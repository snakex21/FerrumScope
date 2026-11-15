//! Wspólny model wyników dla bibliotek producentów GPU (AMD ADL, NVIDIA NVAPI).
//!
//! Oba moduły (`adl.zig`, `nvapi.zig`) ładują DLL producenta dynamicznie
//! w czasie działania i zwracają dane w tym samym kształcie, żeby GUI/integrator
//! mógł je połączyć z listą adapterów z DXGI/SetupAPI po lokalizacji PCI
//! (bus/device/function) albo po parze vendor_id/device_id.
//!
//! ## Zasady
//!
//! * Każdy odczyt jest opcjonalny (`?Reading`). Brak wartości = biblioteka nie
//!   podała jej albo podała coś nieprawdopodobnego (patrz `plausible`).
//! * Każdy odczyt niesie `source` — stały napis mówiący, z którego API i którego
//!   pola/czujnika pochodzi wartość. Dzięki temu w GUI widać, skąd liczba.
//! * Teksty (nazwa adaptera, typ VRAM, wersja sterownika) trzymamy w buforach
//!   o stałej długości wewnątrz struktur — kopiowanie struktury jest bezpieczne,
//!   a `poll` nie alokuje.
//! * Moduły są **tylko do odczytu**: nie wywołują żadnej funkcji typu Set,
//!   sterowania wentylatorem, zegarami ani resetu.

const std = @import("std");
const builtin = @import("builtin");

/// Pojedynczy odczyt liczbowy z jednostką i źródłem.
pub const Reading = struct {
    value: f64,
    /// Jednostka, np. "MHz", "C", "RPM", "%", "W", "V", "B".
    unit: []const u8,
    /// Pochodzenie, np. "ADL OD8 PMLog ADL_PMLOG_TEMPERATURE_EDGE".
    source: []const u8,
};

/// Krótki tekst o stałej pojemności — kopiowalny, bez alokacji.
pub const Text = struct {
    pub const capacity = 128;

    buf: [capacity]u8 = [_]u8{0} ** capacity,
    len: u8 = 0,

    pub fn slice(self: *const Text) []const u8 {
        return self.buf[0..self.len];
    }

    /// Kopiuje tekst z bufora C (do pierwszego NUL), odrzucając znaki spoza
    /// drukowalnego ASCII i przycinając białe znaki. Chroni przed śmieciami
    /// zwróconymi przez sterownik (brak terminatora, bajty sterujące).
    pub fn fromC(raw: []const u8) Text {
        var t: Text = .{};
        const end = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
        for (raw[0..end]) |c| {
            if (t.len >= capacity) break;
            t.buf[t.len] = if (c >= 0x20 and c < 0x7f) c else '?';
            t.len += 1;
        }
        const trimmed = std.mem.trim(u8, t.buf[0..t.len], " \t");
        if (trimmed.len != t.len) {
            var out: Text = .{};
            @memcpy(out.buf[0..trimmed.len], trimmed);
            out.len = @intCast(trimmed.len);
            return out;
        }
        return t;
    }

    /// Formatuje tekst; zbyt długi wynik jest obcinany, nigdy nie zawodzi.
    pub fn print(comptime fmt: []const u8, args: anytype) Text {
        var t: Text = .{};
        const s = std.fmt.bufPrint(&t.buf, fmt, args) catch t.buf[0..];
        t.len = @intCast(s.len);
        return t;
    }

    pub fn isEmpty(self: *const Text) bool {
        return self.len == 0;
    }
};

/// Odczyt tekstowy (typ VRAM, wersja sterownika) — odpowiednik `Reading`
/// dla wartości, które nie są liczbą.
pub const TextReading = struct {
    text: Text,
    source: []const u8,
};

/// Lokalizacja PCI adaptera — klucz do złączenia z listą DXGI/SetupAPI.
pub const PciLocation = struct {
    bus: u32,
    device: u32,
    function: u32,

    pub fn eql(a: PciLocation, b: PciLocation) bool {
        return a.bus == b.bus and a.device == b.device and a.function == b.function;
    }
};

/// Wszystkie odczyty adaptera. Pola "dynamiczne" odświeża `poll`, a pola
/// statyczne (`vram_*`, `driver_version`) są ustalane raz przy `open`.
pub const Readings = struct {
    // --- dynamiczne ---
    gpu_clock_mhz: ?Reading = null,
    mem_clock_mhz: ?Reading = null,
    temp_edge_c: ?Reading = null,
    temp_hotspot_c: ?Reading = null,
    temp_mem_c: ?Reading = null,
    fan_rpm: ?Reading = null,
    fan_percent: ?Reading = null,
    load_percent: ?Reading = null,
    power_w: ?Reading = null,
    voltage_v: ?Reading = null,
    // --- statyczne ---
    vram_bytes: ?Reading = null,
    vram_type: ?TextReading = null,
    driver_version: ?TextReading = null,
    /// VBIOS karty (ADL `ADL2_Adapter_VideoBiosInfo_Get`, NVAPI
    /// `NvAPI_GPU_GetVbiosVersionString`). Numer części AMD ma postać
    /// „113-…” i często wskazuje dokładny model karty producenta.
    vbios_part_number: ?TextReading = null,
    vbios_version: ?TextReading = null,
    vbios_date: ?TextReading = null,

    /// Zeruje tylko pola dynamiczne (przed kolejnym `poll`).
    pub fn clearDynamic(self: *Readings) void {
        self.gpu_clock_mhz = null;
        self.mem_clock_mhz = null;
        self.temp_edge_c = null;
        self.temp_hotspot_c = null;
        self.temp_mem_c = null;
        self.fan_rpm = null;
        self.fan_percent = null;
        self.load_percent = null;
        self.power_w = null;
        self.voltage_v = null;
    }
};

/// Jeden fizyczny adapter widziany przez bibliotekę producenta.
pub const Adapter = struct {
    /// "ADL" albo "NVAPI".
    vendor_library: []const u8,
    name: Text = .{},
    pci: ?PciLocation = null,
    vendor_id: ?u16 = null,
    device_id: ?u16 = null,
    /// SUBSYS w formacie Windows: (subsystem_id << 16) | subsystem_vendor_id.
    subsys_id: ?u32 = null,
    revision: ?u8 = null,
    /// Indeks/uchwyt w natywnym API (ADL iAdapterIndex, NVAPI indeks GPU) —
    /// tylko diagnostyka.
    native_index: i32 = -1,
    /// Ścieżka odczytu sensorów, np. "OD8 PMLog", "OverdriveN", "Overdrive5".
    sensor_path: []const u8 = "none",
    readings: Readings = .{},
};

/// Stan biblioteki producenta.
pub const Status = union(enum) {
    available,
    dll_not_found,
    /// Kod błędu zwrócony przez funkcję inicjalizującą (ADL_ERR_*, NvAPI_Status).
    init_failed: i32,
    no_adapters,
    unsupported_api,
};

pub const LibraryInfo = struct {
    /// Nazwa DLL, np. "atiadlxx.dll".
    name: []const u8,
    /// Wersja (sterownika/interfejsu) zgłoszona przez bibliotekę, jeśli znana.
    version: Text = .{},
    status: Status = .dll_not_found,
    /// Czytelny dla człowieka opis stanu (stały napis).
    reason: []const u8 = "",
};

/// Wynik jednorazowego zapytania. Pamięć `adapters` należy do alokatora
/// przekazanego do `query`; zwolnij przez `deinit`.
pub const Result = struct {
    library: LibraryInfo,
    adapters: []Adapter = &.{},

    pub fn deinit(self: *Result, alloc: std.mem.Allocator) void {
        alloc.free(self.adapters);
        self.adapters = &.{};
    }
};

// ---------------------------------------------------------------------------
// Walidacja wartości
// ---------------------------------------------------------------------------

/// Zakres wiarygodności dla danej jednostki. Wartości spoza zakresu traktujemy
/// jako śmieci ze sterownika i odrzucamy (lepiej "brak" niż 65535 C).
pub fn plausible(unit: []const u8, v: f64) bool {
    if (std.math.isNan(v) or std.math.isInf(v)) return false;
    const R = struct { u: []const u8, lo: f64, hi: f64 };
    const table = [_]R{
        .{ .u = "MHz", .lo = 0, .hi = 20000 },
        .{ .u = "C", .lo = -60, .hi = 200 },
        .{ .u = "RPM", .lo = 0, .hi = 20000 },
        .{ .u = "%", .lo = 0, .hi = 100 },
        .{ .u = "W", .lo = 0, .hi = 3000 },
        .{ .u = "V", .lo = 0, .hi = 3 },
        .{ .u = "B", .lo = 1, .hi = 1 << 50 },
    };
    for (table) |r| {
        if (std.mem.eql(u8, r.u, unit)) return v >= r.lo and v <= r.hi;
    }
    return true;
}

/// Tworzy odczyt, jeśli wartość jest wiarygodna dla jednostki.
pub fn reading(value: f64, unit: []const u8, source: []const u8) ?Reading {
    if (!plausible(unit, value)) return null;
    return .{ .value = value, .unit = unit, .source = source };
}

// ---------------------------------------------------------------------------
// Ciąg PnP Windows ("PCI\VEN_1002&DEV_744C&SUBSYS_0E3A1002&REV_C8\...")
// ---------------------------------------------------------------------------

pub const PnpIds = struct {
    vendor_id: ?u16 = null,
    device_id: ?u16 = null,
    subsys_id: ?u32 = null,
    revision: ?u8 = null,
};

/// Wyciąga VEN/DEV/SUBSYS/REV z identyfikatora sprzętu PnP. Wielkość liter
/// bez znaczenia; nieznane lub uszkodzone pola zostają `null`.
pub fn parsePnpString(s: []const u8) PnpIds {
    var ids: PnpIds = .{};
    // Bierzemy tylko drugi segment ("VEN_..&DEV_..") — po "PCI\", przed
    // kolejnym "\" (który zaczyna identyfikator instancji).
    var seg = s;
    if (std.mem.indexOfScalar(u8, seg, '\\')) |i| seg = seg[i + 1 ..];
    if (std.mem.indexOfScalar(u8, seg, '\\')) |i| seg = seg[0..i];

    var it = std.mem.splitScalar(u8, seg, '&');
    while (it.next()) |tok| {
        if (keyValue(tok, "VEN_")) |v| ids.vendor_id = parseHex(u16, v, 4);
        if (keyValue(tok, "DEV_")) |v| ids.device_id = parseHex(u16, v, 4);
        if (keyValue(tok, "SUBSYS_")) |v| ids.subsys_id = parseHex(u32, v, 8);
        if (keyValue(tok, "REV_")) |v| ids.revision = parseHex(u8, v, 2);
    }
    return ids;
}

fn keyValue(tok: []const u8, key: []const u8) ?[]const u8 {
    if (tok.len < key.len) return null;
    if (!std.ascii.eqlIgnoreCase(tok[0..key.len], key)) return null;
    return tok[key.len..];
}

fn parseHex(comptime T: type, v: []const u8, digits: usize) ?T {
    if (v.len < digits) return null;
    return std.fmt.parseInt(T, v[0..digits], 16) catch null;
}

// ---------------------------------------------------------------------------
// Ładowanie DLL
//
// Używamy bezpośrednio `kernel32.LoadLibraryExW` z flagą
// `LOAD_LIBRARY_SEARCH_SYSTEM32` (0x800), a nie `std.DynLib`:
//   * biblioteki producentów leżą w System32 — ta flaga wyklucza podłożenie
//     DLL z katalogu programu / CWD (DLL planting),
//   * `std.os.windows.FreeLibrary` ma `assert` na wyniku, a my chcemy, żeby
//     zamykanie nigdy nie przerywało procesu.
// ---------------------------------------------------------------------------

pub const HMODULE = if (builtin.os.tag == .windows) std.os.windows.HMODULE else *opaque {};

const LOAD_LIBRARY_SEARCH_SYSTEM32: u32 = 0x00000800;

/// Ładuje DLL z System32. `null`, gdy brak pliku (lub nie-Windows).
pub fn loadSystemDll(comptime name: []const u8) ?HMODULE {
    if (builtin.os.tag != .windows) return null;
    const w = std.unicode.utf8ToUtf16LeStringLiteral(name);
    return std.os.windows.kernel32.LoadLibraryExW(w, null, LOAD_LIBRARY_SEARCH_SYSTEM32);
}

pub fn freeDll(h: HMODULE) void {
    if (builtin.os.tag != .windows) return;
    _ = std.os.windows.kernel32.FreeLibrary(h);
}

/// Pobiera eksport jako wskaźnik funkcji typu `F` (np. `*const fn (...) callconv(.c) i32`).
pub fn getProc(comptime F: type, h: HMODULE, comptime name: [:0]const u8) ?F {
    if (builtin.os.tag != .windows) return null;
    const p = std.os.windows.kernel32.GetProcAddress(h, name.ptr) orelse return null;
    return @ptrCast(@alignCast(p));
}

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

test "parsePnpString: pełny identyfikator AMD" {
    const ids = parsePnpString("PCI\\VEN_1002&DEV_744C&SUBSYS_0E3A1002&REV_C8\\6&2B1A5C3D&0&00000019");
    try std.testing.expectEqual(@as(?u16, 0x1002), ids.vendor_id);
    try std.testing.expectEqual(@as(?u16, 0x744C), ids.device_id);
    try std.testing.expectEqual(@as(?u32, 0x0E3A1002), ids.subsys_id);
    try std.testing.expectEqual(@as(?u8, 0xC8), ids.revision);
}

test "parsePnpString: małe litery, brak REV, śmieci" {
    const a = parsePnpString("pci\\ven_10de&dev_2684&subsys_16f310de");
    try std.testing.expectEqual(@as(?u16, 0x10DE), a.vendor_id);
    try std.testing.expectEqual(@as(?u16, 0x2684), a.device_id);
    try std.testing.expectEqual(@as(?u32, 0x16F310DE), a.subsys_id);
    try std.testing.expectEqual(@as(?u8, null), a.revision);

    const b = parsePnpString("");
    try std.testing.expectEqual(@as(?u16, null), b.vendor_id);

    const c = parsePnpString("PCI\\VEN_ZZZZ&DEV_12&REV_");
    try std.testing.expectEqual(@as(?u16, null), c.vendor_id);
    try std.testing.expectEqual(@as(?u16, null), c.device_id);
    try std.testing.expectEqual(@as(?u8, null), c.revision);
}

test "Text.fromC: NUL, brak terminatora, bajty sterujące, trim" {
    const t1 = Text.fromC("AMD Radeon RX 7900 XTX\x00garbage");
    try std.testing.expectEqualStrings("AMD Radeon RX 7900 XTX", t1.slice());
    const t2 = Text.fromC("  ab\x01c  ");
    try std.testing.expectEqualStrings("ab?c", t2.slice());
    const long = [_]u8{'x'} ** 300;
    const t3 = Text.fromC(&long);
    try std.testing.expectEqual(@as(usize, Text.capacity), t3.slice().len);
}

test "plausible / reading" {
    try std.testing.expect(reading(55, "C", "t") != null);
    try std.testing.expect(reading(65535, "C", "t") == null);
    try std.testing.expect(reading(101, "%", "t") == null);
    try std.testing.expect(reading(std.math.nan(f64), "MHz", "t") == null);
    try std.testing.expect(reading(1.1, "V", "t") != null);
}
