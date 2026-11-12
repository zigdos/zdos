const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");

pub fn run(args: []const []const u8) u8 {
    if (args.len == 0) {
        errout.print("usage: rmdir PATH...\n");
        return 2;
    }
    var result: u8 = 0;
    for (args) |path| {
        const dir = zdos.openDir(path) catch |err| {
            printErrorPath(path, err);
            result = 1;
            continue;
        };
        var empty = true;
        var entry: zdos.DirEntry = undefined;
        while (dir.next(&entry)) |has_entry| {
            if (!has_entry) break;
            if (!std.mem.eql(u8, entry.name(), ".") and !std.mem.eql(u8, entry.name(), "..")) {
                empty = false;
                break;
            }
        } else |err| {
            dir.close();
            printErrorPath(path, err);
            result = 1;
            continue;
        }
        dir.close();
        if (!empty) {
            errout.printf("rmdir: {s}: directory not empty\n", .{path});
            result = 1;
            continue;
        }
        zdos.deleteTree(path) catch |err| {
            printErrorPath(path, err);
            result = 1;
        };
    }
    return result;
}

fn printErrorPath(path: []const u8, err: zdos.Error) void {
    errout.printf("rmdir: {s}: {s}\n", .{ path, zdos.message(err) });
}
