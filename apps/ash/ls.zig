const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");

pub fn run(args: []const []const u8) u8 {
    var show_hidden = false;
    var long_format = false;
    var directory_only = false;
    var human_readable = false;
    var show_inode = false;
    var paths: [32][]const u8 = undefined;
    var path_count: usize = 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "-A")) {
            show_hidden = true;
        } else if (std.mem.eql(u8, arg, "-l")) {
            long_format = true;
        } else if (std.mem.eql(u8, arg, "-d")) {
            directory_only = true;
        } else if (std.mem.eql(u8, arg, "-h")) {
            human_readable = true;
        } else if (std.mem.eql(u8, arg, "-i")) {
            show_inode = true;
        } else if (arg.len > 2 and arg[0] == '-') {
            for (arg[1..]) |option| switch (option) {
                'a', 'A' => show_hidden = true,
                'l' => long_format = true,
                'd' => directory_only = true,
                'h' => human_readable = true,
                'i' => show_inode = true,
                else => {
                    errout.printf("ls: unsupported option: -{c}\n", .{option});
                    return 2;
                },
            };
        } else if (arg.len > 1 and arg[0] == '-') {
            errout.printf("ls: unsupported option: {s}\n", .{arg});
            return 2;
        } else if (path_count < paths.len) {
            paths[path_count] = arg;
            path_count += 1;
        } else {
            errout.print("ls: too many paths\n");
            return 2;
        }
    }
    if (path_count == 0) {
        paths[0] = ".";
        path_count = 1;
    }
    var result: u8 = 0;
    for (paths[0..path_count], 0..) |path, index| {
        if (path_count > 1) zdos.printf("{s}:\n", .{path});
        const entry = zdos.stat(path) catch |err| {
            printErrorPath(path, err);
            result = 1;
            continue;
        };
        if (!entry.is_dir or directory_only) {
            if (show_inode) printInode(path);
            printDirEntry(path, path, entry, long_format, human_readable);
            continue;
        }
        const dir = zdos.openDir(path) catch |err| {
            printErrorPath(path, err);
            result = 1;
            continue;
        };
        // Sorted by name, as Unix ls:
        var items: std.ArrayListUnmanaged(zdos.DirEntry) = .{};
        defer items.deinit(zdos.allocator);
        var item: zdos.DirEntry = undefined;
        while (dir.next(&item)) |has_item| {
            if (!has_item) break;
            const name = item.name();
            if (!show_hidden and (name[0] == '.' or item.attrs & zdos.Attr.hidden != 0)) continue;
            items.append(zdos.allocator, item) catch {
                errout.print("ls: not enough memory\n");
                result = 1;
                break;
            };
        } else |err| {
            printErrorPath(path, err);
            result = 1;
        }
        dir.close();
        std.sort.heap(zdos.DirEntry, items.items, {}, struct {
            fn less(_: void, x: zdos.DirEntry, y: zdos.DirEntry) bool {
                return std.ascii.lessThanIgnoreCase(x.name(), y.name());
            }
        }.less);
        for (items.items) |*e| {
            var full_buf: [1100]u8 = undefined;
            const sep: []const u8 = if (path.len > 0 and (path[path.len - 1] == '/' or path[path.len - 1] == '\\')) "" else "/";
            const full = std.fmt.bufPrint(&full_buf, "{s}{s}{s}", .{ path, sep, e.name() }) catch e.name();
            if (show_inode) printInode(full);
            printDirEntry(e.name(), full, e.*, long_format, human_readable);
        }
        if (index + 1 < path_count) zdos.print("\n");
    }
    return result;
}

// -i: the file system's inode number; '-' where it has none (FAT)
fn printInode(full: []const u8) void {
    if (zdos.statEx(full)) |x| {
        if (x.valid & zdos.StatValid.ino != 0) return zdos.printf("{d:>8} ", .{x.ino});
    } else |_| {}
    zdos.print("       - ");
}

// full: the path to it, for its permissions.
fn printDirEntry(name: []const u8, full: []const u8, entry: zdos.DirEntry, long_format: bool, human_readable: bool) void {
    if (long_format) {
        if (zdos.permissions(full)) |p| {
            var mode_buf: [10]u8 = undefined;
            zdos.printf("{s} ", .{modeString(p.mode, &mode_buf)});
            // FAT's owners are made up by place, but enforced as such:
            zdos.printf("{d:>5} {d:>5} ", .{ p.uid, p.gid });
        } else |_| {
            zdos.print(if (entry.is_dir) "d" else "-");
            zdos.print(if (entry.attrs & zdos.Attr.read_only != 0) "r-- " else "rw- ");
        }
        if (human_readable) {
            var size_buf: [8]u8 = undefined;
            const size = formatSize(entry.size, &size_buf);
            zdos.printf("{s:>10} ", .{size});
        } else {
            zdos.printf("{d:>10} ", .{entry.size});
        }
        zdos.printf("{d:04}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} ", .{
            entry.modified.year,
            entry.modified.month,
            entry.modified.day,
            entry.modified.hour,
            entry.modified.minute,
        });
    }
    const color = if (zdos.outputRedirected()) null else nameColor(name, entry);
    if (color) |code| zdos.print(code);
    zdos.print(name);
    if (entry.is_dir) zdos.print("/");
    if (color != null) zdos.print("\x1b[39m");
    zdos.print("\n");
}

// s / S, t / T for setuid, setgid, sticky.
fn modeString(mode: u32, buf: *[10]u8) []const u8 {
    buf[0] = switch (mode & 0o170000) {
        0o040000 => 'd',
        0o120000 => 'l',
        0o020000 => 'c',
        0o060000 => 'b',
        0o010000 => 'p',
        0o140000 => 's',
        else => '-',
    };
    const rwx = "rwxrwxrwx";
    for (0..9) |i| {
        buf[1 + i] = if (mode & (@as(u32, 0o400) >> @intCast(i)) != 0) rwx[i] else '-';
    }
    const special = [_]struct { bit: u32, at: usize, set: u8 }{
        .{ .bit = 0o4000, .at = 3, .set = 's' },
        .{ .bit = 0o2000, .at = 6, .set = 's' },
        .{ .bit = 0o1000, .at = 9, .set = 't' },
    };
    for (special) |sp| {
        if (mode & sp.bit != 0) buf[sp.at] = if (buf[sp.at] == 'x') sp.set else std.ascii.toUpper(sp.set);
    }
    return buf;
}

fn nameColor(name: []const u8, entry: zdos.DirEntry) ?[]const u8 {
    if (entry.is_dir) return "\x1b[94m";

    if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| {
        const extension = name[dot + 1 ..];
        for ([_][]const u8{ "APP", "CMD", "BAT", "EXE", "SH" }) |executable| {
            if (std.ascii.eqlIgnoreCase(extension, executable)) return "\x1b[92m";
        }
        // Archive files (not the FAT archive attribute, which most files have):
        for ([_][]const u8{ "ZIP", "TAR", "GZ", "TGZ", "7Z" }) |archive| {
            if (std.ascii.eqlIgnoreCase(extension, archive)) return "\x1b[91m";
        }
    }

    if (entry.attrs & zdos.Attr.system != 0) return "\x1b[93m";
    return null;
}

fn formatSize(bytes: u64, buffer: *[8]u8) []const u8 {
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

fn printErrorPath(path: []const u8, err: zdos.Error) void {
    errout.printf("ls: {s}: {s}\n", .{ path, zdos.message(err) });
}
