// KILO [FILE]: the kilo text editor, ported to Zig.
// Changes from the C version: diffed cell-grid rendering for the slow
// UEFI console (the bottom-right cell is never written, so UEFI can't
// scroll), selection with copy/cut/paste, undo, CRLF kept, UTF-8.
// Everything that depends on ZDOS is in the ZDOS SHIM section.
//
// This port is significant rework under the 2-Clause BSD License:
// Copyright (c) 2026 Aleksandr Vankov. All rights reserved.
// Original kilo:
// Copyright (c) 2016, Salvatore Sanfilippo <antirez at gmail dot com>
// All rights reserved.
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// * Redistributions of source code must retain the above copyright notice,
//   this list of conditions and the following disclaimer.
// * Redistributions in binary form must reproduce the above copyright notice,
//   this list of conditions and the following disclaimer in the documentation
//   and/or other materials provided with the distribution.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

const std = @import("std");
const zdos = @import("zdos/zdos.zig");
comptime {
    _ = zdos;
}

pub const zdos_file_version = [4]u8{ 0, 8, 0, 0 };

// SETTINGS

const kilo_version = "0.8.0";
const tab_stop = 4;
const quit_times_default = 3;
const status_ttl_ms = 5000;

/// Sideways, scroll by a quarter of the width when the cursor leaves.
const jump_scroll = true;
/// New files (and files without a line break) are saved with CRLF endings.
const new_file_crlf = false;
/// Two changed spans closer than this many cells are written as one.
const merge_gap = 6;
/// Ctrl-Z goes back at most this many steps.
const max_undo = 200;
/// Use ESC[K for a blank line tail only if it is longer than this.
const erase_min = 4;

// ZDOS SHIM

/// The file is cut to its length after writing.
const write_mode: zdos.OpenMode = .write;

/// Reads a field of zdos.Pos under whichever name the ABI uses.
fn posField(p: zdos.Pos, comptime names: []const []const u8) usize {
    inline for (names) |n| {
        if (@hasField(zdos.Pos, n)) return @intCast(@field(p, n));
    }
    @compileError("zdos.Pos: unknown field names, adjust posField() calls");
}

fn termCols() usize {
    return posField(zdos.screenSize(), &.{ "col", "cols", "x", "column", "width" });
}

fn termRows() usize {
    return posField(zdos.screenSize(), &.{ "row", "rows", "y", "height" });
}

/// Names of zdos.Scan constants (snake_case; UPPER_CASE is tried too).
const scan_names = [_]struct { []const u8, u32 }{
    .{ "up", K.arrow_up },
    .{ "arrow_up", K.arrow_up },
    .{ "cursor_up", K.arrow_up },
    .{ "down", K.arrow_down },
    .{ "arrow_down", K.arrow_down },
    .{ "cursor_down", K.arrow_down },
    .{ "left", K.arrow_left },
    .{ "arrow_left", K.arrow_left },
    .{ "cursor_left", K.arrow_left },
    .{ "right", K.arrow_right },
    .{ "arrow_right", K.arrow_right },
    .{ "cursor_right", K.arrow_right },
    .{ "home", K.home },
    .{ "end", K.end },
    .{ "page_up", K.page_up },
    .{ "pgup", K.page_up },
    .{ "prior", K.page_up },
    .{ "page_down", K.page_down },
    .{ "pgdn", K.page_down },
    .{ "pgdown", K.page_down },
    .{ "next", K.page_down },
    .{ "delete", K.del },
    .{ "del", K.del },
    .{ "escape", K.escape },
    .{ "esc", K.escape },
    .{ "backspace", K.backspace },
    .{ "enter", '\r' },
    .{ "return", '\r' },
    .{ "tab", '\t' },
};

fn upper(comptime s: []const u8) []const u8 {
    comptime {
        var buf: [s.len]u8 = undefined;
        for (s, 0..) |ch, i| buf[i] = std.ascii.toUpper(ch);
        const out = buf;
        return &out;
    }
}

fn scanToKey(s: anytype) ?u32 {
    inline for (scan_names) |e| {
        inline for (.{ e[0], comptime upper(e[0]) }) |name| {
            if (@hasDecl(zdos.Scan, name)) {
                if (s == @field(zdos.Scan, name)) return e[1];
            }
        }
    }
    return null;
}

fn ctrlHeld(k: zdos.Key) bool {
    const T = @TypeOf(k.mods);
    return switch (@typeInfo(T)) {
        .int => k.mods & zdos.Mod.ctrl != 0,
        .@"struct" => k.mods.ctrl,
        else => @compileError("Key.mods: adjust ctrlHeld()"),
    };
}

/// Characters as code points, control codes 1..26, K.* above every code point;
/// null for keys the editor ignores.
fn translateKey(k: zdos.Key) ?u32 {
    if (scanToKey(k.scan)) |key| return key;
    var c: u32 = k.char;
    if (c == 0) return null;
    if (ctrlHeld(k) and c < 128 and std.ascii.isAlphabetic(@intCast(c))) c &= 0x1f;
    return switch (c) {
        8 => K.backspace, // Ctrl-H and Backspace are the same key
        10 => '\r',
        else => c,
    };
}

fn nextKey() u32 {
    while (true) {
        if (translateKey(zdos.readKey())) |c| return c;
    }
}

// KEYS

const K = struct {
    const backspace: u32 = 127;
    const escape: u32 = 27;
    // Above every code point, so they never clash with text:
    const arrow_left: u32 = 0x200000;
    const arrow_right: u32 = 0x200001;
    const arrow_up: u32 = 0x200002;
    const arrow_down: u32 = 0x200003;
    const del: u32 = 0x200004;
    const home: u32 = 0x200005;
    const end: u32 = 0x200006;
    const page_up: u32 = 0x200007;
    const page_down: u32 = 0x200008;
};

/// CTRL_KEY(k)
const ck = struct {
    const a: u32 = 'a' & 0x1f;
    const c: u32 = 'c' & 0x1f;
    const p: u32 = 'p' & 0x1f;
    const v: u32 = 'v' & 0x1f;
    const x: u32 = 'x' & 0x1f;
    const z: u32 = 'z' & 0x1f;
    const f: u32 = 'f' & 0x1f;
    const h: u32 = 'h' & 0x1f;
    const l: u32 = 'l' & 0x1f;
    const q: u32 = 'q' & 0x1f;
    const s: u32 = 's' & 0x1f;
};

// MEMORY: a small growable array on the ZDOS heap

const heap = zdos.allocator;
const Oom = error{OutOfMemory};

fn Vec(comptime T: type) type {
    return struct {
        items: []T = &.{},
        cap: usize = 0,

        const Self = @This();

        fn deinit(self: *Self) void {
            if (self.cap != 0) heap.free(self.items.ptr[0..self.cap]);
            self.* = .{};
        }

        fn reserve(self: *Self, n: usize) Oom!void {
            if (n <= self.cap) return;
            var new_cap: usize = if (self.cap == 0) 16 else self.cap;
            while (new_cap < n) new_cap *= 2;
            const mem = try heap.alloc(T, new_cap);
            @memcpy(mem[0..self.items.len], self.items);
            if (self.cap != 0) heap.free(self.items.ptr[0..self.cap]);
            self.items = mem[0..self.items.len];
            self.cap = new_cap;
        }

        fn resize(self: *Self, n: usize) Oom!void {
            try self.reserve(n);
            self.items.len = n;
        }

        fn clear(self: *Self) void {
            self.items.len = 0;
        }

        fn append(self: *Self, x: T) Oom!void {
            try self.reserve(self.items.len + 1);
            self.items.len += 1;
            self.items[self.items.len - 1] = x;
        }

        fn appendSlice(self: *Self, s: []const T) Oom!void {
            const old = self.items.len;
            try self.resize(old + s.len);
            @memcpy(self.items[old..][0..s.len], s);
        }

        fn insertSlice(self: *Self, at: usize, s: []const T) Oom!void {
            const old = self.items.len;
            try self.resize(old + s.len);
            var i = old;
            while (i > at) {
                i -= 1;
                self.items[i + s.len] = self.items[i];
            }
            @memcpy(self.items[at..][0..s.len], s);
        }

        fn insert(self: *Self, at: usize, x: T) Oom!void {
            return self.insertSlice(at, &[_]T{x});
        }

        fn removeAt(self: *Self, at: usize) T {
            const v = self.items[at];
            var i = at;
            while (i + 1 < self.items.len) : (i += 1) self.items[i] = self.items[i + 1];
            self.items.len -= 1;
            return v;
        }

        /// Moving the rest once.
        fn removeRange(self: *Self, at: usize, n: usize) void {
            std.mem.copyForwards(T, self.items[at .. self.items.len - n], self.items[at + n ..]);
            self.items.len -= n;
        }

        /// Moving the rest once.
        fn insertCopies(self: *Self, at: usize, n: usize, x: T) Oom!void {
            const old = self.items.len;
            try self.resize(old + n);
            std.mem.copyBackwards(T, self.items[at + n ..], self.items[at..old]);
            @memset(self.items[at..][0..n], x);
        }
    };
}

// SYNTAX HIGHLIGHTING DATA

const Hl = enum(u8) { normal, comment, mlcomment, keyword1, keyword2, string, number, match };

const hl_numbers: u8 = 1 << 0;
const hl_strings: u8 = 1 << 1;
/// ' starts only a character literal, so Rust lifetimes don't open a string.
const hl_char_quotes: u8 = 1 << 2;
/// ` quotes a string too (JavaScript template strings, on one line).
const hl_backticks: u8 = 1 << 3;

const Syntax = struct {
    filetype: []const u8,
    /// ".ext" matches the extension, others match anywhere in the name.
    filematch: []const []const u8,
    /// A trailing '|' marks a type (second keyword colour).
    keywords: []const []const u8,
    singleline_comment_start: []const u8,
    multiline_comment_start: []const u8,
    multiline_comment_end: []const u8,
    flags: u8,
};

const c_extensions = [_][]const u8{ ".c", ".h", ".cpp" };
const c_keywords = [_][]const u8{
    "switch", "if",      "while",   "for",    "break",     "continue", "return", "else",
    "struct", "union",   "typedef", "static", "enum",      "class",    "case",   "int|",
    "long|",  "double|", "float|",  "char|",  "unsigned|", "signed|",  "void|",
};

const sh_extensions = [_][]const u8{".sh"};
const sh_keywords = [_][]const u8{
    "if",      "then",    "else",     "elif",     "fi",
    "case",    "esac",    "for",      "while",    "until",
    "do",      "done",    "in",       "select",   "function",
    "time",    "coproc",  "break",    "continue", "return",
    "exit",    "shift",   "exec",     "eval",     "set",
    "unset",   "export",  "readonly", "local",    "declare",
    "typeset", "alias",   "unalias",  "trap",     "wait",
    "read",    "getopts", "source",   "test",     "true",
    "false",   "command", "builtin",  "type",     "hash",
    "jobs",    "fg",      "bg",       "disown",   "suspend",
    "umask",   "ulimit",  "times",    "pwd",      "cd",
    "echo",    "printf",  "kill",
};

const py_extensions = [_][]const u8{".py"};
const py_keywords = [_][]const u8{
    "False",   "None",       "True",
    "and",     "as",         "assert",
    "async",   "await",      "break",
    "class",   "continue",   "def",
    "del",     "elif",       "else",
    "except",  "finally",    "for",
    "from",    "global",     "if",
    "import",  "in",         "is",
    "lambda",  "nonlocal",   "not",
    "or",      "pass",       "raise",
    "return",  "try",        "while",
    "with",    "yield",      "int|",
    "float|",  "complex|",   "str|",
    "bool|",   "list|",      "dict|",
    "set|",    "frozenset|", "tuple|",
    "bytes|",  "bytearray|", "range|",
    "object|", "type|",
};

const zig_extensions = [_][]const u8{".zig"};
const zig_keywords = [_][]const u8{
    "const",  "var",    "fn",     "pub",      "if",     "else",   "while",       "for",
    "switch", "return", "break",  "continue", "try",    "catch",  "defer",       "errdefer",
    "struct", "enum",   "union",  "error",    "orelse", "and",    "or",          "comptime",
    "inline", "test",   "extern", "export",   "packed", "opaque", "unreachable", "u8|",
    "u16|",   "u32|",   "u64|",   "usize|",   "i8|",    "i16|",   "i32|",        "i64|",
    "isize|", "f32|",   "f64|",   "bool|",    "void|",  "type|",  "anytype|",    "noreturn|",
};

const java_extensions = [_][]const u8{".java"};
const java_keywords = [_][]const u8{
    "abstract",   "assert",       "break",  "case",    "catch",      "class",
    "continue",   "default",      "do",     "else",    "enum",       "extends",
    "final",      "finally",      "for",    "if",      "implements", "import",
    "instanceof", "interface",    "native", "new",     "package",    "private",
    "protected",  "public",       "return", "static",  "strictfp",   "super",
    "switch",     "synchronized", "this",   "throw",   "throws",     "transient",
    "try",        "volatile",     "while",  "var",     "record",     "yield",
    "boolean|",   "byte|",        "char|",  "short|",  "int|",       "long|",
    "float|",     "double|",      "void|",  "String|", "Object|",    "true|",
    "false|",     "null|",
};

const js_extensions = [_][]const u8{ ".js", ".mjs", ".cjs", ".jsx" };
const js_keywords = [_][]const u8{
    "async",      "await",    "break",     "case",    "catch",      "class",
    "const",      "continue", "debugger",  "default", "delete",     "do",
    "else",       "export",   "extends",   "finally", "for",        "from",
    "function",   "if",       "import",    "in",      "instanceof", "let",
    "new",        "of",       "return",    "static",  "super",      "switch",
    "this",       "throw",    "try",       "typeof",  "var",        "void",
    "while",      "with",     "yield",     "true|",   "false|",     "null|",
    "undefined|", "NaN|",     "Infinity|", "Array|",  "Object|",    "String|",
    "Number|",    "Boolean|", "Promise|",  "Map|",    "Set|",       "JSON|",
    "Math|",      "console|",
};

const rust_extensions = [_][]const u8{".rs"};
const rust_keywords = [_][]const u8{
    "as",     "async",   "await",   "break",  "const",  "continue", "crate",
    "dyn",    "else",    "enum",    "extern", "fn",     "for",      "if",
    "impl",   "in",      "let",     "loop",   "match",  "mod",      "move",
    "mut",    "pub",     "ref",     "return", "self",   "Self",     "static",
    "struct", "super",   "trait",   "type",   "unsafe", "use",      "where",
    "while",  "true|",   "false|",  "i8|",    "i16|",   "i32|",     "i64|",
    "i128|",  "isize|",  "u8|",     "u16|",   "u32|",   "u64|",     "u128|",
    "usize|", "f32|",    "f64|",    "bool|",  "char|",  "str|",     "String|",
    "Vec|",   "Option|", "Result|", "Box|",   "Some|",  "None|",    "Ok|",
    "Err|",
};

const lua_extensions = [_][]const u8{".lua"};
const lua_keywords = [_][]const u8{
    "and",    "break",    "do",      "else",    "elseif",        "end",
    "for",    "function", "goto",    "if",      "in",            "local",
    "not",    "or",       "repeat",  "return",  "then",          "until",
    "while",  "nil|",     "true|",   "false|",  "self|",         "require|",
    "print|", "pairs|",   "ipairs|", "type|",   "tostring|",     "tonumber|",
    "error|", "assert|",  "pcall|",  "select|", "setmetatable|", "getmetatable|",
};

const cmd_extensions = [_][]const u8{ ".bat", ".cmd" };
const cmd_keywords = [_][]const u8{
    "HELP",  "VER",      "CLS",        "DRIVES",
    "CD",    "CHDIR",    "DIR",        "LS",
    "TYPE",  "CAT",      "FIND",       "FINDSTR",
    "SORT",  "FC",       "COMP",       "WHERE",
    "MD",    "MKDIR",    "MKFILE",     "ECHO",
    "DEL",   "RM",       "ERASE",      "RD",
    "RMDIR", "DELTREE",  "COPY",       "CP",
    "XCOPY", "COPY CON", "MOV",        "MV",
    "REN",   "ATTRIB",   "DATE",       "MEM",
    "VOL",   "LABEL",    "SET",        "PATH",
    "CALL",  "PAUSE",    "CHOICE",     "EXIT",
    "REM",   "@ECHO",    "ERRORLEVEL", "IF",
    "ELSE",  "DO",       "IN",         "SHIFT",
    "BREAK", "CALL",     "PAUSE",      "CHOICE",
};

const hldb = [_]Syntax{
    .{
        .filetype = "c",
        .filematch = &c_extensions,
        .keywords = &c_keywords,
        .singleline_comment_start = "//",
        .multiline_comment_start = "/*",
        .multiline_comment_end = "*/",
        .flags = hl_numbers | hl_strings,
    },
    .{
        .filetype = "zig",
        .filematch = &zig_extensions,
        .keywords = &zig_keywords,
        .singleline_comment_start = "//",
        .multiline_comment_start = "",
        .multiline_comment_end = "",
        .flags = hl_numbers | hl_strings,
    },
    .{
        .filetype = "py",
        .filematch = &py_extensions,
        .keywords = &py_keywords,
        .singleline_comment_start = "#",
        .multiline_comment_start = "",
        .multiline_comment_end = "",
        .flags = hl_numbers | hl_strings,
    },
    .{
        .filetype = "java",
        .filematch = &java_extensions,
        .keywords = &java_keywords,
        .singleline_comment_start = "//",
        .multiline_comment_start = "/*",
        .multiline_comment_end = "*/",
        .flags = hl_numbers | hl_strings,
    },
    .{
        .filetype = "js",
        .filematch = &js_extensions,
        .keywords = &js_keywords,
        .singleline_comment_start = "//",
        .multiline_comment_start = "/*",
        .multiline_comment_end = "*/",
        .flags = hl_numbers | hl_strings | hl_backticks,
    },
    .{
        .filetype = "rust",
        .filematch = &rust_extensions,
        .keywords = &rust_keywords,
        .singleline_comment_start = "//",
        .multiline_comment_start = "/*",
        .multiline_comment_end = "*/",
        .flags = hl_numbers | hl_strings | hl_char_quotes,
    },
    .{
        .filetype = "lua",
        .filematch = &lua_extensions,
        .keywords = &lua_keywords,
        .singleline_comment_start = "--",
        .multiline_comment_start = "--[[",
        .multiline_comment_end = "]]",
        .flags = hl_numbers | hl_strings,
    },
    .{
        .filetype = "sh",
        .filematch = &sh_extensions,
        .keywords = &sh_keywords,
        .singleline_comment_start = "#",
        .multiline_comment_start = "",
        .multiline_comment_end = "",
        .flags = hl_numbers | hl_strings,
    },
    .{
        .filetype = "cmd",
        .filematch = &cmd_extensions,
        .keywords = &cmd_keywords,
        .singleline_comment_start = "#",
        .multiline_comment_start = "",
        .multiline_comment_end = "",
        .flags = hl_numbers | hl_strings,
    },
};

/// 'x' (one character, maybe several bytes) or '\...'.
fn isCharLiteral(s: []const u8) bool {
    if (s.len < 3) return false;
    if (s[1] == '\\') return true;
    const g = glyphAt(s, 1);
    return 1 + g.len < s.len and s[1 + g.len] == '\'';
}

fn isSeparator(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == 0 or std.mem.indexOfScalar(u8, ",.()+-/*=~%<>[];", c) != null;
}

// SCREEN CELLS AND COLOURS

// (attr << 24) | code point. attr: bits 0-3 = ANSI foreground digit
// (0-7, 9 = default), bit 4 = bold, bit 5 = reverse video.
const Cell = u32;
const attr_default: u8 = 9;
const attr_bold: u8 = 0x10;
const attr_rev: u8 = 0x20;
const blank_cell: Cell = (@as(Cell, attr_default) << 24) | ' ';
/// Never produced by compose(): forces a repaint of the cell.
const stale_cell: Cell = 0xFFFF_FFFF;

fn mkCell(cp: u21, attr: u8) Cell {
    return (@as(Cell, attr) << 24) | cp;
}

fn hlAttr(h: Hl) u8 {
    return switch (h) {
        .normal => attr_default,
        .comment, .mlcomment => 6, // cyan
        .keyword1 => 3 | attr_bold, // yellow
        .keyword2 => 2 | attr_bold, // green
        .string => 5 | attr_bold, // light magenta (changed from 5)
        .number => 1 | attr_bold, // light red (changed from 1)
        .match => 4 | attr_bold, // light blue (changed from 4)
    };
}

const Emitter = struct {
    out: *Vec(u8),
    attr: u8 = attr_default,
    /// Where the cursor will be after `out` (maxInt: unknown).
    tx: usize = std.math.maxInt(usize),
    ty: usize = std.math.maxInt(usize),
    failed: bool = false,

    fn raw(self: *Emitter, s: []const u8) void {
        self.out.appendSlice(s) catch {
            self.failed = true;
        };
    }

    fn moveTo(self: *Emitter, x: usize, y: usize) void {
        if (self.tx == x and self.ty == y) return;
        var b: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "\x1b[{d};{d}H", .{ y + 1, x + 1 }) catch return;
        self.raw(s);
        self.tx = x;
        self.ty = y;
    }

    fn setAttr(self: *Emitter, a: u8) void {
        if (a == self.attr) return;
        self.attr = a;
        if (a == attr_default) return self.raw("\x1b[0m");
        var b: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&b, "\x1b[0{s}{s};3{d}m", .{
            if (a & attr_bold != 0) ";1" else "",
            if (a & attr_rev != 0) ";7" else "",
            a & 15,
        }) catch return;
        self.raw(s);
    }

    /// All its UTF-8 bytes at once, so the console never gets half.
    fn char(self: *Emitter, cp: u21) void {
        var buf: [4]u8 = undefined;
        self.raw(encodeCp(cp, &buf));
        self.tx +%= 1;
    }
};

// DATA

// UTF-8 helpers (pure functions on bytes):

/// A byte that does not start valid UTF-8 is one character, shown '?'.
const Glyph = struct { cp: u21, len: usize };

fn glyphAt(bytes: []const u8, i: usize) Glyph {
    const bad: Glyph = .{ .cp = '?', .len = 1 };
    if (i >= bytes.len) return bad;
    const b = bytes[i];
    if (b < 0x80) return .{ .cp = b, .len = 1 };
    const n: usize = std.unicode.utf8ByteSequenceLength(b) catch return bad;
    if (i + n > bytes.len) return bad;
    const cp = std.unicode.utf8Decode(bytes[i..][0..n]) catch return bad;
    return .{ .cp = cp, .len = n };
}

/// 0 if at is 0.
fn prevGlyph(bytes: []const u8, at: usize) usize {
    var i: usize = 0;
    var prev: usize = 0;
    while (i < at and i < bytes.len) {
        prev = i;
        i += glyphAt(bytes, i).len;
    }
    return prev;
}

/// At most the length of bytes.
fn snapGlyph(bytes: []const u8, at: usize) usize {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = glyphAt(bytes, i).len;
        if (i + n > at) return i;
        i += n;
    }
    return bytes.len;
}

/// One per character.
fn widthBefore(bytes: []const u8, at: usize) usize {
    var i: usize = 0;
    var cols: usize = 0;
    while (i < at and i < bytes.len) : (cols += 1) i += glyphAt(bytes, i).len;
    return cols;
}

/// Fewer if s is shorter.
fn cutChars(s: []const u8, n: usize) []const u8 {
    var i: usize = 0;
    var k: usize = 0;
    while (i < s.len and k < n) : (k += 1) i += glyphAt(s, i).len;
    return s[0..i];
}

/// A tab goes to the next stop, any other character takes one column.
fn cxToRx(bytes: []const u8, cx: usize) usize {
    var rx: usize = 0;
    var i: usize = 0;
    while (i < cx and i < bytes.len) {
        if (bytes[i] == '\t') {
            rx += (tab_stop - 1) - (rx % tab_stop);
            i += 1;
        } else {
            i += glyphAt(bytes, i).len;
        }
        rx += 1;
    }
    return rx;
}

/// The length of bytes if there is none.
fn rxToCx(bytes: []const u8, rx: usize) usize {
    var cur_rx: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const len: usize = if (bytes[i] == '\t') 1 else glyphAt(bytes, i).len;
        if (bytes[i] == '\t') cur_rx += (tab_stop - 1) - (cur_rx % tab_stop);
        cur_rx += 1;
        if (cur_rx > rx) return i;
        i += len;
    }
    return bytes.len;
}

/// Printable ASCII, or a code point from U+00A0 up (not a surrogate).
fn isTextKey(c: u32) bool {
    if (c >= 32 and c < 127) return true;
    return c >= 0xA0 and c <= 0x10FFFF and (c < 0xD800 or c > 0xDFFF);
}

fn encodeCp(cp: u21, out: *[4]u8) []const u8 {
    const n = std.unicode.utf8Encode(cp, out) catch {
        out[0] = '?';
        return out[0..1];
    };
    return out[0..n];
}

const Row = struct {
    chars: Vec(u8) = .{},
    render: Vec(u8) = .{},
    hl: Vec(Hl) = .{},
    hl_open_comment: bool = false,

    fn deinit(self: *Row) void {
        self.chars.deinit();
        self.render.deinit();
        self.hl.deinit();
    }
};

fn rowCxToRx(row: *const Row, cx: usize) usize {
    return cxToRx(row.chars.items, cx);
}

fn rowRxToCx(row: *const Row, rx: usize) usize {
    return rxToCx(row.chars.items, rx);
}

fn scrollAxis(pos: usize, off: usize, size: usize, jump_in: usize) usize {
    const jump = @min(jump_in, size -| 1);
    if (pos < off) {
        const behind = off - pos;
        if (behind <= jump) return off -| jump;
        if (behind <= size) return pos;
        return pos -| jump;
    }
    if (pos >= off + size) {
        const ahead = pos + 1 - (off + size);
        if (ahead <= jump) return off + jump;
        if (ahead <= size) return pos + 1 - size;
        return (pos + 1 + jump) -| size;
    }
    return off;
}

fn fatal(msg: []const u8) noreturn {
    zdos.print("\x1b[0m");
    zdos.clearScreen();
    zdos.print("\x1b[H\x1b[?1049l");
    zdos.showCursor(true);
    zdos.printf("kilo: {s}\n", .{msg});
    zdos.exit(1);
}

fn isStopChar(c: u8) bool {
    return c == 0 or std.mem.indexOfScalar(u8, " '\"\n()[].#<>", c) != null;
}

fn normalMovement(key: u32) u32 {
    return switch (key) {
        'h' => K.arrow_left,
        'j' => K.arrow_down,
        'k' => K.arrow_up,
        'l' => K.arrow_right,
        '\r' => K.arrow_down,
        ' ' => K.arrow_right,
        K.backspace => K.arrow_left,
        else => key,
    };
}

const Mode = enum { insert, normal };

/// Undo: rows [at, at + new_n) were `old` (old_n lines) before.
const Change = struct {
    at: usize,
    old_n: usize,
    new_n: usize,
    old: Vec(u8) = .{},
};

/// Undone together; the cursor before it.
const UndoStep = struct {
    changes: Vec(Change) = .{},
    cx: usize,
    cy: usize,

    fn deinit(self: *UndoStep) void {
        for (self.changes.items) |*ch| ch.old.deinit();
        self.changes.deinit();
    }
};

/// Character x of row y.
const TextPos = struct {
    x: usize = 0,
    y: usize = 0,

    fn before(a: TextPos, b: TextPos) bool {
        return a.y < b.y or (a.y == b.y and a.x < b.x);
    }
};

const PromptCallback = *const fn (*Editor, []const u8, u32) void;

const Editor = struct {
    rows: Vec(Row) = .{},
    cx: usize = 0,
    cy: usize = 0,
    rx: usize = 0,
    rowoff: usize = 0,
    coloff: usize = 0,
    dirty: usize = 0,
    mode: Mode = .normal,
    quit: bool = false,
    quit_times: u8 = quit_times_default,
    filename: ?[]u8 = null,
    crlf: bool = new_file_crlf,
    is_new_file: bool = false,
    syntax: ?*const Syntax = null,

    status: [256]u8 = undefined,
    status_len: usize = 0,
    status_time: u64 = 0,
    /// While a prompt is open: the cursor column on the message bar.
    prompt_col: ?usize = null,

    // Incremental search:
    find_last: isize = -1,
    find_dir: isize = 1,
    find_saved_line: usize = 0,
    find_saved_hl: ?[]Hl = null,

    // Selection, from sel_anchor to the cursor, and clipboard:
    sel: bool = false,
    sel_anchor: TextPos = .{},
    clip: Vec(u8) = .{}, // lines separated by '\n'
    clip_lines: bool = false, // whole lines (copied without a selection)

    undo: Vec(UndoStep) = .{},
    recording: bool = false, // off while loading and while undoing
    step_open: bool = false, // the current key has started an undo step
    key_cx: usize = 0, // the cursor before the current key
    key_cy: usize = 0,
    typing_row: ?usize = null, // the last step was typing on this row

    cols: usize = 0,
    term_rows: usize = 0,
    text_rows: usize = 0,
    cells: Vec(Cell) = .{},
    shadow: Vec(Cell) = .{},
    out: Vec(u8) = .{},
    cursor_known: bool = false,
    term_cx: usize = 0,
    term_cy: usize = 0,
    /// What is on the screen (shadow):
    drawn_rowoff: usize = 0,
    drawn_coloff: usize = 0,

    fn setStatus(self: *Editor, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.status, fmt, args) catch self.status[0..];
        self.status_len = s.len;
        self.status_time = zdos.millis();
    }

    fn nrows(self: *const Editor) usize {
        return self.rows.items.len;
    }

    fn updateSyntaxRow(self: *Editor, at: usize) bool {
        const row = &self.rows.items[at];
        const render = row.render.items;
        const hl = row.hl.items;
        if (hl.len != render.len) return false; // an earlier allocation failed
        @memset(hl, .normal);

        const syn = self.syntax orelse return false;
        const scs = syn.singleline_comment_start;
        const mcs = syn.multiline_comment_start;
        const mce = syn.multiline_comment_end;

        var prev_sep = true;
        var in_string: u8 = 0;
        var in_comment = at > 0 and self.rows.items[at - 1].hl_open_comment;

        var i: usize = 0;
        while (i < render.len) {
            const c = render[i];
            const prev_hl: Hl = if (i > 0) hl[i - 1] else .normal;

            // A block comment start may begin like a line comment (Lua's --[[):
            if (scs.len != 0 and in_string == 0 and !in_comment) {
                if (std.mem.startsWith(u8, render[i..], scs) and
                    !(mcs.len != 0 and std.mem.startsWith(u8, render[i..], mcs)))
                {
                    @memset(hl[i..], .comment);
                    break;
                }
            }

            if (mcs.len != 0 and mce.len != 0 and in_string == 0) {
                if (in_comment) {
                    hl[i] = .mlcomment;
                    if (std.mem.startsWith(u8, render[i..], mce)) {
                        @memset(hl[i..][0..mce.len], .mlcomment);
                        i += mce.len;
                        in_comment = false;
                        prev_sep = true;
                    } else {
                        i += 1;
                    }
                    continue;
                } else if (std.mem.startsWith(u8, render[i..], mcs)) {
                    @memset(hl[i..][0..mcs.len], .mlcomment);
                    i += mcs.len;
                    in_comment = true;
                    continue;
                }
            }

            if (syn.flags & hl_strings != 0) {
                if (in_string != 0) {
                    hl[i] = .string;
                    if (c == '\\' and i + 1 < render.len) {
                        hl[i + 1] = .string;
                        i += 2;
                        continue;
                    }
                    if (c == in_string) in_string = 0;
                    i += 1;
                    prev_sep = true;
                    continue;
                } else if (c == '"' or (c == '\'' and (syn.flags & hl_char_quotes == 0 or isCharLiteral(render[i..]))) or
                    (c == '`' and syn.flags & hl_backticks != 0))
                {
                    in_string = c;
                    hl[i] = .string;
                    i += 1;
                    continue;
                }
            }

            if (syn.flags & hl_numbers != 0) {
                if ((std.ascii.isDigit(c) and (prev_sep or prev_hl == .number)) or
                    (c == '.' and prev_hl == .number))
                {
                    hl[i] = .number;
                    i += 1;
                    prev_sep = false;
                    continue;
                }
            }

            if (prev_sep) {
                var matched = false;
                for (syn.keywords) |kw| {
                    const kw2 = kw[kw.len - 1] == '|';
                    const klen = if (kw2) kw.len - 1 else kw.len;
                    if (std.mem.startsWith(u8, render[i..], kw[0..klen]) and
                        (i + klen >= render.len or isSeparator(render[i + klen])))
                    {
                        @memset(hl[i..][0..klen], if (kw2) Hl.keyword2 else Hl.keyword1);
                        i += klen;
                        matched = true;
                        break;
                    }
                }
                if (matched) {
                    prev_sep = false;
                    continue;
                }
            }

            prev_sep = isSeparator(c);
            i += 1;
        }

        const changed = row.hl_open_comment != in_comment;
        row.hl_open_comment = in_comment;
        return changed;
    }

    /// While a row's "inside a block comment" state changes, the next row
    /// is redone too.
    fn updateSyntaxFrom(self: *Editor, at: usize) void {
        var i = at;
        while (i < self.nrows()) : (i += 1) {
            if (!self.updateSyntaxRow(i)) break;
        }
    }

    fn rehighlightAll(self: *Editor) void {
        for (0..self.nrows()) |i| _ = self.updateSyntaxRow(i);
    }

    fn selectSyntax(self: *Editor) void {
        self.syntax = null;
        if (self.filename) |name| {
            const base_start = if (std.mem.lastIndexOfAny(u8, name, "\\/:")) |p| p + 1 else 0;
            const ext: ?[]const u8 = if (std.mem.lastIndexOfScalar(u8, name[base_start..], '.')) |p|
                name[base_start + p ..]
            else
                null;
            found: for (&hldb) |*s| {
                for (s.filematch) |m| {
                    const is_ext = m[0] == '.';
                    if ((is_ext and ext != null and std.ascii.eqlIgnoreCase(ext.?, m)) or
                        (!is_ext and std.mem.indexOf(u8, name, m) != null))
                    {
                        self.syntax = s;
                        break :found;
                    }
                }
            }
        }
        self.rehighlightAll();
    }

    fn updateRow(self: *Editor, at: usize) Oom!void {
        const row = &self.rows.items[at];
        row.render.clear();
        for (row.chars.items) |c| {
            if (c == '\t') {
                try row.render.append(' ');
                while (row.render.items.len % tab_stop != 0) try row.render.append(' ');
            } else {
                try row.render.append(c);
            }
        }
        try row.hl.resize(row.render.items.len);
        self.updateSyntaxFrom(at);
    }

    fn insertRow(self: *Editor, at: usize, s: []const u8) Oom!void {
        if (at > self.nrows()) return;
        self.record(at, 0, 1);
        try self.rows.insert(at, .{});
        errdefer {
            var r = self.rows.removeAt(at);
            r.deinit();
        }
        try self.rows.items[at].chars.appendSlice(s);
        try self.updateRow(at);
        self.dirty += 1;
        // The next row may have depended on this one:
        if (at + 1 < self.nrows()) self.updateSyntaxFrom(at + 1);
    }

    fn delRow(self: *Editor, at: usize) void {
        if (at >= self.nrows()) return;
        self.record(at, 1, 0);
        var r = self.rows.removeAt(at);
        r.deinit();
        self.dirty += 1;
        if (at < self.nrows()) self.updateSyntaxFrom(at);
    }

    /// One character, or a copy of one.
    fn rowInsertBytes(self: *Editor, ri: usize, at: usize, s: []const u8) Oom!void {
        self.record(ri, 1, 1);
        const row = &self.rows.items[ri];
        try row.chars.insertSlice(@min(at, row.chars.items.len), s);
        try self.updateRow(ri);
        self.dirty += 1;
    }

    fn rowAppendString(self: *Editor, ri: usize, s: []const u8) Oom!void {
        self.record(ri, 1, 1);
        try self.rows.items[ri].chars.appendSlice(s);
        try self.updateRow(ri);
        self.dirty += 1;
    }

    /// One character.
    fn rowDelChar(self: *Editor, ri: usize, at: usize, n: usize) Oom!void {
        const row = &self.rows.items[ri];
        if (at >= row.chars.items.len) return;
        self.record(ri, 1, 1);
        row.chars.removeRange(at, @min(n, row.chars.items.len - at));
        try self.updateRow(ri);
        self.dirty += 1;
    }

    fn insertChar(self: *Editor, cp: u32) Oom!void {
        if (self.cy == self.nrows()) try self.insertRow(self.nrows(), "");
        var buf: [4]u8 = undefined;
        const s = encodeCp(@intCast(cp), &buf);
        try self.rowInsertBytes(self.cy, self.cx, s);
        self.cx += s.len;
    }

    fn insertNewline(self: *Editor) Oom!void {
        if (self.cx == 0) {
            try self.insertRow(self.cy, "");
        } else {
            const tail = self.rows.items[self.cy].chars.items[self.cx..];
            try self.insertRow(self.cy + 1, tail);
            self.record(self.cy, 1, 1);
            self.rows.items[self.cy].chars.items.len = self.cx;
            try self.updateRow(self.cy);
        }
        self.cy += 1;
        self.cx = 0;
    }

    fn delChar(self: *Editor) Oom!void {
        if (self.cy == self.nrows()) return;
        if (self.cx == 0 and self.cy == 0) return;
        if (self.cx > 0) {
            // The whole character before the cursor goes:
            const at = prevGlyph(self.rows.items[self.cy].chars.items, self.cx);
            try self.rowDelChar(self.cy, at, self.cx - at);
            self.cx = at;
        } else {
            self.cx = self.rows.items[self.cy - 1].chars.items.len;
            try self.rowAppendString(self.cy - 1, self.rows.items[self.cy].chars.items);
            self.delRow(self.cy);
            self.cy -= 1;
        }
    }

    fn delRows(self: *Editor, at: usize, n: usize) void {
        if (n == 0) return;
        self.record(at, n, 0);
        for (self.rows.items[at..][0..n]) |*r| r.deinit();
        self.rows.removeRange(at, n);
        self.dirty += 1;
        if (at < self.nrows()) self.updateSyntaxFrom(at);
    }

    fn insertLines(self: *Editor, at: usize, text: []const u8) Oom!void {
        const n = std.mem.count(u8, text, "\n") + 1;
        self.record(at, 0, n);
        try self.rows.insertCopies(at, n, .{});
        var it = std.mem.splitScalar(u8, text, '\n');
        var i = at;
        while (it.next()) |line| : (i += 1) {
            try self.rows.items[i].chars.appendSlice(line);
            try self.updateRow(i);
        }
        self.dirty += 1;
        // The next row may have depended on these:
        if (at + n < self.nrows()) self.updateSyntaxFrom(at + n);
    }

    /// Notes rows [at, at + old_n) before they become new_n rows. Without
    /// memory for it, undo starts over (a gap would undo wrongly).
    fn record(self: *Editor, at: usize, old_n: usize, new_n: usize) void {
        if (!self.recording) return;
        self.recordOrFail(at, old_n, new_n) catch {
            self.clearUndo();
            self.setStatus("Out of memory: undo starts here", .{});
        };
    }

    fn recordOrFail(self: *Editor, at: usize, old_n: usize, new_n: usize) Oom!void {
        if (!self.step_open) {
            if (self.undo.items.len == max_undo) {
                var oldest = self.undo.removeAt(0);
                oldest.deinit();
            }
            try self.undo.append(.{ .cx = self.key_cx, .cy = self.key_cy });
            self.step_open = true;
        }
        const us = &self.undo.items[self.undo.items.len - 1];
        var change: Change = .{ .at = at, .old_n = old_n, .new_n = new_n };
        errdefer change.old.deinit();
        for (self.rows.items[at..][0..old_n], 0..) |*row, i| {
            if (i > 0) try change.old.append('\n');
            try change.old.appendSlice(row.chars.items);
        }
        try us.changes.append(change);
    }

    fn clearUndo(self: *Editor) void {
        for (self.undo.items) |*us| us.deinit();
        self.undo.clear();
        self.step_open = false;
        self.typing_row = null;
    }

    /// And the cursor.
    fn undoStep(self: *Editor) void {
        if (self.undo.items.len == 0) {
            self.setStatus("Nothing to undo", .{});
            return;
        }
        var us = self.undo.items[self.undo.items.len - 1];
        self.undo.items.len -= 1;
        defer us.deinit();
        self.recording = false;
        defer self.recording = true;
        var i = us.changes.items.len;
        while (i > 0) {
            i -= 1;
            const ch = us.changes.items[i];
            self.delRows(ch.at, ch.new_n);
            if (ch.old_n > 0) self.insertLines(ch.at, ch.old.items) catch {
                self.clearUndo();
                self.setStatus("Out of memory: can't undo", .{});
                return;
            };
        }
        self.cy = @min(us.cy, self.nrows());
        self.cx = us.cx;
        self.moveCursor(0); // only puts the cursor within the row
        self.dirty += 1;
        self.setStatus("Undone ({d} more)", .{self.undo.items.len});
    }

    /// On a row, at most at its end.
    fn clampPos(self: *const Editor, p: TextPos) TextPos {
        const n = self.nrows();
        if (n == 0) return .{};
        if (p.y >= n) return .{ .x = self.rows.items[n - 1].chars.items.len, .y = n - 1 };
        return .{ .x = @min(p.x, self.rows.items[p.y].chars.items.len), .y = p.y };
    }

    /// End not included; null if none.
    fn selRange(self: *const Editor) ?[2]TextPos {
        if (!self.sel) return null;
        const a = self.clampPos(self.sel_anchor);
        const b = self.clampPos(.{ .x = self.cx, .y = self.cy });
        if (a.x == b.x and a.y == b.y) return null;
        return if (a.before(b)) .{ a, b } else .{ b, a };
    }

    fn selectAll(self: *Editor) void {
        if (self.nrows() == 0) return;
        self.sel_anchor = .{};
        const end = self.clampPos(.{ .y = self.nrows() });
        self.cx = end.x;
        self.cy = end.y;
        self.sel = true;
    }

    /// Ctrl-C, Ctrl-X: the selection, or else the cursor's line.
    fn copySelection(self: *Editor, cut: bool) Oom!void {
        if (self.selRange()) |r| {
            const a = r[0];
            const b = r[1];
            self.clip.clear();
            for (a.y..b.y + 1) |y| {
                const chars = self.rows.items[y].chars.items;
                const from = if (y == a.y) a.x else 0;
                const to = if (y == b.y) b.x else chars.len;
                try self.clip.appendSlice(chars[from..to]);
                if (y < b.y) try self.clip.append('\n');
            }
            self.clip_lines = false;
            self.sel = false;
            if (cut) {
                // Row a.y keeps what is before the
                // selection and gets what is after:
                const first = &self.rows.items[a.y].chars;
                const tail = self.rows.items[b.y].chars.items[b.x..];
                self.record(a.y, 1, 1);
                if (a.y == b.y) {
                    first.removeRange(a.x, b.x - a.x);
                } else {
                    try first.reserve(a.x + tail.len);
                    first.items.len = a.x;
                    first.appendSlice(tail) catch unreachable; // reserved
                    self.delRows(a.y + 1, b.y - a.y);
                }
                try self.updateRow(a.y);
                self.dirty += 1;
                self.cx = a.x;
                self.cy = a.y;
            }
            self.setStatus("{s} {d} characters", .{ if (cut) "Cut" else "Copied", self.clip.items.len });
            return;
        }
        if (self.cy >= self.nrows()) return;
        self.clip.clear();
        try self.clip.appendSlice(self.rows.items[self.cy].chars.items);
        self.clip_lines = true;
        self.sel = false;
        if (cut) {
            self.delRows(self.cy, 1);
            self.moveCursor(0); // only puts the cursor within the row
        }
        self.setStatus("{s} the line", .{if (cut) "Cut" else "Copied"});
    }

    /// Ctrl-V: lines copied as lines go in before the cursor's line.
    fn paste(self: *Editor) Oom!void {
        if (self.clip.items.len == 0 and !self.clip_lines) return;
        self.sel = false;
        const text = self.clip.items;
        if (self.clip_lines) {
            const at = @min(self.cy, self.nrows());
            try self.insertLines(at, text);
            self.cy += std.mem.count(u8, text, "\n") + 1;
            return;
        }
        if (self.cy == self.nrows()) try self.insertRow(self.nrows(), "");
        self.record(self.cy, 1, 1);
        const nl = std.mem.indexOfScalar(u8, text, '\n') orelse {
            try self.rows.items[self.cy].chars.insertSlice(self.cx, text);
            try self.updateRow(self.cy);
            self.dirty += 1;
            self.cx += text.len;
            return;
        };
        // Several lines: the cursor's line is split around them:
        const last_nl = std.mem.lastIndexOfScalar(u8, text, '\n').?;
        const row = &self.rows.items[self.cy].chars;
        const tail = try heap.dupe(u8, row.items[self.cx..]);
        defer heap.free(tail);
        row.items.len = self.cx;
        try row.appendSlice(text[0..nl]);
        try self.updateRow(self.cy);
        try self.insertLines(self.cy + 1, text[nl + 1 ..]);
        const lines = std.mem.count(u8, text, "\n");
        try self.rowAppendString(self.cy + lines, tail);
        self.cy += lines;
        self.cx = text.len - last_nl - 1;
    }

    /// Shift with a movement key selects; without Shift it ends the selection.
    fn handleKey(self: *Editor, k: zdos.Key) void {
        const c = translateKey(k) orelse return;
        switch (c) {
            K.arrow_up, K.arrow_down, K.arrow_left, K.arrow_right, K.home, K.end, K.page_up, K.page_down => {
                if (k.mods & zdos.Mod.shift == 0) {
                    self.sel = false;
                } else if (!self.sel) {
                    self.sel_anchor = .{ .x = self.cx, .y = self.cy };
                    self.sel = true;
                }
            },
            else => {},
        }
        self.processKey(c);
    }

    fn finishLine(self: *Editor, line: *Vec(u8), terminated: bool, first: *bool) Oom!void {
        var len = line.items.len;
        if (terminated and first.*) {
            self.crlf = len > 0 and line.items[len - 1] == '\r';
            first.* = false;
        }
        while (len > 0 and (line.items[len - 1] == '\n' or line.items[len - 1] == '\r')) len -= 1;
        try self.insertRow(self.nrows(), line.items[0..len]);
        line.clear();
    }

    fn openFile(self: *Editor, name: []const u8) zdos.Error!void {
        if (self.filename) |f| heap.free(f);
        self.filename = try heap.dupe(u8, name);
        self.selectSyntax();

        const f = zdos.open(name, .read) catch |err| switch (err) {
            error.NotFound => {
                self.is_new_file = true;
                return;
            },
            else => return err,
        };
        defer f.close();

        var chunk: [8192]u8 = undefined;
        var line: Vec(u8) = .{};
        defer line.deinit();
        var first = true;
        while (true) {
            const n = try f.read(&chunk);
            if (n == 0) break;
            var rest: []const u8 = chunk[0..n];
            while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                try line.appendSlice(rest[0..nl]);
                try self.finishLine(&line, true, &first);
                rest = rest[nl + 1 ..];
            }
            try line.appendSlice(rest);
        }
        if (line.items.len > 0) try self.finishLine(&line, false, &first);
        self.dirty = 0;
    }

    fn writeRows(self: *Editor, w: *FileWriter) zdos.Error!usize {
        const eol: []const u8 = if (self.crlf) "\r\n" else "\n";
        for (self.rows.items) |*row| {
            try w.write(row.chars.items);
            try w.write(eol);
        }
        try w.flush();
        try w.f.setSize(w.total);
        return w.total;
    }

    fn save(self: *Editor) Oom!void {
        if (self.filename == null) {
            const name = (try self.prompt("Save as: ", " (ESC to cancel)", null)) orelse {
                self.setStatus("Save aborted", .{});
                return;
            };
            self.filename = name;
            self.selectSyntax();
        }
        const name = self.filename.?;

        const result: zdos.Error!usize = blk: {
            const f = zdos.open(name, write_mode) catch |err| break :blk err;
            var w = FileWriter{ .f = f };
            const written = self.writeRows(&w);
            const closed = f.closeChecked();
            const total = written catch |err| break :blk err;
            closed catch |err| break :blk err;
            break :blk total;
        };
        if (result) |total| {
            self.dirty = 0;
            self.setStatus("{d} bytes written to disk", .{total});
        } else |err| {
            self.setStatus("Can't save! I/O error: {s}", .{zdos.message(err)});
        }
    }

    fn findCallback(self: *Editor, query: []const u8, key: u32) void {
        if (self.find_saved_hl) |saved| {
            if (self.find_saved_line < self.nrows()) {
                const hl = self.rows.items[self.find_saved_line].hl.items;
                const n = @min(hl.len, saved.len);
                @memcpy(hl[0..n], saved[0..n]);
            }
            heap.free(saved);
            self.find_saved_hl = null;
        }

        if (key == '\r' or key == K.escape) {
            self.find_last = -1;
            self.find_dir = 1;
            return;
        } else if (key == K.arrow_right or key == K.arrow_down) {
            self.find_dir = 1;
        } else if (key == K.arrow_left or key == K.arrow_up) {
            self.find_dir = -1;
        } else {
            self.find_last = -1;
            self.find_dir = 1;
        }

        if (self.find_last == -1) self.find_dir = 1;
        if (query.len == 0) return;

        const n: isize = @intCast(self.nrows());
        var current = self.find_last;
        for (0..self.nrows()) |_| {
            current += self.find_dir;
            if (current == -1) {
                current = n - 1;
            } else if (current == n) {
                current = 0;
            }
            const idx: usize = @intCast(current);
            const row = &self.rows.items[idx];
            if (std.mem.indexOf(u8, row.render.items, query)) |pos| {
                self.find_last = current;
                self.cy = idx;
                // pos is a byte of the render; the cursor needs a column:
                self.cx = rowRxToCx(row, widthBefore(row.render.items, pos));
                // scroll() brings the match into view:
                if (heap.dupe(Hl, row.hl.items)) |copy| {
                    self.find_saved_line = idx;
                    self.find_saved_hl = copy;
                    const hl = row.hl.items;
                    if (pos + query.len <= hl.len) @memset(hl[pos..][0..query.len], .match);
                } else |_| {}
                break;
            }
        }
    }

    fn find(self: *Editor) Oom!void {
        const saved_cx = self.cx;
        const saved_cy = self.cy;
        const saved_coloff = self.coloff;
        const saved_rowoff = self.rowoff;

        const query = try self.prompt("Search: ", " (Use ESC/Arrows/Enter)", findCallbackThunk);
        if (query) |q| {
            heap.free(q);
        } else {
            self.cx = saved_cx;
            self.cy = saved_cy;
            self.coloff = saved_coloff;
            self.rowoff = saved_rowoff;
        }
    }

    /// Vertically by as many lines as the cursor left the window, sideways
    /// by `hjump` columns (see jump_scroll).
    fn scroll(self: *Editor) void {
        self.rx = if (self.cy < self.nrows()) rowCxToRx(&self.rows.items[self.cy], self.cx) else 0;
        const hjump = if (jump_scroll) self.cols / 4 else 0;
        self.rowoff = scrollAxis(self.cy, self.rowoff, self.text_rows, 0);
        self.coloff = scrollAxis(self.rx, self.coloff, self.cols, hjump);
    }

    /// Clears the screen when its size changed, and on the first frame.
    fn syncSize(self: *Editor) void {
        const c = termCols();
        const r = termRows();
        if (c == self.cols and r == self.term_rows and self.cells.cap != 0) return;
        if (c < 8 or r < 3) fatal("screen too small");
        self.cells.resize(c * r) catch fatal("out of memory");
        self.shadow.resize(c * r) catch fatal("out of memory");
        @memset(self.shadow.items, blank_cell);
        self.cols = c;
        self.term_rows = r;
        self.text_rows = r - 2;
        self.rowoff = 0; // scroll() finds the right offsets for the new size
        self.coloff = 0;
        self.drawn_rowoff = 0;
        self.drawn_coloff = 0;
        self.cursor_known = false;
        zdos.print("\x1b[0m");
        zdos.clearScreen();
    }

    fn put(self: *Editor, x: usize, y: usize, cp: u21, attr: u8) void {
        if (x < self.cols and y < self.term_rows) self.cells.items[y * self.cols + x] = mkCell(cp, attr);
    }

    /// One cell per character, up to column `limit`.
    fn putText(self: *Editor, x: usize, y: usize, s: []const u8, attr: u8, limit: usize) void {
        var cx = x;
        var i: usize = 0;
        while (i < s.len) {
            if (cx >= limit) break;
            const g = glyphAt(s, i);
            self.put(cx, y, g.cp, attr);
            cx += 1;
            i += g.len;
        }
    }

    fn drawRows(self: *Editor) void {
        const range = self.selRange();
        for (0..self.text_rows) |y| {
            const filerow = y + self.rowoff;
            if (filerow >= self.nrows()) {
                if (self.nrows() == 0 and y == self.text_rows / 3) {
                    var buf: [80]u8 = undefined;
                    const w = std.fmt.bufPrint(&buf, "Kilo editor for ZIGDOS -- version {s}", .{kilo_version}) catch buf[0..];
                    const text = w[0..@min(w.len, self.cols)];
                    const padding = (self.cols - text.len) / 2;
                    if (padding != 0) self.put(0, y, '~', attr_default);
                    self.putText(padding, y, text, attr_default, self.cols);
                } else {
                    self.put(0, y, '~', attr_default);
                }
                continue;
            }
            const row = &self.rows.items[filerow];
            const render = row.render.items;
            const hl = row.hl.items;
            // The selection: black on light gray, and one cell after the end
            // when the line break is selected too:
            var sel_from: usize = 0;
            var sel_to: usize = 0;
            var sel_eol = false;
            if (range) |r| if (filerow >= r[0].y and filerow <= r[1].y) {
                sel_from = if (filerow == r[0].y) rowCxToRx(row, r[0].x) else 0;
                sel_to = if (filerow == r[1].y) rowCxToRx(row, r[1].x) else std.math.maxInt(usize);
                sel_eol = filerow < r[1].y;
            };
            // col is the screen column in the row:
            var col: usize = 0;
            var j: usize = 0;
            while (j < render.len) {
                const g = glyphAt(render, j);
                if (col >= self.coloff) {
                    const x = col - self.coloff;
                    if (x >= self.cols) break;
                    const selected = col >= sel_from and col < sel_to;
                    // Invalid bytes, control characters,
                    // DEL and C1: a reverse symbol:
                    const bad = g.len == 1 and render[j] >= 0x80;
                    if (bad or g.cp < 32 or (g.cp >= 127 and g.cp < 160)) {
                        const sym: u21 = if (!bad and g.cp <= 26) '@' + g.cp else '?';
                        self.put(x, y, sym, attr_default | attr_rev);
                    } else {
                        const h: Hl = if (j < hl.len) hl[j] else .normal;
                        self.put(x, y, g.cp, if (selected) attr_default | attr_rev else hlAttr(h));
                    }
                }
                j += g.len;
                col += 1;
            }
            if (sel_eol and col >= self.coloff) self.put(col - self.coloff, y, ' ', attr_default | attr_rev);
        }
    }

    fn drawStatusBar(self: *Editor) void {
        const y = self.text_rows;
        for (0..self.cols) |x| self.put(x, y, ' ', attr_default | attr_rev);

        const name = self.filename orelse "[No Name]";
        var lbuf: [160]u8 = undefined;
        const left = std.fmt.bufPrint(&lbuf, " {s} | {s} - {d} lines {s}", .{
            if (self.mode == .normal) "NORMAL" else "INSERT",
            cutChars(name, 20),
            self.nrows(),
            if (self.dirty != 0) "(modified)" else "",
        }) catch lbuf[0..];
        var rbuf: [64]u8 = undefined;
        const right = std.fmt.bufPrint(&rbuf, "{s} | {d}/{d} ", .{
            if (self.syntax) |s| s.filetype else "no ft",
            self.cy + 1,
            self.nrows(),
        }) catch rbuf[0..0];

        self.putText(0, y, left, attr_default | attr_rev, self.cols);
        if (left.len + right.len <= self.cols) {
            self.putText(self.cols - right.len, y, right, attr_default | attr_rev, self.cols);
        }
    }

    fn drawMessageBar(self: *Editor) void {
        if (self.status_len == 0) return;
        if (zdos.millis() -% self.status_time >= status_ttl_ms) return;
        // The last cell is never written (UEFI would scroll):
        self.putText(0, self.term_rows - 1, self.status[0..self.status_len], attr_default, self.cols - 1);
    }

    fn differs(self: *const Editor, y: usize, x: usize) bool {
        if (y == self.term_rows - 1 and x == self.cols - 1) return false;
        const i = y * self.cols + x;
        return self.cells.items[i] != self.shadow.items[i];
    }

    fn flush(self: *Editor) void {
        const cols = self.cols;
        const cells = self.cells.items;
        const shadow = self.shadow.items;

        self.out.clear();
        var em = Emitter{ .out = &self.out };
        if (self.cursor_known) {
            em.tx = self.term_cx;
            em.ty = self.term_cy;
        }

        // A few lines down: let the screen scroll, as MORE does, so only the
        // new lines and the bars are drawn:
        const down = self.rowoff -% self.drawn_rowoff;
        if (self.rowoff > self.drawn_rowoff and down < self.text_rows / 2 and self.coloff == self.drawn_coloff) {
            self.scrollScreen(&em, down);
        }
        self.drawn_rowoff = self.rowoff;
        self.drawn_coloff = self.coloff;

        for (0..self.term_rows) |y| {
            const base = y * cols;
            // First column of the blank tail:
            var blank_from = cols;
            while (blank_from > 0 and cells[base + blank_from - 1] == blank_cell) blank_from -= 1;

            var x: usize = 0;
            while (x < cols) {
                if (!self.differs(y, x)) {
                    x += 1;
                    continue;
                }
                // Extend over further changes, bridging short gaps:
                var end = x + 1;
                var s = x + 1;
                while (s < cols) : (s += 1) {
                    if (self.differs(y, s)) {
                        end = s + 1;
                    } else if (s + 1 - end >= merge_gap) {
                        break;
                    }
                }

                const erase = end > blank_from and cols - @max(x, blank_from) > erase_min;
                const text_end = if (erase) @min(end, blank_from) else end;

                if (x < text_end) {
                    em.moveTo(x, y);
                    for (x..text_end) |i| {
                        const cell = cells[base + i];
                        em.setAttr(@intCast(cell >> 24));
                        em.char(@truncate(cell));
                    }
                    if (text_end == cols) em.tx = std.math.maxInt(usize); // wrapped
                }
                if (erase) {
                    if (x >= text_end) em.moveTo(x, y);
                    em.setAttr(attr_default);
                    em.raw("\x1b[K");
                }
                const done = if (erase) cols else end;
                @memcpy(shadow[base + x ..][0 .. done - x], cells[base + x ..][0 .. done - x]);
                x = done;
            }
        }
        em.setAttr(attr_default);
        const painted = self.out.items.len != 0;

        var cur_x: usize = undefined;
        var cur_y: usize = undefined;
        if (self.prompt_col) |pc| {
            cur_x = @min(pc, self.cols - 2);
            cur_y = self.term_rows - 1;
        } else {
            cur_x = self.rx - self.coloff;
            cur_y = self.cy - self.rowoff;
        }
        em.moveTo(cur_x, cur_y);

        if (em.failed) {
            // Out of memory: drop the frame and repaint everything next time:
            @memset(shadow, stale_cell);
            self.cursor_known = false;
            return;
        }
        if (self.out.items.len == 0) return;

        if (painted) zdos.showCursor(false);
        zdos.print(self.out.items);
        if (painted) zdos.showCursor(true);
        self.term_cx = cur_x;
        self.term_cy = cur_y;
        self.cursor_known = true;
    }

    /// The shadow moves with it, so the diff paints only the new rows and
    /// the two bars.
    fn scrollScreen(self: *Editor, em: *Emitter, lines: usize) void {
        em.setAttr(attr_default); // new rows in the normal colors
        em.moveTo(0, self.term_rows - 1);
        for (0..lines) |_| em.raw("\n");
        em.tx = 0;
        const cols = self.cols;
        const shadow = self.shadow.items;
        const kept = (self.term_rows - lines) * cols;
        std.mem.copyForwards(Cell, shadow[0..kept], shadow[lines * cols ..]);
        @memset(shadow[kept..], blank_cell);
    }

    fn refresh(self: *Editor) void {
        self.syncSize();
        self.scroll();
        @memset(self.cells.items, blank_cell);
        self.drawRows();
        self.drawStatusBar();
        self.drawMessageBar();
        self.flush();
    }

    fn charAt(self: *const Editor, y: usize, x: usize) u8 {
        if (y >= self.nrows()) return 0;
        const chars = self.rows.items[y].chars.items;
        return if (x < chars.len) chars[x] else 0;
    }

    /// moveCursor() that tells whether the cursor moved.
    fn step(self: *Editor, key: u32) bool {
        const ox = self.cx;
        const oy = self.cy;
        self.moveCursor(key);
        return ox != self.cx or oy != self.cy;
    }

    fn specialMovement(self: *Editor, key: u32) void {
        switch (key) {
            'w' => {
                while (!isStopChar(self.charAt(self.cy, self.cx))) {
                    if (!self.step(K.arrow_right)) break;
                    while (isStopChar(self.charAt(self.cy, self.cx + 1))) {
                        if (!self.step(K.arrow_right)) break;
                    }
                }
                _ = self.step(K.arrow_right);
            },
            'b' => {
                while (!isStopChar(self.charAt(self.cy, self.cx))) {
                    if (!self.step(K.arrow_left)) break;
                    while (isStopChar(if (self.cx > 0) self.charAt(self.cy, self.cx - 1) else 0)) {
                        if (!self.step(K.arrow_left)) break;
                    }
                }
                _ = self.step(K.arrow_left);
            },
            '}' => {
                self.cx = 0;
                self.moveCursor(K.arrow_down);
                while (self.cy < self.nrows() and self.rows.items[self.cy].chars.items.len != 0) {
                    if (!self.step(K.arrow_down)) break;
                }
            },
            '{' => {
                self.cx = 0;
                self.moveCursor(K.arrow_up);
                while (self.cy < self.nrows() and self.rows.items[self.cy].chars.items.len != 0) {
                    if (!self.step(K.arrow_up)) break;
                }
            },
            else => {},
        }
    }

    fn doInsert(self: *Editor, key: u32) Oom!void {
        switch (key) {
            'i' => self.mode = .insert,
            'I' => {
                self.cx = 0;
                self.mode = .insert;
            },
            'a' => {
                self.moveCursor(K.arrow_right);
                self.mode = .insert;
            },
            'A' => {
                if (self.cy < self.nrows()) self.cx = self.rows.items[self.cy].chars.items.len;
                self.mode = .insert;
            },
            'o' => {
                if (self.cy < self.nrows()) self.cx = self.rows.items[self.cy].chars.items.len;
                try self.insertNewline();
                self.mode = .insert;
            },
            'O' => {
                self.cx = 0;
                try self.insertNewline();
                self.moveCursor(K.arrow_up);
                self.mode = .insert;
            },
            else => {},
        }
    }

    /// The callback sees every key. Null if cancelled; caller frees.
    fn prompt(self: *Editor, prefix: []const u8, suffix: []const u8, callback: ?PromptCallback) Oom!?[]u8 {
        var buf: Vec(u8) = .{};
        defer buf.deinit();
        defer self.prompt_col = null;

        while (true) {
            self.setStatus("{s}{s}{s}", .{ prefix, buf.items, suffix });
            self.prompt_col = prefix.len + widthBefore(buf.items, buf.items.len);
            self.refresh();

            const c = nextKey();
            if (c == K.del or c == ck.h or c == K.backspace) {
                // A whole character goes:
                if (buf.items.len != 0) buf.items.len = prevGlyph(buf.items, buf.items.len);
            } else if (c == K.escape) {
                self.setStatus("", .{});
                if (callback) |cb| cb(self, buf.items, c);
                return null;
            } else if (c == '\r') {
                if (buf.items.len != 0) {
                    self.setStatus("", .{});
                    if (callback) |cb| cb(self, buf.items, c);
                    return try heap.dupe(u8, buf.items);
                }
            } else if (isTextKey(c)) {
                var enc: [4]u8 = undefined;
                try buf.appendSlice(encodeCp(@intCast(c), &enc));
            }

            if (callback) |cb| cb(self, buf.items, c);
        }
    }

    /// None past the last row.
    fn rowBytes(self: *const Editor, y: usize) []const u8 {
        return if (y < self.nrows()) self.rows.items[y].chars.items else &.{};
    }

    fn moveCursor(self: *Editor, key: u32) void {
        const n = self.nrows();
        switch (key) {
            K.arrow_left => {
                if (self.cx != 0) {
                    self.cx = prevGlyph(self.rowBytes(self.cy), self.cx);
                } else if (self.cy > 0) {
                    self.cy -= 1;
                    self.cx = self.rows.items[self.cy].chars.items.len;
                }
            },
            K.arrow_right => {
                if (self.cy < n) {
                    const bytes = self.rows.items[self.cy].chars.items;
                    if (self.cx < bytes.len) {
                        self.cx += glyphAt(bytes, self.cx).len;
                    } else if (self.cx == bytes.len) {
                        self.cy += 1;
                        self.cx = 0;
                    }
                }
            },
            K.arrow_up => {
                if (self.cy != 0) self.cy -= 1;
            },
            K.arrow_down => {
                if (self.cy < n) self.cy += 1;
            },
            else => {},
        }
        // At most the end of the row; a byte inside a character (after a move
        // up or down) goes back to its start:
        self.cx = snapGlyph(self.rowBytes(self.cy), self.cx);
    }

    fn pageMove(self: *Editor, c: u32) void {
        if (c == K.page_up) {
            self.cy = self.rowoff;
        } else {
            self.cy = @min(self.rowoff + self.text_rows - 1, self.nrows());
        }
        var times = self.text_rows;
        while (times > 0) : (times -= 1) {
            self.moveCursor(if (c == K.page_up) K.arrow_up else K.arrow_down);
        }
    }

    /// False if Ctrl-Q only produced a warning.
    fn tryQuit(self: *Editor) bool {
        if (self.dirty != 0 and self.quit_times > 0) {
            self.setStatus("WARNING!!! File has unsaved changes. Press Ctrl-Q {d} more times to quit.", .{self.quit_times});
            self.quit_times -= 1;
            return false;
        }
        self.quit = true;
        return true;
    }

    fn processInsertKey(self: *Editor, c: u32) Oom!void {
        switch (c) {
            '\r' => try self.insertNewline(),
            ck.q => if (!self.tryQuit()) return,
            ck.s => try self.save(),
            K.home => self.cx = 0,
            K.end => {
                if (self.cy < self.nrows()) self.cx = self.rows.items[self.cy].chars.items.len;
            },
            ck.f => try self.find(),
            K.backspace, ck.h, K.del => {
                if (c == K.del) self.moveCursor(K.arrow_right);
                try self.delChar();
            },
            K.page_up, K.page_down => self.pageMove(c),
            K.arrow_up, K.arrow_down, K.arrow_left, K.arrow_right => self.moveCursor(c),
            ck.l, K.escape => self.mode = .normal,
            else => {
                if (c == '\t' or isTextKey(c)) try self.insertChar(c);
            },
        }
        self.quit_times = quit_times_default;
    }

    fn processNormalKey(self: *Editor, c: u32) Oom!void {
        switch (c) {
            ck.q => if (!self.tryQuit()) return,
            ck.s => try self.save(),
            K.home => self.cx = 0,
            K.end => {
                if (self.cy < self.nrows()) self.cx = self.rows.items[self.cy].chars.items.len;
            },
            ck.f => try self.find(),
            K.page_up, K.page_down => self.pageMove(c),
            K.arrow_up, K.arrow_down, K.arrow_left, K.arrow_right => self.moveCursor(c),
            'i', 'I', 'a', 'A', 'o', 'O' => try self.doInsert(c),
            'w', 'b', '}', '{' => self.specialMovement(c),
            'p' => self.setStatus("char at {d} = {d}", .{ self.rx, self.charAt(self.cy, self.cx) }),
            else => self.moveCursor(normalMovement(c)),
        }
        self.quit_times = quit_times_default;
    }

    fn processKey(self: *Editor, c: u32) void {
        const before = self.dirty;
        self.key_cx = self.cx;
        self.key_cy = self.cy;
        self.step_open = false;
        const steps = self.undo.items.len;
        const result = switch (c) {
            ck.z => self.undoStep(),
            ck.a => self.selectAll(),
            ck.c => self.copySelection(false),
            ck.x => self.copySelection(true),
            ck.v, ck.p => self.paste(),
            else => blk: {
                if (c == K.escape) self.sel = false;
                break :blk if (self.mode == .normal) self.processNormalKey(c) else self.processInsertKey(c);
            },
        };
        result catch {
            self.setStatus("Out of memory!", .{});
            self.clearUndo(); // the change may be half done
        };
        // Changes end a selection (it would point elsewhere):
        if (self.dirty > before) self.sel = false;
        self.groupTyping(c, steps);
    }

    /// Typing on one row is undone a word at a time.
    fn groupTyping(self: *Editor, c: u32, steps_before: usize) void {
        const n = self.undo.items.len;
        if (n != steps_before + 1) {
            self.typing_row = null;
            return;
        }
        const us = &self.undo.items[n - 1];
        const ch = us.changes.items;
        const typing = self.mode == .insert and isTextKey(c) and
            ch.len == 1 and ch[0].old_n == 1 and ch[0].new_n == 1;
        if (!typing) {
            self.typing_row = null;
            return;
        }
        const row = ch[0].at;
        if (self.typing_row == row and c != ' ') {
            us.deinit();
            self.undo.items.len -= 1;
        }
        self.typing_row = row;
    }
};

fn findCallbackThunk(e: *Editor, query: []const u8, key: u32) void {
    e.findCallback(query, key);
}

const FileWriter = struct {
    f: zdos.File,
    buf: [8192]u8 = undefined,
    n: usize = 0,
    total: usize = 0,

    fn write(self: *FileWriter, data: []const u8) zdos.Error!void {
        var rest = data;
        while (rest.len > 0) {
            if (self.n == self.buf.len) try self.flush();
            const k = @min(self.buf.len - self.n, rest.len);
            @memcpy(self.buf[self.n..][0..k], rest[0..k]);
            self.n += k;
            rest = rest[k..];
        }
    }

    fn flush(self: *FileWriter) zdos.Error!void {
        if (self.n == 0) return;
        try self.f.writeAll(self.buf[0..self.n]);
        self.total += self.n;
        self.n = 0;
    }
};

/// Optionally in double quotes.
fn parseFileName(args: []const u8) ?[]const u8 {
    const a = std.mem.trim(u8, args, " \t\r\n");
    if (a.len == 0) return null;
    if (a[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, a, 1, '"') orelse a.len;
        return if (end > 1) a[1..end] else null;
    }
    const end = std.mem.indexOfAny(u8, a, " \t") orelse a.len;
    return a[0..end];
}

pub fn main(args: []const u8) u8 {
    if (zdos.outputRedirected()) {
        zdos.print("kilo: output is redirected, the editor needs the screen\n");
        return 1;
    }

    var ed: Editor = .{};

    if (parseFileName(args)) |name| {
        ed.openFile(name) catch |err| {
            zdos.printf("kilo: can't open {s}: {s}\n", .{ name, zdos.message(err) });
            return 1;
        };
    }
    ed.recording = true; // changes from here on can be undone

    // The alternate screen: the console's own comes back afterwards, and
    // its scroll keys and wheel are the editor's meanwhile:
    zdos.print("\x1b[?1049h");
    zdos.setCtrlC(true); // Ctrl-C is an ordinary key
    ed.setStatus("{s}Ctrl- S save, Q quit, F find, C copy, X cut, V paste, Z undo", .{
        if (ed.is_new_file) "NEW FILE: " else "HELP: ",
    });

    while (!ed.quit) {
        ed.refresh();
        ed.handleKey(zdos.readKey());
        // Keys already waiting (a held arrow key) before drawing again:
        while (!ed.quit) ed.handleKey(zdos.pollKey() orelse break);
    }

    zdos.print("\x1b[0m");
    zdos.clearScreen();
    zdos.print("\x1b[H\x1b[?1049l");
    zdos.showCursor(true);
    zdos.setCtrlC(false);
    return 0;
}
