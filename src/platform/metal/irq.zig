// MSI / MSI-X of PCIe devices (allocMsi). They arrive through the
// task switching path, which calls dispatch with interrupts off.
//   x86_64: a vector of core 0's local APIC (first_vector..),
//           address 0xFEE00000 with the APIC ID
//   ARM64:  a GICv2m frame's SPIs, or a GICv3 ITS's LPIs
// Wired interrupts (INTx) would need ACPI's AML (_PRT).
const std = @import("std");
const builtin = @import("builtin");
const gic = if (builtin.cpu.arch == .aarch64) @import("gic.zig") else struct {};
const cpu_x86 = if (builtin.cpu.arch == .x86_64) @import("cpu_x86_64.zig") else struct {};

pub const Handler = *const fn (ctx: ?*anyopaque) void;
pub const Msi = struct { address: u64, data: u32 };

// x86_64: the vectors for devices
// (switch_x86_64.zig has a gate for each)
pub const first_vector = 0x50;
pub const vectors = 0x30;

const Entry = struct { id: u32, handler: Handler, ctx: ?*anyopaque };
const max = 32;
var entries: [max]Entry = undefined;
var count: usize = 0;

// A message for the device with PCI requester ID `requester`
// (bus << 8 | device << 3 | function; ARM64's ITS tells devices
// apart by it); handler runs for each of its interrupts.
// Null if none is left or the
// interrupt controller has no messages.
pub fn allocMsi(requester: u16, handler: Handler, ctx: ?*anyopaque) ?Msi {
    if (count == max) return null;
    switch (builtin.cpu.arch) {
        .x86_64 => {
            if (count >= vectors) return null;
            // Core 0's, wherever the driver starts (ISOLCPUS= cores stay quiet)
            const apic = cpu_x86.bootApicId();
            if (apic > 255) return null; // beyond what a message can address without remapping
            const vector: u32 = first_vector + @as(u32, @intCast(count));
            entries[count] = .{ .id = vector, .handler = handler, .ctx = ctx };
            count += 1;
            return .{ .address = 0xFEE0_0000 | (@as(u64, apic) << 12), .data = vector };
        },
        .aarch64 => {
            const m = gic.allocMsi(requester) orelse return null;
            entries[count] = .{ .id = m.intid, .handler = handler, .ctx = ctx };
            count += 1;
            return .{ .address = m.address, .data = m.data };
        },
        else => return null,
    }
}

// x86_64: a vector of core 0's local APIC for a wired line
// (cpu_x86_64.routeIsa); null if none is left
pub fn allocVector(handler: Handler, ctx: ?*anyopaque) ?u32 {
    if (builtin.cpu.arch != .x86_64 or count == max or count >= vectors) return null;
    const vector: u32 = first_vector + @as(u32, @intCast(count));
    entries[count] = .{ .id = vector, .handler = handler, .ctx = ctx };
    count += 1;
    return vector;
}

// From the switching path: the handlers of interrupt id (an
// x86_64 vector, an ARM64 INTID)
pub fn dispatch(id: u32) void {
    for (entries[0..count]) |e| {
        if (e.id == id) e.handler(e.ctx);
    }
}
