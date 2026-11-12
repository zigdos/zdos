//! Intel 8254x (e1000) and 82574 (e1000e): one receive and
//! one transmit ring of legacy descriptors, frames copied
//! in and out. Memory is identity-mapped (DMA addresses
//! are the buffers').

const std = @import("std");
const builtin = @import("builtin");

pub const bar_span = 128 * 1024; // the registers (BAR 0)

const CTRL = 0x0000;
const STATUS = 0x0008;
const EERD = 0x0014;
const ICR = 0x00C0;
const IMS = 0x00D0;
const IMC = 0x00D8;
const IVAR = 0x00E4; // 82574: which MSI-X vector each cause uses
const RCTL = 0x0100;
const TCTL = 0x0400;
const TIPG = 0x0410;
const RDBAL = 0x2800;
const RDBAH = 0x2804;
const RDLEN = 0x2808;
const RDH = 0x2810;
const RDT = 0x2818;
const TDBAL = 0x3800;
const TDBAH = 0x3804;
const TDLEN = 0x3808;
const TDH = 0x3810;
const TDT = 0x3818;
const MTA = 0x5200;
const RAL0 = 0x5400;
const RAH0 = 0x5404;

const ctrl_slu = 1 << 6; // set link up
const ctrl_asde = 1 << 5; // speed from auto-negotiation
const ctrl_rst = 1 << 26;
const status_lu = 1 << 1;
const rctl_en = 1 << 1;
const rctl_upe = 1 << 3; // every unicast frame
const rctl_mpe = 1 << 4; // every multicast frame
const rctl_bam = 1 << 15; // broadcasts
const rctl_secrc = 1 << 26; // strip the CRC
const tctl_en = 1 << 1;
const tctl_psp = 1 << 3; // pad short frames
// Interrupt causes: link change, receive descriptors
// low, overrun, timer; with MSI-X the 82574's per-queue
// ones (receive queue 0, other)
const int_causes: u32 = (1 << 2) | (1 << 4) | (1 << 6) | (1 << 7);
const msix_causes: u32 = (1 << 20) | (1 << 24);

const RxDesc = extern struct {
    addr: u64,
    length: u16,
    checksum: u16,
    status: u8,
    errors: u8,
    special: u16,
};

const TxDesc = extern struct {
    addr: u64,
    length: u16,
    cso: u8,
    cmd: u8,
    status: u8,
    css: u8,
    special: u16,
};

const desc_dd = 1; // descriptor done
const rx_eop = 2;
const tx_cmd = 0x0B; // end of packet, insert CRC, report status

pub const rx_count = 128;
pub const tx_count = 64;
pub const buf_size = 2048;

// Pages the driver needs: rings and buffers
pub const pages = 1 + 1 + (rx_count + tx_count) * buf_size / 4096;

pub const E1000 = struct {
    base: usize,
    is_82574: bool,
    mac: [6]u8 = undefined,
    rx: [*]volatile RxDesc = undefined,
    tx: [*]volatile TxDesc = undefined,
    rx_bufs: [*]u8 = undefined,
    tx_bufs: [*]u8 = undefined,
    rx_next: u32 = 0,
    tx_next: u32 = 0,

    pub fn supports(device_id: u16) bool {
        return switch (device_id) {
            0x1004, 0x1008, 0x1009, 0x100C, 0x100D, 0x100E, 0x100F, 0x1010, 0x1011, 0x1012, 0x1013, 0x1015, 0x1016, 0x1017, 0x1018, 0x1019, 0x101A, 0x101D, 0x101E, 0x1026, 0x1027, 0x1028, 0x1075, 0x1076, 0x1077, 0x1078, 0x1079, 0x107A, 0x107B, 0x107C, 0x108A, 0x1099, 0x10B5, 0x10D3 => true,
            else => false,
        };
    }

    fn read(self: *const E1000, reg: usize) u32 {
        const p: *const volatile u32 = @ptrFromInt(self.base + reg);
        return switch (builtin.cpu.arch) {
            // 32 bits wide whatever is tested of it (see arch/mmio.zig)
            .x86_64 => asm volatile ("movl (%[p]), %[r]"
                : [r] "=r" (-> u32),
                : [p] "r" (p),
                : "memory"
            ),
            .x86 => asm volatile ("movl (%[p]), %[r]"
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

    fn write(self: *const E1000, reg: usize, value: u32) void {
        @as(*volatile u32, @ptrFromInt(self.base + reg)).* = value;
    }

    // Reset, rings, receiving and sending on;
    // interrupts still masked. mem: `pages` pages
    // for rings and buffers.
    pub fn init(self: *E1000, mem: [*]align(4096) u8, delay_us: *const fn (u32) void) error{ResetFailed}!void {
        self.write(IMC, 0xFFFF_FFFF);
        self.write(CTRL, self.read(CTRL) | ctrl_rst);
        delay_us(1000);
        var waited: u32 = 0;
        while (self.read(CTRL) & ctrl_rst != 0) : (waited += 1) {
            if (waited == 100) return error.ResetFailed;
            delay_us(1000);
        }
        self.write(IMC, 0xFFFF_FFFF);
        _ = self.read(ICR);
        // Link up, with the speed the PHY negotiates;
        // no reset bits left set
        var ctrl = self.read(CTRL) | ctrl_slu | ctrl_asde;
        ctrl &= ~@as(u32, (1 << 3) | (1 << 7) | (1 << 30) | (1 << 31));
        self.write(CTRL, ctrl);
        self.readMac(delay_us);
        for (0..128) |i| self.write(MTA + i * 4, 0);

        self.rx = @ptrCast(@alignCast(mem));
        self.tx = @ptrCast(@alignCast(mem + 4096));
        self.rx_bufs = mem + 2 * 4096;
        self.tx_bufs = self.rx_bufs + rx_count * buf_size;

        for (0..rx_count) |i| {
            self.rx[i] = .{ .addr = @intFromPtr(self.rx_bufs + i * buf_size), .length = 0, .checksum = 0, .status = 0, .errors = 0, .special = 0 };
        }
        const rx_addr: u64 = @intFromPtr(self.rx);
        self.write(RDBAL, @truncate(rx_addr));
        self.write(RDBAH, @truncate(rx_addr >> 32));
        self.write(RDLEN, rx_count * @sizeOf(RxDesc));
        self.write(RDH, 0);
        self.write(RDT, rx_count - 1);
        self.rx_next = 0;
        self.write(RCTL, rctl_en | rctl_bam | rctl_secrc); // 2048-byte buffers (BSIZE 0)

        for (0..tx_count) |i| {
            self.tx[i] = .{ .addr = @intFromPtr(self.tx_bufs + i * buf_size), .length = 0, .cso = 0, .cmd = 0, .status = desc_dd, .css = 0, .special = 0 };
        }
        const tx_addr: u64 = @intFromPtr(self.tx);
        self.write(TDBAL, @truncate(tx_addr));
        self.write(TDBAH, @truncate(tx_addr >> 32));
        self.write(TDLEN, tx_count * @sizeOf(TxDesc));
        self.write(TDH, 0);
        self.write(TDT, 0);
        self.tx_next = 0;
        self.write(TIPG, 10 | (8 << 10) | (6 << 20));
        self.write(TCTL, tctl_en | tctl_psp | (0x10 << 4) | (0x40 << 12));
    }

    // The address the card loaded from its
    // EEPROM into RAL0/RAH0, else read there
    fn readMac(self: *E1000, delay_us: *const fn (u32) void) void {
        const lo = self.read(RAL0);
        const hi = self.read(RAH0);
        if (hi & (1 << 31) != 0 and (lo != 0 or hi & 0xFFFF != 0)) {
            self.mac = .{ @truncate(lo), @truncate(lo >> 8), @truncate(lo >> 16), @truncate(lo >> 24), @truncate(hi), @truncate(hi >> 8) };
            return;
        }
        for (0..3) |w| {
            const word = self.eepromWord(@intCast(w), delay_us);
            self.mac[w * 2] = @truncate(word);
            self.mac[w * 2 + 1] = @truncate(word >> 8);
        }
        const l = @as(u32, self.mac[0]) | @as(u32, self.mac[1]) << 8 | @as(u32, self.mac[2]) << 16 | @as(u32, self.mac[3]) << 24;
        self.write(RAL0, l);
        self.write(RAH0, @as(u32, self.mac[4]) | @as(u32, self.mac[5]) << 8 | (1 << 31));
    }

    fn eepromWord(self: *const E1000, addr: u8, delay_us: *const fn (u32) void) u16 {
        // 82574: address at bit 2, done bit 1; the 8254x:
        // bit 8, done bit 4
        const shift: u5 = if (self.is_82574) 2 else 8;
        const done: u32 = if (self.is_82574) 1 << 1 else 1 << 4;
        self.write(EERD, 1 | (@as(u32, addr) << shift));
        for (0..1000) |_| {
            const v = self.read(EERD);
            if (v & done != 0) return @truncate(v >> 16);
            delay_us(10);
        }
        return 0;
    }

    pub fn enableInterrupts(self: *const E1000) void {
        // 82574 with MSI-X: every cause to vector 0
        if (self.is_82574) self.write(IVAR, (1 << 3) | (1 << 11) | (1 << 19) | (1 << 31));
        self.write(IMS, int_causes | if (self.is_82574) msix_causes else 0);
    }

    // From the interrupt: reading ICR acknowledges it
    pub fn acknowledge(self: *const E1000) void {
        _ = self.read(ICR);
    }

    // A shared wired line's: whether the card raised it
    pub fn takeCauses(self: *const E1000) bool {
        return self.read(ICR) != 0;
    }

    // Every frame on the wire, not only
    // its own address's (a bridge's port)
    pub fn promiscuous(self: *const E1000) void {
        self.write(RCTL, self.read(RCTL) | rctl_upe | rctl_mpe);
    }

    pub fn linkUp(self: *const E1000) bool {
        return self.read(STATUS) & status_lu != 0;
    }

    pub fn send(self: *E1000, frame: []const u8) bool {
        if (frame.len > buf_size or frame.len == 0) return false;
        const i = self.tx_next;
        const d = &self.tx[i];
        if (d.status & desc_dd == 0) return false; // the ring is full
        @memcpy((self.tx_bufs + i * buf_size)[0..frame.len], frame);
        d.length = @intCast(frame.len);
        d.cmd = tx_cmd;
        d.status = 0;
        self.tx_next = (i + 1) % tx_count;
        asm volatile ("" ::: "memory");
        self.write(TDT, self.tx_next);
        return true;
    }

    // One received frame into buf (its length), null if none waits
    // Bad frames are skipped, at most a ring's worth per call (a
    // card reporting errors without end can't keep the caller here)
    pub fn receive(self: *E1000, buf: []u8) ?usize {
        var skipped: usize = 0;
        while (skipped < rx_count) : (skipped += 1) {
            const i = self.rx_next;
            const d = &self.rx[i];
            const status = d.status;
            if (status & desc_dd == 0) return null;
            const len: usize = d.length;
            const good = status & rx_eop != 0 and d.errors == 0 and len <= buf.len;
            if (good) @memcpy(buf[0..len], (self.rx_bufs + i * buf_size)[0..len]);
            d.status = 0;
            self.rx_next = (i + 1) % rx_count;
            asm volatile ("" ::: "memory");
            self.write(RDT, i); // the descriptor goes back to the card
            if (good) return len; // a frame spanning buffers, or a bad one, is dropped
        }
        return null;
    }
};
