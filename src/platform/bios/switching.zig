// Preemptive task switching for tasks.zig (platform.switching),
// as on metal: the PIT's IRQ0 (one-shot deadlines, pic.zig),
// `int $0x31` (yield) and devices' IRQs (setIrqHandler:
// the IDE channels'; addIrqHandler: PCI cards' shared lines)
// enter one stub, which saves the whole state on
// the task's stack and resumes the one the scheduler returns.
//
// A saved state, from the stack pointer up: the address of the
// registers, the FPU state (fxsave with SSE, else fnsave;
// 16-aligned), the registers (pushal), the entry kind (1 tick,
// 0 yield, else an IRQ's vector),
// then the CPU's eip, cs, eflags.
const std = @import("std");
const arch = @import("../../arch/x86.zig");
const port = @import("../../arch/x86_port.zig");
const pic = @import("pic.zig");
const lapic = @import("lapic.zig");
const realmode = @import("realmode.zig");

pub const Why = enum(u8) { yield, tick, irq };
pub const Callback = *const fn (sp: usize, why: Why, in_program: bool) usize;

const timer_vector = arch.irq_base; // IRQ0
const yield_vector = 0x31;
const lapic_vector = 0x32; // each core's local APIC timer (B3)
const kick_vector = 0x33; // an idle core has work (B4)

comptime {
    asm (
        \\.text
        \\.global zdos_bios_switch_timer
        \\zdos_bios_switch_timer:
        \\    pushl $1
        \\    jmp zdos_bios_switch_common
        \\.global zdos_bios_switch_yield
        \\zdos_bios_switch_yield:
        \\    pushl $0
        \\    jmp zdos_bios_switch_common
        \\.global zdos_bios_switch_lapic
        \\zdos_bios_switch_lapic:
        \\    pushl $2
        \\    jmp zdos_bios_switch_common
        \\.global zdos_bios_switch_kick
        \\zdos_bios_switch_kick:
        \\    pushl $3
        \\    jmp zdos_bios_switch_common
        \\.global zdos_bios_switch_irq3
        \\zdos_bios_switch_irq3:
        \\    pushl $0x23
        \\    jmp zdos_bios_switch_common
        \\.global zdos_bios_switch_irq4
        \\zdos_bios_switch_irq4:
        \\    pushl $0x24
        \\    jmp zdos_bios_switch_common
        \\.global zdos_bios_switch_irq5
        \\zdos_bios_switch_irq5:
        \\    pushl $0x25
        \\    jmp zdos_bios_switch_common
        \\.global zdos_bios_switch_irq7
        \\zdos_bios_switch_irq7:
        \\    pushl $0x27
        \\    jmp zdos_bios_switch_common
        \\.global zdos_bios_switch_irq9
        \\zdos_bios_switch_irq9:
        \\    pushl $0x29
        \\    jmp zdos_bios_switch_common
        \\.global zdos_bios_switch_irq10
        \\zdos_bios_switch_irq10:
        \\    pushl $0x2A
        \\    jmp zdos_bios_switch_common
        \\.global zdos_bios_switch_irq11
        \\zdos_bios_switch_irq11:
        \\    pushl $0x2B
        \\    jmp zdos_bios_switch_common
        \\.global zdos_bios_switch_irq14
        \\zdos_bios_switch_irq14:
        \\    pushl $0x2E
        \\    jmp zdos_bios_switch_common
        \\.global zdos_bios_switch_irq15
        \\zdos_bios_switch_irq15:
        \\    pushl $0x2F
        \\    jmp zdos_bios_switch_common
        \\zdos_bios_switch_common:
        \\    pushal
        \\    cld
        \\    mov %esp, %ebx
        \\    sub $512, %esp
        \\    and $-16, %esp
        \\    mov %cr4, %eax
        \\    test $0x200, %eax
        \\    jz 1f
        \\    fxsave (%esp)
        \\    jmp 2f
        \\1:  fnsave (%esp)
        \\2:  push %ebx
        \\    mov %esp, %ecx
        \\    mov 32(%ebx), %eax
        \\    mov 36(%ebx), %edx
        \\    and $-16, %esp
        \\    sub $4, %esp
        \\    push %edx
        \\    push %eax
        \\    push %ecx
        \\    call zdos_bios_task_switch
        \\    mov %eax, %esp
        \\    mov %esp, %ebx
        \\    and $-16, %esp
        \\    call zdos_bios_switch_finish
        \\    mov %ebx, %esp
        \\    pop %ebx
        \\    mov %cr4, %eax
        \\    test $0x200, %eax
        \\    jz 3f
        \\    fxrstor (%esp)
        \\    jmp 4f
        \\3:  frstor (%esp)
        \\4:  mov %ebx, %esp
        \\    popal
        \\    add $4, %esp
        \\    iret
    );
}

extern fn zdos_bios_switch_timer() callconv(.naked) void;
extern fn zdos_bios_switch_yield() callconv(.naked) void;
extern fn zdos_bios_switch_lapic() callconv(.naked) void;
extern fn zdos_bios_switch_kick() callconv(.naked) void;
extern fn zdos_bios_switch_irq3() callconv(.naked) void;
extern fn zdos_bios_switch_irq4() callconv(.naked) void;
extern fn zdos_bios_switch_irq5() callconv(.naked) void;
extern fn zdos_bios_switch_irq7() callconv(.naked) void;
extern fn zdos_bios_switch_irq9() callconv(.naked) void;
extern fn zdos_bios_switch_irq10() callconv(.naked) void;
extern fn zdos_bios_switch_irq11() callconv(.naked) void;
extern fn zdos_bios_switch_irq14() callconv(.naked) void;
extern fn zdos_bios_switch_irq15() callconv(.naked) void;

extern const __kernel_start: u8;
extern const __kernel_end: u8;

var callback: ?Callback = null;
var image_start: usize = 0;
var image_end: usize = 0;

export fn zdos_bios_task_switch(sp: u32, kind: u32, eip: u32) callconv(.c) u32 {
    var why: Why = if (kind == 0) .yield else if (kind == 3) .irq else .tick;
    if (kind >= arch.irq_base) {
        const irq = kind - arch.irq_base;
        if (irq_handlers[irq & 15]) |h| h();
        for (shared[irq & 15][0..shared_count[irq & 15]]) |e| _ = e.handler(e.ctx);
        if (irq >= 8) port.outb(0xA0, 0x20); // the slave PIC's EOI, then the master's
        why = .irq;
    }
    if (kind == 2 or kind == 3) {
        lapic.endOfInterrupt();
    } else if (kind != 0) port.outb(0x20, 0x20);
    const f = callback orelse return sp;
    const in_program = eip < image_start or eip >= image_end;
    return f(sp, why, in_program);
}

// Devices' IRQs through the stub: their handlers (interrupts
// off), which may wake tasks; the
// switch to a woken one follows at once
var irq_handlers: [16]?*const fn () void = @splat(null);

// IRQ 14 and 15 (the IDE channels) only; false for another
pub fn setIrqHandler(irq: u4, h: *const fn () void) bool {
    const entry: usize = switch (irq) {
        14 => @intFromPtr(&zdos_bios_switch_irq14),
        15 => @intFromPtr(&zdos_bios_switch_irq15),
        else => return false,
    };
    const was = disable();
    defer restore(was);
    irq_handlers[irq] = h;
    arch.setGate(arch.irq_base + @as(u8, irq), entry);
    pic.unmask(irq);
    return true;
}

// PCI cards' wired lines (level-triggered, shared): each
// handler quiets its device; masked during BIOS calls (pic.zig)
pub const SharedHandler = *const fn (ctx: ?*anyopaque) bool;
const Shared = struct { handler: SharedHandler, ctx: ?*anyopaque };
var shared: [16][4]Shared = undefined;
var shared_count: [16]u8 = @splat(0);

// IRQ 3, 4, 5, 7, 9, 10 or 11; false for another or a full line
pub fn addIrqHandler(irq: u4, h: SharedHandler, ctx: ?*anyopaque) bool {
    const entry: usize = switch (irq) {
        3 => @intFromPtr(&zdos_bios_switch_irq3),
        4 => @intFromPtr(&zdos_bios_switch_irq4),
        5 => @intFromPtr(&zdos_bios_switch_irq5),
        7 => @intFromPtr(&zdos_bios_switch_irq7),
        9 => @intFromPtr(&zdos_bios_switch_irq9),
        10 => @intFromPtr(&zdos_bios_switch_irq10),
        11 => @intFromPtr(&zdos_bios_switch_irq11),
        else => return false,
    };
    if (shared_count[irq] == shared[irq].len) return false;
    const was = disable();
    defer restore(was);
    shared[irq][shared_count[irq]] = .{ .handler = h, .ctx = ctx };
    shared_count[irq] += 1;
    arch.setGate(arch.irq_base + @as(u8, irq), entry);
    pic.unmaskDevice(irq);
    return true;
}

var finish: ?*const fn () void = null;

export fn zdos_bios_switch_finish() callconv(.c) void {
    if (finish) |f| f();
}

// Switching on: the gates, one-shot deadlines (the local APIC's
// timer or the PIT), then interrupts on for good. done: after
// each switch, on the new task's stack (several cores).
pub fn start(f: Callback, done: *const fn () void) bool {
    image_start = @intFromPtr(&__kernel_start);
    image_end = @intFromPtr(&__kernel_end);
    callback = f;
    finish = done;
    arch.setGate(kick_vector, @intFromPtr(&zdos_bios_switch_kick));
    arch.setGate(timer_vector, @intFromPtr(&zdos_bios_switch_timer));
    arch.setGate(yield_vector, @intFromPtr(&zdos_bios_switch_yield));
    // The local APIC's timer where the BIOS
    // left the APIC on (B3), else the PIT
    if (@import("config.zig").lapic_timer and lapic.init() and lapic.timerWorks()) {
        arch.setGate(lapic_vector, @intFromPtr(&zdos_bios_switch_lapic));
        pic.useLapicTimer();
        use_lapic = true;
        realmode.before_call = &beforeBiosCall;
        realmode.seal_call = &sealBiosCall;
        realmode.after_call = &afterBiosCall;
        lapic.armAt(lapic_vector, 0);
    } else {
        pic.startOneShot();
        pic.armOneShot(null);
    }
    asm volatile ("sti" ::: "memory");
    return true;
}

var use_lapic = false;
var in_bios_call = false;

// SEVERAL CORES (B4): TASKS ON THE OTHER CORES TOO, AS ON METAL
// A core's index from its task register: each core loads
// its own selector once, and STR reads it without an exit to
// a hypervisor (the APIC ID's MMIO read was one, and the
// kernel asks constantly). GS holds the thread pointer and
// BIOS calls reload the data segments; nothing loads TR.
// The task state segment is never used (all in ring 0).
// Without the GDT room: the APIC ID.

const max_cores = 64;
var index_of = [_]u8{0xFF} ** 256;
var apic_of = [_]u32{0} ** max_cores;
var scheduling = [_]bool{false} ** max_cores;
var registered = [_]bool{false} ** max_cores;

pub fn setCoreIndex(i: usize) void {
    const id = lapic.id();
    index_of[id & 0xFF] = @intCast(i);
    apic_of[i] = id;
    loadTaskRegister(i);
    registered[i] = true;
    arch.coreIndex = &coreIndex;
}

pub fn coreIndex() usize {
    return ownIndex() orelse 0;
}

// Null: a core not registered
fn ownIndex() ?usize {
    if (tr_cores) {
        const sel = asm volatile ("str %[r]"
            : [r] "=r" (-> u16),
        );
        return if (sel >= tss_first) (sel - tss_first) / 8 else null;
    }
    const id = lapic.id() & 0xFF;
    const i = index_of[id];
    return if (i == 0xFF) null else i;
}

// A GDT with stage 2's entries and one TSS descriptor a core
// after them, loaded only for LTR (stage 2's again after it:
// BIOS calls load that one anyway; TR keeps its selector)
const tss_first = 0x30;
var gdt: [tss_first / 8 + max_cores]u64 align(8) = @splat(0);
var tss: [104]u8 align(16) = @splat(0);
var tr_cores = false;
var tr_failed = false;
var gdt_lock = std.atomic.Value(bool).init(false);

fn loadTaskRegister(i: usize) void {
    if (tr_failed) return;
    const flags = asm volatile ("pushfl; cli; popl %[f]"
        : [f] "=r" (-> u32),
        :
        : "memory"
    );
    defer if (flags & 0x200 != 0) asm volatile ("sti" ::: "memory");
    while (gdt_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer gdt_lock.store(false, .release);
    var old: [6]u8 align(4) = undefined;
    asm volatile ("sgdt (%[p])"
        :
        : [p] "r" (&old),
        : "memory"
    );
    const old_limit = std.mem.readInt(u16, old[0..2], .little);
    const old_base = std.mem.readInt(u32, old[2..6], .little);
    // Stage 2's entries reaching tss_first: the APIC ID
    if (old_limit + 1 > tss_first or i >= max_cores) {
        tr_failed = true;
        tr_cores = false;
        return;
    }
    const from: [*]const u64 = @ptrFromInt(old_base);
    @memcpy(gdt[0 .. (old_limit + 1) / 8], from[0 .. (old_limit + 1) / 8]);
    // 32-bit TSS, available, present, ring 0; limit 103:
    const b: u64 = @intFromPtr(&tss);
    gdt[tss_first / 8 + i] = 103 | ((b & 0xFF_FFFF) << 16) | (@as(u64, 0x89) << 40) | ((b >> 24) << 56);
    var new: [6]u8 align(4) = undefined;
    std.mem.writeInt(u16, new[0..2], @sizeOf(@TypeOf(gdt)) - 1, .little);
    std.mem.writeInt(u32, new[2..6], @intCast(@intFromPtr(&gdt)), .little);
    asm volatile (
        \\lgdt (%[n])
        \\ltr %[s]
        \\lgdt (%[o])
        :
        : [n] "r" (&new),
          [o] "r" (&old),
          [s] "r" (@as(u16, @intCast(tss_first + 8 * i))),
        : "memory"
    );
    tr_cores = true;
}

// Another core joins: its own APIC timer for deadlines
// (none without B3: it stays a worker for programs'
// jobs), interrupts on
pub fn startCore() bool {
    if (!use_lapic or !@import("config.zig").tasks_on_all_cores) return false;
    scheduling[coreIndex()] = true;
    lapic.armAt(lapic_vector, 0);
    asm volatile ("sti" ::: "memory");
    return true;
}

// Whether this core runs tasks (a fault in a program's code
// there is a signal, as on core 0)
pub fn onTaskCore() bool {
    const i = ownIndex() orelse return false;
    return scheduling[i];
}

// Core i, idle, looks for a ready task now
pub fn kick(i: usize) void {
    if (i < max_cores and registered[i]) lapic.sendIpi(apic_of[i], kick_vector);
}

// The next timer interrupt at nanos() == at (null: the PIT's in
// 55 ms at the latest, the APIC's none)
pub fn armTimer(at: ?u64) void {
    if (!use_lapic) return pic.armOneShot(at);
    // Core 0's call only: set again after it:
    if (in_bios_call and coreIndex() == 0) return;
    lapic.armAt(lapic_vector, at);
}

// The APIC timer's interrupt must not come in real mode:
// what is pending taken first (interrupts on: a task's
// call, which may switch tasks with the timer still on),
// then the timer off
fn beforeBiosCall() void {
    if (asm volatile ("pushfl; popl %[f]"
        : [f] "=r" (-> u32),
    ) & 0x200 != 0) {
        var spins: u32 = 0;
        while (anyPending() and spins < 100_000) : (spins += 1) std.atomic.spinLoopHint();
    }
    in_bios_call = true;
    lapic.maskTimer();
}

const sealed_vectors = [_]u8{ lapic_vector, kick_vector, arch.wake_vector };

fn anyPending() bool {
    for (sealed_vectors) |v| if (lapic.pending(v)) return true;
    return false;
}

// Interrupts off: no IPI reaches core 0 until afterBiosCall.
// Not sealed (one came meanwhile): the timer back on before
// realmode.call takes it, as a switch may follow:
fn sealBiosCall(if_on: bool) bool {
    if (lapic.sealCore0(if_on, &sealed_vectors)) return true;
    in_bios_call = false;
    lapic.armAt(lapic_vector, 0);
    return false;
}

fn afterBiosCall() void {
    lapic.unsealCore0(); // what was held back: the timer below
    in_bios_call = false;
    lapic.armAt(lapic_vector, 0); // at once: the scheduler sets the next
}

pub fn yield() void {
    asm volatile ("int $0x31" ::: "memory");
}

// Interrupts off; the earlier EFLAGS for restore
pub fn disable() usize {
    return asm volatile ("pushfl; cli; popl %[f]"
        : [f] "=r" (-> usize),
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

pub fn pushCall(sp: usize, f: *const fn (arg: usize) callconv(.c) noreturn, arg: usize) usize {
    return newContext(sp - 128, f, arg);
}

// A new task's first state: as if interrupted just before
// startAsm, which calls entry(arg) (ebx, esi), with interrupts
// on and the FPU as after reset
pub fn newContext(top: usize, entry: *const fn (arg: usize) callconv(.c) noreturn, arg: usize) usize {
    const frame = (top & ~@as(usize, 15)) - 64; // eip, cs, eflags here; room above
    const w: [*]u32 = @ptrFromInt(frame);
    w[0] = @intFromPtr(&startAsm);
    w[1] = asm volatile ("mov %%cs, %[r]"
        : [r] "=r" (-> u32),
    );
    w[2] = 0x202; // IF
    const regs = frame - 36; // pushal's 8 registers, then the kind
    const r: [*]u32 = @ptrFromInt(regs);
    @memset(r[0..9], 0);
    r[1] = arg; // esi
    r[4] = @intFromPtr(entry); // ebx
    const fx = (regs - 512) & ~@as(usize, 15);
    const area: [*]u8 = @ptrFromInt(fx);
    @memset(area[0..512], 0);
    std.mem.writeInt(u16, area[0..2], 0x037F, .little); // FCW (both layouts)
    if (sse()) {
        std.mem.writeInt(u32, area[24..28], 0x1F80, .little); // MXCSR
    } else {
        std.mem.writeInt(u16, area[8..10], 0xFFFF, .little); // fnsave: every register empty
    }
    const slot: *u32 = @ptrFromInt(fx - 4);
    slot.* = regs;
    return fx - 4;
}

// CR4.OSFXSR: fxsave's layout (arch.enableFpu sets it with SSE)
fn sse() bool {
    const cr4 = asm volatile ("mov %%cr4, %[r]"
        : [r] "=r" (-> u32),
    );
    return cr4 & 0x200 != 0;
}

// A new task's first return lands here: entry (ebx) gets arg (esi)
fn startAsm() callconv(.naked) void {
    asm volatile (
        \\and $-16, %%esp
        \\sub $12, %%esp
        \\push %%esi
        \\call *%%ebx
        \\ud2
    );
}
