// Lines that left the top of the screen, kept as UTF-8 with
// ANSI colors in a fixed buffer (SCROLLBACK=, default 64KB),
// the oldest dropped. The wheel and Shift+PgUp / PgDn / Home /
// End show them; a key returns. Off on the alternate screen.
const std = @import("std");
const tasks = @import("tasks.zig");
const platform = @import("../platform.zig");
const api = @import("api.zig");

const pc = platform.console;
pub const available = @hasDecl(pc, "cellAt");

const default_size = 64 * 1024;
const max_line = 4096; // a stored line's bytes at most (the rest cut off)

var static_buf: [default_size]u8 = undefined;
var buf: []u8 = &static_buf;
var used: usize = 0;
var lines: usize = 0;
var offset: usize = 0; // lines back from the live screen; 0: not scrolled
pub var alt = false; // the alternate screen is on
var alt_owner: usize = 0; // the program that switched to it

pub fn init() void {
    if (comptime available) pc.setScrollHook(&pushTop);
}

// SCROLLBACK=64KB / 1MB / 0
pub fn configure(get: *const fn (name: []const u8) ?[]const u8) void {
    if (comptime !available) return;
    const text = get("SCROLLBACK") orelse return;
    const size = parseSize(std.mem.trim(u8, text, " \t")) orelse return;
    if (size == buf.len) return;
    leave();
    const new: []u8 = if (size == 0)
        &.{}
    else if (size <= static_buf.len)
        static_buf[0..size]
    else if (platform.memory.alloc(size)) |p| p[0..size] else return;
    // What is kept moves over (as much as fits); with the static
    // buffer it is already in place
    if (used > new.len) dropFront(used - new.len);
    if (new.ptr != buf.ptr and used > 0) std.mem.copyForwards(u8, new[0..used], buf[0..used]);
    if (new.len == 0) {
        used = 0;
        lines = 0;
    }
    buf = new;
}

fn parseSize(text: []const u8) ?usize {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    const n = std.fmt.parseInt(usize, text[0..end], 10) catch return null;
    const unit = std.mem.trim(u8, text[end..], " ");
    const mult: usize = if (unit.len == 0 or std.ascii.eqlIgnoreCase(unit, "B")) 1 else if (std.ascii.eqlIgnoreCase(unit, "KB") or std.ascii.eqlIgnoreCase(unit, "K")) 1024 else if (std.ascii.eqlIgnoreCase(unit, "MB") or std.ascii.eqlIgnoreCase(unit, "M")) 1024 * 1024 else return null;
    return std.math.mul(usize, n, mult) catch null;
}

// A line is stored as its length (2 bytes), its text, its
// length again, so the buffer can be walked both ways.

// ANSI's color order is not VGA's (it maps itself back)
const ansi_order = [8]u8{ 0, 4, 2, 6, 1, 5, 3, 7 };

// From the console's scroll, before the top row goes
fn pushTop() void {
    if (comptime !available) return;
    // A full-screen program's lines aren't history
    if (alt or buf.len == 0 or !pc.cellsReady()) return;
    var line: [max_line]u8 = undefined;
    const n = encodeRow(0, &line);
    append(line[0..n]);
    // A view stays where it is: the live screen moved under it
    if (offset > 0) {
        offset = @min(offset + 1, lines);
        drawMarker();
        pc.viewFlush();
    }
}

fn encodeRow(row: u32, out: *[max_line]u8) usize {
    if (comptime !available) return 0;
    const cols = pc.size().col;
    // Without the blanks at its end
    var last: u32 = cols;
    while (last > 0) {
        const c = pc.cellAt(last - 1, row);
        if (c.char != ' ' or c.bg != 0) break;
        last -= 1;
    }
    var n: usize = 0;
    var fg: u8 = 7;
    var bg: u8 = 0;
    for (0..last) |x| {
        const c = pc.cellAt(@intCast(x), row);
        if (n + 16 > out.len) break;
        if (c.fg != fg or c.bg != bg) {
            const fg_code = @as(u32, if (c.fg >= 8) 90 else 30) + ansi_order[c.fg & 7];
            const bg_code = @as(u32, if (c.bg >= 8) 100 else 40) + ansi_order[c.bg & 7];
            n += (std.fmt.bufPrint(out[n..][0..12], "\x1b[{d};{d}m", .{ fg_code, bg_code }) catch unreachable).len;
            fg = c.fg;
            bg = c.bg;
        }
        const len: usize = std.unicode.utf8Encode(c.char, out[n..][0..4]) catch blk: {
            out[n] = '?';
            break :blk 1;
        };
        n += len;
    }
    return n;
}

fn append(data: []const u8) void {
    const rec = data.len + 4;
    if (rec > buf.len) return;
    if (used + rec > buf.len) dropFront(used + rec - buf.len + buf.len / 4);
    std.mem.writeInt(u16, buf[used..][0..2], @intCast(data.len), .little);
    @memcpy(buf[used + 2 ..][0..data.len], data);
    std.mem.writeInt(u16, buf[used + 2 + data.len ..][0..2], @intCast(data.len), .little);
    used += rec;
    lines += 1;
}

// The oldest lines, at least `bytes` of them, go
fn dropFront(bytes: usize) void {
    var cut: usize = 0;
    var dropped: usize = 0;
    while (cut < bytes and cut < used) {
        cut += std.mem.readInt(u16, buf[cut..][0..2], .little) + 4;
        dropped += 1;
    }
    cut = @min(cut, used);
    std.mem.copyForwards(u8, buf[0 .. used - cut], buf[cut..used]);
    used -= cut;
    lines -= dropped;
    offset = @min(offset, lines);
}

// CLS: the history goes
pub fn clear() void {
    leave();
    used = 0;
    lines = 0;
}

pub fn viewing() bool {
    return offset > 0;
}

// Whether scrolling may happen now (the
// caller checks the program's side)
pub fn usable() bool {
    if (comptime !available) return false;
    return buf.len > 0 and !alt and pc.cellsReady() and !api.screenTaken();
}

// Positive: back into the history
pub fn scrollBy(delta: i64) void {
    if (!usable()) return;
    const target: i64 = std.math.clamp(@as(i64, @intCast(offset)) + delta, 0, @as(i64, @intCast(lines)));
    setOffset(@intCast(target));
}

pub fn pageSize() i64 {
    if (comptime !available) return 1;
    return @max(1, @as(i64, pc.size().row) - 1);
}

pub fn toTop() void {
    if (usable()) setOffset(lines);
}

pub fn leave() void {
    if (offset > 0) setOffset(0);
}

fn setOffset(new: usize) void {
    if (comptime !available) return;
    if (new == offset) return;
    const was = offset;
    offset = new;
    if (new == 0) return pc.viewEnd();
    if (was == 0) pc.viewBegin();
    draw();
}

// Rows of history, then of the live screen below them
fn draw() void {
    if (comptime !available) return;
    const size = pc.size();
    // The first history line shown: offset lines back from the newest
    var pos = used;
    var k: usize = 0;
    while (k < offset and pos > 0) : (k += 1) {
        const len = std.mem.readInt(u16, buf[pos - 2 ..][0..2], .little);
        pos -= len + 4;
    }
    var r: u32 = 0;
    while (r < size.row) : (r += 1) {
        if (pos < used) {
            const len = std.mem.readInt(u16, buf[pos..][0..2], .little);
            drawLine(r, buf[pos + 2 ..][0..len], size.col);
            pos += len + 4;
        } else {
            // The live screen's rows, from its top
            const live = r - @as(u32, @intCast(@min(offset, size.row)));
            for (0..size.col) |x| pc.viewCell(@intCast(x), r, pc.cellAt(@intCast(x), live));
        }
    }
    drawMarker();
    pc.viewFlush();
}

fn drawLine(r: u32, text: []const u8, cols: u32) void {
    if (comptime !available) return;
    var x: u32 = 0;
    var fg: u8 = 7;
    var bg: u8 = 0;
    var i: usize = 0;
    while (i < text.len and x < cols) {
        if (text[i] == 0x1B) { // ESC [ fg ; bg m, as encodeRow writes it
            const end = std.mem.indexOfScalarPos(u8, text, i, 'm') orelse break;
            var it = std.mem.splitScalar(u8, text[i + 2 .. end], ';');
            const f = std.fmt.parseInt(u8, it.next() orelse "37", 10) catch 37;
            const b = std.fmt.parseInt(u8, it.next() orelse "40", 10) catch 40;
            fg = (if (f >= 90) @as(u8, 8) else 0) + ansi_order[(f % 10) & 7];
            bg = (if (b >= 100) @as(u8, 8) else 0) + ansi_order[(b % 10) & 7];
            i = end + 1;
            continue;
        }
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const c: u21 = if (i + len <= text.len) std.unicode.utf8Decode(text[i..][0..len]) catch '?' else '?';
        i += len;
        pc.viewCell(x, r, .{ .char = c, .fg = fg, .bg = bg });
        x += 1;
    }
    while (x < cols) : (x += 1) pc.viewCell(x, r, .{});
}

// "[-123]" at the top right, black on light gray
fn drawMarker() void {
    if (comptime !available) return;
    if (offset == 0) return;
    var b: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&b, "[-{d}]", .{offset}) catch return;
    const cols = pc.size().col;
    if (text.len > cols) return;
    const x0: u32 = cols - @as(u32, @intCast(text.len));
    for (text, 0..) |ch, i| pc.viewCell(x0 + @as(u32, @intCast(i)), 0, .{ .char = ch, .fg = 0, .bg = 7 });
}

// THE ALTERNATE SCREEN (ESC[?1049h / L, FROM ansi.zig)

pub fn altScreen(on: bool) void {
    if (comptime !available) return;
    if (on == alt) return;
    leave();
    if (on) {
        pc.altEnter();
        alt_owner = if (tasks.world().program) |cur| @intFromPtr(cur) else 0;
    } else pc.altLeave();
    alt = on;
}

// A program that ends on the alternate screen leaves it
pub fn programEnded(p: *const anyopaque) void {
    if (alt and alt_owner == @intFromPtr(p)) altScreen(false);
}
