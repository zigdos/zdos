// sed [-nEs] [-i[SUFFIX]] [-e SCRIPT]... [-f FILE]... [SCRIPT] [FILE...]
// Back-references inside a pattern (\(a\)\1) are refused: regex.zig
// can't match them in linear time.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const sys = @import("../zdos/system.zig");
const errout = @import("errout.zig");
const regex = @import("regex.zig");
const text = @import("text.zig");

const Allocator = std.mem.Allocator;
const List = std.ArrayListUnmanaged(u8);

const Error = error{ Script, OutOfMemory, Interrupted };

// THE SCRIPT

const Addr = union(enum) {
    line: usize,
    last, // $
    re: ?usize, // an index into Sed.regexes; null: the last regex used
    step: struct { first: usize, step: usize }, // first~step
    plus: usize, // second address only: +N lines after the first
};

// Text, or what a group matched (0: the whole match, &).
const Part = union(enum) { lit: []const u8, group: u8 };

const Subst = struct {
    re: ?usize,
    parts: []const Part,
    global: bool = false,
    nth: usize = 1,
    prints: u8 = 0, // p flags
    wfile: ?usize = null,
};

const Cmd = struct {
    a1: ?Addr = null,
    a2: ?Addr = null,
    negate: bool = false,
    active: bool = false, // inside its range
    range_end: usize = 0, // the last line of a +N range
    op: u8,
    arg: []const u8 = "", // the text of a i c, the label of : b t T, the file of r
    num: usize = 0, // the exit code of q Q; the index after the } of {; the target of b t T
    sub: ?*Subst = null,
    map: ?*[256]u8 = null, // y
    wfile: usize = 0, // w
};

// The standard output, a w file, or the file -i rewrites.
const Sink = struct {
    file: ?zdos.File = null,
    screen: bool = false, // /dev/stderr
    buf: List = .{},
    crlf: bool = false, // write line ends as "\r\n" (-i on a DOS file)
    missing_newline: bool = false, // the last line went out without one

    fn write(self: *Sink, a: Allocator, s: []const u8) Allocator.Error!void {
        if (self.crlf) {
            for (s) |c| {
                if (c == '\n') try self.buf.append(a, '\r');
                try self.buf.append(a, c);
            }
        } else try self.buf.appendSlice(a, s);
        if (self.buf.items.len >= 4096) self.flush();
    }

    // Without newline (the input's last line had none) the next output
    // starts with the line end it lacked.
    fn line(self: *Sink, a: Allocator, s: []const u8, newline: bool) Allocator.Error!void {
        if (self.missing_newline) try self.write(a, "\n");
        try self.write(a, s);
        if (newline) try self.write(a, "\n");
        self.missing_newline = !newline;
    }

    fn flush(self: *Sink) void {
        if (self.buf.items.len == 0) return;
        if (self.file) |f| {
            f.writeAll(self.buf.items) catch |err| errout.printf("sed: write error: {s}\n", .{zdos.message(err)});
        } else if (self.screen) errout.print(self.buf.items) else zdos.print(self.buf.items);
        self.buf.clearRetainingCapacity();
    }
};

const End = enum { next, delete, restart, quit, quit_silent };

// a text and r files, written at the end of the cycle.
const Pending = union(enum) { text: []const u8, file: []const u8 };

const Sed = struct {
    a: Allocator,
    interrupted: *bool,
    quiet: bool = false,
    extended: bool = false,
    separate: bool = false,
    in_place: ?[]const u8 = null, // the backup suffix ("": none)
    cmds: std.ArrayListUnmanaged(Cmd) = .{},
    regexes: std.ArrayListUnmanaged(regex.Regex) = .{},
    outs: std.ArrayListUnmanaged(Sink) = .{}, // 0: the standard output
    w_names: std.ArrayListUnmanaged([]const u8) = .{},
    uses_last: bool = false, // the script has $: lines are read one ahead
    ps: List = .{}, // pattern space
    hs: List = .{}, // hold space
    scratch: List = .{},
    pending: std.ArrayListUnmanaged(Pending) = .{},
    out: *Sink = undefined,
    line_no: usize = 0,
    last_line: bool = false,
    no_newline: bool = false, // the last line read had no line end
    replaced: bool = false, // for t and T
    last_re: ?usize = null,
    status: u8 = 0,
    steps: usize = 0,
    quit: bool = false,
    files: []const []const u8 = &.{},
    file_i: usize = 0,
    file_name: []const u8 = "-", // F
    reader: ?text.Reader = null,
    ahead: List = .{},
    ahead_valid: bool = false,
    ahead_newline: bool = false,

    // INPUT

    fn openNext(self: *Sed) bool {
        while (self.file_i < self.files.len) {
            const name = self.files[self.file_i];
            self.file_i += 1;
            self.reader = text.Reader.open(name) catch |err| {
                errout.printf("sed: can't read {s}: {s}\n", .{ name, zdos.message(err) });
                self.status = 2;
                continue;
            };
            self.file_name = name;
            return true;
        }
        return false;
    }

    // False at the end.
    fn fetch(self: *Sed) Allocator.Error!bool {
        if (self.ahead_valid) return true;
        while (true) {
            if (self.reader == null and !self.openNext()) return false;
            var r = &self.reader.?;
            if (r.readLine(self.a, &self.ahead) catch false) {
                self.ahead_valid = true;
                self.ahead_newline = r.newline;
                if (self.in_place != null and r.crlf) self.out.crlf = true;
                return true;
            }
            r.close();
            self.reader = null;
        }
    }

    // With append after a newline; false at the end of the input.
    fn takeLine(self: *Sed, append: bool) Allocator.Error!bool {
        if (!try self.fetch()) return false;
        if (!append) self.ps.clearRetainingCapacity() else try self.ps.append(self.a, '\n');
        try self.ps.appendSlice(self.a, self.ahead.items);
        self.ahead_valid = false;
        self.no_newline = !self.ahead_newline;
        self.line_no += 1;
        self.replaced = false;
        self.last_line = self.uses_last and !try self.fetch();
        return true;
    }

    // ADDRESSES

    fn match(self: *Sed, re: ?usize) Error!bool {
        const i = re orelse self.last_re orelse {
            errout.print("sed: no previous regular expression\n");
            return error.Script;
        };
        self.last_re = i;
        return self.regexes.items[i].search(self.ps.items, 0) != null;
    }

    fn addrMatches(self: *Sed, addr: Addr) Error!bool {
        return switch (addr) {
            .line => |n| self.line_no == n,
            .last => self.last_line,
            .re => |re| try self.match(re),
            .step => |s| if (s.step == 0) self.line_no == s.first else self.line_no >= s.first and (self.line_no - s.first) % s.step == 0,
            .plus => false,
        };
    }

    fn selected(self: *Sed, cmd: *Cmd) Error!bool {
        const a1 = cmd.a1 orelse return !cmd.negate;
        const a2 = cmd.a2 orelse return (try self.addrMatches(a1)) != cmd.negate;
        if (cmd.active) {
            const ends = switch (a2) {
                .line => |n| self.line_no >= n,
                .plus => self.line_no >= cmd.range_end,
                else => try self.addrMatches(a2),
            };
            if (ends) cmd.active = false;
            return !cmd.negate;
        }
        if (!try self.addrMatches(a1)) return cmd.negate;
        // A range's first line; a line number not ahead ends it at once:
        cmd.active = switch (a2) {
            .line => |n| n > self.line_no,
            .plus => |n| blk: {
                cmd.range_end = self.line_no + n;
                break :blk n > 0;
            },
            .last => !self.last_line,
            else => true,
        };
        return !cmd.negate;
    }

    // COMMANDS

    fn exec(self: *Sed) Error!End {
        var pc: usize = 0;
        const a = self.a;
        while (pc < self.cmds.items.len) {
            self.steps +%= 1;
            if (self.steps & 0x3ff == 0 and sys.ctrlCPressed(true)) {
                self.interrupted.* = true;
                return error.Interrupted;
            }
            const cmd = &self.cmds.items[pc];
            if (!try self.selected(cmd)) {
                pc = if (cmd.op == '{') cmd.num else pc + 1;
                continue;
            }
            switch (cmd.op) {
                '{', '}', ':' => {},
                '=' => {
                    var buf: [24]u8 = undefined;
                    try self.out.line(a, std.fmt.bufPrint(&buf, "{d}", .{self.line_no}) catch unreachable, true);
                },
                'F' => try self.out.line(a, self.file_name, true),
                'a' => try self.pending.append(a, .{ .text = cmd.arg }),
                'i' => try self.out.line(a, cmd.arg, true),
                'c' => {
                    // A range is changed as a whole: the text once, at its end:
                    if (cmd.a2 == null or cmd.negate or !cmd.active) try self.out.line(a, cmd.arg, true);
                    return .delete;
                },
                'd' => return .delete,
                'D' => {
                    const nl = std.mem.indexOfScalar(u8, self.ps.items, '\n') orelse return .delete;
                    std.mem.copyForwards(u8, self.ps.items, self.ps.items[nl + 1 ..]);
                    self.ps.items.len -= nl + 1;
                    return .restart;
                },
                'g' => {
                    self.ps.clearRetainingCapacity();
                    try self.ps.appendSlice(a, self.hs.items);
                },
                'G' => {
                    try self.ps.append(a, '\n');
                    try self.ps.appendSlice(a, self.hs.items);
                },
                'h' => {
                    self.hs.clearRetainingCapacity();
                    try self.hs.appendSlice(a, self.ps.items);
                },
                'H' => {
                    try self.hs.append(a, '\n');
                    try self.hs.appendSlice(a, self.ps.items);
                },
                'l' => try self.list(),
                'n' => {
                    if (!self.quiet) try self.out.line(a, self.ps.items, !self.no_newline);
                    try self.flushPending();
                    if (!try self.takeLine(false)) return .quit_silent;
                },
                'N' => {
                    try self.flushPending();
                    // No next line: as GNU, the pattern
                    // space is printed and sed ends:
                    if (!try self.takeLine(true)) return .quit;
                },
                'p' => try self.out.line(a, self.ps.items, !self.no_newline),
                'P' => {
                    const nl = std.mem.indexOfScalar(u8, self.ps.items, '\n');
                    try self.out.line(a, self.ps.items[0 .. nl orelse self.ps.items.len], nl != null or !self.no_newline);
                },
                'q', 'Q' => {
                    self.status = @truncate(cmd.num);
                    return if (cmd.op == 'q') .quit else .quit_silent;
                },
                'r' => try self.pending.append(a, .{ .file = cmd.arg }),
                's' => try self.substitute(cmd.sub.?),
                'b' => {
                    pc = cmd.num;
                    continue;
                },
                't', 'T' => {
                    const jump = self.replaced == (cmd.op == 't');
                    self.replaced = false;
                    if (jump) {
                        pc = cmd.num;
                        continue;
                    }
                },
                'w' => try self.outs.items[cmd.wfile].line(a, self.ps.items, !self.no_newline),
                'x' => std.mem.swap(List, &self.ps, &self.hs),
                'y' => for (self.ps.items) |*c| {
                    c.* = cmd.map.?[c.*];
                },
                'z' => self.ps.clearRetainingCapacity(),
                else => unreachable,
            }
            pc += 1;
        }
        return .next;
    }

    fn substitute(self: *Sed, sub: *Subst) Error!void {
        const i = sub.re orelse self.last_re orelse {
            errout.print("sed: no previous regular expression\n");
            return error.Script;
        };
        self.last_re = i;
        const re = &self.regexes.items[i];
        const ps = self.ps.items;
        const a = self.a;
        var out = &self.scratch;
        out.clearRetainingCapacity();
        var copied: usize = 0; // ps up to here is in out
        var pos: usize = 0;
        var count: usize = 0;
        var prev_end: ?usize = null;
        var did = false;
        while (pos <= ps.len) {
            const m = re.search(ps, pos) orelse break;
            // An empty match right after a match doesn't count (s/x*/-/g):
            if (m.start == m.end and prev_end != null and m.start == prev_end.?) {
                if (m.start >= ps.len) break;
                pos = m.start + 1;
                continue;
            }
            count += 1;
            if (count >= sub.nth) {
                try out.appendSlice(a, ps[copied..m.start]);
                for (sub.parts) |part| switch (part) {
                    .lit => |s| try out.appendSlice(a, s),
                    .group => |g| if (g == 0) {
                        try out.appendSlice(a, ps[m.start..m.end]);
                    } else if (re.group(g)) |x| try out.appendSlice(a, ps[x.start..x.end]),
                };
                copied = m.end;
                did = true;
                if (!sub.global) break;
            }
            prev_end = m.end;
            pos = if (m.end > m.start) m.end else m.end + 1;
        }
        if (!did) return;
        try out.appendSlice(a, ps[copied..]);
        std.mem.swap(List, &self.ps, &self.scratch);
        self.replaced = true;
        var k: u8 = 0;
        while (k < sub.prints) : (k += 1) try self.out.line(a, self.ps.items, !self.no_newline);
        if (sub.wfile) |w| try self.outs.items[w].line(a, self.ps.items, !self.no_newline);
    }

    // l: in lines of 70 columns.
    fn list(self: *Sed) Allocator.Error!void {
        const a = self.a;
        var row: List = .{};
        defer row.deinit(a);
        for (self.ps.items) |c| {
            var piece: [4]u8 = undefined;
            const s: []const u8 = switch (c) {
                '\\' => "\\\\",
                0x07 => "\\a",
                0x08 => "\\b",
                0x0c => "\\f",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                0x0b => "\\v",
                else => if (c >= 0x20 and c < 0x7f) blk: {
                    piece[0] = c;
                    break :blk piece[0..1];
                } else std.fmt.bufPrint(&piece, "\\{o:0>3}", .{c}) catch unreachable,
            };
            if (row.items.len + s.len > 69) {
                try row.append(a, '\\');
                try self.out.line(a, row.items, true);
                row.clearRetainingCapacity();
            }
            try row.appendSlice(a, s);
        }
        try row.append(a, '$');
        try self.out.line(a, row.items, true);
    }

    fn flushPending(self: *Sed) Allocator.Error!void {
        for (self.pending.items) |p| switch (p) {
            .text => |t| try self.out.line(self.a, t, true),
            .file => |name| {
                const f = zdos.open(name, .read) catch continue; // skipped, as POSIX says
                defer f.close();
                if (self.out.missing_newline) try self.out.line(self.a, "", false);
                var buf: [4096]u8 = undefined;
                while (true) {
                    const n = f.read(&buf) catch break;
                    if (n == 0) break;
                    try self.out.write(self.a, buf[0..n]);
                }
            },
        };
        self.pending.clearRetainingCapacity();
    }

    // One stream, or one file with -s and -i.
    fn stream(self: *Sed, files: []const []const u8) Error!void {
        self.files = files;
        self.file_i = 0;
        self.line_no = 0;
        self.ahead_valid = false;
        for (self.cmds.items) |*c| c.active = if (c.a1) |a1| a1 == .line and a1.line == 0 else false;
        defer {
            if (self.reader) |*r| r.close();
            self.reader = null;
        }
        if (!try self.takeLine(false)) return;
        while (true) {
            const end = try self.exec();
            if ((end == .next or end == .quit) and !self.quiet) try self.out.line(self.a, self.ps.items, !self.no_newline);
            try self.flushPending();
            if (end == .quit or end == .quit_silent) {
                self.quit = true;
                break;
            }
            if (end == .restart) continue;
            if (!try self.takeLine(false)) break;
        }
    }

    // -i: through a temporary file beside it, which takes its place; the
    // original goes to FILE + SUFFIX if given.
    fn editInPlace(self: *Sed, name: []const u8) Error!void {
        const tmp = try std.fmt.allocPrint(self.a, "{s}.sedtmp", .{name});
        if (zdos.stat(name)) |e| {
            if (e.is_dir) {
                errout.printf("sed: couldn't edit {s}: not a regular file\n", .{name});
                self.status = 4;
                return;
            }
        } else |err| {
            errout.printf("sed: can't read {s}: {s}\n", .{ name, zdos.message(err) });
            self.status = 2;
            return;
        }
        const f = zdos.open(tmp, .write) catch |err| {
            errout.printf("sed: couldn't open {s}: {s}\n", .{ tmp, zdos.message(err) });
            self.status = 4;
            return;
        };
        var sink: Sink = .{ .file = f };
        self.out = &sink;
        defer self.out = &self.outs.items[0];
        self.stream(&.{name}) catch |err| {
            sink.flush();
            f.close();
            zdos.delete(tmp) catch {};
            return err;
        };
        sink.flush();
        f.closeChecked() catch |err| {
            errout.printf("sed: couldn't write {s}: {s}\n", .{ tmp, zdos.message(err) });
            zdos.delete(tmp) catch {};
            self.status = 4;
            return;
        };
        const suffix = self.in_place.?;
        if (suffix.len > 0) {
            const backup = try std.fmt.allocPrint(self.a, "{s}{s}", .{ name, suffix });
            zdos.delete(backup) catch {};
            zdos.move(name, backup) catch |err| return self.replaceFailed(name, tmp, err);
        } else zdos.delete(name) catch |err| return self.replaceFailed(name, tmp, err);
        zdos.move(tmp, name) catch |err| return self.replaceFailed(name, tmp, err);
    }

    fn replaceFailed(self: *Sed, name: []const u8, tmp: []const u8, err: zdos.Error) void {
        errout.printf("sed: couldn't replace {s}: {s} (the result is in {s})\n", .{ name, zdos.message(err), tmp });
        self.status = 4;
    }
};

// PARSING

const Parser = struct {
    sed: *Sed,
    s: []const u8,
    pos: usize = 0,
    blocks: std.ArrayListUnmanaged(usize) = .{}, // the { not yet closed

    fn fail(self: *Parser, comptime msg: []const u8, args: anytype) Error {
        errout.printf("sed: char {d}: " ++ msg ++ "\n", .{self.pos} ++ args);
        return error.Script;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.s.len) self.s[self.pos] else null;
    }

    fn skipBlanks(self: *Parser) void {
        while (self.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            self.pos += 1;
        }
    }

    fn number(self: *Parser) ?usize {
        const start = self.pos;
        while (self.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            self.pos += 1;
        }
        if (self.pos == start) return null;
        return std.fmt.parseInt(usize, self.s[start..self.pos], 10) catch null;
    }

    fn script(self: *Parser) Error!void {
        const sed = self.sed;
        if (std.mem.startsWith(u8, self.s, "#n") and (self.s.len == 2 or self.s[2] == '\n')) sed.quiet = true;
        while (true) {
            while (self.peek()) |c| {
                if (c != ' ' and c != '\t' and c != '\n' and c != ';') break;
                self.pos += 1;
            }
            const c0 = self.peek() orelse break;
            if (c0 == '#') {
                while (self.peek()) |c| : (self.pos += 1) if (c == '\n') break;
                continue;
            }
            var cmd: Cmd = .{ .op = 0 };
            cmd.a1 = try self.address(false);
            if (cmd.a1 != null) {
                self.skipBlanks();
                if (self.peek() == ',') {
                    self.pos += 1;
                    self.skipBlanks();
                    cmd.a2 = try self.address(true) orelse return self.fail("unexpected `,'", .{});
                }
                if (cmd.a1.? == .line and cmd.a1.?.line == 0 and (cmd.a2 == null or cmd.a2.? != .re))
                    return self.fail("invalid usage of line address 0", .{});
            }
            self.skipBlanks();
            while (self.peek() == '!') {
                self.pos += 1;
                cmd.negate = true;
                self.skipBlanks();
            }
            const op = self.peek() orelse return self.fail("missing command", .{});
            self.pos += 1;
            cmd.op = op;
            switch (op) {
                '{' => {
                    try self.blocks.append(sed.a, sed.cmds.items.len);
                    try sed.cmds.append(sed.a, cmd);
                    continue;
                },
                '}' => {
                    if (cmd.a1 != null or cmd.negate) return self.fail("unexpected `}}'", .{});
                    const open = self.blocks.pop() orelse return self.fail("unexpected `}}'", .{});
                    sed.cmds.items[open].num = sed.cmds.items.len + 1;
                },
                '=', 'd', 'D', 'F', 'g', 'G', 'h', 'H', 'l', 'n', 'N', 'p', 'P', 'x', 'z' => {},
                'a', 'i', 'c' => cmd.arg = try self.textArg(),
                ':' => {
                    if (cmd.a1 != null) return self.fail(": doesn't want any addresses", .{});
                    cmd.arg = self.label();
                    if (cmd.arg.len == 0) return self.fail("\":\" lacks a label", .{});
                },
                'b', 't', 'T' => cmd.arg = self.label(),
                'r' => cmd.arg = try self.fileName(),
                'w' => cmd.wfile = try self.outFile(try self.fileName()),
                'q', 'Q' => {
                    if (cmd.a2 != null) return self.fail("command only uses one address", .{});
                    self.skipBlanks();
                    cmd.num = self.number() orelse 0;
                },
                's' => cmd.sub = try self.subst(),
                'y' => cmd.map = try self.translit(),
                else => return self.fail("unknown command: `{c}'", .{op}),
            }
            try sed.cmds.append(sed.a, cmd);
            self.skipBlanks();
            if (self.peek()) |c| switch (c) {
                '\n', ';', '}', '#' => {},
                else => return self.fail("extra characters after command", .{}),
            };
        }
        if (self.blocks.items.len > 0) return self.fail("unmatched `{{'", .{});
        // Labels: b t T jump to the command after their label, or past the end:
        for (sed.cmds.items) |*cmd| {
            if (cmd.op != 'b' and cmd.op != 't' and cmd.op != 'T') continue;
            cmd.num = sed.cmds.items.len;
            if (cmd.arg.len == 0) continue;
            for (sed.cmds.items, 0..) |other, k| {
                if (other.op == ':' and std.mem.eql(u8, other.arg, cmd.arg)) {
                    cmd.num = k + 1;
                    break;
                }
            } else {
                errout.printf("sed: can't find label for jump to `{s}'\n", .{cmd.arg});
                return error.Script;
            }
        }
    }

    fn address(self: *Parser, second: bool) Error!?Addr {
        const c = self.peek() orelse return null;
        if (std.ascii.isDigit(c)) {
            const n = self.number() orelse return self.fail("bad line number", .{});
            if (!second and self.peek() == '~') {
                self.pos += 1;
                return .{ .step = .{ .first = n, .step = self.number() orelse 0 } };
            }
            return .{ .line = n };
        }
        if (c == '$') {
            self.pos += 1;
            self.sed.uses_last = true;
            return .last;
        }
        if (second and c == '+') {
            self.pos += 1;
            return .{ .plus = self.number() orelse return self.fail("expected a number after +", .{}) };
        }
        if (c == '/' or c == '\\') {
            self.pos += 1;
            const delim = if (c == '/') '/' else (self.peek() orelse return self.fail("unterminated address regex", .{}));
            if (c == '\\') self.pos += 1;
            const raw = try self.delimited(delim, "unterminated address regex");
            var icase = false;
            while (self.peek()) |f| {
                if (f != 'I') break;
                icase = true;
                self.pos += 1;
            }
            return .{ .re = try self.compile(raw, delim, icase) };
        }
        return null;
    }

    // The delim is skipped; escapes are kept.
    fn delimited(self: *Parser, delim: u8, comptime what: []const u8) Error![]const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == '\\' and self.pos + 1 < self.s.len) {
                self.pos += 2;
                continue;
            }
            if (c == delim) {
                self.pos += 1;
                return self.s[start .. self.pos - 1];
            }
            if (c == '\n' and delim != '\n') break;
            self.pos += 1;
        }
        return self.fail(what, .{});
    }

    // Null for the empty one (the last regex used).
    fn compile(self: *Parser, raw: []const u8, delim: u8, icase: bool) Error!?usize {
        if (raw.len == 0) return null;
        const sed = self.sed;
        var pat: List = .{};
        var k: usize = 0;
        while (k < raw.len) : (k += 1) {
            if (raw[k] == '\\' and k + 1 < raw.len) {
                const n = raw[k + 1];
                if (n >= '1' and n <= '9') return self.fail("back-references in a pattern (\\{c}) are not supported", .{n});
                if (n == delim) {
                    try pat.append(sed.a, delim);
                } else try pat.appendSlice(sed.a, raw[k .. k + 2]);
                k += 1;
                continue;
            }
            try pat.append(sed.a, raw[k]);
        }
        const ere = if (sed.extended) pat.items else try regex.fromBasic(sed.a, pat.items);
        const re = regex.compile(sed.a, ere, .{ .icase = icase }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return self.fail("bad regular expression: {s}", .{raw});
        };
        try sed.regexes.append(sed.a, re);
        return sed.regexes.items.len - 1;
    }

    fn subst(self: *Parser) Error!*Subst {
        const sed = self.sed;
        const delim = self.peek() orelse return self.fail("unterminated `s' command", .{});
        if (delim == '\\' or delim == '\n') return self.fail("bad delimiter for `s'", .{});
        self.pos += 1;
        const raw_re = try self.delimited(delim, "unterminated `s' command");
        const raw_repl = try self.delimited(delim, "unterminated `s' command");
        const sub = try sed.a.create(Subst);
        sub.* = .{ .re = null, .parts = &.{} };
        var icase = false;
        var nth_set = false;
        while (self.peek()) |c| {
            switch (c) {
                'g' => sub.global = true,
                'p' => sub.prints += 1,
                'I', 'i' => icase = true,
                '0'...'9' => {
                    if (nth_set) return self.fail("multiple number options to `s' command", .{});
                    sub.nth = self.number() orelse unreachable;
                    if (sub.nth == 0) return self.fail("number option to `s' command may not be zero", .{});
                    nth_set = true;
                    continue;
                },
                'w' => {
                    self.pos += 1;
                    sub.wfile = try self.outFile(try self.fileName());
                    break;
                },
                'e', 'm', 'M' => return self.fail("`s' option `{c}' is not supported", .{c}),
                else => break,
            }
            self.pos += 1;
        }
        sub.re = try self.compile(raw_re, delim, icase);
        sub.parts = try self.replacement(raw_repl, delim);
        return sub;
    }

    // \1 ... \9 and & are what the groups matched; escapes as in escaped().
    fn replacement(self: *Parser, raw: []const u8, delim: u8) Error![]const Part {
        const a = self.sed.a;
        var parts: std.ArrayListUnmanaged(Part) = .{};
        var lit: List = .{};
        var k: usize = 0;
        while (k < raw.len) : (k += 1) {
            const c = raw[k];
            var group: ?u8 = null;
            if (c == '&') {
                group = 0;
            } else if (c == '\\' and k + 1 < raw.len) {
                k += 1;
                const n = raw[k];
                if (n >= '1' and n <= '9') {
                    group = n - '0';
                } else try lit.append(a, if (n == delim) n else escaped(n));
            } else try lit.append(a, c);
            if (group) |g| {
                if (lit.items.len > 0) try parts.append(a, .{ .lit = try lit.toOwnedSlice(a) });
                try parts.append(a, .{ .group = g });
            }
        }
        if (lit.items.len > 0) try parts.append(a, .{ .lit = try lit.toOwnedSlice(a) });
        return parts.toOwnedSlice(a);
    }

    fn translit(self: *Parser) Error!*[256]u8 {
        const a = self.sed.a;
        const delim = self.peek() orelse return self.fail("unterminated `y' command", .{});
        self.pos += 1;
        const from = try unescape(a, try self.delimited(delim, "unterminated `y' command"), delim);
        const to = try unescape(a, try self.delimited(delim, "unterminated `y' command"), delim);
        if (from.len != to.len) return self.fail("strings for `y' command are different lengths", .{});
        const map = try a.create([256]u8);
        for (map, 0..) |*m, k| m.* = @intCast(k);
        for (from, to) |f, t| map[f] = t;
        return map;
    }

    // "a text" (GNU) or "a\" and the text on the next lines, each but the
    // last ending in \.
    fn textArg(self: *Parser) Error![]const u8 {
        const a = self.sed.a;
        self.skipBlanks();
        if (self.peek() == '\\') {
            self.pos += 1;
            if (self.peek() == '\n') self.pos += 1;
        }
        var out: List = .{};
        while (self.peek()) |c| {
            if (c == '\n') break;
            self.pos += 1;
            if (c == '\\') {
                const n = self.peek() orelse break;
                self.pos += 1;
                try out.append(a, n);
                continue;
            }
            try out.append(a, c);
        }
        return out.toOwnedSlice(a);
    }

    fn label(self: *Parser) []const u8 {
        self.skipBlanks();
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == '\n' or c == ';') break;
            self.pos += 1;
        }
        return std.mem.trimRight(u8, self.s[start..self.pos], " \t");
    }

    fn fileName(self: *Parser) Error![]const u8 {
        self.skipBlanks();
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == '\n') break;
            self.pos += 1;
        }
        if (self.pos == start) return self.fail("missing filename in r/R/w/W commands", .{});
        return self.s[start..self.pos];
    }

    // One per file name, made empty before sed starts.
    fn outFile(self: *Parser, name: []const u8) Error!usize {
        const sed = self.sed;
        if (std.mem.eql(u8, name, "/dev/stdout")) return 0;
        for (sed.w_names.items, 1..) |n, k| if (std.mem.eql(u8, n, name)) return k;
        var sink: Sink = .{};
        if (std.mem.eql(u8, name, "/dev/stderr")) {
            sink.screen = true;
        } else {
            sink.file = zdos.open(name, .write) catch |err| return self.fail("couldn't open file {s}: {s}", .{ name, zdos.message(err) });
        }
        try sed.outs.append(sed.a, sink);
        try sed.w_names.append(sed.a, name);
        return sed.outs.items.len - 1;
    }
};

// As GNU sed; other characters stand for themselves.
fn escaped(c: u8) u8 {
    return switch (c) {
        'n' => '\n',
        't' => '\t',
        'r' => '\r',
        'a' => 0x07,
        'f' => 0x0c,
        'v' => 0x0b,
        else => c,
    };
}

// y's strings: \\ \delim and the escapes above.
fn unescape(a: Allocator, raw: []const u8, delim: u8) Allocator.Error![]const u8 {
    var out: List = .{};
    var k: usize = 0;
    while (k < raw.len) : (k += 1) {
        if (raw[k] == '\\' and k + 1 < raw.len) {
            k += 1;
            try out.append(a, if (raw[k] == delim) raw[k] else escaped(raw[k]));
            continue;
        }
        try out.append(a, raw[k]);
    }
    return out.toOwnedSlice(a);
}

pub fn run(interrupted: *bool, args: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(zdos.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sed: Sed = .{ .a = a, .interrupted = interrupted };
    var pieces: List = .{};
    var have_script = false;
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
            const long = arg[2..];
            const eq = std.mem.indexOfScalar(u8, long, '=');
            const name = long[0 .. eq orelse long.len];
            const value: ?[]const u8 = if (eq) |e| long[e + 1 ..] else null;
            if (std.mem.eql(u8, name, "quiet") or std.mem.eql(u8, name, "silent")) {
                sed.quiet = true;
            } else if (std.mem.eql(u8, name, "regexp-extended")) {
                sed.extended = true;
            } else if (std.mem.eql(u8, name, "separate")) {
                sed.separate = true;
            } else if (std.mem.eql(u8, name, "in-place")) {
                sed.in_place = value orelse "";
            } else if (std.mem.eql(u8, name, "expression") or std.mem.eql(u8, name, "file")) {
                const v = value orelse blk: {
                    i += 1;
                    break :blk if (i < args.len) args[i] else return usage();
                };
                if (!addPiece(a, &pieces, v, name[0] == 'f')) return 1;
                have_script = true;
            } else {
                errout.printf("sed: unknown option: {s}\n", .{arg});
                return 1;
            }
            continue;
        }
        var k: usize = 1;
        while (k < arg.len) : (k += 1) {
            switch (arg[k]) {
                'n' => sed.quiet = true,
                'E', 'r' => sed.extended = true,
                's' => sed.separate = true,
                'i' => {
                    sed.in_place = arg[k + 1 ..];
                    break;
                },
                'e', 'f' => {
                    const v = if (k + 1 < arg.len) arg[k + 1 ..] else blk: {
                        i += 1;
                        break :blk if (i < args.len) args[i] else return usage();
                    };
                    if (!addPiece(a, &pieces, v, arg[k] == 'f')) return 1;
                    have_script = true;
                    break;
                },
                else => {
                    errout.printf("sed: unknown option: -{c}\n", .{arg[k]});
                    return 1;
                },
            }
        }
    }
    if (!have_script) {
        if (operands.items.len == 0) return usage();
        pieces.appendSlice(a, operands.orderedRemove(0)) catch return outOfMemory();
    }
    sed.outs.append(a, .{}) catch return outOfMemory();
    sed.out = &sed.outs.items[0];
    var parser: Parser = .{ .sed = &sed, .s = pieces.items };
    parser.script() catch |err| return failed(err);
    sed.out = &sed.outs.items[0]; // outFile may have moved the list
    defer for (sed.outs.items) |*o| {
        o.flush();
        if (o.file) |f| f.close();
    };
    if (operands.items.len == 0) {
        if (sed.in_place != null) {
            errout.print("sed: no input files\n");
            return 1;
        }
        operands.append(a, "-") catch return outOfMemory();
    }
    if (sed.in_place != null) {
        for (operands.items) |name| {
            sed.editInPlace(name) catch |err| return failed(err);
            if (sed.quit) break;
        }
    } else if (sed.separate) {
        for (operands.items) |name| {
            sed.stream(&.{name}) catch |err| return failed(err);
            if (sed.quit) break;
        }
    } else sed.stream(operands.items) catch |err| return failed(err);
    return sed.status;
}

// The pieces are joined by newlines.
fn addPiece(a: Allocator, pieces: *List, value: []const u8, is_file: bool) bool {
    addPieceText(a, pieces, value, is_file) catch |err| {
        if (err == error.OutOfMemory) _ = outOfMemory();
        return false;
    };
    return true;
}

fn addPieceText(a: Allocator, pieces: *List, value: []const u8, is_file: bool) error{ OutOfMemory, CantOpen }!void {
    if (pieces.items.len > 0) try pieces.append(a, '\n');
    if (!is_file) return pieces.appendSlice(a, value);
    const f = zdos.open(value, .read) catch |err| {
        errout.printf("sed: couldn't open file {s}: {s}\n", .{ value, zdos.message(err) });
        return error.CantOpen;
    };
    defer f.close();
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = f.read(&buf) catch break;
        if (n == 0) break;
        try pieces.appendSlice(a, buf[0..n]);
    }
    // DOS line ends of a script file:
    var w: usize = 0;
    for (pieces.items) |c| {
        if (c == '\r') continue;
        pieces.items[w] = c;
        w += 1;
    }
    pieces.items.len = w;
    if (pieces.items.len > 0 and pieces.items[pieces.items.len - 1] == '\n') pieces.items.len -= 1;
}

fn failed(err: Error) u8 {
    return switch (err) {
        error.Script => 1,
        error.OutOfMemory => outOfMemory(),
        error.Interrupted => 130,
    };
}

fn usage() u8 {
    errout.print("usage: sed [-nEs] [-i[SUFFIX]] [-e SCRIPT]... [-f FILE]... [SCRIPT] [FILE...]\n");
    return 1;
}

fn outOfMemory() u8 {
    errout.print("sed: not enough memory\n");
    return 4;
}
