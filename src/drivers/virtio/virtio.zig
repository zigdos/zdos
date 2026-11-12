//! virtio 1.x over PCI ("modern") and split virtqueues, after
//! Minix 3's libvirtio. Memory is identity-mapped (DMA
//! addresses are the buffers' own).

const std = @import("std");
const builtin = @import("builtin");
const pci = @import("../pcie/pci.zig");

pub const vendor_id = 0x1AF4;

// Device status
pub const status_ack = 1;
pub const status_driver = 2;
pub const status_driver_ok = 4;
pub const status_features_ok = 8;
pub const status_failed = 128;

// Common features (bits of the 64)
pub const f_version_1: u64 = 1 << 32;
pub const f_access_platform: u64 = 1 << 33; // fine: no IOMMU, addresses are physical

pub const no_vector = 0xFFFF;

// The common configuration's registers
const c_dfselect = 0x00;
const c_dfeature = 0x04;
const c_gfselect = 0x08;
const c_gfeature = 0x0C;
const c_msix_config = 0x10;
const c_status = 0x14;
const c_generation = 0x15;
const c_qselect = 0x16;
const c_qsize = 0x18;
const c_qvector = 0x1A;
const c_qenable = 0x1C;
const c_qnotify_off = 0x1E;
const c_qdesc = 0x20;
const c_qavail = 0x28;
const c_qused = 0x30;

const mmio = @import("../../arch/mmio.zig");
pub const read8 = mmio.read8;
pub const read16 = mmio.read16;
pub const read32 = mmio.read32;
pub const write8 = mmio.write8;
pub const write16 = mmio.write16;
pub const write32 = mmio.write32;

pub inline fn barrier() void {
    if (comptime builtin.cpu.arch.isX86()) {
        asm volatile ("mfence" ::: "memory");
    } else if (comptime builtin.cpu.arch.isAARCH64()) {
        asm volatile ("dmb sy" ::: "memory");
    } else {
        asm volatile ("" ::: "memory");
    }
}

// virtio PCI IDs: transitional
// (0x1000 + n) or modern (0x1040 + id)
pub fn isNet(d: pci.PciDeviceLocation) bool {
    return d.vendor_id == vendor_id and (d.device_id == 0x1000 or d.device_id == 0x1041);
}
pub fn isBlk(d: pci.PciDeviceLocation) bool {
    return d.vendor_id == vendor_id and (d.device_id == 0x1001 or d.device_id == 0x1042);
}

// Where the registers are: vendor capabilities
// (0x09) name a BAR, offset, length
pub const Regions = struct {
    common: usize = 0,
    notify: usize = 0,
    notify_mul: u32 = 0,
    isr: usize = 0,
    device: usize = 0,
    // Per BAR: the span the capabilities use (for mapping)
    bar_start: [6]u64 = @splat(0),
    bar_end: [6]u64 = @splat(0),
};

fn cfg32(d: pci.PciDeviceLocation, off: u16) u32 {
    return pci.pciReadConfigDwordInSegment(d.segment, d.bus, d.slot, d.func, off);
}

// Null without the modern interface (a legacy-only device)
pub fn findRegions(d: pci.PciDeviceLocation) ?Regions {
    var r: Regions = .{};
    if ((cfg32(d, 0x04) >> 16) & 0x10 == 0) return null; // no capability list
    var ptr: u16 = @as(u8, @truncate(cfg32(d, 0x34))) & 0xFC;
    var n: usize = 0;
    while (ptr >= 0x40 and n < 48) : (n += 1) {
        const head = cfg32(d, ptr);
        if (@as(u8, @truncate(head)) == 0x09) {
            const kind: u8 = @truncate(head >> 24);
            const bar: u8 = @truncate(cfg32(d, ptr + 4));
            const off = cfg32(d, ptr + 8);
            const len = cfg32(d, ptr + 12);
            if (bar < 6 and kind >= 1 and kind <= 4 and len != 0) {
                const base = d.readBar(@intCast(bar));
                // An I/O-port BAR (low bit set in
                // the raw register) is of no use here
                const raw = cfg32(d, 0x10 + @as(u16, bar) * 4);
                if (base != 0 and raw & 1 == 0) {
                    const at: usize = @intCast(base + off);
                    const slot = switch (kind) {
                        1 => &r.common,
                        2 => &r.notify,
                        3 => &r.isr,
                        else => &r.device,
                    };
                    if (slot.* == 0) {
                        slot.* = at;
                        if (kind == 2) r.notify_mul = cfg32(d, ptr + 16);
                        const s = base + off;
                        const e = base + off + len;
                        if (r.bar_end[bar] == 0 or s < r.bar_start[bar]) r.bar_start[bar] = s;
                        if (e > r.bar_end[bar]) r.bar_end[bar] = e;
                    }
                }
            }
        }
        ptr = @as(u8, @truncate(head >> 8)) & 0xFC;
    }
    if (r.common == 0 or r.notify == 0 or r.device == 0) return null;
    return r;
}

pub const Error = error{ ResetFailed, NoVersion1, FeaturesRejected, NoQueue, QueueTooSmall };

pub const Device = struct {
    regs: Regions,
    features: u64 = 0, // negotiated

    fn common(self: *const Device, off: usize) usize {
        return self.regs.common + off;
    }

    pub fn status(self: *const Device) u8 {
        return read8(self.common(c_status));
    }

    pub fn setStatus(self: *const Device, s: u8) void {
        write8(self.common(c_status), s);
    }

    // Reset, then acknowledged; features: those the driver can use
    // (besides VERSION_1, ACCESS_PLATFORM),
    // agreed with the device's
    pub fn begin(self: *Device, wanted: u64, delay_us: *const fn (u32) void) Error!void {
        self.setStatus(0);
        var waited: u32 = 0;
        while (self.status() != 0) : (waited += 1) {
            if (waited == 1000) return error.ResetFailed;
            delay_us(100);
        }
        self.setStatus(status_ack);
        self.setStatus(status_ack | status_driver);
        write32(self.common(c_dfselect), 0);
        var offered: u64 = read32(self.common(c_dfeature));
        write32(self.common(c_dfselect), 1);
        offered |= @as(u64, read32(self.common(c_dfeature))) << 32;
        if (offered & f_version_1 == 0) {
            self.setStatus(status_failed);
            return error.NoVersion1;
        }
        self.features = offered & (wanted | f_version_1 | f_access_platform);
        write32(self.common(c_gfselect), 0);
        write32(self.common(c_gfeature), @truncate(self.features));
        write32(self.common(c_gfselect), 1);
        write32(self.common(c_gfeature), @truncate(self.features >> 32));
        self.setStatus(status_ack | status_driver | status_features_ok);
        if (self.status() & status_features_ok == 0) {
            self.setStatus(status_failed);
            return error.FeaturesRejected;
        }
        write16(self.common(c_msix_config), no_vector); // config changes are polled
    }

    pub fn has(self: *const Device, f: u64) bool {
        return self.features & f != 0;
    }

    pub fn ready(self: *const Device) void {
        self.setStatus(status_ack | status_driver | status_features_ok | status_driver_ok);
    }

    pub fn fail(self: *const Device) void {
        self.setStatus(status_failed);
    }

    // Device-specific configuration, read
    // until the generation stays the same
    pub fn config(self: *const Device, comptime T: type, off: usize) T {
        while (true) {
            const gen = read8(self.common(c_generation));
            const v: T = switch (T) {
                u8 => read8(self.regs.device + off),
                u16 => read16(self.regs.device + off),
                u32 => read32(self.regs.device + off),
                u64 => @as(u64, read32(self.regs.device + off)) | (@as(u64, read32(self.regs.device + off + 4)) << 32),
                else => @compileError("config width"),
            };
            if (read8(self.common(c_generation)) == gen) return v;
        }
    }

    // Queue `index` in `mem` (Queue.pages pages), at most `max`
    // entries (a power of two); its interrupt on MSI-X entry
    // `vector` (or no_vector).
    // False in q.irq: the device took no vector.
    pub fn setupQueue(self: *const Device, q: *Queue, index: u16, mem: [*]align(4096) u8, max: u16, vector: u16) Error!void {
        write16(self.common(c_qselect), index);
        const offered = read16(self.common(c_qsize));
        if (offered == 0) return error.NoQueue;
        var size: u16 = @min(offered, max);
        // Split queues are a power of two
        size = @as(u16, 1) << @intCast(std.math.log2_int(u16, size));
        if (size < 2) return error.QueueTooSmall;
        write16(self.common(c_qsize), size);
        @memset(mem[0 .. Queue.pages * 4096], 0);
        q.* = .{
            .size = size,
            .index = index,
            .desc = @ptrCast(@alignCast(mem)),
            .avail = @intFromPtr(mem) + 4096,
            .used = @intFromPtr(mem) + 4096 + 1024,
            .notify = self.regs.notify + @as(usize, read16(self.common(c_qnotify_off))) * self.regs.notify_mul,
        };
        write16(self.common(c_qvector), vector);
        q.irq = vector != no_vector and read16(self.common(c_qvector)) == vector;
        if (!q.irq) {
            write16(self.common(c_qvector), no_vector);
            q.noInterrupts();
        }
        write64(self.common(c_qdesc), @intFromPtr(q.desc));
        write64(self.common(c_qavail), q.avail);
        write64(self.common(c_qused), q.used);
        write16(self.common(c_qenable), 1);
    }

    fn write64(addr: usize, v: u64) void {
        write32(addr, @truncate(v));
        write32(addr + 4, @truncate(v >> 32));
    }
};

pub const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};
pub const desc_next = 1;
pub const desc_write = 2; // the device writes the buffer

// A split virtqueue in two pages: the descriptors (up to 256),
// then the driver's ("available") ring and at 1 KiB into that
// page the device's ("used") ring
pub const Queue = struct {
    pub const pages = 2;
    pub const max_size = 256;

    size: u16,
    index: u16,
    desc: [*]volatile Desc,
    avail: usize,
    used: usize,
    notify: usize,
    irq: bool = false,
    avail_idx: u16 = 0, // what the driver has offered
    last_used: u16 = 0, // what it has taken back

    fn noInterrupts(self: *Queue) void {
        write16(self.avail, 1); // VRING_AVAIL_F_NO_INTERRUPT
    }

    // The chain starting at descriptor head to the device
    pub fn offer(self: *Queue, head: u16) void {
        write16(self.avail + 4 + @as(usize, self.avail_idx % self.size) * 2, head);
        self.avail_idx +%= 1;
        barrier(); // the descriptors and the entry before the index
        write16(self.avail + 2, self.avail_idx);
    }

    // After offering: the device told unless it said it needn't be
    pub fn kick(self: *const Queue) void {
        barrier(); // the index before reading the device's flags
        if (read16(self.used) & 1 == 0) write16(self.notify, self.index); // VRING_USED_F_NO_NOTIFY
    }

    pub const Used = struct { id: u16, len: u32 };

    // The next chain the device is done with, if any
    pub fn take(self: *Queue) ?Used {
        if (read16(self.used + 2) == self.last_used) return null;
        barrier(); // the entry after the index
        const e = self.used + 4 + @as(usize, self.last_used % self.size) * 8;
        self.last_used +%= 1;
        return .{ .id = @truncate(read32(e) % self.size), .len = read32(e + 4) };
    }

    pub fn pending(self: *const Queue) bool {
        return read16(self.used + 2) != self.last_used;
    }
};
