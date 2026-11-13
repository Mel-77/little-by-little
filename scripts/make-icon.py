#!/usr/bin/env python3
"""生成 Dayline 的 .icns 图标（纸感卡片 + 三条色块 + 一个勾）。"""
import os
import subprocess
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT_ICONSET = os.path.join(ROOT, "build", "AppIcon.iconset")

S = 2048  # 超采样画布
PAPER_A = (255, 253, 247)
PAPER_B = (245, 236, 220)
INK = (44, 41, 36)
ACCENT = (194, 91, 69)
BAR_G = (207, 223, 196)
BAR_B = (198, 216, 233)
BAR_O = (243, 201, 182)


def rounded(size, radius, fill):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=fill)
    return img


def main():
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # 底部阴影
    pad = int(S * 0.075)
    body = S - pad * 2
    radius = int(body * 0.225)

    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle(
        [pad, pad + int(S * 0.012), pad + body, pad + body + int(S * 0.012)],
        radius=radius,
        fill=(60, 45, 30, 70),
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(int(S * 0.018)))
    canvas.alpha_composite(shadow)

    # 纸面：上浅下深的竖向渐变
    paper = rounded(body, radius, (255, 255, 255, 255))
    grad = Image.new("RGBA", (body, body), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    for y in range(body):
        t = y / body
        c = tuple(int(PAPER_A[i] + (PAPER_B[i] - PAPER_A[i]) * t) for i in range(3))
        gd.line([(0, y), (body, y)], fill=c + (255,))
    paper.paste(grad, (0, 0), paper)
    canvas.alpha_composite(paper, (pad, pad))

    d = ImageDraw.Draw(canvas)

    # 内描边
    d.rounded_rectangle(
        [pad, pad, pad + body - 1, pad + body - 1],
        radius=radius,
        outline=(90, 72, 46, 60),
        width=int(S * 0.004),
    )

    # 三条“时间块”，左端对齐一条虚线般的竖轨
    x0 = pad + int(body * 0.155)
    rx = int(body * 0.045)
    rows = [
        (0.300, 0.470, 0.118, BAR_G),
        (0.450, 0.340, 0.118, BAR_B),
        (0.600, 0.415, 0.118, BAR_O),
    ]
    for ty, wfrac, hfrac, color in rows:
        y = pad + int(body * ty)
        h = int(body * hfrac)
        w = int(body * wfrac)
        d.rounded_rectangle([x0, y, x0 + w, y + h], radius=int(h * 0.34), fill=color + (255,))

    # 勾：右下角的圆 + 白色对勾
    cx = pad + int(body * 0.715)
    cy = pad + int(body * 0.510)
    r = int(body * 0.175)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=ACCENT + (255,))
    lw = int(body * 0.048)
    p1 = (cx - r * 0.42, cy + r * 0.02)
    p2 = (cx - r * 0.08, cy + r * 0.36)
    p3 = (cx + r * 0.45, cy - r * 0.34)
    d.line([p1, p2], fill=(255, 249, 242, 255), width=lw, joint="curve")
    d.line([p2, p3], fill=(255, 249, 242, 255), width=lw, joint="curve")
    for p in (p1, p2, p3):
        d.ellipse([p[0] - lw / 2, p[1] - lw / 2, p[0] + lw / 2, p[1] + lw / 2],
                  fill=(255, 249, 242, 255))

    # 输出 iconset
    os.makedirs(OUT_ICONSET, exist_ok=True)
    specs = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    for name, size in specs:
        canvas.resize((size, size), Image.LANCZOS).save(os.path.join(OUT_ICONSET, name))

    icns = os.path.join(ROOT, "build", "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", OUT_ICONSET, "-o", icns], check=True)
    print("icon ok ->", icns)


if __name__ == "__main__":
    main()
