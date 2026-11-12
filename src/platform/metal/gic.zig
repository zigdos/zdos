// The GIC: lets one PPI (the timer) through to this core for
// `wfi` and task switching, and gives PCIe devices MSIs (allocMsi).
// Where it is and its version come from ACPI's MADT:
//   0x0B  CPU interface: GICv2's registers at byte 32, GICv3's
//         redistributor at 60 (if no 0x0E entry lists them)
//   0x0C  distributor: registers at byte 8, version at 20
//   0x0D  GICv2m MSI frame: registers at 8, flags at 16 (bit 0:
//         the SPIs at 20 (count) and 22 (first) count)
//   0x0E  GICv3 redistributors: base at byte 4, length at 12
//   0x0F  GICv3 ITS: registers at byte 8
const std = @import("std");
const acpi = @import("acpi.zig");
const mmio = @import("../../arch/mmio.zig");
const memory = @import("memory.zig");

const Gic = struct {
    version: u8 = 0,
    dist: usize = 0,
    cpu: usize = 0, // GICv2 CPU interface
    redist: usize = 0, // GICv3 redistributors: start and length
    redist_len: usize = 0,
};

// What enablePpi found, for taking the
// interrupts (acknowledge, end) and for MSIs
var version: u8 = 0;
var cpu_interface: usize = 0; // GICv2
var distributor: usize = 0;
var own_redist: usize = 0; // GICv3: core 0's redistributor

// Lets interrupt `id` (16-31: a PPI) through to this core;
// false if the GIC is unknown or not a v2 / v3 / v4
pub fn enablePpi(id: u32) bool {
    const g = find() orelse return false;
    version = g.version;
    cpu_interface = g.cpu;
    distributor = g.dist;
    return switch (g.version) {
        2 => enableV2(g, id),
        3, 4 => enableV3(g, id),
        else => false,
    };
}

pub const spurious = 1023;

// The interrupt being taken (1023: none), which becomes active:
// as read (GICv2's carries an SGI's sender,
// which its end must give back; idOf)
pub fn acknowledge() u32 {
    return switch (version) {
        2 => mmio.read32(cpu_interface + 0x0C), // GICC_IAR
        3, 4 => @truncate(asm volatile ("mrs %[r], S3_0_C12_C12_0" // ICC_IAR1_EL1
            : [r] "=r" (-> u64),
        ) & 0xFF_FFFF),
        else => spurious,
    };
}

pub fn idOf(acknowledged: u32) u32 {
    return if (version == 2) acknowledged & 0x3FF else acknowledged;
}

// Done with it: what acknowledge gave
pub fn endOfInterrupt(id: u32) void {
    switch (version) {
        2 => mmio.write32(cpu_interface + 0x10, id), // GICC_EOIR
        3, 4 => asm volatile ("msr S3_0_C12_C12_1, %[v]; isb" // ICC_EOIR1_EL1
            :
            : [v] "r" (@as(u64, id)),
        ),
        else => {},
    }
}

// KICKS BETWEEN CORES (SGI 1: AN IDLE CORE HAS WORK)

pub const kick_sgi = 1;
var kick_to: [64]u64 = @splat(0); // per core index: GICv2 target bits, GICv3 MPIDR
var kick_ok: [64]bool = @splat(false);

// This core (index i, interrupts not yet
// on) takes kicks; how others reach it
pub fn enableKick(i: usize) void {
    if (i >= kick_to.len) return;
    const g = find() orelse return;
    switch (g.version) {
        2 => {
            if (!enableV2(g, kick_sgi)) return;
            kick_to[i] = mmio.read32(g.dist + 0x800) & 0xFF; // GICD_ITARGETSR0: this core's own bit
        },
        3, 4 => {
            if (!enableV3(g, kick_sgi)) return;
            kick_to[i] = asm volatile ("mrs %[r], mpidr_el1"
                : [r] "=r" (-> u64),
            );
        },
        else => return,
    }
    kick_ok[i] = kick_to[i] != 0 or g.version != 2;
}

// Whether core i takes kicks (else it looks every millisecond)
pub fn kicks(i: usize) bool {
    return i < kick_ok.len and kick_ok[i];
}

pub fn sendKick(i: usize) void {
    if (i >= kick_to.len or !kick_ok[i]) return;
    const t = kick_to[i];
    switch (version) {
        2 => mmio.write32(distributor + 0xF00, @as(u32, @truncate(t)) << 16 | kick_sgi), // GICD_SGIR
        3, 4 => {
            // ICC_SGI1R_EL1: the INTID, Aff3/2/1, Aff0 as a range and a bit in it
            const aff0 = t & 0xFF;
            const v = @as(u64, kick_sgi) << 24 | ((t >> 32) & 0xFF) << 48 | ((t >> 16) & 0xFF) << 32 |
                ((t >> 8) & 0xFF) << 16 | (aff0 >> 4) << 44 | @as(u64, 1) << @intCast(aff0 & 15);
            asm volatile ("dsb ishst; msr S3_0_C12_C11_5, %[v]; isb"
                :
                : [v] "r" (v),
                : "memory"
            );
        },
        else => {},
    }
}

fn find() ?Gic {
    const madt = acpi.find("APIC") orelse return null;
    var g: Gic = .{};
    var off: usize = 44;
    while (off + 2 <= madt.len) {
        const len = madt[off + 1];
        if (len < 2 or off + len > madt.len) break;
        const e = madt[off .. off + len];
        switch (e[0]) {
            0x0B => if (len >= 76 and g.cpu == 0) {
                g.cpu = @intCast(readU64(e, 32));
                if (g.redist == 0) g.redist = @intCast(readU64(e, 60));
            },
            0x0C => if (len >= 24) {
                g.dist = @intCast(readU64(e, 8));
                g.version = e[20];
            },
            0x0E => if (len >= 16) {
                g.redist = @intCast(readU64(e, 4));
                g.redist_len = std.mem.readInt(u32, e[12..16], .little);
            },
            else => {},
        }
        off += len;
    }
    if (g.dist == 0) return null;
    // Version 0: not stated; a redistributor means v3
    if (g.version == 0) g.version = if (g.redist != 0) 3 else 2;
    return g;
}

fn readU64(b: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, b[off..][0..8], .little);
}

// Priority 0xA0: above the mask (PMR 0xF0) set below
fn setPriority(regs: usize, id: u32) void {
    const at = regs + 0x400 + (id & ~@as(u32, 3));
    const shift: u5 = @intCast((id % 4) * 8);
    mmio.write32(at, (mmio.read32(at) & ~(@as(u32, 0xFF) << shift)) | (@as(u32, 0xA0) << shift));
}

// GICv2: the distributor's per-core copies of the PPI
// registers, the memory-mapped CPU interface
fn enableV2(g: Gic, id: u32) bool {
    if (g.cpu == 0) return false;
    setPriority(g.dist, id);
    mmio.write32(g.dist + 0x100, @as(u32, 1) << @intCast(id)); // GICD_ISENABLER0
    mmio.write32(g.dist, mmio.read32(g.dist) | 3); // GICD_CTLR: groups 0 and 1 on
    mmio.write32(g.cpu + 0x4, 0xF0); // GICC_PMR
    mmio.write32(g.cpu, mmio.read32(g.cpu) | 3); // GICC_CTLR: groups 0 and 1 on
    return true;
}

// GICv3: this core's redistributor (its SGI/PPI frame 64 KB in)
// and the CPU interface's system registers
fn enableV3(g: Gic, id: u32) bool {
    const rd = ownRedistributor(g) orelse return false;
    if (own_redist == 0) own_redist = rd; // core 0's: it comes first
    // Awake: ProcessorSleep (bit 1) off, then ChildrenAsleep (bit 2) clears
    mmio.write32(rd + 0x14, mmio.read32(rd + 0x14) & ~@as(u32, 2));
    var n: u32 = 0;
    while (mmio.read32(rd + 0x14) & 4 != 0) : (n += 1) {
        if (n > 1_000_000) return false;
    }
    const sgi = rd + 0x10000;
    const bit = @as(u32, 1) << @intCast(id);
    mmio.write32(sgi + 0x80, mmio.read32(sgi + 0x80) | bit); // GICR_IGROUPR0: group 1
    setPriority(sgi, id);
    mmio.write32(sgi + 0x100, bit); // GICR_ISENABLER0
    mmio.write32(g.dist, mmio.read32(g.dist) | 2); // GICD_CTLR: group 1 on
    // ICC_SRE_EL1 (SYSTEM REGISTERS ON), ICC_PMR_EL1, ICC_IGRPEN1_EL1
    const sre = asm volatile ("mrs %[r], S3_0_C12_C12_5"
        : [r] "=r" (-> u64),
    );
    if (sre & 1 == 0) return false;
    asm volatile (
        \\msr S3_0_C4_C6_0, %[pmr]
        \\msr S3_0_C12_C12_7, %[on]
        \\isb
        :
        : [pmr] "r" (@as(u64, 0xF0)),
          [on] "r" (@as(u64, 1)),
        : "memory"
    );
    return true;
}

// The redistributor whose GICR_TYPER (byte 8) affinity
// (bits 32-63) is this core's (MPIDR_EL1). Each takes 2
// frames of 64 KB, 4 with virtual LPIs (TYPER bit 1); bit 4
// marks the last one.
fn ownRedistributor(g: Gic) ?usize {
    const mpidr = asm volatile ("mrs %[r], mpidr_el1"
        : [r] "=r" (-> u64),
    );
    return redistributorOf(g, mpidr);
}

fn redistributorOf(g: Gic, mpidr: u64) ?usize {
    if (g.redist == 0) return null;
    const affinity: u32 = @truncate((mpidr & 0xFF_FFFF) | ((mpidr >> 8) & 0xFF00_0000));
    var rd = g.redist;
    const end = if (g.redist_len != 0) g.redist + g.redist_len else std.math.maxInt(usize);
    while (rd < end) {
        const typer = @as(u64, mmio.read32(rd + 8)) | (@as(u64, mmio.read32(rd + 12)) << 32);
        if (@as(u32, @truncate(typer >> 32)) == affinity) return rd;
        if (typer & (1 << 4) != 0) return null;
        rd += if (typer & 2 != 0) 0x40000 else 0x20000;
    }
    return null;
}

//
// GICv2m: the frame's SPIs; a device raises one by writing its
// number to MSI_SETSPI_NS (frame + 0x40). MSI_TYPER (0x08):
// first SPI in bits 16-25, how many in 0-9. Each SPI is set
// edge-triggered, to core 0.
//
// GICv3 ITS: a device writes an event number to GITS_TRANSLATER
// (ITS + 0x10040); the ITS maps (device ID, event) to an LPI
// (INTID 8192+) in one collection, core 0's redistributor.
// All tables are zeroed pages. The device ID is the PCI
// requester ID, mapped through ACPI's IORT.

pub const Msi = struct { address: u64, data: u32, intid: u32 };

const MsiKind = enum { unknown, none, v2m, its };
var msi_kind: MsiKind = .unknown;

var v2m_frame: usize = 0;
var v2m_next: u32 = 0;
var v2m_end: u32 = 0;

pub fn allocMsi(requester: u16) ?Msi {
    if (msi_kind == .unknown) msi_kind = findMsi();
    return switch (msi_kind) {
        .v2m => allocV2m(),
        .its => allocIts(requester),
        else => null,
    };
}

fn findMsi() MsiKind {
    if (distributor == 0) return .none;
    const madt = acpi.find("APIC") orelse return .none;
    var its_base: u64 = 0;
    var off: usize = 44;
    while (off + 2 <= madt.len) {
        const len = madt[off + 1];
        if (len < 2 or off + len > madt.len) break;
        const e = madt[off .. off + len];
        switch (e[0]) {
            0x0D => if (len >= 24 and v2m_frame == 0) {
                v2m_frame = @intCast(readU64(e, 8));
                const typer = mmio.read32(v2m_frame + 0x08);
                var first = (typer >> 16) & 0x3FF;
                var n = typer & 0x3FF;
                if (std.mem.readInt(u32, e[16..20], .little) & 1 != 0) {
                    n = std.mem.readInt(u16, e[20..22], .little);
                    first = std.mem.readInt(u16, e[22..24], .little);
                }
                v2m_next = first;
                v2m_end = first + n;
            },
            0x0F => if (len >= 16 and its_base == 0) {
                its_base = readU64(e, 8);
            },
            else => {},
        }
        off += len;
    }
    if (version >= 3 and its_base != 0 and initIts(@intCast(its_base))) return .its;
    if (v2m_frame != 0 and v2m_next < v2m_end) return .v2m;
    return .none;
}

// An SPI of the GICv2m frame for core `target` (it takes kicks):
// a device's message wakes that core directly, without a
// handler (the network core's wfi); null with an ITS (see
// deviceMessageFor) or none
pub fn messageFor(target: usize) ?Msi {
    if (target >= kick_ok.len or !kick_ok[target]) return null;
    if (msi_kind == .unknown) msi_kind = findMsi();
    return if (msi_kind == .v2m) allocV2mTo(target) else null;
}

fn allocV2m() ?Msi {
    return allocV2mTo(0);
}

fn allocV2mTo(target: usize) ?Msi {
    if (v2m_next >= v2m_end or v2m_next < 32) return null;
    const spi = v2m_next;
    v2m_next += 1;
    const d = distributor;
    // Edge-triggered (GICD_ICFGR: 2 bits each, the upper one), priority
    const cfg = d + 0xC00 + (spi / 16) * 4;
    mmio.write32(cfg, mmio.read32(cfg) | (@as(u32, 2) << @intCast((spi % 16) * 2)));
    setPriority(d, spi);
    if (version >= 3) {
        // Group 1 (what ICC_IAR1 takes), routed to core 0 (GICD_IROUTER)
        const grp = d + 0x80 + (spi / 32) * 4;
        mmio.write32(grp, mmio.read32(grp) | (@as(u32, 1) << @intCast(spi % 32)));
        // Core 0's (kicks on: switching started), wherever
        // the driver starts: ISOLCPUS= cores stay quiet
        const mpidr = if (kick_ok[target]) kick_to[target] else asm volatile ("mrs %[r], mpidr_el1"
            : [r] "=r" (-> u64),
        );
        const route = (mpidr & 0xFF_FFFF) | ((mpidr >> 32 & 0xFF) << 32);
        mmio.write32(d + 0x6000 + spi * 8, @truncate(route));
        mmio.write32(d + 0x6000 + spi * 8 + 4, @truncate(route >> 32));
    } else {
        // GICD_ITARGETSR: a byte per interrupt, the core's bit
        // (bit 0 core 0 until kicks say otherwise)
        const tgt = d + 0x800 + (spi & ~@as(u32, 3));
        const shift: u5 = @intCast((spi % 4) * 8);
        const bits: u32 = if (kick_ok[target]) @as(u32, @truncate(kick_to[target])) & 0xFF else 1;
        mmio.write32(tgt, (mmio.read32(tgt) & ~(@as(u32, 0xFF) << shift)) | (bits << shift));
    }
    mmio.write32(d + 0x100 + (spi / 32) * 4, @as(u32, 1) << @intCast(spi % 32)); // GICD_ISENABLER
    return .{ .address = v2m_frame + 0x40, .data = spi, .intid = spi };
}

const lpi_bits = 14; // INTIDs below 16384: LPIs 8192-16383
const first_lpi = 8192;
const events_per_device = 32;

var its: usize = 0;
var its_coherent = true; // the ITS and redistributor see the CPU's caches
var prop_table: [*]u8 = undefined;
var cmd_queue: [*]u64 = undefined;
const cmd_bytes = 4096;
var cmd_write: usize = 0;
var collection_target: u64 = 0; // MAPC's RDbase field
var next_lpi: u32 = first_lpi;

const ItsDevice = struct { id: u32, events: u32 };
var its_devices: [16]ItsDevice = undefined;
var its_device_count: usize = 0;

fn read64(addr: usize) u64 {
    return @as(u64, mmio.read32(addr)) | (@as(u64, mmio.read32(addr + 4)) << 32);
}

fn write64(addr: usize, v: u64) void {
    mmio.write32(addr, @truncate(v));
    mmio.write32(addr + 4, @truncate(v >> 32));
}

// Zeroed pages aligned to `alignment`
// bytes (the extra ones are left over)
fn zeroedPages(bytes: usize, alignment: usize) ?[*]u8 {
    const pages = (bytes + alignment + 4095) / 4096;
    const mem = memory.allocPages(pages, false) orelse return null;
    const start = std.mem.alignForward(usize, @intFromPtr(mem), alignment);
    const p: [*]u8 = @ptrFromInt(start);
    @memset(p[0..std.mem.alignForward(usize, bytes, 4096)], 0);
    cleanCache(start, bytes);
    return p;
}

// What the CPU wrote reaches memory,
// for a GIC that doesn't snoop caches
fn cleanCache(start: usize, len: usize) void {
    var a = start & ~@as(usize, 63);
    while (a < start + len) : (a += 64) asm volatile ("dc civac, %[a]"
        :
        : [a] "r" (a),
        : "memory"
    );
    asm volatile ("dsb sy" ::: "memory");
}

// Inner-shareable, write-back cacheable (fields at 7-9 and
// 10-11 of the table base registers)
const table_attrs: u64 = (0b111 << 7) | (0b01 << 10);

fn initIts(base: usize) bool {
    const d = distributor;
    const rd = own_redist;
    if (rd == 0) return false;
    if (mmio.read32(d + 0x4) & (1 << 17) == 0) return false; // GICD_TYPER.LPIS
    if ((mmio.read32(d + 0x4) >> 19) & 0x1F < lpi_bits - 1) return false; // IDbits
    its = base;

    // The redistributor: LPI configuration and pending tables, then LPIs on
    if (mmio.read32(rd) & 1 != 0) return false; // EnableLPIs already: can't reprogram
    const prop_bytes = (1 << lpi_bits) - first_lpi;
    prop_table = zeroedPages(prop_bytes, 4096) orelse return false;
    write64(rd + 0x70, @intFromPtr(prop_table) | table_attrs | (lpi_bits - 1)); // GICR_PROPBASER
    if ((read64(rd + 0x70) >> 10) & 3 == 0) its_coherent = false;
    const pend = zeroedPages((1 << lpi_bits) / 8, 64 * 1024) orelse return false;
    write64(rd + 0x78, @intFromPtr(pend) | table_attrs | (1 << 62)); // GICR_PENDBASER, PTZ
    mmio.write32(rd, mmio.read32(rd) | 1); // GICR_CTLR.EnableLPIs

    // The ITS, off while its tables are set
    mmio.write32(base, mmio.read32(base) & ~@as(u32, 1));
    var t: u32 = 0;
    while (mmio.read32(base) & (1 << 31) == 0) : (t += 1) { // Quiescent
        if (t > 1_000_000) return false;
    }
    const typer = read64(base + 0x8);
    const dev_bits: u6 = @intCast(@min(((typer >> 13) & 0x1F) + 1, 16));
    // The collection's target: the
    // redistributor's address (PTA) or its number
    collection_target = if (typer & (1 << 19) != 0) (rd >> 16) else ((read64(rd + 0x8) >> 8) & 0xFFFF);

    for (0..8) |n| {
        const reg = base + 0x100 + n * 8;
        const baser = read64(reg);
        const kind = (baser >> 56) & 7;
        if (kind != 1 and kind != 4) continue; // devices, collections
        const entry_size = ((baser >> 48) & 0x1F) + 1;
        const entries: u64 = if (kind == 1) @as(u64, 1) << dev_bits else 64;
        const bytes = std.mem.alignForward(u64, entries * entry_size, 4096);
        const table = zeroedPages(@intCast(bytes), 64 * 1024) orelse return false;
        // 4 KiB pages (Page_Size 0), Size: pages - 1 (up to 256)
        const pages = @min(bytes / 4096, 256);
        write64(reg, (1 << 63) | @intFromPtr(table) | table_attrs | (pages - 1));
        if ((read64(reg) >> 8) & 3 != 0) {
            // Only bigger pages: count in 64 KiB pages instead
            write64(reg, (1 << 63) | @intFromPtr(table) | table_attrs | (2 << 8) | (@max(bytes / 65536, 1) - 1));
        }
        if ((read64(reg) >> 10) & 3 == 0) its_coherent = false;
    }

    const q = zeroedPages(cmd_bytes, 64 * 1024) orelse return false;
    cmd_queue = @ptrCast(@alignCast(q));
    write64(base + 0x80, (1 << 63) | @intFromPtr(q) | table_attrs | (cmd_bytes / 4096 - 1)); // GITS_CBASER
    if ((read64(base + 0x80) >> 10) & 3 == 0) its_coherent = false;
    write64(base + 0x88, 0); // GITS_CWRITER
    cmd_write = 0;
    mmio.write32(base, mmio.read32(base) | 1); // GITS_CTLR.Enabled

    // Collection 0: core 0
    command(.{ 0x09, 0, (1 << 63) | (collection_target << 16), 0 }); // MAPC
    command(.{ 0x05, 0, collection_target << 16, 0 }); // SYNC
    return waitCommands();
}

fn command(c: [4]u64) void {
    const at = cmd_write / 8;
    cmd_queue[at..][0..4].* = c;
    if (!its_coherent) cleanCache(@intFromPtr(&cmd_queue[at]), 32);
    cmd_write = (cmd_write + 32) % cmd_bytes;
    write64(its + 0x88, cmd_write);
}

fn waitCommands() bool {
    var t: u32 = 0;
    while (read64(its + 0x90) & 0xF_FFE0 != cmd_write) : (t += 1) { // GITS_CREADR
        if (t > 10_000_000) return false;
    }
    return true;
}

// With an ITS: device `requester`'s own message, its LPI on
// core `target` (collection 1, set up once: LPIs on in that
// core's redistributor); null without an ITS or kicks there
pub fn deviceMessageFor(requester: u16, target: usize) ?Msi {
    if (target >= kick_ok.len or !kick_ok[target]) return null;
    if (msi_kind == .unknown) msi_kind = findMsi();
    if (msi_kind != .its) return null;
    if (other_core == null) {
        if (!lpisOn(kick_to[target])) return null;
        other_core = target;
    }
    if (other_core.? != target) return null;
    return allocItsIn(requester, 1);
}

var other_core: ?usize = null; // collection 1's
var other_target: u64 = 0; // its RDbase, as collection_target

// The core's redistributor: the LPI tables (the configuration
// shared with core 0's), LPIs on; collection 1 mapped to it
fn lpisOn(mpidr: u64) bool {
    const g = find() orelse return false;
    const rd = redistributorOf(g, mpidr) orelse return false;
    if (rd == own_redist) return false;
    if (mmio.read32(rd) & 1 == 0) {
        write64(rd + 0x70, read64(own_redist + 0x70)); // GICR_PROPBASER
        const pend = zeroedPages((1 << lpi_bits) / 8, 64 * 1024) orelse return false;
        write64(rd + 0x78, @intFromPtr(pend) | table_attrs | (1 << 62)); // GICR_PENDBASER, PTZ
        mmio.write32(rd, mmio.read32(rd) | 1); // GICR_CTLR.EnableLPIs
    }
    const target = if (read64(its + 0x8) & (1 << 19) != 0) (rd >> 16) else ((read64(rd + 0x8) >> 8) & 0xFFFF);
    other_target = target;
    command(.{ 0x09, 0, (1 << 63) | (target << 16) | 1, 0 }); // MAPC collection 1
    command(.{ 0x05, 0, target << 16, 0 }); // SYNC
    return waitCommands();
}

fn allocIts(requester: u16) ?Msi {
    return allocItsIn(requester, 0);
}

fn allocItsIn(requester: u16, collection: u16) ?Msi {
    if (next_lpi >= (1 << lpi_bits)) return null;
    const dev_id = deviceId(requester);
    // The device's table of events, mapped once
    const dev = for (its_devices[0..its_device_count]) |*x| {
        if (x.id == dev_id) break x;
    } else blk: {
        if (its_device_count == its_devices.len) return null;
        const itt_entry = ((read64(its + 0x8) >> 4) & 0xF) + 1;
        const itt = zeroedPages(@intCast(itt_entry * events_per_device), 4096) orelse return null;
        // MAPD: device, event bits - 1, the table (256-byte aligned), valid
        command(.{ 0x08 | (@as(u64, dev_id) << 32), std.math.log2_int(u32, events_per_device) - 1, (1 << 63) | @intFromPtr(itt), 0 });
        its_devices[its_device_count] = .{ .id = dev_id, .events = 0 };
        its_device_count += 1;
        break :blk &its_devices[its_device_count - 1];
    };
    if (dev.events == events_per_device) return null;
    const event = dev.events;
    dev.events += 1;
    const lpi = next_lpi;
    next_lpi += 1;
    // The LPI's configuration byte: priority 0xA0, bit 1 (RES1), enabled
    prop_table[lpi - first_lpi] = 0xA0 | 0b11;
    if (!its_coherent) cleanCache(@intFromPtr(&prop_table[lpi - first_lpi]), 1);
    command(.{ 0x0A | (@as(u64, dev_id) << 32), event | (@as(u64, lpi) << 32), collection, 0 }); // MAPTI
    command(.{ 0x0C | (@as(u64, dev_id) << 32), event, 0, 0 }); // INV
    command(.{ 0x05, 0, (if (collection == 1) other_target else collection_target) << 16, 0 }); // SYNC
    if (!waitCommands()) return null;
    return .{ .address = its + 0x10040, .data = event, .intid = lpi };
}

// A PCI requester ID as the ITS knows it: through the IORT's
// root complex mapping straight to an ITS (output base +
// offset), else the same number
fn deviceId(requester: u16) u32 {
    const iort = acpi.find("IORT") orelse return requester;
    if (iort.len < 48) return requester;
    const nodes = std.mem.readInt(u32, iort[36..40], .little);
    var off: usize = std.mem.readInt(u32, iort[40..44], .little);
    var n: u32 = 0;
    while (n < nodes and off + 16 <= iort.len) : (n += 1) {
        const node_len = std.mem.readInt(u16, iort[off + 1 ..][0..2], .little);
        if (node_len < 16 or off + node_len > iort.len) break;
        if (iort[off] == 2 and node_len >= 36) { // root complex
            const segment = std.mem.readInt(u32, iort[off + 28 ..][0..4], .little);
            const maps = std.mem.readInt(u32, iort[off + 8 ..][0..4], .little);
            const maps_at = std.mem.readInt(u32, iort[off + 12 ..][0..4], .little);
            var m: u32 = 0;
            while (segment == 0 and m < maps) : (m += 1) {
                const e = off + maps_at + m * 20;
                if (e + 20 > iort.len) break;
                const in_base = std.mem.readInt(u32, iort[e..][0..4], .little);
                const in_count = std.mem.readInt(u32, iort[e + 4 ..][0..4], .little); // minus one
                const out_base = std.mem.readInt(u32, iort[e + 8 ..][0..4], .little);
                const target = std.mem.readInt(u32, iort[e + 12 ..][0..4], .little);
                if (requester < in_base or requester - in_base > in_count) continue;
                // Only a mapping straight to an ITS group (type 0) gives the device ID
                if (target < iort.len and iort[target] == 0) return out_base + (requester - in_base);
            }
        }
        off += node_len;
    }
    return requester;
}
