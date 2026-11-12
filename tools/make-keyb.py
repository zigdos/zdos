#!/usr/bin/env python3
# Makes the keyboard layouts from xkeyboard-config and keysymdef.h:
# keyb/<NAME>.ZKB for each and src/kernel/keyb_layouts.zig (the types,
# compose table and EN, compiled in). Run it after changing the list.
# Each layout is the basic section of its XKB file (includes followed);
# levels 1-4: plain, Shift, AltGr, Shift + AltGr. Enter, Backspace, Tab,
# Space and keypad * are fixed here. .ZKB, little-endian:
# "ZKBD", version u8 = 1, dead count u8 (0..16), 2 bytes reserved;
# 4 layers x 96 u32 code points by set-1 make code (0: nothing);
# then the dead keys' characters, dead count u32s.
import os
import re
import struct
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
SYM = "/usr/share/X11/xkb/symbols"
KEYSYMS = "/usr/include/X11/keysymdef.h"
OUT = os.path.join(ROOT, "src", "kernel", "keyb_layouts.zig")
KEYB_DIR = os.path.join(ROOT, "keyb")
ZKB_MAGIC = b"ZKBD"
ZKB_VERSION = 1

# (zdos name, XKB file, section) in list order, EN the default. Where a
# file has both, the Windows layouts: RU and UA "winkeys", BR "abnt2".
LAYOUTS = [
    ("EN", "us", "basic"), ("ES", "es", "basic"), ("FR", "fr", "basic"), ("DE", "de", "basic"),
    ("RU", "ru", "winkeys"), ("GB", "gb", "basic"), ("IT", "it", "basic"), ("PL", "pl", "basic"),
    ("NL", "nl", "basic"), ("SE", "se", "basic"), ("DK", "dk", "basic"), ("NO", "no", "basic"),
    ("PT", "pt", "basic"), ("BR", "br", "abnt2"), ("CZ", "cz", "basic"), ("UA", "ua", "winkeys"),
    ("GR", "gr", "basic"), ("TR", "tr", "basic"),
]

# XKB key name -> PS/2 set 1 make code (the key's position):
KEYS = {"TLDE": 0x29, "BKSL": 0x2B, "LSGT": 0x56}
for i in range(12):
    KEYS["AE%02d" % (i + 1)] = 0x02 + i
    KEYS["AD%02d" % (i + 1)] = 0x10 + i
for i in range(11):
    KEYS["AC%02d" % (i + 1)] = 0x1E + i
for i in range(10):
    KEYS["AB%02d" % (i + 1)] = 0x2C + i

# Dead keys: the accent ZDOS stores and its combining mark. Grave,
# circumflex and tilde use the spacing modifier letters: the ASCII ones
# are ordinary keys on some layouts.
DEAD = {
    "dead_grave": 0x2CB, "dead_acute": 0xB4, "dead_circumflex": 0x2C6, "dead_tilde": 0x2DC,
    "dead_macron": 0xAF, "dead_breve": 0x2D8, "dead_abovedot": 0x2D9, "dead_diaeresis": 0xA8,
    "dead_abovering": 0x2DA, "dead_doubleacute": 0x2DD, "dead_caron": 0x2C7,
    "dead_cedilla": 0xB8, "dead_ogonek": 0x2DB, "dead_tonos": 0x384,
}
# Dead keys with no combining mark here type their own character:
COMBINING = {
    0x2CB: 0x300, 0xB4: 0x301, 0x2C6: 0x302, 0x2DC: 0x303, 0xAF: 0x304, 0x2D8: 0x306,
    0x2D9: 0x307, 0xA8: 0x308, 0x2DA: 0x30A, 0x2DD: 0x30B, 0x2C7: 0x30C, 0xB8: 0x327,
    0x2DB: 0x328, 0x384: 0x301,
}


def load_keysyms():
    names = {}
    pat = re.compile(r"#define XK_(\w+)\s+0x([0-9a-fA-F]+)\s*/\*\s*U\+([0-9A-Fa-f]+)")
    with open(KEYSYMS, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = pat.search(line)
            if m:
                names[m.group(1)] = int(m.group(3), 16)
    return names


def sections(file, section, keysyms_unused=None):
    # After its includes.
    path = os.path.join(SYM, file)
    if not os.path.exists(path):
        return {}
    text = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r'xkb_symbols\s+"%s"\s*\{' % re.escape(section), text)
    if not m:
        if section != "basic":
            return sections(file, "basic")
        return {}
    end = text.find("\n};", m.end())
    block = text[m.end():end if end >= 0 else len(text)]
    block = re.sub(r"/\*.*?\*/", "", block, flags=re.S)
    block = re.sub(r"//[^\n]*", "", block)
    result = {}
    for inc in re.findall(r'include\s+"([^"]+)"', block):
        for part in inc.split("+"):
            pm = re.match(r"\s*([\w.-]+)(?:\(([\w.-]+)\))?", part)
            if pm:
                result.update(sections(pm.group(1), pm.group(2) or "basic"))
    for km in re.finditer(r"key\s+<(\w+)>\s*\{([^}]*)\}", block):
        bm = re.search(r"\[([^\]]*)\]", km.group(2))
        if bm:
            result[km.group(1)] = [s.strip() for s in bm.group(1).split(",")]
    return result


def keysym_cp(name, names, unknown):
    if name in ("NoSymbol", ""):
        return 0
    if name in DEAD:
        return DEAD[name]
    if name in names:
        return names[name]
    m = re.match(r"U([0-9A-Fa-f]{4,6})$", name)
    if m:
        return int(m.group(1), 16)
    unknown.add(name)
    return 0


def zig_string(cps):
    out = []
    for c in cps:
        if c == 0:
            out.append("\\x00")
        elif c == 0x08:
            out.append("\\x08")
        elif c == 0x09:
            out.append("\\t")
        elif c == 0x0D:
            out.append("\\r")
        elif c == 0x22:
            out.append('\\"')
        elif c == 0x5C:
            out.append("\\\\")
        else:
            out.append(chr(c))
    return '"' + "".join(out) + '"'


# Scan codes written as one string each, to keep the rows readable:
SEGMENTS = [(0x00, 0x01), (0x02, 0x0D), (0x0E, 0x0F), (0x10, 0x1B), (0x1C, 0x1D),
            (0x1E, 0x29), (0x2A, 0x2B), (0x2C, 0x35), (0x36, 0x39), (0x3A, 0x55),
            (0x56, 0x56), (0x57, 0x5F)]


def layer_zig(cps):
    parts = []
    for a, b in SEGMENTS:
        parts.append(zig_string(cps[a:b + 1]))
    return "row(" + " ++\n            ".join(parts) + "),"


def build(name, file, section, names, unknown, deadset, report):
    # deadset: every dead key's character, over all layouts:
    base = sections(file, section)
    layers = [[0] * 0x60 for _ in range(4)]
    dead_here = set()
    for key, code in KEYS.items():
        syms = base.get(key)
        if not syms:
            continue
        for level in range(4):
            if level < len(syms):
                cp = keysym_cp(syms[level], names, unknown)
                layers[level][code] = cp
                if syms[level] in DEAD:
                    dead_here.add(cp)
    # The keys ZDOS handles itself, in every layer:
    for layer in layers:
        layer[0x0E] = 0x08
        layer[0x0F] = 0x09
        layer[0x1C] = 0x0D
        layer[0x37] = ord("*")
        layer[0x39] = ord(" ")
    dead = sorted(dead_here)
    deadset.update(dead_here)
    report.append((name, file + "(" + section + ")", len(base)))
    return layers, dead


def zkb_bytes(layers, dead):
    if len(dead) > 16:
        raise ValueError("more than 16 dead keys")
    out = bytearray(ZKB_MAGIC)
    out += bytes([ZKB_VERSION, len(dead), 0, 0])
    for layer in layers:
        for cp in layer:
            out += struct.pack("<I", cp)
    for cp in dead:
        out += struct.pack("<I", cp)
    return bytes(out)


def main():
    names = load_keysyms()
    # Keysyms the header has no Unicode comment for:
    names.update({"guillemotleft": 0xAB, "guillemotright": 0xBB, "masculine": 0xBA})
    unknown = set()
    deadset = set()
    report = []
    en_text = ""
    os.makedirs(KEYB_DIR, exist_ok=True)
    for name, file, section in LAYOUTS:
        layers, dead = build(name, file, section, names, unknown, deadset, report)
        data = zkb_bytes(layers, dead)
        path = os.path.join(KEYB_DIR, name + ".ZKB")
        with open(path, "wb") as f:
            f.write(data)
        print("wrote %s: %d bytes" % (path, len(data)), file=sys.stderr)
        if name == "EN":
            # EN is compiled in: its table, as Zig code:
            dead_zig = ", ".join("'%s'" % chr(d) if d != 0x27 else "'\\''" for d in dead)
            keys = "\n".join("        " + layer_zig(layer) for layer in layers)
            en_text = ('pub const en: Layout = .{\n    .name = "EN",\n    .keys = .{\n%s\n    },\n    .dead = &.{ %s },\n};\n\n'
                       % (keys, dead_zig))
    # Compose: every dead accent with every ASCII letter it combines with:
    comps = []
    for acc in sorted(deadset):
        mark = COMBINING.get(acc)
        if mark is None:
            continue
        for base_c in list(range(0x41, 0x5B)) + list(range(0x61, 0x7B)):
            c = unicodedata.normalize("NFC", chr(base_c) + chr(mark))
            # Only Latin-1 and Latin Extended-A
            # letters, the ones the layouts use:
            if len(c) == 1 and c != chr(base_c) and 0xC0 <= ord(c) <= 0x17F:
                comps.append((acc, base_c, ord(c)))
    for name, what, n in report:
        print("%s (%s): %d keys" % (name, what, n), file=sys.stderr)
    if unknown:
        print("unknown keysyms: " + ", ".join(sorted(unknown)), file=sys.stderr)
    text = HEADER + en_text + COMPOSE_HEAD + \
        "\n".join("    .{ '%s', '%s', '%s' }," % (chr(a), chr(b), chr(c)) for a, b, c in comps) + COMPOSE_TAIL
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote %s: EN and the compose table (%d pairs)" % (OUT, len(comps)), file=sys.stderr)
    print("wrote %d layout files to %s" % (len(LAYOUTS), KEYB_DIR), file=sys.stderr)


HEADER = """// Keyboard layout types and the built-in layout EN, generated
// by tools/make-keyb.py from X11: do not edit by hand.
// Other layouts are SYSTEM\\KEYB\\*.ZKB files.
//
// One table per layer (0 plain, 1 Shift, 2 AltGr, 3
// Shift+AltGr), indexed by set-1 make code. 0:
// nothing; AltGr layers fall back to Shift / plain.
// Dead keys combine with the next key; a key that doesn't
// combine types the accent first; Space or the same accent
// types the accent alone.
const std = @import("std");

// Scan codes 0x00 .. 0x5F (0x56: the 102nd key)
pub const slots = 0x60;

pub const Layout = struct {
    name: []const u8, // two letters: the name in lists and in SYSTEM.CFG
    keys: [4][slots]u21, // by layer: plain, Shift, AltGr, Shift + AltGr
    dead: []const u21 = &.{}, // the dead keys' characters
};

// Each code point of s is one scan code, from
// 0x00; the length must be exactly slots.
fn row(comptime s: []const u8) [slots]u21 {
    @setEvalBranchQuota(40000);
    var t = [_]u21{0} ** slots;
    var view = std.unicode.Utf8View.initComptime(s).iterator();
    var n: usize = 0;
    while (view.nextCodepoint()) |c| : (n += 1) {
        if (n >= slots) @compileError("keyboard layout row is too long");
        t[n] = c;
    }
    if (n != slots) @compileError("keyboard layout row has the wrong length");
    return t;
}

"""


COMPOSE_HEAD = """// Accent, letter, result: each letter the accent combines with
const composes = [_][3]u21{
"""

COMPOSE_TAIL = """};

// Null if they don't combine.
pub fn compose(accent: u21, base: u21) ?u21 {
    for (composes) |c| {
        if (c[0] == accent and c[1] == base) return c[2];
    }
    return null;
}
"""

if __name__ == "__main__":
    main()
