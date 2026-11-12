// Raw disk access (platform.zig: disk) through Block I/O, whole
// disks only (partitions have their own handles). The list is
// made once, so indexes stay stable.
const std = @import("std");
const uefi = std.os.uefi;
const BlockIo = uefi.protocol.BlockIo;
const platform = @import("../../platform.zig");
const storage = @import("storage.zig");

const max_disks = 32;
var handles: [max_disks]uefi.Handle = undefined;
var disk_count: usize = 0;
var listed = false;

fn blockIo(h: uefi.Handle) ?*BlockIo {
    var ptr: ?*anyopaque = null;
    if (uefi.system_table.boot_services.?.handleProtocol(h, &BlockIo.guid, &ptr) != .success) return null;
    return @ptrCast(@alignCast(ptr.?));
}

fn list() void {
    if (listed) return;
    listed = true;
    const bs = uefi.system_table.boot_services.?;
    var n: usize = 0;
    var all: [*]uefi.Handle = undefined;
    if (bs.locateHandleBuffer(.by_protocol, &BlockIo.guid, null, &n, &all) != .success) return;
    defer _ = bs.freePool(@ptrCast(all));
    for (all[0..n]) |h| {
        const bio = blockIo(h) orelse continue;
        if (bio.media.logical_partition) continue;
        if (disk_count == max_disks) break;
        handles[disk_count] = h;
        disk_count += 1;
    }
}

fn open(index: usize) platform.Error!*BlockIo {
    list();
    if (index >= disk_count) return error.InvalidArgument;
    return blockIo(handles[index]) orelse error.DeviceError;
}

pub fn count() usize {
    list();
    return disk_count;
}

pub fn info(index: usize) ?platform.DiskInfo {
    list();
    if (index >= disk_count) return null;
    const bio = blockIo(handles[index]) orelse return null;
    const m = bio.media;
    return .{
        .sectors = if (m.media_present) m.last_block + 1 else 0,
        .sector_size = m.block_size,
        .removable = m.removable_media,
        .read_only = m.read_only,
    };
}

pub fn read(index: usize, lba: u64, buf: []u8) platform.Error!void {
    const bio = try open(index);
    const m = bio.media;
    if (!m.media_present or buf.len == 0 or buf.len % m.block_size != 0) return error.InvalidArgument;
    if (lba + buf.len / m.block_size > m.last_block + 1) return error.DeviceError;
    try storage.blocksRead(bio, lba, buf);
}

pub fn write(index: usize, lba: u64, data: []const u8) platform.Error!void {
    const bio = try open(index);
    const m = bio.media;
    if (m.read_only) return error.WriteProtected;
    if (!m.media_present or data.len == 0 or data.len % m.block_size != 0) return error.InvalidArgument;
    if (lba + data.len / m.block_size > m.last_block + 1) return error.DeviceError;
    try storage.blocksWrite(bio, lba, data);
    _ = bio.flushBlocks();
}

// WHERE A VOLUME IS (storage.location)

// A handle's device path as bytes, without its end node
fn devicePath(h: uefi.Handle) ?[]const u8 {
    var ptr: ?*anyopaque = null;
    if (uefi.system_table.boot_services.?.handleProtocol(h, &uefi.protocol.DevicePath.guid, &ptr) != .success) return null;
    const p: [*]const u8 = @ptrCast(ptr.?);
    var at: usize = 0;
    while (at < 4096) {
        if (p[at] == 0x7F and p[at + 1] == 0xFF) return p[0..at]; // the end node
        const len = std.mem.readInt(u16, p[at + 2 ..][0..2], .little);
        if (len < 4) return null;
        at += len;
    }
    return null;
}

// The disk index and first sector of a volume's handle: the
// whole disk, or the disk whose device path is the longest
// prefix of the partition's, plus the Hard Drive node (media
// type 4, subtype 1: start at byte 8)
pub fn locate(h: uefi.Handle) ?struct { disk: u32, start: u64 } {
    list();
    for (handles[0..disk_count], 0..) |d, i| {
        if (d == h) return .{ .disk = @intCast(i), .start = 0 };
    }
    const path = devicePath(h) orelse return null;
    var best: ?u32 = null;
    var best_len: usize = 0;
    for (handles[0..disk_count], 0..) |d, i| {
        const dp = devicePath(d) orelse continue;
        if (dp.len < path.len and dp.len >= best_len and std.mem.eql(u8, path[0..dp.len], dp)) {
            best = @intCast(i);
            best_len = dp.len;
        }
    }
    const disk = best orelse return null;
    // The last Hard Drive node after the disk's own path
    var start: ?u64 = null;
    var at = best_len;
    while (at + 4 <= path.len) {
        const len = std.mem.readInt(u16, path[at + 2 ..][0..2], .little);
        if (len < 4 or at + len > path.len) return null;
        if (path[at] == 4 and path[at + 1] == 1 and len >= 24) start = std.mem.readInt(u64, path[at + 8 ..][0..8], .little);
        at += len;
    }
    return .{ .disk = disk, .start = start orelse return null };
}
