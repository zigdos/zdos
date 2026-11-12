// SUDO [-u USER] COMMAND | -k: as Unix sudo, for the group ADMINS
// The password is asked again after 5 minutes (\CONF\SUDO).
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

var list: users.List = .{};
var groups: users.Groups = .{};

const grace_minutes = 5;

pub fn main(args: []const u8) u8 {
    var rest = std.mem.trim(u8, args, " \t");
    var target_name: []const u8 = "ROOT";
    var forget = false;
    while (rest.len > 0 and rest[0] == '-') {
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const word = rest[0..end];
        rest = std.mem.trim(u8, rest[end..], " \t");
        if (std.mem.eql(u8, word, "-u")) {
            const e = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
            target_name = rest[0..e];
            rest = std.mem.trim(u8, rest[e..], " \t");
        } else if (std.mem.eql(u8, word, "-k")) {
            forget = true;
        } else {
            return usage();
        }
    }
    if (rest.len == 0 and !forget) return usage();

    users.load(&list) catch |err| return failed("users", err);
    users.loadGroups(&groups) catch |err| return failed("groups", err);
    const caller = users.realUser(&list) orelse {
        zdos.print("SUDO: who are you? (your user isn't in USERS.CFG)\n");
        return 1;
    };
    if (forget) {
        var stamp_buf: [300]u8 = undefined;
        zdos.delete(stampPath(caller.name, &stamp_buf)) catch {};
        if (rest.len == 0) return 0;
    }
    if (caller.uid != 0 and !groups.isMember(users.admins, caller.name)) {
        zdos.printf("SUDO: {s} is not in the group ADMINS\n", .{caller.name});
        return 1;
    }
    const target = list.find(target_name) orelse {
        zdos.printf("SUDO: no user {s}\n", .{target_name});
        return 1;
    };
    if (caller.uid != 0 and caller.password.len > 0 and !recent(caller.name)) {
        zdos.printf("[sudo] password for {s}: ", .{caller.name});
        var pw_buf: [128]u8 = undefined;
        defer users.wipe(&pw_buf);
        const pw = users.readLine(&pw_buf, true) orelse return 1;
        if (!users.checkPassword(caller.password, pw)) {
            zdos.sleep(1000);
            zdos.print("SUDO: wrong password\n");
            return 1;
        }
        users.upgradeHash(&list, caller, pw);
    }
    stamp(caller.name);

    var saved: users.SavedVars = .{};
    var sudo_user_buf: [64]u8 = undefined;
    const old_sudo_user = zdos.getVar("SUDO_USER", &sudo_user_buf);
    users.setUserVars(target, &saved);
    zdos.setVar("SUDO_USER", caller.name) catch {};
    defer {
        users.restoreVars(&saved);
        zdos.setVar("SUDO_USER", old_sudo_user orelse "") catch {};
    }
    // Root stays saved: the variables go back as root after the command;
    // what the command starts can't get root back.
    users.become(target, zdos.keep_id) catch |err| return failed("switching", err);
    defer zdos.setIds(.{ .real = zdos.keep_id, .uid = 0, .saved = zdos.keep_id, .gid = zdos.keep_id, .group_count = zdos.keep_groups, .groups = undefined }) catch {};
    return zdos.runCommand(rest) catch |err| failed("running", err);
}

fn usage() u8 {
    zdos.print("SUDO [-u USER] COMMAND...   SUDO -k: ask for the password next time\n");
    return 1;
}

fn failed(what: []const u8, err: zdos.Error) u8 {
    zdos.printf("SUDO: {s}: {s}\n", .{ what, zdos.message(err) });
    return 1;
}

// \CONF\SUDO\<name>: the minute of the last password.

fn stampPath(name: []const u8, buf: []u8) []const u8 {
    var users_buf: [300]u8 = undefined;
    const cfg = users.filePath(&users_buf); // C:\CONF\USERS.CFG
    const dir = cfg[0 .. cfg.len - "USERS.CFG".len];
    return std.fmt.bufPrint(buf, "{s}SUDO\\{s}", .{ dir, name }) catch "";
}

// Minutes since 2000, near enough to compare.
fn minuteNow() u64 {
    const t = zdos.getTime();
    const days = (@as(u64, t.year) -| 2000) * 372 + @as(u64, t.month) * 31 + t.day;
    return days * 1440 + @as(u64, t.hour) * 60 + t.minute;
}

fn recent(name: []const u8) bool {
    var path_buf: [300]u8 = undefined;
    const f = zdos.open(stampPath(name, &path_buf), .read) catch return false;
    defer f.close();
    var buf: [24]u8 = undefined;
    const n = f.read(&buf) catch return false;
    const then = std.fmt.parseInt(u64, std.mem.trim(u8, buf[0..n], " \r\n"), 10) catch return false;
    const now = minuteNow();
    return now >= then and now - then < grace_minutes;
}

fn stamp(name: []const u8) void {
    var path_buf: [300]u8 = undefined;
    const path = stampPath(name, &path_buf);
    // Root's alone, where the drive keeps modes:
    const dir = path[0 .. path.len - name.len - 1];
    if (zdos.makeDir(dir)) zdos.setMode(dir, 0o700) catch {} else |_| {}
    const f = zdos.open(path, .write) catch return;
    defer f.close();
    var buf: [24]u8 = undefined;
    f.writeAll(std.fmt.bufPrint(&buf, "{d}\n", .{minuteNow()}) catch return) catch {};
}
