// Starting the other x86_64 cores (smp.zig). A core starts in
// real mode at a page below 1 MiB, so a stub copied there goes
// through protected mode into long mode with core 0's CR3, GDT
// and IDT, then calls zdos_x86_ap_main. Cores come from ACPI's
// MADT (types 0 and 9). Workers are woken by IPI.
const std = @import("std");
const smp = @import("smp.zig");
const cpu = @import("cpu_x86_64.zig");
const paging = @import("paging_x86_64.zig");
const page_tables = @import("paging.zig");
const acpi = @import("acpi.zig");
const memory = @import("memory.zig");
const clock = @import("clock.zig");

pub const wake_vector = 0x40;

// The stub. Its fields (ap_*) are filled in the copy; addresses
// inside it are offsets from zdos_ap_start,
// the copy's base in EBX from 32-bit mode on.
comptime {
    asm (
        \\.text
        \\.code16
        \\.global zdos_ap_start
        \\zdos_ap_start:
        \\    cli
        \\    cld
        \\    mov %cs, %ax
        \\    mov %ax, %ds
        \\    xor %ebx, %ebx
        \\    mov %cs, %bx
        \\    shl $4, %ebx
        \\    lgdtl zdos_ap_gdtr - zdos_ap_start
        \\    mov %cr0, %eax
        \\    or $1, %eax
        \\    mov %eax, %cr0
        \\    ljmpl *(zdos_ap_far32 - zdos_ap_start)
        \\.code32
        \\.global zdos_ap_32
        \\zdos_ap_32:
        \\    mov $0x10, %ax
        \\    mov %ax, %ds
        \\    mov %ax, %es
        \\    mov %ax, %ss
        \\    mov %cr4, %eax
        \\    or $0x620, %eax
        \\    mov %eax, %cr4
        \\    mov (zdos_ap_cr3 - zdos_ap_start)(%ebx), %eax
        \\    mov %eax, %cr3
        \\    mov $0xC0000080, %ecx
        \\    mov (zdos_ap_efer - zdos_ap_start)(%ebx), %eax
        \\    xor %edx, %edx
        \\    wrmsr
        \\    mov %cr0, %eax
        \\    and $0xFFFFFFFB, %eax
        \\    or $0x80010022, %eax
        \\    mov %eax, %cr0
        \\    ljmpl *(zdos_ap_far64 - zdos_ap_start)(%ebx)
        \\.code64
        \\.global zdos_ap_64
        \\zdos_ap_64:
        \\    mov %ebx, %ebx
        \\    lgdt (zdos_ap_kernel_gdtr - zdos_ap_start)(%rbx)
        \\    lidt (zdos_ap_kernel_idtr - zdos_ap_start)(%rbx)
        \\    movw (zdos_ap_kernel_ds - zdos_ap_start)(%rbx), %ax
        \\    mov %ax, %ds
        \\    mov %ax, %es
        \\    mov %ax, %ss
        \\    mov %ax, %fs
        \\    mov %ax, %gs
        \\    mov (zdos_ap_stack - zdos_ap_start)(%rbx), %rsp
        \\    movzwq (zdos_ap_kernel_cs - zdos_ap_start)(%rbx), %rax
        \\    push %rax
        \\    lea 1f(%rip), %rax
        \\    push %rax
        \\    lretq
        \\1:
        \\    mov (zdos_ap_index - zdos_ap_start)(%rbx), %rcx
        \\    mov (zdos_ap_entry - zdos_ap_start)(%rbx), %rax
        \\    sub $32, %rsp
        \\    call *%rax
        \\2:
        \\    hlt
        \\    jmp 2b
        \\.balign 8
        \\.global zdos_ap_gdt
        \\zdos_ap_gdt:
        \\    .quad 0
        \\    .quad 0x00CF9A000000FFFF
        \\    .quad 0x00CF92000000FFFF
        \\    .quad 0x00AF9A000000FFFF
        \\.global zdos_ap_gdtr
        \\zdos_ap_gdtr:
        \\    .word 31
        \\    .long 0
        \\.global zdos_ap_far32
        \\zdos_ap_far32:
        \\    .long 0
        \\    .word 0x08
        \\.global zdos_ap_far64
        \\zdos_ap_far64:
        \\    .long 0
        \\    .word 0x18
        \\.global zdos_ap_cr3
        \\zdos_ap_cr3:
        \\    .long 0
        \\.global zdos_ap_efer
        \\zdos_ap_efer:
        \\    .long 0
        \\.global zdos_ap_kernel_gdtr
        \\zdos_ap_kernel_gdtr:
        \\    .word 0
        \\    .quad 0
        \\.global zdos_ap_kernel_idtr
        \\zdos_ap_kernel_idtr:
        \\    .word 0
        \\    .quad 0
        \\.global zdos_ap_kernel_cs
        \\zdos_ap_kernel_cs:
        \\    .word 0
        \\.global zdos_ap_kernel_ds
        \\zdos_ap_kernel_ds:
        \\    .word 0
        \\.balign 8
        \\.global zdos_ap_stack
        \\zdos_ap_stack:
        \\    .quad 0
        \\.global zdos_ap_index
        \\zdos_ap_index:
        \\    .quad 0
        \\.global zdos_ap_entry
        \\zdos_ap_entry:
        \\    .quad 0
        \\.global zdos_ap_end
        \\zdos_ap_end:
    );
}

extern const zdos_ap_start: u8;
extern const zdos_ap_32: u8;
extern const zdos_ap_64: u8;
extern const zdos_ap_gdt: u8;
extern const zdos_ap_gdtr: u8;
extern const zdos_ap_far32: u8;
extern const zdos_ap_far64: u8;
extern const zdos_ap_cr3: u8;
extern const zdos_ap_efer: u8;
extern const zdos_ap_kernel_gdtr: u8;
extern const zdos_ap_kernel_idtr: u8;
extern const zdos_ap_kernel_cs: u8;
extern const zdos_ap_kernel_ds: u8;
extern const zdos_ap_stack: u8;
extern const zdos_ap_index: u8;
extern const zdos_ap_entry: u8;
extern const zdos_ap_end: u8;

var stub: [*]u8 = undefined; // the copy below 1 MiB
var stub_page: ?[*]align(4096) u8 = null;
var main_apic: u32 = 0;

// Right after leaving the firmware: the page for the stub,
// below 1 MiB, before the drivers take the
// low memory (it is handed out lowest first)
pub fn reserve() void {
    stub_page = memory.allocBelow(0x10_0000);
    if (stub_page) |p| page_tables.setStubPage(@intFromPtr(p));
}

// A field of the copy, by its symbol
// in the original (plus `extra` bytes)
fn field(comptime T: type, sym: *const u8) *align(1) T {
    return fieldAt(T, sym, 0);
}

fn fieldAt(comptime T: type, sym: *const u8, extra: usize) *align(1) T {
    return @ptrCast(stub + offsetOf(sym) + extra);
}

pub fn startAll(add: *const fn (hw_id: u64) ?smp.Started) void {
    if (!cpu.apicReady()) return;
    if (cpu.cr4() & (1 << 12) != 0) return; // 5-level paging: the stub doesn't do it
    const cr3 = cpu.cr3() & 0x000F_FFFF_FFFF_F000;
    if (cr3 >= 1 << 32) return; // loaded in 32-bit mode
    const size = @intFromPtr(&zdos_ap_end) - @intFromPtr(&zdos_ap_start);
    const page = stub_page orelse return; // the startup IPI's page
    stub = page;
    @memcpy(stub[0..size], @as([*]const u8, @ptrCast(&zdos_ap_start))[0..size]);

    const base: u32 = @intCast(@intFromPtr(stub));
    fieldAt(u32, &zdos_ap_gdtr, 2).* = base + offsetOf(&zdos_ap_gdt); // after the limit
    field(u32, &zdos_ap_far32).* = base + offsetOf(&zdos_ap_32);
    field(u32, &zdos_ap_far64).* = base + offsetOf(&zdos_ap_64);
    field(u32, &zdos_ap_cr3).* = @intCast(cr3);
    field(u32, &zdos_ap_efer).* = @truncate(cpu.rdmsrPub(0xC000_0080) & ~@as(u64, 1 << 10)); // LMA is read-only
    cpu.storeGdtr(@ptrCast(field([10]u8, &zdos_ap_kernel_gdtr)));
    cpu.storeIdtr(@ptrCast(field([10]u8, &zdos_ap_kernel_idtr)));
    field(u16, &zdos_ap_kernel_cs).* = cpu.codeSelector();
    field(u16, &zdos_ap_kernel_ds).* = cpu.dataSelector();
    field(u64, &zdos_ap_entry).* = @intFromPtr(&zdos_x86_ap_main);

    main_apic = cpu.apicId();
    const madt = acpi.find("APIC") orelse return;
    var off: usize = 44;
    while (off + 2 <= madt.len) {
        const len = madt[off + 1];
        if (len < 2 or off + len > madt.len) break;
        const e = madt[off .. off + len];
        const id: ?u32 = switch (e[0]) {
            0 => if (len >= 8 and std.mem.readInt(u32, e[4..8], .little) & 1 != 0) e[3] else null,
            9 => if (len >= 16 and std.mem.readInt(u32, e[8..12], .little) & 1 != 0) std.mem.readInt(u32, e[4..8], .little) else null,
            else => null,
        };
        off += len;
        const apic = id orelse continue;
        if (apic == main_apic) continue;
        const s = add(apic) orelse break;
        startOne(apic, s);
    }
}

fn offsetOf(sym: *const u8) u32 {
    return @intCast(@intFromPtr(sym) - @intFromPtr(&zdos_ap_start));
}

// INIT, 10 ms, startup IPI twice (vector:
// the stub's page number); then up to 100 ms for
// the core to report (smp.coreOnline)
fn startOne(apic: u32, s: smp.Started) void {
    field(u64, &zdos_ap_stack).* = s.stack_top;
    field(u64, &zdos_ap_index).* = s.index;
    asm volatile ("mfence" ::: "memory");
    const vector: u32 = @intCast(@intFromPtr(stub) >> 12);
    cpu.sendIpi(apic, 0x4500); // INIT, assert
    clock.delayUs(10_000);
    cpu.sendIpi(apic, 0x4600 | vector); // startup
    clock.delayUs(200);
    cpu.sendIpi(apic, 0x4600 | vector);
    const until = clock.millis() + 100;
    while (clock.millis() < until) {
        if (smp.onlineCount() > s.index) return;
        std.atomic.spinLoopHint();
    }
}

// A new core, on its stack with core 0's tables, GDT and IDT:
// its local APIC, the x87/SSE state, then the worker loop
export fn zdos_x86_ap_main(index: u64) callconv(.c) noreturn {
    paging.sharePat();
    if (!cpu.loadTss(@intCast(index))) cpu.noFaultStacks();
    cpu.initOtherCore();
    asm volatile ("fninit");
    smp.workerLoop(@intCast(index));
}

pub fn wake(c: *smp.Core) void {
    cpu.sendIpi(@intCast(c.hw_id), wake_vector);
}

pub fn jobDone() void {
    cpu.sendIpi(main_apic, wake_vector);
}

// Until an interrupt: the wake-up IPI. sti takes effect after
// hlt, so an IPI sent before the hlt still ends it.
pub fn sleep(c: *smp.Core) void {
    _ = c;
    asm volatile ("sti; hlt; cli" ::: "memory");
}
