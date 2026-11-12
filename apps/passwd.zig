// PASSWD [NAME]: changes a password in USERS.CFG (another's: root only)
// An empty new password removes it.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

var list: users.List = .{};

pub fn main(args: []const u8) u8 {
    users.load(&list) catch |err| {
        zdos.printf("PASSWD: {s}\n", .{zdos.message(err)});
        return 1;
    };
    const caller = users.realUser(&list) orelse {
        zdos.print("PASSWD: who are you? (your user isn't in USERS.CFG)\n");
        return 1;
    };
    var me_buf: [users.max_name]u8 = undefined;
    const me = me_buf[0..caller.name.len];
    @memcpy(me, caller.name);
    const caller_is_root = caller.uid == 0;
    const arg = std.mem.trim(u8, args, " \t");
    const name = if (arg.len > 0) arg else me;
    const u = list.find(name) orelse {
        zdos.printf("PASSWD: no user {s}\n", .{name});
        return 1;
    };
    if (!std.ascii.eqlIgnoreCase(name, me) and !caller_is_root) {
        zdos.print("PASSWD: only root changes another user's password\n");
        return 1;
    }
    if (!caller_is_root and u.password.len > 0) {
        zdos.print("Old password: ");
        var old_buf: [128]u8 = undefined;
        defer users.wipe(&old_buf);
        const old = users.readLine(&old_buf, true) orelse return 1;
        if (!users.checkPassword(u.password, old)) {
            zdos.sleep(1000);
            zdos.print("PASSWD: wrong password\n");
            return 1;
        }
    }
    zdos.printf("Password of {s}\n", .{u.name});
    var pw_buf: [256]u8 = undefined;
    defer users.wipe(&pw_buf);
    const pw = users.askNewPassword(&pw_buf) orelse return 1;
    var hash_buf: [128]u8 = undefined;
    u.password = list.keep(users.hashPassword(pw, &hash_buf)) orelse return 1;
    users.save(&list) catch |err| {
        zdos.printf("PASSWD: {s}\n", .{zdos.message(err)});
        return 1;
    };
    zdos.print(if (pw.len == 0) "Password removed\n" else "Password changed\n");
    return 0;
}
