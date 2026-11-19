// Line breaking for libass, libunibreak's interface (linebreak.h):
// the rules of Unicode's line breaking (UAX #14) that matter for text
// on a screen: breaks at spaces, after hyphens and dashes and between
// CJK characters, never before closing punctuation or after opening.
// Tested on the host: zig test linebreak.zig
const std = @import("std");

const must_break: u8 = 0; // linebreak.h's LINEBREAK_MUSTBREAK
const allow_break: u8 = 1;
const no_break: u8 = 2;
const indeterminate: u8 = 4; // after the last character

// The classes used, of UAX #14's:
const Class = enum {
    al, // letters, digits, anything else: no break between
    nu, // digits (no break after a hyphen before one)
    sp, // space
    bk, // line feed and the like: break after
    cr,
    gl, // no-break space, word joiner: never break
    zw, // zero-width space: break after
    cm, // combining marks, joiners, variation selectors
    op, // opening punctuation: no break after
    cl, // closing punctuation, ! ? , . : ; small kana: no break before
    hy, // hyphen-minus: break after, unless a digit follows
    ba, // hyphens, dashes, soft hyphen: break after
    b2, // em dash: break before and after
    id, // CJK ideographs, kana, Hangul syllables: break around
};

const Range = struct { lo: u21, hi: u21, class: Class };

// Sorted, not overlapping; what isn't here is al:
const ranges = [_]Range{
    .{ .lo = 0x0021, .hi = 0x0021, .class = .cl }, // !
    .{ .lo = 0x0028, .hi = 0x0028, .class = .op },
    .{ .lo = 0x0029, .hi = 0x0029, .class = .cl },
    .{ .lo = 0x002C, .hi = 0x002C, .class = .cl },
    .{ .lo = 0x002D, .hi = 0x002D, .class = .hy },
    .{ .lo = 0x002E, .hi = 0x002E, .class = .cl },
    .{ .lo = 0x002F, .hi = 0x002F, .class = .cl },
    .{ .lo = 0x0030, .hi = 0x0039, .class = .nu },
    .{ .lo = 0x003A, .hi = 0x003B, .class = .cl },
    .{ .lo = 0x003F, .hi = 0x003F, .class = .cl },
    .{ .lo = 0x005B, .hi = 0x005B, .class = .op },
    .{ .lo = 0x005D, .hi = 0x005D, .class = .cl },
    .{ .lo = 0x007B, .hi = 0x007B, .class = .op },
    .{ .lo = 0x007D, .hi = 0x007D, .class = .cl },
    .{ .lo = 0x00A0, .hi = 0x00A0, .class = .gl },
    .{ .lo = 0x00AB, .hi = 0x00AB, .class = .op }, // «
    .{ .lo = 0x00AD, .hi = 0x00AD, .class = .ba }, // soft hyphen
    .{ .lo = 0x00BB, .hi = 0x00BB, .class = .cl }, // »
    .{ .lo = 0x00BF, .hi = 0x00BF, .class = .op }, // ¿
    .{ .lo = 0x0300, .hi = 0x036F, .class = .cm },
    .{ .lo = 0x0483, .hi = 0x0489, .class = .cm },
    .{ .lo = 0x0591, .hi = 0x05BD, .class = .cm },
    .{ .lo = 0x05BF, .hi = 0x05BF, .class = .cm },
    .{ .lo = 0x05C1, .hi = 0x05C2, .class = .cm },
    .{ .lo = 0x05C4, .hi = 0x05C5, .class = .cm },
    .{ .lo = 0x05C7, .hi = 0x05C7, .class = .cm },
    .{ .lo = 0x0610, .hi = 0x061A, .class = .cm },
    .{ .lo = 0x061F, .hi = 0x061F, .class = .cl }, // Arabic question mark
    .{ .lo = 0x064B, .hi = 0x065F, .class = .cm },
    .{ .lo = 0x0670, .hi = 0x0670, .class = .cm },
    .{ .lo = 0x06D6, .hi = 0x06DC, .class = .cm },
    .{ .lo = 0x06DF, .hi = 0x06E4, .class = .cm },
    .{ .lo = 0x06E7, .hi = 0x06E8, .class = .cm },
    .{ .lo = 0x06EA, .hi = 0x06ED, .class = .cm },
    .{ .lo = 0x0900, .hi = 0x0903, .class = .cm },
    .{ .lo = 0x093A, .hi = 0x094F, .class = .cm },
    .{ .lo = 0x0951, .hi = 0x0957, .class = .cm },
    .{ .lo = 0x0E31, .hi = 0x0E31, .class = .cm }, // Thai vowels and tones
    .{ .lo = 0x0E34, .hi = 0x0E3A, .class = .cm },
    .{ .lo = 0x0E47, .hi = 0x0E4E, .class = .cm },
    .{ .lo = 0x1AB0, .hi = 0x1AFF, .class = .cm },
    .{ .lo = 0x1DC0, .hi = 0x1DFF, .class = .cm },
    .{ .lo = 0x2007, .hi = 0x2007, .class = .gl }, // figure space
    .{ .lo = 0x200B, .hi = 0x200B, .class = .zw },
    .{ .lo = 0x200C, .hi = 0x200D, .class = .cm }, // ZWNJ, ZWJ
    .{ .lo = 0x2010, .hi = 0x2010, .class = .ba },
    .{ .lo = 0x2011, .hi = 0x2011, .class = .gl }, // non-breaking hyphen
    .{ .lo = 0x2012, .hi = 0x2013, .class = .ba },
    .{ .lo = 0x2014, .hi = 0x2014, .class = .b2 },
    .{ .lo = 0x2018, .hi = 0x2018, .class = .op }, // ‘
    .{ .lo = 0x2019, .hi = 0x2019, .class = .cl }, // ’
    .{ .lo = 0x201A, .hi = 0x201A, .class = .op },
    .{ .lo = 0x201C, .hi = 0x201C, .class = .op }, // “
    .{ .lo = 0x201D, .hi = 0x201D, .class = .cl }, // ”
    .{ .lo = 0x201E, .hi = 0x201E, .class = .op }, // „
    .{ .lo = 0x2026, .hi = 0x2026, .class = .cl }, // …
    .{ .lo = 0x2028, .hi = 0x2029, .class = .bk },
    .{ .lo = 0x202F, .hi = 0x202F, .class = .gl },
    .{ .lo = 0x2039, .hi = 0x2039, .class = .op }, // ‹
    .{ .lo = 0x203A, .hi = 0x203A, .class = .cl }, // ›
    .{ .lo = 0x2060, .hi = 0x2060, .class = .gl }, // word joiner
    .{ .lo = 0x20D0, .hi = 0x20FF, .class = .cm },
    .{ .lo = 0x2E80, .hi = 0x2FFF, .class = .id }, // CJK radicals
    .{ .lo = 0x3000, .hi = 0x3000, .class = .ba }, // ideographic space
    .{ .lo = 0x3001, .hi = 0x3002, .class = .cl }, // 、。
    .{ .lo = 0x3003, .hi = 0x3004, .class = .id },
    .{ .lo = 0x3005, .hi = 0x3005, .class = .cl }, // 々
    .{ .lo = 0x3006, .hi = 0x3007, .class = .id },
    .{ .lo = 0x3008, .hi = 0x3008, .class = .op }, // 〈 and the brackets after:
    .{ .lo = 0x3009, .hi = 0x3009, .class = .cl },
    .{ .lo = 0x300A, .hi = 0x300A, .class = .op },
    .{ .lo = 0x300B, .hi = 0x300B, .class = .cl },
    .{ .lo = 0x300C, .hi = 0x300C, .class = .op }, // 「
    .{ .lo = 0x300D, .hi = 0x300D, .class = .cl }, // 」
    .{ .lo = 0x300E, .hi = 0x300E, .class = .op },
    .{ .lo = 0x300F, .hi = 0x300F, .class = .cl },
    .{ .lo = 0x3010, .hi = 0x3010, .class = .op }, // 【
    .{ .lo = 0x3011, .hi = 0x3011, .class = .cl },
    .{ .lo = 0x3012, .hi = 0x3013, .class = .id },
    .{ .lo = 0x3014, .hi = 0x3014, .class = .op },
    .{ .lo = 0x3015, .hi = 0x3015, .class = .cl },
    .{ .lo = 0x3016, .hi = 0x3016, .class = .op },
    .{ .lo = 0x3017, .hi = 0x3017, .class = .cl },
    .{ .lo = 0x3018, .hi = 0x3018, .class = .op },
    .{ .lo = 0x3019, .hi = 0x3019, .class = .cl },
    .{ .lo = 0x301A, .hi = 0x301A, .class = .op },
    .{ .lo = 0x301B, .hi = 0x301B, .class = .cl },
    .{ .lo = 0x301C, .hi = 0x301C, .class = .cl }, // 〜
    .{ .lo = 0x301D, .hi = 0x301D, .class = .op },
    .{ .lo = 0x301E, .hi = 0x301F, .class = .cl },
    .{ .lo = 0x3020, .hi = 0x3029, .class = .id },
    .{ .lo = 0x302A, .hi = 0x302F, .class = .cm },
    .{ .lo = 0x3030, .hi = 0x303A, .class = .id },
    .{ .lo = 0x303B, .hi = 0x303C, .class = .cl },
    .{ .lo = 0x303D, .hi = 0x303F, .class = .id },
    // Hiragana, its small letters and marks no line starts with:
    .{ .lo = 0x3041, .hi = 0x3041, .class = .cl },
    .{ .lo = 0x3042, .hi = 0x3042, .class = .id },
    .{ .lo = 0x3043, .hi = 0x3043, .class = .cl },
    .{ .lo = 0x3044, .hi = 0x3044, .class = .id },
    .{ .lo = 0x3045, .hi = 0x3045, .class = .cl },
    .{ .lo = 0x3046, .hi = 0x3046, .class = .id },
    .{ .lo = 0x3047, .hi = 0x3047, .class = .cl },
    .{ .lo = 0x3048, .hi = 0x3048, .class = .id },
    .{ .lo = 0x3049, .hi = 0x3049, .class = .cl },
    .{ .lo = 0x304A, .hi = 0x3062, .class = .id },
    .{ .lo = 0x3063, .hi = 0x3063, .class = .cl }, // っ
    .{ .lo = 0x3064, .hi = 0x3082, .class = .id },
    .{ .lo = 0x3083, .hi = 0x3083, .class = .cl },
    .{ .lo = 0x3084, .hi = 0x3084, .class = .id },
    .{ .lo = 0x3085, .hi = 0x3085, .class = .cl },
    .{ .lo = 0x3086, .hi = 0x3086, .class = .id },
    .{ .lo = 0x3087, .hi = 0x3087, .class = .cl },
    .{ .lo = 0x3088, .hi = 0x308D, .class = .id },
    .{ .lo = 0x308E, .hi = 0x308E, .class = .cl },
    .{ .lo = 0x308F, .hi = 0x3094, .class = .id },
    .{ .lo = 0x3095, .hi = 0x3096, .class = .cl },
    .{ .lo = 0x3099, .hi = 0x309A, .class = .cm },
    .{ .lo = 0x309B, .hi = 0x309E, .class = .cl },
    .{ .lo = 0x309F, .hi = 0x309F, .class = .id },
    // Katakana, the same:
    .{ .lo = 0x30A0, .hi = 0x30A1, .class = .cl },
    .{ .lo = 0x30A2, .hi = 0x30A2, .class = .id },
    .{ .lo = 0x30A3, .hi = 0x30A3, .class = .cl },
    .{ .lo = 0x30A4, .hi = 0x30A4, .class = .id },
    .{ .lo = 0x30A5, .hi = 0x30A5, .class = .cl },
    .{ .lo = 0x30A6, .hi = 0x30A6, .class = .id },
    .{ .lo = 0x30A7, .hi = 0x30A7, .class = .cl },
    .{ .lo = 0x30A8, .hi = 0x30A8, .class = .id },
    .{ .lo = 0x30A9, .hi = 0x30A9, .class = .cl },
    .{ .lo = 0x30AA, .hi = 0x30C2, .class = .id },
    .{ .lo = 0x30C3, .hi = 0x30C3, .class = .cl }, // ッ
    .{ .lo = 0x30C4, .hi = 0x30E2, .class = .id },
    .{ .lo = 0x30E3, .hi = 0x30E3, .class = .cl },
    .{ .lo = 0x30E4, .hi = 0x30E4, .class = .id },
    .{ .lo = 0x30E5, .hi = 0x30E5, .class = .cl },
    .{ .lo = 0x30E6, .hi = 0x30E6, .class = .id },
    .{ .lo = 0x30E7, .hi = 0x30E7, .class = .cl },
    .{ .lo = 0x30E8, .hi = 0x30ED, .class = .id },
    .{ .lo = 0x30EE, .hi = 0x30EE, .class = .cl },
    .{ .lo = 0x30EF, .hi = 0x30F4, .class = .id },
    .{ .lo = 0x30F5, .hi = 0x30F6, .class = .cl },
    .{ .lo = 0x30F7, .hi = 0x30FA, .class = .id },
    .{ .lo = 0x30FB, .hi = 0x30FE, .class = .cl }, // ・ー ヽヾ
    .{ .lo = 0x30FF, .hi = 0x30FF, .class = .id },
    .{ .lo = 0x3105, .hi = 0x31EF, .class = .id }, // Bopomofo, CJK strokes
    .{ .lo = 0x31F0, .hi = 0x31FF, .class = .cl }, // small Katakana
    .{ .lo = 0x3200, .hi = 0x4DBF, .class = .id }, // enclosed, CJK Ext. A
    .{ .lo = 0x4E00, .hi = 0x9FFF, .class = .id }, // CJK ideographs
    .{ .lo = 0xA000, .hi = 0xA4CF, .class = .id }, // Yi
    .{ .lo = 0xAC00, .hi = 0xD7A3, .class = .id }, // Hangul syllables
    .{ .lo = 0xF900, .hi = 0xFAFF, .class = .id },
    .{ .lo = 0xFE00, .hi = 0xFE0F, .class = .cm }, // variation selectors
    .{ .lo = 0xFE20, .hi = 0xFE2F, .class = .cm },
    .{ .lo = 0xFE30, .hi = 0xFE4F, .class = .id }, // CJK compatibility forms
    .{ .lo = 0xFEFF, .hi = 0xFEFF, .class = .gl },
    // Full-width forms: their punctuation as above, the rest ideographic:
    .{ .lo = 0xFF01, .hi = 0xFF01, .class = .cl },
    .{ .lo = 0xFF02, .hi = 0xFF07, .class = .id },
    .{ .lo = 0xFF08, .hi = 0xFF08, .class = .op },
    .{ .lo = 0xFF09, .hi = 0xFF09, .class = .cl },
    .{ .lo = 0xFF0A, .hi = 0xFF0B, .class = .id },
    .{ .lo = 0xFF0C, .hi = 0xFF0C, .class = .cl },
    .{ .lo = 0xFF0D, .hi = 0xFF0D, .class = .id },
    .{ .lo = 0xFF0E, .hi = 0xFF0E, .class = .cl },
    .{ .lo = 0xFF0F, .hi = 0xFF19, .class = .id },
    .{ .lo = 0xFF1A, .hi = 0xFF1B, .class = .cl },
    .{ .lo = 0xFF1C, .hi = 0xFF1E, .class = .id },
    .{ .lo = 0xFF1F, .hi = 0xFF1F, .class = .cl },
    .{ .lo = 0xFF20, .hi = 0xFF3A, .class = .id },
    .{ .lo = 0xFF3B, .hi = 0xFF3B, .class = .op },
    .{ .lo = 0xFF3C, .hi = 0xFF3C, .class = .id },
    .{ .lo = 0xFF3D, .hi = 0xFF3D, .class = .cl },
    .{ .lo = 0xFF3E, .hi = 0xFF5A, .class = .id },
    .{ .lo = 0xFF5B, .hi = 0xFF5B, .class = .op },
    .{ .lo = 0xFF5C, .hi = 0xFF5C, .class = .id },
    .{ .lo = 0xFF5D, .hi = 0xFF5D, .class = .cl },
    .{ .lo = 0xFF5E, .hi = 0xFF5E, .class = .id },
    .{ .lo = 0xFF5F, .hi = 0xFF5F, .class = .op },
    .{ .lo = 0xFF60, .hi = 0xFF61, .class = .cl },
    .{ .lo = 0xFF62, .hi = 0xFF62, .class = .op },
    .{ .lo = 0xFF63, .hi = 0xFF64, .class = .cl },
    .{ .lo = 0xFFE0, .hi = 0xFFE6, .class = .id },
    .{ .lo = 0x1F300, .hi = 0x1F64F, .class = .id }, // emoji, pictographs
    .{ .lo = 0x1F680, .hi = 0x1F6FF, .class = .id },
    .{ .lo = 0x1F900, .hi = 0x1F9FF, .class = .id },
    .{ .lo = 0x20000, .hi = 0x3FFFD, .class = .id }, // CJK Ext. B and later
    .{ .lo = 0xE0100, .hi = 0xE01EF, .class = .cm },
};

comptime {
    @setEvalBranchQuota(10000);
    for (ranges[1..], 0..) |r, i| {
        if (r.lo > r.hi or r.lo <= ranges[i].hi) @compileError("ranges not sorted");
    }
}

fn classOf(cp: u32) Class {
    switch (cp) {
        ' ' => return .sp,
        '\n', 0x0B, 0x0C, 0x85 => return .bk,
        '\r' => return .cr,
        else => {},
    }
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < ranges[mid].lo) hi = mid else if (cp > ranges[mid].hi) lo = mid + 1 else return ranges[mid].class;
    }
    return .al;
}

// The break between a and b (b follows a):
fn pair(a: Class, b: Class) u8 {
    if (a == .bk) return must_break;
    if (a == .cr) return if (b == .bk) no_break else must_break;
    if (b == .bk or b == .cr or b == .sp or b == .zw) return no_break;
    if (a == .zw) return allow_break;
    if (b == .cm or a == .gl or b == .gl) return no_break;
    if (b == .cl) return no_break;
    if (a == .op) return no_break;
    if (a == .sp) return allow_break;
    if (a == .b2 and b == .b2) return no_break;
    if (b == .hy or b == .ba) return no_break;
    if (a == .hy) return if (b == .nu) no_break else allow_break;
    if (a == .ba or a == .b2 or b == .b2) return allow_break;
    if (a == .id or b == .id) return allow_break;
    return no_break;
}

// brks[i]: the break after s[i]; the last character's is must_break
// after a line end, else indeterminate (libunibreak 5 and later).
export fn set_linebreaks_utf32(s: [*]const u32, len: usize, lang: ?[*:0]const u8, brks: [*]u8) callconv(.c) void {
    _ = lang;
    if (len == 0) return;
    // A combining mark takes the class of what it combines with
    // (UAX #14's rule 9); after a space it counts as a letter:
    var prev: Class = classOf(s[0]);
    if (prev == .cm) prev = .al;
    for (0..len - 1) |i| {
        const next_raw = classOf(s[i + 1]);
        brks[i] = pair(prev, next_raw);
        if (next_raw != .cm or prev == .sp or prev == .bk or prev == .cr or prev == .zw) {
            prev = if (next_raw == .cm) .al else next_raw;
        }
    }
    brks[len - 1] = if (prev == .bk or prev == .cr) must_break else indeterminate;
}

export fn init_linebreak() callconv(.c) void {}

// TESTS

fn breaks(comptime text: []const u8) []const u8 {
    var cps: [256]u32 = undefined;
    var n: usize = 0;
    var it = (std.unicode.Utf8View.init(text) catch unreachable).iterator();
    while (it.nextCodepoint()) |cp| : (n += 1) cps[n] = cp;
    const Out = struct {
        var buf: [256]u8 = undefined;
    };
    set_linebreaks_utf32(&cps, n, null, &Out.buf);
    // One letter per character: m must, a allow, - none, ? indeterminate
    for (Out.buf[0..n]) |*b| b.* = switch (b.*) {
        must_break => 'm',
        allow_break => 'a',
        no_break => '-',
        else => '?',
    };
    return Out.buf[0..n];
}

test "words break after spaces" {
    try std.testing.expectEqualStrings("-----a--?", breaks("Hello you"));
    try std.testing.expectEqualStrings("------a--?", breaks("Hello  you")); // only after the last space
}

test "line ends" {
    try std.testing.expectEqualStrings("-m-?", breaks("a\nbc"));
    try std.testing.expectEqualStrings("--m", breaks("ab\n"));
    try std.testing.expectEqualStrings("---m?", breaks("ab\r\nc")); // CR LF together
}

test "punctuation" {
    try std.testing.expectEqualStrings("---a-?", breaks("Hi, yo")); // not before the comma
    try std.testing.expectEqualStrings("-a----a-?", breaks("a (bc) de")); // not after (, not before )
    try std.testing.expectEqualStrings("----a---?", breaks("well-done")); // after the hyphen
    try std.testing.expectEqualStrings("a--?", breaks(" -42")); // not between - and a digit
}

test "no-break space" {
    try std.testing.expectEqualStrings("----?", breaks("10\u{00A0}kg"));
}

test "CJK" {
    try std.testing.expectEqualStrings("aa?", breaks("日本語"));
    try std.testing.expectEqualStrings("a-a?", breaks("日本。語")); // not before 。
    try std.testing.expectEqualStrings("-?", breaks("「本")); // not after 「
    try std.testing.expectEqualStrings("--?", breaks("ちょっ")); // not before small kana ょ, っ
    try std.testing.expectEqualStrings("aaa?", breaks("한국어요")); // Hangul syllables
}

test "combining marks stay with their letter" {
    try std.testing.expectEqualStrings("---a?", breaks("e\u{0301}e x"));
}
