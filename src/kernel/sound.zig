// Samples to the sound card a driver registered, converted to
// 16-bit stereo and, where the card lacks the rate, resampled
// linearly to 48000 or 44100 Hz. One program at a time. While
// it plays, a task asks the card every 10 ms and silences what
// has played, so a paused program is quiet, not a repeated
// buffer; it sleeps while nothing plays.
const std = @import("std");
const drv = @import("drv.zig");
const drivers = @import("drivers.zig");
const tasks = @import("tasks.zig");
const platform = @import("../platform.zig");

pub const Error = error{ NotSupported, InvalidArgument, AccessDenied, InvalidHandle };

const handle_id = 1; // the one output
const one: u32 = 1 << 16; // resampling positions in 16.16

var owner: ?*const anyopaque = null; // the program (api.Program) playing
var in_rate: u32 = 0;
var in_channels: u32 = 0;
var in_bits: u32 = 0;
var out_rate: u32 = 0;
var volume: u32 = 80;
var task_started = false;
// Counts opens: the task waits on it while nothing plays
var starts = std.atomic.Value(u32).init(0);

// A frame split across writes, and the resampler's state
var partial: [4]u8 = undefined;
var partial_len: usize = 0;
var step: u32 = one;
var frac: u32 = 0;
var last: [2]i16 = .{ 0, 0 };
var have_last = false;

fn card() Error!*const drv.SoundCard {
    return drivers.sound_card orelse error.NotSupported;
}

pub fn open(program: *const anyopaque, rate: u32, channels: u32, bits: u32) Error!i32 {
    const c = try card();
    if (rate < 8000 or rate > 192_000 or (channels != 1 and channels != 2) or (bits != 8 and bits != 16)) return error.InvalidArgument;
    if (owner) |o| {
        if (o != program) return error.AccessDenied;
        c.stop(c.ctx);
    }
    out_rate = if (c.start(c.ctx, rate)) rate else if (c.start(c.ctx, 48_000)) 48_000 else if (c.start(c.ctx, 44_100)) 44_100 else return error.NotSupported;
    c.set_volume(c.ctx, volume);
    owner = program;
    in_rate = rate;
    in_channels = channels;
    in_bits = bits;
    partial_len = 0;
    step = @intCast((@as(u64, rate) << 16) / out_rate);
    frac = 0;
    have_last = false;
    if (!task_started) task_started = tasks.kernelTask(&pollMain, 0, "SOUND", 20) != null;
    _ = starts.fetchAdd(1, .acq_rel);
    tasks.wake(&starts);
    return handle_id;
}

fn mine(program: *const anyopaque, handle: i32) Error!*const drv.SoundCard {
    const c = try card();
    if (handle != handle_id or owner != program) return error.InvalidHandle;
    return c;
}

// The samples, converted, into the card: waits while
// its buffer is full. The bytes taken (fewer if a
// signal ended the wait).
pub fn write(program: *const anyopaque, handle: i32, data: []const u8) Error!usize {
    const c = try mine(program, handle);
    const frame = in_channels * in_bits / 8;
    var out: [4096]u8 align(2) = undefined;
    var done: usize = 0;
    while (done < data.len) {
        // As many input bytes as give at most out's frames
        const room_frames = out.len / 4;
        const max_in_frames = @max(1, (@as(u64, room_frames) * in_rate / out_rate) -| 2);
        const chunk = @min(data.len - done, @as(usize, @intCast(max_in_frames)) * frame);
        const n = convert(data[done..][0..chunk], frame, &out);
        if (!feed(c, program, out[0..n])) return done + chunk; // a signal, or closed: what is queued stays
        done += chunk;
    }
    return done;
}

// Every byte of out into the card, waiting while it is full;
// false if a signal ended the wait or the program's other
// thread closed the card meanwhile
fn feed(c: *const drv.SoundCard, program: *const anyopaque, out: []const u8) bool {
    var at: usize = 0;
    while (at < out.len) {
        const n = c.write(c.ctx, out[at..].ptr, out.len - at);
        at += n;
        if (n > 0) continue;
        if (!pause(2)) return false;
        if (owner != program) return false;
    }
    return true;
}

// A wait for the card with the kernel lock given up: else
// the console, keys (Ctrl+C) and the program's other threads
// wait as long as the card is full
fn pause(ms: u32) bool {
    const held = tasks.dropKernel();
    defer if (held) {
        _ = tasks.enterKernel();
    };
    return tasks.sleep(ms);
}

// Input bytes (whole frames, with any left from the last write)
// as 16-bit stereo frames at out_rate: the bytes put into out
fn convert(data: []const u8, frame: usize, out: *[4096]u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (true) {
        var f: [4]u8 = undefined;
        if (partial_len > 0) {
            const need = frame - partial_len;
            if (data.len - i < need) {
                @memcpy(partial[partial_len..][0 .. data.len - i], data[i..]);
                partial_len += data.len - i;
                break;
            }
            @memcpy(f[0..partial_len], partial[0..partial_len]);
            @memcpy(f[partial_len..frame], data[i..][0..need]);
            i += need;
            partial_len = 0;
        } else if (data.len - i >= frame) {
            @memcpy(f[0..frame], data[i..][0..frame]);
            i += frame;
        } else {
            @memcpy(partial[0 .. data.len - i], data[i..]);
            partial_len = data.len - i;
            break;
        }
        const cur = sample(&f);
        if (in_rate == out_rate) {
            w = put(out, w, cur);
            continue;
        }
        if (!have_last) {
            last = cur;
            have_last = true;
            continue;
        }
        while (frac < one and w + 4 <= out.len) : (frac += step) {
            var s: [2]i16 = undefined;
            for (0..2) |ch| s[ch] = @intCast(@as(i32, last[ch]) + @divTrunc((@as(i32, cur[ch]) - last[ch]) * @as(i32, @intCast(frac)), @as(i32, one)));
            w = put(out, w, s);
        }
        frac -|= one;
        last = cur;
    }
    return w;
}

// A frame as 16-bit stereo (8-bit is unsigned)
fn sample(f: *const [4]u8) [2]i16 {
    var s: [2]i16 = undefined;
    for (0..in_channels) |ch| {
        s[ch] = if (in_bits == 8)
            @as(i16, @as(i16, f[ch]) - 128) << 8
        else
            std.mem.readInt(i16, f[ch * 2 ..][0..2], .little);
    }
    if (in_channels == 1) s[1] = s[0];
    return s;
}

fn put(out: *[4096]u8, w: usize, s: [2]i16) usize {
    std.mem.writeInt(i16, out[w..][0..2], s[0], .little);
    std.mem.writeInt(i16, out[w + 2 ..][0..2], s[1], .little);
    return w + 4;
}

// Bytes not yet heard, in the program's format
pub fn queued(program: *const anyopaque, handle: i32) Error!usize {
    const c = try mine(program, handle);
    const out_bytes = c.queued(c.ctx);
    return @intCast(@as(u64, out_bytes / 4) * in_rate / out_rate * (in_channels * in_bits / 8));
}

// Plays what is queued (unless drop, or a signal ends the wait;
// a card that stops playing, after
// that time and a second), then ends
pub fn close(program: *const anyopaque, handle: i32, drop: bool) Error!void {
    const c = try mine(program, handle);
    if (!drop) {
        const until = platform.clock.millis() + c.queued(c.ctx) / 4 * 1000 / out_rate + 1000;
        while (c.queued(c.ctx) > 0 and platform.clock.millis() < until) {
            if (!pause(5)) break;
            if (owner != program) return; // closed meanwhile
        }
    }
    c.stop(c.ctx);
    owner = null;
}

// A program ended: its output stops
pub fn programEnded(program: *const anyopaque) void {
    if (owner != program) return;
    const c = drivers.sound_card orelse return;
    c.stop(c.ctx);
    owner = null;
}

pub fn setVolume(percent: u32) Error!void {
    const c = try card();
    volume = @min(percent, 100);
    c.set_volume(c.ctx, volume);
}

// VOLUME= in SYSTEM.CFG: the level from startup on (a card
// applies it when a program opens it)
pub fn startVolume(percent: u32) void {
    volume = @min(percent, 100);
    if (drivers.sound_card) |c| c.set_volume(c.ctx, volume);
}

pub fn getVolume() Error!u32 {
    _ = try card();
    return volume;
}

fn pollMain(_: usize) callconv(.c) noreturn {
    while (true) {
        const seen = starts.load(.acquire);
        const took = tasks.enterKernel();
        const playing = owner != null;
        if (playing) {
            if (drivers.sound_card) |c| _ = c.queued(c.ctx);
        }
        if (took) tasks.leaveKernel();
        // Until a program opens the card (no wake-up lost: the
        // count is checked again before sleeping):
        if (!playing) {
            _ = tasks.waitObjectSince(&starts, null, &starts, seen);
            continue;
        }
        _ = tasks.sleep(10);
    }
}
