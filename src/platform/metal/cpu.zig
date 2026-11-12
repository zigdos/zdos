// CPU idling and exceptions for the metal editions,
// by CPU (cpu_x86_64.zig, cpu_arm64.zig). wait() sleeps
// until the next ~1 ms wake-up.
const builtin = @import("builtin");

const impl = switch (builtin.cpu.arch) {
    .x86_64 => @import("cpu_x86_64.zig"),
    .aarch64 => @import("cpu_arm64.zig"),
    else => @compileError("metal: x86_64 and aarch64 only"),
};

var ready = false;

// After leaving the firmware (memory and the clock work)
pub fn init() void {
    ready = impl.init();
}

// Sleeps until the next wake-up (at most about 1 ms); returns
// at once before init or if it failed
pub fn wait() void {
    if (ready) impl.wait() else @import("std").atomic.spinLoopHint();
}
