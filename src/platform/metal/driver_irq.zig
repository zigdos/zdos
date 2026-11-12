// Drivers' device interrupts (kernel drivers.zig): MSI-X or MSI
// through msi.zig, to core 0 or as a message of the caller's
const std = @import("std");
const pci = @import("../../drivers/pcie/pci.zig");
const msi = @import("msi.zig");
const paging = @import("paging.zig");

pub const Handler = *const fn (ctx: ?*anyopaque) bool;

const Entry = struct { handler: Handler, ctx: ?*anyopaque };
var entries: [8]Entry = undefined;
var count: usize = 0;

fn run(ctx: ?*anyopaque) void {
    const e: *const Entry = @ptrCast(@alignCast(ctx.?));
    _ = e.handler(e.ctx);
}

// The BAR holding the MSI-X table may be one the driver never
// mapped:
fn mapTable(d: pci.PciDeviceLocation) bool {
    const info = pci.getMsixInfo(d.segment, d.bus, d.slot, d.func) orelse return true;
    const bar = d.readBar(info.table_bir);
    if (bar == 0) return false;
    const end = info.table_offset + @as(usize, info.table_size) * 16;
    return paging.mapDevice(bar, std.mem.alignForward(usize, end, 4096));
}

pub fn attach(d: pci.PciDeviceLocation, handler: Handler, ctx: ?*anyopaque) bool {
    if (count == entries.len or !mapTable(d)) return false;
    entries[count] = .{ .handler = handler, .ctx = ctx };
    if (!msi.attach(d, &run, &entries[count])) return false;
    count += 1;
    return true;
}

pub fn attachMessage(d: pci.PciDeviceLocation, address: u64, data: u32) bool {
    return mapTable(d) and msi.attachMessage(d, address, data);
}

// Straight to core `core`, no handler (ARM64 with an ITS)
pub fn attachTo(d: pci.PciDeviceLocation, core: usize) bool {
    return mapTable(d) and msi.attachTo(d, core);
}
