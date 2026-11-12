// ash's built-ins: the shell's own here, the tools in their own modules
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const sys = @import("../zdos/system.zig");
const shell_mod = @import("shell.zig");
const expand = @import("expand.zig");
const format = @import("format.zig");
const names = @import("names.zig");
const parser = @import("parser.zig");
const command_lookup = @import("command_lookup.zig");

const awk = @import("awk.zig");
const basename = @import("basename.zig");
const cat = @import("cat.zig");
const cp = @import("cp.zig");
const cut = @import("cut.zig");
const date = @import("date.zig");
const df = @import("df.zig");
const diff = @import("diff.zig");
const dirname = @import("dirname.zig");
const find = @import("find.zig");
const grep = @import("grep.zig");
const head = @import("head.zig");
const ls = @import("ls.zig");
const mkdir = @import("mkdir.zig");
const mv = @import("mv.zig");
const patch = @import("patch.zig");
const rm = @import("rm.zig");
const rmdir = @import("rmdir.zig");
const sleep = @import("sleep.zig");
const sed = @import("sed.zig");
const sort = @import("sort.zig");
const tail = @import("tail.zig");
const touch = @import("touch.zig");
const chmod = @import("chmod.zig");
const uniq = @import("uniq.zig");
const wc = @import("wc.zig");
const where = @import("where.zig");
const which = @import("which.zig");
const xargs = @import("xargs.zig");
const xxd = @import("xxd.zig");

const Allocator = std.mem.Allocator;
const Shell = shell_mod.Shell;
const gpa = zdos.allocator;

// Their variable assignments (NAME=value cmd) stay afterwards:
const special = [_][]const u8{ ".", ":", "break", "continue", "eval", "exec", "exit", "export", "readonly", "return", "set", "shift", "source", "trap", "unset", "local" };

pub fn isSpecial(name: []const u8) bool {
    for (special) |s| if (std.mem.eql(u8, s, name)) return true;
    return false;
}

const eql = std.mem.eql;

// Null if name isn't one.
pub fn run(sh: *Shell, a: Allocator, argv: []const []const u8) ?u8 {
    const name = argv[0];
    const args = argv[1..];
    if (!names.isBuiltin(name)) return null;
    if (eql(u8, name, ":") or eql(u8, name, "true")) return 0;
    if (eql(u8, name, "false")) return 1;
    if (eql(u8, name, "echo")) return echo(a, args);
    if (eql(u8, name, "printf")) return printf(a, args);
    if (eql(u8, name, "test")) return testCommand(args);
    if (eql(u8, name, "[")) {
        if (args.len == 0 or !eql(u8, args[args.len - 1], "]")) {
            errout.print("[: missing ]\n");
            return 2;
        }
        return testCommand(args[0 .. args.len - 1]);
    }
    if (eql(u8, name, "cd")) return cd(sh, a, args);
    if (eql(u8, name, "pwd")) {
        var buf: [1100]u8 = undefined;
        zdos.printf("{s}\n", .{shell_mod.posixPath(&buf)});
        return 0;
    }
    if (eql(u8, name, "break") or eql(u8, name, "continue")) return loopControl(sh, name, args);
    if (eql(u8, name, "return")) return returnCommand(sh, args);
    if (eql(u8, name, "exit")) {
        var status = sh.status;
        if (args.len > 0) status = parseStatus(args[0]) orelse {
            errout.print("ash: exit: numeric argument required\n");
            return 2;
        };
        sh.flow = .exit_;
        sh.exit_status = status;
        return status;
    }
    if (eql(u8, name, "export")) return exportCommand(sh, args, true);
    if (eql(u8, name, "readonly")) return exportCommand(sh, args, false);
    if (eql(u8, name, "unset")) return unset(sh, args);
    if (eql(u8, name, "local")) return local(sh, args);
    if (eql(u8, name, "set")) return set(sh, args);
    if (eql(u8, name, "shift")) return shift(sh, args);
    if (eql(u8, name, "eval")) {
        const text = std.mem.join(a, " ", args) catch return shell_mod.outOfMemory();
        return sh.runText(text, "eval");
    }
    if (eql(u8, name, ".") or eql(u8, name, "source")) return source(sh, args);
    if (eql(u8, name, "exec")) {
        if (args.len == 0) return 0;
        const status = sh.runBuiltinOrProgram(a, args);
        sh.flow = .exit_;
        sh.exit_status = status;
        return status;
    }
    if (eql(u8, name, "trap")) return trap(sh, args);
    if (eql(u8, name, "read")) return read(sh, a, args);
    if (eql(u8, name, "command")) return command(sh, a, args);
    if (eql(u8, name, "type")) return typeCommand(sh, a, args);
    if (eql(u8, name, "wait")) return sh.waitTasks(args);
    if (eql(u8, name, "help")) return help();
    if (eql(u8, name, "clear")) {
        zdos.clearScreen();
        return 0;
    }
    if (eql(u8, name, "env")) return env(sh, a, args);
    // The tools:
    if (eql(u8, name, "awk")) return awk.run(sh, args);
    if (eql(u8, name, "basename")) return basename.run(args);
    if (eql(u8, name, "cat")) return cat.run(args);
    if (eql(u8, name, "cp") or eql(u8, name, "copy")) return cp.run(args);
    if (eql(u8, name, "cut")) return cut.run(args);
    if (eql(u8, name, "date")) return date.run(args);
    if (eql(u8, name, "df")) return df.run(args);
    if (eql(u8, name, "diff")) return diff.run(&sh.interrupted, args);
    if (eql(u8, name, "dirname")) return dirname.run(args);
    if (eql(u8, name, "find")) return find.run(sh, args);
    if (eql(u8, name, "grep")) return grep.run(args);
    if (eql(u8, name, "head")) return head.run(args);
    if (eql(u8, name, "ls") or eql(u8, name, "list") or eql(u8, name, "dir")) return ls.run(args);
    if (eql(u8, name, "mkdir")) return mkdir.run(args);
    if (eql(u8, name, "mv") or eql(u8, name, "move")) return mv.run(args);
    if (eql(u8, name, "patch")) return patch.run(&sh.interrupted, args);
    if (eql(u8, name, "rm") or eql(u8, name, "remove") or eql(u8, name, "del")) return rm.run(args);
    if (eql(u8, name, "rmdir")) return rmdir.run(args);
    if (eql(u8, name, "sed")) return sed.run(&sh.interrupted, args);
    if (eql(u8, name, "sleep")) return sleep.run(args);
    if (eql(u8, name, "sort")) return sort.run(args);
    if (eql(u8, name, "tail")) return tail.run(args);
    if (eql(u8, name, "touch")) return touch.run(args);
    if (eql(u8, name, "chmod")) return chmod.runChmod(args);
    if (eql(u8, name, "chown")) return chmod.runChown(args);
    if (eql(u8, name, "uniq")) return uniq.run(args);
    if (eql(u8, name, "wc")) return wc.run(args);
    if (eql(u8, name, "where")) return where.run(args);
    if (eql(u8, name, "which")) return which.run(args);
    if (eql(u8, name, "xargs")) return xargs.run(sh, args);
    if (eql(u8, name, "xxd")) return xxd.run(args);
    return null;
}

fn parseStatus(text: []const u8) ?u8 {
    const value = std.fmt.parseInt(i32, text, 10) catch return null;
    return @truncate(@as(u32, @bitCast(value)));
}

fn echo(a: Allocator, args: []const []const u8) u8 {
    var newline = true;
    var escapes = false;
    var first: usize = 0;
    // -n -e -E, also combined (-ne); anything else is text:
    while (first < args.len) : (first += 1) {
        const arg = args[first];
        if (arg.len < 2 or arg[0] != '-' or std.mem.indexOfNone(u8, arg[1..], "neE") != null) break;
        for (arg[1..]) |c| switch (c) {
            'n' => newline = false,
            'e' => escapes = true,
            else => escapes = false,
        };
    }
    var out: std.ArrayListUnmanaged(u8) = .{};
    for (args[first..], 0..) |arg, i| {
        if (i > 0) out.append(a, ' ') catch return shell_mod.outOfMemory();
        if (escapes) {
            if (unescape(a, &out, arg, false) catch return shell_mod.outOfMemory()) {
                zdos.print(out.items);
                return 0;
            }
        } else out.appendSlice(a, arg) catch return shell_mod.outOfMemory();
    }
    if (newline) out.append(a, '\n') catch return shell_mod.outOfMemory();
    zdos.print(out.items);
    return 0;
}

// Of echo -e, printf formats and %b; true at \c (stop).
fn unescape(a: Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8, printf_octal: bool) Allocator.Error!bool {
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
            'e' => try out.append(a, 0x1b),
            'f' => try out.append(a, 0x0c),
            'v' => try out.append(a, 0x0b),
            '\\' => try out.append(a, '\\'),
            'c' => return true,
            'x' => {
                var v: u8 = 0;
                var n: usize = 0;
                while (n < 2 and i + 1 < s.len and std.ascii.isHex(s[i + 1])) : (n += 1) {
                    i += 1;
                    v = v * 16 + (std.fmt.charToDigit(s[i], 16) catch 0);
                }
                if (n == 0) try out.appendSlice(a, "\\x") else try out.append(a, v);
            },
            '0'...'7' => {
                // echo: \0nnn; printf: \nnn:
                if (c != '0' and !printf_octal) {
                    try out.append(a, '\\');
                    try out.append(a, c);
                    continue;
                }
                var v: u32 = if (c == '0' and !printf_octal) 0 else c - '0';
                var n: usize = 0;
                while (n < (if (c == '0' and !printf_octal) @as(usize, 3) else 2) and i + 1 < s.len and s[i + 1] >= '0' and s[i + 1] <= '7') : (n += 1) {
                    i += 1;
                    v = v * 8 + (s[i] - '0');
                }
                try out.append(a, @truncate(v));
            },
            else => {
                try out.append(a, '\\');
                try out.append(a, c);
            },
        }
    }
    return false;
}

fn printf(a: Allocator, args: []const []const u8) u8 {
    if (args.len == 0) {
        errout.print("usage: printf FORMAT [ARGUMENT...]\n");
        return 2;
    }
    const fmt = args[0];
    var rest = args[1..];
    var out: std.ArrayListUnmanaged(u8) = .{};
    var status: u8 = 0;
    // The format is used again while arguments are left:
    while (true) {
        const before = rest.len;
        var i: usize = 0;
        while (i < fmt.len) {
            const c = fmt[i];
            if (c == '\\') {
                const end = escapeEnd(fmt, i);
                if (unescape(a, &out, fmt[i..end], true) catch return shell_mod.outOfMemory()) {
                    zdos.print(out.items);
                    return status;
                }
                i = end;
                continue;
            }
            if (c != '%') {
                out.append(a, c) catch return shell_mod.outOfMemory();
                i += 1;
                continue;
            }
            if (i + 1 < fmt.len and fmt[i + 1] == 'b') {
                const arg = nextArg(&rest);
                if (unescape(a, &out, arg, false) catch return shell_mod.outOfMemory()) {
                    zdos.print(out.items);
                    return status;
                }
                i += 2;
                continue;
            }
            var spec = format.parseSpec(fmt, i) orelse {
                errout.printf("printf: bad format: {s}\n", .{fmt[i..]});
                return 1;
            };
            i += spec.len;
            if (spec.width_star) {
                const w = number(nextArg(&rest), &status);
                spec.width = @intFromFloat(@min(@abs(w), 4096));
                if (w < 0) spec.minus = true;
            }
            if (spec.precision_star) spec.precision = @intFromFloat(@min(@max(number(nextArg(&rest), &status), 0), 4096));
            const result = switch (spec.conv) {
                '%' => out.append(a, '%'),
                's' => format.string(a, &out, spec, nextArg(&rest)),
                'c' => blk: {
                    const arg = nextArg(&rest);
                    break :blk format.char(a, &out, spec, if (arg.len > 0) arg[0..1] else "");
                },
                'd', 'i', 'o', 'u', 'x', 'X' => format.integer(a, &out, spec, number(nextArg(&rest), &status)),
                else => format.float(a, &out, spec, number(nextArg(&rest), &status)),
            };
            result catch return shell_mod.outOfMemory();
        }
        if (rest.len == 0 or rest.len == before) break;
    }
    zdos.print(out.items);
    return status;
}

fn escapeEnd(fmt: []const u8, at: usize) usize {
    if (at + 1 >= fmt.len) return fmt.len;
    var end = at + 2;
    const c = fmt[at + 1];
    if (c >= '0' and c <= '7') {
        while (end < fmt.len and end < at + 4 and fmt[end] >= '0' and fmt[end] <= '7') end += 1;
    } else if (c == 'x') {
        while (end < fmt.len and end < at + 4 and std.ascii.isHex(fmt[end])) end += 1;
    }
    return end;
}

fn nextArg(rest: *[]const []const u8) []const u8 {
    if (rest.len == 0) return "";
    const arg = rest.*[0];
    rest.* = rest.*[1..];
    return arg;
}

// 42, -1.5, 0x1F, 017, 'A (the character's code)
fn number(text: []const u8, status: *u8) f64 {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return 0;
    if (t[0] == '\'' or t[0] == '"') return if (t.len > 1) @floatFromInt(t[1]) else 0;
    if (expand.parseNumber(t)) |v| return @floatFromInt(v);
    if (std.fmt.parseFloat(f64, t)) |v| return v else |_| {}
    errout.printf("printf: {s}: invalid number\n", .{text});
    status.* = 1;
    return 0;
}

pub fn testCommand(args: []const []const u8) u8 {
    if (args.len == 0) return 1;
    var t: Test = .{ .args = args };
    const result = t.orExpr() catch return 2;
    if (t.i != args.len) {
        errout.printf("test: {s}: unexpected argument\n", .{args[t.i]});
        return 2;
    }
    return @intFromBool(!result);
}

const Test = struct {
    args: []const []const u8,
    i: usize = 0,

    fn peek(self: *Test, offset: usize) ?[]const u8 {
        return if (self.i + offset < self.args.len) self.args[self.i + offset] else null;
    }

    fn orExpr(self: *Test) error{Bad}!bool {
        var v = try self.andExpr();
        while (self.peek(0)) |w| {
            if (!eql(u8, w, "-o")) break;
            self.i += 1;
            v = (try self.andExpr()) or v;
        }
        return v;
    }

    fn andExpr(self: *Test) error{Bad}!bool {
        var v = try self.notExpr();
        while (self.peek(0)) |w| {
            if (!eql(u8, w, "-a")) break;
            self.i += 1;
            v = (try self.notExpr()) and v;
        }
        return v;
    }

    fn notExpr(self: *Test) error{Bad}!bool {
        const w = self.peek(0) orelse return self.bad("argument expected");
        // "!" alone or as the left side of a comparison is a string:
        if (eql(u8, w, "!") and !(self.peek(1) != null and isBinary(self.peek(1).?) and self.peek(2) != null)) {
            self.i += 1;
            return !(try self.notExpr());
        }
        return self.primary();
    }

    fn primary(self: *Test) error{Bad}!bool {
        const w = self.peek(0) orelse return self.bad("argument expected");
        if (self.peek(1)) |op| if (isBinary(op) and self.peek(2) != null) {
            const rhs = self.peek(2).?;
            self.i += 3;
            return binary(w, op, rhs);
        };
        if (eql(u8, w, "(") and self.peek(1) != null) {
            self.i += 1;
            const v = try self.orExpr();
            const close = self.peek(0) orelse return self.bad("missing )");
            if (!eql(u8, close, ")")) return self.bad("missing )");
            self.i += 1;
            return v;
        }
        if (w.len == 2 and w[0] == '-' and self.peek(1) != null and std.mem.indexOfScalar(u8, "nzefdsrwxhLbcpSt", w[1]) != null) {
            const operand = self.peek(1).?;
            self.i += 2;
            return unary(w[1], operand);
        }
        self.i += 1;
        return w.len > 0;
    }

    fn bad(self: *Test, message: []const u8) error{Bad} {
        _ = self;
        errout.printf("test: {s}\n", .{message});
        return error.Bad;
    }

    fn isBinary(op: []const u8) bool {
        const ops = [_][]const u8{ "=", "==", "!=", "<", ">", "-eq", "-ne", "-lt", "-le", "-gt", "-ge", "-nt", "-ot" };
        for (ops) |o| if (eql(u8, o, op)) return true;
        return false;
    }

    fn unary(op: u8, s: []const u8) error{Bad}!bool {
        switch (op) {
            'n' => return s.len > 0,
            'z' => return s.len == 0,
            'h', 'L', 'b', 'c', 'p', 'S', 't' => return false,
            else => {},
        }
        const entry = zdos.stat(s) catch return false;
        return switch (op) {
            'f' => !entry.is_dir,
            'd' => entry.is_dir,
            's' => entry.size > 0,
            'w' => entry.attrs & zdos.Attr.read_only == 0,
            else => true, // -e -r -x
        };
    }

    fn binary(lhs: []const u8, op: []const u8, rhs: []const u8) error{Bad}!bool {
        if (eql(u8, op, "=") or eql(u8, op, "==")) return eql(u8, lhs, rhs);
        if (eql(u8, op, "!=")) return !eql(u8, lhs, rhs);
        if (eql(u8, op, "<")) return std.mem.lessThan(u8, lhs, rhs);
        if (eql(u8, op, ">")) return std.mem.lessThan(u8, rhs, lhs);
        if (eql(u8, op, "-nt") or eql(u8, op, "-ot")) {
            const x = zdos.stat(lhs) catch return false;
            const y = zdos.stat(rhs) catch return false;
            const tx = timeKey(x.modified);
            const ty = timeKey(y.modified);
            return if (op[1] == 'n') tx > ty else tx < ty;
        }
        const x = integer(lhs) orelse return error.Bad;
        const y = integer(rhs) orelse return error.Bad;
        if (eql(u8, op, "-eq")) return x == y;
        if (eql(u8, op, "-ne")) return x != y;
        if (eql(u8, op, "-lt")) return x < y;
        if (eql(u8, op, "-le")) return x <= y;
        if (eql(u8, op, "-gt")) return x > y;
        return x >= y;
    }

    fn integer(s: []const u8) ?i64 {
        const t = std.mem.trim(u8, s, " \t");
        return std.fmt.parseInt(i64, t, 10) catch {
            errout.printf("test: {s}: integer expected\n", .{s});
            return null;
        };
    }

    fn timeKey(t: zdos.Time) u64 {
        return ((((@as(u64, t.year) * 13 + t.month) * 32 + t.day) * 24 + t.hour) * 60 + t.minute) * 60 + t.second;
    }
};

fn cd(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var target: []const u8 = undefined;
    var show = false;
    if (args.len == 0) {
        target = sh.getVar("HOME") orelse {
            errout.print("ash: cd: HOME not set\n");
            return 1;
        };
    } else if (eql(u8, args[0], "-")) {
        target = sh.getVar("OLDPWD") orelse {
            errout.print("ash: cd: OLDPWD not set\n");
            return 1;
        };
        show = true;
    } else target = args[0];
    var buf: [1100]u8 = undefined;
    const old = a.dupe(u8, shell_mod.posixPath(&buf)) catch return shell_mod.outOfMemory();
    zdos.setCwd(target) catch |err| {
        errout.printf("ash: cd: {s}: {s}\n", .{ target, zdos.message(err) });
        return 1;
    };
    const now = shell_mod.posixPath(&buf);
    sh.setVar("OLDPWD", old) catch {};
    sh.setVar("PWD", now) catch {};
    if (show) zdos.printf("{s}\n", .{now});
    return 0;
}

fn exportCommand(sh: *Shell, args: []const []const u8, is_export: bool) u8 {
    var list = args.len == 0;
    for (args) |arg| {
        if (eql(u8, arg, "-p")) {
            list = true;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = arg[0 .. eq orelse arg.len];
        if (!parser.isName(name)) {
            errout.printf("ash: export: {s}: bad variable name\n", .{name});
            return 1;
        }
        if (eq) |e| sh.setVar(name, arg[e + 1 ..]) catch return shell_mod.outOfMemory();
        if (is_export) sh.exportVar(name) catch return shell_mod.outOfMemory();
    }
    if (list and is_export) listVars(sh, true);
    return 0;
}

// Sorted by name, as NAME='value'.
fn listVars(sh: *Shell, exported_only: bool) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var keys: std.ArrayListUnmanaged([]const u8) = .{};
    var it = sh.vars.iterator();
    while (it.next()) |e| {
        if (exported_only and !e.value_ptr.exported) continue;
        keys.append(a, e.key_ptr.*) catch return;
    }
    std.sort.heap([]const u8, keys.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    for (keys.items) |key| {
        const v = sh.vars.getPtr(key).?;
        var out: std.ArrayListUnmanaged(u8) = .{};
        if (exported_only) out.appendSlice(a, "export ") catch return;
        out.appendSlice(a, key) catch return;
        out.append(a, '=') catch return;
        if (v.array) {
            out.append(a, '(') catch return;
            for (v.values.items, 0..) |item, k| {
                if (k > 0) out.append(a, ' ') catch return;
                quote(a, &out, item) catch return;
            }
            out.append(a, ')') catch return;
        } else {
            quote(a, &out, if (v.values.items.len > 0) v.values.items[0] else "") catch return;
        }
        out.append(a, '\n') catch return;
        zdos.print(out.items);
    }
}

fn quote(a: Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) Allocator.Error!void {
    try out.append(a, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, c);
    }
    try out.append(a, '\'');
}

fn unset(sh: *Shell, args: []const []const u8) u8 {
    var functions = false;
    for (args) |arg| {
        if (eql(u8, arg, "-f")) {
            functions = true;
            continue;
        }
        if (eql(u8, arg, "-v")) continue;
        if (functions) {
            _ = sh.functions.remove(arg);
        } else {
            sh.unsetVar(arg);
        }
    }
    return 0;
}

fn local(sh: *Shell, args: []const []const u8) u8 {
    if (sh.function_depth == 0) {
        errout.print("ash: local: not in a function\n");
        return 1;
    }
    for (args) |arg| {
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = arg[0 .. eq orelse arg.len];
        if (!parser.isName(name)) {
            errout.printf("ash: local: {s}: bad variable name\n", .{name});
            return 1;
        }
        sh.makeLocal(name) catch return shell_mod.outOfMemory();
        if (eq) |e| {
            sh.setVar(name, arg[e + 1 ..]) catch return shell_mod.outOfMemory();
        }
    }
    return 0;
}

// For `set` and ash's command line: -e -u -x -f, -o NAME, + to switch off.
// Returns how many arguments it took, null on an error.
pub fn setOptions(sh: *Shell, arg: []const u8, next: ?[]const u8) ?usize {
    const on = arg[0] == '-';
    var used: usize = 1;
    for (arg[1..]) |c| {
        switch (c) {
            'e' => sh.opts.errexit = on,
            'u' => sh.opts.nounset = on,
            'x' => sh.opts.xtrace = on,
            'f' => sh.opts.noglob = on,
            'o' => {
                const option = next orelse {
                    listOptions(sh);
                    return used;
                };
                used = 2;
                if (eql(u8, option, "errexit")) sh.opts.errexit = on else if (eql(u8, option, "nounset")) sh.opts.nounset = on else if (eql(u8, option, "xtrace")) sh.opts.xtrace = on else if (eql(u8, option, "noglob")) sh.opts.noglob = on else if (eql(u8, option, "pipefail")) sh.opts.pipefail = on else {
                    errout.printf("ash: set: {s}: unknown option\n", .{option});
                    return null;
                }
            },
            'v', 'h', 'm', 'C', 'b', 'n', 'a' => {}, // accepted, no effect here
            else => {
                errout.printf("ash: set: -{c}: unknown option\n", .{c});
                return null;
            },
        }
    }
    return used;
}

fn listOptions(sh: *Shell) void {
    const list = [_]struct { []const u8, bool }{
        .{ "errexit", sh.opts.errexit },
        .{ "noglob", sh.opts.noglob },
        .{ "nounset", sh.opts.nounset },
        .{ "pipefail", sh.opts.pipefail },
        .{ "xtrace", sh.opts.xtrace },
    };
    for (list) |o| zdos.printf("{s:<12}{s}\n", .{ o[0], if (o[1]) "on" else "off" });
}

fn set(sh: *Shell, args: []const []const u8) u8 {
    if (args.len == 0) {
        listVars(sh, false);
        return 0;
    }
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (arg.len < 2 or (arg[0] != '-' and arg[0] != '+')) break;
        const used = setOptions(sh, arg, if (i + 1 < args.len) args[i + 1] else null) orelse return 2;
        i += used;
        if (i >= args.len) return 0;
    }
    sh.setArgs(args[i..]) catch return shell_mod.outOfMemory();
    return 0;
}

fn shift(sh: *Shell, args: []const []const u8) u8 {
    var count: usize = 1;
    if (args.len > 0) count = std.fmt.parseInt(usize, args[0], 10) catch {
        errout.print("ash: shift: numeric argument required\n");
        return 2;
    };
    if (count > sh.args.len) {
        errout.print("ash: shift: can't shift that many\n");
        return 1;
    }
    sh.setArgs(sh.args[count..]) catch return shell_mod.outOfMemory();
    return 0;
}

fn loopControl(sh: *Shell, name: []const u8, args: []const []const u8) u8 {
    var levels: u32 = 1;
    if (args.len > 0) levels = std.fmt.parseInt(u32, args[0], 10) catch 0;
    if (levels == 0) {
        errout.printf("ash: {s}: bad number\n", .{name});
        return 1;
    }
    if (sh.loop_depth == 0) return 0;
    sh.flow = if (name[0] == 'b') .break_ else .continue_;
    sh.flow_levels = @min(levels, sh.loop_depth);
    return 0;
}

fn returnCommand(sh: *Shell, args: []const []const u8) u8 {
    var status = sh.status;
    if (args.len > 0) status = parseStatus(args[0]) orelse {
        errout.print("ash: return: numeric argument required\n");
        return 2;
    };
    if (sh.function_depth == 0 and source_depth == 0) {
        errout.print("ash: return: not in a function\n");
        return 1;
    }
    sh.flow = .return_;
    sh.status = status;
    return status;
}

var source_depth: u32 = 0;

fn source(sh: *Shell, args: []const []const u8) u8 {
    if (args.len == 0) {
        errout.print("ash: .: a file name is needed\n");
        return 2;
    }
    const text = shell_mod.readScript(args[0]) orelse return 1;
    defer gpa.free(text);
    // Arguments after the name are $1 ... while it runs:
    const old_args = sh.args;
    var replaced = false;
    if (args.len > 1) {
        sh.args = &.{};
        sh.setArgs(args[1..]) catch {
            sh.args = old_args;
            return shell_mod.outOfMemory();
        };
        replaced = true;
    }
    source_depth += 1;
    const status = sh.runText(text, args[0]);
    source_depth -= 1;
    if (sh.flow == .return_) sh.flow = .none;
    if (replaced) {
        sh.setArgs(&.{}) catch {};
        sh.args = old_args;
    }
    return if (sh.flow == .none) sh.status else status;
}

fn trap(sh: *Shell, args: []const []const u8) u8 {
    if (args.len == 0) {
        if (sh.exit_trap) |t| zdos.printf("trap -- '{s}' EXIT\n", .{t});
        return 0;
    }
    if (args.len == 1) {
        errout.print("ash: trap: a signal name is needed\n");
        return 2;
    }
    for (args[1..]) |signal| {
        if (!(eql(u8, signal, "EXIT") or eql(u8, signal, "0"))) continue; // only EXIT happens
        if (sh.exit_trap) |t| gpa.free(t);
        sh.exit_trap = null;
        if (!eql(u8, args[0], "-") and args[0].len > 0) sh.exit_trap = gpa.dupe(u8, args[0]) catch return shell_mod.outOfMemory();
    }
    return 0;
}

fn read(sh: *Shell, a: Allocator, args_in: []const []const u8) u8 {
    var raw = false;
    var prompt: []const u8 = "";
    var args = args_in;
    while (args.len > 0 and args[0].len > 1 and args[0][0] == '-') {
        if (eql(u8, args[0], "-r")) {
            raw = true;
        } else if (eql(u8, args[0], "-p") and args.len > 1) {
            prompt = args[1];
            args = args[1..];
        } else if (eql(u8, args[0], "--")) {
            args = args[1..];
            break;
        } else {
            errout.printf("ash: read: {s}: unknown option\n", .{args[0]});
            return 2;
        }
        args = args[1..];
    }
    const targets: []const []const u8 = if (args.len == 0) &.{"REPLY"} else args;
    for (targets) |t| if (!parser.isName(t)) {
        errout.printf("ash: read: {s}: bad variable name\n", .{t});
        return 2;
    };
    var line: std.ArrayListUnmanaged(u8) = .{};
    // Characters that came from \x, kept from splitting:
    var escaped: std.ArrayListUnmanaged(bool) = .{};
    var got_newline = false;
    if (zdos.inputRedirected()) {
        var byte: [1]u8 = undefined;
        while (zdos.readInput(&byte) == 1) {
            var c = byte[0];
            if (c == '\r') continue;
            if (c == '\n') {
                got_newline = true;
                break;
            }
            var esc = false;
            if (c == '\\' and !raw) {
                if (zdos.readInput(&byte) != 1) break;
                c = byte[0];
                if (c == '\r' and zdos.readInput(&byte) == 1) c = byte[0];
                if (c == '\n') continue; // a line continued
                esc = true;
            }
            line.append(a, c) catch return shell_mod.outOfMemory();
            escaped.append(a, esc) catch return shell_mod.outOfMemory();
        }
    } else {
        zdos.print(prompt);
        while (true) {
            const key = zdos.readKey();
            if (key.char == '\r' or key.char == '\n') {
                zdos.print("\n");
                got_newline = true;
                break;
            }
            if (key.char == 4) break;
            if (key.char == 3) return 130;
            if (key.char == 0x08 or key.char == 0x7f) {
                if (line.items.len > 0) {
                    line.items.len -= 1;
                    escaped.items.len -= 1;
                    zdos.print("\x08 \x08");
                }
            } else if (key.char >= 0x20 and key.char < 0x7f) {
                const c: u8 = @intCast(key.char);
                line.append(a, c) catch return shell_mod.outOfMemory();
                escaped.append(a, false) catch return shell_mod.outOfMemory();
                zdos.print(&.{c});
            }
        }
    }
    // Split at IFS: one field per name, the rest of the line for the last:
    const ifs = sh.getVar("IFS") orelse " \t\n";
    var i: usize = 0;
    const items = line.items;
    const isIfs = struct {
        fn f(set_: []const u8, chars: []const u8, esc: []const bool, k: usize) bool {
            return !esc[k] and std.mem.indexOfScalar(u8, set_, chars[k]) != null;
        }
    }.f;
    const isWhite = struct {
        fn f(c: u8) bool {
            return c == ' ' or c == '\t' or c == '\n';
        }
    }.f;
    for (targets, 0..) |name, n| {
        while (i < items.len and isIfs(ifs, items, escaped.items, i) and isWhite(items[i])) i += 1;
        var end = i;
        if (n + 1 == targets.len) {
            end = items.len;
            // Trailing IFS white space goes:
            while (end > i and isIfs(ifs, items, escaped.items, end - 1) and isWhite(items[end - 1])) end -= 1;
        } else {
            while (end < items.len and !isIfs(ifs, items, escaped.items, end)) end += 1;
        }
        sh.setVar(name, items[i..end]) catch return shell_mod.outOfMemory();
        i = end;
        if (i < items.len and n + 1 < targets.len) {
            // One delimiter: white space around a non-white one:
            while (i < items.len and isIfs(ifs, items, escaped.items, i) and isWhite(items[i])) i += 1;
            if (i < items.len and isIfs(ifs, items, escaped.items, i) and !isWhite(items[i])) i += 1;
        }
    }
    return if (got_newline) 0 else 1;
}

fn describe(sh: *Shell, a: Allocator, name: []const u8, verbose: bool) bool {
    if (sh.functions.contains(name)) {
        zdos.printf("{s}{s}\n", .{ name, if (verbose) " is a shell function" else "" });
        return true;
    }
    if (names.isBuiltin(name)) {
        zdos.printf("{s}{s}\n", .{ name, if (verbose) " is a shell builtin" else "" });
        return true;
    }
    const matches = command_lookup.find(a, name) catch return false;
    if (matches.len == 0) {
        if (verbose) errout.printf("{s}: not found\n", .{name});
        return false;
    }
    if (verbose) zdos.printf("{s} is {s}\n", .{ name, matches[0] }) else zdos.printf("{s}\n", .{matches[0]});
    return true;
}

fn command(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    if (args.len == 0) return 0;
    if (eql(u8, args[0], "-v") or eql(u8, args[0], "-V")) {
        var status: u8 = 0;
        for (args[1..]) |name| {
            if (!describe(sh, a, name, args[0][1] == 'V')) status = 1;
        }
        return status;
    }
    return sh.runBuiltinOrProgram(a, args);
}

fn typeCommand(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var status: u8 = 0;
    for (args) |name| {
        if (!describe(sh, a, name, true)) status = 1;
    }
    return status;
}

fn env(sh: *Shell, a: Allocator, args: []const []const u8) u8 {
    var first: usize = 0;
    while (first < args.len and std.mem.indexOfScalar(u8, args[first], '=') != null) first += 1;
    const pushed = if (first > 0) (if (sys.pushVars()) true else |_| false) else false;
    defer if (pushed) sys.popVars();
    for (args[0..first]) |assignment| {
        const eq = std.mem.indexOfScalar(u8, assignment, '=').?;
        zdos.setVar(assignment[0..eq], assignment[eq + 1 ..]) catch |err| {
            errout.printf("env: {s}\n", .{zdos.message(err)});
            return 1;
        };
    }
    if (first < args.len) return sh.runBuiltinOrProgram(a, args[first..]);
    var index: u32 = 0;
    var buffer: [600]u8 = undefined;
    while (zdos.varAt(index, &buffer)) |entry| : (index += 1) {
        zdos.print(entry);
        zdos.print("\n");
    }
    return 0;
}

fn help() u8 {
    zdos.print(
        \\ash built-in commands:
        \\  shell     . : [ break cd command continue echo eval exec exit export
        \\            false help local printf pwd read readonly return set shift
        \\            source test trap true type unset wait
        \\  files     cat chmod chown cp/copy df find ls/list/dir mkdir mv/move
        \\            rm/remove/del rmdir touch xxd
        \\  text      awk basename cut diff dirname grep head patch sed sort tail
        \\            uniq wc xargs
        \\  other     clear date env sleep where which
        \\Other commands are programs (.APP) and scripts (.sh) in the current
        \\folder or PATH. Pipelines run one command after another.
        \\Syntax: ; && || | < > >> << 2> >&2, if/while/until/for/case,
        \\name() { ... }, ( ... ), $var ${var:-x} ${#var} ${var%x} $(...) $((...)),
        \\arrays name=(a b) ${name[@]}. Paths use / ; a drive is /C:/ .
        \\See docs/ASH.md for details.
        \\
    );
    return 0;
}
