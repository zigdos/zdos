// Clock: date and time from the CMOS RTC; milliseconds from the
// TSC, calibrated once against the PIT
const platform = @import("../../platform.zig");
const arch = @import("../../arch.zig");
const Counter = @import("../../arch/counter.zig").Counter;
const port = @import("../../arch/x86_port.zig");
const cmos = @import("../../drivers/cmos.zig");
const acpi = @import("acpi.zig");
const wallclock = @import("../wallclock.zig");

var tsc_start: u64 = 0;
var tsc_per_ms: u64 = 1;

pub fn init() void {
    tsc_start = arch.timestamp();
    tsc_per_ms = @max(1, measureTsc());
    startCounter();
    cmos.century_reg = acpi.centuryRegister() orelse 0;
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

// TSC ticks during 10 ms of PIT channel 2 (speaker gated off);
// the PIT runs at 1.193182 MHz on every PC
fn measureTsc() u64 {
    const pit_hz = 1193182;
    const ticks: u16 = pit_hz / 100; // 10 ms
    const gate = port.inb(0x61);
    port.outb(0x61, (gate & 0xFC) | 0x01); // channel 2 gate on, speaker off
    port.outb(0x43, 0xB0); // channel 2, lobyte/hibyte, mode 0 (count down once)
    port.outb(0x42, @truncate(ticks));
    port.outb(0x42, @truncate(ticks >> 8));
    // Restarting the gate starts the count
    const g = port.inb(0x61);
    port.outb(0x61, g & 0xFE);
    port.outb(0x61, g | 0x01);
    const start = arch.timestamp();
    var spins: u32 = 0;
    // Bit 5 of port 0x61 follows channel 2's output, which goes high at 0
    while (port.inb(0x61) & 0x20 == 0) : (spins += 1) {
        if (spins > 10_000_000) break; // no PIT (should not happen): guess below
    }
    const elapsed = arch.timestamp() - start;
    port.outb(0x61, gate);
    if (spins > 10_000_000) return 200_000; // as if 200 MHz
    return elapsed / 10;
}

pub fn timestampRate() u64 {
    return tsc_per_ms * 1000;
}

pub fn millis() u64 {
    return (arch.timestamp() - tsc_start) / tsc_per_ms;
}

pub fn delayUs(us: u32) void {
    const start = arch.timestamp();
    const ticks = @as(u64, us) * tsc_per_ms / 1000;
    while (arch.timestamp() - start < ticks) asm volatile ("pause");
}

pub fn sleep(ms: u32) void {
    const end = millis() + ms;
    while (millis() < end) {}
}

pub fn now() ?platform.DateTime {
    return wallclock.now(&cmos.now, millis());
}

pub fn set(dt: platform.DateTime) bool {
    defer wallclock.forget();
    return cmos.set(dt);
}
