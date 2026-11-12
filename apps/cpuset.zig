// CPUSET: a task's affinity.
//   CPUSET [-p] -c LIST PROGRAM [ARGS] | ID
//   CPUSET -p ID
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const system = @import("zdos/system.zig");

comptime {
    _ = zdos;
}

const usage =
    \\Usage: CPUSET -c LIST PROGRAM [ARGS]  run PROGRAM on those cores
    \\       CPUSET -p -c LIST ID           change a running task
    \\       CPUSET -p ID                   show a task's cores
    \\  LIST: core numbers and ranges, as 2,3 or 1-3 (core 0 is the first)
    \\
;

pub fn main(args: []const u8) u8 {
    var it = std.mem.tokenizeAny(u8, args, " \t");
    var list: ?[]const u8 = null;
    var pid_mode = false;
    // Options first (-c LIST, -p), then the program or the task:
    var word = it.next() orelse return fail(usage);
    while (word.len == 2 and word[0] == '-') : (word = it.next() orelse return fail(usage)) {
        switch (std.ascii.toLower(word[1])) {
            'c' => list = it.next() orelse return fail(usage),
            'p' => pid_mode = true,
            else => return fail(usage),
        }
    }
    const text = list orelse return if (pid_mode) show(word) else fail(usage);
    const mask = parse(text) orelse return fail("CPUSET: a list is core numbers and ranges: 2,3 or 1-3\n");
    if (pid_mode) {
        const id = std.fmt.parseInt(u32, word, 10) catch return fail(usage);
        system.taskSetAffinity(id, mask) catch |err| return failErr(err);
        return 0;
    }
    // The program runs in this task and inherits the set; ZDOS puts it
    // back for the shell when it ends.
    system.taskSetAffinity(system.taskId(), mask) catch |err| return failErr(err);
    return zdos.exec(word, std.mem.trimLeft(u8, it.rest(), " \t")) catch |err| failErr(err);
}

fn parse(text: []const u8) ?u64 {
    var mask: u64 = 0;
    var parts = std.mem.tokenizeScalar(u8, text, ',');
    while (parts.next()) |part| {
        const dash = std.mem.indexOfScalar(u8, part, '-');
        const lo = std.fmt.parseInt(u6, part[0 .. dash orelse part.len], 10) catch return null;
        const hi = if (dash) |d| std.fmt.parseInt(u6, part[d + 1 ..], 10) catch return null else lo;
        if (hi < lo) return null;
        var c = lo;
        while (true) : (c += 1) {
            mask |= @as(u64, 1) << c;
            if (c == hi) break;
        }
    }
    return if (mask == 0) null else mask;
}

fn show(word: []const u8) u8 {
    const id = std.fmt.parseInt(u32, word, 10) catch return fail(usage);
    const mask = system.taskAffinity(id) orelse return fail("CPUSET: no such task\n");
    if (mask == ~@as(u64, 0)) {
        zdos.printf("Task {d}: any core\n", .{id});
        return 0;
    }
    zdos.printf("Task {d}: cores", .{id});
    var sep: []const u8 = " ";
    for (0..64) |c| {
        if ((mask >> @intCast(c)) & 1 == 0) continue;
        zdos.printf("{s}{d}", .{ sep, c });
        sep = ",";
    }
    zdos.print("\n");
    return 0;
}

fn fail(text: []const u8) u8 {
    zdos.printError(text);
    return 1;
}

fn failErr(err: zdos.Error) u8 {
    zdos.eprintf("CPUSET: {s}\n", .{zdos.message(err)});
    return 1;
}
