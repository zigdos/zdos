// SSH [-p PORT] [-i KEYFILE] [-l USER] [user@]host [COMMAND]
// Enter ~ . ends the connection.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const ssh = @import("ssh/client.zig");
const vt_mod = @import("ssh/vt.zig");
const Vt = vt_mod.Vt;
const keyBytes = vt_mod.keyBytes;

comptime {
    _ = zdos;
}

pub const zdos_file_version = [4]u8{ 0, 6, 1, 0 };

pub const std_options: std.Options = .{
    .cryptoRandomSeed = zdos.randomBytes,
    .crypto_always_getrandom = true,
};

fn usage() u8 {
    zdos.print("SSH [-p PORT] [-i KEYFILE] [-l USER] [user@]host [COMMAND]\n");
    return 1;
}

pub fn main(args: []const u8) u8 {
    var words = std.mem.tokenizeAny(u8, args, " \t");
    var port: u16 = 22;
    var identity: ?[]const u8 = null;
    var user: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var command: ?[]const u8 = null;
    while (words.next()) |w| {
        if (std.mem.eql(u8, w, "-p")) {
            port = std.fmt.parseInt(u16, words.next() orelse return usage(), 10) catch return usage();
        } else if (std.mem.eql(u8, w, "-i")) {
            identity = words.next() orelse return usage();
        } else if (std.mem.eql(u8, w, "-l")) {
            user = words.next() orelse return usage();
        } else if (w[0] == '-') {
            return usage();
        } else {
            target = w;
            // The rest of the line is the command, as typed:
            const after = @intFromPtr(w.ptr) - @intFromPtr(args.ptr) + w.len;
            const rest = std.mem.trim(u8, args[after..], " \t");
            if (rest.len > 0) command = rest;
            break;
        }
    }
    var user_buf: [64]u8 = undefined;
    const t = ssh.splitTarget(target orelse return usage(), &user_buf);
    zdos.setCtrlC(true); // Ctrl+C goes to the remote side
    const c = ssh.Client.connect(.{ .host = t.host, .port = port, .user = user orelse t.user, .identity = identity }) catch |err| {
        zdos.eprintf("SSH: {s}: {s}\n", .{ t.host, ssh.errorText(err) });
        return 255;
    };
    defer c.deinit();
    const code = if (command) |cmd| runCommand(c, cmd) else interactive(c, t.host);
    return code catch |err| {
        zdos.eprintf("SSH: {s}: {s}\n", .{ t.host, ssh.errorText(err) });
        return 255;
    };
}

// Its output to ours, our input (if redirected) to it.
fn runCommand(c: *ssh.Client, command: []const u8) ssh.Error!u8 {
    try c.start(command);
    if (zdos.inputRedirected()) {
        var buf: [16384]u8 = undefined;
        while (true) {
            const n = zdos.readInput(&buf);
            if (n == 0) break;
            try c.write(buf[0..n]);
        }
    }
    try c.sendEof();
    while (!c.closed) {
        switch (try c.next()) {
            .data => |d| zdos.print(d),
            .stderr => |d| zdos.printError(d),
            else => {},
        }
    }
    return @intCast(@min(c.exit_status orelse 255, 255));
}

fn interactive(c: *ssh.Client, host: []const u8) ssh.Error!u8 {
    const size = zdos.screenSize();
    var vt = Vt.init(size.col, size.row) catch return error.OutOfMemory;
    defer vt.deinit();
    try c.requestPty(size.col, size.row);
    try c.start(null);
    zdos.clearScreen();
    var line_start = true;
    var tilde = false;
    loop: while (!c.closed) {
        var fds = [2]zdos.PollFd{
            .{ .handle = c.sock.handle, .events = zdos.Poll.in },
            .{ .handle = zdos.PollFd.stdin_handle, .events = zdos.Poll.in },
        };
        if (!c.ready()) _ = zdos.table().files.poll(&fds, 2, 100);
        while (zdos.pollKey()) |k| {
            // Enter ~ . ends the connection, as OpenSSH's escape:
            if (tilde) {
                tilde = false;
                if (k.char == '.') break :loop;
                if (k.char != '~') try c.write("~");
            } else if (line_start and k.char == '~') {
                tilde = true;
                continue;
            }
            var buf: [16]u8 = undefined;
            const bytes = keyBytes(k, vt.app_cursor, &buf);
            if (bytes.len > 0) try c.write(bytes);
            line_start = k.char == '\r';
        }
        var got = false;
        while (c.ready() or (!got and fds[0].revents != 0)) {
            got = true;
            switch (try c.next()) {
                .data, .stderr => |d| vt.feed(d),
                .closed => break,
                else => {},
            }
            const answer = vt.takeReply();
            if (answer.len > 0) try c.write(answer);
        }
        vt.draw();
    }
    c.close();
    zdos.setColor(.light_gray, .black);
    zdos.clearScreen();
    zdos.printf("Connection to {s} closed.\n", .{host});
    return @intCast(@min(c.exit_status orelse 0, 255));
}
