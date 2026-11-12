// By file extension only; unknown ones are downloads.
const std = @import("std");

const types = [_][2][]const u8{
    .{ "html", "text/html; charset=utf-8" },
    .{ "htm", "text/html; charset=utf-8" },
    .{ "css", "text/css; charset=utf-8" },
    .{ "js", "text/javascript; charset=utf-8" },
    .{ "mjs", "text/javascript; charset=utf-8" },
    .{ "json", "application/json" },
    .{ "xml", "application/xml" },
    .{ "txt", "text/plain; charset=utf-8" },
    .{ "md", "text/markdown; charset=utf-8" },
    .{ "csv", "text/csv; charset=utf-8" },
    .{ "cfg", "text/plain; charset=utf-8" },
    .{ "ini", "text/plain; charset=utf-8" },
    .{ "log", "text/plain; charset=utf-8" },
    .{ "wasm", "application/wasm" },
    .{ "pdf", "application/pdf" },
    .{ "png", "image/png" },
    .{ "jpg", "image/jpeg" },
    .{ "jpeg", "image/jpeg" },
    .{ "gif", "image/gif" },
    .{ "webp", "image/webp" },
    .{ "avif", "image/avif" },
    .{ "svg", "image/svg+xml" },
    .{ "ico", "image/x-icon" },
    .{ "bmp", "image/bmp" },
    .{ "tif", "image/tiff" },
    .{ "tiff", "image/tiff" },
    .{ "mp3", "audio/mpeg" },
    .{ "ogg", "audio/ogg" },
    .{ "oga", "audio/ogg" },
    .{ "wav", "audio/wav" },
    .{ "flac", "audio/flac" },
    .{ "opus", "audio/opus" },
    .{ "mid", "audio/midi" },
    .{ "mp4", "video/mp4" },
    .{ "m4v", "video/mp4" },
    .{ "webm", "video/webm" },
    .{ "ogv", "video/ogg" },
    .{ "avi", "video/x-msvideo" },
    .{ "mkv", "video/x-matroska" },
    .{ "woff", "font/woff" },
    .{ "woff2", "font/woff2" },
    .{ "ttf", "font/ttf" },
    .{ "otf", "font/otf" },
    .{ "zip", "application/zip" },
    .{ "gz", "application/gzip" },
    .{ "tgz", "application/gzip" },
    .{ "tar", "application/x-tar" },
    .{ "7z", "application/x-7z-compressed" },
    .{ "rar", "application/vnd.rar" },
    .{ "bz2", "application/x-bzip2" },
    .{ "xz", "application/x-xz" },
    .{ "zst", "application/zstd" },
    .{ "lz4", "application/x-lz4" },
};

pub const download = "application/octet-stream"; // exe, app, bin, img, iso ... and the unknown

pub fn of(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return download;
    const ext = name[dot + 1 ..];
    for (types) |t| {
        if (std.ascii.eqlIgnoreCase(t[0], ext)) return t[1];
    }
    return download;
}
