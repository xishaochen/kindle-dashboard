"""用离散姿势切换重建动画帧（不做任何交叉混合）。

为什么必须放弃补间：
  尾巴是实心形状在移动。把「原位」和「抬起」各取 50% 混合，屏幕上就同时看到
  两条半透明尾巴叠在一起 —— 在 e-ink 上就是一团灰雾，尾巴尖也会从实心黑变灰。
  交叉淡化 = 双重曝光，对移动的实心物体永远不可能成立。

正确做法（传统定格/二帧动画）：
  只用两个已渲染好的干净姿势，靠**停留时长**表达节奏，靠**来回切换**表达动作。
  没有中间混合，每一帧都是纯原图或纯 AI 帧，零灰雾。

用法：
  python anim_frames.py <base.png> <动作>=<生成图>:<疏密序列>:<间隔ms> ...
  例：python anim_frames.py sit.png blur=BGBGBB:120
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image

sys.stdout.reconfigure(encoding="utf-8")

W, H, PW, PH, PAD = 1072, 1416, 1072, 1608, 96
PAL = np.arange(8, 249, 16)          # 原图真实使用的 16 级色阶


def to_full(p):
    """把生成图还原到画布尺寸并裁掉补白（与生成时对称补白互为逆操作）。"""
    im = Image.open(p).convert("L").resize((PW, PH), Image.LANCZOS)
    return np.array(im.crop((0, PAD, W, PAD + H)), dtype=np.uint8)


def snap(a):
    """吸附到 16 级色阶：把连续渐变还原成硬边色块（e-ink 只有 16 级灰）。"""
    idx = np.abs(a.astype(np.int16)[..., None] - PAL[None, None, :]).argmin(axis=2)
    return PAL[idx].astype(np.uint8)


def build(base_arr, gen_arr, rect, seq, per, outdir):
    x, y, w, h = rect
    os.makedirs(outdir, exist_ok=True)
    bp = base_arr[y:y + h, x:x + w]
    gp = snap(gen_arr[y:y + h, x:x + w])

    for i, c in enumerate(seq):
        patch = bp if c == "B" else gp
        Image.fromarray(patch, "L").save(os.path.join(outdir, "f%d.png" % i))
        gray = int(((patch > 100) & (patch < 200)).sum())
        print("  f%d = %s  中间灰 %6d px" % (i, "原位" if c == "B" else "AI帧", gray))

    with open(os.path.join(outdir, "anim.txt"), "w") as f:
        f.write("n %d\nper %d\nrect %d %d %d %d\n" % (len(seq), per, x, y, w, h))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("base", help="原底图（如 sit.png）")
    ap.add_argument("--out", required=True, help="输出根目录，每个动作一个子目录")
    ap.add_argument("--rects", required=True,
                    help="矩形定义目录，每个动作一个 <name>/rect.txt")
    ap.add_argument("spec", nargs="+",
                    help="<动作>=<生成图>:<序列>:<间隔ms>，序列用 B/G，如 blink=x.png:BGGBBB:120")
    a = ap.parse_args()

    base_arr = np.array(Image.open(a.base).convert("L"), dtype=np.uint8)
    if base_arr.shape != (H, W):
        print("警告：底图尺寸 %s，预期 (%d,%d)" % (base_arr.shape, H, W))

    summary = []
    for s in a.spec:
        name_eq, gen, seq, per = s.split("=")[0], s.split("=")[1].split(":")[0], \
            s.split(":")[1], int(s.split(":")[2])
        rect = tuple(int(v) for v in open(os.path.join(a.rects, name_eq, "rect.txt")).read().split())
        print("=== %s  per=%dms  rect=%dx%d ===" % (name_eq, per, rect[2], rect[3]))
        build(base_arr, to_full(gen), rect, seq, per, os.path.join(a.out, name_eq))
        summary.append("%s %d %d %d %d %d %d" % (name_eq, len(seq), per, *rect))

    with open(os.path.join(a.out, "anim.txt"), "w") as f:
        f.write("\n".join(summary) + "\n")
    print()
    print("=== anim.txt ===")
    print("\n".join(summary))


if __name__ == "__main__":
    main()
