#!/bin/sh
# WiFi 一键修复 / KUAL 菜单项
#
# 背景：2026-11-01 排查 6 小时的根因只有一个字符的差别：
#       ap_scan=2 -> ap_scan=1
#
# 原理：nl80211 驱动下 ap_scan=2 不扫描，wpa_supplicant 没有 BSS 缓存，
#       关联请求的 BSSID 只能是全零 00:00:00:00:00:00、且没有 RSN IE，
#       路由器按 802.11 标准只能回 status_code=1（Unspecified failure）。
#       这不是路由器拒绝，是请求本身不合法。
#
# 本脚本做四件事，全部幂等，可以反复点：
#   1. 检查/修正 ap_scan=1（含设备上已存在的 agentd7.sh）
#   2. 只停 wifid，绝不动 wifim / wifis（停了 wlan0 会整个消失）
#   3. 重建 supplicant，等扫描完成、BSS 缓存建立后再关联
#   4. 拿 IP，写 wifi.ok，显示结果

PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH
export PATH

D=/mnt/us/weatherdash
AG=$D/agentd7.sh
LOG=$D/repair.log
WCONF=/tmp/wpa_repair.conf
WC="timeout 8 wpa_cli -i wlan0 -p /var/run/wpa_supplicant"
NETS="YOUR_SSID|YOUR_WIFI_PASSWORD;"

say() { echo "$(date -u '+%F %T') $*" >> "$LOG" 2>/dev/null; }
msgs() { echo "$1" > /tmp/rp.msg 2>/dev/null; }

# 屏幕：状态栏会盖住顶部，只有第 8 行之后可见。
# 每 10 秒刷新进度，否则用户看到的是冻结的旧图，误以为卡死。
# eips 会往 stdout 打印 update_to_display 之类的系统噪声，
# 命令通道会把它当成命令结果回传，日志里全是垃圾。全部丢进 /dev/null。
show() { eips 8 1 "$1" >/dev/null 2>&1; }
shown() { eips 9 1 "$1" >/dev/null 2>&1; }

: > "$LOG"
say "########## wifi repair start ##########"

# 阻止休眠：否则屏幕冻结在旧画面
lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null

restore_ss() {
  if [ -f "$D/carousel.on" ] || [ -f "$D/touchd.on" ]; then
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null
  else
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
  fi
}

ipof() { ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p'; }
st() { $WC status 2>/dev/null </dev/null | sed -n 's/^wpa_state=//p'; }

# ============================================================
# 第 0 步：先看是不是已经连上了，连上就别折腾
# ============================================================
IP=$(ipof)
STATE=$(st)
if [ -n "$IP" ] && [ "$STATE" = "COMPLETED" ]; then
  say "already connected ip=[$IP] -- nothing to do"
  show "WiFi already OK"
  shown "IP $IP"
  restore_ss
  exit 0
fi

# ============================================================
# 第 1 步：修正 ap_scan（根因）
# ============================================================
show "repair: check ap_scan"
say "--- step 1: ap_scan ---"

# 设备上已有的 agentd7.sh 如果写着 ap_scan=2，就地改掉。
# 用 awk 整行替换，busybox sed 处理这种带引号的替换容易出错。
if [ -f "$AG" ]; then
  if grep -q 'echo "ap_scan=2"' "$AG" 2>/dev/null; then
    say "FOUND ap_scan=2 in agentd7.sh -- fixing to 1"
    awk '{ if ($0 == "    echo \"ap_scan=2\"") print "    echo \"ap_scan=1\""; else print }' \
      "$AG" > /tmp/ag.new 2>/dev/null
    if [ -s /tmp/ag.new ]; then
      cp -f /tmp/ag.new "$AG" 2>/dev/null
      say "agentd7.sh ap_scan fixed  now=$(grep -c 'ap_scan=1' "$AG")"
    fi
    rm -f /tmp/ag.new
  else
    say "agentd7.sh ap_scan already 1 (or not found)"
  fi
fi

# ============================================================
# 第 2 步：只停 wifid，绝不停 wifim / wifis
# ============================================================
show "repair: reset supplicant"
say "--- step 2: reset supplicant ---"

initctl start wifim 2>/dev/null
initctl start wifis 2>/dev/null
sleep 2

# wifim = 驱动，wifis = 射频/supplicant 宿主。停掉它们 wlan0 会整个消失，
# 而且停用状态会一直保留到重启。只能停 wifid。
initctl stop wifid 2>/dev/null
killall wifid 2>/dev/null
sleep 1

killall wpa_supplicant 2>/dev/null
sleep 2
rm -f /var/run/wpa_supplicant/wlan0 2>/dev/null

if [ ! -e /sys/class/net/wlan0 ]; then
  say "FATAL: wlan0 missing after reset"
  show "wlan0 MISSING - reboot device"
  restore_ss
  exit 1
fi
say "wlan0 present"

# ============================================================
# 第 3 步：写配置（ap_scan=1 是重点）
# ============================================================
say "--- step 3: write config ---"
{
  echo "ctrl_interface=/var/run/wpa_supplicant"
  echo "update_config=1"
  echo "ap_scan=1"
  echo ""
  pri=20
  echo "$NETS" | tr ';' '\n' | while IFS='|' read -r s p; do
    [ -z "$s" ] && continue
    printf 'network={\n\tssid="%s"\n\tpsk="%s"\n\tpriority=%d\n\tscan_ssid=1\n}\n' "$s" "$p" "$pri"
    pri=$((pri - 5))
  done
} > "$WCONF" 2>/dev/null
chmod 600 "$WCONF" 2>/dev/null
cp -f "$WCONF" "$D/wpa_live.conf" 2>/dev/null
say "config bytes=$(wc -c < "$WCONF" 2>/dev/null) ap_scan=$(grep -c 'ap_scan=1' "$WCONF")"

ifconfig wlan0 up 2>/dev/null

# ============================================================
# 第 4 步：启动 supplicant（不要用 -B，会丢 debug）
# ============================================================
show "repair: start supplicant"
say "--- step 4: start supplicant ---"

DBG=$D/repair_dbg.log
rm -f "$DBG"
timeout 180 wpa_supplicant -dd -i wlan0 -c "$WCONF" -Dnl80211 >> "$DBG" 2>&1 &
sleep 4

n=0
while [ $n -lt 10 ]; do
  $WC status >/dev/null 2>&1 </dev/null && break
  n=$((n + 1))
  sleep 1
done
say "ctrl ready after ${n}s"

# ============================================================
# 第 5 步：扫描并等 BSS 缓存建立（v4 实测的决定性步骤）
# ============================================================
show "repair: scan for AP"
say "--- step 5: scan + wait BSS ---"

timeout 8 $WC scan >/dev/null 2>&1 </dev/null
sn=0
FOUND=""
while [ $sn -lt 12 ]; do
  SR=$(timeout 6 $WC scan_results 2>/dev/null </dev/null)
  for want in YOUR_SSID YOUR_SSID_2; do
    if echo "$SR" | grep -qi "$want"; then
      FOUND="$want"
      break 2
    fi
  done
  sn=$((sn + 1))
  sleep 2
done

if [ -z "$FOUND" ]; then
  say "NO AP found in scan after ${sn}x2s"
  echo "$SR" | head -n 12 | while IFS= read -r l; do say "  sr| $l"; done
  show "NO AP - check router"
  restore_ss
  exit 1
fi
say "found [$FOUND] after ${sn}x2s"

# 确认 BSS 条目真的有内容，而不是全零 BSSID
BSSID=$(echo "$SR" | grep -i "$FOUND" | head -n 1 | awk '{print $1}')
say "bssid=[$BSSID]"
if [ -n "$BSSID" ]; then
  BSSOUT=$(timeout 6 $WC bss "$BSSID" 2>/dev/null </dev/null)
  if [ -n "$BSSOUT" ]; then
    say "BSS entry OK ($(echo "$BSSOUT" | wc -l) lines)"
  else
    say "BSS entry EMPTY -- will still try, but watch for 000000000000"
  fi
fi

# ============================================================
# 第 6 步：关联
# ============================================================
show "repair: connecting"
say "--- step 6: connect ---"

SEL=$(timeout 10 $WC list_networks 2>/dev/null </dev/null \
      | grep -i "$FOUND" | head -n 1 | awk '{print $1}')
[ -z "$SEL" ] && SEL=0
say "select_network $SEL for [$FOUND]"

$WC select_network "$SEL" >/dev/null 2>&1 </dev/null

n=0
STATE=""
while [ $n -lt 20 ]; do
  STATE=$(st)
  [ "$STATE" = "COMPLETED" ] && break
  # 已经被拒就别干等，直接重扫
  if grep -aq 'CTRL-EVENT-ASSOC-REJECT' "$DBG" 2>/dev/null && [ $n -gt 5 ]; then
    say "assoc rejected, retry after rescan"
    timeout 8 $WC scan >/dev/null 2>&1 </dev/null
    sleep 3
    $WC select_network "$SEL" >/dev/null 2>&1 </dev/null
  fi
  n=$((n + 1))
  sleep 2
done
say "connect state=[$STATE]"

# ============================================================
# 第 7 步：拿 IP
# ============================================================
if [ "$STATE" = "COMPLETED" ]; then
  show "repair: getting IP"
  IP=$(ipof)
  if [ -z "$IP" ]; then
    udhcpc -i wlan0 -b -q -n -t 8 -T 2 >/dev/null 2>&1
    sleep 2
    IP=$(ipof)
  fi
  [ -s /etc/resolv.conf ] || echo "nameserver 192.168.1.1" > /etc/resolv.conf 2>/dev/null
fi

# ============================================================
# 结果
# ============================================================
say "--- result ---"
say "state=[$STATE] ip=[$IP] ssid=[$($WC status 2>/dev/null </dev/null | sed -n 's/^ssid=//p')]"

if [ -n "$IP" ]; then
  date -u '+%F %T' > "$D/wifi.ok" 2>/dev/null
  show "WiFi OK"
  shown "IP $IP"
  say "SUCCESS"

  # 出错证据
  grep -aq 'CTRL-EVENT-ASSOC-REJECT' "$DBG" 2>/dev/null && \
    say "WARN: had ASSOC-REJECT during this run"
  grep -aq '4-Way Handshake failed' "$DBG" 2>/dev/null && \
    say "WARN: had 4-Way Handshake failed (password?)"

  restore_ss
  exit 0
else
  show "WiFi FAILED - see log"
  shown "KUAL: WiFi diag"

  # 把关键证据留在日志里，方便插 USB 后直接判断
  say "--- assoc reject evidence ---"
  grep -aE 'Trying to associate|ASSOC-REJECT|status_code|No WPA/RSN IE' "$DBG" 2>/dev/null \
    | tail -n 12 | while IFS= read -r l; do say "  dbg| $l"; done
  say "--- handshake evidence ---"
  grep -aE '4-Way Handshake|reason=|CTRL-EVENT-DISCONNECTED' "$DBG" 2>/dev/null \
    | tail -n 10 | while IFS= read -r l; do say "  dbg| $l"; done

  restore_ss
  exit 1
fi
