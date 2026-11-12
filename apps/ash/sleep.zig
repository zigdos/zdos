const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const errout = @import("errout.zig");

pub fn run(args: []const []const u8) u8 {
    if (args.len != 1) {
        errout.print("usage: sleep SECONDS\n");
        return 2;
    }
    const seconds = std.fmt.parseFloat(f64, args[0]) catch {
        errout.printf("sleep: invalid duration: {s}\n", .{args[0]});
        return 2;
    };
    if (!std.math.isFinite(seconds) or seconds < 0) {
        errout.printf("sleep: invalid duration: {s}\n", .{args[0]});
        return 2;
    }
    const milliseconds = @ceil(seconds * 1000.0);
    if (milliseconds >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
        errout.print("sleep: duration is too large\n");
        return 2;
    }
    var remaining: u64 = @intFromFloat(milliseconds);
    while (remaining > std.math.maxInt(u32)) {
        zdos.sleep(std.math.maxInt(u32));
        remaining -= std.math.maxInt(u32);
    }
    if (remaining > 0) zdos.sleep(@intCast(remaining));
    return 0;
}
