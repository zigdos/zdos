// PLAY FILE.WAV|FILE.MID [VOLUME]: PCM 8-32 bits or float, mono or
// stereo (24 and 32 bits as 16; of more channels the first two), or
// a MIDI file through MIDI.ZDL (MIDISYNTH=fm or sf2).
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const sound = @import("zdos/sound.zig");
const system = @import("zdos/system.zig");

comptime {
    _ = zdos;
}

pub const zdos_file_version = [4]u8{ 0, 6, 0, 0 };

const Format = struct {
    tag: u16 = 0, // 1 PCM, 3 float
    channels: u16 = 0,
    rate: u32 = 0,
    bits: u16 = 0,
    block: u16 = 0,
};

var in_buf: [64 * 1024]u8 = undefined;
var out_buf: [128 * 1024]u8 = undefined; // 8-bit, 3+ channels doubles

pub fn main(args: []const u8) u8 {
    system.catchCtrlC(true); // send() looks for it
    defer system.catchCtrlC(false);
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    const name = words.next() orelse {
        zdos.print("Usage: PLAY file.wav|file.mid [volume 0-100]\n");
        return 1;
    };
    if (words.next()) |v| {
        const percent = std.fmt.parseInt(u32, v, 10) catch {
            zdos.print("PLAY: the volume is a number, 0-100\n");
            return 1;
        };
        sound.setVolume(percent) catch {};
    }
    const f = zdos.open(name, .read) catch |err| {
        zdos.printf("PLAY: {s}: {s}\n", .{ name, zdos.message(err) });
        return 1;
    };
    defer f.close();

    var head: [12]u8 = undefined;
    if (readAll(f, head[0..4]) and std.mem.eql(u8, head[0..4], "MThd")) return playMidi(f, name);
    if (!readAll(f, head[4..]) or !std.mem.eql(u8, head[0..4], "RIFF") or !std.mem.eql(u8, head[8..12], "WAVE")) return bad("not a WAV file");
    // Chunks up to "data", with "fmt " on the way:
    var fmt: Format = .{};
    var data_len: u64 = 0;
    while (true) {
        var ch: [8]u8 = undefined;
        if (!readAll(f, &ch)) return bad("no data chunk");
        const len = std.mem.readInt(u32, ch[4..8], .little);
        if (std.mem.eql(u8, ch[0..4], "fmt ")) {
            var b: [40]u8 = @splat(0);
            const take = @min(len, b.len);
            if (len < 16 or !readAll(f, b[0..take])) return bad("a bad fmt chunk");
            fmt = .{
                .tag = std.mem.readInt(u16, b[0..2], .little),
                .channels = std.mem.readInt(u16, b[2..4], .little),
                .rate = std.mem.readInt(u32, b[4..8], .little),
                .block = std.mem.readInt(u16, b[12..14], .little),
                .bits = std.mem.readInt(u16, b[14..16], .little),
            };
            // WAVE_FORMAT_EXTENSIBLE: the real format starts its subtype GUID:
            if (fmt.tag == 0xFFFE and len >= 26) fmt.tag = std.mem.readInt(u16, b[24..26], .little);
            if (!skip(f, len - take + (len & 1))) return bad("a short file");
        } else if (std.mem.eql(u8, ch[0..4], "data")) {
            data_len = len;
            break;
        } else if (!skip(f, len + (len & 1))) return bad("no data chunk");
    }
    const ok_bits = (fmt.tag == 1 and (fmt.bits == 8 or fmt.bits == 16 or fmt.bits == 24 or fmt.bits == 32)) or (fmt.tag == 3 and fmt.bits == 32);
    if (!ok_bits or fmt.channels == 0 or fmt.rate == 0 or fmt.block != fmt.channels * fmt.bits / 8) return bad("a sample format PLAY doesn't know (PCM 8-32 bits, float 32)");

    const out_channels: u32 = @min(fmt.channels, 2);
    const out_bits: u32 = if (fmt.bits == 8 and fmt.channels <= 2) 8 else 16;
    const out = sound.open(fmt.rate, out_channels, out_bits) catch |err| {
        zdos.printf("PLAY: no sound output: {s}\n", .{zdos.message(err)});
        return 1;
    };
    const secs = data_len / (@as(u64, fmt.rate) * fmt.block);
    zdos.printf("{s}: {d} Hz, {d} bits{s}, {s}, {d}:{d:0>2}  (Ctrl+C stops)\n", .{
        name,                                                                                       fmt.rate,  fmt.bits,  if (fmt.tag == 3) " float" else "",
        if (fmt.channels == 1) "mono" else if (fmt.channels == 2) "stereo" else "first 2 channels", secs / 60, secs % 60,
    });

    // Whole frames per read:
    const frames_per = in_buf.len / fmt.block;
    var left = data_len;
    while (left > 0) {
        const want: usize = @intCast(@min(left, frames_per * fmt.block));
        const n = readSome(f, in_buf[0..want]);
        if (n < fmt.block) break;
        const whole = n - n % fmt.block;
        left -= n;
        const bytes = convert(fmt, out_channels, in_buf[0..whole]);
        switch (send(out, bytes, fmt.rate * out_channels * out_bits / 8)) {
            .more => {},
            .ctrl_c => return 255,
            .failed => break,
        }
    }
    out.close(false);
    return 0;
}

// MIDI.ZDL (ports/media/midi): exports.def's slots, typed where
// PLAY calls them; the C convention.
const Midi = opaque {};
const MidiApi = extern struct {
    slots: usize,
    open: *const fn (c_int, ?[*:0]const u8) callconv(.c) ?*Midi,
    open_memory: *const anyopaque,
    close: *const fn (*Midi) callconv(.c) void,
    synth: *const fn (*Midi) callconv(.c) c_int,
    set_output: *const fn (*Midi, c_int, c_int) callconv(.c) c_int,
    set_volume: *const anyopaque,
    load: *const anyopaque,
    load_memory: *const fn (*Midi, *const anyopaque, c_int) callconv(.c) c_int,
    stop: *const anyopaque,
    restart: *const anyopaque,
    set_loop: *const anyopaque,
    finished: *const fn (*Midi) callconv(.c) c_int,
    length_ms: *const fn (*Midi) callconv(.c) c_uint,
    position_ms: *const anyopaque,
    render: *const fn (*Midi, [*]i16, c_int, c_int) callconv(.c) void,
};
const midi_fm = 1;
const midi_rate = 44100;
var midi_pcm: [2 * 4096]i16 = undefined;

fn playMidi(f: zdos.File, name: []const u8) u8 {
    const size = f.size() catch 0;
    if (size < 14 or size > 64 << 20) return bad("not a MIDI file");
    const data = zdos.allocator.alloc(u8, @intCast(size)) catch return bad("out of memory");
    defer zdos.allocator.free(data);
    f.seek(0) catch return bad("can't read the file");
    if (!readAll(f, data)) return bad("a short file");

    const lib = zdos.library(MidiApi, "MIDI") catch |err| {
        zdos.printf("PLAY: MIDI.ZDL: {s}\n", .{zdos.message(err)});
        return 1;
    };
    const m = lib.open(0, null) orelse return bad("no synthesizer (MIDI.ZDL)");
    defer lib.close(m);
    if (lib.set_output(m, midi_rate, 2) != 0 or lib.load_memory(m, data.ptr, @intCast(data.len)) != 0)
        return bad("not a MIDI file PLAY can play");
    const out = sound.open(midi_rate, 2, 16) catch |err| {
        zdos.printf("PLAY: no sound output: {s}\n", .{zdos.message(err)});
        return 1;
    };
    const secs = lib.length_ms(m) / 1000;
    zdos.printf("{s}: MIDI, {s}, {d}:{d:0>2}  (Ctrl+C stops)\n", .{
        name, if (lib.synth(m) == midi_fm) "FM" else "SoundFont", secs / 60, secs % 60,
    });
    while (lib.finished(m) == 0) {
        lib.render(m, &midi_pcm, midi_pcm.len / 2, 0);
        switch (send(out, std.mem.sliceAsBytes(&midi_pcm), midi_rate * 4)) {
            .more => {},
            .ctrl_c => return 255,
            .failed => break,
        }
    }
    out.close(false);
    return 0;
}

// Into the card 50 ms at a time while it holds less than
// 100 ms (less than the SB16's ring: a write doesn't wait);
// meanwhile PLAY waits itself and looks for Ctrl+C, which
// drops what is queued
const Sent = enum { more, ctrl_c, failed };

fn send(out: sound.Output, bytes: []const u8, per_second: usize) Sent {
    var at: usize = 0;
    while (at < bytes.len) {
        while (out.queued() > per_second / 10) {
            if (system.ctrlCPressed(true)) {
                out.close(true);
                return .ctrl_c;
            }
            zdos.sleep(10);
        }
        const piece = @min(bytes.len - at, @max(per_second / 20 & ~@as(usize, 3), 4));
        at += out.write(bytes[at..][0..piece]) catch return .failed;
    }
    return .more;
}

// As they are, or 16-bit (and two channels).
fn convert(fmt: Format, out_channels: u32, in: []const u8) []const u8 {
    if ((fmt.bits == 8 or fmt.bits == 16) and fmt.tag == 1 and fmt.channels <= 2) return in;
    const size: usize = fmt.bits / 8;
    var w: usize = 0;
    var i: usize = 0;
    while (i + fmt.block <= in.len) : (i += fmt.block) {
        for (0..out_channels) |c| {
            const s = in[i + c * size ..][0..size];
            const v: i16 = switch (fmt.bits) {
                8 => @as(i16, @as(i16, s[0]) - 128) << 8,
                16 => std.mem.readInt(i16, s[0..2], .little),
                24 => @intCast(std.mem.readInt(i24, s[0..3], .little) >> 8),
                else => if (fmt.tag == 3)
                    @intFromFloat(std.math.clamp(@as(f32, @bitCast(std.mem.readInt(u32, s[0..4], .little))), -1.0, 1.0) * 32767.0)
                else
                    @intCast(std.mem.readInt(i32, s[0..4], .little) >> 16),
            };
            std.mem.writeInt(i16, out_buf[w..][0..2], v, .little);
            w += 2;
        }
    }
    return out_buf[0..w];
}

fn readAll(f: zdos.File, buf: []u8) bool {
    return readSome(f, buf) == buf.len;
}

fn readSome(f: zdos.File, buf: []u8) usize {
    var got: usize = 0;
    while (got < buf.len) {
        const n = f.read(buf[got..]) catch break;
        if (n == 0) break;
        got += n;
    }
    return got;
}

fn skip(f: zdos.File, n: u64) bool {
    var left = n;
    var b: [512]u8 = undefined;
    while (left > 0) {
        const k: usize = @intCast(@min(left, b.len));
        if (!readAll(f, b[0..k])) return false;
        left -= k;
    }
    return true;
}

fn bad(why: []const u8) u8 {
    zdos.printf("PLAY: {s}\n", .{why});
    return 1;
}
