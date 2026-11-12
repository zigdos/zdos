// DEMO: shows and tests the program API. Without arguments a menu of
// the groups; with a group's name, that group:
//   DEMO api [SECTION...]   the API's tests; exit code: failures
//   DEMO colors | keyboard | keys | mouse | tree | gfx | rgb [1] |
//        sound | tasks | cores [N]
// For its own tests: DEMO child | exit | upper | var NAME | task ...
// api works in DEMOTEST (made and deleted in the current folder).
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");
const gfx = @import("zdos/gfx.zig");
const sound = @import("zdos/sound.zig");
const net = @import("zdos/net.zig");
comptime {
    _ = zdos;
}

// THE GROUPS: the menu's items and the command line's words
const Group = struct {
    name: []const u8,
    title: []const u8,
    run: *const fn (args: []const u8, in_menu: bool) u8,
    ask: bool = true, // the menu waits for a key after it
};

const groups = [_]Group{
    .{ .name = "api", .title = "API tests", .run = apiGroup },
    .{ .name = "colors", .title = "Colors and screen", .run = colorsGroup },
    .{ .name = "keyboard", .title = "Keyboard", .run = keyboardGroup, .ask = false },
    .{ .name = "keys", .title = "Key events", .run = keysGroup },
    .{ .name = "mouse", .title = "Mouse", .run = mouseGroup },
    .{ .name = "tree", .title = "Directory tree", .run = treeGroup },
    .{ .name = "gfx", .title = "Graphics, 256 colors", .run = gfxGroup },
    .{ .name = "rgb", .title = "Graphics, true color", .run = rgbGroup },
    .{ .name = "sound", .title = "Sound", .run = soundGroup },
    .{ .name = "tasks", .title = "Tasks", .run = tasksGroup },
    .{ .name = "cores", .title = "Cores", .run = coresGroup },
};

pub fn main(args: []const u8) u8 {
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    const first = words.next() orelse {
        menu();
        return 0;
    };
    const rest = std.mem.trim(u8, words.rest(), " ");
    if (std.ascii.eqlIgnoreCase(first, "child")) {
        zdos.setColor(.light_magenta, .black);
        zdos.print("    (child program running, exits with 42)\n");
        zdos.setColor(.light_gray, .black);
        return 42;
    }
    if (std.ascii.eqlIgnoreCase(first, "exit")) return deepExit(5);
    if (std.ascii.eqlIgnoreCase(first, "upper")) return upper();
    if (std.ascii.eqlIgnoreCase(first, "var") and rest.len > 0) return showVar(rest);
    if (std.ascii.eqlIgnoreCase(first, "task")) return taskRole(rest);
    for (groups) |g| {
        if (std.ascii.eqlIgnoreCase(first, g.name)) return g.run(rest, false);
    }
    zdos.print("Usage: DEMO [api [SECTION...] | colors | keyboard | keys | mouse | tree | gfx | rgb [1] | sound | tasks | cores [N]]\n");
    return 1;
}

fn apiGroup(args: []const u8, _: bool) u8 {
    return runTests(args);
}

fn colorsGroup(_: []const u8, _: bool) u8 {
    colors();
    return 0;
}

fn keyboardGroup(_: []const u8, _: bool) u8 {
    keyboard();
    return 0;
}

fn keysGroup(_: []const u8, _: bool) u8 {
    return keyEvents();
}

fn mouseGroup(_: []const u8, _: bool) u8 {
    return mouseDemo();
}

fn treeGroup(_: []const u8, _: bool) u8 {
    tree();
    return 0;
}

// From the menu back to text; from the command line ZDOS does that
fn gfxGroup(_: []const u8, in_menu: bool) u8 {
    graphics(in_menu);
    return 0;
}

fn rgbGroup(args: []const u8, _: bool) u8 {
    return trueColor(args.len > 0);
}

fn soundGroup(_: []const u8, _: bool) u8 {
    return tune();
}

fn tasksGroup(_: []const u8, _: bool) u8 {
    return tasksDemo();
}

fn coresGroup(args: []const u8, _: bool) u8 {
    return coresDemo(args);
}

fn deepExit(depth: u32) u8 {
    if (depth == 0) zdos.exit(77);
    return deepExit(depth - 1) +% 1;
}

// DEMO UPPER: stdin to stdout in capitals, for pipes.
fn upper() u8 {
    if (!zdos.inputRedirected()) {
        zdos.print("Usage: command | DEMO UPPER, or DEMO UPPER < file\n");
        return 1;
    }
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = zdos.readInput(&buf);
        if (n == 0) break;
        for (buf[0..n]) |*c| c.* = std.ascii.toUpper(c.*);
        zdos.print(buf[0..n]);
    }
    return 0;
}

fn showVar(name: []const u8) u8 {
    var buf: [512]u8 = undefined;
    if (zdos.getVar(name, &buf)) |v| {
        zdos.printf("{s}={s}\n", .{ name, v });
        return 0;
    }
    zdos.printf("{s} is not set\n", .{name});
    return 1;
}

fn tune() u8 {
    zdos.print("The PC speaker (QEMU: -audiodev pa,id=snd -machine pcspk-audiodev=snd)\n");
    zdos.print("Square wave:\n");
    if (playTune(false) != 0) return 1;
    zdos.sleep(500);
    zdos.print("Soft (short pulses; silent in QEMU, quieter on a real speaker):\n");
    if (playTune(true) != 0) return 1;
    zdos.sleep(500);
    return playSamples();
}

// 22050 Hz mono; ZDOS converts and resamples for the card.
fn playSamples() u8 {
    const rate = 22050;
    const out = sound.open(rate, 1, 16) catch |err| {
        zdos.printf("Sound card: {s}\n", .{zdos.message(err)});
        return 0;
    };
    zdos.print("Sound card (QEMU: -device intel-hda -device hda-duplex):\n");
    var buf: [1024]i16 = undefined;
    for (tune_notes) |n| {
        const total = rate * n[1] / 1000;
        var done: u32 = 0;
        // A sine by recurrence, y[n] = 2 cos(w) y[n-1] - y[n-2]:
        // @sin goes wrong on the BIOS edition (x87 without SSE breaks
        // compiler-rt's range reduction).
        const w = 2 * std.math.pi * @as(f32, @floatFromInt(n[0])) / rate;
        const k = 2 * (1 - w * w / 2 + w * w * w * w / 24);
        var prev: f32 = -(w - w * w * w / 6); // sin(-w)
        var cur: f32 = 0; // sin(0)
        while (done < total) {
            const count = @min(buf.len, total - done);
            for (buf[0..count], 0..) |*s, i| {
                // A short fade at both ends against clicks:
                const at = done + @as(u32, @intCast(i));
                const edge = @min(at, total - at);
                const env: f32 = @min(1.0, @as(f32, @floatFromInt(edge)) / 300.0);
                s.* = @intFromFloat(cur * 9000 * env);
                const next = k * cur - prev;
                prev = cur;
                cur = next;
            }
            _ = out.write(std.mem.sliceAsBytes(buf[0..count])) catch break;
            done += @intCast(count);
        }
        zdos.printf("{d} Hz ", .{n[0]});
    }
    out.close(false);
    zdos.print("\n");
    return 0;
}

// Hz and milliseconds a note:
const tune_notes = [_][2]u32{ .{ 262, 150 }, .{ 330, 150 }, .{ 392, 150 }, .{ 523, 300 }, .{ 392, 150 }, .{ 523, 450 } };

fn playTune(soft: bool) u8 {
    for (tune_notes) |n| {
        const played = if (soft) sound.softTone(n[0]) else sound.tone(n[0]);
        played catch |err| {
            // Not here (metal ARM64 ...): nothing to show, no failure
            zdos.printf("No sound: {s}\n", .{zdos.message(err)});
            return if (err == error.NotSupported) 0 else 1;
        };
        zdos.sleep(n[1]);
        zdos.printf("{d} Hz ", .{n[0]});
    }
    sound.tone(0) catch {};
    zdos.print("\n");
    return 0;
}

// The groups, then Quit; keys 1-9, then A, B ...
const menu_items = groups.len + 1;

fn itemKey(i: usize) u8 {
    if (i == groups.len) return 'Q';
    return if (i < 9) @intCast('1' + i) else @intCast('A' + i - 9);
}

fn keyItem(c: u21) ?usize {
    const up = std.ascii.toUpper(@intCast(c & 0x7F));
    for (0..menu_items) |i| {
        if (itemKey(i) == up) return i;
    }
    return null;
}

fn menu() void {
    var sel: usize = 0;
    while (true) {
        drawMenu(sel);
        const k = zdos.readKey();
        if (k.scan == zdos.Scan.up) {
            sel = (sel + menu_items - 1) % menu_items;
            continue;
        } else if (k.scan == zdos.Scan.down) {
            sel = (sel + 1) % menu_items;
            continue;
        } else if (k.scan == zdos.Scan.esc) {
            break;
        } else if (k.char != '\r') {
            sel = (if (k.char < 128) keyItem(k.char) else null) orelse continue;
        }
        if (sel == groups.len) break;
        zdos.clearScreen();
        zdos.showCursor(true);
        const g = groups[sel];
        _ = g.run("", true);
        if (g.ask) {
            zdos.print("\nPress any key to return to the menu");
            _ = zdos.readKey();
        }
    }
    zdos.clearScreen();
    zdos.showCursor(true);
}

fn drawMenu(sel: usize) void {
    zdos.showCursor(false);
    zdos.clearScreen();
    const size = zdos.screenSize();
    title(" zdos DEMO - program API showcase ", size.col);
    for (0..menu_items) |i| {
        zdos.setCursor(4, @intCast(2 + i));
        if (i == sel) zdos.setColor(.yellow, .blue) else zdos.setColor(.light_gray, .black);
        const name = if (i == groups.len) "Quit" else groups[i].title;
        zdos.printf(" {c}. {s:<24}", .{ itemKey(i), name });
    }
    zdos.setColor(.dark_gray, .black);
    zdos.setCursor(4, @intCast(3 + menu_items));
    zdos.print("Up / Down and Enter, or the key in front.  Esc quits.");
    zdos.setColor(.light_gray, .black);
}

fn title(text: []const u8, width: u32) void {
    zdos.setCursor(0, 0);
    zdos.setColor(.white, .blue);
    zdos.print(text);
    var i: usize = text.len;
    while (i < width) : (i += 1) zdos.print(" ");
    zdos.setColor(.light_gray, .black);
}

// A 256-color gradient on 320 x 200, scrolling down until a key; then
// the frames per second. end_it: switch back with gfx_end (DEMO GFX
// doesn't, so ZDOS has to).
fn graphics(end_it: bool) void {
    const width = 320;
    const height = 200;
    gfx.begin(width, height) catch |err| {
        zdos.printf("Graphics are not available: {s}\n", .{zdos.message(err)});
        return;
    };
    zdos.print("This line was printed while the picture showed.\n");

    const picture = zdos.allocator.alloc(u8, width * height) catch {
        gfx.end();
        zdos.print("Not enough memory\n");
        return;
    };
    defer zdos.allocator.free(picture);
    const blue = [3]u8{ 58, 110, 165 };
    const orange = [3]u8{ 255, 140, 0 };
    const violet = [3]u8{ 80, 25, 130 };
    const green = [3]u8{ 40, 160, 60 };
    const start = zdos.millis();
    var last = start;
    var frames: u32 = 0;
    // Moves with the time, not the frames: 100 steps a second, counted in
    // thousandths so no step is lost.
    var fine: u32 = 0;
    while (zdos.pollKey() == null) : (frames += 1) {
        const now = zdos.millis();
        fine +%= @intCast((now - last) * 100);
        last = now;
        const t = fine / 1000;
        // Blue / orange to violet / green and back in about 10 s:
        const shift = sine[(t / 4 + 192) & 255];
        const top = mix(blue, violet, shift);
        const bottom = mix(orange, green, shift);
        // Top, bottom at 128, top again, so scrolling shows no seam:
        var shades: [256][3]u8 = undefined;
        for (&shades, 0..) |*c, i| c.* = mix(top, bottom, sine[(i + 192) & 255]);
        gfx.palette(0, &shades);
        // 40 rows a second:
        const scroll = t * 40 / 100;
        for (0..height) |y| @memset(picture[y * width ..][0..width], @truncate(y -% scroll));
        gfx.draw(picture);
    }
    const ms = zdos.millis() - start;
    if (!end_it) return;
    gfx.end();
    zdos.printf("{d} frames in {d} ms: {d} per second\n", .{ frames, ms, if (ms == 0) 0 else frames * 1000 / ms });
}

// w 0 is a, 255 is b.
fn mix(a: [3]u8, b: [3]u8, w: u8) [3]u8 {
    var c: [3]u8 = undefined;
    for (&c, a, b) |*v, from, to| v.* = @intCast((@as(u32, from) * (255 - w) + @as(u32, to) * w) / 255);
    return c;
}

// At half the screen's size (scaled 2x by ZDOS) or full.
fn trueColor(full: bool) u8 {
    const s = gfx.screen() catch |err| {
        zdos.printf("No graphics: {s}\n", .{zdos.message(err)});
        return 1;
    };
    if (!s.true_color) {
        zdos.printf("The screen is {d} x {d}, without true color (BIOS: VGA 256 colors)\n", .{ s.width, s.height });
        return 1;
    }
    const width: u32 = if (full) s.width else s.width / 2;
    const height: u32 = if (full) s.height else s.height / 2;
    gfx.beginRgb(width, height) catch |err| {
        zdos.printf("True color is not available: {s}\n", .{zdos.message(err)});
        return 1;
    };
    const picture = zdos.allocator.alloc(u32, @as(usize, width) * height) catch {
        gfx.end();
        zdos.print("Not enough memory\n");
        return 1;
    };
    defer zdos.allocator.free(picture);
    const start = zdos.millis();
    var frames: u32 = 0;
    while (zdos.pollKey() == null) : (frames += 1) {
        // Each corner's color moves along sine curves, every pixel
        // a blend of the four (the picture stays, its colors change):
        const t: u32 = @truncate((zdos.millis() - start) / 20);
        var corner: [4][3]u8 = undefined;
        for (&corner, 0..) |*c, i| {
            const k: u32 = @intCast(i * 64);
            c.* = .{ sine[(t + k) & 255], sine[(t * 2 / 3 + k + 85) & 255], sine[(t / 2 + k + 170) & 255] };
        }
        for (0..height) |y| {
            const wy: u8 = @intCast(y * 255 / @max(height - 1, 1));
            const left = mix(corner[0], corner[2], wy);
            const right = mix(corner[1], corner[3], wy);
            const row = picture[y * width ..][0..width];
            for (row, 0..) |*p, x| {
                const c = mix(left, right, @intCast(x * 255 / @max(width - 1, 1)));
                p.* = @as(u32, c[0]) << 16 | @as(u32, c[1]) << 8 | c[2];
            }
        }
        gfx.drawRgb(picture);
    }
    const ms = zdos.millis() - start;
    gfx.end();
    zdos.printf("Screen {d} x {d}; picture {d} x {d}: {d} frames in {d} ms, {d} per second\n", .{
        s.width, s.height, width, height, frames, ms, if (ms == 0) 0 else frames * 1000 / ms,
    });
    return 0;
}

fn keyEvents() u8 {
    zdos.print("Press keys, also several at once; Esc ends.\n");
    while (true) {
        const e = (gfx.keyEvent() catch |err| {
            zdos.printf("Key releases are not available here: {s}\n", .{zdos.message(err)});
            return 1;
        }) orelse {
            zdos.sleep(10);
            continue;
        };
        const what = if (!e.pressed) "released" else if (e.repeat) "repeated" else "pressed ";
        zdos.printf("  code {X:0>4}  {s}  mods {X:0>4}\n", .{ e.code, what, e.mods });
        if (e.code == 0x01 and !e.pressed) return 0; // Esc let go
    }
}

// Buttons color the background red, green, dark blue; the wheel moves
// a marker on the right edge. Redrawn only on change, to spare the CPU.
fn mouseDemo() u8 {
    _ = gfx.mouse() catch |err| {
        zdos.printf("No mouse here: {s}\n", .{zdos.message(err)});
        return 1;
    };
    const width = 320;
    const height = 200;
    gfx.begin(width, height) catch |err| {
        zdos.printf("Graphics are not available: {s}\n", .{zdos.message(err)});
        return 1;
    };
    defer gfx.end();
    const shades = [_][3]u8{
        .{ 58, 110, 165 }, .{ 0, 0, 0 }, .{ 128, 128, 128 }, .{ 255, 255, 255 }, // background, cursor
        .{ 160, 32, 32 }, .{ 32, 128, 32 }, .{ 24, 40, 140 }, .{ 255, 140, 0 }, // buttons, wheel marker
    };
    gfx.palette(0, &shades);
    const marker_w = 8;
    const marker_h = 40;
    var picture: [width * height]u8 = undefined;
    var x: i32 = width / 2;
    var y: i32 = height / 2;
    var wheel_pos: i32 = height / 2;
    var moved: i64 = 0;
    var clicks: u32 = 0;
    var held: u32 = 0;
    var first = true; // draw the very first picture even without any event
    while (true) {
        if (zdos.pollKey()) |k| {
            if (k.scan == zdos.Scan.esc) break;
        }
        const m = gfx.mouse() catch break;

        const changed = m.dx != 0 or m.dy != 0 or m.wheel != 0 or m.buttons != held;
        if (!changed and !first) {
            zdos.sleep(15);
            continue;
        }
        first = false;

        // Half the mouse counts, so the arrow crosses the screen comfortably:
        x = std.math.clamp(x + @divTrunc(m.dx, 2), 0, width - 1);
        y = std.math.clamp(y + @divTrunc(m.dy, 2), 0, height - 1);
        wheel_pos = std.math.clamp(wheel_pos + m.wheel * 20, 0, height - marker_h);
        moved += @abs(m.dx) + @abs(m.dy);
        if (m.buttons & ~held != 0) clicks += 1;
        held = m.buttons;
        const B = gfx.MouseButton;
        const bg: u8 = if (m.buttons & B.left != 0) 4 else if (m.buttons & B.right != 0) 5 else if (m.buttons & B.middle != 0) 6 else 0;
        @memset(&picture, bg);
        for (0..marker_h) |r| {
            const row = @as(usize, @intCast(wheel_pos)) + r;
            @memset(picture[row * width + (width - marker_w) ..][0..marker_w], 7);
        }
        gfx.drawSmallArrow(&picture, width, x, y, 1, 2, 3);
        gfx.draw(&picture);
        zdos.sleep(15);
    }
    gfx.end();
    zdos.printf("Mouse moved {d} counts, {d} button presses; the arrow ended at {d},{d}\n", .{ moved, clicks, x, y });
    return 0;
}

const sine = blk: {
    var table: [256]u8 = undefined;
    for (&table, 0..) |*v, i| v.* = @intFromFloat(127.5 + 127.5 * @sin(@as(f64, @floatFromInt(i)) * std.math.pi / 128.0));
    break :blk table;
};

const color_names = [_][]const u8{
    "black",     "blue",          "green",       "cyan",
    "red",       "magenta",       "brown",       "light_gray",
    "dark_gray", "light_blue",    "light_green", "light_cyan",
    "light_red", "light_magenta", "yellow",      "white",
};

fn colors() void {
    const size = zdos.screenSize();
    zdos.printf("Screen: {d} columns x {d} rows\n\n", .{ size.col, size.row });

    zdos.print("The 16 text colors:\n");
    for (color_names, 0..) |name, i| {
        zdos.setColor(@enumFromInt(i), .black);
        zdos.printf("  {d:>2} {s:<14}", .{ i, name });
        if (i % 4 == 3) zdos.print("\n");
    }
    zdos.setColor(.light_gray, .black);

    zdos.print("\nOn the 8 background colors:\n");
    for (0..8) |bg| {
        zdos.print("  ");
        for (0..16) |fg| {
            zdos.setColor(@enumFromInt(fg), @enumFromInt(bg));
            zdos.print(" Ab ");
        }
        zdos.setColor(.light_gray, .black);
        zdos.print("\n");
    }

    // A box in the bottom right corner by cursor position:
    const w: u32 = 24;
    const top = zdos.getCursor().row + 1;
    if (size.col > w + 2 and size.row > top + 4) {
        const left = size.col - w - 2;
        zdos.setColor(.black, .cyan);
        for (0..3) |r| {
            zdos.setCursor(left, top + @as(u32, @intCast(r)));
            for (0..w) |_| zdos.print(" ");
        }
        zdos.setCursor(left + 2, top + 1);
        zdos.print("placed with setCursor");
        zdos.setColor(.light_gray, .black);
        zdos.setCursor(0, top + 3);
    }
}

var path_buf: [512]u8 = undefined;
var prefix_buf: [256]u8 = undefined;

// Like DOS "TREE /F".
fn tree() void {
    var cwd_buf: [300]u8 = undefined;
    zdos.setColor(.light_cyan, .black);
    zdos.print(zdos.getCwd(&cwd_buf));
    zdos.setColor(.light_gray, .black);
    zdos.print("\n");
    if (!walk(0, 0)) zdos.print("Can't read the directory\n");
}

const Entry = struct { name: []u8, is_dir: bool };

// prefix_buf holds the lines drawn for the parent levels.
fn walk(path_len: usize, prefix_len: usize) bool {
    // Collected first and the folder closed, so deep trees don't run out
    // of handles, and the last entry is known:
    var entries: std.ArrayListUnmanaged(Entry) = .{};
    defer {
        for (entries.items) |e| zdos.allocator.free(e.name);
        entries.deinit(zdos.allocator);
    }
    {
        const dir = zdos.openDir(path_buf[0..path_len]) catch return false;
        defer dir.close();
        var e: zdos.DirEntry = undefined;
        while (dir.next(&e) catch return false) {
            const name = e.name();
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            const copy = zdos.allocator.dupe(u8, name) catch return false;
            entries.append(zdos.allocator, .{ .name = copy, .is_dir = e.is_dir }) catch return false;
        }
    }

    // Files first (like DOS), then folders:
    var dirs_left: usize = 0;
    for (entries.items) |e| {
        if (e.is_dir) dirs_left += 1;
    }
    const prefix = prefix_buf[0..prefix_len];
    for (entries.items) |e| {
        if (e.is_dir) continue;
        zdos.print(prefix);
        zdos.print(if (dirs_left > 0) "|   " else "    ");
        zdos.print(e.name);
        zdos.print("\n");
    }
    for (entries.items) |e| {
        if (!e.is_dir) continue;
        dirs_left -= 1;
        const last = dirs_left == 0;
        zdos.print(prefix);
        zdos.print(if (last) "\\---" else "+---");
        zdos.setColor(.light_cyan, .black);
        zdos.print(e.name);
        zdos.setColor(.light_gray, .black);
        zdos.print("\n");

        const sep: []const u8 = if (path_len == 0) "" else "\\";
        const child_len = path_len + sep.len + e.name.len;
        if (child_len > path_buf.len or prefix_len + 4 > prefix_buf.len) continue;
        @memcpy(path_buf[path_len..][0..sep.len], sep);
        @memcpy(path_buf[path_len + sep.len ..][0..e.name.len], e.name);
        @memcpy(prefix_buf[prefix_len..][0..4], if (last) "    " else "|   ");
        _ = walk(child_len, prefix_len + 4);
    }
    return true;
}

fn keyboard() void {
    zdos.print("Press keys and key combinations (Ctrl, Alt, Shift, Windows / Cmd).\n");
    zdos.print("Esc twice in a row returns to the menu. Ctrl+C is shown as a key here;\n");
    zdos.print("elsewhere in DEMO it ends the program.\n\n");
    // Ctrl+C as an ordinary key on this page:
    zdos.setCtrlC(true);
    defer zdos.setCtrlC(false);
    var last_esc = false;
    while (true) {
        const k = zdos.readKey();
        const esc = k.scan == zdos.Scan.esc and k.mods & ~lock_bits == 0;
        if (esc and last_esc) return;
        last_esc = esc;
        showKey(k);
    }
}

const lock_bits: u16 = zdos.Mod.caps_lock | zdos.Mod.num_lock | zdos.Mod.scroll_lock;

fn showKey(k: zdos.Key) void {
    const M = zdos.Mod;
    const names = [_]struct { bit: u16, name: []const u8 }{
        .{ .bit = M.left_ctrl, .name = "LCtrl+" },   .{ .bit = M.right_ctrl, .name = "RCtrl+" },
        .{ .bit = M.left_alt, .name = "LAlt+" },     .{ .bit = M.right_alt, .name = "RAlt+" },
        .{ .bit = M.left_shift, .name = "LShift+" }, .{ .bit = M.right_shift, .name = "RShift+" },
        .{ .bit = M.left_logo, .name = "LWin+" },    .{ .bit = M.right_logo, .name = "RWin+" },
        .{ .bit = M.menu, .name = "Menu+" },
    };
    zdos.print("  ");
    zdos.setColor(.light_cyan, .black);
    for (names) |n| {
        if (k.mods & n.bit != 0) zdos.print(n.name);
    }
    zdos.setColor(.white, .black);
    if (k.scan != 0) {
        zdos.printf("scan {d}", .{k.scan});
    } else if (k.char >= 0x20 and k.char < 0x7f) {
        zdos.printf("'{c}'", .{@as(u8, @intCast(k.char))});
    } else if (k.char > 0 and k.char < 0x20) { // a control character: Ctrl+D is ^D
        zdos.printf("^{c} (char {d})", .{ @as(u8, @intCast(k.char + 0x40)), k.char });
    } else {
        zdos.printf("char {d}", .{k.char});
    }
    zdos.setColor(.dark_gray, .black);
    if (k.mods & M.caps_lock != 0) zdos.print("  [Caps]");
    if (k.mods & M.num_lock != 0) zdos.print("  [Num]");
    if (k.mods & M.scroll_lock != 0) zdos.print("  [Scroll]");
    zdos.setColor(.light_gray, .black);
    zdos.print("\n");
}

var failures: u8 = 0;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        zdos.setColor(.light_green, .black);
        zdos.print("  [ OK ] ");
    } else {
        zdos.setColor(.light_red, .black);
        zdos.print("  [FAIL] ");
        failures +|= 1;
    }
    zdos.setColor(.light_gray, .black);
    zdos.printf(fmt ++ "\n", args);
}

// "ok" or the error's name:
fn outcome(r: anytype) []const u8 {
    _ = r catch |err| return @errorName(err);
    return "ok";
}

fn expectError(r: anytype, want: zdos.Error, comptime what: []const u8) void {
    const ok = if (r) |_| false else |err| err == want;
    check(ok, what ++ ": {s} (want {s})", .{ outcome(r), @errorName(want) });
}

fn skip(comptime what: []const u8, fs_name: []const u8) void {
    zdos.setColor(.dark_gray, .black);
    zdos.printf("  [skip] " ++ what ++ " (FAT only; this is {s})\n", .{fs_name});
    zdos.setColor(.light_gray, .black);
}

fn fsName(fs: zdos.FileSystem) []const u8 {
    return switch (fs) {
        .fat12 => "FAT12",
        .fat16 => "FAT16",
        .fat32 => "FAT32",
        .mfs3 => "minix",
        .ext2 => "ext2",
        .ext3 => "ext3",
        .ext4 => "ext4",
        .zfs => "ZFS",
        .ntfs => "NTFS",
        .exfat => "exFAT",
        else => "unknown",
    };
}

fn isFat(fs: zdos.FileSystem) bool {
    return fs == .fat12 or fs == .fat16 or fs == .fat32;
}

fn section(name: []const u8) void {
    zdos.setColor(.yellow, .black);
    zdos.print(name);
    zdos.setColor(.light_gray, .black);
    zdos.print("\n");
}

const Section = struct { name: []const u8, run: *const fn () void };

// In this order; DEMO api SECTION... runs those alone
const sections = [_]Section{
    .{ .name = "time", .run = testTime },
    .{ .name = "memory", .run = testMemory },
    .{ .name = "files", .run = testFiles },
    .{ .name = "screen", .run = testScreen },
    .{ .name = "programs", .run = testPrograms },
    .{ .name = "system", .run = testSystem },
    .{ .name = "drives", .run = testDrives },
    .{ .name = "keyb", .run = testKeyb },
    .{ .name = "tasks", .run = testTasks },
    .{ .name = "cores", .run = testCores },
    .{ .name = "net", .run = testNet },
    .{ .name = "sound", .run = testSound },
};

fn runTests(args: []const u8) u8 {
    failures = 0;
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    if (words.peek() == null) {
        for (sections) |t| t.run();
    } else while (words.next()) |w| {
        for (sections) |t| {
            if (std.ascii.eqlIgnoreCase(w, t.name)) {
                t.run();
                break;
            }
        } else check(false, "no section {s} (have: time memory files screen programs system drives keyb tasks cores net sound)", .{w});
    }
    zdos.print("\n");
    if (failures == 0) {
        zdos.setColor(.light_green, .black);
        zdos.print("All tests passed.\n");
    } else {
        zdos.setColor(.light_red, .black);
        zdos.printf("{d} test(s) failed.\n", .{failures});
    }
    zdos.setColor(.light_gray, .black);
    return failures;
}

fn testTime() void {
    section("Time");
    const t = zdos.getTime();
    check(t.year >= 2000 and t.month >= 1 and t.month <= 12, "date {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ t.year, t.month, t.day, t.hour, t.minute, t.second });
    const start = zdos.millis();
    zdos.sleep(200);
    const took = zdos.millis() - start;
    check(took >= 150 and took <= 400, "sleep(200) took {d} ms", .{took});
    var bad = zdos.getTime();
    bad.month = 2;
    bad.day = 30;
    expectError(sys.setTime(bad), error.InvalidArgument, "setTime refuses February 30");
    bad = .{ .year = 2023, .month = 2, .day = 29, .hour = 12, .minute = 0, .second = 0 };
    expectError(sys.setTime(bad), error.InvalidArgument, "setTime refuses February 29 in 2023");
    // Set the clock to what it says, so the tests don't change it:
    const set = sys.setTime(zdos.getTime());
    check(if (set) |_| true else |_| false, "setTime accepts the current time: {s}", .{outcome(set)});
}

fn testMemory() void {
    section("Memory");
    var list: std.ArrayListUnmanaged(u32) = .{};
    var ok = true;
    for (0..10000) |i| list.append(zdos.allocator, @intCast(i)) catch {
        ok = false;
        break;
    };
    var sum: u64 = 0;
    for (list.items) |v| sum += v;
    check(ok and sum == 49995000, "heap: ArrayList of 10000 numbers, sum {d}", .{sum});
    // Not freed on purpose: ZDOS frees it when the program exits:

    const block = zdos.alloc(100000);
    check(block != null and @intFromPtr(block.?) % 16 == 0, "alloc(100000) is 16-byte aligned", .{});
    zdos.free(block);

    check(bigStack() == 66846720, "stack: 512 KB local array", .{});
}

fn bigStack() u64 {
    var buf: [512 * 1024]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i);
    var sum: u64 = 0;
    for (buf) |b| sum += b;
    return sum;
}

fn testFiles() void {
    section("Files and folders");
    var drives: [26]u8 = undefined;
    const d = zdos.getDrives(&drives);
    check(d.len > 0, "drives: {s}", .{d});
    var all_info = true;
    var has_c = false;
    for (d) |letter| {
        const info = zdos.driveInfo(letter) catch {
            all_info = false;
            continue;
        };
        if (letter == 'C' and info.size > 0) has_c = true;
        zdos.printf("         {c}:  {s:<12} {d:>6} MB{s}{s}{s}\n", .{
            letter,                            info.label(),                          info.size / (1024 * 1024),
            if (info.boot) "  (boot)" else "", if (info.system) "  (system)" else "", if (info.hidden) "  (hidden)" else "",
        });
    }
    check(all_info and has_c, "driveInfo for every drive, C: included", .{});
    expectError(zdos.driveInfo('Y'), error.PathNotFound, "driveInfo of a drive that doesn't exist");
    // Labels, serials, attributes, name rules and old dates are FAT's:
    const c_fs: zdos.FileSystem = if (zdos.driveInfo('C')) |dd| dd.file_system else |_| .unknown;
    var here_buf: [300]u8 = undefined;
    const here_letter = zdos.getCwd(&here_buf)[0];
    const fs: zdos.FileSystem = if (zdos.driveInfo(here_letter)) |dd| dd.file_system else |_| .unknown;
    const fat = isFat(fs);
    if (zdos.driveInfo('C')) |dd| {
        if (isFat(dd.file_system)) {
            check(dd.has_serial, "driveInfo C: {s}, serial {X:0>4}-{X:0>4}", .{ fsName(dd.file_system), dd.serial >> 16, dd.serial & 0xFFFF });
        } else check(dd.file_system != .unknown, "driveInfo C: {s}", .{fsName(dd.file_system)});
    } else |err| check(false, "driveInfo C: {s}", .{@errorName(err)});
    check(zdos.lastErrorCode() == .none, "last_error is none after a call that worked", .{});

    // An invalid label is refused; a valid one set, then the old restored:
    if (!isFat(c_fs)) {
        skip("labels of C:", fsName(c_fs));
    } else if (zdos.driveInfo('C')) |info| {
        expectError(sys.setLabel('C', "BAD*LABEL"), error.InvalidName, "setLabel refuses a label with *");
        expectError(sys.setLabel('C', "TWELVE CHARS"), error.InvalidName, "setLabel refuses a 12-character label");
        var old_buf: [64]u8 = undefined;
        const old = old_buf[0..info.label_len];
        @memcpy(old, info.label());
        const set = sys.setLabel('C', "demo test");
        const now = zdos.driveInfo('C') catch null;
        // EDK2's FAT driver drops the space:
        const shown = now != null and (std.mem.eql(u8, now.?.label(), "DEMO TEST") or std.mem.eql(u8, now.?.label(), "DEMOTEST"));
        const restored = sys.setLabel('C', if (std.mem.eql(u8, old, "NO NAME")) "" else old);
        check(worked(set) and shown and worked(restored), "setLabel C: \"demo test\" (stored as DEMO TEST), then back to \"{s}\"", .{old});
    } else |_| {}

    zdos.deleteTree("DEMOTEST") catch {}; // leftovers of an interrupted run
    const made = zdos.makeDir("DEMOTEST");
    check(worked(made), "makeDir DEMOTEST: {s}", .{outcome(made)});
    expectError(zdos.makeDir("DEMOTEST"), error.AlreadyExists, "makeDir again");

    if (zdos.open("DEMOTEST\\NOTE.TXT", .write)) |f| {
        const w = f.writeAll("First line\n");
        const c = f.closeChecked();
        check(worked(w) and worked(c), "create and write DEMOTEST\\NOTE.TXT: {s}, close {s}", .{ outcome(w), outcome(c) });
    } else |err| check(false, "create DEMOTEST\\NOTE.TXT: {s}", .{@errorName(err)});
    if (zdos.open("DEMOTEST\\NOTE.TXT", .update)) |f| {
        const r = f.seek(zdos.seek_end);
        const w = f.writeAll("Second line\n");
        f.close();
        check(worked(r) and worked(w), "append (update mode, seek to end)", .{});
    } else |err| check(false, "open for update: {s}", .{@errorName(err)});
    if (zdos.open("DEMOTEST\\NOTE.TXT", .read)) |f| {
        var buf: [64]u8 = undefined;
        const n = f.read(&buf) catch 0;
        const size = f.size() catch 0;
        check(std.mem.eql(u8, buf[0..n], "First line\nSecond line\n") and size == 23, "read back, size {d}", .{size});
        expectError(f.write("x"), error.AccessDenied, "write to a file opened for reading");
        f.close();
        expectError(f.read(&buf), error.InvalidHandle, "read after close");
    } else |err| check(false, "open for reading: {s}", .{@errorName(err)});

    // Shorter cuts the end off, longer adds zeros:
    if (zdos.open("DEMOTEST\\SIZE.TXT", .write)) |f| {
        _ = f.writeAll("0123456789") catch {};
        const cut = f.setSize(4);
        const size_cut = f.size() catch 0;
        const grown = f.setSize(8);
        const size_grown = f.size() catch 0;
        var sz_buf: [16]u8 = undefined;
        const at = f.seek(0);
        const n = f.read(&sz_buf) catch 0;
        f.close();
        const want = "0123\x00\x00\x00\x00";
        check(worked(cut) and size_cut == 4 and worked(grown) and size_grown == 8 and worked(at) and n == 8 and std.mem.eql(u8, sz_buf[0..n], want), "setSize 10 -> 4 -> 8 bytes: {s} / {s}, contents {s}", .{ outcome(cut), outcome(grown), if (n == 8 and std.mem.eql(u8, sz_buf[0..n], want)) "0123 + 4 zeros" else "wrong" });
    } else |err| check(false, "create DEMOTEST\\SIZE.TXT: {s}", .{@errorName(err)});
    if (zdos.open("DEMOTEST\\SIZE.TXT", .read)) |f| {
        expectError(f.setSize(0), error.AccessDenied, "setSize on a file opened for reading");
        f.close();
    } else |_| {}

    expectError(zdos.open("DEMOTEST\\MISSING.TXT", .read), error.NotFound, "open a missing file");
    expectError(zdos.open("DEMOTEST\\NO_DIR\\X.TXT", .write), error.PathNotFound, "create in a missing folder");
    expectError(zdos.open("DEMOTEST\\NOTE.TXT\\X.TXT", .read), error.NotADirectory, "a file used as a folder");
    expectError(zdos.open("DEMOTEST", .read), error.IsADirectory, "open a folder as a file");
    if (fat) {
        expectError(zdos.open("DEMOTEST\\A*B.TXT", .write), error.InvalidName, "create a file named A*B.TXT");
    } else skip("'*' refused in names", fsName(fs));
    expectError(zdos.open("DEMOTEST\\NOTE.TXT", @enumFromInt(7)), error.InvalidArgument, "open with an unknown mode");
    expectError(zdos.openDir("DEMOTEST\\NOTE.TXT"), error.NotADirectory, "openDir of a file");

    // FAT finds a name in any case and answers with its spelling on disk:
    if (zdos.stat(if (fat) "demotest\\note.txt" else "DEMOTEST\\NOTE.TXT")) |e| {
        check(!e.is_dir and e.size == 23 and std.mem.eql(u8, e.name(), "NOTE.TXT"), "stat: {s}, {d} bytes, modified {d}", .{ e.name(), e.size, e.modified.year });
    } else |err| check(false, "stat: {s}", .{@errorName(err)});
    if (!fat) {
        // Minix and ext2 have no creation time:
        skip("creation date", fsName(fs));
        if (zdos.stat("DEMOTEST\\NOTE.TXT")) |e| {
            check(e.accessed.year >= 1980, "stat: last accessed {d}-{d:0>2}-{d:0>2}", .{ e.accessed.year, e.accessed.month, e.accessed.day });
        } else |err| check(false, "stat: {s}", .{@errorName(err)});
    } else if (zdos.stat("DEMOTEST\\NOTE.TXT")) |e| {
        check(e.created.year >= 1980 and e.accessed.year >= 1980, "stat: created {d}-{d:0>2}-{d:0>2}, last accessed {d}-{d:0>2}-{d:0>2}", .{ e.created.year, e.created.month, e.created.day, e.accessed.year, e.accessed.month, e.accessed.day });
    } else |_| {}

    // Single-rooted path: "/C:/DEMOTEST/NOTE.TXT":
    var root_buf: [300]u8 = undefined;
    var rooted_buf: [340]u8 = undefined;
    const here = zdos.getCwd(&root_buf);
    const here_sep: []const u8 = if (std.mem.endsWith(u8, here, "\\")) "" else "/";
    const rooted = std.fmt.bufPrint(&rooted_buf, "/{s}{s}DEMOTEST/NOTE.TXT", .{ here, here_sep }) catch "";
    const found = zdos.stat(rooted);
    check(if (found) |e| e.size == 23 else |_| false, "stat {s}: {s}", .{ rooted, outcome(found) });

    // With the on-disk spelling:
    var resolved_buf: [400]u8 = undefined;
    var want_buf: [400]u8 = undefined;
    const want = std.fmt.bufPrint(&want_buf, "{s}{s}DEMOTEST\\NOTE.TXT", .{ here, if (std.mem.endsWith(u8, here, "\\")) "" else "\\" }) catch "";
    const typed = if (fat) "demotest\\..\\demotest\\note.txt" else "DEMOTEST\\..\\DEMOTEST\\NOTE.TXT";
    const fp = zdos.fullPath(typed, &resolved_buf);
    check(if (fp) |f| std.mem.eql(u8, f, want) else |_| false, "fullPath {s}: {s}", .{ typed, if (fp) |f| f else |err| @errorName(err) });

    const renamed = zdos.move("DEMOTEST\\NOTE.TXT", "DEMOTEST\\NOTE2.TXT");
    check(worked(renamed) and gone("DEMOTEST\\NOTE.TXT"), "rename NOTE.TXT -> NOTE2.TXT: {s}", .{outcome(renamed)});
    const case_ok = zdos.move("DEMOTEST\\NOTE2.TXT", "DEMOTEST\\Note2.txt");
    const after = zdos.stat(if (fat) "DEMOTEST\\NOTE2.TXT" else "DEMOTEST\\Note2.txt") catch null;
    check(worked(case_ok) and after != null and std.mem.eql(u8, after.?.name(), "Note2.txt"), "rename that only changes letter case", .{});

    var listed = false;
    var list_end = false;
    if (zdos.openDir("DEMOTEST")) |dir| {
        var e: zdos.DirEntry = undefined;
        while (dir.next(&e) catch false) {
            if (std.mem.eql(u8, e.name(), "Note2.txt")) listed = true;
        }
        list_end = zdos.lastErrorCode() == .none; // the end is not an error
        dir.close();
    } else |_| {}
    check(listed and list_end, "openDir lists Note2.txt; the end of the listing is not an error", .{});

    var cwd_buf: [300]u8 = undefined;
    const before = zdos.getCwd(&cwd_buf);
    var saved: [300]u8 = undefined;
    @memcpy(saved[0..before.len], before);
    const moved = worked(zdos.setCwd("DEMOTEST")) and std.mem.endsWith(u8, zdos.getCwd(&cwd_buf), "\\DEMOTEST");
    check(moved and worked(zdos.setCwd(saved[0..before.len])), "setCwd into DEMOTEST and back", .{});
    expectError(zdos.setCwd("DEMOTEST\\NO_DIR"), error.PathNotFound, "setCwd into a missing folder");

    const copied = zdos.copy("DEMOTEST\\Note2.txt", "DEMOTEST\\Copy.txt");
    check(worked(copied) and (if (zdos.stat("DEMOTEST\\Copy.txt")) |e| e.size == 23 else |_| false), "copy a file: {s}", .{outcome(copied)});
    expectError(zdos.copy("DEMOTEST\\Note2.txt", "DEMOTEST\\Copy.txt"), error.AlreadyExists, "copy onto an existing name");
    expectError(zdos.copy("DEMOTEST\\Missing.txt", "DEMOTEST\\Copy2.txt"), error.NotFound, "copy a missing file");
    zdos.makeDir("DEMOTEST\\SUB") catch {};
    if (zdos.open("DEMOTEST\\SUB\\X.TXT", .write)) |f| {
        _ = f.write("x") catch 0;
        f.close();
    } else |_| {}
    check(worked(zdos.copy("DEMOTEST\\SUB", "DEMOTEST\\SUB2")) and !gone("DEMOTEST\\SUB2\\X.TXT"), "copy a folder with its contents", .{});

    // FAT keeps even seconds:
    const when: zdos.Time = .{ .year = 2001, .month = 2, .day = 3, .hour = 4, .minute = 5, .second = 6 };
    const dated = zdos.setFileTime("DEMOTEST\\Copy.txt", when);
    const m = if (zdos.stat("DEMOTEST\\Copy.txt")) |e| e.modified else |_| zdos.Time{ .year = 0, .month = 0, .day = 0, .hour = 0, .minute = 0, .second = 0 };
    check(worked(dated) and m.year == 2001 and m.month == 2 and m.day == 3 and m.hour == 4 and m.minute == 5 and m.second == 6, "setFileTime 2001-02-03 04:05:06, stat reads it back: {s}", .{outcome(dated)});
    if (fat) {
        expectError(zdos.setFileTime("DEMOTEST\\Copy.txt", .{ .year = 1975, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 }), error.InvalidArgument, "setFileTime before 1980");
    } else skip("dates before 1980 refused", fsName(fs));

    // A copy keeps the original's modification date:
    const recopied = zdos.copy("DEMOTEST\\Copy.txt", "DEMOTEST\\Dated.txt");
    const cm = if (zdos.stat("DEMOTEST\\Dated.txt")) |e| e.modified else |_| zdos.Time{ .year = 0, .month = 0, .day = 0, .hour = 0, .minute = 0, .second = 0 };
    check(worked(recopied) and cm.year == 2001 and cm.month == 2 and cm.day == 3 and cm.hour == 4 and cm.minute == 5 and cm.second == 6, "copy keeps the modification date: {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ cm.year, cm.month, cm.day, cm.hour, cm.minute, cm.second });
    expectError(zdos.copy("DEMOTEST\\SUB", "DEMOTEST\\SUB\\IN"), error.InvalidArgument, "copy a folder into itself");
    const moved_dir = zdos.move("DEMOTEST\\SUB2", "DEMOTEST\\SUB3");
    check(worked(moved_dir) and gone("DEMOTEST\\SUB2") and !gone("DEMOTEST\\SUB3\\X.TXT"), "move a folder", .{});
    expectError(zdos.delete("DEMOTEST\\SUB3"), error.IsADirectory, "delete (files only) of a folder");

    if (fat) {
        const ro = zdos.setAttributes("DEMOTEST\\Note2.txt", zdos.Attr.read_only | zdos.Attr.hidden);
        const ro_attrs = if (zdos.stat("DEMOTEST\\Note2.txt")) |e| e.attrs else |_| 0;
        check(worked(ro) and ro_attrs & (zdos.Attr.read_only | zdos.Attr.hidden) == zdos.Attr.read_only | zdos.Attr.hidden, "setAttributes +R +H, stat shows attrs 0x{X:0>2}", .{ro_attrs});
        expectError(zdos.delete("DEMOTEST\\Note2.txt"), error.AccessDenied, "delete a read-only file");
        expectError(zdos.open("DEMOTEST\\Note2.txt", .update), error.AccessDenied, "open a read-only file for writing");
        check(worked(zdos.setAttributes("DEMOTEST\\Note2.txt", 0)), "clear the attributes again", .{});
        expectError(zdos.setAttributes("\\", 0), error.AccessDenied, "attributes of the root");
    } else skip("read-only and hidden attributes", fsName(fs));

    check(worked(zdos.delete("DEMOTEST\\Note2.txt")), "delete a file", .{});
    expectError(zdos.delete("DEMOTEST\\Note2.txt"), error.NotFound, "delete it again");

    // Delete the test folder while the current directory is inside it:
    var full_buf: [320]u8 = undefined;
    const sep: []const u8 = if (std.mem.endsWith(u8, saved[0..before.len], "\\")) "" else "\\";
    const full = std.fmt.bufPrint(&full_buf, "{s}{s}DEMOTEST", .{ saved[0..before.len], sep }) catch "";
    zdos.setCwd("DEMOTEST\\SUB3") catch {};
    const removed = worked(zdos.deleteTree(full)) and gone(full);
    check(removed and std.mem.eql(u8, zdos.getCwd(&cwd_buf), saved[0..before.len]), "deleteTree DEMOTEST with everything in it; the current directory moves out", .{});
}

fn worked(r: zdos.Error!void) bool {
    return if (r) |_| true else |_| false;
}

fn gone(path: []const u8) bool {
    return if (zdos.stat(path)) |_| false else |err| err == error.NotFound;
}

fn testSystem() void {
    section("System, variables and commands");
    const info = zdos.systemInfo();
    check(info.total_memory > 0 and info.free_memory <= info.total_memory and info.largest_free <= info.free_memory and info.cpuName().len > 0, "systemInfo: {s}, {d} MHz, {d} of {d} KB free", .{ info.cpuName(), info.cpu_mhz, info.free_memory / 1024, info.total_memory / 1024 });

    var own_buf: [300]u8 = undefined;
    const own = zdos.programPath(&own_buf);
    check(own.len > 3 and own[1] == ':' and std.ascii.endsWithIgnoreCase(own, "\\DEMO.APP"), "programPath: {s}", .{own});
    var tiny: [4]u8 = undefined;
    check(zdos.programPath(&tiny).len == 0 and zdos.lastErrorCode() == .invalid_argument, "programPath with a buffer too small fails", .{});

    var var_buf: [16]u8 = undefined;
    const set = zdos.setVar("DEMO_RESULT", "42");
    const got = zdos.getVar("DEMO_RESULT", &var_buf);
    check(worked(set) and got != null and std.mem.eql(u8, got.?, "42"), "setVar DEMO_RESULT=42, getVar reads it back", .{});
    var listed = false;
    var line_buf: [600]u8 = undefined;
    var index: u32 = 0;
    while (zdos.varAt(index, &line_buf)) |line| : (index += 1) {
        if (std.mem.eql(u8, line, "DEMO_RESULT=42")) listed = true;
    }
    check(listed, "varAt lists DEMO_RESULT=42 among {d} variables", .{index});
    expectError(zdos.setVar("BAD NAME", "x"), error.InvalidName, "setVar with a space in the name");
    check(worked(zdos.setVar("DEMO_RESULT", "")) and zdos.getVar("DEMO_RESULT", &var_buf) == null, "setVar with an empty value removes it", .{});

    check((zdos.runCommand("DEMO child") catch 255) == 42, "runCommand DEMO child: ERRORLEVEL 42", .{});
    check((zdos.runCommand("REM a built-in command") catch 255) == 0, "runCommand of a built-in command: 0", .{});
    const code = zdos.exec("DEMO", "exit");
    check(if (code) |c| c == 77 else |_| false, "exit(77) from deep inside a program: exit code {d} ({s})", .{ code catch 0, outcome(code) });

    // Ctrl+C as a flag (nothing pressed), the variables' stack:
    sys.catchCtrlC(true);
    check(!sys.ctrlCPressed(true), "catchCtrlC: no Ctrl+C pressed", .{});
    sys.catchCtrlC(false);
    const pushed = sys.pushVars();
    const in_scope = zdos.setVar("DEMO_SCOPED", "1");
    if (worked(pushed)) sys.popVars();
    check(worked(pushed) and worked(in_scope) and zdos.getVar("DEMO_SCOPED", &var_buf) == null, "pushVars, setVar, popVars: the variable is gone", .{});
    var boot_buf: [128]u8 = undefined;
    const boot = sys.bootFile(&boot_buf);
    check(boot == null or boot.?.len > 1, "bootFile: {s}", .{boot orelse "(not said)"});
}

fn testScreen() void {
    section("Screen");
    // Redirected: cursor and colors are ignored:
    if (zdos.outputRedirected()) {
        zdos.print("  [skip] output is redirected, nothing to test on the screen\n");
        return;
    }
    const size = zdos.screenSize();
    check(size.col >= 40 and size.row >= 20, "screen {d} x {d}", .{ size.col, size.row });
    const row = zdos.getCursor().row;
    zdos.setCursor(30, row);
    const pos = zdos.getCursor();
    zdos.setCursor(0, row);
    check(pos.col == 30 and pos.row == row, "setCursor / getCursor", .{});
    zdos.print("  ");
    for (0..16) |c| {
        zdos.setColor(@enumFromInt(c), .black);
        zdos.print("#");
    }
    zdos.setColor(.light_gray, .black);
    zdos.print(" colors (DEMO colors shows all)\n");
    expectError(gfx.begin(0, 200), error.InvalidArgument, "graphics of width 0");
    expectError(gfx.beginDosAspect(0, 200), error.InvalidArgument, "4:3 graphics of width 0");
}

// On qemu: -machine pcspk-audiodev=; ARM64 has no speaker.
fn testSound() void {
    section("Sound");
    const start = zdos.millis();
    const first = sound.beep(440, 100);
    if (first) |_| {} else |err| if (err == error.NotSupported) {
        zdos.setColor(.dark_gray, .black);
        zdos.print("  [skip] no PC speaker here\n");
        zdos.setColor(.light_gray, .black);
        return;
    }
    const took = zdos.millis() - start;
    check(if (first) |_| took >= 80 and took <= 400 else |_| false, "speaker: beep 440 Hz for 100 ms took {d} ms ({s})", .{ took, outcome(first) });
    var tune_ok = true;
    for ([_]u32{ 523, 659, 784, 1047 }) |hz| tune_ok = tune_ok and if (sound.beep(hz, 80)) |_| true else |_| false;
    check(tune_ok, "speaker: C E G C", .{});
    expectError(sound.tone(10), error.InvalidArgument, "tone of 10 Hz");
    const quiet = sound.tone(0);
    check(if (quiet) |_| true else |_| false, "tone 0: silence ({s})", .{outcome(quiet)});
    if (sound.open(22050, 1, 16)) |out| {
        const silence = [_]u8{0} ** 4410; // 0.1 s
        const wrote = out.write(&silence);
        check(if (wrote) |n| n == silence.len else |_| false, "samples: 0.1 s written ({s})", .{outcome(wrote)});
        check(out.queued() > 0, "samples: {d} bytes queued", .{out.queued()});
        expectError(sound.open(8000, 3, 16), error.InvalidArgument, "samples: 3 channels");
        out.close(false);
        check(true, "samples: closed after playing", .{});
    } else |err| check(err == error.NotSupported, "samples without a sound card: {s}", .{@errorName(err)});
}

fn testPrograms() void {
    section("Programs");
    const code = zdos.exec("DEMO", "child");
    check(if (code) |c| c == 42 else |_| false, "exec DEMO child: exit code {d} ({s})", .{ code catch 0, outcome(code) });

    expectError(zdos.exec("NO_SUCH_PROGRAM", ""), error.NotFound, "exec of a missing program");
}

fn skipLine(comptime what: []const u8, args: anytype) void {
    zdos.setColor(.dark_gray, .black);
    zdos.printf("  [skip] " ++ what ++ "\n", args);
    zdos.setColor(.light_gray, .black);
}

// The current drive's size, place and first sector (read only), the disks
fn testDrives() void {
    section("Drives and disks");
    var cwd_buf: [300]u8 = undefined;
    const letter = zdos.getCwd(&cwd_buf)[0];
    const sectors = sys.driveSectors(letter);
    check(if (sectors) |n| n > 0 else |_| false, "driveSectors {c}: {d} ({s})", .{ letter, sectors catch 0, outcome(sectors) });
    if (sys.driveLocation(letter)) |loc| {
        const disk = sys.diskInfo(loc.disk);
        check(disk != null and loc.sectors > 0 and loc.start + loc.sectors <= disk.?.sectors, "driveLocation {c}: disk {d}, from sector {d}, {d} sectors", .{ letter, loc.disk, loc.start, loc.sectors });
    } else |err| {
        if (err == error.NotSupported) skipLine("driveLocation: not on this edition", .{}) else check(false, "driveLocation {c}: {s}", .{ letter, @errorName(err) });
    }
    var first: [512]u8 = undefined;
    const read = sys.driveRead(letter, 0, &first);
    check(worked(read), "driveRead {c}: its first sector ({s})", .{ letter, outcome(read) });
    const disks = sys.diskCount();
    check(disks > 0 and sys.diskInfo(0) != null, "diskCount {d}, diskInfo of disk 0", .{disks});
    check(sys.diskInfo(disks) == null, "diskInfo past the last disk: none", .{});
    check(sys.driveAt(0) != null, "driveAt 0", .{});
}

// The layouts; another made active, then the old one again
fn testKeyb() void {
    section("Keyboard layouts");
    const n = sys.keybCount();
    var name_buf: [16]u8 = undefined;
    const active = sys.keybActive();
    const name = sys.keybName(active, &name_buf) orelse "";
    check(n >= 1 and active < n and name.len > 0, "{d} layouts, {s} active", .{ n, name });
    check(sys.keybName(n, &name_buf) == null, "keybName past the last: none", .{});
    var loaded_buf: [256]u8 = undefined;
    const loaded = sys.keybLoaded(&loaded_buf);
    check(worked(if (loaded) |_| {} else |err| err), "keybLoaded: {s}", .{loaded catch "?"});
    if (n < 2) return skipLine("switching: one layout only", .{});
    // Only loaded layouts can be active: load another for a while
    const was = loaded catch return;
    const other = (active + 1) % n;
    var other_buf: [16]u8 = undefined;
    const other_name = sys.keybName(other, &other_buf) orelse "";
    var words = std.mem.tokenizeScalar(u8, was, ',');
    const in_list = while (words.next()) |w| {
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, w, " "), other_name)) break true;
    } else false;
    if (!in_list) check(std.meta.isError(sys.keybSetActive(other)), "keybSetActive: not to {s}, not loaded", .{other_name});
    var list_buf: [300]u8 = undefined;
    const list = std.fmt.bufPrint(&list_buf, "{s},{s}", .{ was, other_name }) catch return;
    const added = sys.keybSetLoaded(list);
    const set = sys.keybSetActive(other);
    const now = sys.keybActive();
    const back = sys.keybSetActive(active);
    const restored = sys.keybSetLoaded(was);
    check(worked(added) and worked(set) and now == other and worked(back) and worked(restored) and sys.keybActive() == active,
          "keybSetLoaded with {s}, keybSetActive to it and back", .{other_name});
}

// Three at once; priority inheritance; the CPU's time (tasks: metal)
fn testTasks() void {
    section("Tasks");
    var ids: [3]u32 = undefined;
    for (&ids, [_][]const u8{ "task count A 3 30", "task count B 3 50", "task count C 3 20" }) |*id, args| {
        id.* = sys.taskSpawn("DEMO", args) catch |err| return skipLine("tasks: not on this edition ({s})", .{@errorName(err)});
    }
    var counted = true;
    for (ids) |id| counted = counted and (sys.taskWait(id) catch 255) == 3;
    check(counted, "three tasks at once, each counted to 3", .{});
    check(sys.taskPriority(sys.taskId()) != null, "taskPriority of this task", .{});

    // high wants the mutex low holds while mid keeps a CPU busy for
    // 1 s: with inheritance it waits about low's 300 ms of work
    const m = sys.Mutex.create() catch |err| return check(false, "Mutex.create: {s}", .{@errorName(err)});
    defer m.destroy();
    const work = loopsPerMs() * 300;
    var buf: [64]u8 = undefined;
    const low = spawnTask(std.fmt.bufPrint(&buf, "task low {d} {d}", .{ m.number, work }) catch unreachable) orelse return;
    zdos.sleep(20); // it takes the mutex
    const mid = spawnTask("task mid 1000") orelse return;
    const high = spawnTask(std.fmt.bufPrint(&buf, "task high {d}", .{m.number}) catch unreachable) orelse return;
    const tenths = sys.taskWait(high) catch 255; // what it waited, in 10 ms
    _ = sys.taskWait(low) catch 0;
    _ = sys.taskWait(mid) catch 0;
    check(tenths < 80, "priority inheritance: the high task waited {d} ms (not the middle one's 1000)", .{@as(u32, tenths) * 10});
    const t = sys.cpuTimes();
    check(t.total_ms > 0 and t.idle_ms <= t.total_ms, "cpuTimes: {d} ms in all, {d} idle", .{ t.total_ms, t.idle_ms });
}

fn spawnTask(args: []const u8) ?u32 {
    return sys.taskSpawn("DEMO", args) catch |err| {
        check(false, "taskSpawn DEMO {s}: {s}", .{ args, @errorName(err) });
        return null;
    };
}

// A small Mandelbrot set on this core, then shared out: the same
fn testCores() void {
    section("Cores");
    const n = sys.coreCount();
    check(n >= 1, "coreCount: {d}", .{n});
    if (n < 2) return skipLine("other cores: this machine has one", .{});
    const w = 80;
    const h = 50;
    var one: [w * h]u16 = undefined;
    var all: [w * h]u16 = undefined;
    mandelRows(.{ .out = &one, .w = w, .h = h, .max = 300, .first = 0, .step = 1 });
    const used = shareOut(.{ .out = &all, .w = w, .h = h, .max = 300, .first = 0, .step = 1 }, @min(n, 8));
    check(std.mem.eql(u16, &one, &all), "jobs on {d} other cores: the same result as one core", .{used});
    check(!sys.coreBusy(1), "coreBusy 1 after coreWait: no", .{});
}

// Loopback: queries, a UDP datagram to itself, a TCP echo with a task
fn testNet() void {
    section("Network");
    const info = net.info();
    check(info.flags & net.Flags.started == 0 or info.address[0] != 0, "info: {s}", .{if (info.flags & net.Flags.started != 0) "a card" else "loopback only"});
    var routes: u32 = 0;
    while (net.route(routes) != null and routes < 1000) routes += 1;
    var conns: u32 = 0;
    while (net.connection(conns) != null and conns < 10000) conns += 1;
    var arps: u32 = 0;
    while (net.arpEntry(arps) != null and arps < 10000) arps += 1;
    check(routes < 1000 and conns < 10000 and arps < 10000, "{d} routes, {d} connections, {d} ARP entries", .{ routes, conns, arps });
    const lo = [4]u8{ 127, 0, 0, 1 };
    const pong = net.ping(lo, 1, 32, 64, 1000);
    check(if (pong) |r| r.result == net.PingResult.reply else |_| false, "ping 127.0.0.1 ({s})", .{outcome(pong)});

    // UDP: to its own address
    if (net.Socket.open(net.SocketType.datagram)) |u| {
        defer u.close();
        const bound = u.bind(.{ .addr = lo });
        const me = u.address(false) catch net.Address{};
        const sent = u.sendTo("hello", me);
        var got: [16]u8 = undefined;
        const n = if (worked(bound) and me.port != 0) (u.recvFrom(&got, null) catch 0) else 0;
        check(worked(if (sent) |_| {} else |err| err) and n == 5 and std.mem.eql(u8, got[0..5], "hello"), "UDP to itself on port {d}", .{me.port});
    } else |err| check(false, "UDP socket: {s}", .{@errorName(err)});

    // TCP: a task connects, this one answers in capitals
    const l = net.Socket.open(net.SocketType.stream) catch |err| return check(false, "TCP socket: {s}", .{@errorName(err)});
    defer l.close();
    const listening = if (l.bind(.{ .addr = lo })) |_| l.listen(1) else |err| err;
    const port = (l.address(false) catch net.Address{}).port;
    check(worked(listening) and port != 0, "TCP listening on 127.0.0.1:{d}", .{port});
    if (!worked(listening) or port == 0) return;
    var buf: [32]u8 = undefined;
    const client = sys.taskSpawn("DEMO", std.fmt.bufPrint(&buf, "task echo {d}", .{port}) catch unreachable) catch |err|
        return skipLine("TCP echo: no tasks on this edition ({s})", .{@errorName(err)});
    if (l.accept(null)) |c| {
        defer c.close();
        var line: [16]u8 = undefined;
        const n = c.recv(&line) catch 0;
        for (line[0..n]) |*ch| ch.* = std.ascii.toUpper(ch.*);
        c.sendAll(line[0..n]) catch {};
    } else |err| check(false, "TCP accept: {s}", .{@errorName(err)});
    check((sys.taskWait(client) catch 255) == 0, "TCP: a task's hello came back as HELLO", .{});
}

// DEMO TASKS: three counting tasks, then priority inheritance, timed
fn tasksDemo() u8 {
    zdos.print("1. Three tasks at once\n");
    var ids: [3]u32 = undefined;
    for (&ids, [_][]const u8{ "task count A 3 100", "task count B 3 150", "task count C 3 70" }) |*id, args| {
        id.* = sys.taskSpawn("DEMO", args) catch |err| {
            zdos.printf("Tasks can't be started here ({s})\n", .{@errorName(err)});
            return 1;
        };
    }
    for (ids) |id| {
        const code = sys.taskWait(id) catch 255;
        zdos.printf("task {d} ended with {d}\n", .{ id, code });
    }
    zdos.print("\n2. Priority inheritance\n");
    const m = sys.Mutex.create() catch return 1;
    defer m.destroy();
    var buf: [64]u8 = undefined;
    const low = spawnTask(std.fmt.bufPrint(&buf, "task low {d} {d}", .{ m.number, loopsPerMs() * 300 }) catch return 1) orelse return 1;
    zdos.sleep(20); // it takes the mutex
    const mid = spawnTask("task mid 1000") orelse return 1;
    const high = spawnTask(std.fmt.bufPrint(&buf, "task high {d}", .{m.number}) catch return 1) orelse return 1;
    for ([_]u32{ high, low, mid }) |id| _ = sys.taskWait(id) catch 0;
    zdos.print("(without inheritance the high task would wait for the middle one's whole second)\n");
    return 0;
}

// DEMO TASK ...: the tasks' parts.
//   count NAME N MS   prints N lines, exit code N
//   low M WORK        holds mutex M through WORK loops (priority 5)
//   mid MS            keeps a CPU busy (priority 15)
//   high M            waits for mutex M (priority 25); exit code: ms / 10
//   echo PORT         TCP: sends hello to 127.0.0.1:PORT, wants HELLO
fn taskRole(args: []const u8) u8 {
    var words = std.mem.tokenizeScalar(u8, args, ' ');
    const role = words.next() orelse "";
    if (std.mem.eql(u8, role, "count")) {
        const name = words.next() orelse "?";
        const n: usize = @intCast(number(words.next(), 3));
        const ms = number(words.next(), 100);
        for (1..n + 1) |i| {
            zdos.printf("    {s} {d}\n", .{ name, i });
            zdos.sleep(@intCast(ms));
        }
        return @intCast(n);
    }
    if (std.mem.eql(u8, role, "low")) {
        const m = sys.Mutex{ .number = @intCast(number(words.next(), 0)) };
        const work = number(words.next(), 1000);
        setOwnPriority(5);
        m.lock() catch return 1;
        busyLoops(work);
        m.unlock() catch return 1;
        return 0;
    }
    if (std.mem.eql(u8, role, "mid")) {
        setOwnPriority(15);
        const start = zdos.millis();
        const ms = number(words.next(), 1000);
        while (zdos.millis() - start < ms) {}
        return 0;
    }
    if (std.mem.eql(u8, role, "high")) {
        const m = sys.Mutex{ .number = @intCast(number(words.next(), 0)) };
        setOwnPriority(25);
        zdos.sleep(100); // the low task takes the mutex first
        const start = zdos.millis();
        m.lock() catch return 255;
        const waited = zdos.millis() - start;
        m.unlock() catch {};
        zdos.printf("    high: got the mutex after {d} ms\n", .{waited});
        return @intCast(@min(254, waited / 10));
    }
    if (std.mem.eql(u8, role, "echo")) {
        const port: u16 = @intCast(number(words.next(), 0));
        const s = net.Socket.open(net.SocketType.stream) catch return 1;
        defer s.close();
        s.connect(.{ .addr = .{ 127, 0, 0, 1 }, .port = port }) catch return 2;
        s.sendAll("hello") catch return 3;
        var got: [16]u8 = undefined;
        var n: usize = 0;
        while (n < 5) {
            const k = s.recv(got[n..]) catch return 4;
            if (k == 0) break;
            n += k;
        }
        return if (n == 5 and std.mem.eql(u8, got[0..5], "HELLO")) 0 else 5;
    }
    zdos.print("DEMO task [count NAME N MS | low M WORK | mid MS | high M | echo PORT]\n");
    return 1;
}

fn setOwnPriority(p: u32) void {
    sys.taskSetPriority(sys.taskId(), p) catch {};
}

fn number(word: ?[]const u8, default: u64) u64 {
    return std.fmt.parseInt(u64, word orelse return default, 10) catch default;
}

var sink: u64 = 0;

// Takes as long as it gets the CPU, not wall-clock time.
fn busyLoops(n: u64) void {
    var x: u64 = sink;
    var i: u64 = 0;
    while (i < n) : (i += 1) {
        x = x *% 6364136223846793005 +% 1442695040888963407;
        @as(*volatile u64, &sink).* = x;
    }
}

fn loopsPerMs() u64 {
    const n = 2_000_000;
    const start = zdos.millis();
    busyLoops(n);
    return n / @max(1, zdos.millis() - start);
}

// MANDELBROT: rows first, first + step, ... of out (w x h, max steps)
const Share = struct {
    out: []u16,
    w: usize,
    h: usize,
    max: u16,
    first: usize,
    step: usize,
};

fn mandelRows(share: Share) void {
    var y = share.first;
    while (y < share.h) : (y += share.step) {
        const ci = -1.2 + 2.4 * @as(f64, @floatFromInt(y)) / @as(f64, @floatFromInt(share.h));
        for (0..share.w) |x| {
            const cr = -2.2 + 3.2 * @as(f64, @floatFromInt(x)) / @as(f64, @floatFromInt(share.w));
            var zr: f64 = 0;
            var zi: f64 = 0;
            var i: u16 = 0;
            while (i < share.max and zr * zr + zi * zi < 4) : (i += 1) {
                const t = zr * zr - zi * zi + cr;
                zi = 2 * zr * zi + ci;
                zr = t;
            }
            share.out[y * share.w + x] = i;
        }
    }
}

fn mandelJob(arg: ?*anyopaque) callconv(zdos.cc) void {
    const share: *const Share = @ptrCast(@alignCast(arg.?));
    mandelRows(share.*);
}

// The rows dealt to n cores, this one too; a core that takes no job
// (the network's own) has its share done here. The other cores used.
fn shareOut(whole: Share, n: u32) u32 {
    var shares: [64]Share = undefined;
    var refused: [64]bool = @splat(false);
    var used: u32 = 0;
    for (1..n) |core| {
        shares[core] = whole;
        shares[core].first = core;
        shares[core].step = n;
        if (sys.coreStart(@intCast(core), &mandelJob, &shares[core])) |_| {
            used += 1;
        } else |_| refused[core] = true;
    }
    var mine = whole;
    mine.step = n;
    mandelRows(mine);
    for (1..n) |core| {
        if (refused[core]) mandelRows(shares[core]) else sys.coreWait(@intCast(core));
    }
    return used;
}

const big_w = 320;
const big_h = 200;
var big_one: [big_w * big_h]u16 = undefined;
var big_all: [big_w * big_h]u16 = undefined;

// DEMO CORES [N]: on one core, then on all (at most N), timed
fn coresDemo(args: []const u8) u8 {
    const available = sys.coreCount();
    const n = @max(1, @min(available, std.fmt.parseInt(u32, args, 10) catch available, 64));
    zdos.printf("Cores: {d} (using {d})\n", .{ available, n });
    var t = zdos.millis();
    mandelRows(.{ .out = &big_one, .w = big_w, .h = big_h, .max = 1000, .first = 0, .step = 1 });
    const t1 = zdos.millis() - t;
    zdos.printf("1 core:  {d:>6} ms\n", .{t1});
    var same = true;
    if (n > 1) {
        t = zdos.millis();
        _ = shareOut(.{ .out = &big_all, .w = big_w, .h = big_h, .max = 1000, .first = 0, .step = 1 }, n);
        const tn = zdos.millis() - t;
        const tenths = if (tn == 0) 0 else t1 * 10 / tn;
        zdos.printf("{d} cores: {d:>6} ms ({d}.{d}x)\n", .{ n, tn, tenths / 10, tenths % 10 });
        same = std.mem.eql(u16, &big_one, &big_all);
        zdos.print(if (same) "The results match\n\n" else "The results DIFFER\n\n");
    } else zdos.print("No other cores to compare with\n\n");
    mandelPicture();
    return if (same) 0 else 1;
}

// 64 x 20 characters, each the deepest point of its cell
fn mandelPicture() void {
    const shades = " .:-=+*#%@";
    const cols = 64;
    const rows = 20;
    for (0..rows) |r| {
        var line: [cols + 1]u8 = undefined;
        for (0..cols) |c| {
            var deepest: u16 = 0;
            for (r * big_h / rows..(r + 1) * big_h / rows) |y| {
                for (c * big_w / cols..(c + 1) * big_w / cols) |x| deepest = @max(deepest, big_one[y * big_w + x]);
            }
            line[c] = shades[if (deepest >= 1000) shades.len - 1 else @min(shades.len - 2, deepest / 4)];
        }
        line[cols] = '\n';
        zdos.print(&line);
    }
}
