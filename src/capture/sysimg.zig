//! `.sysimg` — capture/replay danych systemowych (SMBIOS, PCI, GPU, dyski).
//!
//! Rozszerzenie projektu `.cpuimg` (docs/04-fcap-i-testy.md): ten sam styl —
//! **tekstowy**, diffowalny, jedna instrukcja w linii, `#` = komentarz — ale
//! dla danych, które nie są CPUID. Zapisujemy wyłącznie dane **surowe**
//! (bajty tabel, identyfikatory, deskryptory), żeby replay przechodził przez
//! te same dekodery co odczyt na żywo.
//!
//! Domyślnie capture **maskuje** numery seryjne: w SMBIOS (typy 1/2/3/4/17,
//! UUID zerowany) i w STORAGE_DEVICE_DESCRIPTOR (bajty numeru seryjnego → 'X').
//! Struktura i offsety zostają nienaruszone, więc parsery działają tak samo.
//!
//! ```text
//! ferrum-sysimg 1
//! masked yes
//! admin no
//! smbios-status ok
//! smbios 0003030000...            (kolejne linie `smbios` są doklejane)
//! pci 0e 00 0 1002 744c 1849 5304 c8 03 00 00 4 16 4 16 "32.0..." "2026-09-28" "AMD" "AMD Radeon RX 7900 XTX"
//! gpu 1002 744c 53041849 c8 25706889216 0 17140105216 0 "AMD Radeon RX 7900 XTX"
//! disk 0 size 12000138625024
//! disk 0 rot 1
//! disk 0 health requires_admin 5 "uwaga" "źródło"
//! disk 0 desc 00000000...
//! disk 0 nvme 2f01...
//! ```
//! Liczby w `pci`/`gpu` są szesnastkowe (poza rozmiarami pamięci), `-` = brak.

const std = @import("std");
const snap = @import("../sys/snapshot.zig");
const smbios = @import("../sys/smbios.zig");

pub const magic = "ferrum-sysimg";
pub const format_version: u32 = 1;

pub const ParseError = error{ BadMagic, UnsupportedFormat, Malformed, OutOfMemory };

// ---------------------------------------------------------------------------
// Maskowanie
// ---------------------------------------------------------------------------

/// Zastępuje numer seryjny w STORAGE_DEVICE_DESCRIPTOR znakami 'X' (w miejscu).
/// `SerialNumberOffset` leży pod offsetem 24 (winioctl.h).
pub fn maskDescriptorSerial(desc: []u8) void {
    if (desc.len < 28) return;
    const off = std.mem.readInt(u32, desc[24..28], .little);
    if (off == 0 or off >= desc.len) return;
    var i: usize = off;
    while (i < desc.len and desc[i] != 0) : (i += 1) {
        if (desc[i] != ' ') desc[i] = 'X';
    }
}

/// Kopia migawki z zamaskowanymi numerami seryjnymi (bufory kopiowane do `arena`).
pub fn masked(arena: std.mem.Allocator, s: snap.Snapshot) !snap.Snapshot {
    var out = s;
    if (s.smbios) |b| {
        const copy = try arena.dupe(u8, b);
        _ = smbios.maskSerials(copy) catch {};
        out.smbios = copy;
    }
    const disks = try arena.alloc(snap.DiskRaw, s.disks.len);
    for (s.disks, 0..) |d, i| {
        disks[i] = d;
        const dc = try arena.dupe(u8, d.descriptor);
        maskDescriptorSerial(dc);
        disks[i].descriptor = dc;
    }
    out.disks = disks;
    out.serials_masked = true;
    return out;
}

// ---------------------------------------------------------------------------
// Zapis
// ---------------------------------------------------------------------------

fn writeQuoted(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n', '\r' => try w.writeByte(' '),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeHexLines(w: *std.Io.Writer, prefix: []const u8, data: []const u8) !void {
    var i: usize = 0;
    while (i < data.len) : (i += 64) {
        const end = @min(i + 64, data.len);
        try w.print("{s} ", .{prefix});
        for (data[i..end]) |byte| try w.print("{x:0>2}", .{byte});
        try w.writeByte('\n');
    }
}

fn optHex(w: *std.Io.Writer, v: anytype) !void {
    if (v) |x| try w.print(" {x}", .{x}) else try w.writeAll(" -");
}

pub fn write(w: *std.Io.Writer, s: snap.Snapshot, comment: []const u8) !void {
    try w.print("{s} {d}\n", .{ magic, format_version });
    if (comment.len > 0) try w.print("# {s}\n", .{comment});
    try w.print("masked {s}\nadmin {s}\n", .{ if (s.serials_masked) "yes" else "no", if (s.is_admin) "yes" else "no" });
    try w.print("smbios-status {s}\npci-status {s}\ngpu-status {s}\ndisk-status {s}\n", .{
        @tagName(s.smbios_status), @tagName(s.pci_status), @tagName(s.gpu_status), @tagName(s.disk_status),
    });
    if (s.smbios) |b| try writeHexLines(w, "smbios", b);
    for (s.pci) |p| {
        try w.print("pci {x} {x} {x} {x:0>4} {x:0>4} {x:0>4} {x:0>4} {x:0>2}", .{ p.bus, p.dev, p.func, p.vendor, p.device, p.subvendor, p.subdevice, p.revision });
        try optHex(w, p.class);
        try optHex(w, p.subclass);
        try optHex(w, p.progif);
        try optHex(w, p.link_cur_speed);
        try optHex(w, p.link_cur_width);
        try optHex(w, p.link_max_speed);
        try optHex(w, p.link_max_width);
        try w.writeByte(' ');
        try writeQuoted(w, p.driver_version);
        try w.writeByte(' ');
        try writeQuoted(w, p.driver_date);
        try w.writeByte(' ');
        try writeQuoted(w, p.driver_provider);
        try w.writeByte(' ');
        try writeQuoted(w, p.desc);
        try w.writeByte('\n');
    }
    for (s.gpus) |g| {
        try w.print("gpu {x:0>4} {x:0>4} {x:0>8} {x:0>2} {d} {d} {d} {d} ", .{ g.vendor, g.device, g.subsys, g.revision, g.dedicated_vram, g.dedicated_sys, g.shared_sys, @intFromBool(g.software) });
        try writeQuoted(w, g.name);
        try w.writeByte('\n');
    }
    for (s.disks) |d| {
        if (d.size_bytes) |n| try w.print("disk {d} size {d}\n", .{ d.index, n });
        if (d.rotational) |r| try w.print("disk {d} rot {d}\n", .{ d.index, @intFromBool(r) });
        try w.print("disk {d} health {s} {d} ", .{ d.index, @tagName(d.health), d.health_error });
        try writeQuoted(w, d.health_note);
        try w.writeByte(' ');
        try writeQuoted(w, d.health_source);
        try w.writeByte('\n');
        var pfx: [32]u8 = undefined;
        try writeHexLines(w, std.fmt.bufPrint(&pfx, "disk {d} desc", .{d.index}) catch unreachable, d.descriptor);
        if (d.nvme_log) |b| try writeHexLines(w, std.fmt.bufPrint(&pfx, "disk {d} nvme", .{d.index}) catch unreachable, b);
        if (d.ata_smart) |b| try writeHexLines(w, std.fmt.bufPrint(&pfx, "disk {d} smart", .{d.index}) catch unreachable, b);
        if (d.ata_thresholds) |b| try writeHexLines(w, std.fmt.bufPrint(&pfx, "disk {d} thr", .{d.index}) catch unreachable, b);
    }
}

// ---------------------------------------------------------------------------
// Odczyt
// ---------------------------------------------------------------------------

const Tok = struct {
    s: []const u8,
    i: usize = 0,
    arena: std.mem.Allocator,

    fn skip(self: *Tok) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == '\t')) self.i += 1;
    }

    fn word(self: *Tok) ?[]const u8 {
        self.skip();
        if (self.i >= self.s.len) return null;
        const start = self.i;
        while (self.i < self.s.len and self.s[self.i] != ' ' and self.s[self.i] != '\t') self.i += 1;
        return self.s[start..self.i];
    }

    fn quoted(self: *Tok) ParseError![]const u8 {
        self.skip();
        if (self.i >= self.s.len or self.s[self.i] != '"') return error.Malformed;
        self.i += 1;
        var out: std.ArrayList(u8) = .empty;
        while (self.i < self.s.len) : (self.i += 1) {
            const c = self.s[self.i];
            if (c == '\\' and self.i + 1 < self.s.len) {
                self.i += 1;
                try out.append(self.arena, self.s[self.i]);
            } else if (c == '"') {
                self.i += 1;
                return out.items;
            } else try out.append(self.arena, c);
        }
        return error.Malformed;
    }

    fn hex(self: *Tok, comptime T: type) ParseError!T {
        const w = self.word() orelse return error.Malformed;
        return std.fmt.parseInt(T, w, 16) catch error.Malformed;
    }

    fn dec(self: *Tok, comptime T: type) ParseError!T {
        const w = self.word() orelse return error.Malformed;
        return std.fmt.parseInt(T, w, 10) catch error.Malformed;
    }

    fn optHex(self: *Tok, comptime T: type) ParseError!?T {
        const w = self.word() orelse return error.Malformed;
        if (std.mem.eql(u8, w, "-")) return null;
        return std.fmt.parseInt(T, w, 16) catch error.Malformed;
    }
};

fn appendHex(arena: std.mem.Allocator, list: *std.ArrayList(u8), hex: []const u8) ParseError!void {
    if (hex.len % 2 != 0) return error.Malformed;
    var i: usize = 0;
    while (i < hex.len) : (i += 2) {
        const b = std.fmt.parseInt(u8, hex[i .. i + 2], 16) catch return error.Malformed;
        try list.append(arena, b);
    }
}

fn collectOf(w: []const u8) snap.Collect {
    return std.meta.stringToEnum(snap.Collect, w) orelse .unavailable;
}

const DiskBuild = struct {
    raw: snap.DiskRaw,
    desc: std.ArrayList(u8) = .empty,
    nvme: std.ArrayList(u8) = .empty,
    smart: std.ArrayList(u8) = .empty,
    thr: std.ArrayList(u8) = .empty,
};

/// Parsuje plik `.sysimg`. Wszystko alokowane w `arena`.
pub fn parse(arena: std.mem.Allocator, text: []const u8) ParseError!snap.Snapshot {
    var s: snap.Snapshot = .{};
    var smb: std.ArrayList(u8) = .empty;
    var pci: std.ArrayList(snap.PciDevice) = .empty;
    var gpus: std.ArrayList(snap.GpuAdapter) = .empty;
    var disks: std.ArrayList(DiskBuild) = .empty;
    var saw_magic = false;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var t = Tok{ .s = line, .arena = arena };
        const kw = t.word() orelse continue;
        if (!saw_magic) {
            if (!std.mem.eql(u8, kw, magic)) return error.BadMagic;
            const v = try t.dec(u32);
            if (v != format_version) return error.UnsupportedFormat;
            saw_magic = true;
            continue;
        }
        if (std.mem.eql(u8, kw, "masked")) {
            s.serials_masked = std.mem.eql(u8, t.word() orelse "", "yes");
        } else if (std.mem.eql(u8, kw, "admin")) {
            s.is_admin = std.mem.eql(u8, t.word() orelse "", "yes");
        } else if (std.mem.eql(u8, kw, "smbios-status")) {
            s.smbios_status = collectOf(t.word() orelse "");
        } else if (std.mem.eql(u8, kw, "pci-status")) {
            s.pci_status = collectOf(t.word() orelse "");
        } else if (std.mem.eql(u8, kw, "gpu-status")) {
            s.gpu_status = collectOf(t.word() orelse "");
        } else if (std.mem.eql(u8, kw, "disk-status")) {
            s.disk_status = collectOf(t.word() orelse "");
        } else if (std.mem.eql(u8, kw, "smbios")) {
            try appendHex(arena, &smb, t.word() orelse return error.Malformed);
        } else if (std.mem.eql(u8, kw, "pci")) {
            var p: snap.PciDevice = .{ .location_valid = true };
            p.bus = try t.hex(u32);
            p.dev = try t.hex(u32);
            p.func = try t.hex(u32);
            p.vendor = try t.hex(u16);
            p.device = try t.hex(u16);
            p.subvendor = try t.hex(u16);
            p.subdevice = try t.hex(u16);
            p.revision = try t.hex(u8);
            p.class = try t.optHex(u8);
            p.subclass = try t.optHex(u8);
            p.progif = try t.optHex(u8);
            p.link_cur_speed = try t.optHex(u32);
            p.link_cur_width = try t.optHex(u32);
            p.link_max_speed = try t.optHex(u32);
            p.link_max_width = try t.optHex(u32);
            p.driver_version = try t.quoted();
            p.driver_date = try t.quoted();
            p.driver_provider = try t.quoted();
            p.desc = try t.quoted();
            try pci.append(arena, p);
        } else if (std.mem.eql(u8, kw, "gpu")) {
            var g: snap.GpuAdapter = .{};
            g.vendor = try t.hex(u16);
            g.device = try t.hex(u16);
            g.subsys = try t.hex(u32);
            g.revision = try t.hex(u8);
            g.dedicated_vram = try t.dec(u64);
            g.dedicated_sys = try t.dec(u64);
            g.shared_sys = try t.dec(u64);
            g.software = (try t.dec(u8)) != 0;
            g.name = try t.quoted();
            try gpus.append(arena, g);
        } else if (std.mem.eql(u8, kw, "disk")) {
            const idx = try t.dec(u32);
            var db: ?*DiskBuild = null;
            for (disks.items) |*d| {
                if (d.raw.index == idx) db = d;
            }
            if (db == null) {
                try disks.append(arena, .{ .raw = .{ .index = idx } });
                db = &disks.items[disks.items.len - 1];
            }
            const d = db.?;
            const what = t.word() orelse return error.Malformed;
            if (std.mem.eql(u8, what, "size")) {
                d.raw.size_bytes = try t.dec(u64);
            } else if (std.mem.eql(u8, what, "rot")) {
                d.raw.rotational = (try t.dec(u8)) != 0;
            } else if (std.mem.eql(u8, what, "health")) {
                d.raw.health = collectOf(t.word() orelse "");
                d.raw.health_error = try t.dec(u32);
                d.raw.health_note = try t.quoted();
                d.raw.health_source = try t.quoted();
            } else if (std.mem.eql(u8, what, "desc")) {
                try appendHex(arena, &d.desc, t.word() orelse return error.Malformed);
            } else if (std.mem.eql(u8, what, "nvme")) {
                try appendHex(arena, &d.nvme, t.word() orelse return error.Malformed);
            } else if (std.mem.eql(u8, what, "smart")) {
                try appendHex(arena, &d.smart, t.word() orelse return error.Malformed);
            } else if (std.mem.eql(u8, what, "thr")) {
                try appendHex(arena, &d.thr, t.word() orelse return error.Malformed);
            } else return error.Malformed;
        } else {
            // Nieznana instrukcja z przyszłej wersji: pomijamy (zgodność w przód).
        }
    }
    if (!saw_magic) return error.BadMagic;
    if (smb.items.len > 0) s.smbios = smb.items;
    s.pci = pci.items;
    s.gpus = gpus.items;
    const out = try arena.alloc(snap.DiskRaw, disks.items.len);
    for (disks.items, 0..) |*d, i| {
        out[i] = d.raw;
        out[i].descriptor = d.desc.items;
        if (d.nvme.items.len > 0) out[i].nvme_log = d.nvme.items;
        if (d.smart.items.len > 0) out[i].ata_smart = d.smart.items;
        if (d.thr.items.len > 0) out[i].ata_thresholds = d.thr.items;
    }
    s.disks = out;
    return s;
}

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

const testing = std.testing;

test "sysimg: zapis i odczyt zachowują dane surowe" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var desc = [_]u8{0} ** 64;
    std.mem.writeInt(u32, desc[24..28], 40, .little);
    @memcpy(desc[40..52], "SER123456789");
    const pci = [_]snap.PciDevice{.{ .bus = 0x0e, .vendor = 0x1002, .device = 0x744c, .subvendor = 0x1849, .subdevice = 0x5304, .revision = 0xc8, .class = 3, .subclass = 0, .progif = 0, .link_cur_width = 16, .link_cur_speed = 4, .desc = "Karta \"X\"", .driver_version = "32.0" }};
    const gpus = [_]snap.GpuAdapter{.{ .vendor = 0x1002, .device = 0x744c, .subsys = 0x53041849, .revision = 0xc8, .dedicated_vram = 25 << 30, .name = "AMD Radeon RX 7900 XTX" }};
    const nvme = [_]u8{0xAB} ** 512;
    const disks = [_]snap.DiskRaw{.{ .index = 3, .size_bytes = 1_000_000, .descriptor = &desc, .nvme_log = &nvme, .health = .ok, .health_source = "NVMe", .rotational = false }};
    const s: snap.Snapshot = .{ .pci = &pci, .gpus = &gpus, .disks = &disks, .smbios = &[_]u8{ 0, 3, 3, 0, 0, 0, 0, 0 }, .smbios_status = .ok };

    const m = try masked(arena, s);
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(&out.writer, m, "test");
    const text = out.written();
    try testing.expect(std.mem.indexOf(u8, text, "53455231") == null); // „SER1” hex — zamaskowany

    const r = try parse(arena, text);
    try testing.expect(r.serials_masked);
    try testing.expectEqual(@as(usize, 1), r.pci.len);
    try testing.expectEqual(@as(u16, 0x744c), r.pci[0].device);
    try testing.expectEqual(@as(?u32, 16), r.pci[0].link_cur_width);
    try testing.expectEqual(@as(?u32, null), r.pci[0].link_max_width);
    try testing.expectEqualStrings("Karta \"X\"", r.pci[0].desc);
    try testing.expectEqual(@as(u64, 25 << 30), r.gpus[0].dedicated_vram);
    try testing.expectEqual(@as(usize, 1), r.disks.len);
    try testing.expectEqual(@as(u32, 3), r.disks[0].index);
    try testing.expectEqual(@as(usize, 512), r.disks[0].nvme_log.?.len);
    try testing.expectEqualStrings("XXXXXXXXXXXX", r.disks[0].descriptor[40..52]);
    try testing.expectEqual(@as(usize, 8), r.smbios.?.len);
}

test "sysimg: zły nagłówek i uszkodzone linie" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectError(error.BadMagic, parse(a, "ferrum-cpuimg 1\n"));
    try testing.expectError(error.UnsupportedFormat, parse(a, "ferrum-sysimg 9\n"));
    try testing.expectError(error.Malformed, parse(a, "ferrum-sysimg 1\nsmbios 0g\n"));
    try testing.expectError(error.Malformed, parse(a, "ferrum-sysimg 1\npci 1 2\n"));
    const ok = try parse(a, "ferrum-sysimg 1\nfuture-thing 1 2 3\n");
    try testing.expectEqual(@as(usize, 0), ok.pci.len);
}
