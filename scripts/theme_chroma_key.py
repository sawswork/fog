# テーマ画像のマゼンタ背景（#FF00FF）を透過 PNG にする。使い方: python3 scripts/theme_chroma_key.py in.jpg:out.png[:sq] ...  （sq は正方形に切る。numpy / Pillow / scipy が要る）
import sys, numpy as np
from PIL import Image
def key(src, dst, margin=0.02, square=False):
    im = Image.open(src).convert("RGB"); a = np.asarray(im).astype(np.float32)/255
    r,g,b = a[...,0],a[...,1],a[...,2]
    mx = a.max(-1); mn = a.min(-1); d = mx-mn
    sat = np.where(mx>0, d/np.maximum(mx,1e-6), 0); val = mx
    h = np.zeros_like(mx)
    m = d>0
    rm = m&(mx==r); gm = m&(mx==g)&~rm; bm = m&~rm&~gm
    h[rm] = (60*((g-b)/np.maximum(d,1e-6)))[rm] % 360
    h[gm] = (60*((b-r)/np.maximum(d,1e-6)+2))[gm]
    h[bm] = (60*((r-g)/np.maximum(d,1e-6)+4))[bm]
    # hue closeness to magenta (300): 1 inside 288..332, 0 outside 268..352
    hc = np.clip(np.minimum((h-268)/20, (352-h)/20), 0, 1)
    k = hc * np.clip((sat-0.25)/0.3, 0, 1) * np.clip((val-0.25)/0.15, 0, 1)
    alpha = 1 - k
    # despill where partially keyed or green below the r/b average (magenta tint), near the edge
    from scipy import ndimage
    near = ndimage.binary_dilation(alpha < 0.98, iterations=3)
    avg = (r+b)/2
    spill = near & (g < avg)
    g2 = np.where(spill, avg, g)
    out = np.stack([r, g2, b, alpha], -1)
    # un-mix: edge pixels = fg*alpha + magenta*(1-alpha) -> estimate fg
    mag = np.array([1,0,1],dtype=np.float32)
    al = np.clip(alpha,0.05,1)[...,None]
    fg = (out[...,:3] - mag*(1-al))/al
    fg = np.where((alpha<0.98)[...,None], np.clip(fg,0,1), out[...,:3])
    out[...,:3] = fg
    out[...,3] = np.where(alpha<0.04, 0, alpha)
    rgba = (out*255).round().astype(np.uint8)
    ys,xs = np.where(rgba[...,3] > 10)
    H,W = rgba.shape[:2]
    if len(xs)==0: x0,x1,y0,y1 = 0,W,0,H
    else:
        my,mxg = int(H*margin), int(W*margin)
        x0,x1 = max(0,xs.min()-mxg), min(W,xs.max()+mxg+1); y0,y1 = max(0,ys.min()-my), min(H,ys.max()+my+1)
    if square:
        cx,cy = (x0+x1)//2,(y0+y1)//2; s = max(x1-x0,y1-y0)//2
        x0,x1,y0,y1 = max(0,cx-s),min(W,cx+s),max(0,cy-s),min(H,cy+s)
    Image.fromarray(rgba[y0:y1,x0:x1]).save(dst, optimize=True)
    print(dst, (x1-x0, y1-y0), "keyed%", round(100*(1-alpha.mean()),1))
for spec in sys.argv[1:]:
    src,dst,*opt = spec.split(":")
    key(src,dst,square=("sq" in opt))
