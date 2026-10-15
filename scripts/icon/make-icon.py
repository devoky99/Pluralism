#!/usr/bin/env python3
"""Erzeugt das App-Icon von Pluralism aus der Master-Datei.

Quelle:   docs/icon/Pluralism-Icon.svg  (1024 x 1024, Squircle 824 px wie bei macOS-Icons)
Ergebnis: Resources/AppIcon.icns          (scripts/build-app.sh kopiert sie ins App-Bundle)
          docs/icon/Pluralism-Icon-1024.png (Vorschau, auch im README)

Aufruf:   python3 scripts/icon/make-icon.py
Braucht:  pip3 install cairosvg pillow   (auf dem Mac zusätzlich: brew install cairo)

Jede Größe wird direkt aus der SVG gerendert, damit auch kleine Größen scharf bleiben. Darunter liegt ein
weicher Schatten wie bei den Icons von macOS. Die .icns enthält alle zehn Größen als PNG, genau wie sie
Apples iconutil schreibt (16 bis 512 Punkt, jeweils einfach und doppelt).
"""
import io
import os
import struct

import cairosvg
from PIL import Image, ImageFilter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SVG = os.path.join(ROOT, "docs", "icon", "Pluralism-Icon.svg")
ICNS = os.path.join(ROOT, "Resources", "AppIcon.icns")
PREVIEW = os.path.join(ROOT, "docs", "icon", "Pluralism-Icon-1024.png")

# Eintragstyp in der .icns und Kantenlänge in Pixeln
ENTRIES = [
    ("icp4", 16), ("ic11", 32),    # 16 pt, 1x und 2x
    ("icp5", 32), ("ic12", 64),    # 32 pt
    ("ic07", 128), ("ic13", 256),  # 128 pt
    ("ic08", 256), ("ic14", 512),  # 256 pt
    ("ic09", 512), ("ic10", 1024), # 512 pt
]


def render(px: int) -> bytes:
    """Rendert die SVG in px x px mit Schatten und gibt PNG-Daten zurück."""
    icon = Image.open(io.BytesIO(cairosvg.svg2png(url=SVG, output_width=px, output_height=px))).convert("RGBA")
    scale = px / 1024
    shadow = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    shadow.putalpha(icon.split()[3].point(lambda a: int(a * 0.30)))
    shifted = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    shifted.paste(shadow, (0, round(10 * scale)))
    shifted = shifted.filter(ImageFilter.GaussianBlur(max(0.1, 10 * scale)))
    out = io.BytesIO()
    Image.alpha_composite(shifted, icon).save(out, format="PNG", optimize=True)
    return out.getvalue()


def main() -> None:
    cache: dict[int, bytes] = {}
    body = b""
    for kind, px in ENTRIES:
        data = cache.setdefault(px, render(px))
        body += kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data
    with open(ICNS, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)
    with open(PREVIEW, "wb") as f:
        f.write(cache[1024])
    print(f"{ICNS} ({os.path.getsize(ICNS)} Bytes)")
    print(f"{PREVIEW}")


if __name__ == "__main__":
    main()
