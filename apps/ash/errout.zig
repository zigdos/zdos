// Error messages go to stream 2, so they
// don't end up in pipes, files or $(...).
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const sys = @import("../zdos/system.zig");

// A handle, sys.inherited, sys.console, sys.nul; null: where the output
// went when it was set (2>&1).
pub var target: ?i32 = sys.inherited;
pub var output: i32 = sys.inherited; // kept up to date by the shell

pub fn apply() void {
    sys.redirect(.err, target orelse zdos.SpawnOptions.caller_output) catch {};
}

pub fn print(s: []const u8) void {
    zdos.printError(s);
}

pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [600]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
        @memcpy(buf[buf.len - 4 ..], "...\n");
        break :blk buf[0..];
    };
    print(s);
}
