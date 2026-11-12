// A 16550 UART at I/O ports: the PC's COM1-4 (x86: BIOS,
// metal). Polled, or its interrupt through buffered.zig.
const std = @import("std");
const port = @import("../../arch/x86_port.zig");

// REGISTERS
const data = 0; // transmit / receive
const ier = 1; // interrupt enable: bit 0 received, bit 1 room to send
const iir = 2; // interrupt identification (read) / FIFO control (write)
const lcr = 3; // line control: bit 7 DLAB, the divisor follows
const mcr = 4; // modem control: DTR, RTS, OUT2
const lsr = 5; // line status: bit 0 data ready, bit 5 room to send
const scratch = 7;

// MCR: DTR, RTS; OUT2 gates the IRQ line on PCs
const mcr_lines = 0x03;
const mcr_out2 = 0x08;

pub const Uart = struct {
    base: u16,

    pub const fifo_size = 16;

    // One answering at base (its scratch register keeps what
    // is written): 115200 baud, 8 bits, no parity, 1 stop bit,
    // FIFOs on, interrupts off
    pub fn probe(base: u16) ?Uart {
        for ([_]u8{ 0x5A, 0xA5 }) |v| {
            port.outb(base + scratch, v);
            if (port.inb(base + scratch) != v) return null;
        }
        port.outb(base + ier, 0x00);
        port.outb(base + lcr, 0x80);
        port.outb(base + data, 0x01); // divisor 1: 115200 baud
        port.outb(base + ier, 0x00);
        port.outb(base + lcr, 0x03);
        port.outb(base + iir, 0xC7); // FIFOs on and cleared
        port.outb(base + mcr, mcr_lines);
        return .{ .base = base };
    }

    pub fn canSend(u: Uart) bool {
        return port.inb(u.base + lsr) & 0x20 != 0;
    }

    pub fn send(u: Uart, c: u8) void {
        port.outb(u.base + data, c);
    }

    pub fn putPolled(u: Uart, c: u8) void {
        while (!u.canSend()) std.atomic.spinLoopHint();
        u.send(c);
    }

    // A received byte, if one is waiting
    pub fn received(u: Uart) ?u8 {
        if (port.inb(u.base + lsr) & 0x01 == 0) return null;
        return port.inb(u.base + data);
    }

    // OUT2 on for good: the UART drives its line (low while
    // nothing is pending), a gated one could float
    pub fn connectLine(u: Uart) void {
        port.outb(u.base + mcr, mcr_lines | mcr_out2);
    }

    // Enabling "room to send" while the FIFO is empty raises the
    // interrupt at once
    pub fn setInterrupts(u: Uart, rx: bool, tx: bool) void {
        port.outb(u.base + ier, @as(u8, @intFromBool(rx)) | @as(u8, @intFromBool(tx)) << 1);
    }

    // Whether it raises its interrupt now
    pub fn pending(u: Uart) bool {
        return port.inb(u.base + iir) & 0x01 == 0;
    }
};
