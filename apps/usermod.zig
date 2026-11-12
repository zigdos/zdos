// USERMOD NAME -g GROUPS | -s SHELL | -u UID: changes a user. Root only.
// -u moves the home folder along; other files keep the old number.
// Takes effect at the user's next login.
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
    var shell: ?[]const u8 = null;
    var group_list: ?[]const u8 = null;
    var uid: ?u32 = null;
    while (words.next()) |sw| {
        const value = words.next() orelse return usage();
        const v = if (std.mem.eql(u8, value, "\"\"")) "" else value;
        if (std.ascii.eqlIgnoreCase(sw, "-s")) {
            shell = v;
        } else if (std.ascii.eqlIgnoreCase(sw, "-g")) {
            group_list = v;
        } else if (std.ascii.eqlIgnoreCase(sw, "-u")) {
            uid = users.List.parseUid(v) orelse {
                zdos.printf("USERMOD: {s} is no user number (1 and up; 0 is root)\n", .{v});
                return 1;
            };
        } else return usage();
    }
    if (shell == null and group_list == null and uid == null) return usage();
    if (!users.isRoot()) {
        zdos.print("USERMOD: only root changes users (SUDO USERMOD ...)\n");
        return 1;
    }
    users.load(&list) catch |err| return failed(err);
    users.loadGroups(&groups) catch |err| return failed(err);
    const u = list.find(name) orelse {
        zdos.printf("USERMOD: no user {s}\n", .{name});
        return 1;
    };
    if (shell) |s| {
        if (std.mem.indexOfScalar(u8, s, ':')) |colon| {
            if (colon != 1 or std.mem.indexOfScalarPos(u8, s, 2, ':') != null) {
                zdos.print("USERMOD: the shell's path can't have ':' except after the drive\n");
                return 1;
            }
        }
        u.shell = list.keep(s) orelse return 1;
        users.save(&list) catch |err| return failed(err);
    }
    if (uid) |n| {
        if (u.uid == 0) {
            zdos.print("USERMOD: root stays 0\n");
            return 1;
        }
        if (list.findUid(n)) |other| {
            if (other != u) {
                zdos.printf("USERMOD: {d} is {s}'s number\n", .{ n, other.name });
                return 1;
            }
        }
        const old = u.uid;
        u.uid = n;
        users.save(&list) catch |err| return failed(err);
        // The home folder follows (where owners are kept), group too if it was
        // the user's own:
        var home_buf: [300]u8 = undefined;
        const home = users.homeOf(u.name, &home_buf);
        zdos.setOwner(home, n, n) catch {};
        zdos.printf("{s}: number {d} -> {d}; other files of {d} keep it (chown -R {s} PATH)\n", .{ u.name, old, n, old, u.name });
    }
    if (group_list) |g| {
        if (!groups.setMembership(u.name, g)) {
            zdos.print("USERMOD: unusable group names, or too many groups\n");
            return 1;
        }
        users.saveGroups(&groups) catch |err| return failed(err);
    }
    zdos.printf("User {s} changed\n", .{u.name});
    return 0;
}

fn failed(err: zdos.Error) u8 {
    zdos.printf("USERMOD: {s}\n", .{zdos.message(err)});
    return 1;
}

fn usage() u8 {
    zdos.print("USERMOD NAME [-g GROUP,GROUP] [-s SHELL] [-u UID]\n");
    return 1;
}
