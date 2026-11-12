// Shared by the build tools. Paths are relative to the source folder.
const std = @import("std");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
pub const gpa = arena.allocator();

pub fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ format ++ "\n", args);
    std.process.exit(1);
}

pub fn fmt(comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(gpa, format, args) catch fail("out of memory", .{});
}

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn commandLine() []const []const u8 {
    return std.process.argsAlloc(gpa) catch fail("out of memory", .{});
}

// cwd null: here. mkfs.fat's banner goes nowhere; a question from
// mtools fails instead of waiting.
pub fn runIn(cwd: ?[]const u8, argv: []const []const u8) void {
    var child = std.process.Child.init(argv, gpa);
    child.cwd = cwd;
    child.stdout_behavior = .Ignore;
    child.stdin_behavior = .Ignore;
    const term = child.spawnAndWait() catch |err| fail("can't run {s}: {s} (is it installed?)", .{ argv[0], @errorName(err) });
    if (term != .Exited or term.Exited != 0) fail("{s} failed", .{std.mem.join(gpa, " ", argv) catch argv[0]});
}

pub fn run(argv: []const []const u8) void {
    runIn(null, argv);
}

pub fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

pub fn read(path: []const u8) []u8 {
    return std.fs.cwd().readFileAlloc(gpa, path, 1 << 30) catch |err| fail("can't read {s}: {s}", .{ path, @errorName(err) });
}

pub fn write(path: []const u8, data: []const u8) void {
    if (std.fs.path.dirname(path)) |dir| makeDir(dir);
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = data }) catch |err| fail("can't write {s}: {s}", .{ path, @errorName(err) });
}

pub fn makeDir(path: []const u8) void {
    std.fs.cwd().makePath(path) catch |err| fail("can't make {s}: {s}", .{ path, @errorName(err) });
}

pub fn remove(path: []const u8) void {
    std.fs.cwd().deleteTree(path) catch |err| fail("can't remove {s}: {s}", .{ path, @errorName(err) });
}

// Makes the target folder if missing.
pub fn copy(from: []const u8, to: []const u8) void {
    if (std.fs.path.dirname(to)) |dir| makeDir(dir);
    std.fs.cwd().copyFile(from, std.fs.cwd(), to, .{}) catch |err| fail("can't copy {s} to {s}: {s}", .{ from, to, @errorName(err) });
}

// With subfolders; files there are replaced. Nothing if from is missing.
pub fn copyTree(from: []const u8, to: []const u8) void {
    copyTreeExcept(from, to, &.{});
}

// Leaving out the names skip at the top.
pub fn copyTreeExcept(from: []const u8, to: []const u8, skip: []const []const u8) void {
    if (!exists(from)) return;
    makeDir(to);
    names: for (list(from)) |name| {
        for (skip) |s| if (eql(name, s)) continue :names;
        const f = fmt("{s}/{s}", .{ from, name });
        const t = fmt("{s}/{s}", .{ to, name });
        if (isDir(f)) copyTree(f, t) else copy(f, t);
    }
}

// suffix "": all. Sorted by name; none if dir is missing.
pub fn inFolder(dir: []const u8, suffix: []const u8) []const []const u8 {
    if (!exists(dir)) return &.{};
    var paths = std.ArrayList([]const u8).init(gpa);
    for (list(dir)) |name| {
        if (std.mem.endsWith(u8, name, suffix)) paths.append(fmt("{s}/{s}", .{ dir, name })) catch fail("out of memory", .{});
    }
    return paths.items;
}

pub fn isDir(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    return stat.kind == .directory;
}

// Sorted.
pub fn list(dir: []const u8) []const []const u8 {
    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch |err| fail("can't open {s}: {s}", .{ dir, @errorName(err) });
    defer d.close();
    var names = std.ArrayList([]const u8).init(gpa);
    var it = d.iterate();
    while (it.next() catch |err| fail("can't read {s}: {s}", .{ dir, @errorName(err) })) |entry| {
        names.append(gpa.dupe(u8, entry.name) catch fail("out of memory", .{})) catch fail("out of memory", .{});
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    return names.items;
}
