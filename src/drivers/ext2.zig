// ext2 (and ext3 with a clean journal), blocks of 1 to 64 KB:
// the file and directory functions of platform.storage, as
// fat.zig has them. Volumes with features it can't keep
// consistent, or not cleanly unmounted, are read only.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform.zig");

const Error = platform.Error;

comptime {
    if (builtin.cpu.arch.endian() != .little) @compileError("ext2.zig copies inodes as they are on disk: little-endian only");
}

pub const sector_size = 512;

// Where a volume's sectors come from, as fat.Device; lba counts
// from the start of the disk
pub const Device = struct {
    ctx: *const anyopaque,
    read: *const fn (ctx: *const anyopaque, lba: u64, count: usize, buf: []u8) Error!void,
    write: *const fn (ctx: *const anyopaque, lba: u64, count: usize, data: []const u8) Error!void,
    // Puts what was written on the medium (the
    // drive's write cache emptied); null where the
    // backend has no way to (BIOS)
    flush: ?*const fn (ctx: *const anyopaque) Error!void = null,
};

const ext2_magic = 0xEF53;
const root_ino: u32 = 2;
const max_block = 65536;
const link_max = 32000; // EXT2_LINK_MAX
const alloc_cursor_slots = 32; // per volume: block groups being allocated in
const dir_cursor_slots = 32;
const dir_index_slots = 16;
const name_index_slots = 4096; // 64 KiB: about 3500 names in the indexed directories
const indexed_name_max = 255;
const max_run_bytes = 256 * 1024; // the most read or written in one device call

// A name in a directory index: where its entry is (records
// never move, and the name is checked
// against the directory block on a lookup)
const NameIndexState = enum(u8) { empty, tombstone, used };
const NameIndexEntry = struct {
    state: NameIndexState = .empty,
    dir_id: u32 = 0,
    hash: u32 = 0, // of the name
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

const AllocCursor = struct {
    in_use: bool = false,
    group: u32 = 0,
    block_next: u32 = 0,
    inode_next: u32 = 0,
    block_valid: bool = false,
    inode_valid: bool = false,
};

const DirCursor = struct {
    in_use: bool = false,
    ino: u32 = 0,
    pos: u64 = 0, // a record's start: where addEntry looks for room first
    gap_bound: u16 = 0, // every gap before pos is smaller than this
};

// s_state
const state_valid: u16 = 1; // cleanly unmounted
const state_error: u16 = 2;

// Feature bits this driver handles; any other incompat bit: not
// mounted, any other ro_compat bit: read only
const compat_has_journal: u32 = 0x0004;
const incompat_filetype: u32 = 0x0002;
const incompat_flex_bg: u32 = 0x0200;
const ro_compat_sparse_super: u32 = 0x0001;
const ro_compat_large_file: u32 = 0x0002;

const index_fl: u32 = 0x1000; // i_flags: a hashed directory

const s_ifmt: u16 = 0xF000;
const s_ifdir: u16 = 0x4000;
const s_ifreg: u16 = 0x8000;
const write_bits: u16 = 0o222;

// Directory entry file types (incompat_filetype)
const ft_reg: u8 = 1;
const ft_dir: u8 = 2;

const xattr_magic: u32 = 0xEA020000;

var name_index = [_]NameIndexEntry{.{}} ** name_index_slots;
var name_index_empty: usize = name_index_slots; // slots never used since the last clear
var dir_indexes = [_]DirIndex{.{}} ** dir_index_slots;
var dir_index_clock: u64 = 0;
var next_dir_index_id: u32 = 0;

pub const Volume = struct {
    dev: Device,
    start: u64, // first sector of the partition
    total_sectors: u64,
    serial: ?u32 = null, // from the UUID
    // Raised on a disk change by storage:
    // older handles become invalid
    generation: u32 = 0,

    block_size: u32,
    blocks_count: u32,
    inodes_count: u32,
    first_data_block: u32,
    blocks_per_group: u32,
    inodes_per_group: u32,
    group_count: u32,
    inode_size: u32,
    first_ino: u32, // the first inode not reserved
    filetype: bool, // directory entries carry the file type
    journal: bool, // ext3: has a journal (kept, not used: written only when clean)
    rev1: bool, // dynamic revision: has features
    ro_compat: u32, // written back with the superblock (large_file can be set)
    large_file: bool,
    writable: bool,

    free_blocks: u32, // the superblock's counts, kept here and written with it
    free_inodes: u32,
    label: [16]u8,
    super: [1024]u8, // the superblock as last read or written
    state: u16, // s_state as found when mounting
    dirty: bool = false, // the superblock on disk says "not clean"
    writers: u32 = 0, // files open for writing
    unflushed: bool = false, // written since the last flush
    alloc_cursors: [alloc_cursor_slots]AllocCursor = [_]AllocCursor{.{}} ** alloc_cursor_slots,
    next_alloc_cursor: usize = 0,
    dir_cursors: [dir_cursor_slots]DirCursor = [_]DirCursor{.{}} ** dir_cursor_slots,
    next_dir_cursor: usize = 0,
};

pub const File = struct {
    in_use: bool = false,
    size: u64 = 0, // as of the last call (storage reads it)
    v: *Volume = undefined,
    ino: u32 = 0,
    igen: u32 = 0, // the inode's i_generation: it wasn't freed and reused since
    pos: u64 = 0,
    writable: bool = false,
    gen: u32 = 0, // the volume's generation when opened
};

pub const Dir = struct {
    in_use: bool = false,
    v: *Volume = undefined,
    ino: u32 = 0,
    igen: u32 = 0,
    pos: u64 = 0, // byte offset of the next entry
    is_root: bool = false, // "." and ".." aren't listed, as in a FAT root
    gen: u32 = 0,
};

// The first 128 bytes of an inode (all of it in revision 0)
const Inode = extern struct {
    mode: u16,
    uid: u16,
    size: u32,
    atime: u32,
    ctime: u32,
    mtime: u32,
    dtime: u32,
    gid: u16,
    links: u16,
    blocks: u32, // in 512-byte units, indirect blocks included
    flags: u32,
    osd1: u32,
    block: [15]u32, // 12 direct, single, double, triple indirect
    generation: u32,
    file_acl: u32, // extended attribute block
    size_high: u32, // regular files: the size's upper 32 bits (i_dir_acl)
    faddr: u32,
    // osd2 as Linux has it
    blocks_high: u16, // huge_file only (not written: such volumes are read only)
    file_acl_high: u16,
    uid_high: u16, // the owner's upper 16 bits
    gid_high: u16,
    osd2_rest: [4]u8,
};

comptime {
    std.debug.assert(@sizeOf(Inode) == 128);
    std.debug.assert(@offsetOf(Inode, "block") == 40);
    std.debug.assert(@offsetOf(Inode, "generation") == 100);
    std.debug.assert(@offsetOf(Inode, "uid_high") == 120);
}

fn uidOf(inode: *const Inode) u32 {
    return @as(u32, inode.uid_high) << 16 | inode.uid;
}

fn gidOf(inode: *const Inode) u32 {
    return @as(u32, inode.gid_high) << 16 | inode.gid;
}

fn rd16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn rd32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn wr16(b: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, b[at..][0..2], value, .little);
}

fn wr32(b: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], value, .little);
}

fn isDir(inode: *const Inode) bool {
    return inode.mode & s_ifmt == s_ifdir;
}

fn isReg(inode: *const Inode) bool {
    return inode.mode & s_ifmt == s_ifreg;
}

fn fileSize(inode: *const Inode) u64 {
    const high: u64 = if (isReg(inode)) inode.size_high else 0;
    return high << 32 | inode.size;
}

const small_file_max: u64 = std.math.maxInt(i32); // without large_file

// What the block map reaches (12 direct, single, double, triple
// indirect), and what i_blocks can count
fn maxFileSize(v: *const Volume) u64 {
    if (!v.rev1) return small_file_max;
    const ppb: u64 = v.block_size / 4;
    const map = (12 + ppb + ppb * ppb + ppb * ppb * ppb) * v.block_size;
    const counted = @as(u64, std.math.maxInt(u32)) * sector_size;
    return @min(map, counted) - 1;
}

// A file is to grow to size: past 2 GiB the volume needs
// large_file, set at once (the superblock
// is written before the file is)
fn allowSize(v: *Volume, size: u64) Error!void {
    if (size > maxFileSize(v)) return error.DiskFull;
    if (size <= small_file_max or v.large_file) return;
    v.large_file = true;
    v.ro_compat |= ro_compat_large_file;
    try writeSuper(v, v.state & ~state_valid);
}

fn sectorsPerBlock(v: *const Volume) u32 {
    return v.block_size / sector_size;
}

fn groupOf(v: *const Volume, ino: u32) u32 {
    return (ino - 1) / v.inodes_per_group;
}

fn allocationCursor(v: *Volume, group: u32) *AllocCursor {
    for (&v.alloc_cursors) |*cursor| {
        if (cursor.in_use and cursor.group == group) return cursor;
    }
    const cursor = &v.alloc_cursors[v.next_alloc_cursor];
    v.next_alloc_cursor = (v.next_alloc_cursor + 1) % alloc_cursor_slots;
    cursor.* = .{ .in_use = true, .group = group };
    return cursor;
}

fn directoryCursor(v: *Volume, ino: u32) *DirCursor {
    for (&v.dir_cursors) |*cursor| {
        if (cursor.in_use and cursor.ino == ino) return cursor;
    }
    const cursor = &v.dir_cursors[v.next_dir_cursor];
    v.next_dir_cursor = (v.next_dir_cursor + 1) % dir_cursor_slots;
    cursor.* = .{ .in_use = true, .ino = ino };
    return cursor;
}

fn rememberDirectoryCursor(v: *Volume, ino: u32, pos: u64, gap_bound: u16) void {
    const cursor = directoryCursor(v, ino);
    cursor.pos = pos;
    cursor.gap_bound = gap_bound;
}

fn rewindDirectoryCursor(v: *Volume, ino: u32, pos: u64) void {
    const cursor = directoryCursor(v, ino);
    if (pos < cursor.pos) cursor.pos = pos;
}

// MOUNTING

// The superblock: 1024 bytes at byte 1024 of the partition
const super_lba = 2;
const super_sectors = 2;

pub fn mount(dev: Device, start: u64, sectors: u64) ?Volume {
    var sb: [1024]u8 = undefined;
    if (sectors < 8) return null;
    dev.read(dev.ctx, start + super_lba, super_sectors, &sb) catch return null;
    if (rd16(&sb, 56) != ext2_magic) return null;

    const log_block = rd32(&sb, 24);
    if (log_block > 6) return null; // 1 to 64 KB
    const block_size: u32 = @as(u32, 1024) << @intCast(log_block);
    const blocks_count = rd32(&sb, 4);
    const inodes_count = rd32(&sb, 0);
    const first_data_block = rd32(&sb, 20);
    const blocks_per_group = rd32(&sb, 32);
    const inodes_per_group = rd32(&sb, 40);
    const rev = rd32(&sb, 76);

    // Bitmaps are one block each; the superblock is in block 1 with
    // 1 KB blocks, else in block 0
    if (blocks_per_group == 0 or blocks_per_group > block_size * 8) return null;
    if (inodes_per_group == 0 or inodes_per_group > block_size * 8) return null;
    if (first_data_block != @intFromBool(block_size == 1024)) return null;
    if (blocks_count <= first_data_block or inodes_count == 0) return null;
    if (@as(u64, blocks_count) * (block_size / sector_size) > sectors) return null;
    const group_count = (blocks_count - first_data_block + blocks_per_group - 1) / blocks_per_group;
    if (@as(u64, inodes_count) > @as(u64, group_count) * inodes_per_group) return null;

    const inode_size: u32 = if (rev >= 1) rd16(&sb, 88) else 128;
    if (inode_size < 128 or inode_size > block_size or !std.math.isPowerOfTwo(inode_size)) return null;
    const first_ino: u32 = if (rev >= 1) rd32(&sb, 84) else 11;
    if (first_ino <= root_ino or first_ino > inodes_count) return null;

    const incompat: u32 = if (rev >= 1) rd32(&sb, 96) else 0;
    const compat: u32 = if (rev >= 1) rd32(&sb, 92) else 0;
    const ro_compat: u32 = if (rev >= 1) rd32(&sb, 100) else 0;
    if (incompat & ~(incompat_filetype | incompat_flex_bg) != 0) return null;
    const state = rd16(&sb, 58);

    var serial: ?u32 = null;
    if (rev >= 1) {
        var s: u32 = 0;
        var i: usize = 104;
        while (i < 120) : (i += 4) s ^= rd32(&sb, i);
        serial = s;
    }

    return .{
        .dev = dev,
        .start = start,
        .total_sectors = sectors,
        .serial = serial,
        .block_size = block_size,
        .blocks_count = blocks_count,
        .inodes_count = inodes_count,
        .first_data_block = first_data_block,
        .blocks_per_group = blocks_per_group,
        .inodes_per_group = inodes_per_group,
        .group_count = group_count,
        .inode_size = inode_size,
        .first_ino = first_ino,
        .filetype = incompat & incompat_filetype != 0,
        .journal = compat & compat_has_journal != 0,
        .rev1 = rev >= 1,
        .ro_compat = ro_compat,
        .large_file = ro_compat & ro_compat_large_file != 0,
        .writable = ro_compat & ~(ro_compat_sparse_super | ro_compat_large_file) == 0 and
            state & state_valid != 0 and state & state_error == 0,
        .free_blocks = rd32(&sb, 12),
        .free_inodes = rd32(&sb, 16),
        .label = sb[120..136].*,
        .super = sb,
        .state = state,
    };
}

// BLOCK CACHE
//
// Write-through: a changed block reaches the disk
// at once (bput). A slice from bget or bzero stays
// valid until the next call that uses the cache,
// so a block is changed and put back before
// anything else is read.

// A fixed 256 KiB pool is split into block-sized extents: 256
// blocks of 1 KiB, 64 of 4 KiB, only 4 of 64 KiB (correct, but
// slow on such volumes). File data read or written in whole
// blocks bypasses it, so it holds metadata.
const cache_unit_size = 1024;
const cache_units = 256;
const cache_slots = cache_units; // one per unit at most (1 KiB blocks)
const cache_hash_slots = 512; // twice the slots

const Slot = struct {
    ctx: ?*const anyopaque = null,
    lba: u64 = 0,
    size: u32 = 0,
    unit_start: u16 = 0,
    unit_count: u16 = 0,
    hash_next: ?u16 = null,
    lru_prev: ?u16 = null,
    lru_next: ?u16 = null,
    in_lru: bool = false,
};

var cache = [_]Slot{.{}} ** cache_slots;
var cache_hash = [_]?u16{null} ** cache_hash_slots;
var lru_front: ?u16 = null;
var lru_rear: ?u16 = null;
var cache_storage: [cache_units * cache_unit_size]u8 align(4) = undefined;
var cache_units_used = [_]bool{false} ** cache_units;
var cache_entry_count: usize = 0;
var next_free_slot: usize = 0;
var next_storage_unit: usize = 0;

fn cacheSlotIndex(s: *Slot) u16 {
    const offset = @intFromPtr(s) - @intFromPtr(&cache[0]);
    return @intCast(offset / @sizeOf(Slot));
}

fn cacheBucket(ctx: *const anyopaque, lba: u64, size: u32) usize {
    var hash: u64 = @intCast(@intFromPtr(ctx));
    hash ^= lba +% 0x9E3779B97F4A7C15 +% (hash << 6) +% (hash >> 2);
    hash ^= @as(u64, size) *% 0xBF58476D1CE4E5B9;
    hash ^= hash >> 30;
    hash *%= 0xBF58476D1CE4E5B9;
    hash ^= hash >> 27;
    return @intCast(hash & (cache_hash_slots - 1));
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

fn lruRemove(s: *Slot) void {
    if (!s.in_lru) return;
    if (s.lru_prev) |prev| cache[prev].lru_next = s.lru_next else lru_front = s.lru_next;
    if (s.lru_next) |next| cache[next].lru_prev = s.lru_prev else lru_rear = s.lru_prev;
    s.lru_prev = null;
    s.lru_next = null;
    s.in_lru = false;
}

fn touchCache(s: *Slot) void {
    if (s.ctx == null) return;
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

fn invalidateSlot(s: *Slot) void {
    if (s.ctx != null) cache_entry_count -= 1;
    hashRemove(s);
    lruRemove(s);
    const start: usize = @intCast(s.unit_start);
    const end = start + @as(usize, @intCast(s.unit_count));
    for (start..end) |unit| cache_units_used[unit] = false;
    s.* = .{};
}

fn slotData(s: *Slot) []u8 {
    const start = @as(usize, @intCast(s.unit_start)) * cache_unit_size;
    return cache_storage[start..][0..s.size];
}

fn findStorageRunIn(begin: usize, end: usize, units: usize) ?u16 {
    var start = begin;
    while (start + units <= end) {
        var offset: usize = 0;
        while (offset < units and !cache_units_used[start + offset]) : (offset += 1) {}
        if (offset == units) return @intCast(start);
        start += offset + 1;
    }
    return null;
}

fn findStorageRun(units: usize) ?u16 {
    if (units == 0 or units > cache_units) return null;
    return findStorageRunIn(next_storage_unit, cache_units, units) orelse
        findStorageRunIn(0, next_storage_unit, units);
}

fn removeDirIndex(index: *DirIndex) void {
    if (index.id != 0) {
        for (&name_index) |*entry| {
            if (entry.state == .used and entry.dir_id == index.id) entry.state = .tombstone;
        }
    }
    index.* = .{};
}

fn dirIndex(v: *const Volume, ino: u32) ?*DirIndex {
    for (&dir_indexes) |*index| {
        if (index.ctx == v.dev.ctx and index.start == v.start and index.ino == ino) {
            dir_index_clock +%= 1;
            index.used_at = dir_index_clock;
            return index;
        }
    }
    return null;
}

fn ensureDirIndex(v: *const Volume, ino: u32) *DirIndex {
    if (dirIndex(v, ino)) |index| return index;
    var chosen: ?*DirIndex = null;
    for (&dir_indexes) |*index| {
        if (index.ctx == null) {
            chosen = index;
            break;
        }
        if (chosen == null or index.used_at < chosen.?.used_at) chosen = index;
    }
    const index = chosen.?;
    removeDirIndex(index);
    next_dir_index_id +%= 1;
    if (next_dir_index_id == 0) next_dir_index_id = 1;
    dir_index_clock +%= 1;
    index.* = .{ .ctx = v.dev.ctx, .start = v.start, .ino = ino, .id = next_dir_index_id, .used_at = dir_index_clock };
    return index;
}

fn nameHash(dir_id: u32, name: []const u8) u32 {
    var hash: u64 = 14695981039346656037;
    hash = (hash ^ @as(u64, dir_id)) *% 1099511628211;
    for (name) |byte| hash = (hash ^ @as(u64, byte)) *% 1099511628211;
    return @truncate(hash ^ (hash >> 32));
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
fn nameIndexPut(index: *DirIndex, name: []const u8, pos: u64) bool {
    if (name.len > indexed_name_max) return true;
    const hash = nameHash(index.id, name);
    const at: u32 = @intCast(pos);
    if (nameIndexFind(index.id, hash, at) != null) return true;
    var slot: usize = hash & (name_index_slots - 1);
    var tombstone: ?usize = null;
    for (0..name_index_slots) |_| {
        const entry = &name_index[slot];
        if (entry.state == .tombstone and tombstone == null) tombstone = slot;
        if (entry.state == .empty) break;
        slot = (slot + 1) & (name_index_slots - 1);
    } else if (tombstone == null) {
        index.complete = false;
        return false;
    }
    if (tombstone == null) name_index_empty -= 1;
    name_index[tombstone orelse slot] = .{ .state = .used, .dir_id = index.id, .hash = hash, .pos = at };
    return true;
}

fn nameIndexRemove(index: *DirIndex, name: []const u8, pos: u64) void {
    if (name.len > indexed_name_max) return;
    if (nameIndexFind(index.id, nameHash(index.id, name), @intCast(pos))) |found| name_index[found].state = .tombstone;
}

// The directory entry at byte pos, if it is in use: its inode
// and its name (valid until the next cache call)
fn entryAt(v: *Volume, dir: *Inode, pos: u64) Error!?struct { ino: u32, name: []const u8 } {
    const bs: u64 = v.block_size;
    if (pos >= fileSize(dir)) return null;
    const block = try mapBlock(v, dir, pos / bs, false, 0);
    if (block == 0) return null;
    const b = try bget(v, block);
    const off: usize = @intCast(pos % bs);
    const r = try record(b, off);
    if (r.ino == 0) return null;
    return .{ .ino = r.ino, .name = b[off + 8 ..][0..r.name_len] };
}

// Looks name up in a complete index, as findEntry does
// (letter case counts). Each candidate's name is read from
// the directory and compared.
fn nameIndexLookup(v: *Volume, dir: *Inode, index: *const DirIndex, name: []const u8, out: *Found) Error!bool {
    const hash = nameHash(index.id, name);
    var slot: usize = hash & (name_index_slots - 1);
    for (0..name_index_slots) |_| {
        const entry = name_index[slot];
        if (entry.state == .empty) break;
        slot = (slot + 1) & (name_index_slots - 1);
        if (entry.state != .used or entry.dir_id != index.id or entry.hash != hash) continue;
        const found = (try entryAt(v, dir, entry.pos)) orelse continue;
        if (!std.mem.eql(u8, found.name, name)) continue;
        out.ino = found.ino;
        out.name_len = found.name.len;
        @memcpy(out.name_buf[0..found.name.len], found.name);
        return true;
    }
    return false;
}

// Removed entries become tombstones, never empty again, and a
// probe stops only at an empty slot: when few are left as an
// index is built, every slot is emptied
// (and every directory index dropped)
fn clearNameIndex() void {
    for (&name_index) |*entry| entry.state = .empty;
    for (&dir_indexes) |*index| index.* = .{};
    name_index_empty = name_index_slots;
}

fn discardDirIndex(v: *const Volume, ino: u32) void {
    if (dirIndex(v, ino)) |index| removeDirIndex(index);
}

fn discardDirectoryCursor(v: *Volume, ino: u32) void {
    for (&v.dir_cursors) |*cursor| {
        if (cursor.in_use and cursor.ino == ino) cursor.* = .{};
    }
}

// Drops the cached blocks of a disk
// (it was written directly, or changed)
pub fn forget(dev_ctx: *const anyopaque) void {
    for (&cache) |*s| {
        if (s.ctx == dev_ctx) invalidateSlot(s);
    }
    for (&dir_indexes) |*index| {
        if (index.ctx == dev_ctx) removeDirIndex(index);
    }
}

fn devRead(v: *const Volume, lba: u64, count: usize, buf: []u8) Error!void {
    return v.dev.read(v.dev.ctx, lba, count, buf);
}

fn devWrite(v: *Volume, lba: u64, count: usize, data: []const u8) Error!void {
    v.unflushed = true;
    return v.dev.write(v.dev.ctx, lba, count, data);
}

fn devFlush(v: *Volume) Error!void {
    if (v.dev.flush) |flush| try flush(v.dev.ctx);
    v.unflushed = false;
}

// Block 0 is never data or metadata
// (0 means "none" in block pointers)
fn checkBlock(v: *const Volume, block: u32) Error!void {
    if (block == 0 or block >= v.blocks_count) return error.DeviceError;
}

fn blockLba(v: *const Volume, block: u32) u64 {
    return v.start + @as(u64, block) * sectorsPerBlock(v);
}

fn cached(v: *const Volume, lba: u64) ?*Slot {
    const bucket = cacheBucket(v.dev.ctx, lba, v.block_size);
    var link = cache_hash[bucket];
    while (link) |at| {
        const s = &cache[at];
        if (s.ctx == v.dev.ctx and s.lba == lba and s.size == v.block_size) return s;
        link = s.hash_next;
    }
    return null;
}

fn freeSlot(size: u32) Error!*Slot {
    if (size == 0 or size % cache_unit_size != 0 or size > max_block) return error.DeviceError;
    const units: usize = @intCast(size / cache_unit_size);
    while (true) {
        var empty: ?*Slot = null;
        if (cache_entry_count < cache_slots) {
            for (0..cache_slots) |offset| {
                const index = (next_free_slot + offset) % cache_slots;
                const s = &cache[index];
                if (s.ctx == null and s.unit_count == 0) {
                    empty = s;
                    next_free_slot = (index + 1) % cache_slots;
                    break;
                }
            }
        }
        if (empty) |s| {
            if (findStorageRun(units)) |start| {
                s.unit_start = start;
                s.unit_count = @intCast(units);
                s.size = size;
                const first: usize = @intCast(start);
                for (first..first + units) |unit| cache_units_used[unit] = true;
                next_storage_unit = if (first + units < cache_units) first + units else 0;
                return s;
            }
        }
        const victim = if (lru_front) |index| &cache[index] else return error.DeviceError;
        invalidateSlot(victim);
    }
}

fn bget(v: *Volume, block: u32) Error![]u8 {
    try checkBlock(v, block);
    const lba = blockLba(v, block);
    if (cached(v, lba)) |s| {
        touchCache(s);
        return slotData(s);
    }
    const s = try freeSlot(v.block_size);
    devRead(v, lba, sectorsPerBlock(v), slotData(s)) catch |err| {
        invalidateSlot(s);
        return err;
    };
    s.ctx = v.dev.ctx;
    s.lba = lba;
    s.size = v.block_size;
    cache_entry_count += 1;
    hashInsert(s);
    touchCache(s);
    return slotData(s);
}

// A zero-filled block, not read: for a block written whole
fn bzero(v: *Volume, block: u32) Error![]u8 {
    try checkBlock(v, block);
    const lba = blockLba(v, block);
    const hit = cached(v, lba);
    const s = hit orelse try freeSlot(v.block_size);
    if (hit == null) {
        s.ctx = v.dev.ctx;
        s.lba = lba;
        s.size = v.block_size;
        cache_entry_count += 1;
        hashInsert(s);
    }
    @memset(slotData(s), 0);
    touchCache(s);
    return slotData(s);
}

// Writes a block (a slice from bget or bzero, changed).
// A failed write leaves it unknown:
// it is dropped from the cache.
fn bput(v: *Volume, block: u32, data: []const u8) Error!void {
    try checkBlock(v, block);
    const lba = blockLba(v, block);
    devWrite(v, lba, sectorsPerBlock(v), data[0..v.block_size]) catch |err| {
        if (cached(v, lba)) |s| invalidateSlot(s);
        return err;
    };
    if (cached(v, lba)) |s| {
        const block_data = slotData(s);
        if (data.ptr != block_data.ptr) @memcpy(block_data, data[0..v.block_size]);
        touchCache(s);
    }
}

// Data blocks first.. (count of them, in a row) read or written
// in one device call, around the cache: file data doesn't push
// metadata out of it. The cache writes through, so the disk is
// current for a read; a write drops the cached copies first.
fn readRun(v: *Volume, first: u32, count: u32, buf: []u8) Error!void {
    try checkBlock(v, first);
    try checkBlock(v, first + count - 1);
    try devRead(v, blockLba(v, first), @as(usize, count) * sectorsPerBlock(v), buf[0 .. @as(usize, count) * v.block_size]);
}

fn writeRun(v: *Volume, first: u32, count: u32, data: []const u8) Error!void {
    try checkBlock(v, first);
    try checkBlock(v, first + count - 1);
    for (0..count) |i| {
        if (cached(v, blockLba(v, first + @as(u32, @intCast(i))))) |s| invalidateSlot(s);
    }
    try devWrite(v, blockLba(v, first), @as(usize, count) * sectorsPerBlock(v), data[0 .. @as(usize, count) * v.block_size]);
}

// SUPERBLOCK

// Read only because it wasn't cleanly
// unmounted or says it has errors
pub fn notClean(v: *const Volume) bool {
    return !v.writable and (v.state & state_valid == 0 or v.state & state_error != 0);
}

// Writes the free counts, label and state into the superblock
// (the copy read when mounting, so
// it isn't read again each time)
fn writeSuper(v: *Volume, state: u16) Error!void {
    var sb = v.super;
    wr32(&sb, 12, v.free_blocks);
    wr32(&sb, 16, v.free_inodes);
    wr32(&sb, 48, now()); // s_wtime
    wr16(&sb, 58, state);
    @memcpy(sb[120..136], &v.label);
    if (v.rev1) wr32(&sb, 100, v.ro_compat);
    try devWrite(v, v.start + super_lba, super_sectors, &sb);
    v.super = sb;
}

// Before a change: refused on a read-only volume.
// The superblock says "not clean" until the change is done;
// that is flushed first, so no change
// can reach the disk before it.
fn beginWrite(v: *Volume) Error!void {
    if (!v.writable) return error.WriteProtected;
    if (v.dirty) return;
    try writeSuper(v, v.state & ~state_valid);
    try devFlush(v);
    v.dirty = true;
}

// After a change: "clean" again with the new counts, unless
// files are still open for writing (then on their close)
fn endWrite(v: *Volume) void {
    if (!v.dirty or v.writers > 0) return;
    markClean(v) catch {};
}

// What was written is flushed, then "clean" is written
// and flushed too: "clean" never reaches the disk before
// what it vouches for
fn markClean(v: *Volume) Error!void {
    try devFlush(v);
    try writeSuper(v, v.state);
    try devFlush(v);
    v.dirty = false;
}

// Everything written put on the disk, the volume marked clean
// if no file is open for writing:
// before shutting down or restarting
pub fn sync(v: *Volume) Error!void {
    if (v.dirty and v.writers == 0) return markClean(v);
    if (v.unflushed) try devFlush(v);
}

// GROUP DESCRIPTORS, INODES

const Group = struct {
    block_bitmap: u32,
    inode_bitmap: u32,
    inode_table: u32,
    free_blocks: u16,
    free_inodes: u16,
};

// The descriptor table follows the superblock's block;
// 32 bytes each
fn groupPlace(v: *const Volume, g: u32) struct { block: u32, off: usize } {
    const byte = @as(u64, g) * 32;
    return .{ .block = v.first_data_block + 1 + @as(u32, @intCast(byte / v.block_size)), .off = @intCast(byte % v.block_size) };
}

fn readGroup(v: *Volume, g: u32) Error!Group {
    if (g >= v.group_count) return error.DeviceError;
    const p = groupPlace(v, g);
    const b = try bget(v, p.block);
    const gd: Group = .{
        .block_bitmap = rd32(b, p.off),
        .inode_bitmap = rd32(b, p.off + 4),
        .inode_table = rd32(b, p.off + 8),
        .free_blocks = rd16(b, p.off + 12),
        .free_inodes = rd16(b, p.off + 14),
    };
    try checkBlock(v, gd.block_bitmap);
    try checkBlock(v, gd.inode_bitmap);
    try checkBlock(v, gd.inode_table);
    return gd;
}

// Adds to a group's free block, free inode and directory counts
fn adjustGroup(v: *Volume, g: u32, blocks: i32, inodes: i32, dirs: i32) Error!void {
    const p = groupPlace(v, g);
    const b = try bget(v, p.block);
    const add = struct {
        fn f(buf: []u8, at: usize, d: i32) void {
            const n: i32 = rd16(buf, at);
            wr16(buf, at, @intCast(std.math.clamp(n + d, 0, 0xFFFF)));
        }
    }.f;
    add(b, p.off + 12, blocks);
    add(b, p.off + 14, inodes);
    add(b, p.off + 16, dirs);
    try bput(v, p.block, b);
}

const InodePlace = struct { block: u32, off: usize };

fn inodePlace(v: *Volume, ino: u32) Error!InodePlace {
    if (ino == 0 or ino > v.inodes_count) return error.DeviceError;
    const gd = try readGroup(v, groupOf(v, ino));
    const byte = @as(u64, (ino - 1) % v.inodes_per_group) * v.inode_size;
    return .{ .block = gd.inode_table + @as(u32, @intCast(byte / v.block_size)), .off = @intCast(byte % v.block_size) };
}

fn readInode(v: *Volume, ino: u32, out: *Inode) Error!void {
    const p = try inodePlace(v, ino);
    const b = try bget(v, p.block);
    @memcpy(std.mem.asBytes(out), b[p.off..][0..@sizeOf(Inode)]);
}

// Writes the first 128 bytes; the rest
// of a larger inode stays as it is
fn writeInode(v: *Volume, ino: u32, inode: *const Inode) Error!void {
    const p = try inodePlace(v, ino);
    const b = try bget(v, p.block);
    @memcpy(b[p.off..][0..@sizeOf(Inode)], std.mem.asBytes(inode));
    try bput(v, p.block, b);
}

// A new inode: the space past the 128
// bytes is cleared (i_extra_isize 0)
fn writeNewInode(v: *Volume, ino: u32, inode: *const Inode) Error!void {
    const p = try inodePlace(v, ino);
    const b = try bget(v, p.block);
    @memset(b[p.off..][0..v.inode_size], 0);
    @memcpy(b[p.off..][0..@sizeOf(Inode)], std.mem.asBytes(inode));
    try bput(v, p.block, b);
}

var generation_counter: u32 = 0;

// i_generation of a new inode: differs
// from the last user of the number
fn newGeneration() u32 {
    generation_counter +%= 1;
    return @as(u32, @truncate(platform.clock.millis())) ^ (generation_counter *% 2654435761);
}

fn newInode(mode: u16, links: u16) Inode {
    const t = now();
    var inode = std.mem.zeroes(Inode);
    inode.mode = mode;
    inode.links = links;
    inode.uid = @truncate(platform.new_owner.uid);
    inode.uid_high = @truncate(platform.new_owner.uid >> 16);
    inode.gid = @truncate(platform.new_owner.gid);
    inode.gid_high = @truncate(platform.new_owner.gid >> 16);
    inode.atime = t;
    inode.ctime = t;
    inode.mtime = t;
    inode.generation = newGeneration();
    return inode;
}

// ALLOCATION

fn blocksInGroup(v: *const Volume, g: u32) u32 {
    if (g + 1 < v.group_count) return v.blocks_per_group;
    return v.blocks_count - v.first_data_block - g * v.blocks_per_group;
}

// The first clear bit at or after from, below n
fn findClear(bitmap: []const u8, from: u32, n: u32) ?u32 {
    var i = from;
    while (i < n) {
        if (i % 8 == 0 and bitmap[i / 8] == 0xFF) {
            i += 8;
            continue;
        }
        if (bitmap[i / 8] & (@as(u8, 1) << @intCast(i % 8)) == 0) return i;
        i += 1;
    }
    return null;
}

fn bitSet(bitmap: []const u8, i: usize) bool {
    return bitmap[i / 8] & (@as(u8, 1) << @intCast(i % 8)) != 0;
}

// Blocks first.. in a row (count of them)
const Run = struct { first: u32, count: u32 };

// Up to want free blocks in a row, preferably in group goal:
// marked in the bitmap and counted (one write
// of each) before anything points at them
fn allocRun(v: *Volume, goal: u32, want: u32) Error!Run {
    if (v.free_blocks == 0) return error.DiskFull;
    var k: u32 = 0;
    while (k < v.group_count) : (k += 1) {
        const g = (goal + k) % v.group_count;
        const gd = try readGroup(v, g);
        if (gd.free_blocks == 0) continue;
        const bm = try bget(v, gd.block_bitmap);
        const n = blocksInGroup(v, g);
        const cursor = allocationCursor(v, g);
        const from = if (cursor.block_valid and cursor.block_next < n) cursor.block_next else 0;
        const bit = findClear(bm, from, n) orelse
            (if (from != 0) findClear(bm, 0, from) else null) orelse continue;
        var count: u32 = 1;
        while (count < want and bit + count < n and !bitSet(bm, bit + count)) count += 1;
        for (bit..bit + count) |i| bm[i / 8] |= @as(u8, 1) << @intCast(i % 8);
        try bput(v, gd.block_bitmap, bm);
        try adjustGroup(v, g, -@as(i32, @intCast(count)), 0, 0);
        v.free_blocks -|= count;
        cursor.block_next = if (bit + count < n) bit + count else 0;
        cursor.block_valid = true;
        return .{ .first = v.first_data_block + g * v.blocks_per_group + bit, .count = count };
    }
    return error.DiskFull;
}

fn allocBlock(v: *Volume, goal: u32) Error!u32 {
    return (try allocRun(v, goal, 1)).first;
}

// Frees count blocks from first on: one bitmap and one
// descriptor write per group they are in
fn freeRun(v: *Volume, first: u32, count: u32) Error!void {
    var block = first;
    var left = count;
    while (left > 0) {
        try checkBlock(v, block);
        if (block < v.first_data_block) return error.DeviceError;
        const g = (block - v.first_data_block) / v.blocks_per_group;
        const bit = (block - v.first_data_block) % v.blocks_per_group;
        const n = @min(left, blocksInGroup(v, g) - bit);
        const gd = try readGroup(v, g);
        const bm = try bget(v, gd.block_bitmap);
        for (bit..bit + n) |i| {
            if (!bitSet(bm, i)) return error.DeviceError; // already free: damaged
        }
        for (bit..bit + n) |i| bm[i / 8] &= ~(@as(u8, 1) << @intCast(i % 8));
        try bput(v, gd.block_bitmap, bm);
        try adjustGroup(v, g, @intCast(n), 0, 0);
        v.free_blocks += n;
        const cursor = allocationCursor(v, g);
        if (!cursor.block_valid or bit < cursor.block_next) {
            cursor.block_next = bit;
            cursor.block_valid = true;
        }
        block += n;
        left -= n;
    }
}

fn freeBlock(v: *Volume, block: u32) Error!void {
    return freeRun(v, block, 1);
}

// Frees the data blocks listed (the direct pointers, or one
// indirect block's entries), neighbours a run at a time;
// i_blocks goes down with them
fn freeBlockList(v: *Volume, inode: *Inode, blocks: []const u32) Error!void {
    var i: usize = 0;
    while (i < blocks.len) {
        var n: u32 = 1;
        while (i + n < blocks.len and blocks[i + n] == blocks[i] +% n) n += 1;
        try freeRun(v, blocks[i], n);
        inode.blocks -|= n * sectorsPerBlock(v);
        i += n;
    }
}

// A free inode number, preferably in
// group goal (never a reserved one)
fn allocInode(v: *Volume, goal: u32, dir: bool) Error!u32 {
    if (v.free_inodes == 0) return error.DiskFull;
    var k: u32 = 0;
    while (k < v.group_count) : (k += 1) {
        const g = (goal + k) % v.group_count;
        const gd = try readGroup(v, g);
        if (gd.free_inodes == 0) continue;
        const first: u32 = if (g * v.inodes_per_group < v.first_ino - 1) v.first_ino - 1 - g * v.inodes_per_group else 0;
        const n = @min(v.inodes_per_group, v.inodes_count - g * v.inodes_per_group);
        const bm = try bget(v, gd.inode_bitmap);
        const cursor = allocationCursor(v, g);
        const from = if (cursor.inode_valid and cursor.inode_next >= first and cursor.inode_next < n) cursor.inode_next else first;
        const bit = findClear(bm, from, n) orelse
            (if (from > first) findClear(bm, first, from) else null) orelse continue;
        bm[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
        try bput(v, gd.inode_bitmap, bm);
        try adjustGroup(v, g, 0, -1, @intFromBool(dir));
        v.free_inodes -= 1;
        cursor.inode_next = if (bit + 1 < n) bit + 1 else first;
        cursor.inode_valid = true;
        return g * v.inodes_per_group + bit + 1;
    }
    return error.DiskFull;
}

fn freeInode(v: *Volume, ino: u32, dir: bool) Error!void {
    if (ino < v.first_ino or ino > v.inodes_count) return error.DeviceError;
    const g = groupOf(v, ino);
    const bit = (ino - 1) % v.inodes_per_group;
    const gd = try readGroup(v, g);
    const bm = try bget(v, gd.inode_bitmap);
    const mask = @as(u8, 1) << @intCast(bit % 8);
    if (bm[bit / 8] & mask == 0) return error.DeviceError;
    bm[bit / 8] &= ~mask;
    try bput(v, gd.inode_bitmap, bm);
    try adjustGroup(v, g, 0, 1, -@as(i32, @intFromBool(dir)));
    v.free_inodes += 1;
    discardDirIndex(v, ino);
    discardDirectoryCursor(v, ino);
    const first: u32 = if (g * v.inodes_per_group < v.first_ino - 1) v.first_ino - 1 - g * v.inodes_per_group else 0;
    const cursor = allocationCursor(v, g);
    if (!cursor.inode_valid or bit < cursor.inode_next or cursor.inode_next < first) {
        cursor.inode_next = bit;
        cursor.inode_valid = true;
    }
}

// BLOCK MAPS

fn pointersPerBlock(v: *const Volume) u64 {
    return v.block_size / 4;
}

// A block for the inode, counted in its i_blocks (refused
// before it would overflow, so no block is taken for nothing)
fn allocFor(v: *Volume, inode: *Inode, goal: u32) Error!u32 {
    if (inode.blocks > std.math.maxInt(u32) - sectorsPerBlock(v)) return error.DiskFull;
    const block = try allocBlock(v, goal);
    inode.blocks += sectorsPerBlock(v);
    return block;
}

// A zero-filled indirect block
fn newTable(v: *Volume, goal: u32, inode: *Inode) Error!u32 {
    const block = try allocFor(v, inode, goal);
    const b = try bzero(v, block);
    try bput(v, block, b);
    return block;
}

// The block holding block n of the inode's data, 0 for a hole.
// With alloc, a hole gets a block (not cleared: the caller
// writes it), and the indirect blocks on the way too.
// The inode's pointers and i_blocks change in memory:
// the caller writes the inode.
fn mapBlock(v: *Volume, inode: *Inode, n: u64, alloc: bool, goal: u32) Error!u32 {
    if (n < 12) {
        const i: usize = @intCast(n);
        if (inode.block[i] == 0 and alloc) {
            inode.block[i] = try allocFor(v, inode, goal);
        } else if (inode.block[i] != 0) try checkBlock(v, inode.block[i]);
        return inode.block[i];
    }
    const p = (try leafOf(v, inode, n, alloc, goal)) orelse return 0;
    var entry = rd32(try bget(v, p.table), p.index * 4);
    if (entry == 0) {
        if (!alloc) return 0;
        entry = try allocFor(v, inode, goal);
        const b = try bget(v, p.table);
        wr32(b, p.index * 4, entry);
        try bput(v, p.table, b);
    } else try checkBlock(v, entry);
    return entry;
}

// The pointer to data block n (12 or more): an entry
// of an indirect block
const Pointer = struct { table: u32, index: usize };

// Where block n's pointer is; null if an indirect block on the
// way is missing.
// With alloc, missing ones are made (zero-filled).
fn leafOf(v: *Volume, inode: *Inode, n: u64, alloc: bool, goal: u32) Error!?Pointer {
    const ppb = pointersPerBlock(v);
    var rel = n - 12;
    var depth: u32 = 1;
    var span = ppb; // data blocks under one pointer of the inode at this depth
    while (rel >= span) {
        rel -= span;
        depth += 1;
        if (depth > 3) return error.DiskFull; // past the largest file
        span *= ppb;
    }

    const root = &inode.block[11 + depth];
    if (root.* == 0) {
        if (!alloc) return null;
        root.* = try newTable(v, goal, inode);
    }
    var table = root.*;
    var level = depth;
    while (level > 1) : (level -= 1) {
        span /= ppb;
        const index: usize = @intCast(rel / span);
        rel %= span;
        var entry = rd32(try bget(v, table), index * 4);
        if (entry == 0) {
            if (!alloc) return null;
            entry = try newTable(v, goal, inode);
            const b = try bget(v, table);
            wr32(b, index * 4, entry);
            try bput(v, table, b);
        } else try checkBlock(v, entry);
        table = entry;
    }
    return .{ .table = table, .index = @intCast(rel) };
}

// Points data blocks n.. of the inode (holes now) at
// the run's blocks: direct pointers in memory, indirect ones
// with one write per indirect block. pointed counts those done,
// also when it fails (an indirect block couldn't be made).
// i_blocks is the caller's; it writes the inode too.
fn pointRun(v: *Volume, inode: *Inode, n: u64, run: Run, goal: u32, pointed: *u32) Error!void {
    while (pointed.* < run.count) {
        const at = n + pointed.*;
        const block = run.first + pointed.*;
        if (at < 12) {
            inode.block[@intCast(at)] = block;
            pointed.* += 1;
            continue;
        }
        const p = (try leafOf(v, inode, at, true, goal)).?;
        const room: u32 = @intCast(@min(run.count - pointed.*, pointersPerBlock(v) - p.index));
        const b = try bget(v, p.table);
        for (0..room) |k| wr32(b, (p.index + k) * 4, block + @as(u32, @intCast(k)));
        try bput(v, p.table, b);
        pointed.* += room;
    }
}

// Frees the entries of an indirect block from data block from
// on (counted from the block's start); true
// if the block itself was freed (nothing left)
fn freeTree(v: *Volume, inode: *Inode, table: u32, depth: u32, from: u64) Error!bool {
    try checkBlock(v, table);
    const ppb = pointersPerBlock(v);
    var span: u64 = 1;
    for (1..depth) |_| span *= ppb;
    var e: usize = @intCast(from / span);
    const sub = from % span;
    if (sub != 0) {
        // The first entry's subtree keeps what is before from
        const entry = rd32(try bget(v, table), e * 4);
        if (entry != 0 and try freeTree(v, inode, entry, depth - 1, sub)) {
            const b = try bget(v, table);
            wr32(b, e * 4, 0);
            try bput(v, table, b);
        }
        e += 1;
    }
    // The rest goes whole: a chunk of entries is unlinked (one
    // write of the block), then freed
    var chunk: [256]u32 = undefined;
    while (e < ppb) {
        const b = try bget(v, table);
        var n: usize = 0;
        while (e < ppb and n < chunk.len) : (e += 1) {
            const entry = rd32(b, e * 4);
            if (entry == 0) continue;
            chunk[n] = entry;
            n += 1;
            wr32(b, e * 4, 0);
        }
        if (n == 0) continue;
        try bput(v, table, b);
        if (depth == 1) {
            try freeBlockList(v, inode, chunk[0..n]);
        } else for (chunk[0..n]) |entry| {
            _ = try freeTree(v, inode, entry, depth - 1, 0);
        }
    }
    const b = try bget(v, table);
    for (0..@intCast(ppb)) |i| {
        if (rd32(b, i * 4) != 0) return false;
    }
    try freeBlock(v, table);
    inode.blocks -|= sectorsPerBlock(v);
    return true;
}

// Frees the inode's data blocks from block keep on, and the
// indirect blocks left empty.
// The inode changes in memory: the caller writes it.
fn freeBlocksFrom(v: *Volume, inode: *Inode, keep: u64) Error!void {
    var direct: [12]u32 = undefined;
    var count: usize = 0;
    for (0..12) |i| {
        if (i < keep or inode.block[i] == 0) continue;
        direct[count] = inode.block[i];
        count += 1;
        inode.block[i] = 0;
    }
    try freeBlockList(v, inode, direct[0..count]);
    const ppb = pointersPerBlock(v);
    var first: u64 = 12; // the first data block under the pointer
    var span: u64 = ppb;
    for (1..4) |depth| {
        const root = &inode.block[11 + depth];
        if (root.* != 0 and keep < first + span) {
            const from = if (keep > first) keep - first else 0;
            const table = root.*;
            if (from == 0) {
                root.* = 0;
                _ = try freeTree(v, inode, table, @intCast(depth), 0);
            } else if (try freeTree(v, inode, table, @intCast(depth), from)) root.* = 0;
        }
        first += span;
        span *= ppb;
    }
}

// Releases a file's extended attribute
// block (shared ones have a count)
fn releaseXattr(v: *Volume, inode: *Inode) Error!void {
    const block = inode.file_acl;
    if (block == 0) return;
    inode.file_acl = 0;
    const b = try bget(v, block);
    if (rd32(b, 0) != xattr_magic) return; // not one: left alone
    const refs = rd32(b, 4);
    if (refs > 1) {
        wr32(b, 4, refs - 1);
        try bput(v, block, b);
        return;
    }
    try freeBlock(v, block);
    inode.blocks -|= sectorsPerBlock(v);
}

// Cuts or extends the inode's data to size (an extension
// is a hole). The tail of the new last block is cleared,
// so that growing the file later shows zeros there.
// The inode changes in memory: the caller writes it.
fn truncate(v: *Volume, inode: *Inode, size: u64) Error!void {
    const bs: u64 = v.block_size;
    const old = fileSize(inode);
    if (size < old) {
        try freeBlocksFrom(v, inode, (size + bs - 1) / bs);
        if (size % bs != 0) {
            const block = try mapBlock(v, inode, size / bs, false, 0);
            if (block != 0) {
                const b = try bget(v, block);
                @memset(b[@intCast(size % bs)..], 0);
                try bput(v, block, b);
            }
        }
    }
    inode.size = @truncate(size);
    if (isReg(inode)) inode.size_high = @intCast(size >> 32);
}

// DIRECTORIES

// A directory entry: inode, rec_len, name_len, file type, name
const Record = struct {
    ino: u32,
    rec_len: usize,
    name_len: usize,
};

// rec_len on the disk is 16 bits: a record spanning a whole 64
// KB block is stored as 65535 (or 0, as some versions wrote it)
fn getRecLen(b: []const u8, off: usize) usize {
    const n: usize = rd16(b, off + 4);
    return if (b.len == 65536 and (n == 65535 or n == 0)) 65536 else n;
}

fn putRecLen(b: []u8, off: usize, len: usize) void {
    wr16(b, off + 4, if (len == 65536) 65535 else @intCast(len));
}

fn recLen(name_len: usize) usize {
    return (8 + name_len + 3) & ~@as(usize, 3);
}

// The entry at off; a damaged one
// is an error, so a walk always ends
fn record(b: []const u8, off: usize) Error!Record {
    if (off + 8 > b.len) return error.DeviceError;
    const r: Record = .{ .ino = rd32(b, off), .rec_len = getRecLen(b, off), .name_len = b[off + 6] };
    if (r.rec_len < 8 or r.rec_len % 4 != 0 or off + r.rec_len > b.len) return error.DeviceError;
    if (r.ino != 0 and 8 + r.name_len > r.rec_len) return error.DeviceError;
    return r;
}

fn writeRecord(v: *const Volume, b: []u8, off: usize, ino: u32, rec_len: usize, name: []const u8, ftype: u8) void {
    wr32(b, off, ino);
    putRecLen(b, off, rec_len);
    b[off + 6] = @intCast(name.len);
    b[off + 7] = if (v.filetype) ftype else 0; // name_len's high byte in revision 0
    @memcpy(b[off + 8 ..][0..name.len], name);
    @memset(b[off + 8 + name.len .. off + recLen(name.len)], 0);
}

fn fileType(inode: *const Inode) u8 {
    return if (isDir(inode)) ft_dir else if (isReg(inode)) ft_reg else 0;
}

const EntryRoom = struct {
    block: u32,
    offset: usize,
    record: Record,
    pos: u64,
};

fn findEntryRoom(v: *Volume, dir: *Inode, need: usize, start: u64, stop: u64) Error!?EntryRoom {
    const bs: u64 = v.block_size;
    var pos = start;
    while (pos < stop) {
        const base = pos - pos % bs;
        const block_no = try mapBlock(v, dir, pos / bs, false, 0);
        if (block_no == 0) {
            pos = @min(stop, base + bs);
            continue;
        }
        const b = try bget(v, block_no);
        const block_stop = @min(stop, base + bs);
        var off: usize = @intCast(pos - base);
        while (base + off < block_stop) {
            const r = try record(b, off);
            const used = if (r.ino == 0) 0 else recLen(r.name_len);
            if (r.rec_len - used >= need) return .{ .block = block_no, .offset = off, .record = r, .pos = base + off };
            off += r.rec_len;
        }
        pos = block_stop;
    }
    return null;
}

const Found = struct {
    ino: u32,
    name_buf: [255]u8 = undefined, // as on the disk
    name_len: usize = 0,

    fn name(self: *const Found) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

// Looks up name in a directory. Letter case counts, as on
// Linux: README.TXT and readme.txt are two names.
fn findEntry(v: *Volume, dir_ino: u32, dir: *Inode, name: []const u8, out: *Found) Error!bool {
    if (name.len <= indexed_name_max) {
        if (dirIndex(v, dir_ino)) |index| {
            if (index.complete) return nameIndexLookup(v, dir, index, name, out);
        }
        // The index is (re)built now. With few empty slots left (live
        // names of directories no longer in use, or tombstones) every
        // probe gets long: start afresh; the
        // indexes dropped are rebuilt when next used
        if (name_index_empty < name_index_slots / 8) clearNameIndex();
    }
    const indexed = if (name.len <= indexed_name_max) ensureDirIndex(v, dir_ino) else null;
    if (indexed) |index| index.complete = false;
    var index_complete = true;
    const bs: u64 = v.block_size;
    const blocks = (fileSize(dir) + bs - 1) / bs;
    var match: ?Found = null;
    var n: u64 = 0;
    while (n < blocks) : (n += 1) {
        const block = try mapBlock(v, dir, n, false, 0);
        if (block == 0) continue;
        const b = try bget(v, block);
        var off: usize = 0;
        while (off < b.len) {
            const r = try record(b, off);
            defer off += r.rec_len;
            if (r.ino == 0) continue;
            const entry_name = b[off + 8 ..][0..r.name_len];
            if (indexed) |index| {
                if (!nameIndexPut(index, entry_name, n * bs + off)) index_complete = false;
            }
            if (match == null and std.mem.eql(u8, entry_name, name)) {
                var found: Found = .{ .ino = r.ino, .name_len = r.name_len };
                @memcpy(found.name_buf[0..r.name_len], entry_name);
                match = found;
            }
        }
    }
    if (indexed) |index| index.complete = index_complete;
    const found = match orelse return false;
    out.* = found;
    return true;
}

fn touch(inode: *Inode) void {
    const t = now();
    inode.mtime = t;
    inode.ctime = t;
}

// Adds an entry to directory dir_ino: in the first record with
// room for it, else in a new block at the end. A hashed
// directory becomes a plain one first
// (its index would not know the entry).
fn addEntry(v: *Volume, dir_ino: u32, name: []const u8, ino: u32, ftype: u8) Error!void {
    var dir: Inode = undefined;
    try readInode(v, dir_ino, &dir);
    if (!isDir(&dir)) return error.PathNotFound;
    if (dir.flags & index_fl != 0) {
        dir.flags &= ~index_fl;
        try writeInode(v, dir_ino, &dir);
    }
    const need = recLen(name.len);
    const bs: u64 = v.block_size;
    const dir_size = fileSize(&dir);
    const blocks = (dir_size + bs - 1) / bs;
    const cursor = directoryCursor(v, dir_ino);
    if (cursor.pos > dir_size or cursor.pos % 4 != 0) {
        cursor.pos = 0;
        cursor.gap_bound = 0;
    }
    const start = cursor.pos;
    const old_bound = cursor.gap_bound;
    const need16: u16 = @intCast(need);
    // First fit from the cursor; before it
    // only if a gap there could be big enough
    var from_zero = start == 0;
    var room = try findEntryRoom(v, &dir, need, start, dir_size);
    if (room == null and !from_zero and need < old_bound) {
        room = try findEntryRoom(v, &dir, need, 0, start);
        from_zero = true;
    }
    if (room) |spot| {
        const b = try bget(v, spot.block);
        const r = spot.record;
        const used = if (r.ino == 0) 0 else recLen(r.name_len);
        if (used == 0) {
            writeRecord(v, b, spot.offset, ino, r.rec_len, name, ftype);
        } else {
            putRecLen(b, spot.offset, used);
            writeRecord(v, b, spot.offset + used, ino, r.rec_len - used, name, ftype);
        }
        try bput(v, spot.block, b);
        if (dirIndex(v, dir_ino)) |index| {
            if (index.complete and !nameIndexPut(index, name, spot.pos + used)) index.complete = false;
        }
        // The cursor stays on the record used: what is left of its room
        // is after it.
        // The gaps skipped before it were smaller than need.
        rememberDirectoryCursor(v, dir_ino, spot.pos, if (from_zero) need16 else @max(old_bound, need16));
        touch(&dir);
        return writeInode(v, dir_ino, &dir);
    }
    // A new block: the inode with its
    // pointer and size is written last
    const block = try mapBlock(v, &dir, blocks, true, groupOf(v, dir_ino));
    const b = try bzero(v, block);
    writeRecord(v, b, 0, ino, v.block_size, name, ftype);
    bput(v, block, b) catch |err| {
        writeInode(v, dir_ino, &dir) catch {}; // the block is the directory's anyway
        return err;
    };
    const append_pos = dir.size;
    dir.size += v.block_size;
    touch(&dir);
    try writeInode(v, dir_ino, &dir);
    if (dirIndex(v, dir_ino)) |index| {
        if (index.complete and !nameIndexPut(index, name, append_pos)) index.complete = false;
    }
    // No gap anywhere before it was big enough (the part before the
    // cursor was searched, or its gaps were known to be smaller)
    rememberDirectoryCursor(v, dir_ino, append_pos, need16);
}

// Removes the entry named exactly name for inode ino: its space
// goes to the entry before it, or (first
// in its block) it is marked unused
fn removeEntry(v: *Volume, dir_ino: u32, name: []const u8, ino: u32) Error!void {
    var dir: Inode = undefined;
    try readInode(v, dir_ino, &dir);
    const bs: u64 = v.block_size;
    const blocks = (fileSize(&dir) + bs - 1) / bs;
    var n: u64 = 0;
    while (n < blocks) : (n += 1) {
        const block = try mapBlock(v, &dir, n, false, 0);
        if (block == 0) continue;
        const b = try bget(v, block);
        var off: usize = 0;
        var prev: ?usize = null;
        while (off < b.len) {
            const r = try record(b, off);
            if (r.ino == ino and std.mem.eql(u8, b[off + 8 ..][0..r.name_len], name)) {
                if (prev) |p| {
                    putRecLen(b, p, getRecLen(b, p) + r.rec_len);
                } else wr32(b, off, 0);
                try bput(v, block, b);
                // From an incomplete index too: its rebuild keeps what is in it
                if (dirIndex(v, dir_ino)) |index| nameIndexRemove(index, name, n * bs + off);
                rewindDirectoryCursor(v, dir_ino, n * bs + (prev orelse off));
                touch(&dir);
                return writeInode(v, dir_ino, &dir);
            }
            prev = off;
            off += r.rec_len;
        }
    }
    return error.NotFound;
}

// Only "." and ".." in it
fn isEmptyDir(v: *Volume, dir: *Inode) Error!bool {
    const bs: u64 = v.block_size;
    const blocks = (fileSize(dir) + bs - 1) / bs;
    var n: u64 = 0;
    while (n < blocks) : (n += 1) {
        const block = try mapBlock(v, dir, n, false, 0);
        if (block == 0) continue;
        const b = try bget(v, block);
        var off: usize = 0;
        while (off < b.len) {
            const r = try record(b, off);
            defer off += r.rec_len;
            if (r.ino == 0) continue;
            const name = b[off + 8 ..][0..r.name_len];
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) return false;
        }
    }
    return true;
}

// Points the ".." entry of directory ino at parent
fn setDotDot(v: *Volume, ino: u32, parent: u32) Error!void {
    const p = try dotDotPlace(v, ino);
    const b = try bget(v, p.block);
    wr32(b, p.off, parent);
    try bput(v, p.block, b);
}

// The ".." entry of directory ino, in its first block
fn dotDotPlace(v: *Volume, ino: u32) Error!struct { block: u32, off: usize } {
    var dir: Inode = undefined;
    try readInode(v, ino, &dir);
    const block = try mapBlock(v, &dir, 0, false, 0);
    if (block == 0) return error.DeviceError;
    const b = try bget(v, block);
    var off: usize = 0;
    while (off < b.len) {
        const r = try record(b, off);
        if (r.ino != 0 and std.mem.eql(u8, b[off + 8 ..][0..r.name_len], "..")) return .{ .block = block, .off = off };
        off += r.rec_len;
    }
    return error.DeviceError;
}

// Adds to a directory's link count (each subdirectory's
// ".." is one). A count of 1 means "too many to count"
// (dir_nlink) and stays.
// Any inode's count by one, for rename's crash-safe order:
fn stepLinks(v: *Volume, ino: u32, d: i32) Error!void {
    var x: Inode = undefined;
    try readInode(v, ino, &x);
    const n: i32 = x.links;
    x.links = @intCast(std.math.clamp(n + d, 0, link_max));
    try writeInode(v, ino, &x);
}

fn addLinks(v: *Volume, ino: u32, d: i32) Error!void {
    var dir: Inode = undefined;
    try readInode(v, ino, &dir);
    if (dir.links == 1) return;
    const n: i32 = dir.links;
    dir.links = @intCast(std.math.clamp(n + d, 2, link_max));
    dir.ctime = now();
    try writeInode(v, ino, &dir);
}

// PATHS

const Target = struct {
    ino: u32,
    inode: Inode,
    parent: u32, // the directory holding it (the root's is the root)
    found: Found, // its entry there (unset for the root)
    is_root: bool,
};

fn resolve(v: *Volume, path: []const u8, t: *Target) Error!void {
    t.ino = root_ino;
    t.parent = root_ino;
    t.is_root = true;
    try readInode(v, root_ino, &t.inode);
    if (!isDir(&t.inode)) return error.DeviceError;
    var it = std.mem.tokenizeAny(u8, path, "\\/");
    while (it.next()) |segment| {
        const last = it.peek() == null;
        if (!isDir(&t.inode)) return error.PathNotFound;
        if (!try findEntry(v, t.ino, &t.inode, segment, &t.found)) return if (last) error.NotFound else error.PathNotFound;
        t.parent = t.ino;
        t.ino = t.found.ino;
        t.is_root = false;
        try readInode(v, t.ino, &t.inode);
    }
}

// The directory a new path goes into, and the new name
fn parentOf(v: *Volume, path: []const u8, dir_ino: *u32, dir: *Inode) Error![]const u8 {
    var name: []const u8 = "";
    var parent_end: usize = 0;
    var it = std.mem.tokenizeAny(u8, path, "\\/");
    while (it.next()) |segment| {
        parent_end = @intFromPtr(segment.ptr) - @intFromPtr(path.ptr);
        name = segment;
    }
    if (name.len == 0 or name.len > 255) return error.InvalidName;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.InvalidName;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidName;

    var t: Target = undefined;
    resolve(v, path[0..parent_end], &t) catch |err| return if (err == error.NotFound) error.PathNotFound else err;
    if (!isDir(&t.inode)) return error.PathNotFound;
    dir_ino.* = t.ino;
    dir.* = t.inode;
    return name;
}

fn mustNotExist(v: *Volume, dir_ino: u32, dir: *Inode, name: []const u8) Error!void {
    var f: Found = undefined;
    if (try findEntry(v, dir_ino, dir, name, &f)) return error.AlreadyExists;
}

// FILES

fn stale(v: *const Volume, gen: u32) bool {
    return gen != v.generation;
}

// The inode of an open file, as it is now;
// a deleted (perhaps reused) one is refused
fn loadFile(f: *File, inode: *Inode) Error!void {
    if (!f.in_use or stale(f.v, f.gen)) return error.InvalidHandle;
    try readInode(f.v, f.ino, inode);
    if (inode.links == 0 or inode.dtime != 0 or inode.generation != f.igen or !isReg(inode)) return error.InvalidHandle;
    f.size = fileSize(inode);
}

pub fn openFile(v: *Volume, path: []const u8, mode: platform.OpenMode, f: *File) Error!void {
    var t: Target = undefined;
    // Only a name that is really missing gets created
    const exists = if (resolve(v, path, &t)) true else |err| switch (err) {
        error.NotFound => false,
        else => return err,
    };
    if (exists and isDir(&t.inode)) return error.IsADirectory;
    if (!exists) {
        if (mode == .read) return error.NotFound;
        try beginWrite(v);
        defer endWrite(v);
        var dir_ino: u32 = undefined;
        var dir: Inode = undefined;
        const name = try parentOf(v, path, &dir_ino, &dir);
        const ino = try allocInode(v, groupOf(v, dir_ino), false);
        const inode = newInode(s_ifreg | 0o644, 1);
        errdefer freeInode(v, ino, false) catch {};
        try writeNewInode(v, ino, &inode);
        try addEntry(v, dir_ino, name, ino, ft_reg);
        f.* = .{ .in_use = true, .v = v, .ino = ino, .igen = inode.generation, .writable = true, .gen = v.generation };
        v.writers += 1;
        return;
    }
    if (!isReg(&t.inode)) return error.AccessDenied; // symbolic link, device ...
    if (mode != .read) {
        if (!v.writable) return error.WriteProtected;
        if (t.inode.mode & write_bits == 0) return error.AccessDenied;
    }
    f.* = .{
        .in_use = true,
        .v = v,
        .ino = t.ino,
        .igen = t.inode.generation,
        .size = fileSize(&t.inode),
        .writable = mode != .read,
        .gen = v.generation,
    };
    if (f.writable) v.writers += 1;
    errdefer {
        if (f.writable) v.writers -= 1;
        f.in_use = false;
    }
    if (mode == .write and (f.size > 0 or t.inode.blocks > 0)) {
        try beginWrite(v);
        defer endWrite(v);
        try truncate(v, &t.inode, 0);
        touch(&t.inode);
        try writeInode(v, t.ino, &t.inode);
        f.size = 0;
    }
}

pub fn read(f: *File, buf: []u8) Error!usize {
    var inode: Inode = undefined;
    try loadFile(f, &inode);
    if (f.pos >= f.size) return 0;
    const v = f.v;
    const bs: u64 = v.block_size;
    const total: usize = @intCast(@min(buf.len, f.size - f.pos));
    var done: usize = 0;
    while (done < total) {
        const in_block: usize = @intCast(f.pos % bs);
        const block = try mapBlock(v, &inode, f.pos / bs, false, 0);
        // Whole blocks in a row on the disk: one device read
        const whole: u32 = if (in_block == 0 and block != 0) @intCast(@min((total - done) / v.block_size, runBlocks(v))) else 0;
        if (whole > 0) {
            var count: u32 = 1;
            while (count < whole and try mapBlock(v, &inode, f.pos / bs + count, false, 0) == block +% count) count += 1;
            try readRun(v, block, count, buf[done..]);
            const n = @as(usize, count) * v.block_size;
            done += n;
            f.pos += n;
            continue;
        }
        const n = @min(total - done, v.block_size - in_block);
        if (block == 0) {
            @memset(buf[done..][0..n], 0); // a hole
        } else {
            const b = try bget(v, block);
            @memcpy(buf[done..][0..n], b[in_block..][0..n]);
        }
        done += n;
        f.pos += n;
    }
    return done;
}

// What was written; an error only if nothing was (a write cut
// short by a full disk returns the part that made it, like
// POSIX).
// Writing past the end leaves a hole, which reads as zeros.
pub fn write(f: *File, data: []const u8) Error!usize {
    var inode: Inode = undefined;
    try loadFile(f, &inode);
    if (!f.writable) return error.AccessDenied; // opened for reading
    if (data.len == 0) return 0;
    const v = f.v;
    if (f.pos > maxFileSize(v) or data.len > maxFileSize(v) - f.pos) return error.DiskFull;
    try beginWrite(v);
    defer endWrite(v);
    try allowSize(v, @max(f.size, f.pos + data.len));

    var done: usize = 0;
    const result = writeSome(f, &inode, data, &done);
    // The inode always: blocks may have
    // been added even if the write failed
    const end = f.pos + done;
    if (end > fileSize(&inode)) {
        inode.size = @truncate(end);
        inode.size_high = @intCast(end >> 32);
    }
    if (done > 0) touch(&inode);
    try writeInode(v, f.ino, &inode);
    f.pos = end;
    f.size = fileSize(&inode);
    result catch |err| {
        if (done == 0) return err;
    };
    return done;
}

// Blocks in one device call at most
fn runBlocks(v: *const Volume) u32 {
    return @max(1, max_run_bytes / v.block_size);
}

fn writeSome(f: *File, inode: *Inode, data: []const u8, done: *usize) Error!void {
    const v = f.v;
    const bs: u64 = v.block_size;
    const spb = sectorsPerBlock(v);
    const goal = groupOf(v, f.ino);
    while (done.* < data.len) {
        const pos = f.pos + done.*;
        const in_block: usize = @intCast(pos % bs);
        const n_block = pos / bs;
        const left = data.len - done.*;
        const block = try mapBlock(v, inode, n_block, false, 0);
        // Whole blocks from here on
        const whole: u32 = if (in_block == 0) @intCast(@min(left / v.block_size, runBlocks(v))) else 0;
        if (block != 0) {
            if (whole > 0) {
                // In a row on the disk: one device write
                var count: u32 = 1;
                while (count < whole and try mapBlock(v, inode, n_block + count, false, 0) == block +% count) count += 1;
                try writeRun(v, block, count, data[done.*..]);
                done.* += @as(usize, count) * v.block_size;
            } else {
                const n = @min(left, v.block_size - in_block);
                const b = try bget(v, block);
                @memcpy(b[in_block..][0..n], data[done.*..][0..n]);
                try bput(v, block, b);
                done.* += n;
            }
            continue;
        }

        // A hole: new blocks are written before anything points at them
        // (and freed again if that fails), so they never show old data
        var want: u32 = 1;
        while (want < whole and try mapBlock(v, inode, n_block + want, false, 0) == 0) want += 1;
        const room = (std.math.maxInt(u32) - inode.blocks) / spb; // what i_blocks can still count
        if (room == 0) return error.DiskFull;
        const run = try allocRun(v, goal, @min(want, room));
        const written: usize = if (whole > 0) blk: {
            writeRun(v, run.first, run.count, data[done.*..]) catch |err| {
                freeRun(v, run.first, run.count) catch {};
                return err;
            };
            break :blk @as(usize, run.count) * v.block_size;
        } else blk: {
            // Part of one block: zeros around what is written
            const n = @min(left, v.block_size - in_block);
            const b = bzero(v, run.first) catch |err| {
                freeRun(v, run.first, run.count) catch {};
                return err;
            };
            @memcpy(b[in_block..][0..n], data[done.*..][0..n]);
            bput(v, run.first, b) catch |err| {
                freeRun(v, run.first, run.count) catch {};
                return err;
            };
            break :blk n;
        };
        var pointed: u32 = 0;
        const result = pointRun(v, inode, n_block, run, goal, &pointed);
        inode.blocks +|= pointed * spb;
        result catch |err| {
            // The blocks pointed at hold their data; the others go back
            freeRun(v, run.first + pointed, run.count - pointed) catch {};
            done.* += @as(usize, pointed) * v.block_size;
            return err;
        };
        done.* += written;
    }
}

pub fn seek(f: *File, pos: u64) Error!void {
    if (!f.in_use or stale(f.v, f.gen)) return error.InvalidHandle;
    f.pos = if (pos == platform.seek_end) f.size else pos;
}

// Sets the file's length: shorter frees the blocks past it,
// longer adds a hole. The position stays where it is.
pub fn setSize(f: *File, new_size: u64) Error!void {
    var inode: Inode = undefined;
    try loadFile(f, &inode);
    if (!f.writable) return error.AccessDenied;
    const v = f.v;
    if (new_size > maxFileSize(v)) return error.DiskFull;
    if (new_size == f.size) return;
    try beginWrite(v);
    defer endWrite(v);
    try allowSize(v, new_size);
    try truncate(v, &inode, new_size);
    touch(&inode);
    try writeInode(v, f.ino, &inode);
    f.size = new_size;
}

// Everything written so far put on the disk and the volume
// marked clean, though the file stays open: a reset now loses
// nothing and needs no check. The next change marks it "not
// clean" again (every change starts with beginWrite).
pub fn commit(f: *File) Error!void {
    if (!f.in_use or stale(f.v, f.gen)) return error.InvalidHandle;
    if (!f.writable) return;
    if (f.v.dirty) return markClean(f.v);
    if (f.v.unflushed) try devFlush(f.v);
}

pub fn close(f: *File) Error!void {
    if (!f.in_use) return error.InvalidHandle;
    f.in_use = false;
    if (stale(f.v, f.gen) or !f.writable) return;
    f.v.writers -|= 1;
    endWrite(f.v);
}

// DIRECTORIES

fn fillInfo(name: []const u8, ino: u32, inode: *const Inode, out: *platform.EntryInfo) void {
    out.* = .{};
    const n = @min(name.len, out.name_buf.len);
    @memcpy(out.name_buf[0..n], name[0..n]);
    out.name_len = n;
    out.is_dir = isDir(inode);
    out.size = if (out.is_dir) 0 else fileSize(inode);
    out.attrs = if (inode.mode & write_bits == 0) platform.Attr.read_only else 0;
    if (dateTime(inode.mtime)) |t| out.modified = t;
    if (dateTime(inode.atime)) |t| out.accessed = t;
    // created: ext2 has no creation time
    // (i_ctime is the inode's last change)
    out.unix = .{
        .mode = inode.mode,
        .uid = uidOf(inode),
        .gid = gidOf(inode),
        .ino = ino,
        .links = inode.links,
        .blocks = inode.blocks,
        .changed = dateTime(inode.ctime) orelse platform.no_date,
    };
}

pub fn stat(v: *Volume, path: []const u8, out: *platform.EntryInfo) Error!void {
    var t: Target = undefined;
    try resolve(v, path, &t);
    fillInfo(if (t.is_root) "" else t.found.name(), t.ino, &t.inode, out);
}

// An open file's information, without a name
pub fn fstat(f: *File, out: *platform.EntryInfo) Error!void {
    var inode: Inode = undefined;
    try loadFile(f, &inode);
    fillInfo("", f.ino, &inode, out);
}

pub fn setModifiedOpen(f: *File, when: platform.DateTime) Error!void {
    var inode: Inode = undefined;
    try loadFile(f, &inode);
    try beginWrite(f.v);
    defer endWrite(f.v);
    inode.mtime = unixTime(when);
    inode.ctime = now();
    try writeInode(f.v, f.ino, &inode);
}

pub fn openDir(v: *Volume, path: []const u8, d: *Dir) Error!void {
    var t: Target = undefined;
    try resolve(v, path, &t);
    if (!isDir(&t.inode)) return error.NotADirectory;
    d.* = .{ .in_use = true, .v = v, .ino = t.ino, .igen = t.inode.generation, .is_root = t.is_root, .gen = v.generation };
}

// The next entry, false at the end of the directory
pub fn readDir(d: *Dir, out: *platform.EntryInfo) Error!bool {
    if (!d.in_use or stale(d.v, d.gen)) return error.InvalidHandle;
    const v = d.v;
    var dir: Inode = undefined;
    try readInode(v, d.ino, &dir);
    if (!isDir(&dir) or dir.links == 0 or dir.generation != d.igen) return error.InvalidHandle;
    const bs: u64 = v.block_size;
    const size = fileSize(&dir);
    while (d.pos < size) {
        const block = try mapBlock(v, &dir, d.pos / bs, false, 0);
        if (block == 0) {
            d.pos = (d.pos / bs + 1) * bs; // a hole: no entries
            continue;
        }
        const b = try bget(v, block);
        const off: usize = @intCast(d.pos % bs);
        const r = try record(b, off);
        d.pos += r.rec_len;
        if (r.ino == 0) continue;
        var found: Found = .{ .ino = r.ino, .name_len = r.name_len };
        @memcpy(found.name_buf[0..r.name_len], b[off + 8 ..][0..r.name_len]);
        const name = found.name();
        if (d.is_root and (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, ".."))) continue;
        var inode: Inode = undefined;
        try readInode(v, r.ino, &inode);
        fillInfo(name, r.ino, &inode, out);
        return true;
    }
    return false;
}

pub fn makeDir(v: *Volume, path: []const u8) Error!void {
    try beginWrite(v);
    defer endWrite(v);
    var parent: u32 = undefined;
    var pdir: Inode = undefined;
    const name = try parentOf(v, path, &parent, &pdir);
    try mustNotExist(v, parent, &pdir, name);
    if (pdir.links >= link_max) return error.DiskFull;

    const ino = try allocInode(v, groupOf(v, parent), true);
    const block = allocBlock(v, groupOf(v, ino)) catch |err| {
        freeInode(v, ino, true) catch {};
        return err;
    };
    newDir(v, ino, block, parent, name) catch |err| {
        freeBlock(v, block) catch {};
        freeInode(v, ino, true) catch {};
        return err;
    };
    // The entry is in: a failure now only leaves
    // the parent's count low (e2fsck fixes it)
    addLinks(v, parent, 1) catch {};
}

// Writes directory ino's block ("." and
// "..") and inode, then its entry in parent
fn newDir(v: *Volume, ino: u32, block: u32, parent: u32, name: []const u8) Error!void {
    const b = try bzero(v, block);
    writeRecord(v, b, 0, ino, 12, ".", ft_dir);
    writeRecord(v, b, 12, parent, v.block_size - 12, "..", ft_dir);
    try bput(v, block, b);

    var inode = newInode(s_ifdir | 0o755, 2);
    inode.size = v.block_size;
    inode.blocks = sectorsPerBlock(v);
    inode.block[0] = block;
    try writeNewInode(v, ino, &inode);
    try addEntry(v, parent, name, ino, ft_dir);
}

// Frees an inode that has no links left:
// its blocks, then the inode
fn releaseInode(v: *Volume, ino: u32, inode: *Inode) Error!void {
    const dir = isDir(inode);
    try freeBlocksFrom(v, inode, 0);
    try releaseXattr(v, inode);
    inode.size = 0;
    inode.size_high = 0;
    inode.links = 0;
    inode.dtime = now();
    try writeInode(v, ino, inode);
    try freeInode(v, ino, dir);
}

// Deletes a file or an empty directory.
// Read-only ones are refused, as in DOS.
pub fn delete(v: *Volume, path: []const u8) Error!void {
    try beginWrite(v);
    defer endWrite(v);
    var t: Target = undefined;
    try resolve(v, path, &t);
    if (t.is_root) return error.AccessDenied;
    if (std.mem.eql(u8, t.found.name(), ".") or std.mem.eql(u8, t.found.name(), "..")) return error.AccessDenied;
    if (t.inode.mode & write_bits == 0) return error.AccessDenied;
    const dir = isDir(&t.inode);
    if (dir and !try isEmptyDir(v, &t.inode)) return error.DirNotEmpty;

    try removeEntry(v, t.parent, t.found.name(), t.ino);
    if (dir) {
        try addLinks(v, t.parent, -1);
        t.inode.links = 0;
    } else t.inode.links -|= 1;
    if (t.inode.links == 0) return releaseInode(v, t.ino, &t.inode);
    t.inode.ctime = now();
    try writeInode(v, t.ino, &t.inode);
}

// True if directory ino is dir or below it
fn isInside(v: *Volume, ino: u32, dir: u32) Error!bool {
    var cur = ino;
    var steps: u32 = 0;
    while (steps < 4096) : (steps += 1) {
        if (cur == dir) return true;
        if (cur == root_ino) return false;
        // Read where it is: a lookup would
        // index every directory on the way
        const p = try dotDotPlace(v, cur);
        cur = rd32(try bget(v, p.block), p.off);
    }
    return error.DeviceError; // a loop: damaged
}

// Renames or moves a file or directory within the volume; to
// must not exist (a change of letter case is a new name:
// Report.txt to report.txt works)
pub fn rename(v: *Volume, from: []const u8, to: []const u8) Error!void {
    try beginWrite(v);
    defer endWrite(v);
    var src: Target = undefined;
    try resolve(v, from, &src);
    if (src.is_root) return error.AccessDenied;
    if (std.mem.eql(u8, src.found.name(), ".") or std.mem.eql(u8, src.found.name(), "..")) return error.AccessDenied;
    var parent: u32 = undefined;
    var pdir: Inode = undefined;
    const name = try parentOf(v, to, &parent, &pdir);
    var existing: Found = undefined;
    if (try findEntry(v, parent, &pdir, name, &existing)) {
        // The same name, or another link to
        // the same file there: nothing to do
        if (existing.ino == src.ino and parent == src.parent) return;
        return error.AlreadyExists;
    }

    const dir = isDir(&src.inode);
    const moves = dir and parent != src.parent;
    if (moves) {
        if (try isInside(v, parent, src.ino)) return error.InvalidArgument;
        if (pdir.links >= link_max) return error.DiskFull;
    }
    // Counts go up before the new names and down after the old
    // ones: a cut between leaves counts too high (a leak), never
    // a name on a count that misses it. The new entry before the
    // old one goes: if that fails, nothing is lost:
    try stepLinks(v, src.ino, 1);
    if (moves) try addLinks(v, parent, 1);
    try addEntry(v, parent, name, src.ino, fileType(&src.inode));
    try removeEntry(v, src.parent, src.found.name(), src.ino);
    if (moves) {
        try setDotDot(v, src.ino, parent);
        try addLinks(v, src.parent, -1);
    }
    try stepLinks(v, src.ino, -1);
    try readInode(v, src.ino, &src.inode);
    src.inode.ctime = now();
    try writeInode(v, src.ino, &src.inode);
}

// Read only: no write permission for anyone;
// writable again: everyone's. Hidden, system and archive
// have no ext2 equivalent (they always read as clear):
// setting one is NotSupported.
pub fn setAttributes(v: *Volume, path: []const u8, attrs: u8) Error!void {
    if (attrs & (platform.Attr.hidden | platform.Attr.system | platform.Attr.archive) != 0) return error.NotSupported;
    try beginWrite(v);
    defer endWrite(v);
    var t: Target = undefined;
    try resolve(v, path, &t);
    if (t.is_root) return error.AccessDenied;
    if (attrs & platform.Attr.read_only != 0) {
        t.inode.mode &= ~write_bits;
    } else if (t.inode.mode & write_bits == 0) t.inode.mode |= write_bits;
    t.inode.ctime = now();
    try writeInode(v, t.ino, &t.inode);
}

pub fn setModified(v: *Volume, path: []const u8, when: platform.DateTime) Error!void {
    try beginWrite(v);
    defer endWrite(v);
    var t: Target = undefined;
    try resolve(v, path, &t);
    if (t.is_root) return error.AccessDenied;
    t.inode.mtime = unixTime(when);
    t.inode.ctime = now();
    try writeInode(v, t.ino, &t.inode);
}

// UNIX PERMISSIONS (CHMOD, CHOWN)

pub fn permissions(v: *Volume, path: []const u8) Error!platform.Permissions {
    var t: Target = undefined;
    try resolve(v, path, &t);
    return .{ .mode = t.inode.mode, .uid = uidOf(&t.inode), .gid = gidOf(&t.inode) };
}

// Sets the permission bits (rwx for owner, group, others;
// setuid, setgid, sticky); the file type stays. Removing every
// write bit makes the entry read only for ZDOS too.
pub fn setMode(v: *Volume, path: []const u8, mode: u16) Error!void {
    if (mode & ~@as(u16, 0o7777) != 0) return error.InvalidArgument;
    try beginWrite(v);
    defer endWrite(v);
    var t: Target = undefined;
    try resolve(v, path, &t);
    t.inode.mode = (t.inode.mode & s_ifmt) | mode;
    t.inode.ctime = now();
    try writeInode(v, t.ino, &t.inode);
}

// Sets the owner and group (32-bit ids: the low 16
// bits in i_uid / i_gid, the high ones in osd2).
// null keeps one as it is.
pub fn setOwner(v: *Volume, path: []const u8, uid: ?u32, gid: ?u32) Error!void {
    try beginWrite(v);
    defer endWrite(v);
    var t: Target = undefined;
    try resolve(v, path, &t);
    if (uid) |u| {
        t.inode.uid = @truncate(u);
        t.inode.uid_high = @intCast(u >> 16);
    }
    if (gid) |g| {
        t.inode.gid = @truncate(g);
        t.inode.gid_high = @intCast(g >> 16);
    }
    t.inode.ctime = now();
    try writeInode(v, t.ino, &t.inode);
}

// THE VOLUME

pub fn blockBytes(v: *const Volume) u32 {
    return v.block_size;
}

pub fn sizeBytes(v: *const Volume) u64 {
    return @as(u64, v.blocks_count) * v.block_size;
}

pub fn freeBytes(v: *Volume) u64 {
    return @as(u64, v.free_blocks) * v.block_size;
}

pub fn fsName(v: *const Volume) []const u8 {
    return if (v.journal) "ext3" else "ext2";
}

pub fn label(v: *Volume, out: []u8) usize {
    const n = @min(std.mem.indexOfScalar(u8, &v.label, 0) orelse v.label.len, out.len);
    @memcpy(out[0..n], v.label[0..n]);
    return n;
}

// Up to 16 bytes; written with the superblock
pub fn setLabel(v: *Volume, new_label: []const u8) Error!void {
    try beginWrite(v);
    defer endWrite(v);
    if (new_label.len > v.label.len) return error.InvalidName;
    @memset(&v.label, 0);
    @memcpy(v.label[0..new_label.len], new_label);
}

// TIME
//
// ext2 keeps seconds since 1970 (UTC). The PC clock has
// no time zone: its time is taken as UTC both ways, so
// dates shown are the dates written.

fn now() u32 {
    const t = platform.clock.now() orelse return 0;
    return unixTime(t);
}

// Days from civil (Howard Hinnant)
fn unixTime(t: platform.DateTime) u32 {
    if (t.year < 1970 or t.month < 1 or t.month > 12) return 0;
    const y: i64 = @as(i64, t.year) - @intFromBool(t.month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = t.month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + t.day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    const secs = days * 86400 + @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second;
    return @intCast(std.math.clamp(secs, 0, std.math.maxInt(u32)));
}

// Civil from days; null for 0 ("never")
fn dateTime(secs: u32) ?platform.DateTime {
    if (secs == 0) return null;
    const days: u32 = secs / 86400;
    const rem: u32 = secs % 86400;
    const z: u32 = days + 719468;
    const era: u32 = z / 146097;
    const doe: u32 = z % 146097;
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u32 = (5 * doy + 2) / 153;
    const day: u32 = doy - (153 * mp + 2) / 5 + 1;
    const month: u32 = if (mp < 10) mp + 3 else mp - 9;
    const year: u32 = yoe + era * 400 + @intFromBool(month <= 2);
    return .{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = @intCast(rem / 3600),
        .minute = @intCast(rem % 3600 / 60),
        .second = @intCast(rem % 60),
    };
}
