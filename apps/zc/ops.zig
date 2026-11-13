// Copy, move, make folder, delete.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const dialog = @import("dialog.zig");
const panel = @import("panel.zig");
const copy = @import("copy.zig");

const Panel = panel.Panel;

// The selected entries, else the one at the cursor (not ".."):
fn count(p: *Panel) usize {
    const n = p.selectedCount();
    if (n > 0) return n;
    const e = p.current() orelse return 0;
    return if (e.up) 0 else 1;
}

fn isTarget(p: *Panel, i: usize, any_selected: bool) bool {
    const e = p.entries.items[i];
    if (e.up) return false;
    return if (any_selected) e.selected else i == p.cursor;
}

// "name" or "N items":
fn what(p: *Panel, n: usize, buf: []u8) []const u8 {
    if (n == 1) {
        const any = p.selectedCount() > 0;
        for (p.entries.items, 0..) |e, i| {
            if (isTarget(p, i, any)) return std.fmt.bufPrint(buf, "\"{s}\"", .{p.name(e)}) catch "1 item";
        }
    }
    return std.fmt.bufPrint(buf, "{d} items", .{n}) catch "items";
}

fn failed(name: []const u8, err: zdos.Error) bool {
    return dialog.message("Error", &.{ name, zdos.message(err) }, true);
}

pub fn copyOrMove(src: *Panel, dst: *Panel, moving: bool) void {
    const n = count(src);
    if (n == 0) return;
    var what_buf: [800]u8 = undefined;
    var prompt_buf: [900]u8 = undefined;
    const title = if (moving) "Rename or move" else "Copy";
    const prompt = std.fmt.bufPrint(&prompt_buf, "{s} {s} to:", .{ if (moving) "Move" else "Copy", what(src, n, &what_buf) }) catch "To:";
    var typed_buf: [panel.max_path]u8 = undefined;
    const typed = dialog.input(title, prompt, dst.path(), &typed_buf) orelse return;
    const trimmed = std.mem.trim(u8, typed, " \t\"");
    if (trimmed.len == 0) return;
    // Relative to the source panel's folder:
    zdos.setCwd(src.path()) catch {};
    var target_buf: [panel.max_path]u8 = undefined;
    const target = zdos.fullPath(trimmed, &target_buf) catch |err| {
        _ = failed(trimmed, err);
        return;
    };
    const into_dir = if (zdos.stat(target)) |t| t.is_dir else |_| false;
    if (!into_dir and n > 1) {
        _ = dialog.message("Error", &.{ target, "is not a folder" }, true);
        return;
    }

    var job: copy.Job = .{ .moving = moving, .title = if (moving) "Move" else "Copy" };
    job.init();
    defer job.deinit();
    const any = src.selectedCount() > 0;
    dialog.status(job.title, &.{"Counting the files"});
    for (src.entries.items, 0..) |e, i| {
        if (!isTarget(src, i, any)) continue;
        var buf: [panel.max_path]u8 = undefined;
        const from = src.join(src.name(e), &buf) orelse continue;
        job.count(from, e.is_dir, e.size);
    }

    for (0..src.entries.items.len) |i| {
        if (job.stopped) break;
        if (!isTarget(src, i, any)) continue;
        const e = &src.entries.items[i];
        const name = src.name(e.*);
        var from_buf: [panel.max_path]u8 = undefined;
        var to_buf: [panel.max_path]u8 = undefined;
        const from = src.join(name, &from_buf) orelse continue;
        const to = if (into_dir) (panel.joinPath(target, name, &to_buf) orelse continue) else target;
        if (std.ascii.eqlIgnoreCase(from, to) and !moving) continue;
        if (e.is_dir and copy.inside(from, to)) {
            if (!dialog.message("Error", &.{ name, "can't go into itself" }, true)) break;
            continue;
        }
        const done = if (moving) job.move(from, to, e.is_dir) else job.copy(from, to, e.is_dir);
        if (done) e.selected = false;
    }
    src.load(null);
    dst.load(null);
}

pub fn makeFolder(p: *Panel) void {
    var name_buf: [768]u8 = undefined;
    const typed = dialog.input("Make folder", "Folder name:", "", &name_buf) orelse return;
    const name = std.mem.trim(u8, typed, " \t\"");
    if (name.len == 0) return;
    var buf: [panel.max_path]u8 = undefined;
    const path = p.join(name, &buf) orelse return;
    zdos.makeDir(path) catch |err| {
        _ = failed(name, err);
        return;
    };
    p.load(name);
}

pub fn delete(p: *Panel) void {
    const n = count(p);
    if (n == 0) return;
    var what_buf: [800]u8 = undefined;
    var line_buf: [900]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "Delete {s}?", .{what(p, n, &what_buf)}) catch "Delete?";
    if (!dialog.confirm("Delete", &.{line}, true)) return;
    const any = p.selectedCount() > 0;
    for (0..p.entries.items.len) |i| {
        if (!isTarget(p, i, any)) continue;
        const e = p.entries.items[i];
        const name = p.name(e);
        var buf: [panel.max_path]u8 = undefined;
        const path = p.join(name, &buf) orelse continue;
        dialog.status("Delete", &.{name});
        const result = if (e.is_dir) zdos.deleteTree(path) else zdos.delete(path);
        result catch |err| {
            if (!failed(name, err)) break;
        };
    }
    p.load(null);
}
