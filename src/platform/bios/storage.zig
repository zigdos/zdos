// Volumes, files and directories: ZDOS's file system drivers
// (drivers/filesystems.zig) on the partitions
// (drivers/partitions.zig) of the BIOS disks (disk.zig),
// and FAT on the floppy drives.
const std = @import("std");
const platform = @import("../../platform.zig");
const disk = @import("disk.zig");
const realmode = @import("realmode.zig");
const fat = @import("../../drivers/fat.zig");
const fsd = @import("../../drivers/filesystems.zig");
const partitions = @import("../../drivers/partitions.zig");

const Vol = fsd.Volume;

pub const Volume = *Vol;
pub const FileHandle = *fsd.OpenFile;
pub const DirHandle = *fsd.OpenDir;

const max_volumes = 24;
var volumes: [max_volumes]Vol = undefined;
var volume_flags: [max_volumes]platform.VolumeFlags = undefined;
var volume_count: usize = 0; // slots used so far (in use or not)
// A slot is in use while its partition exists. A deleted
// partition's slot stays (drives refer to slots) and is reused
// by a later new partition.
var volume_used = [_]bool{false} ** max_volumes;
// Each partition's length from its partition table: the
// volume's size for raw access and FORMAT,
// also where its file system is smaller
var part_sectors: [max_volumes]u64 = undefined;

// Floppy drives: one volume each, also without a disk. boot:
// the first 90 bytes of the boot sector (BPB, serial, label) to
// recognize the disk again; recheck: a tool wrote the disk
// directly, so re-read it on next use even
// if the change line says it wasn't changed.
const Floppy = struct {
    disk: *disk.Disk,
    present: bool,
    boot: [90]u8,
    recheck: bool = false,
};
var floppies: [max_volumes]?Floppy = [_]?Floppy{null} ** max_volumes;

// The disk and sectors of a volume (driveLocation:
// FORMAT, FDISK, SYS). A floppy drive gives the whole drive
// even with no disk mounted, so FORMAT can reach a blank disk.
pub fn location(vol: Volume) ?platform.Location {
    if (floppies[indexOf(vol)]) |f| return .{ .disk = @intCast(diskIndex(f.disk)), .start = 0, .sectors = f.disk.sectors };
    return .{ .disk = @intCast(diskIndex(diskOf(vol))), .start = startOf(vol), .sectors = part_sectors[indexOf(vol)] };
}

fn diskOf(vol: *const Vol) *const disk.Disk {
    return @ptrCast(@alignCast(fsd.ctxOf(vol)));
}

const startOf = fsd.startOf;
const sectorsOf = fsd.sectorsOf;
const generationOf = fsd.generationOf;

// The first driver that finds its file system on these sectors of d
fn mount(d: *disk.Disk, start: u64, sectors: u64) ?Vol {
    return fsd.mount(d, devRead, devWrite, devFlush, start, sectors);
}

// What the drivers hold back goes to the disks:
// before shutting down or restarting
pub fn syncAll() void {
    for (volumes[0..volume_count], 0..) |*v, i| {
        if (volume_used[i] and floppies[i] == null) fsd.sync(v);
    }
}

// A blank disk without a partition table is no volume
fn mountPart(d: *disk.Disk, p: partitions.Partition) ?Vol {
    const v = mount(d, p.start, p.sectors) orelse return null;
    if (p.whole_disk and fsd.isBlank(&v)) return null;
    return v;
}

fn diskIndex(d: *const disk.Disk) usize {
    return (@intFromPtr(d) - @intFromPtr(disk.disks.ptr)) / @sizeOf(disk.Disk);
}

fn indexOf(vol: Volume) usize {
    return (@intFromPtr(vol) - @intFromPtr(&volumes[0])) / @sizeOf(Vol);
}

// false: a floppy drive without a disk, or a partition no driver reads
fn ready(vol: Volume) bool {
    if (!volume_used[indexOf(vol)]) return false;
    if (vol.* == .unreadable) return false;
    const f = floppies[indexOf(vol)] orelse return true;
    return f.present;
}

// A floppy drive without a disk: "not ready", as DOS says
fn needReady(vol: Volume) platform.Error!void {
    if (!ready(vol)) return error.DeviceError;
}

fn devRead(ctx: *const anyopaque, lba: u64, count: usize, buf: []u8) platform.Error!void {
    const d: *const disk.Disk = @ptrCast(@alignCast(ctx));
    return disk.read(d, lba, count, buf);
}

fn devWrite(ctx: *const anyopaque, lba: u64, count: usize, data: []const u8) platform.Error!void {
    const d: *const disk.Disk = @ptrCast(@alignCast(ctx));
    return disk.write(d, lba, count, data);
}

// A SATA disk's write cache emptied
// (int 13h and the IDE driver: nothing)
fn devFlush(ctx: *const anyopaque) platform.Error!void {
    const d: *const disk.Disk = @ptrCast(@alignCast(ctx));
    return disk.flush(d);
}

fn partRead(ctx: *const anyopaque, lba: u64, buf: *[512]u8) bool {
    const d: *const disk.Disk = @ptrCast(@alignCast(ctx));
    disk.read(d, lba, 1, buf) catch return false;
    return true;
}

// Finds every volume, in disk order. The boot volume: on the
// boot disk, the one at the LBA stage 2 passed on, else the
// active partition, else the first normal volume.
pub fn init() void {
    disk.init();
    const boot_drive: u8 = @truncate(realmode.info.boot_drive);
    const boot_lba: u64 = realmode.info.boot_lba;
    for (disk.disks) |*d| {
        if (d.drive < 0x80) {
            // A floppy: the whole disk is one FAT volume, no partitions
            if (volume_count >= max_volumes) break;
            volumes[volume_count] = .{ .fat = undefined };
            floppies[volume_count] = .{ .disk = d, .present = false, .boot = undefined };
            volume_flags[volume_count] = .{ .floppy = true, .boot = d.drive == boot_drive };
            volume_used[volume_count] = true;
            volume_count += 1;
            _ = mountFloppy(volume_count - 1);
            continue;
        }
        var parts: [32]partitions.Partition = undefined;
        const n = partitions.scan(d, partRead, d.sectors, &parts);
        var boot_index: ?usize = null;
        var boot_rank: u8 = 0;
        for (parts[0..n]) |p| {
            if (volume_count >= max_volumes) break;
            const v = mountPart(d, p) orelse continue;
            volumes[volume_count] = v;
            volume_used[volume_count] = true;
            part_sectors[volume_count] = p.sectors;
            volume_flags[volume_count] = .{ .hidden = p.hidden, .system = p.system, .active = p.active, .floppy = d.drive < 0x80, .unreadable = v == .unreadable };
            if (d.drive == boot_drive and !p.hidden and !p.system and v != .unreadable) {
                const rank: u8 = if (p.start == boot_lba) 3 else if (p.active) 2 else 1;
                if (rank > boot_rank) {
                    if (boot_index) |b| volume_flags[b].boot = false;
                    volume_flags[volume_count].boot = true;
                    boot_index = volume_count;
                    boot_rank = rank;
                }
            }
            volume_count += 1;
        }
    }
}

// Sectors relative to the volume's start (FORMAT): the whole partition
pub fn volumeSectors(vol: Volume) ?u64 {
    return lengthOf(vol);
}

fn lengthOf(vol: Volume) u64 {
    return if (floppies[indexOf(vol)] != null) sectorsOf(vol) else part_sectors[indexOf(vol)];
}

fn volumeCount(vol: Volume, lba: u64, bytes: usize) platform.Error!usize {
    // A deleted partition: as a missing disk, it can't be read or written
    if (!volume_used[indexOf(vol)]) return error.DeviceError;
    if (bytes == 0 or bytes % disk.sector_size != 0) return error.InvalidArgument;
    const count = bytes / disk.sector_size;
    if (lba + count > lengthOf(vol)) return error.DeviceError;
    return count;
}

pub fn volumeRead(vol: Volume, lba: u64, buf: []u8) platform.Error!void {
    const count = try volumeCount(vol, lba, buf.len);
    return disk.read(diskOf(vol), startOf(vol) + lba, count, buf);
}

pub fn volumeWrite(vol: Volume, lba: u64, data: []const u8) platform.Error!void {
    const count = try volumeCount(vol, lba, data.len);
    return disk.write(diskOf(vol), startOf(vol) + lba, count, data);
}

pub fn volumeChanged(vol: Volume) void {
    if (location(vol)) |where| diskChanged(where.disk);
}

// After FORMAT, SYS, CHKDSK or FDISK wrote a disk directly:
// drop the FAT driver's cached
// sectors and rescan its partitions.
pub fn diskChanged(index: usize) void {
    const d = &disk.disks[index];
    fsd.forget(d);
    if (d.drive < 0x80) {
        // A floppy: re-read on next use; the
        // change line doesn't report a reformat
        for (&floppies) |*slot| {
            if (slot.*) |*f| {
                if (f.disk == d) f.recheck = true;
            }
        }
        return;
    }
    rescanDisk(d);
}

// Re-reads disk d's partition table. A partition still there
// (same first sector) keeps its slot and is remounted with the
// table's hidden/system flags. A vanished partition frees its
// slot, but not for a partition found in this same call, so no
// drive takes over a deleted volume's letter.
fn rescanDisk(d: *disk.Disk) void {
    var parts: [32]partitions.Partition = undefined;
    const n = partitions.scan(d, partRead, d.sectors, &parts);
    var taken = [_]bool{false} ** 32;
    var gone = [_]bool{false} ** max_volumes;
    for (0..volume_count) |i| {
        if (!volume_used[i] or floppies[i] != null) continue;
        if (diskOf(&volumes[i]) != d) continue;
        const k = for (parts[0..n], 0..) |p, j| {
            if (p.start == startOf(&volumes[i])) break j;
        } else {
            gone[i] = true;
            continue;
        };
        taken[k] = true;
        const p = parts[k];
        const generation = generationOf(&volumes[i]).*;
        const fresh = mountPart(d, p) orelse {
            gone[i] = true;
            continue;
        };
        volumes[i] = fresh;
        generationOf(&volumes[i]).* = generation;
        part_sectors[i] = p.sectors;
        volume_flags[i].hidden = p.hidden;
        volume_flags[i].system = p.system;
        volume_flags[i].active = p.active;
        volume_flags[i].unreadable = fresh == .unreadable;
    }
    for (parts[0..n], 0..) |p, k| {
        if (taken[k]) continue;
        const i = freeSlot(&gone) orelse break;
        const v = mountPart(d, p) orelse continue;
        volumes[i] = v;
        part_sectors[i] = p.sectors;
        volume_flags[i] = .{ .hidden = p.hidden, .system = p.system, .active = p.active, .unreadable = v == .unreadable };
        volume_used[i] = true;
    }
    for (gone, 0..) |g, i| {
        if (g) volume_used[i] = false;
    }
}

// A slot that is free now and was not
// freed by this call (see rescanDisk)
fn freeSlot(gone: *const [max_volumes]bool) ?usize {
    for (0..volume_count) |i| {
        if (!volume_used[i] and !gone[i]) return i;
    }
    if (volume_count >= max_volumes) return null;
    volume_count += 1;
    return volume_count - 1;
}

// Mounts the disk in floppy drive i,
// with the geometry from its boot sector
fn mountFloppy(i: usize) platform.Media {
    const f = &floppies[i].?;
    const dev: fat.Device = .{ .ctx = f.disk, .read = devRead, .write = devWrite };
    const was_present = f.present;
    f.recheck = false;
    var bs: [512]u8 = undefined;
    const readable = if (disk.read(f.disk, 0, 1, &bs)) true else |_| false;
    if (readable and was_present and std.mem.eql(u8, bs[0..90], &f.boot)) {
        // Same disk (reinserted, or a BIOS that can't tell):
        // the cache may be stale
        fat.forget(f.disk);
        volumes[i].fat.free_clusters = null;
        return .same;
    }
    fat.forget(f.disk);
    const generation = if (was_present) volumes[i].fat.generation + 1 else 0;
    f.present = false;
    if (readable) {
        disk.resetGeometry(f.disk);
        disk.setGeometry(f.disk, std.mem.readInt(u16, bs[26..28], .little), std.mem.readInt(u16, bs[24..26], .little));
        if (fat.mount(dev, 0, f.disk.sectors)) |v| {
            volumes[i] = .{ .fat = v };
            volumes[i].fat.generation = generation;
            f.boot = bs[0..90].*;
            f.present = true;
            return .changed;
        }
    }
    // Nothing usable: open files become invalid. Back to
    // the drive's geometry: a blank disk's boot sector is
    // random, and FORMAT uses it.
    disk.resetGeometry(f.disk);
    volumes[i].fat.generation = generation;
    return .missing;
}

// Disks are found once, at startup (the BIOS knows no others)
pub fn newDevices() bool {
    return false;
}

pub fn checkMedia(vol: Volume) platform.Media {
    const i = indexOf(vol);
    const f = floppies[i] orelse return .same;
    if (f.present and !f.recheck and !disk.mayHaveChanged(f.disk)) return .same;
    return mountFloppy(i);
}

// In slot order, without freed slots
pub fn listVolumes(out: []Volume, flags: []platform.VolumeFlags) usize {
    var n: usize = 0;
    for (0..volume_count) |i| {
        if (!volume_used[i]) continue;
        if (n >= out.len or n >= flags.len) break;
        out[n] = &volumes[i];
        flags[n] = volume_flags[i];
        n += 1;
    }
    return n;
}

pub fn unixNames(vol: Volume) bool {
    return fsd.unixNames(vol);
}

pub fn notClean(vol: Volume) bool {
    return fsd.notClean(vol);
}

// An unreadable partition has one too:
// its size and what it seems to hold
pub fn volumeInfo(vol: Volume) ?platform.VolumeInfo {
    if (!ready(vol) and !(volume_used[indexOf(vol)] and vol.* == .unreadable)) return null;
    return fsd.volumeInfo(vol);
}

pub fn stat(vol: Volume, path: []const u8, out: *platform.EntryInfo) platform.Error!void {
    try needReady(vol);
    return fsd.stat(vol, path, out);
}

pub fn openFile(vol: Volume, path: []const u8, mode: platform.OpenMode) platform.Error!FileHandle {
    try needReady(vol);
    return fsd.openFile(vol, path, mode);
}

pub const read = fsd.read;
pub const fstat = fsd.fstat;
pub const fileKey = fsd.fileKey;
pub const FileKey = fsd.FileKey;
pub const setModifiedOpen = fsd.setModifiedOpen;
pub const write = fsd.write;
pub const seek = fsd.seek;
pub const setSize = fsd.setSize;
pub const size = fsd.size;
pub const close = fsd.close;
pub const commit = fsd.commit;

pub fn openDir(vol: Volume, path: []const u8) platform.Error!DirHandle {
    try needReady(vol);
    return fsd.openDir(vol, path);
}

pub const readDir = fsd.readDir;
pub const closeDir = fsd.closeDir;

pub fn makeDir(vol: Volume, path: []const u8) platform.Error!void {
    try needReady(vol);
    return fsd.makeDir(vol, path);
}

pub fn delete(vol: Volume, path: []const u8) platform.Error!void {
    try needReady(vol);
    return fsd.delete(vol, path);
}

pub fn rename(vol: Volume, from: []const u8, to: []const u8) platform.Error!void {
    try needReady(vol);
    return fsd.rename(vol, from, to);
}

pub fn setAttributes(vol: Volume, path: []const u8, attrs: u8) platform.Error!void {
    try needReady(vol);
    return fsd.setAttributes(vol, path, attrs);
}

pub fn setModified(vol: Volume, path: []const u8, when: platform.DateTime) platform.Error!void {
    try needReady(vol);
    return fsd.setModified(vol, path, when);
}

pub fn setLabel(vol: Volume, label: []const u8) platform.Error!void {
    try needReady(vol);
    return fsd.setLabel(vol, label);
}

pub fn permissions(vol: Volume, path: []const u8) platform.Error!platform.Permissions {
    try needReady(vol);
    return fsd.permissions(vol, path);
}

pub fn setMode(vol: Volume, path: []const u8, mode: u16) platform.Error!void {
    try needReady(vol);
    return fsd.setMode(vol, path, mode);
}

pub fn setOwner(vol: Volume, path: []const u8, uid: ?u32, gid: ?u32) platform.Error!void {
    try needReady(vol);
    return fsd.setOwner(vol, path, uid, gid);
}
