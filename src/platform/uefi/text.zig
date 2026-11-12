// UTF-8 <-> UCS-2 (UEFI: no surrogate pairs); anything
// unrepresentable becomes '?'.
const std = @import("std");

// Decodes one character from s; returns it and
// how many bytes it used. Invalid UTF-8 counts as
// one '?' per bad byte.
pub fn decodeUtf8(s: []const u8) struct { char: u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(s[0]) catch return .{ .char = '?', .len = 1 };
    if (len > s.len) return .{ .char = '?', .len = 1 };
    const c = std.unicode.utf8Decode(s[0..len]) catch return .{ .char = '?', .len = 1 };
    return .{ .char = c, .len = len };
}

pub fn toUcs2(c: u21) u16 {
    return if (c > 0xFFFF or (c >= 0xD800 and c <= 0xDFFF)) '?' else @intCast(c);
}

// UTF-8 -> 0-terminated UCS-2 in out; null if it doesn't fit
pub fn utf8ToUcs2Z(s: []const u8, out: []u16) ?[*:0]const u16 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        const d = decodeUtf8(s[i..]);
        if (n + 1 >= out.len) return null;
        out[n] = toUcs2(d.char);
        n += 1;
        i += d.len;
    }
    out[n] = 0;
    return @ptrCast(out.ptr);
}

// UCS-2 -> UTF-8 in out; stops (without
// splitting a character) when out is full
pub fn ucs2ToUtf8(s: []const u16, out: []u8) []u8 {
    var n: usize = 0;
    for (s) |c| {
        const cp: u21 = if (c >= 0xD800 and c <= 0xDFFF) '?' else c;
        var tmp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &tmp) catch unreachable;
        if (n + len > out.len) break;
        @memcpy(out[n..][0..len], tmp[0..len]);
        n += len;
    }
    return out[0..n];
}
