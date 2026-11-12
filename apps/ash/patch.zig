// patch: applies unified, context and normal diffs, as BSD patch
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const sys = @import("../zdos/system.zig");
const errout = @import("errout.zig");
const diff = @import("diff.zig");

const Allocator = std.mem.Allocator;
const Lines = diff.Lines;

const PLine = struct {
    kind: u8, // ' ', '-' or '+'
    text: []const u8,
    nl: bool = true,
};

const Hunk = struct {
    old_start: usize, // the first old line; with old_len 0 the line before
    old_len: usize = 0,
    new_start: usize,
    new_len: usize = 0,
    lines: []PLine,
    // BSD patch's context (the most fuzz): before the first change, 100
    // without (0 for normal diffs):
    ctx: usize = 100,

    fn context(h: *const Hunk) usize {
        return h.ctx;
    }

    fn reversed(h: *const Hunk, a: Allocator) Allocator.Error!Hunk {
        const lines = try a.alloc(PLine, h.lines.len);
        // Within a change the deleted lines come first:
        var i: usize = 0;
        var k: usize = 0;
        while (i < h.lines.len) {
            if (h.lines[i].kind == ' ') {
                lines[k] = h.lines[i];
                i += 1;
                k += 1;
                continue;
            }
            var end = i;
            while (end < h.lines.len and h.lines[end].kind != ' ') end += 1;
            for ([2]u8{ '+', '-' }) |from| {
                for (h.lines[i..end]) |l| if (l.kind == from) {
                    lines[k] = l;
                    lines[k].kind = if (from == '+') '-' else '+';
                    k += 1;
                };
            }
            i = end;
        }
        return .{ .old_start = h.new_start, .old_len = h.new_len, .new_start = h.old_start, .new_len = h.old_len, .lines = lines, .ctx = h.ctx };
    }
};

const FilePatch = struct {
    names: [3]?[]const u8 = .{ null, null, null }, // old, new, Index:
    epoch: [2]bool = .{ false, false }, // /dev/null, or dated 1970-01-01 UTC (diff -N)
    stamps: [2][]const u8 = .{ "", "" }, // what follows the names
    kind: enum { unified, context, normal } = .unified,
    hunks: []Hunk = &.{},
    lead: []const []const u8 = &.{}, // the lines before the first hunk
    at: usize = 0, // the line where its first hunk starts
};

const Error = Allocator.Error || error{Malformed};

fn trimCr(s: []const u8) []const u8 {
    return if (s.len > 0 and s[s.len - 1] == '\r') s[0 .. s.len - 1] else s;
}

const Parser = struct {
    a: Allocator,
    lines: []const []const u8,
    i: usize = 0,
    bad_line: usize = 0,
    index: ?[]const u8 = null,
    diff_name: ?[]const u8 = null, // from a "diff ... OLD NEW" line, for normal diffs

    fn line(p: *Parser, k: usize) ?[]const u8 {
        return if (k < p.lines.len) trimCr(p.lines[k]) else null;
    }

    fn malformed(p: *Parser) error{Malformed} {
        p.bad_line = p.i + 1;
        return error.Malformed;
    }

    // Null at the end.
    fn next(p: *Parser) Error!?FilePatch {
        const start = p.i;
        var fp = try p.find() orelse return null;
        fp.lead = p.lines[start .. fp.at - 1];
        return fp;
    }

    fn find(p: *Parser) Error!?FilePatch {
        while (p.i < p.lines.len) {
            const l = p.line(p.i).?;
            const l1 = p.line(p.i + 1) orelse "";
            const l2 = p.line(p.i + 2) orelse "";
            if (std.mem.startsWith(u8, l, "--- ") and std.mem.startsWith(u8, l1, "+++ ") and std.mem.startsWith(u8, l2, "@@ ")) {
                var fp = p.named(l, l1);
                p.i += 2;
                fp.at = p.i + 1;
                var hunks: std.ArrayListUnmanaged(Hunk) = .{};
                while (p.line(p.i)) |h| {
                    if (!std.mem.startsWith(u8, h, "@@ ")) break;
                    try hunks.append(p.a, try p.unified());
                }
                fp.hunks = hunks.items;
                return fp;
            }
            if (std.mem.startsWith(u8, l, "*** ") and std.mem.startsWith(u8, l1, "--- ") and std.mem.startsWith(u8, l2, "***************")) {
                var fp = p.named(l, l1);
                fp.kind = .context;
                p.i += 2;
                fp.at = p.i + 1;
                var hunks: std.ArrayListUnmanaged(Hunk) = .{};
                while (p.line(p.i)) |h| {
                    if (!std.mem.startsWith(u8, h, "***************")) break;
                    try hunks.append(p.a, try p.context());
                }
                fp.hunks = hunks.items;
                return fp;
            }
            if (normalHeader(l) != null) {
                var fp: FilePatch = .{ .names = .{ p.diff_name, null, p.index }, .at = p.i + 1, .kind = .normal };
                p.index = null;
                p.diff_name = null;
                var hunks: std.ArrayListUnmanaged(Hunk) = .{};
                while (p.line(p.i)) |h| {
                    const r = normalHeader(h) orelse break;
                    try hunks.append(p.a, try p.normal(r));
                }
                fp.hunks = hunks.items;
                return fp;
            }
            if (std.mem.startsWith(u8, l, "Index: ")) p.index = std.mem.trim(u8, l[7..], " \t");
            if (std.mem.startsWith(u8, l, "diff ")) {
                // The second last word not an option: the old file:
                var words: std.ArrayListUnmanaged([]const u8) = .{};
                var it = std.mem.tokenizeAny(u8, l[5..], " \t");
                while (it.next()) |w| if (w[0] != '-') try words.append(p.a, w);
                p.diff_name = if (words.items.len >= 2) words.items[words.items.len - 2] else null;
                p.index = null;
            }
            p.i += 1;
        }
        return null;
    }

    fn named(p: *Parser, old: []const u8, new: []const u8) FilePatch {
        var fp: FilePatch = .{};
        for ([2][]const u8{ old[4..], new[4..] }, 0..) |s, k| {
            const tab = std.mem.indexOfScalar(u8, s, '\t');
            const end = tab orelse std.mem.indexOfScalar(u8, s, ' ') orelse s.len;
            const name = s[0..end];
            fp.names[k] = if (std.mem.eql(u8, name, "/dev/null")) null else name;
            fp.stamps[k] = s[end..];
            fp.epoch[k] = std.mem.eql(u8, name, "/dev/null") or (end < s.len and isEpoch(s[end + 1 ..]));
        }
        fp.names[2] = p.index;
        p.index = null;
        p.diff_name = null;
        return fp;
    }

    fn unified(p: *Parser) Error!Hunk {
        const h = p.line(p.i).?;
        var r = Ranges{ .s = h, .pos = 3 };
        if (!r.char('-')) return p.malformed();
        const old_start = r.num() orelse return p.malformed();
        const old_len = if (r.char(',')) r.num() orelse return p.malformed() else 1;
        if (!r.char(' ') or !r.char('+')) return p.malformed();
        const new_start = r.num() orelse return p.malformed();
        const new_len = if (r.char(',')) r.num() orelse return p.malformed() else 1;
        p.i += 1;
        var lines: std.ArrayListUnmanaged(PLine) = .{};
        var olds: usize = 0;
        var news: usize = 0;
        while (olds < old_len or news < new_len) : (p.i += 1) {
            if (p.i >= p.lines.len) return p.malformed();
            const l = p.lines[p.i];
            // A context line whose space an editor dropped:
            if (l.len == 0 or std.mem.eql(u8, l, "\r")) {
                try lines.append(p.a, .{ .kind = ' ', .text = l });
                olds += 1;
                news += 1;
                continue;
            }
            switch (l[0]) {
                ' ', '-', '+' => {
                    try lines.append(p.a, .{ .kind = l[0], .text = l[1..] });
                    if (l[0] != '+') olds += 1;
                    if (l[0] != '-') news += 1;
                },
                '\\' => if (lines.items.len > 0) {
                    lines.items[lines.items.len - 1].nl = false;
                },
                else => return p.malformed(),
            }
        }
        if (olds != old_len or news != new_len) return p.malformed();
        p.noNewline(lines.items);
        return .{ .old_start = old_start, .old_len = old_len, .new_start = new_start, .new_len = new_len, .lines = lines.items, .ctx = leading(lines.items, false) };
    }

    fn noNewline(p: *Parser, lines: []PLine) void {
        while (p.line(p.i)) |l| {
            if (l.len == 0 or l[0] != '\\') break;
            if (lines.len > 0) lines[lines.len - 1].nl = false;
            p.i += 1;
        }
    }

    // "*** A,B ****" or "--- A,B ----": the start and the number of lines.
    fn contextRange(p: *Parser, l: []const u8, mark: []const u8) Error![2]usize {
        const start: []const u8 = if (mark[1] == '*') "*** " else "--- ";
        if (!std.mem.startsWith(u8, l, start) or !std.mem.endsWith(u8, l, mark)) return p.malformed();
        var r = Ranges{ .s = l, .pos = 4 };
        const a = r.num() orelse return p.malformed();
        if (!r.char(',')) return .{ a, @intFromBool(a != 0) };
        const b = r.num() orelse return p.malformed();
        return .{ a, if (b >= a) b - a + 1 else 0 };
    }

    // Lines with two-character marks.
    fn contextSide(p: *Parser, list: *std.ArrayListUnmanaged(PLine), count: usize, marks: []const u8) Error!void {
        var n: usize = 0;
        while (n < count) : (p.i += 1) {
            if (p.i >= p.lines.len) return p.malformed();
            const l = p.lines[p.i];
            if (l.len > 0 and l[0] == '\\') {
                if (list.items.len > 0) list.items[list.items.len - 1].nl = false;
                continue;
            }
            if (l.len == 0 or std.mem.eql(u8, l, "\r")) {
                try list.append(p.a, .{ .kind = ' ', .text = l });
            } else {
                if (std.mem.indexOfScalar(u8, marks, l[0]) == null or (l.len > 1 and l[1] != ' ')) return p.malformed();
                try list.append(p.a, .{ .kind = l[0], .text = if (l.len > 1) l[2..] else "" });
            }
            n += 1;
        }
        p.noNewline(list.items);
    }

    fn context(p: *Parser) Error!Hunk {
        p.i += 1;
        const old = try p.contextRange(p.line(p.i) orelse return p.malformed(), " ****");
        p.i += 1;
        var olds: std.ArrayListUnmanaged(PLine) = .{};
        var news: std.ArrayListUnmanaged(PLine) = .{};
        const l = p.line(p.i) orelse return p.malformed();
        if (!(std.mem.startsWith(u8, l, "--- ") and std.mem.endsWith(u8, l, " ----"))) try p.contextSide(&olds, old[1], " -!");
        const new = try p.contextRange(p.line(p.i) orelse return p.malformed(), " ----");
        p.i += 1;
        if (p.line(p.i)) |n| {
            if (n.len >= 2 and n[1] == ' ' and std.mem.indexOfScalar(u8, " +!", n[0]) != null) try p.contextSide(&news, new[1], " +!");
        }
        // A side left out has no changes: the other side's context lines:
        if (olds.items.len == 0) for (news.items) |x| if (x.kind == ' ') try olds.append(p.a, x);
        if (news.items.len == 0) for (olds.items) |x| if (x.kind == ' ') try news.append(p.a, x);
        var lines: std.ArrayListUnmanaged(PLine) = .{};
        var i: usize = 0;
        var j: usize = 0;
        const o = olds.items;
        const n = news.items;
        while (i < o.len or j < n.len) {
            if (i < o.len and o[i].kind == '-') {
                try lines.append(p.a, o[i]);
                i += 1;
            } else if (j < n.len and n[j].kind == '+') {
                try lines.append(p.a, n[j]);
                j += 1;
            } else if ((i < o.len and o[i].kind == '!') or (j < n.len and n[j].kind == '!')) {
                while (i < o.len and o[i].kind == '!') : (i += 1) try lines.append(p.a, .{ .kind = '-', .text = o[i].text, .nl = o[i].nl });
                while (j < n.len and n[j].kind == '!') : (j += 1) try lines.append(p.a, .{ .kind = '+', .text = n[j].text, .nl = n[j].nl });
            } else if (i < o.len and j < n.len) {
                var c = o[i];
                c.nl = o[i].nl and n[j].nl;
                try lines.append(p.a, c);
                i += 1;
                j += 1;
            } else return p.malformed();
        }
        var h: Hunk = .{ .old_start = old[0], .new_start = new[0], .lines = lines.items, .ctx = leading(lines.items, true) };
        for (lines.items) |x| {
            if (x.kind != '+') h.old_len += 1;
            if (x.kind != '-') h.new_len += 1;
        }
        return h;
    }

    fn normal(p: *Parser, r: NormalRange) Error!Hunk {
        p.i += 1;
        var lines: std.ArrayListUnmanaged(PLine) = .{};
        if (r.op != 'a') try p.normalSide(&lines, r.old[1] - r.old[0] + 1, "< ", '-');
        if (r.op == 'c') {
            if (!std.mem.eql(u8, p.line(p.i) orelse "", "---")) return p.malformed();
            p.i += 1;
        }
        if (r.op != 'd') try p.normalSide(&lines, r.new[1] - r.new[0] + 1, "> ", '+');
        return .{
            .old_start = r.old[0],
            .old_len = if (r.op == 'a') 0 else r.old[1] - r.old[0] + 1,
            .new_start = r.new[0],
            .new_len = if (r.op == 'd') 0 else r.new[1] - r.new[0] + 1,
            .lines = lines.items,
            .ctx = 0,
        };
    }

    fn normalSide(p: *Parser, list: *std.ArrayListUnmanaged(PLine), count: usize, mark: []const u8, kind: u8) Error!void {
        const first = list.items.len;
        while (list.items.len - first < count) : (p.i += 1) {
            if (p.i >= p.lines.len) return p.malformed();
            const l = p.lines[p.i];
            if (l.len > 0 and l[0] == '\\') {
                if (list.items.len > first) list.items[list.items.len - 1].nl = false;
                continue;
            }
            if (!std.mem.startsWith(u8, l, mark)) return p.malformed();
            try list.append(p.a, .{ .kind = kind, .text = l[2..] });
        }
        p.noNewline(list.items[first..]);
    }
};

// Unified diffs: 100 for none.
fn leading(lines: []const PLine, zero_counts: bool) usize {
    for (lines, 0..) |l, n| {
        if (l.kind != ' ') return if (n > 0 or zero_counts) n else 100;
    }
    return 100;
}

const Ranges = struct {
    s: []const u8,
    pos: usize,

    fn char(r: *Ranges, c: u8) bool {
        if (r.pos < r.s.len and r.s[r.pos] == c) {
            r.pos += 1;
            return true;
        }
        return false;
    }

    fn num(r: *Ranges) ?usize {
        const start = r.pos;
        while (r.pos < r.s.len and std.ascii.isDigit(r.s[r.pos])) r.pos += 1;
        return std.fmt.parseInt(usize, r.s[start..r.pos], 10) catch null;
    }
};

const NormalRange = struct { old: [2]usize, op: u8, new: [2]usize };

// "A[,B]{a,c,d}C[,D]"
fn normalHeader(l: []const u8) ?NormalRange {
    var r = Ranges{ .s = l, .pos = 0 };
    var x: NormalRange = undefined;
    x.old[0] = r.num() orelse return null;
    x.old[1] = if (r.char(',')) r.num() orelse return null else x.old[0];
    if (r.pos >= l.len or std.mem.indexOfScalar(u8, "acd", l[r.pos]) == null) return null;
    x.op = l[r.pos];
    r.pos += 1;
    x.new[0] = r.num() orelse return null;
    x.new[1] = if (r.char(',')) r.num() orelse return null else x.new[0];
    if (r.pos != l.len or x.old[1] < x.old[0] or x.new[1] < x.new[0]) return null;
    return x;
}

// "1970-01-01 00:00:00[.000] +0000" in any zone, or as ctime() writes
// it ("Thu Jan  1 00:00:00 1970", "Wed Dec 31 ... 1969").
fn isEpoch(s_in: []const u8) bool {
    const s = std.mem.trim(u8, s_in, " \t");
    if (s.len == 24 and s[3] == ' ' and s[7] == ' ')
        return (std.mem.eql(u8, s[4..10], "Jan  1") and std.mem.endsWith(u8, s, " 1970")) or
            (std.mem.eql(u8, s[4..10], "Dec 31") and std.mem.endsWith(u8, s, " 1969"));
    if (s.len < 19 or s[10] != ' ' or s[13] != ':' or s[16] != ':') return false;
    var secs: i64 = if (std.mem.startsWith(u8, s, "1970-01-01")) 0 else if (std.mem.startsWith(u8, s, "1969-12-31")) -86400 else return false;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return false;
    const m = std.fmt.parseInt(i64, s[14..16], 10) catch return false;
    const sec = std.fmt.parseInt(i64, s[17..19], 10) catch return false;
    secs += h * 3600 + m * 60 + sec;
    var rest = s[19..];
    while (rest.len > 0 and (rest[0] == '.' or std.ascii.isDigit(rest[0]))) {
        if (rest[0] != '.' and rest[0] != '0') return false;
        rest = rest[1..];
    }
    rest = std.mem.trim(u8, rest, " ");
    if (rest.len == 5 and (rest[0] == '+' or rest[0] == '-')) {
        const zh = std.fmt.parseInt(i64, rest[1..3], 10) catch return false;
        const zm = std.fmt.parseInt(i64, rest[3..5], 10) catch return false;
        const zone = (zh * 3600 + zm * 60) * @as(i64, if (rest[0] == '-') -1 else 1);
        secs -= zone;
    }
    return secs == 0;
}

// As BSD patch (Larry Wall's): messages, hunk search, fuzz, reversed
// patches and reject files.
const Patch = struct {
    a: Allocator,
    strip: ?usize = null, // null: BSD's default (the base name, or the whole
    reverse: bool = false,
    noreverse: bool = false, // -N
    force: bool = false,
    batch: bool = false,
    check: bool = false, // -C, --dry-run
    backups: bool = true, // as BSD patch: NAME.orig unless -V none or --posix
    suffix: []const u8 = ".orig",
    prefix: []const u8 = "", // -B
    remove_empty: bool = false,
    verbose: bool = true,
    loose: bool = false, // -l
    max_fuzz: usize = 2,
    orig: ?[]const u8 = null,
    output: ?[]const u8 = null,
    reject_name: ?[]const u8 = null, // -r
    output_used: bool = false,
    patches: usize = 0,
    status: u8 = 0,

    fn flag(self: *Patch, c: u8) bool {
        switch (c) {
            'R' => self.reverse = true,
            'N' => self.noreverse = true,
            'b' => self.backups = true,
            'C' => self.check = true,
            'E' => self.remove_empty = true,
            'f' => self.force = true,
            't' => self.batch = true,
            's' => self.verbose = false,
            'l' => self.loose = true,
            'u', 'c', 'n' => {}, // the kind of diff: found anyway
            else => return false,
        }
        return true;
    }

    fn valued(self: *Patch, c: u8, value: []const u8, input: *?[]const u8) bool {
        switch (c) {
            'i' => input.* = value,
            'o' => self.output = value,
            'r' => self.reject_name = value,
            'z' => self.suffix = value,
            'B' => self.prefix = value,
            // As BSD's get_version ("never": simple), but none turns them off:
            'V' => self.backups = !std.mem.eql(u8, value, "none"),
            'd' => zdos.setCwd(value) catch |err| {
                errout.print(join(self.a, .{ "patch: **** can't cd to ", value, ": ", zdos.message(err), "\n" }));
                return false;
            },
            else => {
                const n = std.fmt.parseInt(usize, value, 10) catch {
                    errout.print(join(self.a, .{ "patch: bad number: ", value, "\n" }));
                    return false;
                };
                if (c == 'p') self.strip = n else self.max_fuzz = n;
            },
        }
        return true;
    }

    // To the error output as in BSD patch; std.fmt for each would be large.
    // say always, tell unless -s.
    fn say(self: *Patch, pieces: anytype) void {
        errout.print(join(self.a, pieces));
    }

    fn tell(self: *Patch, pieces: anytype) void {
        if (self.verbose) self.say(pieces);
    }

    fn trouble(self: *Patch, pieces: anytype) void {
        errout.print(join(self.a, .{"patch: **** "} ++ pieces ++ .{"\n"}));
        self.status = 2;
    }

    fn noMemory(self: *Patch) void {
        self.trouble(.{"out of memory"});
    }

    // -p: as BSD's fetchname; null when the name has too few parts.
    fn stripped(self: *const Patch, name: []const u8) ?[]const u8 {
        if (self.strip == null) {
            const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return name;
            if (slash + 1 == name.len) return null;
            if (name[0] != '/') if (zdos.stat(name[0..slash])) |e| if (e.is_dir) return name else {} else |_| {};
            return name[slash + 1 ..];
        }
        var s = name;
        for (0..self.strip.?) |_| {
            const slash = std.mem.indexOfScalar(u8, s, '/') orelse return null;
            s = s[slash + 1 ..];
            while (s.len > 0 and s[0] == '/') s = s[1..];
        }
        return if (s.len == 0) null else s;
    }

    // BSD's best_name: of existing files (unless any will do) the fewest
    // parts, then the shortest base name, then the shortest; the Index:
    // name only without the others.
    fn bestName(self: *Patch, fp: *const FilePatch, any: bool) ?[]const u8 {
        var best: ?[]const u8 = null;
        const count: usize = if (fp.names[0] != null or fp.names[1] != null) 2 else 3;
        for (fp.names[0..count]) |n| {
            const name = self.stripped(n orelse continue) orelse continue;
            if (!any) {
                const e = zdos.stat(name) catch continue;
                if (e.is_dir) continue;
            }
            if (best == null or better(name, best.?)) best = name;
        }
        return best;
    }

    fn better(x: []const u8, y: []const u8) bool {
        const px = std.mem.count(u8, x, "/");
        const py = std.mem.count(u8, y, "/");
        if (px != py) return px < py;
        const bx = x.len - (if (std.mem.lastIndexOfScalar(u8, x, '/')) |s| s + 1 else 0);
        const by = y.len - (if (std.mem.lastIndexOfScalar(u8, y, '/')) |s| s + 1 else 0);
        if (bx != by) return bx < by;
        return x.len < y.len;
    }

    // Besides -l (white space), lines that differ only in a final "\r" match:
    // Unix patches apply to DOS files and the other way round.
    fn same(self: *const Patch, p: []const u8, f: []const u8) bool {
        if (std.mem.eql(u8, p, f) or std.mem.eql(u8, trimCr(p), trimCr(f))) return true;
        if (!self.loose) return false;
        var i: usize = 0;
        var j: usize = 0;
        while (true) {
            if (i < p.len and std.ascii.isWhitespace(p[i])) {
                if (j == f.len or !std.ascii.isWhitespace(f[j])) return false;
                while (i < p.len and std.ascii.isWhitespace(p[i])) i += 1;
                while (j < f.len and std.ascii.isWhitespace(f[j])) j += 1;
                continue;
            }
            if (i == p.len or j == f.len) return i == p.len and j == f.len;
            if (p[i] != f[j]) return false;
            i += 1;
            j += 1;
        }
    }

    // BSD's patch_match: fuzz lines at both ends don't count; the last
    // lines agree on the line end.
    fn matches(self: *const Patch, h: *const Hunk, input: Lines, at: usize, fuzz: usize) bool {
        if (at + h.old_len > input.lines.len) return false;
        var k: usize = 0;
        for (h.lines) |l| {
            if (l.kind == '+') continue;
            defer k += 1;
            if (k < fuzz or k + fuzz >= h.old_len) continue;
            if (!self.same(l.text, input.lines[at + k])) return false;
            if (at + k + 1 == input.lines.len and l.nl == input.incomplete) return false;
        }
        return true;
    }

    // BSD's locate_hunk: at the guess, then 1, 2 ... lines after and before
    // it (not before the last hunk's end, less its context).
    fn locate(self: *const Patch, h: *const Hunk, input: Lines, guess: usize, frozen: usize, fuzz: usize) ?usize {
        if (h.old_len == 0) return guess;
        const n = input.lines.len;
        const lowest = frozen -| h.context();
        if (guess < n and self.matches(h, input, guess, fuzz)) return guess;
        var off: usize = 1;
        while (true) : (off += 1) {
            const after = guess + off + h.old_len <= n;
            const before = off <= guess and guess - off >= lowest;
            if (!after and !before) return null;
            if (after and self.matches(h, input, guess + off, fuzz)) return guess + off;
            if (before and self.matches(h, input, guess - off, fuzz)) return guess - off;
        }
    }

    // BSD's pch_newfirst: with no new lines the line after, but for
    // unified hunks as given.
    fn newFirst(h: *const Hunk, kind: anytype, reversed: bool) usize {
        return h.new_start + @intFromBool(h.new_len == 0 and (kind == .normal or reversed));
    }

    fn firstLine(h: *const Hunk) usize {
        return if (h.old_len == 0) h.old_start else h.old_start - 1;
    }

    fn file(self: *Patch, fp_in: FilePatch) void {
        var fp = fp_in;
        const a = self.a;
        const kinds = [_][]const u8{ "a unified diff", "a new-style context diff", "a normal diff" };
        self.tell(.{ "Hmm...  ", if (self.patches == 0) "Looks" else "The next patch looks", " like ", kinds[@intFromEnum(fp.kind)], " to me...\n" });
        self.patches += 1;
        if (fp.lead.len > 0) {
            self.tell(.{"The text leading up to this was:\n--------------------------\n"});
            for (fp.lead) |l| self.tell(.{ "|", l, "\n" });
            self.tell(.{"--------------------------\n"});
        }
        const total = fp.hunks.len;
        const creating = fp.hunks.len > 0 and fp.hunks[0].old_len == 0 and fp.hunks[0].old_start == 0;
        var skip = false;
        const name = self.orig orelse self.bestName(&fp, creating) orelse blk: {
            self.say(.{"No file to patch.  Skipping...\n"});
            skip = true;
            break :blk self.bestName(&fp, true) orelse "patch";
        };
        const exists = if (zdos.stat(name)) |_| true else |_| false;
        var data: []const u8 = "";
        if (!skip) {
            if (exists) {
                data = diff.readFile(a, name) catch |err| return self.trouble(.{ "can't open file ", name, ": ", zdos.message(err) });
            } else if (creating) {
                self.tell(.{ "(Creating file ", name, "...)\n" });
            } else return self.trouble(.{ "can't find ", name });
            self.tell(.{ "Patching file ", name, " using Plan A...\n" });
        }
        const input = diff.splitLines(a, data) catch return self.noMemory();
        var out: std.ArrayListUnmanaged(u8) = .{};
        var rejects: std.ArrayListUnmanaged(Hunk) = .{};
        var reverse = self.reverse;
        var frozen: usize = 0;
        var last_offset: isize = 0;
        for (fp.hunks, 0..) |*hunk, k| {
            var h = if (reverse) hunk.reversed(a) catch return self.noMemory() else hunk.*;
            const max_fuzz = @min(self.max_fuzz, h.context());
            var where: ?usize = null;
            var fuzz: usize = 0;
            while (!skip) {
                const guess: usize = @intCast(@max(0, @as(isize, @intCast(firstLine(&h))) + last_offset));
                if (h.old_len == 0 and fuzz == 0 and fp.kind != .normal) self.tell(.{"Empty context always matches.\n"});
                where = self.locate(&h, input, guess, frozen, fuzz);
                if (where == null and k == 0 and !self.force) {
                    // Already applied, or reversed? Without
                    // a terminal to ask, as BSD patch: yes:
                    const r = h.reversed(a) catch return self.noMemory();
                    where = self.locate(&r, input, guess, frozen, fuzz);
                    if (where != null) {
                        if (self.noreverse) {
                            self.say(.{"Ignoring previously applied (or reversed) patch.\n"});
                            skip = true;
                            where = null;
                        } else {
                            reverse = !reverse;
                            h = r;
                            self.tell(.{ if (reverse) "R" else "Unr", "eversed (or previously applied) patch detected!  ", if (reverse) "Assuming" else "Ignoring", " -R.\n" });
                        }
                    }
                }
                if (where != null or skip or fuzz == max_fuzz) break;
                fuzz += 1;
            }
            const first = firstLine(&h);
            if (where) |at| {
                self.emit(&out, &h, input, at, &frozen) catch return self.noMemory();
                // Offsets add up (BSD patch's are from the last hunk's):
                last_offset = @as(isize, @intCast(at)) - @as(isize, @intCast(first));
                self.tell(.{ "Hunk #", k + 1, " succeeded at ", @as(isize, @intCast(newFirst(&h, fp.kind, reverse))) + last_offset });
                if (fuzz > 0) self.tell(.{ " with fuzz ", fuzz });
                if (last_offset != 0) self.tell(.{ " (offset ", last_offset, if (last_offset == 1) " line)" else " lines)" });
                self.tell(.{".\n"});
            } else {
                self.tell(.{ "Hunk #", k + 1, if (skip) " ignored at " else " failed at ", @as(isize, @intCast(newFirst(&h, fp.kind, reverse))) + last_offset, ".\n" });
                var r = h;
                r.old_start = @intCast(@max(0, @as(isize, @intCast(first + 1)) + last_offset));
                r.new_start = @intCast(@max(0, @as(isize, @intCast(newFirst(&h, fp.kind, reverse))) + last_offset));
                rejects.append(a, r) catch return self.noMemory();
            }
        }
        if (!skip) {
            self.copyLines(&out, input, frozen, input.lines.len) catch return self.noMemory();
            self.finish(&fp, name, exists, out.items);
        }
        if (rejects.items.len > 0) self.reject(&fp, name, rejects.items, if (skip) "ignored" else "failed", total);
    }

    fn copyLines(self: *Patch, out: *std.ArrayListUnmanaged(u8), input: Lines, from: usize, to: usize) Allocator.Error!void {
        for (from..to) |i| {
            try out.appendSlice(self.a, input.lines[i]);
            if (!(input.incomplete and i + 1 == input.lines.len)) try out.append(self.a, '\n');
        }
    }

    // BSD's apply_hunk: the file is copied up to each change, so context
    // lines are the file's; if they differ only in "\r", added lines get
    // the file's line ends.
    fn emit(self: *Patch, out: *std.ArrayListUnmanaged(u8), h: *const Hunk, input: Lines, at: usize, frozen: *usize) Allocator.Error!void {
        var add_cr = false;
        var drop_cr = false;
        var k: usize = 0;
        for (h.lines) |l| {
            if (l.kind == '+') continue;
            const f = input.lines[at + k];
            k += 1;
            if (std.mem.eql(u8, l.text, f)) continue;
            if (f.len == l.text.len + 1 and std.mem.endsWith(u8, f, "\r") and std.mem.startsWith(u8, f, l.text)) add_cr = true;
            if (l.text.len == f.len + 1 and std.mem.endsWith(u8, l.text, "\r") and std.mem.startsWith(u8, l.text, f)) drop_cr = true;
        }
        k = 0;
        for (h.lines) |l| {
            if (l.kind == ' ') {
                k += 1;
                continue;
            }
            if (at + k > frozen.*) {
                try self.copyLines(out, input, frozen.*, at + k);
                frozen.* = at + k;
            }
            if (l.kind == '-') {
                frozen.* = @max(frozen.*, at + k + 1);
                k += 1;
                continue;
            }
            var t = l.text;
            if (drop_cr and !add_cr) t = trimCr(t);
            try out.appendSlice(self.a, t);
            if (add_cr and !drop_cr and !std.mem.endsWith(u8, t, "\r")) try out.append(self.a, '\r');
            if (l.nl) try out.append(self.a, '\n');
        }
    }

    fn finish(self: *Patch, fp: *const FilePatch, name: []const u8, exists: bool, result: []const u8) void {
        if (self.check) return;
        const target = self.output orelse name;
        if (std.mem.eql(u8, target, "-")) return zdos.print(result);
        const target_exists = if (self.output == null) exists else if (zdos.stat(target)) |_| true else |_| false;
        if (self.output != null and self.output_used) return self.append(target, result);
        if (target_exists and self.backups) self.makeBackup(target);
        self.write(target, target_exists and !self.backups, result);
        self.output_used = true;
        // -E, and (not in BSD) a file the patch deletes, to /dev/null or dated
        // 1970-01-01:
        if (result.len == 0 and (self.remove_empty or fp.epoch[1])) {
            self.tell(.{ "Removing ", target, " (empty after patching).\n" });
            zdos.delete(target) catch |err| return self.trouble(.{ "can't remove ", target, ": ", zdos.message(err) });
            removeEmptyParents(target);
        }
    }

    fn makeBackup(self: *Patch, name: []const u8) void {
        const backup = if (self.prefix.len > 0) join(self.a, .{ self.prefix, name }) else join(self.a, .{ name, self.suffix });
        zdos.delete(backup) catch {};
        zdos.move(name, backup) catch |err| self.trouble(.{ "can't backup ", name, ": ", zdos.message(err) });
    }

    // Through a temporary file beside it, which then takes its place.
    fn write(self: *Patch, name: []const u8, replace: bool, data: []const u8) void {
        makeParents(name);
        const tmp = join(self.a, .{ name, ".ptmp" });
        const mode: ?u32 = if (zdos.permissions(name)) |p| (if (p.unix) p.mode & 0o7777 else null) else |_| null;
        const f = zdos.open(tmp, .write) catch |err| return self.trouble(.{ "can't create ", tmp, ": ", zdos.message(err) });
        f.writeAll(data) catch |err| {
            f.close();
            zdos.delete(tmp) catch {};
            return self.trouble(.{ "can't write ", tmp, ": ", zdos.message(err) });
        };
        f.closeChecked() catch |err| {
            zdos.delete(tmp) catch {};
            return self.trouble(.{ "can't write ", tmp, ": ", zdos.message(err) });
        };
        if (replace) zdos.delete(name) catch |err| return self.trouble(.{ "can't replace ", name, ": ", zdos.message(err), " (the result is in ", tmp, ")" });
        zdos.move(tmp, name) catch |err| return self.trouble(.{ "can't create ", name, ": ", zdos.message(err), ", output is in ", tmp });
        if (mode) |m| zdos.setMode(name, m) catch {};
    }

    // -o with several files: one after another.
    fn append(self: *Patch, o: []const u8, data: []const u8) void {
        const f = zdos.open(o, .update) catch |err| return self.trouble(.{ "can't open ", o, ": ", zdos.message(err) });
        defer f.close();
        f.seek(zdos.seek_end) catch {};
        f.writeAll(data) catch |err| self.trouble(.{ "can't write ", o, ": ", zdos.message(err) });
    }

    // NAME.rej: unified for a unified diff, else in context
    // form, as BSD's abort_hunk.
    fn reject(self: *Patch, fp: *const FilePatch, name: []const u8, hunks: []const Hunk, what: []const u8, total: usize) void {
        if (self.status == 0) self.status = 1;
        const base = self.output orelse name;
        var rej = self.reject_name orelse join(self.a, .{ if (std.mem.eql(u8, base, "-")) name else base, ".rej" });
        if (std.mem.lastIndexOfScalar(u8, rej, '/')) |slash| {
            if (zdos.stat(rej[0..slash])) |_| {} else |_| rej = rej[slash + 1 ..];
        }
        self.say(.{ hunks.len, " out of ", total, " hunks ", what, "--saving rejects to ", rej, "\n" });
        if (self.check) return;
        var s: std.ArrayListUnmanaged(u8) = .{};
        const w = s.writer(self.a);
        for (hunks) |h| {
            if (fp.kind == .unified) {
                w.print("@@ -{d},{d} +{d},{d} @@\n", .{ if (h.old_len > 0) h.old_start else 0, h.old_len, h.new_start, h.new_len }) catch return;
                for (h.lines) |l| {
                    w.print("{c}{s}\n", .{ l.kind, l.text }) catch return;
                    if (!l.nl) w.writeAll("\\ No newline at end of file\n") catch return;
                }
            } else writeContextHunk(w, &h, fp.kind == .normal) catch return;
        }
        const f = zdos.open(rej, .write) catch |err| return self.trouble(.{ "can't create ", rej, ": ", zdos.message(err) });
        defer f.close();
        f.writeAll(s.items) catch |err| self.trouble(.{ "can't write ", rej, ": ", zdos.message(err) });
    }
};

// Both sides in full, "!" for changed lines (normal diffs: "-" and "+",
// no stars after the ranges).
fn writeContextHunk(w: anytype, h: *const Hunk, normal: bool) !void {
    try w.writeAll("***************\n");
    for ([2]u8{ '-', '+' }) |side| {
        const start = if (side == '-') h.old_start else h.new_start;
        const count = if (side == '-') h.old_len else h.new_len;
        try w.writeAll(if (side == '-') "*** " else "--- ");
        if (count == 0) {
            try w.writeAll("0");
        } else if (count == 1) {
            try w.print("{d}", .{start});
        } else try w.print("{d},{d}", .{ start, start + count - 1 });
        try w.writeAll(if (normal) (if (side == '-') "\n" else " -----\n") else (if (side == '-') " ****\n" else " ----\n"));
        var i: usize = 0;
        while (i < h.lines.len) {
            if (h.lines[i].kind == ' ') {
                try w.print("  {s}\n", .{h.lines[i].text});
                i += 1;
                continue;
            }
            var end = i;
            var both = [2]bool{ false, false };
            while (end < h.lines.len and h.lines[end].kind != ' ') : (end += 1) both[@intFromBool(h.lines[end].kind == '+')] = true;
            for (h.lines[i..end]) |l| if (l.kind == side) {
                try w.print("{c} {s}\n", .{ if (both[0] and both[1] and !normal) '!' else side, l.text });
            };
            i = end;
        }
    }
}

fn join(a: Allocator, pieces: anytype) []const u8 {
    var s: std.ArrayListUnmanaged(u8) = .{};
    inline for (pieces) |p| {
        switch (@typeInfo(@TypeOf(p))) {
            .int, .comptime_int => {
                var buf: [24]u8 = undefined;
                s.appendSlice(a, std.fmt.bufPrint(&buf, "{d}", .{@as(i64, @intCast(p))}) catch unreachable) catch {};
            },
            else => s.appendSlice(a, p) catch {},
        }
    }
    return s.items;
}

fn makeParents(name: []const u8) void {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, name, i, '/')) |slash| : (i = slash + 1) {
        if (slash > 0) zdos.makeDir(name[0..slash]) catch {};
    }
}

// Folders that a removed file leaves empty go too.
fn removeEmptyParents(name: []const u8) void {
    var end = name.len;
    while (std.mem.lastIndexOfScalar(u8, name[0..end], '/')) |slash| : (end = slash) {
        if (slash == 0) return;
        const folder = name[0..slash];
        const dir = zdos.openDir(folder) catch return;
        var entry: zdos.DirEntry = undefined;
        var empty = true;
        while (dir.next(&entry) catch false) {
            const n = entry.name();
            if (!std.mem.eql(u8, n, ".") and !std.mem.eql(u8, n, "..")) empty = false;
        }
        dir.close();
        if (!empty) return;
        zdos.deleteTree(folder) catch return;
    }
}

pub fn run(interrupted: *bool, args: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(zdos.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p: Patch = .{ .a = a };
    // -d changes the folder for this command only:
    var cwd_buf: [1100]u8 = undefined;
    const cwd = zdos.getCwd(&cwd_buf);
    defer if (cwd.len > 0) zdos.setCwd(cwd) catch {};
    var input: ?[]const u8 = null;
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
        if (std.mem.startsWith(u8, arg, "--")) {
            const eq = std.mem.indexOfScalar(u8, arg, '=');
            const name = arg[2 .. eq orelse arg.len];
            const longs = [_]struct { []const u8, u8 }{
                .{ "strip", 'p' },             .{ "reverse", 'R' }, .{ "forward", 'N' },            .{ "input", 'i' },
                .{ "output", 'o' },            .{ "backup", 'b' },  .{ "remove-empty-files", 'E' }, .{ "fuzz", 'F' },
                .{ "ignore-whitespace", 'l' }, .{ "silent", 's' },  .{ "quiet", 's' },              .{ "force", 'f' },
                .{ "batch", 't' },             .{ "unified", 'u' }, .{ "context", 'c' },            .{ "normal", 'n' },
                .{ "check", 'C' },             .{ "dry-run", 'C' }, .{ "directory", 'd' },          .{ "prefix", 'B' },
                .{ "reject-file", 'r' },       .{ "suffix", 'z' },  .{ "version-control", 'V' },
            };
            var short: ?u8 = null;
            for (longs) |l| if (std.mem.eql(u8, l[0], name)) {
                short = l[1];
            };
            if (std.mem.eql(u8, name, "posix")) {
                p.backups = false;
            } else if (short) |c| {
                if (std.mem.indexOfScalar(u8, valued_options, c) != null) {
                    const value = if (eq) |e| arg[e + 1 ..] else blk: {
                        i += 1;
                        if (i == args.len) return usage();
                        break :blk args[i];
                    };
                    if (!p.valued(c, value, &input)) return 2;
                } else _ = p.flag(c);
            } else {
                errout.print(join(a, .{ "patch: unknown option: ", arg, "\n" }));
                return 2;
            }
            continue;
        }
        var k: usize = 1;
        while (k < arg.len) : (k += 1) {
            const c = arg[k];
            if (std.mem.indexOfScalar(u8, valued_options, c) != null) {
                const value = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                    i += 1;
                    if (i == args.len) return usage();
                    break :blk args[i];
                };
                if (!p.valued(c, value, &input)) return 2;
                break;
            }
            if (!p.flag(c)) {
                errout.print(join(a, .{ "patch: unknown option: -", arg[k .. k + 1], "\n" }));
                return 2;
            }
        }
    }
    if (operands.items.len > 2) return usage();
    if (operands.items.len >= 1) p.orig = operands.items[0];
    if (operands.items.len == 2) input = operands.items[1];
    const path = input orelse "-";
    const data = diff.readFile(a, path) catch |err| {
        errout.print(join(a, .{ "patch: ", path, ": ", zdos.message(err), "\n" }));
        return 2;
    };
    const lines = diff.splitLines(a, data) catch return outOfMemory();
    var parser: Parser = .{ .a = a, .lines = lines.lines };
    var any = false;
    var end: usize = 0; // where the last patch ended
    while (true) {
        if (sys.ctrlCPressed(true)) {
            interrupted.* = true;
            return 130;
        }
        const fp = parser.next() catch |err| {
            if (err == error.OutOfMemory) return outOfMemory();
            errout.print(join(a, .{ "patch: **** malformed patch at line ", parser.bad_line, ": ", if (parser.bad_line <= lines.lines.len) lines.lines[parser.bad_line - 1] else "", "\n" }));
            return 2;
        } orelse break;
        any = true;
        p.file(fp);
        end = parser.i;
        if (p.status == 2) return 2;
    }
    if (!any) {
        p.tell(.{"Hmm..."});
        p.say(.{"  I can't seem to find a patch in there anywhere.\n"});
    } else if (end < lines.lines.len) {
        p.tell(.{"Hmm...  Ignoring the trailing garbage.\n"});
    }
    if (any) p.tell(.{"done\n"});
    return p.status;
}

const valued_options = "pioFrzBVd";

fn usage() u8 {
    errout.print("usage: patch [-bCcEflNnRstu] [-B backup-prefix] [-d directory] [-F max-fuzz]\n" ++
        "             [-i patchfile] [-o out-file] [-p strip-count] [-r rej-name]\n" ++
        "             [-V none | simple] [-z backup-ext] [--posix] [origfile [patchfile]]\n");
    return 2;
}

fn outOfMemory() u8 {
    errout.print("patch: not enough memory\n");
    return 2;
}
