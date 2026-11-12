// LABEL: shows or sets a drive's volume label
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const sys = @import("zdos/system.zig");

comptime {
    _ = zdos;
}

const usage = "Usage: LABEL X: [label]\n";

pub fn main(args: []const u8) u8 {
    const s = std.mem.trim(u8, args, " \t");
    if (s.len < 2 or s[1] != ':' or !std.ascii.isAlphabetic(s[0])) {
        zdos.print(usage);
        return 1;
    }
    const letter = std.ascii.toUpper(s[0]);
    const label = std.mem.trim(u8, s[2..], " \t");
    if (label.len > 0) return setLabel(letter, label);

    const info = zdos.driveInfo(letter) catch {
        zdos.printf("No drive {c}:\n", .{letter});
        return 1;
    };
    if (!info.ready) {
        zdos.printf("Drive {c}: has no readable disk\n", .{letter});
        return 1;
    }
    if (info.label_len == 0) {
        zdos.printf("Volume in drive {c} has no label\n", .{letter});
    } else {
        zdos.printf("Volume in drive {c} is {s}\n", .{ letter, info.label() });
    }
    zdos.print("Volume label (11 characters, ENTER for none)? ");
    var buf: [64]u8 = undefined;
    const answer = readLine(&buf);
    if (answer.len > 0) return setLabel(letter, answer);
    if (info.label_len == 0) return 0;
    zdos.print("Delete current volume label (Y/N)? ");
    const yes = readLine(&buf);
    if (!std.ascii.eqlIgnoreCase(yes, "y") and !std.ascii.eqlIgnoreCase(yes, "yes")) return 0;
    return setLabel(letter, "");
}

fn setLabel(letter: u8, label: []const u8) u8 {
    sys.setLabel(letter, label) catch |err| {
        if (err == error.InvalidName) {
            zdos.print("Invalid volume label: 11 characters at most, and none of\n* ? . , ; : / \\ | + = < > [ ] \"\n");
        } else {
            zdos.printf("Cannot set the label: {s}\n", .{zdos.message(err)});
        }
        return 1;
    };
    return 0;
}

fn readLine(buf: []u8) []const u8 {
    var n: usize = 0;
    while (true) {
        const key = zdos.readKey();
        if (key.char == '\r' or key.char == '\n') break;
        if (key.char == 0x08) {
            if (n > 0) {
                n -= 1;
                zdos.print("\x08 \x08");
            }
            continue;
        }
        if (key.char < 0x20 or key.char > 0x7E) continue;
        if (n < buf.len) {
            buf[n] = @intCast(key.char);
            n += 1;
            zdos.print(buf[n - 1 .. n]);
        }
    }
    zdos.print("\n");
    return std.mem.trim(u8, buf[0..n], " \t");
}
