// A Minix V3 image holding a folder, made through ZDOS's own Minix
// driver (as drive C:); tools/disk/mkimage.py runs it:
//   mfsdir IMAGE KIB FOLDER
// Modes as on C:: folders and .APP or host-executable files 0755,
// other files 0644.
const std = @import("std");
const files = @import("files.zig");
const minix = @import("minix.zig");

pub const zdos_platform = .host;
pub const zdos_host_backend = minix.backend;
const fmt = files.fmt;

pub fn main() void {
    const args = std.process.argsAlloc(files.gpa) catch files.fail("out of memory", .{});
    if (args.len != 4) files.fail("Usage: mfsdir IMAGE KIB FOLDER", .{});
    const img = args[1];
    const kib = std.fmt.parseInt(u32, args[2], 10) catch files.fail("{s}: not a size in KiB", .{args[2]});
    if (!files.isDir(args[3])) files.fail("{s}: not a folder", .{args[3]});
    minix.mkfs(img, kib);
    put(img, "", args[3]);
    minix.finish();
}

// The folder's entries under the image's path `to` ("" the root):
fn put(img: []const u8, to: []const u8, from: []const u8) void {
    for (files.list(from)) |name| {
        const src = fmt("{s}/{s}", .{ from, name });
        const dst = fmt("{s}/{s}", .{ to, name });
        if (files.isDir(src)) {
            minix.mkdirs(img, dst);
            put(img, dst, src);
        } else {
            minix.copy(img, src, dst);
        }
    }
}
