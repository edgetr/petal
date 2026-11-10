#!/usr/bin/env python3
"""Petal's icon: five slim petals on warm paper, the one at the top (the focus petal) in Petal's pink. It is drawn
here, in code, and every copy of it is written from this file.

Flat copies (a browser shows no glass) go to site/icon.svg and the site's PNGs (rendered by macOS's sips).

The macOS app icon is the Icon Composer document Petal.icon: each petal is a sliver of Liquid Glass on grained
paper, with a dark appearance, and a tinted one (which Clear uses too) in which the petals turn white for the
system to tint, the focus petal brightest. Xcode's actool compiles it into Assets.car (every appearance, for
macOS 26 and later) and Petal.icns (for older macOS); Apple's ictool renders the previews. So this runs on a Mac
with Xcode 26 or later. Standard library only, like the rest of Petal.

    python3 brand/icon.py
"""
import json
import math
import pathlib
import random
import shutil
import struct
import subprocess
import tempfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
BRAND = ROOT / "brand"
ICTOOL = pathlib.Path("/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool")

PAPER, INK, PINK = "#f1f0ec", "#17181c", "#d9367f"
DARK_PAPER, DARK_INK, DARK_PINK = "#121316", "#ecebe6", "#ec5c9b"

# One petal on the 64-unit grid, pointing up from the flower's centre: it starts GAP from the centre, is LENGTH
# long and HALF_WIDTH wide at its fullest. The flower's centre sits a little low so the five petals look centred.
CENTRE, GAP, LENGTH, HALF_WIDTH = (32, 34), 4.5, 15, 3.6
ANGLES = (0, 72, 144, 216, 288)   # 0 is the pink petal


def petal(angle, scale=1.0, centre=CENTRE):
    """The petal at `angle` degrees as an absolute SVG path, scaled about the 64-unit grid's middle."""
    k = HALF_WIDTH / 0.75   # a cubic's control points sit 4/3 of the curve's width out
    near, far = GAP + LENGTH * 0.28, GAP + LENGTH * 0.72
    points = [(0, -GAP), (k, -near), (k, -far), (0, -GAP - LENGTH), (-k, -far), (-k, -near), (0, -GAP)]
    a = math.radians(angle)
    cos, sin = math.cos(a), math.sin(a)

    def place(x, y):
        x, y = x * cos - y * sin + centre[0], x * sin + y * cos + centre[1]
        return f"{(x - 32) * scale + 32 * scale:.2f} {(y - 32) * scale + 32 * scale:.2f}"

    p = [place(*q) for q in points]
    return f"M{p[0]}C{p[1]} {p[2]} {p[3]}C{p[4]} {p[5]} {p[6]}Z"


def flat_svg():
    paths = "".join(f'\n  <path d="{petal(a)}" fill="{PINK if a == 0 else INK}"/>' for a in ANGLES)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">\n'
            f'  <rect width="64" height="64" rx="15" fill="{PAPER}"/>{paths}\n</svg>\n')


def layer_svg(pink, dark):
    """The pink petal, or the four ink petals, on Icon Composer's 1024-point canvas."""
    colour = (DARK_PINK if dark else PINK) if pink else (DARK_INK if dark else INK)
    paths = "".join(f'<path d="{petal(a, 16)}" fill="{colour}"/>' for a in ANGLES if (a == 0) == pink)
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">{paths}</svg>\n'


def png(path, width, height, rgba_rows):
    """A plain RGBA PNG, written with zlib alone."""
    raw = b"".join(b"\0" + row for row in rgba_rows)

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def grain(path, dark):
    """Fine grain for the paper, its own layer under the glass, as on Edgetr's other icons."""
    rng = random.Random(7 if dark else 5)
    shade, strength = (255, 22) if dark else (20, 16)
    rows = []
    for _ in range(1024):
        row = bytearray()
        for _ in range(1024):
            row += bytes((shade, shade, shade, min(255, int(abs(rng.gauss(0, 1)) * strength))))
        rows.append(bytes(row))
    png(path, 1024, 1024, rows)


def srgb(hex_colour, alpha=1.0):
    r, g, b = (int(hex_colour[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},{alpha:.5f}"


def icon_document(path):
    shutil.rmtree(path, ignore_errors=True)
    (path / "Assets").mkdir(parents=True)
    for name, pink in (("focus-petal", True), ("petals", False)):
        (path / f"Assets/{name}.svg").write_text(layer_svg(pink, dark=False))
        (path / f"Assets/{name}-dark.svg").write_text(layer_svg(pink, dark=True))
    grain(path / "Assets/grain.png", dark=False)
    grain(path / "Assets/grain-dark.png", dark=True)

    def layer(name, tinted_alpha):
        # Tinted and Clear drop colour, and pink would turn the dimmest grey. So the petals turn white for the
        # system to tint, the focus petal at full strength and the others fainter, and it still stands out.
        return {"name": name, "glass": True, "image-name-specializations": [
                    {"value": f"{name}.svg"}, {"appearance": "dark", "value": f"{name}-dark.svg"}],
                "fill-specializations": [{"appearance": "tinted", "value": {"solid": srgb("#ffffff", tinted_alpha)}}]}

    def group(name, layers, shadow, refract=0.0):
        return {"name": name, "layers": layers, "lighting": "individual", "specular": "inside",
                "shadow": {"kind": "neutral", "opacity": shadow},
                "translucency": {"enabled": False, "value": 0}, "blur": {"enabled": False, "value": 0},
                "refractivity": {"enabled": refract > 0, "depth": refract, "strength": refract}}

    paper = {"name": "Paper", "lighting": "combined", "specular": False, "shadow": {"kind": "none", "opacity": 0},
             "layers": [{"name": "grain", "glass": False, "opacity": 0.5, "image-name-specializations": [
                 {"value": "grain.png"}, {"appearance": "dark", "value": "grain-dark.png"}]}]}
    document = {
        "features": ["refractivity"],
        "fill-specializations": [{"value": {"solid": srgb(PAPER)}}, {"appearance": "dark", "value": {"solid": srgb(DARK_PAPER)}}],
        "groups": [group("Focus petal", [layer("focus-petal", 1.0)], 0.45, refract=0.3),
                   group("Petals", [layer("petals", 0.55)], 0.3), paper],
        "supported-platforms": {"squares": "shared"},
    }
    (path / "icon.json").write_text(json.dumps(document, indent=2) + "\n")


def render(document, path, rendition, size=512):
    subprocess.run([str(ICTOOL), str(document), "--export-image", "--output-file", str(path), "--platform", "macOS",
                    "--rendition", rendition, "--width", str(size), "--height", str(size), "--scale", "1"],
                   check=True, capture_output=True)


def compile_icon(document, out):
    """Assets.car with every appearance, and Petal.icns for macOS before 26, as Xcode builds them."""
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["xcrun", "actool", str(document), "--compile", tmp, "--platform", "macosx",
                        "--minimum-deployment-target", "14.0", "--app-icon", "Petal",
                        "--output-partial-info-plist", f"{tmp}/partial.plist"], check=True, capture_output=True)
        shutil.rmtree(out, ignore_errors=True)
        out.mkdir(parents=True)
        for name in ("Assets.car", "Petal.icns"):
            shutil.copy(pathlib.Path(tmp) / name, out / name)


def main():
    svg = flat_svg()
    (ROOT / "site/icon.svg").write_text(svg)
    for name, size in (("icon-176.png", 176), ("apple-touch-icon.png", 180)):   # the install card at 88pt; iOS
        subprocess.run(["sips", "-s", "format", "png", "-z", str(size), str(size), str(ROOT / "site/icon.svg"),
                        "--out", str(ROOT / "site" / name)], check=True, capture_output=True)

    if not ICTOOL.exists():
        raise SystemExit(f"wrote the flat icons; the macOS icon needs Xcode 26 or later with Icon Composer ({ICTOOL})")
    document = BRAND / "Petal.icon"
    icon_document(document)
    compile_icon(document, BRAND / "macos")
    previews = BRAND / "previews"
    shutil.rmtree(previews, ignore_errors=True)
    previews.mkdir()
    for rendition in ("Default", "Dark", "ClearLight", "ClearDark", "TintedLight", "TintedDark"):
        render(document, previews / f"{rendition.lower()}.png", rendition)
    print("wrote site/icon.svg and", BRAND.relative_to(ROOT))


if __name__ == "__main__":
    main()
