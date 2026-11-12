// grep [-EFivncqlhHrowx] [-e PATTERN]... [PATTERN] [FILE...]
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const regex = @import("regex.zig");
const text = @import("text.zig");

const Allocator = std.mem.Allocator;

const Options = struct {
    extended: bool = false,
    fixed: bool = false,
    ignore_case: bool = false,
    invert: bool = false,
    number: bool = false,
    count: bool = false,
    quiet: bool = false,
    list: bool = false,
    names: ?bool = null, // -h / -H
    recursive: bool = false,
    only: bool = false,
    word: bool = false,
    line: bool = false,
};

const Grep = struct {
    a: Allocator,
    o: Options,
    fixed: []const []const u8 = &.{},
    re: ?regex.Regex = null,
    show_names: bool = false,
    found: bool = false,
    failed: bool = false,
    out: text.Output = .{},

    fn isWord(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    // At or after from.
    fn find(self: *Grep, line: []const u8, from: usize) ?regex.Match {
        var pos = from;
        while (pos <= line.len) {
            const m = self.findAny(line, pos) orelse return null;
            if (self.o.line and (m.start != 0 or m.end != line.len)) {
                if (m.start >= line.len) return null;
                pos = m.start + 1;
                continue;
            }
            if (self.o.word) {
                const before_ok = m.start == 0 or !isWord(line[m.start - 1]);
                const after_ok = m.end == line.len or !isWord(line[m.end]);
                if (!before_ok or !after_ok or m.end == m.start) {
                    if (m.start >= line.len) return null;
                    pos = m.start + 1;
                    continue;
                }
            }
            return m;
        }
        return null;
    }

    fn findAny(self: *Grep, line: []const u8, from: usize) ?regex.Match {
        if (self.re) |*re| return re.search(line, from);
        var best: ?regex.Match = null;
        for (self.fixed) |p| {
            const at = if (self.o.ignore_case) indexIgnoreCase(line, from, p) else std.mem.indexOfPos(u8, line, from, p);
            if (at) |s| {
                if (best == null or s < best.?.start or (s == best.?.start and s + p.len > best.?.end))
                    best = .{ .start = s, .end = s + p.len };
            }
        }
        return best;
    }

    fn file(self: *Grep, path: []const u8, reader: *text.Reader) void {
        var line: std.ArrayListUnmanaged(u8) = .{};
        defer line.deinit(self.a);
        var n: usize = 0;
        var count: usize = 0;
        while (reader.readLine(self.a, &line) catch false) {
            n += 1;
            const l = line.items;
            const m = self.find(l, 0);
            if ((m != null) == self.o.invert) continue;
            count += 1;
            self.found = true;
            if (self.o.quiet) return;
            if (self.o.list) {
                self.out.write(path);
                self.out.write("\n");
                return;
            }
            if (self.o.count) continue;
            if (self.o.only and !self.o.invert) {
                var pos: usize = 0;
                while (self.find(l, pos)) |x| {
                    if (x.end > x.start) {
                        self.prefix(path, n);
                        self.out.write(l[x.start..x.end]);
                        self.out.write("\n");
                    }
                    pos = if (x.end > x.start) x.end else x.start + 1;
                    if (pos > l.len) break;
                }
                continue;
            }
            self.prefix(path, n);
            self.out.write(l);
            self.out.write("\n");
        }
        if (self.o.count) {
            if (self.show_names) {
                self.out.write(path);
                self.out.write(":");
            }
            var buf: [24]u8 = undefined;
            self.out.write(std.fmt.bufPrint(&buf, "{d}\n", .{count}) catch unreachable);
        }
    }

    fn prefix(self: *Grep, path: []const u8, n: usize) void {
        if (self.show_names) {
            self.out.write(path);
            self.out.write(":");
        }
        if (self.o.number) {
            var buf: [24]u8 = undefined;
            self.out.write(std.fmt.bufPrint(&buf, "{d}:", .{n}) catch unreachable);
        }
    }

    fn walk(self: *Grep, p: []const u8) void {
        if (self.found and self.o.quiet) return;
        if (self.o.recursive) {
            if (zdos.stat(p)) |entry| {
                if (entry.is_dir) return self.folder(p);
            } else |_| {}
        }
        var reader = text.Reader.open(p) catch |err| {
            errout.printf("grep: {s}: {s}\n", .{ p, zdos.message(err) });
            self.failed = true;
            return;
        };
        defer reader.close();
        self.file(p, &reader);
    }

    fn folder(self: *Grep, p: []const u8) void {
        const dir = zdos.openDir(p) catch |err| {
            errout.printf("grep: {s}: {s}\n", .{ p, zdos.message(err) });
            self.failed = true;
            return;
        };
        defer dir.close();
        var entry: zdos.DirEntry = undefined;
        while (dir.next(&entry) catch false) {
            const name = entry.name();
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const sep: []const u8 = if (std.mem.endsWith(u8, p, "/")) "" else "/";
            const child = std.fmt.allocPrint(self.a, "{s}{s}{s}", .{ p, sep, name }) catch return;
            defer self.a.free(child);
            self.walk(child);
        }
    }
};

fn indexIgnoreCase(hay: []const u8, from: usize, needle: []const u8) ?usize {
    if (needle.len > hay.len) return null;
    var i = from;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return i;
    }
    return null;
}

pub fn run(args: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(zdos.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var o: Options = .{};
    var patterns: std.ArrayListUnmanaged([]const u8) = .{};
    var operands: std.ArrayListUnmanaged([]const u8) = .{};
    var i: usize = 0;
    var options = true;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (!options or arg.len < 2 or arg[0] != '-') {
            operands.append(a, arg) catch return outOfMemory();
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            options = false;
            continue;
        }
        var k: usize = 1;
        while (k < arg.len) : (k += 1) {
            switch (arg[k]) {
                'E' => o.extended = true,
                'F' => o.fixed = true,
                'G' => o.extended = false,
                'i' => o.ignore_case = true,
                'v' => o.invert = true,
                'n' => o.number = true,
                'c' => o.count = true,
                'q', 's' => o.quiet = o.quiet or arg[k] == 'q',
                'l' => o.list = true,
                'h' => o.names = false,
                'H' => o.names = true,
                'r', 'R' => o.recursive = true,
                'o' => o.only = true,
                'w' => o.word = true,
                'x' => o.line = true,
                'e' => {
                    const value = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                        i += 1;
                        break :blk if (i < args.len) args[i] else return usage();
                    };
                    patterns.append(a, value) catch return outOfMemory();
                    break;
                },
                else => {
                    errout.printf("grep: unknown option: -{c}\n", .{arg[k]});
                    return 2;
                },
            }
        }
    }
    if (patterns.items.len == 0) {
        if (operands.items.len == 0) return usage();
        patterns.append(a, operands.orderedRemove(0)) catch return outOfMemory();
    }
    var g: Grep = .{ .a = a, .o = o };
    defer g.out.deinit();
    if (o.fixed) {
        g.fixed = patterns.items;
    } else {
        // One expression: (p1)|(p2) ...:
        var joined: std.ArrayListUnmanaged(u8) = .{};
        for (patterns.items, 0..) |p, k| {
            const ere = if (o.extended) p else regex.fromBasic(a, p) catch return outOfMemory();
            if (k > 0) joined.append(a, '|') catch return outOfMemory();
            if (patterns.items.len > 1) joined.append(a, '(') catch return outOfMemory();
            joined.appendSlice(a, ere) catch return outOfMemory();
            if (patterns.items.len > 1) joined.append(a, ')') catch return outOfMemory();
        }
        g.re = regex.compile(a, joined.items, .{ .icase = o.ignore_case }) catch |err| {
            if (err == error.OutOfMemory) return outOfMemory();
            errout.printf("grep: bad regular expression: {s}\n", .{joined.items});
            return 2;
        };
    }
    if (operands.items.len == 0) operands.append(a, if (o.recursive) "." else "-") catch return outOfMemory();
    g.show_names = o.names orelse (operands.items.len > 1 or o.recursive);
    for (operands.items) |p| {
        if (std.mem.eql(u8, p, "-")) {
            var reader = text.Reader.stdin();
            g.file("(standard input)", &reader);
        } else g.walk(p);
        if (g.found and o.quiet) break;
    }
    if (g.found and o.quiet) return 0;
    if (g.failed) return 2;
    return if (g.found) 0 else 1;
}

fn usage() u8 {
    errout.print("usage: grep [-EFivncqlhHrowx] [-e PATTERN] PATTERN [FILE...]\n");
    return 2;
}

fn outOfMemory() u8 {
    errout.print("grep: not enough memory\n");
    return 2;
}
