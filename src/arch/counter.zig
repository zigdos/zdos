// Nanoseconds from a free-running counter
// (TSC, ARM64's generic timer): ticks times a
// 32.32 fixed-point factor, so any rate
// converts with one multiply.

pub const Counter = struct {
    start: u64 = 0,
    mult: u64 = 1 << 32, // nanoseconds per tick, times 2^32

    pub fn setRate(self: *Counter, per_second: u64) void {
        self.mult = @intCast((@as(u128, 1_000_000_000) << 32) / @max(per_second, 1));
    }

    pub fn nanos(self: *const Counter, now: u64) u64 {
        return @truncate((@as(u128, now -% self.start) * self.mult) >> 32);
    }

    // The inverse of nanos, for deadline timers.
    pub fn ticksAt(self: *const Counter, ns: u64) u64 {
        return self.start +% @as(u64, @truncate((@as(u128, ns) << 32) / @max(self.mult, 1)));
    }

    // At least 1.
    pub fn resolution(self: *const Counter) u64 {
        return @max(1, (self.mult + (1 << 32) - 1) >> 32);
    }
};
