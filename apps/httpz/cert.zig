// The server's certificate chain and key in PEM (ECDSA P-256 only),
// and a self-signed pair made when there is none.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const zc = @import("../zdos/zcrypt.zig"); // ZCRYPT.ZDL

// The secret and its public key
pub const Key = zc.P256Key;

pub const Error = error{ BadPem, BadKey, UnsupportedKey, KeyMismatch, TooBig } || zdos.Error;

pub const max_chain = 4;

pub const Chain = struct {
    der: [16 * 1024]u8 = undefined,
    len: usize = 0,
    certs: [max_chain][]const u8 = undefined,
    count: usize = 0,
};

fn readFile(path: []const u8, buf: []u8) zdos.Error![]const u8 {
    const f = try zdos.open(path, .read);
    defer f.close();
    var len: usize = 0;
    while (len < buf.len) {
        const n = try f.read(buf[len..]);
        if (n == 0) break;
        len += n;
    }
    return buf[0..len];
}

// Between "-----BEGIN label-----" and its END; pos moves past it. Null:
// no more blocks of that label.
fn pemBlock(text: []const u8, pos: *usize, label: []const u8, out: []u8) Error!?[]u8 {
    var begin_buf: [64]u8 = undefined;
    const begin = std.fmt.bufPrint(&begin_buf, "-----BEGIN {s}-----", .{label}) catch return error.BadPem;
    const start = std.mem.indexOfPos(u8, text, pos.*, begin) orelse return null;
    const body = start + begin.len;
    const end = std.mem.indexOfPos(u8, text, body, "-----END") orelse return error.BadPem;
    pos.* = end + 8;
    var clean: [16 * 1024]u8 = undefined;
    var n: usize = 0;
    for (text[body..end]) |c| {
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') continue;
        if (n == clean.len) return error.TooBig;
        clean[n] = c;
        n += 1;
    }
    const dec = std.base64.standard.Decoder;
    const size = dec.calcSizeForSlice(clean[0..n]) catch return error.BadPem;
    if (size > out.len) return error.TooBig;
    dec.decode(out[0..size], clean[0..n]) catch return error.BadPem;
    return out[0..size];
}

pub fn loadChain(path: []const u8, chain: *Chain) Error!void {
    var text_buf: [32 * 1024]u8 = undefined;
    const text = try readFile(path, &text_buf);
    var pos: usize = 0;
    chain.* = .{};
    while (chain.count < max_chain) {
        const der = (try pemBlock(text, &pos, "CERTIFICATE", chain.der[chain.len..])) orelse break;
        chain.certs[chain.count] = der;
        chain.count += 1;
        chain.len += der.len;
    }
    if (chain.count == 0) return error.BadPem;
}

// DER, as much as keys need:

const Der = struct {
    data: []const u8,
    pos: usize = 0,

    // If it has this tag.
    fn next(self: *Der, tag: u8) Error![]const u8 {
        if (self.pos + 2 > self.data.len or self.data[self.pos] != tag) return error.BadKey;
        var len: usize = self.data[self.pos + 1];
        var at = self.pos + 2;
        if (len & 0x80 != 0) {
            const bytes = len & 0x7F;
            if (bytes == 0 or bytes > 3 or at + bytes > self.data.len) return error.BadKey;
            len = 0;
            for (self.data[at .. at + bytes]) |b| len = len << 8 | b;
            at += bytes;
        }
        if (at + len > self.data.len) return error.BadKey;
        self.pos = at + len;
        return self.data[at .. at + len];
    }
};

const oid_ec_public_key = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 };
const oid_p256 = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07 };
const oid_ecdsa_sha256 = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02 };

// SEC1's ECPrivateKey: SEQUENCE { 1, OCTET STRING D, ... }
fn sec1Secret(der: []const u8) Error![32]u8 {
    var outer: Der = .{ .data = der };
    var seq: Der = .{ .data = try outer.next(0x30) };
    _ = try seq.next(0x02);
    const d = try seq.next(0x04);
    if (d.len == 0 or d.len > 32) return error.BadKey;
    var out = [_]u8{0} ** 32;
    @memcpy(out[32 - d.len ..], d);
    return out;
}

// PKCS#8: SEQUENCE { 0, SEQUENCE { ecPublicKey, prime256v1 },
// OCTET STRING { SEC1 } }
fn pkcs8Secret(der: []const u8) Error![32]u8 {
    var outer: Der = .{ .data = der };
    var seq: Der = .{ .data = try outer.next(0x30) };
    _ = try seq.next(0x02);
    var alg: Der = .{ .data = try seq.next(0x30) };
    if (!std.mem.eql(u8, try alg.next(0x06), &oid_ec_public_key)) return error.UnsupportedKey;
    if (!std.mem.eql(u8, try alg.next(0x06), &oid_p256)) return error.UnsupportedKey;
    return sec1Secret(try seq.next(0x04));
}

pub fn loadKey(path: []const u8) Error!Key {
    var text_buf: [8 * 1024]u8 = undefined;
    const text = try readFile(path, &text_buf);
    var der_buf: [4 * 1024]u8 = undefined;
    var pos: usize = 0;
    var secret: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);
    if (try pemBlock(text, &pos, "EC PRIVATE KEY", &der_buf)) |der| {
        secret = try sec1Secret(der);
    } else {
        pos = 0;
        const der = (try pemBlock(text, &pos, "PRIVATE KEY", &der_buf)) orelse
            return error.UnsupportedKey; // RSA, or no key at all
        secret = try pkcs8Secret(der);
    }
    std.crypto.secureZero(u8, &der_buf);
    return Key.fromSecret(secret);
}

// The chain's first certificate holds the key's public key.
pub fn matches(chain: *const Chain, key: Key) bool {
    return std.mem.indexOf(u8, chain.certs[0], &key.public) != null;
}

// SELF-SIGNED CERTIFICATE

const Out = struct {
    buf: []u8,
    len: usize = 0,

    fn add(self: *Out, data: []const u8) Error!void {
        if (self.len + data.len > self.buf.len) return error.TooBig;
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += data.len;
    }

    // tag, its DER length, contents
    fn tlv(self: *Out, tag: u8, contents: []const u8) Error!void {
        var head: [4]u8 = .{ tag, 0, 0, 0 };
        var n: usize = 2;
        if (contents.len < 0x80) {
            head[1] = @intCast(contents.len);
        } else if (contents.len < 0x100) {
            head[1] = 0x81;
            head[2] = @intCast(contents.len);
            n = 3;
        } else {
            head[1] = 0x82;
            head[2] = @intCast(contents.len >> 8);
            head[3] = @intCast(contents.len & 0xFF);
            n = 4;
        }
        try self.add(head[0..n]);
        try self.add(contents);
    }

    fn slice(self: *const Out) []const u8 {
        return self.buf[0..self.len];
    }
};

fn utcTime(t: zdos.Time, years_later: u16, buf: *[13]u8) []const u8 {
    const year = t.year + years_later;
    return std.fmt.bufPrint(buf, "{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{ year % 100, t.month, t.day, t.hour, t.minute, t.second }) catch unreachable;
}

// SEQUENCE { SET { SEQUENCE { commonName, UTF8String cn } } }
fn name(out: *Out, cn: []const u8) Error!void {
    var b1: [128]u8 = undefined;
    var b2: [128]u8 = undefined;
    var b3: [128]u8 = undefined;
    var attr: Out = .{ .buf = &b1 };
    try attr.tlv(0x06, &.{ 0x55, 0x04, 0x03 });
    try attr.tlv(0x0C, cn);
    var set: Out = .{ .buf = &b2 };
    try set.tlv(0x30, attr.slice());
    var seq: Out = .{ .buf = &b3 };
    try seq.tlv(0x31, set.slice());
    try out.tlv(0x30, seq.slice());
}

// 10 years from now, for localhost and the names given.
pub fn makeSelfSigned(key: *const Key, cn: []const u8, dns_names: []const []const u8, out_der: []u8) Error![]const u8 {
    var tbs_buf: [2048]u8 = undefined;
    var tbs: Out = .{ .buf = &tbs_buf };
    var tmp: [1024]u8 = undefined;
    var tmp2: [1024]u8 = undefined;

    try tbs.tlv(0xA0, &.{ 0x02, 0x01, 0x02 }); // version 3
    var serial: [16]u8 = undefined;
    zdos.randomBytes(&serial);
    serial[0] &= 0x7F; // positive
    serial[0] |= 0x40; // and no leading zero
    try tbs.tlv(0x02, &serial);
    var alg: Out = .{ .buf = &tmp };
    try alg.tlv(0x06, &oid_ecdsa_sha256);
    try tbs.tlv(0x30, alg.slice());
    try name(&tbs, cn); // issuer
    const now = zdos.getTime();
    var t1: [13]u8 = undefined;
    var t2: [13]u8 = undefined;
    var validity: Out = .{ .buf = &tmp };
    try validity.tlv(0x17, utcTime(now, 0, &t1));
    try validity.tlv(0x17, utcTime(now, 10, &t2));
    try tbs.tlv(0x30, validity.slice());
    try name(&tbs, cn); // subject
    // SubjectPublicKeyInfo:
    var spki: Out = .{ .buf = &tmp };
    var ids: Out = .{ .buf = &tmp2 };
    try ids.tlv(0x06, &oid_ec_public_key);
    try ids.tlv(0x06, &oid_p256);
    try spki.tlv(0x30, ids.slice());
    var bits: [66]u8 = undefined;
    bits[0] = 0;
    bits[1..].* = key.public;
    try spki.tlv(0x03, &bits);
    try tbs.tlv(0x30, spki.slice());
    // Extensions: basicConstraints (not a CA), subjectAltName:
    var alt_names: Out = .{ .buf = &tmp };
    for (dns_names) |n| try alt_names.tlv(0x82, n);
    var alt_seq: Out = .{ .buf = &tmp2 };
    try alt_seq.tlv(0x30, alt_names.slice());
    var b_san: [600]u8 = undefined;
    var san: Out = .{ .buf = &b_san };
    try san.tlv(0x06, &.{ 0x55, 0x1D, 0x11 });
    try san.tlv(0x04, alt_seq.slice());
    var b_bc: [64]u8 = undefined;
    var bc: Out = .{ .buf = &b_bc };
    try bc.tlv(0x06, &.{ 0x55, 0x1D, 0x13 });
    try bc.tlv(0x04, &.{ 0x30, 0x00 });
    var b_exts: [800]u8 = undefined;
    var exts: Out = .{ .buf = &b_exts };
    try exts.tlv(0x30, bc.slice());
    try exts.tlv(0x30, san.slice());
    var b_wrap: [800]u8 = undefined;
    var wrap: Out = .{ .buf = &b_wrap };
    try wrap.tlv(0x30, exts.slice());
    try tbs.tlv(0xA3, wrap.slice());

    var b_tbs_seq: [2048]u8 = undefined;
    var tbs_seq: Out = .{ .buf = &b_tbs_seq };
    try tbs_seq.tlv(0x30, tbs.slice());
    var sig_der: [72]u8 = undefined;
    const sig_bytes = try key.signDer(tbs_seq.slice(), &sig_der);
    var sig_bits: [72 + 1]u8 = undefined;
    sig_bits[0] = 0;
    @memcpy(sig_bits[1..][0..sig_bytes.len], sig_bytes);

    var b_body: [2400]u8 = undefined;
    var body: Out = .{ .buf = &b_body };
    try body.add(tbs_seq.slice());
    var alg2: Out = .{ .buf = &tmp };
    try alg2.tlv(0x06, &oid_ecdsa_sha256);
    try body.tlv(0x30, alg2.slice());
    try body.tlv(0x03, sig_bits[0 .. sig_bytes.len + 1]);
    var cert: Out = .{ .buf = out_der };
    try cert.tlv(0x30, body.slice());
    return cert.slice();
}

// SEC1 ECPrivateKey: SEQUENCE { 1, OCTET STRING D, [0] prime256v1,
// [1] public }
fn sec1Der(key: *const Key, out_buf: []u8) Error![]const u8 {
    var b: [200]u8 = undefined;
    var inner: Out = .{ .buf = &b };
    try inner.tlv(0x02, &.{1});
    try inner.tlv(0x04, &key.secret);
    var b0: [16]u8 = undefined;
    var curve: Out = .{ .buf = &b0 };
    try curve.tlv(0x06, &oid_p256);
    try inner.tlv(0xA0, curve.slice());
    var bits: [66]u8 = undefined;
    bits[0] = 0;
    bits[1..].* = key.public;
    var b1: [80]u8 = undefined;
    var pub_bits: Out = .{ .buf = &b1 };
    try pub_bits.tlv(0x03, &bits);
    try inner.tlv(0xA1, pub_bits.slice());
    var out: Out = .{ .buf = out_buf };
    try out.tlv(0x30, inner.slice());
    std.crypto.secureZero(u8, &b);
    return out.slice();
}

fn writePem(path: []const u8, label: []const u8, der: []const u8) Error!void {
    var b64: [8 * 1024]u8 = undefined;
    const enc = std.base64.standard.Encoder;
    if (enc.calcSize(der.len) > b64.len) return error.TooBig;
    const text = enc.encode(&b64, der);
    const f = try zdos.open(path, .write);
    defer f.close();
    var line: [80]u8 = undefined;
    try f.writeAll(std.fmt.bufPrint(&line, "-----BEGIN {s}-----\n", .{label}) catch unreachable);
    var i: usize = 0;
    while (i < text.len) : (i += 64) {
        try f.writeAll(text[i..@min(i + 64, text.len)]);
        try f.writeAll("\n");
    }
    try f.writeAll(std.fmt.bufPrint(&line, "-----END {s}-----\n", .{label}) catch unreachable);
    std.crypto.secureZero(u8, &b64);
}

// The key only root's to read.
pub fn makeFiles(cert_path: []const u8, key_path: []const u8, dns_names: []const []const u8) Error!void {
    var secret: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &secret);
    var key: Key = undefined;
    defer std.crypto.secureZero(u8, &key.secret);
    while (true) {
        zdos.randomBytes(&secret);
        key = Key.fromSecret(secret) catch continue; // 0 or past the order: again
        break;
    }
    var der: [3000]u8 = undefined;
    const cert_der = try makeSelfSigned(&key, "zdos", dns_names, &der);
    var key_der_buf: [256]u8 = undefined;
    const key_der = try sec1Der(&key, &key_der_buf);
    defer std.crypto.secureZero(u8, &key_der_buf);
    try writePem(key_path, "EC PRIVATE KEY", key_der);
    zdos.setMode(key_path, 0o600) catch {};
    try writePem(cert_path, "CERTIFICATE", cert_der);
    zdos.setMode(cert_path, 0o644) catch {};
}
