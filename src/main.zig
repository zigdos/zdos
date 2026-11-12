// Metal entry (x86_64, ARM64):
// platform.init leaves the firmware.
const std = @import("std");
const platform = @import("platform.zig");
const metal = @import("platform/metal/metal.zig");
const arch = @import("arch.zig");
const startup = @import("kernel/startup.zig");

pub const zdos_platform: platform.Platform = .metal;

// The firmware guarantees only 128 KiB of stack.
const kernel_stack_size = 1024 * 1024;
const no_arg: u8 = 0;
var kernel_saved: usize = 0; // the kernel never exits through arch.exitTo

pub fn main() noreturn {
    platform.init();
    const pages = kernel_stack_size / 4096;
    if (platform.memory.allocPages(pages, false)) |stack| {
        _ = arch.callOnStack(&no_arg, &kernelEntry, @intFromPtr(stack) + kernel_stack_size, &kernel_saved);
    }
    startup.run(); // not enough memory for a stack: use the firmware's
}

fn kernelEntry(_: *const anyopaque) callconv(arch.cc) u8 {
    startup.run();
}

// A Zig panic is a kernel bug: shown on
// ZDOS's own console, as the firmware is gone.
pub const panic = std.debug.FullPanic(metal.panicHalt);
