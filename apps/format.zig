// FORMAT: a new, empty FAT file system on a partition or a floppy.
// Without -C the volume's size decides the cluster size.
const std = @import("std");
const builtin = @import("builtin");
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

const sector = 512;
// The UEFI build is freestanding too:
const is_bios = builtin.os.tag == .freestanding and builtin.cpu.arch == .x86;
const usage = "Usage: FORMAT X: [-T 12|16|32] [-C bytes] [-L label] [-F]\n  or FORMAT <disk> <partition> [-T 12|16|32] [-C bytes] [-L label] [-F]\n  -F: full format, every sector overwritten with zeros first\n";

const Plan = struct {
    kind: sys.Kind,
    spc: u32,
    reserved: u32,
    fat_sectors: u32,
    root_entries: u32,
    root_sectors: u32,
    clusters: u32,
};

pub fn main(args: []const u8) u8 {
    if (std.mem.trim(u8, args, " \t").len > 0 and users.diskToolDenied("FORMAT")) return 1;
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    var pos: [2][]const u8 = undefined;
    var npos: usize = 0;
    var want: ?sys.Kind = null;
    var cluster_bytes: ?u32 = null;
    var label: []const u8 = "NO NAME";
    var full = false;
    while (words.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, "-F")) {
            full = true;
        } else if (std.ascii.eqlIgnoreCase(word, "-C")) {
            const v = words.next() orelse {
                zdos.print(usage);
                return 1;
            };
            const b = std.fmt.parseInt(u32, v, 10) catch {
                zdos.print(usage);
                return 1;
            };
            if (b < sector or b > 32768 or !std.math.isPowerOfTwo(b)) {
                zdos.print("The cluster size is 512 to 32768 bytes, a power of two\n");
                return 1;
            }
            cluster_bytes = b;
        } else if (std.ascii.eqlIgnoreCase(word, "-T")) {
            const v = words.next() orelse {
                zdos.print(usage);
                return 1;
            };
            want = if (std.mem.eql(u8, v, "12")) .fat12 else if (std.mem.eql(u8, v, "16")) .fat16 else if (std.mem.eql(u8, v, "32")) .fat32 else {
                zdos.print(usage);
                return 1;
            };
        } else if (std.ascii.eqlIgnoreCase(word, "-L")) {
            label = words.next() orelse {
                zdos.print(usage);
                return 1;
            };
        } else {
            if (npos == 2) {
                zdos.print(usage);
                return 1;
            }
            pos[npos] = word;
            npos += 1;
        }
    }
    if (label.len > 11) {
        zdos.print("The label can be 11 characters at most\n");
        return 1;
    }
    if (npos == 0) {
        zdos.print(usage);
        return 1;
    }
    // FORMAT X: or FORMAT <disk> <partition>:
    const target = if (driveLetter(pos[0])) |letter| blk: {
        if (npos != 1) {
            zdos.print(usage);
            return 1;
        }
        break :blk targetByLetter(letter) orelse return 1;
    } else blk: {
        if (npos != 2) {
            zdos.print(usage);
            return 1;
        }
        const disk = std.fmt.parseInt(u32, pos[0], 10) catch {
            zdos.print(usage);
            return 1;
        };
        const part_no = std.fmt.parseInt(u32, pos[1], 10) catch {
            zdos.print(usage);
            return 1;
        };
        break :blk findPartition(disk, part_no) orelse return 1;
    };

    const total = target.sectors;
    if (total == 0) {
        zdos.printf("Disk {d} has no readable disk\n", .{target.disk});
        return 1;
    }
    // FAT counts sectors in 32 bits:
    if (total > std.math.maxInt(u32)) {
        zdos.print("It is larger than 2 TB, more than a FAT file system can hold\n");
        return 1;
    }
    const geo = geometryFor(target, total) orelse {
        zdos.printf("A floppy of {d} sectors is not a size FORMAT knows\n", .{total});
        return 1;
    };
    const spc_fixed: ?u32 = if (cluster_bytes) |b| b / sector else null;
    const kind = want orelse autoKind(total, spc_fixed);
    const plan = planFor(kind, total, spc_fixed orelse defaultSpc(kind, total)) orelse {
        zdos.printf("A FAT{s} volume with these clusters doesn't fit this partition; try -T or -C\n", .{kindDigits(kind)});
        return 1;
    };
    zdos.printf("Format disk {d}, from sector {d}, as {s}:\n{d} sectors, {d} clusters of {d} bytes, label \"{s}\".\n", .{
        target.disk,
        target.start,
        kindName(kind),
        total,
        plan.clusters,
        plan.spc * sector,
        label,
    });
    if (target.esp) zdos.print("This is an EFI system partition: its boot files would be erased.\n");
    if (full) zdos.print("Full format: every sector is overwritten with zeros first (this takes a while).\n");
    zdos.print("ALL DATA on it will be lost. Format it? (Y/N) ");
    if (!sys.askYes()) {
        zdos.print("Nothing was changed.\n");
        return 1;
    }
    sys.syncDisk(target.disk) catch {
        zdos.print("Cannot sync the target disk before formatting.\n");
        return 1;
    };
    const serial: u32 = @truncate(zdos.millis() ^ 0x5A5A_1234);
    if (!writeVolume(target, total, plan, geo, label, serial, full)) {
        zdos.printf("Cannot write disk {d}\n", .{target.disk});
        return 1;
    }
    if (!target.floppy) setFatType(target, kind);
    if (target.letter != 0) sys.driveChanged(target.letter) else sys.diskChanged(target.disk);
    zdos.printf("Formatted as {s}, serial {X:0>4}-{X:0>4}.\n", .{ kindName(kind), serial >> 16, serial & 0xFFFF });
    zdos.print("It is not bootable yet: use SYS for that.\n");
    if (zdos.onUefi()) zdos.print("Restart ZDOS before using it: the firmware still shows\nthe old contents until then.\n");
    return 0;
}

// As FDISK makes them; kept where it already fits, an ESP stays one.
// A failure is only reported.
fn setFatType(t: Target, kind: sys.Kind) void {
    // By letter the target counts from the volume: where is it on its disk?
    var disk = t.disk;
    var start = t.start;
    if (t.letter != 0) {
        const loc = sys.driveLocation(t.letter) catch return;
        disk = loc.disk;
        start = loc.start;
    }
    var list: [sys.max_partitions]sys.Partition = undefined;
    const n = sys.partitionsOf(disk, &list) orelse return;
    const p = for (list[0..n]) |p| {
        if (p.start == start) break p;
    } else return; // no partition table
    if (p.esp) return;
    const fits: []const u8 = switch (kind) {
        .fat12 => &.{ 0x01, 0x11 },
        .fat16 => &.{ 0x04, 0x06, 0x0E, 0x14, 0x16, 0x1E },
        .fat32 => &.{ 0x0B, 0x0C, 0x1B, 0x1C },
    };
    const hidden = std.mem.indexOfScalar(u8, &.{ 0x11, 0x14, 0x16, 0x1B, 0x1C, 0x1E }, p.kind) != null;
    const mbr_type: u8 = if (std.mem.indexOfScalar(u8, fits, p.kind) != null) p.kind else switch (kind) {
        .fat12 => if (hidden) 0x11 else 0x01,
        .fat16 => if (hidden) 0x16 else 0x06,
        .fat32 => if (hidden) 0x1C else 0x0C,
    };
    switch (sys.setPartitionType(disk, start, mbr_type, &sys.gpt_basic_data)) {
        .changed => if (p.kind != 0) zdos.printf("Partition type set to {X:0>2}.\n", .{mbr_type}) else zdos.print("Partition type set to Microsoft basic data.\n"),
        .already, .no_table => {},
        .failed => zdos.print("The partition's type could not be changed.\n"),
    }
}

fn driveLetter(word: []const u8) ?u8 {
    if (word.len == 2 and word[1] == ':' and std.ascii.isAlphabetic(word[0])) return std.ascii.toUpper(word[0]);
    if (word.len == 1 and std.ascii.isAlphabetic(word[0])) return std.ascii.toUpper(word[0]);
    return null;
}

// esp: FORMAT asks again. hidden: the volume's first sector on its disk
// (for the BIOS boot code).
const Target = struct { disk: u32, start: u64, sectors: u64, esp: bool, letter: u8 = 0, hidden: u64 = 0, floppy: bool = false };

// The drive ZDOS started from is refused: the boot files are on it.
fn targetByLetter(letter: u8) ?Target {
    const info = zdos.driveInfo(letter) catch {
        zdos.printf("No drive {c}:\n", .{letter});
        return null;
    };
    if (info.boot) {
        zdos.printf("Drive {c}: is the drive ZDOS was started from: it is not formatted\n", .{letter});
        return null;
    }
    if (!info.ready) {
        // A blank floppy: the whole disk, through its drive's disk number:
        if (info.floppy) {
            if (sys.driveLocation(letter)) |loc| {
                if (loc.sectors > 0) return .{ .disk = loc.disk, .start = 0, .sectors = loc.sectors, .esp = false, .floppy = true };
            } else |_| {}
        }
        zdos.printf("Drive {c}: has no readable disk\n", .{letter});
        return null;
    }
    const sectors = sys.driveSectors(letter) catch |err| {
        if (err == error.NotSupported) {
            zdos.printf("Drive {c}: can't be formatted on this version (its sectors aren't 512 bytes)\n", .{letter});
        } else {
            zdos.printf("Cannot read the size of drive {c}:\n", .{letter});
        }
        return null;
    };
    // "Hidden sectors", for the BIOS boot code; 0 where unknown:
    const hidden: u64 = if (sys.driveLocation(letter)) |loc| loc.start else |_| 0;
    return .{ .disk = 0, .start = 0, .sectors = sectors, .esp = info.system, .letter = letter, .hidden = hidden, .floppy = info.floppy };
}

// The whole disk when there is no partition table.
fn findPartition(disk: u32, part_no: u32) ?Target {
    const info = sys.diskInfo(disk) orelse {
        zdos.printf("No disk {d}\n", .{disk});
        return null;
    };
    if (info.sector_size != sector or info.sectors == 0) {
        zdos.printf("Disk {d} has no readable disk or its sectors are not 512 bytes\n", .{disk});
        return null;
    }
    // GPT: the entry slots, as Linux numbers them; no table: partition 1.
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
    // A BIOS floppy drive, the only removable disks there:
    if (p.whole_disk) return .{ .disk = disk, .start = 0, .sectors = info.sectors, .esp = false, .floppy = is_bios and info.removable };
    if (p.kind == 0x05 or p.kind == 0x0F) {
        zdos.printf("Partition {d} is an extended partition: format one of the partitions it holds\n", .{part_no});
        return null;
    }
    if (p.sectors == 0 or p.start + p.sectors > info.sectors) {
        zdos.printf("Partition {d} goes past the end of the disk: its entry is damaged\n", .{part_no});
        return null;
    }
    return .{ .disk = disk, .start = p.start, .sectors = p.sectors, .esp = p.esp, .hidden = p.start };
}

// A floppy gets its standard format's (ZDOS and the boot code address
// it by them); null for another size.
const Geometry = struct { spt: u32 = 63, heads: u32 = 255, media: u8 = 0xF8 };

const floppy_formats = [_]struct { sectors: u64, geo: Geometry }{
    .{ .sectors = 320, .geo = .{ .spt = 8, .heads = 1, .media = 0xFE } }, // 160 KB
    .{ .sectors = 360, .geo = .{ .spt = 9, .heads = 1, .media = 0xFC } }, // 180 KB
    .{ .sectors = 640, .geo = .{ .spt = 8, .heads = 2, .media = 0xFF } }, // 320 KB
    .{ .sectors = 720, .geo = .{ .spt = 9, .heads = 2, .media = 0xFD } }, // 360 KB
    .{ .sectors = 1440, .geo = .{ .spt = 9, .heads = 2, .media = 0xF9 } }, // 720 KB
    .{ .sectors = 2400, .geo = .{ .spt = 15, .heads = 2, .media = 0xF9 } }, // 1.2 MB
    .{ .sectors = 2880, .geo = .{ .spt = 18, .heads = 2, .media = 0xF0 } }, // 1.44 MB
    .{ .sectors = 5760, .geo = .{ .spt = 36, .heads = 2, .media = 0xF0 } }, // 2.88 MB
};

fn geometryFor(t: Target, total: u64) ?Geometry {
    if (!t.floppy) return .{};
    for (floppy_formats) |f| {
        if (f.sectors == total) return f.geo;
    }
    return null;
}

fn kindName(kind: sys.Kind) []const u8 {
    return switch (kind) {
        .fat12 => "FAT12",
        .fat16 => "FAT16",
        .fat32 => "FAT32",
    };
}

fn kindDigits(kind: sys.Kind) []const u8 {
    return switch (kind) {
        .fat12 => "12",
        .fat16 => "16",
        .fat32 => "32",
    };
}

// Without -T: FAT12 for floppy sizes, else FAT16 if its
// clusters fit, else FAT32.
fn autoKind(total: u64, spc: ?u32) sys.Kind {
    if (total <= 4096) return .fat12;
    if (planFor(.fat16, total, spc orelse defaultSpc(.fat16, total)) != null) return .fat16;
    return .fat32;
}

// Sectors per cluster, after Windows's FORMAT table.
fn defaultSpc(kind: sys.Kind, total: u64) u32 {
    const mb: u64 = 1 << 20;
    const gb: u64 = 1 << 30;
    const bytes = total * sector;
    const cluster: u64 = switch (kind) {
        .fat12 => if (bytes <= 2 * mb) 512 else if (bytes <= 4 * mb) 1024 else 2048,
        .fat16 => if (bytes <= 32 * mb) 512 else if (bytes <= 64 * mb) 1024 else if (bytes <= 128 * mb) 2048 else if (bytes <= 256 * mb) 4096 else if (bytes <= 512 * mb) 8192 else if (bytes <= gb) 16384 else if (bytes <= 2 * gb) 32768 else 65536,
        .fat32 => if (bytes <= 128 * mb) 512 else if (bytes <= 256 * mb) 2048 else if (bytes <= 8 * gb) 4096 else if (bytes <= 16 * gb) 8192 else if (bytes <= 32 * gb) 16384 else 32768,
    };
    return @intCast(cluster / sector);
}

// Null if the cluster count doesn't fit that type.
fn planFor(kind: sys.Kind, total: u64, spc: u32) ?Plan {
    const reserved: u32 = if (kind == .fat32) 32 else 1;
    const root_entries: u32 = switch (kind) {
        .fat12 => 224,
        .fat16 => 512,
        .fat32 => 0,
    };
    const root_sectors: u32 = (root_entries * 32 + sector - 1) / sector;
    const reserved64: u64 = reserved;
    const root64: u64 = root_sectors;
    const spc64: u64 = spc;
    var fat_sectors: u64 = 1;
    var round: u32 = 0;
    while (round < 16) : (round += 1) {
        const used = reserved64 + 2 * fat_sectors + root64;
        if (total <= used) return null;
        const clusters = (total - used) / spc64;
        const entry_bytes: u64 = switch (kind) {
            .fat12 => ((clusters + 2) * 3 + 1) / 2,
            .fat16 => (clusters + 2) * 2,
            .fat32 => (clusters + 2) * 4,
        };
        const needed = (entry_bytes + sector - 1) / sector;
        if (needed == fat_sectors) break;
        fat_sectors = needed;
    }
    const used = reserved64 + 2 * fat_sectors + root64;
    if (total <= used or fat_sectors == 0 or fat_sectors > std.math.maxInt(u32)) return null;
    const clusters = (total - used) / spc64;
    if (clusters == 0 or clusters > std.math.maxInt(u32)) return null;
    const fits = switch (kind) {
        .fat12 => clusters < 4085,
        .fat16 => clusters >= 4085 and clusters < 65525,
        .fat32 => clusters >= 65525 and clusters <= 0x0FFF_FFF5, // highest: 0x0FFFFFF6
    };
    if (!fits) return null;
    return .{
        .kind = kind,
        .spc = spc,
        .reserved = reserved,
        .fat_sectors = @intCast(fat_sectors),
        .root_entries = root_entries,
        .root_sectors = root_sectors,
        .clusters = @intCast(clusters),
    };
}

// ZDOS's boot code is not in it (SYS adds it).
fn bootSector(total: u64, plan: Plan, geo: Geometry, hidden: u64, label: []const u8, serial: u32) [sector]u8 {
    var b = [_]u8{0} ** sector;
    const fat32 = plan.kind == .fat32;
    b[0] = 0xEB;
    b[1] = if (fat32) 0x58 else 0x3C;
    b[2] = 0x90;
    @memcpy(b[3..11], "ZIGDOS  ");
    put16(&b, 11, sector);
    b[13] = @intCast(plan.spc);
    put16(&b, 14, plan.reserved);
    b[16] = 2;
    put16(&b, 17, plan.root_entries);
    if (total <= 0xFFFF) {
        put16(&b, 19, @intCast(total));
    } else {
        put32(&b, 32, @intCast(total));
    }
    b[21] = geo.media;
    put16(&b, 22, if (fat32) 0 else plan.fat_sectors);
    put16(&b, 24, geo.spt);
    put16(&b, 26, geo.heads);
    // Hidden sectors: beyond 32 bits the BIOS can't boot it anyway:
    put32(&b, 28, if (hidden <= std.math.maxInt(u32)) @intCast(hidden) else 0);
    if (total <= 0xFFFF) put32(&b, 32, 0) else put32(&b, 32, @intCast(total));
    var name: [11]u8 = undefined;
    @memset(&name, ' ');
    @memcpy(name[0..label.len], label);
    if (fat32) {
        put32(&b, 36, plan.fat_sectors);
        put16(&b, 40, 0);
        put16(&b, 42, 0);
        put32(&b, 44, 2); // the root directory's cluster
        put16(&b, 48, 1); // FSInfo sector
        put16(&b, 50, 6); // backup boot sector
        b[64] = 0x80;
        b[66] = 0x29;
        put32(&b, 67, serial);
        @memcpy(b[71..82], &name);
        @memcpy(b[82..90], "FAT32   ");
    } else {
        b[36] = 0x80;
        b[38] = 0x29;
        put32(&b, 39, serial);
        @memcpy(b[43..54], &name);
        @memcpy(b[54..62], if (plan.kind == .fat12) "FAT12   " else "FAT16   ");
    }
    b[510] = 0x55;
    b[511] = 0xAA;
    return b;
}

fn put16(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u16, b[at..][0..2], @truncate(v), .little);
}

fn put32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

// For the progress line.
const Writer = struct {
    disk: u32,
    letter: u8,
    start: u64,
    progress: sys.Progress,
    done: u64 = 0,

    fn put(self: *Writer, lba: u64, data: []const u8) bool {
        if (self.letter != 0) {
            sys.driveWrite(self.letter, lba - self.start, data) catch return false;
        } else {
            sys.writeSectors(self.disk, lba, data) catch return false;
        }
        self.done += data.len / sector;
        self.progress.update(self.done);
        return true;
    }
};

// 128 sectors, in .bss: not in the .APP file.
var zeros = [_]u8{0} ** (128 * sector);

// Sectors at each end that hold another file system's signature: ZFS
// keeps two 256 KB labels at the start and two at the end.
const label_area: u64 = 1024;

// Old ext2/ZFS signatures are cleared first, or Linux would see two
// file systems and mount neither. full: every sector is cleared.
fn writeVolume(t: Target, total: u64, plan: Plan, geo: Geometry, label: []const u8, serial: u32, full: bool) bool {
    const start = t.start;
    const boot = bootSector(total, plan, geo, t.hidden, label, serial);
    const zero = [_]u8{0} ** sector;
    const root_writes: u64 = if (plan.kind == .fat32) plan.spc else plan.root_sectors;
    const front_end: u64 = if (full) total else @min(total, if (t.floppy) 8 else label_area);
    const back_start: u64 = if (full or t.floppy or total <= 2 * label_area) total else total - label_area;
    const wipes = (front_end -| 1) + (total - back_start);
    var w = Writer{ .disk = t.disk, .letter = t.letter, .start = start, .progress = sys.Progress.begin("Writing the file system", wipes + 2 * @as(u64, plan.fat_sectors) + root_writes + 4) };
    defer w.progress.finish();
    // The boot sector is written below; many sectors at a time:
    var s: u64 = 1;
    while (s < front_end) {
        const n: usize = @intCast(@min(front_end - s, zeros.len / sector));
        if (!w.put(start + s, zeros[0 .. n * sector])) return false;
        s += n;
    }
    s = back_start;
    while (s < total) : (s += 1) {
        if (!w.put(start + s, &zero)) return false;
    }
    // Boot sector, and the backup on FAT32:
    if (!w.put(start, &boot)) return false;
    if (plan.kind == .fat32) {
        if (!w.put(start + 6, &boot)) return false;
        var info = [_]u8{0} ** sector;
        std.mem.writeInt(u32, info[0..4], 0x41615252, .little);
        std.mem.writeInt(u32, info[484..488], 0x61417272, .little);
        std.mem.writeInt(u32, info[488..492], plan.clusters - 1, .little);
        std.mem.writeInt(u32, info[492..496], 3, .little);
        std.mem.writeInt(u32, info[508..512], 0xAA550000, .little);
        if (!w.put(start + 1, &info)) return false;
    }
    // Entry 0 holds the media byte:
    var first = [_]u8{0} ** sector;
    switch (plan.kind) {
        .fat12 => {
            first[0] = geo.media;
            first[1] = 0xFF;
            first[2] = 0xFF;
        },
        .fat16 => {
            first[0] = geo.media;
            first[1] = 0xFF;
            first[2] = 0xFF;
            first[3] = 0xFF;
        },
        .fat32 => {
            std.mem.writeInt(u32, first[0..4], 0x0FFF_FF00 | @as(u32, geo.media), .little);
            std.mem.writeInt(u32, first[4..8], 0x0FFF_FFFF, .little);
            std.mem.writeInt(u32, first[8..12], 0x0FFF_FFFF, .little); // the root
        },
    }
    var copy: u32 = 0;
    while (copy < 2) : (copy += 1) {
        const fat_start = start + @as(u64, plan.reserved) + @as(u64, copy) * @as(u64, plan.fat_sectors);
        if (!w.put(fat_start, &first)) return false;
        var s2: u64 = 1;
        while (s2 < plan.fat_sectors) : (s2 += 1) {
            if (!w.put(fat_start + s2, &zero)) return false;
        }
    }
    // Fixed area, or cluster 2 on FAT32; the first entry is the label:
    var root_first = [_]u8{0} ** sector;
    if (!std.mem.eql(u8, label, "NO NAME")) {
        var name: [11]u8 = undefined;
        @memset(&name, ' ');
        @memcpy(name[0..label.len], label);
        @memcpy(root_first[0..11], &name);
        root_first[11] = 0x08; // volume label
    }
    const root_start = start + @as(u64, plan.reserved) + 2 * @as(u64, plan.fat_sectors);
    var r: u64 = 0;
    if (plan.kind == .fat32) {
        while (r < plan.spc) : (r += 1) {
            if (!w.put(root_start + r, if (r == 0) &root_first else &zero)) return false;
        }
    } else {
        while (r < plan.root_sectors) : (r += 1) {
            if (!w.put(root_start + r, if (r == 0) &root_first else &zero)) return false;
        }
    }
    return true;
}
