// A terminal for SSH's remote programs: what an xterm understands of their
// output, kept in a grid and drawn on ZDOS's screen in the 16 VGA colors.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");

pub const Cell = struct {
    ch: u21 = ' ',
    fg: u4 = 7,
    bg: u4 = 0,
};

const default_fg = 7;
const default_bg = 0;
// ANSI's color order as VGA's:
const vga_of = [8]u4{ 0, 4, 2, 6, 1, 5, 3, 7 };

pub const Vt = struct {
    cols: u32,
    rows: u32,
    cells: []Cell,
    other: []Cell, // the screen not shown (main / alternate)
    alt: bool = false,
    dirty: []bool,
    x: u32 = 0,
    y: u32 = 0,
    wrap_pending: bool = false,
    top: u32 = 0, // the scroll region
    bottom: u32 = 0,
    fg: u4 = default_fg,
    bg: u4 = default_bg,
    bold: bool = false,
    reverse: bool = false,
    saved: struct { x: u32 = 0, y: u32 = 0, fg: u4 = default_fg, bg: u4 = default_bg, bold: bool = false, reverse: bool = false } = .{},
    autowrap: bool = true,
    insert: bool = false,
    cursor_visible: bool = true,
    // Tell the console about the alternate screen (no scrollback there);
    // not when the grid is drawn elsewhere (TERM).
    tell_console: bool = true,
    app_cursor: bool = false, // arrows as ESC O A
    line_drawing: bool = false, // G0 is DEC's special graphics
    state: enum { ground, esc, csi, osc, osc_esc, charset, skip_one } = .ground,
    params: [16]u32 = undefined,
    count: usize = 0,
    private: u8 = 0, // '?' or '>' after CSI
    utf8: [4]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_need: u3 = 0,
    // Cursor position, device attributes:
    reply: [64]u8 = undefined,
    reply_len: usize = 0,

    pub fn init(cols: u32, rows: u32) !Vt {
        const a = zdos.allocator;
        const n = @as(usize, cols) * rows;
        const cells = try a.alloc(Cell, n);
        const other = try a.alloc(Cell, n);
        const dirty = try a.alloc(bool, rows);
        @memset(cells, .{});
        @memset(other, .{});
        @memset(dirty, true);
        return .{ .cols = cols, .rows = rows, .cells = cells, .other = other, .dirty = dirty, .bottom = rows - 1 };
    }

    pub fn deinit(self: *Vt) void {
        zdos.allocator.free(self.cells);
        zdos.allocator.free(self.other);
        zdos.allocator.free(self.dirty);
    }

    fn at(self: *Vt, x: u32, y: u32) *Cell {
        return &self.cells[@as(usize, y) * self.cols + x];
    }

    fn blank(self: *const Vt) Cell {
        return .{ .ch = ' ', .fg = default_fg, .bg = if (self.reverse) default_fg else self.bg };
    }

    pub fn takeReply(self: *Vt) []const u8 {
        const r = self.reply[0..self.reply_len];
        self.reply_len = 0;
        return r;
    }

    fn answer(self: *Vt, text: []const u8) void {
        const n = @min(text.len, self.reply.len - self.reply_len);
        @memcpy(self.reply[self.reply_len..][0..n], text[0..n]);
        self.reply_len += n;
    }

    // INPUT: THE REMOTE PROGRAM'S OUTPUT

    pub fn feed(self: *Vt, data: []const u8) void {
        for (data) |b| self.byte(b);
    }

    fn byte(self: *Vt, b: u8) void {
        switch (self.state) {
            .ground => {},
            .esc => return self.escape(b),
            .csi => return self.csiByte(b),
            .osc => {
                if (b == 7) self.state = .ground else if (b == 0x1B) self.state = .osc_esc;
                return;
            },
            .osc_esc => {
                self.state = .ground; // ESC \ ends it
                return;
            },
            .charset => {
                self.line_drawing = b == '0';
                self.state = .ground;
                return;
            },
            .skip_one => {
                self.state = .ground;
                return;
            },
        }
        if (self.utf8_need > 0) {
            if (b & 0xC0 != 0x80) {
                self.utf8_need = 0; // broken: drop it, take b afresh
            } else {
                self.utf8[self.utf8_len] = b;
                self.utf8_len += 1;
                if (self.utf8_len == self.utf8_need) {
                    self.utf8_need = 0;
                    const cp = std.unicode.utf8Decode(self.utf8[0..self.utf8_len]) catch '?';
                    self.put(cp);
                }
                return;
            }
        }
        switch (b) {
            0x1B => {
                self.state = .esc;
            },
            '\r' => self.moveTo(0, self.y),
            '\n', 0x0B, 0x0C => self.index(),
            8 => if (self.x > 0) self.moveTo(self.x - 1, self.y),
            '\t' => self.moveTo(@min((self.x / 8 + 1) * 8, self.cols - 1), self.y),
            0...7, 0x0E...0x1A, 0x1C...0x1F, 0x7F => {},
            0x80...0xBF => {},
            0xC0...0xFF => {
                self.utf8[0] = b;
                self.utf8_len = 1;
                self.utf8_need = std.unicode.utf8ByteSequenceLength(b) catch 0;
                if (self.utf8_need <= 1) self.utf8_need = 0;
            },
            else => self.put(if (self.line_drawing) lineChar(b) else b),
        }
    }

    fn escape(self: *Vt, b: u8) void {
        self.state = .ground;
        switch (b) {
            '[' => {
                self.state = .csi;
                self.count = 0;
                self.private = 0;
                @memset(&self.params, 0);
            },
            ']', 'P', '_', '^' => self.state = .osc, // OSC, DCS ...: up to BEL or ESC \
            '(' => self.state = .charset,
            ')', '*', '+', '#', '%' => self.state = .skip_one,
            '7' => self.saveCursor(),
            '8' => self.restoreCursor(),
            'D' => self.index(),
            'E' => {
                self.moveTo(0, self.y);
                self.index();
            },
            'M' => self.reverseIndex(),
            'c' => self.reset(),
            else => {}, // '=', '>' (keypad) and others
        }
    }

    fn csiByte(self: *Vt, b: u8) void {
        switch (b) {
            '0'...'9' => {
                if (self.count == 0) self.count = 1;
                const p = &self.params[self.count - 1];
                p.* = p.* *| 10 +| (b - '0');
            },
            ';', ':' => {
                if (self.count == 0) self.count = 1;
                if (self.count < self.params.len) self.count += 1;
            },
            '?', '>', '<', '=' => self.private = b,
            0x20...0x2F => {}, // intermediate bytes
            0x40...0x7E => {
                self.state = .ground;
                self.csi(b);
            },
            else => self.state = .ground,
        }
    }

    fn param(self: *const Vt, i: usize, default: u32) u32 {
        if (i >= self.count or self.params[i] == 0) return default;
        return self.params[i];
    }

    fn csi(self: *Vt, final: u8) void {
        const n = self.param(0, 1);
        if (self.private == '?') {
            if (final == 'h' or final == 'l') self.modes(final == 'h');
            return;
        }
        if (self.private != 0) {
            if (final == 'c') self.answer("\x1b[>0;0;0c");
            return;
        }
        switch (final) {
            '@' => self.insertChars(n),
            'A' => self.moveTo(self.x, if (self.y >= self.top and self.y -| n < self.top) self.top else self.y -| n),
            'B', 'e' => self.moveTo(self.x, if (self.y <= self.bottom) @min(self.y + n, self.bottom) else self.y + n),
            'C', 'a' => self.moveTo(self.x + n, self.y),
            'D' => self.moveTo(self.x -| n, self.y),
            'E' => self.moveTo(0, @min(self.y + n, self.bottom)),
            'F' => self.moveTo(0, self.y -| n),
            'G', '`' => self.moveTo(n - 1, self.y),
            'H', 'f' => self.moveTo(self.param(1, 1) - 1, self.param(0, 1) - 1),
            'd' => self.moveTo(self.x, n - 1),
            'J' => self.eraseDisplay(self.param(0, 0)),
            'K' => self.eraseLine(self.param(0, 0)),
            'L' => self.insertLines(n),
            'M' => self.deleteLines(n),
            'P' => self.deleteChars(n),
            'S' => self.scrollUp(self.top, self.bottom, n),
            'T' => self.scrollDown(self.top, self.bottom, n),
            'X' => {
                var i: u32 = 0;
                while (i < n and self.x + i < self.cols) : (i += 1) self.at(self.x + i, self.y).* = self.blank();
                self.dirty[self.y] = true;
            },
            'm' => self.sgr(),
            'r' => {
                const t = self.param(0, 1) - 1;
                const bo = self.param(1, self.rows) - 1;
                if (t < bo and bo < self.rows) {
                    self.top = t;
                    self.bottom = bo;
                    self.moveTo(0, 0);
                }
            },
            's' => self.saveCursor(),
            'u' => self.restoreCursor(),
            'h', 'l' => if (self.param(0, 0) == 4) {
                self.insert = final == 'h';
            },
            'n' => {
                if (self.param(0, 0) == 6) {
                    var buf: [24]u8 = undefined;
                    self.answer(std.fmt.bufPrint(&buf, "\x1b[{d};{d}R", .{ self.y + 1, self.x + 1 }) catch "");
                } else if (self.param(0, 0) == 5) self.answer("\x1b[0n");
            },
            'c' => self.answer("\x1b[?1;2c"),
            else => {},
        }
    }

    fn modes(self: *Vt, on: bool) void {
        var i: usize = 0;
        while (i < @max(self.count, 1)) : (i += 1) {
            switch (self.params[i]) {
                1 => self.app_cursor = on,
                7 => self.autowrap = on,
                25 => self.cursor_visible = on,
                47, 1047, 1049 => self.alternate(on, self.params[i] == 1049),
                else => {},
            }
        }
    }

    fn alternate(self: *Vt, on: bool, save: bool) void {
        if (on == self.alt) return;
        // The console too: no local scrollback while the remote
        // program has the screen:
        if (self.tell_console) zdos.print(if (on) "\x1b[?1049h" else "\x1b[?1049l");
        if (on and save) self.saveCursor();
        std.mem.swap([]Cell, &self.cells, &self.other);
        self.alt = on;
        if (on) @memset(self.cells, self.blank());
        @memset(self.dirty, true);
        if (!on and save) self.restoreCursor();
    }

    fn sgr(self: *Vt) void {
        var i: usize = 0;
        const n = @max(self.count, 1);
        while (i < n) : (i += 1) {
            const p = self.params[i];
            switch (p) {
                0 => {
                    self.fg = default_fg;
                    self.bg = default_bg;
                    self.bold = false;
                    self.reverse = false;
                },
                1 => self.bold = true,
                22 => self.bold = false,
                7 => self.reverse = true,
                27 => self.reverse = false,
                30...37 => self.fg = vga_of[p - 30],
                39 => self.fg = default_fg,
                40...47 => self.bg = vga_of[p - 40],
                49 => self.bg = default_bg,
                90...97 => self.fg = @as(u4, vga_of[p - 90]) + 8,
                100...107 => self.bg = @as(u4, vga_of[p - 100]) + 8,
                38, 48 => {
                    var color: ?u4 = null;
                    if (i + 2 < n and self.params[i + 1] == 5) {
                        color = from256(self.params[i + 2]);
                        i += 2;
                    } else if (i + 4 < n and self.params[i + 1] == 2) {
                        color = nearest(self.params[i + 2], self.params[i + 3], self.params[i + 4]);
                        i += 4;
                    }
                    if (color) |c| {
                        if (p == 38) self.fg = c else self.bg = c;
                    }
                },
                else => {},
            }
        }
    }

    // THE GRID

    fn put(self: *Vt, cp: u21) void {
        if (self.wrap_pending and self.autowrap) {
            self.wrap_pending = false;
            self.x = 0;
            self.index();
        }
        if (self.insert) self.insertChars(1);
        var fg = self.fg;
        var bg = self.bg;
        if (self.bold and fg < 8) fg += 8;
        if (self.reverse) std.mem.swap(u4, &fg, &bg);
        self.at(self.x, self.y).* = .{ .ch = cp, .fg = fg, .bg = bg };
        self.dirty[self.y] = true;
        if (self.x + 1 < self.cols) self.x += 1 else self.wrap_pending = true;
    }

    fn moveTo(self: *Vt, x: u32, y: u32) void {
        self.wrap_pending = false;
        self.x = @min(x, self.cols - 1);
        self.y = @min(y, self.rows - 1);
    }

    fn index(self: *Vt) void {
        self.wrap_pending = false;
        if (self.y == self.bottom) self.scrollUp(self.top, self.bottom, 1) else if (self.y + 1 < self.rows) self.y += 1;
    }

    fn reverseIndex(self: *Vt) void {
        self.wrap_pending = false;
        if (self.y == self.top) self.scrollDown(self.top, self.bottom, 1) else if (self.y > 0) self.y -= 1;
    }

    fn row(self: *Vt, y: u32) []Cell {
        return self.cells[@as(usize, y) * self.cols ..][0..self.cols];
    }

    fn scrollUp(self: *Vt, top: u32, bottom: u32, n: u32) void {
        const k = @min(n, bottom - top + 1);
        var y = top;
        while (y + k <= bottom) : (y += 1) @memcpy(self.row(y), self.row(y + k));
        while (y <= bottom) : (y += 1) @memset(self.row(y), self.blank());
        @memset(self.dirty[top .. bottom + 1], true);
    }

    fn scrollDown(self: *Vt, top: u32, bottom: u32, n: u32) void {
        const k = @min(n, bottom - top + 1);
        var y = bottom;
        while (y >= top + k) : (y -= 1) {
            @memcpy(self.row(y), self.row(y - k));
            if (y == 0) break;
        }
        y = top;
        while (y < top + k) : (y += 1) @memset(self.row(y), self.blank());
        @memset(self.dirty[top .. bottom + 1], true);
    }

    fn insertLines(self: *Vt, n: u32) void {
        if (self.y < self.top or self.y > self.bottom) return;
        self.scrollDown(self.y, self.bottom, n);
        self.moveTo(0, self.y);
    }

    fn deleteLines(self: *Vt, n: u32) void {
        if (self.y < self.top or self.y > self.bottom) return;
        self.scrollUp(self.y, self.bottom, n);
        self.moveTo(0, self.y);
    }

    fn insertChars(self: *Vt, n: u32) void {
        const r = self.row(self.y);
        const k = @min(n, self.cols - self.x);
        std.mem.copyBackwards(Cell, r[self.x + k ..], r[self.x .. self.cols - k]);
        @memset(r[self.x..][0..k], self.blank());
        self.dirty[self.y] = true;
    }

    fn deleteChars(self: *Vt, n: u32) void {
        const r = self.row(self.y);
        const k = @min(n, self.cols - self.x);
        std.mem.copyForwards(Cell, r[self.x .. self.cols - k], r[self.x + k ..]);
        @memset(r[self.cols - k ..], self.blank());
        self.dirty[self.y] = true;
    }

    fn eraseLine(self: *Vt, mode: u32) void {
        const r = self.row(self.y);
        switch (mode) {
            0 => @memset(r[self.x..], self.blank()),
            1 => @memset(r[0 .. self.x + 1], self.blank()),
            else => @memset(r, self.blank()),
        }
        self.dirty[self.y] = true;
    }

    fn eraseDisplay(self: *Vt, mode: u32) void {
        const start = @as(usize, self.y) * self.cols + self.x;
        switch (mode) {
            0 => {
                @memset(self.cells[start..], self.blank());
                @memset(self.dirty[self.y..], true);
            },
            1 => {
                @memset(self.cells[0 .. start + 1], self.blank());
                @memset(self.dirty[0 .. self.y + 1], true);
            },
            else => {
                @memset(self.cells, self.blank());
                @memset(self.dirty, true);
            },
        }
    }

    fn saveCursor(self: *Vt) void {
        self.saved = .{ .x = self.x, .y = self.y, .fg = self.fg, .bg = self.bg, .bold = self.bold, .reverse = self.reverse };
    }

    fn restoreCursor(self: *Vt) void {
        self.moveTo(self.saved.x, self.saved.y);
        self.fg = self.saved.fg;
        self.bg = self.saved.bg;
        self.bold = self.saved.bold;
        self.reverse = self.saved.reverse;
    }

    fn reset(self: *Vt) void {
        if (self.alt) self.alternate(false, false);
        self.fg = default_fg;
        self.bg = default_bg;
        self.bold = false;
        self.reverse = false;
        self.top = 0;
        self.bottom = self.rows - 1;
        self.autowrap = true;
        self.insert = false;
        self.app_cursor = false;
        self.cursor_visible = true;
        self.line_drawing = false;
        @memset(self.cells, .{});
        @memset(self.dirty, true);
        self.moveTo(0, 0);
    }

    // OUTPUT: THE CHANGED ROWS ONTO THE SCREEN

    pub fn draw(self: *Vt) void {
        var y: u32 = 0;
        var drew = false;
        while (y < self.rows) : (y += 1) {
            if (!self.dirty[y]) continue;
            self.dirty[y] = false;
            drew = true;
            zdos.setCursor(0, y);
            const r = self.row(y);
            // The screen's last cell stays: writing it would scroll:
            const end = if (y + 1 == self.rows) self.cols - 1 else self.cols;
            var x: u32 = 0;
            while (x < end) {
                const fg = r[x].fg;
                const bg = r[x].bg;
                var text: [1024]u8 = undefined;
                var len: usize = 0;
                while (x < end and r[x].fg == fg and r[x].bg == bg and len + 4 <= text.len) : (x += 1) {
                    len += std.unicode.utf8Encode(r[x].ch, text[len..]) catch blk: {
                        text[len] = '?';
                        break :blk 1;
                    };
                }
                zdos.setColor(@enumFromInt(fg), @enumFromInt(bg));
                zdos.print(text[0..len]);
            }
        }
        if (drew) zdos.setColor(@enumFromInt(default_fg), @enumFromInt(default_bg));
        zdos.setCursor(self.x, self.y);
        zdos.showCursor(self.cursor_visible);
    }
};

// As an xterm sends it.
pub fn keyBytes(k: zdos.Key, app_cursor: bool, buf: *[16]u8) []const u8 {
    const S = zdos.Scan;
    if (k.scan != 0) {
        const arrow: ?u8 = switch (k.scan) {
            S.up => 'A',
            S.down => 'B',
            S.right => 'C',
            S.left => 'D',
            S.home => 'H',
            S.end => 'F',
            else => null,
        };
        if (arrow) |a| return std.fmt.bufPrint(buf, "\x1b{c}{c}", .{ @as(u8, if (app_cursor) 'O' else '['), a }) catch "";
        return switch (k.scan) {
            S.insert => "\x1b[2~",
            S.delete => "\x1b[3~",
            S.page_up => "\x1b[5~",
            S.page_down => "\x1b[6~",
            S.f1 => "\x1bOP",
            S.f1 + 1 => "\x1bOQ",
            S.f1 + 2 => "\x1bOR",
            S.f1 + 3 => "\x1bOS",
            S.f1 + 4 => "\x1b[15~",
            S.f1 + 5 => "\x1b[17~",
            S.f1 + 6 => "\x1b[18~",
            S.f1 + 7 => "\x1b[19~",
            S.f1 + 8 => "\x1b[20~",
            S.f10 => "\x1b[21~",
            S.f11 => "\x1b[23~",
            S.f12 => "\x1b[24~",
            S.esc => "\x1b",
            else => "",
        };
    }
    if (k.char == 0) return "";
    const c: u21 = if (k.char == 8) 0x7F else k.char; // Backspace: DEL, as xterm
    var len: usize = 0;
    const alt = k.mods & (zdos.Mod.left_alt | zdos.Mod.right_alt) != 0 and c < 0x80;
    if (alt) {
        buf[0] = 0x1B;
        len = 1;
    }
    len += std.unicode.utf8Encode(c, buf[len..]) catch return "";
    return buf[0..len];
}

// For ncurses line drawing.
fn lineChar(b: u8) u21 {
    return switch (b) {
        'j' => 0x2518,
        'k' => 0x2510,
        'l' => 0x250C,
        'm' => 0x2514,
        'n' => 0x253C,
        'q' => 0x2500,
        't' => 0x251C,
        'u' => 0x2524,
        'v' => 0x2534,
        'w' => 0x252C,
        'x' => 0x2502,
        'a' => 0x2592,
        '`' => 0x25C6,
        'f' => 0x00B0,
        'g' => 0x00B1,
        '~' => 0x00B7,
        '0' => 0x2588,
        else => b,
    };
}

// The nearest of the 16.
fn from256(n: u32) u4 {
    if (n < 8) return vga_of[n];
    if (n < 16) return @as(u4, vga_of[n - 8]) + 8;
    if (n < 232) {
        const c = n - 16;
        const level = [6]u32{ 0, 95, 135, 175, 215, 255 };
        return nearest(level[c / 36], level[(c / 6) % 6], level[c % 6]);
    }
    const g = 8 + (n - 232) * 10;
    return nearest(g, g, g);
}

fn nearest(r: u32, g: u32, b: u32) u4 {
    const palette = [16][3]u32{
        .{ 0, 0, 0 },       .{ 0, 0, 170 },     .{ 0, 170, 0 },     .{ 0, 170, 170 },
        .{ 170, 0, 0 },     .{ 170, 0, 170 },   .{ 170, 85, 0 },    .{ 170, 170, 170 },
        .{ 85, 85, 85 },    .{ 85, 85, 255 },   .{ 85, 255, 85 },   .{ 85, 255, 255 },
        .{ 255, 85, 85 },   .{ 255, 85, 255 },  .{ 255, 255, 85 },  .{ 255, 255, 255 },
    };
    var best: u4 = 0;
    var best_d: u32 = std.math.maxInt(u32);
    for (palette, 0..) |p, i| {
        const dr = @as(i64, @min(r, 255)) - p[0];
        const dg = @as(i64, @min(g, 255)) - p[1];
        const db = @as(i64, @min(b, 255)) - p[2];
        const d: u32 = @intCast(dr * dr + dg * dg + db * db);
        if (d < best_d) {
            best_d = d;
            best = @intCast(i);
        }
    }
    return best;
}
