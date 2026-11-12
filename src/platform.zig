// The platform layer: everything the kernel needs
// from the machine. The entry file's zdos_platform
// chooses the backend; the comptime check at the end lists
// what each must declare. Text is UTF-8.
// Paths are absolute within a volume ("\DOCS\REPORT.TXT");
// names compare case-insensitively.
const std = @import("std");

// TYPES SHARED BY ALL BACKENDS

// NotFound: the last path component is missing; PathNotFound: a
// folder on the way. Backends that can't tell (UEFI) say
// NotFound, and fs.zig, which resolves
// the folders first, tells them apart.
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
};

// char: 0 for keys without one; scan identifies those (Scan).
// Enter is '\r', Backspace 0x08. A modifier pressed alone comes
// as char 0, scan 0 with its Mod
// bit, if the platform can report it.
pub const Key = struct {
    char: u21,
    scan: u16,
    mods: u16 = 0,
};

// For the scrollback: consoles that keep their text declare
// cellAt, viewBegin, viewCell, viewEnd,
// altEnter, altLeave and on_scroll.
pub const Cell = struct { char: u21 = ' ', fg: u8 = 7, bg: u8 = 0 };

// UEFI scan codes, as abi.Scan.
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
    pub const f1 = 0x0b; // f1..f10 are consecutive: f1 + n - 1
    pub const f10 = 0x14;
    pub const f11 = 0x15;
    pub const f12 = 0x16;
    pub const esc = 0x17;
    pub const redraw = 0xFE; // not a key: kernel/console.zig's answer to a line editor
};

// As abi.Mod.
pub const Mod = struct {
    pub const left_shift = 0x0001;
    pub const right_shift = 0x0002;
    pub const left_ctrl = 0x0004;
    pub const right_ctrl = 0x0008;
    pub const left_alt = 0x0010;
    pub const right_alt = 0x0020;
    pub const left_logo = 0x0040; // Windows key, Cmd on Mac keyboards
    pub const right_logo = 0x0080;
    pub const menu = 0x0100;
    pub const caps_lock = 0x1000; // lock keys: on / off
    pub const num_lock = 0x2000;
    pub const scroll_lock = 0x4000;
};

// For games. code: the PC set 1 make code,
// the same on every layout; E0 keys as
// 0xE000 | code, Pause 0xE11D. repeat:
// by the keyboard's repeat.
pub const KeyEvent = struct {
    code: u16,
    pressed: bool,
    repeat: bool = false,
    mods: u16 = 0,
};

// Movement since last asked (in the mouse's counts, dy down),
// the wheel (positive: toward the user), buttons held (bit 0
// left, 1 right, 2 middle).
pub const Mouse = struct {
    dx: i32 = 0,
    dy: i32 = 0,
    wheel: i32 = 0,
    buttons: u8 = 0,
};

// 0-based; or a size in columns and rows.
pub const Position = struct {
    col: u32,
    row: u32,
};

// The screen pictures are shown
// on, and whether true color works.
pub const ScreenInfo = struct {
    width: u32,
    height: u32,
    true_color: bool,
};

pub const ScreenSize = struct {
    width: u32,
    height: u32,
};

pub const DateTime = struct {
    year: u16,
    month: u8, // 1-12
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub const OpenMode = enum {
    read, // existing file, read only
    write, // create, or empty an existing file; read and write
    update, // create if missing, keep contents; read and write
};

pub const seek_end = std.math.maxInt(u64);

// In bytes of UTF-8 (FAT allows 255 characters).
pub const max_name = 768;

// The same values FAT and UEFI use.
pub const Attr = struct {
    pub const read_only = 0x01;
    pub const hidden = 0x02;
    pub const system = 0x04;
    pub const archive = 0x20;
    pub const all = read_only | hidden | system | archive;
};

pub const no_date: DateTime = .{ .year = 0, .month = 0, .day = 0, .hour = 0, .minute = 0, .second = 0 };

// The disk's index, first sector and length in sectors.
pub const Location = struct {
    disk: u32,
    start: u64,
    sectors: u64,
};

// For raw access. sectors 0: no disk in the drive.
pub const DiskInfo = struct {
    sectors: u64,
    sector_size: u32,
    removable: bool,
    read_only: bool,
};

pub const EntryInfo = struct {
    name_buf: [max_name]u8 = undefined,
    name_len: usize = 0, // the on-disk spelling
    is_dir: bool = false,
    attrs: u8 = 0, // Attr bits
    size: u64 = 0,
    modified: DateTime = no_date,
    // Year 0 if unknown (FAT keeps only
    // the date of the last access).
    created: DateTime = no_date,
    accessed: DateTime = no_date,
    unix: ?UnixInfo = null, // from a Unix file system (ext2); null on FAT

    pub fn name(self: *const EntryInfo) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

// largest_free: the most one allocation can get.
pub const MemoryStats = struct {
    total: u64,
    free: u64,
    largest_free: u64,
};

// The type bits (S_IFMT) and permission
// bits (0o7777), owner and group.
pub const Permissions = struct {
    mode: u16,
    uid: u32,
    gid: u32,
};

// Besides EntryInfo's own.
pub const UnixInfo = struct {
    mode: u16, // type and permission bits
    uid: u32,
    gid: u32,
    ino: u64,
    links: u32,
    blocks: u64, // 512-byte units in use
    changed: DateTime = no_date, // the inode's last change
};

pub const VolumeInfo = struct {
    label_buf: [64]u8 = undefined,
    label_len: usize = 0,
    size: u64 = 0, // bytes
    free: u64 = 0, // bytes
    serial: ?u32 = null, // the volume serial number from formatting, if known
    fs_name: []const u8 = "", // "FAT12", "FAT16", "FAT32"; "" if unknown
    block_size: u32 = 0, // bytes per cluster or block; 0 if unknown

    pub fn label(self: *const VolumeInfo) []const u8 {
        return self.label_buf[0..self.label_len];
    }
};

pub const VolumeFlags = struct {
    boot: bool = false,
    system: bool = false, // an EFI System Partition (holds the PC's boot loaders)
    hidden: bool = false, // the partition asks for no drive letter (recovery, OEM ...)
    floppy: bool = false, // on a floppy drive: gets A: or B:
    unreadable: bool = false, // no driver reads it: no letter
    removable: bool = false, // USB stick, card reader (UEFI)
    active: bool = false, // marked active in the table
};

pub const Media = enum {
    same, // the same disk as before (or not removable)
    changed, // another disk: mounted anew; open files on the old one are invalid
    missing, // no readable disk in the drive
};

// host: tools/build brings its own backend as
// `zdos_host_backend`, with only what the
// file system drivers use (clock.now).
pub const Platform = enum { bios, uefi, metal, host };

const is_host = @as(Platform, @import("root").zdos_platform) == .host;

const backend = switch (@as(Platform, @import("root").zdos_platform)) {
    .uefi => @import("platform/uefi/uefi.zig"),
    .bios => @import("platform/bios/bios.zig"),
    .metal => @import("platform/metal/metal.zig"),
    .host => @import("root").zdos_host_backend,
};

pub const name: []const u8 = backend.name;

// A program's own, its threads' unless they ask (thread_max at
// most), ZDOS's own tasks'.
pub const Stacks = struct {
    program: usize,
    thread: usize,
    task: usize,
    thread_max: usize,
};

pub const config = if (@hasDecl(backend, "config")) backend.config else struct {
    pub const stacks: Stacks = .{ .program = 1024 * 1024, .thread = 256 * 1024, .task = 64 * 1024, .thread_max = 16 * 1024 * 1024 };
};

pub const init = backend.init;

// SYSTEM.CFG settings for the backend once read (metal:
// PAGING=); get looks one up.
pub fn configure(get: *const fn (name: []const u8) ?[]const u8) void {
    if (@hasDecl(backend, "configure")) backend.configure(get);
}

// Other CPU cores running jobs (fn (arg) callconv(arch.cc)).
// Without them: core 0 only.
pub const Job = *const fn (arg: ?*anyopaque) callconv(@import("arch.zig").cc) void;
pub const cores = if (@hasDecl(backend, "cores")) backend.cores else struct {
    pub fn count() usize {
        return 1;
    }
    pub fn start(core: u32, job: Job, arg: ?*anyopaque) bool {
        _ = core;
        _ = job;
        _ = arg;
        return false;
    }
    pub fn busy(core: u32) bool {
        _ = core;
        return false;
    }
    pub fn wait(core: u32) void {
        _ = core;
    }
};

// x86: available, tone(hz, soft), hz 0 silence.
pub const speaker = if (!is_host and (@import("builtin").cpu.arch == .x86_64 or @import("builtin").cpu.arch == .x86))
    @import("drivers/speaker.zig")
else
    struct {
        pub fn available() bool {
            return false;
        }
        pub fn tone(hz: u32, soft: bool) void {
            _ = .{ hz, soft };
        }
    };

// W^X for loaded images (metal RW_NX=): code(start, end,
// read_only) makes the code executable, read only unless
// the image has no separate code pages (false: no memory
// for the tables). release before the memory goes back.
pub const exec_protect = if (@hasDecl(backend, "exec_protect")) backend.exec_protect else struct {
    pub fn code(start: usize, end: usize, read_only: bool) bool {
        _ = .{ start, end, read_only };
        return true;
    }
    pub fn release(start: usize, end: usize) void {
        _ = .{ start, end };
    }
};

// Task switching: start, newContext, yield, interrupts, idle.
// Metal preempts; UEFI and BIOS are cooperative.
pub const has_switching = @hasDecl(backend, "switching");
pub const switching = if (has_switching) backend.switching else struct {};

// Drivers wait with io.wait, the handler calls io.signal; until
// tasks.zig sets them, drivers poll. A waiter that saw count n
// sleeps only while count is still n.
pub const IoEvent = struct {
    count: u32 = 0,
    seen_interrupt: bool = false, // the device's interrupts arrive at all
    last_seen: u32 = 0, // the count when its waiter last looked (waitFor)
};

// For io.deferWork.
pub const Work = struct {
    func: *const fn (ctx: ?*anyopaque) void,
    ctx: ?*anyopaque = null,
    queued: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    next: ?*Work = null,
};

pub const io = struct {
    // Until ev.count differs from seen or about max_us passed; the
    // microseconds it took. Null: no tasks, poll.
    pub var wait: ?*const fn (ev: *IoEvent, seen: u32, max_us: u32) u32 = null;
    // From an interrupt handler (interrupts off).
    pub var signal: *const fn (ev: *IoEvent) void = &countOnly;
    // Threaded interrupts: run by a kernel task at its own priority
    // once tasks.zig sets this, at once before.
    // Queued once until it runs.
    pub var deferWork: *const fn (w: *Work) void = &runNow;

    fn runNow(w: *Work) void {
        w.func(w.ctx);
    }

    fn countOnly(ev: *IoEvent) void {
        ev.count +%= 1;
        ev.seen_interrupt = true;
    }

    // Until the next interrupt since it last looked, or a deadline
    // (20 ms once interrupts came, 1 ms before), else a short spin;
    // about the microseconds it took.
    pub fn waitFor(ev: *IoEvent, spin: *const fn (us: u32) void) u32 {
        const w = wait orelse {
            spin(10);
            return 10;
        };
        const us = w(ev, ev.last_seen, if (ev.seen_interrupt) 20_000 else 1_000);
        ev.last_seen = ev.count;
        return us;
    }
};

// Network cards by number: start(i, how)
// starts card i (null: none); send and
// receive one frame (receive: its length,
// null if none); linkUp: the cable;
// promiscuous: false if it can't.
// event: its interrupt's (null:
// polled, by idle.hook).
pub const NetCard = struct {
    mac: [6]u8,
    name: []const u8,
    event: ?*IoEvent,
    interrupts: bool = false, // its interrupt arrives (to core 0, or the network core)
};

pub const has_net = @hasDecl(backend, "net");
pub const MsiMessage = struct { address: u64, data: u32 };
// To core 0 (default), as a message to the network core, to
// core 0 which wakes the network core (relay), or none (polled
// there).
pub const NetInterrupt = union(enum) { core0, message: MsiMessage, relay, none };
pub const has_net_core = @hasDecl(backend, "net_core");
// The cards' interrupts left unconnected: polled
pub const net_polled = @hasDecl(backend, "net_polled") and backend.net_polled;
// .SYS drivers, where the edition drives its hardware itself;
// mapDevice maps a device's registers.
pub const has_own_drivers = @hasDecl(backend, "own_drivers");
pub const own_drivers = if (has_own_drivers) backend.own_drivers else struct {};
pub const net_core = if (has_net_core) backend.net_core else struct {};
pub const net = if (has_net) backend.net else struct {};

// Polled backends (UEFI): called while waiting for keys or
// time, so devices keep working.
pub const idle = struct {
    pub var hook: ?*const fn () void = null;

    pub fn run() void {
        if (hook) |h| h();
    }
};

// A CPU fault in a program (metal): the task resumes in
// faults.handler, which ends the program with the signal or
// runs its handler.
// Faults in ZDOS's own code halt with the crash screen.
pub const Fault = struct {
    signal: u8, // POSIX number: SIGSEGV, SIGILL, SIGFPE, SIGBUS, SIGTRAP
    what: []const u8, // the CPU's name for it ("Page fault")
    pc: usize, // where the program was
    addr: usize = 0, // the address it used, where the CPU tells (0: none)
};

pub const faults = struct {
    pub var handler: ?*const fn (f: *const Fault) noreturn = null;
};

// Once tasks switch, where the backend has interrupts.
pub fn startInterrupts() void {
    if (@hasDecl(backend, "startInterrupts")) backend.startInterrupts();
}

pub const console = backend.console;
// A serial console with an interrupt (BIOS, metal):
// startInterrupts, service (kernel/serial.zig's task), toPolled
pub const serial = if (@hasDecl(backend, "serial")) backend.serial else struct {};
// File systems and disks under the storage lock, a mutex
// of its own: a task waiting for its disk gives the kernel
// lock up meanwhile, so other calls go on.
pub const storage = struct {
    const b = backend.storage;
    pub const FileHandle = b.FileHandle;
    pub const DirHandle = b.DirHandle;
    pub const Volume = b.Volume;
    pub const init = b.init;
    pub const location = Locked(b.location).call;
    pub const syncAll = Locked(b.syncAll).call;
    pub const volumeSectors = Locked(b.volumeSectors).call;
    pub const volumeRead = Locked(b.volumeRead).call;
    pub const volumeWrite = Locked(b.volumeWrite).call;
    pub const volumeChanged = Locked(b.volumeChanged).call;
    pub const diskChanged = Locked(b.diskChanged).call;
    pub const newDevices = Locked(b.newDevices).call;
    pub const checkMedia = Locked(b.checkMedia).call;
    pub const listVolumes = Locked(b.listVolumes).call;
    pub const volumeInfo = Locked(b.volumeInfo).call;
    pub const unixNames = Locked(b.unixNames).call;
    pub const stat = Locked(b.stat).call;
    pub const openFile = Locked(b.openFile).call;
    pub const openDir = Locked(b.openDir).call;
    pub const makeDir = Locked(b.makeDir).call;
    pub const delete = Locked(b.delete).call;
    pub const rename = Locked(b.rename).call;
    pub const setAttributes = Locked(b.setAttributes).call;
    pub const setModified = Locked(b.setModified).call;
    pub const setLabel = Locked(b.setLabel).call;
    pub const permissions = Locked(b.permissions).call;
    pub const setMode = Locked(b.setMode).call;
    pub const setOwner = Locked(b.setOwner).call;
    pub const close = Locked(b.close).call;
    pub const closeDir = Locked(b.closeDir).call;
    pub const commit = Locked(b.commit).call;
    pub const fstat = Locked(b.fstat).call;
    pub const read = Locked(b.read).call;
    pub const readDir = Locked(b.readDir).call;
    pub const seek = Locked(b.seek).call;
    pub const setModifiedOpen = Locked(b.setModifiedOpen).call;
    pub const setSize = Locked(b.setSize).call;
    pub const size = Locked(b.size).call;
    pub const write = Locked(b.write).call;
    pub usingnamespace if (@hasDecl(b, "eject")) struct {
        pub const eject = Locked(b.eject).call;
    } else struct {};
    pub usingnamespace if (@hasDecl(b, "hotplugStart")) struct {
        pub const hotplugStart = Locked(b.hotplugStart).call;
    } else struct {};
    pub usingnamespace if (@hasDecl(b, "hotplugUpdate")) struct {
        pub const hotplugUpdate = Locked(b.hotplugUpdate).call;
    } else struct {};
    pub usingnamespace if (@hasDecl(b, "deviceHandle")) struct {
        pub const deviceHandle = Locked(b.deviceHandle).call;
    } else struct {};
    pub usingnamespace if (@hasDecl(b, "forgetAll")) struct {
        pub const forgetAll = Locked(b.forgetAll).call;
    } else struct {};
    pub usingnamespace if (@hasDecl(b, "hotplug_news")) struct {
        pub const hotplug_news = &b.hotplug_news;
        pub const HotplugChange = b.HotplugChange;
    } else struct {};
};

// For files ext2 and Minix make: the
// program's user (perm.zig sets it).
pub var new_owner: struct { uid: u32 = 0, gid: u32 = 0 } = .{};
pub const memory = backend.memory;
pub const clock = backend.clock;
pub const power = backend.power;
pub const graphics = backend.graphics;
pub const disk = struct {
    const b = backend.disk;
    pub const count = b.count;
    pub const info = Locked(b.info).call;
    pub const read = Locked(b.read).call;
    pub const write = Locked(b.write).call;
    pub usingnamespace if (@hasDecl(b, "locate")) struct {
        pub const locate = b.locate;
    } else struct {};
};

// Work that must run on core 0 (a BIOS call in real mode): the
// task moves there and back.
pub var core0_enter: ?*const fn () u64 = null;
pub var core0_leave: ?*const fn (saved: u64) void = null;

// Set by tasks.zig once tasks switch.
pub var storage_lock: ?*const fn () void = null;
pub var storage_unlock: ?*const fn () void = null;

fn Locked(comptime f: anytype) type {
    const info_ = @typeInfo(@TypeOf(f)).@"fn";
    const R = info_.return_type.?;
    const p = info_.params;
    return struct {
        pub const call = switch (p.len) {
            0 => struct {
                fn w() R {
                    take();
                    defer give();
                    return f();
                }
            }.w,
            1 => struct {
                fn w(a: p[0].type.?) R {
                    take();
                    defer give();
                    return f(a);
                }
            }.w,
            2 => struct {
                fn w(a: p[0].type.?, c: p[1].type.?) R {
                    take();
                    defer give();
                    return f(a, c);
                }
            }.w,
            3 => struct {
                fn w(a: p[0].type.?, c: p[1].type.?, d: p[2].type.?) R {
                    take();
                    defer give();
                    return f(a, c, d);
                }
            }.w,
            4 => struct {
                fn w(a: p[0].type.?, c: p[1].type.?, d: p[2].type.?, e: p[3].type.?) R {
                    take();
                    defer give();
                    return f(a, c, d, e);
                }
            }.w,
            5 => struct {
                fn w(a: p[0].type.?, c: p[1].type.?, d: p[2].type.?, e: p[3].type.?, g: p[4].type.?) R {
                    take();
                    defer give();
                    return f(a, c, d, e, g);
                }
            }.w,
            else => @compileError("a storage function with more than 5 parameters: add a case"),
        };
        fn take() void {
            if (storage_lock) |l| l();
        }
        fn give() void {
            if (storage_unlock) |u| u();
        }
    };
}
pub const boot = backend.boot;

// A backend missing a declaration fails here.
comptime {
    if (!is_host) checkBackend();
}

fn checkBackend() void {
    const required = .{
        .{ console, .{ "clear", "write", "getCursor", "setCursor", "size", "setColor", "showCursor", "readKey", "pollKey", "keyEvents", "keyEvent", "pollMouse", "loadFont", "loadFontFile", "font_files", "setCodepage", "firmware_keys" } },
        .{ storage, .{ "Volume", "FileHandle", "DirHandle", "listVolumes", "volumeInfo", "unixNames", "stat", "fstat", "openFile", "read", "write", "seek", "size", "setSize", "close", "openDir", "readDir", "closeDir", "makeDir", "delete", "rename", "setAttributes", "setModified", "setModifiedOpen", "setLabel", "permissions", "setMode", "setOwner", "newDevices", "checkMedia", "location", "diskChanged", "volumeSectors", "volumeRead", "volumeWrite", "volumeChanged", "syncAll" } },
        .{ memory, .{ "allocPages", "freePages", "alloc", "free", "stats" } },
        .{ clock, .{ "now", "set", "millis", "sleep", "timestampRate" } },
        .{ power, .{ "shutdown", "restart" } },
        .{ graphics, .{ "screen", "modes", "begin", "beginRgb", "palette", "draw", "drawRgb", "end" } },
        .{ disk, .{ "count", "info", "read", "write" } },
        .{ boot, .{ "add", "file" } },
    };
    inline for (required) |r| {
        inline for (r[1]) |decl| {
            if (!@hasDecl(r[0], decl)) @compileError("platform backend is missing " ++ decl);
        }
    }
}
