"""Génère l'icône TrackData (1024 px) et ses variantes iOS. Usage : python3 scripts/generer-icone.py App/Assets.xcassets/AppIcon.appiconset"""
"""Génère des propositions d'icône TrackData (1024 px) + une planche de comparaison."""
import math
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

S = 2048  # rendu en 2x puis réduit (anti-crénelage)
FONT_COND = "/usr/share/fonts/truetype/roboto/unhinted/RobotoCondensed-BoldItalic.ttf"
FONT_BLACK = "/usr/share/fonts/truetype/lato/Lato-BlackItalic.ttf"

CYAN = (0, 214, 255)
BLUE = (40, 110, 255)
ORANGE = (255, 140, 0)
RED = (255, 45, 60)
WHITE = (255, 255, 255)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(len(a)))


def multi(colors, t):
    t = min(max(t, 0), 1)
    n = len(colors) - 1
    i = min(int(t * n), n - 1)
    return lerp(colors[i], colors[i + 1], t * n - i)


def radial_bg(c_in, c_out, center=(0.5, 0.42), radius=0.85):
    y, x = np.mgrid[0:S, 0:S].astype(np.float32) / S
    d = np.sqrt((x - center[0]) ** 2 + (y - center[1]) ** 2) / radius
    d = np.clip(d, 0, 1)[..., None]
    img = np.array(c_in, np.float32) * (1 - d) + np.array(c_out, np.float32) * d
    return Image.fromarray(img.astype(np.uint8), "RGB").convert("RGBA")


def carbon(base=18, amp=16, cell=36):
    """Texture fibre de carbone (sergé) tournée à 45°."""
    n = S * 2
    y, x = np.mgrid[0:n, 0:n].astype(np.float32)
    cx = (x // cell).astype(int)
    cy = (y // cell).astype(int)
    fx = (x % cell) / cell
    fy = (y % cell) / cell
    horiz = (cx + cy) % 2 == 0
    shade = np.where(horiz, np.sin(fy * math.pi), np.sin(fx * math.pi))
    v = base + amp * shade
    tex = Image.fromarray(np.clip(v, 0, 255).astype(np.uint8), "L").rotate(45, resample=Image.BICUBIC)
    tex = tex.crop((n // 4, n // 4, n // 4 + S, n // 4 + S))
    rgb = Image.merge("RGB", (tex, tex, tex.point(lambda p: min(255, p + 4))))
    return rgb.convert("RGBA")


def vignette(img, strength=0.55):
    y, x = np.mgrid[0:S, 0:S].astype(np.float32) / S
    d = np.sqrt((x - 0.5) ** 2 + (y - 0.5) ** 2) / 0.72
    m = 1 - strength * np.clip(d, 0, 1) ** 2
    arr = np.array(img).astype(np.float32)
    arr[..., :3] *= m[..., None]
    return Image.fromarray(arr.clip(0, 255).astype(np.uint8), "RGBA")


def gradient_arc(layer, center, radius, width, start, end, colors, steps=360):
    d = ImageDraw.Draw(layer)
    box = [center[0] - radius, center[1] - radius, center[0] + radius, center[1] + radius]
    for i in range(steps):
        a0 = start + (end - start) * i / steps
        a1 = start + (end - start) * (i + 1.6) / steps
        d.arc(box, a0, a1, fill=multi(colors, i / steps) + (255,), width=width)
    # extrémités arrondies
    for ang, col in ((start, colors[0]), (end, colors[-1])):
        r = radius - width / 2
        px = center[0] + r * math.cos(math.radians(ang))
        py = center[1] + r * math.sin(math.radians(ang))
        d.ellipse([px - width / 2, py - width / 2, px + width / 2, py + width / 2], fill=col + (255,))


def add_glow(base, layer, blur, strength=1.0):
    glow = layer.filter(ImageFilter.GaussianBlur(blur))
    if strength != 1.0:
        a = glow.getchannel("A").point(lambda p: min(255, int(p * strength)))
        glow.putalpha(a)
    base = Image.alpha_composite(base, glow)
    return Image.alpha_composite(base, layer)


def finish(img):
    return img.resize((1024, 1024), Image.LANCZOS).convert("RGB")


# ---------------------------------------------------------------- A : cadran carbone
def concept_a():
    img = vignette(carbon(), 0.6)
    c = (S / 2, S * 0.52)
    R = S * 0.36
    track = Image.new("RGBA", (S, S))
    ImageDraw.Draw(track).arc([c[0] - R, c[1] - R, c[0] + R, c[1] + R], 135, 405, fill=(255, 255, 255, 28), width=int(S * 0.07))
    img = Image.alpha_composite(img, track)
    # graduations
    ticks = Image.new("RGBA", (S, S))
    td = ImageDraw.Draw(ticks)
    for k in range(0, 28):
        ang = math.radians(135 + 270 * k / 27)
        r1, r2 = R - S * 0.075, R - S * (0.11 if k % 3 == 0 else 0.092)
        td.line([c[0] + r1 * math.cos(ang), c[1] + r1 * math.sin(ang), c[0] + r2 * math.cos(ang), c[1] + r2 * math.sin(ang)],
                fill=(255, 255, 255, 170 if k % 3 == 0 else 90), width=int(S * (0.008 if k % 3 == 0 else 0.005)))
    img = Image.alpha_composite(img, ticks)
    arc = Image.new("RGBA", (S, S))
    gradient_arc(arc, c, R + S * 0.035, int(S * 0.07), 135, 135 + 270 * 0.80, [CYAN, BLUE, ORANGE, RED])
    img = add_glow(img, arc, S * 0.03, 1.2)
    # aiguille
    needle = Image.new("RGBA", (S, S))
    nd = ImageDraw.Draw(needle)
    ang = math.radians(135 + 270 * 0.80)
    tip = (c[0] + R * 0.98 * math.cos(ang), c[1] + R * 0.98 * math.sin(ang))
    perp = ang + math.pi / 2
    w = S * 0.022
    base1 = (c[0] + w * math.cos(perp), c[1] + w * math.sin(perp))
    base2 = (c[0] - w * math.cos(perp), c[1] - w * math.sin(perp))
    nd.polygon([base1, tip, base2], fill=(255, 70, 50, 255))
    img = add_glow(img, needle, S * 0.02, 1.0)
    hub = Image.new("RGBA", (S, S))
    hd = ImageDraw.Draw(hub)
    hr = S * 0.055
    hd.ellipse([c[0] - hr, c[1] - hr, c[0] + hr, c[1] + hr], fill=(30, 32, 36, 255), outline=(200, 205, 215, 255), width=int(S * 0.012))
    img = Image.alpha_composite(img, hub)
    # monogramme
    txt = Image.new("RGBA", (S, S))
    f = ImageFont.truetype(FONT_COND, int(S * 0.15))
    tdraw = ImageDraw.Draw(txt)
    tdraw.text((S / 2, S * 0.83), "TD", font=f, anchor="mm", fill=(255, 255, 255, 235))
    img = Image.alpha_composite(img, txt)
    return finish(img)


# ---------------------------------------------------------------- B : piste lumineuse
def track_points(n=1200):
    """Circuit stylisé : ligne droite, épingle, chicane, grande courbe (spline fermée)."""
    ctrl = [(-0.80, 0.62), (0.10, 0.62), (0.72, 0.60), (0.92, 0.38), (0.80, 0.12), (0.45, 0.05),
            (0.30, -0.18), (0.55, -0.42), (0.62, -0.70), (0.30, -0.82), (-0.20, -0.62), (-0.45, -0.70),
            (-0.80, -0.55), (-0.90, -0.20), (-0.62, 0.02), (-0.92, 0.30)]
    m = len(ctrl)
    pts = []
    per = n // m
    for i in range(m):
        p0, p1, p2, p3 = ctrl[(i - 1) % m], ctrl[i], ctrl[(i + 1) % m], ctrl[(i + 2) % m]
        for k in range(per):
            t = k / per
            t2, t3 = t * t, t * t * t
            x = 0.5 * ((2 * p1[0]) + (-p0[0] + p2[0]) * t + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2 + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3)
            y = 0.5 * ((2 * p1[1]) + (-p0[1] + p2[1]) * t + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3)
            pts.append((x, y))
    return pts


def concept_b():
    img = radial_bg((24, 36, 62), (3, 5, 10), center=(0.5, 0.42), radius=0.85)
    pts = track_points()
    c = (S / 2, S * 0.5)
    scale = S * 0.38
    P = [(c[0] + x * scale, c[1] + y * scale) for x, y in pts]
    n = len(P)
    # bitume
    asphalt = Image.new("RGBA", (S, S))
    ad = ImageDraw.Draw(asphalt)
    ad.line(P + [P[0]], fill=(255, 255, 255, 26), width=int(S * 0.085), joint="curve")
    img = Image.alpha_composite(img, asphalt)
    # trajectoire lumineuse en dégradé (bleu froid → rouge au point le plus rapide)
    line = Image.new("RGBA", (S, S))
    ld = ImageDraw.Draw(line)
    w = int(S * 0.032)
    for i in range(n):
        col = multi([CYAN, BLUE, (150, 80, 255), ORANGE, RED, CYAN], i / n)
        ld.line([P[i], P[(i + 1) % n]], fill=col + (255,), width=w)
        ld.ellipse([P[i][0] - w / 2, P[i][1] - w / 2, P[i][0] + w / 2, P[i][1] + w / 2], fill=col + (255,))
    img = add_glow(img, line, S * 0.028, 1.4)
    # ligne de départ / arrivée en damier, perpendiculaire à la ligne droite du bas
    flag = Image.new("RGBA", (S, S))
    fd = ImageDraw.Draw(flag)
    fx, fy = c[0] + 0.0 * scale, c[1] + 0.62 * scale
    sq = S * 0.022
    for row in range(2):
        for col in range(4):
            if (row + col) % 2 == 0:
                x0 = fx - sq + row * sq
                y0 = fy - 2 * sq + col * sq
                fd.rectangle([x0, y0, x0 + sq, y0 + sq], fill=(255, 255, 255, 255))
            else:
                x0 = fx - sq + row * sq
                y0 = fy - 2 * sq + col * sq
                fd.rectangle([x0, y0, x0 + sq, y0 + sq], fill=(10, 10, 14, 255))
    img = Image.alpha_composite(img, flag)
    # la voiture : point blanc lumineux
    car = Image.new("RGBA", (S, S))
    cd = ImageDraw.Draw(car)
    px, py = P[int(n * 0.31)]
    r = S * 0.032
    cd.ellipse([px - r, py - r, px + r, py + r], fill=WHITE + (255,))
    img = add_glow(img, car, S * 0.035, 1.6)
    return finish(img)


# ---------------------------------------------------------------- C : monogramme TD
def concept_c():
    img = radial_bg((40, 44, 52), (8, 9, 12), center=(0.3, 0.2), radius=1.1)
    # bandes de vitesse
    stripes = Image.new("RGBA", (S, S))
    sd = ImageDraw.Draw(stripes)
    for i, col in enumerate([CYAN, BLUE, ORANGE]):
        x0 = S * (0.05 + i * 0.075)
        sd.polygon([(x0, S * 0.80), (x0 + S * 0.05, S * 0.80), (x0 + S * 0.05 + S * 0.32, S * 0.18), (x0 + S * 0.32, S * 0.18)], fill=col + (235,))
    img = add_glow(img, stripes, S * 0.02, 0.9)
    txt = Image.new("RGBA", (S, S))
    f = ImageFont.truetype(FONT_BLACK, int(S * 0.46))
    td = ImageDraw.Draw(txt)
    td.text((S * 0.56, S * 0.50), "TD", font=f, anchor="mm", fill=WHITE + (255,))
    shadow = txt.filter(ImageFilter.GaussianBlur(S * 0.02))
    shadow = Image.merge("RGBA", (*[Image.new("L", (S, S), 0)] * 3, shadow.getchannel("A").point(lambda p: int(p * 0.8))))
    img = Image.alpha_composite(img, shadow)
    img = Image.alpha_composite(img, txt)
    # barre « data » en dégradé sous le monogramme
    bar = Image.new("RGBA", (S, S))
    bd = ImageDraw.Draw(bar)
    x0, x1, y0 = S * 0.30, S * 0.86, S * 0.775
    steps = 200
    for i in range(steps):
        xa = x0 + (x1 - x0) * i / steps
        xb = x0 + (x1 - x0) * (i + 1.5) / steps
        bd.polygon([(xa, y0), (xb, y0), (xb - S * 0.012, y0 + S * 0.035), (xa - S * 0.012, y0 + S * 0.035)],
                   fill=multi([CYAN, BLUE, ORANGE, RED], i / steps) + (255,))
    img = add_glow(img, bar, S * 0.02, 1.2)
    return finish(img)


# ---------------------------------------------------------------- D : arc + graphe (minimal)
def concept_d():
    img = radial_bg((16, 22, 38), (0, 0, 0), center=(0.5, 0.4), radius=0.95)
    c = (S / 2, S * 0.62)
    R = S * 0.38
    # grille discrète
    grid = Image.new("RGBA", (S, S))
    gdd = ImageDraw.Draw(grid)
    for k in range(1, 4):
        gdd.arc([c[0] - R * k / 4, c[1] - R * k / 4, c[0] + R * k / 4, c[1] + R * k / 4], 180, 360, fill=(255, 255, 255, 22), width=int(S * 0.006))
    img = Image.alpha_composite(img, grid)
    arc = Image.new("RGBA", (S, S))
    gradient_arc(arc, c, R, int(S * 0.095), 180, 360, [CYAN, BLUE, ORANGE, RED])
    img = add_glow(img, arc, S * 0.04, 1.3)
    graph = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(graph)
    pts = []
    for i in range(120):
        t = i / 119
        x = c[0] - R * 0.66 + t * R * 1.30
        y = c[1] - R * 0.06 - R * 0.62 * (t ** 2.2) + R * 0.035 * math.sin(t * 16) * (1 - t)
        pts.append((x, y))
    gd.line(pts, fill=WHITE + (255,), width=int(S * 0.026), joint="curve")
    ex, ey = pts[-1]
    r = S * 0.04
    gd.ellipse([ex - r, ey - r, ex + r, ey + r], fill=WHITE + (255,))
    img = add_glow(img, graph, S * 0.025, 1.2)
    return finish(img)


def rounded(img, radius_ratio=0.2237):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], radius=int(img.size[0] * radius_ratio), fill=255)
    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)
    return out



NAVY = (14, 20, 36)


def curve_points(c, R, x_from, x_to, n=160):
    """Courbe type montée en puissance : départ plat, montée franche, léger plateau en haut."""
    pts = []
    for i in range(n):
        t = i / (n - 1)
        s = 1 / (1 + math.exp(-10 * (t - 0.52)))           # sigmoïde
        s0, s1 = 1 / (1 + math.exp(5.2)), 1 / (1 + math.exp(-4.8))
        s = (s - s0) / (s1 - s0)
        x = c[0] + R * (x_from + (x_to - x_from) * t)
        y = c[1] - R * 0.10 - R * 0.64 * s
        pts.append((x, y))
    return pts


def area_fill(pts, base_y, color):
    """Dégradé vertical sous la courbe."""
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).polygon(pts + [(pts[-1][0], base_y), (pts[0][0], base_y)], fill=255)
    top = min(p[1] for p in pts)
    y = np.arange(S, dtype=np.float32)
    alpha = np.clip(1 - (y - top) / max(base_y - top, 1), 0, 1) ** 1.4 * 150
    grad = np.repeat(alpha[:, None], S, axis=1).astype(np.uint8)
    a = Image.fromarray(grad, "L")
    a = Image.fromarray((np.array(a, np.float32) * np.array(mask, np.float32) / 255).astype(np.uint8), "L")
    layer = Image.new("RGBA", (S, S), color + (0,))
    layer.putalpha(a)
    return layer


def ticks_layer(c, R, start, end, count, inner, outer, alpha=90, major_every=4):
    layer = Image.new("RGBA", (S, S))
    d = ImageDraw.Draw(layer)
    for k in range(count + 1):
        ang = math.radians(start + (end - start) * k / count)
        major = k % major_every == 0
        r1 = R - inner
        r2 = R - (outer if major else outer * 0.6)
        d.line([c[0] + r1 * math.cos(ang), c[1] + r1 * math.sin(ang), c[0] + r2 * math.cos(ang), c[1] + r2 * math.sin(ang)],
               fill=(255, 255, 255, alpha + (60 if major else 0)), width=int(S * (0.007 if major else 0.0045)))
    return layer


def gloss(img, strength=34):
    """Reflet doux en haut à gauche (esprit « verre » d'iOS 26)."""
    y, x = np.mgrid[0:S, 0:S].astype(np.float32) / S
    d = np.clip(1 - np.sqrt((x - 0.25) ** 2 + (y - 0.05) ** 2) / 0.75, 0, 1) ** 2 * strength
    layer = np.zeros((S, S, 4), np.uint8)
    layer[..., :3] = 255
    layer[..., 3] = d.astype(np.uint8)
    return Image.alpha_composite(img, Image.fromarray(layer, "RGBA"))


def smooth_line(layer, pts, width, color):
    d = ImageDraw.Draw(layer)
    r = width / 2
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        steps = max(1, int(math.hypot(x1 - x0, y1 - y0) / 2))
        for k in range(steps + 1):
            x = x0 + (x1 - x0) * k / steps
            y = y0 + (y1 - y0) * k / steps
            d.ellipse([x - r, y - r, x + r, y + r], fill=color + (255,))


def glowing_dot(img, x, y, r, halo_color):
    halo = Image.new("RGBA", (S, S))
    ImageDraw.Draw(halo).ellipse([x - r * 2.6, y - r * 2.6, x + r * 2.6, y + r * 2.6], fill=halo_color + (200,))
    img = Image.alpha_composite(img, halo.filter(ImageFilter.GaussianBlur(r * 1.6)))
    dot = Image.new("RGBA", (S, S))
    ImageDraw.Draw(dot).ellipse([x - r, y - r, x + r, y + r], fill=WHITE + (255,))
    return Image.alpha_composite(img, dot)


def variant(sweep_start, sweep_end, background, carbon_bg=False, line_color=WHITE, center_y=0.60, radius=0.38,
            palette=(CYAN, BLUE, ORANGE, RED)):
    img = vignette(carbon(base=14, amp=12), 0.65) if carbon_bg else radial_bg(background, (0, 0, 0), center=(0.5, 0.38), radius=0.95)
    c = (S / 2, S * center_y)
    R = S * radius
    W = int(S * 0.09)
    # piste de l'arc (partie non remplie)
    track = Image.new("RGBA", (S, S))
    ImageDraw.Draw(track).arc([c[0] - R, c[1] - R, c[0] + R, c[1] + R], sweep_start, sweep_end, fill=(255, 255, 255, 22), width=W)
    img = Image.alpha_composite(img, track)
    img = Image.alpha_composite(img, ticks_layer(c, R, sweep_start, sweep_end, 24, W * 1.25, W * 1.25 + S * 0.035))
    arc = Image.new("RGBA", (S, S))
    gradient_arc(arc, c, R, W, sweep_start, sweep_end, palette, steps=500)
    img = add_glow(img, arc, S * 0.04, 1.35)
    # courbe + remplissage
    pts = curve_points(c, R, -0.62, 0.66)
    img = Image.alpha_composite(img, area_fill(pts, c[1] + R * 0.02, (90, 170, 255)))
    line = Image.new("RGBA", (S, S))
    smooth_line(line, pts, S * 0.026, line_color)
    img = add_glow(img, line, S * 0.018, 1.0)
    ex, ey = pts[-1]
    img = glowing_dot(img, ex, ey, S * 0.036, ORANGE)
    return finish(gloss(img))



OUT = sys.argv[1]
from PIL import ImageOps

def original_curve(c, R, n=160):
    """Courbe de la D d'origine (montée progressive avec une petite ondulation au départ)."""
    pts = []
    for i in range(n):
        t = i / (n - 1)
        x = c[0] - R * 0.66 + t * R * 1.30
        y = c[1] - R * 0.06 - R * 0.62 * (t ** 2.2) + R * 0.035 * math.sin(t * 16) * (1 - t)
        pts.append((x, y))
    return pts


def final_icon():
    img = radial_bg(NAVY, (0, 0, 0), center=(0.5, 0.38), radius=0.95)
    c = (S / 2, S * 0.66)
    R = S * 0.39
    W = int(S * 0.09)
    track = Image.new("RGBA", (S, S))
    ImageDraw.Draw(track).arc([c[0] - R, c[1] - R, c[0] + R, c[1] + R], 180, 360, fill=(255, 255, 255, 22), width=W)
    img = Image.alpha_composite(img, track)
    img = Image.alpha_composite(img, ticks_layer(c, R, 180, 360, 24, W * 1.25, W * 1.25 + S * 0.035))
    arc = Image.new("RGBA", (S, S))
    gradient_arc(arc, c, R, W, 180, 360, (CYAN, BLUE, ORANGE, RED), steps=500)
    img = add_glow(img, arc, S * 0.04, 1.35)
    pts = original_curve(c, R)
    img = Image.alpha_composite(img, area_fill(pts, c[1] + R * 0.02, (90, 170, 255)))
    line = Image.new("RGBA", (S, S))
    smooth_line(line, pts, S * 0.026, WHITE)
    img = add_glow(img, line, S * 0.018, 1.0)
    ex, ey = pts[-1]
    img = glowing_dot(img, ex, ey, S * 0.036, ORANGE)
    return finish(gloss(img))


icon = final_icon()
icon.save(f"{OUT}/icon-1024.png")
# Variante sombre : l'icône est déjà sombre, on la reprend telle quelle.
icon.save(f"{OUT}/icon-1024-dark.png")
# Variante teintée : niveaux de gris contrastés sur fond noir (iOS applique la teinte choisie).
gray = ImageOps.autocontrast(ImageOps.grayscale(icon), cutoff=1)
gray.save(f"{OUT}/icon-1024-tinted.png")

prev = Image.new("RGB", (3 * 360 + 40, 400), (242, 242, 247))
for i, name in enumerate(["icon-1024.png", "icon-1024-tinted.png"]):
    im = Image.open(f"{OUT}/{name}").convert("RGB").resize((320, 320), Image.LANCZOS)
    r = rounded(im)
    prev.paste(r, (20 + i * 360, 40), r)
small = rounded(icon.resize((120, 120), Image.LANCZOS))
prev.paste(small, (20 + 2 * 360 + 100, 140), small)
prev.save(f"{OUT}/apercu-final.png")
print("ok")
