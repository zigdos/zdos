// A PCI device's interrupt as a message (irq.zig): MSI-X table
// entry 0 if the device has MSI-X, else MSI.
// Its wired interrupt (INTx) is switched off.
const std = @import("std");
const pci = @import("../../drivers/pcie/pci.zig");
const irq = @import("irq.zig");
const memory = @import("memory.zig");
const builtin = @import("builtin");
const gic = if (builtin.cpu.arch == .aarch64) @import("gic.zig") else struct {};

// What own page tables map of a BAR holding an MSI-X table, at least
const table_span = 1 << 20;

// handler(ctx) for each of the device's interrupts; false if it
// has neither MSI-X nor MSI, or no message is left
pub fn attach(dev: pci.PciDeviceLocation, handler: irq.Handler, ctx: ?*anyopaque) bool {
    const rid: u16 = (@as(u16, dev.bus) << 8) | (@as(u16, dev.slot) << 3) | dev.func;
    if (pci.getMsixInfo(dev.segment, dev.bus, dev.slot, dev.func)) |info| {
        const bar = dev.readBar(info.table_bir);
        const span = @max(table_span, std.mem.alignForward(usize, info.table_offset + @as(usize, info.table_size) * 16, 4096));
        if (bar != 0) {
            if (!(info.table_bir == 0 and bar == dev.bar0)) memory.addDevice(bar, span);
            const m = irq.allocMsi(rid, handler, ctx) orelse return false;
            _ = pci.setMsixFunctionEnabled(dev.segment, dev.bus, dev.slot, dev.func, true, true);
            if (!pci.configureMsixTableEntry(@intCast(bar), span, info, 0, m.address, m.data, false)) {
                _ = pci.setMsixFunctionEnabled(dev.segment, dev.bus, dev.slot, dev.func, false, false);
                return false;
            }
            _ = pci.setMsixFunctionEnabled(dev.segment, dev.bus, dev.slot, dev.func, true, false);
            disableIntx(dev);
            return true;
        }
    }
    if (pci.getMsiInfo(dev.segment, dev.bus, dev.slot, dev.func) != null) {
        const m = irq.allocMsi(rid, handler, ctx) orelse return false;
        if (!pci.configureMsiMessage(dev.segment, dev.bus, dev.slot, dev.func, m.address, @truncate(m.data), 0, true)) return false;
        disableIntx(dev);
        return true;
    }
    return false;
}

// The device's interrupt as a message of the caller's
// (to another core): no handler here. False as attach.
pub fn attachMessage(dev: pci.PciDeviceLocation, address: u64, data: u32) bool {
    if (pci.getMsixInfo(dev.segment, dev.bus, dev.slot, dev.func)) |info| {
        const bar = dev.readBar(info.table_bir);
        const span = @max(table_span, std.mem.alignForward(usize, info.table_offset + @as(usize, info.table_size) * 16, 4096));
        if (bar != 0) {
            if (!(info.table_bir == 0 and bar == dev.bar0)) memory.addDevice(bar, span);
            _ = pci.setMsixFunctionEnabled(dev.segment, dev.bus, dev.slot, dev.func, true, true);
            if (!pci.configureMsixTableEntry(@intCast(bar), span, info, 0, address, data, false)) {
                _ = pci.setMsixFunctionEnabled(dev.segment, dev.bus, dev.slot, dev.func, false, false);
                return false;
            }
            _ = pci.setMsixFunctionEnabled(dev.segment, dev.bus, dev.slot, dev.func, true, false);
            disableIntx(dev);
            return true;
        }
    }
    if (pci.getMsiInfo(dev.segment, dev.bus, dev.slot, dev.func) != null) {
        if (!pci.configureMsiMessage(dev.segment, dev.bus, dev.slot, dev.func, address, @truncate(data), 0, true)) return false;
        disableIntx(dev);
        return true;
    }
    return false;
}

// ARM64 with an ITS: the device's own message to core `core`
// (an LPI there, no handler); false elsewhere or if it can't
pub fn attachTo(dev: pci.PciDeviceLocation, core: usize) bool {
    if (builtin.cpu.arch != .aarch64) return false;
    const rid: u16 = (@as(u16, dev.bus) << 8) | (@as(u16, dev.slot) << 3) | dev.func;
    const m = gic.deviceMessageFor(rid, core) orelse return false;
    return attachMessage(dev, m.address, m.data);
}

// Command register bit 10: no wired interrupt
fn disableIntx(dev: pci.PciDeviceLocation) void {
    const cmd = pci.pciReadConfigDwordInSegment(dev.segment, dev.bus, dev.slot, dev.func, 0x04);
    pci.pciWriteConfigDwordInSegment(dev.segment, dev.bus, dev.slot, dev.func, 0x04, (cmd & 0xFFFF) | (1 << 10));
}
