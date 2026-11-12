// The serial port, from ACPI's SPCR: a PL011 or a 16550 at I/O
// ports or in memory (Raspberry Pi mini UART: registers 4 bytes
// apart), left as the firmware set it up. Without SPCR: COM1 on
// x86_64 if it answers. The I/O-port 16550 works by its
// interrupt once tasks run (drivers/serial/buffered.zig), the
// others are polled.
const std = @import("std");
const builtin = @import("builtin");
const acpi = @import("acpi.zig");
const mmio = @import("../../arch/mmio.zig");
const irq = @import("irq.zig");
const cpu_x86 = if (builtin.cpu.arch == .x86_64) @import("cpu_x86_64.zig") else struct {};
const uart = @import("../../drivers/serial/uart16550.zig");

// I/O ports exist on x86_64 only
const has_ports = builtin.cpu.arch == .x86_64;
const Com = @import("../../drivers/serial/buffered.zig").Buffered(uart.Uart);
var com: if (has_ports) Com else void = undefined;

const Kind = enum { none, io16550, mmio16550, pl011 };

var kind: Kind = .none;
var base: usize = 0; // memory address
var stride: usize = 1; // bytes between a memory-mapped 16550's registers

// 16550 registers
const thr = 0; // transmit / receive
const lsr = 5; // line status: bit 0 data ready, bit 5 transmitter empty

// SERIAL= of SYSTEM.CFG: on (output and keys), out (output
// only, no key polling) or off (unused)
pub const Mode = enum { on, out, off };
pub var mode: Mode = .on;

pub fn setMode(value: ?[]const u8) void {
    const v = std.mem.trim(u8, value orelse return, " \t\r");
    mode = if (std.ascii.eqlIgnoreCase(v, "off")) .off else if (std.ascii.eqlIgnoreCase(v, "out")) .out else .on;
}

// Whether keys come from it
pub fn input() bool {
    return kind != .none and mode == .on;
}

// Whether the console must look for them (no interrupt)
pub fn polled() bool {
    return input() and !(has_ports and kind == .io16550 and com.irq);
}

// After acpi.capture
pub fn init() void {
    if (fromSpcr()) return;
    switch (builtin.cpu.arch) {
        .x86_64 => probeCom1(),
        else => {},
    }
}

fn probeCom1() void {
    if (!has_ports) return;
    const u = uart.Uart.probe(0x3F8) orelse return;
    com = .{ .chip = u };
    kind = .io16550;
}

// SPCR: interface type at 36, the base address (a Generic
// Address Structure) at 40: address space, bit width, bit
// offset, access size, address
fn fromSpcr() bool {
    const t = acpi.find("SPCR") orelse return false;
    if (t.len < 52) return false;
    const space = t[40];
    const bit_width = t[41];
    const access_size = t[43];
    const address = std.mem.readInt(u64, t[44..52], .little);
    if (address == 0) return false;
    kind = switch (t[36]) {
        0x03, 0x0D, 0x0E => .pl011, // ARM PL011, ARM SBSA UARTs (a PL011 subset)
        0x00, 0x01, 0x10, 0x12 => switch (space) { // 16550 kinds, BCM2835 mini UART
            0 => .mmio16550,
            1 => if (has_ports) .io16550 else return false,
            else => return false,
        },
        else => return false,
    };
    if (kind == .pl011 and space != 0) {
        kind = .none;
        return false;
    }
    if (kind == .io16550) {
        if (has_ports) com = .{ .chip = .{ .base = @intCast(address) } };
        return true;
    }
    base = @intCast(address);
    stride = if (access_size == 3 or bit_width == 32) 4 else 1;
    return true;
}

// INTERRUPTS (kernel/serial.zig): COM1's IRQ 4 through the
// I/O APIC; its task's wake and work

pub fn startInterrupts(wake: *const fn () void) bool {
    if (!has_ports or kind != .io16550 or mode == .off) return false;
    const vector = irq.allocVector(&onIrq, null) orelse return false;
    com.keys = mode == .on;
    com.startInterrupts(wake);
    if (!cpu_x86.routeIsa(4, vector)) {
        com.irq = false; // polled, as before
        return false;
    }
    return true;
}

fn onIrq(_: ?*anyopaque) void {
    if (has_ports) _ = com.interrupt();
}

pub fn service() void {
    if (has_ports and kind == .io16550) com.service();
}

pub fn setInputWake(f: *const fn () void) void {
    if (has_ports) com.input_wake = f;
}

// A panic, or no task for it
pub fn toPolled() void {
    if (has_ports and kind == .io16550) com.toPolled();
}

pub fn put(c: u8) void {
    if (mode == .off) return;
    switch (kind) {
        .none => {},
        .io16550 => if (has_ports) com.put(c),
        .mmio16550 => {
            while (memIn(lsr) & 0x20 == 0) {}
            memOut(thr, c);
        },
        .pl011 => {
            while (mmio.read32(base + 0x18) & 0x20 != 0) {} // FR.TXFF: the FIFO is full
            mmio.write32(base, c);
        },
    }
}

// A received byte, if one is waiting
pub fn get() ?u8 {
    if (mode != .on) return null;
    switch (kind) {
        .none => return null,
        .io16550 => return if (has_ports) com.get() else null,
        .mmio16550 => {
            if (memIn(lsr) & 0x01 == 0) return null;
            return memIn(thr);
        },
        .pl011 => {
            if (mmio.read32(base + 0x18) & 0x10 != 0) return null; // FR.RXFE: nothing received
            return @truncate(mmio.read32(base));
        },
    }
}

// A 16550 register in memory: 32-bit accesses
// where they are 4 bytes apart, else bytes
fn memIn(reg: usize) u8 {
    const at = base + reg * stride;
    return if (stride == 4) @truncate(mmio.read32(at)) else @as(*volatile u8, @ptrFromInt(at)).*;
}

fn memOut(reg: usize, value: u8) void {
    const at = base + reg * stride;
    if (stride == 4) mmio.write32(at, value) else @as(*volatile u8, @ptrFromInt(at)).* = value;
}
