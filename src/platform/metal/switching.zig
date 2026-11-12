// Task switching for tasks.zig (platform.switching), by CPU:
// switch_x86_64.zig, switch_arm64.zig
const builtin = @import("builtin");

const impl = switch (builtin.cpu.arch) {
    .x86_64 => @import("switch_x86_64.zig"),
    .aarch64 => @import("switch_arm64.zig"),
    else => @compileError("metal: x86_64 and aarch64 only"),
};

// Why the scheduler is called: a task gives the CPU up, the
// timer's tick, or a device's interrupt
// (whose handler may have woken a task)
pub const Why = enum(u8) { yield, tick, irq };

// The scheduler: the interrupted task's saved state (sp), why,
// and whether it was running its program's code (it may be
// preempted only there); the state to resume
pub const Callback = *const fn (sp: usize, why: Why, in_program: bool) usize;
// start(callback, done): done runs after
// each switch, on the new task's stack

pub const setImage = impl.setImage;
// Several cores running tasks: a core's number (setCoreIndex
// before it runs any), another core joining (startCore: false
// if it can't tick), waking an idle core (kick)
pub const coreIndex = impl.coreIndex;
pub const setCoreIndex = impl.setCoreIndex;
pub const startCore = impl.startCore;
pub const kick = impl.kick;
// Another state on the task's stack below `sp`, which calls
// f(arg) when resumed (signals delivered to
// a program between two of its instructions)
pub const pushCall = impl.pushCall;
pub const start = impl.start;
pub const newContext = impl.newContext;
pub const yield = impl.yield;
pub const disable = impl.disable;
pub const restore = impl.restore;
pub const idle = impl.idle;
// This core's next timer interrupt at a nanos() value (null:
// none), set after each switch:
// deadlines instead of a periodic tick
pub const armTimer = impl.armTimer;
