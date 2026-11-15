//! Format binarnej bazy PCI ID (`ferrum-pciids.bin`) oraz jej kompilator.
//!
//! Plik jest współdzielony przez dwie strony:
//!   * `tools/pciids_compile.zig` (build step) — parsuje `pci.ids` funkcją
//!     `parse` i serializuje wynik funkcją `serialize`;
//!   * `src/sys/pciids.zig` (runtime) — czyta obraz, korzystając ze stałych
//!     układu zdefiniowanych tutaj.
//!
//! Dlaczego osobny plik, a nie import kompilatora z testów runtime: Zig 0.15
//! nie pozwala importować plików spoza katalogu modułu (`../../tools/...`
//! z modułu zakorzenionego w `src/`). Narzędzie dostaje ten plik jako nazwany
//! moduł `pciids_format`, a runtime importuje go ścieżką względną. Zmiana
//! układu psuje więc kompilację obu stron naraz.
//!
//! Układ obrazu (wszystkie liczby little-endian, rekordy bez wyrównania):
//!
//!   nagłówek (`header_size` = 96 B):
//!     0  magic[8]            "FSPCIDB\x00"
//!     8  format_version u16  `format_version`
//!     10 header_size u16
//!     12 total_size u32      długość całego obrazu
//!     16 liczniki u32 x6     vendor, device, subsystem, class, subclass, progif
//!     40 offsety u32 x6      początki tabel w tej samej kolejności
//!     64 pool_off u32, pool_len u32
//!     72 StrRef version      (off u32 + len u16, względem puli)
//!     78 StrRef date
//!     84 StrRef attribution
//!     90 zarezerwowane u16 (0)
//!     92 crc32 u32           CRC-32 (ISO-HDLC) bajtów [header_size..total_size)
//!
//!   tabele (posortowane rosnąco po kluczu, gotowe do wyszukiwania binarnego):
//!     vendor    16 B: vid u16, name StrRef, dev_first u32, dev_count u32
//!     device    14 B: did u16, name StrRef, sub_first u32, sub_count u16
//!     subsystem 10 B: svid u16, sdid u16, name StrRef
//!     class     12 B: class u8, 0 u8, name StrRef, sub_first u16, sub_count u16
//!     subclass  12 B: sub u8, 0 u8, name StrRef, pi_first u16, pi_count u16
//!     progif     8 B: pi u8, 0 u8, name StrRef
//!   pula napisów: zdeduplikowane nazwy w UTF-8, bez terminatora.
//!
//! Urządzenia jednego producenta tworzą ciągły zakres `[dev_first,
//! dev_first+dev_count)` posortowany po `did`; analogicznie podsystemy
//! urządzenia (po `svid`, `sdid`), podklasy klasy i interfejsy podklasy.

const std = @import("std");

pub const magic = "FSPCIDB\x00";
pub const format_version: u16 = 1;
pub const header_size: usize = 96;

pub const str_ref_size: usize = 6;
pub const vendor_rec_size: usize = 16;
pub const device_rec_size: usize = 14;
pub const subsys_rec_size: usize = 10;
pub const class_rec_size: usize = 12;
pub const subclass_rec_size: usize = 12;
pub const progif_rec_size: usize = 8;

/// Offsety pól nagłówka — jedno źródło prawdy dla zapisu i odczytu.
pub const Hdr = struct {
    pub const version = 8;
    pub const hsize = 10;
    pub const total = 12;
    pub const counts = 16; // 6 x u32
    pub const offsets = 40; // 6 x u32
    pub const pool_off = 64;
    pub const pool_len = 68;
    pub const version_ref = 72;
    pub const date_ref = 78;
    pub const attribution_ref = 84;
    pub const crc = 92;
};

/// Indeksy tabel w tablicach liczników i offsetów nagłówka.
pub const Table = enum(u3) { vendor, device, subsystem, class, subclass, progif };

pub const table_rec_sizes = [_]usize{
    vendor_rec_size,
    device_rec_size,
    subsys_rec_size,
    class_rec_size,
    subclass_rec_size,
    progif_rec_size,
};

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

pub const Vendor = struct { vid: u16, name: []const u8 };
pub const Device = struct { vid: u16, did: u16, name: []const u8 };
pub const Subsystem = struct { vid: u16, did: u16, svid: u16, sdid: u16, name: []const u8 };
pub const Class = struct { class: u8, name: []const u8 };
pub const Subclass = struct { class: u8, sub: u8, name: []const u8 };
pub const ProgIf = struct { class: u8, sub: u8, pi: u8, name: []const u8 };

/// Ile numerów błędnych linii zapamiętujemy do raportu (licznik jest pełny).
pub const max_reported_malformed = 32;

/// Wynik parsowania: tabele posortowane i zdeduplikowane (wygrywa pierwszy
/// wpis z pliku). Nazwy wskazują **w tekst wejściowy** — tekst musi żyć co
/// najmniej tak długo jak `Parsed`.
pub const Parsed = struct {
    vendors: []Vendor,
    devices: []Device,
    subsystems: []Subsystem,
    classes: []Class,
    subclasses: []Subclass,
    progifs: []ProgIf,
    /// Wartość z linii `#\tVersion: ...` nagłówka (pusta, gdy brak).
    version: []const u8,
    /// Wartość z linii `#\tDate: ...` nagłówka (pusta, gdy brak).
    date: []const u8,
    /// Blok komentarzy z początku pliku (licencja i autorzy), linie dosłownie,
    /// rozdzielone `\n`, bez `\r`.
    attribution: []const u8,
    /// Liczba odrzuconych duplikatów (wszystkie poziomy razem).
    duplicates: u32,
    /// Liczba linii, których nie dało się zinterpretować.
    malformed: u32,
    /// Numery (od 1) pierwszych `max_reported_malformed` błędnych linii.
    malformed_lines: []u32,

    pub fn deinit(self: *Parsed, gpa: std.mem.Allocator) void {
        gpa.free(self.vendors);
        gpa.free(self.devices);
        gpa.free(self.subsystems);
        gpa.free(self.classes);
        gpa.free(self.subclasses);
        gpa.free(self.progifs);
        gpa.free(self.attribution);
        gpa.free(self.malformed_lines);
        self.* = undefined;
    }
};

fn parseHex(comptime T: type, s: []const u8) ?T {
    if (s.len != @sizeOf(T) * 2) return null;
    var v: T = 0;
    for (s) |c| {
        const d: T = switch (c) {
            '0'...'9' => @intCast(c - '0'),
            'a'...'f' => @intCast(c - 'a' + 10),
            'A'...'F' => @intCast(c - 'A' + 10),
            else => return null,
        };
        v = (v << 4) | d;
    }
    return v;
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Rozbiera `<hex o długości n><białe znaki><nazwa>`. Zwraca null, gdy brak
/// separatora albo nazwa jest pusta.
fn splitIdName(comptime T: type, s: []const u8) ?struct { id: T, name: []const u8 } {
    const n = @sizeOf(T) * 2;
    if (s.len < n + 2) return null;
    const id = parseHex(T, s[0..n]) orelse return null;
    if (!isWs(s[n])) return null;
    const name = std.mem.trim(u8, s[n..], " \t");
    if (name.len == 0) return null;
    return .{ .id = id, .name = name };
}

const Mode = enum { vendors, classes };

/// Parsuje tekst w formacie `pci.ids`. Nigdy nie przerywa na błędnej linii —
/// liczy ją i idzie dalej. Błąd zwraca wyłącznie przy braku pamięci.
pub fn parse(gpa: std.mem.Allocator, text: []const u8) !Parsed {
    var vendors: std.ArrayList(Vendor) = .empty;
    defer vendors.deinit(gpa);
    var devices: std.ArrayList(Device) = .empty;
    defer devices.deinit(gpa);
    var subsystems: std.ArrayList(Subsystem) = .empty;
    defer subsystems.deinit(gpa);
    var classes: std.ArrayList(Class) = .empty;
    defer classes.deinit(gpa);
    var subclasses: std.ArrayList(Subclass) = .empty;
    defer subclasses.deinit(gpa);
    var progifs: std.ArrayList(ProgIf) = .empty;
    defer progifs.deinit(gpa);
    var attribution: std.ArrayList(u8) = .empty;
    defer attribution.deinit(gpa);
    var bad_lines: std.ArrayList(u32) = .empty;
    defer bad_lines.deinit(gpa);

    var version: []const u8 = "";
    var date: []const u8 = "";
    var malformed: u32 = 0;

    var mode: Mode = .vendors;
    var cur_vendor: ?u16 = null;
    var cur_device: ?u16 = null;
    var cur_class: ?u8 = null;
    var cur_sub: ?u8 = null;
    var in_header = true;

    var it = std.mem.splitScalar(u8, text, '\n');
    var line_no: u32 = 0;
    while (it.next()) |raw| {
        line_no += 1;
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        line = std.mem.trimRight(u8, line, " \t");

        // Nagłówek: ciągły blok komentarzy na samym początku pliku.
        if (in_header) {
            if (line.len > 0 and line[0] == '#') {
                if (attribution.items.len > 0) try attribution.append(gpa, '\n');
                try attribution.appendSlice(gpa, line);
                const body = std.mem.trim(u8, line[1..], " \t");
                if (std.mem.startsWith(u8, body, "Version:")) {
                    version = std.mem.trim(u8, body["Version:".len..], " \t");
                } else if (std.mem.startsWith(u8, body, "Date:")) {
                    date = std.mem.trim(u8, body["Date:".len..], " \t");
                }
                continue;
            }
            in_header = false;
        }

        if (line.len == 0) continue;
        var depth: usize = 0;
        while (depth < line.len and line[depth] == '\t') depth += 1;
        const body = line[depth..];
        if (body.len == 0 or body[0] == '#') continue;

        const ok: bool = switch (depth) {
            0 => blk: {
                if (body.len >= 2 and body[0] == 'C' and isWs(body[1])) {
                    mode = .classes;
                    cur_vendor = null;
                    cur_device = null;
                    cur_sub = null;
                    const r = splitIdName(u8, std.mem.trimLeft(u8, body[1..], " \t")) orelse {
                        cur_class = null;
                        break :blk false;
                    };
                    cur_class = r.id;
                    try classes.append(gpa, .{ .class = r.id, .name = r.name });
                    break :blk true;
                }
                mode = .vendors;
                cur_class = null;
                cur_sub = null;
                cur_device = null;
                const r = splitIdName(u16, body) orelse {
                    cur_vendor = null;
                    break :blk false;
                };
                cur_vendor = r.id;
                try vendors.append(gpa, .{ .vid = r.id, .name = r.name });
                break :blk true;
            },
            1 => switch (mode) {
                .vendors => blk: {
                    const vid = cur_vendor orelse break :blk false;
                    const r = splitIdName(u16, body) orelse {
                        cur_device = null;
                        break :blk false;
                    };
                    cur_device = r.id;
                    try devices.append(gpa, .{ .vid = vid, .did = r.id, .name = r.name });
                    break :blk true;
                },
                .classes => blk: {
                    const c = cur_class orelse break :blk false;
                    const r = splitIdName(u8, body) orelse {
                        cur_sub = null;
                        break :blk false;
                    };
                    cur_sub = r.id;
                    try subclasses.append(gpa, .{ .class = c, .sub = r.id, .name = r.name });
                    break :blk true;
                },
            },
            2 => switch (mode) {
                .vendors => blk: {
                    const vid = cur_vendor orelse break :blk false;
                    const did = cur_device orelse break :blk false;
                    // `ssss ssss  nazwa` — dwa identyfikatory oddzielone spacją.
                    if (body.len < 10 or !isWs(body[4])) break :blk false;
                    const svid = parseHex(u16, body[0..4]) orelse break :blk false;
                    const rest = std.mem.trimLeft(u8, body[4..], " \t");
                    const r = splitIdName(u16, rest) orelse break :blk false;
                    try subsystems.append(gpa, .{
                        .vid = vid,
                        .did = did,
                        .svid = svid,
                        .sdid = r.id,
                        .name = r.name,
                    });
                    break :blk true;
                },
                .classes => blk: {
                    const c = cur_class orelse break :blk false;
                    const s = cur_sub orelse break :blk false;
                    const r = splitIdName(u8, body) orelse break :blk false;
                    try progifs.append(gpa, .{ .class = c, .sub = s, .pi = r.id, .name = r.name });
                    break :blk true;
                },
            },
            else => false,
        };
        if (!ok) {
            malformed += 1;
            if (bad_lines.items.len < max_reported_malformed) try bad_lines.append(gpa, line_no);
        }
    }

    var dups: u32 = 0;
    dups += sortDedupe(Vendor, vendors.items, vendorLess, &vendors);
    dups += sortDedupe(Device, devices.items, deviceLess, &devices);
    dups += sortDedupe(Subsystem, subsystems.items, subsysLess, &subsystems);
    dups += sortDedupe(Class, classes.items, classLess, &classes);
    dups += sortDedupe(Subclass, subclasses.items, subclassLess, &subclasses);
    dups += sortDedupe(ProgIf, progifs.items, progifLess, &progifs);

    return .{
        .vendors = try vendors.toOwnedSlice(gpa),
        .devices = try devices.toOwnedSlice(gpa),
        .subsystems = try subsystems.toOwnedSlice(gpa),
        .classes = try classes.toOwnedSlice(gpa),
        .subclasses = try subclasses.toOwnedSlice(gpa),
        .progifs = try progifs.toOwnedSlice(gpa),
        .version = version,
        .date = date,
        .attribution = try attribution.toOwnedSlice(gpa),
        .duplicates = dups,
        .malformed = malformed,
        .malformed_lines = try bad_lines.toOwnedSlice(gpa),
    };
}

fn vendorKey(v: Vendor) u64 {
    return v.vid;
}
fn deviceKey(d: Device) u64 {
    return (@as(u64, d.vid) << 16) | d.did;
}
fn subsysKey(s: Subsystem) u64 {
    return (@as(u64, s.vid) << 48) | (@as(u64, s.did) << 32) | (@as(u64, s.svid) << 16) | s.sdid;
}
fn classKey(c: Class) u64 {
    return c.class;
}
fn subclassKey(c: Subclass) u64 {
    return (@as(u64, c.class) << 8) | c.sub;
}
fn progifKey(c: ProgIf) u64 {
    return (@as(u64, c.class) << 16) | (@as(u64, c.sub) << 8) | c.pi;
}

fn vendorLess(_: void, a: Vendor, b: Vendor) bool {
    return vendorKey(a) < vendorKey(b);
}
fn deviceLess(_: void, a: Device, b: Device) bool {
    return deviceKey(a) < deviceKey(b);
}
fn subsysLess(_: void, a: Subsystem, b: Subsystem) bool {
    return subsysKey(a) < subsysKey(b);
}
fn classLess(_: void, a: Class, b: Class) bool {
    return classKey(a) < classKey(b);
}
fn subclassLess(_: void, a: Subclass, b: Subclass) bool {
    return subclassKey(a) < subclassKey(b);
}
fn progifLess(_: void, a: ProgIf, b: ProgIf) bool {
    return progifKey(a) < progifKey(b);
}

fn keyOf(comptime T: type, x: T) u64 {
    return switch (T) {
        Vendor => vendorKey(x),
        Device => deviceKey(x),
        Subsystem => subsysKey(x),
        Class => classKey(x),
        Subclass => subclassKey(x),
        ProgIf => progifKey(x),
        else => @compileError("nieobsługiwany typ"),
    };
}

/// Sortuje stabilnie (`std.mem.sort` to sortowanie blokowe, stabilne), więc
/// z równych kluczy pierwszy jest ten, który wystąpił w pliku wcześniej —
/// i tylko on zostaje. Zwraca liczbę usuniętych duplikatów.
fn sortDedupe(
    comptime T: type,
    items: []T,
    comptime less: fn (void, T, T) bool,
    list: *std.ArrayList(T),
) u32 {
    std.mem.sort(T, items, {}, less);
    if (items.len == 0) return 0;
    var w: usize = 1;
    for (items[1..]) |x| {
        if (keyOf(T, x) == keyOf(T, items[w - 1])) continue;
        items[w] = x;
        w += 1;
    }
    const removed: u32 = @intCast(items.len - w);
    list.shrinkRetainingCapacity(w);
    return removed;
}

// ---------------------------------------------------------------------------
// Serializacja
// ---------------------------------------------------------------------------

pub const SerializeError = error{ TooManyEntries, StringTooLong, PoolTooLarge } || std.mem.Allocator.Error;

const Pool = struct {
    bytes: std.ArrayList(u8) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,

    fn deinit(self: *Pool, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
        self.index.deinit(gpa);
    }

    /// Dodaje napis do puli (deduplikacja po treści) i zwraca jego referencję.
    fn add(self: *Pool, gpa: std.mem.Allocator, s: []const u8) SerializeError!struct { off: u32, len: u16 } {
        if (s.len > std.math.maxInt(u16)) return error.StringTooLong;
        const gop = try self.index.getOrPut(gpa, s);
        if (!gop.found_existing) {
            if (self.bytes.items.len + s.len > std.math.maxInt(u32)) return error.PoolTooLarge;
            gop.value_ptr.* = @intCast(self.bytes.items.len);
            try self.bytes.appendSlice(gpa, s);
        }
        return .{ .off = gop.value_ptr.*, .len = @intCast(s.len) };
    }
};

const Out = struct {
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,

    fn int(self: *Out, comptime T: type, v: T) !void {
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try self.buf.appendSlice(self.gpa, &b);
    }

    fn str(self: *Out, pool: *Pool, s: []const u8) !void {
        const r = try pool.add(self.gpa, s);
        try self.int(u32, r.off);
        try self.int(u16, r.len);
    }
};

fn putU32(buf: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, buf[at..][0..4], v, .little);
}

fn putRef(buf: []u8, at: usize, r: anytype) void {
    std.mem.writeInt(u32, buf[at..][0..4], r.off, .little);
    std.mem.writeInt(u16, buf[at + 4 ..][0..2], r.len, .little);
}

fn countU16(n: usize) SerializeError!u16 {
    return std.math.cast(u16, n) orelse error.TooManyEntries;
}

fn countU32(n: usize) SerializeError!u32 {
    return std.math.cast(u32, n) orelse error.TooManyEntries;
}

/// Serializuje wynik `parse` do obrazu binarnego opisanego na górze pliku.
/// Wynik należy do wywołującego (`gpa.free`).
pub fn serialize(gpa: std.mem.Allocator, p: *const Parsed) SerializeError![]u8 {
    var pool: Pool = .{};
    defer pool.deinit(gpa);
    var out: Out = .{ .gpa = gpa };
    errdefer out.buf.deinit(gpa);

    try out.buf.appendNTimes(gpa, 0, header_size);
    var offsets: [6]u32 = undefined;
    const counts = [6]usize{
        p.vendors.len,
        p.devices.len,
        p.subsystems.len,
        p.classes.len,
        p.subclasses.len,
        p.progifs.len,
    };

    // Vendor: zakres urządzeń wyznaczamy jednym przejściem — obie tabele są
    // posortowane po `vid`.
    offsets[0] = try countU32(out.buf.items.len);
    {
        var d: usize = 0;
        for (p.vendors) |v| {
            while (d < p.devices.len and p.devices[d].vid < v.vid) d += 1;
            const first = d;
            while (d < p.devices.len and p.devices[d].vid == v.vid) d += 1;
            try out.int(u16, v.vid);
            try out.str(&pool, v.name);
            try out.int(u32, try countU32(first));
            try out.int(u32, try countU32(d - first));
        }
    }

    offsets[1] = try countU32(out.buf.items.len);
    {
        var s: usize = 0;
        for (p.devices) |d| {
            const key = deviceKey(d);
            while (s < p.subsystems.len and (subsysKey(p.subsystems[s]) >> 32) < key) s += 1;
            const first = s;
            while (s < p.subsystems.len and (subsysKey(p.subsystems[s]) >> 32) == key) s += 1;
            try out.int(u16, d.did);
            try out.str(&pool, d.name);
            try out.int(u32, try countU32(first));
            try out.int(u16, try countU16(s - first));
        }
    }

    offsets[2] = try countU32(out.buf.items.len);
    for (p.subsystems) |s| {
        try out.int(u16, s.svid);
        try out.int(u16, s.sdid);
        try out.str(&pool, s.name);
    }

    offsets[3] = try countU32(out.buf.items.len);
    {
        var s: usize = 0;
        for (p.classes) |c| {
            while (s < p.subclasses.len and p.subclasses[s].class < c.class) s += 1;
            const first = s;
            while (s < p.subclasses.len and p.subclasses[s].class == c.class) s += 1;
            try out.int(u8, c.class);
            try out.int(u8, 0);
            try out.str(&pool, c.name);
            try out.int(u16, try countU16(first));
            try out.int(u16, try countU16(s - first));
        }
    }

    offsets[4] = try countU32(out.buf.items.len);
    {
        var i: usize = 0;
        for (p.subclasses) |sc| {
            const key = subclassKey(sc);
            while (i < p.progifs.len and (progifKey(p.progifs[i]) >> 8) < key) i += 1;
            const first = i;
            while (i < p.progifs.len and (progifKey(p.progifs[i]) >> 8) == key) i += 1;
            try out.int(u8, sc.sub);
            try out.int(u8, 0);
            try out.str(&pool, sc.name);
            try out.int(u16, try countU16(first));
            try out.int(u16, try countU16(i - first));
        }
    }

    offsets[5] = try countU32(out.buf.items.len);
    for (p.progifs) |pi| {
        try out.int(u8, pi.pi);
        try out.int(u8, 0);
        try out.str(&pool, pi.name);
    }

    const ver_ref = try pool.add(gpa, p.version);
    const date_ref = try pool.add(gpa, p.date);
    const attr_ref = try pool.add(gpa, p.attribution);

    const pool_off = try countU32(out.buf.items.len);
    const pool_len = try countU32(pool.bytes.items.len);
    try out.buf.appendSlice(gpa, pool.bytes.items);
    const total = try countU32(out.buf.items.len);

    const img = out.buf.items;
    @memcpy(img[0..magic.len], magic);
    std.mem.writeInt(u16, img[Hdr.version..][0..2], format_version, .little);
    std.mem.writeInt(u16, img[Hdr.hsize..][0..2], @intCast(header_size), .little);
    putU32(img, Hdr.total, total);
    for (counts, 0..) |c, i| putU32(img, Hdr.counts + 4 * i, try countU32(c));
    for (offsets, 0..) |o, i| putU32(img, Hdr.offsets + 4 * i, o);
    putU32(img, Hdr.pool_off, pool_off);
    putU32(img, Hdr.pool_len, pool_len);
    putRef(img, Hdr.version_ref, ver_ref);
    putRef(img, Hdr.date_ref, date_ref);
    putRef(img, Hdr.attribution_ref, attr_ref);
    putU32(img, Hdr.crc, std.hash.Crc32.hash(img[header_size..]));

    return out.buf.toOwnedSlice(gpa);
}

/// Wygoda dla testów i narzędzia: `parse` + `serialize` w jednym kroku.
pub fn compile(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    var p = try parse(gpa, text);
    defer p.deinit(gpa);
    return serialize(gpa, &p);
}

test "parseHex odrzuca złą długość i znaki" {
    try std.testing.expectEqual(@as(?u16, 0x10de), parseHex(u16, "10DE"));
    try std.testing.expectEqual(@as(?u16, null), parseHex(u16, "10d"));
    try std.testing.expectEqual(@as(?u8, null), parseHex(u8, "0g"));
}
