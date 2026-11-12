// x86_64 page tables for paging.zig: 4 levels, 2 MiB and 1 GiB
// pages where possible. ZDOS's own PAT: RAM write-back,
// the screen write-combining (the firmware's MTRRs rarely
// make it so; uncached, drawing crawls), devices UC-.
// All of the first 4 GiB is mapped.
const std = @import("std");
const paging = @import("paging.zig");
const cpu = @import("cpu_x86_64.zig");

pub const Layout = struct {
    page_shift: u6 = 12,
    index_bits: u6 = 9,
    levels: u3 = 4,
    block_from: u3, // 1: 1 GiB pages; 2: from 2 MiB
    entries: usize = 512,
    table_bytes: usize = 4096,
    address_space: u64 = 1 << 48,
    nx: bool = false, // RW_NX: EFER.NXE on, RAM not executed (paging.zig)
};

// PAT entries 0-3 (and 4-7 the same):
// write-back, write-combining, UC-, UC
const pat_value: u64 = 0x0007_0106_0007_0106;
const write_back = 0; // entry 0
const write_combining = 0x08; // PWT: entry 1
const uncached = 0x10; // PCD: entry 2
var pat_set = false; // the tables use pat_value: other cores need it too

const present_writable = 0x3;
const large = 0x80; // PS: a 1 GiB or 2 MiB page
const no_execute: u64 = 1 << 63;
const address_mask: u64 = 0x000F_FFFF_FFFF_F000;

pub fn supports(size: usize) bool {
    return size == 4096;
}

pub fn prepare(size: usize) !Layout {
    _ = size;
    // 5-level paging (CR4.LA57) would need a fifth level
    if (cr4() & (1 << 12) != 0) return error.FiveLevelPaging;
    // CPUID 1: EDX BIT 16, PAT
    const features = asm volatile ("cpuid"
        : [d] "={edx}" (-> u32),
        : [a] "{eax}" (@as(u32, 1)),
          [c] "{ecx}" (@as(u32, 0)),
        : "ebx"
    );
    if (features & (1 << 16) == 0) return error.NoPat;
    // CPUID 0x80000001: EDX bit 26, 1 GiB pages
    const edx = asm volatile ("cpuid"
        : [d] "={edx}" (-> u32),
        : [a] "{eax}" (@as(u32, 0x8000_0001)),
          [c] "{ecx}" (@as(u32, 0)),
        : "ebx"
    );
    return .{ .block_from = if (edx & (1 << 26) != 0) 1 else 2 };
}

pub fn deviceDefaultTop(top: u64) u64 {
    _ = top;
    return 1 << 32;
}

pub fn leaf(addr: u64, kind: paging.Kind, last: bool, l: Layout) u64 {
    if (kind == .guard) return 0;
    const cache: u64 = switch (kind) {
        .ram, .code, .ram_exec, .guard => write_back,
        .screen => write_combining,
        .device => uncached,
    };
    var e = addr | present_writable | cache | @as(u64, if (last) 0 else large);
    if (kind == .code) e &= ~@as(u64, 2); // read only
    if (l.nx and kind != .code and kind != .ram_exec) e |= no_execute;
    return e;
}

// CPUID 0x80000001: EDX BIT 20, NX
pub fn hasNx() bool {
    const edx = asm volatile ("cpuid"
        : [d] "={edx}" (-> u32),
        : [a] "{eax}" (@as(u32, 0x8000_0001)),
          [c] "{ecx}" (@as(u32, 0)),
        : "ebx"
    );
    return edx & (1 << 20) != 0;
}

pub fn leafAllows(e: u64, write: bool, exec: bool) bool {
    return (!write or e & 2 != 0) and (!exec or e & no_execute == 0);
}

pub fn table(addr: u64) u64 {
    return addr | present_writable;
}

pub fn isValid(e: u64) bool {
    return e & 1 != 0;
}

pub fn isTable(e: u64, last: bool) bool {
    return !last and e & 1 != 0 and e & large == 0;
}

pub fn tableOf(e: u64) [*]u64 {
    return @ptrFromInt(e & address_mask);
}

// One of the entries a large page becomes, with its flags
pub fn smaller(e: u64, addr: u64, child_last: bool, l: Layout) u64 {
    _ = l;
    const flags = e & (0xFFF | no_execute) & ~@as(u64, large);
    return addr | flags | @as(u64, if (child_last) 0 else large);
}

// The PAT, CR3 to the new tables, then a flush of global
// entries (CR4.PGE off and on) and of the caches
pub fn activate(root: [*]u64, l: Layout) void {
    // NX entries fault as reserved bits without EFER.NXE (other
    // cores copy EFER when they start)
    if (l.nx) wrmsr(0xC000_0080, cpu.rdmsrPub(0xC000_0080) | (1 << 11));
    wrmsr(0x277, pat_value);
    pat_set = true;
    asm volatile ("mov %[r], %%cr3"
        :
        : [r] "r" (@intFromPtr(root)),
        : "memory"
    );
    const c4 = cr4();
    if (c4 & (1 << 7) != 0) {
        setCr4(c4 & ~@as(u64, 1 << 7));
        setCr4(c4);
    }
    asm volatile ("wbinvd" ::: "memory");
}

// Entries changed (a device mapped late):
// CR3 again drops what the TLB held
pub fn flush(l: Layout) void {
    _ = l;
    asm volatile (
        \\mov %%cr3, %%rax
        \\mov %%rax, %%cr3
        ::: "rax", "memory");
}

// Another core, already on the tables: the same PAT as core 0
pub fn sharePat() void {
    if (!pat_set) return;
    wrmsr(0x277, pat_value);
    asm volatile (
        \\mov %%cr3, %%rax
        \\mov %%rax, %%cr3
        \\wbinvd
        ::: "rax", "memory");
}

// Only the GDT is the firmware's still (the IDT is cpu_x86_64.zig's)
pub fn ownCpuState() bool {
    return cpu.ownGdt();
}

pub fn stackPointer() u64 {
    return asm volatile ("mov %%rsp, %[r]"
        : [r] "=r" (-> u64),
    );
}

fn cr4() u64 {
    return asm volatile ("mov %%cr4, %[r]"
        : [r] "=r" (-> u64),
    );
}

fn setCr4(v: u64) void {
    asm volatile ("mov %[v], %%cr4"
        :
        : [v] "r" (v),
        : "memory"
    );
}

fn wrmsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
    );
}
