// SCREEN: the firmware's screen modes, the one in use in brackets
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const gfx = @import("zdos/gfx.zig");

comptime {
    _ = zdos;
}

const columns = 4;

pub fn main(_: []const u8) u8 {
    var buf: [64]gfx.ScreenSize = undefined;
    const modes = gfx.modes(&buf);
    if (modes.len == 0) {
        zdos.print("No screen modes known (no graphics)\n");
        return 1;
    }
    const now = gfx.screen() catch null;
    zdos.print("Screen modes (for RESOLUTION in SYSTEM.CFG); [res] is current\n");
    // Down the columns, smallest first:
    const rows = (modes.len + columns - 1) / columns;
    for (0..rows) |r| {
        for (0..columns) |c| {
            const i = c * rows + r;
            if (i >= modes.len) break;
            const m = modes[i];
            const current = if (now) |s| s.width == m.width and s.height == m.height else false;
            // " WxH " or "[WxH]", so the sizes stay in line:
            var text: [24]u8 = undefined;
            const open: u8 = if (current) '[' else ' ';
            const close: u8 = if (current) ']' else ' ';
            const cell = std.fmt.bufPrint(&text, "{c}{d}x{d}{c}", .{ open, m.width, m.height, close }) catch "?";
            if (c > 0) zdos.print("   ");
            zdos.printf("{s: <11}", .{cell});
        }
        zdos.print("\n");
    }
    return 0;
}
