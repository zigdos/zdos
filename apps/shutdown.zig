const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    _ = args;
    if (!users.isAdmin()) {
        zdos.print("SHUTDOWN: only admins may turn off the computer (SUDO SHUTDOWN)\n");
        return 1;
    }
    sys.shutdown();
}
