// The BIOS edition's boot code from the kernel, for build.zig:
//   bios-boot <binutils prefix> <kernel ELF> <src/boot/bios> <out>
// Makes ZIGDOS.SYS (stage 2 + LZ4 kernel), mbr.bin, vbr16.bin, vbr32.bin.
const std = @import("std");
const files = @import("files.zig");
const fmt = files.fmt;
const fail = files.fail;
const lz4 = @import("lz4.zig");

var prefix: []const u8 = undefined;
var src: []const u8 = undefined;
var out: []const u8 = undefined;

pub fn main() void {
    const args = files.commandLine();
    if (args.len != 5) fail("usage: bios-boot <binutils prefix> <kernel ELF file> <src/boot/bios> <out folder>", .{});
    prefix = args[1];
    const kernel_elf = args[2];
    src = args[3];
    out = args[4];

    // 1. The kernel, entry at 1 MiB. ZIGDOS.SYS is loaded to 0x8000 and
    //    must end below 0x80000: 4 KiB of stage 2 plus at most 952
    //    sectors of compressed kernel.
    const elf = files.read(kernel_elf);
    if (elf.len < 28 or !std.mem.eql(u8, elf[0..4], "\x7fELF") or elf[4] != 1) fail("{s} is not a 32-bit ELF file", .{kernel_elf});
    const entry = std.mem.readInt(u32, elf[24..28], .little);
    if (entry != 0x100000) fail("the kernel's entry is 0x{x}, not 0x100000", .{entry});
    const kernel_bin = fmt("{s}/kernel.bin", .{out});
    files.run(&.{ fmt("{s}objcopy", .{prefix}), "-O", "binary", kernel_elf, kernel_bin });
    const kernel = lz4.compress(files.gpa, files.read(kernel_bin)) catch fail("out of memory", .{});
    files.remove(kernel_bin);
    const sectors = (kernel.len + 511) / 512;
    if (sectors > 952) fail("the kernel is too large ({d} sectors, compressed)", .{sectors});

    // 2. Stage 2, with the compressed kernel's size:
    const stage2 = assemble("stage2", "0x8000", fmt("KERNEL_PACKED={d}", .{kernel.len}));
    files.remove(fmt("{s}/stage2.bin", .{out}));
    if (stage2.len > 4096) fail("stage2.bin is larger than 4 KiB", .{});

    // 3. ZIGDOS.SYS = stage 2 padded to 4 KiB + the kernel:
    const sys = files.gpa.alloc(u8, 4096 + kernel.len) catch fail("out of memory", .{});
    @memset(sys[0..4096], 0);
    @memcpy(sys[0..stage2.len], stage2);
    @memcpy(sys[4096..], kernel);
    files.write(fmt("{s}/ZIGDOS.SYS", .{out}), sys);

    // 4. The boot sectors, each of its exact size:
    if (assemble("mbr", "0x0600", null).len != 440) fail("mbr.bin is not 440 bytes", .{});
    if (assemble("vbr16", "0x7C00", null).len != 512) fail("vbr16.bin is not 512 bytes", .{});
    if (assemble("vbr32", "0x7C00", null).len != 1024) fail("vbr32.bin is not 1024 bytes", .{});
}

// Linked at address as <out>/<name>.bin. Only .text: as adds a
// .note.gnu.property section that would bloat it.
fn assemble(name: []const u8, address: []const u8, defsym: ?[]const u8) []const u8 {
    const s = fmt("{s}/{s}.s", .{ src, name });
    const o = fmt("{s}/{s}.o", .{ out, name });
    const elf = fmt("{s}/{s}.elf", .{ out, name });
    const bin = fmt("{s}/{s}.bin", .{ out, name });
    const as = fmt("{s}as", .{prefix});
    if (defsym) |d| files.run(&.{ as, "--32", "--defsym", d, s, "-o", o }) else files.run(&.{ as, "--32", s, "-o", o });
    files.run(&.{ fmt("{s}ld", .{prefix}), "-m", "elf_i386", "-Ttext", address, "-e", "_start", o, "-o", elf });
    files.run(&.{ fmt("{s}objcopy", .{prefix}), "-O", "binary", "-j", ".text", elf, bin });
    files.remove(o);
    files.remove(elf);
    return files.read(bin);
}
