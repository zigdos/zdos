// SCP [-P PORT] [-i KEYFILE] [-r] [-q] SOURCE... TARGET
// SSHD runs SCP -t and -f for the other end (OpenSSH's scp -O).
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const ssh = @import("ssh/client.zig");

comptime {
    _ = zdos;
}

pub const zdos_file_version = [4]u8{ 0, 6, 1, 0 };

pub const std_options: std.Options = .{
    .cryptoRandomSeed = zdos.randomBytes,
    .crypto_always_getrandom = true,
};

fn usage() u8 {
    zdos.print("SCP [-P PORT] [-i KEYFILE] [-r] [-q] SOURCE... TARGET   ([user@]host:path)\n");
    return 1;
}

const Error = error{ Refused, BadProtocol } || ssh.Error;

var quiet = false;
var recursive = false;

pub fn main(args: []const u8) u8 {
    var words = std.mem.tokenizeAny(u8, args, " \t");
    var port: u16 = 22;
    var identity: ?[]const u8 = null;
    var paths: [32][]const u8 = undefined;
    var count: usize = 0;
    var remote_mode: ?u8 = null; // 't' or 'f': SSHD's side
    var options_done = false;
    while (words.next()) |w| {
        if (!options_done and w.len > 1 and w[0] == '-') {
            if (std.mem.eql(u8, w, "--")) {
                options_done = true;
            } else if (std.mem.eql(u8, w, "-P")) {
                port = std.fmt.parseInt(u16, words.next() orelse return usage(), 10) catch return usage();
            } else if (std.mem.eql(u8, w, "-i")) {
                identity = words.next() orelse return usage();
            } else {
                // Letters together, as scp -rt:
                for (w[1..]) |o| switch (o) {
                    'r' => recursive = true,
                    'q' => quiet = true,
                    't', 'f' => remote_mode = o,
                    'p', 'd', 'v', 'O' => {},
                    else => return usage(),
                };
            }
            continue;
        }
        if (count == paths.len) return usage();
        paths[count] = w;
        count += 1;
    }
    if (remote_mode) |m| {
        if (count != 1) return 1;
        var io: Io = .{ .client = null };
        var pb: [300]u8 = undefined;
        const path = localPath(paths[0], &pb);
        const r = if (m == 't') sink(&io, path) else source(&io, &.{path});
        r catch return 1;
        return 0;
    }
    if (count < 2) return usage();
    const target = paths[count - 1];
    const sources = paths[0 .. count - 1];
    var user_buf: [64]u8 = undefined;
    if (remoteSpec(target)) |rt| {
        for (sources) |s| if (remoteSpec(s) != null) {
            zdos.printError("SCP: copying between two remote hosts isn't supported\n");
            return 1;
        };
        return copy(rt, port, identity, &user_buf, true, sources, "");
    }
    if (sources.len != 1) {
        zdos.printError("SCP: one remote source at a time\n");
        return 1;
    }
    const rs = remoteSpec(sources[0]) orelse {
        zdos.printError("SCP: one side must be remote ([user@]host:path)\n");
        return 1;
    };
    return copy(rs, port, identity, &user_buf, false, &.{}, target);
}

const Remote = struct { target: []const u8, path: []const u8 };

// "C:\..." is a drive, not a host.
fn remoteSpec(s: []const u8) ?Remote {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    if (colon <= 1) return null;
    if (std.mem.indexOfAny(u8, s[0..colon], "\\/") != null) return null;
    return .{ .target = s[0..colon], .path = s[colon + 1 ..] };
}

fn copy(r: Remote, port: u16, identity: ?[]const u8, user_buf: []u8, upload: bool, sources: []const []const u8, local_target: []const u8) u8 {
    const t = ssh.splitTarget(r.target, user_buf);
    const c = ssh.Client.connect(.{ .host = t.host, .port = port, .user = t.user, .identity = identity }) catch |err| {
        zdos.eprintf("SCP: {s}: {s}\n", .{ t.host, ssh.errorText(err) });
        return 1;
    };
    defer c.deinit();
    var cmd_buf: [400]u8 = undefined;
    const path = if (r.path.len == 0) "." else r.path;
    const cmd = std.fmt.bufPrint(&cmd_buf, "scp {s}{s} {s}{s}", .{
        if (recursive) "-r " else "",
        if (upload) (if (sources.len > 1) "-d -t" else "-t") else "-f",
        if (path[0] == '-') "-- " else "",
        path,
    }) catch return 1;
    var io: Io = .{ .client = c };
    var ok = true;
    c.start(cmd) catch |err| {
        zdos.eprintf("SCP: {s}: {s}\n", .{ t.host, ssh.errorText(err) });
        return 1;
    };
    const result = if (upload) source(&io, sources) else blk: {
        var pb: [300]u8 = undefined;
        break :blk sink(&io, localPath(local_target, &pb));
    };
    result catch |err| {
        if (err != error.Refused) zdos.eprintf("SCP: {s}\n", .{ssh.errorText(err)});
        ok = false;
    };
    c.sendEof() catch {};
    // The remote side's exit code:
    while (!c.closed) {
        switch (c.next() catch break) {
            .stderr => |d| zdos.printError(d),
            else => {},
        }
    }
    if (c.exit_status) |s| if (s != 0) {
        ok = false;
    };
    return if (ok) 0 else 1;
}

// "/C:/x" as "C:\x", '/' as '\'; "" as ".".
fn localPath(p: []const u8, buf: *[300]u8) []const u8 {
    var s = p;
    if (s.len == 0) return ".";
    if (s.len >= 3 and s[0] == '/' and s[2] == ':') s = s[1..];
    const n = @min(s.len, buf.len);
    for (s[0..n], 0..) |c, i| buf[i] = if (c == '/') '\\' else c;
    return buf[0..n];
}

// The program's input and output, or the SSH channel:

const Io = struct {
    client: ?*ssh.Client,
    pending: []const u8 = "",
    buf: [32768]u8 = undefined,

    // false at the end
    fn fill(self: *Io) Error!bool {
        if (self.pending.len > 0) return true;
        if (self.client) |c| {
            while (!c.closed and !c.remote_eof) {
                switch (try c.next()) {
                    .data => |d| {
                        if (d.len == 0) continue;
                        self.pending = d;
                        return true;
                    },
                    .stderr => |d| zdos.printError(d),
                    else => {},
                }
            }
            return false;
        }
        const n = zdos.readInput(&self.buf);
        self.pending = self.buf[0..n];
        return n > 0;
    }

    fn byte(self: *Io) Error!?u8 {
        if (!try self.fill()) return null;
        const b = self.pending[0];
        self.pending = self.pending[1..];
        return b;
    }

    fn read(self: *Io, out: []u8) Error!usize {
        if (!try self.fill()) return 0;
        const n = @min(out.len, self.pending.len);
        @memcpy(out[0..n], self.pending[0..n]);
        self.pending = self.pending[n..];
        return n;
    }

    fn write(self: *Io, data: []const u8) Error!void {
        if (self.client) |c| return c.write(data);
        zdos.print(data);
    }

    // Without its '\n'; null at the end.
    fn line(self: *Io, out: []u8) Error!?[]const u8 {
        var n: usize = 0;
        while (true) {
            const b = try self.byte() orelse return if (n == 0) null else out[0..n];
            if (b == '\n') return out[0..n];
            if (n == out.len) return error.BadProtocol;
            out[n] = b;
            n += 1;
        }
    }

    // 0 fine, 1 a warning, 2 an error (with a line).
    fn ack(self: *Io) Error!void {
        const b = try self.byte() orelse return error.ConnectionAborted;
        if (b == 0) return;
        var msg: [512]u8 = undefined;
        const text = try self.line(&msg) orelse "";
        if (self.client != null) zdos.eprintf("SCP: {s}\n", .{text});
        if (b == 1) return;
        return error.Refused;
    }

    fn fail(self: *Io, comptime fmt: []const u8, args: anytype) void {
        var buf: [300]u8 = undefined;
        const text = std.fmt.bufPrint(buf[1..], fmt ++ "\n", args) catch return;
        buf[0] = 2;
        if (self.client != null) zdos.eprintf("SCP: " ++ fmt ++ "\n", args);
        self.write(buf[0 .. text.len + 1]) catch {};
    }
};

// scp -t, or downloading.

fn sink(io: *Io, target: []const u8) Error!void {
    var dir_buf: [300]u8 = undefined;
    var dir_len: usize = 0; // "": target names the file
    var depth: usize = 0;
    const target_is_dir = if (zdos.stat(target)) |e| e.is_dir else |_| false;
    if (target_is_dir) {
        @memcpy(dir_buf[0..target.len], target);
        dir_len = target.len;
    }
    try io.write(&[1]u8{0});
    var line_buf: [600]u8 = undefined;
    while (try io.line(&line_buf)) |line| {
        if (line.len == 0) return error.BadProtocol;
        switch (line[0]) {
            'T' => try io.write(&[1]u8{0}),
            1, 2 => {
                zdos.eprintf("SCP: {s}\n", .{line[1..]});
                if (line[0] == 2) return error.Refused;
            },
            'E' => {
                if (depth == 0) return error.BadProtocol;
                depth -= 1;
                dir_len = std.mem.lastIndexOfScalar(u8, dir_buf[0..dir_len], '\\') orelse 0;
                try io.write(&[1]u8{0});
            },
            'C', 'D' => {
                // "C0644 size name":
                var parts = std.mem.tokenizeScalar(u8, line[1..], ' ');
                const mode = std.fmt.parseInt(u32, parts.next() orelse return error.BadProtocol, 8) catch return error.BadProtocol;
                const size = std.fmt.parseInt(u64, parts.next() orelse return error.BadProtocol, 10) catch return error.BadProtocol;
                const name_at = @intFromPtr((parts.next() orelse return error.BadProtocol).ptr) - @intFromPtr(line.ptr);
                const name = line[name_at..];
                if (std.mem.indexOfAny(u8, name, "/\\:") != null or std.mem.eql(u8, name, "..") or std.mem.eql(u8, name, ".")) {
                    io.fail("bad name: {s}", .{name});
                    return error.Refused;
                }
                var pb: [300]u8 = undefined;
                const path = if (dir_len > 0 or depth > 0)
                    std.fmt.bufPrint(&pb, "{s}\\{s}", .{ dir_buf[0..dir_len], name }) catch return error.BadProtocol
                else
                    target;
                if (line[0] == 'D') {
                    if (!recursive) {
                        io.fail("{s}: a folder (use -r)", .{name});
                        return error.Refused;
                    }
                    zdos.makeDir(path) catch |err| if (err != error.AlreadyExists) {
                        io.fail("{s}: {s}", .{ path, zdos.message(err) });
                        return error.Refused;
                    };
                    if (path.len > dir_buf.len) return error.BadProtocol;
                    std.mem.copyForwards(u8, dir_buf[0..path.len], path);
                    dir_len = path.len;
                    depth += 1;
                    try io.write(&[1]u8{0});
                    continue;
                }
                try receiveFile(io, path, size, mode);
            },
            else => return error.BadProtocol,
        }
    }
}

fn receiveFile(io: *Io, path: []const u8, size: u64, mode: u32) Error!void {
    const f = zdos.open(path, .write) catch |err| {
        io.fail("{s}: {s}", .{ path, zdos.message(err) });
        return error.Refused;
    };
    try io.write(&[1]u8{0});
    var left = size;
    var failed: ?zdos.Error = null;
    var buf: [16384]u8 = undefined;
    while (left > 0) {
        const n = try io.read(buf[0..@intCast(@min(left, buf.len))]);
        if (n == 0) {
            f.close();
            return error.ConnectionAborted;
        }
        if (failed == null) f.writeAll(buf[0..n]) catch |err| {
            failed = err;
        };
        left -= n;
    }
    f.close();
    zdos.setMode(path, mode & 0o777) catch {};
    try io.ack(); // the sender's end of the file
    if (failed) |err| {
        io.fail("{s}: {s}", .{ path, zdos.message(err) });
        return error.Refused;
    }
    try io.write(&[1]u8{0});
    if (!quiet and io.client != null) zdos.printf("{s}  {d} bytes\n", .{ std.fs.path.basenameWindows(path), size });
}

// scp -f, or uploading.

fn source(io: *Io, paths: []const []const u8) Error!void {
    try io.ack(); // the receiver is ready
    for (paths) |p| {
        var pb: [300]u8 = undefined;
        const path = localPath(p, &pb);
        const e = zdos.stat(path) catch |err| {
            io.fail("{s}: {s}", .{ path, zdos.message(err) });
            continue;
        };
        if (e.is_dir) {
            if (!recursive) {
                io.fail("{s}: a folder (use -r)", .{path});
                continue;
            }
            try sendDir(io, path, 0);
        } else try sendFile(io, path);
    }
}

fn sendFile(io: *Io, path: []const u8) Error!void {
    const f = zdos.open(path, .read) catch |err| {
        io.fail("{s}: {s}", .{ path, zdos.message(err) });
        return;
    };
    defer f.close();
    const size = f.size() catch 0;
    var head: [400]u8 = undefined;
    const name = std.fs.path.basenameWindows(path);
    try io.write(std.fmt.bufPrint(&head, "C0644 {d} {s}\n", .{ size, name }) catch return error.BadProtocol);
    try io.ack();
    var left = size;
    var buf: [16384]u8 = undefined;
    while (left > 0) {
        const n = f.read(buf[0..@intCast(@min(left, buf.len))]) catch 0;
        if (n == 0) {
            // Shorter than it was: the rest as zeros, then the error:
            @memset(&buf, 0);
            while (left > 0) {
                const k: usize = @intCast(@min(left, buf.len));
                try io.write(buf[0..k]);
                left -= k;
            }
            io.fail("{s}: read error", .{path});
            return;
        }
        try io.write(buf[0..n]);
        left -= n;
    }
    try io.write(&[1]u8{0});
    try io.ack();
    if (!quiet and io.client != null) zdos.printf("{s}  {d} bytes\n", .{ name, size });
}

fn sendDir(io: *Io, path: []const u8, depth: usize) Error!void {
    if (depth > 16) return;
    var head: [400]u8 = undefined;
    try io.write(std.fmt.bufPrint(&head, "D0755 0 {s}\n", .{std.fs.path.basenameWindows(path)}) catch return error.BadProtocol);
    try io.ack();
    const d = zdos.openDir(path) catch |err| {
        io.fail("{s}: {s}", .{ path, zdos.message(err) });
        return;
    };
    defer d.close();
    var e: zdos.DirEntry = undefined;
    while (d.next(&e) catch false) {
        const name = e.name();
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var cb: [300]u8 = undefined;
        const child = std.fmt.bufPrint(&cb, "{s}\\{s}", .{ path, name }) catch continue;
        if (e.is_dir) try sendDir(io, child, depth + 1) else try sendFile(io, child);
    }
    try io.write("E\n");
    try io.ack();
}
