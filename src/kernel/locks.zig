// Byte-range locks on files, as Windows' LockFileEx.
// Each is held by an open file (a handle and its dup
// copies) and goes when that closes or its program ends.
// Advisory: reads and writes don't look at them.
// An open file's own locks never stand in its way.
// Locking a range it holds again converts that lock.
// Waiters sleep on a futex, woken by every unlock.
const std = @import("std");
const platform = @import("../platform.zig");
const tasks = @import("tasks.zig");

const max_locks = 256;

pub const Error = error{ WouldBlock, TimedOut, Interrupted, InvalidArgument, OutOfMemory };

const Lock = struct {
    used: bool = false,
    exclusive: bool = false,
    key: platform.storage.FileKey = undefined,
    owner: *const anyopaque = undefined, // the stdio.File
    start: u64 = 0,
    end: u64 = 0, // past the last byte; maxInt: no end
};

var table = [_]Lock{.{}} ** max_locks;
var table_lock = std.atomic.Value(bool).init(false);
// Changes with every unlock: what waiters sleep on
var released: u32 = 0;

fn take() usize {
    const was = if (platform.has_switching) platform.switching.disable() else 0;
    while (table_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    return was;
}

fn give(was: usize) void {
    table_lock.store(false, .release);
    if (platform.has_switching) platform.switching.restore(was);
}

fn sameKey(a: platform.storage.FileKey, b: platform.storage.FileKey) bool {
    return a.volume == b.volume and a.id == b.id;
}

fn endOf(start: u64, len: u64) Error!u64 {
    if (len == 0) return std.math.maxInt(u64);
    return std.math.add(u64, start, len) catch error.InvalidArgument;
}

// Whether another open file's lock is in the way
fn blocked(key: platform.storage.FileKey, owner: *const anyopaque, start: u64, end: u64, exclusive: bool) bool {
    for (&table) |*l| {
        if (!l.used or l.owner == owner or !sameKey(l.key, key)) continue;
        if (l.start >= end or start >= l.end) continue;
        if (exclusive or l.exclusive) return true;
    }
    return false;
}

fn find(key: platform.storage.FileKey, owner: *const anyopaque, start: u64, end: u64) ?*Lock {
    for (&table) |*l| {
        if (l.used and l.owner == owner and sameKey(l.key, key) and l.start == start and l.end == end) return l;
    }
    return null;
}

// len 0: from start on, however far the file grows; ms 0:
// fail at once (WouldBlock), null: no limit (else TimedOut)
pub fn lock(key: platform.storage.FileKey, owner: *const anyopaque, start: u64, len: u64, exclusive: bool, ms: ?u32) Error!void {
    const end = try endOf(start, len);
    const until = if (ms) |m| platform.clock.millis() + m else 0;
    while (true) {
        const was = take();
        const seen = @atomicLoad(u32, &released, .acquire);
        if (!blocked(key, owner, start, end, exclusive)) {
            defer give(was);
            if (find(key, owner, start, end)) |l| {
                l.exclusive = exclusive;
                return;
            }
            for (&table) |*l| {
                if (l.used) continue;
                l.* = .{ .used = true, .exclusive = exclusive, .key = key, .owner = owner, .start = start, .end = end };
                return;
            }
            return error.OutOfMemory;
        }
        give(was);
        var left: ?u32 = null;
        if (ms != null) {
            const now = platform.clock.millis();
            if (now >= until) return if (ms.? == 0) error.WouldBlock else error.TimedOut;
            left = @intCast(@min(until - now, std.math.maxInt(u32)));
        }
        tasks.futexWait(&released, seen, left, 0xFFFF_FFFF) catch |err| switch (err) {
            error.WouldBlock => {}, // released meanwhile
            error.TimedOut => {},
            error.Interrupted => return error.Interrupted,
            error.InvalidArgument => return error.InvalidArgument,
        };
    }
}

// The lock of exactly that range: false if there is none
pub fn unlock(key: platform.storage.FileKey, owner: *const anyopaque, start: u64, len: u64) Error!bool {
    const end = try endOf(start, len);
    const was = take();
    const l = find(key, owner, start, end);
    if (l) |x| x.used = false;
    give(was);
    if (l != null) wake();
    return l != null;
}

// The open file closes: its locks go
pub fn dropOwner(owner: *const anyopaque) void {
    var any = false;
    const was = take();
    for (&table) |*l| {
        if (l.used and l.owner == owner) {
            l.used = false;
            any = true;
        }
    }
    give(was);
    if (any) wake();
}

fn wake() void {
    _ = @atomicRmw(u32, &released, .Add, 1, .release);
    _ = tasks.futexWake(&released, std.math.maxInt(u32), 0xFFFF_FFFF) catch 0;
}
