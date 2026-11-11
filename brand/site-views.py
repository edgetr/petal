#!/usr/bin/env python3
"""Writes the pictures of Petal that petal.codes shows (site/views/*.webp).

Every one is a real view of Petal, drawn off-screen by `Petal --snapshot` with made-up content at 3 pixels a
point on a clear background, once light and once dark (the promotional video's `source/README.md` says how, and
its `snapshot-film.patch` is what the harness needs for it). This reads those two folders as they were drawn,
cuts each view to what the page shows, takes the soft shadow off the light ones and trims them to their edge (the
page draws the shadow itself, so a view lines up with the text beside it), scales it to twice the size it is
shown at, and writes WebP. The two views of Settings are cut from a page of the settings window, which is glass
over whatever is behind it: the snapshots are drawn with `PETAL_SNAPSHOT_BACKDROP=#f6f5f1` (the patch's), so the
page has the site's plain paper behind it and nothing here is a wash of color. Those two are cut flat (FLAT).

    python3 brand/site-views.py <folder with the snapshots' light/ and dark/>

It needs Pillow. Run it again when a view changes; the names here are the names index.html uses.
"""
import sys
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw

SRC = Path(sys.argv[1]) if len(sys.argv) > 1 else None
OUT = Path(__file__).resolve().parent.parent / 'site' / 'views'

# Settings › Vault, 920 points wide. Its column of rows runs from 258 to 862 points; each cut is one group (the
# items with the line under them; Import and export) with 20 points of the page around what it holds.
VAULT_ITEMS = (714, 1119, 2646, 2208)
VAULT_IMPORT = (714, 2898, 2646, 3360)

# name: (source, box or None, width written, corner radius in source pixels or 0). A box is in the snapshot's own
# pixels, 3 to a point. Dark views (cards, chips, the dock's buttons) come from dark/ and keep their own edge: DARK.
# Everything else comes from light/.
VIEWS = {
    # the first screen
    'hero-outline': ('note-open', None, 960, 0),
    'hero-dentist': ('note-folded', None, 520, 0),
    'hero-alex': ('note-person', (1826, 180, 2400, 810), 520, 0),
    # notes stick to things
    'sentence': ('note-edge-tabs', (0, 0, 3000, 1800), 1800, 0),
    'sentence-note': ('note-sentence', None, 600, 0),
    'person': ('note-person', (0, 0, 2460, 1330), 1500, 0),
    'screen': ('note-on-screen', (0, 0, 2130, 1470), 1300, 0),
    # every note in one window
    'window-grid': ('notes-window-grid', (0, 0, 3840, 1935), 1900, 0),
    'window-grid-near': ('notes-window-grid', (840, 0, 2430, 1515), 900, 0),
    'window-canvas': ('notes-window-canvas', (0, 0, 3840, 2250), 1500, 0),
    # @Petal on a note
    'helper-ink': ('helper-ink', None, 960, 0),
    'helper-watcher': ('helper-watcher', (640, 40, 1880, 720), 860, 0),
    'helper-task': ('helper-task', (640, 34, 1880, 890), 860, 0),
    'helper-working': ('helper-working', None, 960, 0),
    'helper-code-front': ('helper-code', (50, 40, 1250, 1180), 900, 0),
    'helper-code-back': ('helper-code', (1240, 30, 2450, 1190), 900, 0),
    # the viewer
    'viewer': ('viewer-pdf', None, 1900, 0),
    'viewer-near': ('viewer-pdf', (2010, 0, 3660, 1860), 1000, 0),
    # Petal AI in apps
    'card-use': ('film-card-use', (16, 0, 1280, 336), 880, 66),
    'card-trash': ('film-card-trash', (16, 0, 1280, 336), 880, 66),
    # a display of its own for each run
    'preview-run': ('film-run-preview', (17, 18, 1327, 585), 1100, 60),
    'run-note': ('film-run-note', None, 1000, 0),
    'chip-export': ('film-pill-export', None, 430, 0),
    # the vault: in Settings, its items and Import and export, each a group of rows with the page's margin around it
    'vault-items': ('settings-vault', VAULT_ITEMS, 1300, 0),
    'vault-import': ('settings-vault', VAULT_IMPORT, 1300, 0),
    'card-buy': ('card-vault-buy', None, 800, 0),
    'chip-password': ('film-pill-password', None, 470, 0),
    'card-key': ('card-agent-key', (16, 0, 1280, 336), 880, 66),
    # the dock: Petal's own buttons, and a window preview
    'dock-ai': ('film-ai', None, 138, 0),
    'dock-finder': ('film-finder', None, 138, 0),
    'dock-pad': ('film-pad', None, 138, 0),
    'dock-add': ('film-add', None, 138, 0),
    'dock-playing': ('film-playing', None, 138, 0),
    'dock-trash': ('film-trash', None, 138, 0),
    'preview-music': ('preview-music', None, 900, 0),
}


DARK = ('card-', 'chip-', 'dock-', 'preview-')
FLAT = ('vault-items', 'vault-import')


def trimmed(picture):
    """The view without its shadow (black, mostly clear pixels), cut to what is left."""
    red, green, blue, alpha = picture.split()
    lightest = ImageChops.lighter(ImageChops.lighter(red, green), blue)
    shadow = ImageChops.multiply(lightest.point(lambda v: 255 if v < 48 else 0), alpha.point(lambda v: 255 if v < 120 else 0))
    picture.putalpha(ImageChops.subtract(alpha, shadow))
    return picture.crop(picture.getchannel('A').getbbox())


def main():
    if not SRC or not (SRC / 'light').is_dir() or not (SRC / 'dark').is_dir():
        sys.exit(__doc__)
    OUT.mkdir(parents=True, exist_ok=True)
    for name, (source, box, width, radius) in VIEWS.items():
        picture = Image.open(SRC / ('dark' if name.startswith(DARK) else 'light') / f'{source}.png').convert('RGBA')
        if box:
            picture = picture.crop(box)
        if name not in FLAT and not name.startswith(DARK):
            picture = trimmed(picture)
        if radius:
            # A card the snapshot cut flat at an edge gets its own corners back.
            mask = Image.new('L', picture.size, 0)
            ImageDraw.Draw(mask).rounded_rectangle((0, 0, picture.width - 1, picture.height - 1), radius, fill=255)
            picture.putalpha(mask)
        if width < picture.width:
            picture = picture.resize((width, round(picture.height * width / picture.width)), Image.LANCZOS)
        picture.save(OUT / f'{name}.webp', 'WEBP', quality=86, method=6)
        print(f'{name}.webp {picture.width}x{picture.height} {(OUT / f"{name}.webp").stat().st_size // 1024} KB')


if __name__ == '__main__':
    main()
