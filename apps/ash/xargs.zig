// xargs [-0] [-r] [-n N] [-I TEXT] [COMMAND [ARGUMENT...]] Programs get as many
// words as fit in ZDOS's 4 KiB argument text per run; built-ins get them all.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const sys = @import("../zdos/system.zig");
const shell_mod = @import("shell.zig");
const names = @import("names.zig");
const text = @import("text.zig");

const Allocator = std.mem.Allocator;
const Shell = shell_mod.Shell;

const max_program_args = 4000;

pub fn run(sh: *Shell, args: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(zdos.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nul = false;
    var no_empty = false;
    var per_run: usize = std.math.maxInt(usize);
    var replace: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len and args[i].len > 1 and args[i][0] == '-') : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "-0")) {
            nul = true;
        } else if (std.mem.eql(u8, arg, "-r")) {
            no_empty = true;
        } else if (std.mem.startsWith(u8, arg, "-n")) {
            const value = if (arg.len > 2) arg[2..] else blk: {
                i += 1;
                break :blk if (i < args.len) args[i] else "";
            };
            per_run = std.fmt.parseInt(usize, value, 10) catch return usage();
            if (per_run == 0) return usage();
        } else if (std.mem.startsWith(u8, arg, "-I")) {
            replace = if (arg.len > 2) arg[2..] else blk: {
                i += 1;
                break :blk if (i < args.len) args[i] else return usage();
            };
        } else return usage();
    }
    const command: []const []const u8 = if (i < args.len) args[i..] else &.{"echo"};

    var words: std.ArrayListUnmanaged([]const u8) = .{};
    var reader = text.Reader.stdin();
    if (replace != null) {
        var line: std.ArrayListUnmanaged(u8) = .{};
        while (reader.readLine(a, &line) catch false) {
            const t = std.mem.trimLeft(u8, line.items, " \t");
            if (t.len > 0) words.append(a, a.dupe(u8, t) catch return shell_mod.outOfMemory()) catch return shell_mod.outOfMemory();
        }
    } else {
        readWords(a, &reader, nul, &words) catch return shell_mod.outOfMemory();
    }
    if (words.items.len == 0 and (no_empty or replace != null)) return 0;

    // The commands read nothing more from the input:
    const old_in = sh.in_handle;
    sh.setInput(sys.nul);
    defer sh.setInput(old_in);

    var status: u8 = 0;
    if (replace) |r| {
        for (words.items) |word| {
            var argv: std.ArrayListUnmanaged([]const u8) = .{};
            for (command) |c| {
                const replaced = std.mem.replaceOwned(u8, a, c, r, word) catch return shell_mod.outOfMemory();
                argv.append(a, replaced) catch return shell_mod.outOfMemory();
            }
            status = merge(status, sh.runBuiltinOrProgram(a, argv.items));
            if (sh.interrupted) break;
        }
        return status;
    }
    const builtin = names.isBuiltin(command[0]);
    var base_len: usize = 0;
    for (command[1..]) |c| base_len += c.len + 3;
    var next: usize = 0;
    while (true) {
        var argv: std.ArrayListUnmanaged([]const u8) = .{};
        argv.appendSlice(a, command) catch return shell_mod.outOfMemory();
        var len = base_len;
        var count: usize = 0;
        while (next < words.items.len and count < per_run) {
            const w = words.items[next];
            if (!builtin and count > 0 and len + w.len + 3 > max_program_args) break;
            argv.append(a, w) catch return shell_mod.outOfMemory();
            len += w.len + 3;
            count += 1;
            next += 1;
        }
        status = merge(status, sh.runBuiltinOrProgram(a, argv.items));
        if (next >= words.items.len or sh.interrupted) break;
    }
    return status;
}

// 123 if some run failed, 127 if the command was not found.
fn merge(old: u8, new: u8) u8 {
    if (new == 127) return 127;
    if (new != 0 and old == 0) return 123;
    return old;
}

fn readWords(a: Allocator, reader: *text.Reader, nul: bool, words: *std.ArrayListUnmanaged([]const u8)) Allocator.Error!void {
    var word: std.ArrayListUnmanaged(u8) = .{};
    var have = false;
    var quote: u8 = 0;
    while (reader.readByte() catch null) |c| {
        if (nul) {
            if (c == 0) {
                try words.append(a, try a.dupe(u8, word.items));
                word.clearRetainingCapacity();
            } else try word.append(a, c);
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0 else try word.append(a, c);
            continue;
        }
        switch (c) {
            ' ', '\t', '\n', '\r' => {
                if (have) try words.append(a, try a.dupe(u8, word.items));
                word.clearRetainingCapacity();
                have = false;
            },
            '\'', '"' => {
                quote = c;
                have = true;
            },
            '\\' => {
                if (reader.readByte() catch null) |n| try word.append(a, n);
                have = true;
            },
            else => {
                try word.append(a, c);
                have = true;
            },
        }
    }
    if (have or (nul and word.items.len > 0)) try words.append(a, try a.dupe(u8, word.items));
}

fn usage() u8 {
    errout.print("usage: xargs [-0] [-r] [-n N] [-I TEXT] [COMMAND [ARGUMENT...]]\n");
    return 1;
}
