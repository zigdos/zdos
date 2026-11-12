const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");

pub fn run(args: []const []const u8) u8 {
    var recursive = false;
    var force = false;
    var result: u8 = 0;
    var has_operand = false;
    for (args) |path| {
        if (path.len > 1 and path[0] == '-') {
            for (path[1..]) |option| switch (option) {
                'r', 'R' => recursive = true,
                'f' => force = true,
                else => {
                    errout.printf("rm: unsupported option: -{c}\n", .{option});
                    return 2;
                },
            };
            continue;
        }
        has_operand = true;
        const entry = zdos.stat(path) catch |err| {
            if (!(force and (err == error.NotFound or err == error.PathNotFound))) printErrorPath(path, err);
            if (!force) result = 1;
            continue;
        };
        if (entry.is_dir and !recursive) {
            errout.printf("rm: {s}: is a directory (use -r)\n", .{path});
            result = 1;
            continue;
        }
        const delete_result = if (entry.is_dir) zdos.deleteTree(path) else zdos.delete(path);
        delete_result catch |err| {
            printErrorPath(path, err);
            result = 1;
        };
    }
    if (!has_operand) {
        errout.print("usage: rm [-r] [-f] PATH...\n");
        return 2;
    }
    return result;
}

fn printErrorPath(path: []const u8, err: zdos.Error) void {
    errout.printf("rm: {s}: {s}\n", .{ path, zdos.message(err) });
}
