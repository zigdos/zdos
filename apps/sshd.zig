// SSHD: the SSH server, a service (SSHD.CFG). Runs as root.
//   SSHD -s USER [-c LINE]   (its own) a session run as USER
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");
const net = @import("zdos/net.zig");
const users = @import("zdos/users.zig");
const ssh = @import("ssh/transport.zig");
const wire = @import("ssh/wire.zig");
const keys = @import("ssh/keys.zig");
const cores = @import("ssh/cores.zig");

comptime {
    _ = zdos;
}

pub const zdos_file_version = [4]u8{ 0, 6, 1, 0 };

pub const std_options: std.Options = .{
    .cryptoRandomSeed = zdos.randomBytes,
    .crypto_always_getrandom = true,
};

const Msg = ssh.Msg;
const Ed25519 = @import("zdos/zcrypt.zig").Ed25519;

const max_connections = 8;
const max_channels = 4;
const window_size: u32 = 64 * 1024; // what a client may send before we adjust
const packet_max: u32 = 32768;

var host_key: Ed25519.KeyPair = undefined;
var allow_passwords = true;
var port: u16 = 22;
var conf_drive: u8 = 'C';
var own_path_buf: [300]u8 = undefined;
var own_path: []const u8 = "";
var log_lock: ?sys.Mutex = null;
var log_buf: [300]u8 = undefined;
var log_path: []const u8 = ""; // LOG=; empty: no log
var active = std.atomic.Value(u32).init(0);

pub fn main(args: []const u8) u8 {
    const a = std.mem.trim(u8, args, " \t");
    if (std.mem.startsWith(u8, a, "-s ")) return session(std.mem.trim(u8, a[3..], " \t"));
    if (a.len > 0) {
        zdos.print("SSHD   (a service: SSHD=true in \\CONF\\SERVICES.CFG; see docs/SSH.md)\n");
        return 1;
    }
    if (!users.isRoot()) {
        zdos.printError("SSHD: runs as root\n");
        return 1;
    }
    var vb: [300]u8 = undefined;
    if (zdos.getVar("COMSPEC", &vb)) |c| {
        if (c.len > 1 and c[1] == ':') conf_drive = c[0];
    }
    own_path = zdos.programPath(&own_path_buf);
    log_lock = sys.Mutex.create() catch null;
    readConfig();
    if (std.fs.path.dirnameWindows(log_path)) |dir| {
        if (std.fs.path.dirnameWindows(dir)) |parent| zdos.makeDir(parent) catch {};
        zdos.makeDir(dir) catch {};
    }
    loadHostKey() catch |err| {
        log("host key: {s}", .{errText(err)});
        zdos.eprintf("SSHD: host key: {s}\n", .{errText(err)});
        return 1;
    };
    const listener = net.Socket.open(net.SocketType.stream) catch |err| return fatal("socket", err);
    listener.setOption(net.SocketOption.reuse_address, 1) catch {};
    listener.bind(.{ .addr = .{ 0, 0, 0, 0 }, .port = port }) catch |err| return fatal("port", err);
    listener.listen(max_connections) catch |err| return fatal("listen", err);
    var blob: [51]u8 = undefined;
    ssh.ed25519Blob(host_key.public_key.toBytes(), &blob);
    var fp: [64]u8 = undefined;
    log("listening on port {d}; host key {s}", .{ port, keys.fingerprint(&blob, &fp) });
    zdos.printf("SSHD: port {d}, host key {s}\n", .{ port, keys.fingerprint(&blob, &fp) });

    while (true) {
        var peer: net.Address = .{};
        const s = listener.accept(&peer) catch |err| {
            log("accept: {s}", .{errText(err)});
            zdos.sleep(200);
            continue;
        };
        if (active.load(.monotonic) >= max_connections) {
            s.close();
            continue;
        }
        const c = zdos.allocator.create(Conn) catch {
            s.close();
            continue;
        };
        c.* = .{ .sock = s, .peer = peer };
        for (&c.channels) |*ch| ch.reset();
        _ = active.fetchAdd(1, .monotonic);
        const id = sys.threadCreate(&connThread, c, 256 * 1024, null) catch {
            _ = active.fetchSub(1, .monotonic);
            s.close();
            zdos.allocator.destroy(c);
            continue;
        };
        sys.threadDetach(id) catch {};
    }
}

fn fatal(what: []const u8, err: zdos.Error) u8 {
    log("{s}: {s}", .{ what, zdos.message(err) });
    zdos.eprintf("SSHD: {s}: {s}\n", .{ what, zdos.message(err) });
    return 1;
}

// PORT=, PASSWORDS=true/false, LOG=FILE
fn readConfig() void {
    var path = "C:\\CONF\\SSHD.CFG".*;
    path[0] = conf_drive;
    var buf: [2048]u8 = undefined;
    const text = keys.readFile(&path, &buf) catch return;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const name = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "PORT")) {
            port = std.fmt.parseInt(u16, value, 10) catch port;
        } else if (std.ascii.eqlIgnoreCase(name, "PASSWORDS")) {
            allow_passwords = !std.ascii.eqlIgnoreCase(value, "false");
        } else if (std.ascii.eqlIgnoreCase(name, "LOG")) {
            const n = @min(value.len, log_buf.len);
            @memcpy(log_buf[0..n], value[0..n]);
            log_path = log_buf[0..n];
        }
    }
}

// Made on the first start.
fn loadHostKey() keys.Error!void {
    var path = "C:\\CONF\\SSHHOST.KEY".*;
    path[0] = conf_drive;
    host_key = keys.loadPrivate(&path, null) catch |err| switch (err) {
        error.NotFound => {
            var seed: [32]u8 = undefined;
            zdos.randomBytes(&seed);
            defer std.crypto.secureZero(u8, &seed);
            host_key = Ed25519.KeyPair.generateDeterministic(seed) catch return error.BadKeyFile;
            try keys.savePrivate(&path, host_key, "zdos host key");
            log("made a new host key", .{});
            return;
        },
        else => return err,
    };
}

// SSHD.CFG's LOG= (none without it)
fn log(comptime fmt: []const u8, args: anytype) void {
    if (log_path.len == 0) return;
    if (log_lock) |m| m.lock() catch {};
    defer if (log_lock) |m| m.unlock() catch {};
    var line: [400]u8 = undefined;
    const t = zdos.getTime();
    const head = std.fmt.bufPrint(&line, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} ", .{ t.year, t.month, t.day, t.hour, t.minute, t.second }) catch return;
    const body = std.fmt.bufPrint(line[head.len .. line.len - 1], fmt, args) catch line[head.len .. line.len - 1];
    line[head.len + body.len] = '\n';
    const f = zdos.open(log_path, .update) catch zdos.open(log_path, .write) catch return;
    defer f.close();
    f.seek(f.size() catch 0) catch {};
    f.writeAll(line[0 .. head.len + body.len + 1]) catch {};
}

fn errText(err: anyerror) []const u8 {
    inline for (@typeInfo(zdos.Error).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return zdos.message(@field(zdos.Error, e.name));
    }
    return @errorName(err);
}

// A CONNECTION: ONE THREAD EACH

const Channel = struct {
    used: bool = false,
    local: u32 = 0,
    remote: u32 = 0,
    remote_window: u64 = 0,
    remote_max: u32 = 0,
    pty: bool = false,
    cols: u32 = 80,
    rows: u32 = 24,
    started: bool = false,
    task: u32 = 0,
    term: ?zdos.File = null,
    stdin: ?zdos.File = null, // the program's input: we write
    stdout: ?zdos.File = null, // we read
    stderr: ?zdos.File = null,
    // Not yet given to the program:
    inbox: [window_size]u8 = undefined,
    inbox_len: usize = 0,
    consumed: u32 = 0, // since the last WINDOW_ADJUST
    client_eof: bool = false,
    stdin_closed: bool = false,
    closing: bool = false, // our CLOSE sent

    // Every field's default but the inbox's: a whole default value
    // would be kept in the program, 64 KB of it per use
    fn reset(ch: *Channel) void {
        inline for (std.meta.fields(Channel)) |f| {
            if (comptime !std.mem.eql(u8, f.name, "inbox")) @field(ch, f.name) = f.defaultValue().?;
        }
    }
};

const Conn = struct {
    sock: net.Socket,
    peer: net.Address,
    t: *ssh.Transport = undefined,
    user_buf: [users.max_name]u8 = undefined,
    user_len: usize = 0,
    channels: [max_channels]Channel = undefined, // reset when made

    fn user(self: *const Conn) []const u8 {
        return self.user_buf[0..self.user_len];
    }
};

fn connThread(arg: ?*anyopaque) callconv(zdos.cc) usize {
    const c: *Conn = @ptrCast(@alignCast(arg.?));
    var ab: [16]u8 = undefined;
    const who = net.addressText(c.peer.addr, &ab);
    serve(c) catch |err| {
        if (err != error.ConnectionAborted and err != error.Disconnected) log("{s}: {s}", .{ who, errText(err) });
    };
    for (&c.channels) |*ch| endChannel(c, ch, false);
    if (c.user_len > 0) log("{s}: {s} left", .{ who, c.user() });
    c.sock.close();
    zdos.allocator.destroy(c);
    _ = active.fetchSub(1, .monotonic);
    return 0;
}

const Failure = error{AuthFailed};

fn serve(c: *Conn) (ssh.Error || Failure)!void {
    c.t = try ssh.Transport.create(c.sock, .server);
    defer c.t.destroy();
    c.t.host_key = host_key;
    c.sock.setOption(net.SocketOption.recv_timeout, 60_000) catch {};
    c.sock.setOption(net.SocketOption.no_delay, 1) catch {};
    try c.t.handshake();
    const p = try c.t.receive();
    var r = wire.Reader.init(p[1..]);
    if (p[0] != Msg.service_request or !std.mem.eql(u8, try r.string(), "ssh-userauth")) return error.Protocol;
    var w = c.t.writer(Msg.service_accept);
    try w.string("ssh-userauth");
    try c.t.send(w.slice());
    try authenticate(c);
    c.sock.setOption(net.SocketOption.recv_timeout, 0) catch {};
    c.sock.setOption(net.SocketOption.keepalive, 1) catch {};
    var ab: [16]u8 = undefined;
    log("{s}: {s} logged in", .{ net.addressText(c.peer.addr, &ab), c.user() });
    try connection(c);
}

fn authenticate(c: *Conn) (ssh.Error || Failure)!void {
    const list = zdos.allocator.create(users.List) catch return error.OutOfMemory;
    defer zdos.allocator.destroy(list);
    list.* = .{};
    users.load(list) catch {};
    var tries: u32 = 0;
    while (tries < 10) {
        const p = try c.t.receive();
        if (p[0] != Msg.userauth_request) continue;
        var r = wire.Reader.init(p[1..]);
        const name = try r.string();
        const service = try r.string();
        const method = try r.string();
        const u = if (users.validName(name) and std.mem.eql(u8, service, "ssh-connection")) list.find(name) else null;
        if (std.mem.eql(u8, method, "publickey")) {
            const has_sig = try r.boolean();
            const alg = try r.string();
            const blob = try r.string();
            if (u == null or !std.mem.eql(u8, alg, "ssh-ed25519") or !keyAllowed(u.?.name, blob)) {
                tries += 1;
                try authFailure(c);
                continue;
            }
            if (!has_sig) {
                var w = c.t.writer(Msg.userauth_pk_ok);
                try w.string(alg);
                try w.string(blob);
                try c.t.send(w.slice());
                continue;
            }
            const sig = try r.string();
            if (try signatureOk(c, name, service, alg, blob, sig)) return authSuccess(c, u.?);
            tries += 1;
        } else if (std.mem.eql(u8, method, "password") and allow_passwords) {
            _ = try r.boolean();
            const pw = try r.string();
            tries += 1;
            if (u != null and passwordOk(u.?, pw)) return authSuccess(c, u.?);
        } else if (!std.mem.eql(u8, method, "none")) tries += 1;
        try authFailure(c);
    }
    var ab: [16]u8 = undefined;
    log("{s}: too many failed logins", .{net.addressText(c.peer.addr, &ab)});
    c.t.disconnect(14, "too many failed logins");
    return error.AuthFailed;
}

fn authFailure(c: *Conn) ssh.Error!void {
    var w = c.t.writer(Msg.userauth_failure);
    try w.string(if (allow_passwords) "publickey,password" else "publickey");
    try w.boolean(false);
    try c.t.send(w.slice());
}

fn authSuccess(c: *Conn, u: *const users.User) ssh.Error!void {
    c.user_len = @min(u.name.len, c.user_buf.len);
    @memcpy(c.user_buf[0..c.user_len], u.name[0..c.user_len]);
    try c.t.send(&[1]u8{Msg.userauth_success});
}

fn keyAllowed(name: []const u8, blob: []const u8) bool {
    var hb: [300]u8 = undefined;
    const home = users.homeOf(name, &hb);
    var pb: [340]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}\\.SSH\\AUTHORIZED_KEYS", .{home}) catch return false;
    return keys.fileHasKey(path, blob);
}

const SigJob = struct {
    pk: Ed25519.PublicKey,
    sig: [64]u8,
    data: []const u8,
    ok: bool = false,

    fn work(j: *SigJob) void {
        Ed25519.Signature.fromBytes(j.sig).verify(j.data, j.pk) catch return;
        j.ok = true;
    }
};

// RFC 4252 7: the client signed session id, request and key.
fn signatureOk(c: *Conn, name: []const u8, service: []const u8, alg: []const u8, blob: []const u8, sig_blob: []const u8) ssh.Error!bool {
    var br = wire.Reader.init(blob);
    _ = try br.string();
    const pk_bytes = try br.string();
    var sr = wire.Reader.init(sig_blob);
    if (!std.mem.eql(u8, try sr.string(), "ssh-ed25519")) return false;
    const sig = try sr.string();
    if (pk_bytes.len != 32 or sig.len != 64) return false;
    var data: [1024]u8 = undefined;
    var w = wire.Writer.init(&data);
    try w.string(&c.t.session_id);
    try w.byte(Msg.userauth_request);
    try w.string(name);
    try w.string(service);
    try w.string("publickey");
    try w.boolean(true);
    try w.string(alg);
    try w.string(blob);
    var job: SigJob = .{
        .pk = Ed25519.PublicKey.fromBytes(pk_bytes[0..32].*) catch return false,
        .sig = sig[0..64].*,
        .data = w.slice(),
    };
    cores.run(SigJob, &job, SigJob.work, false);
    return job.ok;
}

const PasswordJob = struct {
    fba: std.heap.FixedBufferAllocator,
    field: []const u8,
    password: []const u8,
    ok: bool = false,

    fn work(j: *PasswordJob) void {
        j.ok = users.checkPasswordWith(j.fba.allocator(), j.field, j.password);
    }
};

// No empty passwords over the network; Argon2 on another core with its
// memory ready (19 MB).
fn passwordOk(u: *const users.User, pw: []const u8) bool {
    if (u.password.len == 0 or pw.len == 0) return false;
    const size = 20 * 1024 * 1024;
    const mem = zdos.allocator.alloc(u8, size) catch return users.checkPassword(u.password, pw);
    defer zdos.allocator.free(mem);
    var job: PasswordJob = .{ .fba = .init(mem), .field = u.password, .password = pw };
    cores.run(PasswordJob, &job, PasswordJob.work, true);
    return job.ok;
}

fn connection(c: *Conn) ssh.Error!void {
    var next_id: u32 = 0;
    while (true) {
        var fds: [1 + 4 * max_channels]zdos.PollFd = undefined;
        var n: u32 = 0;
        fds[n] = .{ .handle = c.sock.handle, .events = zdos.Poll.in };
        n += 1;
        for (&c.channels) |*ch| {
            if (!ch.used or !ch.started) continue;
            const can_send = ch.remote_window > 0 and !ch.closing;
            if (ch.term) |f| if (can_send or !ch.pty) {
                fds[n] = .{ .handle = f.handle, .events = zdos.Poll.in };
                n += 1;
            };
            if (ch.stdout) |f| if (can_send) {
                fds[n] = .{ .handle = f.handle, .events = zdos.Poll.in };
                n += 1;
            };
            if (ch.stderr) |f| if (can_send) {
                fds[n] = .{ .handle = f.handle, .events = zdos.Poll.in };
                n += 1;
            };
            if (ch.stdin) |f| if (ch.inbox_len > 0) {
                fds[n] = .{ .handle = f.handle, .events = zdos.Poll.out };
                n += 1;
            };
        }
        const wait: i32 = if (c.t.buffered()) 0 else 50;
        _ = zdos.table().files.poll(&fds, n, wait);
        if (c.t.buffered() or fds[0].revents != 0) {
            const p = try c.t.receive();
            try dispatch(c, p, &next_id);
        }
        for (&c.channels) |*ch| {
            if (ch.used and ch.started) try pump(c, ch);
        }
    }
}

fn channelBy(c: *Conn, local: u32) ?*Channel {
    for (&c.channels) |*ch| {
        if (ch.used and ch.local == local) return ch;
    }
    return null;
}

fn dispatch(c: *Conn, p: []const u8, next_id: *u32) ssh.Error!void {
    var r = wire.Reader.init(p[1..]);
    switch (p[0]) {
        Msg.channel_open => {
            const kind = try r.string();
            const sender = try r.int();
            const window = try r.int();
            const max = try r.int();
            const free = for (&c.channels) |*ch| {
                if (!ch.used) break ch;
            } else null;
            if (!std.mem.eql(u8, kind, "session") or free == null) {
                var w = c.t.writer(Msg.channel_open_failure);
                try w.int(sender);
                try w.int(if (free == null) 4 else 3); // resource shortage, unknown type
                try w.string(if (free == null) "too many channels" else "only sessions");
                try w.string("");
                return c.t.send(w.slice());
            }
            const ch = free.?;
            ch.* = .{ .used = true, .local = next_id.*, .remote = sender, .remote_window = window, .remote_max = @max(max, 1024) };
            next_id.* +%= 1;
            var w = c.t.writer(Msg.channel_open_confirmation);
            try w.int(sender);
            try w.int(ch.local);
            try w.int(window_size);
            try w.int(packet_max);
            try c.t.send(w.slice());
        },
        Msg.channel_request => {
            const ch = channelBy(c, try r.int()) orelse return;
            const kind = try r.string();
            const want_reply = try r.boolean();
            var ok = false;
            if (std.mem.eql(u8, kind, "pty-req")) {
                _ = try r.string();
                ch.cols = try r.int();
                ch.rows = try r.int();
                ch.pty = true;
                ok = !ch.started;
            } else if (std.mem.eql(u8, kind, "shell") and !ch.started) {
                ok = start(c, ch, null);
            } else if (std.mem.eql(u8, kind, "exec") and !ch.started) {
                ok = start(c, ch, try r.string());
            } else if (std.mem.eql(u8, kind, "subsystem") and !ch.started) {
                // SFTP: SFTPSRV.APP, as the user, over pipes:
                if (std.mem.eql(u8, try r.string(), "sftp")) {
                    ch.pty = false;
                    ok = start(c, ch, "SFTPSRV");
                }
            } else if (std.mem.eql(u8, kind, "window-change")) {
                ch.cols = try r.int();
                ch.rows = try r.int();
                if (ch.term) |t| if (ch.pty) sys.termResize(t, ch.cols, ch.rows) catch {};
                ok = true;
            }
            if (want_reply) {
                var w = c.t.writer(if (ok) Msg.channel_success else Msg.channel_failure);
                try w.int(ch.remote);
                try c.t.send(w.slice());
            }
        },
        Msg.channel_data => {
            const ch = channelBy(c, try r.int()) orelse return;
            const data = try r.string();
            const room = ch.inbox.len - ch.inbox_len;
            if (data.len > room) return error.Protocol; // past the window we gave
            @memcpy(ch.inbox[ch.inbox_len..][0..data.len], data);
            ch.inbox_len += data.len;
        },
        Msg.channel_window_adjust => {
            const ch = channelBy(c, try r.int()) orelse return;
            ch.remote_window +|= try r.int();
        },
        Msg.channel_eof => {
            const ch = channelBy(c, try r.int()) orelse return;
            ch.client_eof = true;
        },
        Msg.channel_close => {
            const ch = channelBy(c, try r.int()) orelse return;
            endChannel(c, ch, true);
        },
        Msg.global_request => {
            _ = try r.string();
            if (try r.boolean()) try c.t.send(&[1]u8{Msg.request_failure});
        },
        Msg.channel_extended_data, Msg.channel_success, Msg.channel_failure => {},
        else => {
            var w = c.t.writer(Msg.unimplemented);
            try w.int(c.t.in.seq -% 1);
            try c.t.send(w.slice());
        },
    }
}

// SSHD -s USER [-c LINE], as root, on its own remote console; a command
// gets pipes for its streams.
fn start(c: *Conn, ch: *Channel, command: ?[]const u8) bool {
    var ab: [600]u8 = undefined;
    const args = if (command) |cmd|
        std.fmt.bufPrint(&ab, "-s {s} -c {s}", .{ c.user(), cmd }) catch return false
    else
        std.fmt.bufPrint(&ab, "-s {s}", .{c.user()}) catch return false;
    const term = sys.termCreate(if (ch.pty) ch.cols else 80, if (ch.pty) ch.rows else 24) catch return false;
    var opts: sys.SpawnOptions = .{ .term = term.handle };
    var child_ends: [3]?zdos.File = .{ null, null, null };
    if (!ch.pty) {
        const in = sys.pipe() catch return failStart(ch, term, &child_ends);
        child_ends[0] = .{ .handle = in.read };
        ch.stdin = .{ .handle = in.write };
        const out = sys.pipe() catch return failStart(ch, term, &child_ends);
        child_ends[1] = .{ .handle = out.write };
        ch.stdout = .{ .handle = out.read };
        const err = sys.pipe() catch return failStart(ch, term, &child_ends);
        child_ends[2] = .{ .handle = err.write };
        ch.stderr = .{ .handle = err.read };
        opts.input = in.read;
        opts.output = out.write;
        opts.err = err.write;
    }
    const id = sys.taskSpawnWith(own_path, args, opts) catch return failStart(ch, term, &child_ends);
    for (child_ends) |e| if (e) |f| f.close();
    ch.term = term;
    ch.task = id;
    ch.started = true;
    return true;
}

fn failStart(ch: *Channel, term: zdos.File, ends: *[3]?zdos.File) bool {
    closeStreams(ch);
    term.close();
    for (ends) |e| if (e) |f| f.close();
    return false;
}

fn closeStreams(ch: *Channel) void {
    inline for (.{ "stdin", "stdout", "stderr", "term" }) |name| {
        if (@field(ch, name)) |f| f.close();
        @field(ch, name) = null;
    }
}

// Ends the channel when the program has ended and its output is sent.
fn pump(c: *Conn, ch: *Channel) ssh.Error!void {
    if (ch.closing) return;
    // To the program:
    if (ch.inbox_len > 0) {
        var n: usize = 0;
        if (ch.pty) {
            if (ch.term) |t| n = t.write(ch.inbox[0..ch.inbox_len]) catch 0;
        } else if (ch.stdin) |f| {
            // A pipe holds 64 KiB: writing more would wait for the program:
            const unread: usize = if (f.statEx()) |x| @intCast(x.file_size) else |_| 0;
            const room = (64 * 1024) -| unread;
            if (room > 0) n = f.write(ch.inbox[0..@min(ch.inbox_len, room)]) catch ch.inbox_len;
        } else n = ch.inbox_len;
        if (n > 0) {
            std.mem.copyForwards(u8, ch.inbox[0 .. ch.inbox_len - n], ch.inbox[n..ch.inbox_len]);
            ch.inbox_len -= n;
            ch.consumed += @intCast(n);
        }
    }
    if (ch.consumed >= window_size / 2) {
        var w = c.t.writer(Msg.channel_window_adjust);
        try w.int(ch.remote);
        try w.int(ch.consumed);
        try c.t.send(w.slice());
        ch.consumed = 0;
    }
    if (ch.client_eof and ch.inbox_len == 0 and !ch.stdin_closed) {
        if (ch.stdin) |f| f.close();
        ch.stdin = null;
        ch.stdin_closed = true;
    }
    // From the program:
    var done = true;
    if (ch.term) |f| {
        if (!try forward(c, ch, f, if (ch.pty) .data else .drop)) done = false else {
            f.close();
            ch.term = null;
        }
    }
    if (ch.stdout) |f| {
        if (!try forward(c, ch, f, .data)) done = false else {
            f.close();
            ch.stdout = null;
        }
    }
    if (ch.stderr) |f| {
        if (!try forward(c, ch, f, .stderr)) done = false else {
            f.close();
            ch.stderr = null;
        }
    }
    const code = sys.taskEnded(ch.task) orelse return;
    if (!done) return;
    _ = sys.taskWait(ch.task) catch {}; // collected
    ch.task = 0;
    var w = c.t.writer(Msg.channel_request);
    try w.int(ch.remote);
    try w.string("exit-status");
    try w.boolean(false);
    try w.int(code);
    try c.t.send(w.slice());
    var eof = c.t.writer(Msg.channel_eof);
    try eof.int(ch.remote);
    try c.t.send(eof.slice());
    var close = c.t.writer(Msg.channel_close);
    try close.int(ch.remote);
    try c.t.send(close.slice());
    ch.closing = true;
}

const Stream = enum { data, stderr, drop };

// As the window allows; true at its end.
fn forward(c: *Conn, ch: *Channel, f: zdos.File, kind: Stream) ssh.Error!bool {
    var fds = [1]zdos.PollFd{.{ .handle = f.handle, .events = zdos.Poll.in }};
    var rounds: usize = 0;
    while (rounds < 8) : (rounds += 1) {
        if (zdos.table().files.poll(&fds, 1, 0) <= 0) return false;
        if (kind != .drop and ch.remote_window == 0) return false;
        var buf: [16384]u8 = undefined;
        const limit: usize = if (kind == .drop) buf.len else @intCast(@min(buf.len, ch.remote_window, ch.remote_max));
        const n = f.read(buf[0..limit]) catch return true;
        if (n == 0) return true;
        if (kind == .drop) continue;
        var w = c.t.writer(if (kind == .data) Msg.channel_data else Msg.channel_extended_data);
        try w.int(ch.remote);
        if (kind == .stderr) try w.int(1);
        try w.string(buf[0..n]);
        try c.t.send(w.slice());
        ch.remote_window -= n;
    }
    return false;
}

// The program is stopped (SIGHUP from its console, then SIGKILL) and
// the slot freed.
fn endChannel(c: *Conn, ch: *Channel, reply: bool) void {
    if (!ch.used) return;
    if (ch.task != 0) {
        if (sys.taskEnded(ch.task) == null) {
            sys.signalSend(ch.task, sys.Signal.hup) catch {};
            sys.signalSend(ch.task, sys.Signal.kill) catch {};
        }
        _ = sys.taskWait(ch.task) catch {};
    }
    closeStreams(ch);
    if (reply and !ch.closing) {
        var w = c.t.writer(Msg.channel_close);
        w.int(ch.remote) catch {};
        c.t.send(w.slice()) catch {};
    }
    ch.reset();
}

// SSHD -s USER [-c LINE], as root: the user's home and variables, then
// the user's rights for good, and the shell or the command.
fn session(rest: []const u8) u8 {
    const name_end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
    const name = rest[0..name_end];
    const after = std.mem.trim(u8, rest[name_end..], " \t");
    var command: ?[]const u8 = null;
    if (after.len > 0) {
        if (!std.mem.startsWith(u8, after, "-c ")) return 1;
        command = std.mem.trim(u8, after[3..], " \t");
    }
    const list = zdos.allocator.create(users.List) catch return 1;
    list.* = .{};
    users.load(list) catch {};
    const u = list.find(name) orelse return 1;
    var home_buf: [300]u8 = undefined;
    const home = users.makeHome(u, &home_buf);
    zdos.setCwd(home) catch {};
    sys.pushVars() catch {};
    users.setUserVars(u, null);
    if (command == null) zdos.setVar("TERM", "vt100") catch {};
    users.become(u, u.uid) catch return 1;
    var shell_buf: [300]u8 = undefined;
    const shell = if (u.shell.len > 0) u.shell else zdos.getVar("COMSPEC", &shell_buf) orelse "C:\\APPS\\COMMAND.APP";
    if (command) |line| return zdos.runCommand(line) catch 127;
    const is_command = std.ascii.eqlIgnoreCase(std.fs.path.basenameWindows(shell), "COMMAND.APP");
    return zdos.exec(shell, if (is_command) "-l -d" else "") catch 127;
}
