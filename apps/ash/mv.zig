const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");

// mv: moves or renames files and folders
pub fn run(args: []const []const u8) u8 {
    var paths: std.ArrayListUnmanaged([]const u8) = .{};
    defer paths.deinit(zdos.allocator);
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '-') {
            for (arg[1..]) |c| switch (c) {
                'f', 'v' => {},
                else => {
                    errout.printf("mv: unknown option: -{c}\n", .{c});
                    return 2;
                },
            };
        } else paths.append(zdos.allocator, arg) catch return 1;
    }
    if (paths.items.len < 2) {
        errout.print("usage: mv SOURCE... DEST\n");
        return 2;
    }
    const dest = paths.items[paths.items.len - 1];
    const sources = paths.items[0 .. paths.items.len - 1];
    if (sources.len > 1) {
        const entry = zdos.stat(dest) catch null;
        if (entry == null or !entry.?.is_dir) {
            errout.printf("mv: {s}: not a folder\n", .{dest});
            return 1;
        }
    }
    var status: u8 = 0;
    for (sources) |source| {
        if (moveOne(source, dest) != 0) status = 1;
    }
    return status;
}

fn moveOne(src: []const u8, dest: []const u8) u8 {
    _ = zdos.stat(src) catch |err| {
        printErrorPath(src, err);
        return 1;
    };
    var src_path_buf: [1028]u8 = undefined;
    const src_path = zdos.fullPath(src, &src_path_buf) catch src;
    var destination_buf: [1024]u8 = undefined;
    const destination = destinationFor(src, src_path, dest, &destination_buf) orelse {
        errout.print("mv: destination path too long\n");
        return 1;
    };
    var dst_path_buf: [1028]u8 = undefined;
    const dst_path = zdos.fullPath(destination, &dst_path_buf) catch destination;
    // Same file: nothing to do, unless only the capitalization typed for
    // the destination changes:
    const same_name = std.mem.eql(u8, src_path, dst_path);
    const new_name = lastName(destination);
    if (same_name and (std.mem.eql(u8, new_name, lastName(src_path)) or std.mem.eql(u8, new_name, lastName(src)))) return 0;
    if (!same_name) {
        if (zdos.stat(destination) catch null) |destination_entry| {
            if (destination_entry.is_dir) {
                errout.printf("mv: {s}: a folder is in the way\n", .{destination});
                return 1;
            }
            zdos.delete(destination) catch |err| {
                printErrorPath(destination, err);
                return 1;
            };
        }
    }
    zdos.move(src, destination) catch |err| {
        printErrorPath(src, err);
        return 1;
    };
    return 0;
}

// DEST/name when DEST is a folder other than the source itself ("mv
// Docs docs" names it in another case).
fn destinationFor(source: []const u8, source_path: []const u8, destination: []const u8, buffer: []u8) ?[]const u8 {
    const existing = zdos.stat(destination) catch return destination;
    if (!existing.is_dir) return destination;
    var path_buf: [1028]u8 = undefined;
    if (zdos.fullPath(destination, &path_buf)) |path| {
        if (std.mem.eql(u8, path, source_path)) return destination;
    } else |_| {}
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

// "E:/Docs/Report.txt/" -> "Report.txt"
fn lastName(path: []const u8) []const u8 {
    var n = path;
    while (n.len > 1 and (n[n.len - 1] == '/' or n[n.len - 1] == '\\')) n = n[0 .. n.len - 1];
    var i = n.len;
    while (i > 0 and n[i - 1] != '/' and n[i - 1] != '\\') i -= 1;
    // A drive is one letter: "C:name", not "id:01":
    if (i == 0 and n.len >= 2 and n[1] == ':' and std.ascii.isAlphabetic(n[0])) i = 2;
    return n[i..];
}

fn printErrorPath(path: []const u8, err: zdos.Error) void {
    errout.printf("mv: {s}: {s}\n", .{ path, zdos.message(err) });
}
