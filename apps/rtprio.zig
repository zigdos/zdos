// RTPRIO: a task's scheduling policy and priority.
//   RTPRIO -f|-r PRIORITY [-p ID | PROGRAM [ARGS]]
//   RTPRIO -d RUNTIME DEADLINE PERIOD [-p ID | PROGRAM [ARGS]]   (us)
//   RTPRIO -p ID
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const system = @import("zdos/system.zig");

comptime {
    _ = zdos;
}

const usage =
    \\Usage: RTPRIO -f|-r PRIORITY PROGRAM [ARGS]  run PROGRAM with that policy
    \\       RTPRIO -f|-r -p PRIORITY ID           change a running task
    \\       RTPRIO -d RUNTIME DEADLINE PERIOD PROGRAM [ARGS]
    \\       RTPRIO -d RUNTIME DEADLINE PERIOD -p ID
    \\       RTPRIO -p ID                          show a task's policy and priority
    \\  -f FIFO (keeps the CPU until it waits), -r RR (turns every 10 ms, the
    \\  default); PRIORITY 0-31, higher first (default 16). -d: earliest
    \\  deadline first, above every priority: RUNTIME each PERIOD, done by
    \\  DEADLINE after its start (microseconds)
    \\
;

const names = [_][]const u8{ "RR", "FIFO", "RR", "RR", "RR", "RR", "DEADLINE" }; // by abi.Policy

pub fn main(args: []const u8) u8 {
    var it = std.mem.tokenizeAny(u8, args, " \t");
    var policy: ?u32 = null;
    var pid_mode = false;
    var word = it.next() orelse return fail(usage);
    var dl: [3]u64 = undefined;
    while (word.len == 2 and word[0] == '-') : (word = it.next() orelse return fail(usage)) {
        switch (std.ascii.toLower(word[1])) {
            'f' => policy = 1,
            'r' => policy = 2,
            'p' => pid_mode = true,
            'd' => {
                policy = 6;
                for (&dl) |*v| v.* = 1000 * (std.fmt.parseInt(u64, it.next() orelse return fail(usage), 10) catch return fail(usage));
            },
            else => return fail(usage),
        }
    }
    if (policy == 6) return deadline(word, &it, pid_mode, dl);
    if (pid_mode and policy == null) return show(word);
    const p = policy orelse return fail(usage);
    const prio = std.fmt.parseInt(u32, word, 10) catch return fail(usage);
    if (prio > 31) return fail("RTPRIO: priority 0-31\n");
    if (pid_mode) {
        const id = std.fmt.parseInt(u32, it.next() orelse return fail(usage), 10) catch return fail(usage);
        set(id, p, prio) catch |err| return failErr(err);
        return 0;
    }
    // The program runs in this task and inherits both; ZDOS puts them
    // back for the shell when it ends.
    const program = it.next() orelse return fail(usage);
    set(system.taskId(), p, prio) catch |err| return failErr(err);
    return zdos.exec(program, std.mem.trimLeft(u8, it.rest(), " \t")) catch |err| failErr(err);
}

fn deadline(word: []const u8, it: anytype, pid_mode: bool, dl: [3]u64) u8 {
    if (pid_mode) {
        const id = std.fmt.parseInt(u32, word, 10) catch return fail(usage);
        system.taskSetDeadline(id, dl[0], dl[1], dl[2]) catch |err| return failErr(err);
        return 0;
    }
    system.taskSetDeadline(system.taskId(), dl[0], dl[1], dl[2]) catch |err| return failErr(err);
    return zdos.exec(word, std.mem.trimLeft(u8, it.rest(), " \t")) catch |err| failErr(err);
}

fn set(id: u32, policy: u32, prio: u32) zdos.Error!void {
    try system.taskSetPriority(id, prio);
    try system.taskSetPolicy(id, policy);
}

fn show(word: []const u8) u8 {
    const id = std.fmt.parseInt(u32, word, 10) catch return fail(usage);
    const prio = system.taskPriority(id) orelse return fail("RTPRIO: no such task\n");
    const p = system.taskPolicy(id) orelse 0;
    if (system.taskDeadline(id)) |d| {
        zdos.printf("Task {d}: DEADLINE, runtime {d} us, deadline {d} us, period {d} us\n", .{ id, d.runtime / 1000, d.deadline / 1000, d.period / 1000 });
        return 0;
    }
    zdos.printf("Task {d}: {s}, priority {d}\n", .{ id, names[@min(p, names.len - 1)], prio });
    return 0;
}

fn fail(text: []const u8) u8 {
    zdos.printError(text);
    return 1;
}

fn failErr(err: zdos.Error) u8 {
    zdos.eprintf("RTPRIO: {s}\n", .{zdos.message(err)});
    return 1;
}
