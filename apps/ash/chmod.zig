const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const users = @import("../zdos/users.zig");
const errout = @import("errout.zig");

// chmod/chown [-R] MODE PATH: MODE in octal or symbolic.
// Usage and bad modes or owners exit 1, as BSD's.
// For non-unix fs (FAT) only the write bits count: none makes it read only.
// Names from USERS.CFG, GROUPS.CFG. Root only, as on Linux. FAT has no owners.

const Change = union(enum) {
    mode: []const u8, // as typed: applied to each file's own mode
    owner: struct { uid: ?u32, gid: ?u32 },
};

pub fn runChmod(args: []const []const u8) u8 {
    return run("chmod", args);
}

pub fn runChown(args: []const []const u8) u8 {
    return run("chown", args);
}

fn run(cmd: []const u8, args: []const []const u8) u8 {
    var recursive = false;
    var first: usize = 0;
    while (first < args.len and args[first].len > 1 and args[first][0] == '-') : (first += 1) {
        const arg = args[first];
        if (std.mem.eql(u8, arg, "--")) {
            first += 1;
            break;
        }
        // "-w" ... is a symbolic mode, not an option:
        if (std.mem.eql(u8, cmd, "chmod") and isSymbolic(arg)) break;
        for (arg[1..]) |option| switch (option) {
            'R' => recursive = true,
            else => {
                errout.printf("{s}: unsupported option: -{c}\n", .{ cmd, option });
                return 1;
            },
        };
    }
    if (args.len - first < 2) {
        if (std.mem.eql(u8, cmd, "chmod")) {
            errout.print("usage: chmod [-R] MODE PATH...\n");
        } else errout.print("usage: chown [-R] [OWNER][:GROUP] PATH...\n");
        return 1;
    }
    const spec = args[first];
    const change: Change = if (std.mem.eql(u8, cmd, "chmod")) blk: {
        if (applyMode(spec, 0o644, false) == null) {
            errout.printf("chmod: invalid mode: {s}\n", .{spec});
            return 1;
        }
        break :blk .{ .mode = spec };
    } else blk: {
        const ids = parseOwner(spec) orelse {
            errout.printf("chown: invalid owner: {s} (no such user or group)\n", .{spec});
            return 1;
        };
        break :blk .{ .owner = .{ .uid = ids[0], .gid = ids[1] } };
    };
    var result: u8 = 0;
    for (args[first + 1 ..]) |path| {
        if (!apply(cmd, change, path, recursive, 0)) result = 1;
    }
    return result;
}

// With recursive also what is below it; false after an error.
fn apply(cmd: []const u8, change: Change, path: []const u8, recursive: bool, depth: u32) bool {
    const entry = zdos.stat(path) catch |err| return fail(cmd, path, err);
    var ok = true;
    switch (change) {
        .mode => |spec| {
            const now = zdos.permissions(path) catch |err| return fail(cmd, path, err);
            const mode = applyMode(spec, now.mode, entry.is_dir).?; // checked when parsed
            if (mode != now.mode & 0o7777) zdos.setMode(path, mode) catch |err| {
                ok = fail(cmd, path, err);
            };
        },
        .owner => |ids| zdos.setOwner(path, ids.uid, ids.gid) catch |err| {
            ok = fail(cmd, path, err);
        },
    }
    if (!recursive or !entry.is_dir or depth >= 64) return ok;
    const dir = zdos.openDir(path) catch |err| return fail(cmd, path, err);
    defer dir.close();
    var item: zdos.DirEntry = undefined;
    while (dir.next(&item) catch |err| return fail(cmd, path, err)) {
        const name = item.name();
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const sep: []const u8 = if (path.len > 0 and (path[path.len - 1] == '/' or path[path.len - 1] == '\\')) "" else "/";
        const child = std.fmt.allocPrint(zdos.allocator, "{s}{s}{s}", .{ path, sep, name }) catch {
            errout.printf("{s}: not enough memory\n", .{cmd});
            return false;
        };
        defer zdos.allocator.free(child);
        if (!apply(cmd, change, child, true, depth + 1)) ok = false;
    }
    return ok;
}

fn fail(cmd: []const u8, path: []const u8, err: zdos.Error) bool {
    errout.printf("{s}: {s}: {s}\n", .{ cmd, path, zdos.message(err) });
    return false;
}

// "-w", "-x,u+r"
fn isSymbolic(arg: []const u8) bool {
    for (arg[1..]) |c| {
        if (std.mem.indexOfScalar(u8, "rwxXst,+-=ugoa", c) == null) return false;
    }
    return true;
}

// Null: not a valid mode. dir: X sets execute on folders.
fn applyMode(spec: []const u8, now: u32, dir: bool) ?u32 {
    if (spec.len == 0) return null;
    if (std.ascii.isDigit(spec[0])) {
        const v = std.fmt.parseInt(u32, spec, 8) catch return null;
        return if (v > 0o7777) null else v;
    }
    var mode = now & 0o7777;
    var clauses = std.mem.splitScalar(u8, spec, ',');
    while (clauses.next()) |clause| {
        var i: usize = 0;
        var who: u32 = 0;
        while (i < clause.len) : (i += 1) {
            who |= switch (clause[i]) {
                'u' => 0o4700,
                'g' => 0o2070,
                'o' => 0o1007,
                'a' => 0o7777,
                else => break,
            };
        }
        if (who == 0) who = 0o7777; // no umask in ZDOS: as "a"
        if (i == clause.len) return null; // no operator
        while (i < clause.len) {
            const op = clause[i];
            if (op != '+' and op != '-' and op != '=') return null;
            i += 1;
            var bits: u32 = 0;
            while (i < clause.len and clause[i] != '+' and clause[i] != '-' and clause[i] != '=') : (i += 1) {
                bits |= switch (clause[i]) {
                    'r' => 0o444,
                    'w' => 0o222,
                    'x' => 0o111,
                    'X' => if (dir or mode & 0o111 != 0) 0o111 else 0,
                    's' => 0o6000,
                    't' => 0o1000,
                    else => return null,
                };
            }
            bits &= who;
            switch (op) {
                '+' => mode |= bits,
                '-' => mode &= ~bits,
                else => mode = (mode & ~who) | bits,
            }
        }
    }
    return mode;
}

// "1000", "1000:100", ":100", "1000:": null for "as it is"
var user_list: users.List = .{};
var group_list: users.Groups = .{};

fn parseOwner(spec: []const u8) ?[2]?u32 {
    const colon = std.mem.indexOfScalar(u8, spec, ':');
    const owner = if (colon) |c| spec[0..c] else spec;
    const group = if (colon) |c| spec[c + 1 ..] else "";
    users.load(&user_list) catch {};
    users.loadGroups(&group_list) catch {};
    const uid = if (owner.len == 0) null else userId(owner) orelse return null;
    // "alice:": the user's own group (numbered as the user):
    const gid = if (group.len > 0) groupId(group) orelse return null else if (colon != null and uid != null) uid else null;
    if (uid == null and gid == null) return null;
    return .{ uid, gid };
}

fn userId(text: []const u8) ?u32 {
    if (parseId(text)) |v| return v;
    return if (user_list.find(text)) |u| u.uid else null;
}

// A user's name means their own group.
fn groupId(text: []const u8) ?u32 {
    if (parseId(text)) |v| return v;
    if (group_list.find(text)) |g| return g.gid;
    return if (user_list.find(text)) |u| u.uid else null;
}

fn parseId(text: []const u8) ?u32 {
    const v = std.fmt.parseInt(u32, text, 10) catch return null;
    return if (v == std.math.maxInt(u32)) null else v; // that one means "keep"
}
