// Minix V3: 32-bit zone pointers and a signed 32-bit maximum
// file size in the superblock.
const std = @import("std");
const platform = @import("../platform.zig");
const Error = platform.Error;

pub const sector_size = 512;
const WriteFn = *const fn (*const anyopaque, u64, usize, []const u8) Error!void;
pub const Device = struct {
    ctx: *const anyopaque,
    read: *const fn (*const anyopaque, u64, usize, []u8) Error!void,
    write: WriteFn,
    // Null where the backend can't (BIOS).
    flush: ?*const fn (*const anyopaque) Error!void = null,
};

const dir_cursor_slots = 32;
const DirCursor = struct {
    in_use: bool = false,
    ino: u32 = 0,
    pos: u64 = 0,
};

// A name in a directory index: where its entry is (entries
// never move, and the name is checked
// against the directory block on a lookup)
const dir_index_slots = 32;
const name_index_slots = 4096; // 64 KiB: about 3500 names in the indexed directories
const NameIndexState = enum(u8) { empty, tombstone, used };
const NameIndexEntry = struct {
    state: NameIndexState = .empty,
    dir_id: u32 = 0,
    hash: u32 = 0,
    pos: u32 = 0, // the entry's byte offset in the directory
};

const DirIndex = struct {
    ctx: ?*const anyopaque = null,
    start: u64 = 0,
    ino: u32 = 0,
    id: u32 = 0,
    complete: bool = false,
    used_at: u64 = 0,
};

var name_index = [_]NameIndexEntry{.{}} ** name_index_slots;
var name_index_empty: usize = name_index_slots; // slots never used since the last clear
var dir_indexes = [_]DirIndex{.{}} ** dir_index_slots;
var dir_index_clock: u64 = 0;
var next_dir_index_id: u32 = 0;

// BLOCK CACHE
// Write-through; the device is flushed when a change is done
// (markClean), on commit and by sync. 256 KiB: 64 slots of 4
// KiB (a slot holds one block of any size). File data in whole
// blocks bypasses it, so it holds metadata.
const cache_slots = 64;
const cache_hash_slots = 128; // twice the slots
const flush_batch_blocks = 4;
const Slot = struct {
    ctx: ?*const anyopaque = null,
    lba: u64 = 0,
    size: u32 = 0,
    write: ?WriteFn = null,
    dirty: bool = false,
    pins: u16 = 0,
    hash_next: ?u8 = null,
    lru_prev: ?u8 = null,
    lru_next: ?u8 = null,
    in_lru: bool = false,
    data: [4096]u8 align(4) = undefined,
};

var cache = [_]Slot{.{}} ** cache_slots;
var cache_hash = [_]?u8{null} ** cache_hash_slots;
var lru_front: ?u8 = null;
var lru_rear: ?u8 = null;
var cache_entry_count: usize = 0;
var next_free_slot: usize = 0;
var flush_buffer: [flush_batch_blocks * 4096]u8 align(4) = undefined;

pub fn forget(dev_ctx: *const anyopaque) void {
    // Raw disk changes invalidate any cached copy. Call sync before
    // changing a mounted volume so dirty
    // entries are not discarded here.
    for (&cache) |*s| {
        if (s.ctx == dev_ctx) invalidateSlot(s);
    }
    for (&dir_indexes) |*d| {
        if (d.ctx == dev_ctx) removeDirIndex(d);
    }
}

fn removeDirIndex(d: *DirIndex) void {
    if (d.id != 0) {
        for (&name_index) |*entry| {
            if (entry.state == .used and entry.dir_id == d.id) entry.state = .tombstone;
        }
    }
    d.* = .{};
}

// Removed entries become tombstones, never empty again, and a
// probe stops only at an empty slot: when few are left as an
// index is built, every slot is emptied
// (and every directory index dropped)
fn clearNameIndex() void {
    for (&name_index) |*entry| entry.state = .empty;
    for (&dir_indexes) |*d| d.* = .{};
    name_index_empty = name_index_slots;
}

fn dirIndex(v: *const Volume, ino: u32) ?*DirIndex {
    for (&dir_indexes) |*d| {
        if (d.ctx == v.dev.ctx and d.start == v.start and d.ino == ino) {
            dir_index_clock +%= 1;
            d.used_at = dir_index_clock;
            return d;
        }
    }
    return null;
}

fn ensureDirIndex(v: *const Volume, ino: u32) *DirIndex {
    if (dirIndex(v, ino)) |d| return d;
    var chosen: ?*DirIndex = null;
    for (&dir_indexes) |*d| {
        if (d.ctx == null) {
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
    d.* = .{ .ctx = v.dev.ctx, .start = v.start, .ino = ino, .id = next_dir_index_id, .used_at = dir_index_clock };
    return d;
}

fn nameHash(dir_id: u32, name: []const u8) u32 {
    var h: u64 = 14695981039346656037;
    h = (h ^ @as(u64, dir_id)) *% 1099511628211;
    for (name) |c| h = (h ^ @as(u64, c)) *% 1099511628211;
    return @truncate(h ^ (h >> 32));
}

// The slot of the entry at pos, if
// it is in the index under this hash
fn nameIndexFind(dir_id: u32, hash: u32, pos: u32) ?usize {
    var slot: usize = hash & (name_index_slots - 1);
    for (0..name_index_slots) |_| {
        const entry = &name_index[slot];
        if (entry.state == .empty) return null;
        if (entry.state == .used and entry.dir_id == dir_id and entry.hash == hash and entry.pos == pos) return slot;
        slot = (slot + 1) & (name_index_slots - 1);
    }
    return null;
}

// Adds the entry named name at byte pos of the directory; false
// if the table is full (the index is then incomplete)
fn nameIndexPut(d: *DirIndex, name: []const u8, pos: u64) bool {
    if (name.len > 60) return false;
    const hash = nameHash(d.id, name);
    const at: u32 = @intCast(pos);
    if (nameIndexFind(d.id, hash, at) != null) return true;
    var slot: usize = hash & (name_index_slots - 1);
    var tombstone: ?usize = null;
    for (0..name_index_slots) |_| {
        const entry = &name_index[slot];
        if (entry.state == .tombstone and tombstone == null) tombstone = slot;
        if (entry.state == .empty) break;
        slot = (slot + 1) & (name_index_slots - 1);
    } else if (tombstone == null) {
        d.complete = false;
        return false;
    }
    if (tombstone == null) name_index_empty -= 1;
    name_index[tombstone orelse slot] = .{ .state = .used, .dir_id = d.id, .hash = hash, .pos = at };
    return true;
}

fn nameIndexRemove(d: *DirIndex, name: []const u8, pos: u64) void {
    if (name.len > 60) return;
    if (nameIndexFind(d.id, nameHash(d.id, name), @intCast(pos))) |found| name_index[found].state = .tombstone;
}

// Looks name up in a complete index: each candidate's entry is
// read from the directory and its name compared
fn nameIndexLookup(v: *Volume, dir: *const Inode, d: *const DirIndex, name: []const u8) Error!?u32 {
    const hash = nameHash(d.id, name);
    var slot: usize = hash & (name_index_slots - 1);
    for (0..name_index_slots) |_| {
        const entry = name_index[slot];
        if (entry.state == .empty) break;
        slot = (slot + 1) & (name_index_slots - 1);
        if (entry.state != .used or entry.dir_id != d.id or entry.hash != hash) continue;
        if (entry.pos + 64 > dir.size) continue;
        const zone = try map(v, dir, entry.pos / v.block_size);
        if (zone == 0) continue;
        const s = try getBlock(v, zone);
        defer unpin(s);
        const ent = s.data[entry.pos % v.block_size ..][0..64];
        const child = u32le(ent, 0);
        if (child == 0) continue;
        const n = std.mem.indexOfScalar(u8, ent[4..], 0) orelse 60;
        if (same(name, ent[4 .. 4 + n])) return child;
    }
    return null;
}

fn discardDirIndex(v: *const Volume, ino: u32) void {
    if (dirIndex(v, ino)) |d| removeDirIndex(d);
}

fn blockLba(v: *const Volume, block_num: u32) u64 {
    return v.start + @as(u64, block_num) * (v.block_size / sector_size);
}

fn cacheSlotIndex(s: *Slot) u8 {
    const offset = @intFromPtr(s) - @intFromPtr(&cache[0]);
    return @intCast(offset / @sizeOf(Slot));
}

fn cacheBucket(ctx: *const anyopaque, lba: u64, size: u32) usize {
    var h: u64 = @intCast(@intFromPtr(ctx));
    h ^= lba +% 0x9E3779B97F4A7C15 +% (h << 6) +% (h >> 2);
    h ^= @as(u64, size) *% 0xBF58476D1CE4E5B9;
    h ^= h >> 30;
    h *%= 0xBF58476D1CE4E5B9;
    h ^= h >> 27;
    return @intCast(h & (cache_hash_slots - 1));
}

fn hashInsert(s: *Slot) void {
    const bucket = cacheBucket(s.ctx.?, s.lba, s.size);
    const index = cacheSlotIndex(s);
    s.hash_next = cache_hash[bucket];
    cache_hash[bucket] = index;
}

fn hashRemove(s: *Slot) void {
    const ctx = s.ctx orelse return;
    const bucket = cacheBucket(ctx, s.lba, s.size);
    const index = cacheSlotIndex(s);
    var link = &cache_hash[bucket];
    while (link.*) |at| {
        if (at == index) {
            link.* = s.hash_next;
            s.hash_next = null;
            return;
        }
        link = &cache[at].hash_next;
    }
}

fn invalidateSlot(s: *Slot) void {
    if (s.ctx != null) cache_entry_count -= 1;
    hashRemove(s);
    lruRemove(s);
    s.* = .{};
}

fn cached(v: *const Volume, lba: u64) ?*Slot {
    const bucket = cacheBucket(v.dev.ctx, lba, v.block_size);
    var link = cache_hash[bucket];
    while (link) |at| {
        const s = &cache[at];
        if (s.ctx == v.dev.ctx and s.lba == lba and s.size == v.block_size) {
            return s;
        }
        link = s.hash_next;
    }
    return null;
}

fn discardBlock(v: *const Volume, block_num: u32) void {
    const lba = blockLba(v, block_num);
    if (cached(v, lba)) |s| invalidateSlot(s);
}

fn touch(s: *Slot) void {
    if (s.pins != 0) return;
    if (s.in_lru) lruRemove(s);
    const index = cacheSlotIndex(s);
    s.lru_prev = lru_rear;
    s.lru_next = null;
    s.in_lru = true;
    if (lru_rear) |rear| {
        cache[rear].lru_next = index;
    } else {
        lru_front = index;
    }
    lru_rear = index;
}

fn lruRemove(s: *Slot) void {
    if (!s.in_lru) return;
    if (s.lru_prev) |prev| cache[prev].lru_next = s.lru_next else lru_front = s.lru_next;
    if (s.lru_next) |next| cache[next].lru_prev = s.lru_prev else lru_rear = s.lru_prev;
    s.lru_prev = null;
    s.lru_next = null;
    s.in_lru = false;
}

fn pin(s: *Slot) Error!void {
    if (s.pins == std.math.maxInt(u16)) return error.DeviceError;
    if (s.pins == 0) lruRemove(s);
    s.pins += 1;
}

fn unpin(s: *Slot) void {
    if (s.pins == 0) return;
    s.pins -= 1;
    if (s.pins == 0) touch(s);
}

fn matchesFlush(s: *const Slot, ctx: *const anyopaque, volume: ?*const Volume) bool {
    if (s.ctx != ctx or !s.dirty or s.pins != 0) return false;
    if (volume) |v| {
        if (s.lba < v.start or s.lba - v.start >= v.total_sectors) return false;
    }
    return true;
}

fn flushDirty(ctx: *const anyopaque, volume: ?*const Volume) Error!void {
    var run: [flush_batch_blocks]*Slot = undefined;
    while (true) {
        var first: ?*Slot = null;
        for (&cache) |*s| {
            if (!matchesFlush(s, ctx, volume)) continue;
            if (first == null or s.lba < first.?.lba) first = s;
        }
        const head = first orelse return;
        const write_fn = head.write orelse return error.DeviceError;
        const block_size = head.size;
        const sectors_per_block = block_size / sector_size;
        var run_len: usize = 1;
        run[0] = head;
        const block_bytes: usize = @intCast(block_size);
        @memcpy(flush_buffer[0..block_bytes], head.data[0..block_bytes]);

        while (run_len < flush_batch_blocks) {
            const next_lba = head.lba + @as(u64, @intCast(run_len)) * @as(u64, @intCast(sectors_per_block));
            var next: ?*Slot = null;
            for (&cache) |*s| {
                if (!matchesFlush(s, ctx, volume) or s.size != block_size or s.lba != next_lba or s.write == null or s.write.? != write_fn) continue;
                next = s;
                break;
            }
            const tail = next orelse break;
            run[run_len] = tail;
            const off = run_len * block_bytes;
            @memcpy(flush_buffer[off..][0..block_bytes], tail.data[0..block_bytes]);
            run_len += 1;
        }

        const bytes = run_len * block_bytes;
        const sectors = run_len * @as(usize, @intCast(sectors_per_block));
        try write_fn(ctx, head.lba, sectors, flush_buffer[0..bytes]);
        for (run[0..run_len]) |s| s.dirty = false;
    }
}

fn freeSlot() Error!*Slot {
    if (cache_entry_count < cache_slots) {
        for (0..cache_slots) |offset| {
            const index = (next_free_slot + offset) % cache_slots;
            const s = &cache[index];
            if (s.ctx == null) {
                next_free_slot = (index + 1) % cache_slots;
                return s;
            }
        }
    }

    const victim = if (lru_front) |index| &cache[index] else null;
    const s = victim orelse return error.DeviceError;
    if (s.dirty) {
        const ctx = s.ctx orelse return error.DeviceError;
        try flushDirty(ctx, null);
    }
    invalidateSlot(s);
    return s;
}

fn getBlock(v: *Volume, block_num: u32) Error!*Slot {
    if (block_num >= v.zones) return error.DeviceError;
    const lba = blockLba(v, block_num);
    if (cached(v, lba)) |s| {
        try pin(s);
        return s;
    }
    const s = try freeSlot();
    const spb = v.block_size / sector_size;
    try v.dev.read(v.dev.ctx, lba, spb, s.data[0..v.block_size]);
    s.ctx = v.dev.ctx;
    s.lba = lba;
    s.size = v.block_size;
    s.write = v.dev.write;
    s.dirty = false;
    s.pins = 1;
    cache_entry_count += 1;
    hashInsert(s);
    return s;
}

fn bzero(v: *Volume, block_num: u32) Error![]u8 {
    if (block_num >= v.zones) return error.DeviceError;
    const lba = blockLba(v, block_num);
    const s = if (cached(v, lba)) |hit| blk: {
        try pin(hit);
        break :blk hit;
    } else blk: {
        const slot = try freeSlot();
        slot.ctx = v.dev.ctx;
        slot.lba = lba;
        slot.size = v.block_size;
        slot.write = v.dev.write;
        slot.pins = 1;
        cache_entry_count += 1;
        hashInsert(slot);
        break :blk slot;
    };
    @memset(s.data[0..v.block_size], 0);
    s.dirty = true;
    return s.data[0..v.block_size];
}

fn bput(v: *Volume, block_num: u32, data: []const u8) Error!void {
    if (block_num >= v.zones or data.len != v.block_size) return error.DeviceError;
    const lba = blockLba(v, block_num);
    if (v.write_failed) {
        if (cached(v, lba)) |s| unpin(s); // the caller's pin, as a write would
        return error.DeviceError;
    }
    const s = if (cached(v, lba)) |hit| hit else blk: {
        const slot = try freeSlot();
        slot.ctx = v.dev.ctx;
        slot.lba = lba;
        slot.size = v.block_size;
        slot.write = v.dev.write;
        cache_entry_count += 1;
        hashInsert(slot);
        break :blk slot;
    };
    if (s.data[0..v.block_size].ptr != data.ptr) @memcpy(s.data[0..v.block_size], data);
    s.dirty = true;
    const sectors: usize = @intCast(v.block_size / sector_size);
    devWrite(v, lba, sectors, s.data[0..v.block_size]) catch |err| {
        v.write_failed = true;
        invalidateSlot(s);
        return err;
    };
    s.dirty = false;
    if (s.pins != 0) unpin(s) else touch(s);
}

pub const Volume = struct {
    dev: Device,
    start: u64,
    total_sectors: u64,
    serial: ?u32 = null,
    generation: u32 = 0,
    block_size: u32,
    zones: u32,
    first_zone: u32,
    inode_map_blocks: u16,
    zone_map_blocks: u16,
    inode_count: u32,
    max_size: u64,
    clean: bool,
    writable: bool,
    writers: u32 = 0,
    write_failed: bool = false,
    super: [1024]u8, // the superblock as last read or written
    unflushed: bool = false, // written since the last flush
    last_ino: u32 = 2,
    // Minix's s_zsearch: the next zone bitmap bit to try, so the
    // allocated prefix isn't rescanned:
    zone_search_bit: u32 = 0,
    dir_cursors: [dir_cursor_slots]DirCursor = [_]DirCursor{.{}} ** dir_cursor_slots,
    next_dir_cursor: usize = 0,
};

pub const File = struct {
    in_use: bool = false,
    size: u64 = 0,
    v: *Volume = undefined,
    ino: u32 = 0,
    pos: u64 = 0,
    gen: u32 = 0,
    writable: bool = false,
};

pub const Dir = struct {
    in_use: bool = false,
    v: *Volume = undefined,
    ino: u32 = 0,
    pos: u64 = 0,
    gen: u32 = 0,
};

fn directoryCursor(v: *const Volume, ino: u32) u64 {
    for (v.dir_cursors) |cursor| {
        if (cursor.in_use and cursor.ino == ino) return cursor.pos;
    }
    return 0;
}

fn rememberDirectoryCursor(v: *Volume, ino: u32, pos: u64) void {
    for (&v.dir_cursors) |*cursor| {
        if (cursor.in_use and cursor.ino == ino) {
            cursor.pos = pos;
            return;
        }
    }
    const cursor = &v.dir_cursors[v.next_dir_cursor];
    v.next_dir_cursor = (v.next_dir_cursor + 1) % dir_cursor_slots;
    cursor.* = .{ .in_use = true, .ino = ino, .pos = pos };
}

fn rewindDirectoryCursor(v: *Volume, ino: u32, pos: u64) void {
    for (&v.dir_cursors) |*cursor| {
        if (cursor.in_use and cursor.ino == ino and pos < cursor.pos) {
            cursor.pos = pos;
            return;
        }
    }
}

fn forgetDirectoryCursor(v: *Volume, ino: u32) void {
    for (&v.dir_cursors) |*cursor| {
        if (cursor.in_use and cursor.ino == ino) {
            cursor.* = .{};
            return;
        }
    }
}

fn u16le(b: []const u8, n: usize) u16 {
    return std.mem.readInt(u16, b[n..][0..2], .little);
}

fn u32le(b: []const u8, n: usize) u32 {
    return std.mem.readInt(u32, b[n..][0..4], .little);
}

fn block(v: *Volume, n: u32, b: []u8) Error!void {
    if (n >= v.zones or b.len != v.block_size) return error.DeviceError;
    const s = try getBlock(v, n);
    @memcpy(b, s.data[0..v.block_size]);
    unpin(s);
}

fn writeBlock(v: *Volume, n: u32, b: []const u8) Error!void {
    if (n >= v.zones or b.len != v.block_size) return error.DeviceError;
    try bput(v, n, b);
}

fn devWrite(v: *Volume, lba: u64, count: usize, data: []const u8) Error!void {
    v.unflushed = true;
    return v.dev.write(v.dev.ctx, lba, count, data);
}

fn devFlush(v: *Volume) Error!void {
    if (v.dev.flush) |flush| try flush(v.dev.ctx);
    v.unflushed = false;
}

// Writes the clean flag into the superblock (the copy read when
// mounting, so it isn't read again each time)
fn writeState(v: *Volume, clean: bool) Error!void {
    var sb = v.super;
    const state = u16le(&sb, 14);
    std.mem.writeInt(u16, sb[14..16], if (clean) state | 1 else state & ~@as(u16, 1), .little);
    try devWrite(v, v.start + 2, 2, &sb);
    v.super = sb;
    v.clean = clean;
}

// The superblock says "not clean" until the change is done;
// that is flushed first, so no
// change can reach the disk before it
fn markDirty(v: *Volume) Error!void {
    if (!v.writable) return error.WriteProtected;
    if (!v.clean) return;
    try writeState(v, false);
    try devFlush(v);
}

fn beginWrite(v: *Volume) Error!void {
    if (v.write_failed) return error.DeviceError;
    if (!v.writable) return error.WriteProtected;
    try markDirty(v);
    v.writers += 1;
}

// After a change: "clean" again once no writer is left (a file
// open for writing: on its close)
fn endWrite(v: *Volume) void {
    if (v.writers != 0) v.writers -= 1;
    if (v.writers == 0 and !v.clean) markClean(v) catch {};
}

// What was written reaches the device (cached blocks
// still dirty first) and is flushed, then "clean" is
// written and flushed too: "clean" never reaches the disk
// before what it vouches for
fn markClean(v: *Volume) Error!void {
    try putOnDisk(v);
    try writeState(v, true);
    try devFlush(v);
}

fn putOnDisk(v: *Volume) Error!void {
    if (v.write_failed) return error.DeviceError;
    try flushDirty(v.dev.ctx, v);
    for (&cache) |*s| {
        if (s.ctx == v.dev.ctx and s.lba >= v.start and s.lba - v.start < v.total_sectors and s.dirty) return error.DeviceError;
    }
    try devFlush(v);
}

// Before shutdown or a disk operation replacing this volume:
// everything to the device, the volume
// marked clean if no writer remains.
pub fn sync(v: *Volume) Error!void {
    if (v.writable and !v.clean and v.writers == 0) return markClean(v);
    if (v.unflushed) try putOnDisk(v);
}

pub fn mount(dev: Device, start: u64, sectors: u64) ?Volume {
    if (sectors < 8) return null;
    var sb: [1024]u8 = undefined;
    dev.read(dev.ctx, start + 2, 2, &sb) catch return null;
    if (u16le(&sb, 24) != 0x4d5a) return null; // Minix V3, little endian
    const imap = u16le(&sb, 6);
    const zmap = u16le(&sb, 8);
    const ninodes = u32le(&sb, 0);
    const zones = u32le(&sb, 20);
    const block_size: u32 = u16le(&sb, 28);
    const max_size: u64 = @min(u32le(&sb, 16), 0x7fff_ffff);
    if (u16le(&sb, 12) != 0 or u16le(&sb, 14) & 0xff00 != 0 or block_size < 1024 or block_size > 4096 or
        !std.math.isPowerOfTwo(block_size) or imap == 0 or zmap == 0 or
        ninodes == 0 or zones < 4 or @as(u64, zones) * (block_size / sector_size) > sectors) return null;
    const inode_blocks = (ninodes + block_size / 64 - 1) / (block_size / 64);
    const first_zone_disk = u16le(&sb, 10);
    const first_zone: u32 = if (first_zone_disk != 0) first_zone_disk else 2 + imap + zmap + inode_blocks;
    if (first_zone < 2 + imap + zmap + inode_blocks or first_zone >= zones) return null;
    if (@as(u64, imap) * block_size * 8 < @as(u64, ninodes) + 1 or
        @as(u64, zmap) * block_size * 8 < @as(u64, zones) - first_zone + 1) return null;
    const pointers: u64 = block_size / 4;
    const pointer_limit = (7 + pointers + pointers * pointers) * block_size;
    // Not cleanly unmounted: read only until checked
    // (CHKMFS), as Minix's own MFS mounts it
    const clean = u16le(&sb, 14) & 1 != 0;
    return .{ .dev = dev, .start = start, .total_sectors = @min(sectors, @as(u64, zones) * (block_size / sector_size)), .block_size = block_size, .zones = zones, .first_zone = first_zone, .inode_map_blocks = imap, .zone_map_blocks = zmap, .inode_count = ninodes, .max_size = @min(max_size, pointer_limit), .clean = clean, .writable = clean, .last_ino = 2, .super = sb };
}

// Read only because it wasn't cleanly unmounted
pub fn notClean(v: *const Volume) bool {
    return !v.writable and !v.clean;
}

const Inode = struct { mode: u16, links: u16, uid: u16, gid: u16, size: u64, atime: u32, mtime: u32, ctime: u32, zones: [10]u32 };

fn inode(v: *Volume, ino: u32) Error!Inode {
    if (ino == 0 or ino > v.inode_count) return error.NotFound;
    const per = v.block_size / 64;
    const inode_start: u64 = 2 + v.inode_map_blocks + v.zone_map_blocks;
    const bn: u32 = @intCast(inode_start + (ino - 1) / per);
    const slot = try getBlock(v, bn);
    defer unpin(slot);
    const b = slot.data[0..v.block_size];
    const off: usize = @as(usize, (ino - 1) % per) * 64;
    var z: [10]u32 = undefined;
    for (0..10) |i| z[i] = u32le(b, off + 24 + i * 4);
    const size = u32le(b, off + 8);
    if (size > v.max_size) return error.DeviceError;
    return .{ .mode = u16le(b, off), .links = u16le(b, off + 2), .uid = u16le(b, off + 4), .gid = u16le(b, off + 6), .size = size, .atime = u32le(b, off + 12), .mtime = u32le(b, off + 16), .ctime = u32le(b, off + 20), .zones = z };
}

fn writeInode(v: *Volume, ino: u32, x: *const Inode) Error!void {
    if (ino == 0 or ino > v.inode_count or x.size > v.max_size) return error.InvalidArgument;
    const per = v.block_size / 64;
    const start: u64 = 2 + v.inode_map_blocks + v.zone_map_blocks;
    const bn: u32 = @intCast(start + (ino - 1) / per);
    const slot = try getBlock(v, bn);
    const b = slot.data[0..v.block_size];
    const off: usize = @as(usize, (ino - 1) % per) * 64;
    std.mem.writeInt(u16, b[off..][0..2], x.mode, .little);
    std.mem.writeInt(u16, b[off + 2 ..][0..2], x.links, .little);
    std.mem.writeInt(u16, b[off + 4 ..][0..2], x.uid, .little);
    std.mem.writeInt(u16, b[off + 6 ..][0..2], x.gid, .little);
    std.mem.writeInt(u32, b[off + 8 ..][0..4], @intCast(x.size), .little);
    std.mem.writeInt(u32, b[off + 12 ..][0..4], x.atime, .little);
    std.mem.writeInt(u32, b[off + 16 ..][0..4], x.mtime, .little);
    std.mem.writeInt(u32, b[off + 20 ..][0..4], x.ctime, .little);
    for (x.zones, 0..) |z, i| std.mem.writeInt(u32, b[off + 24 + i * 4 ..][0..4], z, .little);
    try writeBlock(v, bn, b[0..v.block_size]);
}

fn bitmapUpdate(v: *Volume, start: u32, bit: u32, used: bool) Error!void {
    const byte = bit / 8;
    const bn = start + byte / v.block_size;
    const slot = try getBlock(v, bn);
    const b = slot.data[0..v.block_size];
    const mask = @as(u8, 1) << @intCast(bit % 8);
    const off: usize = byte % v.block_size;
    if ((b[off] & mask != 0) == used) {
        unpin(slot);
        return error.DeviceError;
    }
    if (used) b[off] |= mask else b[off] &= ~mask;
    try writeBlock(v, bn, b[0..v.block_size]);
}

fn allocateInode(v: *Volume) Error!u32 {
    var ino: u32 = v.last_ino;
    var checked: u32 = 0;
    while (checked < v.inode_count) : (checked += 1) {
        if (ino > v.inode_count) ino = 2;
        if (try findFreeInode(v, ino)) |found| {
            v.last_ino = found + 1;
            forgetDirectoryCursor(v, found);
            discardDirIndex(v, found);
            return found;
        }
        ino += 1;
    }
    return error.DiskFull;
}

fn findFreeInode(v: *Volume, ino: u32) Error!?u32 {
    const byte = ino / 8;
    const bn = 2 + byte / v.block_size;
    const slot = try getBlock(v, bn);
    const b = slot.data[0..v.block_size];
    const mask = @as(u8, 1) << @intCast(ino % 8);
    const off: usize = byte % v.block_size;
    if (b[off] & mask != 0) {
        unpin(slot);
        return null;
    }
    b[off] |= mask;
    try writeBlock(v, bn, b);
    return ino;
}

// Data zones are initialized by their first write; indirect
// tables use allocateZeroedZone.
fn allocateZone(v: *Volume) Error!u32 {
    return (try allocateRun(v, 1)).first;
}

const ZoneRun = struct { first: u32, count: u32 };

// The first free zone and up to want-1 free ones right after it
// (in the same bitmap block): one bitmap
// write for all of them, as ext2's allocRun
fn allocateRun(v: *Volume, want: u32) Error!ZoneRun {
    const zmap: u32 = 2 + v.inode_map_blocks;
    const max_bit = v.zones - v.first_zone;
    var bit = v.zone_search_bit;
    if (bit == 0 or bit > max_bit) bit = 1;
    var checked: u32 = 0;
    while (checked < max_bit) {
        const map_block_index = bit / (v.block_size * 8);
        const bn = zmap + map_block_index;
        const slot = try getBlock(v, bn);
        const b = slot.data[0..v.block_size];

        while (bit <= max_bit and (bit / (v.block_size * 8)) == map_block_index) {
            const byte_in_block = (bit / 8) % v.block_size;
            const bit_in_byte = @as(u3, @intCast(bit % 8));
            if (b[byte_in_block] == 0xFF) {
                const advance = 8 - (bit % 8);
                bit += advance;
                checked += advance;
                continue;
            }
            const mask = @as(u8, 1) << bit_in_byte;
            if (b[byte_in_block] & mask == 0) {
                var count: u32 = 1;
                while (count < want) : (count += 1) {
                    const next = bit + count;
                    if (next > max_bit or next / (v.block_size * 8) != map_block_index) break;
                    const nb = (next / 8) % v.block_size;
                    const nm = @as(u8, 1) << @as(u3, @intCast(next % 8));
                    if (b[nb] & nm != 0) break;
                }
                for (bit..bit + count) |k| b[(k / 8) % v.block_size] |= @as(u8, 1) << @as(u3, @intCast(k % 8));
                try writeBlock(v, bn, b);
                unpin(slot);
                v.zone_search_bit = bit + count;
                return .{ .first = bit + (v.first_zone - 1), .count = count };
            }
            bit += 1;
            checked += 1;
        }
        unpin(slot);
        if (bit > max_bit) bit = 1;
    }
    return error.DiskFull;
}

fn allocateZeroedZone(v: *Volume) Error!u32 {
    const zone = try allocateZone(v);
    const b = try bzero(v, zone);
    try bput(v, zone, b);
    return zone;
}

fn freeZone(v: *Volume, zone: u32) Error!void {
    if (zone < v.first_zone or zone >= v.zones) return error.DeviceError;
    const bit = zone - (v.first_zone - 1);
    try bitmapUpdate(v, 2 + v.inode_map_blocks, bit, false);
    if (v.zone_search_bit == 0 or bit < v.zone_search_bit) v.zone_search_bit = bit;
    discardBlock(v, zone);
}

// Zones to free, gathered so that each zone bitmap block is
// written once per batch instead of once per zone
const FreeList = struct {
    zones: [256]u32 = undefined,
    n: usize = 0,
};

fn freeLater(v: *Volume, list: *FreeList, zone: u32) Error!void {
    if (zone < v.first_zone or zone >= v.zones) return error.DeviceError;
    if (list.n == list.zones.len) try freeZones(v, list);
    list.zones[list.n] = zone;
    list.n += 1;
}

// Clears the listed zones in the bitmap: one read-modify-write
// per bitmap block. A zone already free is damage: nothing of
// that block is written.
fn freeZones(v: *Volume, list: *FreeList) Error!void {
    const zmap: u32 = 2 + v.inode_map_blocks;
    const bits_per_block = v.block_size * 8;
    for (0..list.n) |i| {
        const head = list.zones[i];
        if (head == 0) continue; // done with an earlier bitmap block
        const map_block = (head - (v.first_zone - 1)) / bits_per_block;
        const bn = zmap + map_block;
        const s = try getBlock(v, bn);
        const b = s.data[0..v.block_size];
        for (list.zones[i..list.n]) |*z| {
            if (z.* == 0) continue;
            const bit = z.* - (v.first_zone - 1);
            if (bit / bits_per_block != map_block) continue;
            const byte = (bit / 8) % v.block_size;
            const mask = @as(u8, 1) << @intCast(bit % 8);
            if (b[byte] & mask == 0) {
                invalidateSlot(s); // changed in memory only: dropped
                return error.DeviceError;
            }
            b[byte] &= ~mask;
            if (v.zone_search_bit == 0 or bit < v.zone_search_bit) v.zone_search_bit = bit;
            discardBlock(v, z.*);
            z.* = 0;
        }
        try writeBlock(v, bn, b);
    }
    list.n = 0;
}

// A zone and, for an indirect table
// (depth 1 or 2), all it points at
fn freeTree(v: *Volume, list: *FreeList, zone: u32, depth: u32) Error!void {
    if (zone == 0) return;
    if (depth != 0) {
        var i: u32 = 0;
        while (i < v.block_size / 4) : (i += 1) try freeTree(v, list, try pointerAt(v, zone, i), depth - 1);
    }
    try freeLater(v, list, zone);
}

// Frees what an indirect table points at from data block
// from on (counted from the table's start), with one
// write of the table; true if nothing is left in it (it
// is then freed too). The table is changed in the cache.
fn freeFrom(v: *Volume, list: *FreeList, table: u32, depth: u32, from: u64) Error!bool {
    const s = try getBlock(v, table);
    var changed = false;
    clearEntries(v, list, s, depth, from, &changed) catch |err| {
        invalidateSlot(s); // changed in memory only: dropped
        return err;
    };
    const data = s.data[0..v.block_size];
    const empty = std.mem.allEqual(u8, data, 0);
    if (changed) try writeBlock(v, table, data) else unpin(s);
    if (empty) try freeLater(v, list, table);
    return empty;
}

fn clearEntries(v: *Volume, list: *FreeList, s: *Slot, depth: u32, from: u64, changed: *bool) Error!void {
    const per: u64 = v.block_size / 4;
    const span: u64 = if (depth == 2) per else 1;
    const first = from / span;
    const sub = from % span;
    var e = first;
    while (e < per) : (e += 1) {
        const off: usize = @intCast(e * 4);
        const child = u32le(&s.data, off);
        if (child == 0) continue;
        if (depth == 1) {
            try freeLater(v, list, child);
        } else if (e == first and sub != 0) {
            // Its first part stays
            if (!try freeFrom(v, list, child, 1, sub)) continue;
        } else try freeTree(v, list, child, 1);
        put32(&s.data, off, 0);
        changed.* = true;
    }
}

fn emptyInode(v: *Volume, ino: u32, x: *Inode) Error!void {
    var list: FreeList = .{};
    for (0..7) |i| try freeTree(v, &list, x.zones[i], 0);
    try freeTree(v, &list, x.zones[7], 1);
    try freeTree(v, &list, x.zones[8], 2);
    try freeZones(v, &list);
    x.size = 0;
    @memset(&x.zones, 0);
    try writeInode(v, ino, x);
}

// The zone holding block n of the file, 0
// for a hole (a missing indirect table too)
fn map(v: *Volume, ino: *const Inode, n: u64) Error!u32 {
    const per = v.block_size / 4;
    if (n < 7) return ino.zones[@intCast(n)];
    var idx = n - 7;
    if (idx < per) {
        if (ino.zones[7] == 0) return 0;
        return pointerAt(v, ino.zones[7], idx);
    }
    idx -= per;
    if (idx >= @as(u64, per) * per) return error.DeviceError; // past the largest file
    if (ino.zones[8] == 0) return 0;
    const a = try pointerAt(v, ino.zones[8], idx / per);
    if (a == 0) return 0;
    return pointerAt(v, a, idx % per);
}

// Entry index of an indirect table, read in the cache
fn pointerAt(v: *Volume, table: u32, index: u64) Error!u32 {
    const s = try getBlock(v, table);
    defer unpin(s);
    return u32le(s.data[0..v.block_size], @intCast(index * 4));
}

fn put32(b: []u8, off: usize, x: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], x, .little);
}
const NewMapping = struct {
    zone: u32,
    table: u32 = 0,
    index: u32 = 0,
    pending: bool = false,
};

// The pointer is published only once the zone is written, so
// holes can't expose old data.
fn mapAlloc(v: *Volume, ino: *Inode, n: u64) Error!NewMapping {
    const per: u64 = v.block_size / 4;
    if (n < 7) {
        const i: usize = @intCast(n);
        if (ino.zones[i] == 0) ino.zones[i] = try allocateZone(v);
        return .{ .zone = ino.zones[i] };
    }
    var idx = n - 7;
    if (idx < per) {
        if (ino.zones[7] == 0) ino.zones[7] = try allocateZeroedZone(v);
        return try indirectDataAlloc(v, ino.zones[7], @intCast(idx));
    }
    idx -= per;
    if (idx >= per * per) return error.DiskFull;
    if (ino.zones[8] == 0) ino.zones[8] = try allocateZeroedZone(v);
    const outer = try indirectTableAlloc(v, ino.zones[8], @intCast(idx / per));
    return try indirectDataAlloc(v, outer, @intCast(idx % per));
}

// Frees the file's zones from data block keep on, and the
// tables left empty.
// The inode changes in memory: the caller writes it.
fn freeBlocksFrom(v: *Volume, ino: *Inode, keep: u64) Error!void {
    const per: u64 = v.block_size / 4;
    var list: FreeList = .{};
    for (0..7) |i| {
        if (i < keep or ino.zones[i] == 0) continue;
        try freeLater(v, &list, ino.zones[i]);
        ino.zones[i] = 0;
    }
    if (ino.zones[7] != 0 and keep < 7 + per) {
        if (try freeFrom(v, &list, ino.zones[7], 1, if (keep > 7) keep - 7 else 0)) ino.zones[7] = 0;
    }
    if (ino.zones[8] != 0 and keep < 7 + per + per * per) {
        if (try freeFrom(v, &list, ino.zones[8], 2, if (keep > 7 + per) keep - 7 - per else 0)) ino.zones[8] = 0;
    }
    try freeZones(v, &list);
}

// Points data blocks logical.. of the file (holes now)
// at zones first.. (count of them): direct pointers in
// memory (the caller writes the inode), indirect ones
// with one write per table. pointed counts those done.
fn pointRun(v: *Volume, ino: *Inode, logical: u64, first: u32, count: u32, pointed: *u32) Error!void {
    while (pointed.* < count) {
        const at = logical + pointed.*;
        const zone = first + pointed.*;
        if (at < 7) {
            ino.zones[@intCast(at)] = zone;
            pointed.* += 1;
            continue;
        }
        const leaf = try leafTable(v, ino, at);
        const room: u32 = @intCast(@min(count - pointed.*, v.block_size / 4 - leaf.index));
        const s = try getBlock(v, leaf.table);
        for (0..room) |k| put32(&s.data, @intCast((leaf.index + k) * 4), zone + @as(u32, @intCast(k)));
        try writeBlock(v, leaf.table, s.data[0..v.block_size]);
        pointed.* += room;
    }
}

// The indirect table holding data block at's pointer (at is 7
// or more), and the index there; missing tables are made
fn leafTable(v: *Volume, ino: *Inode, at: u64) Error!struct { table: u32, index: u64 } {
    const per: u64 = v.block_size / 4;
    var idx = at - 7;
    if (idx < per) {
        if (ino.zones[7] == 0) ino.zones[7] = try allocateZeroedZone(v);
        return .{ .table = ino.zones[7], .index = idx };
    }
    idx -= per;
    if (idx >= per * per) return error.DiskFull;
    if (ino.zones[8] == 0) ino.zones[8] = try allocateZeroedZone(v);
    return .{ .table = try indirectTableAlloc(v, ino.zones[8], @intCast(idx / per)), .index = idx % per };
}

const max_run_bytes = 256 * 1024; // the most read or written in one device call

fn runBlocks(v: *const Volume) u32 {
    return @max(1, max_run_bytes / v.block_size);
}

// Zones first.. in a row (count of them) read or written in one
// device call, around the cache (file data doesn't push
// metadata out of it). The cache writes through, so the disk is
// current for a read; a write drops cached copies first.
fn readRun(v: *Volume, first: u32, count: u32, out: []u8) Error!void {
    if (first < v.first_zone or first + count > v.zones) return error.DeviceError;
    const spb = v.block_size / sector_size;
    try v.dev.read(v.dev.ctx, blockLba(v, first), @as(usize, count) * spb, out[0 .. @as(usize, count) * v.block_size]);
}

fn writeRun(v: *Volume, first: u32, count: u32, data: []const u8) Error!void {
    if (v.write_failed) return error.DeviceError;
    if (first < v.first_zone or first + count > v.zones) return error.DeviceError;
    for (0..count) |i| discardBlock(v, first + @as(u32, @intCast(i)));
    const spb = v.block_size / sector_size;
    devWrite(v, blockLba(v, first), @as(usize, count) * spb, data[0 .. @as(usize, count) * v.block_size]) catch |err| {
        v.write_failed = true;
        return err;
    };
}

fn indirectTableAlloc(v: *Volume, table: u32, index: u32) Error!u32 {
    var b: [4096]u8 = undefined;
    try block(v, table, b[0..v.block_size]);
    const off: usize = @as(usize, index) * 4;
    var value = u32le(&b, off);
    if (value == 0) {
        value = try allocateZeroedZone(v);
        put32(&b, off, value);
        try writeBlock(v, table, b[0..v.block_size]);
    }
    return value;
}

fn indirectDataAlloc(v: *Volume, table: u32, index: u32) Error!NewMapping {
    var b: [4096]u8 = undefined;
    try block(v, table, b[0..v.block_size]);
    const off: usize = @as(usize, index) * 4;
    const value = u32le(&b, off);
    if (value != 0) return .{ .zone = value };
    return .{ .zone = try allocateZone(v), .table = table, .index = index, .pending = true };
}

fn commitMapping(v: *Volume, mapping: NewMapping) Error!void {
    if (!mapping.pending) return;
    var b: [4096]u8 = undefined;
    try block(v, mapping.table, b[0..v.block_size]);
    const off: usize = @as(usize, mapping.index) * 4;
    if (u32le(&b, off) != 0) return error.DeviceError;
    put32(&b, off, mapping.zone);
    try writeBlock(v, mapping.table, b[0..v.block_size]);
}

fn writeAt(v: *Volume, ino: *Inode, pos: u64, src: []const u8) Error!usize {
    if (pos > v.max_size or src.len > v.max_size - pos) return error.DiskFull;
    var done: usize = 0;
    while (done < src.len) {
        const p = pos + done;
        const logical = p / v.block_size;
        const existing = try map(v, ino, logical);
        const off: usize = @intCast(p % v.block_size);
        // Whole blocks from here on: in runs, one device write each
        const whole: u32 = if (off == 0) @intCast(@min((src.len - done) / v.block_size, runBlocks(v))) else 0;
        if (whole > 0 and existing != 0) {
            var count: u32 = 1;
            while (count < whole and try map(v, ino, logical + count) == existing +% count) count += 1;
            try writeRun(v, existing, count, src[done..]);
            done += @as(usize, count) * v.block_size;
            continue;
        }
        if (whole > 0) {
            // Holes: new zones in a row, written before anything points at
            // them (freed again if that fails, so they never show old data)
            var holes: u32 = 1;
            while (holes < whole and try map(v, ino, logical + holes) == 0) holes += 1;
            const run = try allocateRun(v, holes);
            const first = run.first;
            const count = run.count;
            writeRun(v, first, count, src[done..]) catch |err| {
                for (0..count) |i| freeZone(v, first + @as(u32, @intCast(i))) catch {};
                return err;
            };
            var pointed: u32 = 0;
            pointRun(v, ino, logical, first, count, &pointed) catch |err| {
                for (pointed..count) |i| freeZone(v, first + @as(u32, @intCast(i))) catch {};
                return err;
            };
            done += @as(usize, count) * v.block_size;
            continue;
        }
        const take = @min(src.len - done, v.block_size - off);
        var mapping: ?NewMapping = null;
        const bn = if (existing == 0) blk: {
            mapping = try mapAlloc(v, ino, logical);
            break :blk mapping.?.zone;
        } else existing;
        const b = if (existing == 0) try bzero(v, bn) else blk: {
            const slot = try getBlock(v, bn);
            break :blk slot.data[0..v.block_size];
        };
        @memcpy(b[off .. off + take], src[done .. done + take]);
        try writeBlock(v, bn, b);
        if (mapping) |new_mapping| try commitMapping(v, new_mapping);
        done += take;
    }
    ino.size = @max(ino.size, pos + done);
    return done;
}

fn readAt(v: *Volume, ino: *const Inode, pos: u64, out: []u8) Error!usize {
    if (pos >= ino.size or out.len == 0) return 0;
    const amt: usize = @intCast(@min(ino.size - pos, out.len));
    var done: usize = 0;
    while (done < amt) {
        const p = pos + done;
        const logical = p / v.block_size;
        const off: usize = @intCast(p % v.block_size);
        const bn = try map(v, ino, logical);
        // Whole blocks in a row on the disk: one device read
        const whole: u32 = if (off == 0 and bn != 0) @intCast(@min((amt - done) / v.block_size, runBlocks(v))) else 0;
        if (whole > 0) {
            var count: u32 = 1;
            while (count < whole and try map(v, ino, logical + count) == bn +% count) count += 1;
            try readRun(v, bn, count, out[done..]);
            done += @as(usize, count) * v.block_size;
            continue;
        }
        const take = @min(amt - done, v.block_size - off);
        if (bn == 0) @memset(out[done .. done + take], 0) else {
            const s = try getBlock(v, bn);
            defer unpin(s);
            @memcpy(out[done .. done + take], s.data[off..][0..take]);
        }
        done += take;
    }
    return done;
}

fn readDirBlock(v: *Volume, dir: *const Inode, pos: u64, b: []u8) Error!u32 {
    const zone = try map(v, dir, pos / v.block_size);
    if (zone == 0) @memset(b, 0) else try block(v, zone, b);
    return zone;
}

fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn lookup(v: *Volume, dir_ino: u32, name: []const u8) Error!u32 {
    const d = try inode(v, dir_ino);
    if (d.mode & 0xf000 != 0x4000) return error.NotADirectory;
    if (name.len <= 60) {
        if (dirIndex(v, dir_ino)) |indexed| {
            if (indexed.complete) return (try nameIndexLookup(v, &d, indexed, name)) orelse error.NotFound;
        }
        // The index is (re)built now. With few empty slots left (live
        // names of directories no longer in use, or tombstones) every
        // probe gets long: start afresh; the
        // indexes dropped are rebuilt when next used
        if (name_index_empty < name_index_slots / 8) clearNameIndex();
    }
    const indexed = if (name.len <= 60) ensureDirIndex(v, dir_ino) else null;
    if (indexed) |idx| idx.complete = false;
    var found: ?u32 = null;
    var index_complete = true;
    var b: [4096]u8 = undefined;
    var base: u64 = 0;
    while (base + 64 <= d.size) : (base += v.block_size) {
        _ = try readDirBlock(v, &d, base, b[0..v.block_size]);
        const limit: usize = @intCast(@min(v.block_size, d.size - base));
        var off: usize = 0;
        while (off + 64 <= limit) : (off += 64) {
            const ent = b[off..][0..64];
            const child = u32le(ent, 0);
            if (child == 0) continue;
            const n = std.mem.indexOfScalar(u8, ent[4..], 0) orelse 60;
            const entry_name = ent[4 .. 4 + n];
            if (indexed) |idx| {
                if (!nameIndexPut(idx, entry_name, base + off)) index_complete = false;
            }
            if (found == null and same(name, entry_name)) found = child;
        }
    }
    if (indexed) |idx| idx.complete = index_complete;
    return found orelse error.NotFound;
}

fn finishDirEntryInsert(v: *Volume, dir_ino: u32, d: *Inode, name: []const u8, pos: u64) Error!void {
    d.mtime = currentTime();
    d.ctime = d.mtime;
    try writeInode(v, dir_ino, d);
    if (dirIndex(v, dir_ino)) |idx| {
        if (idx.complete and !nameIndexPut(idx, name, pos)) idx.complete = false;
    }
    rememberDirectoryCursor(v, dir_ino, pos);
}

fn putDirEntry(v: *Volume, dir_ino: u32, name: []const u8, target: u32) Error!void {
    if (name.len == 0 or name.len > 60 or std.mem.indexOfAny(u8, name, "/\\\x00") != null) return error.InvalidName;
    var d = try inode(v, dir_ino);
    if (d.mode & 0xf000 != 0x4000) return error.NotADirectory;
    var ent = [_]u8{0} ** 64;
    var pos = directoryCursor(v, dir_ino);
    if (pos > d.size or pos % 64 != 0) pos = 0;
    while (pos + 64 <= d.size) {
        const base = pos - pos % v.block_size;
        const zone = try map(v, &d, base / v.block_size);
        const block_end = @min(d.size, base + v.block_size);
        if (zone == 0) {
            put32(&ent, 0, target);
            @memcpy(ent[4 .. 4 + name.len], name);
            _ = try writeAt(v, &d, pos, &ent);
            try finishDirEntryInsert(v, dir_ino, &d, name, pos);
            return;
        }

        const slot = try getBlock(v, zone);
        const b = slot.data[0..v.block_size];
        while (pos + 64 <= block_end) : (pos += 64) {
            const off: usize = @intCast(pos - base);
            if (u32le(b, off) != 0) continue;
            put32(b, off, target);
            @memset(b[off + 4 ..][0..60], 0);
            @memcpy(b[off + 4 ..][0..name.len], name);
            try writeBlock(v, zone, b);
            try finishDirEntryInsert(v, dir_ino, &d, name, pos);
            return;
        }
        unpin(slot);
    }
    if (d.size % 64 != 0) return error.DeviceError;
    const append_pos = d.size;
    @memset(&ent, 0);
    put32(&ent, 0, target);
    @memcpy(ent[4 .. 4 + name.len], name);
    _ = try writeAt(v, &d, append_pos, &ent);
    try finishDirEntryInsert(v, dir_ino, &d, name, append_pos);
}

fn removeDirEntry(v: *Volume, dir_ino: u32, name: []const u8) Error!u32 {
    var d = try inode(v, dir_ino);
    var pos: u64 = 0;
    var b: [4096]u8 = undefined;
    while (pos + 64 <= d.size) : (pos += v.block_size) {
        _ = try readDirBlock(v, &d, pos, b[0..v.block_size]);
        const limit: usize = @intCast(@min(v.block_size, d.size - pos));
        var off: usize = 0;
        while (off + 64 <= limit) : (off += 64) {
            const ent = b[off..][0..64];
            const n = u32le(ent, 0);
            const len = std.mem.indexOfScalar(u8, ent[4..], 0) orelse 60;
            if (n != 0 and same(name, ent[4 .. 4 + len])) {
                var changed: [64]u8 = undefined;
                @memcpy(&changed, ent);
                put32(&changed, 0, 0);
                const entry_pos = pos + off;
                _ = try writeAt(v, &d, entry_pos, &changed);
                // From an incomplete index too: its rebuild keeps what is in it
                if (dirIndex(v, dir_ino)) |idx| nameIndexRemove(idx, name, entry_pos);
                rewindDirectoryCursor(v, dir_ino, entry_pos);
                d.mtime = currentTime();
                d.ctime = d.mtime;
                try writeInode(v, dir_ino, &d);
                return n;
            }
        }
    }
    return error.NotFound;
}

fn trimSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) : (end -= 1) {}
    return path[0..end];
}

fn parent(v: *Volume, path: []const u8) Error!struct { ino: u32, name: []const u8 } {
    const p = trimSeparators(path);
    const i = std.mem.lastIndexOfAny(u8, p, "/\\");
    const name = if (i) |at| p[at + 1 ..] else p;
    if (name.len == 0 or name.len > 60 or same(name, ".") or same(name, "..")) return error.InvalidName;
    const parent_path = if (i) |at| p[0..at] else "";
    const pino = if (parent_path.len == 0) 1 else try resolve(v, parent_path);
    const pi = try inode(v, pino);
    if (pi.mode & 0xf000 != 0x4000) return error.PathNotFound;
    return .{ .ino = pino, .name = name };
}

fn containsDir(v: *Volume, ancestor: u32, candidate: u32) Error!bool {
    var cur = candidate;
    var steps: u32 = 0;
    while (steps <= v.inode_count) : (steps += 1) {
        if (cur == ancestor) return true;
        if (cur == 1) return false;
        const d = try inode(v, cur);
        var e: [64]u8 = undefined;
        _ = try readAt(v, &d, 64, &e);
        const next = u32le(&e, 0);
        if (next == 0 or next == cur) return error.DeviceError;
        cur = next;
    }
    return error.DeviceError;
}

fn resolve(v: *Volume, path: []const u8) Error!u32 {
    var cur: u32 = 1;
    var it = std.mem.tokenizeAny(u8, path, "/\\");
    while (it.next()) |part| {
        cur = lookup(v, cur, part) catch |err| return if (err == error.NotFound and it.peek() != null) error.PathNotFound else err;
    }
    return cur;
}

fn date(timestamp: u32) platform.DateTime {
    if (timestamp == 0) return platform.no_date;
    var days: u32 = timestamp / 86400;
    const seconds = timestamp % 86400;
    var year: u16 = 1970;
    while (true) {
        const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
        const count: u32 = if (leap) 366 else 365;
        if (days < count) break;
        days -= count;
        year += 1;
    }
    const months = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    var month: u8 = 1;
    for (months, 0..) |raw, i| {
        const count: u32 = if (i == 1 and leap) 29 else raw;
        if (days < count) break;
        days -= count;
        month += 1;
    }
    return .{ .year = year, .month = month, .day = @intCast(days + 1), .hour = @intCast(seconds / 3600), .minute = @intCast((seconds % 3600) / 60), .second = @intCast(seconds % 60) };
}

fn currentTime() u32 {
    const t = platform.clock.now() orelse return 0;
    return unixTime(t);
}

fn info(v: *Volume, ino: u32, nm: []const u8, out: *platform.EntryInfo) Error!void {
    const x = try inode(v, ino);
    out.* = .{};
    const n = @min(nm.len, out.name_buf.len);
    @memcpy(out.name_buf[0..n], nm[0..n]);
    out.name_len = n;
    out.is_dir = x.mode & 0xf000 == 0x4000;
    out.size = x.size;
    out.modified = date(x.mtime);
    // created:
    // Minix has no creation time (ctime is the inode's last change)
    out.accessed = date(x.atime);
    out.attrs = if (x.mode & 0o222 == 0) platform.Attr.read_only else 0;
    out.unix = .{ .mode = x.mode, .uid = x.uid, .gid = x.gid, .ino = ino, .links = x.links, .blocks = (x.size + 511) / 512, .changed = date(x.ctime) };
}
pub fn stat(v: *Volume, path: []const u8, out: *platform.EntryInfo) Error!void {
    const n = try resolve(v, path);
    try info(v, n, pathName(path), out);
}

fn pathName(path: []const u8) []const u8 {
    const p = trimSeparators(path);
    return if (std.mem.lastIndexOfAny(u8, p, "/\\")) |i| p[i + 1 ..] else p;
}
pub fn openFile(v: *Volume, path: []const u8, mode: platform.OpenMode, f: *File) Error!void {
    // A file opened for writing stays a writer (the volume "not
    // clean") until its close; the defer
    // is the function's, not the if's
    var keep_writer = false;
    if (mode != .read) try beginWrite(v);
    defer if (mode != .read and !keep_writer) endWrite(v);
    const n = resolve(v, path) catch |err| blk: {
        if (err != error.NotFound or mode == .read) return err;
        if (!v.writable) return error.WriteProtected;
        const p = try parent(v, path);
        // resolve() proved the last component absent: no second scan:
        const new_ino = try allocateInode(v);
        const x = Inode{ .mode = 0o100644, .links = 1, .uid = @truncate(platform.new_owner.uid), .gid = @truncate(platform.new_owner.gid), .size = 0, .atime = currentTime(), .mtime = currentTime(), .ctime = currentTime(), .zones = [_]u32{0} ** 10 };
        writeInode(v, new_ino, &x) catch |e| {
            bitmapUpdate(v, 2, new_ino, false) catch {};
            return e;
        };
        putDirEntry(v, p.ino, p.name, new_ino) catch |e| {
            bitmapUpdate(v, 2, new_ino, false) catch {};
            return e;
        };
        break :blk new_ino;
    };
    var x = try inode(v, n);
    if (x.mode & 0xf000 == 0x4000) return error.IsADirectory;
    if (mode != .read and x.mode & 0o222 == 0) return error.AccessDenied;
    if (mode == .write) {
        if (!v.writable) return error.WriteProtected;
        try emptyInode(v, n, &x);
    }
    f.* = .{ .in_use = true, .size = x.size, .v = v, .ino = n, .gen = v.generation, .writable = mode != .read };
    keep_writer = mode != .read;
}
pub fn read(f: *File, b: []u8) Error!usize {
    if (!f.in_use or f.gen != f.v.generation) return error.InvalidHandle;
    var x = try inode(f.v, f.ino);
    const n = try readAt(f.v, &x, f.pos, b);
    f.pos += n;
    return n;
}
pub fn seek(f: *File, p: u64) Error!void {
    if (!f.in_use or f.gen != f.v.generation) return error.InvalidHandle;
    f.pos = if (p == platform.seek_end) f.size else p;
}
pub fn write(f: *File, data: []const u8) Error!usize {
    if (!f.in_use or f.gen != f.v.generation) return error.InvalidHandle;
    if (!f.writable) return error.AccessDenied;
    if (f.v.write_failed) return error.DeviceError;
    if (data.len == 0) return 0;
    try markDirty(f.v); // again, if a commit marked it clean
    var x = try inode(f.v, f.ino);
    const n = try writeAt(f.v, &x, f.pos, data);
    x.mtime = currentTime();
    x.ctime = x.mtime;
    try writeInode(f.v, f.ino, &x);
    f.pos += n;
    f.size = x.size;
    return n;
}
pub fn setSize(f: *File, size: u64) Error!void {
    if (!f.in_use or f.gen != f.v.generation) return error.InvalidHandle;
    if (!f.writable) return error.AccessDenied;
    if (size > f.v.max_size) return error.DiskFull;
    try markDirty(f.v); // again, if a commit marked it clean
    var x = try inode(f.v, f.ino);
    if (size < x.size) {
        try freeBlocksFrom(f.v, &x, (size + f.v.block_size - 1) / f.v.block_size);
        if (size % f.v.block_size != 0) {
            // The new last block's tail is cleared:
            // growing again shows zeros
            const bn = try map(f.v, &x, size / f.v.block_size);
            if (bn != 0) {
                const s = try getBlock(f.v, bn);
                @memset(s.data[@intCast(size % f.v.block_size)..f.v.block_size], 0);
                try writeBlock(f.v, bn, s.data[0..f.v.block_size]);
            }
        }
    }
    x.size = size;
    x.ctime = currentTime();
    x.mtime = x.ctime;
    try writeInode(f.v, f.ino, &x);
    f.size = size;
}
// Everything written so far put on the disk and the volume
// marked clean, though the file stays open: a reset now loses
// nothing and needs no check. The next write marks it "not
// clean" again (markDirty in write, setSize).
pub fn commit(f: *File) Error!void {
    if (!f.in_use or f.gen != f.v.generation) return error.InvalidHandle;
    if (!f.writable) return;
    if (!f.v.clean) return markClean(f.v);
    if (f.v.unflushed) try putOnDisk(f.v);
}
pub fn close(f: *File) Error!void {
    if (!f.in_use) return error.InvalidHandle;
    if (f.writable) {
        if (f.gen == f.v.generation) endWrite(f.v) else if (f.v.writers != 0) f.v.writers -= 1;
    }
    f.in_use = false;
}
pub fn fstat(f: *File, out: *platform.EntryInfo) Error!void {
    if (!f.in_use or f.gen != f.v.generation) return error.InvalidHandle;
    try info(f.v, f.ino, "", out);
}
pub fn setModifiedOpen(f: *File, when: platform.DateTime) Error!void {
    if (!f.in_use or f.gen != f.v.generation) return error.InvalidHandle;
    try beginWrite(f.v);
    defer endWrite(f.v);
    var x = try inode(f.v, f.ino);
    x.mtime = unixTime(when);
    x.ctime = currentTime();
    try writeInode(f.v, f.ino, &x);
}
pub fn openDir(v: *Volume, path: []const u8, d: *Dir) Error!void {
    const n = try resolve(v, path);
    const x = try inode(v, n);
    if (x.mode & 0xf000 != 0x4000) return error.NotADirectory;
    d.* = .{ .in_use = true, .v = v, .ino = n, .gen = v.generation };
}
pub fn readDir(d: *Dir, out: *platform.EntryInfo) Error!bool {
    if (!d.in_use or d.gen != d.v.generation) return error.InvalidHandle;
    var x = try inode(d.v, d.ino);
    var e: [64]u8 = undefined;
    while (d.pos + 64 <= x.size) {
        const entry_pos = d.pos;
        d.pos += 64;
        _ = try readAt(d.v, &x, entry_pos, &e);
        const n = u32le(&e, 0);
        if (n == 0) continue;
        const len = std.mem.indexOfScalar(u8, e[4..], 0) orelse 60;
        if (same(e[4 .. 4 + len], ".") or same(e[4 .. 4 + len], "..")) continue;
        try info(d.v, n, e[4 .. 4 + len], out);
        return true;
    }
    return false;
}
pub fn makeDir(v: *Volume, path: []const u8) Error!void {
    try beginWrite(v);
    defer endWrite(v);
    const p = try parent(v, path);
    if (lookup(v, p.ino, p.name)) |_| return error.AlreadyExists else |e| if (e != error.NotFound) return e;
    const ino = try allocateInode(v);
    var child = Inode{ .mode = 0o040755, .links = 2, .uid = @truncate(platform.new_owner.uid), .gid = @truncate(platform.new_owner.gid), .size = 0, .atime = currentTime(), .mtime = currentTime(), .ctime = currentTime(), .zones = [_]u32{0} ** 10 };
    var buf = [_]u8{0} ** 128;
    put32(&buf, 0, ino);
    buf[4] = '.';
    put32(&buf, 64, p.ino);
    buf[68] = '.';
    buf[69] = '.';
    _ = try writeAt(v, &child, 0, &buf);
    child.size = v.block_size;
    try writeInode(v, ino, &child);
    try putDirEntry(v, p.ino, p.name, ino);
    var par = try inode(v, p.ino);
    par.links +|= 1;
    try writeInode(v, p.ino, &par);
}
pub fn delete(v: *Volume, path: []const u8) Error!void {
    try beginWrite(v);
    defer endWrite(v);
    const p = try parent(v, path);
    const ino = try lookup(v, p.ino, p.name);
    if (ino == 1) return error.AccessDenied;
    var x = try inode(v, ino);
    if (x.mode & 0o222 == 0) return error.AccessDenied; // read only, as in DOS
    const is_dir = x.mode & 0xf000 == 0x4000;
    if (is_dir) {
        var pos: u64 = 0;
        var e: [64]u8 = undefined;
        while (pos + 64 <= x.size) : (pos += 64) {
            _ = try readAt(v, &x, pos, &e);
            const n = u32le(&e, 0);
            if (n == 0) continue;
            const len = std.mem.indexOfScalar(u8, e[4..], 0) orelse 60;
            if (!same(e[4 .. 4 + len], ".") and !same(e[4 .. 4 + len], "..")) return error.DirNotEmpty;
        }
    }
    _ = try removeDirEntry(v, p.ino, p.name);
    if (!is_dir and x.links > 1) {
        x.links -= 1;
        try writeInode(v, ino, &x);
        return;
    }
    try emptyInode(v, ino, &x);
    try bitmapUpdate(v, 2, ino, false);
    if (is_dir) discardDirIndex(v, ino);
    if (is_dir) {
        var par = try inode(v, p.ino);
        if (par.links != 0) par.links -= 1;
        try writeInode(v, p.ino, &par);
    }
}
pub fn rename(v: *Volume, from: []const u8, to: []const u8) Error!void {
    try beginWrite(v);
    defer endWrite(v);
    const a = try parent(v, from);
    const b = try parent(v, to);
    const src = try lookup(v, a.ino, a.name);
    const src_inode = try inode(v, src);
    const src_is_dir = src_inode.mode & 0xf000 == 0x4000;
    if (src_is_dir and try containsDir(v, src, b.ino)) return error.InvalidArgument;
    if (lookup(v, b.ino, b.name)) |dest| {
        if (src == dest) return;
        const dest_inode = try inode(v, dest);
        if (src_is_dir != (dest_inode.mode & 0xf000 == 0x4000)) return error.AccessDenied;
        try delete(v, to);
    } else |e| if (e != error.NotFound) return e;
    const ino = src;
    var x = try inode(v, ino);
    const is_dir = x.mode & 0xf000 == 0x4000;
    const moved_dir = is_dir and a.ino != b.ino;
    // Counts go up before the new names and down after the old
    // ones: a cut between leaves counts too high (a leak), never
    // a name on a count that misses it:
    x.links +|= 1;
    try writeInode(v, ino, &x);
    if (moved_dir) {
        var new_parent = try inode(v, b.ino);
        new_parent.links +|= 1;
        try writeInode(v, b.ino, &new_parent);
    }
    try putDirEntry(v, b.ino, b.name, ino);
    _ = try removeDirEntry(v, a.ino, a.name);
    if (moved_dir) {
        var d = try inode(v, ino);
        var parent_entry: [4]u8 = undefined;
        std.mem.writeInt(u32, &parent_entry, b.ino, .little);
        _ = try writeAt(v, &d, 64, &parent_entry); // the index has its place: unchanged
        try writeInode(v, ino, &d);
        var old_parent = try inode(v, a.ino);
        if (old_parent.links > 0) old_parent.links -= 1;
        try writeInode(v, a.ino, &old_parent);
    }
    var y = try inode(v, ino);
    if (y.links > 0) y.links -= 1;
    try writeInode(v, ino, &y);
}
pub fn setAttributes(v: *Volume, path: []const u8, attrs: u8) Error!void {
    if (attrs & ~@as(u8, platform.Attr.read_only) != 0) return error.NotSupported;
    try beginWrite(v);
    defer endWrite(v);
    const ino = try resolve(v, path);
    var x = try inode(v, ino);
    if (attrs & platform.Attr.read_only != 0) x.mode &= ~@as(u16, 0o222) else x.mode |= 0o222;
    x.ctime = currentTime();
    try writeInode(v, ino, &x);
}
pub fn setModified(v: *Volume, path: []const u8, when: platform.DateTime) Error!void {
    try beginWrite(v);
    defer endWrite(v);
    const ino = try resolve(v, path);
    var x = try inode(v, ino);
    x.mtime = unixTime(when);
    x.ctime = currentTime();
    try writeInode(v, ino, &x);
}
pub fn setLabel(_: *Volume, _: []const u8) Error!void {
    return error.NotSupported;
}
pub fn permissions(v: *Volume, path: []const u8) Error!platform.Permissions {
    const x = try inode(v, try resolve(v, path));
    return .{ .mode = x.mode, .uid = x.uid, .gid = x.gid };
}
pub fn setMode(v: *Volume, path: []const u8, mode: u16) Error!void {
    if (mode & ~@as(u16, 0o7777) != 0) return error.InvalidArgument;
    try beginWrite(v);
    defer endWrite(v);
    const ino = try resolve(v, path);
    var x = try inode(v, ino);
    x.mode = (x.mode & 0xf000) | mode;
    x.ctime = currentTime();
    try writeInode(v, ino, &x);
}
pub fn setOwner(v: *Volume, path: []const u8, uid: ?u32, gid: ?u32) Error!void {
    if ((uid != null and uid.? > 0xffff) or (gid != null and gid.? > 0xffff)) return error.InvalidArgument;
    try beginWrite(v);
    defer endWrite(v);
    const ino = try resolve(v, path);
    var x = try inode(v, ino);
    if (uid) |u| x.uid = @intCast(u);
    if (gid) |g| x.gid = @intCast(g);
    x.mode &= ~@as(u16, 0o6000);
    x.ctime = currentTime();
    try writeInode(v, ino, &x);
}

fn unixTime(t: platform.DateTime) u32 {
    if (t.year < 1970 or t.month < 1 or t.month > 12) return 0;
    const y: i64 = @as(i64, t.year) - @intFromBool(t.month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = t.month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + @as(i64, t.day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    const secs = days * 86400 + @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second;
    return @intCast(std.math.clamp(secs, 0, std.math.maxInt(u32)));
}
pub fn blockBytes(v: *const Volume) u32 {
    return v.block_size;
}

pub fn sizeBytes(v: *Volume) u64 {
    return @as(u64, v.zones) * v.block_size;
}
// Counts the clear bits of the zone bitmap (bits 1 to zones -
// first_zone), a byte at a time where it can
pub fn freeBytes(v: *Volume) u64 {
    const map_start: u32 = 2 + v.inode_map_blocks;
    const bits = v.zones - v.first_zone;
    const bits_per_block = v.block_size * 8;
    var free: u64 = 0;
    var map_block: u32 = 0;
    while (map_block <= bits / bits_per_block) : (map_block += 1) {
        const s = getBlock(v, map_start + map_block) catch return free * v.block_size;
        defer unpin(s);
        const first_bit = map_block * bits_per_block;
        const last_bit = @min(bits, first_bit + bits_per_block - 1);
        var bit = @max(first_bit, 1);
        while (bit <= last_bit) {
            const rel = bit - first_bit;
            const byte = s.data[rel / 8];
            if (rel % 8 == 0 and bit + 7 <= last_bit) {
                free += 8 - @as(u64, @popCount(byte));
                bit += 8;
                continue;
            }
            if (byte & (@as(u8, 1) << @intCast(rel % 8)) == 0) free += 1;
            bit += 1;
        }
    }
    return free * v.block_size;
}
pub fn fsName(_: *Volume) []const u8 {
    return "Minix V3";
}
pub fn label(_: *Volume, _: []u8) usize {
    return 0;
}
