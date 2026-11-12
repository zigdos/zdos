// Variables, kept by ZDOS: a global scope and one per running batch file.
// ERRORLEVEL, CD, DATE and TIME are made here (a SET hides them).
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const sys = @import("../zdos/system.zig");

pub const max_name = 32;
pub const max_value = 512;

pub var errorlevel: u8 = 0;

pub const Buf = [max_value]u8;

// In buf; null if not set.
pub fn get(name: []const u8, buf: *Buf) ?[]const u8 {
    if (zdos.getVar(name, buf)) |v| return v;
    const is = std.ascii.eqlIgnoreCase;
    if (is(name, "ERRORLEVEL")) return std.fmt.bufPrint(buf, "{d}", .{errorlevel}) catch null;
    if (is(name, "CD")) {
        const cwd = zdos.getCwd(buf);
        return if (cwd.len > 0) cwd else null;
    }
    if (is(name, "DATE") or is(name, "TIME")) {
        const t = zdos.getTime();
        if (t.year == 0) return null; // no clock
        return if (is(name, "DATE"))
            std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2}", .{ t.year, t.month, t.day }) catch null
        else
            std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second }) catch null;
    }
    return null;
}

pub const SetError = error{ BadName, TooLong, OutOfSpace, Denied };

// An empty value removes it (in a batch file hides the outer one).
pub fn set(name: []const u8, value: []const u8) SetError!void {
    if (name.len == 0 or name.len > max_name or std.mem.indexOfAny(u8, name, "=% ") != null) return error.BadName;
    if (value.len > max_value) return error.TooLong;
    zdos.setVar(name, value) catch |err| return switch (err) {
        error.InvalidName => error.BadName,
        error.InvalidArgument => error.TooLong,
        error.AccessDenied => error.Denied, // a global variable, not an admin
        else => error.OutOfSpace,
    };
}

// False if nested too deeply or out of memory.
pub fn pushScope() bool {
    sys.pushVars() catch return false;
    return true;
}

pub fn popScope() void {
    sys.popVars();
}

pub fn each(ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8, []const u8) void) void {
    var buf: [max_name + 1 + max_value]u8 = undefined;
    var index: u32 = 0;
    while (zdos.varAt(index, &buf)) |line| : (index += 1) {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        f(ctx, line[0..eq], line[eq + 1 ..]);
    }
}
