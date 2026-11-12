// SU [-] [USER] [-c COMMAND]: as Unix su, root by default
// Becoming root is for the group ADMINS only (as BSD's wheel).
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

var list: users.List = .{};
var groups: users.Groups = .{};

pub fn main(args: []const u8) u8 {
    var to_home = false;
    var target_name: []const u8 = "ROOT";
    var command: ?[]const u8 = null;
    var rest = std.mem.trim(u8, args, " \t");
    while (rest.len > 0) {
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const word = rest[0..end];
        if (std.mem.eql(u8, word, "-") or std.mem.eql(u8, word, "-l")) {
            to_home = true;
        } else if (std.mem.eql(u8, word, "-c")) {
            command = std.mem.trim(u8, rest[end..], " \t");
            break;
        } else if (word[0] == '-') {
            zdos.print("SU [-] [USER] [-c COMMAND]\n");
            return 1;
        } else {
            target_name = word;
        }
        rest = std.mem.trim(u8, rest[end..], " \t");
    }

    users.load(&list) catch |err| return failed("users", err);
    users.loadGroups(&groups) catch |err| return failed("groups", err);
    const caller = users.realUser(&list) orelse {
        zdos.print("SU: who are you? (your user isn't in USERS.CFG)\n");
        return 1;
    };
    const target = list.find(target_name) orelse {
        zdos.printf("SU: no user {s}\n", .{target_name});
        return 1;
    };
    if (caller.uid != 0) {
        if (target.uid == 0 and !groups.isMember(users.admins, caller.name)) {
            zdos.print("SU: only the group ADMINS may become root\n");
            return 1;
        }
        if (target.password.len > 0) {
            zdos.print("Password: ");
            var pw_buf: [128]u8 = undefined;
            defer users.wipe(&pw_buf);
            const pw = users.readLine(&pw_buf, true) orelse return 1;
            if (!users.checkPassword(target.password, pw)) {
                zdos.sleep(1000);
                zdos.print("SU: wrong password\n");
                return 1;
            }
            users.upgradeHash(&list, target, pw);
        }
    }

    var saved: users.SavedVars = .{};
    users.setUserVars(target, &saved);
    defer users.restoreVars(&saved);
    // Root stays saved: the variables go back as root after the command;
    // what the command starts can't get root back.
    users.become(target, zdos.keep_id) catch |err| return failed("switching", err);
    defer zdos.setIds(.{ .real = zdos.keep_id, .uid = 0, .saved = zdos.keep_id, .gid = zdos.keep_id, .group_count = zdos.keep_groups, .groups = undefined }) catch {};
    if (to_home) {
        var home_buf: [300]u8 = undefined;
        const home = users.homeOf(target.name, &home_buf);
        zdos.setCwd(home) catch |err| zdos.printf("{s}: {s}\n", .{ home, zdos.message(err) });
    }
    if (command) |line| return zdos.runCommand(line) catch |err| failed("running", err);
    var shell_buf: [300]u8 = undefined;
    const shell = if (target.shell.len > 0) target.shell else zdos.getVar("COMSPEC", &shell_buf) orelse "C:\\APPS\\COMMAND.APP";
    return zdos.exec(shell, "") catch |err| failed(shell, err);
}

fn failed(what: []const u8, err: zdos.Error) u8 {
    zdos.printf("SU: {s}: {s}\n", .{ what, zdos.message(err) });
    return 1;
}
