const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const sys = @import("../zdos/system.zig");

// df [-a] [-h] [-T] [PATH...]
pub fn run(args: []const []const u8) u8 {
    var human_readable = false;
    var print_type = false;
    var all_drives = false;
    var operands: [32][]const u8 = undefined;
    var operand_count: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--human-readable")) {
            human_readable = true;
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all")) {
            all_drives = true;
        } else if (std.mem.eql(u8, arg, "--print-type")) {
            print_type = true;
        } else if (arg.len > 1 and arg[0] == '-' and !std.mem.startsWith(u8, arg, "--")) {
            for (arg[1..]) |option| switch (option) {
                'a' => all_drives = true,
                'h' => human_readable = true,
                'T' => print_type = true,
                else => {
                    errout.printf("df: unsupported option: -{c}\n", .{option});
                    return 2;
                },
            };
        } else {
            if (operand_count == operands.len) {
                errout.print("df: too many operands\n");
                return 2;
            }
            operands[operand_count] = arg;
            operand_count += 1;
        }
    }

    zdos.printf("{s:<10} ", .{"Filesystem"});
    if (print_type) zdos.printf("{s:<6} ", .{"Type"});
    zdos.printf("{s:>10} {s:>10} {s:>10} {s:>5} {s}\n", .{
        "Size", "Used", "Available", "Use%", "Mounted on",
    });
    var found = false;
    var failed = false;
    if (operand_count == 0) {
        var index: u32 = 0;
        while (sys.driveAt(index)) |drive| : (index += 1) {
            if (drive.letter == 0 or (!drive.ready and !all_drives)) continue;
            found = true;
            printDrive(drive, human_readable, print_type);
        }
    } else {
        for (operands[0..operand_count]) |path| {
            const drive_letter = driveLetter(path) catch |err| {
                errout.printf("df: {s}: {s}\n", .{ path, zdos.message(err) });
                failed = true;
                continue;
            };
            const drive = zdos.driveInfo(drive_letter) catch |err| {
                errout.printf("df: {s}: {s}\n", .{ path, zdos.message(err) });
                failed = true;
                continue;
            };
            if (!drive.ready and !all_drives) {
                errout.printf("df: {s}: drive is not ready\n", .{path});
                failed = true;
                continue;
            }
            found = true;
            printDrive(drive, human_readable, print_type);
        }
    }
    if (!found) {
        if (operand_count == 0) errout.print("df: no readable drives\n");
        return 1;
    }
    return if (failed) 1 else 0;
}

fn driveLetter(path: []const u8) zdos.Error!u8 {
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') {
        return std.ascii.toUpper(path[0]);
    }
    if (path.len >= 4 and path[0] == '/' and std.ascii.isAlphabetic(path[1]) and path[2] == ':' and path[3] == '/') {
        return std.ascii.toUpper(path[1]);
    }
    var buffer: [1028]u8 = undefined;
    const full_path = try zdos.fullPath(path, &buffer);
    if (full_path.len < 2 or !std.ascii.isAlphabetic(full_path[0]) or full_path[1] != ':') return error.InvalidName;
    return std.ascii.toUpper(full_path[0]);
}

fn printDrive(drive: zdos.DriveInfo, human_readable: bool, print_type: bool) void {
    const filesystem: [2]u8 = .{ drive.letter, ':' };
    zdos.printf("{s:<10} ", .{filesystem[0..]});
    if (print_type) {
        const kind = zdos.fileSystemName(drive.file_system);
        zdos.printf("{s:<6} ", .{if (drive.ready and kind.len > 0) kind else "-"});
    }
    if (!drive.ready) {
        zdos.printf("{s:>10} {s:>10} {s:>10} {s:>5} /{c}:/\n", .{
            "-", "-", "-", "-", drive.letter,
        });
        return;
    }

    const used = drive.size -| drive.free;
    if (human_readable) {
        var size_buf: [4]u8 = undefined;
        var used_buf: [4]u8 = undefined;
        var free_buf: [4]u8 = undefined;
        zdos.printf("{s:>10} {s:>10} {s:>10}", .{
            formatSize(drive.size, &size_buf),
            formatSize(used, &used_buf),
            formatSize(drive.free, &free_buf),
        });
    } else {
        zdos.printf("{d:>10} {d:>10} {d:>10}", .{
            drive.size / 1024,
            used / 1024,
            drive.free / 1024,
        });
    }
    const percent: u128 = if (drive.size == 0) 0 else (@as(u128, used) * 100 + drive.size / 2) / drive.size;
    zdos.printf(" {d:>4}% /{c}:/\n", .{ percent, drive.letter });
}

fn formatSize(bytes: u64, buffer: *[4]u8) []const u8 {
    if (bytes < 1000) {
        return std.fmt.bufPrint(buffer, "{d}B", .{bytes}) catch unreachable;
    }
    const units = [_]u8{ 'K', 'M', 'G', 'T', 'P', 'E' };
    var divisor: u64 = 1024;
    var unit_index: usize = 0;
    while (unit_index + 1 < units.len and bytes / divisor >= 1024) : (unit_index += 1) {
        divisor *= 1024;
    }
    var tenths = (@as(u128, bytes) * 10 + divisor / 2) / divisor;
    if (tenths >= 10_000 and unit_index + 1 < units.len) {
        divisor *= 1024;
        unit_index += 1;
        tenths = (@as(u128, bytes) * 10 + divisor / 2) / divisor;
    }
    if (tenths < 100) {
        return std.fmt.bufPrint(buffer, "{d}.{d}{c}", .{
            tenths / 10,
            tenths % 10,
            units[unit_index],
        }) catch unreachable;
    }
    const rounded = (tenths + 5) / 10;
    return std.fmt.bufPrint(buffer, "{d}{c}", .{ rounded, units[unit_index] }) catch unreachable;
}
