// VER [FILE]: the ZDOS version, or a program's, library's or driver's
// version and ABI (header bytes 4 and 8, any CPU's).
const std = @import("std");
const zdos = @import("zdos/zdos.zig");

comptime {
    _ = zdos;
}

pub const zdos_file_version = [4]u8{ 1, 0, 0, 0 };

const cpu_name = switch (@import("builtin").cpu.arch) {
    .aarch64 => "ARM64",
    else => std.fmt.comptimePrint("{d}-bit", .{@bitSizeOf(usize)}),
};

const Kind = struct { magic: *const [4]u8, what: []const u8 };
const kinds = [_]Kind{
    .{ .magic = "ZAP6", .what = "program, x86-64" },
    .{ .magic = "ZAP3", .what = "program, x86" },
    .{ .magic = "ZAPA", .what = "program, ARM64" },
    .{ .magic = "ZDL6", .what = "library, x86-64" },
    .{ .magic = "ZDL3", .what = "library, x86" },
    .{ .magic = "ZDLA", .what = "library, ARM64" },
    .{ .magic = "ZSY6", .what = "driver, x86-64" },
    .{ .magic = "ZSY3", .what = "driver, x86" },
    .{ .magic = "ZSYA", .what = "driver, ARM64" },
};

pub fn main(args: []const u8) u8 {
    const path = std.mem.trim(u8, args, " \t\"");
    if (path.len == 0) {
        var buf: [64]u8 = undefined;
        const platform = zdos.getVar("PLATFORM", &buf) orelse "";
        const edition = if (std.ascii.startsWithIgnoreCase(platform, "bios"))
            "BIOS"
        else if (std.ascii.startsWithIgnoreCase(platform, "metal")) "Metal" else "UEFI";
        const v = zdos.systemInfo().os_version;
        zdos.printf("ZDOS " ++ cpu_name ++ " {s} Edition version {d}.{d}.{d}.{d}\n", .{ edition, v[0], v[1], v[2], v[3] });
        return 0;
    }
    if (std.mem.eql(u8, path, "/?") or std.mem.eql(u8, path, "-h")) {
        zdos.print("Usage: VER [file]   the ZDOS version, or a .APP's, .ZDL's or .SYS's\n");
        return 0;
    }
    return showFile(path);
}

fn showFile(path: []const u8) u8 {
    const file = zdos.open(path, .read) catch |err| {
        zdos.eprintf("VER: {s}: {s}\n", .{ path, zdos.message(err) });
        return 1;
    };
    defer file.close();
    var head: [12]u8 = undefined;
    var got: usize = 0;
    while (got < head.len) {
        const n = file.read(head[got..]) catch 0;
        if (n == 0) break;
        got += n;
    }
    const kind = for (kinds) |k| {
        if (got == head.len and std.mem.eql(u8, head[0..4], k.magic)) break k;
    } else {
        zdos.printf("{s}: not a ZDOS program, library or driver\n", .{path});
        return 1;
    };
    const abi_version = std.mem.readInt(u32, head[4..8], .little);
    const v = std.mem.readInt(u32, head[8..12], .little);
    zdos.printf("{s}: {s}, ", .{ path, kind.what });
    if (v == 0) {
        zdos.print("no version");
    } else zdos.printf("version {d}.{d}.{d}.{d}", .{ v >> 24, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF });
    zdos.printf(", ABI version {d}\n", .{abi_version});
    return 0;
}
