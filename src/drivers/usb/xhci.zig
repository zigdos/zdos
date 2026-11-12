//! xHCI 1.x host controller.
//!
//! BAR0 mapped uncached, bus mastering on;
//! without identity mapping set
//! `virtualToPhysicalFn` before `init`.
//! XhciDriver is ~400 KB (rings, contexts):
//! a global, never on a stack.

const std = @import("std");
const builtin = @import("builtin");

pub const MaxSlots = 32;
pub const RingSize = 64;
pub const EndpointRingsPerSlot = 4;
pub const MaxScratchpads = 32;

// Platform hooks

pub var virtualToPhysicalFn: *const fn (virtual_address: usize) u64 = defaultVirtualToPhysical;

pub fn defaultVirtualToPhysical(virtual_address: usize) u64 {
    return @as(u64, virtual_address);
}

pub inline fn virtToPhys(va: usize) u64 {
    return virtualToPhysicalFn(va);
}

/// Replace with a real timer-based delay when you have one.
/// The default is ~1us per iteration on x86.
pub var delayUsFn: *const fn (us: u32) void = defaultDelayUs;

pub fn defaultDelayUs(us: u32) void {
    var i: u32 = 0;
    while (i < us) : (i += 1) {
        if (comptime builtin.cpu.arch.isX86()) {
            // A write to the POST port takes roughly
            // one microsecond on PC hardware.
            asm volatile ("outb %[v], $0x80"
                :
                : [v] "{al}" (@as(u8, 0)),
            );
        } else {
            cpuRelax();
        }
    }
}

pub fn delayMs(ms: u32) void {
    var i: u32 = 0;
    while (i < ms) : (i += 1) delayUsFn(1000);
}

inline fn cpuRelax() void {
    if (comptime builtin.cpu.arch.isX86()) {
        asm volatile ("pause");
    } else if (comptime builtin.cpu.arch.isAARCH64()) {
        asm volatile ("yield");
    }
}

pub inline fn memoryBarrier() void {
    if (comptime builtin.cpu.arch.isX86()) {
        asm volatile ("mfence" ::: "memory");
    } else if (comptime builtin.cpu.arch.isAARCH64()) {
        asm volatile ("dmb sy" ::: "memory");
    } else {
        asm volatile ("" ::: "memory");
    }
}

const read32 = @import("../../arch/mmio.zig").load32; // full width: never narrowed (QEMU answers a narrowed port read with 0)

inline fn rd32(addr: usize) u32 {
    return read32(@ptrFromInt(addr));
}
inline fn wr32(addr: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(addr)).* = v;
}
/// 64-bit registers are written as two dwords, low first, which
/// is valid with or without AC64.
inline fn set64(lo: *volatile u32, hi: *volatile u32, v: u64) void {
    lo.* = @truncate(v);
    hi.* = @truncate(v >> 32);
}

// Registers

pub const CapabilityRegisters = extern struct {
    cap_length: u8, // byte 0 of dword 0 (read the whole dword on real hardware)
    reserved: u8,
    hci_version: u16,
    hcs_params1: u32,
    hcs_params2: u32,
    hcs_params3: u32,
    hcc_params1: u32,
    doorbell_offset: u32,
    runtime_offset: u32,
    hcc_params2: u32,
};

pub const OperationalRegisters = extern struct {
    usb_cmd: u32, // 0x00
    usb_sts: u32, // 0x04
    page_size: u32, // 0x08
    reserved1: [2]u32, // 0x0C
    dn_ctrl: u32, // 0x14
    crcr_lo: u32, // 0x18
    crcr_hi: u32, // 0x1C
    reserved2: [4]u32, // 0x20
    dcbaap_lo: u32, // 0x30
    dcbaap_hi: u32, // 0x34
    config: u32, // 0x38
};

pub const PortRegisters = extern struct {
    portsc: u32,
    portpmsc: u32,
    portli: u32,
    porthlpmc: u32,
};

pub const InterrupterRegisters = extern struct {
    iman: u32,
    imod: u32,
    erstsz: u32,
    reserved: u32,
    erstba_lo: u32,
    erstba_hi: u32,
    erdp_lo: u32,
    erdp_hi: u32,
};

pub const RuntimeRegisters = extern struct {
    mfindex: u32,
    reserved: [7]u32,
    interrupters: InterrupterRegisters, // interrupter 0 at 0x20
};

comptime {
    std.debug.assert(@offsetOf(OperationalRegisters, "dn_ctrl") == 0x14);
    std.debug.assert(@offsetOf(OperationalRegisters, "crcr_lo") == 0x18);
    std.debug.assert(@offsetOf(OperationalRegisters, "dcbaap_lo") == 0x30);
    std.debug.assert(@offsetOf(OperationalRegisters, "config") == 0x38);
    std.debug.assert(@offsetOf(RuntimeRegisters, "interrupters") == 0x20);
    std.debug.assert(@sizeOf(PortRegisters) == 16);
    std.debug.assert(@sizeOf(Trb) == 16);
}

const CMD_RS: u32 = 1 << 0;
const CMD_HCRST: u32 = 1 << 1;
const CMD_INTE: u32 = 1 << 2;
const STS_HCH: u32 = 1 << 0;
const STS_EINT: u32 = 1 << 3;
const STS_CNR: u32 = 1 << 11;

pub const PORTSC_CCS: u32 = 1 << 0;
pub const PORTSC_PED: u32 = 1 << 1;
pub const PORTSC_PR: u32 = 1 << 4;
pub const PORTSC_PP: u32 = 1 << 9;
pub const PORTSC_CSC: u32 = 1 << 17;
pub const PORTSC_PEC: u32 = 1 << 18;
pub const PORTSC_WRC: u32 = 1 << 19;
pub const PORTSC_OCC: u32 = 1 << 20;
pub const PORTSC_PRC: u32 = 1 << 21;
pub const PORTSC_PLC: u32 = 1 << 22;
pub const PORTSC_CEC: u32 = 1 << 23;
pub const PORTSC_WPR: u32 = 1 << 31;
pub const PORTSC_CHANGE_BITS: u32 = PORTSC_CSC | PORTSC_PEC | PORTSC_WRC | PORTSC_OCC | PORTSC_PRC | PORTSC_PLC | PORTSC_CEC;

/// PORTSC mixes RW1C bits (PED, change bits)
/// with ordinary bits. Writing back a value read
/// from the register would disable the port and
/// clear pending changes, so every write starts
/// from this "neutral" value (only the preserved
/// RW bits) and ORs in exactly what it wants.
inline fn portNeutral(sc: u32) u32 {
    return sc & ((1 << 9) | (3 << 14) | (7 << 25));
}

pub const PortSpeed = enum(u8) {
    low,
    full,
    high,
    super,

    /// Value for the Slot Context "speed"
    /// field and PORTSC speed IDs.
    pub fn slotSpeed(self: PortSpeed) u32 {
        return switch (self) {
            .full => 1,
            .low => 2,
            .high => 3,
            .super => 4,
        };
    }
    pub fn defaultEp0MaxPacket(self: PortSpeed) u16 {
        return switch (self) {
            .low => 8,
            .full => 8, // real value is read from the first 8 bytes of the device descriptor
            .high => 64,
            .super => 512,
        };
    }
};

// TRBs and rings

pub const TRB_NORMAL: u32 = 1;
pub const TRB_SETUP: u32 = 2;
pub const TRB_DATA: u32 = 3;
pub const TRB_STATUS: u32 = 4;
pub const TRB_LINK: u32 = 6;
pub const TRB_ENABLE_SLOT: u32 = 9;
pub const TRB_DISABLE_SLOT: u32 = 10;
pub const TRB_ADDRESS_DEVICE: u32 = 11;
pub const TRB_CONFIGURE_ENDPOINT: u32 = 12;
pub const TRB_EVALUATE_CONTEXT: u32 = 13;
pub const TRB_RESET_ENDPOINT: u32 = 14;
pub const TRB_SET_TR_DEQUEUE: u32 = 16;
pub const TRB_TRANSFER_EVENT: u32 = 32;
pub const TRB_CMD_COMPLETION: u32 = 33;
pub const TRB_PORT_STATUS_CHANGE: u32 = 34;

pub const TRB_TC: u32 = 1 << 1; // link TRB: toggle cycle
pub const TRB_CH: u32 = 1 << 4; // chain bit
pub const TRB_ISP: u32 = 1 << 2; // interrupt on short packet
pub const TRB_IOC: u32 = 1 << 5; // interrupt on completion
pub const TRB_IDT: u32 = 1 << 6; // immediate data (setup stage)
pub const TRB_DIR_IN: u32 = 1 << 16;

/// Generic TRB: dword0-1 parameter, dword2 status, dword3
/// control (bit0 cycle, bits 15:10 TRB
/// type, everything else type-specific).
pub const Trb = extern struct {
    parameter: u64,
    status: u32,
    control: u32,
};

/// A 64-entry ring. Aligned to its own size so it can never
/// straddle a 64 KB boundary.
pub const TrbRing = struct {
    trbs: [RingSize]Trb align(1024),
    enqueue: u32,
    cycle: u1,

    pub fn reset(self: *TrbRing) void {
        @memset(std.mem.asBytes(&self.trbs), 0);
        self.enqueue = 0;
        self.cycle = 1;
    }

    pub fn phys(self: *const TrbRing) u64 {
        return virtToPhys(@intFromPtr(&self.trbs));
    }

    /// Queue one TRB. `control` must not contain the cycle bit.
    /// Returns the TRB's physical address (the value the matching
    /// Transfer/Command event reports).
    /// The caller rings the doorbell.
    pub fn push(self: *TrbRing, parameter: u64, status: u32, control: u32) u64 {
        const idx = self.enqueue;
        const slot: *volatile Trb = &self.trbs[idx];
        slot.parameter = parameter;
        slot.status = status;
        memoryBarrier();
        slot.control = (control & ~@as(u32, 1)) | @as(u32, self.cycle);
        const addr = virtToPhys(@intFromPtr(&self.trbs[idx]));

        self.enqueue += 1;
        if (self.enqueue == RingSize - 1) {
            // Last slot is a Link TRB back to the start; it carries the
            // current cycle bit, then the producer
            // cycle toggles for the next lap.
            const link: *volatile Trb = &self.trbs[RingSize - 1];
            link.parameter = self.phys();
            link.status = 0;
            memoryBarrier();
            link.control = (TRB_LINK << 10) | TRB_TC | @as(u32, self.cycle);
            self.enqueue = 0;
            self.cycle ^= 1;
        }
        return addr;
    }
};

pub const EventRing = struct {
    trbs: [RingSize]Trb align(1024),
    dequeue: u32,
    cycle: u1,

    pub fn reset(self: *EventRing) void {
        @memset(std.mem.asBytes(&self.trbs), 0);
        self.dequeue = 0;
        self.cycle = 1;
    }

    pub fn peek(self: *const EventRing) ?Trb {
        const t: *const volatile Trb = &self.trbs[self.dequeue];
        const control = t.control;
        if ((control & 1) != @as(u32, self.cycle)) return null;
        memoryBarrier();
        return Trb{ .parameter = t.parameter, .status = t.status, .control = control };
    }

    pub fn advance(self: *EventRing) void {
        self.dequeue += 1;
        if (self.dequeue == RingSize) {
            self.dequeue = 0;
            self.cycle ^= 1;
        }
    }
};

pub const ErstEntry = extern struct {
    segment_base_address: u64 = 0,
    segment_size: u16 = 0,
    reserved0: u16 = 0,
    reserved1: u32 = 0,
};

// Contexts

/// 32 contexts * 64 bytes = 2048 (worst case); 2048-aligned so
/// a context never crosses a page.
const DeviceContextStorage = struct { bytes: [2048]u8 align(2048) };

/// Describes one endpoint to add
/// with a Configure Endpoint command.
pub const EndpointSetup = struct {
    dci: u8, // device context index = ep_number * 2 + (IN ? 1 : 0)
    ep_type: u8, // xHCI endpoint type (see xhciEndpointType)
    max_packet_size: u16,
    interval: u8, // xHCI interval exponent (see endpointInterval)
};

/// Convert a USB endpoint descriptor's transfer type +
/// direction to the xHCI EP Type field.
pub fn xhciEndpointType(attributes: u8, is_in: bool) u8 {
    return switch (attributes & 3) {
        0 => 4, // control
        1 => if (is_in) 5 else 1, // isochronous
        2 => if (is_in) 6 else 2, // bulk
        else => if (is_in) 7 else 3, // interrupt
    };
}

/// Convert bInterval to the xHCI interval
/// exponent (period = 2^n * 125 us).
pub fn endpointInterval(speed: PortSpeed, attributes: u8, b_interval: u8) u8 {
    const kind = attributes & 3;
    if (kind == 0 or kind == 2) return 0;
    const b: u32 = if (b_interval == 0) 1 else b_interval;
    switch (speed) {
        .full, .low => {
            if (kind == 3) {
                // bInterval is in milliseconds: convert
                // to 125 us units and take log2.
                const n: u8 = @intCast(std.math.log2_int(u32, b * 8));
                return @min(@max(n, 3), 10);
            }
            return @intCast(@min(b + 2, 15)); // isochronous FS: 2^(b-1) ms
        },
        else => return @intCast(@min(b - 1, 15)), // already an exponent + 1
    }
}

pub inline fn ctxDword(base: []u8, ctx_size: usize, ctx_index: usize, dword: usize) *volatile u32 {
    return @ptrCast(@alignCast(&base[ctx_index * ctx_size + dword * 4]));
}

pub const IrqEvent = struct { slot: u8, dci: u8, code: u8 };

const DataRing = struct {
    ring: TrbRing,
    dci: u8, // 0 = unused
    mps: u16, // wMaxPacketSize of the endpoint (for the TRB TD Size field)
};

/// Queue a data buffer as one or more TRBs.
/// A TRB's buffer must not cross a 64 KB boundary, so the
/// buffer is split there; all TRBs but the last are chained
/// and only the last carries `last_flags` (IOC/ISP). The first
/// TRB has type `first_type` plus `first_flags` (e.g. DIR for
/// a control data stage); the rest are Normal TRBs. Returns
/// the physical address of the LAST TRB, which is what the
/// completion event reports. Assumes the buffer is physically
/// contiguous (true for identity mapping).
fn pushBuffer(ring: *TrbRing, buf: usize, len: usize, mps: u16, first_type: u32, first_flags: u32, last_flags: u32) u64 {
    var remaining = len;
    var va = buf;
    var first = true;
    var last_phys: u64 = 0;
    const pkt: usize = if (mps == 0) 512 else mps;
    while (remaining > 0) {
        const pa = virtToPhys(va);
        const to_boundary: usize = 0x10000 - @as(usize, @intCast(pa & 0xFFFF));
        const chunk = @min(remaining, to_boundary);
        remaining -= chunk;
        const td_size: u32 = @intCast(@min(@as(usize, 31), (remaining + pkt - 1) / pkt));
        var ctrl: u32 = (if (first) first_type else TRB_NORMAL) << 10;
        if (first) ctrl |= first_flags;
        if (remaining == 0) ctrl |= last_flags else ctrl |= TRB_CH;
        last_phys = ring.push(pa, @as(u32, @intCast(chunk)) | (td_size << 17), ctrl);
        va += chunk;
        first = false;
    }
    return last_phys;
}

// Driver

pub const XhciDriver = struct {
    bar: usize,
    caps: *volatile CapabilityRegisters,
    ops: *volatile OperationalRegisters,
    run: *volatile RuntimeRegisters,
    ports_base: [*]volatile PortRegisters,
    doorbells: [*]volatile u32,

    ctx_size: usize, // 32 or 64 bytes (HCCPARAMS1.CSZ)
    max_ports: u8,
    max_slots: u8,
    ac64: bool,

    cmd_ring: TrbRing,
    event_ring: EventRing,
    erst: ErstEntry align(64),
    dcbaa: [MaxSlots + 1]u64 align(64),
    scratch_array: [MaxScratchpads]u64 align(64),
    scratch_pages: [MaxScratchpads][4096]u8 align(4096),
    dev_ctx: [MaxSlots + 1]DeviceContextStorage,
    input_ctx: [4096]u8 align(4096),

    ep0_rings: [MaxSlots + 1]TrbRing,
    ep0_mps: [MaxSlots + 1]u16,
    slot_max_dci: [MaxSlots + 1]u8,
    data_rings: [MaxSlots + 1][EndpointRingsPerSlot]DataRing,

    // Event state, filled by drainEvents().
    cmd_done: bool,
    cmd_code: u8,
    cmd_slot: u8,
    last_completion_code: u8,

    sync_pending: bool,
    sync_done: bool,
    sync_slot: u8,
    sync_dci: u8,
    sync_code: u8,
    sync_ptr: u64,

    irq_mask: [MaxSlots + 1]u32,
    irq_code: [MaxSlots + 1][32]u8,
    // Completions not yet taken, per endpoint: an endpoint with
    // several transfers queued (a mouse)
    // may finish more than one between polls
    irq_count: [MaxSlots + 1][32]u8,

    port_changed: [256]bool,
    port_is_usb3: [256]bool,

    // The OS's wait for the interrupt (pause), if set: it returns
    // about how many microseconds passed. Null after init.
    wait_hook: ?*const fn (ctx: *anyopaque) u32,
    wait_ctx: ?*anyopaque,

    /// Prepare the driver for the controller at `pci_bar0_address`
    /// (mapped virtual address of BAR0).
    pub fn init(self: *XhciDriver, pci_bar0_address: usize) void {
        @memset(std.mem.asBytes(self), 0);
        const bar = pci_bar0_address;
        const dw0 = rd32(bar);
        const cap_length: usize = dw0 & 0xFF;
        const caps: *volatile CapabilityRegisters = @ptrFromInt(bar);

        self.bar = bar;
        self.caps = caps;
        self.ops = @ptrFromInt(bar + cap_length);
        self.run = @ptrFromInt(bar + (read32(&caps.runtime_offset) & ~@as(u32, 0x1F)));
        self.ports_base = @ptrFromInt(bar + cap_length + 0x400);
        self.doorbells = @ptrFromInt(bar + (read32(&caps.doorbell_offset) & ~@as(u32, 0x3)));

        const hcs1 = read32(&caps.hcs_params1);
        const hcc1 = read32(&caps.hcc_params1);
        self.max_slots = @intCast(@min(hcs1 & 0xFF, MaxSlots));
        self.max_ports = @intCast((hcs1 >> 24) & 0xFF);
        self.ac64 = (hcc1 & 1) != 0;
        self.ctx_size = if ((hcc1 & (1 << 2)) != 0) 64 else 32;
    }

    // CONTROLLER BRING-UP

    pub fn setupAndStart(self: *XhciDriver) !void {
        self.walkExtendedCapabilities();

        // Halt (firmware may have left it running).
        if ((read32(&self.ops.usb_sts) & STS_HCH) == 0) {
            self.ops.usb_cmd = read32(&self.ops.usb_cmd) & ~CMD_RS;
            var t: u32 = 0;
            while ((read32(&self.ops.usb_sts) & STS_HCH) == 0) : (t += 1) {
                if (t > 100_000) return error.HaltTimeout;
                delayUsFn(10);
            }
        }

        // Reset.
        self.ops.usb_cmd = CMD_HCRST;
        var t: u32 = 0;
        while ((read32(&self.ops.usb_cmd) & CMD_HCRST) != 0) : (t += 1) {
            if (t > 100_000) return error.ResetTimeout;
            delayUsFn(10);
        }
        t = 0;
        while ((read32(&self.ops.usb_sts) & STS_CNR) != 0) : (t += 1) {
            if (t > 100_000) return error.NotReadyTimeout;
            delayUsFn(10);
        }

        if ((self.ops.page_size & 1) == 0) return error.UnsupportedPageSize; // need 4 KB pages
        if (self.max_slots == 0 or self.max_ports == 0) return error.NoSlotsOrPorts;
        if (!self.ac64) {
            const end = virtToPhys(@intFromPtr(self)) + @sizeOf(XhciDriver);
            if ((end >> 32) != 0) return error.DmaMemoryAbove4G;
        }

        self.ops.config = (self.ops.config & ~@as(u32, 0xFF)) | self.max_slots;

        // Scratchpad buffers (mandatory on much real hardware).
        const hcs2 = read32(&self.caps.hcs_params2);
        const scratch_n: u32 = (((hcs2 >> 21) & 0x1F) << 5) | ((hcs2 >> 27) & 0x1F);
        if (scratch_n > MaxScratchpads) return error.TooManyScratchpads;
        var i: usize = 0;
        while (i < scratch_n) : (i += 1) {
            self.scratch_array[i] = virtToPhys(@intFromPtr(&self.scratch_pages[i]));
        }
        self.dcbaa[0] = if (scratch_n > 0) virtToPhys(@intFromPtr(&self.scratch_array)) else 0;
        memoryBarrier();
        set64(&self.ops.dcbaap_lo, &self.ops.dcbaap_hi, virtToPhys(@intFromPtr(&self.dcbaa)));

        // Command ring.
        self.cmd_ring.reset();
        set64(&self.ops.crcr_lo, &self.ops.crcr_hi, self.cmd_ring.phys() | @as(u64, self.cmd_ring.cycle));

        // Event ring (interrupter 0):
        // ERSTSZ, then ERDP, then ERSTBA (which arms the ring).
        self.event_ring.reset();
        self.erst = .{
            .segment_base_address = virtToPhys(@intFromPtr(&self.event_ring.trbs)),
            .segment_size = RingSize,
        };
        memoryBarrier();
        const intr = &self.run.interrupters;
        intr.erstsz = 1;
        set64(&intr.erdp_lo, &intr.erdp_hi, virtToPhys(@intFromPtr(&self.event_ring.trbs)));
        set64(&intr.erstba_lo, &intr.erstba_hi, virtToPhys(@intFromPtr(&self.erst)));

        // Run. We poll the event ring, so
        // interrupts (INTE / IMAN.IE) stay disabled.
        self.ops.usb_cmd = CMD_RS;
        t = 0;
        while ((read32(&self.ops.usb_sts) & STS_HCH) != 0) : (t += 1) {
            if (t > 100_000) return error.StartTimeout;
            delayUsFn(10);
        }
    }

    /// Walk xHCI extended capabilities: take ownership from the
    /// BIOS (USB Legacy Support) and learn which root ports are
    /// USB3 (Supported Protocol).
    fn walkExtendedCapabilities(self: *XhciDriver) void {
        const xecp = (read32(&self.caps.hcc_params1) >> 16) & 0xFFFF;
        if (xecp == 0) return;
        var p: usize = self.bar + @as(usize, xecp) * 4;
        var guard: u32 = 0;
        while (guard < 64) : (guard += 1) {
            const dw0 = rd32(p);
            const id = dw0 & 0xFF;
            const next = (dw0 >> 8) & 0xFF;
            if (id == 1) {
                // USB Legacy Support: BIOS owned = bit 16, OS owned = bit 24.
                if ((dw0 & (1 << 16)) != 0) {
                    wr32(p, dw0 | (1 << 24));
                    var t: u32 = 0;
                    while ((rd32(p) & (1 << 16)) != 0 and t < 100_000) : (t += 1) delayUsFn(10);
                }
                // Disable all SMI sources and clear pending SMI status.
                const ctl = rd32(p + 4);
                const disable_smi: u32 = (0x3 << 1) | (0xFF << 5) | (0x7 << 17);
                wr32(p + 4, (ctl & ~disable_smi) | 0xE000_0000);
            } else if (id == 2) {
                const major = (dw0 >> 24) & 0xFF;
                const dw2 = rd32(p + 8);
                const first = dw2 & 0xFF;
                const count = (dw2 >> 8) & 0xFF;
                if (major == 3) {
                    var k: u32 = 0;
                    while (k < count) : (k += 1) {
                        const port = first + k;
                        if (port >= 1 and port <= 255) self.port_is_usb3[port] = true;
                    }
                }
            }
            if (next == 0) break;
            p += @as(usize, next) * 4;
        }
    }

    // EVENTS

    /// Consume every pending event and record its effect. Safe to
    /// call at any time (it never calls back into drivers); waiters
    /// and the poll loop look at the recorded state.
    pub fn drainEvents(self: *XhciDriver) void {
        var any = false;
        while (self.event_ring.peek()) |ev| {
            any = true;
            self.event_ring.advance();
            const ptype = (ev.control >> 10) & 0x3F;
            switch (ptype) {
                TRB_CMD_COMPLETION => {
                    self.cmd_code = @intCast((ev.status >> 24) & 0xFF);
                    self.cmd_slot = @intCast((ev.control >> 24) & 0xFF);
                    self.last_completion_code = self.cmd_code;
                    self.cmd_done = true;
                },
                TRB_TRANSFER_EVENT => {
                    const slot: u8 = @intCast((ev.control >> 24) & 0xFF);
                    const dci: u8 = @intCast((ev.control >> 16) & 0x1F);
                    const code: u8 = @intCast((ev.status >> 24) & 0xFF);
                    self.last_completion_code = code;
                    if (self.sync_pending and !self.sync_done and slot == self.sync_slot) {
                        if (ev.parameter == self.sync_ptr) {
                            self.sync_code = code;
                            self.sync_done = true;
                            continue;
                        }
                        if (dci == self.sync_dci and code != 1 and code != 13) {
                            // Error on an earlier stage of the awaited
                            // transfer (data stage stall, etc).
                            self.sync_code = code;
                            self.sync_done = true;
                            continue;
                        }
                        if (dci == self.sync_dci) continue; // intermediate stage (short packet) of the awaited TD
                    }
                    if (slot >= 1 and slot <= MaxSlots and dci < 32) {
                        self.irq_mask[slot] |= (@as(u32, 1) << @as(u5, @intCast(dci)));
                        self.irq_code[slot][dci] = code;
                        self.irq_count[slot][dci] +|= 1;
                    }
                },
                TRB_PORT_STATUS_CHANGE => {
                    const port: u32 = @intCast((ev.parameter >> 24) & 0xFF);
                    if (port >= 1 and port <= self.max_ports) self.port_changed[port] = true;
                },
                else => {},
            }
        }
        if (any) self.updateErdp();
    }

    fn updateErdp(self: *XhciDriver) void {
        const p = virtToPhys(@intFromPtr(&self.event_ring.trbs[self.event_ring.dequeue])) | (1 << 3); // EHB
        set64(&self.run.interrupters.erdp_lo, &self.run.interrupters.erdp_hi, p);
    }

    /// Next completed interrupt/bulk transfer on a non-synchronous
    /// endpoint, if any: one per completion, in order.
    pub fn takeInterrupt(self: *XhciDriver) ?IrqEvent {
        var slot: usize = 1;
        while (slot <= self.max_slots) : (slot += 1) {
            const mask = self.irq_mask[slot];
            if (mask == 0) continue;
            const dci: u5 = @intCast(@ctz(mask));
            const count = &self.irq_count[slot][dci];
            if (count.* > 0) count.* -= 1;
            if (count.* == 0) self.irq_mask[slot] = mask & ~(@as(u32, 1) << dci);
            return .{ .slot = @intCast(slot), .dci = dci, .code = self.irq_code[slot][dci] };
        }
        return null;
    }

    /// A completed transfer of this endpoint, taken if it succeeded
    /// (the interrupt's input handling: an error is left for the
    /// poll loop to recover from)
    pub fn takeInputEvent(self: *XhciDriver, slot: u8, dci: u8) bool {
        const count = &self.irq_count[slot][dci];
        if (count.* == 0) return false;
        const code = self.irq_code[slot][dci];
        if (code != 1 and code != 13) return false; // success / short packet only
        count.* -= 1;
        if (count.* == 0) self.irq_mask[slot] &= ~(@as(u32, 1) << @as(u5, @intCast(dci)));
        return true;
    }

    /// Compatibility wrapper: drain events, then let the core
    /// manager handle hot-plug and endpoint events.
    pub fn pollEvents(self: *XhciDriver, core_manager: anytype) void {
        self.drainEvents();
        core_manager.processPending(self);
    }

    // COMMANDS

    const CommandResult = struct { code: u8, slot: u8 };

    fn sendCommand(self: *XhciDriver, ptype: u32, param: u64, status: u32, control_extra: u32) !CommandResult {
        self.drainEvents();
        self.cmd_done = false;
        _ = self.cmd_ring.push(param, status, (ptype << 10) | control_extra);
        memoryBarrier();
        self.doorbells[0] = 0;

        var t: u32 = 0;
        while (t < 500_000) { // ~5 s in 10 us steps
            self.drainEvents();
            if (self.cmd_done) {
                self.cmd_done = false;
                if (self.cmd_code != 1) return error.CommandFailed;
                return .{ .code = self.cmd_code, .slot = self.cmd_slot };
            }
            t += self.pause();
        }
        return error.CommandTimeout;
    }

    pub fn enableSlot(self: *XhciDriver) !u8 {
        const r = try self.sendCommand(TRB_ENABLE_SLOT, 0, 0, 0);
        if (r.slot == 0 or r.slot > self.max_slots) return error.InvalidSlotId;
        return r.slot;
    }

    pub fn disableSlot(self: *XhciDriver, slot_id: u8) !void {
        _ = try self.sendCommand(TRB_DISABLE_SLOT, 0, 0, @as(u32, slot_id) << 24);
        self.dcbaa[slot_id] = 0;
    }

    /// Build the output + input contexts for a freshly enabled slot
    /// and issue Address Device.
    pub fn addressDevice(self: *XhciDriver, slot_id: u8, root_port: u8, speed: PortSpeed) !void {
        return self.addressDeviceRouted(slot_id, root_port, 0, speed, 0, 0);
    }

    /// Address Device for a device anywhere in the tree: `route` is
    /// its route string (a hub port number per tier below the root
    /// port, 4 bits each, the first tier lowest). A low- or
    /// full-speed device behind a high-speed hub talks through that
    /// hub's transaction translator: `tt_slot` is the hub's slot,
    /// `tt_port` the hub port (both 0 otherwise).
    pub fn addressDeviceRouted(self: *XhciDriver, slot_id: u8, root_port: u8, route: u20, speed: PortSpeed, tt_slot: u8, tt_port: u8) !void {
        if (slot_id == 0 or slot_id > self.max_slots) return error.InvalidSlot;
        const csz = self.ctx_size;

        @memset(&self.dev_ctx[slot_id].bytes, 0);
        self.dcbaa[slot_id] = virtToPhys(@intFromPtr(&self.dev_ctx[slot_id]));
        self.ep0_rings[slot_id].reset();
        for (&self.data_rings[slot_id]) |*d| d.dci = 0;
        self.slot_max_dci[slot_id] = 1;
        self.ep0_mps[slot_id] = speed.defaultEp0MaxPacket();

        const ic: []u8 = &self.input_ctx;
        @memset(ic, 0);
        ctxDword(ic, csz, 0, 1).* = 0b11; // add flags: slot context + EP0
        // Slot context (input index 1)
        ctxDword(ic, csz, 1, 0).* = @as(u32, route) | (speed.slotSpeed() << 20) | (1 << 27); // context entries = 1
        ctxDword(ic, csz, 1, 1).* = @as(u32, root_port) << 16;
        ctxDword(ic, csz, 1, 2).* = @as(u32, tt_slot) | (@as(u32, tt_port) << 8);
        // EP0 context (input index 2)
        ctxDword(ic, csz, 2, 1).* = (3 << 1) | (4 << 3) | (@as(u32, self.ep0_mps[slot_id]) << 16); // CErr=3, control EP
        const deq = self.ep0_rings[slot_id].phys() | 1; // DCS = 1
        ctxDword(ic, csz, 2, 2).* = @truncate(deq);
        ctxDword(ic, csz, 2, 3).* = @truncate(deq >> 32);
        ctxDword(ic, csz, 2, 4).* = 8; // average TRB length
        memoryBarrier();

        _ = try self.sendCommand(TRB_ADDRESS_DEVICE, virtToPhys(@intFromPtr(&self.input_ctx)), 0, @as(u32, slot_id) << 24);
    }

    /// After reading bMaxPacketSize0 from the device, fix up EP0
    /// (needed for full-speed devices).
    pub fn updateEp0MaxPacket(self: *XhciDriver, slot_id: u8, max_packet: u16) !void {
        const csz = self.ctx_size;
        const ic: []u8 = &self.input_ctx;
        const dc: []u8 = &self.dev_ctx[slot_id].bytes;
        @memset(ic, 0);
        ctxDword(ic, csz, 0, 1).* = 1 << 1; // add flags: EP0
        var d: usize = 0;
        while (d < 8) : (d += 1) ctxDword(ic, csz, 2, d).* = ctxDword(dc, csz, 1, d).*; // copy output EP0 ctx
        const w1 = ctxDword(ic, csz, 2, 1);
        w1.* = (w1.* & 0x0000_FFFF) | (@as(u32, max_packet) << 16);
        memoryBarrier();
        _ = try self.sendCommand(TRB_EVALUATE_CONTEXT, virtToPhys(@intFromPtr(&self.input_ctx)), 0, @as(u32, slot_id) << 24);
        self.ep0_mps[slot_id] = max_packet;
    }

    fn getDataEntry(self: *XhciDriver, slot_id: u8, dci: u8) ?*DataRing {
        for (&self.data_rings[slot_id]) |*d| {
            if (d.dci == dci) return d;
        }
        for (&self.data_rings[slot_id]) |*d| {
            if (d.dci == 0) {
                d.dci = dci;
                d.mps = 0;
                d.ring.reset();
                return d;
            }
        }
        return null;
    }

    fn getDataRing(self: *XhciDriver, slot_id: u8, dci: u8) ?*TrbRing {
        if (self.getDataEntry(slot_id, dci)) |d| return &d.ring;
        return null;
    }

    /// Add endpoints to a configured device (Configure Endpoint).
    /// One command covers all endpoints.
    pub fn configureEndpoints(self: *XhciDriver, slot_id: u8, eps: []const EndpointSetup) !void {
        if (slot_id == 0 or slot_id > self.max_slots or eps.len == 0) return error.InvalidSlot;
        const csz = self.ctx_size;
        const ic: []u8 = &self.input_ctx;
        const dc: []u8 = &self.dev_ctx[slot_id].bytes;
        @memset(ic, 0);

        var add_flags: u32 = 1; // A0: slot context
        var max_dci: u8 = self.slot_max_dci[slot_id];
        for (eps) |ep| max_dci = @max(max_dci, ep.dci);

        // Slot context: copy the current one, raising Context Entries.
        var d: usize = 0;
        while (d < 8) : (d += 1) ctxDword(ic, csz, 1, d).* = ctxDword(dc, csz, 0, d).*;
        const s0 = ctxDword(ic, csz, 1, 0);
        s0.* = (s0.* & ~(@as(u32, 0x1F) << 27)) | (@as(u32, max_dci) << 27);

        for (eps) |ep| {
            if (ep.dci < 2 or ep.dci > 31) return error.InvalidEndpoint;
            const entry = self.getDataEntry(slot_id, ep.dci) orelse return error.NoFreeRing;
            entry.mps = ep.max_packet_size;
            entry.ring.reset(); // the context below starts the ring at its beginning with DCS = 1
            const ring = &entry.ring;
            add_flags |= @as(u32, 1) << @as(u5, @intCast(ep.dci));
            const idx: usize = @as(usize, ep.dci) + 1; // input context index = DCI + 1
            ctxDword(ic, csz, idx, 0).* = @as(u32, ep.interval) << 16;
            ctxDword(ic, csz, idx, 1).* = (3 << 1) | (@as(u32, ep.ep_type) << 3) | (@as(u32, ep.max_packet_size) << 16);
            const deq = ring.phys() | 1;
            ctxDword(ic, csz, idx, 2).* = @truncate(deq);
            ctxDword(ic, csz, idx, 3).* = @truncate(deq >> 32);
            ctxDword(ic, csz, idx, 4).* = @as(u32, ep.max_packet_size) | (@as(u32, ep.max_packet_size) << 16); // avg TRB len, max ESIT payload
        }
        ctxDword(ic, csz, 0, 1).* = add_flags;
        memoryBarrier();

        _ = try self.sendCommand(TRB_CONFIGURE_ENDPOINT, virtToPhys(@intFromPtr(&self.input_ctx)), 0, @as(u32, slot_id) << 24);
        self.slot_max_dci[slot_id] = max_dci;
    }

    /// Mark a configured device as a hub with `ports` downstream
    /// ports (Configure Endpoint with only the slot context).
    /// `ttt`: its TT think time (wHubCharacteristics bits 5-6).
    pub fn configureHub(self: *XhciDriver, slot_id: u8, ports: u8, ttt: u2) !void {
        if (slot_id == 0 or slot_id > self.max_slots) return error.InvalidSlot;
        const csz = self.ctx_size;
        const ic: []u8 = &self.input_ctx;
        const dc: []u8 = &self.dev_ctx[slot_id].bytes;
        @memset(ic, 0);
        ctxDword(ic, csz, 0, 1).* = 1; // add flags: slot context only
        var d: usize = 0;
        while (d < 8) : (d += 1) ctxDword(ic, csz, 1, d).* = ctxDword(dc, csz, 0, d).*;
        const s0 = ctxDword(ic, csz, 1, 0);
        s0.* |= 1 << 26; // Hub
        const s1 = ctxDword(ic, csz, 1, 1);
        s1.* = (s1.* & 0x00FF_FFFF) | (@as(u32, ports) << 24);
        const s2 = ctxDword(ic, csz, 1, 2);
        s2.* = (s2.* & ~@as(u32, 3 << 16)) | (@as(u32, ttt) << 16);
        memoryBarrier();
        _ = try self.sendCommand(TRB_CONFIGURE_ENDPOINT, virtToPhys(@intFromPtr(&self.input_ctx)), 0, @as(u32, slot_id) << 24);
    }

    /// Un-halt an endpoint after a stall/error
    /// and restart its ring from the beginning.
    pub fn recoverEndpoint(self: *XhciDriver, slot_id: u8, dci: u8) !void {
        const ctrl = (@as(u32, slot_id) << 24) | (@as(u32, dci) << 16);
        _ = self.sendCommand(TRB_RESET_ENDPOINT, 0, 0, ctrl) catch {}; // fails harmlessly if not halted
        const ring: *TrbRing = if (dci == 1) &self.ep0_rings[slot_id] else (self.getDataRing(slot_id, dci) orelse return error.NoRing);
        ring.reset();
        _ = try self.sendCommand(TRB_SET_TR_DEQUEUE, ring.phys() | 1, 0, ctrl);
    }

    // PORTS

    pub fn portStatus(self: *XhciDriver, port_id: u8) u32 {
        return read32(&self.ports_base[port_id - 1].portsc);
    }

    /// Clear all pending change bits on a
    /// port and return which ones were set.
    pub fn ackPortChanges(self: *XhciDriver, port_id: u8) u32 {
        const reg = &self.ports_base[port_id - 1];
        const sc = read32(&reg.portsc);
        const changes = sc & PORTSC_CHANGE_BITS;
        if (changes != 0) reg.portsc = portNeutral(sc) | changes;
        return changes;
    }

    /// Reset a connected port (or wait for USB3 link training) and
    /// return the negotiated speed.
    pub fn portReset(self: *XhciDriver, port_id: u8) !PortSpeed {
        if (port_id == 0 or port_id > self.max_ports) return error.InvalidPort;
        const reg = &self.ports_base[port_id - 1];
        var sc = read32(&reg.portsc);
        if ((sc & PORTSC_CCS) == 0) return error.DeviceNotConnected;

        if (self.port_is_usb3[port_id]) {
            // SuperSpeed ports train on their own; only
            // force a warm reset if it never comes up.
            var t: u32 = 0;
            while ((read32(&reg.portsc) & PORTSC_PED) == 0 and t < 30_000) : (t += 1) delayUsFn(10); // 300 ms
            if ((read32(&reg.portsc) & PORTSC_PED) == 0) {
                reg.portsc = portNeutral(read32(&reg.portsc)) | PORTSC_WPR;
                t = 0;
                while ((read32(&reg.portsc) & PORTSC_PED) == 0 and t < 100_000) : (t += 1) delayUsFn(10);
            }
        } else {
            reg.portsc = portNeutral(sc) | PORTSC_PR;
            var t: u32 = 0;
            while ((read32(&reg.portsc) & PORTSC_PRC) == 0) : (t += 1) { // PR clears itself; PRC marks completion
                if (t > 100_000) return error.PortResetTimeout;
                delayUsFn(10);
            }
        }

        _ = self.ackPortChanges(port_id);
        delayMs(10); // USB reset recovery time
        sc = read32(&reg.portsc);
        if ((sc & PORTSC_CCS) == 0) return error.DeviceNotConnected;
        if ((sc & PORTSC_PED) == 0) return error.PortNotEnabled;

        return switch ((sc >> 10) & 0xF) {
            1 => .full,
            2 => .low,
            3 => .high,
            4, 5, 6, 7 => .super,
            else => error.UnknownPortSpeed,
        };
    }

    // TRANSFERS

    fn beginSync(self: *XhciDriver, slot_id: u8, dci: u8, ptr: u64) void {
        self.drainEvents();
        self.sync_pending = true;
        self.sync_done = false;
        self.sync_slot = slot_id;
        self.sync_dci = dci;
        self.sync_ptr = ptr;
    }

    fn waitSync(self: *XhciDriver) !void {
        var t: u32 = 0;
        while (t < 400_000) : (t += self.pause()) { // ~4 s in 10 us steps
            self.drainEvents();
            if (self.sync_done) {
                self.sync_pending = false;
                const code = self.sync_code;
                if (code == 1 or code == 13) return;
                if (code == 6 or code == 4 or code == 3) { // stall / transaction error / babble: endpoint halted
                    self.recoverEndpoint(self.sync_slot, self.sync_dci) catch {};
                    return if (code == 6) error.TransferStall else error.TransferFailed;
                }
                return error.TransferFailed;
            }
        }
        self.sync_pending = false;
        return error.DeviceTimeout;
    }

    /// Between looks at the event ring: 10 us, or the OS's wait for
    /// the interrupt (wait_hook); in 10 us steps
    fn pause(self: *XhciDriver) u32 {
        if (self.wait_hook) |hook| return @max(1, hook(self.wait_ctx.?) / 10);
        delayUsFn(10);
        return 1;
    }

    /// Interrupter 0 on (events raise it, at most every 10 us), and
    /// the controller's interrupts.
    /// The OS has set up its message and handler.
    pub fn enableInterrupts(self: *XhciDriver) void {
        const intr = &self.run.interrupters;
        intr.imod = 40; // x 250 ns
        intr.iman = 0b11; // IE, and IP cleared (write 1)
        self.ops.usb_cmd = read32(&self.ops.usb_cmd) | CMD_INTE;
    }

    /// From the OS's interrupt handler: acknowledged
    /// (the events stay for drainEvents)
    pub fn acknowledgeInterrupt(self: *XhciDriver) void {
        self.ops.usb_sts = STS_EINT;
        const intr = &self.run.interrupters;
        intr.iman = read32(&intr.iman) | 1;
    }

    pub fn executeControlTransfer(
        self: *XhciDriver,
        slot_id: u8,
        bmRequestType: u8,
        bRequest: u8,
        wValue: u16,
        wIndex: u16,
        data_ptr: ?*anyopaque,
        wLength: u16,
    ) !void {
        if (slot_id == 0 or slot_id > self.max_slots) return error.InvalidSlot;
        const ring = &self.ep0_rings[slot_id];
        const has_data = wLength > 0 and data_ptr != null;
        const is_in = (bmRequestType & 0x80) != 0;

        const setup: u64 = @as(u64, bmRequestType) | (@as(u64, bRequest) << 8) | (@as(u64, wValue) << 16) |
            (@as(u64, wIndex) << 32) | (@as(u64, wLength) << 48);
        const trt: u32 = if (!has_data) 0 else if (is_in) 3 else 2;
        _ = ring.push(setup, 8, (TRB_SETUP << 10) | TRB_IDT | (trt << 16));

        if (has_data) {
            const dir: u32 = if (is_in) TRB_DIR_IN else 0;
            const isp: u32 = if (is_in) TRB_ISP else 0;
            _ = pushBuffer(ring, @intFromPtr(data_ptr.?), wLength, self.ep0_mps[slot_id], TRB_DATA, dir, isp);
        }

        const status_dir: u32 = if (has_data and is_in) 0 else TRB_DIR_IN;
        const status_phys = ring.push(0, 0, (TRB_STATUS << 10) | TRB_IOC | status_dir);

        self.beginSync(slot_id, 1, status_phys);
        memoryBarrier();
        self.doorbells[slot_id] = 1;
        try self.waitSync();
    }

    /// Synchronous bulk transfer, split into as many TRBs as needed
    /// so none crosses a 64 KB boundary.
    /// `ep_id` is the DCI (ep_number * 2 + IN).
    pub fn submitBulkTransfer(self: *XhciDriver, slot_id: u8, ep_id: u8, buffer_ptr: ?*const anyopaque, length: usize) !void {
        if (length == 0 or buffer_ptr == null) return;
        if (slot_id == 0 or slot_id > self.max_slots) return error.InvalidSlot;
        if (length > 60 * 0x10000) return error.TransferTooLarge; // must fit in the 63-TRB ring
        const entry = self.getDataEntry(slot_id, ep_id) orelse return error.NoRing;
        const last = pushBuffer(&entry.ring, @intFromPtr(buffer_ptr.?), length, entry.mps, TRB_NORMAL, 0, TRB_IOC | TRB_ISP);
        self.beginSync(slot_id, ep_id, last);
        memoryBarrier();
        self.doorbells[slot_id] = ep_id;
        try self.waitSync();
    }

    /// Queue an asynchronous transfer (HID reports).
    /// Completion shows up via takeInterrupt(). `ep_id` is the DCI.
    /// `phys_buffer` must already be a physical address.
    pub fn submitInterruptTransfer(self: *XhciDriver, slot_id: u8, ep_id: u8, phys_buffer: u64, length: u16) !void {
        if (slot_id == 0 or slot_id > self.max_slots) return error.InvalidSlot;
        const ring = self.getDataRing(slot_id, ep_id) orelse return error.NoRing;
        _ = ring.push(phys_buffer, length, (TRB_NORMAL << 10) | TRB_IOC | TRB_ISP);
        memoryBarrier();
        self.doorbells[slot_id] = ep_id;
    }
};
