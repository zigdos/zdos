// PS/2 keyboard and mouse on x86_64 PCs (8042 at ports 0x60 /
// 0x64): by IRQ 1 and 12 through the I/O APIC once interrupts
// start, else polled. Scan codes (translated to set 1) go to
// keyboard.zig. The interrupt reads the byte itself (a byte is
// cheaper than waking a task).
// The mouse gets a wheel (4-byte packets)
// after the IntelliMouse knock (rates 200, 100, 80).
const std = @import("std");
const builtin = @import("builtin");
const port = @import("../../arch/x86_port.zig");
const keyboard = @import("keyboard.zig");
const clock = @import("clock.zig");
const irq = @import("irq.zig");
const cpu_x86 = if (builtin.cpu.arch == .x86_64) @import("cpu_x86_64.zig") else struct {};
const Mod = @import("../../platform.zig").Mod;

const data_port = 0x60;
const status_port = 0x64;
const status_output_full = 0x01;
const status_input_full = 0x02;
const status_from_mouse = 0x20;

// PS2INPUT= of SYSTEM.CFG: auto (default) uses them if
// they answer, on uses them unasked, off leaves the
// controller alone. Only auto and on poll.
pub const Mode = enum { auto, on, off };
var mode: Mode = .auto;

var present = false;
var extended = false; // the last byte was the 0xE0 prefix
var skip: u8 = 0; // bytes left of a Pause key sequence
var leds_shown: ?u8 = null; // what the keyboard's lights show; null: not set yet

var mouse_present = false;
var mouse_wheel = false; // 4-byte packets
var packet: [4]u8 = undefined;
var packet_len: usize = 0;

// Interrupts on: the bytes are the handler's
var irq_on = false;
// The controller's: the handler's, or a command's while it waits
// for the answer (the handler leaves the bytes then)
var owner = std.atomic.Value(bool).init(false);

// Whether the controller must be polled (no interrupt)
pub fn polled() bool {
    return present and !irq_on;
}

// Once interrupts start (metal.zig): the configuration byte's
// bit 0 the keyboard's interrupt, bit 1 the mouse's
pub fn startInterrupts() void {
    if (builtin.cpu.arch != .x86_64 or !present) return;
    const vector = irq.allocVector(&onIrq, null) orelse return;
    lock();
    const config = if (command(0x20)) read() else null;
    const bits: u8 = 0x01 | (if (mouse_present) @as(u8, 0x02) else 0);
    const ok = config != null and command(0x60) and write(config.? | bits);
    if (ok and cpu_x86.routeIsa(1, vector) and (!mouse_present or cpu_x86.routeIsa(12, vector))) irq_on = true;
    unlock();
}

// IRQ 1 or 12 (interrupts off): the bytes waiting, unless a
// command owns the controller (unlock takes them then)
fn onIrq(_: ?*anyopaque) void {
    if (owner.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
    drain(16);
    owner.store(false, .release);
}

fn lock() void {
    while (owner.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

// Bytes that came while it was owned found it taken: their
// interrupt is spent, so they are read here
fn unlock() void {
    while (true) {
        if (irq_on) drain(64);
        owner.store(false, .release);
        if (!irq_on or port.inb(status_port) & status_output_full == 0) return;
        if (owner.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return; // the handler has it
    }
}

// Up to max waiting bytes to the keyboard or mouse
fn drain(max: usize) void {
    var n: usize = 0;
    while (n < max) : (n += 1) {
        const status = port.inb(status_port);
        if (status & status_output_full == 0) return;
        const byte = port.inb(data_port);
        if (status & status_from_mouse != 0) mouseByte(byte) else decode(byte);
    }
}

// PS2INPUT= (on, off; anything else: auto),
// read before leaving the firmware
pub fn setMode(value: ?[]const u8) void {
    const v = std.mem.trim(u8, value orelse return, " \t\r");
    mode = if (std.ascii.eqlIgnoreCase(v, "on")) .on else if (std.ascii.eqlIgnoreCase(v, "off")) .off else .auto;
}

// After leaving the firmware (x86_64 only): the
// controller with scan code translation on (set 1).
// auto: not found (no answer), it stays off, unpolled.
pub fn init() void {
    if (builtin.cpu.arch != .x86_64 or mode == .off) return;
    const auto = mode == .auto;
    // No controller: the ports read as 0xFF
    if (auto and port.inb(status_port) == 0xFF) return;
    var n: usize = 0;
    while (port.inb(status_port) & status_output_full != 0 and n < 64) : (n += 1) _ = port.inb(data_port);
    // Configuration byte: bit 6 translation, bit 4 keyboard clock off.
    // on and unreadable: 0x44 (translation, POST passed, no IRQs).
    const got: ?u8 = if (command(0x20)) read() else null;
    if (auto and got == null) return;
    const config = got orelse 0x44;
    const wanted = (config | 0x40) & ~@as(u8, 0x10);
    if (wanted != config or got == null) {
        if ((!command(0x60) or !write(wanted)) and auto) return;
    }
    _ = command(0xAE); // the keyboard port on
    present = true;
    updateLeds(); // the lock keys start off: so do the lights
    initMouse(wanted, auto);
}

pub fn hasMouse() bool {
    return mouse_present;
}

// The second port on, then the mouse: defaults,
// the wheel if it has one, reporting on. config:
// the configuration byte as set above. auto: no
// answer, no mouse (not polled).
fn initMouse(config: u8, auto: bool) void {
    _ = command(0xA8); // the second port on
    // Its clock on (bit 5 off), its interrupt off (bit 1): polled
    if ((!command(0x60) or !write(config & ~@as(u8, 0x22))) and auto) return;
    // Defaults: also tells that a mouse answers
    if (!mouseSend(0xF6) and auto) return;
    for ([_]u8{ 200, 100, 80 }) |rate| {
        if (!mouseSend(0xF3) or !mouseSend(rate)) break;
    }
    if (mouseSend(0xF2)) { // its ID: 3 has a wheel
        if (readFrom(true)) |id| mouse_wheel = id == 3;
    }
    if (!mouseSend(0xF4) and auto) return; // reporting on
    packet_len = 0;
    mouse_present = true;
}

// A byte to the mouse (controller command 0xD4 first), then its ACK
fn mouseSend(byte: u8) bool {
    if (!command(0xD4) or !write(byte)) return false;
    return readFrom(true) == 0xFA;
}

// The next byte from the mouse (true) or the
// keyboard within 50 ms; bytes of the other one are
// handled as they come
fn readFrom(from_mouse: bool) ?u8 {
    const until = clock.millis() + 50;
    while (clock.millis() < until) {
        const status = port.inb(status_port);
        if (status & status_output_full == 0) continue;
        const b = port.inb(data_port);
        const is_mouse = status & status_from_mouse != 0;
        if (is_mouse == from_mouse) return b;
        if (is_mouse) mouseByte(b) else decode(b);
    }
    return null;
}

// A packet's bytes: 1 the buttons (bit 3 always set) and the
// movements' sign and overflow bits, 2 x, 3 y (up is positive:
// ZDOS's down is), 4 the wheel (signed)
fn mouseByte(b: u8) void {
    if (!mouse_present) return;
    // Out of step: a first byte has bit 3 set
    if (packet_len == 0 and b & 0x08 == 0) return;
    packet[packet_len] = b;
    packet_len += 1;
    if (packet_len < @as(usize, if (mouse_wheel) 4 else 3)) return;
    packet_len = 0;
    const flags = packet[0];
    var dx: i32 = 0;
    var dy: i32 = 0;
    if (flags & 0xC0 == 0) { // no overflow (else the movement is unreliable)
        dx = @as(i32, packet[1]) - (if (flags & 0x10 != 0) @as(i32, 256) else 0);
        dy = @as(i32, packet[2]) - (if (flags & 0x20 != 0) @as(i32, 256) else 0);
    }
    // The wheel: positive when rolled toward the user
    const wheel: i32 = if (mouse_wheel) @as(i8, @bitCast(packet[3])) else 0;
    keyboard.feedMouse(dx, -dy, wheel, flags & 0x07);
}

pub fn poll() void {
    if (!present) return;
    if (irq_on) {
        // The bytes come by interrupt; the lights from here
        // (their answers take milliseconds)
        lock();
        updateLeds();
        unlock();
        return;
    }
    // At most 64 bytes a call: a PC without the
    // controller reads as a stream of 0xFF
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        const status = port.inb(status_port);
        if (status & status_output_full == 0) return;
        const byte = port.inb(data_port);
        if (status & status_from_mouse != 0) {
            mouseByte(byte);
            continue;
        }
        decode(byte);
        updateLeds();
    }
}

// The lights as keyboard.zig's lock keys say (a lock key on
// any keyboard counts): command 0xED, then the light bits
fn updateLeds() void {
    const locks = keyboard.lockState();
    var leds: u8 = 0;
    if (locks & Mod.scroll_lock != 0) leds |= 1;
    if (locks & Mod.num_lock != 0) leds |= 2;
    if (locks & Mod.caps_lock != 0) leds |= 4;
    if (leds_shown != null and leds_shown.? == leds) return;
    leds_shown = leds;
    if (!send(0xED)) return;
    _ = send(leds);
}

// A byte to the keyboard, then its answer: ACK (0xFA) true,
// resend (0xFE) or none within 50 ms false. Keys typed
// meanwhile are decoded as usual.
fn send(byte: u8) bool {
    if (!waitInput()) return false;
    port.outb(data_port, byte);
    const until = clock.millis() + 50;
    while (clock.millis() < until) {
        const status = port.inb(status_port);
        if (status & status_output_full == 0) continue;
        const b = port.inb(data_port);
        if (status & status_from_mouse != 0) {
            mouseByte(b);
            continue;
        }
        if (b == 0xFA) return true;
        if (b == 0xFE) return false;
        decode(b);
    }
    return false;
}

fn decode(byte: u8) void {
    if (skip > 0) {
        skip -= 1;
        return;
    }
    switch (byte) {
        0xE1 => { // Pause: E1 1D 45 E1 9D C5, press and release at once
            skip = 5;
            keyboard.feed(keyboard.pause, true);
            keyboard.feed(keyboard.pause, false);
            return;
        },
        0xE0 => {
            extended = true;
            return;
        },
        // Replies to commands (ACK, resend, echo) and error codes
        0xFA, 0xFE, 0xEE, 0x00, 0xFF => {
            extended = false;
            return;
        },
        else => {},
    }
    const ext = extended;
    extended = false;
    const code = byte & 0x7F;
    // E0 2A / E0 36: "fake" Shift sent around some keys
    if (ext and (code == 0x2A or code == 0x36)) return;
    keyboard.feed(@as(u16, if (ext) 0xE000 else 0) | code, byte & 0x80 == 0);
}

// A controller command (port 0x64);
// false if the controller doesn't take it
fn command(c: u8) bool {
    if (!waitInput()) return false;
    port.outb(status_port, c);
    return true;
}

fn write(b: u8) bool {
    if (!waitInput()) return false;
    port.outb(data_port, b);
    return true;
}

fn read() ?u8 {
    var n: u32 = 0;
    while (n < 100_000) : (n += 1) {
        if (port.inb(status_port) & status_output_full != 0) return port.inb(data_port);
    }
    return null;
}

fn waitInput() bool {
    var n: u32 = 0;
    while (n < 100_000) : (n += 1) {
        if (port.inb(status_port) & status_input_full == 0) return true;
    }
    return false;
}
