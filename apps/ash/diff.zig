// diff: files line by line, and folders (-r), as BSD diff.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const sys = @import("../zdos/system.zig");
const errout = @import("errout.zig");
const text = @import("text.zig");
const regex = @import("regex.zig");

const Allocator = std.mem.Allocator;

pub const Lines = struct {
    lines: []const []const u8 = &.{}, // without "\n" (a "\r" before it stays)
    incomplete: bool = false, // the last line has no "\n"
};

pub fn splitLines(a: Allocator, data: []const u8) Allocator.Error!Lines {
    var list = try std.ArrayListUnmanaged([]const u8).initCapacity(a, std.mem.count(u8, data, "\n") + 1);
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, data, start, '\n')) |nl| {
        list.appendAssumeCapacity(data[start..nl]);
        start = nl + 1;
    }
    if (start < data.len) list.appendAssumeCapacity(data[start..]);
    return .{ .lines = list.items, .incomplete = start < data.len };
}

pub const ReadError = zdos.Error || Allocator.Error;

pub fn readFile(a: Allocator, path: []const u8) ReadError![]u8 {
    var data: std.ArrayListUnmanaged(u8) = .{};
    if (std.mem.eql(u8, path, "-")) {
        var reader = text.Reader.stdin();
        while (true) {
            const chunk = try reader.readChunk();
            if (chunk.len == 0) break;
            try data.appendSlice(a, chunk);
        }
        return data.items;
    }
    const f = try zdos.open(path, .read);
    defer f.close();
    if (f.size()) |size| try data.ensureTotalCapacity(a, @intCast(size + 1)) else |_| {}
    while (true) {
        try data.ensureUnusedCapacity(a, 4096);
        const n = try f.read(data.unusedCapacitySlice());
        if (n == 0) break;
        data.items.len += n;
    }
    return data.items;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == 0x0b or c == 0x0c;
}

// del lines from a0 in the first file became ins lines from b0.
const Change = struct { a0: usize, del: usize, b0: usize, ins: usize, ignore: bool = false };

// E. Myers, "An O(ND) difference algorithm and its variations"
// (1986), linear space. Past `limit` edits a search splits at its
// furthest point, bounding the time on very different files.
const Myers = struct {
    xv: []const u32,
    yv: []const u32,
    xc: []bool, // out: the changed lines
    yc: []bool,
    fwd: []isize, // furthest x on each diagonal k = x - y (index k + mid)
    back: []isize, // smallest x on each diagonal, searching backwards
    mid: isize,
    limit: isize,
    steps: usize = 0,

    const Split = struct { x: isize, y: isize, x2: isize, y2: isize };

    fn same(m: *const Myers, x: isize, y: isize) bool {
        return m.xv[@intCast(x)] == m.yv[@intCast(y)];
    }

    fn f(m: *Myers, k: isize) *isize {
        return &m.fwd[@intCast(k + m.mid)];
    }

    fn b(m: *Myers, k: isize) *isize {
        return &m.back[@intCast(k + m.mid)];
    }

    // Diagonals are relative to (x0,y0).
    fn middle(m: *Myers, x0: isize, y0: isize, x1: isize, y1: isize) error{Interrupted}!Split {
        const n = x1 - x0;
        const delta = n - (y1 - y0);
        const odd = @mod(delta, 2) == 1;
        m.f(1).* = 0;
        m.b(delta - 1).* = n;
        var d: isize = 0;
        while (true) : (d += 1) {
            if (d & 0xff == 0xff and sys.ctrlCPressed(true)) return error.Interrupted;
            var k = -d;
            while (k <= d) : (k += 2) {
                // Down from diagonal k+1 or right
                // from k-1, then along equal lines:
                var x = if (k == -d or (k != d and m.f(k - 1).* < m.f(k + 1).*)) m.f(k + 1).* else m.f(k - 1).* + 1;
                var y = x - k;
                const sx = x;
                const sy = y;
                while (x < n and y < y1 - y0 and m.same(x0 + x, y0 + y)) {
                    x += 1;
                    y += 1;
                }
                m.f(k).* = x;
                if (odd and k >= delta - (d - 1) and k <= delta + (d - 1) and x >= m.b(k).*)
                    return .{ .x = x0 + sx, .y = y0 + sy, .x2 = x0 + x, .y2 = y0 + y };
            }
            k = -d;
            while (k <= d) : (k += 2) {
                // The same backwards, on diagonal delta + k:
                const c = delta + k;
                var x = if (k == d or (k != -d and m.b(c + 1).* > m.b(c - 1).*)) m.b(c - 1).* else m.b(c + 1).* - 1;
                var y = x - c;
                const ex = x;
                const ey = y;
                while (x > 0 and y > 0 and m.same(x0 + x - 1, y0 + y - 1)) {
                    x -= 1;
                    y -= 1;
                }
                m.b(c).* = x;
                if (!odd and c >= -d and c <= d and x <= m.f(c).*)
                    return .{ .x = x0 + x, .y = y0 + y, .x2 = x0 + ex, .y2 = y0 + ey };
            }
            if (d < m.limit) continue;
            // Too many edits: the forward point furthest along:
            var best: isize = -1;
            var bx: isize = 0;
            k = -d;
            while (k <= d) : (k += 2) {
                const x = @min(m.f(k).*, n);
                const y = x - k;
                if (y < 0 or y > y1 - y0) continue;
                if (x + y > best) {
                    best = x + y;
                    bx = x;
                }
            }
            return .{ .x = x0 + bx, .y = y0 + best - bx, .x2 = x0 + bx, .y2 = y0 + best - bx };
        }
    }

    fn compare(m: *Myers, x0_in: isize, y0_in: isize, x1_in: isize, y1_in: isize) error{Interrupted}!void {
        var x0 = x0_in;
        var y0 = y0_in;
        var x1 = x1_in;
        var y1 = y1_in;
        while (true) {
            while (x0 < x1 and y0 < y1 and m.same(x0, y0)) {
                x0 += 1;
                y0 += 1;
            }
            while (x0 < x1 and y0 < y1 and m.same(x1 - 1, y1 - 1)) {
                x1 -= 1;
                y1 -= 1;
            }
            if (x0 == x1 or y0 == y1) {
                @memset(m.xc[@intCast(x0)..@intCast(x1)], true);
                @memset(m.yc[@intCast(y0)..@intCast(y1)], true);
                return;
            }
            m.steps += 1;
            if (m.steps & 0xff == 0 and sys.ctrlCPressed(true)) return error.Interrupted;
            const s = try m.middle(x0, y0, x1, y1);
            try m.compare(x0, y0, s.x, s.y);
            x0 = s.x2;
            y0 = s.y2;
        }
    }
};

const Format = enum { normal, unified, context, ed, forward_ed, rcs };

const Diff = struct {
    a: Allocator,
    interrupted: *bool,
    format: Format = .normal,
    context: usize = 3,
    brief: bool = false,
    report_same: bool = false,
    recursive: bool = false,
    new_file: bool = false, // -N
    new_file_right: bool = false, // -P: only files missing on the left
    text_mode: bool = false,
    minimal: bool = false,
    ignore_case: bool = false,
    space_change: bool = false,
    all_space: bool = false,
    blank_lines: bool = false,
    strip_cr: bool = false,
    expand_tabs: bool = false,
    initial_tab: bool = false,
    functions: bool = false, // -p
    ignore_re: ?regex.Regex = null, // -I
    excludes: std.ArrayListUnmanaged([]const u8) = .{},
    start_at: ?[]const u8 = null, // -S
    labels: [2]?[]const u8 = .{ null, null },
    switches: []const u8 = "", // the options as given, for "diff -ru a/x b/x"
    status: u8 = 0,
    out: text.Output = .{},
    // -p: the last function line found and where the search stopped:
    func: []const u8 = "",
    func_from: usize = 0,

    fn fail(self: *Diff, path: []const u8, err: ReadError) void {
        self.out.flush();
        errout.printf("diff: {s}: {s}\n", .{ path, zdos.message(err) });
        self.status = 2;
    }

    fn differ(self: *Diff) void {
        if (self.status == 0) self.status = 1;
    }

    fn flag(self: *Diff, c: u8) bool {
        switch (c) {
            'u' => self.format = .unified,
            'c' => self.format = .context,
            'e' => self.format = .ed,
            'f' => self.format = .forward_ed,
            'n' => self.format = .rcs,
            'q' => self.brief = true,
            's' => self.report_same = true,
            'r' => self.recursive = true,
            'N' => self.new_file = true,
            'P' => self.new_file_right = true,
            'a' => self.text_mode = true,
            'd' => self.minimal = true,
            'i' => self.ignore_case = true,
            'b' => self.space_change = true,
            'w' => self.all_space = true,
            'B' => self.blank_lines = true,
            't' => self.expand_tabs = true,
            'T' => self.initial_tab = true,
            'p' => self.functions = true,
            else => return false,
        }
        if (c == 'u' or c == 'c') self.context = 3;
        return true;
    }

    // -U N, -C N
    fn optionValue(self: *Diff, c: u8, v: []const u8) bool {
        self.context = std.fmt.parseInt(usize, v, 10) catch return false;
        self.format = if (c == 'U') .unified else .context;
        return true;
    }

    fn ignoring(self: *const Diff) bool {
        return self.ignore_case or self.space_change or self.all_space or self.blank_lines or self.strip_cr or self.ignore_re != null;
    }

    fn key(self: *const Diff, buf: *std.ArrayListUnmanaged(u8), a: Allocator, line: []const u8) Allocator.Error![]const u8 {
        if (!self.ignore_case and !self.space_change and !self.all_space) return line;
        buf.clearRetainingCapacity();
        var space = false;
        for (line) |c| {
            if (isSpace(c) and (self.all_space or self.space_change)) {
                space = true;
                continue;
            }
            if (space and !self.all_space) try buf.append(a, ' ');
            space = false;
            try buf.append(a, if (self.ignore_case) std.ascii.toLower(c) else c);
        }
        return buf.items;
    }

    // -B and -I: lines whose changes don't count.
    fn ignorable(self: *Diff, line: []const u8) bool {
        if (self.ignore_re) |*re| {
            if (re.search(line, 0) != null) return true;
            if (!self.blank_lines) return false;
        }
        if (self.space_change or self.all_space) {
            for (line) |c| if (!isSpace(c)) return false;
            return true;
        }
        return line.len == 0;
    }

    fn changes(self: *Diff, a: Allocator, x: Lines, y: Lines) (Allocator.Error || error{Interrupted})![]Change {
        const nx = x.lines.len;
        const ny = y.lines.len;
        // Equal lines get the same class:
        const xid = try a.alloc(u32, nx);
        const yid = try a.alloc(u32, ny);
        var classes: std.StringHashMapUnmanaged(u32) = .{};
        var buf: std.ArrayListUnmanaged(u8) = .{};
        var next: u32 = 0;
        for ([2]Lines{ x, y }, [2][]u32{ xid, yid }) |lines, ids| {
            for (lines.lines, ids) |line, *id| {
                const k = try self.key(&buf, a, line);
                const entry = try classes.getOrPut(a, k);
                if (!entry.found_existing) {
                    entry.key_ptr.* = try a.dupe(u8, k);
                    entry.value_ptr.* = next;
                    next += 1;
                }
                id.* = entry.value_ptr.*;
            }
        }
        // A last line without "\n" differs from one with it (unless -b/-w):
        if (!self.space_change and !self.all_space) {
            const same = x.incomplete and y.incomplete and xid[nx - 1] == yid[ny - 1];
            if (x.incomplete) xid[nx - 1] = next;
            if (y.incomplete) yid[ny - 1] = if (same) next else next + 1;
            next += 2;
        }
        // Lines without an equal in the other file are changes for sure; the
        // search runs on the others:
        const in_x = try a.alloc(bool, next);
        const in_y = try a.alloc(bool, next);
        @memset(in_x, false);
        @memset(in_y, false);
        for (xid) |id| in_x[id] = true;
        for (yid) |id| in_y[id] = true;
        const xc = try a.alloc(bool, nx);
        const yc = try a.alloc(bool, ny);
        var xv: std.ArrayListUnmanaged(u32) = .{};
        var yv: std.ArrayListUnmanaged(u32) = .{};
        var xmap: std.ArrayListUnmanaged(u32) = .{};
        var ymap: std.ArrayListUnmanaged(u32) = .{};
        for ([2][]const u32{ xid, yid }, [2][]bool{ xc, yc }, [2][]const bool{ in_y, in_x }, [2]*std.ArrayListUnmanaged(u32){ &xv, &yv }, [2]*std.ArrayListUnmanaged(u32){ &xmap, &ymap }) |ids, changed, other, v, map| {
            for (ids, changed, 0..) |id, *c, i| {
                c.* = !other[id];
                if (c.*) continue;
                try v.append(a, id);
                try map.append(a, @intCast(i));
            }
        }
        const n = xv.items.len;
        const m = yv.items.len;
        const limit: usize = if (self.minimal) (n + m) / 2 + 1 else 2048;
        const max_d = @min(limit, (n + m) / 2) + 2;
        var myers: Myers = .{
            .xv = xv.items,
            .yv = yv.items,
            .xc = try a.alloc(bool, n),
            .yc = try a.alloc(bool, m),
            .fwd = try a.alloc(isize, n + m + 2 * max_d + 6),
            .back = try a.alloc(isize, n + m + 2 * max_d + 6),
            .mid = @intCast(m + max_d + 2),
            .limit = @intCast(limit),
        };
        @memset(myers.xc, false);
        @memset(myers.yc, false);
        myers.compare(0, 0, @intCast(n), @intCast(m)) catch |err| {
            self.interrupted.* = true;
            return err;
        };
        for (myers.xc, xmap.items) |changed, i| xc[i] = changed;
        for (myers.yc, ymap.items) |changed, i| yc[i] = changed;
        merge(xc, xid);
        merge(yc, yid);
        // The script: runs of changed lines:
        var list: std.ArrayListUnmanaged(Change) = .{};
        var i: usize = 0;
        var j: usize = 0;
        while (i < nx or j < ny) {
            if ((i < nx and xc[i]) or (j < ny and yc[j])) {
                var ch: Change = .{ .a0 = i, .del = 0, .b0 = j, .ins = 0 };
                while (i < nx and xc[i]) i += 1;
                while (j < ny and yc[j]) j += 1;
                ch.del = i - ch.a0;
                ch.ins = j - ch.b0;
                if (self.blank_lines or self.ignore_re != null) {
                    ch.ignore = true;
                    for (x.lines[ch.a0..i]) |l| ch.ignore = ch.ignore and self.ignorable(l);
                    for (y.lines[ch.b0..j]) |l| ch.ignore = ch.ignore and self.ignorable(l);
                }
                try list.append(a, ch);
            } else {
                i += 1;
                j += 1;
            }
        }
        return list.items;
    }

    // OUTPUT

    fn put(self: *Diff, s: []const u8) void {
        self.out.write(s);
    }

    fn putf(self: *Diff, comptime fmt: []const u8, args: anytype) void {
        var buf: [64]u8 = undefined;
        self.put(std.fmt.bufPrint(&buf, fmt, args) catch unreachable);
    }

    // mark 0: none, as ed scripts have them.
    fn putLine(self: *Diff, mark: u8, lines: Lines, i: usize) void {
        if (mark != 0) {
            self.put(&.{mark});
            if (self.initial_tab) {
                self.put("\t");
            } else if (self.format != .unified) self.put(" ");
        }
        const l = lines.lines[i];
        if (self.expand_tabs and std.mem.indexOfScalar(u8, l, '\t') != null) {
            var col: usize = 0;
            for (l) |c| {
                if (c == '\t') {
                    self.put("        "[0 .. 8 - col % 8]);
                    col += 8 - col % 8;
                } else {
                    self.put(&.{c});
                    col += 1;
                }
            }
        } else self.put(l);
        self.put("\n");
        if (lines.incomplete and i + 1 == lines.lines.len) {
            if (mark == 0) {
                self.out.flush();
                errout.print("diff: No newline at end of file\n");
            } else self.put("\\ No newline at end of file\n");
        }
    }

    // With none the line before.
    fn range(self: *Diff, start: usize, count: usize, sep: []const u8) void {
        if (count == 0) {
            self.putf("{d}", .{start});
        } else if (count == 1) {
            self.putf("{d}", .{start + 1});
        } else {
            self.putf("{d}", .{start + 1});
            self.put(sep);
            self.putf("{d}", .{start + count});
        }
    }

    fn unifiedRange(self: *Diff, start: usize, count: usize) void {
        if (count == 0) {
            self.putf("{d},0", .{start});
        } else if (count == 1) {
            self.putf("{d}", .{start + 1});
        } else self.putf("{d},{d}", .{ start + 1, count });
    }

    // "--- NAME\tTIME", the time as ctime() writes it, as BSD diff.
    fn header(self: *Diff, mark: []const u8, which: usize, path: []const u8, missing: bool) void {
        self.put(mark);
        if (self.labels[which]) |label| {
            self.put(label);
            self.put("\n");
            return;
        }
        self.put(path);
        const t = if (missing)
            zdos.Time{ .year = 1970, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 }
        else if (std.mem.eql(u8, path, "-"))
            zdos.getTime()
        else if (zdos.statEx(path)) |st| st.modified else |_| zdos.Time{ .year = 0, .month = 0, .day = 0, .hour = 0, .minute = 0, .second = 0 };
        if (t.year != 0 and t.month >= 1 and t.month <= 12) {
            const days = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
            const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
            const day = days[@intCast(@mod(daysSince1970(t.year, t.month, t.day), 7))];
            self.putf("\t{s} {s} {d:>2} {d:0>2}:{d:0>2}:{d:0>2} {d}", .{ day, months[t.month - 1], t.day, t.hour, t.minute, t.second, t.year });
        }
        self.put("\n");
    }

    fn normal(self: *Diff, x: Lines, y: Lines, list: []const Change) void {
        for (list) |ch| {
            if (ch.ignore) continue;
            self.range(ch.a0, ch.del, ",");
            self.put(if (ch.del == 0) "a" else if (ch.ins == 0) "d" else "c");
            self.range(ch.b0, ch.ins, ",");
            self.put("\n");
            for (ch.a0..ch.a0 + ch.del) |i| self.putLine('<', x, i);
            if (ch.del > 0 and ch.ins > 0) self.put("---\n");
            for (ch.b0..ch.b0 + ch.ins) |j| self.putLine('>', y, j);
        }
    }

    // -e: last change first; a line "." is written ".." and put
    // right by an s command.
    fn edScript(self: *Diff, y: Lines, list: []const Change) void {
        var k = list.len;
        while (k > 0) {
            k -= 1;
            const ch = list[k];
            if (ch.ignore) continue;
            self.range(ch.a0, ch.del, ",");
            self.put(if (ch.del == 0) "a\n" else if (ch.ins == 0) "d\n" else "c\n");
            if (ch.ins == 0) continue;
            for (ch.b0..ch.b0 + ch.ins) |j| {
                const at = ch.a0 + (j - ch.b0) + 1; // the line it becomes
                if (std.mem.eql(u8, y.lines[j], ".")) {
                    self.putf("..\n.\n{d}s/^\\.\\././\n", .{at});
                    if (j + 1 < ch.b0 + ch.ins) self.putf("{d}a\n", .{at});
                } else self.putLine(0, y, j);
            }
            if (!std.mem.eql(u8, y.lines[ch.b0 + ch.ins - 1], ".")) self.put(".\n");
        }
    }

    // -f: the same forwards ("c3 5"), -n: RCS ("d3 2", "a5 1").
    fn forwardScript(self: *Diff, y: Lines, list: []const Change) void {
        for (list) |ch| {
            if (ch.ignore) continue;
            if (self.format == .rcs) {
                if (ch.del > 0) self.putf("d{d} {d}\n", .{ ch.a0 + 1, ch.del });
                if (ch.ins > 0) self.putf("a{d} {d}\n", .{ ch.a0 + ch.del, ch.ins });
            } else {
                self.put(if (ch.del == 0) "a" else if (ch.ins == 0) "d" else "c");
                self.range(ch.a0, ch.del, " ");
                self.put("\n");
            }
            for (ch.b0..ch.b0 + ch.ins) |j| self.putLine(0, y, j);
            if (self.format == .forward_ed and ch.ins > 0) self.put(".\n");
        }
    }

    // -p: the closest line before the hunk that starts like a C function,
    // searched back to where the last search began.
    fn function(self: *Diff, x: Lines, before: usize) []const u8 {
        var pos = before;
        const last = self.func_from;
        self.func_from = before;
        while (pos > last) : (pos -= 1) {
            const l = x.lines[pos - 1];
            if (l.len == 0 or !(std.ascii.isAlphabetic(l[0]) or l[0] == '_' or l[0] == '$')) continue;
            if (std.mem.startsWith(u8, l, "private:") or std.mem.startsWith(u8, l, "protected:") or std.mem.startsWith(u8, l, "public:")) continue;
            self.func = l[0..@min(l.len, 54)];
            break;
        }
        return self.func;
    }

    // Groups closer than twice the context; groups of ignored changes only
    // are left out.
    fn hunks(self: *Diff, x: Lines, y: Lines, list: []const Change) void {
        var first: usize = 0;
        while (first < list.len) {
            var last = first;
            while (last + 1 < list.len and list[last + 1].a0 - (list[last].a0 + list[last].del) <= 2 * self.context) last += 1;
            const group = list[first .. last + 1];
            first = last + 1;
            var shown = false;
            for (group) |ch| shown = shown or !ch.ignore;
            if (!shown) continue;
            const a0 = group[0].a0 -| self.context;
            const b0 = group[0].b0 - (group[0].a0 - a0);
            const end = group[group.len - 1].a0 + group[group.len - 1].del;
            const a1 = @min(end + self.context, x.lines.len);
            const b1 = group[group.len - 1].b0 + group[group.len - 1].ins + (a1 - end);
            if (self.format == .unified) {
                self.unifiedHunk(x, y, group, a0, a1, b0, b1);
            } else self.contextHunk(x, y, group, a0, a1, b0, b1);
        }
    }

    fn functionName(self: *Diff, x: Lines, a0: usize) void {
        if (!self.functions) return;
        const f = self.function(x, a0);
        if (f.len == 0) return;
        self.put(" ");
        self.put(f);
    }

    fn unifiedHunk(self: *Diff, x: Lines, y: Lines, group: []const Change, a0: usize, a1: usize, b0: usize, b1: usize) void {
        self.put("@@ -");
        self.unifiedRange(a0, a1 - a0);
        self.put(" +");
        self.unifiedRange(b0, b1 - b0);
        self.put(" @@");
        self.functionName(x, a0);
        self.put("\n");
        var i = a0;
        for (group) |ch| {
            while (i < ch.a0) : (i += 1) self.putLine(' ', x, i);
            for (ch.a0..ch.a0 + ch.del) |k| self.putLine('-', x, k);
            for (ch.b0..ch.b0 + ch.ins) |k| self.putLine('+', y, k);
            i = ch.a0 + ch.del;
        }
        while (i < a1) : (i += 1) self.putLine(' ', x, i);
    }

    fn contextHunk(self: *Diff, x: Lines, y: Lines, group: []const Change, a0: usize, a1: usize, b0: usize, b1: usize) void {
        var dels = false;
        var inss = false;
        for (group) |ch| {
            dels = dels or ch.del > 0;
            inss = inss or ch.ins > 0;
        }
        self.put("***************");
        self.functionName(x, a0);
        self.put("\n*** ");
        self.range(a0, a1 - a0, ",");
        self.put(" ****\n");
        if (dels) self.contextSide(x, group, a0, a1, true);
        self.put("--- ");
        self.range(b0, b1 - b0, ",");
        self.put(" ----\n");
        if (inss) self.contextSide(y, group, b0, b1, false);
    }

    fn contextSide(self: *Diff, lines: Lines, group: []const Change, from: usize, to: usize, old: bool) void {
        var k: usize = 0;
        for (from..to) |i| {
            while (k < group.len and (if (old) group[k].a0 + group[k].del else group[k].b0 + group[k].ins) <= i) k += 1;
            var mark: u8 = ' ';
            if (k < group.len) {
                const ch = group[k];
                const start = if (old) ch.a0 else ch.b0;
                if (i >= start) mark = if ((if (old) ch.ins else ch.del) == 0) (if (old) '-' else '+') else '!';
            }
            self.putLine(mark, lines, i);
        }
    }

    // FILES AND FOLDERS

    fn files(self: *Diff, p0: []const u8, p1: []const u8, missing: [2]bool, in_dir: bool) void {
        var arena = std.heap.ArenaAllocator.init(zdos.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const data0 = if (missing[0]) "" else readFile(a, p0) catch |err| return self.fail(p0, err);
        const data1 = if (missing[1]) "" else readFile(a, p1) catch |err| return self.fail(p1, err);
        if (std.mem.eql(u8, data0, data1)) {
            if (self.report_same) self.putf2("Files {s} and {s} are identical\n", p0, p1);
            return;
        }
        const binary = !self.text_mode and (std.mem.indexOfScalar(u8, data0, 0) != null or std.mem.indexOfScalar(u8, data1, 0) != null);
        if (binary or (self.brief and !self.ignoring())) {
            if (in_dir and !binary) {
                self.put("diff");
                self.put(self.switches);
                self.putf2(" {s} {s}\n", p0, p1);
            }
            if (binary and !self.brief) self.put("Binary f") else self.put("F");
            self.putf2("iles {s} and {s} differ\n", p0, p1);
            self.differ();
            return;
        }
        const x = splitLines(a, data0) catch |err| return self.fail(p0, err);
        const y = splitLines(a, data1) catch |err| return self.fail(p1, err);
        if (self.strip_cr) for ([2]Lines{ x, y }) |lines| {
            for (@constCast(lines.lines)) |*l| {
                if (l.len > 0 and l.*[l.len - 1] == '\r') l.* = l.*[0 .. l.len - 1];
            }
        };
        const list = self.changes(a, x, y) catch |err| {
            if (err == error.OutOfMemory) self.fail(p0, error.OutOfMemory);
            return;
        };
        var any = false;
        for (list) |ch| any = any or !ch.ignore;
        if (!any) {
            if (self.report_same) self.putf2("Files {s} and {s} are identical\n", p0, p1);
            return;
        }
        self.differ();
        if (in_dir) {
            self.put("diff");
            self.put(self.switches);
            self.putf2(" {s} {s}\n", p0, p1);
        }
        if (self.brief) return self.putf2("Files {s} and {s} differ\n", p0, p1);
        self.func = "";
        self.func_from = 0;
        switch (self.format) {
            .normal => self.normal(x, y, list),
            .ed => self.edScript(y, list),
            .forward_ed, .rcs => self.forwardScript(y, list),
            .unified => {
                self.header("--- ", 0, p0, missing[0]);
                self.header("+++ ", 1, p1, missing[1]);
                self.hunks(x, y, list);
            },
            .context => {
                self.header("*** ", 0, p0, missing[0]);
                self.header("--- ", 1, p1, missing[1]);
                self.hunks(x, y, list);
            },
        }
    }

    fn putf2(self: *Diff, comptime fmt: []const u8, s0: []const u8, s1: []const u8) void {
        const s = std.fmt.allocPrint(zdos.allocator, fmt, .{ s0, s1 }) catch return;
        defer zdos.allocator.free(s);
        self.put(s);
    }

    // Files, folders, or missing ones (with -N).
    fn pair(self: *Diff, p0: []const u8, p1: []const u8, missing_in: [2]bool, in_dir: bool) void {
        if (self.interrupted.*) return;
        var missing = missing_in;
        var is_dir = [2]bool{ false, false };
        for ([2][]const u8{ p0, p1 }, 0..) |p, k| {
            if (missing[k] or std.mem.eql(u8, p, "-")) continue;
            if (zdos.stat(p)) |e| {
                is_dir[k] = e.is_dir;
            } else |err| {
                if (!(self.new_file or (k == 0 and self.new_file_right)) or in_dir) return self.fail(p, err);
                missing[k] = true;
            }
        }
        if (missing[0] and missing[1]) {
            self.fail(p0, error.NotFound);
            return;
        }
        if (missing[0]) is_dir[0] = is_dir[1];
        if (missing[1]) is_dir[1] = is_dir[0];
        if (is_dir[0] and is_dir[1]) {
            if (in_dir and !self.recursive) return self.putf2("Common subdirectories: {s} and {s}\n", p0, p1);
            return self.folders(p0, p1, missing, !in_dir);
        }
        if (is_dir[0] != is_dir[1]) {
            if (in_dir) {
                const kinds = [2][]const u8{ "regular file", "directory" };
                const s = std.fmt.allocPrint(self.a, "File {s} is a {s} while file {s} is a {s}\n", .{ p0, kinds[@intFromBool(is_dir[0])], p1, kinds[@intFromBool(is_dir[1])] }) catch return;
                self.put(s);
                self.differ();
                return;
            }
            // diff FILE FOLDER: FOLDER/FILE:
            const file = if (is_dir[0]) p1 else p0;
            const base = file[if (std.mem.lastIndexOfAny(u8, file, "/\\")) |s| s + 1 else 0..];
            const inside = join(self.a, if (is_dir[0]) p0 else p1, base) catch return;
            return if (is_dir[0]) self.pair(inside, p1, missing, false) else self.pair(p0, inside, missing, false);
        }
        self.files(p0, p1, missing, in_dir);
    }

    fn folders(self: *Diff, p0: []const u8, p1: []const u8, missing: [2]bool, top: bool) void {
        var names: [2][]const []const u8 = .{ &.{}, &.{} };
        for ([2][]const u8{ p0, p1 }, 0..) |p, k| {
            if (missing[k]) continue;
            names[k] = self.listDir(p) catch |err| return self.fail(p, err);
        }
        var i: usize = 0;
        var j: usize = 0;
        // -S: the top folders from that name on:
        if (top) if (self.start_at) |s| {
            while (i < names[0].len and std.mem.order(u8, names[0][i], s) == .lt) i += 1;
            while (j < names[1].len and std.mem.order(u8, names[1][j], s) == .lt) j += 1;
        };
        while ((i < names[0].len or j < names[1].len) and !self.interrupted.*) {
            const order: std.math.Order = if (i == names[0].len)
                .gt
            else if (j == names[1].len)
                .lt
            else
                std.mem.order(u8, names[0][i], names[1][j]);
            const name = if (order == .gt) names[1][j] else names[0][i];
            const c0 = join(self.a, p0, name) catch return;
            const c1 = join(self.a, p1, name) catch return;
            if (order != .eq and !self.new_file and !(order == .gt and self.new_file_right)) {
                self.put("Only in ");
                self.put(if (order == .lt) p0 else p1);
                self.put(": ");
                self.put(name);
                self.put("\n");
                self.differ();
            } else self.pair(c0, c1, .{ order == .gt, order == .lt }, true);
            if (order != .gt) i += 1;
            if (order != .lt) j += 1;
        }
    }

    fn listDir(self: *Diff, path: []const u8) ReadError![]const []const u8 {
        const dir = try zdos.openDir(path);
        defer dir.close();
        var names: std.ArrayListUnmanaged([]const u8) = .{};
        var entry: zdos.DirEntry = undefined;
        next: while (try dir.next(&entry)) {
            const name = entry.name();
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            for (self.excludes.items) |pat| if (wildcard(pat, name)) continue :next;
            try names.append(self.a, try self.a.dupe(u8, name));
        }
        std.sort.heap([]const u8, names.items, {}, struct {
            fn less(_: void, l: []const u8, r: []const u8) bool {
                return std.mem.order(u8, l, r) == .lt;
            }
        }.less);
        return names.items;
    }
};

// A run of changed lines can slide over equal lines without changing
// the script's length; it does where that joins it to a neighbour (two
// insertions of "x" in "x x" show as one).
fn merge(c: []bool, ids: []const u32) void {
    var i: usize = 0;
    while (i < c.len) {
        if (!c[i]) {
            i += 1;
            continue;
        }
        var s = i;
        while (i < c.len and c[i]) i += 1;
        var e = i;
        // Up to the run before?
        var t = s;
        var u = e;
        while (t > 0 and !c[t - 1] and ids[t - 1] == ids[u - 1]) {
            t -= 1;
            u -= 1;
        }
        if (t < s and t > 0 and c[t - 1]) {
            @memset(c[s..e], false);
            @memset(c[t..u], true);
            s = t;
            e = u;
        }
        // Down to the run after?
        t = s;
        u = e;
        while (u < c.len and !c[u] and ids[u] == ids[t]) {
            t += 1;
            u += 1;
        }
        if (u > e and u < c.len and c[u]) {
            @memset(c[s..e], false);
            @memset(c[t..u], true);
        }
        i = @max(i, u);
    }
}

// For the day of the week.
fn daysSince1970(year: u16, month: u8, day: u8) i64 {
    const y: i64 = @as(i64, year) - @intFromBool(month <= 2);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, month) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

// -x: * ? and [...]
fn wildcard(pat: []const u8, name: []const u8) bool {
    if (pat.len == 0) return name.len == 0;
    switch (pat[0]) {
        '*' => {
            var k: usize = 0;
            while (k <= name.len) : (k += 1) if (wildcard(pat[1..], name[k..])) return true;
            return false;
        },
        '?' => return name.len > 0 and wildcard(pat[1..], name[1..]),
        '[' => {
            const close = std.mem.indexOfScalarPos(u8, pat, 1, ']') orelse return name.len > 0 and name[0] == '[' and wildcard(pat[1..], name[1..]);
            if (name.len == 0) return false;
            var set = pat[1..close];
            const negate = set.len > 0 and (set[0] == '!' or set[0] == '^');
            if (negate) set = set[1..];
            var hit = false;
            var k: usize = 0;
            while (k < set.len) : (k += 1) {
                if (k + 2 < set.len and set[k + 1] == '-') {
                    hit = hit or (name[0] >= set[k] and name[0] <= set[k + 2]);
                    k += 2;
                } else hit = hit or name[0] == set[k];
            }
            return hit != negate and wildcard(pat[close + 1 ..], name[1..]);
        },
        else => return name.len > 0 and name[0] == pat[0] and wildcard(pat[1..], name[1..]),
    }
}

fn join(a: Allocator, dir: []const u8, name: []const u8) Allocator.Error![]const u8 {
    const sep: []const u8 = if (dir.len == 0 or std.mem.endsWith(u8, dir, "/") or std.mem.endsWith(u8, dir, "\\") or std.mem.endsWith(u8, dir, ":")) "" else "/";
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ dir, sep, name });
}

pub fn run(interrupted: *bool, args: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(zdos.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diff = .{ .a = a, .interrupted = interrupted };
    defer d.out.deinit();
    var operands: std.ArrayListUnmanaged([]const u8) = .{};
    var switches: std.ArrayListUnmanaged(u8) = .{};
    var ignore: std.ArrayListUnmanaged(u8) = .{}; // the -I patterns as a|b
    var nlabels: usize = 0;
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
        switches.append(a, ' ') catch return outOfMemory();
        switches.appendSlice(a, arg) catch return outOfMemory();
        // An option's value: after = or the letter, else the next argument:
        var value: ?[]const u8 = null;
        var c: u8 = 0;
        if (std.mem.startsWith(u8, arg, "--")) {
            const eq = std.mem.indexOfScalar(u8, arg, '=');
            const name = arg[2 .. eq orelse arg.len];
            if (eq) |e| value = arg[e + 1 ..];
            const longs = [_]struct { []const u8, u8 }{
                .{ "brief", 'q' },              .{ "report-identical-files", 's' },  .{ "recursive", 'r' },
                .{ "new-file", 'N' },           .{ "unidirectional-new-file", 'P' }, .{ "text", 'a' },
                .{ "ignore-case", 'i' },        .{ "ignore-space-change", 'b' },     .{ "ignore-all-space", 'w' },
                .{ "ignore-blank-lines", 'B' }, .{ "minimal", 'd' },                 .{ "ed", 'e' },
                .{ "forward-ed", 'f' },         .{ "rcs", 'n' },                     .{ "expand-tabs", 't' },
                .{ "initial-tab", 'T' },        .{ "show-c-function", 'p' },         .{ "unified", 'U' },
                .{ "context", 'C' },            .{ "label", 'L' },                   .{ "ignore-matching-lines", 'I' },
                .{ "exclude", 'x' },            .{ "exclude-from", 'X' },            .{ "starting-file", 'S' },
                .{ "strip-trailing-cr", 'R' },  .{ "normal", 'o' },
            };
            for (longs) |l| if (std.mem.eql(u8, l[0], name)) {
                c = l[1];
            };
            if (c == 0) {
                errout.printf("diff: unknown option: {s}\n", .{arg});
                return 2;
            }
            // --unified and --context have an optional value:
            if (c == 'U' or c == 'C') {
                d.format = if (c == 'U') .unified else .context;
                d.context = 3;
                if (value) |v| if (!d.optionValue(c, v)) return badNumber(v);
                continue;
            }
            if (std.mem.indexOfScalar(u8, "LIxXS", c) == null) {
                if (c == 'R') d.strip_cr = true else if (c == 'o') d.format = .normal else _ = d.flag(c);
                continue;
            }
        } else {
            var k: usize = 1;
            while (k < arg.len) : (k += 1) {
                c = arg[k];
                if (std.mem.indexOfScalar(u8, "UCLIxXS", c) != null) {
                    if (k + 1 < arg.len) value = arg[k + 1 ..];
                    break;
                }
                // -u5, -c10: the context after -u or -c:
                if (std.ascii.isDigit(c) and k > 1 and (arg[k - 1] == 'u' or arg[k - 1] == 'c')) {
                    d.context = std.fmt.parseInt(usize, arg[k..], 10) catch return badNumber(arg[k..]);
                    c = 0;
                    break;
                }
                if (!d.flag(c)) {
                    errout.printf("diff: unknown option: -{c}\n", .{c});
                    return 2;
                }
                c = 0;
            }
            if (c == 0) continue;
        }
        if (value == null) {
            i += 1;
            if (i == args.len) return usage();
            value = args[i];
            switches.append(a, ' ') catch return outOfMemory();
            switches.appendSlice(a, args[i]) catch return outOfMemory();
        }
        const v = value.?;
        switch (c) {
            'U', 'C' => if (!d.optionValue(c, v)) return badNumber(v),
            'L' => {
                if (nlabels == 2) return usage();
                d.labels[nlabels] = v;
                nlabels += 1;
            },
            'I' => {
                if (ignore.items.len > 0) ignore.append(a, '|') catch return outOfMemory();
                ignore.appendSlice(a, v) catch return outOfMemory();
            },
            'x' => d.excludes.append(a, v) catch return outOfMemory(),
            'X' => {
                const list = readFile(a, v) catch |err| {
                    errout.printf("diff: {s}: {s}\n", .{ v, zdos.message(err) });
                    return 2;
                };
                var it = std.mem.tokenizeAny(u8, list, "\r\n");
                while (it.next()) |pat| d.excludes.append(a, pat) catch return outOfMemory();
            },
            'S' => d.start_at = v,
            else => unreachable,
        }
    }
    if (operands.items.len != 2) return usage();
    if (ignore.items.len > 0) {
        d.ignore_re = regex.compile(a, ignore.items, .{}) catch {
            errout.printf("diff: {s}: bad regular expression\n", .{ignore.items});
            return 2;
        };
    }
    d.switches = switches.items;
    d.pair(operands.items[0], operands.items[1], .{ false, false }, false);
    if (interrupted.*) return 2;
    return d.status;
}

fn usage() u8 {
    errout.print("usage: diff [-abdipTtw] [-c | -e | -f | -n | -q | -u] [-B] [-I pattern] [-L label] file1 file2\n" ++
        "       diff ... -C number | -U number file1 file2\n" ++
        "       diff [-abdiNPprsTtw] [-c | -e | -f | -n | -q | -u] [-S name] [-X file] [-x pattern] dir1 dir2\n");
    return 2;
}

fn badNumber(v: []const u8) u8 {
    errout.printf("diff: invalid context length: {s}\n", .{v});
    return 2;
}

fn outOfMemory() u8 {
    errout.print("diff: not enough memory\n");
    return 2;
}
