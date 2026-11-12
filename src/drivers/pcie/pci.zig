//! PCI/PCIe configuration space: enumeration, BARs, MSI/MSI-X.
//!
//! The kernel maps and registers
//! ECAM regions (registerEcamRegion); mechanism #1 reaches
//! only segment 0 and the first 256 bytes. The MSI helpers
//! only program registers.

const builtin = @import("builtin");

pub const ConfigSpaceSize: u16 = 4096;
pub const StandardConfigSpaceSize: u16 = 256;
pub const PciConfigAccess = enum { legacy, ecam };

pub const EcamRegion = struct {
    /// PCI segment group (ACPI MCFG segment number).
    /// Defaults to segment zero.
    segment: u16 = 0,
    /// First bus number covered by this MCFG allocation.
    start_bus: u8,
    /// Last bus number covered by this MCFG allocation, inclusive.
    end_bus: u8,
    /// Mapped virtual base corresponding to the physical ECAM
    /// base for start_bus. Must cover all buses in this region
    /// and use appropriate device-memory attributes.
    virtual_base: usize,
};

const MaxEcamRegions = 64;
var ecam_regions: [MaxEcamRegions]?EcamRegion = [_]?EcamRegion{null} ** MaxEcamRegions;

pub fn registerEcamRegion(region: EcamRegion) bool {
    if (region.start_bus > region.end_bus or region.virtual_base == 0) return false;
    for (&ecam_regions) |*entry| {
        if (entry.*) |existing| {
            if (existing.segment == region.segment and existing.start_bus == region.start_bus and existing.end_bus == region.end_bus) {
                entry.* = region;
                return true;
            }
        }
    }
    for (&ecam_regions) |*entry| {
        if (entry.* == null) {
            entry.* = region;
            return true;
        }
    }
    return false;
}

pub fn clearEcamRegions() void {
    ecam_regions = [_]?EcamRegion{null} ** MaxEcamRegions;
}

fn findEcamRegion(segment: u16, bus: u8) ?EcamRegion {
    for (ecam_regions) |entry| {
        if (entry) |region| {
            if (region.segment == segment and bus >= region.start_bus and bus <= region.end_bus) return region;
        }
    }
    return null;
}

fn ecamAddress(region: EcamRegion, bus: u8, slot: u8, func: u8, offset: u16) usize {
    const bus_offset = (@as(usize, bus - region.start_bus)) << 20;
    const slot_offset = @as(usize, slot) << 15;
    const func_offset = @as(usize, func) << 12;
    return region.virtual_base + bus_offset + slot_offset + func_offset + @as(usize, offset & 0x0FFC);
}

inline fn outl(port: u16, value: u32) void {
    if (comptime builtin.cpu.arch.isX86()) {
        asm volatile ("outl %[value], %[port]"
            :
            : [value] "{eax}" (value), [port] "{dx}" (port),
        );
    }
}

inline fn inl(port: u16) u32 {
    if (comptime builtin.cpu.arch.isX86()) {
        return asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> u32),
            : [port] "{dx}" (port),
        );
    }
    return 0xFFFF_FFFF;
}

fn legacyReadConfigDword(bus: u8, slot: u8, func: u8, offset: u16) u32 {
    if (offset >= StandardConfigSpaceSize or !builtin.cpu.arch.isX86()) return 0xFFFF_FFFF;
    const address = (@as(u32, 1) << 31) | (@as(u32, bus) << 16) | (@as(u32, slot) << 11) | (@as(u32, func) << 8) | (@as(u32, offset) & 0xFC);
    outl(0xCF8, address);
    return inl(0xCFC);
}

fn legacyWriteConfigDword(bus: u8, slot: u8, func: u8, offset: u16, value: u32) void {
    if (offset >= StandardConfigSpaceSize or !builtin.cpu.arch.isX86()) return;
    const address = (@as(u32, 1) << 31) | (@as(u32, bus) << 16) | (@as(u32, slot) << 11) | (@as(u32, func) << 8) | (@as(u32, offset) & 0xFC);
    outl(0xCF8, address);
    outl(0xCFC, value);
}

pub fn pciReadConfigDwordInSegment(segment: u16, bus: u8, slot: u8, func: u8, offset: u16) u32 {
    if (slot >= 32 or func >= 8 or offset >= ConfigSpaceSize) return 0xFFFF_FFFF;
    if (findEcamRegion(segment, bus)) |region| {
        const ptr: *volatile u32 = @ptrFromInt(ecamAddress(region, bus, slot, func, offset));
        return ptr.*;
    }
    if (segment != 0) return 0xFFFF_FFFF;
    return legacyReadConfigDword(bus, slot, func, offset);
}

pub fn pciWriteConfigDwordInSegment(segment: u16, bus: u8, slot: u8, func: u8, offset: u16, value: u32) void {
    if (slot >= 32 or func >= 8 or offset >= ConfigSpaceSize) return;
    if (findEcamRegion(segment, bus)) |region| {
        const ptr: *volatile u32 = @ptrFromInt(ecamAddress(region, bus, slot, func, offset));
        ptr.* = value;
        return;
    }
    if (segment == 0) legacyWriteConfigDword(bus, slot, func, offset, value);
}

/// Backwards-compatible segment-zero accessors.
pub fn pciReadConfigDword(bus: u8, slot: u8, func: u8, offset: u16) u32 {
    return pciReadConfigDwordInSegment(0, bus, slot, func, offset);
}
pub fn pciWriteConfigDword(bus: u8, slot: u8, func: u8, offset: u16, value: u32) void {
    pciWriteConfigDwordInSegment(0, bus, slot, func, offset, value);
}

fn readConfigByteInSegment(segment: u16, bus: u8, slot: u8, func: u8, offset: u16) u8 {
    const dword = pciReadConfigDwordInSegment(segment, bus, slot, func, offset & 0xFFFC);
    const shift: u5 = @intCast((offset & 3) * 8);
    return @truncate(dword >> shift);
}
fn readConfigWordInSegment(segment: u16, bus: u8, slot: u8, func: u8, offset: u16) u16 {
    const dword = pciReadConfigDwordInSegment(segment, bus, slot, func, offset & 0xFFFC);
    const shift: u5 = @intCast((offset & 2) * 8);
    return @truncate(dword >> shift);
}
fn writeConfigWordInSegment(segment: u16, bus: u8, slot: u8, func: u8, offset: u16, value: u16) void {
    const aligned = offset & 0xFFFC;
    // Command/Status share a dword. Status bits are
    // write-one-to-clear, so never echo the status half back when
    // changing the Command register.
    if (aligned == 0x04 and (offset & 2) == 0) {
        pciWriteConfigDwordInSegment(segment, bus, slot, func, aligned, value);
        return;
    }
    const old = pciReadConfigDwordInSegment(segment, bus, slot, func, aligned);
    const shift: u5 = @intCast((offset & 2) * 8);
    const mask = @as(u32, 0xFFFF) << shift;
    pciWriteConfigDwordInSegment(segment, bus, slot, func, aligned, (old & ~mask) | (@as(u32, value) << shift));
}

pub const PciCapabilityInfo = struct { pm: bool = false, msi: bool = false, msix: bool = false, pcie: bool = false };

pub const PciDeviceLocation = struct {
    segment: u16 = 0,
    bus: u8,
    slot: u8,
    func: u8,
    vendor_id: u16,
    device_id: u16,
    class_id: u8,
    subclass_id: u8,
    prog_if: u8,
    header_type: u8,
    bar0: u64,
    interrupt_line: u8,
    interrupt_pin: u8,
    capabilities: PciCapabilityInfo,

    pub fn readBar(self: PciDeviceLocation, bar_idx: u3) u64 {
        return readBarAddressInSegment(self.segment, self.bus, self.slot, self.func, bar_idx);
    }
    pub fn getBar5(self: PciDeviceLocation) u64 { return self.readBar(5); }
};

pub fn readBarAddressInSegment(segment: u16, bus: u8, slot: u8, func: u8, bar_idx: u3) u64 {
    const offset: u16 = 0x10 + @as(u16, bar_idx) * 4;
    const low = pciReadConfigDwordInSegment(segment, bus, slot, func, offset);
    if (low == 0xFFFF_FFFF) return 0;
    if ((low & 1) != 0) return low & 0xFFFF_FFFC;
    const bar_type = (low >> 1) & 3;
    if (bar_type == 2 and bar_idx < 5) {
        const high = pciReadConfigDwordInSegment(segment, bus, slot, func, offset + 4);
        if (high == 0xFFFF_FFFF) return 0;
        return (@as(u64, high) << 32) | (low & 0xFFFF_FFF0);
    }
    return low & 0xFFFF_FFF0;
}
pub fn readBarAddress(bus: u8, slot: u8, func: u8, bar_idx: u3) u64 {
    return readBarAddressInSegment(0, bus, slot, func, bar_idx);
}

fn capabilityStart(segment: u16, bus: u8, slot: u8, func: u8, header_type: u8) u8 {
    return if ((header_type & 0x7F) == 2) readConfigByteInSegment(segment, bus, slot, func, 0x14) else readConfigByteInSegment(segment, bus, slot, func, 0x34);
}
fn nextCapability(segment: u16, bus: u8, slot: u8, func: u8, ptr: u8) u8 {
    return readConfigByteInSegment(segment, bus, slot, func, @as(u16, ptr) + 1);
}

/// Visit standard capabilities with
/// pointer validation and cycle detection.
fn findCapability(segment: u16, bus: u8, slot: u8, func: u8, wanted_id: u8) ?u8 {
    const status = readConfigWordInSegment(segment, bus, slot, func, 0x06);
    if ((status & 0x10) == 0) return null;
    const header = readConfigByteInSegment(segment, bus, slot, func, 0x0E);
    var ptr = capabilityStart(segment, bus, slot, func, header);
    var visited = [_]bool{false} ** 256;
    var count: u8 = 0;
    while (ptr >= 0x40 and ptr <= 0xFC and count < 48) : (count += 1) {
        if ((ptr & 3) != 0 or visited[ptr]) return null;
        visited[ptr] = true;
        if (readConfigByteInSegment(segment, bus, slot, func, ptr) == wanted_id) return ptr;
        const next = nextCapability(segment, bus, slot, func, ptr);
        if (next == 0) return null;
        if (next == ptr or (next & 3) != 0) return null;
        ptr = next;
    }
    return null;
}

fn scanCapabilities(segment: u16, bus: u8, slot: u8, func: u8, status: u16, header_type: u8) PciCapabilityInfo {
    var info = PciCapabilityInfo{};
    if ((status & 0x10) == 0) return info;
    var ptr = capabilityStart(segment, bus, slot, func, header_type);
    var visited = [_]bool{false} ** 256;
    var count: u8 = 0;
    while (ptr >= 0x40 and ptr <= 0xFC and count < 48) : (count += 1) {
        if ((ptr & 3) != 0 or visited[ptr]) break;
        visited[ptr] = true;
        switch (readConfigByteInSegment(segment, bus, slot, func, ptr)) {
            0x01 => info.pm = true,
            0x05 => info.msi = true,
            0x10 => info.pcie = true,
            0x11 => info.msix = true,
            else => {},
        }
        const next = nextCapability(segment, bus, slot, func, ptr);
        if (next == 0) break;
        if (next == ptr or (next & 3) != 0) break;
        ptr = next;
    }
    return info;
}

pub fn requestPowerStateD0InSegment(segment: u16, bus: u8, slot: u8, func: u8) bool {
    const ptr = findCapability(segment, bus, slot, func, 0x01) orelse return false;
    const pmcsr_offset: u16 = @as(u16, ptr) + 4;
    var pmcsr = readConfigWordInSegment(segment, bus, slot, func, pmcsr_offset);
    pmcsr &= ~@as(u16, 3);
    writeConfigWordInSegment(segment, bus, slot, func, pmcsr_offset, pmcsr);
    return true;
}
pub fn requestPowerStateD0(bus: u8, slot: u8, func: u8) bool {
    return requestPowerStateD0InSegment(0, bus, slot, func);
}

/// Configure memory decoding only. Bus mastering is
/// intentionally left to the driver, which should enable it
/// only after DMA buffers and addresses are ready.
pub fn enableMemorySpace(bus: u8, slot: u8, func: u8) void {
    enableMemorySpaceInSegment(0, bus, slot, func);
}
pub fn enableMemorySpaceInSegment(segment: u16, bus: u8, slot: u8, func: u8) void {
    const command = readConfigWordInSegment(segment, bus, slot, func, 0x04) | 0x0002;
    writeConfigWordInSegment(segment, bus, slot, func, 0x04, command);
}
pub fn enableBusMaster(bus: u8, slot: u8, func: u8) void {
    enableBusMasterInSegment(0, bus, slot, func);
}
pub fn enableBusMasterInSegment(segment: u16, bus: u8, slot: u8, func: u8) void {
    const command = readConfigWordInSegment(segment, bus, slot, func, 0x04) | 0x0004;
    writeConfigWordInSegment(segment, bus, slot, func, 0x04, command);
}
pub fn disableBusMaster(bus: u8, slot: u8, func: u8) void {
    disableBusMasterInSegment(0, bus, slot, func);
}
pub fn disableBusMasterInSegment(segment: u16, bus: u8, slot: u8, func: u8) void {
    const command = readConfigWordInSegment(segment, bus, slot, func, 0x04) & ~@as(u16, 0x0004);
    writeConfigWordInSegment(segment, bus, slot, func, 0x04, command);
}

pub const MsiInfo = struct {
    capability_offset: u8,
    is_64_bit: bool,
    supports_masking: bool,
    multiple_message_capable: u3,
};
pub const MsixInfo = struct {
    capability_offset: u8,
    table_size: u16,
    table_bir: u3,
    table_offset: u32,
    pba_bir: u3,
    pba_offset: u32,
};

pub fn getMsiInfo(segment: u16, bus: u8, slot: u8, func: u8) ?MsiInfo {
    const ptr = findCapability(segment, bus, slot, func, 0x05) orelse return null;
    const control = readConfigWordInSegment(segment, bus, slot, func, @as(u16, ptr) + 2);
    return .{
        .capability_offset = ptr,
        .is_64_bit = (control & (1 << 7)) != 0,
        .supports_masking = (control & (1 << 8)) != 0,
        .multiple_message_capable = @truncate((control >> 1) & 7),
    };
}
pub fn getMsixInfo(segment: u16, bus: u8, slot: u8, func: u8) ?MsixInfo {
    const ptr = findCapability(segment, bus, slot, func, 0x11) orelse return null;
    const control = readConfigWordInSegment(segment, bus, slot, func, @as(u16, ptr) + 2);
    const table = pciReadConfigDwordInSegment(segment, bus, slot, func, @as(u16, ptr) + 4);
    const pba = pciReadConfigDwordInSegment(segment, bus, slot, func, @as(u16, ptr) + 8);
    if (table == 0xFFFF_FFFF or pba == 0xFFFF_FFFF) return null;
    return .{
        .capability_offset = ptr,
        .table_size = @as(u16, control & 0x07FF) + 1,
        .table_bir = @truncate(table & 7),
        .table_offset = table & 0xFFFF_FFF8,
        .pba_bir = @truncate(pba & 7),
        .pba_offset = pba & 0xFFFF_FFF8,
    };
}

/// Program an MSI message and optionally enable MSI.
/// Caller must have installed the interrupt handler and
/// arranged a valid destination before passing enable=true.
pub fn configureMsiMessage(segment: u16, bus: u8, slot: u8, func: u8, message_address: u64, message_data: u16, multiple_message_enable: u3, enable: bool) bool {
    const info = getMsiInfo(segment, bus, slot, func) orelse return false;
    if ((message_address & 3) != 0 or (!info.is_64_bit and message_address > 0xFFFF_FFFF)) return false;
    if (multiple_message_enable > info.multiple_message_capable) return false;
    const cap: u16 = info.capability_offset;
    const control_offset = cap + 2;
    var control = readConfigWordInSegment(segment, bus, slot, func, control_offset);
    // Disable while updating the message registers;
    // preserve other control fields.
    writeConfigWordInSegment(segment, bus, slot, func, control_offset, control & ~@as(u16, 1));
    pciWriteConfigDwordInSegment(segment, bus, slot, func, cap + 4, @truncate(message_address));
    var data_offset: u16 = cap + 8;
    if (info.is_64_bit) {
        pciWriteConfigDwordInSegment(segment, bus, slot, func, cap + 8, @truncate(message_address >> 32));
        data_offset = cap + 12;
    }
    writeConfigWordInSegment(segment, bus, slot, func, data_offset, message_data);
    control = (control & ~@as(u16, 0x0071)) | (@as(u16, multiple_message_enable) << 4);
    if (enable) control |= 1;
    writeConfigWordInSegment(segment, bus, slot, func, control_offset, control);
    return true;
}

/// Set MSI's per-vector mask bit. vector_index must be below 32
/// and the device must advertise per-vector masking.
/// This does not enable MSI.
pub fn setMsiVectorMasked(segment: u16, bus: u8, slot: u8, func: u8, vector_index: u5, masked: bool) bool {
    const info = getMsiInfo(segment, bus, slot, func) orelse return false;
    if (!info.supports_masking) return false;
    const mask_offset: u16 = @as(u16, info.capability_offset) + (if (info.is_64_bit) @as(u16, 16) else @as(u16, 12));
    const old = pciReadConfigDwordInSegment(segment, bus, slot, func, mask_offset);
    if (old == 0xFFFF_FFFF) return false;
    const bit = @as(u32, 1) << vector_index;
    pciWriteConfigDwordInSegment(segment, bus, slot, func, mask_offset, if (masked) old | bit else old & ~bit);
    return true;
}

/// Mask/unmask the MSI-X function. Table entries should be
/// programmed while masked.
pub fn setMsixFunctionEnabled(segment: u16, bus: u8, slot: u8, func: u8, enabled: bool, function_masked: bool) bool {
    const info = getMsixInfo(segment, bus, slot, func) orelse return false;
    const offset: u16 = @as(u16, info.capability_offset) + 2;
    var control = readConfigWordInSegment(segment, bus, slot, func, offset);
    control &= ~@as(u16, 0xC000); // Function Mask bit 14 and Enable bit 15.
    if (function_masked) control |= 1 << 14;
    if (enabled) control |= 1 << 15;
    writeConfigWordInSegment(segment, bus, slot, func, offset, control);
    return true;
}

/// Configure one MSI-X table entry in a caller-mapped BAR.
/// mapped_bar must point to the beginning of the
/// BAR's mapped virtual range; bar_mapping_len is its
/// mapped byte length. The function masks the entry first,
/// writes address/data, then applies `masked`.
pub fn configureMsixTableEntry(mapped_bar: usize, bar_mapping_len: usize, info: MsixInfo, entry_index: u16, message_address: u64, message_data: u32, masked: bool) bool {
    if (mapped_bar == 0 or entry_index >= info.table_size or (message_address & 3) != 0) return false;
    const entry_offset = @as(usize, info.table_offset) + @as(usize, entry_index) * 16;
    if (entry_offset > bar_mapping_len or bar_mapping_len - entry_offset < 16) return false;
    const entry = mapped_bar + entry_offset;
    const address_low: *volatile u32 = @ptrFromInt(entry);
    const address_high: *volatile u32 = @ptrFromInt(entry + 4);
    const data: *volatile u32 = @ptrFromInt(entry + 8);
    const vector_control: *volatile u32 = @ptrFromInt(entry + 12);
    vector_control.* = vector_control.* | 1;
    address_low.* = @truncate(message_address);
    address_high.* = @truncate(message_address >> 32);
    data.* = message_data;
    // Ensure message fields are visible
    // before final mask state is written.
    if (comptime builtin.cpu.arch.isX86()) {
        asm volatile ("mfence" ::: "memory");
    } else if (comptime builtin.cpu.arch == .aarch64) {
        asm volatile ("dmb oshst" ::: "memory");
    }
    vector_control.* = if (masked) 1 else 0;
    return true;
}

fn makeDevice(segment: u16, bus: u8, slot: u8, func: u8, reg0: u32) PciDeviceLocation {
    const reg8 = pciReadConfigDwordInSegment(segment, bus, slot, func, 0x08);
    const header_type = readConfigByteInSegment(segment, bus, slot, func, 0x0E);
    const status: u16 = @truncate(pciReadConfigDwordInSegment(segment, bus, slot, func, 0x04) >> 16);
    return .{
        .segment = segment, .bus = bus, .slot = slot, .func = func,
        .vendor_id = @truncate(reg0), .device_id = @truncate(reg0 >> 16),
        .class_id = @truncate(reg8 >> 24), .subclass_id = @truncate(reg8 >> 16), .prog_if = @truncate(reg8 >> 8),
        .header_type = header_type,
        .bar0 = readBarAddressInSegment(segment, bus, slot, func, 0),
        .interrupt_line = readConfigByteInSegment(segment, bus, slot, func, 0x3C),
        .interrupt_pin = readConfigByteInSegment(segment, bus, slot, func, 0x3D),
        .capabilities = scanCapabilities(segment, bus, slot, func, status, header_type),
    };
}

const BusBitmap = [256]bool;
fn scanOneBus(segment: u16, bus: u8, visited_buses: *BusBitmap, callback: *const fn (device: PciDeviceLocation) void) void {
    if (visited_buses[bus]) return;
    visited_buses[bus] = true;
    var slot: u8 = 0;
    while (slot < 32) : (slot += 1) {
        const reg0_func0 = pciReadConfigDwordInSegment(segment, bus, slot, 0, 0);
        if (@as(u16, @truncate(reg0_func0)) == 0xFFFF) continue;
        const header0 = readConfigByteInSegment(segment, bus, slot, 0, 0x0E);
        const functions: u8 = if ((header0 & 0x80) != 0) 8 else 1;
        var func: u8 = 0;
        while (func < functions) : (func += 1) {
            const reg0 = if (func == 0) reg0_func0 else pciReadConfigDwordInSegment(segment, bus, slot, func, 0);
            if (@as(u16, @truncate(reg0)) == 0xFFFF) continue;
            _ = requestPowerStateD0InSegment(segment, bus, slot, func);
            // Do not enable bus mastering globally: storage/network drivers
            // must enable it only after setting up DMA memory.
            // Enable memory decoding for enumeration.
            enableMemorySpaceInSegment(segment, bus, slot, func);
            const device = makeDevice(segment, bus, slot, func, reg0);
            callback(device);
            if (device.class_id == 0x06 and device.subclass_id == 0x04 and (device.header_type & 0x7F) == 1) {
                const buses = pciReadConfigDwordInSegment(segment, bus, slot, func, 0x18);
                const secondary: u8 = @truncate(buses >> 8);
                const subordinate: u8 = @truncate(buses >> 16);
                if (secondary != 0 and subordinate >= secondary) scanOneBus(segment, secondary, visited_buses, callback);
            }
        }
    }
}

pub const PciScanner = struct {
    /// Enumerate a single PCI segment.
    /// Segment zero can fall back to legacy x86 access.
    pub fn scanSegment(segment: u16, callback: *const fn (device: PciDeviceLocation) void) void {
        var visited = [_]bool{false} ** 256;
        scanOneBus(segment, 0, &visited, callback);
        var bus: u16 = 0;
        while (bus < 256) : (bus += 1) {
            const b: u8 = @intCast(bus);
            if (!visited[b] and (segment == 0 or findEcamRegion(segment, b) != null)) scanOneBus(segment, b, &visited, callback);
        }
    }

    /// Enumerate segment zero and every other segment represented
    /// by a registered ECAM region. Multiple regions in one
    /// segment are deduplicated. The callback's device.segment
    /// is part of the device identity; consumers should key
    /// devices by segment:bus:slot:function.
    pub fn scanBus(callback: *const fn (device: PciDeviceLocation) void) void {
        scanSegment(0, callback);
        var processed: [MaxEcamRegions]?u16 = [_]?u16{null} ** MaxEcamRegions;
        var processed_count: usize = 0;
        for (ecam_regions) |entry| {
            if (entry) |region| {
                if (region.segment == 0) continue;
                var already = false;
                for (processed[0..processed_count]) |seen| {
                    if (seen != null and seen.? == region.segment) { already = true; break; }
                }
                if (!already) {
                    processed[processed_count] = region.segment;
                    processed_count += 1;
                    scanSegment(region.segment, callback);
                }
            }
        }
    }
};
