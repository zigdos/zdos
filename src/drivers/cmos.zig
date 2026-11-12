// The CMOS RTC (MC146818)
const port = @import("../arch/x86_port.zig");
const DateTime = @import("../platform.zig").DateTime;

const index_port = 0x70;
const data_port = 0x71;
const nmi_off = 0x80; // keeps NMIs off while a register is selected

const reg_second = 0x00;
const reg_minute = 0x02;
const reg_hour = 0x04;
const reg_weekday = 0x06; // 1 = Sunday; not used by ZDOS, but DOS-era programs read it
const reg_day = 0x07;
const reg_month = 0x08;
const reg_year = 0x09;
const reg_a = 0x0A; // bit 7: update in progress
const reg_b = 0x0B; // bit 7: stop updates, bit 2: binary (not BCD), bit 1: 24-hour mode

// From ACPI's FADT. 0: none, only
// the two-digit year, so 1980-2079.
pub var century_reg: u8 = 0;

fn read(reg: u8) u8 {
    port.outb(index_port, nmi_off | reg);
    port.wait();
    return port.inb(data_port);
}

fn write(reg: u8, val: u8) void {
    port.outb(index_port, nmi_off | reg);
    port.wait();
    port.outb(data_port, val);
}

fn updating() bool {
    return read(reg_a) & 0x80 != 0;
}

const Raw = struct { s: u8, m: u8, h: u8, d: u8, mo: u8, y: u8 };

fn readRaw() Raw {
    while (updating()) {}
    return .{ .s = read(reg_second), .m = read(reg_minute), .h = read(reg_hour), .d = read(reg_day), .mo = read(reg_month), .y = read(reg_year) };
}

fn fromBcd(v: u8) u8 {
    return (v >> 4) * 10 + (v & 0x0F);
}

fn toBcd(v: u8) u8 {
    return ((v / 10) << 4) | (v % 10);
}

fn decode(v: u8, binary: bool) u8 {
    return if (binary) v else fromBcd(v);
}

// The two-digit year counts from 2000 (80-99: 1980-1999),
// unless the century register says otherwise.
pub fn now() ?DateTime {
    // Read until two reads agree: the clock may tick in between:
    var a = readRaw();
    var tries: usize = 0;
    while (tries < 5) : (tries += 1) {
        const b = readRaw();
        if (sameRaw(a, b)) break;
        a = b;
    }
    const status = read(reg_b);
    const binary = status & 0x04 != 0;
    const pm = a.h & 0x80 != 0;
    var r = a;
    r.h &= 0x7F;
    if (!binary) {
        r = .{ .s = fromBcd(r.s), .m = fromBcd(r.m), .h = fromBcd(r.h), .d = fromBcd(r.d), .mo = fromBcd(r.mo), .y = fromBcd(r.y) };
    }
    if (status & 0x02 == 0) { // 12-hour mode: 12 AM is 0, 12 PM is 12
        r.h %= 12;
        if (pm) r.h += 12;
    }
    if (r.mo < 1 or r.mo > 12 or r.d < 1 or r.d > 31 or r.h > 23 or r.m > 59 or r.s > 59 or r.y > 99) return null;
    const century: u8 = if (century_reg != 0) decode(read(century_reg), binary) else 0;
    const year: u16 = if (century >= 1 and century <= 99)
        @as(u16, century) * 100 + r.y
    else if (r.y >= 80) 1900 + @as(u16, r.y) else 2000 + @as(u16, r.y);
    return .{ .year = year, .month = r.mo, .day = r.d, .hour = r.h, .minute = r.m, .second = r.s };
}

// 0 = Sunday (Sakamoto's method).
fn weekday(dt: DateTime) u8 {
    const offsets = [_]u16{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const y: u16 = if (dt.month < 3) dt.year - 1 else dt.year;
    return @intCast((y + y / 4 - y / 100 + y / 400 + offsets[dt.month - 1] + dt.day) % 7);
}

fn sameRaw(a: Raw, b: Raw) bool {
    return a.s == b.s and a.m == b.m and a.h == b.h and a.d == b.d and a.mo == b.mo and a.y == b.y;
}

pub fn set(dt: DateTime) bool {
    // With the century register every year up to 9999 fits:
    if (century_reg == 0 and (dt.year < 1980 or dt.year > 2079)) return false;
    if (dt.year > 9999) return false;
    const status = read(reg_b);
    const binary = status & 0x04 != 0;
    const h24 = status & 0x02 != 0;
    const conv = struct {
        fn f(v: u8, bin: bool) u8 {
            return if (bin) v else toBcd(v);
        }
    }.f;
    var hour = conv(dt.hour, binary);
    if (!h24) {
        const h12: u8 = if (dt.hour % 12 == 0) 12 else dt.hour % 12;
        hour = conv(h12, binary) | (if (dt.hour >= 12) @as(u8, 0x80) else 0);
    }
    write(reg_b, status | 0x80); // stop updates while writing
    write(reg_second, conv(dt.second, binary));
    write(reg_minute, conv(dt.minute, binary));
    write(reg_hour, hour);
    write(reg_weekday, conv(weekday(dt) + 1, binary));
    write(reg_day, conv(dt.day, binary));
    write(reg_month, conv(dt.month, binary));
    write(reg_year, conv(@intCast(dt.year % 100), binary));
    if (century_reg != 0) write(century_reg, conv(@intCast(dt.year / 100), binary));
    write(reg_b, status & 0x7F);
    return true;
}
