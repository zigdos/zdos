// VOLUME [0-100]: the sound card's output volume, for every program
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const sound = @import("zdos/sound.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    const arg = std.mem.trim(u8, args, " \t");
    if (arg.len > 0) {
        const percent = std.fmt.parseInt(u32, std.mem.trimRight(u8, arg, "%"), 10) catch 101;
        if (percent > 100) {
            zdos.print("Usage: VOLUME [0-100]\n");
            return 1;
        }
        sound.setVolume(percent) catch |err| {
            zdos.printf("VOLUME: {s}\n", .{if (err == error.NotSupported) "no sound card" else zdos.message(err)});
            return 1;
        };
    }
    const v = sound.volume() orelse {
        zdos.print("VOLUME: no sound card\n");
        return 1;
    };
    zdos.printf("Volume {d}%\n", .{v});
    return 0;
}
