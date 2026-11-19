// A TLS 1.3 server (RFC 8446): X25519 or P-256, AES-128-GCM or
// ChaCha20-Poly1305, an ECDSA P-256 certificate; no client certificates,
// tickets or early data. Kex, signature and large writes run on a free core.
// Reads and writes through the caller's io.
const std = @import("std");
const zdos = @import("zdos");
const zc = zdos.zcrypt;
const cores = @import("cores.zig");

const tls = std.crypto.tls;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Hmac = std.crypto.auth.hmac.sha2.HmacSha256;
const X25519 = std.crypto.dh.X25519;
const P256 = std.crypto.ecc.P256;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const ChaCha = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
pub const Ecdsa = std.crypto.sign.ecdsa.EcdsaP256Sha256;

pub const Error = error{ Closed, Protocol, Unsupported, BadRecord, TimedOut, ConnectionFailed };

// With minimal integers: std's toDer keeps leading zero bytes (1 in 128
// signatures), which OpenSSL refuses.
pub fn signatureDer(sig: Ecdsa.Signature, buf: *[Ecdsa.Signature.der_encoded_length_max]u8) []const u8 {
    var n: usize = 2;
    for ([2]*const [32]u8{ &sig.r, &sig.s }) |v| {
        var i: usize = 0;
        while (i < 31 and v[i] == 0) i += 1;
        const pad = v[i] >= 0x80;
        buf[n] = 0x02;
        buf[n + 1] = @intCast(32 - i + @intFromBool(pad));
        n += 2;
        if (pad) {
            buf[n] = 0;
            n += 1;
        }
        @memcpy(buf[n..][0 .. 32 - i], v[i..]);
        n += 32 - i;
    }
    buf[0] = 0x30;
    buf[1] = @intCast(n - 2);
    return buf[0..n];
}

const max_plain = 1 << 14;
const max_record = max_plain + 256;
const tag_len = 16;
const offload_min = 4096; // writes this large are sealed on another core
const batch = 4; // records sealed per write

const Suite = enum { aes128, chacha };

const Keys = struct {
    key: [32]u8 = undefined, // AES-128 uses the first 16
    iv: [12]u8 = undefined,
    seq: u64 = 0,

    fn from(suite: Suite, secret: [32]u8) Keys {
        var k: Keys = .{};
        switch (suite) {
            .aes128 => k.key[0..16].* = tls.hkdfExpandLabel(Hkdf, secret, "key", "", 16),
            .chacha => k.key = tls.hkdfExpandLabel(Hkdf, secret, "key", "", 32),
        }
        k.iv = tls.hkdfExpandLabel(Hkdf, secret, "iv", "", 12);
        return k;
    }

    fn nonce(self: *const Keys) [12]u8 {
        var n = self.iv;
        var seq: [8]u8 = undefined;
        std.mem.writeInt(u64, &seq, self.seq, .big);
        for (0..8) |i| n[4 + i] ^= seq[i];
        return n;
    }
};

// Header, ciphertext, tag: plain then the inner content type.
fn seal(suite: Suite, k: *Keys, kind: u8, plain: []const u8, out: []u8) usize {
    const len = plain.len + 1 + tag_len;
    out[0] = 23;
    out[1] = 3;
    out[2] = 3;
    std.mem.writeInt(u16, out[3..5], @intCast(len), .big);
    const body = out[5..][0 .. plain.len + 1];
    @memcpy(body[0..plain.len], plain);
    body[plain.len] = kind;
    const tag = out[5 + plain.len + 1 ..][0..tag_len];
    const n = k.nonce();
    switch (suite) {
        .aes128 => Aes128Gcm.encrypt(body, tag, body, out[0..5], n, k.key[0..16].*),
        .chacha => ChaCha.encrypt(body, tag, body, out[0..5], n, k.key),
    }
    k.seq += 1;
    return 5 + len;
}

pub const Server = struct {
    io: zc.TlsIo,
    suite: Suite = .aes128,
    rk: Keys = .{}, // reading
    wk: Keys = .{}, // writing
    encrypted_in: bool = false,
    c_secret: [32]u8 = undefined, // the client's traffic secret (KeyUpdate)
    s_secret: [32]u8 = undefined,
    alpn_http11: bool = false,
    closed: bool = false,
    // A record as read, then decrypted in place:
    rec: [5 + max_record]u8 = undefined,
    // Decrypted application data not yet read:
    plain: []u8 = &.{},
    // Handshake messages that span records:
    hs: [max_plain * 2]u8 = undefined,
    hs_len: usize = 0,
    out: [batch * (5 + max_plain + 1 + tag_len)]u8 = undefined,

    // RECORDS

    fn readFull(self: *Server, buf: []u8) Error!void {
        var got: usize = 0;
        while (got < buf.len) {
            const n = self.io.recv(self.io.ctx, buf[got..].ptr, buf.len - got);
            if (n == -2) return error.TimedOut;
            if (n < 0) return error.ConnectionFailed;
            if (n == 0) return error.Closed;
            got += @intCast(n);
        }
    }

    fn sendAll(self: *Server, data: []const u8) Error!void {
        var done: usize = 0;
        while (done < data.len) {
            const n = self.io.send(self.io.ctx, data[done..].ptr, data.len - done);
            if (n <= 0) return error.ConnectionFailed;
            done += @intCast(n);
        }
    }

    // Decrypted once keys are set; change_cipher_spec records are skipped.
    fn readRecord(self: *Server) Error!struct { kind: u8, data: []u8 } {
        while (true) {
            try self.readFull(self.rec[0..5]);
            const len = std.mem.readInt(u16, self.rec[3..5], .big);
            if (len > max_record) return error.BadRecord;
            try self.readFull(self.rec[5..][0..len]);
            const kind = self.rec[0];
            const data = self.rec[5..][0..len];
            if (kind == 20) continue; // change_cipher_spec, for middleboxes
            if (!self.encrypted_in) return .{ .kind = kind, .data = data };
            if (kind != 23 or len < tag_len + 1) return error.BadRecord;
            const body = data[0 .. len - tag_len];
            const tag = data[len - tag_len ..][0..tag_len].*;
            const n = self.rk.nonce();
            switch (self.suite) {
                .aes128 => Aes128Gcm.decrypt(body, body, tag, self.rec[0..5], n, self.rk.key[0..16].*) catch return error.BadRecord,
                .chacha => ChaCha.decrypt(body, body, tag, self.rec[0..5], n, self.rk.key) catch return error.BadRecord,
            }
            self.rk.seq += 1;
            // The inner type: the last byte that isn't padding:
            var end = body.len;
            while (end > 0 and body[end - 1] == 0) end -= 1;
            if (end == 0) return error.BadRecord;
            return .{ .kind = body[end - 1], .data = body[0 .. end - 1] };
        }
    }

    fn sendPlainRecord(self: *Server, kind: u8, data: []const u8) Error!void {
        var head: [5]u8 = .{ kind, 3, 3, 0, 0 };
        std.mem.writeInt(u16, head[3..5], @intCast(data.len), .big);
        try self.sendAll(&head);
        try self.sendAll(data);
    }

    const SealJob = struct {
        s: *Server,
        kind: u8,
        data: []const u8,
        out_len: usize = 0,

        fn work(j: *SealJob) void {
            var at: usize = 0;
            var i: usize = 0;
            while (i < j.data.len) {
                const n = @min(max_plain, j.data.len - i);
                at += seal(j.s.suite, &j.s.wk, j.kind, j.data[i .. i + n], j.s.out[at..]);
                i += n;
            }
            j.out_len = at;
        }
    };

    // Batches records per send.
    fn sendEncrypted(self: *Server, kind: u8, data: []const u8) Error!void {
        var i: usize = 0;
        while (i < data.len) {
            const n = @min(batch * max_plain, data.len - i);
            var job: SealJob = .{ .s = self, .kind = kind, .data = data[i .. i + n] };
            if (n >= offload_min) cores.run(SealJob, &job, SealJob.work) else job.work();
            try self.sendAll(self.out[0..job.out_len]);
            i += n;
        }
    }

    fn alert(self: *Server, description: u8) void {
        const a = [2]u8{ 2, description };
        if (self.encrypted_in) {
            self.sendEncrypted(21, &a) catch {};
        } else {
            self.sendPlainRecord(21, &a) catch {};
        }
    }

    // HANDSHAKE

    // Type, then its body, whole.
    fn handshakeMessage(self: *Server) Error!struct { kind: u8, msg: []const u8 } {
        while (true) {
            if (self.hs_len >= 4) {
                const len = std.mem.readInt(u24, self.hs[1..4], .big);
                if (len + 4 > self.hs.len) return error.Protocol;
                if (self.hs_len >= len + 4) return .{ .kind = self.hs[0], .msg = self.hs[0 .. len + 4] };
            }
            const r = try self.readRecord();
            if (r.kind == 21) return error.Closed;
            if (r.kind != 22) return error.Protocol;
            if (self.hs_len + r.data.len > self.hs.len) return error.Protocol;
            @memcpy(self.hs[self.hs_len..][0..r.data.len], r.data);
            self.hs_len += r.data.len;
        }
    }

    fn consumeMessage(self: *Server, len: usize) void {
        std.mem.copyForwards(u8, self.hs[0 .. self.hs_len - len], self.hs[len..self.hs_len]);
        self.hs_len -= len;
    }

    const Hello = struct {
        session_id: [32]u8 = undefined,
        session_id_len: usize = 0,
        suite: ?Suite = null,
        tls13: bool = false,
        ecdsa: bool = false,
        x25519: ?[32]u8 = null,
        p256: ?[65]u8 = null,
        alpn_http11: bool = false,
    };

    fn parseHello(msg: []const u8) Error!Hello {
        var h: Hello = .{};
        var r = Reader{ .data = msg[4..] };
        _ = try r.int(u16); // legacy_version
        _ = try r.bytes(32); // random
        const sid = try r.vec(u8);
        if (sid.len > 32) return error.Protocol;
        @memcpy(h.session_id[0..sid.len], sid);
        h.session_id_len = sid.len;
        var suites = Reader{ .data = try r.vec(u16) };
        var have_aes = false;
        var have_chacha = false;
        while (suites.left() >= 2) switch (try suites.int(u16)) {
            0x1301 => have_aes = true,
            0x1303 => have_chacha = true,
            else => {},
        };
        h.suite = if (have_aes) .aes128 else if (have_chacha) .chacha else null;
        _ = try r.vec(u8); // compression
        if (r.left() == 0) return h;
        var exts = Reader{ .data = try r.vec(u16) };
        while (exts.left() >= 4) {
            const kind = try exts.int(u16);
            var e = Reader{ .data = try exts.vec(u16) };
            switch (kind) {
                43 => { // supported_versions
                    var v = Reader{ .data = try e.vec(u8) };
                    while (v.left() >= 2) if (try v.int(u16) == 0x0304) {
                        h.tls13 = true;
                    };
                },
                13 => { // signature_algorithms
                    var v = Reader{ .data = try e.vec(u16) };
                    while (v.left() >= 2) if (try v.int(u16) == 0x0403) {
                        h.ecdsa = true;
                    };
                },
                51 => { // key_share
                    var v = Reader{ .data = try e.vec(u16) };
                    while (v.left() >= 4) {
                        const group = try v.int(u16);
                        const key = try v.vec(u16);
                        if (group == 0x001D and key.len == 32) h.x25519 = key[0..32].*;
                        if (group == 0x0017 and key.len == 65 and key[0] == 4) h.p256 = key[0..65].*;
                    }
                },
                16 => { // ALPN
                    var v = Reader{ .data = try e.vec(u16) };
                    while (v.left() >= 1) if (std.mem.eql(u8, try v.vec(u8), "http/1.1")) {
                        h.alpn_http11 = true;
                    };
                },
                else => {},
            }
        }
        return h;
    }

    // Our key share and the shared secret, on another core.
    const KexJob = struct {
        hello: *const Hello,
        secret: [32]u8,
        public: [65]u8 = undefined,
        public_len: usize = 0,
        shared: [32]u8 = undefined,
        ok: bool = false,

        fn work(j: *KexJob) void {
            if (j.hello.x25519) |peer| {
                j.public[0..32].* = X25519.recoverPublicKey(j.secret) catch return;
                j.public_len = 32;
                j.shared = X25519.scalarmult(j.secret, peer) catch return;
            } else if (j.hello.p256) |peer| {
                const ours = P256.basePoint.mul(j.secret, .big) catch return;
                j.public = ours.toUncompressedSec1();
                j.public_len = 65;
                const point = P256.fromSec1(&peer) catch return;
                const s = point.mulPublic(j.secret, .big) catch return;
                j.shared = s.affineCoordinates().x.toBytes(.big);
            } else return;
            j.ok = true;
        }
    };

    const SignJob = struct {
        key: *const Ecdsa.KeyPair,
        content: []const u8,
        sig: [Ecdsa.Signature.der_encoded_length_max]u8 = undefined,
        sig_len: usize = 0,

        fn work(j: *SignJob) void {
            const s = j.key.sign(j.content, null) catch return;
            j.sig_len = signatureDer(s, &j.sig).len;
        }
    };

    // certs: DER, the server's first
    pub fn handshake(self: *Server, certs: []const zc.TlsCert, key: *const Ecdsa.KeyPair) Error!void {
        errdefer self.alert(40); // handshake_failure
        var transcript = Sha256.init(.{});

        const ch = try self.handshakeMessage();
        if (ch.kind != 1) return error.Protocol;
        const hello = try parseHello(ch.msg);
        transcript.update(ch.msg);
        self.consumeMessage(ch.msg.len);
        if (!hello.tls13 or !hello.ecdsa or hello.suite == null) return error.Unsupported;
        if (hello.x25519 == null and hello.p256 == null) return error.Unsupported;
        self.suite = hello.suite.?;
        self.alpn_http11 = hello.alpn_http11;

        var kex: KexJob = .{ .hello = &hello, .secret = undefined };
        zdos.randomBytes(&kex.secret);
        defer std.crypto.secureZero(u8, &kex.secret);
        cores.run(KexJob, &kex, KexJob.work);
        if (!kex.ok) return error.Protocol;

        // ServerHello:
        var sh_buf: [256]u8 = undefined;
        var w = Writer{ .buf = &sh_buf };
        try w.add(&.{ 2, 0, 0, 0, 3, 3 });
        var random: [32]u8 = undefined;
        zdos.randomBytes(&random);
        try w.add(&random);
        try w.add(&.{@intCast(hello.session_id_len)});
        try w.add(hello.session_id[0..hello.session_id_len]);
        try w.int(u16, if (self.suite == .aes128) 0x1301 else 0x1303);
        try w.add(&.{0});
        const ext_at = w.len;
        try w.int(u16, 0);
        try w.add(&.{ 0x00, 0x2B, 0x00, 0x02, 0x03, 0x04 }); // supported_versions: TLS 1.3
        try w.int(u16, 51); // key_share
        try w.int(u16, @intCast(4 + kex.public_len));
        try w.int(u16, if (kex.public_len == 32) 0x001D else 0x0017);
        try w.int(u16, @intCast(kex.public_len));
        try w.add(kex.public[0..kex.public_len]);
        std.mem.writeInt(u16, sh_buf[ext_at..][0..2], @intCast(w.len - ext_at - 2), .big);
        std.mem.writeInt(u24, sh_buf[1..4], @intCast(w.len - 4), .big);
        transcript.update(w.slice());
        try self.sendPlainRecord(22, w.slice());
        try self.sendPlainRecord(20, &.{1}); // change_cipher_spec, for middleboxes

        // The handshake keys:
        const zeros = [_]u8{0} ** 32;
        const early = Hkdf.extract(&zeros, &zeros);
        const empty = tls.emptyHash(Sha256);
        const derived = tls.hkdfExpandLabel(Hkdf, early, "derived", &empty, 32);
        const hs_secret = Hkdf.extract(&derived, &kex.shared);
        const h1 = transcript.peek();
        const c_hs = tls.hkdfExpandLabel(Hkdf, hs_secret, "c hs traffic", &h1, 32);
        const s_hs = tls.hkdfExpandLabel(Hkdf, hs_secret, "s hs traffic", &h1, 32);
        self.wk = Keys.from(self.suite, s_hs);
        self.rk = Keys.from(self.suite, c_hs);

        // EncryptedExtensions, Certificate, CertificateVerify, Finished:
        var flight: [4 * 4 + 16 * 1024 + 512]u8 = undefined;
        var f = Writer{ .buf = &flight };
        const ee_at = f.len;
        try f.add(&.{ 8, 0, 0, 0 });
        if (self.alpn_http11) {
            // extensions 15 bytes:
            // ALPN (16), 11 bytes, a list of 9: "http/1.1":
            try f.add(&.{ 0x00, 0x0F, 0x00, 0x10, 0x00, 0x0B, 0x00, 0x09, 0x08 });
            try f.add("http/1.1");
        } else try f.add(&.{ 0, 0 });
        std.mem.writeInt(u24, flight[ee_at + 1 ..][0..3], @intCast(f.len - ee_at - 4), .big);
        transcript.update(flight[ee_at..f.len]);

        const cert_at = f.len;
        try f.add(&.{ 11, 0, 0, 0, 0 }); // and an empty request context
        const list_at = f.len;
        try f.add(&.{ 0, 0, 0 });
        for (certs) |c| {
            try f.int(u24, @intCast(c.len));
            try f.add(c.der[0..c.len]);
            try f.int(u16, 0);
        }
        std.mem.writeInt(u24, flight[list_at..][0..3], @intCast(f.len - list_at - 3), .big);
        std.mem.writeInt(u24, flight[cert_at + 1 ..][0..3], @intCast(f.len - cert_at - 4), .big);
        transcript.update(flight[cert_at..f.len]);

        var content: [64 + 34 + 32]u8 = undefined;
        @memset(content[0..64], 0x20);
        @memcpy(content[64..][0..33], "TLS 1.3, server CertificateVerify");
        content[97] = 0;
        content[98..130].* = transcript.peek();
        var sign: SignJob = .{ .key = key, .content = &content };
        cores.run(SignJob, &sign, SignJob.work);
        if (sign.sig_len == 0) return error.Protocol;
        const cv_at = f.len;
        try f.add(&.{ 15, 0, 0, 0, 0x04, 0x03 });
        try f.int(u16, @intCast(sign.sig_len));
        try f.add(sign.sig[0..sign.sig_len]);
        std.mem.writeInt(u24, flight[cv_at + 1 ..][0..3], @intCast(f.len - cv_at - 4), .big);
        transcript.update(flight[cv_at..f.len]);

        const h2 = transcript.peek();
        const s_finished_key = tls.hkdfExpandLabel(Hkdf, s_hs, "finished", "", 32);
        const s_verify = tls.hmac(Hmac, &h2, s_finished_key);
        const fin_at = f.len;
        try f.add(&.{ 20, 0, 0, 32 });
        try f.add(&s_verify);
        transcript.update(flight[fin_at..f.len]);
        try self.sendEncrypted(22, f.slice());

        // The application keys, from the transcript up to our Finished:
        const h3 = transcript.peek();
        const derived2 = tls.hkdfExpandLabel(Hkdf, hs_secret, "derived", &empty, 32);
        const master = Hkdf.extract(&derived2, &zeros);
        self.c_secret = tls.hkdfExpandLabel(Hkdf, master, "c ap traffic", &h3, 32);
        self.s_secret = tls.hkdfExpandLabel(Hkdf, master, "s ap traffic", &h3, 32);

        // The client's Finished:
        self.encrypted_in = true;
        const fin = try self.handshakeMessage();
        if (fin.kind != 20 or fin.msg.len != 4 + 32) return error.Protocol;
        const c_finished_key = tls.hkdfExpandLabel(Hkdf, c_hs, "finished", "", 32);
        const c_verify = tls.hmac(Hmac, &h3, c_finished_key);
        if (!std.crypto.timing_safe.eql([32]u8, c_verify, fin.msg[4..36].*)) return error.Protocol;
        self.consumeMessage(fin.msg.len);

        self.wk = Keys.from(self.suite, self.s_secret);
        self.rk = Keys.from(self.suite, self.c_secret);
    }

    // APPLICATION DATA

    // 0 when the client has closed.
    pub fn read(self: *Server, buf: []u8) Error!usize {
        while (self.plain.len == 0) {
            if (self.closed) return 0;
            const r = try self.readRecord();
            switch (r.kind) {
                23 => self.plain = r.data,
                21 => { // an alert: close_notify, or an error
                    self.closed = true;
                    return 0;
                },
                22 => try self.postHandshake(r.data),
                else => return error.Protocol,
            }
        }
        const n = @min(buf.len, self.plain.len);
        @memcpy(buf[0..n], self.plain[0..n]);
        self.plain = self.plain[n..];
        return n;
    }

    // KeyUpdate (answered if the client asks), the rest ignored.
    fn postHandshake(self: *Server, data: []const u8) Error!void {
        if (data.len == 5 and data[0] == 24) {
            self.c_secret = tls.hkdfExpandLabel(Hkdf, self.c_secret, "traffic upd", "", 32);
            self.rk = Keys.from(self.suite, self.c_secret);
            if (data[4] == 1) {
                try self.sendEncrypted(22, &.{ 24, 0, 0, 1, 0 });
                self.s_secret = tls.hkdfExpandLabel(Hkdf, self.s_secret, "traffic upd", "", 32);
                self.wk = Keys.from(self.suite, self.s_secret);
            }
        }
    }

    pub fn writeAll(self: *Server, data: []const u8) Error!void {
        if (data.len > 0) try self.sendEncrypted(23, data);
    }

    pub fn close(self: *Server) void {
        self.alert(0); // close_notify (a warning)
    }
};

// HANDSHAKE MESSAGE I/O

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn left(self: *const Reader) usize {
        return self.data.len - self.pos;
    }

    fn bytes(self: *Reader, n: usize) Error![]const u8 {
        if (self.left() < n) return error.Protocol;
        defer self.pos += n;
        return self.data[self.pos..][0..n];
    }

    fn int(self: *Reader, comptime T: type) Error!T {
        const n = @divExact(@bitSizeOf(T), 8);
        return std.mem.readInt(T, (try self.bytes(n))[0..n], .big);
    }

    // With a length of type T in front.
    fn vec(self: *Reader, comptime T: type) Error![]const u8 {
        return self.bytes(try self.int(T));
    }
};

const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn add(self: *Writer, data: []const u8) Error!void {
        if (self.len + data.len > self.buf.len) return error.Protocol;
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn int(self: *Writer, comptime T: type, v: T) Error!void {
        var b: [@divExact(@bitSizeOf(T), 8)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .big);
        try self.add(&b);
    }

    fn slice(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }
};
