// RTL8139.SYS: Realtek RTL8129/8139 and clones, 10/100 Mbit/s. One
// 64 KiB receive ring without WRAP, as MINIX's and the BSDs' (a frame
// may split at its end), 4 transmit buffers in turn. I/O ports on x86,
// else memory (BAR1). Its wired interrupt where ZDOS routes one (BIOS
// edition), else polled.
const std = @import("std");
const builtin = @import("builtin");
const drv = @import("drv");

export const zdos_driver_ids = [_]drv.PciId{
    .{ .vendor = 0x10EC, .device = 0x8139 }, // RTL8139/8139C/8139C+ (QEMU's)
    .{ .vendor = 0x10EC, .device = 0x8138 }, // RTL8139 (CardBus)
    .{ .vendor = 0x10EC, .device = 0x8129 }, // RTL8129
    .{ .vendor = 0x1113, .device = 0x1211 }, // Accton MPX5030, SMC1211TX
    .{ .vendor = 0x1186, .device = 0x1300 }, // D-Link DFE-530TX+, DFE-538TX
    .{ .vendor = 0x1186, .device = 0x1340 }, // D-Link DFE-690TXD
    .{ .vendor = 0x13D1, .device = 0xAB06 }, // AboCom FE2000VX
    .{ .vendor = 0x1259, .device = 0xA117 }, // Allied Telesyn AT-2500TX
    .{ .vendor = 0x1259, .device = 0xA11E }, // Allied Telesyn AT-2500TX
    .{ .vendor = 0x14EA, .device = 0xAB06 }, // Planex FNW-3603-TX
    .{ .vendor = 0x14EA, .device = 0xAB07 }, // Planex FNW-3800-TX
    .{ .vendor = 0x4033, .device = 0x1360 }, // Addtron AEF-360TX
    .{ .vendor = 0x1432, .device = 0x9130 }, // Edimax EN-9130TX
    .{ .vendor = 0x02AC, .device = 0x1012 }, // SpeedStream SS1012
    .{ .vendor = 0x1500, .device = 0x1360 }, // Delta Electronics
    .{ .vendor = 0x1743, .device = 0x8139 }, // Peppercon ROL/F-100
    .{ .vendor = 0x021B, .device = 0x8139 }, // Compaq HNE-300
    .{ .vendor = 0x18A1, .device = 0x8139 }, // Hangzhou Silan
    .{ .vendor = 0x126C, .device = 0x1211 }, // Nortel
    .{ .vendor = 0x0357, .device = 0x000A }, // TTTech MC322
    .{ .vendor = 0, .device = 0 },
};

var api: *const drv.Api = undefined;
var io_base: u16 = 0; // ports, or
var mmio: usize = 0; // memory

// REGISTERS: ports or memory, explicit widths

fn rd(off: u16, comptime T: type) T {
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => if (mmio == 0) {
            const port = io_base + off;
            return switch (T) {
                u8 => asm volatile ("inb %[p], %[r]"
                    : [r] "={al}" (-> u8),
                    : [p] "{dx}" (port),
                ),
                u16 => asm volatile ("inw %[p], %[r]"
                    : [r] "={ax}" (-> u16),
                    : [p] "{dx}" (port),
                ),
                else => asm volatile ("inl %[p], %[r]"
                    : [r] "={eax}" (-> u32),
                    : [p] "{dx}" (port),
                ),
            };
        },
        else => {},
    }
    const a = mmio + off;
    const v: u32 = switch (builtin.cpu.arch) {
        .x86, .x86_64 => switch (T) {
            u8 => asm volatile ("movzbl (%[a]), %[r]"
                : [r] "=r" (-> u32),
                : [a] "r" (a),
                : "memory"
            ),
            u16 => asm volatile ("movzwl (%[a]), %[r]"
                : [r] "=r" (-> u32),
                : [a] "r" (a),
                : "memory"
            ),
            else => asm volatile ("movl (%[a]), %[r]"
                : [r] "=r" (-> u32),
                : [a] "r" (a),
                : "memory"
            ),
        },
        .aarch64 => switch (T) {
            u8 => asm volatile ("ldrb %[r:w], [%[a]]"
                : [r] "=r" (-> u32),
                : [a] "r" (a),
                : "memory"
            ),
            u16 => asm volatile ("ldrh %[r:w], [%[a]]"
                : [r] "=r" (-> u32),
                : [a] "r" (a),
                : "memory"
            ),
            else => asm volatile ("ldr %[r:w], [%[a]]"
                : [r] "=r" (-> u32),
                : [a] "r" (a),
                : "memory"
            ),
        },
        else => @compileError("RTL8139.SYS: x86 and ARM64 only"),
    };
    return @truncate(v);
}

fn wr(off: u16, comptime T: type, v: T) void {
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => if (mmio == 0) {
            const port = io_base + off;
            switch (T) {
                u8 => asm volatile ("outb %[v], %[p]"
                    :
                    : [v] "{al}" (v),
                      [p] "{dx}" (port),
                ),
                u16 => asm volatile ("outw %[v], %[p]"
                    :
                    : [v] "{ax}" (v),
                      [p] "{dx}" (port),
                ),
                else => asm volatile ("outl %[v], %[p]"
                    :
                    : [v] "{eax}" (v),
                      [p] "{dx}" (port),
                ),
            }
            return;
        },
        else => {},
    }
    const a = mmio + off;
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => switch (T) {
            u8 => asm volatile ("movb %[v], (%[a])"
                :
                : [v] "q" (v),
                  [a] "r" (a),
                : "memory"
            ),
            u16 => asm volatile ("movw %[v], (%[a])"
                :
                : [v] "r" (v),
                  [a] "r" (a),
                : "memory"
            ),
            else => asm volatile ("movl %[v], (%[a])"
                :
                : [v] "r" (v),
                  [a] "r" (a),
                : "memory"
            ),
        },
        .aarch64 => {
            const w: u32 = v;
            switch (T) {
                u8 => asm volatile ("dsb sy\n strb %[v:w], [%[a]]"
                    :
                    : [v] "r" (w),
                      [a] "r" (a),
                    : "memory"
                ),
                u16 => asm volatile ("dsb sy\n strh %[v:w], [%[a]]"
                    :
                    : [v] "r" (w),
                      [a] "r" (a),
                    : "memory"
                ),
                else => asm volatile ("dsb sy\n str %[v:w], [%[a]]"
                    :
                    : [v] "r" (w),
                      [a] "r" (a),
                    : "memory"
                ),
            }
        },
        else => @compileError("RTL8139.SYS: x86 and ARM64 only"),
    }
}

// Read what the card wrote by DMA only after the register that said so.
fn readBarrier() void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("dsb ld" ::: "memory"),
        else => asm volatile ("" ::: "memory"),
    }
}

const IDR0 = 0x00;
const MAR0 = 0x08;
const TSD0 = 0x10; // transmit status, 4 of them
const TSAD0 = 0x20; // transmit buffer addresses
const RBSTART = 0x30;
const CR = 0x37;
const CAPR = 0x38;
const IMR = 0x3C;
const ISR = 0x3E;
const TCR = 0x40;
const RCR = 0x44;
const CFG9346 = 0x50;
const CONFIG1 = 0x52;
const MSR = 0x58;

const cr_reset = 0x10;
const cr_rx = 0x08;
const cr_tx = 0x04;
const cr_rx_empty = 0x01;
const tsd_own = 1 << 13; // the card is done with the buffer
const tsd_ok = 1 << 15;
const tsd_abort = 1 << 30;
const msr_link_fail = 0x04;
const rx_ok = 0x0001;
// Interrupt causes: receive OK and error, ring overflow, link
// change, FIFO overflow (sends are checked when the next goes)
const int_causes: u16 = 0x0001 | 0x0002 | 0x0010 | 0x0020 | 0x0040;
const rx_unfinished = 0xFFF0;

const ring_size = 65536;
const ring_pages = 17; // the ring and the card's 16 bytes past it
const tx_count = 4;
const tx_size = 2048;
const max_frame = 1514;

var ring: [*]u8 = undefined;
var tx_bufs: [*]u8 = undefined;
var rx_at: u16 = 0;
var tx_next: u32 = 0;
var tx_busy = [_]bool{false} ** tx_count;

fn send(_: ?*anyopaque, frame: [*]const u8, len: usize) callconv(drv.cc) bool {
    if (len == 0 or len > max_frame) return false;
    const i = tx_next;
    const off: u16 = @intCast(TSD0 + i * 4);
    if (tx_busy[i]) {
        const st = rd(off, u32);
        if (st & tsd_own == 0) return false; // all 4 still going out
        if (st & tsd_abort != 0) wr(TCR, u32, rd(TCR, u32) | 1); // clear the abort
    }
    const buf = tx_bufs + i * tx_size;
    @memcpy(buf[0..len], frame[0..len]);
    const n = @max(len, 60); // the card doesn't pad short frames
    if (n > len) @memset(buf[len..n], 0);
    // Size and an early transmit threshold of 256; this clears OWN:
    wr(off, u32, @as(u32, @intCast(n)) | (8 << 16));
    tx_busy[i] = true;
    tx_next = (i + 1) % tx_count;
    return true;
}

fn receive(_: ?*anyopaque, buf: [*]u8, max: usize) callconv(drv.cc) isize {
    // Polled, the causes are cleared here (with interrupts, ack):
    if (!interrupts) {
        const isr = rd(ISR, u16);
        if (isr != 0) wr(ISR, u16, isr);
    }
    while (rd(CR, u8) & cr_rx_empty == 0) {
        readBarrier();
        const head = ring + rx_at;
        const status = std.mem.readInt(u16, head[0..2], .little);
        const size = std.mem.readInt(u16, head[2..4], .little); // with the CRC
        if (size == rx_unfinished) return -1; // the card is still copying it
        // Shorter than 64 is a runt (QEMU's socket network passes unpadded
        // ARPs): taken, not a broken ring:
        if (status & rx_ok == 0 or size < 14 + 4 or size > max_frame + 4) {
            restartReceive();
            return -1;
        }
        const len: usize = size - 4;
        const fits = len <= max;
        if (fits) {
            // In two parts when it wraps past the ring's end:
            const at = (@as(usize, rx_at) + 4) & (ring_size - 1);
            const first = @min(len, ring_size - at);
            @memcpy(buf[0..first], ring[at..][0..first]);
            @memcpy(buf[first..len], ring[0 .. len - first]);
        }
        rx_at = @intCast((@as(u32, rx_at) + size + 4 + 3) & ~@as(u32, 3) & (ring_size - 1));
        wr(CAPR, u16, rx_at -% 16); // CAPR trails the read position by 16
        if (fits) return @intCast(len);
    }
    return -1;
}

// After a bad header the ring can't be followed: the receiver anew.
fn restartReceive() void {
    wr(CR, u8, cr_tx);
    wr(RBSTART, u32, @truncate(@intFromPtr(ring)));
    rx_at = 0;
    wr(CR, u8, cr_rx | cr_tx);
    wr(RCR, u32, rcr | accept_all);
    wr(CAPR, u16, 0 -% @as(u16, 16));
}

fn linkUp(_: ?*anyopaque) callconv(drv.cc) bool {
    return rd(MSR, u8) & msr_link_fail == 0;
}

// Own address and broadcasts, unlimited DMA bursts, 64 KiB ring
// (RBLEN 11), no receive FIFO threshold.
const rcr: u32 = 0x02 | 0x08 | (7 << 8) | (3 << 11) | (7 << 13);
// Set by promiscuous (a bridge port): every address and multicast
var accept_all: u32 = 0;

var card: drv.NetCard = .{
    .mac = undefined,
    .name_len = 0,
    .name = @splat(0),
    .send = send,
    .receive = receive,
    .link_up = linkUp,
};

fn log(comptime fmt: []const u8, args: anytype) void {
    var line: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&line, fmt, args) catch return;
    api.log(text.ptr, text.len);
}

export fn zdos_driver_init(a: *const drv.Api, dev: *const drv.Device) callconv(drv.cc) bool {
    api = a;
    const is_x86 = builtin.cpu.arch == .x86 or builtin.cpu.arch == .x86_64;
    const bar0 = api.pci_read(dev, 0x10); // as it reads: bit 0 for ports
    if (is_x86 and bar0 & 1 != 0 and bar0 & 0xFFFC != 0) {
        io_base = @intCast(bar0 & 0xFFFC);
    } else {
        const bar = dev.bars[1];
        if (bar & 1 != 0 or bar == 0) return false;
        const phys = bar & ~@as(u64, 0xF);
        if (phys > std.math.maxInt(usize) or !api.map_device(phys, 0x100)) return false;
        mmio = @intCast(phys);
    }
    api.pci_enable(dev);

    wr(CFG9346, u8, 0xC0); // configuration writable
    wr(CONFIG1, u8, 0); // out of low power
    wr(CFG9346, u8, 0);
    wr(CR, u8, cr_reset);
    const until = api.millis() + 100;
    while (rd(CR, u8) & cr_reset != 0) {
        if (api.millis() > until) {
            log("RTL8139: no reset\n", .{});
            return false;
        }
        api.delay_us(100);
    }
    for (0..6) |i| card.mac[i] = rd(@intCast(IDR0 + i), u8);

    // The ring, then the transmit buffers; 32-bit addresses:
    const page_count = ring_pages + tx_count * tx_size / 4096;
    const pages = api.alloc_pages(page_count) orelse return false;
    if (@as(u64, @intFromPtr(pages)) + page_count * 4096 > 0xFFFF_FFFF) {
        api.free_pages(pages, page_count);
        log("RTL8139: no memory below 4 GiB\n", .{});
        return false;
    }
    ring = pages;
    tx_bufs = pages + ring_pages * 4096;

    wr(IMR, u16, 0); // polled
    wr(ISR, u16, 0xFFFF);
    wr(MAR0, u32, 0);
    wr(MAR0 + 4, u32, 0);
    wr(RBSTART, u32, @truncate(@intFromPtr(ring)));
    for (0..tx_count) |i| wr(@intCast(TSAD0 + i * 4), u32, @truncate(@intFromPtr(tx_bufs + i * tx_size)));
    wr(CR, u8, cr_rx | cr_tx);
    wr(RCR, u32, rcr);
    wr(TCR, u32, (3 << 24) | (6 << 8)); // standard gap, 1 KiB DMA bursts
    wr(CAPR, u16, 0 -% @as(u16, 16));

    const name = std.fmt.bufPrint(&card.name, "Realtek RTL8139 {X:0>4}:{X:0>4}", .{ dev.vendor, dev.device }) catch "Realtek RTL8139";
    card.name_len = @intCast(name.len);
    const m = card.mac;
    log("RTL8139: {X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}, {s}\n", .{ m[0], m[1], m[2], m[3], m[4], m[5], if (mmio != 0) "memory" else "ports" });
    if (!api.register_net(&card)) return false;
    // A ZDOS without net_interrupts polls:
    if (api.slots * @sizeOf(usize) >= @offsetOf(drv.Api, "net_interrupts")) _ = api.net_interrupts(&card, dev, &control);
    if (api.slots * @sizeOf(usize) >= @offsetOf(drv.Api, "net_promiscuous")) _ = api.net_promiscuous(&card, &promiscuous);
    return true;
}

// Every frame, as MINIX's NDEV_MODE_PROMISC: all addresses (AAP)
// and multicasts (AM, the hash table all ones)
fn promiscuous(_: ?*anyopaque) callconv(drv.cc) bool {
    accept_all = 0x01 | 0x04;
    wr(MAR0, u32, 0xFFFF_FFFF);
    wr(MAR0 + 4, u32, 0xFFFF_FFFF);
    wr(RCR, u32, rcr | accept_all);
    return true;
}

var interrupts = false;

fn control(_: ?*anyopaque, op: u32) callconv(drv.cc) bool {
    switch (op) {
        drv.NetIrq.enable => {
            interrupts = true;
            wr(IMR, u16, int_causes);
        },
        drv.NetIrq.rearm => wr(IMR, u16, int_causes),
        drv.NetIrq.disable => {
            interrupts = false;
            wr(IMR, u16, 0);
        },
        drv.NetIrq.ack => {
            const isr = rd(ISR, u16);
            // 0xFFFF: the card is gone; 0: another device's on the line:
            if (isr == 0 or isr == 0xFFFF) return false;
            wr(IMR, u16, 0);
            wr(ISR, u16, isr);
        },
        else => return false,
    }
    return true;
}
