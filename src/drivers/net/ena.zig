//! Amazon ENA (AWS Nitro), after FreeBSD's ena and ena_com: one
//! TX and one RX queue, polled, LLQ when offered.
//! Untested (QEMU has no ENA). Memory is identity-mapped.

const std = @import("std");
const builtin = @import("builtin");

pub fn supports(vendor_id: u16, device_id: u16) bool {
    return vendor_id == 0x1D0F and switch (device_id) {
        0x0EC2, 0x1EC2, 0xEC20, 0xEC21 => true,
        else => false,
    };
}

// BAR 0: the registers, and the doorbells the device puts in it
pub const reg_span: usize = 1 << 20;
// BAR 2: the LLQ memory (TX
// descriptors written into the device)
pub const mem_bar_index: u3 = 2;
pub const mem_bar_span: usize = 16 << 20;

const ring_max = 256;
const buf_size = 2048;
const mtu = 1500;

// Pages of `mem`: admin SQ, admin CQ, AENQ (+ readless
// response), TX SQ, TX CQ, RX SQ,
// RX CQ, then the TX and RX buffers
const p_asq = 0;
const p_acq = 1;
const p_aenq = 2;
const p_txsq = 3;
const p_txcq = 4;
const p_rxsq = 5;
const p_rxcq = 6;
const p_txbuf = 7;
const p_rxbuf = p_txbuf + ring_max * buf_size / 4096;
pub const pages: usize = p_rxbuf + ring_max * buf_size / 4096;

// Registers
const CAPS = 0x08;
const AQ_BASE_LO = 0x10;
const AQ_BASE_HI = 0x14;
const AQ_CAPS = 0x18;
const ACQ_BASE_LO = 0x20;
const ACQ_BASE_HI = 0x24;
const ACQ_CAPS = 0x28;
const AQ_DB = 0x2C;
const AENQ_CAPS = 0x34;
const AENQ_BASE_LO = 0x38;
const AENQ_BASE_HI = 0x3C;
const AENQ_HEAD_DB = 0x40;
const INTR_MASK = 0x4C;
const DEV_CTL = 0x54;
const DEV_STS = 0x58;
const MMIO_REG_READ = 0x5C;
const MMIO_RESP_LO = 0x60;
const MMIO_RESP_HI = 0x64;
const VERSION = 0x00;
const CONTROLLER_VERSION = 0x04;

const sts_ready = 1 << 0;
const sts_reset_in_progress = 1 << 3;
const read_timeout = 0xFFFF_FFFF;

const admin_depth = 32;
const aenq_depth = 16;
const entry_size = 64; // admin SQ / CQ and AENQ entries

// Admin opcodes, features, AENQ groups
const op_create_sq = 1;
const op_create_cq = 3;
const op_get_feature = 8;
const op_set_feature = 9;
const f_device_attributes = 1;
const f_max_queues_num = 2;
const f_llq = 4;
const f_max_queues_ext = 7;
const f_mtu = 14;
const f_aenq_config = 26;
const group_link_change = 0;
const placement_host = 1;
const placement_dev = 3;

// TX descriptor (len_ctrl) bits; the meta descriptor's
const tx_first = 1 << 26;
const tx_last = 1 << 27;
const tx_comp_req = 1 << 28;
const meta_ext_valid = 1 << 14;
const meta_eth_type = 1 << 20;
const meta_store = 1 << 21;
const meta_desc = 1 << 23;
// RX descriptor ctrl, RX completion status
const rx_ctrl = (1 << 2) | (1 << 3) | (1 << 4); // first, last, completion requested
const rxc_phase = 1 << 24;
const rxc_first = 1 << 26;
const rxc_last = 1 << 27;

pub const Error = error{ NotReady, ResetFailed, BadVersion, BadDmaWidth, AdminTimeout, AdminFailed, Unsupported, NoQueues };

inline fn barrier() void {
    switch (builtin.cpu.arch) {
        .x86_64, .x86 => asm volatile ("mfence" ::: "memory"),
        .aarch64 => asm volatile ("dmb sy" ::: "memory"),
        else => asm volatile ("" ::: "memory"),
    }
}

// DMA memory the device writes: always read through volatile
fn get16(p: [*]u8, off: usize) u16 {
    return @as(*volatile u16, @ptrCast(@alignCast(p + off))).*;
}
fn get32(p: [*]u8, off: usize) u32 {
    return @as(*volatile u32, @ptrCast(@alignCast(p + off))).*;
}
fn put8(p: [*]u8, off: usize, v: u8) void {
    @as(*volatile u8, @ptrCast(p + off)).* = v;
}
fn put16(p: [*]u8, off: usize, v: u16) void {
    @as(*volatile u16, @ptrCast(@alignCast(p + off))).* = v;
}
fn put32(p: [*]u8, off: usize, v: u32) void {
    @as(*volatile u32, @ptrCast(@alignCast(p + off))).* = v;
}
// An ena_common_mem_addr: low 32 bits, high 16
fn putAddr(p: [*]u8, off: usize, addr: u64) void {
    put32(p, off, @truncate(addr));
    put16(p, off + 4, @truncate(addr >> 32));
}

const Llq = struct {
    entry: u16 = 128, // bytes per entry
    before_header: u16 = 2, // descriptors in the first entry before the pushed header
    per_line: u16 = 8, // descriptors per later entry
    no_meta_caching: bool = false, // every packet carries a meta descriptor
};

pub const Ena = struct {
    base: usize,
    mem_bar: usize = 0,
    // PCI revision ID: bit 0 set means no readless register reads
    revision: u8 = 0,
    mac: [6]u8 = undefined,

    mem: [*]u8 = undefined,
    delay_us: *const fn (u32) void = undefined,
    readless: bool = true,
    read_seq: u16 = 0,
    dma_bits: u6 = 48,
    admin_timeout_us: u32 = 3_000_000,
    supported: u32 = 0,

    aq_tail: u16 = 0,
    aq_phase: u1 = 1,
    acq_head: u16 = 0,
    acq_phase: u1 = 1,
    aenq_head: u16 = aenq_depth,
    aenq_phase: u1 = 1,
    link_up: bool = false,

    llq: ?Llq = null,
    max_header: u16 = 0, // LLQ: bytes pushed with the descriptors

    tx_depth: u16 = 0,
    tx_db: usize = 0,
    tx_llq: usize = 0, // LLQ: where the device's TX entries are
    tx_tail: u16 = 0,
    tx_phase: u1 = 1,
    tx_comp: u16 = 0, // SQ entries the device is done with
    txc_head: u16 = 0,
    txc_phase: u1 = 1,
    tx_next: u16 = 0,
    tx_busy: [ring_max]bool = @splat(false),
    tx_entries: [ring_max]u8 = @splat(0), // SQ entries each request took

    rx_depth: u16 = 0,
    rx_db: usize = 0,
    rx_tail: u16 = 0,
    rx_phase: u1 = 1,
    rxc_head: u16 = 0,
    rxc_phase: u1 = 1,

    fn page(self: *const Ena, n: usize) [*]u8 {
        return self.mem + n * 4096;
    }

    fn rawRead(self: *const Ena, reg: usize) u32 {
        const p: *const volatile u32 = @ptrFromInt(self.base + reg);
        return switch (builtin.cpu.arch) {
            // 32 bits wide whatever is tested of it (see arch/mmio.zig)
            .x86_64, .x86 => asm volatile ("movl (%[p]), %[r]"
                : [r] "=r" (-> u32),
                : [p] "r" (p),
                : "memory"
            ),
            .aarch64 => asm volatile ("ldr %[r:w], [%[p]]"
                : [r] "=r" (-> u32),
                : [p] "r" (p),
                : "memory"
            ),
            else => p.*,
        };
    }

    fn write(self: *const Ena, reg: usize, value: u32) void {
        @as(*volatile u32, @ptrFromInt(self.base + reg)).* = value;
    }

    // A register through the readless mechanism: the device writes
    // it to memory (ena_com_reg_bar_read32)
    fn read(self: *Ena, reg: u16) u32 {
        if (!self.readless) return self.rawRead(reg);
        const resp = self.page(p_aenq) + 2048;
        self.read_seq +%= 1;
        put16(resp, 0, self.read_seq +% 0xDEAD);
        barrier();
        self.write(MMIO_REG_READ, (@as(u32, reg) << 16) | self.read_seq);
        var i: u32 = 0;
        while (i < 200_000) : (i += 1) {
            if (get16(resp, 0) == self.read_seq) break;
            self.delay_us(1);
        } else return read_timeout;
        barrier();
        if (get16(resp, 2) != reg) return read_timeout;
        return get32(resp, 4);
    }

    fn setReadResponse(self: *const Ena) void {
        const addr: u64 = @intFromPtr(self.page(p_aenq) + 2048);
        self.write(MMIO_RESP_LO, @truncate(addr));
        self.write(MMIO_RESP_HI, @truncate(addr >> 32));
    }

    // Until DEV_STS's reset-in-progress
    // bit is `want`, `timeout` in 100 ms
    fn waitReset(self: *Ena, timeout: u32, want: u32) Error!void {
        var waited: u64 = 0;
        var delay: u32 = 100;
        while (true) {
            const v = self.read(DEV_STS);
            if (v == read_timeout) return error.ResetFailed;
            if (v & sts_reset_in_progress == want) return;
            if (waited >= @as(u64, timeout) * 100_000) return error.ResetFailed;
            self.delay_us(delay);
            waited += delay;
            delay = @min(delay * 2, 5000);
        }
    }

    fn reset(self: *Ena) Error!void {
        const sts = self.read(DEV_STS);
        const caps = self.read(CAPS);
        if (sts == read_timeout or caps == read_timeout or sts & sts_ready == 0) return error.NotReady;
        const timeout = (caps >> 1) & 0x1F;
        if (timeout == 0) return error.ResetFailed;
        self.write(DEV_CTL, 1); // reset, reason "normal"
        self.setReadResponse();
        try self.waitReset(timeout, sts_reset_in_progress);
        self.write(DEV_CTL, 0);
        try self.waitReset(timeout, 0);
        const admin_to = (caps >> 16) & 0xF;
        self.admin_timeout_us = if (admin_to != 0) admin_to * 100_000 else 3_000_000;
    }

    // One admin command (64 bytes), its
    // completion into `resp`; polled
    fn admin(self: *Ena, cmd: *[entry_size]u8, resp: *[entry_size]u8) Error!void {
        const mask = admin_depth - 1;
        const id: u16 = self.aq_tail & mask;
        std.mem.writeInt(u16, cmd[0..2], id, .little);
        cmd[3] |= self.aq_phase;
        @memcpy(self.page(p_asq)[@as(usize, id) * entry_size ..][0..entry_size], cmd);
        self.aq_tail +%= 1;
        if (self.aq_tail & mask == 0) self.aq_phase ^= 1;
        barrier();
        self.write(AQ_DB, self.aq_tail);

        var waited: u64 = 0;
        var delay: u32 = 100;
        while (true) {
            const cq = self.page(p_acq);
            while (true) {
                const e = cq + @as(usize, self.acq_head & mask) * entry_size;
                if (@as(*volatile u8, &e[3]).* & 1 != self.acq_phase) break;
                barrier();
                const done = get16(e, 0) & 0xFFF;
                const status = @as(*volatile u8, &e[2]).*;
                if (done == id) @memcpy(resp, e[0..entry_size]);
                self.acq_head +%= 1;
                if (self.acq_head & mask == 0) self.acq_phase ^= 1;
                if (done == id) {
                    return switch (status) {
                        0 => {},
                        3 => error.Unsupported,
                        else => error.AdminFailed,
                    };
                }
            }
            if (waited >= self.admin_timeout_us) return error.AdminTimeout;
            self.delay_us(delay);
            waited += delay;
            delay = @min(delay * 2, 5000);
        }
    }

    fn getFeature(self: *Ena, id: u8, version: u8, resp: *[entry_size]u8) Error!void {
        if (id != f_device_attributes and self.supported & (@as(u32, 1) << @intCast(id)) == 0) return error.Unsupported;
        var cmd: [entry_size]u8 = @splat(0);
        cmd[2] = op_get_feature;
        cmd[17] = id;
        cmd[18] = version;
        try self.admin(&cmd, resp);
    }

    // Reset, admin queue, features, LLQ if offered, one TX and one
    // RX queue (FreeBSD's ena_device_init, ena_up). mem:
    // `pages` pages.
    pub fn init(self: *Ena, mem: [*]align(4096) u8, delay_us: *const fn (u32) void) Error!void {
        self.mem = mem;
        self.delay_us = delay_us;
        @memset(mem[0 .. p_txbuf * 4096], 0);

        self.readless = self.revision & 1 == 0;
        self.read_seq = 0;
        self.setReadResponse();
        try self.reset();

        const ver = self.read(VERSION);
        const ctrl = self.read(CONTROLLER_VERSION);
        if (ver == read_timeout or ctrl == read_timeout or ctrl & 0xFF_FFFF < 1) return error.BadVersion;
        const caps = self.read(CAPS);
        if (caps == read_timeout) return error.BadDmaWidth;
        const width = (caps >> 8) & 0xFF;
        if (width < 32 or width > 48) return error.BadDmaWidth;
        self.dma_bits = @intCast(width);
        const top: u64 = @intFromPtr(mem) + pages * 4096;
        if (top > (@as(u64, 1) << self.dma_bits)) return error.BadDmaWidth;

        // Admin queues and the AENQ (ena_com_admin_init)
        const sts = self.read(DEV_STS);
        if (sts == read_timeout or sts & sts_ready == 0) return error.NotReady;
        const asq: u64 = @intFromPtr(self.page(p_asq));
        const acq: u64 = @intFromPtr(self.page(p_acq));
        const aenq: u64 = @intFromPtr(self.page(p_aenq));
        self.write(AQ_BASE_LO, @truncate(asq));
        self.write(AQ_BASE_HI, @truncate(asq >> 32));
        self.write(ACQ_BASE_LO, @truncate(acq));
        self.write(ACQ_BASE_HI, @truncate(acq >> 32));
        self.write(AQ_CAPS, admin_depth | (entry_size << 16));
        self.write(ACQ_CAPS, admin_depth | (entry_size << 16));
        self.write(AENQ_BASE_LO, @truncate(aenq));
        self.write(AENQ_BASE_HI, @truncate(aenq >> 32));
        self.write(AENQ_CAPS, aenq_depth | (entry_size << 16));
        self.write(INTR_MASK, 1); // admin completions polled

        var r: [entry_size]u8 = undefined;
        try self.getFeature(f_device_attributes, 0, &r);
        self.supported = get32(&r, 16);
        @memcpy(&self.mac, r[32..38]);

        // Queue depths: the device's limits,
        // powers of two, at most ring_max
        var tx_max: u32 = 0;
        var rx_max: u32 = 0;
        var tx_sq_max: u32 = 0;
        if (self.getFeature(f_max_queues_ext, 1, &r)) |_| {
            if (r[8] != 1) return error.NoQueues;
            rx_max = @min(get32(&r, 40), get32(&r, 36));
            tx_max = get32(&r, 32);
            tx_sq_max = get32(&r, 28);
        } else |err| {
            if (err != error.Unsupported) return err;
            try self.getFeature(f_max_queues_num, 0, &r);
            rx_max = @min(get32(&r, 20), get32(&r, 12));
            tx_max = get32(&r, 20);
            tx_sq_max = get32(&r, 12);
        }

        // Link changes only; without them the link counts as up
        try self.getFeature(f_aenq_config, 0, &r);
        const groups = get32(&r, 8) & (1 << group_link_change);
        self.link_up = groups == 0;
        if (groups != 0) {
            var cmd: [entry_size]u8 = @splat(0);
            cmd[2] = op_set_feature;
            cmd[17] = f_aenq_config;
            put32(&cmd, 24, groups);
            try self.admin(&cmd, &r);
        }

        // TX placement: LLQ if the device has it (some Nitro devices
        // need it), else descriptors in host
        // memory as FreeBSD falls back to
        var llq_depth: u32 = 0;
        if (self.mem_bar != 0 and self.supported & (1 << f_llq) != 0) {
            if (self.getFeature(f_llq, 1, &r)) |_| {
                if (get32(&r, 8) != 0) {
                    if (self.configLlq(&r)) |l| {
                        self.llq = l;
                        llq_depth = get32(&r, 12);
                        // 256-byte entries: the device's depth for them, else half
                        if (l.entry == 256) llq_depth = if (get16(&r, 34) != 0) get16(&r, 34) else llq_depth / 2;
                    } else |_| {}
                }
            } else |err| if (err != error.Unsupported) return err;
        }
        tx_max = @min(tx_max, if (self.llq != null) llq_depth else tx_sq_max);
        self.tx_depth = depthFor(tx_max) orelse return error.NoQueues;
        self.rx_depth = depthFor(rx_max) orelse return error.NoQueues;

        // AENQ: every entry ours to fill (ena_com_admin_aenq_enable)
        self.write(AENQ_HEAD_DB, aenq_depth);

        if (self.supported & (1 << f_mtu) != 0) {
            var cmd: [entry_size]u8 = @splat(0);
            cmd[2] = op_set_feature;
            cmd[17] = f_mtu;
            put32(&cmd, 20, mtu);
            self.admin(&cmd, &r) catch {};
        }

        try self.createQueues();
        self.fillRx();
    }

    fn depthFor(max: u32) ?u16 {
        if (max < 8) return null;
        const d: u32 = @min(max, ring_max);
        return @intCast(@as(u32, 1) << @intCast(31 - @clz(d)));
    }

    // FreeBSD's defaults (inline header, several descriptors per
    // entry, 128 bytes, 2 before the
    // header), else what the device has
    fn configLlq(self: *Ena, r: *[entry_size]u8) Error!Llq {
        var l: Llq = .{};
        if (get16(r, 16) & 1 == 0) return error.Unsupported; // inline header
        const strides = get16(r, 28);
        const multiple = strides & 2 != 0;
        if (!multiple and strides & 1 == 0) return error.Unsupported;
        const sizes = get16(r, 20);
        const size_ctrl: u16 = if (sizes & 1 != 0) 1 else if (sizes & 2 != 0) 2 else if (sizes & 4 != 0) 4 else return error.Unsupported;
        l.entry = switch (size_ctrl) {
            1 => 128,
            2 => 192,
            else => 256,
        };
        const before = get16(r, 24);
        l.before_header = if (before & 2 != 0) 2 else if (before & 1 != 0) 1 else if (before & 4 != 0) 4 else if (before & 8 != 0) 8 else return error.Unsupported;
        l.per_line = if (multiple) l.entry / 16 else 1;
        const accel = get16(r, 36);
        l.no_meta_caching = accel & 1 != 0;
        if (l.entry <= l.before_header * 16) return error.Unsupported;

        var cmd: [entry_size]u8 = @splat(0);
        cmd[2] = op_set_feature;
        cmd[17] = f_llq;
        put16(&cmd, 30, 1);
        put16(&cmd, 34, size_ctrl);
        put16(&cmd, 38, l.before_header);
        put16(&cmd, 42, if (multiple) 2 else 1);
        put16(&cmd, 48, 0b11); // disable meta caching, limit TX burst
        var resp: [entry_size]u8 = undefined;
        try self.admin(&cmd, &resp);
        self.max_header = @min(l.entry - l.before_header * 16, 255);
        return l;
    }

    // A completion queue (CQ entry size
    // in words), then its submission queue
    fn createQueue(self: *Ena, tx: bool, depth: u16, sq: [*]u8, cq: [*]u8) Error!struct { db: u32, llq: u32 } {
        var r: [entry_size]u8 = undefined;
        var cmd: [entry_size]u8 = @splat(0);
        cmd[2] = op_create_cq;
        cmd[4] = 1 << 5; // interrupt mode, never unmasked: polled
        cmd[5] = if (tx) 2 else 4;
        put16(&cmd, 6, depth);
        // No vector, as polling drivers do; else vector 0
        put32(&cmd, 8, 0xFFFF_FFFF);
        putAddr(&cmd, 12, @intFromPtr(cq));
        self.admin(&cmd, &r) catch |err| {
            if (err != error.AdminFailed) return err;
            cmd[0] = 0;
            cmd[1] = 0;
            cmd[3] = 0;
            put32(&cmd, 8, 0);
            try self.admin(&cmd, &r);
        };
        const cq_idx = get16(&r, 8);

        cmd = @splat(0);
        cmd[2] = op_create_sq;
        cmd[4] = (if (tx) @as(u8, 1) else 2) << 5;
        const placement: u8 = if (tx and self.llq != null) placement_dev else placement_host;
        cmd[6] = placement; // completion policy 0: a completion per descriptor
        cmd[7] = 1; // physically contiguous
        put16(&cmd, 8, cq_idx);
        put16(&cmd, 10, depth);
        if (placement == placement_host) putAddr(&cmd, 12, @intFromPtr(sq));
        try self.admin(&cmd, &r);
        return .{ .db = get32(&r, 12), .llq = get32(&r, 16) };
    }

    fn createQueues(self: *Ena) Error!void {
        const t = try self.createQueue(true, self.tx_depth, self.page(p_txsq), self.page(p_txcq));
        if (t.db + 4 > reg_span) return error.NoQueues;
        self.tx_db = self.base + t.db;
        if (self.llq) |l| {
            if (@as(usize, t.llq) + @as(usize, self.tx_depth) * l.entry > mem_bar_span) return error.NoQueues;
            self.tx_llq = self.mem_bar + t.llq;
        }
        const rq = try self.createQueue(false, self.rx_depth, self.page(p_rxsq), self.page(p_rxcq));
        if (rq.db + 4 > reg_span) return error.NoQueues;
        self.rx_db = self.base + rq.db;
    }

    fn doorbell(addr: usize, tail: u16) void {
        barrier();
        @as(*volatile u32, @ptrFromInt(addr)).* = tail;
    }

    // RX buffer `id` back to the device at the SQ's tail
    fn postRx(self: *Ena, id: u16) void {
        const d = self.page(p_rxsq) + @as(usize, self.rx_tail & (self.rx_depth - 1)) * 16;
        const addr: u64 = @intFromPtr(self.page(p_rxbuf) + @as(usize, id) * buf_size);
        put16(d, 0, buf_size);
        put8(d, 2, 0);
        put8(d, 3, rx_ctrl | @as(u8, self.rx_phase));
        put16(d, 4, id);
        put16(d, 6, 0);
        put32(d, 8, @truncate(addr));
        put16(d, 12, @truncate(addr >> 32));
        put16(d, 14, 0);
        self.rx_tail +%= 1;
        if (self.rx_tail & (self.rx_depth - 1) == 0) self.rx_phase ^= 1;
    }

    // The ring less one entry (an SQ never fills)
    fn fillRx(self: *Ena) void {
        var id: u16 = 0;
        while (id < self.rx_depth - 1) : (id += 1) self.postRx(id);
        doorbell(self.rx_db, self.rx_tail);
    }

    // AENQ events: link changes (ena_com_aenq_intr_handler)
    fn pollAenq(self: *Ena) void {
        const q = self.page(p_aenq);
        var done: u16 = 0;
        while (true) {
            const e = q + @as(usize, self.aenq_head & (aenq_depth - 1)) * entry_size;
            if (@as(*volatile u8, &e[4]).* & 1 != self.aenq_phase) break;
            barrier();
            if (get16(e, 0) == group_link_change) self.link_up = get32(e, 16) & 1 != 0;
            self.aenq_head +%= 1;
            if (self.aenq_head & (aenq_depth - 1) == 0) self.aenq_phase ^= 1;
            done += 1;
        }
        if (done == 0) return;
        barrier();
        self.write(AENQ_HEAD_DB, self.aenq_head);
    }

    // TX completions: their requests' buffers free again
    fn reapTx(self: *Ena) void {
        const cq = self.page(p_txcq);
        while (true) {
            const e = cq + @as(usize, self.txc_head & (self.tx_depth - 1)) * 8;
            if (@as(*volatile u8, &e[3]).* & 1 != self.txc_phase) break;
            barrier();
            const id = get16(e, 0);
            self.txc_head +%= 1;
            if (self.txc_head & (self.tx_depth - 1) == 0) self.txc_phase ^= 1;
            if (id >= self.tx_depth or !self.tx_busy[id]) continue;
            self.tx_busy[id] = false;
            self.tx_comp +%= self.tx_entries[id];
        }
    }

    fn sqFree(self: *const Ena) u16 {
        return self.tx_depth - 1 - (self.tx_tail -% self.tx_comp);
    }

    pub fn send(self: *Ena, frame: []const u8) bool {
        if (frame.len == 0 or frame.len > buf_size) return false;
        self.reapTx();
        if (self.sqFree() < 3) return false;
        const id = self.tx_next;
        if (self.tx_busy[id]) return false;
        const buf = self.page(p_txbuf) + @as(usize, id) * buf_size;
        @memcpy(buf[0..frame.len], frame);
        const start = self.tx_tail;
        if (self.llq) |l| self.sendLlq(l, id, buf, frame) else {
            const d = self.page(p_txsq) + @as(usize, self.tx_tail & (self.tx_depth - 1)) * 16;
            self.txDesc(d, id, @intFromPtr(buf), @intCast(frame.len), 0, true);
            self.tx_tail +%= 1;
            if (self.tx_tail & (self.tx_depth - 1) == 0) self.tx_phase ^= 1;
        }
        self.tx_entries[id] = @intCast(self.tx_tail -% start);
        self.tx_busy[id] = true;
        self.tx_next = (id + 1) & (self.tx_depth - 1);
        doorbell(self.tx_db, self.tx_tail);
        return true;
    }

    // A data descriptor (ena_com_prepare_tx), the packet's only one
    fn txDesc(self: *const Ena, d: [*]u8, id: u16, addr: u64, len: u16, header: u8, first: bool) void {
        const hi: u32 = @truncate((addr >> 32) & ((@as(u64, 1) << self.dma_bits) - 1) & 0xFFFF);
        put32(d, 0, len | (@as(u32, id >> 10) << 16) | (@as(u32, self.tx_phase) << 24) | (if (first) @as(u32, tx_first) else 0) | tx_last | tx_comp_req);
        put32(d, 4, @as(u32, id & 0x3FF) << 22);
        put32(d, 8, @truncate(addr));
        put32(d, 12, hi | (@as(u32, header) << 24));
    }

    // LLQ: the descriptors and the frame's first bytes written into
    // the device's entries (FreeBSD's bounce buffer lines)
    fn sendLlq(self: *Ena, l: Llq, id: u16, buf: [*]u8, frame: []const u8) void {
        var line: [256]u8 align(8) = @splat(0);
        const header: u16 = @intCast(@min(frame.len, self.max_header));
        @memcpy(line[l.before_header * 16 ..][0..header], frame[0..header]);
        var idx: u16 = 0;
        var left: u16 = l.before_header;
        if (l.no_meta_caching) {
            // A meta descriptor without offloads
            const m: [*]u8 = &line;
            put32(m, 0, meta_desc | meta_ext_valid | meta_eth_type | (@as(u32, self.tx_phase) << 24) | tx_first | meta_store);
            idx += 1;
            left -= 1;
            if (left == 0) {
                self.flushLine(l, &line);
                idx = 0;
                left = l.per_line;
            }
        }
        const rest: u16 = @intCast(frame.len - header);
        const addr: u64 = if (rest != 0) @intFromPtr(buf + header) else 0;
        self.txDesc(@as([*]u8, &line) + @as(usize, idx) * 16, id, addr, rest, @intCast(header), !l.no_meta_caching);
        self.flushLine(l, &line);
    }

    fn flushLine(self: *Ena, l: Llq, line: *align(8) [256]u8) void {
        const dst: [*]volatile u64 = @ptrFromInt(self.tx_llq + @as(usize, self.tx_tail & (self.tx_depth - 1)) * l.entry);
        const src: [*]const u64 = @ptrCast(line);
        for (0..l.entry / 8) |i| dst[i] = src[i];
        @memset(line, 0);
        self.tx_tail +%= 1;
        if (self.tx_tail & (self.tx_depth - 1) == 0) self.tx_phase ^= 1;
    }

    // One received frame into buf (its length), null if none waits.
    // A frame over several buffers,
    // or too long for buf, is dropped.
    pub fn receive(self: *Ena, buf: []u8) ?usize {
        self.pollAenq();
        self.reapTx();
        const cq = self.page(p_rxcq);
        const mask = self.rx_depth - 1;
        var tries: u16 = 0;
        while (tries < self.rx_depth) : (tries += 1) {
            // The whole packet's completions there?
            // (ena_com_cdesc_rx_pkt_get)
            var n: u16 = 0;
            var phase = self.rxc_phase;
            var complete = false;
            while (n < self.rx_depth) {
                const at = self.rxc_head +% n;
                const e = cq + @as(usize, at & mask) * 16;
                const status = get32(e, 0);
                if ((status & rxc_phase) >> 24 != phase) break;
                n += 1;
                if ((at +% 1) & mask == 0) phase ^= 1;
                if (status & rxc_last != 0) {
                    complete = true;
                    break;
                }
            }
            if (!complete) return null;
            barrier();
            const first = cq + @as(usize, self.rxc_head & mask) * 16;
            const good = n == 1 and get32(first, 0) & rxc_first != 0;
            var len: usize = 0;
            for (0..n) |k| {
                const e = cq + @as(usize, (self.rxc_head +% @as(u16, @intCast(k))) & mask) * 16;
                const id = get16(e, 6);
                if (good) {
                    const off = @as(*volatile u8, &e[14]).*;
                    len = get16(e, 4);
                    if (id < self.rx_depth and off + len <= buf_size and len <= buf.len) {
                        @memcpy(buf[0..len], (self.page(p_rxbuf) + @as(usize, id) * buf_size + off)[0..len]);
                    } else len = 0;
                }
                if (id < self.rx_depth) self.postRx(id);
            }
            self.rxc_head +%= n;
            self.rxc_phase = phase;
            doorbell(self.rx_db, self.rx_tail);
            if (good and len != 0) return len;
        }
        return null;
    }

    pub fn linkUp(self: *Ena) bool {
        self.pollAenq();
        return self.link_up;
    }

    // ENA has no such setting
    pub fn promiscuous(self: *Ena) bool {
        _ = self;
        return false;
    }
};
