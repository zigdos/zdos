// ash: a POSIX-style command interpreter
const zdos = @import("zdos/zdos.zig");
const shell = @import("ash/shell.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    return shell.run(args);
}
