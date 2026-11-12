//! USB core on top of xhci.zig: attach/detach, enumeration,
//! hubs, class drivers and event dispatch.

const std = @import("std");

pub const xhci = @import("xhci.zig");
pub const mouse = @import("usbmouse.zig");
pub const keyboard = @import("usbkbd.zig");
pub const storage = @import("usbstorage.zig");

pub const AttachedDeviceType = enum {
    none,
    mouse,
    keyboard,
    storage,
    hub,
    composite,
};

pub const MaxInterfacesPerSlot = 4;

pub const InterfaceDriverInstance = union(AttachedDeviceType) {
    none: void,
    mouse: mouse.UsbMouseDriver,
    keyboard: keyboard.UsbKeyboardDriver,
    storage: storage.UsbStorageDriver,
    hub: void,
    composite: void,
};

pub const DeviceSlotTracker = struct {
    device_type: AttachedDeviceType = .none,
    interfaces: [MaxInterfacesPerSlot]InterfaceDriverInstance = [_]InterfaceDriverInstance{.{ .none = {} }} ** MaxInterfacesPerSlot,
    interface_count: usize = 0,

    endpoint_addresses: [MaxInterfacesPerSlot]u8 = [_]u8{0} ** MaxInterfacesPerSlot,
    endpoint_types: [MaxInterfacesPerSlot]u8 = [_]u8{0} ** MaxInterfacesPerSlot,
    /// xHCI device-context index of each
    /// interface's primary endpoint (0 = none).
    endpoint_dci: [MaxInterfacesPerSlot]u8 = [_]u8{0} ** MaxInterfacesPerSlot,
    interface_numbers: [MaxInterfacesPerSlot]u8 = [_]u8{0} ** MaxInterfacesPerSlot,

    /// Root port the device is under (directly
    /// or through hubs); 0 = slot not in use.
    port: u8 = 0,
    speed: xhci.PortSpeed = .full,
    /// Behind a hub: the hub's slot and port (0 on a root port),
    /// the route string and tier (0 on a root port). tt_*: the
    /// transaction translator a
    /// low/full-speed device talks through.
    parent_slot: u8 = 0,
    parent_port: u8 = 0,
    route: u20 = 0,
    tier: u8 = 0,
    tt_slot: u8 = 0,
    tt_port: u8 = 0,
    /// Hubs: downstream ports, the status-change endpoint's packet
    /// size and its report (DMA target).
    hub_ports: u8 = 0,
    hub_mps: u16 = 0,
    hub_change: [8]u8 align(16) = [_]u8{0} ** 8,
    /// A status-change report left for processTopology
    /// (topology_elsewhere), and whether it came
    hub_pending: bool = false,
    hub_ok: bool = false,
    /// Tells this device from one enumerated
    /// in the same slot before or later
    attach_id: u32 = 0,
    vendor_id: u16 = 0,
    product_id: u16 = 0,

    manufacturer: [64]u8 = [_]u8{0} ** 64,
    product: [64]u8 = [_]u8{0} ** 64,
    serial_number: [64]u8 = [_]u8{0} ** 64,
};

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

/// Parsed endpoint descriptor (not the wire layout: the wire
/// form is 7 bytes and unaligned).
pub const EndpointDescriptor = struct {
    length: u8,
    descriptor_type: u8,
    endpoint_address: u8,
    attributes: u8,
    max_packet_size: u16,
    interval: u8,
};

fn rd16(b: []const u8, o: usize) u16 {
    return @as(u16, b[o]) | (@as(u16, b[o + 1]) << 8);
}

fn dciOf(endpoint_address: u8) u8 {
    return (endpoint_address & 0x0F) * 2 + @as(u8, if ((endpoint_address & 0x80) != 0) 1 else 0);
}

pub const UsbCoreManager = struct {
    slots: [xhci.MaxSlots + 1]DeviceSlotTracker = [_]DeviceSlotTracker{.{}} ** (xhci.MaxSlots + 1),
    port_slot: [256]u8 = [_]u8{0} ** 256,

    /// Called for every key press/release (PC set-1 scancode,
    /// 0xE0xx for extended keys).
    pub var on_key_event: ?*const fn (event: keyboard.ZdosKeyEvent) void = null;
    pub var on_mouse: ?*const fn (m: mouse.ZdosMouse) void = null;
    /// The lock keys that are on (ZDOS
    /// Mod bits), for keyboards' lights
    pub var lock_state: ?*const fn () u16 = null;
    /// Devices coming and going are handled by processTopology
    /// alone (the OS's hot-plug task), not by processPending: that
    /// may run where it must not wait for long (key polling)
    pub var topology_elsewhere = false;
    /// The USB debounce after a connect; 0
    /// where the caller has waited already
    pub var debounce_ms: u32 = 100;
    var next_attach_id: u32 = 1;

    fn locks() u16 {
        return if (lock_state) |f| f() else 0;
    }

    pub fn executeControlTransfer(
        self: *UsbCoreManager,
        driver: *xhci.XhciDriver,
        slot_id: u8,
        bmRequestType: u8,
        bRequest: u8,
        wValue: u16,
        wIndex: u16,
        data_ptr: ?*anyopaque,
        wLength: u16,
    ) !void {
        _ = self;
        try driver.executeControlTransfer(slot_id, bmRequestType, bRequest, wValue, wIndex, data_ptr, wLength);
    }

    // PORT MANAGEMENT

    /// Attach everything already plugged into a root port.
    /// Call once after setupAndStart().
    pub fn scanPorts(self: *UsbCoreManager, driver: *xhci.XhciDriver) void {
        var port: u8 = 1;
        while (port <= driver.max_ports) : (port += 1) {
            _ = driver.ackPortChanges(port);
            if ((driver.portStatus(port) & xhci.PORTSC_CCS) != 0 and self.port_slot[port] == 0) {
                self.attachPort(driver, port) catch {};
            }
        }
        // Everything seen so far has been handled;
        // drop stale change notifications.
        driver.drainEvents();
        port = 1;
        while (port <= driver.max_ports) : (port += 1) driver.port_changed[port] = false;
    }

    /// Reset a port, give the device an address and enumerate it.
    pub fn attachPort(self: *UsbCoreManager, driver: *xhci.XhciDriver, port: u8) !void {
        xhci.delayMs(debounce_ms);
        const speed = try driver.portReset(port);
        const slot = try driver.enableSlot();
        errdefer driver.disableSlot(slot) catch {};

        self.slots[slot] = .{};
        self.slots[slot].port = port;
        self.slots[slot].speed = speed;
        self.port_slot[port] = slot;
        errdefer {
            self.port_slot[port] = 0;
            self.slots[slot] = .{};
        }

        try driver.addressDevice(slot, port, speed);
        try self.enumerateAndAttachDevice(driver, slot);
    }

    pub fn detachPort(self: *UsbCoreManager, driver: *xhci.XhciDriver, port: u8) void {
        const slot = self.port_slot[port];
        if (slot == 0) return;
        self.detachSlot(driver, slot);
        self.port_slot[port] = 0;
    }

    /// Forget a device and, if it is a hub, everything behind it.
    fn detachSlot(self: *UsbCoreManager, driver: *xhci.XhciDriver, slot: u8) void {
        var s: u8 = 1;
        while (s <= xhci.MaxSlots) : (s += 1) {
            if (self.slots[s].port != 0 and self.slots[s].parent_slot == slot) self.detachSlot(driver, s);
        }
        driver.disableSlot(slot) catch {};
        self.slots[slot] = .{};
    }

    fn handlePortChange(self: *UsbCoreManager, driver: *xhci.XhciDriver, port: u8) void {
        const status = driver.portStatus(port);
        const changes = driver.ackPortChanges(port);
        const connected = (status & xhci.PORTSC_CCS) != 0;
        const attached = self.port_slot[port] != 0;

        if (attached and (!connected or (changes & xhci.PORTSC_CSC) != 0)) self.detachPort(driver, port);
        if (connected and self.port_slot[port] == 0) self.attachPort(driver, port) catch {};
    }

    /// Hot-plug handling (unless topology_elsewhere) plus delivery
    /// of completed interrupt transfers. Called by
    /// XhciDriver.pollEvents().
    pub fn processPending(self: *UsbCoreManager, driver: *xhci.XhciDriver) void {
        self.process(driver, !topology_elsewhere);
    }

    /// processPending with devices coming
    /// and going (the OS's hot-plug task)
    pub fn processTopology(self: *UsbCoreManager, driver: *xhci.XhciDriver) void {
        self.process(driver, true);
    }

    fn process(self: *UsbCoreManager, driver: *xhci.XhciDriver, topology: bool) void {
        if (topology) {
            var port: u8 = 1;
            while (port <= driver.max_ports) : (port += 1) {
                if (driver.port_changed[port]) {
                    driver.port_changed[port] = false;
                    self.handlePortChange(driver, port);
                }
            }
            for (1..xhci.MaxSlots + 1) |s| {
                const t = &self.slots[s];
                if (!t.hub_pending) continue;
                t.hub_pending = false;
                const slot: u8 = @intCast(s);
                if (t.hub_ok) self.handleHubChange(driver, slot);
                for (0..t.interface_count) |i| {
                    if (t.interfaces[i] == .hub and t.endpoint_dci[i] != 0) self.queueHubStatus(driver, slot, t.endpoint_dci[i]) catch {};
                }
            }
        }
        while (driver.takeInterrupt()) |ev| {
            self.dispatchEndpointEvent(driver, ev.slot, ev.dci, ev.code, topology);
        }
    }

    /// Whether processTopology has work: a root port or a hub
    /// reported a change. Doesn't wait.
    pub fn topologyPending(self: *const UsbCoreManager, driver: *const xhci.XhciDriver) bool {
        var port: u8 = 1;
        while (port <= driver.max_ports) : (port += 1) {
            if (driver.port_changed[port]) return true;
        }
        for (1..xhci.MaxSlots + 1) |s| {
            const t = &self.slots[s];
            if (t.hub_ports == 0) continue;
            if (t.hub_pending) return true;
            for (0..t.interface_count) |i| {
                const dci = t.endpoint_dci[i];
                if (t.interfaces[i] == .hub and dci != 0 and driver.irq_count[s][dci] > 0) return true;
            }
        }
        return false;
    }

    // ENUMERATION

    fn classify(self: *UsbCoreManager, tracker: *DeviceSlotTracker, slot_id: u8, iface: InterfaceDescriptor) ?usize {
        _ = self;
        if (tracker.interface_count >= MaxInterfacesPerSlot) return null;
        const idx = tracker.interface_count;
        const c = iface.interface_class;
        const sub = iface.interface_subclass;
        const proto = iface.interface_protocol;

        if (c == 3 and sub == 1 and proto == 2) {
            var m = mouse.UsbMouseDriver.init(slot_id);
            m.on_zdos_mouse = on_mouse;
            tracker.interfaces[idx] = .{ .mouse = m };
            tracker.device_type = .mouse;
        } else if (c == 3 and sub == 1 and proto == 1) {
            var k = keyboard.UsbKeyboardDriver.init(slot_id);
            k.on_key_event = on_key_event;
            tracker.interfaces[idx] = .{ .keyboard = k };
            tracker.device_type = .keyboard;
        } else if (c == 0x08 and sub == 0x06 and proto == 0x50) { // mass storage, SCSI, bulk-only transport
            tracker.interfaces[idx] = .{ .storage = storage.UsbStorageDriver.init(slot_id) };
            tracker.device_type = .storage;
        } else if (c == 0x09) {
            tracker.interfaces[idx] = .{ .hub = {} };
            tracker.device_type = .hub;
        } else {
            return null;
        }
        tracker.interface_numbers[idx] = iface.interface_number;
        tracker.interface_count += 1;
        if (tracker.interface_count > 1) tracker.device_type = .composite;
        return idx;
    }

    /// Enumerate an already-addressed device (Enable Slot +
    /// Address Device done): read descriptors, bind class
    /// drivers, configure endpoints, SET_CONFIGURATION, and start
    /// the HID transfers. anyerror: hubs make this recursive
    /// (setUpHub -> attachHubPort -> here).
    pub fn enumerateAndAttachDevice(self: *UsbCoreManager, driver: *xhci.XhciDriver, slot_id: u8) anyerror!void {
        const tracker = &self.slots[slot_id];
        tracker.device_type = .none;
        tracker.interface_count = 0;
        tracker.attach_id = next_attach_id;
        next_attach_id +%= 1;

        // 1. First 8 bytes of the device descriptor
        // tell us EP0's real max packet size.
        var dd: [18]u8 align(8) = [_]u8{0} ** 18;
        try self.executeControlTransfer(driver, slot_id, 0x80, 0x06, 0x0100, 0, &dd, 8);
        const raw_mps = dd[7];
        const real_mps: u16 = if (tracker.speed == .super) (if (raw_mps >= 9 and raw_mps <= 15) @as(u16, 1) << @as(u4, @intCast(raw_mps)) else 512) else raw_mps;
        const mps_valid = switch (real_mps) {
            8, 16, 32, 64, 512 => true,
            else => false,
        };
        if (mps_valid and real_mps != driver.ep0_mps[slot_id]) try driver.updateEp0MaxPacket(slot_id, real_mps);

        // 2. Full device descriptor + strings.
        try self.executeControlTransfer(driver, slot_id, 0x80, 0x06, 0x0100, 0, &dd, 18);
        tracker.vendor_id = rd16(&dd, 8);
        tracker.product_id = rd16(&dd, 10);
        if (dd[14] != 0) _ = self.fetchStringDescriptor(driver, slot_id, dd[14], &tracker.manufacturer);
        if (dd[15] != 0) _ = self.fetchStringDescriptor(driver, slot_id, dd[15], &tracker.product);
        if (dd[16] != 0) _ = self.fetchStringDescriptor(driver, slot_id, dd[16], &tracker.serial_number);

        // 3. Configuration descriptor: 9 bytes
        // for wTotalLength, then the whole thing.
        var cfg: [512]u8 align(8) = [_]u8{0} ** 512;
        try self.executeControlTransfer(driver, slot_id, 0x80, 0x06, 0x0200, 0, &cfg, 9);
        const total: usize = @min(rd16(&cfg, 2), cfg.len);
        const config_value = cfg[5];
        if (total > 9) try self.executeControlTransfer(driver, slot_id, 0x80, 0x06, 0x0200, 0, &cfg, @intCast(total));

        // 4. Walk descriptors, bind drivers,
        // collect the endpoints to configure.
        var setups: [8]xhci.EndpointSetup = undefined;
        var n_setups: usize = 0;
        var cur: ?usize = null;
        var cur_iface: InterfaceDescriptor = undefined;
        var st_in: ?u8 = null;
        var st_out: ?u8 = null;
        var st_in_mps: u16 = 0;
        var st_out_mps: u16 = 0;

        var off: usize = 0;
        while (off + 2 <= total) {
            const len = cfg[off];
            const typ = cfg[off + 1];
            if (len < 2 or off + len > total) break;

            switch (typ) {
                4 => { // interface (alternate setting 0 only)
                    cur = null;
                    st_in = null;
                    st_out = null;
                    if (len >= 9 and cfg[off + 3] == 0) {
                        cur_iface = .{
                            .length = cfg[off],
                            .descriptor_type = cfg[off + 1],
                            .interface_number = cfg[off + 2],
                            .alternate_setting = cfg[off + 3],
                            .num_endpoints = cfg[off + 4],
                            .interface_class = cfg[off + 5],
                            .interface_subclass = cfg[off + 6],
                            .interface_protocol = cfg[off + 7],
                            .interface_idx = cfg[off + 8],
                        };
                        cur = self.classify(tracker, slot_id, cur_iface);
                    }
                },
                0x21 => if (cur) |idx| { // HID: the report descriptor's length
                    switch (tracker.interfaces[idx]) {
                        .mouse => |*m_drv| if (len >= 9 and cfg[off + 6] == 0x22) {
                            m_drv.report_desc_len = rd16(&cfg, off + 7);
                        },
                        else => {},
                    }
                },
                5 => if (cur) |idx| { // endpoint
                    if (len >= 7) {
                        const ep = EndpointDescriptor{
                            .length = cfg[off],
                            .descriptor_type = cfg[off + 1],
                            .endpoint_address = cfg[off + 2],
                            .attributes = cfg[off + 3],
                            .max_packet_size = rd16(&cfg, off + 4),
                            .interval = cfg[off + 6],
                        };
                        const is_in = (ep.endpoint_address & 0x80) != 0;
                        const dci = dciOf(ep.endpoint_address);
                        const mps = ep.max_packet_size & 0x07FF;
                        const is_interrupt = (ep.attributes & 3) == 3;
                        const is_bulk = (ep.attributes & 3) == 2;

                        switch (tracker.interfaces[idx]) {
                            .mouse => |*m_drv| {
                                if (is_interrupt and is_in and tracker.endpoint_dci[idx] == 0 and n_setups < setups.len) {
                                    const pi = mouse.InterfaceDescriptor{
                                        .length = cur_iface.length,
                                        .descriptor_type = cur_iface.descriptor_type,
                                        .interface_number = cur_iface.interface_number,
                                        .alternate_setting = cur_iface.alternate_setting,
                                        .num_endpoints = cur_iface.num_endpoints,
                                        .interface_class = cur_iface.interface_class,
                                        .interface_subclass = cur_iface.interface_subclass,
                                        .interface_protocol = cur_iface.interface_protocol,
                                        .interface_idx = cur_iface.interface_idx,
                                    };
                                    if (m_drv.parseInterface(pi, ep.endpoint_address, mps)) {
                                        tracker.endpoint_addresses[idx] = ep.endpoint_address;
                                        tracker.endpoint_types[idx] = ep.attributes & 3;
                                        tracker.endpoint_dci[idx] = dci;
                                        setups[n_setups] = .{ .dci = dci, .ep_type = xhci.xhciEndpointType(ep.attributes, true), .max_packet_size = mps, .interval = xhci.endpointInterval(tracker.speed, ep.attributes, ep.interval) };
                                        n_setups += 1;
                                    }
                                }
                            },
                            .keyboard => |*k_drv| {
                                if (is_interrupt and is_in and tracker.endpoint_dci[idx] == 0 and n_setups < setups.len) {
                                    const pi = keyboard.InterfaceDescriptor{
                                        .length = cur_iface.length,
                                        .descriptor_type = cur_iface.descriptor_type,
                                        .interface_number = cur_iface.interface_number,
                                        .alternate_setting = cur_iface.alternate_setting,
                                        .num_endpoints = cur_iface.num_endpoints,
                                        .interface_class = cur_iface.interface_class,
                                        .interface_subclass = cur_iface.interface_subclass,
                                        .interface_protocol = cur_iface.interface_protocol,
                                        .interface_idx = cur_iface.interface_idx,
                                    };
                                    if (k_drv.parseInterface(pi, ep.endpoint_address, mps)) {
                                        tracker.endpoint_addresses[idx] = ep.endpoint_address;
                                        tracker.endpoint_types[idx] = ep.attributes & 3;
                                        tracker.endpoint_dci[idx] = dci;
                                        setups[n_setups] = .{ .dci = dci, .ep_type = xhci.xhciEndpointType(ep.attributes, true), .max_packet_size = mps, .interval = xhci.endpointInterval(tracker.speed, ep.attributes, ep.interval) };
                                        n_setups += 1;
                                    }
                                }
                            },
                            .hub => {
                                // The status-change endpoint: which ports changed
                                if (is_interrupt and is_in and tracker.endpoint_dci[idx] == 0 and n_setups < setups.len) {
                                    tracker.endpoint_addresses[idx] = ep.endpoint_address;
                                    tracker.endpoint_types[idx] = 3;
                                    tracker.endpoint_dci[idx] = dci;
                                    tracker.hub_mps = mps;
                                    setups[n_setups] = .{ .dci = dci, .ep_type = xhci.xhciEndpointType(ep.attributes, true), .max_packet_size = mps, .interval = xhci.endpointInterval(tracker.speed, ep.attributes, ep.interval) };
                                    n_setups += 1;
                                }
                            },
                            .storage => |*s_drv| {
                                if (is_bulk and tracker.endpoint_dci[idx] == 0) {
                                    if (is_in) {
                                        if (st_in == null) {
                                            st_in = ep.endpoint_address;
                                            st_in_mps = mps;
                                        }
                                    } else if (st_out == null) {
                                        st_out = ep.endpoint_address;
                                        st_out_mps = mps;
                                    }
                                    if (st_in != null and st_out != null and n_setups + 2 <= setups.len) {
                                        tracker.endpoint_addresses[idx] = st_in.?;
                                        tracker.endpoint_types[idx] = 2;
                                        _ = s_drv.parseInterface(0x08, 0x06, 0x50, st_in.?, st_out.?);
                                        s_drv.interface_number = cur_iface.interface_number;
                                        tracker.endpoint_dci[idx] = dciOf(st_in.?);
                                        setups[n_setups] = .{ .dci = dciOf(st_in.?), .ep_type = xhci.xhciEndpointType(2, true), .max_packet_size = st_in_mps, .interval = 0 };
                                        setups[n_setups + 1] = .{ .dci = dciOf(st_out.?), .ep_type = xhci.xhciEndpointType(2, false), .max_packet_size = st_out_mps, .interval = 0 };
                                        n_setups += 2;
                                    }
                                }
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
            off += len;
        }

        // 5. Configure Endpoint first, then SET_CONFIGURATION.
        if (n_setups > 0) try driver.configureEndpoints(slot_id, setups[0..n_setups]);
        try self.executeControlTransfer(driver, slot_id, 0x00, 0x09, config_value, 0, null, 0);

        // 6. Class setup and start of transfers.
        var i: usize = 0;
        while (i < tracker.interface_count) : (i += 1) {
            const iface_no: u16 = tracker.interface_numbers[i];
            switch (tracker.interfaces[i]) {
                .keyboard => |*k_drv| {
                    if (tracker.endpoint_dci[i] == 0) continue;
                    // Boot protocol + indefinite idle.
                    // Devices may stall these; failure is fine.
                    self.executeControlTransfer(driver, slot_id, 0x21, 0x0B, 0, iface_no, null, 0) catch {};
                    self.executeControlTransfer(driver, slot_id, 0x21, 0x0A, 0, iface_no, null, 0) catch {};
                    try k_drv.queueAll(driver);
                    k_drv.setLedState(driver, locks()) catch {};
                },
                .mouse => |*m_drv| {
                    if (tracker.endpoint_dci[i] == 0) continue;
                    self.setUpMouse(driver, slot_id, iface_no, m_drv);
                    self.executeControlTransfer(driver, slot_id, 0x21, 0x0A, 0, iface_no, null, 0) catch {};
                    try m_drv.queueAll(driver);
                },
                .storage => |*s_drv| {
                    if (tracker.endpoint_dci[i] == 0) continue;
                    // A card reader with no media fails here; that must
                    // not abort enumeration.
                    s_drv.readDiskCapacity(driver) catch {};
                },
                .hub => {
                    if (tracker.endpoint_dci[i] == 0) continue;
                    // A hub that can't be set up stays
                    // listed, with nothing behind it.
                    self.setUpHub(driver, slot_id, tracker.endpoint_dci[i]) catch {};
                },
                else => {},
            }
        }
    }

    /// Report protocol with the layout from the report descriptor,
    /// else boot protocol.
    /// Devices may stall SET_PROTOCOL; failure is fine.
    fn setUpMouse(self: *UsbCoreManager, driver: *xhci.XhciDriver, slot_id: u8, iface_no: u16, m_drv: *mouse.UsbMouseDriver) void {
        var desc: [512]u8 align(8) = [_]u8{0} ** 512;
        const want: u16 = if (m_drv.report_desc_len != 0) @min(m_drv.report_desc_len, desc.len) else desc.len;
        var report_protocol = false;
        if (self.executeControlTransfer(driver, slot_id, 0x81, 0x06, 0x2200, iface_no, &desc, want)) |_| {
            if (mouse.parseReportDescriptor(desc[0..want])) |layout| {
                m_drv.layout = layout;
                report_protocol = true;
            }
        } else |_| {}
        if (!report_protocol) m_drv.layout = mouse.boot_layout;
        // Report protocol is the default after the
        // port reset, so a stall changes nothing
        self.executeControlTransfer(driver, slot_id, 0x21, 0x0B, @intFromBool(report_protocol), iface_no, null, 0) catch {};
    }

    fn fetchStringDescriptor(self: *UsbCoreManager, driver: *xhci.XhciDriver, slot_id: u8, index: u8, dest_buf: []u8) bool {
        var raw_buf: [256]u8 align(8) = [_]u8{0} ** 256;
        self.executeControlTransfer(
            driver,
            slot_id,
            0x80,
            0x06,
            @as(u16, 3) << 8 | @as(u16, index),
            0x0409,
            &raw_buf,
            255,
        ) catch return false;

        const length = raw_buf[0];
        if (length < 2) return false;
        const char_count = (length - 2) / 2;
        var i: usize = 0;
        while (i < char_count and i < dest_buf.len - 1) : (i += 1) {
            const wchar = std.mem.readInt(u16, raw_buf[2 + (i * 2) ..][0..2], .little);
            dest_buf[i] = if (wchar < 128) @as(u8, @intCast(wchar)) else '?';
        }
        dest_buf[@min(char_count, dest_buf.len - 1)] = 0;
        return true;
    }

    // RUNTIME DISPATCH

    /// From the controller's interrupt, when no USB code is
    /// running (metal's usb.zig): the keyboards' and mice's
    /// completed reports, their transfers queued again, so a
    /// key's release counts at once however busy ZDOS is.
    /// Nothing here waits: errors, hubs and devices coming and
    /// going stay recorded for processPending.
    pub fn processInput(self: *UsbCoreManager, driver: *xhci.XhciDriver) void {
        for (1..xhci.MaxSlots + 1) |s| {
            const slot: u8 = @intCast(s);
            const t = &self.slots[slot];
            if (t.device_type == .none) continue;
            for (0..t.interface_count) |i| {
                const dci = t.endpoint_dci[i];
                if (dci == 0) continue;
                switch (t.interfaces[i]) {
                    .keyboard => |*k| while (driver.takeInputEvent(slot, dci)) {
                        k.on_key_event = on_key_event;
                        k.processInterruptPacket();
                        k.queueInterruptTransfer(driver) catch {};
                    },
                    .mouse => |*m| while (driver.takeInputEvent(slot, dci)) {
                        m.on_zdos_mouse = on_mouse;
                        m.processInterruptPacket();
                        m.queueInterruptTransfer(driver) catch {};
                    },
                    else => {},
                }
            }
        }
    }

    /// Keyboards' lights where the lock keys changed (a control
    /// transfer that waits: not from the interrupt)
    pub fn updateLeds(self: *UsbCoreManager, driver: *xhci.XhciDriver) void {
        for (1..xhci.MaxSlots + 1) |s| {
            const t = &self.slots[s];
            if (t.device_type == .none) continue;
            for (0..t.interface_count) |i| {
                switch (t.interfaces[i]) {
                    .keyboard => |*k| k.setLedState(driver, locks()) catch {},
                    else => {},
                }
            }
        }
    }

    fn dispatchEndpointEvent(self: *UsbCoreManager, driver: *xhci.XhciDriver, slot_id: u8, dci: u8, code: u8, topology: bool) void {
        if (slot_id == 0 or slot_id > xhci.MaxSlots) return;
        const tracker = &self.slots[slot_id];
        if (tracker.device_type == .none) return;

        const ok = (code == 1 or code == 13); // success / short packet
        var i: usize = 0;
        while (i < tracker.interface_count) : (i += 1) {
            if (tracker.endpoint_dci[i] != dci) continue;
            if (!ok) {
                driver.recoverEndpoint(slot_id, dci) catch continue;
            }
            switch (tracker.interfaces[i]) {
                .keyboard => |*k_drv| {
                    if (ok) {
                        // Pick up callbacks assigned after enumeration.
                        k_drv.on_key_event = on_key_event;
                        k_drv.processInterruptPacket();
                        k_drv.queueInterruptTransfer(driver) catch {};
                    } else {
                        // The endpoint was reset (recoverEndpoint): its transfers, and
                        // completions of them not taken yet, are gone
                        driver.irq_count[slot_id][dci] = 0;
                        driver.irq_mask[slot_id] &= ~(@as(u32, 1) << @as(u5, @intCast(dci)));
                        k_drv.queueAll(driver) catch {};
                    }
                },
                .mouse => |*m_drv| {
                    if (ok) {
                        m_drv.on_zdos_mouse = on_mouse;
                        m_drv.processInterruptPacket();
                        m_drv.queueInterruptTransfer(driver) catch {};
                    } else {
                        // The endpoint was reset (recoverEndpoint): its transfers, and
                        // completions of them not taken yet, are gone
                        driver.irq_count[slot_id][dci] = 0;
                        driver.irq_mask[slot_id] &= ~(@as(u32, 1) << @as(u5, @intCast(dci)));
                        m_drv.queueAll(driver) catch {};
                    }
                },
                .hub => {
                    if (!topology) {
                        tracker.hub_pending = true;
                        tracker.hub_ok = ok;
                        continue;
                    }
                    if (ok) self.handleHubChange(driver, slot_id);
                    self.queueHubStatus(driver, slot_id, dci) catch {};
                },
                else => {},
            }
        }
    }

    // HUBS (USB 2: HIGH- AND FULL-SPEED HUBS;
    // A USB 3 HUB'S USB 2 HALF IS ONE OF THOSE)

    const hub_port_reset = 4;
    const hub_port_power = 8;
    const hub_c_port_connection = 16;
    const hub_c_port_enable = 17;
    const hub_c_port_suspend = 18;
    const hub_c_port_over_current = 19;
    const hub_c_port_reset = 20;

    /// After a hub is configured: tell the controller it is a hub,
    /// power its ports, attach what is plugged in, then watch its
    /// status-change endpoint (dci) for hot-plug.
    fn setUpHub(self: *UsbCoreManager, driver: *xhci.XhciDriver, slot: u8, dci: u8) !void {
        const t = &self.slots[slot];
        // A USB 3 hub's SuperSpeed half:
        // keyboards and mice are on its USB 2 half
        if (t.speed == .super) return;
        if (t.tier >= 5) return; // the route string has room for 5 tiers
        var desc: [16]u8 align(8) = [_]u8{0} ** 16;
        try self.executeControlTransfer(driver, slot, 0xA0, 0x06, 0x2900, 0, &desc, 9); // hub descriptor
        const ports = @min(desc[2], 15);
        if (ports == 0) return;
        const ttt: u2 = @intCast((rd16(&desc, 3) >> 5) & 3);
        try driver.configureHub(slot, ports, ttt);
        t.hub_ports = ports;

        var p: u8 = 1;
        while (p <= ports) : (p += 1) self.hubSetPortFeature(driver, slot, p, hub_port_power) catch {};
        xhci.delayMs(@max(@as(u32, desc[5]) * 2, 100)); // bPwrOn2PwrGood, in 2 ms units
        p = 1;
        while (p <= ports) : (p += 1) self.checkHubPort(driver, slot, p);
        try self.queueHubStatus(driver, slot, dci);
    }

    fn queueHubStatus(self: *UsbCoreManager, driver: *xhci.XhciDriver, slot: u8, dci: u8) !void {
        const t = &self.slots[slot];
        const len: u16 = @min(t.hub_mps, t.hub_change.len);
        @memset(&t.hub_change, 0);
        try driver.submitInterruptTransfer(slot, dci, xhci.virtToPhys(@intFromPtr(&t.hub_change)), len);
    }

    /// The hub's status-change report: bit n set = port n
    /// changed (bit 0: the hub itself).
    fn handleHubChange(self: *UsbCoreManager, driver: *xhci.XhciDriver, slot: u8) void {
        const t = &self.slots[slot];
        var p: u8 = 1;
        while (p <= t.hub_ports) : (p += 1) {
            if (t.hub_change[p / 8] & (@as(u8, 1) << @intCast(p % 8)) != 0) self.checkHubPort(driver, slot, p);
        }
    }

    /// The device on a hub port, if one is attached there.
    fn childAt(self: *UsbCoreManager, hub_slot: u8, port: u8) u8 {
        var s: u8 = 1;
        while (s <= xhci.MaxSlots) : (s += 1) {
            const c = &self.slots[s];
            if (c.port != 0 and c.parent_slot == hub_slot and c.parent_port == port) return s;
        }
        return 0;
    }

    /// Acknowledge a hub port's changes, then
    /// attach or detach its device as needed.
    fn checkHubPort(self: *UsbCoreManager, driver: *xhci.XhciDriver, hub_slot: u8, port: u8) void {
        var st: [4]u8 align(4) = undefined;
        if (!self.hubGetPortStatus(driver, hub_slot, port, &st)) return;
        const status = rd16(&st, 0);
        const change = rd16(&st, 2);
        if (change & 0x01 != 0) self.hubClearPortFeature(driver, hub_slot, port, hub_c_port_connection) catch {};
        if (change & 0x02 != 0) self.hubClearPortFeature(driver, hub_slot, port, hub_c_port_enable) catch {};
        if (change & 0x04 != 0) self.hubClearPortFeature(driver, hub_slot, port, hub_c_port_suspend) catch {};
        if (change & 0x08 != 0) self.hubClearPortFeature(driver, hub_slot, port, hub_c_port_over_current) catch {};
        if (change & 0x10 != 0) self.hubClearPortFeature(driver, hub_slot, port, hub_c_port_reset) catch {};

        const connected = status & 0x01 != 0;
        const child = self.childAt(hub_slot, port);
        if (child != 0 and (!connected or change & 0x01 != 0)) self.detachSlot(driver, child);
        if (connected and self.childAt(hub_slot, port) == 0) self.attachHubPort(driver, hub_slot, port) catch {};
    }

    /// Reset a hub port, give its device an address (routed through
    /// the hub) and enumerate it.
    fn attachHubPort(self: *UsbCoreManager, driver: *xhci.XhciDriver, hub_slot: u8, port: u8) anyerror!void {
        xhci.delayMs(debounce_ms);
        try self.hubSetPortFeature(driver, hub_slot, port, hub_port_reset);
        var st: [4]u8 align(4) = undefined;
        var n: u32 = 0;
        while (true) : (n += 1) {
            if (n > 50) return error.PortResetTimeout;
            xhci.delayMs(10);
            if (!self.hubGetPortStatus(driver, hub_slot, port, &st)) return error.PortStatusFailed;
            if (rd16(&st, 2) & 0x10 != 0) break; // C_PORT_RESET: the reset is done
        }
        self.hubClearPortFeature(driver, hub_slot, port, hub_c_port_reset) catch {};
        xhci.delayMs(10); // reset recovery
        const status = rd16(&st, 0);
        if (status & 0x01 == 0) return error.DeviceNotConnected;
        if (status & 0x02 == 0) return error.PortNotEnabled;
        const speed: xhci.PortSpeed = if (status & (1 << 9) != 0) .low else if (status & (1 << 10) != 0) .high else .full;

        const hub = &self.slots[hub_slot];
        const root_port = hub.port;
        const route = hub.route | (@as(u20, port) << @intCast(4 * @as(u32, hub.tier)));
        const tier = hub.tier + 1;
        // Low/full speed below a high-speed hub: that hub's TT;
        // below a full-speed hub: its TT
        var tt_slot: u8 = 0;
        var tt_port: u8 = 0;
        if (speed == .low or speed == .full) {
            if (hub.speed == .high) {
                tt_slot = hub_slot;
                tt_port = port;
            } else {
                tt_slot = hub.tt_slot;
                tt_port = hub.tt_port;
            }
        }

        const slot = try driver.enableSlot();
        errdefer driver.disableSlot(slot) catch {};
        self.slots[slot] = .{};
        const c = &self.slots[slot];
        c.port = root_port;
        c.speed = speed;
        c.parent_slot = hub_slot;
        c.parent_port = port;
        c.route = route;
        c.tier = tier;
        c.tt_slot = tt_slot;
        c.tt_port = tt_port;
        errdefer self.slots[slot] = .{};

        try driver.addressDeviceRouted(slot, root_port, route, speed, tt_slot, tt_port);
        try self.enumerateAndAttachDevice(driver, slot);
    }

    // HUB CLASS REQUESTS

    /// Issues a USB hub class Get_Port_Status request.
    pub fn hubGetPortStatus(self: *UsbCoreManager, driver: *xhci.XhciDriver, slot_id: u8, port_number: u8, dest_buf: []u8) bool {
        if (dest_buf.len < 4) return false;
        self.executeControlTransfer(driver, slot_id, 0xA3, 0x00, 0, port_number, dest_buf.ptr, 4) catch return false;
        return true;
    }

    /// Issues a USB hub class Set_Feature request.
    pub fn hubSetPortFeature(self: *UsbCoreManager, driver: *xhci.XhciDriver, slot_id: u8, port_number: u8, feature_selector: u16) !void {
        try self.executeControlTransfer(driver, slot_id, 0x23, 0x03, feature_selector, port_number, null, 0);
    }

    /// Issues a USB hub class Clear_Feature request.
    pub fn hubClearPortFeature(self: *UsbCoreManager, driver: *xhci.XhciDriver, slot_id: u8, port_number: u8, feature_selector: u16) !void {
        try self.executeControlTransfer(driver, slot_id, 0x23, 0x01, feature_selector, port_number, null, 0);
    }
};
