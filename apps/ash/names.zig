// For which, type and Tab completion.
pub const builtins = [_][]const u8{
    ".",      ":",     "[",     "awk",      "basename", "break",   "cat",  "cd",
    "chmod",  "chown", "clear", "command",  "continue", "copy",    "cp",   "cut",
    "date",   "del",   "df",    "diff",     "dir",      "dirname", "echo", "env",
    "eval",   "exec",  "exit",  "export",   "false",    "find",    "grep", "head",
    "help",   "list",  "local", "ls",       "mkdir",    "move",    "mv",   "patch",
    "printf", "pwd",   "read",  "readonly", "remove",   "return",  "rm",   "rmdir",
    "sed",    "set",   "shift", "sleep",    "sort",     "source",  "tail", "test",
    "touch",  "trap",  "true",  "type",     "uniq",     "unset",   "wait", "wc",
    "where",  "which", "xargs", "xxd",
};

pub fn isBuiltin(name: []const u8) bool {
    for (builtins) |b| {
        if (@import("std").mem.eql(u8, b, name)) return true;
    }
    return false;
}
