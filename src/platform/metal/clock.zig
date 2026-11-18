// Clock: a millisecond counter from the CPU's timestamp
// (the TSC; on ARM64 the generic timer), calibrated against
// the firmware's Stall before leaving it;
// date and time from the firmware's runtime services,
// which keep working without its boot services
const std = @import("std");
const uefi = std.os.uefi;
const platform = @import("../../platform.zig");
const arch = @import("../../arch.zig");
const Counter = @import("../../arch/counter.zig").Counter;
const wallclock = @import("../wallclock.zig");
const cpu = @import("cpu.zig");

var tsc_start: u64 = 0;
var tsc_per_ms: u64 = 1;

// While the firmware's boot services are there
pub fn init() void {
    tsc_start = arch.timestamp();
    _ = uefi.system_table.boot_services.?.stall(10_000);
    tsc_per_ms = @max(1, (arch.timestamp() - tsc_start) / 10);
    startCounter();
}
// Nanoseconds since startup from the counter
// millis uses (ARM64: at the rate the generic
// timer states), and its step
var counter: Counter = .{};

fn startCounter() void {
    counter.start = tsc_start;
    const stated = if (@hasDecl(arch, "counterRate")) arch.counterRate() else null;
    counter.setRate(stated orelse tsc_per_ms * 1000);
}

pub fn nanos() u64 {
    return counter.nanos(arch.timestamp());
}

pub fn resolution() u64 {
    return counter.resolution();
}

// The counter's value (arch.timestamp) at nanos() == ns
pub fn timestampAt(ns: u64) u64 {
    return counter.ticksAt(ns);
}

// Counter ticks in ns nanoseconds (rounded up)
pub fn ticksIn(ns: u64) u64 {
    return counter.ticksAt(ns) -% counter.start + 1;
}

pub fn timestampRate() u64 {
    return tsc_per_ms * 1000;
}

pub fn millis() u64 {
    return (arch.timestamp() - tsc_start) / tsc_per_ms;
}

// Busy-waits us microseconds (the drivers' delays)
pub fn delayUs(us: u32) void {
    const start = arch.timestamp();
    const ticks = @as(u64, us) * tsc_per_ms / 1000;
    while (arch.timestamp() - start < ticks) std.atomic.spinLoopHint();
}

// The CPU sleeps (cpu.wait wakes it about every millisecond)
// while more than a millisecond is left, and
// only the last one is spun, to end on time
pub fn sleep(ms: u32) void {
    const until = millis() + ms;
    while (millis() + 1 < until) cpu.wait();
    while (millis() < until) std.atomic.spinLoopHint();
}

pub fn now() ?platform.DateTime {
    return wallclock.now(&firmwareNow, millis());
}

// UEFI's GetTime: slow (the clock chip's ports), so only now and then
fn firmwareNow() ?platform.DateTime {
    var t: uefi.Time = undefined;
    if (uefi.system_table.runtime_services.getTime(&t, null) != .success) return null;
    return .{ .year = t.year, .month = t.month, .day = t.day, .hour = t.hour, .minute = t.minute, .second = t.second };
}

pub fn set(dt: platform.DateTime) bool {
    defer wallclock.forget();
    const rs = uefi.system_table.runtime_services;
    // Start from the current record to keep
    // its time zone and daylight fields
    var t: uefi.Time = undefined;
    if (rs.getTime(&t, null) != .success) return false;
    t.year = dt.year;
    t.month = dt.month;
    t.day = dt.day;
    t.hour = dt.hour;
    t.minute = dt.minute;
    t.second = dt.second;
    t.nanosecond = 0;
    return rs.setTime(&t) == .success;
}
