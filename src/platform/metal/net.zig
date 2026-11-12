// The metal editions' network cards
// (platform.net), up to `max`: Intel e1000
// family (drivers/net/e1000.zig),
// virtio-net (drivers/virtio/net.zig) and
// Amazon ENA (drivers/net/ena.zig, polled).
// Interrupts by MSI-X / MSI where the card
// has them (QEMU's e1000 doesn't: then the
// network task looks every 2 ms); on ARM64
// core 0 takes them for the network core.
const std = @import("std");
const platform = @import("../../platform.zig");
const pci = @import("../../drivers/pcie/pci.zig");
const e1000 = @import("../../drivers/net/e1000.zig");
const virtio = @import("../../drivers/virtio/virtio.zig");
const vnet = @import("../../drivers/virtio/net.zig");
const ena = @import("../../drivers/net/ena.zig");
const msi = @import("msi.zig");
const memory = @import("memory.zig");
const clock = @import("clock.zig");
const console = @import("console.zig");

const max = 8;
const Kind = enum { e1000, virtio, ena };
const Found = struct { kind: Kind, dev: pci.PciDeviceLocation, regs: virtio.Regions = .{} };
var found: [max]Found = undefined;
var found_count: usize = 0;
const Nic = union(Kind) { e1000: e1000.E1000, virtio: vnet.Net, ena: ena.Ena };
var nics: [max]Nic = undefined;
var started: [max]bool = @splat(false);
var event: platform.IoEvent = .{}; // every card's interrupt

// While the firmware's mapping is still
// built (before paging.configure):
// the cards' registers get mapped (virtio's
// and ENA's BARs may be above 4 GiB)
pub fn probe() void {
    pci.PciScanner.scanBus(&onPciDevice);
    for (found[0..found_count]) |f| switch (f.kind) {
        .e1000 => memory.addDevice(f.dev.bar0, e1000.bar_span),
        .virtio => {
            for (f.regs.bar_start, f.regs.bar_end) |s, e| {
                if (e > s) memory.addDevice(s, e - s);
            }
            mapMsixTable(f.dev);
        },
        .ena => {
            memory.addDevice(f.dev.bar0, ena.reg_span);
            const mem_bar = f.dev.readBar(ena.mem_bar_index);
            if (mem_bar != 0) memory.addDevice(mem_bar, ena.mem_bar_span);
        },
    };
}

// msi.attach maps the table once cards
// start, which is late for own page tables
fn mapMsixTable(d: pci.PciDeviceLocation) void {
    const info = pci.getMsixInfo(d.segment, d.bus, d.slot, d.func) orelse return;
    const bar = d.readBar(info.table_bir);
    if (bar != 0) memory.addDevice(bar, std.mem.alignForward(usize, info.table_offset + @as(usize, info.table_size) * 16, 4096));
}

pub fn present() bool {
    return found_count > 0;
}

fn onPciDevice(d: pci.PciDeviceLocation) void {
    if (found_count == max) return;
    if (d.vendor_id == 0x8086 and e1000.E1000.supports(d.device_id) and d.bar0 != 0) {
        found[found_count] = .{ .kind = .e1000, .dev = d };
    } else if (virtio.isNet(d)) {
        // Legacy-only (no modern registers): not supported
        found[found_count] = .{ .kind = .virtio, .dev = d, .regs = virtio.findRegions(d) orelse return };
    } else if (ena.supports(d.vendor_id, d.device_id) and d.bar0 != 0) {
        found[found_count] = .{ .kind = .ena, .dev = d };
    } else return;
    found_count += 1;
}

// Card i (0 ...; null: none): its interrupt to core 0,
// as a message elsewhere (the network core's; then it
// isn't acknowledged here: acknowledge), or none
pub fn start(i: usize, how: platform.NetInterrupt) ?platform.NetCard {
    if (i >= found_count) return null;
    const f = found[i];
    const d = f.dev;
    pci.enableMemorySpaceInSegment(d.segment, d.bus, d.slot, d.func);
    pci.enableBusMasterInSegment(d.segment, d.bus, d.slot, d.func);
    switch (f.kind) {
        .e1000 => {
            const mem = memory.allocPages(e1000.pages, false) orelse return null;
            nics[i] = .{ .e1000 = .{ .base = @intCast(d.bar0), .is_82574 = d.device_id == 0x10D3 } };
            const nic = &nics[i].e1000;
            nic.init(mem, &clock.delayUs) catch {
                memory.freePages(mem, e1000.pages);
                return null;
            };
            started[i] = true;
            const irq = attach(d, how, &nics[i]);
            if (irq) nic.enableInterrupts();
            return .{
                .mac = nic.mac,
                .name = if (nic.is_82574) "Intel 82574 (e1000e)" else "Intel e1000",
                .event = if (irq and how == .core0) &event else null,
                .interrupts = irq,
            };
        },
        .virtio => {
            const mem = memory.allocPages(vnet.pages, false) orelse return null;
            nics[i] = .{ .virtio = .{ .dev = .{ .regs = f.regs } } };
            const nic = &nics[i].virtio;
            // Its message before the queues are
            // made with it (virtio has only MSI-X)
            const msix = pci.getMsixInfo(d.segment, d.bus, d.slot, d.func) != null and attach(d, how, &nics[i]);
            nic.init(mem, &clock.delayUs, if (msix) 0 else virtio.no_vector) catch {
                memory.freePages(mem, vnet.pages);
                return null;
            };
            started[i] = true;
            const irq = nic.irq();
            return .{
                .mac = nic.mac,
                .name = "virtio-net",
                .event = if (irq and how == .core0) &event else null,
                .interrupts = irq,
            };
        },
        .ena => {
            const mem = memory.allocPages(ena.pages, false) orelse return null;
            // The revision's bit 0: registers read directly, not through DMA
            const revision: u8 = @truncate(pci.pciReadConfigDwordInSegment(d.segment, d.bus, d.slot, d.func, 0x08));
            nics[i] = .{ .ena = .{ .base = @intCast(d.bar0), .mem_bar = @intCast(d.readBar(ena.mem_bar_index)), .revision = revision } };
            const nic = &nics[i].ena;
            nic.init(mem, &clock.delayUs) catch |err| {
                memory.freePages(mem, ena.pages);
                var buf: [64]u8 = undefined;
                console.write(std.fmt.bufPrint(&buf, "Amazon ENA: not started ({s})\n", .{@errorName(err)}) catch return null);
                return null;
            };
            started[i] = true;
            return .{ .mac = nic.mac, .name = "Amazon ENA", .event = null, .interrupts = false };
        },
    }
}

fn attach(d: pci.PciDeviceLocation, how: platform.NetInterrupt, nic: *Nic) bool {
    return switch (how) {
        .core0 => msi.attach(d, &onInterrupt, nic),
        .message => |m| msi.attachMessage(d, m.address, m.data),
        // An ITS's LPI straight to the network core, else core 0 relays:
        .relay => (if (platform.net_core.coreIndex()) |c| msi.attachTo(d, c) else false) or msi.attach(d, &onRelay, nic),
        .none => false,
    };
}

// The network core's acknowledgement of the
// cards' interrupt (e1000: reading their causes;
// virtio's MSI-X needs none)
pub fn acknowledge() void {
    for (nics[0..found_count], started[0..found_count]) |*n, s| {
        if (s and n.* == .e1000) n.e1000.acknowledge();
    }
}

fn onInterrupt(ctx: ?*anyopaque) void {
    const nic: *Nic = @ptrCast(@alignCast(ctx.?));
    if (nic.* == .e1000) nic.e1000.acknowledge();
    platform.io.signal(&event);
}

// On core 0, for the network core (ARM64):
fn onRelay(ctx: ?*anyopaque) void {
    const nic: *Nic = @ptrCast(@alignCast(ctx.?));
    if (nic.* == .e1000) nic.e1000.acknowledge();
    platform.net_core.wake();
}

pub fn send(i: usize, frame: []const u8) bool {
    return switch (nics[i]) {
        inline else => |*n| n.send(frame),
    };
}

pub fn receive(i: usize, buf: []u8) ?usize {
    return switch (nics[i]) {
        inline else => |*n| n.receive(buf),
    };
}

pub fn linkUp(i: usize) bool {
    return switch (nics[i]) {
        inline else => |*n| n.linkUp(),
    };
}

// Every frame, not only its own address's (a bridge's port)
pub fn promiscuous(i: usize) bool {
    return switch (nics[i]) {
        .e1000 => |*n| blk: {
            n.promiscuous();
            break :blk true;
        },
        inline else => |*n| n.promiscuous(),
    };
}
