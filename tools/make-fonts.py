#!/usr/bin/env python3
# Makes fonts/terminal/<family>-<W>x<H>.zfn from Spleen and Terminus BDF
# files, which must be copied into fonts/terminal/ first. ZFNT: 16-byte
# header "ZFNT", version u8 = 1, width u8, height u8, flags u8 (0), glyph
# count u32, reserved u32; then per
# glyph in code point order: code point u32, height rows of (width+7)/8 bytes,
# the leftmost pixel in the high bit. Glyphs sit in the font's full cell
# (FONTBOUNDINGBOX), cut at its edges.
#
# CP437'S SYMBOLS: Spleen draws some only in its CP437 files
# (cp437/<family>-<W>x<H>-ibm-437.bdf, copied in too). A size
# with one gets the characters it lacks from it; a size above
# 8x16 without one (Spleen 12x24) gets the next larger one's,
# scaled down. Bytes become code points through
# fonts/codepages/CP437.zcp.
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


def cp437_points():
    path = os.path.join(ROOT, "fonts", "codepages", "CP437.zcp")
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"ZCPG":
        raise SystemExit(f"{path}: not a codepage file")
    return struct.unpack("<256I", data[12:12 + 1024])


def as_glyph(pixels, cell):
    # Pixel rows filling the cell, as read_bdf's glyphs:
    cw, ch, cx, cy = cell
    per_row = (cw + 7) // 8
    data = cell_bytes(pixels, cw, ch)
    return (cw, ch, cx, cy), [data[r * per_row:(r + 1) * per_row] for r in range(ch)]


def scaled_down(pixels, sw, sh, dw, dh):
    # Each target pixel inked when the source pixels under it are
    # at least 35% ink: keeps 2-pixel strokes whole and even.
    fx, fy = sw / dw, sh / dh
    out = []
    for y in range(dh):
        y0, y1 = y * fy, (y + 1) * fy
        row = []
        for x in range(dw):
            x0, x1 = x * fx, (x + 1) * fx
            ink = 0.0
            for sy in range(int(y0), min(sh, -int(-y1 // 1))):
                h = min(y1, sy + 1) - max(y0, sy)
                for sx in range(int(x0), min(sw, -int(-x1 // 1))):
                    w = min(x1, sx + 1) - max(x0, sx)
                    if h > 0 and w > 0 and pixels[sy][sx]:
                        ink += w * h
            row.append(1 if ink >= 0.35 * fx * fy else 0)
        out.append(row)
    return out


def larger_cp437(family, cw, ch):
    # The smallest CP437 file of the family larger than cw x ch:
    best = None
    for path in glob.glob(os.path.join(FONTS, f"{family}-*x*-ibm-437.bdf")):
        w, h = (int(v) for v in os.path.basename(path).split("-")[1].split("x"))
        if w > cw and h > ch and (best is None or w < best[0]):
            best = (w, path)
    return best[1] if best else None


def cp437_extra(family, cell, have):
    # The CP437 characters the font lacks, from its own size's
    # CP437 file, else (sizes above 8x16: Spleen 12x24) the next
    # larger one's scaled down; {} if none.
    cw, ch = cell[0], cell[1]
    own = os.path.join(FONTS, f"{family}-{cw}x{ch}-ibm-437.bdf")
    if os.path.exists(own):
        src = own
    else:
        # The small sizes would lose too much of the drawing:
        src = larger_cp437(family, cw, ch) if cw > 8 and ch > 16 else None
    if src is None:
        return {}
    src_cell, src_glyphs = read_bdf(src)
    points = cp437_points()
    extra = {}
    for byte, glyph in src_glyphs.items():
        code = points[byte] if 0 <= byte < 256 else 0
        if code == 0 or code in have:
            continue
        pixels = place(glyph, src_cell)
        if src != own:
            pixels = scaled_down(pixels, src_cell[0], src_cell[1], cw, ch)
        extra[code] = as_glyph(pixels, cell)
    return extra


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
        if bdf.endswith("-ibm-437.bdf"):
            continue
        family = os.path.basename(bdf).split("-")[0]
        cell, glyphs = read_bdf(bdf)
        extra = cp437_extra(family, cell, glyphs)
        glyphs.update(extra)
        out = os.path.join(FONTS, f"{family}-{cell[0]}x{cell[1]}.zfn")
        size_bytes = write_zfn(out, cell, glyphs)
        made.append((os.path.basename(out), len(glyphs), len(extra), size_bytes))
    for name, count, added, size in made:
        print(f"{name}: {count} glyphs ({added} from CP437), {size} bytes")


if __name__ == "__main__":
    main()
