"""GIF 展示页 v4（定版）：v2 净化背景 + 相框内加白边。

放弃 v3 的 2.9x。原因是实测出来的：
  源 GIF 主体 bbox 正好等于整帧（0-174 x 0-256），说明源素材本身
  鼻子和脚就被裁在边缘。放大只会把这个"已经切断"的边缘放得更明显。

v4 的做法：
  * 内容仍按 2.6x 缩放（v2 的清晰度已经被真机确认）
  * 但不再直接铺满相框，而是先贴到一张四周留 28px 纯白的内画布上
  * 这样主体与相框之间有空隙，视觉上"完整"，而不是被框切断
  * 内画布是纯白，与背景同色，所以刷新时这部分不产生变化、不影响帧率

同时修正 v3 的净化 bug：
  v3 把 purify_bg 用在了"放大并量化之后"，而那时大象腹下的浅色
  已经被平滑成 >=234 的值，于是被当成背景洗掉了。
  只在"原尺寸、平滑之前"净化一次，且阈值收紧到 190。
"""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageSequence
from scipy import ndimage

sys.stdout.reconfigure(encoding="utf-8")

KD = r"C:\Users\杰西卡\AppData\Roaming\ClawHiveApp\accounts\acct_57620a774ce086ad\tenants\tnt_daa8c7e0700de6fe\workspace\kindle-dashboard"
G = r"C:\Users\杰西卡\AppData\Roaming\ClawHiveApp\accounts\acct_57620a774ce086ad\tenants\tnt_daa8c7e0700de6fe\openclaw\state\media\outgoing\originals"

W, H = 1072, 1416
PAL = np.arange(8, 249, 16)
WHITE = 248
PAD = 28          # 内容与相框之间的白边


def snap16(a):
    idx = np.abs(a.astype(np.int16)[..., None] - PAL[None, None, :]).argmin(axis=2)
    return PAL[idx].astype(np.uint8)


def font(sz, bold=False):
    for p in ((r"C:\Windows\Fonts\msyhbd.ttc" if bold else r"C:\Windows\Fonts\msyh.ttc"),
              r"C:\Windows\Fonts\msyh.ttc"):
        try:
            return ImageFont.truetype(p, sz)
        except Exception:
            continue
    return ImageFont.load_default()


def composite(path):
    im = Image.open(path)
    out, durs, canvas = [], [], None
    for fr in ImageSequence.Iterator(im):
        durs.append(fr.info.get("duration", 100))
        rgba = fr.convert("RGBA")
        if canvas is None:
            canvas = Image.new("RGBA", im.size, (255, 255, 255, 255))
        canvas = Image.alpha_composite(canvas, rgba)
        out.append(canvas.convert("RGB").copy())
        if fr.disposal_method == 2:
            canvas.paste(Image.new("RGBA", im.size, (255, 255, 255, 255)), (0, 0))
    return out, durs


def purify_bg(a, thr=190):
    """只把与边界连通的极浅区域推成纯白。阈值 190 是为了不误伤主体浅色区。"""
    light = a >= thr
    lab, n = ndimage.label(light)
    if n == 0:
        return a.copy()
    border = set(lab[0, :].tolist()) | set(lab[-1, :].tolist())
    border |= set(lab[:, 0].tolist()) | set(lab[:, -1].tolist())
    border.discard(0)
    if not border:
        return a.copy()
    out = a.copy()
    out[np.isin(lab, list(border))] = WHITE
    return out


def build(src_gif, outdir, title, subtitle, credit, scale=2.6, blur=1.0):
    os.makedirs(outdir, exist_ok=True)
    for old in os.listdir(outdir):
        if old.startswith("f") and old.endswith(".png"):
            os.remove(os.path.join(outdir, old))

    frames, durs = composite(src_gif)
    per = int(np.median(durs)) if durs else 100
    n = len(frames)
    src_w, src_h = frames[0].size
    cw, ch = int(src_w * scale), int(src_h * scale)     # 内容尺寸
    aw, ah = cw + 2 * PAD, ch + 2 * PAD                  # 帧图尺寸（含白边）

    TITLE_H, FOOT_H = 142, 136
    stage_h = H - TITLE_H - FOOT_H
    ax = (W - aw) // 2
    ay = TITLE_H + (stage_h - ah) // 2

    print("源 %s  %d 帧  %dms  %dx%d" % (os.path.basename(src_gif), n, per, src_w, src_h))
    print("  内容 %.2fx -> %dx%d   加白边 %dpx -> 帧图 %dx%d @ (%d,%d)"
          % (scale, cw, ch, PAD, aw, ah, ax, ay))

    # 1) 原尺寸净化 + 平滑（顺序关键：先净化再平滑，避免平滑把浅色推到阈值以上）
    proc = []
    for f in frames:
        a = np.array(f.convert("L")).astype(np.float32)
        a = purify_bg(a, 190)
        if blur > 0:
            a = ndimage.gaussian_filter(a, blur)
        proc.append(a)

    stack = np.stack(proc)
    lo, hi = np.percentile(stack, 2.0), np.percentile(stack, 98.0)
    if hi - lo > 20:
        proc = [np.clip((p - lo) * (240.0 / (hi - lo)) + 8.0, 0, 255) for p in proc]

    # 2) 缩放内容 -> 贴到含白边的纯白画布
    for i, a in enumerate(proc):
        img = Image.fromarray(a.astype(np.uint8), "L").resize((cw, ch), Image.LANCZOS)
        canvas = Image.new("L", (aw, ah), WHITE)
        canvas.paste(img, (PAD, PAD))
        arr = snap16(np.array(canvas))
        Image.fromarray(arr, "L").save(os.path.join(outdir, "f%d.png" % i))

    # 3) 背景页
    bg = Image.new("L", (W, H), WHITE)
    dr = ImageDraw.Draw(bg)
    dr.text((56, 30), title, fill=8, font=font(48, True))
    dr.text((56, 92), subtitle, fill=96, font=font(24))
    dr.rectangle([ax - 4, ay - 4, ax + aw + 3, ay + ah + 3], outline=150, width=2)
    fy = H - FOOT_H + 18
    dr.text((56, fy), "%d 帧 · %d ms/帧 · %.1f fps" % (n, per, 1000.0 / per),
            fill=40, font=font(26))
    dr.text((56, fy + 38), credit, fill=110, font=font(20))
    dr.text((56, fy + 70), "Kindle GC16 · 局部刷新 %dx%d" % (aw, ah),
            fill=150, font=font(20))
    bg_a = snap16(np.array(bg))
    Image.fromarray(bg_a, "L").save(os.path.join(outdir, "bg.png"))

    with open(os.path.join(outdir, "anim.txt"), "w") as f:
        f.write("n %d\nper %d\nrect %d %d %d %d\n" % (n, per, ax, ay, aw, ah))
    meta = {"n": n, "per": per, "rect": [ax, ay, aw, ah], "scale": scale, "pad": PAD}
    with open(os.path.join(outdir, "meta.json"), "w") as f:
        json.dump(meta, f, ensure_ascii=False, indent=1)

    # 验收：主体不得贴帧图边缘
    fa = np.array(Image.open(os.path.join(outdir, "f0.png")).convert("L")).astype(np.int16)
    m = fa < 200
    edge = (int(m[0, :].sum()), int(m[-1, :].sum()), int(m[:, 0].sum()), int(m[:, -1].sum()))
    ys, xs = np.nonzero(m)
    d = np.abs(np.diff(fa, axis=1))
    print("  帧图 %dx%d  灰阶 %d  跳变>20 %.2f%%  贴边(上,下,左,右)=%s  主体bbox y%d-%d x%d-%d"
          % (aw, ah, len(np.unique(fa)), 100.0 * (d > 20).mean(), edge,
             ys.min(), ys.max(), xs.min(), xs.max()))

    prev = Image.fromarray(bg_a, "L").copy()
    prev.paste(Image.open(os.path.join(outdir, "f0.png")), (ax, ay))
    p = os.path.join(G, "editref", "gifpage-v4.png")
    prev.save(p)
    print("  版式预览 ->", p)
    return meta


def main():
    out = os.path.join(KD, "dist", "cat6", "gifpage")
    m = build(os.path.join(KD, "gifwork", "elephant.gif"), out,
              "GIF 展示页", "大象行走 · Wikimedia Commons",
              "素材：Elephant Walking animated.gif · Public domain", scale=2.6)
    print()
    print("meta =", json.dumps(m, ensure_ascii=False))


if __name__ == "__main__":
    main()
