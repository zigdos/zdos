// Volumes, files and directories. Partitions the firmware's
// FAT driver mounted go through Simple File System;
// the others (ext2 ...) through their Block I/O to ZDOS's own
// file system drivers (drivers/filesystems.zig).
const std = @import("std");
const uefi = std.os.uefi;
const File = uefi.protocol.File;
const SimpleFileSystem = uefi.protocol.SimpleFileSystem;
const BlockIo = uefi.protocol.BlockIo;
const platform = @import("../../platform.zig");
const fsd = @import("../../drivers/filesystems.zig");
const partitions = @import("../../drivers/partitions.zig");
const text = @import("text.zig");
const rawdisk = @import("rawdisk.zig");

// A volume: the root directory of one the firmware mounted, or
// a partition one of ZDOS's drivers took
const Vol = union(enum) {
    firmware: *const File,
    driver: fsd.Volume,
};

pub const Volume = *Vol;
// A firmware handle with its volume's slot and
// that slot's epoch: refused once the device is
// gone, or the slot holds another
const FwHandle = struct {
    file: *const File,
    vol: u8,
    epoch: u32,
    key: u64 = 0, // the path (fileKey): no inode here
};
pub const FileHandle = union(enum) {
    firmware: FwHandle,
    driver: *fsd.OpenFile,
};
pub const DirHandle = union(enum) {
    firmware: FwHandle,
    driver: *fsd.OpenDir,
};

// Longest path in UCS-2 characters (a
// 1024-byte UTF-8 path has at most 1024)
const max_path = 1024;

// Every volume, found once (the kernel compares volumes by
// address), with its partition handle
// (boot sector, Block I/O, boot entries)
const max_volumes = 32;
var volumes: [max_volumes]Vol = undefined;
var handle_of: [max_volumes]uefi.Handle = undefined;
var flags_of: [max_volumes]platform.VolumeFlags = undefined;
var volume_count: usize = 0;
var listed = false;
// A removable device that was pulled out: the firmware freed
// its handles and protocols, so nothing of
// it is used any more (checkMedia sets it)
var gone = [_]bool{false} ** max_volumes;
// A firmware volume's Simple File System, to tell the same
// device from a new one at a reused handle
var sfs_of: [max_volumes]?*const SimpleFileSystem = [_]?*const SimpleFileSystem{null} ** max_volumes;
// Raised when a slot gets another device or is mounted again:
// handles of the one before become invalid
// (a driver volume's generation is its epoch)
var epoch = [_]u32{0} ** max_volumes;
// A gone slot that took a newly plugged device:
// checkMedia says .changed once
var replaced = [_]bool{false} ** max_volumes;
// New Block I/O handles (a device plugged in) signal this event
var arrival: ?uefi.Event = null;
var arrival_key: *anyopaque = undefined;

fn alive(vol: Volume) Error!void {
    if (gone[indexOf(vol)]) return error.DeviceError;
}

fn aliveHandle(h: FwHandle) Error!*const File {
    if (!handleValid(h)) return error.InvalidHandle;
    return h.file;
}

fn handleValid(h: FwHandle) bool {
    return !gone[h.vol] and epoch[h.vol] == h.epoch;
}

// A driver volume's sector I/O: its partition's Block I/O, with
// the media it was mounted on (another disk in the drive fails
// instead of being written)
const Part = struct {
    bio: *BlockIo,
    media_id: u32,
    unflushed: bool = false, // written since the last flush
};
var parts: [max_volumes]Part = undefined;

const FwPath = [max_path + 1]u16;

fn fwPath(path: []const u8, buf: *FwPath) ?[*:0]const u16 {
    return text.utf8ToUcs2Z(path, buf);
}

// "Fast boot" firmware may connect only the boot device:
// connect every controller so all disks and partitions show up.
pub fn init() void {
    const bs = uefi.system_table.boot_services.?;
    var count: usize = 0;
    var handles: [*]uefi.Handle = undefined;
    if (bs.locateHandleBuffer(.all_handles, null, null, &count, &handles) != .success) return;
    defer _ = bs.freePool(@ptrCast(handles));
    for (handles[0..count]) |h| {
        _ = bs.connectController(h, null, null, true);
    }
    // Devices plugged in later (newDevices)
    var ev: uefi.Event = undefined;
    if (bs.createEvent(0, 0, null, null, &ev) != .success) return;
    if (bs.registerProtocolNotify(&BlockIo.guid, ev, &arrival_key) == .success) arrival = ev else _ = bs.closeEvent(ev);
}

fn indexOf(vol: Volume) usize {
    return (@intFromPtr(vol) - @intFromPtr(&volumes[0])) / @sizeOf(Vol);
}

// The volume's partition handle, for boot entries (SYS)
pub fn deviceHandle(vol: Volume) ?uefi.Handle {
    return handle_of[indexOf(vol)];
}

// The partition's Block I/O: sector 0 is the partition's first
fn volumeBlockIo(vol: Volume) platform.Error!*uefi.protocol.BlockIo {
    try alive(vol); // its handle may belong to another device now
    const h = deviceHandle(vol) orelse return error.NotSupported;
    var ptr: ?*anyopaque = null;
    if (uefi.system_table.boot_services.?.handleProtocol(h, &uefi.protocol.BlockIo.guid, &ptr) != .success) return error.NotSupported;
    return @ptrCast(@alignCast(ptr.?));
}

pub fn volumeSectors(vol: Volume) ?u64 {
    const bio = volumeBlockIo(vol) catch return null;
    if (bio.media.block_size != 512) return null;
    return bio.media.last_block + 1;
}

fn volumeCheck(m: *uefi.protocol.BlockIo.BlockMedia, lba: u64, bytes: usize) platform.Error!usize {
    if (!m.media_present or m.block_size != 512) return error.DeviceError;
    if (bytes == 0 or bytes % 512 != 0) return error.InvalidArgument;
    const count = bytes / 512;
    if (lba + @as(u64, count) > m.last_block + 1) return error.DeviceError;
    return count;
}

pub fn volumeRead(vol: Volume, lba: u64, buf: []u8) platform.Error!void {
    const bio = try volumeBlockIo(vol);
    _ = try volumeCheck(bio.media, lba, buf.len);
    try blocksRead(bio, lba, buf);
}

pub fn volumeWrite(vol: Volume, lba: u64, data: []const u8) platform.Error!void {
    const bio = try volumeBlockIo(vol);
    if (bio.media.read_only) return error.WriteProtected;
    _ = try volumeCheck(bio.media, lba, data.len);
    try blocksWrite(bio, lba, data);
    _ = bio.flushBlocks();
}

// After raw writes (FORMAT): a driver volume is mounted again,
// by whichever driver takes it now. The firmware's FAT driver
// caches on its own; only a restart helps there.
pub fn volumeChanged(vol: Volume) void {
    switch (vol.*) {
        .firmware => {},
        .driver => remount(indexOf(vol)),
    }
}

// The same for every driver volume (a
// disk's partitions aren't told apart here)
pub fn diskChanged(index: usize) void {
    _ = index;
    for (volumes[0..volume_count], 0..) |*v, i| {
        if (v.* == .driver) remount(i);
    }
    // A volume made where none was (MKE2FS on a blank disk):
    _ = addVolumes();
}

// Before shutting down or restarting: sync drivers, flush dirty
// driver volumes and the firmware's FAT volumes.
pub fn syncAll() void {
    for (volumes[0..volume_count], 0..) |*v, i| {
        if (gone[i]) continue;
        switch (v.*) {
            .firmware => |root| _ = root.flush(),
            .driver => |*d| {
                fsd.sync(d);
                if (parts[i].unflushed) partFlush(&parts[i]) catch {};
            },
        }
    }
}

fn remount(i: usize) void {
    if (gone[i]) return;
    const p = &parts[i];
    fsd.forget(p);
    epoch[i] +%= 1; // older handles become invalid
    p.media_id = p.bio.media.media_id;
    if (fsd.mount(p, partRead, partWrite, partFlush, 0, p.bio.media.last_block + 1)) |v| volumes[i] = .{ .driver = v };
    fsd.generationOf(&volumes[i].driver).* = epoch[i];
    flags_of[i].unreadable = volumes[i].driver == .unreadable;
}

// The volume's disk (platform.disk's index), first sector and
// length, from its device path; 512-byte sectors only
pub fn location(vol: Volume) ?platform.Location {
    const bio = volumeBlockIo(vol) catch return null;
    if (bio.media.block_size != 512) return null;
    const where = rawdisk.locate(handle_of[indexOf(vol)]) orelse return null;
    const disk_info = rawdisk.info(where.disk) orelse return null;
    if (disk_info.sector_size != 512) return null;
    return .{ .disk = where.disk, .start = where.start, .sectors = bio.media.last_block + 1 };
}

pub fn listVolumes(out: []Volume, flags: []platform.VolumeFlags) usize {
    if (!listed) findVolumes();
    listed = true;
    const n = @min(volume_count, out.len, flags.len);
    for (0..n) |i| {
        out[i] = &volumes[i];
        flags[i] = flags_of[i];
    }
    return n;
}

// Drops the drivers' cached blocks of every volume (metal,
// after reading SYSTEM.CFG through this
// module, before mounting the disks itself)
pub fn forgetAll() void {
    for (volumes[0..volume_count], 0..) |v, i| {
        if (v == .driver) fsd.forget(&parts[i]);
    }
}

fn findVolumes() void {
    _ = addVolumes();
}

// Volumes for handles not in the table yet: the firmware's FAT
// volumes, then unmounted 512-byte-sector partitions offered to
// ZDOS's drivers. A new one reuses a gone device's slot, so a
// re-plugged stick keeps its letter. True if one was added.
fn addVolumes() bool {
    const bs = uefi.system_table.boot_services.?;
    const boot = bootDevice(bs);
    var added = false;
    var count: usize = 0;
    var handles: [*]uefi.Handle = undefined;
    if (bs.locateHandleBuffer(.by_protocol, &SimpleFileSystem.guid, null, &count, &handles) == .success) {
        defer _ = bs.freePool(@ptrCast(handles));
        for (handles[0..count]) |h| {
            if (known(h)) continue;
            const i = freeSlot() orelse break;
            if (!addVolume(bs, h, i)) continue;
            take(i);
            flags_of[i] = partitionFlags(bs, h);
            flags_of[i].boot = boot != null and h == boot.?;
            flags_of[i].removable = removable(bs, h);
            added = true;
        }
    }
    if (bs.locateHandleBuffer(.by_protocol, &BlockIo.guid, null, &count, &handles) == .success) {
        defer _ = bs.freePool(@ptrCast(handles));
        for (handles[0..count]) |h| {
            if (known(h)) continue;
            var ptr: ?*anyopaque = null;
            if (bs.handleProtocol(h, &SimpleFileSystem.guid, &ptr) == .success) continue; // the firmware's
            if (bs.handleProtocol(h, &BlockIo.guid, &ptr) != .success) continue;
            const bio: *BlockIo = @ptrCast(@alignCast(ptr.?));
            const m = bio.media;
            if (!m.media_present or m.block_size != 512) continue;
            const i = freeSlot() orelse break;
            parts[i] = .{ .bio = bio, .media_id = m.media_id };
            const was_gone = gone[i];
            gone[i] = false; // partRead may run now
            // A whole disk only without a partition table (else the
            // firmware made handles for its
            // partitions), and not a blank one
            const whole = !m.logical_partition;
            const v = (if (whole and !noTable(&parts[i], m.last_block + 1)) null else fsd.mount(&parts[i], partRead, partWrite, partFlush, 0, m.last_block + 1)) orelse {
                gone[i] = was_gone;
                continue;
            };
            if (whole and fsd.isBlank(&v)) {
                gone[i] = was_gone;
                continue;
            }
            take(i);
            volumes[i] = .{ .driver = v };
            fsd.generationOf(&volumes[i].driver).* = epoch[i];
            handle_of[i] = h;
            flags_of[i] = partitionFlags(bs, h);
            flags_of[i].unreadable = v == .unreadable;
            flags_of[i].removable = m.removable_media;
            added = true;
        }
    }
    return added;
}

// The disk has no partition table ("superfloppy": an ext2 stick, say)
fn noTable(p: *const Part, sectors: u64) bool {
    var list: [1]partitions.Partition = undefined;
    return partitions.scan(p, scanRead, sectors, &list) == 1 and list[0].whole_disk;
}

fn scanRead(ctx: *const anyopaque, lba: u64, buf: *[512]u8) bool {
    partRead(ctx, lba, 1, buf) catch return false;
    return true;
}

// In the table, for a device that is still there
fn known(h: uefi.Handle) bool {
    for (0..volume_count) |i| {
        if (!gone[i] and handle_of[i] == h) return true;
    }
    return false;
}

// A gone slot, else the next new one
fn freeSlot() ?usize {
    for (0..volume_count) |i| {
        if (gone[i]) return i;
    }
    return if (volume_count < max_volumes) volume_count else null;
}

// Slot i holds a new device now
fn take(i: usize) void {
    if (i == volume_count) {
        volume_count += 1;
    } else {
        replaced[i] = true;
        epoch[i] +%= 1;
    }
    gone[i] = false;
}

// Devices plugged in since the last call: connected (some
// firmware stops at the USB device), pulled-out ones marked
// gone, new volumes added. True if the volume list changed.
// Once per file call; costs one CheckEvent.
pub fn newDevices() bool {
    const ev = arrival orelse return false;
    const bs = uefi.system_table.boot_services.?;
    if (bs.checkEvent(ev) != .success) return false;
    while (true) {
        var h: [1]uefi.Handle = undefined;
        var len: usize = @sizeOf(uefi.Handle);
        if (bs.locateHandle(.by_register_notify, null, arrival_key, &len, &h) != .success) break;
        _ = bs.connectController(h[0], null, null, true); // its partitions signal again: taken in this loop
    }
    for (0..volume_count) |i| {
        if (!gone[i] and flags_of[i].removable and !stillThere(i)) gone[i] = true;
    }
    return addVolumes();
}

// The protocol ZDOS keeps for slot i is still the handle's
// (else the device was pulled out, and it was freed)
fn stillThere(i: usize) bool {
    const bs = uefi.system_table.boot_services.?;
    var ptr: ?*anyopaque = null;
    return switch (volumes[i]) {
        .firmware => bs.handleProtocol(handle_of[i], &SimpleFileSystem.guid, &ptr) == .success and
            @intFromPtr(ptr.?) == @intFromPtr(sfs_of[i]),
        .driver => bs.handleProtocol(handle_of[i], &BlockIo.guid, &ptr) == .success and
            @intFromPtr(ptr.?) == @intFromPtr(parts[i].bio),
    };
}

// A USB stick or a card reader: its Block I/O says so
fn removable(bs: *uefi.tables.BootServices, h: uefi.Handle) bool {
    var ptr: ?*anyopaque = null;
    if (bs.handleProtocol(h, &BlockIo.guid, &ptr) != .success) return false;
    const bio: *BlockIo = @ptrCast(@alignCast(ptr.?));
    return bio.media.removable_media;
}

// Buffers for controllers that want aligned ones (io_align)
var bounce: [64 * 1024]u8 align(4096) = undefined;

fn aligned(p: *const Part, ptr: [*]const u8) bool {
    const a = p.bio.media.io_align;
    return a <= 1 or @intFromPtr(ptr) % a == 0;
}

// ReadBlocks / WriteBlocks for raw access (rawdisk, volumeRead):
// through bounce where the buffer lacks the device's io_align
pub fn blocksRead(bio: *BlockIo, lba: u64, buf: []u8) platform.Error!void {
    const m = bio.media;
    if (m.io_align <= 1 or @intFromPtr(buf.ptr) % m.io_align == 0) {
        if (bio.readBlocks(m.media_id, lba, buf.len, buf.ptr) != .success) return error.DeviceError;
        return;
    }
    var done: usize = 0;
    while (done < buf.len) {
        const n = @min(buf.len - done, bounce.len);
        if (bio.readBlocks(m.media_id, lba + done / m.block_size, n, &bounce) != .success) return error.DeviceError;
        @memcpy(buf[done..][0..n], bounce[0..n]);
        done += n;
    }
}

pub fn blocksWrite(bio: *BlockIo, lba: u64, data: []const u8) platform.Error!void {
    const m = bio.media;
    const direct = m.io_align <= 1 or @intFromPtr(data.ptr) % m.io_align == 0;
    var done: usize = 0;
    while (done < data.len) {
        const n = if (direct) data.len else @min(data.len - done, bounce.len);
        if (!direct) @memcpy(bounce[0..n], data[done..][0..n]);
        // The firmware's signature takes a mutable
        // pointer, but it only reads the data:
        const from: [*]u8 = if (direct) @constCast(data.ptr) else &bounce;
        switch (bio.writeBlocks(m.media_id, lba + done / m.block_size, n, from)) {
            .success => {},
            .write_protected => return error.WriteProtected,
            else => return error.DeviceError,
        }
        done += n;
    }
}

fn partRead(ctx: *const anyopaque, lba: u64, count: usize, buf: []u8) Error!void {
    const p: *const Part = @ptrCast(@alignCast(ctx));
    if (partGone(p)) return error.DeviceError;
    const bytes = count * 512;
    if (buf.len < bytes) return error.InvalidArgument;
    if (aligned(p, buf.ptr)) return blockStatus(p.bio.readBlocks(p.media_id, lba, bytes, buf.ptr));
    var done: usize = 0;
    while (done < bytes) {
        const n = @min(bytes - done, bounce.len);
        try blockStatus(p.bio.readBlocks(p.media_id, lba + done / 512, n, &bounce));
        @memcpy(buf[done..][0..n], bounce[0..n]);
        done += n;
    }
}

fn partWrite(ctx: *const anyopaque, lba: u64, count: usize, data: []const u8) Error!void {
    const p: *Part = @ptrCast(@alignCast(@constCast(ctx)));
    if (partGone(p)) return error.DeviceError;
    const bytes = count * 512;
    if (data.len < bytes) return error.InvalidArgument;
    p.unflushed = true;
    if (aligned(p, data.ptr)) {
        try blockStatus(p.bio.writeBlocks(p.media_id, lba, bytes, @constCast(data.ptr)));
    } else {
        var done: usize = 0;
        while (done < bytes) {
            const n = @min(bytes - done, bounce.len);
            @memcpy(bounce[0..n], data[done..][0..n]);
            try blockStatus(p.bio.writeBlocks(p.media_id, lba + done / 512, n, &bounce));
            done += n;
        }
    }
}

// Not after each write (a flush can take milliseconds); drivers
// ask where it counts. Errors are ignored: firmware that can't
// flush (or a device without a write
// cache) must not make every change fail
fn partFlush(ctx: *const anyopaque) Error!void {
    const p: *Part = @ptrCast(@alignCast(@constCast(ctx)));
    if (partGone(p)) return;
    _ = p.bio.flushBlocks();
    p.unflushed = false;
}

fn partGone(p: *const Part) bool {
    return gone[(@intFromPtr(p) - @intFromPtr(&parts[0])) / @sizeOf(Part)];
}

fn blockStatus(status: uefi.Status) Error!void {
    return switch (status) {
        .success => {},
        .write_protected => error.WriteProtected,
        else => error.DeviceError, // media_changed, no_media, device_error ...
    };
}

// Partition Info protocol (UEFI 2.7+): ESP flag and the
// partition table entry.
// Without it every volume counts as normal.
const PartitionInfo = extern struct {
    revision: u32,
    type: u32, // 0 other, 1 MBR, 2 GPT
    system: u8, // 1: EFI System Partition
    reserved: [7]u8,
    info: extern union {
        mbr: extern struct { boot: u8, chs_start: [3]u8, os_type: u8, chs_end: [3]u8, lba_start: [4]u8, lba_size: [4]u8 },
        gpt: extern struct { type_guid: [16]u8, unique_guid: [16]u8, start: u64, end: u64, attributes: u64, name: [36]u16 },
    },

    const guid align(8) = uefi.Guid{
        .time_low = 0x8cf2f62c,
        .time_mid = 0xbc9b,
        .time_high_and_version = 0x4821,
        .clock_seq_high_and_reserved = 0x80,
        .clock_seq_low = 0x8d,
        .node = [_]u8{ 0xec, 0x9e, 0xc4, 0x21, 0xa1, 0xa0 },
    };
};

// GPT attributes Windows uses on recovery / OEM partitions
const gpt_hidden: u64 = 1 << 62;
const gpt_no_drive_letter: u64 = 1 << 63;
// MBR types of hidden FAT partitions
const mbr_hidden_fat = [_]u8{ 0x11, 0x14, 0x16, 0x1b, 0x1c, 0x1e };

fn partitionFlags(bs: *uefi.tables.BootServices, h: uefi.Handle) platform.VolumeFlags {
    var ptr: ?*anyopaque = null;
    if (bs.handleProtocol(h, &PartitionInfo.guid, &ptr) != .success) return .{};
    const p: *const PartitionInfo = @ptrCast(@alignCast(ptr.?));
    var f: platform.VolumeFlags = .{ .system = p.system == 1 };
    switch (p.type) {
        1 => {
            f.hidden = std.mem.indexOfScalar(u8, &mbr_hidden_fat, p.info.mbr.os_type) != null;
            f.active = p.info.mbr.boot == 0x80; // the MBR's boot indicator
        },
        2 => f.hidden = p.info.gpt.attributes & (gpt_hidden | gpt_no_drive_letter) != 0,
        else => {},
    }
    return f;
}

fn bootDevice(bs: *uefi.tables.BootServices) ?uefi.Handle {
    var ptr: ?*anyopaque = null;
    if (bs.handleProtocol(uefi.handle, &uefi.protocol.LoadedImage.guid, &ptr) != .success) return null;
    const image: *const uefi.protocol.LoadedImage = @ptrCast(@alignCast(ptr.?));
    return image.device_handle;
}

fn addVolume(bs: *uefi.tables.BootServices, h: uefi.Handle, i: usize) bool {
    var ptr: ?*anyopaque = null;
    if (bs.handleProtocol(h, &SimpleFileSystem.guid, &ptr) != .success) return false;
    const sfs: *const SimpleFileSystem = @ptrCast(@alignCast(ptr.?));
    var root: *const File = undefined;
    if (sfs.openVolume(&root) != .success) return false;
    volumes[i] = .{ .firmware = root };
    handle_of[i] = h;
    sfs_of[i] = sfs;
    return true;
}

// The firmware's volumes are FAT
pub fn unixNames(vol: Volume) bool {
    return switch (vol.*) {
        .firmware => false,
        .driver => |*v| fsd.unixNames(v),
    };
}

pub fn notClean(vol: Volume) bool {
    return switch (vol.*) {
        .firmware => false,
        .driver => |*v| fsd.notClean(v),
    };
}

pub fn volumeInfo(vol: Volume) ?platform.VolumeInfo {
    alive(vol) catch return null;
    const root = switch (vol.*) {
        .firmware => |r| r,
        .driver => |*v| return fsd.volumeInfo(v),
    };
    var buf: [512]u8 align(8) = undefined;
    var len: usize = buf.len;
    if (root.getInfo(&uefi.FileSystemInfo.guid, &len, &buf) != .success) return null;
    const info: *const uefi.FileSystemInfo = @ptrCast(&buf);
    var result: platform.VolumeInfo = .{ .size = info.volume_size, .free = info.free_space, .block_size = info.block_size };
    if (bootSector(vol)) |b| {
        result.serial = b.serial;
        result.fs_name = b.fs_name;
    }
    result.label_len = text.ucs2ToUtf8(std.mem.sliceTo(info.getVolumeLabel(), 0), &result.label_buf).len;
    return result;
}

// Serial number and FAT type from the boot sector:
// Simple File System reports neither
fn bootSector(vol: Volume) ?struct { serial: ?u32, fs_name: []const u8 } {
    const h = handle_of[indexOf(vol)];
    const bs = uefi.system_table.boot_services.?;
    var ptr: ?*anyopaque = null;
    if (bs.handleProtocol(h, &uefi.protocol.BlockIo.guid, &ptr) != .success) return null;
    const bio: *uefi.protocol.BlockIo = @ptrCast(@alignCast(ptr.?));
    const block = bio.media.block_size;
    if (block < 512 or block > 4096) return null;
    var buf: [4096]u8 align(16) = undefined;
    if (bio.readBlocks(bio.media.media_id, 0, block, &buf) != .success) return null;
    if (buf[510] != 0x55 or buf[511] != 0xAA) return null;
    const rd16 = struct {
        fn f(b: []const u8) u32 {
            return std.mem.readInt(u16, b[0..2], .little);
        }
    }.f;
    // FAT32 has no 16-bit FAT size; FAT12 vs FAT16 by cluster count
    const fat16_size = rd16(buf[22..]);
    var fs_name: []const u8 = "FAT32";
    if (fat16_size != 0) {
        const bytes_per_sector = rd16(buf[11..]);
        const spc: u32 = buf[13];
        var total = rd16(buf[19..]);
        if (total == 0) total = std.mem.readInt(u32, buf[32..36], .little);
        const root_sectors = if (bytes_per_sector == 0) 0 else (rd16(buf[17..]) * 32 + bytes_per_sector - 1) / bytes_per_sector;
        const data_start = rd16(buf[14..]) + buf[16] * fat16_size + root_sectors;
        const clusters = if (spc == 0 or total <= data_start) 0 else (total - data_start) / spc;
        fs_name = if (clusters < 4085) "FAT12" else "FAT16";
    }
    const sig_at: usize = if (fat16_size == 0) 0x42 else 0x26;
    const serial: ?u32 = if (buf[sig_at] == 0x29) std.mem.readInt(u32, buf[sig_at + 1 ..][0..4], .little) else null;
    return .{ .serial = serial, .fs_name = fs_name };
}

// Removable devices, once per file call: pulled out (its
// protocols were freed) means missing for good. A driver volume
// with a new media id is mounted again; the firmware's FAT
// notices a new card itself.
pub fn checkMedia(vol: Volume) platform.Media {
    const i = indexOf(vol);
    if (gone[i]) return .missing;
    if (replaced[i]) {
        replaced[i] = false;
        return .changed;
    }
    if (!flags_of[i].removable) return .same;
    if (!stillThere(i)) {
        gone[i] = true;
        return .missing;
    }
    switch (vol.*) {
        .firmware => return .same,
        .driver => {
            const m = parts[i].bio.media;
            if (!m.media_present) return .missing;
            if (m.media_id == parts[i].media_id) return .same;
            remount(i);
            return .changed;
        },
    }
}

// The label lives in the volume's FileSystemInfo
pub fn setLabel(vol: Volume, label: []const u8) Error!void {
    try alive(vol);
    const root = switch (vol.*) {
        .firmware => |r| r,
        .driver => |*v| return fsd.setLabel(v, label),
    };
    var buf: [@sizeOf(uefi.FileSystemInfo) + 64 * 2]u8 align(8) = undefined;
    var len: usize = buf.len;
    try check(root.getInfo(&uefi.FileSystemInfo.guid, &len, &buf));
    const label_at = @offsetOf(uefi.FileSystemInfo, "_volume_label");
    const name: *[64]u16 = @ptrCast(@alignCast(&buf[label_at]));
    var n: usize = 0;
    var view = std.unicode.Utf8View.init(label) catch return error.InvalidName;
    var it = view.iterator();
    while (it.nextCodepoint()) |c| {
        if (n == name.len - 1 or c > 0xFFFF) return error.InvalidName;
        name[n] = @intCast(c);
        n += 1;
    }
    name[n] = 0;
    const info: *uefi.FileSystemInfo = @ptrCast(&buf);
    info.size = label_at + (n + 1) * 2;
    return check(root.setInfo(&uefi.FileSystemInfo.guid, info.size, &buf));
}

// ERRORS

const Error = platform.Error;

// NOT_FOUND also means a missing parent directory; the kernel
// resolves the directories first to tell them apart.
fn statusError(status: uefi.Status) Error {
    return switch (status) {
        .not_found => error.NotFound,
        .access_denied, .security_violation => error.AccessDenied,
        // The FAT driver turns every failed delete into this warning
        // (read-only, a directory that isn't empty ...)
        .warn_delete_failure => error.AccessDenied,
        .write_protected => error.WriteProtected,
        .volume_full => error.DiskFull,
        .out_of_resources => error.OutOfMemory,
        .unsupported => error.NotSupported,
        .invalid_parameter => error.InvalidArgument,
        else => error.DeviceError, // device_error, no_media, media_changed, volume_corrupted, not_ready, timeout ...
    };
}

fn check(status: uefi.Status) Error!void {
    if (status != .success) return statusError(status);
}

// ENTRIES

fn toEntryInfo(info: *const uefi.FileInfo, out: *platform.EntryInfo) void {
    const m = info.modification_time;
    out.name_len = text.ucs2ToUtf8(std.mem.sliceTo(info.getFileName(), 0), &out.name_buf).len;
    out.is_dir = info.attribute & File.efi_file_directory != 0;
    // UEFI's attribute bits have the same values as FAT's and ZDOS's
    out.attrs = @intCast(info.attribute & platform.Attr.all);
    out.size = info.file_size;
    out.modified = fromEfiTime(m);
    out.created = fromEfiTime(info.create_time);
    out.accessed = fromEfiTime(info.last_access_time);
    out.unix = null;
}

fn fromEfiTime(t: uefi.Time) platform.DateTime {
    if (t.year == 0) return platform.no_date;
    return .{ .year = t.year, .month = t.month, .day = t.day, .hour = t.hour, .minute = t.minute, .second = t.second };
}

// FileInfo's fixed part plus a 255-character name
const InfoBuf = [@sizeOf(uefi.FileInfo) + 256 * 2]u8;

fn open(root: *const File, path: []const u8, mode: u64, attributes: u64) Error!*const File {
    var buf: FwPath = undefined;
    const p = fwPath(path, &buf) orelse return error.InvalidName;
    var f: *const File = undefined;
    const status = root.open(&f, p, mode, attributes);
    if (status == .invalid_parameter) return error.InvalidName; // the FAT driver's answer to a bad name
    try check(status);
    return f;
}

const read_only = File.efi_file_mode_read;
const read_write = File.efi_file_mode_read | File.efi_file_mode_write;

fn getFileInfo(f: *const File, buf: *align(8) InfoBuf) Error!*uefi.FileInfo {
    var len: usize = buf.len;
    try check(f.getInfo(&uefi.FileInfo.guid, &len, buf));
    return @ptrCast(buf);
}

fn isDir(f: *const File) Error!bool {
    var buf: InfoBuf align(8) = undefined;
    const info = try getFileInfo(f, &buf);
    return info.attribute & File.efi_file_directory != 0;
}

fn fwStat(vol: *const File, path: []const u8, out: *platform.EntryInfo) Error!void {
    const f = try open(vol, path, read_only, 0);
    defer _ = f.close();
    var buf: InfoBuf align(8) = undefined;
    toEntryInfo(try getFileInfo(f, &buf), out);
}

// FILES

fn fwOpenFile(vol: *const File, path: []const u8, mode: platform.OpenMode) Error!*const File {
    switch (mode) {
        .read => return open(vol, path, read_only, 0),
        .write => {
            // An existing file is emptied in place (FileInfo with size 0),
            // as DOS does: it keeps its name as stored (not as typed this
            // time), its attributes and its creation date
            if (open(vol, path, read_write, 0)) |old| {
                // A directory opens too: it must not be emptied
                const dir = isDir(old) catch |err| {
                    _ = old.close();
                    return err;
                };
                if (dir) {
                    _ = old.close();
                    return error.IsADirectory;
                }
                fwSetSize(old, 0) catch |err| {
                    _ = old.close();
                    return err;
                };
                return old;
            } else |err| switch (err) {
                error.NotFound => {},
                else => return err, // read-only, write-protected ...
            }
        },
        .update => {},
    }
    return open(vol, path, read_write | File.efi_file_mode_create, 0);
}

fn fwRead(f: *const File, buf: []u8) Error!usize {
    var len = buf.len;
    try check(f.read(&len, buf.ptr));
    return len;
}

fn fwWrite(f: *const File, data: []const u8) Error!usize {
    var len = data.len;
    try check(f.write(&len, data.ptr));
    return len;
}

fn fwSeek(f: *const File, pos: u64) Error!void {
    return check(f.setPosition(pos)); // UEFI also uses maxInt(u64) for "end of file"
}

// Through FileInfo. Extended bytes aren't reliably zeroed by
// every firmware, so the zeros are written first.
// The position is kept.
fn fwSetSize(f: *const File, new_size: u64) Error!void {
    var buf: InfoBuf align(8) = undefined;
    const info = try getFileInfo(f, &buf);
    const old_size = info.file_size;
    if (new_size > old_size) {
        var pos: u64 = 0;
        try check(f.getPosition(&pos));
        defer _ = f.setPosition(pos);
        try check(f.setPosition(old_size));
        const zeros = [_]u8{0} ** 4096;
        var left = new_size - old_size;
        while (left > 0) {
            const n: usize = @intCast(@min(left, zeros.len));
            var len = n;
            try check(f.write(&len, &zeros));
            if (len != n) return error.DiskFull;
            left -= n;
        }
        return;
    }
    if (new_size == old_size) return;
    info.file_size = new_size;
    return check(f.setInfo(&uefi.FileInfo.guid, info.size, &buf));
}

fn fwSize(f: *const File) Error!u64 {
    var buf: InfoBuf align(8) = undefined;
    return (try getFileInfo(f, &buf)).file_size;
}

// Close flushes and reports nothing
fn fwClose(f: *const File) Error!void {
    _ = f.close();
}

fn fwCommit(f: *const File) Error!void {
    return check(f.flush());
}

// DIRECTORIES

fn fwOpenDir(vol: *const File, path: []const u8) Error!*const File {
    const d = try open(vol, path, read_only, 0);
    const dir = isDir(d) catch |err| {
        _ = d.close();
        return err;
    };
    if (!dir) {
        _ = d.close();
        return error.NotADirectory;
    }
    return d;
}

// A read of length 0 is the end of the directory
fn fwReadDir(d: *const File, out: *platform.EntryInfo) Error!bool {
    var buf: InfoBuf align(8) = undefined;
    var len: usize = buf.len;
    try check(d.read(&len, &buf));
    if (len == 0) return false;
    toEntryInfo(@ptrCast(&buf), out);
    return true;
}

fn fwCloseDir(d: *const File) void {
    _ = d.close();
}

fn fwMakeDir(vol: *const File, path: []const u8) Error!void {
    const f = try open(vol, path, read_write | File.efi_file_mode_create, File.efi_file_directory);
    _ = f.close();
}

fn fwDelete(vol: *const File, path: []const u8) Error!void {
    const f = try open(vol, path, read_write, 0);
    // A failed delete is only a warning: check for a non-empty
    // directory first, to report why
    if (isDir(f) catch false) {
        var buf: InfoBuf align(8) = undefined;
        while (true) {
            var len: usize = buf.len;
            if (f.read(&len, &buf) != .success or len == 0) break;
            const info: *const uefi.FileInfo = @ptrCast(&buf);
            const name = std.mem.sliceTo(info.getFileName(), 0);
            const dots = name.len <= 2 and name.len > 0 and name[0] == '.' and (name.len == 1 or name[1] == '.');
            if (!dots) {
                _ = f.close();
                return error.DirNotEmpty;
            }
        }
    }
    return check(f.delete()); // delete also closes the handle
}

// Through FileInfo; works on a read-only handle, as read-only
// files can't be opened for writing
fn fwSetAttributes(vol: *const File, path: []const u8, attrs: u8) Error!void {
    const f = open(vol, path, read_write, 0) catch |err| switch (err) {
        error.AccessDenied, error.WriteProtected => try open(vol, path, read_only, 0),
        else => return err,
    };
    defer _ = f.close();
    var buf: InfoBuf align(8) = undefined;
    const info = try getFileInfo(f, &buf);
    info.attribute = (info.attribute & ~@as(u64, platform.Attr.all)) | (attrs & platform.Attr.all);
    return check(f.setInfo(&uefi.FileInfo.guid, info.size, &buf));
}

// Through FileInfo
fn fwSetModified(vol: *const File, path: []const u8, when: platform.DateTime) Error!void {
    const f = open(vol, path, read_write, 0) catch |err| switch (err) {
        error.AccessDenied, error.WriteProtected => try open(vol, path, read_only, 0),
        else => return err,
    };
    defer _ = f.close();
    return fwSetFileModified(f, when);
}

fn fwSetFileModified(f: *const File, when: platform.DateTime) Error!void {
    var buf: InfoBuf align(8) = undefined;
    const info = try getFileInfo(f, &buf);
    const m = &info.modification_time;
    m.year = when.year;
    m.month = when.month;
    m.day = when.day;
    m.hour = when.hour;
    m.minute = when.minute;
    m.second = when.second;
    m.nanosecond = 0;
    return check(f.setInfo(&uefi.FileInfo.guid, info.size, &buf));
}

fn fwRename(vol: *const File, from: []const u8, to: []const u8) Error!void {
    const f = try open(vol, from, read_write, 0);
    defer _ = f.close();

    // Through FileInfo; a name starting with '\' is a path from the
    // root, which also moves the file
    var buf: [@sizeOf(uefi.FileInfo) + (max_path + 1) * 2]u8 align(8) = undefined;
    var len: usize = buf.len;
    try check(f.getInfo(&uefi.FileInfo.guid, &len, &buf));
    const info: *uefi.FileInfo = @ptrCast(&buf);
    const name: *FwPath = @ptrCast(@alignCast(&buf[@sizeOf(uefi.FileInfo)]));
    _ = fwPath(to, name) orelse return error.InvalidName;
    const name_len = std.mem.indexOfScalar(u16, name, 0).?;
    info.size = @sizeOf(uefi.FileInfo) + (name_len + 1) * 2;
    const status = f.setInfo(&uefi.FileInfo.guid, info.size, &buf);
    if (status == .invalid_parameter) return error.InvalidName;
    return check(status);
}

// BOTH KINDS

pub fn stat(vol: Volume, path: []const u8, out: *platform.EntryInfo) Error!void {
    try alive(vol);
    return switch (vol.*) {
        .firmware => |root| fwStat(root, path, out),
        .driver => |*v| fsd.stat(v, path, out),
    };
}

pub fn openFile(vol: Volume, path: []const u8, mode: platform.OpenMode) Error!FileHandle {
    try alive(vol);
    return switch (vol.*) {
        .firmware => |root| .{ .firmware = .{ .file = try fwOpenFile(root, path, mode), .vol = @intCast(indexOf(vol)), .epoch = epoch[indexOf(vol)], .key = pathKey(path) } },
        .driver => |*v| .{ .driver = try fsd.openFile(v, path, mode) },
    };
}

pub const FileKey = fsd.FileKey;

// The firmware's FAT: the volume's number and the path, as FAT
// compares names (capitals, either slash)
pub fn fileKey(f: FileHandle) FileKey {
    return switch (f) {
        .firmware => |h| .{ .volume = h.vol, .id = h.key },
        .driver => |h| fsd.fileKey(h),
    };
}

fn pathKey(path: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (path) |c| {
        const k = if (c == '/') '\\' else std.ascii.toUpper(c);
        h = (h ^ k) *% 0x100000001b3;
    }
    return h;
}

pub fn read(f: FileHandle, buf: []u8) Error!usize {
    return switch (f) {
        .firmware => |h| fwRead(try aliveHandle(h), buf),
        .driver => |h| fsd.read(h, buf),
    };
}

pub fn write(f: FileHandle, data: []const u8) Error!usize {
    return switch (f) {
        .firmware => |h| fwWrite(try aliveHandle(h), data),
        .driver => |h| fsd.write(h, data),
    };
}

pub fn seek(f: FileHandle, pos: u64) Error!void {
    return switch (f) {
        .firmware => |h| fwSeek(try aliveHandle(h), pos),
        .driver => |h| fsd.seek(h, pos),
    };
}

pub fn setSize(f: FileHandle, new_size: u64) Error!void {
    return switch (f) {
        .firmware => |h| fwSetSize(try aliveHandle(h), new_size),
        .driver => |h| fsd.setSize(h, new_size),
    };
}

// The name is left empty
pub fn fstat(f: FileHandle, out: *platform.EntryInfo) Error!void {
    return switch (f) {
        .firmware => |h| {
            var buf: InfoBuf align(8) = undefined;
            toEntryInfo(try getFileInfo(try aliveHandle(h), &buf), out);
            out.name_len = 0;
        },
        .driver => |h| fsd.fstat(h, out),
    };
}

pub fn setModifiedOpen(f: FileHandle, when: platform.DateTime) Error!void {
    return switch (f) {
        .firmware => |h| fwSetFileModified(try aliveHandle(h), when),
        .driver => |h| fsd.setModifiedOpen(h, when),
    };
}

pub fn size(f: FileHandle) Error!u64 {
    return switch (f) {
        .firmware => |h| fwSize(try aliveHandle(h)),
        .driver => |h| fsd.size(h),
    };
}

// A handle of a device that is gone is only forgotten:
// its memory was freed
pub fn close(f: FileHandle) Error!void {
    return switch (f) {
        .firmware => |h| if (handleValid(h)) fwClose(h.file) else {},
        .driver => |h| fsd.close(h),
    };
}

pub fn commit(f: FileHandle) Error!void {
    return switch (f) {
        .firmware => |h| fwCommit(try aliveHandle(h)),
        .driver => |h| fsd.commit(h),
    };
}

pub fn openDir(vol: Volume, path: []const u8) Error!DirHandle {
    try alive(vol);
    return switch (vol.*) {
        .firmware => |root| .{ .firmware = .{ .file = try fwOpenDir(root, path), .vol = @intCast(indexOf(vol)), .epoch = epoch[indexOf(vol)] } },
        .driver => |*v| .{ .driver = try fsd.openDir(v, path) },
    };
}

pub fn readDir(d: DirHandle, out: *platform.EntryInfo) Error!bool {
    return switch (d) {
        .firmware => |h| fwReadDir(try aliveHandle(h), out),
        .driver => |h| fsd.readDir(h, out),
    };
}

pub fn closeDir(d: DirHandle) void {
    switch (d) {
        .firmware => |h| if (handleValid(h)) fwCloseDir(h.file),
        .driver => |h| fsd.closeDir(h),
    }
}

pub fn makeDir(vol: Volume, path: []const u8) Error!void {
    try alive(vol);
    return switch (vol.*) {
        .firmware => |root| fwMakeDir(root, path),
        .driver => |*v| fsd.makeDir(v, path),
    };
}

pub fn delete(vol: Volume, path: []const u8) Error!void {
    try alive(vol);
    return switch (vol.*) {
        .firmware => |root| fwDelete(root, path),
        .driver => |*v| fsd.delete(v, path),
    };
}

pub fn rename(vol: Volume, from: []const u8, to: []const u8) Error!void {
    try alive(vol);
    return switch (vol.*) {
        .firmware => |root| fwRename(root, from, to),
        .driver => |*v| fsd.rename(v, from, to),
    };
}

pub fn setAttributes(vol: Volume, path: []const u8, attrs: u8) Error!void {
    try alive(vol);
    return switch (vol.*) {
        .firmware => |root| fwSetAttributes(root, path, attrs),
        .driver => |*v| fsd.setAttributes(v, path, attrs),
    };
}

pub fn setModified(vol: Volume, path: []const u8, when: platform.DateTime) Error!void {
    try alive(vol);
    return switch (vol.*) {
        .firmware => |root| fwSetModified(root, path, when),
        .driver => |*v| fsd.setModified(v, path, when),
    };
}

// The firmware's FAT has no Unix permissions: the kernel makes
// them up from the read-only attribute
pub fn permissions(vol: Volume, path: []const u8) Error!platform.Permissions {
    try alive(vol);
    return switch (vol.*) {
        .firmware => error.NotSupported,
        .driver => |*v| fsd.permissions(v, path),
    };
}

pub fn setMode(vol: Volume, path: []const u8, mode: u16) Error!void {
    try alive(vol);
    return switch (vol.*) {
        .firmware => error.NotSupported,
        .driver => |*v| fsd.setMode(v, path, mode),
    };
}

pub fn setOwner(vol: Volume, path: []const u8, uid: ?u32, gid: ?u32) Error!void {
    try alive(vol);
    return switch (vol.*) {
        .firmware => error.NotSupported,
        .driver => |*v| fsd.setOwner(v, path, uid, gid),
    };
}
