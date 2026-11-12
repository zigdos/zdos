const std = @import("std");
const zdos = @import("zdos");
comptime {
    _ = zdos;
}

const width = 10;
const height = 16;
const cell = 12;
const screen_width = 320;
const screen_height = 200;
const board_left = (screen_width - width * cell) / 2;
const board_top = (screen_height - height * cell) / 2;

const Piece = struct {
    rows: [4]u8,
    color: u8,
};

const shapes = [_][4]u8{
    .{ 0b0000, 0b1111, 0b0000, 0b0000 },
    .{ 0b0110, 0b0110, 0b0000, 0b0000 },
    .{ 0b0100, 0b1110, 0b0000, 0b0000 },
    .{ 0b0110, 0b1100, 0b0000, 0b0000 },
    .{ 0b1100, 0b0110, 0b0000, 0b0000 },
    .{ 0b1000, 0b1110, 0b0000, 0b0000 },
    .{ 0b0010, 0b1110, 0b0000, 0b0000 },
};

const Game = struct {
    board: [height][width]u8 = @splat(@splat(0)),
    piece: Piece = undefined,
    x: i32 = 3,
    y: i32 = 0,
    next_shape: usize = 0,
    lines: u32 = 0,
    over: bool = false,

    fn spawn(self: *Game) void {
        const index = self.next_shape;
        self.next_shape = (self.next_shape + 1) % shapes.len;
        self.piece = .{ .rows = shapes[index], .color = @intCast(index + 2) };
        self.x = 3;
        self.y = 0;
        self.over = self.collides(self.x, self.y, self.piece.rows);
    }

    fn collides(self: *const Game, x: i32, y: i32, rows: [4]u8) bool {
        for (rows, 0..) |row, py| {
            for (0..4) |px| {
                if (row & (@as(u8, 1) << @intCast(px)) == 0) continue;
                const bx = x + @as(i32, @intCast(px));
                const by = y + @as(i32, @intCast(py));
                if (bx < 0 or bx >= width or by >= height or by < 0) return true;
                if (self.board[@intCast(by)][@intCast(bx)] != 0) return true;
            }
        }
        return false;
    }

    fn move(self: *Game, dx: i32) void {
        if (!self.collides(self.x + dx, self.y, self.piece.rows)) self.x += dx;
    }

    fn fall(self: *Game) bool {
        if (!self.collides(self.x, self.y + 1, self.piece.rows)) {
            self.y += 1;
        } else {
            self.lock();
            self.clearLines();
            self.spawn();
            return true;
        }
        return false;
    }

    fn rotate(self: *Game) void {
        var rows = [_]u8{0} ** 4;
        for (0..4) |row| {
            for (0..4) |col| {
                if (self.piece.rows[row] & (@as(u8, 1) << @intCast(col)) != 0) {
                    rows[col] |= @as(u8, 1) << @intCast(3 - row);
                }
            }
        }
        if (!self.collides(self.x, self.y, rows)) self.piece.rows = rows;
    }

    fn drop(self: *Game) void {
        while (!self.collides(self.x, self.y + 1, self.piece.rows)) self.y += 1;
        _ = self.fall();
    }

    fn lock(self: *Game) void {
        for (self.piece.rows, 0..) |row, py| {
            for (0..4) |px| {
                if (row & (@as(u8, 1) << @intCast(px)) == 0) continue;
                const bx = self.x + @as(i32, @intCast(px));
                const by = self.y + @as(i32, @intCast(py));
                if (bx >= 0 and bx < width and by >= 0 and by < height) {
                    self.board[@intCast(by)][@intCast(bx)] = self.piece.color;
                }
            }
        }
    }

    fn clearLines(self: *Game) void {
        var y: usize = height;
        while (y > 0) {
            y -= 1;
            var full = true;
            for (self.board[y]) |value| {
                if (value == 0) {
                    full = false;
                    break;
                }
            }
            if (!full) continue;
            var row = y;
            while (row > 0) : (row -= 1) self.board[row] = self.board[row - 1];
            self.board[0] = [_]u8{0} ** width;
            self.lines += 1;
            y += 1;
        }
    }
};

pub fn main(_: []const u8) u8 {
    zdos.print("BLOCKS\n\nArrows or A/D: move   Up or W: rotate\nDown or S: faster   Space: drop   Esc: quit\n\nPress any key to start.\n");
    _ = zdos.readKey();

    const api = zdos.table();
    if (!api.gfx.begin(screen_width, screen_height)) {
        const err = zdos.lastError();
        zdos.printf("Graphics unavailable: {s}\n", .{zdos.message(err)});
        return 1;
    }
    defer api.gfx.end();

    const colors = [_][3]u8{
        .{ 8, 12, 24 },
        .{ 36, 44, 64 },
        .{ 64, 220, 220 },
        .{ 240, 220, 64 },
        .{ 180, 80, 220 },
        .{ 80, 220, 100 },
        .{ 240, 80, 80 },
        .{ 80, 120, 240 },
        .{ 240, 150, 60 },
    };
    api.gfx.palette(0, @intCast(colors.len), @ptrCast(&colors[0]));

    var game = Game{};
    game.next_shape = @intCast(zdos.millis() % shapes.len);
    game.spawn();
    var pixels: [screen_width * screen_height]u8 = undefined;
    var last_fall = zdos.millis();
    var last_down_key = zdos.millis();
    var down_blocked = false;

    while (true) {
        const idle_now = zdos.millis();
        if (down_blocked and idle_now - last_down_key >= 600) down_blocked = false;
        while (zdos.pollKey()) |key| {
            if (key.scan == zdos.Scan.esc) return 0;
            if (game.over) {
                game = .{ .next_shape = @intCast(zdos.millis() % shapes.len) };
                game.spawn();
                last_fall = zdos.millis();
                continue;
            }
            const ch: u8 = if (key.char <= 127) std.ascii.toLower(@intCast(key.char)) else 0;
            if (key.scan == zdos.Scan.left or ch == 'a') game.move(-1) else if (key.scan == zdos.Scan.right or ch == 'd') game.move(1) else if (key.scan == zdos.Scan.down or ch == 's') {
                last_down_key = zdos.millis();
                if (!down_blocked and game.fall()) down_blocked = true;
            } else if (key.scan == zdos.Scan.up or ch == 'w') game.rotate() else if (ch == ' ') game.drop();
        }

        const now = zdos.millis();
        if (!game.over and now - last_fall >= 500) {
            if (game.fall() and now - last_down_key < 600) down_blocked = true;
            last_fall = now;
        }
        draw(&pixels, &game);
        api.gfx.draw(pixels[0..].ptr);
        zdos.sleep(20);
    }
}

fn draw(pixels: *[screen_width * screen_height]u8, game: *const Game) void {
    @memset(pixels, 0);
    for (0..height) |y| {
        for (0..width) |x| {
            const color = game.board[y][x];
            drawCell(pixels, x, y, if (game.over) 1 else color);
        }
    }
    if (!game.over) {
        for (game.piece.rows, 0..) |row, py| {
            for (0..4) |px| {
                if (row & (@as(u8, 1) << @intCast(px)) == 0) continue;
                const x = game.x + @as(i32, @intCast(px));
                const y = game.y + @as(i32, @intCast(py));
                if (x >= 0 and x < width and y >= 0 and y < height) {
                    drawCell(pixels, @intCast(x), @intCast(y), game.piece.color);
                }
            }
        }
    }
    for (0..@min(game.lines, 20)) |i| {
        const x = 20 + (i % 4) * 14;
        const y = 72 + (i / 4) * 14;
        fillRect(pixels, x, y, 8, 8, 2);
    }
}

fn drawCell(pixels: *[screen_width * screen_height]u8, x: usize, y: usize, color: u8) void {
    const px = board_left + x * cell;
    const py = board_top + y * cell;
    fillRect(pixels, px, py, cell - 1, cell - 1, if (color == 0) 1 else color);
}

fn fillRect(pixels: *[screen_width * screen_height]u8, x: usize, y: usize, w: usize, h: usize, color: u8) void {
    for (y..y + h) |row| {
        @memset(pixels[row * screen_width + x .. row * screen_width + x + w], color);
    }
}
