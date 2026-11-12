// Regular expressions for awk, grep and sed: POSIX ERE, and BRE
// translated to it. Leftmost-longest by a Thompson NFA (linear time);
// groups 1-9 for sed's \1 ... \9. Also \s \S \w \W, and escapes inside
// brackets, as awk has them.
const std = @import("std");

const Allocator = std.mem.Allocator;
const CharSet = std.StaticBitSet(256);

pub const Error = error{ BadRegex, OutOfMemory };

const Inst = union(enum) {
    char: u8,
    any,
    set: u16, // index into sets
    split: struct { a: u32, b: u32 }, // a is tried first
    jmp: u32,
    bol,
    eol,
    save: u8, // slot 2 * group (its start) or 2 * group + 1 (its end)
    match,
};

pub const Match = struct { start: usize, end: usize };

pub const Options = struct { icase: bool = false };

pub const max_groups = 9;
const unset = std.math.maxInt(usize);

pub const Regex = struct {
    prog: []Inst,
    sets: []CharSet,
    // Sized to the program.
    marks: []usize,
    clist: []Thread,
    nlist: []Thread,
    anchored: bool, // starts with ^: only position 0 can match
    // Slots per thread (2 per group), for each list, and of the best match.
    slots: usize,
    ccaps: []usize,
    ncaps: []usize,
    best_caps: []usize,

    pub fn deinit(self: *Regex, allocator: Allocator) void {
        allocator.free(self.prog);
        allocator.free(self.sets);
        allocator.free(self.marks);
        allocator.free(self.clist);
        allocator.free(self.nlist);
        allocator.free(self.ccaps);
        allocator.free(self.ncaps);
        allocator.free(self.best_caps);
    }

    // In the last successful search; null if it didn't take part.
    pub fn group(self: *const Regex, g: usize) ?Match {
        if (g == 0 or 2 * g > self.slots) return null;
        const s = self.best_caps[2 * g - 2];
        const e = self.best_caps[2 * g - 1];
        if (s == unset or e == unset) return null;
        return .{ .start = s, .end = e };
    }

    pub fn isMatch(self: *Regex, text: []const u8) bool {
        return self.search(text, 0) != null;
    }

    // ^ matches only at position 0 of text, $ only at its end.
    pub fn search(self: *Regex, text: []const u8, from: usize) ?Match {
        @memset(self.marks, 0);
        var none: [2 * max_groups]usize = undefined;
        @memset(&none, unset);
        var best: ?Match = null;
        var clen: usize = 0;
        var pos = from;
        while (true) : (pos += 1) {
            if (best == null and (!self.anchored or pos == 0)) {
                clen = self.add(.c, clen, 0, pos, pos, text.len, none[0..self.slots]);
            }
            if (clen == 0) {
                // No thread here ($ before the end, say): a match
                // may start further on:
                if (best != null or self.anchored or pos >= text.len) break;
                continue;
            }
            var nlen: usize = 0;
            for (self.clist[0..clen], 0..) |t, i| {
                if (best) |b| if (t.start > b.start) continue;
                const caps = self.ccaps[i * self.slots ..][0..self.slots];
                const step = switch (self.prog[t.pc]) {
                    .match => {
                        if (best == null or t.start < best.?.start or (t.start == best.?.start and pos > best.?.end)) {
                            best = .{ .start = t.start, .end = pos };
                            @memcpy(self.best_caps, caps);
                        }
                        continue;
                    },
                    .char => |c| pos < text.len and text[pos] == c,
                    .any => pos < text.len,
                    .set => |s| pos < text.len and self.sets[s].isSet(text[pos]),
                    else => false,
                };
                if (step) nlen = self.add(.n, nlen, t.pc + 1, t.start, pos + 1, text.len, caps);
            }
            if (pos >= text.len) break;
            std.mem.swap([]Thread, &self.clist, &self.nlist);
            std.mem.swap([]usize, &self.ccaps, &self.ncaps);
            clen = nlen;
        }
        return best;
    }

    const Which = enum { c, n };

    // Following jumps and splits, to the current list (c) or the next (n);
    // caps: its group positions.
    fn add(self: *Regex, which: Which, len: usize, pc: u32, start: usize, pos: usize, text_len: usize, caps: []const usize) usize {
        if (self.marks[pc] == pos + 1) return len;
        self.marks[pc] = pos + 1;
        switch (self.prog[pc]) {
            .jmp => |to| return self.add(which, len, to, start, pos, text_len, caps),
            .split => |s| {
                const n = self.add(which, len, s.a, start, pos, text_len, caps);
                return self.add(which, n, s.b, start, pos, text_len, caps);
            },
            .bol => return if (pos == 0) self.add(which, len, pc + 1, start, pos, text_len, caps) else len,
            .eol => return if (pos == text_len) self.add(which, len, pc + 1, start, pos, text_len, caps) else len,
            .save => |slot| return self.addSaved(which, len, pc, start, pos, text_len, caps, slot),
            else => {
                const list = if (which == .c) self.clist else self.nlist;
                const store = if (which == .c) self.ccaps else self.ncaps;
                list[len] = .{ .pc = pc, .start = start };
                @memcpy(store[len * self.slots ..][0..self.slots], caps);
                return len + 1;
            },
        }
    }

    // A .save: in a frame of its own, so add's stays small.
    fn addSaved(self: *Regex, which: Which, len: usize, pc: u32, start: usize, pos: usize, text_len: usize, caps: []const usize, slot: u8) usize {
        var copy: [2 * max_groups]usize = undefined;
        @memcpy(copy[0..self.slots], caps);
        copy[slot] = pos;
        return self.add(which, len, pc + 1, start, pos, text_len, copy[0..self.slots]);
    }
};

const Thread = struct { pc: u32, start: usize };

pub fn compile(allocator: Allocator, pattern: []const u8, options: Options) Error!Regex {
    var c: Compiler = .{ .allocator = allocator, .src = pattern, .icase = options.icase };
    defer c.prog.deinit(allocator);
    defer c.sets.deinit(allocator);
    try c.alternation(0);
    if (c.pos != c.src.len) return error.BadRegex;
    try c.emit(.match);
    const n = c.prog.items.len;
    const slots: usize = 2 * @as(usize, @min(c.groups, max_groups));
    const prog = try allocator.dupe(Inst, c.prog.items);
    errdefer allocator.free(prog);
    const sets = try allocator.dupe(CharSet, c.sets.items);
    errdefer allocator.free(sets);
    const marks = try allocator.alloc(usize, n);
    errdefer allocator.free(marks);
    const clist = try allocator.alloc(Thread, n);
    errdefer allocator.free(clist);
    const nlist = try allocator.alloc(Thread, n);
    errdefer allocator.free(nlist);
    const ccaps = try allocator.alloc(usize, n * slots);
    errdefer allocator.free(ccaps);
    const ncaps = try allocator.alloc(usize, n * slots);
    errdefer allocator.free(ncaps);
    const best_caps = try allocator.alloc(usize, slots);
    return .{
        .prog = prog,
        .sets = sets,
        .marks = marks,
        .clist = clist,
        .nlist = nlist,
        .slots = slots,
        .ccaps = ccaps,
        .ncaps = ncaps,
        .best_caps = best_caps,
        .anchored = pattern.len > 0 and pattern[0] == '^' and std.mem.indexOfScalar(u8, pattern, '|') == null,
    };
}

// \( \) \{ \} \| \+ \? become operators, the bare characters literal,
// and * at the start is literal.
pub fn fromBasic(allocator: Allocator, pattern: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var at_start = true;
    while (i < pattern.len) {
        const c = pattern[i];
        if (c == '[') {
            const end = bracketEnd(pattern, i);
            try out.appendSlice(allocator, pattern[i..end]);
            i = end;
            at_start = false;
            continue;
        }
        if (c == '\\' and i + 1 < pattern.len) {
            const n = pattern[i + 1];
            switch (n) {
                '(', ')', '{', '}', '|', '+', '?' => try out.append(allocator, n),
                else => try out.appendSlice(allocator, pattern[i .. i + 2]),
            }
            i += 2;
            at_start = n == '(' or n == '|';
            continue;
        }
        switch (c) {
            '(', ')', '{', '}', '|', '+', '?' => try out.appendSlice(allocator, &.{ '\\', c }),
            '*' => if (at_start) try out.appendSlice(allocator, "\\*") else try out.append(allocator, c),
            else => try out.append(allocator, c),
        }
        at_start = c == '^' and at_start;
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

// pattern[start] == '['
fn bracketEnd(pattern: []const u8, start: usize) usize {
    var i = start + 1;
    if (i < pattern.len and pattern[i] == '^') i += 1;
    if (i < pattern.len and pattern[i] == ']') i += 1;
    while (i < pattern.len and pattern[i] != ']') {
        if (pattern[i] == '[' and i + 1 < pattern.len and pattern[i + 1] == ':') {
            if (std.mem.indexOfPos(u8, pattern, i + 2, ":]")) |e| {
                i = e + 2;
                continue;
            }
        }
        i += 1;
    }
    return if (i < pattern.len) i + 1 else pattern.len;
}

const Compiler = struct {
    allocator: Allocator,
    src: []const u8,
    pos: usize = 0,
    icase: bool,
    groups: usize = 0, // ( ... ) seen so far
    prog: std.ArrayListUnmanaged(Inst) = .{},
    sets: std.ArrayListUnmanaged(CharSet) = .{},

    fn emit(self: *Compiler, inst: Inst) Error!void {
        if (self.prog.items.len > 20000) return error.BadRegex;
        try self.prog.append(self.allocator, inst);
    }

    fn peek(self: *Compiler) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn alternation(self: *Compiler, depth: usize) Error!void {
        if (depth > 100) return error.BadRegex;
        const start = self.prog.items.len;
        try self.concatenation(depth);
        if (self.peek() != '|') return;
        // split L1, L2; L1: first; jmp end; L2: rest:
        var jumps: std.ArrayListUnmanaged(usize) = .{};
        defer jumps.deinit(self.allocator);
        var branch_start = start;
        while (self.peek() == '|') {
            self.pos += 1;
            try self.insert(branch_start, .{ .split = .{ .a = 0, .b = 0 } });
            try jumps.append(self.allocator, self.prog.items.len);
            try self.emit(.{ .jmp = 0 });
            const next = self.prog.items.len;
            self.prog.items[branch_start] = .{ .split = .{ .a = @intCast(branch_start + 1), .b = @intCast(next) } };
            branch_start = next;
            try self.concatenation(depth);
        }
        const end: u32 = @intCast(self.prog.items.len);
        for (jumps.items) |j| self.prog.items[j] = .{ .jmp = end };
    }

    fn concatenation(self: *Compiler, depth: usize) Error!void {
        while (self.peek()) |c| {
            if (c == '|' or c == ')') return;
            try self.repetition(depth);
        }
    }

    fn repetition(self: *Compiler, depth: usize) Error!void {
        const start = self.prog.items.len;
        try self.atom(depth);
        while (self.peek()) |c| {
            switch (c) {
                '*' => {
                    self.pos += 1;
                    try self.star(start);
                },
                '+' => {
                    self.pos += 1;
                    try self.emit(.{ .split = .{ .a = @intCast(start), .b = @intCast(self.prog.items.len + 1) } });
                },
                '?' => {
                    self.pos += 1;
                    try self.insert(start, .{ .split = .{ .a = @intCast(start + 1), .b = 0 } });
                    self.prog.items[start].split.b = @intCast(self.prog.items.len);
                },
                '{' => {
                    const saved = self.pos;
                    const bounds = self.interval() orelse {
                        self.pos = saved;
                        return; // a literal {, read by atom next
                    };
                    try self.repeat(start, bounds.min, bounds.max);
                },
                else => return,
            }
        }
    }

    fn star(self: *Compiler, start: usize) Error!void {
        // L: split body, end; body; jmp L:
        try self.insert(start, .{ .split = .{ .a = @intCast(start + 1), .b = 0 } });
        try self.emit(.{ .jmp = @intCast(start) });
        self.prog.items[start].split.b = @intCast(self.prog.items.len);
    }

    const Bounds = struct { min: u32, max: ?u32 };

    fn interval(self: *Compiler) ?Bounds {
        self.pos += 1; // {
        const min = self.number() orelse return null;
        var max: ?u32 = min;
        if (self.peek() == ',') {
            self.pos += 1;
            max = self.number();
        }
        if (self.peek() != '}') return null;
        self.pos += 1;
        if (max) |m| if (m < min) return null;
        if (min > 255 or (max orelse 0) > 255) return null;
        return .{ .min = min, .max = max };
    }

    fn number(self: *Compiler) ?u32 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            self.pos += 1;
        }
        if (self.pos == start) return null;
        return std.fmt.parseInt(u32, self.src[start..self.pos], 10) catch null;
    }

    // x{min,max}: the body copied min times, then optional copies or a star.
    fn repeat(self: *Compiler, start: usize, min: u32, max: ?u32) Error!void {
        const body = try self.allocator.dupe(Inst, self.prog.items[start..]);
        defer self.allocator.free(body);
        self.prog.items.len = start;
        var i: u32 = 0;
        while (i < min) : (i += 1) try self.appendCopy(body, start);
        if (max) |m| {
            while (i < m) : (i += 1) {
                const at = self.prog.items.len;
                try self.emit(.{ .split = .{ .a = @intCast(at + 1), .b = 0 } });
                try self.appendCopy(body, start);
                self.prog.items[at].split.b = @intCast(self.prog.items.len);
            }
        } else {
            const at = self.prog.items.len;
            try self.appendCopy(body, start);
            try self.star(at);
        }
    }

    // Moving their jump targets along.
    fn appendCopy(self: *Compiler, body: []const Inst, origin: usize) Error!void {
        const base: i64 = @intCast(self.prog.items.len);
        const old_base: i64 = @intCast(origin);
        for (body) |inst| {
            var copy = inst;
            switch (copy) {
                .jmp => |*to| to.* = @intCast(@as(i64, to.*) - old_base + base),
                .split => |*s| {
                    s.a = @intCast(@as(i64, s.a) - old_base + base);
                    s.b = @intCast(@as(i64, s.b) - old_base + base);
                },
                else => {},
            }
            try self.emit(copy);
        }
    }

    // Jumps to at reach the new one, jumps within the moved code move too.
    fn insert(self: *Compiler, at: usize, inst: Inst) Error!void {
        try self.prog.insert(self.allocator, at, inst);
        for (self.prog.items, 0..) |*i, index| {
            if (index == at) continue;
            const limit: usize = if (index < at) at + 1 else at;
            switch (i.*) {
                .jmp => |*to| {
                    if (to.* >= limit) to.* += 1;
                },
                .split => |*s| {
                    if (s.a >= limit) s.a += 1;
                    if (s.b >= limit) s.b += 1;
                },
                else => {},
            }
        }
    }

    fn atom(self: *Compiler, depth: usize) Error!void {
        const c = self.peek() orelse return error.BadRegex;
        self.pos += 1;
        switch (c) {
            '(' => {
                self.groups += 1;
                const g = self.groups;
                if (g <= max_groups) try self.emit(.{ .save = @intCast(2 * g - 2) });
                if (self.peek() == ')') {
                    self.pos += 1;
                } else {
                    try self.alternation(depth + 1);
                    if (self.peek() != ')') return error.BadRegex;
                    self.pos += 1;
                }
                if (g <= max_groups) try self.emit(.{ .save = @intCast(2 * g - 1) });
            },
            '.' => try self.emit(.any),
            '^' => try self.emit(.bol),
            '$' => try self.emit(.eol),
            '[' => try self.bracket(),
            '\\' => {
                const e = self.peek() orelse return error.BadRegex;
                self.pos += 1;
                // \s \S white space or not, \w \W word characters or not (GNU):
                switch (e) {
                    's', 'S', 'w', 'W' => {
                        var set = CharSet.initEmpty();
                        _ = addClass(&set, if (e == 's' or e == 'S') "space" else "alnum");
                        if (e == 'w' or e == 'W') set.set('_');
                        if (e == 'S' or e == 'W') set.toggleAll();
                        try self.addSet(set);
                    },
                    else => try self.literal(escapeChar(e)),
                }
            },
            '*', '+', '?' => {
                if (self.prog.items.len == 0) return self.literal(c);
                return error.BadRegex;
            },
            else => try self.literal(c),
        }
    }

    fn literal(self: *Compiler, c: u8) Error!void {
        if (self.icase and std.ascii.isAlphabetic(c)) {
            var set = CharSet.initEmpty();
            set.set(std.ascii.toLower(c));
            set.set(std.ascii.toUpper(c));
            return self.addSet(set);
        }
        try self.emit(.{ .char = c });
    }

    fn addSet(self: *Compiler, set: CharSet) Error!void {
        if (self.sets.items.len >= std.math.maxInt(u16)) return error.BadRegex;
        try self.sets.append(self.allocator, set);
        try self.emit(.{ .set = @intCast(self.sets.items.len - 1) });
    }

    fn bracket(self: *Compiler) Error!void {
        var set = CharSet.initEmpty();
        var negate = false;
        if (self.peek() == '^') {
            negate = true;
            self.pos += 1;
        }
        var first = true;
        while (true) {
            const c = self.peek() orelse return error.BadRegex;
            if (c == ']' and !first) {
                self.pos += 1;
                break;
            }
            first = false;
            if (c == '[' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == ':') {
                const end = std.mem.indexOfPos(u8, self.src, self.pos + 2, ":]") orelse return error.BadRegex;
                const name = self.src[self.pos + 2 .. end];
                if (!addClass(&set, name)) return error.BadRegex;
                self.pos = end + 2;
                continue;
            }
            var lo = c;
            self.pos += 1;
            if (c == '\\' and self.pos < self.src.len) {
                lo = escapeChar(self.src[self.pos]);
                self.pos += 1;
            }
            var hi = lo;
            if (self.peek() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                self.pos += 1;
                hi = self.src[self.pos];
                self.pos += 1;
                if (hi == '\\' and self.pos < self.src.len) {
                    hi = escapeChar(self.src[self.pos]);
                    self.pos += 1;
                }
                if (hi < lo) return error.BadRegex;
            }
            var ch: usize = lo;
            while (ch <= hi) : (ch += 1) {
                set.set(ch);
                if (self.icase) {
                    set.set(std.ascii.toLower(@intCast(ch)));
                    set.set(std.ascii.toUpper(@intCast(ch)));
                }
            }
        }
        if (negate) set.toggleAll();
        try self.addSet(set);
    }
};

fn escapeChar(c: u8) u8 {
    return switch (c) {
        't' => '\t',
        'n' => '\n',
        'r' => '\r',
        'f' => 0x0c,
        'v' => 0x0b,
        'a' => 0x07,
        'b' => 0x08,
        else => c,
    };
}

fn addClass(set: *CharSet, name: []const u8) bool {
    const Pred = *const fn (u8) bool;
    const classes = [_]struct { []const u8, Pred }{
        .{ "alpha", std.ascii.isAlphabetic },
        .{ "digit", std.ascii.isDigit },
        .{ "alnum", std.ascii.isAlphanumeric },
        .{ "upper", std.ascii.isUpper },
        .{ "lower", std.ascii.isLower },
        .{ "space", std.ascii.isWhitespace },
        .{ "punct", isPunct },
        .{ "xdigit", std.ascii.isHex },
        .{ "print", std.ascii.isPrint },
        .{ "cntrl", std.ascii.isControl },
        .{ "blank", isBlank },
        .{ "graph", isGraph },
    };
    for (classes) |class| {
        if (!std.mem.eql(u8, class[0], name)) continue;
        var c: usize = 0;
        while (c < 256) : (c += 1) {
            if (class[1](@intCast(c))) set.set(c);
        }
        return true;
    }
    return false;
}

fn isPunct(c: u8) bool {
    return std.ascii.isPrint(c) and !std.ascii.isAlphanumeric(c) and c != ' ';
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isGraph(c: u8) bool {
    return std.ascii.isPrint(c) and c != ' ';
}
