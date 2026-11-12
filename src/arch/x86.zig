// 32-bit x86 code of the BIOS edition (i686 and later):
// arch.zig's contracts, FPU/SSE setup, the exception table.
const std = @import("std");

pub fn timestamp() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

// cdecl
pub const cc: std.builtin.CallingConvention = .{ .x86_sysv = .{} };

pub const callOnStack: *const fn (arg: *const anyopaque, func: *const anyopaque, stack_top: usize, saved: *usize) callconv(cc) u8 = @ptrCast(&callOnStackAsm);

pub const exitTo: *const fn (saved: usize, code: u8) callconv(cc) noreturn = @ptrCast(&exitToAsm);

// Arguments at 8, 12, 16, 20 from ebp. ebp, ebx, esi, edi,
// the x87 CW and with SSE MXCSR are saved on the caller's
// stack, for both a return and exitTo. func starts with
// x87 / SSE as after reset (fninit, MXCSR 0x1F80).
// ebp keeps the caller's stack pointer. 16-byte aligned at
// the call, as cdecl asks.
fn callOnStackAsm() callconv(.naked) void {
    asm volatile (
        \\push %%ebp
        \\mov %%esp, %%ebp
        \\push %%ebx
        \\push %%esi
        \\push %%edi
        \\sub $8, %%esp
        \\fnstcw (%%esp)
        \\fninit
        \\mov %%cr4, %%eax
        \\test $0x200, %%eax
        \\jz 1f
        \\stmxcsr 4(%%esp)
        \\pushl $0x1F80
        \\ldmxcsr (%%esp)
        \\add $4, %%esp
        \\1:
        \\mov 20(%%ebp), %%eax
        \\mov %%esp, (%%eax)
        \\mov 8(%%ebp), %%eax
        \\mov 12(%%ebp), %%ecx
        \\mov 16(%%ebp), %%esp
        \\and $-16, %%esp
        \\sub $12, %%esp
        \\push %%eax
        \\call *%%ecx
        \\lea -20(%%ebp), %%esp
        \\fninit
        \\fldcw (%%esp)
        \\mov %%cr4, %%ecx
        \\test $0x200, %%ecx
        \\jz 1f
        \\ldmxcsr 4(%%esp)
        \\1:
        \\add $8, %%esp
        \\pop %%edi
        \\pop %%esi
        \\pop %%ebx
        \\pop %%ebp
        \\ret
    );
}

// 4(esp): where callOnStack saved the registers, 8(esp):
// the result; returns as callOnStack does.
fn exitToAsm() callconv(.naked) void {
    asm volatile (
        \\movzbl 8(%%esp), %%eax
        \\mov 4(%%esp), %%esp
        \\fninit
        \\fldcw (%%esp)
        \\mov %%cr4, %%ecx
        \\test $0x200, %%ecx
        \\jz 1f
        \\ldmxcsr 4(%%esp)
        \\1:
        \\add $8, %%esp
        \\pop %%edi
        \\pop %%esi
        \\pop %%ebx
        \\pop %%ebp
        \\ret
    );
}

pub const cpuName = @import("x86_cpu.zig").name;

// The BIOS leaves the FPU and SSE (Pentium III+) off.
// ZDOS uses neither and runs one program at a time, so
// only the settings are saved around a program. CR0:
// EM off, MP and NE on (#MF, vector 16); CR4: OSFXSR and
// OSXMMEXCPT (#XM, vector 19). fninit and the reset
// MXCSR mask every error.
pub fn enableFpu() void {
    var cr0: u32 = undefined;
    asm volatile ("mov %%cr0, %[r]"
        : [r] "=r" (cr0),
    );
    cr0 = (cr0 & ~@as(u32, 1 << 2)) | (1 << 1) | (1 << 5);
    asm volatile ("mov %[r], %%cr0; fninit"
        :
        : [r] "r" (cr0),
    );

    const edx = @import("x86_cpu.zig").cpuid(1, 0)[3];
    const fxsr = 1 << 24;
    const sse = 1 << 25;
    if (edx & (fxsr | sse) != (fxsr | sse)) return; // Pentium II and older
    var cr4: u32 = undefined;
    asm volatile ("mov %%cr4, %[r]"
        : [r] "=r" (cr4),
    );
    cr4 |= (1 << 9) | (1 << 10);
    asm volatile ("mov %[r], %%cr4"
        :
        : [r] "r" (cr4),
    );
}
pub const timestamp_is_cpu_clock = true;

// GS: stage 2's GDT entry 0x28 gets the thread
// pointer as its base; BIOS calls reset GS
// (reloadThreadPointer after them).
// Cores share the entry: writing it and
// loading GS go together under a lock, and
// each core keeps its own pointer.
const tls_selector = 0x28;
const max_tls_cores = 64;
var thread_pointers = [_]usize{0} ** max_tls_cores;
var tls_lock = std.atomic.Value(bool).init(false);
pub var coreIndex: *const fn () usize = &coreZero;

fn coreZero() usize {
    return 0;
}

pub fn setThreadPointer(tp: usize) void {
    thread_pointers[coreIndex() % max_tls_cores] = tp;
    reloadThreadPointer();
}

pub fn reloadThreadPointer() void {
    const flags = asm volatile ("pushfl; cli; popl %[f]"
        : [f] "=r" (-> u32),
        :
        : "memory"
    );
    defer if (flags & 0x200 != 0) asm volatile ("sti" ::: "memory");
    const tp = thread_pointers[coreIndex() % max_tls_cores];
    if (tp == 0) return;
    var gdtr: [6]u8 align(4) = undefined;
    storeGdtr(&gdtr);
    const base = std.mem.readInt(u32, gdtr[2..6], .little);
    const limit = std.mem.readInt(u16, gdtr[0..2], .little);
    if (limit < tls_selector + 7) return; // an older stage 2 without the entry
    while (tls_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer tls_lock.store(false, .release);
    const entry: *align(1) volatile u64 = @ptrFromInt(base + tls_selector);
    const b: u64 = tp;
    // 32-bit data, 4 GiB, present, writable;
    // base split over the entry:
    entry.* = 0x00CF_9200_0000_FFFF | ((b & 0xFF_FFFF) << 16) | ((b >> 24) << 56);
    asm volatile ("mov %[s], %%gs"
        :
        : [s] "r" (@as(u16, tls_selector)),
        : "memory"
    );
}

// x86 keeps its I-cache coherent with data writes.
pub fn syncCode(code: []const u8) void {
    _ = code;
}

// EXCEPTIONS: without an IDT any exception triple-faults.
// Interrupts are off until task switching starts, then
// on except in short sections and BIOS calls. PIC IRQs
// are on 0x20-0x2F; 0x40 wakes other cores.

// What the CPU and the handler stubs leave on the stack.
pub const ExceptionFrame = extern struct {
    edi: u32,
    esi: u32,
    ebp: u32,
    esp: u32, // before pushal; not the faulting code's
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,
    vector: u32,
    error_code: u32, // 0 for exceptions without one
    eip: u32,
    cs: u32,
    eflags: u32,
};

pub const exception_names = [32][]const u8{
    "Division by zero",     "Debug",               "NMI",            "Breakpoint",
    "Overflow",             "Bound range",         "Invalid opcode", "No FPU",
    "Double fault",         "FPU segment overrun", "Invalid TSS",    "Segment not present",
    "Stack fault",          "General protection",  "Page fault",     "Reserved",
    "FPU error",            "Alignment check",     "Machine check",  "SIMD error",
    "Virtualization",       "Control protection",  "Reserved",       "Reserved",
    "Reserved",             "Reserved",            "Reserved",       "Reserved",
    "Hypervisor injection", "VMM communication",   "Security",       "Reserved",
};

const IdtEntry = extern struct {
    offset_low: u16,
    selector: u16,
    zero: u8,
    type_attr: u8,
    offset_high: u16,
};

pub const irq_base = 0x20; // IRQ0-15 on 0x20-0x2F
const keyboard_vector = irq_base + 1;
const mouse_vector = irq_base + 12;
pub const wake_vector = 0x40; // another core's wake-up IPI (local APIC)
const apic_spurious_vector = 0xFF;
var idt: [256]IdtEntry = std.mem.zeroes([256]IdtEntry);
var handler: *const fn (*const ExceptionFrame) noreturn = undefined;
var keyboard_irq: *const fn () callconv(cc) void = undefined;
var mouse_irq: *const fn () callconv(cc) void = undefined;

const code_selector = 0x08; // stage 2's GDT

fn idtEntry(addr: usize) IdtEntry {
    return .{
        .offset_low = @truncate(addr),
        .selector = code_selector,
        .zero = 0,
        .type_attr = 0x8E, // present, ring 0, 32-bit interrupt gate
        .offset_high = @truncate(addr >> 16),
    };
}

// handler gets every exception and must not return.
pub fn installExceptionHandlers(h: *const fn (*const ExceptionFrame) noreturn) void {
    handler = h;
    inline for (0..32) |v| {
        const addr = @intFromPtr(stub(v));
        idt[v] = idtEntry(addr);
    }
    for (irq_base..irq_base + 8) |v| idt[v] = idtEntry(@intFromPtr(&masterIrqEntry));
    for (irq_base + 8..irq_base + 16) |v| idt[v] = idtEntry(@intFromPtr(&slaveIrqEntry));
    idt[wake_vector] = idtEntry(@intFromPtr(&wakeEntry));
    idt[apic_spurious_vector] = idtEntry(@intFromPtr(&spuriousEntry));
    const Idtr = packed struct { limit: u16, base: u32 };
    const idtr: Idtr = .{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&idtr),
    );
}

// For task switching's stubs.
pub fn setGate(vector: u8, addr: usize) void {
    idt[vector] = idtEntry(addr);
}

// The BIOS leaves the PIC in legacy mode, where IRQ1 shares
// vector 9 with the coprocessor-segment-overrun exception:
// IRQ gates only while waiting for input, other IRQs masked
// by the caller. IRQ12 must wake the wait too:
// an unread mouse byte fills the controller's buffer, and then
// IRQ1 never comes. The callbacks read the data port;
// the entries send the EOIs.
pub fn waitForInputIrq(keyboard: *const fn () callconv(cc) void, mouse: *const fn () callconv(cc) void) void {
    setInputIrqs(keyboard, mouse);
    halt();
}

// For every wait from now on; they read the controller's byte,
// as an unread one would hold up the next.
pub fn setInputIrqs(keyboard: *const fn () callconv(cc) void, mouse: *const fn () callconv(cc) void) void {
    keyboard_irq = keyboard;
    mouse_irq = mouse;
    idt[keyboard_vector] = idtEntry(@intFromPtr(&keyboardIrqEntry));
    idt[mouse_vector] = idtEntry(@intFromPtr(&mouseIrqEntry));
}

// Until the next interrupt (the timer's at
// the latest, if unmasked). The interrupt
// flag stays as it was.
pub fn halt() void {
    asm volatile ("pushfl; sti; hlt; popfl" ::: "memory");
}

// The timer's tick only wakes a halt:
// the other IRQs acknowledged.
fn masterIrqEntry(_: *const InterruptFrame) callconv(.{ .x86_interrupt = .{} }) void {
    asm volatile ("movb $0x20, %al; outb %al, $0x20");
}

fn slaveIrqEntry(_: *const InterruptFrame) callconv(.{ .x86_interrupt = .{} }) void {
    asm volatile ("outb %%al, $0xA0; outb %%al, $0x20"
        :
        : [eoi] "{al}" (@as(u8, 0x20)),
    );
}

// Acknowledged at the local APIC's EOI register.
pub var apic_base: usize = 0xFEE0_0000;

fn wakeEntry(_: *const InterruptFrame) callconv(.{ .x86_interrupt = .{} }) void {
    @as(*volatile u32, @ptrFromInt(apic_base + 0xB0)).* = 0;
}

fn spuriousEntry(_: *const InterruptFrame) callconv(.{ .x86_interrupt = .{} }) void {}

// For other cores to load the same.
pub fn storeGdtr(to: *[6]u8) void {
    asm volatile ("sgdt (%[p])"
        :
        : [p] "r" (to),
        : "memory"
    );
}

pub fn storeIdtr(to: *[6]u8) void {
    asm volatile ("sidt (%[p])"
        :
        : [p] "r" (to),
        : "memory"
    );
}

const InterruptFrame = extern struct {
    eip: u32,
    cs: u32,
    eflags: u32,
};

fn keyboardIrqEntry(_: *const InterruptFrame) callconv(.{ .x86_interrupt = .{} }) void {
    keyboard_irq();
    asm volatile ("movb $0x20, %al; outb %al, $0x20");
}

fn mouseIrqEntry(_: *const InterruptFrame) callconv(.{ .x86_interrupt = .{} }) void {
    mouse_irq();
    // The slave PIC first, then the master's cascade line:
    asm volatile ("outb %%al, $0xA0; outb %%al, $0x20"
        :
        : [eoi] "{al}" (@as(u8, 0x20)),
    );
}

// The CPU pushes an error code for these; the stubs push 0 for
// the others, so the frames match.
fn hasErrorCode(v: u8) bool {
    return switch (v) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

fn stub(comptime v: u8) *const fn () callconv(.naked) void {
    return &struct {
        fn entry() callconv(.naked) void {
            asm volatile ((if (hasErrorCode(v)) "" else "pushl $0\n") ++
                    std.fmt.comptimePrint("pushl ${d}\n", .{v}) ++
                    "jmp zdos_exception_common");
        }
    }.entry;
}

export fn zdos_exception_common() callconv(.naked) void {
    asm volatile (
        \\pushal
        \\cld
        \\push %%esp
        \\call zdos_exception_dispatch
    );
}

export fn zdos_exception_dispatch(frame: *const ExceptionFrame) callconv(.c) noreturn {
    handler(frame);
}
