// The local APIC of each core (xAPIC: registers at its
// physical address, no paging), for starting the other cores
// and waking them, and their one-shot timers. Only where the
// BIOS left it on: switching it on would take the PICs'
// interrupts away from core 0.
const std = @import("std");
const arch = @import("../../arch/x86.zig");
const cpuid = @import("../../arch/x86_cpu.zig").cpuid;
const clock = @import("clock.zig");

const reg_id = 0x20;
const reg_eoi = 0xB0;
const reg_spurious = 0xF0;
const reg_icr_low = 0x300;
const reg_icr_high = 0x310;
const reg_lvt_timer = 0x320;
const reg_lint0 = 0x350;
const reg_lint1 = 0x360;
const reg_timer_initial = 0x380;
const reg_timer_current = 0x390;
const reg_timer_divide = 0x3E0;

var ready = false;
var ticks_per_ms: u32 = 0;

// IPIS TO CORE 0
// An IPI taken in a BIOS call goes through the
// real-mode table: no ZDOS handler, no EOI. While
// core 0 is sealed none is sent; the call's end
// arms its timer at once instead. The gate keeps
// a send from slipping past the seal.
var core0_apic: u32 = 0xFFFF_FFFF; // set by init() on core 0
var gate = std.atomic.Value(u32).init(0);
var core0_sealed = std.atomic.Value(bool).init(false);

fn gateLock() void {
    while (gate.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn gateUnlock() void {
    gate.store(0, .release);
}

fn read(reg: usize) u32 {
    // 32 bits wide, as the APIC wants (see arch/mmio.zig)
    return asm volatile ("movl (%[p]), %[r]"
        : [r] "=r" (-> u32),
        : [p] "r" (arch.apic_base + reg),
        : "memory"
    );
}

fn write(reg: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(arch.apic_base + reg)).* = value;
}

fn rdmsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
    );
    return @as(u64, hi) << 32 | lo;
}

// Core 0's: true if usable. Software-disabled (all
// its inputs masked): on, with the PICs through LINT0
// as virtual wire, as the MP specification sets it.
pub fn init() bool {
    if (ready) return true;
    const edx = cpuid(1, 0)[3];
    if (edx & (1 << 9) == 0 or edx & (1 << 5) == 0) return false; // no APIC, no MSRs
    const base_msr = rdmsr(0x1B);
    if (base_msr & (1 << 11) == 0) return false; // off globally
    if (base_msr >> 32 != 0) return false; // above 4 GiB: unreachable without paging
    arch.apic_base = @intCast(base_msr & 0xFFFF_F000);
    // init() runs on core 0 first:
    if (core0_apic == 0xFFFF_FFFF) core0_apic = id();
    if (read(reg_spurious) & 0x100 == 0) {
        write(reg_lint0, 0x700); // ExtINT
        write(reg_lint1, 0x400); // NMI
        write(reg_spurious, 0x100 | 0xFF);
    }
    // The timer's rate: counting down for about 10 ms, masked; the
    // time it really took from the clock (a delay overshoots, under
    // emulation by several percent: every
    // deadline would be that much late)
    write(reg_timer_divide, 0x3); // the bus clock / 16
    write(reg_lvt_timer, 1 << 16);
    write(reg_timer_initial, 0xFFFF_FFFF);
    const t0 = clock.nanos();
    clock.delayUs(10_000);
    const counted: u64 = 0xFFFF_FFFF - read(reg_timer_current);
    const took = @max(1, clock.nanos() - t0);
    ticks_per_ms = @intCast(@min(counted * 1_000_000 / took, 0xFFFF_FFFF));
    write(reg_timer_initial, 0);
    ready = true;
    return true;
}

pub fn id() u32 {
    return read(reg_id) >> 24;
}

// Another core's own: on, its inputs from the PICs masked
pub fn initOther() void {
    write(reg_lint0, 1 << 16);
    write(reg_lint1, 0x400);
    write(reg_spurious, 0x100 | 0xFF);
}

// Each core has its own ICR, so cores don't disturb each other;
// but the two writes (destination, then command) must not be
// split by an interrupt on this core whose handler sends an IPI
// too (the scheduler's kick): it would overwrite the
// destination, and ours would go to the wrong core.
// Hence interrupts off for the sequence (no lock: a handler
// waiting for a lock its interrupted
// code holds would never go on)
pub fn sendIpi(apic: u32, low: u32) void {
    const f = asm volatile ("pushfl; cli; popl %[f]"
        : [f] "=r" (-> u32),
        :
        : "memory"
    );
    if (apic == core0_apic) {
        // Interrupts off while the gate is held: a
        // handler here must not wait for it:
        gateLock();
        if (!core0_sealed.load(.acquire)) {
            rawSend(apic, low);
            waitSent(); // in core 0's IRR before the gate opens
        }
        gateUnlock();
    } else {
        rawSend(apic, low);
    }
    if (f & 0x200 != 0) asm volatile ("sti" ::: "memory");
}

fn rawSend(apic: u32, low: u32) void {
    while (read(reg_icr_low) & (1 << 12) != 0) std.atomic.spinLoopHint(); // delivery pending
    write(reg_icr_high, apic << 24);
    write(reg_icr_low, low);
}

fn waitSent() void {
    while (read(reg_icr_low) & (1 << 12) != 0) std.atomic.spinLoopHint();
}

// Core 0, interrupts off, before a BIOS call: IPIs
// to it held back from now on. False (not sealed)
// if one of `vectors` is pending and if_on: the
// caller takes it first and tries again.
pub fn sealCore0(if_on: bool, vectors: []const u8) bool {
    gateLock();
    defer gateUnlock();
    if (if_on) {
        for (vectors) |v| if (pending(v)) return false;
    }
    core0_sealed.store(true, .release);
    return true;
}

// Core 0, after the call: IPIs go through again
// (what was held back: the caller's timer tick)
pub fn unsealCore0() void {
    const f = asm volatile ("pushfl; cli; popl %[f]"
        : [f] "=r" (-> u32),
        :
        : "memory"
    );
    gateLock();
    core0_sealed.store(false, .release);
    gateUnlock();
    if (f & 0x200 != 0) asm volatile ("sti" ::: "memory");
}

// This core's timer: once, after us, as interrupt `vector`
pub fn oneShot(vector: u8, us: u32) void {
    if (ticks_per_ms == 0) return;
    write(reg_timer_divide, 0x3);
    write(reg_lvt_timer, vector);
    const ticks = @as(u64, ticks_per_ms) * us / 1000;
    write(reg_timer_initial, @intCast(@max(1, @min(ticks, 0xFFFF_FFFF))));
}

pub fn stopOneShot() void {
    write(reg_timer_initial, 0);
}

pub fn timerWorks() bool {
    return ticks_per_ms != 0;
}

// CORE 0's TIMER AS THE SCHEDULER'S (switching.zig, B3)

// One-shot at nanos() == at as interrupt `vector` (null: off)
pub fn armAt(vector: u8, at: ?u64) void {
    if (ticks_per_ms == 0) return;
    const ns = at orelse return write(reg_timer_initial, 0);
    const now = clock.nanos();
    const left: u64 = if (ns > now) @min(ns - now, 1_000_000_000) else 0;
    const ticks = @as(u64, ticks_per_ms) * left / 1_000_000;
    write(reg_timer_divide, 0x3);
    write(reg_lvt_timer, vector);
    write(reg_timer_initial, @intCast(@max(1, @min(ticks, 0xFFFF_FFFF))));
}

// No timer interrupt from now on (bit 16 of its entry), until armAt
pub fn maskTimer() void {
    write(reg_lvt_timer, read(reg_lvt_timer) | (1 << 16));
    write(reg_timer_initial, 0);
}

// The interrupt is accepted but not yet taken (IRR)
pub fn pending(vector: u8) bool {
    return read(0x200 + @as(usize, vector / 32) * 0x10) & (@as(u32, 1) << @intCast(vector % 32)) != 0;
}

pub fn endOfInterrupt() void {
    write(reg_eoi, 0);
}
