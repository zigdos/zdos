#!/usr/bin/env python3
# Makes fonts/terminal/<family>-<W>x<H>.zfn from Spleen and Terminus BDF
# files, which must be copied into fonts/terminal/ first. ZFNT: 16-byte
# header "ZFNT", version u8 = 1, width u8, height u8, flags u8 (0), glyph
# count u32, reserved u32; then per
# glyph in code point order: code point u32, height rows of (width+7)/8 bytes,
# the leftmost pixel in the high bit. Glyphs sit in the font's full cell
# (FONTBOUNDINGBOX), cut at its edges.
import glob
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
FONTS = os.path.join(ROOT, "fonts", "terminal")


def read_bdf(path):
    # (width, height, x offset, y offset) of the cell, and code point ->
    # (bbx width, bbx height, bbx x, bbx y, rows of bytes):
    cell = None
    glyphs = {}
    code = None
    bbx = None
    rows = None
    in_bitmap = False
    with open(path, encoding="latin-1") as f:
        for line in f:
            line = line.strip()
            if line.startswith("FONTBOUNDINGBOX "):
                _, w, h, x, y = line.split()
                cell = (int(w), int(h), int(x), int(y))
            elif line.startswith("ENCODING "):
                code = int(line.split()[1])
            elif line.startswith("BBX "):
                _, w, h, x, y = line.split()
                bbx = (int(w), int(h), int(x), int(y))
            elif line == "BITMAP":
                rows = []
                in_bitmap = True
            elif line == "ENDCHAR":
                if code is not None and code >= 0 and bbx is not None:
                    glyphs[code] = (bbx, rows)
                code = None
                bbx = None
                in_bitmap = False
            elif in_bitmap:
                rows.append(bytes.fromhex(line))
    if cell is None:
        raise SystemExit(f"{path}: no FONTBOUNDINGBOX")
    return cell, glyphs


def pixel(row_bytes, x):
    # Leftmost pixel in the high bit of the first byte.
    return (row_bytes[x // 8] >> (7 - x % 8)) & 1


def place(glyph, cell):
    # As rows of pixels (1 = ink).
    cw, ch, cx, cy = cell
    (gw, gh, gx, gy), rows = glyph
    out = [[0] * cw for _ in range(ch)]
    # Glyph row j is cell row j + (cell top - glyph top):
    shift_row = (cy + ch) - (gy + gh)
    shift_col = gx - cx
    for j in range(gh):
        for i in range(gw):
            if not pixel(rows[j], i):
                continue
            r = j + shift_row
            c = i + shift_col
            if 0 <= r < ch and 0 <= c < cw:
                out[r][c] = 1
    return out


def cell_bytes(pixels, cw, ch):
    per_row = (cw + 7) // 8
    data = bytearray()
    for row in pixels:
        for byte in range(per_row):
            value = 0
            for bit in range(8):
                x = byte * 8 + bit
                if x < cw and row[x]:
                    value |= 0x80 >> bit
            data.append(value)
    return bytes(data)


def write_zfn(path, cell, glyphs):
    cw, ch = cell[0], cell[1]
    out = bytearray(b"ZFNT")
    out += bytes([1, cw, ch, 0])
    out += struct.pack("<II", len(glyphs), 0)
    for code in sorted(glyphs):
        out += struct.pack("<I", code)
        out += cell_bytes(place(glyphs[code], cell), cw, ch)
    with open(path, "wb") as f:
        f.write(out)
    return len(out)


def main():
    made = []
    for bdf in sorted(glob.glob(os.path.join(FONTS, "*.bdf"))):
        family = os.path.basename(bdf).split("-")[0]
        cell, glyphs = read_bdf(bdf)
        out = os.path.join(FONTS, f"{family}-{cell[0]}x{cell[1]}.zfn")
        size_bytes = write_zfn(out, cell, glyphs)
        made.append((os.path.basename(out), len(glyphs), size_bytes))
    for name, count, size in made:
        print(f"{name}: {count} glyphs, {size} bytes")


if __name__ == "__main__":
    main()
