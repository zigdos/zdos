// ARM64 idling (cpu.zig), the first way that works:
// 1. `wfi` woken by a generic timer armed 1 ms ahead (IRQs
//    masked in the CPU; wfi wakes anyway). Firmware disables the
//    timer in the GIC on exit, so timerReachesCore tests once
//    that the IRQ arrives, else wfi could hang.
// 2. `wfe` woken by the timer's event stream (no GIC needed;
//    QEMU just spins).
// Timers tried: EL1 virtual, then physical; at EL2
// (Raspberry Pi firmware) physical, then hypervisor.
const std = @import("std");
const arch = @import("../../arch.zig");
const acpi = @import("acpi.zig");
const gic = @import("gic.zig");

const Timer = enum { virtual, physical, hypervisor };

var timer: ?Timer = null; // way 1 with this timer; null: way 2
var ticks_per_ms: u64 = 0;

pub fn init() bool {
    const at_el2 = (asm volatile ("mrs %[r], CurrentEL"
        : [r] "=r" (-> u64),
    ) >> 2) & 3 == 2;
    installVectors(at_el2);
    const freq = asm volatile ("mrs %[r], cntfrq_el0"
        : [r] "=r" (-> u64),
    );
    if (freq < 1000) return false;
    ticks_per_ms = freq / 1000;

    const candidates: [2]Timer = if (at_el2) .{ .physical, .hypervisor } else .{ .virtual, .physical };
    for (candidates) |t| {
        _ = gic.enablePpi(interruptOf(t));
        if (timerReachesCore(t)) {
            timer = t;
            return true;
        }
    }
    startEventStream(at_el2);
    return true;
}

// Once tasks switch, the timer ticks every millisecond by
// itself (its IRQ is taken:
// switch_arm64.zig) and wfi waits for it
pub var ticking = false;

pub fn wait() void {
    if (ticking) return asm volatile ("wfi" ::: "memory");
    timedWait();
}

// Until this core's own timer, armed for
// a millisecond (or the event stream)
fn timedWait() void {
    if (timer) |t| {
        // Re-arming ends the timer's last signal; the next one comes in 1 ms
        switch (t) {
            inline else => |ct| arm(ct, ticks_per_ms),
        }
        asm volatile ("wfi" ::: "memory");
    } else {
        asm volatile ("wfe" ::: "memory");
    }
}

// FOR TASK SWITCHING (switch_arm64.zig)
// The timer's interrupt, if its interrupt
// reaches this core (else no ticks)
pub fn timerInterrupt() ?u32 {
    return interruptOf(timer orelse return null);
}

// The next tick in a millisecond
// (re-arming also ends this one's signal)
pub fn nextTick() void {
    if (timer) |t| switch (t) {
        inline else => |ct| arm(ct, ticks_per_ms),
    };
}

// The next interrupt at nanos() == at (null: none; past:
// at once). TVAL is relative and 32 bits signed: far deadlines
// come back as an early wake.
pub fn armDeadline(at: ?u64) void {
    const t = timer orelse return;
    const ns = at orelse {
        switch (t) {
            inline else => |ct| asm volatile ("msr " ++ register(ct, "ctl") ++ ", %[off]\nisb"
                :
                : [off] "r" (@as(u64, 0)),
                : "memory"
            ),
        }
        return;
    };
    const clock = @import("clock.zig");
    const now = clock.nanos();
    const left = if (ns > now) ns - now else 0;
    const ticks = @min(clock.timestampAt(left) -% clock.timestampAt(0) + 1, 0x7FFF_FFFF);
    switch (t) {
        inline else => |ct| arm(ct, ticks),
    }
}

// OTHER CORES (smp_arm64.zig)
// A started core: its exception vectors, and the way it sleeps:
// true with core 0's timer through the GIC (if it reaches this
// core too), false with the event stream and wfe
pub fn initOtherCore() bool {
    const at_el2 = (asm volatile ("mrs %[r], CurrentEL"
        : [r] "=r" (-> u64),
    ) >> 2) & 3 == 2;
    installVectors(at_el2);
    if (timer) |t| {
        _ = gic.enablePpi(interruptOf(t));
        if (timerReachesCore(t)) return true;
    }
    startEventStream(at_el2);
    return false;
}

// Other cores don't tick: they arm their own timer for up to us
// (gic.kick_sgi ends it sooner), else the event stream wakes them
pub fn sleepOtherCore(on_timer: bool, us: u32) void {
    const t = (if (on_timer) timer else null) orelse return asm volatile ("wfe" ::: "memory");
    const ticks = @max(1, @min(ticks_per_ms * us / 1000, 0x7FFF_FFFF));
    switch (t) {
        inline else => |ct| arm(ct, ticks),
    }
    asm volatile ("wfi" ::: "memory");
    // IRQs stay masked here: what woke it is taken by hand,
    // the timer first switched off so its signal ends:
    armDeadline(null);
    var n: u32 = 0;
    while (n < 8) : (n += 1) {
        const taken = gic.acknowledge();
        if (gic.idOf(taken) == gic.spurious) break;
        gic.endOfInterrupt(taken);
    }
}

// Whether the timer's interrupt reaches the core: no IRQ
// signalled before, one once the timer is armed to go off
// at once, none again once it is switched off (each seen
// within 5 ms). The timer is left switched off.
fn timerReachesCore(t: Timer) bool {
    switch (t) {
        inline else => |ct| {
            if (irqSignalled()) return false; // something else: the test would prove nothing
            arm(ct, 0);
            const reached = waitIrq(true);
            asm volatile ("msr " ++ register(ct, "ctl") ++ ", %[off]\nisb"
                :
                : [off] "r" (@as(u64, 0)),
                : "memory"
            );
            return reached and waitIrq(false);
        },
    }
}

// The timer's interrupt number: from ACPI's GTDT (non-secure
// EL1 timer at byte 56, virtual at
// 64, EL2 at 72), else the usual ones
fn interruptOf(t: Timer) u32 {
    const at: usize, const usual: u32 = switch (t) {
        .physical => .{ 56, 30 },
        .virtual => .{ 64, 27 },
        .hypervisor => .{ 72, 26 },
    };
    const gtdt = acpi.find("GTDT") orelse return usual;
    if (gtdt.len < at + 4) return usual;
    const id = std.mem.readInt(u32, gtdt[at..][0..4], .little);
    return if (id >= 16 and id < 32) id else usual;
}

// ISR_EL1 bit 7: an IRQ is signalled to the core, masked or not
fn irqSignalled() bool {
    return asm volatile ("mrs %[r], isr_el1"
        : [r] "=r" (-> u64),
    ) & (1 << 7) != 0;
}

// Up to 5 ms for the IRQ signal to become `on`
fn waitIrq(on: bool) bool {
    const start = arch.timestamp();
    while (arch.timestamp() - start < 5 * ticks_per_ms) {
        if (irqSignalled() == on) return true;
    }
    return false;
}

// The timer goes off in `ticks` (0: now), its interrupt not
// masked at the timer (CTL: bit 0 enable, bit 1 mask)
fn arm(comptime t: Timer, ticks: u64) void {
    asm volatile ("msr " ++ register(t, "tval") ++ ", %[ticks]\n" ++
            "msr " ++ register(t, "ctl") ++ ", %[on]\n" ++
            "isb"
        :
        : [ticks] "r" (ticks),
          [on] "r" (@as(u64, 1)),
        : "memory"
    );
}

fn register(comptime t: Timer, comptime name: []const u8) []const u8 {
    return switch (t) {
        .virtual => "cntv_" ++ name ++ "_el0",
        .physical => "cntp_" ++ name ++ "_el0",
        .hypervisor => "cnthp_" ++ name ++ "_el2",
    };
}

// An event about every millisecond: counter bit n flips every
// 2^(n+1) ticks, so the largest n with 2^(n+1) <= ticks_per_ms
fn startEventStream(at_el2: bool) void {
    var n: u6 = 0;
    while (n < 15 and (@as(u64, 4) << n) <= ticks_per_ms) n += 1;
    const bits: u64 = (1 << 2) | (@as(u64, n) << 4);
    if (at_el2) {
        const v = asm volatile ("mrs %[r], cnthctl_el2"
            : [r] "=r" (-> u64),
        );
        asm volatile ("msr cnthctl_el2, %[v]"
            :
            : [v] "r" ((v & ~@as(u64, 0xFC)) | bits),
        );
    } else {
        const v = asm volatile ("mrs %[r], cntkctl_el1"
            : [r] "=r" (-> u64),
        );
        asm volatile ("msr cntkctl_el1, %[v]"
            :
            : [v] "r" ((v & ~@as(u64, 0xFC)) | bits),
        );
    }
    asm volatile ("isb");
}

//
// Own exception vectors (the firmware's memory may be reused):
// a crash screen. Each entry switches to its own stack (the one
// in use may be what failed).

const vector_entry =
    \\.balign 128
    \\mov x0, #{d}
    \\adrp x1, zdos_arm64_crash_stack
    \\add x1, x1, :lo12:zdos_arm64_crash_stack
    \\add x1, x1, #4, lsl #12
    \\mov sp, x1
    \\b zdos_arm64_crash
    \\
;

// Entries 4 and 5 (from ZDOS's level on its stack: synchronous,
// IRQ) go to task switching (switch_arm64.zig): an SVC is a
// task giving the CPU up, the timer's IRQ the scheduler's tick;
// anything else there is a crash too
comptime {
    var text: []const u8 = ".text\n.balign 2048\n.global zdos_arm64_vectors\nzdos_arm64_vectors:\n";
    for (0..16) |i| {
        text = text ++ switch (i) {
            4 => ".balign 128\nb zdos_arm64_sync_spx\n",
            5 => ".balign 128\nb zdos_arm64_irq_spx\n",
            else => std.fmt.comptimePrint(vector_entry, .{i}),
        };
    }
    asm (text);
}

export var zdos_arm64_crash_stack: [16384]u8 align(16) = undefined;
extern const zdos_arm64_vectors: u8;

fn installVectors(at_el2: bool) void {
    if (at_el2) {
        asm volatile ("msr S3_4_C12_C0_0, %[v]; isb"
            :
            : [v] "r" (@intFromPtr(&zdos_arm64_vectors)),
        );
    } else {
        asm volatile ("msr vbar_el1, %[v]; isb"
            :
            : [v] "r" (@intFromPtr(&zdos_arm64_vectors)),
        );
    }
}

// Entries 0-3: from the current level on SP_EL0; 4-7:
// on SP_ELx (ZDOS); 8-15: from a lower level. In each group:
// synchronous, IRQ, FIQ, SError.
const kinds = [4][]const u8{ "Synchronous exception", "IRQ", "FIQ", "SError" };

export fn zdos_arm64_crash(vector: u64) callconv(.c) noreturn {
    const el2 = (asm volatile ("mrs %[r], CurrentEL"
        : [r] "=r" (-> u64),
    ) >> 2) & 3 == 2;
    var esr: u64 = undefined;
    var elr: u64 = undefined;
    var far: u64 = undefined;
    if (el2) {
        asm volatile ("mrs %[a], S3_4_C5_C2_0; mrs %[b], S3_4_C4_C0_1; mrs %[c], S3_4_C6_C0_0"
            : [a] "=r" (esr),
              [b] "=r" (elr),
              [c] "=r" (far),
        );
    } else {
        asm volatile ("mrs %[a], esr_el1; mrs %[b], elr_el1; mrs %[c], far_el1"
            : [a] "=r" (esr),
              [b] "=r" (elr),
              [c] "=r" (far),
        );
    }
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf,
        \\
        \\*** CPU exception: {s} (vector {d})
        \\PC={x:0>16} ESR={x:0>8} FAR={x:0>16}
        \\System halted. Restart the computer.
        \\
    , .{ kinds[vector % 4], vector, elr, esr, far }) catch "\n*** CPU exception. System halted.\n";
    const console = @import("console.zig");
    console.setColor(15, 4);
    console.write(text);
    while (true) asm volatile ("msr daifset, #0xf; wfi");
}
