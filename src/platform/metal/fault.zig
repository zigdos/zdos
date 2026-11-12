// A CPU fault in a program's code: the exception paths note it
// here and resume the task in `entry`, below its stack, which
// hands it to platform.faults.handler.
// The faulting state is never resumed.
const platform = @import("../../platform.zig");

pub var last: platform.Fault = undefined;

// Whether a fault at pc can go to the kernel: the kernel takes
// faults (tasks switch) and pc is a program's code, not ZDOS's
pub fn wanted(pc: usize, inProgram: *const fn (pc: usize) bool) bool {
    return platform.faults.handler != null and inProgram(pc);
}

pub fn entry(_: usize) callconv(.c) noreturn {
    platform.faults.handler.?(&last);
}

// The kernel's room below the fault: what the program had on
// its stack there stays as it was (a
// red zone, the frame that faulted)
pub const gap = 4096;
