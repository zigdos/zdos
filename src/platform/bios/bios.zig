// Platform backend for BIOS PCs: 32-bit protected mode,
// no paging, i686. Disks (int 13h) and video modes (int 10h)
// go through the BIOS, with interrupts off. Preemptive tasks
// once switching starts (the PIT's one-shot deadlines, the
// keyboard and mouse: pic.zig), other cores for jobs and the
// network, an e1000 card polled.
const std = @import("std");
const realmode = @import("realmode.zig");
const port = @import("../../arch/x86_port.zig");
const arch = @import("../../arch/x86.zig");
const platform = @import("../../platform.zig");

pub const console = @import("console.zig");
pub const serial = @import("serial.zig");

// SYSTEM.CFG's settings for the platform
pub fn configure(get: *const fn (name: []const u8) ?[]const u8) void {
    serial.setMode(get("SERIAL"));
}
pub const storage = @import("storage.zig");
pub const memory = @import("memory.zig");
pub const clock = @import("clock.zig");
pub const graphics = @import("graphics.zig");
pub const boot = @import("boot.zig");
pub const disk = @import("rawdisk.zig");
// Task switching, preemptive (platform.switching)
pub const switching = @import("switching.zig");
// Other CPU cores, as workers for programs' jobs (platform.cores)
pub const cores = @import("smp.zig");
// The network card (platform.net), and
// a core of its own for the network
pub const net = @import("net.zig");
pub const net_core = @import("net_core.zig");
// pub const net_polled = false; // switch to polling mode
// Drivers from files (kernel/drivers.zig):
// no paging, every address reachable; interrupts on the device's
// wired line (PCI config byte 0x3C), shared
pub const own_drivers = struct {
    pub fn mapDevice(start: u64, len: u64) bool {
        return start + len <= 1 << 32;
    }
    pub fn attachInterrupt(d: pci.PciDeviceLocation, h: switching.SharedHandler, ctx: ?*anyopaque) bool {
        if (d.interrupt_pin == 0 or d.interrupt_line == 0 or d.interrupt_line > 15) return false;
        // Command register bit 10 off: the wired interrupt on
        const cmd = pci.pciReadConfigDwordInSegment(d.segment, d.bus, d.slot, d.func, 0x04);
        pci.pciWriteConfigDwordInSegment(d.segment, d.bus, d.slot, d.func, 0x04, cmd & 0xFFFF & ~@as(u32, 1 << 10));
        return switching.addIrqHandler(@intCast(d.interrupt_line), h, ctx);
    }
};
const pci = @import("../../drivers/pcie/pci.zig");
const pic = @import("pic.zig");

pub const name = "BIOS";
pub const config = @import("config.zig");

pub const BootInfo = realmode.BootInfo;

// Called by the entry point (main_bios.zig) before init
pub fn setBootInfo(info: *const BootInfo) void {
    realmode.info = info;
}

pub fn init() void {
    // Don't trust the FPU state the BIOS left
    asm volatile ("fninit");
    arch.installExceptionHandlers(&onException);
    // Mask keyboard and mouse so the BIOS's handlers can't eat
    // their bytes during BIOS calls;
    // console.readKey unmasks them while it waits.
    port.outb(0x21, port.inb(0x21) | 0x02); // IRQ 1: keyboard
    port.outb(0xA1, port.inb(0xA1) | 0x10); // IRQ 12: PS/2 mouse
    console.init();
    memory.init();
    clock.init();
    storage.init();
    // From here on BIOS calls switch the PICs and the PIT back and forth
    pic.init();
}

// Once tasks switch (platform.startInterrupts): the IDE
// channels' IRQs for ZDOS's ATA driver
pub fn startInterrupts() void {
    @import("disk.zig").startInterrupts(&ideIrq);
}

fn ideIrq(channel: u1) bool {
    return switching.setIrqHandler(if (channel == 0) 14 else 15, if (channel == 0) &ide0 else &ide1);
}

fn ide0() void {
    @import("../../drivers/ata.zig").handle(0);
}

fn ide1() void {
    @import("../../drivers/ata.zig").handle(1);
}

pub const power = struct {
    // APM power-off; without APM, the classic message
    pub fn shutdown() noreturn {
        apmOff();
        console.write("\nIt is now safe to turn off your computer.\n");
        halt();
    }

    // Keyboard controller reset: command 0xFE on port 0x64
    pub fn restart() noreturn {
        while (port.inb(0x64) & 0x02 != 0) {} // the controller takes no more input
        port.outb(0x64, 0xFE);
        halt();
    }
};

fn apmOff() void {
    var r: realmode.Regs = .{ .eax = 0x5300, .ebx = 0 }; // installed?
    realmode.call(0x15, &r);
    if (r.carry() or (r.ebx & 0xFFFF) != 0x504D) return; // "PM"
    r = .{ .eax = 0x5301, .ebx = 0 }; // connect the real-mode interface
    realmode.call(0x15, &r);
    r = .{ .eax = 0x530E, .ebx = 0, .ecx = 0x0102 }; // driver version 1.2
    realmode.call(0x15, &r);
    r = .{ .eax = 0x5308, .ebx = 0x0001, .ecx = 0x0001 }; // enable power management
    realmode.call(0x15, &r);
    r = .{ .eax = 0x5307, .ebx = 0x0001, .ecx = 0x0003 }; // all devices: off
    realmode.call(0x15, &r);
}

fn halt() noreturn {
    while (true) asm volatile ("cli; hlt");
}

// A CPU fault in a program's code (outside ZDOS's image, on
// core 0) ends the program with a signal or runs its handler,
// as on metal: the handler runs right here, below the
// faulting state on the program's own stack (the exception
// stayed in ring 0). ZDOS's own faults, and other cores'
// (their jobs), show the crash screen.
extern const __kernel_start: u8;
extern const __kernel_end: u8;

fn onException(frame: *const arch.ExceptionFrame) noreturn {
    const v = frame.vector;
    const in_program = frame.eip < @intFromPtr(&__kernel_start) or frame.eip >= @intFromPtr(&__kernel_end);
    if (platform.faults.handler) |h| if (in_program and (cores.onCoreZero() or switching.onTaskCore())) if (signalOf(v)) |sig| {
        if (v == 16) asm volatile ("fnclex"); // the x87's pending error
        // On this stack, not a global: another task may fault meanwhile
        const fault: platform.Fault = .{ .signal = sig, .what = arch.exception_names[v & 31], .pc = frame.eip };
        // The gate turned interrupts off; the program had them on
        // (tasks switch preemptively), and
        // its handler and its end run as it
        if (frame.eflags & 0x200 != 0) asm volatile ("sti" ::: "memory");
        h(&fault);
    };
    crashScreen(frame);
}

// POSIX signals for the exceptions a program's code may cause (metal's)
fn signalOf(vector: u32) ?u8 {
    return switch (vector) {
        0, 7, 16, 19 => 8, // division, no FPU, x87 and SIMD errors: SIGFPE
        1, 3 => 5, // debug, breakpoint: SIGTRAP
        4, 5, 10, 11, 12, 13, 14 => 11, // overflow, bound, segment, stack, protection, page: SIGSEGV
        6 => 4, // invalid opcode (ud2, Zig's @trap): SIGILL
        17 => 7, // alignment check: SIGBUS
        else => null,
    };
}

fn crashScreen(frame: *const arch.ExceptionFrame) noreturn {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf,
        \\
        \\*** CPU exception {d}: {s}
        \\EIP={x:0>8} error={x:0>8} EFLAGS={x:0>8}
        \\EAX={x:0>8} EBX={x:0>8} ECX={x:0>8} EDX={x:0>8}
        \\ESI={x:0>8} EDI={x:0>8} EBP={x:0>8}
        \\System halted. Restart the computer.
        \\
    , .{
        frame.vector, arch.exception_names[frame.vector & 31], frame.eip, frame.error_code, frame.eflags,
        frame.eax,    frame.ebx,                               frame.ecx, frame.edx,        frame.esi,
        frame.edi,    frame.ebp,
    }) catch "\n*** CPU exception. System halted.\n";
    console.setColor(15, 4);
    console.write(text);
    halt();
}
