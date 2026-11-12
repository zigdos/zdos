// PLAY FILE.WAV [VOLUME]: PCM 8-32 bits or float, mono or stereo
// 24 and 32 bits are played as 16; of more channels the first two.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const sound = @import("zdos/sound.zig");

comptime {
    _ = zdos;
}

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
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    const name = words.next() orelse {
        zdos.print("Usage: PLAY file.wav [volume 0-100]\n");
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
    if (!readAll(f, &head) or !std.mem.eql(u8, head[0..4], "RIFF") or !std.mem.eql(u8, head[8..12], "WAVE")) return bad("not a WAV file");
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
        name,                                                      fmt.rate, fmt.bits, if (fmt.tag == 3) " float" else "",
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
        var at: usize = 0;
        while (at < bytes.len) at += out.write(bytes[at..]) catch break;
    }
    out.close(false);
    return 0;
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
