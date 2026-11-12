// DRIVES: every drive, also those without a letter.
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    _ = args;
    if (sys.driveAt(0) == null) {
        zdos.print("No drives found\n");
        return 1;
    }
    zdos.print("Drives:\n");
    var index: u32 = 0;
    while (sys.driveAt(index)) |info| : (index += 1) {
        if (info.letter != 0) zdos.printf("  {c}:  ", .{info.letter}) else zdos.print("  --  ");
        if (info.ready or info.unreadable) {
            const kind = zdos.fileSystemName(info.file_system);
            zdos.printf("{s:<12}{s:<7}{d:>8} MB", .{ info.label(), if (kind.len > 0) kind else "unknown", info.size / (1024 * 1024) });
        } else if (info.floppy or info.removable) {
            zdos.print("(no disk)");
        }
        if (info.unreadable) zdos.print("   (not readable)");
        if (info.boot) zdos.print("   (boot)");
        if (info.system) zdos.print("   (system)");
        if (info.hidden) zdos.print("   (hidden)");
        zdos.print("\n");
    }
    return 0;
}
