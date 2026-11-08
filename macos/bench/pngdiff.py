#!/usr/bin/env python3
"""Compares two folders of PNGs pixel by pixel (Python standard library only).

    python3 -I macos/bench/pngdiff.py <before folder> <after folder> [--tolerance N]

For each file in both: same size or not, how many pixels differ (any channel by more than N, default 0), the
largest channel difference, and the box around the differences. Exits 1 if any image differs or is missing
from either folder."""
import os, struct, sys, zlib

def read_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', path
    pos, idat, width = 8, b'', 0
    while pos < len(data):
        length, kind = struct.unpack('>I4s', data[pos:pos + 8])
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b'IHDR':
            width, height, depth, color, _, _, interlace = struct.unpack('>IIBBBBB', chunk)
            assert depth in (8, 16) and interlace == 0, (path, depth, interlace)
            channels = {6: 4, 2: 3, 0: 1, 4: 2}[color]
            size = depth // 8
        elif kind == b'IDAT':
            idat += chunk
        elif kind == b'IEND':
            break
    raw = zlib.decompress(idat)
    bpp = channels * size
    stride = width * bpp
    rows, prev, i = [], bytearray(stride), 0
    for _ in range(height):
        f = raw[i]; line = bytearray(raw[i + 1:i + 1 + stride]); i += 1 + stride
        if f == 1:
            for x in range(bpp, stride): line[x] = (line[x] + line[x - bpp]) & 255
        elif f == 2:
            for x in range(stride): line[x] = (line[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride): line[x] = (line[x] + ((line[x - bpp] if x >= bpp else 0) + prev[x]) // 2) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x - bpp] if x >= bpp else 0; b = prev[x]; c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line[::size]) if size == 2 else bytes(line)); prev = line   # 16-bit: the high byte
    return width, height, channels, rows

def main():
    args = sys.argv[1:]
    tolerance = int(args[args.index('--tolerance') + 1]) if '--tolerance' in args else 0
    before, after = args[0], args[1]
    pngs = lambda folder: {n for n in os.listdir(folder) if n.endswith('.png')}
    names = sorted(pngs(before) & pngs(after))
    missing = [(n, after) for n in sorted(pngs(before) - pngs(after))] + [(n, before) for n in sorted(pngs(after) - pngs(before))]
    changed = 0
    for name in names:
        a = read_png(os.path.join(before, name)); b = read_png(os.path.join(after, name))
        if a[:3] != b[:3]:
            print(f'{name}: size {a[0]}x{a[1]} -> {b[0]}x{b[1]}'); changed += 1; continue
        w, h, ch, ra = a; rb = b[3]
        count, worst, box = 0, 0, None
        for y in range(h):
            la, lb = ra[y], rb[y]
            if la == lb: continue
            for x in range(w):
                d = max(abs(la[x * ch + k] - lb[x * ch + k]) for k in range(ch))
                if d > tolerance:
                    count += 1; worst = max(worst, d)
                    box = (min(box[0], x), min(box[1], y), max(box[2], x), max(box[3], y)) if box else (x, y, x, y)
        if count:
            changed += 1
            print(f'{name}: {count} of {w*h} pixels differ (largest {worst}/255), in x {box[0]}-{box[2]}, y {box[1]}-{box[3]}')
        else:
            print(f'{name}: identical')
    for name, folder in missing: print(f'{name}: missing from {folder}')
    print(f'{len(names)} compared, {changed} differ, {len(missing)} missing')
    sys.exit(1 if changed or missing else 0)

main()
