// SYSTEM.CFG, read once at startup: every NAME=value
// becomes a global variable. TERM also sets the console
// mode for the session.
const std = @import("std");
const platform = @import("../platform.zig");
const con = @import("console.zig");
const fs = @import("fs.zig");
const env = @import("env.zig");
const ansi = @import("ansi.zig");

pub const path = "\\CONF\\SYSTEM.CFG";
pub const max_size = 16 * 1024;

// SHELL= or COMSPEC=, whichever came last
var interpreter_buf: [fs.max_path]u8 = undefined;
var interpreter_len: usize = 0;

pub fn interpreter() ?[]const u8 {
    return if (interpreter_len > 0) interpreter_buf[0..interpreter_len] else null;
}

pub fn load() void {
    readFile();
    const term = env.get("TERM") orelse {
        env.set("TERM", ansi.modeName()) catch {};
        return;
    };
    if (std.ascii.eqlIgnoreCase(term, "vt100")) {
        ansi.mode = .vt100;
    } else if (std.ascii.eqlIgnoreCase(term, "zdos")) {
        ansi.mode = .zdos;
    } else {
        con.printf("SYSTEM.CFG: unknown TERM={s} (vt100 or zdos); using {s}\n", .{ term, ansi.modeName() });
    }
}

fn readFile() void {
    const d = fs.bootDrive() orelse return;
    const f = fs.openFile(d, path, .read) catch |err| {
        if (err != error.NotFound) con.printf("Cannot read {s}: {s}\n", .{ path, fs.message(err) });
        return;
    };
    defer fs.close(f);
    const S = struct {
        var buf: [max_size]u8 = undefined;
    };
    var len: usize = 0;
    while (len < S.buf.len) {
        const n = platform.storage.read(f, S.buf[len..]) catch |err| {
            con.printf("Cannot read {s}: {s}\n", .{ path, fs.message(err) });
            return;
        };
        if (n == 0) break;
        len += n;
    }
    if (len == S.buf.len) {
        con.printf("{s} is too big (at most {d} bytes)\n", .{ path, max_size - 1 });
        return;
    }
    parse(S.buf[0..len]);
}

pub const Line = union(enum) {
    blank, // also a comment, a section
    bad: []const u8, // what is wrong
    setting: struct { name: []const u8, value: []const u8 },
};

// One line of SYSTEM.CFG (also read by
// metal before leaving the firmware)
pub fn line(raw: []const u8) Line {
    const l = std.mem.trim(u8, raw, " \t\r");
    if (l.len == 0 or l[0] == '#' or l[0] == ';') return .blank;
    if (l[0] == '[') return if (l[l.len - 1] != ']') .{ .bad = "a section needs [Name]" } else .blank;
    const eq = std.mem.indexOfScalar(u8, l, '=') orelse return .{ .bad = "expected NAME=value" };
    var value = std.mem.trim(u8, l[eq + 1 ..], " \t");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    return .{ .setting = .{ .name = std.mem.trim(u8, l[0..eq], " \t"), .value = value } };
}

fn parse(text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        const s = switch (line(raw)) {
            .blank => continue,
            .bad => |what| {
                problem(number, what);
                continue;
            },
            .setting => |s| s,
        };
        const name = s.name;
        const value = s.value;
        if ((std.ascii.eqlIgnoreCase(name, "SHELL") or std.ascii.eqlIgnoreCase(name, "COMSPEC")) and
            value.len > 0 and value.len <= interpreter_buf.len)
        {
            @memcpy(interpreter_buf[0..value.len], value);
            interpreter_len = value.len;
        }
        env.set(name, value) catch |err| problem(number, switch (err) {
            error.BadName => "not a valid variable name",
            error.TooLong => "the value is too long",
            error.OutOfSpace => "no room for more variables",
        });
    }
}

fn problem(number: usize, what: []const u8) void {
    con.printf("SYSTEM.CFG line {d}: {s}\n", .{ number, what });
}
