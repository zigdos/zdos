// For services: TERM / INT / Ctrl+C stop them, HUP reloads;
// "NAME -reload" / "NAME -stop" signal the running one.
const std = @import("std");
const zdos = @import("zdos.zig");
const sys = @import("system.zig");

pub var stopping = std.atomic.Value(bool).init(false);
pub var reloading = std.atomic.Value(bool).init(false);

fn onSignal(sig: i32) callconv(zdos.cc) void {
    if (sig == sys.Signal.hup) reloading.store(true, .release) else stopping.store(true, .release);
}

pub fn catchSignals() void {
    const one: u64 = 1;
    zdos.table().signals.set_handler(&onSignal, one << sys.Signal.term | one << sys.Signal.int | one << sys.Signal.hup, one << sys.Signal.pipe);
    sys.catchCtrlC(true);
}

pub fn shouldStop() bool {
    if (sys.ctrlCPressed(true)) stopping.store(true, .release);
    return stopping.load(.acquire);
}

// Once.
pub fn takeReload() bool {
    return reloading.swap(false, .acq_rel);
}

// To the other tasks running NAME.APP: how many.
pub fn signalRunning(name: []const u8, sig: u32) usize {
    const me = sys.taskId();
    var n: usize = 0;
    var i: u32 = 0;
    while (sys.taskInfo(i)) |t| : (i += 1) {
        const full = std.mem.sliceTo(&t.name, 0);
        const stem = full[0 .. std.mem.indexOfScalar(u8, full, '.') orelse full.len];
        if (t.id == me or t.state == sys.TaskState.ended or !std.ascii.eqlIgnoreCase(stem, name)) continue;
        sys.signalSend(t.id, sig) catch continue;
        n += 1;
    }
    return n;
}

// The exit code; null if args is neither.
pub fn command(name: []const u8, args: []const u8) ?u8 {
    const a = std.mem.trim(u8, args, " \t");
    const sig: u32 = if (std.ascii.eqlIgnoreCase(a, "-reload") or std.ascii.eqlIgnoreCase(a, "/reload"))
        sys.Signal.hup
    else if (std.ascii.eqlIgnoreCase(a, "-stop") or std.ascii.eqlIgnoreCase(a, "/stop"))
        sys.Signal.term
    else
        return null;
    const n = signalRunning(name, sig);
    if (n == 0) {
        zdos.eprintf("{s}: not running\n", .{name});
        return 1;
    }
    zdos.printf("{s}: {s} sent\n", .{ name, if (sig == sys.Signal.hup) "reload" else "stop" });
    return 0;
}

// COMSPEC'S, FOR \CONF AND \DATA.
pub fn drive() u8 {
    var b: [300]u8 = undefined;
    if (zdos.getVar("COMSPEC", &b)) |c| {
        if (c.len > 1 and c[1] == ':') return c[0];
    }
    return 'C';
}

// In memory of the allocator's; null: none, or unreadable.
pub fn readAll(path: []const u8, max: usize) ?[]u8 {
    const f = zdos.open(path, .read) catch return null;
    defer f.close();
    const size: usize = @intCast(@min(f.size() catch return null, max));
    const buf = zdos.allocator.alloc(u8, size) catch return null;
    var len: usize = 0;
    while (len < size) {
        const n = f.read(buf[len..]) catch break;
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

// Size and modified time, to see that it changed.
pub const Watch = struct {
    stamp: [16]u8 = @splat(0xFF),

    fn now(path: []const u8) [16]u8 {
        var s: [16]u8 = @splat(0);
        const e = zdos.stat(path) catch return s;
        std.mem.writeInt(u64, s[0..8], e.size, .little);
        @memcpy(s[8..16], std.mem.asBytes(&e.modified));
        return s;
    }

    // True the first time, then when it differs from the last call's.
    pub fn changed(self: *Watch, path: []const u8) bool {
        const s = now(path);
        if (std.mem.eql(u8, &s, &self.stamp)) return false;
        self.stamp = s;
        return true;
    }
};

// Empty path: none.
pub const Log = struct {
    path_buf: [260]u8 = undefined,
    path_len: usize = 0,

    // The log's file, its folder made
    pub fn set(self: *Log, path: []const u8) void {
        self.path_len = @min(path.len, self.path_buf.len);
        @memcpy(self.path_buf[0..self.path_len], path[0..self.path_len]);
        if (path.len == 0) return;
        if (std.fs.path.dirnameWindows(path)) |dir| {
            if (std.fs.path.dirnameWindows(dir)) |parent| zdos.makeDir(parent) catch {};
            zdos.makeDir(dir) catch {};
        }
    }

    pub fn line(self: *Log, comptime fmt: []const u8, args: anytype) void {
        if (self.path_len == 0) return;
        const path = self.path_buf[0..self.path_len];
        var buf: [600]u8 = undefined;
        const t = zdos.getTime();
        const head = std.fmt.bufPrint(&buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} ", .{ t.year, t.month, t.day, t.hour, t.minute, t.second }) catch return;
        const body = std.fmt.bufPrint(buf[head.len .. buf.len - 1], fmt, args) catch buf[head.len .. buf.len - 1];
        buf[head.len + body.len] = '\n';
        const f = zdos.open(path, .update) catch zdos.open(path, .write) catch return;
        defer f.close();
        f.seek(f.size() catch 0) catch {};
        f.writeAll(buf[0 .. head.len + body.len + 1]) catch {};
    }
};

// SETTING=value lines ('#' and ';' comments, [sections] skipped).
pub const Line = union(enum) { setting: struct { name: []const u8, value: []const u8 }, words: []const u8 };

pub fn lines(text: []const u8) LineIterator {
    return .{ .it = std.mem.tokenizeAny(u8, text, "\r\n") };
}

pub const LineIterator = struct {
    it: std.mem.TokenIterator(u8, .any),

    pub fn next(self: *LineIterator) ?Line {
        while (self.it.next()) |raw| {
            const cut = raw[0 .. std.mem.indexOfScalar(u8, raw, '#') orelse raw.len];
            const line = std.mem.trim(u8, cut, " \t");
            if (line.len == 0 or line[0] == ';' or line[0] == '[') continue;
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                return .{ .setting = .{ .name = std.mem.trim(u8, line[0..eq], " \t"), .value = std.mem.trim(u8, line[eq + 1 ..], " \t") } };
            }
            return .{ .words = line };
        }
        return null;
    }
};
