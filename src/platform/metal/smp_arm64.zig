// Starting the other ARM64 cores (smp.zig) with PSCI CPU_ON,
// via HVC or SMC as ACPI's FADT says (byte 129: bit 0 PSCI,
// bit 1 HVC). Cores are the enabled GIC CPU interfaces in
// the MADT (type 0x0B: flags at 12, MPIDR at 68).
// A core starts with the MMU off, so the handover record
// is cleaned to memory first. Idle cores are woken by an SGI
// (gic.kick_sgi), else they look every millisecond.
const std = @import("std");
const smp = @import("smp.zig");
const cpu = @import("cpu_arm64.zig");
const gic = @import("gic.zig");
const acpi = @import("acpi.zig");
const clock = @import("clock.zig");

// What a starting core needs (the offsets below are the entry's)
const Boot = extern struct {
    stack: u64, // 0
    mair: u64, // 8
    tcr: u64, // 16
    ttbr0: u64, // 24
    sctlr: u64, // 32
    mode: u64, // 40: 0 EL1, 1 EL2, 2 EL2 with VHE
    hcr: u64, // 48: VHE only
    index: u64, // 56
    entry: u64, // 64
};

var boot: Boot align(64) = undefined;

comptime {
    asm (
        \\.text
        \\.balign 4
        \\.global zdos_arm64_ap_start
        \\zdos_arm64_ap_start:
        \\    mov x19, x0
        \\    ldr x1, [x19, #0]
        \\    mov sp, x1
        \\    ldr x2, [x19, #40]
        \\    cbz x2, 10f
        \\    cmp x2, #2
        \\    b.eq 20f
        // EL2 without VHE: CPTR_EL2.TFP off,
        // MAIR_EL2, TCR_EL2, TTBR0_EL2, SCTLR_EL2
        \\    mrs x1, S3_4_C1_C1_2
        \\    bic x1, x1, #0x400
        \\    msr S3_4_C1_C1_2, x1
        \\    ldr x1, [x19, #8]
        \\    msr S3_4_C10_C2_0, x1
        \\    ldr x1, [x19, #16]
        \\    msr S3_4_C2_C0_2, x1
        \\    ldr x1, [x19, #24]
        \\    msr S3_4_C2_C0_0, x1
        \\    isb
        \\    sys #4, c8, c7, #0
        \\    dsb nsh
        \\    ldr x1, [x19, #32]
        \\    msr S3_4_C1_C0_0, x1
        \\    isb
        \\    b 30f
        // EL2 with VHE:
        // HCR_EL2 as core 0's, then the EL1 names reach EL2's registers
        \\20:
        \\    ldr x1, [x19, #48]
        \\    msr S3_4_C1_C1_0, x1
        \\    isb
        \\10:
        \\    mrs x1, cpacr_el1
        \\    orr x1, x1, #0x300000
        \\    msr cpacr_el1, x1
        \\    ldr x1, [x19, #8]
        \\    msr mair_el1, x1
        \\    ldr x1, [x19, #16]
        \\    msr tcr_el1, x1
        \\    ldr x1, [x19, #24]
        \\    msr ttbr0_el1, x1
        \\    isb
        \\    ldr x2, [x19, #40]
        \\    cbz x2, 11f
        \\    sys #4, c8, c7, #0
        \\    b 12f
        \\11:
        \\    tlbi vmalle1
        \\12:
        \\    dsb nsh
        \\    ldr x1, [x19, #32]
        \\    msr sctlr_el1, x1
        \\    isb
        \\30:
        \\    ldr x0, [x19, #56]
        \\    ldr x1, [x19, #64]
        \\    blr x1
        \\40:
        \\    wfi
        \\    b 40b
    );
}

extern const zdos_arm64_ap_start: u8;

// Right after leaving the firmware: nothing to keep for later
pub fn reserve() void {}

pub fn startAll(add: *const fn (hw_id: u64) ?smp.Started) void {
    const fadt = acpi.find("FACP") orelse return;
    if (fadt.len < 131) return;
    const flags = std.mem.readInt(u16, fadt[129..131], .little);
    if (flags & 1 == 0) return; // no PSCI
    const use_hvc = flags & 2 != 0;
    const el = (asm volatile ("mrs %[r], CurrentEL"
        : [r] "=r" (-> u64),
    ) >> 2) & 3;
    if (el == 2 and use_hvc) return; // HVC would call ZDOS itself

    // Core 0's translation, for every core
    boot = std.mem.zeroes(Boot);
    if (el == 2) {
        const hcr = asm volatile ("mrs %[r], S3_4_C1_C1_0"
            : [r] "=r" (-> u64),
        );
        if (hcr & (1 << 34) != 0) {
            boot.mode = 2;
            boot.hcr = hcr;
        } else boot.mode = 1;
    }
    if (boot.mode == 1) {
        boot.mair = asm volatile ("mrs %[r], S3_4_C10_C2_0"
            : [r] "=r" (-> u64),
        );
        boot.tcr = asm volatile ("mrs %[r], S3_4_C2_C0_2"
            : [r] "=r" (-> u64),
        );
        boot.ttbr0 = asm volatile ("mrs %[r], S3_4_C2_C0_0"
            : [r] "=r" (-> u64),
        );
        boot.sctlr = asm volatile ("mrs %[r], S3_4_C1_C0_0"
            : [r] "=r" (-> u64),
        );
    } else {
        boot.mair = asm volatile ("mrs %[r], mair_el1"
            : [r] "=r" (-> u64),
        );
        boot.tcr = asm volatile ("mrs %[r], tcr_el1"
            : [r] "=r" (-> u64),
        );
        boot.ttbr0 = asm volatile ("mrs %[r], ttbr0_el1"
            : [r] "=r" (-> u64),
        );
        boot.sctlr = asm volatile ("mrs %[r], sctlr_el1"
            : [r] "=r" (-> u64),
        );
    }
    boot.entry = @intFromPtr(&zdos_arm64_ap_main);

    const own = asm volatile ("mrs %[r], mpidr_el1"
        : [r] "=r" (-> u64),
    ) & 0xFF_00FF_FFFF;
    const madt = acpi.find("APIC") orelse return;
    var off: usize = 44;
    while (off + 2 <= madt.len) {
        const len = madt[off + 1];
        if (len < 2 or off + len > madt.len) break;
        const e = madt[off .. off + len];
        off += len;
        if (e[0] != 0x0B or len < 76) continue;
        if (std.mem.readInt(u32, e[12..16], .little) & 1 == 0) continue; // not enabled
        const mpidr = std.mem.readInt(u64, e[68..76], .little) & 0xFF_00FF_FFFF;
        if (mpidr == own) continue;
        const s = add(mpidr) orelse break;
        startOne(mpidr, s, use_hvc);
    }
}

// CPU_ON (function 0xC4000003: target, entry, context), then up
// to 100 ms for the core to report (smp.coreOnline)
fn startOne(mpidr: u64, s: smp.Started, use_hvc: bool) void {
    boot.stack = s.stack_top;
    boot.index = s.index;
    cleanToMemory(@ptrCast(&boot), @sizeOf(Boot));
    const result = if (use_hvc) asm volatile ("hvc #0"
        : [r] "={x0}" (-> i64),
        : [f] "{x0}" (@as(u64, 0xC400_0003)),
          [t] "{x1}" (mpidr),
          [e] "{x2}" (@intFromPtr(&zdos_arm64_ap_start)),
          [c] "{x3}" (@intFromPtr(&boot)),
        : "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "memory"
    ) else asm volatile (".inst 0xd4000003 // SMC #0"
        : [r] "={x0}" (-> i64),
        : [f] "{x0}" (@as(u64, 0xC400_0003)),
          [t] "{x1}" (mpidr),
          [e] "{x2}" (@intFromPtr(&zdos_arm64_ap_start)),
          [c] "{x3}" (@intFromPtr(&boot)),
        : "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "memory"
    );
    if (result != 0) return;
    const until = clock.millis() + 100;
    while (clock.millis() < until) {
        if (smp.onlineCount() > s.index) return;
        std.atomic.spinLoopHint();
    }
}

// The data cache lines of a range, written back to memory (DC CVAC)
fn cleanToMemory(p: [*]const u8, len: usize) void {
    const ctr = asm volatile ("mrs %[r], ctr_el0"
        : [r] "=r" (-> u64),
    );
    const line = @as(usize, 4) << @intCast((ctr >> 16) & 0xF);
    var a = @intFromPtr(p) & ~(line - 1);
    while (a < @intFromPtr(p) + len) : (a += line) {
        asm volatile ("dc cvac, %[a]"
            :
            : [a] "r" (a),
            : "memory"
        );
    }
    asm volatile ("dsb sy" ::: "memory");
}

// A new core, MMU and FP on, on its stack: its vectors and idle
// timer, then the worker loop
export fn zdos_arm64_ap_main(index: u64) callconv(.c) noreturn {
    smp.cores[index].sleeps_on_timer = cpu.initOtherCore();
    if (smp.cores[index].sleeps_on_timer) gic.enableKick(index);
    smp.workerLoop(@intCast(index));
}

// SGIs where the GIC lets them through (gic.enableKick),
// else the sleeper's next look
pub fn wake(c: *smp.Core) void {
    gic.sendKick(indexOf(c));
}

pub fn jobDone() void {
    gic.sendKick(0);
}

// Kicked cores look again within 50 ms at the latest:
pub fn sleep(c: *smp.Core) void {
    cpu.sleepOtherCore(c.sleeps_on_timer, if (gic.kicks(indexOf(c))) 50_000 else 1000);
}

fn indexOf(c: *const smp.Core) usize {
    return (@intFromPtr(c) - @intFromPtr(&smp.cores[0])) / @sizeOf(smp.Core);
}
