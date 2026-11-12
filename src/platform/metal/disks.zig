// Disks of the metal editions: NVMe, AHCI, virtio-blk
// and USB mass storage. All are offered in 512-byte
// sectors whatever the device block size, through a
// page-aligned bounce buffer (which also hides the
// drivers' alignment rules); partial-block writes read
// the block first. Once tasks switch, NVMe, AHCI and
// virtio completions raise an interrupt (platform.io).
// USB disks come and go (update); one pulled out keeps
// its entry, for when it comes back.
const std = @import("std");
const uefi = std.os.uefi;
const platform = @import("../../platform.zig");
const pci = @import("../../drivers/pcie/pci.zig");
const nvme = @import("../../drivers/pcie/nvme.zig");
const ahci = @import("../../drivers/pcie/ahci.zig");
const virtio = @import("../../drivers/virtio/virtio.zig");
const vblk = @import("../../drivers/virtio/blk.zig");
const memory = @import("memory.zig");
const clock = @import("clock.zig");
const usb = @import("usb.zig");
const msi = @import("msi.zig");

pub const sector_size = 512;
pub const max_disks = 16;
const max_controllers = 4;
const bounce_size = 64 * 1024;

pub const Disk = struct {
    dev: union(enum) {
        nvme: *nvme.NvmeDriver,
        sata: struct { drv: *ahci.AhciDriver, port: u5 },
        virtio: *vblk.Blk,
        usb: usb.StorageRef,
    },
    block_size: u32, // the device's
    sectors: u64, // of 512 bytes
    removable: bool = false,
    read_only: bool = false,
    // USB: who it is, whether its device is attached (as update
    // last saw it), and whether EJECT let it go
    id: usb.StorageId = .{},
    attached: bool = true,
    ejected: bool = false,
};

pub var list: [max_disks]Disk = undefined;
pub var count: usize = 0;

var bounce: []align(4096) u8 = &.{};

// The partition the firmware loaded ZDOS from, to mark
// the boot volume: its start and length in sectors (0:
// unknown) and its signature, which tells it from a
// partition of another disk at the same place: GPT, the
// partition's unique GUID; MBR, the disk's 32-bit
// signature (sector 0, byte
// 440)
var boot_start: u64 = 0;
var boot_sectors: u64 = 0;
var boot_signature: [16]u8 = undefined;
var boot_signature_type: u8 = 0; // 0 none, 1 MBR, 2 GPT

// While the firmware runs: the boot partition, from the device
// path of the device ZDOS was loaded from (a Hard Drive node:
// start at byte 8, length at 16,
// signature at 24, its type at 41)
pub fn captureBootPartition() void {
    const bs = uefi.system_table.boot_services.?;
    var ptr: ?*anyopaque = null;
    if (bs.handleProtocol(uefi.handle, &uefi.protocol.LoadedImage.guid, &ptr) != .success) return;
    const image: *const uefi.protocol.LoadedImage = @ptrCast(@alignCast(ptr.?));
    const device = image.device_handle orelse return;
    if (bs.handleProtocol(device, &uefi.protocol.DevicePath.guid, &ptr) != .success) return;
    var node: [*]const u8 = @ptrCast(ptr.?);
    var n: usize = 0;
    while (n < 64) : (n += 1) {
        const kind = node[0];
        const subtype = node[1];
        const len = std.mem.readInt(u16, node[2..4], .little);
        if (kind == 0x7F or len < 4) return; // the end
        if (kind == 4 and subtype == 1 and len >= 42) {
            boot_start = std.mem.readInt(u64, node[8..16], .little);
            boot_sectors = std.mem.readInt(u64, node[16..24], .little);
            boot_signature = node[24..40].*;
            boot_signature_type = node[41];
            return;
        }
        node += len;
    }
}

// After USB is started: every disk, in the order NVMe,
// SATA, virtio, USB. Each is reported through report.
pub fn init(report: *const fn ([]const u8) void) void {
    nvme.delayUsFn = &clock.delayUs;
    ahci.delayUsFn = &clock.delayUs;
    const mem = memory.allocPages(bounce_size / 4096, false) orelse return report("Disks: not enough memory\n");
    bounce = mem[0..bounce_size];

    found_count = 0;
    pci.PciScanner.scanBus(&onPciDevice);
    for (found[0..found_count]) |f| {
        if (f.kind == .nvme) startNvme(f.dev, report);
    }
    for (found[0..found_count]) |f| {
        if (f.kind == .sata) startAhci(f.dev, report);
    }
    for (found[0..found_count]) |f| {
        if (f.kind == .virtio) startVirtio(f.dev, report);
    }
    var refs: [max_disks]usb.StorageRef = undefined;
    for (refs[0..usb.storageDevices(&refs)]) |ref| {
        const d = usbDisk(ref) orelse continue;
        add(d, d.id.blocks, "USB", report);
    }
}

fn usbDisk(ref: usb.StorageRef) ?Disk {
    const s = usb.storageOf(ref) orelse return null;
    return .{ .dev = .{ .usb = ref }, .block_size = s.dev.block_size, .sectors = 0, .removable = true, .read_only = s.dev.is_write_protected, .id = usb.storageId(ref) };
}

// What update found for a disk
pub const Change = enum { none, gone, back, new };

// After USB devices came or went (the hot-plug
// task, controllers entered): disks pulled out
// are marked gone; a device plugged in is the
// disk it was before (same identity: back), else
// a new one (in a pulled-out one's entry when the
// list is full). changes: by disk index.
pub fn update(changes: *[max_disks]Change) void {
    @memset(changes, .none);
    for (list[0..count], 0..) |*d, i| {
        if (d.dev != .usb or !d.attached or usb.storageOf(d.dev.usb) != null) continue;
        d.attached = false;
        if (!d.ejected) changes[i] = .gone; // EJECT said so already
    }
    var refs: [max_disks]usb.StorageRef = undefined;
    next: for (refs[0..usb.storageDevices(&refs)]) |ref| {
        for (list[0..count]) |*d| {
            if (d.dev == .usb and d.attached and std.meta.eql(d.dev.usb, ref)) continue :next;
        }
        var disk = usbDisk(ref) orelse continue;
        if (disk.block_size < sector_size or disk.block_size > bounce_size or !std.math.isPowerOfTwo(disk.block_size)) continue;
        disk.sectors = disk.id.blocks * (disk.block_size / sector_size);
        var change: Change = .back;
        const i = for (list[0..count], 0..) |*d, k| {
            if (d.dev == .usb and !d.attached and d.id.eql(&disk.id)) break k;
        } else if (count < max_disks) blk: {
            change = .new;
            count += 1;
            break :blk count - 1;
        } else for (list[0..count], 0..) |*d, k| {
            if (d.dev == .usb and !d.attached) break k;
        } else continue;
        list[i] = disk;
        changes[i] = change;
    }
}

// The started controllers, for their interrupts
const Controller = struct {
    dev: pci.PciDeviceLocation,
    drv: union(enum) { nvme: *nvme.NvmeDriver, sata: *ahci.AhciDriver, virtio: *vblk.Blk },
    ev: platform.IoEvent = .{},
};
var controllers: [2 * max_controllers]Controller = undefined;
var controller_count: usize = 0;

// Each controller's interrupt: completions wake the waiting task
pub fn startInterrupts() void {
    for (controllers[0..controller_count]) |*c| {
        switch (c.drv) {
            .nvme => |n| {
                // Its message was set up before it started (startNvme)
                if (!n.cq_irq) continue;
                n.wait_ctx = c;
                n.wait_hook = &waitHook;
            },
            .sata => |a| {
                if (!msi.attach(c.dev, &onInterrupt, c)) continue;
                a.wait_ctx = c;
                a.wait_hook = &waitHook;
                a.enableInterrupts();
            },
            .virtio => |v| {
                if (!v.irq()) continue; // as NVMe's: set up at start
                v.wait_ctx = c;
                v.wait_hook = &waitHook;
            },
        }
    }
}

fn onInterrupt(ctx: ?*anyopaque) void {
    const c: *Controller = @ptrCast(@alignCast(ctx.?));
    if (c.drv == .sata) c.drv.sata.handleInterrupt();
    platform.io.signal(&c.ev);
}

fn waitHook(ctx: *anyopaque) u32 {
    const c: *Controller = @ptrCast(@alignCast(ctx));
    return platform.io.waitFor(&c.ev, &clock.delayUs);
}

const Found = struct { kind: enum { nvme, sata, virtio }, dev: pci.PciDeviceLocation };
var found: [2 * max_controllers]Found = undefined;
var found_count: usize = 0;

fn onPciDevice(d: pci.PciDeviceLocation) void {
    if (found_count == found.len) return;
    if (virtio.isBlk(d)) {
        found[found_count] = .{ .kind = .virtio, .dev = d };
        found_count += 1;
        return;
    }
    if (d.class_id != 0x01) return; // mass storage
    // NVM EXPRESS (08/02), SATA AHCI (06/01)
    if (d.subclass_id == 0x08 and d.prog_if == 0x02) {
        found[found_count] = .{ .kind = .nvme, .dev = d };
    } else if (d.subclass_id == 0x06 and d.prog_if == 0x01) {
        found[found_count] = .{ .kind = .sata, .dev = d };
    } else return;
    found_count += 1;
}

// A disk of `blocks` device blocks into the list, with a line for it
fn add(d: Disk, blocks: u64, what: []const u8, report: *const fn ([]const u8) void) void {
    if (count == max_disks) return;
    if (d.block_size < sector_size or d.block_size > bounce_size or !std.math.isPowerOfTwo(d.block_size)) {
        var buf: [96]u8 = undefined;
        report(std.fmt.bufPrint(&buf, "{s} disk: blocks of {d} bytes are not supported\n", .{ what, d.block_size }) catch return);
        return;
    }
    list[count] = d;
    list[count].sectors = blocks * (d.block_size / sector_size);
    var buf: [96]u8 = undefined;
    const mb = list[count].sectors / 2048;
    report(std.fmt.bufPrint(&buf, "Disk {d}: {s}, {d} MB{s}\n", .{ count, what, mb, if (d.read_only) ", write-protected" else "" }) catch return);
    count += 1;
}

// The driver state lives in allocated pages at a fixed address:
// the controller reads its queues there
fn allocDriver(comptime T: type) ?*T {
    const mem = memory.allocPages((@sizeOf(T) + 4095) / 4096, false) orelse return null;
    return @ptrCast(@alignCast(mem));
}

fn startNvme(dev: pci.PciDeviceLocation, report: *const fn ([]const u8) void) void {
    if (dev.bar0 == 0) return;
    const drv = allocDriver(nvme.NvmeDriver) orelse return;
    pci.enableMemorySpaceInSegment(dev.segment, dev.bus, dev.slot, dev.func);
    pci.enableBusMasterInSegment(dev.segment, dev.bus, dev.slot, dev.func);
    memory.addDevice(dev.bar0, usb.bar_span);
    drv.* = nvme.NvmeDriver.init(@intCast(dev.bar0)); // the firmware's identity mapping covers the BAR
    // Its interrupt (MSI-X entry 0) before the completion queues
    // are made with it: a controller may take only vectors enabled
    // by then (QEMU's does).
    // It is handled once tasks switch (startInterrupts).
    if (controller_count == controllers.len) return;
    const c = &controllers[controller_count];
    c.* = .{ .dev = dev, .drv = .{ .nvme = drv } };
    drv.cq_irq = pci.getMsixInfo(dev.segment, dev.bus, dev.slot, dev.func) != null and msi.attach(dev, &onInterrupt, c);
    drv.setupAndStart() catch |err| {
        var buf: [96]u8 = undefined;
        report(std.fmt.bufPrint(&buf, "NVMe: not started ({s})\n", .{@errorName(err)}) catch return);
        return;
    };
    add(.{ .dev = .{ .nvme = drv }, .block_size = drv.block_size, .sectors = 0 }, drv.total_blocks, "NVMe", report);
    controller_count += 1;
}

fn remember(dev: pci.PciDeviceLocation, drv: @FieldType(Controller, "drv")) void {
    if (controller_count == controllers.len) return;
    controllers[controller_count] = .{ .dev = dev, .drv = drv };
    controller_count += 1;
}

// AHCI's registers are at BAR 5
fn startAhci(dev: pci.PciDeviceLocation, report: *const fn ([]const u8) void) void {
    const bar5 = dev.readBar(5);
    if (bar5 == 0) return;
    const drv = allocDriver(ahci.AhciDriver) orelse return;
    pci.enableMemorySpaceInSegment(dev.segment, dev.bus, dev.slot, dev.func);
    pci.enableBusMasterInSegment(dev.segment, dev.bus, dev.slot, dev.func);
    memory.addDevice(bar5, usb.bar_span);
    drv.* = ahci.AhciDriver.init(@intCast(bar5));
    drv.setupAndStart() catch |err| {
        if (err == error.NoActiveSataDiskFound) return; // an empty controller
        var buf: [96]u8 = undefined;
        report(std.fmt.bufPrint(&buf, "SATA: not started ({s})\n", .{@errorName(err)}) catch return);
        return;
    };
    for (&drv.ports, 0..) |*p, i| {
        const state = if (p.*) |*s| s else continue;
        if (state.device_type != .sata or state.total_sectors == 0) continue;
        add(.{ .dev = .{ .sata = .{ .drv = drv, .port = @intCast(i) } }, .block_size = state.block_size, .sectors = 0 }, state.total_sectors, "SATA", report);
    }
    remember(dev, .{ .sata = drv });
}

// virtio-blk with the modern interface
// (legacy-only devices are not supported)
fn startVirtio(dev: pci.PciDeviceLocation, report: *const fn ([]const u8) void) void {
    const regs = virtio.findRegions(dev) orelse return report("virtio-blk: no virtio 1.0 interface\n");
    if (controller_count == controllers.len) return;
    const drv = allocDriver(vblk.Blk) orelse return;
    const mem = memory.allocPages(vblk.pages, false) orelse return;
    pci.enableMemorySpaceInSegment(dev.segment, dev.bus, dev.slot, dev.func);
    pci.enableBusMasterInSegment(dev.segment, dev.bus, dev.slot, dev.func);
    for (regs.bar_start, regs.bar_end) |s, e| {
        if (e > s) memory.addDevice(s, e - s);
    }
    drv.* = .{ .dev = .{ .regs = regs } };
    const c = &controllers[controller_count];
    c.* = .{ .dev = dev, .drv = .{ .virtio = drv } };
    // Its message before the queue is made with it (virtio has only MSI-X)
    const msix = pci.getMsixInfo(dev.segment, dev.bus, dev.slot, dev.func) != null and msi.attach(dev, &onInterrupt, c);
    drv.init(mem, &clock.delayUs, if (msix) 0 else virtio.no_vector) catch |err| {
        var buf: [96]u8 = undefined;
        report(std.fmt.bufPrint(&buf, "virtio-blk: not started ({s})\n", .{@errorName(err)}) catch return);
        return;
    };
    add(.{ .dev = .{ .virtio = drv }, .block_size = drv.block_size, .sectors = 0, .read_only = drv.read_only }, drv.blocks, "virtio", report);
    controller_count += 1;
}

// Whether this partition of d is the one the firmware loaded ZDOS from
pub fn isBootPartition(d: *const Disk, start: u64, sectors: u64) bool {
    if (boot_sectors == 0 or start != boot_start or sectors != boot_sectors) return false;
    var sector: [512]u8 = undefined;
    switch (boot_signature_type) {
        1 => {
            read(d, 0, 1, &sector) catch return false;
            return std.mem.eql(u8, sector[440..444], boot_signature[0..4]);
        },
        2 => {
            // The GPT header (sector 1): entries' first sector at 72, count
            // at 80, size at 84.
            // An entry: unique GUID at 16, first sector at 32.
            read(d, 1, 1, &sector) catch return false;
            if (!std.mem.eql(u8, sector[0..8], "EFI PART")) return false;
            const first = std.mem.readInt(u64, sector[72..80], .little);
            const entries = @min(std.mem.readInt(u32, sector[80..84], .little), 256);
            const size = std.mem.readInt(u32, sector[84..88], .little);
            if (size < 48 or size > 512 or 512 % size != 0) return false;
            const per_sector = 512 / size;
            var e: u32 = 0;
            while (e < entries) : (e += 1) {
                if (e % per_sector == 0) read(d, first + e / per_sector, 1, &sector) catch return false;
                const entry = sector[(e % per_sector) * size ..][0..size];
                if (std.mem.readInt(u64, entry[32..40], .little) == start) return std.mem.eql(u8, entry[16..32], &boot_signature);
            }
            return false;
        },
        else => return true,
    }
}

// Device blocks to and from the bounce buffer
fn devRead(d: *const Disk, lba: u64, blocks: usize) platform.Error!void {
    const buf = bounce[0 .. blocks * d.block_size];
    switch (d.dev) {
        .nvme => |n| nvme.NvmeDriver.zdosRead(n, lba, blocks, buf) catch return error.DeviceError,
        .virtio => |v| v.read(lba, blocks, buf) catch return error.DeviceError,
        .sata => |s| {
            var done: usize = 0;
            while (done < blocks) {
                const chunk: u16 = @intCast(@min(blocks - done, 128));
                s.drv.readSectorsAt(s.port, lba + done, chunk, buf[done * d.block_size ..][0 .. @as(usize, chunk) * d.block_size]) catch return error.DeviceError;
                done += chunk;
            }
        },
        .usb => |ref| {
            usb.enter(); // the controller's events are this transfer's meanwhile
            defer usb.leave();
            const s = usb.storageOf(ref) orelse return error.DeviceError;
            s.dev.xhci_driver = s.drv;
            @TypeOf(s.dev.*).zdosRead(s.dev, lba, blocks, buf) catch return error.DeviceError;
        },
    }
}

fn devWrite(d: *const Disk, lba: u64, blocks: usize) platform.Error!void {
    if (d.read_only) return error.WriteProtected;
    const buf = bounce[0 .. blocks * d.block_size];
    switch (d.dev) {
        .nvme => |n| nvme.NvmeDriver.zdosWrite(n, lba, blocks, buf) catch return error.DeviceError,
        .virtio => |v| v.write(lba, blocks, buf) catch return error.DeviceError,
        .sata => |s| {
            var done: usize = 0;
            while (done < blocks) {
                const chunk: u16 = @intCast(@min(blocks - done, 128));
                s.drv.writeSectorsAt(s.port, lba + done, chunk, buf[done * d.block_size ..][0 .. @as(usize, chunk) * d.block_size]) catch return error.DeviceError;
                done += chunk;
            }
        },
        .usb => |ref| {
            usb.enter();
            defer usb.leave();
            const s = usb.storageOf(ref) orelse return error.DeviceError;
            s.dev.xhci_driver = s.drv;
            @TypeOf(s.dev.*).zdosWrite(s.dev, lba, blocks, buf) catch |err| return if (err == error.DeviceWriteProtected) error.WriteProtected else error.DeviceError;
        },
    }
}

// What the next transfer of `sectors` from `lba` covers:
// device blocks first_block.. (blocks of them), starting `skip`
// sectors into the first, `take` sectors in all
const Span = struct { first_block: u64, blocks: usize, skip: usize, take: usize };

fn span(d: *const Disk, lba: u64, sectors: usize) Span {
    const per: u64 = d.block_size / sector_size;
    const skip: usize = @intCast(lba % per);
    const max_blocks = bounce.len / d.block_size;
    const wanted: usize = @intCast((skip + sectors + per - 1) / per);
    const blocks = @min(wanted, max_blocks);
    return .{ .first_block = lba / per, .blocks = blocks, .skip = skip, .take = @min(sectors, blocks * @as(usize, @intCast(per)) - skip) };
}

pub fn read(d: *const Disk, lba: u64, sectors: usize, buf: []u8) platform.Error!void {
    if (buf.len < sectors * sector_size) return error.InvalidArgument;
    if (lba + sectors > d.sectors) return error.DeviceError;
    var done: usize = 0;
    while (done < sectors) {
        const s = span(d, lba + done, sectors - done);
        try devRead(d, s.first_block, s.blocks);
        @memcpy(buf[done * sector_size ..][0 .. s.take * sector_size], bounce[s.skip * sector_size ..][0 .. s.take * sector_size]);
        done += s.take;
    }
}

pub fn write(d: *const Disk, lba: u64, sectors: usize, data: []const u8) platform.Error!void {
    if (data.len < sectors * sector_size) return error.InvalidArgument;
    if (lba + sectors > d.sectors) return error.DeviceError;
    if (d.read_only) return error.WriteProtected;
    const per: usize = d.block_size / sector_size;
    var done: usize = 0;
    while (done < sectors) {
        const s = span(d, lba + done, sectors - done);
        // Part of a device block: the rest of it is read first
        if (s.skip != 0 or (s.skip + s.take) % per != 0) try devRead(d, s.first_block, s.blocks);
        @memcpy(bounce[s.skip * sector_size ..][0 .. s.take * sector_size], data[done * sector_size ..][0 .. s.take * sector_size]);
        try devWrite(d, s.first_block, s.blocks);
        done += s.take;
    }
}

// The device's write cache to the medium
pub fn flush(d: *const Disk) void {
    switch (d.dev) {
        .nvme => |n| n.flush() catch {},
        .sata => |s| s.drv.flushAt(s.port) catch {},
        .virtio => |v| v.flush() catch {},
        .usb => |ref| {
            usb.enter();
            defer usb.leave();
            if (usb.storageOf(ref)) |s| s.dev.syncCache(s.drv) catch {};
        },
    }
}

// A removable disk that is gone (a USB
// stick pulled out, or let go by EJECT)
pub fn missing(d: *const Disk) bool {
    return switch (d.dev) {
        .usb => |ref| d.ejected or usb.storageOf(ref) == null,
        else => false,
    };
}

// EJECT: the device's cache to the medium, the device told it
// may be removed; the disk is missing
// until it is plugged in again
pub fn eject(d: *Disk) void {
    flush(d);
    if (d.dev == .usb) {
        usb.enter();
        defer usb.leave();
        if (usb.storageOf(d.dev.usb)) |s| s.dev.stopUnit(s.drv) catch {};
    }
    d.ejected = true;
}
