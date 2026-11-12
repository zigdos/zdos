// TOP [N]: the tasks and their CPU use, anew every N seconds (1).
// CPU time is counted at the 1 ms timer of metal; elsewhere only the
// list is shown.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const system = @import("zdos/system.zig");

comptime {
    _ = zdos;
}

const max_tasks = 64;

const Row = struct {
    info: system.TaskInfo,
    used_ms: u64, // since the last screen
};

// At the last screen, to tell what each used since.
var last_ids: [max_tasks]u32 = undefined;
var last_ms: [max_tasks]u64 = undefined;
var last_count: usize = 0;

fn previous(id: u32) ?u64 {
    for (last_ids[0..last_count], last_ms[0..last_count]) |i, ms| {
        if (i == id) return ms;
    }
    return null;
}

fn stateName(s: u8) []const u8 {
    return switch (s) {
        system.TaskState.ready => "ready",
        system.TaskState.running => "running",
        system.TaskState.sleeping => "sleeping",
        system.TaskState.waiting => "waiting",
        system.TaskState.stopped => "stopped",
        else => "ended",
    };
}

// Cut or filled with spaces to the screen's width.
fn line(row: u32, width: u32, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
    const w = @min(width -| 1, buf.len);
    var out: [256]u8 = undefined;
    const n = @min(text.len, w);
    @memcpy(out[0..n], text[0..n]);
    @memset(out[n..w], ' ');
    zdos.setCursor(0, row);
    zdos.print(out[0..w]);
}

pub fn main(args: []const u8) u8 {
    const word = std.mem.trim(u8, args, " \t");
    const seconds: u32 = if (word.len == 0) 1 else std.fmt.parseInt(u32, word, 10) catch {
        zdos.print("TOP [seconds between screens]   Q or Esc ends it\n");
        return 1;
    };
    const interval: u64 = @as(u64, @max(seconds, 1)) * 1000;
    // The alternate screen: the console's comes back afterwards:
    zdos.print("\x1b[?1049h");
    zdos.clearScreen();
    zdos.showCursor(false);
    defer {
        zdos.clearScreen();
        zdos.print("\x1b[?1049l");
        zdos.showCursor(true);
    }
    var last_times = system.cpuTimes();
    var shown_at = zdos.millis();
    var first = true;
    while (true) {
        const times = system.cpuTimes();
        const span = times.total_ms -| last_times.total_ms;
        // Idle time counts only where tasks switch (metal); never 0 there:
        const measured = times.idle_ms != 0;
        draw(times, if (first) 0 else span, times.idle_ms -| last_times.idle_ms, measured);
        last_times = times;
        first = false;
        // Keys between screens; the screen comes again after the interval:
        shown_at = zdos.millis();
        while (zdos.millis() - shown_at < interval) {
            if (zdos.pollKey()) |k| {
                if (k.scan == zdos.Scan.esc or k.char == 'q' or k.char == 'Q') return 0;
            }
            zdos.sleep(50);
        }
    }
}

fn draw(times: zdos.CpuTimes, span: u64, idle: u64, measured: bool) void {
    const size = zdos.screenSize();
    var rows: [max_tasks]Row = undefined;
    var n: usize = 0;
    var i: u32 = 0;
    while (system.taskInfo(i)) |t| : (i += 1) {
        if (n == rows.len) break;
        const before = previous(t.id) orelse t.cpu_ms;
        rows[n] = .{ .info = t, .used_ms = t.cpu_ms -| before };
        n += 1;
    }
    // The busiest first:
    std.mem.sort(Row, rows[0..n], {}, struct {
        fn more(_: void, a: Row, b: Row) bool {
            if (a.used_ms != b.used_ms) return a.used_ms > b.used_ms;
            return a.info.id < b.info.id;
        }
    }.more);
    last_count = n;
    for (rows[0..n], 0..) |r, k| {
        last_ids[k] = r.info.id;
        last_ms[k] = r.info.cpu_ms;
    }

    const up = times.total_ms / 1000;
    if (measured and span > 0) {
        const busy = (span -| idle) * 1000 / span;
        line(0, size.col, "TOP - up {d}:{d:0>2}:{d:0>2}   tasks {d}   CPU busy {d}.{d}%  idle {d}.{d}%   {d} cores", .{
            up / 3600, up / 60 % 60, up % 60, n, busy / 10, busy % 10, (1000 - busy) / 10, (1000 - busy) % 10, system.coreCount(),
        });
    } else {
        line(0, size.col, "TOP - up {d}:{d:0>2}:{d:0>2}   tasks {d}   {d} cores{s}", .{
            up / 3600, up / 60 % 60, up % 60, n, system.coreCount(), if (measured) "" else "   (CPU time is counted on the metal editions)",
        });
    }
    const info = zdos.systemInfo();
    line(1, size.col, "Memory {d} MB free of {d} MB", .{ info.free_memory >> 20, info.total_memory >> 20 });
    line(2, size.col, "", .{});
    line(3, size.col, " TASK PARENT PRI STATE      CPU%      TIME PROGRAM", .{});
    var row: u32 = 4;
    for (rows[0..n]) |r| {
        if (row + 1 >= size.row) break;
        const pct = if (span > 0) r.used_ms * 1000 / span else 0;
        const ms = r.info.cpu_ms;
        line(row, size.col, "{d:>5} {d:>6} {d:>3} {s:<9} {d:>3}.{d}% {d:>3}:{d:0>2}.{d:0>2} {s}", .{
            r.info.id,               r.info.parent,       r.info.priority, stateName(r.info.state),
            pct / 10,                pct % 10,            ms / 60000,      ms / 1000 % 60,
            ms / 10 % 100,           std.mem.sliceTo(&r.info.name, 0),
        });
        row += 1;
    }
    while (row + 1 < size.row) : (row += 1) line(row, size.col, "", .{});
    line(size.row - 1, size.col, "Q or Esc: quit", .{});
}
