const std = @import("std");

const math = std.math;
const ascii = std.ascii;
const deflate = std.compress.flate;

const hashing_util = @import("../../hashing.zig");
const HashingWriter = hashing_util.HashingWriter;

const format = @import("format.zig");

const SourceVTable = struct {
    read: *const fn (*anyopaque, []u8) anyerror!usize,
    get_pos: *const fn (*anyopaque) anyerror!u64,
    get_end_pos: *const fn (*anyopaque) anyerror!u64,
    seek_by: *const fn (*anyopaque, i64) anyerror!void,
    seek_to: *const fn (*anyopaque, u64) anyerror!void,
};

const SourceContext = struct {
    const Self = @This();

    context: *anyopaque,
    vtable: *const SourceVTable,

    pub const Reader = std.io.Reader(*Self, anyerror, read);
    pub const SeekableStream = struct {
        context: *Self,

        pub fn getPos(stream: @This()) anyerror!u64 {
            return stream.context.vtable.get_pos(stream.context.context);
        }

        pub fn getEndPos(stream: @This()) anyerror!u64 {
            return stream.context.vtable.get_end_pos(stream.context.context);
        }

        pub fn seekBy(stream: @This(), offset: i64) anyerror!void {
            return stream.context.vtable.seek_by(stream.context.context, offset);
        }

        pub fn seekTo(stream: @This(), position: u64) anyerror!void {
            return stream.context.vtable.seek_to(stream.context.context, position);
        }
    };

    fn vtableFor(comptime SourceType: type) *const SourceVTable {
        return &struct {
            const table = SourceVTable{
                .read = readSource,
                .get_pos = getSourcePos,
                .get_end_pos = getSourceEndPos,
                .seek_by = seekSourceBy,
                .seek_to = seekSourceTo,
            };

            fn typed(context: *anyopaque) SourceType {
                return @ptrCast(@alignCast(context));
            }

            fn readSource(context: *anyopaque, bytes: []u8) anyerror!usize {
                return typed(context).reader().read(bytes);
            }

            fn getSourcePos(context: *anyopaque) anyerror!u64 {
                return typed(context).seekableStream().getPos();
            }

            fn getSourceEndPos(context: *anyopaque) anyerror!u64 {
                return typed(context).getEndPos();
            }

            fn seekSourceBy(context: *anyopaque, offset: i64) anyerror!void {
                return typed(context).seekableStream().seekBy(offset);
            }

            fn seekSourceTo(context: *anyopaque, position: u64) anyerror!void {
                return typed(context).seekableStream().seekTo(position);
            }
        }.table;
    }

    fn init(source: anytype) Self {
        const SourceType = @TypeOf(source);
        return .{
            .context = @ptrCast(source),
            .vtable = vtableFor(SourceType),
        };
    }

    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }

    fn read(self: *Self, bytes: []u8) anyerror!usize {
        return self.vtable.read(self.context, bytes);
    }

    pub fn seekableStream(self: *Self) SeekableStream {
        return .{ .context = self };
    }
};

const BufferedSeekableSource = @import("../../seekable_buffered_stream.zig").mixin(
    SourceContext.Reader,
    SourceContext.SeekableStream,
);

pub const CentralDirectoryHeader = struct {
    version_made: format.Version,
    version_needed: format.Version,
    flags: format.GeneralPurposeBitFlag,
    compression_method: format.CompressionMethod,
    last_mod: format.DosTimestamp,

    crc32: u32,
    compressed_size: u64,
    uncompressed_size: u64,

    filename: []const u8,
    offset: u64,

    fn read(archive: anytype, rec: format.CentralDirectoryRecord) CentralDirectoryHeader {
        var header: CentralDirectoryHeader = undefined;

        header.version_made = format.Version.read(rec.version_made);
        header.version_needed = format.Version.read(rec.version_needed);
        header.flags = rec.flags;
        header.compression_method = rec.compression_method;
        header.last_mod = format.DosTimestamp.read(.{ rec.last_mod_time, rec.last_mod_date });

        header.crc32 = rec.crc32;
        header.compressed_size = rec.compressed_size;
        header.uncompressed_size = rec.uncompressed_size;

        header.filename = archive.readFilename(rec);
        header.offset = rec.local_offset;

        return header;
    }
};

fn lessThanCentralDirectoryRecord(buf: []const u8, a: format.CentralDirectoryRecord, b: format.CentralDirectoryRecord) bool {
    const a_name = buf[a.filename_idx..][0..a.filename_len];
    const b_name = buf[b.filename_idx..][0..b.filename_len];

    for (a_name, 0..) |a_ch, i| {
        if (i == b_name.len) return false;

        const b_ch = b_name[i];
        if (a_ch == '/' and b_ch != '/') return true;
        if (a_ch != '/' and b_ch == '/') return false;

        switch (math.order(ascii.toLower(a_ch), ascii.toLower(b_ch))) {
            .lt => return true,
            .gt => return false,
            .eq => continue,
        }
    }

    // we just need something consistent here, this shouldn't be possible
    return a.local_offset < b.local_offset;
}

pub const ArchiveReader = struct {
    source: SourceContext,

    directory: std.ArrayListUnmanaged(format.CentralDirectoryRecord) = .{},
    start_offset: u64 = 0,

    filename_buf: std.ArrayListUnmanaged(u8) = .{},

    directory_offset: u64 = 0,
    directory_size: u64 = 0,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: *std.io.StreamSource) ArchiveReader {
        return initWithSource(allocator, source);
    }

    pub fn initWithSource(allocator: std.mem.Allocator, source: anytype) ArchiveReader {
        return .{
            .allocator = allocator,
            .source = SourceContext.init(source),
        };
    }

    pub fn deinit(self: *ArchiveReader) void {
        self.directory.deinit(self.allocator);
        self.filename_buf.deinit(self.allocator);
    }

    /// Finds and reads the zip central directory. Expects a correct zip file.
    pub fn load(self: *ArchiveReader) !void {
        const reader = self.source.reader();
        const seeker = self.source.seekableStream();

        // theres no neat way to iterate backwards quickly, but buffering helps
        const buf = try self.allocator.alloc(u8, 1024);
        defer self.allocator.free(buf);

        try seeker.seekTo(try seeker.getEndPos());

        // Search from the end of the file to find the end of central directory record

        var eocd_offset: usize = 0;
        find_eocd: while (true) {
            const position = try seeker.getPos();
            if (position == 0) return error.NotAnArchive;
            try seeker.seekTo(if (position > 1021) position - 1021 else 0);

            const read = try reader.readAll(buf);
            if (read < 4) return error.NotAnArchive;

            eocd_offset = read - 4;
            while (eocd_offset >= 0) : (eocd_offset -= 1) {
                const signature = std.mem.readInt(u32, buf[eocd_offset..][0..4], .little);
                if (signature == format.EndOfCentralDirectoryRecord.signature) {
                    eocd_offset = read - eocd_offset;

                    break :find_eocd;
                }

                // prevent overflow
                if (eocd_offset == 0) continue :find_eocd;
            }
        }

        // pos - read + offset
        self.start_offset = (try seeker.getPos()) - eocd_offset;

        try seeker.seekTo(self.start_offset + 4);
        const eocd = try format.EndOfCentralDirectoryRecord.read(reader);

        var directory_size: u64 = eocd.directory_size;
        var directory_offset: u64 = eocd.directory_offset;
        var entries_total: u64 = eocd.entries_total;

        // Look for the zip64 end of central directory locator if we need to

        if (eocd.needs64()) {
            var offset: usize = 0;
            find_eocd64l: while (true) {
                const position = try seeker.getPos();
                if (position == 0) return error.InvalidArchive;
                try seeker.seekTo(if (position > 1021) position - 1021 else 0);

                const read = try reader.readAll(buf);

                offset = read - 4;
                while (offset >= 0) : (offset -= 1) {
                    const signature = std.mem.readInt(u32, buf[offset..][0..4], .little);
                    if (signature == format.EndOfCentralDirectory64Locator.signature) {
                        try seeker.seekBy(-@as(i64, @intCast(read - offset)) + 4);
                        break :find_eocd64l;
                    }

                    // prevent overflow
                    if (offset == 0) continue :find_eocd64l;
                }
            }

            const eocd64l = try format.EndOfCentralDirectory64Locator.read(reader);
            try seeker.seekTo(eocd64l.offset);

            self.start_offset = eocd64l.offset;

            const eocd64 = try format.EndOfCentralDirectory64Record.read(reader);

            if (eocd.directory_size == 0xffffffff) {
                directory_size = eocd64.directory_size;
            }

            if (eocd.directory_offset == 0xffffffff) {
                directory_offset = eocd64.directory_offset;
            }

            if (eocd.entries_total == 0xffff) {
                entries_total = eocd64.num_entries_total;
            }
        }

        self.directory_offset = directory_offset;
        self.directory_size = directory_size;

        // Begin loading central directory

        if (entries_total > std.math.maxInt(usize)) return error.InvalidArchive;
        if (entries_total > directory_size / 42) return error.InvalidArchive;
        const filename_capacity_u64 = directory_size - entries_total * 42;
        if (filename_capacity_u64 > std.math.maxInt(usize)) return error.InvalidArchive;

        self.start_offset -= directory_offset + directory_size;

        try self.directory.resize(self.allocator, @intCast(entries_total));
        try self.filename_buf.ensureTotalCapacity(self.allocator, @intCast(filename_capacity_u64));

        try seeker.seekTo(self.start_offset + directory_offset);

        var buffered = BufferedSeekableSource.buffered(reader);
        const buffered_reader = buffered.reader();

        for (self.directory.items) |*item| {
            item.* = try format.CentralDirectoryRecord.read(buffered_reader);

            item.filename_idx = self.filename_buf.items.len;
            self.filename_buf.items.len += item.filename_len;

            const nread = try buffered_reader.readAll(self.filename_buf.items[item.filename_idx..]);
            if (nread != item.filename_len) return error.EndOfStream;

            if (item.needs64()) {
                var pos: usize = 0;
                while (pos < item.extra_len) {
                    const header_id = try buffered_reader.readInt(u16, .little);
                    const data_len = try buffered_reader.readInt(u16, .little);
                    pos += 4;

                    if (header_id == 0x0001) {
                        const before = pos;

                        if (item.uncompressed_size == 0xffffffff) {
                            item.uncompressed_size = try buffered_reader.readInt(u64, .little);
                            pos += 8;
                        }

                        if (item.compressed_size == 0xffffffff) {
                            item.compressed_size = try buffered_reader.readInt(u64, .little);
                            pos += 8;
                        }

                        if (item.local_offset == 0xffffffff) {
                            item.local_offset = try buffered_reader.readInt(u64, .little);
                            pos += 8;
                        }

                        const nread64 = pos - before;
                        if (nread64 != data_len) {
                            try BufferedSeekableSource.seekBy(seeker, &buffered, @intCast(data_len - nread64));
                            pos += data_len - nread64;
                        }
                    } else {
                        try BufferedSeekableSource.seekBy(seeker, &buffered, data_len);
                        pos += data_len;
                    }
                }
            } else {
                try BufferedSeekableSource.seekBy(seeker, &buffered, item.extra_len);
            }

            try BufferedSeekableSource.seekBy(seeker, &buffered, item.comment_len);
        }

        self.filename_buf.shrinkAndFree(self.allocator, self.filename_buf.items.len);

        std.mem.sort(format.CentralDirectoryRecord, self.directory.items, self.filename_buf.items, lessThanCentralDirectoryRecord);
    }

    fn readFilename(self: ArchiveReader, item: format.CentralDirectoryRecord) []const u8 {
        return self.filename_buf.items[item.filename_idx..][0..item.filename_len];
    }

    /// Get the directory header at the given index.
    pub fn getHeader(
        self: ArchiveReader,
        index: usize,
    ) CentralDirectoryHeader {
        return CentralDirectoryHeader.read(self, self.directory.items[index]);
    }

    /// Get the directory header of a file with a given name.
    pub fn findFile(
        self: ArchiveReader,
        name: []const u8,
    ) ?CentralDirectoryHeader {
        for (self.directory.items, 0..) |item, i| {
            const filename = self.readFilename(item);
            if (std.mem.eql(u8, filename, name)) {
                return self.getHeader(i);
            }
        }
        return null;
    }

    /// Get the directory header of a file with a given name.
    ///
    /// Strips off the first `strip_components` components of the path in the
    /// archive before comparing.
    pub fn findFileInside(
        self: ArchiveReader,
        name: []const u8,
        strip_components: usize,
    ) ?CentralDirectoryHeader {
        find: for (self.directory.items, 0..) |item, i| {
            var filename = self.readFilename(item);

            var j: usize = 0;
            while (j < strip_components) : (j += 1) {
                const idx = std.mem.indexOf(u8, filename, "/") orelse continue :find;
                filename = filename[idx + 1 ..];
            }

            if (std.mem.eql(u8, filename, name)) {
                return self.getHeader(i);
            }
        }
    }

    /// Extracts the contents of an archived file and writes it into the given
    /// writer.
    pub fn extractFile(
        self: *ArchiveReader,
        header: CentralDirectoryHeader,
        writer: anytype,
        verify: bool,
    ) !void {
        if (header.uncompressed_size == 0) return;

        if (header.version_needed.major > 4) return error.UnsupportedVersion;
        if (header.version_needed.major == 4 and header.version_needed.minor > 5) return error.UnsupportedVersion;

        const reader = self.source.reader();
        const seeker = self.source.seekableStream();

        try seeker.seekTo(self.start_offset + header.offset);
        const local_header = try format.LocalFileRecord.read(reader);

        try seeker.seekBy(local_header.filename_len + local_header.extra_len);

        var buffered = BufferedSeekableSource.buffered(reader);
        const buffered_reader = buffered.reader();

        var fifo = std.fifo.LinearFifo(u8, .{ .Static = 8192 }).init();

        var limited = BufferedSeekableSource.LimitedReader.init(buffered_reader, header.compressed_size);
        const limited_reader = limited.reader();

        var hashing = HashingWriter(@TypeOf(writer), format.Crc32).init(writer);
        const hwriter = hashing.writer();

        switch (header.compression_method) {
            .none => {
                try fifo.pump(limited_reader, hwriter);
            },
            .deflated => {
                // This is not reusable, is there a reason for that?
                // ZDOS: the decompressor (74 KiB) on the heap, made in place
                const D = deflate.Decompressor(@TypeOf(limited_reader));
                const decompressor = try self.allocator.create(D);
                defer self.allocator.destroy(decompressor);
                decompressor.* = .{ .bits = @FieldType(D, "bits").init(limited_reader) };

                try fifo.pump(decompressor.reader(), hwriter);
            },
            else => return error.UnsupportedCompressionMethod,
        }

        if (verify) {
            if (hashing.hash.final() != header.crc32) return error.InvalidChecksum;
        }
    }

    /// Extracts the contents of an archived file and returns it as a string.
    ///
    /// The caller owns the returned memory.
    pub fn extractFileString(
        self: *ArchiveReader,
        header: CentralDirectoryHeader,
        alloc: std.mem.Allocator,
        verify: bool,
    ) ![]const u8 {
        const out = try alloc.alloc(u8, header.uncompressed_size);
        errdefer alloc.free(out);

        var stream = std.io.fixedBufferStream(out);

        try self.extractFile(header, stream.writer(), verify);

        return out;
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
