// CPU-specific code: x86_64, x86 (BIOS), aarch64
const builtin = @import("builtin");

const impl = switch (builtin.cpu.arch) {
    .x86_64 => @import("arch/x86_64.zig"),
    .x86 => @import("arch/x86.zig"),
    .aarch64 => @import("arch/arm64.zig"),
    else => @compileError("ZDOS does not support this CPU"),
};

pub const cc = impl.cc;
pub const timestamp = impl.timestamp;
// callOnStack(arg, func, stack_top, saved): func(arg) on
// another stack, its 8-bit result. saved: where the caller's
// stack and registers are, for exitTo.
pub const callOnStack = impl.callOnStack;
// exitTo(saved, code): ends func from anywhere
// inside it, as if it had returned code.
pub const exitTo = impl.exitTo;
pub const syncCode = impl.syncCode;
// The running task's thread pointer for thread_local data:
// x86_64 FS base, ARM64 TPIDR_EL0, x86 GS's segment base.
pub const setThreadPointer = impl.setThreadPointer;
pub const cpuName = impl.cpuName;
pub const timestamp_is_cpu_clock = impl.timestamp_is_cpu_clock;
