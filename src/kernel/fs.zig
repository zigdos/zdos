// Drives, paths and file operations on the platform's storage.
// Each volume is a drive with its
// own current directory, as DOS.
const std = @import("std");
const tasks = @import("tasks.zig");
const platform = @import("../platform.zig");
const storage = platform.storage;
const drive_c = @import("drive_c.zig");
const normal = drive_c.normal;
const con = @import("console.zig");
const abi = @import("abi.zig");
const api = @import("api.zig");

pub const max_path = 1024; // bytes of UTF-8 (FAT itself has no limit; Windows-made paths need up to ~780)
const max_drives = 24; // C: .. Z:

// The platform's errors; the kernel also returns PathNotFound,
// InvalidName, AlreadyExists ... from its own checks.
pub const Error = platform.Error;

pub fn errorCode(err: Error) abi.ErrorCode {
    return switch (err) {
        error.NotFound => .not_found,
        error.PathNotFound => .path_not_found,
        error.AlreadyExists => .already_exists,
        error.AccessDenied => .access_denied,
        error.WriteProtected => .write_protected,
        error.DiskFull => .disk_full,
        error.TooManyOpen => .too_many_open,
        error.InvalidHandle => .invalid_handle,
        error.OutOfMemory => .out_of_memory,
        error.InvalidName => .invalid_name,
        error.DeviceError => .device_error,
        error.NotSupported => .not_supported,
        error.NotADirectory => .not_a_directory,
        error.IsADirectory => .is_a_directory,
        error.DirNotEmpty => .dir_not_empty,
        error.InvalidArgument => .invalid_argument,
    };
}

pub fn message(err: Error) []const u8 {
    return errorCode(err).message();
}

pub const FileHandle = storage.FileHandle;
pub const EntryInfo = platform.EntryInfo;

// Absolute path on a drive, always starting with '\' ("\" is the root)
pub const Path = struct {
    buf: [max_path]u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Path) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *Path, s: []const u8) void {
        @memcpy(self.buf[0..s.len], s);
        self.len = s.len;
    }

    pub fn append(self: *Path, name: []const u8) bool {
        const sep: usize = if (self.len > 1) 1 else 0;
        if (self.len + sep + name.len > max_path) return false;
        if (sep == 1) {
            self.buf[self.len] = '\\';
            self.len += 1;
        }
        @memcpy(self.buf[self.len..][0..name.len], name);
        self.len += name.len;
        return true;
    }

    pub fn pop(self: *Path) void {
        var i = self.len;
        while (i > 0 and self.buf[i - 1] != '\\') i -= 1;
        self.len = if (i <= 1) 1 else i - 1;
    }
};

pub const Drive = struct {
    letter: u8, // 0: no drive letter (yet)
    vol: storage.Volume,
    is_boot: bool,
    is_system: bool, // EFI System Partition
    is_hidden: bool,
    is_floppy: bool = false,
    is_unreadable: bool = false, // no driver reads it: listed, never a letter
    is_removable: bool = false, // checked for a change as a floppy is (UEFI USB sticks ...)
    is_missing: bool = false, // the last check found no disk (or the device gone)
    checked: u32 = std.math.maxInt(u32), // request number of the last media check
    cwd: Path, // the current directory of programs that didn't change it (CwdSet)
    disk_gen: u32 = 0, // counts disk changes: programs' current directories from before are void
};

// CURRENT DIRECTORIES, PER PROGRAM
// A program starts with a copy of its starter's.
// Only drives whose directory was changed have an
// entry (shared, refcounted); the others use Drive.cwd.

pub const CwdPath = struct {
    refs: u32 = 1,
    disk_gen: u32, // the drive's disk_gen when set
    path: Path,
};

pub const CwdSet = struct {
    entries: [26]?*CwdPath = [_]?*CwdPath{null} ** 26,

    // A copy of other's (the same entries, counted)
    pub fn inherit(self: *CwdSet, other: *const CwdSet) void {
        for (other.entries, &self.entries) |from, *to| {
            to.* = from;
            if (from) |x| x.refs += 1;
        }
    }

    pub fn release(self: *CwdSet) void {
        for (&self.entries) |*e| {
            if (e.*) |x| drop(x);
            e.* = null;
        }
    }

    fn drop(x: *CwdPath) void {
        x.refs -= 1;
        if (x.refs == 0) platform.memory.free(@ptrCast(@alignCast(x)));
    }

    fn index(d: *const Drive) ?usize {
        const l = std.ascii.toUpper(d.letter);
        return if (l >= 'A' and l <= 'Z') l - 'A' else null;
    }

    fn of(self: *const CwdSet, d: *const Drive) ?*const Path {
        const x = self.entries[index(d) orelse return null] orelse return null;
        return if (x.disk_gen == d.disk_gen) &x.path else null;
    }

    fn set(self: *CwdSet, d: *const Drive, path: *const Path) Error!void {
        const i = index(d) orelse return error.InvalidArgument;
        const mem = platform.memory.alloc(@sizeOf(CwdPath)) orelse return error.OutOfMemory;
        const x: *CwdPath = @ptrCast(@alignCast(mem));
        x.* = .{ .disk_gen = d.disk_gen, .path = path.* };
        if (self.entries[i]) |old| drop(old);
        self.entries[i] = x;
    }
};

// The running program's current directory
// on d (the drive's own if none)
pub fn cwdOf(d: *const Drive) *const Path {
    if (tasks.world().program) |p| {
        if (p.cwds.of(d)) |path| return path;
    }
    return &d.cwd;
}

// Changes the running program's current directory on d
// (without a program: the drive's own)
pub fn setCwd(d: *Drive, path: *const Path) Error!void {
    if (tasks.world().program) |p| return p.cwds.set(d, path);
    d.cwd = path.*;
}

// Floppies are checked for a changed disk once per request
// (each API file call bumps this); hard disks never.
var request: u32 = 0;

pub fn newRequest() void {
    request +%= 1;
    if (request == std.math.maxInt(u32)) request = 0;
}

// Devices plugged in since the last call get their drives (UEFI
// USB sticks); called before a drive is looked up
pub fn pollDevices() void {
    if (storage.newDevices()) volumesChanged();
}

// A changed or missing floppy (or removable device) sends the
// drive back to its root. report: print
// "not ready" if there is no disk.
pub fn checkDrive(d: *const Drive, report: bool) void {
    const m: *Drive = @constCast(d);
    if (!(m.is_floppy or m.is_removable) or m.checked == request) return;
    m.checked = request;
    const media = storage.checkMedia(vol(m));
    m.is_missing = media == .missing;
    switch (media) {
        .same => {},
        .changed => {
            m.cwd.set("\\");
            m.disk_gen +%= 1;
            if (report) reportNotClean(m);
        },
        .missing => {
            m.cwd.set("\\");
            m.disk_gen +%= 1;
            if (report and m.letter != 0) con.printf("Drive {c}: is not ready (no disk?)\n", .{m.letter});
        },
    }
}

// Drives mounted read only until checked: said at
// startup (after the banner) and for a new disk
pub fn reportAllNotClean() void {
    for (drives) |*d| reportNotClean(d);
}

fn reportNotClean(d: *const Drive) void {
    if (comptime !@hasDecl(storage, "notClean")) return;
    if (d.letter == 0 or !storage.notClean(d.vol)) return;
    const info = storage.volumeInfo(d.vol) orelse return;
    const checker = if (std.mem.eql(u8, info.fs_name, "Minix V3")) "CHKMFS" else "CHKEXT2";
    con.printf("Drive {c}: unfinished change: read only. To fix: {s} {c}: -F\n", .{ d.letter, checker, d.letter });
}

fn vol(d: *const Drive) storage.Volume {
    checkDrive(d, true);
    return d.vol;
}

var drive_buf: [max_drives]Drive = undefined;
// Floppies (A:, B:), C:, the other
// letters in order, then those without one
pub var drives: []Drive = drive_buf[0..0];
// Shared by all programs

fn hasApps(v: storage.Volume) bool {
    return drive_c.hasApps(storage, v);
}

// Assigns letters (rules: README.md, "Drives"): A:, B:
// floppies; C: as drive_c.pick; D: on the other normal volumes;
// ESPs and hidden partitions get none,
// nor do partitions no driver reads.
pub fn init() void {
    var vols: [max_drives]storage.Volume = undefined;
    var flags: [max_drives]platform.VolumeFlags = undefined;
    const n = storage.listVolumes(&vols, &flags);

    const c = drive_c.pick(storage, vols[0..n], flags[0..n]);

    var used = [_]bool{false} ** 26;
    var count: usize = 0;
    var floppy_letter: u8 = 'A';
    for (0..n) |i| {
        if (!flags[i].floppy) continue;
        add(vols[i], flags[i], if (floppy_letter <= 'B') floppy_letter else 0, &used, &count);
        floppy_letter += 1;
    }
    if (c) |i| add(vols[i], flags[i], 'C', &used, &count);
    for (0..n) |i| {
        if (i != c and normal(flags[i])) add(vols[i], flags[i], freeLetter('D', &used), &used, &count);
    }
    for (0..n) |i| {
        if (i != c and !normal(flags[i]) and !flags[i].floppy) add(vols[i], flags[i], 0, &used, &count);
    }
    drives = drive_buf[0..count];
    // The system drive: the boot drive if it has a letter
    // and \APPS (A: after booting from a floppy), else C:
    system_drive = for (drives) |*d| {
        if (d.is_boot and d.letter != 0 and hasApps(d.vol)) break d;
    } else driveByLetter('C');
    tasks.world().drive = system_drive orelse for (drives) |*d| {
        if (d.letter != 0) break d;
    } else null;
}

var system_drive: ?*Drive = null;

// Where \CONF and \APPS are (chosen at the drive scan): the
// boot drive if it has a letter and \APPS, else C:
pub fn bootDrive() ?*Drive {
    return system_drive orelse driveByLetter('C');
}

// DISKLET: letters for all drives without one, after the
// highest in use (not for unreadable ones).
// Returns how many got one.
pub fn assignLetters() usize {
    var assigned: usize = 0;
    for (drives) |*d| {
        if (d.letter != 0 or d.is_unreadable) continue;
        const l = nextLetter();
        if (l == 0) break;
        d.letter = l;
        assigned += 1;
    }
    return assigned;
}

// The first unused letter after the
// highest one in use; 0 if none is left
fn nextLetter() u8 {
    var used = [_]bool{false} ** 26;
    var highest: u8 = 'B';
    for (drives) |d| {
        if (d.letter == 0) continue;
        used[d.letter - 'A'] = true;
        highest = @max(highest, d.letter);
    }
    if (highest == 'Z') return 0;
    return freeLetter(highest + 1, &used);
}

// After a partition table changed (FDISK): drives whose volume
// is gone are dropped, new normal volumes (and ones that became
// readable) get the next letter, the others keep theirs.
pub fn volumesChanged() void {
    // No storage call runs on a drive of the table meanwhile (one
    // waiting for its disk has given up the
    // kernel lock, not the storage lock)
    tasks.storageLock();
    defer tasks.storageUnlock();
    var vols: [max_drives]storage.Volume = undefined;
    var flags: [max_drives]platform.VolumeFlags = undefined;
    const n = storage.listVolumes(&vols, &flags);
    const cur: ?storage.Volume = if (tasks.world().drive) |c| c.vol else null;
    const sys: ?storage.Volume = if (system_drive) |d| d.vol else null;

    var count: usize = 0;
    var now_readable = [_]bool{false} ** max_drives;
    for (drive_buf[0..drives.len]) |d| {
        const i = listedAt(vols[0..n], d.vol) orelse continue;
        drive_buf[count] = d;
        drive_buf[count].is_hidden = flags[i].hidden;
        drive_buf[count].is_system = flags[i].system;
        drive_buf[count].is_unreadable = flags[i].unreadable;
        now_readable[count] = d.is_unreadable and !flags[i].unreadable;
        count += 1;
    }
    const kept = count;
    for (vols[0..n], flags[0..n]) |v, f| {
        if (hasDrive(drive_buf[0..kept], v)) continue;
        if (count >= max_drives) break;
        drive_buf[count] = .{ .letter = 0, .vol = v, .is_boot = f.boot, .is_system = f.system, .is_hidden = f.hidden, .is_floppy = f.floppy, .is_unreadable = f.unreadable, .is_removable = f.removable, .cwd = .{} };
        drive_buf[count].cwd.set("\\");
        count += 1;
    }
    drives = drive_buf[0..count];
    for (drive_buf[kept..count]) |*d| {
        if (!d.is_hidden and !d.is_system and !d.is_unreadable) d.letter = nextLetter();
    }
    for (drive_buf[0..kept], now_readable[0..kept]) |*d, readable| {
        if (readable and d.letter == 0 and !d.is_hidden and !d.is_system) d.letter = nextLetter();
    }

    // The list moved: the system drive again by its volume
    system_drive = null;
    if (sys) |v| {
        for (drives) |*d| {
            if (d.vol == v) system_drive = d;
        }
    }
    var keep: ?*Drive = null;
    if (cur) |v| {
        for (drives) |*d| {
            if (d.vol == v) keep = d;
        }
    }
    tasks.world().drive = keep orelse driveByLetter('C') orelse for (drives) |*d| {
        if (d.letter != 0) break d;
    } else null;
}

fn listedAt(vols: []const storage.Volume, v: storage.Volume) ?usize {
    for (vols, 0..) |w, i| {
        if (w == v) return i;
    }
    return null;
}

fn hasDrive(ds: []const Drive, v: storage.Volume) bool {
    for (ds) |d| {
        if (d.vol == v) return true;
    }
    return false;
}

// Wraps around after Z; A and B are never used
fn freeLetter(start: u8, used: *[26]bool) u8 {
    var l = start;
    for (0..24) |_| {
        if (!used[l - 'A']) return l;
        l = if (l == 'Z') 'C' else l + 1;
    }
    return 0; // more volumes than letters: no letter
}

fn add(v: storage.Volume, f: platform.VolumeFlags, letter: u8, used: *[26]bool, count: *usize) void {
    if (count.* >= max_drives) return;
    if (letter != 0) used[letter - 'A'] = true;
    drive_buf[count.*] = .{ .letter = letter, .vol = v, .is_boot = f.boot, .is_system = f.system, .is_hidden = f.hidden, .is_floppy = f.floppy, .is_unreadable = f.unreadable, .is_removable = f.removable, .cwd = .{} };
    drive_buf[count.*].cwd.set("\\");
    count.* += 1;
}

// EJECT: the drive's disk written out and let go, until it is
// plugged in again (metal's USB disks).
// Not the boot or system drive's disk.
pub fn eject(d: *Drive) Error!void {
    if (comptime !@hasDecl(storage, "eject")) return error.NotSupported;
    if (!d.is_removable) return error.NotSupported;
    if (d.is_boot or d == bootDrive()) return error.AccessDenied;
    try storage.eject(d.vol, if (bootDrive()) |b| b.vol else null);
    for (drives) |*x| x.checked = std.math.maxInt(u32); // its drives are missing now
}

pub fn driveByLetter(c: u8) ?*Drive {
    const upper = std.ascii.toUpper(c);
    if (upper < 'A' or upper > 'Z') return null; // hidden drives have letter 0
    for (drives) |*d| {
        if (d.letter == upper) return d;
    }
    return null;
}

pub fn volumeInfo(d: *const Drive) ?platform.VolumeInfo {
    return storage.volumeInfo(vol(d));
}

const LabelError = error{ InvalidCharacters, TooLong };

// DOS label rules: at most 11 characters, none of * ? . , ; : /
// \ | + = < > [ ] ", stored in capitals (returned in buf)
pub fn checkLabel(label: []const u8, buf: *[64]u8) LabelError![]const u8 {
    const view = std.unicode.Utf8View.init(label) catch return error.InvalidCharacters;
    var count: usize = 0;
    var it = view.iterator();
    while (it.nextCodepoint()) |c| {
        count += 1;
        if (c < 0x20 or (c < 0x80 and std.mem.indexOfScalar(u8, "*?.,;:/\\|+=<>[]\"", @intCast(c)) != null)) return error.InvalidCharacters;
    }
    if (count > 11 or label.len > buf.len) return error.TooLong;
    for (label, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    return buf[0..label.len];
}

pub fn setLabel(d: *const Drive, label: []const u8) Error!void {
    return storage.setLabel(vol(d), label);
}

fn isSep(c: u8) bool {
    return c == '\\' or c == '/';
}

// "/C:/DOCS" (or "\C:\DOCS") -> "C:/DOCS", the single-rooted
// form POSIX programs use. A colon can't be in a FAT name, so
// no real folder is hidden.
pub fn dropRootSlash(path: []const u8) []const u8 {
    if (path.len >= 3 and isSep(path[0]) and std.ascii.isAlphabetic(path[1]) and path[2] == ':') return path[1..];
    return path;
}

// A typed path: quotes removed wherever they are (a quote can't
// be in a FAT name), then dropRootSlash.
// The result may point into buf.
pub const TypedBuf = [max_path + 8]u8;
pub fn typedPath(arg: []const u8, buf: *TypedBuf) []const u8 {
    if (std.mem.indexOfScalar(u8, arg, '"') == null) return dropRootSlash(arg);
    var n: usize = 0;
    for (arg) |c| {
        if (c == '"') continue;
        if (n == buf.len) break; // too long anyway: resolving reports it
        buf[n] = c;
        n += 1;
    }
    return dropRootSlash(buf[0..n]);
}

fn stat(d: *const Drive, path: *const Path, out: *EntryInfo) Error!void {
    return storage.stat(vol(d), path.slice(), out);
}

// Resolves a directory path against the drive's current
// directory, with the on-disk spelling of each name. A missing
// step is PathNotFound, a file on the way NotADirectory.
pub fn resolveDir(d: *const Drive, arg: []const u8, out: *Path) Error!void {
    checkDrive(d, true); // before using its current directory
    out.set("\\");
    if (arg.len == 0 or !isSep(arg[0])) out.set(cwdOf(d).slice());

    var it = std.mem.tokenizeAny(u8, arg, "\\/");
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            out.pop();
            continue;
        }
        const parent_len = out.len;
        if (!out.append(comp)) return error.InvalidName; // too long

        var info: EntryInfo = .{};
        stat(d, out, &info) catch |err| return switch (err) {
            error.NotFound => error.PathNotFound,
            else => err,
        };
        if (!info.is_dir) return error.NotADirectory;

        out.len = parent_len;
        _ = out.append(info.name());
    }
}

// Resolves a file path; its folders must
// exist, the file itself is not checked
fn filePath(d: *const Drive, name: []const u8, out: *Path) Error!void {
    var cut = name.len;
    while (cut > 0 and !isSep(name[cut - 1])) cut -= 1;
    const file_name = name[cut..];
    if (file_name.len == 0 or std.mem.eql(u8, file_name, ".") or std.mem.eql(u8, file_name, "..")) return error.InvalidName;
    try resolveDir(d, name[0..cut], out);
    if (!out.append(file_name)) return error.InvalidName; // too long
}

// Resolves any path, existing or not; its folders must exist.
// An existing last name gets the on-disk spelling.
pub fn resolvePath(d: *const Drive, name: []const u8, out: *Path) Error!void {
    var n = name;
    while (n.len > 1 and isSep(n[n.len - 1])) n = n[0 .. n.len - 1];
    var cut = n.len;
    while (cut > 0 and !isSep(n[cut - 1])) cut -= 1;
    const last = n[cut..];
    if (last.len == 0 or std.mem.eql(u8, last, ".") or std.mem.eql(u8, last, "..")) {
        return resolveDir(d, n, out);
    }
    try filePath(d, n, out);
    var info: EntryInfo = .{};
    if (stat(d, out, &info)) {
        out.pop();
        _ = out.append(info.name());
    } else |err| switch (err) {
        error.NotFound => {}, // a new name: kept as typed
        else => return err,
    }
}

pub const Kind = enum { file, dir };

pub fn entryInfo(d: *const Drive, path: *const Path, out: *EntryInfo) Error!void {
    return stat(d, path, out);
}

// platform.Attr bits
pub fn setAttributes(d: *const Drive, path: *const Path, attrs: u8) Error!void {
    return storage.setAttributes(vol(d), path.slice(), attrs);
}

pub fn permissions(d: *const Drive, path: *const Path) Error!platform.Permissions {
    return storage.permissions(vol(d), path.slice());
}

pub fn setMode(d: *const Drive, path: *const Path, mode: u16) Error!void {
    return storage.setMode(vol(d), path.slice(), mode);
}

pub fn setOwner(d: *const Drive, path: *const Path, uid: ?u32, gid: ?u32) Error!void {
    return storage.setOwner(vol(d), path.slice(), uid, gid);
}

// Not for the root
pub fn setModified(d: *const Drive, path: *const Path, t: platform.DateTime) Error!void {
    return storage.setModified(vol(d), path.slice(), t);
}

// null if nothing is there. A disk error stays an
// error, not "nothing": callers would go on and create
// what may well exist.
pub fn kindOf(d: *const Drive, path: *const Path) Error!?Kind {
    var info: EntryInfo = .{};
    stat(d, path, &info) catch |err| return switch (err) {
        error.NotFound => null,
        else => err,
    };
    return if (info.is_dir) .dir else .file;
}

pub fn mustNotExist(d: *const Drive, path: *const Path) Error!void {
    if (try kindOf(d, path) != null) return error.AlreadyExists;
}

// Checked here so every platform returns
// InvalidName, whatever its FAT driver says.
// Minix and ext2 take what Unix does: all but
// 0 and the separators.
fn checkNewName(d: *const Drive, path: *const Path) Error!void {
    const name = baseName(path);
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;
    const unix = storage.unixNames(vol(d));
    for (name) |c| {
        if (c == 0 or c == '/' or c == '\\') return error.InvalidName;
        if (unix) continue;
        if (c < 0x20 or std.mem.indexOfScalar(u8, "\"*:<>?|", c) != null) return error.InvalidName;
    }
}

pub fn baseName(path: *const Path) []const u8 {
    const s = path.slice();
    var i = s.len;
    while (i > 0 and s[i - 1] != '\\') i -= 1;
    return s[i..];
}

// Inside dir or dir itself. Both are resolved paths: their
// existing parts are spelled as on the disk, so letter case is
// compared exactly (on ext2 and Minix,
// Report and report are two names)
pub fn isInside(path: []const u8, dir: []const u8) bool {
    if (path.len < dir.len) return false;
    if (!std.mem.eql(u8, path[0..dir.len], dir)) return false;
    return path.len == dir.len or dir.len == 1 or path[dir.len] == '\\';
}

// DIRECTORIES

const DirIterator = struct {
    handle: storage.DirHandle,
    info: EntryInfo = .{},

    // Valid until the next call
    pub fn next(self: *DirIterator) Error!?*const EntryInfo {
        if (!try storage.readDir(self.handle, &self.info)) return null;
        return &self.info;
    }

    pub fn close(self: *DirIterator) void {
        storage.closeDir(self.handle);
    }
};

pub fn openDir(d: *const Drive, path: *const Path) Error!DirIterator {
    return .{ .handle = try storage.openDir(vol(d), path.slice()) };
}

pub fn makeDir(d: *const Drive, path: *const Path) Error!void {
    try checkNewName(d, path);
    try mustNotExist(d, path);
    return storage.makeDir(vol(d), path.slice());
}

// FILES

// Never opens directories
pub fn openFile(d: *const Drive, name: []const u8, mode: platform.OpenMode) Error!FileHandle {
    var path: Path = .{};
    try filePath(d, name, &path);
    return openPath(d, &path, mode);
}

fn openPath(d: *const Drive, path: *const Path, mode: platform.OpenMode) Error!FileHandle {
    if (try kindOf(d, path)) |kind| {
        if (kind == .dir) return error.IsADirectory;
    } else if (mode == .read) {
        return error.NotFound;
    } else try checkNewName(d, path); // to be created
    return storage.openFile(vol(d), path.slice(), mode);
}

// Ignores a failure to update the entry
// (read-only use, or already reported)
pub fn close(f: FileHandle) void {
    storage.close(f) catch {};
}

// Exactly buf.len bytes; a file that ends before is InvalidArgument
pub fn readAll(f: FileHandle, buf: []u8) Error!void {
    var done: usize = 0;
    while (done < buf.len) {
        const n = try storage.read(f, buf[done..]);
        if (n == 0) return error.InvalidArgument;
        done += n;
    }
}

pub fn deleteFile(d: *const Drive, name: []const u8) Error!void {
    var path: Path = .{};
    try filePath(d, name, &path);
    switch (try kindOf(d, &path) orelse return error.NotFound) {
        .file => {},
        .dir => return error.IsADirectory,
    }
    return storage.delete(vol(d), path.slice());
}

// Entries taken by the hidden attribute (the -a and -a:h switches)
pub const Select = enum {
    visible, // the default
    all, // -a
    hidden, // -a:h

    pub fn takes(self: Select, attrs: u8) bool {
        const hidden = attrs & platform.Attr.hidden != 0;
        return switch (self) {
            .visible => !hidden,
            .all => true,
            .hidden => hidden,
        };
    }
};

pub const DeleteResult = struct {
    deleted: usize = 0,
    failed: bool = false,
    err: ?Error = null, // the first failure

    fn fail(self: *DeleteResult, err: Error) void {
        self.failed = true;
        if (self.err == null) self.err = err;
    }
};

// A file, or a folder with everything in it; stops at the first failure
pub fn deleteTree(d: *const Drive, path: *const Path) Error!void {
    var r: DeleteResult = .{};
    deleteAll(d, path, &r);
    if (r.err) |err| return err;
}

// A file, or a folder with everything in it, hidden entries
// included (the caller already selected what to delete).
// Goes on after a failure; r counts and keeps the first error.
// Iterative (see Stack): entries first, then the folder.
pub fn deleteAll(d: *const Drive, path: *const Path, r: *DeleteResult) void {
    const Frame = struct {
        list: NameList,
        it: NameIterator,
        len: usize, // of cur for this folder
    };
    var stack: Stack(Frame) = .{};
    defer {
        while (stack.top()) |f| {
            f.list.deinit();
            stack.pop();
        }
        stack.deinit();
    }
    var cur: Path = path.*;
    var pending = true; // cur is an entry still to handle
    while (true) {
        if (pending) {
            pending = false;
            if (kindOf(d, &cur)) |kind| {
                if (kind == .dir) {
                    // The names first: the listing changes while entries are deleted
                    if (listMatches(d, &cur, "*", .all)) |list| {
                        stack.push(.{ .list = list, .it = list.iterator(), .len = cur.len }) catch |err| {
                            var l = list;
                            l.deinit();
                            r.fail(err);
                        };
                    } else |err| r.fail(err);
                } else if (kind == .file) {
                    deleteEntry(d, &cur, r);
                } else r.fail(error.NotFound);
            } else |err| r.fail(err);
        }
        const f = stack.top() orelse return;
        if (f.it.next()) |name| {
            cur.len = f.len;
            if (cur.append(name)) {
                pending = true;
            } else r.fail(error.InvalidName);
            continue;
        }
        // The folder's entries are done: now the folder itself
        cur.len = f.len;
        f.list.deinit();
        stack.pop();
        deleteEntry(d, &cur, r);
    }
}

fn deleteEntry(d: *const Drive, path: *const Path, r: *DeleteResult) void {
    if (storage.delete(vol(d), path.slice())) {
        r.deleted += 1;
    } else |err| r.fail(err);
}

// Within one drive; the destination must not exist,
// its folder must. System-attribute entries can't
// be renamed or moved (boot files:
// ZIGDOS.SYS, \EFI\BOOT\BOOT*.EFI); checked here so
// it holds whatever the FAT driver does.
pub fn rename(d: *const Drive, from: *const Path, to: *const Path) Error!void {
    var info: EntryInfo = .{};
    try stat(d, from, &info);
    if (info.attrs & platform.Attr.system != 0) return error.AccessDenied;
    try checkNewName(d, to);

    return storage.rename(vol(d), from.slice(), to.slice());
}

// Replaces the destination; keeps the
// modification time, as DOS's COPY does
fn copyFile(sd: *const Drive, src: *const Path, dd: *const Drive, dst: *const Path) Error!void {
    var info: EntryInfo = .{};
    try stat(sd, src, &info);

    const buf_size = 64 * 1024;
    const buf = platform.memory.alloc(buf_size) orelse return error.OutOfMemory;
    defer platform.memory.free(buf);

    const in = try openPath(sd, src, .read);
    defer close(in);
    const out = try openPath(dd, dst, .write);
    copyData(in, out, buf[0..buf_size]) catch |err| {
        close(out);
        return err;
    };
    try storage.close(out); // the size and date are written now: may fail too
    // After closing, which stamps the current time. A date that
    // can't be set doesn't fail the copy.
    if (info.modified.year != 0) setModified(dd, dst, info.modified) catch {};
    // Its permission bits, as cp keeps them (setuid and
    // the like not): a copied program still runs. From FAT, which
    // has none, a program (.APP) gets 0755. Where the target has
    // none (FAT) nothing is set.
    const mode: ?u16 = if (info.unix) |u| u.mode & 0o777 else if (std.ascii.endsWithIgnoreCase(src.slice(), ".APP")) 0o755 else null;
    if (mode) |m| setMode(dd, dst, m) catch {};
}

fn copyData(in: FileHandle, out: FileHandle, buf: []u8) Error!void {
    while (true) {
        const n = try storage.read(in, buf);
        if (n == 0) return;
        const w = try storage.write(out, buf[0..n]);
        if (w != n) return error.DiskFull;
    }
}

// WILDCARDS

// * and ?, ignoring case
pub fn matches(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star_p: ?usize = null; // position after the last *
    var star_n: usize = 0; // where that * started matching
    while (n < name.len) {
        if (p < pattern.len and pattern[p] == '*') {
            p += 1;
            star_p = p;
            star_n = n;
        } else if (p < pattern.len and (pattern[p] == '?' or std.ascii.toLower(pattern[p]) == std.ascii.toLower(name[n]))) {
            p += 1;
            n += 1;
        } else if (star_p) |sp| {
            // Let the last * take one more character and try again
            p = sp;
            star_n += 1;
            n = star_n;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

// WALKING FOLDER TREES
// Iterative, not recursive: one heap Stack entry per level
// holds that folder's names (collected first, so the folder can
// be changed), so kernel stack use doesn't grow with depth.

pub fn Stack(comptime T: type) type {
    return struct {
        items: []T = &.{},
        len: usize = 0,

        const Self = @This();

        pub fn push(self: *Self, value: T) Error!void {
            if (self.len == self.items.len) {
                const cap = @max(16, self.items.len * 2);
                const mem = platform.memory.alloc(cap * @sizeOf(T)) orelse return error.OutOfMemory;
                const new: [*]T = @ptrCast(@alignCast(mem));
                @memcpy(new[0..self.len], self.items[0..self.len]);
                if (self.items.len > 0) platform.memory.free(@ptrCast(@alignCast(self.items.ptr)));
                self.items = new[0..cap];
            }
            self.items[self.len] = value;
            self.len += 1;
        }

        pub fn top(self: *Self) ?*T {
            return if (self.len == 0) null else &self.items[self.len - 1];
        }

        pub fn pop(self: *Self) void {
            self.len -= 1;
        }

        pub fn deinit(self: *Self) void {
            if (self.items.len > 0) platform.memory.free(@ptrCast(@alignCast(self.items.ptr)));
            self.* = .{};
        }
    };
}

const NameIterator = std.mem.TokenIterator(u8, .scalar);

// Matching names of a directory ("." and ".." excluded),
// collected first so the directory can then be changed safely
const NameList = struct {
    buf: ?[*]align(8) u8 = null,
    cap: usize = 0,
    len: usize = 0,
    count: usize = 0,
    dirs: usize = 0,

    pub fn add(self: *NameList, name: []const u8) bool {
        if (self.len + name.len + 1 > self.cap) {
            const new_cap = @max(4096, (self.len + name.len + 1) * 2);
            const new = platform.memory.alloc(new_cap) orelse return false;
            if (self.buf) |old| {
                @memcpy(new[0..self.len], old[0..self.len]);
                platform.memory.free(old);
            }
            self.buf = new;
            self.cap = new_cap;
        }
        @memcpy(self.buf.?[self.len..][0..name.len], name);
        self.buf.?[self.len + name.len] = 0;
        self.len += name.len + 1;
        self.count += 1;
        return true;
    }

    pub fn iterator(self: *const NameList) NameIterator {
        const data: []const u8 = if (self.buf) |b| b[0..self.len] else "";
        return std.mem.tokenizeScalar(u8, data, 0);
    }

    pub fn deinit(self: *NameList) void {
        if (self.buf) |b| platform.memory.free(b);
        self.* = .{};
    }
};

// Fails if the directory can't be read or memory runs out. sel:
// which entries by the hidden attribute (.all for everything)
pub fn listMatches(d: *const Drive, dir: *const Path, pattern: []const u8, sel: Select) Error!NameList {
    var list: NameList = .{};
    errdefer list.deinit();
    var it = try openDir(d, dir);
    defer it.close();
    while (try it.next()) |e| {
        const name = e.name();
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (!matches(pattern, name)) continue;
        if (!sel.takes(e.attrs)) continue;
        if (!list.add(name)) return error.OutOfMemory;
        if (e.is_dir) list.dirs += 1;
    }
    return list;
}

// CHANGING ONLY THE CAPITALIZATION OF A NAME

// FAT treats "readme.txt" and "README.TXT" as one name, so a
// direct rename fails with AlreadyExists:
// go through a temporary name.
pub fn renameCase(d: *const Drive, path: *const Path, new_name: []const u8) Error!void {
    var final: Path = path.*;
    final.pop();
    var tmp: Path = final;
    if (!final.append(new_name)) return error.InvalidName;
    var tmp_name_buf: [max_path]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&tmp_name_buf, "{s}.zdos-tmp", .{new_name}) catch return error.InvalidName;
    if (!tmp.append(tmp_name)) return error.InvalidName;
    try mustNotExist(d, &tmp);
    try rename(d, path, &tmp);
    rename(d, &tmp, &final) catch |err| {
        rename(d, &tmp, path) catch {}; // put it back
        return err;
    };
}

// "DOCS\Report.txt\" -> "Report.txt"
pub fn lastComponent(arg: []const u8) []const u8 {
    var n = arg;
    while (n.len > 1 and isSep(n[n.len - 1])) n = n[0 .. n.len - 1];
    var i = n.len;
    while (i > 0 and !isSep(n[i - 1])) i -= 1;
    // A drive is one letter: "C:name", not "id:01":
    if (i == 0 and n.len >= 2 and n[1] == ':' and std.ascii.isAlphabetic(n[0])) i = 2;
    return n[i..];
}

// After a folder was deleted or moved: a current directory
// inside it goes to its parent
pub fn leaveRemoved(d: *Drive, path: *const Path) void {
    if (isInside(cwdOf(d).slice(), path.slice())) {
        var up = path.*;
        up.pop();
        setCwd(d, &up) catch {};
    }
    if (isInside(d.cwd.slice(), path.slice())) {
        d.cwd = path.*;
        d.cwd.pop();
    }
}

// A file, or a folder with everything in it, to
// dst, which must not exist; across drives too.
// No questions (COMMAND.APP's COPY has its own).
// On failure what was copied stays.
// Iterative (see Stack).
pub fn copyTree(sd: *const Drive, src: *const Path, dd: *const Drive, dst: *const Path) Error!void {
    const Frame = struct {
        list: NameList,
        it: NameIterator,
        s_len: usize,
        d_len: usize,
    };
    var stack: Stack(Frame) = .{};
    defer {
        while (stack.top()) |f| {
            f.list.deinit();
            stack.pop();
        }
        stack.deinit();
    }
    var s: Path = src.*;
    var t: Path = dst.*;
    var pending = true; // s is an entry still to copy to t
    while (true) {
        if (pending) {
            pending = false;
            const kind = try kindOf(sd, &s) orelse return error.NotFound;
            try mustNotExist(dd, &t);
            if (kind == .file) {
                try copyFile(sd, &s, dd, &t);
            } else {
                try makeDir(dd, &t);
                var list = try listMatches(sd, &s, "*", .all);
                stack.push(.{ .list = list, .it = list.iterator(), .s_len = s.len, .d_len = t.len }) catch |err| {
                    list.deinit();
                    return err;
                };
            }
        }
        const f = stack.top() orelse return;
        if (f.it.next()) |name| {
            s.len = f.s_len;
            t.len = f.d_len;
            if (!s.append(name) or !t.append(name)) return error.InvalidName;
            pending = true;
        } else {
            f.list.deinit();
            stack.pop();
        }
    }
}
