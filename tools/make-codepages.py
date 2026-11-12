#!/usr/bin/env python3
# Makes fonts/codepages/CPnnn.zcp: for each DOS codepage the code point
# of each byte value. "ZCPG", version u8 = 1, 3 bytes reserved, count
# u32 = 256, then 256 little-endian u32 code points. Bytes 0x01-0x1F
# and 0x7F are the DOS graphic symbols, as in CP437.
import codecs
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
OUT = os.path.join(ROOT, "fonts", "codepages")

# Bytes 0x00-0x1F and 0x7F in DOS codepages (0x00 is blank):
DOS_CONTROL = [
    0x0000, 0x263A, 0x263B, 0x2665, 0x2666, 0x2663, 0x2660, 0x2022,
    0x25D8, 0x25CB, 0x25D9, 0x2642, 0x2640, 0x266A, 0x266B, 0x263C,
    0x25BA, 0x25C4, 0x2195, 0x203C, 0x00B6, 0x00A7, 0x25AC, 0x21A8,
    0x2191, 0x2193, 0x2192, 0x2190, 0x221F, 0x2194, 0x25B2, 0x25BC,
]

# Names as ZDOS uses them (CODEPAGE=CP866 etc.):
CODEPAGES = {
    "CP437": "cp437", "CP737": "cp737", "CP850": "cp850", "CP852": "cp852",
    "CP855": "cp855", "CP857": "cp857", "CP860": "cp860", "CP861": "cp861",
    "CP862": "cp862", "CP863": "cp863", "CP865": "cp865", "CP866": "cp866",
    "CP1251": "cp1251", "CP1252": "cp1252", "KOI8-R": "koi8_r",
}


def points_for(codec):
    points = []
    for b in range(256):
        if b < 32 or b == 0x7F:
            points.append(DOS_CONTROL[b] if b < 32 else 0x2302)
        else:
            # 0x80-0xFF and printable ASCII from the codec; undefined bytes are
            # blank (code point 0):
            try:
                points.append(ord(bytes([b]).decode(codec)))
            except UnicodeDecodeError:
                points.append(0)
    return points


def write_map(name, points):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, f"{name}.zcp")
    data = b"ZCPG" + bytes([1, 0, 0, 0]) + struct.pack("<I", 256)
    data += b"".join(struct.pack("<I", p) for p in points)
    with open(path, "wb") as f:
        f.write(data)
    return path


def main():
    for name, codec in CODEPAGES.items():
        try:
            codecs.lookup(codec)
        except LookupError:
            raise SystemExit(f"codec {codec} is not available in Python")
        points = points_for(codec)
        blanks = sum(1 for p in points[32:] if p == 0)
        path = write_map(name, points)
        print(f"{name}: {path} ({blanks} undefined bytes)")


if __name__ == "__main__":
    main()
