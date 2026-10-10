"""Writes a small animated WebP test fixture without external tools.

Each frame is a solid colour encoded as lossless VP8L with single-symbol ("simple") prefix codes, so the pixel data
takes no bits at all. Usage: python3 Tools/make_animated_webp.py <out.webp> <width> <height> <frame-ms> RRGGBB [RRGGBB ...]
"""
import struct
import sys


class Bits:
    def __init__(self):
        self.value = 0
        self.count = 0

    def put(self, value, width):
        self.value |= (value & ((1 << width) - 1)) << self.count
        self.count += width

    def bytes(self):
        length = (self.count + 7) // 8
        return self.value.to_bytes(length, "little")


def vp8l(width, height, rgb):
    bits = Bits()
    bits.put(width - 1, 14)
    bits.put(height - 1, 14)
    bits.put(0, 1)  # alpha_is_used
    bits.put(0, 3)  # version
    bits.put(0, 1)  # no transform
    bits.put(0, 1)  # no colour cache
    bits.put(0, 1)  # no meta prefix codes
    red, green, blue = rgb
    for symbol in (green, red, blue, 255, 0):  # green, red, blue, alpha, distance
        bits.put(1, 1)  # simple code
        bits.put(0, 1)  # one symbol
        if symbol > 1:
            bits.put(1, 1)
            bits.put(symbol, 8)
        else:
            bits.put(0, 1)
            bits.put(symbol, 1)
    return b"\x2f" + bits.bytes()


def chunk(tag, payload):
    data = tag + struct.pack("<I", len(payload)) + payload
    return data + (b"\x00" if len(payload) % 2 else b"")


def u24(value):
    return struct.pack("<I", value)[:3]


def animated(width, height, duration, colours):
    frames = b""
    for rgb in colours:
        frame = u24(0) + u24(0) + u24(width - 1) + u24(height - 1) + u24(duration) + b"\x02"  # no blend, keep
        frames += chunk(b"ANMF", frame + chunk(b"VP8L", vp8l(width, height, rgb)))
    vp8x = chunk(b"VP8X", bytes([0x02, 0, 0, 0]) + u24(width - 1) + u24(height - 1))
    anim = chunk(b"ANIM", b"\x00\x00\x00\x00" + struct.pack("<H", 0))
    body = b"WEBP" + vp8x + anim + frames
    return b"RIFF" + struct.pack("<I", len(body)) + body


if __name__ == "__main__":
    out, width, height, duration = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
    colours = [tuple(int(hex_[i:i + 2], 16) for i in (0, 2, 4)) for hex_ in sys.argv[5:]]
    with open(out, "wb") as handle:
        handle.write(animated(width, height, duration, colours))
