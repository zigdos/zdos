// CHKMFS: checks a Minix 3 volume through raw sectors; -F repairs it.
// Checks ported from Minix 3's fsck.mfs; lost inodes go to \lost+found
// as in fsck_ext2fs.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const c = @import("fsck/common.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    return c.run(args, .{ .tool = "CHKMFS", .fs_name = "Minix 3", .probe = probe, .analyse = analyse, .repair = repair });
}

const magic_v3 = 0x4D5A;
const root_ino = 1;
const inode_size = 64;
const entry_size = 64;
const name_max = 60;
const direct = 7;
const link_max = 0x7FFF; // SHRT_MAX, as fsck.mfs
const max_bad = 8; // more: the tables are not trusted

const s_ifmt: u16 = 0o170000;
const s_ifreg: u16 = 0o100000;
const s_ifdir: u16 = 0o040000;
const s_ifchr: u16 = 0o020000;
const s_ifblk: u16 = 0o060000;
const s_ififo: u16 = 0o010000;
const s_iflnk: u16 = 0o120000;
const s_ifsock: u16 = 0o140000;

fn probe(sb: *const [1024]u8) bool {
    return c.rd16(sb, 24) == magic_v3;
}

var bs: u32 = 0; // block (= zone) size
var ninodes: u32 = 0;
var zones: u32 = 0;
var imap_blocks: u32 = 0;
var zmap_blocks: u32 = 0;
var first: u32 = 0; // first data zone
var ilist: u32 = 0; // first block of the inode table
var sb_flags: u16 = 0;

// What the walk found:
var imap: []u8 = &.{}; // bit per inode: in use (reached, or kept as lost)
var zmap: []u8 = &.{}; // bit per data zone, as on disk: bit z - first + 1
var dirmap: []u8 = &.{}; // bit per inode: a directory
var count: []u32 = &.{}; // directory entries naming each inode
var nfiles: u32 = 0;
var ndirs: u32 = 0;
var lf_ino: u32 = 0; // \lost+found, 0 if none
var incomplete = false;

// CROSS-LINKS: the file found second gets its own copy (e2fsck's clone).
// The repair first claims every zone any inode names, so a copy never
// takes a zone of a file not walked yet.
var had_cross = false; // the check found one: the repair takes a census
var claimed: []u8 = &.{}; // bit per data zone, as zmap
var census_done = false;
var free_left: u64 = 0; // zones neither in use nor claimed
var census_buf: [4][4096]u8 = undefined;
var count_buf: [4][4096]u8 = undefined;
var clone_buf: [4][4096]u8 = undefined;
var copy_buf: [4096]u8 = undefined;

var arena: std.heap.ArenaAllocator = undefined;
var level_buf: [4][4096]u8 = undefined; // indirect blocks, by level
var scan_buf: [4096]u8 = undefined; // the directory block being scanned
var buf: [4096]u8 = undefined; // any other block
var ino_cache: [4096]u8 = undefined; // one block of the inode table
var ino_cache_block: ?u64 = null;

const Folder = struct { ino: u32, parent: u32, path: []const u8, zones: []const u32, size: u32 };
var pending: std.ArrayListUnmanaged(Folder) = .{};
var pending_next: usize = 0;

fn analyse() bool {
    return pass();
}

fn repair() bool {
    _ = pass();
    return c.failures == 0;
}

fn pass() bool {
    arena = std.heap.ArenaAllocator.init(zdos.allocator);
    defer arena.deinit();
    pending = .{};
    pending_next = 0;
    nfiles = 0;
    ndirs = 0;
    lf_ino = 0;
    incomplete = false;
    ino_cache_block = null;
    census_done = false;
    if (!c.fixing) had_cross = false;
    if (!readSuper()) return false;
    if (!c.fixing) zdos.printf("{d} bytes per block, {d} zones, {d} inodes\n", .{ bs, zones, ninodes });
    imap = c.bitmap(@as(u64, imap_blocks) * bs * 8) orelse return false;
    defer zdos.allocator.free(imap);
    zmap = c.bitmap(@as(u64, zmap_blocks) * bs * 8) orelse return false;
    defer zdos.allocator.free(zmap);
    dirmap = c.bitmap(@as(u64, ninodes) + 1) orelse return false;
    defer zdos.allocator.free(dirmap);
    count = zdos.allocator.alloc(u32, @as(usize, ninodes) + 1) catch {
        zdos.print("Out of memory\n");
        return false;
    };
    defer zdos.allocator.free(count);
    @memset(count, 0);
    claimed = c.bitmap(@as(u64, zmap_blocks) * bs * 8) orelse return false;
    defer zdos.allocator.free(claimed);

    if (c.fixing and had_cross) census();
    if (!checkTree()) return false;
    if (!incomplete) lostInodes();
    if (incomplete) {
        c.report("out of memory: not every folder was checked, the maps are not compared", .{});
    } else {
        linkCounts();
        compareMap("zone", 2 + imap_blocks, zmap_blocks, zmap, @as(u64, zones) - first + 1, first - 1);
        compareMap("inode", 2, imap_blocks, imap, @as(u64, ninodes) + 1, 0);
        clearUnused();
    }
    cleanFlag();
    var free_inodes: u32 = 0;
    var i: u32 = 1;
    while (i <= ninodes) : (i += 1) {
        if (!c.bitGet(imap, i)) free_inodes += 1;
    }
    var free_zones: u32 = 0;
    var z: u32 = first;
    while (z < zones) : (z += 1) {
        if (!c.bitGet(zmap, z - first + 1)) free_zones += 1;
    }
    zdos.printf("{d} files, {d} folders, {d} of {d} inodes free, {d} of {d} zones free\n", .{ nfiles, ndirs, free_inodes, ninodes, free_zones, zones - first });
    c.summary();
    return true;
}

// fsck.mfs chksuper, and what ZDOS's driver accepts.

fn readSuper() bool {
    var sb: [1024]u8 = undefined;
    if (!c.readSuper(&sb)) {
        zdos.print("Cannot read the superblock\n");
        return false;
    }
    ninodes = c.rd32(&sb, 0);
    imap_blocks = c.rd16(&sb, 6);
    zmap_blocks = c.rd16(&sb, 8);
    const first_old = c.rd16(&sb, 10);
    const log_zone = c.rd16(&sb, 12);
    sb_flags = c.rd16(&sb, 14);
    zones = c.rd32(&sb, 20);
    bs = c.rd16(&sb, 28);
    if (bs < 1024 or bs > 4096 or !std.math.isPowerOfTwo(bs)) return fatal("block size {d} is not supported (1024 to 4096)", .{bs});
    if (log_zone != 0) return fatal("zones larger than blocks are not supported", .{});
    if (sb_flags & 0xFF00 != 0) return fatal("unknown feature flags 0x{x:0>4}", .{sb_flags});
    if (ninodes == 0 or zones < 4 or imap_blocks == 0 or zmap_blocks == 0) return fatal("the superblock is damaged", .{});
    if (@as(u64, zones) * (bs / c.sector) > c.vol.sectors) return fatal("the volume is smaller than its {d} zones", .{zones});
    const inode_blocks = (ninodes + bs / inode_size - 1) / (bs / inode_size);
    ilist = 2 + imap_blocks + zmap_blocks;
    first = ilist + inode_blocks;
    if (first_old != 0) {
        if (first_old < first or first_old >= zones) return fatal("first data zone {d} is wrong", .{first_old});
        if (first_old != first) c.warn("first data zone is {d}, expected {d}", .{ first_old, first });
        first = first_old;
    }
    if (first >= zones) return fatal("the superblock is damaged", .{});
    if (@as(u64, imap_blocks) * bs * 8 < @as(u64, ninodes) + 1) return fatal("too few inode map blocks", .{});
    if (@as(u64, zmap_blocks) * bs * 8 < @as(u64, zones) - first + 1) return fatal("too few zone map blocks", .{});
    return true;
}

fn fatal(comptime fmt: []const u8, args: anytype) bool {
    zdos.printf("Not checked: " ++ fmt ++ "\n", args);
    return false;
}

const Inode = struct {
    raw: [inode_size]u8,
    fn mode(n: *const Inode) u16 {
        return c.rd16(&n.raw, 0);
    }
    fn kind(n: *const Inode) u16 {
        return c.rd16(&n.raw, 0) & s_ifmt;
    }
    fn links(n: *const Inode) u16 {
        return c.rd16(&n.raw, 2);
    }
    fn size(n: *const Inode) u32 {
        return c.rd32(&n.raw, 8);
    }
    fn zone(n: *const Inode, i: usize) u32 {
        return c.rd32(&n.raw, 24 + 4 * i);
    }
};

fn inodeBlock(ino: u32) u64 {
    return ilist + @as(u64, ino - 1) * inode_size / bs;
}

fn loadInodeBlock(block: u64) bool {
    if (ino_cache_block == block) return true;
    ino_cache_block = null;
    if (!c.read(block * bs, ino_cache[0..bs])) return false;
    ino_cache_block = block;
    return true;
}

fn readInode(ino: u32) ?Inode {
    if (!loadInodeBlock(inodeBlock(ino))) {
        c.report("cannot read inode {d}", .{ino});
        return null;
    }
    const at: usize = @intCast(@as(u64, ino - 1) * inode_size % bs);
    return .{ .raw = ino_cache[at..][0..inode_size].* };
}

fn writeInode(ino: u32, n: *const Inode) bool {
    const block = inodeBlock(ino);
    if (!loadInodeBlock(block)) return false;
    const at: usize = @intCast(@as(u64, ino - 1) * inode_size % bs);
    @memcpy(ino_cache[at..][0..inode_size], &n.raw);
    // Only the sector that holds it:
    const sec_at = at - at % c.sector;
    return c.write(block * bs + sec_at, ino_cache[sec_at..][0..c.sector]);
}

fn validType(mode: u16) bool {
    return switch (mode & s_ifmt) {
        s_ifreg, s_ifdir, s_ifchr, s_ifblk, s_ififo, s_iflnk, s_ifsock => true,
        else => false,
    };
}

// ZONES (fsck.mfs chkzones / markzone)

const Walk = struct {
    path: []const u8,
    ino: u32 = 0,
    pos: u64 = 0, // the logical zone the next pointer maps
    data: ?*std.ArrayListUnmanaged(u32) = null, // data zones (directories, links)
    dry: bool = false, // only count the bad pointers
    bad: u32 = 0,
    keep: bool = false, // too many bad pointers: report them, clear none
    own: std.ArrayListUnmanaged(u32) = .{}, // zones it marked or got: freed if deleted
    delete: ?[]const u8 = null, // -D deletes the file; why
};

fn span(level: u2) u64 {
    var n: u64 = 1;
    var l = level;
    while (l > 0) : (l -= 1) n *= bs / 4;
    return n;
}

fn levelName(level: u2) []const u8 {
    return switch (level) {
        0 => "data",
        1 => "indirect",
        2 => "double indirect",
        3 => "triple indirect",
    };
}

// In an inode or an indirect block. True if p was cleared.
fn walkPointer(p: *[4]u8, level: u2, w: *Walk) bool {
    if (w.delete != null) return false;
    const z = std.mem.readInt(u32, p, .little);
    if (z == 0) {
        w.pos += span(level);
        return false;
    }
    if (z < first or z >= zones) {
        w.pos += span(level);
        w.bad += 1;
        if (w.dry or w.keep) return false; // keep: reported once (walkZones)
        c.problem(true, "{s}: {s} zone {d} is outside the volume (pointer cleared)", .{ w.path, levelName(level), z });
        if (!c.fixing) return false;
        std.mem.writeInt(u32, p, 0, .little);
        return true;
    }
    const bit = z - first + 1;
    if (!w.dry) {
        if (c.bitGet(zmap, bit)) {
            if (crossLinked(p, z, level, w)) return true;
            if (level == 0) addData(w, z); // still the folder's
            w.pos += span(level);
            return false;
        }
        c.bitSet(zmap, bit);
        own(w, z);
    }
    if (level == 0) {
        if (!w.dry) addData(w, z);
        w.pos += 1;
        return false;
    }
    const table = level_buf[level][0..bs];
    if (!c.read(@as(u64, z) * bs, table)) {
        if (!w.dry) c.report("{s}: cannot read zone {d}", .{ w.path, z });
        w.pos += span(level);
        return false;
    }
    var changed = false;
    var i: usize = 0;
    while (i < bs) : (i += 4) {
        if (walkPointer(table[i..][0..4], level - 1, w)) changed = true;
    }
    if (changed and c.fixing and w.delete == null and !c.write(@as(u64, z) * bs, table)) c.report("{s}: cannot write zone {d}", .{ w.path, z });
    return false;
}

fn own(w: *Walk, z: u32) void {
    w.own.append(arena.allocator(), z) catch {
        incomplete = true;
    };
}

// Holes as 0.
fn addData(w: *Walk, z: u32) void {
    const list = w.data orelse return;
    if (w.pos > 1 << 20) return; // no folder is that large
    const a = arena.allocator();
    while (list.items.len < w.pos) list.append(a, 0) catch {
        incomplete = true;
        return;
    };
    list.append(a, z) catch {
        incomplete = true;
    };
}

// Fixes go into n, written by the caller.
fn walkZones(n: *Inode, w: *Walk) bool {
    // Many bad pointers: the tables are likely garbage, clear nothing:
    var dry = Walk{ .path = w.path, .dry = true };
    var copy = n.*;
    for (0..10) |i| _ = walkPointer(copy.raw[24 + 4 * i ..][0..4], pointerLevel(i), &dry);
    w.keep = dry.bad > max_bad;
    if (w.keep) {
        if (deletes(w)) {
            w.delete = "a damaged inode: its zone pointers are garbage";
            return false;
        }
        unfixable(w, "{s}: {d} zone pointers outside the volume: a damaged inode", .{ w.path, dry.bad });
    }
    var changed = false;
    for (0..10) |i| {
        if (walkPointer(n.raw[24 + 4 * i ..][0..4], pointerLevel(i), w)) changed = true;
    }
    return changed;
}

fn pointerLevel(i: usize) u2 {
    return if (i < direct) 0 else @intCast(i - direct + 1);
}

// CROSS-LINKS

// z is already in use. The check reports it; the repair copies z (and
// what an indirect z names) to free zones for this file, so both keep
// their data where it is. True if p now names the copy.
fn crossLinked(p: *[4]u8, z: u32, level: u2, w: *Walk) bool {
    if (w.keep) return false; // a damaged inode: reported as such
    if (!c.fixing) {
        had_cross = true;
        c.report("{s}: {s} zone {d} is also used by another file (cross-linked): -F gives this file its own copy", .{ w.path, levelName(level), z });
        return false;
    }
    // Not seen by the check: the census now (it reads only the inode table)
    if (!census_done) census();
    const need = treeSize(z, level);
    if (need > free_left) {
        if (deletes(w)) {
            w.delete = "cross-linked, no room for its own copy";
            return false;
        }
        unfixable(w, "{s}: {s} zone {d} is cross-linked; its copy needs {d} free zones, {d} are left", .{ w.path, levelName(level), z, need, free_left });
        return false;
    }
    const copy = copyTree(z, level, w) orelse {
        if (deletes(w)) {
            w.delete = "cross-linked, its copy failed";
            return false;
        }
        unfixable(w, "{s}: {s} zone {d} is cross-linked; it could not be copied", .{ w.path, levelName(level), z });
        return false;
    };
    std.mem.writeInt(u32, p, copy, .little);
    c.fixedCross("{s} ({s} zone {d})", .{ w.path, levelName(level), z });
    return true;
}

// Every zone any inode with a valid mode names, before the
// tree is walked: free_left is what copies may take.
fn census() void {
    var ino: u32 = 1;
    while (ino <= ninodes) : (ino += 1) {
        const n = readInode(ino) orelse continue;
        if (!validType(n.mode())) continue;
        if (n.kind() == s_ifchr or n.kind() == s_ifblk) continue; // zone 0 is the device number
        for (0..10) |i| claimTree(n.zone(i), pointerLevel(i));
    }
    free_left = 0;
    var z: u32 = first;
    while (z < zones) : (z += 1) {
        if (!c.bitGet(claimed, z - first + 1) and !c.bitGet(zmap, z - first + 1)) free_left += 1;
    }
    census_done = true;
}

fn claimTree(z: u32, level: u2) void {
    if (z < first or z >= zones or c.bitGet(claimed, z - first + 1)) return;
    c.bitSet(claimed, z - first + 1);
    if (level == 0) return;
    const table = census_buf[level][0..bs];
    if (!c.read(@as(u64, z) * bs, table)) return;
    var i: usize = 0;
    while (i < bs) : (i += 4) claimTree(c.rd32(table, i), level - 1);
}

// z and what it names in the volume; unreadable: too many
fn treeSize(z: u32, level: u2) u64 {
    if (level == 0) return 1;
    const table = count_buf[level][0..bs];
    if (!c.read(@as(u64, z) * bs, table)) return std.math.maxInt(u64);
    var total: u64 = 1;
    var i: usize = 0;
    while (i < bs) : (i += 4) {
        const e = c.rd32(table, i);
        if (e >= first and e < zones) total +|= treeSize(e, level - 1);
    }
    return total;
}

// The copy's zone; null on a read or write error. Pointers
// outside the volume are dropped from copied tables.
fn copyTree(z: u32, level: u2, w: *Walk) ?u32 {
    if (level == 0) {
        const nz = freeZone() orelse return null;
        own(w, nz);
        if (!c.read(@as(u64, z) * bs, copy_buf[0..bs]) or !c.write(@as(u64, nz) * bs, copy_buf[0..bs])) return null;
        addData(w, nz);
        w.pos += 1;
        return nz;
    }
    const table = clone_buf[level][0..bs];
    if (!c.read(@as(u64, z) * bs, table)) return null;
    var i: usize = 0;
    while (i < bs) : (i += 4) {
        const e = c.rd32(table, i);
        if (e < first or e >= zones) {
            c.wr32(table, i, 0);
            w.pos += span(level - 1);
            continue;
        }
        const copy = copyTree(e, level - 1, w) orelse return null;
        c.wr32(table, i, copy);
    }
    const nz = freeZone() orelse return null;
    own(w, nz);
    if (!c.write(@as(u64, nz) * bs, table)) return null;
    return nz;
}

// -D in the repair; never the root
fn deletes(w: *const Walk) bool {
    return c.fixing and c.deleting and w.ino != root_ino;
}

// What -D would delete says so; the root not
fn unfixable(w: *const Walk, comptime fmt: []const u8, args: anytype) void {
    if (w.ino != root_ino) return c.onlyByDeleting(fmt, args);
    if (c.fixing) c.report("cannot fix: " ++ fmt, args) else c.report(fmt, args);
}

// Its zones (not those it shared) free again, the inode cleared;
// the caller drops its entry. A folder's files become lost ones.
fn deleteFile(ino: u32, w: *const Walk, why: []const u8) void {
    for (w.own.items) |z| c.bitClr(zmap, z - first + 1);
    c.bitClr(imap, ino);
    const zero = Inode{ .raw = .{0} ** inode_size };
    if (!writeInode(ino, &zero)) return c.report("{s}: cannot clear inode {d}", .{ w.path, ino });
    c.deleted("{s} (inode {d}): {s}", .{ w.path, ino, why });
}

// THE TREE (fsck.mfs chktree / descendtree)

// First visit of ino. path: its folder's path, plus name if not null.
// A directory is queued. false: the entry should be removed.
fn visit(ino: u32, parent: u32, base: []const u8, name: ?[]const u8) bool {
    var n = readInode(ino) orelse return true;
    const mode = n.mode();
    const kind = n.kind();
    const path = if (name) |nm| childPath(base, nm, kind == s_ifdir) else base;
    if (!validType(mode)) {
        c.problem(true, "{s}: inode {d} is not in use or has a bad mode (0{o}) (entry removed)", .{ path, ino, mode });
        return false;
    }
    c.bitSet(imap, ino);
    var data: std.ArrayListUnmanaged(u32) = .{};
    var w = Walk{ .path = path, .ino = ino };
    if (kind == s_ifdir or kind == s_iflnk) w.data = &data;
    var changed = false;
    if (kind == s_ifchr or kind == s_ifblk) {
        // Zone 0 holds the device number; the others must be empty:
        var i: usize = 1;
        while (i < 10) : (i += 1) {
            if (n.zone(i) == 0) continue;
            c.problem(true, "{s}: device file has zone number {d} (cleared)", .{ path, n.zone(i) });
            c.wr32(&n.raw, 24 + 4 * i, 0);
            changed = true;
        }
    } else changed = walkZones(&n, &w);
    if (w.delete) |why| {
        deleteFile(ino, &w, why);
        return false;
    }
    if (kind == s_iflnk and checkLink(&n, data.items, path)) changed = true;
    if (changed and c.fixing and !writeInode(ino, &n)) c.report("{s}: cannot write inode {d}", .{ path, ino });
    if (kind == s_ifdir) {
        ndirs += 1;
        c.bitSet(dirmap, ino);
        pending.append(arena.allocator(), .{ .ino = ino, .parent = parent, .path = path, .zones = data.items, .size = n.size() }) catch {
            incomplete = true;
        };
    } else nfiles += 1;
    return true;
}

// fsck.mfs chklink: the target fits a block and has no NUL.
fn checkLink(n: *Inode, data: []const u32, path: []const u8) bool {
    const size = n.size();
    if (size == 0 or size > bs) {
        c.report("{s}: symbolic link of {d} bytes", .{ path, size });
        return false;
    }
    if (data.len == 0 or data[0] == 0) {
        c.report("{s}: symbolic link without a target", .{path});
        return false;
    }
    if (!c.read(@as(u64, data[0]) * bs, buf[0..bs])) return false;
    const len: u32 = @intCast(std.mem.indexOfScalar(u8, buf[0..size], 0) orelse size);
    if (len == size) return false;
    c.problem(true, "{s}: symbolic link size is {d}, its target has {d} characters (size set)", .{ path, size, len });
    c.wr32(&n.raw, 8, len);
    return true;
}

fn childPath(base: []const u8, name: []const u8, dir: bool) []const u8 {
    const p = std.fmt.allocPrint(arena.allocator(), "{s}{s}{s}", .{ base, name, if (dir) "\\" else "" }) catch {
        incomplete = true;
        return base;
    };
    for (p[base.len..]) |*ch| {
        if (ch.* < 0x20 or ch.* > 0x7E) ch.* = '?';
    }
    return p;
}

fn checkTree() bool {
    const root = readInode(root_ino) orelse return false;
    if (root.kind() != s_ifdir) {
        zdos.printf("Not checked: the root inode is not a directory (mode 0{o})\n", .{root.mode()});
        return false;
    }
    _ = visit(root_ino, root_ino, "\\", null);
    scanPending();
    return true;
}

fn scanPending() void {
    while (pending_next < pending.items.len) {
        const f = pending.items[pending_next];
        pending_next += 1;
        scanFolder(f);
    }
}

// fsck.mfs chkdirzone / chkentry / chkdots
fn scanFolder(f: Folder) void {
    var seen_dot = false;
    var seen_dotdot = false;
    var end: u64 = 0; // past the last entry in use
    for (f.zones, 0..) |z, zi| {
        if (z == 0) continue;
        const block = scan_buf[0..bs];
        if (!c.read(@as(u64, z) * bs, block)) {
            c.report("{s}: cannot read zone {d}", .{ f.path, z });
            continue;
        }
        var dirty = false;
        var off: usize = 0;
        while (off < bs) : (off += entry_size) {
            const e = block[off..][0..entry_size];
            if (c.rd32(e, 0) == 0) continue;
            const pos = @as(u64, zi) * bs + off;
            if (checkEntry(f, e, pos, &seen_dot, &seen_dotdot)) dirty = true;
            if (c.rd32(e, 0) != 0) end = pos + entry_size;
        }
        if (dirty and c.fixing and !c.write(@as(u64, z) * bs, block)) c.report("{s}: cannot write zone {d}", .{ f.path, z });
    }
    if (!seen_dot) c.report("{s}: '.' is missing", .{f.path});
    if (!seen_dotdot) c.report("{s}: '..' is missing", .{f.path});
    if (end > f.size) {
        c.problem(true, "{s}: size {d} is smaller than its entries ({d} bytes) (size set)", .{ f.path, f.size, end });
        if (c.fixing) setSize(f.ino, @intCast(end), f.path);
    }
}

fn setSize(ino: u32, size: u32, path: []const u8) void {
    var n = readInode(ino) orelse return;
    c.wr32(&n.raw, 8, size);
    if (!writeInode(ino, &n)) c.report("{s}: cannot write inode {d}", .{ path, ino });
}

fn entryName(e: []const u8) []const u8 {
    const raw = e[4..][0..name_max];
    return raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse name_max];
}

// True if it was changed.
fn checkEntry(f: Folder, e: *[entry_size]u8, pos: u64, seen_dot: *bool, seen_dotdot: *bool) bool {
    const ino = c.rd32(e, 0);
    const name = entryName(e);
    if (ino < root_ino or ino > ninodes) {
        c.problem(true, "{s}: entry '{s}' names inode {d}, outside the inode table (removed)", .{ f.path, printable(name), ino });
        return clearEntry(e);
    }
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
        const dotdot = name.len == 2;
        if (dotdot) seen_dotdot.* = true else seen_dot.* = true;
        if (pos != @as(u64, if (dotdot) entry_size else 0)) c.warn("{s}: '{s}' is at offset {d}", .{ f.path, name, pos });
        // A lost folder's '..' is 0 while there is no \lost+found:
        const want = if (dotdot) f.parent else f.ino;
        if (want == 0 or ino == want) {
            count[ino] += 1;
            return false;
        }
        c.problem(true, "{s}: '{s}' names inode {d} instead of {d} (set)", .{ f.path, name, ino, want });
        count[want] += 1;
        if (!c.fixing) return false;
        c.wr32(e, 0, want);
        return true;
    }
    if (name.len == 0) {
        c.problem(true, "{s}: entry for inode {d} has no name (removed)", .{ f.path, ino });
        return clearEntry(e);
    }
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        c.problem(true, "{s}: entry '{s}' has a '/' in its name (removed)", .{ f.path, printable(name) });
        return clearEntry(e);
    }
    if (count[ino] >= link_max) {
        c.problem(true, "{s}: too many links to inode {d}, entry '{s}' (removed)", .{ f.path, ino, printable(name) });
        return clearEntry(e);
    }
    if (c.bitGet(dirmap, ino)) {
        c.problem(true, "{s}: entry '{s}' is a second link to a folder (removed)", .{ f.path, printable(name) });
        return clearEntry(e);
    }
    if (!c.bitGet(imap, ino)) {
        if (!visit(ino, f.ino, f.path, name)) return clearEntry(e);
        if (f.ino == root_ino and std.mem.eql(u8, name, "lost+found") and c.bitGet(dirmap, ino)) lf_ino = ino;
    }
    count[ino] += 1;
    return false;
}

fn clearEntry(e: *[entry_size]u8) bool {
    if (!c.fixing) return false;
    @memset(e, 0);
    return true;
}

fn printable(name: []const u8) []const u8 {
    for (name) |ch| {
        if (ch < 0x20 or ch > 0x7E) return "(unprintable name)";
    }
    return name;
}

// LOST INODES

const Lost = struct { ino: u32, dir: bool, size: u32 };

// In use, valid and linked, but not reached by the tree. fsck.mfs frees them;
// here they are kept in \lost+found.
fn lostInodes() void {
    const disk_imap = c.bitmap(@as(u64, imap_blocks) * bs * 8) orelse {
        incomplete = true;
        return;
    };
    defer zdos.allocator.free(disk_imap);
    if (!c.read(2 * @as(u64, bs), disk_imap)) {
        c.report("cannot read the inode map", .{});
        incomplete = true;
        return;
    }
    var lost: std.ArrayListUnmanaged(Lost) = .{};
    // Folders first, from the topmost lost folder of each chain, so a
    // lost folder's files stay in it. Every zone is marked before
    // \lost+found takes one.
    for ([_]bool{ true, false }) |dirs| {
        var ino: u32 = 2;
        while (ino <= ninodes) : (ino += 1) {
            if (!isLost(ino, disk_imap)) continue;
            const n = readInode(ino) orelse continue;
            if ((n.kind() == s_ifdir) != dirs) continue;
            var next = if (dirs) topLost(ino, disk_imap) else ino;
            while (true) {
                const top = readInode(next) orelse break;
                const path = std.fmt.allocPrint(arena.allocator(), "\\lost+found\\#{d}{s}", .{ next, if (dirs) "\\" else "" }) catch {
                    incomplete = true;
                    return;
                };
                // Deleted (-D): not linked
                if (visit(next, lf_ino, path, null)) {
                    lost.append(arena.allocator(), .{ .ino = next, .dir = dirs, .size = top.size() }) catch {
                        incomplete = true;
                        return;
                    };
                    count[next] += 1; // its entry in \lost+found
                }
                scanPending();
                if (incomplete) return;
                if (next == ino or !isLost(ino, disk_imap)) break;
                next = ino; // its chain didn't lead back to it
            }
        }
    }
    if (lost.items.len == 0) return;
    if (!c.fixing) {
        for (lost.items) |l| c.report("inode {d} ({s}, {d} bytes) is in no folder: -F links it into \\lost+found as #{d}", .{ l.ino, if (l.dir) "folder" else "file", l.size, l.ino });
        if (lf_ino == 0) zdos.print("    there is no \\lost+found: -F makes one\n");
        return;
    }
    const had_lf = lf_ino != 0;
    if (!had_lf and !makeLostFound()) {
        c.report("cannot make \\lost+found: {d} inodes in no folder stay so", .{lost.items.len});
        return;
    }
    for (lost.items) |l| {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "#{d}", .{l.ino}) catch unreachable;
        if (!addEntry(lf_ino, name, l.ino)) {
            c.report("inode {d} is in no folder: no room in \\lost+found", .{l.ino});
            continue;
        }
        c.fixed("inode {d} ({s}, {d} bytes) linked into \\lost+found as {s}", .{ l.ino, if (l.dir) "folder" else "file", l.size, name });
        if (l.dir and !had_lf) setDotDot(l.ino);
    }
}

fn isLost(ino: u32, disk_imap: []const u8) bool {
    if (c.bitGet(imap, ino) or !c.bitGet(disk_imap, ino)) return false;
    const n = readInode(ino) orelse return false;
    return n.links() != 0 and validType(n.mode());
}

fn topLost(start: u32, disk_imap: []const u8) u32 {
    var ino = start;
    var steps: u32 = 0;
    while (steps < 1000) : (steps += 1) {
        const n = readInode(ino) orelse return ino;
        const z = n.zone(0);
        if (z < first or z >= zones) return ino;
        if (!c.read(@as(u64, z) * bs, buf[0..bs])) return ino;
        const up = c.rd32(&buf, entry_size);
        if (up < 2 or up > ninodes or up == start or !isLost(up, disk_imap)) return ino;
        const un = readInode(up) orelse return ino;
        if (un.kind() != s_ifdir) return ino;
        ino = up;
    }
    return ino;
}

// Scanned before \lost+found existed: its '..' now names it.
fn setDotDot(ino: u32) void {
    const n = readInode(ino) orelse return;
    const z = n.zone(0);
    if (z < first or z >= zones) return;
    if (!c.read(@as(u64, z) * bs, buf[0..bs])) return;
    if (!std.mem.eql(u8, entryName(buf[entry_size..][0..entry_size]), "..")) return;
    const old = c.rd32(&buf, entry_size);
    if (old == lf_ino) return;
    c.wr32(&buf, entry_size, lf_ino);
    if (!c.write(@as(u64, z) * bs, buf[0..bs])) return c.report("cannot write zone {d}", .{z});
    if (old >= 1 and old <= ninodes and count[old] > 0) count[old] -= 1;
    count[lf_ino] += 1;
}

fn freeZone() ?u32 {
    var z: u32 = first;
    while (z < zones) : (z += 1) {
        const bit = z - first + 1;
        if (!c.bitGet(zmap, bit) and !c.bitGet(claimed, bit)) {
            c.bitSet(zmap, bit);
            c.bitSet(claimed, bit);
            free_left -|= 1;
            return z;
        }
    }
    return null;
}

fn makeLostFound() bool {
    var ino: u32 = 2;
    const free_ino = while (ino <= ninodes) : (ino += 1) {
        if (c.bitGet(imap, ino)) continue;
        const n = readInode(ino) orelse return false;
        if (n.mode() == 0) break ino;
    } else return false;
    const z = freeZone() orelse return false;
    @memset(buf[0..bs], 0);
    c.wr32(&buf, 0, free_ino);
    buf[4] = '.';
    c.wr32(&buf, entry_size, root_ino);
    buf[entry_size + 4] = '.';
    buf[entry_size + 5] = '.';
    if (!c.write(@as(u64, z) * bs, buf[0..bs])) return false;
    var n = Inode{ .raw = .{0} ** inode_size };
    c.wr16(&n.raw, 0, s_ifdir | 0o700);
    c.wr16(&n.raw, 2, 2);
    c.wr32(&n.raw, 8, 2 * entry_size);
    const now = c.unixNow();
    c.wr32(&n.raw, 12, now);
    c.wr32(&n.raw, 16, now);
    c.wr32(&n.raw, 20, now);
    c.wr32(&n.raw, 24, z);
    if (!writeInode(free_ino, &n)) return false;
    if (!addEntry(root_ino, "lost+found", free_ino)) return false;
    // The root gets the new folder's '..':
    if (readInode(root_ino)) |r0| {
        var r = r0;
        c.wr16(&r.raw, 2, r.links() + 1);
        _ = writeInode(root_ino, &r);
    }
    c.bitSet(imap, free_ino);
    c.bitSet(dirmap, free_ino);
    count[free_ino] += 2;
    count[root_ino] += 1;
    ndirs += 1;
    lf_ino = free_ino;
    c.fixed("made \\lost+found", .{});
    return true;
}

// In a free entry of its direct zones.
fn addEntry(dir: u32, name: []const u8, ino: u32) bool {
    var n = readInode(dir) orelse return false;
    const size = n.size();
    var zi: usize = 0;
    while (zi < direct) : (zi += 1) {
        var z = n.zone(zi);
        if (z == 0) {
            if (@as(u64, zi) * bs < size) continue; // a hole inside the folder
            z = freeZone() orelse return false;
            @memset(buf[0..bs], 0);
            if (!c.write(@as(u64, z) * bs, buf[0..bs])) return false;
            c.wr32(&n.raw, 24 + 4 * zi, z);
        }
        if (z < first or z >= zones) continue;
        if (!c.read(@as(u64, z) * bs, buf[0..bs])) return false;
        var off: usize = 0;
        while (off < bs) : (off += entry_size) {
            if (c.rd32(&buf, off) != 0) continue;
            @memset(buf[off..][0..entry_size], 0);
            c.wr32(&buf, off, ino);
            @memcpy(buf[off + 4 ..][0..name.len], name);
            if (!c.write(@as(u64, z) * bs, buf[0..bs])) return false;
            const end: u32 = @intCast(zi * bs + off + entry_size);
            if (end > size) c.wr32(&n.raw, 8, end);
            return writeInode(dir, &n);
        }
    }
    return false;
}

// fsck.mfs chkcount

fn linkCounts() void {
    var ino: u32 = 1;
    while (ino <= ninodes) : (ino += 1) {
        if (!c.bitGet(imap, ino)) continue;
        var n = readInode(ino) orelse continue;
        const want = @min(count[ino], link_max);
        if (n.links() == want) continue;
        c.problem(true, "inode {d}: link count is {d}, {d} entries name it (set)", .{ ino, n.links(), want });
        if (c.fixing) {
            c.wr16(&n.raw, 2, @intCast(want));
            if (!writeInode(ino, &n)) c.report("cannot write inode {d}", .{ino});
        }
    }
}

// fsck.mfs chkmap: bits 1 to valid - 1; base: what bit 0 stands for.
// The repair writes the found map, with bit 0 and the bits past valid
// set as MKMFS3 does.
fn compareMap(comptime what: []const u8, start: u32, blocks: u32, map: []u8, valid: u64, base: u64) void {
    const disk = c.bitmap(@as(u64, blocks) * bs * 8) orelse return;
    defer zdos.allocator.free(disk);
    const bytes = @as(usize, blocks) * bs;
    if (!c.read(@as(u64, start) * bs, disk[0..bytes])) return c.report("cannot read the " ++ what ++ " map", .{});
    var missing: u64 = 0; // in use, marked free
    var extra: u64 = 0; // marked in use, not used
    var i: u64 = 1;
    while (i < valid) : (i += 1) {
        const ours = c.bitGet(map, i);
        if (ours == c.bitGet(disk, i)) continue;
        if (missing + extra < 10) zdos.printf("    " ++ what ++ " {d} is {s}\n", .{ i + base, if (ours) "in use but marked free" else "marked in use but not used" });
        if (ours) missing += 1 else extra += 1;
    }
    if (missing + extra == 0) return;
    c.problem(true, "the " ++ what ++ " map is wrong: {d} in use marked free, {d} unused marked in use (map rewritten)", .{ missing, extra });
    if (!c.fixing) return;
    c.bitSet(map, 0);
    i = valid;
    while (i < @as(u64, bytes) * 8) : (i += 1) c.bitSet(map, i);
    if (!c.write(@as(u64, start) * bs, map[0..bytes])) c.report("cannot write the " ++ what ++ " map", .{});
}

// fsck.mfs chkilist: inodes not in use must be cleared.
fn clearUnused() void {
    var ino: u32 = 1;
    var found: u32 = 0;
    while (ino <= ninodes) : (ino += 1) {
        if (c.bitGet(imap, ino)) continue;
        const n = readInode(ino) orelse continue;
        if (n.mode() == 0) continue;
        found += 1;
        if (found <= 10) zdos.printf("    inode {d} is not in use but not cleared (mode 0{o})\n", .{ ino, n.mode() });
        if (c.fixing) {
            const zero = Inode{ .raw = .{0} ** inode_size };
            if (!writeInode(ino, &zero)) c.report("cannot clear inode {d}", .{ino});
        }
    }
    if (found > 0) c.problem(true, "{d} inodes not in use are not cleared (cleared)", .{found});
}

// A problem: ZDOS (as Minix) mounts such a volume read only. util-linux's
// mkfs.minix leaves it 0, so its volumes need one -F.
fn cleanFlag() void {
    if (sb_flags & 1 != 0) return;
    if (!c.fixing) return c.report("the volume is not marked clean (an unfinished change, or made by Linux's mkfs.minix): ZDOS mounts it read only", .{});
    if (c.failures > 0) return;
    var sb: [1024]u8 = undefined;
    if (!c.readSuper(&sb)) return c.report("cannot read the superblock", .{});
    c.wr16(&sb, 14, c.rd16(&sb, 14) | 1);
    if (!c.write(1024, &sb)) return c.report("cannot write the superblock", .{});
    c.fixed("marked the volume clean", .{});
}
