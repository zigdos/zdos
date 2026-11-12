// ATA disks on the legacy IDE ports (0x1F0 / 0x170, IRQ 14 /
// 15), LBA28/48, 512-byte sectors: bus-master DMA where
// controller and drive have it, else PIO with READ / WRITE
// MULTIPLE. Every wait is bounded; once the IRQ is handled, a
// waiter sleeps on it.
// ATAPI and SATA-signature devices are left alone.
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform.zig");
const port = @import("../arch/x86_port.zig");

pub const sector_size = 512;

const Channel = struct {
    base: u16,
    ctrl: u16,
    irq: u8,
    ev: platform.IoEvent = .{},
    interrupts: bool = false, // its IRQ reaches handle(): nIEN off, waits sleep
    // Bus-master DMA: its registers (0: none), the descriptor table
    // and a buffer of a command's size, below 4 GiB:
    bm: u16 = 0,
    prd: ?*[4]u32 = null,
    buf: ?[*]align(4096) u8 = null,
};

pub var channels = [2]Channel{
    .{ .base = 0x1F0, .ctrl = 0x3F6, .irq = 14 },
    .{ .base = 0x170, .ctrl = 0x376, .irq = 15 },
};

pub const Drive = struct {
    channel: u1,
    slave: bool,
    sectors: u64,
    lba48: bool,
    multiple: u8 = 1, // sectors per PIO block (SET MULTIPLE MODE)
    dma: bool = false, // DMA on this drive (the drive and the channel have it)
    dma_capable: bool = false, // the drive says it does DMA (IDENTIFY word 49)
};

// From the channel's base:
const reg_data = 0;
const reg_error = 1;
const reg_count = 2;
const reg_lba0 = 3;
const reg_lba1 = 4;
const reg_lba2 = 5;
const reg_select = 6;
const reg_status = 7; // reading it acknowledges the IRQ
const reg_command = 7;

const st_err = 0x01;
const st_drq = 0x08;
const st_df = 0x20;
const st_bsy = 0x80;

pub const Error = error{ DeviceError, Timeout };

// Set by the OS before probe.
pub var delayUs: *const fn (us: u32) void = &noDelay;

fn noDelay(_: u32) void {}

fn altStatus(c: *const Channel) u8 {
    return port.inb(c.ctrl);
}

// The 400 ns after selection: four
// reads of the alternate status.
fn settle(c: *const Channel) void {
    for (0..4) |_| _ = altStatus(c);
}

// Until BSY clears (with want_drq also DRQ or an error),
// up to ms; sleeping on the IRQ where it is handled.
fn waitStatus(c: *Channel, want_drq: bool, ms: u32) Error!u8 {
    var left_us: u64 = @as(u64, ms) * 1000;
    while (true) {
        const s = altStatus(c);
        if (s == 0xFF) return error.DeviceError; // nothing there (floating bus)
        if (s & st_bsy == 0) {
            if (s & (st_err | st_df) != 0) return error.DeviceError;
            if (!want_drq or s & st_drq != 0) return s;
        }
        if (left_us == 0) return error.Timeout;
        if (c.interrupts and platform.io.wait != null) {
            left_us -|= platform.io.waitFor(&c.ev, delayUs);
        } else {
            delayUs(10);
            left_us -|= 10;
        }
    }
}

// From the IRQ handler (interrupts off).
pub fn handle(index: u1) void {
    const c = &channels[index];
    _ = port.inb(c.base + reg_status);
    platform.io.signal(&c.ev);
}

pub fn interruptsOn(index: u1) void {
    const c = &channels[index];
    c.interrupts = true;
    port.outb(c.ctrl, 0); // nIEN off
}

fn select(c: *Channel, slave: bool, lba_top: u8) void {
    port.outb(c.base + reg_select, 0xE0 | (@as(u8, @intFromBool(slave)) << 4) | (lba_top & 0x0F));
    settle(c);
}

// IDENTIFY DEVICE; null if no ATA disk.
pub fn probe(index: u1, slave: bool) ?Drive {
    const c = &channels[index];
    port.outb(c.ctrl, 0x02); // nIEN: no IRQ while probing
    if (altStatus(c) == 0xFF) return null; // no channel
    select(c, slave, 0);
    port.outb(c.base + reg_count, 0);
    port.outb(c.base + reg_lba0, 0);
    port.outb(c.base + reg_lba1, 0);
    port.outb(c.base + reg_lba2, 0);
    port.outb(c.base + reg_command, 0xEC);
    settle(c);
    if (altStatus(c) == 0) return null; // no drive
    // BSY clears; a non-ATA device
    // shows its signature in LBA 1 / 2:
    var spins: u32 = 0;
    while (altStatus(c) & st_bsy != 0) : (spins += 1) {
        if (spins > 100_000) return null;
        delayUs(10);
    }
    if (port.inb(c.base + reg_lba1) != 0 or port.inb(c.base + reg_lba2) != 0) return null; // ATAPI, SATA
    const s = waitStatus(c, true, 1000) catch return null;
    if (s & st_drq == 0) return null;
    var id: [256]u16 = undefined;
    readWords(c, &id);
    if (id[49] & (1 << 9) == 0) return null; // no LBA
    const lba48 = id[83] & (1 << 10) != 0;
    const sectors: u64 = if (lba48)
        @as(u64, id[100]) | @as(u64, id[101]) << 16 | @as(u64, id[102]) << 32 | @as(u64, id[103]) << 48
    else
        @as(u64, id[60]) | @as(u64, id[61]) << 16;
    if (sectors == 0) return null;
    var d: Drive = .{ .channel = index, .slave = slave, .sectors = sectors, .lba48 = lba48, .dma_capable = id[49] & (1 << 8) != 0 };
    // The most sectors per interrupt the drive allows (word 47):
    const most: u8 = @truncate(id[47]);
    if (most >= 2) {
        const want: u8 = @min(most, 16);
        select(c, slave, 0);
        port.outb(c.base + reg_count, want);
        port.outb(c.base + reg_command, 0xC6); // SET MULTIPLE MODE
        settle(c);
        if (waitStatus(c, false, 1000)) |_| d.multiple = want else |_| {}
    }
    return d;
}

// Under a hypervisor each inw / outw is a trip out of the
// guest, rep insw / outsw one for many.
fn readWords(c: *const Channel, out: *[256]u16) void {
    const data = c.base + reg_data;
    switch (builtin.cpu.arch) {
        .x86 => asm volatile ("movl %[p], %%edi; movl $256, %%ecx; cld; rep insw"
            :
            : [d] "{dx}" (data),
              [p] "r" (out),
            : "edi", "ecx", "memory", "cc"
        ),
        .x86_64 => asm volatile ("movq %[p], %%rdi; movl $256, %%ecx; cld; rep insw"
            :
            : [d] "{dx}" (data),
              [p] "r" (out),
            : "rdi", "rcx", "memory", "cc"
        ),
        else => for (out) |*w| {
            w.* = port.inw(data);
        },
    }
}

fn writeWords(c: *const Channel, in: *const [256]u16) void {
    const data = c.base + reg_data;
    switch (builtin.cpu.arch) {
        .x86 => asm volatile ("movl %[p], %%esi; movl $256, %%ecx; cld; rep outsw"
            :
            : [d] "{dx}" (data),
              [p] "r" (in),
            : "esi", "ecx", "memory", "cc"
        ),
        .x86_64 => asm volatile ("movq %[p], %%rsi; movl $256, %%ecx; cld; rep outsw"
            :
            : [d] "{dx}" (data),
              [p] "r" (in),
            : "rsi", "rcx", "memory", "cc"
        ),
        else => for (in) |w| port.outw(data, w),
    }
}

// count 0 means 256 / 65536.
fn issue(c: *Channel, d: *const Drive, lba: u64, count: u16, cmd28: u8, cmd48: u8) Error!void {
    _ = try waitStatus(c, false, 5000);
    // nIEN as ZDOS wants it (a BIOS call may have set it):
    port.outb(c.ctrl, if (c.interrupts) 0 else 0x02);
    if (d.lba48) {
        select(c, d.slave, 0);
        port.outb(c.base + reg_count, @truncate(count >> 8));
        port.outb(c.base + reg_lba0, @truncate(lba >> 24));
        port.outb(c.base + reg_lba1, @truncate(lba >> 32));
        port.outb(c.base + reg_lba2, @truncate(lba >> 40));
        port.outb(c.base + reg_count, @truncate(count));
        port.outb(c.base + reg_lba0, @truncate(lba));
        port.outb(c.base + reg_lba1, @truncate(lba >> 8));
        port.outb(c.base + reg_lba2, @truncate(lba >> 16));
        port.outb(c.base + reg_command, cmd48);
    } else {
        select(c, d.slave, @truncate(lba >> 24));
        port.outb(c.base + reg_count, @truncate(count));
        port.outb(c.base + reg_lba0, @truncate(lba));
        port.outb(c.base + reg_lba1, @truncate(lba >> 8));
        port.outb(c.base + reg_lba2, @truncate(lba >> 16));
        port.outb(c.base + reg_command, cmd28);
    }
    settle(c);
}

// 128 sectors (64 KiB): LBA28 counts take 256 at most.
const chunk = 128;
const chunk_bytes = chunk * sector_size;

pub fn read(d: *Drive, lba: u64, count: usize, buf: []u8) Error!void {
    if (count * sector_size > buf.len or lba + count > d.sectors) return error.DeviceError;
    if (!d.lba48 and lba + count > 1 << 28) return error.DeviceError;
    const c = &channels[d.channel];
    var done: usize = 0;
    while (done < count) {
        const n: usize = @min(chunk, count - done);
        const part = buf[done * sector_size ..][0 .. n * sector_size];
        if (d.dma) {
            if (dmaTransfer(c, d, lba + done, n, false)) {
                @memcpy(part, c.buf.?[0..part.len]);
                done += n;
                continue;
            } else |err| dmaFailed(d, err); // PIO from now on, and this chunk again
        }
        try pioRead(c, d, lba + done, n, part);
        done += n;
    }
}

pub fn write(d: *Drive, lba: u64, count: usize, data: []const u8) Error!void {
    if (count * sector_size > data.len or lba + count > d.sectors) return error.DeviceError;
    if (!d.lba48 and lba + count > 1 << 28) return error.DeviceError;
    const c = &channels[d.channel];
    var done: usize = 0;
    while (done < count) {
        const n: usize = @min(chunk, count - done);
        const part = data[done * sector_size ..][0 .. n * sector_size];
        if (d.dma) {
            @memcpy(c.buf.?[0..part.len], part);
            if (dmaTransfer(c, d, lba + done, n, true)) {
                done += n;
                continue;
            } else |err| dmaFailed(d, err);
        }
        try pioWrite(c, d, lba + done, n, part);
        done += n;
    }
    // The drive's write cache to the medium:
    _ = try waitStatus(c, false, 5000);
    select(c, d.slave, 0);
    port.outb(c.base + reg_command, if (d.lba48) 0xEA else 0xE7);
    settle(c);
    _ = try waitStatus(c, false, 30_000);
}

// A block of `multiple` sectors per DRQ, one interrupt each.
fn pioRead(c: *Channel, d: *const Drive, lba: u64, n: usize, buf: []u8) Error!void {
    const m = @max(d.multiple, 1);
    try issue(c, d, lba, @intCast(n), if (m > 1) 0xC4 else 0x20, if (m > 1) 0x29 else 0x24);
    var i: usize = 0;
    while (i < n) {
        _ = try waitStatus(c, true, 5000);
        const block: usize = @min(m, n - i);
        for (0..block) |k| {
            var words: [256]u16 = undefined; // the caller's buffer may be odd-aligned
            readWords(c, &words);
            @memcpy(buf[(i + k) * sector_size ..][0..sector_size], std.mem.asBytes(&words));
        }
        i += block;
    }
}

fn pioWrite(c: *Channel, d: *const Drive, lba: u64, n: usize, data: []const u8) Error!void {
    const m = @max(d.multiple, 1);
    try issue(c, d, lba, @intCast(n), if (m > 1) 0xC5 else 0x30, if (m > 1) 0x39 else 0x34);
    var i: usize = 0;
    while (i < n) {
        _ = try waitStatus(c, true, 5000);
        const block: usize = @min(m, n - i);
        for (0..block) |k| {
            var words: [256]u16 = undefined;
            @memcpy(std.mem.asBytes(&words), data[(i + k) * sector_size ..][0..sector_size]);
            writeWords(c, &words);
        }
        i += block;
    }
    _ = try waitStatus(c, false, 5000);
}

// BUS-MASTER DMA (THE PCI IDE CONTROLLER'S BAR 4)

const bm_command = 0; // bit 0 start, bit 3 to memory (a read)
const bm_status = 2; // bit 0 active, 1 error, 2 interrupt (both written 1 to clear)
const bm_prd = 4;

// The controller's bus-master registers
// (I/O BAR 4), for both channels.
pub fn useDma(bm_base: u16) void {
    for (&channels, 0..) |*c, i| {
        const prd_page = platform.memory.allocPages(1, false) orelse return;
        const buf = platform.memory.allocPages(chunk_bytes / 4096, false) orelse return;
        // Physical addresses below 4 GiB (BIOS: no paging):
        if (@intFromPtr(prd_page) + 4096 > 1 << 32 or @intFromPtr(buf) + chunk_bytes > 1 << 32) return;
        c.prd = @ptrCast(@alignCast(prd_page));
        c.buf = buf;
        c.bm = bm_base + @as(u16, @intCast(i)) * 8;
    }
}

// Said once on the console.
fn dmaFailed(d: *Drive, err: Error) void {
    d.dma = false;
    var buf: [80]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "IDE {d}{s}: DMA failed ({s}), PIO from now on\n", .{ d.channel, if (d.slave) "s" else "m", @errorName(err) }) catch return;
    if (@hasDecl(platform.console, "write")) platform.console.write(text);
}

pub fn enableDma(d: *Drive) void {
    d.dma = d.dma_capable and channels[d.channel].bm != 0;
}

// One interrupt at the end.
fn dmaTransfer(c: *Channel, d: *const Drive, lba: u64, n: usize, to_disk: bool) Error!void {
    const bytes = n * sector_size;
    const addr: u32 = @intCast(@intFromPtr(c.buf.?));
    // Descriptors may not cross a 64 KiB boundary: split there:
    const first = @min(bytes, 0x1_0000 - (addr & 0xFFFF));
    const prd = c.prd.?;
    if (first == bytes) {
        prd[0] = addr;
        prd[1] = @as(u32, @intCast(bytes & 0xFFFF)) | 0x8000_0000; // 0 means 64 KiB
    } else {
        prd[0] = addr;
        prd[1] = @intCast(first & 0xFFFF);
        prd[2] = addr + @as(u32, @intCast(first));
        prd[3] = @as(u32, @intCast((bytes - first) & 0xFFFF)) | 0x8000_0000;
    }
    asm volatile ("" ::: "memory");
    port.outb(c.bm + bm_command, 0);
    port.outl(c.bm + bm_prd, @intCast(@intFromPtr(prd)));
    port.outb(c.bm + bm_status, port.inb(c.bm + bm_status) | 0x06);
    try issue(c, d, lba, @intCast(n), if (to_disk) 0xCA else 0xC8, if (to_disk) 0x35 else 0x25);
    port.outb(c.bm + bm_command, if (to_disk) 0x01 else 0x09);
    // Until the controller is no longer active (or its
    // interrupt bit, or an error), bounded. The interrupt bit
    // alone isn't enough: with nIEN (polling before tasks
    // run) it never comes:
    var left_us: u64 = 2_000_000;
    while (true) {
        const bs = port.inb(c.bm + bm_status);
        if (bs & 0x02 != 0) break;
        if ((bs & 0x04 != 0 or bs & 0x01 == 0) and altStatus(c) & st_bsy == 0) break;
        if (left_us == 0) break;
        if (c.interrupts and platform.io.wait != null) {
            left_us -|= platform.io.waitFor(&c.ev, delayUs);
        } else {
            delayUs(10);
            left_us -|= 10;
        }
    }
    port.outb(c.bm + bm_command, 0);
    const bs = port.inb(c.bm + bm_status);
    port.outb(c.bm + bm_status, bs | 0x06);
    const st = altStatus(c);
    if (bs & 0x02 != 0 or st & (st_err | st_df | st_bsy) != 0) return error.DeviceError;
    if (bs & 0x01 != 0 and bs & 0x04 == 0) return error.Timeout; // it never finished
}
