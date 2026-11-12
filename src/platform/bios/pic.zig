// The two 8259 PICs and the PIT, as ZDOS runs with them:
// IRQs on 0x20-0x2F (the BIOS's IRQ0 vector 8 is the double
// fault in protected mode), a 1 kHz tick until the scheduler
// runs, then one-shot deadlines (armOneShot), and the
// keyboard's and mouse's IRQs; and back as the BIOS set them
// (0x08 / 0x70, 18.2 Hz, keyboard and mouse masked so it can't
// take their bytes) for BIOS calls, which count on its tick
// (floppy motor, timeouts).
const port = @import("../../arch/x86_port.zig");
const arch = @import("../../arch/x86.zig");
const kbd = @import("../../drivers/ps2kbd.zig");
const mouse = @import("../../drivers/ps2mouse.zig");

var active = false; // ZDOS's setup is in place (from init on)
var one_shot = false; // the scheduler arms the PIT (armOneShot)
var lapic_timer = false; // the local APIC's timer instead: IRQ0 masked in ZDOS
// PCI cards' lines (unmaskDevice): off during BIOS calls, whose
// handlers would only EOI a line the card keeps raised
var device_lines: u16 = 0;

pub fn init() void {
    arch.setInputIrqs(&kbd.irq1, &mouse.irq);
    active = true;
    toZdos();
}

pub fn toZdos() void {
    if (!active) return;
    remap(arch.irq_base, arch.irq_base + 8);
    // After a BIOS call: a deadline the scheduler then sets again
    if (!lapic_timer) {
        if (one_shot) pitOnce(pit_hz / 1000) else pit(1193); // 1193182 Hz / 1193: 1 kHz
    }
    // The tick (the PIT's, unless the local APIC's), the keyboard,
    // the cascade and the mouse on
    port.outb(0x21, (port.inb(0x21) & ~@as(u8, 0x07)) | @as(u8, if (lapic_timer) 0x01 else 0));
    port.outb(0xA1, port.inb(0xA1) & ~@as(u8, 0x10));
    port.outb(0x21, port.inb(0x21) & ~@as(u8, @truncate(device_lines)));
    port.outb(0xA1, port.inb(0xA1) & ~@as(u8, @truncate(device_lines >> 8)));
}

pub fn toBios() void {
    if (!active) return;
    port.outb(0x21, port.inb(0x21) | 0x02 | @as(u8, @truncate(device_lines)));
    port.outb(0xA1, port.inb(0xA1) | 0x10 | @as(u8, @truncate(device_lines >> 8)));
    remap(0x08, 0x70);
    pit(0); // 65536: 18.2 Hz
    if (lapic_timer) port.outb(0x21, port.inb(0x21) & ~@as(u8, 0x01)); // the BIOS's tick
}

// ICW1-4 (initialization clears the masks: kept)
fn remap(master: u8, slave: u8) void {
    const m1 = port.inb(0x21);
    const m2 = port.inb(0xA1);
    port.outb(0x20, 0x11);
    port.outb(0xA0, 0x11);
    port.outb(0x21, master);
    port.outb(0xA1, slave);
    port.outb(0x21, 0x04); // the slave on IRQ 2
    port.outb(0xA1, 0x02);
    port.outb(0x21, 0x01); // 8086 mode
    port.outb(0xA1, 0x01);
    port.outb(0x21, m1);
    port.outb(0xA1, m2);
}

// An IRQ on for good (a device ZDOS drives: the IDE channels).
// BIOS calls leave it so: the BIOS's
// own handler takes it meanwhile.
pub fn unmask(irq: u4) void {
    if (irq < 8) {
        port.outb(0x21, port.inb(0x21) & ~(@as(u8, 1) << @intCast(irq)));
    } else {
        port.outb(0xA1, port.inb(0xA1) & ~(@as(u8, 1) << @intCast(irq - 8)));
        port.outb(0x21, port.inb(0x21) & ~@as(u8, 0x04)); // the cascade
    }
}

// A PCI card's line, on in ZDOS only. PCI lines stay raised
// while a cause is pending: level-triggered in the ELCR (ports
// 0x4D0 / 0x4D1), else a cause arriving during the handler
// raises no new edge and is lost.
pub fn unmaskDevice(irq: u4) void {
    device_lines |= @as(u16, 1) << irq;
    const elcr: u16 = if (irq < 8) 0x4D0 else 0x4D1;
    port.outb(elcr, port.inb(elcr) | (@as(u8, 1) << @intCast(irq & 7)));
    unmask(irq);
}

const pit_hz = 1193182;

// From now on the scheduler's deadlines drive the PIT (switching.zig)
pub fn startOneShot() void {
    one_shot = true;
}

// The local APIC's timer drives them instead:
// IRQ0 masked while ZDOS runs
pub fn useLapicTimer() void {
    lapic_timer = true;
    port.outb(0x21, port.inb(0x21) | 0x01);
}

// IRQ0 at nanos() == at (past: at once; null or beyond 55 ms:
// in 55 ms, when the scheduler arms it again)
pub fn armOneShot(at: ?u64) void {
    const ns = at orelse return pitOnce(0xFFFF);
    const now = @import("clock.zig").nanos();
    const left: u64 = if (ns > now) @min(ns - now, 100_000_000) else 0;
    const counts = (left * pit_hz + 999_999_999) / 1_000_000_000;
    pitOnce(@intCast(@max(1, @min(counts, 0xFFFF))));
}

// Channel 0, interrupt on terminal
// count (mode 0): one IRQ0 after `count`
fn pitOnce(count: u16) void {
    port.outb(0x43, 0x30);
    port.outb(0x40, @truncate(count));
    port.outb(0x40, @truncate(count >> 8));
}

// Channel 0, rate generator (mode 2); 0 means 65536
fn pit(divisor: u16) void {
    port.outb(0x43, 0x34);
    port.outb(0x40, @truncate(divisor));
    port.outb(0x40, @truncate(divisor >> 8));
}
