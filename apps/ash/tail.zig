// tail [-n N | -N | -n +N] [FILE...]: +N from line N on
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const text = @import("text.zig");

pub fn run(args: []const []const u8) u8 {
    var count: usize = 10;
    var from_start = false;
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    defer files.deinit(zdos.allocator);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            files.appendSlice(zdos.allocator, args[i + 1 ..]) catch return outOfMemory();
            break;
        }
        var value: ?[]const u8 = null;
        if (std.mem.startsWith(u8, arg, "-n")) {
            value = if (arg.len > 2) arg[2..] else blk: {
                i += 1;
                break :blk if (i < args.len) args[i] else return usage();
            };
        } else if (arg.len > 1 and arg[0] == '-' and std.ascii.isDigit(arg[1])) {
            value = arg[1..];
        } else if (arg.len > 1 and arg[0] == '-') {
            return usage();
        } else {
            files.append(zdos.allocator, arg) catch return outOfMemory();
            continue;
        }
        var v = value.?;
        from_start = v.len > 0 and v[0] == '+';
        if (from_start or (v.len > 0 and v[0] == '-')) v = v[1..];
        count = std.fmt.parseInt(usize, v, 10) catch return usage();
    }
    if (files.items.len == 0) files.append(zdos.allocator, "-") catch return outOfMemory();
    var out: text.Output = .{};
    defer out.deinit();
    var status: u8 = 0;
    for (files.items, 0..) |path, k| {
        var reader = text.Reader.open(path) catch |err| {
            errout.printf("tail: {s}: {s}\n", .{ path, zdos.message(err) });
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
        if (!tailOf(&reader, count, from_start, &out)) status = 1;
    }
    return status;
}

fn tailOf(reader: *text.Reader, count: usize, from_start: bool, out: *text.Output) bool {
    const a = zdos.allocator;
    var line: std.ArrayListUnmanaged(u8) = .{};
    defer line.deinit(a);
    if (from_start) {
        var n: usize = 1;
        while (reader.readLine(a, &line) catch false) : (n += 1) {
            if (n < count) continue;
            out.write(line.items);
            if (reader.newline) out.write("\n");
        }
        return true;
    }
    // The last count lines, in a ring:
    const ring = a.alloc(?[]u8, count) catch return outOfMemory() == 0;
    defer {
        for (ring) |r| if (r) |s| a.free(s);
        a.free(ring);
    }
    @memset(ring, null);
    var next: usize = 0;
    var total: usize = 0;
    var last_newline = true;
    while (reader.readLine(a, &line) catch false) {
        if (count == 0) continue;
        const copy = a.dupe(u8, line.items) catch return outOfMemory() == 0;
        if (ring[next]) |old| a.free(old);
        ring[next] = copy;
        next = (next + 1) % count;
        total += 1;
        last_newline = reader.newline;
    }
    const n = @min(total, count);
    for (0..n) |k| {
        const s = ring[(next + count - n + k) % count].?;
        out.write(s);
        if (k + 1 < n or last_newline) out.write("\n");
    }
    return true;
}

fn usage() u8 {
    errout.print("usage: tail [-n LINES | -LINES | -n +LINE] [FILE...]\n");
    return 2;
}

fn outOfMemory() u8 {
    errout.print("tail: not enough memory\n");
    return 1;
}
