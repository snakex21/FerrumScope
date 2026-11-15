//! Odczyt osadzonej bazy PCI ID (obraz `ferrum-pciids.bin`).
//!
//! Obraz powstaje w czasie budowania (`tools/pciids_compile.zig`) z pliku
//! `db/source/pci/pci.ids` z PCI ID Repository (https://pci-ids.ucw.cz/),
//! dystrybuowanego na licencji GPL-2.0-or-later LUB BSD-3-Clause. Oryginalny
//! nagłówek z informacją o licencji i autorach jest zachowany w obrazie
//! i dostępny przez `Db.attribution()`.
//!
//! Czytnik nie alokuje: `Db` to zestaw slice'ów wskazujących w obraz.
//! `load` sprawdza nagłówek, sumę CRC i **wszystkie** referencje oraz
//! uporządkowanie tabel, więc późniejsze wyszukiwania mogą indeksować bez
//! dodatkowych sprawdzeń — uszkodzony obraz kończy się błędem, nie paniką.
//! Układ obrazu opisuje `pciids_format.zig`.

const std = @import("std");
const fmt = @import("pciids_format.zig");

pub const LoadError = error{
    TooShort,
    BadMagic,
    UnsupportedVersion,
    BadHeader,
    SizeMismatch,
    ChecksumMismatch,
    OutOfBounds,
    BadRange,
    NotSorted,
};

pub const Counts = struct {
    vendors: u32,
    devices: u32,
    subsystems: u32,
    classes: u32,
    subclasses: u32,
    progifs: u32,
};

fn rd16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn rd32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

pub const Db = struct {
    pool: []const u8,
    vendors: []const u8,
    devices: []const u8,
    subsystems: []const u8,
    classes: []const u8,
    subclasses: []const u8,
    progifs: []const u8,
    n: Counts,
    version_str: []const u8,
    date_str: []const u8,
    attribution_str: []const u8,

    /// Waliduje obraz i zwraca widok na niego. `bytes` musi żyć co najmniej
    /// tak długo jak zwrócony `Db` (zwykle to `@embedFile`, więc wiecznie).
    pub fn load(bytes: []const u8) LoadError!Db {
        if (bytes.len < fmt.header_size) return error.TooShort;
        if (!std.mem.eql(u8, bytes[0..fmt.magic.len], fmt.magic)) return error.BadMagic;
        if (rd16(bytes, fmt.Hdr.version) != fmt.format_version) return error.UnsupportedVersion;
        if (rd16(bytes, fmt.Hdr.hsize) != fmt.header_size) return error.BadHeader;
        if (rd32(bytes, fmt.Hdr.total) != bytes.len) return error.SizeMismatch;
        if (std.hash.Crc32.hash(bytes[fmt.header_size..]) != rd32(bytes, fmt.Hdr.crc)) return error.ChecksumMismatch;

        var tables: [6][]const u8 = undefined;
        var cnt: [6]u32 = undefined;
        for (0..6) |i| {
            cnt[i] = rd32(bytes, fmt.Hdr.counts + 4 * i);
            const off: usize = rd32(bytes, fmt.Hdr.offsets + 4 * i);
            const len = @as(usize, cnt[i]) * fmt.table_rec_sizes[i];
            if (off < fmt.header_size or off > bytes.len or len > bytes.len - off) return error.OutOfBounds;
            tables[i] = bytes[off..][0..len];
        }
        const pool_off: usize = rd32(bytes, fmt.Hdr.pool_off);
        const pool_len: usize = rd32(bytes, fmt.Hdr.pool_len);
        if (pool_off > bytes.len or pool_len > bytes.len - pool_off) return error.OutOfBounds;

        var db: Db = .{
            .pool = bytes[pool_off..][0..pool_len],
            .vendors = tables[0],
            .devices = tables[1],
            .subsystems = tables[2],
            .classes = tables[3],
            .subclasses = tables[4],
            .progifs = tables[5],
            .n = .{
                .vendors = cnt[0],
                .devices = cnt[1],
                .subsystems = cnt[2],
                .classes = cnt[3],
                .subclasses = cnt[4],
                .progifs = cnt[5],
            },
            .version_str = "",
            .date_str = "",
            .attribution_str = "",
        };
        db.version_str = try db.checkedStr(bytes, fmt.Hdr.version_ref);
        db.date_str = try db.checkedStr(bytes, fmt.Hdr.date_ref);
        db.attribution_str = try db.checkedStr(bytes, fmt.Hdr.attribution_ref);
        try db.validate();
        return db;
    }

    fn checkedStr(self: *const Db, b: []const u8, at: usize) LoadError![]const u8 {
        const off: usize = rd32(b, at);
        const len: usize = rd16(b, at + 4);
        if (off > self.pool.len or len > self.pool.len - off) return error.OutOfBounds;
        return self.pool[off..][0..len];
    }

    /// Sprawdza nazwy, zakresy dzieci i ścisłe uporządkowanie kluczy.
    fn validate(self: *const Db) LoadError!void {
        const S = struct {
            fn range(first: usize, count: usize, total: usize) LoadError!void {
                if (first > total or count > total - first) return error.BadRange;
            }
        };
        var prev: i64 = -1;
        for (0..self.n.vendors) |i| {
            const r = self.vendors[i * fmt.vendor_rec_size ..][0..fmt.vendor_rec_size];
            const vid = rd16(r, 0);
            if (vid <= prev) return error.NotSorted;
            prev = vid;
            _ = try self.checkedStr(r, 2);
            const first = rd32(r, 8);
            const count = rd32(r, 12);
            try S.range(first, count, self.n.devices);
            var pd: i64 = -1;
            for (first..first + count) |d| {
                const dr = self.devices[d * fmt.device_rec_size ..][0..fmt.device_rec_size];
                const did = rd16(dr, 0);
                if (did <= pd) return error.NotSorted;
                pd = did;
            }
        }
        for (0..self.n.devices) |i| {
            const r = self.devices[i * fmt.device_rec_size ..][0..fmt.device_rec_size];
            _ = try self.checkedStr(r, 2);
            const first = rd32(r, 8);
            const count = rd16(r, 12);
            try S.range(first, count, self.n.subsystems);
            var ps: i64 = -1;
            for (first..first + count) |s| {
                const sr = self.subsystems[s * fmt.subsys_rec_size ..][0..fmt.subsys_rec_size];
                const k: i64 = (@as(i64, rd16(sr, 0)) << 16) | rd16(sr, 2);
                if (k <= ps) return error.NotSorted;
                ps = k;
            }
        }
        for (0..self.n.subsystems) |i| {
            _ = try self.checkedStr(self.subsystems[i * fmt.subsys_rec_size ..][0..fmt.subsys_rec_size], 4);
        }
        prev = -1;
        for (0..self.n.classes) |i| {
            const r = self.classes[i * fmt.class_rec_size ..][0..fmt.class_rec_size];
            if (r[0] <= prev) return error.NotSorted;
            prev = r[0];
            _ = try self.checkedStr(r, 2);
            const first = rd16(r, 8);
            const count = rd16(r, 10);
            try S.range(first, count, self.n.subclasses);
            var ps: i64 = -1;
            for (first..first + count) |s| {
                const sub = self.subclasses[s * fmt.subclass_rec_size];
                if (sub <= ps) return error.NotSorted;
                ps = sub;
            }
        }
        for (0..self.n.subclasses) |i| {
            const r = self.subclasses[i * fmt.subclass_rec_size ..][0..fmt.subclass_rec_size];
            _ = try self.checkedStr(r, 2);
            const first = rd16(r, 8);
            const count = rd16(r, 10);
            try S.range(first, count, self.n.progifs);
            var pp: i64 = -1;
            for (first..first + count) |p| {
                const pi = self.progifs[p * fmt.progif_rec_size];
                if (pi <= pp) return error.NotSorted;
                pp = pi;
            }
        }
        for (0..self.n.progifs) |i| {
            _ = try self.checkedStr(self.progifs[i * fmt.progif_rec_size ..][0..fmt.progif_rec_size], 2);
        }
    }

    /// Nazwa z referencji już zwalidowanej w `load`.
    fn name(self: *const Db, rec: []const u8, at: usize) []const u8 {
        const off: usize = rd32(rec, at);
        const len: usize = rd16(rec, at + 4);
        return self.pool[off..][0..len];
    }

    /// Wyszukiwanie binarne w tablicy rekordów o stałym rozmiarze; `keyFn`
    /// czyta klucz z rekordu. Zwraca indeks względem `first`.
    fn search(
        table: []const u8,
        comptime rec_size: usize,
        first: usize,
        count: usize,
        key: u32,
        comptime keyFn: fn ([]const u8) u32,
    ) ?usize {
        var lo: usize = first;
        var hi: usize = first + count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const k = keyFn(table[mid * rec_size ..][0..rec_size]);
            if (k == key) return mid;
            if (k < key) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    fn key16(r: []const u8) u32 {
        return rd16(r, 0);
    }
    fn key8(r: []const u8) u32 {
        return r[0];
    }
    /// Klucz podsystemu: `svid << 16 | sdid` (rekord przechowuje oba jako u16 LE).
    fn keySub(r: []const u8) u32 {
        return (@as(u32, rd16(r, 0)) << 16) | rd16(r, 2);
    }

    fn vendorRec(self: *const Db, vid: u16) ?[]const u8 {
        const i = search(self.vendors, fmt.vendor_rec_size, 0, self.n.vendors, vid, key16) orelse return null;
        return self.vendors[i * fmt.vendor_rec_size ..][0..fmt.vendor_rec_size];
    }

    fn deviceRec(self: *const Db, vid: u16, did: u16) ?[]const u8 {
        const v = self.vendorRec(vid) orelse return null;
        const i = search(self.devices, fmt.device_rec_size, rd32(v, 8), rd32(v, 12), did, key16) orelse return null;
        return self.devices[i * fmt.device_rec_size ..][0..fmt.device_rec_size];
    }

    fn classRec(self: *const Db, class: u8) ?[]const u8 {
        const i = search(self.classes, fmt.class_rec_size, 0, self.n.classes, class, key8) orelse return null;
        return self.classes[i * fmt.class_rec_size ..][0..fmt.class_rec_size];
    }

    fn subclassRec(self: *const Db, class: u8, subclass: u8) ?[]const u8 {
        const c = self.classRec(class) orelse return null;
        const i = search(self.subclasses, fmt.subclass_rec_size, rd16(c, 8), rd16(c, 10), subclass, key8) orelse return null;
        return self.subclasses[i * fmt.subclass_rec_size ..][0..fmt.subclass_rec_size];
    }

    /// Nazwa producenta (`10de` -> "NVIDIA Corporation").
    pub fn vendorName(self: *const Db, vid: u16) ?[]const u8 {
        const r = self.vendorRec(vid) orelse return null;
        return self.name(r, 2);
    }

    /// Nazwa urządzenia danego producenta.
    pub fn deviceName(self: *const Db, vid: u16, did: u16) ?[]const u8 {
        const r = self.deviceRec(vid, did) orelse return null;
        return self.name(r, 2);
    }

    /// Nazwa podsystemu (karta/płyta konkretnego producenta) dla urządzenia
    /// `vid:did` o identyfikatorze podsystemu `svid:sdid`.
    pub fn subsystemName(self: *const Db, vid: u16, did: u16, svid: u16, sdid: u16) ?[]const u8 {
        const d = self.deviceRec(vid, did) orelse return null;
        const key = (@as(u32, svid) << 16) | sdid;
        const i = search(self.subsystems, fmt.subsys_rec_size, rd32(d, 8), rd16(d, 12), key, keySub) orelse return null;
        return self.name(self.subsystems[i * fmt.subsys_rec_size ..][0..fmt.subsys_rec_size], 4);
    }

    /// Nazwa klasy bazowej (`03` -> "Display controller").
    pub fn baseClassName(self: *const Db, class: u8) ?[]const u8 {
        const r = self.classRec(class) orelse return null;
        return self.name(r, 2);
    }

    /// Nazwa na najgłębszym **zażądanym** poziomie: podklasy, gdy `progif`
    /// jest null, albo interfejsu programowego w przeciwnym razie. Brak wpisu
    /// na tym poziomie daje null (bez cichego zejścia do poziomu wyżej —
    /// o fallbacku decyduje wywołujący, np. przez `baseClassName`).
    pub fn className(self: *const Db, class: u8, subclass: u8, progif: ?u8) ?[]const u8 {
        const s = self.subclassRec(class, subclass) orelse return null;
        const pi = progif orelse return self.name(s, 2);
        const i = search(self.progifs, fmt.progif_rec_size, rd16(s, 8), rd16(s, 10), pi, key8) orelse return null;
        return self.name(self.progifs[i * fmt.progif_rec_size ..][0..fmt.progif_rec_size], 2);
    }

    /// Wersja źródłowego `pci.ids` (linia `# Version:`), np. "2026.09.25".
    pub fn version(self: *const Db) []const u8 {
        return self.version_str;
    }

    /// Data źródłowego `pci.ids` (linia `# Date:`).
    pub fn date(self: *const Db) []const u8 {
        return self.date_str;
    }

    /// Oryginalny nagłówek `pci.ids` z licencją i autorami (do okna "O programie").
    pub fn attribution(self: *const Db) []const u8 {
        return self.attribution_str;
    }

    pub fn counts(self: *const Db) Counts {
        return self.n;
    }
};

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

const sample =
    "#\r\n" ++
    "#\tList of PCI IDs\r\n" ++
    "#\r\n" ++
    "#\tVersion: 2099.01.02\r\n" ++
    "#\tDate:    2099-01-02 03:04:05\r\n" ++
    "#\r\n" ++
    "#\tThis file can be distributed under either the GNU General Public License\r\n" ++
    "#\t(version 2 or higher) or the 3-clause BSD License.\r\n" ++
    "\r\n" ++
    "# Syntax:\n" ++
    "10de  NVIDIA Corporation\n" ++
    "\t2684  AD102 [GeForce RTX 4090]\n" ++
    "\t\t1043 889c  ROG Strix RTX 4090\n" ++
    "\t\t10de 167c  RTX 4090 Founders Edition\n" ++
    "\t1b80  GP104 [GeForce GTX 1080]\n" ++
    "1002  Advanced Micro Devices, Inc. [AMD/ATI]\n" ++
    "\t744c  Navi 31 [Radeon RX 7900 XT/7900 XTX]\n" ++
    "\t\t1849 5304  Radeon RX 7900 XTX Phantom Gaming\n" ++
    "\t\t1002 0e3b  Radeon RX 7900 XTX\n" ++
    "0001  Wrong\n" ++
    "C 03  Display controller\n" ++
    "\t00  VGA compatible controller\n" ++
    "\t\t00  VGA controller\n" ++
    "\t\t01  8514 controller\n" ++
    "\t02  3D controller\n" ++
    "C 01  Mass storage controller\n" ++
    "\t08  Non-Volatile memory controller\n" ++
    "\t\t01  NVMHCI\n" ++
    "\t\t02  NVM Express\n";

fn buildSample(gpa: std.mem.Allocator) ![]u8 {
    return fmt.compile(gpa, sample);
}

test "Db: wyszukiwanie producentów, urządzeń i podsystemów" {
    const gpa = std.testing.allocator;
    const img = try buildSample(gpa);
    defer gpa.free(img);
    const db = try Db.load(img);

    try std.testing.expectEqualStrings("NVIDIA Corporation", db.vendorName(0x10de).?);
    try std.testing.expectEqualStrings("Wrong", db.vendorName(0x0001).?);
    try std.testing.expectEqual(@as(?[]const u8, null), db.vendorName(0x8086));
    try std.testing.expectEqualStrings("AD102 [GeForce RTX 4090]", db.deviceName(0x10de, 0x2684).?);
    try std.testing.expectEqualStrings("GP104 [GeForce GTX 1080]", db.deviceName(0x10de, 0x1b80).?);
    try std.testing.expectEqual(@as(?[]const u8, null), db.deviceName(0x10de, 0x744c));
    try std.testing.expectEqualStrings("Navi 31 [Radeon RX 7900 XT/7900 XTX]", db.deviceName(0x1002, 0x744c).?);
    try std.testing.expectEqualStrings(
        "Radeon RX 7900 XTX Phantom Gaming",
        db.subsystemName(0x1002, 0x744c, 0x1849, 0x5304).?,
    );
    try std.testing.expectEqualStrings("Radeon RX 7900 XTX", db.subsystemName(0x1002, 0x744c, 0x1002, 0x0e3b).?);
    try std.testing.expectEqual(@as(?[]const u8, null), db.subsystemName(0x1002, 0x744c, 0x1849, 0x5305));
    try std.testing.expectEqual(@as(?[]const u8, null), db.subsystemName(0x10de, 0x1b80, 0x1043, 0x889c));

    const c = db.counts();
    try std.testing.expectEqual(@as(u32, 3), c.vendors);
    try std.testing.expectEqual(@as(u32, 3), c.devices);
    try std.testing.expectEqual(@as(u32, 4), c.subsystems);
    try std.testing.expectEqual(@as(u32, 2), c.classes);
    try std.testing.expectEqual(@as(u32, 3), c.subclasses);
    try std.testing.expectEqual(@as(u32, 4), c.progifs);
}

test "Db: klasy, wersja i nagłówek licencji" {
    const gpa = std.testing.allocator;
    const img = try buildSample(gpa);
    defer gpa.free(img);
    const db = try Db.load(img);

    try std.testing.expectEqualStrings("Display controller", db.baseClassName(0x03).?);
    try std.testing.expectEqualStrings("VGA compatible controller", db.className(0x03, 0x00, null).?);
    try std.testing.expectEqualStrings("VGA controller", db.className(0x03, 0x00, 0x00).?);
    try std.testing.expectEqualStrings("3D controller", db.className(0x03, 0x02, null).?);
    try std.testing.expectEqual(@as(?[]const u8, null), db.className(0x03, 0x02, 0x00));
    try std.testing.expectEqualStrings("NVM Express", db.className(0x01, 0x08, 0x02).?);
    try std.testing.expectEqual(@as(?[]const u8, null), db.className(0x02, 0x00, null));

    try std.testing.expectEqualStrings("2099.01.02", db.version());
    try std.testing.expectEqualStrings("2099-01-02 03:04:05", db.date());
    try std.testing.expect(std.mem.indexOf(u8, db.attribution(), "3-clause BSD License") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, db.attribution(), '\r') == null);
}

test "Db.load odrzuca uszkodzony obraz zamiast panikować" {
    const gpa = std.testing.allocator;
    const img = try buildSample(gpa);
    defer gpa.free(img);

    try std.testing.expectError(error.TooShort, Db.load(img[0..10]));
    try std.testing.expectError(error.SizeMismatch, Db.load(img[0 .. img.len - 1]));

    const bad = try gpa.dupe(u8, img);
    defer gpa.free(bad);

    bad[0] = 'X';
    try std.testing.expectError(error.BadMagic, Db.load(bad));
    @memcpy(bad, img);

    bad[fmt.Hdr.version] = 99;
    try std.testing.expectError(error.UnsupportedVersion, Db.load(bad));
    @memcpy(bad, img);

    bad[img.len - 1] ^= 0xFF;
    try std.testing.expectError(error.ChecksumMismatch, Db.load(bad));
    @memcpy(bad, img);

    // Licznik urządzeń poza obrazem — z poprawionym CRC, żeby dojść do
    // sprawdzania granic (CRC nie obejmuje nagłówka).
    std.mem.writeInt(u32, bad[fmt.Hdr.counts + 4 ..][0..4], 0x00FF_FFFF, .little);
    try std.testing.expectError(error.OutOfBounds, Db.load(bad));
    @memcpy(bad, img);

    // Zakres urządzeń producenta poza tabelą (CRC przeliczone ponownie).
    const voff = std.mem.readInt(u32, img[fmt.Hdr.offsets..][0..4], .little);
    std.mem.writeInt(u32, bad[voff + 12 ..][0..4], 1000, .little);
    std.mem.writeInt(u32, bad[fmt.Hdr.crc..][0..4], std.hash.Crc32.hash(bad[fmt.header_size..]), .little);
    try std.testing.expectError(error.BadRange, Db.load(bad));
    @memcpy(bad, img);

    // Zaburzona kolejność producentów.
    std.mem.writeInt(u16, bad[voff..][0..2], 0xFFFF, .little);
    std.mem.writeInt(u32, bad[fmt.Hdr.crc..][0..4], std.hash.Crc32.hash(bad[fmt.header_size..]), .little);
    try std.testing.expectError(error.NotSorted, Db.load(bad));
}

test "Db: pusta baza jest poprawna" {
    const gpa = std.testing.allocator;
    const img = try fmt.compile(gpa, "");
    defer gpa.free(img);
    const db = try Db.load(img);
    try std.testing.expectEqual(@as(?[]const u8, null), db.vendorName(0));
    try std.testing.expectEqual(@as(?[]const u8, null), db.className(0, 0, null));
    try std.testing.expectEqualStrings("", db.version());
}

test {
    _ = fmt;
}
