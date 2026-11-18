// Event queues (epoll outside, kqueue-like inside)
// and counters (eventfd). Sockets, pipe ends and
// counters call notify when they change; waits look
// at what fired (edge) or at all watches.
const std = @import("std");
const abi = @import("abi.zig");
const tasks = @import("tasks.zig");
const platform = @import("../platform.zig");
const native = @import("builtin").cpu.arch.endian();

const B = abi.QueueBits;

pub const Error = error{ InvalidArgument, AlreadyExists, NotFound, OutOfMemory, Interrupted, WouldBlock };

pub const Queue = struct {
    refs: u32 = 1,
    news: std.atomic.Value(u32) = .init(0), // bumped when a watch fires (waitObjectSince)
    next: usize = 0, // where the next look starts: level watches take turns
};

// The events lock guards obj, queue, next and the chains
// (notify reads them on any core); the
// kernel lock the rest, and changes take both
const Watch = struct {
    obj: ?*const anyopaque = null, // what notifies it; null: a free entry
    queue: *Queue = undefined,
    owner: *const anyopaque = undefined, // the program whose handle it is
    handle: i32 = -1,
    events: u32 = 0, // QueueBits wanted, with edge / once
    data: u64 = 0,
    fired: std.atomic.Value(bool) = .init(false),
    off: bool = false, // once, and reported: until modified
    next: u16 = nil, // the next watch of its bucket, in index order
};

const max_watches = 512;
const nil = std.math.maxInt(u16);
var watches: [max_watches]Watch = @splat(.{});
var top: usize = 0; // entries at top and after are free
var active = std.atomic.Value(u32).init(0); // watches in use: none, notify returns at once

// Watches by object: a bucket's chain, so notify looks at one object's
const buckets = 128;
var heads: [buckets]u16 = @splat(nil);

fn bucketOf(obj: *const anyopaque) usize {
    const a = @intFromPtr(obj);
    return ((a >> 4) ^ (a >> 11)) % buckets;
}

// Lock order: the scheduler lock, then this one (notify runs
// from the tick with the scheduler lock held); never the
// scheduler lock while holding it
var held = std.atomic.Value(bool).init(false);
var waking = std.atomic.Value(u32).init(0); // notifies waking queues they found

fn lock() usize {
    while (true) {
        while (held.load(.monotonic)) std.atomic.spinLoopHint();
        const was = if (platform.has_switching) platform.switching.disable() else 0;
        if (held.cmpxchgWeak(false, true, .acquire, .monotonic) == null) return was;
        if (platform.has_switching) platform.switching.restore(was);
    }
}

fn unlock() void {
    held.store(false, .release);
}

fn interruptsBack(was: usize) void {
    if (platform.has_switching) platform.switching.restore(was);
}

// obj became readable, writable, hung up or failed:
// its watches fire and their queues' waiters wake.
// Any core, interrupts on or off; outside: from a core
// outside the scheduler (tasks.wakeFromOutside).
pub fn notify(obj: *const anyopaque) void {
    notifyMatching(obj, null, false);
}

pub fn notifyFromOutside(obj: *const anyopaque) void {
    notifyMatching(obj, null, true);
}

// Every watched object `is` says yes to (the network's overflowed news)
pub fn notifyWhere(is: *const fn (obj: *const anyopaque) bool) void {
    notifyMatching(null, is, false);
}

// In batches of up to 16 queues: news bumped under the events
// lock, then the queues woken under the scheduler lock,
// interrupts off throughout
fn notifyMatching(one: ?*const anyopaque, is: ?*const fn (obj: *const anyopaque) bool, outside: bool) void {
    if (active.load(.acquire) == 0) return;
    const batch = 16;
    var from: usize = 0; // watches from this index on are left
    while (true) {
        var qs: [batch]*Queue = undefined;
        var n: usize = 0;
        var more = false;
        const was = lock();
        var i: usize = if (one) |o| heads[bucketOf(o)] else from;
        while (i != nil and i < top) : (i = if (one != null) watches[i].next else i + 1) {
            if (i < from) continue;
            const w = &watches[i];
            const obj = w.obj orelse continue;
            if (if (one) |o| obj != o else !is.?(obj)) continue;
            if (n == batch) {
                more = true;
                from = i;
                break;
            }
            w.fired.store(true, .release);
            _ = w.queue.news.fetchAdd(1, .acq_rel);
            if (std.mem.indexOfScalar(*Queue, qs[0..n], w.queue) == null) {
                qs[n] = w.queue;
                n += 1;
            }
        }
        if (n > 0) _ = waking.fetchAdd(1, .acq_rel);
        unlock();
        for (qs[0..n]) |q| if (outside) tasks.wakeFromOutside(q) else tasks.wake(q);
        if (n > 0) _ = waking.fetchSub(1, .acq_rel);
        interruptsBack(was);
        if (!more) return;
    }
}

// A queue's own waiters, after a change
// to its watches: what holds now counts
fn poke(q: *Queue) void {
    _ = q.news.fetchAdd(1, .acq_rel);
    tasks.wake(q);
}

pub fn createQueue() ?*Queue {
    const mem = platform.memory.alloc(@sizeOf(Queue)) orelse return null;
    const q: *Queue = @ptrCast(@alignCast(mem));
    q.* = .{};
    return q;
}

pub fn releaseQueue(q: *Queue) void {
    q.refs -= 1;
    if (q.refs > 0) return;
    for (watches[0..top]) |*w| {
        if (w.obj != null and w.queue == q) drop(w);
    }
    // A notify may hold it still, between its lock and its wakes (short)
    while (waking.load(.acquire) != 0) std.atomic.spinLoopHint();
    platform.memory.free(@ptrCast(@alignCast(q)));
}

// A program's handle closed: its watches go
pub fn handleClosed(owner: *const anyopaque, handle: i32) void {
    for (watches[0..top]) |*w| {
        if (w.obj != null and w.owner == owner and w.handle == handle) drop(w);
    }
}

fn find(q: *Queue, owner: *const anyopaque, handle: i32) ?*Watch {
    for (watches[0..top]) |*w| {
        if (w.obj != null and w.queue == q and w.owner == owner and w.handle == handle) return w;
    }
    return null;
}

fn indexOf(w: *const Watch) u16 {
    return @intCast((@intFromPtr(w) - @intFromPtr(&watches)) / @sizeOf(Watch));
}

fn drop(w: *Watch) void {
    const i = indexOf(w);
    const was = lock();
    var at = &heads[bucketOf(w.obj.?)];
    while (at.* != i) at = &watches[at.*].next;
    at.* = w.next;
    w.obj = null;
    while (top > 0 and watches[top - 1].obj == null) top -= 1;
    _ = active.fetchSub(1, .release);
    unlock();
    interruptsBack(was);
}

// QueueOp on the watch of owner's handle (obj:
// what notifies for its object)
pub fn change(q: *Queue, owner: *const anyopaque, handle: i32, obj: *const anyopaque, op: u32, events: u32, data: u64) Error!void {
    const found = find(q, owner, handle);
    switch (op) {
        abi.QueueOp.add => {
            if (found != null) return error.AlreadyExists;
            const w = for (&watches) |*w| {
                if (w.obj == null) break w;
            } else return error.OutOfMemory;
            const i = indexOf(w);
            w.* = .{ .queue = q, .owner = owner, .handle = handle, .events = events, .data = data };
            w.fired.store(true, .release); // what holds already counts
            const was = lock();
            var at = &heads[bucketOf(obj)];
            while (at.* != nil and at.* < i) at = &watches[at.*].next;
            w.next = at.*;
            at.* = i;
            w.obj = obj;
            if (i >= top) top = i + 1;
            _ = active.fetchAdd(1, .release);
            unlock();
            interruptsBack(was);
            poke(q);
        },
        abi.QueueOp.modify => {
            const w = found orelse return error.NotFound;
            w.events = events;
            w.data = data;
            w.off = false;
            w.fired.store(true, .release);
            poke(q);
        },
        abi.QueueOp.delete => drop(found orelse return error.NotFound),
        else => return error.InvalidArgument,
    }
}

// POLL'S WATCHES
// A waiting poll is on each object it looks at (as MINIX's
// select and SerenityOS's blockers): a watch of its task's
// queue that nothing collects (the poll looks itself, api.zig).
// No program handle: handleClosed leaves it. Kernel lock held.

// A watch of q on obj; null with the table full
pub fn pollWatch(q: *Queue, obj: *const anyopaque) ?u16 {
    const w = for (&watches) |*w| {
        if (w.obj == null) break w;
    } else return null;
    const i = indexOf(w);
    w.* = .{ .queue = q, .owner = q, .handle = -1 };
    const was = lock();
    var at = &heads[bucketOf(obj)];
    while (at.* != nil and at.* < i) at = &watches[at.*].next;
    w.next = at.*;
    at.* = i;
    w.obj = obj;
    if (i >= top) top = i + 1;
    _ = active.fetchAdd(1, .release);
    unlock();
    interruptsBack(was);
    return i;
}

pub fn pollUnwatch(i: u16) void {
    if (watches[i].obj != null) drop(&watches[i]);
}

// A task that ended in its poll left watches of q
pub fn pollUnwatchAll(q: *Queue) void {
    for (watches[0..top]) |*w| {
        if (w.obj != null and w.queue == q) drop(w);
    }
}

// QueueBits that hold for a watched handle now; null if the
// handle is gone or is another object now
pub const Readiness = *const fn (handle: i32, obj: *const anyopaque) ?u32;

// The queue's events into out, waiting
// up to timeout_ms (-1: no limit) for one
pub fn wait(q: *Queue, out: []abi.QueueEvent, timeout_ms: i32, ready: Readiness) Error!usize {
    if (out.len == 0) return 0;
    const began = platform.clock.millis();
    while (true) {
        const seen = q.news.load(.acquire);
        const n = collect(q, out, ready);
        if (n > 0 or timeout_ms == 0) return n;
        var ms: ?u32 = null;
        if (timeout_ms > 0) {
            const gone = platform.clock.millis() - began;
            if (gone >= @as(u64, @intCast(timeout_ms))) return 0;
            ms = @intCast(@as(u64, @intCast(timeout_ms)) - gone);
        }
        const ok = if (tasks.active()) tasks.waitObjectSince(q, ms, &q.news, seen) else tasks.sleep(1);
        if (!ok) return error.Interrupted;
    }
}

fn collect(q: *Queue, out: []abi.QueueEvent, ready: Readiness) usize {
    var n: usize = 0;
    const count = top;
    if (count == 0) return 0;
    const start = q.next % count;
    var k: usize = 0;
    while (k < count and n < out.len) : (k += 1) {
        const i = (start + k) % count;
        const w = &watches[i];
        const obj = w.obj orelse continue;
        if (w.queue != q or w.off) continue;
        if (w.events & B.edge != 0 and !w.fired.swap(false, .acq_rel)) continue;
        const now = ready(w.handle, obj) orelse {
            drop(w);
            continue;
        };
        const got = now & (w.events | B.err | B.hup);
        if (got == 0) continue;
        out[n] = .{ .events = got, .data = w.data };
        n += 1;
        if (w.events & B.once != 0) w.off = true;
        q.next = i + 1;
    }
    return n;
}

pub const Counter = struct {
    refs: u32 = 1,
    value: u64,
    semaphore: bool,
    nonblock: bool,

    const max = std.math.maxInt(u64) - 1;

    pub fn readiness(self: *const Counter) u32 {
        return (if (self.value > 0) B.in else 0) | (if (self.value < max) B.out else 0);
    }

    // The count (semaphore: one) as 8 bytes, waiting while it is 0
    pub fn read(self: *Counter, buf: []u8) Error!usize {
        if (buf.len < 8) return error.InvalidArgument;
        while (self.value == 0) {
            if (self.nonblock or !tasks.active()) return error.WouldBlock;
            if (!tasks.waitObject(self, null)) return error.Interrupted;
        }
        const v: u64 = if (self.semaphore) 1 else self.value;
        self.value -= v;
        std.mem.writeInt(u64, buf[0..8], v, native);
        tasks.wake(self);
        notify(self);
        return 8;
    }

    // Adds an 8-byte value, waiting while it would pass max
    pub fn write(self: *Counter, data: []const u8) Error!usize {
        if (data.len < 8) return error.InvalidArgument;
        const v = std.mem.readInt(u64, data[0..8], native);
        if (v > max) return error.InvalidArgument;
        while (max - self.value < v) {
            if (self.nonblock or !tasks.active()) return error.WouldBlock;
            if (!tasks.waitObject(self, null)) return error.Interrupted;
        }
        self.value += v;
        tasks.wake(self);
        notify(self);
        return 8;
    }
};

pub fn createCounter(value: u32, flags: u32) ?*Counter {
    const mem = platform.memory.alloc(@sizeOf(Counter)) orelse return null;
    const c: *Counter = @ptrCast(@alignCast(mem));
    c.* = .{
        .value = value,
        .semaphore = flags & abi.CounterFlags.semaphore != 0,
        .nonblock = flags & abi.CounterFlags.nonblocking != 0,
    };
    return c;
}

pub fn releaseCounter(c: *Counter) void {
    c.refs -= 1;
    if (c.refs == 0) platform.memory.free(@ptrCast(@alignCast(c)));
}
