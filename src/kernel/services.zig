// SERVICES.CFG, read once at startup: each NAME=true starts
// NAME as a background task, as root, output dropped.
// NAME=true fifo 28 (or rr; priority 0-31) sets its scheduling.
const std = @import("std");
const platform = @import("../platform.zig");
const con = @import("console.zig");
const fs = @import("fs.zig");
const tasks = @import("tasks.zig");

pub const path = "\\CONF\\SERVICES.CFG";

pub fn start() void {
    const d = fs.bootDrive() orelse return;
    const f = fs.openFile(d, path, .read) catch |err| {
        if (err != error.NotFound) con.printf("Cannot read {s}: {s}\n", .{ path, fs.message(err) });
        return;
    };
    const S = struct {
        var buf: [4096]u8 = undefined;
    };
    var len: usize = 0;
    while (len < S.buf.len) {
        const n = platform.storage.read(f, S.buf[len..]) catch break;
        if (n == 0) break;
        len += n;
    }
    fs.close(f);
    var lines = std.mem.tokenizeAny(u8, S.buf[0..len], "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#' or line[0] == ';' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        var words = std.mem.tokenizeAny(u8, value, " \t,");
        if (!std.ascii.eqlIgnoreCase(words.next() orelse "", "true") or name.len == 0) continue;
        var policy: ?tasks.Policy = null;
        var priority: ?u8 = null;
        while (words.next()) |w| {
            if (std.ascii.eqlIgnoreCase(w, "fifo")) policy = .fifo else if (std.ascii.eqlIgnoreCase(w, "rr")) policy = .rr else if (std.fmt.parseInt(u8, w, 10) catch null) |n| {
                if (n < tasks.priorities) priority = n else con.printf("Services: {s}: priority {d} (0-31)\n", .{ name, n });
            } else con.printf("Services: {s}: \"{s}\"? (fifo, rr, a priority)\n", .{ name, w });
        }
        if (!tasks.active()) {
            con.printf("Services: {s} needs tasks (not on this edition)\n", .{name});
            continue;
        }
        const id = tasks.spawn(name, "", .{ .input = .nul, .output = .nul, .errout = .nul, .policy = policy, .priority = priority }) catch |err| {
            con.printf("Services: {s}: {s}\n", .{ name, switch (err) {
                error.NotFound => "not found",
                error.NotProgram => "not a program",
                error.OutOfMemory => "not enough memory",
                error.TooMany => "too many tasks",
                error.NotSupported => "no tasks on this edition",
                error.InvalidArgument => "bad variables",
            } });
            continue;
        };
        con.printf("Services: {s} started (task {d})\n", .{ name, id });
    }
}
