// The screen as cells; flush writes the rows that changed.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");

pub const Color = zdos.Color;

pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = .light_gray,
    bg: Color = .black,

    fn same(a: Cell, b: Cell) bool {
        return a.char == b.char and a.fg == b.fg and a.bg == b.bg;
    }
};

pub var cols: u32 = 0;
pub var rows: u32 = 0;
var cells: []Cell = &.{};
var shown: []Cell = &.{};
var out: []u8 = &.{};
var all_dirty = true;

// To the screen's size; false without memory:
pub fn resize() bool {
    const size = zdos.screenSize();
    if (size.col == cols and size.row == rows and cells.len != 0) return true;
    const a = zdos.allocator;
    a.free(cells);
    a.free(shown);
    a.free(out);
    cells = &.{};
    shown = &.{};
    out = &.{};
    const n = @as(usize, size.col) * size.row;
    cells = a.alloc(Cell, n) catch return false;
    shown = a.alloc(Cell, n) catch return false;
    // A cell: 4 bytes of UTF-8 and a color sequence:
    out = a.alloc(u8, @as(usize, size.col) * 16 + 16) catch return false;
    @memset(cells, .{});
    cols = size.col;
    rows = size.row;
    all_dirty = true;
    return true;
}

pub fn invalidate() void {
    all_dirty = true;
}

pub fn put(x: u32, y: u32, c: u21, fg: Color, bg: Color) void {
    if (x >= cols or y >= rows) return;
    cells[@as(usize, y) * cols + x] = .{ .char = c, .fg = fg, .bg = bg };
}

pub fn fill(x: u32, y: u32, w: u32, h: u32, c: u21, fg: Color, bg: Color) void {
    for (y..y + h) |yy| {
        for (x..x + w) |xx| put(@intCast(xx), @intCast(yy), c, fg, bg);
    }
}

// UTF-8 text, at most width cells; the rest of width
// is filled with spaces. The cells written:
pub fn text(x: u32, y: u32, s: []const u8, width: u32, fg: Color, bg: Color) u32 {
    var n: u32 = 0;
    var i: usize = 0;
    while (n < width and i < s.len) : (n += 1) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        var c: u21 = '?';
        if (i + len <= s.len) c = std.unicode.utf8Decode(s[i..][0..len]) catch '?';
        i += if (i + len <= s.len) len else 1;
        if (c < 0x20 or c == 0x7F) c = '?';
        put(x + n, y, c, fg, bg);
    }
    var k = n;
    while (k < width) : (k += 1) put(x + k, y, ' ', fg, bg);
    return n;
}

// Characters in UTF-8 text:
pub fn textWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

// ANSI color order as VGA numbers, and back:
const ansi = [8]u8{ 0, 4, 2, 6, 1, 5, 3, 7 };

fn sgr(buf: []u8, fg: Color, bg: Color) usize {
    const f = @intFromEnum(fg);
    const b = @intFromEnum(bg);
    const fg_code: u32 = if (f >= 8) 90 + @as(u32, ansi[f - 8]) else 30 + @as(u32, ansi[f]);
    const bg_code: u32 = 40 + @as(u32, ansi[b & 7]);
    const s = std.fmt.bufPrint(buf, "\x1b[{d};{d}m", .{ fg_code, bg_code }) catch return 0;
    return s.len;
}

// Each changed row in one print. The last row stops a cell
// short: writing the corner scrolls the screen.
pub fn flush() void {
    for (0..rows) |y| {
        const at = y * cols;
        const row = cells[at..][0..cols];
        if (!all_dirty and rowSame(row, shown[at..][0..cols])) continue;
        writeRow(@intCast(y));
        @memcpy(shown[at..][0..cols], row);
    }
    all_dirty = false;
}

// Row y to the screen, whatever is there:
pub fn writeRow(y: u32) void {
    if (y >= rows) return;
    const row = cells[@as(usize, y) * cols ..][0..cols];
    const last = if (y + 1 == rows) cols -| 1 else cols;
    var n: usize = 0;
    var fg: ?Color = null;
    var bg: ?Color = null;
    for (row[0..last]) |c| {
        if (fg != c.fg or bg != c.bg) {
            n += sgr(out[n..], c.fg, c.bg);
            fg = c.fg;
            bg = c.bg;
        }
        n += std.unicode.utf8Encode(c.char, out[n..][0..4]) catch blk: {
            out[n] = '?';
            break :blk 1;
        };
    }
    zdos.setCursor(0, y);
    zdos.print(out[0..n]);
}

fn rowSame(a: []const Cell, b: []const Cell) bool {
    for (a, b) |x, y| {
        if (!x.same(y)) return false;
    }
    return true;
}
