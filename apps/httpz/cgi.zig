// CGI for HTTPZ. HTTPZ starts itself as "-cgi" in a task of its own (a
// new task gets only the global variables): it reads the CGI variables
// from its input, sets them in its own scope and runs the script, whose
// input is then the request body and whose output the reply.
const std = @import("std");
const zdos = @import("../zdos/zdos.zig");
const sys = @import("../zdos/system.zig");

pub const max_interpreters = 16;
const max_var = 512; // a ZDOS variable's longest value

pub const Interpreter = struct {
    ext_buf: [16]u8 = undefined,
    ext_len: usize = 0,
    path_buf: [256]u8 = undefined,
    path_len: usize = 0,

    pub fn ext(self: *const Interpreter) []const u8 {
        return self.ext_buf[0..self.ext_len];
    }

    pub fn path(self: *const Interpreter) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

// THE HELPER TASK: HTTPZ -cgi <interpreter or -><TAB><script>

fn readExact(buf: []u8) bool {
    var got: usize = 0;
    while (got < buf.len) {
        const n = zdos.readInput(buf[got..]);
        if (n == 0) return false;
        got += n;
    }
    return true;
}

pub fn helper(args: []const u8) u8 {
    const tab = std.mem.indexOfScalar(u8, args, '\t') orelse return 1;
    const interpreter = args[0..tab];
    const script = args[tab + 1 ..];
    // "<length>\n", then NAME=VALUE lines of that length:
    var len_buf: [16]u8 = undefined;
    var n: usize = 0;
    while (n < len_buf.len) : (n += 1) {
        if (!readExact(len_buf[n..][0..1])) return 1;
        if (len_buf[n] == '\n') break;
    }
    const len = std.fmt.parseInt(usize, len_buf[0..n], 10) catch return 1;
    const vars = zdos.allocator.alloc(u8, len) catch return 1;
    defer zdos.allocator.free(vars);
    if (!readExact(vars)) return 1;
    sys.pushVars() catch return 1;
    var lines = std.mem.splitScalar(u8, vars, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const value = line[eq + 1 ..];
        zdos.setVar(line[0..eq], value[0..@min(value.len, max_var)]) catch {};
    }
    if (std.fs.path.dirnameWindows(script)) |dir| zdos.setCwd(dir) catch {};
    const native = std.mem.eql(u8, interpreter, "-");
    return (if (native) zdos.exec(script, "") else zdos.exec(interpreter, script)) catch |err| {
        // The reply says why (no execute permission, a missing interpreter):
        zdos.printf("Status: 500 Internal Server Error\nContent-Type: text/plain\n\nCGI: can't run {s}: {s}\n", .{
            if (native) script else interpreter, zdos.message(err),
        });
        return 127;
    };
}

// RUNNING ONE

pub const Request = struct {
    own_path: []const u8, // HTTPZ.APP
    script: []const u8,
    interpreter: ?[]const u8,
    vars: []const u8, // NAME=VALUE lines
    body: []const u8,
    timeout_ms: u64,
};

const Feed = struct {
    pipe: zdos.File,
    head_buf: [16]u8 = undefined, // "<length of vars>\n"
    head_len: usize = 0,
    vars: []const u8,
    body: []const u8,

    fn run(arg: ?*anyopaque) callconv(zdos.cc) usize {
        const f: *Feed = @ptrCast(@alignCast(arg.?));
        defer f.pipe.close();
        f.pipe.writeAll(f.head_buf[0..f.head_len]) catch return 0;
        f.pipe.writeAll(f.vars) catch return 0;
        f.pipe.writeAll(f.body) catch return 0;
        return 0;
    }
};

pub const Started = struct {
    task: u32,
    output: zdos.File,
    feed: *Feed,
    feeder: u32,
    deadline: u64,

    // 0 at the end. TimedOut when the time is up.
    pub fn read(self: *Started, buf: []u8) zdos.Error!usize {
        while (true) {
            const now = zdos.millis();
            if (now >= self.deadline) return error.TimedOut;
            var fds = [1]zdos.PollFd{.{ .handle = self.output.handle, .events = zdos.Poll.in }};
            const wait: i32 = @intCast(@min(self.deadline - now, 1000));
            if (zdos.table().files.poll(&fds, 1, wait) <= 0) continue;
            return self.output.read(buf) catch |err| if (err == error.BrokenPipe) 0 else err;
        }
    }

    // Stopped if still running, waited for.
    pub fn finish(self: *Started) void {
        self.output.close();
        if (sys.taskEnded(self.task) == null) {
            const until = zdos.millis() + 500;
            while (sys.taskEnded(self.task) == null and zdos.millis() < until) zdos.sleep(10);
            if (sys.taskEnded(self.task) == null) sys.signalSend(self.task, sys.Signal.kill) catch {};
        }
        _ = sys.taskWait(self.task) catch {};
        _ = sys.threadJoin(self.feeder) catch {};
        zdos.allocator.destroy(self.feed);
    }
};

pub fn start(r: Request) zdos.Error!Started {
    var args_buf: [600]u8 = undefined;
    const args = std.fmt.bufPrint(&args_buf, "-cgi {s}\t{s}", .{ r.interpreter orelse "-", r.script }) catch return error.InvalidArgument;
    const in = try sys.pipe();
    const out = sys.pipe() catch |err| {
        zdos.table().files.close(in.read);
        zdos.table().files.close(in.write);
        return err;
    };
    const opts: sys.SpawnOptions = .{ .input = in.read, .output = out.write, .err = sys.SpawnOptions.nul_stream };
    const task = sys.taskSpawnWith(r.own_path, args, opts) catch |err| {
        for ([_]i32{ in.read, in.write, out.read, out.write }) |h| zdos.table().files.close(h);
        return err;
    };
    zdos.table().files.close(in.read);
    zdos.table().files.close(out.write);

    // Variables and body from a thread of their own: a script that writes
    // before reading the whole body must not stop us:
    const feed = zdos.allocator.create(Feed) catch {
        zdos.table().files.close(in.write);
        zdos.table().files.close(out.read);
        sys.signalSend(task, sys.Signal.kill) catch {};
        _ = sys.taskWait(task) catch {};
        return error.OutOfMemory;
    };
    feed.* = .{ .pipe = .{ .handle = in.write }, .vars = r.vars, .body = r.body };
    feed.head_len = (std.fmt.bufPrint(&feed.head_buf, "{d}\n", .{r.vars.len}) catch unreachable).len;
    const feeder = sys.threadCreate(&Feed.run, feed, 32 * 1024, null) catch |err| {
        zdos.table().files.close(in.write);
        zdos.table().files.close(out.read);
        zdos.allocator.destroy(feed);
        sys.signalSend(task, sys.Signal.kill) catch {};
        _ = sys.taskWait(task) catch {};
        return err;
    };
    return .{ .task = task, .output = .{ .handle = out.read }, .feed = feed, .feeder = feeder, .deadline = zdos.millis() + r.timeout_ms };
}
