// A core of its own for the network (kernel net.zig):
// NETCPU='s, else the last, taken from the programs' jobs.
// x86_64: the card's interrupt, core 0's requests and a
// one-shot timer wake it (smp's wake vector),
// and it tells core 0 of news by an IPI;
// ARM64: core 0's requests wake it by an SGI; the cards'
// interrupts by a GICv2m SPI targeted at it, else taken on core
// 0 and relayed by an SGI; else its timer. Core 0 learns news
// at its tick.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../../platform.zig");
const smp = @import("smp.zig");
const irq = @import("irq.zig");
const gic = if (x86) struct {} else @import("gic.zig");
const x86 = builtin.cpu.arch == .x86_64;
const cpu = if (x86) @import("cpu_x86_64.zig") else @import("cpu_arm64.zig");
const smp_x86 = if (x86) @import("smp_x86_64.zig") else struct {};

var core: ?usize = null;
var entry = std.atomic.Value(?*const fn () noreturn).init(null);
var main_apic: u32 = 0;
var news_vector: ?u8 = null;
var news_fn: ?*const fn () void = null;

// Takes the core (it waits for run); false with a single core.
// The card's interrupt message for it: msiMessage.
pub fn claim(news: *const fn () void, want: ?usize) bool {
    core = smp.dedicate(&waitForEntry, null, want) orelse return false;
    news_fn = news;
    if (x86) {
        main_apic = cpu.apicId();
        if (irq.allocMsi(0, &onNews, null)) |m| news_vector = @intCast(m.data);
    }
    return true;
}

fn onNews(_: ?*anyopaque) void {
    if (news_fn) |f| f();
}

// ARM64 without a GICv2m frame (an ITS): the cards' interrupts
// go to core 0, which wakes the network core
pub const relays = !x86;

// The card's interrupt to the network core (as its wake-up):
// x86_64 its wake vector, ARM64 one SPI for every card
var arm_message: ?platform.MsiMessage = null;

pub fn msiMessage() ?platform.MsiMessage {
    const c = core orelse return null;
    if (!x86) {
        if (arm_message == null) {
            const m = gic.messageFor(c) orelse return null;
            arm_message = .{ .address = m.address, .data = m.data };
        }
        return arm_message;
    }
    const apic = smp.cores[c].hw_id;
    if (apic > 255) return null;
    return .{ .address = 0xFEE0_0000 | (apic << 12), .data = smp_x86.wake_vector };
}

// The network core's number (null: none)
pub fn coreIndex() ?usize {
    return core;
}

pub fn run(f: *const fn () noreturn) void {
    entry.store(f, .release);
    wake();
}

fn waitForEntry(_: ?*anyopaque) callconv(@import("../../arch.zig").cc) void {
    // A core index for the scheduler's lock: it wakes tasks itself
    @import("switching.zig").setCoreIndex(core.?);
    while (true) {
        if (entry.load(.acquire)) |f| f();
        sleep(1000);
    }
}

// On the network core: until woken, or about us
pub fn sleep(us: u32) void {
    if (x86) {
        cpu.oneShot(smp_x86.wake_vector, us);
        asm volatile ("sti; hlt; cli" ::: "memory");
        cpu.stopOneShot();
    } else {
        cpu.sleepOtherCore(smp.cores[core.?].sleeps_on_timer, us);
    }
}

// From core 0: the network core has work
pub fn wake() void {
    if (core) |c| smp.wakeCore(c);
}

// From the network core: news for core 0 (x86_64:
// an interrupt there; ARM64: its timer tick looks)
pub fn tellMain() void {
    if (!x86) return;
    if (news_vector) |v| cpu.sendIpi(main_apic, v);
}
