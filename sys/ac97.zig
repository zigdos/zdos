// AC97.SYS: AC'97 on Intel ICH and compatibles, x86 only (I/O ports).
// 32 buffer entries of 4 KiB; the last valid index is kept one behind
// the current one, so it plays on, and what played is silenced again.
// 48000 Hz, other rates where the codec has variable rate audio.
const std = @import("std");
const builtin = @import("builtin");
const drv = @import("drv");

export const zdos_driver_ids = [_]drv.PciId{
    .{ .vendor = 0x8086, .device = 0x2415 }, // 82801AA (QEMU's)
    .{ .vendor = 0x8086, .device = 0x2425 }, // 82801AB
    .{ .vendor = 0x8086, .device = 0x2445 }, // 82801BA
    .{ .vendor = 0x8086, .device = 0x2485 }, // ICH3
    .{ .vendor = 0x8086, .device = 0x24C5 }, // ICH4
    .{ .vendor = 0x8086, .device = 0x24D5 }, // ICH5
    .{ .vendor = 0x8086, .device = 0x25A6 }, // 6300ESB
    .{ .vendor = 0x8086, .device = 0x266E }, // ICH6
    .{ .vendor = 0x8086, .device = 0x27DE }, // ICH7
    .{ .vendor = 0x8086, .device = 0x7195 }, // 440MX
    .{ .vendor = 0x10DE, .device = 0x01B1 }, // nForce
    .{ .vendor = 0x10DE, .device = 0x006A }, // nForce2
    .{ .vendor = 0x10DE, .device = 0x00DA }, // nForce3
    .{ .vendor = 0x10DE, .device = 0x00EA }, // nForce3 250
    .{ .vendor = 0x10DE, .device = 0x0059 }, // CK804
    .{ .vendor = 0x10DE, .device = 0x008A }, // MCP2S
    .{ .vendor = 0x1022, .device = 0x746D }, // AMD 8111
    .{ .vendor = 0x1022, .device = 0x7445 }, // AMD 768
    .{ .vendor = 0, .device = 0 },
};

const is_x86 = builtin.cpu.arch == .x86 or builtin.cpu.arch == .x86_64;

var api: *const drv.Api = undefined;
var nam: u16 = 0; // mixer ports
var nabm: u16 = 0; // bus master ports

fn in8(port: u16) u8 {
    return switch (builtin.cpu.arch) {
        .x86, .x86_64 => asm volatile ("inb %[p], %[r]"
            : [r] "={al}" (-> u8),
            : [p] "{dx}" (port),
        ),
        else => 0,
    };
}
fn in16(port: u16) u16 {
    return switch (builtin.cpu.arch) {
        .x86, .x86_64 => asm volatile ("inw %[p], %[r]"
            : [r] "={ax}" (-> u16),
            : [p] "{dx}" (port),
        ),
        else => 0,
    };
}
fn in32(port: u16) u32 {
    return switch (builtin.cpu.arch) {
        .x86, .x86_64 => asm volatile ("inl %[p], %[r]"
            : [r] "={eax}" (-> u32),
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
fn out16(port: u16, v: u16) void {
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => asm volatile ("outw %[v], %[p]"
            :
            : [v] "{ax}" (v),
              [p] "{dx}" (port),
        ),
        else => {},
    }
}
fn out32(port: u16, v: u32) void {
    switch (builtin.cpu.arch) {
        .x86, .x86_64 => asm volatile ("outl %[v], %[p]"
            :
            : [v] "{eax}" (v),
              [p] "{dx}" (port),
        ),
        else => {},
    }
}

// Mixer registers:
const RESET = 0x00;
const MASTER = 0x02;
const HEADPHONE = 0x04;
const PCM_OUT = 0x18;
const EXT_ID = 0x28;
const EXT_CTRL = 0x2A;
const FRONT_RATE = 0x2C;

// Bus master: PCM out's box, and the global registers:
const PO_BDBAR = 0x10;
const PO_CIV = 0x14;
const PO_LVI = 0x15;
const PO_SR = 0x16;
const PO_PICB = 0x18;
const PO_CR = 0x1B;
const GLOB_CNT = 0x2C;
const GLOB_STA = 0x30;

const entries = 32;
const entry_bytes = 4096;
const buffer_size = entries * entry_bytes;
const margin = 1024;

var buffer: [*]u8 = undefined;
var bdl: [*]volatile u32 = undefined;
var variable_rate = false;
var running = false;
var last_pos: u32 = 0;
var written: u64 = 0;
var played: u64 = 0;

fn waitUntil(ms: u64, comptime cond: fn () bool) bool {
    const until = api.millis() + ms;
    while (!cond()) {
        if (api.millis() > until) return false;
        api.delay_us(50);
    }
    return true;
}

fn resetBox() void {
    out8(nabm + PO_CR, 0);
    out8(nabm + PO_CR, 0x02); // reset registers
    _ = waitUntil(20, struct {
        fn f() bool {
            return in8(nabm + PO_CR) & 0x02 == 0;
        }
    }.f);
    out16(nabm + PO_SR, 0x1C); // clear status
    running = false;
}

fn start(_: ?*anyopaque, rate: u32) callconv(drv.cc) bool {
    if (rate != 48000) {
        if (!variable_rate or rate < 8000 or rate > 48000) return false;
        out16(nam + FRONT_RATE, @intCast(rate));
        if (in16(nam + FRONT_RATE) != rate) return false; // a rate the codec rounds
    } else if (variable_rate) out16(nam + FRONT_RATE, 48000);
    resetBox();
    @memset(buffer[0..buffer_size], 0);
    out32(nabm + PO_BDBAR, @truncate(@intFromPtr(bdl)));
    out8(nabm + PO_LVI, entries - 1);
    last_pos = 0;
    written = 0;
    played = 0;
    out8(nabm + PO_CR, 0x01); // run
    running = true;
    return true;
}

// The last valid entry moved on, a halted DMA started
// again, what played silenced.
fn update() void {
    if (!running) return;
    const civ = in8(nabm + PO_CIV) % entries;
    const picb: u32 = in16(nabm + PO_PICB); // 16-bit samples left in the entry
    out8(nabm + PO_LVI, @intCast((civ + entries - 1) % entries));
    const sr = in16(nabm + PO_SR);
    if (sr & 0x01 != 0) { // halted: it reached the last valid entry
        out16(nabm + PO_SR, 0x1C);
        out8(nabm + PO_CR, 0x01);
    } else if (sr & 0x1C != 0) out16(nabm + PO_SR, sr & 0x1C);
    const into = entry_bytes -| @min(picb * 2, entry_bytes);
    const pos: u32 = @intCast((@as(u32, civ) * entry_bytes + into) % buffer_size);
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
    if (running) resetBox();
    @memset(buffer[0..buffer_size], 0);
}

// 0 (loudest) to 31 per channel; 0%: muted.
fn setVolume(_: ?*anyopaque, percent: u32) callconv(drv.cc) void {
    const p = @min(percent, 100);
    if (p == 0) return out16(nam + MASTER, 0x8000);
    const att: u16 = @intCast((100 - p) * 31 / 100);
    out16(nam + MASTER, att << 8 | att);
    out16(nam + HEADPHONE, att << 8 | att);
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

fn log(comptime fmt: []const u8, args: anytype) void {
    var line: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&line, fmt, args) catch return;
    api.log(text.ptr, text.len);
}

export fn zdos_driver_init(a: *const drv.Api, dev: *const drv.Device) callconv(drv.cc) bool {
    api = a;
    if (!is_x86) return false;
    // Both BARs are I/O ports (bit 0):
    if (dev.bars[0] & 1 == 0 or dev.bars[1] & 1 == 0) return false;
    nam = @intCast(dev.bars[0] & 0xFFFC);
    nabm = @intCast(dev.bars[1] & 0xFFFC);
    api.pci_enable(dev);

    // Cold reset, then the primary codec ready (bit 8):
    out32(nabm + GLOB_CNT, 0);
    api.delay_us(1000);
    out32(nabm + GLOB_CNT, 0x02);
    if (!waitUntil(1000, struct {
        fn f() bool {
            return in32(nabm + GLOB_STA) & (1 << 8) != 0;
        }
    }.f)) {
        log("AC97: no codec\n", .{});
        return false;
    }
    out16(nam + RESET, 0);
    api.delay_us(10_000);
    out16(nam + MASTER, 0); // 0 dB, unmuted
    out16(nam + HEADPHONE, 0);
    out16(nam + PCM_OUT, 0x0808); // 0 dB
    if (in16(nam + EXT_ID) & 1 != 0) { // variable rate audio
        out16(nam + EXT_CTRL, in16(nam + EXT_CTRL) | 1);
        variable_rate = true;
    }

    // The buffer, then the entries' list after it; 32-bit addresses:
    const pages = api.alloc_pages(buffer_size / 4096 + 1) orelse return false;
    const base = @intFromPtr(pages);
    if (@as(u64, base) + buffer_size + 4096 > 0xFFFF_FFFF) {
        api.free_pages(pages, buffer_size / 4096 + 1);
        log("AC97: no memory below 4 GiB\n", .{});
        return false;
    }
    buffer = pages;
    bdl = @ptrCast(@alignCast(pages + buffer_size));
    for (0..entries) |i| {
        bdl[i * 2] = @truncate(base + i * entry_bytes);
        bdl[i * 2 + 1] = entry_bytes / 2; // samples; no interrupt
    }
    resetBox();

    const name = std.fmt.bufPrint(&card.name, "AC'97 {X:0>4}:{X:0>4}", .{ dev.vendor, dev.device }) catch "AC'97";
    card.name_len = @intCast(name.len);
    log("AC97: codec ready{s}\n", .{if (variable_rate) ", variable rate" else ", 48000 Hz only"});
    return api.register_sound(&card);
}
