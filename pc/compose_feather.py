"""带羽化的合成：消除补丁边界硬切。

三个要点：
1. 蒙版 = 原眼睛暗区 ∪ AI 改动区，再膨胀 —— 覆盖"旧眼睛"和"新眼睑"两处
2. 边界用高斯羽化 alpha 混合，不留硬台阶
3. 脏矩形按蒙版算，比整块小，也用 A2 波形
"""

import os
import sys

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage

sys.stdout.reconfigure(encoding="utf-8")

# 路径由参数传入，脚本不含本机路径。
HERE = os.path.dirname(os.path.abspath(__file__))


W, H, PW, PH, PAD = 1072, 1416, 1072, 1608, 96
TH = 60
MIN_BLOB = 300
GROW = 14
FEATHER = 5


def to_full(p, sharpen=20):
    im = Image.open(p).convert("L").resize((PW, PH), Image.LANCZOS)
    if sharpen > 0:
        im = im.filter(ImageFilter.UnsharpMask(radius=1.6, percent=sharpen, threshold=2))
    return np.array(im.crop((0, PAD, W, PAD + H)), dtype=np.uint8)


def q16(a):
    steps = np.arange(8, 249, 16)
    idx = np.abs(a.astype(np.int16)[..., None] - steps[None, None, :]).argmin(axis=2)
    return steps[idx].astype(np.uint8)


def diff_region(base, gen, th=TH):
    raw = np.abs(base.astype(np.int16) - gen.astype(np.int16)) > th
    st = ndimage.generate_binary_structure(2, 2)
    core = ndimage.binary_dilation(ndimage.binary_erosion(raw, st, 2), st, 2)
    lab, n = ndimage.label(core, st)
    keep = np.zeros_like(core)
    for i in range(1, n + 1):
        b = lab == i
        if b.sum() >= MIN_BLOB:
            keep |= b
    return keep


def feather_blend(base, gen, mask, grow=GROW, feather=FEATHER):
    """把 gen 融进 base：mask 内全取 gen，mask 外羽化过渡。"""
    st = ndimage.generate_binary_structure(2, 2)
    grown = ndimage.binary_dilation(mask, st, iterations=grow)
    # alpha: grown 内=1，边界 feather px 内线性降到 0
    dist = ndimage.distance_transform_edt(grown)
    alpha = np.clip(dist / float(feather + 1), 0.0, 1.0)
    out = base.astype(np.float32) * (1 - alpha) + gen.astype(np.float32) * alpha
    return np.clip(out + 0.5, 0, 255).astype(np.uint8), grown


def rect_of_mask(mask, grow=2):
    ys, xs = np.where(mask)
    x0 = max(0, int(xs.min()) - grow)
    y0 = max(0, int(ys.min()) - grow)
    x1 = min(W, int(xs.max()) + 1 + grow)
    y1 = min(H, int(ys.max()) + 1 + grow)
    return (x0, y0, x1 - x0, y1 - y0)


def main(src_dir, work_dir, name, outname, gens):
    base = np.array(Image.open(os.path.join(src_dir, "%s.png" % name)).convert("L"), dtype=np.uint8)
    gens_full = [to_full(g) for g in gens]
    # 蒙版 = 所有 AI 改动区并集
    union = np.zeros((H, W), bool)
    for g in gens_full:
        union |= diff_region(base, g)

    frames = [base]
    for g in gens_full:
        f, grown = feather_blend(base, g, union)
        frames.append(f)

    rect = rect_of_mask(ndimage.binary_dilation(union, np.ones((3, 3), bool), 1), 2)
    x, y, w, h = rect
    d = os.path.join(work_dir, "frames", outname)
    os.makedirs(d, exist_ok=True)
    print("=== %s ===" % outname)
    print("蒙版 %d px  矩形 x=%d y=%d w=%d h=%d (%d px, %.1f%% 屏) -> %s"
          % (union.sum(), x, y, w, h, w * h, 100.0 * w * h / (W * H),
             "GC16" if w * h > 180000 else "A2"))

    for i, f in enumerate(frames):
        q = q16(f)
        p = q[y:y + h, x:x + w]
        fp = os.path.join(d, "f%d.png" % i)
        Image.fromarray(p, "L").save(fp)
        print("  f%d %dx%d %dB" % (i, w, h, os.path.getsize(fp)))

    open(os.path.join(d, "rect.txt"), "w").write("%d %d %d %d\n" % rect)
    Image.fromarray(frames[-1], "L").save(os.path.join(d, "preview-full.png"))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5:])
