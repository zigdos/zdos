// cut -c LIST | -f LIST [-d CHAR] [-s] [FILE...]
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const text = @import("text.zig");

const max_ranges = 64;

const Range = struct {
    first: u64,
    last: u64,
};

const Selection = struct {
    ranges: [max_ranges]Range = undefined,
    len: usize = 0,

    fn contains(self: Selection, position: u64) bool {
        for (self.ranges[0..self.len]) |range| {
            if (position >= range.first and position <= range.last) return true;
        }
        return false;
    }
};

pub fn run(args: []const []const u8) u8 {
    var fields: ?bool = null;
    var selection: Selection = .{};
    var delimiter: u8 = '\t';
    var suppress = false;
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    defer files.deinit(zdos.allocator);
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            files.appendSlice(zdos.allocator, args[i + 1 ..]) catch return outOfMemory();
            break;
        }
        if (arg.len < 2 or arg[0] != '-') {
            files.append(zdos.allocator, arg) catch return outOfMemory();
            continue;
        }
        switch (arg[1]) {
            'c', 'f', 'd' => {
                const value = if (arg.len > 2) arg[2..] else blk: {
                    i += 1;
                    break :blk if (i < args.len) args[i] else return usageError();
                };
                if (arg[1] == 'd') {
                    if (value.len != 1) return usageError();
                    delimiter = value[0];
                } else {
                    if (fields != null) return usageError();
                    fields = arg[1] == 'f';
                    selection = parseSelection(value) catch return usageError();
                }
            },
            's' => suppress = true,
            else => {
                errout.printf("cut: unknown option: {s}\n", .{arg});
                return 2;
            },
        }
    }
    const by_field = fields orelse return usageError();
    if (files.items.len == 0) files.append(zdos.allocator, "-") catch return outOfMemory();
    var out: text.Output = .{};
    defer out.deinit();
    var line: std.ArrayListUnmanaged(u8) = .{};
    defer line.deinit(zdos.allocator);
    var status: u8 = 0;
    for (files.items) |path| {
        var reader = text.Reader.open(path) catch |err| {
            errout.printf("cut: {s}: {s}\n", .{ path, zdos.message(err) });
            status = 1;
            continue;
        };
        defer reader.close();
        while (reader.readLine(zdos.allocator, &line) catch false) {
            const l = line.items;
            if (!by_field) {
                for (l, 1..) |c, k| if (selection.contains(k)) out.write(&.{c});
                out.write("\n");
                continue;
            }
            if (std.mem.indexOfScalar(u8, l, delimiter) == null) {
                if (!suppress) {
                    out.write(l);
                    out.write("\n");
                }
                continue;
            }
            var it = std.mem.splitScalar(u8, l, delimiter);
            var k: u64 = 1;
            var first = true;
            while (it.next()) |field| : (k += 1) {
                if (!selection.contains(k)) continue;
                if (!first) out.write(&.{delimiter});
                out.write(field);
                first = false;
            }
            out.write("\n");
        }
    }
    return status;
}

fn parseSelection(list: []const u8) error{InvalidSelection}!Selection {
    var result: Selection = .{};
    var parts = std.mem.splitScalar(u8, list, ',');
    while (parts.next()) |part| {
        if (part.len == 0 or result.len == result.ranges.len) return error.InvalidSelection;
        const dash = std.mem.indexOfScalar(u8, part, '-');
        var first: u64 = 1;
        var last: u64 = std.math.maxInt(u64);
        if (dash) |at| {
            if (std.mem.indexOfScalar(u8, part[at + 1 ..], '-') != null) return error.InvalidSelection;
            if (at > 0) first = std.fmt.parseInt(u64, part[0..at], 10) catch return error.InvalidSelection;
            if (at + 1 < part.len) last = std.fmt.parseInt(u64, part[at + 1 ..], 10) catch return error.InvalidSelection;
        } else {
            first = std.fmt.parseInt(u64, part, 10) catch return error.InvalidSelection;
            last = first;
        }
        if (first == 0 or last < first) return error.InvalidSelection;
        result.ranges[result.len] = .{ .first = first, .last = last };
        result.len += 1;
    }
    if (result.len == 0) return error.InvalidSelection;
    return result;
}

fn usageError() u8 {
    errout.print("usage: cut -c LIST | -f LIST [-d CHAR] [-s] [FILE...]\n");
    return 2;
}

fn outOfMemory() u8 {
    errout.print("cut: not enough memory\n");
    return 1;
}
