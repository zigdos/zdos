// SSH's transport (RFC 4253) for both ends: curve25519-sha256 (strict
// as OpenSSH's), chacha20-poly1305@openssh.com or AES-GCM, Ed25519
// host keys (and ECDSA P-256 for checking a server's). The kex math and
// large packets run on another core when one is free.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const net = @import("../zdos/net.zig");
const wire = @import("wire.zig");
const cores = @import("cores.zig");

const zc = @import("../zdos/zcrypt.zig"); // ZCRYPT.ZDL
const Ed25519 = zc.Ed25519;
const X25519 = zc.X25519;
const Sha256 = zc.Sha256;
const ChaCha = zc.ChaCha20With64BitNonce;
const Poly1305 = zc.Poly1305;
const Aes128Gcm = zc.Aes128Gcm;
const Aes256Gcm = zc.Aes256Gcm;
const P256 = zc.EcdsaP256Sha256;

pub const Msg = struct {
    pub const disconnect = 1;
    pub const ignore = 2;
    pub const unimplemented = 3;
    pub const debug = 4;
    pub const service_request = 5;
    pub const service_accept = 6;
    pub const ext_info = 7;
    pub const kexinit = 20;
    pub const newkeys = 21;
    pub const kex_ecdh_init = 30;
    pub const kex_ecdh_reply = 31;
    pub const userauth_request = 50;
    pub const userauth_failure = 51;
    pub const userauth_success = 52;
    pub const userauth_banner = 53;
    pub const userauth_pk_ok = 60; // keyboard-interactive: info_request
    pub const userauth_info_response = 61;
    pub const global_request = 80;
    pub const request_success = 81;
    pub const request_failure = 82;
    pub const channel_open = 90;
    pub const channel_open_confirmation = 91;
    pub const channel_open_failure = 92;
    pub const channel_window_adjust = 93;
    pub const channel_data = 94;
    pub const channel_extended_data = 95;
    pub const channel_eof = 96;
    pub const channel_close = 97;
    pub const channel_request = 98;
    pub const channel_success = 99;
    pub const channel_failure = 100;
};

pub const Error = error{
    Protocol,
    NoCommonAlgorithm,
    BadHostKey,
    HostKeyRejected,
    BadSignature,
    Disconnected,
    BadMac,
} || wire.Error || zdos.Error;

pub const Role = enum { client, server };

const Cipher = enum { none, chacha, aes128_gcm, aes256_gcm };

const Keys = struct {
    cipher: Cipher = .none,
    key: [64]u8 = undefined,
    iv: [12]u8 = undefined,
    seq: u32 = 0,
};

pub const max_packet = 35000; // RFC 4253 6.1: what every end accepts
const tag_len = 16;
// Smaller packets cost more to hand over than to encrypt here.
const offload_min = 4096;

const version_text = "SSH-2.0-ZDOS_1.0";
const ciphers = "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com";

pub const Transport = struct {
    sock: net.Socket,
    role: Role,
    // Server: its host key:
    host_key: ?Ed25519.KeyPair = null,
    // Client: asked about the server's host key blob; false refuses it:
    check_host: ?*const fn (ctx: ?*anyopaque, blob: []const u8) bool = null,
    check_ctx: ?*anyopaque = null,
    host_blob: [160]u8 = undefined, // re-keying must not change it
    host_blob_len: usize = 0,

    peer_version: [256]u8 = undefined,
    peer_version_len: usize = 0,
    my_kexinit: [512]u8 = undefined,
    my_kexinit_len: usize = 0,
    peer_kexinit: [2048]u8 = undefined,
    peer_kexinit_len: usize = 0,
    session_id: [32]u8 = undefined,
    have_session: bool = false,
    strict: bool = false,
    in: Keys = .{},
    out: Keys = .{},
    // The peer's DISCONNECT text:
    reason: [128]u8 = undefined,
    reason_len: usize = 0,

    raw: [max_packet + 128]u8 = undefined, // received, not yet used
    raw_start: usize = 0,
    raw_end: usize = 0,
    payload: [max_packet]u8 = undefined, // the last packet's
    plain: [max_packet + 64]u8 = undefined, // before encryption
    pkt: [max_packet + 64]u8 = undefined,
    msg: [max_packet]u8 = undefined, // for messages being built (writer)

    pub fn create(sock: net.Socket, role: Role) Error!*Transport {
        const t = try zdos.allocator.create(Transport);
        t.* = .{ .sock = sock, .role = role };
        return t;
    }

    pub fn destroy(self: *Transport) void {
        std.crypto.secureZero(u8, std.mem.asBytes(&self.in));
        std.crypto.secureZero(u8, std.mem.asBytes(&self.out));
        zdos.allocator.destroy(self);
    }

    pub fn disconnectText(self: *const Transport) []const u8 {
        return self.reason[0..self.reason_len];
    }

    // Built in self.msg: begin, then send(w.slice()).
    pub fn writer(self: *Transport, kind: u8) wire.Writer {
        var w = wire.Writer.init(&self.msg);
        w.byte(kind) catch unreachable;
        return w;
    }

    pub fn handshake(self: *Transport) Error!void {
        try self.sock.sendAll(version_text ++ "\r\n");
        try self.readVersion();
        try self.kex(null);
    }

    // Lines before the version line are the server's (RFC 4253 4.2).
    fn readVersion(self: *Transport) Error!void {
        var lines: usize = 0;
        while (lines < 50) : (lines += 1) {
            var len: usize = 0;
            while (true) {
                if (self.raw_start == self.raw_end) try self.fill();
                const c = self.raw[self.raw_start];
                self.raw_start += 1;
                if (c == '\n') break;
                if (len < self.peer_version.len) {
                    self.peer_version[len] = c;
                    len += 1;
                } else return error.Protocol;
            }
            if (len > 0 and self.peer_version[len - 1] == '\r') len -= 1;
            const line = self.peer_version[0..len];
            if (std.mem.startsWith(u8, line, "SSH-")) {
                if (!std.mem.startsWith(u8, line, "SSH-2.0-") and !std.mem.startsWith(u8, line, "SSH-1.99-")) return error.Protocol;
                self.peer_version_len = len;
                return;
            }
            if (self.role == .server) return error.Protocol;
        }
        return error.Protocol;
    }

    fn fill(self: *Transport) Error!void {
        if (self.raw_start == self.raw_end) {
            self.raw_start = 0;
            self.raw_end = 0;
        } else if (self.raw_start > 0 and self.raw_end == self.raw.len) {
            std.mem.copyForwards(u8, self.raw[0 .. self.raw_end - self.raw_start], self.raw[self.raw_start..self.raw_end]);
            self.raw_end -= self.raw_start;
            self.raw_start = 0;
        }
        if (self.raw_end == self.raw.len) return error.Protocol;
        const n = try self.sock.recv(self.raw[self.raw_end..]);
        if (n == 0) return error.ConnectionAborted;
        self.raw_end += n;
    }

    fn need(self: *Transport, n: usize) Error![]u8 {
        if (n > self.raw.len) return error.Protocol;
        if (self.raw.len - self.raw_start < n) {
            std.mem.copyForwards(u8, self.raw[0 .. self.raw_end - self.raw_start], self.raw[self.raw_start..self.raw_end]);
            self.raw_end -= self.raw_start;
            self.raw_start = 0;
        }
        while (self.raw_end - self.raw_start < n) try self.fill();
        return self.raw[self.raw_start..][0..n];
    }

    // poll on the socket wouldn't say so.
    pub fn buffered(self: *const Transport) bool {
        return self.raw_end > self.raw_start;
    }

    fn readPacket(self: *Transport) Error![]const u8 {
        const k = &self.in;
        var nonce: [8]u8 = undefined;
        std.mem.writeInt(u64, &nonce, k.seq, .big);
        var len: u32 = undefined;
        var body: []const u8 = undefined; // padding length, payload, padding
        switch (k.cipher) {
            .none => {
                len = std.mem.readInt(u32, (try self.need(4))[0..4], .big);
                if (len < 5 or len > max_packet) return error.Protocol;
                const all = try self.need(4 + len);
                @memcpy(self.plain[0..len], all[4..]);
                body = self.plain[0..len];
                self.raw_start += 4 + len;
            },
            .chacha => {
                var enc_len: [4]u8 = (try self.need(4))[0..4].*;
                var plain_len: [4]u8 = undefined;
                ChaCha.xor(&plain_len, &enc_len, 0, k.key[32..64].*, nonce);
                len = std.mem.readInt(u32, &plain_len, .big);
                if (len < 8 or len > max_packet or len % 8 != 0) return error.Protocol;
                const all = try self.need(4 + len + tag_len);
                if (!open(k, nonce, all, self.plain[0..len])) return error.BadMac;
                body = self.plain[0..len];
                self.raw_start += 4 + len + tag_len;
            },
            .aes128_gcm, .aes256_gcm => {
                len = std.mem.readInt(u32, (try self.need(4))[0..4], .big);
                if (len < 16 or len > max_packet or len % 16 != 0) return error.Protocol;
                const all = try self.need(4 + len + tag_len);
                if (!open(k, nonce, all, self.plain[0..len])) return error.BadMac;
                nextIv(&k.iv);
                body = self.plain[0..len];
                self.raw_start += 4 + len + tag_len;
            },
        }
        k.seq +%= 1;
        const pad = body[0];
        if (@as(usize, pad) + 2 > body.len) return error.Protocol;
        const n = body.len - 1 - pad;
        @memcpy(self.payload[0..n], body[1..][0..n]);
        return self.payload[0..n];
    }

    pub fn send(self: *Transport, payload: []const u8) Error!void {
        const k = &self.out;
        const aead = k.cipher != .none;
        const block: usize = if (k.cipher == .aes128_gcm or k.cipher == .aes256_gcm) 16 else 8;
        // Padded to the block; the length field counts unless AEAD:
        const counted = 1 + payload.len + @as(usize, if (aead) 0 else 4);
        var pad = block - counted % block;
        if (pad < 4) pad += block;
        const len = 1 + payload.len + pad;
        if (len + 4 + tag_len > self.pkt.len) return error.TooLong;
        self.plain[0] = @intCast(pad);
        @memcpy(self.plain[1..][0..payload.len], payload);
        @memset(self.plain[1 + payload.len ..][0..pad], 0);
        std.mem.writeInt(u32, self.pkt[0..4], @intCast(len), .big);
        var nonce: [8]u8 = undefined;
        std.mem.writeInt(u64, &nonce, k.seq, .big);
        var total = 4 + len;
        if (k.cipher == .none) {
            @memcpy(self.pkt[4..][0..len], self.plain[0..len]);
        } else {
            seal(k, nonce, self.pkt[0 .. 4 + len + tag_len], self.plain[0..len]);
            if (k.cipher != .chacha) nextIv(&k.iv);
            total += tag_len;
        }
        k.seq +%= 1;
        try self.sock.sendAll(self.pkt[0..total]);
    }

    // Transport messages are handled here (a re-keying the peer starts,
    // ignored ones, DISCONNECT).
    pub fn receive(self: *Transport) Error![]const u8 {
        while (true) {
            const p = try self.readPacket();
            if (p.len == 0) return error.Protocol;
            switch (p[0]) {
                Msg.ignore, Msg.debug, Msg.unimplemented, Msg.ext_info => continue,
                Msg.disconnect => {
                    var r = wire.Reader.init(p[1..]);
                    _ = r.int() catch 0;
                    const text = r.string() catch "";
                    self.reason_len = @min(text.len, self.reason.len);
                    @memcpy(self.reason[0..self.reason_len], text[0..self.reason_len]);
                    return error.Disconnected;
                },
                Msg.kexinit => {
                    try self.kex(p);
                    continue;
                },
                else => return p,
            }
        }
    }

    pub fn disconnect(self: *Transport, reason: u32, text: []const u8) void {
        var w = self.writer(Msg.disconnect);
        w.int(reason) catch {};
        w.string(text) catch {};
        w.string("") catch {};
        self.send(w.slice()) catch {};
    }

    // KEY EXCHANGE

    fn buildKexinit(self: *Transport) void {
        var w = wire.Writer.init(&self.my_kexinit);
        w.byte(Msg.kexinit) catch unreachable;
        var cookie: [16]u8 = undefined;
        zdos.randomBytes(&cookie);
        w.bytes(&cookie) catch unreachable;
        const kex_list = if (self.role == .client)
            "curve25519-sha256,curve25519-sha256@libssh.org,kex-strict-c-v00@openssh.com"
        else
            "curve25519-sha256,curve25519-sha256@libssh.org,kex-strict-s-v00@openssh.com";
        w.string(kex_list) catch unreachable;
        w.string(if (self.role == .client) "ssh-ed25519,ecdsa-sha2-nistp256" else "ssh-ed25519") catch unreachable;
        w.string(ciphers) catch unreachable;
        w.string(ciphers) catch unreachable;
        // AEAD makes the MAC unused; a name for peers that compare lists:
        w.string("hmac-sha2-256") catch unreachable;
        w.string("hmac-sha2-256") catch unreachable;
        w.string("none") catch unreachable;
        w.string("none") catch unreachable;
        w.string("") catch unreachable;
        w.string("") catch unreachable;
        w.boolean(false) catch unreachable;
        w.int(0) catch unreachable;
        self.my_kexinit_len = w.len;
    }

    // The first, or one the peer started with its KEXINIT.
    fn kex(self: *Transport, peer_first: ?[]const u8) Error!void {
        const first = !self.have_session;
        self.buildKexinit();
        try self.send(self.my_kexinit[0..self.my_kexinit_len]);
        const peer = peer_first orelse blk: {
            const p = try self.readPacket();
            if (p.len == 0 or p[0] != Msg.kexinit) return error.Protocol;
            break :blk p;
        };
        if (peer.len > self.peer_kexinit.len) return error.TooLong;
        @memcpy(self.peer_kexinit[0..peer.len], peer);
        self.peer_kexinit_len = peer.len;

        var r = wire.Reader.init(self.peer_kexinit[0..peer.len]);
        _ = try r.bytes(17);
        const lists = [_][]const u8{ try r.string(), try r.string(), try r.string(), try r.string(), try r.string(), try r.string(), try r.string(), try r.string() };
        var mine = wire.Reader.init(self.my_kexinit[0..self.my_kexinit_len]);
        _ = try mine.bytes(17);
        const my_lists = [_][]const u8{ try mine.string(), try mine.string(), try mine.string(), try mine.string(), try mine.string(), try mine.string(), try mine.string(), try mine.string() };
        const c = if (self.role == .client) my_lists else lists;
        const s = if (self.role == .client) lists else my_lists;
        _ = wire.choose(c[0], s[0]) orelse return error.NoCommonAlgorithm; // both curve25519
        const host_alg = wire.choose(c[1], s[1]) orelse return error.NoCommonAlgorithm;
        const c2s = cipherOf(wire.choose(c[2], s[2]) orelse return error.NoCommonAlgorithm);
        const s2c = cipherOf(wire.choose(c[3], s[3]) orelse return error.NoCommonAlgorithm);
        _ = wire.choose(c[6], s[6]) orelse return error.NoCommonAlgorithm;
        _ = wire.choose(c[7], s[7]) orelse return error.NoCommonAlgorithm;
        if (first) {
            self.strict = if (self.role == .client)
                wire.listHas(lists[0], "kex-strict-s-v00@openssh.com")
            else
                wire.listHas(lists[0], "kex-strict-c-v00@openssh.com");
        }

        var h: [32]u8 = undefined;
        var k_enc: [37]u8 = undefined; // K as mpint
        var k_len: usize = 0;
        if (self.role == .client) try self.kexClient(host_alg, &h, &k_enc, &k_len) else try self.kexServer(&h, &k_enc, &k_len);
        defer std.crypto.secureZero(u8, &k_enc);
        if (first) {
            self.session_id = h;
            self.have_session = true;
        }

        // NEWKEYS each way; the new keys start with the next packet:
        var next_out: Keys = .{};
        var next_in: Keys = .{};
        const out_c = if (self.role == .client) c2s else s2c;
        const in_c = if (self.role == .client) s2c else c2s;
        self.derive(&next_out, out_c, k_enc[0..k_len], &h, if (self.role == .client) 'A' else 'B');
        self.derive(&next_in, in_c, k_enc[0..k_len], &h, if (self.role == .client) 'B' else 'A');
        try self.send(&[1]u8{Msg.newkeys});
        next_out.seq = if (self.strict) 0 else self.out.seq;
        self.out = next_out;
        const nk = try self.readPacket();
        if (nk.len != 1 or nk[0] != Msg.newkeys) return error.Protocol;
        next_in.seq = if (self.strict) 0 else self.in.seq;
        self.in = next_in;
    }

    // IV letter, then key letter + 2 ('A'/'C', 'B'/'D').
    fn derive(self: *const Transport, out: *Keys, cipher: Cipher, k: []const u8, h: *const [32]u8, iv_letter: u8) void {
        out.cipher = cipher;
        var iv: [32]u8 = undefined;
        self.deriveBytes(k, h, iv_letter, &iv);
        @memcpy(&out.iv, iv[0..12]);
        self.deriveBytes(k, h, iv_letter + 2, &out.key);
    }

    // RFC 4253 7.2: HASH(K || H || letter || session_id), then extended.
    fn deriveBytes(self: *const Transport, k: []const u8, h: *const [32]u8, letter: u8, out: []u8) void {
        var first: Sha256 = .init(.{});
        first.update(k);
        first.update(h);
        first.update(&[1]u8{letter});
        first.update(&self.session_id);
        var block: [32]u8 = undefined;
        first.final(&block);
        var have: usize = @min(32, out.len);
        @memcpy(out[0..have], block[0..have]);
        while (have < out.len) {
            var more: Sha256 = .init(.{});
            more.update(k);
            more.update(h);
            more.update(out[0..have]);
            more.final(&block);
            const n = @min(32, out.len - have);
            @memcpy(out[have..][0..n], block[0..n]);
            have += n;
        }
    }

    // V_C, V_S, I_C, I_S, K_S
    fn hashStart(self: *const Transport, host_blob: []const u8) Sha256 {
        var h: Sha256 = .init(.{});
        const v_mine = version_text;
        const v_peer = self.peer_version[0..self.peer_version_len];
        hashString(&h, if (self.role == .client) v_mine else v_peer);
        hashString(&h, if (self.role == .client) v_peer else v_mine);
        const i_mine = self.my_kexinit[0..self.my_kexinit_len];
        const i_peer = self.peer_kexinit[0..self.peer_kexinit_len];
        hashString(&h, if (self.role == .client) i_mine else i_peer);
        hashString(&h, if (self.role == .client) i_peer else i_mine);
        hashString(&h, host_blob);
        return h;
    }

    fn kexClient(self: *Transport, host_alg: []const u8, h_out: *[32]u8, k_enc: *[37]u8, k_len: *usize) Error!void {
        var job: ClientJob = .{};
        zdos.randomBytes(&job.seed);
        cores.run(ClientJob, &job, ClientJob.ourKey, false);
        if (!job.ok) return error.Protocol;
        var w = self.writer(Msg.kex_ecdh_init);
        try w.string(&job.our_pub);
        try self.send(w.slice());

        const p = try self.readPacket();
        if (p.len == 0 or p[0] != Msg.kex_ecdh_reply) return error.Protocol;
        var r = wire.Reader.init(p[1..]);
        const host_blob = try r.string();
        const q_s = try r.string();
        const sig_blob = try r.string();
        if (q_s.len != 32 or host_blob.len > self.host_blob.len) return error.Protocol;
        // Its kind must be the one agreed; re-keying keeps it:
        var hb = wire.Reader.init(host_blob);
        if (!std.mem.eql(u8, try hb.string(), host_alg)) return error.BadHostKey;
        if (self.have_session) {
            if (!std.mem.eql(u8, host_blob, self.host_blob[0..self.host_blob_len])) return error.BadHostKey;
        } else {
            @memcpy(self.host_blob[0..host_blob.len], host_blob);
            self.host_blob_len = host_blob.len;
        }
        job.peer_pub = q_s[0..32].*;
        job.hash = self.hashStart(host_blob);
        hashString(&job.hash, &job.our_pub);
        hashString(&job.hash, q_s);
        try parseHostKey(&job, host_alg, host_blob, sig_blob);
        cores.run(ClientJob, &job, ClientJob.finish, false);
        defer std.crypto.secureZero(u8, &job.seed);
        if (!job.ok) return error.Protocol;
        if (!job.verified) return error.BadSignature;
        h_out.* = job.h;
        k_len.* = encodeK(&job.shared, k_enc);
        std.crypto.secureZero(u8, &job.shared);
        if (!self.have_session) {
            const check = self.check_host orelse return error.HostKeyRejected;
            if (!check(self.check_ctx, host_blob)) return error.HostKeyRejected;
        }
    }

    fn kexServer(self: *Transport, h_out: *[32]u8, k_enc: *[37]u8, k_len: *usize) Error!void {
        const key = self.host_key orelse return error.BadHostKey;
        const p = try self.readPacket();
        if (p.len == 0 or p[0] != Msg.kex_ecdh_init) return error.Protocol;
        var r = wire.Reader.init(p[1..]);
        const q_c = try r.string();
        if (q_c.len != 32) return error.Protocol;
        var job: ServerJob = .{ .key = key, .peer_pub = q_c[0..32].* };
        zdos.randomBytes(&job.seed);
        var blob: [51]u8 = undefined;
        ed25519Blob(key.public_key.toBytes(), &blob);
        job.hash = self.hashStart(&blob);
        hashString(&job.hash, q_c);
        cores.run(ServerJob, &job, ServerJob.work, false);
        defer std.crypto.secureZero(u8, &job.seed);
        if (!job.ok) return error.Protocol;

        var w = self.writer(Msg.kex_ecdh_reply);
        try w.string(&blob);
        try w.string(&job.our_pub);
        var sig: [83]u8 = undefined;
        var sw = wire.Writer.init(&sig);
        try sw.string("ssh-ed25519");
        try sw.string(&job.sig);
        try w.string(sw.slice());
        try self.send(w.slice());
        h_out.* = job.h;
        k_len.* = encodeK(&job.shared, k_enc);
        std.crypto.secureZero(u8, &job.shared);
    }
};

// PACKET CRYPTO: pure computation, so on another core for large ones

const Seal = struct {
    k: *const Keys,
    nonce: [8]u8,
    pkt: []u8, // length field, room for the body and tag
    plain: []const u8,

    fn work(j: *Seal) void {
        sealHere(j.k, j.nonce, j.pkt, j.plain);
    }
};

// pkt: the plain length field first; gets the encrypted packet and tag.
fn seal(k: *const Keys, nonce: [8]u8, pkt: []u8, plain: []const u8) void {
    var job: Seal = .{ .k = k, .nonce = nonce, .pkt = pkt, .plain = plain };
    if (plain.len >= offload_min) cores.run(Seal, &job, Seal.work, false) else sealHere(k, nonce, pkt, plain);
}

fn sealHere(k: *const Keys, nonce: [8]u8, pkt: []u8, plain: []const u8) void {
    const len = plain.len;
    switch (k.cipher) {
        .none => unreachable,
        .chacha => {
            const plain_len = pkt[0..4].*;
            ChaCha.xor(pkt[0..4], &plain_len, 0, k.key[32..64].*, nonce);
            ChaCha.xor(pkt[4..][0..len], plain, 1, k.key[0..32].*, nonce);
            var poly_key: [32]u8 = undefined;
            ChaCha.stream(&poly_key, 0, k.key[0..32].*, nonce);
            Poly1305.create(pkt[4 + len ..][0..16], pkt[0 .. 4 + len], &poly_key);
        },
        .aes128_gcm, .aes256_gcm => {
            const ad = pkt[0..4].*;
            if (k.cipher == .aes128_gcm) {
                Aes128Gcm.encrypt(pkt[4..][0..len], pkt[4 + len ..][0..16], plain, &ad, k.iv, k.key[0..16].*);
            } else {
                Aes256Gcm.encrypt(pkt[4..][0..len], pkt[4 + len ..][0..16], plain, &ad, k.iv, k.key[0..32].*);
            }
        },
    }
}

const Open = struct {
    k: *const Keys,
    nonce: [8]u8,
    all: []const u8, // length field, body, tag
    out: []u8,
    ok: bool = false,

    fn work(j: *Open) void {
        j.ok = openHere(j.k, j.nonce, j.all, j.out);
    }
};

// Checked and decrypted into out; false if forged.
fn open(k: *const Keys, nonce: [8]u8, all: []const u8, out: []u8) bool {
    var job: Open = .{ .k = k, .nonce = nonce, .all = all, .out = out };
    if (out.len >= offload_min) {
        cores.run(Open, &job, Open.work, false);
        return job.ok;
    }
    return openHere(k, nonce, all, out);
}

fn openHere(k: *const Keys, nonce: [8]u8, all: []const u8, out: []u8) bool {
    const len = out.len;
    switch (k.cipher) {
        .none => unreachable,
        .chacha => {
            var poly_key: [32]u8 = undefined;
            ChaCha.stream(&poly_key, 0, k.key[0..32].*, nonce);
            var tag: [16]u8 = undefined;
            Poly1305.create(&tag, all[0 .. 4 + len], &poly_key);
            if (!std.crypto.timing_safe.eql([16]u8, tag, all[4 + len ..][0..16].*)) return false;
            ChaCha.xor(out, all[4..][0..len], 1, k.key[0..32].*, nonce);
        },
        .aes128_gcm, .aes256_gcm => {
            const tag = all[4 + len ..][0..16].*;
            if (k.cipher == .aes128_gcm) {
                Aes128Gcm.decrypt(out, all[4..][0..len], tag, all[0..4], k.iv, k.key[0..16].*) catch return false;
            } else {
                Aes256Gcm.decrypt(out, all[4..][0..len], tag, all[0..4], k.iv, k.key[0..32].*) catch return false;
            }
        },
    }
    return true;
}

// On another core if free: its public key, then the shared secret, H,
// and the server's signature checked.
const ClientJob = struct {
    seed: [32]u8 = undefined,
    our_pub: [32]u8 = undefined,
    peer_pub: [32]u8 = undefined,
    shared: [32]u8 = undefined,
    hash: Sha256 = undefined,
    h: [32]u8 = undefined,
    host: union(enum) { none, ed25519: Ed25519.PublicKey, p256: P256.PublicKey } = .none,
    sig_ed: [64]u8 = undefined,
    sig_p256: [64]u8 = undefined,
    ok: bool = false,
    verified: bool = false,

    fn ourKey(j: *ClientJob) void {
        j.our_pub = X25519.recoverPublicKey(j.seed) catch return;
        j.ok = true;
    }

    fn finish(j: *ClientJob) void {
        j.ok = false;
        j.shared = X25519.scalarmult(j.seed, j.peer_pub) catch return;
        var k_enc: [37]u8 = undefined;
        const n = encodeK(&j.shared, &k_enc);
        j.hash.update(k_enc[0..n]);
        j.hash.final(&j.h);
        j.ok = true;
        switch (j.host) {
            .none => {},
            .ed25519 => |pk| {
                const sig = Ed25519.Signature.fromBytes(j.sig_ed);
                sig.verify(&j.h, pk) catch return;
                j.verified = true;
            },
            .p256 => |pk| {
                const sig = P256.Signature.fromBytes(j.sig_p256);
                sig.verify(&j.h, pk) catch return;
                j.verified = true;
            },
        }
    }
};

const ServerJob = struct {
    key: Ed25519.KeyPair,
    seed: [32]u8 = undefined,
    our_pub: [32]u8 = undefined,
    peer_pub: [32]u8,
    shared: [32]u8 = undefined,
    hash: Sha256 = undefined,
    h: [32]u8 = undefined,
    sig: [64]u8 = undefined,
    ok: bool = false,

    fn work(j: *ServerJob) void {
        j.our_pub = X25519.recoverPublicKey(j.seed) catch return;
        j.shared = X25519.scalarmult(j.seed, j.peer_pub) catch return;
        hashString(&j.hash, &j.our_pub);
        var k_enc: [37]u8 = undefined;
        const n = encodeK(&j.shared, &k_enc);
        j.hash.update(k_enc[0..n]);
        j.hash.final(&j.h);
        const s = j.key.sign(&j.h, null) catch return;
        j.sig = s.toBytes();
        j.ok = true;
    }
};

// Into the job, for checking there.
fn parseHostKey(job: *ClientJob, alg: []const u8, blob: []const u8, sig_blob: []const u8) Error!void {
    var b = wire.Reader.init(blob);
    _ = try b.string();
    var s = wire.Reader.init(sig_blob);
    if (!std.mem.eql(u8, try s.string(), alg)) return error.BadSignature;
    if (std.mem.eql(u8, alg, "ssh-ed25519")) {
        const pk = try b.string();
        const sig = try s.string();
        if (pk.len != 32 or sig.len != 64) return error.BadHostKey;
        job.host = .{ .ed25519 = Ed25519.PublicKey.fromBytes(pk[0..32].*) catch return error.BadHostKey };
        job.sig_ed = sig[0..64].*;
    } else if (std.mem.eql(u8, alg, "ecdsa-sha2-nistp256")) {
        if (!std.mem.eql(u8, try b.string(), "nistp256")) return error.BadHostKey;
        job.host = .{ .p256 = P256.PublicKey.fromSec1(try b.string()) catch return error.BadHostKey };
        // (mpint r, mpint s) as 32 bytes each:
        var rs = wire.Reader.init(try s.string());
        const r_part = try rs.mpint();
        const s_part = try rs.mpint();
        if (r_part.len > 32 or s_part.len > 32) return error.BadSignature;
        @memset(&job.sig_p256, 0);
        @memcpy(job.sig_p256[32 - r_part.len .. 32], r_part);
        @memcpy(job.sig_p256[64 - s_part.len .. 64], s_part);
    } else return error.BadHostKey;
}

// RFC 8731: the 32 bytes as an mpint.
fn encodeK(shared: *const [32]u8, out: *[37]u8) usize {
    var w = wire.Writer.init(out);
    w.mpint(shared) catch unreachable;
    return w.len;
}

fn hashString(h: *Sha256, s: []const u8) void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(s.len), .big);
    h.update(&len);
    h.update(s);
}

fn cipherOf(name: []const u8) Cipher {
    if (std.mem.eql(u8, name, "chacha20-poly1305@openssh.com")) return .chacha;
    if (std.mem.eql(u8, name, "aes256-gcm@openssh.com")) return .aes256_gcm;
    return .aes128_gcm;
}

// The IV's last 8 bytes.
fn nextIv(iv: *[12]u8) void {
    const n = std.mem.readInt(u64, iv[4..12], .big);
    std.mem.writeInt(u64, iv[4..12], n +% 1, .big);
}

// "ssh-ed25519" and the public key, as SSH sends keys.
pub fn ed25519Blob(pk: [32]u8, out: *[51]u8) void {
    var w = wire.Writer.init(out);
    w.string("ssh-ed25519") catch unreachable;
    w.string(&pk) catch unreachable;
}
