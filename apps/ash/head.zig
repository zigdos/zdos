// head [-n N | -N] [-c BYTES] [FILE...]
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const text = @import("text.zig");

pub fn run(args: []const []const u8) u8 {
    var count: usize = 10;
    var bytes = false;
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    defer files.deinit(zdos.allocator);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            files.appendSlice(zdos.allocator, args[i + 1 ..]) catch return outOfMemory();
            break;
        }
        if (arg.len > 1 and arg[0] == '-' and (arg[1] == 'n' or arg[1] == 'c')) {
            bytes = arg[1] == 'c';
            const value = if (arg.len > 2) arg[2..] else blk: {
                i += 1;
                break :blk if (i < args.len) args[i] else return usage();
            };
            count = std.fmt.parseInt(usize, value, 10) catch return usage();
        } else if (arg.len > 1 and arg[0] == '-' and std.ascii.isDigit(arg[1])) {
            count = std.fmt.parseInt(usize, arg[1..], 10) catch return usage();
        } else if (arg.len > 1 and arg[0] == '-') {
            return usage();
        } else files.append(zdos.allocator, arg) catch return outOfMemory();
    }
    if (files.items.len == 0) files.append(zdos.allocator, "-") catch return outOfMemory();
    var out: text.Output = .{};
    defer out.deinit();
    var line: std.ArrayListUnmanaged(u8) = .{};
    defer line.deinit(zdos.allocator);
    var status: u8 = 0;
    for (files.items, 0..) |path, k| {
        var reader = text.Reader.open(path) catch |err| {
            errout.printf("head: {s}: {s}\n", .{ path, zdos.message(err) });
            status = 1;
            continue;
        };
        defer reader.close();
        if (files.items.len > 1) {
            if (k > 0) out.write("\n");
            out.write("==> ");
            out.write(path);
            out.write(" <==\n");
        }
        if (bytes) {
            var left = count;
            while (left > 0) : (left -= 1) {
                const c = (reader.readByte() catch null) orelse break;
                out.write(&.{c});
            }
            continue;
        }
        var n: usize = 0;
        while (n < count and (reader.readLine(zdos.allocator, &line) catch false)) : (n += 1) {
            out.write(line.items);
            if (reader.newline) out.write("\n");
        }
    }
    return status;
}

fn usage() u8 {
    errout.print("usage: head [-n LINES | -LINES] [-c BYTES] [FILE...]\n");
    return 2;
}

fn outOfMemory() u8 {
    errout.print("head: not enough memory\n");
    return 1;
}
