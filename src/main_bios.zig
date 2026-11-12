// BIOS entry: stage 2 copies the kernel to 1 MiB and jumps to
// _start in protected mode with EAX = &BootInfo.
const std = @import("std");
const platform = @import("platform.zig");
const bios = @import("platform/bios/bios.zig");
const arch = @import("arch.zig");
const startup = @import("kernel/startup.zig");

pub const zdos_platform: platform.Platform = .bios;

// Must come first in the kernel image (kernel.ld).
export fn _start() linksection(".text.entry") callconv(.naked) noreturn {
    asm volatile (
        \\mov $__stack_top, %%esp
        \\mov %%eax, %%ebx
        // Stage 2 copied only the file's contents: zero .bss:
        \\mov $__bss_start, %%edi
        \\mov $__bss_end, %%ecx
        \\sub %%edi, %%ecx
        \\xor %%eax, %%eax
        \\cld
        \\rep stosb
        \\push %%ebx
        \\call zdos_bios_main
    );
}

const kernel_stack_size = 1024 * 1024;
const no_arg: u8 = 0;
var kernel_saved: usize = 0; // the kernel never exits through arch.exitTo

export fn zdos_bios_main(info: *const bios.BootInfo) callconv(.c) noreturn {
    if (info.magic != @import("platform/bios/realmode.zig").boot_info_magic) while (true) {};
    bios.setBootInfo(info);
    @import("arch/x86.zig").enableFpu(); // FPU and SSE for programs
    platform.init();
    const pages = kernel_stack_size / 4096;
    if (platform.memory.allocPages(pages, false)) |stack| {
        _ = arch.callOnStack(&no_arg, &kernelEntry, @intFromPtr(stack) + kernel_stack_size, &kernel_saved);
    }
    startup.run(); // not enough memory for a stack: use the startup stack
}

fn kernelEntry(_: *const anyopaque) callconv(arch.cc) u8 {
    startup.run();
}

// A Zig panic is a kernel bug: show it and halt.
pub const panic = std.debug.FullPanic(panicHalt);

fn panicHalt(msg: []const u8, _: ?usize) noreturn {
    platform.serial.toPolled();
    platform.console.setColor(15, 4);
    platform.console.write("\n*** ZDOS panic: ");
    platform.console.write(msg);
    platform.console.write("\nSystem halted. Restart the computer.\n");
    while (true) asm volatile ("cli; hlt");
}
