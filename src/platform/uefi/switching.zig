// Cooperative task switching
// for tasks.zig (platform.switching): the firmware owns the
// timer, so a task gives the CPU up only inside ZDOS (yield).
// A saved state is the registers the calling convention
// preserves, on the task's own stack.
const std = @import("std");
const builtin = @import("builtin");
const uefi = std.os.uefi;
const arch = @import("../../arch.zig");
const console = @import("console.zig");

// Only yield happens here; tasks.zig catches up with the clock itself
pub const cooperative = true;

pub const Why = enum(u8) { yield, tick, irq };
pub const Callback = *const fn (sp: usize, why: Why, in_program: bool) usize;

var callback: ?Callback = null;

pub fn start(f: Callback) bool {
    callback = f;
    return true;
}

fn switchPoint(sp: usize) callconv(arch.cc) usize {
    return callback.?(sp, .yield, false);
}

const yieldAsm: *const fn (f: *const fn (usize) callconv(arch.cc) usize) callconv(arch.cc) void = @ptrCast(&swapAsm);

pub fn yield() void {
    yieldAsm(&switchPoint);
}

// Nothing interrupts ZDOS's own code here
pub fn disable() usize {
    return 0;
}

pub fn restore(state: usize) void {
    _ = state;
}

// The idle task: until the firmware's next timer tick, or a key
// while a task waits for one (that task
// is woken), then a turn for whoever woke
var tick: ?uefi.Event = null;

pub fn idle() void {
    const bs = uefi.system_table.boot_services.?;
    if (tick == null) {
        var e: uefi.Event = undefined;
        if (bs.createEvent(uefi.tables.BootServices.event_timer, 0, null, null, &e) == .success and
            bs.setTimer(e, .timer_periodic, 10_000) == .success) tick = e;
    }
    var events: [2]uefi.Event = undefined;
    var n: usize = 0;
    if (tick) |t| {
        events[n] = t;
        n += 1;
    }
    const key = console.inputEvent();
    if (key) |k| {
        events[n] = k;
        n += 1;
    }
    if (n == 0) {
        _ = bs.stall(1000);
    } else {
        var index: usize = undefined;
        if (bs.waitForEvent(n, &events, &index) == .success and key != null and index == n - 1) console.inputArrived();
    }
    yield();
}

pub fn pushCall(sp: usize, f: *const fn (arg: usize) callconv(.c) noreturn, arg: usize) usize {
    return newContext(sp - 128, f, arg);
}

// A new task's first state: resuming it calls entry(arg) on its stack
pub fn newContext(top: usize, entry: *const fn (arg: usize) callconv(.c) noreturn, arg: usize) usize {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            // 168 bytes of xmm6-15 / control words, r15 ... rbx,
            // then the return address
            const frame = (top & ~@as(usize, 15)) - 256;
            const b: [*]u8 = @ptrFromInt(frame);
            @memset(b[0..256], 0);
            std.mem.writeInt(u16, b[160..162], 0x037F, .little); // FCW
            std.mem.writeInt(u32, b[164..168], 0x1F80, .little); // MXCSR
            const regs: [*]usize = @ptrFromInt(frame + 168);
            regs[3] = @intFromPtr(entry); // r12
            regs[2] = arg; // r13
            regs[8] = @intFromPtr(&startAsm);
            return frame;
        },
        .aarch64 => {
            const frame = (top & ~@as(usize, 15)) - 176;
            const regs: [*]usize = @ptrFromInt(frame);
            @memset(regs[0..22], 0);
            regs[0] = @intFromPtr(entry); // x19
            regs[1] = arg; // x20
            regs[11] = @intFromPtr(&startAsm); // x30
            return frame;
        },
        else => @compileError("UEFI switching: x86_64 and aarch64 only"),
    }
}

// x86_64 (Microsoft x64): f in rcx; the saved state's address
// is f's argument and f returns the state to resume. aarch64:
// f in x0, the same.
fn swapAsm() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\push %%rbx
            \\push %%rbp
            \\push %%rdi
            \\push %%rsi
            \\push %%r12
            \\push %%r13
            \\push %%r14
            \\push %%r15
            \\sub $168, %%rsp
            \\movdqa %%xmm6, 0(%%rsp)
            \\movdqa %%xmm7, 16(%%rsp)
            \\movdqa %%xmm8, 32(%%rsp)
            \\movdqa %%xmm9, 48(%%rsp)
            \\movdqa %%xmm10, 64(%%rsp)
            \\movdqa %%xmm11, 80(%%rsp)
            \\movdqa %%xmm12, 96(%%rsp)
            \\movdqa %%xmm13, 112(%%rsp)
            \\movdqa %%xmm14, 128(%%rsp)
            \\movdqa %%xmm15, 144(%%rsp)
            \\fnstcw 160(%%rsp)
            \\stmxcsr 164(%%rsp)
            \\mov %%rcx, %%rax
            \\mov %%rsp, %%rcx
            \\sub $32, %%rsp
            \\call *%%rax
            \\mov %%rax, %%rsp
            \\movdqa 0(%%rsp), %%xmm6
            \\movdqa 16(%%rsp), %%xmm7
            \\movdqa 32(%%rsp), %%xmm8
            \\movdqa 48(%%rsp), %%xmm9
            \\movdqa 64(%%rsp), %%xmm10
            \\movdqa 80(%%rsp), %%xmm11
            \\movdqa 96(%%rsp), %%xmm12
            \\movdqa 112(%%rsp), %%xmm13
            \\movdqa 128(%%rsp), %%xmm14
            \\movdqa 144(%%rsp), %%xmm15
            \\fldcw 160(%%rsp)
            \\ldmxcsr 164(%%rsp)
            \\add $168, %%rsp
            \\pop %%r15
            \\pop %%r14
            \\pop %%r13
            \\pop %%r12
            \\pop %%rsi
            \\pop %%rdi
            \\pop %%rbp
            \\pop %%rbx
            \\ret
        ),
        .aarch64 => asm volatile (
            \\sub sp, sp, #176
            \\stp x19, x20, [sp, #0]
            \\stp x21, x22, [sp, #16]
            \\stp x23, x24, [sp, #32]
            \\stp x25, x26, [sp, #48]
            \\stp x27, x28, [sp, #64]
            \\stp x29, x30, [sp, #80]
            \\stp d8, d9, [sp, #96]
            \\stp d10, d11, [sp, #112]
            \\stp d12, d13, [sp, #128]
            \\stp d14, d15, [sp, #144]
            \\mrs x9, fpcr
            \\str x9, [sp, #160]
            \\mov x9, x0
            \\mov x0, sp
            \\blr x9
            \\mov sp, x0
            \\ldr x9, [sp, #160]
            \\msr fpcr, x9
            \\ldp d14, d15, [sp, #144]
            \\ldp d12, d13, [sp, #128]
            \\ldp d10, d11, [sp, #112]
            \\ldp d8, d9, [sp, #96]
            \\ldp x29, x30, [sp, #80]
            \\ldp x27, x28, [sp, #64]
            \\ldp x25, x26, [sp, #48]
            \\ldp x23, x24, [sp, #32]
            \\ldp x21, x22, [sp, #16]
            \\ldp x19, x20, [sp, #0]
            \\add sp, sp, #176
            \\ret
        ),
        else => unreachable,
    }
}

// A new task's first return lands here:
// entry (r12 / x19) gets arg (r13 / x20)
fn startAsm() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\mov %%r13, %%rcx
            \\mov %%r13, %%rdi
            \\and $-16, %%rsp
            \\sub $32, %%rsp
            \\call *%%r12
            \\ud2
        ),
        .aarch64 => asm volatile (
            \\mov x0, x20
            \\blr x19
            \\brk #0
        ),
        else => unreachable,
    }
}
