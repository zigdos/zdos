// SSHTEST SETUP | CLIENT: the ZDOS side of tests/net/ssh-tests.py.
// Files from and results to the drive labelled NETLOG; exit code:
// failures.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const system = @import("zdos/system.zig");
const users = @import("zdos/users.zig");

comptime {
    _ = zdos;
}

var log: ?zdos.File = null;
var passed: u32 = 0;
var failed: u32 = 0;
var letter: u8 = 0;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    zdos.print(text);
    if (log) |f| f.writeAll(text) catch {};
}

fn check(ok: bool, comptime what: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (ok) passed += 1 else failed += 1;
    var detail: [256]u8 = undefined;
    const d = std.fmt.bufPrint(&detail, fmt, args) catch "";
    if (ok) say("ok - " ++ what ++ "\n", .{}) else say("not ok - " ++ what ++ " ({s})\n", .{d});
}

fn findLogDrive() ?u8 {
    var i: u32 = 0;
    while (system.driveAt(i)) |d| : (i += 1) {
        if (std.ascii.eqlIgnoreCase(d.label(), "NETLOG")) return d.letter;
    }
    return null;
}

fn onLog(name: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{c}:\\{s}", .{ letter, name }) catch "";
}

pub fn main(args: []const u8) u8 {
    letter = findLogDrive() orelse {
        zdos.print("SSHTEST: no drive labelled NETLOG\n");
        return 1;
    };
    const v = [2]u8{ letter, ':' };
    zdos.setVar("NETLOG", &v) catch {};
    const cmd = std.mem.trim(u8, args, " \t");
    if (std.ascii.eqlIgnoreCase(cmd, "SETUP")) return setup();
    if (std.ascii.eqlIgnoreCase(cmd, "CLIENT")) return client();
    zdos.print("SSHTEST SETUP | CLIENT\n");
    return 1;
}

fn setup() u8 {
    var lb: [40]u8 = undefined;
    log = zdos.open(onLog("SETUP.LOG", &lb), .write) catch null;
    defer if (log) |f| f.close();
    var vb: [300]u8 = undefined;
    const sys_drive: u8 = if (zdos.getVar("COMSPEC", &vb)) |c| c[0] else 'C';
    var hb: [300]u8 = undefined;
    const home = users.homeOf("ROOT", &hb);
    var sb: [320]u8 = undefined;
    const ssh_dir = std.fmt.bufPrint(&sb, "{s}\\.SSH", .{home}) catch return 1;
    zdos.makeDir(home) catch {};
    zdos.makeDir(ssh_dir) catch {};
    const copies = [_][2][]const u8{
        .{ "SETUP\\SERVICES.CFG", "\\CONF\\SERVICES.CFG" },
        .{ "SETUP\\SSHD.CFG", "\\CONF\\SSHD.CFG" },
        .{ "SETUP\\AUTHKEYS.TXT", "\\.SSH\\AUTHORIZED_KEYS" },
        .{ "SETUP\\CLIENT.KEY", "\\.SSH\\ID_ED25519" },
        .{ "SETUP\\KNOWN.TXT", "\\.SSH\\KNOWN_HOSTS" },
    };
    for (copies) |c| {
        var fb: [60]u8 = undefined;
        var tb: [340]u8 = undefined;
        const to = if (std.mem.startsWith(u8, c[1], "\\CONF"))
            std.fmt.bufPrint(&tb, "{c}:{s}", .{ sys_drive, c[1] }) catch continue
        else
            std.fmt.bufPrint(&tb, "{s}{s}", .{ home, c[1] }) catch continue;
        zdos.delete(to) catch {};
        if (zdos.copy(onLog(c[0], &fb), to)) {
            say("copied {s}\n", .{to});
        } else |err| say("not copied {s}: {s}\n", .{ to, zdos.message(err) });
    }
    // Root's password, for the password login:
    var pb: [60]u8 = undefined;
    var pw_buf: [64]u8 = undefined;
    const pw_text = readSmall(onLog("SETUP\\PASSWORD.TXT", &pb), &pw_buf) catch "";
    const pw = std.mem.trim(u8, pw_text, " \t\r\n");
    if (pw.len > 0) {
        const list = zdos.allocator.create(users.List) catch return 1;
        list.* = .{};
        users.load(list) catch {};
        if (list.find("ROOT")) |u| {
            var hash_buf: [128]u8 = undefined;
            const field = users.hashPassword(pw, &hash_buf);
            if (list.keep(field)) |kept| u.password = kept;
            if (users.save(list)) say("root's password set\n", .{}) else |err| say("password not saved: {s}\n", .{zdos.message(err)});
        } else say("no root in the users list\n", .{});
    }
    say("# SETUP done\n", .{});
    return 0;
}

fn readSmall(path: []const u8, buf: []u8) zdos.Error![]const u8 {
    const f = try zdos.open(path, .read);
    defer f.close();
    var len: usize = 0;
    while (len < buf.len) {
        const n = try f.read(buf[len..]);
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

const big_size = 300_000;

// The same bytes as net-tests.py's BIG.
fn bigByte(i: usize) u8 {
    return @truncate(i * 31 + i / 1000);
}

fn client() u8 {
    var lb: [40]u8 = undefined;
    log = zdos.open(onLog("SSHTEST.LOG", &lb), .write) catch null;
    defer if (log) |f| f.close();
    say("# SSHTEST\n", .{});
    var cb: [60]u8 = undefined;
    var conf_buf: [512]u8 = undefined;
    const conf = readSmall(onLog("SETUP\\HOST.TXT", &cb), &conf_buf) catch "";
    var user: []const u8 = "";
    var dir: []const u8 = "";
    var lines = std.mem.tokenizeAny(u8, conf, "\r\n");
    while (lines.next()) |l| {
        if (std.mem.startsWith(u8, l, "user=")) user = l[5..];
        if (std.mem.startsWith(u8, l, "dir=")) dir = l[4..];
    }
    check(user.len > 0 and dir.len > 0, "HOST.TXT read", "{s}", .{conf});
    var tb: [120]u8 = undefined;
    const target = std.fmt.bufPrint(&tb, "-p 2222 {s}@10.0.2.2", .{user}) catch return 1;
    var scp_tb: [120]u8 = undefined;
    const scp_host = std.fmt.bufPrint(&scp_tb, "{s}@10.0.2.2", .{user}) catch return 1;
    var line: [600]u8 = undefined;

    _ = run(std.fmt.bufPrint(&line, "SSH {s} echo client-ok > {c}:\\C-ECHO.TXT", .{ target, letter }) catch "");
    expectFile("C-ECHO.TXT", "client-ok", "SSH runs a command");

    const code = run(std.fmt.bufPrint(&line, "SSH {s} exit 7", .{target}) catch "");
    check(code == 7, "SSH gives the command's exit code", "{d}", .{code});

    writeFile("C:\\TEMP\\SSHIN.TXT", "stdin-data\n") catch {};
    _ = run(std.fmt.bufPrint(&line, "SSH {s} cat < C:\\TEMP\\SSHIN.TXT > {c}:\\C-CAT.TXT", .{ target, letter }) catch "");
    expectFile("C-CAT.TXT", "stdin-data", "SSH passes input");

    // SCP both ways, 300 KB:
    makeBig("C:\\TEMP\\UP.BIN") catch {};
    const up = run(std.fmt.bufPrint(&line, "SCP -P 2222 C:\\TEMP\\UP.BIN {s}:{s}/up.bin", .{ scp_host, dir }) catch "");
    check(up == 0, "SCP upload (checked by the host too)", "exit {d}", .{up});
    zdos.delete("C:\\TEMP\\DOWN.BIN") catch {};
    const down = run(std.fmt.bufPrint(&line, "SCP -P 2222 {s}:{s}/down.bin C:\\TEMP\\DOWN.BIN", .{ scp_host, dir }) catch "");
    check(down == 0 and bigMatches("C:\\TEMP\\DOWN.BIN"), "SCP download matches", "exit {d}", .{down});

    zdos.deleteTree("C:\\TEMP\\TREE") catch {};
    const rd = run(std.fmt.bufPrint(&line, "SCP -r -P 2222 {s}:{s}/tree C:\\TEMP\\TREE", .{ scp_host, dir }) catch "");
    check(rd == 0 and fileHas("C:\\TEMP\\TREE\\subdir\\b.txt", "tree-b"), "SCP -r download", "exit {d}", .{rd});
    const ru = run(std.fmt.bufPrint(&line, "SCP -r -P 2222 C:\\TEMP\\TREE {s}:{s}/tree2", .{ scp_host, dir }) catch "");
    check(ru == 0, "SCP -r upload (checked by the host too)", "exit {d}", .{ru});

    say("# SSHTEST: {d} passed, {d} failed\n", .{ passed, failed });
    return @intCast(@min(failed, 255));
}

fn run(line: []const u8) u8 {
    say("$ {s}\n", .{line});
    return zdos.runCommand(line) catch 255;
}

fn writeFile(path: []const u8, data: []const u8) zdos.Error!void {
    const f = try zdos.open(path, .write);
    defer f.close();
    try f.writeAll(data);
}

fn makeBig(path: []const u8) zdos.Error!void {
    const f = try zdos.open(path, .write);
    defer f.close();
    var buf: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < big_size) {
        const n = @min(buf.len, big_size - i);
        for (buf[0..n], 0..) |*b, k| b.* = bigByte(i + k);
        try f.writeAll(buf[0..n]);
        i += n;
    }
}

fn bigMatches(path: []const u8) bool {
    const f = zdos.open(path, .read) catch return false;
    defer f.close();
    var buf: [4096]u8 = undefined;
    var i: usize = 0;
    while (true) {
        const n = f.read(&buf) catch return false;
        if (n == 0) break;
        for (buf[0..n], 0..) |b, k| if (b != bigByte(i + k)) return false;
        i += n;
    }
    return i == big_size;
}

fn fileHas(path: []const u8, needle: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const text = readSmall(path, &buf) catch return false;
    return std.mem.indexOf(u8, text, needle) != null;
}

fn expectFile(comptime name: []const u8, needle: []const u8, comptime what: []const u8) void {
    var pb: [40]u8 = undefined;
    const path = onLog(name, &pb);
    var buf: [4096]u8 = undefined;
    const text = readSmall(path, &buf) catch "";
    check(std.mem.indexOf(u8, text, needle) != null, what, "{s}: {s}", .{ name, text[0..@min(text.len, 80)] });
}
