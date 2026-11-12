const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");

pub fn run(args: []const []const u8) u8 {
    var no_create = false;
    var first_path: usize = 0;
    while (first_path < args.len) {
        const arg = args[first_path];
        if (std.mem.eql(u8, arg, "--")) {
            first_path += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--no-create")) {
            first_path += 1;
            no_create = true;
            continue;
        }
        if (arg.len > 1 and arg[0] == '-') {
            errout.printf("touch: unsupported option: {s}\n", .{arg});
            return 2;
        }
        break;
    }
    if (first_path == args.len) {
        errout.print("usage: touch [-c] [--] FILE...\n");
        return 2;
    }

    const now = zdos.getTime();
    var result: u8 = 0;
    for (args[first_path..]) |path| {
        const entry = zdos.stat(path) catch |err| {
            if (no_create) {
                if (err != error.NotFound and err != error.PathNotFound) {
                    printError(path, err);
                    result = 1;
                }
                continue;
            }
            if (err != error.NotFound and err != error.PathNotFound) {
                printError(path, err);
                result = 1;
                continue;
            }
            createFile(path) catch |create_err| {
                printError(path, create_err);
                result = 1;
                continue;
            };
            zdos.setFileTime(path, now) catch |time_err| {
                printError(path, time_err);
                result = 1;
            };
            continue;
        };
        _ = entry;
        zdos.setFileTime(path, now) catch |err| {
            printError(path, err);
            result = 1;
        };
    }
    return result;
}

fn createFile(path: []const u8) zdos.Error!void {
    const file = try zdos.open(path, .write);
    try file.closeChecked();
}

fn printError(path: []const u8, err: zdos.Error) void {
    errout.printf("touch: {s}: {s}\n", .{ path, zdos.message(err) });
}
