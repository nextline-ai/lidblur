"""LidBlur app icon generator.

Produces 1024x1024 layers for Icon Composer (transparent PNGs, plus SVG for the vector layers)
and a masked preview. Run: python3 make_icon.py  (needs numpy + pillow)
"""
import os, math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 4                     # supersampling factor
N = 1024 * S
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Layers")
os.makedirs(OUT, exist_ok=True)

def hexc(h, a=255):
    h = h.lstrip('#'); return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)

# ---------------------------------------------------------------- geometry (1024 units)
SCREEN_BOTTOM_Y, SCREEN_TOP_Y = 676, 236
BOT_X0, BOT_X1 = 196, 828          # bottom (hinge) edge of the lid
TOP_X0, TOP_X1 = 290, 734          # top (outer) edge: narrower -> tilted away
BEZEL = 18                         # bezel thickness around the screen
BASE_Y0, BASE_Y1 = 684, 742        # keyboard deck seen from the front
BASE_X0, BASE_X1 = 128, 896

def u(v): return v * S

def trapezoid(x0b, x1b, x0t, x1t, yb, yt):
    return [(u(x0t), u(yt)), (u(x1t), u(yt)), (u(x1b), u(yb)), (u(x0b), u(yb))]

def rounded_poly_mask(points, radius, size=N):
    """Polygon with rounded corners via morphological open (erode then dilate)."""
    m = Image.new('L', (size, size), 0)
    ImageDraw.Draw(m).polygon(points, fill=255)
    r = int(radius)
    if r > 0:
        m = m.filter(ImageFilter.MinFilter(1))
        # round corners: blur + threshold keeps straight edges, rounds corners
        b = m.filter(ImageFilter.GaussianBlur(r * 0.55))
        a = np.asarray(b).astype(np.float32)
        a = np.clip((a - 127.5) * 4 + 127.5, 0, 255)
        m = Image.fromarray(a.astype(np.uint8))
    return m

def inset(points, d):
    """Inset a convex quad (TL, TR, BR, BL) by d along its edge normals (approx via centroid lines)."""
    (tlx, tly), (trx, try_), (brx, bry), (blx, bly) = points
    # vertical-ish sides: move inwards along x, top/bottom along y; adjust for slant
    def side_shift(x_top, x_bot, y_top, y_bot, sign):
        dx, dy = x_bot - x_top, y_bot - y_top
        L = math.hypot(dx, dy); nx = sign * dy / L
        return d / max(abs(nx), 1e-6) * (1 if sign > 0 else -1)
    lt = side_shift(tlx, blx, tly, bly, 1); rt = side_shift(trx, brx, try_, bry, -1)
    return [(tlx + lt, tly + d), (trx + rt, try_ + d), (brx + rt, bry - d), (blx + lt, bly - d)]

# ---------------------------------------------------------------- background layer
def background():
    y = np.linspace(0, 1, N, dtype=np.float32)[:, None]
    x = np.linspace(0, 1, N, dtype=np.float32)[None, :]
    top = np.array(hexc('#2C3A5C')[:3], np.float32); bot = np.array(hexc('#0D1220')[:3], np.float32)
    g = top * (1 - y[..., None]) + bot * y[..., None]
    g = np.broadcast_to(g, (N, N, 3)).copy()
    # soft light pool behind the screen
    cx, cy = 0.5, 0.42
    d = np.sqrt((x - cx) ** 2 + ((y - cy) * 1.25) ** 2)
    glow = np.exp(-(d / 0.36) ** 2)[..., None] * np.array([78, 64, 160], np.float32) * 0.55
    g = np.clip(g + glow, 0, 255)
    img = Image.fromarray(g.astype(np.uint8), 'RGB').convert('RGBA')
    return img

# ---------------------------------------------------------------- screen content
def wallpaper(w, h):
    """Colorful abstract content with a couple of window shapes (drawn at full res)."""
    img = Image.new('RGBA', (w, h), hexc('#1A1240'))
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    base = np.zeros((h, w, 3), np.float32) + np.array(hexc('#1C1446')[:3], np.float32)
    def blob(cx, cy, rx, ry, col, k=1.0):
        d = ((xx - cx * w) / (rx * w)) ** 2 + ((yy - cy * h) / (ry * h)) ** 2
        return np.exp(-d * 1.6)[..., None] * np.array(col[:3], np.float32) * k
    acc = base
    acc = acc + blob(0.14, 0.86, 0.50, 0.45, hexc('#FF6A3D'), 1.15)
    acc = acc + blob(0.36, 0.62, 0.38, 0.38, hexc('#FF3D7F'), 0.95)
    acc = acc + blob(0.86, 0.70, 0.45, 0.45, hexc('#7B5CFF'), 1.0)
    acc = acc + blob(0.70, 0.22, 0.55, 0.40, hexc('#2FC3FF'), 0.75)
    acc = acc + blob(0.20, 0.25, 0.45, 0.35, hexc('#8A3DFF'), 0.6)
    acc = np.clip(acc, 0, 255)
    img = Image.fromarray(acc.astype(np.uint8), 'RGB').convert('RGBA')
    d = ImageDraw.Draw(img)
    # one app window: crisp near the hinge, it dissolves toward the top in the blur pass
    r = int(0.045 * w)
    x0, y0, x1, y1 = 0.36 * w, 0.40 * h, 0.86 * w, 1.06 * h
    d.rounded_rectangle([x0, y0, x1, y1], radius=r, fill=hexc('#F7F8FC', 228))
    d.rounded_rectangle([x0, y0, x1, y0 + 0.11 * h], radius=r, fill=hexc('#E4E8F1', 255))
    d.rectangle([x0, y0 + 0.06 * h, x1, y0 + 0.11 * h], fill=hexc('#E4E8F1', 255))
    for i, c in enumerate(['#FF5F57', '#FEBC2E', '#28C840']):
        cx = x0 + (0.045 + i * 0.045) * w; cy = y0 + 0.055 * h; rr = 0.016 * w
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=hexc(c))
    for i, frac in enumerate([0.62, 0.44, 0.54]):
        y = 0.60 + i * 0.11
        d.rounded_rectangle([x0 + 0.05 * w, y * h, x0 + (0.05 + 0.45 * frac) * w, (y + 0.045) * h],
                            radius=int(0.02 * w), fill=hexc('#CDD3E0'))
    return img

def blur_gradient(img, top_frac=1.0):
    """Blur grows toward the top edge (row 0) and the image darkens there, like the fold effect."""
    w, h = img.size
    sigmas = [0, 14, 34, 70, 130, 220]
    levels = [np.asarray(img if s == 0 else img.filter(ImageFilter.GaussianBlur(s * S / 4 * 1.0))).astype(np.float32) for s in sigmas]
    t = np.linspace(0, 1, h, dtype=np.float32)          # 0 at top, 1 at bottom (hinge)
    amount = (1 - t) ** 1.15                              # 1 at the top, 0 at the hinge
    pos = amount * (len(sigmas) - 1)
    i0 = np.clip(np.floor(pos).astype(int), 0, len(sigmas) - 2)
    fr = (pos - i0)[:, None, None]
    out = np.zeros_like(levels[0])
    for k in range(len(sigmas) - 1):
        sel = (i0 == k)[:, None, None]
        out = np.where(sel, levels[k] * (1 - fr) + levels[k + 1] * fr, out)
    shade = (0.26 + 0.74 * t ** 0.85)[:, None, None]
    out[..., :3] *= shade
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), 'RGBA')

def screen_layer():
    outer = trapezoid(BOT_X0, BOT_X1, TOP_X0, TOP_X1, SCREEN_BOTTOM_Y, SCREEN_TOP_Y)
    lid_mask = rounded_poly_mask(outer, u(30))
    inner = inset(outer, u(BEZEL))
    scr_mask = rounded_poly_mask(inner, u(16))
    layer = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    # bezel: near-black with a faint vertical sheen
    bez = Image.new('RGBA', (N, N), hexc('#0A0C12'))
    layer.paste(bez, (0, 0), lid_mask)
    # content: render a rectangle covering the screen bbox, warp-free (the panel itself is the tilt cue)
    xs = [p[0] for p in inner]; ys = [p[1] for p in inner]
    bx0, by0, bx1, by1 = int(min(xs)), int(min(ys)), int(max(xs)), int(max(ys))
    content = blur_gradient(wallpaper(bx1 - bx0, by1 - by0))
    full = Image.new('RGBA', (N, N), (0, 0, 0, 0)); full.paste(content, (bx0, by0))
    layer.paste(full, (0, 0), scr_mask)
    return layer

def base_layer():
    layer = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    m = Image.new('L', (N, N), 0)
    ImageDraw.Draw(m).rounded_rectangle([u(BASE_X0), u(BASE_Y0), u(BASE_X1), u(BASE_Y1)], radius=u(24), fill=255)
    # thumb notch at the front edge centre
    ImageDraw.Draw(m).rounded_rectangle([u(452), u(BASE_Y0) - u(10), u(572), u(BASE_Y0) + u(14)], radius=u(12), fill=0)
    yy = np.linspace(0, 1, N, dtype=np.float32)[:, None]
    t = np.clip((yy * 1024 - BASE_Y0) / (BASE_Y1 - BASE_Y0), 0, 1)
    top = np.array(hexc('#F2F4F8')[:3], np.float32); bot = np.array(hexc('#9AA3B3')[:3], np.float32)
    col = top * (1 - t[..., None]) + bot * t[..., None]
    col = np.broadcast_to(col, (N, N, 3))
    alu = Image.fromarray(col.astype(np.uint8), 'RGB').convert('RGBA')
    layer.paste(alu, (0, 0), m)
    return layer

def save(img, name):
    img.resize((1024, 1024), Image.LANCZOS).save(os.path.join(OUT, name))

def preview_mask(size, radius_frac=0.2237):
    """Rounded rect at the macOS icon corner ratio, for previews only (Icon Composer applies the real shape)."""
    m = Image.new('L', (size * 4, size * 4), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, size * 4 - 1, size * 4 - 1], radius=int(size * 4 * radius_frac), fill=255)
    return m.resize((size, size), Image.LANCZOS)

if __name__ == '__main__':
    bg, scr, base = background(), screen_layer(), base_layer()
    save(bg, 'Background.png'); save(scr, 'Screen.png'); save(base, 'Base.png')
    comp = bg.copy(); comp.alpha_composite(scr); comp.alpha_composite(base)
    comp = comp.resize((1024, 1024), Image.LANCZOS)
    comp.save(os.path.join(OUT, '..', 'Composite-1024.png'))
    # preview: inset to the macOS icon grid with a squircle
    body = comp.resize((824, 824), Image.LANCZOS)
    canvas = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
    canvas.paste(body, (100, 100), preview_mask(824))
    canvas.save(os.path.join(OUT, '..', 'Preview-masked.png'))
    # small-size check sheet
    sheet = Image.new('RGBA', (16 + 512 + 16 + 128 + 16 + 64 + 16 + 32 + 16, 544), (236, 236, 240, 255))
    x = 16
    for sz in (512, 128, 64, 32):
        sheet.alpha_composite(canvas.resize((sz, sz), Image.LANCZOS), (x, 16)); x += sz + 16
    sheet.save(os.path.join(OUT, '..', 'Preview-sizes.png'))
    print('ok')
