// Date and time parsing for DATE
const std = @import("std");
const DateTime = @import("../zdos/zdos.zig").Time;

// "yyyy-mm-dd", "hh:mm[:ss][ am|pm]", or both. Parts not given
// keep their value; a time without seconds sets them to 0.
pub fn parse(input: []const u8, t: *DateTime) bool {
    var buf: [64]u8 = undefined;
    if (input.len > buf.len) return false;
    const lower = std.ascii.lowerString(&buf, input);

    var new = t.*;
    var have_date = false;
    var have_time = false;
    var pm: ?bool = null;
    var hour: u32 = 0;
    var it = std.mem.tokenizeAny(u8, lower, " \t");
    while (it.next()) |token| {
        var tok = token;
        if (std.mem.eql(u8, tok, "am") or std.mem.eql(u8, tok, "pm")) {
            if (!have_time or pm != null) return false;
            pm = tok[0] == 'p';
        } else if (std.mem.indexOfScalar(u8, tok, '-') != null) {
            if (have_date) return false;
            var parts = std.mem.splitScalar(u8, tok, '-');
            const y = num(parts.next(), 1900, 9999) orelse return false;
            const m = num(parts.next(), 1, 12) orelse return false;
            const d = num(parts.next(), 1, daysInMonth(y, m)) orelse return false;
            if (parts.next() != null) return false;
            new.year = @intCast(y);
            new.month = @intCast(m);
            new.day = @intCast(d);
            have_date = true;
        } else if (std.mem.indexOfScalar(u8, tok, ':') != null) {
            if (have_time) return false;
            if (std.mem.endsWith(u8, tok, "am") or std.mem.endsWith(u8, tok, "pm")) {
                pm = tok[tok.len - 2] == 'p';
                tok = tok[0 .. tok.len - 2];
            }
            var parts = std.mem.splitScalar(u8, tok, ':');
            hour = num(parts.next(), 0, 23) orelse return false;
            new.minute = @intCast(num(parts.next(), 0, 59) orelse return false);
            new.second = @intCast(if (parts.next()) |ss| num(ss, 0, 59) orelse return false else 0);
            if (parts.next() != null) return false;
            have_time = true;
        } else return false;
    }
    if (have_time) {
        if (pm) |is_pm| {
            // 12:xx am is 00:xx, 12:xx pm is 12:xx:
            if (hour < 1 or hour > 12) return false;
            hour = (hour % 12) + @as(u32, if (is_pm) 12 else 0);
        }
        new.hour = @intCast(hour);
    }
    if (!have_date and !have_time) return false;
    t.* = new;
    return true;
}

fn num(s: ?[]const u8, min: u32, max: u32) ?u32 {
    const str = s orelse return null;
    const v = std.fmt.parseInt(u32, str, 10) catch return null;
    return if (v < min or v > max) null else v;
}

pub fn daysInMonth(year: u32, month: u32) u32 {
    const leap = (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
    const days = [_]u32{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return days[month - 1];
}

pub fn valid(t: DateTime) bool {
    if (t.year < 1900 or t.year > 9999 or t.month < 1 or t.month > 12 or t.day < 1 or
        t.hour > 23 or t.minute > 59 or t.second > 59)
    {
        return false;
    }
    return t.day <= daysInMonth(t.year, t.month);
}

// 0 = Sunday (Sakamoto's method).
pub fn weekday(year: u16, month: u8, day: u8) usize {
    const offsets = [_]usize{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const y: usize = if (month < 3) year - 1 else year;
    return (y + y / 4 - y / 100 + y / 400 + offsets[(month - 1) % 12] + day) % 7;
}

pub fn weekdayName(t: DateTime) []const u8 {
    const days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    return days[weekday(t.year, t.month, t.day)];
}
