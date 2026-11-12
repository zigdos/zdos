const std = @import("std");

const sector_size: u64 = 512;
const max_bitmap_blocks: u64 = std.math.maxInt(i16);

const Layout = struct {
    block_size: u32,
    zones: u32,
    inodes: u32,
    imap_blocks: u32,
    zmap_blocks: u32,
    inode_blocks: u32,
    first_zone: u32,
};

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);
    if (args.len < 3) return usage();

    const path = args[1];
    const size = std.fmt.parseInt(u64, args[2], 10) catch return usage();
    var block_size: u32 = 4096;
    var requested_inodes: ?u32 = null;
    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-b") or std.mem.eql(u8, args[i], "--block-size")) {
            i += 1;
            if (i == args.len) return usage();
            block_size = parseBlockSize(args[i]) orelse return usage();
        } else if (std.mem.eql(u8, args[i], "-i") or std.mem.eql(u8, args[i], "--inodes")) {
            i += 1;
            if (i == args.len) return usage();
            requested_inodes = std.fmt.parseInt(u32, args[i], 10) catch return usage();
            if (requested_inodes.? == 0) return usage();
        } else return usage();
    }

    const layout = format(path, size, block_size, requested_inodes) catch |err| {
        std.debug.print("cannot format {s}: {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    std.debug.print("Created Minix V3: {s}, {d} bytes, block size {d}, {d} inodes, max file size {d}\n", .{
        path, size, block_size, layout.inodes, maxFileSize(block_size),
    });
}

// Also for tools/build, which imports this file as module "mkmfs3".
pub fn format(path: []const u8, size: u64, block_size: u32, requested_inodes: ?u32) !Layout {
    const layout = try plan(size, block_size, requested_inodes);
    const max_size = maxFileSize(block_size);

    const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
    defer file.close();
    try file.setEndPos(size);

    // A new file is zero-filled: both maps, the root, then the superblock
    // at byte 1024:
    try writeMap(file, 2, layout.imap_blocks, layout.inodes + 1, block_size);
    const zmap_start = 2 + layout.imap_blocks;
    try writeMap(file, zmap_start, layout.zmap_blocks, layout.zones - layout.first_zone + 1, block_size);
    try writeRoot(file, layout);
    try writeSuper(file, layout, max_size);

    return layout;
}

fn usage() noreturn {
    std.debug.print("Usage: mkmfs3 <image> <size-bytes> [-b 1024|2048|4096] [-i inodes]\n", .{});
    std.process.exit(2);
}

fn parseBlockSize(text: []const u8) ?u32 {
    if (std.ascii.eqlIgnoreCase(text, "1k")) return 1024;
    if (std.ascii.eqlIgnoreCase(text, "2k")) return 2048;
    if (std.ascii.eqlIgnoreCase(text, "4k")) return 4096;
    const value = std.fmt.parseInt(u32, text, 10) catch return null;
    return if (value == 1024 or value == 2048 or value == 4096) value else null;
}

fn plan(size: u64, bs: u32, requested: ?u32) !Layout {
    // Like MKMFS3, format all complete blocks; trailing sectors stay unused:
    if (size < bs) return error.NotEnoughSpace;
    const zones64 = size / bs;
    if (zones64 > std.math.maxInt(u32)) return error.TooManyZones;
    const zones: u32 = @intCast(zones64);
    const ipb = bs / 64;
    const bits_per_block = @as(u64, bs) * 8;
    const kb = size / 1024;
    const divisor: u64 = if (kb >= 1_000_000_000) 12 else if (kb >= 100_000_000) 10 else if (kb >= 10_000_000) 8 else if (kb >= 1_000_000) 6 else if (kb >= 100_000) 4 else 2;
    const def = alignUp(@max(@as(u64, 1), kb / divisor), ipb);
    const inode_count = requested orelse @as(u32, @intCast(def));
    const imap64 = ceilDiv(@as(u64, inode_count) + 1, bits_per_block);
    const zmap64 = ceilDiv(zones, bits_per_block);
    const itable64 = ceilDiv(inode_count, ipb);
    if (imap64 == 0 or imap64 > max_bitmap_blocks or zmap64 == 0 or zmap64 > max_bitmap_blocks) return error.BitmapTooLarge;
    const first64 = 2 + imap64 + zmap64 + itable64;
    if (zones < 8 or first64 >= zones) return error.NotEnoughSpace;
    return .{
        .block_size = bs,
        .zones = zones,
        .inodes = inode_count,
        .imap_blocks = @intCast(imap64),
        .zmap_blocks = @intCast(zmap64),
        .inode_blocks = @intCast(itable64),
        .first_zone = @intCast(first64),
    };
}

fn alignUp(value: u64, unit: u32) u64 {
    return (value + unit - 1) / unit * unit;
}

fn ceilDiv(n: u64, d: u64) u64 {
    return n / d + @intFromBool(n % d != 0);
}

fn maxFileSize(bs: u32) u32 {
    const p: u64 = bs / 4;
    return @intCast(@min((7 + p + p * p) * bs, 0x7fff_ffff));
}

fn pwrite(file: std.fs.File, block_no: u32, bs: u32, data: []const u8) !void {
    try file.pwriteAll(data, @as(u64, block_no) * bs);
}

fn writeMap(file: std.fs.File, start: u32, count: u32, valid_bits: u32, bs: u32) !void {
    var block: [4096]u8 = undefined;
    const bits_per_block = bs * 8;
    for (0..count) |idx| {
        @memset(block[0..bs], 0);
        const global_start = @as(u64, idx) * bits_per_block;
        const unused_start = @max(global_start, valid_bits);
        if (unused_start > global_start) {
            var bit: u32 = @intCast(unused_start - global_start);
            while (bit < bits_per_block) : (bit += 1) setBit(&block, bit);
        }
        if (idx == 0) {
            setBit(&block, 0);
            setBit(&block, 1);
        }
        try pwrite(file, start + @as(u32, @intCast(idx)), bs, block[0..bs]);
    }
}

fn setBit(bytes: []u8, bit: u32) void {
    bytes[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
}

fn writeRoot(file: std.fs.File, l: Layout) !void {
    var root_block: [4096]u8 = [_]u8{0} ** 4096;
    put32(&root_block, 0, 1);
    root_block[4] = '.';
    put32(&root_block, 64, 1);
    root_block[68] = '.';
    root_block[69] = '.';
    try pwrite(file, l.first_zone, l.block_size, root_block[0..l.block_size]);

    var inode_block: [4096]u8 = [_]u8{0} ** 4096;
    put16(&inode_block, 0, 0o40755);
    put16(&inode_block, 2, 2);
    put32(&inode_block, 8, 128);
    const now: u32 = @intCast(@min(std.time.timestamp(), std.math.maxInt(u32)));
    put32(&inode_block, 12, now);
    put32(&inode_block, 16, now);
    put32(&inode_block, 20, now);
    put32(&inode_block, 24, l.first_zone);
    const inode_start = 2 + l.imap_blocks + l.zmap_blocks;
    try pwrite(file, inode_start, l.block_size, inode_block[0..l.block_size]);
}

fn writeSuper(file: std.fs.File, l: Layout, max_size: u32) !void {
    var sb: [1024]u8 = [_]u8{0} ** 1024;
    put32(&sb, 0, l.inodes);
    put16(&sb, 6, @intCast(l.imap_blocks));
    put16(&sb, 8, @intCast(l.zmap_blocks));
    put16(&sb, 10, if (l.first_zone <= std.math.maxInt(u16)) @intCast(l.first_zone) else 0);
    put16(&sb, 14, 1);
    put32(&sb, 16, max_size);
    put32(&sb, 20, l.zones);
    put16(&sb, 24, 0x4d5a);
    put16(&sb, 28, @intCast(l.block_size));
    try file.pwriteAll(&sb, 1024);
}

fn put16(bytes: []u8, offset: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[offset..][0..2], value, .little);
}

fn put32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
