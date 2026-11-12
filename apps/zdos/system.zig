// System functions for shells and system tools, and the disk tools' helpers.
// Ordinary programs need only zdos.zig.
const std = @import("std");
const zdos = @import("zdos.zig");

const Error = zdos.Error;
const DiskLocation = zdos.DiskLocation;
const File = zdos.File;
const DriveInfo = zdos.DriveInfo;
const Time = zdos.Time;

fn api() *const zdos.Api {
    return zdos.table();
}

// REDIRECTION AND PIPES

pub const Stream = enum(u32) {
    input = 0, // read_input
    output = 1, // print
    err = 2, // printError: the screen unless redirected, also while output is
};

// Besides an open file or pipe:
pub const inherited: i32 = -1; // what the program started with
pub const console: i32 = -2; // the keyboard / the screen
pub const nul: i32 = -3; // NUL: nowhere; output is dropped, input is empty

pub fn redirect(stream: Stream, handle: i32) Error!void {
    return zdos.check(api().system.redirect(@intFromEnum(stream), handle));
}

pub fn createPipe() Error!File {
    const h = api().system.create_pipe();
    if (h < 0) return zdos.lastError();
    return .{ .handle = h };
}

// REMOTE CONSOLES (SSHD)

// Read gives what its tasks print, write types keys; a task starts on
// it with taskSpawnWith(.., .{ .term = handle }).
pub fn termCreate(cols: u32, rows: u32) Error!File {
    const h = api().system.term_create(cols, rows);
    if (h < 0) return zdos.lastError();
    return .{ .handle = h };
}

pub fn termResize(t: File, cols: u32, rows: u32) Error!void {
    return zdos.check(api().system.term_resize(t.handle, cols, rows));
}


// Local time (DATE, TIME).
pub fn setTime(time: Time) Error!void {
    return zdos.check(api().time.set(&time));
}

pub fn catchCtrlC(on: bool) void {
    api().system.catch_ctrl_c(on);
}

pub fn ctrlCPressed(clear: bool) bool {
    return api().system.ctrl_c_pressed(clear);
}

// VARIABLE SCOPES (BATCH FILES)

pub fn pushVars() Error!void {
    return zdos.check(api().system.push_vars());
}

pub fn popVars() void {
    api().system.pop_vars();
}

// DRIVES

// "" removes it.
pub fn setLabel(letter: u8, label: []const u8) Error!void {
    return zdos.check(api().drives.set_label(letter, label.ptr, label.len));
}

pub fn driveAt(index: u32) ?DriveInfo {
    var info: DriveInfo = undefined;
    return if (api().drives.at(index, &info)) info else null;
}

pub fn assignLetters() u32 {
    return api().drives.assign_letters();
}

// EJECT: the drive's disk written out and let go.
pub fn eject(letter: u8) Error!void {
    return zdos.check(api().drives.eject(letter));
}

// POWER

pub fn sync() Error!void {
    return error.NotSupported;
}

pub fn shutdown() noreturn {
    api().system.shutdown();
}

pub fn restart() noreturn {
    api().system.restart();
}

// The disk's index, the first sector and the length. NotSupported
// where the platform can't say (UEFI, for now).
pub fn driveLocation(letter: u8) Error!DiskLocation {
    var loc: DiskLocation = undefined;
    try zdos.check(api().drives.location(letter, &loc));
    return loc;
}

// On the boot drive (DriveInfo.boot): "\\EFI\\BOOT\\BOOTX64.EFI" (BIOS:
// "\\ZIGDOS.SYS"); null if the firmware didn't say or it doesn't fit.
pub fn bootFile(buf: []u8) ?[]const u8 {
    const n = api().system.boot_file(buf.ptr, buf.len);
    if (n == 0 or n > buf.len) return null;
    return buf[0..n];
}

// "\\EFI\\ZDOS\\ZIGDOS.EFI" on drive letter, first in
// the boot order (UEFI only).
pub fn addBootEntry(letter: u8, path: []const u8) Error!void {
    return zdos.check(api().system.add_boot_entry(letter, path.ptr, path.len));
}

// RAW DISKS: by index; lba counts sectors of the disk's sector size.
// Writing can destroy the disk the system started from: ask first.

const DiskInfo = zdos.DiskInfo;

pub fn diskCount() u32 {
    return api().disks.count();
}

pub fn diskInfo(index: u32) ?DiskInfo {
    var info: DiskInfo = undefined;
    return if (api().disks.info(index, &info)) info else null;
}

pub fn readSectors(index: u32, lba: u64, buf: []u8) Error!void {
    const count = try sectorCount(index, buf.len);
    return zdos.check(api().disks.read(index, lba, count, buf.ptr));
}

pub fn writeSectors(index: u32, lba: u64, data: []const u8) Error!void {
    const count = try sectorCount(index, data.len);
    return zdos.check(api().disks.write(index, lba, count, data.ptr));
}

// Before writing disk index directly.
pub fn syncDisk(index: u32) Error!void {
    return zdos.check(api().disks.sync(index));
}

fn sectorCount(index: u32, bytes: usize) Error!u32 {
    const info = diskInfo(index) orelse return error.InvalidArgument;
    if (bytes == 0 or bytes % info.sector_size != 0) return error.InvalidArgument;
    return @intCast(bytes / info.sector_size);
}

// PARTITIONS AND FAT BOOT SECTORS: NUMBERED AS CHKDSK LISTS THEM (MBR
// primary, then logical; GPT entry slots; no table: partition 1)

pub const sector = 512;
pub const max_parts = 32;

pub const Kind = enum { fat12, fat16, fat32 };

// start: its boot sector's absolute sector on the disk.
pub const Layout = struct {
    kind: Kind,
    start: u64,
    total: u32,
    spc: u32, // sectors per cluster
    reserved: u32,
    fats: u32,
    fat_sectors: u32,
    root_sectors: u32, // FAT12/16 fixed root directory
    root_cluster: u32, // FAT32
    clusters: u32,
    serial: u32, // volume serial number
};

pub fn rd16(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

pub fn rd32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

// b read from start; null if not FAT.
pub fn parseLayout(start: u64, b: []const u8) ?Layout {
    if (b[510] != 0x55 or b[511] != 0xAA) return null;
    if (rd16(b, 11) != sector) return null;
    const spc = b[13];
    if (spc == 0 or spc & (spc - 1) != 0) return null;
    const reserved = rd16(b, 14);
    const fats: u32 = b[16];
    if (reserved == 0 or fats == 0 or fats > 2) return null;
    const root_entries = rd16(b, 17);
    var total = rd16(b, 19);
    if (total == 0) total = rd32(b, 32);
    var fat_sectors = rd16(b, 22);
    if (fat_sectors == 0) fat_sectors = rd32(b, 36);
    if (fat_sectors == 0) return null;
    const root_sectors = (root_entries * 32 + sector - 1) / sector;
    const data_start = reserved + fats * fat_sectors + root_sectors;
    if (total <= data_start) return null;
    const clusters = (total - data_start) / spc;
    const kind: Kind = if (clusters < 4085) .fat12 else if (clusters < 65525) .fat16 else .fat32;
    const fat32 = kind == .fat32;
    return .{
        .kind = kind,
        .start = start,
        .total = total,
        .spc = spc,
        .reserved = reserved,
        .fats = fats,
        .fat_sectors = fat_sectors,
        .root_sectors = if (fat32) 0 else root_sectors,
        .root_cluster = if (fat32) rd32(b, 44) else 0,
        .clusters = clusters,
        .serial = rd32(b, if (fat32) 67 else 39),
    };
}

pub const max_partitions = 128;

pub const Partition = struct {
    number: u32, // as partitionsOf numbers them
    start: u64,
    sectors: u64,
    esp: bool, // an EFI system partition
    kind: u8, // MBR type; 0 on GPT
    // MBR: the sector holding the entry (MBR or EBR) and its offset:
    entry_lba: u64 = 0,
    entry_off: u16 = 0,
    whole_disk: bool = false, // no partition table: the whole disk, partition 1
};

// GPT type GUIDs, as stored:
pub const gpt_esp = [16]u8{ 0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B };
pub const gpt_basic_data = [16]u8{ 0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44, 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7 }; // EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
pub const gpt_linux = [16]u8{ 0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47, 0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4 }; // 0FC63DAF-8483-4772-8E79-3D69D8477DE4

// Without a partition table: partition 1 (whole_disk). Null if the
// disk or its GPT can't be read.
pub fn partitionsOf(disk: u32, out: *[max_partitions]Partition) ?usize {
    var mbr: [sector]u8 = undefined;
    readSectors(disk, 0, &mbr) catch return null;
    const total: u64 = if (diskInfo(disk)) |d| d.sectors else 0;
    if (!hasTable(&mbr)) {
        out[0] = .{ .number = 1, .start = 0, .sectors = total, .esp = false, .kind = 0, .whole_disk = true };
        return 1;
    }
    for (0..4) |i| {
        if (mbr[446 + 16 * i + 4] == 0xEE) return gptPartitions(disk, out);
    }
    return mbrPartitions(disk, &mbr, out);
}

// "FAT", "NTFS", "exFAT" or null: a disk whose sector 0 is one has no
// partition table, though it ends in 55 AA.
pub fn bootSectorKind(b: *const [sector]u8) ?[]const u8 {
    if (b[510] != 0x55 or b[511] != 0xAA) return null;
    if (parseLayout(0, b) != null) return "FAT";
    if (std.mem.eql(u8, b[3..11], "NTFS    ")) return "NTFS";
    if (std.mem.eql(u8, b[3..11], "EXFAT   ")) return "exFAT";
    return null;
}

// Its signature and no boot sector there (they end in 55 AA too). A
// damaged table still counts, so tools refuse rather than overwrite it.
fn hasTable(b: *const [sector]u8) bool {
    if (b[510] != 0x55 or b[511] != 0xAA) return false;
    return bootSectorKind(b) == null;
}

fn mbrPartitions(disk: u32, mbr: *const [sector]u8, out: *[max_partitions]Partition) usize {
    var n: usize = 0;
    var ext_start: u64 = 0;
    for (0..4) |i| {
        const off = 446 + 16 * i;
        const e = mbr[off..][0..16];
        if (e[4] == 0 or n == max_partitions) continue;
        if ((e[4] == 0x05 or e[4] == 0x0F) and ext_start == 0) ext_start = rd32(e, 8);
        out[n] = .{ .number = @intCast(n + 1), .start = rd32(e, 8), .sectors = rd32(e, 12), .esp = e[4] == 0xEF, .kind = e[4], .entry_off = @intCast(off) };
        n += 1;
    }
    if (ext_start == 0) return n;
    var at: u64 = ext_start;
    var records: u32 = 0;
    while (records < max_partitions and n < max_partitions) : (records += 1) {
        var ebr: [sector]u8 = undefined;
        readSectors(disk, at, &ebr) catch break;
        if (ebr[510] != 0x55 or ebr[511] != 0xAA) break;
        const logical = ebr[446..462];
        if (logical[4] != 0) {
            out[n] = .{ .number = @intCast(n + 1), .start = at + rd32(logical, 8), .sectors = rd32(logical, 12), .esp = logical[4] == 0xEF, .kind = logical[4], .entry_lba = at, .entry_off = 446 };
            n += 1;
        }
        const next = ebr[462..478];
        if (next[4] != 0x05 and next[4] != 0x0F) break;
        at = ext_start + rd32(next, 8);
    }
    return n;
}

// Header at sector 1, numbered by slot.
fn gptPartitions(disk: u32, out: *[max_partitions]Partition) ?usize {
    var hdr: [sector]u8 = undefined;
    readSectors(disk, 1, &hdr) catch return null;
    if (!std.mem.eql(u8, hdr[0..8], "EFI PART")) return null;
    const entries_lba = std.mem.readInt(u64, hdr[72..80], .little);
    const count = std.mem.readInt(u32, hdr[80..84], .little);
    const size = std.mem.readInt(u32, hdr[84..88], .little);
    if (size < 128 or size > sector or sector % size != 0) return null;
    var n: usize = 0;
    var entries: [sector]u8 = undefined;
    var loaded: u64 = std.math.maxInt(u64);
    var slot: u32 = 0;
    while (slot < @min(count, max_partitions)) : (slot += 1) {
        const byte = @as(u64, slot) * size;
        const lba = entries_lba + byte / sector;
        if (lba != loaded) {
            readSectors(disk, lba, &entries) catch return null;
            loaded = lba;
        }
        const e = entries[@intCast(byte % sector)..][0..128];
        if (std.mem.allEqual(u8, e[0..16], 0)) continue;
        const first = std.mem.readInt(u64, e[32..40], .little);
        const last = std.mem.readInt(u64, e[40..48], .little);
        if (last < first) continue;
        out[n] = .{ .number = slot + 1, .start = first, .sectors = last - first + 1, .esp = std.mem.eql(u8, e[0..16], &gpt_esp), .kind = 0 };
        n += 1;
    }
    return n;
}

pub const TypeChange = enum { changed, already, no_table, failed };

// mbr_type on MBR, gpt_type on GPT (each copy entries first, then
// header, so one stays whole).
pub fn setPartitionType(disk: u32, start: u64, mbr_type: u8, gpt_type: *const [16]u8) TypeChange {
    var list: [max_partitions]Partition = undefined;
    const n = partitionsOf(disk, &list) orelse return .failed;
    const p = for (list[0..n]) |p| {
        if (p.start == start) break p;
    } else return .failed;
    if (p.whole_disk) return .no_table;
    if (p.kind == 0) return gptSetType(disk, p.number - 1, gpt_type);
    if (p.kind == mbr_type) return .already;
    var sec: [sector]u8 = undefined;
    readSectors(disk, p.entry_lba, &sec) catch return .failed;
    if (sec[p.entry_off + 4] != p.kind) return .failed; // changed meanwhile
    sec[p.entry_off + 4] = mbr_type;
    writeSectors(disk, p.entry_lba, &sec) catch return .failed;
    return .changed;
}

var gpt_entries: [64 * 1024]u8 align(8) = undefined;

fn gptSetType(disk: u32, slot: u32, gpt_type: *const [16]u8) TypeChange {
    var hdr: [sector]u8 = undefined;
    readSectors(disk, 1, &hdr) catch return .failed;
    if (!std.mem.eql(u8, hdr[0..8], "EFI PART")) return .failed;
    const entries_lba = std.mem.readInt(u64, hdr[72..80], .little);
    const count = std.mem.readInt(u32, hdr[80..84], .little);
    const size = std.mem.readInt(u32, hdr[84..88], .little);
    const bytes = @as(u64, count) * size;
    if (slot >= count or size < 128 or bytes > gpt_entries.len or bytes % sector != 0) return .failed;
    const array = gpt_entries[0..@intCast(bytes)];
    readSectors(disk, entries_lba, array) catch return .failed;
    const type_at = @as(usize, slot) * size;
    if (std.mem.eql(u8, array[type_at..][0..16], gpt_type)) return .already;
    @memcpy(array[type_at..][0..16], gpt_type);
    const entries_crc = std.hash.Crc32.hash(array);

    writeSectors(disk, entries_lba, array) catch return .failed;
    if (!sealGptHeader(disk, 1, &hdr, entries_crc)) return .failed;
    // The backup, at the end of the disk, with its own copy of the entries:
    const alternate = std.mem.readInt(u64, hdr[32..40], .little);
    var backup: [sector]u8 = undefined;
    readSectors(disk, alternate, &backup) catch return .failed;
    if (!std.mem.eql(u8, backup[0..8], "EFI PART")) return .failed;
    const backup_entries = std.mem.readInt(u64, backup[72..80], .little);
    writeSectors(disk, backup_entries, array) catch return .failed;
    if (!sealGptHeader(disk, alternate, &backup, entries_crc)) return .failed;
    return .changed;
}

// Over header_size bytes, its checksum field 0 while computing.
fn sealGptHeader(disk: u32, lba: u64, h: *[sector]u8, entries_crc: u32) bool {
    const header_size = std.mem.readInt(u32, h[12..16], .little);
    if (header_size < 92 or header_size > sector) return false;
    std.mem.writeInt(u32, h[88..92], entries_crc, .little);
    std.mem.writeInt(u32, h[16..20], 0, .little);
    std.mem.writeInt(u32, h[16..20], std.hash.Crc32.hash(h[0..header_size]), .little);
    writeSectors(disk, lba, h) catch return false;
    return true;
}

// "label NN%" at the cursor, changed in place. finish clears it, so
// what is printed next starts where the label was.
pub const Progress = struct {
    start: zdos.Pos,
    label: []const u8,
    total: u64,
    shown: u32 = 101,

    pub fn begin(label: []const u8, total: u64) Progress {
        var p = Progress{ .start = zdos.getCursor(), .label = label, .total = total };
        p.update(0);
        return p;
    }

    pub fn update(self: *Progress, done: u64) void {
        const pct: u32 = if (self.total == 0) 100 else @intCast(@min(@as(u64, 100), done * 100 / self.total));
        if (pct == self.shown) return;
        self.shown = pct;
        zdos.setCursor(self.start.col, self.start.row);
        zdos.printf("{s} {d:>3}%", .{ self.label, pct });
    }

    pub fn finish(self: *Progress) void {
        zdos.setCursor(self.start.col, self.start.row);
        var i: usize = 0;
        while (i < self.label.len + 5) : (i += 1) zdos.print(" ");
        zdos.setCursor(self.start.col, self.start.row);
    }
};

// Sectors counted from the volume's first sector.
pub fn driveSectors(letter: u8) Error!u64 {
    var n: u64 = 0;
    try zdos.check(api().drives.sectors(letter, &n));
    return n;
}

pub fn driveRead(letter: u8, lba: u64, buf: []u8) Error!void {
    return zdos.check(api().drives.read(letter, lba, buf.ptr, buf.len));
}

pub fn driveWrite(letter: u8, lba: u64, data: []const u8) Error!void {
    return zdos.check(api().drives.write(letter, lba, data.ptr, data.len));
}

// Before writing the drive's volume directly.
pub fn syncDrive(letter: u8) Error!void {
    return zdos.check(api().drives.sync(letter));
}

pub fn driveChanged(letter: u8) void {
    _ = api().drives.changed(letter);
}

// The disk's volumes are read again, so the mounted drives don't use
// what was there before.
pub fn diskChanged(index: u32) void {
    _ = api().disks.changed(index);
}

// The question is already printed; Enter ends the answer, so a stray
// key changes nothing. True for Y or Yes.
pub fn askYes() bool {
    var buf: [8]u8 = undefined;
    var n: usize = 0;
    while (true) {
        const key = zdos.readKey();
        if (key.char == '\r' or key.char == '\n') break;
        if (key.char == 0x08) {
            if (n > 0) {
                n -= 1;
                zdos.print("\x08 \x08");
            }
            continue;
        }
        if (key.char < 0x20 or key.char > 0x7E) continue;
        if (n < buf.len) {
            buf[n] = @intCast(key.char);
            n += 1;
            zdos.print(buf[n - 1 .. n]);
        }
    }
    zdos.print("\n");
    const answer = buf[0..n];
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

// CORES: for the program's own computing; a job calls no ZDOS function

pub const CoreJob = zdos.CoreJob;

// Core 0 (the program's) included; 1 where there are no others.
pub fn coreCount() u32 {
    return api().cores.count();
}

// n: 1..coreCount()-1; AccessDenied while it still runs one.
pub fn coreStart(n: u32, job: CoreJob, arg: ?*anyopaque) Error!void {
    return zdos.check(api().cores.start(n, job, arg));
}

pub fn coreBusy(n: u32) bool {
    return api().cores.busy(n);
}

pub fn coreWait(n: u32) void {
    api().cores.wait(n);
}

// TASKS: metal only, elsewhere taskSpawn gives NotSupported

pub const TaskInfo = zdos.TaskInfo;
pub const TaskState = zdos.TaskState;

// Found as exec finds it; its id.
pub fn taskSpawn(path: []const u8, args: []const u8) Error!u32 {
    const id = api().tasks.spawn(path.ptr, path.len, args.ptr, args.len);
    if (id < 0) return zdos.lastError();
    return @intCast(id);
}

// One this task started; its exit code.
pub fn taskWait(id: u32) Error!u8 {
    const code = api().tasks.wait(id);
    if (code < 0) return zdos.lastError();
    return @intCast(code);
}

// Null while it runs.
pub fn taskEnded(id: u32) ?u8 {
    var code: u8 = 0;
    return if (api().tasks.ended(id, &code)) code else null;
}

pub fn taskId() u32 {
    return api().tasks.id();
}

pub fn taskYield() void {
    api().tasks.yield();
}

pub fn taskSetPriority(id: u32, priority: u32) Error!void {
    return zdos.check(api().tasks.set_priority(id, priority));
}

// abi.Policy: fifo, rr.
pub fn taskSetPolicy(id: u32, policy: u32) Error!void {
    return zdos.check(api().tasks.set_policy(id, policy));
}

// Policy 6: runtime ns each period, done by deadline ns after its
// start (period 0: = deadline).
pub fn taskSetDeadline(id: u32, runtime: u64, deadline: u64, period: u64) Error!void {
    return zdos.check(api().tasks.set_deadline(id, runtime, deadline, period));
}

pub const Deadline = @import("abi").DeadlineSetting;

// Null: not a deadline task.
pub fn taskDeadline(id: u32) ?Deadline {
    var d: Deadline = undefined;
    return if (api().tasks.deadline(id, &d)) d else null;
}

// Null for an unknown task.
pub fn taskPolicy(id: u32) ?u32 {
    const p = api().tasks.policy(id);
    return if (p < 0) null else @intCast(p);
}

// Bit n: core n; all ones: any.
pub fn taskSetAffinity(id: u32, mask: u64) Error!void {
    return zdos.check(api().cores.set_affinity(id, mask));
}

// Null for an unknown task.
pub fn taskAffinity(id: u32) ?u64 {
    const m = api().cores.affinity(id);
    return if (m == 0) null else m;
}

pub fn taskPriority(id: u32) ?u32 {
    const p = api().tasks.priority(id);
    return if (p < 0) null else @intCast(p);
}

// Null past the last.
pub fn taskInfo(index: u32) ?TaskInfo {
    var info: TaskInfo = undefined;
    return if (api().tasks.info(index, &info)) info else null;
}

// Its holder inherits the priority of the tasks waiting for it.
pub const Mutex = struct {
    number: i32,

    pub fn create() Error!Mutex {
        const n = api().tasks.mutex_create();
        if (n < 0) return zdos.lastError();
        return .{ .number = n };
    }

    pub fn lock(self: Mutex) Error!void {
        return zdos.check(api().tasks.mutex_lock(self.number));
    }

    pub fn unlock(self: Mutex) Error!void {
        return zdos.check(api().tasks.mutex_unlock(self.number));
    }

    pub fn destroy(self: Mutex) void {
        api().tasks.mutex_destroy(self.number);
    }

    // WouldBlock if another task holds it.
    pub fn tryLock(self: Mutex) Error!void {
        return zdos.check(api().tasks.mutex_try_lock(self.number));
    }
};

pub const SpawnOptions = zdos.SpawnOptions;
pub const TaskEnd = zdos.TaskEnd;

// Handles, or SpawnOptions.same_stream ..., and a priority.
pub fn taskSpawnWith(path: []const u8, args: []const u8, options: SpawnOptions) Error!u32 {
    const id = api().tasks.spawn_ex(path.ptr, path.len, args.ptr, args.len, &options);
    if (id < 0) return zdos.lastError();
    return @intCast(id);
}

// Variables of its own instead of the global ones: env holds
// "NAME=value" entries, each ended by a 0 byte.
pub fn taskSpawnEnv(path: []const u8, args: []const u8, options: SpawnOptions, env: []const u8) Error!u32 {
    const id = api().tasks.spawn_env(path.ptr, path.len, args.ptr, args.len, &options, env.ptr, env.len);
    if (id < 0) return zdos.lastError();
    return @intCast(id);
}

// An empty path fails where it exists.
pub fn spawnEnvWorks() bool {
    _ = api().tasks.spawn_env("", 0, "", 0, null, "", 0);
    return zdos.lastErrorCode() != .not_supported;
}

// Null if none has yet and hang is false; NoChild if there is none.
pub fn taskWaitAny(hang: bool) Error!?TaskEnd {
    var e: TaskEnd = .{};
    const id = api().tasks.wait_any(if (hang) 0 else zdos.WaitFlags.no_hang, &e);
    if (id < 0) return zdos.lastError();
    return if (id == 0) null else e;
}

pub fn taskParent() u32 {
    return api().tasks.parent();
}

// Since startup: all milliseconds, and those no task ran in.
pub fn cpuTimes() zdos.CpuTimes {
    var t: zdos.CpuTimes = .{ .total_ms = 0, .idle_ms = 0 };
    api().tasks.times(&t);
    return t;
}

// THREADS: functions of the program as tasks of their own (metal)

pub const ThreadEntry = zdos.ThreadEntry;

// stack_size 0: 256 KiB (threads.default_stack_size); priority null: the caller's.
pub fn threadCreate(entry: ThreadEntry, arg: ?*anyopaque, stack_size: usize, priority: ?u32) Error!u32 {
    const id = api().threads.create(entry, arg, stack_size, if (priority) |p| @intCast(p) else -1);
    if (id < 0) return zdos.lastError();
    return @intCast(id);
}

// What the thread's entry returned.
pub fn threadJoin(id: u32) Error!usize {
    var r: usize = 0;
    try zdos.check(api().threads.join(id, &r));
    return r;
}

pub fn threadDetach(id: u32) Error!void {
    return zdos.check(api().threads.detach(id));
}

pub fn threadExit(result: usize) noreturn {
    api().threads.exit(result);
}

// Waits while word is expected, until futexWake, timeout_ms (TimedOut) or
// a signal (Interrupted); WouldBlock if it isn't. May return spuriously:
// check the word.
pub fn futexWait(word: *const u32, expected: u32, timeout_ms: ?u32) Error!void {
    const code = api().threads.futex_wait(word, expected, if (timeout_ms) |t| @intCast(@min(t, std.math.maxInt(i32))) else -1, 0xFFFF_FFFF);
    if (code != .none) return zdos.errorOf(code);
}

// How many it woke.
pub fn futexWake(word: *const u32, count: u32) Error!u32 {
    const n = api().threads.futex_wake(word, count, 0xFFFF_FFFF);
    if (n < 0) return zdos.lastError();
    return @intCast(n);
}

// Used with a Mutex.
pub const Cond = struct {
    number: i32,

    pub fn create() Error!Cond {
        const n = api().threads.cond_create();
        if (n < 0) return zdos.lastError();
        return .{ .number = n };
    }

    // Lets m go, waits for signal / broadcast (or TimedOut), takes m again.
    // May end early: check what was waited for.
    pub fn wait(self: Cond, m: Mutex, timeout_ms: ?u32) Error!void {
        return zdos.check(api().threads.cond_wait(self.number, m.number, if (timeout_ms) |t| @intCast(t) else -1));
    }

    pub fn signal(self: Cond) void {
        api().threads.cond_signal(self.number);
    }

    pub fn broadcast(self: Cond) void {
        api().threads.cond_broadcast(self.number);
    }

    pub fn destroy(self: Cond) void {
        api().threads.cond_destroy(self.number);
    }
};

pub const Semaphore = struct {
    number: i32,

    pub fn create(initial: u32) Error!Semaphore {
        const n = api().threads.sem_create(initial);
        if (n < 0) return zdos.lastError();
        return .{ .number = n };
    }

    // null: no limit; 0: WouldBlock at once.
    pub fn wait(self: Semaphore, timeout_ms: ?u32) Error!void {
        return zdos.check(api().threads.sem_wait(self.number, if (timeout_ms) |t| @intCast(t) else -1));
    }

    pub fn post(self: Semaphore) Error!void {
        return zdos.check(api().threads.sem_post(self.number));
    }

    pub fn value(self: Semaphore) ?u32 {
        const v = api().threads.sem_value(self.number);
        return if (v < 0) null else @intCast(v);
    }

    pub fn destroy(self: Semaphore) void {
        api().threads.sem_destroy(self.number);
    }
};

// SIGNALS: POSIX signals between tasks (metal)

pub const Signal = zdos.Signal;

pub fn signalSend(task: u32, sig: u32) Error!void {
    return zdos.check(api().signals.send(task, sig));
}

// Between tasks.
pub fn pipe() Error!struct { read: i32, write: i32 } {
    var h: [2]i32 = undefined;
    try zdos.check(api().files.pipe(&h));
    return .{ .read = h[0], .write = h[1] };
}

// KEYBOARD LAYOUTS

pub fn keybCount() u32 {
    return api().keyb.count();
}

// Two letters; null past the last one.
pub fn keybName(index: u32, buf: []u8) ?[]const u8 {
    const n = api().keyb.name(index, buf.ptr, buf.len);
    if (n == 0) return null;
    return buf[0..@min(n, buf.len)];
}

pub fn keybActive() u32 {
    return api().keyb.active();
}

// It must be one of the loaded ones.
pub fn keybSetActive(index: u32) Error!void {
    return zdos.check(api().keyb.set_active(index));
}

// Comma separated (EN,ES,FR).
pub fn keybLoaded(buf: []u8) Error![]const u8 {
    const n = api().keyb.loaded(buf.ptr, buf.len);
    if (n == 0) {
        if (zdos.lastErrorCode() != .none) return zdos.lastError();
        return buf[0..0];
    }
    return buf[0..n];
}

// "EN,ES,FR"; unknown names fail with InvalidArgument.
pub fn keybSetLoaded(list: []const u8) Error!void {
    return zdos.check(api().keyb.set_loaded(list.ptr, list.len));
}
