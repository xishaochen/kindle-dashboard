"""catkit v3 —— 生产版：生成 5 个完整动作的序列帧 + 设备资源包。

v2 评审剩余缺陷，本版修复：
  1. 胡须用 104 灰（原 150 太浅，e-ink 上会显脏）
  2. 脚掌去掉黑描边，与前腿白色连成一体（原像穿白鞋）
  3. 尾尖圆头改小、渐细更均匀（原尾尖过重）

输出 dist/cat5/：
  base.png                 全屏基图
  anim.txt                 清单（busybox 友好，无 JSON）
  <action>/fN.png          各动作帧（已裁到脏矩形）
  contact-<action>.png     对照图（人工核验用）
"""
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.stdout.reconfigure(encoding="utf-8")

BASE = r"C:\Users\杰西卡\AppData\Roaming\ClawHiveApp\accounts\acct_57620a774ce086ad\tenants\tnt_daa8c7e0700de6fe\workspace\kindle-dashboard"
DIST = os.path.join(BASE, "dist", "cat5")
MEDIA = r"C:\Users\杰西卡\AppData\Roaming\ClawHiveApp\accounts\acct_57620a774ce086ad\tenants\tnt_daa8c7e0700de6fe\openclaw\state\media\outgoing\originals\catsheet"

W, H = 1072, 1416
SS = 4
BLACK, WHITE = 0, 255
WHISK = 104          # 胡须用较深的灰，避免 e-ink 上发脏

CX = 536
GROUND = 1258
HEAD_CY = 548
HEAD_RX, HEAD_RY = 172, 152
EAR_L = [(386, 300), (330, 452), (474, 452)]
EAR_R = [(686, 300), (742, 452), (598, 452)]


def q16(img):
    a = np.array(img, dtype=np.float32)
    out = np.clip(np.round((a - 8.0) / 16.0), 0, 15) * 16.0 + 8.0
    return Image.fromarray(out.astype(np.uint8), "L")


def S(v):
    return v * SS


def ell(d, cx, cy, rx, ry, **kw):
    d.ellipse([S(cx - rx), S(cy - ry), S(cx + rx), S(cy + ry)], **kw)


def pol(d, pts, **kw):
    d.polygon([(S(x), S(y)) for x, y in pts], **kw)


def ln(d, pts, w=4, **kw):
    d.line([(S(x), S(y)) for x, y in pts], width=int(S(w)), joint="curve", **kw)


def arc(d, cx, cy, rx, ry, s, e, w=4, **kw):
    d.arc([S(cx - rx), S(cy - ry), S(cx + rx), S(cy + ry)], s, e,
          width=int(S(w)), **kw)


def rotp(p, c, deg):
    r = math.radians(deg)
    dx, dy = p[0] - c[0], p[1] - c[1]
    return (c[0] + dx * math.cos(r) - dy * math.sin(r),
            c[1] + dx * math.sin(r) + dy * math.cos(r))


def catmull(pts, closed=True, n=12):
    out = []
    m = len(pts)
    rng = range(m) if closed else range(m - 1)
    for i in rng:
        p0, p1, p2, p3 = pts[(i - 1) % m], pts[i], pts[(i + 1) % m], pts[(i + 2) % m]
        for k in range(n):
            t = k / float(n)
            t2, t3 = t * t, t * t * t
            x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t +
                       (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2 +
                       (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
            y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t +
                       (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 +
                       (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
            out.append((x, y))
    if not closed:
        out.append(pts[-1])
    return out


def taper(d, spine, w0, w1, tip_r=0.0, fill=BLACK):
    n = len(spine)
    left, right = [], []
    for i in range(n):
        t = i / float(n - 1)
        w = (w0 + (w1 - w0) * (t ** 0.85)) * 0.5
        if i == 0:
            dx, dy = spine[1][0] - spine[0][0], spine[1][1] - spine[0][1]
        elif i == n - 1:
            dx, dy = spine[-1][0] - spine[-2][0], spine[-1][1] - spine[-2][1]
        else:
            dx = spine[i + 1][0] - spine[i - 1][0]
            dy = spine[i + 1][1] - spine[i - 1][1]
        L = math.hypot(dx, dy) or 1.0
        nx, ny = -dy / L, dx / L
        left.append((spine[i][0] + nx * w, spine[i][1] + ny * w))
        right.append((spine[i][0] - nx * w, spine[i][1] - ny * w))
    pol(d, left + right[::-1], fill=fill)
    if tip_r > 0:
        ell(d, spine[-1][0], spine[-1][1], tip_r, tip_r, fill=fill)


# ------------------------------------------------------------------ 部件
def draw_tail(d, ang, lift=0.0):
    """尾巴：绕尾根旋转。整条尾巴必须在地面线之上，不能穿到地面以下。"""
    root = (CX + 128, 1150)
    base = [(0, 0), (74, -18), (146, 48 - lift), (192, 148 - lift * 1.5),
            (196, 240 - lift * 2.0)]
    a = math.radians(ang)
    ca, sa = math.cos(a), math.sin(a)
    spine = catmull([(root[0] + x * ca - y * sa, root[1] + x * sa + y * ca)
                     for x, y in base], closed=False, n=14)
    # 硬限制：脊线不允许低于地面线减 18px（尾巴不能垂到地面下面）
    lim = GROUND - 18
    spine = [(x, min(y, lim)) for x, y in spine]
    taper(d, spine, 60, 20, tip_r=11)


def draw_body(d, breath):
    t = breath
    pts = [
        (CX, 662),
        (CX + 96, 672), (CX + 138, 726), (CX + 148, 800),
        (CX + 138, 880), (CX + 158, 962), (CX + 172 + 7 * t, 1058),
        (CX + 166 + 7 * t, 1152), (CX + 132, 1228), (CX + 62, 1264),
        (CX, 1268),
        (CX - 62, 1264), (CX - 132, 1228), (CX - 166 - 7 * t, 1152),
        (CX - 172 - 7 * t, 1058), (CX - 158, 962), (CX - 138, 880),
        (CX - 148, 800), (CX - 138, 726), (CX - 96, 672),
    ]
    pol(d, catmull(pts, closed=True, n=6), fill=BLACK)


def draw_white(d, breath):
    """脸白 + 胸白一片。"""
    t = breath
    pts = [
        (CX, 452),
        (CX + 56, 470), (CX + 104, 512), (CX + 118, 574),
        (CX + 106, 636), (CX + 78, 680), (CX + 62, 714),
        (CX + 96, 760), (CX + 128 + 6 * t, 840), (CX + 122 + 6 * t, 950),
        (CX + 108, 1060), (CX + 80, 1152), (CX + 44, 1218),
        (CX, 1238),
        (CX - 44, 1218), (CX - 80, 1152), (CX - 108, 1060),
        (CX - 122 - 6 * t, 950), (CX - 128 - 6 * t, 840), (CX - 96, 760),
        (CX - 62, 714), (CX - 78, 680), (CX - 106, 636), (CX - 118, 574),
        (CX - 104, 512), (CX - 56, 470),
    ]
    pol(d, catmull(pts, closed=True, n=6), fill=WHITE)


def draw_ears(d, tl, tr):
    for tri, pivot, ang in ((EAR_L, (400, 452), -22 * tl),
                            (EAR_R, (672, 452), 22 * tr)):
        pol(d, [rotp(p, pivot, ang) for p in tri], fill=BLACK)
    for tri, pivot, ang in ((EAR_L, (400, 452), -22 * tl),
                            (EAR_R, (672, 452), 22 * tr)):
        inner = [(pivot[0] + (x - pivot[0]) * 0.50,
                  pivot[1] + (y - pivot[1]) * 0.58) for x, y in tri]
        pol(d, [rotp(p, pivot, ang) for p in inner], fill=WHITE)


def draw_eye(d, ex, ey, state, look=0.0):
    """眼白始终保留（避免 e-ink 上大块黑白翻转留残影）。
    闭合时用「填充黑的眼睑」从上往下压住眼白，而不是只画一条细弧线。"""
    er = 48
    ry_full = er - 2

    # 底座：眼白椭圆（恒定存在）
    ell(d, ex, ey, er, ry_full + 6, fill=WHITE)
    ell(d, ex, ey, er, ry_full + 6, outline=BLACK, width=int(S(6)))

    # 上下眼睑的开口半高：state=1 全开，state=0 几乎贴合成缝
    ry = max(3.0, ry_full * state)

    # 上眼睑：从眼白顶部往下填充黑（关键：fill 不是 outline）
    lid_top = ey - ry_full - 8
    lid_bot = ey - ry
    if lid_bot > lid_top:
        pol(d, [(ex - er - 4, lid_top), (ex + er + 4, lid_top),
                (ex + er + 4, lid_bot), (ex - er - 4, lid_bot)], fill=BLACK)

    if state <= 0.15:
        # 完全闭合：下眼睑也往上收，只留一条缝 + 睫毛
        pol(d, [(ex - er - 4, ey + 4), (ex + er + 4, ey + 4),
                (ex + er + 4, ey + ry_full + 10), (ex - er - 4, ey + ry_full + 10)],
            fill=BLACK)
        arc(d, ex, ey + 2, er - 6, max(8, ry_full - 10), 190, 350, w=7, fill=BLACK)
        for k in range(3):
            lx = ex - 26 + k * 26
            ln(d, [(lx, ey - 6), (lx - 4 + k * 4, ey - 30)], w=5, fill=BLACK)
        return

    # 瞳孔：只在开口范围内
    pr = max(6.0, min(11.0, ry - 6))
    ell(d, ex + look, ey + (ry_full - ry) * 0.30, 11, pr, fill=BLACK)
    if ry > 18:
        ell(d, ex + look + 6, ey - ry * 0.30, 6, 6, fill=WHITE)

    # 下眼睑：闭合过程中往上收
    if state < 0.72:
        bot = ey + max(ry, ry_full * 0.55)
        pol(d, [(ex - er - 4, bot), (ex + er + 4, bot),
                (ex + er + 4, ey + ry_full + 10), (ex - er - 4, ey + ry_full + 10)],
            fill=BLACK)


def draw_head(d, eye, look, mouth, tl, tr, dy=0.0):
    cy = HEAD_CY + dy
    draw_ears(d, tl, tr)
    ell(d, CX, cy, HEAD_RX, HEAD_RY, fill=BLACK)
    # 耳内白要重画（被头盖住的部分也要在）
    for tri, pivot, ang in ((EAR_L, (400, 452), -22 * tl),
                            (EAR_R, (672, 452), 22 * tr)):
        inner = [(pivot[0] + (x - pivot[0]) * 0.50,
                  pivot[1] + (y - pivot[1]) * 0.58) for x, y in tri]
        pol(d, [rotp(p, pivot, ang) for p in inner], fill=WHITE)

    draw_eye(d, CX - 72, cy - 22, eye, look)
    draw_eye(d, CX + 72, cy - 22, eye, look + 1)

    pol(d, [(CX - 15, cy + 50), (CX + 15, cy + 50), (CX, cy + 72)], fill=BLACK)
    if mouth > 0.25:
        # 张大嘴：横向宽、纵向深，带口腔内部与舌头
        mw = 40 + 130 * mouth          # 半宽 40..170
        top = cy + 72
        dep = 30 + 230 * mouth        # 深 30..260
        pol(d, catmull([
            (CX - mw, top),
            (CX - mw * 0.55, top + dep * 0.30),
            (CX, top + dep * 0.38),
            (CX + mw * 0.55, top + dep * 0.30),
            (CX + mw, top),
            (CX + mw * 0.60, top + dep * 0.82),
            (CX, top + dep),
            (CX - mw * 0.60, top + dep * 0.82),
        ], closed=True, n=6), fill=BLACK)
        # 口腔内里的暗区 + 舌头
        if mouth > 0.45:
            # 口腔内部：深色膛 + 舌头 + 上下齿列
            ell(d, CX, top + dep * 0.58, mw * 0.66, dep * 0.28, fill=72)
            ell(d, CX, top + dep * 0.80, mw * 0.52, dep * 0.16, fill=184)
            ell(d, CX, top + dep * 0.90, mw * 0.34, dep * 0.09, fill=136)
            # 上獠牙（两根，尖长）
            for sx in (-1, 1):
                pol(d, [(CX + sx * mw * 0.50, top + dep * 0.10),
                        (CX + sx * mw * 0.36, top + dep * 0.10),
                        (CX + sx * mw * 0.44, top + dep * 0.38)], fill=WHITE)
            # 下獠牙（两根小的）
            for sx in (-1, 1):
                pol(d, [(CX + sx * mw * 0.44, top + dep * 0.98),
                        (CX + sx * mw * 0.32, top + dep * 0.98),
                        (CX + sx * mw * 0.39, top + dep * 0.74)], fill=WHITE)
            # 上颚横纹，暗示口腔深度
            for k in range(2):
                yy = top + dep * (0.20 + k * 0.13)
                arc(d, CX, yy, mw * 0.44, dep * 0.10, 200, 340, w=4, fill=104)
    else:
        arc(d, CX - 20, cy + 70, 22, 20, 12, 96, w=6, fill=BLACK)
        arc(d, CX + 20, cy + 70, 22, 20, 84, 168, w=6, fill=BLACK)

    for k in range(3):
        y = cy + 46 + k * 15
        ln(d, [(CX - 112, y), (CX - 238, y - 20 + k * 19)], w=3, fill=WHISK)
        ln(d, [(CX + 112, y), (CX + 238, y - 20 + k * 19)], w=3, fill=WHISK)


def draw_legs(d, breath):
    for lx in (CX - 84, CX + 84):
        ln(d, [(lx, 1020), (lx, 1240)], w=58, fill=WHITE)
        ell(d, lx, 1244, 54, 32, fill=WHITE)     # 无黑描边，与前腿连成一体
        for k in range(3):
            arc(d, lx - 22 + k * 22, 1256, 9, 11, 205, 335, w=4, fill=BLACK)


def scene(eye=1.0, look=0.0, mouth=0.0, tail=0.0, lift=0.0, breath=0.0,
          ear_l=0.0, ear_r=0.0, head_dy=0.0, chrome=False):
    img = Image.new("L", (W * SS, H * SS), WHITE)
    d = ImageDraw.Draw(img)
    ln(d, [(0, GROUND), (W, GROUND)], w=5, fill=BLACK)
    ln(d, [(0, GROUND + 12), (W, GROUND + 12)], w=3, fill=104)
    draw_tail(d, tail, lift)
    draw_body(d, breath)
    draw_white(d, breath)
    draw_head(d, eye, look, mouth, ear_l, ear_r, head_dy)
    draw_legs(d, breath)
    if chrome:
        draw_clock(d)
    return img.resize((W, H), Image.LANCZOS)


def draw_clock(d):
    import datetime
    now = datetime.datetime.now()
    txt = "%02d:%02d" % (now.hour, now.minute)
    try:
        f = ImageFont.truetype(r"C:\Windows\Fonts\msyhbd.ttc", int(S(150)))
    except Exception:
        return
    box = d.textbbox((0, 0), txt, font=f)
    d.text((S(CX) - (box[2] - box[0]) / 2.0, S(70)), txt, font=f, fill=BLACK)


# ------------------------------------------------------------------ 动作定义
ACTIONS = [
    # name,    周期ms, 帧参数
    ("blink", 150, [
        dict(eye=1.0), dict(eye=0.60), dict(eye=0.34), dict(eye=0.18),
        dict(eye=0.10), dict(eye=0.20), dict(eye=0.42), dict(eye=0.72),
        dict(eye=1.0),
    ]),
    ("breath", 1200, [
        dict(breath=0.0, head_dy=0), dict(breath=0.55, head_dy=-2),
        dict(breath=1.0, head_dy=-3), dict(breath=0.62, head_dy=-2),
        dict(breath=-0.10, head_dy=0), dict(breath=-0.85, head_dy=2),
        dict(breath=-0.45, head_dy=1), dict(breath=-0.10, head_dy=0),
    ]),
    ("tail", 260, [
        dict(tail=-4, lift=6), dict(tail=-13, lift=22), dict(tail=-22, lift=46),
        dict(tail=-17, lift=38), dict(tail=-6, lift=12), dict(tail=8, lift=16),
        dict(tail=18, lift=40), dict(tail=21, lift=44),
    ]),
    ("ear", 190, [
        dict(ear_l=0.0, ear_r=0.0), dict(ear_l=0.85, ear_r=0.18),
        dict(ear_l=0.40, ear_r=0.55), dict(ear_l=0.10, ear_r=0.95),
        dict(ear_l=0.30, ear_r=0.35), dict(ear_l=0.05, ear_r=0.08),
    ]),
    ("yawn", 420, [
        dict(eye=1.0, mouth=0.0), dict(eye=0.72, mouth=0.10, head_dy=-1),
        dict(eye=0.52, mouth=0.26, head_dy=-2), dict(eye=0.34, mouth=0.48, head_dy=-3),
        dict(eye=0.20, mouth=0.72, head_dy=-4), dict(eye=0.12, mouth=0.90, head_dy=-6),
        dict(eye=0.08, mouth=1.0, head_dy=-7), dict(eye=0.10, mouth=0.95, head_dy=-7),
        dict(eye=0.16, mouth=0.82, head_dy=-6), dict(eye=0.26, mouth=0.60, head_dy=-5),
        dict(eye=0.42, mouth=0.36, head_dy=-3), dict(eye=0.62, mouth=0.16, head_dy=-2),
        dict(eye=0.82, mouth=0.05, head_dy=-1), dict(eye=1.0, mouth=0.0, head_dy=0),
    ]),
]


def build():
    if not os.path.isdir(DIST):
        os.makedirs(DIST)
    if not os.path.isdir(MEDIA):
        os.makedirs(MEDIA)

    print("=" * 78)
    print("渲染基图")
    print("=" * 78)
    base_img = q16(scene())
    base_img.save(os.path.join(DIST, "base.png"), format="PNG", optimize=True)
    print("  base.png %dB" % os.path.getsize(os.path.join(DIST, "base.png")))
    ba = np.array(base_img, dtype=np.int16)

    manifest = []
    for name, period, frames in ACTIONS:
        print()
        print("=" * 78)
        print("%s   %d 帧  周期 %dms" % (name, len(frames), period))
        print("=" * 78)
        adir = os.path.join(DIST, name)
        if not os.path.isdir(adir):
            os.makedirs(adir)
        for f in os.listdir(adir):
            if f.endswith(".png"):
                os.remove(os.path.join(adir, f))

        imgs = [q16(scene(**kw)) for kw in frames]

        # 脏矩形 = 所有帧 vs base 的差异并集
        x0 = y0 = 10 ** 9
        x1 = y1 = -1
        for im in imgs:
            a = np.array(im, dtype=np.int16)
            dd = np.abs(a - ba) > 6
            if dd.sum():
                r = np.where(dd.sum(axis=1) > 0)[0]
                c = np.where(dd.sum(axis=0) > 0)[0]
                x0 = min(x0, int(c.min())); x1 = max(x1, int(c.max()))
                y0 = min(y0, int(r.min())); y1 = max(y1, int(r.max()))
        if x1 < 0:
            print("  无形化，跳过")
            continue
        pad = 6
        rx0, ry0 = max(0, x0 - pad), max(0, y0 - pad)
        rx1, ry1 = min(W, x1 + 1 + pad), min(H, y1 + 1 + pad)
        rw, rh = rx1 - rx0, ry1 - ry0

        diffs = []
        for i, im in enumerate(imgs):
            im.crop((rx0, ry0, rx1, ry1)).save(
                os.path.join(adir, "f%d.png" % i), format="PNG", optimize=True)
            a = np.array(im, dtype=np.int16)
            diffs.append(int((np.abs(a - ba) > 6).sum()))

        print("  矩形 x%d y%d %dx%d  = 屏 %.1f%%" % (rx0, ry0, rw, rh,
                                                   100.0 * rw * rh / (W * H)))
        print("  各帧差异: %s" % " ".join(str(v) for v in diffs))
        manifest.append((name, len(imgs), period, rx0, ry0, rw, rh))

        # 对照图
        th = 260
        tiles = []
        for im in imgs:
            s = th / float(im.size[1])
            tiles.append(im.resize((int(im.size[0] * s), th), Image.LANCZOS))
        cols = min(4, len(tiles))
        rows = (len(tiles) + cols - 1) // cols
        tw = max(t.size[0] for t in tiles)
        sheet = Image.new("L", (cols * (tw + 8) + 8, rows * (th + 8) + 8), 200)
        for i, t in enumerate(tiles):
            r, c = divmod(i, cols)
            sheet.paste(t, (8 + c * (tw + 8), 8 + r * (th + 8)))
        sp = os.path.join(MEDIA, "contact-%s.png" % name)
        sheet.save(sp)
        print("  对照图 -> %s" % sp)

    with open(os.path.join(DIST, "anim.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("# action frames period_ms rectx recty rectw recth\n")
        for m in manifest:
            f.write("%s %d %d %d %d %d %d\n" % m)
    print()
    print("=" * 78)
    print("anim.txt")
    print("=" * 78)
    with open(os.path.join(DIST, "anim.txt"), encoding="ascii") as f:
        print(f.read())


if __name__ == "__main__":
    build()
