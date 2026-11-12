// Unix-style file permissions: each program runs as a user
// (inherited from its starter); root (user 0) may do anything.
//
// FAT has no owners, so the boot drive's are
// made up by place (fatOwner):
// \USERS\<name> that user's 0700, SHADOW.CFG
// root's 0600, \TEMP 0777, the rest root's 0755.
// Other FAT drives are everyone's. LOGIN, SU,
// SUDO and PASSWD in \APPS are setuid root.
//
// No real protection yet: programs share all memory and run
// with ZDOS's privileges.
const std = @import("std");
const tasks = @import("tasks.zig");
const platform = @import("../platform.zig");
const fs = @import("fs.zig");
const api = @import("api.zig");
const abi = @import("abi.zig");

const Error = fs.Error;

pub const max_groups = 16;

pub const Ids = struct {
    real: u32 = 0, // who started it
    uid: u32 = 0, // whose rights it has (effective)
    saved: u32 = 0, // what it may switch back to
    gid: u32 = 0,
    groups: [max_groups]u32 = undefined,
    group_count: u8 = 0,

    fn inGroup(self: *const Ids, gid: u32) bool {
        if (gid == self.gid) return true;
        for (self.groups[0..self.group_count]) |g| {
            if (g == gid) return true;
        }
        return false;
    }
};

const root_ids: Ids = .{};

// The running program's; root while ZDOS starts
pub fn current() *const Ids {
    return if (tasks.world().program) |p| &p.ids else &root_ids;
}

pub fn isRoot() bool {
    return current().uid == 0;
}

pub fn mustBeRoot() Error!void {
    if (!isRoot()) return error.AccessDenied;
}

// The group admins (as apps/zdos/users.zig numbers it): may set
// the clock, turn the computer off or
// restart it, and set global variables
pub const admins_gid = 10;

pub fn isAdmin() bool {
    const me = current();
    return me.uid == 0 or me.inGroup(admins_gid);
}

pub fn mustBeAdmin() Error!void {
    if (!isAdmin()) return error.AccessDenied;
}

pub const read: u3 = 4;
pub const write: u3 = 2;
pub const exec: u3 = 1;

pub const Owner = struct { uid: u32, gid: u32, mode: u32 };

// A FAT entry's owner and mode as the checks make them up (by
// place, the read-only attribute taking
// the write bits), for stat and listings
pub fn madeUp(d: *const fs.Drive, path: []const u8, attrs: u8) Owner {
    var o = fatOwner(d, path);
    if (attrs & platform.Attr.read_only != 0) o.mode &= ~@as(u32, 0o222);
    return o;
}

// fatOwner looks at a path's first two names only:
// deeper paths are theirs
pub const rule_depth = 2;

fn ownerOf(d: *const fs.Drive, path: *const fs.Path) Error!Owner {
    if (fs.permissions(d, path)) |p| {
        return .{ .uid = p.uid, .gid = p.gid, .mode = p.mode };
    } else |err| if (err != error.NotSupported) return err;
    var o = fatOwner(d, path.slice());
    if (path.len > 1) {
        var info: platform.EntryInfo = .{};
        try fs.entryInfo(d, path, &info);
        if (info.attrs & platform.Attr.read_only != 0) o.mode &= ~@as(u32, 0o222);
    }
    return o;
}

// FATOWNER= in SYSTEM.CFG (default true): the made-up owners on
// a FAT system drive. Read once at startup,
// since any program may change the variable.
pub var fat_rules = true;

pub fn configure(get: *const fn (name: []const u8) ?[]const u8) void {
    if (get("FATOWNER")) |v| fat_rules = !std.ascii.eqlIgnoreCase(v, "false");
}

// Where FAT has no owners: by place on the boot drive;
// elsewhere (and inside \TEMP) everyone's, shown as
// the asking user's own (as macOS shows FAT)
fn fatOwner(d: *const fs.Drive, path: []const u8) Owner {
    if (!fat_rules or !isSystemDrive(d)) return asker();
    var parts = std.mem.tokenizeScalar(u8, path, '\\');
    const first = parts.next() orelse return .{ .uid = 0, .gid = 0, .mode = 0o755 };
    if (std.ascii.eqlIgnoreCase(first, "TEMP")) {
        return if (parts.next() != null) asker() else .{ .uid = 0, .gid = 0, .mode = 0o777 };
    }
    // The passwords (\CONF\SHADOW.CFG) and SUDO's time stamps: root's alone
    if (std.ascii.eqlIgnoreCase(first, "CONF")) {
        if (parts.next()) |second| {
            if (std.ascii.eqlIgnoreCase(second, "SHADOW.CFG")) return .{ .uid = 0, .gid = 0, .mode = 0o600 };
            if (std.ascii.eqlIgnoreCase(second, "SUDO")) return .{ .uid = 0, .gid = 0, .mode = 0o700 };
        }
    }
    if (std.ascii.eqlIgnoreCase(first, "USERS")) {
        if (parts.next()) |name| {
            const uid = userId(name) orelse 0;
            return .{ .uid = uid, .gid = uid, .mode = 0o700 };
        }
    }
    return .{ .uid = 0, .gid = 0, .mode = 0o755 };
}

fn asker() Owner {
    const me = current();
    return .{ .uid = me.uid, .gid = me.gid, .mode = 0o777 };
}

fn allowed(o: Owner, want: u3) bool {
    const me = current();
    if (me.uid == 0) return true;
    const shift: u5 = if (me.uid == o.uid) 6 else if (me.inGroup(o.gid)) 3 else 0;
    const bits: u3 = @intCast((o.mode >> shift) & 7);
    return bits & want == want;
}

// Search (x) on each folder above path
fn searchAbove(d: *const fs.Drive, path: *const fs.Path) Error!void {
    var p = path.*;
    while (p.len > 1) {
        p.pop();
        if (!allowed(try ownerOf(d, &p), exec)) return error.AccessDenied;
    }
}

// want (read, write, exec, or'ed) on what path names
pub fn check(d: *const fs.Drive, path: *const fs.Path, want: u3) Error!void {
    if (isRoot()) return;
    try searchAbove(d, path);
    if (!allowed(try ownerOf(d, path), want)) return error.AccessDenied;
}

// Running a program: read and execute permission. Root may read
// anything, but runs only what has an execute bit (any of the
// three), as on Unix; FAT's made-up modes all have them.
pub fn checkRun(d: *const fs.Drive, path: *const fs.Path) Error!void {
    if (isRoot()) {
        const o = try ownerOf(d, path);
        if (o.mode & 0o111 == 0) return error.AccessDenied;
        return;
    }
    try check(d, path, read | exec);
}

// Making or removing the entry path names: write and
// search on its folder
pub fn checkEntry(d: *const fs.Drive, path: *const fs.Path) Error!void {
    if (isRoot() or path.len <= 1) return;
    var folder = path.*;
    folder.pop();
    try check(d, &folder, write | exec);
}

// Changing the mode, times or attributes: the owner or root
pub fn checkOwner(d: *const fs.Drive, path: *const fs.Path) Error!void {
    if (isRoot()) return;
    try searchAbove(d, path);
    if ((try ownerOf(d, path)).uid != current().uid) return error.AccessDenied;
}

// Opening a file: read, or write (an
// existing file) / its folder (a new one)
pub fn checkOpen(d: *const fs.Drive, path: *const fs.Path, mode: platform.OpenMode) Error!void {
    setCreator();
    if (isRoot()) return;
    const exists = (fs.kindOf(d, path) catch null) != null;
    switch (mode) {
        .read => try check(d, path, read),
        .update => if (exists) try check(d, path, read | write) else try checkEntry(d, path),
        .write => if (exists) try check(d, path, write) else try checkEntry(d, path),
    }
}

// New files and folders on ext2 and Minix
// belong to the running program's user
pub fn setCreator() void {
    const me = current();
    platform.new_owner = .{ .uid = me.uid, .gid = me.gid };
}

// A PROGRAM'S IDS WHEN IT STARTS
// As exec on Unix: the starter's ids, the saved user =
// the effective one; a setuid program gets its owner's
// rights (root for the system's own)
pub fn startIds(inherited: *const Ids, d: *const fs.Drive, path: []const u8) Ids {
    var ids = inherited.*;
    if (setuidOwner(d, path)) |owner| ids.uid = owner;
    ids.saved = ids.uid;
    return ids;
}

const setuid_root = [_][]const u8{ "\\APPS\\LOGIN.APP", "\\APPS\\SU.APP", "\\APPS\\SUDO.APP", "\\APPS\\PASSWD.APP" };

// The drive with \APPS and \CONF (the boot drive, or C:)
fn isSystemDrive(d: *const fs.Drive) bool {
    return if (fs.bootDrive()) |b| b == d else false;
}

fn setuidOwner(d: *const fs.Drive, path: []const u8) ?u32 {
    if (isSystemDrive(d)) {
        for (setuid_root) |name| {
            if (std.ascii.eqlIgnoreCase(path, name)) return 0;
        }
    }
    var p: fs.Path = .{};
    if (path.len > fs.max_path) return null;
    p.set(path);
    const perms = fs.permissions(d, &p) catch return null;
    return if (perms.mode & 0o4000 != 0) perms.uid else null;
}

// setresuid with groups: keep_id leaves a value as it is.
// Root may set anything; others only switch among their real,
// effective and saved user, and keep their groups.
pub fn setIds(ids: *Ids, new: *const abi.Ids) Error!void {
    const was_root = ids.uid == 0;
    const choices = [_]u32{ ids.real, ids.uid, ids.saved };
    for ([_]u32{ new.real, new.uid, new.saved }) |v| {
        if (v == abi.keep_id or was_root) continue;
        if (std.mem.indexOfScalar(u32, &choices, v) == null) return error.AccessDenied;
    }
    if (!was_root and (new.gid != abi.keep_id or new.group_count != abi.keep_groups)) return error.AccessDenied;
    if (new.group_count != abi.keep_groups and new.group_count > max_groups) return error.InvalidArgument;
    if (new.real != abi.keep_id) ids.real = new.real;
    if (new.uid != abi.keep_id) ids.uid = new.uid;
    if (new.saved != abi.keep_id) ids.saved = new.saved;
    if (new.gid != abi.keep_id) ids.gid = new.gid;
    if (new.group_count != abi.keep_groups) {
        ids.group_count = @intCast(new.group_count);
        @memcpy(ids.groups[0..new.group_count], new.groups[0..new.group_count]);
    }
}

pub fn getIds(ids: *const Ids, out: *abi.Ids) void {
    out.real = ids.real;
    out.uid = ids.uid;
    out.saved = ids.saved;
    out.gid = ids.gid;
    out.group_count = ids.group_count;
    @memcpy(out.groups[0..ids.group_count], ids.groups[0..ids.group_count]);
}

// May the running program signal a task running as target?
// Root, or the same real or effective user
// as the target's real or saved one (POSIX)
pub fn maySignal(target: *const Ids) bool {
    const me = current();
    if (me.uid == 0) return true;
    return me.real == target.real or me.real == target.saved or me.uid == target.real or me.uid == target.saved;
}

// USER NAMES: \CONF\USERS.CFG ON THE BOOT DRIVE

var users_text: [16 * 1024]u8 = undefined;
var users_len: usize = 0;
var users_size: u64 = std.math.maxInt(u64); // the file's when read, to notice changes
var users_modified: platform.DateTime = platform.no_date;

fn userId(name: []const u8) ?u32 {
    if (std.ascii.eqlIgnoreCase(name, "root")) return 0;
    reloadUsers();
    var lines = std.mem.splitScalar(u8, users_text[0..users_len], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, ':');
        if (!std.ascii.eqlIgnoreCase(fields.next() orelse continue, name)) continue;
        return std.fmt.parseInt(u32, fields.next() orelse return null, 10) catch null;
    }
    return null;
}

fn reloadUsers() void {
    const d = fs.bootDrive() orelse return;
    var p: fs.Path = .{};
    p.set("\\CONF\\USERS.CFG");
    var info: platform.EntryInfo = .{};
    fs.entryInfo(d, &p, &info) catch {
        users_len = 0;
        users_size = std.math.maxInt(u64);
        return;
    };
    if (info.size == users_size and std.meta.eql(info.modified, users_modified)) return;
    users_len = 0;
    const f = fs.openFile(d, p.slice(), .read) catch return;
    defer fs.close(f);
    while (users_len < users_text.len) {
        const n = platform.storage.read(f, users_text[users_len..]) catch break;
        if (n == 0) break;
        users_len += n;
    }
    users_size = info.size;
    users_modified = info.modified;
}
