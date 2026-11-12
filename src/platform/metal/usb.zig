// USB for the metal editions: every xHCI controller
// on PCI (drivers/usb), polled when the console
// looks for keys; once tasks switch, interrupts
// wake waiting tasks, and the task IRQ
// (deferred work) takes keyboards' and mice's reports
// (a release counts even while ZDOS is busy drawing),
// and devices plugged in or pulled out wake the
// hot-plug task (startHotplug).
// Keyboards and mice report to keyboard.zig.
const platform = @import("../../platform.zig");
const msi = @import("msi.zig");
const std = @import("std");
const pci = @import("../../drivers/pcie/pci.zig");
const usb = @import("../../drivers/usb/usbcore.zig");
const xhci = usb.xhci;
const acpi = @import("acpi.zig");
const clock = @import("clock.zig");
const memory = @import("memory.zig");
const keyboard = @import("keyboard.zig");

const max_controllers = 4;
// What own page tables map of a controller's registers (BAR 0):
// more than any xHCI's register space
pub const bar_span = 1 << 20;

// A controller: its driver state (about 400
// KB, at a fixed address: the controller reads
// it) and its devices
const Controller = struct {
    drv: *xhci.XhciDriver,
    mgr: *usb.UsbCoreManager,
    dev: pci.PciDeviceLocation,
    ev: platform.IoEvent = .{},
    work: platform.Work = .{ .func = &takeEvents },
};

var controllers: [max_controllers]Controller = undefined;
var controller_count: usize = 0;

// The xHCI controllers PCI lists, before they are started
var found: [max_controllers]pci.PciDeviceLocation = undefined;
var found_count: usize = 0;

// After leaving the firmware: its own USB driver no longer
// runs the controllers. Each controller and device is
// reported through write.
pub fn init(write: *const fn ([]const u8) void) void {
    acpi.ecamRegions(&addEcam);
    xhci.delayUsFn = &clock.delayUs;
    usb.UsbCoreManager.on_key_event = &onKey;
    usb.UsbCoreManager.lock_state = &keyboard.lockState;
    usb.UsbCoreManager.on_mouse = &onMouse;

    found_count = 0;
    pci.PciScanner.scanBus(&onPciDevice);
    if (found_count == 0) return write("USB: no xHCI controller\n");
    for (found[0..found_count], 1..) |dev, number| {
        var buf: [96]u8 = undefined;
        start(dev) catch |err| {
            write(std.fmt.bufPrint(&buf, "USB controller {d}: not started ({s})\n", .{ number, @errorName(err) }) catch continue);
            continue;
        };
        list(write, controller_count - 1, number);
    }
}

fn onPciDevice(d: pci.PciDeviceLocation) void {
    // Serial bus (0x0C) / USB (0x03) / xHCI programming interface (0x30)
    if (d.class_id == 0x0C and d.subclass_id == 0x03 and d.prog_if == 0x30 and found_count < max_controllers) {
        found[found_count] = d;
        found_count += 1;
    }
}

fn start(dev: pci.PciDeviceLocation) !void {
    if (dev.bar0 == 0) return error.BarNotAssigned;
    const drv_pages = (@sizeOf(xhci.XhciDriver) + 4095) / 4096;
    const mgr_pages = (@sizeOf(usb.UsbCoreManager) + 4095) / 4096;
    const drv_mem = memory.allocPages(drv_pages, false) orelse return error.OutOfMemory;
    errdefer memory.freePages(drv_mem, drv_pages);
    const mgr_mem = memory.allocPages(mgr_pages, false) orelse return error.OutOfMemory;
    errdefer memory.freePages(mgr_mem, mgr_pages);
    const drv: *xhci.XhciDriver = @ptrCast(drv_mem);
    const mgr: *usb.UsbCoreManager = @ptrCast(mgr_mem);
    // Field by field: the whole default
    // value would be built on the stack first
    for (&mgr.slots) |*s| s.* = .{};
    @memset(&mgr.port_slot, 0);

    pci.enableMemorySpaceInSegment(dev.segment, dev.bus, dev.slot, dev.func);
    pci.enableBusMasterInSegment(dev.segment, dev.bus, dev.slot, dev.func); // xHCI is a DMA master
    memory.addDevice(dev.bar0, bar_span);
    drv.init(@intCast(dev.bar0)); // the firmware's identity mapping covers the BAR
    try drv.setupAndStart();
    mgr.scanPorts(drv);
    controllers[controller_count] = .{ .drv = drv, .mgr = mgr, .dev = dev };
    controllers[controller_count].work.ctx = &controllers[controller_count];
    controller_count += 1;
}

// Each controller's interrupt (MSI-X / MSI):
// events wake the waiting task
pub fn startInterrupts() void {
    for (controllers[0..controller_count]) |*c| {
        if (!msi.attach(c.dev, &onInterrupt, c)) continue;
        c.drv.wait_ctx = c;
        c.drv.wait_hook = &waitHook;
        c.drv.enableInterrupts();
    }
}

// Code using the controllers is running (poll,
// a USB disk's transfer; under the kernel lock,
// so one at a time, on any core): the deferred
// interrupt work then leaves the events to it, and
// never waits for it. Such code waits only while
// that work drains: spinning a little, then
// sleeping until it lets go (it runs in a task,
// which a higher priority may preempt).
const free = 0;
const in_interrupt = 1;
const in_code = 2;
var owner = std.atomic.Value(u32).init(free);
var depth: u32 = 0; // nested enters of the code holding the controllers

pub fn enter() void {
    if (depth > 0) {
        depth += 1;
        return;
    }
    var spins: u32 = 0;
    while (owner.cmpxchgWeak(free, in_code, .acquire, .monotonic) != null) {
        spins += 1;
        if (spins < 2000 or platform.io.wait == null) {
            std.atomic.spinLoopHint();
            continue;
        }
        _ = platform.io.wait.?(&released, released.count, 1000);
    }
    depth = 1;
}

// The deferred work let go of the controllers (enter's sleepers)
var released: platform.IoEvent = .{};

pub fn leave() void {
    depth -= 1;
    if (depth > 0) return;
    // A change the code's waits took from the event ring:
    // the interrupt didn't see it
    const news = hotplug_wake != null and topologyPending();
    owner.store(free, .release);
    if (news) hotplug_wake.?();
}

// Devices coming and going are the
// hot-plug task's (storage.zig): wake is
// called (from the interrupt too) when a
// controller has such news
var hotplug_wake: ?*const fn () void = null;

pub fn startHotplug(wake: *const fn () void) void {
    usb.UsbCoreManager.topology_elsewhere = true;
    usb.UsbCoreManager.debounce_ms = 0; // the task has waited (without the controllers)
    hotplug_wake = wake;
}

// Held by the caller (enter, or the interrupt)
fn topologyPending() bool {
    for (controllers[0..controller_count]) |c| {
        if (c.mgr.topologyPending(c.drv)) return true;
    }
    return false;
}

// The task's work: ports' and hubs' changes
// (enumeration and all); enter is the caller's
pub fn processTopology() void {
    for (controllers[0..controller_count]) |c| {
        c.drv.drainEvents();
        c.mgr.processTopology(c.drv);
    }
}

// The interrupt: acknowledged, waiters woken;
// the events are deferred work
fn onInterrupt(ctx: ?*anyopaque) void {
    const c: *Controller = @ptrCast(@alignCast(ctx.?));
    c.drv.acknowledgeInterrupt();
    platform.io.signal(&c.ev);
    platform.io.deferWork(&c.work);
}

// In the task IRQ (or the interrupt, before tasks): the event
// ring and the keyboards' and mice's reports, unless code holds
// the controllers (it takes them itself)
fn takeEvents(ctx: ?*anyopaque) void {
    const c: *Controller = @ptrCast(@alignCast(ctx.?));
    if (owner.cmpxchgStrong(free, in_interrupt, .acquire, .monotonic) != null) return;
    c.drv.drainEvents();
    c.mgr.processInput(c.drv);
    const news = hotplug_wake != null and c.mgr.topologyPending(c.drv);
    owner.store(free, .release);
    signalReleased();
    if (news) hotplug_wake.?();
}

fn signalReleased() void {
    const s = platform.switching.disable();
    defer platform.switching.restore(s);
    platform.io.signal(&released);
}

fn waitHook(ctx: *anyopaque) u32 {
    const c: *Controller = @ptrCast(@alignCast(ctx));
    return platform.io.waitFor(&c.ev, &clock.delayUs);
}

// Whether a mouse is plugged in (also as part of a composite device)
pub fn hasMouse() bool {
    for (controllers[0..controller_count]) |c| {
        // By pointer: by value the whole array (160 KB) is copied onto
        // the stack first, past the end of a thread's
        for (&c.mgr.slots) |*s| {
            for (s.interfaces[0..@min(s.interface_count, s.interfaces.len)]) |i| {
                if (i == .mouse) return true;
            }
            if (s.device_type == .mouse) return true;
        }
    }
    return false;
}

pub fn poll() void {
    enter();
    defer leave();
    for (controllers[0..controller_count]) |c| {
        c.drv.pollEvents(c.mgr);
        c.mgr.updateLeds(c.drv);
    }
}

// A USB mass storage device (disks.zig): its controller,
// slot and interface, and its enumeration,
// so a device later in the same slot isn't taken for it
pub const StorageRef = struct {
    controller: usize,
    slot: u8,
    iface: u8,
    attach_id: u32,
};

// Who a device is, to know a stick plugged in again: vendor,
// product and serial number (if it has one) and its size
pub const StorageId = struct {
    vendor: u16 = 0,
    product: u16 = 0,
    serial: [32]u8 = @splat(0),
    blocks: u64 = 0,

    pub fn eql(a: *const StorageId, b: *const StorageId) bool {
        return a.vendor == b.vendor and a.product == b.product and a.blocks == b.blocks and std.mem.eql(u8, &a.serial, &b.serial);
    }
};

pub fn storageId(ref: StorageRef) StorageId {
    const t = &controllers[ref.controller].mgr.slots[ref.slot];
    var id: StorageId = .{ .vendor = t.vendor_id, .product = t.product_id };
    const serial = std.mem.sliceTo(&t.serial_number, 0);
    const n = @min(serial.len, id.serial.len);
    @memcpy(id.serial[0..n], serial[0..n]);
    if (storageOf(ref)) |s| id.blocks = s.dev.block_count;
    return id;
}

// The mass storage devices attached now whose capacity is known
pub fn storageDevices(out: []StorageRef) usize {
    var n: usize = 0;
    for (controllers[0..controller_count], 0..) |c, ci| {
        var s: u8 = 1;
        while (s <= xhci.MaxSlots) : (s += 1) {
            const t = &c.mgr.slots[s];
            if (t.port == 0) continue;
            for (t.interfaces[0..t.interface_count], 0..) |*i, k| {
                if (i.* != .storage or i.storage.block_count == 0 or n == out.len) continue;
                out[n] = .{ .controller = ci, .slot = s, .iface = @intCast(k), .attach_id = t.attach_id };
                n += 1;
            }
        }
    }
    return n;
}

// The device's driver and its controller's, if it is still attached
pub fn storageOf(ref: StorageRef) ?struct { dev: *usb.storage.UsbStorageDriver, drv: *xhci.XhciDriver } {
    if (ref.controller >= controller_count) return null;
    const c = controllers[ref.controller];
    const t = &c.mgr.slots[ref.slot];
    if (t.port == 0 or t.attach_id != ref.attach_id or ref.iface >= t.interface_count) return null;
    const i = &t.interfaces[ref.iface];
    if (i.* != .storage) return null;
    return .{ .dev = &i.storage, .drv = c.drv };
}

// One line per device of controller i ("USB 5.1: keyboard (QEMU
// USB Keyboard)"), and one per root
// port whose device couldn't be set up
fn list(write: *const fn ([]const u8) void, i: usize, number: usize) void {
    const c = controllers[i];
    var buf: [160]u8 = undefined;
    if (found_count > 1) write(std.fmt.bufPrint(&buf, "USB controller {d}:\n", .{number}) catch "");
    var port: u8 = 1;
    while (port <= c.drv.max_ports) : (port += 1) {
        if (c.drv.portStatus(port) & xhci.PORTSC_CCS == 0) continue;
        if (c.mgr.port_slot[port] == 0) {
            write(std.fmt.bufPrint(&buf, "USB {d}: a device that could not be set up\n", .{port}) catch continue);
            continue;
        }
        listTree(write, c.mgr, c.mgr.port_slot[port]);
    }
}

// A device and, for a hub, what is behind it
fn listTree(write: *const fn ([]const u8) void, mgr: *usb.UsbCoreManager, slot: u8) void {
    const t = &mgr.slots[slot];
    var where: [32]u8 = undefined;
    var buf: [160]u8 = undefined;
    write(std.fmt.bufPrint(&buf, "USB {s}: {s} ({s})\n", .{ path(&where, t), @tagName(t.device_type), std.mem.sliceTo(&t.product, 0) }) catch return);
    if (t.hub_ports == 0) return;
    var s: u8 = 1;
    while (s <= xhci.MaxSlots) : (s += 1) {
        const child = &mgr.slots[s];
        if (child.port != 0 and child.parent_slot == slot) listTree(write, mgr, s);
    }
}

// "5", or "5.1.3": the root port, then
// the hub ports from the route string
fn path(buf: []u8, t: *const usb.DeviceSlotTracker) []const u8 {
    var len = (std.fmt.bufPrint(buf, "{d}", .{t.port}) catch return "?").len;
    for (0..t.tier) |i| {
        const hub_port = (t.route >> @intCast(4 * i)) & 0xF;
        len += (std.fmt.bufPrint(buf[len..], ".{d}", .{hub_port}) catch break).len;
    }
    return buf[0..len];
}

// The ECAM base in MCFG is that of bus 0;
// pci.zig wants that of start_bus. The firmware's
// identity mapping covers it.
fn addEcam(base: u64, segment: u16, start_bus: u8, end_bus: u8) void {
    memory.addDevice(base + (@as(u64, start_bus) << 20), (@as(u64, end_bus) - start_bus + 1) << 20);
    _ = pci.registerEcamRegion(.{
        .segment = segment,
        .start_bus = start_bus,
        .end_bus = end_bus,
        .virtual_base = @intCast(base + (@as(u64, start_bus) << 20)),
    });
}

fn onKey(e: usb.keyboard.ZdosKeyEvent) void {
    keyboard.feed(e.code, e.pressed);
}

// USB wheels count away from the user, ZDOS's toward
fn onMouse(m: usb.mouse.ZdosMouse) void {
    keyboard.feedMouse(m.dx, m.dy, -m.wheel, m.buttons);
}
