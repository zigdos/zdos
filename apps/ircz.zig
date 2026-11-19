// IRCZ [-k] [-p] [-n NICK] [-u USER] [-w PASSWORD] SERVER[:PORT] [#CHAN ...]
// Tabs: Alt+1..9, Alt+0, Ctrl+N, Ctrl+P or /win N; /help lists the commands.
const std = @import("std");
const zdos = @import("zdos/zdos.zig");
const net = @import("zdos/net.zig");
const Tls = @import("zdos/zcrypt.zig").Tls; // ZCRYPT.ZDL

comptime {
    _ = zdos;
}

pub const zdos_file_version = [4]u8{ 0, 8, 1, 0 };

const Color = zdos.Color;

// LIMITS
const max_tabs = 24;
const ring_len = 256; // lines kept per tab
const slot_cap = 768;
const max_cells = 640;
const nick_cap = 40;
const max_nicks = 4096;
const input_cap = 1000;
const hist_len = 32;
const indent = 6; // wrapped rows start under the text, after the time
const version_reply = "IRCZ for ZDOS";
const quit_message = "IRCZ for ZDOS";

// COLOURS
const C = struct {
    const time = Color.dark_gray;
    const text = Color.light_gray;
    const own = Color.white;
    const mention = Color.yellow;
    const info = Color.light_gray;
    const join = Color.light_green;
    const part = Color.brown;
    const quit = Color.red;
    const kick = Color.magenta;
    const nick = Color.light_blue;
    const notice = Color.light_magenta;
    const err = Color.light_red;
    const numeric = Color.green;
    const topic = Color.light_cyan;
    const mode = Color.cyan;
    const bar = Color.blue;
};

const nick_colors = [_]Color{
    .light_green, .light_cyan, .light_magenta, .yellow, .light_blue,
    .green,       .cyan,       .magenta,       .brown,  .light_red,
};

fn Text(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = undefined,
        len: usize = 0,

        fn get(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }

        fn set(self: *@This(), s: []const u8) void {
            const n = utf8Cut(s, cap);
            std.mem.copyForwards(u8, self.buf[0..n], s[0..n]);
            self.len = n;
        }
    };
}

// The longest start of s up to max bytes that ends on a character.
pub fn utf8Cut(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var n = max;
    while (n > 0 and s[n] & 0xC0 == 0x80) n -= 1;
    return n;
}

// Where to cut s for a message of at most max bytes: at a space
// in its second half if there is one.
pub fn splitPoint(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    const cut = @max(utf8Cut(s, max), 1);
    if (std.mem.lastIndexOfScalar(u8, s[0..cut], ' ')) |sp| {
        if (sp >= max / 2) return sp;
    }
    return cut;
}

fn fmtBuf(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    fbs.writer().print(fmt, args) catch {};
    return fbs.getWritten();
}

// OPTIONS
var host: []const u8 = "";
var port: u16 = 0;
var use_tls = true;
var verify = true;
var password: ?[]const u8 = null;
var autojoin: [16][]const u8 = undefined;
var autojoin_count: usize = 0;
var user_name: Text(nick_cap) = .{};

fn usage() u8 {
    zdos.print(
        \\IRCZ [-k] [-p] [-n NICK] [-u USER] [-w PASSWORD] SERVER[:PORT] [#CHAN ...]
        \\  TLS on port 6697; -p or port 6667: plain text
        \\  -k  don't check the certificate against CACERT.PEM
        \\  -w  password for SASL PLAIN (account NICK) and PASS
        \\
    );
    return 1;
}

fn envVar(name: []const u8, buf: []u8) ?[]const u8 {
    const v = zdos.getVar(name, buf) orelse return null;
    return if (v.len > 0) v else null;
}

fn parseArgs(args: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, args, " \t");
    var nick_opt: ?[]const u8 = null;
    var user_opt: ?[]const u8 = null;
    var server: ?[]const u8 = null;
    while (words.next()) |w| {
        if (std.mem.eql(u8, w, "-k")) {
            verify = false;
        } else if (std.mem.eql(u8, w, "-p")) {
            use_tls = false;
        } else if (std.mem.eql(u8, w, "-n")) {
            nick_opt = words.next() orelse return false;
        } else if (std.mem.eql(u8, w, "-u")) {
            user_opt = words.next() orelse return false;
        } else if (std.mem.eql(u8, w, "-w")) {
            password = words.next() orelse return false;
        } else if (w[0] == '-') {
            return false;
        } else if (server == null) {
            server = w;
        } else {
            if (autojoin_count == autojoin.len) return false;
            autojoin[autojoin_count] = w;
            autojoin_count += 1;
        }
    }
    const s = server orelse return false;
    host = s;
    port = if (use_tls) 6697 else 6667;
    if (std.mem.lastIndexOfScalar(u8, s, ':')) |c| {
        host = s[0..c];
        port = std.fmt.parseInt(u16, s[c + 1 ..], 10) catch return false;
        if (port == 6667) use_tls = false;
    }
    if (host.len == 0) return false;
    var vb: [64]u8 = undefined;
    const n = nick_opt orelse envVar("USER", &vb) orelse
        envVar("USERNAME", &vb) orelse "zdosuser";
    me.set(n);
    base_nick.set(n);
    user_name.set(user_opt orelse n);
    return true;
}

// PARSER
pub const Msg = struct {
    prefix: []const u8 = "",
    command: []const u8 = "",
    params: [15][]const u8 = undefined,
    count: usize = 0,

    pub fn nick(self: *const Msg) []const u8 {
        const e = std.mem.indexOfAny(u8, self.prefix, "!@") orelse
            self.prefix.len;
        return self.prefix[0..e];
    }

    pub fn arg(self: *const Msg, i: usize) []const u8 {
        return if (i < self.count) self.params[i] else "";
    }

    fn last(self: *const Msg) []const u8 {
        return if (self.count > 0) self.params[self.count - 1] else "";
    }

    fn is(self: *const Msg, name: []const u8) bool {
        return std.ascii.eqlIgnoreCase(self.command, name);
    }
};

// [@tags] [:prefix] COMMAND params [:trailing]
pub fn parse(text: []const u8) ?Msg {
    var line = text;
    var m: Msg = .{};
    if (line.len > 0 and line[0] == '@') {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
        line = line[sp + 1 ..];
    }
    line = std.mem.trimLeft(u8, line, " ");
    if (line.len > 0 and line[0] == ':') {
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
        m.prefix = line[1..sp];
        line = std.mem.trimLeft(u8, line[sp + 1 ..], " ");
    }
    const e = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
    m.command = line[0..e];
    if (m.command.len == 0) return null;
    line = line[e..];
    while (m.count < m.params.len) {
        line = std.mem.trimLeft(u8, line, " ");
        if (line.len == 0) break;
        if (line[0] == ':' or m.count == m.params.len - 1) {
            m.params[m.count] = if (line[0] == ':') line[1..] else line;
            m.count += 1;
            break;
        }
        const end = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        m.params[m.count] = line[0..end];
        m.count += 1;
        line = line[end..];
    }
    return m;
}

// RFC 1459 case mapping:
fn ircLower(c: u8) u8 {
    return switch (c) {
        'A'...'Z' => c + 32,
        '[' => '{',
        ']' => '}',
        '\\' => '|',
        '^' => '~',
        else => c,
    };
}

pub fn sameName(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (ircLower(x) != ircLower(y)) return false;
    }
    return true;
}

fn nickChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or
        std.mem.indexOfScalar(u8, "-_[]{}\\`^|", c) != null;
}

// The nick as a word of text.
pub fn mentions(text: []const u8, nick: []const u8) bool {
    if (nick.len == 0 or text.len < nick.len) return false;
    var i: usize = 0;
    while (i + nick.len <= text.len) : (i += 1) {
        if (!sameName(text[i..][0..nick.len], nick)) continue;
        const after = i + nick.len;
        if (i > 0 and nickChar(text[i - 1])) continue;
        if (after < text.len and nickChar(text[after])) continue;
        return true;
    }
    return false;
}

// FORMATTING
// A stored line: UTF-8 text without control bytes; ESC fg bg
// changes the colours of what follows.
pub const LineBuf = struct {
    buf: [slot_cap]u8 = undefined,
    len: usize = 0,
    fg: u8 = 0xFF,
    bg: u8 = 0xFF,
    full: bool = false,

    pub fn style(self: *LineBuf, fg: Color, bg: Color) void {
        const f = @intFromEnum(fg);
        const b = @intFromEnum(bg);
        if (f == self.fg and b == self.bg) return;
        if (self.len + 3 + 4 > self.buf.len) {
            self.full = true;
            return;
        }
        self.buf[self.len..][0..3].* = .{ 0x1B, f, b };
        self.len += 3;
        self.fg = f;
        self.bg = b;
    }

    fn put(self: *LineBuf, bytes: []const u8) void {
        if (self.full or self.len + bytes.len > self.buf.len) {
            self.full = true;
            return;
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    // Control characters are dropped, bytes that aren't UTF-8
    // are taken as Latin-1:
    pub fn text(self: *LineBuf, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len and !self.full) {
            const c = s[i];
            if (c < 0x80) {
                i += 1;
                if (c == '\t') self.put(" ") else if (c >= 0x20 and c != 0x7F) self.put(&.{c});
                continue;
            }
            const n = std.unicode.utf8ByteSequenceLength(c) catch 0;
            if (n > 1 and i + n <= s.len and std.unicode.utf8ValidateSlice(s[i..][0..n])) {
                // C1 controls (U+0080..U+009F) go too:
                if (!(n == 2 and c == 0xC2 and s[i + 1] < 0xA0)) self.put(s[i..][0..n]);
                i += n;
            } else {
                if (c >= 0xA0) self.put(&.{ 0xC0 | (c >> 6), 0x80 | (c & 0x3F) });
                i += 1;
            }
        }
    }

    // mIRC formatting: colours, bold, reverse and reset; the
    // other codes are dropped.
    pub fn irc(self: *LineBuf, s: []const u8, base: Color) void {
        var st: Mirc = .{};
        var i: usize = 0;
        while (i < s.len and !self.full) {
            switch (s[i]) {
                0x02 => {
                    st.bold = !st.bold;
                    i += 1;
                },
                0x0F => {
                    st = .{};
                    i += 1;
                },
                0x16 => {
                    st.reverse = !st.reverse;
                    i += 1;
                },
                0x03 => i = st.color(s, i + 1),
                0x04 => i = skipHex(s, i + 1),
                else => {
                    var e = i;
                    while (e < s.len and !isFormat(s[e])) e += 1;
                    const fb = st.colors(base);
                    self.style(fb[0], fb[1]);
                    self.text(s[i..e]);
                    i = e;
                },
            }
        }
    }
};

fn isFormat(c: u8) bool {
    return c == 0x02 or c == 0x03 or c == 0x04 or c == 0x0F or c == 0x16;
}

const Mirc = struct {
    fg: ?u8 = null,
    bg: ?u8 = null,
    bold: bool = false,
    reverse: bool = false,

    // After ^C: fg[,bg], nothing resets both:
    fn color(self: *Mirc, s: []const u8, start: usize) usize {
        var i = start;
        const f = digits(s, &i) orelse {
            self.fg = null;
            self.bg = null;
            return i;
        };
        self.fg = if (f == 99) null else f;
        if (i + 1 < s.len and s[i] == ',' and std.ascii.isDigit(s[i + 1])) {
            i += 1;
            const b = digits(s, &i).?;
            self.bg = if (b == 99) null else b;
        }
        return i;
    }

    fn colors(self: *const Mirc, base: Color) [2]Color {
        var f: u8 = @intFromEnum(base);
        var b: u8 = 0;
        if (self.fg) |x| f = mircColor(x) orelse f;
        if (self.bg) |x| b = mircColor(x) orelse 0;
        if (self.bold and f < 8) f += 8;
        if (self.reverse) std.mem.swap(u8, &f, &b);
        return .{ @enumFromInt(f), @enumFromInt(b) };
    }
};

fn digits(s: []const u8, i: *usize) ?u8 {
    var n: u8 = 0;
    var k: usize = 0;
    while (k < 2 and i.* < s.len and std.ascii.isDigit(s[i.*])) : (k += 1) {
        n = n * 10 + (s[i.*] - '0');
        i.* += 1;
    }
    return if (k == 0) null else n;
}

// ^D RRGGBB[,RRGGBB]:
fn skipHex(s: []const u8, start: usize) usize {
    var i = start;
    var k: usize = 0;
    while (k < 6 and i < s.len and std.ascii.isHex(s[i])) : (k += 1) i += 1;
    if (k > 0 and i + 1 < s.len and s[i] == ',' and std.ascii.isHex(s[i + 1])) {
        i += 1;
        k = 0;
        while (k < 6 and i < s.len and std.ascii.isHex(s[i])) : (k += 1) i += 1;
    }
    return i;
}

// mIRC's colour numbers as ZDOS colours (16..98 roughly):
pub fn mircColor(n: u8) ?u8 {
    const basic = [16]u8{ 15, 0, 1, 2, 12, 4, 5, 6, 14, 10, 3, 11, 9, 13, 8, 7 };
    const dark = [12]u8{ 4, 6, 6, 2, 2, 2, 3, 1, 1, 5, 5, 4 };
    const light = [12]u8{ 12, 14, 14, 10, 10, 10, 11, 9, 9, 13, 13, 12 };
    if (n < 16) return basic[n];
    if (n < 88) {
        const row = (n - 16) / 12;
        return if (row < 2) dark[(n - 16) % 12] else light[(n - 16) % 12];
    }
    if (n < 99) return if (n < 91) 0 else if (n < 95) 8 else 7;
    return null;
}

pub const Cell = struct {
    ch: u21 = ' ',
    fg: u4 = 7,
    bg: u4 = 0,
};

// A stored line as screen cells; how many.
pub fn expand(line: []const u8, out: []Cell) usize {
    var fg: u4 = 7;
    var bg: u4 = 0;
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < out.len) {
        if (line[i] == 0x1B) {
            if (i + 2 >= line.len) break;
            fg = @truncate(line[i + 1]);
            bg = @truncate(line[i + 2]);
            i += 3;
            continue;
        }
        const l: usize = std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
        const cp: u21 = if (i + l <= line.len)
            std.unicode.utf8Decode(line[i..][0..l]) catch '?'
        else
            '?';
        out[n] = .{ .ch = cp, .fg = fg, .bg = bg };
        n += 1;
        i += l;
    }
    return n;
}

// The rows of cells at width (continued rows indented), cut at
// spaces where it can; how many rows.
pub fn wrap(cells: []const Cell, width: usize, rows_out: [][2]usize) usize {
    const ind: usize = if (width > indent + 10) indent else 0;
    var n: usize = 0;
    var i: usize = 0;
    while (n < rows_out.len) {
        const avail = if (n == 0) width else width - ind;
        if (cells.len - i <= avail) {
            rows_out[n] = .{ i, cells.len };
            return n + 1;
        }
        var end = i + avail;
        var j = end;
        while (j > i + avail / 3) : (j -= 1) {
            if (cells[j].ch == ' ') {
                end = j;
                break;
            }
        }
        rows_out[n] = .{ i, end };
        n += 1;
        i = if (end < cells.len and cells[end].ch == ' ') end + 1 else end;
    }
    return n;
}

// TABS
const Kind = enum { server, channel, query };
const Unread = enum(u8) { none, msg, mention };

const Nick = struct {
    name: [nick_cap]u8 = undefined,
    len: u8 = 0,
    mode: u8 = 0, // its highest prefix ('@', '+'), or 0

    fn get(self: *const Nick) []const u8 {
        return self.name[0..self.len];
    }
};

const Slot = struct {
    len: u16,
    data: [slot_cap]u8,
};

const Ring = struct {
    slots: [ring_len]Slot,
    head: usize, // where the next line goes
    count: usize,

    fn at(self: *const Ring, i: usize) []const u8 {
        const s = &self.slots[(self.head + ring_len - self.count + i) % ring_len];
        return s.data[0..s.len];
    }
};

const Tab = struct {
    kind: Kind,
    name: Text(64) = .{},
    topic: Text(400) = .{},
    ring: ?*Ring = null,
    nicks: std.ArrayListUnmanaged(Nick) = .empty,
    joined: bool = false,
    names_open: bool = false, // a NAMES reply is coming in
    unread: Unread = .none,
    scroll: usize = 0, // rows up from the newest
};

var tabs: [max_tabs]Tab = undefined;
var tab_count: usize = 0;
var active: usize = 0;

fn findTab(name: []const u8) ?usize {
    for (1..tab_count) |i| {
        if (sameName(tabs[i].name.get(), name)) return i;
    }
    return null;
}

fn openTab(kind: Kind, name: []const u8) ?usize {
    if (findTab(name)) |i| return i;
    if (tab_count == max_tabs) return null;
    const i = tab_count;
    tabs[i] = .{ .kind = kind };
    tabs[i].name.set(name);
    tabs[i].ring = zdos.allocator.create(Ring) catch null;
    if (tabs[i].ring) |r| {
        r.head = 0;
        r.count = 0;
    }
    tab_count += 1;
    dirty = true;
    return i;
}

fn closeTab(i: usize) void {
    if (i == 0 or i >= tab_count) return;
    if (tabs[i].ring) |r| zdos.allocator.destroy(r);
    tabs[i].nicks.deinit(zdos.allocator);
    std.mem.copyForwards(Tab, tabs[i .. tab_count - 1], tabs[i + 1 .. tab_count]);
    tab_count -= 1;
    if (active >= i) active -= 1;
    tabs[active].unread = .none;
    dirty = true;
}

fn setActive(i: usize) void {
    if (i >= tab_count) return;
    active = i;
    tabs[i].unread = .none;
    dirty = true;
}

fn isChannel(name: []const u8) bool {
    return name.len > 0 and std.mem.indexOfScalar(u8, chantypes.get(), name[0]) != null;
}

// A channel target with STATUSMSG's prefix (@#chan) as the channel:
fn chanTarget(name: []const u8) []const u8 {
    var s = name;
    while (s.len > 1 and std.mem.indexOfScalar(u8, prefix_syms.get(), s[0]) != null) s = s[1..];
    return if (isChannel(s)) s else name;
}

fn rowsOf(line: []const u8) usize {
    var cells: [max_cells]Cell = undefined;
    var spans: [64][2]usize = undefined;
    return wrap(cells[0..expand(line, &cells)], @max(cols, 1), &spans);
}

fn addLine(ti: usize, l: *const LineBuf, level: Unread) void {
    const t = &tabs[ti];
    const line = l.buf[0..l.len];
    if (t.ring) |r| {
        const s = &r.slots[r.head];
        s.len = @intCast(line.len);
        @memcpy(s.data[0..line.len], line);
        r.head = (r.head + 1) % ring_len;
        if (r.count < ring_len) r.count += 1;
    }
    // A scrolled view stays where it is:
    if (t.scroll > 0) t.scroll += rowsOf(line);
    if (ti != active and @intFromEnum(level) > @intFromEnum(t.unread)) t.unread = level;
    dirty = true;
}

fn begin() LineBuf {
    var l: LineBuf = .{};
    const t = zdos.getTime();
    var b: [8]u8 = undefined;
    l.style(C.time, .black);
    l.text(fmtBuf(&b, "{d:0>2}:{d:0>2} ", .{ t.hour, t.minute }));
    return l;
}

// head in colour, then rest with its mIRC formatting:
fn note(ti: usize, color: Color, head: []const u8, rest: []const u8) void {
    var l = begin();
    l.style(color, .black);
    l.text(head);
    l.irc(rest, color);
    addLine(ti, &l, .none);
}

fn notef(ti: usize, color: Color, comptime fmt: []const u8, args: anytype) void {
    var b: [600]u8 = undefined;
    note(ti, color, fmtBuf(&b, fmt, args), "");
}

fn nickColor(name: []const u8) Color {
    if (sameName(name, me.get())) return C.own;
    var h: u32 = 2166136261;
    for (name) |c| h = (h ^ ircLower(c)) *% 16777619;
    return nick_colors[h % nick_colors.len];
}

const How = enum { msg, action, notice };

fn showMsg(ti: usize, from: []const u8, mode: u8, text: []const u8, how: How) void {
    const own = sameName(from, me.get());
    const ment = !own and mentions(text, me.get());
    const base = if (own) C.own else if (ment) C.mention else C.text;
    const nc = nickColor(from);
    var l = begin();
    switch (how) {
        .msg => {
            l.style(.dark_gray, .black);
            l.text("<");
            l.style(nc, .black);
            if (mode != 0) l.text(&.{mode});
            l.text(from);
            l.style(.dark_gray, .black);
            l.text("> ");
        },
        .action => {
            l.style(.white, .black);
            l.text("* ");
            l.style(nc, .black);
            l.text(from);
            l.text(" ");
        },
        .notice => {
            l.style(C.notice, .black);
            l.text("-");
            l.text(from);
            l.text("- ");
        },
    }
    l.irc(text, base);
    const level: Unread = if (own) .none else if (ment or tabs[ti].kind == .query) .mention else .msg;
    addLine(ti, &l, level);
}

// NICK LISTS
var prefix_modes: Text(16) = .{};
var prefix_syms: Text(16) = .{};
var chantypes: Text(16) = .{};
var chanmodes: Text(64) = .{}; // A,B,C,D as ISUPPORT says

fn nickIndex(ti: usize, name: []const u8) ?usize {
    for (tabs[ti].nicks.items, 0..) |*n, i| {
        if (sameName(n.get(), name)) return i;
    }
    return null;
}

fn addNick(ti: usize, name: []const u8, mode: u8) void {
    if (name.len == 0) return;
    if (nickIndex(ti, name)) |i| {
        tabs[ti].nicks.items[i].mode = mode;
        return;
    }
    if (tabs[ti].nicks.items.len >= max_nicks) return;
    var n: Nick = .{ .mode = mode };
    const len = @min(name.len, nick_cap);
    @memcpy(n.name[0..len], name[0..len]);
    n.len = @intCast(len);
    tabs[ti].nicks.append(zdos.allocator, n) catch {};
}

fn removeNick(ti: usize, name: []const u8) bool {
    const i = nickIndex(ti, name) orelse return false;
    _ = tabs[ti].nicks.orderedRemove(i);
    return true;
}

fn renameNick(ti: usize, old: []const u8, new: []const u8) bool {
    const i = nickIndex(ti, old) orelse return false;
    const n = &tabs[ti].nicks.items[i];
    const len = @min(new.len, nick_cap);
    @memcpy(n.name[0..len], new[0..len]);
    n.len = @intCast(len);
    return true;
}

fn modeOf(ti: usize, name: []const u8) u8 {
    if (tabs[ti].kind != .channel) return 0;
    const i = nickIndex(ti, name) orelse return 0;
    return tabs[ti].nicks.items[i].mode;
}

fn rank(sym: u8) usize {
    if (sym == 0) return 99;
    return std.mem.indexOfScalar(u8, prefix_syms.get(), sym) orelse 98;
}

fn nickLess(_: void, a: Nick, b: Nick) bool {
    const ra = rank(a.mode);
    const rb = rank(b.mode);
    if (ra != rb) return ra < rb;
    const x = a.get();
    const y = b.get();
    for (0..@min(x.len, y.len)) |i| {
        const p = ircLower(x[i]);
        const q = ircLower(y[i]);
        if (p != q) return p < q;
    }
    return x.len < y.len;
}

fn showNames(ti: usize) void {
    const t = &tabs[ti];
    std.mem.sort(Nick, t.nicks.items, {}, nickLess);
    notef(ti, C.info, "Users on {s} ({d}):", .{ t.name.get(), t.nicks.items.len });
    var l = begin();
    for (t.nicks.items) |*n| {
        if (l.len > 560) {
            addLine(ti, &l, .none);
            l = begin();
        }
        l.style(.dark_gray, .black);
        l.text(if (n.mode != 0) &.{n.mode} else " ");
        l.style(nickColor(n.get()), .black);
        l.text(n.get());
        l.text(" ");
    }
    if (t.nicks.items.len > 0) addLine(ti, &l, .none);
}

// ISUPPORT's PREFIX, CHANTYPES and CHANMODES:
fn isupport(m: *const Msg) void {
    for (1..m.count -| 1) |i| {
        const p = m.params[i];
        if (std.mem.startsWith(u8, p, "PREFIX=(")) {
            const v = p["PREFIX=(".len..];
            const close = std.mem.indexOfScalar(u8, v, ')') orelse continue;
            prefix_modes.set(v[0..close]);
            prefix_syms.set(v[close + 1 ..]);
        } else if (std.mem.startsWith(u8, p, "CHANTYPES=")) {
            chantypes.set(p["CHANTYPES=".len..]);
        } else if (std.mem.startsWith(u8, p, "CHANMODES=")) {
            chanmodes.set(p["CHANMODES=".len..]);
        }
    }
}

// The group (0 A ... 3 D) of a channel mode; 4 for others.
fn modeGroup(c: u8) usize {
    var g: usize = 0;
    for (chanmodes.get()) |x| {
        if (x == ',') g += 1 else if (x == c) return g;
    }
    return 4;
}

// Prefix modes (+o nick) change the nick lists:
fn channelModes(ti: usize, m: *const Msg) void {
    var argi: usize = 2;
    var plus = true;
    for (m.arg(1)) |c| {
        switch (c) {
            '+' => plus = true,
            '-' => plus = false,
            else => {
                if (std.mem.indexOfScalar(u8, prefix_modes.get(), c)) |k| {
                    const who = m.arg(argi);
                    argi += 1;
                    const i = nickIndex(ti, who) orelse continue;
                    const n = &tabs[ti].nicks.items[i];
                    const sym = if (k < prefix_syms.len) prefix_syms.buf[k] else 0;
                    if (plus and rank(sym) < rank(n.mode)) n.mode = sym;
                    if (!plus and n.mode == sym) n.mode = 0;
                } else {
                    const g = modeGroup(c);
                    if (g <= 1 or (g == 2 and plus)) argi += 1;
                }
            },
        }
    }
}

// CONNECTION
var sock: ?net.Socket = null;
var tls: ?Tls = null;
var inbuf: [16384]u8 = undefined;
var inlen: usize = 0;
var registered = false;
var me: Text(nick_cap) = .{};
var base_nick: Text(nick_cap) = .{};
var nick_tries: u8 = 0;
var own_prefix_len: usize = 0; // nick!user@host as the server shows it
var away = false;
var autojoined = false;
var channels_formed: usize = 0; // RPL_LUSERCHANNELS
var listed: usize = 0;
var want_join: Text(64) = .{}; // the channel /join asked for
var quitting = false;
var quit_deadline: u64 = 0;
var done = false;

fn errorText(err: anyerror) []const u8 {
    inline for (@typeInfo(zdos.Error).error_set.?) |e| {
        if (err == @field(anyerror, e.name)) return zdos.message(@field(zdos.Error, e.name));
    }
    return switch (err) {
        error.EndOfStream => "the server closed the connection",
        error.TlsCertificateNotVerified => "the certificate isn't from a known authority (-k: don't check)",
        error.CertificateHostMismatch => "the certificate is for another name",
        error.CertificateExpired, error.CertificateNotYetValid => "the certificate isn't valid now (the clock?)",
        error.NoCertificates => "\\CONF\\CACERT.PEM is missing or empty (-k: don't check)",
        else => @errorName(err),
    };
}

fn connect() !void {
    const s = try net.Socket.connectTo(host, port);
    errdefer s.close();
    s.setOption(net.SocketOption.no_delay, 1) catch {};
    if (use_tls) tls = try Tls.connect(s, host, verify, unixTime());
    sock = s;
    inlen = 0;
    registered = false;
    nick_tries = 0;
    own_prefix_len = 0;
}

// Decrypted bytes the TLS client holds; poll can't see them:
fn tlsPending() bool {
    if (sock == null) return false;
    const c = tls orelse return false;
    return c.pending();
}

// One read, so the keys never wait for the server: 0 can be a
// TLS record without data.
fn netRead(out: []u8) !usize {
    const s = sock orelse return error.EndOfStream;
    if (tls) |c| return c.readSome(out);
    const n = try s.recv(out);
    if (n == 0) return error.EndOfStream;
    return n;
}

fn lost(why: []const u8) void {
    if (sock) |s| s.close();
    sock = null;
    if (tls) |c| c.deinit();
    tls = null;
    registered = false;
    for (tabs[1..tab_count]) |*t| {
        t.joined = false;
        t.nicks.clearRetainingCapacity();
    }
    dirty = true;
    if (quitting) return;
    note(0, C.err, "Disconnected: ", why);
    if (active != 0) note(active, C.err, "Disconnected: ", why);
    note(0, C.info, "/reconnect connects again, /quit ends IRCZ", "");
}

// CR and LF can't end up inside; at most 512 bytes with CR LF.
fn sendRaw(line: []const u8) void {
    const s = sock orelse return;
    var buf: [512]u8 = undefined;
    const n = utf8Cut(line, 510);
    for (line[0..n], 0..) |c, i| buf[i] = if (c == '\r' or c == '\n') ' ' else c;
    buf[n] = '\r';
    buf[n + 1] = '\n';
    const data = buf[0 .. n + 2];
    const ok = if (tls) |c|
        (if (c.writeAll(data)) true else |_| false)
    else
        (if (s.sendAll(data)) true else |_| false);
    if (!ok) lost("can't send");
}

fn sendf(comptime fmt: []const u8, args: anytype) void {
    var b: [2048]u8 = undefined;
    sendRaw(fmtBuf(&b, fmt, args));
}

fn register() void {
    if (password) |p| {
        sendRaw("CAP REQ :sasl");
        sendf("PASS {s}", .{p});
    }
    sendf("NICK {s}", .{me.get()});
    sendf("USER {s} 0 * :{s}", .{ user_name.get(), version_reply });
}

fn saslCredentials() void {
    const p = password orelse return;
    var raw: [300]u8 = undefined;
    const acct = base_nick.get();
    if (acct.len * 2 + p.len + 2 > raw.len) return sendRaw("AUTHENTICATE *");
    const plain = fmtBuf(&raw, "{s}\x00{s}\x00{s}", .{ acct, acct, p });
    var enc: [400]u8 = undefined;
    const b64 = std.base64.standard.Encoder.encode(&enc, plain);
    sendf("AUTHENTICATE {s}", .{b64});
    std.crypto.secureZero(u8, &raw);
}

// ZDOS keeps local time: close enough for certificates.
fn unixTime() i64 {
    const t = zdos.getTime();
    const y: i64 = if (t.month <= 2) @as(i64, t.year) - 1 else t.year;
    const m: i64 = t.month;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + t.day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + @as(i64, t.hour) * 3600 + @as(i64, t.minute) * 60 + t.second;
}

// EVENTS
fn readNet() void {
    // A line that doesn't fit is dropped:
    if (inbuf.len - inlen < 1024) inlen = 0;
    const n = netRead(inbuf[inlen..]) catch |err| return lost(errorText(err));
    inlen += n;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, inbuf[0..inlen], start, '\n')) |nl| {
        var line = inbuf[start..nl];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        handleLine(line);
        start = nl + 1;
        if (sock == null) return;
    }
    std.mem.copyForwards(u8, inbuf[0 .. inlen - start], inbuf[start..inlen]);
    inlen -= start;
}

fn handleLine(line: []const u8) void {
    const m = parse(line) orelse return;
    const cmd = m.command;
    if (cmd.len == 3 and std.ascii.isDigit(cmd[0])) {
        return numeric(&m, std.fmt.parseInt(u16, cmd, 10) catch return);
    }
    if (m.is("PING")) return sendf("PONG :{s}", .{m.arg(0)});
    if (m.is("PRIVMSG")) return privmsg(&m, false);
    if (m.is("NOTICE")) return privmsg(&m, true);
    if (m.is("JOIN")) return onJoin(&m);
    if (m.is("PART")) return onPart(&m);
    if (m.is("QUIT")) return onQuit(&m);
    if (m.is("NICK")) return onNick(&m);
    if (m.is("KICK")) return onKick(&m);
    if (m.is("MODE")) return onMode(&m);
    if (m.is("TOPIC")) return onTopic(&m);
    if (m.is("CAP")) return onCap(&m);
    if (m.is("AUTHENTICATE")) {
        if (std.mem.eql(u8, m.arg(0), "+")) saslCredentials();
        return;
    }
    if (m.is("ERROR")) return note(0, C.err, "ERROR: ", m.arg(0));
    if (m.is("INVITE")) {
        var b: [160]u8 = undefined;
        return note(active, C.join, fmtBuf(&b, "{s} invites you to ", .{m.nick()}), m.arg(1));
    }
    if (m.is("PONG")) return;
    note(0, C.numeric, "", line);
}

fn privmsg(m: *const Msg, notice: bool) void {
    const from = m.nick();
    const target = chanTarget(m.arg(0));
    var text = m.arg(1);
    var how: How = if (notice) .notice else .msg;
    if (text.len >= 2 and text[0] == 1) {
        var body = text[1..];
        if (body[body.len - 1] == 1) body = body[0 .. body.len - 1];
        const sp = std.mem.indexOfScalar(u8, body, ' ') orelse body.len;
        const what = body[0..sp];
        const rest = if (sp < body.len) body[sp + 1 ..] else "";
        if (!std.ascii.eqlIgnoreCase(what, "ACTION")) return ctcp(from, notice, what, rest);
        text = rest;
        how = .action;
    }
    const from_server = std.mem.indexOfScalar(u8, m.prefix, '!') == null;
    var ti: usize = 0;
    if (isChannel(target)) {
        ti = findTab(target) orelse 0;
    } else if (from_server or !registered) {
        ti = 0;
    } else if (notice) {
        ti = findTab(from) orelse active;
    } else {
        ti = openTab(.query, from) orelse 0;
    }
    showMsg(ti, from, modeOf(ti, from), text, how);
}

fn ctcp(from: []const u8, notice: bool, what: []const u8, rest: []const u8) void {
    var b: [200]u8 = undefined;
    if (notice) {
        return note(active, C.notice, fmtBuf(&b, "CTCP {s} reply from {s}: ", .{ what, from }), rest);
    }
    if (std.ascii.eqlIgnoreCase(what, "VERSION")) {
        sendf("NOTICE {s} :\x01VERSION {s}\x01", .{ from, version_reply });
    } else if (std.ascii.eqlIgnoreCase(what, "PING")) {
        sendf("NOTICE {s} :\x01PING {s}\x01", .{ from, rest });
    } else if (std.ascii.eqlIgnoreCase(what, "TIME")) {
        const t = zdos.getTime();
        sendf("NOTICE {s} :\x01TIME {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}\x01", .{ from, t.year, t.month, t.day, t.hour, t.minute, t.second });
    } else if (std.ascii.eqlIgnoreCase(what, "CLIENTINFO")) {
        sendf("NOTICE {s} :\x01CLIENTINFO ACTION CLIENTINFO PING TIME VERSION\x01", .{from});
    }
    note(0, C.notice, fmtBuf(&b, "CTCP {s} from {s} ", .{ what, from }), rest);
}

fn hostOf(prefix: []const u8) []const u8 {
    const bang = std.mem.indexOfScalar(u8, prefix, '!') orelse return "";
    return prefix[bang + 1 ..];
}

fn onJoin(m: *const Msg) void {
    const chan = m.arg(0);
    const who = m.nick();
    if (sameName(who, me.get())) {
        own_prefix_len = m.prefix.len;
        const i = openTab(.channel, chan) orelse return note(0, C.err, "Too many tabs for ", chan);
        const t = &tabs[i];
        t.name.set(chan);
        t.joined = true;
        t.names_open = false;
        t.nicks.clearRetainingCapacity();
        if (active == 0 or sameName(want_join.get(), chan)) {
            setActive(i);
            want_join.len = 0;
        }
        notef(i, C.join, "--> You joined {s}", .{chan});
        return;
    }
    const i = findTab(chan) orelse return;
    addNick(i, who, 0);
    notef(i, C.join, "--> {s} ({s}) joined {s}", .{ who, hostOf(m.prefix), chan });
}

fn onPart(m: *const Msg) void {
    const chan = m.arg(0);
    const who = m.nick();
    const i = findTab(chan) orelse return;
    var b: [200]u8 = undefined;
    if (sameName(who, me.get())) {
        closeTab(i);
        return notef(0, C.part, "<-- You left {s}", .{chan});
    }
    _ = removeNick(i, who);
    const reason = m.arg(1);
    note(i, C.part, fmtBuf(&b, "<-- {s} left {s} ", .{ who, chan }), reason);
}

fn onQuit(m: *const Msg) void {
    const who = m.nick();
    var b: [200]u8 = undefined;
    const head = fmtBuf(&b, "<-- {s} quit ", .{who});
    for (1..tab_count) |i| {
        const here = switch (tabs[i].kind) {
            .channel => removeNick(i, who),
            .query => sameName(tabs[i].name.get(), who),
            .server => false,
        };
        if (here) note(i, C.quit, head, m.arg(0));
    }
}

fn onNick(m: *const Msg) void {
    const old = m.nick();
    const new = m.arg(0);
    const mine = sameName(old, me.get());
    if (mine) {
        me.set(new);
        notef(0, C.nick, "You are now known as {s}", .{new});
    }
    for (1..tab_count) |i| {
        const t = &tabs[i];
        var here = false;
        if (t.kind == .channel) here = renameNick(i, old, new);
        if (t.kind == .query and sameName(t.name.get(), old) and findTab(new) == null) {
            t.name.set(new);
            here = true;
        }
        if (here) notef(i, C.nick, "{s} is now known as {s}", .{ old, new });
    }
    dirty = true;
}

fn onKick(m: *const Msg) void {
    const chan = m.arg(0);
    const victim = m.arg(1);
    const i = findTab(chan) orelse return;
    var b: [200]u8 = undefined;
    if (sameName(victim, me.get())) {
        tabs[i].joined = false;
        tabs[i].nicks.clearRetainingCapacity();
        var l = begin();
        l.style(C.kick, .black);
        l.text(fmtBuf(&b, "!!! You were kicked from {s} by {s} ", .{ chan, m.nick() }));
        l.irc(m.arg(2), C.kick);
        return addLine(i, &l, .mention);
    }
    _ = removeNick(i, victim);
    note(i, C.kick, fmtBuf(&b, "<-- {s} was kicked by {s} ", .{ victim, m.nick() }), m.arg(2));
}

fn joinedParams(m: *const Msg, from: usize, buf: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    for (from..m.count) |i| {
        if (i > from) fbs.writer().writeByte(' ') catch {};
        fbs.writer().writeAll(m.params[i]) catch {};
    }
    return fbs.getWritten();
}

fn onMode(m: *const Msg) void {
    const target = m.arg(0);
    var b: [512]u8 = undefined;
    var h: [200]u8 = undefined;
    const what = joinedParams(m, 1, &b);
    if (isChannel(target)) {
        const i = findTab(target) orelse return;
        channelModes(i, m);
        return note(i, C.mode, fmtBuf(&h, "mode/{s} [{s}] by {s}", .{ target, what, m.nick() }), "");
    }
    note(0, C.mode, fmtBuf(&h, "mode/{s} [{s}]", .{ target, what }), "");
}

fn onTopic(m: *const Msg) void {
    const i = findTab(m.arg(0)) orelse return;
    tabs[i].topic.set(m.arg(1));
    var b: [200]u8 = undefined;
    note(i, C.topic, fmtBuf(&b, "{s} changed the topic to: ", .{m.nick()}), m.arg(1));
}

fn onCap(m: *const Msg) void {
    const sub = m.arg(1);
    if (std.ascii.eqlIgnoreCase(sub, "ACK") and std.mem.indexOf(u8, m.arg(2), "sasl") != null) {
        sendRaw("AUTHENTICATE PLAIN");
    } else if (std.ascii.eqlIgnoreCase(sub, "NAK")) {
        note(0, C.err, "The server has no SASL", "");
        sendRaw("CAP END");
    }
}

fn joinAll() void {
    for (1..tab_count) |i| {
        if (tabs[i].kind == .channel) sendf("JOIN {s}", .{tabs[i].name.get()});
    }
    if (autojoined) return;
    autojoined = true;
    for (autojoin[0..autojoin_count]) |c| joinChannel(c, "");
}

fn joinChannel(name: []const u8, key: []const u8) void {
    const hash = if (isChannel(name)) "" else "#";
    sendf("JOIN {s}{s}{s}{s}", .{ hash, name, if (key.len > 0) " " else "", key });
}

fn nickError(m: *const Msg, n: u16) void {
    var b: [600]u8 = undefined;
    if (!registered and n == 433 and nick_tries < 2) {
        nick_tries += 1;
        var nb: [nick_cap + 2]u8 = undefined;
        const base = base_nick.get();
        @memcpy(nb[0..base.len], base);
        @memset(nb[base.len..][0..nick_tries], '_');
        me.set(nb[0 .. base.len + nick_tries]);
        notef(0, C.err, "Nick {s} is in use, trying {s}", .{ m.arg(1), me.get() });
        return sendf("NICK {s}", .{me.get()});
    }
    note(if (registered) active else 0, C.err, "", joinedParams(m, 1, &b));
    if (!registered) note(0, C.info, "Pick another one: /nick NEWNICK", "");
}

fn numeric(m: *const Msg, n: u16) void {
    var b: [600]u8 = undefined;
    var h: [200]u8 = undefined;
    switch (n) {
        1 => {
            registered = true;
            me.set(m.arg(0));
            note(0, C.numeric, "", m.last());
            joinAll();
        },
        5 => {
            isupport(m);
            note(0, C.numeric, "", joinedParams(m, 1, &b));
        },
        301 => {
            const ti = findTab(m.arg(1)) orelse active;
            note(ti, C.numeric, fmtBuf(&h, "{s} is away: ", .{m.arg(1)}), m.arg(2));
        },
        305, 306 => {
            away = n == 306;
            dirty = true;
            note(active, C.numeric, "", m.last());
        },
        // WHOIS replies:
        276, 307, 311...313, 317...320, 330, 335, 338, 378, 379, 671 => {
            note(active, C.numeric, fmtBuf(&h, "[{s}] ", .{m.arg(1)}), joinedParams(m, 2, &b));
        },
        324 => {
            const ti = findTab(m.arg(1)) orelse 0;
            note(ti, C.mode, fmtBuf(&h, "mode/{s} ", .{m.arg(1)}), joinedParams(m, 2, &b));
        },
        329 => {},
        331 => {
            const ti = findTab(m.arg(1)) orelse 0;
            notef(ti, C.topic, "No topic set for {s}", .{m.arg(1)});
        },
        332 => {
            const ti = findTab(m.arg(1)) orelse 0;
            if (ti != 0) tabs[ti].topic.set(m.arg(2));
            note(ti, C.topic, fmtBuf(&h, "Topic for {s}: ", .{m.arg(1)}), m.arg(2));
        },
        333 => {
            const ti = findTab(m.arg(1)) orelse 0;
            const who = m.arg(2);
            const setter = who[0 .. std.mem.indexOfScalar(u8, who, '!') orelse who.len];
            const secs = std.fmt.parseInt(u64, m.arg(3), 10) catch 0;
            notef(ti, C.topic, "Topic set by {s} on {s}", .{ setter, dateText(secs, &h) });
        },
        353 => names(m),
        366 => {
            const ti = findTab(m.arg(1)) orelse return;
            const t = &tabs[ti];
            t.names_open = false;
            var ops: usize = 0;
            for (t.nicks.items) |*x| {
                if (x.mode != 0 and x.mode != '+') ops += 1;
            }
            notef(ti, C.info, "{s}: {d} nicks ({d} ops)", .{ t.name.get(), t.nicks.items.len, ops });
        },
        432, 433, 436 => nickError(m, n),
        900, 901 => note(0, C.numeric, "", m.last()),
        903 => {
            note(0, C.numeric, "", m.last());
            sendRaw("CAP END");
        },
        902, 904, 905, 906 => {
            note(0, C.err, "SASL: ", m.last());
            sendRaw("CAP END");
        },
        907, 908 => {},
        254 => {
            channels_formed = std.fmt.parseInt(usize, m.arg(1), 10) catch 0;
            note(0, C.numeric, "", joinedParams(m, 1, &b));
        },
        // LIST: me #chan users :topic
        321 => {
            listed = 0;
            note(0, C.numeric, "Channel              Users  Topic", "");
        },
        322 => {
            listed += 1;
            note(0, C.numeric, fmtBuf(&h, "{s:<20} {s:>5}  ", .{ m.arg(1), m.arg(2) }), m.arg(3));
        },
        323 => notef(0, C.numeric, "{d} channels", .{listed}),
        else => {
            const err = n >= 400 and n < 600;
            note(if (err) active else 0, if (err) C.err else C.numeric, "", joinedParams(m, 1, &b));
        },
    }
}

// RPL_NAMREPLY: me = #chan :@op +voice nick ...
fn names(m: *const Msg) void {
    const ti = findTab(m.arg(2)) orelse {
        var b: [600]u8 = undefined;
        return note(0, C.numeric, "", joinedParams(m, 2, &b));
    };
    const t = &tabs[ti];
    if (!t.names_open) {
        t.nicks.clearRetainingCapacity();
        t.names_open = true;
    }
    var it = std.mem.tokenizeScalar(u8, m.arg(3), ' ');
    while (it.next()) |entry| {
        var w = entry;
        var mode: u8 = 0;
        while (w.len > 0 and std.mem.indexOfScalar(u8, prefix_syms.get(), w[0]) != null) {
            if (mode == 0) mode = w[0];
            w = w[1..];
        }
        const e = std.mem.indexOfScalar(u8, w, '!') orelse w.len;
        addNick(ti, w[0..e], mode);
    }
    dirty = true;
}

fn dateText(secs: u64, buf: []u8) []const u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return fmtBuf(buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{
        yd.year,              md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    });
}

// SCREEN
var cols: usize = 0;
var rows: usize = 0;
var cur: []Cell = &.{};
var shown: []Cell = &.{}; // what the screen has; ch 0: unknown
var dirty = true;
var cursor_col: usize = 0;

fn invalidate() void {
    for (shown) |*c| c.ch = 0;
    zdos.setColor(.light_gray, .black);
    zdos.clearScreen();
    dirty = true;
}

fn checkSize() void {
    const sz = zdos.screenSize();
    const c: usize = sz.col;
    const r: usize = sz.row;
    if (c == cols and r == rows) return;
    zdos.allocator.free(cur);
    zdos.allocator.free(shown);
    cur = &.{};
    shown = &.{};
    cols = 0;
    rows = 0;
    if (c == 0 or r == 0) return;
    cur = zdos.allocator.alloc(Cell, c * r) catch return;
    shown = zdos.allocator.alloc(Cell, c * r) catch {
        zdos.allocator.free(cur);
        cur = &.{};
        return;
    };
    cols = c;
    rows = r;
    invalidate();
}

// The next character of s that can be shown; null at the end.
fn nextChar(s: []const u8, i: *usize) ?u21 {
    while (i.* < s.len) {
        const c = s[i.*];
        const l: usize = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const end = @min(i.* + l, s.len);
        const cp: u21 = std.unicode.utf8Decode(s[i.*..end]) catch '?';
        i.* = end;
        if (cp >= 0x20 and cp != 0x7F and !(cp >= 0x80 and cp < 0xA0)) return cp;
    }
    return null;
}

fn charCount(s: []const u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (nextChar(s, &i)) |_| n += 1;
    return n;
}

fn putStr(x0: usize, y: usize, s: []const u8, fg: Color, bg: Color) usize {
    var x = x0;
    var i: usize = 0;
    while (x < cols) {
        const cp = nextChar(s, &i) orelse break;
        cur[y * cols + x] = .{ .ch = cp, .fg = @intCast(@intFromEnum(fg)), .bg = @intCast(@intFromEnum(bg)) };
        x += 1;
    }
    return x;
}

fn fillRow(y: usize, fg: Color, bg: Color) void {
    const blank: Cell = .{ .fg = @intCast(@intFromEnum(fg)), .bg = @intCast(@intFromEnum(bg)) };
    @memset(cur[y * cols ..][0..cols], blank);
}

fn draw() void {
    if (rows < 4 or cols < 16) {
        if (rows > 0 and cols > 0) {
            @memset(cur, .{});
            _ = putStr(0, 0, "IRCZ: too small", .white, .black);
            flush();
        }
        return;
    }
    @memset(cur, .{});
    drawTabBar();
    drawMessages();
    drawStatus();
    drawInput();
    flush();
}

fn labelWidth(i: usize) usize {
    var b: [8]u8 = undefined;
    return 3 + fmtBuf(&b, "{d}", .{i + 1}).len + charCount(tabs[i].name.get());
}

fn drawTabBar() void {
    fillRow(0, .light_gray, C.bar);
    // From a tab that lets the active one fit:
    var first: usize = 0;
    var need: usize = 0;
    for (0..active + 1) |i| need += labelWidth(i);
    while (first < active and need + 1 > cols) : (first += 1) need -= labelWidth(first);
    var x: usize = if (first > 0) putStr(0, 0, "<", .white, C.bar) else 0;
    for (first..tab_count) |i| {
        const t = &tabs[i];
        const colors: [2]Color = if (i == active) .{ .black, .light_gray } else switch (t.unread) {
            .none => .{ .light_gray, C.bar },
            .msg => .{ .light_cyan, C.bar },
            .mention => .{ .yellow, .red },
        };
        if (x + labelWidth(i) > cols) {
            _ = putStr(cols - 1, 0, ">", .white, C.bar);
            break;
        }
        var b: [80]u8 = undefined;
        x = putStr(x, 0, fmtBuf(&b, " {d}:{s} ", .{ i + 1, t.name.get() }), colors[0], colors[1]);
    }
}

fn drawMessages() void {
    const t = &tabs[active];
    const h = rows - 3;
    // Scrolled past the oldest line: down to it, once:
    for (0..2) |_| {
        @memset(cur[cols .. (1 + h) * cols], .{});
        const left = paintLines(t, 1, h);
        if (left == 0 or t.scroll == 0) break;
        t.scroll -|= left;
    }
}

// Bottom up, from t.scroll rows above the newest; the rows left empty.
fn paintLines(t: *const Tab, top: usize, h: usize) usize {
    const r = t.ring orelse return h + t.scroll;
    var y = h;
    var skip = t.scroll;
    var i = r.count;
    var cells: [max_cells]Cell = undefined;
    var spans: [64][2]usize = undefined;
    const ind: usize = if (cols > indent + 10) indent else 0;
    while (i > 0 and y > 0) {
        i -= 1;
        const n = expand(r.at(i), &cells);
        var k = wrap(cells[0..n], cols, &spans);
        while (k > 0 and y > 0) {
            k -= 1;
            if (skip > 0) {
                skip -= 1;
                continue;
            }
            y -= 1;
            var x: usize = if (k == 0) 0 else ind;
            for (cells[spans[k][0]..spans[k][1]]) |c| {
                if (x >= cols) break;
                cur[(top + y) * cols + x] = c;
                x += 1;
            }
        }
    }
    return y + skip;
}

fn drawStatus() void {
    const y = rows - 2;
    const t = &tabs[active];
    fillRow(y, .white, C.bar);
    var b: [200]u8 = undefined;
    var x = putStr(0, y, fmtBuf(&b, " [{s}{s}] [{d}:{s}", .{
        me.get(), if (away) " (away)" else "", active + 1, t.name.get(),
    }), .white, C.bar);
    if (t.kind == .channel) {
        x = putStr(x, y, fmtBuf(&b, ", {d} nicks", .{t.nicks.items.len}), .white, C.bar);
        if (!t.joined) x = putStr(x, y, ", not joined", .light_red, C.bar);
    }
    if (sock == null) x = putStr(x, y, ", DISCONNECTED", .light_red, C.bar);
    x = putStr(x, y, "] ", .white, C.bar);
    const end = if (t.scroll > 0) cols -| 8 else cols;
    var l: LineBuf = .{};
    if (t.kind == .server) {
        l.text(fmtBuf(&b, "{s}:{d}{s}", .{ host, port, if (use_tls) " (TLS)" else "" }));
    } else l.irc(t.topic.get(), .light_gray);
    var cells: [max_cells]Cell = undefined;
    for (cells[0..expand(l.buf[0..l.len], &cells)]) |c| {
        if (x >= end) break;
        var cell = c;
        if (cell.bg == 0) cell.bg = @intCast(@intFromEnum(C.bar));
        cur[y * cols + x] = cell;
        x += 1;
    }
    if (t.scroll > 0) _ = putStr(cols -| 8, y, " -MORE- ", .yellow, C.bar);
}

fn drawInput() void {
    const y = rows - 1;
    var b: [80]u8 = undefined;
    const name = tabs[active].name.get();
    const prompt = fmtBuf(&b, "[{s}] ", .{name[0..utf8Cut(name, @min(cols / 3, 40))]});
    const start = putStr(0, y, prompt, .light_cyan, .black);
    // The last cell stays: writing it would scroll:
    const room = @max(cols -| 1 -| start, 1);
    if (in_pos < in_view) in_view = in_pos;
    if (in_pos >= in_view + room) in_view = in_pos - room + 1;
    var x = start;
    for (input[in_view..@min(in_len, in_view + room)]) |c| {
        if (x >= cols - 1) break;
        cur[y * cols + x] = .{ .ch = c, .fg = 15, .bg = 0 };
        x += 1;
    }
    cursor_col = @min(start + in_pos - in_view, cols - 1);
}

fn sameCell(a: Cell, b: Cell) bool {
    return a.ch == b.ch and a.fg == b.fg and a.bg == b.bg;
}

// What changed since the last time, row by row:
fn flush() void {
    var hidden = false;
    for (0..rows) |y| {
        const row = cur[y * cols ..][0..cols];
        const old = shown[y * cols ..][0..cols];
        const end = if (y + 1 == rows) cols - 1 else cols;
        var x0: usize = 0;
        while (x0 < end and sameCell(row[x0], old[x0])) x0 += 1;
        if (x0 == end) continue;
        var x1 = end;
        while (x1 > x0 and sameCell(row[x1 - 1], old[x1 - 1])) x1 -= 1;
        if (!hidden) zdos.showCursor(false);
        hidden = true;
        zdos.setCursor(@intCast(x0), @intCast(y));
        var x = x0;
        while (x < x1) {
            const fg = row[x].fg;
            const bg = row[x].bg;
            var buf: [512]u8 = undefined;
            var n: usize = 0;
            while (x < x1 and row[x].fg == fg and row[x].bg == bg and n + 4 <= buf.len) : (x += 1) {
                n += std.unicode.utf8Encode(row[x].ch, buf[n..]) catch blk: {
                    buf[n] = '?';
                    break :blk 1;
                };
            }
            zdos.setColor(@enumFromInt(@as(u8, fg)), @enumFromInt(@as(u8, bg)));
            zdos.print(buf[0..n]);
        }
        @memcpy(old[x0..x1], row[x0..x1]);
    }
    zdos.setColor(.light_gray, .black);
    zdos.setCursor(@intCast(cursor_col), @intCast(rows - 1));
    if (hidden) zdos.showCursor(true);
}

// INPUT
var input: [input_cap]u21 = undefined;
var in_len: usize = 0;
var in_pos: usize = 0;
var in_view: usize = 0;

const Entry = struct {
    len: usize = 0,
    cps: [input_cap]u21 = undefined,
};
var hist: [hist_len]Entry = undefined;
var hist_count: usize = 0;
var hist_head: usize = 0;
var hist_at: ?usize = null; // how far back; null: the line being typed
var hist_saved: Entry = .{};

var comp_on = false;
var comp_start: usize = 0;
var comp_prefix: Text(nick_cap) = .{};
var comp_next: usize = 0;

fn loadEntry(e: *const Entry) void {
    @memcpy(input[0..e.len], e.cps[0..e.len]);
    in_len = e.len;
    in_pos = e.len;
}

fn saveEntry(e: *Entry) void {
    @memcpy(e.cps[0..in_len], input[0..in_len]);
    e.len = in_len;
}

fn histEntry(back: usize) *Entry {
    return &hist[(hist_head + hist_len - 1 - back) % hist_len];
}

fn historyUp() void {
    if (hist_count == 0) return;
    if (hist_at) |a| {
        if (a + 1 >= hist_count) return;
        hist_at = a + 1;
    } else {
        saveEntry(&hist_saved);
        hist_at = 0;
    }
    loadEntry(histEntry(hist_at.?));
}

fn historyDown() void {
    const a = hist_at orelse return;
    if (a == 0) {
        hist_at = null;
        return loadEntry(&hist_saved);
    }
    hist_at = a - 1;
    loadEntry(histEntry(a - 1));
}

fn pushHistory() void {
    hist_at = null;
    if (hist_count > 0) {
        const last = histEntry(0);
        if (last.len == in_len and std.mem.eql(u21, last.cps[0..in_len], input[0..in_len])) return;
    }
    saveEntry(&hist[hist_head]);
    hist_head = (hist_head + 1) % hist_len;
    if (hist_count < hist_len) hist_count += 1;
}

fn insert(c: u21) void {
    if (in_len == input_cap) return;
    std.mem.copyBackwards(u21, input[in_pos + 1 .. in_len + 1], input[in_pos..in_len]);
    input[in_pos] = c;
    in_len += 1;
    in_pos += 1;
}

fn deleteRange(a: usize, b: usize) void {
    std.mem.copyForwards(u21, input[a .. in_len - (b - a)], input[b..in_len]);
    in_len -= b - a;
    in_pos = a;
}

fn insertText(s: []const u8) void {
    var i: usize = 0;
    while (nextChar(s, &i)) |c| insert(c);
}

// The nicks of the channel that start with the word before
// the cursor, one per Tab:
fn complete() void {
    const t = &tabs[active];
    if (!comp_on) {
        var s = in_pos;
        while (s > 0 and input[s - 1] != ' ') s -= 1;
        if (s == in_pos or in_pos - s > nick_cap) return;
        var b: [nick_cap]u8 = undefined;
        for (input[s..in_pos], 0..) |c, i| b[i] = if (c < 0x80) @intCast(c) else '?';
        comp_prefix.set(b[0 .. in_pos - s]);
        comp_start = s;
        comp_next = 0;
        comp_on = true;
    }
    const p = comp_prefix.get();
    const list = t.nicks.items;
    var found: ?[]const u8 = null;
    if (t.kind == .query) {
        if (comp_next == 0 and startsWithName(t.name.get(), p)) found = t.name.get();
        comp_next = 1;
    }
    var k: usize = 0;
    while (found == null and k < list.len) : (k += 1) {
        const i = (comp_next + k) % list.len;
        if (startsWithName(list[i].get(), p)) {
            found = list[i].get();
            comp_next = i + 1;
        }
    }
    const name = found orelse return;
    deleteRange(comp_start, in_pos);
    insertText(name);
    insertText(if (comp_start == 0) ": " else " ");
}

fn startsWithName(name: []const u8, p: []const u8) bool {
    return name.len >= p.len and sameName(name[0..p.len], p);
}

fn handleKey(k: zdos.Key) void {
    const S = zdos.Scan;
    dirty = true;
    if (k.scan != 0) {
        comp_on = false;
        if (k.alt() and k.scan == S.left) return setActive((active + tab_count - 1) % tab_count);
        if (k.alt() and k.scan == S.right) return setActive((active + 1) % tab_count);
        const t = &tabs[active];
        const page = @max(rows -| 4, 1);
        switch (k.scan) {
            S.left => in_pos -|= 1,
            S.right => in_pos = @min(in_pos + 1, in_len),
            S.home => in_pos = 0,
            S.end => in_pos = in_len,
            S.delete => if (in_pos < in_len) deleteRange(in_pos, in_pos + 1),
            S.up => historyUp(),
            S.down => historyDown(),
            S.page_up => t.scroll += page,
            S.page_down => t.scroll -|= page,
            S.redraw => invalidate(),
            else => {},
        }
        return;
    }
    var c: u21 = k.char;
    if (c == 0) return;
    if (k.alt() and c >= '0' and c <= '9') {
        return setActive(if (c == '0') 9 else c - '1');
    }
    if (k.ctrl() and !k.alt() and c < 128 and std.ascii.isAlphabetic(@intCast(c))) c &= 0x1F;
    if (c != '\t') comp_on = false;
    switch (c) {
        '\r', '\n' => submit(),
        8, 0x7F => if (in_pos > 0) deleteRange(in_pos - 1, in_pos),
        '\t' => complete(),
        1 => in_pos = 0, // Ctrl+A
        5 => in_pos = in_len, // Ctrl+E
        3 => note(active, C.info, "Ctrl+C: /quit ends IRCZ", ""),
        11 => in_len = in_pos, // Ctrl+K
        12 => invalidate(), // Ctrl+L
        14 => setActive((active + 1) % tab_count), // Ctrl+N
        16 => setActive((active + tab_count - 1) % tab_count), // Ctrl+P
        21 => deleteRange(0, in_pos), // Ctrl+U
        23 => { // Ctrl+W
            var s = in_pos;
            while (s > 0 and input[s - 1] == ' ') s -= 1;
            while (s > 0 and input[s - 1] != ' ') s -= 1;
            deleteRange(s, in_pos);
        },
        else => if (c >= 0x20 and !(c >= 0x7F and c < 0xA0)) insert(c),
    }
}

fn submit() void {
    if (in_len == 0) return;
    var b: [input_cap * 4]u8 = undefined;
    var n: usize = 0;
    for (input[0..in_len]) |c| n += std.unicode.utf8Encode(c, b[n..]) catch 0;
    pushHistory();
    in_len = 0;
    in_pos = 0;
    in_view = 0;
    tabs[active].scroll = 0;
    command(b[0..n]);
}

// COMMANDS
const help_text = [_][]const u8{
    "/join #CHAN [KEY]   /part [#CHAN] [MSG]   /close   /win N   /clear",
    "/msg NICK TEXT   /query NICK [TEXT]   /me TEXT   /notice NICK TEXT",
    "/nick NICK   /topic [TEXT]   /names   /list [FILTER]   /whois NICK",
    "/mode [ARGS]   /kick NICK [MSG]   /away [MSG]   /ctcp NICK WHAT   /quote LINE",
    "/reconnect   /quit [MSG]   //TEXT sends /TEXT",
    "Alt+1..9, Alt+0, Ctrl+N, Ctrl+P, Alt+Left/Right: tabs",
    "PgUp/PgDn: scroll   Up/Down: history   Tab: nick completion",
};

fn connected() bool {
    if (sock != null) return true;
    note(active, C.err, "Not connected (/reconnect)", "");
    return false;
}

fn ownPrefixLen() usize {
    if (own_prefix_len > 0) return own_prefix_len;
    return me.len + 2 + user_name.len + 1 + 63;
}

// Split so the line the others get stays within 512 bytes:
fn say(target: []const u8, text: []const u8, action: bool) void {
    if (!connected()) return;
    const ti = findTab(target);
    const extra: usize = if (action) "\x01ACTION \x01".len else 0;
    const over = 1 + ownPrefixLen() + " PRIVMSG  :\r\n".len + target.len + extra;
    const max = if (over + 64 < 512) 512 - over else 64;
    var rest = text;
    while (rest.len > 0) {
        const n = splitPoint(rest, max);
        const part = rest[0..n];
        if (action) {
            sendf("PRIVMSG {s} :\x01ACTION {s}\x01", .{ target, part });
        } else sendf("PRIVMSG {s} :{s}", .{ target, part });
        if (ti) |i| {
            showMsg(i, me.get(), modeOf(i, me.get()), part, if (action) .action else .msg);
        } else {
            var b: [100]u8 = undefined;
            note(active, C.own, fmtBuf(&b, "-> *{s}* ", .{target}), part);
        }
        rest = rest[n..];
        if (rest.len > 0 and rest[0] == ' ') rest = rest[1..];
    }
}

fn word(s: []const u8) [2][]const u8 {
    const t = std.mem.trimLeft(u8, s, " ");
    const e = std.mem.indexOfScalar(u8, t, ' ') orelse t.len;
    return .{ t[0..e], std.mem.trimLeft(u8, t[e..], " ") };
}

fn command(line: []const u8) void {
    const t = &tabs[active];
    if (line[0] != '/' or (line.len > 1 and line[1] == '/')) {
        const text = if (line[0] == '/') line[1..] else line;
        if (t.kind == .server) return note(0, C.info, "Join a channel first: /join #CHANNEL", "");
        return say(t.name.get(), text, false);
    }
    const w = word(line[1..]);
    const cmd = w[0];
    const args = std.mem.trimRight(u8, w[1], " ");
    const is = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.ascii.eqlIgnoreCase(a, b);
        }
    }.f;
    var b: [600]u8 = undefined;
    if (is(cmd, "quit") or is(cmd, "exit")) {
        quitting = true;
        quit_deadline = zdos.millis() + 2000;
        if (sock == null) done = true;
        return sendf("QUIT :{s}", .{if (args.len > 0) args else quit_message});
    }
    if (is(cmd, "help")) {
        for (help_text) |h| note(active, C.info, h, "");
        return;
    }
    if (is(cmd, "win") or is(cmd, "w")) {
        const n = std.fmt.parseInt(usize, args, 10) catch 0;
        if (n == 0 or n > tab_count) return note(active, C.err, "No such tab", "");
        return setActive(n - 1);
    }
    if (is(cmd, "clear")) {
        if (t.ring) |r| r.count = 0;
        t.scroll = 0;
        return;
    }
    if (is(cmd, "close")) {
        if (t.kind == .server) return note(0, C.info, "/quit ends IRCZ", "");
        if (t.kind == .channel and t.joined and sock != null) {
            return sendf("PART {s} :{s}", .{ t.name.get(), quit_message });
        }
        return closeTab(active);
    }
    if (is(cmd, "names") and args.len == 0 and t.kind == .channel) return showNames(active);
    if (is(cmd, "reconnect")) {
        if (sock != null) {
            sendRaw("QUIT :reconnecting");
            quitting = true;
            lost("");
            quitting = false;
        }
        notef(0, C.info, "Connecting to {s}:{d}...", .{ host, port });
        setActive(0);
        draw();
        connect() catch |err| return note(0, C.err, "Can't connect: ", errorText(err));
        return register();
    }
    if (!connected()) return;
    const a = word(args);
    if (is(cmd, "join") or is(cmd, "j")) {
        if (a[0].len == 0) return note(active, C.err, "/join #CHANNEL [KEY]", "");
        const first = a[0][0 .. std.mem.indexOfScalar(u8, a[0], ',') orelse a[0].len];
        want_join.set(fmtBuf(&b, "{s}{s}", .{ if (isChannel(first)) "" else "#", first }));
        var it = std.mem.tokenizeScalar(u8, a[0], ',');
        while (it.next()) |c| joinChannel(c, a[1]);
    } else if (is(cmd, "part") or is(cmd, "leave")) {
        const chan = if (isChannel(a[0])) a[0] else if (t.kind == .channel) t.name.get() else "";
        const msg = if (isChannel(a[0])) a[1] else args;
        if (chan.len == 0) return note(active, C.err, "/part #CHANNEL [MSG]", "");
        sendf("PART {s} :{s}", .{ chan, if (msg.len > 0) msg else quit_message });
    } else if (is(cmd, "msg")) {
        if (a[0].len == 0 or a[1].len == 0) return note(active, C.err, "/msg NICK TEXT", "");
        if (!isChannel(a[0])) _ = openTab(.query, a[0]);
        say(a[0], a[1], false);
    } else if (is(cmd, "query") or is(cmd, "q")) {
        if (a[0].len == 0) return note(active, C.err, "/query NICK [TEXT]", "");
        const i = openTab(.query, a[0]) orelse return note(active, C.err, "Too many tabs", "");
        setActive(i);
        if (a[1].len > 0) say(a[0], a[1], false);
    } else if (is(cmd, "me")) {
        if (t.kind == .server) return note(0, C.info, "Join a channel first: /join #CHANNEL", "");
        say(t.name.get(), args, true);
    } else if (is(cmd, "notice")) {
        if (a[1].len == 0) return note(active, C.err, "/notice TARGET TEXT", "");
        sendf("NOTICE {s} :{s}", .{ a[0], a[1] });
        note(active, C.notice, fmtBuf(&b, "-> -{s}- ", .{a[0]}), a[1]);
    } else if (is(cmd, "nick")) {
        if (a[0].len == 0) return note(active, C.err, "/nick NICK", "");
        if (!registered) me.set(a[0]);
        sendf("NICK {s}", .{a[0]});
    } else if (is(cmd, "topic")) {
        const other = isChannel(a[0]);
        const chan = if (other) a[0] else if (t.kind == .channel) t.name.get() else "";
        const text = if (other) a[1] else args;
        if (chan.len == 0) return note(active, C.err, "/topic [#CHANNEL] [TEXT]", "");
        if (text.len == 0) return sendf("TOPIC {s}", .{chan});
        sendf("TOPIC {s} :{s}", .{ chan, text });
    } else if (is(cmd, "names")) {
        sendf("NAMES {s}", .{a[0]});
    } else if (is(cmd, "list")) {
        // A tab keeps ring_len lines: a big network's list needs a filter:
        if (args.len == 0 and channels_formed > ring_len) {
            return notef(active, C.err, "{d} channels: /list >100 (users), /list *WORD* or /list * (all)", .{channels_formed});
        }
        setActive(0);
        if (args.len == 0) return sendRaw("LIST");
        sendf("LIST {s}", .{args});
    } else if (is(cmd, "whois") or is(cmd, "wi")) {
        if (a[0].len == 0) return note(active, C.err, "/whois NICK", "");
        sendf("WHOIS {s}", .{a[0]});
    } else if (is(cmd, "mode")) {
        const here = t.kind == .channel and (args.len == 0 or args[0] == '+' or args[0] == '-');
        if (here) return sendf("MODE {s} {s}", .{ t.name.get(), args });
        sendf("MODE {s}", .{if (args.len > 0) args else me.get()});
    } else if (is(cmd, "kick") or is(cmd, "k")) {
        if (t.kind != .channel or a[0].len == 0) return note(active, C.err, "/kick NICK [MSG] in a channel", "");
        sendf("KICK {s} {s} :{s}", .{ t.name.get(), a[0], a[1] });
    } else if (is(cmd, "away")) {
        if (args.len == 0) return sendRaw("AWAY");
        sendf("AWAY :{s}", .{args});
    } else if (is(cmd, "ctcp")) {
        if (a[1].len == 0) return note(active, C.err, "/ctcp NICK WHAT [ARGS]", "");
        var up: [32]u8 = undefined;
        const what = std.ascii.upperString(&up, a[1][0..@min(a[1].len, up.len)]);
        sendf("PRIVMSG {s} :\x01{s}\x01", .{ a[0], what });
    } else if (is(cmd, "quote") or is(cmd, "raw")) {
        sendRaw(args);
    } else {
        note(active, C.err, fmtBuf(&b, "Unknown command /{s} (/help)", .{cmd}), "");
    }
}

// MAIN
fn run() void {
    while (!done) {
        checkSize();
        if (dirty) {
            draw();
            dirty = false;
        }
        var fds = [2]zdos.PollFd{
            .{ .handle = zdos.PollFd.stdin_handle, .events = zdos.Poll.in },
            .{ .handle = if (sock) |s| s.handle else -1, .events = zdos.Poll.in },
        };
        const pending = tlsPending();
        const count: u32 = if (sock != null) 2 else 1;
        _ = zdos.table().files.poll(&fds, count, if (pending) 0 else 250);
        while (!done) handleKey(zdos.pollKey() orelse break);
        if (sock != null and (pending or fds[1].revents != 0)) readNet();
        if (quitting and (sock == null or zdos.millis() > quit_deadline)) done = true;
    }
}

pub fn main(args: []const u8) u8 {
    if (!parseArgs(args)) return usage();
    prefix_modes.set("qaohv");
    prefix_syms.set("~&@%+");
    chantypes.set("#&+!");
    chanmodes.set("beI,k,l,");
    zdos.printf("IRCZ: connecting to {s}:{d}{s}...\n", .{ host, port, if (use_tls) " (TLS)" else "" });
    connect() catch |err| {
        zdos.eprintf("IRCZ: {s}: {s}\n", .{ host, errorText(err) });
        return 1;
    };
    tabs[0] = .{ .kind = .server };
    tabs[0].name.set(host);
    tabs[0].ring = zdos.allocator.create(Ring) catch null;
    if (tabs[0].ring) |r| {
        r.head = 0;
        r.count = 0;
    }
    tab_count = 1;
    zdos.setCtrlC(true);
    zdos.print("\x1b[?1049h");
    notef(0, C.info, "Connected to {s}:{d}{s}; /help lists the commands", .{ host, port, if (use_tls) " (TLS)" else "" });
    register();
    run();
    if (sock) |s| s.close();
    zdos.setColor(.light_gray, .black);
    zdos.clearScreen();
    zdos.print("\x1b[?1049l");
    zdos.showCursor(true);
    zdos.setCtrlC(false);
    return 0;
}
