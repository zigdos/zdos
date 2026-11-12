// ACPI tables for the metal editions: RSDP from the
// firmware's configuration table, then XSDT or RSDT,
// then a table by signature. Addresses are used as
// is (identity mapping).
const std = @import("std");
const uefi = std.os.uefi;
const ConfigurationTable = uefi.tables.ConfigurationTable;

const sdt_header = 36; // a system description table's header
const max_table = 1 << 20; // no table is this big: a bigger length is garbage

var rsdp: ?[]const u8 = null;

fn bytesAt(addr: usize, len: usize) []const u8 {
    return @as([*]const u8, @ptrFromInt(addr))[0..len];
}

fn readU32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

fn readU64(bytes: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, bytes[off..][0..8], .little);
}

// Every ACPI structure's bytes add up to 0 (mod 256)
fn sumOk(bytes: []const u8) bool {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum == 0;
}

// While the firmware runs: the RSDP it lists, ACPI 2.0 preferred
pub fn capture() void {
    const st = uefi.system_table;
    const tables = st.configuration_table[0..st.number_of_table_entries];
    for ([_]uefi.Guid{ ConfigurationTable.acpi_20_table_guid, ConfigurationTable.acpi_10_table_guid }) |guid| {
        for (tables) |t| {
            if (!t.vendor_guid.eql(guid)) continue;
            if (check(@intFromPtr(t.vendor_table))) |r| {
                rsdp = r;
                return;
            }
        }
    }
}

fn check(addr: usize) ?[]const u8 {
    const head = bytesAt(addr, 20);
    if (!std.mem.eql(u8, head[0..8], "RSD PTR ") or !sumOk(head)) return null;
    if (head[15] < 2) return head; // revision 0: no XSDT
    const size = readU32(bytesAt(addr, 24), 20);
    if (size < sdt_header or size > 256) return null;
    const full = bytesAt(addr, size);
    return if (sumOk(full)) full else null;
}

// The table at a physical address, if its
// length is sane and its checksum is right
fn tableAt(addr: u64) ?[]const u8 {
    if (addr == 0) return null;
    const at: usize = @intCast(addr);
    const size = readU32(bytesAt(at, 8), 4);
    if (size < sdt_header or size > max_table) return null;
    const t = bytesAt(at, size);
    return if (sumOk(t)) t else null;
}

// The first table with this signature ("MCFG", "FACP" ...)
pub fn find(signature: *const [4]u8) ?[]const u8 {
    const r = rsdp orelse return null;
    // The XSDT lists 64-bit addresses, the RSDT 32-bit ones
    const xsdt = if (r.len >= 36) tableAt(readU64(r, 24)) else null;
    const root = xsdt orelse tableAt(readU32(r, 16)) orelse return null;
    const entry: usize = if (xsdt != null) 8 else 4;
    var off: usize = sdt_header;
    while (off + entry <= root.len) : (off += entry) {
        const addr = if (entry == 8) readU64(root, off) else readU32(root, off);
        const t = tableAt(addr) orelse continue;
        if (std.mem.eql(u8, t[0..4], signature)) return t;
    }
    return null;
}

// PCIe configuration space (ECAM) from the MCFG table: each
// allocation's base address, segment and buses, to callback
pub fn ecamRegions(callback: *const fn (base: u64, segment: u16, start_bus: u8, end_bus: u8) void) void {
    const mcfg = find("MCFG") orelse return;
    var off: usize = sdt_header + 8; // 8 reserved bytes after the header
    while (off + 16 <= mcfg.len) : (off += 16) {
        const base = readU64(mcfg, off);
        const segment = std.mem.readInt(u16, mcfg[off + 8 ..][0..2], .little);
        callback(base, segment, mcfg[off + 10], mcfg[off + 11]);
    }
}
