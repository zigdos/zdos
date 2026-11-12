// Tasks: programs running at the same time (metal, BIOS:
// on all cores; UEFI: core 0) in one address space.
// Task 1 (slot 0) is the one ZDOS started with; ids are POSIX
// process IDs, 0 none.
//
// Fixed priorities 0-31 (higher first), round
// robin per `slice`. Metal and BIOS preempt anywhere outside
// interrupts-off sections (all spinlocks are such), ZDOS's
// own code included. UEFI is cooperative: switches only in
// ZDOS's waits and on leaving it. No periodic tick: each core's
// timer is armed for its next deadline (core 0 also every 1 ms
// for the network). Times are nanoseconds. Each task has its
// own World (program, stdio, env, drive).
//
// Kernel lock ("Giant"): taken on entering ZDOS except by
// calls that need only the scheduler (time, waits, mutexes,
// futexes, signals ...); given up while waiting;
// only a driver's ioWait keeps it. It and all mutexes inherit
// priority, through chains.
//
// An ended task is freed at once; its exit code stays in
// `ended_list` (64, oldest overwritten) unless SA_NOCLDWAIT.
// Threads are kept until joined unless detached. Signals arrive
// when ZDOS returns to the program, or before preempted program
// code resumes (signalEntry).
const std = @import("std");
const platform = @import("../platform.zig");
const arch = @import("../arch.zig");
const abi = @import("abi.zig");
const api = @import("api.zig");
const stdio = @import("stdio.zig");
const env = @import("env.zig");
const fs = @import("fs.zig");
const perm = @import("perm.zig");
const con = @import("console.zig");
const loader = @import("loader.zig");
const Term = @import("term.zig").Term;

pub const max_tasks = 64;
pub const priorities = 32;
pub const default_priority = 16;
const slice_ns = 10_000_000; // round robin within a priority
const housekeeping_ns = 1_000_000; // core 0's timer at the latest: the network's news
const accounting_ns = 10_000_000; // other cores' (not isolated): CPU times stay current
const stack_size = platform.config.stacks.task; // a task's own stack, where it starts its program
const max_thread_stack = platform.config.stacks.thread_max;

const Why = if (platform.has_switching) platform.switching.Why else enum { yield, tick, irq };
// No timer interrupt: the clock is caught
// up with at every switch (catchUp)
const cooperative = platform.has_switching and @hasDecl(platform.switching, "cooperative");
const Sig = abi.Signal;

// Several cores run tasks (metal): the platform tells a core
// its index and calls back once it
// is off a task's stack (finish)
const smp = platform.has_switching and @hasDecl(platform.switching, "coreIndex");

// Interrupts off and, once other cores run
// tasks, the scheduler lock: all of this
// file's state is under it. A core may take it
// again while it holds it.
fn disable() usize {
    const was = if (platform.has_switching) platform.switching.disable() else 0;
    lockSched();
    return was;
}

fn restore(state: usize) void {
    unlockSched();
    if (platform.has_switching) platform.switching.restore(state);
}

var sched_owner = std.atomic.Value(u32).init(0); // core index + 1; 0: free
var sched_depth: u32 = 0;

fn lockSched() void {
    if (!smp or !(smp_on or outside)) return;
    const id: u32 = @intCast(coreIndex() + 1);
    if (sched_owner.load(.monotonic) == id) {
        sched_depth += 1;
        return;
    }
    while (true) {
        while (sched_owner.load(.monotonic) != 0) std.atomic.spinLoopHint();
        if (sched_owner.cmpxchgWeak(0, id, .acquire, .monotonic) == null) break;
    }
    sched_depth = 1;
}

fn unlockSched() void {
    if (!smp or !(smp_on or outside)) return;
    sched_depth -= 1;
    if (sched_depth != 0) return;
    // The kick state is taken and cleared while the lock is held: a
    // task made ready by another core right
    // after the unlock must not lose its kick
    const k = kick_wanted;
    const pinned = kick_pinned;
    const mask = kick_mask;
    const prio = kick_prio;
    kick_wanted = false;
    kick_pinned = 0;
    kick_mask = 0;
    kick_prio = 0;
    sched_owner.store(0, .release);
    if (k) _ = kickCore(pinned, mask, prio, coreIndex());
}

pub const State = enum(u8) {
    free,
    ready,
    running,
    sleeping, // until wake_at
    waiting, // for a task's end (waits_for)
    mutex, // for a mutex (blocked_on), the kernel lock too
    blocked, // for wait_obj (a pipe, a condition, a semaphore, a thread's end ...), until wake_at if set
    io, // a driver for its device's interrupt (wait_obj: the IoEvent), until wake_at
    stopped, // SIGSTOP, until SIGCONT
    zombie,
};

// What ended a wait
pub const Wake = enum(u8) { none, object, timeout, signal };

// What ZDOS keeps for "the running program": each task's own
pub const World = struct {
    program: ?*api.Program = null,
    input: stdio.Input = .none,
    output: stdio.Output = .screen,
    errout: stdio.Output = .screen,
    depth: usize = 0,
    catching: bool = false,
    break_pending: bool = false,
    drive: ?*fs.Drive = null,
    env: env.Stack = .{},
};

// Before init (task 1's record isn't set up yet): startup's
// world, which task 1 then takes over
var boot_world: World = .{};
var world_ready = false;

// The running task's world: what api.current, stdio's streams,
// the current drive and the variables were as globals
pub fn world() *World {
    if (!world_ready) return &boot_world;
    return &cur().world;
}

pub const any_child = 0xFFFF_FFFF;
const any_core = 0xFF;
const all_cores = ~@as(u64, 0);

// ISOLCPUS=: cores tasks without an affinity of their own
// (all_cores) don't run on, left to
// those that ask for them (never core 0)
pub var isolated: u64 = 0;

fn allowed(t: *const Task) u64 {
    return if (t.cores == all_cores) ~isolated else t.cores;
}

fn indexOf(c: *const Core) usize {
    if (c == &core0) return 0;
    return (@intFromPtr(c) - @intFromPtr(&other_cores[0])) / @sizeOf(Core) + 1;
}

pub const Task = struct {
    id: u32 = 0,
    state: State = .free,
    base_priority: u8 = default_priority,
    priority: u8 = default_priority, // with what it inherits
    sp: usize = 0, // where its registers are while it doesn't run
    next: ?*Task = null, // in its ready queue
    wake_at: u64 = 0, // nanos(); sleeping: then; blocked, io: the deadline (0: none)
    waits_for: u32 = 0, // waiting: that task's end (any_child: any child's)
    blocked_on: ?*Mutex = null,
    wait_obj: ?*const anyopaque = null,
    woke: Wake = .none,
    futex_bits: u32 = 0, // blocked on a futex (wait_obj: its address): the waiter's bits
    wait_seq: u64 = 0, // when its futex wait began: equal priorities wake oldest first
    interruptible: bool = false, // its wait ends for a signal
    parent: u32 = 0,
    detached: bool = false, // nobody waits for it: freed once it ends
    exit_code: u8 = 0,
    term_signal: u8 = 0, // the signal that ended its program, if one did
    cpu_ms: u64 = 0, // milliseconds it ran (from cpu_ns)
    cpu_ns: u64 = 0,
    last_core: u8 = 0, // where it ran last: that core's timer has its deadlines
    // A thread: runs thread_entry(thread_arg) in its creator's program
    thread: bool = false,
    kernel: bool = false, // ZDOS's own (kernelTask): no program, no signals
    main_id: u32 = 0, // a thread's program's own task
    thread_program: ?*api.Program = null,
    thread_entry: usize = 0,
    thread_arg: usize = 0,
    thread_result: usize = 0,
    stack_bytes: usize = stack_size,
    tls: usize = 0, // the program's per-thread value (the C library's errno and keys)
    thread_pointer: usize = 0, // its thread_local block (arch.setThreadPointer)
    // Signals
    sig_pending: u64 = 0,
    sig_mask: u64 = 0,
    // Its timer (alarm, setitimer, timer_settime):
    // timer_sig at timer_at (nanos(); 0: off), again
    // every timer_interval
    timer_at: u64 = 0,
    timer_interval: u64 = 0,
    timer_sig: u8 = 0,
    preempted_in_program: bool = false, // its saved state is in its program's code
    on_cpu: bool = false, // a core runs it, or hasn't finished switching away from it
    doomed: bool = false, // its program ended while it ran on another core
    cores: u64 = all_cores, // the cores that may run it (bit n: core n)
    policy: Policy = .rr, // fifo: no time slice among its priority
    // Deadline tasks (setDeadline): nanoseconds; the current
    // period's start, absolute deadline
    // and budget left; the priority before
    dl_runtime: u64 = 0,
    dl_deadline: u64 = 0,
    dl_period: u64 = 0,
    dl_start: u64 = 0,
    dl_abs: u64 = 0,
    dl_left: i64 = 0,
    dl_saved_prio: u8 = default_priority,
    resume_sp: usize = 0, // after signals were handled (signalEntry): this state
    // Current directories its first program starts with:
    // its starter's (counted; released when it ends)
    cwds: fs.CwdSet = .{},
    ids: perm.Ids = .{}, // the user its first program runs as: its starter's
    // Streams spawn gave it (references, released when it ends)
    own_input: stdio.Input = .none,
    own_output: stdio.Output = .screen,
    own_errout: stdio.Output = .screen,
    // Its screen and keyboard if they are remote (term.zig);
    // counted, except a thread's
    term: ?*Term = null,
    world: World = .{},
    stack: ?[*]align(4096) u8 = null,
    found: loader.Found = undefined, // its program and arguments
    args_buf: [loader.max_args]u8 = undefined,
    args_len: usize = 0,
    name_buf: [32]u8 = [_]u8{0} ** 32,

    pub fn name(self: *const Task) []const u8 {
        return std.mem.sliceTo(&self.name_buf, 0);
    }
};

// Set up in init (undefined here:
// zero-filled memory, not part of the file)
pub var tasks: [max_tasks]Task = undefined;
var next_id: u32 = 2;
var idle_ns: u64 = 0; // time nothing ran in, all cores'

// What each core runs: its task, its own idle task, its turn
const max_cores = 64;
const Core = struct {
    current: *Task,
    idle: Task,
    slice_end: u64 = 0, // nanos(): the running task's turn ends (round robin)
    accounted: u64 = 0, // nanos() up to which CPU time was counted
    // A task of higher priority became ready
    // while ZDOS ran: switch on leaving it
    switch_pending: bool = false,
    leaving: ?*Task = null, // switched away from: off this core once finish runs
    online: bool = false, // runs tasks
};
// Core 0's from the start (before init too); the others' when they join
var core0: Core = .{ .current = &tasks[0], .idle = .{ .id = 0xFFFF_FFFF, .base_priority = 0, .priority = 0 }, .online = true };
var other_cores: [max_cores - 1]Core = undefined;

fn coreAt(i: usize) *Core {
    return if (i == 0) &core0 else &other_cores[i - 1];
}
var smp_on = false; // other cores run tasks too (startCores)
var core_count: usize = 1; // cores running tasks
var kick_wanted = false; // a task became ready: an idle core should look
var kick_pinned: u64 = 0; // specific cores with pinned ready tasks
var kick_mask: u64 = 0; // the cores what became ready (unpinned) may run on (enqueue)
var kick_prio: u8 = 0; // and its priority

fn coreIndex() usize {
    return if (smp and (smp_on or outside)) platform.switching.coreIndex() else 0;
}

// A core outside the scheduler (the network's)
// wakes tasks itself: the scheduler's lock is taken
// even with tasks on core 0 alone
var outside = false;

// From core 0, before that core starts
// (it sets its own index): whether it may
pub fn allowOutsideWakes() bool {
    if (!smp or !running) return false;
    platform.switching.setCoreIndex(0);
    outside = true;
    return true;
}

fn me() *Core {
    return coreAt(coreIndex());
}

// The running task. Interrupts off for the read: preempted
// between finding the core and reading its
// task, it could have moved to another core.
fn cur() *Task {
    if (!smp or !platform.has_switching) return core0.current;
    const was = platform.switching.disable();
    const t = me().current;
    platform.switching.restore(was);
    return t;
}

// The ready tasks: a FIFO per priority, a bit per non-empty one
var heads = [_]?*Task{null} ** priorities;
var tails = [_]?*Task{null} ** priorities;
var ready_bits: u32 = 0;

var running = false; // switching started

// At startup, after the platform: task 0 is what runs now
pub fn init() void {
    for (&tasks) |*x| x.* = .{};
    for (&ended_list) |*r| r.* = .{};
    for (&mutexes) |*m| m.* = .{};
    for (&conds) |*c| c.* = .{};
    for (&sems) |*s| s.* = .{};
    const t = &tasks[0];
    t.* = .{ .id = 1, .state = .running, .on_cpu = true, .world = boot_world };
    @memcpy(t.name_buf[0..4], "ZDOS");
    core0.current = t;
    world_ready = true;
    if (platform.has_switching) {
        const stack = platform.memory.allocPages(stack_size / 4096, false) orelse return;
        me().idle.state = .ready;
        me().idle.sp = platform.switching.newContext(@intFromPtr(stack) + stack_size, &idleLoop, 0);
        running = if (smp) platform.switching.start(&switchPoint, &finishSwitch) else platform.switching.start(&switchPoint);
        if (running) {
            platform.io.wait = &ioWait;
            platform.io.signal = &ioSignal;
            platform.faults.handler = &api.programFault;
            startIrqTask(30); // before devices' interrupts: their deferred work
            platform.storage_lock = &lockStorage;
            platform.storage_unlock = &unlockStorage;
            platform.core0_enter = &toCoreZero;
            platform.core0_leave = &backFromCoreZero;
            platform.startInterrupts();
        }
    }
}

pub fn active() bool {
    return running;
}

// The current task's own priority (without what it inherits)
pub fn ownPriority() u8 {
    return cur().base_priority;
}

// POSIX's scheduling policies (abi.Policy's numbers): rr takes
// turns every `slice` within a priority, fifo keeps the CPU
// until it waits, yields or a higher priority comes deadline
// (Linux's SCHED_DEADLINE, 6): earliest deadline first, above
// every priority, with a budget per period (setDeadline)
pub const Policy = enum(u8) { fifo = 1, rr = 2, deadline = 6 };

pub fn ownPolicy() Policy {
    return cur().policy;
}

pub fn setPolicy(id: u32, policy: Policy) bool {
    if (policy == .deadline) return false; // setDeadline
    const t = byId(id) orelse return false;
    const was = disable();
    defer restore(was);
    const was_deadline = t.policy == .deadline;
    t.policy = policy;
    if (was_deadline) {
        // Back to its priority from before (recompute requeues it)
        t.base_priority = t.dl_saved_prio;
        recompute(t);
    }
    return true;
}

// DEADLINE SCHEDULING (EDF WITH A BUDGET PER PERIOD)
// A deadline task runs at the top priority, the
// earliest absolute deadline first among them.
// Each period it may run `runtime`: then it
// waits for the next period (throttled).
// Its deadline is renewed as it becomes ready
// once the last one passed. Admission: all of
// them together at most 95% of the cores' time.

const deadline_priority = priorities - 1;

pub const DeadlineError = error{ InvalidArgument, NotFound, Overloaded };

pub fn setDeadline(id: u32, runtime: u64, deadline: u64, period_or_0: u64) DeadlineError!void {
    const period = if (period_or_0 == 0) deadline else period_or_0;
    if (runtime == 0 or runtime > deadline or deadline > period) return error.InvalidArgument;
    const t = byId(id) orelse return error.NotFound;
    const was = disable();
    defer restore(was);
    // Utilization in millionths of a core: the others' and this one's
    var used: u64 = 0;
    for (&tasks) |*x| {
        if (x == t or x.state == .free or x.state == .zombie or x.policy != .deadline) continue;
        used += x.dl_runtime * 1_000_000 / x.dl_period;
    }
    used += runtime * 1_000_000 / period;
    if (used > core_count * 950_000) return error.Overloaded;
    if (t.policy != .deadline) t.dl_saved_prio = t.base_priority;
    t.policy = .deadline;
    t.dl_runtime = runtime;
    t.dl_deadline = deadline;
    t.dl_period = period;
    t.dl_abs = 0; // renewed now (running) or as it becomes ready
    renewDeadline(t, platform.clock.nanos());
    t.base_priority = deadline_priority;
    if (t.state == .ready) {
        remove(t);
        t.priority = deadline_priority;
        enqueue(t);
    } else t.priority = @max(t.priority, deadline_priority);
    requestSwitch();
}

pub fn deadlineOf(id: u32) ?struct { runtime: u64, deadline: u64, period: u64 } {
    const t = byId(id) orelse return null;
    if (t.policy != .deadline) return null;
    return .{ .runtime = t.dl_runtime, .deadline = t.dl_deadline, .period = t.dl_period };
}

// A new period once the deadline passed: budget full, deadline ahead
fn renewDeadline(t: *Task, now: u64) void {
    if (t.policy != .deadline or (t.dl_abs != 0 and now < t.dl_abs)) return;
    t.dl_start = now;
    t.dl_abs = now + t.dl_deadline;
    t.dl_left = @intCast(t.dl_runtime);
}

// What EDF orders by: the absolute
// deadline (others at that priority after)
fn edfKey(t: *const Task) u64 {
    return if (t.policy == .deadline) t.dl_abs else std.math.maxInt(u64);
}

// The earliest deadline among the ready ones c may run (maxInt: none)
fn earliestReady(c: *Core) u64 {
    var best: u64 = std.math.maxInt(u64);
    var at = heads[deadline_priority];
    while (at) |t| : (at = t.next) {
        if ((allowed(t) >> @intCast(indexOf(c))) & 1 == 0) continue;
        best = @min(best, edfKey(t));
    }
    return best;
}

// The cores a task may run on (bit n: core n; all ones: any,
// isolated ones aside). False for an unknown task or a set
// without a core running tasks.
pub fn setAffinity(id: u32, mask: u64) bool {
    const t = byId(id) orelse return false;
    var usable: u64 = 1; // core 0
    for (1..max_cores) |i| {
        if (smp_on and @atomicLoad(bool, &coreAt(i).online, .acquire)) usable |= @as(u64, 1) << @intCast(i);
    }
    if (mask & usable == 0) return false;
    const was = disable();
    t.cores = if (mask & usable == usable) all_cores else mask;
    restore(was);
    if (t != cur() and t.state == .ready) kickIdleCore(allowed(t));
    return true;
}

pub fn affinity(id: u32) ?u64 {
    const t = byId(id) orelse return null;
    return t.cores;
}

pub fn ownAffinity() u64 {
    return cur().cores;
}

pub fn currentId() u32 {
    return cur().id;
}

pub fn currentTask() *Task {
    return cur();
}

// Since startup: milliseconds in all (of every core running
// tasks), and those no task ran in
// (0 without switching: unknown)
pub fn times() struct { total: u64, idle: u64 } {
    return .{ .total = platform.clock.millis() * core_count, .idle = idle_ns / 1_000_000 };
}

fn idleTask() Task {
    return .{ .id = 0xFFFF_FFFF, .base_priority = 0, .priority = 0, .state = .running, .on_cpu = true };
}

// OTHER CORES

// At the end of startup (after the network took a core of
// its own, if it does): the other cores join, up to
// `limit` in all (CORES=; null: all), the network's aside
// (its start fails). Each runs its idle task until its
// timer gives it a ready one.
pub fn startCores(limit: ?usize) void {
    if (!smp or !running) return;
    const n = @min(platform.cores.count(), limit orelse max_cores, max_cores);
    if (n < 2) return;
    platform.switching.setCoreIndex(0);
    smp_on = true;
    for (1..n) |i| {
        const c = coreAt(i);
        c.* = .{ .current = undefined, .idle = idleTask() };
        c.current = &c.idle;
        if (!platform.cores.start(@intCast(i), &coreJoin, @ptrFromInt(i))) continue;
        // Wait until it runs tasks (or gave up: its timer can't reach it)
        const until = platform.clock.millis() + 100;
        while (!@atomicLoad(bool, &c.online, .acquire) and platform.clock.millis() < until) std.atomic.spinLoopHint();
    }
}

pub fn coreCount() usize {
    return core_count;
}

// A core's job that never returns: from
// now on it is a core of the scheduler
fn coreJoin(arg: ?*anyopaque) callconv(arch.cc) void {
    const i = @intFromPtr(arg);
    platform.switching.setCoreIndex(i);
    if (!platform.switching.startCore()) return; // no ticks here: it stays a job worker
    const was = disable();
    core_count += 1;
    @atomicStore(bool, &coreAt(i).online, true, .release);
    restore(was);
    idleLoop(0);
}

// A task became ready: an idle core (not this one) looks at once
fn kickIdleCore(mask: u64) void {
    if (!@hasDecl(platform.switching, "kick")) return;
    if (idleCoreIn(mask, coreIndex())) |i| platform.switching.kick(i);
}

// A task became ready: kick each core that has a pinned task
// waiting for it, and kick at most ONE core
// for unpinned tasks (no thundering herd)
fn kickCore(pinned: u64, mask: u64, prio: u8, self: usize) bool {
    if (!@hasDecl(platform.switching, "kick")) return false;
    var kicked_mask: u64 = 0;

    // 1. Kick each core that has a pinned task specifically waiting for it
    if (pinned != 0) {
        for (0..max_cores) |i| {
            if (i == self or (pinned >> @intCast(i)) & 1 == 0) continue;
            if (i > 0 and !@atomicLoad(bool, &smp_on, .acquire)) break;
            const c = coreAt(i);
            if (!@atomicLoad(bool, &c.online, .acquire)) continue;
            const cur_task = @atomicLoad(*Task, &c.current, .monotonic);
            if (cur_task == &c.idle or cur_task.priority < prio) {
                platform.switching.kick(i);
                kicked_mask |= @as(u64, 1) << @intCast(i);
            }
        }
    }

    // 2. For unpinned tasks: kick AT MOST ONE idle or lower-priority core
    if (mask != 0 and kicked_mask & mask == 0) {
        if (idleCoreIn(mask, self)) |i| {
            platform.switching.kick(i);
            kicked_mask |= @as(u64, 1) << @intCast(i);
        } else if (lowerCoreIn(mask, prio, self)) |i| {
            platform.switching.kick(i);
            kicked_mask |= @as(u64, 1) << @intCast(i);
        }
    }
    return kicked_mask != 0;
}

fn lowerCoreIn(mask: u64, prio: u8, self: usize) ?usize {
    var best: ?usize = null;
    var best_prio: u8 = prio;
    for (0..max_cores) |i| {
        if (i == self or (mask >> @intCast(i)) & 1 == 0) continue;
        if (i > 0 and !@atomicLoad(bool, &smp_on, .acquire)) break;
        const c = coreAt(i);
        if (!@atomicLoad(bool, &c.online, .acquire)) continue;
        const p = @atomicLoad(*Task, &c.current, .monotonic).priority;
        if (p < best_prio) {
            best = i;
            best_prio = p;
        }
    }
    return best;
}

// An idle core that may run what became ready (its
// affinity, isolated cores): the first. (Preferring a
// task's last core measured slower: waking that core costs
// more than its warm cache saves.)
fn idleCoreIn(mask: u64, self: usize) ?usize {
    for (0..max_cores) |i| {
        if (i == self or (mask >> @intCast(i)) & 1 == 0) continue;
        if (i > 0 and !@atomicLoad(bool, &smp_on, .acquire)) break;
        const c = coreAt(i);
        if (!@atomicLoad(bool, &c.online, .acquire)) continue;
        if (@atomicLoad(*Task, &c.current, .monotonic) == &c.idle) return i;
    }
    return null;
}

// Only the front task reads the keyboard; the others wait
// if they try. It is the first task (the command
// interpreter and what it runs) unless a program's tab is
// in front (api.zig); a program's threads count as it.
var front_id: u32 = 0; // 0: the first task

pub fn setFront(id: u32) void {
    front_id = id;
    if (front_hook) |f| f();
}

// Called when the front changes (console.zig: a task waiting
// for keys may now take them)
pub var front_hook: ?*const fn () void = null;

pub fn foreground() bool {
    const f = if (front_id == 0) tasks[0].id else front_id;
    return cur().id == f or (cur().thread and cur().main_id == f);
}

fn idleLoop(_: usize) callconv(.c) noreturn {
    while (true) platform.switching.idle();
}

// READY QUEUES

fn enqueue(t: *Task) void {
    enqueueAt(t, false);
}

// first: ahead of its priority's others (the new owner of
// the kernel or storage lock: everyone waits for it)
fn enqueueAt(t: *Task, first: bool) void {
    if (t.policy == .deadline) renewDeadline(t, platform.clock.nanos());
    t.state = .ready;
    t.next = null;
    t.wait_obj = null;
    const p = t.priority;
    if (first and heads[p] != null) {
        t.next = heads[p];
        heads[p] = t;
    } else {
        if (tails[p]) |tail| tail.next = t else heads[p] = t;
        tails[p] = t;
    }
    ready_bits |= @as(u32, 1) << @intCast(p);
    kick_wanted = true;
    const a = allowed(t);
    if (@popCount(a) == 1) {
        kick_pinned |= a;
    } else {
        kick_mask |= a;
    }
    kick_prio = @max(kick_prio, p);
}

// The first ready task of the highest priority this
// core may run: not one still on another core's stack
// (on_cpu), not one pinned to another core
fn dequeueBest(c: *Core) ?*Task {
    var bits = ready_bits;
    while (bits != 0) {
        const p: u5 = @intCast(31 - @clz(bits));
        bits &= ~(@as(u32, 1) << p);
        var prev: ?*Task = null;
        var at = heads[p];
        if (p == deadline_priority) {
            // The earliest deadline this core may run
            var best: ?*Task = null;
            var best_prev: ?*Task = null;
            while (at) |t| : (at = t.next) {
                const pinned_elsewhere = (allowed(t) >> @intCast(indexOf(c))) & 1 == 0;
                if (!((t.on_cpu and t != c.current) or pinned_elsewhere)) {
                    if (best == null or edfKey(t) < edfKey(best.?)) {
                        best = t;
                        best_prev = prev;
                    }
                }
                prev = t;
            }
            if (best) |t| {
                if (best_prev) |pr| pr.next = t.next else heads[p] = t.next;
                if (tails[p] == t) tails[p] = best_prev;
                if (heads[p] == null) ready_bits &= ~(@as(u32, 1) << p);
                t.next = null;
                return t;
            }
            continue;
        }
        while (at) |t| : (at = t.next) {
            const pinned_elsewhere = (allowed(t) >> @intCast(indexOf(c))) & 1 == 0;
            if ((t.on_cpu and t != c.current) or pinned_elsewhere) {
                prev = t;
                continue;
            }
            if (prev) |pr| pr.next = t.next else heads[p] = t.next;
            if (tails[p] == t) tails[p] = prev;
            if (heads[p] == null) ready_bits &= ~(@as(u32, 1) << p);
            t.next = null;
            return t;
        }
    }
    return null;
}

fn remove(t: *Task) void {
    const p = t.priority;
    var prev: ?*Task = null;
    var at = heads[p];
    while (at) |x| : (at = x.next) {
        if (x == t) {
            if (prev) |pr| pr.next = x.next else heads[p] = x.next;
            if (tails[p] == x) tails[p] = prev;
            if (heads[p] == null) ready_bits &= ~(@as(u32, 1) << @intCast(p));
            x.next = null;
            return;
        }
        prev = x;
    }
}

fn bestReadyPriority() ?u8 {
    if (ready_bits == 0) return null;
    return @intCast(31 - @clz(ready_bits));
}

// A task that became ready outranks the running one: switch as
// soon as ZDOS returns to the program
fn requestSwitch() void {
    if (bestReadyPriority()) |best| {
        const c = me();
        if (best > c.current.priority or (best == deadline_priority and c.current.priority == deadline_priority and earliestReady(c) < edfKey(c.current))) c.switch_pending = true;
    }
}

// SWITCHING

// Called by the platform, interrupts off: from the timer
// (this core's deadline), a device's interrupt or a kick,
// or when a task gives the CPU up (yield). sp:
// the interrupted task's saved state; in_program: it was
// running its program's code (signals may be delivered
// before it resumes). Returns the state to resume: the same
// task's or another's.
fn switchPoint(sp: usize, why: Why, in_program: bool) usize {
    _ = disable(); // held until finishSwitch, once this core is off the old stack
    const c = me();
    const prev = c.current;
    prev.sp = sp;
    if (!smp) {
        // No finish callback: the last switch's old task is off this core now
        if (c.leaving) |l| l.on_cpu = false;
        c.leaving = null;
    }
    const now = platform.clock.nanos();
    account(c, now);
    if (cooperative) catchUp(now);
    // A deadline task out of budget waits for its next period
    // (not while it holds the kernel or storage lock:
    // everyone would wait with it)
    if (prev.policy == .deadline and prev != &c.idle and prev.state == .running and prev.dl_left <= 0 and
        kernel.owner != prev and storage_m.owner != prev)
    {
        prev.state = .sleeping;
        prev.wake_at = prev.dl_start + prev.dl_period;
        prev.woke = .none;
        prev.preempted_in_program = in_program and why != .yield;
    }
    if (why == .yield) {
        c.switch_pending = false; // given up now: whatever was pending is decided below
        prev.preempted_in_program = false;
        if (prev.resume_sp != 0) {
            // Signals handled (signalEntry): back to where its program was
            prev.sp = prev.resume_sp;
            prev.resume_sp = 0;
            prev.preempted_in_program = true;
        }
    } else {
        prev.preempted_in_program = in_program;
        if (why == .tick) {
            if (c == &core0) if (tick_hook) |h| h();
            timerWork(now);
        }
    }
    if (prev.state == .running) {
        if (why != .yield) {
            // Not to run here (its affinity changed): off this core at once
            const banned = prev != &c.idle and (allowed(prev) >> @intCast(indexOf(c))) & 1 == 0;
            const best = bestReadyPriority() orelse if (banned) prev.priority else return resumeHere(c, prev, now);
            const earlier = best == deadline_priority and prev.priority == deadline_priority and earliestReady(c) < edfKey(prev);
            const wanted = banned or prev == &c.idle or best > prev.priority or earlier or (why == .tick and best == prev.priority and now >= c.slice_end and prev.policy == .rr and kernel.owner != prev);
            if (!wanted) return resumeHere(c, prev, now);
            if (prev != &c.idle and !in_program and !preemptible) {
                // Inside ZDOS: when it returns to the program (leaving)
                c.switch_pending = true;
                arm(c, now);
                return prev.sp;
            }
        }
        if (prev != &c.idle) enqueue(prev);
    }
    const next = dequeueBest(c) orelse &c.idle;
    if (next == prev) {
        prev.state = .running;
        c.slice_end = now + slice_ns;
        return resumeHere(c, prev, now);
    }
    switchTo(c, next, now);
    arm(c, now);
    return resumeOf(next);
}

// ZDOS's own code may be switched away from (step
// 3 of docs/REALTIME.md): its state is each
// task's own (world), its spinlocks keep
// interrupts off, and the kernel lock is a mutex
// that hands priority on
const preemptible = !cooperative;

fn resumeHere(c: *Core, t: *Task, now: u64) usize {
    arm(c, now);
    return resumeOf(t);
}

// The time since the last look goes to whoever ran on this core
fn account(c: *Core, now: u64) void {
    if (c.accounted == 0 or now <= c.accounted) {
        c.accounted = now;
        return;
    }
    const passed = now - c.accounted;
    c.accounted = now;
    const t = c.current;
    if (t == &c.idle) {
        idle_ns += passed;
    } else {
        t.cpu_ns += passed;
        t.cpu_ms = t.cpu_ns / 1_000_000;
        if (t.policy == .deadline) t.dl_left -= @intCast(@min(passed, std.math.maxInt(i64)));
    }
}

// This core's next timer interrupt: the earliest deadline of
// the tasks that last ran here, the running task's turn if
// another of its priority waits, core 0's housekeeping, else
// (an isolated core with nothing due) none
fn arm(c: *Core, now: u64) void {
    if (comptime !@hasDecl(platform.switching, "armTimer")) return;
    const idx = indexOf(c);
    var at: u64 = std.math.maxInt(u64);
    if (idx == 0) {
        at = now + housekeeping_ns;
    } else if ((isolated >> @intCast(idx)) & 1 == 0) {
        at = now + accounting_ns;
    }
    const t = c.current;
    // Not while it holds the kernel lock: its turn ends as
    // it gives the lock back (leaveKernel)
    if (t != &c.idle and t.policy == .rr and kernel.owner != t) {
        if (bestReadyPriority()) |best| {
            if (best == t.priority) at = @min(at, c.slice_end);
        }
    }
    if (t != &c.idle and t.policy == .deadline) at = @min(at, now + @as(u64, @intCast(@max(t.dl_left, 0))));
    for (&tasks) |*x| {
        if (x.state == .free or x.state == .zombie) continue;
        const my_core = x.last_core == idx or (allowed(x) == (@as(u64, 1) << @intCast(idx)));
        if (!my_core and !(idx == 0 and !onlineCore(x.last_core))) continue;
        switch (x.state) {
            .sleeping, .blocked, .io => if (x.wake_at != 0) {
                at = @min(at, x.wake_at);
            },
            else => {},
        }
        if (x.timer_at != 0) at = @min(at, x.timer_at);
    }
    platform.switching.armTimer(if (at == std.math.maxInt(u64)) null else at);
}

fn onlineCore(i: u8) bool {
    if (i == 0) return true;
    if (i >= max_cores or !smp_on) return false;
    return @atomicLoad(bool, &coreAt(i).online, .acquire);
}

// The platform, on the new task's stack:
// the old one may run elsewhere now
fn finishSwitch() void {
    if (@hasDecl(platform.memory, "syncTlb")) platform.memory.syncTlb(coreIndex()); // guards set meanwhile
    const c = me();
    if (c.leaving) |l| l.on_cpu = false;
    c.leaving = null;
    unlockSched();
}

fn switchTo(c: *Core, next: *Task, now: u64) void {
    c.switch_pending = false;
    const prev = c.current;
    c.leaving = prev;
    c.current = next;
    next.state = .running;
    next.on_cpu = true;
    next.last_core = @intCast(indexOf(c));
    c.slice_end = now + slice_ns;
    if (next != &c.idle) arch.setThreadPointer(next.thread_pointer);
    reapDetached();
}

// The state to resume a task at: signals to handle first if it
// was preempted in its program's code. The call goes well below
// the saved state: if t is the task interrupted just now, the
// switching code's own calls are still
// running on the stack right under it.
const signal_frame_gap = 4096;

fn resumeOf(t: *Task) usize {
    if (platform.has_switching and t != &me().idle and t.preempted_in_program and deliverable(t)) {
        t.preempted_in_program = false;
        t.sp = platform.switching.pushCall(t.sp - signal_frame_gap, &signalEntry, t.sp);
    }
    return t.sp;
}

fn signalEntry(saved: usize) callconv(.c) noreturn {
    api.deliverSignals();
    cur().resume_sp = saved;
    yieldNow(); // switchPoint resumes `saved`
    unreachable;
}

// Cooperative: the time since the last look goes to whoever ran
// it (account), the timers' work is done at each switch
fn catchUp(now: u64) void {
    if (tick_hook) |h| h();
    timerWork(now);
}

// Called with the timer's work (interrupts off):
// the network core's news
pub var tick_hook: ?*const fn () void = null;

// At a timer interrupt (any core's: each arms for the tasks
// that last ran there), at each switch (cooperative):
// sleepers and deadlines, timers
fn timerWork(now: u64) void {
    for (&tasks) |*t| {
        switch (t.state) {
            .free, .zombie => continue,
            .sleeping => if (now >= t.wake_at) {
                t.woke = .timeout;
                enqueue(t);
            },
            .blocked, .io => if (t.wake_at != 0 and now >= t.wake_at) {
                t.woke = .timeout;
                enqueue(t);
            },
            else => {},
        }
        if (t.timer_at != 0 and now >= t.timer_at) {
            if (t.timer_interval == 0) {
                t.timer_at = 0;
            } else {
                // Missed periods are one signal, as POSIX's overruns
                const late = now - t.timer_at;
                t.timer_at += (late / t.timer_interval + 1) * t.timer_interval;
            }
            if (t.timer_sig != 0) post(t, t.timer_sig);
        }
    }
}

// Ended tasks, their stacks and slots back; joinable threads
// stay until joined. Not one still on a core (on_cpu): a core
// runs it, or the switch away from it still runs on its stack
// (UEFI's firmware overwrites freed memory at once).
// It goes at a later switch.
fn reapDetached() void {
    for (&tasks) |*t| {
        if (t.state == .zombie and !t.on_cpu and (!t.thread or t.detached)) free(t);
    }
}

// ENDED TASKS' RECORDS

pub const max_ended = 64;

const EndedRecord = struct {
    used: bool = false,
    id: u32 = 0,
    parent: u32 = 0,
    code: u8 = 0,
    signal: u8 = 0,
    seq: u64 = 0, // when it was kept: the oldest is overwritten
};

var ended_list: [max_ended]EndedRecord = [_]EndedRecord{.{}} ** max_ended;
var ended_seq: u64 = 0;

// A free record, else the oldest one
fn keepEnded(t: *const Task) void {
    var slot = &ended_list[0];
    for (&ended_list) |*r| {
        if (!r.used) {
            slot = r;
            break;
        }
        if (r.seq < slot.seq) slot = r;
    }
    ended_seq += 1;
    slot.* = .{ .used = true, .id = t.id, .parent = t.parent, .code = t.exit_code, .signal = t.term_signal, .seq = ended_seq };
}

fn recordOf(id: u32) ?*EndedRecord {
    for (&ended_list) |*r| {
        if (r.used and r.id == id) return r;
    }
    return null;
}

// A child of the current task that
// ended (any, or id), taken off the list
fn takeEnded(id: ?u32) ?Ended {
    var best: ?*EndedRecord = null;
    for (&ended_list) |*r| {
        if (!r.used or r.parent != cur().id) continue;
        if (id) |want| if (r.id != want) continue;
        if (best == null or r.seq < best.?.seq) best = r;
    }
    const r = best orelse return null;
    r.used = false;
    return .{ .id = r.id, .code = r.code, .signal = r.signal };
}

// Whether the parent wants records of its children's ends
fn parentKeepsRecords(parent: *const Task) bool {
    const p = programOf(parent) orelse return true;
    return p.sig_ignored & (bit(Sig.chld) | bit(Sig.no_child_wait)) == 0;
}

// Its slot at once, its stack later (freeEnded): free runs with the
// scheduler's lock held, and the page allocator's lock may be held
// long by another core's search: every core's switches would wait
fn free(t: *Task) void {
    if (t.stack) |s| {
        if (ended_count < ended_stacks.len) {
            ended_stacks[ended_count] = .{ .stack = s, .bytes = t.stack_bytes };
            ended_count += 1;
        } else freeStack(s, t.stack_bytes); // none left: at once
    }
    t.* = .{};
}

const EndedStack = struct { stack: [*]align(4096) u8, bytes: usize };
var ended_stacks: [2 * max_tasks]EndedStack = undefined;
var ended_count: usize = 0; // under the scheduler's lock

// Outside the scheduler, interrupts on (leaving, allocStack): the
// stacks of tasks freed since
pub fn freeEnded() void {
    if (@atomicLoad(usize, &ended_count, .monotonic) == 0) return;
    var taken: [2 * max_tasks]EndedStack = undefined;
    const was = disable();
    const n = ended_count;
    @memcpy(taken[0..n], ended_stacks[0..n]);
    ended_count = 0;
    restore(was);
    for (taken[0..n]) |e| freeStack(e.stack, e.bytes);
}

// A stack with a guard page below where the platform
// has them (metal): running off its end faults instead
// of overwriting what lies there
pub fn allocStack(bytes: usize) ?[*]align(4096) u8 {
    freeEnded(); // the ended ones' first: their memory may be needed
    if (@hasDecl(platform.memory, "allocStack")) return platform.memory.allocStack(bytes);
    return platform.memory.allocPages(bytes / 4096, false);
}

pub fn freeStack(stack: [*]align(4096) u8, bytes: usize) void {
    if (@hasDecl(platform.memory, "freeStack")) return platform.memory.freeStack(stack, bytes);
    platform.memory.freePages(stack, bytes / 4096);
}

// Every ZDOS function a program calls returns through here
// (api.zig), the kernel lock given back: a switch wanted
// meanwhile happens now, signals are handled
pub fn leaving() void {
    if (!running) return;
    const was = disable();
    const c = me();
    if (cooperative) {
        // Woken sleepers, and the turn of the same priority's next task
        const now = platform.clock.nanos();
        account(c, now);
        catchUp(now);
        if (bestReadyPriority()) |best| {
            if (best > c.current.priority or (best == c.current.priority and now >= c.slice_end and c.current.policy != .fifo)) c.switch_pending = true;
        }
    }
    const pending = c.switch_pending;
    restore(was);
    if (pending) yieldNow();
    if (deliverable(cur())) api.deliverSignals();
    freeEnded();
}

// Gives the CPU up: the current task's
// state says why (running: just a turn)
fn yieldNow() void {
    if (platform.has_switching) platform.switching.yield();
}

// Gives the CPU up for a wait whose state is set (interrupts
// off since `was`). The kernel lock goes
// for the wait and is taken again after it.
fn blockNow(was: usize) void {
    const held = kernel.owner == cur();
    if (held) {
        handOver(&kernel);
        recompute(cur());
    }
    restore(was);
    yieldNow();
    if (held) lockMutex(&kernel);
}

// THE KERNEL LOCK

var kernel: Mutex = .{ .used = true };

// Entering ZDOS from a program (api.zig):
// true if taken now (false: no switching, or
// this task holds it already)
pub fn enterKernel() bool {
    if (!running or kernel.owner == cur()) return false;
    lockMutex(&kernel);
    return true;
}

pub fn leaveKernel() void {
    if (!running or kernel.owner != cur()) return;
    const was = disable();
    handOver(&kernel);
    recompute(cur());
    requestSwitch();
    // Its turn ended while it held the lock (switching):
    const c = me();
    if (c.current.policy == .rr and platform.clock.nanos() >= c.slice_end) {
        if (bestReadyPriority()) |best| {
            if (best == c.current.priority) c.switch_pending = true;
        }
    }
    restore(was);
}

// Before a program's code runs (loader.zig):
// the lock goes if held; true then
pub fn dropKernel() bool {
    if (!running or kernel.owner != cur()) return false;
    leaveKernel();
    return true;
}

// WORK FOR CORE 0 ONLY (PLATFORM.CORE0_ENTER: BIOS CALLS)

// The task moves to core 0 (pinned there meanwhile); its cores
// before, or 0 if it was there already
fn toCoreZero() u64 {
    if (!smp_on or coreIndex() == 0) return 0;
    const t = cur();
    const was = disable();
    const saved = t.cores;
    t.cores = 1;
    restore(was);
    while (coreIndex() != 0) yieldNow();
    return saved;
}

fn backFromCoreZero(saved: u64) void {
    if (saved == 0) return;
    const was = disable();
    cur().cores = saved;
    restore(was);
}

// THE STORAGE LOCK
// File systems and disks (platform.storage, platform.disk)
// are one task's at a time, under a mutex of their own
// taken inside the kernel lock. Its holder gives the kernel
// lock up while it waits for its device (ioWait), so the
// rest of ZDOS goes on meanwhile. Waiting for it drops the
// kernel lock too (blockNow): the order is always kernel
// lock, then storage. Recursive: a storage error printed to
// a redirected output writes a file.

var storage_m: Mutex = .{ .used = true };
var storage_depth: u32 = 0;

fn lockStorage() void {
    if (!running) return;
    if (storage_m.owner == cur()) {
        storage_depth += 1;
        return;
    }
    lockMutex(&storage_m);
    storage_depth = 1;
}

fn unlockStorage() void {
    if (!running or storage_m.owner != cur()) return;
    storage_depth -= 1;
    if (storage_depth != 0) return;
    const was = disable();
    handOver(&storage_m);
    recompute(cur());
    requestSwitch();
    restore(was);
}

// For fs.zig: changes to the drive table while no storage call runs
pub fn storageLock() void {
    lockStorage();
}

pub fn storageUnlock() void {
    unlockStorage();
}

// DEVICE WAITS (PLATFORM.IO)

// A driver waits for its device: until the interrupt (ev.count
// no longer seen) or max_us. The kernel lock stays: no other
// task enters ZDOS meanwhile, but they run their programs.
fn ioWait(ev: *platform.IoEvent, seen: u32, max_us: u32) u32 {
    if (!running or cur() == &me().idle) {
        platform.clock.sleep(1);
        return 1000;
    }
    const us: u32 = @max(1, max_us);
    const was = disable();
    if (ev.count != seen) {
        restore(was);
        return 0;
    }
    cur().state = .io;
    cur().wait_obj = ev;
    cur().woke = .none;
    cur().wake_at = platform.clock.nanos() + @as(u64, us) * 1000;
    // A storage call's wait: the kernel lock goes meanwhile (the
    // storage lock stays, keeping file
    // systems and disks this task's)
    const drop = kernel.owner == cur() and storage_m.owner == cur();
    if (drop) {
        handOver(&kernel);
        recompute(cur());
    }
    restore(was);
    yieldNow();
    if (drop) lockMutex(&kernel);
    return if (cur().woke == .timeout) us else 20;
}

// From a device's interrupt handler (interrupts off)
fn ioSignal(ev: *platform.IoEvent) void {
    const was = disable(); // other cores run the scheduler too
    defer restore(was);
    ev.count +%= 1;
    ev.seen_interrupt = true;
    for (&tasks) |*t| {
        if (t.state == .io and t.wait_obj == @as(*const anyopaque, ev)) {
            t.woke = .object;
            enqueue(t);
        }
    }
}

// WAITING FOR OBJECTS

// Waits for obj (wake/wakeOne), until ms (null: no deadline);
// interrupts are off since `was`. With interruptible, a signal
// ends it too. Why it ended.
fn waitFor(was: usize, obj: *const anyopaque, ms: ?u32, interruptible: bool) Wake {
    if (interruptible and deliverable(cur())) {
        restore(was);
        return .signal;
    }
    cur().state = .blocked;
    cur().wait_obj = obj;
    cur().woke = .none;
    cur().interruptible = interruptible;
    cur().wake_at = if (ms) |m| deadlineIn(m) else 0;
    blockNow(was);
    cur().interruptible = false;
    return cur().woke;
}

// Wakes every task waiting for obj
pub fn wake(obj: *const anyopaque) void {
    if (!running) return;
    const was = disable();
    for (&tasks) |*t| {
        if (t.state == .blocked and t.wait_obj == obj) {
            t.woke = .object;
            enqueue(t);
        }
    }
    requestSwitch();
    restore(was);
}

// wake from a core outside the scheduler (allowOutsideWakes):
// it has no current task to switch from, so an idle core is
// told, else core 0 looks at once (as at its tick: a higher
// priority runs there now)
pub fn wakeFromOutside(obj: *const anyopaque) void {
    if (!running) return;
    const was = disable();
    var woke = false;
    for (&tasks) |*t| {
        if (t.state == .blocked and t.wait_obj == obj) {
            t.woke = .object;
            enqueue(t);
            woke = true;
        }
    }
    const pinned = kick_pinned;
    const mask = kick_mask;
    const prio = kick_prio;
    kick_wanted = false;
    kick_pinned = 0;
    kick_mask = 0;
    kick_prio = 0;
    restore(was);
    // No core of the scheduler is this one: none is skipped; when
    // nobody was kicked, core 0 looks at once (as before)
    if (woke and !kickCore(pinned, mask, prio, max_cores)) {
        if (@hasDecl(platform.switching, "kick")) platform.switching.kick(0);
    }
}

// Wakes the highest of the tasks waiting for obj; false if none waits
fn wakeOne(obj: *const anyopaque) bool {
    var best: ?*Task = null;
    for (&tasks) |*t| {
        if (t.state == .blocked and t.wait_obj == obj and (best == null or t.priority > best.?.priority)) best = t;
    }
    const b = best orelse return false;
    b.woke = .object;
    enqueue(b);
    requestSwitch();
    return true;
}

// For pipes and the like (stdio.zig): waits until wake(obj), a
// signal, or ms (null: none). False if a signal ended it.
pub fn waitObject(obj: *const anyopaque, ms: ?u32) bool {
    if (!running) return true;
    return waitFor(disable(), obj, ms, true) != .signal;
}

// waitObject, unless counter has moved on from seen: another
// core's news since the caller looked (it wakes obj from an
// interrupt here, maybe before the wait began)
pub fn waitObjectSince(obj: *const anyopaque, ms: ?u32, counter: *const std.atomic.Value(u32), seen: u32) bool {
    if (!running) return true;
    const was = disable();
    if (counter.load(.acquire) != seen) {
        restore(was);
        return true;
    }
    return waitFor(was, obj, ms, true) != .signal;
}

// Wakes every task waiting for an object `is` says yes to
pub fn wakeWhere(is: *const fn (obj: *const anyopaque) bool) void {
    if (!running) return;
    const was = disable();
    for (&tasks) |*t| {
        if (t.state == .blocked and t.wait_obj != null and is(t.wait_obj.?)) {
            t.woke = .object;
            enqueue(t);
        }
    }
    requestSwitch();
    restore(was);
}

// WHAT TASKS DO

// Sleeps ms milliseconds; other tasks run meanwhile. A signal
// ends it early: false then.
// Without switching, the platform's sleep.
pub fn sleep(ms: u32) bool {
    if (!running) {
        platform.clock.sleep(ms);
        return true;
    }
    return sleepUntil(deadlineIn(ms));
}

// nanos() ms milliseconds from now
fn deadlineIn(ms: u32) u64 {
    return platform.clock.nanos() + @as(u64, ms) * 1_000_000;
}

// Sleeps until nanos() reaches at (to
// the timer's precision: the core's
// deadline timer, not a tick); false if
// a signal ended it first
pub fn sleepUntil(at: u64) bool {
    if (!running) {
        while (platform.clock.nanos() < at) std.atomic.spinLoopHint();
        return true;
    }
    const was = disable();
    if (deliverable(cur())) {
        restore(was);
        return false;
    }
    if (platform.clock.nanos() >= at) {
        restore(was);
        return true;
    }
    cur().state = .sleeping;
    cur().wake_at = at;
    cur().interruptible = true;
    cur().woke = .none;
    blockNow(was);
    cur().interruptible = false;
    return cur().woke != .signal;
}

// For ZDOS's own long waits that a signal doesn't
// end (the keyboard): the task's signals handled
// here, as on returning to its program (the
// kernel lock given up meanwhile); a fatal one
// ends the program from here
pub fn handleSignals() void {
    if (!running or !deliverable(cur())) return;
    const held = dropKernel();
    api.deliverSignals();
    if (held) _ = enterKernel();
}

// Sleeps ms milliseconds whatever comes
// (ZDOS's own polling: the keyboard)
pub fn nap(ms: u32) void {
    if (!running) return platform.clock.sleep(ms);
    const was = disable();
    cur().state = .sleeping;
    cur().wake_at = deadlineIn(ms);
    cur().interruptible = false;
    blockNow(was);
}

// Lets tasks of the same priority run (sched_yield)
pub fn yield() void {
    if (!running) return;
    const held = dropKernel();
    yieldNow();
    if (held) _ = enterKernel();
}

pub const SpawnError = error{ NotSupported, NotFound, NotProgram, OutOfMemory, TooMany, InvalidArgument };

pub const SpawnOptions = struct {
    input: stdio.Input = .none,
    output: stdio.Output = .screen,
    errout: stdio.Output = .screen,
    priority: ?u8 = null, // the caller's
    policy: ?Policy = null, // the caller's
    term: ?*Term = null, // its console (null: the caller's)
    env: ?[]const u8 = null, // its own variables (env.initOwnStack's block); null: the global ones
};

// What a new task or thread gets of its starter's policy: a
// deadline one's children run round robin at its priority from
// before (as Linux's reset-on-fork)
fn inheritable(t: *const Task) Policy {
    return if (t.policy == .deadline) .rr else t.policy;
}

fn startPriority(t: *const Task) u8 {
    return if (t.policy == .deadline) t.dl_saved_prio else t.base_priority;
}

fn freeTask() ?*Task {
    for (&tasks) |*t| {
        if (t.state == .free) return t;
    }
    return null;
}

// A number no task and no record has (after the counter wrapped around)
fn newId() u32 {
    while (true) {
        const id = next_id;
        next_id +%= 1;
        if (next_id == 0 or next_id == any_child) next_id = 2;
        if (byId(id) == null and recordOf(id) == null) return id;
    }
}

// Starts the program at path with args as a new task;
// returns its id. Its standard input and output are
// opts' (references taken here, released when it ends);
// it gets the caller's current drive and the global
// variables, or opts.env's.
pub fn spawn(path: []const u8, args: []const u8, opts: SpawnOptions) SpawnError!u32 {
    if (!platform.has_switching or !running) return error.NotSupported;
    var found: loader.Found = undefined;
    if (!loader.find(path, &found)) return error.NotFound;
    if (found.kind != .program) return error.NotProgram;
    var vars: env.Stack = .{};
    env.initStack(&vars);
    if (opts.env) |block| env.initOwnStack(&vars, block) catch |err| return switch (err) {
        error.OutOfSpace => error.OutOfMemory,
        else => error.InvalidArgument,
    };
    errdefer env.releaseStack(&vars);
    const t = freeTask() orelse return error.TooMany;
    const stack = allocStack(stack_size) orelse return error.OutOfMemory;
    const prio = opts.priority orelse startPriority(cur());
    t.* = .{
        .id = newId(),
        .base_priority = prio,
        .policy = opts.policy orelse inheritable(cur()),
        .cores = cur().cores,
        .priority = prio,
        .parent = cur().id,
        .stack = stack,
        .found = found,
        .own_input = opts.input,
        .own_output = opts.output,
        .own_errout = opts.errout,
        .term = opts.term orelse cur().term,
    };
    if (t.term) |tm| tm.attach();
    stdio.retainInput(opts.input);
    stdio.retainOutput(opts.output);
    stdio.retainOutput(opts.errout);
    if (world().program) |p| t.cwds.inherit(&p.cwds);
    t.ids = perm.current().*;
    t.args_len = @min(args.len, t.args_buf.len);
    @memcpy(t.args_buf[0..t.args_len], args[0..t.args_len]);
    const base = std.fs.path.basenameWindows(found.path.slice());
    const n = @min(base.len, t.name_buf.len - 1);
    @memcpy(t.name_buf[0..n], base[0..n]);
    t.world = .{ .drive = world().drive, .input = opts.input, .output = opts.output, .errout = opts.errout, .env = vars };
    t.sp = platform.switching.newContext(@intFromPtr(stack) + stack_size, &taskEntry, @intFromPtr(t));
    const was = disable();
    enqueue(t);
    requestSwitch();
    restore(was);
    return t.id;
}

fn taskEntry(arg: usize) callconv(.c) noreturn {
    const t: *Task = @ptrFromInt(arg);
    _ = enterKernel();
    const code: u8 = switch (loader.runFound(&t.found, t.args_buf[0..t.args_len])) {
        .exited => |c| c,
        else => 255,
    };
    exit(code);
}

// The current task (not a thread) ends: what it holds goes, its
// parent may collect the code. The kernel lock is held.
fn exit(code: u8) noreturn {
    const t = cur();
    stdio.releaseInput(t.own_input);
    stdio.releaseOutput(t.own_output);
    stdio.releaseOutput(t.own_errout);
    t.own_input = .none;
    t.own_output = .screen;
    t.own_errout = .screen;
    t.cwds.release();
    if (t.term) |tm| tm.detach();
    t.term = null;
    env.releaseStack(&t.world.env);
    const was = disable();
    t.exit_code = code;
    releaseAll(t);
    // Its children have nobody to wait for them now: no records
    for (&tasks) |*c| {
        if (c.state != .free and c.parent == t.id and c != t and !c.thread) {
            c.detached = true;
            c.parent = 0;
        }
    }
    for (&ended_list) |*r| {
        if (r.used and r.parent == t.id) r.used = false;
    }
    // Its own record, for its parent; the task itself goes (reapDetached)
    if (!t.detached) {
        if (byId(t.parent)) |p| {
            if (parentKeepsRecords(p)) keepEnded(t);
            post(p, Sig.chld);
        }
    }
    for (&tasks) |*w| {
        if (w.state == .waiting and (w.waits_for == t.id or (w.waits_for == any_child and w.id == t.parent))) enqueue(w);
    }
    t.state = .zombie;
    restore(was);
    while (true) yieldNow();
}

pub const WaitError = error{ InvalidArgument, NotSupported, Interrupted, NoChild };

// Until task id (one this task started) has ended; its exit code
pub fn wait(id: u32) WaitError!u8 {
    return (try waitEnded(id)).code;
}

// The same, with the signal that ended it (0: none).
// InvalidArgument: not a child of this task, or ended with no
// record left (overwritten, or not kept).
pub fn waitEnded(id: u32) WaitError!Ended {
    if (!running) return error.NotSupported;
    while (true) {
        const was = disable();
        if (takeEnded(id)) |e| {
            restore(was);
            return e;
        }
        const t = byId(id) orelse {
            restore(was);
            return error.InvalidArgument;
        };
        if (t.parent != cur().id or t == cur() or t.thread or t.state == .zombie) {
            restore(was);
            return error.InvalidArgument;
        }
        if (!waitChild(was, id)) return error.Interrupted;
    }
}

// Waiting for a child's end (interrupts
// off since was); false if a signal came
fn waitChild(was: usize, id: u32) bool {
    if (deliverable(cur())) {
        restore(was);
        return false;
    }
    cur().state = .waiting;
    cur().waits_for = id;
    cur().interruptible = true;
    cur().woke = .none;
    blockNow(was);
    cur().interruptible = false;
    return cur().woke != .signal;
}

pub const Ended = struct { id: u32, code: u8, signal: u8 };

// Any task this one started that ended (collected: freed); null
// if none has and `hang` is false. NoChild: it has none.
pub fn waitAny(hang: bool) WaitError!?Ended {
    if (!running) return error.NoChild;
    while (true) {
        const was = disable();
        if (takeEnded(null)) |e| {
            restore(was);
            return e;
        }
        var children = false;
        for (&tasks) |*t| {
            if (t.state == .free or t.state == .zombie or t.thread or t.parent != cur().id or t == cur()) continue;
            children = true;
        }
        if (!children) {
            restore(was);
            return error.NoChild;
        }
        if (!hang) {
            restore(was);
            return null;
        }
        if (!waitChild(was, any_child)) return error.Interrupted;
    }
}

// Whether task id has ended (and with what code), without
// waiting or taking its record
pub fn ended(id: u32) ?u8 {
    const r = recordOf(id) orelse return null;
    return r.code;
}

pub fn byId(id: u32) ?*Task {
    for (&tasks) |*t| {
        if (t.state != .free and t.id == id) return t;
    }
    return null;
}

// The user a task runs as: its running
// program's (or, before that, its own)
fn idsOf(t: *Task) *const perm.Ids {
    return if (t.world.program) |p| &p.ids else &t.ids;
}

// May the running program change task id (its priority)?
// Its own tasks, or any as root, as with signals; null if
// there is no such task
pub fn mayControl(id: u32) ?bool {
    const t = byId(id) orelse return null;
    return perm.maySignal(idsOf(t));
}

// A task's own priority (0-31); what it inherits stays on top
pub fn setPriority(id: u32, prio: u8) bool {
    if (prio >= priorities) return false;
    const t = byId(id) orelse return false;
    const was = disable();
    t.base_priority = prio;
    recompute(t);
    requestSwitch();
    restore(was);
    return true;
}

// THREADS

pub const ThreadEntry = *const fn (arg: usize) callconv(abi.cc) usize;

// A thread of the running program: entry(arg) as a task of
// its own (the caller's priority unless prio is given), on a
// stack of stack_bytes (0: 64 KiB). It ends when entry
// returns or with threadExit; its program's end ends it too.
pub fn threadCreate(entry: usize, arg: usize, stack_bytes: usize, prio: ?u8) SpawnError!u32 {
    return threadCreateOn(entry, arg, stack_bytes, prio, any_core);
}

fn threadCreateOn(entry: usize, arg: usize, stack_bytes: usize, prio: ?u8, core: u8) SpawnError!u32 {
    if (!platform.has_switching or !running) return error.NotSupported;
    const w = world();
    const program = w.program orelse return error.NotSupported;
    const bytes = std.mem.alignForward(usize, if (stack_bytes == 0) platform.config.stacks.thread else @max(stack_bytes, 16 * 1024), 4096);
    if (bytes > max_thread_stack) return error.OutOfMemory;
    const t = freeTask() orelse return error.TooMany;
    const stack = allocStack(bytes) orelse return error.OutOfMemory;
    const p = prio orelse startPriority(cur());
    t.* = .{
        .id = newId(),
        .base_priority = p,
        .priority = p,
        .parent = cur().id,
        .stack = stack,
        .stack_bytes = bytes,
        .thread = true,
        .cores = if (core == any_core) cur().cores else @as(u64, 1) << @intCast(core),
        .detached = core != any_core,
        .main_id = if (cur().thread) cur().main_id else cur().id,
        .thread_program = program,
        .thread_entry = entry,
        .thread_arg = arg,
        .sig_mask = cur().sig_mask,
        .policy = inheritable(cur()),
        .term = cur().term,
    };
    t.name_buf = cur().name_buf;
    t.world = .{
        .program = program,
        .input = w.input,
        .output = w.output,
        .errout = w.errout,
        .depth = w.depth,
        .drive = w.drive,
    };
    env.initStackLike(&t.world.env, &w.env);
    t.sp = platform.switching.newContext(@intFromPtr(stack) + bytes, &threadStart, @intFromPtr(t));
    const was = disable();
    enqueue(t);
    requestSwitch();
    restore(was);
    return t.id;
}

// A task of ZDOS itself (the network's): entry(arg) on its own
// stack, with no program; signals don't reach it.
// Its id, or null.
pub fn kernelTask(entry: *const fn (arg: usize) callconv(.c) noreturn, arg: usize, name: []const u8, prio: u8) ?u32 {
    if (!platform.has_switching or !running) return null;
    const t = freeTask() orelse return null;
    const stack = allocStack(stack_size) orelse return null;
    t.* = .{ .id = newId(), .base_priority = prio, .priority = prio, .stack = stack, .kernel = true };
    const n = @min(name.len, t.name_buf.len - 1);
    @memcpy(t.name_buf[0..n], name[0..n]);
    t.world = .{ .drive = world().drive };
    env.initStack(&t.world.env);
    t.sp = platform.switching.newContext(@intFromPtr(stack) + stack_size, entry, arg);
    const was = disable();
    enqueue(t);
    requestSwitch();
    restore(was);
    return t.id;
}

fn threadStart(arg: usize) callconv(.c) noreturn {
    const t: *Task = @ptrFromInt(arg);
    const f: ThreadEntry = @ptrFromInt(t.thread_entry);
    threadExit(f(t.thread_arg));
}

// DEFERRED INTERRUPT WORK: THE TASK IRQ (THREADED INTERRUPTS)
// Handlers acknowledge their device and queue what
// takes longer (platform.io.deferWork); IRQ runs it at
// its own priority (IRQPRIO=), FIFO.

var work_head: ?*platform.Work = null;
var work_signal: u8 = 0; // IRQ waits for it

fn deferWork(w: *platform.Work) void {
    if (w.queued.swap(true, .acq_rel)) return; // queued already
    const was = disable();
    w.next = work_head;
    work_head = w;
    restore(was);
    wake(&work_signal);
}

fn workTask(_: usize) callconv(.c) noreturn {
    while (true) {
        const was = disable();
        var at = work_head;
        work_head = null;
        if (at == null) {
            _ = waitFor(was, &work_signal, null, false);
            continue;
        }
        restore(was);
        while (at) |w| {
            at = w.next;
            w.queued.store(false, .release);
            w.func(w.ctx);
        }
    }
}

// At startup, before devices' interrupts are on (or as
// soon as possible): the task IRQ at prio; until then
// handlers do their work themselves
var irq_task: u32 = 0;

pub fn startIrqTask(prio: u8) void {
    const id = kernelTask(&workTask, 0, "IRQ", @min(prio, priorities - 1)) orelse return;
    if (byId(id)) |t| t.policy = .fifo;
    irq_task = id;
    platform.io.deferWork = &deferWork;
}

// IRQPRIO= (SYSTEM.CFG): the task IRQ's priority
pub fn setIrqPriority(prio: u8) bool {
    return irq_task != 0 and setPriority(irq_task, prio);
}

// PROGRAMS' JOBS (GROUP "CORES") ONCE THE OTHER CORES RUN TASKS
// A job is a detached thread of its program pinned to its core.

var job_ids = [_]u32{0} ** max_cores;

pub fn smpActive() bool {
    return smp_on;
}

pub fn jobStart(core: usize, job: usize, arg: usize) bool {
    if (core == 0 or core >= max_cores or !coreAt(core).online or jobBusy(core)) return false;
    job_ids[core] = threadCreateOn(job, arg, 0, null, @intCast(core)) catch return false;
    return true;
}

pub fn jobBusy(core: usize) bool {
    if (core >= max_cores or job_ids[core] == 0) return false;
    const t = byId(job_ids[core]) orelse return false;
    return t.state != .zombie;
}

pub fn jobWait(core: usize) void {
    if (core >= max_cores or job_ids[core] == 0) return;
    while (true) {
        const was = disable();
        const t = byId(job_ids[core]) orelse return restore(was);
        if (t.state == .zombie) return restore(was);
        _ = waitFor(was, t, null, false);
    }
}

pub fn isThread() bool {
    return cur().thread;
}

// The current thread ends with value (for threadJoin)
pub fn threadExit(value: usize) noreturn {
    const t = cur();
    const was = disable();
    t.thread_result = value;
    releaseAll(t);
    for (&tasks) |*w| {
        if (w.state == .blocked and w.wait_obj == @as(*const anyopaque, t)) {
            w.woke = .object;
            enqueue(w);
        }
    }
    t.state = .zombie;
    restore(was);
    while (true) yieldNow();
}

pub const ThreadError = error{ InvalidArgument, Deadlock };

fn threadOfProgram(id: u32) ThreadError!*Task {
    const t = byId(id) orelse return error.InvalidArgument;
    if (!t.thread or t.thread_program != world().program or t.detached) return error.InvalidArgument;
    if (t == cur()) return error.Deadlock;
    return t;
}

// Until thread id (of this program) has ended; what it returned
pub fn threadJoin(id: u32) ThreadError!usize {
    const t = try threadOfProgram(id);
    while (true) {
        const was = disable();
        if (t.state == .zombie) {
            const v = t.thread_result;
            if (t.on_cpu) t.detached = true else free(t); // still on its core: reaped later
            restore(was);
            return v;
        }
        _ = waitFor(was, t, null, false);
    }
}

// Nobody will join it: freed once it ends
pub fn threadDetach(id: u32) ThreadError!void {
    const t = try threadOfProgram(id);
    const was = disable();
    t.detached = true;
    if (t.state == .zombie and !t.on_cpu) free(t);
    restore(was);
}

// A thread asks for its program's end (exit): the program's own
// task ends it as for a fatal signal,
// with this code (api.deliverSignals)
pub fn requestProgramExit(program: *api.Program, code: u8) void {
    program.pending_exit = code;
    const main = byId(cur().main_id) orelse return;
    const was = disable();
    post(main, Sig.kill);
    restore(was);
}

// The program's threads end with it The program's
// threads end with it. One running on another
// core gets SIGKILL (doomed: only it ends);
// true while there are such.
fn endThreads(program: *const api.Program) bool {
    var running_elsewhere = false;
    for (&tasks) |*t| {
        if (!t.thread or t.thread_program != program or t == cur() or t.state == .free) continue;
        // One core (BIOS, UEFI, CORES=1): its on_cpu may be stale (no
        // finish step after a switch), and
        // nothing else runs it: freed at once
        if (smp_on and t.on_cpu) {
            if (t.state == .zombie) {
                t.detached = true; // reaped once off its core
                continue;
            }
            t.doomed = true;
            post(t, Sig.kill);
            running_elsewhere = true;
            continue;
        }
        if (t.state == .ready) remove(t);
        releaseAll(t);
        free(t);
    }
    return running_elsewhere;
}

// A thread its program's end stops (endThreads):
// its SIGKILL ends only it
pub fn doomed() bool {
    return cur().doomed;
}

pub fn setTls(v: usize) void {
    cur().tls = v;
}

pub fn tls() usize {
    return cur().tls;
}

pub fn setThreadPointer(tp: usize) void {
    cur().thread_pointer = tp;
    arch.setThreadPointer(tp);
}

pub fn threadPointer() usize {
    return cur().thread_pointer;
}

// MUTEXES WITH PRIORITY INHERITANCE

pub const max_mutexes = 64;

pub const Mutex = struct {
    used: bool = false,
    owner: ?*Task = null,
    program: ?*const anyopaque = null, // the program that made it (api.Program)
};

pub var mutexes: [max_mutexes]Mutex = undefined;

pub fn mutexCreate(program: *const anyopaque) ?usize {
    for (&mutexes, 0..) |*m, i| {
        if (!m.used) {
            m.* = .{ .used = true, .program = program };
            return i;
        }
    }
    return null;
}

// A program ended: its mutexes, conditions and semaphores go (a
// held mutex handed to a waiter first), its threads end
pub fn programEnded(program: *api.Program) void {
    var was = disable();
    while (endThreads(program)) {
        restore(was);
        nap(1);
        was = disable();
    }
    for (&mutexes) |*m| {
        if (!m.used or m.program != @as(*const anyopaque, program)) continue;
        if (m.owner != null) handOver(m);
        if (m.owner == null) m.* = .{} else m.program = null;
    }
    for (&conds) |*c| {
        if (c.used and c.program == @as(*const anyopaque, program)) c.* = .{};
    }
    for (&sems) |*s| {
        if (s.used and s.program == @as(*const anyopaque, program)) s.* = .{};
    }
    restore(was);
}

pub const MutexError = error{ InvalidArgument, Deadlock, Busy };

fn mutexAt(index: usize) MutexError!*Mutex {
    if (index >= max_mutexes or !mutexes[index].used) return error.InvalidArgument;
    return &mutexes[index];
}

pub fn mutexLock(index: usize) MutexError!void {
    const m = try mutexAt(index);
    if (m.owner == cur()) return error.Deadlock;
    lockMutex(m);
}

pub fn mutexTryLock(index: usize) MutexError!void {
    const m = try mutexAt(index);
    const was = disable();
    defer restore(was);
    if (m.owner == cur()) return error.Deadlock;
    if (m.owner != null) return error.Busy;
    m.owner = cur();
}

// Until m is the current task's; the owner (and whoever it
// waits for) runs at least at its priority meanwhile
fn lockMutex(m: *Mutex) void {
    var spins: u32 = 0;
    var was = disable();
    while (true) {
        if (m.owner == null or !running) {
            m.owner = cur();
            restore(was);
            return;
        }
        // Its owner runs on another core: it likely lets go
        // within microseconds, cheaper to watch for than a
        // sleep and a wake-up across cores. Sleep below as soon
        // as the owner leaves its core (it went to sleep
        // holding it) or it takes long.
        const owner = m.owner.?;
        if (!smp_on or spins >= max_spins or !owner.on_cpu or owner.state != .running or owner == cur()) break;
        restore(was);
        while (spins < max_spins) : (spins += 1) {
            const o = @atomicLoad(?*Task, &m.owner, .monotonic) orelse break;
            if (o == owner and !@atomicLoad(bool, &owner.on_cpu, .monotonic)) break;
            std.atomic.spinLoopHint();
        }
        was = disable();
    }
    cur().blocked_on = m;
    cur().state = .mutex;
    recompute(m.owner.?);
    if (m == &kernel) {
        restore(was);
        yieldNow();
    } else blockNow(was);
    // Unlock handed it over (owner is us now)
}

// Pause loops a task watches a mutex
// whose owner runs elsewhere (tens of µs)
const max_spins = 4000;

pub fn mutexUnlock(index: usize) MutexError!void {
    const m = try mutexAt(index);
    const was = disable();
    defer restore(was);
    if (m.owner != cur()) return error.InvalidArgument;
    handOver(m);
    recompute(cur());
    requestSwitch();
}

pub fn mutexDestroy(index: usize) void {
    if (index >= max_mutexes) return;
    const m = &mutexes[index];
    if (!m.used or m.owner != null) return;
    m.* = .{};
}

// To the highest waiter, or free
fn handOver(m: *Mutex) void {
    var best: ?*Task = null;
    for (&tasks) |*t| {
        if (t.state == .mutex and t.blocked_on == m and (best == null or t.priority > best.?.priority)) best = t;
    }
    m.owner = best;
    if (best) |b| {
        b.blocked_on = null;
        recompute(b);
        // A program's mutex: in turn. The kernel's: the others
        // of its priority would each run a slice first, the
        // waiters behind it too (a convoy):
        enqueueAt(b, m == &kernel or m == &storage_m);
    }
}

// A task's priority: its own, or the highest of those waiting
// for its mutexes (the kernel lock too). Following the chain
// (the owner may itself wait for a mutex).
fn recompute(t: *Task) void {
    var at: ?*Task = t;
    var hops: usize = 0;
    while (at) |x| : (hops += 1) {
        if (hops > max_tasks) break;
        var p = x.base_priority;
        for (&tasks) |*w| {
            if (w.state != .mutex) continue;
            const m = w.blocked_on orelse continue;
            if (m.owner == x) p = @max(p, w.priority);
        }
        if (p == x.priority) break;
        if (x.state == .ready) {
            remove(x);
            x.priority = p;
            enqueue(x);
        } else x.priority = p;
        at = if (x.state == .mutex and x.blocked_on != null) x.blocked_on.?.owner else null;
    }
}

// A task that ends lets go of the mutexes it holds, and the kernel lock
fn releaseAll(t: *Task) void {
    for (&mutexes) |*m| {
        if (m.used and m.owner == t) handOver(m);
    }
    if (kernel.owner == t) handOver(&kernel);
    if (storage_m.owner == t) {
        storage_depth = 0;
        handOver(&storage_m);
    }
}

// CONDITION VARIABLES

pub const max_conds = 64;

const Cond = struct {
    used: bool = false,
    program: ?*const anyopaque = null,
};

var conds: [max_conds]Cond = undefined;

pub fn condCreate(program: *const anyopaque) ?usize {
    for (&conds, 0..) |*c, i| {
        if (!c.used) {
            c.* = .{ .used = true, .program = program };
            return i;
        }
    }
    return null;
}

pub fn condDestroy(index: usize) void {
    if (index < max_conds) conds[index] = .{};
}

pub const CondError = error{ InvalidArgument, TimedOut };

// Gives the mutex up and waits for a signal or broadcast
// of the condition (or ms passing: TimedOut), then takes
// the mutex again. A POSIX signal may end the wait early
// (as a spurious wakeup).
pub fn condWait(index: usize, mutex: usize, ms: ?u32) CondError!void {
    if (index >= max_conds or !conds[index].used) return error.InvalidArgument;
    const m = mutexAt(mutex) catch return error.InvalidArgument;
    if (m.owner != cur()) return error.InvalidArgument;
    if (!running) return if (ms != null) error.TimedOut else error.InvalidArgument; // nobody else could signal
    const was = disable();
    handOver(m);
    recompute(cur());
    const w = waitFor(was, &conds[index], ms, true);
    lockMutex(m);
    if (w == .timeout) return error.TimedOut;
}

pub fn condSignal(index: usize, all: bool) void {
    if (index >= max_conds or !conds[index].used) return;
    if (all) return wake(&conds[index]);
    const was = disable();
    _ = wakeOne(&conds[index]);
    restore(was);
}

// SEMAPHORES

pub const max_sems = 64;

const Sem = struct {
    used: bool = false,
    value: u32 = 0,
    program: ?*const anyopaque = null,
};

var sems: [max_sems]Sem = undefined;

pub fn semCreate(program: *const anyopaque, value: u32) ?usize {
    for (&sems, 0..) |*s, i| {
        if (!s.used) {
            s.* = .{ .used = true, .value = value, .program = program };
            return i;
        }
    }
    return null;
}

pub fn semDestroy(index: usize) void {
    if (index < max_sems) sems[index] = .{};
}

pub const SemError = error{ InvalidArgument, TimedOut, Interrupted, WouldBlock };

// Takes one (waiting until there is one, up to ms; 0: not at all)
pub fn semWait(index: usize, ms: ?u32) SemError!void {
    if (index >= max_sems or !sems[index].used) return error.InvalidArgument;
    const s = &sems[index];
    while (true) {
        const was = disable();
        if (s.value > 0) {
            s.value -= 1;
            restore(was);
            return;
        }
        if ((ms != null and ms.? == 0) or !running) {
            restore(was);
            return error.WouldBlock; // without switching nobody else could post
        }
        switch (waitFor(was, s, ms, true)) {
            .timeout => return error.TimedOut,
            .signal => return error.Interrupted,
            else => {},
        }
    }
}

pub fn semPost(index: usize) SemError!void {
    if (index >= max_sems or !sems[index].used) return error.InvalidArgument;
    const s = &sems[index];
    const was = disable();
    defer restore(was);
    s.value +|= 1;
    _ = wakeOne(s);
}

pub fn semValue(index: usize) ?u32 {
    if (index >= max_sems or !sems[index].used) return null;
    return sems[index].value;
}

// FUTEXES
// A waiter is blocked with wait_obj its word's
// address and futex_bits set. The word is checked
// under the scheduler lock, which wakes take too:
// a wake after the waker's store can't come between
// the check and the wait.

pub const FutexError = error{ InvalidArgument, WouldBlock, TimedOut, Interrupted };

var futex_seq: u64 = 0;

fn futexAddr(addr: *const u32) FutexError!*const anyopaque {
    if (@intFromPtr(addr) == 0 or @intFromPtr(addr) % 4 != 0) return error.InvalidArgument;
    return addr;
}

// While *addr is expected: until futexWake /
// futexRequeue, ms (null: no limit) or a signal
pub fn futexWait(addr: *const u32, expected: u32, ms: ?u32, bits: u32) FutexError!void {
    const obj = try futexAddr(addr);
    if (bits == 0) return error.InvalidArgument;
    const was = disable();
    if (@atomicLoad(u32, addr, .seq_cst) != expected) {
        restore(was);
        return error.WouldBlock;
    }
    if (ms != null and ms.? == 0) {
        restore(was);
        return error.TimedOut;
    }
    if (!running) {
        restore(was);
        _ = sleep(ms orelse return error.InvalidArgument); // nobody else could wake it
        return error.TimedOut;
    }
    cur().futex_bits = bits;
    cur().wait_seq = futex_seq;
    futex_seq +%= 1;
    const w = waitFor(was, obj, ms, true);
    cur().futex_bits = 0;
    return switch (w) {
        .timeout => error.TimedOut,
        .signal => error.Interrupted,
        else => {},
    };
}

pub fn futexWake(addr: *const u32, count: u32, bits: u32) FutexError!u32 {
    const obj = try futexAddr(addr);
    if (bits == 0) return error.InvalidArgument;
    if (!running) return 0;
    const was = disable();
    defer restore(was);
    return wakeFutex(obj, count, bits);
}

// If *addr is expected: wakes count of its waiters and moves
// move_count more to addr2; how many in all
pub fn futexRequeue(addr: *const u32, expected: u32, count: u32, addr2: *const u32, move_count: u32) FutexError!u32 {
    const obj = try futexAddr(addr);
    const obj2 = try futexAddr(addr2);
    const was = disable();
    defer restore(was);
    if (@atomicLoad(u32, addr, .seq_cst) != expected) return error.WouldBlock;
    if (!running) return 0;
    const woken = wakeFutex(obj, count, 0xFFFF_FFFF);
    var moved: u32 = 0;
    while (moved < move_count) : (moved += 1) {
        const t = futexWaiter(obj, 0xFFFF_FFFF) orelse break;
        t.wait_obj = obj2;
    }
    return woken + moved;
}

// The waiter on obj to wake first: the
// highest priority, then the oldest
fn futexWaiter(obj: *const anyopaque, bits: u32) ?*Task {
    var best: ?*Task = null;
    for (&tasks) |*t| {
        if (t.state != .blocked or t.wait_obj != obj or t.futex_bits & bits == 0) continue;
        const b = best orelse {
            best = t;
            continue;
        };
        if (t.priority > b.priority or (t.priority == b.priority and t.wait_seq < b.wait_seq)) best = t;
    }
    return best;
}

fn wakeFutex(obj: *const anyopaque, count: u32, bits: u32) u32 {
    var n: u32 = 0;
    while (n < count) : (n += 1) {
        const t = futexWaiter(obj, bits) orelse break;
        t.woke = .object;
        enqueue(t);
    }
    if (n > 0) requestSwitch();
    return n;
}

// SIGNALS

fn bit(sig: u32) u64 {
    return @as(u64, 1) << @intCast(sig);
}

const unmaskable = bit(Sig.kill) | bit(Sig.stop);

fn deliverable(t: *const Task) bool {
    return t.sig_pending & (~t.sig_mask | unmaskable) != 0;
}

fn programOf(t: *const Task) ?*api.Program {
    return t.world.program;
}

// The running task's program, also outside the kernel lock (signals)
pub fn currentProgram() ?*api.Program {
    return programOf(cur());
}

// Signals the default action ignores
pub fn ignoredByDefault(sig: u32) bool {
    return sig == Sig.chld or sig == Sig.urg or sig == Sig.winch or sig == Sig.cont;
}

// Marks sig pending for t (interrupts off), waking it from a
// wait a signal may end; dropped if its program ignores it
fn post(t: *Task, sig: u32) void {
    if (sig == Sig.cont or sig == Sig.kill) {
        t.sig_pending &= ~(bit(Sig.stop) | bit(Sig.tstp) | bit(Sig.ttin) | bit(Sig.ttou));
        if (t.state == .stopped) enqueue(t);
    }
    if (sig != Sig.kill and sig != Sig.stop) {
        if (programOf(t)) |p| {
            if (p.sig_ignored & bit(sig) != 0) return;
            if (p.sig_caught & bit(sig) == 0 and ignoredByDefault(sig)) return;
        } else if (ignoredByDefault(sig)) return;
    }
    if (sig == Sig.stop or sig == Sig.tstp or sig == Sig.ttin or sig == Sig.ttou) t.sig_pending &= ~bit(Sig.cont);
    t.sig_pending |= bit(sig);
    if (!deliverable(t)) return;
    if (t.interruptible and (t.state == .sleeping or t.state == .waiting or t.state == .blocked)) {
        t.woke = .signal;
        enqueue(t);
    }
}

pub const KillError = error{ NotFound, InvalidArgument, AccessDenied };

// Sends sig (1-63; 0: only whether the task exists) to task id
pub fn kill(id: u32, sig: u32) KillError!void {
    if (sig >= 64) return error.InvalidArgument;
    const t = byId(id) orelse {
        if (recordOf(id) != null) return; // ended, not collected yet: it still counts
        return error.NotFound;
    };
    if (sig == 0 or t.state == .zombie) return; // it exists (or did: not collected yet)
    if (t.kernel) return error.AccessDenied;
    // Only to one's own tasks, unless root
    if (!perm.maySignal(idsOf(t))) return error.AccessDenied;
    const was = disable();
    post(t, sig);
    requestSwitch();
    restore(was);
}

// The current task's next signal to handle (taken off pending), or null
pub fn nextSignal() ?u32 {
    const was = disable();
    defer restore(was);
    const ready = cur().sig_pending & (~cur().sig_mask | unmaskable);
    if (ready == 0) return null;
    // SIGKILL first, then the lowest number
    const sig: u32 = if (ready & bit(Sig.kill) != 0) Sig.kill else @ctz(ready);
    cur().sig_pending &= ~bit(sig);
    return sig;
}

pub fn signalMask() u64 {
    return cur().sig_mask;
}

// SIGKILL and SIGSTOP can't be blocked
pub fn setSignalMask(mask: u64) void {
    cur().sig_mask = mask & ~unmaskable;
}

pub fn pendingSignals() u64 {
    return cur().sig_pending;
}

// SIGALRM in ms (0: none); the milliseconds the previous timer had left
pub fn alarm(ms: u64) u64 {
    const old = setTimer(Sig.alrm, ms *| 1_000_000, 0);
    return (old.left + 999_999) / 1_000_000;
}

pub const TimerSetting = struct { left: u64, interval: u64 };

// The task's timer (alarm, setitimer, timer_settime): sig in
// `first` nanoseconds (0: off), then every `interval` (0:
// once). The setting before.
pub fn setTimer(sig: u32, first: u64, interval: u64) TimerSetting {
    const t = cur();
    const was = disable();
    defer restore(was);
    const now = platform.clock.nanos();
    const old: TimerSetting = .{ .left = if (t.timer_at > now) t.timer_at - now else if (t.timer_at != 0) 1 else 0, .interval = t.timer_interval };
    t.timer_sig = @intCast(sig & 63);
    t.timer_at = if (first == 0) 0 else now +| first;
    t.timer_interval = if (first == 0) 0 else interval;
    // A sooner deadline than this core's timer has: armed now
    if (running) arm(me(), now);
    return old;
}

pub fn timer() TimerSetting {
    const t = cur();
    const now = platform.clock.nanos();
    return .{ .left = if (t.timer_at > now) t.timer_at - now else if (t.timer_at != 0) 1 else 0, .interval = t.timer_interval };
}

// Waits until a signal comes (pause)
pub fn waitSignal() void {
    if (!running) return;
    _ = waitFor(disable(), cur(), null, true);
}

// SIGSTOP and its kind: the task stops until SIGCONT
pub fn stopSelf() void {
    if (!running) return;
    const was = disable();
    if (cur().sig_pending & bit(Sig.cont) != 0) {
        cur().sig_pending &= ~bit(Sig.cont);
        restore(was);
        return;
    }
    cur().state = .stopped;
    blockNow(was);
}

pub fn setTermSignal(sig: u8) void {
    cur().term_signal = sig;
}
