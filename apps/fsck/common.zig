// Shared by CHKMFS and CHKEXT2: CHKDSK's command line and check/repair
// flow, sector I/O, and the problem counters.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const sys = @import("../zdos/system.zig");
const users = @import("../zdos/users.zig");

pub const sector = 512;

// By drive letter, or by disk and absolute start sector.
pub const Volume = struct {
    disk: u32 = 0,
    letter: u8 = 0,
    start: u64 = 0,
    sectors: u64 = 0,
};

pub var vol: Volume = .{};
pub var fixing = false; // the repair pass: fixes are made and reported as fixed
pub var problems: u32 = 0;
pub var fixes: u32 = 0;
pub var failures: u32 = 0; // problems the repair couldn't fix
pub var deleting = false; // -D: what can't be fixed is deleted
pub var deletable: u32 = 0; // files only deleting would fix

pub const Checker = struct {
    tool: []const u8, // "CHKMFS"
    fs_name: []const u8, // "Minix 3"
    // sb: bytes 1024 to 2047 of the volume:
    probe: *const fn (sb: *const [1024]u8) bool,
    // The counters say what was found. false: not checked at all:
    analyse: *const fn () bool,
    // After analyse found problems; false if some failed:
    repair: *const fn () bool,
};

// -A: as -D, without questions, and a restart after a repair
const Fix = enum { none, fix, delete, auto };

// CHKxxx X: [-F|-D|-A] or CHKxxx [disk [partition] [-F|-D|-A]]
pub fn run(args: []const u8, c: Checker) u8 {
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    const first = words.next() orelse {
        listDisks();
        return usage(c);
    };
    if (users.diskToolDenied(c.tool)) return 1;
    if (driveLetter(first)) |letter| {
        var want: Fix = .none;
        while (words.next()) |word| {
            want = fixOption(word) orelse return usage(c);
        }
        vol = volumeByLetter(letter, c) orelse return 1;
        return check(c, want, 0, 0);
    }
    const disk = std.fmt.parseInt(u32, first, 10) catch return usage(c);
    var part: ?u32 = null;
    var want: Fix = .none;
    while (words.next()) |word| {
        if (fixOption(word)) |f| {
            want = f;
        } else {
            part = std.fmt.parseInt(u32, word, 10) catch return usage(c);
        }
    }
    const p = part orelse {
        if (want != .none) return usage(c);
        listPartitions(disk, c);
        return 0;
    };
    if (p == 0) return usage(c);
    vol = findVolume(disk, p, c) orelse return 1;
    return check(c, want, disk, p);
}

// -F fixes; -D fixes and deletes the files that can't be fixed;
// -A does that unasked and restarts
fn fixOption(word: []const u8) ?Fix {
    if (std.ascii.eqlIgnoreCase(word, "-F")) return .fix;
    if (std.ascii.eqlIgnoreCase(word, "-D")) return .delete;
    if (std.ascii.eqlIgnoreCase(word, "-A")) return .auto;
    return null;
}

fn usage(c: Checker) u8 {
    zdos.printf("Usage: {s} X: [-F|-D|-A] or {s} [disk [partition] [-F|-D|-A]]\n", .{ c.tool, c.tool });
    return 1;
}

fn driveLetter(word: []const u8) ?u8 {
    if (word.len == 2 and word[1] == ':' and std.ascii.isAlphabetic(word[0])) return std.ascii.toUpper(word[0]);
    if (word.len == 1 and std.ascii.isAlphabetic(word[0])) return std.ascii.toUpper(word[0]);
    return null;
}

// Check; with -F or -D ask, repair, check again, offer a restart;
// -A asks nothing and restarts.
fn check(c: Checker, want: Fix, disk: u32, p: u32) u8 {
    if (vol.letter != 0) {
        zdos.printf("Checking the {s} volume of drive {c}:\n", .{ c.fs_name, vol.letter });
    } else {
        zdos.printf("Checking the {s} volume on disk {d}, partition {d}:\n", .{ c.fs_name, disk, p });
    }
    resetCounts();
    if (!c.analyse()) return 1;
    if (problems == 0) return 0;
    if (want == .none) {
        if (vol.letter != 0) {
            zdos.printf("Run {s} {c}: -F to fix {d} problems. Nothing was changed.\n", .{ c.tool, vol.letter, problems });
        } else {
            zdos.printf("Run {s} {d} {d} -F to fix {d} problems. Nothing was changed.\n", .{ c.tool, disk, p, problems });
        }
        if (deletable > 0) deleteHint(c, disk, p);
        return 1;
    }
    if (want == .auto) {
        zdos.print("Fixing them (-A), deleting the files that can't be repaired.\n");
    } else {
        const also: []const u8 = if (want == .delete) ", deleting the files that can't be repaired" else "";
        if (vol.letter != 0) {
            zdos.printf("Fix these problems on drive {c}:{s}? (Y/N) ", .{ vol.letter, also });
        } else {
            zdos.printf("Fix these problems on disk {d}, partition {d}{s}? (Y/N) ", .{ disk, p, also });
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
    resetCounts();
    fixing = true;
    deleting = want == .delete or want == .auto;
    const repaired = c.repair();
    fixing = false;
    deleting = false;
    zdos.printf("{d} fixed, {d} could not be fixed.\n", .{ fixes, failures });
    if (deletable > 0) deleteHint(c, disk, p);
    const made = fixes;
    if (made > 0) {
        if (vol.letter != 0) sys.driveChanged(vol.letter) else sys.diskChanged(disk);
    }
    zdos.print("Checking the disk again:\n");
    resetCounts();
    const checked = c.analyse();
    const clean = repaired and checked and problems == 0;
    if (made > 0) {
        if (want == .auto) autoRestart(clean) else askRestart();
    }
    return if (clean) 0 else 1;
}

// -A: the kernel reads a repaired volume again by itself; only one
// with a drive letter may have programs' files open on it. Only when
// the second check is clean: problems left would come back at every
// start (a loop when run from AUTOEXEC.CMD).
fn autoRestart(clean: bool) void {
    if (!hasLetter(vol.letter, vol.disk, vol.start)) return zdos.print("It has no drive letter: no restart needed.\n");
    if (!clean) return zdos.print("Problems are left: no restart. Restart before using the disk again.\n");
    restartCountdown();
}

// A volume checked by disk and partition may have one too. Unknown
// (UEFI can't say where a drive is): counted as having one.
pub fn hasLetter(letter: u8, disk: u32, start: u64) bool {
    if (letter != 0) return true;
    var unknown = false;
    var l: u8 = 'A';
    while (l <= 'Z') : (l += 1) {
        const loc = sys.driveLocation(l) catch |err| {
            if (err == error.NotSupported) unknown = true;
            continue;
        };
        if (loc.disk == disk and loc.start == start) return true;
    }
    return unknown;
}

// Ten seconds, a dot each; any key stays.
pub fn restartCountdown() void {
    while (zdos.pollKey() != null) {} // keys typed before don't count
    zdos.print("Restarting in 10 seconds, so the repaired disk is read again (any key: stay) ");
    var tick: u32 = 0;
    while (tick < 100) : (tick += 1) {
        zdos.sleep(100);
        if (zdos.pollKey() != null) {
            zdos.print("\nNot restarting. Restart before using the disk again.\n");
            return;
        }
        if (tick % 10 == 9) zdos.print(".");
    }
    zdos.print("\n");
    sys.restart();
}

fn resetCounts() void {
    problems = 0;
    fixes = 0;
    failures = 0;
    deletable = 0;
}

fn deleteHint(c: Checker, disk: u32, p: u32) void {
    if (vol.letter != 0) {
        zdos.printf("{d} files can't be repaired: {s} {c}: -D fixes the rest and deletes them.\n", .{ deletable, c.tool, vol.letter });
    } else {
        zdos.printf("{d} files can't be repaired: {s} {d} {d} -D fixes the rest and deletes them.\n", .{ deletable, c.tool, disk, p });
    }
}

fn askRestart() void {
    if (!hasLetter(vol.letter, vol.disk, vol.start)) return zdos.print("It has no drive letter: no restart needed.\n");
    zdos.print("Restart the computer now, so the repaired disk is read again? (Y/N) ");
    if (sys.askYes()) sys.restart();
    zdos.print("Restart the computer before using the disk again.\n");
}

pub fn summary() void {
    if (fixing) return; // the repair's own line follows
    if (problems == 0) {
        zdos.print("No errors found.\n");
    } else {
        zdos.printf("{d} problems found.\n", .{problems});
    }
}

// In the repair pass: one that could not be fixed.
pub fn report(comptime fmt: []const u8, args: anytype) void {
    if (fixing) failures += 1 else problems += 1;
    zdos.printf("  " ++ fmt ++ "\n", args);
}

// The check reports it with report.
pub fn fixed(comptime fmt: []const u8, args: anytype) void {
    fixes += 1;
    zdos.printf("  fixed: " ++ fmt ++ "\n", args);
}

// A cross-link's copy: fixed, but what the file
// holds there is another file's data.
pub fn fixedCross(comptime fmt: []const u8, args: anytype) void {
    fixes += 1;
    zdos.printf("  Check this file: fixed crosslink, had data of another file: " ++ fmt ++ "\n", args);
}

// A file only deleting fixes: the check and -F report it (-F as
// not fixed); -D deletes it (the checker does, then calls deleted)
pub fn onlyByDeleting(comptime fmt: []const u8, args: anytype) void {
    deletable += 1;
    if (fixing) {
        report("cannot fix: " ++ fmt ++ " (-D deletes this file)", args);
    } else report(fmt ++ " (-D deletes this file)", args);
}

pub fn deleted(comptime fmt: []const u8, args: anytype) void {
    fixes += 1;
    zdos.printf("  deleted: " ++ fmt ++ "\n", args);
}

// Reported in the check; done: whether the repair fixed it.
pub fn problem(done: bool, comptime fmt: []const u8, args: anytype) void {
    if (!fixing) return report(fmt, args);
    if (done) fixed(fmt, args) else report("cannot fix: " ++ fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    zdos.printf("  warning: " ++ fmt ++ "\n", args);
}

// off and buf.len are multiples of 512.
pub fn read(off: u64, buf: []u8) bool {
    std.debug.assert(off % sector == 0 and buf.len % sector == 0);
    const lba = off / sector;
    if (lba + buf.len / sector > vol.sectors) return false;
    if (vol.letter != 0) {
        sys.driveRead(vol.letter, lba, buf) catch return false;
        return true;
    }
    sys.readSectors(vol.disk, vol.start + lba, buf) catch return false;
    return true;
}

pub fn write(off: u64, data: []const u8) bool {
    std.debug.assert(fixing and off % sector == 0 and data.len % sector == 0);
    const lba = off / sector;
    if (lba + data.len / sector > vol.sectors) return false;
    if (vol.letter != 0) {
        sys.driveWrite(vol.letter, lba, data) catch return false;
        return true;
    }
    sys.writeSectors(vol.disk, vol.start + lba, data) catch return false;
    return true;
}

pub fn rd16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

pub fn rd32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

pub fn wr16(b: []u8, at: usize, v: u16) void {
    std.mem.writeInt(u16, b[at..][0..2], v, .little);
}

pub fn wr32(b: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, b[at..][0..4], v, .little);
}

// All clear; null (and a message) without memory.
pub fn bitmap(n: u64) ?[]u8 {
    const m = zdos.allocator.alloc(u8, @intCast((n + 7) / 8)) catch {
        zdos.print("Out of memory\n");
        return null;
    };
    @memset(m, 0);
    return m;
}

pub fn bitGet(map: []const u8, i: u64) bool {
    return map[@intCast(i / 8)] & (@as(u8, 1) << @intCast(i % 8)) != 0;
}

pub fn bitSet(map: []u8, i: u64) void {
    map[@intCast(i / 8)] |= @as(u8, 1) << @intCast(i % 8);
}

pub fn bitClr(map: []u8, i: u64) void {
    map[@intCast(i / 8)] &= ~(@as(u8, 1) << @intCast(i % 8));
}

// Both file systems' superblocks are there.
pub fn readSuper(out: *[1024]u8) bool {
    return read(1024, out);
}

fn probeAt(disk: u32, start: u64, c: Checker) bool {
    var sb: [1024]u8 = undefined;
    sys.readSectors(disk, start + 2, &sb) catch return false;
    return c.probe(&sb);
}

fn listDisks() void {
    var i: u32 = 0;
    while (i < sys.diskCount()) : (i += 1) {
        const d = sys.diskInfo(i) orelse continue;
        zdos.printf("Disk {d}: {d} sectors of {d} bytes{s}\n", .{ i, d.sectors, d.sector_size, if (d.removable) ", removable" else "" });
    }
}

fn listPartitions(disk: u32, c: Checker) void {
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
        const ours = probeAt(disk, p.start, c);
        if (p.whole_disk) {
            zdos.printf("Disk {d} has no partition table: partition 1 is the whole disk, ", .{disk});
        } else if (p.kind != 0) {
            zdos.printf("Partition {d}: type 0x{x:0>2}, ", .{ p.number, p.kind });
        } else zdos.printf("Partition {d}: GPT{s}, ", .{ p.number, if (p.esp) " EFI system" else "" });
        zdos.printf("start sector {d}, {d} sectors, {s}{s}\n", .{ p.start, p.sectors, if (ours) "" else "not ", c.fs_name });
    }
}

fn findVolume(disk: u32, part: u32, c: Checker) ?Volume {
    const info = sys.diskInfo(disk) orelse {
        zdos.printf("No disk {d}\n", .{disk});
        return null;
    };
    if (info.sector_size != sector) {
        zdos.printf("Disk {d} does not use 512-byte sectors\n", .{disk});
        return null;
    }
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
    if (p.start > info.sectors or p.sectors > info.sectors - p.start) {
        zdos.printf("Partition {d} goes past the end of the disk\n", .{part});
        return null;
    }
    if (!probeAt(disk, p.start, c)) {
        zdos.printf("Partition {d} is not a {s} volume\n", .{ part, c.fs_name });
        return null;
    }
    return .{ .disk = disk, .start = p.start, .sectors = p.sectors };
}

fn volumeByLetter(letter: u8, c: Checker) ?Volume {
    _ = zdos.driveInfo(letter) catch {
        zdos.printf("No drive {c}:\n", .{letter});
        return null;
    };
    const sectors = sys.driveSectors(letter) catch |err| {
        zdos.printf("Cannot read drive {c}: {s}\n", .{ letter, zdos.message(err) });
        return null;
    };
    var sb: [1024]u8 = undefined;
    sys.driveRead(letter, 2, &sb) catch |err| {
        zdos.printf("Cannot read drive {c}: {s}\n", .{ letter, zdos.message(err) });
        return null;
    };
    if (!c.probe(&sb)) {
        zdos.printf("Drive {c}: is not a {s} volume\n", .{ letter, c.fs_name });
        return null;
    }
    return .{ .letter = letter, .sectors = sectors };
}

// For new inodes' times.
pub fn unixNow() u32 {
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
