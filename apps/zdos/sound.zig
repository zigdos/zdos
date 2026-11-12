// Sound (group sound): the PC speaker; samples need a sound card's
// driver (not_supported without one).
const zdos = @import("zdos.zig");

const Error = zdos.Error;

fn api() *const zdos.Api {
    return zdos.table();
}

// 20-20000 Hz until the next call; 0: silence.
pub fn tone(hz: u32) Error!void {
    return zdos.check(api().sound.tone(hz));
}

// A short pulse per period: quieter on a real speaker, silent in QEMU
// (it plays only square waves).
pub fn softTone(hz: u32) Error!void {
    return zdos.check(api().sound.soft_tone(hz));
}

pub fn beep(hz: u32, ms: u32) Error!void {
    return zdos.check(api().sound.beep(hz, ms));
}

// rate Hz, channels 1-2, bits 8 or 16 (interleaved).
pub const Output = struct {
    handle: i32,

    pub fn write(self: Output, data: []const u8) Error!usize {
        const n = api().sound.write(self.handle, data.ptr, data.len);
        if (n < 0) return zdos.lastError();
        return @intCast(n);
    }

    // Queued and not yet heard.
    pub fn queued(self: Output) usize {
        return api().sound.queued(self.handle);
    }

    // Plays what is queued first, unless drop.
    pub fn close(self: Output, drop: bool) void {
        api().sound.close(self.handle, drop);
    }
};

pub fn open(rate: u32, channels: u32, bits: u32) Error!Output {
    const h = api().sound.open(rate, channels, bits);
    if (h < 0) return zdos.lastError();
    return .{ .handle = h };
}

pub fn setVolume(percent: u32) Error!void {
    return zdos.check(api().sound.set_volume(percent));
}

// 0-100; null without a card.
pub fn volume() ?u32 {
    const v = api().sound.volume();
    return if (v < 0) null else @intCast(v);
}
