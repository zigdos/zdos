// HDA.SYS: High Definition Audio (any PCI class 04, subclass 03).
// 16-bit stereo on the first codec's output pins, each by a path to a DAC.
// One stream, a 64 KiB cyclic buffer whose played part is silenced
// again, so a pause in writing is quiet. No interrupts: ZDOS asks.
const std = @import("std");
const builtin = @import("builtin");
const drv = @import("drv");

export const zdos_driver_ids = [_]drv.PciId{
    .{ .vendor = drv.any_vendor, .device = 0x0403 }, // multimedia, HD Audio
    .{ .vendor = 0, .device = 0 },
};

var api: *const drv.Api = undefined;
var regs: usize = 0;

// REGISTERS: explicit widths, a volatile struct field may be read
// narrower than the device wants

fn r8(off: usize) u8 {
    return @truncate(rd(off, 1));
}
fn r16(off: usize) u16 {
    return @truncate(rd(off, 2));
}
fn r32(off: usize) u32 {
    return rd(off, 4);
}

fn rd(off: usize, comptime size: u8) u32 {
    const a = regs + off;
    return switch (builtin.cpu.arch) {
        .x86_64, .x86 => switch (size) {
            1 => asm volatile ("movzbl (%[a]), %[r]"
                : [r] "=r" (-> u32),
                : [a] "r" (a),
                : "memory"
            ),
            2 => asm volatile ("movzwl (%[a]), %[r]"
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
        .aarch64 => switch (size) {
            1 => asm volatile ("ldrb %[r:w], [%[a]]"
                : [r] "=r" (-> u32),
                : [a] "r" (a),
                : "memory"
            ),
            2 => asm volatile ("ldrh %[r:w], [%[a]]"
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
        else => @compileError("HDA.SYS: x86 and ARM64 only"),
    };
}

fn w8(off: usize, v: u8) void {
    wr(off, v, 1);
}
fn w16(off: usize, v: u16) void {
    wr(off, v, 2);
}
fn w32(off: usize, v: u32) void {
    wr(off, v, 4);
}

fn wr(off: usize, v: u32, comptime size: u8) void {
    const a = regs + off;
    switch (builtin.cpu.arch) {
        .x86_64, .x86 => switch (size) {
            1 => asm volatile ("movb %[v], (%[a])"
                :
                : [v] "q" (@as(u8, @truncate(v))),
                  [a] "r" (a),
                : "memory"
            ),
            2 => asm volatile ("movw %[v], (%[a])"
                :
                : [v] "r" (@as(u16, @truncate(v))),
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
        .aarch64 => switch (size) {
            1 => asm volatile ("dsb sy\n strb %[v:w], [%[a]]"
                :
                : [v] "r" (v),
                  [a] "r" (a),
                : "memory"
            ),
            2 => asm volatile ("dsb sy\n strh %[v:w], [%[a]]"
                :
                : [v] "r" (v),
                  [a] "r" (a),
                : "memory"
            ),
            else => asm volatile ("dsb sy\n str %[v:w], [%[a]]"
                :
                : [v] "r" (v),
                  [a] "r" (a),
                : "memory"
            ),
        },
        else => @compileError("HDA.SYS: x86 and ARM64 only"),
    }
}

const GCAP = 0x00;
const GCTL = 0x08;
const STATESTS = 0x0E;
const INTCTL = 0x20;
const CORBLBASE = 0x40;
const CORBUBASE = 0x44;
const CORBWP = 0x48;
const CORBRP = 0x4A;
const CORBCTL = 0x4C;
const CORBSIZE = 0x4E;
const RIRBLBASE = 0x50;
const RIRBUBASE = 0x54;
const RIRBWP = 0x58;
const RINTCNT = 0x5A;
const RIRBCTL = 0x5C;
const RIRBSTS = 0x5D;
const RIRBSIZE = 0x5E;

// Stream descriptor registers, from its base:
const SD_CTL = 0x00; // 3 bytes: SRST bit 0, RUN bit 1, stream number 23:20
const SD_STS = 0x03;
const SD_LPIB = 0x04;
const SD_CBL = 0x08;
const SD_LVI = 0x0C;
const SD_FMT = 0x12;
const SD_BDPL = 0x18;
const SD_BDPU = 0x1C;

// False on timeout.
fn waitFor(ms: u64, comptime cond: fn () bool) bool {
    const until = api.millis() + ms;
    while (!cond()) {
        if (api.millis() > until) return false;
        api.delay_us(10);
    }
    return true;
}

fn physLow(p: usize) u32 {
    return @truncate(p);
}
fn physHigh(p: usize) u32 {
    return @truncate(@as(u64, p) >> 32);
}

// CONTROLLER AND COMMANDS

var corb: [*]volatile u32 = undefined;
var rirb: [*]volatile u64 = undefined;
var corb_entries: u16 = 0;
var rirb_entries: u16 = 0;
var rirb_read: u16 = 0;

fn reset() bool {
    w8(CORBCTL, 0);
    w8(RIRBCTL, 0);
    w32(GCTL, r32(GCTL) & ~@as(u32, 1));
    if (!waitFor(100, struct {
        fn f() bool {
            return r32(GCTL) & 1 == 0;
        }
    }.f)) return false;
    api.delay_us(100);
    w32(GCTL, r32(GCTL) | 1);
    if (!waitFor(100, struct {
        fn f() bool {
            return r32(GCTL) & 1 != 0;
        }
    }.f)) return false;
    api.delay_us(1000); // codecs announce themselves (STATESTS) within 521 us
    w32(INTCTL, 0); // polled
    return true;
}

// The size code and entries.
fn ringSize(reg: usize) struct { code: u8, entries: u16 } {
    const caps = r8(reg) >> 4;
    if (caps & 4 != 0) return .{ .code = 2, .entries = 256 };
    if (caps & 2 != 0) return .{ .code = 1, .entries = 16 };
    return .{ .code = 0, .entries = 2 };
}

fn setupRings() bool {
    const page = api.alloc_pages(1) orelse return false;
    const p = @intFromPtr(page);
    corb = @ptrCast(@alignCast(page));
    rirb = @ptrFromInt(p + 2048);

    const cs = ringSize(CORBSIZE);
    corb_entries = cs.entries;
    w8(CORBSIZE, (r8(CORBSIZE) & 0xFC) | cs.code);
    w32(CORBLBASE, physLow(p));
    w32(CORBUBASE, physHigh(p));
    // Read pointer reset: bit 15 set, seen, cleared (some controllers
    // never show it: then go on):
    w16(CORBRP, 0x8000);
    _ = waitFor(5, struct {
        fn f() bool {
            return r16(CORBRP) & 0x8000 != 0;
        }
    }.f);
    w16(CORBRP, 0);
    _ = waitFor(5, struct {
        fn f() bool {
            return r16(CORBRP) & 0x8000 == 0;
        }
    }.f);
    w16(CORBWP, 0);
    w8(CORBCTL, 0x02); // DMA on

    const rs = ringSize(RIRBSIZE);
    rirb_entries = rs.entries;
    w8(RIRBSIZE, (r8(RIRBSIZE) & 0xFC) | rs.code);
    w32(RIRBLBASE, physLow(p + 2048));
    w32(RIRBUBASE, physHigh(p + 2048));
    w16(RIRBWP, 0x8000); // write pointer reset
    // At this response count controllers (QEMU's) stop taking commands
    // until RIRBSTS is cleared, which command does. INTCTL stays off:
    w16(RINTCNT, 0xFF);
    w8(RIRBSTS, 0x05);
    w8(RIRBCTL, 0x03); // DMA on, response count flag on
    rirb_read = 0;
    return true;
}

var command_failed = false;

// The answer is 0 after a timeout. Verbs above 0xF take an 8-bit
// payload, the 4-bit ones 16 bits.
fn command(cad: u32, nid: u32, verb: u32, payload: u32) u32 {
    const body: u32 = if (verb > 0xF) (verb << 8) | (payload & 0xFF) else (verb << 16) | (payload & 0xFFFF);
    const word = (cad << 28) | (nid << 20) | body;
    const wp = (r16(CORBWP) + 1) % corb_entries;
    corb[wp] = word;
    w16(CORBWP, wp);
    const until = api.millis() + 20;
    while (true) {
        const hw = r16(RIRBWP) % rirb_entries;
        if (hw != rirb_read) {
            rirb_read = (rirb_read + 1) % rirb_entries;
            const e = rirb[rirb_read];
            w8(RIRBSTS, 0x05); // responses taken: the controller goes on
            if ((e >> 32) & 0x10 != 0) continue; // unsolicited
            return @truncate(e);
        }
        if (api.millis() > until) {
            command_failed = true;
            return 0;
        }
        api.delay_us(5);
    }
}

fn param(cad: u32, nid: u32, id: u32) u32 {
    return command(cad, nid, 0xF00, id);
}

// THE CODEC'S WIDGETS: OUTPUT PINS TO CONVERTERS

const max_nodes = 128;
const max_depth = 6;
const Node = struct {
    caps: u32 = 0, // audio widget capabilities
    conns: [16]u8 = undefined,
    conn_count: u8 = 0,
};

var codec: u32 = 0;
var afg: u32 = 0;
var nodes = [_]Node{.{}} ** max_nodes;
var first_node: u32 = 0;
var node_count: u32 = 0;

fn kind(nid: u32) u32 {
    return (nodes[nid].caps >> 20) & 0xF;
}

const kind_output = 0;
const kind_mixer = 2;
const kind_selector = 3;
const kind_pin = 4;

// Short form 4 entries, long form 2 per answer; an entry with the range
// bit stands for all nodes from the previous one.
fn readConnections(nid: u32) void {
    const len_info = param(codec, nid, 0x0E);
    const long = len_info & 0x80 != 0;
    const len = len_info & 0x7F;
    const per: u32 = if (long) 2 else 4;
    const bits: u5 = if (long) 16 else 8;
    var n = &nodes[nid];
    n.conn_count = 0;
    var prev: u32 = 0;
    var i: u32 = 0;
    while (i < len) : (i += per) {
        const r = command(codec, nid, 0xF02, i);
        for (0..per) |k| {
            if (i + k >= len) break;
            const raw = (r >> @intCast(k * bits)) & ((@as(u32, 1) << bits) - 1);
            const range = raw & (@as(u32, 1) << (bits - 1)) != 0;
            const id = raw & ((@as(u32, 1) << (bits - 1)) - 1);
            if (range and prev != 0) {
                var x = prev + 1;
                while (x <= id) : (x += 1) addConn(n, x);
            } else addConn(n, id);
            prev = id;
        }
    }
}

fn addConn(n: *Node, id: u32) void {
    if (n.conn_count < n.conns.len and id < max_nodes) {
        n.conns[n.conn_count] = @intCast(id);
        n.conn_count += 1;
    }
}

// Its nodes, and at each the index of the connection taken:
var path: [max_depth]u8 = undefined;
var path_index: [max_depth]u8 = undefined;
var path_len: usize = 0;

fn findPath(nid: u32, depth: usize) bool {
    if (depth == max_depth or nid < first_node or nid >= first_node + node_count) return false;
    path[depth] = @intCast(nid);
    if (kind(nid) == kind_output) {
        path_len = depth + 1;
        return true;
    }
    if (depth > 0 and kind(nid) != kind_mixer and kind(nid) != kind_selector) return false;
    const n = &nodes[nid];
    for (n.conns[0..n.conn_count], 0..) |c, i| {
        path_index[depth] = @intCast(i);
        if (findPath(c, depth + 1)) return true;
    }
    return false;
}

// The widget's own, else the function group's.
fn ampCaps(nid: u32, output: bool) u32 {
    const id: u32 = if (output) 0x12 else 0x0D;
    const own = nodes[nid].caps & (1 << 3) != 0; // amp parameter override
    return param(codec, if (own) nid else afg, id);
}

// Output or input (index), both channels, gain, mute.
fn setAmp(nid: u32, output: bool, index: u32, gain: u32, mute: bool) void {
    const payload: u32 = (if (output) @as(u32, 1) << 15 else @as(u32, 1) << 14) | (3 << 12) | (index << 8) |
        (if (mute) @as(u32, 0x80) else 0) | (gain & 0x7F);
    _ = command(codec, nid, 0x3, payload);
}

// The converters playing, and the output amps the volume sets:
var dacs: [8]u8 = undefined;
var dac_count: usize = 0;
const Volume = struct { nid: u8, steps: u8 };
var volumes: [8]Volume = undefined;
var volume_count: usize = 0;

fn addDac(nid: u32) void {
    for (dacs[0..dac_count]) |d| if (d == nid) return;
    if (dac_count < dacs.len) {
        dacs[dac_count] = @intCast(nid);
        dac_count += 1;
    }
}

fn addVolume(nid: u32, steps: u32) void {
    for (volumes[0..volume_count]) |v| if (v.nid == nid) return;
    if (volume_count < volumes.len) {
        volumes[volume_count] = .{ .nid = @intCast(nid), .steps = @intCast(steps) };
        volume_count += 1;
    }
}

// Connections chosen, amps on at 0 dB, the pin driving.
fn setupPath(device: u32, pin_caps: u32) void {
    for (path[0..path_len], 0..) |nid, i| {
        _ = command(codec, nid, 0x705, 0); // power D0
        const caps = nodes[nid].caps;
        const k = kind(nid);
        if (i + 1 < path_len) {
            if (k == kind_mixer) {
                if (caps & (1 << 1) != 0) { // input amp
                    const ac = ampCaps(nid, false);
                    setAmp(nid, false, path_index[i], ac & 0x7F, false);
                }
            } else if (nodes[nid].conn_count > 1) {
                _ = command(codec, nid, 0x701, path_index[i]); // connection select
            }
        }
        if (caps & (1 << 2) != 0) { // output amp
            const ac = ampCaps(nid, true);
            const steps = (ac >> 8) & 0x7F;
            setAmp(nid, true, 0, ac & 0x7F, false);
            if (steps > 0 and k != kind_pin) addVolume(nid, steps);
        }
    }
    const pin = path[0];
    // Output on; headphone drive where it is headphones:
    const hp: u32 = if (device == 2 and pin_caps & (1 << 3) != 0) 0x80 else 0;
    _ = command(codec, pin, 0x707, 0x40 | hp);
    if (pin_caps & (1 << 16) != 0) _ = command(codec, pin, 0x70C, 0x02); // EAPD on
    addDac(path[path_len - 1]);
}

fn setupCodec() bool {
    const root = param(codec, 0, 0x04);
    const fg_start = (root >> 16) & 0xFF;
    const fg_count = root & 0xFF;
    afg = 0;
    for (0..fg_count) |i| {
        const nid: u32 = fg_start + @as(u32, @intCast(i));
        if (param(codec, nid, 0x05) & 0xFF == 1) {
            afg = nid;
            break;
        }
    }
    if (afg == 0) return false;
    _ = command(codec, afg, 0x705, 0); // power D0
    api.delay_us(10_000);
    const sub = param(codec, afg, 0x04);
    first_node = (sub >> 16) & 0xFF;
    if (first_node == 0 or first_node >= max_nodes) return false;
    node_count = @min(sub & 0xFF, max_nodes - first_node);
    for (first_node..first_node + node_count) |nid| {
        nodes[nid].caps = param(codec, @intCast(nid), 0x09);
        if (nodes[nid].caps & (1 << 8) != 0) readConnections(@intCast(nid)) else nodes[nid].conn_count = 0;
    }
    // Connected line out, speaker, headphones; failing those,
    // any pin that can output:
    var found = false;
    for (0..2) |pass| {
        for (first_node..first_node + node_count) |nid| {
            if (kind(@intCast(nid)) != kind_pin) continue;
            const pin_caps = param(codec, @intCast(nid), 0x0C);
            if (pin_caps & (1 << 4) == 0) continue; // not output capable
            const config = command(codec, @intCast(nid), 0xF1C, 0);
            const device = (config >> 20) & 0xF;
            const connected = config >> 30 != 1;
            if (pass == 0 and !(connected and device <= 2)) continue;
            if (!findPath(@intCast(nid), 0)) continue;
            setupPath(device, pin_caps);
            found = true;
        }
        if (found) break;
    }
    return found and !command_failed;
}

// THE STREAM

const buffer_size = 64 * 1024;
const parts = 4;
const stream_tag = 1;
const margin = 1024; // bytes ahead of the DMA position new samples start

var sd: usize = 0; // the output stream's registers
var buffer: [*]u8 = undefined;
var running = false;
var last_pos: u32 = 0;
var written: u64 = 0;
var played: u64 = 0;

fn setupStream() bool {
    const gcap = r16(GCAP);
    const inputs = (gcap >> 8) & 0xF;
    const outputs = (gcap >> 12) & 0xF;
    if (outputs == 0) return false;
    sd = 0x80 + @as(usize, inputs) * 0x20;
    const pages = api.alloc_pages(buffer_size / 4096 + 1) orelse return false;
    buffer = pages;
    const bdl: [*]volatile u32 = @ptrCast(@alignCast(pages + buffer_size));
    const base = @intFromPtr(pages);
    for (0..parts) |i| {
        const at = base + i * (buffer_size / parts);
        bdl[i * 4 + 0] = physLow(at);
        bdl[i * 4 + 1] = physHigh(at);
        bdl[i * 4 + 2] = buffer_size / parts;
        bdl[i * 4 + 3] = 0; // no interrupt
    }
    return true;
}

// Base 48 or 44.1 kHz, multiplier, divisor; the converters'
// rate bit (parameter 0x0A).
const Rate = struct { hz: u32, base: u32, mult: u32, div: u32, bit: u5 };
const rates = [_]Rate{
    .{ .hz = 48000, .base = 0, .mult = 0, .div = 0, .bit = 6 },
    .{ .hz = 44100, .base = 1, .mult = 0, .div = 0, .bit = 5 },
    .{ .hz = 96000, .base = 0, .mult = 1, .div = 0, .bit = 8 },
    .{ .hz = 88200, .base = 1, .mult = 1, .div = 0, .bit = 7 },
    .{ .hz = 192000, .base = 0, .mult = 3, .div = 0, .bit = 10 },
    .{ .hz = 176400, .base = 1, .mult = 3, .div = 0, .bit = 9 },
    .{ .hz = 32000, .base = 0, .mult = 1, .div = 2, .bit = 4 },
    .{ .hz = 22050, .base = 1, .mult = 0, .div = 1, .bit = 3 },
    .{ .hz = 16000, .base = 0, .mult = 0, .div = 2, .bit = 2 },
    .{ .hz = 11025, .base = 1, .mult = 0, .div = 3, .bit = 1 },
    .{ .hz = 8000, .base = 0, .mult = 0, .div = 5, .bit = 0 },
};

fn supported(r: Rate) bool {
    if (r.hz == 48000) return true;
    for (dacs[0..dac_count]) |d| {
        const own = nodes[d].caps & (1 << 4) != 0; // format override
        const pcm = param(codec, if (own) d else afg, 0x0A);
        if (pcm & (@as(u32, 1) << r.bit) == 0) return false;
    }
    return true;
}

fn stopStream() void {
    const ctl = r8(sd + SD_CTL);
    w8(sd + SD_CTL, ctl & ~@as(u8, 0x02));
    _ = waitFor(10, struct {
        fn f() bool {
            return r8(sd + SD_CTL) & 0x02 == 0;
        }
    }.f);
    running = false;
}

fn start(_: ?*anyopaque, hz: u32) callconv(drv.cc) bool {
    const r = for (rates) |x| {
        if (x.hz == hz) break x;
    } else return false;
    if (!supported(r)) return false;
    if (running) stopStream();
    // Stream reset:
    w8(sd + SD_CTL, r8(sd + SD_CTL) | 0x01);
    _ = waitFor(10, struct {
        fn f() bool {
            return r8(sd + SD_CTL) & 0x01 != 0;
        }
    }.f);
    w8(sd + SD_CTL, r8(sd + SD_CTL) & ~@as(u8, 0x01));
    _ = waitFor(10, struct {
        fn f() bool {
            return r8(sd + SD_CTL) & 0x01 == 0;
        }
    }.f);
    @memset(buffer[0..buffer_size], 0);
    const format: u16 = @intCast((r.base << 14) | (r.mult << 11) | (r.div << 8) | (1 << 4) | 1); // 16 bits, 2 channels
    const bdl = @intFromPtr(buffer) + buffer_size;
    w32(sd + SD_BDPL, physLow(bdl));
    w32(sd + SD_BDPU, physHigh(bdl));
    w32(sd + SD_CBL, buffer_size);
    w16(sd + SD_LVI, parts - 1);
    w16(sd + SD_FMT, format);
    w8(sd + SD_CTL + 2, stream_tag << 4);
    w8(sd + SD_STS, 0x1C); // clear status
    for (dacs[0..dac_count]) |d| {
        _ = command(codec, d, 0x2, format);
        _ = command(codec, d, 0x706, stream_tag << 4);
    }
    last_pos = 0;
    written = 0;
    played = 0;
    w8(sd + SD_CTL, r8(sd + SD_CTL) | 0x02); // run
    running = true;
    return true;
}

// What the DMA played is silenced again.
fn update() void {
    if (!running) return;
    const pos = r32(sd + SD_LPIB) % buffer_size;
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
    var left = n;
    var from: usize = 0;
    while (left > 0) {
        const part = @min(left, buffer_size - at);
        @memcpy(buffer[at..][0..part], data[from..][0..part]);
        from += part;
        left -= part;
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
    if (running) stopStream();
    @memset(buffer[0..buffer_size], 0);
}

fn setVolume(_: ?*anyopaque, percent: u32) callconv(drv.cc) void {
    for (volumes[0..volume_count]) |v| {
        const gain = @as(u32, v.steps) * @min(percent, 100) / 100;
        setAmp(v.nid, true, 0, gain, percent == 0);
    }
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

fn fail(why: []const u8) bool {
    var line: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "HDA: {s}\n", .{why}) catch return false;
    api.log(text.ptr, text.len);
    return false;
}

export fn zdos_driver_init(a: *const drv.Api, dev: *const drv.Device) callconv(drv.cc) bool {
    api = a;
    const bar = dev.bars[0];
    if (bar == 0 or bar & 1 != 0) return false; // memory registers only
    const phys = bar & ~@as(u64, 0xF);
    if (phys > std.math.maxInt(usize) or !api.map_device(phys, 0x4000)) return false;
    regs = @intCast(phys);
    api.pci_enable(dev);
    if (!reset()) return fail("the controller doesn't leave reset");
    if (!setupRings()) return fail("no memory for its command rings");
    const present = r16(STATESTS);
    w16(STATESTS, present);
    if (present & 0x7FFF == 0) return fail("no codec");
    // The first codec with an audio function group and an output path:
    var cad: u32 = 0;
    const ok = while (cad < 15) : (cad += 1) {
        if (present & (@as(u16, 1) << @intCast(cad)) == 0) continue;
        codec = cad;
        command_failed = false;
        dac_count = 0;
        volume_count = 0;
        if (setupCodec()) break true;
    } else false;
    if (!ok or !setupStream()) {
        w8(CORBCTL, 0);
        w8(RIRBCTL, 0);
        return fail(if (!ok) (if (command_failed) "the codec doesn't answer" else "no output pin with a path to a converter") else "no output stream or memory");
    }
    var buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "HD Audio {X:0>4}:{X:0>4}", .{ dev.vendor, dev.device }) catch "HD Audio";
    @memcpy(card.name[0..name.len], name);
    card.name_len = @intCast(name.len);
    var line: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "HDA: codec {d}, {d} output path(s)\n", .{ codec, dac_count }) catch "HDA\n";
    api.log(text.ptr, text.len);
    return api.register_sound(&card);
}
