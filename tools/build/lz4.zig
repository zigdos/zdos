// LZ4 block compression for the BIOS kernel (stage2.s unpacks it).
// Greedy, one hash table.
//   lz4 <in> <out>
const std = @import("std");

pub fn compress(alloc: std.mem.Allocator, in: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(alloc);
    const table = try alloc.alloc(u32, 1 << 16);
    defer alloc.free(table);
    @memset(table, std.math.maxInt(u32));
    var anchor: usize = 0;
    var i: usize = 0;
    // The last bytes stay literals, as LZ4 asks:
    const limit = if (in.len > 12) in.len - 12 else 0;
    while (i < limit) {
        const seq = std.mem.readInt(u32, in[i..][0..4], .little);
        const h: usize = @intCast((seq *% 2654435761) >> 16);
        const ref = table[h];
        table[h] = @intCast(i);
        if (ref != std.math.maxInt(u32) and i - ref <= 65535 and std.mem.readInt(u32, in[ref..][0..4], .little) == seq) {
            var len: usize = 4;
            while (i + len < in.len - 5 and in[ref + len] == in[i + len]) len += 1;
            try sequence(alloc, &out, in[anchor..i], @intCast(i - ref), len);
            i += len;
            anchor = i;
            continue;
        }
        i += 1;
    }
    // The last literals, with no match:
    const lit = in.len - anchor;
    try out.append(alloc, @as(u8, @intCast(@min(lit, 15))) << 4);
    if (lit >= 15) try length(alloc, &out, lit - 15);
    try out.appendSlice(alloc, in[anchor..]);
    return out.toOwnedSlice(alloc);
}

fn sequence(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), lit: []const u8, offset: u16, match: usize) !void {
    const m = match - 4;
    try out.append(alloc, (@as(u8, @intCast(@min(lit.len, 15))) << 4) | @as(u8, @intCast(@min(m, 15))));
    if (lit.len >= 15) try length(alloc, out, lit.len - 15);
    try out.appendSlice(alloc, lit);
    try out.append(alloc, @truncate(offset));
    try out.append(alloc, @truncate(offset >> 8));
    if (m >= 15) try length(alloc, out, m - 15);
}

// Past 15: bytes of 255, then the rest.
fn length(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), n: usize) !void {
    var left = n;
    while (left >= 255) : (left -= 255) try out.append(alloc, 255);
    try out.append(alloc, @intCast(left));
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const alloc = gpa.allocator();
    const args = try std.process.argsAlloc(alloc);
    if (args.len != 3) {
        std.debug.print("usage: lz4 <in> <out>\n", .{});
        std.process.exit(1);
    }
    const in = try std.fs.cwd().readFileAlloc(alloc, args[1], 64 << 20);
    const packed_data = try compress(alloc, in);
    try std.fs.cwd().writeFile(.{ .sub_path = args[2], .data = packed_data });
}
