const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const path_list = @import("../command/path_list.zig");

const Allocator = std.mem.Allocator;

// Tried after a name without one. Programs and batch
// files are ZDOS ones (capitals); scripts as on Unix (on
// ext2 and Minix case counts).
const extensions = [_][]const u8{ ".APP", ".CMD", ".BAT", ".EXE", ".sh" };

pub fn find(allocator: Allocator, name: []const u8) Allocator.Error![][]const u8 {
    var matches: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer matches.deinit(allocator);

    const has_path = std.mem.indexOfAny(u8, name, "/\\:") != null;
    try findInDirectory(allocator, &matches, ".", name);
    if (!has_path) {
        var path_buffer: [1024]u8 = undefined;
        if (zdos.getVar("PATH", &path_buffer)) |path| {
            var directories = path_list.Iterator{ .value = path };
            while (directories.next()) |raw_directory| {
                const directory = std.mem.trim(u8, raw_directory, " \t");
                if (directory.len == 0) continue;
                try findInDirectory(allocator, &matches, directory, name);
            }
        }
    }
    return matches.toOwnedSlice(allocator);
}

fn findInDirectory(
    allocator: Allocator,
    matches: *std.ArrayListUnmanaged([]const u8),
    directory: []const u8,
    name: []const u8,
) Allocator.Error!void {
    if (hasExtension(name)) {
        _ = try addIfFile(allocator, matches, try joinPath(allocator, directory, name));
        return;
    }

    const exact = try joinPath(allocator, directory, name);
    _ = try addIfFile(allocator, matches, exact);
    for (extensions) |extension| {
        const candidate = try std.fmt.allocPrint(allocator, "{s}{s}", .{ name, extension });
        _ = try addIfFile(allocator, matches, try joinPath(allocator, directory, candidate));
    }
}

fn addIfFile(
    allocator: Allocator,
    matches: *std.ArrayListUnmanaged([]const u8),
    path: []const u8,
) Allocator.Error!bool {
    const entry = zdos.stat(path) catch return false;
    if (entry.is_dir) return false;
    try matches.append(allocator, path);
    return true;
}

fn joinPath(allocator: Allocator, directory: []const u8, name: []const u8) Allocator.Error![]const u8 {
    if (std.mem.eql(u8, directory, ".")) return allocator.dupe(u8, name);
    const separator = if (std.mem.endsWith(u8, directory, "/") or
        std.mem.endsWith(u8, directory, "\\") or std.mem.endsWith(u8, directory, ":")) "" else "/";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ directory, separator, name });
}

fn hasExtension(name: []const u8) bool {
    const base = if (std.mem.lastIndexOfAny(u8, name, "/\\")) |separator| name[separator + 1 ..] else name;
    return std.mem.indexOfScalar(u8, base, '.') != null;
}
