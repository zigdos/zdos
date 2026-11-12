// Output helpers, Ctrl+C and the standard streams. Ctrl+C is caught;
// commands, batch files and pipes poll breakRequested.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const sys = @import("../zdos/system.zig");

pub fn print(str: []const u8) void {
    zdos.print(str);
}

pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    print(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

pub fn printChar(c: u21) void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(c, &buf) catch return;
    print(buf[0..len]);
}

pub fn spaces(count: usize) void {
    var i: usize = 0;
    while (i < count) : (i += 1) print(" ");
}

pub fn printRight(str: []const u8, width: usize) void {
    if (str.len < width) spaces(width - str.len);
    print(str);
}

// "    12,345"
pub fn printNum(n: u64, width: usize) void {
    var buf: [32]u8 = undefined;
    var i: usize = buf.len;
    var v = n;
    var digits: usize = 0;
    while (true) {
        if (digits > 0 and digits % 3 == 0) {
            i -= 1;
            buf[i] = ',';
        }
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
        digits += 1;
        if (v == 0) break;
    }
    printRight(buf[i..], width);
}

var interrupted = false; // while a line was read

// Since clearBreak.
pub fn breakRequested() bool {
    if (!interrupted and sys.ctrlCPressed(false)) interrupted = true;
    return interrupted;
}

pub fn clearBreak() void {
    interrupted = false;
    _ = sys.ctrlCPressed(true);
}

// Typed while the line editor had it as a key: it stops the command
// that asked for the line too.
pub fn interrupt() void {
    interrupted = true;
}

// Questions go to the screen even when output is redirected:
//   const prev = term.toScreen(); defer term.restore(prev);

pub var out_handle: i32 = sys.inherited;
pub var in_handle: i32 = sys.inherited;

pub fn setOutput(handle: i32) void {
    sys.redirect(.output, handle) catch return;
    out_handle = handle;
}

pub fn setInput(handle: i32) void {
    sys.redirect(.input, handle) catch return;
    in_handle = handle;
}

pub fn toScreen() i32 {
    const prev = out_handle;
    setOutput(sys.console);
    return prev;
}

pub fn restore(prev: i32) void {
    setOutput(prev);
}

// Set while the output goes to the MORE of -p, which shows colors.
pub var colors_to_pager = false;

// On the screen, and in the pipe to MORE of -p.
pub fn colorsWanted() bool {
    return !zdos.outputRedirected() or colors_to_pager;
}
