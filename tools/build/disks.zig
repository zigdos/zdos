// The disk images and release zips from build/<edition>/, as
// build.sh and dist.sh; run by build.zig in the source folder:
//   disks images | test-disks <edition>
//   disks release <version> [<Pi 4 firmware folder>]
//   disks minix-system <edition> <image>
// Writes partition tables and Minix drives itself, so it works on macOS.
const std = @import("std");
const files = @import("files.zig");
const fat = @import("fat.zig");
const partitions = @import("partitions.zig");
const firmware = @import("firmware.zig");
const minix = @import("minix.zig");

// ZDOS's Minix driver runs here: its platform is this computer.
pub const zdos_platform = .host;
pub const zdos_host_backend = minix.backend;
const fmt = files.fmt;
const eql = files.eql;
const inFolder = files.inFolder;
const system_partition_size_mib = 512;
const sectors_per_mib = 2048;
const kib_per_mib = 1024;
const efi_partition_size_mib = 64;

pub fn main() void {
    const args = files.commandLine();
    if (args.len == 3 and eql(args[1], "images")) {
        if (eql(args[2], "bios-x86")) biosImages() else uefiImage(args[2]);
    } else if (args.len == 3 and eql(args[1], "test-disks")) {
        testDisks(args[2]);
    } else if (args.len == 4 and eql(args[1], "minix-system")) {
        minix.mkfs(args[3], system_partition_size_mib * kib_per_mib);
        fillSystem(args[3], args[2], false);
        minix.finish();
    } else if ((args.len == 3 or args.len == 4) and eql(args[1], "release")) {
        release(args[2], if (args.len == 4) args[3] else firmware.rpi4());
    } else {
        files.fail("usage: disks images|test-disks <edition>, disks release <version> [<Pi 4 firmware>]", .{});
    }
}

// DRIVE C:

// Not all programs fit on 1.44 MB any more.
const floppy_apps = [_][]const u8{ "COMMAND.APP", "SYS.APP" };

// See put. The floppy gets only floppy_apps; a missing one stops the build.
fn fillSystem(drive: []const u8, e: []const u8, floppy: bool) void {
    if (floppy) {
        for (floppy_apps) |app| put(drive, "/APPS", &.{fmt("build/{s}/APPS/{s}", .{ e, app })});
        put(drive, "/CONF", &.{"conf/SYSTEM.CFG"});
        put(drive, "/SCRIPTS", &.{"scripts/AUTOEXEC.CMD"});
    } else {
        put(drive, "/APPS", inFolder(fmt("build/{s}/APPS", .{e}), ""));
        put(drive, "/APPS", inFolder(fmt("build/{s}/APPS_3RD", .{e}), ""));
        put(drive, "/GAMES", inFolder(fmt("build/{s}/GAMES", .{e}), ""));
        put(drive, "/LIBS", inFolder(fmt("build/{s}/LIBS", .{e}), ""));
        put(drive, "/LIBS", inFolder(fmt("build/{s}/LIBS_3RD", .{e}), ""));
        put(drive, "/SYSTEM/DRIVERS", inFolder(fmt("build/{s}/DRIVERS", .{e}), ""));
        put(drive, "/DATA", inFolder("build/DATA", ""));
        put(drive, "/DATA", inFolder("data", ""));
        put(drive, "/SYSTEM/FONTS", inFolder("fonts/terminal", ".zfn"));
        put(drive, "/SYSTEM/FONTS", inFolder("fonts/codepages", ".zcp"));
        put(drive, "/SYSTEM/TTF", ttfFonts());
        put(drive, "/SYSTEM/KEYB", inFolder("keyb", ".ZKB"));
        put(drive, "/SCRIPTS", inFolder("scripts", ""));
        put(drive, "/CONF", inFolder("conf", ""));
        put(drive, "/DOCS", &.{"README.md"});
        put(drive, "/DOCS", inFolder("docs", ""));
    }
    put(drive, "/TEMP", &.{}); // TEMP= in SYSTEM.CFG
}

// TrueType and OpenType fonts for \SYSTEM\TTF: fonts/TTF's and those
// in $ZDOS_PORTS_SRC/TTF (unset: ../TTF), at any depth there; variable
// fonts ("Variable" in the name) left out.
fn ttfFonts() []const []const u8 {
    var out = std.ArrayList([]const u8).init(files.gpa);
    const src = std.process.getEnvVarOwned(files.gpa, "ZDOS_PORTS_SRC") catch "..";
    for ([_][]const u8{ "fonts/TTF", fmt("{s}/TTF", .{src}) }) |dir| addFonts(dir, &out);
    return out.items;
}

fn addFonts(dir: []const u8, out: *std.ArrayList([]const u8)) void {
    if (!files.isDir(dir)) return;
    for (files.list(dir)) |name| {
        const path = fmt("{s}/{s}", .{ dir, name });
        if (files.isDir(path)) {
            addFonts(path, out);
            continue;
        }
        const font = std.ascii.endsWithIgnoreCase(name, ".ttf") or std.ascii.endsWithIgnoreCase(name, ".otf");
        if (!font or std.ascii.indexOfIgnoreCase(name, "variable") != null) continue;
        out.append(path) catch files.fail("out of memory", .{});
    }
}

// FAT SYSTEM DISK AND BOOT FLOPPY (BIOS)

fn biosImages() void {
    const sys = "build/bios-x86/ZIGDOS.SYS";

    // System disk (MBR): p1 FAT32, active -> C:. The boot sector needs
    // -h = the partition's start. mkfs.fat leaves sectors 2 and 8 free for
    // part 2 of the boot code:
    const p1 = "build/bios-x86/p1.img";
    const system_size_mib = system_partition_size_mib;
    const system_size_sectors = @as(u64, system_size_mib) * sectors_per_mib;
    fat.mkfs(p1, "32", "ZDOS", system_size_mib * kib_per_mib, &.{ "-h", "2048" });
    fat.makeBootable(p1, "build/bios-x86/vbr32.bin", sys);
    fillSystem(p1, "bios-x86", false);
    partitions.mbr("build/bios-x86/system.img", system_size_mib + 2, "build/bios-x86/mbr.bin", &.{
        .{ .start = 2048, .size = system_size_sectors, .image = p1, .mbr_type = 0x0C, .bootable = true },
    });
    files.remove(p1);

    // Boot floppy (1.44 MB, FAT12, no partition table):
    const floppy = "build/bios-x86/floppy.img";
    fat.mkfs(floppy, "12", "ZIGDOS", 1440, &.{});
    fat.makeBootable(floppy, "build/bios-x86/vbr16.bin", sys);
    fillSystem(floppy, "bios-x86", true);
}

// MINIX SYSTEM DISK (UEFI, METAL)

// system.img (GPT):
//   p1 EFI System Partition (FAT32), only \EFI\BOOT -> no letter
//   p2 Minix V3 -> C:
fn uefiImage(e: []const u8) void {
    const boot = if (std.mem.endsWith(u8, e, "x86_64")) "BOOTX64.EFI" else "BOOTAA64.EFI";
    const p1 = fmt("build/{s}/p1.img", .{e});
    const p2 = fmt("build/{s}/p2.mfs", .{e});
    const system_size_mib = system_partition_size_mib;
    const system_size_sectors = @as(u64, system_size_mib) * sectors_per_mib;
    const efi_size_sectors = efi_partition_size_mib * sectors_per_mib;
    const system_start = sectors_per_mib + efi_size_sectors;
    fat.mkfs(p1, "32", "EFI", efi_partition_size_mib * kib_per_mib, &.{});
    put(p1, "/EFI/BOOT", &.{fmt("build/{s}/{s}", .{ e, boot })});
    fat.attrib(p1, "+s", fmt("::/EFI/BOOT/{s}", .{boot}));
    minix.mkfs(p2, system_size_mib * kib_per_mib);
    fillSystem(p2, e, false);
    minix.finish();
    partitions.gpt(fmt("build/{s}/system.img", .{e}), system_size_mib + efi_partition_size_mib + 2, &.{
        .{ .start = sectors_per_mib, .size = efi_size_sectors, .image = p1, .gpt_type = partitions.efi_system, .name = "EFI System" },
        .{ .start = system_start, .size = system_size_sectors, .image = p2, .gpt_type = partitions.linux_data, .name = "zdos" },
    });
    files.remove(p1);
    files.remove(p2);
}

// TEST DISKS

// Beside system.img; the run scripts attach them.
fn testDisks(e: []const u8) void {
    const p1 = fmt("build/{s}/p1.img", .{e});
    const p2 = fmt("build/{s}/p2.img", .{e});
    const p3 = fmt("build/{s}/p3.img", .{e});

    if (eql(e, "bios-x86")) {
        // data.img (MBR):
        //   p1 ext2 -> D:
        //   p5 FAT16, logical, of a "hidden" type -> no letter
        mkext2(p1, "DATA", 64 * 1024);
        fat.mkfs(p3, "16", "RECOVERY", 16 * 1024, &.{});
        fat.text(p3, "::/RECOVER.TXT", "Recovery data\n");
        partitions.mbr("build/bios-x86/data.img", 84, null, &.{
            .{ .start = 2048, .size = 131072, .image = p1, .mbr_type = 0x83 },
            .{ .start = 133120, .size = 34816, .mbr_type = 0x05 },
            .{ .start = 135168, .size = 32768, .image = p3, .mbr_type = 0x16, .logical = true },
        });
    }
    if (eql(e, "uefi-x86_64") or eql(e, "metal-x86_64")) {
        // sata.img (GPT):
        //   p1 ext2 -> D:
        //   p2 GPT attributes 62, 63 (hidden, no letter) -> no letter
        mkext2(p1, "DATA", 64 * 1024);
        fat.mkfs(p2, "16", "RECOVERY", 16 * 1024, &.{});
        fat.text(p2, "::/RECOVER.TXT", "Recovery data\n");
        partitions.gpt(fmt("build/{s}/sata.img", .{e}), 82, &.{
            .{ .start = 2048, .size = 131072, .image = p1, .gpt_type = partitions.linux_data, .name = "Data" },
            .{ .start = 133120, .size = 32768, .image = p2, .name = "Recovery", .attrs = (1 << 62) | (1 << 63) },
        });
        // USB stick:
        fat.mkfs(p3, "16", "USB", 16 * 1024, &.{});
        fat.text(p3, "::/USB.TXT", "A USB stick\n");
        partitions.mbr(fmt("build/{s}/usb.img", .{e}), 20, null, &.{
            .{ .start = 2048, .size = 32768, .image = p3, .mbr_type = 0x06 },
        });
    }
    if (eql(e, "uefi-arm64") or eql(e, "metal-arm64")) {
        // data.img (GPT):
        mkext2(p1, "DATA", 64 * 1024);
        partitions.gpt(fmt("build/{s}/data.img", .{e}), 66, &.{
            .{ .start = 2048, .size = 131072, .image = p1, .gpt_type = partitions.linux_data, .name = "Data" },
        });
    }
    files.remove(p1);
    files.remove(p2);
    files.remove(p3);
}

fn mkext2(img: []const u8, label: []const u8, kib: u32) void {
    files.remove(img);
    files.run(&.{ "mke2fs", "-q", "-F", "-t", "ext2", "-L", label, img, fmt("{d}k", .{kib}) });
}

// RELEASE ZIPS

// With SHA256SUMS-<version>-ZDOS. Each is put together in a
// folder of its name, removed once zipped.
fn release(version: []const u8, rpi4_firmware: []const u8) void {
    var sums = std.ArrayList(u8).init(files.gpa);

    for ([_][]const u8{ "metal-x86_64", "metal-arm64", "bios-x86", "uefi-x86_64", "uefi-arm64" }) |e| {
        const dir = fmt("dist/zdos-{s}-{s}", .{ version, e });
        files.remove(dir);
        files.copy(fmt("run-{s}.sh", .{e}), fmt("{s}/run-{s}.sh", .{ dir, e }));
        files.copy(fmt("build/{s}/system.img", .{e}), fmt("{s}/zdos-{s}.img", .{ dir, e }));
        if (std.mem.endsWith(u8, e, "x86_64")) firmware.qemu("x86_64", fmt("{s}/firmware", .{dir}));
        if (std.mem.endsWith(u8, e, "arm64")) firmware.qemu("arm64", fmt("{s}/firmware", .{dir}));
        zip(dir, &sums);
    }

    // For a stick or card: install.sh, edition.txt and drive C: in files/;
    // for the Pi also its firmware, without Readme.md:
    const sticks = [_]struct { name: []const u8, edition: []const u8, boot: []const u8, pi: bool }{
        .{ .name = "usb-metal-x86_64", .edition = "metal-x86_64", .boot = "BOOTX64.EFI", .pi = false },
        .{ .name = "usb-metal-rpi4u", .edition = "metal-arm64", .boot = "BOOTAA64.EFI", .pi = true },
        .{ .name = "usb-uefi-x86_64", .edition = "uefi-x86_64", .boot = "BOOTX64.EFI", .pi = false },
        .{ .name = "usb-uefi-rpi4u", .edition = "uefi-arm64", .boot = "BOOTAA64.EFI", .pi = true },
    };
    for (sticks) |st| {
        const dir = fmt("dist/zdos-{s}-{s}", .{ version, st.name });
        files.remove(dir);
        files.copy("install.sh", fmt("{s}/install.sh", .{dir}));
        files.write(fmt("{s}/edition.txt", .{dir}), fmt("{s}\n", .{st.name["usb-".len..]}));
        if (st.pi) files.copyTreeExcept(rpi4_firmware, fmt("{s}/files", .{dir}), &.{ "Readme.md", "files" });
        put(fmt("{s}/files", .{dir}), "/EFI/BOOT", &.{fmt("build/{s}/{s}", .{ st.edition, st.boot })});
        fillSystem(fmt("{s}/files", .{dir}), st.edition, false);
        zip(dir, &sums);
    }

    files.write(fmt("dist/SHA256SUMS-{s}-ZDOS", .{version}), sums.items);
}

// Notes the checksum in sums, and removes the folder.
fn zip(dir: []const u8, sums: *std.ArrayList(u8)) void {
    const name = std.fs.path.basename(dir);
    const zip_name = fmt("{s}.zip", .{name});
    files.remove(fmt("{s}.zip", .{dir}));
    files.runIn(std.fs.path.dirname(dir), &.{ "zip", "-qr", zip_name, name });
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(files.read(fmt("{s}.zip", .{dir})), &hash, .{});
    sums.writer().print("{s}  {s}\n", .{ std.fmt.fmtSliceHexLower(&hash), zip_name }) catch unreachable;
    files.remove(dir);
}

// COPYING INTO IMAGES

// Into a FAT image (*.img, mtools), a Minix image (*.mfs) or a folder.
// In name order: ZDOS lists some folders (SYSTEM\KEYB) in the order
// their files were written.
fn put(drive: []const u8, to: []const u8, from: []const []const u8) void {
    const image = std.mem.endsWith(u8, drive, ".img");
    const minix_image = std.mem.endsWith(u8, drive, ".mfs");
    if (image) fat.mkdirs(drive, to) else if (minix_image) minix.mkdirs(drive, to) else files.makeDir(fmt("{s}{s}", .{ drive, to }));
    for (from) |f| {
        const name = std.fs.path.basename(f);
        if (files.isDir(f)) {
            put(drive, fmt("{s}/{s}", .{ to, name }), inFolder(f, ""));
        } else if (minix_image) {
            minix.copy(drive, f, fmt("{s}/{s}", .{ to, name }));
        } else if (image) {
            files.run(&.{ "mcopy", "-D", "o", "-i", drive, f, fmt("::{s}/{s}", .{ to, name }) });
        } else {
            files.copy(f, fmt("{s}{s}/{s}", .{ drive, to, name }));
        }
    }
}
