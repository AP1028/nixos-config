#!/usr/bin/env python3
"""Extract the 256x256 PNG embedded in Steam's .ico favicon.

The arm64 client zip ships no icon, so we reuse Valve's favicon. Modern .ico
files store entries >= 256px as raw PNG blobs; this picks the largest entry
and copies that PNG out verbatim.
"""

import struct
import sys


def main(ico: str, out: str) -> None:
    data = open(ico, "rb").read()
    count = struct.unpack("<H", data[4:6])[0]
    best = None  # (area, offset, size)
    off = 6
    for _ in range(count):
        w = data[off] or 256
        h = data[off + 1] or 256
        size = struct.unpack("<I", data[off + 8:off + 12])[0]
        offset = struct.unpack("<I", data[off + 12:off + 16])[0]
        area = w * h
        if best is None or area > best[0]:
            best = (area, offset, size)
        off += 16

    _, offset, size = best
    png = data[offset:offset + size]
    assert png[:8] == b"\x89PNG\r\n\x1a\n", "largest ICO entry is not a PNG"
    with open(out, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
