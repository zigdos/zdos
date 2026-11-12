// VOL [X:]: a drive's label, serial, file system, block size and space
const std = @import("std");
const zdos = @import("zdos/zdos.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    const a = std.mem.trim(u8, args, " \t");
    var letter: u8 = 0;
    if (a.len == 2 and a[1] == ':' and std.ascii.isAlphabetic(a[0])) {
        letter = std.ascii.toUpper(a[0]);
    } else if (a.len == 0) {
        var cwd_buf: [512]u8 = undefined;
        const cwd = zdos.getCwd(&cwd_buf);
        if (cwd.len == 0) {
            zdos.print("No drive selected\n");
            return 1;
        }
        letter = cwd[0];
    } else {
        zdos.print("Usage: VOL [X:]\n");
        return 1;
    }
    const info = zdos.driveInfo(letter) catch {
        zdos.print("Invalid drive specification\n");
        return 1;
    };

    zdos.printf(" Volume in drive {c} ", .{letter});
    if (info.label_len > 0) zdos.printf("is {s}\n", .{info.label()}) else zdos.print("has no label\n");
    if (info.has_serial) zdos.printf(" Volume Serial Number is {X:0>4}-{X:0>4}\n", .{ info.serial >> 16, info.serial & 0xFFFF });
    const name = zdos.fileSystemName(info.file_system);
    if (name.len > 0) zdos.printf(" File system is {s}\n", .{name});
    if (info.block_size > 0) zdos.printf(" Block size is {d} bytes\n", .{info.block_size});
    if (!info.ready or info.size == 0) return 0;

    const used = info.size -| info.free;
    const percent = (@as(u128, used) * 100 + info.size / 2) / info.size;
    var total_buf: [32]u8 = undefined;
    const total_text = grouped(info.size, &total_buf);
    var pct_buf: [16]u8 = undefined;
    const pct = std.fmt.bufPrint(&pct_buf, ", {d}%", .{percent}) catch "";
    zdos.print("\n");
    space("Total", info.size, total_text.len, "");
    space("Used", used, total_text.len, pct);
    space("Available", info.free, total_text.len, "");
    return 0;
}

// " Used        33,858,560 bytes  (32.3 MB, 53%)"
fn space(label: []const u8, bytes: u64, width: usize, suffix: []const u8) void {
    var buf: [32]u8 = undefined;
    const text = grouped(bytes, &buf);
    zdos.printf(" {s: <11}", .{label});
    for (text.len..width) |_| zdos.print(" ");
    zdos.printf("{s} bytes  (", .{text});
    human(bytes);
    zdos.printf("{s})\n", .{suffix});
}

// 1234567 -> "1,234,567"
fn grouped(n: u64, buf: *[32]u8) []const u8 {
    var digits: [20]u8 = undefined;
    const d = std.fmt.bufPrint(&digits, "{d}", .{n}) catch unreachable;
    var len: usize = 0;
    for (d, 0..) |c, i| {
        if (i > 0 and (d.len - i) % 3 == 0) {
            buf[len] = ',';
            len += 1;
        }
        buf[len] = c;
        len += 1;
    }
    return buf[0..len];
}

// "61.0 MB": one decimal, in the largest unit that keeps it at least 1.
fn human(bytes: u64) void {
    const units = [_][]const u8{ "bytes", "KB", "MB", "GB", "TB" };
    var unit: usize = 0;
    var scale: u64 = 1;
    while (unit + 1 < units.len and bytes / scale >= 1024) {
        scale *= 1024;
        unit += 1;
    }
    if (unit == 0) return zdos.printf("{d} bytes", .{bytes});
    const tenths = (@as(u128, bytes) * 10 + scale / 2) / scale;
    zdos.printf("{d}.{d} {s}", .{ tenths / 10, tenths % 10, units[unit] });
}
