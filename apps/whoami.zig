// WHOAMI: the effective user (root inside SU or SUDO)
const zdos = @import("zdos/zdos.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

var list: users.List = .{};

pub fn main(_: []const u8) u8 {
    users.load(&list) catch {};
    const uid = zdos.getIds().uid;
    if (list.findUid(uid)) |u| {
        zdos.printf("{s}\n", .{u.name});
    } else {
        zdos.printf("{d}\n", .{uid});
    }
    return 0;
}
