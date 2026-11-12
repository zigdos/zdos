// ZCRYPT.ZDL: Zig's cryptography as a shared library. No state here:
// callers pass their own memory, so one copy serves every program.
const std = @import("std");
const zdos = @import("zdos");
const abi = @import("abi");
const zc = zdos.zcrypt;

// zdos.zig's start-up (zdos_library_init: the library's groups):
comptime {
    _ = zdos;
}

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
