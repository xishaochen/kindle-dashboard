#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""人生周历页渲染器 —— 52 列 x N 行，每格一周

排版约束（PW3 1072x1448，整页由 carousel 画在 y=32 处）：
- 图像第 0-30 行会被系统状态栏盖住，内容从 y=30 之后开始
- 图像超过 y=1408 的部分会被屏幕底边裁掉

几何一律由可用空间反推，不再写死格子尺寸。
第一版把 100 行 x 13px 写死，网格高度 1297px 直接把统计区顶出画面。
"""
import os
import sys
from datetime import date, timedelta

from PIL import Image, ImageDraw

from render_dashboard import BLACK, DARK, LIGHT, MID, F, load_cfg  # noqa: F401

BASE = os.path.dirname(os.path.abspath(__file__))

SAFE_TOP = 30          # 系统状态栏保留
SAFE_BOTTOM = 1408     # 屏幕底边安全线
GRID_TOP = 158         # 网格起始 y

EMPTY_GRAY = 214       # 未到的周


def life_cfg(cfg):
    lc = cfg.get("life") or {}
    return {
        "birth": lc.get("birth", "1990-01-01"),
        "years": int(lc.get("years", 100)),
        "weeks_per_year": int(lc.get("weeks_per_year", 52)),
    }


def stats_for(birth, today, years, wpy):
    total = years * wpy
    elapsed = max(0, min((today - birth).days // 7, total))
    return {
        "birth": birth, "today": today, "years": years,
        "weeks_per_year": wpy, "total": total, "elapsed": elapsed,
        "remaining": total - elapsed,
        "ratio": elapsed / total if total else 0.0,
        "age_years": (today - birth).days / 365.2425,
        "row": elapsed // wpy, "col": elapsed % wpy,
        "next_turn": birth + timedelta(days=(elapsed + 1) * 7),
    }


def grid_metrics(W, cols, rows, reserve):
    """按可用空间反推格子尺寸，横纵独立取值。

    52 列 x 100 行在竖屏上是「高度定瓶颈」：纵向只够 pitch≈9px，
    若坚持正方形，网格只能宽 465px，两侧空掉一半。
    所以横向单独算 pitch，得到略扁的矩形格子（约 10x6），既填满版面，
    又能一格一格数清 —— 这正是市面周历海报的通行做法。

    pitch 必须向下取整：向上取整会让网格凭空多出几十像素，
    第一版就足在这里，10.64 四舍五入成 11，网格高了 32px 直接撞上水印。
    """
    avail_w = W - 268                       # 左右留 134，给刻度和「现在」标注
    avail_h = (SAFE_BOTTOM - reserve) - GRID_TOP
    px = int(avail_w / cols)
    py = int(avail_h / rows)
    gx_gap = max(2, int(round(px * 0.30)))
    gy_gap = max(2, int(round(py * 0.32)))
    cw, ch = px - gx_gap, py - gy_gap
    gw = cols * px - gx_gap
    gh = rows * py - gy_gap
    return cw, ch, px, py, gx_gap, gy_gap, gw, gh, (W - gw) // 2


def render_life(cfg, today=None):
    W, H = cfg["width"], cfg["height"]
    lc = life_cfg(cfg)
    birth = date.fromisoformat(lc["birth"])
    today = today or date.today()
    s = stats_for(birth, today, lc["years"], lc["weeks_per_year"])

    cols, rows = s["weeks_per_year"], s["years"]

    # 统计区高度由内容量决定，先按需预留，再交给 grid_metrics 反推格子。
    # 元素从下往上算，保证水印和最后一行永远不会重叠。
    WM_SIZE, WM_PAD = 19, 14           # 水印字号与距底边的距离
    ST_LINE3, ST_LINE2, ST_NUM = 20, 22, 42
    stats_h = 26 + 8 + 22 + 52 + 30 + ST_LINE3 + 20
    reserve = stats_h + WM_SIZE + WM_PAD + 12

    cell, ch, px, py, gx_gap, gy_gap, gw, gh, gx = grid_metrics(
        W, cols, rows, reserve)
    gy = GRID_TOP

    if gy + gh > SAFE_BOTTOM - reserve:
        raise RuntimeError(
            f"网格高度 {gh}px 超出可用空间，gy+gh={gy + gh} 会挤掉统计区")

    img = Image.new("L", (W, H), 255)
    d = ImageDraw.Draw(img)

    # ------------------------------------------------------------ 页眉
    d.text((W / 2, SAFE_TOP + 2), "LIFETIME IN WEEKS", font=F(44, True),
           fill=BLACK, anchor="mt")
    d.text((W / 2, SAFE_TOP + 60), f"人生周历 · {birth.year} 年至今 · 满 {s['years']} 岁",
           font=F(23), fill=MID, anchor="mt")

    # ------------------------------------------------------ 列刻度（周）
    label_y = gy - 24
    for n in (1, 13, 26, 39, 52):
        if n > cols:
            continue
        d.text((gx + (n - 1) * px + cell / 2, label_y), str(n),
               font=F(16), fill=LIGHT, anchor="mt")

    # 行刻度（岁）：1、10、20 …… 100 全部标出，右侧对齐网格左缘外
    for i in range(rows):
        yr = i + 1
        if yr == 1 or yr % 10 == 0:
            strong = (yr % 20 == 0)
            d.text((gx - 10, gy + i * py + ch / 2), str(yr),
                   font=F(17, strong), fill=MID if strong else LIGHT,
                   anchor="rm")

    # ------------------------------------------------------------ 网格
    # 逐格绘制。已过画黑、未到画浅灰，间隙留白——
    # 这样黑色区域里也能数出一格一格，而不是一坨实心黑。
    full_rows = s["elapsed"] // cols
    rest_cols = s["elapsed"] % cols
    for r in range(rows):
        y = gy + r * py
        if r < full_rows:
            # 整行已过：一次画完整行，再逐列打白缝，比 5200 次判断快且等效
            d.rectangle([gx, y, gx + gw - 1, y + ch], fill=BLACK)
            for c in range(1, cols):
                x = gx + c * px
                d.rectangle([x - gx_gap, y, x - 1, y + ch], fill=255)
        elif r == full_rows and rest_cols:
            d.rectangle([gx, y, gx + rest_cols * px - gx_gap - 1, y + ch], fill=BLACK)
            for c in range(1, rest_cols):
                x = gx + c * px
                d.rectangle([x - gx_gap, y, x - 1, y + ch], fill=255)
            for c in range(rest_cols, cols):
                x = gx + c * px
                d.rectangle([x, y, x + cell, y + ch], fill=EMPTY_GRAY)
        else:
            for c in range(cols):
                x = gx + c * px
                d.rectangle([x, y, x + cell, y + ch], fill=EMPTY_GRAY)

    # 当前周：四周留白把周围格子推开，中间一个黑格，在任何背景上都跳出来
    if s["elapsed"] < s["total"]:
        cx = gx + s["col"] * px
        cy = gy + s["row"] * py
        pad = gy_gap + 3
        d.rectangle([cx - pad, cy - pad, cx + cell + pad, cy + ch + pad], fill=255)
        d.rectangle([cx, cy, cx + cell, cy + ch], fill=BLACK)

        # 右侧引线标注，解决「标记在中间、年龄写底下」对不上的问题
        lx0 = gx + gw + pad + 4
        lx1 = min(W - 16, lx0 + 34)
        d.line([lx0, cy + ch / 2, lx1, cy + ch / 2], fill=BLACK, width=2)
        d.text((lx1 + 6, cy + ch / 2 - 10), "现在", font=F(19, True),
               fill=BLACK, anchor="lm")
        d.text((lx1 + 6, cy + ch / 2 + 12), f"第 {s['elapsed'] + 1} 周",
               font=F(16), fill=MID, anchor="lm")

    d.rectangle([gx - 1, gy - 1, gx + gw, gy + gh], outline=LIGHT, width=1)

    # ------------------------------------------------------------ 统计区
    # 游标式布局：每一项都从上一个元素的实际底部往下排，
    # 不再用「bar_y + 固定偏移」这种靠手算的方式，那种写法一改字号就重叠。
    y = gy + gh + 26
    d.line([gx, y, gx + gw - 1, y], fill=LIGHT, width=8)
    filled_w = int((gw - 1) * s["ratio"])
    if filled_w > 0:
        d.line([gx, y, gx + filled_w, y], fill=BLACK, width=8)

    y += 20
    d.text((gx, y), f"{s['ratio'] * 100:.2f}%", font=F(ST_NUM, True),
           fill=BLACK, anchor="lt")
    d.text((gx + gw - 1, y + 12), f"剩 {s['remaining']} 周", font=F(30, True),
           fill=BLACK, anchor="rt")

    y += 52
    d.text((gx, y), f"已过 {s['elapsed']} 周 / 共 {s['total']} 周 · "
                    f"{s['age_years']:.1f} 岁",
           font=F(ST_LINE2), fill=DARK, anchor="lt")

    y += 30
    d.text((gx, y), f"每 7 天补一格 · 下一格 {s['next_turn']:%Y-%m-%d}",
           font=F(ST_LINE3), fill=MID, anchor="lt")

    # 水印固定贴底，且在最后一行的下方留足缺口
    wm_y = SAFE_BOTTOM - WM_PAD - WM_SIZE
    if wm_y < y + ST_LINE3 + 8:
        raise RuntimeError(f"统计区压到水印：最后一行底 {y + ST_LINE3} > 水印顶 {wm_y}")
    d.text((gx, wm_y), "WeatherDash · 人生周历", font=F(WM_SIZE), fill=LIGHT, anchor="lt")
    d.text((gx + gw - 1, wm_y), "每周一格 · 每行一年", font=F(WM_SIZE), fill=LIGHT, anchor="rt")

    return img, s


def main():
    out = "lifeweeks.png"
    today = None
    for a in sys.argv[1:]:
        if a.startswith("--date="):
            today = date.fromisoformat(a.split("=", 1)[1])
        elif not a.startswith("--"):
            out = a

    cfg = load_cfg()
    img, s = render_life(cfg, today=today)
    path = out if os.path.isabs(out) else os.path.join(BASE, out)
    img.save(path, format="PNG", optimize=True)
    print(f"[out] {path}  {img.size[0]}x{img.size[1]}  {os.path.getsize(path)} bytes")
    print(f"[stats] 出生 {s['birth']} 今天 {s['today']} 已过 {s['elapsed']} 周 "
          f"({s['ratio']*100:.2f}%) 剩 {s['remaining']} 周 下一格 {s['next_turn']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
