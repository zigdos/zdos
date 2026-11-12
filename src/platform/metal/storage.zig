// Volumes for metal: ZDOS's file system drivers on the
// partitions of disks.zig, as on BIOS. The boot volume is the
// ESP the firmware loaded ZDOS from. Pulled-out USB disks'
// volumes report a missing disk; plugged in again (or a new
// one), the hot-plug task mounts them (hotplugUpdate).
const std = @import("std");
const platform = @import("../../platform.zig");
const disks = @import("disks.zig");
const fsd = @import("../../drivers/filesystems.zig");
const partitions = @import("../../drivers/partitions.zig");
const usb = @import("usb.zig");

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
// A USB disk's volume whose partition its device no longer has
// (plugged in again, changed meanwhile), and
// one mounted again since checkMedia looked
var vol_gone = [_]bool{false} ** max_volumes;
var vol_changed = [_]bool{false} ** max_volumes;

// The disk and sectors of a volume (FORMAT, FDISK, SYS)
pub fn location(vol: Volume) ?platform.Location {
    return .{ .disk = @intCast(diskIndex(diskOf(vol))), .start = startOf(vol), .sectors = part_sectors[indexOf(vol)] };
}

// A sector of the disk a volume is on (boot entries read
// its partition table)
pub fn diskSector(vol: Volume, lba: u64, buf: *[512]u8) bool {
    return partRead(diskOf(vol), lba, buf);
}

fn diskOf(vol: *const Vol) *const disks.Disk {
    return @ptrCast(@alignCast(fsd.ctxOf(vol)));
}

const startOf = fsd.startOf;
const generationOf = fsd.generationOf;

fn mount(d: *const disks.Disk, start: u64, sectors: u64) ?Vol {
    return fsd.mount(d, devRead, devWrite, devFlush, start, sectors);
}

// What the drivers hold back goes to the disks, and the disks'
// write caches to the media: before shutting down or restarting
pub fn syncAll() void {
    for (volumes[0..volume_count], 0..) |*v, i| {
        if (volume_used[i]) fsd.sync(v);
    }
    for (disks.list[0..disks.count]) |*d| disks.flush(d);
}

// A blank disk without a partition table is no volume
fn mountPart(d: *const disks.Disk, p: partitions.Partition) ?Vol {
    const v = mount(d, p.start, p.sectors) orelse return null;
    if (p.whole_disk and fsd.isBlank(&v)) return null;
    return v;
}

fn diskIndex(d: *const disks.Disk) usize {
    return (@intFromPtr(d) - @intFromPtr(&disks.list[0])) / @sizeOf(disks.Disk);
}

fn indexOf(vol: Volume) usize {
    return (@intFromPtr(vol) - @intFromPtr(&volumes[0])) / @sizeOf(Vol);
}

// false: a deleted partition, one no
// driver reads, or a pulled-out disk's
fn ready(vol: Volume) bool {
    if (!volume_used[indexOf(vol)] or vol_gone[indexOf(vol)]) return false;
    if (vol.* == .unreadable) return false;
    return !disks.missing(diskOf(vol));
}

// "Not ready", as DOS says
fn needReady(vol: Volume) platform.Error!void {
    if (!ready(vol)) return error.DeviceError;
}

fn devRead(ctx: *const anyopaque, lba: u64, count: usize, buf: []u8) platform.Error!void {
    return disks.read(@ptrCast(@alignCast(ctx)), lba, count, buf);
}

fn devWrite(ctx: *const anyopaque, lba: u64, count: usize, data: []const u8) platform.Error!void {
    return disks.write(@ptrCast(@alignCast(ctx)), lba, count, data);
}

fn devFlush(ctx: *const anyopaque) platform.Error!void {
    disks.flush(@ptrCast(@alignCast(ctx)));
}

fn partRead(ctx: *const anyopaque, lba: u64, buf: *[512]u8) bool {
    disks.read(@ptrCast(@alignCast(ctx)), lba, 1, buf) catch return false;
    return true;
}

// Every volume, in disk order (disks.init has run)
pub fn init() void {
    for (disks.list[0..disks.count]) |*d| {
        var parts: [32]partitions.Partition = undefined;
        const n = partitions.scan(d, partRead, d.sectors, &parts);
        for (parts[0..n]) |p| {
            if (volume_count >= max_volumes) break;
            const v = mountPart(d, p) orelse continue;
            volumes[volume_count] = v;
            volume_used[volume_count] = true;
            part_sectors[volume_count] = p.sectors;
            volume_flags[volume_count] = flagsOf(d, p, v);
            volume_count += 1;
        }
    }
}

fn flagsOf(d: *const disks.Disk, p: partitions.Partition, v: Vol) platform.VolumeFlags {
    return .{
        .hidden = p.hidden,
        .system = p.system,
        .active = p.active,
        .removable = d.removable,
        .unreadable = v == .unreadable,
        .boot = disks.isBootPartition(d, p.start, p.sectors),
    };
}

// Sectors relative to the volume's start (FORMAT): the whole partition
pub fn volumeSectors(vol: Volume) ?u64 {
    return part_sectors[indexOf(vol)];
}

fn volumeCount(vol: Volume, lba: u64, bytes: usize) platform.Error!usize {
    // A deleted partition: as a missing disk, it can't be read or written
    if (!volume_used[indexOf(vol)]) return error.DeviceError;
    if (bytes == 0 or bytes % disks.sector_size != 0) return error.InvalidArgument;
    const count = bytes / disks.sector_size;
    if (lba + count > part_sectors[indexOf(vol)]) return error.DeviceError;
    return count;
}

pub fn volumeRead(vol: Volume, lba: u64, buf: []u8) platform.Error!void {
    const count = try volumeCount(vol, lba, buf.len);
    return disks.read(diskOf(vol), startOf(vol) + lba, count, buf);
}

pub fn volumeWrite(vol: Volume, lba: u64, data: []const u8) platform.Error!void {
    const count = try volumeCount(vol, lba, data.len);
    return disks.write(diskOf(vol), startOf(vol) + lba, count, data);
}

pub fn volumeChanged(vol: Volume) void {
    if (location(vol)) |where| diskChanged(where.disk);
}

// After FORMAT, SYS, CHKDSK or FDISK wrote a disk directly:
// drop the drivers' cached sectors and rescan its partitions
pub fn diskChanged(index: usize) void {
    if (index >= disks.count) return;
    const d = &disks.list[index];
    fsd.forget(d);
    rescanDisk(d);
}

// Re-reads disk d's partition table. A partition still there
// (same first sector) keeps its slot and is remounted with
// the table's flags. A vanished partition frees its slot, but
// not for a partition found in this same call, so no drive
// takes over a deleted volume's letter.
fn rescanDisk(d: *const disks.Disk) void {
    var parts: [32]partitions.Partition = undefined;
    const n = partitions.scan(d, partRead, d.sectors, &parts);
    var taken = [_]bool{false} ** 32;
    var gone = [_]bool{false} ** max_volumes;
    for (0..volume_count) |i| {
        if (!volume_used[i]) continue;
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
        const boot = volume_flags[i].boot;
        volume_flags[i] = flagsOf(d, p, fresh);
        volume_flags[i].boot = boot;
    }
    for (parts[0..n], 0..) |p, k| {
        if (taken[k]) continue;
        const i = freeSlot(&gone) orelse break;
        const v = mountPart(d, p) orelse continue;
        volumes[i] = v;
        part_sectors[i] = p.sectors;
        volume_flags[i] = flagsOf(d, p, v);
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

// USB disks come and go through the hot-plug task (hotplugUpdate)
pub fn newDevices() bool {
    return false;
}

pub fn checkMedia(vol: Volume) platform.Media {
    const i = indexOf(vol);
    if (vol_gone[i] or disks.missing(diskOf(vol))) return .missing;
    if (vol_changed[i]) {
        vol_changed[i] = false;
        return .changed;
    }
    return .same;
}

// A volume whose device went away, or that was mounted (new or back)
pub const HotplugChange = struct { vol: Volume, came: bool };

// Counts the controllers' news of devices coming and going: the
// kernel's task waits for it to move, and is woken by wake
pub var hotplug_news = std.atomic.Value(u32).init(0);
var hotplug_wake: ?*const fn () void = null;

pub fn hotplugStart(wake: *const fn () void) void {
    hotplug_wake = wake;
    usb.startHotplug(&hotplugNotify);
}

// From the USB interrupt too
fn hotplugNotify() void {
    _ = hotplug_news.fetchAdd(1, .release);
    hotplug_wake.?();
}

// The task's work, under the kernel lock: devices enumerated or
// let go, then the disks' volumes; what changed into out
pub fn hotplugUpdate(out: []HotplugChange) usize {
    var changes: [disks.max_disks]disks.Change = undefined;
    {
        usb.enter();
        defer usb.leave();
        usb.processTopology();
        disks.update(&changes);
    }
    var n: usize = 0;
    for (changes[0..disks.count], disks.list[0..disks.count]) |c, *d| {
        if (c == .none) continue;
        fsd.forget(d); // what was cached of it is stale either way
        if (c != .gone) {
            n += remount(d, out[n..]);
            continue;
        }
        for (0..volume_count) |i| {
            if (!volume_used[i] or vol_gone[i] or diskOf(&volumes[i]) != d or n == out.len) continue;
            out[n] = .{ .vol = &volumes[i], .came = false };
            n += 1;
        }
    }
    return n;
}

// A disk plugged in (again): its partitions in the slots its
// volumes had (in order: their drives keep their letters), the
// others in new slots; old slots left over are gone.
// Handles of before become invalid.
fn remount(d: *const disks.Disk, out: []HotplugChange) usize {
    var old: [max_volumes]usize = undefined;
    var old_n: usize = 0;
    for (0..volume_count) |i| {
        if (!volume_used[i] or diskOf(&volumes[i]) != d) continue;
        old[old_n] = i;
        old_n += 1;
    }
    var parts: [32]partitions.Partition = undefined;
    const pn = partitions.scan(d, partRead, d.sectors, &parts);
    var taken: usize = 0;
    var n: usize = 0;
    for (parts[0..pn]) |p| {
        const v = mountPart(d, p) orelse continue;
        const i = if (taken < old_n) old[taken] else newSlot() orelse break;
        if (taken < old_n) taken += 1;
        const reused = volume_used[i];
        const generation = if (reused) generationOf(&volumes[i]).* +% 1 else 0;
        volumes[i] = v;
        generationOf(&volumes[i]).* = generation;
        part_sectors[i] = p.sectors;
        volume_flags[i] = flagsOf(d, p, v);
        volume_used[i] = true;
        vol_gone[i] = false;
        vol_changed[i] = reused;
        if (n < out.len) {
            out[n] = .{ .vol = &volumes[i], .came = true };
            n += 1;
        }
    }
    for (old[taken..old_n]) |i| vol_gone[i] = true;
    return n;
}

// A slot for a new volume: an unused one, else a pulled-out
// disk's (its drive's letter goes to this one, as on UEFI)
fn newSlot() ?usize {
    for (0..volume_count) |i| {
        if (!volume_used[i]) return i;
    }
    if (volume_count < max_volumes) {
        volume_count += 1;
        return volume_count - 1;
    }
    for (0..volume_count) |i| {
        if (vol_gone[i] or disks.missing(diskOf(&volumes[i]))) return i;
    }
    return null;
}

// EJECT: every volume of vol's disk written out and the
// device let go; its drives are missing until it is
// plugged in again. Not the disk ZDOS booted from or
// system is on, nor one with a file open for writing.
pub fn eject(vol: Volume, system: ?Volume) platform.Error!void {
    const d: *disks.Disk = @constCast(diskOf(vol));
    if (d.dev != .usb) return error.NotSupported;
    if (disks.missing(d)) return error.DeviceError;
    for (0..volume_count) |i| {
        if (!volume_used[i] or diskOf(&volumes[i]) != d) continue;
        if (volume_flags[i].boot or system == &volumes[i]) return error.AccessDenied;
        if (fsd.openForWriting(&volumes[i])) return error.AccessDenied;
    }
    for (0..volume_count) |i| {
        if (volume_used[i] and !vol_gone[i] and diskOf(&volumes[i]) == d) fsd.sync(&volumes[i]);
    }
    disks.eject(d);
    fsd.forget(d);
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
