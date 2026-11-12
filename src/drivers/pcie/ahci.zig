//! AHCI (SATA) driver: several
//! ports, NCQ, ATAPI optical drives.

const std = @import("std");
const builtin = @import("builtin");

// Physical address hook (identity by default)
pub var virtualToPhysicalFn: *const fn (virtual_address: usize) u64 = defaultVirtualToPhysical;

pub fn defaultVirtualToPhysical(virtual_address: usize) u64 {
    return @as(u64, virtual_address);
}

inline fn virtToPhys(va: usize) u64 {
    return virtualToPhysicalFn(va);
}

const read32 = @import("../../arch/mmio.zig").load32; // full width: never narrowed

inline fn memoryBarrier() void {
    if (comptime builtin.cpu.arch.isX86()) {
        asm volatile ("mfence" ::: "memory");
    } else if (comptime builtin.cpu.arch.isAARCH64()) {
        asm volatile ("dmb sy" ::: "memory");
    } else {
        asm volatile ("" ::: "memory");
    }
}

/// Replace with a timer-based delay if you have one (default:
/// ~1 us per iteration on x86).
pub var delayUsFn: *const fn (us: u32) void = defaultDelayUs;

pub fn defaultDelayUs(us: u32) void {
    var i: u32 = 0;
    while (i < us) : (i += 1) {
        if (comptime builtin.cpu.arch.isX86()) {
            asm volatile ("outb %[v], $0x80"
                :
                : [v] "{al}" (@as(u8, 0)),
            );
        } else {
            asm volatile ("" ::: "memory");
        }
    }
}

fn delayMs(ms: u32) void {
    var i: u32 = 0;
    while (i < ms) : (i += 1) delayUsFn(1000);
}

const PORT_CMD_ST: u32 = 1 << 0;
const PORT_CMD_FRE: u32 = 1 << 4;
const PORT_CMD_FR: u32 = 1 << 14;
const PORT_CMD_CR: u32 = 1 << 15;
const TFD_ERR: u32 = 1 << 0;
const TFD_DRQ: u32 = 1 << 3;
const TFD_DF: u32 = 1 << 5;
const TFD_BSY: u32 = 1 << 7;
/// PxIS: TFES, HBFS, HBDS, IFS, INFS, OFS
const PORT_IS_ERR_MASK: u32 = (1 << 30) | (1 << 29) | (1 << 28) | (1 << 27) | (1 << 26) | (1 << 24);

// HBA registers and tables
pub const AhciPortRegisters = extern struct {
    clb: u32, // Command List Base Address (Lower 32 bits)
    clbu: u32, // Command List Base Address (Upper 32 bits)
    fb: u32, // Received FIS Base Address (Lower 32 bits)
    fbu: u32, // Received FIS Base Address (Upper 32 bits)
    is: u32, // Interrupt Status
    ie: u32, // Interrupt Enable
    cmd: u32, // Command and Status
    reserved0: u32,
    tfd: u32, // Task File Data
    sig: u32, // Signature (Identifies if port is SATA, ATAPI, etc.)
    ssts: u32, // Serial ATA Status (Device presence tracking)
    sctl: u32, // Serial ATA Control
    serr: u32, // Serial ATA Error
    sact: u32, // Serial ATA Active
    ci: u32, // Command Issue
    sntf: u32,
    fbs: u32,
    reserved1: [15]u32, // PxDEVSLP, reserved, vendor: a port block is 0x80 bytes
};

pub const AhciHbaRegisters = extern struct {
    cap: u32, // Host Capabilities
    ghc: u32, // Global Host Control
    is: u32, // Interrupt Status
    pi: u32, // Ports Implemented (Bitmask of up to 32 ports)
    vs: u32, // Version
    ccc_ctl: u32,
    ccc_pts: u32,
    em_loc: u32,
    em_ctl: u32,
    cap2: u32, // Host Capabilities Extended
    bohc: u32, // BIOS/OS Handoff Control
    reserved: [29]u32,
    vendor_reserved: [24]u32,
    ports: [32]AhciPortRegisters,
};

comptime {
    std.debug.assert(@sizeOf(AhciPortRegisters) == 0x80);
    std.debug.assert(@offsetOf(AhciHbaRegisters, "ports") == 0x100);
}

// Command list, tables and FIS area (physically aligned)
pub const AhciPrdtEntry = extern struct {
    dba: u64 = 0, // Data Base Address (64-bit physical address)
    reserved: u32 = 0,
    flags_dbc: u32 = 0, // [21:0] DBC, [31] Interrupt

    pub fn init(phys_addr: u64, byte_count: u32, interrupt: bool) AhciPrdtEntry {
        const dbc = (byte_count - 1) & 0x003F_FFFF;
        const i: u32 = if (interrupt) (1 << 31) else 0;
        return .{
            .dba = phys_addr,
            .reserved = 0,
            .flags_dbc = dbc | i,
        };
    }
};

pub const AhciCmdHeader = extern struct {
    flags: u16 = 0, // [4:0] CFL, [5] ATAPI, [6] Write, [7] Prefetch, [8] Reset, [15:12] PMP
    prdtl: u16 = 0, // PRDT Length
    prdbc: u32 = 0, // PRD Byte Count
    ctba: u64 = 0, // Command Table Base Address
    reserved: [4]u32 = [_]u32{0} ** 4,

    pub fn init(cfl: u5, is_write: bool, prdt_len: u16, ctba_phys: u64) AhciCmdHeader {
        var f: u16 = @as(u16, cfl);
        if (is_write) f |= (1 << 6);
        return .{
            .flags = f,
            .prdtl = prdt_len,
            .prdbc = 0,
            .ctba = ctba_phys,
            .reserved = [_]u32{0} ** 4,
        };
    }
};

pub const MaxPrdtEntries = 8;

pub const AhciCmdTable = extern struct {
    cfis: [64]u8 = [_]u8{0} ** 64, // Command FIS payload
    acmd: [16]u8 = [_]u8{0} ** 16, // ATAPI Command payload
    reserved: [48]u8 = [_]u8{0} ** 48,
    prdt: [MaxPrdtEntries]AhciPrdtEntry = [_]AhciPrdtEntry{.{}} ** MaxPrdtEntries,
};

comptime {
    std.debug.assert(@sizeOf(AhciCmdTable) == 256);
    std.debug.assert(@offsetOf(AhciCmdTable, "prdt") == 0x80);
    std.debug.assert(@sizeOf(AhciCmdHeader) == 32);
}

pub const DeviceType = enum {
    sata,
    atapi,
    unknown,
};

pub const AhciPortState = struct {
    port_idx: u5,
    device_type: DeviceType,
    total_sectors: u64 = 0,
    block_size: u32 = 512,
    /// True only when both HBA and device advertise NCQ support.
    ncq_supported: bool = false,
    command_slots: u6 = 1,

    // Per-port command list, tables and received-FIS area
    cmd_headers: [32]AhciCmdHeader align(1024) = [_]AhciCmdHeader{.{}} ** 32,
    cmd_tables: [32]AhciCmdTable align(128) = [_]AhciCmdTable{.{}} ** 32,
    received_fis: [256]u8 align(256) = [_]u8{0} ** 256,
};

pub const AhciDriver = struct {
    hba: *volatile AhciHbaRegisters,
    ports: [32]?AhciPortState = [_]?AhciPortState{null} ** 32,
    active_port_idx: ?u5 = null, // the default disk

    // Interrupt mode (enableInterrupts):
    // handleInterrupt moves each port's PxIS into soft_is
    // and acknowledges it; waits look at both. wait_hook, if
    // set, replaces the 10 us pause while a command runs and
    // returns about how many microseconds passed.
    soft_is: [32]u32 = [_]u32{0} ** 32,
    wait_hook: ?*const fn (ctx: *anyopaque) u32 = null,
    wait_ctx: ?*anyopaque = null,

    pub fn init(pci_bar5_address: usize) AhciDriver {
        return .{
            .hba = @as(*volatile AhciHbaRegisters, @ptrFromInt(pci_bar5_address)),
        };
    }

    fn stopPortEngine(port: *volatile AhciPortRegisters) !void {
        port.cmd = read32(&port.cmd) & (~PORT_CMD_ST);
        var t: u32 = 0;
        while ((read32(&port.cmd) & PORT_CMD_CR) != 0) : (t += 1) {
            if (t > 50_000) return error.PortResetTimeout; // 500 ms
            delayUsFn(10);
        }
        port.cmd = read32(&port.cmd) & (~PORT_CMD_FRE);
        t = 0;
        while ((read32(&port.cmd) & PORT_CMD_FR) != 0) : (t += 1) {
            if (t > 50_000) return error.PortResetTimeout;
            delayUsFn(10);
        }
    }

    fn waitPortReady(port: *volatile AhciPortRegisters, timeout_ms: u32) bool {
        var t: u32 = 0;
        while (t < timeout_ms) : (t += 1) {
            if ((read32(&port.tfd) & (TFD_BSY | TFD_DRQ)) == 0) return true;
            delayMs(1);
        }
        return false;
    }

    fn comReset(port: *volatile AhciPortRegisters) void {
        port.sctl = (read32(&port.sctl) & ~@as(u32, 0x0F)) | 1; // DET = 1: assert COMRESET
        delayMs(2); // must be held >= 1 ms
        port.sctl = read32(&port.sctl) & (~@as(u32, 0x0F));
        var w: u32 = 0;
        while (w < 200) : (w += 1) { // wait up to ~200 ms for the link to come back (DET == 3)
            if ((read32(&port.ssts) & 0x0F) == 3) break;
            delayMs(1);
        }
    }

    /// Stop/clear/restart the command
    /// engine after an error or timeout.
    fn recoverPort(self: *AhciDriver, port_idx: u5) void {
        const port = &self.hba.ports[port_idx];
        stopPortEngine(port) catch {};
        port.serr = 0xFFFF_FFFF;
        port.is = 0xFFFF_FFFF;
        self.soft_is[port_idx] = 0;
        if ((read32(&port.tfd) & (TFD_BSY | TFD_DRQ)) != 0) comReset(port);
        port.cmd = read32(&port.cmd) | (PORT_CMD_FRE);
        port.cmd = read32(&port.cmd) | (PORT_CMD_ST);
    }

    /// Iterates through implemented HBA ports, performs COMRESET if
    /// needed, detects SATA/ATAPI devices,
    /// and initializes all active ports.
    pub fn setupAndStart(self: *AhciDriver) !void {
        // 1. BIOS/OS Handoff negotiation
        if ((read32(&self.hba.cap2) & 1) != 0) {
            self.hba.bohc = read32(&self.hba.bohc) | ((1 << 1)); // Request OS Ownership
            var waited: u32 = 0;
            while ((read32(&self.hba.bohc) & (1 << 0)) != 0 and waited < 2000) : (waited += 1) delayMs(1);
        }

        // 2. AHCI mode on, HBA interrupts off: this driver polls,
        //    and the kernel has no handler for a stray one:
        self.hba.ghc = read32(&self.hba.ghc) | (@as(u32, 1 << 31));
        self.hba.ghc = read32(&self.hba.ghc) & (~@as(u32, 1 << 1));
        self.hba.is = 0xFFFF_FFFF;

        const ports_implemented = read32(&self.hba.pi);
        var found_any = false;
        var i: u5 = 0;
        while (true) {
            if ((ports_implemented & (@as(u32, 1) << i)) != 0) {
                // A failing port must not prevent
                // the other ports from being probed.
                if (self.probePort(i) catch false) found_any = true;
            }
            if (i == 31) break;
            i += 1;
        }

        if (!found_any) return error.NoActiveSataDiskFound;
    }

    fn probePort(self: *AhciDriver, i: u5) !bool {
        const port = &self.hba.ports[i];
        port.ie = 0;
        if ((read32(&port.ssts) & 0x0F) == 0) return false; // nothing attached

        // The device's signature only arrives in a D2H FIS, and the HBA
        // takes FISes in only while FIS receive (FRE) is on, which
        // firmware usually turns off when it lets go of the port.
        // So: the port's command list and FIS area first, FRE on, then
        // a COMRESET if no signature has come
        // yet (PxCMD.ST is 0 while DET changes).
        self.ports[i] = AhciPortState{ .port_idx = i, .device_type = .unknown };
        errdefer self.ports[i] = null;
        const p_state = &self.ports[i].?;
        try self.configurePortState(p_state, false);
        var ssts = read32(&port.ssts);
        if ((ssts & 0x0F) != 3 or read32(&port.sig) == 0xFFFF_FFFF) {
            stopPortEngine(port) catch {};
            port.cmd = read32(&port.cmd) | PORT_CMD_FRE;
            comReset(port);
            ssts = read32(&port.ssts);
        }
        const det = ssts & 0x0F;
        const ipm = (ssts >> 8) & 0x0F;
        if (det != 3 or ipm != 1) return error.NoDevice;

        // The signature is only valid once the device has sent its
        // first D2H FIS (BSY/DRQ clear).
        port.serr = 0xFFFF_FFFF;
        if (!waitPortReady(port, 2000)) return error.DeviceNotReady;

        const sig = read32(&port.sig);
        const dtype: DeviceType = switch (sig) {
            0x00000101 => .sata,
            0xEB140101 => .atapi, // SATA Optical Drive / CD-ROM
            else => return error.UnknownDevice,
        };
        p_state.device_type = dtype;
        try self.configurePortState(p_state, true);

        if (dtype == .sata) {
            try self.identifySataDisk(p_state);
        } else {
            try self.identifyAtapiDevice(p_state);
        }

        // The default block device is the first
        // SATA *disk*, never an optical drive.
        if (self.active_port_idx == null and dtype == .sata) {
            self.active_port_idx = i;
        }
        return true;
    }

    /// The port's command list and FIS area, FIS receive on; with
    /// `start` the command engine too
    fn configurePortState(self: *AhciDriver, p_state: *AhciPortState, start: bool) !void {
        const port = &self.hba.ports[p_state.port_idx];

        try stopPortEngine(port);

        // Without 64-bit addressing support (CAP.S64A) all DMA
        // structures must sit below 4 GB.
        if ((read32(&self.hba.cap) & (1 << 31)) == 0) {
            const end = virtToPhys(@intFromPtr(p_state)) + @sizeOf(AhciPortState);
            if ((end >> 32) != 0) return error.DmaAddressAbove4G;
        }

        const clb_phys = virtToPhys(@intFromPtr(&p_state.cmd_headers));
        port.clb = @as(u32, @intCast(clb_phys & 0xFFFFFFFF));
        port.clbu = @as(u32, @intCast((clb_phys >> 32) & 0xFFFFFFFF));

        const fb_phys = virtToPhys(@intFromPtr(&p_state.received_fis));
        port.fb = @as(u32, @intCast(fb_phys & 0xFFFFFFFF));
        port.fbu = @as(u32, @intCast((fb_phys >> 32) & 0xFFFFFFFF));
        memoryBarrier();

        port.serr = 0xFFFFFFFF;
        port.is = 0xFFFFFFFF;
        port.ie = 0;
        port.cmd = read32(&port.cmd) | (PORT_CMD_FRE);
        if (!start) return;
        // ST may only be set while the
        // device is idle (BSY and DRQ clear).
        if (!waitPortReady(port, 1000)) return error.PortNotReady;
        port.cmd = read32(&port.cmd) | (PORT_CMD_ST);

        // CAP.NCS is the zero-based number of command slots; cap at
        // our 32-entry arrays.
        const reported_slots: u6 = @intCast(((read32(&self.hba.cap) >> 8) & 0x1F) + 1);
        p_state.command_slots = reported_slots;
        // Device support is determined by IDENTIFY DEVICE word 76, so
        // host support alone is not sufficient to enable NCQ.
        p_state.ncq_supported = (read32(&self.hba.cap) & (1 << 30)) != 0;
    }

    fn buildPrdt(cmd_table: *AhciCmdTable, data_ptr: [*]u8, byte_len: usize) u16 {
        var remaining = byte_len;
        var cur_ptr = @intFromPtr(data_ptr);
        var prdt_count: u16 = 0;

        while (remaining > 0 and prdt_count < MaxPrdtEntries) {
            // Each PRDT entry can transfer up to
            // 4MB (mask 0x003F_FFFF + 1 bytes)
            const chunk_len = @min(remaining, 0x0040_0000);
            cmd_table.prdt[prdt_count] = AhciPrdtEntry.init(virtToPhys(cur_ptr), @intCast(chunk_len), false);
            remaining -= chunk_len;
            cur_ptr += chunk_len;
            prdt_count += 1;
        }
        // A nonzero remainder means the caller asked for more data than
        // our fixed PRDT can describe.
        // Returning zero makes the caller fail safely.
        if (remaining != 0) return 0;
        return prdt_count;
    }

    fn validDataTransfer(p_state: *const AhciPortState, count: u16, data_len: usize) bool {
        if (count == 0) return false;
        const expected = @as(u64, count) * p_state.block_size;
        return expected <= @as(u64, std.math.maxInt(usize)) and data_len == @as(usize, @intCast(expected)) and expected <= @as(u64, MaxPrdtEntries) * 0x0040_0000;
    }

    fn allocateNcqSlot(self: *AhciDriver, p_state: *AhciPortState) !u5 {
        const port = &self.hba.ports[p_state.port_idx];
        const occupied = read32(&port.ci) | read32(&port.sact);
        var slot: u6 = 0;
        while (slot < p_state.command_slots) : (slot += 1) {
            if ((occupied & (@as(u32, 1) << @as(u5, @intCast(slot)))) == 0) return @intCast(slot);
        }
        return error.NoFreeCommandSlot;
    }

    pub fn readSectors(self: *AhciDriver, lba: u64, count: u16, destination: []u8) !void {
        return self.readSectorsAt(self.active_port_idx orelse return error.DriverNotConfigured, lba, count, destination);
    }

    pub fn writeSectors(self: *AhciDriver, lba: u64, count: u16, source: []const u8) !void {
        return self.writeSectorsAt(self.active_port_idx orelse return error.DriverNotConfigured, lba, count, source);
    }

    /// readSectors on the disk at a given
    /// port (each SATA disk of the HBA)
    pub fn readSectorsAt(self: *AhciDriver, port_idx: u5, lba: u64, count: u16, destination: []u8) !void {
        if (self.ports[port_idx] == null) return error.PortNotConfigured;
        const p_state = &self.ports[port_idx].?;
        if (p_state.device_type != .sata) return error.NotSataDisk;
        if (!validDataTransfer(p_state, count, destination.len)) return error.InvalidTransferSize;
        if (lba >= (@as(u64, 1) << 48) or @as(u64, count) > ((@as(u64, 1) << 48) - lba)) return error.LbaOutOfRange;

        const slot: u5 = if (p_state.ncq_supported) try self.allocateNcqSlot(p_state) else 0;
        const cmd_table = &p_state.cmd_tables[slot];
        @memset(cmd_table.cfis[0..20], 0);

        // READ FPDMA QUEUED (0x60) when supported;
        // otherwise READ DMA EXT (0x25).
        cmd_table.cfis[0] = 0x27; // Register FIS - Host to Device
        cmd_table.cfis[1] = 0x80; // Set Command bit
        cmd_table.cfis[2] = if (p_state.ncq_supported) 0x60 else 0x25;
        if (p_state.ncq_supported) {
            cmd_table.cfis[3] = @truncate(count & 0xFF); // Features: sector count low
            cmd_table.cfis[11] = @truncate(count >> 8); // Features: sector count high
            cmd_table.cfis[12] = @as(u8, @intCast((@as(u16, slot) << 3) & 0xF8)); // tag
        }
        cmd_table.cfis[4] = @as(u8, @intCast(lba & 0xFF));
        cmd_table.cfis[5] = @as(u8, @intCast((lba >> 8) & 0xFF));
        cmd_table.cfis[6] = @as(u8, @intCast((lba >> 16) & 0xFF));
        cmd_table.cfis[7] = 0x40; // Device register: LBA mode
        cmd_table.cfis[8] = @as(u8, @intCast((lba >> 24) & 0xFF));
        cmd_table.cfis[9] = @as(u8, @intCast((lba >> 32) & 0xFF));
        cmd_table.cfis[10] = @as(u8, @intCast((lba >> 40) & 0xFF));
        if (!p_state.ncq_supported) {
            cmd_table.cfis[12] = @as(u8, @intCast(count & 0xFF));
            cmd_table.cfis[13] = @as(u8, @intCast((count >> 8) & 0xFF));
        } else {
            cmd_table.cfis[13] = 0; // Priority = 0; tag is in sector-count bits 7:3.
        }

        const byte_len: usize = @intCast(@as(u64, count) * p_state.block_size);
        const prdt_len = buildPrdt(cmd_table, destination.ptr, byte_len);
        if (prdt_len == 0) return error.TransferTooLarge;
        p_state.cmd_headers[slot] = AhciCmdHeader.init(5, false, prdt_len, virtToPhys(@intFromPtr(cmd_table)));

        if (p_state.ncq_supported) try self.sendNcqCommand(port_idx, slot) else try self.sendAhciCommand(port_idx, slot);
    }

    /// writeSectors on the disk at a given port
    pub fn writeSectorsAt(self: *AhciDriver, port_idx: u5, lba: u64, count: u16, source: []const u8) !void {
        if (self.ports[port_idx] == null) return error.PortNotConfigured;
        const p_state = &self.ports[port_idx].?;
        if (p_state.device_type != .sata) return error.NotSataDisk;
        if (!validDataTransfer(p_state, count, source.len)) return error.InvalidTransferSize;
        if (lba >= (@as(u64, 1) << 48) or @as(u64, count) > ((@as(u64, 1) << 48) - lba)) return error.LbaOutOfRange;

        const slot: u5 = if (p_state.ncq_supported) try self.allocateNcqSlot(p_state) else 0;
        const cmd_table = &p_state.cmd_tables[slot];

        @memset(cmd_table.cfis[0..20], 0);

        // WRITE FPDMA QUEUED (0x61) when supported;
        // otherwise WRITE DMA EXT (0x35).
        cmd_table.cfis[0] = 0x27; // Register FIS - Host to Device
        cmd_table.cfis[1] = 0x80; // Set Command bit
        cmd_table.cfis[2] = if (p_state.ncq_supported) 0x61 else 0x35;
        if (p_state.ncq_supported) {
            cmd_table.cfis[3] = @truncate(count & 0xFF);
            cmd_table.cfis[11] = @truncate(count >> 8);
            cmd_table.cfis[12] = @as(u8, @intCast((@as(u16, slot) << 3) & 0xF8));
        }
        cmd_table.cfis[4] = @as(u8, @intCast(lba & 0xFF));
        cmd_table.cfis[5] = @as(u8, @intCast((lba >> 8) & 0xFF));
        cmd_table.cfis[6] = @as(u8, @intCast((lba >> 16) & 0xFF));
        cmd_table.cfis[7] = 0x40; // Device register: LBA mode
        cmd_table.cfis[8] = @as(u8, @intCast((lba >> 24) & 0xFF));
        cmd_table.cfis[9] = @as(u8, @intCast((lba >> 32) & 0xFF));
        cmd_table.cfis[10] = @as(u8, @intCast((lba >> 40) & 0xFF));
        if (!p_state.ncq_supported) {
            cmd_table.cfis[12] = @as(u8, @intCast(count & 0xFF));
            cmd_table.cfis[13] = @as(u8, @intCast((count >> 8) & 0xFF));
        } else {
            cmd_table.cfis[13] = 0; // Priority = 0; tag is in sector-count bits 7:3.
        }

        const byte_len: usize = @intCast(@as(u64, count) * p_state.block_size);
        const prdt_len = buildPrdt(cmd_table, @constCast(source.ptr), byte_len);
        if (prdt_len == 0) return error.TransferTooLarge;
        p_state.cmd_headers[slot] = AhciCmdHeader.init(5, true, prdt_len, virtToPhys(@intFromPtr(cmd_table)));

        if (p_state.ncq_supported) try self.sendNcqCommand(port_idx, slot) else try self.sendAhciCommand(port_idx, slot);
    }

    /// FLUSH CACHE EXT: the disk's write
    /// cache to the medium (before power off)
    pub fn flushAt(self: *AhciDriver, port_idx: u5) !void {
        if (self.ports[port_idx] == null) return error.PortNotConfigured;
        const p_state = &self.ports[port_idx].?;
        if (p_state.device_type != .sata) return error.NotSataDisk;
        const cmd_table = &p_state.cmd_tables[0];
        @memset(cmd_table.cfis[0..20], 0);
        cmd_table.cfis[0] = 0x27; // Register FIS - Host to Device
        cmd_table.cfis[1] = 0x80; // Command
        cmd_table.cfis[2] = 0xEA; // FLUSH CACHE EXT
        cmd_table.cfis[7] = 0x40;
        p_state.cmd_headers[0] = AhciCmdHeader.init(5, false, 0, virtToPhys(@intFromPtr(cmd_table)));
        try self.sendAhciCommand(port_idx, 0);
    }

    /// Submit an NCQ read without waiting for completion.
    /// Returns the command tag/slot. The destination buffer must
    /// remain valid and DMA-accessible
    /// until waitNcqCompletion succeeds.
    pub fn submitNcqRead(self: *AhciDriver, lba: u64, count: u16, destination: []u8) !u5 {
        return self.submitNcqTransfer(lba, count, destination.ptr, destination.len, false);
    }

    /// Submit an NCQ write without waiting for completion.
    /// The source buffer must remain valid and DMA-accessible
    /// until waitNcqCompletion succeeds.
    pub fn submitNcqWrite(self: *AhciDriver, lba: u64, count: u16, source: []const u8) !u5 {
        return self.submitNcqTransfer(lba, count, @constCast(source.ptr), source.len, true);
    }

    fn submitNcqTransfer(self: *AhciDriver, lba: u64, count: u16, data: [*]u8, data_len: usize, is_write: bool) !u5 {
        const port_idx = self.active_port_idx orelse return error.DriverNotConfigured;
        const p_state = &self.ports[port_idx].?;
        if (p_state.device_type != .sata) return error.NotSataDisk;
        if (!p_state.ncq_supported) return error.NcqNotSupported;
        if (!validDataTransfer(p_state, count, data_len)) return error.InvalidTransferSize;
        if (lba >= (@as(u64, 1) << 48) or @as(u64, count) > ((@as(u64, 1) << 48) - lba)) return error.LbaOutOfRange;

        const slot = try self.allocateNcqSlot(p_state);
        const bit = @as(u32, 1) << slot;
        const cmd_table = &p_state.cmd_tables[slot];
        @memset(cmd_table.cfis[0..20], 0);
        cmd_table.cfis[0] = 0x27;
        cmd_table.cfis[1] = 0x80;
        cmd_table.cfis[2] = if (is_write) 0x61 else 0x60;
        cmd_table.cfis[3] = @truncate(count & 0xFF); // Features: sector count low
        cmd_table.cfis[4] = @truncate(lba & 0xFF);
        cmd_table.cfis[5] = @truncate((lba >> 8) & 0xFF);
        cmd_table.cfis[6] = @truncate((lba >> 16) & 0xFF);
        cmd_table.cfis[7] = 0x40;
        cmd_table.cfis[8] = @truncate((lba >> 24) & 0xFF);
        cmd_table.cfis[9] = @truncate((lba >> 32) & 0xFF);
        cmd_table.cfis[10] = @truncate((lba >> 40) & 0xFF);
        cmd_table.cfis[11] = @truncate(count >> 8); // Features: sector count high
        cmd_table.cfis[12] = @as(u8, @intCast((@as(u16, slot) << 3) & 0xF8)); // NCQ tag
        cmd_table.cfis[13] = 0; // Priority

        const prdt_len = buildPrdt(cmd_table, data, data_len);
        if (prdt_len == 0) return error.TransferTooLarge;
        p_state.cmd_headers[slot] = AhciCmdHeader.init(5, is_write, prdt_len, virtToPhys(@intFromPtr(cmd_table)));

        const port = &self.hba.ports[port_idx];
        // Clear stale W1C status only when the queue is idle; do not
        // erase status while other asynchronous
        // commands may still be running.
        if ((read32(&port.ci) | read32(&port.sact)) == 0) {
            port.serr = 0xFFFF_FFFF;
            port.is = 0xFFFF_FFFF;
        }
        memoryBarrier();
        port.sact = read32(&port.sact) | bit;
        port.ci = read32(&port.ci) | bit;
        return slot;
    }

    /// Wait for an asynchronously submitted NCQ command to finish.
    /// The slot remains owned by the caller until this returns;
    /// call it once for each submitted tag.
    pub fn waitNcqCompletion(self: *AhciDriver, slot: u5) !void {
        const port_idx = self.active_port_idx orelse return error.DriverNotConfigured;
        try self.waitSlotDone(port_idx, @as(u32, 1) << slot);
    }

    // ATAPI packet commands
    pub fn sendAtapiCommand(self: *AhciDriver, port_idx: u5, scsi_pkt: []const u8, destination: []u8) !void {
        if (self.ports[port_idx] == null) return error.PortNotConfigured;
        const p_state = &self.ports[port_idx].?;
        if (p_state.device_type != .atapi) return error.NotAtapiDevice;
        if (scsi_pkt.len != 12 and scsi_pkt.len != 16) return error.InvalidAtapiPacketLength;

        const slot: u5 = 0;
        const cmd_table = &p_state.cmd_tables[slot];
        @memset(cmd_table.cfis[0..20], 0);
        cmd_table.cfis[0] = 0x27; // Register FIS: host to device
        cmd_table.cfis[1] = 0x80; // Command bit
        cmd_table.cfis[2] = 0xA0; // PACKET
        cmd_table.cfis[3] = 1; // DMA feature; PRDT carries the data payload
        const byte_count_limit: usize = @min(destination.len, 0xFFFE);
        cmd_table.cfis[5] = @truncate(byte_count_limit & 0xFF);
        cmd_table.cfis[6] = @truncate((byte_count_limit >> 8) & 0xFF);

        @memset(&cmd_table.acmd, 0);
        @memcpy(cmd_table.acmd[0..scsi_pkt.len], scsi_pkt);

        var prdt_len: u16 = 0;
        if (destination.len > 0) {
            prdt_len = buildPrdt(cmd_table, destination.ptr, destination.len);
            if (prdt_len == 0) return error.TransferTooLarge;
        }

        var header = AhciCmdHeader.init(5, false, prdt_len, virtToPhys(@intFromPtr(cmd_table)));
        header.flags |= (1 << 5); // ATAPI
        p_state.cmd_headers[slot] = header;
        try self.sendAhciCommand(port_idx, slot);
    }

    /// SCSI INQUIRY (36-byte response) for an ATAPI device.
    pub fn atapiInquiry(self: *AhciDriver, port_idx: u5, response: []u8) !void {
        if (response.len < 36) return error.BufferTooSmall;
        const cdb = [_]u8{ 0x12, 0, 0, 0, 36, 0, 0, 0, 0, 0, 0, 0 };
        try self.sendAtapiCommand(port_idx, &cdb, response[0..36]);
    }

    /// SCSI READ CAPACITY(10).
    /// Response contains last LBA and block size, big-endian.
    pub fn atapiReadCapacity(self: *AhciDriver, port_idx: u5, response: []u8) !void {
        if (response.len < 8) return error.BufferTooSmall;
        const cdb = [_]u8{ 0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        try self.sendAtapiCommand(port_idx, &cdb, response[0..8]);
        const p_state = &self.ports[port_idx].?;
        const last_lba = (@as(u32, response[0]) << 24) | (@as(u32, response[1]) << 16) | (@as(u32, response[2]) << 8) | response[3];
        const block_size = (@as(u32, response[4]) << 24) | (@as(u32, response[5]) << 16) | (@as(u32, response[6]) << 8) | response[7];
        if (block_size == 0) return error.InvalidBlockSize;
        p_state.total_sectors = @as(u64, last_lba) + 1;
        p_state.block_size = block_size;
    }

    /// SCSI READ TOC/PMA/ATIP, format 0,
    /// returning up to response.len bytes.
    pub fn atapiReadToc(self: *AhciDriver, port_idx: u5, response: []u8) !void {
        if (response.len < 4 or response.len > 0xFFFF) return error.InvalidTransferSize;
        const cdb = [_]u8{ 0x43, 0x02, 0, 0, 0, 0, 0, @truncate((response.len >> 8) & 0xFF), @truncate(response.len & 0xFF), 0, 0, 0 };
        try self.sendAtapiCommand(port_idx, &cdb, response);
    }

    /// SCSI READ (12), useful for data CD/DVD media. Buffer must be
    /// exactly count * block_size.
    pub fn atapiReadBlocks(self: *AhciDriver, port_idx: u5, lba: u32, count: u32, destination: []u8) !void {
        if (count == 0) return error.InvalidTransferSize;
        if (self.ports[port_idx] == null) return error.PortNotConfigured;
        const p_state = &self.ports[port_idx].?;
        if (p_state.device_type != .atapi) return error.NotAtapiDevice;
        const expected = @as(u64, count) * p_state.block_size;
        if (expected != destination.len or expected > @as(u64, MaxPrdtEntries) * 0x0040_0000) return error.InvalidTransferSize;
        const cdb = [_]u8{ 0xA8, 0, @truncate((lba >> 24) & 0xFF), @truncate((lba >> 16) & 0xFF), @truncate((lba >> 8) & 0xFF), @truncate(lba & 0xFF), @truncate((count >> 24) & 0xFF), @truncate((count >> 16) & 0xFF), @truncate((count >> 8) & 0xFF), @truncate(count & 0xFF), 0, 0 };
        try self.sendAtapiCommand(port_idx, &cdb, destination);
    }


    /// Wait until `bit` is no longer pending in CI/SACT. Errors are
    /// detected through PxIS while waiting (a fatal error halts the
    /// engine and leaves CI set, so CI alone would just time out)
    /// and through PxTFD afterwards. DRQ is NOT an error:
    /// PIO/DMA data phases legitimately assert it.
    fn waitSlotDone(self: *AhciDriver, port_idx: u5, bit: u32) !void {
        const port = &self.hba.ports[port_idx];
        var left: u32 = 500_000; // x 10 us = 5 s
        while (((read32(&port.ci) | read32(&port.sact)) & bit) != 0) {
            if (left == 0) {
                self.recoverPort(port_idx);
                return error.DeviceTimeout;
            }
            if (((read32(&port.is) | self.soft_is[port_idx]) & PORT_IS_ERR_MASK) != 0) {
                self.recoverPort(port_idx);
                return error.SataDiskHardwareTransferError;
            }
            if (self.wait_hook) |hook| {
                left -|= @max(1, hook(self.wait_ctx.?) / 10);
            } else {
                delayUsFn(10);
                left -= 1;
            }
        }
        if (((read32(&port.is) | self.soft_is[port_idx]) & PORT_IS_ERR_MASK) != 0 or (read32(&port.tfd) & (TFD_ERR | TFD_DF)) != 0) {
            self.recoverPort(port_idx);
            return error.SataDiskHardwareTransferError;
        }
        // Acknowledge normal completion status (DHRS/PSS/DPS/SDBS...)
        // once nothing else is in flight.
        if ((read32(&port.ci) | read32(&port.sact)) == 0) {
            port.is = 0xFFFF_FFFF;
            self.soft_is[port_idx] = 0;
        }
    }

    /// Interrupts on for the started ports (completions and
    /// errors), and the HBA's.
    /// The OS has set up its message (MSI) and handler first.
    pub fn enableInterrupts(self: *AhciDriver) void {
        const wanted: u32 = 0x3F | PORT_IS_ERR_MASK; // DHRS PSS DSS SDBS UFS DPS, errors
        for (&self.ports, 0..) |*p, i| {
            if (p.* == null) continue;
            const port = &self.hba.ports[i];
            port.is = 0xFFFF_FFFF;
            port.ie = wanted;
        }
        self.hba.is = 0xFFFF_FFFF;
        self.hba.ghc = read32(&self.hba.ghc) | (1 << 1);
    }

    /// From the OS's interrupt handler: each port's status kept for
    /// the waiters and acknowledged, then the HBA's
    pub fn handleInterrupt(self: *AhciDriver) void {
        const pending = read32(&self.hba.is);
        var i: u6 = 0;
        while (i < 32) : (i += 1) {
            if (pending & (@as(u32, 1) << @intCast(i)) == 0) continue;
            const port = &self.hba.ports[i];
            const pis = read32(&port.is);
            self.soft_is[i] |= pis;
            port.is = pis;
        }
        self.hba.is = pending;
    }

    fn sendNcqCommand(self: *AhciDriver, port_idx: u5, slot: u5) !void {
        const port = &self.hba.ports[port_idx];
        const bit = @as(u32, 1) << slot;
        if (!waitPortReady(port, 1000)) {
            self.recoverPort(port_idx);
            return error.DeviceBusy;
        }
        // Clear stale W1C status only if no
        // other queued command is active.
        if ((read32(&port.ci) | read32(&port.sact)) == 0) {
            port.serr = 0xFFFF_FFFF;
            port.is = 0xFFFF_FFFF;
            self.soft_is[port_idx] = 0;
        }
        memoryBarrier();
        port.sact = read32(&port.sact) | bit;
        port.ci = read32(&port.ci) | bit;
        try self.waitSlotDone(port_idx, bit);
    }

    fn sendAhciCommand(self: *AhciDriver, port_idx: u5, slot: u5) !void {
        const port = &self.hba.ports[port_idx];
        const bit = @as(u32, 1) << slot;
        if (!waitPortReady(port, 1000)) {
            self.recoverPort(port_idx);
            return error.DeviceBusy;
        }
        // Stale error bits from an earlier
        // command would otherwise fail this one.
        if ((read32(&port.ci) | read32(&port.sact)) == 0) {
            port.serr = 0xFFFF_FFFF;
            port.is = 0xFFFF_FFFF;
            self.soft_is[port_idx] = 0;
        }
        memoryBarrier();
        port.ci = bit;
        try self.waitSlotDone(port_idx, bit);
    }

    fn identifySataDisk(self: *AhciDriver, p_state: *AhciPortState) !void {
        var identify_buf: [256]u16 align(16) = [_]u16{0} ** 256;
        const slot: u5 = 0;
        const cmd_table = &p_state.cmd_tables[slot];

        @memset(cmd_table.cfis[0..20], 0);
        cmd_table.cfis[0] = 0x27;
        cmd_table.cfis[1] = 0x80;
        cmd_table.cfis[2] = 0xEC; // IDENTIFY DEVICE

        const prdt_len = buildPrdt(cmd_table, @ptrCast(&identify_buf), 512);
        p_state.cmd_headers[slot] = AhciCmdHeader.init(5, false, prdt_len, virtToPhys(@intFromPtr(cmd_table)));

        try self.sendAhciCommand(p_state.port_idx, slot);

        const lba48_sectors = (@as(u64, identify_buf[103]) << 48) |
            (@as(u64, identify_buf[102]) << 32) |
            (@as(u64, identify_buf[101]) << 16) |
            @as(u64, identify_buf[100]);
        p_state.total_sectors = if (lba48_sectors > 0) lba48_sectors else (@as(u32, identify_buf[61]) << 16) | identify_buf[60];
        // Logical sector size: word 106 valid when bit 14 set /
        // bit 15 clear; bit 12 means the logical sector is longer
        // than 256 words, with its length in words 117-118.
        var bs: u32 = 512;
        const w106 = identify_buf[106];
        if ((w106 & 0xC000) == 0x4000 and (w106 & (1 << 12)) != 0) {
            const words: u32 = (@as(u32, identify_buf[118]) << 16) | identify_buf[117];
            if (words != 0) bs = words * 2;
        }
        p_state.block_size = bs;
        // IDENTIFY DEVICE word 76 bit 8 advertises NCQ support.
        p_state.ncq_supported = p_state.ncq_supported and (identify_buf[76] & (1 << 8)) != 0;
        if (p_state.ncq_supported) {
            // Word 75 bits 4:0 = device queue depth
            // - 1; tags beyond it are invalid.
            const depth: u6 = @intCast((identify_buf[75] & 0x1F) + 1);
            p_state.command_slots = @min(p_state.command_slots, depth);
        }
    }

    fn identifyAtapiDevice(self: *AhciDriver, p_state: *AhciPortState) !void {
        p_state.total_sectors = 0;
        p_state.block_size = 2048; // Typical optical data sector size; capacity command refines this.
        var capacity: [8]u8 = [_]u8{0} ** 8;
        self.atapiReadCapacity(p_state.port_idx, &capacity) catch {
            // Some optical drives report NOT READY when
            // no media is inserted. Keep the device
            // available for INQUIRY/TOC and retry
            // capacity after media insertion.
            return;
        };
    }

    // SHARING THE HBA WITH FIRMWARE (THE BIOS EDITION)
    // The BIOS goes on using the ports ZDOS doesn't take (int 13h
    // for its other disks, a CD): no handoff, nothing HBA-wide, no
    // COMRESET. A port is borrowed with its
    // registers saved, and given back as it was.

    pub const SavedPort = struct { clb: u32, clbu: u32, fb: u32, fbu: u32, cmd: u32, ie: u32 };

    /// Port i's SATA disk on ZDOS's command list, identified; null
    /// (the port untouched, or given back) unless it is a disk the
    /// firmware has up and idle. returnPort
    /// gives it back unless the caller keeps it.
    pub fn borrowPort(self: *AhciDriver, i: u5) ?SavedPort {
        if ((read32(&self.hba.pi) & (@as(u32, 1) << i)) == 0) return null;
        const port = &self.hba.ports[i];
        const ssts = read32(&port.ssts);
        if ((ssts & 0x0F) != 3 or ((ssts >> 8) & 0x0F) != 1) return null; // no link, or a power-saving state
        if (read32(&port.sig) != 0x00000101) return null; // not a disk (ATAPI, or nothing seen)
        if ((read32(&port.ci) | read32(&port.sact)) != 0) return null; // a command running
        const saved: SavedPort = .{
            .clb = read32(&port.clb),
            .clbu = read32(&port.clbu),
            .fb = read32(&port.fb),
            .fbu = read32(&port.fbu),
            .cmd = read32(&port.cmd),
            .ie = read32(&port.ie),
        };
        self.ports[i] = AhciPortState{ .port_idx = i, .device_type = .sata };
        const p_state = &self.ports[i].?;
        self.configurePortState(p_state, true) catch {
            self.returnPort(i, saved);
            return null;
        };
        self.identifySataDisk(p_state) catch {
            self.returnPort(i, saved);
            return null;
        };
        return saved;
    }

    /// Port i back to the firmware: its command list, FIS area,
    /// interrupt enables and engine state
    /// as they were before borrowPort
    pub fn returnPort(self: *AhciDriver, i: u5, saved: SavedPort) void {
        const port = &self.hba.ports[i];
        stopPortEngine(port) catch {};
        port.clb = saved.clb;
        port.clbu = saved.clbu;
        port.fb = saved.fb;
        port.fbu = saved.fbu;
        memoryBarrier();
        port.serr = 0xFFFF_FFFF;
        port.is = 0xFFFF_FFFF;
        port.ie = saved.ie;
        if ((saved.cmd & PORT_CMD_FRE) != 0) port.cmd = read32(&port.cmd) | PORT_CMD_FRE;
        if ((saved.cmd & PORT_CMD_ST) != 0) {
            _ = waitPortReady(port, 1000);
            port.cmd = read32(&port.cmd) | PORT_CMD_ST;
        }
        self.ports[i] = null;
        self.soft_is[i] = 0;
        if (self.active_port_idx) |a| {
            if (a == i) self.active_port_idx = null;
        }
    }

    // ZDOS adapter
    pub fn zdosRead(ctx: *const anyopaque, lba: u64, count: usize, buf: []u8) !void {
        const self: *AhciDriver = @ptrCast(@alignCast(@constCast(ctx)));
        const port_idx = self.active_port_idx orelse return error.DriverNotConfigured;
        const p_state = &self.ports[port_idx].?;

        if (buf.len < count * p_state.block_size) return error.BufferTooSmall;
        var remaining = count;
        var cur_lba = lba;
        var offset: usize = 0;
        while (remaining > 0) {
            const chunk: u16 = @intCast(@min(remaining, 128));
            const byte_len = @as(usize, chunk) * p_state.block_size;
            try self.readSectors(cur_lba, chunk, buf[offset .. offset + byte_len]);
            remaining -= chunk;
            cur_lba += chunk;
            offset += byte_len;
        }
    }

    pub fn zdosWrite(ctx: *const anyopaque, lba: u64, count: usize, data: []const u8) !void {
        const self: *AhciDriver = @ptrCast(@alignCast(@constCast(ctx)));
        const port_idx = self.active_port_idx orelse return error.DriverNotConfigured;
        const p_state = &self.ports[port_idx].?;

        if (data.len < count * p_state.block_size) return error.BufferTooSmall;
        var remaining = count;
        var cur_lba = lba;
        var offset: usize = 0;
        while (remaining > 0) {
            const chunk: u16 = @intCast(@min(remaining, 128));
            const byte_len = @as(usize, chunk) * p_state.block_size;
            try self.writeSectors(cur_lba, chunk, data[offset .. offset + byte_len]);
            remaining -= chunk;
            cur_lba += chunk;
            offset += byte_len;
        }
    }

    pub const ZdosBlockDevice = struct {
        ctx: *const anyopaque,
        read: *const fn (ctx: *const anyopaque, lba: u64, count: usize, buf: []u8) anyerror!void,
        write: *const fn (ctx: *const anyopaque, lba: u64, count: usize, data: []const u8) anyerror!void,
    };

    pub fn asZdosDevice(self: *AhciDriver) ZdosBlockDevice {
        return .{
            .ctx = self,
            .read = zdosRead,
            .write = zdosWrite,
        };
    }
};
