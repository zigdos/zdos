// ZMATRIX [-u]: falling green characters, as cmatrix
// -u adds katakana, math and block glyphs, if the font has them.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");

comptime {
    _ = zdos;
}

pub const zdos_file_version = [4]u8{ 0, 8, 0, 0 };

const black: zdos.Color = @enumFromInt(0);
const green: zdos.Color = @enumFromInt(2);
const light_green: zdos.Color = @enumFromInt(10);
const gray: zdos.Color = @enumFromInt(7);
const white: zdos.Color = @enumFromInt(15);

// Cells behind the white head that stay light green:
const light_len: i32 = 3;

fn screenCols(p: zdos.Pos) u32 {
    return p.col;
}
fn screenRows(p: zdos.Pos) u32 {
    return p.row;
}

const ascii_set = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz" ++
    "@#$%&*+=<>?/\\|~^!:;{}[]()";

const utf8_set = [_][]const u8{
    "ｱ", "ｲ", "ｳ", "ｴ", "ｵ", "ｶ", "ｷ", "ｸ", "ｹ", "ｺ", "ｻ", "ｼ", "ｽ", "ｾ", "ｿ", "ﾀ", "ﾁ", "ﾂ", "ﾃ", "ﾄ",
    "ﾅ", "ﾆ", "ﾇ", "ﾈ", "ﾉ", "ﾊ", "ﾋ", "ﾌ", "ﾍ", "ﾎ", "ﾏ", "ﾐ", "ﾑ", "ﾒ", "ﾓ", "ﾔ", "ﾕ", "ﾖ", "ﾗ", "ﾘ",
    "ﾙ", "ﾚ", "ﾛ", "ﾜ", "ﾝ", "∑", "∂", "∆", "∇", "∞", "≈", "≠", "±",  "√", "∫", "Ω",  "Ж",  "Ψ",  "Φ",  "λ",
    "π",  "§",  "¶",  "░", "▒", "▓", "╬", "╫", "◊", "¤",
};

const empty: u8 = 255;

const Drop = struct {
    head: i32,
    len: i32,
    delay: u8,
    tick: u8,
};

const Matrix = struct {
    cols: u32,
    rows: u32,
    utf8: bool,
    rng: std.Random,
    grid: []u8, // glyph index per cell, `empty` if blank
    drops: []Drop,

    fn glyphCount(self: *const Matrix) u32 {
        return if (self.utf8) ascii_set.len + utf8_set.len else ascii_set.len;
    }

    fn glyph(self: *const Matrix, i: u8) []const u8 {
        _ = self;
        if (i < ascii_set.len) return ascii_set[i..][0..1];
        return utf8_set[i - ascii_set.len];
    }

    fn randomGlyph(self: *Matrix) u8 {
        return @intCast(self.rng.uintLessThan(u32, self.glyphCount()));
    }

    fn put(self: *Matrix, col: u32, row: u32, g: []const u8, fg: zdos.Color) void {
        // The bottom-right cell would scroll the screen:
        if (row == self.rows - 1 and col == self.cols - 1) return;
        zdos.setCursor(col, row);
        zdos.setColor(fg, black);
        zdos.print(g);
    }

    fn cell(self: *Matrix, col: u32, row: i32) ?*u8 {
        if (row < 0 or row >= @as(i32, @intCast(self.rows))) return null;
        return &self.grid[@as(usize, @intCast(row)) * self.cols + col];
    }

    fn resetDrop(self: *Matrix, d: *Drop, first: bool) void {
        const rows: i32 = @intCast(self.rows);
        d.len = 4 + @as(i32, @intCast(self.rng.uintLessThan(u32, @max(self.rows, 6) - 2)));
        d.delay = 1 + @as(u8, @intCast(self.rng.uintLessThan(u32, 3)));
        d.tick = 0;
        const spread: u32 = if (first) self.rows * 2 else self.rows / 2 + 1;
        d.head = -@as(i32, @intCast(self.rng.uintLessThan(u32, spread)));
        _ = rows;
    }

    fn step(self: *Matrix) void {
        var col: u32 = 0;
        while (col < self.cols) : (col += 1) {
            const d = &self.drops[col];
            d.tick += 1;
            if (d.tick < d.delay) continue;
            d.tick = 0;
            d.head += 1;

            // New head glyph, white:
            if (self.cell(col, d.head)) |c| {
                c.* = self.randomGlyph();
                self.put(col, @intCast(d.head), self.glyph(c.*), white);
            }
            // The cell behind the head becomes light green:
            if (self.cell(col, d.head - 1)) |c| {
                if (c.* != empty) self.put(col, @intCast(d.head - 1), self.glyph(c.*), light_green);
            }
            // After light_len cells, light green cools down to green:
            if (self.cell(col, d.head - 1 - light_len)) |c| {
                if (c.* != empty) self.put(col, @intCast(d.head - 1 - light_len), self.glyph(c.*), green);
            }
            // Occasional glitch: a glyph in the trail changes:
            if (self.rng.uintLessThan(u32, 8) == 0) {
                const off: i32 = light_len + 2 + @as(i32, @intCast(self.rng.uintLessThan(u32, @intCast(d.len))));
                if (self.cell(col, d.head - off)) |c| {
                    if (c.* != empty) {
                        c.* = self.randomGlyph();
                        self.put(col, @intCast(d.head - off), self.glyph(c.*), green);
                    }
                }
            }
            // The end of the trail disappears:
            if (self.cell(col, d.head - d.len)) |c| {
                c.* = empty;
                self.put(col, @intCast(d.head - d.len), " ", green);
            }
            // Fully off the screen: a new drop:
            if (d.head - d.len >= @as(i32, @intCast(self.rows))) self.resetDrop(d, false);
        }
    }
};

fn hasFlag(args: []const u8, flag: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, flag)) return true;
    }
    return false;
}

pub fn main(args: []const u8) u8 {
    if (hasFlag(args, "-h") or hasFlag(args, "/?")) {
        zdos.print("zmatrix [-u]\n  -u  also use katakana and other UTF-8 glyphs\nPress any key to quit.\n");
        return 0;
    }
    if (zdos.outputRedirected()) {
        zdos.print("zmatrix needs the screen\n");
        return 1;
    }

    const size = zdos.screenSize();
    const cols = screenCols(size);
    const rows = screenRows(size);
    if (cols < 2 or rows < 2) return 1;

    const grid = zdos.allocator.alloc(u8, @as(usize, cols) * rows) catch {
        zdos.print("Out of memory\n");
        return 1;
    };
    defer zdos.allocator.free(grid);
    @memset(grid, empty);

    const drops = zdos.allocator.alloc(Drop, cols) catch {
        zdos.print("Out of memory\n");
        return 1;
    };
    defer zdos.allocator.free(drops);

    var prng = std.Random.DefaultPrng.init(zdos.millis() ^ 0x5DEECE66D);
    var m: Matrix = .{
        .cols = cols,
        .rows = rows,
        .utf8 = hasFlag(args, "-u"),
        .rng = prng.random(),
        .grid = grid,
        .drops = drops,
    };
    for (m.drops) |*d| m.resetDrop(d, true);

    zdos.print("\x1b[?1049h"); // the alternate screen
    zdos.setColor(green, black);
    zdos.clearScreen();
    zdos.showCursor(false);

    while (zdos.pollKey() == null) {
        m.step();
        zdos.sleep(56); // was 45 ms; 45 / 0.8 = 0.8x speed
    }

    zdos.setColor(gray, black);
    zdos.clearScreen();
    zdos.setCursor(0, 0);
    zdos.print("\x1b[?1049l");
    zdos.showCursor(true);
    return 0;
}
