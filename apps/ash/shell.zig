// ash: the shell's state and the running of commands. Pipelines run as
// in DOS, one command after another through pipes in memory; subshells
// are saved and restored state. Exported variables are ZDOS variables.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");
const sys = @import("../zdos/system.zig");
const parser = @import("parser.zig");
const expand = @import("expand.zig");
const names = @import("names.zig");
const builtins = @import("builtins.zig");
const editor = @import("editor.zig");
const command_lookup = @import("command_lookup.zig");

const Allocator = std.mem.Allocator;
const Node = parser.Node;
const gpa = zdos.allocator;

pub const Var = struct {
    values: std.ArrayListUnmanaged([]const u8) = .{}, // element 0: the scalar value
    array: bool = false,
    exported: bool = false,

    fn deinit(self: *Var) void {
        for (self.values.items) |v| gpa.free(v);
        self.values.deinit(gpa);
    }

    fn clone(self: *const Var) Allocator.Error!Var {
        var copy: Var = .{ .array = self.array, .exported = self.exported };
        errdefer copy.deinit();
        try copy.values.ensureTotalCapacity(gpa, self.values.items.len);
        for (self.values.items) |v| copy.values.appendAssumeCapacity(try gpa.dupe(u8, v));
        return copy;
    }
};

const Flow = enum { none, break_, continue_, return_, exit_ };

pub const Options = struct {
    errexit: bool = false, // -e
    nounset: bool = false, // -u
    xtrace: bool = false, // -x
    noglob: bool = false, // -f
    pipefail: bool = false, // -o pipefail
};

const SavedLocal = struct { name: []const u8, old: ?Var };

const State = struct {
    vars: std.StringHashMapUnmanaged(Var),
    functions: std.StringHashMapUnmanaged(*Node),
    args: []const []const u8,
    opts: Options,
    cwd: []const u8,
    exit_trap: ?[]const u8,
    locals_len: usize,
    loop_depth: u32,
};

// reported: said so at a prompt.
const Finished = struct { id: u32, code: u8, signal: u8 = 0, reported: bool = true };

pub const Shell = struct {
    vars: std.StringHashMapUnmanaged(Var) = .{},
    functions: std.StringHashMapUnmanaged(*Node) = .{},
    // Kept until the shell ends:
    function_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa),
    args: []const []const u8 = &.{}, // $1 ...; owned
    zero: []const u8 = "ash",
    status: u8 = 0,
    flow: Flow = .none,
    flow_levels: u32 = 1, // break 2, continue 2
    exit_status: u8 = 0,
    interrupted: bool = false, // Ctrl+C: everything stops
    loop_depth: u32 = 0,
    function_depth: u32 = 0,
    opts: Options = .{},
    errexit_off: u32 = 0, // > 0 while running conditions, where -e doesn't apply
    interactive: bool = false,
    in_handle: i32 = sys.inherited,
    out_handle: i32 = sys.inherited,
    exit_trap: ?[]const u8 = null,
    locals: std.ArrayListUnmanaged(SavedLocal) = .{},
    local_base: usize = 0,
    substitution_status: ?u8 = null, // of the last $( ), for assignments alone
    // Tasks started with & ($! is the last), and those collected, with
    // their codes, for wait ID afterwards (POSIX: at least 25; here 64):
    last_background: ?u32 = null,
    background: std.ArrayListUnmanaged(u32) = .{},
    finished: [64]Finished = undefined,
    finished_count: usize = 0,
    finished_next: usize = 0,

    pub fn deinit(self: *Shell) void {
        var it = self.vars.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        self.vars.deinit(gpa);
        self.functions.deinit(gpa);
        self.function_arena.deinit();
        freeArgs(self.args);
        self.dropLocals(0);
        self.locals.deinit(gpa);
        if (self.exit_trap) |t| gpa.free(t);
    }

    // VARIABLES

    pub fn getVar(self: *Shell, name: []const u8) ?[]const u8 {
        const v = self.vars.getPtr(name) orelse return null;
        if (v.values.items.len == 0) return if (v.array) "" else null;
        return v.values.items[0];
    }

    fn slot(self: *Shell, name: []const u8) Allocator.Error!*Var {
        const entry = try self.vars.getOrPut(gpa, name);
        if (!entry.found_existing) {
            entry.key_ptr.* = gpa.dupe(u8, name) catch |err| {
                self.vars.removeByPtr(entry.key_ptr);
                return err;
            };
            entry.value_ptr.* = .{};
        }
        return entry.value_ptr;
    }

    pub fn setVar(self: *Shell, name: []const u8, value: []const u8) Allocator.Error!void {
        const owned = try gpa.dupe(u8, value);
        errdefer gpa.free(owned);
        const v = try self.slot(name);
        if (v.values.items.len == 0) {
            try v.values.append(gpa, owned);
        } else {
            gpa.free(v.values.items[0]);
            v.values.items[0] = owned;
        }
        if (v.exported) syncVar(name, value);
    }

    pub fn appendVar(self: *Shell, name: []const u8, value: []const u8) Allocator.Error!void {
        const old = self.getVar(name) orelse "";
        const joined = try std.mem.concat(gpa, u8, &.{ old, value });
        defer gpa.free(joined);
        try self.setVar(name, joined);
    }

    pub fn setArray(self: *Shell, name: []const u8, values: []const []const u8, append: bool) Allocator.Error!void {
        const v = try self.slot(name);
        if (!append) {
            for (v.values.items) |old| gpa.free(old);
            v.values.clearRetainingCapacity();
        }
        v.array = true;
        for (values) |value| {
            const owned = try gpa.dupe(u8, value);
            v.values.append(gpa, owned) catch |err| {
                gpa.free(owned);
                return err;
            };
        }
    }

    pub fn setElement(self: *Shell, name: []const u8, index: usize, value: []const u8) Allocator.Error!void {
        const v = try self.slot(name);
        v.array = true;
        while (v.values.items.len <= index) try v.values.append(gpa, try gpa.dupe(u8, ""));
        const owned = try gpa.dupe(u8, value);
        gpa.free(v.values.items[index]);
        v.values.items[index] = owned;
    }

    pub fn unsetVar(self: *Shell, name: []const u8) void {
        const entry = self.vars.fetchRemove(name) orelse return;
        var v = entry.value;
        if (v.exported) syncVar(name, "");
        gpa.free(entry.key);
        v.deinit();
    }

    pub fn exportVar(self: *Shell, name: []const u8) Allocator.Error!void {
        const v = try self.slot(name);
        v.exported = true;
        syncVar(name, if (v.values.items.len > 0) v.values.items[0] else "");
    }

    fn syncVar(name: []const u8, value: []const u8) void {
        zdos.setVar(name, value) catch |err| {
            // Not an admin: the shell keeps it as its own; programs it starts
            // don't see it:
            if (err == error.AccessDenied) return;
            errout.printf("ash: {s}: can't export ({s})\n", .{ name, zdos.message(err) });
        };
    }

    // As exported shell variables.
    pub fn importEnvironment(self: *Shell) void {
        var index: u32 = 0;
        var buf: [600]u8 = undefined;
        while (zdos.varAt(index, &buf)) |entry| : (index += 1) {
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (!parser.isName(entry[0..eq])) continue;
            const v = self.slot(entry[0..eq]) catch return;
            v.exported = true;
            const owned = gpa.dupe(u8, entry[eq + 1 ..]) catch return;
            for (v.values.items) |old| gpa.free(old);
            v.values.clearRetainingCapacity();
            v.values.append(gpa, owned) catch gpa.free(owned);
        }
    }

    // `local NAME`: saved now, put back when the function returns.
    pub fn makeLocal(self: *Shell, name: []const u8) Allocator.Error!void {
        for (self.locals.items[self.local_base..]) |l| {
            if (std.mem.eql(u8, l.name, name)) return;
        }
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        var old: ?Var = null;
        if (self.vars.getPtr(name)) |v| old = try v.clone();
        try self.locals.append(gpa, .{ .name = owned, .old = old });
    }

    fn restoreLocals(self: *Shell, base: usize) void {
        while (self.locals.items.len > base) {
            const l = self.locals.pop().?;
            const was_exported = if (self.vars.getPtr(l.name)) |v| v.exported else false;
            if (self.vars.fetchRemove(l.name)) |entry| {
                gpa.free(entry.key);
                var v = entry.value;
                v.deinit();
            }
            if (l.old) |old| {
                const entry = self.vars.getOrPut(gpa, l.name) catch {
                    var o = old;
                    o.deinit();
                    gpa.free(l.name);
                    continue;
                };
                entry.key_ptr.* = l.name;
                entry.value_ptr.* = old;
                if (old.exported) syncVar(l.name, if (old.values.items.len > 0) old.values.items[0] else "");
            } else {
                if (was_exported) syncVar(l.name, "");
                gpa.free(l.name);
            }
        }
    }

    fn dropLocals(self: *Shell, base: usize) void {
        while (self.locals.items.len > base) {
            var l = self.locals.pop().?;
            if (l.old) |*old| old.deinit();
            gpa.free(l.name);
        }
    }

    pub fn setArgs(self: *Shell, values: []const []const u8) Allocator.Error!void {
        const copy = try dupeArgs(values);
        freeArgs(self.args);
        self.args = copy;
    }

    pub fn optionLetters(self: *Shell, a: Allocator) Allocator.Error![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .{};
        if (self.opts.errexit) try out.append(a, 'e');
        if (self.opts.noglob) try out.append(a, 'f');
        if (self.interactive) try out.append(a, 'i');
        if (self.opts.nounset) try out.append(a, 'u');
        if (self.opts.xtrace) try out.append(a, 'x');
        return out.items;
    }

    // SUBSHELLS

    fn saveState(self: *Shell) Allocator.Error!State {
        var vars: std.StringHashMapUnmanaged(Var) = .{};
        errdefer freeVars(&vars);
        try vars.ensureTotalCapacity(gpa, self.vars.count());
        var it = self.vars.iterator();
        while (it.next()) |e| {
            const key = try gpa.dupe(u8, e.key_ptr.*);
            const v = e.value_ptr.clone() catch |err| {
                gpa.free(key);
                return err;
            };
            vars.putAssumeCapacity(key, v);
        }
        var functions = try self.functions.clone(gpa);
        errdefer functions.deinit(gpa);
        const args = try dupeArgs(self.args);
        errdefer freeArgs(args);
        var cwd_buf: [1100]u8 = undefined;
        const cwd = try gpa.dupe(u8, zdos.getCwd(&cwd_buf));
        errdefer gpa.free(cwd);
        const trap = if (self.exit_trap) |t| try gpa.dupe(u8, t) else null;
        return .{
            .vars = vars,
            .functions = functions,
            .args = args,
            .opts = self.opts,
            .cwd = cwd,
            .exit_trap = trap,
            .locals_len = self.locals.items.len,
            .loop_depth = self.loop_depth,
        };
    }

    fn restoreState(self: *Shell, state: *State) void {
        // Exported variables come back by themselves: ZDOS drops the scope:
        freeVars(&self.vars);
        self.vars = state.vars;
        self.functions.deinit(gpa);
        self.functions = state.functions;
        freeArgs(self.args);
        self.args = state.args;
        self.opts = state.opts;
        if (state.cwd.len > 0) zdos.setCwd(state.cwd) catch {};
        gpa.free(state.cwd);
        if (self.exit_trap) |t| gpa.free(t);
        self.exit_trap = state.exit_trap;
        self.dropLocals(state.locals_len);
        self.loop_depth = state.loop_depth;
    }

    // Or, when node is null, the text src.
    fn isolated(self: *Shell, node: ?*const Node, src: []const u8) u8 {
        var state = self.saveState() catch return outOfMemory();
        const pushed = if (sys.pushVars()) true else |_| false;
        // A subshell doesn't inherit the EXIT trap; one set inside runs at end:
        if (self.exit_trap) |t| gpa.free(t);
        self.exit_trap = null;
        var status: u8 = 0;
        if (node) |n| {
            status = self.exec(n);
        } else {
            status = self.runText(src, "");
        }
        if (self.flow == .exit_ and !self.interrupted) status = self.exit_status;
        if (!self.interrupted) {
            self.flow = .none;
            status = self.runExitTrap(status);
        }
        self.restoreState(&state);
        if (pushed) sys.popVars();
        return status;
    }

    pub fn subshell(self: *Shell, node: *const Node) u8 {
        return self.isolated(node, "");
    }

    // $(command): without the newlines at the end.
    pub fn commandSubstitution(self: *Shell, a: Allocator, src: []const u8) expand.Error![]const u8 {
        var out = try self.capture(a, src);
        while (out.len > 0 and out[out.len - 1] == '\n') out.len -= 1;
        return out;
    }

    pub fn capture(self: *Shell, a: Allocator, src: []const u8) Allocator.Error![]u8 {
        const pipe = sys.createPipe() catch return error.OutOfMemory;
        defer pipe.close();
        const old_out = self.out_handle;
        self.setOutput(pipe.handle);
        const status = self.isolated(null, src);
        self.setOutput(old_out);
        var out: std.ArrayListUnmanaged(u8) = .{};
        errdefer out.deinit(a);
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = pipe.read(&buf) catch 0;
            if (n == 0) break;
            try out.appendSlice(a, buf[0..n]);
        }
        self.substitution_status = status;
        self.status = status;
        return out.toOwnedSlice(a);
    }

    // For awk's print | "command" and system().
    pub fn runWithInput(self: *Shell, src: []const u8, input: ?[]const u8) u8 {
        if (input) |data| {
            const pipe = sys.createPipe() catch return outOfMemory();
            defer pipe.close();
            pipe.writeAll(data) catch return outOfMemory();
            const old_in = self.in_handle;
            self.setInput(pipe.handle);
            defer self.setInput(old_in);
            return self.isolated(null, src);
        }
        return self.isolated(null, src);
    }

    pub fn setInput(self: *Shell, handle: i32) void {
        sys.redirect(.input, handle) catch |err| printError("ash: input", err);
        self.in_handle = handle;
    }

    pub fn setOutput(self: *Shell, handle: i32) void {
        sys.redirect(.output, handle) catch |err| printError("ash: output", err);
        self.out_handle = handle;
        errout.output = handle;
    }

    // RUNNING COMMANDS

    fn checkInterrupt(self: *Shell) bool {
        if (self.interrupted) return true;
        if (!sys.ctrlCPressed(true)) return false;
        self.interrupted = true;
        self.flow = .exit_;
        self.exit_status = 130;
        self.status = 130;
        return true;
    }

    pub fn exec(self: *Shell, node: *const Node) u8 {
        if (self.flow != .none) return self.status;
        if (self.checkInterrupt()) return self.status;
        const status: u8 = switch (node.*) {
            .simple => |*s| self.execSimple(s),
            .pipeline => |p| self.execPipeline(p.commands, p.negate),
            .and_or => |n| blk: {
                var status: u8 = undefined;
                self.errexit_off += 1;
                status = self.exec(n.first);
                self.errexit_off -= 1;
                for (n.rest, 0..) |item, k| {
                    if (self.flow != .none) break;
                    if (item.or_ == (status == 0)) continue;
                    const last = k + 1 == n.rest.len;
                    if (!last) self.errexit_off += 1;
                    status = self.exec(item.node);
                    if (!last) self.errexit_off -= 1;
                }
                break :blk status;
            },
            .list => |items| blk: {
                var status: u8 = 0;
                for (items) |item| {
                    status = if (item.background) self.execBackground(item.node) else self.exec(item.node);
                    if (self.flow != .none) break;
                }
                break :blk status;
            },
            .subshell => |body| self.subshell(body),
            .group => |body| self.exec(body),
            .if_ => |n| self.execIf(n.branches, n.else_body),
            .loop => |n| self.execLoop(n.cond, n.body, n.until),
            .for_ => |n| self.execFor(n.name, n.words, n.body),
            .case_ => |n| self.execCase(n.word, n.items),
            .function => |f| self.defineFunction(f.name, f.body_src),
            .redirected => |r| blk: {
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();
                var saved: Redirected = .{};
                if (!self.redirect(arena.allocator(), r.redirs, &saved)) break :blk 1;
                break :blk self.restoreWith(&saved, self.exec(r.node));
            },
        };
        if (self.flow != .none and self.flow != .exit_) return self.status;
        self.status = status;
        // set -e: a failed command ends the shell, except in conditions:
        if (self.opts.errexit and status != 0 and self.errexit_off == 0 and self.flow == .none) {
            const counts = switch (node.*) {
                .simple, .subshell => true,
                .pipeline => |p| !p.negate,
                else => false,
            };
            if (counts) {
                self.flow = .exit_;
                self.exit_status = status;
            }
        }
        return status;
    }

    fn execIf(self: *Shell, branches: []const parser.Branch, else_body: ?*Node) u8 {
        for (branches) |br| {
            self.errexit_off += 1;
            const c = self.exec(br.cond);
            self.errexit_off -= 1;
            if (self.flow != .none) return self.status;
            if (c == 0) return self.exec(br.body);
        }
        if (else_body) |e| return self.exec(e);
        return 0;
    }

    // True if the loop should stop.
    fn loopStops(self: *Shell) bool {
        switch (self.flow) {
            .break_ => {
                if (self.flow_levels > 1) self.flow_levels -= 1 else self.flow = .none;
                return true;
            },
            .continue_ => {
                if (self.flow_levels > 1) {
                    self.flow_levels -= 1;
                    return true;
                }
                self.flow = .none;
                return false;
            },
            .none => return false,
            else => return true,
        }
    }

    fn execLoop(self: *Shell, cond: *const Node, body: *const Node, until: bool) u8 {
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        var status: u8 = 0;
        while (true) {
            self.errexit_off += 1;
            const c = self.exec(cond);
            self.errexit_off -= 1;
            if (self.flow != .none) {
                if (self.loopStops()) break;
                continue;
            }
            if ((c == 0) == until) break;
            status = self.exec(body);
            if (self.loopStops()) break;
        }
        return if (self.flow != .none) self.status else status;
    }

    fn execFor(self: *Shell, name: []const u8, words: ?[]const []const u8, body: *const Node) u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var values: std.ArrayListUnmanaged([]const u8) = .{};
        if (words) |ws| {
            for (ws) |w| expand.fields(self, a, w, &values) catch |err| return self.expandFailed(err);
        } else {
            for (self.args) |arg| values.append(a, a.dupe(u8, arg) catch return outOfMemory()) catch return outOfMemory();
        }
        self.loop_depth += 1;
        defer self.loop_depth -= 1;
        var status: u8 = 0;
        for (values.items) |value| {
            self.setVar(name, value) catch return outOfMemory();
            status = self.exec(body);
            if (self.loopStops()) break;
        }
        return if (self.flow != .none) self.status else status;
    }

    fn execCase(self: *Shell, word: []const u8, items: []const parser.CaseItem) u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const value = expand.string(self, a, word) catch |err| return self.expandFailed(err);
        for (items) |item| {
            for (item.patterns) |p| {
                const pat = expand.pattern(self, a, p) catch |err| return self.expandFailed(err);
                if (!expand.matchPattern(pat, value, false)) continue;
                return if (item.body) |b| self.exec(b) else 0;
            }
        }
        return 0;
    }

    fn defineFunction(self: *Shell, name: []const u8, body_src: []const u8) u8 {
        const a = self.function_arena.allocator();
        const src = a.dupe(u8, body_src) catch return outOfMemory();
        var p = parser.Parser.init(a, src);
        const node = (p.next() catch {
            errout.printf("ash: {s}: bad function body\n", .{name});
            return 2;
        }) orelse return 2;
        const key = a.dupe(u8, name) catch return outOfMemory();
        self.functions.put(gpa, key, node) catch return outOfMemory();
        return 0;
    }

    fn execPipeline(self: *Shell, commands: []const *Node, negate: bool) u8 {
        if (negate) self.errexit_off += 1;
        defer if (negate) {
            self.errexit_off -= 1;
        };
        var status: u8 = 0;
        if (commands.len == 1) {
            status = self.exec(commands[0]);
        } else if (self.execTaskPipeline(commands)) |s| {
            status = s;
        } else {
            var input: ?zdos.File = null;
            var failed: u8 = 0;
            for (commands, 0..) |command, k| {
                var output: ?zdos.File = null;
                if (k + 1 < commands.len) {
                    output = sys.createPipe() catch |err| {
                        printError("ash: pipe", err);
                        status = 1;
                        break;
                    };
                }
                const old_in = self.in_handle;
                const old_out = self.out_handle;
                if (input) |f| self.setInput(f.handle);
                if (output) |f| self.setOutput(f.handle);
                status = self.subshell(command);
                if (output != null) self.setOutput(old_out);
                if (input) |f| {
                    self.setInput(old_in);
                    f.close();
                }
                input = output;
                if (status != 0) failed = status;
                if (self.interrupted) break;
            }
            if (input) |f| f.close();
            if (self.opts.pipefail and failed != 0) status = failed;
        }
        if (negate and self.flow == .none) status = @intFromBool(status == 0);
        return status;
    }

    // TASKS

    // A program, its standard streams at most redirected to files;
    // NAME=value before it only where ZDOS gives tasks their own variables.
    const Spawnable = struct {
        argv: []const []const u8,
        in_file: ?[]const u8 = null,
        out_file: ?[]const u8 = null,
        append: bool = false,
        err: ErrTarget = .caller, // where standard error goes (fd 2)
        assigns: []const [2][]const u8 = &.{}, // for it alone
    };

    // A dup (2>&1) copies where the output goes at that point, as in any shell:
    // ">f 2>&1" sends both to f, "2>&1 >f" only the output.
    const ErrTarget = union(enum) {
        caller, // the default: where the shell's own errors go
        inherited_output, // 2>&1 before any > : the output the task would get
        with_output, // 2>&1 after > file: the same file as the output
        file: struct { name: []const u8, append: bool },
    };

    fn spawnable(self: *Shell, a: Allocator, node: *const Node) ?Spawnable {
        if (node.* != .simple) return null;
        const assigns = a.alloc([2][]const u8, node.simple.assigns.len) catch return null;
        for (node.simple.assigns, assigns) |*as, *kv| {
            if (as.index != null or as.array != null or as.append) return null;
            kv.* = .{ as.name, expand.string(self, a, as.value) catch return null };
        }
        if (assigns.len > 0 and !sys.spawnEnvWorks()) return null;
        var argv: std.ArrayListUnmanaged([]const u8) = .{};
        for (node.simple.words) |w| expand.fields(self, a, w, &argv) catch return null;
        if (argv.items.len == 0 or self.functions.get(argv.items[0]) != null or names.isBuiltin(argv.items[0])) return null;
        var sp: Spawnable = .{ .argv = argv.items, .assigns = assigns };
        // In order, each on the state the one before left, as redirect() in a
        // classic ash on the child's descriptors:
        var out_redirected = false;
        for (node.simple.redirs) |r| {
            if (r.heredoc != null) return null;
            var t: std.ArrayListUnmanaged([]const u8) = .{};
            expand.fields(self, a, r.target, &t) catch return null;
            if (t.items.len != 1) return null;
            const target = t.items[0];
            switch (r.op) {
                .input => {
                    if (r.fd != 0) return null;
                    sp.in_file = target;
                },
                .output, .append => switch (r.fd) {
                    1 => {
                        sp.out_file = target;
                        sp.append = r.op == .append;
                        out_redirected = true;
                    },
                    2 => sp.err = .{ .file = .{ .name = target, .append = r.op == .append } },
                    else => return null,
                },
                .dup_output => {
                    if (r.fd != 2) return null; // >&2 and the others: not as tasks
                    if (std.mem.eql(u8, target, "1")) {
                        sp.err = if (out_redirected) .with_output else .inherited_output;
                    } else if (std.mem.eql(u8, target, "-")) {
                        sp.err = .{ .file = .{ .name = "/dev/null", .append = false } };
                    } else return null;
                },
                else => return null,
            }
        }
        return sp;
    }

    // Its own files override these streams. Null if it can't be a task
    // here (not metal, not found ...): the caller reports the error.
    fn spawnTask(self: *Shell, a: Allocator, sp: Spawnable, input: i32, output: i32) zdos.Error!u32 {
        var in = input;
        var out = output;
        var files: [3]?zdos.File = .{ null, null, null };
        defer for (files) |f| if (f) |x| x.close();
        // NUL is a stream of its own (SpawnOptions.nul_stream), not a file:
        if (sp.in_file) |name| {
            if (isNull(name)) {
                in = sys.nul;
            } else {
                files[0] = try zdos.open(name, .read);
                in = files[0].?.handle;
            }
        }
        if (sp.out_file) |name| {
            if (isNull(name)) {
                out = sys.nul;
            } else {
                const f = try zdos.open(name, if (sp.append) .update else .write);
                if (sp.append) f.seek(zdos.seek_end) catch {};
                files[1] = f;
                out = f.handle;
            }
        }
        var err_handle: i32 = zdos.SpawnOptions.caller_error;
        switch (sp.err) {
            .caller => {},
            // Without a file of its own: the pipe it writes to, else the
            // caller's output (as errout.apply uses caller_output):
            .inherited_output => err_handle = if (output == zdos.SpawnOptions.same_stream) zdos.SpawnOptions.caller_output else output,
            .with_output => err_handle = out,
            .file => |f| if (isNull(f.name)) {
                err_handle = sys.nul;
            } else {
                const file = try zdos.open(f.name, if (f.append) .update else .write);
                if (f.append) file.seek(zdos.seek_end) catch {};
                files[2] = file;
                err_handle = file.handle;
            },
        }
        const packed_args = packArguments(a, sp.argv[1..]) catch return error.OutOfMemory;
        const opts: zdos.SpawnOptions = .{ .input = in, .output = out, .err = err_handle };
        // Non-admins can't make the exported variables global ones:
        const vars = self.envBlock(a, sp.assigns) catch return error.OutOfMemory;
        return sys.taskSpawnEnv(sp.argv[0], packed_args, opts, vars) catch |err| switch (err) {
            error.NotSupported => if (sp.assigns.len == 0) sys.taskSpawnWith(sp.argv[0], packed_args, opts) else err,
            else => err,
        };
    }

    // assigns, then the other exported variables, as a taskSpawnEnv block;
    // what ZDOS can't hold (empty, too long, over 48) is left out.
    fn envBlock(self: *Shell, a: Allocator, assigns: []const [2][]const u8) Allocator.Error![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .{};
        var count: usize = 0;
        for (assigns) |kv| try appendEnv(a, &out, &count, kv[0], kv[1]);
        var it = self.vars.iterator();
        next: while (it.next()) |e| {
            const v = e.value_ptr;
            if (!v.exported or v.array or v.values.items.len == 0) continue;
            for (assigns) |kv| if (std.mem.eql(u8, kv[0], e.key_ptr.*)) continue :next;
            try appendEnv(a, &out, &count, e.key_ptr.*, v.values.items[0]);
        }
        return out.items;
    }

    fn appendEnv(a: Allocator, out: *std.ArrayListUnmanaged(u8), count: *usize, name: []const u8, value: []const u8) Allocator.Error!void {
        if (count.* == 48 or name.len > 32 or value.len == 0 or value.len > 512) return;
        try out.appendSlice(a, name);
        try out.append(a, '=');
        try out.appendSlice(a, value);
        try out.append(a, 0);
        count.* += 1;
    }

    // A | B | C with B and C programs: B and C run as tasks beside A
    // (which may read the keyboard), joined by POSIX pipes.
    fn execTaskPipeline(self: *Shell, commands: []const *Node) ?u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const rest = a.alloc(Spawnable, commands.len - 1) catch return null;
        for (commands[1..], rest) |c, *sp| sp.* = self.spawnable(a, c) orelse return null;
        const ids = a.alloc(u32, rest.len) catch return null;
        var started: usize = 0;
        var first_out: i32 = -1;
        var input: i32 = -1; // the read end for the next task
        var status: u8 = 0;
        // From the last one back: each gets the pipe its writer will get:
        var i = rest.len;
        var next_in: i32 = zdos.SpawnOptions.same_stream;
        while (i > 0) {
            i -= 1;
            const p = sys.pipe() catch break;
            const id = self.spawnTask(a, rest[i], p.read, next_in) catch |err| {
                (zdos.File{ .handle = p.read }).close();
                (zdos.File{ .handle = p.write }).close();
                if (started == 0) return null; // nothing started: the old way
                errout.printf("ash: {s}: {s}\n", .{ rest[i].argv[0], zdos.message(err) });
                status = 127;
                break;
            };
            ids[i] = id;
            started += 1;
            (zdos.File{ .handle = p.read }).close();
            if (next_in != zdos.SpawnOptions.same_stream) (zdos.File{ .handle = next_in }).close();
            next_in = p.write;
        }
        input = next_in;
        if (status == 0 and started == rest.len) {
            // The first command here, its output into the first task:
            first_out = input;
            const old_out = self.out_handle;
            self.setOutput(first_out);
            const first = self.subshell(commands[0]);
            self.setOutput(old_out);
            if (first != 0 and self.opts.pipefail) status = first;
        }
        if (input != zdos.SpawnOptions.same_stream) (zdos.File{ .handle = input }).close();
        // Then the tasks: their codes, the last one's the pipeline's:
        var last: u8 = status;
        for (ids[rest.len - started ..]) |id| {
            if (self.interrupted) sys.signalSend(id, zdos.Signal.int) catch {};
            const code = sys.taskWait(id) catch 255;
            if (code != 0 and self.opts.pipefail) status = code;
            last = code;
        }
        return if (self.opts.pipefail and status != 0) status else last;
    }

    // COMMAND &: a program runs as a task where ZDOS has them;
    // $! is its number. Anything else runs in the foreground.
    fn execBackground(self: *Shell, node: *const Node) u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (self.spawnable(a, node)) |sp| {
            self.collectFinished(false); // codes kept before ZDOS's records may go
            // A classic ash gives a script's background
            // command no stdin (fd0_redirected); here the task
            // shares the shell's. sys.nul would do as POSIX
            // says, once pollKey on an empty input is checked:
            const input: i32 = zdos.SpawnOptions.same_stream;
            if (self.spawnTask(a, sp, input, zdos.SpawnOptions.same_stream)) |id| {
                self.last_background = id;
                self.background.append(gpa, id) catch {};
                if (self.interactive) errout.printf("[{d}]\n", .{id});
                return 0;
            } else |err| {
                if (err != error.NotSupported) {
                    errout.printf("ash: {s}: {s}\n", .{ sp.argv[0], zdos.message(err) });
                    return 127;
                }
            }
        }
        // Not a program, or a redirection a task can't have (a here-document,
        // >&2, a descriptor above 2): say so, a silent foreground run looks
        // like a hang:
        errout.print("ash: cannot run this in the background; running it in the foreground\n");
        self.last_background = null; // so $! isn't an older task's number
        return self.exec(node);
    }

    // wait [ID...]: also ones collected already; the last one's status,
    // 127 for an unknown one. Without IDs every & task, then 0.
    pub fn waitTasks(self: *Shell, ids: []const []const u8) u8 {
        if (ids.len == 0) {
            for (self.background.items) |id| {
                const code = sys.taskWait(id) catch continue;
                self.remember(.{ .id = id, .code = code });
            }
            self.background.clearRetainingCapacity();
            return 0;
        }
        var status: u8 = 0;
        for (ids) |word| {
            const id = std.fmt.parseInt(u32, word, 10) catch return 127;
            _ = self.forgetBackground(id);
            status = self.takeFinished(id) orelse (sys.taskWait(id) catch 127);
        }
        return status;
    }

    // ZDOS keeps only a few records. report: say so, as before a prompt.
    pub fn collectFinished(self: *Shell, report: bool) void {
        while (true) {
            const e = (sys.taskWaitAny(false) catch break) orelse break;
            if (!self.forgetBackground(e.id)) continue;
            self.remember(.{ .id = e.id, .code = e.code, .signal = e.signal, .reported = false });
        }
        if (!report) return;
        // Also those collected quietly meanwhile (before an &), oldest first:
        for (0..self.finished_count) |k| {
            const f = &self.finished[(self.finished_next + k) % self.finished_count];
            if (f.reported) continue;
            f.reported = true;
            if (f.signal != 0) {
                errout.printf("[{d}] Terminated by signal {d}\n", .{ f.id, f.signal });
            } else if (f.code == 0) {
                errout.printf("[{d}] Done\n", .{f.id});
            } else {
                errout.printf("[{d}] Exit {d}\n", .{ f.id, f.code });
            }
        }
    }

    // False if it wasn't there.
    fn forgetBackground(self: *Shell, id: u32) bool {
        for (self.background.items, 0..) |b, i| {
            if (b == id) {
                _ = self.background.swapRemove(i);
                return true;
            }
        }
        return false;
    }

    // In order: once all are used the oldest is at finished_next, and a new
    // one replaces it.
    fn remember(self: *Shell, f: Finished) void {
        if (self.finished_count < self.finished.len) {
            self.finished[self.finished_count] = f;
            self.finished_count += 1;
            return;
        }
        self.finished[self.finished_next] = f;
        self.finished_next = (self.finished_next + 1) % self.finished.len;
    }

    // The order of the others kept.
    fn takeFinished(self: *Shell, id: u32) ?u8 {
        const n = self.finished_count;
        for (0..n) |k| {
            const i = (self.finished_next + k) % n;
            if (self.finished[i].id != id) continue;
            const code = self.finished[i].code;
            // Close the gap: the ones after it
            // move up, oldest first again at 0:
            var rest: [64]Finished = undefined;
            var m: usize = 0;
            for (0..n) |j| {
                const at = (self.finished_next + j) % n;
                if (at == i) continue;
                rest[m] = self.finished[at];
                m += 1;
            }
            @memcpy(self.finished[0..m], rest[0..m]);
            self.finished_count = m;
            self.finished_next = 0;
            return code;
        }
        return null;
    }

    fn execSimple(self: *Shell, s: *const parser.Simple) u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        self.substitution_status = null;
        var argv: std.ArrayListUnmanaged([]const u8) = .{};
        for (s.words) |w| expand.fields(self, a, w, &argv) catch |err| return self.expandFailed(err);

        if (argv.items.len == 0) {
            // Assignments and redirections alone:
            var saved: Redirected = .{};
            if (!self.redirect(a, s.redirs, &saved)) return 1;
            if (!self.restore(&saved)) return 1;
            for (s.assigns) |*item| {
                self.assign(a, item) catch |err| return self.expandFailed(err);
            }
            if (self.opts.xtrace and s.assigns.len > 0) self.trace(a, s.assigns, &.{});
            return self.substitution_status orelse 0;
        }
        if (self.opts.xtrace) self.trace(a, s.assigns, argv.items);

        // exec with only redirections: they stay:
        if (std.mem.eql(u8, argv.items[0], "exec") and argv.items.len == 1) {
            var saved: Redirected = .{};
            if (!self.redirect(a, s.redirs, &saved)) return 1;
            return 0;
        }
        var saved: Redirected = .{};
        if (!self.redirect(a, s.redirs, &saved)) return 1;
        if (s.assigns.len == 0) return self.restoreWith(&saved, self.runCommand(a, argv.items));
        if (builtins.isSpecial(argv.items[0])) {
            for (s.assigns) |*item| self.assign(a, item) catch |err| {
                _ = self.restore(&saved);
                return self.expandFailed(err);
            };
            return self.restoreWith(&saved, self.runCommand(a, argv.items));
        }
        return self.restoreWith(&saved, self.withTemporaryVars(a, s.assigns, argv.items));
    }

    // NAME=value command: only for the command, and exported.
    fn withTemporaryVars(self: *Shell, a: Allocator, assigns: []const parser.Assign, argv: []const []const u8) u8 {
        const pushed = if (sys.pushVars()) true else |_| false;
        defer if (pushed) sys.popVars();
        const base = self.locals.items.len;
        for (assigns) |*item| {
            self.makeLocalAlways(item.name) catch return outOfMemory();
            self.assign(a, item) catch |err| {
                self.restoreLocals(base);
                return self.expandFailed(err);
            };
            if (self.vars.getPtr(item.name)) |v| {
                v.exported = true;
                syncVar(item.name, if (v.values.items.len > 0) v.values.items[0] else "");
            }
        }
        const status = self.runCommand(a, argv);
        // Put the old values back without touching ZDOS (popVars does that):
        while (self.locals.items.len > base) {
            const l = self.locals.pop().?;
            if (self.vars.fetchRemove(l.name)) |entry| {
                gpa.free(entry.key);
                var v = entry.value;
                v.deinit();
            }
            if (l.old) |old| {
                self.vars.put(gpa, l.name, old) catch {
                    var o = old;
                    o.deinit();
                    gpa.free(l.name);
                };
            } else gpa.free(l.name);
        }
        return status;
    }

    fn makeLocalAlways(self: *Shell, name: []const u8) Allocator.Error!void {
        const owned = try gpa.dupe(u8, name);
        errdefer gpa.free(owned);
        var old: ?Var = null;
        if (self.vars.getPtr(name)) |v| old = try v.clone();
        try self.locals.append(gpa, .{ .name = owned, .old = old });
    }

    pub fn assign(self: *Shell, a: Allocator, assign_: *const parser.Assign) expand.Error!void {
        if (assign_.array) |words| {
            var values: std.ArrayListUnmanaged([]const u8) = .{};
            for (words) |w| try expand.fields(self, a, w, &values);
            return self.setArray(assign_.name, values.items, assign_.append);
        }
        const value = try expand.string(self, a, assign_.value);
        if (assign_.index) |index| {
            const k = try expand.arithmetic(self, a, index);
            if (k < 0) return error.BadSubstitution;
            const i: usize = @intCast(k);
            if (assign_.append) {
                const old = if (self.vars.getPtr(assign_.name)) |v| (if (i < v.values.items.len) v.values.items[i] else "") else "";
                return self.setElement(assign_.name, i, try std.mem.concat(a, u8, &.{ old, value }));
            }
            return self.setElement(assign_.name, i, value);
        }
        if (assign_.append) return self.appendVar(assign_.name, value);
        return self.setVar(assign_.name, value);
    }

    fn trace(self: *Shell, a: Allocator, assigns: []const parser.Assign, argv: []const []const u8) void {
        _ = self;
        var out: std.ArrayListUnmanaged(u8) = .{};
        out.appendSlice(a, "+") catch return;
        for (assigns) |as| {
            out.append(a, ' ') catch return;
            out.appendSlice(a, as.name) catch return;
            out.append(a, '=') catch return;
            out.appendSlice(a, as.value) catch return;
        }
        for (argv) |arg| {
            out.append(a, ' ') catch return;
            out.appendSlice(a, arg) catch return;
        }
        out.append(a, '\n') catch return;
        errout.print(out.items);
    }

    pub fn expandFailed(self: *Shell, err: expand.Error) u8 {
        const status: u8 = switch (err) {
            error.OutOfMemory => return outOfMemory(),
            error.BadSubstitution => blk: {
                errout.print("ash: bad substitution\n");
                break :blk 2;
            },
            error.Unset, error.Arithmetic => 1,
        };
        // An expansion error ends a script:
        if (!self.interactive) {
            self.flow = .exit_;
            self.exit_status = status;
        }
        return status;
    }

    pub fn runCommand(self: *Shell, a: Allocator, argv: []const []const u8) u8 {
        if (self.functions.get(argv[0])) |body| return self.callFunction(body, argv);
        return self.runBuiltinOrProgram(a, argv);
    }

    pub fn runBuiltinOrProgram(self: *Shell, a: Allocator, argv: []const []const u8) u8 {
        if (builtins.run(self, a, argv)) |status| return status;
        return self.runProgram(a, argv);
    }

    fn callFunction(self: *Shell, body: *const Node, argv: []const []const u8) u8 {
        if (self.function_depth >= 200) {
            errout.print("ash: functions nested too deeply\n");
            return 2;
        }
        const new_args = dupeArgs(argv[1..]) catch return outOfMemory();
        const old_args = self.args;
        self.args = new_args;
        const old_base = self.local_base;
        self.local_base = self.locals.items.len;
        const old_loop = self.loop_depth;
        self.loop_depth = 0;
        self.function_depth += 1;
        var status = self.exec(body);
        if (self.flow == .return_) {
            self.flow = .none;
            status = self.status;
        }
        self.function_depth -= 1;
        self.loop_depth = old_loop;
        self.restoreLocals(self.local_base);
        self.local_base = old_base;
        freeArgs(self.args);
        self.args = old_args;
        return status;
    }

    // PROGRAMS AND SCRIPTS

    fn runProgram(self: *Shell, a: Allocator, argv: []const []const u8) u8 {
        const name = argv[0];
        const before = environment(a);
        const packed_args = packArguments(a, argv[1..]) catch return outOfMemory();
        if (zdos.exec(name, packed_args)) |code| {
            self.importChanges(a, before);
            return code;
        } else |err| switch (err) {
            error.NotFound, error.PathNotFound, error.NotSupported, error.InvalidName => {
                if (self.findScript(a, name)) |path| return self.runScript(a, path, argv[1..]);
                if (err == error.NotSupported) {
                    errout.printf("ash: {s}: not a program\n", .{name});
                    return 126;
                }
                errout.printf("ash: {s}: not found\n", .{name});
                return 127;
            },
            else => {
                errout.printf("ash: {s}: {s}\n", .{ name, zdos.message(err) });
                return 126;
            },
        }
    }

    // A program may set ZDOS variables (for batch files): take them over.
    fn importChanges(self: *Shell, a: Allocator, before: []const []const u8) void {
        const after = environment(a);
        outer: for (after) |entry| {
            for (before) |old| if (std.mem.eql(u8, old, entry)) continue :outer;
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            if (!parser.isName(entry[0..eq])) continue;
            const v = self.slot(entry[0..eq]) catch return;
            v.exported = true;
            const owned = gpa.dupe(u8, entry[eq + 1 ..]) catch return;
            for (v.values.items) |old| gpa.free(old);
            v.values.clearRetainingCapacity();
            v.values.append(gpa, owned) catch gpa.free(owned);
        }
    }

    // A path to it, or found in the current folder or PATH (NAME.sh or a
    // file without extension).
    fn findScript(self: *Shell, a: Allocator, name: []const u8) ?[]const u8 {
        _ = self;
        if (std.mem.indexOfAny(u8, name, "/\\:") != null) {
            if (isFile(name)) return name;
            const with_sh = std.fmt.allocPrint(a, "{s}.sh", .{name}) catch return null;
            return if (isFile(with_sh)) with_sh else null;
        }
        const matches = command_lookup.find(a, name) catch return null;
        for (matches) |path| {
            const base = path[if (std.mem.lastIndexOfAny(u8, path, "/\\")) |s| s + 1 else 0..];
            const dot = std.mem.lastIndexOfScalar(u8, base, '.');
            if (dot == null or std.ascii.eqlIgnoreCase(base[dot.?..], ".sh")) return path;
        }
        return null;
    }

    pub fn runScript(self: *Shell, a: Allocator, path: []const u8, args: []const []const u8) u8 {
        const text = readScript(path) orelse return 127;
        defer gpa.free(text);
        if (std.mem.startsWith(u8, text, "#!")) {
            const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
            var words: std.ArrayListUnmanaged([]const u8) = .{};
            var it = std.mem.tokenizeAny(u8, text[2..line_end], " \t\r");
            while (it.next()) |w| words.append(a, w) catch return outOfMemory();
            // #!/usr/bin/env bash:
            if (words.items.len > 1 and isInterpreter(words.items[0], "env")) _ = words.orderedRemove(0);
            if (words.items.len > 0 and !isShell(words.items[0])) {
                var all: std.ArrayListUnmanaged([]const u8) = .{};
                all.appendSlice(a, words.items[1..]) catch return outOfMemory();
                all.append(a, path) catch return outOfMemory();
                all.appendSlice(a, args) catch return outOfMemory();
                const packed_args = packArguments(a, all.items) catch return outOfMemory();
                return zdos.exec(words.items[0], packed_args) catch |err| {
                    errout.printf("ash: {s}: {s}: {s}\n", .{ path, words.items[0], zdos.message(err) });
                    return 127;
                };
            }
        }
        return self.runChild(path, text, args);
    }

    // As a separate shell: only exported variables reach it, and nothing
    // it sets comes back.
    fn runChild(self: *Shell, path: []const u8, text: []const u8, args: []const []const u8) u8 {
        const pushed = if (sys.pushVars()) true else |_| false;
        defer if (pushed) sys.popVars();
        var child: Shell = .{ .in_handle = self.in_handle, .out_handle = self.out_handle };
        defer child.deinit();
        child.importEnvironment();
        child.zero = path;
        child.setArgs(args) catch return outOfMemory();
        const status = child.runMain(text, path);
        if (child.interrupted) {
            self.interrupted = true;
            self.flow = .exit_;
            self.exit_status = 130;
        }
        return status;
    }

    // As the shell's whole work, a script or -c text: then the EXIT trap.
    pub fn runMain(self: *Shell, text: []const u8, name: []const u8) u8 {
        var status = self.runText(text, name);
        if (self.flow == .exit_) status = self.exit_status;
        self.flow = .none;
        return self.runExitTrap(status);
    }

    pub fn runExitTrap(self: *Shell, status: u8) u8 {
        const trap = self.exit_trap orelse return status;
        self.exit_trap = null;
        defer gpa.free(trap);
        self.status = status;
        self.flow = .none;
        _ = self.runText(trap, "trap");
        if (self.flow == .exit_) {
            self.flow = .none;
            return self.exit_status;
        }
        return status;
    }

    // One complete command at a time.
    pub fn runText(self: *Shell, text: []const u8, name: []const u8) u8 {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var p = parser.Parser.init(arena.allocator(), text);
        while (true) {
            const node = p.next() catch |err| {
                reportSyntax(&p, err, name);
                self.status = 2;
                if (!self.interactive) {
                    self.flow = .exit_;
                    self.exit_status = 2;
                }
                break;
            } orelse break;
            _ = self.exec(node);
            if (self.flow != .none) break;
        }
        return self.status;
    }

    // REDIRECTIONS

    const Redirected = struct {
        in: ?i32 = null, // the handles before, if changed
        out: ?i32 = null,
        err_changed: bool = false,
        err: ?i32 = null,
        files: [8]zdos.File = undefined,
        count: usize = 0,
    };

    fn redirect(self: *Shell, a: Allocator, redirs: []const parser.Redir, saved: *Redirected) bool {
        for (redirs) |r| {
            if (!self.redirectOne(a, r, saved)) {
                _ = self.restore(saved);
                return false;
            }
        }
        return true;
    }

    fn keep(saved: *Redirected, file: zdos.File) bool {
        if (saved.count == saved.files.len) {
            errout.print("ash: too many redirections\n");
            file.close();
            return false;
        }
        saved.files[saved.count] = file;
        saved.count += 1;
        return true;
    }

    fn changeInput(self: *Shell, saved: *Redirected, handle: i32) void {
        if (saved.in == null) saved.in = self.in_handle;
        self.setInput(handle);
    }

    fn changeOutput(self: *Shell, saved: *Redirected, handle: i32) void {
        if (saved.out == null) saved.out = self.out_handle;
        self.setOutput(handle);
    }

    // null: error messages go where the output goes.
    fn changeErrors(saved: *Redirected, target: ?i32) void {
        if (!saved.err_changed) {
            saved.err_changed = true;
            saved.err = errout.target;
        }
        errout.target = target;
        errout.apply();
    }

    fn redirectOne(self: *Shell, a: Allocator, r: parser.Redir, saved: *Redirected) bool {
        if (r.op == .heredoc) {
            const doc = r.heredoc.?;
            const text = if (doc.expand) expand.heredoc(self, a, doc.body) catch |err| {
                _ = self.expandFailed(err);
                return false;
            } else doc.body;
            const pipe = sys.createPipe() catch |err| {
                printError("ash: here-document", err);
                return false;
            };
            if (!keep(saved, pipe)) return false;
            pipe.writeAll(text) catch {};
            if (r.fd == 0) self.changeInput(saved, pipe.handle);
            return true;
        }
        const target = expand.string(self, a, r.target) catch |err| {
            _ = self.expandFailed(err);
            return false;
        };
        if (r.op == .herestring) {
            const pipe = sys.createPipe() catch |err| {
                printError("ash: here-string", err);
                return false;
            };
            if (!keep(saved, pipe)) return false;
            pipe.writeAll(target) catch {};
            pipe.writeAll("\n") catch {};
            if (r.fd == 0) self.changeInput(saved, pipe.handle);
            return true;
        }
        switch (r.op) {
            .dup_output => {
                if (r.fd == 1 and std.mem.eql(u8, target, "2")) {
                    // >&2: the output goes where error messages go:
                    self.changeOutput(saved, zdos.SpawnOptions.caller_error);
                } else if (r.fd == 2 and std.mem.eql(u8, target, "1")) {
                    changeErrors(saved, null);
                } else if (r.fd == 2 and std.mem.eql(u8, target, "-")) {
                    changeErrors(saved, sys.nul);
                }
                return true;
            },
            .dup_input => return true,
            .input, .read_write => {
                if (r.fd != 0) return true;
                if (isNull(target)) {
                    self.changeInput(saved, sys.nul);
                    return true;
                }
                const file = zdos.open(target, if (r.op == .input) .read else .update) catch |err| {
                    errout.printf("ash: {s}: {s}\n", .{ target, zdos.message(err) });
                    return false;
                };
                if (!keep(saved, file)) return false;
                self.changeInput(saved, file.handle);
                return true;
            },
            .output, .append => {
                if (r.fd != 1 and r.fd != 2) return true;
                const errors = r.fd == 2;
                if (isNull(target)) {
                    if (errors) changeErrors(saved, sys.nul) else self.changeOutput(saved, sys.nul);
                    return true;
                }
                if (std.mem.eql(u8, target, "/dev/stdout")) {
                    if (errors) changeErrors(saved, null);
                    return true;
                }
                if (std.mem.eql(u8, target, "/dev/stderr") or std.mem.eql(u8, target, "/dev/tty")) {
                    if (!errors) self.changeOutput(saved, sys.console);
                    return true;
                }
                const file = zdos.open(target, if (r.op == .append) .update else .write) catch |err| {
                    errout.printf("ash: {s}: {s}\n", .{ target, zdos.message(err) });
                    return false;
                };
                if (!keep(saved, file)) return false;
                if (r.op == .append) file.seek(zdos.seek_end) catch {};
                if (errors) changeErrors(saved, file.handle) else self.changeOutput(saved, file.handle);
                return true;
            },
            .heredoc, .herestring => unreachable,
        }
    }

    // False if a file failed to close: ZDOS reports there what writing to
    // it refused (a full disk, a file at its size limit).
    fn restore(self: *Shell, saved: *Redirected) bool {
        if (saved.err_changed) {
            errout.target = saved.err;
            errout.apply();
        }
        saved.err_changed = false;
        if (saved.out) |h| self.setOutput(h);
        if (saved.in) |h| self.setInput(h);
        saved.out = null;
        saved.in = null;
        var ok = true;
        for (saved.files[0..saved.count]) |f| {
            f.closeChecked() catch |err| {
                printError("ash", err);
                ok = false;
            };
        }
        saved.count = 0;
        return ok;
    }

    // Or 1 if it succeeded but its output couldn't be written.
    fn restoreWith(self: *Shell, saved: *Redirected, status: u8) u8 {
        return if (self.restore(saved) or status != 0) status else 1;
    }
};

fn freeVars(vars: *std.StringHashMapUnmanaged(Var)) void {
    var it = vars.iterator();
    while (it.next()) |e| {
        gpa.free(e.key_ptr.*);
        e.value_ptr.deinit();
    }
    vars.deinit(gpa);
}

fn dupeArgs(values: []const []const u8) Allocator.Error![]const []const u8 {
    const list = try gpa.alloc([]const u8, values.len);
    var done: usize = 0;
    errdefer {
        for (list[0..done]) |v| gpa.free(v);
        gpa.free(list);
    }
    for (values) |v| {
        list[done] = try gpa.dupe(u8, v);
        done += 1;
    }
    return list;
}

fn freeArgs(args: []const []const u8) void {
    for (args) |v| gpa.free(v);
    if (args.len > 0) gpa.free(args);
}

fn environment(a: Allocator) []const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .{};
    var index: u32 = 0;
    var buf: [600]u8 = undefined;
    while (zdos.varAt(index, &buf)) |entry| : (index += 1) {
        list.append(a, a.dupe(u8, entry) catch break) catch break;
    }
    return list.items;
}

fn isFile(path: []const u8) bool {
    const entry = zdos.stat(path) catch return false;
    return !entry.is_dir;
}

fn isNull(path: []const u8) bool {
    if (std.mem.eql(u8, path, "/dev/null")) return true;
    const name = path[if (std.mem.lastIndexOfAny(u8, path, "/\\")) |s| s + 1 else 0..];
    return std.ascii.eqlIgnoreCase(name, "NUL") or std.ascii.eqlIgnoreCase(name, "NUL:");
}

fn isInterpreter(path: []const u8, name: []const u8) bool {
    var base = path[if (std.mem.lastIndexOfAny(u8, path, "/\\")) |s| s + 1 else 0..];
    if (base.len > 4 and std.ascii.eqlIgnoreCase(base[base.len - 4 ..], ".app")) base = base[0 .. base.len - 4];
    return std.ascii.eqlIgnoreCase(base, name);
}

// Scripts for these shells run in ash.
fn isShell(path: []const u8) bool {
    return isInterpreter(path, "ash") or isInterpreter(path, "sh") or isInterpreter(path, "bash") or isInterpreter(path, "dash");
}

// DOS line ends made Unix ones.
pub fn readScript(path: []const u8) ?[]u8 {
    const file = zdos.open(path, .read) catch |err| {
        errout.printf("ash: {s}: {s}\n", .{ path, zdos.message(err) });
        return null;
    };
    defer file.close();
    var text: std.ArrayListUnmanaged(u8) = .{};
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = file.read(&buf) catch |err| {
            errout.printf("ash: {s}: {s}\n", .{ path, zdos.message(err) });
            text.deinit(gpa);
            return null;
        };
        if (n == 0) break;
        text.appendSlice(gpa, buf[0..n]) catch {
            _ = outOfMemory();
            text.deinit(gpa);
            return null;
        };
    }
    removeCarriageReturns(&text);
    return text.toOwnedSlice(gpa) catch null;
}

fn removeCarriageReturns(text: *std.ArrayListUnmanaged(u8)) void {
    var n: usize = 0;
    for (text.items, 0..) |c, i| {
        if (c == '\r' and i + 1 < text.items.len and text.items[i + 1] == '\n') continue;
        text.items[n] = c;
        n += 1;
    }
    text.items.len = n;
}

fn reportSyntax(p: *const parser.Parser, err: parser.Error, name: []const u8) void {
    // name: the script; empty for typed commands:
    var where_buf: [300]u8 = undefined;
    const where = if (name.len == 0) "" else std.fmt.bufPrint(&where_buf, "{s}: line {d}: ", .{ name, p.lineAt(p.error_pos) }) catch "";
    switch (err) {
        error.OutOfMemory => _ = outOfMemory(),
        error.Incomplete => errout.printf("ash: {s}syntax error: unexpected end of file\n", .{if (name.len == 0) "" else where_buf[0 .. name.len + 2]}),
        error.Syntax => errout.printf("ash: {s}syntax error: {s} '{s}'\n", .{ where, p.message, p.errorText() }),
    }
}

// Plain words as they are, so programs that split at spaces
// get what was typed; quotes only around empty words and
// ones with blanks or quotes. The one escape is \" (as
// zdos_crt0.c and splitArgs read it); trailing backslashes
// go after the closing quote.
pub fn packArguments(a: Allocator, args: []const []const u8) Allocator.Error![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    for (args, 0..) |arg, index| {
        if (index > 0) try result.append(a, ' ');
        if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\r\n\"'") == null) {
            try result.appendSlice(a, arg);
            continue;
        }
        const body = std.mem.trimRight(u8, arg, "\\");
        try result.append(a, '"');
        for (body) |c| {
            if (c == '"') try result.append(a, '\\');
            try result.append(a, c);
        }
        try result.append(a, '"');
        try result.appendSlice(a, arg[body.len..]);
    }
    return result.items;
}

pub fn printError(context: []const u8, err: zdos.Error) void {
    errout.printf("{s}: {s}\n", .{ context, zdos.message(err) });
}

pub fn outOfMemory() u8 {
    errout.print("ash: not enough memory\n");
    return 1;
}

// Split as ZDOS passes them: words, "..." with \", '...'.
fn splitArgs(a: Allocator, text: []const u8) Allocator.Error![]const []const u8 {
    var args: std.ArrayListUnmanaged([]const u8) = .{};
    var i: usize = 0;
    while (true) {
        while (i < text.len and std.ascii.isWhitespace(text[i])) i += 1;
        if (i >= text.len) break;
        var word: std.ArrayListUnmanaged(u8) = .{};
        var quote: u8 = 0;
        while (i < text.len) : (i += 1) {
            const c = text[i];
            if (quote == 0 and std.ascii.isWhitespace(c)) break;
            if (quote == 0 and (c == '"' or c == '\'')) {
                quote = c;
            } else if (c == quote) {
                quote = 0;
            } else if (c == '\\' and quote != '\'' and i + 1 < text.len and text[i + 1] == '"') {
                i += 1;
                try word.append(a, text[i]);
            } else {
                try word.append(a, c);
            }
        }
        try args.append(a, word.items);
    }
    return args.items;
}

pub fn run(arg_text: []const u8) u8 {
    sys.catchCtrlC(true);
    var sh: Shell = .{};
    defer sh.deinit();
    sh.importEnvironment();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var args = splitArgs(a, arg_text) catch return outOfMemory();
    while (args.len > 0 and args[0].len > 1 and args[0][0] == '-' and !std.mem.eql(u8, args[0], "-c") and !std.mem.eql(u8, args[0], "-s")) {
        if (builtins.setOptions(&sh, args[0], if (args.len > 1) args[1] else null)) |used| {
            args = args[used..];
        } else return 2;
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "-c")) {
        if (args.len < 2) {
            errout.print("ash: -c: a command is needed\n");
            return 2;
        }
        if (args.len > 2) {
            sh.zero = args[2];
            sh.setArgs(args[3..]) catch return outOfMemory();
        }
        return sh.runMain(args[1], "");
    }
    if (args.len > 0 and std.mem.eql(u8, args[0], "-s")) {
        sh.setArgs(args[1..]) catch return outOfMemory();
        var text: std.ArrayListUnmanaged(u8) = .{};
        var buf: [1024]u8 = undefined;
        while (true) {
            const n = zdos.readInput(&buf);
            if (n == 0) break;
            text.appendSlice(a, buf[0..n]) catch return outOfMemory();
        }
        removeCarriageReturns(&text);
        return sh.runMain(text.items, "");
    }
    if (args.len > 0) {
        const text = readScript(args[0]) orelse return 127;
        defer gpa.free(text);
        sh.zero = args[0];
        sh.setArgs(args[1..]) catch return outOfMemory();
        return sh.runMain(text, args[0]);
    }
    return interactive(&sh);
}

fn interactive(sh: *Shell) u8 {
    sh.interactive = true;
    runStartupScript(sh);
    var buffer: [editor.max_line]u8 = undefined;
    var pending: std.ArrayListUnmanaged(u8) = .{};
    defer pending.deinit(gpa);
    zdos.print("ash for ZDOS (POSIX subset); help lists the built-in commands\n");
    while (sh.flow != .exit_ or sh.interrupted) {
        sh.flow = .none;
        sh.interrupted = false;
        _ = sys.ctrlCPressed(true);
        if (pending.items.len > 0) {
            printPrompt(sh, sh.getVar("PS2") orelse "> ");
        } else {
            sh.collectFinished(true);
            printPrompt(sh, sh.getVar("PS1") orelse "\\w\\$ ");
        }
        const line = editor.readLine(&buffer) orelse {
            if (pending.items.len == 0) break;
            pending.clearRetainingCapacity();
            continue;
        };
        if (line.len == 0 and pending.items.len > 0 and sys.ctrlCPressed(false)) {
            pending.clearRetainingCapacity();
            continue;
        }
        pending.appendSlice(gpa, line) catch {
            _ = outOfMemory();
            pending.clearRetainingCapacity();
            continue;
        };
        pending.append(gpa, '\n') catch {};
        // Parse everything first: an unfinished command asks for more lines:
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var p = parser.Parser.init(arena.allocator(), pending.items);
        var nodes: std.ArrayListUnmanaged(*Node) = .{};
        var complete = true;
        while (true) {
            const node = p.next() catch |err| {
                if (err == error.Incomplete) {
                    complete = false;
                } else {
                    reportSyntax(&p, err, "");
                    sh.status = 2;
                    nodes.clearRetainingCapacity();
                }
                break;
            } orelse break;
            nodes.append(arena.allocator(), node) catch break;
        }
        if (!complete) continue;
        for (nodes.items) |node| {
            _ = sh.exec(node);
            if (sh.flow == .exit_) break;
            sh.flow = .none;
        }
        pending.clearRetainingCapacity();
        if (sh.interrupted) {
            sh.status = 130;
            continue;
        }
    }
    const status = if (sh.flow == .exit_) sh.exit_status else sh.status;
    return sh.runExitTrap(status);
}

// Root: $ENV, or SCRIPTS\ashrc.sh beside the APPS folder ash is in.
// Other users: ashrc.sh in their HOME, if there is one.
fn runStartupScript(sh: *Shell) void {
    var path_buf: [600]u8 = undefined;
    var path: []const u8 = undefined;
    if (zdos.getIds().uid != 0) {
        const home = sh.getVar("HOME") orelse return;
        path = std.fmt.bufPrint(&path_buf, "{s}{s}ashrc.sh", .{ home, if (std.mem.endsWith(u8, home, "\\") or std.mem.endsWith(u8, home, "/")) "" else "\\" }) catch return;
    } else if (sh.getVar("ENV")) |env| {
        path = env;
    } else {
        var program_buf: [512]u8 = undefined;
        const program = zdos.programPath(&program_buf);
        const apps = std.fs.path.dirnameWindows(program) orelse return;
        const root = std.fs.path.dirnameWindows(apps) orelse return;
        path = std.fmt.bufPrint(&path_buf, "{s}{s}SCRIPTS\\ashrc.sh", .{ root, if (std.mem.endsWith(u8, root, "\\")) "" else "\\" }) catch return;
    }
    if (!isFile(path)) return;
    const text = readScript(path) orelse return;
    defer gpa.free(text);
    _ = sh.runText(text, path);
    if (sh.flow != .exit_) sh.flow = .none;
}

fn printPrompt(sh: *Shell, prompt: []const u8) void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // \w and \$ first, their text in quotes, then the usual expansions:
    var text: std.ArrayListUnmanaged(u8) = .{};
    var i: usize = 0;
    while (i < prompt.len) : (i += 1) {
        if (prompt[i] == '\\' and i + 1 < prompt.len) {
            i += 1;
            switch (prompt[i]) {
                'w' => {
                    var cwd_buf: [1100]u8 = undefined;
                    quoteInto(a, &text, posixPath(&cwd_buf)) catch return;
                },
                // As bash: # with root's rights, else $:
                '$' => text.append(a, if (zdos.getIds().uid == 0) '#' else '$') catch return,
                'n' => text.append(a, '\n') catch return,
                '\\' => text.appendSlice(a, "\\\\") catch return,
                else => text.appendSlice(a, prompt[i - 1 .. i + 1]) catch return,
            }
            continue;
        }
        text.append(a, prompt[i]) catch return;
    }
    const old_status = sh.status;
    const rendered = expand.string(sh, a, text.items) catch prompt;
    sh.status = old_status;
    zdos.print(rendered);
    editor.setPrompt(rendered);
}

fn quoteInto(a: Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) Allocator.Error!void {
    try out.append(a, '\'');
    for (s) |c| {
        if (c == '\'') try out.appendSlice(a, "'\\''") else try out.append(a, c);
    }
    try out.append(a, '\'');
}

// As /C:/APPS.
pub fn posixPath(buf: *[1100]u8) []const u8 {
    var cwd_buf: [1026]u8 = undefined;
    const cwd = zdos.getCwd(&cwd_buf);
    var n: usize = 0;
    if (cwd.len > 1 and cwd[1] == ':') {
        buf[0] = '/';
        n = 1;
    }
    for (cwd) |c| {
        if (n >= buf.len) break;
        buf[n] = if (c == '\\') '/' else c;
        n += 1;
    }
    // "/C:/" for the root, but "/C:/APPS" without a slash at the end:
    return buf[0..n];
}
