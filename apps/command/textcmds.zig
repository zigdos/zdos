// FIND, SORT and FINDSTR: the named files or stdin, a line at a time.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const con = @import("term.zig");
const fs = @import("fs.zig");
const vars = @import("vars.zig");

const max_line = 4096; // longer lines are taken in pieces

// "quoted text" is one word, without the quotes.
pub const Words = struct {
    rest: []const u8,
    buf: [fs.max_path + 8]u8 = undefined,

    pub fn next(self: *Words) ?[]const u8 {
        const s = std.mem.trimLeft(u8, self.rest, " \t");
        if (s.len == 0) return null;
        var n: usize = 0;
        var quoted = false;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const c = s[i];
            if (c == '"') {
                quoted = !quoted;
                continue;
            }
            if (!quoted and (c == ' ' or c == '\t')) break;
            if (n < self.buf.len) {
                self.buf[n] = c;
                n += 1;
            }
        }
        self.rest = s[i..];
        return self.buf[0..n];
    }
};

// "-v", "-vn": false if a letter isn't known.
pub fn takeSwitches(word: []const u8, letters: []const u8, flags: []bool, cmd: []const u8) bool {
    for (word[1..]) |c| {
        const i = std.mem.indexOfScalar(u8, letters, std.ascii.toLower(c)) orelse {
            con.printf("{s}: unknown switch -{c}\n", .{ cmd, c });
            vars.errorlevel = 2;
            return false;
        };
        flags[i] = true;
    }
    return true;
}

pub const Lines = struct {
    file: ?zdos.File, // null: the standard input
    buf: [4096]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    eof: bool = false,
    failed: bool = false,
    line: [max_line]u8 = undefined,

    // Without its line end; null at the end or after a printed error
    // (failed is set).
    pub fn next(self: *Lines) ?[]const u8 {
        var n: usize = 0;
        while (true) {
            if (self.start == self.end) {
                if (self.eof) return if (n > 0) self.trimmed(n) else null;
                self.start = 0;
                self.end = if (self.file) |f| f.read(&self.buf) catch |err| {
                    con.printf("Read error: {s}\n", .{fs.message(err)});
                    self.failed = true;
                    self.eof = true;
                    return null;
                } else zdos.readInput(&self.buf);
                if (self.end == 0) self.eof = true;
                continue;
            }
            const c = self.buf[self.start];
            self.start += 1;
            if (c == '\n') return self.trimmed(n);
            self.line[n] = c;
            n += 1;
            if (n == max_line) return self.line[0..n];
        }
    }

    fn trimmed(self: *Lines, n: usize) []const u8 {
        var len = n;
        if (len > 0 and self.line[len - 1] == '\r') len -= 1;
        return self.line[0..len];
    }
};

// Or a message why there is none to read.
fn standardInput(cmd: []const u8) bool {
    if (zdos.inputRedirected()) return true;
    con.printf("{s}: name a file, or give it input: DIR | {s} ..., {s} ... < file\n", .{ cmd, cmd, cmd });
    return false;
}

// Wildcards in the last part; the name as typed ("DOCS\*.TXT" -> "DOCS\A.TXT").
// False after a printed error.
fn eachFile(arg: []const u8, ctx: anytype, comptime each: fn (@TypeOf(ctx), []const u8, zdos.File) void) bool {
    const path = fs.resolve(arg) catch |err| {
        con.printf("{s} - {s}\n", .{ fs.message(err), arg });
        return false;
    };
    if (!fs.hasWildcard(path.name())) {
        const f = zdos.open(path.slice(), .read) catch |err| {
            con.printf("{s} - {s}\n", .{ fs.message(err), arg });
            return false;
        };
        defer f.close();
        each(ctx, arg, f);
        return true;
    }
    // The typed folder part, kept in front of each name found:
    var cut = arg.len;
    while (cut > 0 and arg[cut - 1] != '\\' and arg[cut - 1] != '/') cut -= 1;
    // A drive is one letter: "C:name", not "id:01":
    if (cut == 0 and arg.len >= 2 and arg[1] == ':' and std.ascii.isAlphabetic(arg[0])) cut = 2;
    var shown: [fs.max_path + 8]u8 = undefined;
    @memcpy(shown[0..cut], arg[0..cut]);
    var dir = path;
    dir.pop();
    var names = fs.listMatches(&dir, path.name(), .visible) catch |err| {
        con.printf("{s} - {s}\n", .{ fs.message(err), path.slice() });
        return false;
    };
    defer names.deinit();
    var found = false;
    var it = names.iterator();
    while (it.next()) |name| {
        var full = dir;
        if (!full.append(name)) continue;
        if ((fs.kindOf(&full) catch null) != .file) continue;
        const f = zdos.open(full.slice(), .read) catch continue;
        defer f.close();
        found = true;
        const n = @min(name.len, shown.len - cut);
        @memcpy(shown[cut..][0..n], name[0..n]);
        each(ctx, shown[0 .. cut + n], f);
        if (con.breakRequested()) break;
    }
    if (!found) con.printf("File not found - {s}\n", .{arg});
    return found;
}

// SEARCHING (FIND AND FINDSTR)

const Search = struct {
    cmd: []const u8,
    invert: bool = false, // -v: the lines that don't match
    count: bool = false, // -c: only how many
    numbers: bool = false, // -n
    names_only: bool = false, // -l: only file names
    ignore_case: bool = false, // -i
    many_files: bool = false, // name each line's file (FINDSTR, as grep)
    headers: bool = false, // "---------- FILE" before each file (FIND, as DOS)
    text: []const u8 = "", // FIND
    pattern: ?*const Pattern = null, // FINDSTR
    found: bool = false,

    fn matches(self: *const Search, line: []const u8) bool {
        const hit = if (self.pattern) |p| p.match(line) else if (self.ignore_case)
            std.ascii.indexOfIgnoreCase(line, self.text) != null
        else
            std.mem.indexOf(u8, line, self.text) != null;
        return hit != self.invert;
    }

    // name null: the standard input.
    fn run(self: *Search, name: ?[]const u8, lines: *Lines) void {
        if (self.headers and !self.count) con.printf("\n---------- {s}\n", .{name.?});
        var number: usize = 0;
        var hits: usize = 0;
        while (lines.next()) |line| {
            number += 1;
            if (con.breakRequested()) return;
            if (!self.matches(line)) continue;
            hits += 1;
            if (self.count) continue;
            if (self.names_only) {
                con.printf("{s}\n", .{name orelse "(input)"});
                break;
            }
            if (self.many_files) con.printf("{s}:", .{name.?});
            if (self.numbers) {
                if (self.pattern != null) con.printf("{d}:", .{number}) else con.printf("[{d}]", .{number});
            }
            con.print(line);
            con.print("\n");
        }
        if (hits > 0) self.found = true;
        if (self.count) {
            if (name != null and (self.headers or self.many_files)) {
                if (self.pattern != null) con.printf("{s}:{d}\n", .{ name.?, hits }) else con.printf("---------- {s}: {d}\n", .{ name.?, hits });
            } else con.printf("{d}\n", .{hits});
        }
    }

    fn onFile(self: *Search, name: []const u8, f: zdos.File) void {
        var lines: Lines = .{ .file = f };
        self.run(name, &lines);
    }
};

// Or the standard input.
fn searchAll(s: *Search, w: *Words) void {
    var files: [32][]const u8 = undefined;
    var store: [32][fs.max_path + 8]u8 = undefined;
    var n: usize = 0;
    while (w.next()) |word| {
        if (n == files.len) {
            con.printf("{s}: too many file names\n", .{s.cmd});
            vars.errorlevel = 2;
            return;
        }
        @memcpy(store[n][0..word.len], word);
        files[n] = store[n][0..word.len];
        n += 1;
    }
    var ok = true;
    if (n == 0) {
        if (!standardInput(s.cmd)) {
            vars.errorlevel = 2;
            return;
        }
        var lines: Lines = .{ .file = null };
        s.run(null, &lines);
        ok = !lines.failed;
    } else {
        const wild = for (files[0..n]) |f| {
            if (std.mem.indexOfAny(u8, f, "*?") != null) break true;
        } else false;
        if (s.pattern != null) s.many_files = n > 1 or wild else s.headers = true;
        for (files[0..n]) |f| {
            if (!eachFile(f, s, Search.onFile)) ok = false;
            if (con.breakRequested()) break;
        }
    }
    vars.errorlevel = if (!ok) 2 else if (s.found) 0 else 1;
}

// FIND [-v] [-c] [-n] [-i] "text" [file ...]
pub fn find(args: []const u8) void {
    var s: Search = .{ .cmd = "FIND" };
    var w: Words = .{ .rest = args };
    var flags = [_]bool{false} ** 4;
    var text: [max_line]u8 = undefined;
    while (true) {
        const start = std.mem.trimLeft(u8, w.rest, " \t");
        const word = w.next() orelse {
            con.print("FIND [-v] [-c] [-n] [-i] \"text\" [file ...]\n");
            vars.errorlevel = 2;
            return;
        };
        // -x is a switch; "-x" in quotes is the text:
        if (word.len > 1 and word[0] == '-' and start[0] != '"') {
            if (!takeSwitches(word, "vcni", &flags, "FIND")) return;
            continue;
        }
        @memcpy(text[0..word.len], word);
        s.text = text[0..word.len];
        break;
    }
    s.invert = flags[0];
    s.count = flags[1];
    s.numbers = flags[2];
    s.ignore_case = flags[3];
    searchAll(&s, &w);
}

// FINDSTR [-v] [-c] [-n] [-i] [-l] pattern [file ...]
pub fn findstr(args: []const u8) void {
    var s: Search = .{ .cmd = "FINDSTR" };
    var w: Words = .{ .rest = args };
    var flags = [_]bool{false} ** 5;
    var pattern_text: [max_line]u8 = undefined;
    var pattern_len: usize = 0;
    while (true) {
        const start = std.mem.trimLeft(u8, w.rest, " \t");
        const word = w.next() orelse {
            con.print("FINDSTR [-v] [-c] [-n] [-i] [-l] pattern [file ...]\n");
            vars.errorlevel = 2;
            return;
        };
        if (word.len > 1 and word[0] == '-' and start[0] != '"') {
            if (!takeSwitches(word, "vcnil", &flags, "FINDSTR")) return;
            continue;
        }
        @memcpy(pattern_text[0..word.len], word);
        pattern_len = word.len;
        break;
    }
    s.invert = flags[0];
    s.count = flags[1];
    s.numbers = flags[2];
    s.ignore_case = flags[3];
    s.names_only = flags[4];
    var p: Pattern = .{};
    p.compile(pattern_text[0..pattern_len], s.ignore_case) catch {
        con.print("FINDSTR: bad pattern\n");
        vars.errorlevel = 2;
        return;
    };
    s.pattern = &p;
    searchAll(&s, &w);
}

// SORT [-r] [file]: without case (as in DOS), equal lines keep order.
pub fn sort(args: []const u8) void {
    var w: Words = .{ .rest = args };
    var flags = [_]bool{false};
    var name: ?[]const u8 = null;
    var name_buf: [fs.max_path + 8]u8 = undefined;
    while (w.next()) |word| {
        if (word.len > 1 and word[0] == '-') {
            if (!takeSwitches(word, "r", &flags, "SORT")) return;
        } else if (name == null) {
            @memcpy(name_buf[0..word.len], word);
            name = name_buf[0..word.len];
        } else {
            con.print("SORT [-r] [file]\n");
            vars.errorlevel = 1;
            return;
        }
    }
    vars.errorlevel = 1; // until the lines are out
    var text: fs.Grow(u8) = .{};
    defer text.deinit();
    var ends: fs.Grow(usize) = .{}; // where each line ends in text
    defer ends.deinit();
    const Collect = struct {
        text: *fs.Grow(u8),
        ends: *fs.Grow(usize),
        ok: bool = true,

        fn all(self: *@This(), lines: *Lines) void {
            while (lines.next()) |line| {
                if (con.breakRequested()) {
                    self.ok = false;
                    return;
                }
                if (!self.text.append(line) or !self.ends.append(&.{self.text.len})) {
                    con.print("SORT: not enough memory\n");
                    self.ok = false;
                    return;
                }
            }
            if (lines.failed) self.ok = false;
        }

        fn onFile(self: *@This(), _: []const u8, f: zdos.File) void {
            var lines: Lines = .{ .file = f };
            self.all(&lines);
        }
    };
    var c: Collect = .{ .text = &text, .ends = &ends };
    if (name) |n| {
        if (fs.hasWildcard(n)) {
            con.print("SORT: one file, without wildcards\n");
            return;
        }
        if (!eachFile(n, &c, Collect.onFile)) return;
    } else {
        if (!standardInput("SORT")) return;
        var lines: Lines = .{ .file = null };
        c.all(&lines);
    }
    if (!c.ok) return;

    // Sort line numbers, then print the lines in that order:
    const count = ends.len;
    var order: fs.Grow(u32) = .{};
    defer order.deinit();
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (!order.append(&.{i})) {
            con.print("SORT: not enough memory\n");
            return;
        }
    }
    const Ctx = struct {
        text: []const u8,
        ends: []const usize,
        reverse: bool,

        fn line(self: @This(), n: u32) []const u8 {
            const start = if (n == 0) 0 else self.ends[n - 1];
            return self.text[start..self.ends[n]];
        }

        fn less(self: @This(), a: u32, b: u32) bool {
            const order_ = std.ascii.orderIgnoreCase(self.line(a), self.line(b));
            return if (self.reverse) order_ == .gt else order_ == .lt;
        }
    };
    const ctx: Ctx = .{ .text = text.slice(), .ends = ends.slice(), .reverse = flags[0] };
    std.sort.block(u32, order.slice(), ctx, Ctx.less);
    for (order.slice()) |n| {
        if (con.breakRequested()) return;
        con.print(ctx.line(n));
        con.print("\n");
    }
    vars.errorlevel = 0;
}

// FINDSTR PATTERNS: . [..] [^..] * + ? ^ $ a|b \x, on bytes

const Pattern = struct {
    const max_alts = 8;
    const max_nodes = 64;

    const Quant = enum { one, opt, star, plus };
    const Node = struct {
        set: std.StaticBitSet(256),
        quant: Quant = .one,
    };
    const Alt = struct {
        nodes: [max_nodes]Node = undefined,
        len: usize = 0,
        at_start: bool = false, // ^
        at_end: bool = false, // $
    };

    alts: [max_alts]Alt = undefined,
    count: usize = 0,

    fn compile(self: *Pattern, text: []const u8, ignore_case: bool) error{Bad}!void {
        self.count = 1;
        self.alts[0] = .{};
        var a = &self.alts[0];
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == '|') {
                if (self.count == max_alts) return error.Bad;
                self.alts[self.count] = .{};
                a = &self.alts[self.count];
                self.count += 1;
                i += 1;
                continue;
            }
            if (c == '^' and a.len == 0 and !a.at_start) {
                a.at_start = true;
                i += 1;
                continue;
            }
            if (c == '$' and (i + 1 == text.len or text[i + 1] == '|')) {
                a.at_end = true;
                i += 1;
                continue;
            }
            if ((c == '*' or c == '+' or c == '?') and a.len > 0 and a.nodes[a.len - 1].quant == .one) {
                a.nodes[a.len - 1].quant = switch (c) {
                    '*' => .star,
                    '+' => .plus,
                    else => .opt,
                };
                i += 1;
                continue;
            }
            if (a.len == max_nodes) return error.Bad;
            var set = std.StaticBitSet(256).initEmpty();
            switch (c) {
                '.' => set = std.StaticBitSet(256).initFull(),
                '[' => i = try parseSet(text, i + 1, &set) - 1,
                '\\' => {
                    if (i + 1 == text.len) return error.Bad;
                    i += 1;
                    set.set(text[i]);
                },
                else => set.set(c),
            }
            if (ignore_case) {
                for ('a'..'z' + 1) |l| {
                    const u = l - 'a' + 'A';
                    if (set.isSet(l) or set.isSet(u)) {
                        set.set(l);
                        set.set(u);
                    }
                }
            }
            a.nodes[a.len] = .{ .set = set };
            a.len += 1;
            i += 1;
        }
    }

    // From just after '[': the index just after ']'.
    fn parseSet(text: []const u8, from: usize, set: *std.StaticBitSet(256)) error{Bad}!usize {
        var i = from;
        var negate = false;
        if (i < text.len and text[i] == '^') {
            negate = true;
            i += 1;
        }
        var first = true;
        while (i < text.len and (text[i] != ']' or first)) : (first = false) {
            const lo = text[i];
            if (i + 2 < text.len and text[i + 1] == '-' and text[i + 2] != ']') {
                const hi = text[i + 2];
                if (hi < lo) return error.Bad;
                for (lo..@as(usize, hi) + 1) |ch| set.set(ch);
                i += 3;
            } else {
                set.set(lo);
                i += 1;
            }
        }
        if (i == text.len) return error.Bad; // no ']'
        if (negate) set.toggleAll();
        return i + 1;
    }

    fn match(self: *const Pattern, line: []const u8) bool {
        for (self.alts[0..self.count]) |*a| {
            if (a.at_start) {
                if (matchHere(a, 0, line, 0)) return true;
                continue;
            }
            var start: usize = 0;
            while (start <= line.len) : (start += 1) {
                if (matchHere(a, 0, line, start)) return true;
            }
        }
        return false;
    }

    fn matchHere(a: *const Alt, ni: usize, line: []const u8, pos: usize) bool {
        if (ni == a.len) return !a.at_end or pos == line.len;
        const n = &a.nodes[ni];
        const here = pos < line.len and n.set.isSet(line[pos]);
        switch (n.quant) {
            .one => return here and matchHere(a, ni + 1, line, pos + 1),
            .opt => return (here and matchHere(a, ni + 1, line, pos + 1)) or matchHere(a, ni + 1, line, pos),
            .star, .plus => {
                // As many as there are, then fewer until the rest matches:
                var end = pos;
                while (end < line.len and n.set.isSet(line[end])) end += 1;
                const least: usize = if (n.quant == .plus) 1 else 0;
                while (end >= pos + least) {
                    if (matchHere(a, ni + 1, line, end)) return true;
                    if (end == pos) break;
                    end -= 1;
                }
                return false;
            },
        }
    }
};
