const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    _ = args;
    if (!users.isAdmin()) {
        zdos.print("REBOOT: only admins may restart the computer (SUDO REBOOT)\n");
        return 1;
    }
    sys.restart();
}
