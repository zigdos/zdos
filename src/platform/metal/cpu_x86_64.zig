// x86_64 interrupts for the metal editions (cpu.zig): own IDT,
// exceptions to the crash screen, a 1 ms local APIC timer.
// The 8259 PICs are remapped to 0x20-0x2F and masked, as are
// all I/O APIC inputs. The local APIC is used in whichever mode
// the firmware left (xAPIC or x2APIC).
const std = @import("std");
const port = @import("../../arch/x86_port.zig");
const mmio = @import("../../arch/mmio.zig");
const acpi = @import("acpi.zig");
const clock = @import("clock.zig");
const console = @import("console.zig");
const fault = @import("fault.zig");
const switching = @import("switch_x86_64.zig");
const paging = @import("paging.zig");
const memory = @import("memory.zig");

const timer_vector = 0x30;
const spurious_vector = 0xFF;
const timer_hz = 1000;

const IdtEntry = extern struct {
    offset_low: u16,
    selector: u16,
    ist: u8 = 0,
    type_attr: u8, // 0x8E: present, ring 0, interrupt gate
    offset_mid: u16,
    offset_high: u32,
    reserved: u32 = 0,
};

// What the CPU pushes for an interrupt or exception
const InterruptFrame = extern struct {
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

const Interrupt = std.builtin.CallingConvention{ .x86_64_interrupt = .{} };

var idt: [256]IdtEntry align(16) = undefined;
var x2apic = false;
var lapic_base: usize = 0; // xAPIC: the registers' address

pub fn init() bool {
    // The x87 / SSE state as after reset, not the firmware's (its
    // precision or leftover x87 registers break long double)
    const mxcsr: u32 = 0x1F80;
    asm volatile ("fninit; ldmxcsr (%[p])"
        :
        : [p] "r" (&mxcsr),
        : "memory"
    );
    const cs = asm volatile ("mov %%cs, %[r]"
        : [r] "=r" (-> u16),
    );
    // Exceptions 0-31 to the crash screen,
    // everything else acknowledged and ignored
    inline for (0..32) |v| idt[v] = gate(cs, @intFromPtr(&Exception(v).stub));
    for (32..256) |v| idt[v] = gate(cs, @intFromPtr(&ignoredInterrupt));
    idt[timer_vector] = gate(cs, @intFromPtr(&timerInterrupt));
    idt[spurious_vector] = gate(cs, @intFromPtr(&spuriousInterrupt));
    const Idtr = packed struct { limit: u16, base: u64 };
    const idtr: Idtr = .{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&idtr),
    );

    maskPics();
    maskIoApics();
    return startTimer();
}

fn gate(cs: u16, addr: usize) IdtEntry {
    return .{
        .offset_low = @truncate(addr),
        .selector = cs,
        .type_attr = 0x8E,
        .offset_mid = @truncate(addr >> 16),
        .offset_high = @truncate(addr >> 32),
    };
}

// Sleeps until the next interrupt: the timer's at the latest.
// sti takes effect after the next instruction, so an interrupt
// pending already still wakes the hlt.
pub fn wait() void {
    if (interrupts_on) {
        asm volatile ("sti; hlt" ::: "memory");
    } else {
        asm volatile ("sti; hlt; cli" ::: "memory");
    }
}

// FOR TASK SWITCHING (SWITCH_X86_64.ZIG)

// Once tasks switch, interrupts stay on (the timer preempts programs)
var interrupts_on = false;
var timer_running = false;

pub fn interruptsOn() void {
    interrupts_on = true;
    asm volatile ("sti" ::: "memory");
}

pub fn timerRunning() bool {
    return timer_running;
}

pub fn setGate(vector: u8, addr: usize) void {
    idt[vector] = gate(codeSelector(), addr);
}

pub fn endOfInterrupt() void {
    apicWrite(reg_eoi, 0);
}

// GDT

// The firmware's GDT lives in boot-time memory: before that is
// reused (paging.zig), a copy takes over with the same selector
// numbers, so loaded segments stay valid. False if a selector
// is beyond the table here. After the firmware's 16 entries: a
// TSS descriptor (two entries) per core
const tss_first = 16;
const max_cores = 64;
var gdt: [tss_first + 2 * max_cores]u64 align(16) = [_]u64{0} ** (tss_first + 2 * max_cores);
var own_gdt = false;

pub fn ownGdt() bool {
    const cs = asm volatile ("mov %%cs, %[r]"
        : [r] "=r" (-> u16),
    );
    const data = [_]u16{
        asm volatile ("mov %%ss, %[r]"
            : [r] "=r" (-> u16),
        ),
        asm volatile ("mov %%ds, %[r]"
            : [r] "=r" (-> u16),
        ),
        asm volatile ("mov %%es, %[r]"
            : [r] "=r" (-> u16),
        ),
        asm volatile ("mov %%fs, %[r]"
            : [r] "=r" (-> u16),
        ),
        asm volatile ("mov %%gs, %[r]"
            : [r] "=r" (-> u16),
        ),
    };
    if (cs >> 3 >= gdt.len or cs >> 3 == 0) return false;
    gdt[cs >> 3] = 0x00AF_9A00_0000_FFFF; // code: present, ring 0, 64-bit
    for (data) |sel| {
        if (sel >> 3 == 0) continue; // the null selector: fine in 64-bit mode
        if (sel >> 3 >= gdt.len or sel >> 3 == cs >> 3) return false;
        gdt[sel >> 3] = 0x00CF_9200_0000_FFFF; // data: present, ring 0, writable
    }
    const Gdtr = packed struct { limit: u16, base: u64 };
    const gdtr: Gdtr = .{ .limit = @sizeOf(@TypeOf(gdt)) - 1, .base = @intFromPtr(&gdt) };
    asm volatile ("lgdt (%[p])"
        :
        : [p] "r" (&gdtr),
        : "memory"
    );
    own_gdt = true;
    if (loadTss(0)) {
        // Page and double faults on the core's own stack: one that ran
        // off its end (a guard, memory.allocStack) can still be handled
        idt[8].ist = 1;
        idt[14].ist = 1;
        paging.setFaultStacks(true);
    }
    return true;
}

// FAULT STACKS
// A 64-bit TSS per core: only IST1 is
// used, 16 KiB for page and double faults

var tss: [max_cores][104]u8 align(16) = undefined;
const fault_stack_pages = 4;

// The core's TSS (core 0: in ownGdt; the others as they start).
// False without ZDOS's GDT or memory:
// then faults stay on the current stack.
pub fn loadTss(index: usize) bool {
    if (!own_gdt or index >= max_cores) return false;
    const stack = memory.allocPages(fault_stack_pages, false) orelse return false;
    const t = &tss[index];
    @memset(t, 0);
    std.mem.writeInt(u64, t[36..44], @intFromPtr(stack) + fault_stack_pages * 4096, .little); // IST1
    std.mem.writeInt(u16, t[102..104], 104, .little); // no I/O permission map
    const base: u64 = @intFromPtr(t);
    const limit: u64 = 103;
    gdt[tss_first + 2 * index] = (limit & 0xFFFF) | ((base & 0xFF_FFFF) << 16) | (@as(u64, 0x89) << 40) | (((limit >> 16) & 0xF) << 48) | (((base >> 24) & 0xFF) << 56);
    gdt[tss_first + 2 * index + 1] = base >> 32;
    const selector: u16 = @intCast((tss_first + 2 * index) * 8);
    asm volatile ("ltr %[s]"
        :
        : [s] "r" (selector),
        : "memory"
    );
    return true;
}

// A core that couldn't load its TSS: no fault stacks for anyone
// (the gates would send its faults to a TSS it doesn't have)
pub fn noFaultStacks() void {
    idt[8].ist = 0;
    idt[14].ist = 0;
    paging.setFaultStacks(false);
}

// INTERRUPT CONTROLLERS

// The PICs reinitialized with their IRQs on 0x20-0x2F (the
// firmware may have left them on
// exception vectors), then all masked
fn maskPics() void {
    port.outb(0x20, 0x11); // ICW1: initialize, ICW4 follows
    port.outb(0xA0, 0x11);
    port.outb(0x21, 0x20); // ICW2: vectors
    port.outb(0xA1, 0x28);
    port.outb(0x21, 0x04); // ICW3: the slave on IRQ 2
    port.outb(0xA1, 0x02);
    port.outb(0x21, 0x01); // ICW4: 8086 mode
    port.outb(0xA1, 0x01);
    port.outb(0x21, 0xFF);
    port.outb(0xA1, 0xFF);
}

// MADT entries of type 1 are I/O APICs: their address at byte
// 4. Register 1 tells the number of inputs; each input's
// redirection entry (registers 0x10
// + 2i) has its mask in bit 16.
fn maskIoApics() void {
    const madt = acpi.find("APIC") orelse return;
    var off: usize = 44;
    while (off + 2 <= madt.len) {
        const len = madt[off + 1];
        if (len < 2 or off + len > madt.len) break;
        if (madt[off] == 1 and len >= 12) {
            const base: usize = std.mem.readInt(u32, madt[off + 4 ..][0..4], .little);
            const inputs = ((ioApicRead(base, 1) >> 16) & 0xFF) + 1;
            for (0..inputs) |i| {
                const reg: u32 = 0x10 + 2 * @as(u32, @intCast(i));
                ioApicWrite(base, reg, ioApicRead(base, reg) | (1 << 16));
            }
        }
        off += len;
    }
}

// An ISA IRQ (COM1's 4) to vector on core 0. MADT type 2 is an
// override: source IRQ at 3, its GSI at 4, flags at 8 (bits
// 0-1 polarity, 3: active low; 2-3 trigger, 3: level); without
// one: GSI = IRQ, edge, active high. Type 1 I/O APICs: their
// first GSI at 8.
pub fn routeIsa(irq: u8, vector: u32) bool {
    const madt = acpi.find("APIC") orelse return false;
    const apic = bootApicId();
    if (apic > 255) return false; // beyond the redirection entry's 8 bits
    var gsi: u32 = irq;
    var flags: u16 = 0;
    var off: usize = 44;
    while (off + 2 <= madt.len) {
        const len = madt[off + 1];
        if (len < 2 or off + len > madt.len) break;
        if (madt[off] == 2 and len >= 10 and madt[off + 3] == irq) {
            gsi = std.mem.readInt(u32, madt[off + 4 ..][0..4], .little);
            flags = std.mem.readInt(u16, madt[off + 8 ..][0..2], .little);
        }
        off += len;
    }
    const low = flags & 3 == 3;
    const level = (flags >> 2) & 3 == 3;
    off = 44;
    while (off + 2 <= madt.len) {
        const len = madt[off + 1];
        if (len < 2 or off + len > madt.len) break;
        if (madt[off] == 1 and len >= 12) {
            const base: usize = std.mem.readInt(u32, madt[off + 4 ..][0..4], .little);
            const first = std.mem.readInt(u32, madt[off + 8 ..][0..4], .little);
            const inputs = ((ioApicRead(base, 1) >> 16) & 0xFF) + 1;
            if (gsi >= first and gsi - first < inputs) {
                const reg: u32 = 0x10 + 2 * (gsi - first);
                ioApicWrite(base, reg + 1, apic << 24);
                // The low half last: it unmasks (bit 16 clear)
                ioApicWrite(base, reg, vector | (if (low) @as(u32, 1) << 13 else 0) | (if (level) @as(u32, 1) << 15 else 0));
                return true;
            }
        }
        off += len;
    }
    return false;
}

fn ioApicRead(base: usize, reg: u32) u32 {
    mmio.write32(base, reg);
    return mmio.read32(base + 0x10);
}

fn ioApicWrite(base: usize, reg: u32, value: u32) void {
    mmio.write32(base, reg);
    mmio.write32(base + 0x10, value);
}

// LOCAL APIC AND ITS TIMER

const apic_base_msr = 0x1B;
const reg_eoi = 0xB0;
const reg_spurious = 0xF0;
const reg_lvt_timer = 0x320;
const reg_timer_initial = 0x380;
const reg_timer_current = 0x390;
const reg_timer_divide = 0x3E0;

fn startTimer() bool {
    const msr = rdmsr(apic_base_msr);
    if (msr & (1 << 11) == 0) return false; // the APIC is off
    x2apic = msr & (1 << 10) != 0;
    lapic_base = @intCast(msr & 0xF_FFFF_F000);

    apicWrite(reg_spurious, 0x100 | spurious_vector); // APIC on
    apicWrite(reg_timer_divide, 0x3); // the bus clock / 16
    // Calibration: counting down from the top for 10 ms, masked
    apicWrite(reg_lvt_timer, 1 << 16);
    apicWrite(reg_timer_initial, 0xFFFF_FFFF);
    // The time it really took from the clock: a delay overshoots
    // (under emulation by several percent,
    // every deadline that much late)
    const t0 = clock.nanos();
    clock.delayUs(10_000);
    const counted: u64 = 0xFFFF_FFFF - apicRead(reg_timer_current);
    const took = @max(1, clock.nanos() - t0);
    const per_tick: u32 = @intCast(@min(counted * 1_000_000 / took / (timer_hz / 1000), 0xFFFF_FFFF));
    if (per_tick == 0) return false;
    apicWrite(reg_lvt_timer, timer_vector | (1 << 17)); // periodic
    apicWrite(reg_timer_initial, per_tick);
    ticks_per_ms = per_tick;
    timer_running = true;
    boot_apic = apicId();
    return true;
}

// Core 0's APIC ID: devices' interrupts
// go there, never to an isolated core
var boot_apic: u32 = 0;

pub fn bootApicId() u32 {
    return boot_apic;
}

var ticks_per_ms: u32 = 0;

// Another core's own timer: once, after us, as
// interrupt `vector` (0: off). Its rate is core 0's
// (the same bus clock).
pub fn oneShot(vector: u8, us: u32) void {
    if (ticks_per_ms == 0) return;
    apicWrite(reg_timer_divide, 0x3);
    apicWrite(reg_lvt_timer, vector);
    const ticks = @as(u64, ticks_per_ms) * us / 1000;
    apicWrite(reg_timer_initial, @intCast(@max(1, @min(ticks, 0xFFFF_FFFF))));
}

pub fn stopOneShot() void {
    apicWrite(reg_timer_initial, 0);
}

// Another core that runs tasks: its own periodic tick, at core
// 0's rate, until the scheduler arms deadlines (armDeadline)
pub fn startTickHere() bool {
    if (ticks_per_ms == 0) return false;
    apicWrite(reg_timer_divide, 0x3);
    apicWrite(reg_lvt_timer, timer_vector | (1 << 17)); // periodic
    apicWrite(reg_timer_initial, ticks_per_ms);
    return true;
}

// DEADLINES (TASKS.ZIG, ONCE SWITCHING RUNS)
// The timer fires once, at a nanos() value: TSC-deadline mode
// where the CPU has it (CPUID.1:ECX bit 24), else a one-shot
// count from now. Per core.

const tsc_deadline_msr = 0x6E0;
var tsc_deadline: ?bool = null; // found out once

fn hasTscDeadline() bool {
    if (tsc_deadline) |d| return d;
    const d = @import("../../arch/x86_cpu.zig").cpuid(1, 0)[2] & (1 << 24) != 0;
    tsc_deadline = d;
    return d;
}

// at: nanos() of the wanted interrupt
// (in the past: at once); null: none
pub fn armDeadline(at: ?u64) void {
    if (ticks_per_ms == 0) return;
    const ns = at orelse {
        if (hasTscDeadline()) wrmsr(tsc_deadline_msr, 0) else apicWrite(reg_timer_initial, 0);
        return;
    };
    if (hasTscDeadline()) {
        apicWrite(reg_lvt_timer, timer_vector | (2 << 17)); // TSC-deadline
        // WRMSR to the deadline isn't ordered after the LVT write by itself
        asm volatile ("mfence; lfence" ::: "memory");
        wrmsr(tsc_deadline_msr, @max(1, clock.timestampAt(ns)));
        return;
    }
    const now = clock.nanos();
    const left = if (ns > now) ns - now else 0;
    const ticks = @as(u64, ticks_per_ms) * left / 1_000_000;
    apicWrite(reg_timer_divide, 0x3);
    apicWrite(reg_lvt_timer, timer_vector); // one-shot
    apicWrite(reg_timer_initial, @intCast(@max(1, @min(ticks, 0xFFFF_FFFF))));
}

// GS's base: a core's own slot (switch_x86_64.zig's core index)
pub fn setGsBase(v: u64) void {
    wrmsr(0xC000_0101, v);
}

// FOR THE OTHER CORES (SMP_X86_64.ZIG)

pub fn apicReady() bool {
    return x2apic or lapic_base != 0;
}

pub fn apicId() u32 {
    return if (x2apic) @truncate(rdmsr(0x802)) else apicRead(0x20) >> 24;
}

// An IPI (ICR low word: vector, delivery mode, level) to the
// core with this APIC ID, once the previous one has gone out.
pub fn sendIpi(id: u32, low: u32) void {
    if (x2apic) return wrmsr(0x830, (@as(u64, id) << 32) | low);
    while (apicRead(0x300) & (1 << 12) != 0) std.atomic.spinLoopHint(); // delivery pending
    apicWrite(0x310, id << 24);
    apicWrite(0x300, low);
    // if (x2apic) return wrmsr(0x830, (@as(u64, id) << 32) | low);
    // const f = asm volatile ("pushfq; cli; popq %[f]"
    //     : [f] "=r" (-> u64),
    //     :
    //     : "memory"
    // );
    // while (apicRead(0x300) & (1 << 12) != 0) std.atomic.spinLoopHint(); // delivery pending
    // apicWrite(0x310, id << 24);
    // apicWrite(0x300, low);
    // //if (f & 0x200 != 0) asm volatile ("sti" ::: "memory");
}

// A started core's local APIC: x2APIC mode as on core 0, then
// on (its spurious vector); it gets no timer: IPIs wake it
pub fn initOtherCore() void {
    if (x2apic) wrmsr(apic_base_msr, rdmsr(apic_base_msr) | (1 << 10) | (1 << 11));
    apicWrite(reg_spurious, 0x100 | spurious_vector);
}

pub fn storeGdtr(to: *[10]u8) void {
    asm volatile ("sgdt (%[p])"
        :
        : [p] "r" (to),
        : "memory"
    );
}

pub fn storeIdtr(to: *[10]u8) void {
    asm volatile ("sidt (%[p])"
        :
        : [p] "r" (to),
        : "memory"
    );
}

pub fn codeSelector() u16 {
    return asm volatile ("mov %%cs, %[r]"
        : [r] "=r" (-> u16),
    );
}

// The data segments' selector (SS's: DS may be the null selector)
pub fn dataSelector() u16 {
    return asm volatile ("mov %%ss, %[r]"
        : [r] "=r" (-> u16),
    );
}

pub fn cr3() u64 {
    return asm volatile ("mov %%cr3, %[r]"
        : [r] "=r" (-> u64),
    );
}

pub fn cr4() u64 {
    return asm volatile ("mov %%cr4, %[r]"
        : [r] "=r" (-> u64),
    );
}

pub fn rdmsrPub(msr: u32) u64 {
    return rdmsr(msr);
}

fn apicRead(reg: u32) u32 {
    if (x2apic) return @truncate(rdmsr(0x800 + (reg >> 4)));
    return mmio.read32(lapic_base + reg);
}

fn apicWrite(reg: u32, value: u32) void {
    if (x2apic) return wrmsr(0x800 + (reg >> 4), value);
    mmio.write32(lapic_base + reg, value);
}

fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | lo;
}

fn wrmsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
    );
}

// HANDLERS

fn timerInterrupt(_: *InterruptFrame) callconv(Interrupt) void {
    apicWrite(reg_eoi, 0);
}

// Something the firmware left routed: acknowledged, else ignored
fn ignoredInterrupt(_: *InterruptFrame) callconv(Interrupt) void {
    apicWrite(reg_eoi, 0);
}

// The APIC's spurious interrupt gets no acknowledgement
fn spuriousInterrupt(_: *InterruptFrame) callconv(Interrupt) void {}

// Exceptions 8, 10-14, 17, 21, 29 and 30 push an error code
fn hasErrorCode(v: usize) bool {
    return switch (v) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

// A stub per exception: the vector (and a 0 where the CPU
// pushes no error code) onto the stack, then the common part.
// Naked: the UEFI target's unwind tables can't describe an
// interrupt function that saves SSE registers, and the crash
// screen never returns, so nothing needs saving.
fn Exception(comptime vector: usize) type {
    return struct {
        fn stub() callconv(.naked) void {
            asm volatile ((if (hasErrorCode(vector)) "" else "pushq $0\n") ++
                    std.fmt.comptimePrint("pushq ${d}\n", .{vector}) ++
                    "jmp zdos_metal_exception\n");
        }
    };
}

// The stack as the stubs leave it
const ExceptionStack = extern struct {
    vector: u64,
    code: u64,
    frame: InterruptFrame,
};

// Calls zdos_metal_fault with the stack's address, on a
// 16-byte aligned stack with the 32 bytes of shadow space the
// calling convention wants. If it returns, it made the frame
// resume elsewhere (a program's fault, for the kernel:
// fault.zig): vector and code off, iretq.
export fn zdos_metal_exception() callconv(.naked) void {
    asm volatile (
        \\mov %%rsp, %%rbx
        \\and $-16, %%rsp
        \\sub $32, %%rsp
        \\mov %%rbx, %%rcx
        \\call zdos_metal_fault
        \\mov %%rbx, %%rsp
        \\add $16, %%rsp
        \\iretq
    );
}

// A program's fault (its code, not ZDOS's) goes to the kernel
// as a signal: the frame resumes in fault.entry on the
// program's stack, below its red zone and a gap.
// Anything else is the crash screen.
export fn zdos_metal_fault(stack: *ExceptionStack) callconv(.c) void {
    const v = stack.vector;
    // A page fault the tables allow (RW_NX: another core
    // changed the entry): the stale TLB entry goes, the
    // access runs again. Error code: bit 1 write, 3 reserved
    // bit, 4 instruction fetch.
    if (v == 14 and stack.code & 8 == 0) {
        const addr = asm volatile ("mov %%cr2, %[r]"
            : [r] "=r" (-> u64),
        );
        if (paging.allows(addr, stack.code & 2 != 0, stack.code & 16 != 0)) {
            asm volatile ("invlpg (%[a])"
                :
                : [a] "r" (addr),
                : "memory"
            );
            return;
        }
    }
    const sig = signalOf(v) orelse crash(v, &stack.frame, stack.code);
    if (!fault.wanted(stack.frame.rip, &switching.inProgram)) crash(v, &stack.frame, stack.code);
    const cr2 = asm volatile ("mov %%cr2, %[r]"
        : [r] "=r" (-> u64),
    );
    // Off the stack's end (its guard): the kernel's part runs on the spare
    const overflow = if (v == 14) memory.guardAt(cr2) else null;
    fault.last = .{ .signal = sig, .what = if (overflow != null) "Stack overflow" else exception_names[v], .pc = stack.frame.rip, .addr = if (v == 14) cr2 else 0 };
    stack.frame.rip = @intFromPtr(&fault.entry);
    const below = (stack.frame.rsp -% 128 -% fault.gap) & ~@as(u64, 15);
    const top = overflow orelse memory.guardAt(below) orelse below;
    stack.frame.rsp = (top & ~@as(u64, 15)) -% 8; // as after a call
    stack.frame.rflags = 0x202; // interrupts on
}

// POSIX signals for the exceptions a program's code may cause;
// null: none (double fault, machine check ...:
// ZDOS's crash screen)
fn signalOf(vector: usize) ?u8 {
    return switch (vector) {
        0, 7, 16, 19 => 8, // divide error, no FPU, x87 and SIMD errors: SIGFPE
        1, 3 => 5, // debug, breakpoint: SIGTRAP
        4, 5, 10, 11, 12, 13, 14 => 11, // overflow, bound, TSS, segment, stack, protection, page: SIGSEGV
        6 => 4, // invalid opcode (ud2, Zig's @trap): SIGILL
        17 => 7, // alignment check: SIGBUS
        else => null,
    };
}

const exception_names = [32][]const u8{
    "Division by zero",     "Debug",               "NMI",            "Breakpoint",
    "Overflow",             "Bound range",         "Invalid opcode", "No FPU",
    "Double fault",         "FPU segment overrun", "Invalid TSS",    "Segment not present",
    "Stack fault",          "General protection",  "Page fault",     "Reserved",
    "FPU error",            "Alignment check",     "Machine check",  "SIMD error",
    "Virtualization",       "Control protection",  "Reserved",       "Reserved",
    "Reserved",             "Reserved",            "Reserved",       "Reserved",
    "Hypervisor injection", "VMM communication",   "Security",       "Reserved",
};

// The crash screen: the exception,
// where, and for a page fault the address
fn crash(vector: usize, frame: *const InterruptFrame, code: u64) noreturn {
    const cr2 = asm volatile ("mov %%cr2, %[r]"
        : [r] "=r" (-> u64),
    );
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf,
        \\
        \\*** CPU exception {d}: {s}
        \\RIP={x:0>16} error={x:0>8} RFLAGS={x:0>8}
        \\RSP={x:0>16} CR2={x:0>16}
        \\System halted. Restart the computer.
        \\
    , .{ vector, if (vector == 14 and memory.guardAt(cr2) != null) "Stack overflow (ZDOS's code)" else exception_names[vector], frame.rip, code, frame.rflags, frame.rsp, cr2 }) catch "\n*** CPU exception. System halted.\n";
    console.setColor(15, 4);
    console.write(text);
    while (true) asm volatile ("cli; hlt");
}
