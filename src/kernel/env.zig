// Environment variables in a stack of scopes: the global one,
// plus one per running batch file. Lookups go from the
// innermost scope outwards; set writes only the innermost.
// Names are kept in capitals and compare case-insensitively.
const std = @import("std");
const platform = @import("../platform.zig");

pub const max_name = 32;
pub const max_value = 512;
const max_vars = 48; // per scope
const max_depth = 17; // the global scope + nested batch files

const Var = struct {
    name_buf: [max_name]u8 = undefined,
    name_len: usize = 0,
    // From the platform allocator. null: unset in this scope,
    // hiding an outer scope's variable (SET NAME= in a batch file)
    value: ?[]u8 = null,

    fn name(self: *const Var) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

const Scope = struct {
    vars: [max_vars]Var = [_]Var{.{}} ** max_vars,
    count: usize = 0,

    fn find(self: *Scope, name: []const u8) ?*Var {
        for (self.vars[0..self.count]) |*v| {
            if (std.ascii.eqlIgnoreCase(v.name(), name)) return v;
        }
        return null;
    }

    fn clear(self: *Scope) void {
        for (self.vars[0..self.count]) |*v| freeValue(v);
        self.count = 0;
    }
};

var global: Scope = .{};
// The scopes in use: the global one first. Each task has its
// own stack (its tasks.World); they share the global scope.
pub const Stack = struct {
    scopes: [max_depth]*Scope = undefined,
    depth: usize = 0,
};
// The running task's
pub fn active() *Stack {
    return &@import("tasks.zig").world().env;
}

// A new task's stack: the global scope only
pub fn initStack(st: *Stack) void {
    st.scopes[0] = &global;
    st.depth = 1;
}

// A new task's stack with variables of its own in place of the
// global ones (tasks.spawn_env): block's
// "NAME=value" entries, each ended by a 0 byte
pub fn initOwnStack(st: *Stack, block: []const u8) SetError!void {
    const mem = platform.memory.alloc(@sizeOf(Scope)) orelse return error.OutOfSpace;
    const s: *Scope = @ptrCast(@alignCast(mem));
    s.* = .{};
    var it = std.mem.splitScalar(u8, block, 0);
    while (it.next()) |entry| {
        if (entry.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse 0;
        setIn(s, true, entry[0..eq], entry[eq + 1 ..]) catch |err| {
            s.clear();
            platform.memory.free(@ptrCast(@alignCast(s)));
            return err;
        };
    }
    st.scopes[0] = s;
    st.depth = 1;
}

// A task ends: its own variables go (the global scope stays)
pub fn releaseStack(st: *Stack) void {
    if (st.depth > 0 and st.scopes[0] != &global) {
        st.scopes[0].clear();
        platform.memory.free(@ptrCast(@alignCast(st.scopes[0])));
    }
    initStack(st);
}

// A thread sees its program's task's base variables (global or its own)
pub fn initStackLike(st: *Stack, of: *const Stack) void {
    st.scopes[0] = of.scopes[0];
    st.depth = 1;
}

// Changes would go to the variables everyone shares
pub fn inGlobal() bool {
    return active().depth == 1 and active().scopes[0] == &global;
}

pub fn init() void {
    initStack(active());
    set("PATH", "C:\\APPS") catch {};
}

// false if nested too deeply or out of memory
pub fn push() bool {
    if (active().depth == max_depth) return false;
    const mem = platform.memory.alloc(@sizeOf(Scope)) orelse return false;
    const s: *Scope = @ptrCast(@alignCast(mem));
    s.* = .{};
    active().scopes[active().depth] = s;
    active().depth += 1;
    return true;
}

// 1: only the global scope
pub fn level() usize {
    return active().depth;
}

pub fn pop() void {
    if (active().depth <= 1) return;
    active().depth -= 1;
    const s = active().scopes[active().depth];
    s.clear();
    platform.memory.free(@ptrCast(@alignCast(s)));
}

fn freeValue(v: *Var) void {
    if (v.value) |val| {
        if (val.len > 0) platform.memory.free(@ptrCast(@alignCast(val.ptr)));
    }
    v.value = null;
}

pub fn get(name: []const u8) ?[]const u8 {
    var i = active().depth;
    while (i > 0) {
        i -= 1;
        if (active().scopes[i].find(name)) |v| return v.value;
    }
    return null;
}

pub const SetError = error{ BadName, TooLong, OutOfSpace };

// An empty value removes the variable (in a
// batch file's scope: hides the outer one)
pub fn set(name: []const u8, value: []const u8) SetError!void {
    return setIn(active().scopes[active().depth - 1], active().depth == 1, name, value);
}

// is_global: the base scope, where an empty value removes the variable
fn setIn(scope: *Scope, is_global: bool, name: []const u8, value: []const u8) SetError!void {
    if (name.len == 0 or name.len > max_name or std.mem.indexOfAny(u8, name, "=% ") != null) return error.BadName;
    if (value.len > max_value) return error.TooLong;
    const v = scope.find(name) orelse blk: {
        if (value.len == 0 and is_global) return; // nothing to remove
        if (scope.count == max_vars) return error.OutOfSpace;
        const nv = &scope.vars[scope.count];
        scope.count += 1;
        nv.* = .{};
        _ = std.ascii.upperString(nv.name_buf[0..name.len], name);
        nv.name_len = name.len;
        break :blk nv;
    };
    freeValue(v);
    if (value.len == 0) {
        if (is_global) {
            // The last one takes its place
            const i = (@intFromPtr(v) - @intFromPtr(&scope.vars[0])) / @sizeOf(Var);
            scope.vars[i] = scope.vars[scope.count - 1];
            scope.count -= 1;
        }
        // In a batch file's scope the entry stays,
        // with no value: it hides the outer one
        return;
    }
    const mem = platform.memory.alloc(value.len) orelse return error.OutOfSpace;
    @memcpy(mem[0..value.len], value);
    v.value = mem[0..value.len];
}

pub const Entry = struct { name: []const u8, value: []const u8 };

// The index-th visible variable, each name once with its
// innermost value, outer scopes first; null past the last one
pub fn at(index: usize) ?Entry {
    var n: usize = 0;
    for (0..active().depth) |lv| {
        const s = active().scopes[lv];
        for (s.vars[0..s.count]) |*v| {
            const hidden = for (lv + 1..active().depth) |inner| {
                if (active().scopes[inner].find(v.name()) != null) break true;
            } else false;
            if (hidden) continue;
            const val = v.value orelse continue;
            if (n == index) return .{ .name = v.name(), .value = val };
            n += 1;
        }
    }
    return null;
}
