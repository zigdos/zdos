// KILL [-SIGNAL | -s SIGNAL] TASK... | -l: sends a signal
// TASK as PS shows it. Exit code 0 if every signal went out.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const system = @import("zdos/system.zig");

comptime {
    _ = zdos;
}

const Named = struct { name: []const u8, number: u32 };

const signals = [_]Named{
    .{ .name = "HUP", .number = 1 },   .{ .name = "INT", .number = 2 },
    .{ .name = "QUIT", .number = 3 },  .{ .name = "ILL", .number = 4 },
    .{ .name = "TRAP", .number = 5 },  .{ .name = "ABRT", .number = 6 },
    .{ .name = "BUS", .number = 7 },   .{ .name = "FPE", .number = 8 },
    .{ .name = "KILL", .number = 9 },  .{ .name = "USR1", .number = 10 },
    .{ .name = "SEGV", .number = 11 }, .{ .name = "USR2", .number = 12 },
    .{ .name = "PIPE", .number = 13 }, .{ .name = "ALRM", .number = 14 },
    .{ .name = "TERM", .number = 15 }, .{ .name = "CHLD", .number = 17 },
    .{ .name = "CONT", .number = 18 }, .{ .name = "STOP", .number = 19 },
    .{ .name = "TSTP", .number = 20 }, .{ .name = "TTIN", .number = 21 },
    .{ .name = "TTOU", .number = 22 }, .{ .name = "URG", .number = 23 },
    .{ .name = "WINCH", .number = 28 },
};

fn usage() u8 {
    zdos.print("KILL [-SIGNAL | -s SIGNAL] TASK...   (default TERM)\nKILL -l   lists the signals\n");
    return 1;
}

// With or without SIG, in any case.
fn parseSignal(text: []const u8) ?u32 {
    if (std.fmt.parseInt(u32, text, 10)) |n| {
        return if (n < 64) n else null;
    } else |_| {}
    var name = text;
    if (name.len > 3 and std.ascii.eqlIgnoreCase(name[0..3], "SIG")) name = name[3..];
    for (signals) |s| {
        if (std.ascii.eqlIgnoreCase(s.name, name)) return s.number;
    }
    return null;
}

pub fn main(args: []const u8) u8 {
    var words = std.mem.tokenizeAny(u8, args, " \t");
    var sig: u32 = zdos.Signal.term;
    var first = words.next() orelse return usage();
    if (std.mem.eql(u8, first, "-l") or std.mem.eql(u8, first, "-L")) {
        for (signals) |s| zdos.printf("{d:>2} {s}\n", .{ s.number, s.name });
        return 0;
    }
    if (std.mem.eql(u8, first, "-s") or std.mem.eql(u8, first, "-S")) {
        const name = words.next() orelse return usage();
        sig = parseSignal(name) orelse {
            zdos.printf("KILL: unknown signal {s}\n", .{name});
            return 1;
        };
        first = words.next() orelse return usage();
    } else if (first.len > 1 and first[0] == '-') {
        sig = parseSignal(first[1..]) orelse {
            zdos.printf("KILL: unknown signal {s}\n", .{first[1..]});
            return 1;
        };
        first = words.next() orelse return usage();
    }
    var failed = false;
    var next: ?[]const u8 = first;
    while (next) |word| : (next = words.next()) {
        const id = std.fmt.parseInt(u32, word, 10) catch {
            zdos.printf("KILL: {s} is not a task number\n", .{word});
            failed = true;
            continue;
        };
        system.signalSend(id, sig) catch |err| {
            failed = true;
            switch (err) {
                error.NotFound => zdos.printf("KILL: no task {d}\n", .{id}),
                else => zdos.printf("KILL: task {d}: {s}\n", .{ id, zdos.message(err) }),
            }
        };
    }
    return if (failed) 1 else 0;
}
