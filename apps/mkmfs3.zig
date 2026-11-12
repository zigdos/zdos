// MKMFS3: a new, empty Minix V3 file system.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

const sector = 512;
const usage =
    \\Usage: MKMFS3 X: [-b block size] [-i inodes]
    \\  or MKMFS3 <disk> <partition> [-b block size] [-i inodes]
    \\  or MKMFS3 <disk>     lists the disk's partitions
    \\  -b  1024, 2048, or 4096 bytes (default 4096; also 1K, 2K, 4K)
    \\  -i  number of inodes (default based on the filesystem size)
    \\
;

const Target = struct {
    disk: u32,
    start: u64,
    sectors: u64,
    letter: u8 = 0,
    esp: bool = false,
};

const Layout = struct {
    block_size: u32,
    zones: u32,
    inodes: u32,
    imap_blocks: u32,
    zmap_blocks: u32,
    inode_blocks: u32,
    first_zone: u32,

    fn plan(t: Target, block_size: u32, requested_inodes: ?u32) ?Layout {
        const sectors_per_block = block_size / sector;
        const zones64 = t.sectors / sectors_per_block;
        if (zones64 > std.math.maxInt(u32)) {
            zdos.print("This partition is too large for Minix V3's 32-bit zone count.\n");
            return null;
        }
        const zones: u32 = @intCast(zones64);
        if (zones < 8) {
            zdos.print("The partition is too small for a Minix V3 filesystem.\n");
            return null;
        }

        const inodes_per_block = block_size / 64;
        const inodes64: u64 = requested_inodes orelse defaultInodes(zones, block_size, inodes_per_block);
        if (inodes64 == 0 or inodes64 > std.math.maxInt(u32)) {
            zdos.print("The inode count must be between 1 and 4294967295.\n");
            return null;
        }
        const inodes: u32 = @intCast(inodes64);
        const bits_per_block = @as(u64, block_size) * 8;
        const imap_blocks64 = ceilDiv(inodes64 + 1, bits_per_block);
        const zmap_blocks64 = ceilDiv(zones, bits_per_block);
        const inode_blocks64 = ceilDiv(inodes, inodes_per_block);

        // MFS stores bitmap block counts in signed 16-bit fields:
        if (imap_blocks64 == 0 or imap_blocks64 > std.math.maxInt(i16) or
            zmap_blocks64 == 0 or zmap_blocks64 > std.math.maxInt(i16))
        {
            zdos.print("The inode or zone bitmap would exceed Minix V3's limit.\n");
            return null;
        }
        const first_zone64 = @as(u64, 2) + imap_blocks64 + zmap_blocks64 + inode_blocks64;
        if (first_zone64 <= 4 or first_zone64 >= zones) {
            zdos.print("There is not enough room for the filesystem metadata and root directory.\n");
            return null;
        }

        return .{
            .block_size = block_size,
            .zones = zones,
            .inodes = inodes,
            .imap_blocks = @intCast(imap_blocks64),
            .zmap_blocks = @intCast(zmap_blocks64),
            .inode_blocks = @intCast(inode_blocks64),
            .first_zone = @intCast(first_zone64),
        };
    }

    fn inodeStart(l: Layout) u32 {
        return 2 + l.imap_blocks + l.zmap_blocks;
    }
};

fn ceilDiv(n: u64, d: u64) u64 {
    return n / d + @intFromBool(n % d != 0);
}

fn defaultInodes(zones: u32, block_size: u32, inodes_per_block: u32) u64 {
    const kb = @as(u64, zones) * block_size / 1024;
    const divisor: u64 = if (kb >= 1_000_000_000)
        12
    else if (kb >= 100_000_000)
        10
    else if (kb >= 10_000_000)
        8
    else if (kb >= 1_000_000)
        6
    else if (kb >= 100_000)
        4
    else
        2;
    const requested = @max(@as(u64, 1), kb / divisor);
    return ceilDiv(requested, inodes_per_block) * inodes_per_block;
}

pub fn main(args: []const u8) u8 {
    if (std.mem.trim(u8, args, " \t").len > 0 and users.diskToolDenied("MKMFS3")) return 1;
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    var pos: [2][]const u8 = undefined;
    var npos: usize = 0;
    var block_size: u32 = 4096;
    var requested_inodes: ?u32 = null;
    while (words.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, "-b")) {
            const value = words.next() orelse return fail(usage);
            block_size = parseBlockSize(value) orelse return fail("Block size must be 1024, 2048, or 4096 bytes.\n");
        } else if (std.ascii.eqlIgnoreCase(word, "-i")) {
            const value = words.next() orelse return fail(usage);
            requested_inodes = std.fmt.parseInt(u32, value, 10) catch return fail("Invalid inode count.\n");
            if (requested_inodes.? == 0) return fail("The inode count must be greater than zero.\n");
        } else {
            if (npos == pos.len) return fail(usage);
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
    if (isBootVolume(target)) return fail("That is the volume ZDOS was started from: it is not changed.\n");

    const disk = sys.diskInfo(target.disk) orelse {
        zdos.printf("Cannot read disk {d}\n", .{target.disk});
        return 1;
    };
    if (disk.sector_size != sector or disk.read_only) return fail("The target disk is read-only or does not use 512-byte sectors.\n");

    const layout = Layout.plan(target, block_size, requested_inodes) orelse return 1;
    const bytes = @as(u64, layout.zones) * layout.block_size;
    const pointer_count: u64 = layout.block_size / 4;
    const pointer_limit = (7 + pointer_count + pointer_count * pointer_count) * layout.block_size;
    const max_file_size = @min(pointer_limit, 0x7fff_ffff);
    zdos.printf("Make a Minix V3 filesystem on disk {d}, from sector {d}:\n{d} MB, {d} blocks of {d} bytes, {d} inodes, maximum file size {d} bytes.\n", .{
        target.disk,
        target.start,
        bytes / (1024 * 1024),
        layout.zones,
        layout.block_size,
        layout.inodes,
        max_file_size,
    });
    if (target.esp) zdos.print("This is an EFI system partition: its boot files would be erased.\n");
    zdos.print("ALL DATA on it will be lost. Go ahead? (Y/N) ");
    if (!sys.askYes()) {
        zdos.print("Nothing was changed.\n");
        return 1;
    }
    sys.syncDisk(target.disk) catch return fail("Cannot sync the target disk before formatting.\n");
    if (!writeFilesystem(target, layout, @intCast(max_file_size))) {
        zdos.printf("Cannot write disk {d}\n", .{target.disk});
        return 1;
    }

    zdos.print("Done: an empty Minix V3 filesystem.\n");
    setMinixType(target);
    if (target.letter != 0) sys.driveChanged(target.letter) else sys.diskChanged(target.disk);
    if (zdos.onUefi()) zdos.print("If the firmware had mounted it, restart ZDOS before using it.\n");
    return 0;
}

fn parseBlockSize(text: []const u8) ?u32 {
    if (std.ascii.eqlIgnoreCase(text, "1k")) return 1024;
    if (std.ascii.eqlIgnoreCase(text, "2k")) return 2048;
    if (std.ascii.eqlIgnoreCase(text, "4k")) return 4096;
    const value = std.fmt.parseInt(u32, text, 10) catch return null;
    return if (value == 1024 or value == 2048 or value == 4096) value else null;
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
        zdos.printf("Drive {c}: is the drive ZDOS was started from: it is not changed.\n", .{letter});
        return null;
    }
    if (info.floppy) {
        zdos.print("Floppies get FAT: use FORMAT.\n");
        return null;
    }
    const loc = sys.driveLocation(letter) catch {
        zdos.printf("Cannot tell where drive {c}: is on its disk.\n", .{letter});
        return null;
    };
    return .{ .disk = loc.disk, .start = loc.start, .sectors = loc.sectors, .letter = letter, .esp = info.system };
}

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
        zdos.printf("Disk {d} has no partition table: its only volume is partition 1 (the whole disk).\n", .{disk});
        return;
    }
    if (n == 0) {
        zdos.printf("Disk {d} has a partition table without partitions.\n", .{disk});
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
        zdos.printf("Disk {d} has no readable disk or its sectors are not 512 bytes.\n", .{disk});
        return null;
    }
    if (info.read_only) {
        zdos.printf("Disk {d} is read-only.\n", .{disk});
        return null;
    }
    var list: [sys.max_partitions]sys.Partition = undefined;
    const n = sys.partitionsOf(disk, &list) orelse {
        zdos.printf("Cannot read disk {d}'s partition table.\n", .{disk});
        return null;
    };
    const p = for (list[0..n]) |entry| {
        if (entry.number == part_no) break entry;
    } else {
        if (n == 1 and list[0].whole_disk) {
            zdos.printf("Disk {d} has no partition table: its only volume is partition 1.\n", .{disk});
        } else zdos.printf("Disk {d} has no partition {d}.\n", .{ disk, part_no });
        return null;
    };
    if (p.whole_disk) return .{ .disk = disk, .start = 0, .sectors = info.sectors };
    if (p.kind == 0x05 or p.kind == 0x0F) {
        zdos.printf("Partition {d} is an extended partition: use one of the partitions it holds.\n", .{part_no});
        return null;
    }
    if (p.sectors == 0 or p.start > info.sectors or p.sectors > info.sectors - p.start) {
        zdos.printf("Partition {d} goes past the end of the disk: its entry is damaged.\n", .{part_no});
        return null;
    }
    return .{ .disk = disk, .start = p.start, .sectors = p.sectors, .esp = p.esp };
}

fn setMinixType(t: Target) void {
    switch (sys.setPartitionType(t.disk, t.start, 0x81, &sys.gpt_linux)) {
        .changed => zdos.print("Partition type set to Minix.\n"),
        .already, .no_table => {},
        .failed => zdos.print("The partition type could not be changed.\n"),
    }
}

const Writer = struct {
    target: Target,
    block_size: u32,
    progress: sys.Progress,
    total_sectors: u64,
    done_sectors: u64 = 0,

    fn put(w: *Writer, relative_sector: u64, data: []const u8) bool {
        if (data.len == 0 or data.len % sector != 0) return false;
        const count = data.len / sector;
        if (relative_sector > w.target.sectors or count > w.target.sectors - relative_sector) return false;
        sys.writeSectors(w.target.disk, w.target.start + relative_sector, data) catch return false;
        w.done_sectors += count;
        w.progress.update(w.done_sectors);
        return true;
    }

    fn zeroBlocks(w: *Writer, first: u64, count: u64) bool {
        var block_no = first;
        var left = count;
        const max_blocks = zeros.len / w.block_size;
        const sectors_per_block = w.block_size / sector;
        while (left != 0) {
            const take: usize = @intCast(@min(left, max_blocks));
            const bytes = take * w.block_size;
            if (!w.put(block_no * sectors_per_block, zeros[0..bytes])) return false;
            block_no += take;
            left -= take;
        }
        return true;
    }

    fn block(w: *Writer, number: u32, data: []const u8) bool {
        if (data.len != w.block_size) return false;
        return w.put(@as(u64, number) * (w.block_size / sector), data);
    }
};

var buf: [4096]u8 align(8) = undefined;
var zeros = [_]u8{0} ** 65536;

fn writeFilesystem(t: Target, l: Layout, max_file_size: u32) bool {
    const spb = l.block_size / sector;
    const total = (@as(u64, l.first_zone) + l.imap_blocks + l.zmap_blocks + 2) * spb + 2;
    var writer = Writer{
        .target = t,
        .block_size = l.block_size,
        .progress = sys.Progress.begin("Writing Minix V3 filesystem", total),
        .total_sectors = total,
    };
    defer writer.progress.finish();

    if (!writer.zeroBlocks(0, l.first_zone)) return false;

    if (!writeMap(&writer, 2, l.imap_blocks, l.inodes + 1)) return false;
    const zmap_start = 2 + l.imap_blocks;
    const valid_zone_bits = l.zones - l.first_zone + 1;
    if (!writeMap(&writer, zmap_start, l.zmap_blocks, valid_zone_bits)) return false;
    if (!writeRootDirectory(&writer, l)) return false;
    if (!writeRootInode(&writer, l)) return false;

    var sb: [1024]u8 = [_]u8{0} ** 1024;
    wr32(&sb, 0, l.inodes);
    wr16(&sb, 4, 0); // obsolete V1 zone count
    wr16(&sb, 6, @intCast(l.imap_blocks));
    wr16(&sb, 8, @intCast(l.zmap_blocks));
    wr16(&sb, 10, if (l.first_zone <= std.math.maxInt(u16)) @intCast(l.first_zone) else 0);
    wr16(&sb, 12, 0); // zone size equals block size
    wr16(&sb, 14, 1); // clean filesystem
    wr32(&sb, 16, max_file_size);
    wr32(&sb, 20, l.zones);
    wr16(&sb, 24, 0x4D5A);
    wr16(&sb, 26, 0);
    wr16(&sb, 28, @intCast(l.block_size));
    sb[30] = 0; // Minix V3 disk format version
    // At byte 1024 for every block size:
    return writer.put(2, &sb);
}

fn writeMap(w: *Writer, first_block: u32, map_blocks: u32, valid_bits: u32) bool {
    const bits_per_block = w.block_size * 8;
    for (0..map_blocks) |map_index| {
        @memset(buf[0..w.block_size], 0);
        const global_start = @as(u64, map_index) * bits_per_block;
        const unused_start = @max(global_start, valid_bits);
        const local_unused: u32 = if (unused_start > global_start)
            @intCast(unused_start - global_start)
        else
            bits_per_block;
        if (local_unused < bits_per_block) setBits(&buf, local_unused, bits_per_block);
        if (map_index == 0) {
            setBit(&buf, 0); // bit zero is reserved in both maps
            // Inode 1 is the root; zone bit 1 is first_zone:
            setBit(&buf, 1);
        }
        if (!w.block(first_block + @as(u32, @intCast(map_index)), buf[0..w.block_size])) return false;
    }
    return true;
}

fn writeRootDirectory(w: *Writer, l: Layout) bool {
    @memset(buf[0..l.block_size], 0);
    wr32(&buf, 0, 1);
    buf[4] = '.';
    wr32(&buf, 64, 1);
    buf[68] = '.';
    buf[69] = '.';
    return w.block(l.first_zone, buf[0..l.block_size]);
}

fn writeRootInode(w: *Writer, l: Layout) bool {
    @memset(buf[0..l.block_size], 0);
    wr16(&buf, 0, 0o40755);
    wr16(&buf, 2, 2);
    wr16(&buf, 4, 0);
    wr16(&buf, 6, 0);
    wr32(&buf, 8, 128);
    const now = unixNow();
    wr32(&buf, 12, now);
    wr32(&buf, 16, now);
    wr32(&buf, 20, now);
    wr32(&buf, 24, l.first_zone);
    return w.block(l.inodeStart(), buf[0..l.block_size]);
}

fn setBit(b: []u8, bit: u32) void {
    b[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
}

fn setBits(b: []u8, from: u32, to: u32) void {
    var bit = from;
    while (bit < to) : (bit += 1) setBit(b, bit);
}

fn wr16(b: []u8, off: usize, value: u16) void {
    std.mem.writeInt(u16, b[off..][0..2], value, .little);
}

fn wr32(b: []u8, off: usize, value: u32) void {
    std.mem.writeInt(u32, b[off..][0..4], value, .little);
}

fn unixNow() u32 {
    const t = zdos.getTime();
    if (t.year < 1970 or t.month < 1 or t.month > 12) return 0;
    const y: i64 = @as(i64, t.year) - @intFromBool(t.month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = t.month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + t.day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    const seconds = days * 86400 + @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second;
    return @intCast(std.math.clamp(seconds, 0, std.math.maxInt(u32)));
}
