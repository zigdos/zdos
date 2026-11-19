// ZDLTEST: tests .ZDL loading with ZCRYPT, then each of its functions
// against Zig's own crypto. TAP-like lines; exit code: failures.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const zcrypt = @import("zdos/zcrypt.zig");

comptime {
    _ = zdos;
}

pub const std_options: std.Options = .{
    .cryptoRandomSeed = zdos.randomBytes,
    .crypto_always_getrandom = true,
};

var passed: u32 = 0;
var failed: u32 = 0;

fn check(ok: bool, comptime what: []const u8) void {
    if (ok) passed += 1 else failed += 1;
    zdos.print(if (ok) "ok - " ++ what ++ "\n" else "not ok - " ++ what ++ "\n");
}

pub fn main(_: []const u8) u8 {
    zdos.print("# ZDLTEST\n");
    const z = zcrypt.get() catch |err| {
        zdos.printf("not ok - ZCRYPT.ZDL loads ({s})\n# ZDLTEST: 0 passed, 1 failed\n", .{zdos.message(err)});
        return 1;
    };
    check(true, "ZCRYPT.ZDL loads");
    const again = zdos.loadLibrary("zcrypt") catch null;
    check(again != null and @intFromPtr(again.?) == @intFromPtr(z), "a shared library's table is the same (any case)");
    check(if (zdos.loadLibrary("NOSUCH")) |_| false else |err| err == error.NotFound, "a missing library: NotFound");
    check(if (zdos.loadLibrary("BAD/NAME")) |_| false else |err| err == error.InvalidArgument, "a bad name: InvalidArgument");
    check(z.slots == @import("abi").slotsOf(zcrypt.Api), "its table has every slot");

    const msg = "The quick brown fox jumps over the lazy dog";
    var seed: [32]u8 = undefined;
    for (&seed, 0..) |*b, i| b.* = @intCast(i * 7 + 1);

    // Hashes:
    var h1: [32]u8 = undefined;
    var h2: [32]u8 = undefined;
    z.sha256(msg, msg.len, &h1);
    std.crypto.hash.sha2.Sha256.hash(msg, &h2, .{});
    check(std.mem.eql(u8, &h1, &h2), "sha256");
    var st: zcrypt.Sha256State = undefined;
    z.sha256_init(&st);
    z.sha256_update(&st, msg, 10);
    z.sha256_update(&st, msg[10..], msg.len - 10);
    z.sha256_final(&st, &h1);
    check(std.mem.eql(u8, &h1, &h2), "sha256 in parts");
    z.hmac_sha256(&seed, seed.len, msg, msg.len, &h1);
    std.crypto.auth.hmac.sha2.HmacSha256.create(&h2, msg, &seed);
    check(std.mem.eql(u8, &h1, &h2), "hmac-sha256");

    // X25519:
    var pub1: [32]u8 = undefined;
    const ok_pub = z.x25519_public(&seed, &pub1);
    const want_pub = std.crypto.dh.X25519.recoverPublicKey(seed) catch unreachable;
    check(ok_pub and std.mem.eql(u8, &pub1, &want_pub), "x25519 public key");
    var other: [32]u8 = undefined;
    for (&other, 0..) |*b, i| b.* = @intCast(255 - i);
    const other_pub = std.crypto.dh.X25519.recoverPublicKey(other) catch unreachable;
    var shared: [32]u8 = undefined;
    const ok_shared = z.x25519_shared(&seed, &other_pub, &shared);
    const want_shared = std.crypto.dh.X25519.scalarmult(other, want_pub) catch unreachable;
    check(ok_shared and std.mem.eql(u8, &shared, &want_shared), "x25519 shared secret (both sides agree)");

    // Ed25519:
    var ed_pub: [32]u8 = undefined;
    var ed_sec: [64]u8 = undefined;
    const kp = std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
    check(z.ed25519_from_seed(&seed, &ed_pub, &ed_sec) and std.mem.eql(u8, &ed_pub, &kp.public_key.toBytes()), "ed25519 key from a seed");
    var sig: [64]u8 = undefined;
    const want_sig = (kp.sign(msg, null) catch unreachable).toBytes();
    check(z.ed25519_sign(&ed_sec, msg, msg.len, &sig) and std.mem.eql(u8, &sig, &want_sig), "ed25519 signature");
    check(z.ed25519_verify(&ed_pub, msg, msg.len, &sig), "ed25519 verifies");
    sig[0] ^= 1;
    check(!z.ed25519_verify(&ed_pub, msg, msg.len, &sig), "ed25519 refuses a changed signature");

    // ECDSA P-256:
    const P256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const pkp = P256.KeyPair.generateDeterministic(seed) catch unreachable;
    const psig = (pkp.sign(msg, null) catch unreachable).toBytes();
    const sec1 = pkp.public_key.toUncompressedSec1();
    check(z.p256_verify(&sec1, sec1.len, msg, msg.len, &psig), "p256 verifies");

    // ChaCha20, Poly1305:
    const nonce = [8]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var c1: [msg.len]u8 = undefined;
    var c2: [msg.len]u8 = undefined;
    z.chacha20_xor(&seed, &nonce, 1, msg, &c1, msg.len);
    std.crypto.stream.chacha.ChaCha20With64BitNonce.xor(&c2, msg, 1, seed, nonce);
    check(std.mem.eql(u8, &c1, &c2), "chacha20");
    var t1: [16]u8 = undefined;
    var t2: [16]u8 = undefined;
    z.poly1305(&seed, msg, msg.len, &t1);
    std.crypto.onetimeauth.Poly1305.create(&t2, msg, &seed);
    check(std.mem.eql(u8, &t1, &t2), "poly1305");

    // AES-GCM, both key sizes, and a forged tag:
    const iv = [12]u8{ 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2 };
    const ad = "header";
    inline for (.{ 16, 32 }) |key_len| {
        var sealed: [msg.len]u8 = undefined;
        var tag: [16]u8 = undefined;
        var opened: [msg.len]u8 = undefined;
        const sealed_ok = z.aes_gcm_seal(&seed, key_len, &iv, ad, ad.len, msg, msg.len, &sealed, &tag);
        check(sealed_ok and z.aes_gcm_open(&seed, key_len, &iv, ad, ad.len, &sealed, msg.len, &opened, &tag) and std.mem.eql(u8, &opened, msg), std.fmt.comptimePrint("aes-{d}-gcm both ways", .{key_len * 8}));
        tag[0] ^= 1;
        check(!z.aes_gcm_open(&seed, key_len, &iv, ad, ad.len, &sealed, msg.len, &opened, &tag), std.fmt.comptimePrint("aes-{d}-gcm refuses a forged tag", .{key_len * 8}));
    }

    // Argon2id: its work memory is ours:
    if (zdos.allocator.alloc(u8, zcrypt.argon2_work)) |work| {
        defer zdos.allocator.free(work);
        var phc: [128]u8 = undefined;
        const salt = [16]u8{ 1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 121, 98, 219 };
        const n = z.argon2id_hash("secret", 6, &salt, work.ptr, work.len, &phc, phc.len);
        check(n > 0 and std.mem.startsWith(u8, phc[0..n], "$argon2id$"), "argon2id hash");
        check(n > 0 and z.argon2id_verify(&phc, n, "secret", 6, work.ptr, work.len), "argon2id verifies the password");
        check(n > 0 and !z.argon2id_verify(&phc, n, "wrong", 5, work.ptr, work.len), "argon2id refuses another");
    } else |_| check(false, "memory for argon2id");

    // bcrypt-pbkdf (OpenSSH's key files):
    var k1: [48]u8 = undefined;
    var k2: [48]u8 = undefined;
    const ok_kdf = z.bcrypt_pbkdf("pass", 4, &seed, 16, 4, &k1, k1.len);
    std.crypto.pwhash.bcrypt.opensshKdf("pass", seed[0..16], &k2, 4) catch unreachable;
    check(ok_kdf and std.mem.eql(u8, &k1, &k2), "bcrypt-pbkdf");

    // AES-256-CTR (their encrypted part), a counter crossing a byte:
    var ctr_iv = [_]u8{0} ** 16;
    ctr_iv[15] = 0xFE;
    var ctr1: [100]u8 = undefined;
    var ctr2: [100]u8 = undefined;
    const ok_ctr = z.aes256_ctr(&seed, &ctr_iv, msg.ptr, &ctr1, msg.len);
    const aes = std.crypto.core.aes.Aes256.initEnc(seed);
    std.crypto.core.modes.ctr(@TypeOf(aes), aes, ctr2[0..msg.len], msg, ctr_iv, .big);
    check(ok_ctr and std.mem.eql(u8, ctr1[0..msg.len], ctr2[0..msg.len]), "aes256-ctr");

    zdos.printf("# ZDLTEST: {d} passed, {d} failed\n", .{ passed, failed });
    return @intCast(@min(failed, 255));
}
