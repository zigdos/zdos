// The program API table (abi.zig) on top of fs
// and the platform. Each running program has a
// Program record of what it opened and
// allocated, released when it ends, chained to
// the program that started it. Programs call
// the table directly: no user mode.
const std = @import("std");
const platform = @import("../platform.zig");
const con = @import("console.zig");
const fs = @import("fs.zig");
const perm = @import("perm.zig");
const abi = @import("abi.zig");
const loader = @import("loader.zig");
const stdio = @import("stdio.zig");
const env = @import("env.zig");
const datetime = @import("datetime.zig");
const arch = @import("../arch.zig");
const startup = @import("startup.zig");
const keyb = @import("keyb.zig");
const net = @import("../net/net.zig");
const Term = @import("term.zig").Term;
const scrollback = @import("scrollback.zig");
const libraries = @import("libraries.zig");
const sound = @import("sound.zig");
const rtheap = @import("rtheap.zig");
const queues = @import("events.zig");
const ver = @import("version.zig");

const max_alloc = 1024 * 1024 * 1024;

// What a program starts with: its arguments and the way to its groups
pub fn start(args: []const u8) abi.Start {
    return .{
        .version = abi.version,
        .args = args.ptr,
        .args_len = args.len,
        .not_supported = &notSupported,
        .group = group,
    };
}

// The group called name (an abi.Api field), or null.
// Programs get the groups with
// every function wrapped (Leaving).
fn group(name: [*]const u8, len: usize) callconv(abi.cc) ?*const anyopaque {
    const want = name[0..len];
    inline for (std.meta.fields(abi.Api)) |f| {
        if (std.mem.eql(u8, f.name, want)) {
            // Without task switching there is nothing to do on leaving
            if (!platform.has_switching) return @ptrCast(&@field(this, f.name ++ "_group"));
            return @ptrCast(&Leaving(@typeInfo(f.type).pointer.child, f.name).group);
        }
    }
    return null;
}

// ENTERING AND LEAVING ZDOS
// Every function a program calls returns through
// tasks.leaving, where deferred task switches and signals
// happen, and takes the kernel lock (tasks.zig) unless it
// needs only the scheduler's own lock (lock_free):
// a real-time task's sleeps, waits and wake-ups never wait
// for whoever is in a file system or driver. Wrappers are
// generated at compile time.

const this = @This();

fn Leaving(comptime T: type, comptime name: []const u8) type {
    return struct {
        const group: T = wrapGroup(T, name, @field(this, name ++ "_group"));
    };
}

// Calls that touch only the running task, the scheduler (its
// own lock) and the clock: no kernel lock. "group.function".
const lock_free = [_][]const u8{
    "memory.alloc",               "memory.free",        "tasks.deadline",
    "time.millis",                "time.nanos",         "time.resolution",
    "time.nap",                   "time.nap_until",     "tasks.id",
    "tasks.yield",                "tasks.priority",     "tasks.policy",
    "tasks.mutex_lock",           "tasks.mutex_unlock", "tasks.mutex_try_lock",
    "threads.set_local",          "threads.local",      "threads.set_thread_pointer",
    "threads.default_stack_size", "threads.futex_wait", "threads.futex_wake",
    "threads.futex_requeue",      "threads.cond_wait",  "threads.cond_signal",
    "threads.cond_broadcast",     "threads.sem_wait",   "threads.sem_post",
    "threads.sem_value",          "signals.mask",       "signals.pending",
    "signals.alarm",              "signals.set_timer",  "signals.timer",
};

fn lockFree(comptime group_name: []const u8, comptime field: []const u8) bool {
    for (lock_free) |entry| {
        if (std.mem.eql(u8, entry, group_name ++ "." ++ field)) return true;
    }
    return false;
}

fn wrapGroup(comptime T: type, comptime group_name: []const u8, comptime g: T) T {
    @setEvalBranchQuota(100_000);
    var out = g;
    for (std.meta.fields(T)) |field| {
        const info = @typeInfo(field.type);
        if (info != .pointer or @typeInfo(info.pointer.child) != .@"fn") continue;
        if (comptime lockFree(group_name, field.name)) {
            @field(out, field.name) = unlocked(info.pointer.child, @field(g, field.name));
        } else @field(out, field.name) = wrapped(info.pointer.child, @field(g, field.name));
    }
    return out;
}

// Without the kernel lock: only the way out (switches, signals)
fn unlocked(comptime F: type, comptime f: *const F) *const F {
    const info = @typeInfo(F).@"fn";
    const R = info.return_type.?;
    const p = info.params;
    return switch (p.len) {
        0 => &struct {
            fn w() callconv(abi.cc) R {
                defer tasks.leaving();
                return f();
            }
        }.w,
        1 => &struct {
            fn w(a: p[0].type.?) callconv(abi.cc) R {
                defer tasks.leaving();
                return f(a);
            }
        }.w,
        2 => &struct {
            fn w(a: p[0].type.?, b: p[1].type.?) callconv(abi.cc) R {
                defer tasks.leaving();
                return f(a, b);
            }
        }.w,
        3 => &struct {
            fn w(a: p[0].type.?, b: p[1].type.?, c: p[2].type.?) callconv(abi.cc) R {
                defer tasks.leaving();
                return f(a, b, c);
            }
        }.w,
        4 => &struct {
            fn w(a: p[0].type.?, b: p[1].type.?, c: p[2].type.?, d: p[3].type.?) callconv(abi.cc) R {
                defer tasks.leaving();
                return f(a, b, c, d);
            }
        }.w,
        5 => &struct {
            fn w(a: p[0].type.?, b: p[1].type.?, c: p[2].type.?, d: p[3].type.?, e: p[4].type.?) callconv(abi.cc) R {
                defer tasks.leaving();
                return f(a, b, c, d, e);
            }
        }.w,
        else => @compileError("a lock-free API function with more than 5 parameters: add a case"),
    };
}

fn wrapped(comptime F: type, comptime f: *const F) *const F {
    const info = @typeInfo(F).@"fn";
    const R = info.return_type.?;
    const p = info.params;
    return switch (p.len) {
        0 => &struct {
            fn w() callconv(abi.cc) R {
                const took = tasks.enterKernel();
                defer leave(took);
                return f();
            }
        }.w,
        1 => &struct {
            fn w(a: p[0].type.?) callconv(abi.cc) R {
                const took = tasks.enterKernel();
                defer leave(took);
                return f(a);
            }
        }.w,
        2 => &struct {
            fn w(a: p[0].type.?, b: p[1].type.?) callconv(abi.cc) R {
                const took = tasks.enterKernel();
                defer leave(took);
                return f(a, b);
            }
        }.w,
        3 => &struct {
            fn w(a: p[0].type.?, b: p[1].type.?, c: p[2].type.?) callconv(abi.cc) R {
                const took = tasks.enterKernel();
                defer leave(took);
                return f(a, b, c);
            }
        }.w,
        4 => &struct {
            fn w(a: p[0].type.?, b: p[1].type.?, c: p[2].type.?, d: p[3].type.?) callconv(abi.cc) R {
                const took = tasks.enterKernel();
                defer leave(took);
                return f(a, b, c, d);
            }
        }.w,
        5 => &struct {
            fn w(a: p[0].type.?, b: p[1].type.?, c: p[2].type.?, d: p[3].type.?, e: p[4].type.?) callconv(abi.cc) R {
                const took = tasks.enterKernel();
                defer leave(took);
                return f(a, b, c, d, e);
            }
        }.w,
        6 => &struct {
            fn w(a: p[0].type.?, b: p[1].type.?, c: p[2].type.?, d: p[3].type.?, e: p[4].type.?, g: p[5].type.?) callconv(abi.cc) R {
                const took = tasks.enterKernel();
                defer leave(took);
                return f(a, b, c, d, e, g);
            }
        }.w,
        7 => &struct {
            fn w(a: p[0].type.?, b: p[1].type.?, c: p[2].type.?, d: p[3].type.?, e: p[4].type.?, g: p[5].type.?, h: p[6].type.?) callconv(abi.cc) R {
                const took = tasks.enterKernel();
                defer leave(took);
                return f(a, b, c, d, e, g, h);
            }
        }.w,
        else => @compileError("an API function with more than 7 parameters: add a case"),
    };
}

fn leave(took: bool) void {
    if (took) tasks.leaveKernel();
    tasks.leaving();
}

// The reserved slots of the groups
// (abi.Reserved), and Start.not_supported
fn notSupported() callconv(abi.cc) usize {
    prog().last_error = .not_supported;
    return 0;
}

// The groups, as abi.zig defines them
const console_group: abi.ConsoleApi = .{
    .slots = abi.slotsOf(abi.ConsoleApi),
    .print = print,
    .read_key = readKey,
    .poll_key = pollKey,
    .edit_line = editLine,
    .reserved_console = @splat(&notSupported),
    .read_input = readInput,
    .input_redirected = inputRedirected,
    .output_redirected = outputRedirected,
    .print_error = printError,
    .error_redirected = errorRedirected,
    .clear_screen = clearScreen,
    .set_cursor = setCursor,
    .get_cursor = getCursor,
    .screen_size = screenSize,
    .set_color = setColor,
    .show_cursor = showCursor,
    .reserved_screen = @splat(&notSupported),
};

const memory_group: abi.MemoryApi = .{
    .slots = abi.slotsOf(abi.MemoryApi),
    .alloc = alloc,
    .free = free,
    .reserved_memory = @splat(&notSupported),
};

const files_group: abi.FilesApi = .{
    .slots = abi.slotsOf(abi.FilesApi),
    .open = open,
    .close = close,
    .read = read,
    .write = write,
    .seek = seek,
    .size = size,
    .set_size = setSize,
    .commit = commit,
    .delete_file = delete,
    .stat = stat,
    .set_attributes = setAttributes,
    .set_time = setFileTime,
    .permissions = permissions,
    .set_mode = setMode,
    .set_owner = setOwner,
    .stat_ex = statEx,
    .fstat_ex = fstatEx,
    .pipe = createChannel,
    .dup = dup,
    .poll = poll,
    .fset_time = fsetFileTime,
    .queue_create = queueCreate,
    .queue_events = queueEvents,
    .reserved_files = @splat(&notSupported),
    .open_dir = openDir,
    .read_dir = readDir,
    .make_dir = makeDir,
    .get_cwd = getCwd,
    .set_cwd = setCwd,
    .full_path = fullPath,
    .read_dir_ex = readDirEx,
    .reserved_folders = @splat(&notSupported),
    .copy = copy,
    .move = move,
    .delete_tree = deleteTree,
    .reserved_other = @splat(&notSupported),
};

const drives_group: abi.DrivesApi = .{
    .slots = abi.slotsOf(abi.DrivesApi),
    .letters = getDrives,
    .info = driveInfo,
    .set_label = setLabel,
    .at = driveAt,
    .assign_letters = assignLetters,
    .location = driveLocation,
    .eject = driveEject,
    .reserved_drives = @splat(&notSupported),
    .sectors = driveSectors,
    .read = driveRead,
    .write = driveWrite,
    .sync = driveSync,
    .changed = driveChanged,
    .reserved_volume = @splat(&notSupported),
};

const time_group: abi.TimeApi = .{
    .slots = abi.slotsOf(abi.TimeApi),
    .millis = millis,
    .sleep = sleep,
    .get = getTime,
    .set = setTime,
    .nap = nap,
    .nanos = nanos,
    .resolution = resolution,
    .nap_until = napUntil,
    .reserved_time = @splat(&notSupported),
};

const programs_group: abi.ProgramsApi = .{
    .slots = abi.slotsOf(abi.ProgramsApi),
    .exec = exec,
    .run_command = runCommand,
    .exit = exit,
    .program_path = programPath,
    .set_ctrl_c = setCtrlC,
    .system_info = systemInfo,
    .get_ids = getIds,
    .set_ids = setIds,
    .load_library = loadLibrary,
    .reserved_programs = @splat(&notSupported),
    .get_var = getVar,
    .set_var = setVar,
    .var_at = varAt,
    .reserved_variables = @splat(&notSupported),
    .last_error = lastError,
    .reserved_errors = @splat(&notSupported),
};

const system_group: abi.SystemApi = .{
    .slots = abi.slotsOf(abi.SystemApi),
    .redirect = redirect,
    .create_pipe = createPipe,
    .catch_ctrl_c = catchCtrlC,
    .ctrl_c_pressed = ctrlCPressed,
    .push_vars = pushVars,
    .pop_vars = popVars,
    .term_create = termCreate,
    .term_resize = termResize,
    .reserved_system = @splat(&notSupported),
    .shutdown = shutdown,
    .restart = restart,
    .add_boot_entry = addBootEntry,
    .boot_file = bootFile,
    .reserved_power_boot = @splat(&notSupported),
};

const gfx_group: abi.GfxApi = .{
    .slots = abi.slotsOf(abi.GfxApi),
    .begin = gfxBegin,
    .begin_dos_aspect = gfxBeginDosAspect,
    .palette = gfxPalette,
    .draw = gfxDraw,
    .end = gfxEnd,
    .screen = gfxScreen,
    .begin_rgb = gfxBeginRgb,
    .modes = gfxModes,
    .draw_rgb = gfxDrawRgb,
    .visible = gfxVisible,
    .set_title = gfxSetTitle,
    .reserved_gfx = @splat(&notSupported),
    .key_event = keyEvent,
    .text_input = textInput,
    .reserved_key_events = @splat(&notSupported),
    .mouse = mouse,
    .reserved_mouse = @splat(&notSupported),
};

const disks_group: abi.DisksApi = .{
    .slots = abi.slotsOf(abi.DisksApi),
    .count = diskCount,
    .info = diskInfo,
    .read = diskRead,
    .write = diskWrite,
    .changed = diskChanged,
    .sync = diskSync,
    .reserved_disks = @splat(&notSupported),
};

const keyb_group: abi.KeybApi = .{
    .slots = abi.slotsOf(abi.KeybApi),
    .count = keybCount,
    .name = keybName,
    .active = keybActive,
    .set_active = keybSetActive,
    .loaded = keybLoaded,
    .set_loaded = keybSetLoaded,
    .reserved_keyb = @splat(&notSupported),
};

const tasks = @import("tasks.zig");

const cores_group: abi.CoresApi = .{
    .slots = abi.slotsOf(abi.CoresApi),
    .count = coreCount,
    .start = coreStart,
    .busy = coreBusy,
    .wait = coreWait,
    .set_affinity = coreSetAffinity,
    .affinity = coreAffinity,
    .reserved_cores = @splat(&notSupported),
};

const tasks_group: abi.TasksApi = .{
    .slots = abi.slotsOf(abi.TasksApi),
    .spawn = taskSpawn,
    .wait = taskWait,
    .ended = taskEnded,
    .id = taskId,
    .yield = taskYield,
    .set_priority = taskSetPriority,
    .priority = taskPriority,
    .info = taskInfo,
    .spawn_ex = taskSpawnEx,
    .wait_any = taskWaitAny,
    .wait_end = taskWaitEnd,
    .parent = taskParent,
    .times = taskTimes,
    .spawn_env = taskSpawnEnv,
    .set_policy = taskSetPolicy,
    .policy = taskPolicy,
    .reserved_tasks = @splat(&notSupported),
    .mutex_create = mutexCreate,
    .mutex_lock = mutexLock,
    .mutex_unlock = mutexUnlock,
    .mutex_destroy = mutexDestroy,
    .mutex_try_lock = mutexTryLock,
    .set_deadline = taskSetDeadline,
    .deadline = taskDeadline,
    .reserved_mutexes = @splat(&notSupported),
};

const threads_group: abi.ThreadsApi = .{
    .slots = abi.slotsOf(abi.ThreadsApi),
    .create = threadCreate,
    .join = threadJoin,
    .detach = threadDetach,
    .exit = threadExit,
    .set_local = threadSetLocal,
    .local = threadLocal,
    .set_thread_pointer = threadSetPointer,
    .default_stack_size = threadDefaultStack,
    .futex_wait = futexWait,
    .futex_wake = futexWake,
    .cond_create = condCreate,
    .cond_wait = condWait,
    .cond_signal = condSignal,
    .cond_broadcast = condBroadcast,
    .cond_destroy = condDestroy,
    .futex_requeue = futexRequeue,
    .reserved_conds = @splat(&notSupported),
    .sem_create = semCreate,
    .sem_wait = semWait,
    .sem_post = semPost,
    .sem_value = semValue,
    .sem_destroy = semDestroy,
    .counter_create = counterCreate,
    .reserved_sems = @splat(&notSupported),
};

const net_group: abi.NetApi = .{
    .slots = abi.slotsOf(abi.NetApi),
    .info = netInfo,
    .renew = netRenew,
    .release = netRelease,
    .interface = netInterface,
    .route = netRoute,
    .reserved_interface = @splat(&notSupported),
    .resolve = netResolve,
    .ping = netPing,
    .arp_entry = netArpEntry,
    .arp_add = netArpAdd,
    .arp_remove = netArpRemove,
    .connection = netConnection,
    .reserved_names = @splat(&notSupported),
    .socket = netSocket,
    .bind = netBind,
    .listen = netListen,
    .accept = netAccept,
    .connect = netConnect,
    .send = netSend,
    .recv = netRecv,
    .send_to = netSendTo,
    .recv_from = netRecvFrom,
    .shutdown = netShutdown,
    .address = netAddress,
    .set_option = netSetOption,
    .get_option = netGetOption,
    .recv_via = netRecvVia,
    .send_via = netSendVia,
    .reserved_sockets = @splat(&notSupported),
};

const sound_group: abi.SoundApi = .{
    .slots = abi.slotsOf(abi.SoundApi),
    .tone = soundTone,
    .beep = soundBeep,
    .soft_tone = soundSoftTone,
    .reserved_speaker = @splat(&notSupported),
    .open = soundOpen,
    .write = soundWrite,
    .queued = soundQueued,
    .close = soundClose,
    .set_volume = soundSetVolume,
    .volume = soundVolume,
    .reserved_samples = @splat(&notSupported),
};

const signals_group: abi.SignalsApi = .{
    .slots = abi.slotsOf(abi.SignalsApi),
    .send = signalSend,
    .set_handler = signalSetHandler,
    .mask = signalMask,
    .pending = signalPending,
    .alarm = signalAlarm,
    .wait = signalWait,
    .set_timer = signalSetTimer,
    .timer = signalTimer,
    .reserved_signals = @splat(&notSupported),
};

// TASKS (TASKS.ZIG)

fn taskSpawn(path: [*]const u8, len: usize, args: [*]const u8, args_len: usize) callconv(abi.cc) i32 {
    return spawnWith(path[0..len], args[0..args_len], .{});
}

fn taskSpawnEx(path: [*]const u8, len: usize, args: [*]const u8, args_len: usize, options: *const abi.SpawnOptions) callconv(abi.cc) i32 {
    const opts = spawnOptions(options) catch |err| return failInt(fs.errorCode(err));
    return spawnWith(path[0..len], args[0..args_len], opts);
}

fn taskSpawnEnv(path: [*]const u8, len: usize, args: [*]const u8, args_len: usize, options: ?*const abi.SpawnOptions, env_block: [*]const u8, env_len: usize) callconv(abi.cc) i32 {
    var opts: tasks.SpawnOptions = if (options) |o| spawnOptions(o) catch |err| return failInt(fs.errorCode(err)) else .{};
    opts.env = env_block[0..env_len];
    return spawnWith(path[0..len], args[0..args_len], opts);
}

fn spawnOptions(options: *const abi.SpawnOptions) Error!tasks.SpawnOptions {
    var opts: tasks.SpawnOptions = .{};
    if (options.size < @offsetOf(abi.SpawnOptions, "err")) return error.InvalidArgument;
    if (options.priority >= tasks.priorities) return error.InvalidArgument;
    if (options.priority >= 0) opts.priority = @intCast(options.priority);
    opts.input = try inputOf(options.input);
    opts.output = try outputOf(options.output);
    // An older, shorter record has no err:
    // the error output follows the output
    opts.errout = if (options.size >= @offsetOf(abi.SpawnOptions, "err") + 4)
        (if (options.err == abi.SpawnOptions.same_stream) tasks.world().errout else try outputOf(options.err))
    else
        opts.output;
    // Only a remote console's handle counts (C code zero-fills the field)
    if (options.size >= @offsetOf(abi.SpawnOptions, "term") + 4 and options.term >= 0) {
        if (slotOf(options.term)) |o| switch (o.*) {
            .term => |t| opts.term = t,
            else => {},
        } else |_| {}
    }
    return opts;
}

fn failInt(code: abi.ErrorCode) i32 {
    prog().last_error = code;
    return -1;
}

// A stream for SpawnOptions: a handle,
// or the caller's current one, none, NUL
fn inputOf(code: i32) Error!stdio.Input {
    return switch (code) {
        abi.SpawnOptions.same_stream => tasks.world().input,
        abi.SpawnOptions.no_stream => .none,
        abi.SpawnOptions.nul_stream => .nul,
        else => switch ((try slotOf(code)).*) {
            .file => |f| .{ .file = f },
            .pipe => |pipe| .{ .pipe = pipe },
            .reader => |c| .{ .channel = c },
            .null_dev => .nul,
            .tty => .none,
            .dir, .writer, .socket, .term, .queue, .counter => error.InvalidHandle,
        },
    };
}

fn outputOf(code: i32) Error!stdio.Output {
    return switch (code) {
        abi.SpawnOptions.same_stream, abi.SpawnOptions.caller_output => tasks.world().output,
        abi.SpawnOptions.caller_error => tasks.world().errout,
        abi.SpawnOptions.no_stream => .screen,
        abi.SpawnOptions.nul_stream => .nul,
        else => switch ((try slotOf(code)).*) {
            .file => |f| .{ .file = f },
            .pipe => |pipe| .{ .pipe = pipe },
            .writer => |c| .{ .channel = c },
            .null_dev => .nul,
            .tty => .screen,
            .dir, .reader, .socket, .term, .queue, .counter => error.InvalidHandle,
        },
    };
}

fn spawnWith(path: []const u8, args: []const u8, opts: tasks.SpawnOptions) i32 {
    const id = tasks.spawn(path, args, opts) catch |err| {
        prog().last_error = switch (err) {
            error.NotSupported => .not_supported,
            error.NotFound => .not_found,
            error.NotProgram => .invalid_argument,
            error.OutOfMemory => .out_of_memory,
            error.TooMany => .too_many_open,
            error.InvalidArgument => .invalid_argument,
        };
        return -1;
    };
    prog().last_error = .none;
    return @intCast(id);
}

fn taskWait(id: u32) callconv(abi.cc) i32 {
    const code = tasks.wait(id) catch |err| return failInt(waitErrorCode(err));
    prog().last_error = .none;
    return code;
}

fn waitErrorCode(err: tasks.WaitError) abi.ErrorCode {
    return switch (err) {
        error.NotSupported => .not_supported,
        error.Interrupted => .interrupted,
        error.NoChild => .no_child,
        error.InvalidArgument => .invalid_argument,
    };
}

fn taskWaitAny(flags: u32, out: *abi.TaskEnd) callconv(abi.cc) i32 {
    const e = (tasks.waitAny(flags & abi.WaitFlags.no_hang == 0) catch |err| return failInt(waitErrorCode(err))) orelse {
        prog().last_error = .none;
        return 0;
    };
    out.* = .{ .id = e.id, .code = e.code, .signal = e.signal };
    prog().last_error = .none;
    return @intCast(e.id);
}

fn taskWaitEnd(id: u32, out: *abi.TaskEnd) callconv(abi.cc) bool {
    const e = tasks.waitEnded(id) catch |err| return fail(waitErrorCode(err));
    out.* = .{ .id = e.id, .code = e.code, .signal = e.signal };
    prog().last_error = .none;
    return true;
}

fn taskParent() callconv(abi.cc) u32 {
    return tasks.currentTask().parent;
}

fn taskTimes(out: *abi.CpuTimes) callconv(abi.cc) void {
    const t = tasks.times();
    out.* = .{ .total_ms = t.total, .idle_ms = t.idle };
}

fn taskEnded(id: u32, code: *u8) callconv(abi.cc) bool {
    code.* = tasks.ended(id) orelse return false;
    return true;
}

fn taskId() callconv(abi.cc) u32 {
    return tasks.currentId();
}

fn taskYield() callconv(abi.cc) void {
    tasks.yield();
}

// Only one's own tasks, unless root (as with signals)
fn taskSetPriority(id: u32, priority: u32) callconv(abi.cc) bool {
    const allowed = tasks.mayControl(id) orelse return fail(.invalid_argument);
    if (!allowed) return fail(.access_denied);
    if (priority >= tasks.priorities or !tasks.setPriority(id, @intCast(priority))) return fail(.invalid_argument);
    prog().last_error = .none;
    return true;
}

fn taskSetPolicy(id: u32, policy: u32) callconv(abi.cc) bool {
    const allowed = tasks.mayControl(id) orelse return fail(.invalid_argument);
    if (!allowed) return fail(.access_denied);
    if ((policy != abi.Policy.fifo and policy != abi.Policy.rr) or !tasks.setPolicy(id, @enumFromInt(policy))) return fail(.invalid_argument);
    prog().last_error = .none;
    return true;
}

fn taskPolicy(id: u32) callconv(abi.cc) i32 {
    const t = tasks.byId(id) orelse return -1;
    return @intFromEnum(t.policy);
}

fn taskSetDeadline(id: u32, runtime: u64, deadline: u64, period: u64) callconv(abi.cc) bool {
    const allowed = tasks.mayControl(id) orelse return fail(.invalid_argument);
    if (!allowed) return fail(.access_denied);
    tasks.setDeadline(id, runtime, deadline, period) catch |err| return fail(switch (err) {
        error.Overloaded => .would_block,
        else => .invalid_argument,
    });
    prog().last_error = .none;
    return true;
}

fn taskDeadline(id: u32, out: *abi.DeadlineSetting) callconv(abi.cc) bool {
    const d = tasks.deadlineOf(id) orelse return fail(.invalid_argument);
    out.* = .{ .runtime = d.runtime, .deadline = d.deadline, .period = d.period };
    prog().last_error = .none;
    return true;
}

fn taskPriority(id: u32) callconv(abi.cc) i32 {
    const t = tasks.byId(id) orelse return -1;
    return t.priority;
}

fn taskInfo(index: u32, info: *abi.TaskInfo) callconv(abi.cc) bool {
    var n: u32 = 0;
    for (&tasks.tasks) |*t| {
        if (t.state == .free) continue;
        if (n == index) {
            info.* = .{
                .id = t.id,
                .parent = t.parent,
                .priority = t.priority,
                .base_priority = t.base_priority,
                .state = switch (t.state) {
                    .ready => abi.TaskState.ready,
                    .running => abi.TaskState.running,
                    .sleeping => abi.TaskState.sleeping,
                    .waiting, .mutex, .blocked, .io => abi.TaskState.waiting,
                    .stopped => abi.TaskState.stopped,
                    else => abi.TaskState.ended,
                },
                .name = [_]u8{0} ** 32,
                .cpu_ms = t.cpu_ms,
            };
            const name = t.name();
            @memcpy(info.name[0..name.len], name);
            return true;
        }
        n += 1;
    }
    return false;
}

fn mutexCreate() callconv(abi.cc) i32 {
    const m = tasks.mutexCreate(prog()) orelse {
        prog().last_error = .out_of_memory;
        return -1;
    };
    return @intCast(m);
}

fn mutexLock(m: i32) callconv(abi.cc) bool {
    if (m < 0) return fail(.invalid_argument);
    tasks.mutexLock(@intCast(m)) catch return fail(.invalid_argument);
    prog().last_error = .none;
    return true;
}

fn mutexUnlock(m: i32) callconv(abi.cc) bool {
    if (m < 0) return fail(.invalid_argument);
    tasks.mutexUnlock(@intCast(m)) catch return fail(.invalid_argument);
    prog().last_error = .none;
    return true;
}

fn mutexDestroy(m: i32) callconv(abi.cc) void {
    if (m >= 0) tasks.mutexDestroy(@intCast(m));
}

fn mutexTryLock(m: i32) callconv(abi.cc) bool {
    if (m < 0) return fail(.invalid_argument);
    tasks.mutexTryLock(@intCast(m)) catch |err| return fail(if (err == error.Busy) .would_block else .invalid_argument);
    prog().last_error = .none;
    return true;
}

// THREADS

fn threadCreate(entry: abi.ThreadEntry, arg: ?*anyopaque, stack_size: usize, priority: i32) callconv(abi.cc) i32 {
    if (priority >= tasks.priorities) return failInt(.invalid_argument);
    const prio: ?u8 = if (priority < 0) null else @intCast(priority);
    const id = tasks.threadCreate(@intFromPtr(entry), @intFromPtr(arg), stack_size, prio) catch |err| return failInt(switch (err) {
        error.NotSupported => .not_supported,
        error.OutOfMemory => .out_of_memory,
        error.TooMany => .too_many_open,
        else => .invalid_argument,
    });
    prog().last_error = .none;
    return @intCast(id);
}

fn threadJoin(id: u32, out: *usize) callconv(abi.cc) bool {
    out.* = tasks.threadJoin(id) catch return fail(.invalid_argument);
    prog().last_error = .none;
    return true;
}

fn threadDetach(id: u32) callconv(abi.cc) bool {
    tasks.threadDetach(id) catch return fail(.invalid_argument);
    prog().last_error = .none;
    return true;
}

fn threadExit(value: usize) callconv(abi.cc) noreturn {
    if (!tasks.isThread()) exit(0); // the program's own task: the program ends
    tasks.threadExit(value);
}

fn threadSetLocal(value: usize) callconv(abi.cc) void {
    tasks.setTls(value);
}

fn threadLocal() callconv(abi.cc) usize {
    return tasks.tls();
}

fn threadSetPointer(tp: usize) callconv(abi.cc) void {
    tasks.setThreadPointer(tp);
}

fn threadDefaultStack() callconv(abi.cc) usize {
    return platform.config.stacks.thread;
}

// A timeout from the API: -1 none, else milliseconds
fn timeoutOf(ms: i32) ?u32 {
    return if (ms < 0) null else @intCast(ms);
}

fn condCreate() callconv(abi.cc) i32 {
    const c = tasks.condCreate(prog()) orelse return failInt(.out_of_memory);
    prog().last_error = .none;
    return @intCast(c);
}

fn condWait(c: i32, m: i32, timeout_ms: i32) callconv(abi.cc) bool {
    if (c < 0 or m < 0) return fail(.invalid_argument);
    tasks.condWait(@intCast(c), @intCast(m), timeoutOf(timeout_ms)) catch |err| return fail(if (err == error.TimedOut) .timed_out else .invalid_argument);
    prog().last_error = .none;
    return true;
}

fn condSignal(c: i32) callconv(abi.cc) void {
    if (c >= 0) tasks.condSignal(@intCast(c), false);
}

fn condBroadcast(c: i32) callconv(abi.cc) void {
    if (c >= 0) tasks.condSignal(@intCast(c), true);
}

fn condDestroy(c: i32) callconv(abi.cc) void {
    if (c >= 0) tasks.condDestroy(@intCast(c));
}

fn futexErrorCode(err: tasks.FutexError) abi.ErrorCode {
    return switch (err) {
        error.InvalidArgument => .invalid_argument,
        error.WouldBlock => .would_block,
        error.TimedOut => .timed_out,
        error.Interrupted => .interrupted,
    };
}

fn futexWait(addr: *const u32, expected: u32, timeout_ms: i32, bits: u32) callconv(abi.cc) abi.ErrorCode {
    const code: abi.ErrorCode = if (tasks.futexWait(addr, expected, timeoutOf(timeout_ms), bits)) .none else |err| futexErrorCode(err);
    prog().last_error = code;
    return code;
}

fn futexWake(addr: *const u32, count: u32, bits: u32) callconv(abi.cc) i32 {
    const n = tasks.futexWake(addr, count, bits) catch |err| return failInt(futexErrorCode(err));
    prog().last_error = .none;
    return @intCast(n);
}

fn futexRequeue(addr: *const u32, expected: u32, count: u32, addr2: *const u32, move_count: u32) callconv(abi.cc) i32 {
    const n = tasks.futexRequeue(addr, expected, count, addr2, move_count) catch |err| return failInt(futexErrorCode(err));
    prog().last_error = .none;
    return @intCast(n);
}

fn semCreate(value: u32) callconv(abi.cc) i32 {
    const sm = tasks.semCreate(prog(), value) orelse return failInt(.out_of_memory);
    prog().last_error = .none;
    return @intCast(sm);
}

fn semWait(sm: i32, timeout_ms: i32) callconv(abi.cc) bool {
    if (sm < 0) return fail(.invalid_argument);
    tasks.semWait(@intCast(sm), timeoutOf(timeout_ms)) catch |err| return fail(switch (err) {
        error.TimedOut => .timed_out,
        error.Interrupted => .interrupted,
        error.WouldBlock => .would_block,
        error.InvalidArgument => .invalid_argument,
    });
    prog().last_error = .none;
    return true;
}

fn semPost(sm: i32) callconv(abi.cc) bool {
    if (sm < 0) return fail(.invalid_argument);
    tasks.semPost(@intCast(sm)) catch return fail(.invalid_argument);
    prog().last_error = .none;
    return true;
}

fn semValue(sm: i32) callconv(abi.cc) i32 {
    if (sm < 0) return -1;
    return @intCast(tasks.semValue(@intCast(sm)) orelse return -1);
}

fn semDestroy(sm: i32) callconv(abi.cc) void {
    if (sm >= 0) tasks.semDestroy(@intCast(sm));
}

// SIGNALS

fn signalSend(task: u32, sig: u32) callconv(abi.cc) bool {
    tasks.kill(task, sig) catch |err| return fail(switch (err) {
        error.NotFound => .not_found,
        error.AccessDenied => .access_denied,
        error.InvalidArgument => .invalid_argument,
    });
    prog().last_error = .none;
    return true;
}

fn signalSetHandler(entry: ?abi.SignalEntry, caught: u64, ignored: u64) callconv(abi.cc) void {
    const p = prog();
    p.sig_entry = entry;
    p.sig_caught = if (entry != null) caught else 0;
    p.sig_ignored = ignored & ~p.sig_caught;
}

fn signalMask(how: u32, set: u64) callconv(abi.cc) u64 {
    const old = tasks.signalMask();
    switch (how) {
        0 => tasks.setSignalMask(old | set),
        1 => tasks.setSignalMask(old & ~set),
        2 => tasks.setSignalMask(set),
        else => {},
    }
    return old;
}

fn signalPending() callconv(abi.cc) u64 {
    return tasks.pendingSignals();
}

fn signalAlarm(ms: u64) callconv(abi.cc) u64 {
    return tasks.alarm(ms);
}

fn signalSetTimer(sig: u32, first: u64, interval: u64, old: ?*abi.TimerSetting) callconv(abi.cc) bool {
    if (sig == 0 or sig >= 64) return false;
    const before = tasks.setTimer(sig, first, interval);
    if (old) |o| o.* = .{ .left = before.left, .interval = before.interval };
    return true;
}

fn signalTimer(now: *abi.TimerSetting) callconv(abi.cc) void {
    const t = tasks.timer();
    now.* = .{ .left = t.left, .interval = t.interval };
}

// Waits for a signal with mask blocked meanwhile, and handles
// it here, before the mask is put back (sigsuspend)
fn signalWait(mask: u64) callconv(abi.cc) void {
    const old = tasks.signalMask();
    tasks.setSignalMask(mask);
    tasks.waitSignal();
    const held = tasks.dropKernel(); // handlers are the program's code
    deliverSignals();
    if (held) _ = tasks.enterKernel();
    tasks.setSignalMask(old);
}

// The current task's signals, each as its program
// wants it (abi.SignalsApi): its handler,
// ignored, or the default action.
// From tasks.leaving and before a preempted
// program goes on; never with the kernel lock.
pub fn deliverSignals() void {
    const S = abi.Signal;
    while (tasks.nextSignal()) |sig| {
        const p = tasks.currentProgram() orelse continue; // no program: nothing to do
        const b = @as(u64, 1) << @intCast(sig);
        if (sig == S.kill) terminate(p, sig);
        if (p.sig_caught & b != 0) {
            if (p.sig_entry) |entry| {
                const old = tasks.signalMask();
                tasks.setSignalMask(old | b); // not again while its handler runs
                entry(@intCast(sig));
                tasks.setSignalMask(old);
                continue;
            }
        }
        if (p.sig_ignored & b != 0 or tasks.ignoredByDefault(sig)) continue;
        if (sig == S.stop or sig == S.tstp or sig == S.ttin or sig == S.ttou) {
            tasks.stopSelf();
            continue;
        }
        terminate(p, sig);
    }
}

// A CPU fault in the running program's
// code (platform.faults, metal):
// its signal handler runs if any
// (returning would re-fault, so the
// program then ends); otherwise the
// program ends with 128 + the signal
pub fn programFault(f: *const platform.Fault) noreturn {
    const p = tasks.currentProgram() orelse @panic("CPU fault outside a program");
    const sig: u32 = f.signal;
    const b = @as(u64, 1) << @intCast(sig);
    if (p.sig_caught & b != 0 and tasks.signalMask() & b == 0) {
        if (p.sig_entry) |entry| {
            tasks.setSignalMask(tasks.signalMask() | b);
            entry(@intCast(sig));
        }
    } else {
        const took = tasks.enterKernel();
        var buf: [160]u8 = undefined;
        const name = std.fs.path.basenameWindows(p.path_buf[0..p.path_len]);
        con.printError(if (f.addr != 0)
            std.fmt.bufPrint(&buf, "{s}: {s} at {x}, address {x} ({s})\n", .{ name, f.what, f.pc, f.addr, signalName(sig) }) catch "CPU fault\n"
        else
            std.fmt.bufPrint(&buf, "{s}: {s} at {x} ({s})\n", .{ name, f.what, f.pc, signalName(sig) }) catch "CPU fault\n");
        if (took) tasks.leaveKernel();
    }
    terminate(p, sig);
}

fn signalName(sig: u32) []const u8 {
    return switch (sig) {
        4 => "SIGILL",
        5 => "SIGTRAP",
        7 => "SIGBUS",
        8 => "SIGFPE",
        11 => "SIGSEGV",
        else => "signal",
    };
}

// A signal ends the program (exit code 128 + the signal, or
// what a thread's exit asked for)
fn terminate(p: *Program, sig: u32) noreturn {
    const code: u8 = p.pending_exit orelse @intCast(128 + sig);
    if (tasks.isThread()) {
        if (!tasks.doomed()) tasks.requestProgramExit(p, code);
        tasks.threadExit(0);
    }
    if (p.parent == null and p.pending_exit == null) tasks.setTermSignal(@intCast(sig));
    arch.exitTo(p.exit_saved, code);
}

// CORES
// The jobs run program code on other cores (platform.cores, or
// pinned threads once those cores run tasks: tasks.jobStart);
// each core's job belongs to the program that started it, which
// waits for it when it ends (end): its
// code and data are that program's memory.

const max_cores = 64;
var core_owner = [_]?*Program{null} ** max_cores;

fn coreCount() callconv(abi.cc) u32 {
    return @intCast(@min(platform.cores.count(), max_cores));
}

fn coreStart(core: u32, job: abi.CoreJob, arg: ?*anyopaque) callconv(abi.cc) bool {
    if (core == 0 or core >= coreCount()) return fail(.invalid_argument);
    // Cores that run tasks take a job as a thread pinned to them
    const started = if (tasks.smpActive()) tasks.jobStart(core, @intFromPtr(job), @intFromPtr(arg)) else platform.cores.start(core, job, arg);
    if (!started) return fail(.access_denied);
    core_owner[core] = prog();
    return true;
}

fn coreBusy(core: u32) callconv(abi.cc) bool {
    if (core == 0 or core >= coreCount()) return false;
    return if (tasks.smpActive()) tasks.jobBusy(core) else platform.cores.busy(core);
}

fn coreSetAffinity(id: u32, mask: u64) callconv(abi.cc) bool {
    const allowed = tasks.mayControl(id) orelse return fail(.invalid_argument);
    if (!allowed) return fail(.access_denied);
    if (!tasks.setAffinity(id, mask)) return fail(.invalid_argument);
    prog().last_error = .none;
    return true;
}

fn coreAffinity(id: u32) callconv(abi.cc) u64 {
    return tasks.affinity(id) orelse 0;
}

fn coreWait(core: u32) callconv(abi.cc) void {
    if (core == 0 or core >= coreCount()) return;
    if (tasks.smpActive()) tasks.jobWait(core) else platform.cores.wait(core);
}

// SOUND
// The speaker belongs to the program that last set a tone: its
// end silences it.
// Samples go to a sound card's driver (sound.zig).

var speaker_owner: ?*Program = null;

fn soundTone(hz: u32) callconv(abi.cc) bool {
    return speakerTone(hz, false);
}

fn soundSoftTone(hz: u32) callconv(abi.cc) bool {
    return speakerTone(hz, true);
}

fn speakerTone(hz: u32, soft: bool) bool {
    if (!platform.speaker.available()) return fail(.not_supported);
    if (hz != 0 and (hz < 20 or hz > 20_000)) return fail(.invalid_argument);
    platform.speaker.tone(hz, soft);
    speaker_owner = if (hz == 0) null else prog();
    prog().last_error = .none;
    return true;
}

fn soundBeep(hz: u32, ms: u32) callconv(abi.cc) bool {
    if (!soundTone(hz)) return false;
    sleep(ms);
    return soundTone(0);
}

fn soundError(err: sound.Error) abi.ErrorCode {
    return switch (err) {
        error.NotSupported => .not_supported,
        error.InvalidArgument => .invalid_argument,
        error.AccessDenied => .access_denied,
        error.InvalidHandle => .invalid_handle,
    };
}

fn soundOpen(rate: u32, channels: u32, bits: u32) callconv(abi.cc) i32 {
    const h = sound.open(prog(), rate, channels, bits) catch |err| return failInt(soundError(err));
    prog().last_error = .none;
    return h;
}

fn soundWrite(handle: i32, data: [*]const u8, len: usize) callconv(abi.cc) isize {
    const n = sound.write(prog(), handle, data[0..len]) catch |err| {
        prog().last_error = soundError(err);
        return -1;
    };
    prog().last_error = .none;
    return @intCast(n);
}

fn soundQueued(handle: i32) callconv(abi.cc) usize {
    const n = sound.queued(prog(), handle) catch |err| {
        prog().last_error = soundError(err);
        return 0;
    };
    prog().last_error = .none;
    return n;
}

fn soundClose(handle: i32, drop: bool) callconv(abi.cc) void {
    sound.close(prog(), handle, drop) catch |err| {
        prog().last_error = soundError(err);
        return;
    };
    prog().last_error = .none;
}

fn soundSetVolume(percent: u32) callconv(abi.cc) bool {
    sound.setVolume(percent) catch |err| return fail(soundError(err));
    prog().last_error = .none;
    return true;
}

fn soundVolume() callconv(abi.cc) i32 {
    const v = sound.getVolume() catch |err| return failInt(soundError(err));
    prog().last_error = .none;
    return @intCast(v);
}

fn fail(code: abi.ErrorCode) bool {
    prog().last_error = code;
    return false;
}

const CtrlC = enum {
    ends, // the default
    key, // set_ctrl_c(true): an ordinary key
    caught, // catch_ctrl_c(true): remembered for ctrl_c_pressed (command interpreters)
};

pub const Program = struct {
    const max_handles = 128;
    handles: [max_handles]?Open = .{null} ** max_handles,
    blocks: ?*Block = null,
    parent: ?*Program = null,
    last_error: abi.ErrorCode = .none, // per program, so exec doesn't mix them up
    exit_saved: usize = 0, // where arch.exitTo returns to (set by arch.callOnStack)
    ctrl_c: CtrlC = .ends,
    // Restored when it ends
    start_input: stdio.Input = .none,
    start_output: stdio.Output = .screen,
    start_errout: stdio.Output = .screen,
    var_level: usize = 1,
    start_priority: u8 = tasks.default_priority, // its task's, put back at its end
    start_policy: tasks.Policy = .rr,
    start_affinity: u64 = ~@as(u64, 0),
    // Signals: the handler for those caught, those ignored; a
    // thread's exit asking the program to end with this code
    sig_entry: ?abi.SignalEntry = null,
    sig_caught: u64 = 0,
    sig_ignored: u64 = 0,
    pending_exit: ?u8 = null,
    // Its own current directories and drive (POSIX: per process),
    // from its starter's; the drive goes back when it ends
    cwds: fs.CwdSet = .{},
    start_drive: ?*fs.Drive = null,
    ids: perm.Ids = .{}, // the user it runs as (perm.zig)
    path_buf: [fs.max_path + 2]u8 = undefined, // the .APP file, "C:\APPS\DEMO.APP"
    path_len: usize = 0,
    // The libraries it holds (libraries.zig), released when it ends
    libraries: [libraries.per_program]u8 = undefined,
    library_count: usize = 0,

    // drive: its letter; path: absolute on the drive
    pub fn setPath(self: *Program, drive: u8, path: []const u8) void {
        if (path.len > fs.max_path) return;
        self.path_buf[0] = drive;
        self.path_buf[1] = ':';
        @memcpy(self.path_buf[2..][0..path.len], path);
        self.path_len = path.len + 2;
    }
};

// The running task's program: tasks.world().program

fn prog() *Program {
    return tasks.world().program.?;
}

// ERRORS
// Every call that can fail sets last_error (.none on success).

const Error = fs.Error;

fn result(comptime T: type, r: Error!T, failed: T) T {
    if (r) |v| {
        prog().last_error = .none;
        return v;
    } else |err| {
        prog().last_error = fs.errorCode(err);
        return failed;
    }
}

fn succeeded(r: Error!void) bool {
    return result(bool, if (r) true else |err| err, false);
}

fn lastError() callconv(abi.cc) abi.ErrorCode {
    return prog().last_error;
}

// From the loader, when a program starts
pub fn begin(p: *Program) void {
    p.parent = tasks.world().program;
    p.start_input = tasks.world().input;
    p.start_output = tasks.world().output;
    p.start_errout = tasks.world().errout;
    p.var_level = env.level();
    p.start_priority = tasks.ownPriority();
    p.start_policy = tasks.ownPolicy();
    p.start_affinity = tasks.ownAffinity();
    p.start_drive = tasks.world().drive;
    p.cwds = .{};
    if (tasks.world().program) |parent| p.cwds.inherit(&parent.cwds) else p.cwds.inherit(&tasks.currentTask().cwds);
    // The starter's user, or the program file's owner if it is setuid
    const starter = if (tasks.world().program) |parent| &parent.ids else &tasks.currentTask().ids;
    const own_path = p.path_buf[0..p.path_len];
    p.ids = starter.*;
    if (own_path.len > 2) {
        if (fs.driveByLetter(own_path[0])) |d| p.ids = perm.startIds(starter, d, own_path[2..]);
    }
    tasks.world().program = p;
    tasks.world().catching = true; // Ctrl+C ends it, unless it asks for it as a key
}

// From the loader, when a program ends: frees what it left behind
pub fn end(p: *Program) void {
    tasks.programEnded(p); // its mutexes go
    // A program run in the foreground shares its parent's task: a
    // priority, policy or affinity it set doesn't outlast it
    _ = tasks.setPriority(tasks.currentId(), p.start_priority);
    _ = tasks.setPolicy(tasks.currentId(), p.start_policy);
    _ = tasks.setAffinity(tasks.currentId(), p.start_affinity);
    // Its jobs on other cores finish first:
    // they run its code, in its memory
    for (&core_owner, 0..) |*owner, core| {
        if (owner.* != p) continue;
        if (tasks.smpActive()) tasks.jobWait(core) else platform.cores.wait(@intCast(core));
        owner.* = null;
    }
    if (speaker_owner == p) {
        platform.speaker.tone(0, false);
        speaker_owner = null;
    }
    sound.programEnded(p);
    // Its redirections end, before the files and pipes they use are closed
    tasks.world().input = p.start_input;
    tasks.world().output = p.start_output;
    tasks.world().errout = p.start_errout;
    for (&p.handles) |*h| {
        if (h.*) |o| releaseOpen(o) catch {};
        h.* = null;
    }
    while (p.blocks) |b| free(b.data());
    libraries.programEnded(p);
    while (env.level() > p.var_level) env.pop();
    closeTab(p); // its tab, if it had one
    if (mouse_owner) |owner| if (owner == p) {
        mouse_owner = null;
    };
    if (key_events_owner) |owner| if (owner == p) {
        _ = con.keyEvents(false);
        key_events_owner = null;
    };
    con.textInput(false); // characters kept for text_input are the shell's again
    scrollback.programEnded(p); // ended on the alternate screen: the main one back
    tasks.world().program = p.parent;
    // Its current directories go; the drive is its starter's again
    p.cwds.release();
    tasks.world().drive = p.start_drive;
    con.resetEscape();
    con.setEditRow(null); // a line editor stopped by Ctrl+C or exit
    // A pending Ctrl+C reaches the parent: it ends it or is caught
    // by it (the flag stays set); a parent
    // taking Ctrl+C as a key goes on
    if (tasks.world().program) |parent| {
        tasks.world().catching = parent.ctrl_c != .key;
        if (parent.ctrl_c == .key) con.clearBreak();
    } else tasks.world().catching = true;
    // Back in the kernel: undo screen settings the program changed
    if (tasks.world().program == null) {
        con.setColor(con.default_fg, con.default_bg);
        con.showCursor(true);
    }
}

// CONSOLE AND CTRL+C

// Ends the program as exit(255) would if Ctrl+C was pressed and
// it neither takes it as a key nor catches it; called from
// calls programs make often
fn checkCtrlC() void {
    if (prog().ctrl_c == .ends and con.breakRequested()) stopByCtrlC();
}

fn stopByCtrlC() noreturn {
    arch.exitTo(prog().exit_saved, 255);
}

fn setCtrlC(as_key: bool) callconv(abi.cc) void {
    prog().ctrl_c = if (as_key) .key else .ends;
    tasks.world().catching = !as_key;
    if (as_key) con.clearBreak();
}

fn catchCtrlC(on: bool) callconv(abi.cc) void {
    prog().ctrl_c = if (on) .caught else .ends;
    tasks.world().catching = true;
}

fn ctrlCPressed(clear: bool) callconv(abi.cc) bool {
    const pressed = con.breakRequested();
    if (clear) con.clearBreak();
    return pressed;
}

fn print(str: [*]const u8, len: usize) callconv(abi.cc) void {
    checkCtrlC();
    con.print(str[0..len]);
}

// Key codes and modifier bits are passed on unchanged:
// the values must match
comptime {
    for (@typeInfo(platform.Scan).@"struct".decls) |d| {
        if (@field(platform.Scan, d.name) != @field(abi.Scan, d.name)) @compileError("Scan codes differ: " ++ d.name);
    }
    for (@typeInfo(platform.Mod).@"struct".decls) |d| {
        if (@field(platform.Mod, d.name) != @field(abi.Mod, d.name)) @compileError("Mod bits differ: " ++ d.name);
    }
}

fn toApiKey(k: platform.Key) abi.Key {
    const c: u16 = if (k.char > 0xFFFF) '?' else @intCast(k.char);
    return .{ .scan = k.scan, .char = c, .mods = k.mods };
}

fn readKey() callconv(abi.cc) abi.Key {
    return switch (prog().ctrl_c) {
        .key, .caught => toApiKey(con.readKey()),
        .ends => toApiKey(con.readKeyUnlessBreak() orelse stopByCtrlC()),
    };
}

fn editLine(row: i32) callconv(abi.cc) void {
    con.setEditRow(if (row < 0) null else @intCast(row));
}

fn pollKey(key: *abi.Key) callconv(abi.cc) bool {
    checkCtrlC();
    key.* = toApiKey(con.pollKey() orelse return false);
    return true;
}

// GRAPHICS, IN TABS
//
// Each program that switches to graphics gets a tab:
// its mode, its palette and its last picture (a pointer into
// its own memory, good while it runs). The text console is
// the tab before the first. Alt+Tab or Win+Tab (console.zig)
// brings the next one to the screen; only the front tab is
// shown and only its program gets keys and the mouse (its
// task is the foreground, tasks.zig); the others go on,
// their pictures kept. A tab goes when its program ends
// graphics or ends; the one before it comes forward.

const max_tabs = 8;

const Tab = struct {
    program: *Program,
    task: u32, // its program's task: the foreground while in front
    width: u32,
    height: u32,
    kind: enum { indexed, dos, rgb },
    palette: [768]u8 = [_]u8{0} ** 768,
    frame: usize = 0, // the last picture's address; 0: none yet
    title: [32]u8 = undefined,
    title_len: usize = 0,
};

var tabs: [max_tabs]Tab = undefined;
var tab_count: usize = 0;
var front: ?usize = null; // null: the text console

fn tabOf(p: *const Program) ?usize {
    for (tabs[0..tab_count], 0..) |*t, i| {
        if (t.program == p) return i;
    }
    return null;
}

fn pixels(t: *const Tab) usize {
    return @as(usize, t.width) * t.height;
}

// Tab i (null: the console) to the screen: its mode,
// palette, last picture
fn show(i: ?usize) void {
    scrollback.leave();
    const t = &tabs[
        i orelse {
            platform.graphics.end();
            front = null;
            tasks.setFront(0);
            return;
        }
    ];
    const started = switch (t.kind) {
        .indexed => platform.graphics.begin(t.width, t.height, false),
        .dos => platform.graphics.begin(t.width, t.height, true),
        .rgb => platform.graphics.beginRgb(t.width, t.height),
    };
    started catch return; // the screen can't show it: stays as it is
    front = i;
    tasks.setFront(t.task);
    if (t.kind == .rgb) {
        if (t.frame != 0) platform.graphics.drawRgb(@as([*]const u32, @ptrFromInt(t.frame))[0..pixels(t)]);
    } else {
        platform.graphics.palette(0, &t.palette);
        if (t.frame != 0) platform.graphics.draw(@as([*]const u8, @ptrFromInt(t.frame))[0..pixels(t)]);
    }
}

// Alt+Tab, Win+Tab: the console, then each tab in turn
pub fn switchTab() void {
    const next: ?usize = if (front) |f| (if (f + 1 < tab_count) f + 1 else null) else if (tab_count > 0) 0 else null;
    if (next == front) return;
    show(next);
}

// Whether p's screen is the one shown: its tab in front, or
// (without a tab) the console
fn inFront(p: *const Program) bool {
    if (tabOf(p)) |i| return front == i;
    return front == null;
}

// A program's tab goes (it ended graphics or ended); the tab
// before it, or the console, comes forward if it was in front
fn closeTab(p: *const Program) void {
    const i = tabOf(p) orelse return;
    std.mem.copyForwards(Tab, tabs[i .. tab_count - 1], tabs[i + 1 .. tab_count]);
    tab_count -= 1;
    if (front) |f| {
        if (f == i) {
            show(if (i > 0) i - 1 else if (tab_count > 0) 0 else null);
        } else if (f > i) front = f - 1;
    }
}

// Not from a remote console (SSH): the screen is someone else's
fn startTab(width: u32, height: u32, kind: @FieldType(Tab, "kind")) Error!void {
    if (con.term() != null) return error.NotSupported;
    if (width == 0 or height == 0) return error.InvalidArgument;
    const p = prog();
    const i = tabOf(p) orelse blk: {
        if (tab_count == max_tabs) return error.TooManyOpen;
        const name = std.fs.path.stem(std.fs.path.basenameWindows(p.path_buf[0..p.path_len]));
        var t: Tab = .{ .program = p, .task = taskOfProgram(), .width = width, .height = height, .kind = kind };
        t.title_len = @min(name.len, t.title.len);
        @memcpy(t.title[0..t.title_len], name[0..t.title_len]);
        tabs[tab_count] = t;
        tab_count += 1;
        break :blk tab_count - 1;
    };
    const t = &tabs[i];
    t.width = width;
    t.height = height;
    t.kind = kind;
    t.frame = 0;
    // A program starting graphics comes to the front
    const was = front;
    show(i);
    if (front != i) {
        if (was != front) show(was);
        closeTab(p);
        return error.NotSupported;
    }
}

// The task input goes to while p's tab is in front: its
// program's own (a thread's program is its main task's)
fn taskOfProgram() u32 {
    const t = tasks.currentTask();
    return if (t.thread) t.main_id else t.id;
}

fn gfxBegin(width: u32, height: u32) callconv(abi.cc) bool {
    return succeeded(startTab(width, height, .indexed));
}

fn gfxBeginDosAspect(width: u32, height: u32) callconv(abi.cc) bool {
    return succeeded(startTab(width, height, .dos));
}

fn gfxBeginRgb(width: u32, height: u32) callconv(abi.cc) bool {
    return succeeded(startTab(width, height, .rgb));
}

fn gfxScreen(info: *abi.ScreenInfo) callconv(abi.cc) bool {
    if (con.term() != null) return fail(.not_supported);
    const s = platform.graphics.screen() orelse return fail(.not_supported);
    info.* = .{ .width = s.width, .height = s.height, .true_color = s.true_color };
    prog().last_error = .none;
    return true;
}

fn gfxModes(sizes: [*]abi.ScreenSize, max: usize) callconv(abi.cc) usize {
    const all = platform.graphics.modes();
    for (all[0..@min(all.len, max)], 0..) |s, i| sizes[i] = .{ .width = s.width, .height = s.height };
    return all.len;
}

// A picture: kept as the tab's last, shown if the tab is in front
fn gfxDrawRgb(pic: [*]const u32) callconv(abi.cc) void {
    checkCtrlC();
    const i = tabOf(prog()) orelse return;
    const t = &tabs[i];
    if (t.kind != .rgb) return;
    t.frame = @intFromPtr(pic);
    if (front == i) platform.graphics.drawRgb(pic[0..pixels(t)]);
}

fn gfxDraw(pic: [*]const u8) callconv(abi.cc) void {
    checkCtrlC();
    const i = tabOf(prog()) orelse return;
    const t = &tabs[i];
    if (t.kind == .rgb) return;
    t.frame = @intFromPtr(pic);
    if (front == i) platform.graphics.draw(pic[0..pixels(t)]);
}

fn gfxPalette(first: u32, count: u32, rgb: [*]const u8) callconv(abi.cc) void {
    const i = tabOf(prog()) orelse return;
    if (first > 255) return;
    const n = @as(usize, @min(count, 256 - first)) * 3;
    @memcpy(tabs[i].palette[first * 3 ..][0..n], rgb[0..n]);
    if (front == i) platform.graphics.palette(@intCast(first), rgb[0..n]);
}

fn gfxEnd() callconv(abi.cc) void {
    closeTab(prog());
}

fn gfxVisible() callconv(abi.cc) bool {
    return inFront(prog());
}

fn gfxSetTitle(title: [*]const u8, len: usize) callconv(abi.cc) void {
    const i = tabOf(prog()) orelse return;
    const t = &tabs[i];
    t.title_len = @min(len, t.title.len);
    @memcpy(t.title[0..t.title_len], title[0..t.title_len]);
}

fn textInput(buf: [*]u8, len: usize) callconv(abi.cc) usize {
    checkCtrlC();
    if (!inFront(prog())) return 0;
    return con.takeText(buf[0..len]);
}

// KEY PRESSES AND RELEASES
//
// Recorded from the first key_event call
// on, until the program that made it ends

var key_events_owner: ?*Program = null;

// The console's scrollback stays off while a program has the
// screen (graphics, key events); the wheel
// is a program's while it reads the mouse
pub fn screenTaken() bool {
    return front != null or key_events_owner != null;
}

pub fn mouseTaken() bool {
    return mouse_owner != null;
}

fn keyEvent(event: *abi.KeyEvent) callconv(abi.cc) bool {
    checkCtrlC();
    // A tab not in front gets none (they stay for the one that is)
    if (!inFront(prog())) {
        prog().last_error = .none;
        return false;
    }
    if (key_events_owner == null) {
        scrollback.leave();
        if (!con.keyEvents(true)) {
            prog().last_error = .not_supported;
            return false;
        }
        key_events_owner = prog();
    }
    prog().last_error = .none;
    const e = con.keyEvent() orelse return false;
    event.* = .{ .code = e.code, .pressed = e.pressed, .repeat = e.repeat, .mods = e.mods };
    return true;
}

// MOUSE

// The program that asked last: another one starts from nothing
var mouse_owner: ?*Program = null;

fn mouse(state: *abi.Mouse) callconv(abi.cc) bool {
    checkCtrlC();
    // A tab not in front: no movement, no buttons
    if (!inFront(prog())) {
        prog().last_error = .none;
        state.* = .{ .dx = 0, .dy = 0, .wheel = 0, .buttons = 0 };
        return true;
    }
    const first = if (mouse_owner) |owner| owner != prog() else true;
    if (first) {
        _ = con.pollMouse() orelse {
            prog().last_error = .not_supported;
            return false;
        };
        mouse_owner = prog();
    }
    const m = con.pollMouse() orelse {
        prog().last_error = .not_supported;
        return false;
    };
    prog().last_error = .none;
    state.* = .{ .dx = scaleMouse(m.dx, &mouse_rest_x), .dy = scaleMouse(m.dy, &mouse_rest_y), .wheel = m.wheel, .buttons = m.buttons };
    return true;
}

// MOUSESPEED= (SYSTEM.CFG or SET): the movement in percent,
// 10-1000 (100 if unset or not a number). What doesn't make a
// whole count is kept for the next
// call, so slow movement isn't lost.
var mouse_rest_x: i32 = 0;
var mouse_rest_y: i32 = 0;

fn mouseSpeed() i32 {
    const text = env.get("MOUSESPEED") orelse return 100;
    const v = std.fmt.parseInt(i32, std.mem.trim(u8, text, " %"), 10) catch return 100;
    return std.math.clamp(v, 10, 1000);
}

fn scaleMouse(d: i32, rest: *i32) i32 {
    const speed = mouseSpeed();
    if (speed == 100) return d;
    const total = @as(i64, d) * speed + rest.*;
    const out = @divTrunc(total, 100);
    rest.* = @intCast(total - out * 100);
    return std.math.lossyCast(i32, out);
}

// HEAP
// A header links each program's blocks so they are freed
// when it exits. The platform gives 8-byte alignment;
// the header puts the data at 16 bytes. Blocks come from
// the real-time heap first (RTHEAP=: constant time),
// else the platform. No kernel lock (lock_free): the program's
// list has its own, interrupts off for a few pointer moves.

const Block = extern struct {
    prev: ?*Block,
    next: ?*Block,
    raw: [*]align(8) u8, // what the platform returned
    pad: usize, // makes the header 32 bytes (64-bit) or 16 bytes (32-bit)

    fn data(self: *Block) [*]align(16) u8 {
        return @ptrFromInt(@intFromPtr(self) + @sizeOf(Block));
    }

    comptime {
        std.debug.assert(@sizeOf(Block) % 16 == 0);
    }
};

fn alloc(n: usize) callconv(abi.cc) ?[*]align(16) u8 {
    return result(?[*]align(16) u8, allocBlock(n), null);
}

var blocks_lock = std.atomic.Value(bool).init(false);

fn takeBlocks() usize {
    const was = if (platform.has_switching) platform.switching.disable() else 0;
    while (blocks_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    return was;
}

fn giveBlocks(was: usize) void {
    blocks_lock.store(false, .release);
    if (platform.has_switching) platform.switching.restore(was);
}

fn allocBlock(n: usize) Error![*]align(16) u8 {
    if (n > max_alloc) return error.OutOfMemory;
    const total = n + @sizeOf(Block) + 8;
    const raw: [*]align(8) u8 = if (rtheap.alloc(total)) |r| r else (platform.memory.alloc(total) orelse return error.OutOfMemory);
    const b: *Block = @ptrFromInt(std.mem.alignForward(usize, @intFromPtr(raw), 16));
    const p = prog();
    const was = takeBlocks();
    b.* = .{ .prev = null, .next = p.blocks, .raw = raw, .pad = 0 };
    if (p.blocks) |first| first.prev = b;
    p.blocks = b;
    giveBlocks(was);
    return b.data();
}

fn free(ptr: ?[*]align(16) u8) callconv(abi.cc) void {
    const p = ptr orelse return;
    const b: *Block = @ptrFromInt(@intFromPtr(p) - @sizeOf(Block));
    const was = takeBlocks();
    if (b.prev) |prev| prev.next = b.next else prog().blocks = b.next;
    if (b.next) |next| next.prev = b.prev;
    giveBlocks(was);
    if (!rtheap.free(@ptrCast(b.raw))) platform.memory.free(b.raw);
}

// FILES AND DIRECTORIES

// Open files, directories and pipes of the program.
// Files, pipes and channels are shared
// objects (dup, tasks' streams): counted.
const Open = union(enum) {
    file: *stdio.File,
    // place: the folder's first names (perm.rule_depth), for FAT's
    // made-up owners of its entries
    dir: struct { handle: platform.storage.DirHandle, drive: u8, place: [place_max]u8 = undefined, place_len: u8 = 0, deep: bool = false },
    pipe: *stdio.Pipe,
    reader: *stdio.Channel, // a POSIX pipe's ends
    writer: *stdio.Channel,
    null_dev, // /dev/null
    tty: *TtyLine, // /dev/tty: the keyboard and the screen
    socket: *net.Socket,
    term: *Term, // a remote console's other side
    queue: *queues.Queue,
    counter: *queues.Counter,
};

// A handle goes: its object loses a user (the last closes or frees it)
fn releaseOpen(o: Open) Error!void {
    switch (o) {
        .file => |f| return f.release(),
        .dir => |d| platform.storage.closeDir(d.handle),
        .pipe => |pipe| if (pipe.release()) return error.OutOfMemory,
        .reader => |c| c.closeReader(),
        .writer => |c| c.closeWriter(),
        .null_dev => {},
        .tty => |t| {
            t.refs -= 1;
            if (t.refs == 0) platform.memory.free(@ptrCast(@alignCast(t)));
        },
        .socket => |sock| net.release(sock),
        .term => |t| t.releaseHolder(),
        .queue => |q| queues.releaseQueue(q),
        .counter => |c| queues.releaseCounter(c),
    }
}
fn freeSlot() Error!usize {
    for (prog().handles, 0..) |h, i| {
        if (h == null) return i;
    }
    return error.TooManyOpen;
}

// The handle's entry, in place (redirect
// points the standard streams at it)
fn slotOf(handle: i32) Error!*Open {
    const handles = &prog().handles;
    if (handle < 0 or handle >= handles.len) return error.InvalidHandle;
    if (handles[@intCast(handle)]) |*o| return o;
    return error.InvalidHandle;
}

fn byHandle(handle: i32) Error!Open {
    return (try slotOf(handle)).*;
}

fn fileByHandle(handle: i32) Error!platform.storage.FileHandle {
    return switch (try byHandle(handle)) {
        .file => |f| f.handle,
        else => error.InvalidHandle,
    };
}

// A floppy is checked on each call, quietly: a missing
// disk fails the call
fn checkDrive(d: *const fs.Drive) void {
    fs.newRequest();
    fs.checkDrive(d, false);
}

fn parsePath(path: [*]const u8, len: usize) Error!struct { drive: *fs.Drive, path: []const u8 } {
    fs.pollDevices();
    // /dev/null and the like are devices (open, stat): never a file on disk
    if (posixDevice(path[0..len]) != null) return error.AccessDenied;
    var p = fs.dropRootSlash(mapTmp(path[0..len]));
    var d = tasks.world().drive orelse return error.PathNotFound;
    if (p.len >= 2 and p[1] == ':') {
        d = fs.driveByLetter(p[0]) orelse return error.PathNotFound; // no such drive
        p = p[2..];
    }
    checkDrive(d);
    return .{ .drive = d, .path = p };
}

fn open(path: [*]const u8, len: usize, mode: abi.OpenMode) callconv(abi.cc) i32 {
    return result(i32, openFile(path, len, mode), -1);
}

// POSIX'S OWN PATHS: /DEV AND /TMP
// Exactly these spellings (a forward slash first, no drive,
// lower case) are POSIX's: the devices below, and /tmp as the
// TEMP folder. Any DOS spelling (C:\DEV\NULL, \dev\null,
// /C:/dev/null) reaches what is on the disk.

const PosixDevice = enum { null, tty, stdin, stdout, stderr };

fn posixDevice(path: []const u8) ?PosixDevice {
    const names = [_]struct { []const u8, PosixDevice }{
        .{ "/dev/null", .null },     .{ "/dev/tty", .tty },
        .{ "/dev/stdin", .stdin },   .{ "/dev/stdout", .stdout },
        .{ "/dev/stderr", .stderr },
    };
    for (names) |n| {
        if (std.mem.eql(u8, path, n[0])) return n[1];
    }
    return null;
}

// "/tmp" and "/tmp/x": in the TEMP folder (C:\TEMP if
// TEMP isn't set). A few buffers in turn: a call may map
// two paths (copy, move).
var tmp_bufs: [4][fs.max_path + 2]u8 = undefined;
var tmp_next: usize = 0;

fn mapTmp(path: []const u8) []const u8 {
    if (!(std.mem.eql(u8, path, "/tmp") or std.mem.startsWith(u8, path, "/tmp/"))) return path;
    const temp = env.get("TEMP") orelse "C:\\TEMP";
    const rest = path["/tmp".len..];
    const buf = &tmp_bufs[tmp_next];
    tmp_next = (tmp_next + 1) % tmp_bufs.len;
    if (temp.len + rest.len > buf.len) return path;
    @memcpy(buf[0..temp.len], temp);
    @memcpy(buf[temp.len..][0..rest.len], rest);
    return buf[0 .. temp.len + rest.len];
}

// A line typed at /dev/tty, given out in parts as the reader asks
const TtyLine = struct {
    refs: u32 = 1,
    buf: [256]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,
};

fn newTty() Error!*TtyLine {
    const mem = platform.memory.alloc(@sizeOf(TtyLine)) orelse return error.OutOfMemory;
    const t: *TtyLine = @ptrCast(@alignCast(mem));
    t.* = .{};
    return t;
}

// open of a device: NUL, the terminal, or what a standard stream is now
fn openDevice(dev: PosixDevice) Error!i32 {
    const slot = try freeSlot();
    const o: Open = switch (dev) {
        .null => .null_dev,
        .tty => .{ .tty = try newTty() },
        .stdin => switch (tasks.world().input) {
            .none => .{ .tty = try newTty() },
            .nul => .null_dev,
            .file => |f| blk: {
                f.refs += 1;
                break :blk .{ .file = f };
            },
            .pipe => |pp| blk: {
                pp.refs += 1;
                break :blk .{ .pipe = pp };
            },
            .channel => |c| blk: {
                c.readers += 1;
                break :blk .{ .reader = c };
            },
        },
        .stdout, .stderr => switch (if (dev == .stdout) tasks.world().output else tasks.world().errout) {
            .screen => .{ .tty = try newTty() },
            .nul => .null_dev,
            .file => |f| blk: {
                f.refs += 1;
                break :blk .{ .file = f };
            },
            .pipe => |pp| blk: {
                pp.refs += 1;
                break :blk .{ .pipe = pp };
            },
            .channel => |c| blk: {
                c.writers += 1;
                break :blk .{ .writer = c };
            },
        },
    };
    prog().handles[slot] = o;
    return @intCast(slot);
}

// A line from the keyboard (shown as typed, Backspace works);
// Ctrl+D or Ctrl+Z on an empty line: the end (0)
fn ttyRead(t: *TtyLine, out: []u8) usize {
    if (t.pos == t.len) {
        t.len = 0;
        t.pos = 0;
        const prev = stdio.toScreen();
        defer stdio.restore(prev);
        while (true) {
            const k = con.readKey();
            if (k.char == '\r' or k.char == '\n') {
                con.print("\n");
                t.buf[t.len] = '\n';
                t.len += 1;
                break;
            }
            if ((k.char == 4 or k.char == 0x1A) and t.len == 0) return 0;
            if (k.char == 8 or k.char == 0x7F) {
                if (t.len > 0) {
                    t.len -= 1;
                    while (t.len > 0 and t.buf[t.len] & 0xC0 == 0x80) t.len -= 1;
                    con.print("\x08 \x08");
                }
                continue;
            }
            if (k.char < 0x20) continue;
            var enc: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(k.char), &enc) catch continue;
            if (t.len + n + 1 > t.buf.len) continue;
            @memcpy(t.buf[t.len..][0..n], enc[0..n]);
            t.len += n;
            con.print(enc[0..n]);
        }
    }
    const n = @min(out.len, t.len - t.pos);
    @memcpy(out[0..n], t.buf[t.pos..][0..n]);
    t.pos += n;
    return n;
}

fn ttyWrite(data: []const u8) void {
    const prev = stdio.toScreen();
    defer stdio.restore(prev);
    con.print(data);
}

// What stat and stat_ex say of a device: a character device, empty
const char_device_mode = 0o020000 | 0o666;

fn openFile(path: [*]const u8, len: usize, mode: abi.OpenMode) Error!i32 {
    if (posixDevice(path[0..len])) |dev| return openDevice(dev);
    const fs_mode: platform.OpenMode = switch (mode) {
        .read => .read,
        .write => .write,
        .update => .update,
        _ => return error.InvalidArgument,
    };
    const p = try parsePath(path, len);
    var full: fs.Path = .{};
    try fs.resolvePath(p.drive, p.path, &full);
    try perm.checkOpen(p.drive, &full, fs_mode);
    const f = try fs.openFile(p.drive, p.path, fs_mode);
    const file = stdio.File.create(f, p.drive.letter) orelse {
        fs.close(f);
        return error.OutOfMemory;
    };
    file.writable = fs_mode != .read;
    // Looked for after the disk's waits: the kernel lock
    // goes in them, and another thread may take a handle
    const slot = freeSlot() catch |err| {
        releaseOpen(.{ .file = file }) catch {};
        return err;
    };
    prog().handles[slot] = .{ .file = file };
    return @intCast(slot);
}

// The handle is gone even if closing failed; last_error says so
fn close(handle: i32) callconv(abi.cc) void {
    _ = succeeded(closeHandle(handle));
}

fn closeHandle(handle: i32) Error!void {
    const slot = try slotOf(handle);
    unredirect(slot);
    const o = slot.*;
    prog().handles[@intCast(handle)] = null;
    queues.handleClosed(prog(), handle);
    return releaseOpen(o);
}

fn commit(handle: i32) callconv(abi.cc) bool {
    return succeeded(commitFile(handle));
}

fn commitFile(handle: i32) Error!void {
    return platform.storage.commit(try fileByHandle(handle));
}

// RAW DISKS

fn diskCount() callconv(abi.cc) u32 {
    return @intCast(platform.disk.count());
}

fn diskInfo(index: u32, info: *abi.DiskInfo) callconv(abi.cc) bool {
    const d = platform.disk.info(index) orelse {
        prog().last_error = .invalid_argument;
        return false;
    };
    info.* = .{ .sectors = d.sectors, .sector_size = d.sector_size, .removable = d.removable, .read_only = d.read_only };
    return true;
}

fn diskRead(index: u32, lba: u64, count: u32, buf: [*]u8) callconv(abi.cc) bool {
    return succeeded(diskSectors(index, lba, count, buf, false));
}

fn diskWrite(index: u32, lba: u64, count: u32, data: [*]const u8) callconv(abi.cc) bool {
    return succeeded(diskSectors(index, lba, count, @constCast(data), true));
}

// Reads or writes count sectors; buf holds exactly that many bytes
fn diskSectors(index: u32, lba: u64, count: u32, buf: [*]u8, is_write: bool) Error!void {
    const d = platform.disk.info(index) orelse return error.InvalidArgument;
    if (count == 0) return error.InvalidArgument;
    try perm.mustBeRoot(); // raw sectors pass by every file's permissions
    const bytes = @as(usize, count) * d.sector_size;
    if (is_write) return platform.disk.write(index, lba, buf[0..bytes]);
    return platform.disk.read(index, lba, buf[0..bytes]);
}

fn read(handle: i32, buf: [*]u8, len: usize) callconv(abi.cc) i64 {
    const o = byHandle(handle) catch |err| return result(i64, err, -1);
    if (o == .reader) {
        const n = o.reader.read(buf[0..len]) catch return failInt(.interrupted);
        prog().last_error = .none;
        return @intCast(n);
    }
    if (o == .socket) return socketRecv(o.socket, buf[0..len], 0, null, null);
    if (o == .counter) return result(i64, counterResult(o.counter.read(buf[0..len])), -1);
    if (o == .term) {
        const n = o.term.output.read(buf[0..len]) catch return failInt(.interrupted);
        prog().last_error = .none;
        return @intCast(n);
    }
    return result(i64, readFile(handle, buf[0..len]), -1);
}

fn readFile(handle: i32, buf: []u8) Error!i64 {
    return switch (try byHandle(handle)) {
        .file => |f| @intCast(try platform.storage.read(f.handle, buf)),
        .pipe => |pipe| @intCast(pipe.read(buf)),
        .null_dev => 0,
        .tty => |t| @intCast(ttyRead(t, buf)),
        else => error.InvalidHandle,
    };
}

fn write(handle: i32, buf: [*]const u8, len: usize) callconv(abi.cc) i64 {
    const o = byHandle(handle) catch |err| return result(i64, err, -1);
    if (o == .writer) return writeChannel(o.writer, buf[0..len]);
    if (o == .socket) return socketSend(o.socket, buf[0..len], 0, null, null);
    if (o == .counter) return result(i64, counterResult(o.counter.write(buf[0..len])), -1);
    if (o == .term) {
        prog().last_error = .none;
        return @intCast(o.term.input(buf[0..len]));
    }
    return result(i64, writeFile(handle, buf[0..len]), -1);
}

fn writeChannel(c: *stdio.Channel, data: []const u8) i64 {
    const n = c.write(data) catch |err| {
        if (err == error.BrokenPipe) tasks.kill(tasks.currentId(), abi.Signal.pipe) catch {};
        return failInt(switch (err) {
            error.BrokenPipe => .broken_pipe,
            error.Interrupted => .interrupted,
            error.OutOfMemory => .out_of_memory,
        });
    };
    prog().last_error = .none;
    return @intCast(n);
}

fn writeFile(handle: i32, data: []const u8) Error!i64 {
    return switch (try byHandle(handle)) {
        .file => |f| @intCast(try platform.storage.write(f.handle, data)),
        .pipe => |pipe| {
            pipe.write(data);
            if (pipe.buf.full) return error.OutOfMemory;
            return @intCast(data.len);
        },
        .null_dev => @intCast(data.len),
        .tty => blk: {
            ttyWrite(data);
            break :blk @intCast(data.len);
        },
        else => error.InvalidHandle,
    };
}

fn seek(handle: i32, pos: u64) callconv(abi.cc) bool {
    return succeeded(seekFile(handle, pos));
}

fn seekFile(handle: i32, pos: u64) Error!void {
    switch (try byHandle(handle)) {
        .null_dev, .tty => return, // devices have no position: as on Unix, fine
        else => {},
    }
    return platform.storage.seek(try fileByHandle(handle), pos);
}

fn size(handle: i32) callconv(abi.cc) i64 {
    return result(i64, fileSize(handle), -1);
}

fn fileSize(handle: i32) Error!i64 {
    return switch (try byHandle(handle)) {
        .file => |f| @intCast(try platform.storage.size(f.handle)),
        .pipe => |pipe| @intCast(pipe.buf.len),
        .reader, .writer => |c| @intCast(c.unread),
        .null_dev, .tty => 0,
        .dir, .socket, .term, .queue, .counter => error.InvalidHandle,
    };
}

fn setSize(handle: i32, new_size: u64) callconv(abi.cc) bool {
    return succeeded(setFileSize(handle, new_size));
}

fn setFileSize(handle: i32, new_size: u64) Error!void {
    return platform.storage.setSize(try fileByHandle(handle), new_size);
}

fn delete(path: [*]const u8, len: usize) callconv(abi.cc) bool {
    return succeeded(deleteFile(path, len));
}

fn deleteFile(path: [*]const u8, len: usize) Error!void {
    const r = try resolve(path, len);
    try perm.checkEntry(r.drive, &r.path);
    return fs.deleteFile(r.drive, r.path.slice());
}

fn openDir(path: [*]const u8, len: usize) callconv(abi.cc) i32 {
    return result(i32, openDirectory(path, len), -1);
}

fn openDirectory(path: [*]const u8, len: usize) Error!i32 {
    const p = try parsePath(path, len);
    var dir: fs.Path = .{};
    try fs.resolveDir(p.drive, p.path, &dir);
    try perm.check(p.drive, &dir, perm.read | perm.exec);
    var it = try fs.openDir(p.drive, &dir);
    // After the disk's waits, as in openFile
    const slot = freeSlot() catch |err| {
        it.close();
        return err;
    };
    prog().handles[slot] = .{ .dir = .{ .handle = it.handle, .drive = p.drive.letter } };
    const h = &prog().handles[slot].?.dir;
    // The first names of the folder, as FAT's owners by place need them
    var names = std.mem.tokenizeScalar(u8, dir.slice(), '\\');
    var n: usize = 0;
    var depth: usize = 0;
    while (names.next()) |name| : (depth += 1) {
        if (depth == perm.rule_depth) {
            h.deep = true;
            break;
        }
        if (n + 1 + name.len > place_max) break; // longer: treated as its own folder
        h.place[n] = '\\';
        @memcpy(h.place[n + 1 ..][0..name.len], name);
        n += 1 + name.len;
    }
    h.place_len = @intCast(n);
    return @intCast(slot);
}

const place_max = 96;

// false at the end of the listing (last_error .none) or on an error
fn readDir(handle: i32, entry: *abi.DirEntry) callconv(abi.cc) bool {
    return result(bool, readDirectory(handle, entry), false);
}

fn readDirectory(handle: i32, entry: *abi.DirEntry) Error!bool {
    const d = switch (try byHandle(handle)) {
        .dir => |d| d,
        else => return error.InvalidHandle,
    };
    var info: platform.EntryInfo = .{};
    if (!try platform.storage.readDir(d.handle, &info)) return false;
    toApiEntry(&info, entry);
    return true;
}

// Names are UTF-8; a name longer than out allows is cut at
// a character boundary. The bytes copied.
fn copyName(name: []const u8, out: []u8) usize {
    var n = @min(name.len, out.len);
    while (n < name.len and n > 0 and name[n] & 0xC0 == 0x80) n -= 1;
    @memcpy(out[0..n], name[0..n]);
    return n;
}

fn toApiEntry(info: *const platform.EntryInfo, entry: *abi.DirEntry) void {
    entry.name_len = @intCast(copyName(info.name(), &entry.name_buf));
    entry.is_dir = info.is_dir;
    entry.attrs = info.attrs & abi.Attr.all;
    entry.size = info.size;
    entry.modified = toApiTime(info.modified);
    entry.created = toApiTime(info.created);
    entry.accessed = toApiTime(info.accessed);
}

// A program's path resolved to a drive and an absolute path on it
const Resolved = struct { drive: *fs.Drive, path: fs.Path = .{} };

fn resolve(path: [*]const u8, len: usize) Error!Resolved {
    const p = try parsePath(path, len);
    var r: Resolved = .{ .drive = p.drive };
    try fs.resolvePath(p.drive, p.path, &r.path);
    return r;
}

fn fullPath(path: [*]const u8, len: usize, buf: [*]u8, buf_len: usize) callconv(abi.cc) usize {
    return result(usize, resolveFull(path, len, buf[0..buf_len]), 0);
}

fn resolveFull(path: [*]const u8, len: usize, out: []u8) Error!usize {
    const r = try resolve(path, len);
    const p = r.path.slice();
    if (p.len + 2 > out.len) return error.InvalidArgument; // buffer too small
    out[0] = r.drive.letter;
    out[1] = ':';
    @memcpy(out[2..][0..p.len], p);
    return p.len + 2;
}

fn makeDir(path: [*]const u8, len: usize) callconv(abi.cc) bool {
    return succeeded(makeDirectory(path, len));
}

fn makeDirectory(path: [*]const u8, len: usize) Error!void {
    const r = try resolve(path, len);
    try perm.checkEntry(r.drive, &r.path);
    perm.setCreator();
    return fs.makeDir(r.drive, &r.path);
}

// Within one drive: a rename (which also handles case-only changes)
fn renameOnDrive(src: *const Resolved, dst: *const Resolved, to: []const u8) Error!void {
    if (src.path.len == 1) return error.AccessDenied; // not the root
    if (try fs.kindOf(src.drive, &src.path) == null) return error.NotFound;
    // Only the capitalization changes
    // ("readme.txt" -> "Readme.txt"): FAT sees one
    // name, so this needs two steps
    if (std.mem.eql(u8, src.path.slice(), dst.path.slice())) {
        const typed = fs.lastComponent(to);
        const old_name = fs.baseName(&src.path);
        if (std.mem.eql(u8, typed, old_name) or !std.ascii.eqlIgnoreCase(typed, old_name)) return error.AlreadyExists;
        return fs.renameCase(src.drive, &src.path, typed);
    }
    try fs.mustNotExist(dst.drive, &dst.path);
    if (fs.isInside(dst.path.slice(), src.path.slice())) return error.InvalidArgument; // a folder into itself
    try perm.checkEntry(src.drive, &src.path);
    try perm.checkEntry(dst.drive, &dst.path);
    return fs.rename(src.drive, &src.path, &dst.path);
}

fn deleteTree(path: [*]const u8, len: usize) callconv(abi.cc) bool {
    return succeeded(deleteWholeTree(path, len));
}

fn deleteWholeTree(path: [*]const u8, len: usize) Error!void {
    const r = try resolve(path, len);
    if (r.path.len == 1) return error.AccessDenied; // not the root
    if (try fs.kindOf(r.drive, &r.path) == null) return error.NotFound;
    try checkTreeRemoval(r.drive, &r.path);
    // Even a partial delete may remove the current directory
    defer fs.leaveRemoved(r.drive, &r.path);
    return fs.deleteTree(r.drive, &r.path);
}

// Deleting a whole folder tree: deleting it from its folder,
// and, not being root, owning it (what
// is inside isn't checked one by one)
fn checkTreeRemoval(d: *const fs.Drive, path: *const fs.Path) Error!void {
    try perm.checkEntry(d, path);
    try perm.checkOwner(d, path);
}

fn copy(from: [*]const u8, from_len: usize, to: [*]const u8, to_len: usize) callconv(abi.cc) bool {
    return succeeded(copyTree(from, from_len, to, to_len));
}

fn copyTree(from: [*]const u8, from_len: usize, to: [*]const u8, to_len: usize) Error!void {
    const src = try resolve(from, from_len);
    const dst = try resolve(to, to_len);
    if (src.path.len == 1) return error.AccessDenied; // not the root
    if (src.drive == dst.drive and fs.isInside(dst.path.slice(), src.path.slice())) return error.InvalidArgument; // into itself
    try perm.check(src.drive, &src.path, perm.read);
    try perm.checkEntry(dst.drive, &dst.path);
    perm.setCreator();
    return fs.copyTree(src.drive, &src.path, dst.drive, &dst.path);
}

fn move(from: [*]const u8, from_len: usize, to: [*]const u8, to_len: usize) callconv(abi.cc) bool {
    return succeeded(moveTree(from, from_len, to, to_len));
}

fn moveTree(from: [*]const u8, from_len: usize, to: [*]const u8, to_len: usize) Error!void {
    const src = try resolve(from, from_len);
    const dst = try resolve(to, to_len);
    // Within one drive it is a rename
    // (which also handles case-only changes)
    if (src.drive == dst.drive) {
        try renameOnDrive(&src, &dst, to[0..to_len]);
        if (!std.mem.eql(u8, src.path.slice(), dst.path.slice())) fs.leaveRemoved(src.drive, &src.path);
        return;
    }
    // Across drives: copy, then delete the original
    if (src.path.len == 1) return error.AccessDenied;
    try perm.check(src.drive, &src.path, perm.read);
    try checkTreeRemoval(src.drive, &src.path);
    try perm.checkEntry(dst.drive, &dst.path);
    perm.setCreator();
    try fs.copyTree(src.drive, &src.path, dst.drive, &dst.path);
    defer fs.leaveRemoved(src.drive, &src.path);
    return fs.deleteTree(src.drive, &src.path);
}

fn stat(path: [*]const u8, len: usize, entry: *abi.DirEntry) callconv(abi.cc) bool {
    return succeeded(statPath(path, len, entry));
}

fn loadLibrary(name: [*]const u8, len: usize) callconv(abi.cc) ?*const anyopaque {
    const table = libraries.load(prog(), name[0..len]) catch |err| {
        prog().last_error = switch (err) {
            error.BadName, error.NotProgram, error.Invalid => .invalid_argument,
            error.TooMany => .too_many_open,
            error.NoMemory => .out_of_memory,
            else => |e| fs.errorCode(e),
        };
        return null;
    };
    prog().last_error = .none;
    return table;
}

fn getIds(out: *abi.Ids) callconv(abi.cc) void {
    perm.getIds(&prog().ids, out);
}

fn setIds(ids: *const abi.Ids) callconv(abi.cc) bool {
    return succeeded(perm.setIds(&prog().ids, ids));
}

fn statPath(path: [*]const u8, len: usize, entry: *abi.DirEntry) Error!void {
    if (posixDevice(path[0..len])) |dev| {
        entry.* = std.mem.zeroes(abi.DirEntry);
        const name = @tagName(dev);
        @memcpy(entry.name_buf[0..name.len], name);
        entry.name_len = @intCast(name.len);
        return;
    }
    const r = try resolve(path, len);
    try perm.check(r.drive, &r.path, 0); // the folders above: searchable
    var info: platform.EntryInfo = .{};
    try fs.entryInfo(r.drive, &r.path, &info);
    toApiEntry(&info, entry);
}

// STATEX

fn statEx(path: [*]const u8, len: usize, info: *abi.StatEx) callconv(abi.cc) bool {
    return succeeded(statExPath(path, len, info));
}

fn statExPath(path: [*]const u8, len: usize, info: *abi.StatEx) Error!void {
    try checkStatEx(info);
    if (posixDevice(path[0..len]) != null) {
        var x: abi.StatEx = .{ .size = 0, .mode = char_device_mode, .links = 1 };
        copyStatEx(&x, info);
        return;
    }
    const r = try resolve(path, len);
    try perm.check(r.drive, &r.path, 0);
    var e: platform.EntryInfo = .{};
    try fs.entryInfo(r.drive, &r.path, &e);
    putStatEx(&e, r.drive.letter, r.path.slice(), info);
}

fn fstatEx(handle: i32, info: *abi.StatEx) callconv(abi.cc) bool {
    return succeeded(fstatHandle(handle, info));
}

fn fstatHandle(handle: i32, info: *abi.StatEx) Error!void {
    try checkStatEx(info);
    switch (try byHandle(handle)) {
        .file => |f| {
            var e: platform.EntryInfo = .{};
            try platform.storage.fstat(f.handle, &e);
            putStatEx(&e, f.drive, null, info);
        },
        .pipe => |pipe| {
            var x: abi.StatEx = .{ .size = 0, .mode = 0o010000 | 0o666, .links = 1, .file_size = pipe.buf.len };
            copyStatEx(&x, info);
        },
        .reader, .writer => |c| {
            var x: abi.StatEx = .{ .size = 0, .mode = 0o010000 | 0o666, .links = 1, .file_size = c.unread };
            copyStatEx(&x, info);
        },
        .null_dev, .tty, .term => {
            var x: abi.StatEx = .{ .size = 0, .mode = char_device_mode, .links = 1 };
            copyStatEx(&x, info);
        },
        .socket => {
            var x: abi.StatEx = .{ .size = 0, .mode = 0o140000 | 0o666, .links = 1 };
            copyStatEx(&x, info);
        },
        .queue, .counter => {
            var x: abi.StatEx = .{ .size = 0, .mode = 0o600, .links = 1 }; // as Linux's anonymous inodes
            copyStatEx(&x, info);
        },
        .dir => return error.InvalidHandle,
    }
}

fn readDirEx(handle: i32, info: *abi.StatEx, name: [*]u8, name_len: usize) callconv(abi.cc) usize {
    return result(usize, readDirectoryEx(handle, info, name[0..name_len]), 0);
}

fn readDirectoryEx(handle: i32, info: *abi.StatEx, name: []u8) Error!usize {
    try checkStatEx(info);
    if (name.len == 0) return error.InvalidArgument;
    const d = switch (try byHandle(handle)) {
        .dir => |d| d,
        else => return error.InvalidHandle,
    };
    var e: platform.EntryInfo = .{};
    if (!try platform.storage.readDir(d.handle, &e)) return 0;
    // The entry's place for FAT's owners: deeper
    // than the rules look, the folder's own
    var buf: [place_max + 1 + 768]u8 = undefined;
    const base = d.place[0..d.place_len];
    const place = if (d.deep) base else std.fmt.bufPrint(&buf, "{s}\\{s}", .{ base, e.name() }) catch base;
    putStatEx(&e, d.drive, place, info);
    return copyName(e.name(), name);
}

// At least the fields every StatEx has, and no options yet
fn checkStatEx(info: *const abi.StatEx) Error!void {
    if (info.size < abi.stat_ex_min or info.flags != 0) return error.InvalidArgument;
}

// place: the entry's path, for FAT's made-up owner
// and mode (null: unknown, a plain guess from the
// read-only attribute)
fn putStatEx(e: *const platform.EntryInfo, drive: u8, place: ?[]const u8, out: *abi.StatEx) void {
    var x: abi.StatEx = .{
        .size = 0,
        .attrs = e.attrs & abi.Attr.all,
        .drive = drive,
        .is_dir = e.is_dir,
        .file_size = e.size,
        .modified = toApiTime(e.modified),
        .accessed = toApiTime(e.accessed),
        .created = toApiTime(e.created),
    };
    if (e.unix) |u| {
        const V = abi.StatValid;
        x.valid = V.mode | V.owner | V.links | V.ino | V.blocks;
        x.mode = u.mode;
        x.uid = u.uid;
        x.gid = u.gid;
        x.links = u.links;
        x.ino = u.ino;
        x.blocks = u.blocks;
        x.changed = toApiTime(u.changed);
    } else {
        x.mode = madeUpMode(e);
        x.links = 1;
        x.blocks = (e.size + 511) / 512;
        if (place) |path| if (fs.driveByLetter(drive)) |d| {
            const o = perm.madeUp(d, path, e.attrs);
            x.mode = (x.mode & 0o170000) | o.mode;
            x.uid = o.uid;
            x.gid = o.gid;
        };
    }
    copyStatEx(&x, out);
}

// As many bytes as the program's StatEx has
fn copyStatEx(x: *abi.StatEx, out: *abi.StatEx) void {
    const n: u32 = @min(out.size, @sizeOf(abi.StatEx));
    x.size = n;
    const dst: [*]u8 = @ptrCast(out);
    @memcpy(dst[0..n], std.mem.asBytes(x)[0..n]);
}

// PROGRAMS

fn exec(path: [*]const u8, len: usize, args: [*]const u8, args_len: usize) callconv(abi.cc) i32 {
    return result(i32, execProgram(path[0..len], args[0..args_len]), -1);
}

fn execProgram(path: []const u8, args: []const u8) Error!i32 {
    return switch (loader.runPath(path, args)) {
        .exited => |code| code,
        .not_found => error.NotFound,
        .not_program => error.NotSupported, // not a program, a batch file, or for another ZDOS
        .invalid => error.InvalidArgument, // damaged program file
        .no_memory, .too_deep => error.OutOfMemory,
        .failed => |err| err,
    };
}

fn getCwd(buf: [*]u8, len: usize) callconv(abi.cc) usize {
    return result(usize, currentDir(buf[0..len]), 0);
}

fn currentDir(buf: []u8) Error!usize {
    const d = tasks.world().drive orelse return error.PathNotFound;
    const cwd = fs.cwdOf(d).slice();
    if (cwd.len + 2 > buf.len) return error.InvalidArgument; // buffer too small
    buf[0] = d.letter;
    buf[1] = ':';
    @memcpy(buf[2..][0..cwd.len], cwd);
    return cwd.len + 2;
}

fn setCwd(path: [*]const u8, len: usize) callconv(abi.cc) bool {
    return succeeded(changeDir(path, len));
}

fn changeDir(path: [*]const u8, len: usize) Error!void {
    const p = try parsePath(path, len);
    if (p.path.len > 0) {
        var dir: fs.Path = .{};
        try fs.resolveDir(p.drive, p.path, &dir);
        try perm.check(p.drive, &dir, perm.exec);
        try fs.setCwd(p.drive, &dir);
    }
    tasks.world().drive = p.drive;
}

fn driveInfo(letter: u8, info: *abi.DriveInfo) callconv(abi.cc) bool {
    return succeeded(getDriveInfo(letter, info));
}

fn getDriveInfo(letter: u8, info: *abi.DriveInfo) Error!void {
    fs.pollDevices();
    const d = fs.driveByLetter(letter) orelse return error.PathNotFound; // never one without a letter
    fillDriveInfo(d, info);
}

// Every drive, also those without a letter
fn driveAt(index: u32, info: *abi.DriveInfo) callconv(abi.cc) bool {
    if (index == 0) fs.pollDevices(); // a listing starts at 0
    if (index >= fs.drives.len) return false;
    fillDriveInfo(&fs.drives[index], info);
    return true;
}

// Root only, as the other disk tools (FORMAT, FDISK, SYS go
// by raw sectors): 0 and access_denied otherwise
fn assignLetters() callconv(abi.cc) u32 {
    perm.mustBeRoot() catch return @intFromBool(fail(.access_denied));
    prog().last_error = .none;
    return @intCast(fs.assignLetters());
}

fn fillDriveInfo(d: *const fs.Drive, info: *abi.DriveInfo) void {
    checkDrive(d);
    // A removed disk's driver may still answer from what it read before
    const volume = if (d.is_missing) null else fs.volumeInfo(d);
    info.ready = volume != null and !d.is_unreadable;
    info.floppy = d.is_floppy;
    info.removable = d.is_removable;
    info.unreadable = d.is_unreadable;
    const v = volume orelse platform.VolumeInfo{};
    const label = v.label();
    const n = @min(label.len, info.label_buf.len);
    @memcpy(info.label_buf[0..n], label[0..n]);
    info.label_len = @intCast(n);
    info.size = v.size;
    info.free = v.free;
    info.block_size = if (d.is_unreadable) 0 else v.block_size;
    info.letter = d.letter;
    info.boot = d.is_boot;
    info.system = d.is_system;
    info.hidden = d.is_hidden;
    info.serial = v.serial orelse 0;
    info.has_serial = v.serial != null;
    info.file_system = if (std.mem.eql(u8, v.fs_name, "FAT12"))
        .fat12
    else if (std.mem.eql(u8, v.fs_name, "FAT16"))
        .fat16
    else if (std.mem.eql(u8, v.fs_name, "FAT32"))
        .fat32
    else if (std.mem.eql(u8, v.fs_name, "Minix V3"))
        .mfs3
    else if (std.mem.eql(u8, v.fs_name, "ext2"))
        .ext2
    else if (std.mem.eql(u8, v.fs_name, "ext3"))
        .ext3
    else if (std.mem.eql(u8, v.fs_name, "ext4"))
        .ext4
    else if (std.mem.eql(u8, v.fs_name, "ZFS"))
        .zfs
    else if (std.mem.eql(u8, v.fs_name, "NTFS"))
        .ntfs
    else if (std.mem.eql(u8, v.fs_name, "exFAT"))
        .exfat
    else
        .unknown;
}

// ATTRIBUTES AND LABELS

fn setAttributes(path: [*]const u8, len: usize, attrs: u8) callconv(abi.cc) bool {
    return succeeded(setAttributeBits(path, len, attrs));
}

fn setAttributeBits(path: [*]const u8, len: usize, attrs: u8) Error!void {
    const r = try resolve(path, len);
    if (r.path.len <= 1) return error.AccessDenied; // the root has no attributes
    if (try fs.kindOf(r.drive, &r.path) == null) return error.NotFound;
    try perm.checkOwner(r.drive, &r.path);
    return fs.setAttributes(r.drive, &r.path, attrs & abi.Attr.all);
}

// UNIX PERMISSIONS

fn permissions(path: [*]const u8, len: usize, out: *abi.Permissions) callconv(abi.cc) bool {
    return succeeded(getPermissions(path, len, out));
}

// Made up from the read-only attribute where the file system has none
fn getPermissions(path: [*]const u8, len: usize, out: *abi.Permissions) Error!void {
    const r = try resolve(path, len);
    if (fs.permissions(r.drive, &r.path)) |p| {
        out.* = .{ .mode = p.mode, .uid = p.uid, .gid = p.gid, .unix = true };
        return;
    } else |err| if (err != error.NotSupported) return err;
    var info: platform.EntryInfo = .{};
    try fs.entryInfo(r.drive, &r.path, &info);
    // FAT: what the checks make up (by place, read-only), so listings agree
    const o = perm.madeUp(r.drive, r.path.slice(), info.attrs);
    out.* = .{ .mode = (madeUpMode(&info) & 0o170000) | o.mode, .uid = o.uid, .gid = o.gid, .unix = false };
}

// Where the file system has no mode: from
// the kind and the read-only attribute
fn madeUpMode(info: *const platform.EntryInfo) u32 {
    const kind: u32 = if (info.is_dir) 0o040000 else 0o100000;
    const bits: u32 = if (info.is_dir) 0o755 else 0o644;
    const writable: u32 = if (info.attrs & platform.Attr.read_only != 0) 0 else 0o222;
    return kind | (bits & ~@as(u32, 0o222)) | (bits & writable);
}

fn setMode(path: [*]const u8, len: usize, mode: u32) callconv(abi.cc) bool {
    return succeeded(setModeBits(path, len, mode));
}

// Without Unix permissions: no write bit
// makes it read only, any makes it writable
fn setModeBits(path: [*]const u8, len: usize, mode: u32) Error!void {
    if (mode > 0o7777) return error.InvalidArgument;
    const r = try resolve(path, len);
    if (try fs.kindOf(r.drive, &r.path) == null) return error.NotFound;
    try perm.checkOwner(r.drive, &r.path);
    if (fs.setMode(r.drive, &r.path, @intCast(mode))) {
        return;
    } else |err| if (err != error.NotSupported) return err;
    if (r.path.len <= 1) return error.NotSupported; // the root has no attributes
    var info: platform.EntryInfo = .{};
    try fs.entryInfo(r.drive, &r.path, &info);
    const ro: u8 = platform.Attr.read_only;
    const attrs = if (mode & 0o222 == 0) info.attrs | ro else info.attrs & ~ro;
    if (attrs != info.attrs) try fs.setAttributes(r.drive, &r.path, attrs & platform.Attr.all);
}

fn setOwner(path: [*]const u8, len: usize, uid: u32, gid: u32) callconv(abi.cc) bool {
    return succeeded(setOwnerIds(path, len, uid, gid));
}

fn setOwnerIds(path: [*]const u8, len: usize, uid: u32, gid: u32) Error!void {
    const r = try resolve(path, len);
    if (try fs.kindOf(r.drive, &r.path) == null) return error.NotFound;
    try perm.mustBeRoot(); // giving files away: root only, as on Linux
    return fs.setOwner(r.drive, &r.path, if (uid == abi.keep_id) null else uid, if (gid == abi.keep_id) null else gid);
}

fn setLabel(letter: u8, label: [*]const u8, len: usize) callconv(abi.cc) bool {
    return succeeded(setDriveLabel(letter, label[0..len]));
}

fn setDriveLabel(letter: u8, label: []const u8) Error!void {
    const d = fs.driveByLetter(letter) orelse return error.PathNotFound;
    checkDrive(d);
    try perm.mustBeRoot();
    var buf: [64]u8 = undefined;
    const checked = fs.checkLabel(label, &buf) catch return error.InvalidName;
    return fs.setLabel(d, checked);
}

// SYSTEM AND PROGRAMS

fn systemInfo(info: *abi.SystemInfo) callconv(abi.cc) void {
    const m = platform.memory.stats();
    const mhz: u64 = if (arch.timestamp_is_cpu_clock) (platform.clock.timestampRate() + 500_000) / 1_000_000 else 0;
    info.os_version = ver.zdos;
    info.total_memory = m.total;
    info.free_memory = m.free;
    info.largest_free = m.largest_free;
    info.cpu_mhz = @intCast(@min(mhz, std.math.maxInt(u32)));
    info.pad = .{ 0, 0, 0 };
    const name = arch.cpuName(&info.cpu_name_buf);
    info.cpu_name_len = @intCast(@min(name.len, info.cpu_name_buf.len));
}

fn programPath(buf: [*]u8, len: usize) callconv(abi.cc) usize {
    return result(usize, ownPath(buf[0..len]), 0);
}

fn ownPath(buf: []u8) Error!usize {
    const p = prog();
    if (p.path_len == 0) return error.NotFound;
    if (p.path_len > buf.len) return error.InvalidArgument; // buffer too small
    @memcpy(buf[0..p.path_len], p.path_buf[0..p.path_len]);
    return p.path_len;
}

fn setFileTime(path: [*]const u8, len: usize, time: *const abi.Time) callconv(abi.cc) bool {
    return succeeded(setModified(path, len, time));
}

fn setModified(path: [*]const u8, len: usize, time: *const abi.Time) Error!void {
    const value = fromApiTime(time);
    // FAT dates run from 1980 to 2107
    if (!datetime.valid(value) or value.year < 1980 or value.year > 2107) return error.InvalidArgument;
    const r = try resolve(path, len);
    if (r.path.len <= 1) return error.AccessDenied; // the root has no date
    if (try fs.kindOf(r.drive, &r.path) == null) return error.NotFound;
    perm.checkOwner(r.drive, &r.path) catch try perm.check(r.drive, &r.path, perm.write);
    return fs.setModified(r.drive, &r.path, value);
}

fn fsetFileTime(handle: i32, time: *const abi.Time) callconv(abi.cc) bool {
    return succeeded(setOpenModified(handle, time));
}

// Root, a handle opened for writing, or the owner on a Unix
// file system (the path is unknown here,
// so FAT's made-up owners can't be asked)
fn setOpenModified(handle: i32, time: *const abi.Time) Error!void {
    const value = fromApiTime(time);
    if (!datetime.valid(value) or value.year < 1980 or value.year > 2107) return error.InvalidArgument;
    const f = switch (try byHandle(handle)) {
        .file => |f| f,
        else => return error.InvalidHandle,
    };
    if (!perm.isRoot() and !f.writable) {
        var e: platform.EntryInfo = .{};
        try platform.storage.fstat(f.handle, &e);
        const u = e.unix orelse return error.AccessDenied;
        if (u.uid != perm.current().uid) return error.AccessDenied;
    }
    return platform.storage.setModifiedOpen(f.handle, value);
}

fn setVar(name: [*]const u8, name_len: usize, value: [*]const u8, value_len: usize) callconv(abi.cc) bool {
    return succeeded(setVariable(name[0..name_len], value[0..value_len]));
}

// Global variables are everyone's (USER, PATH, COMSPEC ... that
// LOGIN, SU and SUDO run with): admins only; a batch file's own
// scope is free, and so are a task's own variables (spawn_env)
fn setVariable(name: []const u8, value: []const u8) Error!void {
    if (env.inGlobal()) try perm.mustBeAdmin();
    env.set(name, value) catch |err| return switch (err) {
        error.BadName => error.InvalidName,
        error.TooLong => error.InvalidArgument,
        error.OutOfSpace => error.OutOfMemory,
    };
}

// The command interpreter runs the line: "COMMAND -c line"; its
// exit code is the ERRORLEVEL afterwards
fn runCommand(line: [*]const u8, len: usize) callconv(abi.cc) i32 {
    return result(i32, runInterpreter(line[0..len]), -1);
}

fn runInterpreter(line: []const u8) Error!i32 {
    const prefix = "-c ";
    var args: [loader.max_args]u8 = undefined;
    if (prefix.len + line.len > args.len) return error.InvalidArgument;
    @memcpy(args[0..prefix.len], prefix);
    @memcpy(args[prefix.len..][0..line.len], line);
    return execProgram(startup.commandInterpreter(), args[0 .. prefix.len + line.len]);
}

// In a thread: the program's own task ends it
// (tasks.requestProgramExit)
fn exit(code: u8) callconv(abi.cc) noreturn {
    if (tasks.isThread()) {
        tasks.requestProgramExit(prog(), code);
        tasks.threadExit(0);
    }
    arch.exitTo(prog().exit_saved, code);
}

// Turning off and restarting: admins only. These calls don't
// return, so a program not allowed to make
// them ends (exit code 1), with a message.
fn notAdmin(what: []const u8) noreturn {
    con.printError(what);
    con.printError(": only admins may do that\n");
    exit(1);
}

fn shutdown() callconv(abi.cc) noreturn {
    if (!perm.isAdmin()) notAdmin("Turning off the computer");
    platform.storage.syncAll(); // what the drives' caches hold reaches the disks
    platform.power.shutdown();
}

fn restart() callconv(abi.cc) noreturn {
    if (!perm.isAdmin()) notAdmin("Restarting the computer");
    platform.storage.syncAll();
    platform.power.restart();
}

fn diskChanged(index: u32) callconv(abi.cc) bool {
    if (index >= platform.disk.count()) return false;
    platform.storage.diskChanged(index);
    fs.volumesChanged();
    return true;
}

fn driveSectors(letter: u8, out: *u64) callconv(abi.cc) bool {
    return succeeded(driveSectorsOf(letter, out));
}

fn driveSectorsOf(letter: u8, out: *u64) Error!void {
    const d = fs.driveByLetter(letter) orelse return error.PathNotFound;
    checkDrive(d);
    out.* = platform.storage.volumeSectors(d.vol) orelse return error.NotSupported;
}

fn driveRead(letter: u8, lba: u64, buf: [*]u8, len: usize) callconv(abi.cc) bool {
    return succeeded(driveIo(letter, lba, buf[0..len], false));
}

fn driveWrite(letter: u8, lba: u64, data: [*]const u8, len: usize) callconv(abi.cc) bool {
    return succeeded(driveIo(letter, lba, @constCast(data[0..len]), true));
}

// Root only: sectors pass by every file's permissions (as raw disks)
fn driveIo(letter: u8, lba: u64, buf: []u8, is_write: bool) Error!void {
    const d = fs.driveByLetter(letter) orelse return error.PathNotFound;
    checkDrive(d);
    try perm.mustBeRoot();
    if (is_write) return platform.storage.volumeWrite(d.vol, lba, buf);
    return platform.storage.volumeRead(d.vol, lba, buf);
}

fn driveEject(letter: u8) callconv(abi.cc) bool {
    const d = fs.driveByLetter(letter) orelse return fail(.path_not_found);
    return succeeded(fs.eject(d));
}

// Before a tool writes a volume or disk directly
// (CHKDSK -F, FORMAT ...): every file system's
// held-back writes go out (all of them: simplest, and a
// disk's volumes are all covered)
fn driveSync(letter: u8) callconv(abi.cc) bool {
    _ = fs.driveByLetter(letter) orelse {
        prog().last_error = .path_not_found;
        return false;
    };
    platform.storage.syncAll();
    prog().last_error = .none;
    return true;
}

fn diskSync(index: u32) callconv(abi.cc) bool {
    if (index >= platform.disk.count()) {
        prog().last_error = .invalid_argument;
        return false;
    }
    platform.storage.syncAll();
    prog().last_error = .none;
    return true;
}

fn driveChanged(letter: u8) callconv(abi.cc) bool {
    const d = fs.driveByLetter(letter) orelse {
        prog().last_error = .path_not_found;
        return false;
    };
    platform.storage.volumeChanged(d.vol);
    fs.volumesChanged();
    return true;
}

// KEYBOARD LAYOUTS (KEYB.ZIG)

fn keybCount() callconv(abi.cc) u32 {
    return @intCast(keyb.count());
}

fn keybName(index: u32, buf: [*]u8, len: usize) callconv(abi.cc) usize {
    const name = keyb.name(index) orelse {
        prog().last_error = .invalid_argument;
        return 0;
    };
    prog().last_error = .none;
    const n = @min(name.len, len);
    @memcpy(buf[0..n], name[0..n]);
    return name.len;
}

fn keybActive() callconv(abi.cc) u32 {
    return @intCast(keyb.active());
}

fn keybSetActive(index: u32) callconv(abi.cc) bool {
    return succeeded(keyb.setActive(index));
}

fn keybLoaded(buf: [*]u8, len: usize) callconv(abi.cc) usize {
    return result(usize, keyb.loadedText(buf[0..len]), 0);
}

fn keybSetLoaded(list: [*]const u8, len: usize) callconv(abi.cc) bool {
    return succeeded(keyb.setLoaded(list[0..len]));
}

fn driveLocation(letter: u8, loc: *abi.Location) callconv(abi.cc) bool {
    for (fs.drives) |d| {
        if (d.letter != letter) continue;
        const where = platform.storage.location(d.vol) orelse {
            prog().last_error = .not_supported;
            return false;
        };
        loc.* = .{ .disk = where.disk, .start = where.start, .sectors = where.sectors };
        return true;
    }
    prog().last_error = .path_not_found;
    return false;
}

fn addBootEntry(letter: u8, path: [*]const u8, len: usize) callconv(abi.cc) bool {
    return succeeded(addBootEntryFile(letter, path[0..len]));
}

fn bootFile(buf: [*]u8, len: usize) callconv(abi.cc) usize {
    const path = platform.boot.file() orelse {
        prog().last_error = .not_supported;
        return 0;
    };
    prog().last_error = .none;
    const n = @min(path.len, len);
    @memcpy(buf[0..n], path[0..n]);
    return path.len;
}

fn addBootEntryFile(letter: u8, path: []const u8) Error!void {
    for (fs.drives) |d| {
        if (d.letter == letter) {
            _ = platform.boot.add(d.vol, "ZDOS", path) catch |err| return err;
            return;
        }
    }
    return error.PathNotFound;
}

// VARIABLE SCOPES

fn pushVars() callconv(abi.cc) bool {
    return succeeded(if (env.push()) {} else error.OutOfMemory);
}

// Only a scope the program pushed itself
fn popVars() callconv(abi.cc) void {
    if (env.level() > prog().var_level) env.pop();
}

// "NAME=value", cut to len; the full length
fn varAt(index: u32, buf: [*]u8, len: usize) callconv(abi.cc) i64 {
    const v = env.at(index) orelse return -1;
    var n: usize = 0;
    for ([_][]const u8{ v.name, "=", v.value }) |part| {
        const k = @min(part.len, len - n);
        @memcpy(buf[n..][0..k], part[0..k]);
        n += k;
    }
    return @intCast(v.name.len + 1 + v.value.len);
}

// STANDARD INPUT AND REDIRECTION

// stream 0: input, 1: output; handle -1: what the program
// started with, -2: the keyboard / the screen
fn redirect(stream: u32, handle: i32) callconv(abi.cc) bool {
    return succeeded(setStream(stream, handle));
}

fn setStream(stream: u32, handle: i32) Error!void {
    const p = prog();
    switch (stream) {
        0 => tasks.world().input = switch (handle) {
            -1 => p.start_input,
            -2 => .none,
            -3 => .nul,
            else => try inputOf(handle),
        },
        1 => tasks.world().output = switch (handle) {
            -1 => p.start_output,
            -2 => .screen,
            -3 => .nul,
            -4 => tasks.world().output,
            -5 => tasks.world().errout,
            else => try outputOf(handle),
        },
        2 => tasks.world().errout = switch (handle) {
            -1 => p.start_errout,
            -2 => .screen,
            -3 => .nul,
            else => try outputOf(handle), // -4, -5 as well
        },
        else => return error.InvalidArgument,
    }
}

// A handle being closed, the last one of its object: if the
// standard input or output uses it, they
// go back to what the program started with
fn unredirect(slot: *Open) void {
    const p = prog();
    switch (slot.*) {
        .file => |f| if (f.refs == 1) {
            if (tasks.world().input == .file and tasks.world().input.file == f) tasks.world().input = p.start_input;
            if (tasks.world().output == .file and tasks.world().output.file == f) tasks.world().output = p.start_output;
            if (tasks.world().errout == .file and tasks.world().errout.file == f) tasks.world().errout = p.start_errout;
        },
        .pipe => |pipe| if (pipe.refs == 1) {
            if (tasks.world().input == .pipe and tasks.world().input.pipe == pipe) tasks.world().input = p.start_input;
            if (tasks.world().output == .pipe and tasks.world().output.pipe == pipe) tasks.world().output = p.start_output;
            if (tasks.world().errout == .pipe and tasks.world().errout.pipe == pipe) tasks.world().errout = p.start_errout;
        },
        .reader => |c| if (c.readers == 1 and tasks.world().input == .channel and tasks.world().input.channel == c) {
            tasks.world().input = p.start_input;
        },
        .writer => |c| if (c.writers == 1) {
            if (tasks.world().output == .channel and tasks.world().output.channel == c) tasks.world().output = p.start_output;
            if (tasks.world().errout == .channel and tasks.world().errout.channel == c) tasks.world().errout = p.start_errout;
        },
        .dir, .null_dev, .tty, .socket, .term, .queue, .counter => {}, // streams set from these are NUL, the keyboard, the screen: nothing to undo
    }
}

// POSIX PIPES, DUP, POLL

fn createChannel(handles: *[2]i32) callconv(abi.cc) bool {
    return succeeded(newChannel(handles));
}

fn newChannel(handles: *[2]i32) Error!void {
    const r = try freeSlot();
    const p = prog();
    const c = stdio.Channel.create() orelse return error.OutOfMemory;
    c.readers = 1;
    p.handles[r] = .{ .reader = c };
    const w = freeSlot() catch |err| {
        p.handles[r] = null;
        c.closeReader();
        return err;
    };
    c.writers = 1;
    p.handles[w] = .{ .writer = c };
    handles.* = .{ @intCast(r), @intCast(w) };
}

fn dup(handle: i32) callconv(abi.cc) i32 {
    return result(i32, dupHandle(handle), -1);
}

fn dupHandle(handle: i32) Error!i32 {
    const o = try byHandle(handle);
    const slot = try freeSlot();
    switch (o) {
        .file => |f| f.refs += 1,
        .pipe => |pp| pp.refs += 1,
        .reader => |c| c.readers += 1,
        .writer => |c| c.writers += 1,
        .tty => |t| t.refs += 1,
        .socket => |sock| sock.refs += 1,
        .term => |t| t.retainHolder(),
        .queue => |q| q.refs += 1,
        .counter => |c| c.refs += 1,
        .null_dev => {},
        .dir => return error.NotSupported,
    }
    prog().handles[slot] = o;
    return @intCast(slot);
}

// Waits as MINIX's select and SerenityOS's poll do: a watch on
// each handle's object (events.zig), then one sleep until one of
// them notifies, a signal, Ctrl+C or the timeout, nothing looked
// at again on a timer. Without a watch (the table full, no task
// switching) each millisecond, as before.
fn poll(fds: [*]abi.PollFd, count: u32, timeout_ms: i32) callconv(abi.cc) i32 {
    const list = fds[0..count];
    var ready = lookAt(list);
    if (ready > 0 or timeout_ms == 0) return polled(ready);
    const until: ?u64 = if (timeout_ms > 0) platform.clock.millis() + @as(u64, @intCast(timeout_ms)) else null;
    if (!tasks.active()) return pollEachMs(list, until);

    const slot = (@intFromPtr(tasks.currentTask()) - @intFromPtr(&tasks.tasks)) / @sizeOf(tasks.Task);
    const q = &poll_queues[slot];
    if (poll_left[slot]) queues.pollUnwatchAll(q); // its last poller ended inside
    poll_left[slot] = true;
    var n: usize = 0; // watches made
    var each_ms = false; // an object without one
    var keys = prog().ctrl_c == .ends; // Ctrl+C ends the wait too
    for (list) |*f| {
        var obj: ?*const anyopaque = null;
        if (pollObject(f.handle, &obj) == .keys) keys = true;
        const o = obj orelse continue;
        if (n < max_poll_watches and queues.pollWatch(q, o) != null) n += 1 else each_ms = true;
    }
    if (keys) {
        if (n < max_poll_watches and queues.pollWatch(q, con.inputObject()) != null) n += 1 else each_ms = true;
    }
    ready = pollWait(list, q, until, each_ms, keys);
    queues.pollUnwatchAll(q);
    poll_left[slot] = false;
    if (ready == poll_ctrl_c) stopByCtrlC();
    if (ready < 0) return failInt(.interrupted);
    return polled(ready);
}

const max_poll_watches = 128;
var poll_queues: [tasks.max_tasks]queues.Queue = @splat(.{});
var poll_left: [tasks.max_tasks]bool = @splat(false); // watches a poll may have left
const poll_ctrl_c: i32 = -2;

// The waiting: ready handles, -1 for a signal,
// poll_ctrl_c (the watches go first)
fn pollWait(list: []abi.PollFd, q: *queues.Queue, until: ?u64, each_ms: bool, keys: bool) i32 {
    while (true) {
        const seen = q.news.load(.acquire);
        if (prog().ctrl_c == .ends and con.breakRequested()) return poll_ctrl_c;
        const ready = lookAt(list);
        if (ready > 0) return ready;
        var ms: ?u32 = null;
        if (until) |e| {
            const now = platform.clock.millis();
            if (now >= e) return 0;
            ms = @intCast(@min(e - now, std.math.maxInt(u32)));
        }
        const look: ?u32 = if (each_ms) 1 else if (keys) con.inputLookMs() else null;
        if (look) |l| ms = if (ms) |m| @min(m, l) else l;
        const asked = if (keys) con.inputWanted() else false;
        const ok = tasks.waitObjectSince(q, ms, &q.news, seen);
        con.inputUnwanted(asked);
        if (!ok) return -1;
    }
}

// Without task switching: looked at each millisecond
fn pollEachMs(list: []abi.PollFd, until: ?u64) i32 {
    while (true) {
        checkCtrlC();
        const ready = lookAt(list);
        if (ready > 0) return polled(ready);
        if (until) |e| if (platform.clock.millis() >= e) return polled(0);
        if (!tasks.sleep(1)) return failInt(.interrupted);
    }
}

fn polled(ready: i32) i32 {
    prog().last_error = .none;
    return ready;
}

fn lookAt(list: []abi.PollFd) i32 {
    var ready: i32 = 0;
    for (list) |*f| {
        f.revents = readiness(f.handle, f.events);
        if (f.revents != 0) ready += 1;
    }
    return ready;
}

// What notifies when a handle's readiness changes, into obj;
// keys: the console's input. Handles always ready (files) or
// never (queues) need nothing.
const PollKind = enum { object, keys };

fn pollObject(handle: i32, obj: *?*const anyopaque) PollKind {
    if (handle == abi.PollFd.stdin_handle) {
        switch (tasks.world().input) {
            .none => return .keys,
            .channel => |c| obj.* = c,
            else => {},
        }
        return .object;
    }
    const o = byHandle(handle) catch return .object;
    switch (o) {
        .socket => |sock| obj.* = sock.z,
        .reader, .writer => |c| obj.* = c,
        .counter => |c| obj.* = c,
        .term => |t| obj.* = t.output,
        .tty => return .keys,
        else => {},
    }
    return .object;
}

fn readiness(handle: i32, events: u16) u16 {
    const P = abi.Poll;
    const always = events & (P.in | P.out);
    if (handle == abi.PollFd.stdin_handle) {
        return switch (tasks.world().input) {
            .none => if (con.keyWaiting()) events & P.in else 0,
            .channel => |c| channelIn(c, events),
            else => events & P.in,
        };
    }
    const o = byHandle(handle) catch return P.nval;
    return switch (o) {
        .file, .pipe => always,
        .dir => P.nval,
        .reader => |c| channelIn(c, events),
        .writer => |c| if (c.readers == 0) P.err else if (c.unread < stdio.Channel.capacity) events & P.out else 0,
        .null_dev => always,
        .tty => (if (con.keyWaiting()) events & P.in else 0) | (events & P.out),
        .socket => |sock| net.readiness(sock, events),
        .term => |t| channelIn(t.output, events) | (events & P.out),
        .queue => 0,
        .counter => |c| @as(u16, @truncate(c.readiness())) & events,
    };
}

fn channelIn(c: *stdio.Channel, events: u16) u16 {
    var r: u16 = 0;
    if (c.unread > 0) r |= events & abi.Poll.in;
    if (c.writers == 0) r |= abi.Poll.hup;
    return r;
}

// EVENT QUEUES AND COUNTERS (EVENTS.ZIG)

fn queueCode(err: queues.Error) abi.ErrorCode {
    return switch (err) {
        error.InvalidArgument => .invalid_argument,
        error.AlreadyExists => .already_exists,
        error.NotFound => .not_found,
        error.OutOfMemory => .out_of_memory,
        error.Interrupted => .interrupted,
        error.WouldBlock => .would_block,
    };
}

fn counterResult(r: queues.Error!usize) i64 {
    const n = r catch |err| return failInt(queueCode(err));
    prog().last_error = .none;
    return @intCast(n);
}

fn queueCreate(flags: u32) callconv(abi.cc) i32 {
    if (flags != 0) return failInt(.invalid_argument);
    const slot = freeSlot() catch |err| return failInt(fs.errorCode(err));
    const q = queues.createQueue() orelse return failInt(.out_of_memory);
    prog().handles[slot] = .{ .queue = q };
    prog().last_error = .none;
    return @intCast(slot);
}

fn counterCreate(value: u32, flags: u32) callconv(abi.cc) i32 {
    if (flags & ~@as(u32, abi.CounterFlags.semaphore | abi.CounterFlags.nonblocking) != 0) return failInt(.invalid_argument);
    const slot = freeSlot() catch |err| return failInt(fs.errorCode(err));
    const c = queues.createCounter(value, flags) orelse return failInt(.out_of_memory);
    prog().handles[slot] = .{ .counter = c };
    prog().last_error = .none;
    return @intCast(slot);
}

// What a watchable handle's object
// notifies with (events.notify); null:
// not watchable
fn watchedObject(o: Open) ?*const anyopaque {
    return switch (o) {
        .socket => |sock| sock.z,
        .reader, .writer => |c| c,
        .counter => |c| c,
        else => null,
    };
}

fn queueReadiness(handle: i32, obj: *const anyopaque) ?u32 {
    const B = abi.QueueBits;
    const o = byHandle(handle) catch return null;
    if (watchedObject(o) != obj) return null;
    return switch (o) {
        .socket => |sock| net.queueReadiness(sock),
        .reader => |c| (if (c.unread > 0) B.in else 0) | (if (c.writers == 0) B.hup else 0),
        .writer => |c| if (c.readers == 0) B.err else if (c.unread < stdio.Channel.capacity) B.out else 0,
        .counter => |c| c.readiness(),
        else => null,
    };
}

fn queueEvents(queue: i32, changes: ?[*]const abi.QueueChange, count: u32, out: ?[*]abi.QueueEvent, max: u32, timeout_ms: i32) callconv(abi.cc) i32 {
    const q = switch (byHandle(queue) catch |err| return failInt(fs.errorCode(err))) {
        .queue => |q| q,
        else => return failInt(.invalid_handle),
    };
    if (count > 0) {
        const list = changes orelse return failInt(.invalid_argument);
        for (list[0..count]) |ch| {
            const o = byHandle(ch.handle) catch |err| return failInt(fs.errorCode(err));
            const obj = watchedObject(o) orelse return failInt(.not_supported);
            queues.change(q, prog(), ch.handle, obj, ch.op, ch.events, ch.data) catch |err| return failInt(queueCode(err));
        }
    }
    if (max == 0) {
        prog().last_error = .none;
        return 0;
    }
    const events_out = out orelse return failInt(.invalid_argument);
    const n = queues.wait(q, events_out[0..@min(max, 1024)], timeout_ms, &queueReadiness) catch |err| return failInt(queueCode(err));
    prog().last_error = .none;
    return @intCast(n);
}

// REMOTE CONSOLES (TERM.ZIG)

fn termCreate(cols: u32, rows: u32) callconv(abi.cc) i32 {
    if (!tasks.active()) return failInt(.not_supported);
    const slot = freeSlot() catch |err| return failInt(fs.errorCode(err));
    const t = Term.create(cols, rows) orelse return failInt(.out_of_memory);
    prog().handles[slot] = .{ .term = t };
    prog().last_error = .none;
    return @intCast(slot);
}

fn termResize(handle: i32, cols: u32, rows: u32) callconv(abi.cc) bool {
    switch (byHandle(handle) catch |err| return fail(fs.errorCode(err))) {
        .term => |t| t.resize(cols, rows),
        else => return fail(.invalid_handle),
    }
    prog().last_error = .none;
    return true;
}

fn createPipe() callconv(abi.cc) i32 {
    return result(i32, newPipe(), -1);
}

fn newPipe() Error!i32 {
    const slot = try freeSlot();
    prog().handles[slot] = .{ .pipe = stdio.Pipe.create() orelse return error.OutOfMemory };
    return @intCast(slot);
}

fn readInput(buf: [*]u8, len: usize) callconv(abi.cc) usize {
    checkCtrlC();
    return stdio.read(buf[0..len]);
}

fn inputRedirected() callconv(abi.cc) bool {
    return stdio.inputRedirected();
}

fn outputRedirected() callconv(abi.cc) bool {
    return !stdio.outputIsScreen();
}

fn printError(str: [*]const u8, len: usize) callconv(abi.cc) void {
    checkCtrlC();
    con.printError(str[0..len]);
}

fn errorRedirected() callconv(abi.cc) bool {
    return tasks.world().errout != .screen;
}

fn getVar(name: [*]const u8, name_len: usize, buf: [*]u8, len: usize) callconv(abi.cc) i64 {
    return result(i64, getVariable(name[0..name_len], buf[0..len]), -1);
}

fn getVariable(name: []const u8, buf: []u8) Error!i64 {
    const v = env.get(name) orelse return error.NotFound;
    const n = @min(v.len, buf.len);
    @memcpy(buf[0..n], v[0..n]);
    return @intCast(v.len);
}

fn getDrives(buf: [*]u8, len: usize) callconv(abi.cc) usize {
    fs.pollDevices();
    var n: usize = 0;
    for (fs.drives) |d| {
        if (d.letter == 0 or n == len) continue; // hidden partitions have no letter
        buf[n] = d.letter;
        n += 1;
    }
    return n;
}

// SCREEN

fn clearScreen() callconv(abi.cc) void {
    con.clearScreen();
}

fn setCursor(col: u32, row: u32) callconv(abi.cc) void {
    con.setCursor(.{ .col = col, .row = row });
}

fn getCursor() callconv(abi.cc) abi.Pos {
    const p = con.getCursor();
    return .{ .col = p.col, .row = p.row };
}

fn screenSize() callconv(abi.cc) abi.Pos {
    const p = con.size();
    return .{ .col = p.col, .row = p.row };
}

fn setColor(fg: abi.Color, bg: abi.Color) callconv(abi.cc) void {
    con.setColor(@intFromEnum(fg), @intFromEnum(bg));
}

fn showCursor(visible: bool) callconv(abi.cc) void {
    con.showCursor(visible);
}

// TIME

fn toApiTime(t: platform.DateTime) abi.Time {
    return .{ .year = t.year, .month = t.month, .day = t.day, .hour = t.hour, .minute = t.minute, .second = t.second };
}

fn millis() callconv(abi.cc) u64 {
    return platform.clock.millis();
}

fn nanos() callconv(abi.cc) u64 {
    return platform.clock.nanos();
}

fn resolution() callconv(abi.cc) u64 {
    return platform.clock.resolution();
}

// In steps, so Ctrl+C ends a long wait soon
fn sleep(ms: u32) callconv(abi.cc) void {
    var left = ms;
    while (true) {
        checkCtrlC();
        if (left == 0) return;
        const step = @min(left, 50);
        if (!tasks.sleep(step)) return; // a signal: handled on returning
        left -= step;
    }
}

fn nap(ms: u32) callconv(abi.cc) u32 {
    const began = platform.clock.millis();
    if (tasks.sleep(ms)) return 0;
    const slept = platform.clock.millis() - began;
    return if (slept >= ms) 0 else @intCast(ms - slept);
}

fn napUntil(deadline: u64) callconv(abi.cc) u64 {
    if (tasks.sleepUntil(deadline)) return 0;
    const now = platform.clock.nanos();
    return if (now >= deadline) 0 else deadline - now;
}

fn getTime(time: *abi.Time) callconv(abi.cc) void {
    time.* = if (platform.clock.now()) |t| toApiTime(t) else .{ .year = 0, .month = 0, .day = 0, .hour = 0, .minute = 0, .second = 0 };
}

fn setTime(time: *const abi.Time) callconv(abi.cc) bool {
    return succeeded(setClock(time));
}

fn fromApiTime(time: *const abi.Time) platform.DateTime {
    return .{
        .year = time.year,
        .month = time.month,
        .day = time.day,
        .hour = time.hour,
        .minute = time.minute,
        .second = time.second,
    };
}

fn setClock(time: *const abi.Time) Error!void {
    try perm.mustBeAdmin();
    const value = fromApiTime(time);
    if (!datetime.valid(value)) return error.InvalidArgument;
    if (!platform.clock.set(value)) return error.NotSupported; // the platform clock refused
}

// NETWORK (SRC/NET/NET.ZIG)

// For net.zig's waits: whether Ctrl+C is to end the program waiting
pub fn ctrlCWanted() bool {
    const p = tasks.world().program orelse return false;
    return p.ctrl_c == .ends and con.breakRequested();
}

fn netFail(err: net.Error) void {
    if (err == error.Interrupted) checkCtrlC();
    prog().last_error = net.errorCode(err);
}

fn netOk(r: net.Error!void) bool {
    r catch |err| {
        netFail(err);
        return false;
    };
    prog().last_error = .none;
    return true;
}

fn netInfo(out: *abi.NetInfo) callconv(abi.cc) void {
    net.info(out);
}

fn netRenew(timeout_ms: u32) callconv(abi.cc) bool {
    return netOk(net.renew(timeout_ms));
}

fn netRelease() callconv(abi.cc) bool {
    return netOk(net.releaseAddress());
}

fn netInterface(index: u32, out: *abi.NetInfo) callconv(abi.cc) bool {
    if (!net.interfaceInfo(index, out)) return fail(if (net.active()) .not_found else .network_down);
    prog().last_error = .none;
    return true;
}

fn netRoute(index: u32, out: *abi.NetRoute) callconv(abi.cc) bool {
    if (!net.route(index, out)) return fail(if (net.active()) .not_found else .network_down);
    prog().last_error = .none;
    return true;
}

fn netResolve(name: [*]const u8, len: usize, out: *[4]u8) callconv(abi.cc) bool {
    const a = net.resolve(name[0..len]) catch |err| {
        netFail(err);
        return false;
    };
    out.* = @bitCast(a);
    prog().last_error = .none;
    return true;
}

fn netPing(addr: *const [4]u8, seq: u16, data_size: u16, ttl: u8, timeout_ms: u32, out: *abi.PingReply) callconv(abi.cc) bool {
    const a = net.ping(@bitCast(addr.*), seq, @min(data_size, 1472), if (ttl == 0) 64 else ttl, timeout_ms) catch |err| {
        netFail(err);
        return false;
    };
    out.* = .{
        .result = switch (a.kind) {
            .reply => abi.PingResult.reply,
            .unreachable_ => abi.PingResult.unreachable_,
            .ttl_expired => abi.PingResult.ttl_expired,
        },
        .ttl = a.ttl,
        .bytes = a.bytes,
        .rtt_ms = a.rtt,
        .from = @bitCast(a.from),
    };
    prog().last_error = .none;
    return true;
}

fn netArpEntry(index: u32, out: *abi.ArpEntry) callconv(abi.cc) bool {
    if (!net.arpEntry(index, out)) return fail(if (net.active()) .not_found else .network_down);
    prog().last_error = .none;
    return true;
}

fn netArpAdd(addr: *const [4]u8, mac: *const [6]u8) callconv(abi.cc) bool {
    perm.mustBeAdmin() catch return fail(.access_denied);
    return netOk(net.arpAdd(@bitCast(addr.*), mac));
}

fn netArpRemove(addr: ?*const [4]u8) callconv(abi.cc) bool {
    perm.mustBeAdmin() catch return fail(.access_denied);
    return netOk(net.arpRemove(if (addr) |a| @as(u32, @bitCast(a.*)) else null));
}

fn netConnection(index: u32, out: *abi.Connection) callconv(abi.cc) bool {
    if (!net.connection(index, out)) return fail(if (net.active()) .not_found else .network_down);
    prog().last_error = .none;
    return true;
}

// The socket of a handle; null with last_error set
fn socketOf(handle: i32) ?*net.Socket {
    const o = byHandle(handle) catch {
        prog().last_error = .invalid_handle;
        return null;
    };
    if (o != .socket) {
        prog().last_error = .not_a_socket;
        return null;
    }
    return o.socket;
}

fn netSocket(kind: u32) callconv(abi.cc) i32 {
    if (kind != abi.SocketType.stream and kind != abi.SocketType.datagram) return failInt(.invalid_argument);
    const slot = freeSlot() catch return failInt(.too_many_open);
    const sock = net.socket(kind == abi.SocketType.stream) catch |err| {
        netFail(err);
        return -1;
    };
    prog().handles[slot] = .{ .socket = sock };
    prog().last_error = .none;
    return @intCast(slot);
}

fn netBind(handle: i32, addr: *const abi.NetAddress) callconv(abi.cc) bool {
    const sock = socketOf(handle) orelse return false;
    // Ports below 1024 are root's, as on Unix
    if (addr.port != 0 and addr.port < 1024) perm.mustBeAdmin() catch return fail(.access_denied);
    return netOk(net.bind(sock, @bitCast(addr.addr), addr.port));
}

fn netListen(handle: i32, backlog: u32) callconv(abi.cc) bool {
    const sock = socketOf(handle) orelse return false;
    return netOk(net.listen(sock, backlog));
}

fn netAccept(handle: i32, peer: ?*abi.NetAddress) callconv(abi.cc) i32 {
    const sock = socketOf(handle) orelse return -1;
    const c = net.accept(sock) catch |err| {
        netFail(err);
        return -1;
    };
    // Looked for after the wait: another
    // thread may have taken a handle meanwhile
    const slot = freeSlot() catch {
        net.release(c);
        return failInt(.too_many_open);
    };
    if (peer) |p| {
        const a = net.address(c, true) catch net.From{};
        p.* = .{ .addr = @bitCast(a.addr), .port = a.port };
    }
    prog().handles[slot] = .{ .socket = c };
    prog().last_error = .none;
    return @intCast(slot);
}

fn netConnect(handle: i32, addr: *const abi.NetAddress) callconv(abi.cc) bool {
    const sock = socketOf(handle) orelse return false;
    return netOk(net.connect(sock, @bitCast(addr.addr), addr.port));
}

fn flagsOf(flags: u32) net.Flags {
    return .{ .peek = flags & abi.SocketFlags.peek != 0, .dont_wait = flags & abi.SocketFlags.dont_wait != 0 };
}

fn socketSend(sock: *net.Socket, data: []const u8, flags: u32, to: ?*const abi.NetAddress, via: ?*const abi.NetVia) i64 {
    var dest: ?net.From = if (to) |t| .{ .addr = @bitCast(t.addr), .port = t.port } else null;
    if (via) |v| {
        dest.?.card = v.card;
        dest.?.local = @bitCast(v.local);
    }
    const n = net.send(sock, data, flagsOf(flags), dest) catch |err| {
        if (err == error.BrokenPipe and flags & abi.SocketFlags.no_signal == 0) tasks.kill(tasks.currentId(), abi.Signal.pipe) catch {};
        netFail(err);
        return -1;
    };
    prog().last_error = .none;
    return @intCast(n);
}

fn socketRecv(sock: *net.Socket, buf: []u8, flags: u32, from: ?*abi.NetAddress, via: ?*abi.NetVia) i64 {
    var f: net.From = .{};
    const n = net.recv(sock, buf, flagsOf(flags), &f) catch |err| {
        netFail(err);
        return -1;
    };
    if (from) |out| out.* = .{ .addr = @bitCast(f.addr), .port = f.port };
    if (via) |out| out.* = .{ .card = f.card, .local = @bitCast(f.local) };
    prog().last_error = .none;
    return @intCast(n);
}

fn netSend(handle: i32, buf: [*]const u8, len: usize, flags: u32) callconv(abi.cc) i64 {
    const sock = socketOf(handle) orelse return -1;
    return socketSend(sock, buf[0..len], flags, null, null);
}

fn netRecv(handle: i32, buf: [*]u8, len: usize, flags: u32) callconv(abi.cc) i64 {
    const sock = socketOf(handle) orelse return -1;
    return socketRecv(sock, buf[0..len], flags, null, null);
}

fn netSendTo(handle: i32, buf: [*]const u8, len: usize, flags: u32, to: *const abi.NetAddress) callconv(abi.cc) i64 {
    const sock = socketOf(handle) orelse return -1;
    return socketSend(sock, buf[0..len], flags, to, null);
}

fn netSendVia(handle: i32, buf: [*]const u8, len: usize, flags: u32, to: *const abi.NetAddress, via: *const abi.NetVia) callconv(abi.cc) i64 {
    const sock = socketOf(handle) orelse return -1;
    if (sock.stream) return failInt(.invalid_argument);
    return socketSend(sock, buf[0..len], flags, to, via);
}

fn netRecvFrom(handle: i32, buf: [*]u8, len: usize, flags: u32, from: ?*abi.NetAddress) callconv(abi.cc) i64 {
    const sock = socketOf(handle) orelse return -1;
    return socketRecv(sock, buf[0..len], flags, from, null);
}

fn netRecvVia(handle: i32, buf: [*]u8, len: usize, flags: u32, from: ?*abi.NetAddress, via: ?*abi.NetVia) callconv(abi.cc) i64 {
    const sock = socketOf(handle) orelse return -1;
    return socketRecv(sock, buf[0..len], flags, from, via);
}

fn netShutdown(handle: i32, how: u32) callconv(abi.cc) bool {
    const sock = socketOf(handle) orelse return false;
    if (how > 2) return fail(.invalid_argument);
    return netOk(net.shutdown(sock, how != 1, how != 0));
}

fn netAddress(handle: i32, peer: bool, out: *abi.NetAddress) callconv(abi.cc) bool {
    const sock = socketOf(handle) orelse return false;
    const a = net.address(sock, peer) catch |err| {
        netFail(err);
        return false;
    };
    out.* = .{ .addr = @bitCast(a.addr), .port = a.port };
    prog().last_error = .none;
    return true;
}

fn netSetOption(handle: i32, option: u32, value: u32) callconv(abi.cc) bool {
    const sock = socketOf(handle) orelse return false;
    return netOk(net.setOption(sock, option, value));
}

fn netGetOption(handle: i32, option: u32, out: *u32) callconv(abi.cc) bool {
    const sock = socketOf(handle) orelse return false;
    out.* = net.getOption(sock, option) catch |err| {
        netFail(err);
        return false;
    };
    prog().last_error = .none;
    return true;
}
