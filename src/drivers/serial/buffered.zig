// A serial port through buffers, task-driven (as RTEMS's
// termios task mode): the chip's interrupt only masks it and
// wakes a kernel task (kernel/serial.zig), which moves the
// bytes at its own priority, below real-time tasks. With
// interrupts off: at most `batch` bytes and a few registers.
// Before the interrupt works (and after a panic): polled.
// Chip: canSend, send, received, putPolled, setInterrupts,
// pending, connectLine, fifo_size (uart16550.zig).
const std = @import("std");
const platform = @import("../../platform.zig");

pub fn Buffered(comptime Chip: type) type {
    return struct {
        const Self = @This();
        const tx_size = 4096;
        const rx_size = 256;
        const batch = 4;

        // idle: "room to send" off; armed: on; pending: masked by
        // the interrupt, the task woken
        const State = enum { idle, armed, pending };

        chip: Chip,
        keys: bool = true, // received bytes are taken (SERIAL=on)
        irq: bool = false, // the interrupt works: the buffers are used
        state: State = .idle,
        room: u32 = 0, // free in the chip's FIFO, as last seen empty
        wake: ?*const fn () void = null, // the task
        input_wake: ?*const fn () void = null, // a task waiting for keys
        lock: std.atomic.Value(bool) = .init(false),
        // Counters run free; their difference is the fill
        tx: [tx_size]u8 = undefined,
        tx_head: u32 = 0,
        tx_tail: u32 = 0,
        rx: [rx_size]u8 = undefined,
        rx_head: u32 = 0,
        rx_tail: u32 = 0,

        pub fn put(self: *Self, c: u8) void {
            if (!self.irq) return self.chip.putPolled(c);
            while (true) {
                const was = self.take();
                if (self.tx_head -% self.tx_tail < tx_size) {
                    self.tx[self.tx_head % tx_size] = c;
                    self.tx_head +%= 1;
                    if (self.state == .idle) {
                        self.state = .armed;
                        self.chip.setInterrupts(self.keys, true);
                    }
                    return self.give(was);
                }
                // Full: a batch from here, whatever this task's
                // priority (the serial task may be below it)
                _ = self.sendBatch();
                self.give(was);
            }
        }

        // A received byte, if one is waiting
        pub fn get(self: *Self) ?u8 {
            if (!self.keys) return null;
            if (!self.irq) return self.chip.received();
            const was = self.take();
            defer self.give(was);
            if (self.rx_tail == self.rx_head) return null;
            const c = self.rx[self.rx_tail % rx_size];
            self.rx_tail +%= 1;
            return c;
        }

        // Once its interrupt is connected (wake: the task's)
        pub fn startInterrupts(self: *Self, wake: *const fn () void) void {
            const was = self.take();
            self.wake = wake;
            self.chip.connectLine();
            self.irq = true;
            self.state = .idle;
            self.chip.setInterrupts(self.keys, false);
            self.give(was);
        }

        // The interrupt handler's (interrupts off); whether it was
        // this chip's
        pub fn interrupt(self: *Self) bool {
            while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
            const ours = self.chip.pending();
            if (ours) {
                self.chip.setInterrupts(false, false);
                self.state = .pending;
            }
            self.lock.store(false, .release);
            if (ours) if (self.wake) |w| w();
            return ours;
        }

        // The task's: received bytes in, buffered ones out, until
        // nothing moves; then the interrupts it waits for
        pub fn service(self: *Self) void {
            var got = false;
            while (true) {
                const was = self.take();
                var moved = false;
                var n: usize = 0;
                while (n < batch) : (n += 1) {
                    const c = self.chip.received() orelse break;
                    moved = true;
                    if (self.keys and self.rx_head -% self.rx_tail < rx_size) {
                        self.rx[self.rx_head % rx_size] = c;
                        self.rx_head +%= 1;
                        got = true;
                    }
                }
                if (self.sendBatch()) moved = true;
                if (!moved) {
                    const more = self.tx_head != self.tx_tail;
                    self.state = if (more) .armed else .idle;
                    self.chip.setInterrupts(self.keys, more);
                    self.give(was);
                    break;
                }
                self.give(was);
            }
            if (got) if (self.input_wake) |w| w();
        }

        // Polled again (a panic, no task): what is buffered goes
        // out (the lock may be held by what crashed)
        pub fn toPolled(self: *Self) void {
            if (!self.irq) return;
            self.irq = false;
            self.chip.setInterrupts(false, false);
            while (self.tx_tail != self.tx_head) : (self.tx_tail +%= 1) self.chip.putPolled(self.tx[self.tx_tail % tx_size]);
        }

        // Up to batch bytes into the chip's FIFO; whether any went
        fn sendBatch(self: *Self) bool {
            if (self.room == 0 and self.chip.canSend()) self.room = Chip.fifo_size;
            var n: usize = 0;
            while (n < batch and self.room > 0 and self.tx_tail != self.tx_head) : (n += 1) {
                self.chip.send(self.tx[self.tx_tail % tx_size]);
                self.tx_tail +%= 1;
                self.room -= 1;
            }
            return n > 0;
        }

        fn take(self: *Self) usize {
            const was = if (platform.has_switching) platform.switching.disable() else 0;
            while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
            return was;
        }

        fn give(self: *Self, was: usize) void {
            self.lock.store(false, .release);
            if (platform.has_switching) platform.switching.restore(was);
        }
    };
}
