// TAR: tar archives
const std = @import("std");
const zdos = @import("zdos/zdos.zig");

comptime {
    _ = zdos;
}

const gzip = std.compress.gzip;

const Mode = enum { tar, gz, xz };

/// Last-resort mtime if neither the file nor the clock has a valid date.
/// std.time does not compile on freestanding targets.
const default_mtime: u64 = 0;

// FAT can only store 1980-01-01 .. 2107-12-31 23:59:58:
const fat_min_unix: u64 = 315532800;
const fat_max_unix: u64 = 4354819198;

const block_size = 512;

// zdos.File <-> std.io adapter:

const ZdosStream = struct {
    const Self = @This();

    file: zdos.File,
    position: u64 = 0,

    pub const Reader = std.io.Reader(*Self, anyerror, read);
    pub const Writer = std.io.Writer(*Self, anyerror, write);

    fn init(file: zdos.File) Self {
        return .{ .file = file };
    }

    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }

    pub fn writer(self: *Self) Writer {
        return .{ .context = self };
    }

    pub fn getEndPos(self: *Self) anyerror!u64 {
        return self.file.size();
    }

    fn read(self: *Self, bytes: []u8) anyerror!usize {
        const count = try self.file.read(bytes);
        self.position += count;
        return count;
    }

    fn write(self: *Self, bytes: []const u8) anyerror!usize {
        try self.file.writeAll(bytes);
        self.position += bytes.len;
        return bytes.len;
    }
};

// TIME: local time is stored as if it were UTC, as FAT has no zones

fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(month + 9, 12); // March = 0
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Null if the time is unknown or not a real date (year 0, month 0 ...).
fn unixFromTime(t: zdos.Time) ?u64 {
    if (t.year < 1970 or t.month < 1 or t.month > 12 or t.day < 1 or t.day > 31) return null;
    const days = daysFromCivil(t.year, t.month, t.day);
    const secs = days * 86400 + @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second;
    if (secs < 0) return null;
    return @intCast(secs);
}

/// Clamped to the range FAT can store.
fn timeFromUnix(unix: u64) zdos.Time {
    const secs = std.math.clamp(unix, fat_min_unix, fat_max_unix);
    const days: i64 = @intCast(secs / 86400);
    const rem: u64 = secs % 86400;

    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    const year = yoe + era * 400 + @as(i64, if (month <= 2) 1 else 0);

    return .{
        .year = @intCast(year),
        .month = @intCast(month),
        .day = @intCast(day),
        .hour = @intCast(rem / 3600),
        .minute = @intCast(rem % 3600 / 60),
        .second = @intCast(rem % 60),
    };
}

/// The file's own date, else the current clock.
fn tarTime(modified: zdos.Time) u64 {
    if (unixFromTime(modified)) |unix| return unix;
    return unixFromTime(zdos.getTime()) orelse default_mtime;
}

pub fn main(args: []const u8) u8 {
    var rest = trimSpaces(args);
    const command = nextToken(&rest);
    if (command.len == 0) return usage();

    var mode: ?Mode = null;
    while (rest.len > 0 and rest[0] == '-') {
        const flag = nextToken(&rest);
        if (std.ascii.eqlIgnoreCase(flag, "-gz")) {
            mode = .gz;
        } else if (std.ascii.eqlIgnoreCase(flag, "-xz")) {
            mode = .xz;
        } else {
            return usage();
        }
    }

    const path = withoutQuotes(trimSpaces(rest));
    if (path.len == 0) return usage();

    if (std.ascii.eqlIgnoreCase(command, "c")) {
        return compress(path, mode orelse .tar);
    }
    if (std.ascii.eqlIgnoreCase(command, "x")) {
        return extract(path, mode orelse detectMode(path));
    }
    return usage();
}

// Without its quotes, wherever they are ("My Folder"\Sub), as the
// shell removes them; a quote can't be part of a file name.
var unquoted_buf: [1024]u8 = undefined;
fn withoutQuotes(text: []const u8) []const u8 {
    var n: usize = 0;
    for (text) |c| {
        if (c == '"') continue;
        if (n == unquoted_buf.len) break;
        unquoted_buf[n] = c;
        n += 1;
    }
    return unquoted_buf[0..n];
}

fn usage() u8 {
    zdos.print("Usage: TAR C [-gz] <file-or-directory>\n");
    zdos.print("       TAR X [-gz|-xz] <archive>\n");
    zdos.print("Default is plain .tar. -xz can only be extracted.\n");
    return 1;
}

fn nextToken(rest: *[]const u8) []const u8 {
    const text = trimSpaces(rest.*);
    var end: usize = 0;
    while (end < text.len and !isSpace(text[end])) : (end += 1) {}
    rest.* = trimSpaces(text[end..]);
    return text[0..end];
}

/// Without a flag, guess from the extension.
fn detectMode(path: []const u8) Mode {
    if (endsWithIgnoreCase(path, ".tgz") or endsWithIgnoreCase(path, ".gz")) return .gz;
    if (endsWithIgnoreCase(path, ".txz") or endsWithIgnoreCase(path, ".xz")) return .xz;
    return .tar;
}

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    if (text.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

// COMPRESSION

const Root = struct {
    name: []const u8,
    path: []const u8,
    is_dir: bool,
    modified: zdos.Time,
};

const DirectoryEntry = struct {
    name: []u8,
    is_dir: bool,
    modified: zdos.Time,
};

fn compress(path: []const u8, mode: Mode) u8 {
    if (mode == .xz) {
        zdos.print("TAR: xz compression is not available in the Zig standard library; use -gz.\n");
        return 1;
    }
    compressPath(path, mode) catch |err| {
        zdos.printf("TAR: compress failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn extension(mode: Mode) []const u8 {
    return if (mode == .gz) ".tgz" else ".tar";
}

fn compressPath(path: []const u8, mode: Mode) !void {
    if (hasWildcard(path)) return compressMatches(path, mode);

    var cwd_buffer: [512]u8 = undefined;
    var source_path = trimTrailingSeparators(path);
    if (std.mem.eql(u8, source_path, ".")) source_path = zdos.getCwd(&cwd_buffer);

    const root_name = baseName(source_path);
    if (root_name.len == 0 or std.mem.eql(u8, root_name, ".") or std.mem.eql(u8, root_name, "..")) {
        return error.InvalidFileName;
    }

    const entry = try zdos.stat(source_path);

    const output_path = try std.fmt.allocPrint(zdos.allocator, "{s}{s}", .{ source_path, extension(mode) });
    defer zdos.allocator.free(output_path);

    const roots = [_]Root{.{ .name = root_name, .path = source_path, .is_dir = entry.is_dir, .modified = entry.modified }};
    try writeArchive(output_path, mode, &roots);
    zdos.printf("Created {s}\n", .{output_path});
}

fn compressMatches(pattern_path: []const u8, mode: Mode) !void {
    var split: ?usize = null;
    for (pattern_path, 0..) |char, index| {
        if (isSeparator(char)) split = index;
    }

    const directory_path = if (split) |index| pattern_path[0 .. index + 1] else ".";
    const pattern = if (split) |index| pattern_path[index + 1 ..] else pattern_path;
    if (pattern.len == 0 or hasWildcard(directory_path)) return error.InvalidPattern;

    const output_name = if (mode == .gz) "ARCHIVE.TGZ" else "ARCHIVE.TAR";
    const output_path = if (split != null)
        try joinPath(directory_path, output_name, '\\')
    else
        try zdos.allocator.dupe(u8, output_name);
    defer zdos.allocator.free(output_path);

    var roots: std.ArrayListUnmanaged(Root) = .{};
    defer {
        for (roots.items) |root| {
            zdos.allocator.free(root.name);
            zdos.allocator.free(root.path);
        }
        roots.deinit(zdos.allocator);
    }

    {
        const dir = try zdos.openDir(directory_path);
        defer dir.close();

        var entry: zdos.DirEntry = undefined;
        while (try dir.next(&entry)) {
            const name = entry.name();
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (!dosMatch(pattern, name)) continue;
            if (std.ascii.eqlIgnoreCase(name, "ARCHIVE.TAR")) continue;
            if (std.ascii.eqlIgnoreCase(name, "ARCHIVE.TGZ")) continue;

            const owned_name = try zdos.allocator.dupe(u8, name);
            const owned_path = joinPath(directory_path, name, '\\') catch |err| {
                zdos.allocator.free(owned_name);
                return err;
            };
            roots.append(zdos.allocator, .{ .name = owned_name, .path = owned_path, .is_dir = entry.is_dir, .modified = entry.modified }) catch |err| {
                zdos.allocator.free(owned_name);
                zdos.allocator.free(owned_path);
                return err;
            };
        }
    }

    if (roots.items.len == 0) return error.NoMatches;

    try writeArchive(output_path, mode, roots.items);
    zdos.printf("Created {s} ({d} matches)\n", .{ output_path, roots.items.len });
}

fn writeArchive(output_path: []const u8, mode: Mode, roots: []const Root) !void {
    if (!try shouldWrite(output_path)) {
        zdos.print("Skipped.\n");
        return;
    }

    const output = try zdos.open(output_path, .write);
    defer output.close();
    var sink = ZdosStream.init(output);

    switch (mode) {
        .tar => try writeTar(sink.writer(), roots),
        .gz => {
            // The deflate compressor (395 KiB) on the heap, made in
            // place: gzip.compressor() builds it on the stack, then
            // copies. Its gzip header as std writes it (container.zig):
            const Comp = gzip.Compressor(ZdosStream.Writer);
            const comp = try zdos.allocator.create(Comp);
            defer zdos.allocator.destroy(comp);
            comp.* = .{
                .wrt = sink.writer(),
                .block_writer = @FieldType(Comp, "block_writer").init(sink.writer()),
                .level = @FieldType(Comp, "level").get(.default),
            };
            try sink.writer().writeAll(&.{ 0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 });

            try writeTar(comp.writer(), roots);
            try comp.finish();
        },
        .xz => return error.XzCompressionUnsupported,
    }
}

fn writeTar(w: anytype, roots: []const Root) !void {
    for (roots) |root| {
        if (root.is_dir) {
            const dir_name = try std.fmt.allocPrint(zdos.allocator, "{s}/", .{root.name});
            defer zdos.allocator.free(dir_name);
            try writeHeader(w, dir_name, 0, '5', root.modified);
            try archiveDirectory(w, root.path, root.name);
        } else {
            try archiveFile(w, root.path, root.name, root.modified);
        }
    }

    // End-of-archive marker: two zero blocks:
    const zeros = [_]u8{0} ** block_size;
    try w.writeAll(&zeros);
    try w.writeAll(&zeros);
}

fn archiveFile(w: anytype, path: []const u8, entry_name: []const u8, modified: zdos.Time) !void {
    const file = try zdos.open(path, .read);
    defer file.close();
    var source = ZdosStream.init(file);

    const size = try source.getEndPos();
    try writeHeader(w, entry_name, size, '0', modified);

    var buffer: [1024]u8 = undefined;
    var remaining = size;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, @as(u64, buffer.len)));
        const got = try source.read(buffer[0..want]);
        if (got == 0) return error.UnexpectedEndOfFile;
        try w.writeAll(buffer[0..got]);
        remaining -= got;
    }

    const pad: usize = @intCast((block_size - size % block_size) % block_size);
    if (pad > 0) {
        const zeros = [_]u8{0} ** block_size;
        try w.writeAll(zeros[0..pad]);
    }
}

fn archiveDirectory(w: anytype, path: []const u8, relative_path: []const u8) !void {
    var entries: std.ArrayListUnmanaged(DirectoryEntry) = .{};
    defer {
        for (entries.items) |entry| zdos.allocator.free(entry.name);
        entries.deinit(zdos.allocator);
    }

    // The whole listing first, so only one directory handle is open:
    {
        const dir = try zdos.openDir(path);
        defer dir.close();

        var entry: zdos.DirEntry = undefined;
        while (try dir.next(&entry)) {
            const name = entry.name();
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;

            const owned_name = try zdos.allocator.dupe(u8, name);
            entries.append(zdos.allocator, .{ .name = owned_name, .is_dir = entry.is_dir, .modified = entry.modified }) catch |err| {
                zdos.allocator.free(owned_name);
                return err;
            };
        }
    }

    for (entries.items) |entry| {
        const child_path = try joinPath(path, entry.name, '\\');
        defer zdos.allocator.free(child_path);
        const child_relative = try joinPath(relative_path, entry.name, '/');
        defer zdos.allocator.free(child_relative);

        if (entry.is_dir) {
            const dir_name = try std.fmt.allocPrint(zdos.allocator, "{s}/", .{child_relative});
            defer zdos.allocator.free(dir_name);
            try writeHeader(w, dir_name, 0, '5', entry.modified);
            try archiveDirectory(w, child_path, child_relative);
        } else {
            try archiveFile(w, child_path, child_relative, entry.modified);
        }
    }
}

/// A POSIX ustar header.
fn writeHeader(w: anytype, name: []const u8, size: u64, typeflag: u8, modified: zdos.Time) !void {
    var name_part = name;
    var prefix_part: []const u8 = "";

    if (name.len > 100) {
        // Split at a '/' so that prefix <= 155 and name <= 100 bytes:
        var split: ?usize = null;
        for (name, 0..) |char, index| {
            if (char != '/') continue;
            if (index > 155) break;
            const remainder = name.len - index - 1;
            if (remainder == 0) break;
            if (remainder <= 100) {
                split = index;
                break;
            }
        }
        const index = split orelse return error.NameTooLong;
        prefix_part = name[0..index];
        name_part = name[index + 1 ..];
    }

    var header = [_]u8{0} ** block_size;
    @memcpy(header[0..name_part.len], name_part);
    try formatOctal(header[100..108], if (typeflag == '5') 0o755 else 0o644);
    try formatOctal(header[108..116], 0); // uid
    try formatOctal(header[116..124], 0); // gid
    try formatOctal(header[124..136], size);
    try formatOctal(header[136..148], tarTime(modified));
    @memset(header[148..156], ' '); // checksum placeholder
    header[156] = typeflag;
    @memcpy(header[257..263], "ustar\x00");
    @memcpy(header[263..265], "00");
    @memcpy(header[345 .. 345 + prefix_part.len], prefix_part);

    var sum: u32 = 0;
    for (header) |byte| sum += byte;
    try formatOctal(header[148..155], sum); // 6 digits + NUL
    header[155] = ' ';

    try w.writeAll(&header);
}

/// Zero-padded, NUL-terminated, filling the whole field.
fn formatOctal(field: []u8, value: u64) !void {
    var rest = value;
    var index = field.len - 1;
    field[index] = 0;
    while (index > 0) {
        index -= 1;
        field[index] = '0' + @as(u8, @intCast(rest & 7));
        rest >>= 3;
    }
    if (rest != 0) return error.ValueTooLarge;
}

// EXTRACTION

fn extract(path: []const u8, mode: Mode) u8 {
    extractArchive(path, mode) catch |err| {
        if (entry_len > 0) {
            zdos.printf("TAR: cannot extract {s}: {s}\n", .{ entry_buf[0..entry_len], @errorName(err) });
        } else zdos.printf("TAR: extract failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

// The entry being extracted, for the message
// when it fails (0: between entries)
var entry_buf: [512]u8 = undefined;
var entry_len: usize = 0;

fn noteEntry(name: []const u8) void {
    entry_len = @min(name.len, entry_buf.len);
    @memcpy(entry_buf[0..entry_len], name[0..entry_len]);
}

fn extractArchive(path: []const u8, mode: Mode) !void {
    const input = try zdos.open(path, .read);
    defer input.close();
    var source = ZdosStream.init(input);

    switch (mode) {
        .tar => try extractTar(source.reader()),
        .gz => {
            // The inflate state (74 KiB) on the heap, made in place:
            const Dec = gzip.Decompressor(@TypeOf(source.reader()));
            const dec = try zdos.allocator.create(Dec);
            defer zdos.allocator.destroy(dec);
            dec.* = .{ .bits = @FieldType(Dec, "bits").init(source.reader()) };
            try extractTar(dec.reader());
        },
        .xz => {
            var dec = try std.compress.xz.decompress(zdos.allocator, source.reader());
            defer dec.deinit();
            try extractTar(dec.reader());
        },
    }
}

fn extractTar(reader: anytype) !void {
    var name_buffer: [256]u8 = undefined;
    var link_buffer: [256]u8 = undefined;
    var it = std.tar.iterator(reader, .{
        .file_name_buffer = &name_buffer,
        .link_name_buffer = &link_buffer,
    });

    // Directory times at the end, or extracting into them
    // would change them again:
    var dirs: std.ArrayListUnmanaged(PendingTime) = .{};
    defer {
        for (dirs.items) |item| zdos.allocator.free(item.path);
        dirs.deinit(zdos.allocator);
    }

    // The iterator skips unread file data on next():
    while (try it.next()) |file| {
        // std.tar's File has no mtime, but the iterator keeps the raw header:
        const mtime = headerMtime(&it.header_buffer);
        noteEntry(file.name);
        try extractEntry(file, mtime, &dirs);
        entry_len = 0;
    }

    var index = dirs.items.len;
    while (index > 0) {
        index -= 1;
        applyTime(dirs.items[index].path, dirs.items[index].mtime);
    }
}

const PendingTime = struct {
    path: []u8,
    mtime: u64,
};

/// Bytes 136..148; 0 if unusable.
fn headerMtime(header: []const u8) u64 {
    const field = header[136..148];
    var end: usize = 0;
    while (end < field.len and field[end] >= '0' and field[end] <= '7') : (end += 1) {}
    if (end == 0) return 0;
    return std.fmt.parseInt(u64, field[0..end], 8) catch 0;
}

/// A failure is not worth aborting the extraction.
fn applyTime(path: []const u8, mtime: u64) void {
    if (mtime == 0) return;
    zdos.setFileTime(path, timeFromUnix(mtime)) catch {};
}

fn extractEntry(file: anytype, mtime: u64, dirs: *std.ArrayListUnmanaged(PendingTime)) !void {
    const output_path = (try safeTarPath(file.name)) orelse return;
    defer zdos.allocator.free(output_path);
    noteEntry(output_path);

    switch (file.kind) {
        .directory => {
            try createDirectories(output_path);
            const owned = try zdos.allocator.dupe(u8, output_path);
            dirs.append(zdos.allocator, .{ .path = owned, .mtime = mtime }) catch |err| {
                zdos.allocator.free(owned);
                return err;
            };
        },
        .file => {
            try createParentDirectories(output_path);
            if (!try shouldWrite(output_path)) {
                zdos.printf("Skipped {s}\n", .{output_path});
                return;
            }

            {
                const output = try zdos.open(output_path, .write);
                defer output.close();
                var sink = ZdosStream.init(output);

                const data = file.reader();
                var buffer: [1024]u8 = undefined;
                while (true) {
                    const got = try data.read(&buffer);
                    if (got == 0) break;
                    _ = try sink.write(buffer[0..got]);
                }
            }
            // After close: closing a written file
            // stamps it with the current time:
            applyTime(output_path, mtime);
            zdos.printf("Extracted {s}\n", .{output_path});
        },
        else => zdos.printf("Skipped link {s}\n", .{output_path}),
    }
}

/// Strips a drive, leading separators and "./", validates, and converts '/' to '\'. Null for
/// entries that refer to the extraction root itself.
fn safeTarPath(name: []const u8) !?[]u8 {
    var rest = stripAbsolute(name);
    while (rest.len >= 2 and rest[0] == '.' and isSeparator(rest[1])) rest = rest[2..];
    if (rest.len == 0 or (rest.len == 1 and rest[0] == '.')) return null;
    return try safeArchivePath(rest);
}

/// Absolute names ("/home/...", "C:\\...") are extracted relative:
/// their drive and leading separators go, with one warning.
fn stripAbsolute(name: []const u8) []const u8 {
    var rest = name;
    if (rest.len >= 2 and rest[1] == ':' and std.ascii.isAlphabetic(rest[0]) and
        (rest.len == 2 or isSeparator(rest[2]))) rest = rest[2..];
    while (rest.len > 0 and isSeparator(rest[0])) rest = rest[1..];
    if (rest.len != name.len and !warned_absolute) {
        warned_absolute = true;
        zdos.printf("{s}: absolute names, extracted relative: {s}\n", .{ "TAR", name });
    }
    return rest;
}
var warned_absolute = false;

fn safeArchivePath(name: []const u8) ![]u8 {
    if (name.len == 0 or isSeparator(name[0])) return error.UnsafeArchivePath;

    var component_start: usize = 0;
    for (name, 0..) |char, index| {
        if (char == 0) return error.UnsafeArchivePath;
        if (!isSeparator(char)) continue;

        const component = name[component_start..index];
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.UnsafeArchivePath;
        }
        component_start = index + 1;
    }

    if (component_start < name.len) {
        const component = name[component_start..];
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return error.UnsafeArchivePath;
    }

    const path_len = if (isSeparator(name[name.len - 1])) name.len - 1 else name.len;
    if (path_len == 0) return error.UnsafeArchivePath;

    // "a:b" would name drive A; ".\a:b" doesn't. Names
    // the drive's file system can't take fail there:
    const prefix: []const u8 = if (path_len >= 2 and name[1] == ':') ".\\" else "";
    const path = try zdos.allocator.alloc(u8, prefix.len + path_len);
    @memcpy(path[0..prefix.len], prefix);
    for (name[0..path_len], prefix.len..) |char, index| {
        path[index] = if (isSeparator(char)) '\\' else char;
    }
    return path;
}

fn createParentDirectories(path: []const u8) !void {
    for (path, 0..) |char, index| {
        if (char == '\\') try createDirectory(path[0..index]);
    }
}

fn createDirectories(path: []const u8) !void {
    try createParentDirectories(path);
    try createDirectory(path);
}

fn createDirectory(path: []const u8) !void {
    if (zdos.stat(path)) |existing| {
        if (!existing.is_dir) return error.PathConflict;
        return;
    } else |err| if (err != error.NotFound) return err;
    try zdos.makeDir(path);
}

/// True if `path` doesn't exist, or the user confirmed overwriting.
fn shouldWrite(path: []const u8) !bool {
    if (zdos.stat(path)) |existing| {
        if (existing.is_dir) return error.OutputIsDirectory;
        return confirmOverwrite(path);
    } else |err| if (err != error.NotFound) return err;
    return true;
}

fn confirmOverwrite(path: []const u8) bool {
    zdos.printf("Overwrite {s}? (Y/N) ", .{path});
    while (true) {
        const key = zdos.readKey();
        if (key.char == 'y' or key.char == 'Y') {
            zdos.print("Y\n");
            return true;
        }
        if (key.char == 'n' or key.char == 'N') {
            zdos.print("N\n");
            return false;
        }
    }
}

fn joinPath(parent: []const u8, child: []const u8, separator: u8) ![]u8 {
    if (parent.len == 0) return zdos.allocator.dupe(u8, child);
    const separator_text: []const u8 = if (isSeparator(parent[parent.len - 1])) "" else &.{separator};
    return std.fmt.allocPrint(zdos.allocator, "{s}{s}{s}", .{ parent, separator_text, child });
}

fn baseName(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |char, index| {
        if (isSeparator(char)) start = index + 1;
    }
    return path[start..];
}

fn hasWildcard(path: []const u8) bool {
    return std.mem.indexOfAny(u8, path, "*?") != null;
}

fn dosMatch(pattern: []const u8, name: []const u8) bool {
    var pattern_index: usize = 0;
    var name_index: usize = 0;
    var star_end: ?usize = null;
    var star_name_index: usize = 0;

    while (name_index < name.len) {
        if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            pattern_index += 1;
            star_end = pattern_index;
            star_name_index = name_index;
        } else if (pattern_index < pattern.len and
            (pattern[pattern_index] == '?' or std.ascii.toLower(pattern[pattern_index]) == std.ascii.toLower(name[name_index])))
        {
            pattern_index += 1;
            name_index += 1;
        } else if (star_end) |after_star| {
            pattern_index = after_star;
            star_name_index += 1;
            name_index = star_name_index;
        } else {
            return false;
        }
    }

    while (pattern_index < pattern.len and pattern[pattern_index] == '*') pattern_index += 1;
    return pattern_index == pattern.len;
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and isSeparator(path[end - 1])) {
        if (end == 3 and path[1] == ':') break;
        end -= 1;
    }
    return path[0..end];
}

fn trimSpaces(text: []const u8) []const u8 {
    var start: usize = 0;
    var end = text.len;
    while (start < end and isSpace(text[start])) : (start += 1) {}
    while (end > start and isSpace(text[end - 1])) : (end -= 1) {}
    return text[start..end];
}

fn isSpace(char: u8) bool {
    return char == ' ' or char == '\t';
}

fn isSeparator(char: u8) bool {
    return char == '/' or char == '\\';
}
