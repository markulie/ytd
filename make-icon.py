#!/usr/bin/env python3
"""Writes a 256x256 PNG icon. Pure stdlib — no image library is available,
and AppImage requires an icon, so the pixels are built by hand."""
import struct
import sys
import zlib

SIZE = 256
RADIUS = 56
BG = (26, 26, 32)
PLAY = (255, 78, 66)

# play triangle, pointing right
TIP = (188, 128)
TOP = (100, 74)
BOTTOM = (100, 182)


def _side(px, py, ax, ay, bx, by):
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax)


def _in_triangle(x, y):
    d1 = _side(x, y, *TOP, *TIP)
    d2 = _side(x, y, *TIP, *BOTTOM)
    d3 = _side(x, y, *BOTTOM, *TOP)
    return not ((d1 < 0 or d2 < 0 or d3 < 0) and (d1 > 0 or d2 > 0 or d3 > 0))


def _in_rounded_square(x, y):
    cx = min(max(x, RADIUS), SIZE - 1 - RADIUS)
    cy = min(max(y, RADIUS), SIZE - 1 - RADIUS)
    return (x - cx) ** 2 + (y - cy) ** 2 <= RADIUS ** 2


def _chunk(tag: bytes, data: bytes) -> bytes:
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def render() -> bytes:
    rows = bytearray()
    for y in range(SIZE):
        rows.append(0)  # per-row filter: none
        for x in range(SIZE):
            if not _in_rounded_square(x, y):
                rows.extend((0, 0, 0, 0))  # transparent outside the corners
            elif _in_triangle(x, y):
                rows.extend((*PLAY, 255))
            else:
                rows.extend((*BG, 255))
    header = struct.pack(">2I5B", SIZE, SIZE, 8, 6, 0, 0, 0)  # 8-bit RGBA
    return (b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", header)
            + _chunk(b"IDAT", zlib.compress(bytes(rows), 9)) + _chunk(b"IEND", b""))


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "ytd.png"
    with open(out, "wb") as handle:
        handle.write(render())
    print(f"wrote {out}")
