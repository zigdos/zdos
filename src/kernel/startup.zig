// Kernel startup: drives, variables, SYSTEM.CFG, drivers, the
// network and services, then the command interpreter (SHELL= or
// COMSPEC=), restarted whenever it ends;
// LOGIN.APP WITH LOGIN=true.
const std = @import("std");
const platform = @import("../platform.zig");
const con = @import("console.zig");
const fs = @import("fs.zig");
const env = @import("env.zig");
const config = @import("config.zig");
const loader = @import("loader.zig");
const fonts = @import("fonts.zig");
const keyb = @import("keyb.zig");
const tasks = @import("tasks.zig");
const perm = @import("perm.zig");
const api = @import("api.zig");
const ver = @import("version.zig");
const net = @import("../net/net.zig");
const rtheap = @import("rtheap.zig");
const scrollback = @import("scrollback.zig");
const services = @import("services.zig");
const drivers = @import("drivers.zig");
const hotplug = @import("hotplug.zig");
const serial = @import("serial.zig");
const sound = @import("sound.zig");

var interpreter_buf: [fs.max_path + 2]u8 = undefined;
var interpreter: []const u8 = ""; // full path, "C:\APPS\COMMAND.APP"

pub fn run() noreturn {
    tasks.init(); // what runs from here on is task 0
    // ZDOS's own work here is under the kernel lock, as
    // programs' calls are: services (SSHD) run beside it from
    // SERVICES.CFG on (the loader gives it up while a
    // program's code runs)
    _ = tasks.enterKernel();
    con.initInput(); // keys wake their waiters
    scrollback.init(); // lines leaving the screen are kept from here on
    env.init();
    fs.init();
    // PATH: the boot drive's \APPS (A:\APPS after booting from a floppy)
    var default_name = "C:\\APPS\\COMMAND.APP".*;
    if (fs.bootDrive()) |d| {
        default_name[0] = d.letter;
        env.set("PATH", default_name[0.."C:\\APPS".len]) catch {};
    }
    // After SYSTEM.CFG:
    // FONT=, CODEPAGE= and KEYB= are read from the variables
    config.load();
    platform.configure(&env.get); // before the first program
    perm.configure(&env.get);
    scrollback.configure(&env.get); // SCROLLBACK=
    fonts.apply();
    keyb.apply();
    drivers.loadAll(); // \SYSTEM\DRIVERS\*.SYS (metal, BIOS)
    reserveHeap(); // RTHEAP=
    if (env.get("VOLUME")) |v| {
        const p = std.fmt.parseInt(u32, std.mem.trim(u8, v, " \t%"), 10) catch 101;
        if (p > 100) con.printf("SYSTEM.CFG: VOLUME={s}: a number 0-100\n", .{v}) else sound.startVolume(p);
    }
    if (env.get("IRQPRIO")) |v| {
        const p = std.fmt.parseInt(u8, std.mem.trim(u8, v, " \t"), 10) catch 255;
        if (p >= tasks.priorities or !tasks.setIrqPriority(p)) con.printf("SYSTEM.CFG: IRQPRIO={s}: a priority 0-31\n", .{v});
    }
    if (env.get("CLSONSTART")) |val| {
        if (std.mem.eql(u8, val, "true")) {
            con.clearScreen();
        }
    }
    con.printf("ZDOS version {d}.{d} {s}\n\n", .{ ver.zdos[0], ver.zdos[1], platform.name });
    fs.reportAllNotClean(); // after the banner: CLSONSTART keeps it
    net.start(&env.get, &api.ctrlCWanted); // NETWORK=true
    hotplug.start(); // USB disks plugged in from here on (metal)
    serial.start(); // the serial console by its interrupt (BIOS, metal)
    setPlatform();
    setUser();
    services.start(); // SERVICES.CFG
    // The other cores run tasks too (metal): CORES= says how
    // many in all (1: core 0 alone, as before), default all;
    // never the network's own
    tasks.startCores(if (env.get("CORES")) |v| std.fmt.parseInt(usize, std.mem.trim(u8, v, " \t"), 10) catch null else null);
    if (env.get("ISOLCPUS")) |v| isolate(v);
    net.placeTask(); // NETCPU=

    var name_buf: [fs.max_path]u8 = undefined;
    var name: []const u8 = config.interpreter() orelse &default_name;
    var restarted = false;
    const login = if (env.get("LOGIN")) |v| std.ascii.eqlIgnoreCase(v, "true") else false;
    while (true) {
        const path = locate(name);
        var login_buf: [fs.max_path + 2]u8 = undefined;
        const login_path = if (login and path != null) loginProgram(path.?, &login_buf) else null;
        const result = if (login_path) |lp|
            loader.runPath(lp, "")
        else if (path) |p| loader.runPath(p, interpreterArgs(p, restarted)) else @as(loader.Result, .not_found);
        switch (result) {
            .exited => |code| {
                con.printf("\nThe command interpreter ended (exit code {d}); starting it again\n\n", .{code});
                restarted = true;
            },
            else => {
                con.print("\nBad or missing command interpreter: ");
                con.print(name);
                con.printf(" ({s})\n", .{switch (result) {
                    .not_found => "not found",
                    .not_program, .invalid => "not a ZDOS program",
                    .no_memory, .too_deep => "not enough memory",
                    .failed => |err| fs.message(err),
                    .exited => unreachable,
                }});
                con.print("Enter the path of the command interpreter, or press Enter to try again:\n");
                const typed = readLine(&name_buf);
                if (typed.len > 0) name = typed;
            },
        }
    }
}

// PLATFORM (METAL, UEFI, BIOS) AND ARCH (x86_64, arm64, x86:
// zdos-cc's names), for scripts and programs;
// always ZDOS's, whatever SYSTEM.CFG says
fn setPlatform() void {
    env.set("PLATFORM", platform.name) catch {};
    env.set("ARCH", switch (@import("builtin").cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "arm64",
        else => "x86",
    }) catch {};
}

// ISOLCPUS=2,3 or 2-5: cores kept for tasks that ask
// for them (affinity); core 0 and cores not running
// tasks can't be RTHEAP=16M: programs' memory comes
// from a pool taken now, in constant time (real-time
// tasks), before the platform's allocator
fn reserveHeap() void {
    const v = env.get("RTHEAP") orelse return;
    const bytes = rtheap.parseSize(v) orelse return con.printf("SYSTEM.CFG: RTHEAP={s} is not a size (16M, 512K)\n", .{v});
    if (bytes == 0) return;
    if (!rtheap.init(bytes)) con.printf("SYSTEM.CFG: RTHEAP={s}: not that much free memory in one piece (or under 64K)\n", .{v});
}

fn isolate(text: []const u8) void {
    var mask: u64 = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t,");
    while (it.next()) |w| {
        const dash = std.mem.indexOfScalar(u8, w, '-');
        const lo = std.fmt.parseInt(u6, w[0 .. dash orelse w.len], 10) catch return badIsolate(w);
        const hi = if (dash) |d| std.fmt.parseInt(u6, w[d + 1 ..], 10) catch return badIsolate(w) else lo;
        if (lo == 0 or hi < lo or hi >= platform.cores.count()) return badIsolate(w);
        var c = lo;
        while (true) : (c += 1) {
            mask |= @as(u64, 1) << c;
            if (c == hi) break;
        }
    }
    tasks.isolated = mask;
}

fn badIsolate(word: []const u8) void {
    con.printf("SYSTEM.CFG: ISOLCPUS=: \"{s}\" (cores 1 up to {d}; 0 can't be)\n", .{ word, platform.cores.count() - 1 });
}

// USER, LOGNAME and HOME unless SYSTEM.CFG set them: root, in
// \USERS\ROOT on the boot drive, made if
// missing (LOGIN.APP sets them for each user)
fn setUser() void {
    if (env.get("USER") == null) env.set("USER", "ROOT") catch {};
    const user = env.get("USER") orelse "ROOT";
    if (env.get("LOGNAME") == null) env.set("LOGNAME", user) catch {};
    if (env.get("HOME") != null) return;
    const d = fs.bootDrive() orelse return;
    var path: fs.Path = .{};
    path.set("\\USERS");
    fs.makeDir(d, &path) catch {};
    if (!path.append(user)) return;
    // Private, as Unix's /root (where the drive keeps modes: ext2, Minix)
    if (fs.makeDir(d, &path)) {
        fs.setMode(d, &path, 0o700) catch {};
    } else |_| {}
    var buf: [fs.max_path + 2]u8 = undefined;
    const home = std.fmt.bufPrint(&buf, "{c}:{s}", .{ d.letter, path.slice() }) catch return;
    env.set("HOME", home) catch {};
}

// LOGIN.APP in the interpreter's folder, if there
fn loginProgram(interp: []const u8, buf: []u8) ?[]const u8 {
    const dir = std.fs.path.dirnameWindows(interp) orelse return null;
    const sep = if (std.mem.endsWith(u8, dir, "\\")) "" else "\\";
    const name = std.fmt.bufPrint(buf, "{s}{s}LOGIN.APP", .{ dir, sep }) catch return null;
    var f: loader.Found = undefined;
    if (!loader.find(name, &f) or f.kind != .program) return null;
    return name;
}

// -p (permanent) and, on a restart, -d (skip AUTOEXEC.CMD) are
// COMMAND.APP's; other interpreters get no switches
fn interpreterArgs(path: []const u8, restarted: bool) []const u8 {
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basenameWindows(path), "COMMAND.APP")) return "";
    return if (restarted) "-p -d" else "-p";
}

// Resolves name as COMMAND.APP resolves programs and sets
// COMSPEC and SHELL to the full path;
// null if there is no such program
fn locate(name: []const u8) ?[]const u8 {
    var f: loader.Found = undefined;
    if (!loader.find(name, &f) or f.kind != .program) return null;
    interpreter = std.fmt.bufPrint(&interpreter_buf, "{c}:{s}", .{ f.drive.letter, f.path.slice() }) catch return null;
    env.set("COMSPEC", interpreter) catch {};
    // POSIX FORM: "/C:/APPS/COMMAND.APP"
    var posix: [fs.max_path + 3]u8 = undefined;
    posix[0] = '/';
    for (interpreter, 1..) |c, i| posix[i] = if (c == '\\') '/' else c;
    env.set("SHELL", posix[0 .. interpreter.len + 1]) catch {};
    return interpreter;
}

// For run_command: COMSPEC, or the one started
pub fn commandInterpreter() []const u8 {
    return env.get("COMSPEC") orelse interpreter;
}

// Line input for when there is no
// command interpreter to ask for its path
fn readLine(buf: []u8) []const u8 {
    var len: usize = 0;
    while (true) {
        const k = con.readKey();
        switch (k.char) {
            '\r', '\n' => {
                con.print("\n");
                return buf[0..len];
            },
            0x08, 0x7f => if (len > 0) {
                len -= 1;
                const at = con.getCursor();
                if (at.col > 0) {
                    const back: con.Position = .{ .col = at.col - 1, .row = at.row };
                    con.setCursor(back);
                    con.print(" ");
                    con.setCursor(back);
                }
            },
            else => if (k.char >= 0x20 and k.char < 0x7f and len < buf.len) {
                buf[len] = @intCast(k.char);
                len += 1;
                con.print(buf[len - 1 .. len]);
            },
        }
    }
}
