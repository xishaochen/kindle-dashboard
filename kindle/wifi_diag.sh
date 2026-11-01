#!/bin/sh
# WiFi 关联被拒诊断 v4
#
# v3 的决定性发现（之前几轮都没抓到）：
#
#   wlan0: CTRL-EVENT-ASSOC-REJECT status_code=1
#   Added BSSID 00:00:00:00:00:00 into blacklist      <-- 注意这个 BSSID
#   wlan0: WPA: No WPA/RSN IE available from association info
#   wlan0: WPA: clearing AP RSN IE
#
# 关联请求发给了 **00:00:00:00:00:00**，而且没有带 RSN IE。
# 这不是路由器拒绝我们，而是我们发了一个残缺的关联请求：
# wpa_supplicant 手里根本没有这个 AP 的 BSS 条目，所以：
#   - BSSID 只能用全零
#   - 拿不到 AP 的 RSN IE，自己也构造不出
# 路由器收到这种帧只能回 status_code=1（Unspecified failure）。
#
# 罪魁是我在 v2 里把 ap_scan 从 1 改成 2：
#   ap_scan=2 表示「不扫描，直接定向关联」，但 nl80211 驱动下
#   wpa_supplicant 必须先有 BSS 缓存才能构造合法的关联请求。
#   没有缓存 -> 全零 BSSID + 无 RSN IE -> 必然被拒。
#
# 之前 20:56 那次失败也是 ap_scan=2，所以同样是这个原因。
#
# v4 修正：用 ap_scan=1，让它自己扫描、自己建立 BSS 缓存，
# 并在关联前显式验证 BSS 条目和 RSN IE 是否真的拿到了。

PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH
export PATH

D=/mnt/us/weatherdash
OUT=$D/wifi_diag.out
SSID="YOUR_SSID"
PSK="YOUR_WIFI_PASSWORD"
BSSID="44:f7:70:fe:fd:72"
W="wpa_cli -i wlan0 -p /var/run/wpa_supplicant"

say() { echo "$(date -u '+%F %T') $*" >> "$OUT"; }

: > "$OUT"
say "########## wifi_diag v4 start (ap_scan=1, proper BSS) ##########"

# ---------- 准备：稳定环境 ----------
initctl start wifim 2>/dev/null
initctl start wifis 2>/dev/null
sleep 2
initctl stop wifid 2>/dev/null
killall wifid 2>/dev/null
sleep 1
killall wpa_supplicant 2>/dev/null
sleep 2
rm -f /var/run/wpa_supplicant/wlan0 2>/dev/null
ifconfig wlan0 up 2>/dev/null
say "wlan0 exists=$([ -e /sys/class/net/wlan0 ] && echo yes || echo no)"

# ---------- 关键区别：ap_scan=1 ----------
cat > /tmp/wpa_v4.conf <<EOF
ctrl_interface=/var/run/wpa_supplicant
ap_scan=1
network={
	ssid="$SSID"
	psk="$PSK"
	priority=10
	scan_ssid=1
}
EOF

DBG=$D/wpa_dbg_v4.log
rm -f "$DBG"

timeout 90 wpa_supplicant -dd -i wlan0 -c /tmp/wpa_v4.conf -Dnl80211 >> "$DBG" 2>&1 &
sleep 4

n=0
while [ $n -lt 10 ]; do
  timeout 4 $W status >/dev/null 2>&1 </dev/null && break
  n=$((n + 1))
  sleep 1
done
say "ctrl ready after ${n}s"

# ---------- 主动触发一次扫描，并等它完成 ----------
say ""
say "--- force scan ---"
timeout 8 $W scan >/dev/null 2>&1 </dev/null
n=0
while [ $n -lt 12 ]; do
  sleep 2
  SR=$(timeout 6 $W scan_results 2>/dev/null </dev/null)
  echo "$SR" | grep -qi 'YOUR_SSID' && break
  n=$((n + 1))
done
say "scan wait=${n}x2s found=$(echo "$SR" | grep -ci 'YOUR_SSID')"
echo "$SR" | grep -i 'YOUR_SSID' | while IFS= read -r l; do say "  sr| $l"; done

# ---------- 验证 BSS 条目是否真的进了 wpa_supplicant 的缓存 ----------
say ""
say "--- BSS entry as seen by supplicant ---"
BSSOUT=$(timeout 6 $W bss "$BSSID" 2>/dev/null </dev/null)
if [ -n "$BSSOUT" ]; then
  echo "$BSSOUT" | while IFS= read -r l; do say "  bss| $l"; done
else
  say "  bss| EMPTY -- supplicant has no BSS entry (this is the bug)"
fi

say ""
say "--- list_networks ---"
timeout 6 $W list_networks 2>/dev/null </dev/null | while IFS= read -r l; do say "  ln| $l"; done

# ---------- 关联 ----------
say ""
say "--- connect ---"
timeout 8 $W select_network 0 >/dev/null 2>&1 </dev/null
timeout 8 $W reassociate >/dev/null 2>&1 </dev/null

n=0
while [ $n -lt 22 ]; do
  ST=$(timeout 4 $W status 2>/dev/null </dev/null | sed -n 's/^wpa_state=//p')
  say "  t=$((n * 2))s state=[$ST]"
  [ "$ST" = "COMPLETED" ] && break
  n=$((n + 1))
  sleep 2
done

IP=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
if [ -z "$IP" ] && [ "$ST" = "COMPLETED" ]; then
  udhcpc -i wlan0 -b -q -n -t 8 -T 2 >/dev/null 2>&1
  sleep 2
  IP=$(ifconfig wlan0 2>/dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p')
fi
say "RESULT state=[$ST] ip=[$IP]"

# ---------- 关键证据 ----------
say ""
say "--- assoc attempt (which BSSID / RSN IE present?) ---"
grep -aE 'Trying to associate|Association Request|assoc req|RSN IE|No WPA/RSN IE|ASSOC-REJECT|status_code' "$DBG" 2>/dev/null \
  | tail -n 30 | while IFS= read -r l; do say "  dbg| $l"; done

say ""
say "--- connected/4-way events ---"
grep -aE 'CTRL-EVENT-CONNECTED|4-Way Handshake|CTRL-EVENT-DISCONNECTED|reason=|WPA: Key negotiation' "$DBG" 2>/dev/null \
  | tail -n 20 | while IFS= read -r l; do say "  evt| $l"; done

say ""
say "########## wifi_diag v4 done ##########"
if [ -n "$IP" ]; then say "SUCCESS: got IP $IP"; else say "STILL FAILING: state=[$ST]"; fi
echo "DONE"
