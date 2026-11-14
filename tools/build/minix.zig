// Minix V3 images for drive C:, formatted by mkmfs3-host.zig and filled through
// ZDOS's own Minix driver. Paths look like "/APPS/X.APP". All root's:
// folders and .APP 0755, other files 0644, \TEMP 1777.
const std = @import("std");
const files = @import("files.zig");
const fmt = files.fmt;
const zdosfs = @import("zdos_fs");
const mkmfs3 = @import("mkmfs3");
const mfs = zdosfs.mfs;
const platform = zdosfs.platform;

// The time for new files: local time, as ZDOS's clock gives it there
// (ZDOS has no time zone; its Minix driver keeps that time as is):
const ctime = @cImport(@cInclude("time.h"));

pub const backend = struct {
    pub const clock = struct {
        pub fn now() ?platform.DateTime {
            var t: ctime.time_t = ctime.time(null);
            var tm: ctime.struct_tm = undefined;
            if (ctime.localtime_r(&t, &tm) == null) return null;
            return .{
                .year = @intCast(tm.tm_year + 1900),
                .month = @intCast(tm.tm_mon + 1),
                .day = @intCast(tm.tm_mday),
                .hour = @intCast(tm.tm_hour),
                .minute = @intCast(tm.tm_min),
                .second = @intCast(@min(tm.tm_sec, 59)),
            };
        }
    };
};

// One at a time:
var file: ?std.fs.File = null;
var vol: mfs.Volume = undefined;
var vol_path: []const u8 = "";

fn devRead(ctx: *const anyopaque, lba: u64, count: usize, buf: []u8) platform.Error!void {
    const f: *const std.fs.File = @ptrCast(@alignCast(ctx));
    const n = f.preadAll(buf[0 .. count * mfs.sector_size], lba * mfs.sector_size) catch return error.DeviceError;
    if (n != count * mfs.sector_size) return error.DeviceError;
}

fn devWrite(ctx: *const anyopaque, lba: u64, count: usize, data: []const u8) platform.Error!void {
    const f: *const std.fs.File = @ptrCast(@alignCast(ctx));
    f.pwriteAll(data[0 .. count * mfs.sector_size], lba * mfs.sector_size) catch return error.DeviceError;
}

// Block size 4096, opened for filling.
pub fn mkfs(img: []const u8, kib: u32) void {
    finish();
    files.remove(img);
    if (std.fs.path.dirname(img)) |dir| files.makeDir(dir);
    _ = mkmfs3.format(img, @as(u64, kib) * 1024, 4096, null) catch |err| files.fail("{s}: formatting: {s}", .{ img, @errorName(err) });
    file = std.fs.cwd().openFile(img, .{ .mode = .read_write }) catch |err| files.fail("{s}: {s}", .{ img, @errorName(err) });
    vol = mfs.mount(.{ .ctx = @ptrCast(&file.?), .read = devRead, .write = devWrite }, 0, @as(u64, kib) * 2) orelse
        files.fail("{s}: the Minix driver doesn't mount it", .{img});
    vol_path = img;
}

pub fn finish() void {
    const f = file orelse return;
    mfs.sync(&vol) catch |err| files.fail("{s}: {s}", .{ vol_path, @errorName(err) });
    f.close();
    file = null;
}

fn opened(img: []const u8) *mfs.Volume {
    if (file == null or !std.mem.eql(u8, img, vol_path)) files.fail("{s} is not the Minix image being made", .{img});
    return &vol;
}

// "/SYSTEM/FONTS" -> "\SYSTEM\FONTS"
fn dosPath(path: []const u8) []const u8 {
    const out = files.gpa.dupe(u8, path) catch unreachable;
    for (out) |*c| {
        if (c.* == '/') c.* = '\\';
    }
    return out;
}

// And those above it.
pub fn mkdirs(img: []const u8, path: []const u8) void {
    const v = opened(img);
    var at: []const u8 = "";
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        at = fmt("{s}\\{s}", .{ at, part });
        mfs.makeDir(v, at) catch |err| switch (err) {
            error.AlreadyExists => continue,
            else => files.fail("{s}: {s}: {s}", .{ img, at, @errorName(err) }),
        };
        const mode: u16 = if (std.ascii.eqlIgnoreCase(at, "\\TEMP")) 0o1777 else 0o755;
        mfs.setMode(v, at, mode) catch |err| files.fail("{s}: {s}: {s}", .{ img, at, @errorName(err) });
    }
}

// Replacing it.
pub fn copy(img: []const u8, from: []const u8, to: []const u8) void {
    const v = opened(img);
    const data = files.read(from);
    const path = dosPath(to);
    var f: mfs.File = .{};
    mfs.openFile(v, path, .write, &f) catch |err| files.fail("{s}: {s}: {s}", .{ img, to, @errorName(err) });
    var done: usize = 0;
    while (done < data.len) {
        const n = mfs.write(&f, data[done..]) catch |err| files.fail("{s}: {s}: {s}", .{ img, to, @errorName(err) });
        if (n == 0) files.fail("{s}: {s}: the volume is full", .{ img, to });
        done += n;
    }
    mfs.close(&f) catch |err| files.fail("{s}: {s}: {s}", .{ img, to, @errorName(err) });
    // Programs, and scripts executable on the host (demoa.sh)
    const host_exec = if (std.fs.cwd().statFile(from)) |st| st.mode & 0o111 != 0 else |_| false;
    const program = std.ascii.endsWithIgnoreCase(to, ".APP") or host_exec;
    mfs.setMode(v, path, if (program) 0o755 else 0o644) catch |err| files.fail("{s}: {s}: {s}", .{ img, to, @errorName(err) });
}
