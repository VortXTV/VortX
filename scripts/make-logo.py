#!/usr/bin/env python3
"""Derive every app icon and banner from the brand master (docs/brand/icon-master.png,
the glowing X on obsidian, designed by the maintainer).

Targets: the tvOS layered icon (transparent X front over obsidian back, for the
parallax tilt), the top shelf banners, the full-bleed iOS icon, and the README
banner. Run from the repo root: python3 scripts/make-logo.py
"""
from PIL import Image, ImageDraw, ImageFont, ImageOps
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MASTER = os.path.join(ROOT, "docs/brand/icon-master.png")
BRAND = os.path.join(ROOT, "app/ResourcesTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets")
INK = (242, 240, 234, 255)
_HELVETICA = "/System/Library/Fonts/Helvetica.ttc"

master = Image.open(MASTER).convert("RGB")
W, H = master.size

# The obsidian base, sampled inside the rounded rect away from the glow.
OBSIDIAN = master.getpixel((W // 2, int(H * 0.06)))


def luma_extract(img):
    """The X is additive light on near-black, so luminance IS its alpha. Returns
    RGBA with the artwork floating on transparency, for the parallax front layer."""
    rgba = img.convert("RGBA")
    gray = ImageOps.grayscale(img)
    rgba.putalpha(gray)
    return rgba


# The mark region: the central square, clear of the white rounded corners.
mark_rgb = master.crop((int(W * 0.10), int(H * 0.10), int(W * 0.90), int(H * 0.90)))
mark = luma_extract(mark_rgb)


def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print("wrote", path, img.size)


def icon_layers(w, h, tag):
    back = Image.new("RGB", (w, h), OBSIDIAN)
    save(back, os.path.join(BRAND, f"App Icon{tag}.imagestack/Back.imagestacklayer/Content.imageset/tv_bg_{w}.png"))
    front = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    side = int(h * 0.86)   # tvOS crops edges during the tilt; keep the mark inside
    mk = mark.resize((side, side), Image.LANCZOS)
    front.alpha_composite(mk, ((w - side) // 2, (h - side) // 2))
    save(front, os.path.join(BRAND, f"App Icon{tag}.imagestack/Front.imagestacklayer/Content.imageset/tv_glyph_{w}.png"))


def lockup(w, h, path, radius=0):
    """Obsidian banner: the X mark standing as the X of STREMIO·X."""
    img = Image.new("RGBA", (w, h), OBSIDIAN + (255,))
    font = ImageFont.truetype(_HELVETICA, int(h * 0.34), index=1)   # ttc index 1 = Helvetica Bold
    d = ImageDraw.Draw(img)
    text = "STREMIO"
    stroke = max(1, int(h * 0.008))
    bbox = d.textbbox((0, 0), text, font=font, stroke_width=stroke)
    tw = bbox[2] - bbox[0]
    mark_side = int(h * 0.62)
    gap = int(h * 0.04)
    x = (w - (tw + gap + mark_side)) / 2
    d.text((x, (h - font.size * 1.28) / 2), text, font=font, fill=INK,
           stroke_width=stroke, stroke_fill=INK)
    mk = mark.resize((mark_side, mark_side), Image.LANCZOS)
    img.alpha_composite(mk, (int(x + tw + gap), (h - mark_side) // 2))
    if radius:
        m = Image.new("L", (w, h), 0)
        ImageDraw.Draw(m).rounded_rectangle([0, 0, w, h], radius=radius, fill=255)
        img.putalpha(m)
    save(img, path)


# tvOS layered icons
icon_layers(400, 240, "")
icon_layers(1280, 768, " - App Store")

# Top shelf banners
lockup(1920, 720, os.path.join(BRAND, "Top Shelf Image.imageset/tv_topshelf.png"))
lockup(2320, 720, os.path.join(BRAND, "Top Shelf Image Wide.imageset/tv_topshelf_wide.png"))

# iOS icon: full-bleed square. The master's white rounded corners are replaced by
# compositing the mark onto plain obsidian (the system applies its own corner mask).
ios = Image.new("RGBA", (1024, 1024), OBSIDIAN + (255,))
mk = mark.resize((900, 900), Image.LANCZOS)
ios.alpha_composite(mk, (62, 62))
save(ios.convert("RGB"), os.path.join(ROOT, "app/Resources/Assets.xcassets/AppIcon.appiconset/ios_1024.png"))

# README banner: rounded obsidian card, reads on light and dark GitHub themes.
lockup(1600, 400, os.path.join(ROOT, "docs/logo.png"), radius=36)
