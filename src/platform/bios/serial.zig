// COM1 as a serial console (drivers/serial/): the screen
// mirrored there and keys from it. SERIAL= of SYSTEM.CFG: on
// (default, where it answers), out (only the mirror), off.
// Polled until tasks run, then by IRQ 4 (kernel/serial.zig).
const std = @import("std");
const uart = @import("../../drivers/serial/uart16550.zig");
const Com = @import("../../drivers/serial/buffered.zig").Buffered(uart.Uart);
const switching = @import("switching.zig");

pub const Mode = enum { on, out, off };
pub var mode: Mode = .on;

var com: Com = undefined;
var present = false;

pub fn init() void {
    const u = uart.Uart.probe(0x3F8) orelse return;
    com = .{ .chip = u };
    present = true;
}

pub fn setMode(value: ?[]const u8) void {
    const v = std.mem.trim(u8, value orelse return, " \t\r");
    mode = if (std.ascii.eqlIgnoreCase(v, "off")) .off else if (std.ascii.eqlIgnoreCase(v, "out")) .out else .on;
}

pub fn put(c: u8) void {
    if (present and mode != .off) com.put(c);
}

// A received byte, if one is waiting
pub fn get() ?u8 {
    if (!present or mode != .on) return null;
    return com.get();
}

// IRQ 4 (level-triggered, masked during BIOS calls: switching.zig)
pub fn startInterrupts(wake: *const fn () void) bool {
    if (!present or mode == .off) return false;
    com.keys = mode == .on;
    com.startInterrupts(wake);
    if (!switching.addIrqHandler(4, &onIrq, null)) {
        com.toPolled();
        return false;
    }
    return true;
}

fn onIrq(_: ?*anyopaque) bool {
    return com.interrupt();
}

pub fn service() void {
    if (present) com.service();
}

pub fn setInputWake(f: *const fn () void) void {
    if (present) com.input_wake = f;
}

// A panic, or no task for it
pub fn toPolled() void {
    if (present) com.toPolled();
}
