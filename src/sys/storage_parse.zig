//! Czyste parsery danych dyskowych — bez wywołań systemu operacyjnego.
//!
//! Wejściem są surowe bajty zwrócone przez system (albo odtworzone z pliku
//! replay), wyjściem — struktury z wartościami pochodnymi. Każda wartość
//! pochodna niesie źródło (skąd dokładnie wzięto bajty) i pewność
//! interpretacji, bo część atrybutów SMART jest specyficzna dla producenta.
//!
//! Obsługiwane formaty:
//!   * `STORAGE_DEVICE_DESCRIPTOR` (IOCTL_STORAGE_QUERY_PROPERTY,
//!     StorageDeviceProperty) — producent, model, firmware, numer seryjny,
//!     typ magistrali, flaga nośnika wymiennego.
//!   * NVMe SMART / Health Information (Log ID 02h, 512 B, NVMe Base Spec).
//!   * ATA SMART READ DATA (B0h/D0h, 512 B) i READ THRESHOLDS (B0h/D1h, 512 B).
//!
//! Wszystkie przesunięcia są sprawdzane względem długości bufora; uszkodzony
//! albo obcięty bufor daje błąd `Truncated` albo pole oznaczone jako
//! niedostępne — nigdy odczyt poza zakresem.

const std = @import("std");
const i18n = @import("../i18n/i18n.zig");

// ---------------------------------------------------------------------------
// Wspólne typy
// ---------------------------------------------------------------------------

/// Pewność interpretacji wartości pochodnej.
pub const Confidence = enum {
    /// Pole zdefiniowane w standardzie (NVMe, ATA) albo interpretacja
    /// stosowana jednolicie przez praktycznie wszystkich producentów.
    high,
    /// Interpretacja powszechna, ale znane są warianty producentów.
    medium,
    /// Interpretacja specyficzna dla producenta; może być błędna.
    low,

    pub fn toSlice(self: Confidence) []const u8 {
        return @tagName(self);
    }
};

/// Wartość pochodna ze źródłem i pewnością.
pub fn Derived(comptime T: type) type {
    return struct {
        value: T,
        /// Skąd wzięto wartość, np. "NVMe log 02h, bytes 1..2".
        source: []const u8,
        confidence: Confidence,
        /// Dodatkowe zastrzeżenie (warianty producentów itp.). Może być puste.
        note: []const u8 = "",
    };
}

/// Werdykt zdrowia dysku.
pub const HealthStatus = enum {
    /// Brak danych, z których dałoby się wyprowadzić werdykt.
    unknown,
    ok,
    warning,
    /// NVMe: niezerowe Critical Warning. ATA: atrybut poniżej progu
    /// („failing" w terminologii SMART).
    critical,

    pub fn toSlice(self: HealthStatus) []const u8 {
        return @tagName(self);
    }
};

/// Wspólne podsumowanie zdrowia dla NVMe i ATA — to, co integrator pokazuje
/// w interfejsie niezależnie od protokołu.
pub const HealthSummary = struct {
    status: HealthStatus = .unknown,
    /// Reguła, która zdecydowała o statusie (statyczny tekst).
    reason: []const u8 = "",
    /// ATA: identyfikator atrybutu, który spowodował status (0 = brak).
    trigger_attr: u8 = 0,

    temperature_c: ?Derived(i32) = null,
    power_on_hours: ?Derived(u64) = null,
    power_cycles: ?Derived(u64) = null,
    /// Zużycie w procentach (NVMe: może przekroczyć 100, maks. 255).
    percentage_used: ?Derived(u8) = null,
    data_read_bytes: ?Derived(u128) = null,
    data_written_bytes: ?Derived(u128) = null,
    unsafe_shutdowns: ?Derived(u64) = null,
    media_errors: ?Derived(u64) = null,
    reallocated: ?Derived(u64) = null,
    pending: ?Derived(u64) = null,
    uncorrectable: ?Derived(u64) = null,
};

pub const ParseError = error{Truncated};

/// Napis o stałej pojemności — wynik parsowania nie zależy od czasu życia
/// bufora wejściowego i nie wymaga alokatora.
pub const FixedStr = struct {
    pub const capacity = 96;

    buf: [capacity]u8 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const FixedStr) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set(self: *FixedStr, s: []const u8) void {
        const n = @min(s.len, capacity);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = @intCast(n);
    }
};

fn readU16(b: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, b[off..][0..2], .little);
}

fn readU32(b: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, b[off..][0..4], .little);
}

fn readU128(b: []const u8, off: usize) u128 {
    return std.mem.readInt(u128, b[off..][0..16], .little);
}

fn sat64(v: u128) u64 {
    return if (v > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(v);
}

// ---------------------------------------------------------------------------
// Maskowanie numerów seryjnych
// ---------------------------------------------------------------------------

/// Minimalna długość numeru seryjnego, przy której zostawiamy 2 pierwsze
/// i 2 ostatnie znaki. Krótsze numery maskujemy w całości — przy 6 znakach
/// odsłonięcie 4 ujawniałoby większość numeru.
pub const mask_min_len = 8;

/// Maskuje numer seryjny: zostawia 2 pierwsze i 2 ostatnie znaki, resztę
/// zastępuje `*`. Numery krótsze niż `mask_min_len` są maskowane w całości.
/// Wynik ma długość `min(s.len, buf.len)`; przy za małym buforze ostatnie
/// 2 znaki nadal trafiają na koniec wyniku.
pub fn maskSerial(s: []const u8, buf: []u8) []const u8 {
    const n = @min(s.len, buf.len);
    const out = buf[0..n];
    @memset(out, '*');
    if (s.len >= mask_min_len and n >= mask_min_len) {
        out[0] = s[0];
        out[1] = s[1];
        out[n - 2] = s[s.len - 2];
        out[n - 1] = s[s.len - 1];
    }
    return out;
}

// ---------------------------------------------------------------------------
// STORAGE_DEVICE_DESCRIPTOR
// ---------------------------------------------------------------------------

/// `STORAGE_BUS_TYPE` z winioctl.h. Wartości spoza listy mapujemy na `.unknown`
/// zachowując surową liczbę w `DeviceDescriptor.bus_type_raw`.
pub const BusType = enum(u32) {
    unknown = 0x00,
    scsi = 0x01,
    atapi = 0x02,
    ata = 0x03,
    ieee1394 = 0x04,
    ssa = 0x05,
    fibre = 0x06,
    usb = 0x07,
    raid = 0x08,
    iscsi = 0x09,
    sas = 0x0A,
    sata = 0x0B,
    sd = 0x0C,
    mmc = 0x0D,
    virtual = 0x0E,
    file_backed_virtual = 0x0F,
    spaces = 0x10,
    nvme = 0x11,
    scm = 0x12,
    ufs = 0x13,
    nvmeof = 0x14,
    max_reserved = 0x7F,
    _,

    pub fn fromRaw(v: u32) BusType {
        return @enumFromInt(v);
    }

    /// Nazwa jak w dokumentacji Microsoft (bez prefiksu `BusType`).
    pub fn name(self: BusType) []const u8 {
        return switch (self) {
            .unknown => i18n.t("Unknown"),
            .scsi => "SCSI",
            .atapi => "ATAPI",
            .ata => "ATA",
            .ieee1394 => "1394",
            .ssa => "SSA",
            .fibre => "Fibre",
            .usb => "USB",
            .raid => "RAID",
            .iscsi => "iSCSI",
            .sas => "SAS",
            .sata => "SATA",
            .sd => "SD",
            .mmc => "MMC",
            .virtual => i18n.t("Virtual"),
            .file_backed_virtual => "FileBackedVirtual",
            .spaces => "Spaces",
            .nvme => "NVMe",
            .scm => "SCM",
            .ufs => "UFS",
            .nvmeof => "NVMeoF",
            .max_reserved => "MaxReserved",
            _ => i18n.t("Unknown"),
        };
    }

    /// Czy numer seryjny mógł pochodzić z ATA IDENTIFY (słowa z zamienionymi
    /// bajtami).
    pub fn isAtaFamily(self: BusType) bool {
        return self == .ata or self == .sata or self == .atapi;
    }
};

/// Stan pojedynczego napisu w deskryptorze.
pub const StrStatus = enum {
    /// Przesunięcie 0 — urządzenie nie podało pola.
    absent,
    ok,
    /// Przesunięcie wskazuje w nagłówek deskryptora albo poza bufor.
    out_of_range,
};

/// Sposób, w jaki odczytano numer seryjny.
pub const SerialEncoding = enum {
    plain,
    /// Napis był zapisany szesnastkowo (starsze sterowniki ATA) — zdekodowany.
    hex,
    /// Zapis szesnastkowy surowych słów ATA — zdekodowany i z zamienionymi
    /// bajtami w parach.
    hex_byte_swapped,
};

pub const DeviceDescriptor = struct {
    /// Długość nagłówka `STORAGE_DEVICE_DESCRIPTOR` do pola
    /// `RawPropertiesLength` włącznie.
    pub const header_len = 36;
    /// `sizeof(STORAGE_DEVICE_DESCRIPTOR)` (z 1-bajtową tablicą i paddingiem).
    pub const struct_size = 40;

    version: u32 = 0,
    size: u32 = 0,
    device_type: u8 = 0,
    device_type_modifier: u8 = 0,
    removable: bool = false,
    command_queueing: bool = false,
    bus_type: BusType = .unknown,
    bus_type_raw: u32 = 0,

    vendor_id: FixedStr = .{},
    vendor_status: StrStatus = .absent,
    product_id: FixedStr = .{},
    product_status: StrStatus = .absent,
    product_revision: FixedStr = .{},
    revision_status: StrStatus = .absent,
    serial: FixedStr = .{},
    serial_status: StrStatus = .absent,
    serial_encoding: SerialEncoding = .plain,

    /// Nazwa modelu do wyświetlenia: `vendor product`, chyba że producent
    /// jest pusty, generyczny ("ATA", "NVMe") albo już jest prefiksem produktu.
    pub fn modelName(self: *const DeviceDescriptor, buf: []u8) []const u8 {
        const v = self.vendor_id.slice();
        const p = self.product_id.slice();
        const generic = v.len == 0 or std.ascii.eqlIgnoreCase(v, "ATA") or
            std.ascii.eqlIgnoreCase(v, "NVMe") or
            std.ascii.startsWithIgnoreCase(p, v);
        if (generic) {
            const n = @min(p.len, buf.len);
            @memcpy(buf[0..n], p[0..n]);
            return buf[0..n];
        }
        return std.fmt.bufPrint(buf, "{s} {s}", .{ v, p }) catch buf[0..0];
    }
};

/// Czyści napis z deskryptora: ucina na NUL, obcina spacje/tabulatory,
/// znaki niedrukowalne zamienia na '?'.
fn cleanInto(dst: *FixedStr, s: []const u8) void {
    const end = std.mem.indexOfScalar(u8, s, 0) orelse s.len;
    const t = std.mem.trim(u8, s[0..end], " \t\r\n");
    dst.set(t);
    for (dst.buf[0..dst.len]) |*c| {
        if (c.* < 0x20 or c.* > 0x7E) c.* = '?';
    }
}

fn readDescStr(bytes: []const u8, limit: usize, off: u32, dst: *FixedStr) StrStatus {
    if (off == 0) return .absent;
    if (off < DeviceDescriptor.header_len or off >= limit) return .out_of_range;
    cleanInto(dst, bytes[off..limit]);
    return .ok;
}

fn isHexDigit(c: u8) bool {
    return std.ascii.isHex(c);
}

/// Dekoduje numer seryjny zapisany szesnastkowo, jeśli wygląda na taki zapis.
/// Warunki: parzysta długość >= 8, same cyfry szesnastkowe, po dekodowaniu
/// same drukowalne ASCII i niepusty napis po obcięciu spacji. Prawdziwy numer
/// złożony z cyfr szesnastkowych (np. EUI-64 NVMe) daje po dekodowaniu bajty
/// niedrukowalne, więc zostaje bez zmian.
fn decodeHexSerial(s: []const u8, ata_family: bool, out: *FixedStr) ?SerialEncoding {
    if (s.len < 8 or s.len % 2 != 0) return null;
    for (s) |c| if (!isHexDigit(c)) return null;
    var tmp: [FixedStr.capacity]u8 = undefined;
    const n = s.len / 2;
    if (n > tmp.len) return null;
    for (0..n) |i| {
        const b = std.fmt.parseInt(u8, s[i * 2 ..][0..2], 16) catch return null;
        if (b < 0x20 or b > 0x7E) return null;
        tmp[i] = b;
    }
    // Surowe słowa ATA IDENTIFY są little-endian, a napis jest w nich zapisany
    // big-endian w obrębie słowa — stąd zamiana bajtów w parach.
    if (ata_family) {
        var i: usize = 0;
        while (i + 1 < n) : (i += 2) std.mem.swap(u8, &tmp[i], &tmp[i + 1]);
    }
    const t = std.mem.trim(u8, tmp[0..n], " ");
    if (t.len == 0) return null;
    out.set(t);
    return if (ata_family) .hex_byte_swapped else .hex;
}

/// Parsuje `STORAGE_DEVICE_DESCRIPTOR`. Pole `Size` ogranicza zakres napisów,
/// jeśli jest sensowne (>= nagłówek i <= długość bufora); w przeciwnym razie
/// granicą jest długość bufora.
pub fn parseDeviceDescriptor(bytes: []const u8) ParseError!DeviceDescriptor {
    if (bytes.len < DeviceDescriptor.header_len) return error.Truncated;
    var d: DeviceDescriptor = .{};
    d.version = readU32(bytes, 0);
    d.size = readU32(bytes, 4);
    d.device_type = bytes[8];
    d.device_type_modifier = bytes[9];
    d.removable = bytes[10] != 0;
    d.command_queueing = bytes[11] != 0;
    d.bus_type_raw = readU32(bytes, 28);
    d.bus_type = BusType.fromRaw(d.bus_type_raw);

    const limit: usize = if (d.size >= DeviceDescriptor.header_len and d.size <= bytes.len)
        d.size
    else
        bytes.len;

    d.vendor_status = readDescStr(bytes, limit, readU32(bytes, 12), &d.vendor_id);
    d.product_status = readDescStr(bytes, limit, readU32(bytes, 16), &d.product_id);
    d.revision_status = readDescStr(bytes, limit, readU32(bytes, 20), &d.product_revision);

    var raw_serial: FixedStr = .{};
    d.serial_status = readDescStr(bytes, limit, readU32(bytes, 24), &raw_serial);
    if (d.serial_status == .ok) {
        if (decodeHexSerial(raw_serial.slice(), d.bus_type.isAtaFamily(), &d.serial)) |enc| {
            d.serial_encoding = enc;
        } else {
            d.serial = raw_serial;
            d.serial_encoding = .plain;
        }
    }
    return d;
}

/// Odczytuje napis ATA IDENTIFY (słowa z zamienionymi bajtami) — np. słowa
/// 10..19 (numer seryjny), 23..26 (firmware), 27..46 (model).
pub fn ataIdentifyString(words: []const u8, out: *FixedStr) void {
    var tmp: [FixedStr.capacity]u8 = undefined;
    const n = @min(words.len & ~@as(usize, 1), tmp.len);
    var i: usize = 0;
    while (i + 1 < n) : (i += 2) {
        tmp[i] = words[i + 1];
        tmp[i + 1] = words[i];
    }
    cleanInto(out, tmp[0..n]);
}

// ---------------------------------------------------------------------------
// NVMe SMART / Health Information (Log ID 02h)
// ---------------------------------------------------------------------------

pub const nvme_log_size = 512;

/// Nazwy bitów Critical Warning (bajt 0), od bitu 0.
pub const nvme_critical_warning_names = [_][]const u8{
    i18n.N("available spare below threshold"),
    i18n.N("temperature outside threshold"),
    i18n.N("NVM subsystem reliability degraded"),
    i18n.N("media placed in read-only mode"),
    i18n.N("volatile memory backup device failed"),
    i18n.N("persistent memory region read-only"),
    i18n.N("reserved bit 6"),
    i18n.N("reserved bit 7"),
};

/// Zwraca listę nazw (przetłumaczonych) ustawionych bitów Critical Warning.
pub fn nvmeCriticalWarningList(cw: u8, out: *[8][]const u8) []const []const u8 {
    var n: usize = 0;
    for (0..8) |bit| {
        if (cw & (@as(u8, 1) << @intCast(bit)) != 0) {
            out[n] = i18n.t(nvme_critical_warning_names[bit]);
            n += 1;
        }
    }
    return out[0..n];
}

pub const NvmeHealth = struct {
    /// 1 data unit = 1000 * 512 B (NVMe Base Spec).
    pub const data_unit_bytes: u128 = 512_000;

    critical_warning: u8,
    composite_temp_k: u16,
    available_spare: u8,
    available_spare_threshold: u8,
    percentage_used: u8,
    endurance_group_critical_warning: u8,
    data_units_read: u128,
    data_units_written: u128,
    host_read_commands: u128,
    host_write_commands: u128,
    controller_busy_minutes: u128,
    power_cycles: u128,
    power_on_hours: u128,
    unsafe_shutdowns: u128,
    media_errors: u128,
    error_log_entries: u128,
    warning_temp_minutes: u32,
    critical_temp_minutes: u32,
    /// Czujniki 1..8 w kelwinach; 0 = czujnik niezaimplementowany.
    temp_sensors_k: [8]u16,

    summary: HealthSummary,

    /// Temperatura czujnika `i` (0..7) w °C albo null.
    pub fn sensorC(self: *const NvmeHealth, i: usize) ?i32 {
        const k = self.temp_sensors_k[i];
        return if (k == 0) null else kelvinToC(k);
    }

    pub fn bytesToTB(bytes: u128) f64 {
        return @as(f64, @floatFromInt(bytes)) / 1e12;
    }
};

/// Konwersja K -> °C z przesunięciem 273 (jak smartctl i nvme-cli).
pub fn kelvinToC(k: u16) i32 {
    return @as(i32, k) - 273;
}

/// Parsuje log NVMe 02h. Reguła zdrowia:
///   * Critical Warning != 0 -> critical,
///   * percentage used >= 90 albo available spare < threshold -> warning,
///   * w pozostałych przypadkach ok.
pub fn parseNvmeHealthLog(b: []const u8) ParseError!NvmeHealth {
    if (b.len < nvme_log_size) return error.Truncated;
    var h: NvmeHealth = .{
        .critical_warning = b[0],
        .composite_temp_k = readU16(b, 1),
        .available_spare = b[3],
        .available_spare_threshold = b[4],
        .percentage_used = b[5],
        .endurance_group_critical_warning = b[6],
        .data_units_read = readU128(b, 32),
        .data_units_written = readU128(b, 48),
        .host_read_commands = readU128(b, 64),
        .host_write_commands = readU128(b, 80),
        .controller_busy_minutes = readU128(b, 96),
        .power_cycles = readU128(b, 112),
        .power_on_hours = readU128(b, 128),
        .unsafe_shutdowns = readU128(b, 144),
        .media_errors = readU128(b, 160),
        .error_log_entries = readU128(b, 176),
        .warning_temp_minutes = readU32(b, 192),
        .critical_temp_minutes = readU32(b, 196),
        .temp_sensors_k = undefined,
        .summary = .{},
    };
    for (0..8) |i| h.temp_sensors_k[i] = readU16(b, 200 + i * 2);

    var s: HealthSummary = .{};
    if (h.composite_temp_k != 0) s.temperature_c = .{
        .value = kelvinToC(h.composite_temp_k),
        .source = "NVMe log 02h, bytes 1..2 (Kelvin)",
        .confidence = .high,
    };
    s.power_on_hours = .{ .value = sat64(h.power_on_hours), .source = "NVMe log 02h, bytes 128..143", .confidence = .high };
    s.power_cycles = .{ .value = sat64(h.power_cycles), .source = "NVMe log 02h, bytes 112..127", .confidence = .high };
    s.percentage_used = .{ .value = h.percentage_used, .source = "NVMe log 02h, byte 5", .confidence = .high, .note = i18n.t("may exceed 100") };
    s.data_read_bytes = .{
        .value = h.data_units_read *| NvmeHealth.data_unit_bytes,
        .source = "NVMe log 02h, bytes 32..47 (x 512000 B)",
        .confidence = .high,
        .note = i18n.t("spec rounds data units up"),
    };
    s.data_written_bytes = .{
        .value = h.data_units_written *| NvmeHealth.data_unit_bytes,
        .source = "NVMe log 02h, bytes 48..63 (x 512000 B)",
        .confidence = .high,
        .note = i18n.t("spec rounds data units up"),
    };
    s.unsafe_shutdowns = .{ .value = sat64(h.unsafe_shutdowns), .source = "NVMe log 02h, bytes 144..159", .confidence = .high };
    s.media_errors = .{ .value = sat64(h.media_errors), .source = "NVMe log 02h, bytes 160..175", .confidence = .high };

    if (h.critical_warning != 0) {
        s.status = .critical;
        s.reason = i18n.t("NVMe critical warning != 0");
    } else if (h.percentage_used >= 90) {
        s.status = .warning;
        s.reason = i18n.t("NVMe percentage used >= 90");
    } else if (h.available_spare < h.available_spare_threshold) {
        s.status = .warning;
        s.reason = i18n.t("NVMe available spare < threshold");
    } else {
        s.status = .ok;
        s.reason = i18n.t("NVMe critical warning = 0, used < 90, spare >= threshold");
    }
    h.summary = s;
    return h;
}

// ---------------------------------------------------------------------------
// ATA SMART
// ---------------------------------------------------------------------------

pub const ata_smart_size = 512;
pub const ata_attr_count = 30;
const ata_attr_off = 2;
const ata_attr_len = 12;

/// Nazwa atrybutu SMART wg powszechnej konwencji (smartmontools). Pozycje
/// z "(vendor)" mają różne znaczenie u różnych producentów.
pub fn ataAttrName(id: u8) []const u8 {
    return switch (id) {
        1 => "Raw Read Error Rate",
        2 => "Throughput Performance",
        3 => "Spin-Up Time",
        4 => "Start/Stop Count",
        5 => "Reallocated Sectors Count",
        7 => "Seek Error Rate",
        8 => "Seek Time Performance",
        9 => "Power-On Hours",
        10 => "Spin Retry Count",
        11 => "Calibration Retry Count",
        12 => "Power Cycle Count",
        13 => "Soft Read Error Rate",
        22 => "Helium Level",
        160 => "Uncorrectable Sector Count (vendor)",
        161 => "Valid Spare Blocks (vendor)",
        163 => "Initial Bad Blocks (vendor)",
        164 => "Total Erase Count (vendor)",
        165 => "Max Erase Count (vendor)",
        166 => "Min Erase Count (vendor)",
        167 => "Average Erase Count (vendor)",
        168 => "SATA PHY Error Count (vendor)",
        169 => "Remaining Life (vendor)",
        170 => "Available Reserved Space",
        171 => "Program Fail Count",
        172 => "Erase Fail Count",
        173 => "Wear Leveling Count / Avg Erase (vendor)",
        174 => "Unexpected Power Loss Count",
        175 => "Program Fail Count (Chip)",
        176 => "Erase Fail Count (Chip)",
        177 => "Wear Leveling Count",
        178 => "Used Reserved Block Count (Chip)",
        179 => "Used Reserved Block Count Total",
        180 => "Unused Reserved Block Count Total",
        181 => "Program Fail Count Total",
        182 => "Erase Fail Count Total",
        183 => "Runtime Bad Block / SATA Downshift (vendor)",
        184 => "End-to-End Error",
        187 => "Reported Uncorrectable Errors",
        188 => "Command Timeout",
        189 => "High Fly Writes",
        190 => "Airflow Temperature",
        191 => "G-Sense Error Rate",
        192 => "Power-Off Retract Count",
        193 => "Load Cycle Count",
        194 => "Temperature",
        195 => "Hardware ECC Recovered",
        196 => "Reallocation Event Count",
        197 => "Current Pending Sector Count",
        198 => "Offline Uncorrectable Sector Count",
        199 => "UDMA CRC Error Count",
        200 => "Multi-Zone Error Rate",
        201 => "Soft Read Error Rate (vendor)",
        202 => "Percent Lifetime Remaining (vendor)",
        203 => "Run Out Cancel (vendor)",
        204 => "Soft ECC Correction (vendor)",
        205 => "Thermal Asperity Rate",
        206 => "Flying Height",
        207 => "Spin High Current",
        208 => "Spin Buzz",
        209 => "Offline Seek Performance",
        210 => "Successful RAIN Recovery (vendor)",
        220 => "Disk Shift",
        221 => "G-Sense Error Rate",
        222 => "Loaded Hours",
        223 => "Load/Unload Retry Count",
        224 => "Load Friction",
        225 => "Load/Unload Cycle / Host Writes (vendor)",
        226 => "Load-In Time / Timed Workload (vendor)",
        227 => "Torque Amplification Count",
        228 => "Power-Off Retract Cycle",
        230 => "GMR Head Amplitude / Drive Life Protection (vendor)",
        231 => "SSD Life Left (vendor)",
        232 => "Endurance Remaining / Available Reserved (vendor)",
        233 => "Media Wearout Indicator (vendor)",
        234 => "Average/Max Erase Count (vendor)",
        235 => "Good Block Count / Power-Fail Backup (vendor)",
        240 => "Head Flying Hours / Transfer Error Rate (vendor)",
        241 => "Total LBAs Written",
        242 => "Total LBAs Read",
        243 => "Total LBAs Written Expanded",
        244 => "Total LBAs Read Expanded",
        245 => "Remaining Rated Write Endurance (vendor)",
        246 => "Cumulative Host Sectors Written (vendor)",
        247 => "Host Program Page Count (vendor)",
        248 => "Background Program Page Count (vendor)",
        249 => "NAND Writes 1GiB (vendor)",
        250 => "Read Error Retry Rate",
        251 => "Minimum Spares Remaining (vendor)",
        252 => "Newly Added Bad Flash Block (vendor)",
        254 => "Free Fall Protection",
        else => "Unknown",
    };
}

pub const AtaAttribute = struct {
    id: u8,
    flags: u16,
    current: u8,
    worst: u8,
    raw: [6]u8,
    /// Próg z READ THRESHOLDS (dopasowany po identyfikatorze); null, jeśli
    /// strony progów nie było albo atrybut w niej nie występuje.
    threshold: ?u8 = null,

    pub fn raw48(self: *const AtaAttribute) u64 {
        return std.mem.readInt(u48, &self.raw, .little);
    }

    pub fn rawLow32(self: *const AtaAttribute) u32 {
        return std.mem.readInt(u32, self.raw[0..4], .little);
    }

    pub fn isPrefailure(self: *const AtaAttribute) bool {
        return self.flags & 0x0001 != 0;
    }

    pub fn name(self: *const AtaAttribute) []const u8 {
        return ataAttrName(self.id);
    }

    /// Czy atrybut jest poniżej progu (FAILING). Progi 0 („zawsze OK")
    /// oraz 0xFE/0xFF (wartości specjalne) nie są brane pod uwagę.
    pub fn isFailing(self: *const AtaAttribute) bool {
        const t = self.threshold orelse return false;
        if (t == 0 or t >= 0xFE) return false;
        return self.current <= t;
    }
};

pub const AtaOptions = struct {
    /// Podpowiedź z systemu (np. DEVICE_SEEK_PENALTY_DESCRIPTOR): true = dysk
    /// obrotowy. Dla dysków obrotowych nie wyprowadzamy zużycia z atrybutów
    /// SSD, bo te same identyfikatory znaczą u HDD coś innego.
    rotational: ?bool = null,
};

/// Status testu własnego (bajt 363, starsza połówka).
pub fn ataSelfTestStatusName(v: u8) []const u8 {
    return switch (v >> 4) {
        0 => i18n.t("completed without error / never run"),
        1 => i18n.t("aborted by host"),
        2 => i18n.t("interrupted by reset"),
        3 => i18n.t("fatal error"),
        4 => i18n.t("failed (unknown element)"),
        5 => i18n.t("failed (electrical element)"),
        6 => i18n.t("failed (servo/seek element)"),
        7 => i18n.t("failed (read element)"),
        8 => i18n.t("failed (handling damage)"),
        15 => i18n.t("in progress"),
        else => i18n.t("reserved"),
    };
}

pub const AtaSmart = struct {
    revision: u16,
    attrs: [ata_attr_count]AtaAttribute,
    count: u8,
    offline_collection_status: u8,
    self_test_status: u8,
    data_checksum_ok: bool,
    thresholds_present: bool,
    thresholds_checksum_ok: bool,
    summary: HealthSummary,

    pub fn attributes(self: *const AtaSmart) []const AtaAttribute {
        return self.attrs[0..self.count];
    }

    pub fn find(self: *const AtaSmart, id: u8) ?*const AtaAttribute {
        for (self.attrs[0..self.count]) |*a| if (a.id == id) return a;
        return null;
    }
};

fn checksumOk(page: []const u8) bool {
    var sum: u8 = 0;
    for (page[0..ata_smart_size]) |c| sum +%= c;
    return sum == 0;
}

/// Parsuje stronę SMART READ DATA (i opcjonalnie READ THRESHOLDS).
///
/// Wartości pochodne:
///   * temperatura: atrybut 194 raw[0], awaryjnie 190 raw[0] (medium),
///   * godziny pracy: atrybut 9, młodsze 32 bity raw (medium — warianty
///     producentów: minuty/sekundy, milisekundy w starszych bajtach),
///   * cykle zasilania: 12, młodsze 32 bity,
///   * przemapowane (5), oczekujące (197), nieodczytywalne (198): młodsze
///     32 bity raw,
///   * zużycie: 233 / 177 / 231 / 202 jako 100 - current (tylko gdy dysk nie
///     jest znany jako obrotowy; interpretacja producenta, medium/low),
///   * zapisane bajty: 241 raw48 x 512 (low — jednostka zależy od producenta).
///
/// Reguła zdrowia: dowolny atrybut z progiem > 0 i current <= próg ->
/// critical (failing); w przeciwnym razie 5/197/198 > 0 -> warning; w
/// przeciwnym razie ok.
///
/// Sumy kontrolne są raportowane, ale nie odrzucają strony — część dysków
/// zwraca niepoprawną sumę przy poprawnych danych.
pub fn parseAtaSmart(data: []const u8, thresholds: ?[]const u8, opts: AtaOptions) ParseError!AtaSmart {
    if (data.len < ata_smart_size) return error.Truncated;
    var r: AtaSmart = .{
        .revision = readU16(data, 0),
        .attrs = undefined,
        .count = 0,
        .offline_collection_status = data[362],
        .self_test_status = data[363],
        .data_checksum_ok = checksumOk(data),
        .thresholds_present = false,
        .thresholds_checksum_ok = false,
        .summary = .{},
    };
    for (0..ata_attr_count) |i| {
        const e = data[ata_attr_off + i * ata_attr_len ..][0..ata_attr_len];
        if (e[0] == 0) continue;
        r.attrs[r.count] = .{
            .id = e[0],
            .flags = readU16(e, 1),
            .current = e[3],
            .worst = e[4],
            .raw = e[5..11].*,
        };
        r.count += 1;
    }

    if (thresholds) |t| {
        if (t.len >= ata_smart_size) {
            r.thresholds_present = true;
            r.thresholds_checksum_ok = checksumOk(t);
            for (0..ata_attr_count) |i| {
                const e = t[ata_attr_off + i * ata_attr_len ..][0..ata_attr_len];
                if (e[0] == 0) continue;
                for (r.attrs[0..r.count]) |*a| {
                    if (a.id == e[0]) a.threshold = e[1];
                }
            }
        }
    }

    r.summary = deriveAta(&r, opts);
    return r;
}

fn deriveAta(r: *const AtaSmart, opts: AtaOptions) HealthSummary {
    var s: HealthSummary = .{};

    if (r.find(194)) |a| {
        const t = a.raw[0];
        if (t > 0 and t < 128) s.temperature_c = .{ .value = t, .source = "ATA SMART attr 194 raw[0]", .confidence = .high };
    }
    if (s.temperature_c == null) if (r.find(190)) |a| {
        const t = a.raw[0];
        if (t > 0 and t < 128) s.temperature_c = .{
            .value = t,
            .source = "ATA SMART attr 190 raw[0]",
            .confidence = .medium,
            .note = i18n.t("airflow temperature; fallback when 194 is missing"),
        };
    };

    if (r.find(9)) |a| s.power_on_hours = .{
        .value = a.rawLow32(),
        .source = "ATA SMART attr 9 raw[0..3]",
        .confidence = .medium,
        .note = i18n.t("some vendors count minutes/seconds or pack extra data in raw[4..5]"),
    };
    if (r.find(12)) |a| s.power_cycles = .{ .value = a.rawLow32(), .source = "ATA SMART attr 12 raw[0..3]", .confidence = .high };
    if (r.find(5)) |a| s.reallocated = .{ .value = a.rawLow32(), .source = "ATA SMART attr 5 raw[0..3]", .confidence = .high };
    if (r.find(197)) |a| s.pending = .{ .value = a.rawLow32(), .source = "ATA SMART attr 197 raw[0..3]", .confidence = .high };
    if (r.find(198)) |a| s.uncorrectable = .{ .value = a.rawLow32(), .source = "ATA SMART attr 198 raw[0..3]", .confidence = .high };
    if (r.find(174)) |a| s.unsafe_shutdowns = .{
        .value = a.rawLow32(),
        .source = "ATA SMART attr 174 raw[0..3]",
        .confidence = .medium,
        .note = i18n.t("SSD vendors only"),
    };

    if (opts.rotational != true) {
        const Cand = struct { id: u8, source: []const u8, conf: Confidence, note: []const u8 };
        const cands = [_]Cand{
            .{ .id = 233, .source = "ATA SMART attr 233 current (100 - value)", .conf = .medium, .note = i18n.N("Intel Media Wearout Indicator; vendor-specific") },
            .{ .id = 177, .source = "ATA SMART attr 177 current (100 - value)", .conf = .medium, .note = i18n.N("Samsung Wear Leveling Count; vendor-specific") },
            .{ .id = 231, .source = "ATA SMART attr 231 current (100 - value)", .conf = .medium, .note = i18n.N("SSD Life Left (Kingston/SandForce); vendor-specific") },
            .{ .id = 202, .source = "ATA SMART attr 202 current (100 - value)", .conf = .low, .note = i18n.N("Micron/Crucial lifetime remaining; vendor-specific") },
        };
        for (cands) |c| {
            const a = r.find(c.id) orelse continue;
            if (a.current == 0 or a.current > 100) continue;
            s.percentage_used = .{ .value = 100 - a.current, .source = c.source, .confidence = c.conf, .note = i18n.t(c.note) };
            break;
        }
    }

    if (r.find(241)) |a| s.data_written_bytes = .{
        .value = @as(u128, a.raw48()) * 512,
        .source = "ATA SMART attr 241 raw48 x 512",
        .confidence = .low,
        .note = i18n.t("unit is vendor-specific (LBAs, 32 MiB, GiB)"),
    };
    if (r.find(242)) |a| s.data_read_bytes = .{
        .value = @as(u128, a.raw48()) * 512,
        .source = "ATA SMART attr 242 raw48 x 512",
        .confidence = .low,
        .note = i18n.t("unit is vendor-specific (LBAs, 32 MiB, GiB)"),
    };

    for (r.attrs[0..r.count]) |*a| {
        if (a.isFailing()) {
            s.status = .critical;
            s.reason = i18n.t("ATA SMART attribute at or below threshold (failing)");
            s.trigger_attr = a.id;
            return s;
        }
    }
    const counters = [_]struct { v: ?Derived(u64), id: u8, why: []const u8 }{
        .{ .v = s.reallocated, .id = 5, .why = i18n.N("ATA reallocated sectors > 0") },
        .{ .v = s.pending, .id = 197, .why = i18n.N("ATA pending sectors > 0") },
        .{ .v = s.uncorrectable, .id = 198, .why = i18n.N("ATA offline uncorrectable > 0") },
    };
    for (counters) |c| {
        if (c.v) |d| if (d.value > 0) {
            s.status = .warning;
            s.reason = i18n.t(c.why);
            s.trigger_attr = c.id;
            return s;
        };
    }
    if (r.count == 0) {
        s.status = .unknown;
        s.reason = i18n.t("ATA SMART page has no attributes");
    } else {
        s.status = .ok;
        s.reason = if (r.thresholds_present)
            i18n.t("ATA no attribute at threshold; 5/197/198 = 0")
        else
            i18n.t("ATA 5/197/198 = 0 (thresholds unavailable)");
    }
    return s;
}

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestDesc = struct {
    buf: [512]u8 = [_]u8{0} ** 512,
    pos: usize = DeviceDescriptor.struct_size,

    fn init(bus: u32, removable: bool) TestDesc {
        var t: TestDesc = .{};
        std.mem.writeInt(u32, t.buf[0..4], DeviceDescriptor.struct_size, .little);
        t.buf[8] = 0; // DIRECT_ACCESS_DEVICE
        t.buf[10] = @intFromBool(removable);
        t.buf[11] = 1;
        std.mem.writeInt(u32, t.buf[28..32], bus, .little);
        return t;
    }

    /// Dopisuje napis zakończony NUL i ustawia przesunięcie w polu `field_off`.
    fn str(t: *TestDesc, field_off: usize, s: []const u8) void {
        std.mem.writeInt(u32, t.buf[field_off..][0..4], @intCast(t.pos), .little);
        @memcpy(t.buf[t.pos..][0..s.len], s);
        t.buf[t.pos + s.len] = 0;
        t.pos += s.len + 1;
    }

    fn finish(t: *TestDesc) []const u8 {
        std.mem.writeInt(u32, t.buf[4..8], @intCast(t.pos), .little);
        return t.buf[0..t.pos];
    }
};

test "descriptor: NVMe with plain strings and odd offsets" {
    var t = TestDesc.init(0x11, false);
    t.pos = 41; // nieparzyste przesunięcie
    t.str(12, "NVMe");
    t.str(16, "Example SSD 970 1TB     ");
    t.str(20, "2B2QEXM7");
    t.str(24, "0025_3881_9140_ABCD.");
    const d = try parseDeviceDescriptor(t.finish());
    try testing.expectEqual(BusType.nvme, d.bus_type);
    try testing.expectEqualStrings("NVMe", d.bus_type.name());
    try testing.expectEqualStrings("Example SSD 970 1TB", d.product_id.slice());
    try testing.expectEqualStrings("2B2QEXM7", d.product_revision.slice());
    try testing.expectEqualStrings("0025_3881_9140_ABCD.", d.serial.slice());
    try testing.expectEqual(SerialEncoding.plain, d.serial_encoding);
    try testing.expect(!d.removable);
    var mb: [128]u8 = undefined;
    try testing.expectEqualStrings("Example SSD 970 1TB", d.modelName(&mb));
}

test "descriptor: SATA hex-encoded byte-swapped serial" {
    // "  WD-WCC4E1234567" (spacje wiodące) zapisany jak surowe słowa ATA:
    // bajty zamienione w parach, potem szesnastkowo.
    const plain = "   WD-WCC4E1234567  ";
    var swapped: [plain.len]u8 = undefined;
    var i: usize = 0;
    while (i < plain.len) : (i += 2) {
        swapped[i] = plain[i + 1];
        swapped[i + 1] = plain[i];
    }
    var hex: [plain.len * 2]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&swapped}) catch unreachable;

    var t = TestDesc.init(0x0B, false);
    t.str(16, "WDC WD10EZEX-08WN4A0");
    t.str(24, &hex);
    const d = try parseDeviceDescriptor(t.finish());
    try testing.expectEqual(BusType.sata, d.bus_type);
    try testing.expectEqualStrings("WD-WCC4E1234567", d.serial.slice());
    try testing.expectEqual(SerialEncoding.hex_byte_swapped, d.serial_encoding);
    try testing.expectEqual(StrStatus.absent, d.vendor_status);
}

test "descriptor: hex-looking real serial stays untouched" {
    var t = TestDesc.init(0x11, false);
    t.str(24, "0025385B71B07C4F");
    const d = try parseDeviceDescriptor(t.finish());
    try testing.expectEqualStrings("0025385B71B07C4F", d.serial.slice());
    try testing.expectEqual(SerialEncoding.plain, d.serial_encoding);
}

test "descriptor: out-of-range and header offsets" {
    var t = TestDesc.init(0x07, true);
    t.str(16, "USB Flash Disk");
    const bytes = t.finish();
    var copy: [512]u8 = undefined;
    @memcpy(copy[0..bytes.len], bytes);
    std.mem.writeInt(u32, copy[12..16], 0xFFFF_FFFF, .little); // vendor poza buforem
    std.mem.writeInt(u32, copy[20..24], 8, .little); // revision w nagłówku
    std.mem.writeInt(u32, copy[24..28], @intCast(bytes.len), .little); // serial == limit
    const d = try parseDeviceDescriptor(copy[0..bytes.len]);
    try testing.expectEqual(StrStatus.out_of_range, d.vendor_status);
    try testing.expectEqual(StrStatus.out_of_range, d.revision_status);
    try testing.expectEqual(StrStatus.out_of_range, d.serial_status);
    try testing.expectEqual(StrStatus.ok, d.product_status);
    try testing.expect(d.removable);
    try testing.expectEqualStrings("USB", d.bus_type.name());
}

test "descriptor: truncated buffers and bogus Size" {
    var short: [20]u8 = [_]u8{0} ** 20;
    try testing.expectError(error.Truncated, parseDeviceDescriptor(&short));

    var t = TestDesc.init(0x03, false);
    t.str(16, "ST1000DM003-1CH162");
    const bytes = t.finish();
    var copy: [512]u8 = undefined;
    @memcpy(copy[0..bytes.len], bytes);
    // Size większe niż bufor -> granicą jest bufor.
    std.mem.writeInt(u32, copy[4..8], 4096, .little);
    // Napis bez NUL na końcu bufora (bufor ucięty w środku napisu).
    const cut = bytes.len - 5;
    const d = try parseDeviceDescriptor(copy[0..cut]);
    try testing.expectEqualStrings("ST1000DM003-1C", d.product_id.slice());
    try testing.expectEqual(BusType.ata, d.bus_type);
}

test "descriptor: unknown bus value and non-printable chars" {
    var t = TestDesc.init(0x55, false);
    t.str(16, "Odd\x01Name");
    const d = try parseDeviceDescriptor(t.finish());
    try testing.expectEqualStrings("Unknown", d.bus_type.name());
    try testing.expectEqual(@as(u32, 0x55), d.bus_type_raw);
    try testing.expectEqualStrings("Odd?Name", d.product_id.slice());
}

test "ataIdentifyString swaps bytes and trims" {
    var out: FixedStr = .{};
    ataIdentifyString("aSsmnu gSS D", &out);
    try testing.expectEqualStrings("Samsung SSD", out.slice());
}

test "maskSerial" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("WD***********67", maskSerial("WD-WCC4E1234567", &buf));
    try testing.expectEqualStrings("*******", maskSerial("ABC1234", &buf));
    try testing.expectEqualStrings("AB****YZ", maskSerial("ABCDWXYZ", &buf));
    try testing.expectEqualStrings("", maskSerial("", &buf));
    var small: [8]u8 = undefined;
    try testing.expectEqualStrings("AB****89", maskSerial("ABCDEFGHIJ0123456789", &small));
}

fn nvmeFixture() [512]u8 {
    var b = [_]u8{0} ** 512;
    b[0] = 0;
    std.mem.writeInt(u16, b[1..3], 310, .little); // 37 °C
    b[3] = 100;
    b[4] = 10;
    b[5] = 3;
    std.mem.writeInt(u128, b[32..48], 12_345_678, .little);
    std.mem.writeInt(u128, b[48..64], (@as(u128, 1) << 64) + 5, .little);
    std.mem.writeInt(u128, b[64..80], 400_000_000, .little);
    std.mem.writeInt(u128, b[80..96], 500_000_000, .little);
    std.mem.writeInt(u128, b[96..112], 1_500, .little);
    std.mem.writeInt(u128, b[112..128], 1_024, .little);
    std.mem.writeInt(u128, b[128..144], 8_760, .little);
    std.mem.writeInt(u128, b[144..160], 57, .little);
    std.mem.writeInt(u128, b[160..176], 0, .little);
    std.mem.writeInt(u128, b[176..192], 1_200, .little);
    std.mem.writeInt(u32, b[192..196], 3, .little);
    std.mem.writeInt(u16, b[200..202], 310, .little);
    std.mem.writeInt(u16, b[202..204], 318, .little);
    return b;
}

test "nvme: realistic healthy log" {
    const b = nvmeFixture();
    const h = try parseNvmeHealthLog(&b);
    try testing.expectEqual(HealthStatus.ok, h.summary.status);
    try testing.expectEqual(@as(i32, 37), h.summary.temperature_c.?.value);
    try testing.expectEqual(@as(u64, 8_760), h.summary.power_on_hours.?.value);
    try testing.expectEqual(@as(u8, 3), h.summary.percentage_used.?.value);
    try testing.expectEqual(@as(u128, 12_345_678 * 512_000), h.summary.data_read_bytes.?.value);
    try testing.expectEqual(((@as(u128, 1) << 64) + 5) * 512_000, h.summary.data_written_bytes.?.value);
    try testing.expectEqual(@as(u128, 1_500), h.controller_busy_minutes);
    try testing.expectEqual(@as(u64, 57), h.summary.unsafe_shutdowns.?.value);
    try testing.expectEqual(@as(?i32, 45), h.sensorC(1));
    try testing.expectEqual(@as(?i32, null), h.sensorC(2));
    try testing.expectEqual(@as(u32, 3), h.warning_temp_minutes);
    try testing.expectApproxEqAbs(@as(f64, 6.3210), NvmeHealth.bytesToTB(h.summary.data_read_bytes.?.value), 1e-3);
    try testing.expectEqualStrings("NVMe log 02h, bytes 1..2 (Kelvin)", h.summary.temperature_c.?.source);
}

test "nvme: health rules" {
    var b = nvmeFixture();
    b[0] = 0b0000_0101;
    var h = try parseNvmeHealthLog(&b);
    try testing.expectEqual(HealthStatus.critical, h.summary.status);
    var names: [8][]const u8 = undefined;
    const list = nvmeCriticalWarningList(h.critical_warning, &names);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("available spare below threshold", list[0]);
    try testing.expectEqualStrings("NVM subsystem reliability degraded", list[1]);

    b[0] = 0;
    b[5] = 95;
    h = try parseNvmeHealthLog(&b);
    try testing.expectEqual(HealthStatus.warning, h.summary.status);

    b[5] = 10;
    b[3] = 5;
    b[4] = 10;
    h = try parseNvmeHealthLog(&b);
    try testing.expectEqual(HealthStatus.warning, h.summary.status);

    std.mem.writeInt(u16, b[1..3], 0, .little);
    b[3] = 100;
    h = try parseNvmeHealthLog(&b);
    try testing.expectEqual(HealthStatus.ok, h.summary.status);
    try testing.expect(h.summary.temperature_c == null);
}

test "nvme: truncated" {
    const b = nvmeFixture();
    try testing.expectError(error.Truncated, parseNvmeHealthLog(b[0..511]));
}

const TestAttr = struct { id: u8, flags: u16 = 0x0032, cur: u8, worst: u8, raw: u48, thr: u8 = 0 };

fn ataPages(attrs: []const TestAttr) [2][512]u8 {
    var d = [_]u8{0} ** 512;
    var t = [_]u8{0} ** 512;
    std.mem.writeInt(u16, d[0..2], 0x0010, .little);
    std.mem.writeInt(u16, t[0..2], 0x0010, .little);
    for (attrs, 0..) |a, i| {
        const e = d[2 + i * 12 ..][0..12];
        e[0] = a.id;
        std.mem.writeInt(u16, e[1..3], a.flags, .little);
        e[3] = a.cur;
        e[4] = a.worst;
        std.mem.writeInt(u48, e[5..11], a.raw, .little);
        const te = t[2 + i * 12 ..][0..12];
        te[0] = a.id;
        te[1] = a.thr;
    }
    d[362] = 0x00;
    d[363] = 0x00;
    var sum: u8 = 0;
    for (d[0..511]) |c| sum +%= c;
    d[511] = 0 -% sum;
    sum = 0;
    for (t[0..511]) |c| sum +%= c;
    t[511] = 0 -% sum;
    return .{ d, t };
}

const ssd_attrs = [_]TestAttr{
    .{ .id = 5, .flags = 0x0033, .cur = 100, .worst = 100, .raw = 0, .thr = 10 },
    .{ .id = 9, .cur = 98, .worst = 98, .raw = 5_000 },
    .{ .id = 12, .cur = 99, .worst = 99, .raw = 300 },
    .{ .id = 177, .flags = 0x0013, .cur = 95, .worst = 95, .raw = 42, .thr = 0 },
    .{ .id = 179, .flags = 0x0013, .cur = 100, .worst = 100, .raw = 0, .thr = 10 },
    .{ .id = 181, .cur = 100, .worst = 100, .raw = 0, .thr = 10 },
    .{ .id = 187, .cur = 100, .worst = 100, .raw = 0 },
    .{ .id = 190, .cur = 65, .worst = 50, .raw = 35 },
    .{ .id = 195, .cur = 200, .worst = 200, .raw = 0 },
    .{ .id = 199, .cur = 100, .worst = 100, .raw = 0 },
    .{ .id = 235, .cur = 99, .worst = 99, .raw = 120 },
    .{ .id = 241, .cur = 99, .worst = 99, .raw = 20_000_000_000 },
};

test "ata: SSD page (Samsung-like)" {
    const p = ataPages(&ssd_attrs);
    const s = try parseAtaSmart(&p[0], &p[1], .{ .rotational = false });
    try testing.expect(s.data_checksum_ok);
    try testing.expect(s.thresholds_present and s.thresholds_checksum_ok);
    try testing.expectEqual(@as(usize, ssd_attrs.len), s.attributes().len);
    try testing.expectEqual(HealthStatus.ok, s.summary.status);
    try testing.expectEqual(@as(i32, 35), s.summary.temperature_c.?.value);
    try testing.expectEqual(Confidence.medium, s.summary.temperature_c.?.confidence);
    try testing.expectEqualStrings("ATA SMART attr 190 raw[0]", s.summary.temperature_c.?.source);
    try testing.expectEqual(@as(u64, 5_000), s.summary.power_on_hours.?.value);
    try testing.expectEqual(@as(u8, 5), s.summary.percentage_used.?.value);
    try testing.expectEqualStrings("ATA SMART attr 177 current (100 - value)", s.summary.percentage_used.?.source);
    try testing.expectEqual(@as(u128, 20_000_000_000 * 512), s.summary.data_written_bytes.?.value);
    try testing.expectEqual(Confidence.low, s.summary.data_written_bytes.?.confidence);
    try testing.expectEqual(@as(?u8, 10), s.find(5).?.threshold);
    try testing.expectEqualStrings("Wear Leveling Count", s.find(177).?.name());
    try testing.expect(s.find(5).?.isPrefailure());
}

test "ata: HDD page with reallocated sectors and vendor POH packing" {
    const hdd = [_]TestAttr{
        .{ .id = 1, .flags = 0x000F, .cur = 117, .worst = 99, .raw = 123_456_789, .thr = 6 },
        .{ .id = 3, .flags = 0x0003, .cur = 97, .worst = 96, .raw = 0, .thr = 0 },
        .{ .id = 4, .cur = 99, .worst = 99, .raw = 1_500, .thr = 20 },
        .{ .id = 5, .flags = 0x0033, .cur = 100, .worst = 100, .raw = 8, .thr = 10 },
        .{ .id = 7, .flags = 0x000F, .cur = 80, .worst = 60, .raw = 1_000_000, .thr = 30 },
        // Seagate: godziny w młodszych 32 bitach, milisekundy w starszych.
        .{ .id = 9, .cur = 78, .worst = 78, .raw = (@as(u48, 0x1234) << 32) | 20_000 },
        .{ .id = 10, .flags = 0x0013, .cur = 100, .worst = 100, .raw = 0, .thr = 97 },
        .{ .id = 12, .cur = 99, .worst = 99, .raw = 1_400, .thr = 20 },
        .{ .id = 177, .cur = 100, .worst = 100, .raw = 0 },
        .{ .id = 194, .flags = 0x0022, .cur = 38, .worst = 50, .raw = 0x0000_2D00_1400_26 },
        .{ .id = 197, .cur = 100, .worst = 100, .raw = 0 },
        .{ .id = 198, .flags = 0x0010, .cur = 100, .worst = 100, .raw = 0 },
        .{ .id = 199, .cur = 200, .worst = 200, .raw = 0 },
    };
    const p = ataPages(&hdd);
    const s = try parseAtaSmart(&p[0], &p[1], .{ .rotational = true });
    try testing.expectEqual(HealthStatus.warning, s.summary.status);
    try testing.expectEqual(@as(u8, 5), s.summary.trigger_attr);
    try testing.expectEqual(@as(i32, 38), s.summary.temperature_c.?.value);
    try testing.expectEqual(Confidence.high, s.summary.temperature_c.?.confidence);
    try testing.expectEqual(@as(u64, 20_000), s.summary.power_on_hours.?.value);
    try testing.expectEqual(@as(u64, 8), s.summary.reallocated.?.value);
    try testing.expect(s.summary.percentage_used == null);
}

test "ata: failing attribute and missing thresholds" {
    var attrs = ssd_attrs;
    attrs[0].cur = 9; // 5: current <= threshold 10
    const p = ataPages(&attrs);
    const s = try parseAtaSmart(&p[0], &p[1], .{});
    try testing.expectEqual(HealthStatus.critical, s.summary.status);
    try testing.expectEqual(@as(u8, 5), s.summary.trigger_attr);

    // Bez progów nie da się stwierdzić "failing" — zostaje ok.
    const s2 = try parseAtaSmart(&p[0], null, .{});
    try testing.expectEqual(HealthStatus.ok, s2.summary.status);
    try testing.expect(!s2.thresholds_present);
    try testing.expect(s2.find(5).?.threshold == null);

    // Ucięta strona progów jest ignorowana.
    const s3 = try parseAtaSmart(&p[0], p[1][0..100], .{});
    try testing.expect(!s3.thresholds_present);
}

test "ata: truncated, bad checksum, empty page" {
    const p = ataPages(&ssd_attrs);
    try testing.expectError(error.Truncated, parseAtaSmart(p[0][0..300], null, .{}));
    var bad = p[0];
    bad[511] +%= 1;
    const s = try parseAtaSmart(&bad, null, .{});
    try testing.expect(!s.data_checksum_ok);
    try testing.expectEqual(@as(usize, ssd_attrs.len), s.attributes().len);

    const empty = [_]u8{0} ** 512;
    const e = try parseAtaSmart(&empty, null, .{});
    try testing.expectEqual(HealthStatus.unknown, e.summary.status);
    try testing.expect(e.summary.temperature_c == null);
}

test "ata: self-test status names" {
    try testing.expectEqualStrings("in progress", ataSelfTestStatusName(0xF3));
    try testing.expectEqualStrings("failed (read element)", ataSelfTestStatusName(0x70));
}
