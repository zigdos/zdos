//! USB HID mouse (5 buttons, wheel): report protocol, its
//! fields where the report descriptor puts them; boot protocol
//! if that can't be read (most mice then drop the wheel).

const std = @import("std");
const xhci = @import("xhci.zig");

pub const DeviceDescriptor = extern struct {
    length: u8,
    descriptor_type: u8,
    bcd_usb: u16,
    device_class: u8,
    device_subclass: u8,
    device_protocol: u8,
    max_packet_size0: u8,
    id_vendor: u16,
    id_product: u16,
    bcd_device: u16,
    manufacturer_idx: u8,
    product_idx: u8,
    serial_number_idx: u8,
    num_configurations: u8,
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

pub const MouseBootReport = extern struct {
    buttons: u8 = 0,
    delta_x: i8 = 0,
    delta_y: i8 = 0,
    wheel_scroll: i8 = 0,
    high_res_wheel: i16 = 0,
};

/// Where a value sits in a report (after the
/// report ID byte, if any); size 0: not there
pub const Field = struct {
    offset: u16 = 0, // bits
    size: u8 = 0,
    signed: bool = false,
};

pub const Layout = struct {
    report_id: u8 = 0, // 0: the device uses no report IDs
    buttons: [5]Field = [_]Field{.{}} ** 5,
    x: Field = .{},
    y: Field = .{},
    wheel: Field = .{},
};

pub const boot_layout: Layout = .{
    .buttons = .{
        .{ .offset = 0, .size = 1 }, .{ .offset = 1, .size = 1 }, .{ .offset = 2, .size = 1 },
        .{ .offset = 3, .size = 1 }, .{ .offset = 4, .size = 1 },
    },
    .x = .{ .offset = 8, .size = 8, .signed = true },
    .y = .{ .offset = 16, .size = 8, .signed = true },
    .wheel = .{ .offset = 24, .size = 8, .signed = true }, // optional; 0 if the device doesn't send it
};

/// The mouse's input report in a HID report descriptor: the
/// report that has relative X, then its buttons, Y and wheel.
/// Null if there is none (absolute pointers, odd devices).
pub fn parseReportDescriptor(desc: []const u8) ?Layout {
    const id = scanDescriptor(desc, null, null) orelse return null;
    var layout: Layout = .{ .report_id = id };
    _ = scanDescriptor(desc, id, &layout);
    if (layout.x.size == 0 or layout.y.size == 0 or layout.x.size > 32 or layout.y.size > 32) return null;
    if (layout.wheel.size > 32) layout.wheel = .{};
    return layout;
}

/// One walk over the descriptor's short items. want == null:
/// the report ID of the first relative X. Else the fields of
/// report `want` go into `out`.
fn scanDescriptor(desc: []const u8, want: ?u8, out: ?*Layout) ?u8 {
    var page: u32 = 0;
    var logical_min: i32 = 0;
    var report_size: u32 = 0;
    var report_count: u32 = 0;
    var report_id: u8 = 0;
    var bit_at = [_]u16{0} ** 256; // the next free bit of each report
    var usages: [16]u32 = undefined; // page << 16 | usage
    var n_usages: usize = 0;
    var usage_min: u32 = 0;
    var usage_max: u32 = 0;
    var has_range = false;

    var i: usize = 0;
    while (i < desc.len) {
        const prefix = desc[i];
        if (prefix == 0xFE) { // long item: skipped
            if (i + 1 >= desc.len) break;
            i += 3 + @as(usize, desc[i + 1]);
            continue;
        }
        const len: usize = switch (prefix & 3) {
            3 => 4,
            else => |n| n,
        };
        if (i + 1 + len > desc.len) break;
        const bytes = desc[i + 1 ..][0..len];
        i += 1 + len;
        var data: u32 = 0;
        for (bytes, 0..) |b, k| data |= @as(u32, b) << @intCast(8 * k);
        const sdata: i32 = switch (len) {
            1 => @as(i8, @bitCast(@as(u8, @truncate(data)))),
            2 => @as(i16, @bitCast(@as(u16, @truncate(data)))),
            else => @bitCast(data),
        };
        // A local usage without a page gets the current one
        const full: u32 = if (len == 4) data else (page << 16) | (data & 0xFFFF);

        switch (prefix & 0xFC) {
            0x04 => page = data & 0xFFFF, // usage page
            0x14 => logical_min = sdata,
            0x74 => report_size = data,
            0x94 => report_count = data,
            0x84 => report_id = @truncate(data),
            0x08 => { // usage
                if (n_usages < usages.len) usages[n_usages] = full;
                n_usages += 1;
            },
            0x18 => {
                usage_min = full;
                has_range = true;
            },
            0x28 => usage_max = full,
            0x80, 0x90, 0xB0, 0xA0, 0xC0 => { // input, output, feature, collection, end
                if (prefix & 0xFC == 0x80) {
                    const constant = data & 1 != 0;
                    const relative = data & 4 != 0;
                    for (0..@min(report_count, 1024)) |f| {
                        const at = bit_at[report_id];
                        bit_at[report_id] +|= @intCast(@min(report_size, 0xFFFF));
                        if (constant) continue;
                        const usage: u32 = if (n_usages > 0)
                            usages[@min(f, @min(n_usages, usages.len) - 1)]
                        else if (has_range and usage_min + f <= usage_max)
                            usage_min + @as(u32, @intCast(f))
                        else
                            continue;
                        const field: Field = .{ .offset = at, .size = @intCast(@min(report_size, 255)), .signed = logical_min < 0 };
                        if (want == null) {
                            if (usage == 0x0001_0030 and relative) return report_id;
                            continue;
                        }
                        if (report_id != want.?) continue;
                        const l = out.?;
                        switch (usage) {
                            0x0001_0030 => if (l.x.size == 0) {
                                l.x = field;
                            },
                            0x0001_0031 => if (l.y.size == 0) {
                                l.y = field;
                            },
                            0x0001_0038 => if (l.wheel.size == 0) {
                                l.wheel = field;
                            },
                            0x0009_0001...0x0009_0005 => {
                                const b = &l.buttons[usage - 0x0009_0001];
                                if (b.size == 0) b.* = field;
                            },
                            else => {},
                        }
                    }
                }
                n_usages = 0;
                has_range = false;
            },
            else => {},
        }
    }
    return null;
}

/// A field's value from a report
fn read(report: []const u8, f: Field) i32 {
    if (f.size == 0) return 0;
    const size: u32 = @min(f.size, 32);
    var v: u64 = 0;
    var k: u32 = 0;
    while (k < size) : (k += 1) {
        const bit = @as(usize, f.offset) + k;
        if (bit / 8 >= report.len) break;
        if (report[bit / 8] & (@as(u8, 1) << @intCast(bit % 8)) != 0) v |= @as(u64, 1) << @intCast(k);
    }
    const shift: u6 = @intCast(64 - size);
    const wide: i64 = if (f.signed) @as(i64, @bitCast(v << shift)) >> shift else @intCast(v);
    return @intCast(std.math.clamp(wide, std.math.minInt(i32), std.math.maxInt(i32)));
}

pub const ZdosMouse = struct {
    dx: i32 = 0,
    dy: i32 = 0,
    wheel: i32 = 0,
    high_res_wheel: i32 = 0,
    buttons: u8 = 0,
};

/// Reports requested at once: the controller fetches one per
/// service interval while ZDOS isn't looking, so movement isn't
/// held back to one report (at most 127 counts) per poll.
pub const InFlight = 8;

pub const UsbMouseDriver = struct {
    slot_id: u8,
    input_endpoint_id: u8 = 0,
    max_packet_size: u16 = 8,
    prev_buttons: u8 = 0,
    report_desc_len: u16 = 0, // from the HID descriptor; 0: not given
    layout: Layout = boot_layout,

    /// DMA targets for interrupt reports, used in turn (a ring
    /// finishes its transfers in order). Larger than any boot
    /// report so an endpoint with a big
    /// wMaxPacketSize cannot overflow them.
    buffers: [InFlight][64]u8 align(16) = [_][64]u8{[_]u8{0} ** 64} ** InFlight,
    next_queued: usize = 0, // the buffer the next transfer goes into
    next_done: usize = 0, // the buffer the next completion filled

    on_zdos_mouse: ?*const fn (mouse: ZdosMouse) void = null,

    pub fn init(slot_id: u8) UsbMouseDriver {
        return .{
            .slot_id = slot_id,
        };
    }

    pub fn parseInterface(self: *UsbMouseDriver, interface: InterfaceDescriptor, endpoint_address: u8, max_packet: u16) bool {
        if (interface.interface_class == 3 and interface.interface_subclass == 1 and interface.interface_protocol == 2) {
            const ep_num = endpoint_address & 0x0F;
            const is_in = (endpoint_address & 0x80) != 0;
            if (!is_in) return false;
            self.max_packet_size = max_packet;
            self.input_endpoint_id = (@as(u8, ep_num) * 2) + @as(u8, if (is_in) 1 else 0);
            return true;
        }
        return false;
    }

    /// Queues one transfer into the next buffer in turn
    pub fn queueInterruptTransfer(self: *UsbMouseDriver, xhci_driver: anytype) !void {
        const buf = &self.buffers[self.next_queued];
        @memset(buf, 0); // bytes the device doesn't send must read as 0
        const phys_addr = xhci.virtToPhys(@intFromPtr(buf));
        const len: u16 = @min(self.max_packet_size, @as(u16, buf.len));
        try xhci_driver.submitInterruptTransfer(self.slot_id, self.input_endpoint_id, phys_addr, len);
        self.next_queued = (self.next_queued + 1) % InFlight;
    }

    /// At the start, and after an error left
    /// the endpoint empty: every buffer queued
    pub fn queueAll(self: *UsbMouseDriver, xhci_driver: anytype) !void {
        self.next_queued = 0;
        self.next_done = 0;
        for (0..InFlight) |_| try self.queueInterruptTransfer(xhci_driver);
    }

    /// The report of the next completion
    /// (its buffer is queued again after)
    pub fn processInterruptPacket(self: *UsbMouseDriver) void {
        const raw = &self.buffers[self.next_done];
        self.next_done = (self.next_done + 1) % InFlight;
        const l = &self.layout;
        // Other reports of the device (media
        // keys and such) are not the mouse's
        if (l.report_id != 0 and raw[0] != l.report_id) return;
        const b: []const u8 = if (l.report_id != 0) raw[1..] else raw[0..];
        var buttons: u8 = 0;
        for (l.buttons, 0..) |f, i| {
            if (read(b, f) != 0) buttons |= @as(u8, 1) << @intCast(i);
        }
        const delta_x = read(b, l.x);
        const delta_y = read(b, l.y);
        const wheel = read(b, l.wheel);

        if (delta_x == 0 and delta_y == 0 and wheel == 0 and buttons == self.prev_buttons) return;
        self.prev_buttons = buttons;

        if (self.on_zdos_mouse) |callback| {
            callback(.{
                .dx = delta_x,
                .dy = delta_y,
                .wheel = wheel,
                .high_res_wheel = 0,
                .buttons = buttons,
            });
        }
    }
};
