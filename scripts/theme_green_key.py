# テーマ画像の緑背景（#00FF00）を透過 PNG にする。ピンクや紫を含む絵（マゼンタ抜きだと欠ける）に使う。
# 使い方: python3 scripts/theme_green_key.py in.jpg:out.png ...   （numpy / Pillow / scipy が要る）
import sys, numpy as np
from PIL import Image
from scipy import ndimage

def key(src, dst):
    a = np.asarray(Image.open(src).convert("RGB")).astype(np.float32) / 255
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    dom = g - np.maximum(r, b)                      # 緑の強さ
    alpha = 1 - np.clip((dom - 0.10) / 0.30, 0, 1)
    near = ndimage.binary_dilation(alpha < 0.98, iterations=3)
    g2 = np.where(near & (g > np.maximum(r, b)), np.maximum(r, b), g)   # 縁の緑かぶりを取る
    out = np.stack([r, g2, b, alpha], -1)
    soft = ndimage.gaussian_filter(alpha, 0.6)
    out[..., 3] = np.minimum(alpha, soft + 0.02).clip(0, 1)
    lab, n = ndimage.label(out[..., 3] > 0.2)
    if n > 1:
        sizes = ndimage.sum(np.ones_like(lab), lab, range(1, n + 1))
        for i, s in enumerate(sizes, 1):
            if s < 300: out[..., 3][lab == i] = 0
    im = Image.fromarray((out * 255).astype(np.uint8), "RGBA")
    im = im.crop(im.getbbox())
    im.save(dst, optimize=True)
    print(dst, im.size)

for spec in sys.argv[1:]:
    src, dst = spec.split(":")
    key(src, dst)
