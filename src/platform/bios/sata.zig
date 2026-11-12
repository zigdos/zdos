// SATA disks on AHCI controllers (drivers/pcie/ahci.zig)
// for the BIOS disks that are one of them (same size, same
// first two sectors): polled DMA on any core, no real mode.
// The firmware keeps the ports ZDOS doesn't take.
const std = @import("std");
const ahci = @import("../../drivers/pcie/ahci.zig");
const pci = @import("../../drivers/pcie/pci.zig");
const platform = @import("../../platform.zig");
const clock = @import("clock.zig");

const sector_size = 512;
const max_hbas = 2;
const chunk = 128; // sectors per command

pub const Port = struct { hba: u8, port: u5 };

var hbas: [max_hbas]*ahci.AhciDriver = undefined;
var hba_count: usize = 0;
// DMA wants even addresses: an odd buffer goes through here
var bounce: ?[*]align(4096) u8 = null;

fn onPciDevice(dev: pci.PciDeviceLocation) void {
    if (hba_count == max_hbas or dev.class_id != 0x01 or dev.subclass_id != 0x06 or dev.prog_if != 0x01) return;
    const abar = dev.readBar(5);
    if (abar == 0 or abar >= 1 << 32) return; // no paging here: the first 4 GiB only
    const mem = platform.memory.allocPages((@sizeOf(ahci.AhciDriver) + 4095) / 4096, false) orelse return;
    const drv: *ahci.AhciDriver = @ptrCast(@alignCast(mem));
    pci.enableMemorySpace(dev.bus, dev.slot, dev.func);
    pci.enableBusMaster(dev.bus, dev.slot, dev.func);
    drv.* = ahci.AhciDriver.init(@intCast(abar));
    hbas[hba_count] = drv;
    hba_count += 1;
}

/// A BIOS disk to look for: its size and first two sectors
/// (read through int 13h before any port is borrowed); found
/// when exactly one port is it
pub const Want = struct {
    sectors: u64 = 0,
    first: [2 * sector_size]u8 = undefined,
    used: bool = false,
    found: ?Port = null,
    matches: u8 = 0,
};

const Borrowed = struct { at: Port, saved: ahci.AhciDriver.SavedPort, want: usize };

/// Each port's disk compared with the wants. A port that is no
/// want, or several, goes back to the firmware; so do all the
/// ports of a want that several are (copies of one image).
pub fn match(wants: []Want) void {
    ahci.delayUsFn = &clock.delayUs;
    pci.PciScanner.scanBus(&onPciDevice);
    if (hba_count == 0) return;
    if (bounce == null) bounce = platform.memory.allocPages(chunk * sector_size / 4096, false);

    var kept: [max_hbas * 32]Borrowed = undefined;
    var n: usize = 0;
    for (hbas[0..hba_count], 0..) |drv, h| {
        var i: u6 = 0;
        while (i < 32) : (i += 1) {
            const p: u5 = @intCast(i);
            const saved = drv.borrowPort(p) orelse continue;
            const state = &drv.ports[p].?;
            var own: [2 * sector_size]u8 align(16) = undefined;
            var hit: ?usize = null;
            var hits: usize = 0;
            if (state.block_size == sector_size) {
                if (drv.readSectorsAt(p, 0, 2, &own)) |_| {
                    for (wants, 0..) |*w, k| {
                        if (!w.used or w.sectors != state.total_sectors) continue;
                        if (!std.mem.eql(u8, &w.first, &own)) continue;
                        hit = k;
                        hits += 1;
                    }
                } else |_| {}
            }
            if (hits != 1) {
                drv.returnPort(p, saved);
                continue;
            }
            wants[hit.?].matches += 1;
            kept[n] = .{ .at = .{ .hba = @intCast(h), .port = p }, .saved = saved, .want = hit.? };
            n += 1;
        }
    }
    for (kept[0..n]) |b| {
        if (wants[b.want].matches == 1) {
            wants[b.want].found = b.at;
        } else hbas[b.at.hba].returnPort(b.at.port, b.saved);
    }
}

pub fn transfer(p: Port, lba: u64, count: usize, buf: []u8, is_write: bool) error{DeviceError}!void {
    const drv = hbas[p.hba];
    var done: usize = 0;
    while (done < count) {
        const n: u16 = @intCast(@min(count - done, chunk));
        const bytes = @as(usize, n) * sector_size;
        const piece = buf[done * sector_size ..][0..bytes];
        const odd = @intFromPtr(piece.ptr) & 1 != 0;
        var io = piece;
        if (odd) {
            const b = bounce orelse return error.DeviceError;
            io = b[0..bytes];
            if (is_write) @memcpy(io, piece);
        }
        if (is_write) {
            drv.writeSectorsAt(p.port, lba + done, n, io) catch return error.DeviceError;
        } else {
            drv.readSectorsAt(p.port, lba + done, n, io) catch return error.DeviceError;
            if (odd) @memcpy(piece, io);
        }
        done += n;
    }
}

// The drive's write cache to the medium
pub fn flush(p: Port) error{DeviceError}!void {
    hbas[p.hba].flushAt(p.port) catch return error.DeviceError;
}
