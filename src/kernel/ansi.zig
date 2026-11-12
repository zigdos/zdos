// ANSI escape sequences in screen output, like ANSI.SYS.
// TERM=zdos: SGR colors only; TERM=vt100 adds cursor movement,
// erasing, save/hide and ESC c. Other sequences are read to
// their end and dropped; one may span several writes.
// File and pipe output keeps them.
const scrollback = @import("scrollback.zig");
const platform = @import("../platform.zig");
const Position = platform.Position;

pub const Mode = enum { zdos, vt100 };
pub var mode: Mode = .zdos;

pub fn modeName() []const u8 {
    return @tagName(mode);
}

pub const default_fg = 7; // light gray
pub const default_bg = 0; // black

// Current colors, by a sequence or setColor (VGA numbers 0-15)
var fg: u8 = default_fg;
var bg: u8 = default_bg;
var bold = false; // 1: bright foreground for the colors 0-7
var reverse = false; // 7: foreground and background swapped

const State = enum { text, esc, csi };
var state: State = .text;
const max_params = 16;
var params: [max_params]u16 = undefined;
var count: usize = 0; // parameters started
var private = false; // a parameter byte other than digits and ';' ("ESC [ ? 25 h")
var question = false; // that byte was '?' (DEC private modes)
var intermediate = false; // intermediate bytes ("ESC ( B", "ESC [ 2 SP q"): not ours
var saved: Position = .{ .col = 0, .row = 0 }; // ESC [ s, ESC 7

// ANSI color order (black, red, green, yellow, blue, magenta,
// cyan, white) as VGA numbers
const vga = [8]u8{ 0, 4, 2, 6, 1, 5, 3, 7 };

// The 16 colors as RGB, in VGA order, for matching 256-color
// and RGB sequences: xterm's palette, which those sequences are
// made for (pure red 255,0,0 is light red there).
const palette = [16][3]u8{
    .{ 0, 0, 0 },       .{ 0, 0, 238 },   .{ 0, 205, 0 },   .{ 0, 205, 205 },
    .{ 205, 0, 0 },     .{ 205, 0, 205 }, .{ 205, 205, 0 }, .{ 229, 229, 229 },
    .{ 127, 127, 127 }, .{ 92, 92, 255 }, .{ 0, 255, 0 },   .{ 0, 255, 255 },
    .{ 255, 0, 0 },     .{ 255, 0, 255 }, .{ 255, 255, 0 }, .{ 255, 255, 255 },
};

pub fn write(str: []const u8) void {
    var start: usize = 0; // start of the text not yet written
    for (str, 0..) |c, i| {
        switch (state) {
            .text => if (c == 0x1B) {
                if (i > start) platform.console.write(str[start..i]);
                state = .esc;
                intermediate = false;
            },
            .esc => switch (c) {
                '[' => if (intermediate) {
                    finalEsc(c);
                    start = i + 1;
                    continue;
                } else {
                    state = .csi;
                    count = 0;
                    private = false;
                    question = false;
                },
                0x1B => intermediate = false,
                0x20...0x2F => intermediate = true, // "ESC ( B"
                else => {
                    // The final byte of a two-byte sequence ("ESC 7"); a control
                    // byte or non-ASCII cancels the sequence and is shown
                    if (c >= 0x20 and c < 0x7F) {
                        finalEsc(c);
                        start = i + 1;
                    } else {
                        state = .text;
                        start = i;
                    }
                    continue;
                },
            },
            .csi => switch (c) {
                '0'...'9' => {
                    if (count == 0) startParam();
                    if (count <= max_params) {
                        const p = &params[count - 1];
                        p.* = p.* *| 10 +| (c - '0');
                    }
                },
                ';' => {
                    if (count == 0) startParam();
                    startParam();
                },
                0x3A...0x3A, 0x3C...0x3F => {
                    private = true; // ':' '<' '=' '>' '?'
                    if (c == '?') question = true;
                },
                0x20...0x2F => intermediate = true,
                0x40...0x7E => {
                    state = .text;
                    if (!intermediate) finalCsi(c);
                    start = i + 1;
                    continue;
                },
                0x1B => {
                    state = .esc;
                    intermediate = false;
                },
                else => { // a control byte cancels the sequence and is shown
                    state = .text;
                    start = i;
                    continue;
                },
            },
        }
        if (state != .text) start = i + 1;
    }
    if (state == .text and str.len > start) platform.console.write(str[start..]);
}

// The final byte of "ESC x" (x not '[')
fn finalEsc(c: u8) void {
    state = .text;
    const was_intermediate = intermediate;
    intermediate = false;
    if (mode != .vt100 or was_intermediate) return;
    switch (c) {
        '7' => saved = platform.console.getCursor(),
        '8' => platform.console.setCursor(saved),
        'c' => {
            resetColors();
            apply();
            platform.console.showCursor(true);
            platform.console.clear();
            platform.console.setCursor(.{ .col = 0, .row = 0 });
        },
        else => {},
    }
}

// The final byte of "ESC [ ... x"
fn finalCsi(c: u8) void {
    if (c == 'm' and !private) return sgr();
    if (mode != .vt100) return;
    if (question) {
        if (c == 'h' or c == 'l') {
            for (params[0..@min(count, max_params)]) |p| {
                if (p == 25) platform.console.showCursor(c == 'h');
                // The alternate screen: full-screen programs (no scrollback there)
                if (p == 47 or p == 1047 or p == 1049) scrollback.altScreen(c == 'h');
            }
        }
        return;
    }
    if (private) return;
    const size = platform.console.size();
    if (size.col == 0 or size.row == 0) return;
    const last_col = size.col - 1;
    const last_row = size.row - 1;
    var pos = platform.console.getCursor();
    const n = param(0, 1);
    switch (c) {
        'A' => pos.row -|= n,
        'B' => pos.row = @min(pos.row +| n, last_row),
        'C' => pos.col = @min(pos.col +| n, last_col),
        'D' => pos.col -|= n,
        'E' => pos = .{ .col = 0, .row = @min(pos.row +| n, last_row) },
        'F' => pos = .{ .col = 0, .row = pos.row -| n },
        'G' => pos.col = @min(n - 1, last_col),
        'd' => pos.row = @min(n - 1, last_row),
        'H', 'f' => pos = .{ .col = @min(param(1, 1) - 1, last_col), .row = @min(n - 1, last_row) },
        'J' => {
            const here = pos.row * size.col + pos.col;
            switch (param(0, 0)) {
                0 => erase(size, here, size.row * size.col),
                1 => erase(size, 0, here + 1),
                2, 3 => {
                    platform.console.clear(); // in the current background
                },
                else => {},
            }
        },
        'K' => {
            const line = pos.row * size.col;
            switch (param(0, 0)) {
                0 => erase(size, line + pos.col, line + size.col),
                1 => erase(size, line, line + pos.col + 1),
                2 => erase(size, line, line + size.col),
                else => {},
            }
        },
        's' => if (count == 0) {
            saved = pos;
        },
        'u' => pos = saved,
        else => return,
    }
    platform.console.setCursor(pos);
}

// Parameter i, or `default` when it is missing or 0 (as VT100
// does for counts and positions)
fn param(i: usize, default: u32) u32 {
    if (i >= count or i >= max_params or params[i] == 0) return default;
    return params[i];
}

// Blanks cells from..to (screen offsets, to exclusive) in
// the current colors; the caller restores the cursor
fn erase(size: Position, from: u32, to_: u32) void {
    const cells = size.row * size.col;
    // Not the bottom-right cell: writing it would scroll the screen
    const to = @min(to_, cells - 1);
    const blanks = " " ** 64;
    var at = from;
    while (at < to) {
        const row = at / size.col;
        const end = @min(to, (row + 1) * size.col);
        platform.console.setCursor(.{ .col = at % size.col, .row = row });
        var left = end - at;
        while (left > 0) {
            const k = @min(left, blanks.len);
            platform.console.write(blanks[0..k]);
            left -= k;
        }
        at = end;
    }
}

fn startParam() void {
    count += 1;
    if (count <= max_params) params[count - 1] = 0;
}

// Select Graphic Rendition: colors, bright, reverse.
// Unknown codes are ignored.
fn sgr() void {
    const n = @min(count, max_params);
    if (n == 0) { // "ESC [ m" is "ESC [ 0 m"
        resetColors();
        apply();
        return;
    }
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const p = params[i];
        switch (p) {
            0 => resetColors(),
            1 => bold = true,
            22 => bold = false,
            7 => reverse = true,
            27 => reverse = false,
            30...37 => fg = vga[p - 30],
            39 => fg = default_fg,
            40...47 => bg = vga[p - 40],
            49 => bg = default_bg,
            90...97 => fg = vga[p - 90] + 8,
            100...107 => bg = vga[p - 100], // no bright backgrounds: the normal color
            38, 48 => { // 38;5;n or 38;2;r;g;b (48 for the background)
                if (i + 1 >= n) break;
                var color: ?u8 = null;
                if (params[i + 1] == 5 and i + 2 < n) {
                    color = from256(params[i + 2]);
                    i += 2;
                } else if (params[i + 1] == 2 and i + 4 < n) {
                    color = nearest(clamp(params[i + 2]), clamp(params[i + 3]), clamp(params[i + 4]));
                    i += 4;
                } else {
                    break; // a form we don't know: the rest can't be read reliably
                }
                if (color) |col| {
                    if (p == 38) fg = col else bg = col & 7;
                }
            },
            else => {},
        }
    }
    apply();
}

fn clamp(v: u16) u8 {
    return @intCast(@min(v, 255));
}

// A color of the 256-color palette as the nearest of the 16
fn from256(n: u16) ?u8 {
    if (n < 8) return vga[n];
    if (n < 16) return vga[n - 8] + 8;
    if (n < 232) { // 6x6x6 color cube
        const levels = [6]u8{ 0, 95, 135, 175, 215, 255 };
        const k = n - 16;
        return nearest(levels[k / 36], levels[k / 6 % 6], levels[k % 6]);
    }
    if (n < 256) { // gray ramp
        const g: u8 = @intCast(8 + (n - 232) * 10);
        return nearest(g, g, g);
    }
    return null;
}

fn nearest(r: u8, g: u8, b: u8) u8 {
    var best: u8 = 0;
    var best_dist: u32 = ~@as(u32, 0);
    for (palette, 0..) |c, i| {
        const dr = @as(i32, r) - c[0];
        const dg = @as(i32, g) - c[1];
        const db = @as(i32, b) - c[2];
        const dist: u32 = @intCast(dr * dr + dg * dg + db * db);
        if (dist < best_dist) {
            best_dist = dist;
            best = @intCast(i);
        }
    }
    return best;
}

fn resetColors() void {
    fg = default_fg;
    bg = default_bg;
    bold = false;
    reverse = false;
}

fn apply() void {
    var f = fg;
    if (bold and f < 8) f += 8;
    if (reverse) {
        platform.console.setColor(bg, f & 7);
    } else {
        platform.console.setColor(f, bg);
    }
}

// Colors set by the API (set_color): later sequences start from them
pub fn setColor(f: u8, b: u8) void {
    fg = f & 0x0F;
    bg = b & 0x07;
    bold = false;
    reverse = false;
    platform.console.setColor(fg, bg);
}

// Drops a half-read sequence (when a program ends)
pub fn reset() void {
    state = .text;
    intermediate = false;
}
