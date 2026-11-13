// ZC [FOLDER]: a two-panel file manager; sources in apps/zc/.
// Files open with the programs ZC.CFG in HOME names.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const screen = @import("zc/screen.zig");
const frames = @import("zc/frames.zig");
const config = @import("zc/config.zig");
const panel = @import("zc/panel.zig");
const dialog = @import("zc/dialog.zig");
const edit = @import("zc/edit.zig");
const ops = @import("zc/ops.zig");
const viewer = @import("zc/viewer.zig");
const theme = @import("zc/theme.zig");

comptime {
    _ = zdos;
}

const Scan = zdos.Scan;
const Color = screen.Color;
const Panel = panel.Panel;

var panels: [2]Panel = .{ .{}, .{} };
var active: usize = 0;
var cmd: edit.Line = .{};
var set: frames.Set = undefined;

const executables = [_][]const u8{ "APP", "CMD", "BAT", "EXE", "SH" };
const archives = [_][]const u8{ "ZIP", "TAR", "GZ", "TGZ", "7Z" };

pub fn main(args: []const u8) u8 {
    config.load();
    set = frames.of(config.style orelse frames.detect());
    dialog.set = set;
    dialog.redraw = drawAll;

    var start_buf: [panel.max_path]u8 = undefined;
    const word = std.mem.trim(u8, args, " \t\"");
    const start = if (word.len > 0)
        zdos.fullPath(word, &start_buf) catch zdos.getCwd(&start_buf)
    else
        zdos.getCwd(&start_buf);
    for (&panels) |*p| {
        _ = p.setPath(start);
        p.load(null);
    }

    zdos.setCtrlC(true);
    enterScreen();
    defer leaveScreen();
    while (true) {
        if (!screen.resize()) {
            leaveScreen();
            zdos.printError("ZC: not enough memory\n");
            return 1;
        }
        const caret = draw();
        screen.flush();
        zdos.setCursor(caret, screen.rows -| 2);
        zdos.showCursor(true);
        const k = zdos.readKey();
        if (k.scan == Scan.redraw) {
            screen.invalidate();
            continue;
        }
        if (!handle(k)) break;
    }
    return 0;
}

// The alternate screen keeps the one before; colors and
// cursor as they were afterwards:
fn enterScreen() void {
    zdos.print("\x1b[?1049h");
    zdos.setColor(.light_gray, .black);
    zdos.clearScreen();
    screen.invalidate();
}

fn leaveScreen() void {
    zdos.print("\x1b[0m");
    zdos.setColor(.light_gray, .black);
    zdos.print("\x1b[?1049l");
    zdos.showCursor(true);
}

// KEYS

// False: quit.
// Shift+Up, Shift+Down: the state they give the entries
// passed, from the first one's (null: no such run)
var shift_mark: ?bool = null;

fn handle(k: zdos.Key) bool {
    // Shift alone, as before Shift+Down, keeps the run:
    if (edit.isModifierOnly(k)) return true;
    const p = &panels[active];
    const shift_move = k.shift() and (k.scan == Scan.up or k.scan == Scan.down);
    if (!shift_move) shift_mark = null;
    const page: isize = @intCast(@max(listHeight(), 2) - 1);
    if (edit.fkey(k)) |f| {
        if (k.alt()) {
            if (f == 1 or f == 2) changeDrive(&panels[f - 1]);
            return true;
        }
        switch (f) {
            1 => showHelp(),
            2 => userMenu(),
            3 => viewCurrent(),
            4 => openWith(config.editor),
            5 => ops.copyOrMove(p, &panels[1 - active], false),
            6 => ops.copyOrMove(p, &panels[1 - active], true),
            7 => ops.makeFolder(p),
            8 => ops.delete(p),
            9 => sortMenu(p),
            10 => return !dialog.confirm("Quit", &.{"Leave ZC?"}, false),
            else => {},
        }
        return true;
    }
    if (k.alt() and !k.ctrl() and k.char > ' ' and k.char != 127) {
        if (quickSearch(k.char)) |next| return handle(next);
        return true;
    }
    if (edit.ctrlLetter(k)) |c| {
        switch (c) {
            'o' => if (commandScreen()) |fk| return handle(fk),
            'r' => for (&panels) |*q| q.load(null),
            's' => if (quickSearch(null)) |next| return handle(next),
            else => {},
        }
        return true;
    }
    if (edit.isEnter(k)) {
        if (cmd.len > 0) runCommandLine() else openCurrent();
        return true;
    }
    if (edit.isEsc(k)) {
        cmd.clear();
        return true;
    }
    if (k.char == '\t') {
        active = 1 - active;
        return true;
    }
    const typing = cmd.len > 0;
    switch (k.scan) {
        Scan.up => if (shift_move) markAndMove(p, -1) else p.move(-1),
        Scan.down => if (shift_move) markAndMove(p, 1) else p.move(1),
        Scan.page_up => if (k.ctrl()) p.up() else p.move(-page),
        Scan.page_down => if (k.ctrl()) openDir() else p.move(page),
        Scan.home => if (typing) {
            _ = cmd.key(k);
        } else p.move(-std.math.maxInt(i32)),
        Scan.end => if (typing) {
            _ = cmd.key(k);
        } else p.move(std.math.maxInt(i32)),
        Scan.insert => if (p.current()) |e| {
            if (!e.up) e.selected = !e.selected;
            p.move(1);
        },
        else => _ = cmd.key(k),
    }
    return true;
}

// The cursor to the first name starting with what is typed,
// case ignored; a character no name goes on with isn't
// taken. Esc ends it; another key ends it and is returned.
fn quickSearch(first: ?u16) ?zdos.Key {
    const p = &panels[active];
    var text: [128]u8 = undefined;
    var len: usize = 0;
    var next: ?u16 = first;
    while (true) {
        if (next) |c| {
            next = null;
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &enc) catch 0;
            if (n > 0 and len + n <= text.len) {
                @memcpy(text[len..][0..n], enc[0..n]);
                if (findPrefix(p, text[0 .. len + n])) |i| {
                    p.cursor = i;
                    len += n;
                }
            }
        }
        _ = draw();
        const box_x = drawSearch(text[0..len]);
        screen.flush();
        zdos.setCursor(box_x, screen.rows -| 3);
        zdos.showCursor(true);
        const k = zdos.readKey();
        if (k.scan == Scan.redraw) {
            screen.invalidate();
            continue;
        }
        if (edit.isEsc(k)) return null;
        // Shift for a capital comes alone first:
        if (edit.isModifierOnly(k)) continue;
        if (k.char == 8 and k.scan == 0) {
            if (len > 0) len -= 1;
            while (len > 0 and text[len] & 0xC0 == 0x80) len -= 1;
            continue;
        }
        if (k.char >= ' ' and k.char != 127 and !k.ctrl() and k.scan == 0) {
            next = k.char;
            continue;
        }
        if (k.alt() and k.char > ' ' and k.char != 127) {
            next = k.char;
            continue;
        }
        return k;
    }
}

fn findPrefix(p: *Panel, prefix: []const u8) ?usize {
    for (p.entries.items, 0..) |e, i| {
        if (e.up) continue;
        if (std.ascii.startsWithIgnoreCase(p.name(e), prefix)) return i;
    }
    return null;
}

// The search box over the active panel's bottom frame;
// its caret's column:
fn drawSearch(text: []const u8) u32 {
    const left_w = screen.cols / 2;
    const x0: u32 = if (active == 0) 0 else left_w;
    const pw: u32 = if (active == 0) left_w else screen.cols - left_w;
    const y = screen.rows -| 3;
    const w: u32 = @min(pw -| 4, 30);
    const label = " Search: ";
    const x = x0 + 2;
    _ = screen.text(x, y, label, w, .black, theme.now.accent);
    const lw: u32 = @intCast(label.len);
    const room = w -| lw -| 1;
    const shown = tail(text, room);
    const tw = screen.text(x + lw, y, shown, room, .black, theme.now.accent);
    screen.put(x + w - 1, y, ' ', .black, theme.now.accent);
    return x + lw + tw;
}

fn markAndMove(p: *Panel, delta: isize) void {
    if (p.current()) |e| {
        if (!e.up) {
            if (shift_mark == null) shift_mark = !e.selected;
            e.selected = shift_mark.?;
        }
    }
    p.move(delta);
}

fn openDir() void {
    const p = &panels[active];
    const e = p.current() orelse return;
    if (e.up) return p.up();
    if (e.is_dir) p.into(p.name(e.*));
}

const help_lines = [_][]const u8{
    "F1           this help",
    "F2           menu: commands from [menu] in ZC.CFG",
    "F3           view the file",
    "F4           edit the file",
    "F5           copy",
    "F6           rename or move",
    "F7           make a folder",
    "F8           delete",
    "F9           sort by name, size or time",
    "F10          quit",
    "Enter        open: folder, program, [open], textfiles=",
    "Tab          switch panel",
    "Insert       select or unselect",
    "Shift+Up/Dn  select while moving",
    "Ctrl+PgUp    the folder above",
    "Ctrl+PgDn    into the folder",
    "Alt+F1, F2   the left, right panel's drive",
    "Ctrl+O       hide or show the panels",
    "Ctrl+R       read the folders again",
    "Esc          clear the command line",
    "Alt+letter   quick search (also Ctrl+S)",
};

// The key list, a blank line and where ZC.CFG is:
fn showHelp() void {
    var lines: [help_lines.len + 2][]const u8 = undefined;
    @memcpy(lines[0..help_lines.len], &help_lines);
    var cfg_buf: [700]u8 = undefined;
    lines[help_lines.len] = "";
    lines[help_lines.len + 1] = if (config.cfg_path.len > 0)
        std.fmt.bufPrint(&cfg_buf, "Settings     {s}", .{config.cfg_path}) catch "Settings     ZC.CFG in HOME"
    else
        "Settings     none: HOME isn't set";
    dialog.help("ZC keys", &lines);
}

// Enter: into a folder, run a program, the ZC.CFG command
// for the extension, or the viewer for textfiles=; other
// files only by F3.
fn openCurrent() void {
    const p = &panels[active];
    const e = p.current() orelse return;
    if (e.is_dir) return openDir();
    const name = p.name(e.*);
    var line_buf: [panel.max_path + 64]u8 = undefined;
    if (hasExtension(name, &executables)) {
        const line = config.expand("", name, &line_buf) orelse return;
        return run(std.mem.trim(u8, line, " "));
    }
    const template = config.commandFor(name) orelse {
        if (config.isText(name)) viewCurrent();
        return;
    };
    run(config.expand(template, name, &line_buf) orelse return);
}

fn viewCurrent() void {
    if (!config.internalViewer()) return openWith(config.viewer);
    const p = &panels[active];
    const e = p.current() orelse return;
    if (e.is_dir) return;
    var buf: [panel.max_path]u8 = undefined;
    viewer.view(p.join(p.name(e.*), &buf) orelse return);
}

// A file at the cursor with the editor or an outside viewer:
fn openWith(template: []const u8) void {
    const p = &panels[active];
    const e = p.current() orelse return;
    if (e.is_dir) return;
    var line_buf: [panel.max_path + 64]u8 = undefined;
    run(config.expand(template, p.name(e.*), &line_buf) orelse return);
}

fn runCommandLine() void {
    var buf: [2048]u8 = undefined;
    const line = std.mem.trim(u8, cmd.utf8(&buf), " \t");
    cmd.clear();
    if (line.len == 0) return;
    if (folderOf(line)) |to| {
        changeFolder(to) catch |err| {
            _ = dialog.message("Error", &.{ to, zdos.message(err) }, true);
        };
        return;
    }
    run(line);
}

// CD's folder or a drive change: they move the panel.
fn folderOf(line: []const u8) ?[]const u8 {
    if (cdArgument(line)) |to| return to;
    return if (isDrive(line)) line else null;
}

fn changeFolder(to: []const u8) zdos.Error!void {
    const p = &panels[active];
    zdos.setCwd(p.path()) catch {};
    try zdos.setCwd(to);
    var cwd_buf: [panel.max_path]u8 = undefined;
    _ = p.setPath(zdos.getCwd(&cwd_buf));
    p.cursor = 0;
    p.top = 0;
    p.load(null);
}

fn cdArgument(line: []const u8) ?[]const u8 {
    for ([_][]const u8{ "cd", "chdir" }) |word| {
        if (line.len > word.len and std.ascii.eqlIgnoreCase(line[0..word.len], word) and (line[word.len] == ' ' or line[word.len] == '\\' or line[word.len] == '.')) {
            const arg = std.mem.trim(u8, line[word.len..], " \t\"");
            return if (arg.len > 0) arg else null;
        }
    }
    return null;
}

fn isDrive(line: []const u8) bool {
    return line.len == 2 and line[1] == ':' and std.ascii.isAlphabetic(line[0]);
}

// On the screen before ZC, then back to the panels:
fn run(line: []const u8) void {
    leaveScreen();
    printPrompt();
    zdos.print(line);
    zdos.print("\n");
    execute(line);
    enterScreen();
}

fn printPrompt() void {
    zdos.print(panels[active].path());
    zdos.print(">");
}

const sort_items = [_][]const u8{
    "Name, A to Z",
    "Name, Z to A",
    "Size, smallest first",
    "Size, largest first",
    "Modify time, oldest first",
    "Modify time, newest first",
};

fn sortMenu(p: *Panel) void {
    const now = @as(usize, @intFromEnum(p.sort_by)) * 2 + @intFromBool(p.descending);
    const i = dialog.menu("Sort", &sort_items, now) orelse return;
    p.sort_by = @enumFromInt(i / 2);
    p.descending = i % 2 == 1;
    p.load(null);
}

// F2: a [menu] command, %f as the file at the cursor:
fn userMenu() void {
    const titles = config.menuTitles();
    if (titles.len == 0) {
        _ = dialog.message("Menu", &.{ "ZC.CFG has no [menu] entries:", "title=command, one a line" }, false);
        return;
    }
    const i = dialog.menu("Menu", titles, 0) orelse return;
    const template = config.menuCommand(i);
    if (!config.hasFile(template)) return run(template);
    const p = &panels[active];
    const e = p.current() orelse return;
    if (e.up) {
        _ = dialog.message("Menu", &.{ titles[i], "needs a file at the cursor" }, true);
        return;
    }
    var line_buf: [panel.max_path + 256]u8 = undefined;
    run(config.expand(template, p.name(e.*), &line_buf) orelse return);
}

// In the active panel's folder:
fn execute(line: []const u8) void {
    zdos.setCwd(panels[active].path()) catch {};
    zdos.setCtrlC(false);
    _ = zdos.runCommand(line) catch |err| {
        zdos.print(zdos.message(err));
        zdos.print("\n");
    };
    zdos.setCtrlC(true);
    for (&panels) |*q| q.load(null);
}

// Ctrl+O: the screen before ZC, with the command line and
// the key bar at its bottom. Ctrl+O shows the panels again;
// an F key shows them and is theirs (returned).
fn commandScreen() ?zdos.Key {
    leaveScreen();
    defer enterScreen();
    var row = settle();
    while (true) {
        if (!screen.resize()) return null;
        drawKeys(screen.rows - 1);
        screen.writeRow(screen.rows - 1);
        const caret = drawUserLine(row);
        zdos.setCursor(caret, row);
        const k = zdos.readKey();
        if (k.scan == Scan.redraw) continue;
        if (edit.ctrlLetter(k) == 'o') {
            clearBottom(row);
            return null;
        }
        if (edit.fkey(k) != null) {
            clearBottom(row);
            return k;
        }
        if (edit.isEsc(k)) {
            cmd.clear();
            continue;
        }
        if (!edit.isEnter(k)) {
            _ = cmd.key(k);
            continue;
        }
        var buf: [2048]u8 = undefined;
        const text = std.mem.trim(u8, cmd.utf8(&buf), " \t");
        cmd.clear();
        if (text.len == 0) continue;
        // The line as typed, the output under it:
        clearBottom(row);
        printPrompt();
        zdos.print(text);
        zdos.print("\n");
        if (folderOf(text)) |to| {
            changeFolder(to) catch |err| {
                zdos.print(zdos.message(err));
                zdos.print("\n");
            };
        } else execute(text);
        row = settle();
    }
}

// The command line's row: the next empty one, the last
// but one at most (the screen scrolls for the key bar).
fn settle() u32 {
    if (zdos.getCursor().col != 0) zdos.print("\n");
    const h = zdos.screenSize().row;
    if (zdos.getCursor().row + 1 >= h) zdos.print("\n");
    return @min(zdos.getCursor().row, h -| 2);
}

// The prompt and the command line at row; the caret's column:
fn drawUserLine(row: u32) u32 {
    var out: [4096]u8 = undefined;
    const path = panels[active].path();
    const prompt_w: u32 = @intCast(@min(screen.textWidth(path) + 1, screen.cols / 2));
    var n = (std.fmt.bufPrint(&out, "\x1b[0m{s}>", .{tail(path, prompt_w - 1)}) catch return 0).len;
    const room = screen.cols - prompt_w;
    const shown = cmd.window(room);
    for (shown) |c| n += std.unicode.utf8Encode(c, out[n..][0..4]) catch 0;
    // Spaces to the end, short of the last column (no wrap):
    var k: usize = shown.len;
    while (k + 1 < room) : (k += 1) {
        out[n] = ' ';
        n += 1;
    }
    zdos.setCursor(0, row);
    zdos.print(out[0..n]);
    return prompt_w + @as(u32, @intCast(cmd.caret - cmd.scroll));
}

// Erases the command line and the key bar:
fn clearBottom(row: u32) void {
    var spaces: [512]u8 = undefined;
    @memset(&spaces, ' ');
    const w = @min(screen.cols -| 1, spaces.len);
    zdos.print("\x1b[0m");
    for ([_]u32{ row, screen.rows - 1 }) |y| {
        zdos.setCursor(0, y);
        zdos.print(spaces[0..w]);
    }
    zdos.setCursor(0, row);
}

fn changeDrive(p: *Panel) void {
    const letter = dialog.chooseDrive("Drive", if (p.path_len > 0) p.path_buf[0] else 'C') orelse return;
    // That drive's current folder, else its root:
    var cwd_buf: [panel.max_path]u8 = undefined;
    const drive = [2]u8{ letter, ':' };
    if (zdos.setCwd(&drive)) {
        _ = p.setPath(zdos.getCwd(&cwd_buf));
    } else |_| {
        const root = [3]u8{ letter, ':', '\\' };
        _ = p.setPath(&root);
    }
    p.cursor = 0;
    p.top = 0;
    p.load(null);
}

fn hasExtension(name: []const u8, list: []const []const u8) bool {
    const ext = config.extension(name) orelse return false;
    for (list) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

// DRAWING


fn drawAll() void {
    _ = draw();
}

fn listHeight() usize {
    return (screen.rows -| 2) -| 5;
}

// The command line's caret column:
fn draw() u32 {
    const w = screen.cols;
    const h = screen.rows;
    if (w < 40 or h < 10) {
        screen.fill(0, 0, w, h, ' ', .light_gray, .black);
        _ = screen.text(0, 0, "ZC: the screen is too small", w, .light_gray, .black);
        return 0;
    }
    const left_w = w / 2;
    drawPanel(&panels[0], 0, left_w, h - 2, active == 0);
    drawPanel(&panels[1], left_w, w - left_w, h - 2, active == 1);
    drawKeys(h - 1);
    // The prompt and command line:
    const p = &panels[active];
    const prompt_w: u32 = @intCast(@min(screen.textWidth(p.path()) + 1, w / 2));
    var prompt_buf: [panel.max_path + 1]u8 = undefined;
    const prompt = std.fmt.bufPrint(&prompt_buf, "{s}>", .{tail(p.path(), prompt_w - 1)}) catch ">";
    _ = screen.text(0, h - 2, prompt, prompt_w, .light_gray, .black);
    return cmd.draw(prompt_w, h - 2, w - prompt_w, .light_gray, .black);
}

// Widths; 0: not shown
const Columns = struct {
    name: u32,
    size: u32,
    time: u32,
};

// Modify Time: "2026-11-13 14:05", narrower "26-11-13 14:05";
// a name gets 12 cells at least:
fn columns(inner: u32) Columns {
    const size: u32 = if (config.human_size) 7 else 10;
    for ([_]u32{ 16, 14 }) |t| {
        if (inner >= size + t + 2 + 12) return .{ .name = inner - size - t - 2, .size = size, .time = t };
    }
    if (inner >= size + 1 + 8) return .{ .name = inner - size - 1, .size = size, .time = 0 };
    return .{ .name = inner, .size = 0, .time = 0 };
}

// Where the inner column lines are, from the left frame:
fn separators(c: Columns, out: *[2]u32) []const u32 {
    var n: usize = 0;
    var x: u32 = 1 + c.name;
    if (c.size > 0) {
        out[n] = x;
        n += 1;
        x += 1 + c.size;
    }
    if (c.time > 0) {
        out[n] = x;
        n += 1;
    }
    return out[0..n];
}

fn timeText(t: zdos.Time, w: u32, buf: *[24]u8) []const u8 {
    if (t.year == 0) return "";
    if (w >= 16) return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ t.year, t.month, t.day, t.hour, t.minute }) catch "";
    return std.fmt.bufPrint(buf, "{d:0>2}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}", .{ t.year % 100, t.month, t.day, t.hour, t.minute }) catch "";
}

fn drawPanel(p: *Panel, x: u32, w: u32, h: u32, on: bool) void {
    const inner = w - 2;
    const c = columns(inner);
    var sep_buf: [2]u32 = undefined;
    const seps = separators(c, &sep_buf);
    screen.fill(x, 0, w, h, ' ', theme.now.frame, theme.now.panel);

    // Frame, column lines and the line above the info row:
    const info_y = h - 2;
    for (1..w - 1) |i| {
        screen.put(x + @as(u32, @intCast(i)), 0, set.h, theme.now.frame, theme.now.panel);
        screen.put(x + @as(u32, @intCast(i)), h - 1, set.h, theme.now.frame, theme.now.panel);
        screen.put(x + @as(u32, @intCast(i)), info_y - 1, set.sh, theme.now.frame, theme.now.panel);
    }
    for (1..h - 1) |j| {
        screen.put(x, @intCast(j), set.v, theme.now.frame, theme.now.panel);
        screen.put(x + w - 1, @intCast(j), set.v, theme.now.frame, theme.now.panel);
    }
    screen.put(x, 0, set.tl, theme.now.frame, theme.now.panel);
    screen.put(x + w - 1, 0, set.tr, theme.now.frame, theme.now.panel);
    screen.put(x, h - 1, set.bl, theme.now.frame, theme.now.panel);
    screen.put(x + w - 1, h - 1, set.br, theme.now.frame, theme.now.panel);
    screen.put(x, info_y - 1, set.left_t, theme.now.frame, theme.now.panel);
    screen.put(x + w - 1, info_y - 1, set.right_t, theme.now.frame, theme.now.panel);
    for (seps) |s| {
        screen.put(x + s, 0, set.top_t, theme.now.frame, theme.now.panel);
        for (1..info_y - 1) |j| screen.put(x + s, @intCast(j), set.sv, theme.now.frame, theme.now.panel);
        screen.put(x + s, info_y - 1, set.cross_up, theme.now.frame, theme.now.panel);
    }

    // Column titles:
    const head = theme.now.heading;
    centreText(x + 1, 1, c.name, sortTitle(p, .name, "Name"), head);
    var cx = x + 1 + c.name + 1;
    if (c.size > 0) {
        centreText(cx, 1, c.size, sortTitle(p, .size, "Size"), head);
        cx += c.size + 1;
    }
    if (c.time > 0) centreText(cx, 1, c.time, sortTitle(p, .time, "Modify Time"), head);

    // Entries:
    const list_h = h - 5;
    p.scroll(list_h);
    for (0..list_h) |row| {
        const i = p.top + row;
        if (i >= p.entries.items.len) break;
        const e = p.entries.items[i];
        const y: u32 = @intCast(2 + row);
        const at_cursor = on and i == p.cursor;
        var fg = nameColor(p, e);
        var bg = theme.now.panel;
        if (at_cursor) {
            bg = theme.now.accent;
            fg = if (e.selected) .magenta else .black;
        }
        drawEntry(p, e, x, y, c, fg, bg);
    }

    // The entry at the cursor, or why the folder can't be read:
    if (p.err) |err| {
        _ = screen.text(x + 1, info_y, zdos.message(err), inner, .yellow, theme.now.panel);
    } else if (p.current()) |e| {
        var buf: [64]u8 = undefined;
        const right = entryInfo(e.*, &buf);
        const rw: u32 = @intCast(@min(right.len, inner));
        const name_w = inner - rw -| 1;
        _ = screen.text(x + 1, info_y, if (e.up) ".." else p.name(e.*), name_w, theme.now.frame, theme.now.panel);
        _ = screen.text(x + 1 + inner - rw, info_y, right, rw, theme.now.frame, theme.now.panel);
    }

    // Path at the top; selection or free space at the bottom:
    var title_buf: [panel.max_path + 2]u8 = undefined;
    const title = std.fmt.bufPrint(&title_buf, " {s} ", .{tail(p.path(), inner -| 4)}) catch " ";
    const tw: u32 = @intCast(screen.textWidth(title));
    _ = screen.text(x + (w - tw) / 2, 0, title, tw, if (on) .black else theme.now.frame, if (on) theme.now.accent else theme.now.panel);
    var foot_buf: [80]u8 = undefined;
    var num_buf: [24]u8 = undefined;
    const selected = p.selectedCount();
    const foot: []const u8 = if (selected > 0)
        std.fmt.bufPrint(&foot_buf, " {s}{s} in {d} selected ", .{ config.sizeText(p.selectedBytes(), &num_buf), bytesWord(p.selectedBytes()), selected }) catch ""
    else if (p.free) |free|
        std.fmt.bufPrint(&foot_buf, " {s}{s} free ", .{ config.sizeText(free, &num_buf), bytesWord(free) }) catch ""
    else
        "";
    const fw: u32 = @intCast(@min(foot.len, inner));
    if (fw > 0) _ = screen.text(x + (w - fw) / 2, h - 1, foot, fw, if (selected > 0) .light_magenta else theme.now.frame, theme.now.panel);
}

// " bytes" after a plain number:
fn bytesWord(n: u64) []const u8 {
    return if (config.human_size and n >= 1024) "" else " bytes";
}

fn drawEntry(p: *Panel, e: panel.Entry, x: u32, y: u32, c: Columns, fg: Color, bg: Color) void {
    const name = if (e.up) ".." else p.name(e);
    const shown = screen.text(x + 1, y, name, c.name, fg, bg);
    // A name cut short ends in "~":
    if (shown == c.name and screen.textWidth(name) > c.name) screen.put(x + c.name, y, '~', fg, bg);
    var cx = x + 1 + c.name;
    if (c.size > 0) {
        screen.put(cx, y, set.sv, theme.now.frame, bg);
        var buf: [24]u8 = undefined;
        rightText(cx + 1, y, sizeText(e, c.size, &buf), c.size, fg, bg);
        cx += 1 + c.size;
    }
    if (c.time > 0) {
        screen.put(cx, y, set.sv, theme.now.frame, bg);
        var buf: [24]u8 = undefined;
        rightText(cx + 1, y, if (e.up) "" else timeText(e.modified, c.time, &buf), c.time, fg, bg);
    }
}

// Bytes that don't fit width (10 digits and more) in KB:
fn sizeText(e: panel.Entry, width: u32, buf: *[24]u8) []const u8 {
    if (e.up) return "<UP>";
    if (e.is_dir) return "<DIR>";
    const s = config.sizeText(e.size, buf);
    if (s.len <= width) return s;
    return std.fmt.bufPrint(buf, "{d}K", .{e.size / 1024}) catch "";
}

fn entryInfo(e: panel.Entry, buf: *[64]u8) []const u8 {
    var size_buf: [24]u8 = undefined;
    const size = sizeText(e, 24, &size_buf);
    var time_buf: [24]u8 = undefined;
    const time = if (e.up) "" else timeText(e.modified, 16, &time_buf);
    return std.fmt.bufPrint(buf, "{s}  {s}", .{ size, time }) catch "";
}

// Colors as the shells give them; folders the theme's (blue:
// white, as light blue doesn't show on the blue panel):
fn nameColor(p: *Panel, e: panel.Entry) Color {
    if (e.selected) return .light_magenta;
    if (e.is_dir) return theme.now.folder;
    const name = p.name(e);
    if (hasExtension(name, &executables)) return .light_green;
    if (hasExtension(name, &archives)) return .light_red;
    if (e.attrs & zdos.Attr.system != 0) return .yellow;
    return theme.now.text;
}

const key_labels = [10][]const u8{ "Help", "Menu", "View", "Edit", "Copy", "RenMov", "Mkdir", "Delete", "Sort", "Quit" };

// Number, label, one space before the next; Quit's label
// reaches the corner (never written). The division's rest
// widens the last labels by one cell each. Below 6 cells
// ("RenMov") 1-9 get 6 and Quit the rest (4 at least).
fn drawKeys(y: u32) void {
    const numbers = 9 + 2; // "1" to "9", "10"
    const gaps = 9;
    const room = screen.cols -| (numbers + gaps + 1);
    var label_w = room / 10;
    var wider: usize = room % 10; // the last ones get a cell more
    var quit_w = label_w + @intFromBool(wider > 0);
    if (label_w < 6) {
        label_w = @min(6, (room -| 4) / 9);
        quit_w = room -| label_w * 9;
        wider = 0;
    }
    screen.fill(0, y, screen.cols, 1, ' ', .light_gray, .black);
    var x: u32 = 0;
    for (key_labels, 0..) |label, i| {
        var num_buf: [2]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{i + 1}) catch "";
        x += screen.text(x, y, num, @intCast(num.len), .light_gray, .black);
        const w = if (i == 9) quit_w else label_w + @intFromBool(i + wider >= 10);
        _ = screen.text(x, y, label, w, .black, theme.now.accent);
        x += w + 1;
    }
}

// The sorted column's title gets an arrow:
fn sortTitle(p: *const Panel, by: panel.SortBy, comptime title: []const u8) []const u8 {
    if (p.sort_by != by) return title;
    return if (p.descending) title ++ "↓" else title ++ "↑";
}

fn centreText(x: u32, y: u32, w: u32, s: []const u8, fg: Color) void {
    const n: u32 = @intCast(@min(screen.textWidth(s), w));
    _ = screen.text(x + (w - n) / 2, y, s, n, fg, theme.now.panel);
}

// The cells before it in the same colors, so a cursor
// line has no gaps:
fn rightText(x: u32, y: u32, s: []const u8, w: u32, fg: Color, bg: Color) void {
    const n: u32 = @intCast(@min(s.len, w));
    screen.fill(x, y, w - n, 1, ' ', fg, bg);
    _ = screen.text(x + w - n, y, s[s.len - n ..], n, fg, bg);
}

// The last n characters of UTF-8 text, ".." first if cut:
fn tail(s: []const u8, n: usize) []const u8 {
    const total = screen.textWidth(s);
    if (total <= n) return s;
    var skip = total - n + 2;
    var i: usize = 0;
    while (i < s.len and skip > 0) {
        i += std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        skip -= 1;
    }
    const State = struct {
        var buf: [panel.max_path + 2]u8 = undefined;
    };
    return std.fmt.bufPrint(&State.buf, "..{s}", .{s[@min(i, s.len)..]}) catch s;
}
