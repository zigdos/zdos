// The other CPU cores of the metal editions as job workers
// (platform.cores), started on first use, after the page
// tables are final. At the end of startup tasks.zig gives
// each a job that never ends: it joins the scheduler (one
// core may stay the network's). CPU specifics:
// smp_x86_64.zig, smp_arm64.zig.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../../platform.zig");
const memory = @import("memory.zig");
const cpu = @import("cpu.zig");
const clock = @import("clock.zig");

const impl = switch (builtin.cpu.arch) {
    .x86_64 => @import("smp_x86_64.zig"),
    .aarch64 => @import("smp_arm64.zig"),
    else => @compileError("metal: x86_64 and aarch64 only"),
};

pub const max_cores = 64;
const stack_size = 64 * 1024;

const idle: u32 = 0;
const busy_state: u32 = 1;

pub const Core = struct {
    hw_id: u64 = 0, // APIC ID (x86_64) or MPIDR affinity (ARM64)
    state: std.atomic.Value(u32) = .init(idle),
    job: platform.Job = undefined,
    arg: ?*anyopaque = null,
    sleeps_on_timer: bool = false, // ARM64: wfi with its own timer, else wfe
};

pub var cores: [max_cores]Core = [_]Core{.{}} ** max_cores;
// Core 0, then the started ones in order (a new core counts itself)
var online = std.atomic.Value(usize).init(1);
var started = false;

// Right after leaving the firmware: what starting the cores later needs
pub fn reserve() void {
    impl.reserve();
}

// All the cores, the one ZDOS keeps (dedicate) too:
// it only refuses jobs
pub fn count() usize {
    return startedCount();
}

pub fn reserved() ?usize {
    return dedicated;
}

fn startedCount() usize {
    if (!started) {
        started = true;
        impl.startAll(&addCore);
    }
    return online.load(.acquire);
}

// A CORE OF ZDOS'S OWN (the NETWORK: platform/metal/net_core.zig)

var dedicated: ?usize = null;

// A core (want, else the last) taken from the programs for
// job(arg), which never ends; null with fewer than two cores or
// when want is 0 or past them
pub fn dedicate(job: platform.Job, arg: ?*anyopaque, want: ?usize) ?usize {
    const n = startedCount();
    if (n < 2 or dedicated != null) return null;
    const core = want orelse n - 1;
    if (core == 0 or core >= n) return null;
    if (!start(@intCast(core), job, arg)) return null;
    dedicated = core;
    return core;
}

pub fn wakeCore(core: usize) void {
    impl.wake(&cores[core]);
}

pub fn onlineCount() usize {
    return online.load(.acquire);
}

// For the CPU part: a core is running its loop,
// as the next number. Its stack and slot are
// set up before; null when there's no room.
fn addCore(hw_id: u64) ?Started {
    const index = online.load(.acquire);
    if (index == max_cores) return null;
    const pages = stack_size / 4096;
    const stack = memory.allocPages(pages, false) orelse return null;
    cores[index] = .{ .hw_id = hw_id };
    return .{ .index = index, .stack_top = @intFromPtr(stack) + stack_size };
}

pub const Started = struct { index: usize, stack_top: usize };

// A core reports itself running: it counts from now on (cores
// start one at a time, so it is the next one)
fn coreOnline(index: usize) void {
    if (online.load(.acquire) == index) online.store(index + 1, .release);
}

pub fn start(core: u32, job: platform.Job, arg: ?*anyopaque) bool {
    if (core == 0 or core >= online.load(.acquire) or dedicated == core) return false;
    const c = &cores[core];
    if (c.state.load(.acquire) != idle) return false;
    c.job = job;
    c.arg = arg;
    c.state.store(busy_state, .release);
    impl.wake(c);
    return true;
}

pub fn busy(core: u32) bool {
    if (core == 0 or core >= online.load(.acquire) or dedicated == core) return false;
    return cores[core].state.load(.acquire) != idle;
}

// Spins a short while (short jobs end without a sleep's delay),
// then sleeps between looks (a finishing
// core wakes core 0 where the CPU can)
pub fn wait(core: u32) void {
    if (core == 0 or core >= online.load(.acquire) or dedicated == core) return;
    const c = &cores[core];
    const spin_until = clock.millis() + 1;
    while (c.state.load(.acquire) != idle) {
        if (clock.millis() < spin_until) std.atomic.spinLoopHint() else cpu.wait();
    }
}

// A worker core's life, once the CPU part has set it up
pub fn workerLoop(index: usize) noreturn {
    const c = &cores[index];
    coreOnline(index);
    while (true) {
        if (c.state.load(.acquire) == busy_state) {
            c.job(c.arg);
            c.state.store(idle, .release);
            impl.jobDone();
        } else {
            impl.sleep(c);
        }
    }
}
