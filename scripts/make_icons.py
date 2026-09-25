#!/usr/bin/env python3
"""Draws the BlueNudge app icons (iPhone and Mac relay) into the asset catalogs.

Run from the repository root:  python3 scripts/make_icons.py
Needs Pillow (pip install pillow). Re-run after changing the colors or shapes.
"""
import json
import os

from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOP = (72, 176, 255)
BOTTOM = (10, 94, 235)
WHITE = (255, 255, 255, 255)
SS = 4  # supersampling factor


def gradient(size):
    image = Image.new("RGBA", (size, size))
    draw = ImageDraw.Draw(image)
    for y in range(size):
        t = y / (size - 1)
        color = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)) + (255,)
        draw.line([(0, y), (size, y)], fill=color)
    return image


def draw_glyph(image, box):
    """Speech bubble with a clock face, drawn inside `box` (x0, y0, x1, y1)."""
    x0, y0, x1, y1 = box
    w = x1 - x0
    h = y1 - y0
    draw = ImageDraw.Draw(image)

    bubble = (x0 + w * 0.10, y0 + h * 0.14, x0 + w * 0.90, y0 + h * 0.76)
    radius = (bubble[3] - bubble[1]) * 0.42
    draw.rounded_rectangle(bubble, radius=radius, fill=WHITE)
    # Tail at the lower left, like a received-message bubble.
    draw.polygon(
        [
            (x0 + w * 0.24, y0 + h * 0.68),
            (x0 + w * 0.16, y0 + h * 0.90),
            (x0 + w * 0.44, y0 + h * 0.74),
        ],
        fill=WHITE,
    )

    # Clock inside the bubble.
    cx = (bubble[0] + bubble[2]) / 2
    cy = (bubble[1] + bubble[3]) / 2
    r = (bubble[3] - bubble[1]) * 0.30
    stroke = r * 0.20
    blue = BOTTOM + (255,)
    draw.ellipse((cx - r, cy - r, cx + r, cy + r), outline=blue, width=round(stroke))
    draw.line((cx, cy, cx, cy - r * 0.62), fill=blue, width=round(stroke * 0.9))
    draw.line((cx, cy, cx + r * 0.48, cy + r * 0.22), fill=blue, width=round(stroke * 0.9))
    dot = stroke * 0.7
    draw.ellipse((cx - dot, cy - dot, cx + dot, cy + dot), fill=blue)


def ios_icon(size=1024):
    big = size * SS
    image = gradient(big)
    pad = big * 0.07
    draw_glyph(image, (pad, pad, big - pad, big - pad))
    return image.resize((size, size), Image.LANCZOS).convert("RGB")  # App Store icons must be opaque


def mac_icon(size=1024):
    """macOS icons carry their own rounded-square shape and shadow."""
    big = size * SS
    canvas = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    inset = big * 100 / 1024
    body = (inset, inset, big - inset, big - inset)
    corner = (body[2] - body[0]) * 0.225

    shadow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (body[0], body[1] + big * 0.012, body[2], body[3] + big * 0.012), radius=corner, fill=(0, 0, 0, 90)
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(big * 0.012))
    canvas.alpha_composite(shadow)

    fill = gradient(big)
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(body, radius=corner, fill=255)
    tile = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    tile.paste(fill, (0, 0), mask)
    draw_glyph(tile, body)
    canvas.alpha_composite(tile)
    return canvas.resize((size, size), Image.LANCZOS)


def write_json(path, payload):
    with open(path, "w") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def main():
    ios_dir = os.path.join(ROOT, "App/iOS/Assets.xcassets/AppIcon.appiconset")
    os.makedirs(ios_dir, exist_ok=True)
    ios_icon().save(os.path.join(ios_dir, "AppIcon-1024.png"))
    write_json(
        os.path.join(ios_dir, "Contents.json"),
        {
            "images": [
                {"filename": "AppIcon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}
            ],
            "info": {"author": "xcode", "version": 1},
        },
    )

    mac_dir = os.path.join(ROOT, "App/macOS/Assets.xcassets/AppIcon.appiconset")
    os.makedirs(mac_dir, exist_ok=True)
    master = mac_icon(1024)
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            master.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(mac_dir, name))
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}"})
    write_json(os.path.join(mac_dir, "Contents.json"), {"images": images, "info": {"author": "xcode", "version": 1}})

    accent = {
        "colors": [
            {
                "color": {
                    "color-space": "srgb",
                    "components": {"alpha": "1.000", "blue": "0.922", "green": "0.369", "red": "0.039"},
                },
                "idiom": "universal",
            }
        ],
        "info": {"author": "xcode", "version": 1},
    }
    for platform in ("iOS", "macOS"):
        catalog = os.path.join(ROOT, f"App/{platform}/Assets.xcassets")
        write_json(os.path.join(catalog, "Contents.json"), {"info": {"author": "xcode", "version": 1}})
        colorset = os.path.join(catalog, "AccentColor.colorset")
        os.makedirs(colorset, exist_ok=True)
        write_json(os.path.join(colorset, "Contents.json"), accent)

    print("Icons written.")


if __name__ == "__main__":
    main()
