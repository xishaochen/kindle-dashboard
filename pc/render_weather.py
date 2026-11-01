#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Kindle 电子墨水天气仪表盘渲染器

读取 config.json -> 拉取 Open-Meteo 数据 -> 渲染 1072x1448 灰度 PNG
针对 16 级灰度的电子墨水屏优化：高对比、无渐变、避免大面积实心黑。
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone, timedelta

from PIL import Image, ImageDraw, ImageFont

BASE = os.path.dirname(os.path.abspath(__file__))
CFG_PATH = os.path.join(BASE, "config.json")
CACHE_PATH = os.path.join(BASE, "cache_weather.json")

REG = r"C:\Windows\Fonts\msyh.ttc"
BOLD = r"C:\Windows\Fonts\msyhbd.ttc"

BLACK = 0
DARK = 40
MID = 105
LIGHT = 170

_fonts = {}


def F(size, bold=False):
    key = (size, bold)
    if key not in _fonts:
        path = BOLD if bold else REG
        try:
            _fonts[key] = ImageFont.truetype(path, size)
        except Exception:
            _fonts[key] = ImageFont.truetype(r"C:\Windows\Fonts\simhei.ttf", size)
    return _fonts[key]


# ---------------------------------------------------------------- 天气码映射
WMO = {
    0: ("晴", "sun"),
    1: ("晴间多云", "sun_cloud"),
    2: ("多云", "cloud"),
    3: ("阴", "cloud"),
    45: ("雾", "fog"),
    48: ("雾凇", "fog"),
    51: ("毛毛雨", "drizzle"),
    53: ("毛毛雨", "drizzle"),
    55: ("密集毛毛雨", "drizzle"),
    56: ("冻毛毛雨", "drizzle"),
    57: ("冻毛毛雨", "drizzle"),
    61: ("小雨", "rain"),
    63: ("中雨", "rain"),
    65: ("大雨", "rain"),
    66: ("冻雨", "rain"),
    67: ("强冻雨", "rain"),
    71: ("小雪", "snow"),
    73: ("中雪", "snow"),
    75: ("大雪", "snow"),
    77: ("米雪", "snow"),
    80: ("阵雨", "rain"),
    81: ("强阵雨", "rain"),
    82: ("暴雨", "rain"),
    85: ("阵雪", "snow"),
    86: ("强阵雪", "snow"),
    95: ("雷阵雨", "thunder"),
    96: ("雷暴伴冰雹", "thunder"),
    99: ("强雷暴冰雹", "thunder"),
}


def describe(code):
    return WMO.get(int(code), ("未知", "cloud"))


# ---------------------------------------------------------------- 图标绘制
def _box(box):
    x0, y0, x1, y1 = box
    return x0, y0, x1 - x0, y1 - y0


def icon_sun(d, box, fill=BLACK):
    x, y, w, h = _box(box)
    s = min(w, h)
    cx, cy = x + w / 2, y + h / 2
    r = s * 0.26
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=fill)
    lw = max(4, int(s * 0.055))
    for i in range(8):
        import math
        a = math.radians(i * 45)
        r1, r2 = s * 0.36, s * 0.47
        d.line([cx + r1 * math.cos(a), cy + r1 * math.sin(a),
                cx + r2 * math.cos(a), cy + r2 * math.sin(a)], fill=fill, width=lw)


def _cloud_shape(d, x, y, w, h, fill=BLACK):
    """实心云朵：三个圆 + 底部圆角矩形"""
    r1 = h * 0.30
    d.ellipse([x + w * 0.06, y + h * 0.36, x + w * 0.06 + 2 * r1, y + h * 0.36 + 2 * r1], fill=fill)
    r2 = h * 0.40
    d.ellipse([x + w * 0.26, y + h * 0.10, x + w * 0.26 + 2 * r2, y + h * 0.10 + 2 * r2], fill=fill)
    r3 = h * 0.33
    d.ellipse([x + w * 0.58, y + h * 0.28, x + w * 0.58 + 2 * r3, y + h * 0.28 + 2 * r3], fill=fill)
    d.rounded_rectangle([x + w * 0.10, y + h * 0.60, x + w * 0.94, y + h * 0.86],
                        radius=h * 0.13, fill=fill)


def icon_cloud(d, box, fill=BLACK):
    x, y, w, h = _box(box)
    _cloud_shape(d, x, y, w, h * 0.92, fill)


def icon_sun_cloud(d, box, fill=BLACK):
    x, y, w, h = _box(box)
    s = min(w, h)
    icon_sun(d, (x + w * 0.42, y, x + w, y + h * 0.62), fill)
    _cloud_shape(d, x, y + h * 0.30, w * 0.82, h * 0.70, fill)


def _drops(d, x, y, w, h, n=3, fill=BLACK):
    s = min(w, h)
    lw = max(4, int(s * 0.07))
    for i in range(n):
        cx = x + w * (0.22 + 0.28 * i)
        top = y + h * (0.05 + 0.10 * (i % 2))
        d.line([cx, top, cx - s * 0.07, top + h * 0.55], fill=fill, width=lw)


def icon_rain(d, box, fill=BLACK):
    x, y, w, h = _box(box)
    _cloud_shape(d, x, y, w, h * 0.66, fill)
    _drops(d, x, y + h * 0.60, w, h * 0.42, 3, fill)


def icon_drizzle(d, box, fill=BLACK):
    x, y, w, h = _box(box)
    _cloud_shape(d, x, y, w, h * 0.66, fill)
    _drops(d, x, y + h * 0.62, w, h * 0.30, 4, fill)


def icon_snow(d, box, fill=BLACK):
    import math
    x, y, w, h = _box(box)
    _cloud_shape(d, x, y, w, h * 0.62, fill)
    s = min(w, h)
    lw = max(3, int(s * 0.045))
    for i in range(3):
        cx = x + w * (0.24 + 0.26 * i)
        cy = y + h * 0.80
        r = s * 0.075
        for k in range(3):
            a = math.radians(k * 60)
            d.line([cx - r * math.cos(a), cy - r * math.sin(a),
                    cx + r * math.cos(a), cy + r * math.sin(a)], fill=fill, width=lw)


def icon_thunder(d, box, fill=BLACK):
    x, y, w, h = _box(box)
    _cloud_shape(d, x, y, w, h * 0.62, fill)
    d.polygon([(x + w * 0.54, y + h * 0.58), (x + w * 0.36, y + h * 0.88),
               (x + w * 0.50, y + h * 0.88), (x + w * 0.44, y + h * 1.0),
               (x + w * 0.66, y + h * 0.74), (x + w * 0.52, y + h * 0.74),
               (x + w * 0.60, y + h * 0.58)], fill=fill)


def icon_fog(d, box, fill=BLACK):
    x, y, w, h = _box(box)
    s = min(w, h)
    lw = max(5, int(s * 0.075))
    for i in range(4):
        yy = y + h * (0.28 + 0.16 * i)
        ins = w * (0.14 if i % 2 == 0 else 0.02)
        d.line([x + ins, yy, x + w - ins, yy], fill=fill, width=lw)


ICONS = {
    "sun": icon_sun, "cloud": icon_cloud, "sun_cloud": icon_sun_cloud,
    "rain": icon_rain, "drizzle": icon_drizzle, "snow": icon_snow,
    "thunder": icon_thunder, "fog": icon_fog,
}


def draw_icon(img, kind, box, fill=BLACK):
    d = ImageDraw.Draw(img)
    ICONS.get(kind, icon_cloud)(d, box, fill)


# ---------------------------------------------------------------- 数据获取
def load_cfg():
    with open(CFG_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def fetch(cfg):
    params = {
        "latitude": cfg["latitude"],
        "longitude": cfg["longitude"],
        "current": "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,precipitation",
        "hourly": "temperature_2m,weather_code,precipitation_probability",
        "daily": "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset",
        "timezone": cfg.get("timezone", "Asia/Shanghai"),
        "forecast_days": max(4, cfg.get("days_shown", 4) + 1),
        "wind_speed_unit": "ms",
    }
    url = "https://api.open-meteo.com/v1/forecast?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={"User-Agent": "kindle-dashboard/1.0"})
    with urllib.request.urlopen(req, timeout=25) as r:
        data = json.load(r)
    data["_fetched_at"] = datetime.now().isoformat(timespec="seconds")
    with open(CACHE_PATH, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    return data, True


def load_cached():
    if os.path.exists(CACHE_PATH):
        with open(CACHE_PATH, "r", encoding="utf-8") as f:
            return json.load(f), False
    return None, False


# ---------------------------------------------------------------- 渲染
CN_WEEK = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]


def render(cfg, data, stale=False):
    W, H = cfg["width"], cfg["height"]
    img = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(img)
    M = 60

    cur = data["current"]
    hourly = data["hourly"]
    daily = data["daily"]

    tz = timezone(timedelta(hours=data.get("utc_offset_seconds", 28800) / 3600))
    now = datetime.fromisoformat(cur["time"]).replace(tzinfo=tz)

    # ---------- 页眉
    d.text((M, 56), cfg["city"], font=F(56, True), fill=BLACK, anchor="lt")
    d.text((M + d.textlength(cfg["city"], font=F(56, True)) + 22, 78),
           cfg.get("city_sub", ""), font=F(27), fill=MID, anchor="lt")
    d.text((W - M, 64), f"{now.month}月{now.day}日 {CN_WEEK[now.weekday()]}",
           font=F(31), fill=DARK, anchor="rt")
    d.line([M, 152, W - M, 152], fill=BLACK, width=3)

    # ---------- 主区块：当前温度
    t = cur["temperature_2m"]
    big = F(234, True)
    ts = str(int(round(t)))
    d.text((M - 8, 186), ts, font=big, fill=BLACK, anchor="lt")
    deg_x = M - 8 + d.textlength(ts, font=big) + 16
    d.text((deg_x, 200), "°", font=F(118, True), fill=BLACK, anchor="lt")

    # 右侧：图标 + 天气文字（同一中心轴）
    icon_cx = W - M - 118
    draw_icon(img, describe(cur["weather_code"])[1], (icon_cx - 118, 186, icon_cx + 118, 422))
    label = describe(cur["weather_code"])[0]
    d.text((icon_cx, 440), label, font=F(62 if len(label) <= 2 else 50, True),
           fill=BLACK, anchor="mt")
    d.text((icon_cx, 522), f"体感 {cur['apparent_temperature']:.0f}°",
           font=F(34), fill=DARK, anchor="mt")

    # 左下三列细节
    dets = [
        ("湿度", f"{cur['relative_humidity_2m']:.0f}%"),
        ("风速", f"{cur['wind_speed_10m']:.1f} m/s"),
        ("降水", f"{cur.get('precipitation', 0):.1f} mm"),
    ]
    colw = 204
    for i, (k, v) in enumerate(dets):
        x = M + i * colw
        d.text((x, 478), k, font=F(26), fill=MID, anchor="lt")
        d.text((x, 514), v, font=F(38, True), fill=BLACK, anchor="lt")

    # ---------- 逐时
    y = 600
    d.text((M, y), "逐时预报", font=F(30, True), fill=DARK, anchor="lt")
    n = min(cfg.get("hours_shown", 6), 12)
    d.text((W - M, y + 4), f"未来 {n} 小时", font=F(26), fill=MID, anchor="rt")

    # 找当前小时索引（Open-Meteo 返回的是不带时区的本地时间）
    hours = hourly["time"]
    now_naive = datetime.fromisoformat(cur["time"]).replace(minute=0, second=0, microsecond=0)
    start = 0
    for i, h in enumerate(hours):
        if datetime.fromisoformat(h) >= now_naive:
            start = i
            break

    gap = (W - 2 * M) / n
    y0 = 652
    for i in range(n):
        idx = start + i
        if idx >= len(hours):
            break
        cx = M + gap * i + gap / 2
        ht = datetime.fromisoformat(hours[idx])
        d.text((cx, y0), "现在" if i == 0 else f"{ht.hour}时", font=F(28), fill=DARK, anchor="mt")
        draw_icon(img, describe(hourly["weather_code"][idx])[1],
                  (cx - 30, y0 + 44, cx + 30, y0 + 104))
        # 第一列写「现在」，就用实时温度，避免与顶部大数字差 1 度
        htemp = cur["temperature_2m"] if i == 0 else hourly["temperature_2m"][idx]
        d.text((cx, y0 + 110), f"{htemp:.0f}°",
               font=F(40, True), fill=BLACK, anchor="mt")
        d.text((cx, y0 + 166), f"{hourly['precipitation_probability'][idx]:.0f}%",
               font=F(24), fill=MID, anchor="mt")
        if i:
            d.line([M + gap * i, y0 + 2, M + gap * i, y0 + 200], fill=LIGHT, width=2)

    d.line([M, 886, W - M, 886], fill=BLACK, width=3)

    # ---------- 逐日
    y = 924
    d.text((M, y), "未来几天", font=F(30, True), fill=DARK, anchor="lt")

    nd = min(cfg.get("days_shown", 4), len(daily["time"]))
    lo = min(daily["temperature_2m_min"][:nd])
    hi = max(daily["temperature_2m_max"][:nd])
    span = max(1.0, hi - lo)

    temp_low_x = M + 620          # 低温数字右对齐位置
    bar_x0, bar_x1 = M + 640, W - M - 84
    row_h = 96
    y = 968
    for i in range(nd):
        dt = datetime.fromisoformat(daily["time"][i])
        ry = y + i * row_h
        name = "今天" if i == 0 else ("明天" if i == 1 else CN_WEEK[dt.weekday()])
        d.text((M, ry + 6), name, font=F(34, True), fill=BLACK, anchor="lt")
        d.text((M + 96, ry + 14), f"{dt.month}/{dt.day}", font=F(24), fill=MID, anchor="lt")

        lbl, k3 = describe(daily["weather_code"][i])
        draw_icon(img, k3, (M + 186, ry + 2, M + 236, ry + 52))
        d.text((M + 250, ry + 12), lbl, font=F(26), fill=DARK, anchor="lt")

        amin, amax = daily["temperature_2m_min"][i], daily["temperature_2m_max"][i]
        x0 = bar_x0 + (amin - lo) / span * (bar_x1 - bar_x0)
        x1 = bar_x0 + (amax - lo) / span * (bar_x1 - bar_x0)
        bar_y = ry + 26
        d.line([bar_x0, bar_y, bar_x1, bar_y], fill=LIGHT, width=6)
        d.line([x0, bar_y, max(x1, x0 + 10), bar_y], fill=BLACK, width=14)
        d.text((temp_low_x, ry + 4), f"{amin:.0f}°", font=F(28), fill=MID, anchor="rt")
        d.text((W - M, ry + 4), f"{amax:.0f}°", font=F(28, True), fill=BLACK, anchor="rt")

    # ---------- 页脚
    fy = H - 78
    d.line([M, fy - 20, W - M, fy - 20], fill=LIGHT, width=2)
    stamp = f"更新 {now.strftime('%H:%M')}"
    if stale:
        stamp += "  · 离线缓存"
    d.text((M, fy), stamp, font=F(25), fill=MID, anchor="lt")
    d.text((W - M, fy), "数据 Open-Meteo", font=F(25), fill=MID, anchor="rt")

    return img


def main():
    force = "--force" in sys.argv
    cfg = load_cfg()
    data, ok = (None, False)
    try:
        data, ok = fetch(cfg)
        print("[fetch] 在线数据获取成功")
    except Exception as e:
        print(f"[fetch] 失败：{e}")
        if force:
            raise
        data, _ = load_cached()
        if not data:
            print("[fatal] 无缓存可用")
            return 2
        print("[fetch] 使用本地缓存")

    img = render(cfg, data, stale=not ok)
    out = os.path.join(BASE, cfg.get("output", "dashboard.png"))
    img.save(out, format="PNG", optimize=True)
    print(f"[out] {out}  {img.size[0]}x{img.size[1]}  {os.path.getsize(out)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
