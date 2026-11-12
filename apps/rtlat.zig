// RTLAT: how late periodic wake-ups run, as Linux's cyclictest.
//   RTLAT [-t THREADS] [-i INTERVAL_US] [-l LOOPS] [-p PRIORITY] [-r]
//         [-a CORE] [-h BUCKET_US] [-q]
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const system = @import("zdos/system.zig");

comptime {
    _ = zdos;
}

const usage =
    \\Usage: RTLAT [-t THREADS] [-i INTERVAL_US] [-l LOOPS] [-p PRIORITY] [-r]
    \\             [-a CORE] [-h BUCKET_US] [-q]
    \\  -t threads (1), -i period in microseconds (1000), -l wake-ups each
    \\  (10000; 0: until Ctrl+C), -p priority 0-31 (28), -r RR instead of FIFO,
    \\  -a thread n on core CORE+n, -h a histogram of BUCKET_US-wide buckets,
    \\  -q only the summary. Times in microseconds.
    \\
;

const max_threads = 16;
const buckets = 20;

const Stats = struct {
    count: u64 = 0,
    min: u64 = std.math.maxInt(u64),
    max: u64 = 0,
    sum: u64 = 0,
    last: u64 = 0,
    overruns: u64 = 0, // wake-ups so late a whole period was missed
    hist: [buckets + 1]u64 = @splat(0),
    done: bool = false,
};

var stats: [max_threads]Stats = @splat(.{});
var cfg = struct {
    threads: u32 = 1,
    interval_ns: u64 = 1_000_000,
    loops: u64 = 10_000,
    priority: u32 = 28,
    fifo: bool = true,
    core: ?u32 = null,
    bucket_ns: u64 = 0,
    quiet: bool = false,
}{};
var stop = std.atomic.Value(bool).init(false);

pub fn main(args: []const u8) u8 {
    if (!parse(args)) {
        zdos.printError(usage);
        return 2;
    }
    zdos.printf("RTLAT: {d} thread(s), period {d} us, priority {d} {s}, clock step {d} ns\n", .{
        cfg.threads, cfg.interval_ns / 1000, cfg.priority, if (cfg.fifo) "FIFO" else "RR", zdos.clockResolution(),
    });
    system.catchCtrlC(true);
    defer system.catchCtrlC(false);
    var ids: [max_threads]u32 = undefined;
    var started: u32 = 0;
    while (started < cfg.threads) : (started += 1) {
        ids[started] = system.threadCreate(&measure, @ptrFromInt(started + 1), 0, cfg.priority) catch |err| {
            zdos.eprintf("RTLAT: no thread: {s}\n", .{zdos.message(err)});
            break;
        };
    }
    // A line per thread every second, until done or Ctrl+C:
    while (true) {
        zdos.sleep(1000);
        if (system.ctrlCPressed(true)) stop.store(true, .release);
        var all_done = true;
        for (stats[0..started], 0..) |*s, n| {
            if (!@atomicLoad(bool, &s.done, .acquire)) all_done = false;
            if (!cfg.quiet) line(n, s);
        }
        if (all_done or stop.load(.acquire)) break;
    }
    stop.store(true, .release);
    for (ids[0..started]) |id| _ = system.threadJoin(id) catch 0;
    zdos.print("Summary:\n");
    for (stats[0..started], 0..) |*s, n| line(n, s);
    if (cfg.bucket_ns != 0) histogram(started);
    return 0;
}

fn measure(arg: ?*anyopaque) callconv(zdos.cc) usize {
    _ = zdos.tlsStart();
    const n = @intFromPtr(arg) - 1;
    const me = system.taskId();
    system.taskSetPolicy(me, if (cfg.fifo) 1 else 2) catch {};
    if (cfg.core) |c| system.taskSetAffinity(me, @as(u64, 1) << @intCast(c + n)) catch
        zdos.eprintf("RTLAT: thread {d} can't have core {d}\n", .{ n, c + n });
    const s = &stats[n];
    var next = zdos.nanos();
    while (!stop.load(.acquire) and (cfg.loops == 0 or s.count < cfg.loops)) {
        next += cfg.interval_ns;
        // Until the absolute deadline, as clock_nanosleep(TIMER_ABSTIME):
        while (zdos.nanos() < next) {
            if (!zdos.sleepUntil(next) and stop.load(.acquire)) break;
        }
        const woke = zdos.nanos();
        const late = woke -| next;
        s.last = late;
        s.min = @min(s.min, late);
        s.max = @max(s.max, late);
        s.sum += late;
        s.count += 1;
        if (cfg.bucket_ns != 0) s.hist[@min(late / cfg.bucket_ns, buckets)] += 1;
        // Missed periods are skipped, as cyclictest does:
        while (next + cfg.interval_ns <= woke) {
            next += cfg.interval_ns;
            s.overruns += 1;
        }
    }
    @atomicStore(bool, &s.done, true, .release);
    return 0;
}

fn line(n: usize, s: *const Stats) void {
    if (s.count == 0) {
        zdos.printf("T{d}: no wake-ups yet\n", .{n});
        return;
    }
    zdos.printf("T{d}: C:{d:>7} Min:{d:>6} Act:{d:>6} Avg:{d:>6} Max:{d:>6} Overruns:{d}\n", .{
        n, s.count, s.min / 1000, s.last / 1000, s.sum / s.count / 1000, s.max / 1000, s.overruns,
    });
}

fn histogram(threads: u32) void {
    zdos.print("Histogram (us: wake-ups per thread)\n");
    for (0..buckets + 1) |b| {
        if (b == buckets) {
            zdos.printf(">={d:>6}:", .{buckets * cfg.bucket_ns / 1000});
        } else zdos.printf("{d:>6}-:", .{b * cfg.bucket_ns / 1000});
        for (stats[0..threads]) |*s| zdos.printf(" {d:>8}", .{s.hist[b]});
        zdos.print("\n");
    }
}

fn parse(args: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |w| {
        if (w.len != 2 or w[0] != '-') return false;
        switch (w[1]) {
            'r' => cfg.fifo = false,
            'q' => cfg.quiet = true,
            't', 'i', 'l', 'p', 'a', 'h' => {
                const v = std.fmt.parseInt(u64, it.next() orelse return false, 10) catch return false;
                switch (w[1]) {
                    't' => cfg.threads = @intCast(@min(@max(v, 1), max_threads)),
                    'i' => cfg.interval_ns = @max(v, 1) * 1000,
                    'l' => cfg.loops = v,
                    'p' => cfg.priority = @intCast(@min(v, 31)),
                    'a' => cfg.core = @intCast(@min(v, 63)),
                    'h' => cfg.bucket_ns = @max(v, 1) * 1000,
                    else => unreachable,
                }
            },
            else => return false,
        }
    }
    return true;
}
