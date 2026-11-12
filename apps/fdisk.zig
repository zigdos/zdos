// FDISK: MBR partitions of a disk, as DOS's FDISK. Numbered as
// CHKDSK lists them. GPT disks and the boot disk are refused.
const std = @import("std");
const builtin = @import("builtin");
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

// The UEFI build is freestanding too:
const is_bios = builtin.os.tag == .freestanding and builtin.cpu.arch == .x86;
const usage = "Usage: FDISK <disk> [-MBR]\n";

// 440 bytes, for FDISK -MBR:
const mbr_code: []const u8 = if (is_bios) @embedFile("mbr.bin") else "";

const sectors_per_mb: u64 = 2048; // 1 MB of 512-byte sectors
const align_sectors: u64 = 2048; // partitions and boot records start on 1 MB
const default_type: u8 = 0x06; // FAT16, offered for a new partition
const extended_type: u8 = 0x0F; // the extended partition (LBA form)
const max_logical = sys.max_parts; // logical partitions in one chain
const max_refs = 4 + max_logical; // primary entries plus logical partitions

// Type 0 is empty. In a Table a logical partition's start is absolute;
// on disk it is relative to its boot record (see putSlot).
const Slot = struct {
    kind: u8 = 0,
    boot: bool = false,
    start: u64 = 0,
    sectors: u64 = 0,
};

// Its boot record's sector is absolute.
const Logical = struct {
    ebr: u64 = 0,
    slot: Slot = .{},
};

// Logical partitions in chain order; extended: the one they hang from.
const Table = struct {
    prim: [4]Slot,
    logical: [max_logical]Logical,
    nlogical: usize,
    ext: ?usize,
};

// A primary entry (slot index) or a logical one (index in the chain).
const Ref = struct { logical: bool, index: usize };

const Disk = struct { index: u32, sectors: u64 };

pub fn main(args: []const u8) u8 {
    if (!is_bios) {
        zdos.print("FDISK is only for the BIOS version of ZDOS\n");
        return 1;
    }
    const s = std.mem.trim(u8, args, " \t");
    if (s.len == 0) {
        listDisks();
        zdos.print(usage);
        return 1;
    }
    if (users.diskToolDenied("FDISK")) return 1;
    // The disk number and -MBR, in any order:
    var mbr = false;
    var disk_text: []const u8 = "";
    var words = std.mem.tokenizeAny(u8, s, " \t");
    while (words.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, "-MBR")) {
            mbr = true;
        } else {
            disk_text = word;
        }
    }
    const disk_no = std.fmt.parseInt(u32, disk_text, 10) catch {
        zdos.print(usage);
        return 1;
    };
    const info = sys.diskInfo(disk_no) orelse {
        zdos.printf("No disk {d}\n", .{disk_no});
        return 1;
    };
    if (info.sector_size != sys.sector or info.sectors == 0) {
        zdos.printf("Disk {d} has no readable disk or its sectors are not 512 bytes\n", .{disk_no});
        return 1;
    }
    if (mbr) {
        sys.syncDisk(disk_no) catch {
            zdos.print("Cannot sync filesystems on this disk before writing boot code\n");
            return 1;
        };
        return if (writeBootCode(disk_no)) 0 else 1;
    }
    const d: Disk = .{ .index = disk_no, .sectors = info.sectors };
    if (refusesBoot(disk_no)) return 1;
    const t = loadTable(disk_no) orelse return 1;
    showDisk(d, &t);
    return menu(d);
}

// FDISK <disk> -MBR: the partition table and disk signature are kept.
fn writeBootCode(disk: u32) bool {
    var sec: [sys.sector]u8 = undefined;
    if (!readSec(disk, 0, &sec)) {
        zdos.printf("Cannot read disk {d}\n", .{disk});
        return false;
    }
    // Sector 0 of a single-volume disk (FAT, NTFS, exFAT) is its boot sector:
    // the code would overwrite it.
    if (sys.bootSectorKind(&sec)) |kind| {
        zdos.printf("Disk {d} is one {s} volume with no partition table: it has no MBR\n", .{ disk, kind });
        return false;
    }
    @memcpy(sec[0..440], mbr_code[0..440]);
    sec[510] = 0x55;
    sec[511] = 0xAA;
    if (!writeSec(disk, 0, &sec)) {
        zdos.printf("Cannot write disk {d}\n", .{disk});
        return false;
    }
    zdos.printf("Boot code written to disk {d}; the partition table is kept\n", .{disk});
    return true;
}

fn listDisks() void {
    var i: u32 = 0;
    while (i < sys.diskCount()) : (i += 1) {
        const info = sys.diskInfo(i) orelse continue;
        const mb = @as(u64, info.sectors) * @as(u64, info.sector_size) / (1 << 20);
        zdos.printf("Disk {d}: {d} MB{s}\n", .{ i, mb, if (info.removable) ", removable" else "" });
    }
}

// 0 if it has none.
fn bootLetter() ?u8 {
    var i: u32 = 0;
    while (true) : (i += 1) {
        const drive = sys.driveAt(i) orelse return null;
        if (drive.boot) return drive.letter;
    }
}

// When it can't be told which disk ZDOS started from.
fn refusesBoot(disk: u32) bool {
    const letter = bootLetter() orelse {
        zdos.print("No drive was started from: FDISK won't change any disk\n");
        return true;
    };
    if (letter == 0) {
        zdos.print("The drive ZDOS started from has no letter: FDISK\ncan't tell its disk, so it changes nothing\n");
        return true;
    }
    const where = sys.driveLocation(letter) catch {
        zdos.print("FDISK is only for the BIOS version of ZDOS\n");
        return true;
    };
    if (where.disk == disk) {
        zdos.printf("Disk {d} is the disk ZDOS was started from: FDISK won't change it\n", .{disk});
        return true;
    }
    return false;
}

// Each choice reads the table again, so what was written is seen.
fn menu(d: Disk) u8 {
    while (true) {
        printMenu();
        const choice = readChoice();
        if (choice == '0') return 0;
        if (choice >= '1' and choice <= '3') {
            sys.syncDisk(d.index) catch {
                zdos.print("Cannot sync filesystems on this disk before changing it\n");
                continue;
            };
        }
        var t = loadTable(d.index) orelse return 1;
        switch (choice) {
            '1' => createPartition(d, &t),
            '2' => setActive(d, &t),
            '3' => deletePartition(d, &t),
            '4' => showDisk(d, &t),
            else => {},
        }
    }
}

fn printMenu() void {
    zdos.print("\n1. Create a partition\n2. Set the active partition\n");
    zdos.print("3. Delete a partition\n4. Display partitions\n0. Exit\n\nChoice? ");
}

fn showDisk(d: Disk, t: *const Table) void {
    zdos.printf("\nDisk {d}: {d} MB\n", .{ d.index, d.sectors / sectors_per_mb });
    showPartitions(t);
}

fn showPartitions(t: *const Table) void {
    var refs: [max_refs]Ref = undefined;
    const n = numbered(t, &refs);
    if (n == 0) {
        zdos.print("No partitions\n");
        return;
    }
    zdos.print("No.  Where    Type  Use       Start sector  Size MB  Active\n");
    for (refs[0..n], 1..) |r, num| {
        const s = slotOf(t, r);
        const active: []const u8 = if (s.boot) "Active" else "";
        zdos.printf("{d:>3}  {s:<7}  0x{x:0>2}  {s:<8}  {d:>12}  {d:>7}  {s}\n", .{
            num,
            whereName(r),
            s.kind,
            fatName(s.kind),
            s.start,
            s.sectors / sectors_per_mb,
            active,
        });
    }
}

// Null, with a message, if the disk can't be read or is one FAT volume or GPT.
fn loadTable(disk: u32) ?Table {
    var sec: [sys.sector]u8 = undefined;
    if (!readSec(disk, 0, &sec)) {
        zdos.printf("Cannot read disk {d}\n", .{disk});
        return null;
    }
    // Its boot code would be read as partition entries, and a change would
    // overwrite the file system's boot sector:
    if (sys.bootSectorKind(&sec)) |kind| {
        zdos.printf("Disk {d} is one {s} volume with no partition table.\n", .{ disk, kind });
        zdos.print("FDISK can't partition it.\n");
        return null;
    }
    var t = Table{
        .prim = [_]Slot{.{}} ** 4,
        .logical = undefined,
        .nlogical = 0,
        .ext = null,
    };
    // No signature: blank:
    if (!hasSignature(&sec)) return t;
    for (0..4) |i| t.prim[i] = slotAt(&sec, 446 + 16 * i);
    for (t.prim) |p| {
        if (p.kind == 0xEE) {
            zdos.printf("Disk {d} has a GPT partition table: GPT disks are not supported yet\n", .{disk});
            return null;
        }
    }
    t.ext = firstExtended(&t.prim);
    if (t.ext) |e| readChain(disk, &t, t.prim[e].start);
    return t;
}

// The first 05 or 0F entry with a start (as CHKDSK).
fn firstExtended(prim: *const [4]Slot) ?usize {
    for (prim, 0..) |p, i| {
        if (isExtended(p.kind) and p.start != 0) return i;
    }
    return null;
}

// A record's first entry is a logical partition (start relative
// to the record); the second points to the next record (start
// relative to the extended partition).
fn readChain(disk: u32, t: *Table, ext_start: u64) void {
    var at = ext_start;
    var records: usize = 0;
    while (records < max_logical) : (records += 1) {
        var ebr: [sys.sector]u8 = undefined;
        if (!readSec(disk, at, &ebr)) return;
        if (!hasSignature(&ebr)) return;
        const here = slotAt(&ebr, 446);
        if (here.kind != 0) {
            t.logical[t.nlogical] = .{
                .ebr = at,
                .slot = .{ .kind = here.kind, .start = at + here.start, .sectors = here.sectors },
            };
            t.nlogical += 1;
        }
        const next = slotAt(&ebr, 462);
        if (!isExtended(next.kind)) return;
        at = ext_start + next.start;
    }
}

// CHKDSK's numbering: primary entries in slot order,
// then logical ones in chain order.
fn numbered(t: *const Table, refs: *[max_refs]Ref) usize {
    var n: usize = 0;
    for (t.prim, 0..) |p, i| {
        if (p.kind == 0) continue;
        refs[n] = .{ .logical = false, .index = i };
        n += 1;
    }
    for (0..t.nlogical) |i| {
        refs[n] = .{ .logical = true, .index = i };
        n += 1;
    }
    return n;
}

fn partCount(t: *const Table) usize {
    var refs: [max_refs]Ref = undefined;
    return numbered(t, &refs);
}

fn refFor(t: *const Table, num: u32) ?Ref {
    var refs: [max_refs]Ref = undefined;
    const n = numbered(t, &refs);
    if (num == 0 or @as(usize, num) > n) return null;
    return refs[num - 1];
}

fn slotOf(t: *const Table, r: Ref) Slot {
    return if (r.logical) t.logical[r.index].slot else t.prim[r.index];
}

fn whereName(r: Ref) []const u8 {
    return if (r.logical) "Logical" else "Primary";
}

// "Extended" for 05 and 0F, "" for non-FAT.
fn fatName(kind: u8) []const u8 {
    return switch (kind) {
        0x05, 0x0F => "Extended",
        0x01, 0x11 => "FAT12",
        0x04, 0x06, 0x0E, 0x14, 0x16, 0x1E => "FAT16",
        0x0B, 0x0C, 0x1B, 0x1C => "FAT32",
        else => "",
    };
}

fn isExtended(kind: u8) bool {
    return kind == 0x05 or kind == 0x0F;
}

// Only a primary partition can be active.
fn setActive(d: Disk, t: *Table) void {
    showPartitions(t);
    const num = askNumber("Partition number to make active? ") orelse {
        zdos.print("Nothing was changed.\n");
        return;
    };
    const r = refFor(t, num) orelse {
        zdos.printf("No partition {d}\n", .{num});
        return;
    };
    if (r.logical) {
        zdos.print("Only a primary partition can be the active one\n");
        return;
    }
    if (isExtended(t.prim[r.index].kind)) {
        zdos.print("An extended partition can't be the active one\n");
        return;
    }
    for (&t.prim) |*p| p.boot = false;
    t.prim[r.index].boot = true;
    if (commit(d, t)) {
        zdos.printf("Partition {d} is the active partition\n", .{num});
    }
}

// The extended partition goes only when it has no logical partitions left;
// a logical partition's boot record is cleared.
fn deletePartition(d: Disk, t: *Table) void {
    showPartitions(t);
    const num = askNumber("Partition number to delete? ") orelse {
        zdos.print("Nothing was changed.\n");
        return;
    };
    const r = refFor(t, num) orelse {
        zdos.printf("No partition {d}\n", .{num});
        return;
    };
    const s = slotOf(t, r);
    if (!r.logical and isExtended(s.kind) and t.ext == r.index and t.nlogical > 0) {
        zdos.print("Delete its logical partitions first\n");
        return;
    }
    zdos.printf("Delete partition {d} ({s}, type 0x{x:0>2}, {d} MB)? (Y/N) ", .{
        num,
        whereName(r),
        s.kind,
        s.sectors / sectors_per_mb,
    });
    if (!sys.askYes()) {
        zdos.print("Nothing was changed.\n");
        return;
    }
    if (r.logical) {
        if (!clearRecord(d.index, t.logical[r.index].ebr)) {
            zdos.printf("Cannot clear the boot record on disk {d}\n", .{d.index});
            return;
        }
        removeLogical(t, r.index);
    } else {
        t.prim[r.index] = .{};
        if (t.ext == r.index) t.ext = null;
    }
    if (commit(d, t)) {
        zdos.print("Partition deleted.\n");
    }
}

// The chain is written again without it.
fn removeLogical(t: *Table, i: usize) void {
    var k = i;
    while (k + 1 < t.nlogical) : (k += 1) t.logical[k] = t.logical[k + 1];
    t.nlogical -= 1;
}

// The partition itself is untouched.
fn clearRecord(disk: u32, ebr: u64) bool {
    var sec: [sys.sector]u8 = undefined;
    if (!readSec(disk, ebr, &sec)) return false;
    @memset(sec[446..478], 0);
    return writeSec(disk, ebr, &sec);
}

// Primary or extended (then its first logical too), or primary or
// logical once there is an extended partition.
fn createPartition(d: Disk, t: *Table) void {
    if (t.ext == null) {
        // Without an extended partition, Enter gives a primary one:
        zdos.print("Create a primary (1) or an extended (2) partition? (Enter for 1) ");
        switch (readChoice()) {
            0, '1' => createPrimary(d, t),
            '2' => if (createExtended(d, t)) createLogical(d, t),
            else => zdos.print("Nothing was changed.\n"),
        }
        return;
    }
    zdos.print("Create a primary (1) or a logical (2) partition? ");
    const choice = readChoice();
    if (choice == '1') {
        createPrimary(d, t);
    } else if (choice == '2') {
        createLogical(d, t);
    } else {
        zdos.print("Nothing was changed.\n");
    }
}

fn roomForPartition(t: *const Table) bool {
    if (partCount(t) < sys.max_parts and t.nlogical < max_logical) return true;
    zdos.printf("The disk has {d} partitions already\n", .{sys.max_parts});
    return false;
}

// In the first free entry, after the last primary one.
fn createPrimary(d: Disk, t: *Table) void {
    if (!roomForPartition(t)) return;
    const slot = freePrimary(t) orelse {
        zdos.print("All four primary entries are used\n");
        return;
    };
    const start = primaryStart(t) orelse return;
    const kind = askType() orelse return;
    const size = askSize(spanFree(start, d.sectors)) orelse return;
    t.prim[slot] = .{ .kind = kind, .start = start, .sectors = size };
    clearStart(d.index, start);
    if (commit(d, t)) {
        zdos.printf("Partition made: start sector {d}, {d} MB\n", .{ start, size / sectors_per_mb });
    }
}

// After the last primary one. True if it was written.
fn createExtended(d: Disk, t: *Table) bool {
    if (!roomForPartition(t)) return false;
    const slot = freePrimary(t) orelse {
        zdos.print("All four primary entries are used\n");
        return false;
    };
    const start = primaryStart(t) orelse return false;
    const size = askSize(spanFree(start, d.sectors)) orelse return false;
    t.prim[slot] = .{ .kind = extended_type, .start = start, .sectors = size };
    t.ext = slot;
    // An old boot sector left there would be read as logical partitions:
    clearStart(d.index, start);
    if (!commit(d, t)) return false;
    zdos.print("Extended partition made. Its logical partitions go inside it.\n");
    return true;
}

// After the last logical one: its boot record at the first 1 MB
// boundary, the partition 1 MB after.
fn createLogical(d: Disk, t: *Table) void {
    if (!roomForPartition(t)) return;
    const e = t.ext orelse {
        zdos.print("There is no extended partition\n");
        return;
    };
    const ext_start = t.prim[e].start;
    const ext_end = ext_start + t.prim[e].sectors;
    const ebr = alignUp(logicalEnd(t, ext_start));
    const start = ebr + align_sectors;
    const kind = askType() orelse return;
    const size = askSize(spanFree(start, ext_end)) orelse return;
    t.logical[t.nlogical] = .{
        .ebr = ebr,
        .slot = .{ .kind = kind, .start = start, .sectors = size },
    };
    t.nlogical += 1;
    clearStart(d.index, start);
    if (commit(d, t)) {
        zdos.printf("Logical partition made: start sector {d}, {d} MB\n", .{ start, size / sectors_per_mb });
    }
}

fn freePrimary(t: *const Table) ?usize {
    for (t.prim, 0..) |p, i| {
        if (p.kind == 0) return i;
    }
    return null;
}

// After the last primary one, on a 1 MB boundary, never before 1 MB.
// Null past an MBR entry's 32-bit start (2 TB).
fn primaryStart(t: *const Table) ?u64 {
    var end: u64 = align_sectors;
    for (t.prim) |p| {
        if (p.kind != 0) end = @max(end, p.start + p.sectors);
    }
    const start = alignUp(end);
    if (start > std.math.maxInt(u32)) {
        zdos.print("The free space is past 2 TB, where an MBR partition can't start\n");
        return null;
    }
    return start;
}

// The extended partition's start if none.
fn logicalEnd(t: *const Table, ext_start: u64) u64 {
    var end = ext_start;
    for (t.logical[0..t.nlogical]) |l| end = @max(end, l.slot.start + l.slot.sectors);
    return end;
}

fn alignUp(v: u64) u64 {
    return (v + align_sectors - 1) / align_sectors * align_sectors;
}

// At most what one MBR entry can hold; 0 if start is not before end.
fn spanFree(start: u64, end: u64) u64 {
    if (start >= end) return 0;
    return @min(end - start, std.math.maxInt(u32));
}

// Whole MB typed, or Enter for all the free space. Null, with a
// message, if there is no room or the answer doesn't fit.
fn askSize(free: u64) ?u64 {
    const free_mb = free / sectors_per_mb;
    if (free_mb == 0) {
        zdos.print("There is no free space here\n");
        return null;
    }
    zdos.printf("Size in MB (Enter for all {d} MB free)? ", .{free_mb});
    var buf: [16]u8 = undefined;
    const line = readLine(&buf);
    if (line.len == 0) return free_mb * sectors_per_mb;
    const wanted = std.fmt.parseInt(u64, line, 10) catch {
        zdos.print("Not a number of MB\n");
        return null;
    };
    if (wanted == 0 or wanted > free_mb) {
        zdos.printf("Enter 1 to {d} MB\n", .{free_mb});
        return null;
    }
    return wanted * sectors_per_mb;
}

// A number from the list (Enter: FAT16), or 5 for a hex type.
fn askType() ?u8 {
    zdos.print("Partition type:\n");
    zdos.print(" 1 FAT12              (01)\n");
    zdos.print(" 2 FAT16              (06)\n");
    zdos.print(" 3 FAT32, LBA         (0C)\n");
    zdos.print(" 4 Linux              (83)\n");
    zdos.print(" 5 Other, in hex\n");
    zdos.print("Type (Enter for 2)? ");
    var buf: [8]u8 = undefined;
    const line = readLine(&buf);
    if (line.len == 0) return default_type;
    if (std.mem.eql(u8, line, "1")) return 0x01;
    if (std.mem.eql(u8, line, "2")) return default_type;
    if (std.mem.eql(u8, line, "3")) return 0x0C;
    if (std.mem.eql(u8, line, "4")) return 0x83;
    if (std.mem.eql(u8, line, "5")) return askHexType();
    zdos.print("Not a type from the list (1 to 5)\n");
    return null;
}

// 00 is empty, 05 and 0F are extended, EE is GPT.
fn askHexType() ?u8 {
    zdos.print("Hex type (00 to FF)? ");
    var buf: [8]u8 = undefined;
    const line = readLine(&buf);
    const digits = if (line.len > 2 and line[0] == '0' and (line[1] == 'x' or line[1] == 'X')) line[2..] else line;
    const v = std.fmt.parseInt(u8, digits, 16) catch {
        zdos.print("Not a hex type (00 to FF)\n");
        return null;
    };
    switch (v) {
        0x00, 0x05, 0x0F, 0xEE => {
            zdos.print("That type can't be used: 00 is empty, 05 and 0F are\nextended, EE is GPT\n");
            return null;
        },
        else => return v,
    }
}

fn askNumber(prompt: []const u8) ?u32 {
    zdos.print(prompt);
    var buf: [16]u8 = undefined;
    const line = readLine(&buf);
    return std.fmt.parseInt(u32, line, 10) catch null;
}

// An old file system there would show its old size. Until FORMAT, the
// partition has no drive letter.
fn clearStart(disk: u32, start: u64) void {
    var sec: [sys.sector]u8 = undefined;
    @memset(&sec, 0);
    _ = writeSec(disk, start, &sec);
}

// The logical boot records, then the MBR; tells ZDOS the disk changed.
fn commit(d: Disk, t: *const Table) bool {
    const ok = writeChain(d.index, t) and writeMbr(d.index, t);
    sys.diskChanged(d.index);
    if (!ok) zdos.printf("Cannot write disk {d}: it may be partly changed\n", .{d.index});
    return ok;
}

// Entry 1: the partition, entry 2: the next record. If the first record
// was deleted, a record at the extended partition's start with only
// entry 2 links to the chain.
fn writeChain(disk: u32, t: *const Table) bool {
    if (t.nlogical == 0) return true;
    const ext = t.ext orelse return false;
    const ext_start = t.prim[ext].start;
    if (t.logical[0].ebr != ext_start) {
        var sec: [sys.sector]u8 = undefined;
        if (!readSec(disk, ext_start, &sec)) return false;
        putSlot(&sec, 446, .{});
        putSlot(&sec, 462, linkTo(t.logical[0], ext_start));
        sec[510] = 0x55;
        sec[511] = 0xAA;
        if (!writeSec(disk, ext_start, &sec)) return false;
    }
    for (t.logical[0..t.nlogical], 0..) |l, i| {
        const next: Slot = if (i + 1 < t.nlogical) linkTo(t.logical[i + 1], ext_start) else .{};
        var sec: [sys.sector]u8 = undefined;
        if (!readSec(disk, l.ebr, &sec)) return false;
        putSlot(&sec, 446, .{
            .kind = l.slot.kind,
            .start = l.slot.start - l.ebr,
            .sectors = l.slot.sectors,
        });
        putSlot(&sec, 462, next);
        sec[510] = 0x55; // a boot record carries the signature, as the MBR does
        sec[511] = 0xAA;
        if (!writeSec(disk, l.ebr, &sec)) return false;
    }
    return true;
}

// Its start counts from the extended partition; it spans the
// record and the partition.
fn linkTo(l: Logical, ext_start: u64) Slot {
    return .{
        .kind = 0x05,
        .start = l.ebr - ext_start,
        .sectors = l.slot.start + l.slot.sectors - l.ebr,
    };
}

// Keeps the boot code above the entries.
fn writeMbr(disk: u32, t: *const Table) bool {
    var sec: [sys.sector]u8 = undefined;
    if (!readSec(disk, 0, &sec)) return false;
    for (t.prim, 0..) |p, i| putSlot(&sec, 446 + 16 * i, p);
    sec[510] = 0x55;
    sec[511] = 0xAA;
    return writeSec(disk, 0, &sec);
}

// LBA form: CHS is FE FF FF for the start and the end.
fn putSlot(sec: *[sys.sector]u8, off: usize, s: Slot) void {
    const e = sec[off..][0..16];
    @memset(e, 0);
    if (s.kind == 0) return;
    e[0] = if (s.boot) 0x80 else 0x00;
    e[1] = 0xFE;
    e[2] = 0xFF;
    e[3] = 0xFF;
    e[4] = s.kind;
    e[5] = 0xFE;
    e[6] = 0xFF;
    e[7] = 0xFF;
    std.mem.writeInt(u32, e[8..12], @truncate(s.start), .little);
    std.mem.writeInt(u32, e[12..16], @truncate(s.sectors), .little);
}

// As on disk: a logical partition's start is relative to its sector.
fn slotAt(sec: []const u8, off: usize) Slot {
    return .{
        .kind = sec[off + 4],
        .boot = sec[off] == 0x80,
        .start = sys.rd32(sec, off + 8),
        .sectors = sys.rd32(sec, off + 12),
    };
}

fn hasSignature(sec: []const u8) bool {
    return sec[510] == 0x55 and sec[511] == 0xAA;
}

fn readSec(disk: u32, lba: u64, buf: *[sys.sector]u8) bool {
    sys.readSectors(disk, lba, buf) catch return false;
    return true;
}

fn writeSec(disk: u32, lba: u64, data: *const [sys.sector]u8) bool {
    sys.writeSectors(disk, lba, data) catch return false;
    return true;
}

// The first character of a line; 0 for an empty line.
fn readChoice() u8 {
    var buf: [8]u8 = undefined;
    const line = readLine(&buf);
    return if (line.len > 0) line[0] else 0;
}

fn readLine(buf: []u8) []const u8 {
    var n: usize = 0;
    while (true) {
        const key = zdos.readKey();
        if (key.char == '\r' or key.char == '\n') break;
        if (key.char == 0x08) {
            if (n > 0) {
                n -= 1;
                zdos.print("\x08 \x08");
            }
            continue;
        }
        if (key.char < 0x20 or key.char > 0x7E) continue;
        if (n < buf.len) {
            buf[n] = @intCast(key.char);
            n += 1;
            zdos.print(buf[n - 1 .. n]);
        }
    }
    zdos.print("\n");
    return std.mem.trim(u8, buf[0..n], " \t");
}
