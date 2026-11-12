const std = @import("std");

pub fn mixin(comptime ReaderType: type, comptime SeekerType: type) type {
    const ReaderCtx = std.meta.fieldInfo(ReaderType, .context).type;
    const SeekerTypeCtx = std.meta.fieldInfo(SeekerType, .context).type;

    if (ReaderCtx != SeekerTypeCtx)
        @compileError("ReaderType and SeekerType must have the same context type");

    return struct {
        pub const BufferedReader = std.io.BufferedReader(8192, ReaderType);

        pub inline fn buffered(reader: ReaderType) BufferedReader {
            return BufferedReader{ .unbuffered_reader = reader };
        }

        pub fn seekBy(seeker: SeekerType, buffer: *BufferedReader, offset: i64) !void {
            if (offset == 0) return;

            const count = if (buffer.start > buffer.end)
                buffer.buf.len - buffer.start + buffer.end
            else
                buffer.end - buffer.start;
            const count_u64: u64 = @intCast(count);
            const buffer_len_u64: u64 = @intCast(buffer.buf.len);

            if (offset > 0) {
                const u_offset: u64 = @intCast(offset);

                if (u_offset <= count_u64) {
                    buffer.start += @intCast(u_offset);
                    if (buffer.start > buffer.buf.len)
                        buffer.start %= buffer.buf.len;
                } else if (u_offset <= count_u64 + buffer_len_u64) {
                    const left = u_offset - count_u64;

                    buffer.start = buffer.end;
                    try buffer.reader().skipBytes(left, .{ .buf_size = 8192 });
                } else {
                    const left = u_offset - count_u64;

                    buffer.start = buffer.end;
                    try seeker.seekBy(@intCast(left));
                }
            } else {
                const left = offset - @as(i64, @intCast(count));

                buffer.start = buffer.end;
                try seeker.seekBy(left);
            }
        }

        pub fn getPos(seeker: SeekerType, buffer: *BufferedReader) !u64 {
            const pos = try seeker.getPos();

            const count = if (buffer.start > buffer.end)
                buffer.buf.len - buffer.start + buffer.end
            else
                buffer.end - buffer.start;

            return pos - count;
        }

        pub fn seekTo(seeker: SeekerType, buffer: *BufferedReader, pos: u64) !void {
            const offset = @as(i64, @intCast(pos)) - @as(i64, @intCast(try getPos(seeker, buffer)));

            try seeker.seekBy(buffer, offset);
        }

        pub const LimitedReader = struct {
            unlimited_reader: BufferedReader.Reader,
            limit: u64,
            pos: u64 = 0,

            pub const Error = BufferedReader.Reader.Error;
            pub const Reader = std.io.Reader(*Self, Error, read);

            const Self = @This();

            pub fn init(unlimited_reader: BufferedReader.Reader, limit: u64) Self {
                return .{
                    .unlimited_reader = unlimited_reader,
                    .limit = limit,
                };
            }

            fn read(self: *Self, dest: []u8) Error!usize {
                if (self.pos >= self.limit) return 0;

                const available: u64 = @intCast(dest.len);
                const left: usize = @intCast(@min(self.limit - self.pos, available));
                const num_read = try self.unlimited_reader.read(dest[0..left]);
                self.pos += @intCast(num_read);

                return num_read;
            }

            pub fn reader(self: *Self) Reader {
                return .{ .context = self };
            }
        };
    };
}
