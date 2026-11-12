// Disk images with MBR or GPT and the volumes in their partitions:
// what sfdisk and dd do in build.sh.
const std = @import("std");
const files = @import("files.zig");
const fail = files.fail;

const sector = 512;
// 2048 (1 MiB), as sfdisk writes it, not the minimum 34:
const first_usable = 2048;

pub const Part = struct {
    start: u64, // in sectors
    size: u64,
    image: ?[]const u8 = null, // a volume image written there
    // MBR:
    mbr_type: u8 = 0, // 0x05: extended, holds the next one
    bootable: bool = false,
    logical: bool = false,
    // GPT:
    gpt_type: []const u8 = basic_data,
    name: []const u8 = "",
    attrs: u64 = 0,
};

pub const efi_system = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B";
pub const basic_data = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7";
pub const linux_data = "0FC63DAF-8483-4772-8E79-3D69D8477DE4";

// boot_code: a file whose first 440 bytes go first. One logical
// partition at most: its EBR is the extended partition's first sector.
pub fn mbr(path: []const u8, mib: u64, boot_code: ?[]const u8, parts: []const Part) void {
    const f = newDisk(path, mib);
    defer f.close();
    var table = std.mem.zeroes([512]u8);
    if (boot_code) |code| @memcpy(table[0..440], files.read(code)[0..440]);
    std.mem.writeInt(u32, table[440..444], std.hash.Crc32.hash(path), .little); // disk signature
    var n: usize = 0;
    var extended: ?Part = null;
    for (parts) |p| {
        if (p.logical) {
            const x = extended orelse fail("{s}: a logical partition needs an extended one before it", .{path});
            var ebr = std.mem.zeroes([512]u8);
            mbrEntry(ebr[446..462], 0, p.mbr_type, p.start - x.start, p.size);
            ebr[510] = 0x55;
            ebr[511] = 0xAA;
            f.pwriteAll(&ebr, x.start * sector) catch unreachable;
        } else {
            mbrEntry(table[446 + n * 16 ..][0..16], if (p.bootable) 0x80 else 0, p.mbr_type, p.start, p.size);
            n += 1;
            if (p.mbr_type == 0x05) extended = p;
        }
    }
    table[510] = 0x55;
    table[511] = 0xAA;
    f.pwriteAll(&table, 0) catch unreachable;
    writeVolumes(f, parts);
}

// A protective MBR, the table at the start and its backup at the end.
pub fn gpt(path: []const u8, mib: u64, parts: []const Part) void {
    const f = newDisk(path, mib);
    defer f.close();
    const total = (mib << 20) / sector;
    for (parts) |p| if (p.start < first_usable or p.start + p.size > total - 33) fail("a partition is outside {s}", .{path});

    var pmbr = std.mem.zeroes([512]u8);
    mbrEntry(pmbr[446..462], 0, 0xEE, 1, total - 1);
    pmbr[447..450].* = .{ 0, 2, 0 };
    pmbr[451..454].* = .{ 0xFF, 0xFF, 0xFF };
    pmbr[510] = 0x55;
    pmbr[511] = 0xAA;
    f.pwriteAll(&pmbr, 0) catch unreachable;

    var entries = std.mem.zeroes([128 * 128]u8);
    for (parts, 0..) |p, i| {
        const e = entries[i * 128 ..][0..128];
        e[0..16].* = guid(p.gpt_type);
        e[16..32].* = fixedGuid(files.fmt("{s} {d}", .{ std.fs.path.basename(path), i }));
        std.mem.writeInt(u64, e[32..40], p.start, .little);
        std.mem.writeInt(u64, e[40..48], p.start + p.size - 1, .little);
        std.mem.writeInt(u64, e[48..56], p.attrs, .little);
        for (p.name, 0..) |c, k| std.mem.writeInt(u16, e[56 + k * 2 ..][0..2], c, .little);
    }
    const entries_crc = std.hash.Crc32.hash(&entries);

    // The header, in sector 1 and the backup in the last:
    for ([_]bool{ true, false }) |primary| {
        var h = std.mem.zeroes([512]u8);
        const here: u64 = if (primary) 1 else total - 1;
        const other: u64 = if (primary) total - 1 else 1;
        const table: u64 = if (primary) 2 else total - 33;
        h[0..8].* = "EFI PART".*;
        std.mem.writeInt(u32, h[8..12], 0x00010000, .little);
        std.mem.writeInt(u32, h[12..16], 92, .little);
        std.mem.writeInt(u64, h[24..32], here, .little);
        std.mem.writeInt(u64, h[32..40], other, .little);
        std.mem.writeInt(u64, h[40..48], first_usable, .little);
        std.mem.writeInt(u64, h[48..56], total - 34, .little);
        h[56..72].* = fixedGuid(std.fs.path.basename(path));
        std.mem.writeInt(u64, h[72..80], table, .little);
        std.mem.writeInt(u32, h[80..84], 128, .little);
        std.mem.writeInt(u32, h[84..88], 128, .little);
        std.mem.writeInt(u32, h[88..92], entries_crc, .little);
        std.mem.writeInt(u32, h[16..20], std.hash.Crc32.hash(h[0..92]), .little);
        f.pwriteAll(&entries, table * sector) catch unreachable;
        f.pwriteAll(&h, here * sector) catch unreachable;
    }
    writeVolumes(f, parts);
}

fn newDisk(path: []const u8, mib: u64) std.fs.File {
    const f = std.fs.cwd().createFile(path, .{ .read = true }) catch |err| fail("{s}: {s}", .{ path, @errorName(err) });
    f.setEndPos(mib << 20) catch |err| fail("{s}: {s}", .{ path, @errorName(err) });
    return f;
}

fn writeVolumes(f: std.fs.File, parts: []const Part) void {
    for (parts) |p| if (p.image) |img| {
        const data = files.read(img);
        if (data.len > p.size * sector) fail("{s} doesn't fit its partition", .{img});
        f.pwriteAll(data, p.start * sector) catch |err| fail("writing the disk image: {s}", .{@errorName(err)});
    };
}

fn mbrEntry(entry: *[16]u8, status: u8, kind: u8, start: u64, size: u64) void {
    entry[0] = status;
    entry[1..4].* = chs(start);
    entry[4] = kind;
    entry[5..8].* = chs(start + size - 1);
    std.mem.writeInt(u32, entry[8..12], @intCast(@min(start, 0xFFFF_FFFF)), .little);
    std.mem.writeInt(u32, entry[12..16], @intCast(@min(size, 0xFFFF_FFFF)), .little);
}

// 255 heads and 63 sectors per track.
fn chs(lba: u64) [3]u8 {
    const c = lba / (255 * 63);
    if (c > 1023) return .{ 254, 0xFF, 0xFF };
    const h: u8 = @intCast(lba / 63 % 255);
    const s: u8 = @intCast(lba % 63 + 1);
    return .{ h, s | @as(u8, @intCast((c >> 2) & 0xC0)), @intCast(c & 0xFF) };
}

// The first three fields little-endian.
fn guid(text: []const u8) [16]u8 {
    var hex: [32]u8 = undefined;
    var n: usize = 0;
    for (text) |c| if (c != '-') {
        hex[n] = c;
        n += 1;
    };
    var raw: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&raw, &hex) catch fail("bad GUID {s}", .{text});
    std.mem.reverse(u8, raw[0..4]);
    std.mem.reverse(u8, raw[4..6]);
    std.mem.reverse(u8, raw[6..8]);
    return raw;
}

// The same from build to build: the same disk is the same disk.
fn fixedGuid(name: []const u8) [16]u8 {
    var g: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(name, &g, .{});
    g[7] = (g[7] & 0x0F) | 0x40; // version 4 (stored little-endian)
    g[8] = (g[8] & 0x3F) | 0x80;
    return g;
}
