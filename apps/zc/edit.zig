// A line of text being edited, and key helpers.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const screen = @import("screen.zig");

const Scan = zdos.Scan;

pub fn isEnter(k: zdos.Key) bool {
    return k.char == '\r' or k.char == '\n';
}

pub fn isEsc(k: zdos.Key) bool {
    return k.scan == Scan.esc or k.char == 27;
}

// A modifier or lock key pressed alone: ZDOS's own keyboard
// drivers report one (no character, no scan code); firmware
// keys don't. Nothing to act on.
pub fn isModifierOnly(k: zdos.Key) bool {
    return k.char == 0 and k.scan == 0;
}

// The letter of Ctrl+letter (lower case):
pub fn ctrlLetter(k: zdos.Key) ?u8 {
    if (k.char >= 1 and k.char <= 26 and k.char != 8 and k.char != 9 and k.char != 10 and k.char != 13) return @intCast('a' + k.char - 1);
    if (k.ctrl() and k.char < 128 and std.ascii.isAlphabetic(@intCast(k.char))) return std.ascii.toLower(@intCast(k.char));
    return null;
}

// F1..F12 as 1..12:
pub fn fkey(k: zdos.Key) ?u8 {
    if (k.scan >= Scan.f1 and k.scan <= Scan.f10) return @intCast(k.scan - Scan.f1 + 1);
    if (k.scan == Scan.f11) return 11;
    if (k.scan == Scan.f12) return 12;
    return null;
}

pub const Line = struct {
    chars: [512]u21 = undefined,
    len: usize = 0,
    caret: usize = 0,
    scroll: usize = 0,

    pub fn clear(self: *Line) void {
        self.len = 0;
        self.caret = 0;
        self.scroll = 0;
    }

    pub fn set(self: *Line, text: []const u8) void {
        self.clear();
        var it = (std.unicode.Utf8View.init(text) catch return).iterator();
        while (it.nextCodepoint()) |c| {
            if (self.len == self.chars.len) break;
            self.chars[self.len] = c;
            self.len += 1;
        }
        self.caret = self.len;
    }

    pub fn utf8(self: *const Line, buf: []u8) []const u8 {
        var n: usize = 0;
        for (self.chars[0..self.len]) |c| {
            if (n + 4 > buf.len) break;
            n += std.unicode.utf8Encode(c, buf[n..][0..4]) catch 0;
        }
        return buf[0..n];
    }

    // An editing key: true if it was one.
    pub fn key(self: *Line, k: zdos.Key) bool {
        switch (k.scan) {
            Scan.left => self.caret -|= 1,
            Scan.right => self.caret = @min(self.caret + 1, self.len),
            Scan.home => self.caret = 0,
            Scan.end => self.caret = self.len,
            Scan.delete => if (self.caret < self.len) self.remove(self.caret),
            else => {
                if (k.char == 8) {
                    if (self.caret > 0) {
                        self.caret -= 1;
                        self.remove(self.caret);
                    }
                    return true;
                }
                if (k.char < 32 or k.char == 127 or k.ctrl() or k.alt()) return false;
                if (self.len == self.chars.len) return true;
                std.mem.copyBackwards(u21, self.chars[self.caret + 1 .. self.len + 1], self.chars[self.caret..self.len]);
                self.chars[self.caret] = k.char;
                self.len += 1;
                self.caret += 1;
            },
        }
        return true;
    }

    fn remove(self: *Line, at: usize) void {
        std.mem.copyForwards(u21, self.chars[at .. self.len - 1], self.chars[at + 1 .. self.len]);
        self.len -= 1;
    }

    // What fits width cells, scrolled to show the caret
    // (at caret - scroll):
    pub fn window(self: *Line, width: usize) []const u21 {
        if (width == 0) return &.{};
        if (self.caret < self.scroll) self.scroll = self.caret;
        if (self.caret >= self.scroll + width) self.scroll = self.caret + 1 - width;
        return self.chars[self.scroll..@min(self.len, self.scroll + width)];
    }

    // In width cells at x, y; the caret's column:
    pub fn draw(self: *Line, x: u32, y: u32, width: u32, fg: screen.Color, bg: screen.Color) u32 {
        if (width == 0) return x;
        _ = self.window(width);
        var i: u32 = 0;
        while (i < width) : (i += 1) {
            const at = self.scroll + i;
            const c: u21 = if (at < self.len) self.chars[at] else ' ';
            screen.put(x + i, y, c, fg, bg);
        }
        return x + @as(u32, @intCast(self.caret - self.scroll));
    }
};
