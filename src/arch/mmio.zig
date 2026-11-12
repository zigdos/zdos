// MMIO registers. A plain volatile read can be narrowed (`reg &
// 1` as x86 `testb`), which 16- and 32-bit registers answer
// with 0 or refuse: asm keeps it full width.
const builtin = @import("builtin");

pub inline fn load16(p: *const volatile u16) u16 {
    return switch (builtin.cpu.arch) {
        .x86_64, .x86 => asm volatile ("movw (%[p]), %[r]"
            : [r] "=r" (-> u16),
            : [p] "r" (p),
            : "memory"
        ),
        .aarch64 => asm volatile ("ldrh %[r:w], [%[p]]"
            : [r] "=r" (-> u16),
            : [p] "r" (p),
            : "memory"
        ),
        else => p.*,
    };
}

pub inline fn load32(p: *const volatile u32) u32 {
    return switch (builtin.cpu.arch) {
        .x86_64, .x86 => asm volatile ("movl (%[p]), %[r]"
            : [r] "=r" (-> u32),
            : [p] "r" (p),
            : "memory"
        ),
        .aarch64 => asm volatile ("ldr %[r:w], [%[p]]"
            : [r] "=r" (-> u32),
            : [p] "r" (p),
            : "memory"
        ),
        else => p.*,
    };
}

pub inline fn read8(addr: usize) u8 {
    return @as(*const volatile u8, @ptrFromInt(addr)).*;
}

pub inline fn read16(addr: usize) u16 {
    return load16(@ptrFromInt(addr));
}

pub inline fn read32(addr: usize) u32 {
    return load32(@ptrFromInt(addr));
}

pub inline fn write8(addr: usize, v: u8) void {
    @as(*volatile u8, @ptrFromInt(addr)).* = v;
}

pub inline fn write16(addr: usize, v: u16) void {
    @as(*volatile u16, @ptrFromInt(addr)).* = v;
}

pub inline fn write32(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}
