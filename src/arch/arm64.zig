// AArch64 code; the contracts are in arch.zig.
const std = @import("std");

// The generic timer's virtual counter: a fixed rate
// (CNTFRQ_EL0, often 24-100 MHz) since power-on. isb keeps the
// read from happening early.
pub fn timestamp() u64 {
    return asm volatile (
        \\isb
        \\mrs %[ret], cntvct_el0
        : [ret] "=r" (-> u64),
    );
}

// CNTFRQ_EL0 as the firmware set it; null if not.
pub fn counterRate() ?u64 {
    const f = asm volatile ("mrs %[r], cntfrq_el0"
        : [r] "=r" (-> u64),
    );
    return if (f == 0) null else f;
}

// The generic timer is not the CPU clock.
pub const timestamp_is_cpu_clock = false;

// "ARM Cortex-A57 (r1p0)", from the Main ID Register.
pub fn cpuName(buf: []u8) []const u8 {
    const midr = asm volatile ("mrs %[ret], midr_el1"
        : [ret] "=r" (-> u64),
    );
    const implementer: u8 = @truncate(midr >> 24);
    const variant: u8 = @truncate((midr >> 20) & 0xF);
    const part: u16 = @truncate((midr >> 4) & 0xFFF);
    const revision: u8 = @truncate(midr & 0xF);
    const maker: ?[]const u8 = switch (implementer) {
        0x41 => "ARM",
        0x42 => "Broadcom",
        0x43 => "Cavium",
        0x48 => "HiSilicon",
        0x4E => "NVIDIA",
        0x51 => "Qualcomm",
        0x61 => "Apple",
        0xC0 => "Ampere",
        else => null,
    };
    const core: ?[]const u8 = if (implementer != 0x41) null else switch (part) {
        0xD03 => "Cortex-A53",
        0xD04 => "Cortex-A35",
        0xD05 => "Cortex-A55",
        0xD07 => "Cortex-A57",
        0xD08 => "Cortex-A72",
        0xD09 => "Cortex-A73",
        0xD0A => "Cortex-A75",
        0xD0B => "Cortex-A76",
        0xD0C => "Neoverse N1",
        0xD0D => "Cortex-A77",
        0xD40 => "Neoverse V1",
        0xD41 => "Cortex-A78",
        0xD44 => "Cortex-X1",
        0xD46 => "Cortex-A510",
        0xD47 => "Cortex-A710",
        0xD48 => "Cortex-X2",
        0xD49 => "Neoverse N2",
        0xD4D => "Cortex-A715",
        0xD4E => "Cortex-X3",
        0xD4F => "Neoverse V2",
        0xD80 => "Cortex-A520",
        0xD81 => "Cortex-A720",
        0xD82 => "Cortex-X4",
        else => null,
    };
    if (maker != null and core != null) {
        return std.fmt.bufPrint(buf, "{s} {s} (r{d}p{d})", .{ maker.?, core.?, variant, revision }) catch buf[0..0];
    }
    if (maker) |m| return std.fmt.bufPrint(buf, "{s}, part 0x{x:0>3} (r{d}p{d})", .{ m, part, variant, revision }) catch buf[0..0];
    return std.fmt.bufPrint(buf, "implementer 0x{x:0>2}, part 0x{x:0>3} (r{d}p{d})", .{ implementer, part, variant, revision }) catch buf[0..0];
}

// AAPCS64, which UEFI on ARM uses too.
pub const cc: std.builtin.CallingConvention = .{ .aarch64_aapcs = .{} };

pub const callOnStack: *const fn (arg: *const anyopaque, func: *const anyopaque, stack_top: usize, saved: *usize) callconv(cc) u8 = @ptrCast(&callOnStackAsm);

pub const exitTo: *const fn (saved: usize, code: u8) callconv(cc) noreturn = @ptrCast(&exitToAsm);

// x0 arg, x1 func, x2 stack_top, x3 saved. x19-x30 and d8-d15
// are saved on the caller's stack, 160 bytes, for both a
// return and exitTo. x29 keeps the caller's stack pointer
// while func runs. 16-byte aligned stack.
fn callOnStackAsm() callconv(.naked) void {
    asm volatile (
        \\stp x29, x30, [sp, #-160]!
        \\stp x19, x20, [sp, #16]
        \\stp x21, x22, [sp, #32]
        \\stp x23, x24, [sp, #48]
        \\stp x25, x26, [sp, #64]
        \\stp x27, x28, [sp, #80]
        \\stp d8, d9, [sp, #96]
        \\stp d10, d11, [sp, #112]
        \\stp d12, d13, [sp, #128]
        \\stp d14, d15, [sp, #144]
        \\mov x9, sp
        \\str x9, [x3]
        \\mov x29, sp
        \\and x9, x2, #0xfffffffffffffff0
        \\mov sp, x9
        \\blr x1
        \\mov sp, x29
        \\ldp d14, d15, [sp, #144]
        \\ldp d12, d13, [sp, #128]
        \\ldp d10, d11, [sp, #112]
        \\ldp d8, d9, [sp, #96]
        \\ldp x27, x28, [sp, #80]
        \\ldp x25, x26, [sp, #64]
        \\ldp x23, x24, [sp, #48]
        \\ldp x21, x22, [sp, #32]
        \\ldp x19, x20, [sp, #16]
        \\ldp x29, x30, [sp], #160
        \\ret
    );
}

// x0: where callOnStack saved the registers, w1: the result;
// returns as callOnStack does.
fn exitToAsm() callconv(.naked) void {
    asm volatile (
        \\mov sp, x0
        \\and w0, w1, #0xff
        \\ldp d14, d15, [sp, #144]
        \\ldp d12, d13, [sp, #128]
        \\ldp d10, d11, [sp, #112]
        \\ldp d8, d9, [sp, #96]
        \\ldp x27, x28, [sp, #80]
        \\ldp x25, x26, [sp, #64]
        \\ldp x23, x24, [sp, #48]
        \\ldp x21, x22, [sp, #32]
        \\ldp x19, x20, [sp, #16]
        \\ldp x29, x30, [sp], #160
        \\ret
    );
}

// TPIDR_EL0: what thread_local accesses read.
pub fn setThreadPointer(tp: usize) void {
    asm volatile ("msr tpidr_el0, %[v]"
        :
        : [v] "r" (tp),
        : "memory"
    );
}

// The I-cache doesn't see data writes: clean the code to the
// point of unification, then invalidate.
pub fn syncCode(code: []const u8) void {
    if (code.len == 0) return;
    const ctr = asm volatile ("mrs %[ret], ctr_el0"
        : [ret] "=r" (-> u64),
    );
    const d_line = @as(usize, 4) << @intCast((ctr >> 16) & 0xF);
    const i_line = @as(usize, 4) << @intCast(ctr & 0xF);
    const start = @intFromPtr(code.ptr);
    const end = start + code.len;

    var a = start & ~(d_line - 1);
    while (a < end) : (a += d_line) {
        asm volatile ("dc cvau, %[a]"
            :
            : [a] "r" (a),
            : "memory"
        );
    }
    asm volatile ("dsb ish" ::: "memory");
    a = start & ~(i_line - 1);
    while (a < end) : (a += i_line) {
        asm volatile ("ic ivau, %[a]"
            :
            : [a] "r" (a),
            : "memory"
        );
    }
    asm volatile (
        \\dsb ish
        \\isb
        ::: "memory");
}
