// ZC.CFG in HOME: made from default_text on the first start.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const frames = @import("frames.zig");
const theme = @import("theme.zig");

const default_text =
    \\; ZC settings
    \\; viewer: internal, or a command (%f: the file)
    \\; frames: auto, double, single or ascii
    \\; humansize: sizes in KB, MB, GB from 1 KB on
    \\; theme: blue or dark
    \\; textfiles: extensions Enter opens in the viewer (commas
    \\; or spaces between them)
    \\[options]
    \\viewer=internal
    \\editor=KILO %f
    \\frames=auto
    \\humansize=true
    \\theme=blue
    \\textfiles=TXT,CFG,INI,LOG,MD
    \\
    \\; Enter on a file: extensions=command (%f: the file)
    \\[open]
    \\BMP,GIF,PNG,JPG,JPEG=PICTVIEW %f
    \\WAV,MID=PLAY %f
    \\ZIP=ZIP X %f
    \\TAR,TGZ,GZ,TXZ,XZ=TAR X %f
    \\
    \\; F2: title=command, run in the panel's folder
    \\; (%f: the file at the cursor)
    \\[menu]
    \\Memory=MEM
    \\Drives=DRIVES
    \\Tasks=TOP
    \\Pack into a ZIP=ZIP C %f
    \\
;

pub var viewer: []const u8 = "internal";
pub var editor: []const u8 = "KILO %f";
pub var style: ?frames.Style = null; // null: auto
pub var human_size = true;
pub var text_files: []const u8 = "TXT,CFG,INI,LOG,MD";

pub fn internalViewer() bool {
    return std.ascii.eqlIgnoreCase(viewer, "internal");
}

const Open = struct { exts: []const u8, command: []const u8 };
var opens: [64]Open = undefined;
var open_count: usize = 0;

// F2's entries:
var menu_titles: [64][]const u8 = undefined;
var menu_commands: [64][]const u8 = undefined;
var menu_count: usize = 0;

pub fn menuTitles() []const []const u8 {
    return menu_titles[0..menu_count];
}

pub fn menuCommand(i: usize) []const u8 {
    return menu_commands[i];
}

const max_size = 16 * 1024;

// Where ZC.CFG is (empty without HOME):
pub var cfg_path: []const u8 = "";
var file_buf: [600]u8 = undefined;

pub fn load() void {
    const path_buf = &file_buf;
    var home_buf: [512]u8 = undefined;
    const home = zdos.getVar("HOME", &home_buf) orelse return parse(default_text);
    const sep = if (std.mem.endsWith(u8, home, "\\") or std.mem.endsWith(u8, home, "/")) "" else "\\";
    const path = std.fmt.bufPrint(path_buf, "{s}{s}ZC.CFG", .{ home, sep }) catch return parse(default_text);
    cfg_path = path;
    const f = zdos.open(path, .read) catch |err| {
        if (err == error.NotFound) create(path);
        return parse(default_text);
    };
    defer f.close();
    // Kept: the settings point into it:
    const buf = zdos.allocator.alloc(u8, max_size) catch return parse(default_text);
    var n: usize = 0;
    while (n < buf.len) {
        const got = f.read(buf[n..]) catch break;
        if (got == 0) break;
        n += got;
    }
    parse(buf[0..n]);
}

fn create(path: []const u8) void {
    const f = zdos.open(path, .write) catch return;
    defer f.close();
    f.writeAll(default_text) catch {};
}

fn parse(text: []const u8) void {
    var section: enum { none, options, open, menu } = .none;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == ';' or line[0] == '#') continue;
        if (line[0] == '[') {
            const name = std.mem.trim(u8, line[1 .. std.mem.indexOfScalar(u8, line, ']') orelse line.len], " \t");
            section = if (std.ascii.eqlIgnoreCase(name, "options"))
                .options
            else if (std.ascii.eqlIgnoreCase(name, "open"))
                .open
            else if (std.ascii.eqlIgnoreCase(name, "menu"))
                .menu
            else
                .none;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        switch (section) {
            .options => {
                if (std.ascii.eqlIgnoreCase(key, "viewer")) viewer = value;
                if (std.ascii.eqlIgnoreCase(key, "editor")) editor = value;
                if (std.ascii.eqlIgnoreCase(key, "frames")) style = frames.parse(value);
                if (std.ascii.eqlIgnoreCase(key, "humansize")) human_size = yes(value);
                if (std.ascii.eqlIgnoreCase(key, "textfiles")) text_files = value;
                if (std.ascii.eqlIgnoreCase(key, "theme")) theme.now = theme.parse(value) orelse theme.blue;
            },
            .open => if (open_count < opens.len and value.len > 0) {
                opens[open_count] = .{ .exts = key, .command = value };
                open_count += 1;
            },
            .menu => if (menu_count < menu_titles.len and key.len > 0 and value.len > 0) {
                menu_titles[menu_count] = key;
                menu_commands[menu_count] = value;
                menu_count += 1;
            },
            .none => {},
        }
    }
}

fn yes(value: []const u8) bool {
    for ([_][]const u8{ "true", "yes", "on", "1" }) |w| {
        if (std.ascii.eqlIgnoreCase(value, w)) return true;
    }
    return false;
}

// "123", or from 1 KB on "1.5 KB", "12 MB" (humansize):
pub fn sizeText(n: u64, buf: []u8) []const u8 {
    if (!human_size or n < 1024) return std.fmt.bufPrint(buf, "{d}", .{n}) catch "";
    const units = [_][]const u8{ "KB", "MB", "GB", "TB", "PB" };
    var unit: usize = 0;
    var div: u64 = 1024;
    while (unit + 1 < units.len and n / div >= 1024) : (unit += 1) div *= 1024;
    const whole = n / div;
    if (whole < 10) {
        const tenth = n % div * 10 / div;
        return std.fmt.bufPrint(buf, "{d}.{d} {s}", .{ whole, tenth, units[unit] }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d} {s}", .{ whole, units[unit] }) catch "";
}

// Whether Enter views name (textfiles=):
pub fn isText(name: []const u8) bool {
    const ext = extension(name) orelse return false;
    var words = std.mem.tokenizeAny(u8, text_files, " \t,");
    while (words.next()) |w| {
        if (std.ascii.eqlIgnoreCase(w, ext)) return true;
    }
    return false;
}

// The command for name's extension:
pub fn commandFor(name: []const u8) ?[]const u8 {
    const ext = extension(name) orelse return null;
    for (opens[0..open_count]) |o| {
        var words = std.mem.tokenizeAny(u8, o.exts, " \t,");
        while (words.next()) |w| {
            if (std.ascii.eqlIgnoreCase(w, ext)) return o.command;
        }
    }
    return null;
}

pub fn extension(name: []const u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    if (dot == 0) return null;
    return name[dot + 1 ..];
}

pub fn hasFile(template: []const u8) bool {
    return std.mem.indexOf(u8, template, "%f") != null or std.mem.indexOf(u8, template, "%F") != null;
}

// template with %f as the file, quoted when it has spaces;
// without %f the file comes last:
pub fn expand(template: []const u8, file: []const u8, buf: []u8) ?[]const u8 {
    var quoted_buf: [800]u8 = undefined;
    const q = if (std.mem.indexOfAny(u8, file, " \t") != null)
        std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{file}) catch return null
    else
        file;
    var n: usize = 0;
    var used = false;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '%' and i + 1 < template.len and (template[i + 1] == 'f' or template[i + 1] == 'F')) {
            if (n + q.len > buf.len) return null;
            @memcpy(buf[n..][0..q.len], q);
            n += q.len;
            i += 2;
            used = true;
            continue;
        }
        if (n == buf.len) return null;
        buf[n] = template[i];
        n += 1;
        i += 1;
    }
    if (!used) {
        if (n + 1 + q.len > buf.len) return null;
        buf[n] = ' ';
        @memcpy(buf[n + 1 ..][0..q.len], q);
        n += 1 + q.len;
    }
    return buf[0..n];
}
