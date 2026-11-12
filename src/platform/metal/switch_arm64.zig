// Task switching on ARM64 for tasks.zig. The timer IRQ,
// device IRQs (irq.zig) and `svc #0` (yield) enter one
// stub via vectors 5 and 4: it saves the state on the
// task's stack, calls the scheduler with sp, and resumes
// the state it returns. Exceptions are taken on the
// interrupted stack (SPSel 1).
//
// A saved state (800 bytes, from the stack pointer up): x0-x30
// (0-247), ELR (248), SPSR (256), FPSR (264), FPCR (272),
// padding, q0-q31 (288-799). ELR and SPSR are EL1's, or EL2's
// at EL2 without VHE (zdos_arm64_el2_registers).
//
// Several cores run tasks: TPIDR_EL1 (EL2's at EL2 without
// VHE) holds a core's index, and once on the new task's stack
// the stub calls finish.
//
// Stack guards (memory.allocStack): before saving, the stub
// checks with AT that the state's 800 bytes are mapped; if not,
// the stack ran into its guard and the state goes on the core's
// overflow stack instead (TPIDRRO_EL0, SP_EL0 and PAR_EL1,
// unused otherwise, hold x0, x1 and the kind meanwhile).
const std = @import("std");
const cpu = @import("cpu_arm64.zig");
const gic = @import("gic.zig");
const irq = @import("irq.zig");
const fault = @import("fault.zig");
const smp = @import("smp.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const Why = @import("switching.zig").Why;

const frame_size = 800;
const elr_offset = 248;

export var zdos_arm64_el2_registers: u64 = 0;
export var zdos_arm64_at_el2: u64 = 0; // AT S1E2W instead of S1E1W
export var zdos_arm64_check_stack: u64 = 0; // the stub's guard check on

// A core's stack for a state that didn't fit on its own (above:
// the stack pointer it had)
const overflow_size = 16 * 1024;
export var zdos_arm64_overflow_stacks: [smp.max_cores][overflow_size]u8 align(16) = undefined;

comptime {
    asm (
        \\.text
        \\.global zdos_arm64_irq_spx
        \\zdos_arm64_irq_spx:
        \\    msr tpidrro_el0, x0
        \\    mov x0, #1
        \\    b zdos_arm64_entry
        \\.global zdos_arm64_sync_spx
        \\zdos_arm64_sync_spx:
        \\    msr tpidrro_el0, x0
        \\    mov x0, #0
        \\// x0: the kind; the interrupted x0 in TPIDRRO_EL0, x1 into SP_EL0
        \\zdos_arm64_entry:
        \\    msr sp_el0, x1
        \\    mov x1, x0
        \\    adrp x0, zdos_arm64_check_stack
        \\    ldr x0, [x0, :lo12:zdos_arm64_check_stack]
        \\    cbz x0, 5f
        \\    adrp x0, zdos_arm64_at_el2
        \\    ldr x0, [x0, :lo12:zdos_arm64_at_el2]
        \\    cbnz x0, 2f
        \\    sub x0, sp, #1
        \\    at s1e1w, x0
        \\    isb
        \\    mrs x0, par_el1
        \\    tbnz x0, #0, 6f
        \\    sub x0, sp, #800
        \\    at s1e1w, x0
        \\    b 3f
        \\2:
        \\    sub x0, sp, #1
        \\    at s1e2w, x0
        \\    isb
        \\    mrs x0, par_el1
        \\    tbnz x0, #0, 6f
        \\    sub x0, sp, #800
        \\    at s1e2w, x0
        \\3:
        \\    isb
        \\    mrs x0, par_el1
        \\    tbnz x0, #0, 6f
        \\5:
        \\    sub sp, sp, #800
        \\    b 7f
        \\6:
        \\    // Ran into its guard: the core's overflow stack (index from
        \\    // TPIDR_EL1, EL2's without VHE); the kind waits in PAR_EL1
        \\    msr par_el1, x1
        \\    adrp x0, zdos_arm64_el2_registers
        \\    ldr x0, [x0, :lo12:zdos_arm64_el2_registers]
        \\    cbnz x0, 8f
        \\    mrs x0, tpidr_el1
        \\    b 9f
        \\8:
        \\    mrs x0, S3_4_C13_C0_2
        \\9:
        \\    cmp x0, #63
        \\    b.hi 4f
        \\    add x0, x0, #1
        \\    lsl x0, x0, #14
        \\    adrp x1, zdos_arm64_overflow_stacks
        \\    add x1, x1, :lo12:zdos_arm64_overflow_stacks
        \\    add x0, x1, x0
        \\    sub x0, x0, #816
        \\    mov x1, sp
        \\    str x1, [x0, #800]
        \\    mov sp, x0
        \\    mrs x1, par_el1
        \\7:
        \\    // x1: the kind; the state's x0 and x1 from where they waited
        \\    mrs x0, tpidrro_el0
        \\    str x0, [sp, #0]
        \\    mov x0, x1
        \\    mrs x1, sp_el0
        \\    str x1, [sp, #8]
        \\    b zdos_arm64_switch_save
        \\4:
        \\    // No core index: the crash screen on its own stack
        \\    adrp x0, zdos_arm64_crash_stack
        \\    add x0, x0, :lo12:zdos_arm64_crash_stack
        \\    add x0, x0, #4, lsl #12
        \\    mov sp, x0
        \\    mov x0, #4
        \\    b zdos_arm64_crash
        \\zdos_arm64_switch_save:
        \\    stp x2, x3, [sp, #16]
        \\    stp x4, x5, [sp, #32]
        \\    stp x6, x7, [sp, #48]
        \\    stp x8, x9, [sp, #64]
        \\    stp x10, x11, [sp, #80]
        \\    stp x12, x13, [sp, #96]
        \\    stp x14, x15, [sp, #112]
        \\    stp x16, x17, [sp, #128]
        \\    stp x18, x19, [sp, #144]
        \\    stp x20, x21, [sp, #160]
        \\    stp x22, x23, [sp, #176]
        \\    stp x24, x25, [sp, #192]
        \\    stp x26, x27, [sp, #208]
        \\    stp x28, x29, [sp, #224]
        \\    str x30, [sp, #240]
        \\    adrp x9, zdos_arm64_el2_registers
        \\    ldr x9, [x9, :lo12:zdos_arm64_el2_registers]
        \\    cbnz x9, 1f
        \\    mrs x10, elr_el1
        \\    mrs x11, spsr_el1
        \\    b 2f
        \\1:
        \\    mrs x10, S3_4_C4_C0_1
        \\    mrs x11, S3_4_C4_C0_0
        \\2:
        \\    stp x10, x11, [sp, #248]
        \\    mrs x10, fpsr
        \\    mrs x11, fpcr
        \\    stp x10, x11, [sp, #264]
        \\    add x12, sp, #288
        \\    stp q0, q1, [x12, #0]
        \\    stp q2, q3, [x12, #32]
        \\    stp q4, q5, [x12, #64]
        \\    stp q6, q7, [x12, #96]
        \\    stp q8, q9, [x12, #128]
        \\    stp q10, q11, [x12, #160]
        \\    stp q12, q13, [x12, #192]
        \\    stp q14, q15, [x12, #224]
        \\    stp q16, q17, [x12, #256]
        \\    stp q18, q19, [x12, #288]
        \\    stp q20, q21, [x12, #320]
        \\    stp q22, q23, [x12, #352]
        \\    stp q24, q25, [x12, #384]
        \\    stp q26, q27, [x12, #416]
        \\    stp q28, q29, [x12, #448]
        \\    stp q30, q31, [x12, #480]
        \\    mov x1, x0
        \\    mov x0, sp
        \\    bl zdos_arm64_task_switch
        \\    mov sp, x0
        \\    bl zdos_arm64_switch_finish
        \\    add x12, sp, #288
        \\    ldp q0, q1, [x12, #0]
        \\    ldp q2, q3, [x12, #32]
        \\    ldp q4, q5, [x12, #64]
        \\    ldp q6, q7, [x12, #96]
        \\    ldp q8, q9, [x12, #128]
        \\    ldp q10, q11, [x12, #160]
        \\    ldp q12, q13, [x12, #192]
        \\    ldp q14, q15, [x12, #224]
        \\    ldp q16, q17, [x12, #256]
        \\    ldp q18, q19, [x12, #288]
        \\    ldp q20, q21, [x12, #320]
        \\    ldp q22, q23, [x12, #352]
        \\    ldp q24, q25, [x12, #384]
        \\    ldp q26, q27, [x12, #416]
        \\    ldp q28, q29, [x12, #448]
        \\    ldp q30, q31, [x12, #480]
        \\    ldp x10, x11, [sp, #264]
        \\    msr fpsr, x10
        \\    msr fpcr, x11
        \\    ldp x10, x11, [sp, #248]
        \\    adrp x9, zdos_arm64_el2_registers
        \\    ldr x9, [x9, :lo12:zdos_arm64_el2_registers]
        \\    cbnz x9, 3f
        \\    msr elr_el1, x10
        \\    msr spsr_el1, x11
        \\    b 4f
        \\3:
        \\    msr S3_4_C4_C0_1, x10
        \\    msr S3_4_C4_C0_0, x11
        \\4:
        \\    ldp x2, x3, [sp, #16]
        \\    ldp x4, x5, [sp, #32]
        \\    ldp x6, x7, [sp, #48]
        \\    ldp x8, x9, [sp, #64]
        \\    ldp x10, x11, [sp, #80]
        \\    ldp x12, x13, [sp, #96]
        \\    ldp x14, x15, [sp, #112]
        \\    ldp x16, x17, [sp, #128]
        \\    ldp x18, x19, [sp, #144]
        \\    ldp x20, x21, [sp, #160]
        \\    ldp x22, x23, [sp, #176]
        \\    ldp x24, x25, [sp, #192]
        \\    ldp x26, x27, [sp, #208]
        \\    ldp x28, x29, [sp, #224]
        \\    ldr x30, [sp, #240]
        \\    ldp x0, x1, [sp, #0]
        \\    add sp, sp, #800
        \\    eret
    );
}

const Callback = @import("switching.zig").Callback;

var callback: ?Callback = null;
var timer_id: u32 = 0;
var image_start: usize = 0;
var image_end: usize = 0;

pub fn setImage(start_addr: usize, size: usize) void {
    image_start = start_addr;
    image_end = start_addr + size;
}

// Code outside ZDOS's image is a program's (once the image is known)
pub fn inProgram(pc: usize) bool {
    return image_end != 0 and (pc < image_start or pc >= image_end);
}

extern fn zdos_arm64_crash(vector: u64) callconv(.c) noreturn;

// kind 1: an IRQ; 0: a synchronous exception, of which SVC
// (exception class 0x15) is a switch; a fault in a program's
// code goes to the kernel as a signal (fault.zig); the rest
// is a crash (vector 4)
export fn zdos_arm64_task_switch(frame: u64, kind: u64) callconv(.c) u64 {
    const over = onOverflowStack(frame);
    if (kind == 0) {
        const el2 = zdos_arm64_el2_registers != 0 or currentEl() == 2;
        const esr = if (el2) asm volatile ("mrs %[r], S3_4_C5_C2_0"
            : [r] "=r" (-> u64),
        ) else asm volatile ("mrs %[r], esr_el1"
            : [r] "=r" (-> u64),
        );
        if ((esr >> 26) & 0x3F != 0x15) return programFault(frame, esr, el2);
        if (over) return overflowed(frame);
        const f = callback orelse return frame;
        return f(frame, .yield, false);
    }
    const taken = gic.acknowledge();
    const id = gic.idOf(taken);
    if (id == gic.spurious) return frame;
    var why: Why = .tick;
    if (id == timer_id) {
        cpu.nextTick();
    } else {
        irq.dispatch(id); // a kick (gic.kick_sgi) has nothing to do: the switch below looks
        why = .irq;
    }
    gic.endOfInterrupt(taken);
    if (over) return overflowed(frame);
    const f = callback orelse return frame;
    const elr = @as(*const u64, @ptrFromInt(frame + elr_offset)).*;
    return f(frame, why, elr < image_start or elr >= image_end);
}

fn currentEl() u64 {
    return (asm volatile ("mrs %[r], CurrentEL"
        : [r] "=r" (-> u64),
    ) >> 2) & 3;
}

// A synchronous exception other than SVC: in a program's code
// it resumes in fault.entry, on the program's stack below the
// saved state and a gap; anywhere else (ZDOS's code), or
// without a signal for it, the crash screen
fn programFault(frame: u64, esr: u64, el2: bool) u64 {
    if (onOverflowStack(frame)) return overflowed(frame);
    const elr = @as(*const u64, @ptrFromInt(frame + elr_offset)).*;
    const ec = (esr >> 26) & 0x3F;
    const sig: u8 = switch (ec) {
        0x00, 0x0E, 0x18 => 4, // unknown (undefined instruction), illegal state, system register: SIGILL
        0x20, 0x21, 0x24, 0x25 => if (esr & 0x3F == 0x21) 7 else 11, // aborts: SIGSEGV, alignment: SIGBUS
        0x22, 0x26 => 7, // PC, SP misaligned: SIGBUS
        0x28, 0x2C => 8, // floating point: SIGFPE
        0x3C => 5, // brk (Zig's @trap): SIGTRAP
        else => zdos_arm64_crash(4),
    };
    if (!fault.wanted(elr, &inProgram)) zdos_arm64_crash(4);
    const far = if (el2) asm volatile ("mrs %[r], S3_4_C6_C0_0"
        : [r] "=r" (-> u64),
    ) else asm volatile ("mrs %[r], far_el1"
        : [r] "=r" (-> u64),
    );
    const what: []const u8 = switch (sig) {
        4 => "Undefined instruction",
        5 => "Breakpoint",
        7 => "Alignment fault",
        8 => "Floating point exception",
        else => if (ec == 0x20 or ec == 0x21) "Instruction abort" else "Data abort",
    };
    const has_far = ec == 0x20 or ec == 0x21 or ec == 0x24 or ec == 0x25 or ec == 0x22;
    // Far below the stack pointer into the
    // guard (a big frame): on the spare
    const spare = if (has_far) memory.guardAt(far) else null;
    fault.last = .{ .signal = sig, .what = if (spare != null) "Stack overflow" else what, .pc = elr, .addr = if (has_far) far else 0 };
    const below = frame - fault.gap;
    return newContext(spare orelse memory.guardAt(below) orelse below, &fault.entry, 0);
}

fn onOverflowStack(frame: u64) bool {
    const base = @intFromPtr(&zdos_arm64_overflow_stacks);
    return frame >= base and frame < base + @sizeOf(@TypeOf(zdos_arm64_overflow_stacks));
}

// A state the stub put on the overflow stack: its own stack ran
// into the guard. A program's code goes on in fault.entry on
// the stack's spare (SIGSEGV);
// ZDOS's own can't: the crash screen.
fn overflowed(frame: u64) u64 {
    const elr = @as(*const u64, @ptrFromInt(frame + elr_offset)).*;
    const sp = @as(*const u64, @ptrFromInt(frame + frame_size)).*;
    const spare = memory.guardAt(sp -% 1) orelse memory.guardAt(sp -% frame_size);
    if (spare == null or !fault.wanted(elr, &inProgram)) {
        @import("console.zig").write("\n*** Stack overflow (ZDOS's code)");
        zdos_arm64_crash(4);
    }
    fault.last = .{ .signal = 11, .what = "Stack overflow", .pc = elr, .addr = sp };
    return newContext(spare.?, &fault.entry, 0);
}

var finish: ?*const fn () void = null;

export fn zdos_arm64_switch_finish() callconv(.c) void {
    if (finish) |f| f();
}

// SEVERAL CORES (tasks.zig)

pub fn setCoreIndex(i: usize) void {
    if (zdos_arm64_el2_registers != 0) {
        asm volatile ("msr S3_4_C13_C0_2, %[v]" // TPIDR_EL2
            :
            : [v] "r" (i),
        );
    } else asm volatile ("msr tpidr_el1, %[v]"
        :
        : [v] "r" (i),
    );
}

pub fn coreIndex() usize {
    if (zdos_arm64_el2_registers != 0) return asm volatile ("mrs %[r], S3_4_C13_C0_2"
        : [r] "=r" (-> usize),
    );
    return asm volatile ("mrs %[r], tpidr_el1"
        : [r] "=r" (-> usize),
    );
}

// Another core joins: on SP_ELx, its own timer ticking (only if
// its interrupt reaches the core:
// smp_arm64.zig tested it), IRQs on
pub fn startCore() bool {
    if (!smp.cores[coreIndex()].sleeps_on_timer) return false;
    gic.enableKick(coreIndex());
    asm volatile (
        \\mov x9, sp
        \\msr spsel, #1
        \\mov sp, x9
        ::: "x9", "memory");
    cpu.nextTick();
    asm volatile ("msr daifclr, #2" ::: "memory");
    return true;
}

// An idle core with work: an SGI (else it finds it at its next tick)
pub fn kick(i: usize) void {
    gic.sendKick(i);
}

// Switching on: on SP_ELx, the timer ticking, IRQs
// unmasked for good. False if the timer's
// interrupt doesn't reach this core
// (cpu_arm64.zig's test) or the image is unknown.
// done: after each switch, on the new stack.
pub fn start(f: Callback, done: *const fn () void) bool {
    timer_id = cpu.timerInterrupt() orelse return false;
    if (image_end == 0) return false;
    const el = (asm volatile ("mrs %[r], CurrentEL"
        : [r] "=r" (-> u64),
    ) >> 2) & 3;
    const vhe = el == 2 and asm volatile ("mrs %[r], S3_4_C1_C1_0"
        : [r] "=r" (-> u64),
    ) & (1 << 34) != 0;
    zdos_arm64_el2_registers = @intFromBool(el == 2 and !vhe);
    zdos_arm64_at_el2 = @intFromBool(el == 2);
    setCoreIndex(0); // the overflow stack's index, before other cores join
    gic.enableKick(0);
    zdos_arm64_check_stack = 1;
    paging.setFaultStacks(true);
    asm volatile (
        \\mov x9, sp
        \\msr spsel, #1
        \\mov sp, x9
        ::: "x9", "memory");
    callback = f;
    finish = done;
    cpu.ticking = true;
    cpu.nextTick();
    asm volatile ("msr daifclr, #2" ::: "memory");
    return true;
}

// A new task's first state: as if interrupted just before
// entry(arg), on its stack, at ZDOS's level with IRQs unmasked
pub fn newContext(top: usize, entry: *const fn (arg: usize) callconv(.c) noreturn, arg: usize) usize {
    const frame = (top & ~@as(usize, 15)) - frame_size;
    const words: [*]u64 = @ptrFromInt(frame);
    @memset(words[0 .. frame_size / 8], 0);
    words[0] = arg; // x0
    words[elr_offset / 8] = @intFromPtr(entry);
    const el = (asm volatile ("mrs %[r], CurrentEL"
        : [r] "=r" (-> u64),
    ) >> 2) & 3;
    // EL1h or EL2h, D, A and F masked, IRQs not
    words[elr_offset / 8 + 1] = @as(u64, if (el == 2) 0x9 else 0x5) | 0x340;
    return frame;
}

// A call of f(arg) as the state to resume, below the saved
// state at sp; f must not return:
// it resumes sp itself (tasks.zig)
pub fn pushCall(sp: usize, f: *const fn (arg: usize) callconv(.c) noreturn, arg: usize) usize {
    return newContext(sp, f, arg);
}

pub fn yield() void {
    asm volatile ("svc #0" ::: "memory");
}

// This core's timer interrupt at nanos()
// == at (null: none; past: at once)
pub fn armTimer(at: ?u64) void {
    cpu.armDeadline(at);
}

pub fn disable() usize {
    return asm volatile (
        \\mrs %[r], daif
        \\msr daifset, #2
        : [r] "=r" (-> usize),
        :
        : "memory"
    );
}

pub fn restore(state: usize) void {
    asm volatile ("msr daif, %[s]"
        :
        : [s] "r" (state),
        : "memory"
    );
}

pub fn idle() void {
    asm volatile ("wfi" ::: "memory");
}
