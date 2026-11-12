// LOGIN: asks who is there and starts their shell; asks again when it
// ends (LOGIN=true in SYSTEM.CFG).
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

var list: users.List = .{};
var startup_vars: users.Snapshot = .{}; // after AUTOEXEC.CMD, for every login

pub fn main(_: []const u8) u8 {
    zdos.setCtrlC(true); // Ctrl+C is a key here, not the end of LOGIN
    var spec_buf: [300]u8 = undefined;
    if (zdos.getVar("COMSPEC", &spec_buf)) |spec| {
        if (std.ascii.eqlIgnoreCase(std.fs.path.basenameWindows(spec), "COMMAND.APP")) _ = zdos.exec(spec, "-a") catch {};
    }
    users.takeSnapshot(&startup_vars);
    while (true) {
        // Each login starts with the startup variables: a COMSPEC or PATH left
        // behind would run as the next user.
        users.restoreSnapshot(&startup_vars);
        _ = session();
    }
}

// True if someone logged in.
fn session() bool {
    var host_buf: [64]u8 = undefined;
    const host = zdos.getVar("HOSTNAME", &host_buf) orelse "zdos";
    zdos.printf("\n{s} login: ", .{host});
    var name_buf: [users.max_name + 1]u8 = undefined;
    const typed = users.readLine(&name_buf, false) orelse return false;
    const name = std.mem.trim(u8, typed, " \t");
    if (name.len == 0) return false;

    users.load(&list) catch |err| {
        zdos.printf("{s}: {s}\n", .{ users.filePath(&host_buf), zdos.message(err) });
    };
    const user = list.find(name);
    // A password is asked of a user that doesn't exist too, as on Unix:
    var ok = user != null;
    if (user == null or user.?.password.len > 0) {
        zdos.print("Password: ");
        var pw_buf: [128]u8 = undefined;
        defer users.wipe(&pw_buf);
        const pw = users.readLine(&pw_buf, true) orelse return false;
        if (user) |u| {
            ok = users.checkPassword(u.password, pw);
            if (ok) users.upgradeHash(&list, u, pw);
        }
    }
    if (!ok) {
        zdos.sleep(1000);
        zdos.print("Login incorrect\n");
        return false;
    }
    const u = user.?;

    var home_buf: [300]u8 = undefined;
    const home = users.makeHome(u, &home_buf);
    users.setUserVars(u, null);
    zdos.setCwd(home) catch |err| zdos.printf("{s}: {s}\n", .{ home, zdos.message(err) });
    // Root's rights stay saved, to take them back at logout:
    users.become(u, zdos.keep_id) catch |err| {
        zdos.printf("LOGIN: can't run as {s}: {s}\n", .{ u.name, zdos.message(err) });
        return false;
    };
    defer {
        const back: zdos.Ids = .{ .real = 0, .uid = 0, .saved = zdos.keep_id, .gid = zdos.keep_id, .group_count = zdos.keep_groups, .groups = undefined };
        zdos.setIds(back) catch {};
        zdos.setIds(.{ .real = zdos.keep_id, .uid = zdos.keep_id, .saved = zdos.keep_id, .gid = 0, .group_count = 0, .groups = undefined }) catch {};
    }

    // The user's shell, else the command interpreter:
    var shell_buf: [300]u8 = undefined;
    const shell = if (u.shell.len > 0) u.shell else zdos.getVar("COMSPEC", &shell_buf) orelse "C:\\APPS\\COMMAND.APP";
    const is_command = std.ascii.eqlIgnoreCase(std.fs.path.basenameWindows(shell), "COMMAND.APP");
    const args = if (is_command) "-l -d" else "";
    zdos.printf("\n", .{});
    _ = zdos.exec(shell, args) catch |err| {
        zdos.printf("{s}: {s}\n", .{ shell, zdos.message(err) });
        return true;
    };
    zdos.print("\nLogged out\n");
    return true;
}
