#!/bin/sh
# KUAL starts actions with a minimal PATH that lacks /usr/sbin and /sbin,
# where eips / wpa_cli / wpa_supplicant / ifconfig / udhcpc / killall live.
# Without this line every such call fails silently (all of them are written
# with 2>/dev/null), which looks like "pressing the menu item does nothing".
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH
export PATH
# agentd7.sh (rev-7) —— WiFi 命令代理（幂等 / 不会挂死）
#
# rev-7 关键修复（对应 00:03 / 00:19 / 00:35 三次卡死）：
#   1) 已经连上就直接进主循环，绝不再 kill 掉正常的 supplicant 重建
#   2) 已有 supplicant 且 wpa_cli 能用 → 保留它，不杀
#   3) wpa_supplicant 启动加 timeout，杜绝卡死在 -B 上（日志停在 conf_head 的根因）
#   4) 连接失败不再退出，每 60 秒重试，屏幕保留状态
#   5) 单实例保护，重复点 KUAL 不会互相踩

PC="192.168.1.100:8899"
D=/mnt/us/weatherdash
L1=$D/agent7.log
RES=/tmp/agent7.res
RUN=/tmp/agent7.run.sh
WCONF=/tmp/wpa_own.conf
OKF=$D/wifi.ok
REV="rev-7"

# ---- 内置网络凭据（priority 高者优先）----
NETS="YOUR_SSID|YOUR_WIFI_PASSWORD;"

say() { echo "$(date -u '+%F %T') $*" >> "$L1" 2>/dev/null; }
# ---------- 常亮策略：只在仪表盘真的在跑时才常亮 ----------
# 之前这里无条件设 1，导致退出仪表盘后 1 秒就被改回常亮，
# 屏幕永不自动休眠、电量键也锁不上。
dash_alive() { [ -f "$D/carousel.on" ] || [ -f "$D/touchd.on" ]; }
ss_sync() {
  if dash_alive; then
    lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null
  else
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
  fi
}

show() {
  # 这台机器状态栏压住了上半屏，实测只有第 8 行附近能看到。
  # 原来把状态拆到 2/4/6/8 四行，结果人只能看见最后一段，看不全。
  # 现在把三段拼成一行，一次画在可见的那一行上。
  L="$1"
  [ -n "$2" ] && L="$L | $2"
  [ -n "$3" ] && L="$L | $3"
  eips 8 1 "$L" 2>/dev/null
}

ipof() { ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p'; }
WC="timeout 8 wpa_cli -i wlan0 -p /var/run/wpa_supplicant"
st()   { $WC status 2>/dev/null </dev/null | sed -n 's/^wpa_state=//p'; }
ssid() { $WC status 2>/dev/null </dev/null | sed -n 's/^ssid=//p'; }

# ---------- 单实例保护 ----------
# 为什么不够：pidfile 只记最后一次写的 pid，老实例的 pid 早被覆盖，
# 于是反复启动会累积多个心跳循环（实测同时跑过 4 个），它们各自
# 每分钟改一次 preventScreenSaver，行为互相打架。
# 改成扫描 /proc 里所有 agentd7 实例：除自己外还有活的就退出。
me=$$
others=""
for p in /proc/[0-9]*; do
  pid=$(basename "$p")
  [ "$pid" = "$me" ] && continue
  tr '\0' ' ' < "$p/cmdline" 2>/dev/null | grep -q 'agentd7' && others="$others $pid"
done
if [ -n "$others" ]; then
  say "other agentd7 alive:$others -> exit this instance (pid=$me)"
  exit 0
fi

if [ -f "$D/agent7.pid" ]; then
  OLD=$(cat "$D/agent7.pid" 2>/dev/null)
  case "$OLD" in
    ''|*[!0-9]*) : ;;
    *)
      if [ "$OLD" != "$$" ] && [ -d "/proc/$OLD" ] && \
         tr '\0' ' ' < "/proc/$OLD/cmdline" 2>/dev/null | grep -q 'agentd7'; then
        say "another agentd7 alive pid=$OLD, exit this instance"
        exit 0
      fi
      ;;
  esac
fi
echo "$$" > "$D/agent7.pid" 2>/dev/null
say "########## agentd7 $REV start pid=$$ pc=$PC ##########"

# 干掉 agent_live.sh，避免两个代理同抢 wpa_supplicant
for p in $(pidof agent_live.sh 2>/dev/null); do
  [ "$p" != "$$" ] && { kill -9 "$p" 2>/dev/null; say "killed agent_live pid=$p"; }
done

ss_sync

# ---------- 写 wpa 配置 ----------
write_wconf() {
  {
    echo "ctrl_interface=/var/run/wpa_supplicant"
    echo "update_config=1"
    # ap_scan=1 是必须的。nl80211 驱动下 ap_scan=2 不扫描，
    # wpa_supplicant 没有 BSS 缓存，关联请求的 BSSID 只能是全零、
    # 且没有 RSN IE，路由器按标准回 status_code=1 拒绝。
    # v4 诊断实测：改回 1 并等扫描完成后一次就连上，拿到 192.168.1.50。
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
}

# ---------- 判断是否已经连上，连上就跳过整套重建 ----------
IP=$(ipof)
STATE=$(st)
if [ -n "$IP" ] && [ "$STATE" = "COMPLETED" ]; then
  say "already connected ip=[$IP] ssid=[$(ssid)] -- skip supplicant rebuild"
  show "WIFI OK (reuse)" "IP: $IP" "ssid: $(ssid)"
else
  show "starting..." "" ""
  echo "$$" > "$D/agent7.pid" 2>/dev/null
  /sbin/ifconfig wlan0 up 2>/dev/null || ifconfig wlan0 up 2>/dev/null
  # 注意：这里不要 enable wifid。我们正要接管 wlan0，启用它只会让它
  # 把 supplicant 抢回去。之前这行是 enable 1，等于前面关闭白做。
  mkdir -p /var/run/wpa_supplicant 2>/dev/null
  write_wconf
  say "wconf bytes=$(wc -c < "$WCONF" 2>/dev/null) supp_pid=[$(pidof wpa_supplicant 2>/dev/null)]"

  # ---------- 第一步：让系统自己的 WiFi 栈先试 ----------
  # /etc/wpa_supplicant.conf 里凭据是正确的（已从设备上读出来确认），
  # 系统栈本来就能连。先给它机会，不行再接管，别一上来就抢。
  say "--- phase 1: let system wifi stack try ---"
  for job in wifim wifis; do
    initctl start "$job" 2>/dev/null && say "initctl start $job ok"
  done
  sleep 2
  initctl start wifid 2>/dev/null && say "initctl start wifid ok"

  # 等 wlan0 节点出现（最多 15 秒）
  n=0
  while [ ! -e /sys/class/net/wlan0 ] && [ $n -lt 15 ]; do
    sleep 1
    n=$((n + 1))
  done
  /sbin/ifconfig wlan0 up 2>/dev/null || ifconfig wlan0 up 2>/dev/null
  say "wlan0 exists=$([ -e /sys/class/net/wlan0 ] && echo yes || echo no) waited=${n}s"

  # 给系统栈最多 45 秒去关联
  n=0
  while [ $n -lt 15 ]; do
    S=$(timeout 6 wpa_cli -i wlan0 -p /var/run/wpa_supplicant status 2>/dev/null </dev/null)
    echo "$S" | grep -q 'wpa_state=COMPLETED' && break
    n=$((n + 1))
    sleep 3
  done
  SYSS=$(echo "$S" | grep '^wpa_state=' | cut -d= -f2)
  say "phase1 result: state=[$SYSS] ssid=[$(echo "$S" | grep '^ssid=' | cut -d= -f2)] waited=$((n * 3))s"

  if [ "$SYSS" = "COMPLETED" ]; then
    say "system stack connected by itself -- no takeover needed"
    USABLE=1
  else
    # ---------- 第二步：系统连不上，才接管 ----------
    say "--- phase 2: take over (system stack failed) ---"

    # 取证：这时候最需要知道射频/加密参数为什么连不上
    say "ifconfig wlan0: $(ifconfig wlan0 2>/dev/null | tr '\n' ' ')"
    say "iwconfig wlan0: $(iwconfig wlan0 2>/dev/null | tr '\n' ' ')"
    say "rfkill: $(rfkill list 2>/dev/null | tr '\n' ' ')"
    say "scan_results: $(timeout 15 wpa_cli -i wlan0 -p /var/run/wpa_supplicant scan_results 2>/dev/null </dev/null | grep -i 'Xiaomi' | tr '\n' '|')"

    initctl stop wifid 2>/dev/null && say "initctl stop wifid ok"
    sleep 1
    killall wifid 2>/dev/null
    sleep 1
    killall wpa_supplicant 2>/dev/null
    sleep 2
    rm -f /var/run/wpa_supplicant/wlan0 2>/dev/null
    say "supplicant killed, pid=[$(pidof wpa_supplicant 2>/dev/null)]"
    /sbin/ifconfig wlan0 up 2>/dev/null || ifconfig wlan0 up 2>/dev/null

    # 关键：这里必须真正启动 supplicant。
    # 上一版这段 for drv 循环被误删，导致只 kill 不 start，
    # 日志表现为 "ps|" 为空、"add_network failed"。
    USABLE=0
    for drv in "-Dnl80211" "" "-Dwext"; do
      timeout 25 wpa_supplicant -B -i wlan0 -c "$WCONF" $drv >/dev/null 2>&1
      rc=$?
      sleep 3
      NP=$(pidof wpa_supplicant 2>/dev/null)
      say "drv=[$drv] rc=$rc pid=[$NP]"
      if [ -n "$NP" ] && timeout 10 wpa_cli -i wlan0 -p /var/run/wpa_supplicant status >/dev/null 2>&1 </dev/null; then
        USABLE=1
        say "supplicant usable drv=[$drv]"
        break
      fi
    done
  fi

  if [ "$USABLE" -eq 0 ]; then
    say "########## SUPPLICANT FAILED ##########"
    show "WIFI FAIL" "supplicant" "see agent7.log"
  fi
fi


# 从 NETS 派生 SSID 列表，按定义顺序遍历（第一个优先）
SSIDS=$(echo "$NETS" | tr ';' '\n' | awk -F'|' '{ if ($1 != "") printf "%s ", $1 }')

# ---------- 确保我们的网络真的在 supplicant 里 ----------
# 复用别人启动的 supplicant 时，它里面没有我们的 network 配置。
# 光 status 能应答不代表能连上某个 SSID，所以这里主动把配置写进去。
# 全部通过 wpa_cli 完成，幂等：已有同 SSID 的就不重复添加。
inject_nets() {
  $WC enable_network all >/dev/null 2>&1 </dev/null

  # 先清掉重复：同一个 SSID 只保留最早那个，其余 disable。
  # 之前 bug 每轮 add_network 一次，已经堆了 net 2/4/6/8 四份。
  for ss in $SSIDS; do
    dups=$(timeout 12 wpa_cli -i wlan0 -p /var/run/wpa_supplicant list_networks 2>/dev/null </dev/null \
           | grep -F "$ss" | sed -n 's/^[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -n +2)
    for d in $dups; do
      $WC remove_network "$d" >/dev/null 2>&1 </dev/null
      say "inject: removed duplicate net id $d for [$ss]"
    done
  done

  echo "$NETS" | tr ';' '\n' | while IFS='|' read -r ss psk; do
    [ -z "$ss" ] && continue

    # 已经存在同名 network 就复用它的 id
    id=$(net_id_for "$ss")

    if [ -z "$id" ]; then
      id=$($WC add_network 2>/dev/null </dev/null | tr -d '\r\n ')
      case "$id" in
        ''|*[!0-9]*)
          say "inject: add_network failed for [$ss]"
          continue
          ;;
      esac
      $WC set_network "$id" ssid "\"$ss\"" >/dev/null 2>&1 </dev/null
      $WC set_network "$id" psk "\"$psk\"" >/dev/null 2>&1 </dev/null
      $WC set_network "$id" scan_ssid 1 >/dev/null 2>&1 </dev/null
      $WC set_network "$id" priority 20 >/dev/null 2>&1 </dev/null
      say "inject: added [$ss] as net id $id"
    else
      say "inject: [$ss] already present as net id $id"
    fi

    $WC enable_network "$id" >/dev/null 2>&1 </dev/null
  done

  # 把配置落盘，避免下次重启又丢
  $WC save_config >/dev/null 2>&1 </dev/null

  NL=$(timeout 12 wpa_cli -i wlan0 -p /var/run/wpa_supplicant list_networks 2>/dev/null </dev/null | grep -c .)
  say "inject done: networks_in_supplicant=$NL"
  # 把原文打进日志：下次排查不用再猜 supplicant 里到底有什么
  timeout 12 wpa_cli -i wlan0 -p /var/run/wpa_supplicant list_networks 2>/dev/null </dev/null \
    | while IFS= read -r line; do say "  ln| $line"; done
  say "  ps| $(ps 2>/dev/null | grep wpa_supplicant | grep -v grep | tr '\n' ' ')"
}

# 按 SSID 精确取网络 id。
# 原实现取 list_networks 第一行，实测拿到 0 号（wifid 留下的旧配置），
# 不是我们的 YOUR_SSID（2 号），选中它永远连不上。
net_id_for() {
  # 注意：不要用 awk -F'\t'。busybox awk 不认 \t 转义，$2 会恒为空，
  # 导致"刚注入进来却说找不到"，于是每轮重复 add_network 一直堆编号。
  # 这里改成 grep 定位行 + sed 取首列编号，不依赖字段分隔符。
  timeout 12 wpa_cli -i wlan0 -p /var/run/wpa_supplicant list_networks 2>/dev/null </dev/null \
    | grep -F "$1" \
    | sed -n '1s/^[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

# 兜底：真的没有我们的网络时，才用第一个非空 network
first_net_id() {
  for ss in $SSIDS; do
    id=$(net_id_for "$ss")
    if [ -n "$id" ]; then
      echo "$id"
      return 0
    fi
  done
  timeout 12 wpa_cli -i wlan0 -p /var/run/wpa_supplicant list_networks 2>/dev/null </dev/null \
    | sed -n '1s/^[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

# 等一个状态，期间定期刷屏，让人知道还活着。
# 所有 wpa_cli 都走 timeout，避免 supplicant 关联中不响应时挂死。
wait_state() {
  want=$1
  max=$2
  ss=$3
  n=0
  while [ $n -lt "$max" ]; do
    S=$(st)
    [ "$S" = "$want" ] && { say "reached $want in ${n}x2s"; return 0; }
    n=$((n + 1))
    if [ $((n % 5)) -eq 0 ]; then
      show "connecting $ss ${n}x2s $S" "" ""
    fi
    sleep 2
  done
  return 1
}

# ---------- 单轮连接尝试 ----------
connect_once() {
  show "scanning..." "" ""
  $WC scan >/dev/null 2>&1 </dev/null
  sleep 8
  APF=$(timeout 12 wpa_cli -i wlan0 -p /var/run/wpa_supplicant scan_results 2>/dev/null </dev/null | grep -c 'YOUR_SSID')
  say "scan ap_Xiaomi=$APF"

  # 先确认我们的网络真在里面。配置文件启动有时会被 wifid 换掉，
  # 表现为 list_networks 只有表头（0 个网络）。inject 是幂等的：
  # 已有同 SSID 就复用 id，没有才 add，不会像旧版那样无限堆编号。
  NL=$(timeout 12 wpa_cli -i wlan0 -p /var/run/wpa_supplicant list_networks 2>/dev/null </dev/null | grep -c .)
  say "networks in supplicant=$NL"
  FOUND=0
  for ss in $SSIDS; do
    [ -n "$(net_id_for "$ss")" ] && FOUND=1
  done
  if [ "$FOUND" -eq 0 ]; then
    say "our networks missing (only $NL lines) -> inject via wpa_cli"
    inject_nets
  else
    say "our networks already loaded, skip inject"
  fi
  # wifid 可能在这期间又起来抢 wlan0，选网前再压一次
  killall wifid 2>/dev/null

  # 优先选第一个 SSID（YOUR_SSID）
  SEL=""
  SSID_TRY=""
  for ss in $SSIDS; do
    id=$(net_id_for "$ss")
    if [ -n "$id" ]; then
      SEL="$id"
      SSID_TRY="$ss"
      break
    fi
  done

  if [ -z "$SEL" ]; then
    say "no network in supplicant after inject"
    say "  expected SSIDs: $SSIDS"
    timeout 12 wpa_cli -i wlan0 -p /var/run/wpa_supplicant list_networks 2>/dev/null </dev/null \
      | while IFS= read -r line; do say "  fail| $line"; done
    show "NO NET in supplicant" "" ""
    return 1
  fi

  # 关联前必须等扫描完成、BSS 缓存建立（v4 诊断实测的决定性步骤）。
  # 没有 BSS 条目时，wpa_supplicant 会把关联请求退化成
  # 全零 BSSID + 缺失 RSN IE，路由器只能回 status_code=1 拒绝。
  timeout 8 $WC scan >/dev/null 2>&1 </dev/null
  sn=0
  while [ $sn -lt 10 ]; do
    if timeout 6 $WC scan_results 2>/dev/null </dev/null | grep -qi "$SSID_TRY"; then
      break
    fi
    sn=$((sn + 1))
    sleep 2
  done
  say "bss ready for [$SSID_TRY] after ${sn}x2s"

  say "select_network $SEL for [$SSID_TRY]"
  show "connecting $SSID_TRY" "" ""
  $WC select_network "$SEL" >/dev/null 2>&1 </dev/null

  if wait_state COMPLETED 25 "$SSID_TRY"; then
    say "assoc ok state=[$(st)] ssid=[$(ssid)]"
    show "connected $(ssid)" "" ""
    return 0
  fi
  say "assoc failed state=[$(st)] ssid=[$(ssid)]"
  show "state=$(st) ssid=[$(ssid)]" "" ""

  # 还没连上：把所有网络重新启用，逐个 select 试一遍
  $WC enable_network all >/dev/null 2>&1 </dev/null
  ids=$(timeout 12 wpa_cli -i wlan0 -p /var/run/wpa_supplicant list_networks 2>/dev/null </dev/null | grep -v '^network id' | sed -n 's/^[[:space:]]*\([0-9][0-9]*\).*/\1/p')
  for id in $ids; do
    ss_try=$(timeout 12 wpa_cli -i wlan0 -p /var/run/wpa_supplicant list_networks 2>/dev/null </dev/null \
             | sed -n "s/^[[:space:]]*$id[[:space:]]\+\([^[:space:]]*\).*/\1/p" | head -n 1)
    say "retry select_network $id [$ss_try]"
    show "retry $ss_try" "" ""
    $WC select_network "$id" >/dev/null 2>&1 </dev/null
    if wait_state COMPLETED 10 "$ss_try"; then
      say "retry ok ssid=[$(ssid)]"
      return 0
    fi
    say "  net[$ss_try] state=[$(st)]"
  done

  # 最后手段：重新关联
  $WC reassociate >/dev/null 2>&1 </dev/null
  if wait_state COMPLETED 10 "$SSID_TRY"; then
    say "reassociate ok ssid=[$(ssid)]"
    return 0
  fi
  say "reassociate failed state=[$(st)]"

  return 1
}

# ---------- DHCP + 路由 ----------
dhcp() {
  IP=$(ipof)
  if [ -z "$IP" ]; then
    udhcpc -i wlan0 -b -q -n -t 8 -T 2 >/dev/null 2>&1
    sleep 2
    IP=$(ipof)
  fi
  [ -s /etc/resolv.conf ] || echo "nameserver 192.168.1.1" > /etc/resolv.conf 2>/dev/null
  if [ -n "$IP" ] && ! ip route 2>/dev/null | grep -q '^default'; then
    ip route add default via 192.168.1.1 dev wlan0 2>/dev/null
    say "route add default rc=$?"
  fi
  echo "$IP"
}

APF=0

# ---------- 外层：保证始终在线，掉了就重连 ----------
while :; do
  # 注意：这里不要再 disable wifid。
  # 新版策略是「系统栈优先」——phase 1 恰恰需要 wifid 在跑。
  # 之前这行每轮压一次，等于把 phase 1 的前提条件拆掉了。
  IP=$(ipof)
  if [ -z "$IP" ] || [ "$(st)" != "COMPLETED" ]; then
    connect_once
    IP=$(dhcp)
    say "connect result ip=[$IP] state=[$(st)]"
  fi

  if [ -z "$IP" ]; then
    show "NOIP st=$(st) ap=$APF" "retry 60s" ""
    say "no ip, retry in 60s"
    sleep 60
    continue
  fi

  show "OK $IP $(ssid)" "" ""
  echo "$IP" > "$OKF" 2>/dev/null
  say "online ip=$IP ssid=[$(ssid)]"

  # 第一次上线时拉一次配置：时区 / 常亮 / 关前光 / 开轮播。
  # 放在这里而不是开机钩子，是为了先确保 WiFi 通再画屏——
  # 否则天气页会把 eips 的 WiFi 状态盖掉，人看不到到底连没连上。
  if [ ! -f "$D/.boot_done" ]; then
    say "--- fetch boot config ---"
    BS=/tmp/agent_boot.sh
    if curl -s --max-time 20 "http://$PC/boot" > "$BS" 2>/dev/null && [ -s "$BS" ] && head -n 1 "$BS" | grep -q '^#!'; then
      sh "$BS" >> "$D/boot.log" 2>&1
      touch "$D/.boot_done" 2>/dev/null
      say "boot config applied rc=$?"
    else
      say "boot fetch failed, will retry"
    fi
    rm -f "$BS" 2>/dev/null
  fi

  # ---------- 内层：心跳 + 取命令 ----------
  n=0
  fail=0
  while :; do
    n=$((n + 1))
    ss_sync

    hb=$(curl -s --max-time 8 "http://$PC/hb?b=$n&ip=$IP&v=$REV" 2>/dev/null)
    if [ "$hb" = "ok" ]; then
      fail=0
    else
      fail=$((fail + 1))
      if [ "$fail" -ge 3 ]; then
        say "hb_fail=$fail, reconnecting"
        break
      fi
    fi

    cmd=$(curl -s --max-time 10 "http://$PC/next" 2>/dev/null)
    if [ -n "$cmd" ]; then
      echo "$cmd" > "$RUN" 2>/dev/null
      say "RUN len=${#cmd}"
      ( cd "$D" 2>/dev/null; timeout 300 sh "$RUN" ) > "$RES" 2>&1
      rc=$?
      curl -s --max-time 30 -X POST --data-binary "@$RES" \
        "http://$PC/result?rc=$rc&tag=cmd" >/dev/null 2>&1
      say "DONE rc=$rc out=$(wc -c < "$RES" 2>/dev/null)B"
      rm -f "$RUN" "$RES" 2>/dev/null
    fi

    sleep 3
  done
  sleep 10
done
