// The firmware for the releases: QEMU's UEFI firmware from this
// computer, and the Raspberry Pi 4's.
const std = @import("std");
const files = @import("files.zig");
const fmt = files.fmt;

// Where distributions keep it, and the names in firmware/ the run
// scripts look for.
const Found = struct { files: []const []const u8, as: []const []const u8 };

const x86_64 = [_]Found{
    .{ .files = &.{ "/usr/share/edk2/ovmf/OVMF_CODE.fd", "/usr/share/edk2/ovmf/OVMF_VARS.fd" }, .as = &.{ "OVMF_CODE.fd", "OVMF_VARS.fd" } },
    .{ .files = &.{ "/usr/share/OVMF/OVMF_CODE.fd", "/usr/share/OVMF/OVMF_VARS.fd" }, .as = &.{ "OVMF_CODE.fd", "OVMF_VARS.fd" } },
    .{ .files = &.{ "/usr/share/edk2/x64/OVMF_CODE.fd", "/usr/share/edk2/x64/OVMF_VARS.fd" }, .as = &.{ "OVMF_CODE.fd", "OVMF_VARS.fd" } },
    .{ .files = &.{ "/usr/share/ovmf/OVMF_CODE.fd", "/usr/share/ovmf/OVMF_VARS.fd" }, .as = &.{ "OVMF_CODE.fd", "OVMF_VARS.fd" } },
    .{ .files = &.{ "/opt/homebrew/share/qemu/edk2-x86_64-code.fd", "/opt/homebrew/share/qemu/edk2-i386-vars.fd" }, .as = &.{ "OVMF_CODE.fd", "OVMF_VARS.fd" } },
    .{ .files = &.{ "/usr/local/share/qemu/edk2-x86_64-code.fd", "/usr/local/share/qemu/edk2-i386-vars.fd" }, .as = &.{ "OVMF_CODE.fd", "OVMF_VARS.fd" } },
};

const arm64 = [_]Found{
    .{ .files = &.{"/usr/share/edk2/aarch64/QEMU_EFI.silent.fd"}, .as = &.{"QEMU_EFI.fd"} },
    .{ .files = &.{"/usr/share/edk2/aarch64/QEMU_EFI.fd"}, .as = &.{"QEMU_EFI.fd"} },
    .{ .files = &.{"/usr/share/qemu-efi-aarch64/QEMU_EFI.fd"}, .as = &.{"QEMU_EFI.fd"} },
    .{ .files = &.{"/usr/share/AAVMF/AAVMF_CODE.fd"}, .as = &.{"QEMU_EFI.fd"} },
    .{ .files = &.{"/opt/homebrew/share/qemu/edk2-aarch64-code.fd"}, .as = &.{"QEMU_EFI.fd"} },
    .{ .files = &.{"/usr/local/share/qemu/edk2-aarch64-code.fd"}, .as = &.{"QEMU_EFI.fd"} },
};

// "x86_64" or "arm64", with its license.
pub fn qemu(arch: []const u8, dest: []const u8) void {
    const candidates: []const Found = if (files.eql(arch, "x86_64")) &x86_64 else &arm64;
    const package = if (files.eql(arch, "x86_64")) "edk2-ovmf" else "edk2-aarch64";
    const fw = found: for (candidates) |c| {
        for (c.files) |f| if (!files.exists(f)) continue :found;
        break :found c;
    } else files.fail("QEMU's UEFI firmware for the release not found (install {s})", .{package});
    for (fw.files, fw.as) |f, as| files.copy(f, fmt("{s}/{s}", .{ dest, as }));

    // From the distribution's package, or where to read it:
    const licenses = [_][]const u8{
        fmt("/usr/share/licenses/{s}/License.txt", .{package}),
        fmt("/usr/share/doc/{s}/License.txt", .{package}),
        "/usr/share/doc/ovmf/copyright",
        "/usr/share/doc/qemu-efi-aarch64/copyright",
    };
    for (licenses) |l| if (files.exists(l)) return files.copy(l, fmt("{s}/LICENSE.txt", .{dest}));
    files.write(fmt("{s}/LICENSE.txt", .{dest}),
        \\UEFI firmware for QEMU from the EDK II project (TianoCore),
        \\BSD-2-Clause-Patent license:
        \\https://github.com/tianocore/edk2/blob/master/License.txt
        \\
    );
}

// pftf/RPi4: beside the source folder, in $ZDOS_PORTS_SRC, or where
// earlier builds kept a copy.
pub fn rpi4() []const u8 {
    var candidates = std.ArrayList([]const u8).init(files.gpa);
    candidates.append("../RPi4_UEFI_Firmware") catch unreachable;
    if (std.process.getEnvVarOwned(files.gpa, "ZDOS_PORTS_SRC")) |ports| {
        candidates.append(fmt("{s}/RPi4_UEFI_Firmware", .{ports})) catch unreachable;
    } else |_| {}
    candidates.append("build/rpi4u-arm64") catch unreachable;
    for (candidates.items) |dir| if (files.exists(fmt("{s}/RPI_EFI.fd", .{dir}))) return dir;
    files.fail("the Raspberry Pi 4 UEFI firmware (RPI_EFI.fd) not found in ../RPi4_UEFI_Firmware, $ZDOS_PORTS_SRC/RPi4_UEFI_Firmware or build/rpi4u-arm64 (zig build dist -Drpi4-firmware=<folder>)", .{});
}
