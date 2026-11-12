// CHKEXT2: checks an ext2 volume through raw sectors;
// -F repairs it. Passes ported from NetBSD's fsck_ext2fs;
// refuses the features ZDOS's driver lacks.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const c = @import("fsck/common.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    return c.run(args, .{ .tool = "CHKEXT2", .fs_name = "ext2", .probe = probe, .analyse = analyse, .repair = repair });
}

const magic = 0xEF53;
const root_ino = 2;
const resize_ino = 7;
const ndir = 12; // direct pointers
const link_max = 32000;
const max_bad = 8; // more: the tables are not trusted

// Features this checker and ZDOS's driver understand:
const compat_has_journal: u32 = 0x0004;
const compat_resize_inode: u32 = 0x0010;
const compat_sparse_super2: u32 = 0x0200; // backups only in the groups s_backup_bgs names
const incompat_filetype: u32 = 0x0002;
const incompat_recover: u32 = 0x0004;
const incompat_flex_bg: u32 = 0x0200;
const ro_compat_sparse_super: u32 = 0x0001;
const ro_compat_large_file: u32 = 0x0002;

const s_ifmt: u16 = 0xF000;
const s_ifreg: u16 = 0x8000;
const s_ifdir: u16 = 0x4000;
const s_ifchr: u16 = 0x2000;
const s_ifblk: u16 = 0x6000;
const s_ififo: u16 = 0x1000;
const s_iflnk: u16 = 0xA000;
const s_ifsock: u16 = 0xC000;
const extents_fl: u32 = 0x80000;
const inline_fl: u32 = 0x10000000;
const index_fl: u32 = 0x1000;

fn probe(super: *const [1024]u8) bool {
    return c.rd16(super, 56) == magic;
}

var sb: [1024]u8 = undefined;
var bs: u32 = 0;
var blocks: u32 = 0;
var inodes: u32 = 0;
var first_data: u32 = 0;
var bpg: u32 = 0;
var ipg: u32 = 0;
var ncg: u32 = 0;
var ino_size: u32 = 128;
var first_ino: u32 = 11;
var rev1 = false;
var compat: u32 = 0;
var ro_compat: u32 = 0;
var filetype = false;
var backup_bgs: [2]u32 = .{ 0, 0 }; // sparse_super2: the backups' groups (0: none)
var gd: []u8 = &.{}; // the group descriptors, as on disk
var gd_blocks: u32 = 0;

// Inode states (fsck_ext2fs statemap):
const State = enum(u8) { unused, file, dir, clear, reserved };
var state: []State = &.{};
var ftype: []u8 = &.{}; // directory-entry type of each inode
var count: []u32 = &.{}; // entries naming each inode
var reached: []u8 = &.{}; // bit per inode: named from the root
var bmap: []u8 = &.{}; // bit per block: in use
var dupmap: []u8 = &.{}; // bit per block: used twice
var xattr: []u8 = &.{}; // bit per extended-attribute block
var nfiles: u32 = 0;
var ndirs: u32 = 0;
var lf_ino: u32 = 0;
var lf_said = false;
var walked: []u8 = &.{}; // bit per inode: its blocks were marked
var incomplete = false;

// CROSS-LINKS: the file found second gets its own copy (e2fsck's clone).
// The repair first claims every block any inode names, so a copy never
// takes a block of a file not walked yet.
var had_cross = false; // the check found one: the repair takes a census
var claimed: []u8 = &.{}; // bit per block: named by some inode
var census_done = false;
var free_left: u64 = 0; // blocks neither in use nor claimed
var census_buf: [4][]u8 = undefined;
var count_buf: [4][]u8 = undefined;
var clone_buf: [4][]u8 = undefined;
var copy_buf: []u8 = &.{};

var arena: std.heap.ArenaAllocator = undefined;
var level_buf: [4][]u8 = undefined;
var scan_buf: []u8 = &.{};
var buf: []u8 = &.{};
var ino_cache: []u8 = &.{};
var ino_cache_block: ?u64 = null;

const Dir = struct { blocks: []const u32, size: u64 };
var dirs: std.AutoHashMapUnmanaged(u32, Dir) = .{};
const Folder = struct { ino: u32, parent: u32, path: []const u8 };
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
    const a = arena.allocator();
    dirs = .{};
    pending = .{};
    pending_next = 0;
    nfiles = 0;
    ndirs = 0;
    lf_ino = 0;
    lf_said = false;
    incomplete = false;
    ino_cache_block = null;
    census_done = false;
    if (!c.fixing) had_cross = false;
    if (!readSuper()) return false;
    if (!c.fixing) zdos.printf("{d} bytes per block, {d} blocks, {d} inodes, {d} groups\n", .{ bs, blocks, inodes, ncg });
    for (&level_buf) |*l| l.* = a.alloc(u8, bs) catch return outOfMemory();
    for (&census_buf) |*l| l.* = a.alloc(u8, bs) catch return outOfMemory();
    for (&count_buf) |*l| l.* = a.alloc(u8, bs) catch return outOfMemory();
    for (&clone_buf) |*l| l.* = a.alloc(u8, bs) catch return outOfMemory();
    copy_buf = a.alloc(u8, bs) catch return outOfMemory();
    scan_buf = a.alloc(u8, bs) catch return outOfMemory();
    buf = a.alloc(u8, bs) catch return outOfMemory();
    ino_cache = a.alloc(u8, bs) catch return outOfMemory();
    gd = a.alloc(u8, @as(usize, gd_blocks) * bs) catch return outOfMemory();
    if (!c.read(@as(u64, first_data + 1) * bs, gd)) {
        zdos.print("Not checked: cannot read the group descriptors\n");
        return false;
    }
    state = a.alloc(State, @as(usize, inodes) + 1) catch return outOfMemory();
    @memset(state, .unused);
    ftype = a.alloc(u8, @as(usize, inodes) + 1) catch return outOfMemory();
    @memset(ftype, 0);
    count = a.alloc(u32, @as(usize, inodes) + 1) catch return outOfMemory();
    @memset(count, 0);
    reached = c.bitmap(@as(u64, inodes) + 1) orelse return false;
    defer zdos.allocator.free(reached);
    walked = c.bitmap(@as(u64, inodes) + 1) orelse return false;
    defer zdos.allocator.free(walked);
    bmap = c.bitmap(blocks) orelse return false;
    defer zdos.allocator.free(bmap);
    dupmap = c.bitmap(blocks) orelse return false;
    defer zdos.allocator.free(dupmap);
    xattr = c.bitmap(blocks) orelse return false;
    defer zdos.allocator.free(xattr);
    claimed = c.bitmap(blocks) orelse return false;
    defer zdos.allocator.free(claimed);

    if (!markMetadata()) return false;
    if (c.fixing and had_cross) census();
    pass1();
    if (!pass2()) return false;
    if (incomplete) {
        c.report("out of memory: not every folder was checked, the maps are not compared", .{});
    } else {
        pass3();
        pass4();
        pass5();
    }
    checkBackups();
    cleanState();
    var free_inodes: u32 = 0;
    for (state[1..]) |s| {
        if (s == .unused) free_inodes += 1;
    }
    var free_blocks: u32 = 0;
    var b: u32 = first_data;
    while (b < blocks) : (b += 1) {
        if (!c.bitGet(bmap, b)) free_blocks += 1;
    }
    zdos.printf("{d} files, {d} folders, {d} of {d} inodes free, {d} of {d} blocks free\n", .{ nfiles, ndirs, free_inodes, inodes, free_blocks, blocks });
    c.summary();
    return true;
}

fn outOfMemory() bool {
    zdos.print("Out of memory\n");
    return false;
}

fn fatal(comptime fmt: []const u8, args: anytype) bool {
    zdos.printf("Not checked: " ++ fmt ++ "\n", args);
    return false;
}

fn readSuper() bool {
    if (!c.readSuper(&sb)) return fatal("cannot read the superblock", .{});
    inodes = c.rd32(&sb, 0);
    blocks = c.rd32(&sb, 4);
    first_data = c.rd32(&sb, 20);
    const log_bs = c.rd32(&sb, 24);
    bpg = c.rd32(&sb, 32);
    ipg = c.rd32(&sb, 40);
    rev1 = c.rd32(&sb, 76) >= 1;
    if (log_bs > 6) return fatal("block size 1024 << {d} is not supported", .{log_bs});
    bs = @as(u32, 1024) << @intCast(log_bs);
    if (bpg == 0 or bpg > bs * 8 or ipg == 0 or ipg > bs * 8) return fatal("the group sizes are damaged", .{});
    if (c.rd32(&sb, 36) != bpg) return fatal("fragments are not supported", .{});
    if (first_data != @intFromBool(bs == 1024)) return fatal("first data block {d} is wrong", .{first_data});
    if (blocks <= first_data or inodes == 0) return fatal("the superblock is damaged", .{});
    if (@as(u64, blocks) * (bs / c.sector) > c.vol.sectors) return fatal("the volume is smaller than its {d} blocks", .{blocks});
    ncg = (blocks - first_data + bpg - 1) / bpg;
    if (@as(u64, inodes) > @as(u64, ncg) * ipg) return fatal("more inodes than the groups hold", .{});
    ino_size = if (rev1) c.rd16(&sb, 88) else 128;
    if (ino_size < 128 or ino_size > bs or !std.math.isPowerOfTwo(ino_size)) return fatal("inode size {d} is wrong", .{ino_size});
    first_ino = if (rev1) c.rd32(&sb, 84) else 11;
    if (first_ino <= root_ino or first_ino > inodes) return fatal("first inode {d} is wrong", .{first_ino});
    compat = if (rev1) c.rd32(&sb, 92) else 0;
    const incompat: u32 = if (rev1) c.rd32(&sb, 96) else 0;
    ro_compat = if (rev1) c.rd32(&sb, 100) else 0;
    if (incompat & incompat_recover != 0) return fatal("the journal needs recovery (mount it in Linux first)", .{});
    if (incompat & ~(incompat_filetype | incompat_flex_bg) != 0) return fatal("unsupported features (incompat 0x{x}): ext4?", .{incompat});
    if (ro_compat & ~(ro_compat_sparse_super | ro_compat_large_file) != 0) return fatal("unsupported features (ro_compat 0x{x})", .{ro_compat});
    if (compat & compat_sparse_super2 != 0) {
        backup_bgs = .{ c.rd32(&sb, 588), c.rd32(&sb, 592) };
        for (backup_bgs) |g| {
            if (g >= ncg) return fatal("backup group {d} is past the last group", .{g});
        }
    }
    if (rev1 and c.rd32(&sb, 232) != 0) return fatal("the volume has a list of files to delete (orphans): mount it in Linux first", .{});
    filetype = incompat & incompat_filetype != 0;
    gd_blocks = (ncg + bs / 32 - 1) / (bs / 32);
    const rb = c.rd32(&sb, 8);
    if (rb > blocks) {
        c.problem(true, "reserved block count {d} is larger than the volume (set to 5%)", .{rb});
        if (c.fixing) {
            c.wr32(&sb, 8, blocks / 20);
            writeSuper();
        }
    }
    return true;
}

fn writeSuper() void {
    if (!c.write(1024, &sb)) c.report("cannot write the superblock", .{});
}

fn hasSuper(g: u32) bool {
    if (g == 0) return true;
    if (compat & compat_sparse_super2 != 0) return g == backup_bgs[0] or g == backup_bgs[1];
    if (!rev1 or ro_compat & ro_compat_sparse_super == 0 or g <= 1) return true;
    for ([_]u32{ 3, 5, 7 }) |p| {
        var x: u64 = p;
        while (x < g) x *= p;
        if (x == g) return true;
    }
    return false;
}

fn gdBlockBitmap(g: u32) u32 {
    return c.rd32(gd, g * 32);
}
fn gdInodeBitmap(g: u32) u32 {
    return c.rd32(gd, g * 32 + 4);
}
fn gdInodeTable(g: u32) u32 {
    return c.rd32(gd, g * 32 + 8);
}

fn inodeTableBlocks() u32 {
    return (ipg * ino_size + bs - 1) / bs;
}

// Also the reserved GDT blocks of resize_inode, named by
// its double indirect table.
fn markMetadata() bool {
    var b: u32 = 0;
    while (b < first_data) : (b += 1) c.bitSet(bmap, b);
    const reserved_gdt: u32 = if (compat & compat_resize_inode != 0) c.rd16(&sb, 206) else 0;
    var g: u32 = 0;
    while (g < ncg) : (g += 1) {
        const base = first_data + g * bpg;
        if (hasSuper(g)) {
            if (!markMeta(base, 1 + gd_blocks + reserved_gdt, g, "superblock and descriptors")) return false;
        }
        if (!markMeta(gdBlockBitmap(g), 1, g, "block map")) return false;
        if (!markMeta(gdInodeBitmap(g), 1, g, "inode map")) return false;
        if (!markMeta(gdInodeTable(g), inodeTableBlocks(), g, "inode table")) return false;
    }
    return true;
}

fn markMeta(start: u32, n: u32, g: u32, what: []const u8) bool {
    if (start < first_data or @as(u64, start) + n > blocks) return fatal("group {d}: its {s} is outside the volume", .{ g, what });
    var b = start;
    while (b < start + n) : (b += 1) {
        if (c.bitGet(bmap, b)) return fatal("group {d}: its {s} overlaps other tables", .{ g, what });
        c.bitSet(bmap, b);
    }
    return true;
}

const Inode = struct {
    raw: [128]u8,
    fn mode(n: *const Inode) u16 {
        return c.rd16(&n.raw, 0);
    }
    fn kind(n: *const Inode) u16 {
        return c.rd16(&n.raw, 0) & s_ifmt;
    }
    fn links(n: *const Inode) u16 {
        return c.rd16(&n.raw, 26);
    }
    fn dtime(n: *const Inode) u32 {
        return c.rd32(&n.raw, 20);
    }
    fn sectors(n: *const Inode) u32 {
        return c.rd32(&n.raw, 28);
    }
    fn flags(n: *const Inode) u32 {
        return c.rd32(&n.raw, 32);
    }
    fn ptr(n: *const Inode, i: usize) u32 {
        return c.rd32(&n.raw, 40 + 4 * i);
    }
    fn acl(n: *const Inode) u32 {
        return c.rd32(&n.raw, 104);
    }
    fn size(n: *const Inode) u64 {
        const lo: u64 = c.rd32(&n.raw, 4);
        if (n.kind() == s_ifreg) return lo | @as(u64, c.rd32(&n.raw, 108)) << 32;
        return lo;
    }
    fn setSize(n: *Inode, s: u64) void {
        c.wr32(&n.raw, 4, @truncate(s));
        if (n.kind() == s_ifreg) c.wr32(&n.raw, 108, @intCast(s >> 32));
    }
};

fn inodePlace(ino: u32) struct { block: u64, at: usize } {
    const g = (ino - 1) / ipg;
    const off = @as(u64, (ino - 1) % ipg) * ino_size;
    return .{ .block = gdInodeTable(g) + off / bs, .at = @intCast(off % bs) };
}

fn loadInodeBlock(block: u64) bool {
    if (ino_cache_block == block) return true;
    ino_cache_block = null;
    if (!c.read(block * bs, ino_cache)) return false;
    ino_cache_block = block;
    return true;
}

// The rest of the inode is kept as it is.
fn readInode(ino: u32) ?Inode {
    const p = inodePlace(ino);
    if (!loadInodeBlock(p.block)) {
        c.report("cannot read inode {d}", .{ino});
        return null;
    }
    return .{ .raw = ino_cache[p.at..][0..128].* };
}

fn writeInode(ino: u32, n: *const Inode) bool {
    const p = inodePlace(ino);
    if (!loadInodeBlock(p.block)) return false;
    @memcpy(ino_cache[p.at..][0..128], &n.raw);
    const sec_at = p.at - p.at % c.sector;
    return c.write(p.block * bs + sec_at, ino_cache[sec_at..][0..c.sector]);
}

fn putInode(ino: u32, n: *const Inode) void {
    if (c.fixing and !writeInode(ino, n)) c.report("cannot write inode {d}", .{ino});
}

fn zeroInode(ino: u32) void {
    if (!c.fixing) return;
    const p = inodePlace(ino);
    if (!loadInodeBlock(p.block)) return c.report("cannot read inode {d}", .{ino});
    @memset(ino_cache[p.at..][0..ino_size], 0);
    const first_sec = p.at - p.at % c.sector;
    const end = std.mem.alignForward(usize, p.at + ino_size, c.sector);
    if (!c.write(p.block * bs + first_sec, ino_cache[first_sec..end])) c.report("cannot clear inode {d}", .{ino});
}

fn entryType(kind: u16) u8 {
    return switch (kind) {
        s_ifreg => 1,
        s_ifdir => 2,
        s_ifchr => 3,
        s_ifblk => 4,
        s_ififo => 5,
        s_ifsock => 6,
        s_iflnk => 7,
        else => 0,
    };
}

// INODE BLOCKS (fsck_ext2fs ckinode / iblock / pass1check)

const Walk = struct {
    ino: u32,
    pos: u64 = 0, // the logical block the next pointer maps
    used: u32 = 0, // blocks counted (for i_blocks)
    data: ?*std.ArrayListUnmanaged(u32) = null, // in order (folders)
    mode: enum { mark, dry, unmark } = .mark,
    bad: u32 = 0,
    keep: bool = false, // too many bad pointers: report them, clear none
    own: std.ArrayListUnmanaged(u32) = .{}, // blocks it marked or got: freed if deleted
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

fn inRange(b: u32) bool {
    return b >= first_data and b < blocks;
}

// True if p was changed.
fn walkPointer(p: *[4]u8, level: u2, w: *Walk) bool {
    if (w.delete != null) return false;
    const b = std.mem.readInt(u32, p, .little);
    if (b == 0) {
        w.pos += span(level);
        return false;
    }
    if (!inRange(b)) {
        w.pos += span(level);
        w.bad += 1;
        if (w.mode != .mark or w.keep) return false; // keep: reported once (walkBlocks)
        c.problem(true, "inode {d}: {s} block {d} is outside the volume (pointer cleared)", .{ w.ino, levelName(level), b });
        if (!c.fixing) return false;
        std.mem.writeInt(u32, p, 0, .little);
        return true;
    }
    switch (w.mode) {
        .mark => {
            w.used += 1;
            if (c.bitGet(bmap, b)) {
                if (crossLinked(p, b, level, w)) return true;
                if (level == 0) addData(w, b); // still the folder's
                w.pos += span(level);
                return false;
            }
            c.bitSet(bmap, b);
            own(w, b);
        },
        .unmark => {
            // Shared: the other file's, and so is what it names
            if (c.bitGet(dupmap, b)) {
                w.pos += span(level);
                return false;
            }
            c.bitClr(bmap, b);
        },
        .dry => {},
    }
    if (level == 0) {
        if (w.mode == .mark) addData(w, b);
        w.pos += 1;
        return false;
    }
    const table = level_buf[level];
    if (!c.read(@as(u64, b) * bs, table)) {
        if (w.mode == .mark) c.report("inode {d}: cannot read block {d}", .{ w.ino, b });
        w.pos += span(level);
        return false;
    }
    var changed = false;
    var i: usize = 0;
    while (i < bs) : (i += 4) {
        if (walkPointer(table[i..][0..4], level - 1, w)) changed = true;
    }
    if (changed and c.fixing and w.delete == null and !c.write(@as(u64, b) * bs, table)) c.report("inode {d}: cannot write block {d}", .{ w.ino, b });
    return false;
}

fn own(w: *Walk, b: u32) void {
    if (w.mode != .mark) return;
    w.own.append(arena.allocator(), b) catch {
        incomplete = true;
    };
}

fn addData(w: *Walk, b: u32) void {
    const list = w.data orelse return;
    if (w.pos > 1 << 20) return; // no folder is that large
    const a = arena.allocator();
    while (list.items.len < w.pos) list.append(a, 0) catch {
        incomplete = true;
        return;
    };
    list.append(a, b) catch {
        incomplete = true;
    };
}

fn pointerLevel(i: usize) u2 {
    return if (i < ndir) 0 else @intCast(i - ndir + 1);
}

fn walkBlocks(n: *Inode, w: *Walk) bool {
    if (w.mode == .mark) {
        // Many bad pointers: the tables are likely garbage, clear nothing:
        var dry = Walk{ .ino = w.ino, .mode = .dry };
        var copy = n.*;
        for (0..15) |i| _ = walkPointer(copy.raw[40 + 4 * i ..][0..4], pointerLevel(i), &dry);
        w.keep = dry.bad > max_bad;
        if (w.keep) {
            if (deletes(w)) {
                w.delete = "a damaged inode: its block pointers are garbage";
                return false;
            }
            unfixable(w, "inode {d}: {d} block pointers outside the volume: a damaged inode", .{ w.ino, dry.bad });
        }
    }
    var changed = false;
    for (0..15) |i| {
        if (walkPointer(n.raw[40 + 4 * i ..][0..4], pointerLevel(i), w)) changed = true;
    }
    return changed;
}

// A fast symbolic link keeps its target in the pointers
fn fastLink(n: *const Inode) bool {
    const acl_sectors: u32 = if (n.acl() != 0) bs / 512 else 0;
    return n.kind() == s_iflnk and n.sectors() == acl_sectors;
}

fn hasBlocks(n: *const Inode) bool {
    return switch (n.kind()) {
        s_ifchr, s_ifblk, s_ififo, s_ifsock => false,
        s_iflnk => !fastLink(n),
        else => true,
    };
}

// CROSS-LINKS

// b is already in use. The check reports it; the repair copies b (and
// what an indirect b names) to free blocks for this file, so both keep
// their data where it is. True if p now names the copy.
fn crossLinked(p: *[4]u8, b: u32, level: u2, w: *Walk) bool {
    c.bitSet(dupmap, b);
    if (w.keep) return false; // a damaged inode: reported as such
    if (!c.fixing) {
        had_cross = true;
        c.report("inode {d}: {s} block {d} is also used by another file or the file system (cross-linked): -F gives this file its own copy", .{ w.ino, levelName(level), b });
        return false;
    }
    // Not seen by the check: the census now (it reads only the inode table)
    if (!census_done) census();
    const need = treeSize(b, level);
    if (need > free_left) {
        if (deletes(w)) {
            w.delete = "cross-linked, no room for its own copy";
            return false;
        }
        unfixable(w, "inode {d}: {s} block {d} is cross-linked; its copy needs {d} free blocks, {d} are left", .{ w.ino, levelName(level), b, need, free_left });
        return false;
    }
    const copy = copyTree(b, level, w) orelse {
        if (deletes(w)) {
            w.delete = "cross-linked, its copy failed";
            return false;
        }
        unfixable(w, "inode {d}: {s} block {d} is cross-linked; it could not be copied", .{ w.ino, levelName(level), b });
        return false;
    };
    std.mem.writeInt(u32, p, copy, .little);
    c.bitClr(dupmap, b);
    c.fixedCross("inode {d} ({s} block {d})", .{ w.ino, levelName(level), b });
    return true;
}

// Every block any inode in use names, before pass 1
// marks them: free_left is what copies may take.
fn census() void {
    var ino: u32 = 1;
    while (ino <= inodes) : (ino += 1) {
        const n = readInode(ino) orelse continue;
        if (n.mode() == 0 and n.ptr(0) == 0) continue;
        if (n.mode() != 0 and n.dtime() != 0 and n.links() == 0) continue;
        if (ino == resize_ino and compat & compat_resize_inode != 0) {
            claimTree(n.ptr(13), 0); // what it names is metadata
            continue;
        }
        if (n.flags() & (extents_fl | inline_fl) != 0) continue;
        claimTree(n.acl(), 0);
        if (n.mode() != 0 and (!validType(n.kind()) or !hasBlocks(&n))) continue;
        for (0..15) |i| claimTree(n.ptr(i), pointerLevel(i));
    }
    free_left = 0;
    var b: u32 = first_data;
    while (b < blocks) : (b += 1) {
        if (!c.bitGet(bmap, b) and !c.bitGet(claimed, b)) free_left += 1;
    }
    census_done = true;
}

fn claimTree(b: u32, level: u2) void {
    if (b == 0 or !inRange(b) or c.bitGet(claimed, b)) return;
    c.bitSet(claimed, b);
    if (level == 0) return;
    const table = census_buf[level];
    if (!c.read(@as(u64, b) * bs, table)) return;
    var i: usize = 0;
    while (i < bs) : (i += 4) claimTree(c.rd32(table, i), level - 1);
}

// b and what it names in the volume; unreadable: too many
fn treeSize(b: u32, level: u2) u64 {
    if (level == 0) return 1;
    const table = count_buf[level];
    if (!c.read(@as(u64, b) * bs, table)) return std.math.maxInt(u64);
    var total: u64 = 1;
    var i: usize = 0;
    while (i < bs) : (i += 4) {
        const e = c.rd32(table, i);
        if (e != 0 and inRange(e)) total +|= treeSize(e, level - 1);
    }
    return total;
}

// The copy's block; null on a read or write error. Pointers
// outside the volume are dropped from copied tables.
fn copyTree(b: u32, level: u2, w: *Walk) ?u32 {
    if (level == 0) {
        const nb = freeBlock() orelse return null;
        own(w, nb);
        if (!c.read(@as(u64, b) * bs, copy_buf) or !c.write(@as(u64, nb) * bs, copy_buf)) return null;
        addData(w, nb);
        w.pos += 1;
        return nb;
    }
    const table = clone_buf[level];
    if (!c.read(@as(u64, b) * bs, table)) return null;
    var i: usize = 0;
    while (i < bs) : (i += 4) {
        const e = c.rd32(table, i);
        if (e == 0 or !inRange(e)) {
            c.wr32(table, i, 0);
            w.pos += span(level - 1);
            continue;
        }
        const copy = copyTree(e, level - 1, w) orelse return null;
        c.wr32(table, i, copy);
        w.used += 1;
    }
    const nb = freeBlock() orelse return null;
    own(w, nb);
    if (!c.write(@as(u64, nb) * bs, table)) return null;
    return nb;
}

// -D in the repair: files only, never the root or the reserved inodes
fn deletable(ino: u32) bool {
    return ino >= first_ino;
}

fn deletes(w: *const Walk) bool {
    return c.fixing and c.deleting and deletable(w.ino);
}

// What -D would delete says so; the reserved inodes and the root not
fn unfixable(w: *const Walk, comptime fmt: []const u8, args: anytype) void {
    if (deletable(w.ino)) return c.onlyByDeleting(fmt, args);
    if (c.fixing) c.report("cannot fix: " ++ fmt, args) else c.report(fmt, args);
}

// Its blocks (not those it shared) free again, the inode cleared; its
// entries are removed in pass 2. A folder's files become lost ones.
fn deleteFile(ino: u32, w: *const Walk, why: []const u8) void {
    for (w.own.items) |b| c.bitClr(bmap, b);
    c.bitClr(walked, ino);
    state[ino] = .unused;
    zeroInode(ino);
    c.deleted("inode {d}: {s}", .{ ino, why });
}

// Every inode, its type and blocks.

fn pass1() void {
    var ino: u32 = 1;
    while (ino <= inodes) : (ino += 1) {
        if (ino < first_ino and ino != root_ino) {
            reservedInode(ino);
            continue;
        }
        checkInode(ino);
    }
}

// Bad blocks, journal ...: only their blocks are marked.
fn reservedInode(ino: u32) void {
    state[ino] = .reserved;
    var n = readInode(ino) orelse return;
    if (ino == resize_ino and compat & compat_resize_inode != 0) {
        // Its tables are the reserved GDT blocks, marked with the metadata:
        const b = n.ptr(13);
        if (b != 0 and inRange(b) and !c.bitGet(bmap, b)) c.bitSet(bmap, b);
        return;
    }
    if (n.mode() == 0 and n.ptr(0) == 0) return;
    var w = Walk{ .ino = ino };
    if (hasBlocks(&n) and walkBlocks(&n, &w)) putInode(ino, &n);
}

fn validType(kind: u16) bool {
    return entryType(kind) != 0;
}

fn checkInode(ino: u32) void {
    var n = readInode(ino) orelse return;
    const kind = n.kind();
    if (n.mode() == 0 or (n.dtime() != 0 and n.links() == 0)) {
        if (n.mode() == 0 and (n.size() != 0 or !std.mem.allEqual(u8, n.raw[40..100], 0))) {
            c.problem(true, "inode {d} is partly allocated (cleared)", .{ino});
            zeroInode(ino);
        }
        return;
    }
    var changed = false;
    if (n.dtime() != 0) {
        c.problem(true, "inode {d} is in use but has a deletion time (cleared)", .{ino});
        c.wr32(&n.raw, 20, 0);
        changed = true;
    }
    if (!validType(kind) or n.flags() & (extents_fl | inline_fl) != 0) {
        c.problem(true, "inode {d} has an unknown type (mode 0{o}, flags 0x{x}) (cleared)", .{ ino, n.mode(), n.flags() });
        state[ino] = .clear;
        return;
    }
    if (n.size() > 0x7FFF_FFFF and ro_compat & ro_compat_large_file == 0) {
        c.problem(true, "inode {d} is larger than 2 GB, the large-file flag is not set (set)", .{ino});
        ro_compat |= ro_compat_large_file;
        if (c.fixing) {
            c.wr32(&sb, 100, ro_compat);
            writeSuper();
        }
    }
    ftype[ino] = entryType(kind);
    var data: std.ArrayListUnmanaged(u32) = .{};
    var w = Walk{ .ino = ino };
    if (kind == s_ifdir) w.data = &data;
    if (hasBlocks(&n)) {
        c.bitSet(walked, ino);
        if (walkBlocks(&n, &w)) changed = true;
    }
    if (w.delete) |why| return deleteFile(ino, &w, why);
    if (checkAcl(&n, ino)) changed = true;
    if (n.acl() != 0) w.used += 1;
    const want = w.used * (bs / 512);
    if (n.sectors() != want) {
        c.problem(true, "inode {d}: block count is {d}, it has {d} sectors (set)", .{ ino, n.sectors(), want });
        c.wr32(&n.raw, 28, want);
        changed = true;
    }
    if (kind == s_ifdir) {
        if (dirSize(&n, ino, data.items)) changed = true;
        if (n.size() == 0) {
            c.problem(true, "inode {d} is a folder without blocks (cleared)", .{ino});
            state[ino] = .clear;
        } else {
            state[ino] = .dir;
            dirs.put(arena.allocator(), ino, .{ .blocks = data.items, .size = n.size() }) catch {
                incomplete = true;
            };
        }
    } else {
        state[ino] = .file;
        if (kind == s_iflnk and fastLink(&n) and n.size() >= 60) c.report("inode {d}: symbolic link of {d} bytes kept in the inode", .{ ino, n.size() });
    }
    if (changed) putInode(ino, &n);
}

// In the volume, and shared only with other attributes.
fn checkAcl(n: *Inode, ino: u32) bool {
    const b = n.acl();
    if (b == 0) return false;
    if (!inRange(b)) {
        c.problem(true, "inode {d}: attribute block {d} is outside the volume (cleared)", .{ ino, b });
        c.wr32(&n.raw, 104, 0);
        return true;
    }
    if (c.bitGet(xattr, b)) return false;
    if (c.bitGet(bmap, b)) {
        c.problem(false, "inode {d}: attribute block {d} is also used by another file (cross-linked)", .{ ino, b });
        c.bitSet(dupmap, b);
        return false;
    }
    c.bitSet(bmap, b);
    c.bitSet(xattr, b);
    return false;
}

// Whole blocks, at least its first one.
fn dirSize(n: *Inode, ino: u32, data: []const u32) bool {
    const size = n.size();
    var last: u64 = 0; // past the last data block
    for (data, 0..) |b, i| {
        if (b != 0) last = i + 1;
    }
    if (last == 0) return false;
    var want = size;
    if (size == 0) {
        want = last * bs;
    } else if (size < 24) {
        want = bs;
    } else if (size % bs != 0) {
        want = std.mem.alignForward(u64, size, bs);
    }
    if (want == size) return false;
    c.problem(true, "inode {d}: folder size {d} is not whole blocks (set to {d})", .{ ino, size, want });
    n.setSize(want);
    return true;
}

// The folders, from the root.

fn pass2() bool {
    switch (state[root_ino]) {
        .dir => {},
        else => return fatal("the root inode is not a folder", .{}),
    }
    enqueue(root_ino, root_ino, "\\");
    scanPending();
    return true;
}

fn enqueue(ino: u32, parent: u32, path: []const u8) void {
    c.bitSet(reached, ino);
    ndirs += 1;
    pending.append(arena.allocator(), .{ .ino = ino, .parent = parent, .path = path }) catch {
        incomplete = true;
    };
}

fn scanPending() void {
    while (pending_next < pending.items.len) {
        const f = pending.items[pending_next];
        pending_next += 1;
        scanFolder(f);
    }
}

fn dirsiz(name_len: u32) u32 {
    return (8 + name_len + 3) & ~@as(u32, 3);
}

// fsck_ext2fs dircheck
fn entryOk(block: []const u8, off: usize) bool {
    const left = bs - off;
    if (left < 8) return false;
    const ino = c.rd32(block, off);
    const reclen = c.rd16(block, off + 4);
    if (ino > inodes or reclen < 8 or reclen > left or reclen & 3 != 0) return false;
    if (ino == 0) return true;
    const name_len = block[off + 6];
    if (reclen < dirsiz(name_len) or name_len == 0) return false;
    for (block[off + 8 ..][0..name_len]) |ch| {
        if (ch == 0 or ch == '/') return false;
    }
    return true;
}

fn scanFolder(f: Folder) void {
    const d = dirs.get(f.ino) orelse return;
    const nblocks: usize = @intCast(@min(d.blocks.len, (d.size + bs - 1) / bs));
    var index: u32 = 0; // entry number: 0 is '.', 1 is '..'
    if (d.blocks.len * bs < d.size) c.report("{s}: has empty blocks inside its size", .{f.path});
    for (d.blocks[0..nblocks], 0..) |b, bi| {
        if (b == 0) {
            c.report("{s}: block {d} of the folder is empty", .{ f.path, bi });
            continue;
        }
        const block = scan_buf;
        if (!c.read(@as(u64, b) * bs, block)) {
            c.report("{s}: cannot read block {d}", .{ f.path, b });
            continue;
        }
        var dirty = false;
        var off: usize = 0;
        while (off < bs) {
            if (!entryOk(block, off)) {
                // As fsck_readdir, the rest of the block is dropped:
                c.problem(true, "{s}: damaged entry at byte {d} of block {d} (rest of the block dropped)", .{ f.path, off, b });
                if (c.fixing) {
                    if (off == 0) {
                        @memset(block, 0);
                        c.wr16(block, 4, @intCast(bs));
                    } else {
                        dropRest(block, off);
                    }
                    dirty = true;
                }
                break;
            }
            const reclen = c.rd16(block, off + 4);
            if (c.rd32(block, off) != 0) {
                if (checkEntry(f, block[off..][0..reclen], index)) dirty = true;
                index += 1;
            } else if (bi == 0 and off == 0) index += 1; // a cleared '.'
            off += reclen;
        }
        if (dirty and c.fixing and !c.write(@as(u64, b) * bs, block)) c.report("{s}: cannot write block {d}", .{ f.path, b });
    }
}

// The entry before off takes the space to the end of the block.
fn dropRest(block: []u8, off: usize) void {
    var prev: usize = 0;
    while (true) {
        const next = prev + c.rd16(block, prev + 4);
        if (next >= off) break;
        prev = next;
    }
    c.wr16(block, prev + 4, @intCast(bs - prev));
}

fn printable(name: []const u8) []const u8 {
    for (name) |ch| {
        if (ch < 0x20 or ch > 0x7E) return "(unprintable name)";
    }
    return name;
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

// fsck_ext2fs pass2check; true if changed.
fn checkEntry(f: Folder, e: []u8, index: u32) bool {
    const ino = c.rd32(e, 0);
    const name = e[8..][0..e[6]];
    const is_dot = std.mem.eql(u8, name, ".");
    const is_dotdot = std.mem.eql(u8, name, "..");
    if (index == 0 or index == 1) {
        const want_name = if (index == 0) "." else "..";
        if (!std.mem.eql(u8, name, want_name)) {
            c.report("{s}: '{s}' is missing (the entry there is '{s}')", .{ f.path, want_name, printable(name) });
        } else {
            const want = if (index == 0) f.ino else f.parent;
            var changed = false;
            if (want != 0 and ino != want) {
                c.problem(true, "{s}: '{s}' names inode {d} instead of {d} (set)", .{ f.path, want_name, ino, want });
                c.wr32(e, 0, want);
                changed = c.fixing;
            }
            if (filetype and e[7] != 2) {
                c.problem(true, "{s}: '{s}' has the wrong type (set)", .{ f.path, want_name });
                e[7] = 2;
                changed = c.fixing;
            }
            const named = if (want != 0) want else ino;
            if (named >= 1 and named <= inodes) count[named] += 1;
            return changed;
        }
    }
    if (is_dot or is_dotdot) {
        c.problem(true, "{s}: extra '{s}' entry (removed)", .{ f.path, name });
        return removeEntry(e);
    }
    if (ino > inodes or (ino < first_ino and ino != root_ino)) {
        c.problem(true, "{s}{s}: names inode {d}, out of range (removed)", .{ f.path, printable(name), ino });
        return removeEntry(e);
    }
    if (count[ino] >= link_max) {
        c.problem(true, "{s}{s}: too many links to inode {d} (removed)", .{ f.path, printable(name), ino });
        return removeEntry(e);
    }
    switch (state[ino]) {
        .unused, .reserved => {
            c.problem(true, "{s}{s}: names inode {d}, which is not in use (removed)", .{ f.path, printable(name), ino });
            return removeEntry(e);
        },
        .clear => {
            c.problem(true, "{s}{s}: names inode {d}, which is damaged (removed)", .{ f.path, printable(name), ino });
            return removeEntry(e);
        },
        .dir => {
            if (c.bitGet(reached, ino)) {
                c.problem(true, "{s}{s}: is a second link to a folder (removed)", .{ f.path, printable(name) });
                return removeEntry(e);
            }
            if (f.ino == root_ino and std.mem.eql(u8, name, "lost+found")) lf_ino = ino;
            enqueue(ino, f.ino, childPath(f.path, name, true));
        },
        .file => {
            if (!c.bitGet(reached, ino)) {
                c.bitSet(reached, ino);
                nfiles += 1;
            }
        },
    }
    count[ino] += 1;
    if (filetype and e[7] != ftype[ino]) {
        c.problem(true, "{s}{s}: entry has the wrong type {d} (set to {d})", .{ f.path, printable(name), e[7], ftype[ino] });
        e[7] = ftype[ino];
        return c.fixing;
    }
    return false;
}

fn removeEntry(e: []u8) bool {
    if (!c.fixing) return false;
    c.wr32(e, 0, 0);
    return true;
}

// PASS 3 AND 4: LOST FOLDERS AND FILES, LINK COUNTS

fn isLost(ino: u32) bool {
    return (state[ino] == .file or state[ino] == .dir) and !c.bitGet(reached, ino);
}

// Follows '..' up while it names a lost folder.
fn topLost(start: u32) u32 {
    var ino = start;
    var steps: u32 = 0;
    while (steps < 1000) : (steps += 1) {
        const d = dirs.get(ino) orelse return ino;
        if (d.blocks.len == 0 or d.blocks[0] == 0) return ino;
        if (!c.read(@as(u64, d.blocks[0]) * bs, buf)) return ino;
        const first_len = c.rd16(buf, 4);
        if (first_len < 12 or first_len + 12 > bs) return ino;
        const up = c.rd32(buf, first_len);
        if (up < 1 or up > inodes or up == start or state[up] != .dir or !isLost(up)) return ino;
        ino = up;
    }
    return ino;
}

// From the topmost lost folder of each chain, so the files of a lost
// folder stay in it.
fn pass3() void {
    var ino: u32 = root_ino;
    while (ino <= inodes) : (ino += 1) {
        if (state[ino] != .dir or !isLost(ino)) continue;
        lostFolder(topLost(ino));
        if (isLost(ino)) lostFolder(ino);
        if (incomplete) return;
    }
}

fn lostFolder(ino: u32) void {
    const size = if (dirs.get(ino)) |d| d.size else 0;
    const path = std.fmt.allocPrint(arena.allocator(), "\\lost+found\\#{d}\\", .{ino}) catch {
        incomplete = true;
        return;
    };
    if (!linkLost(ino, true, size)) c.bitSet(reached, ino);
    enqueue(ino, lf_ino, path);
    scanPending();
}

fn pass4() void {
    var ino: u32 = root_ino;
    while (ino <= inodes) : (ino += 1) {
        switch (state[ino]) {
            .clear => {
                clearInode(ino, "damaged");
                continue;
            },
            .file, .dir => {},
            else => continue,
        }
        var n = readInode(ino) orelse continue;
        if (isLost(ino)) {
            if (n.links() == 0) {
                clearInode(ino, "in no folder, with no links");
                continue;
            }
            if (!linkLost(ino, false, n.size())) continue;
        }
        const want: u16 = @intCast(@min(count[ino], link_max));
        if (n.links() == want) continue;
        c.problem(true, "inode {d}: link count is {d}, {d} entries name it (set)", .{ ino, n.links(), want });
        c.wr16(&n.raw, 26, want);
        putInode(ino, &n);
    }
}

// fsck_ext2fs clri: blocks used twice stay in use.
fn clearInode(ino: u32, why: []const u8) void {
    c.problem(true, "inode {d} is {s} (cleared)", .{ ino, why });
    if (c.bitGet(walked, ino)) {
        if (readInode(ino)) |n0| {
            var n = n0;
            var w = Walk{ .ino = ino, .mode = .unmark };
            _ = walkBlocks(&n, &w);
        }
    }
    state[ino] = .unused;
    zeroInode(ino);
}

// Made if missing; the check only reports it. false if it stays lost.
fn linkLost(ino: u32, is_dir: bool, size: u64) bool {
    var name_buf: [16]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "#{d}", .{ino}) catch unreachable;
    const what = if (is_dir) "folder" else "file";
    if (!c.fixing) {
        c.report("inode {d} ({s}, {d} bytes) is in no folder: -F links it into \\lost+found as {s}", .{ ino, what, size, name });
        if (lf_ino == 0 and !lf_said) {
            zdos.print("    there is no \\lost+found: -F makes one\n");
            lf_said = true;
        }
    } else {
        if (lf_ino == 0 and !makeLostFound()) {
            c.report("inode {d} is in no folder: cannot make \\lost+found", .{ino});
            return false;
        }
        if (!addEntry(lf_ino, name, ino)) {
            c.report("inode {d} is in no folder: no room in \\lost+found", .{ino});
            return false;
        }
        c.fixed("inode {d} ({s}, {d} bytes) linked into \\lost+found as {s}", .{ ino, what, size, name });
    }
    count[ino] += 1;
    c.bitSet(reached, ino);
    if (!is_dir) nfiles += 1;
    return true;
}

fn freeBlock() ?u32 {
    var b: u32 = first_data;
    while (b < blocks) : (b += 1) {
        if (!c.bitGet(bmap, b) and !c.bitGet(claimed, b)) {
            c.bitSet(bmap, b);
            c.bitSet(claimed, b);
            free_left -|= 1;
            return b;
        }
    }
    return null;
}

fn makeLostFound() bool {
    var ino: u32 = first_ino;
    const new = while (ino <= inodes) : (ino += 1) {
        if (state[ino] == .unused) break ino;
    } else return false;
    const b = freeBlock() orelse return false;
    @memset(buf, 0);
    c.wr32(buf, 0, new);
    c.wr16(buf, 4, 12);
    buf[6] = 1;
    buf[7] = if (filetype) 2 else 0;
    buf[8] = '.';
    c.wr32(buf, 12, root_ino);
    c.wr16(buf, 16, @intCast(bs - 12));
    buf[18] = 2;
    buf[19] = if (filetype) 2 else 0;
    buf[20] = '.';
    buf[21] = '.';
    if (!c.write(@as(u64, b) * bs, buf)) return false;
    var n = Inode{ .raw = .{0} ** 128 };
    c.wr16(&n.raw, 0, s_ifdir | 0o700);
    const now = c.unixNow();
    c.wr32(&n.raw, 8, now);
    c.wr32(&n.raw, 12, now);
    c.wr32(&n.raw, 16, now);
    c.wr16(&n.raw, 26, 2);
    c.wr32(&n.raw, 28, bs / 512);
    c.wr32(&n.raw, 40, b);
    n.setSize(bs);
    zeroInode(new); // the extra bytes of a large inode
    if (!writeInode(new, &n)) return false;
    ftype[new] = 2;
    if (!addEntry(root_ino, "lost+found", new)) return false;
    // The root gets the new folder's '..':
    if (readInode(root_ino)) |r0| {
        var r = r0;
        c.wr16(&r.raw, 26, r.links() + 1);
        putInode(root_ino, &r);
    }
    state[new] = .dir;
    c.bitSet(reached, new);
    count[new] += 2;
    count[root_ino] += 1;
    ndirs += 1;
    const list = arena.allocator().alloc(u32, 1) catch return false;
    list[0] = b;
    dirs.put(arena.allocator(), new, .{ .blocks = list, .size = bs }) catch return false;
    lf_ino = new;
    c.fixed("made \\lost+found", .{});
    return true;
}

// fsck_ext2fs makeentry / expanddir. An indexed folder becomes a plain
// one, as its index would miss the name.
fn addEntry(dir: u32, name: []const u8, ino: u32) bool {
    var n = readInode(dir) orelse return false;
    const need = dirsiz(@intCast(name.len));
    const nblocks: usize = @intCast((n.size() + bs - 1) / bs);
    var bi: usize = 0;
    while (bi < nblocks and bi < ndir) : (bi += 1) {
        const b = n.ptr(bi);
        if (b == 0 or !inRange(b)) continue;
        if (!c.read(@as(u64, b) * bs, buf)) return false;
        var off: usize = 0;
        while (off + 8 <= bs) {
            const reclen = c.rd16(buf, off + 4);
            if (reclen < 8 or off + reclen > bs) break;
            const used: u32 = if (c.rd32(buf, off) != 0) dirsiz(buf[off + 6]) else 0;
            if (reclen - used >= need) {
                if (used > 0) c.wr16(buf, off + 4, @intCast(used));
                putEntry(buf[off + used ..], reclen - used, name, ino);
                if (!c.write(@as(u64, b) * bs, buf)) return false;
                return unindex(dir, &n);
            }
            off += reclen;
        }
    }
    if (nblocks >= ndir) return false;
    const b = freeBlock() orelse return false;
    @memset(buf, 0);
    putEntry(buf, bs, name, ino);
    if (!c.write(@as(u64, b) * bs, buf)) return false;
    c.wr32(&n.raw, 40 + 4 * nblocks, b);
    n.setSize(@as(u64, nblocks + 1) * bs);
    c.wr32(&n.raw, 28, n.sectors() + bs / 512);
    if (dirs.getPtr(dir)) |d| {
        const list = arena.allocator().alloc(u32, nblocks + 1) catch return false;
        @memset(list, 0);
        @memcpy(list[0..@min(d.blocks.len, nblocks)], d.blocks[0..@min(d.blocks.len, nblocks)]);
        list[nblocks] = b;
        d.* = .{ .blocks = list, .size = n.size() };
    }
    return unindex(dir, &n);
}

fn putEntry(e: []u8, reclen: u32, name: []const u8, ino: u32) void {
    @memset(e[0..reclen], 0);
    c.wr32(e, 0, ino);
    c.wr16(e, 4, @intCast(reclen));
    e[6] = @intCast(name.len);
    e[7] = if (filetype) ftype[ino] else 0;
    @memcpy(e[8..][0..name.len], name);
}

fn unindex(dir: u32, n: *Inode) bool {
    if (n.flags() & index_fl != 0) c.wr32(&n.raw, 32, n.flags() & ~index_fl);
    return writeInode(dir, n);
}

// The maps and the free counts.

fn pass5() void {
    var map_bad_b: u32 = 0;
    var map_bad_i: u32 = 0;
    var sum_bad: u32 = 0;
    var total_bfree: u32 = 0;
    var total_ifree: u32 = 0;
    var g: u32 = 0;
    while (g < ncg) : (g += 1) {
        // Blocks:
        const base = first_data + g * bpg;
        const in_group = @min(bpg, blocks - base);
        @memset(scan_buf, 0xFF);
        var nbfree: u32 = 0;
        var i: u32 = 0;
        while (i < in_group) : (i += 1) {
            if (c.bitGet(bmap, base + i)) continue;
            c.bitClr(scan_buf, i);
            nbfree += 1;
        }
        if (compareBitmap(gdBlockBitmap(g), in_group)) map_bad_b += 1;
        // Inodes:
        @memset(scan_buf, 0xFF);
        var nifree: u32 = 0;
        var gdirs: u32 = 0;
        i = 0;
        const ino_base = g * ipg;
        while (i < ipg) : (i += 1) {
            const ino = ino_base + i + 1;
            if (ino > inodes) break;
            switch (state[ino]) {
                .unused => {
                    c.bitClr(scan_buf, i);
                    nifree += 1;
                },
                .dir => gdirs += 1,
                else => {},
            }
        }
        if (compareBitmap(gdInodeBitmap(g), ipg)) map_bad_i += 1;
        total_bfree += nbfree;
        total_ifree += nifree;
        const d = gd[g * 32 ..][0..32];
        if (c.rd16(d, 12) != nbfree or c.rd16(d, 14) != nifree or c.rd16(d, 16) != gdirs) {
            if (sum_bad < 10) zdos.printf("    group {d}: {d} free blocks, {d} free inodes, {d} folders; counted {d}, {d}, {d}\n", .{ g, c.rd16(d, 12), c.rd16(d, 14), c.rd16(d, 16), nbfree, nifree, gdirs });
            sum_bad += 1;
            c.wr16(d, 12, @intCast(nbfree));
            c.wr16(d, 14, @intCast(nifree));
            c.wr16(d, 16, @intCast(gdirs));
        }
    }
    if (map_bad_b > 0) c.problem(true, "the block maps of {d} groups are wrong (rewritten)", .{map_bad_b});
    if (map_bad_i > 0) c.problem(true, "the inode maps of {d} groups are wrong (rewritten)", .{map_bad_i});
    if (sum_bad > 0) {
        c.problem(true, "the counts of {d} groups are wrong (set)", .{sum_bad});
        if (c.fixing and !c.write(@as(u64, first_data + 1) * bs, gd)) c.report("cannot write the group descriptors", .{});
    }
    const sb_bfree = c.rd32(&sb, 12);
    const sb_ifree = c.rd32(&sb, 16);
    if (sb_bfree != total_bfree or sb_ifree != total_ifree) {
        c.problem(true, "the superblock says {d} free blocks and {d} free inodes, counted {d} and {d} (set)", .{ sb_bfree, sb_ifree, total_bfree, total_ifree });
        if (c.fixing) {
            c.wr32(&sb, 12, total_bfree);
            c.wr32(&sb, 16, total_ifree);
            writeSuper();
        }
    }
}

// Bits past valid are already set in scan_buf. True if they differ.
fn compareBitmap(block: u32, valid: u32) bool {
    if (!c.read(@as(u64, block) * bs, buf)) {
        c.report("cannot read the map in block {d}", .{block});
        return false;
    }
    var shown: u32 = 0;
    var differ = false;
    var i: u32 = 0;
    while (i < valid) : (i += 1) {
        const ours = c.bitGet(scan_buf, i);
        if (ours == c.bitGet(buf, i)) continue;
        differ = true;
        if (shown < 5) {
            zdos.printf("    map in block {d}: bit {d} is {s}\n", .{ block, i, if (ours) "clear but in use" else "set but not in use" });
            shown += 1;
        }
    }
    if (differ and c.fixing and !c.write(@as(u64, block) * bs, scan_buf)) c.report("cannot write the map in block {d}", .{block});
    return differ;
}

// BACKUP SUPERBLOCKS
//
// Groups with a superblock copy (hasSuper) hold the superblock and the
// descriptors again. Their fixed fields must be the primary's; counts,
// state and features may lag (Linux writes them to the primary only),
// as e2fsck allows. The repair writes the primary's over a copy that
// differs.

const sb_fixed = [_][2]u8{ .{ 0, 4 }, .{ 4, 4 }, .{ 20, 4 }, .{ 24, 4 }, .{ 32, 4 }, .{ 40, 4 }, .{ 56, 2 }, .{ 76, 4 } };
const sb_fixed_rev1 = [_][2]u8{ .{ 84, 4 }, .{ 88, 2 }, .{ 104, 16 } }; // first inode, inode size, UUID

fn checkBackups() void {
    const copy = arena.allocator().alloc(u8, @as(usize, gd_blocks) * bs) catch return c.report("out of memory: the backup superblocks are not checked", .{});
    var differ: u32 = 0;
    var unreadable: u32 = 0;
    var g: u32 = 1;
    while (g < ncg) : (g += 1) {
        if (!hasSuper(g)) continue;
        const at = @as(u64, first_data + g * bpg) * bs;
        if (!c.read(at, copy[0..1024])) {
            unreadable += 1;
            continue;
        }
        var same = sameFields(copy[0..1024], &sb_fixed) and (!rev1 or sameFields(copy[0..1024], &sb_fixed_rev1));
        if (same) {
            if (!c.read(at + bs, copy)) {
                unreadable += 1;
                continue;
            }
            var k: u32 = 0;
            while (k < ncg) : (k += 1) {
                // Where the maps and the inode table are:
                if (!std.mem.eql(u8, copy[k * 32 ..][0..12], gd[k * 32 ..][0..12])) same = false;
            }
        }
        if (same) continue;
        if (differ < 5) zdos.printf("    group {d}: its backup superblock or descriptors differ from the primary\n", .{g});
        differ += 1;
        if (c.fixing) writeBackup(g, at);
    }
    if (unreadable > 0) c.report("cannot read the backup superblocks of {d} groups", .{unreadable});
    if (differ > 0) c.problem(true, "the backup superblocks of {d} groups differ from the primary (rewritten)", .{differ});
}

fn sameFields(copy: []const u8, fields: []const [2]u8) bool {
    for (fields) |f| {
        if (!std.mem.eql(u8, copy[f[0]..][0..f[1]], sb[f[0]..][0..f[1]])) return false;
    }
    return true;
}

// The primary's, with the group's number (s_block_group_nr) in it.
fn writeBackup(g: u32, at: u64) void {
    var copy = sb;
    if (rev1) c.wr16(&copy, 90, @intCast(g));
    if (!c.write(at, &copy)) return c.report("cannot write the backup superblock of group {d}", .{g});
    if (!c.write(at + bs, gd)) c.report("cannot write the backup descriptors of group {d}", .{g});
}

// "clean" again once a repair left nothing unfixed.
fn cleanState() void {
    const s = c.rd16(&sb, 58);
    if (s & 1 != 0 and s & 2 == 0) return;
    if (!c.fixing) return c.report("the volume is not marked clean (state 0x{x})", .{s});
    if (c.failures > 0) return c.report("the volume stays marked not clean", .{});
    c.wr16(&sb, 58, 1);
    if (!c.write(1024, &sb)) return c.report("cannot write the superblock", .{});
    c.fixed("marked the volume clean", .{});
}
