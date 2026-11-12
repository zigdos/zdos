const std = @import("std");

const math = std.math;
const ascii = std.ascii;
const deflate = std.compress.flate;

const hashing_util = @import("../../hashing.zig");

const format = @import("format.zig");

const version_needed_non64 = format.Version{ .vendor = .dos, .major = 2, .minor = 0 };
const version_needed_with64 = format.Version{ .vendor = .dos, .major = 4, .minor = 5 };

const Fifo = std.fifo.LinearFifo(u8, .{ .Static = 8192 });

const SinkVTable = struct {
    write: *const fn (*anyopaque, []const u8) anyerror!usize,
    get_pos: *const fn (*anyopaque) anyerror!u64,
    seek_by: *const fn (*anyopaque, i64) anyerror!void,
    seek_to: *const fn (*anyopaque, u64) anyerror!void,
};

const SinkContext = struct {
    const Self = @This();

    context: *anyopaque,
    vtable: *const SinkVTable,

    pub const Writer = std.io.Writer(*Self, anyerror, write);

    fn vtableFor(comptime SinkType: type) *const SinkVTable {
        return &struct {
            const table = SinkVTable{
                .write = writeSink,
                .get_pos = getSinkPos,
                .seek_by = seekSinkBy,
                .seek_to = seekSinkTo,
            };

            fn typed(context: *anyopaque) SinkType {
                return @ptrCast(@alignCast(context));
            }

            fn writeSink(context: *anyopaque, bytes: []const u8) anyerror!usize {
                return typed(context).writer().write(bytes);
            }

            fn getSinkPos(context: *anyopaque) anyerror!u64 {
                return typed(context).seekableStream().getPos();
            }

            fn seekSinkBy(context: *anyopaque, offset: i64) anyerror!void {
                return typed(context).seekableStream().seekBy(offset);
            }

            fn seekSinkTo(context: *anyopaque, position: u64) anyerror!void {
                return typed(context).seekableStream().seekTo(position);
            }
        }.table;
    }

    fn init(sink: anytype) Self {
        const SinkType = @TypeOf(sink);
        return .{
            .context = @ptrCast(sink),
            .vtable = vtableFor(SinkType),
        };
    }

    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }

    fn write(self: *Self, bytes: []const u8) anyerror!usize {
        return self.vtable.write(self.context, bytes);
    }

    fn getPos(self: *Self) anyerror!u64 {
        return self.vtable.get_pos(self.context);
    }

    fn seekBy(self: *Self, offset: i64) anyerror!void {
        return self.vtable.seek_by(self.context, offset);
    }

    fn seekTo(self: *Self, position: u64) anyerror!void {
        return self.vtable.seek_to(self.context, position);
    }

    fn seekableStream(self: *Self) *Self {
        return self;
    }
};

pub const ArchiveWriter = struct {
    sink: SinkContext,

    directory: std.ArrayListUnmanaged(format.CentralDirectoryRecord) = .{},
    extra_data: std.ArrayListUnmanaged(format.ExtraFieldZip64) = .{},
    filenames: std.ArrayListUnmanaged(u8) = .{},

    allocator: std.mem.Allocator,

    /// DOS { time, date } words written into the headers of the next entry.
    /// Set this before each writeSource / writeString call.
    last_mod: [2]u16 = .{ 0, 0 },

    pub fn init(allocator: std.mem.Allocator, sink: *std.io.StreamSource) ArchiveWriter {
        return initWithSink(allocator, sink);
    }

    pub fn initWithSink(allocator: std.mem.Allocator, sink: anytype) ArchiveWriter {
        return .{
            .allocator = allocator,
            .sink = SinkContext.init(sink),
        };
    }

    pub fn deinit(self: *ArchiveWriter) void {
        self.directory.deinit(self.allocator);
        self.filenames.deinit(self.allocator);
        self.extra_data.deinit(self.allocator);
    }

    pub fn finish(self: *ArchiveWriter) !void {
        const offset = try self.sink.getPos();
        for (self.directory.items, self.extra_data.items) |record, extra| {
            try record.write(self.sink.writer());

            const name = self.filenames.items[record.filename_idx..][0..record.filename_len];
            try self.sink.writer().writeAll(name);

            try extra.write(self.sink.writer());
        }

        const final_offset = try self.sink.getPos();
        const dir_size = final_offset - offset;

        const needs_entries64 = self.directory.items.len >= math.maxInt(u16);
        const needs_offset64 = offset >= math.maxInt(u32);
        const needs_size64 = dir_size >= math.maxInt(u32);

        var eocd = std.mem.zeroes(format.EndOfCentralDirectoryRecord);

        if (needs_entries64) {
            eocd.entries_on_disk = math.maxInt(u16);
            eocd.entries_total = math.maxInt(u16);
        } else {
            eocd.entries_on_disk = @truncate(self.directory.items.len);
            eocd.entries_total = @truncate(self.directory.items.len);
        }

        if (needs_size64) {
            eocd.directory_size = math.maxInt(u32);
        } else {
            eocd.directory_size = @truncate(dir_size);
        }

        if (needs_offset64) {
            eocd.directory_offset = math.maxInt(u32);
        } else {
            eocd.directory_offset = @truncate(offset);
        }

        if (needs_entries64 or needs_size64 or needs_offset64) {
            var eocd64 = std.mem.zeroes(format.EndOfCentralDirectory64Record);

            eocd64.size = 44;
            eocd64.version_made = version_needed_with64.write();
            eocd64.version_needed = version_needed_with64.write();
            eocd64.num_entries_disk = self.directory.items.len;
            eocd64.num_entries_total = self.directory.items.len;
            eocd64.directory_size = dir_size;
            eocd64.directory_offset = offset;

            try eocd64.write(self.sink.writer());

            var eocd64l = std.mem.zeroes(format.EndOfCentralDirectory64Locator);

            eocd64l.offset = final_offset;
            eocd64l.num_disks = 1;

            try eocd64l.write(self.sink.writer());
        }

        try eocd.write(self.sink.writer());
    }

    pub fn writeString(self: *ArchiveWriter, name: []const u8, str: []const u8, compress: bool) !void {
        const fbs = std.io.fixedBufferStream(str);

        var src = std.io.StreamSource{ .const_buffer = fbs };

        return self.writeSource(name, &src, compress);
    }

    pub fn writeSource(self: *ArchiveWriter, name: []const u8, src: anytype, compress: bool) !void {
        const BufferedWriter = std.io.BufferedWriter(8192, @TypeOf(self.sink.writer()));
        const HashingReader = hashing_util.HashingReader(@TypeOf(src.reader()), format.Crc32);
        var local = std.mem.zeroes(format.LocalFileRecord);

        local.last_mod_time = self.last_mod[0];
        local.last_mod_date = self.last_mod[1];

        local.compression_method = if (compress) .deflated else .none;

        local.filename_len = @truncate(name.len);

        const uncomp_size = try src.getEndPos();
        const local_offset = try self.sink.getPos();

        const need_size64 = uncomp_size >= math.maxInt(u32);
        const need_offset64 = local_offset >= math.maxInt(u32);

        var extra = format.ExtraFieldZip64{};

        if (need_size64) {
            local.version = version_needed_with64.write();

            extra.uncompressed = uncomp_size;
            extra.compressed = 0;
        } else {
            local.version = version_needed_non64.write();
        }

        local.extra_len = extra.length();

        try local.write(self.sink.writer());
        try self.sink.writer().writeAll(name);
        try extra.write(self.sink.writer());

        var hashing = HashingReader.init(src.reader());
        var buffered = BufferedWriter{ .unbuffered_writer = self.sink.writer() };
        var comp_size: u64 = 0;
        const data_offset = try self.sink.getPos();

        var fifo = Fifo.init();
        if (compress) {
            // ZDOS: the compressor (395 KiB) on the heap, made in place:
            // deflate.compressor() builds it on the stack, then copies
            const C = deflate.Compressor(@TypeOf(buffered.writer()));
            const compressor = try self.allocator.create(C);
            defer self.allocator.destroy(compressor);
            compressor.* = .{
                .wrt = buffered.writer(),
                .block_writer = @FieldType(C, "block_writer").init(buffered.writer()),
                .level = @FieldType(C, "level").get(.default),
            }; // raw deflate: no header to write

            try fifo.pump(hashing.reader(), compressor.writer());
            try compressor.finish();
        } else {
            try fifo.pump(hashing.reader(), buffered.writer());
            comp_size = uncomp_size;
        }

        try buffered.flush();
        if (compress) comp_size = (try self.sink.getPos()) - data_offset;

        const last_offset = try self.sink.getPos();

        if (need_size64) {
            extra.compressed = comp_size;

            local.uncompressed_size = math.maxInt(u32);
            local.compressed_size = math.maxInt(u32);
        } else {
            local.uncompressed_size = @intCast(uncomp_size);
            local.compressed_size = @intCast(comp_size);
        }

        local.crc32 = hashing.hash.final();

        try self.sink.seekableStream().seekTo(local_offset);

        try local.write(self.sink.writer());
        try self.sink.writer().writeAll(name);

        try extra.write(self.sink.writer());

        try self.sink.seekTo(last_offset);

        var entry = try self.directory.addOne(self.allocator);
        entry.* = std.mem.zeroes(format.CentralDirectoryRecord);

        entry.version_made = local.version;
        entry.version_needed = local.version;
        entry.flags = local.flags;
        entry.compression_method = local.compression_method;
        entry.last_mod_time = local.last_mod_time;
        entry.last_mod_date = local.last_mod_date;
        entry.crc32 = local.crc32;
        entry.compressed_size = local.compressed_size;
        entry.uncompressed_size = local.uncompressed_size;
        entry.filename_len = local.filename_len;
        entry.extra_len = local.extra_len;

        if (need_offset64) {
            extra.offset = local_offset;

            entry.version_made = version_needed_with64.write();
            entry.version_needed = version_needed_with64.write();

            entry.local_offset = math.maxInt(u32);
            entry.extra_len = extra.length();
        } else {
            entry.local_offset = @intCast(local_offset);
        }

        entry.filename_idx = self.filenames.items.len;
        try self.filenames.appendSlice(self.allocator, name);
        try self.extra_data.append(self.allocator, extra);
    }
};
