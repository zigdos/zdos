// x86-64 code; the contracts are in arch.zig.
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

// Microsoft x64, as UEFI uses it.
pub const cc: std.builtin.CallingConvention = .{ .x86_64_win = .{} };

pub const callOnStack: *const fn (arg: *const anyopaque, func: *const anyopaque, stack_top: usize, saved: *usize) callconv(cc) u8 = @ptrCast(&callOnStackAsm);

pub const exitTo: *const fn (saved: usize, code: u8) callconv(cc) noreturn = @ptrCast(&exitToAsm);

pub const cpuName = @import("x86_cpu.zig").name;
pub const timestamp_is_cpu_clock = true;

// FS base (MSR 0xC0000100), for
// %fs-relative thread_local accesses.
pub fn setThreadPointer(tp: usize) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (@as(u32, 0xC000_0100)),
          [lo] "{eax}" (@as(u32, @truncate(tp))),
          [hi] "{edx}" (@as(u32, @truncate(tp >> 32))),
    );
}

// x86 keeps its I-cache coherent with data writes.
pub fn syncCode(code: []const u8) void {
    _ = code;
}

// rcx, rdx, r8, r9. Every register Microsoft x64 preserves
// (rbx, rbp, rdi, rsi, r12-r15, xmm6-xmm15, x87 CW, MXCSR) is
// saved on the caller's stack, for both a return and exitTo.
// func starts with x87 / SSE as after reset (fninit, MXCSR
// 0x1F80), as the ABI promises a program. rbx keeps the
// caller's stack pointer. Entry stack: 8 mod 16; after 8 pushes
// and 168 bytes it is 16-byte aligned for movdqa.
fn callOnStackAsm() callconv(.naked) void {
    asm volatile (
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
        \\fninit
        \\pushq $0x1F80
        \\ldmxcsr (%%rsp)
        \\add $8, %%rsp
        \\mov %%rsp, (%%r9)
        \\mov %%rsp, %%rbx
        \\mov %%r8, %%rsp
        \\and $-16, %%rsp
        \\sub $32, %%rsp
        \\call *%%rdx
        \\mov %%rbx, %%rsp
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
        \\fninit
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
    );
}

// rcx: where callOnStack saved the registers, dl: the result;
// returns as callOnStack does.
fn exitToAsm() callconv(.naked) void {
    asm volatile (
        \\movzbl %%dl, %%eax
        \\mov %%rcx, %%rsp
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
        \\fninit
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
    );
}
