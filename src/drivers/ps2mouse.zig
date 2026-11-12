// PS/2 mouse on the controller's second port (IRQ12): irq()
// assembles packets and movement adds up until take(). A wheel
// mouse (ID 3) gets 4-byte packets. init() polls with IRQ12
// still off and enables it at the end: call it with interrupts
// off, before ps2kbd.init(). IRQ12 stays masked in the PIC, so
// the BIOS's handler can't take mouse bytes in BIOS calls;
// waitForInputIrq unmasks it only while readKey sleeps.
const port = @import("../arch/x86_port.zig");
const platform = @import("../platform.zig");

const data_port = 0x60;
const status_port = 0x64;
const status_output_full = 0x01;
const status_input_full = 0x02;
const status_from_mouse = 0x20;

const config_irq_mouse = 0x02; // configuration bit 1: IRQ12 on
const config_clock_off = 0x20; // configuration bit 5: second port's clock off


var present = false;
var packet_size: usize = 3;
var packet: [4]u8 = undefined;
var have: usize = 0; // bytes of the packet so far
var dx: i32 = 0;
var dy: i32 = 0;
var wheel: i32 = 0;
var buttons: u8 = 0;

// Returns the old flags.
// Clobbers in pre-0.14 syntax (0.15+: `.{ .memory = true }`).
fn saveAndDisable() u32 {
    return asm volatile (
        \\pushfl
        \\cli
        \\popl %[flags]
        : [flags] "=r" (-> u32),
        :
        : "memory"
    );
}

fn restore(flags: u32) void {
    if (flags & 0x200 != 0) asm volatile ("sti" ::: "memory");
}

fn waitWrite() bool {
    var n: u32 = 0;
    while (port.inb(status_port) & status_input_full != 0) : (n += 1) {
        if (n > 100_000) return false;
    }
    return true;
}

fn controller(cmd: u8) bool {
    if (!waitWrite()) return false;
    port.outb(status_port, cmd);
    return true;
}

fn writeData(byte: u8) bool {
    if (!waitWrite()) return false;
    port.outb(data_port, byte);
    return true;
}

// From the mouse (from_mouse) or the controller;
// null on timeout. Start-up only, before IRQ12 is on.
fn readFrom(from_mouse: bool) ?u8 {
    var n: u32 = 0;
    while (n < 200_000) : (n += 1) {
        const status = port.inb(status_port);
        if (status & status_output_full == 0) continue;
        const byte = port.inb(data_port);
        if ((status & status_from_mouse != 0) == from_mouse) return byte;
    }
    return null;
}

// True if the mouse acknowledged.
fn send(byte: u8) bool {
    if (!controller(0xD4) or !writeData(byte)) return false; // D4: next byte to the mouse
    return readFrom(true) == 0xFA;
}

fn updateConfig(set: u8, clear: u8) bool {
    if (!controller(0x20)) return false;
    const config = readFrom(false) orelse return false;
    return controller(0x60) and writeData((config & ~clear) | set);
}

// Without a mouse, take gives null.
pub fn init() void {
    if (!start()) switchOff();
}

// The output buffer holds one byte, the keyboard's too: a mouse
// on without a reader fills it, and the keyboard goes dead.
fn switchOff() void {
    present = false;
    _ = controller(0xA7); // the second port off
    _ = updateConfig(config_clock_off, config_irq_mouse);
    var n: u32 = 0;
    while (port.inb(status_port) & status_output_full != 0 and n < 32) : (n += 1) {
        _ = port.inb(data_port);
    }
}

fn start() bool {
    // The second port on, its clock
    // running, its interrupt still off:
    if (!controller(0xA8)) return false;
    if (!updateConfig(0, config_clock_off | config_irq_mouse)) return false;

    if (!send(0xF6)) return false; // defaults: 100 packets/s, 4 counts/mm, not sending
    // The IntelliMouse knock: rates 200,
    // 100, 80 make a wheel mouse answer ID 3:
    if (send(0xF3) and send(200) and send(0xF3) and send(100) and send(0xF3) and send(80) and send(0xF2)) {
        if (readFrom(true)) |id| {
            if (id == 3) packet_size = 4;
        }
    }
    if (!send(0xF4)) return false; // start sending

    have = 0;
    present = true;
    const flags = saveAndDisable();
    defer restore(flags);
    if (!updateConfig(config_irq_mouse, 0)) return false;
    drain(); // a packet byte that came in before the interrupt was on
    return true;
}

// Keyboard bytes are left for its handler.
fn drain() void {
    var n: u32 = 0;
    while (n < 16) : (n += 1) {
        const status = port.inb(status_port);
        if (status & status_output_full == 0) break;
        if (status & status_from_mouse == 0) break;
        feed(port.inb(data_port));
    }
}

// waitForInputIrq's entry sends the EOIs.
pub fn irq() callconv(.c) void {
    drain();
}

// Interrupt gates: never concurrent
// with itself or the keyboard's.
pub fn feed(byte: u8) void {
    if (!present) return;
    // A packet starts with bit 3 set: wait past anything else:
    if (have == 0 and byte & 0x08 == 0) return;
    packet[have] = byte;
    have += 1;
    if (have < packet_size) return;
    have = 0;

    const b0 = packet[0];
    buttons = b0 & 0x07; // left, right, middle
    if (b0 & 0xC0 == 0) { // no overflow
        const x = @as(i32, packet[1]) - (if (b0 & 0x10 != 0) @as(i32, 256) else 0);
        const y = @as(i32, packet[2]) - (if (b0 & 0x20 != 0) @as(i32, 256) else 0);
        dx +|= x; // adds up while nobody asks: saturating
        dy -|= y; // the mouse counts up, the screen down
    }
    // The wheel: positive when rolled toward the user:
    if (packet_size == 4) wheel +|= @as(i8, @bitCast(packet[3]));
}

// Null without a mouse. Interrupts are off meanwhile, so no
// packet is lost or half counted.
pub fn take() ?platform.Mouse {
    if (!present) return null;
    const flags = saveAndDisable();
    const m: platform.Mouse = .{ .dx = dx, .dy = dy, .wheel = wheel, .buttons = buttons };
    dx = 0;
    dy = 0;
    wheel = 0;
    restore(flags);
    return m;
}
