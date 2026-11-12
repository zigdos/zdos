// DELUSER NAME [-r]: removes a user; -r also its home folder. Root only.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

var list: users.List = .{};
var groups: users.Groups = .{};

pub fn main(args: []const u8) u8 {
    var words = std.mem.tokenizeAny(u8, args, " \t");
    const name = words.next() orelse return usage();
    var remove_home = false;
    if (words.next()) |sw| {
        if (!std.ascii.eqlIgnoreCase(sw, "-r")) return usage();
        remove_home = true;
    }
    if (!users.isRoot()) {
        zdos.print("DELUSER: only root removes users (SUDO DELUSER ...)\n");
        return 1;
    }
    var me_buf: [64]u8 = undefined;
    if (std.ascii.eqlIgnoreCase(name, "root") or std.ascii.eqlIgnoreCase(name, users.current(&me_buf))) {
        zdos.print("DELUSER: root and the current user stay\n");
        return 1;
    }
    users.load(&list) catch |err| {
        zdos.printf("DELUSER: {s}\n", .{zdos.message(err)});
        return 1;
    };
    var name_buf: [users.max_name]u8 = undefined;
    const u = list.find(name) orelse {
        zdos.printf("DELUSER: no user {s}\n", .{name});
        return 1;
    };
    const real_name = name_buf[0..u.name.len];
    @memcpy(real_name, u.name);
    _ = list.remove(name);
    users.save(&list) catch |err| {
        zdos.printf("DELUSER: {s}\n", .{zdos.message(err)});
        return 1;
    };
    if (users.loadGroups(&groups)) {
        if (groups.setMembership(real_name, "")) users.saveGroups(&groups) catch {};
    } else |_| {}
    var home_buf: [300]u8 = undefined;
    const home = users.homeOf(real_name, &home_buf);
    if (remove_home) {
        zdos.deleteTree(home) catch |err| switch (err) {
            error.NotFound, error.PathNotFound => {},
            else => zdos.printf("DELUSER: {s}: {s}\n", .{ home, zdos.message(err) }),
        };
        zdos.printf("User {s} and {s} removed\n", .{ real_name, home });
    } else {
        zdos.printf("User {s} removed ({s} stays)\n", .{ real_name, home });
    }
    return 0;
}

fn usage() u8 {
    zdos.print("DELUSER NAME [-r]\n");
    return 1;
}
