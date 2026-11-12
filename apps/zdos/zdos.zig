// The ZDOS program library for Zig: wrappers around the program
// interface and the entry point. System functions are in system.zig.
const std = @import("std");
const abi = @import("abi");

pub const version = abi.version;
pub const cc = abi.cc;
pub const Api = abi.Api;
pub const Key = abi.Key;
pub const Mod = abi.Mod;
pub const Scan = abi.Scan;
pub const Time = abi.Time;
pub const OpenMode = abi.OpenMode;
pub const seek_end = abi.seek_end;
pub const DriveInfo = abi.DriveInfo;
pub const Pos = abi.Pos;
pub const Color = abi.Color;
pub const DirEntry = abi.DirEntry;
pub const Attr = abi.Attr;
pub const FileSystem = abi.FileSystem;
pub const Permissions = abi.Permissions;
pub const StatEx = abi.StatEx;
pub const StatValid = abi.StatValid;
pub const ErrorCode = abi.ErrorCode;
pub const SystemInfo = abi.SystemInfo;
pub const DiskInfo = abi.DiskInfo;
pub const DiskLocation = abi.Location;
pub const CoreJob = abi.CoreJob;
pub const TaskInfo = abi.TaskInfo;
pub const TaskState = abi.TaskState;
pub const SpawnOptions = abi.SpawnOptions;
pub const TaskEnd = abi.TaskEnd;
pub const CpuTimes = abi.CpuTimes;
pub const WaitFlags = abi.WaitFlags;
pub const ThreadEntry = abi.ThreadEntry;
pub const Signal = abi.Signal;
pub const PollFd = abi.PollFd;
pub const Poll = abi.Poll;
pub const NetAddress = abi.NetAddress;
pub const NetInfo = abi.NetInfo;
// Libraries reach ZCRYPT.ZDL through this module.
pub const zcrypt = @import("zcrypt.zig");

// Connected when the program starts (entry).
var groups: Api = undefined;
var api: *const Api = &groups;

pub fn table() *const Api {
    return api;
}

// abi.ErrorCode as a Zig error.
pub const Error = error{
    NotFound,
    PathNotFound,
    AlreadyExists,
    AccessDenied,
    WriteProtected,
    DiskFull,
    TooManyOpen,
    InvalidHandle,
    OutOfMemory,
    InvalidName,
    DeviceError,
    NotSupported,
    NotADirectory,
    IsADirectory,
    DirNotEmpty,
    InvalidArgument,
    Interrupted,
    TimedOut,
    WouldBlock,
    BrokenPipe,
    NoChild,
    NetworkDown,
    InProgress,
    Already,
    AddressInUse,
    HostUnreachable,
    IsConnected,
    NotConnected,
    ConnectionRefused,
    ConnectionReset,
    ConnectionAborted,
    MessageTooLong,
    HostNotFound,
    NotASocket,
};

pub fn lastErrorCode() ErrorCode {
    return api.programs.last_error();
}

pub fn lastError() Error {
    return errorOf(api.programs.last_error());
}

pub fn errorOf(code: ErrorCode) Error {
    return switch (code) {
        .not_found => error.NotFound,
        .path_not_found => error.PathNotFound,
        .already_exists => error.AlreadyExists,
        .access_denied => error.AccessDenied,
        .write_protected => error.WriteProtected,
        .disk_full => error.DiskFull,
        .too_many_open => error.TooManyOpen,
        .invalid_handle => error.InvalidHandle,
        .out_of_memory => error.OutOfMemory,
        .invalid_name => error.InvalidName,
        .not_supported => error.NotSupported,
        .not_a_directory => error.NotADirectory,
        .is_a_directory => error.IsADirectory,
        .dir_not_empty => error.DirNotEmpty,
        .invalid_argument => error.InvalidArgument,
        .interrupted => error.Interrupted,
        .timed_out => error.TimedOut,
        .would_block => error.WouldBlock,
        .broken_pipe => error.BrokenPipe,
        .no_child => error.NoChild,
        .network_down => error.NetworkDown,
        .in_progress => error.InProgress,
        .already => error.Already,
        .address_in_use => error.AddressInUse,
        .host_unreachable => error.HostUnreachable,
        .is_connected => error.IsConnected,
        .not_connected => error.NotConnected,
        .connection_refused => error.ConnectionRefused,
        .connection_reset => error.ConnectionReset,
        .connection_aborted => error.ConnectionAborted,
        .message_too_long => error.MessageTooLong,
        .host_not_found => error.HostNotFound,
        .not_a_socket => error.NotASocket,
        else => error.DeviceError, // .device_error, and codes of a newer zdos
    };
}

pub fn check(ok: bool) Error!void {
    if (!ok) return lastError();
}

pub fn message(err: Error) []const u8 {
    const code: ErrorCode = switch (err) {
        error.NotFound => .not_found,
        error.PathNotFound => .path_not_found,
        error.AlreadyExists => .already_exists,
        error.AccessDenied => .access_denied,
        error.WriteProtected => .write_protected,
        error.DiskFull => .disk_full,
        error.TooManyOpen => .too_many_open,
        error.InvalidHandle => .invalid_handle,
        error.OutOfMemory => .out_of_memory,
        error.InvalidName => .invalid_name,
        error.DeviceError => .device_error,
        error.NotSupported => .not_supported,
        error.NotADirectory => .not_a_directory,
        error.IsADirectory => .is_a_directory,
        error.DirNotEmpty => .dir_not_empty,
        error.InvalidArgument => .invalid_argument,
        error.Interrupted => .interrupted,
        error.TimedOut => .timed_out,
        error.WouldBlock => .would_block,
        error.BrokenPipe => .broken_pipe,
        error.NoChild => .no_child,
        error.NetworkDown => .network_down,
        error.InProgress => .in_progress,
        error.Already => .already,
        error.AddressInUse => .address_in_use,
        error.HostUnreachable => .host_unreachable,
        error.IsConnected => .is_connected,
        error.NotConnected => .not_connected,
        error.ConnectionRefused => .connection_refused,
        error.ConnectionReset => .connection_reset,
        error.ConnectionAborted => .connection_aborted,
        error.MessageTooLong => .message_too_long,
        error.HostNotFound => .host_not_found,
        error.NotASocket => .not_a_socket,
    };
    return code.message();
}

pub fn print(str: []const u8) void {
    api.console.print(str.ptr, str.len);
}

pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    print(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

// The screen unless it was redirected (2>file), also while the output
// goes to a file or pipe.
pub fn printError(str: []const u8) void {
    api.console.print_error(str.ptr, str.len);
}

pub fn eprintf(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    printError(std.fmt.bufPrint(&buf, fmt, args) catch return);
}

pub fn readKey() Key {
    return api.console.read_key();
}

// The line, prompt included, starts at screen row row; null: done.
// Another task's output then goes there and readKey gives Scan.redraw.
pub fn editLine(row: ?u32) void {
    api.console.edit_line(if (row) |r| @intCast(r) else -1);
}

pub fn pollKey() ?Key {
    var key: Key = undefined;
    return if (api.console.poll_key(&key)) key else null;
}

pub fn alloc(size: usize) ?[*]align(16) u8 {
    return api.memory.alloc(size);
}

pub fn free(ptr: ?[*]align(16) u8) void {
    api.memory.free(ptr);
}

// Alignments above 16 bytes are not supported (allocation fails).
pub const allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &.{
    .alloc = heapAlloc,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
    .free = heapFree,
} };

fn heapAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    if (alignment.toByteUnits() > 16) return null;
    return api.memory.alloc(len);
}

fn heapFree(_: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
    api.memory.free(@alignCast(memory.ptr));
}

pub const File = struct {
    handle: i32,

    pub fn close(self: File) void {
        api.files.close(self.handle);
    }

    pub fn closeChecked(self: File) Error!void {
        api.files.close(self.handle);
        return check(api.programs.last_error() == .none);
    }

    pub fn read(self: File, buf: []u8) Error!usize {
        const n = api.files.read(self.handle, buf.ptr, buf.len);
        if (n < 0) return lastError();
        return @intCast(n);
    }

    pub fn write(self: File, data: []const u8) Error!usize {
        const n = api.files.write(self.handle, data.ptr, data.len);
        if (n < 0) return lastError();
        return @intCast(n);
    }

    pub fn writeAll(self: File, data: []const u8) Error!void {
        var done: usize = 0;
        while (done < data.len) {
            const n = try self.write(data[done..]);
            if (n == 0) return error.DiskFull;
            done += n;
        }
    }

    pub fn seek(self: File, pos: u64) Error!void {
        return check(api.files.seek(self.handle, pos));
    }

    pub fn setSize(self: File, new_size: u64) Error!void {
        return check(api.files.set_size(self.handle, new_size));
    }

    pub fn commit(self: File) Error!void {
        return check(api.files.commit(self.handle));
    }

    // As statEx; a pipe: S_IFIFO and its size.
    pub fn statEx(self: File) Error!StatEx {
        var x: StatEx = .{ .size = @sizeOf(StatEx) };
        try check(api.files.fstat_ex(self.handle, &x));
        return x;
    }

    pub fn setTime(self: File, time: Time) Error!void {
        return check(api.files.fset_time(self.handle, &time));
    }

    pub fn size(self: File) Error!u64 {
        const n = api.files.size(self.handle);
        if (n < 0) return lastError();
        return @intCast(n);
    }
};

pub fn open(path: []const u8, mode: OpenMode) Error!File {
    const h = api.files.open(path.ptr, path.len, mode);
    if (h < 0) return lastError();
    return .{ .handle = h };
}

pub fn delete(path: []const u8) Error!void {
    return check(api.files.delete_file(path.ptr, path.len));
}

// RANDOM BYTES: RDRAND / RNDR where present plus the cycle counter,
// through SHA-256 in counter mode (reading ARM's ID register needs
// ZDOS's privileges, which programs have now)
pub fn randomBytes(out: []u8) void {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var h = Sha256.init(.{});
    for (0..16) |_| {
        const r = hardwareRandom() orelse 0;
        const t = cycleCounter();
        h.update(std.mem.asBytes(&r));
        h.update(std.mem.asBytes(&t));
    }
    const ms = millis();
    h.update(std.mem.asBytes(&ms));
    const here = @intFromPtr(&h);
    h.update(std.mem.asBytes(&here));
    var key: [32]u8 = undefined;
    h.final(&key);
    var counter: u64 = 0;
    var done: usize = 0;
    while (done < out.len) : (counter += 1) {
        var block: [32]u8 = undefined;
        var b = Sha256.init(.{});
        b.update(&key);
        b.update(std.mem.asBytes(&counter));
        b.final(&block);
        const n = @min(block.len, out.len - done);
        @memcpy(out[done..][0..n], block[0..n]);
        done += n;
    }
    std.crypto.secureZero(u8, &key);
}

fn hardwareRandom() ?u64 {
    switch (@import("builtin").cpu.arch) {
        .x86_64 => {
            var ecx: u32 = undefined;
            asm volatile ("cpuid"
                : [c] "={ecx}" (ecx),
                : [leaf] "{eax}" (@as(u32, 1)),
                  [sub] "{ecx}" (@as(u32, 0)),
                : "ebx", "edx"
            );
            if (ecx & (1 << 30) == 0) return null; // no RDRAND
            for (0..10) |_| {
                var value: u64 = undefined;
                var ok: u8 = undefined;
                asm volatile ("rdrand %[v]; setc %[ok]"
                    : [v] "=r" (value),
                      [ok] "=r" (ok),
                );
                if (ok != 0) return value;
            }
            return null;
        },
        .x86 => {
            var ecx: u32 = undefined;
            asm volatile ("cpuid"
                : [c] "={ecx}" (ecx),
                : [leaf] "{eax}" (@as(u32, 1)),
                  [sub] "{ecx}" (@as(u32, 0)),
                : "ebx", "edx"
            );
            if (ecx & (1 << 30) == 0) return null;
            for (0..10) |_| {
                var value: u32 = undefined;
                var ok: u8 = undefined;
                asm volatile ("rdrand %[v]; setc %[ok]"
                    : [v] "=r" (value),
                      [ok] "=r" (ok),
                );
                if (ok != 0) return value;
            }
            return null;
        },
        .aarch64 => {
            const isar0 = asm volatile ("mrs %[r], ID_AA64ISAR0_EL1"
                : [r] "=r" (-> u64),
            );
            if ((isar0 >> 60) & 0xF == 0) return null; // no RNDR (the Pi 4 has none)
            for (0..10) |_| {
                var value: u64 = undefined;
                var ok: u64 = undefined;
                asm volatile ("mrs %[v], s3_3_c2_c4_0\n cset %[ok], ne"
                    : [v] "=r" (value),
                      [ok] "=r" (ok),
                );
                if (ok != 0) return value;
            }
            return null;
        },
        else => return null,
    }
}

fn cycleCounter() u64 {
    switch (@import("builtin").cpu.arch) {
        .x86_64, .x86 => {
            var lo: u32 = undefined;
            var hi: u32 = undefined;
            asm volatile ("rdtsc"
                : [lo] "={eax}" (lo),
                  [hi] "={edx}" (hi),
            );
            return @as(u64, hi) << 32 | lo;
        },
        .aarch64 => return asm volatile ("mrs %[r], cntvct_el0"
            : [r] "=r" (-> u64),
        ),
        else => return millis(),
    }
}

pub fn millis() u64 {
    return api.time.millis();
}

// From the CPU's counter (an older ZDOS: millis'), and its step.
pub fn nanos() u64 {
    return if (api.time.resolution() != 0) api.time.nanos() else api.time.millis() * 1_000_000;
}

pub fn clockResolution() u64 {
    const r = api.time.resolution();
    return if (r != 0) r else 1_000_000;
}

pub fn sleep(ms: u32) void {
    api.time.sleep(ms);
}

// Microseconds' precision on metal and BIOS; false if a signal ended it first.
pub fn sleepUntil(deadline: u64) bool {
    return api.time.nap_until(deadline) == 0;
}

pub fn getTime() Time {
    var t: Time = undefined;
    api.time.get(&t);
    return t;
}

pub const Dir = struct {
    handle: i32,

    pub fn next(self: Dir, e: *DirEntry) Error!bool {
        if (api.files.read_dir(self.handle, e)) return true;
        try check(api.programs.last_error() == .none); // the end, not an error
        return false;
    }

    // Null at the end.
    pub fn nextEx(self: Dir, info: *StatEx, name: []u8) Error!?[]const u8 {
        info.* = .{ .size = @sizeOf(StatEx) };
        const n = api.files.read_dir_ex(self.handle, info, name.ptr, name.len);
        if (n > 0) return name[0..n];
        try check(api.programs.last_error() == .none);
        return null;
    }

    pub fn close(self: Dir) void {
        api.files.close(self.handle);
    }
};

pub fn openDir(path: []const u8) Error!Dir {
    const h = api.files.open_dir(path.ptr, path.len);
    if (h < 0) return lastError();
    return .{ .handle = h };
}

pub fn setCtrlC(as_key: bool) void {
    api.programs.set_ctrl_c(as_key);
}

pub fn fullPath(path: []const u8, buf: []u8) Error![]const u8 {
    const n = api.files.full_path(path.ptr, path.len, buf.ptr, buf.len);
    if (n == 0) return lastError();
    return buf[0..n];
}

pub fn getCwd(buf: []u8) []const u8 {
    return buf[0..api.files.get_cwd(buf.ptr, buf.len)];
}

pub fn setCwd(path: []const u8) Error!void {
    return check(api.files.set_cwd(path.ptr, path.len));
}

pub fn getDrives(buf: *[26]u8) []const u8 {
    return buf[0..api.drives.letters(buf, buf.len)];
}

pub fn clearScreen() void {
    api.console.clear_screen();
}

pub fn setCursor(col: u32, row: u32) void {
    api.console.set_cursor(col, row);
}

pub fn getCursor() Pos {
    return api.console.get_cursor();
}

pub fn screenSize() Pos {
    return api.console.screen_size();
}

pub fn setColor(fg: Color, bg: Color) void {
    api.console.set_color(fg, bg);
}

pub fn showCursor(visible: bool) void {
    api.console.show_cursor(visible);
}

pub fn makeDir(path: []const u8) Error!void {
    return check(api.files.make_dir(path.ptr, path.len));
}

pub fn stat(path: []const u8) Error!DirEntry {
    var e: DirEntry = undefined;
    try check(api.files.stat(path.ptr, path.len, &e));
    return e;
}

// stat's and what Unix file systems add (StatValid says which).
pub fn statEx(path: []const u8) Error!StatEx {
    var x: StatEx = .{ .size = @sizeOf(StatEx) };
    try check(api.files.stat_ex(path.ptr, path.len, &x));
    return x;
}

pub fn driveInfo(letter: u8) Error!DriveInfo {
    var info: DriveInfo = undefined;
    try check(api.drives.info(letter, &info));
    return info;
}

// "FAT32", "ext2" ...; "" if unknown.
pub fn fileSystemName(kind: FileSystem) []const u8 {
    return switch (kind) {
        .fat12 => "FAT12",
        .fat16 => "FAT16",
        .fat32 => "FAT32",
        .mfs3 => "minix",
        .ext2 => "ext2",
        .ext3 => "ext3",
        .ext4 => "ext4",
        .zfs => "ZFS",
        .ntfs => "NTFS",
        .exfat => "exFAT",
        else => "",
    };
}

pub fn setAttributes(path: []const u8, attrs: u8) Error!void {
    return check(api.files.set_attributes(path.ptr, path.len, attrs));
}

// unix false: made up from the read-only attribute.
pub fn permissions(path: []const u8) Error!Permissions {
    var p: Permissions = undefined;
    try check(api.files.permissions(path.ptr, path.len, &p));
    return p;
}

// 0o7777 at most; without Unix permissions only "any write bit or none" counts.
pub fn setMode(path: []const u8, mode: u32) Error!void {
    return check(api.files.set_mode(path.ptr, path.len, mode));
}

// After a program copied src to dst itself, as files->copy sets them:
// src's where real (no setuid and the like), 0755 for an .APP from FAT,
// nothing on a FAT target.
pub fn copyMode(src: []const u8, dst: []const u8) void {
    const d = permissions(dst) catch return;
    if (!d.unix) return;
    const s = permissions(src) catch return;
    const mode: u32 = if (s.unix) s.mode & 0o777 else if (std.ascii.endsWithIgnoreCase(src, ".APP")) 0o755 else return;
    if (mode != d.mode & 0o777) setMode(dst, mode) catch {};
}

// Null leaves one as it is; NotSupported without Unix permissions.
pub fn setOwner(path: []const u8, uid: ?u32, gid: ?u32) Error!void {
    return check(api.files.set_owner(path.ptr, path.len, uid orelse abi.keep_id, gid orelse abi.keep_id));
}

pub fn readInput(buf: []u8) usize {
    return api.console.read_input(buf.ptr, buf.len);
}

pub fn inputRedirected() bool {
    return api.console.input_redirected();
}

pub fn outputRedirected() bool {
    return api.console.output_redirected();
}

// UEFI: the firmware's own FAT driver holds volumes, and keeps
// what it read of them until ZDOS restarts
pub fn onUefi() bool {
    var buf: [16]u8 = undefined;
    return std.ascii.eqlIgnoreCase(getVar("PLATFORM", &buf) orelse "", "UEFI");
}

pub fn getVar(name: []const u8, buf: []u8) ?[]const u8 {
    const n = api.programs.get_var(name.ptr, name.len, buf.ptr, buf.len);
    if (n < 0) return null;
    return buf[0..@min(@as(usize, @intCast(n)), buf.len)];
}

pub fn varAt(index: u32, buf: []u8) ?[]const u8 {
    const n = api.programs.var_at(index, buf.ptr, buf.len);
    if (n < 0) return null;
    return buf[0..@min(@as(usize, @intCast(n)), buf.len)];
}

pub fn deleteTree(path: []const u8) Error!void {
    return check(api.files.delete_tree(path.ptr, path.len));
}

pub fn copy(from: []const u8, to: []const u8) Error!void {
    return check(api.files.copy(from.ptr, from.len, to.ptr, to.len));
}

pub fn move(from: []const u8, to: []const u8) Error!void {
    return check(api.files.move(from.ptr, from.len, to.ptr, to.len));
}

pub fn exec(path: []const u8, args: []const u8) Error!u8 {
    const code = api.programs.exec(path.ptr, path.len, args.ptr, args.len);
    if (code < 0) return lastError();
    return @intCast(code);
}

// SYSTEM AND PROGRAMS

pub fn systemInfo() SystemInfo {
    var info: SystemInfo = undefined;
    api.programs.system_info(&info);
    return info;
}

// The user the program runs as, and changing it:
pub const Ids = abi.Ids;
pub const keep_id = abi.keep_id;
pub const keep_groups = abi.keep_groups;

pub fn getIds() Ids {
    var ids: Ids = undefined;
    api.programs.get_ids(&ids);
    return ids;
}

pub fn setIds(ids: Ids) Error!void {
    return check(api.programs.set_ids(&ids));
}

pub fn programPath(buf: []u8) []const u8 {
    return buf[0..api.programs.program_path(buf.ptr, buf.len)];
}

pub fn setFileTime(path: []const u8, time: Time) Error!void {
    return check(api.files.set_time(path.ptr, path.len, &time));
}

pub fn setVar(name: []const u8, value: []const u8) Error!void {
    return check(api.programs.set_var(name.ptr, name.len, value.ptr, value.len));
}

pub fn runCommand(line: []const u8) Error!u8 {
    const code = api.programs.run_command(line.ptr, line.len);
    if (code < 0) return lastError();
    return @intCast(code & 0xFF);
}

pub fn exit(code: u8) noreturn {
    api.programs.exit(code);
}

// \LIBS\NAME.ZDL's export table, loaded for this program, freed when it ends.
pub fn loadLibrary(name: []const u8) Error!*const anyopaque {
    return api.programs.load_library(name.ptr, name.len) orelse lastError();
}

// T: an extern struct starting with slots; slots an older library lacks
// fail with not_supported, as groups' do.
pub fn library(comptime T: type, name: []const u8) Error!*const T {
    const found: [*]const usize = @ptrCast(@alignCast(try loadLibrary(name)));
    const Copy = struct {
        var table: T = undefined;
        var done = false;
    };
    const want = abi.slotsOf(T);
    if (found[0] >= want) return @ptrCast(@alignCast(found));
    if (!Copy.done) {
        const words: [*]usize = @ptrCast(&Copy.table);
        words[0] = want;
        for (1..want + 1) |i| words[i] = if (i <= found[0]) found[i] else @intFromPtr(&notSupported);
        Copy.done = true;
    }
    return &Copy.table;
}

fn notSupported() callconv(cc) usize {
    return 0;
}

// Import stubs (sdk/README.md), listed by the linker:
const Import = extern struct {
    name: [*:0]const u8,
    table: *?*const anyopaque,
};
extern const __zdos_imports_start: Import;
extern const __zdos_imports_end: Import;

fn loadImports() bool {
    const first: [*]const Import = @ptrCast(&__zdos_imports_start);
    const count = (@intFromPtr(&__zdos_imports_end) - @intFromPtr(&__zdos_imports_start)) / @sizeOf(Import);
    for (first[0..count]) |imp| {
        const name = std.mem.sliceTo(imp.name, 0);
        imp.table.* = loadLibrary(name) catch {
            printError(name);
            printError(".ZDL: can't load the library\n");
            return false;
        };
    }
    return true;
}

fn connectAll(start: *const abi.Start) void {
    inline for (std.meta.fields(Api)) |f| {
        @field(groups, f.name) = connect(@typeInfo(f.type).pointer.child, start, f.name);
    }
}

// Each group is asked for by its name first.
fn entry(start: *const abi.Start) callconv(cc) u8 {
    connectAll(start);
    if (!loadImports()) return 1;
    fpuForZig();
    _ = tlsStart();
    return @import("root").main(start.args[0..start.args_len]);
}

// THREADLOCAL: the calling thread's block from the linker scripts' template,
// as zdos_tls.c (x86: below the pointer, which points to itself; ARM64:
// after 64 bytes). The start does it for the main thread;
// threadCreate's threads call it first. False without memory.
extern const __tdata_start: u8;
extern const __tdata_end: u8;
extern const __tbss_end: u8;
const tls_align = 64;

// 32-bit x86 (BIOS, no SSE): x87 rounding to double, as
// compiler-rt's math expects; at extended precision @sin, @cos ...
// come out wrong. Every task starts at extended; the start and
// tlsStart call this, a core job calls it first.
pub fn fpuForZig() void {
    if (@import("builtin").cpu.arch != .x86) return;
    const cw: u16 = 0x027F; // all exceptions masked, double precision, to nearest
    // In a register: an "m" input given a value is the memory of a pointer
    // to it, and fldcw loaded half a stack address:
    asm volatile ("fldcw (%[p])"
        :
        : [p] "r" (&cw),
        : "memory"
    );
}

pub fn tlsStart() bool {
    fpuForZig();
    const size = @intFromPtr(&__tbss_end) - @intFromPtr(&__tdata_start);
    if (size == 0) return true;
    const init = @intFromPtr(&__tdata_end) - @intFromPtr(&__tdata_start);
    const block = std.mem.alignForward(usize, size, tls_align);
    const m = allocator.alignedAlloc(u8, tls_align, block + tls_align) catch return false;
    const template: [*]const u8 = @ptrCast(&__tdata_start);
    var tp: usize = undefined;
    if (@import("builtin").cpu.arch == .aarch64) {
        @memset(m[0..tls_align], 0);
        @memcpy(m[tls_align..][0..init], template[0..init]);
        @memset(m[tls_align + init .. tls_align + size], 0);
        tp = @intFromPtr(m.ptr);
    } else {
        @memcpy(m[0..init], template[0..init]);
        @memset(m[init..block], 0);
        tp = @intFromPtr(m.ptr) + block;
        @as(*usize, @ptrFromInt(tp)).* = tp;
    }
    api.threads.set_thread_pointer(tp);
    return true;
}

// A Zig library (no main; it exports zdos_library): run once per load.
fn libraryInit(start: *const abi.Start) callconv(cc) bool {
    connectAll(start);
    return loadImports();
}

// Slots this ZDOS lacks fail with not_supported, so a newer program
// runs on an older ZDOS.
fn connect(comptime T: type, start: *const abi.Start, comptime name: []const u8) *const T {
    const Copy = struct {
        var group: T = undefined;
    };
    const want = abi.slotsOf(T);
    const found: ?[*]const usize = @ptrCast(@alignCast(start.group(name.ptr, name.len)));
    const have = if (found) |g| g[0] else 0;
    if (have >= want) return @ptrCast(@alignCast(found.?));
    const words: [*]usize = @ptrCast(&Copy.group);
    words[0] = want;
    for (1..want + 1) |i| words[i] = if (i <= have) found.?[i] else @intFromPtr(start.not_supported);
    return &Copy.group;
}

comptime {
    if (@hasDecl(@import("root"), "main")) {
        @export(&entry, .{ .name = "zdos_entry" });
    } else {
        @export(&libraryInit, .{ .name = "zdos_library_init" });
    }
    // e.g.: pub const zdos_file_version = [4]u8{ 2, 8, 0, 0 } in the root file:
    if (@hasDecl(@import("root"), "zdos_file_version")) asm (abi.fileVersionAsm(@import("root").zdos_file_version));
    // e.g.: pub const zdos_api_version: u32 = 2 in the root file (else 1):
    if (@hasDecl(@import("root"), "zdos_api_version")) asm (abi.apiVersionAsm(@import("root").zdos_api_version));
}
