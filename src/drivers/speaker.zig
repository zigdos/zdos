// The PC speaker: PIT channel 2 in mode 3 (square wave), or for
// a softer sound mode 2 (one clock's pulse a period), gated by
// port 0x61 bits 0-1. The BIOS clock borrows
// the channel while calibrating at startup.
const port = @import("../arch/x86_port.zig");

const pit_hz = 1_193_182;

pub fn available() bool {
    return true;
}

// hz 0: silence.
pub fn tone(hz: u32, soft: bool) void {
    const gate = port.inb(0x61);
    if (hz == 0) {
        port.outb(0x61, gate & 0xFC);
        return;
    }
    const divisor: u16 = @intCast(@min(pit_hz / hz, 0xFFFF));
    port.outb(0x43, if (soft) 0xB4 else 0xB6); // channel 2, lobyte/hibyte, mode 2 or 3
    port.outb(0x42, @truncate(divisor));
    port.outb(0x42, @truncate(divisor >> 8));
    port.outb(0x61, gate | 0x03);
}
