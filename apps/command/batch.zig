// Batch files and IF / FOR / SET. The whole file is parsed first;
// variables are expanded when a command runs, so in a FOR or IF block
// %X% is always the current value.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const sys = @import("../zdos/system.zig");
const con = @import("term.zig");
const fs = @import("fs.zig");
const vars = @import("vars.zig");
const shell = @import("shell.zig");
const lineedit = @import("lineedit.zig");

const line_max = 1024; // after expanding variables
const max_nested = 16; // batch files started from batch files
// Parsing and running go one level deeper in the call stack for each
// nested IF / FOR, so the depth is limited where the file is read.
const max_blocks = 64;
const max_file = 256 * 1024;

pub var echo_on = true; // ECHO ON / OFF
var depth: usize = 0; // batch files running
var aborting = false; // Ctrl+C answered with Y: stop all batch files

// MEMORY FOR ONE PARSE

const Arena = struct {
    first: ?*Chunk = null,

    const Chunk = struct {
        next: ?*Chunk,
        used: usize,
        cap: usize,
    };
    const header = std.mem.alignForward(usize, @sizeOf(Chunk), 16);

    fn alloc(self: *Arena, comptime T: type, n: usize) ?[]T {
        const bytes = n * @sizeOf(T);
        const al = @alignOf(T);
        if (self.first) |c| {
            const start = std.mem.alignForward(usize, c.used, al);
            if (start + bytes <= c.cap) {
                c.used = start + bytes;
                const base: [*]u8 = @ptrCast(c);
                return @as([*]T, @ptrCast(@alignCast(base + header + start)))[0..n];
            }
        }
        const cap = @max(16 * 1024, bytes + al);
        const mem = zdos.alloc(header + cap) orelse return null;
        const c: *Chunk = @ptrCast(@alignCast(mem));
        c.* = .{ .next = self.first, .used = bytes, .cap = cap };
        self.first = c;
        return @as([*]T, @ptrCast(@alignCast(mem + header)))[0..n];
    }

    fn deinit(self: *Arena) void {
        var c = self.first;
        while (c) |chunk| {
            c = chunk.next;
            zdos.free(@ptrCast(@alignCast(chunk)));
        }
        self.first = null;
    }
};

// WHAT A BATCH FILE IS MADE OF

const Node = union(enum) {
    command: struct { text: []const u8, quiet: bool },
    if_: *If,
    for_: *For,
};

const Cond = struct {
    negate: bool = false,
    ignore_case: bool = false,
    kind: union(enum) {
        exist: []const u8,
        compare: struct { left: []const u8, right: []const u8, op: CompareOp },
        errorlevel: []const u8,
        defined: []const u8,
    } = .{ .exist = "" },
};

const CompareOp = enum { equal, not_equal, less, less_equal, greater, greater_equal };

const If = struct {
    cond: Cond,
    then: []Node,
    else_: []Node = &.{},
};

const For = struct {
    var_name: u8, // 0: FOR DO, endless
    numeric: bool = false, // FOR -L: the list is from,step,to
    lines: bool = false, // FOR -f: the list is files, 'command' or "text"
    list: []const u8 = "",
    body: []Node = &.{},
};

const NodeList = struct {
    items: []Node = &.{},
    len: usize = 0,

    fn append(self: *NodeList, arena: *Arena, n: Node) bool {
        if (self.len == self.items.len) {
            const new = arena.alloc(Node, @max(8, self.items.len * 2)) orelse return false;
            @memcpy(new[0..self.len], self.items[0..self.len]);
            self.items = new;
        }
        self.items[self.len] = n;
        self.len += 1;
        return true;
    }

    fn slice(self: *const NodeList) []Node {
        return self.items[0..self.len];
    }
};

// PARSING

const blanks = " \t";

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, blanks);
}

// Up to a blank or '('.
fn startsWithWord(s: []const u8, word: []const u8) bool {
    if (s.len < word.len or !std.ascii.eqlIgnoreCase(s[0..word.len], word)) return false;
    return s.len == word.len or s[word.len] == ' ' or s[word.len] == '\t' or s[word.len] == '(';
}

fn firstWord(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and s[i] != ' ' and s[i] != '\t') : (i += 1) {}
    return s[0..i];
}

// If it is on this line.
fn matchParen(s: []const u8) ?usize {
    var level: usize = 0;
    var quoted = false;
    for (s, 0..) |c, i| {
        if (c == '"') quoted = !quoted;
        if (quoted) continue;
        if (c == '(') level += 1;
        if (c == ')') {
            level -= 1;
            if (level == 0) return i;
        }
    }
    return null;
}

// " ELSE " as a word, outside quotes and parentheses.
fn findElse(s: []const u8) ?usize {
    var level: usize = 0;
    var quoted = false;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '"') quoted = !quoted;
        if (quoted) continue;
        if (c == '(') level += 1;
        if (c == ')' and level > 0) level -= 1;
        if (level == 0 and i > 0 and (s[i - 1] == ' ' or s[i - 1] == '\t') and startsWithWord(s[i..], "ELSE")) return i;
    }
    return null;
}

// "quoted text" or a word ending at a blank, or at '=' for ==.
fn takeOperand(s: []const u8, stop_at_eq: bool) struct { op: []const u8, rest: []const u8 } {
    if (s.len > 0 and s[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, s, 1, '"') orelse s.len - 1;
        return .{ .op = s[0 .. close + 1], .rest = s[close + 1 ..] };
    }
    var i: usize = 0;
    while (i < s.len and s[i] != ' ' and s[i] != '\t' and !(stop_at_eq and s[i] == '=')) : (i += 1) {}
    return .{ .op = s[0..i], .rest = s[i..] };
}

const ParsedCompare = struct { op: CompareOp, rest: []const u8 };

fn takeCompareOperand(s: []const u8) struct { op: []const u8, rest: []const u8 } {
    if (s.len > 0 and s[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, s, 1, '"') orelse s.len - 1;
        return .{ .op = s[0 .. close + 1], .rest = s[close + 1 ..] };
    }
    var i: usize = 0;
    while (i < s.len and s[i] != ' ' and s[i] != '\t') : (i += 1) {
        const c = s[i];
        if (c == '<' or c == '>') break;
        if ((c == '=' or c == '!') and i + 1 < s.len and s[i + 1] == '=') break;
    }
    return .{ .op = s[0..i], .rest = s[i..] };
}

fn parseCompareOp(s: []const u8) ?ParsedCompare {
    const symbols = [_]struct { text: []const u8, op: CompareOp }{
        .{ .text = "==", .op = .equal },
        .{ .text = "!=", .op = .not_equal },
        .{ .text = "<=", .op = .less_equal },
        .{ .text = ">=", .op = .greater_equal },
        .{ .text = "<", .op = .less },
        .{ .text = ">", .op = .greater },
    };
    for (symbols) |symbol| {
        if (std.mem.startsWith(u8, s, symbol.text)) return .{ .op = symbol.op, .rest = s[symbol.text.len..] };
    }
    const word = firstWord(s);
    const op: CompareOp = if (std.ascii.eqlIgnoreCase(word, "EQU")) .equal else if (std.ascii.eqlIgnoreCase(word, "NEQ")) .not_equal else if (std.ascii.eqlIgnoreCase(word, "LSS")) .less else if (std.ascii.eqlIgnoreCase(word, "LEQ")) .less_equal else if (std.ascii.eqlIgnoreCase(word, "GTR")) .greater else if (std.ascii.eqlIgnoreCase(word, "GEQ")) .greater_equal else return null;
    return .{ .op = op, .rest = s[word.len..] };
}

const Parser = struct {
    arena: *Arena,
    lines: []const []const u8,
    idx: usize = 0,
    after: []const u8 = "", // what followed a block's ')' on its line
    err: ?[]const u8 = null,
    err_line: usize = 0,
    nesting: usize = 0, // IF / FOR levels being parsed

    fn fail(p: *Parser, msg: []const u8) void {
        if (p.err == null) {
            p.err = msg;
            p.err_line = p.idx;
        }
    }

    fn newNode(p: *Parser, comptime T: type) ?*T {
        const s = p.arena.alloc(T, 1) orelse {
            p.fail("Not enough memory");
            return null;
        };
        return &s[0];
    }

    fn add(p: *Parser, list: *NodeList, n: Node) bool {
        if (list.append(p.arena, n)) return true;
        p.fail("Not enough memory");
        return false;
    }

    // Up to the end, or in a block up to a line starting with ')'.
    fn block(p: *Parser, in_block: bool) ?[]Node {
        var list: NodeList = .{};
        while (p.idx < p.lines.len) {
            const line = trim(p.lines[p.idx]);
            if (line.len > 0 and line[0] == ')') {
                if (in_block) return list.slice();
                p.idx += 1;
                p.fail("Unexpected )");
                return null;
            }
            p.idx += 1;
            if (p.statement(line)) |n| {
                if (!p.add(&list, n)) return null;
            } else if (p.err != null) return null;
        }
        if (in_block) {
            p.fail("Missing ) at the end of a block");
            return null;
        }
        return list.slice();
    }

    // Null for an empty line, a comment or an error.
    fn statement(p: *Parser, text: []const u8) ?Node {
        var t = trim(text);
        var quiet = false;
        if (t.len > 0 and t[0] == '@') {
            quiet = true;
            t = trim(t[1..]);
        }
        if (t.len == 0 or t[0] == '#' or startsWithWord(t, "REM")) return null;
        if (startsWithWord(t, "IF")) return p.parseIf(trim(t[2..]));
        if (startsWithWord(t, "FOR")) return p.parseFor(trim(t[3..]));
        return .{ .command = .{ .text = t, .quiet = quiet } };
    }

    // "( ... )" on one line, a block "(" over several lines up to ")", or
    // a single statement. Sets after.
    fn body(p: *Parser, text: []const u8) ?[]Node {
        const t = trim(text);
        p.after = "";
        var list: NodeList = .{};
        if (t.len == 0 or t[0] != '(') {
            if (p.statement(t)) |n| {
                if (!p.add(&list, n)) return null;
            } else if (p.err != null) return null;
            return list.slice();
        }
        if (matchParen(t)) |close| {
            if (p.statement(t[1..close])) |n| {
                if (!p.add(&list, n)) return null;
            } else if (p.err != null) return null;
            p.after = trim(t[close + 1 ..]);
            return list.slice();
        }
        // Over several lines; text after "(" is the first statement:
        if (p.statement(t[1..])) |n| {
            if (!p.add(&list, n)) return null;
        } else if (p.err != null) return null;
        const rest = p.block(true) orelse return null;
        for (rest) |n| {
            if (!p.add(&list, n)) return null;
        }
        const closing = trim(p.lines[p.idx]);
        p.idx += 1;
        p.after = trim(closing[1..]);
        return list.slice();
    }

    // False (with the error) past max_blocks.
    fn enter(p: *Parser) bool {
        p.nesting += 1;
        if (p.nesting <= max_blocks) return true;
        p.fail("Blocks nested too deeply (more than 64 IF / FOR levels)");
        return false;
    }

    fn parseIf(p: *Parser, rest: []const u8) ?Node {
        defer p.nesting -= 1;
        if (!p.enter()) return null;
        const node = p.newNode(If) orelse return null;
        node.* = .{ .cond = .{}, .then = &.{} };
        var t = rest;
        while (true) {
            if (startsWithWord(t, "-i")) {
                node.cond.ignore_case = true;
                t = trim(t[2..]);
            } else if (startsWithWord(t, "NOT")) {
                node.cond.negate = true;
                t = trim(t[3..]);
            } else break;
        }
        if (startsWithWord(t, "EXIST")) {
            const o = takeOperand(trim(t[5..]), false);
            if (o.op.len == 0) return p.syntax("Missing file name after EXIST");
            node.cond.kind = .{ .exist = o.op };
            t = trim(o.rest);
        } else if (startsWithWord(t, "DEFINED")) {
            const o = takeOperand(trim(t[7..]), false);
            if (o.op.len == 0) return p.syntax("Missing variable name after DEFINED");
            node.cond.kind = .{ .defined = o.op };
            t = trim(o.rest);
        } else if (startsWithWord(t, "ERRORLEVEL")) {
            const o = takeOperand(trim(t[10..]), false);
            if (o.op.len == 0) return p.syntax("Missing number after ERRORLEVEL");
            node.cond.kind = .{ .errorlevel = o.op };
            t = trim(o.rest);
        } else {
            const a = takeCompareOperand(t);
            const comparison = parseCompareOp(trim(a.rest)) orelse return p.syntax("IF needs EXIST, DEFINED, ERRORLEVEL or a comparison");
            const b = takeOperand(trim(comparison.rest), false);
            if (a.op.len == 0 or b.op.len == 0) return p.syntax("Missing value in IF comparison");
            node.cond.kind = .{ .compare = .{ .left = a.op, .right = b.op, .op = comparison.op } };
            t = trim(b.rest);
        }
        if (t.len == 0) return p.syntax("Missing command after the IF condition");

        if (t[0] == '(') {
            node.then = p.body(t) orelse return null;
            if (p.after.len > 0) {
                if (!startsWithWord(p.after, "ELSE")) return p.syntax("Unexpected text after )");
                node.else_ = p.elsePart(trim(p.after[4..])) orelse return null;
            }
        } else if (findElse(t)) |pos| {
            node.then = p.body(trim(t[0..pos])) orelse return null;
            node.else_ = p.elsePart(trim(t[pos + 4 ..])) orelse return null;
        } else {
            node.then = p.body(t) orelse return null;
        }
        return .{ .if_ = node };
    }

    fn elsePart(p: *Parser, text: []const u8) ?[]Node {
        if (text.len == 0) {
            p.fail("Missing command after ELSE");
            return null;
        }
        const nodes = p.body(text) orelse return null;
        if (p.after.len > 0) {
            p.fail("Unexpected text after )");
            return null;
        }
        return nodes;
    }

    fn parseFor(p: *Parser, rest: []const u8) ?Node {
        defer p.nesting -= 1;
        if (!p.enter()) return null;
        const node = p.newNode(For) orelse return null;
        node.* = .{ .var_name = 0 };
        var t = rest;
        if (startsWithWord(t, "-L")) {
            node.numeric = true;
            t = trim(t[2..]);
        } else if (startsWithWord(t, "-f")) {
            node.lines = true;
            t = trim(t[2..]);
        }
        if (!node.numeric and !node.lines and startsWithWord(t, "DO")) {
            t = trim(t[2..]); // endless
        } else {
            // %%X (batch file) or %X (prompt):
            var v = t;
            if (std.mem.startsWith(u8, v, "%%")) v = v[2..] else if (std.mem.startsWith(u8, v, "%")) v = v[1..] else return p.syntax("FOR needs a variable: FOR %%X IN (...) DO, or FOR DO");
            if (v.len == 0 or !std.ascii.isAlphabetic(v[0]) or (v.len > 1 and v[1] != ' ' and v[1] != '\t')) return p.syntax("A FOR variable is one letter: %%X");
            node.var_name = v[0];
            t = trim(v[1..]);
            if (!startsWithWord(t, "IN")) return p.syntax("Missing IN in FOR");
            t = trim(t[2..]);
            if (t.len == 0 or t[0] != '(') return p.syntax("FOR ... IN needs a list in ( )");
            const close = matchParen(t) orelse return p.syntax("Missing ) after the FOR list");
            node.list = t[1..close];
            t = trim(t[close + 1 ..]);
            if (!startsWithWord(t, "DO")) return p.syntax("Missing DO in FOR");
            t = trim(t[2..]);
        }
        if (t.len == 0) return p.syntax("Missing command after DO");
        node.body = p.body(t) orelse return null;
        if (p.after.len > 0) return p.syntax("Unexpected text after )");
        return .{ .for_ = node };
    }

    fn syntax(p: *Parser, msg: []const u8) ?Node {
        p.fail(msg);
        return null;
    }
};

// RUNNING

const Flow = enum { normal, break_loop, exit_file, abort };

const Ctx = struct {
    name: []const u8 = "", // %0
    args: []const u8 = "", // %1 ... from here
    prompt: bool, // a line typed at the prompt, not a batch file
    loops: usize = 0, // FOR loops running (for BREAK)
    vars: [128]?[]const u8 = [_]?[]const u8{null} ** 128, // FOR variables, by letter
};

var active_arithmetic_ctx: ?*const Ctx = null;

fn runNodes(ctx: *Ctx, nodes: []const Node) Flow {
    for (nodes) |n| {
        if (stopRequested(ctx)) return .abort;
        const flow = switch (n) {
            .command => |c| runCommand(ctx, c.text, c.quiet),
            .if_ => |i| if (evalCond(ctx, &i.cond)) runNodes(ctx, i.then) else runNodes(ctx, i.else_),
            .for_ => |f| runFor(ctx, f),
        };
        if (flow != .normal) return flow;
        if (aborting) return .abort;
    }
    return .normal;
}

fn runCommand(ctx: *Ctx, raw: []const u8, quiet: bool) Flow {
    if (arithmeticSetArgs(raw) != null) {
        if (!ctx.prompt and echo_on and !quiet) {
            shell.printPrompt();
            con.print(raw);
            con.print("\n");
        }
        const previous_ctx = active_arithmetic_ctx;
        active_arithmetic_ctx = ctx;
        defer active_arithmetic_ctx = previous_ctx;
        shell.runLine(raw);
        return .normal;
    }
    var buf: [line_max]u8 = undefined;
    const text = expand(ctx, raw, &buf) orelse {
        con.print("Line too long after expanding variables\n");
        return .normal;
    };
    if (text.len == 0) return .normal;
    if (!ctx.prompt and echo_on and !quiet) {
        shell.printPrompt();
        con.print(text);
        con.print("\n");
    }
    if (depth > 0 and startsWithWord(text, "EXIT")) {
        const code = trim(text[4..]);
        if (code.len > 0) vars.errorlevel = std.fmt.parseInt(u8, code, 10) catch vars.errorlevel;
        return .exit_file;
    }
    if (!ctx.prompt and startsWithWord(text, "SHIFT")) {
        // %0 is dropped: %1 becomes %0, %2 becomes %1 ...:
        ctx.name = arg(ctx.args, 0);
        ctx.args = afterFirstArg(ctx.args);
        return .normal;
    }
    if (startsWithWord(text, "BREAK")) {
        if (ctx.loops > 0) return .break_loop;
        con.print("BREAK only works inside a FOR loop\n");
        return .normal;
    }
    shell.runLine(text);
    return .normal;
}

fn arithmeticSetArgs(raw: []const u8) ?[]const u8 {
    const command = trim(raw);
    if (!startsWithWord(command, "SET")) return null;
    const args = trim(command[3..]);
    if (!startsWithWord(args, "-a")) return null;
    return trim(args[2..]);
}

fn evalCond(ctx: *Ctx, c: *const Cond) bool {
    var a_buf: [line_max]u8 = undefined;
    var b_buf: [line_max]u8 = undefined;
    const result = switch (c.kind) {
        .exist => |name| exists(expand(ctx, name, &a_buf) orelse ""),
        .defined => |name| blk: {
            var value_buf: vars.Buf = undefined;
            break :blk vars.get(expand(ctx, name, &a_buf) orelse "", &value_buf) != null;
        },
        .errorlevel => |num| blk: {
            const n = std.fmt.parseInt(u8, expand(ctx, num, &a_buf) orelse "", 10) catch break :blk false;
            break :blk vars.errorlevel >= n;
        },
        .compare => |comparison| blk: {
            const a = expand(ctx, comparison.left, &a_buf) orelse "";
            const b = expand(ctx, comparison.right, &b_buf) orelse "";
            break :blk compareValues(a, b, c.ignore_case, comparison.op);
        },
    };
    return result != c.negate;
}

fn compareValues(a_raw: []const u8, b_raw: []const u8, ignore_case: bool, op: CompareOp) bool {
    const a = unquote(a_raw);
    const b = unquote(b_raw);
    const a_number = std.fmt.parseInt(i64, std.mem.trim(u8, a, blanks), 10) catch null;
    const b_number = std.fmt.parseInt(i64, std.mem.trim(u8, b, blanks), 10) catch null;
    const order = if (a_number != null and b_number != null)
        orderInt(a_number.?, b_number.?)
    else
        compareText(a, b, ignore_case);
    return switch (op) {
        .equal => order == .eq,
        .not_equal => order != .eq,
        .less => order == .lt,
        .less_equal => order != .gt,
        .greater => order == .gt,
        .greater_equal => order != .lt,
    };
}

fn unquote(s: []const u8) []const u8 {
    return if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') s[1 .. s.len - 1] else s;
}

fn orderInt(a: i64, b: i64) std.math.Order {
    return if (a < b) .lt else if (a > b) .gt else .eq;
}

fn compareText(a: []const u8, b: []const u8, ignore_case: bool) std.math.Order {
    const n = @min(a.len, b.len);
    for (0..n) |i| {
        const ac = if (ignore_case) std.ascii.toLower(a[i]) else a[i];
        const bc = if (ignore_case) std.ascii.toLower(b[i]) else b[i];
        if (ac < bc) return .lt;
        if (ac > bc) return .gt;
    }
    return if (a.len < b.len) .lt else if (a.len > b.len) .gt else .eq;
}

// Or one matching a pattern.
fn exists(name_in: []const u8) bool {
    var name = name_in;
    if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"') name = name[1 .. name.len - 1];
    if (name.len == 0) return false;
    var typed_buf: fs.TypedBuf = undefined;
    name = fs.typedPath(name, &typed_buf);
    const last = fs.lastComponent(name);
    if (fs.hasWildcard(last)) {
        const dir = fs.resolveDir(name[0 .. name.len - last.len]) catch return false;
        var list = fs.listMatches(&dir, last, .all) catch return false;
        defer list.deinit();
        return list.count > 0;
    }
    const p = fs.resolve(name) catch return false;
    return (fs.kindOf(&p) catch null) != null;
}

fn runFor(ctx: *Ctx, f: *const For) Flow {
    ctx.loops += 1;
    defer ctx.loops -= 1;
    if (f.var_name == 0) {
        while (true) {
            if (stopRequested(ctx)) return .abort;
            const flow = runNodes(ctx, f.body);
            if (flow == .break_loop) return .normal;
            if (flow != .normal) return flow;
        }
    }

    var list_buf: [line_max]u8 = undefined;
    const list = expand(ctx, f.list, &list_buf) orelse return .normal;
    const saved = ctx.vars[f.var_name];
    defer ctx.vars[f.var_name] = saved;
    if (f.numeric) return forNumbers(ctx, f, list);
    if (f.lines) return forLines(ctx, f, trim(list));

    // Separated by blanks, commas or semicolons; "quoted items" stay whole:
    var i: usize = 0;
    while (i < list.len) {
        while (i < list.len and std.mem.indexOfScalar(u8, " \t,;", list[i]) != null) i += 1;
        if (i == list.len) break;
        const start = i;
        var quoted = false;
        while (i < list.len and (quoted or std.mem.indexOfScalar(u8, " \t,;", list[i]) == null)) : (i += 1) {
            if (list[i] == '"') quoted = !quoted;
        }
        const item = list[start..i];
        const flow = if (fs.hasWildcard(fs.lastComponent(item)))
            forFiles(ctx, f, item)
        else blk: {
            ctx.vars[f.var_name] = item;
            break :blk runNodes(ctx, f.body);
        };
        if (flow == .break_loop) return .normal;
        if (flow != .normal) return flow;
    }
    return .normal;
}

// FOR -L %%I IN (from,step,to): down with a negative step; a step of 0
// repeats until BREAK.
fn forNumbers(ctx: *Ctx, f: *const For, list: []const u8) Flow {
    var nums: [3]i64 = undefined;
    var it = std.mem.tokenizeAny(u8, list, " \t,;");
    for (&nums) |*n| {
        const word = it.next() orelse {
            con.print("FOR -L needs (from,step,to)\n");
            return .normal;
        };
        n.* = std.fmt.parseInt(i64, word, 10) catch {
            con.print("FOR -L needs numbers: (from,step,to)\n");
            return .normal;
        };
    }
    var i = nums[0];
    while ((nums[1] >= 0 and i <= nums[2]) or (nums[1] < 0 and i >= nums[2])) {
        if (stopRequested(ctx)) return .abort;
        var buf: [24]u8 = undefined;
        ctx.vars[f.var_name] = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
        const flow = runNodes(ctx, f.body);
        if (flow == .break_loop) return .normal;
        if (flow != .normal) return flow;
        // Stop instead of overflowing i64 near the ends of the range:
        i = std.math.add(i64, i, nums[1]) catch break;
    }
    return .normal;
}

// FOR -f %%L IN (FILES | 'command' | "text"): each nonempty line whole,
// not split into words as in DOS. All is read before the body runs.
fn forLines(ctx: *Ctx, f: *const For, list: []const u8) Flow {
    var text: fs.Grow(u8) = .{};
    defer text.deinit();
    var full = false; // memory ran out: some lines are missing
    if (list.len >= 2 and list[0] == '\'' and list[list.len - 1] == '\'') {
        // The command's output goes to a pipe; its input stays as it is:
        full = !commandOutput(list[1 .. list.len - 1], &text);
    } else if (list.len >= 2 and list[0] == '"' and list[list.len - 1] == '"') {
        full = !text.append(list[1 .. list.len - 1]);
    } else {
        var i: usize = 0;
        while (i < list.len) {
            while (i < list.len and (list[i] == ' ' or list[i] == '\t')) i += 1;
            if (i == list.len) break;
            const start = i;
            var quoted = false;
            while (i < list.len and (quoted or (list[i] != ' ' and list[i] != '\t'))) : (i += 1) {
                if (list[i] == '"') quoted = !quoted;
            }
            switch (appendFile(&text, std.mem.trim(u8, list[start..i], "\""))) {
                .done => {},
                .failed => return .normal,
                .full => full = true,
            }
        }
    }
    if (full) con.print("Not enough memory for all the lines; the rest was dropped\n");

    var lines = std.mem.splitScalar(u8, text.slice(), '\n');
    while (lines.next()) |raw| {
        // Without '\r'; longer lines are cut:
        var line: [line_max]u8 = undefined;
        var len: usize = 0;
        for (raw) |c| {
            if (c == '\r' or len == line.len) continue;
            line[len] = c;
            len += 1;
        }
        const value = std.mem.trim(u8, line[0..len], " \t");
        if (value.len == 0) continue;
        if (stopRequested(ctx)) return .abort;
        ctx.vars[f.var_name] = value;
        const flow = runNodes(ctx, f.body);
        if (flow == .break_loop) return .normal;
        if (flow != .normal) return flow;
    }
    return .normal;
}

// Run with its output in a pipe; false if memory ran out.
fn commandOutput(line: []const u8, text: *fs.Grow(u8)) bool {
    const pipe = sys.createPipe() catch return false;
    const prev = con.out_handle;
    con.setOutput(pipe.handle);
    shell.runLine(line);
    con.setOutput(prev);
    var complete = true;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = pipe.read(&buf) catch break;
        if (n == 0) break;
        if (!text.append(buf[0..n])) {
            complete = false;
            break;
        }
    }
    pipe.closeChecked() catch {
        complete = false;
    };
    return complete;
}

// failed (with a message) if it can't be read, full if memory ran out.
fn appendFile(text: *fs.Grow(u8), name: []const u8) enum { done, failed, full } {
    var typed_buf: fs.TypedBuf = undefined;
    const path = fs.typedPath(name, &typed_buf);
    if (fs.driveOf(path)) |letter| if (!fs.driveExists(letter)) {
        con.print("Invalid drive specification\n");
        return .failed;
    };
    const h = zdos.open(path, .read) catch |err| {
        cannotRead(name, err);
        return .failed;
    };
    defer h.close();
    var buf: [512]u8 = undefined;
    while (true) {
        const n = h.read(&buf) catch |err| {
            cannotRead(name, err);
            return .failed;
        };
        if (n == 0) return .done;
        if (!text.append(buf[0..n])) return .full;
    }
}

fn cannotRead(name: []const u8, err: fs.Error) void {
    con.printf("Cannot read {s}: {s}\n", .{ name, fs.message(err) });
}

// FOR %%F IN (*.TXT): not folders or hidden ones, as in DOS; the folder
// part as written ("DOCS\*.TXT" -> "DOCS\A.TXT").
fn forFiles(ctx: *Ctx, f: *const For, pattern: []const u8) Flow {
    var typed_buf: fs.TypedBuf = undefined;
    const typed = fs.typedPath(pattern, &typed_buf);
    const last = fs.lastComponent(typed);
    const prefix = typed[0 .. typed.len - last.len];
    const dir = fs.resolveDir(prefix) catch return .normal;
    var names = fs.listMatches(&dir, last, .visible) catch return .normal;
    defer names.deinit();
    var it = names.iterator();
    while (it.next()) |name| {
        var p = dir;
        if (!p.append(name) or (fs.kindOf(&p) catch null) != .file) continue;
        var buf: [fs.max_path]u8 = undefined;
        ctx.vars[f.var_name] = std.fmt.bufPrint(&buf, "{s}{s}", .{ prefix, name }) catch continue;
        const flow = runNodes(ctx, f.body);
        if (flow != .normal) return flow;
    }
    return .normal;
}

// %NAME%, in batch files also %0 ... %9, %* and %%X, at the prompt %X.
// %% in a batch file is one %. An unknown %NAME% is empty in a batch
// file and stays as it is at the prompt, as in DOS.
fn expand(ctx: *const Ctx, text: []const u8, out: []u8) ?[]const u8 {
    var value_buf: vars.Buf = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c != '%' or i + 1 == text.len) {
            if (n == out.len) return null;
            out[n] = c;
            n += 1;
            i += 1;
            continue;
        }
        const next = text[i + 1];
        var value: ?[]const u8 = null;
        var used: usize = 0;
        if (!ctx.prompt and next == '%') {
            // %%X: a FOR variable; otherwise %% is one %:
            if (i + 2 < text.len and ctx.vars[text[i + 2] & 0x7F] != null) {
                value = ctx.vars[text[i + 2] & 0x7F];
                used = 3;
            } else {
                value = "%";
                used = 2;
            }
        } else if (ctx.prompt and ctx.vars[next & 0x7F] != null) {
            value = ctx.vars[next & 0x7F];
            used = 2;
        } else if (!ctx.prompt and next >= '0' and next <= '9') {
            value = if (next == '0') ctx.name else arg(ctx.args, next - '1');
            used = 2;
        } else if (!ctx.prompt and next == '*') {
            value = trim(ctx.args);
            used = 2;
        } else if (std.mem.indexOfScalarPos(u8, text, i + 1, '%')) |close| {
            const name = text[i + 1 .. close];
            if (name.len > 0 and name.len <= vars.max_name and std.mem.indexOfAny(u8, name, " \t") == null) {
                if (vars.get(name, &value_buf)) |v| {
                    value = v;
                    used = close + 1 - i;
                } else if (!ctx.prompt) {
                    value = "";
                    used = close + 1 - i;
                }
            }
        }
        if (value) |v| {
            if (n + v.len > out.len) return null;
            @memcpy(out[n..][0..v.len], v);
            n += v.len;
            i += used;
        } else {
            if (n == out.len) return null;
            out[n] = '%';
            n += 1;
            i += 1;
        }
    }
    return out[0..n];
}

// 0-based; "quoted text" counts as one (quotes kept).
fn arg(args: []const u8, k: usize) []const u8 {
    var i: usize = 0;
    var index: usize = 0;
    while (true) {
        while (i < args.len and (args[i] == ' ' or args[i] == '\t')) i += 1;
        if (i == args.len) return "";
        const start = i;
        var quoted = false;
        while (i < args.len and (quoted or (args[i] != ' ' and args[i] != '\t'))) : (i += 1) {
            if (args[i] == '"') quoted = !quoted;
        }
        if (index == k) return args[start..i];
        index += 1;
    }
}

fn afterFirstArg(args: []const u8) []const u8 {
    var i: usize = 0;
    while (i < args.len and (args[i] == ' ' or args[i] == '\t')) i += 1;
    var quoted = false;
    while (i < args.len and (quoted or (args[i] != ' ' and args[i] != '\t'))) : (i += 1) {
        if (args[i] == '"') quoted = !quoted;
    }
    return args[i..];
}

// Asks whether to stop.
fn stopRequested(ctx: *const Ctx) bool {
    if (aborting) return true;
    if (depth == 0 and ctx.loops == 0) return false;
    if (!con.breakRequested()) return false;
    const prev = con.toScreen();
    defer con.restore(prev);
    con.print("Terminate batch job (Y/N)? ");
    defer con.clearBreak();
    while (true) {
        const answer = zdos.readKey().char;
        if (answer == 'y' or answer == 'Y') {
            con.print("Y\n");
            aborting = true;
            return true;
        }
        if (answer == 'n' or answer == 'N') {
            con.print("N\n");
            return false;
        }
    }
}

// May be IF / FOR, and is expanded (%NAME%).
pub fn runPromptLine(line: []const u8) void {
    var arena: Arena = .{};
    defer arena.deinit();
    const lines = [_][]const u8{line};
    var p: Parser = .{ .arena = &arena, .lines = &lines };
    const nodes = p.block(false) orelse {
        con.printf("Syntax error: {s}\n", .{p.err orelse "?"});
        return;
    };
    var ctx: Ctx = .{ .prompt = true };
    _ = runNodes(&ctx, nodes);
    aborting = false;
}

// Found by shell.find. name is %0 as typed, args %1 ...
pub fn runFile(f: *const shell.Found, name: []const u8, args: []const u8) void {
    run(f, name, args, true);
}

// SCRIPTS\AUTOEXEC.CMD (or .BAT) beside COMMAND.APP's folder, if there is one;
// its variables are global.
pub fn runAutoexec() void {
    var program_buf: [fs.max_path + 2]u8 = undefined;
    const program = zdos.programPath(&program_buf);
    const apps = std.fs.path.dirnameWindows(program) orelse return;
    const root = std.fs.path.dirnameWindows(apps) orelse return;
    const sep = if (std.mem.endsWith(u8, root, "\\")) "" else "\\";
    for ([_][]const u8{ "AUTOEXEC.CMD", "AUTOEXEC.BAT" }) |file| {
        var name_buf: [fs.max_path + 2]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}{s}SCRIPTS\\{s}", .{ root, sep, file }) catch return;
        var f: shell.Found = .{ .kind = .batch };
        if (!f.path.set(name)) return;
        if ((fs.kindOf(&f.path) catch null) != .file) continue;
        run(&f, f.path.onDrive()[1..], "", false);
        return;
    }
}

// For a login shell (COMMAND -l); its variables are global.
pub fn runLoginScript() void {
    var home_buf: [fs.max_path + 2]u8 = undefined;
    const home = zdos.getVar("HOME", &home_buf) orelse return;
    const sep = if (std.mem.endsWith(u8, home, "\\")) "" else "\\";
    for ([_][]const u8{ "LOGIN.CMD", "LOGIN.BAT" }) |file| {
        var name_buf: [fs.max_path + 2]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}{s}{s}", .{ home, sep, file }) catch return;
        var f: shell.Found = .{ .kind = .batch };
        if (!f.path.set(name)) return;
        if ((fs.kindOf(&f.path) catch null) != .file) continue;
        run(&f, f.path.onDrive()[1..], "", false);
        return;
    }
}

fn run(f: *const shell.Found, name: []const u8, args: []const u8, own_scope: bool) void {
    if (depth == max_nested) {
        con.print("Batch files nested too deeply\n");
        return;
    }
    const text = readFile(f) orelse return;
    defer zdos.free(@ptrCast(@alignCast(text.ptr)));

    // Lines, without "\r":
    var arena: Arena = .{};
    defer arena.deinit();
    const count = std.mem.count(u8, text, "\n") + 1;
    const lines = arena.alloc([]const u8, count) orelse {
        con.print("Not enough memory\n");
        return;
    };
    var it = std.mem.splitScalar(u8, text, '\n');
    var k: usize = 0;
    while (it.next()) |l| : (k += 1) lines[k] = std.mem.trimRight(u8, l, "\r");

    var p: Parser = .{ .arena = &arena, .lines = lines };
    const nodes = p.block(false) orelse {
        con.printf("Syntax error in {s}, line {d}: {s}\n", .{ name, p.err_line, p.err orelse "?" });
        return;
    };

    if (own_scope and !vars.pushScope()) {
        con.print("Batch files nested too deeply\n");
        return;
    }
    defer if (own_scope) vars.popScope();
    if (depth == 0) echo_on = true;
    depth += 1;
    defer {
        depth -= 1;
        if (depth == 0) aborting = false;
    }
    var ctx: Ctx = .{ .name = name, .args = args, .prompt = false };
    _ = runNodes(&ctx, nodes);
}

fn readFile(f: *const shell.Found) ?[]u8 {
    const h = zdos.open(f.path.slice(), .read) catch |err| {
        cannotRead("the batch file", err);
        return null;
    };
    defer h.close();
    const size = h.size() catch |err| {
        cannotRead("the batch file", err);
        return null;
    };
    if (size > max_file) {
        con.print("Batch file too big\n");
        return null;
    }
    const len: usize = @intCast(size);
    const mem = zdos.alloc(@max(len, 1)) orelse {
        con.print("Not enough memory\n");
        return null;
    };
    var done: usize = 0;
    while (done < len) {
        const n = h.read(mem[done..len]) catch |err| {
            zdos.free(mem);
            cannotRead("the batch file", err);
            return null;
        };
        if (n == 0) break; // shorter than its size said
        done += n;
    }
    return mem[0..done];
}

// COMMANDS

// SET [NAME[=value]] | -p NAME=prompt
pub fn cmdSet(args: []const u8) void {
    var a = trim(args);
    if (a.len == 0) {
        vars.each(@as(?[]const u8, null), printVar);
        return;
    }
    if (startsWithWord(a, "-a")) {
        var fallback_ctx: Ctx = .{ .prompt = depth == 0 };
        cmdSetArithmetic(active_arithmetic_ctx orelse &fallback_ctx, trim(a[2..]));
        return;
    }
    if (startsWithWord(a, "-p")) {
        const rest = trim(a[2..]);
        const eq = std.mem.indexOfScalar(u8, rest, '=') orelse {
            con.print("Syntax: SET -p NAME=prompt\n");
            return;
        };
        var prompt = rest[eq + 1 ..];
        if (prompt.len >= 2 and prompt[0] == '"' and prompt[prompt.len - 1] == '"') prompt = prompt[1 .. prompt.len - 1];
        var buf: [vars.max_value]u8 = undefined;
        const answer = readAnswer(prompt, &buf);
        if (answer.len > 0) setVar(trim(rest[0..eq]), answer);
        return;
    }
    if (a.len >= 2 and a[0] == '"' and a[a.len - 1] == '"') a = a[1 .. a.len - 1]; // SET "NAME=value"
    const eq = std.mem.indexOfScalar(u8, a, '=') orelse {
        var found = false;
        const Prefix = struct { text: []const u8, found: *bool };
        vars.each(Prefix{ .text = a, .found = &found }, struct {
            fn f(ctx: Prefix, name: []const u8, value: []const u8) void {
                if (name.len < ctx.text.len or !std.ascii.eqlIgnoreCase(name[0..ctx.text.len], ctx.text)) return;
                ctx.found.* = true;
                con.printf("{s}={s}\n", .{ name, value });
            }
        }.f);
        if (!found) con.printf("Environment variable {s} not defined\n", .{a});
        return;
    };
    setVar(trim(a[0..eq]), a[eq + 1 ..]);
}

const ArithmeticError = error{ MissingOperand, InvalidNumber, DivisionByZero, OutOfRange, OutOfSpace };
const ArithmeticOp = enum { add, subtract, multiply, divide, modulo };
const AssignmentOp = union(enum) { set, compound: ArithmeticOp };

// SET -a lines skip expand(): '%' where an operand is expected
// starts a variable; after an operand it is the remainder ("%%" too
// in a batch file, as NT).
const ArithmeticParser = struct {
    text: []const u8,
    ctx: *const Ctx,
    pos: usize = 0,

    fn evaluate(self: *ArithmeticParser) ArithmeticError!i64 {
        const value = try self.additive();
        self.skipSpace();
        if (self.pos != self.text.len) return error.InvalidNumber;
        return value;
    }

    fn additive(self: *ArithmeticParser) ArithmeticError!i64 {
        var value = try self.multiplicative();
        while (true) {
            self.skipSpace();
            if (self.consume('+')) {
                value = try applyArithmetic(.add, value, try self.multiplicative());
            } else if (self.consume('-')) {
                value = try applyArithmetic(.subtract, value, try self.multiplicative());
            } else return value;
        }
    }

    fn multiplicative(self: *ArithmeticParser) ArithmeticError!i64 {
        var value = try self.unary();
        while (true) {
            self.skipSpace();
            if (self.consume('*')) {
                value = try applyArithmetic(.multiply, value, try self.unary());
            } else if (self.consume('/')) {
                value = try applyArithmetic(.divide, value, try self.unary());
            } else if (self.consume('%')) {
                if (!self.ctx.prompt) _ = self.consume('%'); // %% is one % in a batch file
                value = try applyArithmetic(.modulo, value, try self.unary());
            } else return value;
        }
    }

    fn unary(self: *ArithmeticParser) ArithmeticError!i64 {
        self.skipSpace();
        if (self.consume('+')) return self.unary();
        if (self.consume('-')) {
            self.skipSpace();
            if (self.pos < self.text.len and std.ascii.isDigit(self.text[self.pos])) {
                const start = self.pos;
                while (self.pos < self.text.len and std.ascii.isDigit(self.text[self.pos])) : (self.pos += 1) {}
                const magnitude = std.fmt.parseInt(u64, self.text[start..self.pos], 10) catch return error.OutOfRange;
                const min_magnitude: u64 = @as(u64, 1) << 63;
                if (magnitude > min_magnitude) return error.OutOfRange;
                if (magnitude == min_magnitude) return std.math.minInt(i64);
                return -@as(i64, @intCast(magnitude));
            }
            return try applyArithmetic(.subtract, 0, try self.unary());
        }
        return self.primary();
    }

    fn primary(self: *ArithmeticParser) ArithmeticError!i64 {
        self.skipSpace();
        if (self.pos == self.text.len) return error.MissingOperand;
        if (self.consume('(')) {
            const value = try self.additive();
            self.skipSpace();
            if (!self.consume(')')) return error.InvalidNumber;
            return value;
        }
        const c = self.text[self.pos];
        if (std.ascii.isDigit(c)) {
            const start = self.pos;
            while (self.pos < self.text.len and std.ascii.isDigit(self.text[self.pos])) : (self.pos += 1) {}
            return std.fmt.parseInt(i64, self.text[start..self.pos], 10) catch error.OutOfRange;
        }
        if (c == '%') return self.percentOperand();
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = self.pos;
            self.pos += 1;
            while (self.pos < self.text.len and (std.ascii.isAlphanumeric(self.text[self.pos]) or self.text[self.pos] == '_')) : (self.pos += 1) {}
            return arithmeticVariable(self.ctx, self.text[start..self.pos]);
        }
        return error.InvalidNumber;
    }

    // %%X (FOR, batch file)   %X (FOR, prompt)   %1 ... %9   %NAME%
    fn percentOperand(self: *ArithmeticParser) ArithmeticError!i64 {
        const at = self.pos + 1; // just after the first '%'
        const ctx = self.ctx;

        // %%X in a batch file:
        if (!ctx.prompt and at + 1 < self.text.len and self.text[at] == '%') {
            if (ctx.vars[self.text[at + 1] & 0x7F]) |v| {
                self.pos = at + 2;
                return numberOf(v);
            }
        }
        // %X at the prompt:
        if (ctx.prompt and at < self.text.len) {
            if (ctx.vars[self.text[at] & 0x7F]) |v| {
                self.pos = at + 1;
                return numberOf(v);
            }
        }
        // %1 ... %9 in a batch file:
        if (!ctx.prompt and at < self.text.len and self.text[at] >= '1' and self.text[at] <= '9') {
            const v = arg(ctx.args, self.text[at] - '1');
            self.pos = at + 1;
            return numberOf(v);
        }
        // %NAME%:
        const close = std.mem.indexOfScalarPos(u8, self.text, at, '%') orelse return error.MissingOperand;
        const name = self.text[at..close];
        if (!validArithmeticName(name)) return error.InvalidNumber;
        self.pos = close + 1;
        return arithmeticVariable(ctx, name);
    }

    fn skipSpace(self: *ArithmeticParser) void {
        while (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\t')) : (self.pos += 1) {}
    }

    fn consume(self: *ArithmeticParser, c: u8) bool {
        if (self.pos >= self.text.len or self.text[self.pos] != c) return false;
        self.pos += 1;
        return true;
    }
};

fn validArithmeticName(name: []const u8) bool {
    if (name.len == 0 or name.len > vars.max_name) return false;
    if (!(std.ascii.isAlphabetic(name[0]) or name[0] == '_')) return false;
    for (name[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

fn numberOf(text: []const u8) i64 {
    return std.fmt.parseInt(i64, std.mem.trim(u8, text, blanks), 10) catch 0;
}

fn arithmeticVariable(ctx: *const Ctx, name: []const u8) i64 {
    // A FOR variable, by its exact letter (as expand and runFor do):
    if (name.len == 1 and name[0] < 128) {
        if (ctx.vars[name[0]]) |value| return numberOf(value);
    }
    var buf: vars.Buf = undefined;
    const value = vars.get(name, &buf) orelse return 0;
    return numberOf(value);
}

fn applyArithmetic(op: ArithmeticOp, left: i64, right: i64) ArithmeticError!i64 {
    switch (op) {
        .add => {
            const result = @addWithOverflow(left, right);
            if (result[1] != 0) return error.OutOfRange;
            return result[0];
        },
        .subtract => {
            const result = @subWithOverflow(left, right);
            if (result[1] != 0) return error.OutOfRange;
            return result[0];
        },
        .multiply => {
            const result = @mulWithOverflow(left, right);
            if (result[1] != 0) return error.OutOfRange;
            return result[0];
        },
        .divide, .modulo => {
            if (right == 0) return error.DivisionByZero;
            if (left == std.math.minInt(i64) and right == -1) return error.OutOfRange;
            return if (op == .divide) @divTrunc(left, right) else @rem(left, right);
        },
    }
}

fn evalAssignment(ctx: *const Ctx, assignment: []const u8) ArithmeticError!i64 {
    const text = trim(assignment);
    var name_end: usize = 0;
    while (name_end < text.len and (std.ascii.isAlphanumeric(text[name_end]) or text[name_end] == '_')) : (name_end += 1) {}
    const name = text[0..name_end];
    if (!validArithmeticName(name)) return error.InvalidNumber;

    var operator_pos = name_end;
    while (operator_pos < text.len and (text[operator_pos] == ' ' or text[operator_pos] == '\t')) : (operator_pos += 1) {}
    var assignment_op: AssignmentOp = undefined;
    var expression_start = operator_pos;
    if (operator_pos + 1 < text.len and text[operator_pos + 1] == '=') {
        const op: ArithmeticOp = switch (text[operator_pos]) {
            '+' => .add,
            '-' => .subtract,
            '*' => .multiply,
            '/' => .divide,
            '%' => .modulo,
            else => return error.InvalidNumber,
        };
        assignment_op = .{ .compound = op };
        expression_start += 2;
    } else if (operator_pos < text.len and text[operator_pos] == '=') {
        assignment_op = .set;
        expression_start += 1;
    } else return error.InvalidNumber;

    const expression = trim(text[expression_start..]);
    if (expression.len == 0) return error.MissingOperand;
    var parser: ArithmeticParser = .{ .text = expression, .ctx = ctx };
    const value = try parser.evaluate();
    const result = switch (assignment_op) {
        .set => value,
        .compound => |op| try applyArithmetic(op, arithmeticVariable(ctx, name), value),
    };
    var value_buf: [32]u8 = undefined;
    const value_text = std.fmt.bufPrint(&value_buf, "{d}", .{result}) catch return error.OutOfRange;
    vars.set(name, value_text) catch return error.OutOfSpace;
    return result;
}

fn arithmeticAssignments(ctx: *const Ctx, text: []const u8) ArithmeticError!i64 {
    if (trim(text).len == 0) return error.MissingOperand;
    var start: usize = 0;
    var nesting: usize = 0;
    var result: i64 = 0;
    for (text, 0..) |c, i| {
        if (c == '(') nesting += 1 else if (c == ')') {
            if (nesting == 0) return error.InvalidNumber;
            nesting -= 1;
        } else if (c == ',' and nesting == 0) {
            if (trim(text[start..i]).len == 0) return error.MissingOperand;
            result = try evalAssignment(ctx, text[start..i]);
            start = i + 1;
        }
    }
    if (nesting != 0) return error.MissingOperand;
    if (trim(text[start..]).len == 0) return error.MissingOperand;
    return evalAssignment(ctx, text[start..]);
}

fn cmdSetArithmetic(ctx: *const Ctx, expression: []const u8) void {
    const result = arithmeticAssignments(ctx, expression) catch |err| {
        con.print(switch (err) {
            error.DivisionByZero => "Division by zero\n",
            error.MissingOperand => "Missing operand\n",
            error.OutOfRange => "Number out of range\n",
            error.OutOfSpace => "Out of environment space\n",
            error.InvalidNumber => "Invalid number\n",
        });
        return;
    };
    if (ctx.prompt) con.printf("{d}\n", .{result});
}

fn printVar(_: ?[]const u8, name: []const u8, value: []const u8) void {
    con.print(name);
    con.print("=");
    con.print(value);
    con.print("\n");
}

fn setVar(name: []const u8, value: []const u8) void {
    vars.set(name, value) catch |e| con.print(switch (e) {
        error.BadName => "Invalid variable name\n",
        error.TooLong => "Value too long\n",
        error.OutOfSpace => "Out of environment space\n",
        error.Denied => "Only admins may set variables (in a batch file they are its own)\n",
    });
}

// From the keyboard, or one line of stdin if that is redirected.
fn readAnswer(prompt: []const u8, buf: []u8) []const u8 {
    const prev = con.toScreen();
    defer con.restore(prev);
    con.print(prompt);
    if (!zdos.inputRedirected()) return trim(lineedit.read(buf, false));
    var n: usize = 0;
    while (n < buf.len) {
        var c: [1]u8 = undefined;
        if (zdos.readInput(&c) == 0 or c[0] == '\n') break;
        if (c[0] != '\r') {
            buf[n] = c[0];
            n += 1;
        }
    }
    con.print(buf[0..n]);
    con.print("\n");
    return buf[0..n];
}

// PATH [dir;dir... | ;]
pub fn cmdPath(args: []const u8) void {
    var a = trim(args);
    if (a.len > 0 and a[0] == '=') a = trim(a[1..]); // PATH=C:\APPS
    if (a.len == 0) {
        var buf: vars.Buf = undefined;
        if (vars.get("PATH", &buf)) |v| {
            con.print("PATH=");
            con.print(v);
            con.print("\n");
        } else con.print("No Path\n");
        return;
    }
    setVar("PATH", if (std.mem.eql(u8, a, ";")) "" else a);
}

pub fn cmdPause() void {
    const prev = con.toScreen();
    defer con.restore(prev);
    con.print("Press any key to continue . . .");
    while (true) {
        const k = zdos.readKey();
        if (k.char != 0 or k.scan != 0) break; // not a modifier on its own
    }
    con.print("\n");
}

// CHOICE: ERRORLEVEL is the position of the key pressed.
pub fn cmdChoice(args: []const u8) void {
    var keys: []const u8 = "YN";
    var show_keys = true;
    var case_sensitive = false;
    var timeout: ?u32 = null;
    var default_key: ?u8 = null;
    var text: []const u8 = "";

    var rest = trim(args);
    while (rest.len > 0 and rest[0] == '-') {
        const word = firstWord(rest);
        rest = trim(rest[word.len..]);
        // A value: after ':' in the same word, else the next word:
        const inline_value: ?[]const u8 = if (std.mem.indexOfScalar(u8, word, ':')) |c| word[c + 1 ..] else null;
        const sw = if (std.mem.indexOfScalar(u8, word, ':')) |c| word[0..c] else word;
        const is = std.ascii.eqlIgnoreCase;
        if (is(sw, "-c")) {
            keys = inline_value orelse takeWord(&rest);
        } else if (is(sw, "-n")) {
            show_keys = false;
        } else if (is(sw, "-cs")) {
            case_sensitive = true;
        } else if (is(sw, "-t")) {
            // -t:N,10: key N after 10 seconds:
            const v = inline_value orelse "";
            const comma = std.mem.indexOfScalar(u8, v, ',') orelse 0;
            if (comma != 1) return choiceError("Use -t:key,seconds (e.g. -t:N,10)");
            default_key = v[0];
            timeout = std.fmt.parseInt(u32, v[2..], 10) catch return choiceError("Use -t:key,seconds (e.g. -t:N,10)");
        } else if (is(sw, "-m")) {
            text = rest;
            rest = "";
        } else {
            con.print("Invalid switch - ");
            con.print(word);
            con.print("\n");
            vars.errorlevel = 255;
            return;
        }
    }
    if (text.len == 0) text = rest;
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') text = text[1 .. text.len - 1];
    if (keys.len == 0) return choiceError("No keys to choose from");
    if (default_key) |d| {
        if (keyIndex(keys, d, case_sensitive) == null) return choiceError("The key of -t must be one of the keys");
    }

    // The question and the answer always on the screen:
    const prev = con.toScreen();
    defer con.restore(prev);
    con.print(text);
    if (show_keys) {
        if (text.len > 0) con.print(" ");
        con.print("[");
        for (keys, 0..) |k, i| {
            if (i > 0) con.print(",");
            con.print(&[_]u8{if (case_sensitive) k else std.ascii.toUpper(k)});
        }
        con.print("]?");
    }

    const deadline: ?u64 = if (timeout) |t| zdos.millis() + @as(u64, t) * 1000 else null;
    const chosen: usize = while (true) {
        const k = if (deadline == null) zdos.readKey() else zdos.pollKey() orelse {
            if (zdos.millis() >= deadline.?) break keyIndex(keys, default_key.?, case_sensitive).?;
            zdos.sleep(10);
            continue;
        };
        if (k.char == 0 or k.char > 0x7F) continue;
        if (keyIndex(keys, @intCast(k.char), case_sensitive)) |i| break i;
    };
    con.print(&[_]u8{if (case_sensitive) keys[chosen] else std.ascii.toUpper(keys[chosen])});
    con.print("\n");
    vars.errorlevel = @intCast(chosen + 1);
}

fn takeWord(rest: *[]const u8) []const u8 {
    const w = firstWord(rest.*);
    rest.* = trim(rest.*[w.len..]);
    return w;
}

fn keyIndex(keys: []const u8, key: u8, case_sensitive: bool) ?usize {
    for (keys, 0..) |k, i| {
        if (k == key or (!case_sensitive and std.ascii.toUpper(k) == std.ascii.toUpper(key))) return i;
    }
    return null;
}

fn choiceError(msg: []const u8) void {
    con.print(msg);
    con.print("\n");
    vars.errorlevel = 255;
}
