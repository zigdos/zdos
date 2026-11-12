// PICTVIEW FILE: views BMP, GIF, PNG or JPEG; arrow keys browse.
// Without true color (BIOS: VGA 320 x 200): 256 colors (Display).
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const gfx = @import("zdos/gfx.zig");
const zpng = @import("vendor/zpng/src/zpng.zig");
const jpeg = @import("vendor/zjpeg/src/root.zig");

comptime {
    _ = zdos;
}

const Error = zdos.Error || error{ InvalidBmp, UnsupportedBmp, InvalidGif, UnsupportedGif, InvalidPng, UnsupportedPng, InvalidJpeg, UnsupportedJpeg, NoImages, ImageNotFound };
const max_gif_bytes = 64 * 1024 * 1024;
const max_gif_pixels = 16 * 1024 * 1024;

const Navigation = enum { quit, previous, next };

const Bitmap = struct {
    width: u32,
    height: u32,
    top_down: bool,
    bpp: u16,
    pixel_offset: u32,
    row_stride: usize,
    palette: [256]u32,
    palette_len: usize,
};

pub fn main(args: []const u8) u8 {
    const path = std.mem.trim(u8, args, " \t\r\n");
    if (path.len == 0) {
        zdos.print("Usage: PICTVIEW file.bmp|file.gif|file.png|file.jpg|file.jpeg\n");
        return 1;
    }
    const name = if (path.len >= 2 and path[0] == '"' and path[path.len - 1] == '"')
        path[1 .. path.len - 1]
    else
        path;

    view(name) catch |err| {
        switch (err) {
            error.InvalidBmp => zdos.printf("PICTVIEW: {s}: invalid BMP file\n", .{name}),
            error.UnsupportedBmp => zdos.printf("PICTVIEW: {s}: use uncompressed 8-, 24- or 32-bit BMP\n", .{name}),
            error.InvalidPng => zdos.printf("PICTVIEW: {s}: invalid PNG file\n", .{name}),
            error.UnsupportedPng => zdos.printf("PICTVIEW: {s}: unsupported PNG format\n", .{name}),
            error.InvalidJpeg => zdos.printf("PICTVIEW: {s}: invalid JPEG file\n", .{name}),
            error.UnsupportedJpeg => zdos.printf("PICTVIEW: {s}: unsupported JPEG format\n", .{name}),
            error.NoImages => zdos.printf("PICTVIEW: no supported images in the folder\n", .{}),
            error.ImageNotFound => zdos.printf("PICTVIEW: {s}: not found in the folder's image list\n", .{name}),
            else => zdos.printf("PICTVIEW: {s}: {s}\n", .{ name, zdos.message(@errorCast(err)) }),
        }
        return 1;
    };
    return 0;
}

fn view(path: []const u8) Error!void {
    defer gfx.end();

    var images = try imageFiles(path);
    defer {
        for (images.items) |image| zdos.allocator.free(image);
        images.deinit(zdos.allocator);
    }

    const selected_name = basename(path);
    var index: usize = 0;
    var selected = false;
    for (images.items, 0..) |image, i| {
        if (std.ascii.eqlIgnoreCase(basename(image), selected_name)) {
            index = i;
            selected = true;
            break;
        }
    }
    if (!selected) return error.ImageNotFound;

    while (true) {
        switch (try viewImage(images.items[index])) {
            .quit => return,
            .next => index = (index + 1) % images.items.len,
            .previous => index = (index + images.items.len - 1) % images.items.len,
        }
    }
}

fn imageFiles(path: []const u8) Error!std.ArrayListUnmanaged([]u8) {
    var images: std.ArrayListUnmanaged([]u8) = .{};
    errdefer {
        for (images.items) |image| zdos.allocator.free(image);
        images.deinit(zdos.allocator);
    }

    const separator = std.mem.lastIndexOfAny(u8, path, "/\\");
    const folder_prefix = if (separator) |at| path[0 .. at + 1] else "";
    const folder = if (separator) |at|
        if (at == 0) path[0..1] else if (at == 2 and path[1] == ':') path[0 .. at + 1] else path[0..at]
    else
        ".";
    const dir = try zdos.openDir(folder);
    defer dir.close();

    var entry: zdos.DirEntry = undefined;
    while (try dir.next(&entry)) {
        if (entry.is_dir or !supportedImage(entry.name())) continue;
        const full_path = try std.fmt.allocPrint(zdos.allocator, "{s}{s}", .{ folder_prefix, entry.name() });
        errdefer zdos.allocator.free(full_path);
        try images.append(zdos.allocator, full_path);
    }
    if (images.items.len == 0) return error.NoImages;
    std.mem.sort([]u8, images.items, {}, imagePathLessThan);
    return images;
}

fn supportedImage(name: []const u8) bool {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return false;
    const extension = name[dot..];
    return std.ascii.eqlIgnoreCase(extension, ".bmp") or
        std.ascii.eqlIgnoreCase(extension, ".jpg") or
        std.ascii.eqlIgnoreCase(extension, ".jpeg") or
        std.ascii.eqlIgnoreCase(extension, ".png") or
        std.ascii.eqlIgnoreCase(extension, ".gif");
}

fn imagePathLessThan(_: void, a: []u8, b: []u8) bool {
    const common_len = @min(a.len, b.len);
    for (a[0..common_len], b[0..common_len]) |left, right| {
        const lower_left = std.ascii.toLower(left);
        const lower_right = std.ascii.toLower(right);
        if (lower_left != lower_right) return lower_left < lower_right;
        if (left != right) return left < right;
    }
    return a.len < b.len;
}

fn basename(path: []const u8) []const u8 {
    const separator = std.mem.lastIndexOfAny(u8, path, "/\\");
    return if (separator) |at| path[at + 1 ..] else path;
}

fn viewImage(path: []const u8) Error!Navigation {
    const file = try zdos.open(path, .read);
    defer file.close();
    const file_size = try file.size();
    var header: [54]u8 = undefined;
    try readExact(file, 0, header[0..6]);
    if (std.mem.eql(u8, header[0..6], "GIF87a") or std.mem.eql(u8, header[0..6], "GIF89a")) {
        return viewGif(file, file_size, path);
    }
    if (std.mem.eql(u8, header[0..6], "\x89PNG\r\n")) {
        return viewPng(file, file_size, path);
    }
    if (header[0] == 0xff and header[1] == 0xd8) {
        return viewJpeg(file, file_size, path);
    }
    try readExact(file, 0, &header);
    if (!std.mem.eql(u8, header[0..2], "BM")) return error.InvalidBmp;

    const dib_size = std.mem.readInt(u32, header[14..18], .little);
    if (dib_size < 40 or @as(u64, 14) + dib_size > file_size) return error.UnsupportedBmp;
    const signed_width: i32 = @bitCast(std.mem.readInt(u32, header[18..22], .little));
    const signed_height: i32 = @bitCast(std.mem.readInt(u32, header[22..26], .little));
    const bpp = std.mem.readInt(u16, header[28..30], .little);
    const compression = std.mem.readInt(u32, header[30..34], .little);
    if (signed_width <= 0 or signed_height == 0 or signed_height == std.math.minInt(i32))
        return error.InvalidBmp;
    if (std.mem.readInt(u16, header[26..28], .little) != 1 or compression != 0 or
        (bpp != 8 and bpp != 24 and bpp != 32))
        return error.UnsupportedBmp;

    const bitmap = try parseBitmap(file, file_size, header, signed_width, signed_height, bpp, dib_size);
    const screen = try gfx.screen();
    const out_size = fit(bitmap.width, bitmap.height, screen.width, screen.height);
    const pixel_count = std.math.mul(usize, out_size.width, out_size.height) catch return error.InvalidBmp;
    const pixels = try zdos.allocator.alloc(u32, pixel_count);
    defer zdos.allocator.free(pixels);
    const row = try zdos.allocator.alloc(u8, bitmap.row_stride);
    defer zdos.allocator.free(row);

    for (0..out_size.height) |y| {
        const source_y: u64 = @as(u64, y) * bitmap.height / out_size.height;
        const file_y = if (bitmap.top_down) source_y else bitmap.height - 1 - source_y;
        const row_offset = std.math.mul(u64, file_y, bitmap.row_stride) catch return error.InvalidBmp;
        const offset = std.math.add(u64, bitmap.pixel_offset, row_offset) catch return error.InvalidBmp;
        try readExact(file, offset, row);
        for (0..out_size.width) |x| {
            const source_x: usize = @intCast(@as(u64, x) * bitmap.width / out_size.width);
            pixels[y * out_size.width + x] = try pixelAt(bitmap, row, source_x);
        }
    }

    var display = try Display.begin(out_size.width, out_size.height, path);
    defer display.deinit();
    if (bitmap.bpp != 8 or !display.showOwn(pixels, bitmap.palette[0..bitmap.palette_len])) display.show(pixels);
    return waitForNavigation();
}

fn viewPng(file: zdos.File, file_size: u64, path: []const u8) Error!Navigation {
    if (file_size < 24 or file_size > max_gif_bytes) return error.InvalidPng;
    var header: [24]u8 = undefined;
    try readExact(file, 0, &header);
    if (!std.mem.eql(u8, header[12..16], "IHDR")) return error.InvalidPng;
    const width = std.mem.readInt(u32, header[16..20], .big);
    const height = std.mem.readInt(u32, header[20..24], .big);
    if (width == 0 or height == 0 or @as(u64, width) * height > max_gif_pixels)
        return error.InvalidPng;

    const bytes = try zdos.allocator.alloc(u8, @intCast(file_size));
    defer zdos.allocator.free(bytes);
    try readExact(file, 0, bytes);
    var stream = std.io.fixedBufferStream(bytes);
    var image = zpng.Image.read(zdos.allocator, stream.reader()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.UnsupportedPng => return error.UnsupportedPng,
        else => return error.InvalidPng,
    };
    defer image.deinit(zdos.allocator);

    const screen = try gfx.screen();
    const out_size = fit(@intCast(image.width), @intCast(image.height), screen.width, screen.height);
    const pixels = try zdos.allocator.alloc(u32, @as(usize, out_size.width) * out_size.height);
    defer zdos.allocator.free(pixels);
    for (0..out_size.height) |y| {
        const sy: usize = @intCast(@as(u64, y) * image.height / out_size.height);
        for (0..out_size.width) |x| {
            const sx: usize = @intCast(@as(u64, x) * image.width / out_size.width);
            const rgba = image.pixels[sy * image.width + sx];
            const alpha = @as(u32, rgba[3] >> 8);
            const red = (@as(u32, rgba[0] >> 8) * alpha) / 255;
            const green = (@as(u32, rgba[1] >> 8) * alpha) / 255;
            const blue = (@as(u32, rgba[2] >> 8) * alpha) / 255;
            pixels[y * out_size.width + x] = (red << 16) | (green << 8) | blue;
        }
    }

    var display = try Display.begin(out_size.width, out_size.height, path);
    defer display.deinit();
    display.show(pixels);
    return waitForNavigation();
}

fn viewJpeg(file: zdos.File, file_size: u64, path: []const u8) Error!Navigation {
    if (file_size < 4 or file_size > max_gif_bytes) return error.InvalidJpeg;
    const bytes = try zdos.allocator.alloc(u8, @intCast(file_size));
    defer zdos.allocator.free(bytes);
    try readExact(file, 0, bytes);
    var image = jpeg.decode(zdos.allocator, bytes, .{ .max_pixels = max_gif_pixels }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.TooLarge, error.Unsupported => return error.UnsupportedJpeg,
        else => return error.InvalidJpeg,
    };
    defer image.deinit(zdos.allocator);

    const screen = try gfx.screen();
    const out_size = fit(image.width, image.height, screen.width, screen.height);
    const pixels = try zdos.allocator.alloc(u32, @as(usize, out_size.width) * out_size.height);
    defer zdos.allocator.free(pixels);
    for (0..out_size.height) |y| {
        const sy: usize = @intCast(@as(u64, y) * image.height / out_size.height);
        for (0..out_size.width) |x| {
            const sx: usize = @intCast(@as(u64, x) * image.width / out_size.width);
            const src = (sy * image.width + sx) * image.channels;
            const red = image.pixels[src];
            const green = if (image.channels == 1) red else image.pixels[src + 1];
            const blue = if (image.channels == 1) red else image.pixels[src + 2];
            pixels[y * out_size.width + x] = (@as(u32, red) << 16) |
                (@as(u32, green) << 8) | blue;
        }
    }
    var display = try Display.begin(out_size.width, out_size.height, path);
    defer display.deinit();
    display.show(pixels);
    return waitForNavigation();
}

fn viewGif(file: zdos.File, file_size: u64, path: []const u8) Error!Navigation {
    if (file_size < 13 or file_size > max_gif_bytes) return error.InvalidGif;
    const bytes = try zdos.allocator.alloc(u8, @intCast(file_size));
    defer zdos.allocator.free(bytes);
    try readExact(file, 0, bytes);
    var cursor = GifCursor{ .bytes = bytes, .pos = 6 };
    const width = try cursor.readU16();
    const height = try cursor.readU16();
    const screen_flags = try cursor.readByte();
    const background_index = try cursor.readByte();
    _ = try cursor.readByte();
    if (width == 0 or height == 0 or @as(u64, width) * height > max_gif_pixels)
        return error.InvalidGif;

    var global_palette: ?GifPalette = null;
    if (screen_flags & 0x80 != 0) {
        global_palette = try readGifPalette(&cursor, @as(usize, 2) << @intCast(screen_flags & 7));
    }
    const palette = global_palette orelse return error.UnsupportedGif;
    if (background_index >= palette.len) return error.InvalidGif;
    const frame_data_start = cursor.pos;
    const canvas = try zdos.allocator.alloc(u32, @as(usize, width) * height);
    defer zdos.allocator.free(canvas);
    const background = palette.colors[background_index];
    @memset(canvas, background);
    const scratch = try zdos.allocator.alloc(u8, bytes.len);
    defer zdos.allocator.free(scratch);
    const frame_pixels = try zdos.allocator.alloc(u8, @as(usize, width) * height);
    defer zdos.allocator.free(frame_pixels);
    const screen = try gfx.screen();
    const out_size = fit(width, height, screen.width, screen.height);
    const pixels = try zdos.allocator.alloc(u32, @as(usize, out_size.width) * out_size.height);
    defer zdos.allocator.free(pixels);
    var display = try Display.begin(out_size.width, out_size.height, path);
    defer display.deinit();

    var loop_count: ?u16 = null;
    var pass: u32 = 0;
    while (true) : (pass += 1) {
        cursor.pos = frame_data_start;
        @memset(canvas, background);
        var control: GifControl = .{};
        var previous: ?GifFrame = null;
        var previous_snapshot: ?[]u32 = null;
        defer if (previous_snapshot) |saved| zdos.allocator.free(saved);
        var frames_in_pass: usize = 0;
        while (try nextGifFrame(&cursor, scratch, width, height, palette, &control, &loop_count)) |next| {
            if (previous) |old| {
                applyGifDisposal(canvas, width, background, old, previous_snapshot);
                if (previous_snapshot) |saved| {
                    zdos.allocator.free(saved);
                    previous_snapshot = null;
                }
            }

            const n = @as(usize, next.width) * next.height;
            try decodeGifLzw(next.data, next.minimum_code_size, frame_pixels[0..n]);
            for (frame_pixels[0..n]) |index| {
                if (index >= next.palette.len) return error.InvalidGif;
            }
            if (next.control.disposal == 3) {
                previous_snapshot = try saveGifRect(canvas, width, next);
            }
            compositeGifFrame(canvas, width, next, frame_pixels[0..n]);
            scaleRgb(canvas, width, height, pixels, out_size.width, out_size.height);
            // 256 colors: the frame's own palette where all its colors are in it
            if (!display.showOwn(pixels, next.palette.colors[0..next.palette.len])) display.show(pixels);
            frames_in_pass += 1;
            const delay_ns = @as(u64, if (next.control.delay_cs == 0) 10 else next.control.delay_cs) * 10_000_000;
            if (try waitGifFrame(delay_ns)) |navigation| return navigation;
            previous = next;
        }
        if (frames_in_pass == 0) return error.InvalidGif;
        if (loop_count == null or (loop_count.? != 0 and pass >= loop_count.?)) break;
    }
    return waitForNavigation();
}

// THE SCREEN: true color where it has it, else 256 colors (BIOS:
// VGA 320 x 200). There a picture gets a fixed palette (6 levels of
// red, green and blue, 40 grays), Floyd-Steinberg dithered; one whose
// colors are all a palette's (a GIF frame, an 8-bit BMP) that palette.
const Display = struct {
    width: u32,
    height: u32,
    true_color: bool,
    indexed: []u8 = &.{}, // the 8-bit picture
    errors: []i16 = &.{}, // dithering's carried error: two rows of r, g, b
    loaded: enum { none, fixed, own } = .none, // the screen's palette
    own_colors: [256]u32 = undefined, // as loaded for .own
    own_len: usize = 0,

    fn begin(width: u32, height: u32, title: []const u8) Error!Display {
        const s = try gfx.screen();
        if (s.true_color) {
            try gfx.beginRgb(width, height);
            gfx.setTitle(title);
            return .{ .width = width, .height = height, .true_color = true };
        }
        const indexed = try zdos.allocator.alloc(u8, @as(usize, width) * height);
        errdefer zdos.allocator.free(indexed);
        const errors = try zdos.allocator.alloc(i16, (@as(usize, width) + 2) * 3 * 2);
        errdefer zdos.allocator.free(errors);
        try gfx.begin(width, height);
        gfx.setTitle(title);
        return .{ .width = width, .height = height, .true_color = false, .indexed = indexed, .errors = errors };
    }

    fn deinit(self: *Display) void {
        if (self.indexed.len > 0) zdos.allocator.free(self.indexed);
        if (self.errors.len > 0) zdos.allocator.free(self.errors);
    }

    // pixels: width * height, 0x00RRGGBB
    fn show(self: *Display, pixels: []const u32) void {
        if (self.true_color) return gfx.drawRgb(pixels);
        if (self.loaded != .fixed) {
            gfx.palette(0, &fixed_palette);
            self.loaded = .fixed;
        }
        dither(pixels, self.indexed, self.width, self.height, self.errors);
        gfx.draw(self.indexed);
    }

    // With colors as the palette; false if a pixel isn't one of them
    fn showOwn(self: *Display, pixels: []const u32, colors: []const u32) bool {
        if (self.true_color) {
            gfx.drawRgb(pixels);
            return true;
        }
        if (colors.len == 0 or colors.len > 256) return false;
        var table: ColorTable = .{};
        for (colors, 0..) |c, i| table.put(c, @intCast(i));
        for (pixels, self.indexed[0..pixels.len]) |p, *out| out.* = table.get(p) orelse return false;
        if (self.loaded != .own or self.own_len != colors.len or !std.mem.eql(u32, self.own_colors[0..colors.len], colors)) {
            var shades: [256][3]u8 = undefined;
            for (colors, 0..) |c, i| shades[i] = .{ @truncate(c >> 16), @truncate(c >> 8), @truncate(c) };
            gfx.palette(0, shades[0..colors.len]);
            @memcpy(self.own_colors[0..colors.len], colors);
            self.own_len = colors.len;
            self.loaded = .own;
        }
        gfx.draw(self.indexed);
        return true;
    }
};

// 0-215: red, green and blue in 6 levels (36 r + 6 g + b); 216-255: grays
const cube_levels = [6]i32{ 0, 51, 102, 153, 204, 255 };
const gray_count = 40;
const fixed_palette: [256][3]u8 = blk: {
    var p: [256][3]u8 = undefined;
    for (0..216) |i| p[i] = .{ cube_levels[i / 36], cube_levels[i / 6 % 6], cube_levels[i % 6] };
    for (0..gray_count) |i| {
        const v: u8 = (i + 1) * 255 / (gray_count + 1);
        p[216 + i] = .{ v, v, v };
    }
    break :blk p;
};

// Floyd-Steinberg onto fixed_palette: each pixel's error goes 7/16
// right, 3/16 down left, 5/16 down, 1/16 down right. errors: two rows
// of (width + 2) x r, g, b (a spare pixel on each side).
fn dither(pixels: []const u32, out: []u8, width: u32, height: u32, errors: []i16) void {
    const w: usize = width;
    const stride = (w + 2) * 3;
    const shifts = [3]u5{ 16, 8, 0 };
    var this = errors[0..stride];
    var next = errors[stride .. 2 * stride];
    @memset(this, 0);
    for (0..height) |y| {
        @memset(next, 0);
        for (0..w) |x| {
            const p = pixels[y * w + x];
            const e = (x + 1) * 3;
            var want: [3]i32 = undefined;
            for (0..3) |c| {
                const v: i32 = @intCast((p >> shifts[c]) & 0xFF);
                want[c] = std.math.clamp(v + this[e + c], 0, 255);
            }
            const index = nearest(want);
            out[y * w + x] = index;
            for (0..3) |c| {
                const err = want[c] - @as(i32, fixed_palette[index][c]);
                this[e + 3 + c] += @intCast(@divTrunc(err * 7, 16));
                next[e - 3 + c] += @intCast(@divTrunc(err * 3, 16));
                next[e + c] += @intCast(@divTrunc(err * 5, 16));
                next[e + 3 + c] += @intCast(@divTrunc(err, 16));
            }
        }
        std.mem.swap([]i16, &this, &next);
    }
}

// The cube's nearest color, or a gray where that is nearer
fn nearest(c: [3]i32) u8 {
    var index: usize = 0;
    var cube_dist: i32 = 0;
    for (c) |v| {
        const level: usize = @intCast(@divTrunc(v * 5 + 127, 255));
        index = index * 6 + level;
        const d = v - cube_levels[level];
        cube_dist += d * d;
    }
    const average = @divTrunc(c[0] + c[1] + c[2], 3);
    const g: usize = @intCast(std.math.clamp(@divTrunc(average * (gray_count + 1) + 127, 255) - 1, 0, gray_count - 1));
    const gray: i32 = fixed_palette[216 + g][0];
    var gray_dist: i32 = 0;
    for (c) |v| gray_dist += (v - gray) * (v - gray);
    return @intCast(if (gray_dist < cube_dist) 216 + g else index);
}

// Colors to their palette index (the first with that color): 512
// slots, open addressing
const ColorTable = struct {
    keys: [512]u32 = undefined,
    values: [512]u8 = undefined,
    used: [512]bool = @splat(false),

    fn slot(c: u32) usize {
        return (c *% 2654435761) >> 23;
    }

    fn put(t: *ColorTable, c: u32, v: u8) void {
        var i = slot(c);
        while (t.used[i]) : (i = (i + 1) & 511) {
            if (t.keys[i] == c) return;
        }
        t.used[i] = true;
        t.keys[i] = c;
        t.values[i] = v;
    }

    fn get(t: *const ColorTable, c: u32) ?u8 {
        var i = slot(c);
        while (t.used[i]) : (i = (i + 1) & 511) {
            if (t.keys[i] == c) return t.values[i];
        }
        return null;
    }
};

fn parseBitmap(
    file: zdos.File,
    file_size: u64,
    header: [54]u8,
    signed_width: i32,
    signed_height: i32,
    bpp: u16,
    dib_size: u32,
) Error!Bitmap {
    const width: u32 = @intCast(signed_width);
    const height: u32 = @intCast(if (signed_height < 0) -signed_height else signed_height);
    const row_bits = std.math.mul(u64, width, bpp) catch return error.InvalidBmp;
    const row_stride_u64 = std.math.mul(u64, (row_bits + 31) / 32, 4) catch return error.InvalidBmp;
    const row_stride: usize = std.math.cast(usize, row_stride_u64) orelse return error.InvalidBmp;
    const pixel_offset = std.mem.readInt(u32, header[10..14], .little);
    const dib_end = @as(u64, 14) + dib_size;

    var palette: [256]u32 = @splat(0);
    var palette_len: usize = 0;
    var palette_end = dib_end;
    if (bpp == 8) {
        const used = std.mem.readInt(u32, header[46..50], .little);
        palette_len = if (used == 0) 256 else used;
        if (palette_len > palette.len) return error.InvalidBmp;
        const palette_bytes = std.math.mul(u64, palette_len, 4) catch return error.InvalidBmp;
        palette_end = std.math.add(u64, dib_end, palette_bytes) catch return error.InvalidBmp;
        if (palette_end > file_size or pixel_offset < palette_end) return error.InvalidBmp;
        var entries: [256 * 4]u8 = undefined;
        try readExact(file, dib_end, entries[0 .. palette_len * 4]);
        for (0..palette_len) |i| {
            const entry = entries[i * 4 ..][0..4];
            palette[i] = rgb(entry[2], entry[1], entry[0]);
        }
    } else if (pixel_offset < dib_end) {
        return error.InvalidBmp;
    }

    const image_bytes = std.math.mul(u64, row_stride_u64, height) catch return error.InvalidBmp;
    const data_end = std.math.add(u64, pixel_offset, image_bytes) catch return error.InvalidBmp;
    if (pixel_offset > file_size or data_end > file_size) return error.InvalidBmp;

    return .{
        .width = width,
        .height = height,
        .top_down = signed_height < 0,
        .bpp = bpp,
        .pixel_offset = pixel_offset,
        .row_stride = row_stride,
        .palette = palette,
        .palette_len = palette_len,
    };
}

fn pixelAt(bitmap: Bitmap, row: []const u8, x: usize) Error!u32 {
    return switch (bitmap.bpp) {
        8 => if (row[x] < bitmap.palette_len) bitmap.palette[row[x]] else error.InvalidBmp,
        24 => rgb(row[x * 3 + 2], row[x * 3 + 1], row[x * 3]),
        32 => rgb(row[x * 4 + 2], row[x * 4 + 1], row[x * 4]),
        else => unreachable,
    };
}

fn rgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
}

fn fit(width: u32, height: u32, screen_width: u32, screen_height: u32) struct { width: u32, height: u32 } {
    if (width <= screen_width and height <= screen_height) return .{ .width = width, .height = height };
    if (@as(u64, screen_width) * height <= @as(u64, screen_height) * width) {
        return .{
            .width = screen_width,
            .height = @max(1, @as(u32, @intCast(@as(u64, height) * screen_width / width))),
        };
    }
    return .{
        .width = @max(1, @as(u32, @intCast(@as(u64, width) * screen_height / height))),
        .height = screen_height,
    };
}

fn readExact(file: zdos.File, offset: u64, buf: []u8) Error!void {
    try file.seek(offset);
    var done: usize = 0;
    while (done < buf.len) {
        const n = try file.read(buf[done..]);
        if (n == 0) return error.InvalidBmp;
        done += n;
    }
}

const GifCursor = struct {
    bytes: []const u8,
    pos: usize,

    fn readByte(self: *GifCursor) Error!u8 {
        if (self.pos >= self.bytes.len) return error.InvalidGif;
        const value = self.bytes[self.pos];
        self.pos += 1;
        return value;
    }

    fn readU16(self: *GifCursor) Error!u16 {
        const lo = try self.readByte();
        const hi = try self.readByte();
        return @as(u16, lo) | (@as(u16, hi) << 8);
    }

    fn take(self: *GifCursor, len: usize) Error![]const u8 {
        if (len > self.bytes.len -| self.pos) return error.InvalidGif;
        const out = self.bytes[self.pos..][0..len];
        self.pos += len;
        return out;
    }

    fn readSubBlocks(self: *GifCursor, scratch: []u8) Error![]const u8 {
        var len: usize = 0;
        while (true) {
            const block_len = try self.readByte();
            if (block_len == 0) return scratch[0..len];
            if (block_len > scratch.len -| len) return error.InvalidGif;
            const block = try self.take(block_len);
            @memcpy(scratch[len..][0..block_len], block);
            len += block_len;
        }
    }
};

const GifPalette = struct {
    colors: [256]u32 = @splat(0),
    len: usize,
};

const GifControl = struct {
    delay_cs: u16 = 0,
    disposal: u3 = 0,
    transparent: ?u8 = null,
};

const GifFrame = struct {
    left: u16,
    top: u16,
    width: u16,
    height: u16,
    interlaced: bool,
    palette: GifPalette,
    control: GifControl,
    minimum_code_size: u8,
    data: []const u8,
};

fn readGifPalette(cursor: *GifCursor, count: usize) Error!GifPalette {
    if (count == 0 or count > 256) return error.InvalidGif;
    const raw = try cursor.take(count * 3);
    var palette: GifPalette = .{ .len = count };
    for (0..count) |i| palette.colors[i] = rgb(raw[i * 3], raw[i * 3 + 1], raw[i * 3 + 2]);
    return palette;
}

fn nextGifFrame(
    cursor: *GifCursor,
    scratch: []u8,
    canvas_width: u16,
    canvas_height: u16,
    global_palette: GifPalette,
    control: *GifControl,
    loop_count: *?u16,
) Error!?GifFrame {
    while (true) {
        switch (try cursor.readByte()) {
            0x3b => return null,
            0x21 => {
                const label = try cursor.readByte();
                if (label == 0xf9) {
                    const len = try cursor.readByte();
                    if (len != 4) return error.InvalidGif;
                    const block = try cursor.take(4);
                    const flags = block[0];
                    control.* = .{
                        .disposal = @intCast((flags >> 2) & 7),
                        .delay_cs = @as(u16, block[1]) | (@as(u16, block[2]) << 8),
                        .transparent = if (flags & 1 != 0) block[3] else null,
                    };
                    if (try cursor.readByte() != 0) return error.InvalidGif;
                } else {
                    if (label == 0xff) {
                        const app_len = try cursor.readByte();
                        const app_id = try cursor.take(app_len);
                        const data = try cursor.readSubBlocks(scratch);
                        if (std.mem.eql(u8, app_id, "NETSCAPE2.0") and data.len >= 3 and data[0] == 1) {
                            loop_count.* = @as(u16, data[1]) | (@as(u16, data[2]) << 8);
                        }
                    } else {
                        _ = try cursor.readSubBlocks(scratch);
                    }
                }
            },
            0x2c => {
                const left = try cursor.readU16();
                const top = try cursor.readU16();
                const width = try cursor.readU16();
                const height = try cursor.readU16();
                const flags = try cursor.readByte();
                if (width == 0 or height == 0 or
                    @as(u32, left) + width > canvas_width or @as(u32, top) + height > canvas_height)
                    return error.InvalidGif;
                const palette = if (flags & 0x80 != 0)
                    try readGifPalette(cursor, @as(usize, 2) << @intCast(flags & 7))
                else
                    global_palette;
                const minimum_code_size = try cursor.readByte();
                if (minimum_code_size < 2 or minimum_code_size > 8) return error.InvalidGif;
                const data = try cursor.readSubBlocks(scratch);
                const frame = GifFrame{
                    .left = left,
                    .top = top,
                    .width = width,
                    .height = height,
                    .interlaced = flags & 0x40 != 0,
                    .palette = palette,
                    .control = control.*,
                    .minimum_code_size = minimum_code_size,
                    .data = data,
                };
                control.* = .{};
                return frame;
            },
            else => return error.InvalidGif,
        }
    }
}

fn decodeGifLzw(data: []const u8, minimum_code_size: u8, output: []u8) Error!void {
    const clear_code: u16 = @as(u16, 1) << @intCast(minimum_code_size);
    const end_code = clear_code + 1;
    var prefixes: [4096]u16 = undefined;
    var suffixes: [4096]u8 = undefined;
    var stack: [4096]u8 = undefined;
    var bit_pos: usize = 0;
    var code_size: u4 = @intCast(minimum_code_size + 1);
    var next_code: u16 = end_code + 1;
    var old_code: ?u16 = null;
    var first_char: u8 = 0;
    var written: usize = 0;

    while (true) {
        const code = try readGifCode(data, &bit_pos, code_size);
        if (code == clear_code) {
            code_size = @intCast(minimum_code_size + 1);
            next_code = end_code + 1;
            old_code = null;
            continue;
        }
        if (code == end_code) {
            if (written != output.len) return error.InvalidGif;
            return;
        }
        if (code > next_code or code >= 4096) return error.InvalidGif;
        if (old_code == null) {
            if (code >= clear_code or written >= output.len) return error.InvalidGif;
            first_char = @intCast(code);
            output[written] = first_char;
            written += 1;
            old_code = code;
            continue;
        }

        const in_code = code;
        var current = code;
        var stack_len: usize = 0;
        if (code == next_code) {
            stack[stack_len] = first_char;
            stack_len += 1;
            current = old_code.?;
        }
        while (current >= clear_code) {
            if (current >= next_code or stack_len >= stack.len) return error.InvalidGif;
            stack[stack_len] = suffixes[current];
            stack_len += 1;
            current = prefixes[current];
        }
        first_char = @intCast(current);
        stack[stack_len] = first_char;
        stack_len += 1;
        while (stack_len > 0) {
            stack_len -= 1;
            if (written >= output.len) return error.InvalidGif;
            output[written] = stack[stack_len];
            written += 1;
        }

        if (next_code < 4096) {
            prefixes[next_code] = old_code.?;
            suffixes[next_code] = first_char;
            next_code += 1;
            if (next_code == (@as(u16, 1) << @intCast(code_size)) and code_size < 12)
                code_size += 1;
        }
        old_code = in_code;
    }
}

fn readGifCode(data: []const u8, bit_pos: *usize, code_size: u4) Error!u16 {
    const bits: usize = code_size;
    if (bit_pos.* > data.len * 8 or bits > data.len * 8 - bit_pos.*) return error.InvalidGif;
    var code: u16 = 0;
    for (0..bits) |i| {
        const at = bit_pos.* + i;
        code |= @as(u16, (data[at / 8] >> @intCast(at & 7)) & 1) << @intCast(i);
    }
    bit_pos.* += bits;
    return code;
}

fn compositeGifFrame(canvas: []u32, canvas_width: u16, frame: GifFrame, indices: []const u8) void {
    const fw: usize = frame.width;
    const cw: usize = canvas_width;
    if (frame.interlaced) {
        const starts = [_]usize{ 0, 4, 2, 1 };
        const steps = [_]usize{ 8, 8, 4, 2 };
        var source_row: usize = 0;
        for (0..4) |pass| {
            var y = starts[pass];
            while (y < frame.height) : (y += steps[pass]) {
                compositeGifRow(canvas, cw, frame, indices, source_row, y, fw);
                source_row += 1;
            }
        }
    } else {
        for (0..frame.height) |y| compositeGifRow(canvas, cw, frame, indices, y, y, fw);
    }
}

fn compositeGifRow(canvas: []u32, canvas_width: usize, frame: GifFrame, indices: []const u8, source_y: usize, dest_y: usize, frame_width: usize) void {
    const dest = (@as(usize, frame.top) + dest_y) * canvas_width + frame.left;
    for (0..frame_width) |x| {
        const index = indices[source_y * frame_width + x];
        if (frame.control.transparent != index) canvas[dest + x] = frame.palette.colors[index];
    }
}

fn saveGifRect(canvas: []const u32, canvas_width: u16, frame: GifFrame) Error![]u32 {
    const row_width: usize = frame.width;
    const height: usize = frame.height;
    const saved = try zdos.allocator.alloc(u32, row_width * height);
    for (0..height) |y| {
        const from = (@as(usize, frame.top) + y) * canvas_width + frame.left;
        @memcpy(saved[y * row_width ..][0..row_width], canvas[from..][0..row_width]);
    }
    return saved;
}

fn applyGifDisposal(canvas: []u32, canvas_width: u16, background: u32, frame: GifFrame, snapshot: ?[]const u32) void {
    const row_width: usize = frame.width;
    const height: usize = frame.height;
    for (0..height) |y| {
        const from = (@as(usize, frame.top) + y) * canvas_width + frame.left;
        const row = canvas[from..][0..row_width];
        switch (frame.control.disposal) {
            2 => @memset(row, background),
            3 => if (snapshot) |saved| @memcpy(row, saved[y * row_width ..][0..row_width]),
            else => {},
        }
    }
}

fn scaleRgb(source: []const u32, source_width: u32, source_height: u32, dest: []u32, dest_width: u32, dest_height: u32) void {
    for (0..dest_height) |y| {
        const sy: usize = @intCast(@as(u64, y) * source_height / dest_height);
        for (0..dest_width) |x| {
            const sx: usize = @intCast(@as(u64, x) * source_width / dest_width);
            dest[y * dest_width + x] = source[sy * source_width + sx];
        }
    }
}

fn navigationForKey(key: gfx.KeyEvent) ?Navigation {
    if (!key.pressed) return null;
    return switch (key.code) {
        0x01 => .quit,
        0xe04b => .previous,
        0xe04d => .next,
        else => null,
    };
}

fn waitForNavigation() zdos.Error!Navigation {
    while (true) {
        if (try gfx.keyEvent()) |key| {
            if (navigationForKey(key)) |navigation| return navigation;
        } else {
            zdos.sleep(10);
        }
    }
}

fn waitGifFrame(delay_ns: u64) zdos.Error!?Navigation {
    const now = zdos.nanos();
    const deadline = std.math.add(u64, now, delay_ns) catch std.math.maxInt(u64);
    while (zdos.nanos() < deadline) {
        if (try gfx.keyEvent()) |key| {
            if (navigationForKey(key)) |navigation| return navigation;
        } else {
            zdos.sleep(1);
        }
    }
    return null;
}
