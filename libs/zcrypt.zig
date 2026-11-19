// ZCRYPT.ZDL: Zig's cryptography as a shared library. No state here:
// callers pass their own memory, so one copy serves every program.
const std = @import("std");
const zdos = @import("zdos");
const abi = @import("abi");
const TlsClient = @import("vendor/zig-tls/Client.zig");
const tls_server = @import("zcrypt/server.zig");
const zc = zdos.zcrypt;

// zdos.zig's start-up (zdos_library_init: the library's groups):
comptime {
    _ = zdos;
}

pub const zdos_file_version = [4]u8{ 0, 8, 1, 0 };

pub const std_options: std.Options = .{
    .cryptoRandomSeed = zdos.randomBytes,
    .crypto_always_getrandom = true,
};

const cc = abi.cc;
const Sha256 = std.crypto.hash.sha2.Sha256;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const X25519 = std.crypto.dh.X25519;
const Ed25519 = std.crypto.sign.Ed25519;
const P256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const ChaCha = std.crypto.stream.chacha.ChaCha20With64BitNonce;
const Poly1305 = std.crypto.onetimeauth.Poly1305;
const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const argon2 = std.crypto.pwhash.argon2;

comptime {
    if (@sizeOf(Sha256) > @sizeOf(zc.Sha256State)) @compileError("Sha256State is too small");
}

export const zdos_library_shared: u8 = 1;

export const zdos_library: zc.Api = .{
    .slots = abi.slotsOf(zc.Api),
    .sha256 = sha256,
    .sha256_init = sha256Init,
    .sha256_update = sha256Update,
    .sha256_final = sha256Final,
    .hmac_sha256 = hmacSha256,
    .x25519_public = x25519Public,
    .x25519_shared = x25519Shared,
    .ed25519_from_seed = ed25519FromSeed,
    .ed25519_sign = ed25519Sign,
    .ed25519_verify = ed25519Verify,
    .p256_verify = p256Verify,
    .chacha20_xor = chacha20Xor,
    .poly1305 = poly1305,
    .aes_gcm_seal = aesGcmSeal,
    .aes_gcm_open = aesGcmOpen,
    .argon2id_verify = argon2idVerify,
    .argon2id_hash = argon2idHash,
    .bcrypt_pbkdf = bcryptPbkdf,
    .aes256_ctr = aes256Ctr,
    .tls_size = tlsSize,
    .tls_connect = tlsConnect,
    .tls_read = tlsRead,
    .tls_read_some = tlsReadSome,
    .tls_write = tlsWrite,
    .tls_pending = tlsPending,
    .tls_server_size = serverSize,
    .tls_accept = tlsAccept,
    .tls_server_read = serverRead,
    .tls_server_write = serverWrite,
    .tls_server_pending = serverPending,
    .tls_server_close = serverClose,
    .p256_public = p256Public,
    .p256_sign_der = p256SignDer,
};

// HASHES

fn sha256(data: [*]const u8, len: usize, out: *[32]u8) callconv(cc) void {
    Sha256.hash(data[0..len], out, .{});
}

fn state(s: *zc.Sha256State) *Sha256 {
    return @ptrCast(@alignCast(&s.bytes));
}

fn sha256Init(s: *zc.Sha256State) callconv(cc) void {
    state(s).* = Sha256.init(.{});
}

fn sha256Update(s: *zc.Sha256State, data: [*]const u8, len: usize) callconv(cc) void {
    state(s).update(data[0..len]);
}

fn sha256Final(s: *zc.Sha256State, out: *[32]u8) callconv(cc) void {
    state(s).final(out);
}

fn hmacSha256(key: [*]const u8, key_len: usize, data: [*]const u8, len: usize, out: *[32]u8) callconv(cc) void {
    HmacSha256.create(out, data[0..len], key[0..key_len]);
}

// KEY EXCHANGE AND SIGNATURES

fn x25519Public(secret: *const [32]u8, out: *[32]u8) callconv(cc) bool {
    out.* = X25519.recoverPublicKey(secret.*) catch return false;
    return true;
}

fn x25519Shared(secret: *const [32]u8, public: *const [32]u8, out: *[32]u8) callconv(cc) bool {
    out.* = X25519.scalarmult(secret.*, public.*) catch return false;
    return true;
}

fn ed25519FromSeed(seed: *const [32]u8, public: *[32]u8, secret: *[64]u8) callconv(cc) bool {
    const kp = Ed25519.KeyPair.generateDeterministic(seed.*) catch return false;
    public.* = kp.public_key.toBytes();
    secret.* = kp.secret_key.toBytes();
    return true;
}

fn ed25519Sign(secret: *const [64]u8, msg: [*]const u8, len: usize, sig: *[64]u8) callconv(cc) bool {
    const sk = Ed25519.SecretKey.fromBytes(secret.*) catch return false;
    const kp = Ed25519.KeyPair.fromSecretKey(sk) catch return false;
    const s = kp.sign(msg[0..len], null) catch return false;
    sig.* = s.toBytes();
    return true;
}

fn ed25519Verify(public: *const [32]u8, msg: [*]const u8, len: usize, sig: *const [64]u8) callconv(cc) bool {
    const pk = Ed25519.PublicKey.fromBytes(public.*) catch return false;
    Ed25519.Signature.fromBytes(sig.*).verify(msg[0..len], pk) catch return false;
    return true;
}

fn p256Verify(sec1: [*]const u8, sec1_len: usize, msg: [*]const u8, len: usize, sig: *const [64]u8) callconv(cc) bool {
    const pk = P256.PublicKey.fromSec1(sec1[0..sec1_len]) catch return false;
    P256.Signature.fromBytes(sig.*).verify(msg[0..len], pk) catch return false;
    return true;
}

// CIPHERS

fn chacha20Xor(key: *const [32]u8, nonce: *const [8]u8, counter: u64, in: [*]const u8, out: [*]u8, len: usize) callconv(cc) void {
    ChaCha.xor(out[0..len], in[0..len], counter, key.*, nonce.*);
}

fn poly1305(key: *const [32]u8, msg: [*]const u8, len: usize, tag: *[16]u8) callconv(cc) void {
    Poly1305.create(tag, msg[0..len], key);
}

fn aesGcmSeal(key: [*]const u8, key_len: usize, iv: *const [12]u8, ad: [*]const u8, ad_len: usize, plain: [*]const u8, len: usize, out: [*]u8, tag: *[16]u8) callconv(cc) bool {
    switch (key_len) {
        16 => Aes128Gcm.encrypt(out[0..len], tag, plain[0..len], ad[0..ad_len], iv.*, key[0..16].*),
        32 => Aes256Gcm.encrypt(out[0..len], tag, plain[0..len], ad[0..ad_len], iv.*, key[0..32].*),
        else => return false,
    }
    return true;
}

fn aesGcmOpen(key: [*]const u8, key_len: usize, iv: *const [12]u8, ad: [*]const u8, ad_len: usize, cipher: [*]const u8, len: usize, out: [*]u8, tag: *const [16]u8) callconv(cc) bool {
    switch (key_len) {
        16 => Aes128Gcm.decrypt(out[0..len], cipher[0..len], tag.*, ad[0..ad_len], iv.*, key[0..16].*) catch return false,
        32 => Aes256Gcm.decrypt(out[0..len], cipher[0..len], tag.*, ad[0..ad_len], iv.*, key[0..32].*) catch return false,
        else => return false,
    }
    return true;
}

fn aes256Ctr(key: *const [32]u8, iv: *const [16]u8, in: [*]const u8, out: [*]u8, len: usize) callconv(cc) bool {
    const aes = std.crypto.core.aes.Aes256.initEnc(key.*);
    std.crypto.core.modes.ctr(@TypeOf(aes), aes, out[0..len], in[0..len], iv.*, .big);
    return true;
}

// PASSWORDS

const params: argon2.Params = .{ .t = 2, .m = 19 * 1024, .p = 1 };

fn argon2idVerify(phc: [*]const u8, phc_len: usize, password: [*]const u8, password_len: usize, work: [*]u8, work_len: usize) callconv(cc) bool {
    var fba: std.heap.FixedBufferAllocator = .init(work[0..work_len]);
    argon2.strVerify(phc[0..phc_len], password[0..password_len], .{ .allocator = fba.allocator() }) catch return false;
    return true;
}

fn argon2idHash(password: [*]const u8, password_len: usize, salt: *const [16]u8, work: [*]u8, work_len: usize, out: [*]u8, out_len: usize) callconv(cc) usize {
    var fba: std.heap.FixedBufferAllocator = .init(work[0..work_len]);
    var key: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &key);
    argon2.kdf(fba.allocator(), &key, password[0..password_len], salt, params, .argon2id) catch return 0;
    const b64 = std.base64.standard_no_pad;
    var salt_text: [b64.Encoder.calcSize(16)]u8 = undefined;
    var key_text: [b64.Encoder.calcSize(32)]u8 = undefined;
    const text = std.fmt.bufPrint(out[0..out_len], "$argon2id$v=19$m={d},t={d},p={d}${s}${s}", .{
        params.m, params.t, params.p, b64.Encoder.encode(&salt_text, salt), b64.Encoder.encode(&key_text, &key),
    }) catch return 0;
    return text.len;
}

fn bcryptPbkdf(pass: [*]const u8, pass_len: usize, salt: [*]const u8, salt_len: usize, rounds: u32, out: [*]u8, out_len: usize) callconv(cc) bool {
    std.crypto.pwhash.bcrypt.opensshKdf(pass[0..pass_len], salt[0..salt_len], out[0..out_len], rounds) catch return false;
    return true;
}

// TLS CLIENT

const TlsState = struct {
    io: zc.TlsIo,
    client: TlsClient,
};

// The client's stream: the caller's io
const Stream = struct {
    io: *const zc.TlsIo,

    pub const ReadError = error{ConnectionFailed};
    pub const WriteError = error{ConnectionFailed};

    fn recv(self: Stream, buf: []u8) ReadError!usize {
        const n = self.io.recv(self.io.ctx, buf.ptr, buf.len);
        if (n < 0) return error.ConnectionFailed;
        return @intCast(n);
    }

    fn sendAll(self: Stream, data: []const u8) WriteError!void {
        var done: usize = 0;
        while (done < data.len) {
            const n = self.io.send(self.io.ctx, data[done..].ptr, data.len - done);
            if (n <= 0) return error.ConnectionFailed;
            done += @intCast(n);
        }
    }

    pub fn readv(self: Stream, iovecs: []std.posix.iovec) ReadError!usize {
        for (iovecs) |v| {
            if (v.len > 0) return self.recv(v.base[0..v.len]);
        }
        return 0;
    }

    pub fn readAtLeast(self: Stream, out: []u8, len: usize) ReadError!usize {
        var got: usize = 0;
        while (got < len) {
            const n = try self.recv(out[got..]);
            if (n == 0) break;
            got += n;
        }
        return got;
    }

    pub fn writev(self: Stream, iovecs: []const std.posix.iovec_const) WriteError!usize {
        for (iovecs) |v| {
            if (v.len > 0) {
                try self.sendAll(v.base[0..v.len]);
                return v.len;
            }
        }
        return 0;
    }

    pub fn writevAll(self: Stream, iovecs: []std.posix.iovec_const) WriteError!void {
        for (iovecs) |v| try self.sendAll(v.base[0..v.len]);
    }
};

fn tlsState(conn: [*]u8) *TlsState {
    return @ptrCast(@alignCast(conn));
}

fn tlsSize() callconv(cc) usize {
    return @sizeOf(TlsState);
}

fn tlsConnect(conn: [*]u8, io: *const zc.TlsIo, host: [*]const u8, host_len: usize, verify: bool, now: i64) callconv(cc) u32 {
    const st = tlsState(conn);
    st.io = io.*;
    var bundle: std.crypto.Certificate.Bundle = .{};
    defer bundle.deinit(zdos.allocator);
    if (verify) bundle = certificates(now) catch |err| return @intFromEnum(tlsResult(err));
    st.client = TlsClient.init(Stream{ .io = &st.io }, .{
        .host = if (verify) .{ .explicit = host[0..host_len] } else .no_verification,
        .ca = if (verify) .{ .bundle = bundle } else .no_verification,
        .now_sec = now,
    }) catch |err| return @intFromEnum(tlsResult(err));
    // Servers often close without close_notify:
    st.client.allow_truncation_attacks = true;
    return @intFromEnum(zc.TlsResult.ok);
}

fn tlsResult(err: anyerror) zc.TlsResult {
    return switch (err) {
        error.TlsCertificateNotVerified => .not_verified,
        error.CertificateHostMismatch => .host_mismatch,
        error.CertificateExpired => .expired,
        error.CertificateNotYetValid => .not_yet_valid,
        error.NoCertificates => .no_certificates,
        error.ConnectionFailed => .io,
        error.OutOfMemory => .out_of_memory,
        else => .failed,
    };
}

fn tlsRead(conn: [*]u8, out: [*]u8, len: usize) callconv(cc) isize {
    const st = tlsState(conn);
    const n = st.client.read(Stream{ .io = &st.io }, out[0..len]) catch return -1;
    return @intCast(n);
}

fn tlsReadSome(conn: [*]u8, out: [*]u8, len: usize) callconv(cc) isize {
    const st = tlsState(conn);
    var iov = [1]std.posix.iovec{.{ .base = out, .len = len }};
    const n = st.client.readvAdvanced(Stream{ .io = &st.io }, &iov) catch return -1;
    if (n == 0 and st.client.received_close_notify) return -2;
    return @intCast(n);
}

fn tlsWrite(conn: [*]u8, data: [*]const u8, len: usize) callconv(cc) bool {
    const st = tlsState(conn);
    st.client.writeAll(Stream{ .io = &st.io }, data[0..len]) catch return false;
    return true;
}

fn tlsPending(conn: [*]u8) callconv(cc) bool {
    const c = &tlsState(conn).client;
    return c.partial_cleartext_idx < c.partial_ciphertext_idx;
}

// CACERT.PEM of the boot drive (COMSPEC's), in the caller's memory
fn certificates(now: i64) !std.crypto.Certificate.Bundle {
    var vb: [260]u8 = undefined;
    const drive = if (zdos.getVar("COMSPEC", &vb)) |c| (if (c.len > 1 and c[1] == ':') c[0] else 'C') else 'C';
    var path = "C:\\CONF\\CACERT.PEM".*;
    path[0] = drive;
    const f = zdos.open(&path, .read) catch return error.NoCertificates;
    defer f.close();
    const gpa = zdos.allocator;
    const size: usize = @intCast(try f.size());
    const pem = try gpa.alloc(u8, size);
    defer gpa.free(pem);
    var got: usize = 0;
    while (got < size) {
        const n = try f.read(pem[got..]);
        if (n == 0) break;
        got += n;
    }
    var bundle: std.crypto.Certificate.Bundle = .{};
    errdefer bundle.deinit(gpa);
    try bundle.bytes.ensureTotalCapacity(gpa, got / 4 * 3);
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";
    var at: usize = 0;
    var decoded: [8192]u8 = undefined;
    while (std.mem.indexOfPos(u8, pem[0..got], at, begin)) |b| {
        const start = b + begin.len;
        const e = std.mem.indexOfPos(u8, pem[0..got], start, end) orelse break;
        at = e + end.len;
        // Base64 with line breaks: the breaks go first:
        var clean: [12 * 1024]u8 = undefined;
        var n: usize = 0;
        for (pem[start..e]) |ch| {
            if (ch == '\r' or ch == '\n' or ch == ' ' or ch == '\t') continue;
            if (n == clean.len) break;
            clean[n] = ch;
            n += 1;
        }
        const len = std.base64.standard.Decoder.calcSizeForSlice(clean[0..n]) catch continue;
        if (len > decoded.len) continue;
        std.base64.standard.Decoder.decode(decoded[0..len], clean[0..n]) catch continue;
        const decoded_start: u32 = @intCast(bundle.bytes.items.len);
        try bundle.bytes.appendSlice(gpa, decoded[0..len]);
        bundle.parseCert(gpa, decoded_start, now) catch {
            bundle.bytes.items.len = decoded_start; // one it can't use: left out
        };
    }
    if (bundle.map.count() == 0) return error.NoCertificates;
    return bundle;
}

// TLS SERVER (zcrypt/server.zig)

const Ecdsa = tls_server.Ecdsa;

fn server(conn: [*]u8) *tls_server.Server {
    return @ptrCast(@alignCast(conn));
}

fn serverSize() callconv(cc) usize {
    return @sizeOf(tls_server.Server);
}

fn tlsAccept(conn: [*]u8, io: *const zc.TlsIo, certs: [*]const zc.TlsCert, count: usize, secret: *const [32]u8, public: *const [65]u8) callconv(cc) u32 {
    if (count == 0 or count > 4) return @intFromEnum(zc.TlsResult.failed);
    const key: Ecdsa.KeyPair = .{
        .public_key = Ecdsa.PublicKey.fromSec1(public) catch return @intFromEnum(zc.TlsResult.failed),
        .secret_key = Ecdsa.SecretKey.fromBytes(secret.*) catch return @intFromEnum(zc.TlsResult.failed),
    };
    // Field by field, as a whole default would be kept as a template:
    const s = server(conn);
    s.io = io.*;
    s.suite = .aes128;
    s.rk = .{};
    s.wk = .{};
    s.encrypted_in = false;
    s.alpn_http11 = false;
    s.closed = false;
    s.plain = &.{};
    s.hs_len = 0;
    s.handshake(certs[0..count], &key) catch |err| return @intFromEnum(@as(zc.TlsResult, switch (err) {
        error.Closed => .closed,
        error.TimedOut => .timed_out,
        error.Unsupported => .unsupported,
        error.ConnectionFailed => .io,
        else => .failed,
    }));
    return @intFromEnum(zc.TlsResult.ok);
}

fn serverRead(conn: [*]u8, out: [*]u8, len: usize) callconv(cc) isize {
    const n = server(conn).read(out[0..len]) catch |err| return if (err == error.TimedOut) -2 else -1;
    return @intCast(n);
}

fn serverWrite(conn: [*]u8, data: [*]const u8, len: usize) callconv(cc) bool {
    server(conn).writeAll(data[0..len]) catch return false;
    return true;
}

fn serverPending(conn: [*]u8) callconv(cc) bool {
    return server(conn).plain.len > 0;
}

fn serverClose(conn: [*]u8) callconv(cc) void {
    server(conn).close();
}

fn p256Public(secret: *const [32]u8, out: *[65]u8) callconv(cc) bool {
    const sk = Ecdsa.SecretKey.fromBytes(secret.*) catch return false;
    const kp = Ecdsa.KeyPair.fromSecretKey(sk) catch return false;
    out.* = kp.public_key.toUncompressedSec1();
    return true;
}

fn p256SignDer(secret: *const [32]u8, msg: [*]const u8, len: usize, out: *[72]u8) callconv(cc) usize {
    const sk = Ecdsa.SecretKey.fromBytes(secret.*) catch return 0;
    const kp = Ecdsa.KeyPair.fromSecretKey(sk) catch return 0;
    const sig = kp.sign(msg[0..len], null) catch return 0;
    return tls_server.signatureDer(sig, out).len;
}
