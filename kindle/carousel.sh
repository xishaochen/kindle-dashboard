#!/bin/sh
# KUAL starts actions with a minimal PATH that lacks /usr/sbin and /sbin,
# where eips / wpa_cli / wpa_supplicant / ifconfig / udhcpc / killall live.
# Without this line every such call fails silently (all of them are written
# with 2>/dev/null), which looks like "pressing the menu item does nothing".
PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH
export PATH
# WeatherDash carousel - standalone daemon, does not block the WiFi agent
#
# usage:
#   sh carousel.sh start [interval_seconds]
#   sh carousel.sh stop
#   sh carousel.sh status
#   sh carousel.sh awake on|off     on = stay awake, off = allow auto screen-off (default)
#   sh carousel.sh next             render the next page once
#   sh carousel.sh guard            check once whether the status bar redrew over us
#
# About screen-off: by default the device keeps its own idle timeout and will
# turn the screen off by itself. Only when awake=on does this script hold
# preventScreenSaver at 1 (plugged-in, always-on display). Once the screen goes
# off Kindle drops WiFi, so the PC side loses contact until the power button is
# pressed again. That is expected behaviour, not a fault.
#
# About guard: pillow repaints its top clock band roughly once a minute, which
# lands on top of whatever we drew and leaves the screen showing two different
# things at once. guard() samples the top framebuffer rows and re-blits our
# cached page when they change.

D=/mnt/us/weatherdash
SH=/mnt/us/extensions/weatherdash/bin/dash.sh
ON=$D/carousel.on
PIDF=$D/carousel.pid
LOG=$D/carousel.log
IDXF=$D/carousel.idx
AWAKEF=$D/carousel.awake
PAGES="calendar weather lifeweeks cat gifpage"
# 图 PC 的 bridge 地址：lifeweeks 页靠它渲染（设备侧无 python）
PCIP=${PCIP:-192.168.1.100}
# 会随时间变化的页：切到它之前先重渲一次，否则格子永远是旧的。
# 用「日期变了」做触发条件，而不是每次切页都渲，避免无意义刷新。
DATED_PAGES="calendar lifeweeks"
# 靠 PC 供图的页（设备无渲染器）。catsavercat 从 bridge 的 /cat 取。
REMOTE_PAGES="lifeweeks cat gifpage"

FB=/mnt/us/libkh/bin/fbink
IMGDIR=/tmp/weatherdash
SHIFT_Y=32
GUARD_REF=$D/guard.md5
GUARD_LAST=$D/guard.last
GUARD_BAD=$D/guard.bad
GUARD_REPAINT=$D/guard.repaint
GUARD_PTS=$D/guard.pts     # last page.ts seen; a change means a real flip
GUARD_EVERY=5        # seconds between top-band samples; matches the loop tick
# 重绘限速：状态栏自己会闪（时钟分钟位 + 同步图标），采样永远抓不到稳定基准。
# 没有限速时 guard 会自激：重画 -> 采样到另一相位 -> 再重画，屏幕一直在闪。
# 60s 一次已经足够跟上 pillow 的节奏，也不会让人眼觉得在刷屏。
GUARD_MIN_GAP=60

log() { echo "$(date -u '+%F %T') $*" >> "$LOG" 2>/dev/null; }

# 毫秒时钟。date +%s 是整秒，而 period 可能是 1 秒 —— 整秒精度下
# "到点了没" 的判定误差最大 1 秒，等于把 period 拉长一倍。
# /proc/uptime 有百分秒，配合 awk 换算成毫秒，正好够用。
now_ms() {
  cut -d' ' -f1 /proc/uptime | awk '{printf "%d", $1 * 1000}'
}


# 毫秒级等待。busybox 的 sleep 不收小数（实测 `sleep 0.3` 直接 rc=1 并立即返回），
# 所以要用 usleep。$1 = 毫秒。
napsleep() {
  ms=$1
  case "$ms" in ''|*[!0-9]*) ms=500 ;; esac
  if [ "$ms" -ge 1000 ] && [ $((ms % 1000)) -eq 0 ]; then
    sleep $((ms / 1000))
  elif command -v usleep >/dev/null 2>&1; then
    usleep $((ms * 1000))
  else
    sleep $(( (ms + 999) / 1000 ))
  fi
}

# 记住当前在屏的页，repaint() 靠它决定重画哪张。
# 必须同时写 touchd.cur：touchd 用它推算「下一页」，只写 page.idx 会让
# 点击翻页从错误的起点开始（例如猫页点击却翻到 calendar，跳过了一页）。
# 把 page.idx 统一成页名。
# dash.sh 的 loop 模式也写 page.idx，历史版本写的是数字下标，和 carousel 的
# 页名混在一起。page.idx 是数字时 repaint() 的 case 匹配不上直接 return 1，
# 表现为日志刷 "guard: repaint failed"，状态栏盖上来之后永远洗不掉。
normalize_page() {
  # 页名白名单不单独维护：以 $PAGES 为唯一事实来源，
  # 否则每加一页都要改这里，漏改就会把合法页名判成非法、page.idx 退回数字。
  case " $PAGES " in
    *" $1 "*) echo "$1"; return 0 ;;
  esac
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  n=$1
  total=0
  for p in $PAGES; do total=$((total + 1)); done
  [ "$total" -eq 0 ] && return 1
  [ "$n" -ge "$total" ] && n=$((n % total))
  n=$((n + 1))
  echo $PAGES | cut -d' ' -f"$n"
  return 0
}

page_idx_write() {
  echo "$1" > "$D/page.idx"
  echo "$1" > "$D/touchd.cur"
  # 记下"谁、什么时候"翻的页。
  # page.ts 让 guard 区分"有人主动翻页"和"状态栏把我们盖住"：
  # 前者画面变化是预期的，重画一次会让用户看到画面莫名又闪一下；
  # 后者才是真的被盖住，必须重画。page.src 只用于事后对账。
  date +%s > "$D/page.ts" 2>/dev/null
  echo "${2:-dash}" > "$D/page.src" 2>/dev/null
}

awake_on() { [ -f "$AWAKEF" ] && [ "$(cat "$AWAKEF" 2>/dev/null)" = "on" ]; }

# Write preventScreenSaver only when it must change. Re-writing the same value
# resets powerd's idle countdown, so "set 0 forever" would never sleep.
keepawake() {
  want=0
  # 只有我们真的在占屏时才阻止休眠。否则用户退出仪表盘后设备永远不睡，
  # 电量和屏幕寿命都被白耗。
  if awake_on && dash_owns_screen; then
    want=1
  fi
  cur=$(lipc-get-prop com.lab126.powerd preventScreenSaver 2>/dev/null | head -1)
  [ "$cur" = "$want" ] && return 0
  lipc-set-prop com.lab126.powerd preventScreenSaver "$want" 2>/dev/null
}

# Should the dashboard keep painting over whatever is on screen?
#
# The dashboard is not an app: it writes pixels straight to the framebuffer.
# So it cannot tell "user is reading a book" from "user wants the cat". Any
# foreground app other than the KUAL launcher means the user went off to do
# something else, and our 5s guard was repainting over them every minute -
# that is why the calendar/cat kept "coming back by itself".
#
# Rules:
#   - want_kual mark set      -> user asked for the menu, stand down
#   - tab still running       -> we are the intended screen, keep painting
#                             (dashboard itself never changes activeApp, so
#                              this stays valid after we paint)
#   - anything else on top    -> stand down until user comes back
dash_owns_screen() {
  [ -f "$D/want_kual" ] && return 1
  # If the launcher is foreground and our tab is not running, the user is in
  # a KUAL submenu; do not paint over it.
  a=$(lipc-get-prop com.lab126.appmgrd activeApp 2>/dev/null)
  case "$a" in
    *kindlelauncher*)
      [ -f "$ON" ] && return 0
      return 1
      ;;
  esac
  # Some other app (book reader, settings, home) is foreground: yield.
  [ -n "$a" ] && return 1
  return 0
}

netfix() {
  ip route 2>/dev/null | grep -q '^default ' && return 0
  ip route add default via 192.168.1.1 dev wlan0 2>/dev/null
}

alive() {
  [ -f "$PIDF" ] || return 1
  p=$(cat "$PIDF" 2>/dev/null)
  [ -n "$p" ] || return 1
  [ -d "/proc/$p" ] || return 1
  tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q 'carousel\.sh' || return 1
  return 0
}

# md5 of our content's top rows (y=32..72), NOT the status bar itself.
#
# Why skip 32: pillow repaints rows 0..31 with the clock, and that band changes
# on its own (the minute digit and a blinking sync icon), so hashing it makes
# guard fire forever. Our drawings start at SHIFT_Y=32, so a repaint of 0..31
# cannot damage us at all. Sampling just below it detects the only case that
# matters: pillow painting further down than 32 rows.
band_md5() {
  dd if=/dev/fb0 bs=1088 skip=$SHIFT_Y count=40 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1
}

# Re-blit the page we already rendered. Much cheaper than a full render and it
# wipes whatever pillow or the home app painted on top of us.
repaint() {
  # 顺序很重要：先确认该我们占屏，再看有没有图。
  # 以前 dash_owns_screen 失败时静默 return 1，日志只有一句
  # "repaint failed"，根本看不出是「让位」还是「缺图」还是「页码坏了」。
  if ! dash_owns_screen; then
    log "repaint skip: not our screen (activeApp=$(lipc-get-prop com.lab126.appmgrd activeApp 2>/dev/null) on=$([ -f "$ON" ] && echo 1 || echo 0))"
    return 1
  fi
  raw=$(cat "$D/page.idx" 2>/dev/null)
  page=$(normalize_page "$raw")
  if [ -z "$page" ]; then
    log "repaint skip: page.idx=[$raw] 不是页名"
    return 1
  fi
  if [ "$page" != "$raw" ]; then
    log "repaint: page.idx=[$raw] -> [$page]"
    page_idx_write "$page"
  fi
  img="$IMGDIR/$page.png"
  if [ ! -s "$img" ]; then
    log "repaint skip: 缺图 $img"
    return 1
  fi
  # fbink writes the framebuffer directly, so hiding pillow first is only
  # needed as a nudge; skipping the fork keeps the 5s guard cheap.
  "$FB" -q -g "file=$img,x=0,y=$SHIFT_Y" -W GC16 >/dev/null 2>&1 || return 1
  band_md5 > "$GUARD_REF"
  log "repaint $page (status bar redrew over us)"
  return 0
}

guard() {
  [ -x "$FB" ] || return 0
  # 用户切走去干别的（看书、设置、主页）时不要抢屏。
  dash_owns_screen || return 0
  now=$(date +%s)

  # 有人刚主动翻过页（手指点击 / 菜单 / catnext / 轮播到点）：
  # 画面和上次采样不同是预期的，不能当成"状态栏盖住"去重画。
  # 把当前画面认作新基准，然后放过这一轮 —— 否则用户点完会看到
  # 画面又自己闪一下，完全分不清是哪次操作生效的。
  pts=$(cat "$D/page.ts" 2>/dev/null)
  case "$pts" in ''|*[!0-9]*) pts=0 ;; esac
  if [ "$pts" != "$(cat "$GUARD_PTS" 2>/dev/null)" ]; then
    echo "$pts" > "$GUARD_PTS"
    band_md5 > "$GUARD_REF"
    rm -f "$GUARD_BAD"
    return 0
  fi
  last=$(cat "$GUARD_LAST" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -lt "$GUARD_EVERY" ] && return 0
  echo "$now" > "$GUARD_LAST"

  cur=$(band_md5)
  [ -z "$cur" ] && return 0
  ref=$(cat "$GUARD_REF" 2>/dev/null)
  if [ -z "$ref" ]; then
    echo "$cur" > "$GUARD_REF"
    return 0
  fi
  [ "$cur" = "$ref" ] && { rm -f "$GUARD_BAD"; return 0; }

  # 状态栏里有个会闪的图标（升级/同步指示），md5 在两种值之间来回跳。
  # 单次采样不同就重画会变成死循环：重画 -> 采样到另一种 -> 再重画。
  # 必须连采两次都一样，才认定是真的被盖住了。
  sleep 2
  cur2=$(band_md5)
  [ "$cur2" = "$cur" ] || { rm -f "$GUARD_BAD"; return 0; }
  # 跳变回基准值也算正常（只是闪烁相位不同）
  [ "$cur2" = "$ref" ] && { rm -f "$GUARD_BAD"; return 0; }
  cur="$cur2"

  # repeated failures to clean the band mean residual pixels above our y offset
  bad=$(cat "$GUARD_BAD" 2>/dev/null)
  case "$bad" in ''|*[!0-9]*) bad=0 ;; esac
  bad=$((bad + 1))
  echo "$bad" > "$GUARD_BAD"
  # 限速：距上次重绘不足 GUARD_MIN_GAP 秒就直接放过这一轮。
  # 闪烁相位差不是真的被覆盖，不需要为它刷屏。
  prev=$(cat "$GUARD_REPAINT" 2>/dev/null)
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  if [ $((now - prev)) -lt "$GUARD_MIN_GAP" ]; then
    rm -f "$GUARD_BAD"
    return 0
  fi

  if [ "$bad" -ge 3 ]; then
    log "guard: band still dirty after $bad tries, forcing full clear+flash"
    "$FB" -q -c -f >/dev/null 2>&1
    echo 0 > "$GUARD_BAD"
  fi
  if repaint; then
    echo "$now" > "$GUARD_REPAINT"
  else
    log "guard: repaint failed"
  fi
}

# ---- 猫页：多帧序列动画 ---------------------------------------------------
# 设计要点：
#   每个动作是一串独立渲染的帧图 f0..fN，每帧只覆盖自己的脏矩形。
#   帧由 PC 侧程序化渲染（tools/catkit_v3.py），像素天然一致——AI 生图
#   跨帧对不齐（实测 sprite sheet 差异 40~60%、编辑后 29% + 尺寸变化），
#   所以不能用 AI 出帧。
#
#   anim.txt 每行：action frames period_ms rectx recty rectw recth
#   帧文件：cat5/<action>/f<N>.png，尺寸 = rectw x recth
#
#   播放：按 period_ms 逐帧推进，贴到 (rectx, recty+SHIFT_Y)。
#   帧数多、矩形小的动作（眨眼 1.5%、摇尾 5.8%）用 A2 不闪屏；
#   大矩形（呼吸 27%）用 GC16 保灰阶。
CAT5=$D/cat6
CAT_ACTIONS=""          # 动作清单
CAT_CUR=""              # 当前动作
CAT_N=0                 # 当前动作帧数
CAT_PER=800             # 当前动作换帧间隔（毫秒）
CAT_RX=0; CAT_RY=0; CAT_RW=0; CAT_RH=0
CAT_FI=0                # 当前帧序号
CAT_SINCE=0             # 本动作开始时刻（毫秒）
CAT_HOLD=110000         # 每个动作至少停留多少毫秒再换
CAT_FRAMES=0            # 换帧次数计数（调试用）
CAT_BEAT=0              # 累计帧计数（每 20 帧落盘）
CAT_OK=0                # 本帧猫是否在屏上（一帧只查一次）
CAT_CHK=0               # 姿势核对计数（每 8 tick 查一次 cat.pose）
ka_acc=0                # keepawake 累计间隔

# 拉 cat5 基图。注意：绝不能用旧的 /cat?part=base（那是 AI 插画猫），
# 否则屏幕上会同时出现 AI 猫和新画的猫，叠成两只。
cat_fetch_base() {
  mkdir -p "$IMGDIR"
  if [ -s "$IMGDIR/cat.png.bak" ]; then :; fi
  curl -s --max-time 25 -o "$IMGDIR/cat.png.tmp" \
    "http://$PCIP:8899/cat6/base.png" 2>/dev/null
  if [ -s "$IMGDIR/cat.png.tmp" ] && \
     [ "$(wc -c < "$IMGDIR/cat.png.tmp")" -gt 5000 ]; then
    mv -f "$IMGDIR/cat.png.tmp" "$IMGDIR/cat.png"
    return 0
  fi
  rm -f "$IMGDIR/cat.png.tmp"
  return 1
}

# 猫页渲染
# 从 PC 拉动作清单
fetch_cat_list() {
  list=$(curl -s --max-time 15 "http://$PCIP:8899/cat6/list" 2>/dev/null | tr -d '\r')
  acts=""
  echo "$list" | while read -r a n per rx ry rw rh; do
    case "$a" in ''|'#'*) continue ;; esac
    printf '%s ' "$a"
  done > "$D/cat5.actions.tmp" 2>/dev/null
  acts=$(cat "$D/cat5.actions.tmp" 2>/dev/null)
  rm -f "$D/cat5.actions.tmp"
  [ -z "$acts" ] && acts="blink breath tail ear yawn"
  CAT_ACTIONS="$acts"
  log "cat actions: $CAT_ACTIONS"
}

# 动作资源是否齐（anim.txt + 全部帧图）
cat_action_cached() {
  w="$1"
  [ -n "$w" ] || return 1
  [ -s "$CAT5/$w/anim.txt" ] || return 1
  n=$(sed -n 's/^n //p' "$CAT5/$w/anim.txt" 2>/dev/null)
  [ -z "$n" ] && return 1
  i=0
  while [ "$i" -lt "$n" ]; do
    [ -s "$CAT5/$w/f$i.png" ] || return 1
    i=$((i + 1))
  done
  return 0
}

# 拉一个动作的全部资源
cat_fetch_action() {
  w="$1"
  [ -n "$w" ] || return 1
  mkdir -p "$CAT5/$w"
  # 先拿全局清单里这一行的元数据
  line=$(curl -s --max-time 15 "http://$PCIP:8899/cat6/list" 2>/dev/null | tr -d '\r' | grep "^$w ")
  [ -z "$line" ] && return 1
  set -- $line
  n="$2"; per="$3"; rx="$4"; ry="$5"; rw="$6"; rh="$7"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac

  printf 'n %s\nper %s\nrect %s %s %s %s\n' "$n" "$per" "$rx" "$ry" "$rw" "$rh" \
    > "$CAT5/$w/anim.txt.tmp" 2>/dev/null || return 1

  i=0
  while [ "$i" -lt "$n" ]; do
    curl -s --max-time 20 -o "$CAT5/$w/f$i.tmp" \
      "http://$PCIP:8899/cat6/$w/f$i.png" 2>/dev/null
    if [ -s "$CAT5/$w/f$i.tmp" ] && [ "$(wc -c < "$CAT5/$w/f$i.tmp")" -gt 100 ]; then
      mv -f "$CAT5/$w/f$i.tmp" "$CAT5/$w/f$i.png"
    else
      rm -f "$CAT5/$w/f$i.tmp"
      return 1
    fi
    i=$((i + 1))
  done
  mv -f "$CAT5/$w/anim.txt.tmp" "$CAT5/$w/anim.txt"
  return 0
}

cat_load_meta() {
  CAT_N=0; CAT_PER=800; CAT_RX=0; CAT_RY=0; CAT_RW=0; CAT_RH=0
  mf="$CAT5/$CAT_CUR/anim.txt"
  [ -s "$mf" ] || return 1
  while read -r k a b c d e; do
    k=$(printf '%s' "$k" | tr -d '\r')
    a=$(printf '%s' "$a" | tr -d '\r')
    b=$(printf '%s' "$b" | tr -d '\r')
    c=$(printf '%s' "$c" | tr -d '\r')
    d=$(printf '%s' "$d" | tr -d '\r')
    e=$(printf '%s' "$e" | tr -d '\r')
    case "$k" in
      n)    CAT_N=$a ;;
      per)  CAT_PER=$a ;;
      rect) CAT_RX=$a; CAT_RY=$b; CAT_RW=$c; CAT_RH=$d ;;
    esac
  done < "$mf"
  case "$CAT_N" in ''|*[!0-9]*) CAT_N=0 ;; esac
  case "$CAT_PER" in ''|*[!0-9]*) CAT_PER=800 ;; esac
  [ "$CAT_PER" -lt 60 ] && CAT_PER=60
  [ "$CAT_N" -lt 1 ] && return 1
  return 0
}

# 换到某个动作：基图走 GC16 全刷，然后开始放序列
# ---- GIF 展示页 ---------------------------------------------------------
# 独立展示页 = 一张静态背景图 + 中间小矩形逐帧刷新。
# 为什么不整页刷：整页 GC16 每 70ms 一次等于全屏闪烁；只刷动画矩形
# 实测 58.5ms/帧（17.1 fps），已超过源素材 14.3 fps 的要求。
GIF_DIR=/mnt/us/weatherdash/gifpage
GIF_N=0
GIF_PER=100
GIF_RX=0; GIF_RY=0; GIF_RW=0; GIF_RH=0
GIF_FI=0
GIF_OK=0
GIF_FRAMES=0

gif_load_meta() {
  GIF_N=0; GIF_PER=100; GIF_RX=0; GIF_RY=0; GIF_RW=0; GIF_RH=0
  gf="$GIF_DIR/anim.txt"
  [ -s "$gf" ] || return 1
  while read -r k a b c d; do
    k=$(printf '%s' "$k" | tr -d '\r')
    a=$(printf '%s' "$a" | tr -d '\r')
    b=$(printf '%s' "$b" | tr -d '\r')
    c=$(printf '%s' "$c" | tr -d '\r')
    d=$(printf '%s' "$d" | tr -d '\r')
    case "$k" in
      n)    GIF_N=$a ;;
      per)  GIF_PER=$a ;;
      rect) GIF_RX=$a; GIF_RY=$b; GIF_RW=$c; GIF_RH=$d ;;
    esac
  done < "$gf"
  case "$GIF_N" in ''|*[!0-9]*) GIF_N=0 ;; esac
  case "$GIF_PER" in ''|*[!0-9]*) GIF_PER=100 ;; esac
  [ "$GIF_PER" -lt 40 ] && GIF_PER=40
  [ "$GIF_N" -lt 1 ] && return 1
  return 0
}

# 拉背景图与 meta（缺哪补哪，已有就跳过）
gif_fetch() {
  mkdir -p "$GIF_DIR" 2>/dev/null
  if [ ! -s "$GIF_DIR/bg.png" ]; then
    curl -s --max-time 20 -o "$GIF_DIR/bg.png.tmp" \
      "http://$PCIP:8899/cat6/gifpage/bg.png" || return 1
    [ -s "$GIF_DIR/bg.png.tmp" ] || return 1
    mv -f "$GIF_DIR/bg.png.tmp" "$GIF_DIR/bg.png"
  fi
  if [ ! -s "$GIF_DIR/anim.txt" ]; then
    curl -s --max-time 20 -o "$GIF_DIR/anim.txt.tmp" \
      "http://$PCIP:8899/cat6/gifpage/anim.txt" || return 1
    [ -s "$GIF_DIR/anim.txt.tmp" ] || return 1
    mv -f "$GIF_DIR/anim.txt.tmp" "$GIF_DIR/anim.txt"
  fi
  return 0
}

# 素材是否齐：只查首尾两帧，不做 24 次磁盘 stat
gif_cached() {
  gif_load_meta || return 1
  [ -s "$GIF_DIR/bg.png" ] || return 1
  [ -s "$GIF_DIR/f0.png" ] || return 1
  [ -s "$GIF_DIR/f$((GIF_N - 1)).png" ] || return 1
  return 0
}

# 贴一帧：只刷动画矩形，全程 GC16
gif_show_frame() {
  [ "$GIF_OK" = "1" ] || return 1
  gf="$GIF_DIR/f$GIF_FI.png"
  [ -s "$gf" ] || return 1
  if "$FB" -q -g "file=$gf,x=$GIF_RX,y=$((GIF_RY + SHIFT_Y))" -W GC16 >/dev/null 2>&1; then
    GIF_FRAMES=$((GIF_FRAMES + 1))
    # 残影清理：每 24 帧整页重贴背景
    if [ $((GIF_FRAMES % 24)) -eq 0 ] && [ -s "$GIF_DIR/bg.png" ]; then
      "$FB" -q -g "file=$GIF_DIR/bg.png,x=0,y=$SHIFT_Y" -W GC16 >/dev/null 2>&1
    fi
    return 0
  fi
  return 1
}

gif_tick() {
  gif_show_frame || return 1
  GIF_FI=$(( (GIF_FI + 1) % GIF_N ))
  return 0
}

# 只在该占屏时刷
gif_probe() {
  gcur=$(cat "$D/page.idx" 2>/dev/null | tr -d '\r\n')
  if [ "$gcur" = "gifpage" ] && [ -s "$GIF_DIR/bg.png" ] && [ "$GIF_N" -gt 0 ]; then
    GIF_OK=1
  else
    GIF_OK=0
  fi
}

cat_set_pose() {
  want="$1"
  [ -n "$want" ] || return 1
  if ! cat_action_cached "$want"; then
    cat_fetch_action "$want" || {
      log "cat fetch $want failed"
      return 1
    }
  fi
  CAT_CUR="$want"
  CAT_FI=0
  CAT_CHK=0
  cat_load_meta || { log "cat meta $want bad"; return 1; }
  echo "$want" > "$D/cat.pose"
  CAT_SINCE=$(now_ms)
  log "cat action=$want frames=$CAT_N per=${CAT_PER}ms rect=$CAT_RX,$CAT_RY ${CAT_RW}x${CAT_RH}"
  return 0
}

cat_on_screen() {
  [ "$(cat "$D/page.idx" 2>/dev/null)" = "cat" ] || return 1
  [ -n "$CAT_CUR" ] || return 1
  [ "$CAT_N" -gt 0 ] || return 1
  return 0
}

# 贴一帧。小矩形用 A2（不闪屏），大矩形用 GC16（保灰阶）。
# 调用前 CAT_OK 已由 cat_on_screen 置好，这里不再重复查文件（每帧省 10ms）。
cat_show_frame() {
  [ "$CAT_OK" = "1" ] || return 1
  fp="$CAT5/$CAT_CUR/f$CAT_FI.png"
  [ -s "$fp" ] || return 1

  # 面积阈值：超过 12% 屏（约 18 万 px）用 GC16，否则 A2
  # measured on device: GC16 == A2 in speed (23-38ms for every
  # region, incl. full screen), so keep full 16-level greyscale.
  # fbink is called without -f here, so GC16 does not flash black.
  wave=GC16

  if "$FB" -q -g "file=$fp,x=$CAT_RX,y=$((CAT_RY + SHIFT_Y))" -W $wave >/dev/null 2>&1; then
    CAT_FRAMES=$((CAT_FRAMES + 1))
    # 残影清理：A2 每 40 帧、GC16 每 24 帧整屏洗一次基图
    if [ "$wave" = "A2" ]; then ce=40; else ce=24; fi
    if [ $((CAT_FRAMES % ce)) -eq 0 ] && [ -s "$IMGDIR/cat.png" ]; then
      "$FB" -q -g "file=$IMGDIR/cat.png,x=0,y=$SHIFT_Y" -W GC16 >/dev/null 2>&1
    fi
    return 0
  fi
  return 1
}

# 推进一帧。调用者负责按 CAT_PER 控制节奏。
# 性能：每帧只做 fbink + 两次小文件写；cat.fi/cat.blink 每 20 帧才落盘一次
# （只用于调试与状态恢复，掉一两帧无所谓），每帧省 25~30ms。
cat_tick() {
  [ "$CAT_OK" = "1" ] || return 1
  cat_show_frame || return 1
  CAT_FI=$(( (CAT_FI + 1) % CAT_N ))
  CAT_BEAT=$((CAT_BEAT + 1))
  if [ $((CAT_BEAT % 20)) -eq 1 ]; then
    echo "$CAT_FI" > "$D/cat.fi"
    echo "$CAT_BEAT" > "$D/cat.blink"
  fi
  return 0
}

# 一帧只查一次「猫是否在屏上」，结果存 CAT_OK。
# 关键：CAT_CUR/CAT_N/CAT_RX 是 shell 变量，每个进程一份。
# 菜单或 `carousel.sh catnext` 在别的进程里换了姿势并贴了新基图，
# 本进程若不同步，就会拿旧动作的帧贴到新基图上 —— 表现为
# 「尾巴还是不动」「新猫身上嵌一只旧眼睛」。所以必须定期核对 cat.pose。
cat_probe() {
  if [ "$(cat "$D/page.idx" 2>/dev/null)" = "cat" ]; then
    CAT_OK=1
  else
    CAT_OK=0
  fi
  [ "$CAT_OK" = "1" ] || return 0

  # 每 8 tick 核对一次磁盘上的姿势（一次 cat 约 10ms，摊薄后每帧 1ms）
  CAT_CHK=$((CAT_CHK + 1))
  if [ $((CAT_CHK % 8)) -eq 0 ]; then
    disk=$(cat "$D/cat.pose" 2>/dev/null | tr -d '\r\n')
    if [ -n "$disk" ] && [ "$disk" != "$CAT_CUR" ]; then
      log "cat pose drift: mem=[$CAT_CUR] disk=[$disk], resync"
      CAT_CUR="$disk"
      CAT_FI=0
      CAT_BEAT=0
      if ! cat_load_meta; then
        CAT_N=0
        CAT_OK=0
        return 0
      fi
    fi
  fi

  [ -n "$CAT_CUR" ] && [ "$CAT_N" -gt 0 ] || CAT_OK=0
  return 0
}

# 换下一个动作
cat_next_pose() {
  [ -z "$CAT_ACTIONS" ] && return 1
  nxt=""
  prev=""
  for a in $CAT_ACTIONS; do
    [ "$prev" = "$CAT_CUR" ] && nxt="$a"
    prev="$a"
  done
  [ -z "$nxt" ] && nxt=$(echo $CAT_ACTIONS | cut -d' ' -f1)
  cat_set_pose "$nxt" || return 1
  # 换动作时整屏 GC16，洗掉上一个动作的残影
  if [ -s "$IMGDIR/cat.png" ]; then
    "$FB" -q -g "file=$IMGDIR/cat.png,x=0,y=$SHIFT_Y" -W GC16 >/dev/null 2>&1
  fi
  band_md5 > "$GUARD_REF"
  rm -f "$GUARD_BAD"
  return 0
}

render_one() {
  idx="$1"
  # 显式页名必须在 set -- 之前存下来：set -- 会覆盖 $1/$2，
  # 之前 $2 被换成 PAGES 的第 2 项，导致「按页名 pin」永远渲染成 weather。
  want_page="$2"
  set -- $PAGES
  total=$#
  [ "$total" -lt 1 ] && return 1
  if [ -n "$want_page" ]; then
    # 显式指定页（pin 用），不按 idx 推
    page="$want_page"
  else
    pick=$(( idx % total + 1 ))
    page=$(echo $PAGES | cut -d' ' -f"$pick")
  fi

  # 带日期的页：如果它上次渲染的日期不是今天，就需要重渲。
  # 不能只靠 interval 轮播——轮播回来时图还是昨天的，格子就不会变黑。
  need_render=1
  for dp in $DATED_PAGES; do
    if [ "$page" = "$dp" ]; then
      if [ -f "$D/stamp.$page" ] && [ "$(cat "$D/stamp.$page" 2>/dev/null)" = "$(date +%F)" ]; then
        need_render=0
      fi
    fi
  done

  if [ "$need_render" -eq 0 ]; then
    log "skip $page (already rendered $(date +%F))"
    if [ -s "$IMGDIR/$page.png" ]; then
      # 必须把页码记下来：guard 的 repaint() 靠 page.idx 决定重画哪张，
      # 漏写会让状态栏重绘时用上一页的图把我们盖掉。
      page_idx_write "$page"
      "$FB" -q -g "file=$IMGDIR/$page.png,x=0,y=$SHIFT_Y" -W GC16 >/dev/null 2>&1
      keepawake
      band_md5 > "$GUARD_REF"
      rm -f "$GUARD_BAD"
      return 0
    fi
  fi

  netfix
  t0=$(date +%s)
  log "render $page idx=$idx"
  # lifeweeks 不走 dash.sh：它没有设备侧渲染器（设备无 python），
  # 而且往 dash.sh 里加分支还得重新推送那个 30KB 脚本。
  # 直接向 PC 的 bridge 要 PNG，拿到就上屏，拿不到保留旧图。
  if [ "$page" = "lifeweeks" ]; then
    url="http://$PCIP:8899/lifeweeks?d=$(date +%F)"
    if curl -s --max-time 25 -o "$IMGDIR/lifeweeks.png.tmp" "$url" \
       && [ -s "$IMGDIR/lifeweeks.png.tmp" ] \
       && [ "$(wc -c < "$IMGDIR/lifeweeks.png.tmp")" -gt 4000 ]; then
      mv -f "$IMGDIR/lifeweeks.png.tmp" "$IMGDIR/lifeweeks.png"
      page_idx_write "lifeweeks"
      "$FB" -q -g "file=$IMGDIR/lifeweeks.png,x=0,y=$SHIFT_Y" -W GC16 >/dev/null 2>&1
      rc=$?
      log "lifeweeks fetched $url $(wc -c < "$IMGDIR/lifeweeks.png")B fbink_rc=$rc"
    else
      rc=1
      rm -f "$IMGDIR/lifeweeks.png.tmp"
      log "lifeweeks fetch failed $url"
      [ -s "$IMGDIR/lifeweeks.png" ] && \
        "$FB" -q -g "file=$IMGDIR/lifeweeks.png,x=0,y=$SHIFT_Y" -W GC16 >/dev/null 2>&1
    fi
    keepawake
    band_md5 > "$GUARD_REF"
    rm -f "$GUARD_BAD"
    [ "$rc" -eq 0 ] && date +%F > "$D/stamp.$page"
    log "render $page rc=$rc $(( $(date +%s) - t0 ))s"
    return $rc
  fi

  # 猫咪页：和 lifeweeks 同理，设备侧没有渲染器，向 bridge 要 PNG。
  # 猫图不随日期变，所以不写 stamp；拿不到就保留旧图，别把用户停空白页。
  if [ "$page" = "cat" ]; then
    # 首次进入或动作清单还没拿到：先问 PC 有哪些动作
    [ -z "$CAT_ACTIONS" ] && fetch_cat_list
    # 续接上次停留的动作，翻页回来不要每次都从第一个动作开始
    if [ -z "$CAT_CUR" ]; then
      saved=$(cat "$D/cat.pose" 2>/dev/null)
      case " $CAT_ACTIONS " in
        *" $saved "*) [ -n "$saved" ] && cat_set_pose "$saved" ;;
      esac
      [ -z "$CAT_CUR" ] && cat_set_pose "$(echo $CAT_ACTIONS | cut -d' ' -f1)"
    fi
    # 基图必须是 cat5 版（旧 AI 插画猫会让屏上出现两只猫）
    # 用 cat6.base 标记版本：没有标记或标记不符就重拉
    if [ ! -s "$IMGDIR/cat.png" ] || [ "$(cat "$D/cat6.base" 2>/dev/null)" != "v6" ]; then
      if cat_fetch_base; then
        echo v5 > "$D/cat6.base"
        log "cat5 base fetched $(wc -c < "$IMGDIR/cat.png")B"
      else
        log "cat5 base fetch failed"
      fi
    fi
    # 帧序号回到 0，避免用上一轮的位置贴新基图
    echo 0 > "$D/cat.fi"
    CAT_FI=0
    CAT_BEAT=0
    if [ -n "$CAT_CUR" ] && [ -s "$IMGDIR/cat.png" ]; then
      page_idx_write "cat"
      "$FB" -q -g "file=$IMGDIR/cat.png,x=0,y=$SHIFT_Y" -W GC16 >/dev/null 2>&1
      rc=$?
      log "cat shown pose=$CAT_CUR $(wc -c < "$IMGDIR/cat.png")B fbink_rc=$rc"
    else
      rc=1
      log "cat pose unavailable"
    fi
    keepawake
    band_md5 > "$GUARD_REF"
    rm -f "$GUARD_BAD"
    log "render $page rc=$rc $(( $(date +%s) - t0 ))s"
    return $rc
  fi

  # GIF 展示页：和 lifeweeks 同理，设备侧只负责上屏。
  # 先上静态背景（含标题/说明/相框），之后主循环只刷动画矩形。
  if [ "$page" = "gifpage" ]; then
    gif_fetch
    if gif_cached; then
      GIF_FI=0
      GIF_FRAMES=0
      page_idx_write "gifpage"
      "$FB" -q -g "file=$GIF_DIR/bg.png,x=0,y=$SHIFT_Y" -W GC16 >/dev/null 2>&1
      rc=$?
      log "gifpage shown n=$GIF_N per=${GIF_PER}ms rect=$GIF_RX,$GIF_RY ${GIF_RW}x${GIF_RH} rc=$rc"
    else
      rc=1
      log "gifpage assets unavailable"
    fi
    keepawake
    band_md5 > "$GUARD_REF"
    rm -f "$GUARD_BAD"
    log "render $page rc=$rc $(( $(date +%s) - t0 ))s"
    return $rc
  fi

  sh "$SH" once "$page" >>"$LOG" 2>&1
  rc=$?
  log "render $page rc=$rc $(( $(date +%s) - t0 ))s"
  [ "$rc" -eq 0 ] && date +%F > "$D/stamp.$page"
  # dash.sh leaves preventSS at 1 after rendering; hand the sleep right back.
  keepawake
  band_md5 > "$GUARD_REF"
  rm -f "$GUARD_BAD"
  return $rc
}

do_loop() {
  interval="$1"
  case "$interval" in ''|*[!0-9]*) interval=900 ;; esac
  [ "$interval" -lt 30 ] && interval=30

  keepawake
  log "loop start interval=${interval}s awake=$(cat "$AWAKEF" 2>/dev/null || echo off)"

  idx=0
  while [ -f "$ON" ]; do
    render_one "$idx"
    echo "$idx" > "$IDXF"
    idx=$((idx + 1))

    # split sleep: check the stop flag every 5s, re-assert sleep state each tick
    n=0
    guard_acc=0
    next_blink=$(cat "$D/cat.nextblink" 2>/dev/null)
    case "$next_blink" in ''|*[!0-9]*) next_blink=0 ;; esac
    next_gif=0
    while [ "$n" -lt "$interval" ]; do
      [ -f "$ON" ] || break
      # 采样粒度要跟动作走。meta 里的 period 是 1~4 秒：
      # 粒度必须 ≤ 半个换帧间隔，否则帧会被跳过、动作看着一顿一顿。
      # 猫页：tick = CAT_PER/2（下限 80ms，上限 600ms）；非猫页：5 秒。
      cat_probe
      cat_here=$CAT_OK
      gif_probe
      gif_here=$GIF_OK
      if [ "$cat_here" -eq 1 ]; then
        tick_ms=$(( CAT_PER / 2 ))
        [ "$tick_ms" -lt 45 ] && tick_ms=45
        [ "$tick_ms" -gt 600 ] && tick_ms=600
      elif [ "$gif_here" -eq 1 ]; then
        tick_ms=$(( GIF_PER / 2 ))
        [ "$tick_ms" -lt 40 ] && tick_ms=40
        [ "$tick_ms" -gt 600 ] && tick_ms=600
      else
        tick_ms=5000
      fi
      napsleep $tick_ms
      n=$((n + (tick_ms + 999) / 1000))
      # keepawake 里是两次 lipc（实测 44ms+30ms），每帧调用会把帧率压到 1/3。
      # 常亮状态不会几百毫秒就变，30 秒确认一次足够。
      if [ "$cat_here" -eq 1 ]; then ka_acc=$((ka_acc + tick_ms)); else ka_acc=30000; fi
      if [ "$ka_acc" -ge 30000 ]; then
        ka_acc=0
        keepawake
      fi
      # guard 内部有自己的 5 秒限速，但它在限速之前就要 lipc 取 activeApp。
      # 细粒度下别每跳都去 fork，按 5 秒累计调一次。
      guard_acc=$((guard_acc + tick_ms))
      if [ "$guard_acc" -ge 5000 ]; then
        guard_acc=0
        guard
      fi
      # 猫在屏上就按动画自己的节奏推进帧；翻到别的页自然就停
      if [ "$cat_here" -eq 1 ]; then
        now_s=$(now_ms)
        if [ "$next_blink" -eq 0 ] || [ "$now_s" -ge "$next_blink" ]; then
          # 推进一帧。节奏由 anim.txt 的 per（毫秒）决定：
          # 眨眼 150ms、摇尾 260ms、抖耳 190ms、呼吸 1200ms、哈欠 420ms。
          cat_tick
          # 本动作演够 CAT_HOLD 毫秒就换下一个动作
          el=$(( now_s - CAT_SINCE ))
          if [ "$CAT_SINCE" -gt 0 ] && [ "$el" -ge "$CAT_HOLD" ]; then
            cat_next_pose && log "cat switched to $CAT_CUR after $((el / 1000))s"
          fi
          # next_blink 只在 shell 里维护，不再每帧写盘（每帧省 10ms）
          next_blink=$(( now_s + CAT_PER ))
        fi
      else
        next_blink=0
      fi
      # GIF 展示页：与猫页互斥，只在自己该占屏时推进帧
      gif_probe
      if [ "$GIF_OK" = "1" ]; then
        now_g=$(now_ms)
        if [ "$next_gif" -eq 0 ] || [ "$now_g" -ge "$next_gif" ]; then
          gif_tick
          next_gif=$(( now_g + GIF_PER ))
        fi
      else
        next_gif=0
      fi
      if [ $((n % 60)) -eq 0 ]; then
        netfix
      fi
    done
  done

  rm -f "$PIDF"
  log "loop exit"
}

case "$1" in
  start)
    if alive; then
      echo "already running pid=$(cat "$PIDF")"
      exit 0
    fi
    rm -f "$PIDF"
    touch "$ON"
    keepawake
    nohup sh "$0" _loop "${2:-900}" </dev/null >>"$LOG" 2>&1 &
    echo $! > "$PIDF"
    sleep 2
    if alive; then
      echo "started pid=$(cat "$PIDF") interval=${2:-900} awake=$(cat "$AWAKEF" 2>/dev/null || echo off)"
    else
      echo "FAILED to start"
      rm -f "$ON"
      exit 1
    fi
    ;;
  _loop)
    do_loop "$2"
    ;;
  next)
    # 按页名环推进，和 touchd 的 next_page 保持同一套顺序。
    # 之前用 idx 计数器，会和点击翻页的结果对不上（点完再 next 会跳页）。
    cur=$(normalize_page "$(cat "$D/page.idx" 2>/dev/null)")
    nxt=""
    prev=""
    for pg in $PAGES; do
      [ "$prev" = "$cur" ] && nxt="$pg"
      prev="$pg"
    done
    [ -z "$nxt" ] && nxt=$(echo $PAGES | cut -d' ' -f1)
    render_one 0 "$nxt" >/dev/null 2>&1
    page_idx_write "$nxt"
    echo "rendered $nxt"
    ;;
  pin)
    # 钉住单页：不轮播，但保留守护进程。
    # 为什么需要它：仪表盘只是画在 framebuffer 上的像素，没有守护进程时
    # 框架自己的状态栏一重绘就把整页盖掉，看起来就像「点了没反应」。
    page="$2"
    # 白名单不单独维护：PAGES 是唯一事实来源，否则新加页面必然漏改
    case " $PAGES " in
      *" $page "*) ;;
      *) echo "usage: $0 pin $PAGES"; exit 1 ;;
    esac
    if alive; then
      kill "$(cat "$PIDF")" 2>/dev/null
      sleep 1
      kill -9 "$(cat "$PIDF")" 2>/dev/null
    fi
    rm -f "$PIDF"
    touch "$ON"
    keepawake
    nohup sh "$0" _pin "$page" </dev/null >>"$LOG" 2>&1 &
    echo $! > "$PIDF"
    sleep 2
    if alive; then
      echo "pinned page=$page pid=$(cat "$PIDF")"
    else
      echo "FAILED to pin"; rm -f "$ON"; exit 1
    fi
    ;;
  _pin)
    page="$2"
    log "pin start page=$page"
    page_idx_write "$page"
    # 猫页启动前先把 cat5 基图落好，否则第一屏会是旧 AI 猫
    if [ "$page" = "cat" ]; then
      if [ ! -s "$IMGDIR/cat.png" ] || [ "$(cat "$D/cat6.base" 2>/dev/null)" != "v6" ]; then
        mkdir -p "$IMGDIR"
        if cat_fetch_base; then
          echo v5 > "$D/cat6.base"
          log "cat5 base fetched at pin $(wc -c < "$IMGDIR/cat.png")B"
        fi
      fi
    fi
    keepawake
    while [ -f "$ON" ]; do
      # 用户明确要求看 KUAL 菜单时让位（act_kual.sh 建这个标记，
      # 菜单显示出来后由 act_dash.sh 删掉）。不靠 activeApp 判断：
      # 仪表盘只是 framebuffer 上的像素，画上去后 activeApp 一直是
      # kindlelauncher，用它会让我们永远不画，用户就点不进仪表盘了。
      if [ -f "$D/want_kual" ]; then
        sleep 3
        keepawake
        continue
      fi
      # 跟随 page.idx 而不是死钉初始页：touchd 翻页会改 page.idx，
      # 若这里仍按 $page 重画，点击翻走后一分钟就被强行拉回来。
      raw=$(cat "$D/page.idx" 2>/dev/null)
      cur=$(normalize_page "$raw")
      if [ -z "$cur" ]; then
        cur="$page"; page_idx_write "$page"
      elif [ "$cur" != "$raw" ]; then
        # 读到的可能是 dash.sh 留下的数字，改回页名免得 repaint 再被卡
        page_idx_write "$cur"
      fi
      # 猫页必须先确认动作已就绪（cat.pose / 补丁 / meta 都在），
      # 否则不能走"已有图就直接上屏"的快路径，否则动作永远初始化不了。
      if [ "$cur" = "cat" ]; then
        if [ -z "$CAT_ACTIONS" ]; then
          fetch_cat_list
        fi
        if [ -z "$CAT_CUR" ]; then
          saved=$(cat "$D/cat.pose" 2>/dev/null)
          case " $CAT_ACTIONS " in
            *" $saved "*) [ -n "$saved" ] && cat_set_pose "$saved" ;;
          esac
          [ -z "$CAT_CUR" ] && cat_set_pose "$(echo $CAT_ACTIONS | cut -d' ' -f1)"
        fi
        if [ -n "$CAT_CUR" ] && [ -s "$IMGDIR/cat.png" ]; then
          "$FB" -q -g "file=$IMGDIR/cat.png,x=0,y=$SHIFT_Y" -W GC16 >/dev/null 2>&1
          page_idx_write "cat"
          band_md5 > "$GUARD_REF"
          rm -f "$GUARD_BAD"
          log "pin cat pose=$CAT_CUR"
        else
          log "pin cat pose failed, keep previous frame"
        fi
      elif [ "$cur" = "gifpage" ]; then
        # GIF 页用 gifpage/bg.png，不走 $IMGDIR/$cur.png 的命名约定，
        # 所以必须单独一条分支，否则会被当成"缺图"反复 render。
        gif_fetch
        if gif_cached; then
          "$FB" -q -g "file=$GIF_DIR/bg.png,x=0,y=$SHIFT_Y" -W GC16 >/dev/null 2>&1
          page_idx_write "gifpage"
          band_md5 > "$GUARD_REF"
          rm -f "$GUARD_BAD"
          log "pin gifpage n=$GIF_N per=${GIF_PER}ms"
        else
          log "pin gifpage assets missing"
        fi
      elif [ ! -s "$IMGDIR/$cur.png" ]; then
        render_one 0 "$cur"
        page_idx_write "$cur"
      else
        "$FB" -q -g "file=$IMGDIR/$cur.png,x=0,y=$SHIFT_Y" -W GC16 >/dev/null 2>&1
        page_idx_write "$cur"
        band_md5 > "$GUARD_REF"
        rm -f "$GUARD_BAD"
      fi
      # 看门狗循环：每 5 秒采样顶部条，被盖就重画
      # 但猫页要 1 秒粒度：meta 里的 period 是 1~4 秒，5 秒粒度根本兑现不了，
      # 舔爪（period 1）会被拉成 5 秒以上才动一次，看上去就是「偶尔闪一下」。
      n=0
      guard_acc=0
      nb=$(cat "$D/cat.nextblink" 2>/dev/null)
      case "$nb" in ''|*[!0-9]*) nb=0 ;; esac
      ng=0
      while [ "$n" -lt 60 ]; do
        [ -f "$ON" ] || break
        cat_probe
        cat_here=$CAT_OK
        gif_probe
        gif_here=$GIF_OK
        if [ "$cat_here" -eq 1 ]; then
          tick_ms=$(( CAT_PER / 2 ))
          [ "$tick_ms" -lt 45 ] && tick_ms=45
          [ "$tick_ms" -gt 600 ] && tick_ms=600
        elif [ "$gif_here" -eq 1 ]; then
          tick_ms=$(( GIF_PER / 2 ))
          [ "$tick_ms" -lt 40 ] && tick_ms=40
          [ "$tick_ms" -gt 600 ] && tick_ms=600
        else
          tick_ms=5000
        fi
        napsleep $tick_ms
        n=$((n + (tick_ms + 999) / 1000))
        keepawake
        if [ -f "$D/want_kual" ]; then
          # 用户在看 KUAL 菜单：guard 和眨眼都会画屏，本 tick 全部跳过
          continue
        fi
        guard_acc=$((guard_acc + tick_ms))
        if [ "$guard_acc" -ge 5000 ]; then
          guard_acc=0
          guard
        fi
        # pin 单页时若锁的是猫，同样按动画节奏推进
        if [ "$cat_here" -eq 1 ]; then
          now_s=$(now_ms)
          if [ "$nb" -eq 0 ] || [ "$now_s" -ge "$nb" ]; then
            cat_tick
            el=$(( now_s - CAT_SINCE ))
            if [ "$CAT_SINCE" -gt 0 ] && [ "$el" -ge "$CAT_HOLD" ]; then
              cat_next_pose && log "cat switched to $CAT_CUR after $((el / 1000))s"
            fi
            nb=$(( now_s + CAT_PER ))
          fi
        else
          nb=0
        fi
        gif_probe
        if [ "$GIF_OK" = "1" ]; then
          now_g=$(now_ms)
          if [ "$ng" -eq 0 ] || [ "$now_g" -ge "$ng" ]; then
            gif_tick
            ng=$(( now_g + GIF_PER ))
          fi
        else
          ng=0
        fi
      done
    done
    rm -f "$PIDF"
    log "pin exit"
    ;;
  catnext)
    # 立刻换到下一个猫咪姿势（菜单用）。需要 carousel 在跑。
    [ -z "$CAT_ACTIONS" ] && fetch_cat_list
    saved=$(cat "$D/cat.pose" 2>/dev/null)
    case " $CAT_ACTIONS " in
      *" $saved "*) CAT_CUR="$saved" ;;
      *) CAT_CUR="$(echo $CAT_ACTIONS | cut -d' ' -f1)" ;;
    esac
    if cat_next_pose; then
      echo "cat pose -> $CAT_CUR"
    else
      echo "cat next failed"
    fi
    ;;
  pinwithtouch)
    # pin + touchd：只看一页，但长按仍可退出。
    sh "$0" pin "$2" || exit 1
    # touchd 要等图先出来，否则会因为找不到图而空转
    i=0
    while [ $i -lt 20 ]; do
      [ -s "$IMGDIR/$2.png" ] && break
      i=$((i + 1)); sleep 1
    done
    sh "$D/touchd.sh" start >/dev/null 2>&1
    echo "pinned page=$2 with touch rc=$?"
    ;;
  guard)
    guard
    echo "guard done band=$(cat "$GUARD_REF" 2>/dev/null)"
    ;;
  awake)
    case "$2" in
      on)
        echo on > "$AWAKEF"
        lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null
        echo "awake=on (always on, will not auto screen-off)"
        ;;
      off)
        echo off > "$AWAKEF"
        lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
        echo "awake=off (auto screen-off allowed, preventSS=$(lipc-get-prop com.lab126.powerd preventScreenSaver 2>&1 | head -1))"
        ;;
      *)
        echo "usage: $0 awake on|off"; exit 1
        ;;
    esac
    log "awake=$2"
    ;;
  stop)
    rm -f "$ON"
    if alive; then
      kill "$(cat "$PIDF")" 2>/dev/null
      sleep 1
      kill -9 "$(cat "$PIDF")" 2>/dev/null
    fi
    rm -f "$PIDF"
    sh "$SH" barrestore >/dev/null 2>&1
    # always hand the sleep right back on stop, otherwise the key lock dies
    lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
    echo "stopped (preventSS=$(lipc-get-prop com.lab126.powerd preventScreenSaver 2>&1 | head -1))"
    ;;
  status)
    if alive; then
      echo "running pid=$(cat "$PIDF") idx=$(cat "$IDXF" 2>/dev/null) awake=$(cat "$AWAKEF" 2>/dev/null || echo off)"
    else
      echo "stopped awake=$(cat "$AWAKEF" 2>/dev/null || echo off)"
    fi
    ;;
  *)
    echo "usage: $0 start [interval] | stop | status | next | guard | awake on|off"
    ;;
esac
