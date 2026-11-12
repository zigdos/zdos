const zdos = @import("../zdos/zdos.zig");

pub fn run(args: []const []const u8) u8 {
    if (args.len != 0 and args[0].len > 0 and args[0][0] == '+') return printFormat(args[0][1..]);
    const now = zdos.getTime();
    const days = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const weekday = weekdayOf(now.year, now.month, now.day);
    const month_index: usize = @intCast(@max(1, @min(now.month, 12)) - 1);
    zdos.printf("{s} {s} {d:>2} {d:0>2}:{d:0>2}:{d:0>2} {d}\n", .{
        days[weekday], months[month_index], now.day, now.hour, now.minute, now.second, now.year,
    });
    return 0;
}

fn printFormat(format: []const u8) u8 {
    const now = zdos.getTime();
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        if (format[i] != '%') {
            zdos.print(format[i .. i + 1]);
            continue;
        }
        i += 1;
        if (i == format.len) {
            zdos.print("%");
            break;
        }
        switch (format[i]) {
            '%' => zdos.print("%"),
            'Y' => zdos.printf("{d:0>4}", .{now.year}),
            'F' => zdos.printf("{d:0>4}-{d:0>2}-{d:0>2}", .{ now.year, now.month, now.day }),
            'm' => zdos.printf("{d:0>2}", .{now.month}),
            'd' => zdos.printf("{d:0>2}", .{now.day}),
            'H' => zdos.printf("{d:0>2}", .{now.hour}),
            'M' => zdos.printf("{d:0>2}", .{now.minute}),
            'S' => zdos.printf("{d:0>2}", .{now.second}),
            'T' => zdos.printf("{d:0>2}:{d:0>2}:{d:0>2}", .{ now.hour, now.minute, now.second }),
            'a' => zdos.print(([_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" })[weekdayOf(now.year, now.month, now.day)]),
            'b' => zdos.print(([_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" })[@as(usize, @intCast(@max(1, @min(now.month, 12)) - 1))]),
            else => zdos.printf("%{c}", .{format[i]}),
        }
    }
    zdos.print("\n");
    return 0;
}

fn weekdayOf(year: u16, month: u8, day: u8) usize {
    const offsets = [_]usize{ 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 };
    const safe_month = @max(month, 1);
    const y: usize = if (safe_month < 3) year - 1 else year;
    return (y + y / 4 - y / 100 + y / 400 + offsets[(safe_month - 1) % 12] + day) % 7;
}
