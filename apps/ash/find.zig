// find [PATH...] [EXPRESSION]
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const shell_mod = @import("shell.zig");
const expand = @import("expand.zig");
const text = @import("text.zig");

const Allocator = std.mem.Allocator;
const Shell = shell_mod.Shell;

const Expr = union(enum) {
    and_: [2]*Expr,
    or_: [2]*Expr,
    not: *Expr,
    name: []const u8,
    iname: []const u8,
    path: []const u8,
    type_dir: bool,
    inum: u64, // the file system's inode number (none on FAT)
    print,
    print0,
    prune,
    exec: struct { argv: []const []const u8, batch: bool },
    true_,
};

const Parse = struct {
    a: Allocator,
    args: []const []const u8,
    i: usize = 0,
    has_action: bool = false,
    max_depth: usize = std.math.maxInt(usize),
    min_depth: usize = 0,

    fn new(self: *Parse, e: Expr) error{ OutOfMemory, Bad }!*Expr {
        const p = try self.a.create(Expr);
        p.* = e;
        return p;
    }

    fn peek(self: *Parse) ?[]const u8 {
        return if (self.i < self.args.len) self.args[self.i] else null;
    }

    fn orExpr(self: *Parse) error{ OutOfMemory, Bad }!*Expr {
        var left = try self.andExpr();
        while (self.peek()) |w| {
            if (!std.mem.eql(u8, w, "-o") and !std.mem.eql(u8, w, "-or")) break;
            self.i += 1;
            left = try self.new(.{ .or_ = .{ left, try self.andExpr() } });
        }
        return left;
    }

    fn andExpr(self: *Parse) error{ OutOfMemory, Bad }!*Expr {
        var left = try self.notExpr();
        while (self.peek()) |w| {
            if (std.mem.eql(u8, w, "-o") or std.mem.eql(u8, w, "-or") or std.mem.eql(u8, w, ")")) break;
            if (std.mem.eql(u8, w, "-a") or std.mem.eql(u8, w, "-and")) self.i += 1;
            left = try self.new(.{ .and_ = .{ left, try self.notExpr() } });
        }
        return left;
    }

    fn notExpr(self: *Parse) error{ OutOfMemory, Bad }!*Expr {
        const w = self.peek() orelse return self.bad("expression expected");
        if (std.mem.eql(u8, w, "!") or std.mem.eql(u8, w, "-not")) {
            self.i += 1;
            return self.new(.{ .not = try self.notExpr() });
        }
        return self.primary();
    }

    fn operand(self: *Parse, option: []const u8) error{ OutOfMemory, Bad }![]const u8 {
        self.i += 1;
        const v = self.peek() orelse {
            errout.printf("find: {s} needs a value\n", .{option});
            return error.Bad;
        };
        self.i += 1;
        return v;
    }

    fn primary(self: *Parse) error{ OutOfMemory, Bad }!*Expr {
        const w = self.peek().?;
        if (std.mem.eql(u8, w, "(")) {
            self.i += 1;
            const e = try self.orExpr();
            const close = self.peek() orelse return self.bad("missing )");
            if (!std.mem.eql(u8, close, ")")) return self.bad("missing )");
            self.i += 1;
            return e;
        }
        if (std.mem.eql(u8, w, "-name")) return self.new(.{ .name = try self.operand(w) });
        if (std.mem.eql(u8, w, "-iname")) return self.new(.{ .iname = try self.operand(w) });
        if (std.mem.eql(u8, w, "-path") or std.mem.eql(u8, w, "-wholename")) return self.new(.{ .path = try self.operand(w) });
        if (std.mem.eql(u8, w, "-type")) {
            const t = try self.operand(w);
            if (!std.mem.eql(u8, t, "f") and !std.mem.eql(u8, t, "d")) return self.bad("-type takes f or d");
            return self.new(.{ .type_dir = t[0] == 'd' });
        }
        if (std.mem.eql(u8, w, "-inum")) {
            const n = std.fmt.parseInt(u64, try self.operand(w), 10) catch return self.bad("-inum takes an inode number");
            return self.new(.{ .inum = n });
        }
        if (std.mem.eql(u8, w, "-maxdepth") or std.mem.eql(u8, w, "-mindepth")) {
            const v = std.fmt.parseInt(usize, try self.operand(w), 10) catch return self.bad("a number is needed");
            if (w[2] == 'a') self.max_depth = v else self.min_depth = v;
            return self.new(.true_);
        }
        self.i += 1;
        if (std.mem.eql(u8, w, "-print")) {
            self.has_action = true;
            return self.new(.print);
        }
        if (std.mem.eql(u8, w, "-print0")) {
            self.has_action = true;
            return self.new(.print0);
        }
        if (std.mem.eql(u8, w, "-prune")) return self.new(.prune);
        if (std.mem.eql(u8, w, "-exec")) {
            const start = self.i;
            while (self.peek()) |x| : (self.i += 1) {
                if (std.mem.eql(u8, x, ";") or (std.mem.eql(u8, x, "+") and self.i > start and std.mem.eql(u8, self.args[self.i - 1], "{}"))) break;
            } else return self.bad("-exec needs ; or + at the end");
            const batch = std.mem.eql(u8, self.args[self.i], "+");
            const argv = self.args[start..self.i];
            self.i += 1;
            if (argv.len == 0) return self.bad("-exec needs a command");
            self.has_action = true;
            return self.new(.{ .exec = .{ .argv = argv, .batch = batch } });
        }
        errout.printf("find: unknown option: {s}\n", .{w});
        return error.Bad;
    }

    fn bad(self: *Parse, message: []const u8) error{Bad} {
        _ = self;
        errout.printf("find: {s}\n", .{message});
        return error.Bad;
    }
};

const Walk = struct {
    sh: *Shell,
    a: Allocator,
    expr: *Expr,
    max_depth: usize,
    min_depth: usize,
    out: text.Output = .{},
    failed: bool = false,
    batch: std.ArrayListUnmanaged([]const u8) = .{}, // -exec ... {} +
    batch_argv: ?[]const []const u8 = null,

    fn visit(self: *Walk, path: []const u8, is_dir: bool, depth: usize) void {
        if (self.sh.interrupted) return;
        var prune = false;
        if (depth >= self.min_depth) _ = self.eval(self.expr, path, is_dir, &prune);
        if (!is_dir or prune or depth >= self.max_depth) return;
        const dir = zdos.openDir(path) catch |err| {
            errout.printf("find: {s}: {s}\n", .{ path, zdos.message(err) });
            self.failed = true;
            return;
        };
        defer dir.close();
        var entry: zdos.DirEntry = undefined;
        while (dir.next(&entry) catch false) {
            const name = entry.name();
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const sep: []const u8 = if (std.mem.endsWith(u8, path, "/") or std.mem.endsWith(u8, path, "\\")) "" else "/";
            const child = std.fmt.allocPrint(self.a, "{s}{s}{s}", .{ path, sep, name }) catch {
                self.failed = true;
                return;
            };
            self.visit(child, entry.is_dir, depth + 1);
        }
    }

    fn eval(self: *Walk, e: *const Expr, path: []const u8, is_dir: bool, prune: *bool) bool {
        return switch (e.*) {
            .and_ => |p| self.eval(p[0], path, is_dir, prune) and self.eval(p[1], path, is_dir, prune),
            .or_ => |p| self.eval(p[0], path, is_dir, prune) or self.eval(p[1], path, is_dir, prune),
            .not => |x| !self.eval(x, path, is_dir, prune),
            .name => |pat| expand.matchPattern(pat, baseName(path), false),
            .iname => |pat| expand.matchPattern(pat, baseName(path), true),
            .path => |pat| expand.matchPattern(pat, path, false),
            .type_dir => |d| d == is_dir,
            .inum => |n| inodeOf(path) == n,
            .print => blk: {
                self.out.write(path);
                self.out.write("\n");
                break :blk true;
            },
            .print0 => blk: {
                self.out.write(path);
                self.out.write(&.{0});
                break :blk true;
            },
            .prune => blk: {
                prune.* = true;
                break :blk true;
            },
            .exec => |x| self.exec(x.argv, x.batch, path),
            .true_ => true,
        };
    }

    fn exec(self: *Walk, argv: []const []const u8, batch: bool, path: []const u8) bool {
        if (batch) {
            self.batch_argv = argv;
            self.batch.append(self.a, path) catch return false;
            if (self.batch.items.len >= 64) self.flushBatch();
            return true;
        }
        var list: std.ArrayListUnmanaged([]const u8) = .{};
        for (argv) |arg| {
            const replaced = std.mem.replaceOwned(u8, self.a, arg, "{}", path) catch return false;
            list.append(self.a, replaced) catch return false;
        }
        self.out.flush();
        return self.sh.runBuiltinOrProgram(self.a, list.items) == 0;
    }

    fn flushBatch(self: *Walk) void {
        const argv = self.batch_argv orelse return;
        if (self.batch.items.len == 0) return;
        var list: std.ArrayListUnmanaged([]const u8) = .{};
        for (argv[0 .. argv.len - 1]) |arg| list.append(self.a, arg) catch return;
        list.appendSlice(self.a, self.batch.items) catch return;
        self.out.flush();
        if (self.sh.runBuiltinOrProgram(self.a, list.items) != 0) self.failed = true;
        self.batch.clearRetainingCapacity();
    }
};

// null where the file system has none (FAT)
fn inodeOf(path: []const u8) ?u64 {
    const x = zdos.statEx(path) catch return null;
    return if (x.valid & zdos.StatValid.ino != 0) x.ino else null;
}

fn baseName(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    const start = if (std.mem.lastIndexOfAny(u8, path[0..end], "/\\")) |s| s + 1 else 0;
    return path[start..end];
}

pub fn run(sh: *Shell, args: []const []const u8) u8 {
    var arena = std.heap.ArenaAllocator.init(zdos.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var first_expr: usize = 0;
    while (first_expr < args.len) : (first_expr += 1) {
        const arg = args[first_expr];
        if ((arg.len > 1 and arg[0] == '-') or std.mem.eql(u8, arg, "(") or std.mem.eql(u8, arg, "!")) break;
    }
    const paths: []const []const u8 = if (first_expr == 0) &.{"."} else args[0..first_expr];
    var p: Parse = .{ .a = a, .args = args[first_expr..] };
    var expr = if (p.args.len == 0) (p.new(.true_) catch return shell_mod.outOfMemory()) else (p.orExpr() catch return 1);
    if (p.i != p.args.len) {
        errout.printf("find: unexpected {s}\n", .{p.args[p.i]});
        return 1;
    }
    if (!p.has_action) {
        const print = p.new(.print) catch return shell_mod.outOfMemory();
        expr = p.new(.{ .and_ = .{ expr, print } }) catch return shell_mod.outOfMemory();
    }
    var walk: Walk = .{ .sh = sh, .a = a, .expr = expr, .max_depth = p.max_depth, .min_depth = p.min_depth };
    defer walk.out.deinit();
    for (paths) |path| {
        const entry = zdos.stat(path) catch |err| {
            errout.printf("find: {s}: {s}\n", .{ path, zdos.message(err) });
            walk.failed = true;
            continue;
        };
        walk.visit(path, entry.is_dir or isRoot(path), 0);
    }
    walk.flushBatch();
    return if (walk.failed) 1 else 0;
}

fn isRoot(path: []const u8) bool {
    return path.len <= 4 and std.mem.indexOfScalar(u8, path, ':') != null;
}
