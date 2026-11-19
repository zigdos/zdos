// Programs' standard streams: the screen, or a file or pipe.
//   Pipe (create_pipe): DOS style, A's whole output, then B runs
//   Channel (POSIX pipe): between concurrent tasks, 64 KiB, SIGPIPE
// Files, pipes and channels are refcounted.
const std = @import("std");
const platform = @import("../platform.zig");
const tasks = @import("tasks.zig");
const events = @import("events.zig");
const locks = @import("locks.zig");
const abi = @import("abi.zig");

pub const FileHandle = platform.storage.FileHandle;

// A chain of 64 KiB chunks: no big block or copying when it grows
pub const Buffer = struct {
    first: ?*Chunk = null,
    last: ?*Chunk = null,
    len: usize = 0,
    full: bool = false, // memory ran out: later output was dropped

    pub const chunk_data = 64 * 1024 - 2 * @sizeOf(usize);
    pub const Chunk = struct {
        next: ?*Chunk,
        used: usize,
        data: [chunk_data]u8,
    };

    pub fn append(self: *Buffer, bytes: []const u8) void {
        var rest = bytes;
        while (rest.len > 0 and !self.full) {
            if (self.last == null or self.last.?.used == chunk_data) {
                const mem = platform.memory.alloc(@sizeOf(Chunk)) orelse {
                    self.full = true;
                    return;
                };
                const c: *Chunk = @ptrCast(@alignCast(mem));
                c.next = null;
                c.used = 0;
                if (self.last) |l| l.next = c else self.first = c;
                self.last = c;
            }
            const c = self.last.?;
            const n = @min(rest.len, chunk_data - c.used);
            @memcpy(c.data[c.used..][0..n], rest[0..n]);
            c.used += n;
            self.len += n;
            rest = rest[n..];
        }
    }

    pub fn deinit(self: *Buffer) void {
        var c = self.first;
        while (c) |chunk| {
            c = chunk.next;
            platform.memory.free(@ptrCast(@alignCast(chunk)));
        }
        self.* = .{};
    }
};

// A pipe: written at its end, read from its start
pub const Pipe = struct {
    buf: Buffer = .{},
    chunk: ?*Buffer.Chunk = null, // where reading is
    pos: usize = 0,
    refs: u32 = 1,

    pub fn write(self: *Pipe, bytes: []const u8) void {
        self.buf.append(bytes);
    }

    // Bytes into out; 0 at the end of what was written so far
    pub fn read(self: *Pipe, out: []u8) usize {
        var done: usize = 0;
        while (done < out.len) {
            if (self.chunk == null) self.chunk = self.buf.first;
            const c = self.chunk orelse break;
            if (self.pos == c.used) {
                // The last chunk stays the place to read: more may be written to it
                self.chunk = c.next orelse break;
                self.pos = 0;
                continue;
            }
            const n = @min(out.len - done, c.used - self.pos);
            @memcpy(out[done..][0..n], c.data[self.pos..][0..n]);
            self.pos += n;
            done += n;
        }
        return done;
    }

    // A new pipe in memory from the platform allocator; destroy frees it
    pub fn create() ?*Pipe {
        const mem = platform.memory.alloc(@sizeOf(Pipe)) orelse return null;
        const p: *Pipe = @ptrCast(@alignCast(mem));
        p.* = .{};
        return p;
    }

    pub fn destroy(self: *Pipe) void {
        self.buf.deinit();
        platform.memory.free(@ptrCast(@alignCast(self)));
    }

    // One user less; destroyed by the last.
    // Whether memory ran out while it was written.
    pub fn release(self: *Pipe) bool {
        const full = self.buf.full;
        self.refs -= 1;
        if (self.refs == 0) self.destroy();
        return full;
    }
};

// A program's open file, and the first failure while it was
// standard output or input (reported
// when the program closes it)
pub const File = struct {
    handle: FileHandle,
    err: ?platform.Error = null,
    drive: u8 = 0, // its drive letter (files->fstat_ex)
    refs: u32 = 1,
    writable: bool = false, // opened for writing (files->fset_time may)

    pub fn create(handle: FileHandle, drive: u8) ?*File {
        const mem = platform.memory.alloc(@sizeOf(File)) orelse return null;
        const f: *File = @ptrCast(@alignCast(mem));
        f.* = .{ .handle = handle, .drive = drive };
        return f;
    }

    // One user less; the last one closes it: what failed meanwhile or then
    pub fn release(self: *File) platform.Error!void {
        self.refs -= 1;
        if (self.refs > 0) return;
        locks.dropOwner(self);
        const closed = platform.storage.close(self.handle);
        const err = self.err;
        platform.memory.free(@ptrCast(@alignCast(self)));
        if (err) |e| return e;
        return closed;
    }
};

// CHANNELS (POSIX PIPES)

pub const ChannelError = error{ BrokenPipe, Interrupted };

pub const Channel = struct {
    first: ?*Buffer.Chunk = null, // the chunk being read
    last: ?*Buffer.Chunk = null,
    pos: usize = 0, // read position in first
    unread: usize = 0,
    readers: u32 = 0,
    writers: u32 = 0,

    pub const capacity = 64 * 1024; // unread bytes before writers wait

    pub fn create() ?*Channel {
        const mem = platform.memory.alloc(@sizeOf(Channel)) orelse return null;
        const c: *Channel = @ptrCast(@alignCast(mem));
        c.* = .{};
        return c;
    }

    // Up to out.len bytes, waiting for some while a writer is left;
    // 0 at the end (no writer left, all read). Without task
    // switching nobody could write meanwhile: 0 then too.
    pub fn read(self: *Channel, out: []u8) ChannelError!usize {
        if (out.len == 0) return 0;
        while (self.unread == 0) {
            if (self.writers == 0 or !tasks.active()) return 0;
            if (!tasks.waitObject(self, null)) return error.Interrupted;
        }
        var done: usize = 0;
        while (done < out.len and self.unread > 0) {
            const c = self.first.?;
            if (self.pos == c.used) {
                // Read to its end: the next one (the last stays: writing goes on there)
                const next = c.next orelse break;
                platform.memory.free(@ptrCast(@alignCast(c)));
                self.first = next;
                self.pos = 0;
                continue;
            }
            const n = @min(out.len - done, c.used - self.pos);
            @memcpy(out[done..][0..n], c.data[self.pos..][0..n]);
            self.pos += n;
            self.unread -= n;
            done += n;
        }
        tasks.wake(self); // room for writers
        events.notify(self);
        return done;
    }

    // All of data, waiting while the channel is full;
    // BrokenPipe with no reader left. Interrupted by a signal: what
    // was written so far, if any.
    pub fn write(self: *Channel, data: []const u8) (ChannelError || error{OutOfMemory})!usize {
        var done: usize = 0;
        while (done < data.len) {
            if (self.readers == 0) return if (done > 0) done else error.BrokenPipe;
            if (self.unread >= capacity and tasks.active()) {
                if (!tasks.waitObject(self, null)) return if (done > 0) done else error.Interrupted;
                continue;
            }
            const room = if (tasks.active()) capacity - self.unread else data.len - done;
            const n = try self.append(data[done..][0..@min(room, data.len - done)]);
            done += n;
            tasks.wake(self); // data for readers
            events.notify(self);
        }
        return done;
    }

    fn append(self: *Channel, bytes: []const u8) error{OutOfMemory}!usize {
        var rest = bytes;
        while (rest.len > 0) {
            if (self.last == null or self.last.?.used == Buffer.chunk_data) {
                const mem = platform.memory.alloc(@sizeOf(Buffer.Chunk)) orelse return error.OutOfMemory;
                const c: *Buffer.Chunk = @ptrCast(@alignCast(mem));
                c.next = null;
                c.used = 0;
                if (self.last) |l| l.next = c else {
                    self.first = c;
                    self.pos = 0;
                }
                self.last = c;
            }
            const c = self.last.?;
            const n = @min(rest.len, Buffer.chunk_data - c.used);
            @memcpy(c.data[c.used..][0..n], rest[0..n]);
            c.used += n;
            self.unread += n;
            rest = rest[n..];
        }
        return bytes.len;
    }

    pub fn closeReader(self: *Channel) void {
        self.readers -= 1;
        self.ended();
    }

    pub fn closeWriter(self: *Channel) void {
        self.writers -= 1;
        self.ended();
    }

    // A side closed: the other one's waits end (end of
    // data, broken pipe); both closed: freed
    fn ended(self: *Channel) void {
        tasks.wake(self);
        events.notify(self);
        if (self.readers > 0 or self.writers > 0) return;
        var c = self.first;
        while (c) |chunk| {
            c = chunk.next;
            platform.memory.free(@ptrCast(@alignCast(chunk)));
        }
        platform.memory.free(@ptrCast(@alignCast(self)));
    }
};

pub const Output = union(enum) {
    screen,
    pipe: *Pipe,
    file: *File,
    channel: *Channel, // its writing side
    nul, // NUL: dropped
};

pub const Input = union(enum) {
    none, // not redirected: programs read the keyboard themselves
    pipe: *Pipe,
    file: *File,
    channel: *Channel, // its reading side
    nul, // NUL: redirected, but empty
};

// A task or handle starts using a stream (tasks.spawn), and stops
pub fn retainInput(i: Input) void {
    switch (i) {
        .pipe => |p| p.refs += 1,
        .file => |f| f.refs += 1,
        .channel => |c| c.readers += 1,
        else => {},
    }
}

pub fn releaseInput(i: Input) void {
    switch (i) {
        .pipe => |p| _ = p.release(),
        .file => |f| f.release() catch {},
        .channel => |c| c.closeReader(),
        else => {},
    }
}

pub fn retainOutput(o: Output) void {
    switch (o) {
        .pipe => |p| p.refs += 1,
        .file => |f| f.refs += 1,
        .channel => |c| c.writers += 1,
        else => {},
    }
}

pub fn releaseOutput(o: Output) void {
    switch (o) {
        .pipe => |p| _ = p.release(),
        .file => |f| f.release() catch {},
        .channel => |c| c.closeWriter(),
        else => {},
    }
}

// The running task's standard streams (tasks.World): input,
// output, and the error output (the screen
// even while output is redirected, as on Unix)

pub fn outputIsScreen() bool {
    return tasks.world().output == .screen;
}

pub fn inputRedirected() bool {
    return tasks.world().input != .none;
}

// Text that must reach the screen while output is redirected:
//   const prev = stdio.toScreen(); defer stdio.restore(prev);
pub fn toScreen() Output {
    const w = tasks.world();
    const prev = w.output;
    w.output = .screen;
    return prev;
}

pub fn restore(prev: Output) void {
    tasks.world().output = prev;
}

// Output that isn't for the screen, as the program wrote it:
// line ends are the program's choice (no "\r" added to a "\n")
pub fn write(text: []const u8) void {
    writeTo(tasks.world().output, text);
}

pub fn writeTo(out: Output, text: []const u8) void {
    switch (out) {
        .screen => unreachable, // console.print writes to the screen itself
        .nul => {},
        .pipe => |p| p.write(text),
        .file => |f| {
            if (f.err != null) return;
            flush(f, text);
        },
        .channel => |c| _ = c.write(text) catch |err| {
            // Nobody reads any more: SIGPIPE, as on Unix
            if (err == error.BrokenPipe) tasks.kill(tasks.currentId(), abi.Signal.pipe) catch {};
        },
    }
}

fn flush(f: *File, data: []const u8) void {
    var done: usize = 0;
    while (done < data.len and f.err == null) {
        const w = platform.storage.write(f.handle, data[done..]) catch |err| {
            f.err = err;
            return;
        };
        if (w == 0) {
            f.err = error.DiskFull;
            return;
        }
        done += w;
    }
}

// Standard input into buf; 0 at the end, and always 0 if not redirected
pub fn read(buf: []u8) usize {
    return switch (tasks.world().input) {
        .none, .nul => 0,
        .pipe => |p| p.read(buf),
        .file => |f| platform.storage.read(f.handle, buf) catch |err| {
            if (f.err == null) f.err = err;
            return 0;
        },
        .channel => |c| c.read(buf) catch 0,
    };
}
