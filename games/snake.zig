const zdos = @import("zdos");
comptime {
    _ = zdos;
}

const screen_width = 320;
const screen_height = 200;
const cell = 12;
const field_width = screen_width / cell;
const field_height = screen_height / cell;
const field_width_i32: i32 = @intCast(field_width);
const field_height_i32: i32 = @intCast(field_height);
const field_left = (screen_width - field_width * cell) / 2;
const field_top = (screen_height - field_height * cell) / 2;
const max_length = field_width * field_height;
const win_length = 100;

const Point = struct {
    x: i32,
    y: i32,
};

const Direction = enum {
    up,
    down,
    left,
    right,
};

const Result = enum {
    win,
    lose,
};

pub fn main(_: []const u8) u8 {
    zdos.print("SNAKE\n\nArrows or WASD: steer   Esc: quit\nEat food and grow to 100. Don't hit a wall or yourself.\n\nPress any key to start.\n");
    _ = zdos.readKey();

    const api = zdos.table();
    if (!api.gfx.begin(screen_width, screen_height)) {
        const err = zdos.lastError();
        zdos.printf("Graphics unavailable: {s}\n", .{zdos.message(err)});
        return 1;
    }

    const colors = [_][3]u8{
        .{ 8, 12, 24 },
        .{ 36, 44, 64 },
        .{ 80, 220, 100 },
        .{ 240, 80, 80 },
        .{ 180, 240, 120 },
    };
    api.gfx.palette(0, @intCast(colors.len), @ptrCast(&colors[0]));

    var snake: [max_length]Point = undefined;
    var length: usize = 3;
    snake[0] = .{ .x = @intCast(field_width / 2), .y = @intCast(field_height / 2) };
    snake[1] = .{ .x = snake[0].x - 1, .y = snake[0].y };
    snake[2] = .{ .x = snake[0].x - 2, .y = snake[0].y };
    var direction = Direction.right;
    var food = Point{ .x = 3, .y = 3 };
    var random = @as(u32, @truncate(zdos.millis())) | 1;
    placeFood(&food, &snake, length, &random);

    var pixels: [screen_width * screen_height]u8 = undefined;
    var last_step = zdos.millis();
    var result: ?Result = null;

    while (result == null) {
        var events: u8 = 0;
        while (events < 16) : (events += 1) {
            const key = zdos.pollKey() orelse break;
            if (key.scan == zdos.Scan.esc) {
                api.gfx.end();
                return 0;
            }
            const ch: u8 = if (key.char <= 127) @intCast(key.char) else 0;
            const next: ?Direction = if (key.scan == zdos.Scan.up or ch == 'w' or ch == 'W') .up else if (key.scan == zdos.Scan.down or ch == 's' or ch == 'S') .down else if (key.scan == zdos.Scan.left or ch == 'a' or ch == 'A') .left else if (key.scan == zdos.Scan.right or ch == 'd' or ch == 'D') .right else null;
            if (next) |new_direction| {
                if (!isReverse(direction, new_direction)) direction = new_direction;
            }
        }

        const now = zdos.millis();
        if (now - last_step >= 163) {
            last_step = now;
            const head = snake[0];
            const next_head = switch (direction) {
                .up => Point{ .x = head.x, .y = head.y - 1 },
                .down => Point{ .x = head.x, .y = head.y + 1 },
                .left => Point{ .x = head.x - 1, .y = head.y },
                .right => Point{ .x = head.x + 1, .y = head.y },
            };

            if (next_head.x < 0 or next_head.x >= field_width_i32 or
                next_head.y < 0 or next_head.y >= field_height_i32)
            {
                result = .lose;
            } else {
                const eating = samePoint(next_head, food);
                var hit = false;
                for (snake[0..(if (eating) length else length - 1)]) |part| {
                    if (samePoint(next_head, part)) {
                        hit = true;
                        break;
                    }
                }
                if (hit) {
                    result = .lose;
                } else {
                    var i = length + @intFromBool(eating);
                    while (i > 1) {
                        i -= 1;
                        snake[i] = snake[i - 1];
                    }
                    snake[0] = next_head;
                    if (eating) {
                        length += 1;
                        if (length >= win_length) {
                            result = .win;
                        } else {
                            placeFood(&food, &snake, length, &random);
                        }
                    }
                }
            }
        }

        draw(&pixels, &snake, length, food);
        api.gfx.draw(pixels[0..].ptr);
        zdos.sleep(10);
    }

    api.gfx.end();
    if (result.? == .win) {
        zdos.print("You win! Snake reached 100. Press any key to quit.\n");
    } else {
        zdos.print("Game over! Press any key to quit.\n");
    }
    _ = zdos.readKey();
    return 0;
}

fn isReverse(current: Direction, next: Direction) bool {
    return switch (current) {
        .up => next == .down,
        .down => next == .up,
        .left => next == .right,
        .right => next == .left,
    };
}

fn samePoint(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn placeFood(food: *Point, snake: *const [max_length]Point, length: usize, random: *u32) void {
    random.* = random.* *% 1664525 +% 1013904223;
    var index: usize = 1 + @as(usize, random.*) % (max_length - 1);
    for (0..max_length) |_| {
        const candidate = Point{
            .x = @intCast(index % field_width),
            .y = @intCast(index / field_width),
        };
        var occupied = false;
        for (snake[0..length]) |part| {
            if (samePoint(candidate, part)) {
                occupied = true;
                break;
            }
        }
        if (!occupied) {
            food.* = candidate;
            return;
        }
        index = (index + 1) % max_length;
        if (index == 0) index = 1;
    }
}

fn draw(pixels: *[screen_width * screen_height]u8, snake: *const [max_length]Point, length: usize, food: Point) void {
    @memset(pixels, 0);
    for (0..field_height) |y| {
        for (0..field_width) |x| {
            fillCell(pixels, @intCast(x), @intCast(y), 1);
        }
    }
    fillCell(pixels, food.x, food.y, 3);
    for (snake[1..length]) |part| fillCell(pixels, part.x, part.y, 2);
    fillCell(pixels, snake[0].x, snake[0].y, 4);
}

fn fillCell(pixels: *[screen_width * screen_height]u8, x: i32, y: i32, color: u8) void {
    const px = field_left + @as(usize, @intCast(x)) * cell;
    const py = field_top + @as(usize, @intCast(y)) * cell;
    for (py..py + cell - 1) |row| {
        @memset(pixels[row * screen_width + px .. row * screen_width + px + cell - 1], color);
    }
}
