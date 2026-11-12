const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");

pub fn run(args: []const []const u8) u8 {
    var parents = false;
    var first_path: usize = 0;
    while (first_path < args.len and args[first_path].len > 1 and args[first_path][0] == '-') : (first_path += 1) {
        if (std.mem.eql(u8, args[first_path], "-p")) {
            parents = true;
        } else {
            errout.printf("mkdir: unsupported option: {s}\n", .{args[first_path]});
            return 2;
        }
    }
    if (first_path == args.len) {
        errout.print("usage: mkdir [-p] PATH...\n");
        return 2;
    }
    var result: u8 = 0;
    for (args[first_path..]) |path| {
        if (parents) {
            if (makeParents(path)) |err| {
                printErrorPath(path, err);
                result = 1;
            }
        } else {
            zdos.makeDir(path) catch |err| {
                printErrorPath(path, err);
                result = 1;
            };
        }
    }
    return result;
}

fn makeParents(path: []const u8) ?zdos.Error {
    if (path.len == 0 or path.len > 1024) return error.InvalidName;
    var prefix: [1024]u8 = undefined;
    @memcpy(prefix[0..path.len], path);
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (prefix[i] != '/' and prefix[i] != '\\') continue;
        if (i == 0 or (i == 2 and prefix[1] == ':') or (i == 3 and prefix[0] == '/' and prefix[2] == ':')) continue;
        makeDirIfMissing(prefix[0..i]) catch |err| return err;
    }
    makeDirIfMissing(prefix[0..path.len]) catch |err| return err;
    return null;
}

fn makeDirIfMissing(path: []const u8) zdos.Error!void {
    zdos.makeDir(path) catch |err| {
        const entry = zdos.stat(path) catch return err;
        if (!entry.is_dir) return err;
    };
}

fn printErrorPath(path: []const u8, err: zdos.Error) void {
    errout.printf("mkdir: {s}: {s}\n", .{ path, zdos.message(err) });
}
