// ZCRYPT.ZDL's export table, and get(). State lives in the caller's memory, so
// one copy serves every program. Slots only get added at the end.
const std = @import("std");
const abi = @import("abi");
const zdos = @import("zdos.zig");

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
