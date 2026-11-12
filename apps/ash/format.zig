// printf conversions, for the printf built-in and awk.
const std = @import("std");

const Allocator = std.mem.Allocator;
pub const Out = std.ArrayListUnmanaged(u8);

pub const Spec = struct {
    minus: bool = false,
    plus: bool = false,
    space: bool = false,
    zero: bool = false,
    alt: bool = false,
    width: ?usize = null,
    precision: ?usize = null,
    width_star: bool = false,
    precision_star: bool = false,
    conv: u8 = 0,
    len: usize = 0, // bytes of the format the spec took, from the %
};

// fmt[at] == '%'; null if it is incomplete or unknown.
pub fn parseSpec(fmt: []const u8, at: usize) ?Spec {
    var spec: Spec = .{};
    var i = at + 1;
    while (i < fmt.len) : (i += 1) {
        switch (fmt[i]) {
            '-' => spec.minus = true,
            '+' => spec.plus = true,
            ' ' => spec.space = true,
            '0' => spec.zero = true,
            '#' => spec.alt = true,
            else => break,
        }
    }
    if (i < fmt.len and fmt[i] == '*') {
        spec.width_star = true;
        i += 1;
    } else {
        const start = i;
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) i += 1;
        if (i > start) spec.width = std.fmt.parseInt(usize, fmt[start..i], 10) catch return null;
    }
    if (i < fmt.len and fmt[i] == '.') {
        i += 1;
        if (i < fmt.len and fmt[i] == '*') {
            spec.precision_star = true;
            i += 1;
        } else {
            const start = i;
            while (i < fmt.len and std.ascii.isDigit(fmt[i])) i += 1;
            spec.precision = std.fmt.parseInt(usize, fmt[start..i], 10) catch 0;
        }
    }
    // Length modifiers (%ld, %lld, %hd) change nothing here:
    while (i < fmt.len and (fmt[i] == 'l' or fmt[i] == 'h')) i += 1;
    if (i >= fmt.len) return null;
    switch (fmt[i]) {
        'd', 'i', 'o', 'u', 'x', 'X', 'c', 's', 'e', 'E', 'f', 'F', 'g', 'G', '%' => spec.conv = fmt[i],
        else => return null,
    }
    spec.len = i + 1 - at;
    return spec;
}

// So a typo can't ask for gigabytes:
const max_width = 4096;

pub fn integer(allocator: Allocator, out: *Out, spec: Spec, value: f64) Allocator.Error!void {
    const v = clampInt(value);
    var digits_buf: [72]u8 = undefined;
    var prefix: []const u8 = "";
    var digits: []const u8 = undefined;
    switch (spec.conv) {
        'o', 'u', 'x', 'X' => {
            const u: u64 = @bitCast(v);
            digits = switch (spec.conv) {
                'o' => std.fmt.bufPrint(&digits_buf, "{o}", .{u}) catch unreachable,
                'x' => std.fmt.bufPrint(&digits_buf, "{x}", .{u}) catch unreachable,
                'X' => std.fmt.bufPrint(&digits_buf, "{X}", .{u}) catch unreachable,
                else => std.fmt.bufPrint(&digits_buf, "{d}", .{u}) catch unreachable,
            };
            if (spec.alt and u != 0) prefix = switch (spec.conv) {
                'x' => "0x",
                'X' => "0X",
                'o' => "0",
                else => "",
            };
        },
        else => {
            digits = std.fmt.bufPrint(&digits_buf, "{d}", .{@abs(v)}) catch unreachable;
            prefix = if (v < 0) "-" else if (spec.plus) "+" else if (spec.space) " " else "";
        },
    }
    var zeros: usize = 0;
    if (spec.precision) |p| {
        const pp = @min(p, max_width);
        if (pp == 0 and v == 0) digits = "";
        if (pp > digits.len) zeros = pp - digits.len;
    }
    const body_len = prefix.len + zeros + digits.len;
    const width = @min(spec.width orelse 0, max_width);
    const pad = if (width > body_len) width - body_len else 0;
    if (spec.zero and !spec.minus and spec.precision == null) {
        try out.appendSlice(allocator, prefix);
        try out.appendNTimes(allocator, '0', pad + zeros);
        try out.appendSlice(allocator, digits);
        return;
    }
    if (!spec.minus) try out.appendNTimes(allocator, ' ', pad);
    try out.appendSlice(allocator, prefix);
    try out.appendNTimes(allocator, '0', zeros);
    try out.appendSlice(allocator, digits);
    if (spec.minus) try out.appendNTimes(allocator, ' ', pad);
}

fn clampInt(value: f64) i64 {
    if (std.math.isNan(value)) return 0;
    if (value >= 9.2233720368547758e18) return std.math.maxInt(i64);
    if (value <= -9.2233720368547758e18) return std.math.minInt(i64);
    return @intFromFloat(value);
}

pub fn string(allocator: Allocator, out: *Out, spec: Spec, value: []const u8) Allocator.Error!void {
    var s = value;
    if (spec.precision) |p| {
        if (p < s.len) s = s[0..p];
    }
    try padded(allocator, out, spec, s);
}

pub fn char(allocator: Allocator, out: *Out, spec: Spec, c: []const u8) Allocator.Error!void {
    try padded(allocator, out, spec, c);
}

fn padded(allocator: Allocator, out: *Out, spec: Spec, s: []const u8) Allocator.Error!void {
    const width = @min(spec.width orelse 0, max_width);
    const pad = if (width > s.len) width - s.len else 0;
    if (!spec.minus) try out.appendNTimes(allocator, ' ', pad);
    try out.appendSlice(allocator, s);
    if (spec.minus) try out.appendNTimes(allocator, ' ', pad);
}

pub fn float(allocator: Allocator, out: *Out, spec: Spec, value: f64) Allocator.Error!void {
    var buf: [1100]u8 = undefined;
    const body = floatBody(&buf, spec, @abs(value));
    const negative = value < 0 or (value == 0 and std.math.signbit(value));
    const sign: []const u8 = if (negative) "-" else if (spec.plus) "+" else if (spec.space) " " else "";
    const width = @min(spec.width orelse 0, max_width);
    const len = sign.len + body.len;
    const pad = if (width > len) width - len else 0;
    const finite = std.math.isFinite(value);
    if (spec.zero and !spec.minus and finite) {
        try out.appendSlice(allocator, sign);
        try out.appendNTimes(allocator, '0', pad);
        try out.appendSlice(allocator, body);
        return;
    }
    if (!spec.minus) try out.appendNTimes(allocator, ' ', pad);
    try out.appendSlice(allocator, sign);
    try out.appendSlice(allocator, body);
    if (spec.minus) try out.appendNTimes(allocator, ' ', pad);
}

// For %e %f %g, no sign.
fn floatBody(buf: []u8, spec: Spec, v: f64) []const u8 {
    const upper = spec.conv == 'E' or spec.conv == 'F' or spec.conv == 'G';
    if (std.math.isNan(v)) return if (upper) "NAN" else "nan";
    if (std.math.isInf(v)) return if (upper) "INF" else "inf";
    const precision = @min(spec.precision orelse 6, 500);
    switch (spec.conv) {
        'f', 'F' => return fixed(buf, v, precision, spec.alt),
        'e', 'E' => return scientific(buf, v, precision, spec.alt, upper),
        else => {
            const p = if (precision == 0) 1 else precision;
            const x = exponentOf(v, p - 1);
            var s = if (x < -4 or x >= @as(i32, @intCast(p)))
                scientific(buf, v, p - 1, spec.alt, upper)
            else
                fixed(buf, v, @intCast(@as(i32, @intCast(p)) - 1 - x), spec.alt);
            if (!spec.alt) s = stripZeros(buf, s);
            return s;
        },
    }
}

fn fixed(buf: []u8, v: f64, precision: usize, alt: bool) []const u8 {
    var s = fixedExact(buf[0 .. buf.len - 1], v, precision) orelse
        std.fmt.formatFloat(buf[0 .. buf.len - 1], v, .{ .mode = .decimal, .precision = precision }) catch return "?";
    if (alt and precision == 0) {
        buf[s.len] = '.';
        s = buf[0 .. s.len + 1];
    }
    return s;
}

// Rounded half to even as C does: Zig rounds the shortest decimal form, so
// 2.675 would become 2.68, C prints 2.67. Below 2^63 with up to 18 decimals;
// null otherwise.
fn fixedExact(buf: []u8, v: f64, precision: usize) ?[]const u8 {
    if (precision > 18 or !(v < 9.2e18)) return null;
    const bits: u64 = @bitCast(v);
    const biased: i32 = @intCast((bits >> 52) & 0x7ff);
    var mant: u128 = bits & ((1 << 52) - 1);
    var exp: i32 = biased - 1075;
    if (biased == 0) {
        exp = -1074;
    } else {
        mant |= 1 << 52;
    }
    const scale = std.math.powi(u128, 10, precision) catch return null;
    var n: u128 = undefined;
    if (exp >= 0) {
        n = (mant << @intCast(exp)) * scale;
    } else if (exp < -120) {
        n = 0; // below 10^-18: rounds to zero
    } else {
        const k: u7 = @intCast(-exp);
        const x = mant * scale;
        n = x >> k;
        const rem = x - (n << k);
        const half = @as(u128, 1) << (k - 1);
        if (rem > half or (rem == half and n & 1 == 1)) n += 1;
    }
    var digits_buf: [48]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{n}) catch return null;
    if (digits.len + precision + 3 > buf.len) return null;
    var len: usize = 0;
    if (digits.len <= precision) {
        buf[0] = '0';
        len = 1;
        if (precision > 0) {
            buf[1] = '.';
            len = 2;
            @memset(buf[len..][0 .. precision - digits.len], '0');
            len += precision - digits.len;
            @memcpy(buf[len..][0..digits.len], digits);
            len += digits.len;
        }
        return buf[0..len];
    }
    const int_len = digits.len - precision;
    @memcpy(buf[0..int_len], digits[0..int_len]);
    len = int_len;
    if (precision > 0) {
        buf[len] = '.';
        len += 1;
        @memcpy(buf[len..][0..precision], digits[int_len..]);
        len += precision;
    }
    return buf[0..len];
}

// Written with `precision` digits after the point.
fn exponentOf(v: f64, precision: usize) i32 {
    var buf: [600]u8 = undefined;
    const s = std.fmt.formatFloat(&buf, v, .{ .mode = .scientific, .precision = precision }) catch return 0;
    const e = std.mem.indexOfScalar(u8, s, 'e') orelse return 0;
    return std.fmt.parseInt(i32, s[e + 1 ..], 10) catch 0;
}

// Zig writes "1.5e2"; C wants "1.5e+02".
fn scientific(buf: []u8, v: f64, precision: usize, alt: bool, upper: bool) []const u8 {
    var tmp: [600]u8 = undefined;
    const s = std.fmt.formatFloat(&tmp, v, .{ .mode = .scientific, .precision = precision }) catch return "?";
    const e = std.mem.indexOfScalar(u8, s, 'e') orelse return "?";
    const exp = std.fmt.parseInt(i32, s[e + 1 ..], 10) catch 0;
    var n: usize = 0;
    @memcpy(buf[0..e], s[0..e]);
    n = e;
    if (alt and precision == 0) {
        buf[n] = '.';
        n += 1;
    }
    const tail = std.fmt.bufPrint(buf[n..], "{c}{c}{d:0>2}", .{
        @as(u8, if (upper) 'E' else 'e'),
        @as(u8, if (exp < 0) '-' else '+'),
        @abs(exp),
    }) catch return "?";
    return buf[0 .. n + tail.len];
}

// %g drops zeros after the decimal point, and the point itself.
fn stripZeros(buf: []u8, s: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return s;
    const e = std.mem.indexOfAny(u8, s, "eE") orelse s.len;
    var end = e;
    while (end > dot + 1 and s[end - 1] == '0') end -= 1;
    if (end == dot + 1) end = dot;
    if (end == e) return s;
    // s lives in buf; move the exponent down:
    const exp_len = s.len - e;
    std.mem.copyForwards(u8, buf[end .. end + exp_len], s[e..]);
    return buf[0 .. end + exp_len];
}

// Integers plainly, others with %.6g (fmt: OFMT or CONVFMT).
pub fn number(allocator: Allocator, out: *Out, value: f64, fmt: []const u8) Allocator.Error!void {
    if (value == @trunc(value) and @abs(value) < 1e16) {
        var buf: [32]u8 = undefined;
        const i: i64 = @intFromFloat(value);
        try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
        return;
    }
    if (parseSpec(fmt, 0)) |spec| {
        if (spec.len == fmt.len) {
            switch (spec.conv) {
                'e', 'E', 'f', 'F', 'g', 'G' => return float(allocator, out, spec, value),
                'd', 'i' => return integer(allocator, out, spec, value),
                else => {},
            }
        }
    }
    return float(allocator, out, .{ .conv = 'g' }, value);
}
