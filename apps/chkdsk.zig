// CHKDSK: checks a FAT volume through raw sectors; -F repairs it.
// Limits: 512-byte sectors; by disk and partition MBR only (by drive
// letter GPT too); long names are not checked.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");
const users = @import("zdos/users.zig");
const fsck = @import("fsck/common.zig");

comptime {
    _ = zdos;
}

const sector = 512;

const Kind = enum { fat12, fat16, fat32 };

// Sector numbers are relative to the volume's first sector.
const Volume = struct {
    disk: u32,
    letter: u8, // 0: by disk and partition
    start: u64, // absolute sector of the volume's boot sector
    kind: Kind,
    spc: u32, // sectors per cluster
    reserved: u32,
    fats: u32,
    fat_sectors: u32,
    root_sectors: u32, // the fixed root directory (FAT12/16); 0 on FAT32
    root_cluster: u32, // FAT32 only
    data_start: u32, // sector of cluster 2
    clusters: u32, // valid cluster numbers are 2 .. clusters + 1
    fsinfo: u32, // FAT32's FSInfo sector, 0 if none
};

const Loc = struct { lba: u64, off: usize };

const End = enum { eoc, broken, outside, crossed };

// What following a chain found: how many clusters it had, the last one, how
// it ended, and the cluster where it ended (or was cross-linked)
const Walk = struct { count: u32, last: u32, end: End, at: u32 };

var vol: Volume = undefined;
var owned: []u8 = undefined; // bit per cluster: a file or folder uses it
var linked: []u8 = undefined; // bit per cluster: a FAT entry points to it
var fixing = false; // the repair pass: fixes are made and reported as fixed
var problems: u32 = 0;
var fixes: u32 = 0;
var failures: u32 = 0; // problems the repair couldn't fix
var files: u32 = 0;
var folders: u32 = 0;
var free_clusters: u32 = 0;
var bad_clusters: u32 = 0;
var fat_cache: [2][sector]u8 = undefined;
var fat_cache_lba: [2]?u64 = .{ null, null };
var alloc_hint: u32 = 2;
var found_first: ?u32 = null; // the FOUND folder's first cluster, once it exists
var found_label: [9]u8 = "FOUND.000".*; // its name
var found_failed = false; // it couldn't be made (reported once)
var chk_count: u32 = 0;
// The long-name pieces since the last short entry: a run with no short entry
// after it is an orphan. 20 pieces cover the longest name (255 characters).
const max_lfn = 20;
var lfn_locs: [max_lfn]Loc = undefined;
var lfn_count: u32 = 0;
// Folders copied for folder cross-links (repair): FOUND.nnn\DIRi. A copy can
// hold folders that are cross-linked again, so their number is limited.
const max_copies = 64;
var dir_count: u32 = 0;

const Folder = struct {
    first: ?u32, // its first cluster; null: the fixed root (FAT12/16)
    path: []const u8, // "\" or "\A\B\"
    entry: ?Loc, // its entry in the folder that holds it; null: the root or a copy
    root: bool,
    parent: ?u32, // the folder that holds it; null: the root
};

// What the repair pass found, to fix once the scan is complete
const FixKind = enum { empty_file, bad_first, chain_end, size_short, chain_long, cross, folder_cross, orphan_lfn };
const Fix = struct {
    kind: FixKind,
    path: []const u8,
    loc: Loc = .{ .lba = 0, .off = 0 }, // the entry
    first: u32 = 0,
    size: u32 = 0, // a file's size; orphan_lfn: the number of pieces
    r: Walk = .{ .count = 0, .last = 0, .end = .eoc, .at = 0 },
    parent: u32 = 0, // folder_cross: '..' of the empty folder left in its place
    lfn: []const Loc = &.{}, // orphan_lfn: the pieces
};

// Freed when the next pass starts:
var arena: std.heap.ArenaAllocator = undefined;
var arena_live = false;
var pending: std.ArrayListUnmanaged(Folder) = .{}; // folders to scan
var fix_list: std.ArrayListUnmanaged(Fix) = .{};
var copies: std.ArrayListUnmanaged(Folder) = .{}; // made by fixes, scanned next
var incomplete = false; // memory ran out: some folders weren't scanned

pub fn main(args: []const u8) u8 {
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    const usage = "Usage: CHKDSK X: [-F|-A] or CHKDSK [disk [partition] [-F|-A]]\n";
    const first = words.next() orelse {
        listDisks();
        zdos.print(usage);
        return 1;
    };
    if (users.diskToolDenied("CHKDSK")) return 1;
    // CHKDSK X: through the drive (GPT disks too):
    if (driveLetter(first)) |letter| {
        var want_fix_letter = false;
        while (words.next()) |word| {
            if (std.ascii.eqlIgnoreCase(word, "-A")) {
                auto = true;
            } else if (!std.ascii.eqlIgnoreCase(word, "-F")) {
                zdos.print(usage);
                return 1;
            }
            want_fix_letter = true;
        }
        vol = volumeByLetter(letter) orelse return 1;
        return check(want_fix_letter, 0, 0);
    }
    const disk = std.fmt.parseInt(u32, first, 10) catch {
        zdos.print(usage);
        return 1;
    };
    var part: ?u32 = null;
    var want_fix = false;
    while (words.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, "-F")) {
            want_fix = true;
        } else if (std.ascii.eqlIgnoreCase(word, "-A")) {
            want_fix = true;
            auto = true;
        } else {
            part = std.fmt.parseInt(u32, word, 10) catch {
                zdos.print(usage);
                return 1;
            };
        }
    }
    const p = part orelse {
        if (want_fix) {
            zdos.print(usage);
            return 1;
        }
        listPartitions(disk);
        return 0;
    };
    if (p == 0) {
        zdos.print(usage);
        return 1;
    }
    vol = findVolume(disk, p) orelse return 1;
    return check(want_fix, disk, p);
}

// -A: fix without questions, and restart after a repair
var auto = false;

fn driveLetter(word: []const u8) ?u8 {
    if (word.len == 2 and word[1] == ':' and std.ascii.isAlphabetic(word[0])) return std.ascii.toUpper(word[0]);
    if (word.len == 1 and std.ascii.isAlphabetic(word[0])) return std.ascii.toUpper(word[0]);
    return null;
}

// disk and p name the volume in the messages (letter 0).
fn check(want_fix: bool, disk: u32, p: u32) u8 {
    const map_bytes = (vol.clusters + 7) / 8;
    owned = zdos.allocator.alloc(u8, map_bytes) catch {
        zdos.print("Out of memory\n");
        return 1;
    };
    defer zdos.allocator.free(owned);
    linked = zdos.allocator.alloc(u8, map_bytes) catch {
        zdos.print("Out of memory\n");
        return 1;
    };
    defer zdos.allocator.free(linked);
    defer if (arena_live) arena.deinit();

    if (vol.letter != 0) {
        zdos.printf("Checking the {s} volume of drive {c}:\n{d} bytes per sector, {d} sectors per cluster, {d} clusters\n", .{ kindName(), vol.letter, sector, vol.spc, vol.clusters });
    } else {
        zdos.printf("Checking the {s} volume on disk {d}:\n{d} bytes per sector, {d} sectors per cluster, {d} clusters\n", .{ kindName(), vol.disk, sector, vol.spc, vol.clusters });
    }
    analyse();
    if (problems == 0) return 0;
    if (!want_fix) {
        if (vol.letter != 0) {
            zdos.printf("Run CHKDSK {c}: -F to fix {d} problems. Nothing was changed.\n", .{ vol.letter, problems });
        } else {
            zdos.printf("Run CHKDSK {d} {d} -F to fix {d} problems. Nothing was changed.\n", .{ disk, p, problems });
        }
        return 1;
    }
    if (auto) {
        zdos.print("Fixing them (-A).\n");
    } else {
        if (vol.letter != 0) {
            zdos.printf("Fix these problems on drive {c}: (Y/N) ", .{vol.letter});
        } else {
            zdos.printf("Fix these problems on disk {d}, partition {d}? (Y/N) ", .{ disk, p });
        }
        if (!sys.askYes()) {
            zdos.print("Nothing was changed.\n");
            return 1;
        }
    }
    if (vol.letter != 0) {
        sys.syncDrive(vol.letter) catch {
            zdos.print("Cannot sync the volume before repair.\n");
            return 1;
        };
    } else {
        sys.syncDisk(disk) catch {
            zdos.print("Cannot sync the disk before repair.\n");
            return 1;
        };
    }
    const repaired = repair();
    const made = fixes;
    if (made > 0) {
        if (vol.letter != 0) sys.driveChanged(vol.letter) else sys.diskChanged(disk);
    }
    zdos.print("Checking the disk again:\n");
    analyse();
    const clean = repaired and problems == 0;
    if (made > 0) {
        if (auto) autoRestart(clean) else askRestart();
    }
    return if (clean) 0 else 1;
}

// -A, as CHKMFS's (fsck/common.zig)
fn autoRestart(clean: bool) void {
    if (!fsck.hasLetter(vol.letter, vol.disk, vol.start)) return zdos.print("It has no drive letter: no restart needed.\n");
    if (!clean) return zdos.print("Problems are left: no restart. Restart before using the disk again.\n");
    fsck.restartCountdown();
}

// A repair changes the disk under the running system: offer a
// restart where programs may have files open (a drive letter)
fn askRestart() void {
    if (!fsck.hasLetter(vol.letter, vol.disk, vol.start)) return zdos.print("It has no drive letter: no restart needed.\n");
    zdos.print("Restart the computer now, so the repaired disk is read again? (Y/N) ");
    if (sys.askYes()) {
        sys.restart();
    }
    zdos.print("Restart the computer before using the disk again.\n");
}

fn listDisks() void {
    var i: u32 = 0;
    while (i < sys.diskCount()) : (i += 1) {
        const d = sys.diskInfo(i) orelse continue;
        zdos.printf("Disk {d}: {d} sectors of {d} bytes{s}\n", .{ i, d.sectors, d.sector_size, if (d.removable) ", removable" else "" });
    }
}

// Numbered as CHKDSK <disk> <partition>: MBR entries then logical
// partitions, or GPT entry slots.
fn listPartitions(disk: u32) void {
    var parts: [sys.max_partitions]sys.Partition = undefined;
    const n = sys.partitionsOf(disk, &parts) orelse {
        zdos.printf("Cannot read disk {d}'s partition table\n", .{disk});
        return;
    };
    if (n == 0) {
        zdos.printf("Disk {d} has no partitions\n", .{disk});
        return;
    }
    for (parts[0..n]) |p| {
        if (p.kind == 0x05 or p.kind == 0x0F) {
            zdos.printf("Partition {d}: extended partition (its logical partitions follow it)\n", .{p.number});
            continue;
        }
        // GPT types don't say if it is FAT:
        var psec: [sector]u8 = undefined;
        const fat = if (sys.readSectors(disk, p.start, &psec)) parseBpb(disk, p.start, &psec) != null else |_| false;
        if (p.whole_disk) {
            zdos.printf("Disk {d} has no partition table: partition 1 is the whole disk, ", .{disk});
        } else if (p.kind != 0) {
            zdos.printf("Partition {d}: type 0x{x:0>2}, ", .{ p.number, p.kind });
        } else zdos.printf("Partition {d}: GPT{s}, ", .{ p.number, if (p.esp) " EFI system" else "" });
        zdos.printf("start sector {d}, {d} sectors{s}\n", .{ p.start, p.sectors, if (fat) ", FAT" else ", not FAT" });
    }
}

// In the repair pass it could not be fixed.
fn report(comptime fmt: []const u8, args: anytype) void {
    if (fixing) {
        failures += 1;
    } else {
        problems += 1;
    }
    zdos.printf("  " ++ fmt ++ "\n", args);
}

fn fixed(comptime fmt: []const u8, args: anytype) void {
    fixes += 1;
    zdos.printf("  fixed: " ++ fmt ++ "\n", args);
}

fn rd16(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn rd32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

// The disk itself if it has a boot sector and no partition table:
fn findVolume(disk: u32, part: u32) ?Volume {
    var parts: [sys.max_partitions]sys.Partition = undefined;
    const n = sys.partitionsOf(disk, &parts) orelse {
        zdos.printf("Cannot read disk {d}'s partition table\n", .{disk});
        return null;
    };
    const p = for (parts[0..n]) |p| {
        if (p.number == part) break p;
    } else {
        zdos.printf("Disk {d} has no partition {d}\n", .{ disk, part });
        return null;
    };
    if (p.kind == 0x05 or p.kind == 0x0F) {
        zdos.printf("Partition {d} is an extended partition: check one of the partitions it holds\n", .{part});
        return null;
    }
    var psec: [sector]u8 = undefined;
    sys.readSectors(disk, p.start, &psec) catch {
        zdos.printf("Cannot read partition {d}\n", .{part});
        return null;
    };
    if (parseBpb(disk, p.start, &psec)) |v| return v;
    zdos.printf("Partition {d} is not a FAT volume\n", .{part});
    return null;
}

// As the FAT driver: the FAT type comes from the number of clusters.
fn parseBpb(disk: u32, start: u64, b: []const u8) ?Volume {
    if (b[510] != 0x55 or b[511] != 0xAA) return null;
    if (rd16(b, 11) != sector) return null;
    const spc: u32 = b[13];
    if (spc == 0 or spc & (spc - 1) != 0) return null;
    const reserved = rd16(b, 14);
    const fats: u32 = b[16];
    if (reserved == 0 or fats == 0 or fats > 2) return null;
    const root_entries = rd16(b, 17);
    var total = rd16(b, 19);
    if (total == 0) total = rd32(b, 32);
    var fat_sectors = rd16(b, 22);
    if (fat_sectors == 0) fat_sectors = rd32(b, 36);
    if (fat_sectors == 0) return null;
    const root_sectors = (root_entries * 32 + sector - 1) / sector;
    const data_start = reserved + fats * fat_sectors + root_sectors;
    if (total <= data_start) return null;
    const clusters = (total - data_start) / spc;
    const kind: Kind = if (clusters < 4085) .fat12 else if (clusters < 65525) .fat16 else .fat32;
    const fat32 = kind == .fat32;
    return .{
        .disk = disk,
        .letter = 0,
        .start = start,
        .kind = kind,
        .spc = spc,
        .reserved = reserved,
        .fats = fats,
        .fat_sectors = fat_sectors,
        .root_sectors = if (fat32) 0 else root_sectors,
        .root_cluster = if (fat32) rd32(b, 44) else 0,
        .data_start = data_start,
        .clusters = clusters,
        // FSInfo is one of the reserved sectors (0xFFFF and 0: none)
        .fsinfo = if (fat32 and rd16(b, 48) < reserved) rd16(b, 48) else 0,
    };
}

fn kindName() []const u8 {
    return switch (vol.kind) {
        .fat12 => "FAT12",
        .fat16 => "FAT16",
        .fat32 => "FAT32",
    };
}

fn clusterBytes() u64 {
    return @as(u64, vol.spc) * sector;
}

// Counted from the volume's first sector, through its drive letter
// (no partition table needed) or its disk and partition.
fn readSector(lba: u64, buf: []u8) bool {
    if (vol.letter != 0) {
        sys.driveRead(vol.letter, lba, buf) catch return false;
        return true;
    }
    sys.readSectors(vol.disk, vol.start + lba, buf) catch return false;
    return true;
}

fn writeSec(lba: u64, data: []const u8) bool {
    if (vol.letter != 0) {
        sys.driveWrite(vol.letter, lba, data) catch return false;
        return true;
    }
    sys.writeSectors(vol.disk, vol.start + lba, data) catch return false;
    return true;
}

fn volumeByLetter(letter: u8) ?Volume {
    _ = zdos.driveInfo(letter) catch {
        zdos.printf("No drive {c}:\n", .{letter});
        return null;
    };
    var sec: [sector]u8 = undefined;
    sys.driveRead(letter, 0, &sec) catch |err| {
        zdos.printf("Cannot read drive {c}: {s}\n", .{ letter, zdos.message(err) });
        return null;
    };
    var v = parseBpb(0, 0, &sec) orelse {
        zdos.printf("Drive {c}: is not a FAT volume\n", .{letter});
        return null;
    };
    v.letter = letter;
    return v;
}

fn clusterLba(c: u32) u64 {
    return vol.data_start + (@as(u64, c) - 2) * vol.spc;
}

fn validCluster(c: u32) bool {
    return c >= 2 and c < vol.clusters + 2;
}

// End-of-chain marks start here; bad-cluster marks are the value just below
fn eocLimit() u32 {
    return switch (vol.kind) {
        .fat12 => 0xFF8,
        .fat16 => 0xFFF8,
        .fat32 => 0x0FFF_FFF8,
    };
}

fn isEoc(v: u32) bool {
    return v >= eocLimit();
}

fn isBad(v: u32) bool {
    return v == eocLimit() - 1;
}

fn eocValue() u32 {
    return switch (vol.kind) {
        .fat12 => 0xFFF,
        .fat16 => 0xFFFF,
        .fat32 => 0x0FFF_FFFF,
    };
}

fn bitGet(map: []const u8, i: u32) bool {
    const bit: u8 = @as(u8, 1) << @as(u3, @intCast(i % 8));
    return map[i / 8] & bit != 0;
}

fn bitSet(map: []u8, i: u32) void {
    const bit: u8 = @as(u8, 1) << @as(u3, @intCast(i % 8));
    map[i / 8] |= bit;
}

fn bitClr(map: []u8, i: u32) void {
    const bit: u8 = @as(u8, 1) << @as(u3, @intCast(i % 8));
    map[i / 8] &= ~bit;
}

fn fatOffset(c: u32) u64 {
    return switch (vol.kind) {
        .fat12 => @as(u64, c + c / 2),
        .fat16 => @as(u64, c) * 2,
        .fat32 => @as(u64, c) * 4,
    };
}

// Through a one-sector cache:
fn fatBytes(copy: u32, off: u64, out: []u8) bool {
    for (out, 0..) |*b, i| {
        const pos = off + i;
        const lba: u64 = @as(u64, vol.reserved) + @as(u64, copy) * @as(u64, vol.fat_sectors) + pos / sector;
        if (fat_cache_lba[copy] == null or fat_cache_lba[copy].? != lba) {
            if (!readSector(lba, &fat_cache[copy])) return false;
            fat_cache_lba[copy] = lba;
        }
        b.* = fat_cache[copy][@intCast(pos % sector)];
    }
    return true;
}

fn fatEntry(copy: u32, c: u32) ?u32 {
    var b: [4]u8 = undefined;
    switch (vol.kind) {
        .fat12 => {
            if (!fatBytes(copy, fatOffset(c), b[0..2])) return null;
            const v: u32 = @as(u32, b[0]) | (@as(u32, b[1]) << 8);
            return if (c & 1 == 1) v >> 4 else v & 0xFFF;
        },
        .fat16 => {
            if (!fatBytes(copy, fatOffset(c), b[0..2])) return null;
            return @as(u32, b[0]) | (@as(u32, b[1]) << 8);
        },
        .fat32 => {
            if (!fatBytes(copy, fatOffset(c), b[0..4])) return null;
            return std.mem.readInt(u32, &b, .little) & 0x0FFF_FFFF;
        },
    }
}

// One sector read and write per byte:
fn patchFat(copy: u32, off: u64, bytes: []const u8) bool {
    for (bytes, 0..) |byte, i| {
        const pos = off + i;
        const lba: u64 = @as(u64, vol.reserved) + @as(u64, copy) * @as(u64, vol.fat_sectors) + pos / sector;
        var buf: [sector]u8 = undefined;
        if (!readSector(lba, &buf)) return false;
        buf[@intCast(pos % sector)] = byte;
        if (!writeSec(lba, &buf)) return false;
    }
    fat_cache_lba = .{ null, null };
    return true;
}

// In every FAT copy, keeping the bits FAT12 and FAT32 don't own.
fn setFat(c: u32, value: u32) bool {
    // Pointed to now: not a cluster allocCluster may take (a bit left from an
    // entry that pointed to it before only keeps a free cluster unused)
    if (validCluster(value)) bitSet(linked, value - 2);
    const off = fatOffset(c);
    var copy: u32 = 0;
    while (copy < vol.fats) : (copy += 1) {
        var raw: [4]u8 = undefined;
        switch (vol.kind) {
            .fat12 => {
                if (!fatBytes(copy, off, raw[0..2])) return false;
                const old = @as(u32, raw[0]) | (@as(u32, raw[1]) << 8);
                const new: u32 = if (c & 1 == 1) (old & 0x000F) | ((value & 0xFFF) << 4) else (old & 0xF000) | (value & 0xFFF);
                raw[0] = @truncate(new);
                raw[1] = @truncate(new >> 8);
                if (!patchFat(copy, off, raw[0..2])) return false;
            },
            .fat16 => {
                raw[0] = @truncate(value);
                raw[1] = @truncate(value >> 8);
                if (!patchFat(copy, off, raw[0..2])) return false;
            },
            .fat32 => {
                if (!fatBytes(copy, off, raw[0..4])) return false;
                const old = std.mem.readInt(u32, &raw, .little);
                std.mem.writeInt(u32, &raw, (old & 0xF000_0000) | (value & 0x0FFF_FFFF), .little);
                if (!patchFat(copy, off, raw[0..4])) return false;
            },
        }
    }
    return true;
}

// Takes a free cluster for a new chain (repair, after the scan): entry 0 and
// nothing points to it (a chain's last cluster can have 0 too and hold data).
fn allocCluster() ?u32 {
    var c = alloc_hint;
    var tries: u32 = 0;
    while (tries < vol.clusters) : (tries += 1) {
        if (!validCluster(c)) c = 2;
        const v = fatEntry(0, c) orelse return null;
        if (v == 0 and !bitGet(owned, c - 2) and !bitGet(linked, c - 2)) {
            if (!setFat(c, eocValue())) return null;
            // In use from now on, so it isn't taken for a lost chain:
            bitSet(owned, c - 2);
            alloc_hint = c + 1;
            return c;
        }
        c += 1;
    }
    return null;
}

fn copyCluster(src: u32, dst: u32) bool {
    var buf: [sector]u8 = undefined;
    var s: u64 = 0;
    while (s < vol.spc) : (s += 1) {
        if (!readSector(clusterLba(src) + s, &buf)) return false;
        if (!writeSec(clusterLba(dst) + s, &buf)) return false;
    }
    return true;
}

fn zeroCluster(c: u32) bool {
    const zeros = [_]u8{0} ** sector;
    var s: u64 = 0;
    while (s < vol.spc) : (s += 1) {
        if (!writeSec(clusterLba(c) + s, &zeros)) return false;
    }
    return true;
}

// Pass 1: the two FAT copies must match.
fn compareCopies() bool {
    if (vol.fats < 2) return true;
    var progress = sys.Progress.begin("Comparing the FAT copies", vol.clusters + 2);
    var differ: u32 = 0;
    var first_differ: u32 = 0;
    var c: u32 = 0;
    var read_error = false;
    while (c < vol.clusters + 2) : (c += 1) {
        const a = fatEntry(0, c) orelse {
            read_error = true;
            break;
        };
        const b = fatEntry(1, c) orelse {
            read_error = true;
            break;
        };
        if (a != b) {
            if (differ == 0) first_differ = c;
            differ += 1;
        }
        progress.update(c + 1);
    }
    progress.finish();
    if (read_error) {
        report("cannot read the FAT at entry {d}", .{c});
        return false;
    }
    if (differ > 0) {
        if (fixing) {
            fixed("copied FAT 1 over FAT 2 ({d} entries differed, first at {d})", .{ differ, first_differ });
        } else {
            report("the two FAT copies differ in {d} entries (first at {d})", .{ differ, first_differ });
        }
    }
    return differ == 0;
}

fn copyFat() bool {
    var buf: [sector]u8 = undefined;
    var s: u32 = 0;
    while (s < vol.fat_sectors) : (s += 1) {
        const from = vol.reserved + s;
        const to = vol.reserved + vol.fat_sectors + s;
        if (!readSector(from, &buf)) return false;
        if (!writeSec(to, &buf)) return false;
    }
    fat_cache_lba = .{ null, null };
    return true;
}

// Pass 2: counts free clusters, marks the clusters something points to,
// and finds entries that point outside the volume.
fn countEntries() void {
    var progress = sys.Progress.begin("Reading the FAT", vol.clusters);
    var outside: u32 = 0;
    var first_outside: u32 = 0;
    var c: u32 = 2;
    while (c < vol.clusters + 2) : (c += 1) {
        const v = fatEntry(0, c) orelse break;
        if (v == 0) {
            free_clusters += 1;
        } else if (isBad(v)) {
            bad_clusters += 1;
        } else if (isEoc(v)) {
            // End of a chain:
        } else if (!validCluster(v)) {
            if (outside == 0) first_outside = c;
            outside += 1;
        } else {
            bitSet(linked, v - 2);
        }
        progress.update(c - 1);
    }
    progress.finish();
    if (!fixing and outside > 0) {
        report("{d} FAT entries point outside the volume (first: cluster {d})", .{ outside, first_outside });
    }
}

// False without FSInfo's signatures: then the sector is something else.
fn readFsInfo(sec: *[sector]u8) bool {
    if (vol.kind != .fat32 or vol.fsinfo == 0) return false;
    if (!readSector(vol.fsinfo, sec)) {
        report("cannot read FSInfo", .{});
        return false;
    }
    return rd32(sec, 0) == 0x4161_5252 and rd32(sec, 484) == 0x6141_7272 and rd32(sec, 508) == 0xAA55_0000;
}

fn checkFsInfo() void {
    var sec: [sector]u8 = undefined;
    if (!readFsInfo(&sec)) return;
    const counted = std.mem.readInt(u32, sec[488..492], .little);
    if (counted != 0xFFFF_FFFF and counted != free_clusters) {
        report("FSInfo says {d} free clusters, the FAT has {d}", .{ counted, free_clusters });
    }
}

// Marks a file's clusters as used, until the end mark (eoc), a cluster
// in use (crossed), outside the volume (outside), or a free, bad or
// unreadable entry (broken). at: that cluster.
fn walk(first: u32) Walk {
    var c = first;
    var n: u32 = 0;
    var last: u32 = 0;
    while (true) {
        if (!validCluster(c)) return .{ .count = n, .last = last, .end = .outside, .at = c };
        if (bitGet(owned, c - 2)) return .{ .count = n, .last = last, .end = .crossed, .at = c };
        const next = fatEntry(0, c) orelse return .{ .count = n, .last = last, .end = .broken, .at = c };
        if (isBad(next)) return .{ .count = n, .last = last, .end = .broken, .at = c };
        bitSet(owned, c - 2);
        n += 1;
        last = c;
        if (isEoc(next)) return .{ .count = n, .last = last, .end = .eoc, .at = c };
        if (next == 0) return .{ .count = n, .last = last, .end = .broken, .at = c };
        c = next;
    }
}

fn patchEntry(loc: Loc, at: usize, bytes: []const u8) bool {
    var buf: [sector]u8 = undefined;
    if (!readSector(loc.lba, &buf)) return false;
    @memcpy(buf[loc.off + at ..][0..bytes.len], bytes);
    return writeSec(loc.lba, &buf);
}

fn setFirst(loc: Loc, first: u32) bool {
    var lo: [2]u8 = undefined;
    std.mem.writeInt(u16, &lo, @truncate(first), .little);
    if (!patchEntry(loc, 26, &lo)) return false;
    if (vol.kind != .fat32) return true;
    std.mem.writeInt(u16, &lo, @truncate(first >> 16), .little);
    return patchEntry(loc, 20, &lo);
}

fn setSize(loc: Loc, size: u32) bool {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, size, .little);
    return patchEntry(loc, 28, &b);
}

// A zero date shows as 0000-00-00.
fn fatDate(t: zdos.Time) u16 {
    const year: u16 = if (t.year < 1980) 0 else @min(t.year - 1980, 127);
    if (t.month < 1 or t.day < 1) return 1 << 5 | 1; // no clock: 1980-01-01
    return year << 9 | @as(u16, t.month) << 5 | t.day;
}

fn fatTime(t: zdos.Time) u16 {
    return @as(u16, t.hour) << 11 | @as(u16, t.minute) << 5 | t.second / 2;
}

// Created and last written now:
fn entryBytes(name: *const [11]u8, attr: u8, first: u32, size: u32) [32]u8 {
    var e = [_]u8{0} ** 32;
    @memcpy(e[0..11], name);
    e[11] = attr;
    const now = zdos.getTime();
    std.mem.writeInt(u16, e[14..16], fatTime(now), .little);
    std.mem.writeInt(u16, e[16..18], fatDate(now), .little);
    std.mem.writeInt(u16, e[22..24], fatTime(now), .little);
    std.mem.writeInt(u16, e[24..26], fatDate(now), .little);
    std.mem.writeInt(u16, e[20..22], @truncate(first >> 16), .little);
    std.mem.writeInt(u16, e[26..28], @truncate(first), .little);
    std.mem.writeInt(u32, e[28..32], size, .little);
    return e;
}

fn writeEntryAt(loc: Loc, entry: *const [32]u8) bool {
    var buf: [sector]u8 = undefined;
    if (!readSector(loc.lba, &buf)) return false;
    @memcpy(buf[loc.off..][0..32], entry);
    return writeSec(loc.lba, &buf);
}

// Never used or deleted:
fn freeIn(sec: *const [sector]u8) ?usize {
    var off: usize = 0;
    while (off < sector) : (off += 32) {
        if (sec[off] == 0 or sec[off] == 0xE5) return off;
    }
    return null;
}

// dir null: the fixed root.
fn freeSlot(dir: ?u32) ?Loc {
    var sec: [sector]u8 = undefined;
    if (dir == null) {
        const start = vol.reserved + vol.fats * vol.fat_sectors;
        var i: u32 = 0;
        while (i < vol.root_sectors) : (i += 1) {
            if (!readSector(start + i, &sec)) return null;
            if (freeIn(&sec)) |off| return .{ .lba = start + i, .off = off };
        }
        return null;
    }
    var c = dir.?;
    while (validCluster(c)) {
        var s: u64 = 0;
        while (s < vol.spc) : (s += 1) {
            if (!readSector(clusterLba(c) + s, &sec)) return null;
            if (freeIn(&sec)) |off| return .{ .lba = clusterLba(c) + s, .off = off };
        }
        const next = fatEntry(0, c) orelse return null;
        if (isEoc(next)) break;
        c = next;
    }
    return null;
}

// dir null: the fixed root, which can't grow. A full folder grows.
fn addEntry(dir: ?u32, entry: *const [32]u8) bool {
    if (freeSlot(dir)) |loc| return writeEntryAt(loc, entry);
    var c = dir orelse return false;
    while (true) {
        const next = fatEntry(0, c) orelse return false;
        if (isEoc(next) or !validCluster(next)) break;
        c = next;
    }
    const grow = allocCluster() orelse return false;
    if (!zeroCluster(grow)) return false;
    if (!setFat(c, grow)) return false;
    return writeEntryAt(.{ .lba = clusterLba(grow), .off = 0 }, entry);
}

// The clusters after keep, up to total, are not owned now, so the lost
// chain repair saves them.
fn cutAfter(first: u32, keep: u32, total: u32) bool {
    var c = first;
    var i: u32 = 1;
    while (i < keep) : (i += 1) {
        c = fatEntry(0, c) orelse return false;
    }
    var t = fatEntry(0, c) orelse return false;
    if (!setFat(c, eocValue())) return false;
    var n = keep;
    while (n < total and validCluster(t)) : (n += 1) {
        bitClr(owned, t - 2);
        t = fatEntry(0, t) orelse break;
    }
    return true;
}

fn neededFor(size: u32) u32 {
    const per = clusterBytes();
    return @intCast((@as(u64, size) + per - 1) / per);
}

const Copy = struct { first: u32, count: u32 };

// The chain itself stays as it is; a bad cluster ends the copy.
fn copyChain(first: u32, max: u32) ?Copy {
    var src = first;
    var count: u32 = 0;
    var dst_first: u32 = 0;
    var prev: u32 = 0;
    while (validCluster(src) and count < max) {
        const next = fatEntry(0, src) orelse break;
        if (isBad(next)) break;
        const dst = allocCluster() orelse return null;
        if (!copyCluster(src, dst)) return null;
        if (count == 0) {
            dst_first = dst;
        } else if (!setFat(prev, dst)) {
            return null;
        }
        prev = dst;
        count += 1;
        if (isEoc(next) or next == 0) break;
        src = next;
    }
    if (count == 0) return null;
    return .{ .first = dst_first, .count = count };
}

// FAT12/16: null, the fixed area.
fn rootDir() ?u32 {
    return if (vol.kind == .fat32) vol.root_cluster else null;
}

const Seen = enum { no, yes, end };

// end: the folder ends in this sector.
fn sectorHas(sec: *const [sector]u8, name: *const [11]u8) Seen {
    var off: usize = 0;
    while (off < sector) : (off += 32) {
        const e = sec[off..][0..32];
        if (e[0] == 0) return .end;
        if (e[0] == 0xE5 or e[11] == 0x0F) continue;
        if (std.mem.eql(u8, e[0..11], name)) return .yes;
    }
    return .no;
}

// True if it can't be read.
fn rootHas(name: *const [11]u8) bool {
    var sec: [sector]u8 = undefined;
    if (vol.kind != .fat32) {
        const start = vol.reserved + vol.fats * vol.fat_sectors;
        var i: u32 = 0;
        while (i < vol.root_sectors) : (i += 1) {
            if (!readSector(start + i, &sec)) return true;
            switch (sectorHas(&sec, name)) {
                .yes => return true,
                .end => return false,
                .no => {},
            }
        }
        return false;
    }
    var c = vol.root_cluster;
    var n: u32 = 0;
    while (validCluster(c) and n < vol.clusters) : (n += 1) {
        var s: u64 = 0;
        while (s < vol.spc) : (s += 1) {
            if (!readSector(clusterLba(c) + s, &sec)) return true;
            switch (sectorHas(&sec, name)) {
                .yes => return true,
                .end => return false,
                .no => {},
            }
        }
        const next = fatEntry(0, c) orelse return true;
        if (isEoc(next)) return false;
        c = next;
    }
    return false;
}

// FOUND.000, or the next free number when an earlier repair left one.
fn ensureFound() bool {
    if (found_first != null) return true;
    if (found_failed) return false;
    found_failed = true;
    var name = "FOUND   000".*;
    var num: u32 = 0;
    while (rootHas(&name)) {
        num += 1;
        if (num > 999) {
            report("cannot make a FOUND folder: FOUND.000 to FOUND.999 are all taken", .{});
            return false;
        }
        _ = std.fmt.bufPrint(name[8..11], "{d:0>3}", .{num}) catch unreachable;
    }
    _ = std.fmt.bufPrint(&found_label, "FOUND.{s}", .{name[8..11]}) catch unreachable;
    const c = allocCluster() orelse {
        report("cannot make {s}: the disk is full", .{found_label[0..]});
        return false;
    };
    const dot = "." ++ " " ** 10;
    const dotdot = ".." ++ " " ** 9;
    var sec: [sector]u8 = undefined;
    @memset(&sec, 0);
    @memcpy(sec[0..32], &entryBytes(dot, 0x10, c, 0));
    // '..' of a folder in the root is 0, on FAT32 too:
    @memcpy(sec[32..64], &entryBytes(dotdot, 0x10, 0, 0));
    if (!zeroCluster(c) or !writeSec(clusterLba(c), &sec)) {
        report("cannot make {s}: a write failed", .{found_label[0..]});
        _ = setFat(c, 0);
        return false;
    }
    if (!addEntry(rootDir(), &entryBytes(&name, 0x10, c, 0))) {
        report("cannot make {s}: the root directory is full", .{found_label[0..]});
        _ = setFat(c, 0);
        return false;
    }
    found_first = c;
    found_failed = false;
    return true;
}

// FOUND.nnn\FILEnnnn.CHK:
fn saveChk(first: u32, size: u32) bool {
    if (!ensureFound()) return false;
    var name: [11]u8 = undefined;
    _ = std.fmt.bufPrint(&name, "FILE{d:0>4}CHK", .{chk_count}) catch {
        report("cannot save more than 10000 files in {s}", .{found_label[0..]});
        return false;
    };
    if (!addEntry(found_first, &entryBytes(&name, 0, first, size))) {
        report("cannot save a file in {s}: no room", .{found_label[0..]});
        return false;
    }
    chk_count += 1;
    fixed("saved {d} bytes as \\{s}\\{s}.{s}", .{ size, found_label[0..], name[0..8], name[8..11] });
    return true;
}

// Not everything was scanned, so lost clusters can't be told: no fixes.
fn outOfMemory() void {
    if (incomplete) return;
    incomplete = true;
    report("out of memory: not every folder could be checked", .{});
}

fn mem() std.mem.Allocator {
    return arena.allocator();
}

fn remember(f: Fix) void {
    var g = f;
    g.path = mem().dupe(u8, f.path) catch return outOfMemory();
    fix_list.append(mem(), g) catch outOfMemory();
}

fn problem(f: Fix, comptime fmt: []const u8, args: anytype) void {
    if (fixing) remember(f) else report(fmt, args);
}

fn withKind(f: Fix, kind: FixKind) Fix {
    var g = f;
    g.kind = kind;
    return g;
}

fn checkFile(path: []const u8, first: u32, size: u32, loc: Loc) void {
    if (size == 0) {
        if (first != 0) problem(.{ .kind = .empty_file, .path = path, .loc = loc, .first = first }, "{s}: empty file that still has cluster {d}", .{ path, first });
        return;
    }
    if (!validCluster(first)) {
        problem(.{ .kind = .bad_first, .path = path, .loc = loc, .first = first }, "{s}: first cluster {d} is not a cluster of the volume", .{ path, first });
        return;
    }
    const r = walk(first);
    const needed = neededFor(size);
    const f: Fix = .{ .kind = .chain_end, .path = path, .loc = loc, .first = first, .size = size, .r = r };
    switch (r.end) {
        .crossed => problem(withKind(f, .cross), "{s}: cluster {d} is also used by another file or folder (cross-linked)", .{ path, r.at }),
        .broken => problem(f, "{s}: the chain breaks at cluster {d} (a free or bad entry, or a read error)", .{ path, r.at }),
        .outside => problem(f, "{s}: the chain leaves the volume after cluster {d}", .{ path, r.last }),
        .eoc => {
            if (r.count == needed) return;
            const kind: FixKind = if (r.count < needed) .size_short else .chain_long;
            problem(withKind(f, kind), "{s}: size {d} needs {d} clusters, but its chain has {d}", .{ path, size, needed, r.count });
        },
    }
}

fn applyFix(f: Fix) void {
    switch (f.kind) {
        .empty_file => {
            if (setFirst(f.loc, 0)) {
                fixed("{s}: empty, so cluster {d} is freed for the lost chain check", .{ f.path, f.first });
            } else {
                report("{s}: cannot change its entry", .{f.path});
            }
        },
        .bad_first => {
            if (setFirst(f.loc, 0) and setSize(f.loc, 0)) {
                fixed("{s}: its first cluster {d} is not a cluster; the file is now empty", .{ f.path, f.first });
            } else {
                report("{s}: cannot change its entry", .{f.path});
            }
        },
        .chain_end => cutFile(f),
        .size_short => {
            // Shorter than the size says: the size follows the chain:
            const kept = @as(u64, f.r.count) * clusterBytes();
            if (setSize(f.loc, @intCast(kept))) {
                fixed("{s}: size set from {d} to {d} bytes, its chain length", .{ f.path, f.size, kept });
            } else {
                report("{s}: cannot change its size", .{f.path});
            }
        },
        .chain_long => {
            // Longer: cut after the clusters the size needs; the rest is lost:
            const needed = neededFor(f.size);
            if (cutAfter(f.first, needed, f.r.count)) {
                fixed("{s}: chain cut after {d} clusters; the rest is recovered as a lost chain", .{ f.path, needed });
            } else {
                report("{s}: cannot cut its chain", .{f.path});
            }
        },
        .cross => fixCross(f),
        .folder_cross => fixFolderCross(f),
        .orphan_lfn => {
            var ok = true;
            for (f.lfn) |loc| {
                if (!patchEntry(loc, 0, &[_]u8{0xE5})) ok = false;
            }
            if (ok) {
                fixed("{s}: deleted an orphan long-name entry ({d} pieces)", .{ f.path, f.size });
            } else {
                report("{s}: cannot delete an orphan long-name entry", .{f.path});
            }
        },
    }
}

// Ends at the last good cluster, or where its size ends.
fn cutFile(f: Fix) void {
    const keep = @min(f.r.count, neededFor(f.size));
    if (keep == 0) {
        if (setFirst(f.loc, 0) and setSize(f.loc, 0)) {
            fixed("{s}: its first cluster can't be used; the file is now empty", .{f.path});
        } else {
            report("{s}: cannot change its entry", .{f.path});
        }
        return;
    }
    const cut = if (keep == f.r.count) setFat(f.r.last, eocValue()) else cutAfter(f.first, keep, f.r.count);
    if (!cut) {
        report("{s}: cannot change the FAT", .{f.path});
        return;
    }
    const kept = @as(u64, keep) * clusterBytes();
    if (f.size > kept and !setSize(f.loc, @intCast(kept))) {
        report("{s}: cannot change its size", .{f.path});
        return;
    }
    fixed("{s}: chain cut after {d} clusters, size {d} bytes", .{ f.path, keep, @min(@as(u64, f.size), kept) });
}

// Cross-link: the first owner keeps its clusters; this file's data goes
// to a .CHK file and it keeps only the clusters before the shared one.
fn fixCross(f: Fix) void {
    const per = clusterBytes();
    // Past the shared cluster is another file's data:
    const needed = neededFor(f.size);
    const copy = copyChain(f.first, needed) orelse {
        report("{s}: cannot copy its data", .{f.path});
        return;
    };
    const copy_size: u64 = @min(@as(u64, f.size), @as(u64, copy.count) * per);
    if (!saveChk(copy.first, @intCast(copy_size))) return;
    const keep = @min(f.r.count, needed);
    if (keep == 0) {
        if (setFirst(f.loc, 0) and setSize(f.loc, 0)) {
            fixed("{s}: its first cluster is shared; the file is now empty", .{f.path});
        } else {
            report("{s}: cannot change its entry", .{f.path});
        }
        return;
    }
    const cut = if (keep == f.r.count) setFat(f.r.last, eocValue()) else cutAfter(f.first, keep, f.r.count);
    const kept = @min(@as(u64, f.size), @as(u64, keep) * per);
    if (!cut or !setSize(f.loc, @intCast(kept))) {
        report("{s}: cannot cut its chain", .{f.path});
        return;
    }
    fixed("{s}: cut before the shared cluster {d}", .{ f.path, f.r.at });
}

fn setFirstIn(e: *[32]u8, first: u32) void {
    std.mem.writeInt(u16, e[26..28], @truncate(first), .little);
    std.mem.writeInt(u16, e[20..22], @truncate(first >> 16), .little);
}

// A cluster that doesn't start like a folder is left alone.
fn setDotDot(sub: u32, parent: u32) bool {
    var buf: [sector]u8 = undefined;
    if (!readSector(clusterLba(sub), &buf)) return false;
    if (!std.mem.eql(u8, buf[32..43], ".." ++ " " ** 9)) return true;
    setFirstIn(buf[32..64], parent);
    return writeSec(clusterLba(sub), &buf);
}

fn folderCrossed(first: u32) bool {
    var c = first;
    var n: u32 = 0;
    while (validCluster(c) and n < vol.clusters) : (n += 1) {
        if (bitGet(owned, c - 2)) return true;
        const next = fatEntry(0, c) orelse return false;
        if (isEoc(next) or next == 0 or isBad(next)) return false;
        c = next;
    }
    return false;
}

// Fixes '.' and '..'. The copy's clusters stay unmarked for its scan.
fn copyFolder(src: u32, parent: u32) ?u32 {
    // One new cluster for each, chained in the same order:
    var first: u32 = 0;
    var prev: u32 = 0;
    var s = src;
    var n: u32 = 0;
    while (validCluster(s) and n < vol.clusters) {
        const next = fatEntry(0, s) orelse return null;
        if (isBad(next)) break;
        const d = allocCluster() orelse return null;
        bitClr(owned, d - 2);
        if (n == 0) {
            first = d;
        } else if (!setFat(prev, d)) {
            return null;
        }
        prev = d;
        n += 1;
        if (isEoc(next) or next == 0) break;
        s = next;
    }
    if (n == 0) return null;
    // Up to the end marker:
    var sc = src;
    var dc = first;
    var ended = false;
    var k: u32 = 0;
    while (k < n) : (k += 1) {
        var i: u64 = 0;
        while (i < vol.spc) : (i += 1) {
            var buf: [sector]u8 = undefined;
            if (!readSector(clusterLba(sc) + i, &buf)) return null;
            var off: usize = 0;
            while (off < sector and !ended) : (off += 32) {
                const e = buf[off..][0..32];
                if (e[0] == 0) {
                    ended = true;
                    break;
                }
                if (e[0] == 0xE5 or e[11] == 0x0F or e[11] & 0x10 == 0) continue;
                var name_buf: [13]u8 = undefined;
                const short = shortName(e[0..11], &name_buf);
                if (std.mem.eql(u8, short, ".")) {
                    setFirstIn(e, first);
                } else if (std.mem.eql(u8, short, "..")) {
                    setFirstIn(e, parent);
                } else {
                    const sub = clusterOf(e);
                    if (validCluster(sub) and !bitGet(owned, sub - 2) and !setDotDot(sub, first)) return null;
                }
            }
            if (!writeSec(clusterLba(dc) + i, &buf)) return null;
        }
        if (k + 1 < n) {
            sc = fatEntry(0, sc) orelse return null;
            dc = fatEntry(0, dc) orelse return null;
        }
    }
    return first;
}

// The contents are copied to FOUND.nnn\DIRi (scanned next round) and
// the folder stays empty.
fn fixFolderCross(f: Fix) void {
    if (dir_count == max_copies) {
        report("{s}: cannot copy the folder: too many folder copies", .{f.path});
        return;
    }
    if (!ensureFound()) return;
    const copy_first = copyFolder(f.first, found_first.?) orelse {
        report("{s}: cannot copy the folder (no room on the disk)", .{f.path});
        return;
    };
    const empty = allocCluster() orelse {
        report("{s}: cannot make the empty folder (no room on the disk)", .{f.path});
        return;
    };
    const dot = "." ++ " " ** 10;
    const dotdot = ".." ++ " " ** 9;
    var sec: [sector]u8 = undefined;
    @memset(&sec, 0);
    @memcpy(sec[0..32], &entryBytes(dot, 0x10, empty, 0));
    @memcpy(sec[32..64], &entryBytes(dotdot, 0x10, f.parent, 0));
    if (!zeroCluster(empty) or !writeSec(clusterLba(empty), &sec) or !setFirst(f.loc, empty)) {
        report("{s}: cannot change its entry", .{f.path});
        return;
    }
    // Clusters nobody else uses are free now:
    var c = f.first;
    var n: u32 = 0;
    while (validCluster(c) and n < vol.clusters) : (n += 1) {
        const next = fatEntry(0, c) orelse break;
        if (!bitGet(owned, c - 2)) _ = setFat(c, 0);
        if (isEoc(next) or next == 0 or isBad(next)) break;
        c = next;
    }
    var name: [11]u8 = undefined;
    _ = std.fmt.bufPrint(&name, "DIR{d:0>4}    ", .{dir_count}) catch return;
    if (!addEntry(found_first, &entryBytes(&name, 0x10, copy_first, 0))) {
        report("{s}: cannot add its copy to {s}: no room", .{ f.path, found_label[0..] });
        return;
    }
    dir_count += 1;
    fixed("{s}: folder copied to \\{s}\\{s}; {s} is now empty", .{ f.path, found_label[0..], name[0..7], f.path });
    const path = std.fmt.allocPrint(mem(), "\\{s}\\{s}\\", .{ found_label[0..], name[0..7] }) catch return outOfMemory();
    copies.append(mem(), .{ .first = copy_first, .path = path, .entry = null, .root = false, .parent = found_first }) catch outOfMemory();
}

// Orphaned long-name pieces: reported, or deleted by the repair.
fn flushLfn(prefix: []const u8) void {
    if (lfn_count == 0) return;
    const n = @min(lfn_count, max_lfn);
    if (fixing) {
        if (mem().dupe(Loc, lfn_locs[0..n])) |locs| {
            remember(.{ .kind = .orphan_lfn, .path = prefix, .size = lfn_count, .lfn = locs });
        } else |_| {
            outOfMemory();
        }
    } else {
        report("{s}: orphan long-name entry ({d} pieces, with no short entry after them)", .{ prefix, lfn_count });
    }
    lfn_count = 0;
}

fn folderName(path: []const u8) []const u8 {
    return if (path.len > 1) path[0 .. path.len - 1] else path;
}

// False at the end marker.
fn scanSector(sec: *const [sector]u8, lba: u64, f: *const Folder) bool {
    var off: usize = 0;
    while (off < sector) : (off += 32) {
        const e = sec[off..][0..32];
        if (e[0] == 0x00) {
            flushLfn(f.path);
            return false;
        }
        if (e[0] == 0xE5) {
            // A deleted long-name piece is nothing;
            // a deleted short entry ends a run:
            if (e[11] & 0x3F != 0x0F) flushLfn(f.path);
            continue;
        }
        if (e[11] == 0x0F) {
            if (lfn_count < max_lfn) lfn_locs[lfn_count] = .{ .lba = lba, .off = off };
            lfn_count += 1;
            continue;
        }
        if (e[11] & 0x08 != 0 and e[11] & 0x10 == 0) {
            // A volume label: a run before it has no short entry:
            flushLfn(f.path);
            continue;
        }
        lfn_count = 0; // a short entry: the run before it belongs to it
        var name_buf: [13]u8 = undefined;
        const short = shortName(e[0..11], &name_buf);
        const first = clusterOf(e);
        const loc: Loc = .{ .lba = lba, .off = off };
        if (e[11] & 0x10 != 0) {
            if (std.mem.eql(u8, short, ".") or std.mem.eql(u8, short, "..")) continue;
            // The folder made for a repair isn't checked:
            if (found_first != null and first == found_first.?) continue;
            folders += 1;
            const path = std.fmt.allocPrint(mem(), "{s}{s}\\", .{ f.path, short }) catch {
                outOfMemory();
                continue;
            };
            if (!validCluster(first)) {
                report("{s}: folder starts at cluster {d}, which is not a cluster of the volume", .{ folderName(path), first });
                continue;
            }
            const sub: Folder = .{ .first = first, .path = path, .entry = loc, .root = false, .parent = if (f.root) null else f.first };
            pending.append(mem(), sub) catch outOfMemory();
        } else {
            files += 1;
            var path_buf: [512]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ f.path, short }) catch
                (std.fmt.bufPrint(&path_buf, "...\\{s}", .{short}) catch unreachable);
            checkFile(path, first, std.mem.readInt(u32, e[28..32], .little), loc);
        }
    }
    return true;
}

fn clusterOf(e: []const u8) u32 {
    const lo: u32 = std.mem.readInt(u16, e[26..28], .little);
    const hi: u32 = if (vol.kind == .fat32) std.mem.readInt(u16, e[20..22], .little) else 0;
    return (hi << 16) | lo;
}

// "NAME.EXT", no spaces:
fn shortName(raw: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (raw[0..8]) |ch| {
        if (ch == ' ') break;
        out[n] = ch;
        n += 1;
    }
    if (raw[8] != ' ') {
        out[n] = '.';
        n += 1;
        for (raw[8..11]) |ch| {
            if (ch == ' ') break;
            out[n] = ch;
            n += 1;
        }
    }
    return out[0..n];
}

fn scanEntries(f: *const Folder) void {
    var sec: [sector]u8 = undefined;
    const first = f.first orelse {
        const root_start = vol.reserved + vol.fats * vol.fat_sectors;
        var i: u32 = 0;
        while (i < vol.root_sectors) : (i += 1) {
            if (!readSector(root_start + i, &sec)) {
                report("cannot read the root directory", .{});
                return;
            }
            if (!scanSector(&sec, root_start + i, f)) return;
        }
        return;
    };
    // A folder sharing clusters is copied, and the copy is scanned instead:
    if (fixing and f.entry != null and folderCrossed(first)) {
        remember(.{ .kind = .folder_cross, .path = folderName(f.path), .loc = f.entry.?, .first = first, .parent = f.parent orelse 0 });
        return;
    }
    var c = first;
    while (true) {
        if (!validCluster(c)) {
            report("{s}: folder chain leaves the volume at cluster {d}", .{ f.path, c });
            return;
        }
        if (bitGet(owned, c - 2)) {
            report("{s}: folder cluster {d} is also used by another file or folder (cross-linked)", .{ f.path, c });
            return;
        }
        bitSet(owned, c - 2);
        var s: u64 = 0;
        while (s < vol.spc) : (s += 1) {
            if (!readSector(clusterLba(c) + s, &sec)) {
                report("{s}: cannot read a folder sector", .{f.path});
                return;
            }
            if (!scanSector(&sec, clusterLba(c) + s, f)) return;
        }
        const next = fatEntry(0, c) orelse {
            report("{s}: cannot read the FAT", .{f.path});
            return;
        };
        if (isEoc(next)) return;
        if (next == 0 or isBad(next)) {
            report("{s}: folder chain breaks at cluster {d}", .{ f.path, c });
            return;
        }
        c = next;
    }
}

fn scanFolder(f: *const Folder) void {
    const start = pending.items.len;
    lfn_count = 0;
    scanEntries(f);
    flushLfn(f.path);
    std.mem.reverse(Folder, pending.items[start..]);
}

// A list, not recursion. A loop in the tree shows as a cross-link.
fn scanPending() void {
    while (pending.pop()) |f| scanFolder(&f);
}

fn scanRoot() void {
    pending.append(mem(), .{ .first = rootDir(), .path = "\\", .entry = null, .root = true, .parent = null }) catch return outOfMemory();
    scanPending();
}

// In use in the FAT, but no file or folder reaches them.
fn lostClusters() void {
    var progress = sys.Progress.begin("Looking for lost clusters", vol.clusters);
    var lost: u32 = 0;
    var chains: u32 = 0;
    var c: u32 = 2;
    while (c < vol.clusters + 2) : (c += 1) {
        const v = fatEntry(0, c) orelse break;
        if (v != 0 and !isBad(v) and !bitGet(owned, c - 2)) {
            lost += 1;
            if (!bitGet(linked, c - 2)) chains += 1;
        }
        progress.update(c - 1);
    }
    progress.finish();
    // A chain running in a circle has no start, but is a chain:
    if (lost > 0) report("{d} lost clusters in {d} chains that no file or folder uses", .{ lost, @max(chains, 1) });
}

// Each lost chain becomes a .CHK file. The links are worked out again,
// since the fixes changed the FAT.
fn recoverLost() void {
    @memset(linked, 0);
    var c: u32 = 2;
    while (c < vol.clusters + 2) : (c += 1) {
        const v = fatEntry(0, c) orelse return;
        if (validCluster(v)) bitSet(linked, v - 2);
    }
    // First chains with a start, then circles, where any cluster will do:
    for ([_]bool{ true, false }) |starts| {
        c = 2;
        while (c < vol.clusters + 2) : (c += 1) {
            const v = fatEntry(0, c) orelse return;
            if (v == 0 or isBad(v) or bitGet(owned, c - 2)) continue;
            if (starts and bitGet(linked, c - 2)) continue;
            recoverChain(c);
        }
    }
}

// A chain without an end mark gets one at its last cluster.
fn recoverChain(start: u32) void {
    var k = start;
    var n: u32 = 0;
    var ended = false;
    while (true) {
        bitSet(owned, k - 2);
        n += 1;
        const next = fatEntry(0, k) orelse break;
        if (isEoc(next)) {
            ended = true;
            break;
        }
        if (next == 0 or !validCluster(next) or bitGet(owned, next - 2)) break;
        // A bad cluster stays out of the chain:
        const after = fatEntry(0, next) orelse break;
        if (isBad(after)) break;
        k = next;
    }
    if (!ended and !setFat(k, eocValue())) {
        report("cannot end the lost chain at cluster {d}", .{k});
        return;
    }
    _ = saveChk(start, @intCast(@min(@as(u64, n) * clusterBytes(), 0xFFFF_FFFF)));
}

fn resetPass() void {
    @memset(owned, 0);
    @memset(linked, 0);
    problems = 0;
    fixes = 0;
    failures = 0;
    files = 0;
    folders = 0;
    free_clusters = 0;
    bad_clusters = 0;
    fat_cache_lba = .{ null, null };
    alloc_hint = 2;
    found_first = null;
    found_failed = false;
    chk_count = 0;
    lfn_count = 0;
    dir_count = 0;
    incomplete = false;
    if (arena_live) arena.deinit();
    arena = std.heap.ArenaAllocator.init(zdos.allocator);
    arena_live = true;
    pending = .{};
    fix_list = .{};
    copies = .{};
}

// Changes nothing.
fn analyse() void {
    fixing = false;
    resetPass();
    _ = compareCopies();
    countEntries();
    checkFsInfo();
    scanRoot();
    // Without every folder scanned, clusters in use would look lost:
    if (!incomplete) lostClusters();
    zdos.printf("{d} files, {d} folders, {d} of {d} clusters free", .{ files, folders, free_clusters, vol.clusters });
    if (bad_clusters > 0) zdos.printf(", {d} marked bad", .{bad_clusters});
    zdos.print("\n");
    if (problems == 0) {
        zdos.print("No errors found.\n");
    } else {
        zdos.printf("{d} problems found.\n", .{problems});
    }
}

// In rounds: scan and remember problems, then fix them once every
// cluster in use is known. Lost chains are saved last.
fn repair() bool {
    fixing = true;
    resetPass();
    if (vol.fats == 2 and !compareCopiesEqual()) {
        if (copyFat()) {
            fixed("copied FAT 1 over FAT 2", .{});
        } else {
            report("cannot copy FAT 1 over FAT 2", .{});
        }
    }
    countEntries();
    scanRoot();
    while (!incomplete) {
        if (fix_list.items.len == 0) break;
        for (fix_list.items) |f| applyFix(f);
        fix_list.clearRetainingCapacity();
        for (copies.items) |copy| pending.append(mem(), copy) catch outOfMemory();
        copies.clearRetainingCapacity();
        scanPending();
    }
    if (!incomplete) recoverLost();
    fixFsInfo();
    fixing = false;
    zdos.printf("{d} fixed, {d} could not be fixed.\n", .{ fixes, failures });
    return failures == 0;
}

// After the other repairs. An unknown count (all ones) is left alone.
fn fixFsInfo() void {
    var sec: [sector]u8 = undefined;
    if (!readFsInfo(&sec)) return;
    const counted = std.mem.readInt(u32, sec[488..492], .little);
    var free: u32 = 0;
    var c: u32 = 2;
    while (c < vol.clusters + 2) : (c += 1) {
        const v = fatEntry(0, c) orelse return;
        if (v == 0) free += 1;
    }
    if (counted == 0xFFFF_FFFF or counted == free) return;
    std.mem.writeInt(u32, sec[488..492], free, .little);
    if (!writeSec(vol.fsinfo, &sec)) {
        report("cannot write FSInfo", .{});
        return;
    }
    fixed("FSInfo free cluster count set from {d} to {d}", .{ counted, free });
}

fn compareCopiesEqual() bool {
    var c: u32 = 0;
    while (c < vol.clusters + 2) : (c += 1) {
        const a = fatEntry(0, c) orelse return false;
        const b = fatEntry(1, c) orelse return false;
        if (a != b) return false;
    }
    return true;
}
