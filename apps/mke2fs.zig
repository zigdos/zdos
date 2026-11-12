// MKE2FS: a new, empty ext2 file system, laid out as mke2fs does.
// Features: filetype, sparse_super, large_file.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

const sector = 512;
const usage =
    \\Usage: MKE2FS X: [-b block size] [-L label]
    \\  or MKE2FS <disk> <partition> [-b block size] [-L label]
    \\  or MKE2FS <disk>     lists the disk's partitions
    \\  -b  1024, 2048, 4096 ... 65536 bytes (default 1024 below 512 MB, else 4096)
    \\  -L  up to 16 characters
    \\
;

const Target = struct {
    disk: u32,
    start: u64,
    sectors: u64,
    letter: u8 = 0,
    esp: bool = false,
};

pub fn main(args: []const u8) u8 {
    if (std.mem.trim(u8, args, " \t").len > 0 and users.diskToolDenied("MKE2FS")) return 1;
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    var pos: [2][]const u8 = undefined;
    var npos: usize = 0;
    var block_size: ?u32 = null;
    var label: []const u8 = "";
    while (words.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, "-b")) {
            const v = words.next() orelse return fail(usage);
            const b = std.fmt.parseInt(u32, v, 10) catch return fail(usage);
            if (b < 1024 or b > 65536 or !std.math.isPowerOfTwo(b)) return fail("The block size is 1024 to 65536 bytes, a power of two\n");
            block_size = b;
        } else if (std.mem.eql(u8, word, "-L")) {
            label = words.next() orelse return fail(usage);
            if (label.len > 16) return fail("The label can be 16 bytes at most\n");
        } else {
            if (npos == 2) return fail(usage);
            pos[npos] = word;
            npos += 1;
        }
    }
    if (npos == 0) return fail(usage);

    const target = if (driveLetter(pos[0])) |letter| blk: {
        if (npos != 1) return fail(usage);
        break :blk targetByLetter(letter) orelse return 1;
    } else blk: {
        const disk = std.fmt.parseInt(u32, pos[0], 10) catch return fail(usage);
        if (npos == 1) {
            listPartitions(disk);
            return 1;
        }
        const part_no = std.fmt.parseInt(u32, pos[1], 10) catch return fail(usage);
        break :blk findPartition(disk, part_no) orelse return 1;
    };
    if (isBootVolume(target)) return fail("That is the volume ZDOS was started from: it is not changed\n");

    const bytes = target.sectors * sector;
    const bs = block_size orelse @as(u32, if (bytes < 512 * 1024 * 1024) 1024 else 4096);
    const lay = Layout.plan(target.sectors, bs) orelse return 1;

    zdos.printf("Make an ext2 file system on disk {d}, from sector {d}:\n{d} MB, {d} blocks of {d} bytes, {d} inodes in {d} groups, label \"{s}\".\n", .{
        target.disk,
        target.start,
        @as(u64, lay.blocks) * bs / (1024 * 1024),
        lay.blocks,
        bs,
        lay.ipg * lay.groups,
        lay.groups,
        label,
    });
    if (bs > 4096) zdos.print("Note: Linux on x86 PCs can't mount blocks larger than 4096 bytes.\n");
    if (target.esp) zdos.print("This is an EFI system partition: its boot files would be erased.\n");
    zdos.print("ALL DATA on it will be lost. Go ahead? (Y/N) ");
    if (!sys.askYes()) {
        zdos.print("Nothing was changed.\n");
        return 1;
    }
    sys.syncDisk(target.disk) catch return fail("Cannot sync the target disk before formatting\n");
    if (!write(target, lay, label)) {
        zdos.printf("Cannot write disk {d}\n", .{target.disk});
        return 1;
    }
    zdos.print("Done: an empty ext2 file system.\n");
    setLinuxType(target);
    if (target.letter != 0) sys.driveChanged(target.letter) else sys.diskChanged(target.disk);
    if (zdos.onUefi()) zdos.print("If the firmware had mounted it (FAT), restart ZDOS before using it.\n");
    return 0;
}

fn fail(text: []const u8) u8 {
    zdos.print(text);
    return 1;
}

fn driveLetter(word: []const u8) ?u8 {
    if (word.len == 2 and word[1] == ':' and std.ascii.isAlphabetic(word[0])) return std.ascii.toUpper(word[0]);
    if (word.len == 1 and std.ascii.isAlphabetic(word[0])) return std.ascii.toUpper(word[0]);
    return null;
}

fn targetByLetter(letter: u8) ?Target {
    const info = zdos.driveInfo(letter) catch {
        zdos.printf("No drive {c}:\n", .{letter});
        return null;
    };
    if (info.boot) {
        zdos.printf("Drive {c}: is the drive ZDOS was started from: it is not changed\n", .{letter});
        return null;
    }
    if (info.floppy) {
        zdos.print("Floppies get FAT: use FORMAT\n");
        return null;
    }
    const loc = sys.driveLocation(letter) catch {
        zdos.printf("Cannot tell where drive {c}: is on its disk\n", .{letter});
        return null;
    };
    return .{ .disk = loc.disk, .start = loc.start, .sectors = loc.sectors, .letter = letter, .esp = info.system };
}

// By where it is.
fn isBootVolume(t: Target) bool {
    var i: u32 = 0;
    while (sys.driveAt(i)) |d| : (i += 1) {
        if (!d.boot or d.letter == 0) continue;
        const loc = sys.driveLocation(d.letter) catch return false;
        return loc.disk == t.disk and loc.start == t.start;
    }
    return false;
}

fn listPartitions(disk: u32) void {
    var list: [sys.max_partitions]sys.Partition = undefined;
    const n = sys.partitionsOf(disk, &list) orelse {
        zdos.printf("Cannot read disk {d}\n", .{disk});
        return;
    };
    if (n == 1 and list[0].whole_disk) {
        zdos.printf("Disk {d} has no partition table: its only volume is partition 1 (the whole disk)\n", .{disk});
        return;
    }
    if (n == 0) {
        zdos.printf("Disk {d} has a partition table without partitions\n", .{disk});
        return;
    }
    zdos.print("No.   Start sector    Size MB  Type\n");
    for (list[0..n]) |p| {
        zdos.printf("{d:>3} {d:>14} {d:>10}  ", .{ p.number, p.start, p.sectors / 2048 });
        if (p.kind != 0) zdos.printf("MBR {X:0>2}", .{p.kind}) else zdos.print("GPT");
        if (p.esp) zdos.print(" (EFI system)");
        zdos.print("\n");
    }
}

fn findPartition(disk: u32, part_no: u32) ?Target {
    const info = sys.diskInfo(disk) orelse {
        zdos.printf("No disk {d}\n", .{disk});
        return null;
    };
    if (info.sector_size != sector or info.sectors == 0) {
        zdos.printf("Disk {d} has no readable disk or its sectors are not 512 bytes\n", .{disk});
        return null;
    }
    var list: [sys.max_partitions]sys.Partition = undefined;
    const n = sys.partitionsOf(disk, &list) orelse {
        zdos.printf("Cannot read disk {d}'s partition table\n", .{disk});
        return null;
    };
    const p = for (list[0..n]) |p| {
        if (p.number == part_no) break p;
    } else {
        if (n == 1 and list[0].whole_disk) {
            zdos.printf("Disk {d} has no partition table: its only volume is partition 1\n", .{disk});
        } else zdos.printf("Disk {d} has no partition {d}\n", .{ disk, part_no });
        return null;
    };
    if (p.whole_disk) return .{ .disk = disk, .start = 0, .sectors = info.sectors };
    if (p.kind == 0x05 or p.kind == 0x0F) {
        zdos.printf("Partition {d} is an extended partition: use one of the partitions it holds\n", .{part_no});
        return null;
    }
    if (p.sectors == 0 or p.start + p.sectors > info.sectors) {
        zdos.printf("Partition {d} goes past the end of the disk: its entry is damaged\n", .{part_no});
        return null;
    }
    return .{ .disk = disk, .start = p.start, .sectors = p.sectors, .esp = p.esp };
}

// Linux: 83 on MBR, Linux filesystem data on GPT. A failure is only told:
// Linux doesn't need the type.
fn setLinuxType(t: Target) void {
    switch (sys.setPartitionType(t.disk, t.start, 0x83, &sys.gpt_linux)) {
        .changed => zdos.print("Partition type set to Linux.\n"),
        .already, .no_table => {},
        .failed => zdos.print("The partition's type could not be changed (Linux doesn't need it).\n"),
    }
}

const inode_size = 256;
const max_per_group = 65528; // group descriptors count in 16 bits

const Layout = struct {
    bs: u32,
    blocks: u32,
    first_data_block: u32,
    bpg: u32, // blocks per group
    groups: u32,
    ipg: u32, // inodes per group
    itb: u32, // inode table blocks per group
    gdt_blocks: u32,
    lpf_blocks: u32, // lost+found's

    // As mke2fs: one inode per 4 KB below 512 MB, else per 16 KB; a last
    // group too small for its own metadata is left out.
    fn plan(sectors: u64, bs: u32) ?Layout {
        const total64 = sectors * sector / bs;
        if (total64 > std.math.maxInt(u32)) {
            zdos.print("Too many blocks for ext2 (more than 2^32): use larger blocks (-b)\n");
            return null;
        }
        var blocks: u32 = @intCast(total64);
        const fdb: u32 = @intFromBool(bs == 1024);
        if (blocks < 64 or sectors < 2048) {
            zdos.print("Too small for ext2: at least 1 MB and 64 blocks\n");
            return null;
        }
        const bpg: u32 = @min(bs * 8, max_per_group);
        var groups = (blocks - fdb + bpg - 1) / bpg;
        const ratio: u64 = if (sectors * sector < 512 * 1024 * 1024) 4096 else 16384;
        const inodes: u64 = @max(sectors * sector / ratio, 16 * @as(u64, groups));
        const ipb = bs / inode_size;
        const step = @max(8, ipb);
        var ipg: u32 = @intCast((inodes + groups - 1) / groups);
        ipg = std.mem.alignForward(u32, @max(ipg, 16), step);
        ipg = @min(ipg, std.mem.alignBackward(u32, @min(bs * 8, max_per_group), step));
        const itb = ipg / ipb;
        var lay: Layout = .{
            .bs = bs,
            .blocks = blocks,
            .first_data_block = fdb,
            .bpg = bpg,
            .groups = groups,
            .ipg = ipg,
            .itb = itb,
            .gdt_blocks = (groups * 32 + bs - 1) / bs,
            .lpf_blocks = @min(12, @max(1, 16384 / bs)),
        };
        if (groups > 1) {
            const last = groups - 1;
            if (lay.groupBlocks(last) < lay.overhead(last) + 50) {
                groups -= 1;
                blocks = fdb + groups * bpg;
                lay.groups = groups;
                lay.blocks = blocks;
                lay.gdt_blocks = (groups * 32 + bs - 1) / bs;
            }
        }
        if (lay.overhead(0) + 1 + lay.lpf_blocks > lay.groupBlocks(0)) {
            zdos.print("Too small for ext2 with these blocks\n");
            return null;
        }
        return lay;
    }

    fn groupBlocks(l: Layout, g: u32) u32 {
        if (g + 1 < l.groups) return l.bpg;
        return l.blocks - l.first_data_block - g * l.bpg;
    }

    fn hasSuper(g: u32) bool {
        if (g <= 1) return true;
        for ([_]u32{ 3, 5, 7 }) |b| {
            var x: u64 = b;
            while (x < g) x *= b;
            if (x == g) return true;
        }
        return false;
    }

    fn base(l: Layout, g: u32) u32 {
        return l.first_data_block + g * l.bpg;
    }

    // Superblock and descriptors (in some groups), bitmaps, inode table.
    fn overhead(l: Layout, g: u32) u32 {
        return (if (hasSuper(g)) 1 + l.gdt_blocks else 0) + 2 + l.itb;
    }

    fn blockBitmap(l: Layout, g: u32) u32 {
        return l.base(g) + (if (hasSuper(g)) 1 + l.gdt_blocks else 0);
    }

    fn inodeTable(l: Layout, g: u32) u32 {
        return l.blockBitmap(g) + 2;
    }

    // Group 0 also holds the folders.
    fn used(l: Layout, g: u32) u32 {
        return l.overhead(g) + if (g == 0) 1 + l.lpf_blocks else 0;
    }

    fn rootBlock(l: Layout) u32 {
        return l.inodeTable(0) + l.itb;
    }

    fn freeBlocks(l: Layout) u64 {
        var n: u64 = 0;
        for (0..l.groups) |g| n += l.groupBlocks(@intCast(g)) - l.used(@intCast(g));
        return n;
    }
};

const first_ino = 11; // the reserved inodes are 1 to 10; lost+found is 11
const root_ino = 2;
const lpf_ino = 11;

var buf: [65536]u8 align(8) = undefined;
var zeros = [_]u8{0} ** 65536; // in .bss: not in the .APP file

const Writer = struct {
    t: Target,
    bs: u32,
    progress: sys.Progress,
    done: u64 = 0,

    fn put(w: *Writer, rel: u64, data: []const u8) bool {
        sys.writeSectors(w.t.disk, w.t.start + rel, data) catch return false;
        w.done += data.len / sector;
        w.progress.update(w.done);
        return true;
    }

    fn zero(w: *Writer, rel: u64, count: u64) bool {
        var s: u64 = 0;
        while (s < count) {
            const n: usize = @intCast(@min(count - s, zeros.len / sector));
            if (!w.put(rel + s, zeros[0 .. n * sector])) return false;
            s += n;
        }
        return true;
    }

    fn block(w: *Writer, b: u64, data: []const u8) bool {
        return w.put(b * (w.bs / sector), data[0..w.bs]);
    }
};

fn write(t: Target, l: Layout, label: []const u8) bool {
    const bs = l.bs;
    const sectors_per_block = bs / sector;
    const fs_sectors = @as(u64, l.blocks) * sectors_per_block;
    // Old signatures (a FAT boot sector, ZFS labels), as FORMAT clears them:
    const wipe: u64 = @min(fs_sectors, 1024);
    const wipe_end: u64 = if (t.sectors > 2048) 1024 else 0;
    const itables: u64 = @as(u64, l.groups) * l.itb * sectors_per_block;
    var supers: u64 = 0;
    for (0..l.groups) |g| {
        if (Layout.hasSuper(@intCast(g))) supers += 1;
    }
    const meta: u64 = (@as(u64, l.groups) * 2 + supers * (1 + l.gdt_blocks) + 1 + l.lpf_blocks) * sectors_per_block + 2;
    var w = Writer{ .t = t, .bs = bs, .progress = sys.Progress.begin("Writing the file system", wipe + wipe_end + itables + meta) };
    defer w.progress.finish();

    if (!w.zero(0, wipe)) return false;
    if (wipe_end > 0 and !w.zero(t.sectors - wipe_end, wipe_end)) return false;
    for (0..l.groups) |g| {
        if (!w.zero(@as(u64, l.inodeTable(@intCast(g))) * sectors_per_block, @as(u64, l.itb) * sectors_per_block)) return false;
    }

    const now = unixNow();
    var uuid: [16]u8 = undefined;
    randomBytes(&uuid);

    for (0..l.groups) |gi| {
        const g: u32 = @intCast(gi);
        // Used blocks come first; past the group's end set:
        @memset(buf[0..bs], 0);
        setBits(buf[0..bs], 0, l.used(g));
        setBits(buf[0..bs], l.groupBlocks(g), bs * 8);
        if (!w.block(l.blockBitmap(g), &buf)) return false;
        // Inodes 1 to 11 in group 0; past ipg set:
        @memset(buf[0..bs], 0);
        if (g == 0) setBits(buf[0..bs], 0, first_ino);
        setBits(buf[0..bs], l.ipg, bs * 8);
        if (!w.block(l.blockBitmap(g) + 1, &buf)) return false;
        if (Layout.hasSuper(g) and g != 0) {
            if (!writeSuper(&w, l, g, label, &uuid, now)) return false;
            if (!writeDescriptors(&w, l, l.base(g) + 1)) return false;
        }
    }
    if (!writeDescriptors(&w, l, l.base(0) + 1)) return false;

    const root = l.rootBlock();
    @memset(buf[0..bs], 0);
    putEntry(buf[0..bs], 0, root_ino, 12, ".");
    putEntry(buf[0..bs], 12, root_ino, 12, "..");
    putEntry(buf[0..bs], 24, lpf_ino, bs - 24, "lost+found");
    if (!w.block(root, &buf)) return false;
    // Then empty blocks for later entries:
    @memset(buf[0..bs], 0);
    putEntry(buf[0..bs], 0, lpf_ino, 12, ".");
    putEntry(buf[0..bs], 12, root_ino, bs - 12, "..");
    if (!w.block(root + 1, &buf)) return false;
    @memset(buf[0..bs], 0);
    putRecLen(buf[0..bs], 0, bs);
    for (1..l.lpf_blocks) |k| {
        if (!w.block(root + 1 + k, &buf)) return false;
    }

    if (!writeInode(&w, l, root_ino, 0o40755, 3, &.{root}, now)) return false;
    var lpf: [12]u32 = undefined;
    for (0..l.lpf_blocks) |k| lpf[k] = root + 1 + @as(u32, @intCast(k));
    if (!writeInode(&w, l, lpf_ino, 0o40700, 2, lpf[0..l.lpf_blocks], now)) return false;

    // Last: the primary superblock makes it a file system.
    return writeSuper(&w, l, 0, label, &uuid, now);
}

fn setBits(b: []u8, from: u32, to: u32) void {
    var i = from;
    while (i < to) : (i += 1) b[i / 8] |= @as(u8, 1) << @intCast(i % 8);
}

fn wr16(b: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, b[at..][0..2], v, .little);
}

fn wr32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

// rec_len is 16 bits: a whole 64 KB block is stored as 65535.
fn putRecLen(b: []u8, off: usize, len: u32) void {
    wr16(b, off + 4, if (len == 65536) 65535 else @intCast(len));
}

fn putEntry(b: []u8, off: usize, ino: u32, rec_len: u32, name: []const u8) void {
    wr32(b, off, ino);
    putRecLen(b, off, rec_len);
    b[off + 6] = @intCast(name.len);
    b[off + 7] = 2; // a folder (filetype)
    @memcpy(b[off + 8 ..][0..name.len], name);
}

// At byte 1024 in group 0, at the start of the group's
// first block in the others.
fn writeSuper(w: *Writer, l: Layout, g: u32, label: []const u8, uuid: *const [16]u8, now: u32) bool {
    const sb = buf[0..1024];
    @memset(sb, 0);
    var free_blocks = l.freeBlocks();
    if (free_blocks > std.math.maxInt(u32)) free_blocks = std.math.maxInt(u32);
    const inodes = l.ipg * l.groups;
    wr32(sb, 0, inodes);
    wr32(sb, 4, l.blocks);
    wr32(sb, 8, l.blocks / 20); // 5% reserved for root
    wr32(sb, 12, @intCast(free_blocks));
    wr32(sb, 16, inodes - first_ino);
    wr32(sb, 20, l.first_data_block);
    const log: u32 = std.math.log2_int(u32, l.bs) - 10;
    wr32(sb, 24, log);
    wr32(sb, 28, log);
    wr32(sb, 32, l.bpg);
    wr32(sb, 36, l.bpg);
    wr32(sb, 40, l.ipg);
    wr32(sb, 48, now); // s_wtime
    wr16(sb, 54, 0xFFFF); // no mount-count check
    wr16(sb, 56, 0xEF53);
    wr16(sb, 58, 1); // clean
    wr16(sb, 60, 1); // on errors: continue
    wr32(sb, 64, now); // s_lastcheck
    wr32(sb, 76, 1); // dynamic revision
    wr32(sb, 84, first_ino);
    wr16(sb, 88, inode_size);
    wr16(sb, 90, @intCast(g)); // s_block_group_nr
    wr32(sb, 96, 0x0002); // incompat: filetype
    wr32(sb, 100, 0x0003); // ro_compat: sparse_super, large_file
    @memcpy(sb[104..120], uuid);
    @memcpy(sb[120..][0..label.len], label);
    wr32(sb, 264, now); // s_mkfs_time
    if (g == 0) return w.put(2, sb); // bytes 1024-2047
    // A backup: the rest of a larger block zeroed:
    @memset(buf[1024..l.bs], 0);
    return w.block(l.base(g), &buf);
}

// 32 bytes per group.
fn writeDescriptors(w: *Writer, l: Layout, at: u32) bool {
    var g: u32 = 0;
    var k: u32 = 0;
    while (k < l.gdt_blocks) : (k += 1) {
        @memset(buf[0..l.bs], 0);
        var off: usize = 0;
        while (off + 32 <= l.bs and g < l.groups) : ({
            off += 32;
            g += 1;
        }) {
            const d = buf[off..][0..32];
            wr32(d, 0, l.blockBitmap(g));
            wr32(d, 4, l.blockBitmap(g) + 1);
            wr32(d, 8, l.inodeTable(g));
            wr16(d, 12, @intCast(l.groupBlocks(g) - l.used(g)));
            wr16(d, 14, @intCast(l.ipg - if (g == 0) @as(u32, first_ino) else 0));
            wr16(d, 16, if (g == 0) 2 else 0); // root and lost+found
        }
        if (!w.block(at + k, &buf)) return false;
    }
    return true;
}

// Into the zeroed inode table of group 0.
fn writeInode(w: *Writer, l: Layout, ino: u32, mode: u16, links: u16, blocks: []const u32, now: u32) bool {
    const byte = @as(u64, l.inodeTable(0)) * l.bs + @as(u64, ino - 1) * inode_size;
    const s = buf[0..sector];
    @memset(s, 0);
    const i = s[@intCast(byte % sector)..][0..inode_size];
    wr16(i, 0, mode);
    wr32(i, 4, @intCast(blocks.len * l.bs)); // size
    wr32(i, 8, now); // atime
    wr32(i, 12, now); // ctime
    wr32(i, 16, now); // mtime
    wr16(i, 26, links);
    wr32(i, 28, @intCast(blocks.len * (l.bs / sector))); // i_blocks, 512-byte units
    for (blocks, 0..) |b, k| wr32(i, 40 + 4 * k, b);
    wr32(i, 100, randomU32()); // i_generation
    return w.put(byte / sector, s);
}

fn unixNow() u32 {
    const t = zdos.getTime();
    if (t.year < 1970) return 0;
    const y: i64 = @as(i64, t.year) - @intFromBool(t.month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = t.month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + t.day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return @intCast(std.math.clamp(days * 86400 + @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second, 0, std.math.maxInt(u32)));
}

var seed: u64 = 0;

fn randomU32() u32 {
    if (seed == 0) seed = zdos.millis() ^ (@as(u64, unixNow()) << 20) ^ 0x9E3779B97F4A7C15;
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return @truncate(seed);
}

// A version 4 (random) UUID.
fn randomBytes(out: *[16]u8) void {
    for (0..4) |k| wr32(out, k * 4, randomU32());
    out[6] = (out[6] & 0x0F) | 0x40;
    out[8] = (out[8] & 0x3F) | 0x80;
}
