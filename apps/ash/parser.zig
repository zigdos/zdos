// The shell grammar, one complete command at a time, as POSIX shells:
// a script runs up to its first syntax error. Words stay raw text until
// the command runs.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Error = error{ Syntax, Incomplete, OutOfMemory };

pub const Heredoc = struct {
    delimiter: []const u8,
    body: []const u8 = "",
    expand: bool, // delimiter unquoted: $ ` \ work in the body
    strip_tabs: bool, // <<-
};

pub const Redir = struct {
    fd: u8, // 0 input, 1 output, 2 error output
    op: Op,
    target: []const u8 = "", // raw word
    heredoc: ?*Heredoc = null,

    pub const Op = enum { input, output, append, dup_input, dup_output, heredoc, herestring, read_write };
};

pub const Assign = struct {
    name: []const u8,
    index: ?[]const u8 = null, // NAME[index]=value
    append: bool = false, // NAME+=value
    value: []const u8 = "", // raw word
    array: ?[]const []const u8 = null, // raw words of NAME=(...)
};

pub const Simple = struct {
    assigns: []Assign,
    words: []const []const u8,
    redirs: []Redir,
};

pub const AndOr = struct { or_: bool, node: *Node };
pub const ListItem = struct { node: *Node, background: bool };
pub const Branch = struct { cond: *Node, body: *Node };
pub const CaseItem = struct { patterns: []const []const u8, body: ?*Node };

pub const Node = union(enum) {
    simple: Simple,
    pipeline: struct { commands: []*Node, negate: bool },
    and_or: struct { first: *Node, rest: []AndOr },
    list: []ListItem,
    subshell: *Node,
    group: *Node,
    if_: struct { branches: []Branch, else_body: ?*Node },
    loop: struct { cond: *Node, body: *Node, until: bool },
    for_: struct { name: []const u8, words: ?[]const []const u8, body: *Node },
    case_: struct { word: []const u8, items: []CaseItem },
    function: struct { name: []const u8, body_src: []const u8 },
    redirected: struct { node: *Node, redirs: []Redir },
};

const Kind = enum {
    word,
    newline,
    eof,
    semi, // ;
    dsemi, // ;;
    amp, // &
    and_if, // &&
    pipe, // |
    or_if, // ||
    lparen,
    rparen,
    less, // <
    great, // >
    dgreat, // >>
    dless, // <<
    dlessdash, // <<-
    tless, // <<< (a here-string)
    lessand, // <&
    greatand, // >&
    lessgreat, // <>
    clobber, // >|
};

const Token = struct {
    kind: Kind,
    text: []const u8 = "",
    start: usize,
    end: usize,
    fd: ?u8 = null, // 2> and the like
};

pub const Parser = struct {
    a: Allocator,
    src: []const u8,
    pos: usize = 0,
    peeked: ?Token = null,
    last_end: usize = 0,
    pending: std.ArrayListUnmanaged(*Heredoc) = .{},
    // After an error: what was wrong, and where:
    message: []const u8 = "",
    error_pos: usize = 0,

    pub fn init(a: Allocator, src: []const u8) Parser {
        return .{ .a = a, .src = src };
    }

    // Null at the end of the text.
    pub fn next(self: *Parser) Error!?*Node {
        while ((try self.peek()).kind == .newline) self.consume();
        const t = try self.peek();
        if (t.kind == .eof) return null;
        const node = try self.topList();
        const end = try self.peek();
        switch (end.kind) {
            .newline => self.consume(),
            .eof => {},
            else => return self.fail(end, "unexpected"),
        }
        return node;
    }

    // From 1.
    pub fn lineAt(self: *const Parser, pos: usize) usize {
        return 1 + std.mem.count(u8, self.src[0..@min(pos, self.src.len)], "\n");
    }

    fn fail(self: *Parser, t: Token, message: []const u8) Error {
        if (t.kind == .eof) return error.Incomplete;
        self.message = message;
        self.error_pos = t.start;
        return error.Syntax;
    }

    pub fn errorText(self: *const Parser) []const u8 {
        if (self.error_pos >= self.src.len) return "end of input";
        var end = self.error_pos;
        while (end < self.src.len and self.src[end] != '\n' and end - self.error_pos < 20) : (end += 1) {}
        const text = self.src[self.error_pos..end];
        return if (text.len == 0) "newline" else text;
    }

    // TOKENS

    fn peek(self: *Parser) Error!Token {
        if (self.peeked) |t| return t;
        const t = try self.scan();
        self.peeked = t;
        return t;
    }

    fn consume(self: *Parser) void {
        if (self.peeked) |t| self.last_end = t.end;
        self.peeked = null;
    }

    fn take(self: *Parser) Error!Token {
        const t = try self.peek();
        self.consume();
        return t;
    }

    fn isWord(t: Token, text: []const u8) bool {
        return t.kind == .word and std.mem.eql(u8, t.text, text);
    }

    fn skipNewlines(self: *Parser) Error!void {
        while ((try self.peek()).kind == .newline) self.consume();
    }

    fn scan(self: *Parser) Error!Token {
        const s = self.src;
        while (self.pos < s.len) {
            const c = s[self.pos];
            if (c == ' ' or c == '\t' or c == '\r') {
                self.pos += 1;
            } else if (c == '\\' and self.pos + 1 < s.len and s[self.pos + 1] == '\n') {
                self.pos += 2;
            } else if (c == '#') {
                while (self.pos < s.len and s[self.pos] != '\n') self.pos += 1;
            } else break;
        }
        const start = self.pos;
        if (self.pos >= s.len) {
            if (self.pending.items.len > 0) return error.Incomplete;
            return .{ .kind = .eof, .start = start, .end = start };
        }
        const c = s[self.pos];
        if (c == '\n') {
            self.pos += 1;
            try self.readHeredocs();
            return .{ .kind = .newline, .start = start, .end = start + 1 };
        }
        // 2> 0< and the like: a number right before < or >:
        var fd: ?u8 = null;
        if (std.ascii.isDigit(c) and self.pos + 1 < s.len and (s[self.pos + 1] == '<' or s[self.pos + 1] == '>')) {
            fd = c - '0';
            self.pos += 1;
        }
        if (self.operator()) |kind| {
            return .{ .kind = kind, .start = start, .end = self.pos, .fd = fd };
        }
        try self.scanWord();
        return .{ .kind = .word, .text = s[start..self.pos], .start = start, .end = self.pos };
    }

    fn operator(self: *Parser) ?Kind {
        const s = self.src;
        const c = s[self.pos];
        const n1: u8 = if (self.pos + 1 < s.len) s[self.pos + 1] else 0;
        const n2: u8 = if (self.pos + 2 < s.len) s[self.pos + 2] else 0;
        const result: struct { Kind, usize } = switch (c) {
            ';' => if (n1 == ';') .{ .dsemi, 2 } else .{ .semi, 1 },
            '&' => if (n1 == '&') .{ .and_if, 2 } else .{ .amp, 1 },
            '|' => if (n1 == '|') .{ .or_if, 2 } else .{ .pipe, 1 },
            '(' => .{ .lparen, 1 },
            ')' => .{ .rparen, 1 },
            '<' => switch (n1) {
                '<' => if (n2 == '-') .{ .dlessdash, 3 } else if (n2 == '<') .{ .tless, 3 } else .{ .dless, 2 },
                '&' => .{ .lessand, 2 },
                '>' => .{ .lessgreat, 2 },
                else => .{ .less, 1 },
            },
            '>' => switch (n1) {
                '>' => .{ .dgreat, 2 },
                '&' => .{ .greatand, 2 },
                '|' => .{ .clobber, 2 },
                else => .{ .great, 1 },
            },
            else => return null,
        };
        self.pos += result[1];
        return result[0];
    }

    fn scanWord(self: *Parser) Error!void {
        const s = self.src;
        const start = self.pos;
        while (self.pos < s.len) {
            const c = s[self.pos];
            switch (c) {
                ' ', '\t', '\r', '\n', ';', '&', '|', '<', '>', '(', ')' => break,
                '\\' => {
                    if (self.pos + 1 >= s.len) return error.Incomplete;
                    self.pos += 2;
                },
                '\'' => {
                    const close = std.mem.indexOfScalarPos(u8, s, self.pos + 1, '\'') orelse return error.Incomplete;
                    self.pos = close + 1;
                },
                '"' => try self.skipDouble(),
                '`' => try self.skipBacktick(),
                '$' => try self.skipDollar(),
                else => self.pos += 1,
            }
        }
        // NAME=( ... ): an array, read up to its ):
        if (self.pos < s.len and s[self.pos] == '(' and assignmentPrefix(s[start..self.pos]) != null and
            s[self.pos - 1] == '=')
        {
            try self.skipArray();
        }
    }

    fn skipDouble(self: *Parser) Error!void {
        const s = self.src;
        self.pos += 1;
        while (self.pos < s.len) {
            switch (s[self.pos]) {
                '\\' => self.pos += 2,
                '"' => {
                    self.pos += 1;
                    return;
                },
                '$' => try self.skipDollar(),
                '`' => try self.skipBacktick(),
                else => self.pos += 1,
            }
        }
        return error.Incomplete;
    }

    fn skipBacktick(self: *Parser) Error!void {
        const s = self.src;
        self.pos += 1;
        while (self.pos < s.len) {
            switch (s[self.pos]) {
                '\\' => self.pos += 2,
                '`' => {
                    self.pos += 1;
                    return;
                },
                else => self.pos += 1,
            }
        }
        return error.Incomplete;
    }

    fn skipDollar(self: *Parser) Error!void {
        const s = self.src;
        self.pos += 1;
        if (self.pos >= s.len) return;
        switch (s[self.pos]) {
            '\'' => {
                // $'...': backslash escapes, \' included:
                self.pos += 1;
                while (self.pos < s.len and s[self.pos] != '\'') {
                    self.pos += if (s[self.pos] == '\\') 2 else 1;
                }
                if (self.pos >= s.len) return error.Incomplete;
                self.pos += 1;
            },
            '(' => {
                if (self.pos + 1 < s.len and s[self.pos + 1] == '(') {
                    try self.skipNested('(', ')');
                } else {
                    self.pos = try commandSubstitutionEnd(self.a, s, self.pos + 1) + 1;
                }
            },
            '{' => try self.skipNested('{', '}'),
            else => {},
        }
    }

    // Over quotes and nesting.
    fn skipNested(self: *Parser, open: u8, close: u8) Error!void {
        const s = self.src;
        var depth: usize = 0;
        while (self.pos < s.len) {
            const c = s[self.pos];
            if (c == open) {
                depth += 1;
                self.pos += 1;
            } else if (c == close) {
                depth -= 1;
                self.pos += 1;
                if (depth == 0) return;
            } else switch (c) {
                '\\' => self.pos += 2,
                '\'' => {
                    // In ${...} inside double quotes a ' is plain, but in
                    // $(...) it quotes: treat it as quoting in both:
                    const q = std.mem.indexOfScalarPos(u8, s, self.pos + 1, '\'') orelse return error.Incomplete;
                    self.pos = q + 1;
                },
                '"' => try self.skipDouble(),
                '`' => try self.skipBacktick(),
                '$' => {
                    if (self.pos + 1 < s.len and s[self.pos + 1] == '{') {
                        try self.skipDollar();
                    } else self.pos += 1;
                },
                else => self.pos += 1,
            }
        }
        return error.Incomplete;
    }

    // ( words ... ) of an array assignment; newlines and comments allowed.
    fn skipArray(self: *Parser) Error!void {
        const s = self.src;
        self.pos += 1;
        var at_word_start = true;
        while (self.pos < s.len) {
            const c = s[self.pos];
            switch (c) {
                ')' => {
                    self.pos += 1;
                    return;
                },
                '#' => if (at_word_start) {
                    while (self.pos < s.len and s[self.pos] != '\n') self.pos += 1;
                    continue;
                } else {
                    self.pos += 1;
                },
                '\\' => self.pos += 2,
                '\'' => {
                    const q = std.mem.indexOfScalarPos(u8, s, self.pos + 1, '\'') orelse return error.Incomplete;
                    self.pos = q + 1;
                },
                '"' => try self.skipDouble(),
                '`' => try self.skipBacktick(),
                '$' => try self.skipDollar(),
                else => self.pos += 1,
            }
            at_word_start = c == ' ' or c == '\t' or c == '\n' or c == '\r';
        }
        return error.Incomplete;
    }

    // They start after the newline that ends the line with their <<.
    fn readHeredocs(self: *Parser) Error!void {
        const s = self.src;
        for (self.pending.items) |doc| {
            var body: std.ArrayListUnmanaged(u8) = .{};
            while (true) {
                if (self.pos >= s.len) return error.Incomplete;
                const nl = std.mem.indexOfScalarPos(u8, s, self.pos, '\n');
                const line_end = nl orelse s.len;
                var line = s[self.pos..line_end];
                if (nl == null and !std.mem.eql(u8, line, doc.delimiter)) return error.Incomplete;
                self.pos = if (nl) |n| n + 1 else s.len;
                if (doc.strip_tabs) line = std.mem.trimLeft(u8, line, "\t");
                if (std.mem.eql(u8, line, doc.delimiter)) break;
                try body.appendSlice(self.a, line);
                try body.append(self.a, '\n');
            }
            doc.body = try body.toOwnedSlice(self.a);
        }
        self.pending.clearRetainingCapacity();
    }

    // GRAMMAR

    fn newNode(self: *Parser, node: Node) Error!*Node {
        const n = try self.a.create(Node);
        n.* = node;
        return n;
    }

    // and_or ((; | &) and_or)* up to a newline
    fn topList(self: *Parser) Error!*Node {
        var items: std.ArrayListUnmanaged(ListItem) = .{};
        while (true) {
            const node = try self.andOr();
            const t = try self.peek();
            const background = t.kind == .amp;
            try items.append(self.a, .{ .node = node, .background = background });
            if (t.kind != .semi and t.kind != .amp) break;
            self.consume();
            const after = try self.peek();
            if (after.kind == .newline or after.kind == .eof) break;
        }
        if (items.items.len == 1 and !items.items[0].background) return items.items[0].node;
        return self.newNode(.{ .list = try items.toOwnedSlice(self.a) });
    }

    fn isTerminator(t: Token) bool {
        if (t.kind == .rparen or t.kind == .dsemi) return true;
        if (t.kind != .word) return false;
        const words = [_][]const u8{ "then", "else", "elif", "fi", "do", "done", "esac", "}" };
        for (words) |w| if (std.mem.eql(u8, t.text, w)) return true;
        return false;
    }

    // Up to a closing word.
    fn compoundList(self: *Parser) Error!*Node {
        var items: std.ArrayListUnmanaged(ListItem) = .{};
        while (true) {
            try self.skipNewlines();
            const t = try self.peek();
            if (t.kind == .eof) return error.Incomplete;
            if (isTerminator(t)) break;
            const node = try self.andOr();
            const sep = try self.peek();
            var background = false;
            switch (sep.kind) {
                .semi, .newline => self.consume(),
                .amp => {
                    self.consume();
                    background = true;
                },
                else => if (!isTerminator(sep)) return self.fail(sep, "unexpected"),
            }
            try items.append(self.a, .{ .node = node, .background = background });
        }
        if (items.items.len == 0) return self.fail(try self.peek(), "unexpected");
        if (items.items.len == 1 and !items.items[0].background) return items.items[0].node;
        return self.newNode(.{ .list = try items.toOwnedSlice(self.a) });
    }

    fn andOr(self: *Parser) Error!*Node {
        const first = try self.pipeline();
        var rest: std.ArrayListUnmanaged(AndOr) = .{};
        while (true) {
            const t = try self.peek();
            if (t.kind != .and_if and t.kind != .or_if) break;
            self.consume();
            try self.skipNewlines();
            try rest.append(self.a, .{ .or_ = t.kind == .or_if, .node = try self.pipeline() });
        }
        if (rest.items.len == 0) return first;
        return self.newNode(.{ .and_or = .{ .first = first, .rest = try rest.toOwnedSlice(self.a) } });
    }

    fn pipeline(self: *Parser) Error!*Node {
        var negate = false;
        if (isWord(try self.peek(), "!")) {
            self.consume();
            negate = true;
        }
        var commands: std.ArrayListUnmanaged(*Node) = .{};
        try commands.append(self.a, try self.command());
        while ((try self.peek()).kind == .pipe) {
            self.consume();
            try self.skipNewlines();
            try commands.append(self.a, try self.command());
        }
        if (commands.items.len == 1 and !negate) return commands.items[0];
        return self.newNode(.{ .pipeline = .{ .commands = try commands.toOwnedSlice(self.a), .negate = negate } });
    }

    fn command(self: *Parser) Error!*Node {
        const t = try self.peek();
        if (t.kind == .lparen) {
            self.consume();
            const body = try self.compoundList();
            try self.expect(.rparen, null);
            return self.withRedirs(try self.newNode(.{ .subshell = body }));
        }
        if (t.kind == .word) {
            if (std.mem.eql(u8, t.text, "{")) {
                self.consume();
                const body = try self.compoundList();
                try self.expect(.word, "}");
                return self.withRedirs(try self.newNode(.{ .group = body }));
            }
            if (std.mem.eql(u8, t.text, "if")) return self.withRedirs(try self.ifClause());
            if (std.mem.eql(u8, t.text, "while") or std.mem.eql(u8, t.text, "until")) return self.withRedirs(try self.loopClause());
            if (std.mem.eql(u8, t.text, "for")) return self.withRedirs(try self.forClause());
            if (std.mem.eql(u8, t.text, "case")) return self.withRedirs(try self.caseClause());
            if (std.mem.eql(u8, t.text, "function")) {
                self.consume();
                const name = try self.take();
                if (name.kind != .word or !isName(name.text)) return self.fail(name, "bad function name");
                if ((try self.peek()).kind == .lparen) {
                    self.consume();
                    try self.expect(.rparen, null);
                }
                return self.functionBody(name.text);
            }
            if (isTerminator(t)) return self.fail(t, "unexpected");
            self.consume();
            if (isName(t.text) and (try self.peek()).kind == .lparen) {
                self.consume();
                try self.expect(.rparen, null);
                return self.functionBody(t.text);
            }
            return self.simple(t);
        }
        return self.simple(null);
    }

    fn functionBody(self: *Parser, name: []const u8) Error!*Node {
        try self.skipNewlines();
        const t = try self.peek();
        const compound = t.kind == .lparen or (t.kind == .word and (std.mem.eql(u8, t.text, "{") or
            std.mem.eql(u8, t.text, "if") or std.mem.eql(u8, t.text, "while") or
            std.mem.eql(u8, t.text, "until") or std.mem.eql(u8, t.text, "for") or std.mem.eql(u8, t.text, "case")));
        if (!compound) return self.fail(t, "expected a function body, not");
        const start = t.start;
        _ = try self.command();
        return self.newNode(.{ .function = .{ .name = name, .body_src = self.src[start..self.last_end] } });
    }

    fn expect(self: *Parser, kind: Kind, word: ?[]const u8) Error!void {
        const t = try self.peek();
        if (t.kind != kind or (word != null and !std.mem.eql(u8, t.text, word.?))) return self.fail(t, "unexpected");
        self.consume();
    }

    fn ifClause(self: *Parser) Error!*Node {
        self.consume(); // if
        var branches: std.ArrayListUnmanaged(Branch) = .{};
        var else_body: ?*Node = null;
        while (true) {
            const cond = try self.compoundList();
            try self.expect(.word, "then");
            const body = try self.compoundList();
            try branches.append(self.a, .{ .cond = cond, .body = body });
            const t = try self.take();
            if (isWord(t, "elif")) continue;
            if (isWord(t, "else")) {
                else_body = try self.compoundList();
                try self.expect(.word, "fi");
                break;
            }
            if (isWord(t, "fi")) break;
            return self.fail(t, "unexpected");
        }
        return self.newNode(.{ .if_ = .{ .branches = try branches.toOwnedSlice(self.a), .else_body = else_body } });
    }

    fn loopClause(self: *Parser) Error!*Node {
        const until = std.mem.eql(u8, (try self.take()).text, "until");
        const cond = try self.compoundList();
        try self.expect(.word, "do");
        const body = try self.compoundList();
        try self.expect(.word, "done");
        return self.newNode(.{ .loop = .{ .cond = cond, .body = body, .until = until } });
    }

    fn forClause(self: *Parser) Error!*Node {
        self.consume(); // for
        const name = try self.take();
        if (name.kind != .word or !isName(name.text)) return self.fail(name, "bad for variable");
        try self.skipNewlines();
        var words: ?[]const []const u8 = null;
        var t = try self.peek();
        if (isWord(t, "in")) {
            self.consume();
            var list: std.ArrayListUnmanaged([]const u8) = .{};
            while (true) {
                t = try self.peek();
                if (t.kind != .word) break;
                try list.append(self.a, t.text);
                self.consume();
            }
            if (t.kind != .semi and t.kind != .newline) return self.fail(t, "unexpected");
            self.consume();
            words = try list.toOwnedSlice(self.a);
        } else if (t.kind == .semi) {
            self.consume();
        }
        try self.skipNewlines();
        try self.expect(.word, "do");
        const body = try self.compoundList();
        try self.expect(.word, "done");
        return self.newNode(.{ .for_ = .{ .name = name.text, .words = words, .body = body } });
    }

    fn caseClause(self: *Parser) Error!*Node {
        self.consume(); // case
        const word = try self.take();
        if (word.kind != .word) return self.fail(word, "unexpected");
        try self.skipNewlines();
        try self.expect(.word, "in");
        var items: std.ArrayListUnmanaged(CaseItem) = .{};
        while (true) {
            try self.skipNewlines();
            var t = try self.peek();
            if (isWord(t, "esac")) {
                self.consume();
                break;
            }
            if (t.kind == .lparen) self.consume();
            var patterns: std.ArrayListUnmanaged([]const u8) = .{};
            while (true) {
                t = try self.take();
                if (t.kind != .word) return self.fail(t, "unexpected");
                try patterns.append(self.a, t.text);
                t = try self.take();
                if (t.kind == .rparen) break;
                if (t.kind != .pipe) return self.fail(t, "unexpected");
            }
            try self.skipNewlines();
            t = try self.peek();
            var body: ?*Node = null;
            if (t.kind != .dsemi and !isWord(t, "esac")) body = try self.compoundList();
            try items.append(self.a, .{ .patterns = try patterns.toOwnedSlice(self.a), .body = body });
            t = try self.peek();
            if (t.kind == .dsemi) {
                self.consume();
                continue;
            }
            if (isWord(t, "esac")) {
                self.consume();
                break;
            }
            return self.fail(t, "unexpected");
        }
        return self.newNode(.{ .case_ = .{ .word = word.text, .items = try items.toOwnedSlice(self.a) } });
    }

    fn isRedirOp(kind: Kind) bool {
        return switch (kind) {
            .less, .great, .dgreat, .dless, .dlessdash, .tless, .lessand, .greatand, .lessgreat, .clobber => true,
            else => false,
        };
    }

    fn withRedirs(self: *Parser, node: *Node) Error!*Node {
        var redirs: std.ArrayListUnmanaged(Redir) = .{};
        while (isRedirOp((try self.peek()).kind)) {
            try redirs.append(self.a, try self.redirect(try self.take()));
        }
        if (redirs.items.len == 0) return node;
        return self.newNode(.{ .redirected = .{ .node = node, .redirs = try redirs.toOwnedSlice(self.a) } });
    }

    fn redirect(self: *Parser, op: Token) Error!Redir {
        const target = try self.take();
        if (target.kind != .word) return self.fail(target, "expected a file name, not");
        var r: Redir = .{ .fd = 1, .op = .output, .target = target.text };
        switch (op.kind) {
            .less => r = .{ .fd = 0, .op = .input, .target = target.text },
            .great, .clobber => {},
            .dgreat => r.op = .append,
            .lessand => r = .{ .fd = 0, .op = .dup_input, .target = target.text },
            .greatand => r.op = .dup_output,
            .lessgreat => r = .{ .fd = 0, .op = .read_write, .target = target.text },
            .tless => r = .{ .fd = 0, .op = .herestring, .target = target.text },
            .dless, .dlessdash => {
                const doc = try self.a.create(Heredoc);
                const quoted = std.mem.indexOfAny(u8, target.text, "'\"\\") != null;
                doc.* = .{
                    .delimiter = if (quoted) try unquote(self.a, target.text) else target.text,
                    .expand = !quoted,
                    .strip_tabs = op.kind == .dlessdash,
                };
                try self.pending.append(self.a, doc);
                r = .{ .fd = 0, .op = .heredoc, .heredoc = doc };
            },
            else => unreachable,
        }
        if (op.fd) |fd| r.fd = fd;
        return r;
    }

    fn simple(self: *Parser, first: ?Token) Error!*Node {
        var assigns: std.ArrayListUnmanaged(Assign) = .{};
        var words: std.ArrayListUnmanaged([]const u8) = .{};
        var redirs: std.ArrayListUnmanaged(Redir) = .{};
        var pending_first = first;
        while (true) {
            const t = if (pending_first) |f| f else try self.peek();
            if (pending_first == null) {
                if (isRedirOp(t.kind)) {
                    self.consume();
                    try redirs.append(self.a, try self.redirect(t));
                    continue;
                }
                if (t.kind != .word) break;
                self.consume();
            }
            pending_first = null;
            if (words.items.len == 0) {
                if (try self.assignment(t.text)) |assign| {
                    try assigns.append(self.a, assign);
                    continue;
                }
            }
            try words.append(self.a, t.text);
        }
        if (assigns.items.len == 0 and words.items.len == 0 and redirs.items.len == 0)
            return self.fail(try self.peek(), "unexpected");
        return self.newNode(.{ .simple = .{
            .assigns = try assigns.toOwnedSlice(self.a),
            .words = try words.toOwnedSlice(self.a),
            .redirs = try redirs.toOwnedSlice(self.a),
        } });
    }

    fn assignment(self: *Parser, text: []const u8) Error!?Assign {
        const prefix = assignmentPrefix(text) orelse return null;
        var assign: Assign = .{ .name = prefix.name, .index = prefix.index, .append = prefix.append };
        const value = text[prefix.len..];
        if (value.len >= 2 and value[0] == '(' and value[value.len - 1] == ')') {
            var inner = Parser.init(self.a, value[1 .. value.len - 1]);
            var list: std.ArrayListUnmanaged([]const u8) = .{};
            while (true) {
                const t = inner.scan() catch return self.fail(.{ .kind = .word, .start = 0, .end = 0 }, "bad array");
                switch (t.kind) {
                    .eof => break,
                    .newline => {},
                    .word => try list.append(self.a, t.text),
                    else => {
                        self.message = "bad array";
                        return error.Syntax;
                    },
                }
            }
            assign.array = try list.toOwnedSlice(self.a);
        } else {
            assign.value = value;
        }
        return assign;
    }
};

// Found by reading the commands, as a ) in them (of a case pattern,
// say) doesn't end it.
pub fn commandSubstitutionEnd(a: Allocator, src: []const u8, start: usize) Error!usize {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var p = Parser.init(arena.allocator(), src);
    p.pos = start;
    while (true) {
        try p.skipNewlines();
        const t = try p.peek();
        if (t.kind == .rparen) return t.start;
        if (t.kind == .eof) return error.Incomplete;
        _ = try p.andOr();
        const sep = try p.peek();
        switch (sep.kind) {
            .semi, .amp, .newline => p.consume(),
            .rparen => {},
            else => return p.fail(sep, "unexpected"),
        }
    }
}

const Prefix = struct { name: []const u8, index: ?[]const u8, append: bool, len: usize };

// NAME= NAME+= NAME[index]= at the start of a word
fn assignmentPrefix(text: []const u8) ?Prefix {
    var i: usize = 0;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
    if (i == 0 or std.ascii.isDigit(text[0])) return null;
    const name = text[0..i];
    var index: ?[]const u8 = null;
    if (i < text.len and text[i] == '[') {
        const close = std.mem.indexOfScalarPos(u8, text, i, ']') orelse return null;
        index = text[i + 1 .. close];
        i = close + 1;
    }
    var append = false;
    if (i < text.len and text[i] == '+') {
        append = true;
        i += 1;
    }
    if (i >= text.len or text[i] != '=') return null;
    return .{ .name = name, .index = index, .append = append, .len = i + 1 };
}

pub fn isName(text: []const u8) bool {
    if (text.len == 0 or !(std.ascii.isAlphabetic(text[0]) or text[0] == '_')) return false;
    for (text[1..]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

// For here-document delimiters.
fn unquote(a: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (quote == 0 and (c == '\'' or c == '"')) {
            quote = c;
        } else if (c == quote) {
            quote = 0;
        } else if (c == '\\' and quote != '\'' and i + 1 < text.len) {
            i += 1;
            try out.append(a, text[i]);
        } else {
            try out.append(a, c);
        }
    }
    return out.toOwnedSlice(a);
}
