// .ZDL libraries, loaded by name: NAME.ZDL in the program's
// folder, else \LIBS\NAME.ZDL on the boot drive (never the
// current folder, so a library put there can't slip in).
// A shared one is loaded once per file and
// counted, others are copied per program.
const std = @import("std");
const platform = @import("../platform.zig");
const abi = @import("abi.zig");
const fs = @import("fs.zig");
const loader = @import("loader.zig");
const api = @import("api.zig");

pub const max_name = 8;
const max_libraries = 32;
pub const per_program = 8; // libraries one program may hold

// Header fields after loader.Header (byte offsets in the image)
const at_flags = 64;
const at_init = 72;
const flag_shared = 1;

const Init = *const fn (start: *const abi.Start) callconv(abi.cc) bool;

const Library = struct {
    used: bool = false,
    name: [max_name]u8 = undefined,
    name_len: usize = 0,
    // Where it was loaded from ("C:\LIBS\ZCRYPT.ZDL"): shared ones
    // are told apart by it, so two
    // files of one name aren't mixed up
    path: [fs.max_path + 2]u8 = undefined,
    path_len: usize = 0,
    shared: bool = false,
    image: loader.Image = undefined,
    table: *const anyopaque = undefined,
    users: u32 = 0, // programs holding it (one, unless shared)
};

var libraries = [_]Library{.{}} ** max_libraries;

pub const Error = error{ BadName, TooMany } || loader.LoadError;

// The library's export table for program p (holding it until p ends)
pub fn load(p: *api.Program, name_in: []const u8) Error!*const anyopaque {
    var name_buf: [max_name]u8 = undefined;
    const name = try upper(name_in, &name_buf);
    // Held already by p
    for (p.libraries[0..p.library_count]) |i| {
        if (eql(&libraries[i], name)) return libraries[i].table;
    }
    if (p.library_count == per_program) return error.TooMany;

    // The program's folder, then the boot drive's \LIBS
    var own_buf: [fs.max_path + 2]u8 = undefined;
    const own: ?[]const u8 = blk: {
        const prog_path = p.path_buf[0..p.path_len];
        const dir = std.fs.path.dirnameWindows(prog_path) orelse break :blk null;
        const sep = if (std.mem.endsWith(u8, dir, "\\")) "" else "\\";
        break :blk std.fmt.bufPrint(&own_buf, "{s}{s}{s}.ZDL", .{ dir, sep, name }) catch null;
    };
    var lib_buf: [32]u8 = undefined;
    const boot_lib: ?[]const u8 = if (fs.bootDrive()) |d|
        std.fmt.bufPrint(&lib_buf, "{c}:\\LIBS\\{s}.ZDL", .{ d.letter, name }) catch null
    else
        null;
    for ([_]?[]const u8{ own, boot_lib }) |candidate| {
        const full = candidate orelse continue;
        if (try loadFrom(p, name, full)) |table| return table;
    }
    return error.NotFound;
}

// The library at full ("C:\APPS\X.ZDL"): a shared copy
// loaded from there already, else loaded now; null if
// there is no such file
fn loadFrom(p: *api.Program, name: []const u8, full: []const u8) Error!?*const anyopaque {
    for (&libraries, 0..) |*l, i| {
        if (l.used and l.shared and std.ascii.eqlIgnoreCase(l.path[0..l.path_len], full)) {
            l.users += 1;
            hold(p, i);
            return l.table;
        }
    }
    const d = fs.driveByLetter(full[0]) orelse return null;
    const slot = for (&libraries, 0..) |*l, i| {
        if (!l.used) break i;
    } else return error.TooMany;
    const img = loader.loadImage(d, full[2..], loader.library_magic) catch |err| switch (err) {
        error.NotFound, error.PathNotFound => return null,
        else => return err,
    };
    errdefer img.free();
    if (img.header.end < at_init + 8) return error.Invalid;
    const flags = img.field(at_flags);
    const init_at = img.field(at_init);
    if (init_at >= img.header.end) return error.Invalid;
    if (init_at != 0) {
        const init: Init = @ptrFromInt(img.base() + @as(usize, @intCast(init_at)));
        const start = api.start("");
        if (!init(&start)) return error.Invalid;
    }
    const l = &libraries[slot];
    l.* = .{
        .used = true,
        .name_len = name.len,
        .path_len = full.len,
        .shared = flags & flag_shared != 0,
        .image = img,
        .table = @ptrFromInt(img.base() + @as(usize, @intCast(img.header.entry))),
        .users = 1,
    };
    @memcpy(l.name[0..name.len], name);
    @memcpy(l.path[0..full.len], full);
    hold(p, slot);
    return l.table;
}

fn hold(p: *api.Program, i: usize) void {
    p.libraries[p.library_count] = @intCast(i);
    p.library_count += 1;
}

// p ended: its libraries go, a shared one when its last user has
pub fn programEnded(p: *api.Program) void {
    for (p.libraries[0..p.library_count]) |i| {
        const l = &libraries[i];
        l.users -= 1;
        if (l.users == 0) {
            l.image.free();
            l.* = .{};
        }
    }
    p.library_count = 0;
}

fn eql(l: *const Library, name: []const u8) bool {
    return l.used and std.mem.eql(u8, l.name[0..l.name_len], name);
}

// 1-8 letters, digits, '_' or '-', in capitals
fn upper(name: []const u8, buf: *[max_name]u8) Error![]const u8 {
    if (name.len == 0 or name.len > max_name) return error.BadName;
    for (name, 0..) |c, i| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return error.BadName;
        buf[i] = std.ascii.toUpper(c);
    }
    return buf[0..name.len];
}
