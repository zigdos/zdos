// ZIP: zip archives
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const archive = @import("vendor/zig-archive/src/main.zig");

comptime {
    _ = zdos;
}

const ZipWriter = archive.formats.zip.writer.ArchiveWriter;
const ZipReader = archive.formats.zip.reader.ArchiveReader;

const ZdosStream = struct {
    const Self = @This();

    file: zdos.File,
    position: u64 = 0,

    pub const Reader = std.io.Reader(*Self, anyerror, read);
    pub const Writer = std.io.Writer(*Self, anyerror, write);
    pub const SeekableStream = struct {
        context: *Self,

        pub fn getPos(stream: @This()) anyerror!u64 {
            return stream.context.position;
        }

        pub fn getEndPos(stream: @This()) anyerror!u64 {
            return stream.context.file.size();
        }

        pub fn seekBy(stream: @This(), offset: i64) anyerror!void {
            try stream.context.seekBy(offset);
        }

        pub fn seekTo(stream: @This(), position: u64) anyerror!void {
            try stream.context.seekTo(position);
        }
    };

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

    pub fn seekableStream(self: *Self) SeekableStream {
        return .{ .context = self };
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

    fn seekTo(self: *Self, position: u64) anyerror!void {
        try self.file.seek(position);
        self.position = position;
    }

    fn seekBy(self: *Self, offset: i64) anyerror!void {
        if (offset < 0) {
            const distance: u64 = @abs(offset);
            if (distance > self.position) return error.SeekFailed;
            return self.seekTo(self.position - distance);
        }

        const distance: u64 = @intCast(offset);
        if (distance > std.math.maxInt(u64) - self.position) return error.SeekFailed;
        return self.seekTo(self.position + distance);
    }
};

// DOS date/time words of zip headers:

fn validTime(t: zdos.Time) bool {
    return t.year >= 1 and t.month >= 1 and t.month <= 12 and t.day >= 1 and t.day <= 31 and
        t.hour < 24 and t.minute < 60 and t.second < 60;
}

/// { time, date }. An unknown time falls back to the current clock;
/// dates outside 1980..2107 are clamped.
fn dosWords(modified: zdos.Time) [2]u16 {
    var t = modified;
    if (!validTime(t)) {
        t = zdos.getTime();
        if (!validTime(t)) return .{ 0, 0x0021 }; // 1980-01-01 00:00:00
    }

    if (t.year < 1980) {
        t = .{ .year = 1980, .month = 1, .day = 1, .hour = 0, .minute = 0, .second = 0 };
    } else if (t.year > 2107) {
        t = .{ .year = 2107, .month = 12, .day = 31, .hour = 23, .minute = 59, .second = 58 };
    }

    const time_word: u16 = (@as(u16, t.second) >> 1) | (@as(u16, t.minute) << 5) | (@as(u16, t.hour) << 11);
    const date_word: u16 = @as(u16, t.day) | (@as(u16, t.month) << 5) | ((t.year - 1980) << 9);
    return .{ time_word, date_word };
}

/// Null if the entry has no real date.
fn timeFromDos(stamp: anytype) ?zdos.Time {
    if (stamp.month < 1 or stamp.month > 12 or stamp.day < 1 or stamp.day > 31) return null;
    if (stamp.hour > 23 or stamp.minute > 59 or stamp.second > 59) return null;
    return .{
        .year = stamp.year,
        .month = stamp.month,
        .day = stamp.day,
        .hour = stamp.hour,
        .minute = stamp.minute,
        .second = stamp.second,
    };
}

pub fn main(args: []const u8) u8 {
    const command_line = trimSpaces(args);
    var command_end: usize = 0;
    while (command_end < command_line.len and !isSpace(command_line[command_end])) : (command_end += 1) {}

    if (command_end == 0) return usage();

    const command = command_line[0..command_end];
    const path = withoutQuotes(trimSpaces(command_line[command_end..]));
    if (path.len == 0) return usage();
    if (std.ascii.eqlIgnoreCase(command, "c")) return compress(path);
    if (std.ascii.eqlIgnoreCase(command, "x")) return extract(path);
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
    zdos.print("Usage: ZIP C <file-or-directory> | X <archive.zip>\n");
    return 1;
}

fn compress(path: []const u8) u8 {
    compressFile(path) catch |err| {
        zdos.printf("ZIP: compress failed: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn compressFile(path: []const u8) !void {
    if (hasWildcard(path)) return compressMatches(path);

    var cwd_buffer: [512]u8 = undefined;
    var source_path = trimTrailingSeparators(path);
    if (std.mem.eql(u8, source_path, ".")) source_path = zdos.getCwd(&cwd_buffer);

    const root_name = baseName(source_path);
    if (root_name.len == 0 or std.mem.eql(u8, root_name, ".") or std.mem.eql(u8, root_name, "..")) {
        return error.InvalidFileName;
    }

    const entry = try zdos.stat(source_path);

    const output_path = try std.fmt.allocPrint(zdos.allocator, "{s}.zip", .{source_path});
    defer zdos.allocator.free(output_path);

    if (zdos.stat(output_path)) |existing| {
        if (existing.is_dir) return error.OutputIsDirectory;
        if (!confirmOverwrite(output_path)) {
            zdos.print("Skipped.\n");
            return;
        }
    } else |err| if (err != error.NotFound) return err;

    const output = try zdos.open(output_path, .write);
    defer output.close();
    var sink = ZdosStream.init(output);

    var zip = ZipWriter.initWithSink(zdos.allocator, &sink);
    defer zip.deinit();

    if (entry.is_dir) {
        const root_entry = try std.fmt.allocPrint(zdos.allocator, "{s}/", .{root_name});
        defer zdos.allocator.free(root_entry);
        try archiveDirectoryEntry(&zip, root_entry, entry.modified);
        try archiveDirectory(&zip, source_path, root_name);
    } else {
        try archiveFile(&zip, source_path, root_name, entry.modified);
    }
    try zip.finish();

    zdos.printf("Created {s}\n", .{output_path});
}

fn compressMatches(pattern_path: []const u8) !void {
    var split: ?usize = null;
    for (pattern_path, 0..) |char, index| {
        if (isSeparator(char)) split = index;
    }

    const directory_path = if (split) |index| pattern_path[0 .. index + 1] else ".";
    const pattern = if (split) |index| pattern_path[index + 1 ..] else pattern_path;
    if (pattern.len == 0 or hasWildcard(directory_path)) return error.InvalidPattern;

    const output_path = if (split != null)
        try joinPath(directory_path, "ARCHIVE.ZIP", '\\')
    else
        try zdos.allocator.dupe(u8, "ARCHIVE.ZIP");
    defer zdos.allocator.free(output_path);

    var matches: std.ArrayListUnmanaged(DirectoryEntry) = .{};
    defer {
        for (matches.items) |entry| zdos.allocator.free(entry.name);
        matches.deinit(zdos.allocator);
    }

    {
        const dir = try zdos.openDir(directory_path);
        defer dir.close();

        var entry: zdos.DirEntry = undefined;
        while (try dir.next(&entry)) {
            const name = entry.name();
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            if (!dosMatch(pattern, name)) continue;
            if (std.ascii.eqlIgnoreCase(name, "ARCHIVE.ZIP")) continue;

            const owned_name = try zdos.allocator.dupe(u8, name);
            matches.append(zdos.allocator, .{ .name = owned_name, .is_dir = entry.is_dir, .modified = entry.modified }) catch |err| {
                zdos.allocator.free(owned_name);
                return err;
            };
        }
    }

    if (matches.items.len == 0) return error.NoMatches;

    if (zdos.stat(output_path)) |existing| {
        if (existing.is_dir) return error.OutputIsDirectory;
        if (!confirmOverwrite(output_path)) {
            zdos.print("Skipped.\n");
            return;
        }
    } else |err| if (err != error.NotFound) return err;

    const output = try zdos.open(output_path, .write);
    defer output.close();
    var sink = ZdosStream.init(output);
    var zip = ZipWriter.initWithSink(zdos.allocator, &sink);
    defer zip.deinit();

    for (matches.items) |entry| {
        const child_path = try joinPath(directory_path, entry.name, '\\');
        defer zdos.allocator.free(child_path);

        if (entry.is_dir) {
            const directory_name = try std.fmt.allocPrint(zdos.allocator, "{s}/", .{entry.name});
            defer zdos.allocator.free(directory_name);
            try archiveDirectoryEntry(&zip, directory_name, entry.modified);
            try archiveDirectory(&zip, child_path, entry.name);
        } else {
            try archiveFile(&zip, child_path, entry.name, entry.modified);
        }
    }

    try zip.finish();
    zdos.printf("Created {s} ({d} matches)\n", .{ output_path, matches.items.len });
}

fn extract(path: []const u8) u8 {
    extractArchive(path) catch |err| {
        if (entry_len > 0) {
            zdos.printf("ZIP: cannot extract {s}: {s}\n", .{ entry_buf[0..entry_len], @errorName(err) });
        } else zdos.printf("ZIP: extract failed: {s}\n", .{@errorName(err)});
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

const PendingTime = struct {
    path: []u8,
    time: zdos.Time,
};

fn extractArchive(path: []const u8) !void {
    const input = try zdos.open(path, .read);
    defer input.close();
    var source = ZdosStream.init(input);
    var zip = ZipReader.initWithSource(zdos.allocator, &source);
    defer zip.deinit();

    // Directory times at the end, or extracting into them
    // would change them again:
    var dirs: std.ArrayListUnmanaged(PendingTime) = .{};
    defer {
        for (dirs.items) |item| zdos.allocator.free(item.path);
        dirs.deinit(zdos.allocator);
    }

    try zip.load();
    for (0..zip.directory.items.len) |index| {
        try extractEntry(&zip, zip.getHeader(index), &dirs);
        entry_len = 0;
    }

    var index = dirs.items.len;
    while (index > 0) {
        index -= 1;
        applyTime(dirs.items[index].path, dirs.items[index].time);
    }
}

/// A failure is not worth aborting the extraction.
fn applyTime(path: []const u8, time: zdos.Time) void {
    zdos.setFileTime(path, time) catch {};
}

fn extractEntry(zip: *ZipReader, header: anytype, dirs: *std.ArrayListUnmanaged(PendingTime)) !void {
    // RISC OS zips put the file type after a 0 ("!Run\x00feb"):
    const stored = header.filename;
    const full = stored[0 .. std.mem.indexOfScalar(u8, stored, 0) orelse stored.len];
    noteEntry(full);
    const is_directory = full.len > 0 and isSeparator(full[full.len - 1]);
    const name = stripAbsolute(full);
    // The root itself:
    if (name.len == 0) return;
    const output_path = try safeArchivePath(name);
    defer zdos.allocator.free(output_path);
    noteEntry(output_path);
    const modified = timeFromDos(header.last_mod);

    if (is_directory) {
        try createDirectories(output_path);
        if (modified) |time| {
            const owned = try zdos.allocator.dupe(u8, output_path);
            dirs.append(zdos.allocator, .{ .path = owned, .time = time }) catch |err| {
                zdos.allocator.free(owned);
                return err;
            };
        }
        return;
    }

    try createParentDirectories(output_path);
    if (zdos.stat(output_path)) |existing| {
        if (existing.is_dir) return error.OutputIsDirectory;
        if (!confirmOverwrite(output_path)) {
            zdos.printf("Skipped {s}\n", .{output_path});
            return;
        }
    } else |err| if (err != error.NotFound) return err;

    {
        const output = try zdos.open(output_path, .write);
        defer output.close();
        var sink = ZdosStream.init(output);
        try zip.extractFile(header, sink.writer(), true);
    }
    // After close: closing a written file stamps it with the current time:
    if (modified) |time| applyTime(output_path, time);
    zdos.printf("Extracted {s}\n", .{output_path});
}

fn archiveFile(zip: *ZipWriter, path: []const u8, entry_name: []const u8, modified: zdos.Time) !void {
    const file = try zdos.open(path, .read);
    defer file.close();
    var source = ZdosStream.init(file);
    zip.last_mod = dosWords(modified);
    try zip.writeSource(entry_name, &source, true);
}

fn archiveDirectoryEntry(zip: *ZipWriter, entry_name: []const u8, modified: zdos.Time) !void {
    zip.last_mod = dosWords(modified);
    try zip.writeString(entry_name, "", false);
}

const DirectoryEntry = struct {
    name: []u8,
    is_dir: bool,
    modified: zdos.Time,
};

fn archiveDirectory(zip: *ZipWriter, path: []const u8, relative_path: []const u8) !void {
    var entries: std.ArrayListUnmanaged(DirectoryEntry) = .{};
    defer {
        for (entries.items) |entry| zdos.allocator.free(entry.name);
        entries.deinit(zdos.allocator);
    }

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
            const directory_name = try std.fmt.allocPrint(zdos.allocator, "{s}/", .{child_relative});
            defer zdos.allocator.free(directory_name);
            try archiveDirectoryEntry(zip, directory_name, entry.modified);
            try archiveDirectory(zip, child_path, child_relative);
        } else {
            try archiveFile(zip, child_path, child_relative, entry.modified);
        }
    }
}

fn joinPath(parent: []const u8, child: []const u8, separator: u8) ![]u8 {
    if (parent.len == 0) return zdos.allocator.dupe(u8, child);
    const separator_text: []const u8 = if (isSeparator(parent[parent.len - 1])) "" else &.{separator};
    return std.fmt.allocPrint(zdos.allocator, "{s}{s}{s}", .{ parent, separator_text, child });
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
        zdos.printf("{s}: absolute names, extracted relative: {s}\n", .{ "ZIP", name });
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
