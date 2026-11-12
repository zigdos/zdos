//! USB HID boot-protocol keyboard:
//! reports to PC scancodes, LEDs.

const std = @import("std");
const xhci = @import("xhci.zig");

pub const Modifiers = packed struct(u8) {
    ctrl_left: u1 = 0,
    shift_left: u1 = 0,
    alt_left: u1 = 0,
    gui_left: u1 = 0,
    ctrl_right: u1 = 0,
    shift_right: u1 = 0,
    alt_right: u1 = 0,
    gui_right: u1 = 0,
};

pub const KeyboardBootReport = extern struct {
    mods: Modifiers = .{},
    reserved: u8 = 0,
    keycodes: [6]u8 = [_]u8{0} ** 6,
};

pub const InterfaceDescriptor = extern struct {
    length: u8,
    descriptor_type: u8,
    interface_number: u8,
    alternate_setting: u8,
    num_endpoints: u8,
    interface_class: u8,
    interface_subclass: u8,
    interface_protocol: u8,
    interface_idx: u8,
};

pub const ZdosKeyEvent = struct {
    code: u16,
    pressed: bool,
    repeat: bool = false,
    mods: u16 = 0,
};

/// Reports requested at once: the controller writes each into
/// its own buffer while ZDOS is busy, so a device that queues
/// its events (QEMU's keeps 16, then drops new ones, a key's
/// release too) is emptied as they come.
pub const InFlight = 16;

pub const UsbKeyboardDriver = struct {
    slot_id: u8,
    /// xHCI device context index of the
    /// interrupt IN endpoint (ep_number * 2 + 1).
    input_endpoint_id: u8 = 0,
    max_packet_size: u16 = 8,
    interface_number: u8 = 0,

    /// The lights shown (bit 0 Num, 1 Caps,
    /// 2 Scroll Lock); null: not set yet
    leds_shown: ?u8 = null,

    prev_report: KeyboardBootReport = .{},

    /// DMA targets for interrupt reports, used in turn (a ring
    /// finishes its transfers in order). Boot reports are 8 bytes;
    /// the buffers are larger so an endpoint whose wMaxPacketSize
    /// exceeds 8 cannot overflow them.
    buffers: [InFlight][64]u8 align(16) = [_][64]u8{[_]u8{0} ** 64} ** InFlight,
    next_queued: usize = 0, // the buffer the next transfer goes into
    next_done: usize = 0, // the buffer the next completion filled
    led_state_buffer: [16]u8 align(16) = [_]u8{0} ** 16,

    on_key_event: ?*const fn (event: ZdosKeyEvent) void = null,

    pub fn init(slot_id: u8) UsbKeyboardDriver {
        return .{
            .slot_id = slot_id,
        };
    }

    /// Accepts the first interrupt IN endpoint
    /// of a boot-protocol keyboard interface.
    pub fn parseInterface(self: *UsbKeyboardDriver, interface: InterfaceDescriptor, endpoint_address: u8, max_packet: u16) bool {
        if (interface.interface_class == 3 and interface.interface_subclass == 1 and interface.interface_protocol == 1) {
            const is_in = (endpoint_address & 0x80) != 0;
            if (!is_in) return false;
            self.max_packet_size = max_packet;
            self.interface_number = interface.interface_number;
            self.input_endpoint_id = ((endpoint_address & 0x0F) * 2) + 1;
            return true;
        }
        return false;
    }

    /// Queues one transfer into the next buffer in turn
    pub fn queueInterruptTransfer(self: *UsbKeyboardDriver, xhci_driver: anytype) !void {
        const buf = &self.buffers[self.next_queued];
        @memset(buf, 0);
        const phys_addr = xhci.virtToPhys(@intFromPtr(buf));
        const len: u16 = @min(self.max_packet_size, @as(u16, buf.len));
        try xhci_driver.submitInterruptTransfer(self.slot_id, self.input_endpoint_id, phys_addr, len);
        self.next_queued = (self.next_queued + 1) % InFlight;
    }

    /// At the start, and after an error left
    /// the endpoint empty: every buffer queued
    pub fn queueAll(self: *UsbKeyboardDriver, xhci_driver: anytype) !void {
        self.next_queued = 0;
        self.next_done = 0;
        for (0..InFlight) |_| try self.queueInterruptTransfer(xhci_driver);
    }

    /// The lights as the lock keys are (ZDOS Mod bits: caps 0x1000,
    /// num 0x2000, scroll 0x4000), sent only when they changed
    pub fn setLedState(self: *UsbKeyboardDriver, xhci_driver: anytype, locks: u16) !void {
        var leds: u8 = 0;
        if (locks & 0x2000 != 0) leds |= 1 << 0;
        if (locks & 0x1000 != 0) leds |= 1 << 1;
        if (locks & 0x4000 != 0) leds |= 1 << 2;
        if (self.leds_shown != null and self.leds_shown.? == leds) return;
        self.leds_shown = leds;
        @memset(&self.led_state_buffer, 0);
        self.led_state_buffer[0] = leds;

        // HID SET_REPORT (output report, id
        // 0) addressed to this interface.
        try xhci_driver.executeControlTransfer(
            self.slot_id,
            0x21,
            0x09,
            0x0200,
            self.interface_number,
            &self.led_state_buffer,
            1,
        );
    }

    pub fn toZdosMods(mods: Modifiers) u16 {
        var m: u16 = 0;
        if (mods.shift_left == 1) m |= 0x0001;
        if (mods.shift_right == 1) m |= 0x0002;
        if (mods.ctrl_left == 1) m |= 0x0004;
        if (mods.ctrl_right == 1) m |= 0x0008;
        if (mods.alt_left == 1) m |= 0x0010;
        if (mods.alt_right == 1) m |= 0x0020;
        if (mods.gui_left == 1) m |= 0x0040;
        if (mods.gui_right == 1) m |= 0x0080;
        return m;
    }

    /// The report of the next completion
    /// (its buffer is queued again after)
    pub fn processInterruptPacket(self: *UsbKeyboardDriver) void {
        const raw = &self.buffers[self.next_done];
        self.next_done = (self.next_done + 1) % InFlight;
        const current_report = @as(*const KeyboardBootReport, @ptrCast(raw)).*;
        // ErrorRollOver (0x01 in every slot) means "too many keys":
        // ignore the report entirely.
        if (current_report.keycodes[0] == 0x01) return;
        const zdos_mods = toZdosMods(current_report.mods);

        if (self.on_key_event) |callback| {
            const p = self.prev_report.mods;
            const c = current_report.mods;

            if (c.ctrl_left != p.ctrl_left) callback(.{ .code = 0x1D, .pressed = c.ctrl_left == 1, .mods = zdos_mods });
            if (c.shift_left != p.shift_left) callback(.{ .code = 0x2A, .pressed = c.shift_left == 1, .mods = zdos_mods });
            if (c.alt_left != p.alt_left) callback(.{ .code = 0x38, .pressed = c.alt_left == 1, .mods = zdos_mods });
            if (c.gui_left != p.gui_left) callback(.{ .code = 0xE05B, .pressed = c.gui_left == 1, .mods = zdos_mods });
            if (c.ctrl_right != p.ctrl_right) callback(.{ .code = 0xE01D, .pressed = c.ctrl_right == 1, .mods = zdos_mods });
            if (c.shift_right != p.shift_right) callback(.{ .code = 0x36, .pressed = c.shift_right == 1, .mods = zdos_mods });
            if (c.alt_right != p.alt_right) callback(.{ .code = 0xE038, .pressed = c.alt_right == 1, .mods = zdos_mods });
            if (c.gui_right != p.gui_right) callback(.{ .code = 0xE05C, .pressed = c.gui_right == 1, .mods = zdos_mods });
        }

        for (current_report.keycodes) |keycode| {
            if (keycode == 0) continue;

            var was_pressed_previously = false;
            for (self.prev_report.keycodes) |prev_keycode| {
                if (keycode == prev_keycode) {
                    was_pressed_previously = true;
                    break;
                }
            }

            if (!was_pressed_previously) {
                if (self.on_key_event) |callback| {
                    const scan_code = hidKeycodeToPcScanCode(keycode);
                    if (scan_code != 0) {
                        callback(.{
                            .code = scan_code,
                            .pressed = true,
                            .mods = zdos_mods,
                        });
                    }
                }
            }
        }

        if (self.on_key_event) |callback| {
            for (self.prev_report.keycodes) |prev_keycode| {
                if (prev_keycode == 0) continue;
                var still_pressed = false;
                for (current_report.keycodes) |cur_keycode| {
                    if (cur_keycode == prev_keycode) {
                        still_pressed = true;
                        break;
                    }
                }
                if (!still_pressed) {
                    const scan_code = hidKeycodeToPcScanCode(prev_keycode);
                    if (scan_code != 0) {
                        callback(.{
                            .code = scan_code,
                            .pressed = false,
                            .mods = zdos_mods,
                        });
                    }
                }
            }
        }
        self.prev_report = current_report;
    }
};

pub fn hidKeycodeToPcScanCode(keycode: u8) u16 {
    return switch (keycode) {
        0x04 => 0x1E,
        0x05 => 0x30,
        0x06 => 0x2E,
        0x07 => 0x20,
        0x08 => 0x12,
        0x09 => 0x21,
        0x0A => 0x22,
        0x0B => 0x23,
        0x0C => 0x17,
        0x0D => 0x24,
        0x0E => 0x25,
        0x0F => 0x26,
        0x10 => 0x32,
        0x11 => 0x31,
        0x12 => 0x18,
        0x13 => 0x19,
        0x14 => 0x10,
        0x15 => 0x13,
        0x16 => 0x1F,
        0x17 => 0x14,
        0x18 => 0x16,
        0x19 => 0x2F,
        0x1A => 0x11,
        0x1B => 0x2D,
        0x1C => 0x15,
        0x1D => 0x2C,
        0x1E => 0x02,
        0x1F => 0x03,
        0x20 => 0x04,
        0x21 => 0x05,
        0x22 => 0x06,
        0x23 => 0x07,
        0x24 => 0x08,
        0x25 => 0x09,
        0x26 => 0x0A,
        0x27 => 0x0B,
        0x28 => 0x1C,
        0x29 => 0x01,
        0x2A => 0x0E,
        0x2B => 0x0F,
        0x2C => 0x39,
        0x2D => 0x0C,
        0x2E => 0x0D,
        0x2F => 0x1A,
        0x30 => 0x1B,
        0x31 => 0x2B,
        0x32 => 0x2B, // non-US # / ~
        0x33 => 0x27,
        0x34 => 0x28,
        0x35 => 0x29,
        0x36 => 0x33,
        0x37 => 0x34,
        0x38 => 0x35,
        0x39 => 0x3A,
        0x3A => 0x3B,
        0x3B => 0x3C,
        0x3C => 0x3D,
        0x3D => 0x3E,
        0x3E => 0x3F,
        0x3F => 0x40,
        0x40 => 0x41,
        0x41 => 0x42,
        0x42 => 0x43,
        0x43 => 0x44,
        0x44 => 0x57,
        0x45 => 0x58,
        0x46 => 0xE037,
        0x47 => 0x46,
        0x48 => 0xE11D, // Pause
        0x49 => 0xE052,
        0x4A => 0xE047,
        0x4B => 0xE049,
        0x4C => 0xE053,
        0x4D => 0xE04F,
        0x4E => 0xE051,
        0x4F => 0xE04D,
        0x50 => 0xE04B,
        0x51 => 0xE050,
        0x52 => 0xE048,
        0x53 => 0x45,
        0x54 => 0xE035,
        0x55 => 0x37,
        0x56 => 0x4A,
        0x57 => 0x4E,
        0x58 => 0xE01C,
        0x59 => 0x4F,
        0x5A => 0x50,
        0x5B => 0x51,
        0x5C => 0x4B,
        0x5D => 0x4C,
        0x5E => 0x4D,
        0x5F => 0x47,
        0x60 => 0x48,
        0x61 => 0x49,
        0x62 => 0x52,
        0x63 => 0x53,
        0x64 => 0x56, // non-US \ / |
        0x65 => 0xE05D, // Application (menu) key
        0x67 => 0x59, // keypad =
        0x68...0x72 => 0x64 + @as(u16, keycode - 0x68), // F13..F23
        0x73 => 0x76, // F24
        0x85 => 0x7E, // keypad , (Brazilian)
        0x87 => 0x73, // Ro (Japanese), / ? (Brazilian)
        0x88 => 0x70, // Katakana / Hiragana
        0x89 => 0x7D, // Yen
        0x8A => 0x79, // Henkan
        0x8B => 0x7B, // Muhenkan
        else => 0,
    };
}
