// Loads and runs .APP programs, one at a time, each on
// its own stack; control returns to whoever started it.
// An .APP is a flat PIE linked at 0: loaded anywhere,
// .bss zeroed, relocated, entered with a Start record.
// .ZDL and .SYS are the same format with their own
// magic numbers (loadImage).
const std = @import("std");
const builtin = @import("builtin");
const platform = @import("../platform.zig");
const arch = @import("../arch.zig");
const fs = @import("fs.zig");
const perm = @import("perm.zig");
const api = @import("api.zig");
const tasks = @import("tasks.zig");
const abi = @import("abi.zig");
const env = @import("env.zig");
const path_list = @import("path_list.zig");

// Must match sdk/linkers/app-*.ld, lib-*.ld, sys-*.ld.
// Each CPU's ZDOS loads only its own.
pub const magic: u32 = switch (builtin.cpu.arch) {
    .x86_64 => 0x3650415A, // "ZAP6"
    .x86 => 0x3350415A, // "ZAP3"
    .aarch64 => 0x4150415A, // "ZAPA"
    else => @compileError("no program format for this CPU"),
};
pub const library_magic: u32 = switch (builtin.cpu.arch) {
    .x86_64 => 0x364C445A, // "ZDL6"
    .x86 => 0x334C445A, // "ZDL3"
    .aarch64 => 0x414C445A, // "ZDLA"
    else => unreachable,
};
pub const driver_magic: u32 = switch (builtin.cpu.arch) {
    .x86_64 => 0x3659535A, // "ZSY6"
    .x86 => 0x3359535A, // "ZSY3"
    .aarch64 => 0x4159535A, // "ZSYA"
    else => unreachable,
};
const stack_size = platform.config.stacks.program;

// The first 48 bytes of the header, all the loader
// reads (the linker scripts also write code_end and
// ro_end after them; libraries and drivers more
// fields, read from the loaded image).
// Addresses are file offsets.
pub const Header = extern struct {
    magic: u32,
    version: u32, // the API version it needs (zdos_api_version, else 1)
    file_version: u32, // the file's own: a byte each, major.minor.patch.build (0: none)
    reserved: u32,
    entry: u64, // libraries: the export table; drivers: the start function
    end: u64, // end of code + data + .bss
    rela_start: u64, // relocation table (Elf64_Rela / Elf32_Rel entries)
    rela_end: u64,
};

// Static PIE needs only RELATIVE relocations (R_X86_64 / R_386:
// type 8, R_AARCH64: 1027): add the load address. 64-bit
// entries carry the addend; 32-bit
// (REL) ones find it at the target.
const Rela = switch (builtin.cpu.arch) {
    .x86_64, .aarch64 => extern struct {
        offset: u64,
        info: u64,
        addend: i64,
    },
    else => extern struct {
        offset: u32,
        info: u32,
    },
};
const r_relative: u64 = if (builtin.cpu.arch == .aarch64) 1027 else 8;

const max_size = 64 * 1024 * 1024;
// abi.Start.args; longer argument text is cut
pub const max_args = 4096;
// Nesting of programs started by programs, so one that starts
// itself can't use up all memory
const max_depth = 10;

pub const Result = union(enum) {
    exited: u8, // the program ran; its exit code
    not_found,
    not_program, // not a ZDOS program, or built for a newer ZDOS
    invalid, // damaged program file
    no_memory,
    failed: fs.Error, // the file could not be opened or read
    too_deep, // too many programs started by programs
};

// .CMD and .BAT are batch files; .APP or
// any other explicit extension a program
pub const Kind = enum { program, batch };

pub const Found = struct {
    drive: *fs.Drive,
    path: fs.Path = .{}, // absolute on the drive
    kind: Kind,
};

// Finds a command as COMMAND.APP does: without an extension
// tries .APP, .CMD, .BAT in that order; a name with a drive or
// folder only there, a plain name in the current directory,
// then in each PATH folder.
pub fn find(name: []const u8, out: *Found) bool {
    if (findIn(name, out)) return true;
    if (std.mem.indexOfAny(u8, name, ":\\/") != null) return false;
    const path_var = env.get("PATH") orelse return false;
    var it: path_list.Iterator = .{ .value = path_var };
    while (it.next()) |raw| {
        const dir = std.mem.trim(u8, raw, " \t");
        if (dir.len == 0) continue;
        var buf: [fs.max_path]u8 = undefined;
        const sep: []const u8 = if (dir[dir.len - 1] == '\\' or dir[dir.len - 1] == '/' or dir[dir.len - 1] == ':') "" else "\\";
        const full = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ dir, sep, name }) catch continue;
        if (findIn(full, out)) return true;
    }
    return false;
}

fn findIn(path: []const u8, out: *Found) bool {
    var d = tasks.world().drive orelse return false;
    var typed_buf: fs.TypedBuf = undefined;
    var name = fs.typedPath(path, &typed_buf);
    if (name.len >= 2 and name[1] == ':') {
        d = fs.driveByLetter(name[0]) orelse return false;
        name = name[2..];
    }
    var has_ext = false;
    for (name) |c| switch (c) {
        '.' => has_ext = true,
        '\\', '/' => has_ext = false,
        else => {},
    };
    if (has_ext) {
        const batch = std.ascii.endsWithIgnoreCase(name, ".CMD") or std.ascii.endsWithIgnoreCase(name, ".BAT");
        return check(d, name, if (batch) .batch else .program, out);
    }
    const kinds = [_]struct { ext: []const u8, kind: Kind }{
        .{ .ext = ".APP", .kind = .program },
        .{ .ext = ".CMD", .kind = .batch },
        .{ .ext = ".BAT", .kind = .batch },
    };
    for (kinds) |k| {
        var buf: [fs.max_path]u8 = undefined;
        const with_ext = std.fmt.bufPrint(&buf, "{s}{s}", .{ name, k.ext }) catch continue;
        if (check(d, with_ext, k.kind, out)) return true;
    }
    return false;
}

fn check(d: *fs.Drive, name: []const u8, kind: Kind, out: *Found) bool {
    var p: fs.Path = .{};
    fs.resolvePath(d, name, &p) catch return false;
    if ((fs.kindOf(d, &p) catch null) != .file and !(anyCase(d, &p) and (fs.kindOf(d, &p) catch null) == .file)) return false;
    out.* = .{ .drive = d, .path = p, .kind = kind };
    return true;
}

// Program names match in any case, even on
// case-sensitive file systems: the last part of p
// becomes the spelling found in its folder
fn anyCase(d: *fs.Drive, p: *fs.Path) bool {
    const base = fs.baseName(p);
    if (base.len == 0) return false;
    var folder = p.*;
    folder.pop();
    var it = fs.openDir(d, &folder) catch return false;
    defer it.close();
    while (it.next() catch return false) |e| {
        if (!std.ascii.eqlIgnoreCase(e.name(), base) or std.mem.eql(u8, e.name(), base)) continue;
        var found = folder;
        if (!found.append(e.name())) return false;
        p.* = found;
        return true;
    }
    return false;
}

// For exec and the command interpreter.
// Batch files are refused: the command
// interpreter runs those.
pub fn runPath(path: []const u8, args: []const u8) Result {
    var f: Found = undefined;
    if (!find(path, &f)) return .not_found;
    if (f.kind == .batch) return .not_program;
    return runFound(&f, args);
}

pub fn runFound(f: *const Found, args: []const u8) Result {
    return run(f.drive, f.path.slice(), args);
}

// A file of this format loaded and relocated, in pages of its own
pub const Image = struct {
    mem: [*]align(4096) u8,
    pages: usize,
    header: Header,
    // The header's first bytes as in the file: libraries' and
    // drivers' later fields, before relocation could change them
    raw: [80]u8 = undefined,

    // A u64 field of the raw header at byte offset at
    pub fn field(self: *const Image, at: usize) u64 {
        return std.mem.readInt(u64, self.raw[at..][0..8], .little);
    }

    pub fn base(self: *const Image) usize {
        return @intFromPtr(self.mem);
    }

    pub fn bytes(self: *const Image) []u8 {
        return self.mem[0 .. self.pages * 4096];
    }

    pub fn free(self: *const Image) void {
        platform.exec_protect.release(self.base(), self.base() + self.pages * 4096);
        platform.memory.freePages(self.mem, self.pages);
    }
};

pub const LoadError = error{ NotProgram, Invalid, NoMemory } || fs.Error;

// The file `name` on d with this magic number:
// read, .bss zeroed, relocated. A program needs run
// permission (an execute bit, root too); a library
// or driver only read permission, as shared
// libraries on Linux.
pub fn loadImage(d: *const fs.Drive, name: []const u8, want: u32) LoadError!Image {
    if (name.len <= fs.max_path) {
        var p: fs.Path = .{};
        p.set(name);
        if (want == magic) try perm.checkRun(d, &p) else try perm.check(d, &p, perm.read);
    }
    const file = try fs.openFile(d, name, .read);
    defer fs.close(file);
    const file_size = try platform.storage.size(file);

    var header: Header = undefined;
    if (file_size < @sizeOf(Header)) return error.NotProgram;
    try fs.readAll(file, std.mem.asBytes(&header));
    // Older programs run (groups only grow,
    // slots says how far); newer ones don't
    if (header.magic != want or header.version > abi.version) return error.NotProgram;
    const size = header.end;
    // entry: a library's export table may be in .bss (filled by its start)
    if (size < file_size or size > max_size or header.entry < @sizeOf(Header) or header.entry >= size or
        // An empty relocation table may point just past the end of the file
        header.rela_start > header.rela_end or (header.rela_end > header.rela_start and header.rela_end > file_size) or
        (header.rela_end - header.rela_start) % @sizeOf(Rela) != 0)
    {
        return error.Invalid;
    }

    const pages: usize = @intCast((size + 4095) / 4096);
    const mem = platform.memory.allocPages(pages, true) orelse return error.NoMemory;
    errdefer platform.memory.freePages(mem, pages);
    const image = mem[0 .. pages * 4096];
    @memcpy(image[0..@sizeOf(Header)], std.mem.asBytes(&header));
    const file_len: usize = @intCast(file_size); // <= size, checked above
    try fs.readAll(file, image[@sizeOf(Header)..file_len]);
    @memset(image[file_len..], 0); // .bss
    var raw: [80]u8 = @splat(0);
    const head = @min(raw.len, file_len);
    @memcpy(raw[0..head], image[0..head]);

    // Linked at 0: add the load address
    const base = @intFromPtr(mem);
    const relas = std.mem.bytesAsSlice(Rela, image[@intCast(header.rela_start)..@intCast(header.rela_end)]);
    for (relas) |r| {
        if (r.info != r_relative or r.offset > size - @sizeOf(usize)) return error.Invalid;
        const at = image[@intCast(r.offset)..][0..@sizeOf(usize)];
        const value = if (@hasField(Rela, "addend")) @as(usize, @bitCast(r.addend)) else std.mem.readInt(usize, at, .little);
        std.mem.writeInt(usize, at, base +% value, .little);
    }
    arch.syncCode(image);
    // Paged layout (code_end, ro_end after the header): its code
    // read and execute only (RW_NX=); a compact one has code there:
    // all of it executable and writable, as without RW_NX
    const code_end = std.mem.readInt(u64, raw[48..56], .little);
    const ro_end = std.mem.readInt(u64, raw[56..64], .little);
    const paged = code_end % 4096 == 0 and ro_end % 4096 == 0 and code_end >= 4096 and code_end <= ro_end and
        ro_end <= size and header.rela_start >= code_end;
    const code_to = if (paged) @as(usize, @intCast(code_end)) else image.len;
    if (!platform.exec_protect.code(base, base + code_to, paged)) return error.NoMemory;
    return .{ .mem = mem, .pages = pages, .header = header, .raw = raw };
}

fn run(d: *const fs.Drive, name: []const u8, args: []const u8) Result {
    if (tasks.world().depth >= max_depth) return .too_deep;
    const img = loadImage(d, name, magic) catch |err| return switch (err) {
        error.NotFound => .not_found,
        error.NotProgram => .not_program,
        error.Invalid => .invalid,
        error.NoMemory => .no_memory,
        else => |e| .{ .failed = e },
    };
    defer img.free();
    const header = img.header;
    const base = img.base();

    const stack = tasks.allocStack(stack_size) orelse return .no_memory;
    defer tasks.freeStack(stack, stack_size);

    var arg_buf: [max_args]u8 = undefined;
    const n = @min(args.len, arg_buf.len);
    @memcpy(arg_buf[0..n], args[0..n]);
    const start = api.start(arg_buf[0..n]);

    // The program's own record of open files
    // and memory, released when it ends
    var program: api.Program = .{};
    program.setPath(d.letter, name);
    api.begin(&program);
    tasks.world().depth += 1;
    const entry: *const anyopaque = @ptrFromInt(base + @as(usize, @intCast(header.entry)));
    // Ends with the entry function's return, or the
    // program's exit call (arch.exitTo). The program's own
    // code runs without the kernel lock (tasks.zig); back in
    // ZDOS it is taken again.
    _ = tasks.dropKernel();
    const thread_pointer = tasks.threadPointer(); // the program may set its own
    const code = arch.callOnStack(&start, entry, @intFromPtr(stack) + stack_size, &program.exit_saved);
    _ = tasks.enterKernel();
    tasks.setThreadPointer(thread_pointer);
    tasks.world().depth -= 1;
    api.end(&program);
    return .{ .exited = code };
}
