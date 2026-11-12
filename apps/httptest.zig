// HTTPTEST: the ZDOS side of tests/net/httpz-tests.py.
//   HTTPTEST SETUP   (as root) installs the test files from NETLOG
// As a CGI program it prints its variables, user and request body.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const system = @import("zdos/system.zig");

comptime {
    _ = zdos;
}

var log: ?zdos.File = null;

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    zdos.print(text);
    if (log) |f| f.writeAll(text) catch {};
}

pub fn main(args: []const u8) u8 {
    var vb: [64]u8 = undefined;
    if (zdos.getVar("GATEWAY_INTERFACE", &vb) != null) return cgiMain();
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, args, " \t"), "SETUP")) return setup();
    zdos.print("HTTPTEST SETUP\n");
    return 1;
}

fn cgiMain() u8 {
    var out: [8192]u8 = undefined;
    var w: usize = 0;
    const head = "Content-Type: text/plain\nX-Native: yes\n\n";
    @memcpy(out[0..head.len], head);
    w = head.len;
    const names = [_][]const u8{ "REQUEST_METHOD", "QUERY_STRING", "PATH_INFO", "SCRIPT_NAME", "CONTENT_LENGTH", "CONTENT_TYPE", "HTTP_USER_AGENT", "HTTP_X_TEST", "REMOTE_ADDR", "SERVER_PROTOCOL", "HTTPS" };
    for (names) |n| {
        var b: [600]u8 = undefined;
        const v = zdos.getVar(n, &b) orelse "";
        const line = std.fmt.bufPrint(out[w..], "{s}={s}\n", .{ n, v }) catch break;
        w += line.len;
    }
    const uid = std.fmt.bufPrint(out[w..], "UID={d}\nBODY=", .{zdos.getIds().uid}) catch "";
    w += uid.len;
    zdos.print(out[0..w]);
    var body: [4096]u8 = undefined;
    while (true) {
        const n = zdos.readInput(&body);
        if (n == 0) break;
        zdos.print(body[0..n]);
    }
    zdos.print("\n");
    return 0;
}

fn findLogDrive() ?u8 {
    var i: u32 = 0;
    while (system.driveAt(i)) |d| : (i += 1) {
        if (std.ascii.eqlIgnoreCase(d.label(), "NETLOG")) return d.letter;
    }
    return null;
}

// Made if missing.
fn copyTree(from: []const u8, to: []const u8) void {
    zdos.makeDir(to) catch {};
    const d = zdos.openDir(from) catch |err| {
        say("can't read {s}: {s}\n", .{ from, zdos.message(err) });
        return;
    };
    defer d.close();
    var e: zdos.DirEntry = undefined;
    while (d.next(&e) catch false) {
        const name = e.name();
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var fb: [400]u8 = undefined;
        var tb: [400]u8 = undefined;
        const src = std.fmt.bufPrint(&fb, "{s}\\{s}", .{ from, name }) catch continue;
        const dst = std.fmt.bufPrint(&tb, "{s}\\{s}", .{ to, name }) catch continue;
        if (e.is_dir) {
            copyTree(src, dst);
            continue;
        }
        zdos.delete(dst) catch {};
        if (zdos.copy(src, dst)) {
            say("copied {s}\n", .{dst});
        } else |err| say("not copied {s}: {s}\n", .{ dst, zdos.message(err) });
    }
}

fn setup() u8 {
    const letter = findLogDrive() orelse {
        zdos.print("HTTPTEST: no drive labelled NETLOG\n");
        return 1;
    };
    var lb: [40]u8 = undefined;
    log = zdos.open(std.fmt.bufPrint(&lb, "{c}:\\SETUP.LOG", .{letter}) catch "", .write) catch null;
    defer if (log) |f| f.close();
    var vb: [300]u8 = undefined;
    const sys_drive: u8 = if (zdos.getVar("COMSPEC", &vb)) |c| c[0] else 'C';

    var fb: [64]u8 = undefined;
    var tb: [64]u8 = undefined;
    copyTree(std.fmt.bufPrint(&fb, "{c}:\\SETUP\\CONF", .{letter}) catch "", std.fmt.bufPrint(&tb, "{c}:\\CONF", .{sys_drive}) catch "");
    var wb: [64]u8 = undefined;
    const www = std.fmt.bufPrint(&wb, "{c}:\\USERS\\HTTPZ\\www", .{sys_drive}) catch "";
    var ub: [64]u8 = undefined;
    zdos.makeDir(std.fmt.bufPrint(&ub, "{c}:\\USERS", .{sys_drive}) catch "") catch {};
    zdos.makeDir(www[0 .. www.len - 4]) catch {};
    copyTree(std.fmt.bufPrint(&fb, "{c}:\\SETUP\\WWW", .{letter}) catch "", www);

    var pb: [300]u8 = undefined;
    const self = zdos.programPath(&pb);
    var nb: [96]u8 = undefined;
    const native = std.fmt.bufPrint(&nb, "{s}\\functions\\native.app", .{www}) catch "";
    zdos.delete(native) catch {};
    if (zdos.copy(self, native)) {
        zdos.setMode(native, 0o755) catch {};
        say("copied {s}\n", .{native});
    } else |err| say("not copied {s}: {s}\n", .{ native, zdos.message(err) });
    say("# SETUP done\n", .{});
    return 0;
}
