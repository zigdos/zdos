// SB16.SYS: Sound Blaster 16 (ISA, BIOS edition, a probe driver)
// at 0x220 or 0x240: 16-bit stereo by DMA channel 5 in auto-init
// mode from a 32 KiB ring below 16 MiB, 5000-44100 Hz.
// What played is silenced again. No interrupts: the card's is
// acknowledged when ZDOS asks.
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

// The second DMA controller (16-bit channels 4-7): channel 5's:
const DMA_MASK = 0xD4;
const DMA_MODE = 0xD6;
const DMA_FLIPFLOP = 0xD8;
const DMA5_ADDR = 0xC4;
const DMA5_COUNT = 0xC6;
const DMA5_PAGE = 0x8B;

const buffer_size = 32 * 1024;
const words = buffer_size / 2;
const margin = 1024;

var buffer: [*]u8 = undefined;
var running = false;
var last_pos: u32 = 0;
var written: u64 = 0;
var played: u64 = 0;

fn dspWrite(v: u8) void {
    const until = api.millis() + 10;
    while (in8(base + WRITE) & 0x80 != 0 and api.millis() <= until) {}
    out8(base + WRITE, v);
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

// Auto-init, memory to card, the whole buffer. Addresses and counts
// in 16-bit words; the page register holds bits 23:17.
fn setupDma() void {
    const phys: u32 = @truncate(@intFromPtr(buffer));
    out8(DMA_MASK, 0x05); // channel 5 masked
    out8(DMA_FLIPFLOP, 0);
    out8(DMA_MODE, 0x59); // single, auto-init, read, channel 5
    const addr: u16 = @truncate(phys >> 1);
    out8(DMA5_ADDR, @truncate(addr));
    out8(DMA5_ADDR, @truncate(addr >> 8));
    out8(DMA5_PAGE, @truncate((phys >> 16) & 0xFE));
    out8(DMA_FLIPFLOP, 0);
    out8(DMA5_COUNT, @truncate(words - 1));
    out8(DMA5_COUNT, @truncate((words - 1) >> 8));
    out8(DMA_MASK, 0x01); // channel 5 on
}

fn start(_: ?*anyopaque, rate: u32) callconv(drv.cc) bool {
    if (rate < 5000 or rate > 44100) return false;
    stop(null);
    @memset(buffer[0..buffer_size], 0);
    setupDma();
    dspWrite(0x41); // output rate
    dspWrite(@truncate(rate >> 8));
    dspWrite(@truncate(rate));
    dspWrite(0xB6); // 16-bit output, auto-init, FIFO on
    dspWrite(0x30); // stereo, signed
    dspWrite(@truncate(words - 1)); // block (its interrupt): the whole ring
    dspWrite(@truncate((words - 1) >> 8));
    dspWrite(0xD1); // speaker on
    last_pos = 0;
    written = 0;
    played = 0;
    running = true;
    return true;
}

// Read twice in case it moves between bytes.
fn dmaLeft() u32 {
    var prev: u32 = 0xFFFF_FFFF;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        out8(DMA_FLIPFLOP, 0);
        const lo: u32 = in8(DMA5_COUNT);
        const hi: u32 = in8(DMA5_COUNT);
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
    if (pos >= last_pos) {
        @memset(buffer[last_pos..pos], 0);
    } else {
        @memset(buffer[last_pos..buffer_size], 0);
        @memset(buffer[0..pos], 0);
    }
    last_pos = pos;
    played += delta;
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
        dspWrite(0xD5); // 16-bit DMA paused
        dspWrite(0xD9); // auto-init ends
        out8(DMA_MASK, 0x05);
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
    dspWrite(0xE1); // version: an SB16 is 4.x
    const major = dspRead() orelse 0;
    _ = dspRead();
    if (major < 4) return false;
    buffer = api.alloc_isa_dma(buffer_size / 4096) orelse return false;
    mixer(0x32, 0xF8); // voice (PCM) at its loudest; the master sets the volume
    mixer(0x33, 0xF8);
    const name = std.fmt.bufPrint(&card.name, "Sound Blaster 16 at {X}", .{base}) catch "Sound Blaster 16";
    card.name_len = @intCast(name.len);
    var line: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "SB16: DSP {d} at port {X}\n", .{ major, base }) catch "SB16\n";
    api.log(text.ptr, text.len);
    return api.register_sound(&card);
}
