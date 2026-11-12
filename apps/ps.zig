// PS: the tasks running now
const zdos = @import("zdos/zdos.zig");
const system = @import("zdos/system.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    _ = args;
    zdos.print("TASK PARENT PRIORITY  STATE          TIME PROGRAM\n");
    var i: u32 = 0;
    while (system.taskInfo(i)) |t| : (i += 1) {
        const state = switch (t.state) {
            system.TaskState.ready => "ready",
            system.TaskState.running => "running",
            system.TaskState.sleeping => "sleeping",
            system.TaskState.waiting => "waiting",
            system.TaskState.stopped => "stopped",
            else => "ended",
        };
        var prio_buf: [16]u8 = undefined;
        const prio = if (t.priority != t.base_priority)
            @import("std").fmt.bufPrint(&prio_buf, "{d} ({d})", .{ t.priority, t.base_priority }) catch "?"
        else
            @import("std").fmt.bufPrint(&prio_buf, "{d}", .{t.priority}) catch "?";
        // 0 where tasks don't switch:
        const ms = t.cpu_ms;
        zdos.printf("{d:>4} {d:>6} {s:<9} {s:<9} {d:>3}:{d:0>2}.{d:0>2} {s}\n", .{ t.id, t.parent, prio, state, ms / 60000, ms / 1000 % 60, ms / 10 % 100, @import("std").mem.sliceTo(&t.name, 0) });
    }
    return 0;
}
