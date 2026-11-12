const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const path_list = @import("../command/path_list.zig");

pub const Completion = struct {
    start: usize,
    text: []const u8,
};

const commands = @import("names.zig").builtins;

var completed: [2048]u8 = undefined;
var unquoted: [2048]u8 = undefined;
var quoted: [2048]u8 = undefined;
var best_name: [768]u8 = undefined;

pub fn complete(before: []const u8) ?Completion {
    const word_start = currentWordStart(before);
    const raw = before[word_start..];
    if (std.mem.indexOfScalar(u8, raw, '\'') != null) return null;
    const is_quoted = std.mem.indexOfScalar(u8, raw, '"') != null;
    const typed = if (is_quoted) removeDoubleQuotes(raw) orelse return null else raw;
    if (typed.len > 0 and typed[0] == '-') return null;

    const in_command_position = std.mem.trim(u8, before[commandSegmentStart(before)..word_start], " \t").len == 0;
    if (in_command_position and !is_quoted) {
        if (completeCommand(typed)) |text| return .{ .start = word_start, .text = text };
    }
    if (completePath(typed, in_command_position)) |text| {
        return .{ .start = word_start, .text = if (is_quoted) quotePath(text) orelse return null else text };
    }
    return null;
}

fn currentWordStart(before: []const u8) usize {
    var start: usize = 0;
    var quote: u8 = 0;
    for (before, 0..) |byte, index| {
        if ((byte == '\'' or byte == '"') and (quote == 0 or quote == byte)) {
            quote = if (quote == 0) byte else 0;
            continue;
        }
        if (quote == 0 and (std.ascii.isWhitespace(byte) or isOperator(byte))) start = index + 1;
    }
    return start;
}

fn commandSegmentStart(before: []const u8) usize {
    var start: usize = 0;
    var quote: u8 = 0;
    for (before, 0..) |byte, index| {
        if ((byte == '\'' or byte == '"') and (quote == 0 or quote == byte)) {
            quote = if (quote == 0) byte else 0;
        } else if (quote == 0 and (byte == ';' or byte == '|' or byte == '&' or byte == '\n')) {
            start = index + 1;
        }
    }
    return start;
}

fn isOperator(byte: u8) bool {
    return byte == ';' or byte == '|' or byte == '&' or byte == '<' or byte == '>';
}

fn removeDoubleQuotes(text: []const u8) ?[]const u8 {
    if (text.len > unquoted.len) return null;
    var length: usize = 0;
    for (text) |byte| {
        if (byte == '"') continue;
        unquoted[length] = byte;
        length += 1;
    }
    return unquoted[0..length];
}

fn quotePath(path: []const u8) ?[]const u8 {
    if (std.mem.indexOfAny(u8, path, " \t") == null) return path;
    const directory = path.len > 0 and path[path.len - 1] == '/';
    const body_len = path.len - @intFromBool(directory);
    if (body_len + 3 + @intFromBool(directory) > quoted.len) return null;
    quoted[0] = '"';
    @memcpy(quoted[1 .. body_len + 1], path[0..body_len]);
    quoted[body_len + 1] = '"';
    var length = body_len + 2;
    if (directory) {
        quoted[length] = '/';
        length += 1;
    }
    return quoted[0..length];
}

fn completeCommand(prefix: []const u8) ?[]const u8 {
    if (prefix.len == 0) return null;
    for (commands) |command| {
        if (startsWithIgnoreCase(command, prefix)) return command;
    }
    if (completePath(prefix, true)) |text| return text;

    var path_buffer: [1024]u8 = undefined;
    const path = zdos.getVar("PATH", &path_buffer) orelse return null;
    var directories = path_list.Iterator{ .value = path };
    while (directories.next()) |directory| {
        const trimmed = std.mem.trim(u8, directory, " \t");
        if (trimmed.len == 0) continue;
        if (completeProgramIn(trimmed, prefix)) |text| return text;
    }
    return null;
}

fn completePath(typed: []const u8, programs_only: bool) ?[]const u8 {
    var cut = typed.len;
    while (cut > 0 and typed[cut - 1] != '/' and typed[cut - 1] != '\\') cut -= 1;
    // A drive is one letter: "C:name", not "id:01":
    if (cut == 0 and typed.len >= 2 and typed[1] == ':' and std.ascii.isAlphabetic(typed[0])) cut = 2;
    const directory = if (cut == 0) "." else typed[0..cut];
    const prefix = typed[cut..];
    const match = bestMatch(directory, prefix, programs_only) orelse return null;
    if (cut + match.len + @intFromBool(match.is_dir) > completed.len) return null;
    @memcpy(completed[0..cut], typed[0..cut]);
    @memcpy(completed[cut..][0..match.len], best_name[0..match.len]);
    var length = cut + match.len;
    if (match.is_dir) {
        completed[length] = '/';
        length += 1;
    }
    return completed[0..length];
}

const Match = struct {
    len: usize,
    is_dir: bool,
};

fn bestMatch(directory: []const u8, prefix: []const u8, programs_only: bool) ?Match {
    const dir = zdos.openDir(directory) catch return null;
    var best_len: usize = 0;
    var best_is_dir = false;
    var entry: zdos.DirEntry = undefined;
    while (dir.next(&entry)) |has_entry| {
        if (!has_entry) break;
        const name = entry.name();
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (!startsWithIgnoreCase(name, prefix)) continue;
        if (programs_only and !entry.is_dir and !isProgram(name)) continue;
        if (best_len > 0 and std.ascii.orderIgnoreCase(name, best_name[0..best_len]) != .lt) continue;
        if (name.len > best_name.len) continue;
        @memcpy(best_name[0..name.len], name);
        best_len = name.len;
        best_is_dir = entry.is_dir;
    } else |_| {
        dir.close();
        return null;
    }
    dir.close();
    if (best_len == 0) return null;
    return .{ .len = best_len, .is_dir = best_is_dir };
}

fn completeProgramIn(directory: []const u8, prefix: []const u8) ?[]const u8 {
    const match = bestMatch(directory, prefix, true) orelse return null;
    @memcpy(completed[0..match.len], best_name[0..match.len]);
    return completed[0..match.len];
}

fn isProgram(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".APP") or
        std.ascii.endsWithIgnoreCase(name, ".CMD") or
        std.ascii.endsWithIgnoreCase(name, ".BAT") or
        std.ascii.endsWithIgnoreCase(name, ".EXE") or
        std.ascii.endsWithIgnoreCase(name, ".SH");
}

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}
