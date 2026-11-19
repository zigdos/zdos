// TTFTEST: two texts in \SYSTEM\TTF fonts at 13, 16 and 22 pixels on
// the whole screen (BIOS without VESA: 320 x 200); keys 1-4 switch the
// hinting, G gamma, S stem darkening, any other key ends it.
// TTFTEST FONT: against a font file: prints the font, draws "ZDOS ¤!"
// at 16 pixels in shades of ASCII and looks a glyph up
// through the cache; the exit code is the number of failures.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const ft = @import("zdos/freetype.zig");
const gfx = @import("zdos/gfx.zig");

comptime {
    _ = zdos;
}

var failures: u8 = 0;

fn check(ok: bool, what: []const u8) void {
    zdos.printf("{s} {s}\n", .{ if (ok) "OK  " else "FAIL", what });
    if (!ok) failures += 1;
}

const width = 160;
const height = 24;
const baseline = 18;
var canvas: [height][width]u8 = undefined;

// The text at 16 pixels into canvas; FNV-1a of the pixels:
fn draw(face: *ft.Face, text: []const u8) !u32 {
    @memset(&canvas, [_]u8{0} ** width);
    var x: i32 = 0;
    var missing: usize = 0;
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |cp| {
        const index = try face.charIndex(cp);
        if (index == 0) missing += 1;
        face.loadGlyph(index, ft.load_render) catch continue;
        const g = face.glyph;
        const bm = &g.bitmap;
        for (0..bm.rows) |r| {
            for (0..bm.width) |col| {
                const y = baseline - g.bitmap_top + @as(i32, @intCast(r));
                const px = x + g.bitmap_left + @as(i32, @intCast(col));
                if (y < 0 or y >= height or px < 0 or px >= width) continue;
                const cell = &canvas[@intCast(y)][@intCast(px)];
                cell.* = @max(cell.*, bm.at(col, r));
            }
        }
        x += @intCast(g.advance.x >> 6);
    }
    check(missing == 0, "every character has a glyph");

    var h: u32 = 2166136261;
    var ink: usize = 0;
    var right: usize = 0;
    for (canvas) |row| {
        for (row, 0..) |v, col| {
            h = (h ^ v) *% 16777619;
            if (v != 0) {
                ink += 1;
                right = @max(right, col);
            }
        }
    }
    check(ink > 100, "the text has ink");

    // Shades, light to dark:
    const shade = " .:-=+*#%@";
    for (canvas) |row| {
        var line: [width]u8 = undefined;
        var end: usize = 0;
        for (row[0 .. right + 1], 0..) |v, col| {
            line[col] = shade[@as(usize, v) * 9 / 255];
            if (line[col] != ' ') end = col + 1;
        }
        if (end > 0) zdos.printf("  {s}\n", .{line[0..end]});
    }
    return h;
}

// The cache's requester: the face ID is the font's path
fn requester(id: ft.FaceId, lib: *ft.Library, _: ?*anyopaque, face: *?*ft.Face) callconv(.c) c_int {
    return ft.newFaceRaw(lib, @ptrCast(id), 0, face);
}

pub fn main(args: []const u8) u8 {
    const path = std.mem.trim(u8, args, " \t\"");
    if (path.len == 0) {
        screen() catch |err| {
            zdos.printf("TTFTEST: {s}", .{@errorName(err)});
            if (err == error.NotLoaded) zdos.print(": FREETYPE.ZDL not found in \\LIBS");
            if (err == error.CannotOpen) zdos.print(": a font missing in \\SYSTEM\\TTF");
            zdos.print("\n  TTFTEST FONT tests a .ttf or .otf file\n");
            return 1;
        };
        return 0;
    }
    run(path) catch |err| {
        zdos.printf("FAIL {s}", .{@errorName(err)});
        if (err == error.FreeType) zdos.printf(" (FreeType error {d})", .{ft.last_code});
        if (err == error.NotLoaded) zdos.print(": FREETYPE.ZDL not found in \\LIBS");
        zdos.print("\n");
        failures += 1;
    };
    zdos.printf("{d} failed\n", .{failures});
    return failures;
}

fn run(path: []const u8) !void {
    const lib = try ft.Library.init();
    const v = try lib.version();
    zdos.printf("FreeType {d}.{d}.{d}\n", .{ v.major, v.minor, v.patch });

    const face = lib.openFace(path, 0) catch |err| {
        check(false, "FT_New_Face");
        return err;
    };
    check(true, "FT_New_Face");
    zdos.printf("{s} {s}: {d} glyphs, {d} units per em{s}{s}\n", .{
        face.family(),                             face.style(),                               face.num_glyphs, face.units_per_em,
        if (face.scalable()) ", scalable" else "", if (face.hasKerning()) ", kerning" else "",
    });
    check(face.scalable(), "an outline font");

    try face.setPixelSizes(0, 16);
    check(true, "FT_Set_Pixel_Sizes 16");
    const sum = try draw(face, "ZDOS ¤!");
    zdos.printf("pixels: {x:0>8}\n", .{sum});

    // An outline's stroke, as subtitle borders are drawn:
    var stroked = false;
    if (face.loadChar('O', ft.load_default)) {
        var glyph = try ft.getGlyph(face.glyph);
        defer ft.doneGlyph(glyph);
        const stroker = try ft.Stroker.init(lib);
        defer stroker.deinit();
        try stroker.set(2 * 64, .round, .round, 0);
        if (stroker.stroke(&glyph)) {
            if (ft.glyphToBitmap(&glyph, ft.render_normal)) {
                const b = ft.bitmapOf(glyph);
                stroked = b.bitmap.width > 0 and b.bitmap.rows > 0;
            } else |_| {}
        } else |_| {}
    } else |_| {}
    check(stroked, "a stroked outline");

    // The cache finds the glyph index FT_Get_Char_Index does:
    var path_z: [1024]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    var cached = false;
    const manager = try ft.CacheManager.init(lib, 1, 1, 0, &requester, null);
    if (ft.CMapCache.init(manager)) |cmaps| {
        const want = try face.charIndex('A');
        cached = want != 0 and try cmaps.lookup(@ptrCast(&path_z), -1, 'A') == want;
    } else |_| {}
    manager.deinit();
    check(cached, "the cache's glyph for A");

    try face.deinit();
    lib.deinit() catch {
        check(false, "FT_Done_FreeType");
        return;
    };
    check(true, "FT_Done_FreeType");
}

// THE SCREEN: true color at the screen's own size where there is one
// (UEFI, metal, BIOS with VESA), else 320 x 200 with 256 colors. Keys 1-4
// switch the hinting, G gamma correction, S stem darkening; any other
// key ends it.

const Mode = struct {
    name: []const u8,
    interpreter: c_uint, // TrueType's: 40 snaps rows only, 35 both ways
    flags: i32,
};

const modes = [_]Mode{
    .{ .name = "1 TrueType v40", .interpreter = 40, .flags = ft.load_default },
    .{ .name = "2 TrueType v35", .interpreter = 35, .flags = ft.load_default },
    .{ .name = "3 auto-hinter", .interpreter = 40, .flags = ft.load_force_autohint },
    .{ .name = "4 monochrome", .interpreter = 35, .flags = ft.load_target_mono },
};

const Settings = struct {
    mode: Mode = modes[0],
    gamma: bool = true,
    darken: bool = false, // the auto-hinter's stem darkening
};

const sizes = [_]c_uint{ 13, 16, 22 };
const Sample = struct { font: []const u8, text: []const u8 };
const samples = [_]Sample{
    .{ .font = "C:\\SYSTEM\\TTF\\Arimo-Regular.ttf", .text = "ZDOS TTF Test" },
    .{ .font = "C:\\SYSTEM\\TTF\\IBMPlexMono-Regular.ttf", .text = "Monospace text" },
};
const label_font = samples[1].font;
const label_px = 11;

// DEMO mouse's background; the texts, the sizes and settings:
const background = [3]u8{ 58, 110, 165 };
const text_color = 0;
const label_color = 1;
const colors = [_][3]u8{ .{ 255, 255, 255 }, .{ 200, 215, 235 } };

// THE PICTURE: 0x00RRGGBB pixels, or palette indexes (each color a
// ramp of ramp_len steps from the background)
const ramp_len = 64;
var scr_w: u32 = 320;
var scr_h: u32 = 200;
var rgb: ?[]u32 = null;
var indexed: [320 * 200]u8 = undefined;

// GAMMA: a mild 1.4 or none (1.0); colors are mixed in linear light
const gamma_on = 1.4;
var to_linear: [256]f32 = undefined;
var from_linear: [1024]u8 = undefined;

fn setGamma(on: bool) void {
    const g: f32 = if (on) gamma_on else 1.0;
    for (&to_linear, 0..) |*v, i| v.* = std.math.pow(f32, @as(f32, @floatFromInt(i)) / 255.0, g);
    for (&from_linear, 0..) |*v, i| {
        const lin = @as(f32, @floatFromInt(i)) / 1023.0;
        v.* = @intFromFloat(@round(std.math.pow(f32, lin, 1.0 / g) * 255.0));
    }
}

// a of 255 of color over the pixel under it:
fn mix(under: [3]u8, color: [3]u8, a: u8) [3]u8 {
    const t = @as(f32, @floatFromInt(a)) / 255.0;
    var out: [3]u8 = undefined;
    for (0..3) |k| {
        const lin = to_linear[under[k]] * (1 - t) + to_linear[color[k]] * t;
        out[k] = from_linear[@intFromFloat(@round(lin * 1023.0))];
    }
    return out;
}

fn plot(x: i32, y: i32, cover: u8, color: u8) void {
    if (cover == 0 or x < 0 or y < 0 or x >= scr_w or y >= scr_h) return;
    const at = @as(usize, @intCast(y)) * scr_w + @as(usize, @intCast(x));
    if (rgb) |px| {
        const v = px[at];
        const under = [3]u8{ @truncate(v >> 16), @truncate(v >> 8), @truncate(v) };
        const c = mix(under, colors[color], cover);
        px[at] = @as(u32, c[0]) << 16 | @as(u32, c[1]) << 8 | c[2];
    } else {
        // The ramp's step; of overlapping pixels the stronger kept:
        const step: u8 = @intCast(@as(u32, cover) * (ramp_len - 1) / 255);
        indexed[at] = @max(indexed[at], color * ramp_len + step);
    }
}

fn clear() void {
    if (rgb) |px| {
        @memset(px, @as(u32, background[0]) << 16 | @as(u32, background[1]) << 8 | background[2]);
    } else @memset(&indexed, 0);
}

// The ramps, mixed as plot would:
fn setPalette() void {
    var pal: [colors.len * ramp_len][3]u8 = undefined;
    for (colors, 0..) |c, r| {
        for (0..ramp_len) |i| pal[r * ramp_len + i] = mix(background, c, @intCast(i * 255 / (ramp_len - 1)));
    }
    gfx.palette(0, &pal);
}

fn screen() !void {
    var set: Settings = .{};
    setGamma(set.gamma);
    // Fonts and library checked before the screen changes:
    const info = gfx.screen() catch gfx.ScreenInfo{ .width = 320, .height = 200, .true_color = false };
    if (info.true_color) {
        scr_w = info.width;
        scr_h = info.height;
        rgb = zdos.allocator.alloc(u32, @as(usize, scr_w) * scr_h) catch null;
    }
    if (rgb == null) {
        scr_w = 320;
        scr_h = 200;
    }
    defer if (rgb) |px| zdos.allocator.free(px);
    try render(set);
    if (rgb != null) try gfx.beginRgb(scr_w, scr_h) else try gfx.begin(scr_w, scr_h);
    defer gfx.end();
    while (true) {
        if (rgb) |px| gfx.drawRgb(px) else {
            setPalette();
            gfx.draw(&indexed);
        }
        // Set-1 codes: 1-4, G, S
        switch (waitKey()) {
            0x02...0x05 => |k| set.mode = modes[k - 0x02],
            0x22 => set.gamma = !set.gamma,
            0x1F => set.darken = !set.darken,
            else => return,
        }
        setGamma(set.gamma);
        render(set) catch return;
    }
}

fn waitKey() u16 {
    while (true) {
        if (gfx.keyEvent() catch null) |k| {
            if (k.pressed) return k.code;
        } else zdos.sleep(10);
    }
}

// The picture: library and fonts anew, so the settings reach every glyph.
// Each sample at each size, its size at the right; the block in the
// middle, the settings at the bottom.
fn render(set: Settings) !void {
    const lib = try ft.Library.init();
    defer lib.deinit() catch {};
    const interpreter: c_uint = set.mode.interpreter;
    try lib.setProperty("truetype", "interpreter-version", &interpreter);
    const no_darkening: u8 = @intFromBool(!set.darken);
    try lib.setProperty("autofitter", "no-stem-darkening", &no_darkening);
    const flags = set.mode.flags;

    var faces: [samples.len]*ft.Face = undefined;
    for (samples, 0..) |sample, i| faces[i] = try lib.openFace(sample.font, 0);
    defer for (faces) |f| f.deinit() catch {};
    const label = try lib.openFace(label_font, 0);
    defer label.deinit() catch {};
    try label.setPixelSizes(0, label_px);

    const margin: i32 = @intCast(@max(6, scr_w / 32));
    const w: i32 = @intCast(scr_w);
    const h: i32 = @intCast(scr_h);
    const label_h: i32 = label_px + label_px / 2;

    // The block's height: each line's, a third more between lines,
    // half the largest size between the fonts:
    var block: i32 = 0;
    for (faces) |f| {
        for (sizes) |px| {
            try f.setPixelSizes(0, px);
            block += lineHeight(f) + @as(i32, @intCast(px / 3));
        }
        block += @intCast(sizes[sizes.len - 1] / 2);
    }
    block -= @intCast(sizes[sizes.len - 1] / 2);

    clear();
    var y: i32 = @max(0, @divTrunc(h - label_h - block, 2));
    for (faces, samples) |f, sample| {
        for (sizes) |px| {
            try f.setPixelSizes(0, px);
            const base = y + ascent(f);
            try drawText(f, sample.text, margin, base, text_color, flags);
            var num_buf: [8]u8 = undefined;
            const num = std.fmt.bufPrint(&num_buf, "{d} px", .{px}) catch "";
            try drawText(label, num, w - margin - try textWidth(label, num, flags), base, label_color, flags);
            y += lineHeight(f) + @as(i32, @intCast(px / 3));
        }
        y += @intCast(sizes[sizes.len - 1] / 2);
    }

    var text_buf: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "{s} | G gamma {s} | S stems {s}", .{
        set.mode.name, if (set.gamma) "1.4" else "off", if (set.darken) "darker" else "normal",
    }) catch set.mode.name;
    try drawText(label, text, @divTrunc(margin, 2), h - label_px / 2, label_color, flags);
}

fn ascent(f: *ft.Face) i32 {
    return @intCast((f.size.?.metrics.ascender + 63) >> 6);
}

fn lineHeight(f: *ft.Face) i32 {
    const m = f.size.?.metrics;
    return @intCast((m.ascender - m.descender + 63) >> 6);
}

// Hinting changes widths: measured as drawn
fn textWidth(face: *ft.Face, text: []const u8, flags: i32) !i32 {
    var total: i32 = 0;
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |cp| {
        try face.loadChar(cp, flags);
        total += @intCast(face.glyph.advance.x >> 6);
    }
    return total;
}

fn drawText(face: *ft.Face, text: []const u8, x0: i32, base_y: i32, color: u8, flags: i32) !void {
    var x = x0;
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    while (it.nextCodepoint()) |cp| {
        try face.loadChar(cp, ft.load_render | flags);
        const g = face.glyph;
        for (0..g.bitmap.rows) |r| {
            for (0..g.bitmap.width) |c| {
                const py = base_y - g.bitmap_top + @as(i32, @intCast(r));
                const px = x + g.bitmap_left + @as(i32, @intCast(c));
                plot(px, py, g.bitmap.at(c, r), color);
            }
        }
        x += @intCast(g.advance.x >> 6);
    }
}
