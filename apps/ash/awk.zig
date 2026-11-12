// awk [-F FS] [-v NAME=VALUE]... 'PROGRAM' | -f PROGFILE... [FILE]...
// Commands run in ash one at a time: output to a command is collected
// and run when the stream is closed; a getline command runs whole first.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const sys = @import("../zdos/system.zig");
const shell_mod = @import("shell.zig");
const regex = @import("regex.zig");
const format = @import("format.zig");
const text = @import("text.zig");

const Allocator = std.mem.Allocator;
const Shell = shell_mod.Shell;
const gpa = zdos.allocator;

const Err = error{ Fatal, OutOfMemory, Interrupted };

// SCRATCH MEMORY: given out in order, taken back to a mark

const Temp = struct {
    chunks: std.ArrayListUnmanaged([]u8) = .{},
    cur: usize = 0,
    used: usize = 0,
    last: usize = 0, // where the last allocation starts in the current chunk

    const chunk_size = 64 * 1024;
    const Mark = struct { cur: usize, used: usize };

    fn allocator(self: *Temp) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

    fn fit(self: *Temp, len: usize, al: usize) ?[*]u8 {
        const chunk = self.chunks.items[self.cur];
        const base = @intFromPtr(chunk.ptr);
        const start = std.mem.alignForward(usize, base + self.used, al) - base;
        if (start + len > chunk.len) return null;
        self.last = start;
        self.used = start + len;
        return chunk.ptr + start;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *Temp = @ptrCast(@alignCast(ctx));
        const al = alignment.toByteUnits();
        if (self.chunks.items.len > 0) {
            if (self.fit(len, al)) |p| return p;
            while (self.cur + 1 < self.chunks.items.len) {
                self.cur += 1;
                self.used = 0;
                if (self.fit(len, al)) |p| return p;
            }
        }
        const mem = gpa.alloc(u8, @max(chunk_size, len + al)) catch return null;
        self.chunks.append(gpa, mem) catch {
            gpa.free(mem);
            return null;
        };
        self.cur = self.chunks.items.len - 1;
        self.used = 0;
        return self.fit(len, al);
    }

    fn isLast(self: *Temp, memory: []u8) bool {
        if (self.chunks.items.len == 0) return false;
        return memory.ptr == self.chunks.items[self.cur].ptr + self.last;
    }

    fn resize(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        const self: *Temp = @ptrCast(@alignCast(ctx));
        if (self.isLast(memory) and self.last + new_len <= self.chunks.items[self.cur].len) {
            self.used = self.last + new_len;
            return true;
        }
        return new_len <= memory.len;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        return if (resize(ctx, memory, alignment, new_len, ret)) memory.ptr else null;
    }

    fn free(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *Temp = @ptrCast(@alignCast(ctx));
        if (self.isLast(memory)) self.used = self.last;
    }

    fn mark(self: *Temp) Mark {
        return .{ .cur = self.cur, .used = self.used };
    }

    fn release(self: *Temp, m: Mark) void {
        self.cur = m.cur;
        self.used = m.used;
    }

    fn deinit(self: *Temp) void {
        for (self.chunks.items) |c| gpa.free(c);
        self.chunks.deinit(gpa);
    }
};

// VALUES

const Kind = enum(u8) {
    uninit, // never set: "" and 0
    num,
    str,
    strnum, // input that looks like a number: compares as one
};

const Value = struct {
    kind: Kind = .uninit,
    num: f64 = 0,
    str: []const u8 = "", // not valid for .num

    fn ofNum(n: f64) Value {
        return .{ .kind = .num, .num = n };
    }

    fn ofStr(s: []const u8) Value {
        return .{ .kind = .str, .str = s };
    }

    // Text from input: a number if it looks like one.
    fn ofInput(s: []const u8) Value {
        if (looksNumeric(s)) return .{ .kind = .strnum, .str = s, .num = strToNum(s) };
        return .{ .kind = .str, .str = s };
    }
};

// Its text belongs to it.
const Cell = struct {
    v: Value = .{},

    fn set(self: *Cell, v: Value) Allocator.Error!void {
        var new = v;
        if (v.kind == .str or v.kind == .strnum) {
            new.str = try gpa.dupe(u8, v.str);
        } else new.str = "";
        self.deinit();
        self.v = new;
    }

    fn deinit(self: *Cell) void {
        if (self.v.kind == .str or self.v.kind == .strnum) gpa.free(self.v.str);
        self.v = .{};
    }
};

const Array = std.StringHashMapUnmanaged(Cell);

fn freeArray(arr: *Array) void {
    var it = arr.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        e.value_ptr.deinit();
    }
    arr.deinit(gpa);
}

const Slot = union(enum) {
    uninit,
    cell: Cell,
    array: *Array,
    ref: *Slot, // a caller's variable, passed to a function (arrays go by reference)
};

fn freeSlot(s: *Slot) void {
    switch (s.*) {
        .cell => |*c| c.deinit(),
        .array => |arr| {
            freeArray(arr);
            gpa.destroy(arr);
        },
        else => {},
    }
    s.* = .uninit;
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

// Like strtod, 0 if none.
fn strToNum(s: []const u8) f64 {
    var i: usize = 0;
    while (i < s.len and isBlank(s[i])) i += 1;
    const end = numberEnd(s, i);
    if (end == i) return 0;
    return std.fmt.parseFloat(f64, s[i..end]) catch 0;
}

// i if there is none.
fn numberEnd(s: []const u8, start: usize) usize {
    var i = start;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
    const digits_start = i;
    while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
    var digits = i - digits_start;
    if (i < s.len and s[i] == '.') {
        i += 1;
        const f = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        digits += i - f;
    }
    if (digits == 0) return start;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        var j = i + 1;
        if (j < s.len and (s[j] == '+' or s[j] == '-')) j += 1;
        const e = j;
        while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
        if (j > e) i = j;
    }
    return i;
}

fn looksNumeric(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and isBlank(s[i])) i += 1;
    const end = numberEnd(s, i);
    if (end == i) return false;
    var j = end;
    while (j < s.len and isBlank(s[j])) j += 1;
    return j == s.len;
}

// LEXER

const T = enum {
    eof,
    newline,
    lbrace,
    rbrace,
    lparen,
    rparen,
    lbracket,
    rbracket,
    semicolon,
    comma,
    plus,
    minus,
    star,
    slash,
    percent,
    caret,
    not,
    gt,
    lt,
    pipe,
    question,
    colon,
    tilde,
    nomatch,
    dollar,
    assign,
    add_assign,
    sub_assign,
    mul_assign,
    div_assign,
    mod_assign,
    pow_assign,
    eq,
    ne,
    le,
    ge,
    and_,
    or_,
    incr,
    decr,
    append,
    number,
    string,
    ere,
    name,
    funcname, // a name followed right away by (
    builtin,
    kw_begin,
    kw_end,
    kw_function,
    kw_if,
    kw_else,
    kw_while,
    kw_for,
    kw_do,
    kw_break,
    kw_continue,
    kw_next,
    kw_nextfile,
    kw_exit,
    kw_return,
    kw_delete,
    kw_getline,
    kw_print,
    kw_printf,
    kw_in,
};

const Builtin = enum {
    length,
    substr,
    index,
    split,
    sub,
    gsub,
    match,
    sprintf,
    sin,
    cos,
    atan2,
    exp,
    log,
    sqrt,
    int,
    rand,
    srand,
    tolower,
    toupper,
    system,
    close,
    fflush,
};

const Token = struct {
    t: T,
    text: []const u8 = "",
    num: f64 = 0,
    b: Builtin = .length,
    line: u32,
};

const keywords = std.StaticStringMap(T).initComptime(.{
    .{ "BEGIN", .kw_begin },       .{ "END", .kw_end },           .{ "function", .kw_function },
    .{ "func", .kw_function },     .{ "if", .kw_if },             .{ "else", .kw_else },
    .{ "while", .kw_while },       .{ "for", .kw_for },           .{ "do", .kw_do },
    .{ "break", .kw_break },       .{ "continue", .kw_continue }, .{ "next", .kw_next },
    .{ "nextfile", .kw_nextfile }, .{ "exit", .kw_exit },         .{ "return", .kw_return },
    .{ "delete", .kw_delete },     .{ "getline", .kw_getline },   .{ "print", .kw_print },
    .{ "printf", .kw_printf },     .{ "in", .kw_in },
});

fn syntaxError(line: u32, comptime fmt: []const u8, args: anytype) Err {
    errout.printf("awk: line {d}: " ++ fmt ++ "\n", .{line} ++ args);
    return error.Fatal;
}

// Of strings and -v values.
fn unescape(a: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return s;
    var out: std.ArrayListUnmanaged(u8) = .{};
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\' or i + 1 >= s.len) {
            try out.append(a, s[i]);
            continue;
        }
        i += 1;
        const c = s[i];
        switch (c) {
            'n' => try out.append(a, '\n'),
            't' => try out.append(a, '\t'),
            'r' => try out.append(a, '\r'),
            'a' => try out.append(a, 7),
            'b' => try out.append(a, 8),
            'f' => try out.append(a, 0x0c),
            'v' => try out.append(a, 0x0b),
            '\\' => try out.append(a, '\\'),
            '"' => try out.append(a, '"'),
            '/' => try out.append(a, '/'),
            '0'...'7' => {
                var v: u32 = c - '0';
                var n: usize = 1;
                while (n < 3 and i + 1 < s.len and s[i + 1] >= '0' and s[i + 1] <= '7') : (n += 1) {
                    i += 1;
                    v = v * 8 + (s[i] - '0');
                }
                try out.append(a, @truncate(v));
            },
            else => {
                // Kept for regular expressions: "\." matches a dot:
                try out.append(a, '\\');
                try out.append(a, c);
            },
        }
    }
    return out.items;
}

fn lex(a: Allocator, src: []const u8) Err![]Token {
    var toks: std.ArrayListUnmanaged(Token) = .{};
    var i: usize = 0;
    var line: u32 = 1;
    while (true) {
        // Blanks, comments, \ at the end of a line:
        while (i < src.len) {
            const c = src[i];
            if (c == ' ' or c == '\t' or c == '\r') {
                i += 1;
            } else if (c == '\\' and i + 1 < src.len and (src[i + 1] == '\n' or (src[i + 1] == '\r' and i + 2 < src.len and src[i + 2] == '\n'))) {
                i += if (src[i + 1] == '\r') 3 else 2;
                line += 1;
            } else if (c == '#') {
                while (i < src.len and src[i] != '\n') i += 1;
            } else break;
        }
        if (i >= src.len) {
            try toks.append(a, .{ .t = .eof, .line = line });
            return toks.items;
        }
        const c = src[i];
        const n1: u8 = if (i + 1 < src.len) src[i + 1] else 0;
        var tok: Token = .{ .t = .eof, .line = line };
        if (c == '\n') {
            tok.t = .newline;
            line += 1;
            i += 1;
        } else if (std.ascii.isDigit(c) or (c == '.' and std.ascii.isDigit(n1))) {
            const end = numberEnd(src, i);
            tok.t = .number;
            tok.num = std.fmt.parseFloat(f64, src[i..end]) catch 0;
            i = end;
        } else if (c == '"') {
            var j = i + 1;
            while (j < src.len and src[j] != '"') : (j += 1) {
                if (src[j] == '\\') j += 1;
                if (j < src.len and src[j] == '\n') return syntaxError(line, "newline in string", .{});
            }
            if (j >= src.len) return syntaxError(line, "string without end", .{});
            tok.t = .string;
            tok.text = try unescape(a, src[i + 1 .. j]);
            i = j + 1;
        } else if (c == '/' and regexAllowed(toks.items)) {
            var j = i + 1;
            var in_bracket = false;
            var re: std.ArrayListUnmanaged(u8) = .{};
            while (j < src.len) : (j += 1) {
                const d = src[j];
                if (d == '\n') return syntaxError(line, "newline in regular expression", .{});
                if (d == '\\' and j + 1 < src.len) {
                    if (src[j + 1] == '/') {
                        try re.append(a, '/');
                    } else {
                        try re.appendSlice(a, src[j .. j + 2]);
                    }
                    j += 1;
                    continue;
                }
                if (d == '[') in_bracket = true;
                if (d == ']') in_bracket = false;
                if (d == '/' and !in_bracket) break;
                try re.append(a, d);
            }
            if (j >= src.len) return syntaxError(line, "regular expression without end", .{});
            tok.t = .ere;
            tok.text = re.items;
            i = j + 1;
        } else if (std.ascii.isAlphabetic(c) or c == '_') {
            var j = i;
            while (j < src.len and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) j += 1;
            const word = src[i..j];
            tok.text = word;
            if (keywords.get(word)) |kw| {
                tok.t = kw;
            } else if (std.meta.stringToEnum(Builtin, word)) |b| {
                tok.t = .builtin;
                tok.b = b;
            } else if (j < src.len and src[j] == '(') {
                tok.t = .funcname;
            } else tok.t = .name;
            i = j;
        } else {
            const ops = [_]struct { []const u8, T }{
                .{ "&&", .and_ },       .{ "||", .or_ },        .{ "==", .eq },         .{ "!=", .ne },
                .{ "<=", .le },         .{ ">=", .ge },         .{ "!~", .nomatch },    .{ "++", .incr },
                .{ "--", .decr },       .{ ">>", .append },     .{ "+=", .add_assign }, .{ "-=", .sub_assign },
                .{ "*=", .mul_assign }, .{ "/=", .div_assign }, .{ "%=", .mod_assign }, .{ "^=", .pow_assign },
                .{ "**", .caret },      .{ "{", .lbrace },      .{ "}", .rbrace },      .{ "(", .lparen },
                .{ ")", .rparen },      .{ "[", .lbracket },    .{ "]", .rbracket },    .{ ";", .semicolon },
                .{ ",", .comma },       .{ "+", .plus },        .{ "-", .minus },       .{ "*", .star },
                .{ "/", .slash },       .{ "%", .percent },     .{ "^", .caret },       .{ "!", .not },
                .{ ">", .gt },          .{ "<", .lt },          .{ "|", .pipe },        .{ "?", .question },
                .{ ":", .colon },       .{ "~", .tilde },       .{ "$", .dollar },      .{ "=", .assign },
            };
            for (ops) |op| {
                if (std.mem.startsWith(u8, src[i..], op[0])) {
                    tok.t = op[1];
                    i += op[0].len;
                    break;
                }
            } else return syntaxError(line, "unexpected character '{c}'", .{c});
        }
        try toks.append(a, tok);
    }
}

// A / starts a regular expression unless it follows a value.
fn regexAllowed(toks: []const Token) bool {
    if (toks.len == 0) return true;
    return switch (toks[toks.len - 1].t) {
        .name, .number, .string, .rparen, .rbracket, .dollar, .incr, .decr, .builtin, .ere => false,
        else => true,
    };
}

// THE PROGRAM AS A TREE

const Lv = union(enum) { global: u32, local: u32 };

const Cmp = enum { lt, le, eq, ne, gt, ge };

const GetSrc = enum { main, file, command };

const Expr = union(enum) {
    num: f64,
    str: []const u8,
    ere: u32, // index into the regexes; alone it means $0 ~ /.../
    var_: Lv,
    field: *Expr,
    index: struct { v: Lv, subs: []*Expr },
    in_: struct { subs: []*Expr, v: Lv },
    assign: struct { op: u8, target: *Expr, value: *Expr },
    cond: struct { c: *Expr, a: *Expr, b: *Expr },
    and_: [2]*Expr,
    or_: [2]*Expr,
    not: *Expr,
    arith: struct { op: u8, l: *Expr, r: *Expr },
    cmp: struct { op: Cmp, l: *Expr, r: *Expr },
    match: struct { negate: bool, l: *Expr, r: *Expr },
    concat: [2]*Expr,
    neg: *Expr,
    pos: *Expr,
    incdec: struct { target: *Expr, delta: f64, post: bool },
    call: struct { func: u32, args: []*Expr },
    builtin: struct { b: Builtin, args: []*Expr },
    getline: struct { src: GetSrc, target: ?*Expr, from: ?*Expr },
    group: *Expr,
};

const Redir = enum { none, file, append, pipe };

const Print = struct { args: []*Expr, redir: Redir, dest: ?*Expr };

const Stmt = union(enum) {
    expr: *Expr,
    print: Print,
    printf: Print,
    if_: struct { c: *Expr, a: *Stmt, b: ?*Stmt },
    while_: struct { c: *Expr, body: *Stmt },
    do_: struct { body: *Stmt, c: *Expr },
    for_: struct { init: ?*Expr, c: ?*Expr, step: ?*Expr, body: *Stmt },
    for_in: struct { v: *Expr, arr: Lv, body: *Stmt },
    block: []*Stmt,
    next,
    nextfile,
    break_,
    continue_,
    exit: ?*Expr,
    return_: ?*Expr,
    delete: struct { v: Lv, subs: ?[]*Expr },
};

const Item = struct { pattern: ?*Expr, end_pattern: ?*Expr, action: ?*Stmt };

const Func = struct { name: []const u8, nparams: u32 = 0, body: ?*Stmt = null, line: u32 = 0 };

// awk's own variables, at fixed places:
const NR = 0;
const NF = 1;
const FNR = 2;
const FS = 3;
const OFS = 4;
const ORS = 5;
const RS = 6;
const FILENAME = 7;
const SUBSEP = 8;
const RSTART = 9;
const RLENGTH = 10;
const CONVFMT = 11;
const OFMT = 12;
const ENVIRON = 13;
const ARGC = 14;
const ARGV = 15;
const special_names = [_][]const u8{ "NR", "NF", "FNR", "FS", "OFS", "ORS", "RS", "FILENAME", "SUBSEP", "RSTART", "RLENGTH", "CONVFMT", "OFMT", "ENVIRON", "ARGC", "ARGV" };

const Program = struct {
    begin: std.ArrayListUnmanaged(*Stmt) = .{},
    end: std.ArrayListUnmanaged(*Stmt) = .{},
    items: std.ArrayListUnmanaged(Item) = .{},
    funcs: std.ArrayListUnmanaged(Func) = .{},
    globals: std.ArrayListUnmanaged([]const u8) = .{},
    regexes: std.ArrayListUnmanaged(regex.Regex) = .{},
};

const Parser = struct {
    a: Allocator,
    toks: []Token,
    i: usize = 0,
    prog: *Program,
    global_index: std.StringHashMapUnmanaged(u32) = .{},
    func_index: std.StringHashMapUnmanaged(u32) = .{},
    params: ?[]const []const u8 = null,
    in_print: bool = false, // > and | end an expression: they redirect print

    fn peek(self: *Parser) Token {
        return self.toks[self.i];
    }

    fn peekAt(self: *Parser, k: usize) T {
        return if (self.i + k < self.toks.len) self.toks[self.i + k].t else .eof;
    }

    fn advance(self: *Parser) Token {
        const t = self.toks[self.i];
        if (t.t != .eof) self.i += 1;
        return t;
    }

    fn fail(self: *Parser, what: []const u8) Err {
        const t = self.peek();
        return switch (t.t) {
            .eof => syntaxError(t.line, "{s}: unexpected end of program", .{what}),
            .newline => syntaxError(t.line, "{s}: unexpected newline", .{what}),
            .string => syntaxError(t.line, "{s}: unexpected string \"{s}\"", .{ what, t.text }),
            .number => syntaxError(t.line, "{s}: unexpected number", .{what}),
            else => if (t.text.len > 0)
                syntaxError(t.line, "{s}: unexpected '{s}'", .{ what, t.text })
            else
                syntaxError(t.line, "{s}: unexpected {s}", .{ what, @tagName(t.t) }),
        };
    }

    fn expect(self: *Parser, t: T, what: []const u8) Err!void {
        if (self.peek().t != t) return self.fail(what);
        _ = self.advance();
    }

    fn optNewlines(self: *Parser) void {
        while (self.peek().t == .newline) _ = self.advance();
    }

    fn skipTerminators(self: *Parser) void {
        while (self.peek().t == .newline or self.peek().t == .semicolon) _ = self.advance();
    }

    fn new(self: *Parser, e: Expr) Err!*Expr {
        const p = try self.a.create(Expr);
        p.* = e;
        return p;
    }

    fn newStmt(self: *Parser, s: Stmt) Err!*Stmt {
        const p = try self.a.create(Stmt);
        p.* = s;
        return p;
    }

    fn variable(self: *Parser, name: []const u8) Err!Lv {
        if (self.params) |params| {
            for (params, 0..) |p, k| if (std.mem.eql(u8, p, name)) return .{ .local = @intCast(k) };
        }
        const entry = try self.global_index.getOrPut(self.a, name);
        if (!entry.found_existing) {
            entry.value_ptr.* = @intCast(self.prog.globals.items.len);
            try self.prog.globals.append(self.a, name);
        }
        return .{ .global = entry.value_ptr.* };
    }

    fn function(self: *Parser, name: []const u8, line: u32) Err!u32 {
        const entry = try self.func_index.getOrPut(self.a, name);
        if (!entry.found_existing) {
            entry.value_ptr.* = @intCast(self.prog.funcs.items.len);
            try self.prog.funcs.append(self.a, .{ .name = name, .line = line });
        }
        return entry.value_ptr.*;
    }

    fn program(self: *Parser) Err!void {
        for (special_names) |n| _ = try self.variable(n);
        while (true) {
            self.skipTerminators();
            const t = self.peek();
            switch (t.t) {
                .eof => break,
                .kw_function => try self.functionDef(),
                .kw_begin, .kw_end => {
                    _ = self.advance();
                    self.optNewlines();
                    const b = try self.block();
                    if (t.t == .kw_begin) try self.prog.begin.append(self.a, b) else try self.prog.end.append(self.a, b);
                },
                else => {
                    var item: Item = .{ .pattern = null, .end_pattern = null, .action = null };
                    if (t.t != .lbrace) {
                        item.pattern = try self.expr();
                        if (self.peek().t == .comma) {
                            _ = self.advance();
                            self.optNewlines();
                            item.end_pattern = try self.expr();
                        }
                    }
                    if (self.peek().t == .lbrace) item.action = try self.block();
                    try self.prog.items.append(self.a, item);
                },
            }
            // After a pattern without an action, the line must end:
            if (self.i > 0 and self.toks[self.i - 1].t != .rbrace) {
                const after = self.peek().t;
                if (after != .newline and after != .semicolon and after != .eof) return self.fail("syntax error");
            }
        }
        for (self.prog.funcs.items) |f| {
            if (f.body == null) return syntaxError(f.line, "function {s} is not defined", .{f.name});
        }
    }

    fn functionDef(self: *Parser) Err!void {
        _ = self.advance();
        const name_tok = self.advance();
        if (name_tok.t != .name and name_tok.t != .funcname) return syntaxError(name_tok.line, "bad function name", .{});
        const index = try self.function(name_tok.text, name_tok.line);
        if (self.prog.funcs.items[index].body != null) return syntaxError(name_tok.line, "function {s} defined twice", .{name_tok.text});
        try self.expect(.lparen, "function");
        var params: std.ArrayListUnmanaged([]const u8) = .{};
        while (self.peek().t != .rparen) {
            self.optNewlines();
            const p = self.advance();
            if (p.t != .name) return syntaxError(p.line, "bad parameter name", .{});
            try params.append(self.a, p.text);
            self.optNewlines();
            if (self.peek().t == .comma) _ = self.advance() else break;
        }
        try self.expect(.rparen, "function");
        self.optNewlines();
        self.params = params.items;
        const b = try self.block();
        self.params = null;
        const f = &self.prog.funcs.items[index];
        f.nparams = @intCast(params.items.len);
        f.body = b;
    }

    fn block(self: *Parser) Err!*Stmt {
        try self.expect(.lbrace, "block");
        var list: std.ArrayListUnmanaged(*Stmt) = .{};
        while (true) {
            self.skipTerminators();
            if (self.peek().t == .rbrace) {
                _ = self.advance();
                break;
            }
            try list.append(self.a, try self.statement());
        }
        return self.newStmt(.{ .block = list.items });
    }

    fn endSimple(self: *Parser) Err!void {
        switch (self.peek().t) {
            .semicolon, .newline => _ = self.advance(),
            .rbrace, .eof => {},
            else => return self.fail("syntax error"),
        }
    }

    // On the same line or the next.
    fn body(self: *Parser) Err!*Stmt {
        if (self.peek().t == .semicolon) {
            _ = self.advance();
            return self.newStmt(.{ .block = &.{} });
        }
        self.optNewlines();
        return self.statement();
    }

    fn statement(self: *Parser) Err!*Stmt {
        const t = self.peek();
        switch (t.t) {
            .lbrace => return self.block(),
            .semicolon => {
                _ = self.advance();
                return self.newStmt(.{ .block = &.{} });
            },
            .kw_if => {
                _ = self.advance();
                try self.expect(.lparen, "if");
                const c = try self.expr();
                try self.expect(.rparen, "if");
                const a = try self.body();
                // else, maybe after ; and newlines:
                var j = self.i;
                while (self.toks[j].t == .newline or self.toks[j].t == .semicolon) j += 1;
                var b: ?*Stmt = null;
                if (self.toks[j].t == .kw_else) {
                    self.i = j + 1;
                    b = try self.body();
                }
                return self.newStmt(.{ .if_ = .{ .c = c, .a = a, .b = b } });
            },
            .kw_while => {
                _ = self.advance();
                try self.expect(.lparen, "while");
                const c = try self.expr();
                try self.expect(.rparen, "while");
                return self.newStmt(.{ .while_ = .{ .c = c, .body = try self.body() } });
            },
            .kw_do => {
                _ = self.advance();
                const b = try self.body();
                self.skipTerminators();
                try self.expect(.kw_while, "do");
                try self.expect(.lparen, "do");
                const c = try self.expr();
                try self.expect(.rparen, "do");
                try self.endSimple();
                return self.newStmt(.{ .do_ = .{ .body = b, .c = c } });
            },
            .kw_for => return self.forStatement(),
            else => {
                const s = try self.simpleStatement();
                try self.endSimple();
                return s;
            },
        }
    }

    fn forStatement(self: *Parser) Err!*Stmt {
        _ = self.advance();
        try self.expect(.lparen, "for");
        if (self.peek().t == .name and self.peekAt(1) == .kw_in and self.peekAt(2) == .name and self.peekAt(3) == .rparen) {
            const v = try self.new(.{ .var_ = try self.variable(self.advance().text) });
            _ = self.advance();
            const arr = try self.variable(self.advance().text);
            _ = self.advance();
            return self.newStmt(.{ .for_in = .{ .v = v, .arr = arr, .body = try self.body() } });
        }
        const init = if (self.peek().t == .semicolon) null else try self.expr();
        try self.expect(.semicolon, "for");
        self.optNewlines();
        const c = if (self.peek().t == .semicolon) null else try self.expr();
        try self.expect(.semicolon, "for");
        self.optNewlines();
        const step = if (self.peek().t == .rparen) null else try self.expr();
        try self.expect(.rparen, "for");
        return self.newStmt(.{ .for_ = .{ .init = init, .c = c, .step = step, .body = try self.body() } });
    }

    fn atEnd(t: T) bool {
        return t == .newline or t == .semicolon or t == .rbrace or t == .eof;
    }

    fn simpleStatement(self: *Parser) Err!*Stmt {
        const t = self.peek();
        switch (t.t) {
            .kw_print, .kw_printf => return self.printStatement(),
            .kw_next => {
                _ = self.advance();
                return self.newStmt(.next);
            },
            .kw_nextfile => {
                _ = self.advance();
                return self.newStmt(.nextfile);
            },
            .kw_break => {
                _ = self.advance();
                return self.newStmt(.break_);
            },
            .kw_continue => {
                _ = self.advance();
                return self.newStmt(.continue_);
            },
            .kw_exit, .kw_return => {
                _ = self.advance();
                const e = if (atEnd(self.peek().t)) null else try self.expr();
                return self.newStmt(if (t.t == .kw_exit) .{ .exit = e } else .{ .return_ = e });
            },
            .kw_delete => {
                _ = self.advance();
                const name = self.advance();
                if (name.t != .name) return syntaxError(name.line, "delete needs an array", .{});
                const v = try self.variable(name.text);
                var subs: ?[]*Expr = null;
                if (self.peek().t == .lbracket) {
                    _ = self.advance();
                    subs = try self.exprList(.rbracket);
                    try self.expect(.rbracket, "delete");
                }
                return self.newStmt(.{ .delete = .{ .v = v, .subs = subs } });
            },
            else => return self.newStmt(.{ .expr = try self.expr() }),
        }
    }

    fn printEnd(t: T) bool {
        return atEnd(t) or t == .gt or t == .append or t == .pipe;
    }

    fn printStatement(self: *Parser) Err!*Stmt {
        const is_printf = self.advance().t == .kw_printf;
        var args: []*Expr = &.{};
        if (!printEnd(self.peek().t)) {
            var done = false;
            if (self.peek().t == .lparen) {
                // print (a, b) > "file": the parentheses hold the list:
                const save = self.i;
                _ = self.advance();
                const old = self.in_print;
                self.in_print = false;
                const list = self.exprList(.rparen) catch null;
                self.in_print = old;
                if (list != null and self.peek().t == .rparen and printEnd(self.peekAt(1))) {
                    _ = self.advance();
                    args = list.?;
                    done = true;
                } else self.i = save;
            }
            if (!done) {
                self.in_print = true;
                defer self.in_print = false;
                args = try self.exprList(.eof);
            }
        }
        var p: Print = .{ .args = args, .redir = .none, .dest = null };
        switch (self.peek().t) {
            .gt, .append, .pipe => |r| {
                _ = self.advance();
                p.redir = switch (r) {
                    .gt => .file,
                    .append => .append,
                    else => .pipe,
                };
                self.in_print = true;
                defer self.in_print = false;
                p.dest = try self.concat();
            },
            else => {},
        }
        if (is_printf and p.args.len == 0) return self.fail("printf needs a format");
        return self.newStmt(if (is_printf) .{ .printf = p } else .{ .print = p });
    }

    fn exprList(self: *Parser, close: T) Err![]*Expr {
        var list: std.ArrayListUnmanaged(*Expr) = .{};
        if (self.peek().t == close and close != .eof) return list.items;
        while (true) {
            try list.append(self.a, try self.expr());
            if (self.peek().t != .comma) break;
            _ = self.advance();
            self.optNewlines();
        }
        return list.items;
    }

    fn isLvalue(e: *const Expr) bool {
        return e.* == .var_ or e.* == .field or e.* == .index;
    }

    fn expr(self: *Parser) Err!*Expr {
        const lhs = try self.ternary();
        const op: u8 = switch (self.peek().t) {
            .assign => '=',
            .add_assign => '+',
            .sub_assign => '-',
            .mul_assign => '*',
            .div_assign => '/',
            .mod_assign => '%',
            .pow_assign => '^',
            else => return lhs,
        };
        if (!isLvalue(lhs)) return lhs;
        _ = self.advance();
        self.optNewlines();
        const rhs = try self.expr();
        return self.new(.{ .assign = .{ .op = op, .target = lhs, .value = rhs } });
    }

    fn ternary(self: *Parser) Err!*Expr {
        const c = try self.orExpr();
        if (self.peek().t != .question) return c;
        _ = self.advance();
        self.optNewlines();
        const a = try self.expr();
        self.optNewlines();
        try self.expect(.colon, "?:");
        self.optNewlines();
        const b = try self.expr();
        return self.new(.{ .cond = .{ .c = c, .a = a, .b = b } });
    }

    fn orExpr(self: *Parser) Err!*Expr {
        var l = try self.andExpr();
        while (self.peek().t == .or_) {
            _ = self.advance();
            self.optNewlines();
            l = try self.new(.{ .or_ = .{ l, try self.andExpr() } });
        }
        return l;
    }

    fn andExpr(self: *Parser) Err!*Expr {
        var l = try self.inExpr();
        while (self.peek().t == .and_) {
            _ = self.advance();
            self.optNewlines();
            l = try self.new(.{ .and_ = .{ l, try self.inExpr() } });
        }
        return l;
    }

    fn inExpr(self: *Parser) Err!*Expr {
        var l = try self.matchExpr();
        while (self.peek().t == .kw_in) {
            _ = self.advance();
            const name = self.advance();
            if (name.t != .name) return syntaxError(name.line, "in needs an array", .{});
            const subs = try self.a.alloc(*Expr, 1);
            subs[0] = l;
            l = try self.new(.{ .in_ = .{ .subs = subs, .v = try self.variable(name.text) } });
        }
        return l;
    }

    fn matchExpr(self: *Parser) Err!*Expr {
        var l = try self.cmpExpr();
        while (self.peek().t == .tilde or self.peek().t == .nomatch) {
            const negate = self.advance().t == .nomatch;
            l = try self.new(.{ .match = .{ .negate = negate, .l = l, .r = try self.cmpExpr() } });
        }
        return l;
    }

    fn cmpExpr(self: *Parser) Err!*Expr {
        var l = try self.concat();
        // "command" | getline [var]:
        while (self.peek().t == .pipe and self.peekAt(1) == .kw_getline) {
            _ = self.advance();
            _ = self.advance();
            const target = try self.getlineTarget();
            l = try self.new(.{ .getline = .{ .src = .command, .target = target, .from = l } });
        }
        const op: Cmp = switch (self.peek().t) {
            .lt => .lt,
            .le => .le,
            .eq => .eq,
            .ne => .ne,
            .ge => .ge,
            .gt => if (self.in_print) return l else .gt,
            else => return l,
        };
        _ = self.advance();
        return self.new(.{ .cmp = .{ .op = op, .l = l, .r = try self.concat() } });
    }

    fn startsOperand(self: *Parser) bool {
        return switch (self.peek().t) {
            .number, .string, .ere, .name, .funcname, .builtin, .dollar, .lparen, .not, .incr, .decr => true,
            .minus, .plus => false,
            .kw_in => false,
            else => false,
        };
    }

    fn concat(self: *Parser) Err!*Expr {
        var l = try self.additive();
        while (self.startsOperand() and self.peek().t != .not) {
            l = try self.new(.{ .concat = .{ l, try self.additive() } });
        }
        return l;
    }

    fn additive(self: *Parser) Err!*Expr {
        var l = try self.multiplicative();
        while (self.peek().t == .plus or self.peek().t == .minus) {
            const op: u8 = if (self.advance().t == .plus) '+' else '-';
            l = try self.new(.{ .arith = .{ .op = op, .l = l, .r = try self.multiplicative() } });
        }
        return l;
    }

    fn multiplicative(self: *Parser) Err!*Expr {
        var l = try self.unary();
        while (true) {
            const op: u8 = switch (self.peek().t) {
                .star => '*',
                .slash => '/',
                .percent => '%',
                else => return l,
            };
            _ = self.advance();
            l = try self.new(.{ .arith = .{ .op = op, .l = l, .r = try self.unary() } });
        }
    }

    fn unary(self: *Parser) Err!*Expr {
        switch (self.peek().t) {
            .not => {
                _ = self.advance();
                return self.new(.{ .not = try self.unary() });
            },
            .minus => {
                _ = self.advance();
                return self.new(.{ .neg = try self.unary() });
            },
            .plus => {
                _ = self.advance();
                return self.new(.{ .pos = try self.unary() });
            },
            else => return self.power(),
        }
    }

    fn power(self: *Parser) Err!*Expr {
        const base = try self.postfix();
        if (self.peek().t != .caret) return base;
        _ = self.advance();
        // Right to left; the exponent may have a sign:
        const exponent = switch (self.peek().t) {
            .minus => blk: {
                _ = self.advance();
                break :blk try self.new(.{ .neg = try self.power() });
            },
            .plus => blk: {
                _ = self.advance();
                break :blk try self.power();
            },
            else => try self.power(),
        };
        return self.new(.{ .arith = .{ .op = '^', .l = base, .r = exponent } });
    }

    fn postfix(self: *Parser) Err!*Expr {
        if (self.peek().t == .incr or self.peek().t == .decr) {
            const delta: f64 = if (self.advance().t == .incr) 1 else -1;
            const target = try self.dollar();
            if (!isLvalue(target)) return self.fail("++ and -- need a variable");
            return self.new(.{ .incdec = .{ .target = target, .delta = delta, .post = false } });
        }
        const e = try self.dollar();
        if ((self.peek().t == .incr or self.peek().t == .decr) and isLvalue(e)) {
            const delta: f64 = if (self.advance().t == .incr) 1 else -1;
            return self.new(.{ .incdec = .{ .target = e, .delta = delta, .post = true } });
        }
        return e;
    }

    fn dollar(self: *Parser) Err!*Expr {
        if (self.peek().t != .dollar) return self.primary();
        _ = self.advance();
        const operand = switch (self.peek().t) {
            .incr, .decr => try self.postfix(),
            .minus => blk: {
                _ = self.advance();
                break :blk try self.new(.{ .neg = try self.dollar() });
            },
            else => try self.dollar(),
        };
        return self.new(.{ .field = operand });
    }

    fn getlineTarget(self: *Parser) Err!?*Expr {
        if (self.peek().t != .name and self.peek().t != .dollar) return null;
        const e = try self.dollar();
        if (!isLvalue(e)) return self.fail("getline");
        return e;
    }

    fn primary(self: *Parser) Err!*Expr {
        const t = self.advance();
        switch (t.t) {
            .number => return self.new(.{ .num = t.num }),
            .string => return self.new(.{ .str = t.text }),
            .ere => {
                const re = regex.compile(gpa, t.text, .{}) catch return syntaxError(t.line, "bad regular expression /{s}/", .{t.text});
                try self.prog.regexes.append(self.a, re);
                return self.new(.{ .ere = @intCast(self.prog.regexes.items.len - 1) });
            },
            .lparen => {
                const old = self.in_print;
                self.in_print = false;
                defer self.in_print = old;
                const list = try self.exprList(.rparen);
                try self.expect(.rparen, "( )");
                if (list.len > 1) {
                    if (self.peek().t != .kw_in) return self.fail("(a, b) needs in");
                    _ = self.advance();
                    const name = self.advance();
                    if (name.t != .name) return syntaxError(name.line, "in needs an array", .{});
                    return self.new(.{ .in_ = .{ .subs = list, .v = try self.variable(name.text) } });
                }
                if (list.len == 0) return self.fail("( )");
                return self.new(.{ .group = list[0] });
            },
            .name => {
                const v = try self.variable(t.text);
                if (self.peek().t == .lbracket) {
                    _ = self.advance();
                    const old = self.in_print;
                    self.in_print = false;
                    defer self.in_print = old;
                    const subs = try self.exprList(.rbracket);
                    try self.expect(.rbracket, "[ ]");
                    if (subs.len == 0) return self.fail("[ ]");
                    return self.new(.{ .index = .{ .v = v, .subs = subs } });
                }
                return self.new(.{ .var_ = v });
            },
            .funcname => {
                const index = try self.function(t.text, t.line);
                try self.expect(.lparen, "call");
                const old = self.in_print;
                self.in_print = false;
                defer self.in_print = old;
                const args = try self.exprList(.rparen);
                try self.expect(.rparen, "call");
                return self.new(.{ .call = .{ .func = index, .args = args } });
            },
            .builtin => {
                var args: []*Expr = &.{};
                if (self.peek().t == .lparen) {
                    _ = self.advance();
                    const old = self.in_print;
                    self.in_print = false;
                    defer self.in_print = old;
                    args = try self.exprList(.rparen);
                    try self.expect(.rparen, t.text);
                } else if (t.b != .length) return syntaxError(t.line, "{s} needs ( )", .{t.text});
                try checkArgs(t, args);
                return self.new(.{ .builtin = .{ .b = t.b, .args = args } });
            },
            .kw_getline => {
                const target = try self.getlineTarget();
                if (self.peek().t == .lt) {
                    _ = self.advance();
                    const from = try self.postfix();
                    return self.new(.{ .getline = .{ .src = .file, .target = target, .from = from } });
                }
                return self.new(.{ .getline = .{ .src = .main, .target = target, .from = null } });
            },
            else => {
                self.i -= 1;
                return self.fail("syntax error");
            },
        }
    }

    fn checkArgs(t: Token, args: []*Expr) Err!void {
        const range: [2]usize = switch (t.b) {
            .length => .{ 0, 1 },
            .substr => .{ 2, 3 },
            .index, .atan2 => .{ 2, 2 },
            .split => .{ 2, 3 },
            .sub, .gsub => .{ 2, 3 },
            .match => .{ 2, 2 },
            .sprintf => .{ 1, 255 },
            .sin, .cos, .exp, .log, .sqrt, .int, .tolower, .toupper, .system, .close => .{ 1, 1 },
            .rand => .{ 0, 0 },
            .srand, .fflush => .{ 0, 1 },
        };
        if (args.len < range[0] or args.len > range[1]) return syntaxError(t.line, "{s}: wrong number of arguments", .{t.text});
        if (t.b == .split and args[1].* != .var_) return syntaxError(t.line, "split needs an array", .{});
        if ((t.b == .sub or t.b == .gsub) and args.len == 3 and !isLvalue(args[2])) return syntaxError(t.line, "{s} needs a variable to change", .{t.text});
    }
};

// INPUT

const Input = struct {
    reader: ?text.Reader = null, // a file or the standard input
    data: []u8 = &.{}, // or a command's output (owned)
    pos: usize = 0,

    fn byte(self: *Input) ?u8 {
        if (self.reader) |*r| return r.readByte() catch null;
        if (self.pos >= self.data.len) return null;
        const c = self.data[self.pos];
        self.pos += 1;
        return c;
    }

    fn peekByte(self: *Input) ?u8 {
        if (self.reader) |*r| return r.peekByte() catch null;
        return if (self.pos < self.data.len) self.data[self.pos] else null;
    }

    // rs "" means blank lines.
    fn record(self: *Input, rs: []const u8, out: *std.ArrayListUnmanaged(u8)) Allocator.Error!bool {
        out.clearRetainingCapacity();
        if (rs.len == 0) {
            // Paragraphs: blank lines skipped before, ended by one or more:
            while (self.peekByte()) |c| {
                if (c != '\n' and c != '\r') break;
                _ = self.byte();
            }
            var any = false;
            while (self.byte()) |c| {
                any = true;
                if (c == '\r') continue;
                if (c == '\n' and self.peekByte() == '\n') {
                    while (self.peekByte()) |n| {
                        if (n != '\n' and n != '\r') break;
                        _ = self.byte();
                    }
                    break;
                }
                if (c == '\n' and self.peekByte() == '\r') {
                    _ = self.byte();
                    if (self.peekByte() == '\n') {
                        while (self.peekByte()) |n| {
                            if (n != '\n' and n != '\r') break;
                            _ = self.byte();
                        }
                        break;
                    }
                }
                try out.append(gpa, c);
            }
            while (out.items.len > 0 and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
            return any;
        }
        if (rs[0] == '\n' and self.reader != null) {
            return self.reader.?.readLine(gpa, out) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return false,
            };
        }
        var any = false;
        while (self.byte()) |c| {
            any = true;
            if (c == rs[0]) break;
            try out.append(gpa, c);
        }
        if (rs[0] == '\n' and out.items.len > 0 and out.items[out.items.len - 1] == '\r') out.items.len -= 1;
        return any;
    }

    fn close(self: *Input) void {
        if (self.reader) |*r| r.close();
        self.reader = null;
        gpa.free(self.data);
        self.data = &.{};
    }
};

const Stream = struct {
    name: []u8,
    redir: Redir,
    file: ?zdos.File = null,
    data: std.ArrayListUnmanaged(u8) = .{},
    screen: bool = false, // /dev/stderr
};

// THE INTERPRETER

const Flow = enum { normal, next, nextfile, exit, return_, break_, continue_ };

const SepKind = enum { space, char, regex, empty };

const Awk = struct {
    sh: *Shell,
    arena: std.heap.ArenaAllocator,
    prog: Program = .{},
    temp: Temp = .{},
    globals: []Slot = &.{},
    frame: []Slot = &.{},
    depth: u32 = 0,
    dyn: std.StringHashMapUnmanaged(regex.Regex) = .{},
    record: std.ArrayListUnmanaged(u8) = .{},
    fields: std.ArrayListUnmanaged(Cell) = .{},
    nf: usize = 0,
    split_done: bool = true,
    record_stale: bool = false, // fields changed: $0 must be joined again
    main: ?Input = null,
    argv_next: usize = 1,
    main_opened: bool = false,
    inputs: std.StringHashMapUnmanaged(*Input) = .{},
    streams: std.ArrayListUnmanaged(*Stream) = .{},
    out: text.Output = .{},
    exit_code: u8 = 0,
    ret: Cell = .{},
    range_on: []bool = &.{},
    seed: f64 = 0,
    rand_state: u64 = 0x2545F4914F6CDD1D,
    steps: u32 = 0,
    // next, exit ... inside a function, handed on after the statement:
    pending_flow: Flow = .normal,

    fn deinit(self: *Awk) void {
        self.out.deinit();
        for (self.streams.items) |s| {
            if (s.file) |f| f.close();
            s.data.deinit(gpa);
            gpa.free(s.name);
            gpa.destroy(s);
        }
        self.streams.deinit(gpa);
        var it = self.inputs.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.close();
            gpa.destroy(e.value_ptr.*);
            gpa.free(e.key_ptr.*);
        }
        self.inputs.deinit(gpa);
        if (self.main) |*m| m.close();
        for (self.globals) |*s| freeSlot(s);
        gpa.free(self.globals);
        for (self.prog.regexes.items) |*r| r.deinit(gpa);
        var dit = self.dyn.iterator();
        while (dit.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(gpa);
        }
        self.dyn.deinit(gpa);
        for (self.fields.items) |*c| c.deinit();
        self.fields.deinit(gpa);
        self.record.deinit(gpa);
        self.ret.deinit();
        self.temp.deinit();
        self.arena.deinit();
    }

    fn ta(self: *Awk) Allocator {
        return self.temp.allocator();
    }

    fn fatal(comptime fmt: []const u8, args: anytype) Err {
        errout.printf("awk: " ++ fmt ++ "\n", args);
        return error.Fatal;
    }

    // VARIABLES

    fn slotOf(self: *Awk, lv: Lv) *Slot {
        var s = switch (lv) {
            .global => |g| &self.globals[g],
            .local => |l| &self.frame[l],
        };
        while (s.* == .ref) s = s.ref;
        return s;
    }

    fn getVar(self: *Awk, lv: Lv) Err!Value {
        if (lv == .global and lv.global == NF) try self.split();
        const s = self.slotOf(lv);
        return switch (s.*) {
            .uninit => .{},
            .cell => |c| c.v,
            .array => fatal("can't use an array as a value", .{}),
            .ref => unreachable,
        };
    }

    fn setVar(self: *Awk, lv: Lv, v: Value) Err!void {
        if (lv == .global and lv.global == FS and !self.split_done) try self.split();
        // A local that refers to a caller's variable becomes its own:
        var s = switch (lv) {
            .global => |g| &self.globals[g],
            .local => |l| &self.frame[l],
        };
        if (s.* == .ref) {
            const target = blk: {
                var t = s;
                while (t.* == .ref) t = t.ref;
                break :blk t;
            };
            if (target.* == .uninit and lv == .local) {
                s.* = .uninit;
            } else s = target;
        }
        switch (s.*) {
            .array => return fatal("can't assign to an array", .{}),
            .uninit => s.* = .{ .cell = .{} },
            else => {},
        }
        try s.cell.set(v);
        if (lv == .global and lv.global == NF) try self.setNF(self.toNum(v));
    }

    fn arrayOf(self: *Awk, lv: Lv) Err!*Array {
        const s = self.slotOf(lv);
        switch (s.*) {
            .array => |arr| return arr,
            .uninit => {
                const arr = try gpa.create(Array);
                arr.* = .{};
                s.* = .{ .array = arr };
                return arr;
            },
            .cell => |c| {
                if (c.v.kind != .uninit) return fatal("can't use a scalar as an array", .{});
                const arr = try gpa.create(Array);
                arr.* = .{};
                s.* = .{ .array = arr };
                return arr;
            },
            .ref => unreachable,
        }
    }

    fn subscript(self: *Awk, subs: []*Expr) Err![]const u8 {
        if (subs.len == 1) return self.toStr(try self.eval(subs[0]));
        var out: std.ArrayListUnmanaged(u8) = .{};
        const sep = self.special(SUBSEP);
        for (subs, 0..) |e, k| {
            if (k > 0) try out.appendSlice(self.ta(), sep);
            try out.appendSlice(self.ta(), try self.toStr(try self.eval(e)));
        }
        return out.items;
    }

    // Made if it isn't there, as referring to it does in awk.
    fn element(_: *Awk, arr: *Array, key: []const u8) Err!*Cell {
        const entry = try arr.getOrPut(gpa, key);
        if (!entry.found_existing) {
            entry.key_ptr.* = gpa.dupe(u8, key) catch |err| {
                arr.removeByPtr(entry.key_ptr);
                return err;
            };
            entry.value_ptr.* = .{};
        }
        return entry.value_ptr;
    }

    // FS, OFS ...
    fn special(self: *Awk, index: u32) []const u8 {
        return switch (self.globals[index]) {
            .cell => |c| if (c.v.kind == .num) (self.numToStr(c.v.num, "%.6g") catch "") else c.v.str,
            else => "",
        };
    }

    fn setSpecialNum(self: *Awk, index: u32, n: f64) Err!void {
        try self.setVar(.{ .global = index }, Value.ofNum(n));
    }

    fn specialNum(self: *Awk, index: u32) f64 {
        return switch (self.globals[index]) {
            .cell => |c| self.toNum(c.v),
            else => 0,
        };
    }

    // CONVERSIONS

    fn toNum(_: *Awk, v: Value) f64 {
        return switch (v.kind) {
            .uninit => 0,
            .num, .strnum => v.num,
            .str => strToNum(v.str),
        };
    }

    fn numToStr(self: *Awk, n: f64, fmt: []const u8) Err![]const u8 {
        var out: format.Out = .{};
        try format.number(self.ta(), &out, n, fmt);
        return out.items;
    }

    fn toStr(self: *Awk, v: Value) Err![]const u8 {
        return if (v.kind == .num) self.numToStr(v.num, self.special(CONVFMT)) else v.str;
    }

    // For print: numbers with OFMT.
    fn toOutStr(self: *Awk, v: Value) Err![]const u8 {
        return if (v.kind == .num) self.numToStr(v.num, self.special(OFMT)) else v.str;
    }

    fn toBool(_: *Awk, v: Value) bool {
        return switch (v.kind) {
            .uninit => false,
            .num, .strnum => v.num != 0,
            .str => v.str.len > 0,
        };
    }

    fn compare(self: *Awk, a: Value, b: Value) Err!std.math.Order {
        const an = a.kind != .str;
        const bn = b.kind != .str;
        if (an and bn) {
            const x = self.toNum(a);
            const y = self.toNum(b);
            if (x < y) return .lt;
            if (x > y) return .gt;
            return .eq;
        }
        return std.mem.order(u8, try self.toStr(a), try self.toStr(b));
    }

    // FIELDS

    fn sepOf(self: *Awk, fs: []const u8) Err!struct { kind: SepKind, c: u8 = 0, re: ?*regex.Regex = null } {
        if (std.mem.eql(u8, fs, " ")) return .{ .kind = .space };
        if (fs.len == 0) return .{ .kind = .empty };
        if (fs.len == 1 and fs[0] != '\\') return .{ .kind = .char, .c = fs[0] };
        return .{ .kind = .regex, .re = try self.dynRegex(fs) };
    }

    // Pieces are slices of s.
    fn splitText(self: *Awk, s: []const u8, fs: []const u8, pieces: *std.ArrayListUnmanaged([]const u8)) Err!void {
        const sep = try self.sepOf(fs);
        const a = self.ta();
        switch (sep.kind) {
            .space => {
                var it = std.mem.tokenizeAny(u8, s, " \t\n");
                while (it.next()) |w| try pieces.append(a, w);
            },
            .empty => for (0..s.len) |k| try pieces.append(a, s[k .. k + 1]),
            .char => {
                if (s.len == 0) return;
                var it = std.mem.splitScalar(u8, s, sep.c);
                while (it.next()) |w| try pieces.append(a, w);
            },
            .regex => {
                if (s.len == 0) return;
                var start: usize = 0;
                var pos: usize = 0;
                while (pos <= s.len) {
                    const m = sep.re.?.search(s, pos) orelse break;
                    if (m.end == m.start) {
                        pos = m.start + 1;
                        continue;
                    }
                    try pieces.append(a, s[start..m.start]);
                    start = m.end;
                    pos = m.end;
                }
                try pieces.append(a, s[start..]);
            },
        }
    }

    fn split(self: *Awk) Err!void {
        if (self.split_done) return;
        self.split_done = true;
        const m = self.temp.mark();
        defer self.temp.release(m);
        var pieces: std.ArrayListUnmanaged([]const u8) = .{};
        try self.splitText(self.record.items, self.special(FS), &pieces);
        try self.setFieldCount(pieces.items.len);
        for (pieces.items, 0..) |p, k| try self.fields.items[k].set(Value.ofInput(p));
        self.nf = pieces.items.len;
        try self.globals[NF].cell.set(Value.ofNum(@floatFromInt(self.nf)));
    }

    fn setFieldCount(self: *Awk, n: usize) Err!void {
        while (self.fields.items.len > n) {
            var c = self.fields.pop().?;
            c.deinit();
        }
        while (self.fields.items.len < n) try self.fields.append(gpa, .{});
    }

    fn setRecord(self: *Awk, s: []const u8) Err!void {
        // s may be part of the record itself:
        const copy = try gpa.dupe(u8, s);
        defer gpa.free(copy);
        self.record.clearRetainingCapacity();
        try self.record.appendSlice(gpa, copy);
        self.split_done = false;
        self.record_stale = false;
    }

    fn rebuild(self: *Awk) Err!void {
        if (!self.record_stale) return;
        self.record_stale = false;
        const m = self.temp.mark();
        defer self.temp.release(m);
        const ofs = self.special(OFS);
        var out: std.ArrayListUnmanaged(u8) = .{};
        for (self.fields.items[0..self.nf], 0..) |c, k| {
            if (k > 0) try out.appendSlice(self.ta(), ofs);
            try out.appendSlice(self.ta(), try self.toOutStrConv(c.v));
        }
        self.record.clearRetainingCapacity();
        try self.record.appendSlice(gpa, out.items);
    }

    fn toOutStrConv(self: *Awk, v: Value) Err![]const u8 {
        return self.toStr(v);
    }

    fn getField(self: *Awk, i: usize) Err!Value {
        if (i == 0) {
            try self.rebuild();
            return Value.ofInput(self.record.items);
        }
        try self.split();
        if (i > self.nf) return .{};
        return self.fields.items[i - 1].v;
    }

    fn setField(self: *Awk, i: usize, v: Value) Err!void {
        if (i == 0) {
            return self.setRecord(try self.toStr(v));
        }
        try self.split();
        if (i > self.nf) {
            if (i > self.fields.items.len) try self.setFieldCount(i);
            for (self.fields.items[self.nf..i]) |*c| try c.set(Value.ofStr(""));
            self.nf = i;
            try self.globals[NF].cell.set(Value.ofNum(@floatFromInt(self.nf)));
        }
        var copy = v;
        if (v.kind == .num) copy = .{ .kind = .num, .num = v.num };
        try self.fields.items[i - 1].set(copy);
        self.record_stale = true;
    }

    fn setNF(self: *Awk, n: f64) Err!void {
        try self.split();
        const count: usize = if (n < 0) 0 else @intFromFloat(@min(n, 100000));
        if (count > self.fields.items.len) try self.setFieldCount(count);
        if (count > self.nf) {
            for (self.fields.items[self.nf..count]) |*c| try c.set(Value.ofStr(""));
        }
        self.nf = count;
        self.record_stale = true;
        try self.globals[NF].cell.set(Value.ofNum(@floatFromInt(count)));
    }

    fn fieldIndex(self: *Awk, e: *Expr) Err!usize {
        const n = self.toNum(try self.eval(e));
        if (n < 0 or std.math.isNan(n)) return fatal("field ${d} does not exist", .{n});
        if (n > 1e6) return fatal("field number too large", .{});
        return @intFromFloat(n);
    }

    fn dynRegex(self: *Awk, pattern: []const u8) Err!*regex.Regex {
        if (self.dyn.getPtr(pattern)) |r| return r;
        if (self.dyn.count() > 500) {
            var it = self.dyn.iterator();
            while (it.next()) |e| {
                gpa.free(e.key_ptr.*);
                e.value_ptr.deinit(gpa);
            }
            self.dyn.clearRetainingCapacity();
        }
        var re = regex.compile(gpa, pattern, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return fatal("bad regular expression: {s}", .{pattern}),
        };
        const key = gpa.dupe(u8, pattern) catch |err| {
            re.deinit(gpa);
            return err;
        };
        self.dyn.put(gpa, key, re) catch |err| {
            re.deinit(gpa);
            gpa.free(key);
            return err;
        };
        return self.dyn.getPtr(key).?;
    }

    fn regexOf(self: *Awk, e: *Expr) Err!*regex.Regex {
        if (e.* == .ere) return &self.prog.regexes.items[e.ere];
        return self.dynRegex(try self.toStr(try self.eval(e)));
    }

    fn eval(self: *Awk, e: *Expr) Err!Value {
        switch (e.*) {
            .num => |n| return Value.ofNum(n),
            .str => |s| return Value.ofStr(s),
            .ere => |r| {
                try self.rebuild();
                return Value.ofNum(@floatFromInt(@intFromBool(self.prog.regexes.items[r].isMatch(self.record.items))));
            },
            .group => |g| return self.eval(g),
            .var_ => |lv| return self.getVar(lv),
            .field => |f| return self.getField(try self.fieldIndex(f)),
            .index => |x| {
                const arr = try self.arrayOf(x.v);
                const key = try self.subscript(x.subs);
                return (try self.element(arr, key)).v;
            },
            .in_ => |x| {
                const arr = try self.arrayOf(x.v);
                const key = try self.subscript(x.subs);
                return Value.ofNum(@floatFromInt(@intFromBool(arr.contains(key))));
            },
            .assign => |x| return self.assign(x.op, x.target, x.value),
            .cond => |x| return if (self.toBool(try self.eval(x.c))) self.eval(x.a) else self.eval(x.b),
            .and_ => |x| return Value.ofNum(@floatFromInt(@intFromBool(self.toBool(try self.eval(x[0])) and self.toBool(try self.eval(x[1]))))),
            .or_ => |x| return Value.ofNum(@floatFromInt(@intFromBool(self.toBool(try self.eval(x[0])) or self.toBool(try self.eval(x[1]))))),
            .not => |x| return Value.ofNum(@floatFromInt(@intFromBool(!self.toBool(try self.eval(x))))),
            .arith => |x| {
                const l = self.toNum(try self.eval(x.l));
                const r = self.toNum(try self.eval(x.r));
                return Value.ofNum(try arith(x.op, l, r));
            },
            .cmp => |x| {
                const order = try self.compare(try self.eval(x.l), try self.eval(x.r));
                const result = switch (x.op) {
                    .lt => order == .lt,
                    .le => order != .gt,
                    .eq => order == .eq,
                    .ne => order != .eq,
                    .gt => order == .gt,
                    .ge => order != .lt,
                };
                return Value.ofNum(@floatFromInt(@intFromBool(result)));
            },
            .match => |x| {
                const s = try self.toStr(try self.eval(x.l));
                const re = try self.regexOf(x.r);
                return Value.ofNum(@floatFromInt(@intFromBool(re.isMatch(s) != x.negate)));
            },
            .concat => |x| {
                const l = try self.toStr(try self.eval(x[0]));
                const r = try self.toStr(try self.eval(x[1]));
                return Value.ofStr(try std.mem.concat(self.ta(), u8, &.{ l, r }));
            },
            .neg => |x| return Value.ofNum(-self.toNum(try self.eval(x))),
            .pos => |x| return Value.ofNum(self.toNum(try self.eval(x))),
            .incdec => |x| {
                const old = self.toNum(try self.eval(x.target));
                try self.store(x.target, Value.ofNum(old + x.delta));
                return Value.ofNum(if (x.post) old else old + x.delta);
            },
            .call => |x| return self.call(x.func, x.args),
            .builtin => |x| return self.builtin(x.b, x.args),
            .getline => |x| return self.getline(x.src, x.target, x.from),
        }
    }

    fn arith(op: u8, l: f64, r: f64) Err!f64 {
        return switch (op) {
            '+' => l + r,
            '-' => l - r,
            '*' => l * r,
            '/' => if (r == 0) fatal("division by zero", .{}) else l / r,
            '%' => if (r == 0) fatal("division by zero in %", .{}) else @rem(l, r),
            '^' => std.math.pow(f64, l, r),
            else => unreachable,
        };
    }

    fn assign(self: *Awk, op: u8, target: *Expr, value: *Expr) Err!Value {
        var v = try self.eval(value);
        if (op != '=') {
            const old = self.toNum(try self.eval(target));
            v = Value.ofNum(try arith(op, old, self.toNum(v)));
        }
        try self.store(target, v);
        return v;
    }

    fn store(self: *Awk, target: *Expr, v: Value) Err!void {
        switch (target.*) {
            .var_ => |lv| try self.setVar(lv, v),
            .field => |f| try self.setField(try self.fieldIndex(f), v),
            .index => |x| {
                const arr = try self.arrayOf(x.v);
                const key = try self.subscript(x.subs);
                try (try self.element(arr, key)).set(v);
            },
            else => unreachable,
        }
    }

    // FUNCTIONS

    fn call(self: *Awk, index: u32, args: []*Expr) Err!Value {
        const f = self.prog.funcs.items[index];
        if (args.len > f.nparams) return fatal("{s}: too many arguments", .{f.name});
        if (self.depth >= 1000) return fatal("{s}: calls nested too deeply", .{f.name});
        const frame = try gpa.alloc(Slot, f.nparams);
        @memset(frame, .uninit);
        defer {
            for (frame) |*s| {
                if (s.* != .ref) freeSlot(s);
            }
            gpa.free(frame);
        }
        for (args, 0..) |arg, k| {
            // A bare variable that is or may become an array goes by reference:
            if (arg.* == .var_) {
                const s = self.slotOf(arg.var_);
                if (s.* == .array or s.* == .uninit) {
                    frame[k] = .{ .ref = s };
                    continue;
                }
            }
            const v = try self.eval(arg);
            frame[k] = .{ .cell = .{} };
            try frame[k].cell.set(v);
        }
        const old_frame = self.frame;
        self.frame = frame;
        self.depth += 1;
        defer {
            self.frame = old_frame;
            self.depth -= 1;
        }
        self.ret.deinit();
        const flow = try self.exec(f.body.?);
        switch (flow) {
            .exit, .next, .nextfile => {
                self.pending_flow = flow;
                return .{};
            },
            else => {},
        }
        // The returned value moves to the caller's scratch memory:
        var v = self.ret.v;
        if (v.kind == .str or v.kind == .strnum) v.str = try self.ta().dupe(u8, v.str);
        self.ret.deinit();
        return v;
    }

    fn builtin(self: *Awk, b: Builtin, args: []*Expr) Err!Value {
        const a = self.ta();
        switch (b) {
            .length => {
                if (args.len == 0) {
                    try self.rebuild();
                    return Value.ofNum(@floatFromInt(self.record.items.len));
                }
                if (args[0].* == .var_) {
                    const s = self.slotOf(args[0].var_);
                    if (s.* == .array) return Value.ofNum(@floatFromInt(s.array.count()));
                }
                return Value.ofNum(@floatFromInt((try self.toStr(try self.eval(args[0]))).len));
            },
            .substr => {
                // As BWK awk and gawk: numbers truncated, a start before 1
                // counts as 1 (the length stays):
                const s = try self.toStr(try self.eval(args[0]));
                const len: f64 = @floatFromInt(s.len);
                var start = @trunc(self.toNum(try self.eval(args[1])));
                var count = len;
                if (args.len == 3) count = @trunc(self.toNum(try self.eval(args[2])));
                if (std.math.isNan(start) or std.math.isNan(count)) return Value.ofStr("");
                if (start < 1) start = 1;
                if (start > len + 1) start = len + 1;
                if (count < 0) count = 0;
                if (count > len + 1 - start) count = len + 1 - start;
                const from: usize = @intFromFloat(start - 1);
                const n: usize = @intFromFloat(count);
                return Value.ofStr(s[from .. from + n]);
            },
            .index => {
                const s = try self.toStr(try self.eval(args[0]));
                const t = try self.toStr(try self.eval(args[1]));
                const pos = std.mem.indexOf(u8, s, t);
                return Value.ofNum(if (pos) |p| @floatFromInt(p + 1) else 0);
            },
            .split => {
                const s = try a.dupe(u8, try self.toStr(try self.eval(args[0])));
                var pieces: std.ArrayListUnmanaged([]const u8) = .{};
                if (args.len == 3 and args[2].* == .ere) {
                    const re = &self.prog.regexes.items[args[2].ere];
                    try self.splitRegex(s, re, &pieces);
                } else {
                    const fs = if (args.len == 3) try self.toStr(try self.eval(args[2])) else self.special(FS);
                    try self.splitText(s, fs, &pieces);
                }
                const arr = try self.arrayOf(args[1].var_);
                var it = arr.iterator();
                while (it.next()) |e| {
                    gpa.free(e.key_ptr.*);
                    e.value_ptr.deinit();
                }
                arr.clearRetainingCapacity();
                for (pieces.items, 0..) |p, k| {
                    var buf: [24]u8 = undefined;
                    const key = std.fmt.bufPrint(&buf, "{d}", .{k + 1}) catch unreachable;
                    try (try self.element(arr, key)).set(Value.ofInput(p));
                }
                return Value.ofNum(@floatFromInt(pieces.items.len));
            },
            .sub, .gsub => {
                const re = try self.regexOf(args[0]);
                const repl = try self.toStr(try self.eval(args[1]));
                const target_value = if (args.len == 3) try self.eval(args[2]) else try self.getField(0);
                const s = try self.toStr(target_value);
                var out: std.ArrayListUnmanaged(u8) = .{};
                var count: usize = 0;
                var pos: usize = 0;
                var last_end: ?usize = null;
                while (pos <= s.len) {
                    const m = re.search(s, pos) orelse break;
                    if (m.start == m.end and last_end != null and last_end.? == m.start) {
                        // No empty match right after a match:
                        if (m.start < s.len) try out.append(a, s[m.start]);
                        pos = m.start + 1;
                        continue;
                    }
                    try out.appendSlice(a, s[pos..m.start]);
                    try appendReplacement(a, &out, repl, s[m.start..m.end]);
                    count += 1;
                    last_end = m.end;
                    if (m.end == m.start) {
                        if (m.start < s.len) try out.append(a, s[m.start]);
                        pos = m.start + 1;
                    } else pos = m.end;
                    if (b == .sub) break;
                }
                if (count > 0) {
                    if (pos < s.len) try out.appendSlice(a, s[pos..]);
                    const target = if (args.len == 3) args[2] else blk: {
                        const zero = try a.create(Expr);
                        zero.* = .{ .num = 0 };
                        const f = try a.create(Expr);
                        f.* = .{ .field = zero };
                        break :blk f;
                    };
                    try self.store(target, Value.ofStr(out.items));
                }
                return Value.ofNum(@floatFromInt(count));
            },
            .match => {
                const s = try self.toStr(try self.eval(args[0]));
                const re = try self.regexOf(args[1]);
                const m = re.search(s, 0);
                const start: f64 = if (m) |x| @floatFromInt(x.start + 1) else 0;
                const len: f64 = if (m) |x| @floatFromInt(x.end - x.start) else -1;
                try self.setSpecialNum(RSTART, start);
                try self.setSpecialNum(RLENGTH, len);
                return Value.ofNum(start);
            },
            .sprintf => {
                var out: std.ArrayListUnmanaged(u8) = .{};
                try self.formatArgs(&out, args);
                return Value.ofStr(out.items);
            },
            .sin => return Value.ofNum(@sin(self.toNum(try self.eval(args[0])))),
            .cos => return Value.ofNum(@cos(self.toNum(try self.eval(args[0])))),
            .atan2 => {
                const y = self.toNum(try self.eval(args[0]));
                const x = self.toNum(try self.eval(args[1]));
                return Value.ofNum(std.math.atan2(y, x));
            },
            .exp => return Value.ofNum(@exp(self.toNum(try self.eval(args[0])))),
            .log => return Value.ofNum(@log(self.toNum(try self.eval(args[0])))),
            .sqrt => return Value.ofNum(@sqrt(self.toNum(try self.eval(args[0])))),
            .int => return Value.ofNum(@trunc(self.toNum(try self.eval(args[0])))),
            .rand => {
                // xorshift64*, 53 bits into [0, 1):
                var x = self.rand_state;
                x ^= x >> 12;
                x ^= x << 25;
                x ^= x >> 27;
                self.rand_state = x;
                const r = (x *% 0x2545F4914F6CDD1D) >> 11;
                return Value.ofNum(@as(f64, @floatFromInt(r)) / 9007199254740992.0);
            },
            .srand => {
                const old = self.seed;
                self.seed = if (args.len == 1) self.toNum(try self.eval(args[0])) else @floatFromInt(zdos.millis() / 1000);
                self.rand_state = @as(u64, @bitCast(self.seed)) ^ 0x9E3779B97F4A7C15;
                if (self.rand_state == 0) self.rand_state = 1;
                return Value.ofNum(old);
            },
            .tolower, .toupper => {
                const s = try self.toStr(try self.eval(args[0]));
                const out = try a.alloc(u8, s.len);
                for (s, 0..) |c, k| out[k] = if (b == .tolower) std.ascii.toLower(c) else std.ascii.toUpper(c);
                return Value.ofStr(out);
            },
            .system => {
                const cmd = try a.dupe(u8, try self.toStr(try self.eval(args[0])));
                self.flushAll();
                const status = self.sh.runWithInput(cmd, null);
                if (self.sh.interrupted) return error.Interrupted;
                return Value.ofNum(@floatFromInt(status));
            },
            .close => {
                const name = try self.toStr(try self.eval(args[0]));
                return Value.ofNum(try self.closeStream(name));
            },
            .fflush => {
                self.flushAll();
                return Value.ofNum(0);
            },
        }
    }

    fn splitRegex(self: *Awk, s: []const u8, re: *regex.Regex, pieces: *std.ArrayListUnmanaged([]const u8)) Err!void {
        if (s.len == 0) return;
        var start: usize = 0;
        var pos: usize = 0;
        while (pos <= s.len) {
            const m = re.search(s, pos) orelse break;
            if (m.end == m.start) {
                pos = m.start + 1;
                continue;
            }
            try pieces.append(self.ta(), s[start..m.start]);
            start = m.end;
            pos = m.end;
        }
        try pieces.append(self.ta(), s[start..]);
    }

    fn formatArgs(self: *Awk, out: *std.ArrayListUnmanaged(u8), args: []*Expr) Err!void {
        const a = self.ta();
        const fmt = try a.dupe(u8, try self.toStr(try self.eval(args[0])));
        var next: usize = 1;
        var i: usize = 0;
        while (i < fmt.len) {
            if (fmt[i] != '%') {
                const end = std.mem.indexOfScalarPos(u8, fmt, i, '%') orelse fmt.len;
                try out.appendSlice(a, fmt[i..end]);
                i = end;
                continue;
            }
            var spec = format.parseSpec(fmt, i) orelse {
                try out.append(a, '%');
                i += 1;
                continue;
            };
            i += spec.len;
            if (spec.conv == '%') {
                try out.append(a, '%');
                continue;
            }
            if (spec.width_star) {
                const w = self.toNum(try self.argValue(args, &next));
                spec.width = @intFromFloat(@min(@abs(w), 4096));
                if (w < 0) spec.minus = true;
            }
            if (spec.precision_star) spec.precision = @intFromFloat(@min(@max(self.toNum(try self.argValue(args, &next)), 0), 4096));
            const v = try self.argValue(args, &next);
            switch (spec.conv) {
                's' => try format.string(a, out, spec, try self.toStr(v)),
                'c' => {
                    if (v.kind == .num) {
                        var buf: [4]u8 = undefined;
                        const code: u21 = @intFromFloat(@min(@max(v.num, 0), 0x10FFFF));
                        const n = if (code < 256) blk: {
                            buf[0] = @intCast(code);
                            break :blk 1;
                        } else std.unicode.utf8Encode(code, &buf) catch 0;
                        try format.char(a, out, spec, buf[0..n]);
                    } else {
                        const s = try self.toStr(v);
                        try format.char(a, out, spec, if (s.len > 0) s[0..1] else "");
                    }
                },
                'd', 'i', 'o', 'u', 'x', 'X' => try format.integer(a, out, spec, self.toNum(v)),
                else => try format.float(a, out, spec, self.toNum(v)),
            }
        }
    }

    fn argValue(self: *Awk, args: []*Expr, next: *usize) Err!Value {
        if (next.* >= args.len) return .{};
        const v = try self.eval(args[next.*]);
        next.* += 1;
        return v;
    }

    fn getline(self: *Awk, src: GetSrc, target: ?*Expr, from: ?*Expr) Err!Value {
        var line: std.ArrayListUnmanaged(u8) = .{};
        defer line.deinit(gpa);
        switch (src) {
            .main => {
                if (!try self.readMain(&line)) return Value.ofNum(0);
                try self.setSpecialNum(NR, self.specialNum(NR) + 1);
                try self.setSpecialNum(FNR, self.specialNum(FNR) + 1);
            },
            .file, .command => {
                const name = try self.toStr(try self.eval(from.?));
                const input = (try self.openInput(name, src == .command)) orelse return Value.ofNum(-1);
                if (!try input.record(self.special(RS), &line)) return Value.ofNum(0);
                if (src == .command) try self.setSpecialNum(NR, self.specialNum(NR) + 1);
            },
        }
        if (target) |t| {
            try self.store(t, Value.ofInput(try self.ta().dupe(u8, line.items)));
        } else {
            try self.setRecord(line.items);
            if (src == .main) {} // NR and FNR done above
        }
        return Value.ofNum(1);
    }

    fn openInput(self: *Awk, name: []const u8, command: bool) Err!?*Input {
        if (self.inputs.get(name)) |i| return i;
        const input = try gpa.create(Input);
        input.* = .{};
        if (command) {
            self.flushAll();
            const output = self.sh.capture(gpa, name) catch {
                gpa.destroy(input);
                return error.OutOfMemory;
            };
            if (self.sh.interrupted) {
                gpa.free(output);
                gpa.destroy(input);
                return error.Interrupted;
            }
            input.data = output;
        } else {
            input.reader = text.Reader.open(name) catch {
                gpa.destroy(input);
                return null;
            };
        }
        const key = gpa.dupe(u8, name) catch |err| {
            input.close();
            gpa.destroy(input);
            return err;
        };
        self.inputs.put(gpa, key, input) catch |err| {
            input.close();
            gpa.destroy(input);
            gpa.free(key);
            return err;
        };
        return input;
    }

    // The files named in ARGV, or the standard input.
    fn readMain(self: *Awk, line: *std.ArrayListUnmanaged(u8)) Err!bool {
        while (true) {
            if (self.main == null and !try self.openNextMain()) return false;
            if (try self.main.?.record(self.special(RS), line)) return true;
            self.main.?.close();
            self.main = null;
        }
    }

    fn openNextMain(self: *Awk) Err!bool {
        const argv = try self.arrayOf(.{ .global = ARGV });
        while (@as(f64, @floatFromInt(self.argv_next)) < self.specialNum(ARGC)) {
            var buf: [24]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "{d}", .{self.argv_next}) catch unreachable;
            self.argv_next += 1;
            const cell = argv.get(key) orelse continue;
            const arg = try self.ta().dupe(u8, try self.toStr(cell.v));
            if (arg.len == 0) continue;
            if (try self.operandAssignment(arg)) continue;
            self.main_opened = true;
            const reader = text.Reader.open(arg) catch |err| {
                errout.printf("awk: {s}: {s}\n", .{ arg, zdos.message(err) });
                self.exit_code = 2;
                continue;
            };
            self.main = .{ .reader = reader };
            try self.setVar(.{ .global = FILENAME }, Value.ofStr(arg));
            try self.setSpecialNum(FNR, 0);
            return true;
        }
        if (self.main_opened) return false;
        self.main_opened = true;
        self.main = .{ .reader = text.Reader.stdin() };
        try self.setSpecialNum(FNR, 0);
        return true;
    }

    // NAME=value among the files: set when reached.
    fn operandAssignment(self: *Awk, arg: []const u8) Err!bool {
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse return false;
        const name = arg[0..eq];
        if (!isName(name)) return false;
        const index = for (self.prog.globals.items, 0..) |g, k| {
            if (std.mem.eql(u8, g, name)) break k;
        } else return true; // not used by the program
        const value = try unescape(self.ta(), arg[eq + 1 ..]);
        try self.setVar(.{ .global = @intCast(index) }, Value.ofInput(value));
        return true;
    }

    // OUTPUT

    fn streamFor(self: *Awk, redir: Redir, name: []const u8) Err!?*Stream {
        if (std.mem.eql(u8, name, "/dev/stdout") or std.mem.eql(u8, name, "-")) return null;
        for (self.streams.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        const s = try gpa.create(Stream);
        s.* = .{ .name = gpa.dupe(u8, name) catch |err| {
            gpa.destroy(s);
            return err;
        }, .redir = redir };
        self.streams.append(gpa, s) catch |err| {
            gpa.free(s.name);
            gpa.destroy(s);
            return err;
        };
        if (std.mem.eql(u8, name, "/dev/stderr") or std.mem.eql(u8, name, "/dev/tty")) {
            s.screen = true;
        } else if (redir != .pipe) {
            const file = zdos.open(name, if (redir == .append) .update else .write) catch |err| {
                return fatal("{s}: {s}", .{ name, zdos.message(err) });
            };
            if (redir == .append) file.seek(zdos.seek_end) catch {};
            s.file = file;
        }
        return s;
    }

    fn write(self: *Awk, stream: ?*Stream, data: []const u8) Err!void {
        const s = stream orelse {
            self.out.write(data);
            return;
        };
        if (s.screen) {
            self.out.flush();
            sys.redirect(.output, sys.console) catch {};
            zdos.print(data);
            sys.redirect(.output, self.sh.out_handle) catch {};
            return;
        }
        try s.data.appendSlice(gpa, data);
        if (s.file != null and s.data.items.len >= 4096) try flushStream(s);
    }

    fn flushStream(s: *Stream) Err!void {
        if (s.file) |f| {
            f.writeAll(s.data.items) catch |err| return fatal("{s}: {s}", .{ s.name, zdos.message(err) });
            s.data.clearRetainingCapacity();
        }
    }

    fn flushAll(self: *Awk) void {
        self.out.flush();
        for (self.streams.items) |s| flushStream(s) catch {};
    }

    // Running a command that was written to; -1 if nothing has that name.
    fn closeStream(self: *Awk, name: []const u8) Err!f64 {
        for (self.streams.items, 0..) |s, k| {
            if (!std.mem.eql(u8, s.name, name)) continue;
            _ = self.streams.orderedRemove(k);
            return self.finishStream(s);
        }
        if (self.inputs.fetchRemove(name)) |entry| {
            entry.value.close();
            gpa.destroy(entry.value);
            gpa.free(entry.key);
            return 0;
        }
        return -1;
    }

    fn finishStream(self: *Awk, s: *Stream) Err!f64 {
        defer {
            s.data.deinit(gpa);
            gpa.free(s.name);
            gpa.destroy(s);
        }
        var status: f64 = 0;
        if (s.redir == .pipe and !s.screen) {
            self.flushAll();
            status = @floatFromInt(self.sh.runWithInput(s.name, s.data.items));
            if (self.sh.interrupted) return error.Interrupted;
        } else if (s.file) |f| {
            flushStream(s) catch {
                f.close();
                return -1;
            };
            f.closeChecked() catch return -1;
        }
        return status;
    }

    fn closeAll(self: *Awk) Err!void {
        self.out.flush();
        while (self.streams.items.len > 0) {
            const s = self.streams.orderedRemove(0);
            _ = try self.finishStream(s);
        }
    }

    // STATEMENTS

    fn exec(self: *Awk, s: *Stmt) Err!Flow {
        self.steps +%= 1;
        if (self.steps & 0x3ff == 0 and sys.ctrlCPressed(true)) {
            self.sh.interrupted = true;
            self.sh.flow = .exit_;
            self.sh.exit_status = 130;
            return error.Interrupted;
        }
        switch (s.*) {
            .block => |list| {
                for (list) |x| {
                    const f = try self.exec(x);
                    if (f != .normal) return f;
                }
                return .normal;
            },
            .if_ => |x| {
                if (try self.condition(x.c)) return self.exec(x.a);
                if (x.b) |b| return self.exec(b);
                return .normal;
            },
            .while_ => |x| {
                while (try self.condition(x.c)) {
                    switch (try self.exec(x.body)) {
                        .break_ => break,
                        .normal, .continue_ => {},
                        else => |f| return f,
                    }
                }
                return .normal;
            },
            .do_ => |x| {
                while (true) {
                    switch (try self.exec(x.body)) {
                        .break_ => break,
                        .normal, .continue_ => {},
                        else => |f| return f,
                    }
                    if (!try self.condition(x.c)) break;
                }
                return .normal;
            },
            .for_ => |x| {
                if (x.init) |e| try self.simple(e);
                while (x.c == null or try self.condition(x.c.?)) {
                    switch (try self.exec(x.body)) {
                        .break_ => break,
                        .normal, .continue_ => {},
                        else => |f| return f,
                    }
                    if (x.step) |e| try self.simple(e);
                }
                return .normal;
            },
            .for_in => |x| {
                const arr = try self.arrayOf(x.arr);
                // The keys as they are now; the body may change the array:
                var keys: std.ArrayListUnmanaged([]const u8) = .{};
                defer {
                    for (keys.items) |k| gpa.free(k);
                    keys.deinit(gpa);
                }
                var it = arr.keyIterator();
                while (it.next()) |k| {
                    const copy = try gpa.dupe(u8, k.*);
                    keys.append(gpa, copy) catch |err| {
                        gpa.free(copy);
                        return err;
                    };
                }
                for (keys.items) |k| {
                    if (!arr.contains(k)) continue;
                    try self.store(x.v, Value.ofInput(k));
                    switch (try self.exec(x.body)) {
                        .break_ => break,
                        .normal, .continue_ => {},
                        else => |f| return f,
                    }
                }
                return .normal;
            },
            .next => return .next,
            .nextfile => return .nextfile,
            .break_ => return .break_,
            .continue_ => return .continue_,
            .exit => |e| {
                if (e) |x| {
                    const m = self.temp.mark();
                    defer self.temp.release(m);
                    const code = self.toNum(try self.eval(x));
                    self.exit_code = @truncate(@as(u64, @bitCast(@as(i64, @intFromFloat(@max(@min(code, 1e15), -1e15))))));
                }
                return .exit;
            },
            .return_ => |e| {
                if (self.depth == 0) return fatal("return outside a function", .{});
                if (e) |x| {
                    const m = self.temp.mark();
                    defer self.temp.release(m);
                    try self.ret.set(try self.eval(x));
                }
                return .return_;
            },
            .delete => |x| {
                const m = self.temp.mark();
                defer self.temp.release(m);
                const arr = try self.arrayOf(x.v);
                if (x.subs) |subs| {
                    const key = try self.subscript(subs);
                    if (arr.fetchRemove(key)) |entry| {
                        gpa.free(entry.key);
                        var c = entry.value;
                        c.deinit();
                    }
                } else {
                    var it = arr.iterator();
                    while (it.next()) |entry| {
                        gpa.free(entry.key_ptr.*);
                        entry.value_ptr.deinit();
                    }
                    arr.clearRetainingCapacity();
                }
                return .normal;
            },
            .expr => |e| {
                try self.simple(e);
                return self.takePending();
            },
            .print, .printf => |p| {
                const m = self.temp.mark();
                defer self.temp.release(m);
                try self.print(p, s.* == .printf);
                return self.takePending();
            },
        }
    }

    fn takePending(self: *Awk) Flow {
        const f = self.pending_flow;
        self.pending_flow = .normal;
        return f;
    }

    fn simple(self: *Awk, e: *Expr) Err!void {
        const m = self.temp.mark();
        defer self.temp.release(m);
        _ = try self.eval(e);
    }

    fn condition(self: *Awk, e: *Expr) Err!bool {
        const m = self.temp.mark();
        defer self.temp.release(m);
        return self.toBool(try self.eval(e));
    }

    fn print(self: *Awk, p: Print, is_printf: bool) Err!void {
        const a = self.ta();
        var out: std.ArrayListUnmanaged(u8) = .{};
        if (is_printf) {
            try self.formatArgs(&out, p.args);
        } else {
            if (p.args.len == 0) {
                try self.rebuild();
                try out.appendSlice(a, self.record.items);
            }
            for (p.args, 0..) |arg, k| {
                if (k > 0) try out.appendSlice(a, self.special(OFS));
                try out.appendSlice(a, try self.toOutStr(try self.eval(arg)));
            }
            try out.appendSlice(a, self.special(ORS));
        }
        var stream: ?*Stream = null;
        if (p.dest) |d| {
            const name = try self.toStr(try self.eval(d));
            stream = try self.streamFor(p.redir, name);
        }
        try self.write(stream, out.items);
    }

    fn runProgram(self: *Awk) Err!void {
        var exiting = false;
        for (self.prog.begin.items) |b| {
            if (try self.exec(b) == .exit) {
                exiting = true;
                break;
            }
        }
        const read_input = self.prog.items.items.len > 0 or self.prog.end.items.len > 0;
        if (!exiting and read_input) {
            var line: std.ArrayListUnmanaged(u8) = .{};
            defer line.deinit(gpa);
            records: while (try self.readMain(&line)) {
                try self.setRecord(line.items);
                try self.setSpecialNum(NR, self.specialNum(NR) + 1);
                try self.setSpecialNum(FNR, self.specialNum(FNR) + 1);
                for (self.prog.items.items, 0..) |item, k| {
                    if (!try self.matches(item, k)) continue;
                    const flow = if (item.action) |act| try self.exec(act) else blk: {
                        try self.rebuild();
                        self.out.write(self.record.items);
                        self.out.write(self.special(ORS));
                        break :blk Flow.normal;
                    };
                    switch (flow) {
                        .next => continue :records,
                        .nextfile => {
                            if (self.main) |*m| m.close();
                            self.main = null;
                            continue :records;
                        },
                        .exit => {
                            exiting = true;
                            break :records;
                        },
                        else => {},
                    }
                }
            }
        }
        for (self.prog.end.items) |b| {
            if (try self.exec(b) == .exit) break;
        }
    }

    fn matches(self: *Awk, item: Item, k: usize) Err!bool {
        const p = item.pattern orelse return true;
        if (item.end_pattern) |e| {
            if (!self.range_on[k]) {
                if (!try self.condition(p)) return false;
                self.range_on[k] = true;
            }
            if (try self.condition(e)) self.range_on[k] = false;
            return true;
        }
        return self.condition(p);
    }
};

fn appendReplacement(a: Allocator, out: *std.ArrayListUnmanaged(u8), repl: []const u8, matched: []const u8) Allocator.Error!void {
    var i: usize = 0;
    while (i < repl.len) : (i += 1) {
        const c = repl[i];
        if (c == '\\' and i + 1 < repl.len and (repl[i + 1] == '&' or repl[i + 1] == '\\')) {
            i += 1;
            try out.append(a, repl[i]);
        } else if (c == '&') {
            try out.appendSlice(a, matched);
        } else try out.append(a, c);
    }
}

fn isName(s: []const u8) bool {
    if (s.len == 0 or !(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

fn usage() u8 {
    errout.print("usage: awk [-F FS] [-v NAME=VALUE] 'PROGRAM' | -f FILE [FILE | NAME=VALUE]...\n");
    return 2;
}

pub fn run(sh: *Shell, args: []const []const u8) u8 {
    var awk: Awk = .{ .sh = sh, .arena = std.heap.ArenaAllocator.init(gpa) };
    defer awk.deinit();
    const a = awk.arena.allocator();
    var fs: ?[]const u8 = null;
    var assigns: std.ArrayListUnmanaged([]const u8) = .{};
    var source: std.ArrayListUnmanaged(u8) = .{};
    var have_file = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len < 2 or arg[0] != '-') break;
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        const value = if (arg.len > 2) arg[2..] else blk: {
            i += 1;
            if (i >= args.len) return usage();
            break :blk args[i];
        };
        switch (arg[1]) {
            'F' => fs = value,
            'v' => assigns.append(a, value) catch return shell_mod.outOfMemory(),
            'f' => {
                const t = shell_mod.readScript(value) orelse return 2;
                defer gpa.free(t);
                source.appendSlice(a, t) catch return shell_mod.outOfMemory();
                source.append(a, '\n') catch return shell_mod.outOfMemory();
                have_file = true;
            },
            else => return usage(),
        }
    }
    if (!have_file) {
        if (i >= args.len) return usage();
        source.appendSlice(a, args[i]) catch return shell_mod.outOfMemory();
        i += 1;
    }
    const operands = args[i..];

    const toks = lex(a, source.items) catch return 2;
    var p: Parser = .{ .a = a, .toks = toks, .prog = &awk.prog };
    p.program() catch return 2;

    awk.globals = gpa.alloc(Slot, awk.prog.globals.items.len) catch return shell_mod.outOfMemory();
    @memset(awk.globals, .uninit);
    awk.range_on = a.alloc(bool, awk.prog.items.items.len) catch return shell_mod.outOfMemory();
    @memset(awk.range_on, false);
    initVars(&awk, fs, assigns.items, operands) catch return 2;

    var status: u8 = 0;
    awk.runProgram() catch |err| switch (err) {
        error.OutOfMemory => status = shell_mod.outOfMemory(),
        error.Interrupted => status = 130,
        error.Fatal => status = 2,
    };
    if (status == 0) {
        awk.closeAll() catch |err| {
            status = if (err == error.Interrupted) 130 else 2;
        };
    }
    awk.out.flush();
    return if (status != 0) status else awk.exit_code;
}

fn initVars(awk: *Awk, fs: ?[]const u8, assigns: []const []const u8, operands: []const []const u8) Err!void {
    const ta = awk.ta();
    const defaults = [_]struct { u32, []const u8 }{
        .{ FS, " " },        .{ OFS, " " },        .{ ORS, "\n" },    .{ RS, "\n" },
        .{ SUBSEP, "\x1c" }, .{ CONVFMT, "%.6g" }, .{ OFMT, "%.6g" }, .{ FILENAME, "" },
    };
    for (defaults) |d| try awk.setVar(.{ .global = d[0] }, Value.ofStr(d[1]));
    for ([_]u32{ NR, FNR, RSTART }) |n| try awk.setSpecialNum(n, 0);
    try awk.setSpecialNum(RLENGTH, -1);
    awk.globals[NF] = .{ .cell = .{} };
    try awk.globals[NF].cell.set(Value.ofNum(0));
    if (fs) |f| {
        const value = if (std.mem.eql(u8, f, "t")) "\t" else try unescape(ta, f);
        try awk.setVar(.{ .global = FS }, Value.ofStr(value));
    }
    // ENVIRON: the exported variables:
    const env = try awk.arrayOf(.{ .global = ENVIRON });
    var it = awk.sh.vars.iterator();
    while (it.next()) |e| {
        if (!e.value_ptr.exported or e.value_ptr.values.items.len == 0) continue;
        try (try awk.element(env, e.key_ptr.*)).set(Value.ofInput(e.value_ptr.values.items[0]));
    }
    const argv = try awk.arrayOf(.{ .global = ARGV });
    try (try awk.element(argv, "0")).set(Value.ofStr("awk"));
    for (operands, 0..) |op, k| {
        var buf: [24]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{d}", .{k + 1}) catch unreachable;
        try (try awk.element(argv, key)).set(Value.ofInput(op));
    }
    try awk.setSpecialNum(ARGC, @floatFromInt(operands.len + 1));
    for (assigns) |assign| {
        if (!try awk.operandAssignment(assign)) {
            errout.printf("awk: -v {s}: NAME=VALUE expected\n", .{assign});
            return error.Fatal;
        }
    }
    awk.split_done = true;
}
