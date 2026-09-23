#!/usr/bin/env python3
"""Per-row census of P6 PPM present dumps.

The artifact this looks for is a *band* structure, not a colour: rows of the
previous tenant's content (the launch splash's red) surviving where the guest's
partial repaint did not reach, adjacent to rows it did. So the numbers that
matter are how many rows are red-saturated, how many separate bands they form,
and how many times the frame flips between red and non-red down its height —
a full-screen stale frame is one band, a striped one is many.

    ppm-rows.py <dir> [...more dirs]
"""
import glob
import os
import sys


def read_ppm(path):
    with open(path, "rb") as f:
        data = f.read()
    tokens, i = [], 0
    while len(tokens) < 4 and i < len(data):
        while i < len(data) and data[i : i + 1].isspace():
            i += 1
        if data[i : i + 1] == b"#":
            while i < len(data) and data[i : i + 1] != b"\n":
                i += 1
            continue
        j = i
        while j < len(data) and not data[j : j + 1].isspace():
            j += 1
        tokens.append(data[i:j])
        i = j
    if len(tokens) < 4:
        return 0, 0, b""
    w, h = int(tokens[1]), int(tokens[2])
    i += 1  # the single whitespace byte after maxval
    return w, h, data[i : i + w * h * 3]


def is_red(r, g, b):
    return r > 60 and r > 1.35 * g and r > 1.35 * b


def census(path):
    w, h, px = read_ppm(path)
    if w == 0 or len(px) < w * h * 3:
        return f"{os.path.basename(path)}: unreadable or short ({len(px)} bytes)"
    means, flags = [], []
    for y in range(h):
        row = px[y * w * 3 : (y + 1) * w * 3]
        r = sum(row[0::3]) / w
        g = sum(row[1::3]) / w
        b = sum(row[2::3]) / w
        means.append((r, g, b))
        flags.append(is_red(r, g, b))
    transitions = sum(1 for a, b in zip(flags, flags[1:]) if a != b)
    bands, start = [], None
    for y, f in enumerate(flags + [False]):
        if f and start is None:
            start = y
        elif not f and start is not None:
            if y - start >= 4:
                bands.append((start, y - 1))
            start = None
    nr = sum(m[0] for m in means) / h
    ng = sum(m[1] for m in means) / h
    nb = sum(m[2] for m in means) / h
    return (
        f"{os.path.basename(path)} {w}x{h} mean=({nr:.0f},{ng:.0f},{nb:.0f}) "
        f"red_rows={sum(flags)}/{h} bands={len(bands)} flips={transitions} "
        f"first={bands[:4]}"
    )


for directory in sys.argv[1:]:
    for path in sorted(glob.glob(os.path.join(directory, "*.ppm"))):
        print(census(path))
