// The file system drivers behind one interface: a partition is
// offered to each in turn; one none reads is kept as
// unreadable, so it is still listed.
// The backend gives the sector I/O.
const std = @import("std");
const platform = @import("../platform.zig");
const fat = @import("fat.zig");
const ext2 = @import("ext2.zig");
const mfs = @import("mfs.zig");
const unreadable = @import("unreadable.zig");

const Error = platform.Error;

// lba counts from what ctx stands for.
pub const ReadFn = *const fn (ctx: *const anyopaque, lba: u64, count: usize, buf: []u8) Error!void;
pub const WriteFn = *const fn (ctx: *const anyopaque, lba: u64, count: usize, data: []const u8) Error!void;
// Null where the backend can't (BIOS).
pub const FlushFn = ?*const fn (ctx: *const anyopaque) Error!void;

// In the order mount tries them. A driver has fat.zig's
// functions and types; its Volume has dev, start,
// total_sectors, serial and generation. unreadable takes any
// partition the others didn't.
const Fs = enum { fat, mfs, ext2, unreadable };

// Each driver is the file-level constant named as its tag.
fn Driver(comptime fs: Fs) type {
    return @field(@This(), @tagName(fs));
}

// Of a Volume, OpenFile or OpenDir field.
fn driverOf(comptime tag: anytype) type {
    return Driver(@field(Fs, @tagName(tag)));
}

pub const Volume = union(Fs) {
    fat: fat.Volume,
    mfs: mfs.Volume,
    ext2: ext2.Volume,
    unreadable: unreadable.Volume,
};

pub const OpenFile = union(enum) {
    free,
    fat: fat.File,
    mfs: mfs.File,
    ext2: ext2.File,
    unreadable: unreadable.File,
};

pub const OpenDir = union(enum) {
    free,
    fat: fat.Dir,
    mfs: mfs.Dir,
    ext2: ext2.Dir,
    unreadable: unreadable.Dir,
};

pub fn mount(ctx: *const anyopaque, read_fn: ReadFn, write_fn: WriteFn, flush_fn: FlushFn, start: u64, sectors: u64) ?Volume {
    inline for (comptime std.enums.values(Fs)) |fs| {
        const D = Driver(fs);
        var dev: D.Device = .{ .ctx = ctx, .read = read_fn, .write = write_fn };
        if (@hasField(D.Device, "flush")) dev.flush = flush_fn;
        if (D.mount(dev, start, sectors)) |v| return @unionInit(Volume, @tagName(fs), v);
    }
    return null;
}

// No driver reads it and no signature says what it holds: a
// blank disk, not listed without a partition table.
pub fn isBlank(v: *const Volume) bool {
    return switch (v.*) {
        .unreadable => |*x| x.fs_name.len == 0,
        else => false,
    };
}

// Before shutdown or restart (ext2: writes
// flushed, the volume marked clean).
pub fn sync(v: *Volume) void {
    switch (v.*) {
        inline else => |*x, tag| if (@hasDecl(driverOf(tag), "sync")) driverOf(tag).sync(x) catch {},
    }
}

pub fn forget(ctx: *const anyopaque) void {
    inline for (comptime std.enums.values(Fs)) |fs| Driver(fs).forget(ctx);
}

pub fn ctxOf(v: *const Volume) *const anyopaque {
    return switch (v.*) {
        inline else => |*x| x.dev.ctx,
    };
}

pub fn startOf(v: *const Volume) u64 {
    return switch (v.*) {
        inline else => |*x| x.start,
    };
}

pub fn sectorsOf(v: *const Volume) u64 {
    return switch (v.*) {
        inline else => |*x| x.total_sectors,
    };
}

pub fn generationOf(v: *Volume) *u32 {
    return switch (v.*) {
        inline else => |*x| &x.generation,
    };
}

// Minix and ext2 names take all but 0 and '/'
// (as on Unix); FAT's take far less
pub fn unixNames(v: *const Volume) bool {
    return v.* == .mfs or v.* == .ext2;
}

// Read only until checked: not cleanly unmounted
// (drivers with a clean flag: ext2, Minix)
pub fn notClean(v: *const Volume) bool {
    return switch (v.*) {
        inline else => |*x, tag| if (@hasDecl(driverOf(tag), "notClean")) driverOf(tag).notClean(x) else false,
    };
}

// An unreadable volume has one too:
// its size and what it seems to be.
pub fn volumeInfo(v: *Volume) platform.VolumeInfo {
    switch (v.*) {
        inline else => |*x, tag| {
            const D = driverOf(tag);
            var info: platform.VolumeInfo = .{ .size = D.sizeBytes(x), .free = D.freeBytes(x), .serial = x.serial, .fs_name = D.fsName(x) };
            info.label_len = D.label(x, &info.label_buf);
            if (@hasDecl(D, "blockBytes")) info.block_size = D.blockBytes(x);
            return info;
        },
    }
}

pub fn stat(v: *Volume, path: []const u8, out: *platform.EntryInfo) Error!void {
    return switch (v.*) {
        inline else => |*x, tag| driverOf(tag).stat(x, path, out),
    };
}

var files = [_]OpenFile{.free} ** 128;
var dirs = [_]OpenDir{.free} ** 64;

// EJECT waits for it to be closed.
pub fn openForWriting(v: *const Volume) bool {
    const at = switch (v.*) {
        inline else => |*x| @intFromPtr(x),
    };
    for (&files) |*f| {
        switch (f.*) {
            .free => {},
            inline else => |*x| if (comptime @hasField(@TypeOf(x.*), "writable")) {
                if (x.in_use and x.writable and @intFromPtr(x.v) == at) return true;
            },
        }
    }
    return false;
}

// A driver's close only clears its in_use.
fn fileFree(f: *const OpenFile) bool {
    return switch (f.*) {
        .free => true,
        inline else => |*x| !x.in_use,
    };
}

fn dirFree(d: *const OpenDir) bool {
    return switch (d.*) {
        .free => true,
        inline else => |*x| !x.in_use,
    };
}

pub fn openFile(v: *Volume, path: []const u8, mode: platform.OpenMode) Error!*OpenFile {
    for (&files) |*f| {
        if (!fileFree(f)) continue;
        switch (v.*) {
            inline else => |*x, tag| {
                f.* = @unionInit(OpenFile, @tagName(tag), .{});
                driverOf(tag).openFile(x, path, mode, &@field(f.*, @tagName(tag))) catch |err| {
                    f.* = .free;
                    return err;
                };
            },
        }
        return f;
    }
    return error.TooManyOpen;
}

pub fn read(f: *OpenFile, buf: []u8) Error!usize {
    return switch (f.*) {
        .free => error.InvalidHandle,
        inline else => |*x, tag| driverOf(tag).read(x, buf),
    };
}

pub fn write(f: *OpenFile, data: []const u8) Error!usize {
    return switch (f.*) {
        .free => error.InvalidHandle,
        inline else => |*x, tag| driverOf(tag).write(x, data),
    };
}

pub fn seek(f: *OpenFile, pos: u64) Error!void {
    return switch (f.*) {
        .free => error.InvalidHandle,
        inline else => |*x, tag| driverOf(tag).seek(x, pos),
    };
}

pub fn setSize(f: *OpenFile, new_size: u64) Error!void {
    return switch (f.*) {
        .free => error.InvalidHandle,
        inline else => |*x, tag| driverOf(tag).setSize(x, new_size),
    };
}

pub fn fstat(f: *OpenFile, out: *platform.EntryInfo) Error!void {
    return switch (f.*) {
        .free => error.InvalidHandle,
        inline else => |*x, tag| driverOf(tag).fstat(x, out),
    };
}

// The key of kernel/locks.zig, the same for every
// handle of one file: the volume and the inode
// (on FAT the entry's folder and slot)
pub const FileKey = struct { volume: usize, id: u64 };

pub fn fileKey(f: *const OpenFile) FileKey {
    return switch (f.*) {
        .fat => |*x| .{ .volume = @intFromPtr(x.v), .id = @as(u64, x.dir) << 32 | x.slot },
        .mfs => |*x| .{ .volume = @intFromPtr(x.v), .id = x.ino },
        .ext2 => |*x| .{ .volume = @intFromPtr(x.v), .id = x.ino },
        .free, .unreadable => .{ .volume = @intFromPtr(f), .id = 0 },
    };
}

// Through the open file (files->fset_time).
pub fn setModifiedOpen(f: *OpenFile, when: platform.DateTime) Error!void {
    return switch (f.*) {
        .free => error.InvalidHandle,
        inline else => |*x, tag| if (@hasDecl(driverOf(tag), "setModifiedOpen")) driverOf(tag).setModifiedOpen(x, when) else error.NotSupported,
    };
}

pub fn size(f: *OpenFile) Error!u64 {
    return switch (f.*) {
        .free => error.InvalidHandle,
        inline else => |*x| x.size,
    };
}

pub fn close(f: *OpenFile) Error!void {
    return switch (f.*) {
        .free => error.InvalidHandle,
        inline else => |*x, tag| driverOf(tag).close(x),
    };
}

pub fn commit(f: *OpenFile) Error!void {
    return switch (f.*) {
        .free => error.InvalidHandle,
        inline else => |*x, tag| driverOf(tag).commit(x),
    };
}

pub fn openDir(v: *Volume, path: []const u8) Error!*OpenDir {
    for (&dirs) |*d| {
        if (!dirFree(d)) continue;
        switch (v.*) {
            inline else => |*x, tag| {
                d.* = @unionInit(OpenDir, @tagName(tag), .{});
                driverOf(tag).openDir(x, path, &@field(d.*, @tagName(tag))) catch |err| {
                    d.* = .free;
                    return err;
                };
            },
        }
        return d;
    }
    return error.TooManyOpen;
}

pub fn readDir(d: *OpenDir, out: *platform.EntryInfo) Error!bool {
    return switch (d.*) {
        .free => error.InvalidHandle,
        inline else => |*x, tag| driverOf(tag).readDir(x, out),
    };
}

pub fn closeDir(d: *OpenDir) void {
    d.* = .free;
}

pub fn makeDir(v: *Volume, path: []const u8) Error!void {
    return switch (v.*) {
        inline else => |*x, tag| driverOf(tag).makeDir(x, path),
    };
}

pub fn delete(v: *Volume, path: []const u8) Error!void {
    return switch (v.*) {
        inline else => |*x, tag| driverOf(tag).delete(x, path),
    };
}

pub fn rename(v: *Volume, from: []const u8, to: []const u8) Error!void {
    return switch (v.*) {
        inline else => |*x, tag| driverOf(tag).rename(x, from, to),
    };
}

pub fn setAttributes(v: *Volume, path: []const u8, attrs: u8) Error!void {
    return switch (v.*) {
        inline else => |*x, tag| driverOf(tag).setAttributes(x, path, attrs),
    };
}

pub fn setModified(v: *Volume, path: []const u8, when: platform.DateTime) Error!void {
    return switch (v.*) {
        inline else => |*x, tag| driverOf(tag).setModified(x, path, when),
    };
}

pub fn setLabel(v: *Volume, label: []const u8) Error!void {
    return switch (v.*) {
        inline else => |*x, tag| driverOf(tag).setLabel(x, label),
    };
}

// ext2's; NotSupported from the others (the kernel then makes
// them up from the read-only attribute).
pub fn permissions(v: *Volume, path: []const u8) Error!platform.Permissions {
    return switch (v.*) {
        inline else => |*x, tag| if (@hasDecl(driverOf(tag), "permissions")) driverOf(tag).permissions(x, path) else error.NotSupported,
    };
}

// 0o7777; the type stays.
pub fn setMode(v: *Volume, path: []const u8, mode: u16) Error!void {
    return switch (v.*) {
        inline else => |*x, tag| if (@hasDecl(driverOf(tag), "setMode")) driverOf(tag).setMode(x, path, mode) else error.NotSupported,
    };
}

// Null keeps the owner or the group.
pub fn setOwner(v: *Volume, path: []const u8, uid: ?u32, gid: ?u32) Error!void {
    return switch (v.*) {
        inline else => |*x, tag| if (@hasDecl(driverOf(tag), "setOwner")) driverOf(tag).setOwner(x, path, uid, gid) else error.NotSupported,
    };
}
