// ADDUSER [NAME [-s SHELL] [-g GROUPS] [-u UID]]: USERS IN USERS.CFG
// Without arguments lists them. Root only.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

var list: users.List = .{};
var groups: users.Groups = .{};

pub fn main(args: []const u8) u8 {
    users.load(&list) catch |err| return failed(err);
    users.loadGroups(&groups) catch |err| return failed(err);
    var words = std.mem.tokenizeAny(u8, args, " \t");
    const name = words.next() orelse {
        zdos.print("USER      UID  PASSWORD SHELL                GROUPS\n");
        for (list.users[0..list.count]) |u| {
            const has_pw = if (!list.passwords_known) "?" else if (u.password.len > 0) "yes" else "no";
            zdos.printf("{s:<9} {d:>4}  {s:<8} {s:<20} ", .{ u.name, u.uid, has_pw, if (u.shell.len > 0) u.shell else "(COMMAND)" });
            var first = true;
            for (groups.groups[0..groups.count]) |g| {
                if (!groups.isMember(g.name, u.name)) continue;
                zdos.printf("{s}{s}", .{ if (first) "" else ",", g.name });
                first = false;
            }
            zdos.print("\n");
        }
        return 0;
    };
    var shell: []const u8 = "";
    var group_list: []const u8 = "";
    var uid: ?u32 = null;
    while (words.next()) |sw| {
        if (std.ascii.eqlIgnoreCase(sw, "-s")) {
            shell = words.next() orelse return usage();
        } else if (std.ascii.eqlIgnoreCase(sw, "-g")) {
            group_list = words.next() orelse return usage();
        } else if (std.ascii.eqlIgnoreCase(sw, "-u")) {
            const text = words.next() orelse return usage();
            uid = users.List.parseUid(text) orelse {
                zdos.printf("ADDUSER: {s} is no user number (1 and up; 0 is root)\n", .{text});
                return 1;
            };
        } else return usage();
    }
    if (!users.isRoot()) {
        zdos.print("ADDUSER: only root adds users (SUDO ADDUSER ...)\n");
        return 1;
    }
    if (!users.validName(name)) {
        zdos.print("ADDUSER: a name is letters, digits, _ . - (up to 32), starting with a letter or _\n");
        return 1;
    }
    if (list.find(name) != null) {
        zdos.printf("ADDUSER: {s} exists (USERMOD changes a user)\n", .{name});
        return 1;
    }
    if (!validShell(shell)) return 1;
    if (uid) |n| {
        if (list.findUid(n)) |other| {
            zdos.printf("ADDUSER: {d} is {s}'s number\n", .{ n, other.name });
            return 1;
        }
    }
    var pw_buf: [256]u8 = undefined;
    defer users.wipe(&pw_buf);
    zdos.printf("Password of {s}\n", .{name});
    const pw = users.askNewPassword(&pw_buf) orelse return 1;
    var hash_buf: [128]u8 = undefined;
    const user: users.User = .{
        .name = list.keep(name) orelse return 1,
        .uid = uid orelse list.nextUid(),
        .password = list.keep(users.hashPassword(pw, &hash_buf)) orelse return 1,
        .shell = list.keep(shell) orelse return 1,
    };
    if (!list.add(user)) {
        zdos.print("ADDUSER: too many users\n");
        return 1;
    }
    if (!groups.setMembership(user.name, group_list)) {
        zdos.print("ADDUSER: unusable group names, or too many groups\n");
        return 1;
    }
    users.save(&list) catch |err| return failed(err);
    users.saveGroups(&groups) catch |err| return failed(err);
    var home_buf: [300]u8 = undefined;
    const home = users.makeHome(&user, &home_buf);
    zdos.printf("User {s} added (uid {d}), home {s}\n", .{ user.name, user.uid, home });
    return 0;
}

// ':' only after the drive: it separates the fields.
pub fn validShell(shell: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, shell, ':') orelse return true;
    if (colon == 1 and std.mem.indexOfScalarPos(u8, shell, 2, ':') == null) return true;
    zdos.print("The shell's path can't have ':' except after the drive\n");
    return false;
}

fn failed(err: zdos.Error) u8 {
    zdos.printf("ADDUSER: {s}\n", .{zdos.message(err)});
    return 1;
}

fn usage() u8 {
    zdos.print("ADDUSER [NAME [-s SHELL] [-g GROUP,GROUP] [-u UID]]\n");
    return 1;
}
