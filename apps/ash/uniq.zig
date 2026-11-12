// uniq [-c] [-d | -u] [-i] [INPUT [OUTPUT]]
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const text = @import("text.zig");

pub fn run(args: []const []const u8) u8 {
    const a = zdos.allocator;
    var count = false;
    var only_repeated = false;
    var only_single = false;
    var ignore_case = false;
    var paths: [2][]const u8 = .{ "-", "" };
    var npaths: usize = 0;
    for (args) |arg| {
        if (arg.len > 1 and arg[0] == '-') {
            for (arg[1..]) |c| switch (c) {
                'c' => count = true,
                'd' => only_repeated = true,
                'u' => only_single = true,
                'i' => ignore_case = true,
                else => {
                    errout.printf("uniq: unknown option: -{c}\n", .{c});
                    return 2;
                },
            };
        } else {
            if (npaths == 2) {
                errout.print("usage: uniq [-c] [-d | -u] [-i] [INPUT [OUTPUT]]\n");
                return 2;
            }
            paths[npaths] = arg;
            npaths += 1;
        }
    }
    var reader = text.Reader.open(paths[0]) catch |err| {
        errout.printf("uniq: {s}: {s}\n", .{ paths[0], zdos.message(err) });
        return 1;
    };
    defer reader.close();
    var file: ?zdos.File = null;
    if (npaths == 2) file = zdos.open(paths[1], .write) catch |err| {
        errout.printf("uniq: {s}: {s}\n", .{ paths[1], zdos.message(err) });
        return 1;
    };
    defer if (file) |f| f.close();
    var out: text.Output = .{};
    defer out.deinit();
    var previous: std.ArrayListUnmanaged(u8) = .{};
    defer previous.deinit(a);
    var line: std.ArrayListUnmanaged(u8) = .{};
    defer line.deinit(a);
    var repeats: usize = 0;
    while (true) {
        const more = reader.readLine(a, &line) catch false;
        const same = more and repeats > 0 and (if (ignore_case)
            std.ascii.eqlIgnoreCase(previous.items, line.items)
        else
            std.mem.eql(u8, previous.items, line.items));
        if (same) {
            repeats += 1;
            continue;
        }
        if (repeats > 0 and (!only_repeated or repeats > 1) and (!only_single or repeats == 1)) {
            var buf: [24]u8 = undefined;
            var piece: std.ArrayListUnmanaged(u8) = .{};
            defer piece.deinit(a);
            if (count) piece.appendSlice(a, std.fmt.bufPrint(&buf, "{d:>7} ", .{repeats}) catch unreachable) catch {};
            piece.appendSlice(a, previous.items) catch {};
            piece.append(a, '\n') catch {};
            if (file) |f| f.writeAll(piece.items) catch {} else out.write(piece.items);
        }
        if (!more) break;
        previous.clearRetainingCapacity();
        previous.appendSlice(a, line.items) catch {
            errout.print("uniq: not enough memory\n");
            return 1;
        };
        repeats = 1;
    }
    return 0;
}
