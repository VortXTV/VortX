#!/usr/bin/env python3
"""Derive every app icon and banner from the StremioX identity (the maintainer's
design: a two-tone violet pinwheel X with a white centre dot on a dark indigo
rounded square, wordmark "Stremio" in gray with a violet X).

The reference renders live in docs/brand/ (AI generations with a baked-in
checkerboard, unusable directly), so the geometry is reconstructed here with
real transparency, colours sampled from the reference. Run from the repo root:
python3 scripts/make-logo.py
"""
from PIL import Image, ImageDraw, ImageFont
import math
import os

SS = 4  # supersampling for crisp edges

# Sampled from docs/brand/lockup-reference.png
INDIGO = (26, 15, 58)            # icon square
VIOLET_LIGHT = (109, 54, 243)    # NW-SE bar, wordmark X
VIOLET_DARK_TOP = (89, 43, 203)  # NE-SW bar, top
VIOLET_DARK_BOT = (77, 36, 174)  # NE-SW bar, bottom
TEXT_GRAY = (93, 93, 93)         # wordmark on light surfaces
TEXT_LIGHT = (236, 234, 244)     # wordmark on dark surfaces
DOT = (255, 255, 255)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, "app/ResourcesTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets")
_HELVETICA = "/System/Library/Fonts/Helvetica.ttc"


def bar(draw, p0, p1, width, fill):
    (x0, y0), (x1, y1) = p0, p1
    dx, dy = x1 - x0, y1 - y0
    length = math.hypot(dx, dy)
    nx, ny = -dy / length * width / 2, dx / length * width / 2
    draw.polygon([(x0 + nx, y0 + ny), (x1 + nx, y1 + ny),
                  (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)], fill=fill)


def draw_mark(size):
    """The pinwheel X and dot alone, on transparency (the tvOS parallax front
    layer, and the building block for everything else)."""
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    w = 0.225 * s
    inset = 0.16 * s
    # Darker bar (NE -> SW) underneath, with its subtle vertical shade
    half = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    dh = ImageDraw.Draw(half)
    bar(dh, (s - inset, inset), (inset, s - inset), w, VIOLET_DARK_TOP + (255,))
    shade = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ds = ImageDraw.Draw(shade)
    for y in range(s):
        t = y / max(s - 1, 1)
        c = tuple(int(VIOLET_DARK_TOP[i] + (VIOLET_DARK_BOT[i] - VIOLET_DARK_TOP[i]) * t) for i in range(3))
        ds.line([(0, y), (s, y)], fill=c + (255,))
    half.paste(shade, (0, 0), half)
    img.alpha_composite(half)
    # Lighter bar (NW -> SE) on top
    bar(d, (inset, inset), (s - inset, s - inset), w, VIOLET_LIGHT + (255,))
    # Centre dot
    r = 0.085 * s
    d.ellipse([s / 2 - r, s / 2 - r, s / 2 + r, s / 2 + r], fill=DOT + (255,))
    return img.resize((size, size), Image.LANCZOS)


def draw_icon(size, rounded=True):
    """The full icon: the mark on the indigo square."""
    s = size * SS
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if rounded:
        d.rounded_rectangle([0, 0, s, s], radius=int(s * 0.225), fill=INDIGO + (255,))
    else:
        d.rectangle([0, 0, s, s], fill=INDIGO + (255,))
    img = img.resize((size, size), Image.LANCZOS)
    mk = draw_mark(int(size * 0.78))
    img.alpha_composite(mk, ((size - mk.width) // 2, (size - mk.height) // 2))
    return img


def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print("wrote", path, img.size)


def lockup(w, h, path, text_color, background=None, icon_rounded=True):
    """Icon + Stremio[X] wordmark, matching the reference composition."""
    img = Image.new("RGBA", (w, h), background or (0, 0, 0, 0))
    icon_side = int(h * 0.72)
    icon = draw_icon(icon_side, rounded=icon_rounded)
    font = ImageFont.truetype(_HELVETICA, int(h * 0.42), index=1)   # ttc index 1 = Helvetica Bold
    d = ImageDraw.Draw(img)
    name = "Stremio"
    tw = d.textlength(name, font=font)
    xw = d.textlength("X", font=font)
    gap = int(h * 0.10)
    total = icon_side + gap + tw + xw
    x = (w - total) / 2
    y_icon = (h - icon_side) // 2
    img.alpha_composite(icon, (int(x), y_icon))
    ty = (h - font.size * 1.30) / 2
    d.text((x + icon_side + gap, ty), name, font=font, fill=text_color)
    d.text((x + icon_side + gap + tw, ty), "X", font=font, fill=VIOLET_LIGHT)
    save(img, path)


# tvOS layered icon: indigo back, floating mark front (kept inside the tilt-safe area)
for w, h, tag in [(400, 240, ""), (1280, 768, " - App Store")]:
    back = Image.new("RGB", (w, h), INDIGO)
    save(back, os.path.join(BRAND, f"App Icon{tag}.imagestack/Back.imagestacklayer/Content.imageset/tv_bg_{w}.png"))
    front = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    mk = draw_mark(int(h * 0.80))
    front.alpha_composite(mk, ((w - mk.width) // 2, (h - mk.height) // 2))
    save(front, os.path.join(BRAND, f"App Icon{tag}.imagestack/Front.imagestacklayer/Content.imageset/tv_glyph_{w}.png"))

# Top shelf banners: indigo surface, light wordmark
lockup(1920, 720, os.path.join(BRAND, "Top Shelf Image.imageset/tv_topshelf.png"),
       TEXT_LIGHT, background=INDIGO + (255,))
lockup(2320, 720, os.path.join(BRAND, "Top Shelf Image Wide.imageset/tv_topshelf_wide.png"),
       TEXT_LIGHT, background=INDIGO + (255,))

# iOS icon: the square icon, full bleed (the system masks its own corners)
save(draw_icon(1024, rounded=False).convert("RGB"),
     os.path.join(ROOT, "app/Resources/Assets.xcassets/AppIcon.appiconset/ios_1024.png"))

# README: transparent lockups for GitHub's light and dark themes
lockup(1600, 400, os.path.join(ROOT, "docs/logo-light.png"), TEXT_GRAY)
lockup(1600, 400, os.path.join(ROOT, "docs/logo-dark.png"), TEXT_LIGHT)

# Standalone app icon (rounded, transparent corners): the linkable brand file.
save(draw_icon(1024, rounded=True), os.path.join(ROOT, "docs/brand/app-icon.png"))
