// A partition no driver reads (NTFS, ext4 ...): tried last, so
// it is still listed with what its signature says. No letter;
// every file operation fails.
const std = @import("std");
const platform = @import("../platform.zig");

const Error = platform.Error;

// As fat.Device; lba counts from the start of the disk.
pub const Device = struct {
    ctx: *const anyopaque,
    read: *const fn (ctx: *const anyopaque, lba: u64, count: usize, buf: []u8) Error!void,
    write: *const fn (ctx: *const anyopaque, lba: u64, count: usize, data: []const u8) Error!void,
};

pub const Volume = struct {
    dev: Device,
    start: u64,
    total_sectors: u64,
    serial: ?u32 = null,
    generation: u32 = 0,
    fs_name: []const u8, // as platform.VolumeInfo has it; "" if unknown
    label: [16]u8 = .{0} ** 16,
};

pub const File = struct {
    in_use: bool = false,
    size: u64 = 0,
};

pub const Dir = struct {
    in_use: bool = false,
};

// Never fails for a partition with sectors:
// its contents are guessed.
pub fn mount(dev: Device, start: u64, sectors: u64) ?Volume {
    if (sectors == 0) return null;
    var v: Volume = .{ .dev = dev, .start = start, .total_sectors = sectors, .fs_name = "" };
    var b: [1024]u8 = undefined;
    // The boot sector:
    // NTFS and exFAT name themselves after the jump:
    if (dev.read(dev.ctx, start, 1, b[0..512])) {
        if (std.mem.eql(u8, b[3..11], "NTFS    ")) v.fs_name = "NTFS";
        if (std.mem.eql(u8, b[3..11], "EXFAT   ")) v.fs_name = "exFAT";
    } else |_| {}
    if (v.fs_name.len > 0) return v;
    // ext2/3/4: the superblock at byte 1024. ext2.zig refused it:
    // ext4, or an ext3 whose journal needs replaying:
    if (sectors >= 4 and if (dev.read(dev.ctx, start + 2, 2, &b)) true else |_| false) {
        if (std.mem.readInt(u16, b[56..58], .little) == 0xEF53) {
            const compat = std.mem.readInt(u32, b[92..96], .little);
            const incompat = std.mem.readInt(u32, b[96..100], .little);
            v.fs_name = if (incompat & 0x40 != 0) "ext4" else if (compat & 0x4 != 0) "ext3" else "ext2"; // extents, journal
            v.label = b[120..136].*;
            return v;
        }
    }
    // ZFS: an uberblock (0x00bab10c) in label 0's ring at 128 KB;
    // slots are 1 KB or larger, so every 1 KB step is looked at:
    if (sectors >= 512) {
        var slot: u64 = 0;
        while (slot < 128) : (slot += 1) {
            dev.read(dev.ctx, start + 256 + slot * 2, 1, b[0..512]) catch break;
            if (std.mem.readInt(u64, b[0..8], .little) == 0x00bab10c) {
                v.fs_name = "ZFS";
                break;
            }
        }
    }
    return v;
}

pub fn forget(dev_ctx: *const anyopaque) void {
    _ = dev_ctx;
}

pub fn fsName(v: *const Volume) []const u8 {
    return v.fs_name;
}

pub fn label(v: *Volume, out: []u8) usize {
    const n = @min(std.mem.indexOfScalar(u8, &v.label, 0) orelse v.label.len, out.len);
    @memcpy(out[0..n], v.label[0..n]);
    return n;
}

pub fn sizeBytes(v: *const Volume) u64 {
    return v.total_sectors * 512;
}

pub fn freeBytes(v: *Volume) u64 {
    _ = v;
    return 0;
}

// Storage refuses them first (the volume is never ready); these
// only complete the interface.

pub fn stat(v: *Volume, path: []const u8, out: *platform.EntryInfo) Error!void {
    _ = .{ v, path, out };
    return error.DeviceError;
}

pub fn fstat(f: *File, out: *platform.EntryInfo) Error!void {
    _ = .{ f, out };
    return error.InvalidHandle;
}

pub fn openFile(v: *Volume, path: []const u8, mode: platform.OpenMode, f: *File) Error!void {
    _ = .{ v, path, mode, f };
    return error.DeviceError;
}

pub fn read(f: *File, buf: []u8) Error!usize {
    _ = .{ f, buf };
    return error.InvalidHandle;
}

pub fn write(f: *File, data: []const u8) Error!usize {
    _ = .{ f, data };
    return error.InvalidHandle;
}

pub fn seek(f: *File, pos: u64) Error!void {
    _ = .{ f, pos };
    return error.InvalidHandle;
}

pub fn setSize(f: *File, new_size: u64) Error!void {
    _ = .{ f, new_size };
    return error.InvalidHandle;
}

pub fn commit(f: *File) Error!void {
    _ = f;
    return error.InvalidHandle;
}

pub fn close(f: *File) Error!void {
    f.in_use = false;
}

pub fn openDir(v: *Volume, path: []const u8, d: *Dir) Error!void {
    _ = .{ v, path, d };
    return error.DeviceError;
}

pub fn readDir(d: *Dir, out: *platform.EntryInfo) Error!bool {
    _ = .{ d, out };
    return error.InvalidHandle;
}

pub fn makeDir(v: *Volume, path: []const u8) Error!void {
    _ = .{ v, path };
    return error.DeviceError;
}

pub fn delete(v: *Volume, path: []const u8) Error!void {
    _ = .{ v, path };
    return error.DeviceError;
}

pub fn rename(v: *Volume, from: []const u8, to: []const u8) Error!void {
    _ = .{ v, from, to };
    return error.DeviceError;
}

pub fn setAttributes(v: *Volume, path: []const u8, attrs: u8) Error!void {
    _ = .{ v, path, attrs };
    return error.DeviceError;
}

pub fn setModified(v: *Volume, path: []const u8, when: platform.DateTime) Error!void {
    _ = .{ v, path, when };
    return error.DeviceError;
}

pub fn setLabel(v: *Volume, new_label: []const u8) Error!void {
    _ = .{ v, new_label };
    return error.DeviceError;
}
