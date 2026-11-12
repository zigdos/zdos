// Tab completion: the alphabetically first match, no alternatives.
const std = @import("std");
const fs = @import("fs.zig");
const path_list = @import("path_list.zig");
const vars = @import("vars.zig");
const shell = @import("shell.zig");

pub const Completion = struct {
    start: usize, // the text from here up to the cursor is replaced...
    text: []const u8, // ...by this
};

var result_buf: [fs.max_path + 4]u8 = undefined; // a name from completeIn
var out_buf: [fs.max_path + 8]u8 = undefined; // the whole completed word

const Word = struct {
    start: usize,
    end: usize,
    quoted: bool = false, // has a '"' in it
    after_redirect: bool = false, // follows < or >: a file name
};

const max_words = 64;

// before: the line up to the cursor.
pub fn complete(before: []const u8) ?Completion {
    // The words of the current command (after the last |), and the one at
    // the cursor (maybe empty):
    var words: [max_words]Word = undefined;
    var count: usize = 0;
    var cur: ?Word = null;
    var redirect = false;
    var quoted = false;
    for (before, 0..) |c, i| {
        if (!quoted and (c == ' ' or c == '\t' or c == '|' or c == '<' or c == '>')) {
            if (cur) |w| {
                if (count == max_words) return null;
                words[count] = w;
                words[count].end = i;
                count += 1;
                cur = null;
            }
            switch (c) {
                '|' => {
                    count = 0; // a new command
                    redirect = false;
                },
                '<', '>' => redirect = true,
                else => {},
            }
            continue;
        }
        if (cur == null) {
            cur = .{ .start = i, .end = i, .after_redirect = redirect };
            redirect = false;
        }
        if (c == '"') {
            quoted = !quoted;
            cur.?.quoted = true;
        }
    }
    var w = cur orelse Word{ .start = before.len, .end = before.len, .after_redirect = redirect };
    w.end = before.len;
    const typed = before[w.start..];

    if (count == 0 and !w.after_redirect) return commandWord(w.start, typed);

    if (typed.len > 0 and typed[0] == '-') return null; // a switch
    const filter: Filter = if (w.after_redirect or count == 0) .any else if (dirsOnly(before[words[0].start..words[0].end])) .dirs else .any;

    // Unquoted names with spaces: the longest run of plain words before
    // the cursor first ("cd My Fo"), down to the last word alone:
    if (!w.quoted and !w.after_redirect) {
        var first = count;
        while (first > 1) {
            const p = words[first - 1];
            const text = before[p.start..p.end];
            if (p.quoted or p.after_redirect or text[0] == '-') break;
            first -= 1;
        }
        var j = first;
        while (j < count) : (j += 1) {
            if (completeWord(before[words[j].start..], filter)) |text| return .{ .start = words[j].start, .text = text };
        }
    }
    const text = completeWord(typed, filter) orelse return null;
    return .{ .start = w.start, .text = text };
}

// CD, MD, RD and their other names take folders only.
fn dirsOnly(command_word: []const u8) bool {
    for ([_][]const u8{ "CD", "CHDIR", "MD", "MKDIR", "RD", "RMDIR" }) |name| {
        if (std.ascii.eqlIgnoreCase(command_word, name)) return true;
    }
    return false;
}

fn commandWord(start: usize, typed: []const u8) ?Completion {
    if (typed.len == 0) return null;
    var buf: fs.TypedBuf = undefined;
    const word = unquoted(typed, &buf);
    const has_quotes = word.len != typed.len;
    // A built-in: a plain word, no quotes, drive or folder:
    if (!has_quotes and std.mem.indexOfAny(u8, word, ":\\/") == null) {
        if (command(word)) |text| return .{ .start = start, .text = text };
    }
    if (completePath(word, .programs_and_dirs)) |text| return .{ .start = start, .text = text };
    if (std.mem.indexOfAny(u8, word, ":\\/") == null) {
        var path_buf: vars.Buf = undefined;
        var it: path_list.Iterator = .{ .value = vars.get("PATH", &path_buf) orelse "" };
        while (it.next()) |dir| {
            const d = std.mem.trim(u8, dir, " \t");
            if (d.len == 0) continue;
            if (completeIn(d, word, .programs)) |name| return .{ .start = start, .text = quote(name) };
        }
    }
    return null;
}

// In the letter case the user typed.
fn command(word: []const u8) ?[]const u8 {
    const lower = for (word) |ch| {
        if (std.ascii.isLower(ch)) break true;
    } else false;
    for (shell.command_names) |name| {
        if (name.len < word.len or !std.ascii.eqlIgnoreCase(name[0..word.len], word)) continue;
        const out = out_buf[0..name.len];
        if (lower) _ = std.ascii.lowerString(out, name) else @memcpy(out, name);
        return out;
    }
    return null;
}

const Filter = enum { any, dirs, programs_and_dirs, programs };

// Quotes allowed anywhere; the new word is quoted if it has a blank.
fn completeWord(typed: []const u8, filter: Filter) ?[]const u8 {
    var buf: fs.TypedBuf = undefined;
    return completePath(unquoted(typed, &buf), filter);
}

fn completePath(typed: []const u8, filter: Filter) ?[]const u8 {
    var cut = typed.len;
    while (cut > 0 and typed[cut - 1] != '\\' and typed[cut - 1] != '/') cut -= 1;
    // A drive is one letter: "C:name", not "id:01":
    if (cut == 0 and typed.len >= 2 and typed[1] == ':' and std.ascii.isAlphabetic(typed[0])) cut = 2;
    const name = completeIn(typed[0..cut], typed[cut..], filter) orelse return null;
    // The folder part as typed, then the completed name:
    var full: [fs.max_path + 4]u8 = undefined;
    if (cut + name.len > full.len) return null;
    @memcpy(full[0..cut], typed[0..cut]);
    @memcpy(full[cut..][0..name.len], name);
    return quote(full[0 .. cut + name.len]);
}

// A final '\' stays outside the quotes ("My Folder"\), so typing can go
// on after it.
fn quote(path: []const u8) []const u8 {
    if (std.mem.indexOfAny(u8, path, " \t") == null) {
        if (path.len > out_buf.len) return path;
        std.mem.copyForwards(u8, out_buf[0..path.len], path);
        return out_buf[0..path.len];
    }
    const dir = path.len > 0 and path[path.len - 1] == '\\';
    const body = if (dir) path[0 .. path.len - 1] else path;
    if (body.len + 3 > out_buf.len) return path;
    var tmp: [fs.max_path + 4]u8 = undefined;
    @memcpy(tmp[0..body.len], body);
    out_buf[0] = '"';
    @memcpy(out_buf[1..][0..body.len], tmp[0..body.len]);
    out_buf[body.len + 1] = '"';
    var n = body.len + 2;
    if (dir) {
        out_buf[n] = '\\';
        n += 1;
    }
    return out_buf[0..n];
}

// The commands remove them too.
fn unquoted(word: []const u8, buf: *fs.TypedBuf) []const u8 {
    if (std.mem.indexOfScalar(u8, word, '"') == null) return word;
    var n: usize = 0;
    for (word) |c| {
        if (c == '"') continue;
        if (n == buf.len) break;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

// dir: "", "DOCS\", "D:", "C:\APPS". Ignoring case; a '\' is added for folders.
fn completeIn(dir: []const u8, prefix: []const u8, filter: Filter) ?[]const u8 {
    const p = fs.resolveDir(dir) catch return null;
    var it = fs.openDir(&p) catch return null;
    defer it.close();
    var best: ?[]const u8 = null; // name part of result_buf, without the '\'
    var best_len: usize = 0; // with it
    while (it.next() catch null) |e| {
        const name = e.name();
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (name.len < prefix.len or !std.ascii.eqlIgnoreCase(name[0..prefix.len], prefix)) continue;
        const is_program = !e.is_dir and (std.ascii.endsWithIgnoreCase(name, ".APP") or
            std.ascii.endsWithIgnoreCase(name, ".CMD") or std.ascii.endsWithIgnoreCase(name, ".BAT"));
        switch (filter) {
            .any => {},
            .dirs => if (!e.is_dir) continue,
            .programs_and_dirs => if (!e.is_dir and !is_program) continue,
            .programs => if (!is_program) continue,
        }
        if (best) |b| {
            if (std.ascii.orderIgnoreCase(name, b) != .lt) continue;
        }
        const suffix: []const u8 = if (e.is_dir) "\\" else "";
        const out = std.fmt.bufPrint(&result_buf, "{s}{s}", .{ name, suffix }) catch continue;
        best = result_buf[0..name.len];
        best_len = out.len;
    }
    return if (best != null) result_buf[0..best_len] else null;
}
