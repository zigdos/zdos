// sort [-rnfu] [-t CHAR] [-k POS1[,POS2]]... [FILE...]: all in memory
// Without -t a field is its leading blanks and the text after them.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const text = @import("text.zig");

const Allocator = std.mem.Allocator;

const Key = struct {
    start_field: usize, // from 1
    start_char: usize = 1,
    end_field: ?usize = null, // null: to the end of the line
    end_char: ?usize = null,
    numeric: bool = false,
    reverse: bool = false,
    fold: bool = false,
};

const Options = struct {
    keys: []const Key,
    separator: ?u8,
    numeric: bool,
    reverse: bool,
    fold: bool,
};

pub fn run(args: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(zdos.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var keys: std.ArrayListUnmanaged(Key) = .{};
    var opts: Options = .{ .keys = &.{}, .separator = null, .numeric = false, .reverse = false, .fold = false };
    var unique = false;
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            files.appendSlice(a, args[i + 1 ..]) catch return outOfMemory();
            break;
        }
        if (arg.len < 2 or arg[0] != '-') {
            files.append(a, arg) catch return outOfMemory();
            continue;
        }
        var k: usize = 1;
        while (k < arg.len) : (k += 1) {
            switch (arg[k]) {
                'r' => opts.reverse = true,
                'n' => opts.numeric = true,
                'f' => opts.fold = true,
                'u' => unique = true,
                'b' => {},
                't', 'k' => {
                    const value = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                        i += 1;
                        if (i >= args.len) return usage();
                        break :blk args[i];
                    };
                    if (arg[k] == 't') {
                        if (value.len != 1) {
                            errout.print("sort: -t takes one character\n");
                            return 2;
                        }
                        opts.separator = value[0];
                    } else {
                        keys.append(a, parseKey(value) orelse {
                            errout.printf("sort: bad key: {s}\n", .{value});
                            return 2;
                        }) catch return outOfMemory();
                    }
                    break;
                },
                else => {
                    errout.printf("sort: unknown option: -{c}\n", .{arg[k]});
                    return 2;
                },
            }
        }
    }
    opts.keys = keys.items;

    var lines: std.ArrayListUnmanaged([]const u8) = .{};
    if (files.items.len == 0) files.append(a, "-") catch return outOfMemory();
    for (files.items) |path| {
        var reader = text.Reader.open(path) catch |err| {
            errout.printf("sort: {s}: {s}\n", .{ path, zdos.message(err) });
            return 2;
        };
        defer reader.close();
        var line: std.ArrayListUnmanaged(u8) = .{};
        while (reader.readLine(a, &line) catch return outOfMemory()) {
            lines.append(a, a.dupe(u8, line.items) catch return outOfMemory()) catch return outOfMemory();
        }
    }

    std.sort.heap([]const u8, lines.items, opts, lessThan);
    var out = text.Output{};
    defer out.deinit();
    var previous: ?[]const u8 = null;
    for (lines.items) |line| {
        if (unique and previous != null and compareLines(opts, previous.?, line, false) == .eq) continue;
        out.write(line);
        out.write("\n");
        previous = line;
    }
    return 0;
}

// F[.C][nrfb][,F[.C][nrfb]]
fn parseKey(spec: []const u8) ?Key {
    var key: Key = .{ .start_field = 0 };
    var i: usize = 0;
    key.start_field = number(spec, &i) orelse return null;
    if (key.start_field == 0) return null;
    if (i < spec.len and spec[i] == '.') {
        i += 1;
        key.start_char = number(spec, &i) orelse return null;
    }
    flags(spec, &i, &key);
    if (i < spec.len and spec[i] == ',') {
        i += 1;
        key.end_field = number(spec, &i) orelse return null;
        if (i < spec.len and spec[i] == '.') {
            i += 1;
            key.end_char = number(spec, &i) orelse return null;
        }
        flags(spec, &i, &key);
    }
    if (i != spec.len) return null;
    return key;
}

fn number(s: []const u8, i: *usize) ?usize {
    const start = i.*;
    while (i.* < s.len and std.ascii.isDigit(s[i.*])) i.* += 1;
    if (i.* == start) return null;
    return std.fmt.parseInt(usize, s[start..i.*], 10) catch null;
}

fn flags(s: []const u8, i: *usize, key: *Key) void {
    while (i.* < s.len) : (i.* += 1) {
        switch (s[i.*]) {
            'n' => key.numeric = true,
            'r' => key.reverse = true,
            'f' => key.fold = true,
            'b' => {},
            else => return,
        }
    }
}

// f from 1.
fn fieldSpan(line: []const u8, f: usize, sep: ?u8) struct { start: usize, end: usize } {
    var start: usize = 0;
    var n: usize = 1;
    if (sep) |c| {
        while (n < f) : (n += 1) {
            const at = std.mem.indexOfScalarPos(u8, line, start, c) orelse return .{ .start = line.len, .end = line.len };
            start = at + 1;
        }
        const end = std.mem.indexOfScalarPos(u8, line, start, c) orelse line.len;
        return .{ .start = start, .end = end };
    }
    // Blank-separated: a field is its leading blanks and the text after:
    while (true) {
        var end = start;
        while (end < line.len and isBlank(line[end])) end += 1;
        while (end < line.len and !isBlank(line[end])) end += 1;
        if (n == f) return .{ .start = start, .end = end };
        if (end >= line.len) return .{ .start = line.len, .end = line.len };
        start = end;
        n += 1;
    }
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn keyText(line: []const u8, key: Key, sep: ?u8) []const u8 {
    const first = fieldSpan(line, key.start_field, sep);
    var start = first.start;
    // Characters count after the leading blanks:
    if (sep == null) {
        while (start < first.end and isBlank(line[start])) start += 1;
    }
    start = @min(start + key.start_char - 1, first.end);
    var end = line.len;
    if (key.end_field) |ef| {
        const last = fieldSpan(line, ef, sep);
        end = last.end;
        if (key.end_char) |ec| {
            var s = last.start;
            if (sep == null) {
                while (s < last.end and isBlank(line[s])) s += 1;
            }
            end = @min(s + ec, last.end);
        }
    }
    if (end < start) end = start;
    return line[start..end];
}

fn numberOf(s: []const u8) f64 {
    var i: usize = 0;
    while (i < s.len and isBlank(s[i])) i += 1;
    var j = i;
    if (j < s.len and (s[j] == '-' or s[j] == '+')) j += 1;
    while (j < s.len and (std.ascii.isDigit(s[j]) or s[j] == '.')) j += 1;
    return std.fmt.parseFloat(f64, s[i..j]) catch 0;
}

fn compareText(x: []const u8, y: []const u8, numeric: bool, fold: bool) std.math.Order {
    if (numeric) return std.math.order(numberOf(x), numberOf(y));
    if (fold) {
        const n = @min(x.len, y.len);
        for (x[0..n], y[0..n]) |a, b| {
            const o = std.math.order(std.ascii.toLower(a), std.ascii.toLower(b));
            if (o != .eq) return o;
        }
        return std.math.order(x.len, y.len);
    }
    return std.mem.order(u8, x, y);
}

fn compareLines(opts: Options, x: []const u8, y: []const u8, last_resort: bool) std.math.Order {
    if (opts.keys.len == 0) {
        var o = compareText(x, y, opts.numeric, opts.fold);
        if (o == .eq and last_resort and (opts.numeric or opts.fold)) o = std.mem.order(u8, x, y);
        return if (opts.reverse) o.invert() else o;
    }
    for (opts.keys) |key| {
        const has_flags = key.numeric or key.reverse or key.fold;
        const numeric = if (has_flags) key.numeric else opts.numeric;
        const fold = if (has_flags) key.fold else opts.fold;
        const reverse = if (has_flags) key.reverse else opts.reverse;
        const o = compareText(keyText(x, key, opts.separator), keyText(y, key, opts.separator), numeric, fold);
        if (o != .eq) return if (reverse) o.invert() else o;
    }
    if (!last_resort) return .eq;
    const o = std.mem.order(u8, x, y);
    return if (opts.reverse) o.invert() else o;
}

fn lessThan(opts: Options, x: []const u8, y: []const u8) bool {
    return compareLines(opts, x, y, true) == .lt;
}

fn usage() u8 {
    errout.print("usage: sort [-rnfu] [-t CHAR] [-k POS1[,POS2]] [FILE...]\n");
    return 2;
}

fn outOfMemory() u8 {
    errout.print("sort: not enough memory\n");
    return 2;
}
