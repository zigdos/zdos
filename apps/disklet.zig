// DISKLET: gives every drive without a letter one, until restart.
// Exit code 1 if all had one already. Root only.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    _ = args;
    if (!users.isRoot()) {
        zdos.print("DISKLET: only root gives drives letters (SUDO DISKLET)\n");
        return 1;
    }
    const given = sys.assignLetters();
    if (given == 0) zdos.print("All drives already have a letter\n");
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
            zdos.printf("{s:<12}{s:<7}{d:>8} MB", .{ info.label(), if (kind.len > 0) kind else "?", info.size / (1024 * 1024) });
        } else if (info.floppy) {
            zdos.print("(no disk)");
        }
        if (info.unreadable) zdos.print("   (not readable)");
        if (info.boot) zdos.print("   (boot)");
        if (info.system) zdos.print("   (system)");
        if (info.hidden) zdos.print("   (hidden)");
        zdos.print("\n");
    }
    return if (given > 0) 0 else 1;
}
