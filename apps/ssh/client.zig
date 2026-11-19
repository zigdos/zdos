// The client side of SSH and SCP: host key check, login (Ed25519 key,
// else password) and one session channel.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const net = @import("../zdos/net.zig");
const users = @import("../zdos/users.zig");
const ssh = @import("transport.zig");
const wire = @import("wire.zig");
const keys = @import("keys.zig");
const cores = @import("cores.zig");

const Msg = ssh.Msg;
const Ed25519 = @import("../zdos/zcrypt.zig").Ed25519;

pub const Error = error{ AuthFailed, ChannelRefused, RequestRefused } || ssh.Error;

pub const window_size: u32 = 256 * 1024;
const packet_max: u32 = 32768;

pub const Options = struct {
    host: []const u8,
    port: u16 = 22,
    user: []const u8,
    identity: ?[]const u8 = null, // else %HOME%\.SSH\ID_ED25519
    batch: bool = false, // ask nothing: no passwords, no unknown hosts
};

pub const Event = union(enum) {
    none,
    data: []const u8,
    stderr: []const u8,
    eof,
    closed,
};

pub fn errorText(err: anyerror) []const u8 {
    inline for (@typeInfo(zdos.Error).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return zdos.message(@field(zdos.Error, e.name));
    }
    return switch (err) {
        error.AuthFailed => "permission denied",
        error.HostKeyRejected => "host key not accepted",
        error.BadHostKey => "unsupported or changed host key",
        error.BadSignature => "the host key's signature is wrong",
        error.NoCommonAlgorithm => "no algorithms in common (the server needs curve25519, ChaCha20 or AES-GCM)",
        error.Disconnected => "disconnected by the server",
        error.BadMac => "corrupted data",
        error.ChannelRefused, error.RequestRefused => "the server refused the session",
        else => @errorName(err),
    };
}

// "user@host" or "host" (user: USER).
pub fn splitTarget(text: []const u8, user_buf: []u8) struct { user: []const u8, host: []const u8 } {
    if (std.mem.lastIndexOfScalar(u8, text, '@')) |at| return .{ .user = text[0..at], .host = text[at + 1 ..] };
    return .{ .user = zdos.getVar("USER", user_buf) orelse "ROOT", .host = text };
}

pub const Client = struct {
    t: *ssh.Transport,
    sock: net.Socket,
    opts: Options,
    remote: u32 = 0,
    remote_window: u64 = 0,
    remote_max: u32 = 0,
    consumed: u32 = 0,
    exit_status: ?u32 = null,
    remote_eof: bool = false,
    closed: bool = false,
    reply: ?bool = null, // CHANNEL_SUCCESS / FAILURE came
    // Channel data that came while write waited for window space:
    stash: [window_size]u8 = undefined,
    stash_len: usize = 0,
    stash_given: usize = 0,

    pub fn connect(opts: Options) Error!*Client {
        const sock = try net.Socket.connectTo(opts.host, opts.port);
        errdefer sock.close();
        sock.setOption(net.SocketOption.no_delay, 1) catch {};
        sock.setOption(net.SocketOption.keepalive, 1) catch {};
        const c = try zdos.allocator.create(Client);
        errdefer zdos.allocator.destroy(c);
        c.* = .{ .t = try ssh.Transport.create(sock, .client), .sock = sock, .opts = opts };
        errdefer c.t.destroy();
        c.t.check_host = &checkHost;
        c.t.check_ctx = c;
        try c.t.handshake();
        var w = c.t.writer(Msg.service_request);
        try w.string("ssh-userauth");
        try c.t.send(w.slice());
        const p = try c.t.receive();
        if (p[0] != Msg.service_accept) return error.Protocol;
        try c.login();
        try c.openSession();
        return c;
    }

    pub fn deinit(self: *Client) void {
        self.t.destroy();
        self.sock.close();
        zdos.allocator.destroy(self);
    }

    fn login(self: *Client) Error!void {
        var methods_buf: [256]u8 = undefined;
        var methods: []const u8 = "";
        // "none" tells the methods (or lets in):
        {
            var w = self.t.writer(Msg.userauth_request);
            try w.string(self.opts.user);
            try w.string("ssh-connection");
            try w.string("none");
            try self.t.send(w.slice());
            switch (try self.authReply(&methods_buf, &methods)) {
                .success => return,
                else => {},
            }
        }
        if (wire.listHas(methods, "publickey")) {
            if (self.loadKey()) |kp| {
                if (try self.keyLogin(kp, &methods_buf, &methods)) return;
            }
        }
        if (self.opts.batch) return error.AuthFailed;
        var tries: usize = 0;
        while (tries < 3) : (tries += 1) {
            const kbd = wire.listHas(methods, "keyboard-interactive");
            if (!wire.listHas(methods, "password") and !kbd) break;
            var pw_buf: [128]u8 = undefined;
            defer users.wipe(&pw_buf);
            if (wire.listHas(methods, "password")) {
                zdos.printf("{s}@{s}'s password: ", .{ self.opts.user, self.opts.host });
                const pw = users.readLine(&pw_buf, true) orelse return error.AuthFailed;
                var w = self.t.writer(Msg.userauth_request);
                try w.string(self.opts.user);
                try w.string("ssh-connection");
                try w.string("password");
                try w.boolean(false);
                try w.string(pw);
                try self.t.send(w.slice());
            } else {
                var w = self.t.writer(Msg.userauth_request);
                try w.string(self.opts.user);
                try w.string("ssh-connection");
                try w.string("keyboard-interactive");
                try w.string("");
                try w.string("");
                try self.t.send(w.slice());
            }
            if (try self.authReply(&methods_buf, &methods) == .success) return;
            zdos.print("Permission denied, please try again.\n");
        }
        return error.AuthFailed;
    }

    const Reply = enum { success, failure };

    // Until SUCCESS or FAILURE (the methods left into methods); banners
    // shown, keyboard-interactive prompts answered.
    fn authReply(self: *Client, buf: *[256]u8, methods: *[]const u8) Error!Reply {
        while (true) {
            const p = try self.t.receive();
            var r = wire.Reader.init(p[1..]);
            switch (p[0]) {
                Msg.userauth_success => return .success,
                Msg.userauth_failure => {
                    const list = try r.string();
                    const n = @min(list.len, buf.len);
                    @memcpy(buf[0..n], list[0..n]);
                    methods.* = buf[0..n];
                    return .failure;
                },
                Msg.userauth_banner => zdos.print(try r.string()),
                Msg.userauth_pk_ok => try self.answerPrompts(&r),
                else => {},
            }
        }
    }

    // RFC 4256: each prompt answered as typed.
    fn answerPrompts(self: *Client, r: *wire.Reader) Error!void {
        const name = try r.string();
        const instruction = try r.string();
        _ = try r.string();
        const count = try r.int();
        if (name.len > 0) zdos.printf("{s}\n", .{name});
        if (instruction.len > 0) zdos.printf("{s}\n", .{instruction});
        var answers: [4][128]u8 = undefined;
        var lens: [4]usize = .{ 0, 0, 0, 0 };
        defer users.wipe(std.mem.asBytes(&answers));
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const prompt = try r.string();
            const echo = try r.boolean();
            if (i >= answers.len) continue;
            zdos.print(prompt);
            const a = users.readLine(&answers[i], !echo) orelse return error.AuthFailed;
            lens[i] = a.len;
        }
        var w = self.t.writer(Msg.userauth_info_response);
        try w.int(count);
        i = 0;
        while (i < count) : (i += 1) try w.string(if (i < answers.len) answers[i][0..lens[i]] else "");
        try self.t.send(w.slice());
    }

    fn loadKey(self: *Client) ?Ed25519.KeyPair {
        var path_buf: [320]u8 = undefined;
        const path = self.opts.identity orelse blk: {
            var hb: [300]u8 = undefined;
            const home = zdos.getVar("HOME", &hb) orelse return null;
            break :blk std.fmt.bufPrint(&path_buf, "{s}\\.SSH\\ID_ED25519", .{home}) catch return null;
        };
        return keys.loadPrivate(path, null) catch |err| switch (err) {
            error.NeedPassphrase => {
                if (self.opts.batch) return null;
                var pw_buf: [128]u8 = undefined;
                defer users.wipe(&pw_buf);
                zdos.printf("Enter passphrase for key '{s}': ", .{path});
                const pw = users.readLine(&pw_buf, true) orelse return null;
                return keys.loadPrivate(path, pw) catch |e| {
                    zdos.printf("{s}: {s}\n", .{ path, @errorName(e) });
                    return null;
                };
            },
            error.NotFound, error.PathNotFound => null,
            else => {
                if (self.opts.identity != null) zdos.printf("{s}: {s}\n", .{ path, @errorName(err) });
                return null;
            },
        };
    }

    const SignJob = struct {
        kp: Ed25519.KeyPair,
        data: []const u8,
        sig: [64]u8 = undefined,
        ok: bool = false,

        fn work(j: *SignJob) void {
            const s = j.kp.sign(j.data, null) catch return;
            j.sig = s.toBytes();
            j.ok = true;
        }
    };

    fn keyLogin(self: *Client, kp: Ed25519.KeyPair, buf: *[256]u8, methods: *[]const u8) Error!bool {
        var blob: [51]u8 = undefined;
        ssh.ed25519Blob(kp.public_key.toBytes(), &blob);
        var data: [1024]u8 = undefined;
        var d = wire.Writer.init(&data);
        try d.string(&self.t.session_id);
        try d.byte(Msg.userauth_request);
        try d.string(self.opts.user);
        try d.string("ssh-connection");
        try d.string("publickey");
        try d.boolean(true);
        try d.string("ssh-ed25519");
        try d.string(&blob);
        var job: SignJob = .{ .kp = kp, .data = d.slice() };
        cores.run(SignJob, &job, SignJob.work, false);
        if (!job.ok) return false;
        var sig: [83]u8 = undefined;
        var sw = wire.Writer.init(&sig);
        try sw.string("ssh-ed25519");
        try sw.string(&job.sig);
        // What was signed is the request after the session id and type byte:
        var w = self.t.writer(Msg.userauth_request);
        try w.bytes(data[4 + 32 + 1 .. d.len]);
        try w.string(sw.slice());
        try self.t.send(w.slice());
        return try self.authReply(buf, methods) == .success;
    }

    fn openSession(self: *Client) Error!void {
        var w = self.t.writer(Msg.channel_open);
        try w.string("session");
        try w.int(0);
        try w.int(window_size);
        try w.int(packet_max);
        try self.t.send(w.slice());
        while (true) {
            const p = try self.t.receive();
            var r = wire.Reader.init(p[1..]);
            switch (p[0]) {
                Msg.channel_open_confirmation => {
                    _ = try r.int();
                    self.remote = try r.int();
                    self.remote_window = try r.int();
                    self.remote_max = @max(try r.int(), 512);
                    return;
                },
                Msg.channel_open_failure => return error.ChannelRefused,
                Msg.global_request => try self.globalRequest(&r),
                else => {},
            }
        }
    }

    // cols x rows, as an xterm.
    pub fn requestPty(self: *Client, cols: u32, rows: u32) Error!void {
        var w = self.t.writer(Msg.channel_request);
        try w.int(self.remote);
        try w.string("pty-req");
        try w.boolean(true);
        try w.string("xterm");
        try w.int(cols);
        try w.int(rows);
        try w.int(0);
        try w.int(0);
        try w.string(&[1]u8{0}); // no terminal modes
        try self.t.send(w.slice());
        try self.requestReply();
    }

    // The shell (command null) or a command.
    pub fn start(self: *Client, command: ?[]const u8) Error!void {
        var w = self.t.writer(Msg.channel_request);
        try w.int(self.remote);
        try w.string(if (command != null) "exec" else "shell");
        try w.boolean(true);
        if (command) |cmd| try w.string(cmd);
        try self.t.send(w.slice());
        try self.requestReply();
    }

    fn requestReply(self: *Client) Error!void {
        while (true) {
            switch (try self.handle(try self.t.receive())) {
                .data => |d| self.keep(d),
                .stderr => |d| zdos.printError(d),
                .closed => return error.RequestRefused,
                else => {},
            }
            if (self.reply) |ok| {
                self.reply = null;
                if (!ok) return error.RequestRefused;
                return;
            }
        }
    }

    fn globalRequest(self: *Client, r: *wire.Reader) Error!void {
        _ = try r.string();
        if (try r.boolean()) try self.t.send(&[1]u8{Msg.request_failure});
    }

    // What a message means for the channel. Data is stashed while
    // something else waits (write, requestReply).
    fn handle(self: *Client, p: []const u8) Error!Event {
        var r = wire.Reader.init(p[1..]);
        switch (p[0]) {
            Msg.channel_data => {
                _ = try r.int();
                return .{ .data = try r.string() };
            },
            Msg.channel_extended_data => {
                _ = try r.int();
                _ = try r.int();
                return .{ .stderr = try r.string() };
            },
            Msg.channel_window_adjust => {
                _ = try r.int();
                self.remote_window +|= try r.int();
            },
            Msg.channel_eof => {
                self.remote_eof = true;
                return .eof;
            },
            Msg.channel_close => {
                if (!self.closed) {
                    var w = self.t.writer(Msg.channel_close);
                    try w.int(self.remote);
                    try self.t.send(w.slice());
                }
                self.closed = true;
                return .closed;
            },
            Msg.channel_request => {
                _ = try r.int();
                const kind = try r.string();
                const want_reply = try r.boolean();
                if (std.mem.eql(u8, kind, "exit-status")) {
                    self.exit_status = try r.int();
                } else if (std.mem.eql(u8, kind, "exit-signal")) {
                    self.exit_status = 255;
                }
                if (want_reply) {
                    var w = self.t.writer(Msg.channel_failure);
                    try w.int(self.remote);
                    try self.t.send(w.slice());
                }
            },
            Msg.channel_success => self.reply = true,
            Msg.channel_failure => self.reply = false,
            Msg.global_request => try self.globalRequest(&r),
            else => {},
        }
        return .none;
    }

    // Stashed data first, then the next message (waits for it).
    pub fn next(self: *Client) Error!Event {
        if (self.stash_given < self.stash_len) {
            const d = self.stash[self.stash_given..self.stash_len];
            self.stash_given = self.stash_len;
            try self.used(d.len);
            return .{ .data = d };
        }
        self.stash_len = 0;
        self.stash_given = 0;
        const ev = try self.handle(try self.t.receive());
        switch (ev) {
            .data, .stderr => |d| try self.used(d.len),
            else => {},
        }
        return ev;
    }

    // Without waiting.
    pub fn ready(self: *const Client) bool {
        return self.stash_given < self.stash_len or self.t.buffered();
    }

    // The window opened again for what the program took.
    fn used(self: *Client, n: usize) Error!void {
        self.consumed += @intCast(n);
        if (self.consumed < window_size / 2 or self.closed) return;
        var w = self.t.writer(Msg.channel_window_adjust);
        try w.int(self.remote);
        try w.int(self.consumed);
        try self.t.send(w.slice());
        self.consumed = 0;
    }

    pub fn write(self: *Client, data: []const u8) Error!void {
        var rest = data;
        while (rest.len > 0) {
            if (self.closed) return error.ConnectionAborted;
            if (self.remote_window == 0) {
                const ev = try self.handle(try self.t.receive());
                switch (ev) {
                    .data => |d| self.keep(d),
                    .stderr => |d| zdos.printError(d),
                    else => {},
                }
                continue;
            }
            const n: usize = @intCast(@min(rest.len, self.remote_window, self.remote_max, packet_max - 64));
            var w = self.t.writer(Msg.channel_data);
            try w.int(self.remote);
            try w.string(rest[0..n]);
            try self.t.send(w.slice());
            self.remote_window -= n;
            rest = rest[n..];
        }
    }

    fn keep(self: *Client, d: []const u8) void {
        const n = @min(d.len, self.stash.len - self.stash_len);
        @memcpy(self.stash[self.stash_len..][0..n], d[0..n]);
        self.stash_len += n;
    }

    pub fn sendEof(self: *Client) Error!void {
        var w = self.t.writer(Msg.channel_eof);
        try w.int(self.remote);
        try self.t.send(w.slice());
    }

    pub fn close(self: *Client) void {
        if (!self.closed) {
            var w = self.t.writer(Msg.channel_close);
            w.int(self.remote) catch {};
            self.t.send(w.slice()) catch {};
            self.closed = true;
        }
        self.t.disconnect(11, "bye");
    }
};

// Against KNOWN_HOSTS; a new key is shown and, if accepted, added.
fn checkHost(ctx: ?*anyopaque, blob: []const u8) bool {
    const c: *Client = @ptrCast(@alignCast(ctx.?));
    var name_buf: [300]u8 = undefined;
    const name = if (c.opts.port == 22) c.opts.host else std.fmt.bufPrint(&name_buf, "[{s}]:{d}", .{ c.opts.host, c.opts.port }) catch return false;
    var hb: [300]u8 = undefined;
    const home = zdos.getVar("HOME", &hb) orelse "C:\\USERS\\ROOT";
    var dir_buf: [320]u8 = undefined;
    const dir = std.fmt.bufPrint(&dir_buf, "{s}\\.SSH", .{home}) catch return false;
    var path_buf: [340]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}\\KNOWN_HOSTS", .{dir}) catch return false;
    var fp: [64]u8 = undefined;
    switch (keys.checkKnownHost(path, name, blob)) {
        .known => return true,
        .changed => {
            zdos.eprintf("WARNING: the host key of {s} has changed (now {s})!\nSomeone may be listening in. The old key is in {s}.\n", .{ name, keys.fingerprint(blob, &fp), path });
            return false;
        },
        .unknown => {},
    }
    if (c.opts.batch) {
        zdos.eprintf("Host key of {s} is not known ({s})\n", .{ name, keys.fingerprint(blob, &fp) });
        return false;
    }
    var kr = wire.Reader.init(blob);
    zdos.printf("The authenticity of host '{s}' can't be established.\n{s} key fingerprint is {s}.\nAre you sure you want to continue connecting (yes/no)? ", .{ name, kr.string() catch "?", keys.fingerprint(blob, &fp) });
    var answer_buf: [8]u8 = undefined;
    const answer = users.readLine(&answer_buf, false) orelse return false;
    if (!std.ascii.eqlIgnoreCase(answer, "yes") and !std.ascii.eqlIgnoreCase(answer, "y")) return false;
    zdos.makeDir(dir) catch {};
    keys.addKnownHost(path, name, blob) catch |err| zdos.printf("{s}: {s}\n", .{ path, zdos.message(err) });
    zdos.printf("Added '{s}' to the list of known hosts.\n", .{name});
    return true;
}
