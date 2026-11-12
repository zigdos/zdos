// The other CPU cores of the BIOS edition (platform.cores):
// job workers, started on first use, as on metal. The cores
// come from ACPI's MADT, or the MultiProcessor Specification's
// table (1990s boards). A core starts in real mode at 0x9000
// (free once stage 2 unpacked the kernel), where start-up code
// goes into 32-bit protected mode with core 0's GDT and IDT.
const std = @import("std");
const platform = @import("../../platform.zig");
const arch = @import("../../arch/x86.zig");
const acpi = @import("acpi.zig");
const lapic = @import("lapic.zig");
const memory = @import("memory.zig");
const clock = @import("clock.zig");

pub const max_cores = 16;
const stack_pages = 16; // 64 KiB
const stub_at = 0x9000; // the start-up IPI's page (vector 0x09)

const idle_state: u32 = 0;
const busy_state: u32 = 1;

pub const Core = struct {
    hw_id: u32 = 0, // APIC ID
    state: std.atomic.Value(u32) = .init(idle_state),
    job: platform.Job = undefined,
    arg: ?*anyopaque = null,
};

pub var cores: [max_cores]Core = [_]Core{.{}} ** max_cores;
var online = std.atomic.Value(usize).init(1);
var started = false;
var dedicated: ?usize = null;

// Whether the caller runs on core 0 (the only one running tasks)
pub fn onCoreZero() bool {
    if (online.load(.acquire) < 2) return true;
    return lapic.id() == cores[0].hw_id;
}

// All the cores, the one ZDOS keeps (dedicate) too:
// it only refuses jobs
pub fn count() usize {
    return startedCount();
}

pub fn reserved() ?usize {
    return dedicated;
}

fn startedCount() usize {
    if (!started) {
        started = true;
        startAll();
    }
    return online.load(.acquire);
}

pub fn start(core: u32, job: platform.Job, arg: ?*anyopaque) bool {
    if (core == 0 or core >= online.load(.acquire) or dedicated == core) return false;
    const c = &cores[core];
    if (c.state.load(.acquire) != idle_state) return false;
    c.job = job;
    c.arg = arg;
    c.state.store(busy_state, .release);
    wakeCore(core);
    return true;
}

pub fn busy(core: u32) bool {
    if (core == 0 or core >= online.load(.acquire) or dedicated == core) return false;
    return cores[core].state.load(.acquire) != idle_state;
}

// Core 0 halts between looks: its PIT tick wakes it
pub fn wait(core: u32) void {
    if (core == 0 or core >= online.load(.acquire) or dedicated == core) return;
    while (cores[core].state.load(.acquire) != idle_state) arch.halt();
}

// A core (want, else the last) taken from the programs for
// job(arg), which never ends; null with fewer than two cores or
// when want is 0 or past them
pub fn dedicate(job: platform.Job, arg: ?*anyopaque, want: ?usize) ?usize {
    const n = startedCount();
    if (n < 2 or dedicated != null) return null;
    const core = want orelse n - 1;
    if (core == 0 or core >= n) return null;
    if (!start(@intCast(core), job, arg)) return null;
    dedicated = core;
    return core;
}

pub fn wakeCore(core: usize) void {
    lapic.sendIpi(cores[core].hw_id, arch.wake_vector);
}

fn startAll() void {
    if (!lapic.init()) return;
    const main_id = lapic.id();
    cores[0].hw_id = main_id;
    installStub();
    var ids: [max_cores]u32 = undefined;
    const n = findCores(&ids);
    for (ids[0..n]) |apic| {
        if (apic == main_id) continue;
        const index = online.load(.acquire);
        if (index == max_cores) break;
        const stack = memory.allocPages(stack_pages, false) orelse break;
        cores[index] = .{ .hw_id = apic };
        startOne(apic, index, @intFromPtr(stack) + stack_pages * 4096);
    }
}

// APIC IDs of the enabled cores: the MADT's, else the MP table's
fn findCores(out: *[max_cores]u32) usize {
    var n: usize = 0;
    if (acpi.findTable("APIC")) |madt| {
        var off: usize = 44;
        while (off + 2 <= madt.len and n < out.len) {
            const len = madt[off + 1];
            if (len < 2 or off + len > madt.len) break;
            const e = madt[off .. off + len];
            if (e[0] == 0 and len >= 8 and std.mem.readInt(u32, e[4..8], .little) & 1 != 0) {
                out[n] = e[3];
                n += 1;
            }
            off += len;
        }
        if (n > 0) return n;
    }
    const table = mpTable() orelse return 0;
    // Entries after the 44-byte header: processors
    // (type 0) are 20 bytes, the others 8
    const entries = std.mem.readInt(u16, table[34..36], .little);
    var off: usize = 44;
    var i: usize = 0;
    while (i < entries and off < table.len and n < out.len) : (i += 1) {
        if (table[off] == 0) {
            if (off + 20 > table.len) break;
            if (table[off + 3] & 1 != 0) {
                out[n] = table[off + 1];
                n += 1;
            }
            off += 20;
        } else off += 8;
    }
    return n;
}

// The MP floating pointer ("_MP_", 16 bytes) in the EBDA's
// first KiB, the last KiB of base memory or the BIOS ROM; its
// configuration table ("PCMP")
fn mpTable() ?[]const u8 {
    const ebda = @as(usize, @as(*const u16, @ptrFromInt(0x40E)).*) << 4;
    const areas = [_][2]usize{ .{ ebda, 1024 }, .{ 0x9FC00, 1024 }, .{ 0xF0000, 0x10000 } };
    for (areas) |a| {
        if (a[0] == 0) continue;
        var at = a[0];
        while (at + 16 <= a[0] + a[1]) : (at += 16) {
            const p: [*]const u8 = @ptrFromInt(at);
            if (!std.mem.eql(u8, p[0..4], "_MP_") or !sumOk(p[0..16])) continue;
            const addr = std.mem.readInt(u32, p[4..8], .little);
            if (addr == 0) return null; // a default configuration: no table
            const t: [*]const u8 = @ptrFromInt(addr);
            if (!std.mem.eql(u8, t[0..4], "PCMP")) return null;
            const len = std.mem.readInt(u16, t[4..6], .little);
            if (len < 44 or !sumOk(t[0..len])) return null;
            return t[0..len];
        }
    }
    return null;
}

fn sumOk(bytes: []const u8) bool {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum == 0;
}

// INIT, 10 ms, the start-up IPI twice; then
// up to 100 ms for the core to count itself
fn startOne(apic: u32, index: usize, stack_top: usize) void {
    field(u32, &zdos_bios_ap_stack).* = @intCast(stack_top);
    field(u32, &zdos_bios_ap_index).* = @intCast(index);
    asm volatile ("" ::: "memory");
    lapic.sendIpi(apic, 0x4500); // INIT, assert
    clock.delayUs(10_000);
    const vector: u32 = stub_at >> 12;
    lapic.sendIpi(apic, 0x4600 | vector);
    clock.delayUs(200);
    lapic.sendIpi(apic, 0x4600 | vector);
    const until = clock.millis() + 100;
    while (clock.millis() < until) {
        if (online.load(.acquire) > index) return;
        std.atomic.spinLoopHint();
    }
}

// A new core in protected mode, on its stack: its APIC, the
// FPU, then waiting for jobs
export fn zdos_bios_ap_main(index: u32) callconv(.c) noreturn {
    lapic.initOther();
    arch.enableFpu();
    if (online.load(.acquire) == index) online.store(index + 1, .release);
    const c = &cores[index];
    while (true) {
        if (c.state.load(.acquire) == busy_state) {
            c.job(c.arg);
            c.state.store(idle_state, .release);
        } else {
            // sti takes effect after hlt: an IPI sent before still ends it
            asm volatile ("sti; hlt; cli" ::: "memory");
        }
    }
}

// Real mode with CS = 0x0900: core 0's GDT, protected mode,
// then 32-bit code at its linear address (0x9000 + its
// offset), core 0's IDT, the stack, zdos_bios_ap_main(index)
// (by its absolute address: the code runs moved). Fields are
// filled in the copy.

// THE START-UP CODE, COPIED TO 0x9000
comptime {
    asm (
        \\.text
        \\.code16
        \\.global zdos_bios_ap_start
        \\zdos_bios_ap_start:
        \\    cli
        \\    cld
        \\    mov %cs, %ax
        \\    mov %ax, %ds
        \\    lgdtl zdos_bios_ap_gdtr - zdos_bios_ap_start
        \\    mov %cr0, %eax
        \\    or $1, %eax
        \\    mov %eax, %cr0
        \\    ljmpl *(zdos_bios_ap_far32 - zdos_bios_ap_start)
        \\.code32
        \\zdos_bios_ap_32:
        \\    mov $0x10, %ax
        \\    mov %ax, %ds
        \\    mov %ax, %es
        \\    mov %ax, %fs
        \\    mov %ax, %gs
        \\    mov %ax, %ss
        \\    lidt 0x9000 + (zdos_bios_ap_idtr - zdos_bios_ap_start)
        \\    mov 0x9000 + (zdos_bios_ap_stack - zdos_bios_ap_start), %esp
        \\    mov 0x9000 + (zdos_bios_ap_index - zdos_bios_ap_start), %eax
        \\    and $-16, %esp
        \\    sub $12, %esp
        \\    push %eax
        \\    mov $zdos_bios_ap_main, %ecx
        \\    call *%ecx
        \\1:  hlt
        \\    jmp 1b
        \\.balign 4
        \\.global zdos_bios_ap_far32
        \\zdos_bios_ap_far32:
        \\    .long 0x9000 + (zdos_bios_ap_32 - zdos_bios_ap_start)
        \\    .word 0x08
        \\.balign 4
        \\.global zdos_bios_ap_gdtr
        \\zdos_bios_ap_gdtr:
        \\    .word 0
        \\    .long 0
        \\.balign 4
        \\.global zdos_bios_ap_idtr
        \\zdos_bios_ap_idtr:
        \\    .word 0
        \\    .long 0
        \\.balign 4
        \\.global zdos_bios_ap_stack
        \\zdos_bios_ap_stack:
        \\    .long 0
        \\.global zdos_bios_ap_index
        \\zdos_bios_ap_index:
        \\    .long 0
        \\.global zdos_bios_ap_end
        \\zdos_bios_ap_end:
    );
}

extern const zdos_bios_ap_start: u8;
extern const zdos_bios_ap_gdtr: u8;
extern const zdos_bios_ap_idtr: u8;
extern const zdos_bios_ap_stack: u8;
extern const zdos_bios_ap_index: u8;
extern const zdos_bios_ap_end: u8;

// A field of the copy at 0x9000, by its symbol in the original
fn field(comptime T: type, sym: *const u8) *align(1) T {
    const off = @intFromPtr(sym) - @intFromPtr(&zdos_bios_ap_start);
    return @ptrFromInt(stub_at + off);
}

fn installStub() void {
    const size = @intFromPtr(&zdos_bios_ap_end) - @intFromPtr(&zdos_bios_ap_start);
    const dst: [*]u8 = @ptrFromInt(stub_at);
    @memcpy(dst[0..size], @as([*]const u8, @ptrCast(&zdos_bios_ap_start))[0..size]);
    arch.storeGdtr(@ptrCast(field([6]u8, &zdos_bios_ap_gdtr)));
    arch.storeIdtr(@ptrCast(field([6]u8, &zdos_bios_ap_idtr)));
}
