// COMMAND.APP: the ZDOS command interpreter; sources in apps/command/.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");
const shell = @import("command/shell.zig");
const batch = @import("command/batch.zig");
const vars = @import("command/vars.zig");
const term = @import("command/term.zig");

comptime {
    _ = zdos;
}

pub fn main(args: []const u8) u8 {
    // Ctrl+C stops commands and batch files, not the interpreter:
    sys.catchCtrlC(true);
    term.clearBreak();

    var permanent = false;
    var login = false;
    var autoexec = true;
    var rest = std.mem.trim(u8, args, " \t");
    while (rest.len >= 2 and rest[0] == '-') {
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const word = rest[0..end];
        const is = std.ascii.eqlIgnoreCase;
        if (is(word, "-c")) {
            batch.runPromptLine(std.mem.trim(u8, rest[end..], " \t"));
            return shell.exitCode() orelse vars.errorlevel;
        } else if (is(word, "-p")) {
            permanent = true;
        } else if (is(word, "-l")) {
            login = true;
        } else if (is(word, "-a")) {
            // AUTOEXEC.CMD alone (LOGIN.APP, at startup, as root):
            batch.runAutoexec();
            return vars.errorlevel;
        } else if (is(word, "-d")) {
            autoexec = false;
        } else {
            zdos.print("Invalid switch - ");
            zdos.print(word);
            zdos.print("\nCOMMAND [-p | -l] [-d] [-c line] [-a]\n");
            return 1;
        }
        rest = std.mem.trim(u8, rest[end..], " \t");
    }
    return shell.interactive(if (permanent) .permanent else if (login) .login else .secondary, autoexec);
}
