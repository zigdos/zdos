// MBR (with logical partitions), GPT, or
// none (a floppy or "superfloppy" stick).
const std = @import("std");

pub const Partition = struct {
    start: u64, // first sector
    sectors: u64,
    active: bool = false, // MBR "bootable" flag
    hidden: bool = false, // asks for no drive letter (recovery, OEM ...)
    system: bool = false, // EFI System Partition
    whole_disk: bool = false, // no partition table: maybe a file system on the whole disk
};

pub const ReadFn = *const fn (ctx: *const anyopaque, lba: u64, buf: *[512]u8) bool;

const max_logical = 64;

const mbr_hidden_fat = [_]u8{ 0x11, 0x14, 0x16, 0x1b, 0x1c, 0x1e };
const mbr_esp = 0xEF;
const mbr_gpt = 0xEE;

fn isExtended(t: u8) bool {
    return t == 0x05 or t == 0x0F or t == 0x85;
}

const gpt_esp = [16]u8{ 0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B };
// Windows' recovery / OEM partitions:
const gpt_hidden: u64 = 1 << 62;
const gpt_no_drive_letter: u64 = 1 << 63;

const Entry = struct { status: u8, kind: u8, start: u32, sectors: u32 };

fn entry(sector: *const [512]u8, i: usize) Entry {
    const e = sector[0x1BE + i * 16 ..][0..16];
    return .{
        .status = e[0],
        .kind = e[4],
        .start = std.mem.readInt(u32, e[8..12], .little),
        .sectors = std.mem.readInt(u32, e[12..16], .little),
    };
}

// Returns how many.
pub fn scan(ctx: *const anyopaque, read: ReadFn, disk_sectors: u64, out: []Partition) usize {
    var sector: [512]u8 = undefined;
    if (!read(ctx, 0, &sector)) return 0;
    // No signature: ext2's sector 0 has none (FAT's boot
    // sector has one; its entries don't make sense, below):
    if (sector[510] != 0x55 or sector[511] != 0xAA) return wholeDisk(disk_sectors, out);

    var gpt = false;
    var valid = true;
    var used: usize = 0;
    for (0..4) |i| {
        const e = entry(&sector, i);
        if (e.kind == 0) continue;
        used += 1;
        if (e.kind == mbr_gpt) gpt = true;
        if ((e.status != 0 and e.status != 0x80) or e.start == 0 or @as(u64, e.start) + e.sectors > disk_sectors) valid = false;
    }
    if (gpt) {
        const n = scanGpt(ctx, read, disk_sectors, out);
        if (n > 0) return n;
    }
    if (used == 0 or !valid) return wholeDisk(disk_sectors, out);

    var n: usize = 0;
    for (0..4) |i| {
        const e = entry(&sector, i);
        if (e.kind == 0 or e.kind == mbr_gpt) continue;
        if (isExtended(e.kind)) {
            n += scanLogical(ctx, read, e.start, disk_sectors, out[n..]);
            continue;
        }
        if (n >= out.len) break;
        out[n] = .{
            .start = e.start,
            .sectors = e.sectors,
            .active = e.status == 0x80,
            .hidden = std.mem.indexOfScalar(u8, &mbr_hidden_fat, e.kind) != null,
            .system = e.kind == mbr_esp,
        };
        n += 1;
    }
    return n;
}

// Maybe a file system on the whole disk.
fn wholeDisk(disk_sectors: u64, out: []Partition) usize {
    if (out.len == 0 or disk_sectors == 0) return 0;
    out[0] = .{ .start = 0, .sectors = disk_sectors, .whole_disk = true };
    return 1;
}

// A chain of EBRs, each with one partition (relative to itself)
// and the next record (relative to the extended partition).
fn scanLogical(ctx: *const anyopaque, read: ReadFn, ext_start: u64, disk_sectors: u64, out: []Partition) usize {
    var sector: [512]u8 = undefined;
    var n: usize = 0;
    var ebr = ext_start;
    for (0..max_logical) |_| {
        if (ebr >= disk_sectors or !read(ctx, ebr, &sector)) break;
        if (sector[510] != 0x55 or sector[511] != 0xAA) break;
        const part = entry(&sector, 0);
        if (part.kind != 0 and !isExtended(part.kind) and n < out.len) {
            const start = ebr + part.start;
            if (start + part.sectors <= disk_sectors) {
                out[n] = .{
                    .start = start,
                    .sectors = part.sectors,
                    .hidden = std.mem.indexOfScalar(u8, &mbr_hidden_fat, part.kind) != null,
                };
                n += 1;
            }
        }
        const next = entry(&sector, 1);
        if (!isExtended(next.kind) or next.start == 0) break;
        ebr = ext_start + next.start;
    }
    return n;
}

fn scanGpt(ctx: *const anyopaque, read: ReadFn, disk_sectors: u64, out: []Partition) usize {
    var header: [512]u8 = undefined;
    if (!read(ctx, 1, &header) or !std.mem.eql(u8, header[0..8], "EFI PART")) return 0;
    const entries_lba = std.mem.readInt(u64, header[72..80], .little);
    const count = std.mem.readInt(u32, header[80..84], .little);
    const entry_size = std.mem.readInt(u32, header[84..88], .little);
    if (entry_size < 128 or entry_size > 512 or 512 % entry_size != 0) return 0;

    var sector: [512]u8 = undefined;
    var loaded: u64 = std.math.maxInt(u64);
    var n: usize = 0;
    for (0..@min(count, 256)) |i| {
        const byte = @as(u64, i) * entry_size;
        const lba = entries_lba + byte / 512;
        if (lba != loaded) {
            if (!read(ctx, lba, &sector)) break;
            loaded = lba;
        }
        const e = sector[@intCast(byte % 512)..][0..128];
        if (std.mem.allEqual(u8, e[0..16], 0)) continue; // unused entry
        const first = std.mem.readInt(u64, e[32..40], .little);
        const last = std.mem.readInt(u64, e[40..48], .little);
        const attributes = std.mem.readInt(u64, e[48..56], .little);
        if (last < first or last >= disk_sectors) continue;
        if (n >= out.len) break;
        out[n] = .{
            .start = first,
            .sectors = last - first + 1,
            .hidden = attributes & (gpt_hidden | gpt_no_drive_letter) != 0,
            .system = std.mem.eql(u8, e[0..16], &gpt_esp),
        };
        n += 1;
    }
    return n;
}
