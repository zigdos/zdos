const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");

// cp: copies files (and, with -r, folders)
pub fn run(args: []const []const u8) u8 {
    var recursive = false;
    var paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer paths.deinit(zdos.allocator);
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '-') {
            for (arg[1..]) |c| switch (c) {
                'r', 'R' => recursive = true,
                'f', 'p', 'v' => {},
                else => {
                    errout.printf("cp: unknown option: -{c}\n", .{c});
                    return 2;
                },
            };
        } else paths.append(zdos.allocator, arg) catch return 1;
    }
    if (paths.items.len < 2) {
        errout.print("usage: cp [-r] SOURCE... DEST\n");
        return 2;
    }
    const dest = paths.items[paths.items.len - 1];
    const sources = paths.items[0 .. paths.items.len - 1];
    if (sources.len > 1) {
        const entry = zdos.stat(dest) catch null;
        if (entry == null or !entry.?.is_dir) {
            errout.printf("cp: {s}: not a folder\n", .{dest});
            return 1;
        }
    }
    var status: u8 = 0;
    for (sources) |source| {
        if (copyOne(source, dest, recursive) != 0) status = 1;
    }
    return status;
}

const big_size = 64 * 1024;

fn copyOne(src: []const u8, dest: []const u8, recursive: bool) u8 {
    const source = zdos.stat(src) catch |err| {
        printErrorPath(src, err);
        return 1;
    };
    var destination_buf: [1024]u8 = undefined;
    const destination = destinationFor(src, dest, &destination_buf) orelse {
        errout.print("cp: destination path too long\n");
        return 1;
    };
    if (source.is_dir) {
        if (!recursive) {
            errout.printf("cp: {s}: is a folder (use -r)\n", .{src});
            return 1;
        }
        zdos.copy(src, destination) catch |err| {
            printErrorPath(destination, err);
            return 1;
        };
        return 0;
    }
    var src_path_buf: [1028]u8 = undefined;
    var dst_path_buf: [1028]u8 = undefined;
    const src_path = zdos.fullPath(src, &src_path_buf) catch src;
    const dst_path = zdos.fullPath(destination, &dst_path_buf) catch destination;
    // fullPath spells existing names as on disk: one file gives equal
    // paths (on FAT also in other case):
    if (std.mem.eql(u8, src_path, dst_path)) {
        errout.printf("cp: {s}: same file\n", .{src});
        return 1;
    }

    const input = zdos.open(src, .read) catch |err| {
        printErrorPath(src, err);
        return 1;
    };
    defer closeFile(input);
    const output = zdos.open(destination, .write) catch |err| {
        printErrorPath(destination, err);
        return 1;
    };
    // 64 KiB per read and write for fewer disk requests; 4 KiB on the
    // stack without the memory:
    var small: [4096]u8 = undefined;
    const big = zdos.alloc(big_size);
    defer zdos.free(big);
    const buffer: []u8 = if (big) |b| b[0..big_size] else &small;
    while (true) {
        const count = input.read(buffer) catch |err| {
            printErrorPath(src, err);
            closeFile(output);
            return 1;
        };
        if (count == 0) break;
        output.writeAll(buffer[0..count]) catch |err| {
            printErrorPath(destination, err);
            closeFile(output);
            return 1;
        };
    }
    output.closeChecked() catch |err| {
        printErrorPath(destination, err);
        return 1;
    };
    zdos.copyMode(src, destination);
    return 0;
}

fn destinationFor(source: []const u8, destination: []const u8, buffer: []u8) ?[]const u8 {
    const existing = zdos.stat(destination) catch return destination;
    if (!existing.is_dir) return destination;
    const base = source[if (std.mem.lastIndexOfAny(u8, source, "/\\")) |slash| slash + 1 else 0..];
    if (base.len == 0) return null;
    var len = destination.len;
    while (len > 1 and (destination[len - 1] == '/' or destination[len - 1] == '\\')) : (len -= 1) {}
    const separator: usize = if (len > 0 and destination[len - 1] != '/' and destination[len - 1] != '\\') 1 else 0;
    if (len + separator + base.len > buffer.len) return null;
    @memcpy(buffer[0..len], destination[0..len]);
    if (separator == 1) buffer[len] = '/';
    @memcpy(buffer[len + separator ..][0..base.len], base);
    return buffer[0 .. len + separator + base.len];
}

fn closeFile(file: zdos.File) void {
    file.closeChecked() catch |err| errout.printf("cp: close: {s}\n", .{zdos.message(err)});
}

fn printErrorPath(path: []const u8, err: zdos.Error) void {
    errout.printf("cp: {s}: {s}\n", .{ path, zdos.message(err) });
}
