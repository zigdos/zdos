// FAT12/16/32 with long names on any 512-byte-sector
// device, for the BIOS edition. Write-through: every change
// reaches the disk at once, except a file's size and date,
// written on close or commit, as in DOS. Limits:
// 512-byte sectors; case-insensitive for ASCII only;
// no locking of a file opened twice. A disk error is never
// taken for a missing entry or a directory's end:
// an operation would go on with wrong data (a second entry
// for an existing name).
const std = @import("std");
const platform = @import("../platform.zig");
const cp437 = @import("cp437.zig");

const Error = platform.Error;

pub const sector_size = 512;

// lba counts from the start of the disk.
pub const Device = struct {
    ctx: *const anyopaque,
    read: *const fn (ctx: *const anyopaque, lba: u64, count: usize, buf: []u8) Error!void,
    write: *const fn (ctx: *const anyopaque, lba: u64, count: usize, data: []const u8) Error!void,
    // Null where the backend can't (BIOS).
    flush: ?*const fn (ctx: *const anyopaque) Error!void = null,
};

const Kind = enum { fat12, fat16, fat32 };

pub const Volume = struct {
    dev: Device,
    start: u64, // first sector of the partition
    kind: Kind,
    sectors_per_cluster: u32,
    cluster_bytes: u32,
    num_fats: u32,
    active_fat: ?u32, // FAT32 with mirroring off: the only FAT in use
    fat_start: u32, // sectors from the partition start
    fat_sectors: u32,
    root_start: u32, // FAT12/16: the fixed root directory
    root_entries: u32,
    data_start: u32,
    cluster_count: u32, // clusters 2 .. cluster_count + 1
    root_cluster: u32, // FAT32
    fsinfo: u32, // FAT32: sector of the FSInfo record, 0 if none
    total_sectors: u64, // of the file system: nothing past it is ever read or written
    damaged: bool = false, // a bad write was refused
    fsinfo_dirty: bool = false, // free count / next free changed since FSInfo was written
    unflushed: bool = false, // written since the device was last flushed
    bpb_label: [11]u8,
    serial: ?u32 = null, // volume serial number from the boot sector
    free_clusters: ?u32 = null, // from FSInfo when mounting, else counted on first use
    next_free: u32 = 2, // where to look for a free cluster
    // Raised on a disk change (floppies):
    // older handles become invalid.
    generation: u32 = 0,

    // A number outside the data area (a damaged entry or FAT) is
    // refused, never turned into another sector.
    fn clusterSector(v: *const Volume, c: u32) Error!u64 {
        if (c < 2 or c > v.cluster_count + 1) return error.DeviceError;
        return v.data_start + @as(u64, c - 2) * v.sectors_per_cluster;
    }

    // 0: the fixed FAT12/16 root.
    fn root(v: *const Volume) u32 {
        return if (v.kind == .fat32) v.root_cluster else 0;
    }

    // ".." entries and cluster fields use 0 for the root.
    fn dirRef(v: *const Volume, cluster: u32) u32 {
        return if (cluster == 0) v.root() else cluster;
    }

    fn eocMin(v: *const Volume) u32 {
        return switch (v.kind) {
            .fat12 => 0xFF8,
            .fat16 => 0xFFF8,
            .fat32 => 0x0FFF_FFF8,
        };
    }

    // End marker, free, bad or out of range.
    fn isEnd(v: *const Volume, c: u32) bool {
        return c < 2 or c > v.cluster_count + 1 or c >= v.eocMin() - 1;
    }
};

// MOUNTING

// Null if it holds no FAT file system.
pub fn mount(dev: Device, start: u64, sectors: u64) ?Volume {
    var bs: [sector_size]u8 = undefined;
    dev.read(dev.ctx, start, 1, &bs) catch return null;
    const rd16 = struct {
        fn f(b: []const u8) u32 {
            return std.mem.readInt(u16, b[0..2], .little);
        }
    }.f;
    const rd32 = struct {
        fn f(b: []const u8) u32 {
            return std.mem.readInt(u32, b[0..4], .little);
        }
    }.f;

    if (bs[510] != 0x55 or bs[511] != 0xAA) return null;
    const bytes_per_sector = rd16(bs[11..]);
    const spc: u32 = bs[13];
    const reserved = rd16(bs[14..]);
    const num_fats: u32 = bs[16];
    const root_entries = rd16(bs[17..]);
    var total = rd16(bs[19..]);
    const media = bs[21];
    var fat_size = rd16(bs[22..]);
    if (total == 0) total = rd32(bs[32..]);
    const is32 = fat_size == 0;
    if (is32) fat_size = rd32(bs[36..]);

    if (bytes_per_sector != sector_size) return null;
    if (spc == 0 or spc > 128 or spc & (spc - 1) != 0) return null;
    if (reserved == 0 or num_fats == 0 or num_fats > 4 or fat_size == 0) return null;
    if (media != 0xF0 and media < 0xF8) return null;
    if (total == 0 or (sectors > 0 and total > sectors)) return null;
    if (is32 and root_entries != 0) return null;

    const root_sectors = (root_entries * 32 + sector_size - 1) / sector_size;
    const data_start = reserved + num_fats * fat_size + root_sectors;
    if (data_start >= total) return null;
    const clusters = (total - data_start) / spc;
    // FAT32 by its BPB (16-bit FAT size 0), as Linux and Windows,
    // even below the specification's minimum clusters; FAT12 /
    // FAT16 by the cluster count:
    const kind: Kind = if (is32) .fat32 else if (clusters < 4085) .fat12 else if (clusters < 65525) .fat16 else return null;

    // The FAT must be big enough for all clusters:
    const fat_bytes_needed: u64 = switch (kind) {
        .fat12 => (@as(u64, clusters) + 2) * 3 / 2,
        .fat16 => (@as(u64, clusters) + 2) * 2,
        .fat32 => (@as(u64, clusters) + 2) * 4,
    };
    if (@as(u64, fat_size) * sector_size < fat_bytes_needed) return null;

    var v: Volume = .{
        .dev = dev,
        .start = start,
        .kind = kind,
        .sectors_per_cluster = spc,
        .cluster_bytes = spc * sector_size,
        .num_fats = num_fats,
        .active_fat = null,
        .fat_start = reserved,
        .fat_sectors = fat_size,
        .root_start = reserved + num_fats * fat_size,
        .root_entries = root_entries,
        .data_start = data_start,
        .cluster_count = clusters,
        .root_cluster = 0,
        .fsinfo = 0,
        .total_sectors = total,
        .bpb_label = undefined,
    };
    if (is32) {
        const ext_flags = rd16(bs[40..]);
        if (ext_flags & 0x80 != 0) v.active_fat = ext_flags & 0x0F;
        v.root_cluster = rd32(bs[44..]);
        const fsinfo = rd16(bs[48..]);
        if (fsinfo != 0 and fsinfo != 0xFFFF and fsinfo < reserved) v.fsinfo = fsinfo;
        if (v.isEnd(v.root_cluster)) return null;
        // FSInfo's hints, if plausible: the free count spares counting
        // the FAT, the next free cluster a search:
        if (v.fsinfo != 0) {
            var fsi: [sector_size]u8 = undefined;
            const readable = if (dev.read(dev.ctx, start + v.fsinfo, 1, &fsi)) true else |_| false;
            if (readable and validFsInfo(&fsi)) {
                const free = rd32(fsi[488..]); // 0xFFFFFFFF: unknown
                const next = rd32(fsi[492..]);
                if (free <= clusters) v.free_clusters = free;
                if (next >= 2 and next <= clusters + 1) v.next_free = next;
            }
        }
    }
    const label_at: usize = if (is32) 0x47 else 0x2B;
    const sig_at: usize = if (is32) 0x42 else 0x26;
    v.bpb_label = if (bs[sig_at] == 0x29) bs[label_at..][0..11].* else "NO NAME    ".*;
    if (bs[sig_at] == 0x29) v.serial = std.mem.readInt(u32, bs[sig_at + 1 ..][0..4], .little);
    return v;
}

// SECTOR CACHE
//
// Recent sectors (FAT, directories, partial file
// sectors) by a hash table; clock replacement.
// Write-through, except FAT sectors: kept dirty until
// the operation ends (flushFat), so a sector of 128
// clusters is written once.

const cache_lines = 512; // 256 KiB of sectors
const cache_buckets = 1024; // a power of two, twice the lines
const no_line: u16 = 0xFFFF;
const Line = struct {
    dev: ?*const anyopaque = null,
    lba: u64 = 0,
    next: u16 = no_line, // the next line in the same bucket
    referenced: bool = false,
    owner: ?*const Volume = null, // dirty: changed, not yet on this volume's disk
    data: [sector_size]u8 = undefined,
};
var cache = [_]Line{.{}} ** cache_lines;
var buckets = [_]u16{no_line} ** cache_buckets;
var hand: usize = 0;
var dirty_lines: u32 = 0;

fn bucketOf(dev: *const anyopaque, lba: u64) usize {
    var h: u64 = lba *% 0x9E3779B97F4A7C15 ^ @as(u64, @intFromPtr(dev));
    h ^= h >> 29;
    h *%= 0xBF58476D1CE4E5B9;
    h ^= h >> 32;
    return @intCast(h & (cache_buckets - 1));
}

fn findLine(dev: *const anyopaque, lba: u64) ?u16 {
    var i = buckets[bucketOf(dev, lba)];
    while (i != no_line) : (i = cache[i].next) {
        if (cache[i].dev == dev and cache[i].lba == lba) return i;
    }
    return null;
}

fn dropLine(i: u16) void {
    const l = &cache[i];
    const dev = l.dev orelse return;
    var link = &buckets[bucketOf(dev, l.lba)];
    while (link.* != no_line) : (link = &cache[link.*].next) {
        if (link.* == i) {
            link.* = l.next;
            break;
        }
    }
    l.dev = null;
    l.next = no_line;
    if (l.owner != null) {
        l.owner = null;
        dirty_lines -= 1;
    }
}

// DISK ACCESS
//
// devRead / devWrite keep all I/O inside the file system and
// refuse writes to the reserved sectors except FSInfo. Such a
// write means damage or a bug: refused, and
// the volume marked damaged until restart.

fn devRead(v: *const Volume, rel: u64, count: usize, buf: []u8) Error!void {
    if (rel + count > v.total_sectors) return error.DeviceError;
    return v.dev.read(v.dev.ctx, v.start + rel, count, buf);
}

fn devWrite(v: *const Volume, rel: u64, count: usize, data: []const u8) Error!void {
    const m: *Volume = @constCast(v); // volumes live in a writable table
    if (m.damaged) return error.DeviceError;
    const outside = rel + count > v.total_sectors;
    const reserved = rel < v.fat_start and !(v.fsinfo != 0 and rel == v.fsinfo and count == 1);
    if (outside or reserved) {
        m.damaged = true;
        return error.DeviceError;
    }
    m.unflushed = true;
    return v.dev.write(v.dev.ctx, v.start + rel, count, data);
}

// The drive's write cache emptied: when a change is done, on
// commit and close, not per write.
fn putOnDisk(v: *const Volume) Error!void {
    const m: *Volume = @constCast(v);
    if (!m.unflushed) return;
    if (v.dev.flush) |flush| try flush(v.dev.ctx);
    m.unflushed = false;
}

// The FAT, FSInfo's hints, then everything flushed.
fn finish(v: *Volume) void {
    flushFsInfo(v);
    putOnDisk(v) catch {};
}

// Written by flushFat.
fn keepFat(v: *const Volume, rel: u64) void {
    const i = findLine(v.dev.ctx, v.start + rel) orelse return;
    if (cache[i].owner != null) return;
    cache[i].owner = v;
    dirty_lines += 1;
}

// Dropped if that fails: the cache must
// not claim more than the disk has.
fn writeLine(i: u16) Error!void {
    const l = &cache[i];
    const v = l.owner orelse return;
    l.owner = null;
    dirty_lines -= 1;
    devWrite(v, l.lba - v.start, 1, &l.data) catch |err| {
        dropLine(i);
        return err;
    };
}

// In disk order (first FAT, then its copies), before any
// other metadata write: an entry never points to clusters
// the disk's FAT lacks.
fn flushFat(v: *const Volume) Error!void {
    var failed: ?Error = null;
    while (dirty_lines != 0) {
        var best: ?u16 = null;
        for (&cache, 0..) |*l, i| {
            if (l.owner != v) continue;
            if (best == null or l.lba < cache[best.?].lba) best = @intCast(i);
        }
        writeLine(best orelse break) catch |err| {
            failed = err;
        };
    }
    if (failed) |err| return err;
}

// Valid until the next cache call.
fn sector(v: *const Volume, rel: u64) Error!*[sector_size]u8 {
    const lba = v.start + rel;
    if (findLine(v.dev.ctx, lba)) |i| {
        cache[i].referenced = true;
        return &cache[i].data;
    }
    // An empty line, or one not used since the hand last passed:
    while (cache[hand].dev != null and cache[hand].referenced) {
        cache[hand].referenced = false;
        hand = (hand + 1) % cache_lines;
    }
    const i: u16 = @intCast(hand);
    hand = (hand + 1) % cache_lines;
    try writeLine(i); // a dirty line's change first
    dropLine(i);
    const l = &cache[i];
    try devRead(v, rel, 1, &l.data);
    l.dev = v.dev.ctx;
    l.lba = lba;
    l.referenced = true;
    const b = bucketOf(v.dev.ctx, lba);
    l.next = buckets[b];
    buckets[b] = i;
    return &l.data;
}

// If that fails, the changed copy is dropped: the cache
// must match the disk.
fn writeBack(v: *const Volume, rel: u64, data: *const [sector_size]u8) Error!void {
    try flushFat(v);
    devWrite(v, rel, 1, data) catch |err| {
        invalidate(v, rel, 1);
        return err;
    };
}

// After writing past the cache: forget stale copies.
fn invalidate(v: *const Volume, rel: u64, count: u64) void {
    var k: u64 = 0;
    while (k < count) : (k += 1) {
        if (findLine(v.dev.ctx, v.start + rel + k)) |i| dropLine(i);
    }
}

// A floppy that was changed.
pub fn forget(dev_ctx: *const anyopaque) void {
    for (&cache, 0..) |*l, i| {
        if (l.dev == dev_ctx) dropLine(@intCast(i));
    }
    for (&dir_indexes) |*d| {
        if (d.dev == dev_ctx) removeDirIndex(d);
    }
    for (&dir_cursors) |*c| {
        if (c.dev == dev_ctx) c.* = .{};
    }
}

// THE ALLOCATION TABLE

fn fatGet(v: *const Volume, c: u32) Error!u32 {
    switch (v.kind) {
        .fat12 => {
            const off = c + c / 2;
            const lo = try fatByte(v, 0, off);
            const hi = try fatByte(v, 0, off + 1);
            const pair = @as(u32, lo) | @as(u32, hi) << 8;
            return if (c & 1 != 0) pair >> 4 else pair & 0xFFF;
        },
        .fat16 => {
            const s = try sector(v, firstFat(v) + c / 256);
            return std.mem.readInt(u16, s[(c % 256) * 2 ..][0..2], .little);
        },
        .fat32 => {
            const s = try sector(v, firstFat(v) + c / 128);
            return std.mem.readInt(u32, s[(c % 128) * 4 ..][0..4], .little) & 0x0FFF_FFFF;
        },
    }
}

fn firstFat(v: *const Volume) u64 {
    return v.fat_start + @as(u64, v.active_fat orelse 0) * v.fat_sectors;
}

fn fatByte(v: *const Volume, fat: u32, off: u32) Error!u8 {
    const s = try sector(v, v.fat_start + @as(u64, fat) * v.fat_sectors + off / sector_size);
    return s[off % sector_size];
}

fn setFatByte(v: *const Volume, fat: u32, off: u32, val: u8) Error!void {
    const rel = v.fat_start + @as(u64, fat) * v.fat_sectors + off / sector_size;
    const s = try sector(v, rel);
    s[off % sector_size] = val;
    keepFat(v, rel);
}

// Into every copy of the FAT.
fn fatSet(v: *Volume, c: u32, value: u32) Error!void {
    var fat: u32 = 0;
    while (fat < v.num_fats) : (fat += 1) {
        if (v.active_fat) |a| if (a != fat) continue;
        switch (v.kind) {
            .fat12 => {
                const off = c + c / 2;
                const lo = try fatByte(v, fat, off);
                const hi = try fatByte(v, fat, off + 1);
                var pair = @as(u32, lo) | @as(u32, hi) << 8;
                if (c & 1 != 0) {
                    pair = (pair & 0x000F) | (value & 0xFFF) << 4;
                } else {
                    pair = (pair & 0xF000) | (value & 0xFFF);
                }
                try setFatByte(v, fat, off, @truncate(pair));
                try setFatByte(v, fat, off + 1, @truncate(pair >> 8));
            },
            .fat16 => {
                const rel = v.fat_start + @as(u64, fat) * v.fat_sectors + c / 256;
                const s = try sector(v, rel);
                std.mem.writeInt(u16, s[(c % 256) * 2 ..][0..2], @truncate(value), .little);
                keepFat(v, rel);
            },
            .fat32 => {
                const rel = v.fat_start + @as(u64, fat) * v.fat_sectors + c / 128;
                const s = try sector(v, rel);
                const p = s[(c % 128) * 4 ..][0..4];
                const old = std.mem.readInt(u32, p, .little);
                std.mem.writeInt(u32, p, (old & 0xF000_0000) | (value & 0x0FFF_FFFF), .little);
                keepFat(v, rel);
            },
        }
    }
}

fn eocValue(v: *const Volume) u32 {
    return switch (v.kind) {
        .fat12 => 0xFFF,
        .fat16 => 0xFFFF,
        .fat32 => 0x0FFF_FFFF,
    };
}

// FSInfo's free count and next free cluster: read at
// mount, written after every operation that used or
// freed clusters (there is no unmount). An unknown
// count is 0xFFFFFFFF, so others recount.
// Allocation checks the FAT itself.
fn validFsInfo(s: *const [sector_size]u8) bool {
    return std.mem.readInt(u32, s[0..4], .little) == 0x41615252 and
        std.mem.readInt(u32, s[484..488], .little) == 0x61417272;
}

// Also every operation's end for the kept FAT sectors;
// an error: the operation reported
// a failing disk, or write does.
fn flushFsInfo(v: *Volume) void {
    flushFat(v) catch {};
    if (!v.fsinfo_dirty or v.kind != .fat32 or v.fsinfo == 0) return;
    v.fsinfo_dirty = false;
    const s = sector(v, v.fsinfo) catch return;
    if (!validFsInfo(s)) return;
    std.mem.writeInt(u32, s[488..492], v.free_clusters orelse 0xFFFF_FFFF, .little);
    const hint = if (v.next_free >= 2 and v.next_free <= v.cluster_count + 1) v.next_free else 0xFFFF_FFFF; // no hint
    std.mem.writeInt(u32, s[492..496], hint, .little);
    writeBack(v, v.fsinfo, s) catch {}; // the operation itself reported a failing disk
}

// Marked as a chain's end and linked after prev (if not 0).
fn allocCluster(v: *Volume, prev: u32) Error!u32 {
    const total = v.cluster_count;
    var c = if (v.next_free >= 2 and v.next_free <= total + 1) v.next_free else 2;
    var n: u32 = 0;
    while (n < total) : (n += 1) {
        const val = try fatGet(v, c); // a read error is not "disk full"
        if (val == 0) {
            try fatSet(v, c, eocValue(v));
            if (prev != 0) try fatSet(v, prev, c);
            if (v.free_clusters) |*f| f.* -|= 1;
            v.next_free = c + 1;
            v.fsinfo_dirty = true;
            return c;
        }
        c = if (c >= total + 1) 2 else c + 1;
    }
    return error.DiskFull; // every entry read, none free
}

fn freeChain(v: *Volume, first: u32) Error!void {
    var c = first;
    var n: u32 = 0;
    while (!v.isEnd(c) and n <= v.cluster_count) : (n += 1) {
        const next = try fatGet(v, c);
        try fatSet(v, c, 0);
        if (v.free_clusters) |*f| f.* += 1;
        if (c < v.next_free) v.next_free = c;
        v.fsinfo_dirty = true;
        c = next;
    }
}

// Zeroed: no entries.
fn allocDirCluster(v: *Volume, prev: u32) Error!u32 {
    const c = try allocCluster(v, prev);
    const zero = [_]u8{0} ** sector_size;
    const first = try v.clusterSector(c);
    var i: u32 = 0;
    while (i < v.sectors_per_cluster) : (i += 1) {
        try devWrite(v, first + i, 1, &zero);
    }
    invalidate(v, first, v.sectors_per_cluster);
    return c;
}

var count_buf: [32 * 1024]u8 = undefined;

fn countFree(v: *Volume) Error!u32 {
    if (v.free_clusters) |f| return f;
    var free: u32 = 0;
    const bytes_per_entry: u32 = switch (v.kind) {
        .fat12 => 0,
        .fat16 => 2,
        .fat32 => 4,
    };
    const fat_first = firstFat(v);
    if (v.kind == .fat12) {
        // Small enough to go through the cache entry by entry:
        var c: u32 = 2;
        while (c < v.cluster_count + 2) : (c += 1) {
            if (try fatGet(v, c) == 0) free += 1;
        }
    } else {
        const chunk_sectors = count_buf.len / sector_size;
        const needed = (@as(u64, v.cluster_count) + 2) * bytes_per_entry;
        var done: u64 = 0; // bytes of FAT looked at
        while (done < needed) {
            const n: usize = @intCast(@min(chunk_sectors, (needed - done + sector_size - 1) / sector_size));
            try devRead(v, fat_first + done / sector_size, n, count_buf[0 .. n * sector_size]);
            var off: usize = 0;
            while (off < n * sector_size and done + off < needed) : (off += bytes_per_entry) {
                const entry_no = (done + off) / bytes_per_entry;
                if (entry_no < 2) continue;
                const val = if (v.kind == .fat16)
                    std.mem.readInt(u16, count_buf[off..][0..2], .little)
                else
                    std.mem.readInt(u32, count_buf[off..][0..4], .little) & 0x0FFF_FFFF;
                if (val == 0) free += 1;
            }
            done += n * sector_size;
        }
    }
    v.free_clusters = free;
    return free;
}

// DIRECTORY SLOTS
//
// 32-byte slots: short entries, their long-name pieces before
// them, deleted (0xE5) and unused (0x00, the end). A directory
// is named by its first cluster; 0 is the fixed root.

const Loc = struct { rel: u64, off: u16 };

const SlotIter = struct {
    v: *Volume,
    dir: u32,
    index: u32 = 0,
    cluster: u32 = 0, // after next: the cluster of the slot it returned
    placed: bool = false, // cluster already holds slot index (see iterAt)

    // Then moves on; null after the last.
    // extend: add a cluster at the end.
    fn next(it: *SlotIter, extend: bool) Error!?Loc {
        const v = it.v;
        if (it.dir == 0) {
            if (it.index >= v.root_entries) return null;
            const loc: Loc = .{ .rel = v.root_start + it.index / 16, .off = @intCast((it.index % 16) * 32) };
            it.index += 1;
            return loc;
        }
        const per_cluster = v.cluster_bytes / 32;
        if (it.placed) {
            it.placed = false;
        } else if (it.index == 0) {
            it.cluster = it.dir;
        } else if (it.index % per_cluster == 0) {
            const nxt = try fatGet(v, it.cluster);
            if (v.isEnd(nxt)) {
                if (!extend) return null;
                it.cluster = try allocDirCluster(v, it.cluster);
            } else it.cluster = nxt;
        }
        if (it.index >= 65536) return null; // FAT's limit for one directory
        const in_cluster = it.index % per_cluster;
        const loc: Loc = .{ .rel = (try v.clusterSector(it.cluster)) + in_cluster / 16, .off = @intCast((in_cluster % 16) * 32) };
        it.index += 1;
        return loc;
    }
};

// index is in cluster (as a SlotIter reported it):
// no walk from the start.
fn iterAt(v: *Volume, dir: u32, index: u32, cluster: u32) SlotIter {
    return .{ .v = v, .dir = dir, .index = index, .cluster = cluster, .placed = dir != 0 and index != 0 };
}

fn readSlot(v: *const Volume, loc: Loc) Error![32]u8 {
    const s = try sector(v, loc.rel);
    return s[loc.off..][0..32].*;
}

fn writeSlot(v: *const Volume, loc: Loc, slot: *const [32]u8) Error!void {
    const s = try sector(v, loc.rel);
    s[loc.off..][0..32].* = slot.*;
    return writeBack(v, loc.rel, s);
}

// index was seen before: missing means a damaged directory.
fn slotAt(v: *Volume, dir: u32, index: u32) Error!Loc {
    var it: SlotIter = .{ .v = v, .dir = dir };
    if (dir == 0) {
        it.index = index;
        return (try it.next(false)) orelse error.DeviceError;
    }
    // Skip whole clusters:
    const per_cluster = v.cluster_bytes / 32;
    var c = dir;
    var n = index / per_cluster;
    while (n > 0) : (n -= 1) {
        c = try fatGet(v, c);
        if (v.isEnd(c)) return error.DeviceError;
    }
    const in_cluster = index % per_cluster;
    return .{ .rel = (try v.clusterSector(c)) + in_cluster / 16, .off = @intCast((in_cluster % 16) * 32) };
}

const attr_read_only = 0x01;
const attr_system = 0x04;
const attr_volume_id = 0x08;
const attr_directory = 0x10;
const attr_archive = 0x20;
const attr_long_name = 0x0F;

const Found = struct {
    name_buf: [platform.max_name]u8 = undefined,
    name_len: usize = 0,
    raw: [32]u8 = undefined, // the short-name slot
    first_index: u32 = 0, // first slot (long-name pieces come first)
    index: u32 = 0, // the short-name slot
    // Unused in the fixed root:
    first_cluster: u32 = 0,
    short_cluster: u32 = 0,

    fn name(f: *const Found) []const u8 {
        return f.name_buf[0..f.name_len];
    }
    fn isDir(f: *const Found) bool {
        return f.raw[11] & attr_directory != 0;
    }
    fn cluster(f: *const Found, v: *const Volume) u32 {
        return clusterOf(v, &f.raw);
    }
    fn size(f: *const Found) u32 {
        return std.mem.readInt(u32, f.raw[28..32], .little);
    }
};

fn clusterOf(v: *const Volume, raw: *const [32]u8) u32 {
    const lo: u32 = std.mem.readInt(u16, raw[26..28], .little);
    const hi: u32 = if (v.kind == .fat32) std.mem.readInt(u16, raw[20..22], .little) else 0;
    return hi << 16 | lo;
}

fn setCluster(raw: *[32]u8, c: u32) void {
    std.mem.writeInt(u16, raw[26..28], @truncate(c), .little);
    std.mem.writeInt(u16, raw[20..22], @truncate(c >> 16), .little);
}

// Skips deleted slots and labels; false at the end.
// An unreadable slot is an error, not the end.
fn nextEntry(it: *SlotIter, out: *Found) Error!bool {
    var lfn: [260]u16 = undefined;
    var lfn_ok = false; // a complete, unbroken sequence of pieces so far
    var lfn_count: u8 = 0; // pieces announced by the first one
    var lfn_expect: u8 = 0; // ordinal of the next piece; 0: all seen
    var lfn_sum: u8 = 0;
    var lfn_first: u32 = 0;
    var lfn_first_cluster: u32 = 0;
    while (true) {
        const index = it.index;
        const loc = (try it.next(false)) orelse return false;
        const cluster = it.cluster;
        const slot = try readSlot(it.v, loc);
        if (slot[0] == 0x00) return false;
        if (slot[0] == 0xE5) {
            lfn_ok = false;
            continue;
        }
        const attr = slot[11];
        if (attr & 0x3F == attr_long_name) {
            const ord = slot[0] & 0x1F;
            if (slot[0] & 0x40 != 0) {
                if (ord == 0 or ord > 20) {
                    lfn_ok = false;
                    continue;
                }
                lfn_ok = true;
                lfn_count = ord;
                lfn_sum = slot[13];
                lfn_first = index;
                lfn_first_cluster = cluster;
                @memset(lfn[0 .. @as(usize, ord) * 13], 0xFFFF);
            } else if (!lfn_ok or ord != lfn_expect or slot[13] != lfn_sum) {
                lfn_ok = false;
                continue;
            }
            const base = (@as(usize, ord) - 1) * 13;
            const offsets = [13]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
            for (offsets, 0..) |o, i| lfn[base + i] = std.mem.readInt(u16, slot[o..][0..2], .little);
            lfn_expect = ord - 1;
            continue;
        }
        if (attr & attr_volume_id != 0) {
            lfn_ok = false;
            continue;
        }

        out.raw = slot;
        out.index = index;
        out.first_index = index;
        out.short_cluster = cluster;
        out.first_cluster = cluster;
        out.name_len = 0;
        if (lfn_ok and lfn_expect == 0 and checksum(slot[0..11]) == lfn_sum) {
            var len: usize = 0;
            while (len < @as(usize, lfn_count) * 13 and lfn[len] != 0 and lfn[len] != 0xFFFF) len += 1;
            if (std.unicode.utf16LeToUtf8(&out.name_buf, lfn[0..len])) |n| {
                out.name_len = n;
                out.first_index = lfn_first;
                out.first_cluster = lfn_first_cluster;
            } else |_| {}
        }
        if (out.name_len == 0) out.name_len = shortName(&slot, &out.name_buf);
        return true;
    }
}

fn checksum(sfn: *const [11]u8) u8 {
    var sum: u8 = 0;
    for (sfn) |b| sum = ((sum & 1) << 7) +% (sum >> 1) +% b;
    return sum;
}

// "README  TXT" -> "README.TXT"; NT's lower-case flags apply.
fn shortName(slot: *const [32]u8, out: []u8) usize {
    var n: usize = 0;
    const lower_base = slot[12] & 0x08 != 0;
    const lower_ext = slot[12] & 0x10 != 0;
    var base_len: usize = 8;
    while (base_len > 0 and slot[base_len - 1] == ' ') base_len -= 1;
    var ext_len: usize = 3;
    while (ext_len > 0 and slot[8 + ext_len - 1] == ' ') ext_len -= 1;
    for (0..base_len) |i| {
        var b = slot[i];
        if (i == 0 and b == 0x05) b = 0xE5;
        n += putChar(out[n..], b, lower_base);
    }
    if (ext_len > 0) {
        out[n] = '.';
        n += 1;
        for (0..ext_len) |i| n += putChar(out[n..], slot[8 + i], lower_ext);
    }
    return n;
}

// CP437, as DOS wrote it; lower-cased
// after decoding, as NT does.
fn putChar(out: []u8, b: u8, lower: bool) usize {
    const c = cp437.toUnicode(b);
    return std.unicode.utf8Encode(if (lower) lowerChar(c) else c, out) catch 0;
}

// Capitals of CP437's scripts (ASCII,
// Latin-1, Greek) and Cyrillic to lower case.
fn lowerChar(c: u21) u21 {
    return switch (c) {
        'A'...'Z' => c + 32,
        0xC0...0xD6, 0xD8...0xDE => c + 32, // Latin-1, not U+00D7 (multiplication sign)
        0x391...0x3A1, 0x3A3...0x3A9 => c + 32, // Greek, U+03A2 is unassigned
        0x410...0x42F => c + 32, // Cyrillic А-Я
        0x400...0x40F => c + 80, // Cyrillic Ѐ-Џ
        else => c,
    };
}

fn sameName(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

// PATHS

fn isSep(c: u8) bool {
    return c == '\\' or c == '/';
}

// Its name and its short name ("PROGRA~1").
fn matches(f: *const Found, name: []const u8) bool {
    if (sameName(f.name(), name)) return true;
    var short: [32]u8 = undefined;
    const n = shortName(&f.raw, &short);
    return sameName(short[0..n], name);
}

fn lookup(v: *Volume, dir: u32, name: []const u8, out: *Found) Error!bool {
    if (try completeIndex(v, dir)) |idx| return indexLookup(v, dir, idx, name, out);
    // The index can't hold the directory: read it all:
    var it: SlotIter = .{ .v = v, .dir = dir };
    while (try nextEntry(&it, out)) {
        if (matches(out, name)) return true;
    }
    return false;
}

// DIRECTORY INDEXES
//
// Long and short names, hashed ignoring ASCII case, point at
// each entry's slot and cluster. Entries never move, and a
// lookup checks the entry, so a stale index entry only misses.
// Complete once it holds the whole directory; create, remove
// and rename keep it so.
// A deleted directory's index is dropped.

const dir_index_slots = 32;
const name_index_slots = 4096; // a power of two; 80 KiB: about 3500 names
const NameState = enum(u8) { empty, tombstone, used };
const NameEntry = struct {
    state: NameState = .empty,
    id: u32 = 0, // the DirIndex's
    hash: u32 = 0,
    first: u32 = 0, // the entry's first slot
    cluster: u32 = 0, // the cluster that slot is in
};
const DirIndex = struct {
    dev: ?*const anyopaque = null,
    start: u64 = 0,
    dir: u32 = 0,
    id: u32 = 0,
    complete: bool = false,
    used_at: u64 = 0,
};
var names = [_]NameEntry{.{}} ** name_index_slots;
var names_empty: usize = name_index_slots; // slots never used since the last clear
var dir_indexes = [_]DirIndex{.{}} ** dir_index_slots;
var dir_index_clock: u64 = 0;
var next_dir_index_id: u32 = 0;

fn nameHash(id: u32, name: []const u8) u32 {
    var h: u64 = 14695981039346656037;
    h = (h ^ @as(u64, id)) *% 1099511628211;
    for (name) |c| h = (h ^ @as(u64, std.ascii.toLower(c))) *% 1099511628211;
    return @truncate(h ^ (h >> 32));
}

fn dirIndex(v: *const Volume, dir: u32) ?*DirIndex {
    for (&dir_indexes) |*d| {
        if (d.dev == v.dev.ctx and d.start == v.start and d.dir == dir) {
            dir_index_clock +%= 1;
            d.used_at = dir_index_clock;
            return d;
        }
    }
    return null;
}

fn ensureDirIndex(v: *const Volume, dir: u32) *DirIndex {
    if (dirIndex(v, dir)) |d| return d;
    var chosen: ?*DirIndex = null;
    for (&dir_indexes) |*d| {
        if (d.dev == null) {
            chosen = d;
            break;
        }
        if (chosen == null or d.used_at < chosen.?.used_at) chosen = d;
    }
    const d = chosen.?;
    removeDirIndex(d);
    next_dir_index_id +%= 1;
    if (next_dir_index_id == 0) next_dir_index_id = 1;
    dir_index_clock +%= 1;
    d.* = .{ .dev = v.dev.ctx, .start = v.start, .dir = dir, .id = next_dir_index_id, .used_at = dir_index_clock };
    return d;
}

fn removeDirIndex(d: *DirIndex) void {
    if (d.id != 0) {
        for (&names) |*e| {
            if (e.state == .used and e.id == d.id) e.state = .tombstone;
        }
    }
    d.* = .{};
}

// Removed entries become tombstones and a probe stops only at
// an empty slot: when few are left, every
// slot is emptied and every index dropped.
fn clearNameIndex() void {
    for (&names) |*e| e.state = .empty;
    for (&dir_indexes) |*d| d.* = .{};
    names_empty = name_index_slots;
}

fn nameFind(id: u32, hash: u32, first: u32) ?usize {
    var slot: usize = hash & (name_index_slots - 1);
    for (0..name_index_slots) |_| {
        const e = &names[slot];
        if (e.state == .empty) return null;
        if (e.state == .used and e.id == id and e.hash == hash and e.first == first) return slot;
        slot = (slot + 1) & (name_index_slots - 1);
    }
    return null;
}

// False if the table is full (the index is then incomplete).
fn namePut(d: *DirIndex, name: []const u8, first: u32, cluster: u32) bool {
    const hash = nameHash(d.id, name);
    if (nameFind(d.id, hash, first)) |at| {
        names[at].cluster = cluster;
        return true;
    }
    var slot: usize = hash & (name_index_slots - 1);
    var tombstone: ?usize = null;
    for (0..name_index_slots) |_| {
        const e = &names[slot];
        if (e.state == .tombstone and tombstone == null) tombstone = slot;
        if (e.state == .empty) break;
        slot = (slot + 1) & (name_index_slots - 1);
    } else if (tombstone == null) {
        d.complete = false;
        return false;
    }
    if (tombstone == null) names_empty -= 1;
    names[tombstone orelse slot] = .{ .state = .used, .id = d.id, .hash = hash, .first = first, .cluster = cluster };
    return true;
}

fn nameRemove(d: *DirIndex, name: []const u8, first: u32) void {
    if (nameFind(d.id, nameHash(d.id, name), first)) |at| names[at].state = .tombstone;
}

// And under its short name if that differs.
fn indexEntry(d: *DirIndex, f: *const Found) bool {
    if (!namePut(d, f.name(), f.first_index, f.first_cluster)) return false;
    var short: [32]u8 = undefined;
    const n = shortName(&f.raw, &short);
    if (sameName(short[0..n], f.name())) return true;
    return namePut(d, short[0..n], f.first_index, f.first_cluster);
}

fn unindexEntry(d: *DirIndex, f: *const Found) void {
    nameRemove(d, f.name(), f.first_index);
    var short: [32]u8 = undefined;
    const n = shortName(&f.raw, &short);
    if (!sameName(short[0..n], f.name())) nameRemove(d, short[0..n], f.first_index);
}

// Null if the table can't hold it.
fn completeIndex(v: *Volume, dir: u32) Error!?*DirIndex {
    if (dirIndex(v, dir)) |d| {
        if (d.complete) return d;
    }
    // With few empty slots left every probe gets long:
    // start afresh; dropped indexes are rebuilt when next used:
    if (names_empty < name_index_slots / 8) clearNameIndex();
    const d = ensureDirIndex(v, dir);
    d.complete = false;
    var complete = true;
    var it: SlotIter = .{ .v = v, .dir = dir };
    var f: Found = .{};
    while (try nextEntry(&it, &f)) {
        if (!indexEntry(d, &f)) complete = false;
    }
    d.complete = complete;
    return if (complete) d else null;
}

// The first entry in the directory that really
// has the name, as a full read would find.
fn indexLookup(v: *Volume, dir: u32, d: *const DirIndex, name: []const u8, out: *Found) Error!bool {
    const hash = nameHash(d.id, name);
    var slot: usize = hash & (name_index_slots - 1);
    var best: ?u32 = null;
    for (0..name_index_slots) |_| {
        const e = names[slot];
        if (e.state == .empty) break;
        slot = (slot + 1) & (name_index_slots - 1);
        if (e.state != .used or e.id != d.id or e.hash != hash) continue;
        if (best != null and e.first >= best.?) continue;
        var it = iterAt(v, dir, e.first, e.cluster);
        var f: Found = .{};
        if (!try nextEntry(&it, &f) or f.first_index != e.first) continue; // changed since
        if (!matches(&f, name)) continue;
        best = e.first;
        out.* = f;
    }
    return best != null;
}

fn indexAdded(v: *const Volume, dir: u32, f: *const Found) void {
    const d = dirIndex(v, dir) orelse return;
    if (d.complete and !indexEntry(d, f)) d.complete = false;
}

fn indexRemoved(v: *const Volume, dir: u32, f: *const Found) void {
    // From an incomplete index too:
    // its rebuild keeps what is in it:
    if (dirIndex(v, dir)) |d| unindexEntry(d, f);
}

// DIRECTORY CURSORS
//
// Where addEntry looks for free slots first:
// its last entry's slot. Every free run before it
// is shorter than bound, so it is searched only
// for a smaller entry.

const dir_cursor_slots = 32;
const DirCursor = struct {
    dev: ?*const anyopaque = null,
    start: u64 = 0,
    dir: u32 = 0,
    pos: u32 = 0,
    cluster: u32 = 0, // the cluster slot pos is in
    bound: u32 = 0,
};
var dir_cursors = [_]DirCursor{.{}} ** dir_cursor_slots;
var next_dir_cursor: usize = 0;

fn dirCursor(v: *const Volume, dir: u32) *DirCursor {
    for (&dir_cursors) |*c| {
        if (c.dev == v.dev.ctx and c.start == v.start and c.dir == dir) return c;
    }
    const c = &dir_cursors[next_dir_cursor];
    next_dir_cursor = (next_dir_cursor + 1) % dir_cursor_slots;
    c.* = .{ .dev = v.dev.ctx, .start = v.start, .dir = dir };
    return c;
}

// Gone, or new in a cluster another one had.
fn forgetDir(v: *const Volume, dir: u32) void {
    if (dirIndex(v, dir)) |d| removeDirIndex(d);
    for (&dir_cursors) |*c| {
        if (c.dev == v.dev.ctx and c.start == v.start and c.dir == dir) c.* = .{};
    }
}

// The root, or an entry in some directory.
const Target = struct {
    parent: u32, // directory reference of the containing directory
    found: Found = .{},
    is_root: bool = false,
};

// NotFound: the last component is missing;
// PathNotFound: a directory before it.
fn resolve(v: *Volume, path: []const u8, out: *Target) Error!void {
    out.parent = v.root();
    out.is_root = true;
    var dir = v.root();
    var it = std.mem.tokenizeAny(u8, path, "\\/");
    while (it.next()) |comp| {
        if (!out.is_root and !out.found.isDir()) return error.NotADirectory;
        if (!try lookup(v, dir, comp, &out.found)) {
            return if (it.peek() == null) error.NotFound else error.PathNotFound;
        }
        out.parent = dir;
        out.is_root = false;
        dir = v.dirRef(out.found.cluster(v));
    }
}

// "\A\B\C" -> "\A\B"'s reference and "C"
fn parentOf(v: *Volume, path: []const u8, dir: *u32) Error![]const u8 {
    var end = path.len;
    while (end > 0 and isSep(path[end - 1])) end -= 1;
    var cut = end;
    while (cut > 0 and !isSep(path[cut - 1])) cut -= 1;
    const name = path[cut..end];
    if (name.len == 0) return error.InvalidName;
    var t: Target = undefined;
    resolve(v, path[0..cut], &t) catch |err| return switch (err) {
        error.NotFound => error.PathNotFound,
        else => err,
    };
    if (!t.is_root and !t.found.isDir()) return error.NotADirectory;
    dir.* = if (t.is_root) v.root() else v.dirRef(t.found.cluster(v));
    return name;
}

// CREATING ENTRIES

fn now() platform.DateTime {
    return platform.clock.now() orelse .{ .year = 1980, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 };
}

fn dosDate(t: platform.DateTime) u16 {
    const y: u16 = if (t.year < 1980) 0 else @min(t.year - 1980, 127);
    return y << 9 | @as(u16, t.month) << 5 | t.day;
}

fn dosTime(t: platform.DateTime) u16 {
    return @as(u16, t.hour) << 11 | @as(u16, t.minute) << 5 | t.second / 2;
}

fn stampModified(raw: *[32]u8) void {
    const t = now();
    std.mem.writeInt(u16, raw[22..24], dosTime(t), .little);
    std.mem.writeInt(u16, raw[24..26], dosDate(t), .little);
    std.mem.writeInt(u16, raw[18..20], dosDate(t), .little); // accessed
}

fn newRaw(attr: u8, cluster: u32) [32]u8 {
    var raw = [_]u8{0} ** 32;
    raw[11] = attr;
    setCluster(&raw, cluster);
    const t = now();
    std.mem.writeInt(u16, raw[14..16], dosTime(t), .little); // created
    std.mem.writeInt(u16, raw[16..18], dosDate(t), .little);
    stampModified(&raw);
    return raw;
}

const short_specials = "$%'-_@~`!(){}^#&";

fn shortChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, short_specials, c) != null;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |c| {
        if (c < 0x20 or std.mem.indexOfScalar(u8, "\"*/:<>?\\|", c) != null) return false;
    }
    return true;
}

// A valid 8.3 name needs no long-name entries. All lower case
// names (per part) get NT's lower-case flags.
fn exactShortName(name: []const u8, sfn: *[11]u8, flags: *u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const base = if (dot) |d| name[0..d] else name;
    const ext = if (dot) |d| name[d + 1 ..] else "";
    if (base.len == 0 or base.len > 8 or ext.len > 3 or (dot != null and ext.len == 0)) return false;
    var case_flags: u8 = 0;
    for ([2][]const u8{ base, ext }, [2]u8{ 0x08, 0x10 }) |part, flag| {
        var upper = false;
        var lower = false;
        for (part) |c| {
            if (!shortChar(c)) return false;
            if (std.ascii.isUpper(c)) upper = true;
            if (std.ascii.isLower(c)) lower = true;
        }
        if (upper and lower) return false;
        if (lower) case_flags |= flag;
    }
    sfn.* = "           ".*;
    for (base, 0..) |c, i| sfn[i] = std.ascii.toUpper(c);
    for (ext, 0..) |c, i| sfn[8 + i] = std.ascii.toUpper(c);
    flags.* = case_flags;
    return true;
}

// "My Long Name.html" -> "MYLONG~1.HTM"
fn makeAlias(v: *Volume, dir: u32, name: []const u8, sfn: *[11]u8) Error!void {
    var base: [8]u8 = undefined;
    var base_len: usize = 0;
    var ext: [3]u8 = undefined;
    var ext_len: usize = 0;
    const dot = std.mem.lastIndexOfScalar(u8, name, '.');
    const base_part = if (dot) |d| if (d > 0) name[0..d] else name else name;
    const ext_part = if (dot) |d| if (d > 0) name[d + 1 ..] else "" else "";
    for (base_part) |c| {
        if (c == ' ' or c == '.') continue;
        if (base_len == base.len) break;
        base[base_len] = if (c < 0x80 and shortChar(c)) std.ascii.toUpper(c) else '_';
        base_len += 1;
    }
    for (ext_part) |c| {
        if (c == ' ' or c == '.') continue;
        if (ext_len == ext.len) break;
        ext[ext_len] = if (c < 0x80 and shortChar(c)) std.ascii.toUpper(c) else '_';
        ext_len += 1;
    }
    if (base_len == 0) {
        base[0] = '_';
        base_len = 1;
    }
    var n: u32 = 1;
    while (n < 1_000_000) : (n += 1) {
        var tail_buf: [8]u8 = undefined;
        const tail = std.fmt.bufPrint(&tail_buf, "~{d}", .{n}) catch unreachable;
        const keep = @min(base_len, 8 - tail.len);
        sfn.* = "           ".*;
        @memcpy(sfn[0..keep], base[0..keep]);
        @memcpy(sfn[keep..][0..tail.len], tail);
        @memcpy(sfn[8..][0..ext_len], ext[0..ext_len]);
        if (!try shortNameUsed(v, dir, sfn)) return;
    }
    return error.AlreadyExists; // every alias taken
}

fn shortNameUsed(v: *Volume, dir: u32, sfn: *const [11]u8) Error!bool {
    if (try completeIndex(v, dir)) |d| {
        // Indexed as "NAME.EXT"; the slot must match exactly:
        var probe = [_]u8{0} ** 32;
        @memcpy(probe[0..11], sfn);
        var text: [32]u8 = undefined;
        const n = shortName(&probe, &text);
        const hash = nameHash(d.id, text[0..n]);
        var slot: usize = hash & (name_index_slots - 1);
        for (0..name_index_slots) |_| {
            const e = names[slot];
            if (e.state == .empty) break;
            slot = (slot + 1) & (name_index_slots - 1);
            if (e.state != .used or e.id != d.id or e.hash != hash) continue;
            var it = iterAt(v, dir, e.first, e.cluster);
            var f: Found = .{};
            if (!try nextEntry(&it, &f) or f.first_index != e.first) continue;
            if (std.mem.eql(u8, f.raw[0..11], sfn)) return true;
        }
        return false;
    }
    var it: SlotIter = .{ .v = v, .dir = dir };
    while (try it.next(false)) |loc| {
        const slot = try readSlot(v, loc);
        if (slot[0] == 0) return false;
        if (slot[0] == 0xE5 or slot[11] & 0x3F == attr_long_name) continue;
        if (std.mem.eql(u8, slot[0..11], sfn)) return true;
    }
    return false;
}

// needed free slots in a row (not past limit); null if none.
// extend: grow the directory at its end.
fn findFreeRun(it0: SlotIter, needed: u32, limit: ?u32, extend: bool) Error!?struct { start: u32, cluster: u32 } {
    var it = it0;
    var run: u32 = 0;
    var run_start: u32 = 0;
    var run_cluster: u32 = 0;
    while (run < needed) {
        const index = it.index;
        if (limit) |l| if (index >= l) return null;
        const loc = (try it.next(extend)) orelse return null;
        const slot = try readSlot(it.v, loc);
        if (slot[0] == 0x00 or slot[0] == 0xE5) {
            if (run == 0) {
                run_start = index;
                run_cluster = it.cluster;
            }
            run += 1;
        } else run = 0;
    }
    return .{ .start = run_start, .cluster = run_cluster };
}

const Added = struct { index: u32, cluster: u32 };

// The rest of the short entry is template's.
// Returns the short slot. The caller checked the
// name is free; a long name's alias is checked here.
fn addEntry(v: *Volume, dir: u32, raw_name: []const u8, template: *const [32]u8) Error!Added {
    // Windows drops trailing dots and spaces:
    var name = raw_name;
    while (name.len > 0 and (name[name.len - 1] == '.' or name[name.len - 1] == ' ')) name = name[0 .. name.len - 1];
    if (!validName(name)) return error.InvalidName;

    var raw = template.*;
    var sfn: [11]u8 = undefined;
    var flags: u8 = 0;
    var units: [256]u16 = undefined;
    var unit_count: usize = 0;
    const long = !exactShortName(name, &sfn, &flags);
    if (long) {
        unit_count = std.unicode.utf8ToUtf16Le(&units, name) catch return error.InvalidName;
        if (unit_count > 255) return error.InvalidName;
        try makeAlias(v, dir, name, &sfn);
    } else if (try shortNameUsed(v, dir, &sfn)) {
        return error.AlreadyExists;
    }
    @memcpy(raw[0..11], &sfn);
    if (raw[0] == 0xE5) raw[0] = 0x05;
    raw[12] = flags;

    // Free slots from the cursor on, growing the
    // directory if needed; before it only if a run there
    // could be long enough:
    const pieces: u32 = @intCast((unit_count + 12) / 13);
    const needed = pieces + 1;
    const cursor = dirCursor(v, dir);
    const before = if (cursor.pos != 0 and needed < cursor.bound)
        try findFreeRun(.{ .v = v, .dir = dir }, needed, cursor.pos, false)
    else
        null;
    // No more slots: a full fixed root or FAT's limit:
    const run = before orelse (try findFreeRun(iterAt(v, dir, cursor.pos, cursor.cluster), needed, null, true)) orelse
        return error.DiskFull;
    // Every free run before it was shorter:
    cursor.pos = run.start;
    cursor.cluster = run.cluster;
    cursor.bound = needed;

    // The long-name pieces, last first, then the short entry:
    var w = iterAt(v, dir, run.start, run.cluster);
    const sum = checksum(raw[0..11]);
    var p: u32 = 0;
    while (p < pieces) : (p += 1) {
        const ord = pieces - p; // 1-based number of this piece
        var slot = [_]u8{0} ** 32;
        slot[0] = @intCast(ord | (if (p == 0) @as(u32, 0x40) else 0));
        slot[11] = attr_long_name;
        slot[13] = sum;
        const offsets = [13]usize{ 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30 };
        for (offsets, 0..) |o, i| {
            const at = (ord - 1) * 13 + i;
            const unit: u16 = if (at < unit_count) units[at] else if (at == unit_count) 0 else 0xFFFF;
            std.mem.writeInt(u16, slot[o..][0..2], unit, .little);
        }
        try writeSlot(v, (try w.next(false)) orelse return error.DeviceError, &slot);
    }
    try writeSlot(v, (try w.next(false)) orelse return error.DeviceError, &raw);
    const added: Added = .{ .index = run.start + pieces, .cluster = w.cluster };

    // Into the index, as a read of the directory would find it:
    var f: Found = .{ .raw = raw, .first_index = run.start, .index = added.index, .first_cluster = run.cluster, .short_cluster = added.cluster };
    const n = @min(name.len, f.name_buf.len);
    @memcpy(f.name_buf[0..n], name[0..n]);
    f.name_len = n;
    if (!long) f.name_len = shortName(&raw, &f.name_buf);
    indexAdded(v, dir, &f);
    return added;
}

// Long-name pieces and short entry.
fn removeEntry(v: *Volume, dir: u32, f: *const Found) Error!void {
    var it = iterAt(v, dir, f.first_index, f.first_cluster);
    var i = f.first_index;
    while (i <= f.index) : (i += 1) {
        const loc = (try it.next(false)) orelse return error.DeviceError;
        var slot = try readSlot(v, loc);
        slot[0] = 0xE5;
        try writeSlot(v, loc, &slot);
    }
    indexRemoved(v, dir, f);
    // The freed slots are found again by the next addEntry:
    const cursor = dirCursor(v, dir);
    if (f.first_index < cursor.pos) {
        cursor.pos = f.first_index;
        cursor.cluster = f.first_cluster;
    }
}

fn entryLoc(v: *Volume, dir: u32, f: *const Found) Error!Loc {
    var it = iterAt(v, dir, f.index, f.short_cluster);
    return (try it.next(false)) orelse error.DeviceError;
}

// VOLUME INFORMATION

pub fn label(v: *Volume, out: []u8) usize {
    // The root directory's label wins over the boot sector's copy:
    var raw: [11]u8 = v.bpb_label;
    var it: SlotIter = .{ .v = v, .dir = v.root() };
    while (it.next(false) catch null) |loc| {
        const slot = readSlot(v, loc) catch break;
        if (slot[0] == 0) break;
        if (slot[0] == 0xE5 or slot[11] & 0x3F == attr_long_name) continue;
        if (slot[11] & attr_volume_id != 0) {
            raw = slot[0..11].*;
            break;
        }
    }
    if (std.mem.eql(u8, &raw, "NO NAME    ")) return 0;
    var len: usize = 11;
    while (len > 0 and raw[len - 1] == ' ') len -= 1;
    var n: usize = 0;
    for (raw[0..len]) |b| n += std.unicode.utf8Encode(cp437.toUnicode(b), out[n..]) catch break;
    return n;
}

// In the root's label entry, which DOS and Windows read
// ("" removes it); the boot sector's copy stays, as ZDOS
// never writes boot sectors. Must fit 11 CP437 characters;
// the caller checks the rest.
pub fn setLabel(v: *Volume, new_label: []const u8) Error!void {
    defer finish(v); // the directory may grow, clusters be freed
    var raw11 = [_]u8{' '} ** 11;
    var n: usize = 0;
    var view = std.unicode.Utf8View.init(new_label) catch return error.InvalidName;
    var it = view.iterator();
    while (it.nextCodepoint()) |c| {
        if (n == 11) return error.InvalidName;
        const b = cp437.fromUnicode(c) orelse return error.InvalidName;
        raw11[n] = if (b < 0x80) std.ascii.toUpper(b) else b;
        n += 1;
    }

    // The label entry, and the first free slot for a new one:
    var label_loc: ?Loc = null;
    var free_index: ?u32 = null;
    var iter: SlotIter = .{ .v = v, .dir = v.root() };
    while (true) {
        const index = iter.index;
        const loc = (try iter.next(false)) orelse break;
        const slot = try readSlot(v, loc);
        if (slot[0] == 0x00) {
            if (free_index == null) free_index = index;
            break;
        }
        if (slot[0] == 0xE5) {
            if (free_index == null) free_index = index;
            continue;
        }
        if (slot[11] & 0x3F == attr_long_name) continue;
        if (slot[11] & attr_volume_id != 0) {
            label_loc = loc;
            break;
        }
    }

    if (n == 0) {
        const loc = label_loc orelse return; // nothing to remove
        var slot = try readSlot(v, loc);
        slot[0] = 0xE5;
        return writeSlot(v, loc, &slot);
    }
    if (label_loc) |loc| {
        var slot = try readSlot(v, loc);
        @memcpy(slot[0..11], &raw11);
        stampModified(&slot);
        return writeSlot(v, loc, &slot);
    }
    // A new entry: in a free slot, or (FAT32) a new root cluster:
    var raw = newRaw(attr_volume_id, 0);
    @memcpy(raw[0..11], &raw11);
    const loc = if (free_index) |i| try slotAt(v, v.root(), i) else blk: {
        var grow: SlotIter = .{ .v = v, .dir = v.root() };
        while (try grow.next(true)) |l| {
            const slot = try readSlot(v, l);
            if (slot[0] == 0x00 or slot[0] == 0xE5) break :blk l;
        }
        return error.DiskFull; // full fixed root (FAT12/16)
    };
    return writeSlot(v, loc, &raw);
}

pub fn fsName(v: *const Volume) []const u8 {
    return switch (v.kind) {
        .fat12 => "FAT12",
        .fat16 => "FAT16",
        .fat32 => "FAT32",
    };
}

pub fn blockBytes(v: *const Volume) u32 {
    return v.cluster_bytes;
}

pub fn sizeBytes(v: *const Volume) u64 {
    return @as(u64, v.cluster_count) * v.cluster_bytes;
}

pub fn freeBytes(v: *Volume) u64 {
    return @as(u64, countFree(v) catch 0) * v.cluster_bytes;
}

// ENTRIES

// name and raw: the entry's name and its short-name slot.
fn toEntryInfo(name: []const u8, raw: *const [32]u8, out: *platform.EntryInfo) void {
    const n = @min(name.len, out.name_buf.len);
    @memcpy(out.name_buf[0..n], name[0..n]);
    out.name_len = n;
    out.is_dir = raw[11] & attr_directory != 0;
    out.attrs = raw[11] & platform.Attr.all;
    out.size = if (out.is_dir) 0 else std.mem.readInt(u32, raw[28..32], .little);
    const rd = struct {
        fn u16At(r: *const [32]u8, at: usize) u16 {
            return std.mem.readInt(u16, r[at..][0..2], .little);
        }
    }.u16At;
    out.modified = fromDos(rd(raw, 24), rd(raw, 22));
    // Created: also 10 ms steps (0-199) on top of the even seconds:
    out.created = fromDos(rd(raw, 16), rd(raw, 14));
    if (out.created.year != 0 and raw[13] >= 100) out.created.second += 1;
    out.accessed = fromDos(rd(raw, 18), 0); // a date only
    out.unix = null;
}

// Date 0: not set.
fn fromDos(date: u16, time: u16) platform.DateTime {
    if (date == 0) return platform.no_date;
    return .{
        .year = 1980 + (date >> 9),
        .month = @intCast((date >> 5) & 0xF),
        .day = @intCast(date & 0x1F),
        .hour = @intCast(time >> 11),
        .minute = @intCast((time >> 5) & 0x3F),
        .second = @intCast((time & 0x1F) * 2),
    };
}

pub fn stat(v: *Volume, path: []const u8, out: *platform.EntryInfo) Error!void {
    var t: Target = undefined;
    try resolve(v, path, &t);
    if (t.is_root) {
        out.name_len = 0;
        out.is_dir = true;
        out.attrs = 0;
        out.size = 0;
        out.modified = platform.no_date;
        out.created = platform.no_date;
        out.accessed = platform.no_date;
        out.unix = null;
        return;
    }
    toEntryInfo(t.found.name(), &t.found.raw, out);
}

// FILES

pub const File = struct {
    in_use: bool = false,
    v: *Volume = undefined,
    first: u32 = 0, // first cluster, 0 for an empty file
    size: u32 = 0,
    pos: u64 = 0,
    // So sequential access doesn't walk the chain every time:
    cur_cluster: u32 = 0,
    cur_index: u32 = 0,
    // So seeking back doesn't walk the chain: marks[k - 1] is the
    // cluster at index k * mark_step (0: unknown); mark_step comes
    // from the size at first access.
    marks: [mark_count]u32 = .{0} ** mark_count,
    mark_step: u32 = 0,
    dir: u32 = 0, // the directory holding the entry, its slot, and that slot's cluster
    slot: u32 = 0,
    slot_cluster: u32 = 0,
    writable: bool = false,
    dirty: bool = false, // size, cluster or date changed: update the entry on close
    gen: u32 = 0, // the volume's generation when opened
};

const mark_count = 128;

// If i is a mark's place.
fn setMark(f: *File, i: u32, c: u32) void {
    if (i % f.mark_step != 0) return;
    const k = i / f.mark_step;
    if (k >= 1 and k <= mark_count) f.marks[k - 1] = c;
}

// The chain was cut at keep.
fn dropMarks(f: *File, keep: u32) void {
    if (f.mark_step == 0) return;
    for (&f.marks, 1..) |*m, k| {
        if (k * f.mark_step >= keep) m.* = 0;
    }
}

fn stale(f: *const File) bool {
    return f.gen != f.v.generation;
}

// OPENS OF ONE FILE: each has the size and chain the last
// change gave (SQLite reads with one, writes with another).

var opens = [_]?*File{null} ** 128; // as filesystems.zig's files

fn sameEntry(a: *const File, b: *const File) bool {
    return a != b and a.v == b.v and a.gen == b.gen and a.dir == b.dir and a.slot == b.slot;
}

// Not in the table: each open only on its own (as before).
fn register(f: *File) void {
    for (&opens) |*o| {
        if (o.* == null) {
            o.* = f;
            return;
        }
    }
}

fn unregister(f: *File) void {
    for (&opens) |*o| {
        if (o.* == f) o.* = null;
    }
}

// Another open's size and chain: its entry may not have them yet.
fn adopt(f: *File) void {
    for (opens) |o| {
        const x = o orelse continue;
        if (!sameEntry(x, f)) continue;
        f.first = x.first;
        f.size = x.size;
        return;
    }
}

// f's size and chain to the others; keep: the chain was cut to
// that many clusters (their places past it are gone).
fn share(f: *const File, keep: ?u32) void {
    for (opens) |o| {
        const x = o orelse continue;
        if (!sameEntry(x, f)) continue;
        if (x.first != f.first) {
            x.first = f.first;
            x.cur_cluster = 0;
            x.cur_index = 0;
            x.marks = .{0} ** mark_count;
            x.mark_step = 0;
        } else if (keep) |k| {
            dropMarks(x, k);
            if (x.cur_index >= k) {
                x.cur_cluster = 0;
                x.cur_index = 0;
            }
        }
        x.size = f.size;
    }
}

pub fn openFile(v: *Volume, path: []const u8, mode: platform.OpenMode, f: *File) Error!void {
    defer flushFsInfo(v); // the directory may grow, clusters be freed
    var t: Target = undefined;
    // Only a name that is really missing is created: on a read
    // error the entry may exist further on:
    const exists = if (resolve(v, path, &t)) true else |err| switch (err) {
        error.NotFound => false,
        else => return err,
    };
    if (exists and (t.is_root or t.found.isDir())) return error.IsADirectory;
    if (!exists) {
        if (mode == .read) return error.NotFound;
        var dir: u32 = undefined;
        const name = try parentOf(v, path, &dir);
        const raw = newRaw(attr_archive, 0);
        const added = try addEntry(v, dir, name, &raw);
        f.* = .{ .in_use = true, .v = v, .dir = dir, .slot = added.index, .slot_cluster = added.cluster, .writable = true, .gen = v.generation };
        register(f);
        return;
    }
    if (mode != .read and t.found.raw[11] & attr_read_only != 0) return error.AccessDenied;
    f.* = .{
        .in_use = true,
        .gen = v.generation,
        .v = v,
        .first = t.found.cluster(v),
        .size = t.found.size(),
        .dir = t.parent,
        .slot = t.found.index,
        .slot_cluster = t.found.short_cluster,
        .writable = mode != .read,
    };
    adopt(f);
    if (mode == .write and (f.size > 0 or f.first != 0)) {
        // The entry first: a chain that
        // fails to be freed only loses space:
        const chain = f.first;
        f.first = 0;
        f.size = 0;
        f.dirty = true;
        share(f, 0);
        try updateEntry(f);
        try freeChain(v, chain);
    }
    register(f);
}

// 0-based; grows the chain if grow, else 0 past the end.
fn clusterAt(f: *File, n: u32, grow: bool) Error!u32 {
    const v = f.v;
    if (f.first == 0) {
        if (!grow) return 0;
        f.first = try allocCluster(v, 0);
        f.dirty = true;
        f.cur_cluster = 0;
    }
    if (f.mark_step == 0) {
        const clusters = f.size / v.cluster_bytes + 1;
        f.mark_step = @max(1, (clusters + mark_count - 1) / mark_count);
    }
    var c = f.first;
    var i: u32 = 0;
    if (f.cur_cluster != 0 and f.cur_index <= n) {
        c = f.cur_cluster;
        i = f.cur_index;
    }
    // A mark nearer to n than that:
    const k = @min(n / f.mark_step, mark_count);
    if (k >= 1 and f.marks[k - 1] != 0 and k * f.mark_step > i) {
        c = f.marks[k - 1];
        i = k * f.mark_step;
    }
    while (i < n) {
        const next = try fatGet(v, c);
        if (v.isEnd(next)) {
            if (!grow) return 0;
            c = try allocCluster(v, c);
            f.dirty = true;
        } else c = next;
        i += 1;
        setMark(f, i, c);
    }
    f.cur_cluster = c;
    f.cur_index = n;
    return c;
}

pub fn read(f: *File, buf: []u8) Error!usize {
    if (stale(f)) return error.InvalidHandle;
    if (f.pos >= f.size) return 0;
    const v = f.v;
    const total: usize = @intCast(@min(buf.len, f.size - f.pos));
    var done: usize = 0;
    while (done < total) {
        const pos = f.pos;
        const c = try clusterAt(f, @intCast(pos / v.cluster_bytes), false);
        if (c == 0) return error.DeviceError; // chain shorter than the size: damaged
        const in_cluster: u32 = @intCast(pos % v.cluster_bytes);
        const rel = (try v.clusterSector(c)) + in_cluster / sector_size;
        const in_sector = in_cluster % sector_size;
        const left = total - done;
        if (in_sector == 0 and left >= sector_size) {
            // Whole sectors straight into the buffer, on into the clusters
            // right after this one: one request:
            const whole = left / sector_size;
            var n: usize = @min(v.sectors_per_cluster - in_cluster / sector_size, whole);
            var index: u32 = @intCast(pos / v.cluster_bytes);
            var last = c;
            while (n < whole and n + v.sectors_per_cluster <= max_run) {
                const next = clusterAt(f, index + 1, false) catch break; // reported next round
                if (next != last + 1) break;
                index += 1;
                last = next;
                n = @min(n + v.sectors_per_cluster, whole);
            }
            const bytes = n * sector_size;
            try devRead(v, rel, n, buf[done..][0..bytes]);
            done += bytes;
            f.pos += bytes;
        } else {
            const s = try sector(v, rel);
            const n = @min(sector_size - in_sector, left);
            @memcpy(buf[done..][0..n], s[in_sector..][0..n]);
            done += n;
            f.pos += n;
        }
    }
    return done;
}

pub fn write(f: *File, data: []const u8) Error!usize {
    if (stale(f)) return error.InvalidHandle;
    defer flushFsInfo(f.v);
    if (!f.writable) return error.AccessDenied; // opened for reading
    defer share(f, null); // what made it, also on an error
    if (f.pos + data.len > std.math.maxInt(u32)) return error.DiskFull; // 4 GiB
    // Past the end: fill the gap with zeros first:
    while (f.pos > f.size) {
        const zeros = [_]u8{0} ** sector_size;
        const gap: usize = @intCast(@min(f.pos - f.size, sector_size));
        const pos = f.pos;
        f.pos = f.size;
        const n = writeAt(f, zeros[0..gap]) catch |err| {
            f.pos = pos;
            return err;
        };
        f.pos = pos;
        if (n != gap) return error.DiskFull;
    }
    const n = try writeAt(f, data);
    try flushFat(f.v); // the clusters it added: on the disk's FAT at the latest now
    return n;
}

// An error only if nothing was written: a write cut short by a
// full disk returns what made it, as POSIX.
fn writeAt(f: *File, data: []const u8) Error!usize {
    var done: usize = 0;
    writeSome(f, data, &done) catch |err| {
        if (done == 0) return err;
    };
    return done;
}

const max_run = 128; // sectors per data request (64 KiB)

fn writeSome(f: *File, data: []const u8, done_out: *usize) Error!void {
    const v = f.v;
    var done: usize = 0;
    defer done_out.* = done;
    while (done < data.len) {
        const pos = f.pos;
        const c = try clusterAt(f, @intCast(pos / v.cluster_bytes), true);
        const in_cluster: u32 = @intCast(pos % v.cluster_bytes);
        const rel = (try v.clusterSector(c)) + in_cluster / sector_size;
        const in_sector = in_cluster % sector_size;
        const left = data.len - done;
        if (in_sector == 0 and left >= sector_size) {
            // Whole sectors, on into the next clusters on disk: one request
            // (a cluster is taken only if data goes into it):
            const whole = left / sector_size;
            var n: usize = @min(v.sectors_per_cluster - in_cluster / sector_size, whole);
            var index: u32 = @intCast(pos / v.cluster_bytes);
            var last = c;
            while (n < whole and n + v.sectors_per_cluster <= max_run) {
                const next = clusterAt(f, index + 1, true) catch break; // reported next round
                if (next != last + 1) break;
                index += 1;
                last = next;
                n = @min(n + v.sectors_per_cluster, whole);
            }
            const bytes = n * sector_size;
            invalidate(v, rel, n); // a failed write leaves them unknown
            try devWrite(v, rel, n, data[done..][0..bytes]);
            done += bytes;
            f.pos += bytes;
        } else {
            const s = try sector(v, rel);
            const n = @min(sector_size - in_sector, left);
            @memcpy(s[in_sector..][0..n], data[done..][0..n]);
            try writeBack(v, rel, s);

            done += n;
            f.pos += n;
        }
        if (f.pos > f.size) f.size = @intCast(f.pos);
        f.dirty = true;
    }
}

// Shorter: the end is cut and its clusters freed (the entry
// first, so a failure loses only space). Longer: zeros, as
// write does for a gap (FAT has no holes). The position stays.
pub fn setSize(f: *File, new_size: u64) Error!void {
    if (stale(f)) return error.InvalidHandle;
    defer flushFsInfo(f.v);
    if (!f.writable) return error.AccessDenied; // opened for reading
    if (new_size > std.math.maxInt(u32)) return error.DiskFull; // 4 GiB
    if (new_size == f.size) return;
    const v = f.v;

    if (new_size > f.size) {
        const pos = f.pos;
        defer f.pos = pos;
        defer share(f, null);
        f.pos = f.size;
        const zeros = [_]u8{0} ** sector_size;
        while (f.size < new_size) {
            const n: usize = @intCast(@min(new_size - f.size, sector_size));
            if (try writeAt(f, zeros[0..n]) != n) return error.DiskFull;
        }
        return;
    }

    const keep: u32 = @intCast((new_size + v.cluster_bytes - 1) / v.cluster_bytes);
    if (keep == 0) {
        const chain = f.first;
        f.first = 0;
        f.size = 0;
        f.cur_cluster = 0;
        f.cur_index = 0;
        dropMarks(f, 0);
        share(f, 0);
        try updateEntry(f);
        if (chain != 0) try freeChain(v, chain);
        return;
    }
    const last = try clusterAt(f, keep - 1, false); // also the cached place now
    if (last == 0) return error.DeviceError; // chain shorter than the size: damaged
    const rest = try fatGet(v, last);
    dropMarks(f, keep);
    f.size = @intCast(new_size);
    share(f, keep);
    try updateEntry(f);
    if (!v.isEnd(rest)) {
        try fatSet(v, last, eocValue(v));
        try freeChain(v, rest);
    }
}

pub fn seek(f: *File, pos: u64) Error!void {
    if (stale(f)) return error.InvalidHandle;
    f.pos = if (pos == platform.seek_end) f.size else pos;
}

// Size, first cluster and date into its directory entry.
fn updateEntry(f: *File) Error!void {
    const loc = try fileLoc(f);
    var raw = try readSlot(f.v, loc);
    setCluster(&raw, f.first);
    std.mem.writeInt(u32, raw[28..32], f.size, .little);
    raw[11] |= attr_archive;
    stampModified(&raw);
    try writeSlot(f.v, loc, &raw);
    f.dirty = false;
}

// Without a name; the size as written so far
// (the entry gets it on close or commit).
pub fn fstat(f: *File, out: *platform.EntryInfo) Error!void {
    if (stale(f)) return error.InvalidHandle;
    const raw = try readSlot(f.v, try fileLoc(f));
    toEntryInfo("", &raw, out);
    out.size = f.size;
}

// The entry is updated first, so close doesn't stamp it again
// unless the file is written to after this.
pub fn setModifiedOpen(f: *File, when: platform.DateTime) Error!void {
    if (stale(f)) return error.InvalidHandle;
    defer finish(f.v);
    if (f.dirty) try updateEntry(f);
    const loc = try fileLoc(f);
    var raw = try readSlot(f.v, loc);
    std.mem.writeInt(u16, raw[22..24], dosTime(when), .little);
    std.mem.writeInt(u16, raw[24..26], dosDate(when), .little);
    return writeSlot(f.v, loc, &raw);
}

fn fileLoc(f: *File) Error!Loc {
    var it = iterAt(f.v, f.dir, f.slot, f.slot_cluster);
    return (try it.next(false)) orelse error.DeviceError;
}

// The entry now, as close does, then a flush, so data so far
// survives a reset while the file stays open.
pub fn commit(f: *File) Error!void {
    if (stale(f)) return error.InvalidHandle;
    if (f.dirty) try updateEntry(f);
    flushFsInfo(f.v);
    try putOnDisk(f.v);
}

// Even when writing its entry fails; the
// error says size and date may be stale.
pub fn close(f: *File) Error!void {
    defer f.in_use = false;
    defer unregister(f);
    if (stale(f)) return;
    if (f.dirty) try updateEntry(f);
    flushFsInfo(f.v);
    try putOnDisk(f.v);
}

// DIRECTORIES

pub const Dir = struct {
    in_use: bool = false,
    it: SlotIter = undefined,
    gen: u32 = 0,
};

pub fn openDir(v: *Volume, path: []const u8, d: *Dir) Error!void {
    var t: Target = undefined;
    try resolve(v, path, &t);
    if (!t.is_root and !t.found.isDir()) return error.NotADirectory;
    const dir = if (t.is_root) v.root() else v.dirRef(t.found.cluster(v));
    d.* = .{ .in_use = true, .it = .{ .v = v, .dir = dir }, .gen = v.generation };
}

// False at the end.
pub fn readDir(d: *Dir, out: *platform.EntryInfo) Error!bool {
    if (d.gen != d.it.v.generation) return error.InvalidHandle;
    var f: Found = .{};
    if (!try nextEntry(&d.it, &f)) return false;
    toEntryInfo(f.name(), &f.raw, out);
    return true;
}

// AlreadyExists unless NotFound.
fn mustNotExist(v: *Volume, path: []const u8) Error!void {
    var t: Target = undefined;
    if (resolve(v, path, &t)) return error.AlreadyExists else |err| switch (err) {
        error.NotFound => {},
        else => return err,
    }
}

pub fn makeDir(v: *Volume, path: []const u8) Error!void {
    defer finish(v); // the directory may grow, clusters be freed
    var parent: u32 = undefined;
    const name = try parentOf(v, path, &parent);
    try mustNotExist(v, path);

    const c = try allocDirCluster(v, 0);
    forgetDir(v, c); // whatever was known of an earlier directory there
    // "." and ".." (0 means the root):
    var dot = newRaw(attr_directory, c);
    @memcpy(dot[0..11], ".          ");
    const parent_cluster: u32 = if (parent == v.root()) 0 else parent;
    var dotdot = newRaw(attr_directory, parent_cluster);
    @memcpy(dotdot[0..11], "..         ");
    errdefer freeChain(v, c) catch {};
    const s0 = try v.clusterSector(c);
    try writeSlot(v, .{ .rel = s0, .off = 0 }, &dot);
    try writeSlot(v, .{ .rel = s0, .off = 32 }, &dotdot);
    const raw = newRaw(attr_directory, c);
    _ = try addEntry(v, parent, name, &raw);
}

fn isEmptyDir(v: *Volume, dir: u32) Error!bool {
    var it: SlotIter = .{ .v = v, .dir = dir };
    var f: Found = .{};
    while (try nextEntry(&it, &f)) {
        const n = f.name();
        if (!std.mem.eql(u8, n, ".") and !std.mem.eql(u8, n, "..")) return false;
    }
    return true;
}

// A file or an empty directory. Read-only entries are refused,
// as in DOS (ZIGDOS.SYS is read-only).
pub fn delete(v: *Volume, path: []const u8) Error!void {
    defer finish(v); // the directory may grow, clusters be freed
    var t: Target = undefined;
    try resolve(v, path, &t);
    if (t.is_root) return error.AccessDenied;
    if (t.found.raw[11] & attr_read_only != 0) return error.AccessDenied;
    const c = t.found.cluster(v);
    if (t.found.isDir() and !try isEmptyDir(v, v.dirRef(c))) return error.DirNotEmpty;
    try removeEntry(v, t.parent, &t.found);
    if (t.found.isDir()) forgetDir(v, v.dirRef(c)); // its cluster may be reused
    if (c != 0) try freeChain(v, c);
}

// Within the volume; to must not exist.
// System files are refused.
pub fn rename(v: *Volume, from: []const u8, to: []const u8) Error!void {
    defer finish(v); // the directory may grow, clusters be freed
    var src: Target = undefined;
    try resolve(v, from, &src);
    if (src.is_root) return error.AccessDenied;
    // System files keep their name and place: the boot sector looks
    // for ZIGDOS.SYS in the root:
    if (src.found.raw[11] & attr_system != 0) return error.AccessDenied;
    try mustNotExist(v, to);
    var new_parent: u32 = undefined;
    const name = try parentOf(v, to, &new_parent);

    const is_dir = src.found.isDir();
    const c = src.found.cluster(v);
    // A directory can't move into or below itself:
    if (is_dir and insideOrSame(to, from)) return error.InvalidArgument;

    // The new entry first: if that fails, nothing is lost. It takes
    // only free slots, so the old slot numbers stay valid:
    _ = try addEntry(v, new_parent, name, &src.found.raw);
    try removeEntry(v, src.parent, &src.found);

    if (is_dir and new_parent != src.parent) {
        // Point the directory's ".." at its new parent:
        const loc = try slotAt(v, v.dirRef(c), 1);
        var slot = try readSlot(v, loc);
        if (std.mem.eql(u8, slot[0..2], "..")) {
            setCluster(&slot, if (new_parent == v.root()) 0 else new_parent);
            try writeSlot(v, loc, &slot);
        }
    }
}

// Read-only, hidden, system and archive.
pub fn setAttributes(v: *Volume, path: []const u8, attrs: u8) Error!void {
    defer finish(v);
    var t: Target = undefined;
    try resolve(v, path, &t);
    if (t.is_root) return error.AccessDenied;
    const loc = try entryLoc(v, t.parent, &t.found);
    var raw = try readSlot(v, loc);

    raw[11] = (raw[11] & ~@as(u8, platform.Attr.all)) | (attrs & platform.Attr.all);
    return writeSlot(v, loc, &raw);
}

// Seconds in steps of 2, as FAT stores them.
pub fn setModified(v: *Volume, path: []const u8, when: platform.DateTime) Error!void {
    defer finish(v);
    var t: Target = undefined;
    try resolve(v, path, &t);
    if (t.is_root) return error.AccessDenied;
    const loc = try entryLoc(v, t.parent, &t.found);
    var raw = try readSlot(v, loc);
    std.mem.writeInt(u16, raw[22..24], dosTime(when), .little);
    std.mem.writeInt(u16, raw[24..26], dosDate(when), .little);
    return writeSlot(v, loc, &raw);
}

// Ignoring case and the separators' style.
fn insideOrSame(path: []const u8, dir: []const u8) bool {
    var a = std.mem.tokenizeAny(u8, path, "\\/");
    var b = std.mem.tokenizeAny(u8, dir, "\\/");
    while (b.next()) |bc| {
        const ac = a.next() orelse return false;
        if (!sameName(ac, bc)) return false;
    }
    return true;
}
