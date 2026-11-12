// \SYSTEM\DRIVERS\*.SYS on the boot drive, loaded at startup on
// metal and BIOS for the PCI devices their ID tables name.
// One that drives nothing is unloaded again.
const std = @import("std");
const platform = @import("../platform.zig");
const fs = @import("fs.zig");
const con = @import("console.zig");
const loader = @import("loader.zig");
const drv = @import("drv.zig");
const pci = @import("../drivers/pcie/pci.zig");

pub const available = platform.has_own_drivers;
const folder = "\\SYSTEM\\DRIVERS";
const at_ids = 64; // the header's ID table field (sdk/linkers/sys-*.ld)
const max_devices = 64;
// ISA cards (probe drivers, ISA DMA): the BIOS edition only
const isa = @hasDecl(platform.memory, "allocIsaDma");

// The cards drivers registered, for src/net/card.zig
pub const max_net_cards = 8;
pub var net_cards: [max_net_cards]*const drv.NetCard = undefined;
pub var net_card_count: usize = 0;
// net_interrupts' control and device, per card (null: polled)
pub var net_controls: [max_net_cards]?drv.NetControl = @splat(null);
pub var net_devices: [max_net_cards]pci.PciDeviceLocation = undefined;
// The sound card, for sound.zig
pub var sound_card: ?*const drv.SoundCard = null;

var devices: [max_devices]drv.Device = undefined;
var locations: [max_devices]pci.PciDeviceLocation = undefined;
var device_count: usize = 0;
var taken = [_]bool{false} ** max_devices;

pub fn loadAll() void {
    if (!available) return;
    const d = fs.bootDrive() orelse return;
    var path: fs.Path = .{};
    path.set(folder);
    var it = fs.openDir(d, &path) catch return;
    defer it.close();
    device_count = 0;
    pci.PciScanner.scanBus(&found);
    while (it.next() catch null) |e| {
        const name = e.name();
        if (!std.ascii.endsWithIgnoreCase(name, ".SYS")) continue;
        var buf: [fs.max_path]u8 = undefined;
        const file = std.fmt.bufPrint(&buf, "{s}\\{s}", .{ folder, name }) catch continue;
        loadOne(d, file, name);
    }
}

fn found(p: pci.PciDeviceLocation) void {
    if (device_count == max_devices) return;
    var dev: drv.Device = .{
        .segment = p.segment,
        .bus = p.bus,
        .slot = p.slot,
        .func = p.func,
        .vendor = p.vendor_id,
        .device = p.device_id,
        .class = p.class_id,
        .subclass = p.subclass_id,
        .prog_if = p.prog_if,
        .bars = undefined,
    };
    for (&dev.bars, 0..) |*b, i| {
        b.* = p.readBar(@intCast(i));
        // I/O BARs keep bit 0, as drv.Device says (readBar drops it)
        const raw = pci.pciReadConfigDwordInSegment(p.segment, p.bus, p.slot, p.func, 0x10 + @as(u16, @intCast(i)) * 4);
        if (raw != 0xFFFF_FFFF and raw & 1 != 0) b.* |= 1;
    }
    devices[device_count] = dev;
    locations[device_count] = p;
    device_count += 1;
}

fn loadOne(d: *const fs.Drive, file: []const u8, name: []const u8) void {
    const img = loader.loadImage(d, file, loader.driver_magic) catch |err| {
        con.printf("Drivers: {s}: {s}\n", .{ name, @errorName(err) });
        return;
    };
    const ids_at = img.field(at_ids);
    if (ids_at == 0 or ids_at >= img.header.end) {
        img.free();
        return;
    }
    const ids: [*]const drv.PciId = @ptrFromInt(img.base() + @as(usize, @intCast(ids_at)));
    const init: drv.Init = @ptrFromInt(img.base() + @as(usize, @intCast(img.header.entry)));
    var used = false;
    if (isa and probes(ids, img.header.end - ids_at)) {
        const none: drv.Device = .{ .segment = 0, .bus = 0, .slot = 0, .func = 0, .vendor = drv.probe_vendor, .device = 0, .class = 0, .subclass = 0, .prog_if = 0, .bars = @splat(0) };
        if (init(&api, &none)) {
            used = true;
            con.printf("Drivers: {s}\n", .{name});
        }
    }
    for (devices[0..device_count], 0..) |*dev, i| {
        if (taken[i] or !matches(ids, img.header.end - ids_at, dev)) continue;
        if (!init(&api, dev)) continue;
        taken[i] = true;
        used = true;
        con.printf("Drivers: {s} for {X:0>4}:{X:0>4}\n", .{ name, dev.vendor, dev.device });
    }
    if (!used) img.free();
}

// An entry for hardware without a PCI device (drv.probe_vendor)
fn probes(ids: [*]const drv.PciId, room: u64) bool {
    const max: usize = @intCast(@min(room / @sizeOf(drv.PciId), 256));
    for (ids[0..max]) |id| {
        if (id.vendor == 0) return false;
        if (id.vendor == drv.probe_vendor) return true;
    }
    return false;
}

fn matches(ids: [*]const drv.PciId, room: u64, dev: *const drv.Device) bool {
    const max: usize = @intCast(@min(room / @sizeOf(drv.PciId), 256));
    for (ids[0..max]) |id| {
        if (id.vendor == 0) return false;
        if (id.vendor == dev.vendor and id.device == dev.device) return true;
        if (id.vendor == drv.any_vendor and id.device == @as(u16, dev.class) << 8 | dev.subclass) return true;
    }
    return false;
}

// THE DRIVER INTERFACE

const api: drv.Api = .{
    .slots = drv.slotsOf(drv.Api),
    .log = log,
    .millis = millis,
    .delay_us = delayUs,
    .alloc_pages = allocPages,
    .free_pages = freePages,
    .map_device = mapDevice,
    .pci_read = pciRead,
    .pci_write = pciWrite,
    .pci_enable = pciEnable,
    .read_file = readFile,
    .register_net = registerNet,
    .register_sound = registerSound,
    .alloc_isa_dma = allocIsaDma,
    .attach_interrupt = attachInterrupt,
    .net_interrupts = netInterrupts,
};

// The PCI device a driver was started for
fn locationOf(dev: *const drv.Device) ?pci.PciDeviceLocation {
    const at = @intFromPtr(dev);
    const first = @intFromPtr(&devices[0]);
    if (at < first or at >= first + device_count * @sizeOf(drv.Device)) return null;
    const i = (at - first) / @sizeOf(drv.Device);
    if (dev.vendor == drv.probe_vendor) return null;
    return locations[i];
}

// INTERRUPTS
const Attached = struct { handler: drv.InterruptHandler, ctx: ?*anyopaque };
var attached: [8]Attached = undefined;
var attached_count: usize = 0;

fn runAttached(ctx: ?*anyopaque) bool {
    const a: *const Attached = @ptrCast(@alignCast(ctx.?));
    return a.handler(a.ctx);
}

fn attachInterrupt(dev: *const drv.Device, handler: drv.InterruptHandler, ctx: ?*anyopaque) callconv(drv.cc) bool {
    if (!@hasDecl(platform.own_drivers, "attachInterrupt")) return false;
    const loc = locationOf(dev) orelse return false;
    if (attached_count == attached.len) return false;
    const a = &attached[attached_count];
    a.* = .{ .handler = handler, .ctx = ctx };
    if (!platform.own_drivers.attachInterrupt(loc, &runAttached, a)) return false;
    attached_count += 1;
    return true;
}

fn netInterrupts(card: *const drv.NetCard, dev: *const drv.Device, control: drv.NetControl) callconv(drv.cc) bool {
    if (!@hasDecl(platform.own_drivers, "attachInterrupt")) return false;
    const loc = locationOf(dev) orelse return false;
    for (net_cards[0..net_card_count], 0..) |c, i| {
        if (c != card) continue;
        net_controls[i] = control;
        net_devices[i] = loc;
        return true;
    }
    return false;
}

fn allocIsaDma(count: usize) callconv(drv.cc) ?[*]align(4096) u8 {
    if (comptime isa) {
        if (count == 0 or count > 16) return null;
        const p = platform.memory.allocIsaDma(count) orelse return null;
        @memset(p[0 .. count * 4096], 0);
        return p;
    } else return null;
}

fn log(text: [*]const u8, len: usize) callconv(drv.cc) void {
    con.print(text[0..len]);
}

fn millis() callconv(drv.cc) u64 {
    return platform.clock.millis();
}

fn delayUs(us: u32) callconv(drv.cc) void {
    platform.clock.delayUs(us);
}

fn allocPages(count: usize) callconv(drv.cc) ?[*]align(4096) u8 {
    const p = platform.memory.allocPages(count, false) orelse return null;
    @memset(p[0 .. count * 4096], 0);
    return p;
}

fn freePages(pages: [*]align(4096) u8, count: usize) callconv(drv.cc) void {
    platform.memory.freePages(pages, count);
}

fn mapDevice(phys: u64, len: u64) callconv(drv.cc) bool {
    return platform.own_drivers.mapDevice(phys, len);
}

fn pciRead(dev: *const drv.Device, offset: u16) callconv(drv.cc) u32 {
    return pci.pciReadConfigDwordInSegment(dev.segment, dev.bus, dev.slot, dev.func, offset);
}

fn pciWrite(dev: *const drv.Device, offset: u16, value: u32) callconv(drv.cc) void {
    pci.pciWriteConfigDwordInSegment(dev.segment, dev.bus, dev.slot, dev.func, offset, value);
}

// Command register: I/O space (bit 0), memory space (1), bus master (2)
fn pciEnable(dev: *const drv.Device) callconv(drv.cc) void {
    const cmd = pciRead(dev, 0x04);
    pciWrite(dev, 0x04, (cmd & 0xFFFF) | 0x7);
}

fn readFile(name: [*]const u8, len: usize, buf: [*]u8, max: usize) callconv(drv.cc) i64 {
    const d = fs.bootDrive() orelse return -1;
    var pb: [fs.max_path]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}\\{s}", .{ folder, name[0..len] }) catch return -1;
    const f = fs.openFile(d, path, .read) catch return -1;
    defer fs.close(f);
    var got: usize = 0;
    while (got < max) {
        const n = platform.storage.read(f, buf[got..max]) catch return -1;
        if (n == 0) break;
        got += n;
    }
    return @intCast(got);
}

fn registerSound(card: *const drv.SoundCard) callconv(drv.cc) bool {
    if (sound_card != null) return false;
    sound_card = card;
    return true;
}

fn registerNet(card: *const drv.NetCard) callconv(drv.cc) bool {
    for (net_cards[0..net_card_count]) |c| {
        if (c == card) return true; // the same card again
    }
    if (net_card_count == max_net_cards) return false;
    net_cards[net_card_count] = card;
    net_card_count += 1;
    return true;
}
