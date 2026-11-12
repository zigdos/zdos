// The program interface: groups of function tables every .APP
// can use, and their types. A program asks its Start record for
// each group by name; a group only grows (into its reserved
// slots, or at its end). sdk/src/zdos.h mirrors this file:
// change both together. Programs build against it, so it may
// import only std and builtin.
const std = @import("std");
const ver = @import("version.zig");

// The highest API version this ZDOS runs. Stays 1 until the
// release (the groups change in place); after it, groups only
// grow, and a group that must change incompatibly gets a new
// name. Must match sdk/src/zdos.h's ZDOS_SDK_API_VERSION
// and sdk/rust's API_VERSION.
pub const version: u32 = 1;

// The API version a file needs, at header byte 4
// (sdk/linkers/*.ld): the absolute symbol zdos_api_version;
// without it 1. A newer one than ZDOS has: not loaded.
pub fn apiVersionAsm(comptime v: u32) []const u8 {
    if (v < 1 or v > version) @compileError(std.fmt.comptimePrint("zdos_api_version {d}: this ZDOS has 1 to {d}", .{ v, version }));
    return std.fmt.comptimePrint(".globl zdos_api_version\n.set zdos_api_version, {d}\n", .{v});
}

// A file's own version, at header byte 8 (sdk/linkers/*.ld):
// the absolute symbol zdos_file_version,
// a byte each from major down to build
pub fn fileVersionAsm(comptime v: [4]u8) []const u8 {
    return std.fmt.comptimePrint(".globl zdos_file_version\n.set zdos_file_version, 0x{x:0>8}\n", .{std.mem.readInt(u32, &v, .big)});
}

// Spelled out because kernel (UEFI) and programs (freestanding)
// have different default conventions
pub const cc: std.builtin.CallingConvention = switch (@import("builtin").cpu.arch) {
    .x86_64 => .{ .x86_64_win = .{} },
    .x86 => .{ .x86_sysv = .{} },
    .aarch64 => .{ .aarch64_aapcs = .{} },
    else => @compileError("ZDOS programs exist for x86_64, x86 and aarch64 only"),
};

pub const Key = extern struct {
    scan: u16,
    char: u16,
    mods: u16,
    pad: u16 = 0,

    pub fn shift(self: Key) bool {
        return self.mods & Mod.shift != 0;
    }
    pub fn ctrl(self: Key) bool {
        return self.mods & Mod.ctrl != 0;
    }
    pub fn alt(self: Key) bool {
        return self.mods & Mod.alt != 0;
    }
    pub fn logo(self: Key) bool {
        return self.mods & Mod.logo != 0;
    }
};

pub const ScreenInfo = extern struct {
    width: u32,
    height: u32,
    true_color: bool,
    pad: [3]u8 = .{ 0, 0, 0 },
};

pub const ScreenSize = extern struct {
    width: u32,
    height: u32,
};

pub const KeyEvent = extern struct {
    code: u16,
    pressed: bool,
    repeat: bool,
    mods: u16,
    pad: u16 = 0,
};

pub const Mouse = extern struct {
    dx: i32,
    dy: i32,
    wheel: i32,
    buttons: u32,
};

pub const MouseButton = struct {
    pub const left = 1;
    pub const right = 2;
    pub const middle = 4;
};

pub const Mod = struct {
    pub const left_shift = 0x0001;
    pub const right_shift = 0x0002;
    pub const left_ctrl = 0x0004;
    pub const right_ctrl = 0x0008;
    pub const left_alt = 0x0010;
    pub const right_alt = 0x0020;
    pub const left_logo = 0x0040;
    pub const right_logo = 0x0080;
    pub const menu = 0x0100;
    pub const caps_lock = 0x1000;
    pub const num_lock = 0x2000;
    pub const scroll_lock = 0x4000;

    pub const shift = left_shift | right_shift;
    pub const ctrl = left_ctrl | right_ctrl;
    pub const alt = left_alt | right_alt;
    pub const logo = left_logo | right_logo;
};

// The UEFI scan codes; platform.Scan has the same values
pub const Scan = struct {
    pub const up = 0x01;
    pub const down = 0x02;
    pub const right = 0x03;
    pub const left = 0x04;
    pub const home = 0x05;
    pub const end = 0x06;
    pub const insert = 0x07;
    pub const delete = 0x08;
    pub const page_up = 0x09;
    pub const page_down = 0x0a;
    pub const f1 = 0x0b;
    pub const f10 = 0x14;
    pub const f11 = 0x15;
    pub const f12 = 0x16;
    pub const esc = 0x17;
    // Not a key: read_key's answer to a line editor (edit_line)
    // when another task wrote to the screen
    // over its line: show prompt and line again
    pub const redraw = 0xFE;
};

pub const Time = extern struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    pad: u8 = 0,
};

// ZDOS's own values, not errno
pub const ErrorCode = enum(u32) {
    none = 0,
    not_found = 1,
    path_not_found = 2,
    already_exists = 3,
    access_denied = 4,
    write_protected = 5,
    disk_full = 6,
    too_many_open = 7,
    invalid_handle = 8,
    out_of_memory = 9,
    invalid_name = 10,
    device_error = 11,
    not_supported = 12,
    not_a_directory = 13,
    is_a_directory = 14,
    dir_not_empty = 15,
    invalid_argument = 16,
    interrupted = 17, // a signal ended the wait
    timed_out = 18,
    would_block = 19, // it would have to wait, and wasn't to
    broken_pipe = 20, // writing with nobody left to read
    no_child = 21, // no task of this one's to wait for
    network_down = 22, // no network: NETWORK=false, or no card
    in_progress = 23, // connecting, without waiting for it
    already = 24, // a connect is already under way
    address_in_use = 25,
    host_unreachable = 26,
    is_connected = 27,
    not_connected = 28,
    connection_refused = 29,
    connection_reset = 30,
    connection_aborted = 31,
    message_too_long = 32,
    host_not_found = 33,
    not_a_socket = 34,
    _,

    pub fn message(self: ErrorCode) []const u8 {
        return switch (self) {
            .none => "No error",
            .not_found => "File not found",
            .path_not_found => "Path not found",
            .already_exists => "File already exists",
            .access_denied => "Access denied",
            .write_protected => "Disk is write-protected",
            .disk_full => "Disk full",
            .too_many_open => "Too many open files",
            .invalid_handle => "Invalid handle",
            .out_of_memory => "Not enough memory",
            .invalid_name => "Invalid name",
            .device_error => "Disk error",
            .not_supported => "Not supported",
            .not_a_directory => "Not a directory",
            .is_a_directory => "Is a directory",
            .dir_not_empty => "Directory not empty",
            .invalid_argument => "Invalid argument",
            .interrupted => "Interrupted",
            .timed_out => "Timed out",
            .would_block => "Would block",
            .broken_pipe => "Broken pipe",
            .no_child => "No child task",
            .network_down => "No network",
            .in_progress => "Connecting",
            .already => "Already connecting",
            .address_in_use => "Address in use",
            .host_unreachable => "Host unreachable",
            .is_connected => "Already connected",
            .not_connected => "Not connected",
            .connection_refused => "Connection refused",
            .connection_reset => "Connection reset",
            .connection_aborted => "Connection aborted",
            .message_too_long => "Message too long",
            .host_not_found => "Host not found",
            .not_a_socket => "Not a socket",
            _ => "Unknown error",
        };
    }
};

pub const OpenMode = enum(u32) {
    read = 0,
    write = 1,
    update = 2,
    _,
};

pub const seek_end = std.math.maxInt(u64);

pub const Attr = struct {
    pub const read_only = 0x01;
    pub const hidden = 0x02;
    pub const system = 0x04;
    pub const archive = 0x20;
    pub const all = read_only | hidden | system | archive;
};

// zdos.h needs update upon changing this:
pub const FileSystem = enum(u8) {
    unknown = 0,
    fat12 = 1,
    fat16 = 2,
    fat32 = 3,
    mfs3 = 4,
    ext2 = 5,
    ext3 = 6, // ext2 with a journal (ZDOS writes it only when the journal is clean)
    ext4 = 7,
    zfs = 8,
    ntfs = 9,
    exfat = 10,
    _,
};

pub const DriveInfo = extern struct {
    size: u64,
    free: u64,
    serial: u32,
    letter: u8,
    boot: bool,
    system: bool,
    hidden: bool,
    has_serial: bool,
    file_system: FileSystem,
    label_len: u8,
    label_buf: [64]u8,
    floppy: bool,
    ready: bool,
    // A partition no driver reads (never has a letter, not ready):
    // file_system and size say what it seems to hold
    unreadable: bool,
    removable: bool, // a USB stick, a card reader ... (UEFI); not ready: no disk
    block_size: u32, // bytes per cluster or block; 0 if unknown

    pub fn label(self: *const DriveInfo) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

pub const Pos = extern struct {
    col: u32,
    row: u32,
};

pub const Color = enum(u8) {
    black = 0,
    blue = 1,
    green = 2,
    cyan = 3,
    red = 4,
    magenta = 5,
    brown = 6,
    light_gray = 7,
    dark_gray = 8,
    light_blue = 9,
    light_green = 10,
    light_cyan = 11,
    light_red = 12,
    light_magenta = 13,
    yellow = 14,
    white = 15,
};

// drive_location: the volume's disk
// (disk_info index), first sector and length
pub const Location = extern struct {
    disk: u32,
    start: u64,
    sectors: u64,
};

pub const DiskInfo = extern struct {
    sectors: u64,
    sector_size: u32,
    removable: bool,
    read_only: bool,
};

pub const SystemInfo = extern struct {
    os_version: [4]u8 = ver.zdos,
    pad0: [4]u8 = .{ 0, 0, 0, 0 }, // x86 aligns u64 to 4: as zdos.h
    total_memory: u64,
    free_memory: u64,
    largest_free: u64,
    cpu_mhz: u32,
    cpu_name_len: u8,
    pad: [3]u8 = .{ 0, 0, 0 },
    cpu_name_buf: [128]u8,

    pub fn cpuName(self: *const SystemInfo) []const u8 {
        return self.cpu_name_buf[0..self.cpu_name_len];
    }
};
comptime {
    std.debug.assert(@offsetOf(SystemInfo, "total_memory") == 8);
}

// files->permissions: the type bits (S_IFMT) and permission
// bits (0o7777), owner and group. unix false: the file system
// has none (FAT); they are made up from the read-only
// attribute, owner and group 0.
pub const Permissions = extern struct {
    mode: u32,
    uid: u32,
    gid: u32,
    unix: bool,
    pad: [3]u8 = .{ 0, 0, 0 },
};

// files->set_owner: leaves the owner or the group as it is
pub const keep_id: u32 = std.math.maxInt(u32);

// programs->get_ids / set_ids: the user a program
// runs as (real: who started it; uid:
// whose rights it has; saved: what it may switch
// back to), its group and other groups.
// In set_ids keep_id leaves a value as it is,
// group_count keep_groups the groups.
pub const Ids = extern struct {
    real: u32,
    uid: u32,
    saved: u32,
    gid: u32,
    group_count: u32,
    groups: [16]u32,
};
pub const keep_groups: u32 = std.math.maxInt(u32);

// files->stat_ex, fstat_ex, read_dir_ex: stat's information and
// what Unix file systems add. The program sets size to
// @sizeOf(StatEx) as it was built; the kernel fills that many
// bytes at most and sets size to how many it filled. New fields
// go only at the end, so programs built before keep working
// (and see from size that they lack the new ones).
pub const StatEx = extern struct {
    size: u32,
    valid: u32 = 0, // StatValid bits: the fields the file system has
    flags: u32 = 0, // in: 0 (reserved for options such as not following a link)
    attrs: u32 = 0, // Attr bits
    mode: u32 = 0, // type and permission bits (S_IFMT, 07777); made up on FAT
    uid: u32 = 0,
    gid: u32 = 0,
    links: u32 = 0,
    drive: u32 = 0, // the drive letter, as st_dev
    is_dir: bool = false,
    pad: [3]u8 = .{ 0, 0, 0 },
    file_size: u64 = 0,
    ino: u64 = 0,
    blocks: u64 = 0, // 512-byte units in use
    // Year 0 if the file system doesn't keep it; changed: the
    // inode's last change (POSIX st_ctime)
    modified: Time = no_time,
    accessed: Time = no_time,
    created: Time = no_time,
    changed: Time = no_time,
};

pub const no_time: Time = .{ .year = 0, .month = 0, .day = 0, .hour = 0, .minute = 0, .second = 0 };

pub const StatValid = struct {
    pub const mode: u32 = 0x01; // the file system's mode, not one made up
    pub const owner: u32 = 0x02; // uid, gid
    pub const links: u32 = 0x04;
    pub const ino: u32 = 0x08;
    pub const blocks: u32 = 0x10;
};

// The fields every StatEx has: size, valid, flags
pub const stat_ex_min = 12;

comptime {
    std.debug.assert(@sizeOf(StatEx) == 96);
    std.debug.assert(@offsetOf(StatEx, "file_size") == 40);
}

pub const DirEntry = extern struct {
    name_buf: [768]u8,
    name_len: u16,
    is_dir: bool,
    attrs: u8,
    size: u64,
    modified: Time,
    created: Time,
    accessed: Time,

    pub fn name(self: *const DirEntry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

// Unused slots after each part of a group, so the part can grow
// without moving the ones after it: a new function takes the
// next reserved slot (and the reserve shrinks by one).
// They point to a function that fails
// with not_supported and returns 0.
pub const Reserved = *const fn () callconv(cc) usize;

// What a program's entry function gets: its arguments, a
// function that fails with not_supported and returns 0 (for
// slots this ZDOS lacks), and group, which gives the group of
// that name (an Api field name: "files" ...) or null. The start
// of every program: never changes.
pub const Start = extern struct {
    version: u32,
    args: [*]const u8,
    args_len: usize,
    not_supported: Reserved,
    group: *const fn (name: [*]const u8, len: usize) callconv(cc) ?*const anyopaque,
};

// Each group starts with slots: how many
// function pointers follow. A group grows into
// its reserved slots, or at its end (slots then
// grows), never by moving functions; a function
// whose arguments change gets a new slot.

// Text output, keys, standard input and
// output, the screen (group "console")
pub const ConsoleApi = extern struct {
    slots: usize,

    // CONSOLE AND KEYBOARD

    print: *const fn (str: [*]const u8, len: usize) callconv(cc) void,
    read_key: *const fn () callconv(cc) Key,
    poll_key: *const fn (key: *Key) callconv(cc) bool,
    // A line editor waits for keys with its line starting at
    // this screen row (prompt included; -1: done). Output of
    // other tasks then goes there, the line is cleared for it,
    // and read_key gives Scan.redraw: print the prompt and the
    // line again where the cursor is. Only for the task that
    // reads the keyboard.
    edit_line: *const fn (row: i32) callconv(cc) void,
    reserved_console: [3]Reserved,

    // STANDARD INPUT AND OUTPUT

    read_input: *const fn (buf: [*]u8, len: usize) callconv(cc) usize,
    input_redirected: *const fn () callconv(cc) bool,
    output_redirected: *const fn () callconv(cc) bool,
    // The error output (stream 2 of system.redirect): the screen
    // unless redirected, also while the output is
    print_error: *const fn (str: [*]const u8, len: usize) callconv(cc) void,
    error_redirected: *const fn () callconv(cc) bool,

    // SCREEN

    clear_screen: *const fn () callconv(cc) void,
    set_cursor: *const fn (col: u32, row: u32) callconv(cc) void,
    get_cursor: *const fn () callconv(cc) Pos,
    screen_size: *const fn () callconv(cc) Pos,
    set_color: *const fn (fg: Color, bg: Color) callconv(cc) void,
    show_cursor: *const fn (visible: bool) callconv(cc) void,
    reserved_screen: [4]Reserved,
};

// The heap (group "memory")
pub const MemoryApi = extern struct {
    slots: usize,

    // MEMORY

    alloc: *const fn (size: usize) callconv(cc) ?[*]align(16) u8,
    free: *const fn (ptr: ?[*]align(16) u8) callconv(cc) void,
    reserved_memory: [4]Reserved,
};

// Files, folders, copying, moving and deleting (group "files")
pub const FilesApi = extern struct {
    slots: usize,

    // FILES

    open: *const fn (path: [*]const u8, len: usize, mode: OpenMode) callconv(cc) i32,
    close: *const fn (handle: i32) callconv(cc) void,
    read: *const fn (handle: i32, buf: [*]u8, len: usize) callconv(cc) i64,
    write: *const fn (handle: i32, buf: [*]const u8, len: usize) callconv(cc) i64,
    seek: *const fn (handle: i32, pos: u64) callconv(cc) bool,
    size: *const fn (handle: i32) callconv(cc) i64,
    set_size: *const fn (handle: i32, size: u64) callconv(cc) bool,
    commit: *const fn (handle: i32) callconv(cc) bool,
    delete_file: *const fn (path: [*]const u8, len: usize) callconv(cc) bool,
    stat: *const fn (path: [*]const u8, len: usize, entry: *DirEntry) callconv(cc) bool,
    set_attributes: *const fn (path: [*]const u8, len: usize, attrs: u8) callconv(cc) bool,
    set_time: *const fn (path: [*]const u8, len: usize, time: *const Time) callconv(cc) bool,
    permissions: *const fn (path: [*]const u8, len: usize, out: *Permissions) callconv(cc) bool,
    // mode: 0o7777 at most (invalid_argument); without Unix
    // permissions only the write bits count (none: read only)
    set_mode: *const fn (path: [*]const u8, len: usize, mode: u32) callconv(cc) bool,
    // keep_id leaves one as it is; not_supported without Unix permissions
    set_owner: *const fn (path: [*]const u8, len: usize, uid: u32, gid: u32) callconv(cc) bool,
    // StatEx of a path, and of an open file (a pipe: S_IFIFO, its size)
    stat_ex: *const fn (path: [*]const u8, len: usize, info: *StatEx) callconv(cc) bool,
    fstat_ex: *const fn (handle: i32, info: *StatEx) callconv(cc) bool,
    // A pipe between tasks running at the same time (metal;
    // elsewhere its data waits as with create_pipe): handles[0]
    // reads, handles[1] writes. Reading waits for data while a
    // writer is left (0: the end); writing waits while 64 KiB are
    // unread, and with no reader left
    // fails (broken_pipe, and SIGPIPE).
    pipe: *const fn (handles: *[2]i32) callconv(cc) bool,
    // Another handle for the same open file,
    // pipe or folder (the position is shared); -1
    dup: *const fn (handle: i32) callconv(cc) i32,
    // Which of the handles are ready (PollFd.revents), waiting up
    // to timeout_ms (-1: no limit, 0: not at all); how many are, -1
    // (interrupted, invalid_argument)
    poll: *const fn (fds: [*]PollFd, count: u32, timeout_ms: i32) callconv(cc) i32,
    // set_time of an open file (futimens): the caller must be root,
    // have opened it for writing, or own it (Unix file systems)
    fset_time: *const fn (handle: i32, time: *const Time) callconv(cc) bool,
    // An event queue (Linux's epoll, kept as kqueue keeps its own):
    // a handle that watches sockets, pipe ends
    // and counters (QueueChange); flags: 0
    queue_create: *const fn (flags: u32) callconv(cc) i32,
    // Applies count changes to the queue's watches,
    // then gives up to max events (QueueEvent),
    // waiting up to timeout_ms for one (-1: no limit;
    // max 0: no wait): how many, or -1 (interrupted;
    // a change's error: invalid_handle,
    // already_exists, not_found, not_supported for a
    // handle that can't be watched, out_of_memory;
    // the changes before it stay). A watch goes when
    // its handle is closed.
    queue_events: *const fn (queue: i32, changes: ?[*]const QueueChange, count: u32, out: ?[*]QueueEvent, max: u32, timeout_ms: i32) callconv(cc) i32,
    reserved_files: [6]Reserved,

    // FOLDERS

    open_dir: *const fn (path: [*]const u8, len: usize) callconv(cc) i32,
    read_dir: *const fn (handle: i32, entry: *DirEntry) callconv(cc) bool,
    make_dir: *const fn (path: [*]const u8, len: usize) callconv(cc) bool,
    get_cwd: *const fn (buf: [*]u8, len: usize) callconv(cc) usize,
    set_cwd: *const fn (path: [*]const u8, len: usize) callconv(cc) bool,
    full_path: *const fn (path: [*]const u8, len: usize, buf: [*]u8, buf_len: usize) callconv(cc) usize,
    // The next entry's name into name (cut at a character boundary
    // to fit) and its StatEx; the name's length, 0 at the end
    // (last_error .none) or on an error
    read_dir_ex: *const fn (handle: i32, info: *StatEx, name: [*]u8, name_len: usize) callconv(cc) usize,
    reserved_folders: [2]Reserved,

    // COPYING, MOVING, DELETING

    copy: *const fn (from: [*]const u8, from_len: usize, to: [*]const u8, to_len: usize) callconv(cc) bool,
    move: *const fn (from: [*]const u8, from_len: usize, to: [*]const u8, to_len: usize) callconv(cc) bool,
    delete_tree: *const fn (path: [*]const u8, len: usize) callconv(cc) bool,
    reserved_other: [1]Reserved,
};

// Drive letters, their volumes and where they are (group "drives")
pub const DrivesApi = extern struct {
    slots: usize,

    // DRIVES

    letters: *const fn (buf: [*]u8, len: usize) callconv(cc) usize,
    info: *const fn (letter: u8, info: *DriveInfo) callconv(cc) bool,
    set_label: *const fn (letter: u8, label: [*]const u8, len: usize) callconv(cc) bool,
    at: *const fn (index: u32, info: *DriveInfo) callconv(cc) bool,
    assign_letters: *const fn () callconv(cc) u32,
    // path_not_found (no such drive) or not_supported (UEFI: not on
    // a 512-byte-sector disk it can find)
    location: *const fn (letter: u8, loc: *Location) callconv(cc) bool,
    // Writes out the drive's disk and lets it go (it is missing
    // until plugged in again). not_supported (not removable, or the
    // edition can't), access_denied (the boot or system disk, or a
    // file open for writing there)
    eject: *const fn (letter: u8) callconv(cc) bool,
    reserved_drives: [3]Reserved,

    // A DRIVE'S VOLUME, BY ITS LETTER (FORMAT X:)

    // Volume size in sectors; not_supported where the platform can't say
    sectors: *const fn (letter: u8, out: *u64) callconv(cc) bool,
    // Whole sectors from lba, relative to the volume's start.
    // device_error, write_protected or invalid_argument.
    read: *const fn (letter: u8, lba: u64, buf: [*]u8, len: usize) callconv(cc) bool,
    write: *const fn (letter: u8, lba: u64, data: [*]const u8, len: usize) callconv(cc) bool,
    // Before raw writes replace the volume: what the file systems
    // hold back goes to the disks
    sync: *const fn (letter: u8) callconv(cc) bool,
    // After raw writes to the volume: re-read on BIOS; UEFI needs a restart
    changed: *const fn (letter: u8) callconv(cc) bool,
    reserved_volume: [1]Reserved,
};

// Milliseconds, sleeping, the date and time (group "time")
pub const TimeApi = extern struct {
    slots: usize,

    // TIME

    millis: *const fn () callconv(cc) u64,
    sleep: *const fn (ms: u32) callconv(cc) void,
    get: *const fn (time: *Time) callconv(cc) void,
    set: *const fn (time: *const Time) callconv(cc) bool,
    // Sleeps ms milliseconds unless a signal comes first: the
    // milliseconds left then (0: all slept)
    nap: *const fn (ms: u32) callconv(cc) u32,
    // Nanoseconds since startup, from the CPU's
    // free-running counter (monotonic; it may stand still
    // between two calls closer than its step)
    nanos: *const fn () callconv(cc) u64,
    // That counter's step in nanoseconds
    // (1 or more: a 1 MHz counter's 1000)
    resolution: *const fn () callconv(cc) u64,
    // Sleeps until nanos() reaches deadline (metal, BIOS: to the
    // timer's precision, microseconds) unless a signal comes first:
    // the nanoseconds left then (0: reached)
    nap_until: *const fn (deadline: u64) callconv(cc) u64,
    reserved_time: [4]Reserved,
};

// Running programs, variables, errors,
// system information (group "programs")
pub const ProgramsApi = extern struct {
    slots: usize,

    // PROGRAMS

    exec: *const fn (path: [*]const u8, len: usize, args: [*]const u8, args_len: usize) callconv(cc) i32,
    run_command: *const fn (line: [*]const u8, len: usize) callconv(cc) i32,
    exit: *const fn (code: u8) callconv(cc) noreturn,
    program_path: *const fn (buf: [*]u8, len: usize) callconv(cc) usize,
    set_ctrl_c: *const fn (as_key: bool) callconv(cc) void,
    system_info: *const fn (info: *SystemInfo) callconv(cc) void,
    // The running program's user and groups; changing them: root
    // may set any, others only switch among
    // their real, effective and saved user
    get_ids: *const fn (out: *Ids) callconv(cc) void,
    set_ids: *const fn (ids: *const Ids) callconv(cc) bool,
    // A library, NAME.ZDL in the program's folder, else
    // \LIBS\NAME.ZDL on the boot drive: its export table (it
    // starts with slots, like a group). Loaded for this
    // program and freed when it ends; a shared library is
    // loaded once per file for all programs. Null:
    // not_found, invalid_argument (not a ZDOS library, a bad
    // name), out_of_memory, too_many_open.
    load_library: *const fn (name: [*]const u8, len: usize) callconv(cc) ?*const anyopaque,
    reserved_programs: [2]Reserved,

    // VARIABLES

    get_var: *const fn (name: [*]const u8, name_len: usize, buf: [*]u8, len: usize) callconv(cc) i64,
    set_var: *const fn (name: [*]const u8, name_len: usize, value: [*]const u8, value_len: usize) callconv(cc) bool,
    var_at: *const fn (index: u32, buf: [*]u8, len: usize) callconv(cc) i64,
    reserved_variables: [2]Reserved,

    // ERRORS

    last_error: *const fn () callconv(cc) ErrorCode,
    reserved_errors: [1]Reserved,
};

// For command interpreters and system tools: redirection,
// pipes, Ctrl+C, variable scopes, power, boot (group "system")
pub const SystemApi = extern struct {
    slots: usize,

    // REDIRECTION, PIPES, CTRL+C, VARIABLE SCOPES

    // stream 0: input, 1: output, 2: error output; handle -1: what
    // the program started with, -2: the keyboard / the screen, -3:
    // NUL; for 1 and 2 also -4 / -5: where the
    // output / error output goes now (2>&1)
    redirect: *const fn (stream: u32, handle: i32) callconv(cc) bool,
    create_pipe: *const fn () callconv(cc) i32,
    catch_ctrl_c: *const fn (on: bool) callconv(cc) void,
    ctrl_c_pressed: *const fn (clear: bool) callconv(cc) bool,
    push_vars: *const fn () callconv(cc) bool,
    pop_vars: *const fn () callconv(cc) void,
    // A remote console (SSHD's sessions): a handle whose read gives
    // what its tasks print (VT100), whose write types keys;
    // spawn_ex's term starts a task on it. -1 (not_supported
    // without tasks, out_of_memory).
    term_create: *const fn (cols: u32, rows: u32) callconv(cc) i32,
    // Its size changed: its tasks get SIGWINCH
    term_resize: *const fn (handle: i32, cols: u32, rows: u32) callconv(cc) bool,
    reserved_system: [2]Reserved,

    // POWER AND BOOT

    shutdown: *const fn () callconv(cc) noreturn,
    restart: *const fn () callconv(cc) noreturn,
    // UEFI: a boot entry for path (UTF-8, backslashes) on the
    // drive's volume, first in the boot order; an existing entry
    // for it is kept. BIOS: not_supported.
    add_boot_entry: *const fn (letter: u8, path: [*]const u8, len: usize) callconv(cc) bool,
    // On the boot drive: UEFI e.g.
    // "\EFI\BOOT\BOOTX64.EFI", BIOS "\ZIGDOS.SYS". Returns the full
    // length (as much as fits is written); 0 with not_supported if
    // the firmware didn't say.
    boot_file: *const fn (buf: [*]u8, len: usize) callconv(cc) usize,
    reserved_power_boot: [2]Reserved,
};

// The 256-color picture, key presses
// and releases, the mouse (group "gfx")
pub const GfxApi = extern struct {
    slots: usize,

    // GRAPHICS

    begin: *const fn (width: u32, height: u32) callconv(cc) bool,
    // As begin, but the picture is shown 4:3, as a DOS screen did
    // (320 x 200 has tall pixels): for ports of DOS programs.
    // UEFI only; on BIOS the monitor gives the shape.
    begin_dos_aspect: *const fn (width: u32, height: u32) callconv(cc) bool,
    palette: *const fn (first: u32, count: u32, rgb: [*]const u8) callconv(cc) void,
    draw: *const fn (pixels: [*]const u8) callconv(cc) void,
    end: *const fn () callconv(cc) void,
    // The screen pictures are shown on: its size (a picture that
    // size is shown 1:1; smaller ones are scaled by a whole
    // number and centered) and whether true color works;
    // false without graphics
    screen: *const fn (info: *ScreenInfo) callconv(cc) bool,
    // A true-color picture: draw_rgb takes width * height
    // pixels 0x00RRGGBB (bytes blue, green, red, unused);
    // not on BIOS (VGA mode 13h)
    begin_rgb: *const fn (width: u32, height: u32) callconv(cc) bool,
    draw_rgb: *const fn (pixels: [*]const u32) callconv(cc) void,
    // The screen modes the firmware offers (RESOLUTION= in
    // SYSTEM.CFG), smallest first: up to max into sizes; returns
    // how many there are (BIOS: 320 x 200)
    modes: *const fn (sizes: [*]ScreenSize, max: usize) callconv(cc) usize,
    // Tabs: each program in graphics has its own screen;
    // Alt+Tab or Win+Tab brings the next to the front (the
    // text console is one too). Only the front one is shown
    // and gets keys and the mouse; the others go on, their
    // last picture kept. Whether this program's tab is in
    // front (a game may pause while it isn't)
    visible: *const fn () callconv(cc) bool,
    // The tab's name (SDL's window title); its program's name until set
    set_title: *const fn (title: [*]const u8, len: usize) callconv(cc) void,
    reserved_gfx: [3]Reserved,

    // KEY PRESSES AND RELEASES

    key_event: *const fn (event: *KeyEvent) callconv(cc) bool,
    // The characters typed since the last call, as UTF-8 into buf
    // (the keyboard layout applied, dead keys too): SDL's text
    // input beside key events. Its length; 0: none. Once called,
    // the characters are kept for it
    // instead of being dropped by key_event.
    text_input: *const fn (buf: [*]u8, len: usize) callconv(cc) usize,
    reserved_key_events: [1]Reserved,

    // MOUSE

    mouse: *const fn (state: *Mouse) callconv(cc) bool,
    reserved_mouse: [2]Reserved,
};

// Raw disks, for the disk tools (CHKDSK,
// FORMAT, FDISK, SYS) (group "disks")
pub const DisksApi = extern struct {
    slots: usize,

    // RAW DISKS

    count: *const fn () callconv(cc) u32,
    info: *const fn (index: u32, info: *DiskInfo) callconv(cc) bool,
    read: *const fn (index: u32, lba: u64, count: u32, buf: [*]u8) callconv(cc) bool,
    write: *const fn (index: u32, lba: u64, count: u32, data: [*]const u8) callconv(cc) bool,
    // After raw writes to disk index: its volumes are mounted again
    changed: *const fn (index: u32) callconv(cc) bool,
    // Before raw writes to disk index: what the
    // file systems hold back goes to the disks
    sync: *const fn (index: u32) callconv(cc) bool,
    reserved_disks: [2]Reserved,
};

// Keyboard layouts (group "keyb")
pub const KeybApi = extern struct {
    slots: usize,

    // KEYBOARD LAYOUTS

    // All available layouts; the indexes below refer to these
    count: *const fn () callconv(cc) u32,
    // Two letters; returns the length, 0
    // with invalid_argument past the last
    name: *const fn (index: u32, buf: [*]u8, len: usize) callconv(cc) usize,
    active: *const fn () callconv(cc) u32,
    // invalid_argument if it isn't loaded
    set_active: *const fn (index: u32) callconv(cc) bool,
    // "EN,ES,FR" in switching order; returns the length written
    loaded: *const fn (buf: [*]u8, len: usize) callconv(cc) usize,
    // The first becomes active unless the active one stays loaded.
    // invalid_argument for an unknown name or an empty list.
    set_loaded: *const fn (list: [*]const u8, len: usize) callconv(cc) bool,
    reserved_keyb: [2]Reserved,
};

// A task, as tasks.info describes it
pub const TaskInfo = extern struct {
    id: u32,
    parent: u32, // the task that started it
    priority: u8, // with what it inherits from mutexes
    base_priority: u8,
    state: u8, // TaskState
    pad: u8 = 0,
    name: [32]u8, // its program, 0-terminated
    cpu_ms: u64 = 0, // milliseconds it has run (counted at each switch and timer interrupt; 0 without task switching)
};

// tasks.times: since startup, milliseconds
// in all and those no task ran in
pub const CpuTimes = extern struct {
    total_ms: u64,
    idle_ms: u64,
};

pub const TaskState = struct {
    pub const ready = 1;
    pub const running = 2;
    pub const sleeping = 3;
    pub const waiting = 4; // for another task's end, a mutex, a pipe ...
    pub const ended = 5;
    pub const stopped = 6; // SIGSTOP
};

// Programs running at the same time (group "tasks"), on the
// editions that switch tasks: all (metal preemptively;
// UEFI and BIOS cooperatively). The first task is number 1.
// Priorities are 0-31, higher first;
// a new task gets its starter's. Mutexes inherit priority:
// their holder runs at least at the priority of the highest
// task waiting for them. A program's mutexes go when it ends.
pub const TasksApi = extern struct {
    slots: usize,

    // TASKS

    // Starts the program (as exec finds it) as a new task; its id,
    // or -1 (not_found, invalid_argument for a batch file,
    // not_supported, out_of_memory, too_many_open).
    // Standard input none, output the screen.
    spawn: *const fn (path: [*]const u8, len: usize, args: [*]const u8, args_len: usize) callconv(cc) i32,
    // Until task id, one this task started, has ended: its exit
    // code, or -1 (interrupted by a signal, invalid_argument)
    wait: *const fn (id: u32) callconv(cc) i32,
    // Whether task id has ended, with its exit code in code
    ended: *const fn (id: u32, code: *u8) callconv(cc) bool,
    // The calling task's id (1: the first;
    // ids are POSIX process IDs, never 0)
    id: *const fn () callconv(cc) u32,
    // Lets tasks of the same priority run
    yield: *const fn () callconv(cc) void,
    set_priority: *const fn (id: u32, priority: u32) callconv(cc) bool,
    // -1 for an unknown task
    priority: *const fn (id: u32) callconv(cc) i32,
    // The task at index (0, 1 ...); false past the last
    info: *const fn (index: u32, info: *TaskInfo) callconv(cc) bool,
    // spawn with its standard streams and priority chosen (SpawnOptions)
    spawn_ex: *const fn (path: [*]const u8, len: usize, args: [*]const u8, args_len: usize, options: *const SpawnOptions) callconv(cc) i32,
    // A task this one started that has ended, collected into out:
    // its id; 0 if none has yet and flags has no_hang;
    // -1 (no_child, interrupted)
    wait_any: *const fn (flags: u32, out: *TaskEnd) callconv(cc) i32,
    // wait, telling the signal that ended it too
    wait_end: *const fn (id: u32, out: *TaskEnd) callconv(cc) bool,
    // The task that started the calling one (0 for the first)
    parent: *const fn () callconv(cc) u32,
    // Since startup: all milliseconds, and those no task ran in (for TOP)
    times: *const fn (out: *CpuTimes) callconv(cc) void,
    // spawn_ex (options null: spawn's) with its own variables
    // instead of the global ones: env_len bytes of "NAME=value"
    // entries, each ended by a 0 byte (empty ones are skipped).
    // invalid_argument for an entry without '=', a bad name or a
    // value too long; out_of_memory
    // for more than a scope holds (48).
    spawn_env: *const fn (path: [*]const u8, len: usize, args: [*]const u8, args_len: usize, options: ?*const SpawnOptions, env: [*]const u8, env_len: usize) callconv(cc) i32,
    // A task's scheduling policy (Policy): rr (the default) takes
    // turns within a priority every 10 ms, fifo keeps the CPU
    // until it waits or a higher priority comes. Threads and
    // programs it starts inherit it; a foreground program's is put
    // back at its end. Own tasks only, unless root.
    set_policy: *const fn (id: u32, policy: u32) callconv(cc) bool,
    // -1 for an unknown task
    policy: *const fn (id: u32) callconv(cc) i32,
    reserved_tasks: [2]Reserved,

    // MUTEXES

    // A new mutex's number, or -1
    mutex_create: *const fn () callconv(cc) i32,
    // Waits until it's free; invalid_argument if this task holds it already
    mutex_lock: *const fn (mutex: i32) callconv(cc) bool,
    // Only the task holding it may
    mutex_unlock: *const fn (mutex: i32) callconv(cc) bool,
    mutex_destroy: *const fn (mutex: i32) callconv(cc) void,
    // lock without waiting: would_block if another task holds it
    mutex_try_lock: *const fn (mutex: i32) callconv(cc) bool,

    // DEADLINE SCHEDULING

    // Task id runs earliest deadline first, above every priority
    // (policy deadline, Linux's SCHED_DEADLINE): runtime
    // nanoseconds in each period, done by `deadline` after the
    // period's start (period 0: = deadline). invalid_argument
    // unless 0 < runtime <= deadline <= period; would_block if all
    // deadline tasks would need more than 95% of the cores.
    // set_policy (fifo, rr) ends it. Own tasks only, unless root.
    set_deadline: *const fn (id: u32, runtime: u64, deadline: u64, period: u64) callconv(cc) bool,
    // A deadline task's three values (false: not one)
    deadline: *const fn (id: u32, out: *DeadlineSetting) callconv(cc) bool,
    reserved_mutexes: [1]Reserved,
};

pub const DeadlineSetting = extern struct {
    runtime: u64,
    deadline: u64,
    period: u64,
};

// How tasks.spawn_ex starts a program. A stream is a handle of
// the caller, or same_stream (the caller's current one),
// no_stream (input none, output the screen) or nul_stream.
// tasks->set_policy: POSIX's SCHED_FIFO, SCHED_RR numbers
pub const Policy = struct {
    pub const fifo: u32 = 1;
    pub const rr: u32 = 2;
    pub const deadline: u32 = 6; // set_deadline
};

pub const SpawnOptions = extern struct {
    size: u32 = @sizeOf(SpawnOptions),
    priority: i32 = -1, // -1: the caller's
    input: i32 = no_stream,
    output: i32 = no_stream,
    err: i32 = no_stream, // the error output (an older, shorter record: as output)
    term: i32 = -1, // a remote console's handle (term_create): its screen and keys; other values: the caller's

    pub const same_stream = -1;
    pub const no_stream = -2;
    pub const nul_stream = -3;
    // For output and err (and redirect's streams 1 and 2): where
    // the caller's output / error output goes now (2>&1, 1>&2)
    pub const caller_output = -4;
    pub const caller_error = -5;
};

// A task that ended: its id, exit code,
// and the signal that ended it (0: none)
pub const TaskEnd = extern struct {
    id: u32 = 0,
    code: u8 = 0,
    signal: u8 = 0,
    pad: u16 = 0,
};

pub const WaitFlags = struct {
    pub const no_hang = 1;
};

// For files.poll: a handle (or stdin_handle: the standard
// input, the keyboard if it isn't redirected) and the
// events wanted (Poll); revents gets those that happened
pub const PollFd = extern struct {
    handle: i32,
    events: u16,
    revents: u16 = 0,

    pub const stdin_handle = -2;
};

// files.queue_events: a change to a queue's watch
// of a handle. Edge (QueueBits.edge): an event
// each time the handle's object changes, and once
// at add and modify; else while it holds.
// once: reported once, then off until modified.
// err and hup come unasked.
pub const QueueChange = extern struct {
    handle: i32,
    op: u32, // QueueOp
    events: u32, // QueueBits
    pad: u32 = 0,
    data: u64, // given back with its events
};

pub const QueueEvent = extern struct {
    events: u32, // QueueBits that hold
    pad: u32 = 0,
    data: u64,
};

pub const QueueOp = struct {
    pub const add = 1;
    pub const modify = 2;
    pub const delete = 3;
};

// Linux's epoll bit values
pub const QueueBits = struct {
    pub const in: u32 = 0x001;
    pub const out: u32 = 0x004;
    pub const err: u32 = 0x008;
    pub const hup: u32 = 0x010;
    pub const read_hup: u32 = 0x2000; // the peer sends no more
    pub const once: u32 = 1 << 30;
    pub const edge: u32 = 1 << 31;
};

// threads.counter_create
pub const CounterFlags = struct {
    pub const semaphore = 1;
    pub const nonblocking = 2;
};

// The POSIX bit values
pub const Poll = struct {
    pub const in = 0x001;
    pub const out = 0x004;
    pub const err = 0x008;
    pub const hup = 0x010;
    pub const nval = 0x020;
};

// A thread's function: what it returns is what join gets
pub const ThreadEntry = *const fn (arg: ?*anyopaque) callconv(cc) usize;

// Threads of a program (group "threads"), on the
// editions that switch tasks: tasks that run a
// function of the program in its memory, with
// their own stack. Mutexes are in group tasks.
// A thread's end leaves its program running;
// the program's end ends its threads. exit in a
// thread ends the program.
pub const ThreadsApi = extern struct {
    slots: usize,

    // THREADS

    // entry(arg) on a stack of stack_size bytes (0: the platform's
    // default, 256 KiB on PCs), at priority (-1: the caller's); its
    // task id, or -1 (not_supported, out_of_memory, too_many_open)
    create: *const fn (entry: ThreadEntry, arg: ?*anyopaque, stack_size: usize, priority: i32) callconv(cc) i32,
    // Until the thread has ended: what entry returned (or exit's value)
    join: *const fn (id: u32, result: *usize) callconv(cc) bool,
    // Nobody joins it: it goes away when it ends
    detach: *const fn (id: u32) callconv(cc) bool,
    // Ends the calling thread
    exit: *const fn (result: usize) callconv(cc) noreturn,
    // A value of the calling thread's own (for thread-local data)
    set_local: *const fn (value: usize) callconv(cc) void,
    local: *const fn () callconv(cc) usize,
    // The calling thread's thread pointer for thread_local data
    // (x86_64 FS base, ARM64 TPIDR_EL0, x86 GS base): the C library
    // and zdos.zig set it to the thread's TLS block. A program
    // started from this one starts with it;
    // it is back when that program ends.
    set_thread_pointer: *const fn (tp: usize) callconv(cc) void,
    // The stack a thread gets with
    // stack_size 0 (the platform's choice);
    // 0 from a ZDOS without it
    default_stack_size: *const fn () callconv(cc) usize,
    // Futexes: waiting on a 32-bit word of the program's memory
    // (4-byte aligned) while it holds the expected value, woken by
    // address (Linux's FUTEX_WAIT_BITSET and FUTEX_WAKE_BITSET).
    // bits: a waker wakes only waiters whose bits share one
    // with its own (0: invalid_argument).
    // Waits until a wake, timeout_ms (-1:
    // no limit; timed_out) or a signal (interrupted); would_block
    // at once if *addr isn't expected. Returns why (also as
    // last_error, which the program's threads share): .none when
    // woken, maybe spuriously: check the word.
    futex_wait: *const fn (addr: *const u32, expected: u32, timeout_ms: i32, bits: u32) callconv(cc) ErrorCode,
    // Wakes up to count waiters of addr, highest priority first
    // (then the longest waiting): how
    // many, or -1 (invalid_argument)
    futex_wake: *const fn (addr: *const u32, count: u32, bits: u32) callconv(cc) i32,

    // CONDITIONS

    cond_create: *const fn () callconv(cc) i32,
    // Lets the mutex go and waits for signal or
    // broadcast (or timeout_ms; -1: none:
    // timed_out), then takes the mutex again. May end
    // early (a signal): check what was waited for.
    cond_wait: *const fn (cond: i32, mutex: i32, timeout_ms: i32) callconv(cc) bool,
    // Wakes the highest waiting thread, or all of them
    cond_signal: *const fn (cond: i32) callconv(cc) void,
    cond_broadcast: *const fn (cond: i32) callconv(cc) void,
    cond_destroy: *const fn (cond: i32) callconv(cc) void,
    // For conditions built on futexes (FUTEX_CMP_REQUEUE): if *addr
    // is expected, wakes up to count waiters of addr and moves up
    // to move_count more to wait on addr2; how many were woken and
    // moved, or -1 (would_block: *addr isn't expected;
    // invalid_argument)
    futex_requeue: *const fn (addr: *const u32, expected: u32, count: u32, addr2: *const u32, move_count: u32) callconv(cc) i32,
    reserved_conds: [2]Reserved,

    // SEMAPHORES

    sem_create: *const fn (value: u32) callconv(cc) i32,
    // Takes one, waiting up to timeout_ms (-1: no limit;
    // 0: would_block at once)
    sem_wait: *const fn (sem: i32, timeout_ms: i32) callconv(cc) bool,
    sem_post: *const fn (sem: i32) callconv(cc) bool,
    // -1 for an unknown semaphore
    sem_value: *const fn (sem: i32) callconv(cc) i32,
    sem_destroy: *const fn (sem: i32) callconv(cc) void,
    // A counter as a handle (Linux's eventfd):
    // files.write adds an 8-byte value, files.read takes
    // the count as 8 bytes (CounterFlags.semaphore:
    // one), waiting while it is 0; writing waits while it
    // would pass 2^64-2. CounterFlags.nonblocking:
    // would_block instead of waiting. files.poll and
    // event queues see it.
    counter_create: *const fn (value: u32, flags: u32) callconv(cc) i32,
    reserved_sems: [2]Reserved,
};

// POSIX signal numbers (as on Linux)
pub const Signal = struct {
    // Not a signal: in set_handler's ignored, "keep no records of
    // my children's ends" (SA_NOCLDWAIT;
    // SIGCHLD ignored does the same)
    pub const no_child_wait = 0;

    pub const hup = 1;
    pub const int = 2;
    pub const quit = 3;
    pub const ill = 4;
    pub const trap = 5;
    pub const abrt = 6;
    pub const bus = 7;
    pub const fpe = 8;
    pub const kill = 9;
    pub const usr1 = 10;
    pub const segv = 11;
    pub const usr2 = 12;
    pub const pipe = 13;
    pub const alrm = 14;
    pub const term = 15;
    pub const chld = 17;
    pub const cont = 18;
    pub const stop = 19;
    pub const tstp = 20;
    pub const ttin = 21;
    pub const ttou = 22;
    pub const urg = 23;
    pub const winch = 28;
};

// The program's signal handler: called with each signal it catches
pub const SignalEntry = *const fn (sig: i32) callconv(cc) void;

// Signals (group "signals"), between tasks on the editions
// that switch them. A program has one entry for all signals
// it catches (the C library's dispatcher); the others get
// the default action: SIGCHLD, SIGURG, SIGWINCH and SIGCONT
// are ignored, SIGSTOP, SIGTSTP, SIGTTIN, SIGTTOU stop the
// task until SIGCONT, the rest end the program (exit code
// 128 + the signal). A signal is handled when ZDOS returns
// to the program or, if the task was interrupted in its own
// code, before that code goes on; it ends waits for keys,
// other tasks, pipes, sleep (interrupted).
pub const SignalsApi = extern struct {
    slots: usize,

    // SIGNALS

    // To task id; 0 only checks that the task exists
    send: *const fn (task: u32, sig: u32) callconv(cc) bool,
    // The program's handler (null: none) for the
    // signals in caught (bit n: signal n); those in
    // ignored are dropped. Bit 0 of ignored
    // (Signal.no_child_wait), or SIGCHLD ignored:
    // its child tasks leave no record when they end
    // (nothing for wait; it waits for all, then
    // fails with no_child)
    set_handler: *const fn (entry: ?SignalEntry, caught: u64, ignored: u64) callconv(cc) void,
    // The calling task's blocked signals: how 0 adds set, 1 removes
    // it, 2 makes it the set; the set before
    mask: *const fn (how: u32, set: u64) callconv(cc) u64,
    // Sent but blocked
    pending: *const fn () callconv(cc) u64,
    // SIGALRM in ms (0: none); what the previous one had left
    alarm: *const fn (ms: u64) callconv(cc) u64,
    // Waits until a signal is handled, with mask blocked meanwhile
    wait: *const fn (mask: u64) callconv(cc) void,
    // The calling task's timer (one per task; alarm's too): signal
    // sig in first nanoseconds (0: off), then every interval (0:
    // once). The setting before goes to old (if not null).
    // False for a bad signal.
    set_timer: *const fn (sig: u32, first: u64, interval: u64, old: ?*TimerSetting) callconv(cc) bool,
    // Its setting now
    timer: *const fn (now: *TimerSetting) callconv(cc) void,
    reserved_signals: [4]Reserved,
};

// A timer: nanoseconds to its next signal (0: off), and
// its period (0: once)
pub const TimerSetting = extern struct {
    left: u64,
    interval: u64,
};

// A job for another core: called there with the argument given to start
pub const CoreJob = *const fn (arg: ?*anyopaque) callconv(cc) void;

// More CPU cores for a program's own computing (group "cores"):
// jobs on cores 1..count-1 (on metal with tasks on all cores,
// each a thread pinned to its core; elsewhere the core runs
// only the job). A job must not call any ZDOS function and
// shares the program's memory: the program allocates what its
// jobs need before starting them.
// A program that ends waits for its jobs first.
pub const CoresApi = extern struct {
    slots: usize,

    // CORES

    // How many cores, core 0 included (1: no others)
    count: *const fn () callconv(cc) u32,
    // Runs job(arg) on core 1..count-1; invalid_argument for
    // another core, access_denied if it is still running a job
    start: *const fn (core: u32, job: CoreJob, arg: ?*anyopaque) callconv(cc) bool,
    // Whether the core is still running a job
    busy: *const fn (core: u32) callconv(cc) bool,
    // Until the core's job has returned
    wait: *const fn (core: u32) callconv(cc) void,
    // The cores task id may run on (bit n: core n;
    // all ones: any but those ISOLCPUS= keeps).
    // Threads and programs it starts inherit it;
    // a foreground program's is put back at its end.
    // Own tasks only, unless root; invalid_argument for a
    // set without a core running tasks.
    set_affinity: *const fn (id: u32, mask: u64) callconv(cc) bool,
    // Its set (all ones: any); 0 for an unknown task
    affinity: *const fn (id: u32) callconv(cc) u64,
    reserved_cores: [2]Reserved,
};

// An IPv4 address (in the order written:
// 192.168.0.1 is .{ 192, 168, 0, 1 }) and a port
pub const NetAddress = extern struct {
    addr: [4]u8 = .{ 0, 0, 0, 0 },
    port: u16 = 0,
    pad: u16 = 0,
};

pub const NetFlags = struct {
    pub const started = 1; // NETWORK=true found a card
    pub const link = 2; // a cable, a link to the switch
    pub const dhcp = 4; // the address comes from DHCP
    pub const dhcp_bound = 8; // and it has one
    pub const interrupts = 16; // the card's interrupts arrive (else it is polled)
    pub const own_core = 32; // the network runs on a CPU core of its own (metal, BIOS)
    pub const bridge = 64; // the interface is a bridge of several cards (BRIDGE=)
    pub const routing = 128; // packets are forwarded between the interfaces (ROUTING=true)
    pub const default_route = 256; // the default route leaves by this interface
    pub const nat = 512; // NAT= masquerades behind it (an outside card)
};

// net.info, net.interface: an interface (a network card, or a
// bridge of cards) and its settings (flags 0: no network)
pub const NetInfo = extern struct {
    flags: u32,
    lease_s: u32 = 0, // DHCP's lease, seconds
    mac: [6]u8 = .{ 0, 0, 0, 0, 0, 0 },
    card_len: u8 = 0,
    number: u8 = 0, // n of its SYSTEM.CFG setting NETn, from 0 (a bridge: its first card's)
    address: [4]u8 = .{ 0, 0, 0, 0 },
    netmask: [4]u8 = .{ 0, 0, 0, 0 },
    gateway: [4]u8 = .{ 0, 0, 0, 0 },
    dns: [8][4]u8 = @splat(.{ 0, 0, 0, 0 }), // unused ones 0.0.0.0
    dhcp_server: [4]u8 = .{ 0, 0, 0, 0 },
    rx_frames: u64 = 0,
    tx_frames: u64 = 0,
    card_buf: [32]u8 = @splat(0),

    pub fn card(self: *const NetInfo) []const u8 {
        return self.card_buf[0..self.card_len];
    }
};

// net.route: a route (gateway 0.0.0.0: the destination is on the link)
pub const NetRoute = extern struct {
    destination: [4]u8 = .{ 0, 0, 0, 0 },
    netmask: [4]u8 = .{ 0, 0, 0, 0 },
    gateway: [4]u8 = .{ 0, 0, 0, 0 },
    interface: u8 = 0, // NetInfo.number of the one it leaves by (none: none now)
    flags: u8 = 0, // RouteFlags
    pad: u16 = 0,

    pub const none = 0xFF;
};

pub const RouteFlags = struct {
    pub const link = 1; // an interface's own network
    pub const static_ = 2; // ROUTE= in SYSTEM.CFG
    pub const default = 4; // the default route (the interface's router)
};

// net.recv_via, send_via: a datagram's
// interface and local address (as IP_PKTINFO).
// recv: the interface it came in by and the
// address it was sent to (255.255.255.255:
// a broadcast); send: the interface it goes out
// of (to 255.255.255.255: a broadcast on it)
// and its source address (0.0.0.0:
// the interface's). card none: the loopback
// (recv), any (send).
pub const NetVia = extern struct {
    card: u8 = none, // NetInfo.number
    pad: [3]u8 = .{ 0, 0, 0 },
    local: [4]u8 = .{ 0, 0, 0, 0 },

    pub const none = 0xFF;
};

pub const PingResult = struct {
    pub const reply = 1;
    pub const unreachable_ = 2; // a router says so
    pub const ttl_expired = 3; // the time to live ran out on the way
};

pub const PingReply = extern struct {
    result: u8, // PingResult
    ttl: u8,
    bytes: u16, // of data in the reply
    rtt_ms: u32,
    from: [4]u8,
};

pub const ArpEntry = extern struct {
    address: [4]u8,
    mac: [6]u8,
    is_static: bool, // added with arp_add
    pad: u8 = 0,
};

// net.connection: a TCP connection or listener, or a UDP socket
pub const Connection = extern struct {
    proto: u8, // 6 TCP, 17 UDP
    state: u8, // TCP: TcpState
    pad: u16 = 0,
    local: NetAddress,
    remote: NetAddress,
    rx_queued: u32, // received, not read yet
    tx_queued: u32, // sent, not acknowledged yet
};

pub const TcpState = struct {
    pub const closed = 0;
    pub const listen = 1;
    pub const syn_sent = 2;
    pub const syn_received = 3;
    pub const established = 4;
    pub const fin_wait_1 = 5;
    pub const fin_wait_2 = 6;
    pub const close_wait = 7;
    pub const closing = 8;
    pub const last_ack = 9;
    pub const time_wait = 10;
};

pub const SocketType = struct {
    pub const stream = 1; // TCP
    pub const datagram = 2; // UDP
};

// net.send / recv flags
pub const SocketFlags = struct {
    pub const peek = 1; // recv: leave the data there
    pub const dont_wait = 2; // as if nonblocking, this once
    pub const no_signal = 4; // send: no SIGPIPE for a broken connection
};

pub const SocketOption = struct {
    pub const nonblocking = 1; // calls that would wait fail with would_block (connect: in_progress)
    pub const reuse_address = 2;
    pub const keepalive = 3;
    pub const broadcast = 4;
    pub const no_delay = 5; // TCP: send small writes at once
    pub const ttl = 6;
    pub const recv_timeout = 7; // ms a receive waits (0: no limit): then would_block
    pub const send_timeout = 8;
    pub const pending_error = 9; // get: the ErrorCode a failed connect left, once (0: none)
    pub const socket_type = 10; // get: SocketType
};

// The network (group "net"): TCP/IP on the network card,
// started at boot with NETWORK=true in SYSTEM.CFG (UEFI: the
// firmware's network driver; metal: ZDOS's own). Without it the
// calls fail with network_down. Sockets are handles:
// files.read, write, poll, dup and close work on them too.
pub const NetApi = extern struct {
    slots: usize,

    // THE INTERFACE

    info: *const fn (out: *NetInfo) callconv(cc) void,
    // DHCP again on the interfaces that use it, waiting up to
    // timeout_ms for their addresses
    // (invalid_argument if none does)
    renew: *const fn (timeout_ms: u32) callconv(cc) bool,
    // Gives the DHCP address up
    release: *const fn () callconv(cc) bool,
    // The index-th interface (0 ...; info
    // gives the first); false past the last
    interface: *const fn (index: u32, out: *NetInfo) callconv(cc) bool,
    // The index-th route; false past the last
    route: *const fn (index: u32, out: *NetRoute) callconv(cc) bool,
    reserved_interface: [3]Reserved,

    // NAMES, PING, ARP, CONNECTIONS

    // A name's address: written out, localhost,
    // HOSTS.CFG, then DNS (host_not_found)
    resolve: *const fn (name: [*]const u8, len: usize, out: *[4]u8) callconv(cc) bool,
    // An echo request with size bytes of data; waits up to
    // timeout_ms for the answer (timed_out)
    ping: *const fn (addr: *const [4]u8, seq: u16, size: u16, ttl: u8, timeout_ms: u32, out: *PingReply) callconv(cc) bool,
    // The index-th entry of the ARP table (0, 1 ...); false past the last
    arp_entry: *const fn (index: u32, out: *ArpEntry) callconv(cc) bool,
    arp_add: *const fn (addr: *const [4]u8, mac: *const [6]u8) callconv(cc) bool,
    // null: every entry
    arp_remove: *const fn (addr: ?*const [4]u8) callconv(cc) bool,
    // The index-th connection; false past the last
    connection: *const fn (index: u32, out: *Connection) callconv(cc) bool,
    reserved_names: [1]Reserved,

    // SOCKETS

    // A new socket's handle (SocketType), or -1
    socket: *const fn (kind: u32) callconv(cc) i32,
    bind: *const fn (handle: i32, addr: *const NetAddress) callconv(cc) bool,
    listen: *const fn (handle: i32, backlog: u32) callconv(cc) bool,
    // The next connection's handle (peer: its address), waiting for one
    accept: *const fn (handle: i32, peer: ?*NetAddress) callconv(cc) i32,
    // Datagram: the peer send and recv use
    connect: *const fn (handle: i32, addr: *const NetAddress) callconv(cc) bool,
    // Bytes sent / received, -1. A stream sends all unless it
    // may not wait; recv 0: the peer closed. SocketFlags.
    send: *const fn (handle: i32, buf: [*]const u8, len: usize, flags: u32) callconv(cc) i64,
    recv: *const fn (handle: i32, buf: [*]u8, len: usize, flags: u32) callconv(cc) i64,
    send_to: *const fn (handle: i32, buf: [*]const u8, len: usize, flags: u32, to: *const NetAddress) callconv(cc) i64,
    recv_from: *const fn (handle: i32, buf: [*]u8, len: usize, flags: u32, from: ?*NetAddress) callconv(cc) i64,
    // how: 0 receiving, 1 sending, 2 both
    shutdown: *const fn (handle: i32, how: u32) callconv(cc) bool,
    // The socket's own address, or (peer) the one it is connected to
    address: *const fn (handle: i32, peer: bool, out: *NetAddress) callconv(cc) bool,
    set_option: *const fn (handle: i32, option: u32, value: u32) callconv(cc) bool,
    get_option: *const fn (handle: i32, option: u32, out: *u32) callconv(cc) bool,
    // Datagram: recv_from, and the interface it came in by (via)
    recv_via: *const fn (handle: i32, buf: [*]u8, len: usize, flags: u32, from: ?*NetAddress, via: ?*NetVia) callconv(cc) i64,
    // Datagram: send_to out of via's interface, from via's address
    send_via: *const fn (handle: i32, buf: [*]const u8, len: usize, flags: u32, to: *const NetAddress, via: *const NetVia) callconv(cc) i64,
    reserved_sockets: [4]Reserved,
};

// Sound (group "sound"): the PC speaker (x86), and samples on a
// sound card (its driver, .SYS): until one is loaded those
// calls fail with not_supported.
pub const SoundApi = extern struct {
    slots: usize,

    // THE PC SPEAKER

    // A square wave of hz (20-20000) until the next call;
    // 0: silence. The program's end silences it.
    // not_supported without a speaker.
    tone: *const fn (hz: u32) callconv(cc) bool,
    // tone(hz) for ms milliseconds, then silence; returns when done
    // (Ctrl+C or a signal ends it early)
    beep: *const fn (hz: u32, ms: u32) callconv(cc) bool,
    // As tone, but a short pulse per period instead of
    // a square wave: quieter and thinner on a real speaker; QEMU
    // plays it as silence
    soft_tone: *const fn (hz: u32) callconv(cc) bool,
    reserved_speaker: [1]Reserved,

    // SAMPLES (A SOUND CARD)

    // Output at rate Hz, channels 1-2, bits 8 (unsigned) or 16
    // (signed, little-endian), interleaved: a handle, or -1
    // (not_supported without a card,
    // access_denied while another program has it)
    open: *const fn (rate: u32, channels: u32, bits: u32) callconv(cc) i32,
    // Queues len bytes of samples, waiting while
    // the queue is full: the bytes taken, or -1
    write: *const fn (handle: i32, data: [*]const u8, len: usize) callconv(cc) isize,
    // Bytes queued and not yet heard (the delay before new samples play)
    queued: *const fn (handle: i32) callconv(cc) usize,
    // Plays what is queued, then ends (or at once if drop)
    close: *const fn (handle: i32, drop: bool) callconv(cc) void,
    // The card's output volume, 0-100; volume is -1 without a card
    set_volume: *const fn (percent: u32) callconv(cc) bool,
    volume: *const fn () callconv(cc) i32,
    reserved_samples: [6]Reserved,
};

// The groups a program uses, by the names it asks
// ZDOS for (Start.group). The libraries
// (apps/zdos/zdos.zig, sdk/src/zdos.h) fill this when
// the program starts; a group this ZDOS lacks, or has
// fewer slots of, is padded with not_supported.
pub const Api = extern struct {
    console: *const ConsoleApi,
    memory: *const MemoryApi,
    files: *const FilesApi,
    drives: *const DrivesApi,
    time: *const TimeApi,
    programs: *const ProgramsApi,
    system: *const SystemApi,
    gfx: *const GfxApi,
    disks: *const DisksApi,
    keyb: *const KeybApi,
    cores: *const CoresApi,
    tasks: *const TasksApi,
    threads: *const ThreadsApi,
    signals: *const SignalsApi,
    net: *const NetApi,
    sound: *const SoundApi,
};

// How many function slots a group type has (all but its slots field)
pub fn slotsOf(comptime T: type) usize {
    return @sizeOf(T) / @sizeOf(usize) - 1;
}

// Each group's slot count. A function put into a
// reserved slot keeps it; if it changes, a reserve
// wasn't shrunk (or the group grew at its end:
// then update it here and in zdos.h).
comptime {
    if (slotsOf(ConsoleApi) != 22) @compileError("group console: shrink the reserve the new function went into");
    if (slotsOf(MemoryApi) != 6) @compileError("group memory: shrink the reserve the new function went into");
    if (slotsOf(FilesApi) != 42) @compileError("group files: shrink the reserve the new function went into");
    if (slotsOf(DrivesApi) != 16) @compileError("group drives: shrink the reserve the new function went into");
    if (slotsOf(TimeApi) != 12) @compileError("group time: shrink the reserve the new function went into");
    if (slotsOf(ProgramsApi) != 18) @compileError("group programs: shrink the reserve the new function went into");
    if (slotsOf(SystemApi) != 16) @compileError("group system: shrink the reserve the new function went into");
    if (slotsOf(GfxApi) != 20) @compileError("group gfx: shrink the reserve the new function went into");
    if (slotsOf(DisksApi) != 8) @compileError("group disks: shrink the reserve the new function went into");
    if (slotsOf(KeybApi) != 8) @compileError("group keyb: shrink the reserve the new function went into");
    if (slotsOf(CoresApi) != 8) @compileError("group cores: shrink the reserve the new function went into");
    if (slotsOf(TasksApi) != 26) @compileError("group tasks: shrink the reserve the new function went into");
    if (slotsOf(ThreadsApi) != 26) @compileError("group threads: shrink the reserve the new function went into");
    if (slotsOf(SignalsApi) != 12) @compileError("group signals: shrink the reserve the new function went into");
    if (slotsOf(NetApi) != 34) @compileError("group net: shrink the reserve the new function went into");
    if (slotsOf(SoundApi) != 16) @compileError("group sound: shrink the reserve the new function went into");
}
