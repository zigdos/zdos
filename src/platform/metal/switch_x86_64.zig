// Task switching on x86_64 for tasks.zig. The APIC timer
// (vector 0x30), `int $0x31` (yield) and device vectors
// (irq.zig, 0x50+) enter one stub: it saves the state on the
// task's stack (with fxsave), calls the scheduler with sp,
// and resumes the state it returns.
//
// A saved state, from the stack pointer up: padding, the
// registers' address, 512 bytes for fxsave (16-aligned), r15 ...
// rax, the entry kind (1 timer, 0 yield, 2 another core's kick,
// else a device's vector), the CPU's rip, cs, rflags, rsp, ss.
//
// Several cores run tasks: GS's base points to a core's
// slot holding its index, and once on the new task's stack
// the stub calls finish (tasks.zig lets the old task run
// elsewhere from then on).
const std = @import("std");
const cpu = @import("cpu_x86_64.zig");
const irq = @import("irq.zig");
const Why = @import("switching.zig").Why;

pub const timer_vector = 0x30;
pub const yield_vector = 0x31;
pub const kick_vector = 0x32;

comptime {
    asm (
        \\.text
        \\.global zdos_switch_timer
        \\zdos_switch_timer:
        \\    pushq $1
        \\    jmp zdos_switch_common
        \\.global zdos_switch_yield
        \\zdos_switch_yield:
        \\    pushq $0
        \\    jmp zdos_switch_common
        \\.global zdos_switch_kick
        \\zdos_switch_kick:
        \\    pushq $2
        \\    jmp zdos_switch_common
    ++ deviceStubs() ++
        \\zdos_switch_common:
        \\    push %rax
        \\    push %rbx
        \\    push %rcx
        \\    push %rdx
        \\    push %rsi
        \\    push %rdi
        \\    push %rbp
        \\    push %r8
        \\    push %r9
        \\    push %r10
        \\    push %r11
        \\    push %r12
        \\    push %r13
        \\    push %r14
        \\    push %r15
        \\    mov %rsp, %rbx
        \\    sub $528, %rsp
        \\    and $-16, %rsp
        \\    fxsave (%rsp)
        \\    push %rbx
        \\    sub $8, %rsp
        \\    mov %rsp, %rcx
        \\    mov 120(%rbx), %rdx
        \\    mov 128(%rbx), %r8
        \\    sub $32, %rsp
        \\    call zdos_task_switch
        \\    mov %rax, %rsp
        \\    sub $32, %rsp
        \\    call zdos_switch_finish
        \\    add $32, %rsp
        \\    add $8, %rsp
        \\    pop %rbx
        \\    fxrstor (%rsp)
        \\    mov %rbx, %rsp
        \\    pop %r15
        \\    pop %r14
        \\    pop %r13
        \\    pop %r12
        \\    pop %r11
        \\    pop %r10
        \\    pop %r9
        \\    pop %r8
        \\    pop %rbp
        \\    pop %rdi
        \\    pop %rsi
        \\    pop %rdx
        \\    pop %rcx
        \\    pop %rbx
        \\    pop %rax
        \\    add $8, %rsp
        \\    iretq
    );
}

extern fn zdos_switch_timer() callconv(.naked) void;
extern fn zdos_switch_yield() callconv(.naked) void;
extern fn zdos_switch_kick() callconv(.naked) void;
extern fn zdos_switch_devices() callconv(.naked) void;

// One stub of 16 bytes per device
// vector, from zdos_switch_devices on:
// the vector as the kind
fn deviceStubs() []const u8 {
    comptime {
        var s: []const u8 = "\n.balign 16\n.global zdos_switch_devices\nzdos_switch_devices:\n";
        for (0..irq.vectors) |i| {
            s = s ++ std.fmt.comptimePrint(".balign 16\n    pushq ${d}\n    jmp zdos_switch_common\n", .{irq.first_vector + i});
        }
        return s;
    }
}

const Callback = @import("switching.zig").Callback;

var callback: ?Callback = null;
// ZDOS's own image: code there is ZDOS's, everything else a program's
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

export fn zdos_task_switch(sp: u64, kind: u64, rip: u64) callconv(.c) u64 {
    const why: Why = switch (kind) {
        0 => .yield,
        1 => .tick,
        else => .irq,
    };
    if (kind >= irq.first_vector) irq.dispatch(@intCast(kind));
    if (why != .yield) cpu.endOfInterrupt();
    const f = callback orelse return sp;
    const in_program = rip < image_start or rip >= image_end;
    return f(sp, why, in_program);
}

// Switching on: the gates, then interrupts on for good (the
// scheduler runs from the timer). False without the APIC timer.
// done: after each switch, on the new stack.
pub fn start(f: Callback, done: *const fn () void) bool {
    if (!cpu.timerRunning() or image_end == 0) return false;
    callback = f;
    finish = done;
    cpu.setGate(timer_vector, @intFromPtr(&zdos_switch_timer));
    cpu.setGate(yield_vector, @intFromPtr(&zdos_switch_yield));
    cpu.setGate(kick_vector, @intFromPtr(&zdos_switch_kick));
    for (0..irq.vectors) |i| cpu.setGate(@intCast(irq.first_vector + i), @intFromPtr(&zdos_switch_devices) + i * 16);
    cpu.interruptsOn();
    return true;
}

var finish: ?*const fn () void = null;

export fn zdos_switch_finish() callconv(.c) void {
    if (finish) |f| f();
}

// SEVERAL CORES (tasks.zig)

const max_cores = 64;
export var zdos_core_slots: [max_cores]u64 = [_]u64{0} ** max_cores;
var apic_ids: [max_cores]u32 = [_]u32{0} ** max_cores;

// This core is number i from now on (before it runs tasks)
pub fn setCoreIndex(i: usize) void {
    zdos_core_slots[i] = i;
    cpu.setGsBase(@intFromPtr(&zdos_core_slots[i]));
    apic_ids[i] = cpu.apicId();
}

pub fn coreIndex() usize {
    return asm volatile ("mov %%gs:0, %[r]"
        : [r] "=r" (-> usize),
    );
}

// Another core joins: its own tick (the gates are core 0's: one IDT)
pub fn startCore() bool {
    return cpu.startTickHere();
}

// Core i, idle, looks for a ready task now
pub fn kick(i: usize) void {
    cpu.sendIpi(apic_ids[i], kick_vector);
}

// A new task's first state: as if interrupted just before
// entry(arg), on its stack, with interrupts
// on and the x87 / SSE state as after reset
pub fn newContext(top: usize, entry: *const fn (arg: usize) callconv(.c) noreturn, arg: usize) usize {
    const rsp = (top & ~@as(usize, 15)) - 8; // as after a call
    var frame: [*]u64 = @ptrFromInt(rsp - 21 * 8);
    // r15..rax (15), kind, rip, cs, rflags, rsp, ss
    @memset(frame[0..21], 0);
    frame[12] = arg; // rcx: the first argument
    frame[15] = 0;
    frame[16] = @intFromPtr(entry);
    frame[17] = cpu.codeSelector();
    frame[18] = 0x202; // IF
    frame[19] = rsp;
    frame[20] = cpu.dataSelector();
    const regs = @intFromPtr(frame);
    const fx = (regs - 528) & ~@as(usize, 15);
    const area: [*]u8 = @ptrFromInt(fx);
    @memset(area[0..512], 0);
    std.mem.writeInt(u16, area[0..2], 0x037F, .little); // FCW
    std.mem.writeInt(u32, area[24..28], 0x1F80, .little); // MXCSR
    const regs_slot: *u64 = @ptrFromInt(fx - 8);
    regs_slot.* = regs;
    return fx - 16;
}

// A call of f(arg) as the state to resume, below the saved
// state at sp (and the 128-byte red zone a program's code may
// use under its stack pointer); f must not return: it resumes
// sp itself (tasks.zig)
pub fn pushCall(sp: usize, f: *const fn (arg: usize) callconv(.c) noreturn, arg: usize) usize {
    return newContext(sp - 128, f, arg);
}

// This core's timer interrupt at nanos()
// == at (null: none; past: at once)
pub fn armTimer(at: ?u64) void {
    cpu.armDeadline(at);
}

// The current task gives the CPU up
pub fn yield() void {
    asm volatile ("int $0x31" ::: "memory");
}

// Interrupts off; the earlier state for restore
pub fn disable() usize {
    return asm volatile (
        \\pushfq
        \\pop %[r]
        \\cli
        : [r] "=r" (-> usize),
        :
        : "memory"
    );
}

pub fn restore(state: usize) void {
    if (state & 0x200 != 0) asm volatile ("sti" ::: "memory");
}

// The idle task's wait: until the next interrupt
pub fn idle() void {
    asm volatile ("sti; hlt" ::: "memory");
}
