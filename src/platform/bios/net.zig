// The BIOS edition's network cards (platform.net): Intel e1000
// family cards on PCI (drivers/net/e1000.zig), up to `max`,
// with their wired interrupt (the line the BIOS gave them,
// shared), else polled. No paging: their registers and memory
// are reached at their physical addresses.
const platform = @import("../../platform.zig");
const pci = @import("../../drivers/pcie/pci.zig");
const e1000 = @import("../../drivers/net/e1000.zig");
const memory = @import("memory.zig");
const clock = @import("clock.zig");
const bios = @import("bios.zig");
const net_core = @import("net_core.zig");

const max = 8;
var found: [max]pci.PciDeviceLocation = undefined;
var found_count: usize = 0;
var scanned = false;
var nics: [max]e1000.E1000 = undefined;
var event: platform.IoEvent = .{}; // the cards' interrupts, for the NET task

fn scan() void {
    if (scanned) return;
    scanned = true;
    pci.PciScanner.scanBus(&onPciDevice);
}

fn onPciDevice(d: pci.PciDeviceLocation) void {
    if (found_count < max and d.vendor_id == 0x8086 and e1000.E1000.supports(d.device_id) and d.bar0 != 0 and d.bar0 < 1 << 32) {
        found[found_count] = d;
        found_count += 1;
    }
}

pub fn present() bool {
    scan();
    return found_count > 0;
}

// Card i (0 ...; null: none); its interrupt to the NET task's
// event (core0) or the network core (relay), else polled
pub fn start(i: usize, how: platform.NetInterrupt) ?platform.NetCard {
    scan();
    if (i >= found_count) return null;
    const d = found[i];
    pci.enableMemorySpaceInSegment(d.segment, d.bus, d.slot, d.func);
    pci.enableBusMasterInSegment(d.segment, d.bus, d.slot, d.func);
    const mem = memory.allocPages(e1000.pages, false) orelse return null;
    const nic = &nics[i];
    nic.* = .{ .base = @intCast(d.bar0), .is_82574 = d.device_id == 0x10D3 };
    nic.init(mem, &clock.delayUs) catch {
        memory.freePages(mem, e1000.pages);
        return null;
    };
    const irq = switch (how) {
        .core0 => bios.own_drivers.attachInterrupt(d, &onInterrupt, nic),
        .relay => bios.own_drivers.attachInterrupt(d, &onRelay, nic),
        else => false,
    };
    if (irq) nic.enableInterrupts();
    return .{
        .mac = nic.mac,
        .name = if (nic.is_82574) "Intel 82574 (e1000e)" else "Intel e1000",
        .event = if (irq and how == .core0) &event else null,
        .interrupts = irq,
    };
}

fn onInterrupt(ctx: ?*anyopaque) bool {
    const nic: *const e1000.E1000 = @ptrCast(@alignCast(ctx.?));
    if (!nic.takeCauses()) return false;
    platform.io.signal(&event);
    return true;
}

fn onRelay(ctx: ?*anyopaque) bool {
    const nic: *const e1000.E1000 = @ptrCast(@alignCast(ctx.?));
    if (!nic.takeCauses()) return false;
    net_core.wake();
    return true;
}

// Taken in the interrupt (wired lines): nothing left here
pub fn acknowledge() void {}

pub fn send(i: usize, frame: []const u8) bool {
    return nics[i].send(frame);
}

pub fn receive(i: usize, buf: []u8) ?usize {
    return nics[i].receive(buf);
}

pub fn linkUp(i: usize) bool {
    return nics[i].linkUp();
}

// Every frame, not only its own address's (a bridge's port)
pub fn promiscuous(i: usize) bool {
    nics[i].promiscuous();
    return true;
}
