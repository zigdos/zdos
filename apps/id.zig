// ID: the user and groups the shell runs as, as Unix's id
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

var list: users.List = .{};
var groups: users.Groups = .{};

pub fn main(_: []const u8) u8 {
    users.load(&list) catch {};
    users.loadGroups(&groups) catch {};
    const ids = zdos.getIds();
    zdos.printf("uid={d}({s}) gid={d}({s})", .{ ids.real, userName(ids.real), ids.gid, groupName(ids.gid) });
    if (ids.uid != ids.real) zdos.printf(" euid={d}({s})", .{ ids.uid, userName(ids.uid) });
    zdos.printf(" groups={d}({s})", .{ ids.gid, groupName(ids.gid) });
    for (ids.groups[0..@min(ids.group_count, ids.groups.len)]) |g| {
        if (g != ids.gid) zdos.printf(",{d}({s})", .{ g, groupName(g) });
    }
    zdos.print("\n");
    return 0;
}

fn userName(uid: u32) []const u8 {
    return if (list.findUid(uid)) |u| u.name else "?";
}

// Else the user's of the same number (their own group).
fn groupName(gid: u32) []const u8 {
    for (groups.groups[0..groups.count]) |g| {
        if (g.gid == gid) return g.name;
    }
    return userName(gid);
}
