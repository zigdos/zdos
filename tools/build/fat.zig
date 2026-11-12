// FAT images with mkfs.fat and mtools. Paths are written "::/APPS".
const std = @import("std");
const files = @import("files.zig");
const fmt = files.fmt;

// fat: "12", "16" or "32"; extra: more mkfs.fat options.
pub fn mkfs(img: []const u8, fat: []const u8, label: []const u8, kib: u32, extra: []const []const u8) void {
    files.remove(img);
    made.clearRetainingCapacity();
    if (std.fs.path.dirname(img)) |dir| files.makeDir(dir);
    var argv = std.ArrayList([]const u8).init(files.gpa);
    argv.appendSlice(&.{ "mkfs.fat", "-F", fat, "-n", label }) catch unreachable;
    argv.appendSlice(extra) catch unreachable;
    argv.appendSlice(&.{ "-C", img, fmt("{d}", .{kib}) }) catch unreachable;
    files.run(argv.items);
}

// As "<image>::/A/B":
var made = std.StringHashMap(void).init(files.gpa);

// And those above it.
pub fn mkdirs(img: []const u8, path: []const u8) void {
    var at: []const u8 = "::";
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        at = fmt("{s}/{s}", .{ at, part });
        const key = fmt("{s}{s}", .{ img, at });
        if ((made.getOrPut(key) catch unreachable).found_existing) continue;
        files.run(&.{ "mmd", "-i", img, at });
    }
}

// At "::/README.TXT".
pub fn text(img: []const u8, at: []const u8, content: []const u8) void {
    const tmp = fmt("{s}.txt", .{img});
    files.write(tmp, content);
    files.run(&.{ "mcopy", "-i", img, tmp, at });
    files.remove(tmp);
}

pub fn attrib(img: []const u8, attrs: []const u8, at: []const u8) void {
    files.run(&.{ "mattrib", "-i", img, attrs, at });
}

// For the BIOS edition, keeping mkfs.fat's BPB; ZIGDOS.SYS must be the
// first root entry, like IO.SYS.
//   FAT12/16: vbr16.bin into the boot sector (BPB: bytes 3-61)
//   FAT32:    vbr32.bin part 1 into the boot sector (BPB: bytes 3-89)
//             and its backup (sector 6), part 2 into sectors 2 and 8
pub fn makeBootable(img: []const u8, vbr_path: []const u8, sys: []const u8) void {
    const vbr = files.read(vbr_path);
    const f = std.fs.cwd().openFile(img, .{ .mode = .read_write }) catch |err| files.fail("{s}: {s}", .{ img, @errorName(err) });
    defer f.close();
    if (vbr.len == 1024) {
        for ([_]u64{ 0, 6 }) |boot| {
            f.pwriteAll(vbr[0..3], boot * 512) catch unreachable;
            f.pwriteAll(vbr[90..512], boot * 512 + 90) catch unreachable;
            f.pwriteAll(vbr[512..1024], (boot + 2) * 512) catch unreachable;
        }
    } else {
        f.pwriteAll(vbr[0..3], 0) catch unreachable;
        f.pwriteAll(vbr[62..512], 62) catch unreachable;
    }
    files.run(&.{ "mcopy", "-i", img, sys, "::/ZIGDOS.SYS" });
    files.run(&.{ "mattrib", "-i", img, "+s", "+h", "+r", "::/ZIGDOS.SYS" });
}
