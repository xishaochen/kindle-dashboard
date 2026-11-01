# Kindle PW3 WiFi 排查与快速修复手册

> 这份文档记录 2026-11-01 整晚排查的结果。当晚的核心问题用了 **6 小时** 才定位，
> 根因只有一个字符的差别（`ap_scan=2` → `ap_scan=1`）。
>
> **下次 WiFi 连不上，先跳到「三、三分钟自查」，不要从第一节读起。**

---

## 零、一分钟结论（先看这个）

如果 WiFi 连不上，按顺序做这三件事，能解决 90% 的情况：

```
1. KUAL → 📶 启动 WiFi         （等 60 秒）
2. KUAL → 🔧 WiFi 一键修复      （等 90 秒）
3. 还不行 → KUAL → 🔍 WiFi 诊断  （插 USB 读日志）
```

**绝对不要做的三件事：**

| 禁止 | 原因 |
|---|---|
| 改 WiFi 密码 / 重新输入密码 | 密码几乎从来不是原因。关联阶段就被拒时，密码根本没参与验证 |
| `initctl stop wifim` / `stop wifis` | 会让 `wlan0` 整个消失，且停用状态保留到重启 |
| 用 `iwconfig wlan0` 查看状态 | 本驱动不支持 WEXT，恒返回 `no wireless extensions.` |

---

## 一、唯一根因：`ap_scan` 必须是 1

### 症状对照表

| `ap_scan` | 日志表现 | 结果 |
|---|---|---|
| **2** ❌ | `CTRL-EVENT-ASSOC-REJECT status_code=1`<br>`Added BSSID 00:00:00:00:00:00 into blacklist`<br>`WPA: No WPA/RSN IE available` | 关联请求残缺，路由器按标准拒绝 |
| **1** ✅ | `bss\| bssid=44:f7:70:fe:fd:72`<br>`WPA: set AP RSN IE - hexdump(len=22): 30 14 01 00 ...`<br>`WPA: RX message 1 of 4-Way Handshake from 44:f7:70:fe:fd:72`<br>`state=[COMPLETED]` | 一次成功 |

### 原理

`nl80211` 驱动下：

- `ap_scan=2` = 「不扫描，直接定向关联」。但 `wpa_supplicant` **必须先有 BSS 缓存**才能构造合法的关联请求。
- 没有 BSS 缓存时，它会退化成一个残废的帧：
  - BSSID 填全零 `00:00:00:00:00:00`
  - 拿不到 AP 的 RSN IE，自己也构造不出来，于是这个 IE 缺失
- 路由器收到这种帧，**只能**回 `status_code=1`（802.11 标准的 "Unspecified failure"）。

**这不是路由器拒绝你，是你发了一个不合法的请求。任何设备这么发都会被拒。**

### 修复

`/mnt/us/weatherdash/agentd7.sh` 的 `write_wconf()` 函数里：

```sh
# 错
echo "ap_scan=2"

# 对
echo "ap_scan=1"
```

并且关联前必须等扫描完成：

```sh
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
```

---

## 二、如何读懂日志：关联失败 vs 密码错误

**这是最容易走错的地方。两者的排查方向完全相反。**

### 情况 A：关联阶段就被拒 → 不是密码问题

```
wlan0: Trying to associate with SSID 'YOUR_SSID'
wlan0: CTRL-EVENT-ASSOC-REJECT status_code=1
```

- `status_code=1` = Unspecified failure
- `status_code=17` = AP 已满（设备数上限）
- **密码在这一步还没参与验证**
- 排查方向：`ap_scan` 设置、BSS 缓存、MAC 过滤、路由器准入控制

### 情况 B：关联成功但握手失败 → 才是密码问题

```
wlan0: Associated with 44:f7:70:fe:fd:72
wlan0: WPA: 4-Way Handshake failed - pre-shared key may be incorrect
wlan0: CTRL-EVENT-DISCONNECTED bssid=... reason=15
```

- `reason=15` = 4-Way Handshake timeout
- `reason=2` = 之前的认证已失效
- **排查方向**：密码错误、加密方式不匹配

### 判断口诀

> **看 `ASSOC-REJECT` 还是 `4-Way Handshake failed`。**
> 前者说明密码连用都没用上，后者才是密码错。

---

## 三、三分钟自查（实际排查顺序）

### 第 1 步：设备是否在线

**不要用 ping。** ICMP 常被拦，ping 不通不代表离线。

```powershell
# PC 侧
Get-Content net\hb.log -Tail 3
```

正常输出：

```
2026-11-01 14:10:55 beat=30 ip=192.168.1.50 ver=rev-7
2026-11-01 14:10:59 beat=31 ip=192.168.1.50 ver=rev-7
```

- `beat` 在涨 = 设备在线且能主动 POST 到 PC ✅
- **注意时区**：`hb.log` 的时间戳是设备 UTC，比北京时间**慢 8 小时**。
  `14:10` 对应本地 `22:10`。别按本地时间误判「刚离线」。

### 第 2 步：PC → 设备方向是否通

```powershell
arp -a | Select-String "74-c2-46"    # 应看到 192.168.1.50
```

有 ARP 条目但 `ping` 不通 = **正常**（ICMP 被拦），不代表有问题。

### 第 3 步：用命令通道实测

```powershell
# 写一条单行命令到 net\cmd.txt，设备每 3 秒拉一次
$cmd = "ifconfig wlan0 | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p'"
[IO.File]::WriteAllText("net\cmd.txt", $cmd + "`n", (New-Object Text.UTF8Encoding($false)))
```

等 12 秒，看 `net\out\` 有没有新文件。

关键限制（踩过坑）：

| 限制 | 说明 |
|---|---|
| **只能单行** | 多行命令会让执行槽卡住，心跳一起停 |
| **最长 300 秒** | `agentd7.sh` 用 `timeout 300 sh "$RUN"`，超时自动杀 |
| **不要用 `eips` 做测试** | 会占用 framebuffer，卡住命令通道 |
| **换行必须是 LF** | 用 `"`n"`，不要 `"`r`n"` |

### 第 4 步：看设备侧状态

```sh
# 通过 cmd.txt 下发
iw dev wlan0 link          # 必须用 iw，不是 iwconfig
cat /sys/class/net/wlan0/address
wpa_cli -i wlan0 -p /var/run/wpa_supplicant status
```

---

## 四、工具选择：哪些能用，哪些不能用

| 工具 | 状态 | 说明 |
|---|---|---|
| `iw dev wlan0 link` | ✅ 用这个 | 唯一可靠的接口状态查询 |
| `iw dev wlan0 scan` | ✅ | 扫描 AP |
| `iw phy` | ✅ | 查网卡支持的频段 |
| `iwconfig wlan0` | ❌ **恒为空** | 驱动只有 nl80211，不支持 WEXT。**之前所有空白日志都是这个原因** |
| `rfkill` | ❌ MISSING | 设备上没有 |
| `ps \| grep '[c]arousel.sh'` | ❌ 会漏判 | busybox `ps` 不含完整路径。用 `cat /proc/<pid>/cmdline` |
| `od` 读 `/dev/input/eventX` | ❌ 永不触发 | od 按 4KB 缓冲，单次点击填不满管道。用 `lua` 的 `f:read(16)` |

---

## 五、抓 `wpa_supplicant` debug 的正确姿势

### 错误写法（debug 会丢）

```sh
wpa_supplicant -B -dd -i wlan0 -c conf -f log    # ❌
```

`-B` 会 fork，**debug 输出全部丢失**，表现为 `pid=[]`、日志 0 字节。

### 正确写法

```sh
timeout 60 wpa_supplicant -dd -i wlan0 -c /tmp/wpa.conf -Dnl80211 >> "$DBG" 2>&1 &
```

用 `&` 后台 + 重定向，再用 `timeout` 兜底。

### 必须 grep 的关键行

```sh
grep -aE 'Trying to associate|RSN IE|ASSOC-REJECT|status_code' dbg.log
grep -aE '4-Way Handshake|CTRL-EVENT-CONNECTED|reason=' dbg.log
grep -aE 'bssid=' dbg.log   # 确认是不是 00:00:00:00:00:00
```

---

## 六、WiFi 服务管理：只能停 wifid

本设备有三个 WiFi 相关服务：

| 服务 | 作用 | 能否停 |
|---|---|---|
| `wifim` | 驱动 | ❌ **绝对不能停** |
| `wifis` | 射频 / supplicant 宿主 | ❌ **绝对不能停** |
| `wifid` | 高层 WiFi 管理守护进程 | ✅ 可以停 |

**用 `initctl list | grep -i wifi` 全部停掉会让 `wlan0` 整个消失**：

```
ifconfig wlan0  -> rc=255
scan_results    -> ap_Xiaomi=0
```

而且停用状态会**一直保留到设备重启**。

### 标准接管流程

```sh
initctl start wifim     # 确保驱动
initctl start wifis     # 确保射频
sleep 2
initctl stop wifid      # 只停这个
killall wifid 2>/dev/null
sleep 1
killall wpa_supplicant 2>/dev/null
sleep 2
rm -f /var/run/wpa_supplicant/wlan0
```

---

## 七、凭据与频段（已确认正确，不用再查）

### 账号密码

```
NETS="YOUR_SSID|YOUR_WIFI_PASSWORD;"
```

与系统 `/etc/wpa_supplicant.conf`（233B）**完全一致**。

### 频段

```
scan_results: 44:f7:70:fe:fd:72  2457  -57  [WPA2-PSK-CCMP][WPS][ESS]  YOUR_SSID
```

- `2457 MHz` = **信道 10，2.4GHz** ✅
- 信号 `-57 dBm`（强）
- `WPA2-PSK-CCMP`，标准加密 ✅

**`YOUR_SSID` 这个名字本身不带 5G 后缀，就是 2.4GHz 频段。**

### AP 信息

```
wps_device_name=XiaoMiRouter
RSN: Version 1, Group CCMP, Pairwise CCMP, Auth PSK
BSS Load: station count: 9        ← 已连 9 台设备
```

---

## 八、屏幕显示注意事项

### `#` 字符不可用

```
eips: paint_char> character "#" not available
```

eips 内置字体没有 `#`。屏幕文案里不要用。

### 状态栏会盖住内容

- 状态栏每约 60 秒重绘一次，会盖住顶部
- 只有第 8 行之后可见
- 单页显示必须配 `carousel.sh pin <page>` 守护进程

### 屏幕休眠会冻结图像

连接 WiFi 期间图像可能冻结，CPU 还在跑，但看到的永远是旧字，容易误判「卡住了」。

```sh
# 开始
lipc-set-prop com.lab126.powerd preventScreenSaver 1

# 结束（只在仪表盘真的在跑时才继续常亮）
if [ -f "$D/carousel.on" ] || [ -f "$D/touchd.on" ]; then
  lipc-set-prop com.lab126.powerd preventScreenSaver 1
else
  lipc-set-prop com.lab126.powerd preventScreenSaver 0
fi
```

### 命令执行会卡住整个守护进程

`agentd7.sh` 主循环是**串行**的：

```sh
494 | ( cd "$D"; timeout 300 sh "$RUN" ) > "$RES" 2>&1
```

命令执行期间**心跳也停**。所以：

- 不要用 `eips`、`cat /dev/fb0` 这类会占住 framebuffer 的命令做测试
- 单条命令最多阻塞 5 分钟
- 看到心跳停了先想想是不是自己刚发的命令卡住了

---

## 九、PC 侧 bridge 服务

`kindle-dashboard\bridge.py`，端口 `8899`。

| 端点 | 方法 | 作用 |
|---|---|---|
| `/hb?b=<beat>&ip=<ip>&v=<ver>` | GET | 设备心跳 |
| `/next` | GET | 设备拉取下一条命令 |
| `/result?rc=<rc>&tag=<tag>` | POST | 设备回传结果 |
| `/upload?name=<name>` | POST | 设备上传文件 |
| `/tool/<name>` | GET | 分发 `kindle/weatherdash-tools/` 下的脚本 |
| `/ping` | GET | 返回 `pong` |

**bridge 进程消失时**，设备会自动重连，用独立进程重启即可。

### 设备 IP / MAC

```
IP  : 192.168.1.50
MAC : AA:BB:CC:DD:EE:FF
PC  : 192.168.1.100:8899
```

---

## 十、完整修复流程图

```
WiFi 连不上
    │
    ├─ 1. KUAL → 📶 启动 WiFi
    │      │
    │      ├─ 成功 ──→ 完成
    │      └─ 失败 ──→ 2
    │
    ├─ 2. KUAL → 🔧 WiFi 一键修复
    │      │   （自动：ap_scan=1 检查 / 停 wifid / 重建 supplicant / 等 BSS）
    │      │
    │      ├─ 成功 ──→ 完成
    │      └─ 失败 ──→ 3
    │
    ├─ 3. KUAL → 🔍 WiFi 诊断（插 USB 读 wifi_diag.out）
    │      │
    │      ├─ ASSOC-REJECT status_code=1  → ap_scan 不是 1，或被 MAC 过滤
    │      ├─ 4-Way Handshake failed      → 密码错了
    │      ├─ bss EMPTY                   → 扫描没完成，BSS 缓存没建起来
    │      ├─ wlan0 MISSING               → 停错服务了，重启设备
    │      └─ scan 找不到 SSID            → AP 关了 / 信号太弱
    │
    └─ 4. 都失败 → 重启设备，回到 1
```

---

## 十一、本次排查的时间线与弯路（教训）

| 时间 | 尝试 | 结果 | 教训 |
|---|---|---|---|
| 20:35 | 放弃「注入 network 到已有 supplicant」 | — | 一直在和能工作的系统栈抢 wlan0 |
| 20:56 | phase 1：让系统栈自己连 | `state=INACTIVE` 45 秒 | 系统栈用的也是 `ap_scan=2` |
| 20:57 | phase 2：接管 | `assoc failed` | 同一个根因 |
| 21:27 | v2 诊断（`iwconfig`） | `no wireless extensions.` | **工具用错了，看了一整晚空字段** |
| 21:35 | v3：换 MAC 测试 | MAC 不可改 | 但暴露了 `BSSID 00:00:00:00:00:00` |
| 21:57 | v4：`ap_scan=1` | ✅ `COMPLETED` + `192.168.1.50` | 根因确认 |

### 三条最重要的教训

1. **看到 `iwconfig` 空白不要以为是「没数据」**，去查这个工具在当前驱动上能不能用。
2. **`ASSOC-REJECT` ≠ 密码错**。密码错永远是握手阶段失败。
3. **一个配置项错，两套方案会一起错**。系统栈和自接管都用 `ap_scan=2`，所以「换个方式再试」试了两次都是同一个坑。

---

## 十二、关键文件位置

| 文件 | 位置 |
|---|---|
| 主守护进程 | `/mnt/us/weatherdash/agentd7.sh` |
| KUAL 菜单 | `/mnt/us/extensions/weatherdash/menu.json` |
| KUAL 动作 | `/mnt/us/extensions/weatherdash/bin/act/` |
| 运行时日志 | `/mnt/us/weatherdash/agent7.log` |
| WiFi 诊断输出 | `/mnt/us/weatherdash/wifi_diag.out` |
| supplicant 配置 | `/tmp/wpa_own.conf` |
| 连接成功标记 | `/mnt/us/weatherdash/wifi.ok` |
| PC 侧服务 | `kindle-dashboard\bridge.py`（端口 8899） |

---

*最后更新：2026-11-01*
