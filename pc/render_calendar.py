#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""挂历页渲染器 —— 与天气页共用同一套灰阶规范

输出 1072x1448 灰度 PNG（PW3 原生分辨率）
设计：整月网格、今日反白、上下月日期淡显、本月/本年进度。
"""
import calendar
import json
import os
import sys
from datetime import date, datetime

from PIL import Image, ImageDraw

from render_dashboard import (BLACK, DARK, LIGHT, MID, F,
                              load_cfg, draw_icon)  # noqa: F401

BASE = os.path.dirname(os.path.abspath(__file__))
CN_WEEK_SHORT = ["日", "一", "二", "三", "四", "五", "六"]


def month_matrix(year, month):
    """返回 6x7 的日期矩阵，元素为 (date, 是否本月)"""
    cal = calendar.Calendar(firstweekday=6)  # 周日开头，符合中文挂历习惯
    weeks = [list(w) for w in cal.monthdatescalendar(year, month)]
    # 不足 6 周时，接着最后一个日期往后补，绝不复制已有行
    from datetime import timedelta
    while len(weeks) < 6:
        last = weeks[-1][-1]
        weeks.append([last + timedelta(days=i) for i in range(1, 8)])
    return [[(d, d.month == month) for d in w] for w in weeks[:6]]


def render_calendar(cfg, today=None, target=None):
    W, H = cfg["width"], cfg["height"]
    today = today or date.today()
    target = target or today
    year, month = target.year, target.month

    img = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(img)
    M = 60
    CW = (W - 2 * M) / 7

    # ---------------- 页眉
    title = f"{year}年 {month}月"
    d.text((M - 6, 44), title, font=F(96, True), fill=BLACK, anchor="lt")

    ty = 96
    tx = W - M
    d.text((tx, ty), f"第 {target.isocalendar()[1]} 周", font=F(30), fill=DARK, anchor="rt")
    # 本月天数与今日星期
    ndays = calendar.monthrange(year, month)[1]
    d.text((tx, ty + 44), f"{ndays} 天 · 今日 {CN_WEEK_SHORT[(today.weekday() + 1) % 7]}",
           font=F(28), fill=MID, anchor="rt")

    d.line([M, 172, W - M, 172], fill=BLACK, width=3)

    # ---------------- 星期表头
    hy = 196
    is_cur_month = (today.year == year and today.month == month)
    for i, name in enumerate(CN_WEEK_SHORT):
        cx = M + CW * i + CW / 2
        weekend_style = i in (0, 6)
        if weekend_style:
            d.rounded_rectangle([M + CW * i + 10, hy, M + CW * (i + 1) - 10, hy + 52],
                                radius=10, fill=DARK)
            d.text((cx, hy + 8), name, font=F(30, True), fill=255, anchor="mt")
        else:
            d.text((cx, hy + 8), name, font=F(30, True), fill=MID, anchor="mt")

    # ---------------- 日期网格
    grid_top = 268
    row_h = 152
    weeks = month_matrix(year, month)

    for r, week in enumerate(weeks):
        for c, (day, in_month) in enumerate(week):
            x0 = M + CW * c
            y0 = grid_top + r * row_h
            x1, y1 = x0 + CW, y0 + row_h

            # 细分隔线
            if r:
                d.line([M, y0, W - M, y0], fill=LIGHT, width=2)
            if c:
                d.line([x0, grid_top, x0, grid_top + 6 * row_h], fill=LIGHT, width=2)

            num = str(day.day)
            is_today = (day == today)

            if is_today:
                pad = 16
                d.rounded_rectangle([x0 + pad, y0 + pad - 6, x1 - pad, y0 + row_h - pad - 6],
                                    radius=14, fill=BLACK)
                d.text(((x0 + x1) / 2, y0 + 34), num, font=F(64, True), fill=255, anchor="mt")
                d.text(((x0 + x1) / 2, y0 + 104), "今天", font=F(22), fill=200, anchor="mt")
            else:
                color = BLACK if in_month else 190
                size = 54 if in_month else 40
                d.text(((x0 + x1) / 2, y0 + 30), num, font=F(size, in_month),
                       fill=color, anchor="mt")
                # 周末小标记
                if in_month and c in (0, 6):
                    d.line([x0 + CW / 2 - 10, y0 + 104, x0 + CW / 2 + 10, y0 + 104],
                           fill=MID, width=3)

    # 外框
    d.rectangle([M, grid_top, W - M, grid_top + 6 * row_h], outline=BLACK, width=3)

    # ---------------- 页脚：本月进度
    fy = grid_top + 6 * row_h + 52
    day_of_month = today.day if is_cur_month else 1
    ratio = day_of_month / ndays

    d.text((M, fy - 34), "本月进度", font=F(26), fill=MID, anchor="lt")

    bx0, bx1 = M, W - M
    by = fy + 8
    d.line([bx0, by, bx1, by], fill=LIGHT, width=10)
    d.line([bx0, by, bx0 + (bx1 - bx0) * ratio, by], fill=BLACK, width=10)

    # 本年进度
    doy = today.timetuple().tm_yday
    ydays = 366 if calendar.isleap(today.year) else 365
    d.text((M, fy + 34), f"本年第 {doy} 天 / {ydays} 天", font=F(26), fill=DARK, anchor="lt")
    d.text((W - M, fy + 34), f"距本月结束还有 {ndays - day_of_month} 天",
           font=F(26), fill=DARK, anchor="rt")

    # 页脚标识
    d.line([M, H - 96, W - M, H - 96], fill=LIGHT, width=2)
    d.text((M, H - 74), datetime.now().strftime("渲染 %Y-%m-%d %H:%M"),
           font=F(24), fill=MID, anchor="lt")
    d.text((W - M, H - 74), "WeatherDash · 挂历", font=F(24), fill=MID, anchor="rt")

    return img


def main():
    cfg = load_cfg()
    out = sys.argv[1] if len(sys.argv) > 1 else "calendar.png"
    img = render_calendar(cfg)
    path = os.path.join(BASE, out)
    img.save(path, format="PNG", optimize=True)
    print(f"[out] {path}  {img.size[0]}x{img.size[1]}  {os.path.getsize(path)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
