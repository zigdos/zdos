// Disks through int 13h: anything the BIOS can boot from works
// without a driver. LBA extensions (AH=42h/43h) when present,
// else CHS (AH=02h/03h, first 8 GB). 512-byte sectors.
// A hard disk that is an IDE drive ZDOS's own ATA driver finds,
// or a SATA disk on an AHCI controller (sata.zig),
// goes through that instead (no real mode, interrupts on:
// docs/REALTIME.md, B2), matched by its size and first sectors.
const std = @import("std");
const realmode = @import("realmode.zig");
const ata = @import("../../drivers/ata.zig");
const sata = @import("sata.zig");
const pci = @import("../../drivers/pcie/pci.zig");
const clock = @import("clock.zig");

pub const sector_size = 512;
pub const max_disks = 8;

pub const Disk = struct {
    drive: u8, // BIOS drive number: 0x00 floppy A:, 0x80 first hard disk ...
    lba: bool, // LBA extensions
    sectors: u64,
    // Geometry for CHS addressing
    heads: u32,
    sectors_per_track: u32,
    // The drive's own geometry (a floppy's changes with the disk in it)
    drive_heads: u32 = 0,
    drive_sectors_per_track: u32 = 0,
    native: ?ata.Drive = null, // the same disk through ZDOS's ATA driver
    sata: ?sata.Port = null, // or on an AHCI controller
};

var disk_buf: [max_disks]Disk = undefined;
pub var disks: []Disk = disk_buf[0..0];

pub fn init() void {
    var n: usize = 0;
    const hard_disks: *const volatile u8 = @ptrFromInt(0x475); // BIOS data area
    const equipment: *const volatile u16 = @ptrFromInt(0x410);
    var floppies: u8 = 0;
    if (equipment.* & 1 != 0) floppies = @intCast(((equipment.* >> 6) & 3) + 1);

    for (0..floppies) |i| {
        if (n >= max_disks) break;
        if (probe(@intCast(i))) |d| {
            disk_buf[n] = d;
            n += 1;
        }
    }
    for (0..hard_disks.*) |i| {
        if (n >= max_disks) break;
        if (probe(@intCast(0x80 + i))) |d| {
            disk_buf[n] = d;
            n += 1;
        }
    }
    disks = disk_buf[0..n];
    matchNative();
}

// Each BIOS hard disk that is exactly one of the IDE drives:
// the same number of sectors and the same first two. Two alike
// (copies of one image): neither is taken, the BIOS keeps them.
fn matchNative() void {
    matchIde();
    matchSata();
}

fn matchIde() void {
    if (!@import("config.zig").own_ide) return;
    ata.delayUs = &clock.delayUs;
    findIdeController();
    var found: [4]?ata.Drive = @splat(null);
    for (0..4) |i| found[i] = ata.probe(@intCast(i / 2), i % 2 == 1);
    var taken = [_]bool{false} ** 4;
    for (disks) |*d| {
        if (d.drive < 0x80 or !d.lba) continue;
        var bios: [2 * sector_size]u8 = undefined;
        transfer(d, 0, 2, &bios, false) catch continue;
        var match: ?usize = null;
        var matches: usize = 0;
        for (found, 0..) |f, i| {
            var a = f orelse continue;
            if (taken[i] or a.sectors != d.sectors) continue;
            var own: [2 * sector_size]u8 = undefined;
            ata.read(&a, 0, 2, &own) catch continue;
            if (!std.mem.eql(u8, &own, &bios)) continue;
            match = i;
            matches += 1;
        }
        if (matches != 1) continue;
        d.native = found[match.?];
        ata.enableDma(&d.native.?);
        taken[match.?] = true;
    }
}

// The hard disks still on int 13h, each the one SATA disk that
// has its size and first two sectors. Those are read through
// the BIOS first: borrowed ports take its command lists from it
// until they are given back.
var wants: [max_disks]sata.Want = undefined;

fn matchSata() void {
    if (!@import("config.zig").own_sata) return;
    var any = false;
    for (disks, 0..) |*d, i| {
        wants[i] = .{};
        if (d.drive < 0x80 or !d.lba or d.native != null) continue;
        transfer(d, 0, 2, &wants[i].first, false) catch continue;
        wants[i].sectors = d.sectors;
        wants[i].used = true;
        any = true;
    }
    if (!any) return;
    sata.match(wants[0..disks.len]);
    for (disks, 0..) |*d, i| d.sata = wants[i].found;
}

// A PCI IDE controller in compatibility mode (the legacy ports
// ata.zig uses) with bus mastering: its BAR 4 for DMA
var ide_bm: u16 = 0;

fn findIdeController() void {
    pci.PciScanner.scanBus(&onPciDevice);
    if (ide_bm != 0) ata.useDma(ide_bm);
}

fn onPciDevice(dev: pci.PciDeviceLocation) void {
    if (ide_bm != 0 or dev.class_id != 0x01 or dev.subclass_id != 0x01) return;
    // prog_if bits 0 and 2: a channel in native
    // mode (other ports); bit 7: bus master
    if (dev.prog_if & 0x05 != 0 or dev.prog_if & 0x80 == 0) return;
    const bar4 = dev.readBar(4);
    if (bar4 == 0 or bar4 > 0xFFFF) return;
    pci.enableBusMaster(dev.bus, dev.slot, dev.func);
    ide_bm = @intCast(bar4);
}

// The IDE channels ZDOS's driver uses:
// their IRQs from now on (tasks switch)
pub fn startInterrupts(handlerOf: *const fn (channel: u1) bool) void {
    var used = [_]bool{ false, false };
    for (disks) |*d| {
        if (d.native) |a| used[a.channel] = true;
    }
    for (used, 0..) |u, ch| {
        if (u and handlerOf(@intCast(ch))) ata.interruptsOn(@intCast(ch));
    }
}

fn probe(drive: u8) ?Disk {
    var d: Disk = .{ .drive = drive, .lba = false, .sectors = 0, .heads = 0, .sectors_per_track = 0 };

    // Geometry (AH=08h)
    var r: realmode.Regs = .{ .eax = 0x0800, .edx = drive };
    realmode.call(0x13, &r);
    if (!r.carry()) {
        const spt = r.ecx & 0x3F;
        const cyls = ((r.ecx >> 8) & 0xFF) | ((r.ecx & 0xC0) << 2);
        const heads = ((r.edx >> 8) & 0xFF) + 1;
        if (spt > 0) {
            d.sectors_per_track = spt;
            d.heads = heads;
            d.sectors = @as(u64, cyls + 1) * heads * spt;
        }
    }

    // LBA extensions (AH=41h), then the exact size (AH=48h)
    if (drive >= 0x80) {
        r = .{ .eax = 0x4100, .ebx = 0x55AA, .edx = drive };
        realmode.call(0x13, &r);
        if (!r.carry() and (r.ebx & 0xFFFF) == 0xAA55 and r.ecx & 1 != 0) {
            d.lba = true;
            const params = realmode.scratch();
            @memset(params[0..0x1E], 0);
            std.mem.writeInt(u16, params[0..2], 0x1A, .little); // buffer size
            const addr = @intFromPtr(params);
            r = .{ .eax = 0x4800, .edx = drive, .ds = realmode.segment(addr), .esi = realmode.offset(addr) };
            realmode.call(0x13, &r);
            if (!r.carry()) {
                const total = std.mem.readInt(u64, params[0x10..0x18], .little);
                if (total > 0 and total < (1 << 48)) d.sectors = total;
            }
        }
    }
    if (d.sectors == 0) return null;
    if (!d.lba and d.sectors_per_track == 0) return null;
    d.drive_heads = d.heads;
    d.drive_sectors_per_track = d.sectors_per_track;
    return d;
}

// Floppy change line (int 13h AH=16h). Some BIOSes (SeaBIOS)
// always answer "changed", so the
// caller also compares the boot sector.
pub fn mayHaveChanged(d: *const Disk) bool {
    var r: realmode.Regs = .{ .eax = 0x1600, .edx = d.drive };
    realmode.call(0x13, &r);
    return r.carry() or (r.eax >> 8) & 0xFF != 0;
}

// A floppy's geometry from its boot sector (a 1.44 MB disk in a
// 2.88 MB drive has 18 sectors per track, not 36). More than
// two heads is a bogus BPB: the drive's geometry stays.
pub fn setGeometry(d: *Disk, heads: u32, sectors_per_track: u32) void {
    if (heads == 0 or heads > 2 or sectors_per_track == 0 or sectors_per_track > 63) return;
    d.heads = heads;
    d.sectors_per_track = sectors_per_track;
}

pub fn resetGeometry(d: *Disk) void {
    d.heads = d.drive_heads;
    d.sectors_per_track = d.drive_sectors_per_track;
}

pub fn read(d: *const Disk, lba: u64, count: usize, buf: []u8) Error!void {
    return transfer(d, lba, count, buf, false);
}

pub fn write(d: *const Disk, lba: u64, count: usize, data: []const u8) Error!void {
    return transfer(d, lba, count, @constCast(data), true);
}

// Moves count sectors through the bounce
// buffer, in pieces the BIOS accepts
fn transfer(d: *const Disk, lba: u64, count: usize, buf: []u8, is_write: bool) Error!void {
    if (lba + count > d.sectors) return error.DeviceError;
    if (d.sata) |p| return sata.transfer(p, lba, count, buf, is_write);
    if (d.native != null) {
        const a = &@constCast(d).native.?; // DMA may turn off on it
        if (is_write) {
            ata.write(a, lba, count, buf) catch return error.DeviceError;
        } else {
            ata.read(a, lba, count, buf) catch return error.DeviceError;
        }
        return;
    }
    const bounce = realmode.bounce();
    // LBA: 64 sectors per call (some BIOSes take at most 127).
    // CHS: one sector at a time, as old BIOSes can't cross a track.
    const max_chunk: usize = if (d.lba) @min(64, bounce.len / sector_size) else 1;
    var done: usize = 0;
    while (done < count) {
        const n = @min(max_chunk, count - done);
        const bytes = n * sector_size;
        const piece = buf[done * sector_size ..][0..bytes];
        if (is_write) @memcpy(bounce[0..bytes], piece);
        try call(d, lba + done, n, is_write);
        if (!is_write) @memcpy(piece, bounce[0..bytes]);
        done += n;
    }
}

// What was written reaches the medium (the drive's
// write cache emptied): SATA disks; int 13h and the IDE
// driver have no flush here
pub fn flush(d: *const Disk) Error!void {
    if (d.sata) |p| try sata.flush(p);
}

// Only write protection is told apart: other
// BIOS status codes vary between BIOSes
const Error = error{ WriteProtected, DeviceError };

fn statusError(status: u8) Error {
    return switch (status) {
        0x03 => error.WriteProtected,
        else => error.DeviceError, // 0x04 sector not found, 0x80 timeout / no disk, 0xAA not ready ...
    };
}

// With retries: floppies often fail while the motor spins up.
// The status is saved before the reset clears it; write
// protection is not retried.
fn call(d: *const Disk, lba: u64, n: usize, is_write: bool) Error!void {
    const tries: usize = if (d.drive < 0x80) 3 else 2;
    var status: u8 = 0xFF;
    for (0..tries) |_| {
        status = callOnce(d, lba, n, is_write) orelse return;
        if (status == 0x03) break;
        var r: realmode.Regs = .{ .eax = 0x0000, .edx = d.drive }; // reset
        realmode.call(0x13, &r);
    }
    return statusError(status);
}

// null on success, else the BIOS status (AH)
fn callOnce(d: *const Disk, lba: u64, n: usize, is_write: bool) ?u8 {
    const buf_addr = @intFromPtr(realmode.bounce().ptr);
    var r: realmode.Regs = .{};
    if (d.lba) {
        // Disk address packet
        const dap = realmode.scratch();
        @memset(dap[0..16], 0);
        dap[0] = 16;
        std.mem.writeInt(u16, dap[2..4], @intCast(n), .little);
        std.mem.writeInt(u16, dap[4..6], @intCast(realmode.offset(buf_addr)), .little);
        std.mem.writeInt(u16, dap[6..8], @intCast(realmode.segment(buf_addr)), .little);
        std.mem.writeInt(u64, dap[8..16], lba, .little);
        const dap_addr = @intFromPtr(dap);
        r = .{
            .eax = if (is_write) 0x4300 else 0x4200, // AL=0: write without verify
            .edx = d.drive,
            .ds = realmode.segment(dap_addr),
            .esi = realmode.offset(dap_addr),
        };
    } else {
        const track = lba / d.sectors_per_track;
        const sector: u32 = @intCast(lba % d.sectors_per_track + 1);
        const head: u32 = @intCast(track % d.heads);
        const cyl: u32 = @intCast(track / d.heads);
        if (cyl > 1023) return 0x04; // beyond CHS addressing: as "sector not found"
        r = .{
            .eax = (if (is_write) @as(u32, 0x0300) else 0x0200) | @as(u32, @intCast(n)),
            .ecx = ((cyl & 0xFF) << 8) | ((cyl >> 2) & 0xC0) | sector,
            .edx = (head << 8) | d.drive,
            .es = realmode.segment(buf_addr),
            .ebx = realmode.offset(buf_addr),
        };
    }
    realmode.call(0x13, &r);
    if (!r.carry()) return null;
    return @truncate(r.eax >> 8);
}
