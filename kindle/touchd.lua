-- WeatherDash touch daemon
--
-- Lua 5.1: this device has no libc bindings for shell (no ffi, no compiler,
-- evtest has no EVIOCGRAB option), so the raw node is decoded here.
--
-- Why not shell: `od -An -tu1 -w16 < /dev/input/event1 | while read` never
-- fires. od buffers stdout in 4 KB blocks when the consumer is a pipe, and a
-- single tap only produces a dozen 16-byte records, so the block never fills.
--
-- What it cannot do: nothing here can EVIOCGRAB the node, so the tap is still
-- delivered to whatever app sits underneath. We mitigate by repainting our
-- page immediately, which overwrites the stray reaction.
--
-- usage:
--   lua touchd.lua                  run against /dev/input/event1
--   lua touchd.lua /path/node       run against another node
--   lua touchd.lua NODE dry         decide but do not paint (for tests)
--   lua touchd.lua --selftest       decode a synthetic tap and report

local D       = "/mnt/us/weatherdash"
local IMGDIR  = "/tmp/weatherdash"
local FB      = "/mnt/us/libkh/bin/fbink"
local SHIFT_Y = 32
local EVNODE  = "/dev/input/event1"
local LOG     = D .. "/touchd.log"

local TAP_MS  = 900    -- down->up within this = tap
local SLOP    = 80     -- and moved less than this many px
local LONG_MS = 1200   -- 按住超过这个 = 全屏重刷
local EXIT_MS = 2500   -- 按住超过这个 = 退出仪表盘
-- Debounce the *flip*, not the press: a real finger tap is 40-150 ms, so
-- gating the press on a lower bound silently swallowed every fast tap.
local DEBOUNCE_MS = 350

local EV_KEY, EV_ABS = 1, 3
local BTN_TOUCH = 330

-- 原始事件留痕。以前靠“开发一个窗口让你现在点”去抓 dd，你不在跟前就白等。
-- 改成常驻记录：每轮触摸的完整事件序列写进 RAWLOG，事后随时可查。
local RAWLOG   = D .. "/touch.raw"
local RAW_KEEP = tonumber(os.getenv("TOUCHD_RAW") or "1") -- 0 = 关闭
local raw_on   = RAW_KEEP ~= 0
local raw_buf  = {}
local raw_open = false
local raw_flush -- 声明在 ts() 之后，否则取不到它（Lua 局部要先声明）

local args = { ... }
local node = args[1] or EVNODE
local dry  = (args[2] == "dry")

--------------------------------------------------------------------- helpers

local function ts()
  local p = io.popen("date -u '+%F %T' 2>/dev/null")
  local s = p and p:read("*l") or "?"
  if p then p:close() end
  return s
end

local function log(msg)
  local f = io.open(LOG, "a")
  if f then f:write(ts(), " ", msg, "\n"); f:close() end
  if dry then print(msg) end
end

raw_flush = function(tag)
  if not raw_on or #raw_buf == 0 then raw_buf = {}; return end
  local f = io.open(RAWLOG, "a")
  if f then
    f:write("-- ", ts(), " ", tag, " n=", #raw_buf, "\n")
    f:write(table.concat(raw_buf, "\n"), "\n")
    f:close()
  end
  raw_buf = {}
end

-- /proc/uptime gives centisecond resolution without forking. The old version
-- ran `date +%s` through io.popen on every down/up, i.e. two fork+exec per tap.
local function now_ms()
  local f = io.open("/proc/uptime", "r")
  if not f then return os.time() * 1000 end
  local line = f:read("*l") or ""
  f:close()
  local s = tonumber(line:match("^(%d+%.?%d*)"))
  if not s then return os.time() * 1000 end
  return math.floor(s * 1000 + 0.5)
end

local function read_first(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*l")
  f:close()
  if not s then return nil end
  return (s:gsub("%s+$", ""))
end

local function write_first(path, val)
  local f = io.open(path, "w")
  if f then f:write(val, "\n"); f:close() end
end

-- 轮播的页顺序。与 carousel.sh 的 PAGES 保持一致；
-- 单改这里不会影响轮播，只影响手指翻页的顺序。
local PAGES = { "calendar", "weather", "lifeweeks", "cat" }

local function page_known(p)
  for _, v in ipairs(PAGES) do
    if v == p then return true end
  end
  return false
end

-- page on screen: our own marker wins, dash.sh's page.idx is the fallback
local function cur_page()
  local p = read_first(D .. "/touchd.cur") or read_first(D .. "/page.idx")
  if p and page_known(p) then return p end
  return PAGES[1]
end

local function next_page(cur)
  for i, v in ipairs(PAGES) do
    if v == cur then
      return PAGES[i % #PAGES + 1]
    end
  end
  return PAGES[1]
end

-- 屏幕可见的点击反馈。
--
-- 用户的原话是"不知道这次显示是我的哪次触发引起的"。要解决它，靠日志没用，
-- 必须在屏幕上留下"这一次"的痕迹。
--
-- 做法：右上角画一个小角标 = 页序号 + 累计点击次数。
-- 用 A2 单色刷新（约 70ms），不拖慢翻页；角标很小，不遮内容。
-- 每次点击数字都会变，所以"哪一下生效了"一眼能对上。
local BADGE_N = D .. "/touchd.n"

local function bump_tap()
  local n = tonumber(read_first(BADGE_N) or "0") or 0
  n = n + 1
  write_first(BADGE_N, tostring(n))
  return n
end

local function page_no(page)
  for i, v in ipairs(PAGES) do
    if v == page then return i end
  end
  return 0
end

-- 一个 5x7 的极简数字点阵，只够画 0-9。设备没有字体也没有 python，
-- 用 fbink 写字要么依赖它的字体参数（版本不一定支持），要么自己画点。
-- 自己画最稳：9 个点一列，纯黑，A2 下最清楚。
local GLYPH = {
  ["0"] = { "01110", "10001", "10011", "10101", "11001", "10001", "01110" },
  ["1"] = { "00100", "01100", "00100", "00100", "00100", "00100", "01110" },
  ["2"] = { "01110", "10001", "00001", "00010", "00100", "01000", "11111" },
  ["3"] = { "11111", "00010", "00100", "00010", "00001", "10001", "01110" },
  ["4"] = { "00010", "00110", "01010", "10010", "11111", "00010", "00010" },
  ["5"] = { "11111", "10000", "11110", "00001", "00001", "10001", "01110" },
  ["6"] = { "00110", "01000", "10000", "11110", "10001", "10001", "01110" },
  ["7"] = { "11111", "00001", "00010", "00100", "01000", "01000", "01000" },
  ["8"] = { "01110", "10001", "10001", "01110", "10001", "10001", "01110" },
  ["9"] = { "01110", "10001", "10001", "01111", "00001", "00010", "01100" },
}

-- 画角标。
--
-- 不能用 fbink 的画字/画框参数：5.16 的 fbink 版本不一定支持 -k -t --atcol
-- 这套，而且"每个像素点 fork 一次"会让一次点击变成十几个进程，反而更慢。
--
-- 改为：PC 侧渲染好角标 PNG，设备只做一次 fbink 贴图。
-- A2 单色，约 70ms，比原来快一个数量级，也不依赖任何高级参数。
local BADGE_CACHE = D .. "/badge"

local function fetch_badge(text)
  -- 文件名里不能有 / 和 #，换成下划线
  local key = text:gsub("[^%w]", "_")
  local fp = BADGE_CACHE .. "_" .. key .. ".png"
  local f = io.open(fp, "rb")
  if f then f:close(); return fp end
  local url = string.format("http://192.168.1.100:8899/badge?t=%s",
                            text:gsub(" ", "%%20"))
  local rc = os.execute(string.format(
    "curl -s --max-time 8 -o '%s' '%s' 2>/dev/null", fp, url))
  local g = io.open(fp, "rb")
  if g then
    local sz = g:seek("end")
    g:close()
    if sz and sz > 200 then return fp end
  end
  os.remove(fp)
  return nil
end

local function badge(text)
  if dry then return end
  local fp = fetch_badge(text)
  if not fp then return end
  -- 右下角贴上去，一次 fbink，A2 快速刷
  os.execute(string.format(
    "%s -q -g 'file=%s,x=%d,y=%d' -W A2 >/dev/null 2>&1",
    FB, fp, 1072 - 200, SHIFT_Y + 6))
end

local function blit(page)
  local img = IMGDIR .. "/" .. page .. ".png"
  local f = io.open(img, "rb")
  if not f then return false, "no image" end
  f:close()
  if dry then return true end
  -- 不再调 disableEnablePillow：已实测该属性对 5.16 无效，
  -- 每次点击白等 200~400ms 只是拖慢翻页。
  local rc = os.execute(string.format(
    "%s -q -g 'file=%s,x=0,y=%d' -W GC16 >/dev/null 2>&1", FB, img, SHIFT_Y))
  if rc ~= 0 and rc ~= true then return false, "fbink rc=" .. tostring(rc) end
  return true
end

local function set_page(page)
  write_first(D .. "/touchd.cur", page)
  write_first(D .. "/page.idx", page)
end

local function flip()
  local cur = cur_page()
  local nxt = next_page(cur)
  local n = bump_tap()
  -- 人生周历的图由 PC 渲染，可能还没拉下来。没有图就先让 carousel 去取，
  -- 不要把用户停在一张空白页上。
  local ok, err = blit(nxt)
  if ok then
    set_page(nxt)
    -- 更新 guard 基准：我们刚画了屏，画面和上一采样不同是预期的。
    -- 不更新的话，最多 5 秒后守护进程会当成"被状态栏盖住"再重画一遍，
    -- 用户就会看到画面莫名又闪一下，分不清是哪次操作生效的。
    os.execute(string.format(
      "dd if=/dev/fb0 bs=1088 skip=%d count=40 2>/dev/null | md5sum | cut -d' ' -f1 > %s/guard.md5 2>/dev/null",
      SHIFT_Y, D))
    os.execute(string.format("date +%%s > %s/page.ts 2>/dev/null; echo touch > %s/page.src 2>/dev/null", D, D))
    -- 屏幕角标：页序号 + 第几次点击，让"这一下有没有生效"能亲眼看到
    badge(string.format("%d/%d #%d", page_no(nxt), #PAGES, n))
    log(string.format("tap#%d -> %s (%d/%d)", n, nxt, page_no(nxt), #PAGES))
    return nxt
  end
  log("tap -> " .. nxt .. " FAILED " .. tostring(err) .. ", rendering")
  if not dry then
    os.execute("sh " .. D .. "/carousel.sh next >/dev/null 2>&1")
    set_page(nxt)
  end
  return nxt
end

local function force_full()
  local cur = cur_page()
  local n = bump_tap()
  if not dry then
    os.execute(FB .. " -q -c -f >/dev/null 2>&1")
    blit(cur)
    badge(string.format("%d/%d #%d R", page_no(cur), #PAGES, n))
  end
  log(string.format("tap#%d long press -> full refresh %s", n, cur))
end

-- 长按退出：仪表盘是画在 framebuffer 上的像素，下面 KPPMainApp 一直活着。
-- 没有 EVIOCGRAB 就根治不了点击穿透，所以给一个不靠 KUAL 的出口：
-- 长按 2.5 秒 = 退出，让框架重新接管屏幕。
local function do_exit()
  log("long press -> EXIT dashboard")
  if dry then return end
  -- 先自杀，否则下面的 restore 刚画完就被我们的 guard 盖回来
  os.execute("sh " .. D .. "/touchd.sh stop >/dev/null 2>&1 &")
  os.execute("sh " .. D .. "/dashboard.sh exit >/dev/null 2>&1")
  os.exit(0)
end

--------------------------------------------------------------- event decode

-- struct input_event, 32-bit ARM, little endian, 16 bytes:
--   [1..4] tv_sec  [5..8] tv_usec  [9..10] type  [11..12] code  [13..16] value
local function u16(s, i)
  local a, b = s:byte(i, i + 1)
  if not a then return nil end
  return a + b * 256
end

local function u32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  if not a then return nil end
  return a + b * 256 + c * 65536 + d * 16777216
end

-- state machine shared by the daemon and the self test
local function new_parser()
  local st = { down = false, tdown = 0, x = nil, y = nil,
               x0 = nil, y0 = nil, last = 0 }

  function st.feed(t, c, v)
    -- 留痕：只记我们关心的事件，够还原一次触摸的全貌
    if raw_on then
      if t == EV_KEY and c == BTN_TOUCH then
        raw_buf[#raw_buf + 1] = string.format("BTN_TOUCH %d", v)
        raw_open = true
      elseif t == EV_ABS then
        if raw_open or c == 53 or c == 54 then
          raw_buf[#raw_buf + 1] = string.format("ABS %d %d", c, v)
          raw_open = true
        end
      end
    end

    if t == EV_KEY and c == BTN_TOUCH then
      if v == 1 then
        -- cyttsp4_mt reports BTN_TOUCH *before* the first coordinate, so any
        -- x/y still cached here belong to the previous touch. Dropping them
        -- and anchoring on the first ABS after this point is the whole fix:
        -- without it the "start" is the old finger position, the computed
        -- travel is hundreds of px, and every real tap is rejected as a swipe.
        st.down, st.tdown = true, now_ms()
        st.x, st.y, st.x0, st.y0 = nil, nil, nil, nil
      elseif v == 0 and st.down then
        st.down = false
        local t1 = now_ms()
        local dt = t1 - st.tdown
        local x1, y1 = st.x or st.x0, st.y or st.y0
        local xa, ya = st.x0 or st.x, st.y0 or st.y
        raw_buf[#raw_buf + 1] = string.format(
          "# up dt=%d x=%s y=%s x0=%s y0=%s", dt,
          tostring(st.x), tostring(st.y), tostring(st.x0), tostring(st.y0))
        if not (x1 and y1 and xa and ya) then
          log("incomplete tap ignored (no coordinates)")
          raw_flush("incomplete")
          return nil, "incomplete"
        end
        local dx = math.abs(x1 - xa)
        local dy = math.abs(y1 - ya)
        if dt <= TAP_MS and dx <= SLOP and dy <= SLOP then
          -- swallow a second tap that lands while the screen is still settling
          if DEBOUNCE_MS > 0 and st.last > 0 and (t1 - st.last) < DEBOUNCE_MS then
            log(string.format("tap debounced (%dms since last)", t1 - st.last))
            raw_flush("debounced")
            return nil, "debounced"
          end
          st.last = t1
          raw_flush(string.format("tap d=%d,%d dt=%d", dx, dy, dt))
          return flip(), "tap"
        elseif dt >= EXIT_MS and dx <= SLOP and dy <= SLOP then
          st.last = t1
          raw_flush(string.format("exit dt=%d", dt))
          do_exit()
          return "exit", "exit"
        elseif dt >= LONG_MS and dx <= SLOP and dy <= SLOP then
          st.last = t1
          raw_flush(string.format("long dt=%d", dt))
          return force_full(), "long"
        else
          log(string.format("swipe ignored dt=%d d=%d,%d at=%d,%d",
                            dt, dx, dy, xa, ya))
          raw_flush(string.format("swipe d=%d,%d dt=%d", dx, dy, dt))
          return nil, "swipe"
        end
      end
    elseif t == EV_ABS then
      if c == 53 then
        st.x = v
        if not st.x0 then st.x0 = v end
      elseif c == 54 then
        st.y = v
        if not st.y0 then st.y0 = v end
      end
    end
    return nil
  end
  return st
end

local function decode_file(fh, st)
  local n = 0
  while true do
    local ev = fh:read(16)
    if not ev then break end
    if #ev == 16 then
      local t = u16(ev, 9)
      local c = u16(ev, 11)
      local v = u32(ev, 13)
      if t and c and v then
        if v > 2147483647 then v = v - 4294967296 end
        st.feed(t, c, v)
        n = n + 1
      end
    end
  end
  return n
end

------------------------------------------------------------------- selftest

local function le32(n)
  return string.char(n % 256, math.floor(n / 256) % 256,
                     math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function evrec(t, c, v)
  return le32(0) .. le32(0) .. string.char(t % 256, math.floor(t / 256)) ..
         string.char(c % 256, math.floor(c / 256)) .. le32(v < 0 and (v + 4294967296) or v)
end

local function selftest()
  local function write_fixture(path, records)
    local fx = io.open(path, "wb")
    for _, r in ipairs(records) do fx:write(r) end
    fx:close()
  end

  local function run_fixture(path)
    local st = new_parser()
    local fh = io.open(path, "rb")
    local n = decode_file(fh, st)
    fh:close()
    return n
  end

  -- Fixtures below replay the *real* cyttsp4_mt order captured from
  -- /dev/input/event1: BTN_TOUCH first, coordinates only afterwards. The
  -- earlier fixtures put coordinates first, which is precisely why the
  -- start-anchor bug slipped through the tests.
  local function tap(x, y)
    return { evrec(EV_KEY, BTN_TOUCH, 1), evrec(0, 0, 0),
             evrec(EV_ABS, 53, x), evrec(EV_ABS, 54, y), evrec(0, 0, 0),
             evrec(EV_KEY, BTN_TOUCH, 0), evrec(0, 0, 0) }
  end

  local fails = 0
  local function check(name, want, got)
    local ok = (want == got)
    print(string.format("  [%s] %-24s want=%s got=%s",
                        ok and "PASS" or "FAIL", name, tostring(want), tostring(got)))
    if not ok then fails = fails + 1 end
  end

  print("--- selftest (dry, no painting) ---")

  -- 自检用的是伪造事件，绝不能写进 touch.raw，否则真机日志里会掺着
  -- 540,586 这种固定坐标，排查时根本分不清哪条是真人点的。
  raw_on = false

  -- 1. tap in the real driver order flips calendar -> weather
  write_first(D .. "/touchd.cur", "calendar")
  local fx = "/tmp/touchd_tap.bin"
  write_fixture(fx, tap(540, 586))
  check("decoded_events", 7, run_fixture(fx))
  check("tap_real_order", "weather", cur_page())

  -- 2. two more taps walk the whole ring and come back: 3 pages, not 2
  write_first(D .. "/touchd.cur", "weather")
  run_fixture(fx)
  check("page_after_2nd_tap", "lifeweeks", cur_page())

  write_first(D .. "/touchd.cur", "lifeweeks")
  run_fixture(fx)
  check("page_wraps_to_first", "calendar", cur_page())

  -- 2b. every page must be reachable and the ring must close;
  -- catches a ring with a dead slot or one that stops on the last page.
  write_first(D .. "/touchd.cur", "calendar")
  local seen, cur = {}, "calendar"
  for _ = 1, #PAGES do
    cur = next_page(cur)
    seen[#seen + 1] = cur
  end
  local uniq, n = {}, 0
  for _, v in ipairs(seen) do
    if not uniq[v] then uniq[v] = true; n = n + 1 end
  end
  check("ring_visits_every_page", #PAGES, n)
  check("ring_returns_to_start", "calendar", seen[#seen])

  -- 3. finger travelling >80px is a swipe, not a tap
  write_first(D .. "/touchd.cur", "calendar")
  local sw = "/tmp/touchd_swipe.bin"
  write_fixture(sw, {
    evrec(EV_KEY, BTN_TOUCH, 1), evrec(0, 0, 0),
    evrec(EV_ABS, 53, 500), evrec(EV_ABS, 54, 900), evrec(0, 0, 0),
    evrec(EV_ABS, 53, 900), evrec(EV_ABS, 54, 900), evrec(0, 0, 0),
    evrec(EV_KEY, BTN_TOUCH, 0), evrec(0, 0, 0) })
  run_fixture(sw)
  check("swipe_ignored", "calendar", cur_page())

  -- 4. a press with no coordinates at all must be rejected, not crash
  write_first(D .. "/touchd.cur", "calendar")
  local nc = "/tmp/touchd_nocoord.bin"
  write_fixture(nc, { evrec(EV_KEY, BTN_TOUCH, 1), evrec(0, 0, 0),
                      evrec(EV_KEY, BTN_TOUCH, 0), evrec(0, 0, 0) })
  run_fixture(nc)
  check("no_coord_rejected", "calendar", cur_page())

  -- 5. the -1 release burst must not wrap into a huge coordinate
  write_first(D .. "/touchd.cur", "weather")
  local neg = "/tmp/touchd_neg.bin"
  write_fixture(neg, { evrec(EV_KEY, BTN_TOUCH, 1), evrec(0, 0, 0),
                       evrec(EV_ABS, 53, 538), evrec(EV_ABS, 54, 584),
                       evrec(EV_ABS, 57, -1), evrec(0, 0, 0),
                       evrec(EV_KEY, BTN_TOUCH, 0), evrec(0, 0, 0) })
  run_fixture(neg)
  check("neg_value_no_wrap", "lifeweeks", cur_page())

  -- 6. 长按分级必须严格递增，否则「退出」会被「全刷」或「点击」提前吃掉。
  -- 具体毫秒分支靠真机验证（dt 来自 /proc/uptime，dry 下造不出真实间隔）。
  check("thresholds_ordered", "true",
        tostring(EXIT_MS > LONG_MS and LONG_MS > TAP_MS))

  print("--- " .. (fails == 0 and "ALL PASS" or (fails .. " FAILED")) .. " ---")
  return fails
end

---------------------------------------------------------------------- entry

if args[1] == "--selftest" then os.exit(selftest()) end

local fh = io.open(node, "rb")
if not fh then
  log("FATAL cannot open " .. tostring(node))
  os.exit(1)
end

log("touchd start node=" .. node .. (dry and " dry" or ""))

local st = new_parser()
while true do
  local ev = fh:read(16)
  if not ev then break end
  if #ev == 16 then
    local t = u16(ev, 9)
    local c = u16(ev, 11)
    local v = u32(ev, 13)
    if t and c and v then
      if v > 2147483647 then v = v - 4294967296 end
      st.feed(t, c, v)
    end
  end
end
fh:close()
log("touchd loop exit (node closed)")
