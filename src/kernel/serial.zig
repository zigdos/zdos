// The serial console's task SERIAL (task-driven, as RTEMS's
// termios): the UART's interrupt only masks it and wakes this
// task, which moves the bytes (drivers/serial/buffered.zig) at
// priority 20, below real-time tasks.
const std = @import("std");
const platform = @import("../platform.zig");
const tasks = @import("tasks.zig");

const priority = 20;
var news = std.atomic.Value(u32).init(0);

pub fn start() void {
    if (comptime !@hasDecl(platform.serial, "startInterrupts")) return;
    if (!tasks.active() or !platform.serial.startInterrupts(&wake)) return;
    // Without its task the buffers would never empty:
    if (tasks.kernelTask(&taskMain, 0, "SERIAL", priority) == null) platform.serial.toPolled();
}

// From the interrupt (interrupts off)
fn wake() void {
    _ = news.fetchAdd(1, .release);
    tasks.wake(&news);
}

fn taskMain(_: usize) callconv(.c) noreturn {
    while (true) {
        const seen = news.load(.acquire);
        platform.serial.service();
        _ = tasks.waitObjectSince(&news, null, &news, seen);
    }
}
