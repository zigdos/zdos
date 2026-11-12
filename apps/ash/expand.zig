// Word expansion, in POSIX order.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const shell_mod = @import("shell.zig");
const parser = @import("parser.zig");

const Allocator = std.mem.Allocator;
const Shell = shell_mod.Shell;

pub const Error = error{ OutOfMemory, BadSubstitution, Unset, Arithmetic };

const quoted_flag: u8 = 1; // came from quotes: no splitting, no patterns
const split_flag: u8 = 2; // came from an unquoted expansion: split at IFS

const Field = struct {
    text: std.ArrayListUnmanaged(u8) = .{},
    flags: std.ArrayListUnmanaged(u8) = .{},
    has_quotes: bool = false,
};

pub const Mode = enum {
    fields, // command words: split, patterns
    string, // assignments, redirections, case words: one string
    pattern, // case patterns, ${x#pattern}: quoted pattern characters escaped
};

const Builder = struct {
    sh: *Shell,
    a: Allocator,
    mode: Mode,
    done: std.ArrayListUnmanaged(Field) = .{},
    cur: Field = .{},

    fn put(self: *Builder, c: u8, flags: u8) Error!void {
        if (self.mode == .pattern and flags & quoted_flag != 0 and isPatternChar(c)) {
            try self.cur.text.append(self.a, '\\');
            try self.cur.flags.append(self.a, flags);
        }
        try self.cur.text.append(self.a, c);
        try self.cur.flags.append(self.a, flags);
    }

    fn putString(self: *Builder, s: []const u8, quoted: bool) Error!void {
        for (s) |c| try self.put(c, if (quoted) quoted_flag else split_flag);
    }

    // "$@": each element its own field.
    fn breakField(self: *Builder) Error!void {
        self.cur.has_quotes = true;
        try self.done.append(self.a, self.cur);
        self.cur = .{ .has_quotes = true };
    }
};

fn isPatternChar(c: u8) bool {
    return c == '*' or c == '?' or c == '[' or c == ']' or c == '\\';
}

// Appended to out.
pub fn fields(sh: *Shell, a: Allocator, raw: []const u8, out: *std.ArrayListUnmanaged([]const u8)) Error!void {
    // "$@" and "${name[@]}" alone: one field per element, none if empty:
    if (wholeList(raw)) |name| {
        const p = try param(sh, a, name, false);
        for (p.values) |v| try out.append(a, v);
        return;
    }
    var b: Builder = .{ .sh = sh, .a = a, .mode = .fields };
    try walk(&b, raw, false, false);
    try b.done.append(a, b.cur);
    for (b.done.items) |*f| try split(sh, a, f, out);
}

// No splitting, no file names.
pub fn string(sh: *Shell, a: Allocator, raw: []const u8) Error![]const u8 {
    var b: Builder = .{ .sh = sh, .a = a, .mode = .string };
    try walk(&b, raw, false, false);
    if (b.done.items.len == 0) return b.cur.text.items;
    // "$@" in a string: the elements joined by spaces:
    var out: std.ArrayListUnmanaged(u8) = .{};
    for (b.done.items) |f| {
        try out.appendSlice(a, f.text.items);
        try out.append(a, ' ');
    }
    try out.appendSlice(a, b.cur.text.items);
    return out.items;
}

// For matchPattern.
pub fn pattern(sh: *Shell, a: Allocator, raw: []const u8) Error![]const u8 {
    var b: Builder = .{ .sh = sh, .a = a, .mode = .pattern };
    try walk(&b, raw, false, false);
    return b.cur.text.items;
}

// $ ` \ work, quotes are plain characters.
pub fn heredoc(sh: *Shell, a: Allocator, body: []const u8) Error![]const u8 {
    var b: Builder = .{ .sh = sh, .a = a, .mode = .string };
    try walk(&b, body, true, true);
    return b.cur.text.items;
}

fn wholeList(raw: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, raw, "\"$@\"") or std.mem.eql(u8, raw, "\"${@}\"")) return "@";
    if (raw.len > 8 and std.mem.startsWith(u8, raw, "\"${") and std.mem.endsWith(u8, raw, "[@]}\"")) {
        const name = raw[3 .. raw.len - 5];
        if (isName(name)) return raw[3 .. raw.len - 2];
    }
    return null;
}

fn isName(text: []const u8) bool {
    return parser.isName(text);
}

// in_dq: inside double quotes; heredoc: quotes are plain characters.
fn walk(b: *Builder, raw: []const u8, in_dq_start: bool, heredoc_text: bool) Error!void {
    var in_dq = in_dq_start;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        const q: u8 = if (in_dq) quoted_flag else 0;
        switch (c) {
            '\'' => if (!in_dq) {
                const close = std.mem.indexOfScalarPos(u8, raw, i + 1, '\'') orelse raw.len;
                for (raw[i + 1 .. close]) |ch| try b.put(ch, quoted_flag);
                b.cur.has_quotes = true;
                i = close + 1;
                continue;
            },
            '"' => if (!heredoc_text) {
                in_dq = !in_dq;
                b.cur.has_quotes = true;
                i += 1;
                continue;
            },
            '\\' => {
                if (i + 1 >= raw.len) {
                    try b.put('\\', q);
                    i += 1;
                    continue;
                }
                const n = raw[i + 1];
                if (n == '\n') {
                    i += 2;
                    continue;
                }
                if (in_dq) {
                    const special = n == '$' or n == '`' or n == '\\' or (n == '"' and !heredoc_text);
                    if (!special) {
                        try b.put('\\', quoted_flag);
                        i += 1;
                        continue;
                    }
                }
                try b.put(n, quoted_flag);
                i += 2;
                continue;
            },
            '$' => {
                i = try dollar(b, raw, i, in_dq);
                continue;
            },
            '`' => {
                var end = i + 1;
                var inner: std.ArrayListUnmanaged(u8) = .{};
                while (end < raw.len and raw[end] != '`') : (end += 1) {
                    if (raw[end] == '\\' and end + 1 < raw.len and (raw[end + 1] == '`' or raw[end + 1] == '$' or raw[end + 1] == '\\')) end += 1;
                    try inner.append(b.a, raw[end]);
                }
                const output = try b.sh.commandSubstitution(b.a, inner.items);
                try b.putString(output, in_dq);
                i = end + 1;
                continue;
            },
            '~' => if (i == 0 and !in_dq and b.mode != .pattern and (raw.len == 1 or raw[1] == '/')) {
                try b.putString(b.sh.getVar("HOME") orelse "~", true);
                i += 1;
                continue;
            },
            else => {},
        }
        try b.put(c, q);
        i += 1;
    }
}

// Returns the index after it.
fn dollar(b: *Builder, raw: []const u8, i: usize, in_dq: bool) Error!usize {
    if (i + 1 >= raw.len) {
        try b.put('$', if (in_dq) quoted_flag else 0);
        return i + 1;
    }
    const n = raw[i + 1];
    if (n == '\'' and !in_dq) {
        // $'...': C-style escapes:
        var j = i + 2;
        while (j < raw.len and raw[j] != '\'') : (j += 1) {
            var c = raw[j];
            if (c == '\\' and j + 1 < raw.len) {
                j += 1;
                c = switch (raw[j]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    'a' => 7,
                    'b' => 8,
                    'e', 'E' => 0x1b,
                    'f' => 0x0c,
                    'v' => 0x0b,
                    '0'...'7' => blk: {
                        var v: u32 = raw[j] - '0';
                        var k: usize = 1;
                        while (k < 3 and j + 1 < raw.len and raw[j + 1] >= '0' and raw[j + 1] <= '7') : (k += 1) {
                            j += 1;
                            v = v * 8 + (raw[j] - '0');
                        }
                        break :blk @truncate(v);
                    },
                    'x' => blk: {
                        var v: u8 = 0;
                        var k: usize = 0;
                        while (k < 2 and j + 1 < raw.len and std.ascii.isHex(raw[j + 1])) : (k += 1) {
                            j += 1;
                            v = v * 16 + (std.fmt.charToDigit(raw[j], 16) catch 0);
                        }
                        break :blk v;
                    },
                    else => raw[j],
                };
            }
            try b.put(c, quoted_flag);
        }
        b.cur.has_quotes = true;
        return j + 1;
    }
    if (n == '(') {
        const arith = i + 2 < raw.len and raw[i + 2] == '(';
        const close = if (arith)
            findClose(raw, i + 1, '(', ')') orelse return error.BadSubstitution
        else
            parser.commandSubstitutionEnd(b.a, raw, i + 2) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BadSubstitution,
            };
        if (arith and close > i + 3 and raw[close - 1] == ')') {
            const value = try arithmetic(b.sh, b.a, raw[i + 3 .. close - 1]);
            try b.putString(try std.fmt.allocPrint(b.a, "{d}", .{value}), in_dq);
        } else {
            const output = try b.sh.commandSubstitution(b.a, raw[i + 2 .. close]);
            try b.putString(output, in_dq);
        }
        return close + 1;
    }
    if (n == '{') {
        const close = findClose(raw, i + 1, '{', '}') orelse return error.BadSubstitution;
        try braced(b, raw[i + 2 .. close], in_dq);
        return close + 1;
    }
    var end = i + 1;
    if (std.ascii.isAlphabetic(n) or n == '_') {
        while (end < raw.len and (std.ascii.isAlphanumeric(raw[end]) or raw[end] == '_')) end += 1;
    } else if (std.ascii.isDigit(n) or std.mem.indexOfScalar(u8, "@*#?$!-", n) != null) {
        end += 1;
    } else {
        try b.put('$', if (in_dq) quoted_flag else 0);
        return i + 1;
    }
    const name = raw[i + 1 .. end];
    const p = try param(b.sh, b.a, name, true);
    try putParam(b, p, name, in_dq);
    return end;
}

fn putParam(b: *Builder, p: Param, name: []const u8, in_dq: bool) Error!void {
    if (p.list and in_dq and (name[0] == '@' or std.mem.endsWith(u8, name, "[@]"))) {
        for (p.values, 0..) |v, k| {
            if (k > 0) try b.breakField();
            try b.putString(v, true);
        }
        return;
    }
    if (p.list) {
        const sep: []const u8 = if (in_dq) ifsFirst(b.sh) else " ";
        for (p.values, 0..) |v, k| {
            if (k > 0) try b.putString(sep, in_dq);
            try b.putString(v, in_dq);
        }
        return;
    }
    if (p.values.len > 0) try b.putString(p.values[0], in_dq);
}

fn ifsFirst(sh: *Shell) []const u8 {
    const ifs = sh.getVar("IFS") orelse return " ";
    return if (ifs.len > 0) ifs[0..1] else "";
}

// Skipping quotes and nesting.
pub fn findClose(text: []const u8, open_at: usize, open: u8, close: u8) ?usize {
    var depth: usize = 0;
    var i = open_at;
    while (i < text.len) {
        const c = text[i];
        if (c == open) {
            depth += 1;
        } else if (c == close) {
            depth -= 1;
            if (depth == 0) return i;
        } else switch (c) {
            '\\' => i += 1,
            '\'' => i = std.mem.indexOfScalarPos(u8, text, i + 1, '\'') orelse return null,
            '"' => {
                i += 1;
                while (i < text.len and text[i] != '"') : (i += 1) {
                    if (text[i] == '\\') i += 1;
                }
                if (i >= text.len) return null;
            },
            '`' => i = std.mem.indexOfScalarPos(u8, text, i + 1, '`') orelse return null,
            else => {},
        }
        i += 1;
    }
    return null;
}

const Param = struct {
    set: bool, // the variable exists (an empty array counts as set)
    values: []const []const u8,
    list: bool = false, // $@ $* ${a[@]} ${a[*]}
};

// $name / ${name} / ${name[index]}
fn param(sh: *Shell, a: Allocator, name: []const u8, check_unset: bool) Error!Param {
    const p = try paramValue(sh, a, name);
    if (check_unset and !p.set and sh.opts.nounset and name[0] != '@' and name[0] != '*') {
        errout.printf("ash: {s}: parameter not set\n", .{name});
        return error.Unset;
    }
    return p;
}

fn paramValue(sh: *Shell, a: Allocator, name: []const u8) Error!Param {
    const one = struct {
        fn of(a2: Allocator, v: []const u8) Error!Param {
            const list = try a2.alloc([]const u8, 1);
            list[0] = v;
            return .{ .set = true, .values = list };
        }
    }.of;
    switch (name[0]) {
        '@', '*' => return .{ .set = true, .values = sh.args, .list = true },
        '#' => return one(a, try std.fmt.allocPrint(a, "{d}", .{sh.args.len})),
        '?' => return one(a, try std.fmt.allocPrint(a, "{d}", .{sh.status})),
        '$' => return one(a, "1"),
        '!' => return one(a, if (sh.last_background) |id| try std.fmt.allocPrint(a, "{d}", .{id}) else ""),
        '-' => return one(a, try sh.optionLetters(a)),
        '0'...'9' => {
            const n = std.fmt.parseInt(usize, name, 10) catch return error.BadSubstitution;
            if (n == 0) return one(a, sh.zero);
            if (n > sh.args.len) return .{ .set = false, .values = &.{} };
            return one(a, sh.args[n - 1]);
        },
        else => {},
    }
    var base = name;
    var index: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, name, '[')) |open| {
        if (name[name.len - 1] != ']') return error.BadSubstitution;
        base = name[0..open];
        index = name[open + 1 .. name.len - 1];
    }
    if (!isName(base)) return error.BadSubstitution;
    const v = sh.vars.getPtr(base) orelse return .{ .set = false, .values = &.{} };
    const items: []const []const u8 = @ptrCast(v.values.items);
    if (index) |idx| {
        if (std.mem.eql(u8, idx, "@") or std.mem.eql(u8, idx, "*")) return .{ .set = true, .values = items, .list = true };
        const k = try arithmetic(sh, a, idx);
        if (k < 0 or k >= items.len) return .{ .set = false, .values = &.{} };
        return one(a, items[@intCast(k)]);
    }
    if (items.len == 0) return .{ .set = v.array, .values = &.{} };
    return one(a, items[0]);
}

fn braced(b: *Builder, inner: []const u8, in_dq: bool) Error!void {
    const sh = b.sh;
    const a = b.a;
    if (inner.len == 0) return error.BadSubstitution;
    // ${#name}: the length; ${#name[@]}: the number of elements:
    if (inner[0] == '#' and inner.len > 1) {
        const name = inner[1..];
        const p = try param(sh, a, name, true);
        const n = if (p.list) p.values.len else if (p.values.len > 0) p.values[0].len else 0;
        try b.putString(try std.fmt.allocPrint(a, "{d}", .{n}), in_dq);
        return;
    }
    // An identifier (maybe with [index]), digits, or one character:
    var end: usize = 0;
    if (std.ascii.isAlphabetic(inner[0]) or inner[0] == '_') {
        while (end < inner.len and (std.ascii.isAlphanumeric(inner[end]) or inner[end] == '_')) end += 1;
        if (end < inner.len and inner[end] == '[') {
            const close = std.mem.indexOfScalarPos(u8, inner, end, ']') orelse return error.BadSubstitution;
            end = close + 1;
        }
    } else if (std.ascii.isDigit(inner[0])) {
        while (end < inner.len and std.ascii.isDigit(inner[end])) end += 1;
    } else if (std.mem.indexOfScalar(u8, "@*#?$!-", inner[0]) != null) {
        end = 1;
    } else return error.BadSubstitution;
    const name = inner[0..end];
    const rest = inner[end..];
    if (rest.len == 0) {
        const p = try param(sh, a, name, true);
        return putParam(b, p, name, in_dq);
    }

    const p = try param(sh, a, name, false);
    const colon = rest[0] == ':' and rest.len > 1 and std.mem.indexOfScalar(u8, "-=+?", rest[1]) != null;
    const op_at: usize = if (colon) 1 else 0;
    const op = rest[op_at];
    const word = rest[op_at + 1 ..];
    const empty = !p.set or (colon and (p.values.len == 0 or (!p.list and p.values[0].len == 0)));
    switch (op) {
        '-' => if (empty) try walk(b, word, in_dq, false) else try putParam(b, p, name, in_dq),
        '+' => if (!empty) try walk(b, word, in_dq, false),
        '=' => {
            if (empty) {
                if (!isName(name)) return error.BadSubstitution;
                const value = try string(sh, a, word);
                sh.setVar(name, value) catch return error.OutOfMemory;
                try b.putString(value, in_dq);
            } else try putParam(b, p, name, in_dq);
        },
        '?' => {
            if (empty) {
                const message = if (word.len > 0) try string(sh, a, word) else "parameter not set";
                errout.printf("ash: {s}: {s}\n", .{ name, message });
                return error.Unset;
            }
            try putParam(b, p, name, in_dq);
        },
        '#', '%' => {
            const longest = word.len > 0 and word[0] == op;
            const pat = try pattern(sh, a, if (longest) word[1..] else word);
            const values = try a.alloc([]const u8, p.values.len);
            for (p.values, 0..) |v, k| values[k] = trim(v, pat, op == '#', longest);
            try putParam(b, .{ .set = p.set, .values = values, .list = p.list }, name, in_dq);
        },
        '/' => {
            var spec = word;
            var all = false;
            var anchor: u8 = 0;
            if (spec.len > 0 and (spec[0] == '/' or spec[0] == '#' or spec[0] == '%')) {
                if (spec[0] == '/') all = true else anchor = spec[0];
                spec = spec[1..];
            }
            const slash = unquotedSlash(spec);
            const pat = try pattern(sh, a, spec[0 .. slash orelse spec.len]);
            const rep = if (slash) |s| try string(sh, a, spec[s + 1 ..]) else "";
            const values = try a.alloc([]const u8, p.values.len);
            for (p.values, 0..) |v, k| values[k] = try replace(a, v, pat, rep, all, anchor);
            try putParam(b, .{ .set = p.set, .values = values, .list = p.list }, name, in_dq);
        },
        ':' => {
            // ${name:offset} ${name:offset:length}:
            const second = std.mem.indexOfScalar(u8, word, ':');
            var offset = try arithmetic(sh, a, word[0 .. second orelse word.len]);
            const v = if (p.values.len > 0) p.values[0] else "";
            const len: i64 = @intCast(v.len);
            if (offset < 0) offset = @max(0, len + offset);
            if (offset > len) offset = len;
            var count = len - offset;
            if (second) |s| {
                count = try arithmetic(sh, a, word[s + 1 ..]);
                if (count < 0) count = @max(0, len - offset + count);
                count = @min(count, len - offset);
            }
            const start: usize = @intCast(offset);
            try b.putString(v[start .. start + @as(usize, @intCast(count))], in_dq);
        },
        else => return error.BadSubstitution,
    }
}

fn unquotedSlash(text: []const u8) ?usize {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '\\' => i += 1,
            '/' => return i,
            else => {},
        }
    }
    return null;
}

// ${v#p} ${v##p} ${v%p} ${v%%p}
fn trim(v: []const u8, pat: []const u8, prefix: bool, longest: bool) []const u8 {
    if (prefix) {
        if (longest) {
            var k = v.len + 1;
            while (k > 0) {
                k -= 1;
                if (matchPattern(pat, v[0..k], false)) return v[k..];
            }
        } else {
            for (0..v.len + 1) |k| if (matchPattern(pat, v[0..k], false)) return v[k..];
        }
    } else {
        if (longest) {
            for (0..v.len + 1) |k| if (matchPattern(pat, v[k..], false)) return v[0..k];
        } else {
            var k = v.len + 1;
            while (k > 0) {
                k -= 1;
                if (matchPattern(pat, v[k..], false)) return v[0..k];
            }
        }
    }
    return v;
}

// ${v/p/r} ${v//p/r} ${v/#p/r} ${v/%p/r}: the longest match at the
// first (or every) place.
fn replace(a: Allocator, v: []const u8, pat: []const u8, rep: []const u8, all: bool, anchor: u8) Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    var i: usize = 0;
    var replaced = false;
    while (i < v.len) {
        if ((anchor == '#' and i > 0) or (replaced and !all)) break;
        var end = v.len;
        const found: ?usize = while (end > i) : (end -= 1) {
            if (matchPattern(pat, v[i..end], false)) break end;
            if (anchor == '%') break null;
        } else null;
        if (found) |e| {
            try out.appendSlice(a, rep);
            replaced = true;
            i = e;
        } else {
            try out.append(a, v[i]);
            i += 1;
        }
    }
    try out.appendSlice(a, v[i..]);
    return out.items;
}

// FIELD SPLITTING AND FILE NAME PATTERNS

fn split(sh: *Shell, a: Allocator, f: *const Field, out: *std.ArrayListUnmanaged([]const u8)) Error!void {
    const ifs = sh.getVar("IFS") orelse " \t\n";
    var word: Field = .{};
    var has_content = false;
    var produced = false;
    for (f.text.items, f.flags.items) |c, flags| {
        if (flags & split_flag != 0 and std.mem.indexOfScalar(u8, ifs, c) != null) {
            const white = c == ' ' or c == '\t' or c == '\n';
            if (has_content or !white) {
                try finishWord(sh, a, &word, out);
                produced = true;
            }
            word = .{};
            has_content = false;
            continue;
        }
        try word.text.append(a, c);
        try word.flags.append(a, flags);
        has_content = true;
    }
    if (has_content or (f.has_quotes and !produced)) try finishWord(sh, a, &word, out);
}

fn finishWord(sh: *Shell, a: Allocator, w: *const Field, out: *std.ArrayListUnmanaged([]const u8)) Error!void {
    var active = false;
    for (w.text.items, w.flags.items, 0..) |c, flags, i| {
        if (flags & quoted_flag != 0) continue;
        if (c == '*' or c == '?' or (c == '[' and bracketCloses(w.text.items, w.flags.items, i))) active = true;
    }
    if (!active or sh.opts.noglob) {
        try out.append(a, w.text.items);
        return;
    }
    var pat: std.ArrayListUnmanaged(u8) = .{};
    for (w.text.items, w.flags.items) |c, flags| {
        if (flags & quoted_flag != 0 and isPatternChar(c)) try pat.append(a, '\\');
        try pat.append(a, c);
    }
    const start = out.items.len;
    try glob(a, pat.items, out);
    if (out.items.len == start) {
        try out.append(a, w.text.items);
    } else {
        std.sort.heap([]const u8, out.items[start..], {}, lessIgnoreCase);
    }
}

// Only when an unquoted ']' closes it in the same path part, so "["
// alone, the test command, is a word. A ']' right after '[', '[!' or
// '[^' is a member.
fn bracketCloses(text: []const u8, flags: []const u8, open: usize) bool {
    var j = open + 1;
    if (j < text.len and (text[j] == '!' or text[j] == '^')) j += 1;
    if (j < text.len and text[j] == ']') j += 1;
    while (j < text.len) : (j += 1) {
        if (text[j] == '/') return false;
        if (text[j] == ']' and flags[j] & quoted_flag == 0) return true;
    }
    return false;
}

fn lessIgnoreCase(_: void, x: []const u8, y: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(x, y);
}

// Folder by folder.
fn glob(a: Allocator, pat: []const u8, out: *std.ArrayListUnmanaged([]const u8)) Error!void {
    var parts: std.ArrayListUnmanaged([]const u8) = .{};
    var start: usize = 0;
    var i: usize = 0;
    while (i < pat.len) : (i += 1) {
        if (pat[i] == '\\') {
            i += 1;
        } else if (pat[i] == '/') {
            try parts.append(a, pat[start..i]);
            start = i + 1;
        }
    }
    try parts.append(a, pat[start..]);
    try globFrom(a, "", parts.items, out);
}

fn hasMeta(part: []const u8) bool {
    var i: usize = 0;
    while (i < part.len) : (i += 1) {
        switch (part[i]) {
            '\\' => i += 1,
            '*', '?' => return true,
            '[' => if (escapedBracketCloses(part, i)) return true,
            else => {},
        }
    }
    return false;
}

// Where '\' quotes the next character.
fn escapedBracketCloses(part: []const u8, open: usize) bool {
    var j = open + 1;
    if (j < part.len and (part[j] == '!' or part[j] == '^')) j += 1;
    if (j < part.len and part[j] == ']') j += 1;
    while (j < part.len) : (j += 1) {
        if (part[j] == '\\') {
            j += 1;
            continue;
        }
        if (part[j] == ']') return true;
    }
    return false;
}

fn unescape(a: Allocator, part: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, part, '\\') == null) return part;
    var out: std.ArrayListUnmanaged(u8) = .{};
    var i: usize = 0;
    while (i < part.len) : (i += 1) {
        if (part[i] == '\\' and i + 1 < part.len) i += 1;
        try out.append(a, part[i]);
    }
    return out.items;
}

fn join(a: Allocator, prefix: []const u8, name: []const u8, first: bool) Error![]const u8 {
    if (first) return a.dupe(u8, name);
    if (prefix.len > 0 and prefix[prefix.len - 1] == '/') return std.fmt.allocPrint(a, "{s}{s}", .{ prefix, name });
    return std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, name });
}

fn globFrom(a: Allocator, prefix: []const u8, parts: []const []const u8, out: *std.ArrayListUnmanaged([]const u8)) Error!void {
    var path = prefix;
    var first = prefix.len == 0;
    var k: usize = 0;
    // Plain parts are taken as they are:
    while (k < parts.len and !hasMeta(parts[k])) : (k += 1) {
        const name = try unescape(a, parts[k]);
        path = if (first and name.len == 0) "/" else try join(a, path, name, first);
        first = false;
    }
    if (k == parts.len) {
        _ = zdos.stat(path) catch return;
        try out.append(a, path);
        return;
    }
    const part = parts[k];
    const dir = zdos.openDir(if (first) "." else path) catch return;
    defer dir.close();
    var entry: zdos.DirEntry = undefined;
    while (dir.next(&entry) catch false) {
        const name = entry.name();
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (name[0] == '.' and part[0] != '.') continue;
        if (!matchPattern(part, name, false)) continue; // case counts, as in POSIX
        if (k + 1 < parts.len and !entry.is_dir) continue;
        const next = try join(a, path, name, first);
        if (k + 1 == parts.len) {
            try out.append(a, next);
        } else {
            try globFrom(a, next, parts[k + 1 ..], out);
        }
    }
}

// * ? [abc] [!a-z] [^a-z], \ quotes the next character.
pub fn matchPattern(pat: []const u8, text: []const u8, icase: bool) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star_p: ?usize = null;
    var star_t: usize = 0;
    while (t < text.len) {
        if (p < pat.len) {
            switch (pat[p]) {
                '*' => {
                    star_p = p;
                    star_t = t;
                    p += 1;
                    continue;
                },
                '?' => {
                    p += 1;
                    t += 1;
                    continue;
                },
                '[' => if (bracket(pat, p, text[t], icase)) |r| {
                    if (r.matched) {
                        p = r.next;
                        t += 1;
                        continue;
                    }
                } else if (same(pat[p], text[t], icase)) {
                    p += 1;
                    t += 1;
                    continue;
                },
                '\\' => if (p + 1 < pat.len and same(pat[p + 1], text[t], icase)) {
                    p += 2;
                    t += 1;
                    continue;
                },
                else => if (same(pat[p], text[t], icase)) {
                    p += 1;
                    t += 1;
                    continue;
                },
            }
        }
        if (star_p) |sp| {
            p = sp + 1;
            star_t += 1;
            t = star_t;
            continue;
        }
        return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

fn same(x: u8, y: u8, icase: bool) bool {
    return if (icase) std.ascii.toLower(x) == std.ascii.toLower(y) else x == y;
}

const BracketResult = struct { matched: bool, next: usize };

// Null if it isn't a complete bracket expression.
fn bracket(pat: []const u8, at: usize, c: u8, icase: bool) ?BracketResult {
    var i = at + 1;
    var negate = false;
    if (i < pat.len and (pat[i] == '!' or pat[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < pat.len) {
        if (pat[i] == ']' and !first) return .{ .matched = matched != negate, .next = i + 1 };
        first = false;
        var lo = pat[i];
        if (lo == '\\' and i + 1 < pat.len) {
            i += 1;
            lo = pat[i];
        }
        i += 1;
        var hi = lo;
        if (i + 1 < pat.len and pat[i] == '-' and pat[i + 1] != ']') {
            hi = pat[i + 1];
            i += 2;
        }
        const x = if (icase) std.ascii.toLower(c) else c;
        if ((c >= lo and c <= hi) or (icase and x >= std.ascii.toLower(lo) and x <= std.ascii.toLower(hi))) matched = true;
    }
    return null;
}

// ARITHMETIC

pub fn arithmetic(sh: *Shell, a: Allocator, raw: []const u8) Error!i64 {
    const text = try string(sh, a, raw);
    var p: Arith = .{ .sh = sh, .a = a, .text = text };
    const value = p.assignment() catch |err| return arithError(text, err);
    p.skip();
    if (p.i != p.text.len) return arithError(text, error.Arithmetic);
    return value;
}

// Of the last $((...)): division by zero or the syntax.
var arith_problem: []const u8 = "syntax error";

fn arithError(text: []const u8, err: Error) Error {
    if (err == error.Arithmetic) errout.printf("ash: arithmetic: {s}: {s}\n", .{ arith_problem, text });
    arith_problem = "syntax error";
    return err;
}

const Arith = struct {
    sh: *Shell,
    a: Allocator,
    text: []const u8,
    i: usize = 0,
    depth: u32 = 0,

    fn skip(self: *Arith) void {
        while (self.i < self.text.len and std.ascii.isWhitespace(self.text[self.i])) self.i += 1;
    }

    fn eat(self: *Arith, op: []const u8) bool {
        self.skip();
        if (!std.mem.startsWith(u8, self.text[self.i..], op)) return false;
        // Don't take < out of <= or <<, & out of &&, and so on:
        const after = self.i + op.len;
        if (op.len == 1 and after < self.text.len) {
            const n = self.text[after];
            if ((op[0] == '<' or op[0] == '>') and (n == '=' or n == op[0])) return false;
            if ((op[0] == '&' or op[0] == '|') and n == op[0]) return false;
            if (op[0] == '=' and n == '=') return false;
            if (op[0] == '!' and n == '=') return false;
            if (std.mem.indexOfScalar(u8, "+-*/%&|^", op[0]) != null and n == '=') return false;
        }
        if (op.len == 2 and (std.mem.eql(u8, op, "<<") or std.mem.eql(u8, op, ">>")) and after < self.text.len and self.text[after] == '=') return false;
        self.i = after;
        return true;
    }

    fn assignment(self: *Arith) Error!i64 {
        self.skip();
        const save = self.i;
        if (self.name()) |n| {
            const ops = [_][]const u8{ "=", "+=", "-=", "*=", "/=", "%=" };
            for (ops) |op| {
                if (self.eat(op)) {
                    const rhs = try self.assignment();
                    const old = try self.variable(n);
                    const value: i64 = switch (op[0]) {
                        '=' => rhs,
                        '+' => old +% rhs,
                        '-' => old -% rhs,
                        '*' => old *% rhs,
                        else => try divide(old, rhs, op[0]),
                    };
                    try self.store(n, value);
                    return value;
                }
            }
        }
        self.i = save;
        return self.ternary();
    }

    fn ternary(self: *Arith) Error!i64 {
        const c = try self.binary(0);
        if (!self.eat("?")) return c;
        const x = try self.assignment();
        if (!self.eat(":")) return error.Arithmetic;
        const y = try self.assignment();
        return if (c != 0) x else y;
    }

    const levels = [_][]const []const u8{
        &.{"||"},
        &.{"&&"},
        &.{"|"},
        &.{"^"},
        &.{"&"},
        &.{ "==", "!=" },
        &.{ "<=", ">=", "<", ">" },
        &.{ "<<", ">>" },
        &.{ "+", "-" },
        &.{ "*", "/", "%" },
    };

    fn binary(self: *Arith, level: usize) Error!i64 {
        if (level == levels.len) return self.unary();
        var x = try self.binary(level + 1);
        outer: while (true) {
            for (levels[level]) |op| {
                if (!self.eat(op)) continue;
                const y = try self.binary(level + 1);
                x = switch (op[0]) {
                    '|' => if (op.len == 2) @intFromBool(x != 0 or y != 0) else x | y,
                    '&' => if (op.len == 2) @intFromBool(x != 0 and y != 0) else x & y,
                    '^' => x ^ y,
                    '=' => @intFromBool(x == y),
                    '!' => @intFromBool(x != y),
                    '<' => if (op.len == 1) @intFromBool(x < y) else if (op[1] == '=') @intFromBool(x <= y) else x << @intCast(@min(@max(y, 0), 63)),
                    '>' => if (op.len == 1) @intFromBool(x > y) else if (op[1] == '=') @intFromBool(x >= y) else x >> @intCast(@min(@max(y, 0), 63)),
                    '+' => x +% y,
                    '-' => x -% y,
                    '*' => x *% y,
                    else => try divide(x, y, op[0]),
                };
                continue :outer;
            }
            return x;
        }
    }

    fn unary(self: *Arith) Error!i64 {
        if (self.eat("++") or self.eat("--")) {
            const inc: i64 = if (self.text[self.i - 1] == '+') 1 else -1;
            self.skip();
            const n = self.name() orelse return error.Arithmetic;
            const value = (try self.variable(n)) +% inc;
            try self.store(n, value);
            return value;
        }
        if (self.eat("-")) return 0 -% try self.unary();
        if (self.eat("+")) return self.unary();
        if (self.eat("!")) return @intFromBool(try self.unary() == 0);
        if (self.eat("~")) return ~try self.unary();
        return self.primary();
    }

    fn primary(self: *Arith) Error!i64 {
        self.skip();
        if (self.eat("(")) {
            const v = try self.assignment();
            if (!self.eat(")")) return error.Arithmetic;
            return v;
        }
        if (self.name()) |n| {
            const value = try self.variable(n);
            if (self.eat("++") or self.eat("--")) {
                try self.store(n, value +% @as(i64, if (self.text[self.i - 1] == '+') 1 else -1));
            }
            return value;
        }
        const start = self.i;
        while (self.i < self.text.len and std.ascii.isAlphanumeric(self.text[self.i])) self.i += 1;
        if (self.i == start) return error.Arithmetic;
        return parseNumber(self.text[start..self.i]) orelse error.Arithmetic;
    }

    fn name(self: *Arith) ?[]const u8 {
        const start = self.i;
        if (start >= self.text.len or !(std.ascii.isAlphabetic(self.text[start]) or self.text[start] == '_')) return null;
        var end = start;
        while (end < self.text.len and (std.ascii.isAlphanumeric(self.text[end]) or self.text[end] == '_')) end += 1;
        self.i = end;
        return self.text[start..end];
    }

    fn variable(self: *Arith, n: []const u8) Error!i64 {
        const value = self.sh.getVar(n) orelse return 0;
        const trimmed = std.mem.trim(u8, value, " \t\n");
        if (trimmed.len == 0) return 0;
        if (parseNumber(trimmed)) |v| return v;
        // A variable holding an expression:
        if (self.depth > 20) return error.Arithmetic;
        var inner: Arith = .{ .sh = self.sh, .a = self.a, .text = trimmed, .depth = self.depth + 1 };
        const v = try inner.assignment();
        inner.skip();
        if (inner.i != inner.text.len) return error.Arithmetic;
        return v;
    }

    fn store(self: *Arith, n: []const u8, value: i64) Error!void {
        var buf: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
        self.sh.setVar(n, text) catch return error.OutOfMemory;
    }
};

fn divide(x: i64, y: i64, op: u8) Error!i64 {
    if (y == 0) {
        arith_problem = "division by zero";
        return error.Arithmetic;
    }
    if (x == std.math.minInt(i64) and y == -1) return if (op == '/') x else 0;
    return if (op == '/') @divTrunc(x, y) else @rem(x, y);
}

// 42, 0x2A, 052
pub fn parseNumber(text: []const u8) ?i64 {
    if (text.len > 1 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X'))
        return std.fmt.parseInt(i64, text[2..], 16) catch null;
    if (text.len > 1 and text[0] == '0') return std.fmt.parseInt(i64, text[1..], 8) catch null;
    return std.fmt.parseInt(i64, text, 10) catch null;
}
