// ARM64 page tables for paging.zig, at EL1 or EL2. EL2 with
// VHE (HCR_EL2.E2H) works as EL1; only the TLB flush differs.
//   4 KiB pages:  4 levels, 48-bit addresses, 1 GiB and 2 MiB blocks
//   16 KiB pages: 3 levels, 47-bit addresses, 32 MiB blocks
//   64 KiB pages: 2 levels, 42-bit addresses, 512 MiB blocks
// The firmware's MAIR is kept and searched for the needed types,
// so the switch changes no memory type under running code.
const std = @import("std");
const paging = @import("paging.zig");

pub const Layout = struct {
    page_shift: u6,
    index_bits: u6,
    levels: u3,
    block_from: u3,
    entries: usize,
    table_bytes: usize,
    address_space: u64,
    el2: bool, // EL2 without VHE: its own registers and entry format
    vhe: bool, // EL2 with VHE
    normal: u64, // MAIR indices
    device: u64,
    uncached: u64,
    tcr: u64,
};

const address_mask: u64 = 0x0000_FFFF_FFFF_F000;
const access_flag = 1 << 10;
const inner_shareable = 3 << 8;

fn mmfr0() u64 {
    return asm volatile ("mrs %[r], id_aa64mmfr0_el1"
        : [r] "=r" (-> u64),
    );
}

// ID_AA64MMFR0_EL1: TGran4 (bits 28-31) 0xF = none, TGran64
// (24-27) 0xF = none, TGran16 (20-23) 0 = none
pub fn supports(size: usize) bool {
    const m = mmfr0();
    return switch (size) {
        4096 => (m >> 28) & 0xF != 0xF,
        16384 => (m >> 20) & 0xF != 0,
        65536 => (m >> 24) & 0xF != 0xF,
        else => false,
    };
}

pub fn prepare(size: usize) !Layout {
    const at_el2 = (asm volatile ("mrs %[r], CurrentEL"
        : [r] "=r" (-> u64),
    ) >> 2) & 3 == 2;
    const vhe = at_el2 and asm volatile ("mrs %[r], S3_4_C1_C1_0"
        : [r] "=r" (-> u64),
    ) & (1 << 34) != 0;
    const el2 = at_el2 and !vhe;
    const mair = if (el2) asm volatile ("mrs %[r], S3_4_C10_C2_0"
        : [r] "=r" (-> u64),
    ) else asm volatile ("mrs %[r], mair_el1"
        : [r] "=r" (-> u64),
    );
    // 0xFF normal write-back; device: high
    // nibble 0, low 0/4/8/C; 0x44 normal uncached
    var normal: ?u64 = null;
    var device: ?u64 = null;
    var uncached: ?u64 = null;
    for (0..8) |i| {
        const a: u8 = @truncate(mair >> @intCast(8 * i));
        if (a == 0xFF and normal == null) normal = i;
        if (a & 0xF3 == 0 and (device == null or a == 0x04)) device = i;
        if (a == 0x44 and uncached == null) uncached = i;
    }

    // Output address size (PARange, bits 0-3): 32, 36, 40, 42, 44, 48 bits
    const pa_range: u64 = @min(mmfr0() & 0xF, 5);
    const pa_bits: u6 = switch (pa_range) {
        0 => 32,
        1 => 36,
        2 => 40,
        3 => 42,
        4 => 44,
        else => 48,
    };
    const shift: u6, const levels: u3, const block_from: u3, const va_bits: u6, const tg0: u64 = switch (size) {
        4096 => .{ 12, 4, 1, 48, 0b00 },
        16384 => .{ 14, 3, 1, 47, 0b10 },
        65536 => .{ 16, 2, 0, 42, 0b01 },
        else => return error.UnsupportedPageSize,
    };
    const t0sz: u64 = 64 - @as(u64, va_bits);
    // Table walks cached (inner/outer write-back, inner shareable)
    const walk: u64 = (3 << 12) | (1 << 10) | (1 << 8);
    const tcr = if (el2)
        (1 << 31) | (1 << 23) | (pa_range << 16) | (tg0 << 14) | walk | t0sz
    else
        (pa_range << 32) | (0b10 << 30) | (1 << 23) | (tg0 << 14) | walk | t0sz; // TTBR1 off (EPD1)
    const n = normal orelse return error.NoWriteBackType;
    const d = device orelse return error.NoDeviceType;
    return .{
        .page_shift = shift,
        .index_bits = shift - 3,
        .levels = levels,
        .block_from = block_from,
        .entries = @as(usize, 1) << (shift - 3),
        .table_bytes = @as(usize, 1) << shift,
        .address_space = @as(u64, 1) << @min(va_bits, pa_bits),
        .el2 = el2,
        .vhe = vhe,
        .normal = n,
        .device = d,
        .uncached = uncached orelse d,
        .tcr = tcr,
    };
}

pub fn deviceDefaultTop(top: u64) u64 {
    return top;
}

// A block (0b01) or, at the last level, a page (0b11).
// Devices and the screen never execute (EL1: PXN and UXN;
// EL2: XN). At EL2, AP[1] (bit 6) must be 1.
pub fn leaf(addr: u64, kind: paging.Kind, last: bool, l: Layout) u64 {
    if (kind == .guard) return 0;
    var e = addr | @as(u64, if (last) 0b11 else 0b01) | access_flag;
    if (l.el2) e |= 1 << 6;
    const never_execute: u64 = if (l.el2) 1 << 54 else (1 << 53) | (1 << 54);
    switch (kind) {
        .ram, .ram_exec, .guard => e |= (l.normal << 2) | inner_shareable,
        .code => e |= (l.normal << 2) | inner_shareable | (1 << 7), // AP[2]: read only
        .device => e |= (l.device << 2) | never_execute,
        .screen => e |= (l.uncached << 2) | inner_shareable | never_execute,
    }
    return e;
}

pub fn table(addr: u64) u64 {
    return addr | 0b11;
}

// AP[2] read only; PXN (EL1) or XN (EL2) never executed
pub fn leafAllows(e: u64, write: bool, exec: bool) bool {
    return (!write or e & (1 << 7) == 0) and (!exec or e & (3 << 53) == 0);
}

pub fn isValid(e: u64) bool {
    return e & 1 != 0;
}

pub fn isTable(e: u64, last: bool) bool {
    return !last and e & 0b11 == 0b11;
}

pub fn tableOf(e: u64) [*]u64 {
    return @ptrFromInt(e & address_mask);
}

pub fn smaller(e: u64, addr: u64, child_last: bool, l: Layout) u64 {
    _ = l;
    const attributes = e & ~address_mask & ~@as(u64, 0b11);
    return addr | attributes | @as(u64, if (child_last) 0b11 else 0b01);
}

// New table base and TCR, then the old translations out of the
// TLB. The code switching is mapped the
// same before and after (identity, RAM).
pub fn activate(root: [*]u64, l: Layout) void {
    if (l.el2) {
        asm volatile (
            \\dsb ishst
            \\msr S3_4_C2_C0_0, %[root]
            \\msr S3_4_C2_C0_2, %[tcr]
            \\isb
            \\sys #4, c8, c7, #0 // TLBI ALLE2
            \\dsb ish
            \\isb
            :
            : [root] "r" (@intFromPtr(root)),
              [tcr] "r" (l.tcr),
            : "memory"
        );
    } else if (l.vhe) {
        asm volatile (
            \\dsb ishst
            \\msr ttbr0_el1, %[root]
            \\msr tcr_el1, %[tcr]
            \\isb
            \\sys #4, c8, c7, #0 // TLBI ALLE2
            \\dsb ish
            \\isb
            :
            : [root] "r" (@intFromPtr(root)),
              [tcr] "r" (l.tcr),
            : "memory"
        );
    } else {
        asm volatile (
            \\dsb ishst
            \\msr ttbr0_el1, %[root]
            \\msr tcr_el1, %[tcr]
            \\isb
            \\tlbi vmalle1
            \\dsb ish
            \\isb
            :
            : [root] "r" (@intFromPtr(root)),
              [tcr] "r" (l.tcr),
            : "memory"
        );
    }
}

// Entries changed (a device mapped late): the TLB
// dropped, on every core
pub fn flush(l: Layout) void {
    if (l.el2 or l.vhe) {
        asm volatile (
            \\dsb ishst
            \\sys #4, c8, c3, #0 // TLBI ALLE2IS
            \\dsb ish
            \\isb
            ::: "memory");
    } else {
        asm volatile (
            \\dsb ishst
            \\tlbi vmalle1is
            \\dsb ish
            \\isb
            ::: "memory");
    }
}

// The exception vectors are ZDOS's
// since startup (cpu_arm64.zig); there is no GDT
pub fn ownCpuState() bool {
    return true;
}

pub fn stackPointer() u64 {
    return asm volatile ("mov %[r], sp"
        : [r] "=r" (-> u64),
    );
}
