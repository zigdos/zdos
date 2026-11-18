// SB16.SYS: Sound Blaster 16 (ISA, BIOS edition, a probe driver)
// at 0x220 or 0x240: 16-bit stereo by the card's 16-bit DMA
// channel (5-7, as its mixer says) in auto-init mode from a 64 KiB
// ring below 16 MiB, 5000-44100 Hz. What played is silenced again.
// No interrupts: the card's is acknowledged when ZDOS asks; the
// clock counts the laps the DMA counter can't show.
const std = @import("std");
const builtin = @import("builtin");
const drv = @import("drv");

export const zdos_driver_ids = [_]drv.PciId{
    .{ .vendor = drv.probe_vendor, .device = 0 },
    .{ .vendor = 0, .device = 0 },
};

var api: *const drv.Api = undefined;
var base: u16 = 0x220;

fn in8(port: u16) u8 {
    return switch (builtin.cpu.arch) {
        .x86, .x86_64 => asm volatile ("inb %[p], %[r]"
            : [r] "={al}" (-> u8),
            : [p] "{dx}" (port),
        ),
        else => 0,
    };
}
fn out8(port: u16, v: u8) void {
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => asm volatile ("outb %[v], %[p]"
            :
            : [v] "{al}" (v),
              [p] "{dx}" (port),
        ),
        else => {},
    }
}

// DSP ports, from base:
const MIXER_ADDR = 0x4;
const MIXER_DATA = 0x5;
const RESET = 0x6;
const READ = 0xA;
const WRITE = 0xC; // bit 7 set: busy
const READ_STATUS = 0xE; // bit 7 set: data waiting
const ACK16 = 0xF; // reading acknowledges a 16-bit interrupt

// The second DMA controller (16-bit channels 4-7):
const DMA_MASK = 0xD4;
const DMA_MODE = 0xD6;
const DMA_FLIPFLOP = 0xD8;

// Channels 5, 6, 7: address, count, page ports:
const Channel = struct { n: u8, addr: u16, count: u16, page: u16 };
const channels = [_]Channel{
    .{ .n = 5, .addr = 0xC4, .count = 0xC6, .page = 0x8B },
    .{ .n = 6, .addr = 0xC8, .count = 0xCA, .page = 0x89 },
    .{ .n = 7, .addr = 0xCC, .count = 0xCE, .page = 0x8A },
};
var dma: Channel = channels[0];

const buffer_size = 64 * 1024;
const words = buffer_size / 2;
const margin = 1024;

var buffer: [*]u8 = undefined;
var running = false;
var last_pos: u32 = 0;
var written: u64 = 0;
var played: u64 = 0;
var bytes_per_s: u64 = 0;
var last_ms: u64 = 0;

fn dspWrite(v: u8) bool {
    const until = api.millis() + 10;
    while (in8(base + WRITE) & 0x80 != 0) {
        if (api.millis() > until) return false;
    }
    out8(base + WRITE, v);
    return true;
}

fn dspWriteAll(bytes: []const u8) bool {
    for (bytes) |b| {
        if (!dspWrite(b)) return false;
    }
    return true;
}

fn dspRead() ?u8 {
    const until = api.millis() + 10;
    while (in8(base + READ_STATUS) & 0x80 == 0) {
        if (api.millis() > until) return null;
    }
    return in8(base + READ);
}

// 1, 3 us, 0, then 0xAA to read.
fn dspReset() bool {
    out8(base + RESET, 1);
    api.delay_us(10);
    out8(base + RESET, 0);
    return dspRead() == 0xAA;
}

fn mixer(reg: u8, v: u8) void {
    out8(base + MIXER_ADDR, reg);
    out8(base + MIXER_DATA, v);
}

fn mixerRead(reg: u8) u8 {
    out8(base + MIXER_ADDR, reg);
    return in8(base + MIXER_DATA);
}

// Register 0x81: bits 5-7 the 16-bit channels 5-7; none set: 5
// chosen (an older card's jumpers may not take it):
fn findChannel() ?Channel {
    var sel = mixerRead(0x81);
    if (sel & 0xE0 == 0) {
        mixer(0x81, (sel & 0x0F) | 0x20);
        sel = mixerRead(0x81);
    }
    for (channels, 0..) |c, i| {
        if (sel & (@as(u8, 0x20) << @intCast(i)) != 0) return c;
    }
    return null;
}

// Auto-init, memory to card, the whole buffer. Addresses and counts
// in 16-bit words; the page register holds bits 23:17.
fn setupDma() void {
    const phys: u32 = @truncate(@intFromPtr(buffer));
    const sel = dma.n - 4;
    out8(DMA_MASK, 4 | sel); // masked
    out8(DMA_FLIPFLOP, 0);
    out8(DMA_MODE, 0x58 | sel); // single, auto-init, read
    const addr: u16 = @truncate(phys >> 1);
    out8(dma.addr, @truncate(addr));
    out8(dma.addr, @truncate(addr >> 8));
    out8(dma.page, @truncate((phys >> 16) & 0xFE));
    out8(DMA_FLIPFLOP, 0);
    out8(dma.count, @truncate(words - 1));
    out8(dma.count, @truncate((words - 1) >> 8));
    out8(DMA_MASK, sel); // on
}

fn start(_: ?*anyopaque, rate: u32) callconv(drv.cc) bool {
    if (rate < 5000 or rate > 44100) return false;
    stop(null);
    @memset(buffer[0..buffer_size], 0);
    setupDma();
    const ok = dspWriteAll(&.{
        0x41, @truncate(rate >> 8), @truncate(rate), // output rate
        0xB6, 0x30, // 16-bit output, auto-init, FIFO on; stereo, signed
        @truncate(words - 1), @truncate((words - 1) >> 8), // block: the ring
        0xD1, // speaker on
    });
    if (!ok) {
        out8(DMA_MASK, 4 | (dma.n - 4));
        return false;
    }
    last_pos = 0;
    written = 0;
    played = 0;
    bytes_per_s = @as(u64, rate) * 4;
    last_ms = api.millis();
    running = true;
    return true;
}

// Read twice in case it moves between bytes.
fn dmaLeft() u32 {
    var prev: u32 = 0xFFFF_FFFF;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        out8(DMA_FLIPFLOP, 0);
        const lo: u32 = in8(dma.count);
        const hi: u32 = in8(dma.count);
        const v = (hi << 8 | lo) +% 1 & 0xFFFF; // words - 1; 0xFFFF after the end
        if (v == prev) return v;
        prev = v;
    }
    return prev;
}

fn update() void {
    if (!running) return;
    _ = in8(base + ACK16);
    const left = @min(dmaLeft(), words);
    const pos: u32 = ((words - left) % words) * 2;
    const delta = (pos + buffer_size - last_pos) % buffer_size;
    // Whole rings since the last look (a long BIOS call), counted
    // by the clock (all of it played):
    const now = api.millis();
    const expected = (now -| last_ms) * bytes_per_s / 1000;
    const laps = if (expected > delta) (expected - delta + buffer_size / 2) / buffer_size else 0;
    last_ms = now;
    if (laps > 0) {
        @memset(buffer[0..buffer_size], 0);
    } else if (pos >= last_pos) {
        @memset(buffer[last_pos..pos], 0);
    } else {
        @memset(buffer[last_pos..buffer_size], 0);
        @memset(buffer[0..pos], 0);
    }
    last_pos = pos;
    played += delta + laps * buffer_size;
}

fn write(_: ?*anyopaque, data: [*]const u8, len: usize) callconv(drv.cc) usize {
    if (!running) return 0;
    update();
    if (written < played + margin) written = played + margin; // ran dry: ahead of the DMA
    const room = (buffer_size - margin) -| @as(usize, @intCast(written - played));
    const n = @min(len, room) & ~@as(usize, 3);
    var at: usize = @intCast(written % buffer_size);
    var from: usize = 0;
    while (from < n) {
        const part = @min(n - from, buffer_size - at);
        @memcpy(buffer[at..][0..part], data[from..][0..part]);
        from += part;
        at = (at + part) % buffer_size;
    }
    written += n;
    return n;
}

fn queued(_: ?*anyopaque) callconv(drv.cc) usize {
    update();
    return if (written > played) @intCast(written - played) else 0;
}

fn stop(_: ?*anyopaque) callconv(drv.cc) void {
    if (running) {
        _ = dspWrite(0xD5); // 16-bit DMA paused
        _ = dspWrite(0xD9); // auto-init ends
        out8(DMA_MASK, 4 | (dma.n - 4));
        _ = in8(base + ACK16);
        running = false;
    }
    @memset(buffer[0..buffer_size], 0);
}

// Bits 7:3.
fn setVolume(_: ?*anyopaque, percent: u32) callconv(drv.cc) void {
    const v: u8 = @intCast(@min(percent, 100) * 31 / 100 << 3);
    mixer(0x30, v);
    mixer(0x31, v);
}

var card: drv.SoundCard = .{
    .name_len = 0,
    .name = @splat(0),
    .start = start,
    .write = write,
    .queued = queued,
    .stop = stop,
    .set_volume = setVolume,
};

export fn zdos_driver_init(a: *const drv.Api, dev: *const drv.Device) callconv(drv.cc) bool {
    api = a;
    if (builtin.cpu.arch != .x86 and builtin.cpu.arch != .x86_64) return false;
    if (dev.vendor != drv.probe_vendor) return false;
    const found = for ([_]u16{ 0x220, 0x240 }) |b| {
        base = b;
        if (dspReset()) break true;
    } else false;
    if (!found) return false;
    if (!dspWrite(0xE1)) return false; // version: an SB16 is 4.x
    const major = dspRead() orelse 0;
    _ = dspRead();
    if (major < 4) return false;
    dma = findChannel() orelse return false;
    buffer = api.alloc_isa_dma(buffer_size / 4096) orelse return false;
    mixer(0x32, 0xF8); // voice (PCM) at its loudest; the master sets the volume
    mixer(0x33, 0xF8);
    const name = std.fmt.bufPrint(&card.name, "Sound Blaster 16 at {X}", .{base}) catch "Sound Blaster 16";
    card.name_len = @intCast(name.len);
    var line: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "SB16: DSP {d} at port {X}, DMA {d}\n", .{ major, base, dma.n }) catch "SB16\n";
    api.log(text.ptr, text.len);
    return api.register_sound(&card);
}
