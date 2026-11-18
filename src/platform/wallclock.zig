// The date without asking the hardware each time: the clock
// chip (BIOS) or the firmware (UEFI's GetTime) read once, then
// the milliseconds counted on from there. Read again every
// minute and after the date is set. Each read was a dozen
// slow I/O ports (a VM exit each): a program calling time()
// for every DOM event spent most of its time there.
const std = @import("std");
const platform = @import("../platform.zig");
const DateTime = platform.DateTime;

const resync_ms = 60_000;

var lock = std.atomic.Value(bool).init(false);
var valid = false;
var base_secs: i64 = 0; // the date when read, as seconds from 1970
var base_ms: u64 = 0; // the counter then

// read: the hardware's date; ms: the counter now
pub fn now(read: *const fn () ?DateTime, ms: u64) ?DateTime {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    defer lock.store(false, .release);
    if (!valid or ms < base_ms or ms - base_ms >= resync_ms) {
        const t = read() orelse {
            valid = false;
            return null;
        };
        base_secs = toSecs(t);
        base_ms = ms;
        valid = true;
        return t;
    }
    return fromSecs(base_secs + @as(i64, @intCast((ms - base_ms) / 1000)));
}

// After the date is set: the hardware's read again
pub fn forget() void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    valid = false;
    lock.store(false, .release);
}

// DAYS (Hinnant's civil calendar algorithms)

fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y0 - 1 else y0;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn toSecs(t: DateTime) i64 {
    const days = daysFromCivil(t.year, t.month, t.day);
    return days * 86400 + @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second;
}

fn fromSecs(s: i64) DateTime {
    const days = @divFloor(s, 86400);
    const rest = s - days * 86400;
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const d = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    const y = yoe + era * 400 + (if (m <= 2) @as(i64, 1) else 0);
    return .{
        .year = @intCast(y),
        .month = @intCast(m),
        .day = @intCast(d),
        .hour = @intCast(@divFloor(rest, 3600)),
        .minute = @intCast(@divFloor(@mod(rest, 3600), 60)),
        .second = @intCast(@mod(rest, 60)),
    };
}
