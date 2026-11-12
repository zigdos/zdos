// SYS X: [-O]: makes a volume bootable, as DOS's SYS. -O: no
// questions, files are replaced in place (no temporary copy).
const std = @import("std");
const builtin = @import("builtin");
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

// The UEFI builds are freestanding too:
const is_bios = builtin.os.tag == .freestanding and builtin.cpu.arch == .x86;
// Passed in by build.zig:
const vbr16: []const u8 = if (is_bios) @embedFile("vbr16.bin") else "";
const vbr32: []const u8 = if (is_bios) @embedFile("vbr32.bin") else "";

const usage = "Usage: SYS X: [-O]\n  -O  replace the files without asking, in place (no temporary copy)\n";
// The fallback boot file of removable disks and ESPs:
const boot_file = if (builtin.cpu.arch == .aarch64) "\\EFI\\BOOT\\BOOTAA64.EFI" else "\\EFI\\BOOT\\BOOTX64.EFI";
const own_file = "\\EFI\\ZDOS\\ZIGDOS.EFI";

const max_path = 300; // a drive, and a path the kernel gives (up to 256 bytes)

var overwrite = false; // -O

pub fn main(args: []const u8) u8 {
    var letter: ?u8 = null;
    var words = std.mem.tokenizeAny(u8, args, " \t");
    while (words.next()) |w| {
        if (std.ascii.eqlIgnoreCase(w, "-O") or std.ascii.eqlIgnoreCase(w, "/O")) {
            overwrite = true;
        } else if (letter == null) {
            letter = parseLetter(w) orelse return bad();
        } else return bad();
    }
    const l = letter orelse return bad();
    return run(l);
}

fn bad() u8 {
    zdos.print(usage);
    return 1;
}

fn run(letter: u8) u8 {
    if (users.diskToolDenied("SYS")) return 1;
    const info = zdos.driveInfo(letter) catch {
        zdos.printf("No drive {c}:\n", .{letter});
        return 1;
    };
    if (!info.ready) {
        zdos.printf("Drive {c}: has no readable disk\n", .{letter});
        return 1;
    }
    return if (is_bios) biosSys(letter) else uefiSys(letter, info);
}

fn uefiSys(letter: u8, info: zdos.DriveInfo) u8 {
    const source = bootLetter() orelse {
        zdos.print("The drive ZDOS was started from has no letter:\nrun DISKLET first, then SYS again\n");
        return 1;
    };
    // The file ZDOS was started from, else the fallback file:
    var file_buf: [256]u8 = undefined;
    const from_file = sys.bootFile(&file_buf) orelse boot_file;
    var src_buf: [max_path]u8 = undefined;
    const src = std.fmt.bufPrint(&src_buf, "{c}:{s}", .{ source, from_file }) catch return 1;
    if (!exists(src)) {
        zdos.printf("Cannot find {s}, the file ZDOS was started from\n", .{src});
        return 1;
    }

    var kernel_buf: [max_path]u8 = undefined;
    const kernel = std.fmt.bufPrint(&kernel_buf, "{c}:{s}", .{ letter, if (info.system) own_file else boot_file }) catch return 1;
    if (!mayReplace(kernel, src)) return 1;
    if (overwrite) {
        // -O: no questions
    } else if (info.system) {
        zdos.printf("Make {c}: bootable? It is an EFI system partition.\n{s} is written, and\n{s} if that is free. (Y/N) ", .{ letter, own_file, boot_file });
    } else {
        zdos.printf("Make {c}: bootable? It is another disk.\n{s} is written. (Y/N) ", .{ letter, boot_file });
    }
    if (!confirm()) return 1;

    const ok = if (info.system) installEsp(src, letter) else installRemovable(src, letter);
    if (!ok) return 1;
    zdos.printf("{c}: is bootable now.\n", .{letter});
    if (info.system) {
        // The firmware's boot menu gets the entry, first in the order:
        sys.addBootEntry(letter, own_file) catch {
            zdos.print("The firmware's boot entry could not be added.\nChoose " ++ own_file ++ " in the boot menu\n");
            return 0;
        };
        zdos.print("A firmware boot entry for it is first in the boot order.\n");
    }
    return 0;
}

// Its own folder and the fallback file. A fallback file that isn't
// this ZDOS is only replaced after asking.
fn installEsp(src: []const u8, t: u8) bool {
    makeFolder(t, "EFI");
    makeFolder(t, "EFI\\ZDOS");
    var dst_buf: [max_path]u8 = undefined;
    const own = std.fmt.bufPrint(&dst_buf, "{c}:{s}", .{ t, own_file }) catch return false;
    if (!copyFile(src, own, zdos.Attr.system)) return false;
    var fallback_buf: [max_path]u8 = undefined;
    const fallback = std.fmt.bufPrint(&fallback_buf, "{c}:{s}", .{ t, boot_file }) catch return false;
    if (exists(fallback) and !overwrite) {
        if (sameContents(src, fallback)) return true;
        zdos.printf("{s} is there already: another system's, or an older ZDOS.\nReplace it with this ZDOS? (Y/N) ", .{boot_file});
        if (!sys.askYes()) {
            zdos.printf("{s} is not changed\n", .{boot_file});
            return true;
        }
    }
    makeFolder(t, "EFI\\BOOT");
    return copyFile(src, fallback, zdos.Attr.system);
}

// The firmware's fallback path for removable disks.
fn installRemovable(src: []const u8, t: u8) bool {
    makeFolder(t, "EFI");
    makeFolder(t, "EFI\\BOOT");
    var dst_buf: [max_path]u8 = undefined;
    const dst = std.fmt.bufPrint(&dst_buf, "{c}:{s}", .{ t, boot_file }) catch return false;
    return copyFile(src, dst, zdos.Attr.system);
}

// True for Y. The same file or contents needs no question.
fn mayReplace(path: []const u8, src: []const u8) bool {
    if (overwrite or !exists(path) or std.ascii.eqlIgnoreCase(path, src) or sameContents(path, src)) return true;
    zdos.printf("{s} already exists. Replace it? (Y/N) ", .{path});
    return confirm();
}

// An existing one is fine.
fn makeFolder(t: u8, rest: []const u8) void {
    var buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{c}:\\{s}", .{ t, rest }) catch return;
    zdos.makeDir(path) catch {};
}

fn exists(path: []const u8) bool {
    _ = zdos.stat(path) catch return false;
    return true;
}

// False if one can't be read.
fn sameContents(a: []const u8, b: []const u8) bool {
    const fa = zdos.open(a, .read) catch return false;
    defer fa.close();
    const fb = zdos.open(b, .read) catch return false;
    defer fb.close();
    var buf_a: [2048]u8 = undefined;
    var buf_b: [2048]u8 = undefined;
    while (true) {
        const na = readFull(fa, &buf_a) orelse return false;
        const nb = readFull(fb, &buf_b) orelse return false;
        if (na != nb or !std.mem.eql(u8, buf_a[0..na], buf_b[0..nb])) return false;
        if (na == 0) return true;
    }
}

// Null on a read error.
fn readFull(f: zdos.File, buf: []u8) ?usize {
    var n: usize = 0;
    while (n < buf.len) {
        const got = f.read(buf[n..]) catch return null;
        if (got == 0) break;
        n += got;
    }
    return n;
}

fn biosSys(letter: u8) u8 {
    // By disk and first sector: serial numbers can repeat on different volumes:
    const where = sys.driveLocation(letter) catch {
        zdos.printf("Cannot find where drive {c}: is on its disk\n", .{letter});
        return 1;
    };
    var boot_sector: [sys.sector]u8 = undefined;
    sys.readSectors(where.disk, where.start, &boot_sector) catch {
        zdos.printf("Cannot read the boot sector of drive {c}:\n", .{letter});
        return 1;
    };
    const layout = sys.parseLayout(where.start, &boot_sector) orelse {
        zdos.printf("Drive {c}: is not a FAT volume\n", .{letter});
        return 1;
    };
    // The boot code finds the volume through "hidden sectors", 32 bits:
    if (where.start > std.math.maxInt(u32)) {
        zdos.printf("Drive {c}: starts beyond 2 TB on its disk: the BIOS can't start ZDOS from it\n", .{letter});
        return 1;
    }
    // ZDOS's MBR code reads MBR tables only:
    if (where.start != 0 and onGpt(where.disk)) {
        zdos.printf("Drive {c}: is on a GPT disk: the BIOS can't start ZDOS from it\n", .{letter});
        return 1;
    }
    if (!bootCodeFits(&boot_sector, layout)) {
        zdos.printf("Drive {c}: has no room for ZDOS's boot code: format it again\n", .{letter});
        return 1;
    }
    const target = Target{ .disk = where.disk, .layout = layout };
    const boot = bootLetter() orelse {
        zdos.print("No drive was started from: cannot copy ZIGDOS.SYS\n");
        return 1;
    };

    var src_buf: [16]u8 = undefined;
    var dst_buf: [16]u8 = undefined;
    const src = std.fmt.bufPrint(&src_buf, "{c}:\\ZIGDOS.SYS", .{boot}) catch return 1;
    const dst = std.fmt.bufPrint(&dst_buf, "{c}:\\ZIGDOS.SYS", .{letter}) catch return 1;
    if (!mayReplace(dst, src)) return 1;
    if (!overwrite) zdos.printf("Make {c}: bootable? Disk {d}, from sector {d}:\nits boot sector is written and ZIGDOS.SYS is copied. (Y/N) ", .{ letter, target.disk, target.layout.start });
    if (!confirm()) return 1;
    // The file first: if it fails, the volume is as it was:
    if (!copyFile(src, dst, zdos.Attr.system | zdos.Attr.hidden | zdos.Attr.read_only)) return 1;
    sys.syncDisk(target.disk) catch {
        zdos.print("Cannot sync the disk before writing its boot sector\n");
        return 1;
    };
    const written = writeBootCode(target);
    sys.diskChanged(target.disk);
    if (!written) {
        zdos.printf("Cannot write the boot sector of disk {d}\n", .{target.disk});
        return 1;
    }
    zdos.printf("{c}: is bootable now. Its partition must be the active one to boot from it.\n", .{letter});
    return 0;
}

// A protective MBR: a partition of type EE.
fn onGpt(disk: u32) bool {
    var mbr: [sys.sector]u8 = undefined;
    sys.readSectors(disk, 0, &mbr) catch return false;
    if (mbr[510] != 0x55 or mbr[511] != 0xAA) return false;
    for (0..4) |i| {
        if (mbr[446 + i * 16 + 4] == 0xEE) return true;
    }
    return false;
}

const Target = struct { disk: u32, layout: sys.Layout };

// FAT12/16 needs an extended BPB (its type string); FAT32 needs sectors
// 2 and 8 free (not FSInfo) and the backup boot sector, if any, at 6.
fn bootCodeFits(b: *const [sys.sector]u8, l: sys.Layout) bool {
    switch (l.kind) {
        .fat12, .fat16 => return b[38] == 0x28 or b[38] == 0x29,
        .fat32 => {
            const fsinfo = sys.rd16(b, 48);
            const backup = sys.rd16(b, 50);
            if (l.reserved < 9 or fsinfo == 2 or fsinfo == 8) return false;
            return backup == 6 or backup == 0 or backup == 0xFFFF;
        },
    }
}

// Null if it has no letter.
fn bootLetter() ?u8 {
    var i: u32 = 0;
    while (true) : (i += 1) {
        const d = sys.driveAt(i) orelse return null;
        if (d.boot) return if (d.letter != 0) d.letter else null;
    }
}

// Keeps the BPB (as build.sh's make_bootable); on FAT32 also the backup
// and sectors 2 and 8. Sets hidden sectors and, on FAT12/16, the type.
fn writeBootCode(t: Target) bool {
    const l = t.layout;
    var buf: [sys.sector]u8 = undefined;
    switch (l.kind) {
        .fat12, .fat16 => {
            if (!readAt(t.disk, l.start, &buf)) return false;
            copyRange(&buf, 0, vbr16, 0, 3);
            copyRange(&buf, 62, vbr16, 62, 512);
            setHidden(&buf, l.start);
            @memcpy(buf[54..62], if (l.kind == .fat12) "FAT12   " else "FAT16   ");
            return writeAt(t.disk, l.start, &buf);
        },
        .fat32 => {
            if (!readAt(t.disk, l.start, &buf)) return false;
            const has_backup = sys.rd16(&buf, 50) == 6;
            for ([_]u64{ 0, 6 }) |b| {
                if (b == 6 and !has_backup) break;
                if (!readAt(t.disk, l.start + b, &buf)) return false;
                copyRange(&buf, 0, vbr32, 0, 3);
                copyRange(&buf, 90, vbr32, 90, 512);
                setHidden(&buf, l.start);
                if (!writeAt(t.disk, l.start + b, &buf)) return false;
            }
            var second: [sys.sector]u8 = undefined;
            copyRange(&second, 0, vbr32, 512, 1024);
            for ([_]u64{ 2, 8 }) |s| {
                if (s == 8 and !has_backup) break;
                if (!writeAt(t.disk, l.start + s, &second)) return false;
            }
            return true;
        },
    }
}

// The volume's first sector on its disk, checked to fit 32 bits.
fn setHidden(b: *[sys.sector]u8, start: u64) void {
    std.mem.writeInt(u32, b[28..32], @intCast(start), .little);
}

// Runtime indexes: the boot code constants are empty outside the BIOS
// build, where this is never reached.
fn copyRange(dst: []u8, dst_at: usize, src: []const u8, lo: usize, hi: usize) void {
    @memcpy(dst[dst_at..][0 .. hi - lo], src[lo..hi]);
}

fn readAt(disk: u32, lba: u64, buf: []u8) bool {
    sys.readSectors(disk, lba, buf) catch return false;
    return true;
}

fn writeAt(disk: u32, lba: u64, data: []const u8) bool {
    sys.writeSectors(disk, lba, data) catch return false;
    return true;
}

// "X" or "X:" as an upper case letter.
fn parseLetter(args: []const u8) ?u8 {
    const s = std.mem.trim(u8, args, " \t");
    if (s.len == 2 and s[1] == ':' and std.ascii.isAlphabetic(s[0])) return std.ascii.toUpper(s[0]);
    if (s.len == 1 and std.ascii.isAlphabetic(s[0])) return std.ascii.toUpper(s[0]);
    return null;
}

// After its text was printed: true for Y (or Enter); -O: yes.
fn confirm() bool {
    if (overwrite) return true;
    if (sys.askYes()) return true;
    zdos.print("Nothing was changed.\n");
    return false;
}

// Through ZDOSSYS.TMP, so a failed copy leaves the old file working;
// -O: into the file itself.
fn copyFile(src: []const u8, dst: []const u8, attrs: u8) bool {
    if (std.ascii.eqlIgnoreCase(src, dst)) return true;
    if (overwrite) {
        if (exists(dst)) zdos.setAttributes(dst, 0) catch {};
        if (!copyData(src, dst)) return false;
        zdos.setAttributes(dst, attrs) catch {
            zdos.printf("Cannot set the attributes of {s}\n", .{dst});
            return false;
        };
        return true;
    }
    const folder_len = (std.mem.lastIndexOfScalar(u8, dst, '\\') orelse return false) + 1;
    var tmp_buf: [max_path]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}ZDOSSYS.TMP", .{dst[0..folder_len]}) catch return false;
    if (exists(tmp)) {
        zdos.setAttributes(tmp, 0) catch {};
        zdos.delete(tmp) catch {};
    }
    if (!copyData(src, tmp)) {
        zdos.delete(tmp) catch {};
        return false;
    }
    // The complete copy takes the old file's place:
    if (exists(dst)) {
        zdos.setAttributes(dst, 0) catch {};
        zdos.delete(dst) catch {
            zdos.printf("Cannot replace {s}\n", .{dst});
            zdos.delete(tmp) catch {};
            return false;
        };
    }
    zdos.move(tmp, dst) catch {
        zdos.printf("Cannot rename {s} to {s}\n", .{ tmp, dst });
        return false;
    };
    zdos.setAttributes(dst, attrs) catch {
        zdos.printf("Cannot set the attributes of {s}\n", .{dst});
        return false;
    };
    return true;
}

fn copyData(src: []const u8, dst: []const u8) bool {
    const in = zdos.open(src, .read) catch {
        zdos.printf("Cannot read {s}\n", .{src});
        return false;
    };
    defer in.close();
    const out = zdos.open(dst, .write) catch {
        zdos.printf("Cannot write {s}\n", .{dst});
        return false;
    };
    var buf: [2048]u8 = undefined;
    while (true) {
        const n = in.read(&buf) catch {
            zdos.printf("Cannot read {s}\n", .{src});
            out.close();
            return false;
        };
        if (n == 0) break;
        out.writeAll(buf[0..n]) catch {
            zdos.printf("Cannot write {s}: the disk may be full\n", .{dst});
            out.close();
            return false;
        };
    }
    out.closeChecked() catch {
        zdos.printf("Cannot finish {s}\n", .{dst});
        return false;
    };
    return true;
}
