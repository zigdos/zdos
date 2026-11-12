// A core of its own for the network (kernel net.zig),
// as on metal: NETCPU='s, else the last, taken from
// the programs' jobs. It sleeps on its local APIC's timer
// between looks; core 0's requests and the cards' interrupts
// (taken on core 0) wake it (smp's wake IPI).
// News for core 0 wakes it the same way: its idle halt ends,
// and the switch after it takes the news.
const std = @import("std");
const platform = @import("../../platform.zig");
const arch = @import("../../arch/x86.zig");
const smp = @import("smp.zig");
const lapic = @import("lapic.zig");
const clock = @import("clock.zig");

var core: ?usize = null;
var entry = std.atomic.Value(?*const fn () noreturn).init(null);

pub fn claim(news: *const fn () void, want: ?usize) bool {
    _ = news;
    core = smp.dedicate(&waitForEntry, null, want) orelse return false;
    return true;
}

// Cards' wired interrupts reach core 0, which wakes this core:
pub const relays = true;

pub fn msiMessage() ?platform.MsiMessage {
    return null;
}

pub fn run(f: *const fn () noreturn) void {
    entry.store(f, .release);
    wake();
}

fn waitForEntry(_: ?*anyopaque) callconv(arch.cc) void {
    // A core index of its own for the scheduler's lock:
    // it may wake tasks itself
    @import("switching.zig").setCoreIndex(core.?);
    while (true) {
        if (entry.load(.acquire)) |f| f();
        sleep(1000);
    }
}

// On the network core: until woken, or about us
pub fn sleep(us: u32) void {
    if (!lapic.timerWorks()) return clock.delayUs(@min(us, 1000));
    lapic.oneShot(arch.wake_vector, us);
    asm volatile ("sti; hlt; cli" ::: "memory");
    lapic.stopOneShot();
}

pub fn wake() void {
    if (core) |c| smp.wakeCore(c);
}

// An IPI sent while core 0 runs (interrupts off) waits for its
// next halt, which then ends at once
pub fn tellMain() void {
    smp.wakeCore(0);
}
