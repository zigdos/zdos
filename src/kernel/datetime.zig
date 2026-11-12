// Calendar checks for set_time and set_file_time
const DateTime = @import("../platform.zig").DateTime;

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
