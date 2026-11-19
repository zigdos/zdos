// ZCRYPT.ZDL's export table, and get(). State lives in the caller's memory, so
// one copy serves every program. Slots only get added at the end.
const std = @import("std");
const abi = @import("abi");
const zdos = @import("zdos.zig");
const net = @import("net.zig");

const cc = abi.cc;

pub const Sha256State = extern struct {
    bytes: [128]u8 align(8),
};

pub const Api = extern struct {
    slots: usize,

    // Hashes:
    sha256: *const fn (data: [*]const u8, len: usize, out: *[32]u8) callconv(cc) void,
    sha256_init: *const fn (state: *Sha256State) callconv(cc) void,
    sha256_update: *const fn (state: *Sha256State, data: [*]const u8, len: usize) callconv(cc) void,
    sha256_final: *const fn (state: *Sha256State, out: *[32]u8) callconv(cc) void,
    hmac_sha256: *const fn (key: [*]const u8, key_len: usize, data: [*]const u8, len: usize, out: *[32]u8) callconv(cc) void,

    // Key exchange and signatures:
    x25519_public: *const fn (secret: *const [32]u8, out: *[32]u8) callconv(cc) bool,
    x25519_shared: *const fn (secret: *const [32]u8, public: *const [32]u8, out: *[32]u8) callconv(cc) bool,
    // From a 32-byte seed; secret is seed and public key.
    ed25519_from_seed: *const fn (seed: *const [32]u8, public: *[32]u8, secret: *[64]u8) callconv(cc) bool,
    ed25519_sign: *const fn (secret: *const [64]u8, msg: [*]const u8, len: usize, sig: *[64]u8) callconv(cc) bool,
    ed25519_verify: *const fn (public: *const [32]u8, msg: [*]const u8, len: usize, sig: *const [64]u8) callconv(cc) bool,
    // P-256 with SHA-256: the public key as SEC1, the signature r || s:
    p256_verify: *const fn (sec1: [*]const u8, sec1_len: usize, msg: [*]const u8, len: usize, sig: *const [64]u8) callconv(cc) bool,

    // Ciphers. ChaCha20 with a 64-bit nonce and counter (OpenSSH's):
    chacha20_xor: *const fn (key: *const [32]u8, nonce: *const [8]u8, counter: u64, in: [*]const u8, out: [*]u8, len: usize) callconv(cc) void,
    poly1305: *const fn (key: *const [32]u8, msg: [*]const u8, len: usize, tag: *[16]u8) callconv(cc) void,
    // AES-GCM, key 16 or 32 bytes; open is false if the tag is wrong:
    aes_gcm_seal: *const fn (key: [*]const u8, key_len: usize, iv: *const [12]u8, ad: [*]const u8, ad_len: usize, plain: [*]const u8, len: usize, out: [*]u8, tag: *[16]u8) callconv(cc) bool,
    aes_gcm_open: *const fn (key: [*]const u8, key_len: usize, iv: *const [12]u8, ad: [*]const u8, ad_len: usize, cipher: [*]const u8, len: usize, out: [*]u8, tag: *const [16]u8) callconv(cc) bool,

    // Passwords. Argon2id as users.zig; work: at least argon2_work bytes:
    argon2id_verify: *const fn (phc: [*]const u8, phc_len: usize, password: [*]const u8, password_len: usize, work: [*]u8, work_len: usize) callconv(cc) bool,
    // "$argon2id$..." into out; its length, 0 if it failed:
    argon2id_hash: *const fn (password: [*]const u8, password_len: usize, salt: *const [16]u8, work: [*]u8, work_len: usize, out: [*]u8, out_len: usize) callconv(cc) usize,
    // OpenSSH's key-file KDF:
    bcrypt_pbkdf: *const fn (pass: [*]const u8, pass_len: usize, salt: [*]const u8, salt_len: usize, rounds: u32, out: [*]u8, out_len: usize) callconv(cc) bool,

    // AES-256 in counter mode, the counter big-endian (OpenSSH's
    // aes256-ctr key files); false from a ZCRYPT without it:
    aes256_ctr: *const fn (key: *const [32]u8, iv: *const [16]u8, in: [*]const u8, out: [*]u8, len: usize) callconv(cc) bool,

    // TLS client (libs/vendor/zig-tls): a connection's state lives in
    // tls_size bytes of the caller's, 16-aligned. tls_connect does the
    // handshake over io and gives a TlsResult; verify checks the host's
    // name and the certificates of \CONF\CACERT.PEM (boot drive); now
    // is in seconds since 1970.
    tls_size: *const fn () callconv(cc) usize,
    tls_connect: *const fn (state: [*]u8, io: *const TlsIo, host: [*]const u8, host_len: usize, verify: bool, now: i64) callconv(cc) u32,
    // Bytes, at least one; 0: the end; -1: it failed
    tls_read: *const fn (state: [*]u8, out: [*]u8, len: usize) callconv(cc) isize,
    // One record's bytes, maybe none; -1: it failed, -2: closed
    tls_read_some: *const fn (state: [*]u8, out: [*]u8, len: usize) callconv(cc) isize,
    tls_write: *const fn (state: [*]u8, data: [*]const u8, len: usize) callconv(cc) bool,
    // Decrypted bytes not yet read (poll can't see them)
    tls_pending: *const fn (state: [*]u8) callconv(cc) bool,

    // TLS 1.3 server: its state in tls_server_size bytes of the caller's,
    // 16-aligned. tls_accept does the handshake over io (its recv gives
    // -2 when the socket's time ran out) and gives a TlsResult; certs:
    // DER, the server's first; its P-256 key as secret and public.
    tls_server_size: *const fn () callconv(cc) usize,
    tls_accept: *const fn (state: [*]u8, io: *const TlsIo, certs: [*]const TlsCert, count: usize, secret: *const [32]u8, public: *const [65]u8) callconv(cc) u32,
    // Bytes; 0: the client closed; -1: it failed, -2: time ran out
    tls_server_read: *const fn (state: [*]u8, out: [*]u8, len: usize) callconv(cc) isize,
    tls_server_write: *const fn (state: [*]u8, data: [*]const u8, len: usize) callconv(cc) bool,
    tls_server_pending: *const fn (state: [*]u8) callconv(cc) bool,
    // Sends close_notify
    tls_server_close: *const fn (state: [*]u8) callconv(cc) void,

    // P-256. p256_public: a secret's public key (uncompressed SEC1),
    // false if it isn't one. p256_sign_der: a signature with SHA-256 in
    // DER with minimal integers, its length (0: it failed).
    p256_public: *const fn (secret: *const [32]u8, out: *[65]u8) callconv(cc) bool,
    p256_sign_der: *const fn (secret: *const [32]u8, msg: [*]const u8, len: usize, out: *[72]u8) callconv(cc) usize,
};

pub const TlsCert = extern struct {
    der: [*]const u8,
    len: usize,
};

// What tls_connect's state reads and writes through: the bytes moved,
// 0 at the end (recv), negative if it failed
pub const TlsIo = extern struct {
    ctx: ?*anyopaque,
    recv: *const fn (ctx: ?*anyopaque, buf: [*]u8, len: usize) callconv(cc) isize,
    send: *const fn (ctx: ?*anyopaque, data: [*]const u8, len: usize) callconv(cc) isize,
};

pub const TlsResult = enum(u32) {
    ok = 0,
    not_verified = 1,
    host_mismatch = 2,
    expired = 3,
    not_yet_valid = 4,
    no_certificates = 5,
    io = 6,
    out_of_memory = 7,
    failed = 8,
    closed = 9,
    timed_out = 10,
    unsupported = 11,
    _,
};

// 19 MiB plus room for the allocator's bookkeeping.
pub const argon2_work = 20 * 1024 * 1024;

// Loaded on first use (NotFound: no \LIBS\ZCRYPT.ZDL).
pub fn get() zdos.Error!*const Api {
    const S = struct {
        var table: ?*const Api = null;
    };
    if (S.table) |t| return t;
    const t = try zdos.library(Api, "ZCRYPT");
    S.table = t;
    return t;
}

// STD.CRYPTO'S SHAPES OVER THE TABLE
// So programs call the library instead of linking their own copy;
// without ZCRYPT.ZDL the program ends.

fn lib() *const Api {
    return get() catch {
        zdos.printError("ZCRYPT.ZDL is missing (\\LIBS)\n");
        zdos.exit(1);
    };
}

pub const Sha256 = struct {
    state: Sha256State,

    pub fn init(_: struct {}) Sha256 {
        var h: Sha256 = undefined;
        lib().sha256_init(&h.state);
        return h;
    }

    pub fn update(h: *Sha256, data: []const u8) void {
        lib().sha256_update(&h.state, data.ptr, data.len);
    }

    pub fn final(h: *Sha256, out: *[32]u8) void {
        lib().sha256_final(&h.state, out);
    }

    pub fn hash(data: []const u8, out: *[32]u8, _: struct {}) void {
        lib().sha256(data.ptr, data.len, out);
    }
};

pub const X25519 = struct {
    pub fn recoverPublicKey(secret: [32]u8) error{IdentityElement}![32]u8 {
        var out: [32]u8 = undefined;
        if (!lib().x25519_public(&secret, &out)) return error.IdentityElement;
        return out;
    }

    pub fn scalarmult(secret: [32]u8, public: [32]u8) error{IdentityElement}![32]u8 {
        var out: [32]u8 = undefined;
        if (!lib().x25519_shared(&secret, &public, &out)) return error.IdentityElement;
        return out;
    }
};

pub const Ed25519 = struct {
    pub const PublicKey = struct {
        bytes: [32]u8,

        // Checked when a signature is
        pub fn fromBytes(b: [32]u8) error{NonCanonical}!PublicKey {
            return .{ .bytes = b };
        }

        pub fn toBytes(pk: PublicKey) [32]u8 {
            return pk.bytes;
        }
    };

    // The seed, then the public key:
    pub const SecretKey = struct {
        bytes: [64]u8,

        pub fn fromBytes(b: [64]u8) error{NonCanonical}!SecretKey {
            return .{ .bytes = b };
        }

        pub fn toBytes(sk: SecretKey) [64]u8 {
            return sk.bytes;
        }
    };

    pub const Signature = struct {
        bytes: [64]u8,

        pub fn fromBytes(b: [64]u8) Signature {
            return .{ .bytes = b };
        }

        pub fn toBytes(s: Signature) [64]u8 {
            return s.bytes;
        }

        pub fn verify(s: Signature, msg: []const u8, pk: PublicKey) error{SignatureVerificationFailed}!void {
            if (!lib().ed25519_verify(&pk.bytes, msg.ptr, msg.len, &s.bytes)) return error.SignatureVerificationFailed;
        }
    };

    pub const KeyPair = struct {
        public_key: PublicKey,
        secret_key: SecretKey,

        pub fn generateDeterministic(seed: [32]u8) error{IdentityElement}!KeyPair {
            var kp: KeyPair = undefined;
            if (!lib().ed25519_from_seed(&seed, &kp.public_key.bytes, &kp.secret_key.bytes)) return error.IdentityElement;
            return kp;
        }

        // The public half must be the seed's
        pub fn fromSecretKey(sk: SecretKey) error{ IdentityElement, NonCanonical }!KeyPair {
            const kp = try generateDeterministic(sk.bytes[0..32].*);
            if (!std.mem.eql(u8, &kp.public_key.bytes, sk.bytes[32..64])) return error.NonCanonical;
            return kp;
        }

        pub fn sign(kp: KeyPair, msg: []const u8, noise: ?[32]u8) error{IdentityElement}!Signature {
            _ = noise; // deterministic, as RFC 8032
            var s: Signature = undefined;
            if (!lib().ed25519_sign(&kp.secret_key.bytes, msg.ptr, msg.len, &s.bytes)) return error.IdentityElement;
            return s;
        }
    };
};

// ECDSA P-256 with SHA-256, verifying only
pub const EcdsaP256Sha256 = struct {
    pub const PublicKey = struct {
        sec1: [65]u8,
        len: usize,

        // Checked when a signature is
        pub fn fromSec1(b: []const u8) error{InvalidEncoding}!PublicKey {
            if (b.len == 0 or b.len > 65) return error.InvalidEncoding;
            var pk: PublicKey = .{ .sec1 = undefined, .len = b.len };
            @memcpy(pk.sec1[0..b.len], b);
            return pk;
        }
    };

    // r, then s:
    pub const Signature = struct {
        bytes: [64]u8,

        pub fn fromBytes(b: [64]u8) Signature {
            return .{ .bytes = b };
        }

        pub fn verify(s: Signature, msg: []const u8, pk: PublicKey) error{SignatureVerificationFailed}!void {
            if (!lib().p256_verify(&pk.sec1, pk.len, msg.ptr, msg.len, &s.bytes)) return error.SignatureVerificationFailed;
        }
    };
};

pub const ChaCha20With64BitNonce = struct {
    pub fn xor(out: []u8, in: []const u8, counter: u64, key: [32]u8, nonce: [8]u8) void {
        lib().chacha20_xor(&key, &nonce, counter, in.ptr, out.ptr, in.len);
    }

    pub fn stream(out: []u8, counter: u64, key: [32]u8, nonce: [8]u8) void {
        @memset(out, 0);
        lib().chacha20_xor(&key, &nonce, counter, out.ptr, out.ptr, out.len);
    }
};

pub const Poly1305 = struct {
    pub fn create(out: *[16]u8, msg: []const u8, key: *const [32]u8) void {
        lib().poly1305(key, msg.ptr, msg.len, out);
    }
};

fn AesGcm(comptime key_len: usize) type {
    return struct {
        pub fn encrypt(c: []u8, tag: *[16]u8, m: []const u8, ad: []const u8, npub: [12]u8, key: [key_len]u8) void {
            _ = lib().aes_gcm_seal(&key, key_len, &npub, ad.ptr, ad.len, m.ptr, m.len, c.ptr, tag);
        }

        pub fn decrypt(m: []u8, c: []const u8, tag: [16]u8, ad: []const u8, npub: [12]u8, key: [key_len]u8) error{AuthenticationFailed}!void {
            if (!lib().aes_gcm_open(&key, key_len, &npub, ad.ptr, ad.len, c.ptr, c.len, m.ptr, &tag)) return error.AuthenticationFailed;
        }
    };
}

pub const Aes128Gcm = AesGcm(16);
pub const Aes256Gcm = AesGcm(32);

// OpenSSH's key-file KDF, then AES-256-CTR with its key and IV
pub fn opensshKdf(pass: []const u8, salt: []const u8, out: []u8, rounds: u32) error{WeakParameters}!void {
    if (!lib().bcrypt_pbkdf(pass.ptr, pass.len, salt.ptr, salt.len, rounds, out.ptr, out.len)) return error.WeakParameters;
}

pub fn aes256Ctr(key: *const [32]u8, iv: *const [16]u8, out: []u8, in: []const u8) error{NotSupported}!void {
    if (!lib().aes256_ctr(key, iv, in.ptr, out.ptr, in.len)) return error.NotSupported;
}

// Argon2id with users.zig's settings; work: argon2_work bytes
pub fn argon2idHash(password: []const u8, salt: *const [16]u8, work: []u8, out: []u8) []const u8 {
    const n = lib().argon2id_hash(password.ptr, password.len, salt, work.ptr, work.len, out.ptr, out.len);
    return out[0..n];
}

pub fn argon2idVerify(phc: []const u8, password: []const u8, work: []u8) bool {
    return lib().argon2id_verify(phc.ptr, phc.len, password.ptr, password.len, work.ptr, work.len);
}

// TLS OVER A SOCKET
// The connection's state in the program's memory; the handshake,
// records and certificate checks in the library.

pub const Tls = struct {
    conn: []align(16) u8,

    pub const Error = error{
        TlsCertificateNotVerified,
        CertificateHostMismatch,
        CertificateExpired,
        CertificateNotYetValid,
        NoCertificates,
        ConnectionFailed,
        OutOfMemory,
        TlsFailed,
    };

    // verify: the host's name and \CONF\CACERT.PEM's authorities
    pub fn connect(sock: net.Socket, host: []const u8, verify: bool, now: i64) Error!Tls {
        const api = lib();
        const mem = zdos.allocator.alignedAlloc(u8, 16, api.tls_size()) catch return error.OutOfMemory;
        errdefer zdos.allocator.free(mem);
        const io: TlsIo = .{ .ctx = @ptrFromInt(@as(usize, @intCast(sock.handle))), .recv = sockRecv, .send = sockSend };
        const r: TlsResult = @enumFromInt(api.tls_connect(mem.ptr, &io, host.ptr, host.len, verify, now));
        return switch (r) {
            .ok => .{ .conn = mem },
            .not_verified => error.TlsCertificateNotVerified,
            .host_mismatch => error.CertificateHostMismatch,
            .expired => error.CertificateExpired,
            .not_yet_valid => error.CertificateNotYetValid,
            .no_certificates => error.NoCertificates,
            .io => error.ConnectionFailed,
            .out_of_memory => error.OutOfMemory,
            else => error.TlsFailed,
        };
    }

    pub fn deinit(self: Tls) void {
        zdos.allocator.free(self.conn);
    }

    // At least one byte; 0: the end
    pub fn read(self: Tls, out: []u8) error{ConnectionFailed}!usize {
        const n = lib().tls_read(self.conn.ptr, out.ptr, out.len);
        if (n < 0) return error.ConnectionFailed;
        return @intCast(n);
    }

    // One record's bytes, maybe none
    pub fn readSome(self: Tls, out: []u8) error{ ConnectionFailed, EndOfStream }!usize {
        const n = lib().tls_read_some(self.conn.ptr, out.ptr, out.len);
        if (n == -2) return error.EndOfStream;
        if (n < 0) return error.ConnectionFailed;
        return @intCast(n);
    }

    pub fn writeAll(self: Tls, data: []const u8) error{ConnectionFailed}!void {
        if (!lib().tls_write(self.conn.ptr, data.ptr, data.len)) return error.ConnectionFailed;
    }

    // Decrypted bytes not yet read: poll can't see them
    pub fn pending(self: Tls) bool {
        return lib().tls_pending(self.conn.ptr);
    }
};

// A TLS 1.3 server's side of a socket
pub const TlsServer = struct {
    conn: []align(16) u8,

    pub const Error = error{ Closed, TimedOut, Unsupported, ConnectionFailed, OutOfMemory, TlsFailed };

    // certs: DER, the server's first
    pub fn accept(sock: net.Socket, certs: []const []const u8, key: *const P256Key) Error!TlsServer {
        const api = lib();
        var list: [4]TlsCert = undefined;
        if (certs.len == 0 or certs.len > list.len) return error.TlsFailed;
        for (certs, 0..) |c, i| list[i] = .{ .der = c.ptr, .len = c.len };
        const mem = zdos.allocator.alignedAlloc(u8, 16, api.tls_server_size()) catch return error.OutOfMemory;
        errdefer zdos.allocator.free(mem);
        const io: TlsIo = .{ .ctx = @ptrFromInt(@as(usize, @intCast(sock.handle))), .recv = sockRecv, .send = sockSend };
        const r: TlsResult = @enumFromInt(api.tls_accept(mem.ptr, &io, &list, certs.len, &key.secret, &key.public));
        return switch (r) {
            .ok => .{ .conn = mem },
            .closed => error.Closed,
            .timed_out => error.TimedOut,
            .unsupported => error.Unsupported,
            .io => error.ConnectionFailed,
            else => error.TlsFailed,
        };
    }

    // close_notify sent, the state freed
    pub fn deinit(self: TlsServer) void {
        lib().tls_server_close(self.conn.ptr);
        zdos.allocator.free(self.conn);
    }

    // 0: the client closed
    pub fn read(self: TlsServer, out: []u8) error{ ConnectionFailed, TimedOut }!usize {
        const n = lib().tls_server_read(self.conn.ptr, out.ptr, out.len);
        if (n == -2) return error.TimedOut;
        if (n < 0) return error.ConnectionFailed;
        return @intCast(n);
    }

    pub fn writeAll(self: TlsServer, data: []const u8) error{ConnectionFailed}!void {
        if (!lib().tls_server_write(self.conn.ptr, data.ptr, data.len)) return error.ConnectionFailed;
    }

    // Decrypted bytes not yet read: poll can't see them
    pub fn pending(self: TlsServer) bool {
        return lib().tls_server_pending(self.conn.ptr);
    }
};

// P-256: the secret and its public key (uncompressed SEC1)
pub const P256Key = struct {
    secret: [32]u8,
    public: [65]u8,

    pub fn fromSecret(secret: [32]u8) error{BadKey}!P256Key {
        var k: P256Key = .{ .secret = secret, .public = undefined };
        if (!lib().p256_public(&k.secret, &k.public)) return error.BadKey;
        return k;
    }

    // A signature with SHA-256 in DER, in out
    pub fn signDer(k: *const P256Key, msg: []const u8, out: *[72]u8) error{BadKey}![]const u8 {
        const n = lib().p256_sign_der(&k.secret, msg.ptr, msg.len, out);
        if (n == 0) return error.BadKey;
        return out[0..n];
    }
};

fn socketOf(ctx: ?*anyopaque) net.Socket {
    return .{ .handle = @intCast(@intFromPtr(ctx)) };
}

// -2: the socket's receive time ran out
fn sockRecv(ctx: ?*anyopaque, buf: [*]u8, len: usize) callconv(cc) isize {
    const n = socketOf(ctx).recv(buf[0..len]) catch |err| return if (err == error.WouldBlock) -2 else -1;
    return @intCast(n);
}

fn sockSend(ctx: ?*anyopaque, data: [*]const u8, len: usize) callconv(cc) isize {
    const n = socketOf(ctx).send(data[0..len]) catch return -1;
    return @intCast(n);
}
