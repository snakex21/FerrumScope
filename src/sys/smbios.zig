//! Czysty (niezależny od platformy) parser tablic SMBIOS / DMI.
//!
//! Wejście:
//!   * Windows: bufor z `GetSystemFirmwareTable('RSMB', 0, ...)`, czyli nagłówek
//!     `RawSMBIOSData` { u8 Used20CallingMethod; u8 SMBIOSMajorVersion;
//!     u8 SMBIOSMinorVersion; u8 DmiRevision; u32 Length; u8 SMBIOSTableData[Length] }
//!     -> `fromRawSmbiosData`.
//!   * Linux: `/sys/firmware/dmi/tables/DMI` (gołe dane tablicy) plus wersja
//!     z `smbios_entry_point` -> `fromTableData`.
//!
//! Moduł nie wykonuje żadnych wywołań systemowych i nie alokuje pamięci.
//! Warstwy są rozdzielone:
//!   1. surowa: `Table`, `Iterator`, `Structure` (bajty + zestaw napisów),
//!   2. zinterpretowana: `decodeBios`, `decodeSystem`, ... — każde pole trzyma
//!      surową wartość, wartość zdekodowaną i odwołanie do specyfikacji
//!      (DMTF DSP0134, SMBIOS 3.x).
//!
//! Parser jest odporny na uszkodzone dane: nigdy nie czyta poza buforem
//! i zawsze kończy iterację (pozycja rośnie co najmniej o 4 bajty na krok).
//!
//! Pola wrażliwe (numery seryjne, asset tagi, UUID) mają flagę `sensitive`.
//! `maskSerials` pozwala zamaskować je w przechwyconej tablicy przed zapisaniem
//! jej jako fixture testowego.

const std = @import("std");

/// Błędy warstwy surowej.
pub const Error = error{
    /// Bufor krótszy niż 8-bajtowy nagłówek `RawSMBIOSData`.
    TooShort,
};

/// Długość nagłówka `RawSMBIOSData` zwracanego przez Windows.
pub const raw_header_len: usize = 8;

/// Typ struktury oznaczający koniec tablicy (SMBIOS 3.x §7.46).
pub const end_of_table_type: u8 = 127;

/// Wersja SMBIOS (major.minor) — wpływa na obecność pól i kolejność bajtów UUID.
pub const Version = struct {
    major: u8,
    minor: u8,

    /// Czy wersja jest co najmniej `major.minor`.
    pub fn atLeast(self: Version, major: u8, minor: u8) bool {
        return self.major > major or (self.major == major and self.minor >= minor);
    }
};

/// Surowa tablica SMBIOS: wersja i dane struktur (bez nagłówka `RawSMBIOSData`).
pub const Table = struct {
    major: u8,
    minor: u8,
    data: []const u8,
    /// `DmiRevision` z nagłówka Windows (0, gdy nieznane).
    dmi_revision: u8 = 0,
    /// Nagłówek deklarował więcej danych niż było w buforze — dane obcięte.
    truncated: bool = false,

    pub fn version(self: Table) Version {
        return .{ .major = self.major, .minor = self.minor };
    }

    /// Iterator po strukturach tablicy.
    pub fn iterator(self: Table) Iterator {
        return .{ .data = self.data, .version = self.version() };
    }

    /// Pierwsza struktura danego typu (albo null).
    pub fn find(self: Table, type_id: u8) ?Structure {
        var it = self.iterator();
        while (it.next()) |s| {
            if (s.type_id == type_id) return s;
        }
        return null;
    }
};

/// Parsuje bufor `RawSMBIOSData` (Windows `GetSystemFirmwareTable('RSMB')`).
/// Jeżeli pole `Length` deklaruje więcej bajtów niż jest w buforze, dane są
/// przycinane do dostępnych, a `Table.truncated` = true (wynik częściowy).
pub fn fromRawSmbiosData(buf: []const u8) Error!Table {
    if (buf.len < raw_header_len) return error.TooShort;
    const declared = std.mem.readInt(u32, buf[4..8], .little);
    const avail = buf.len - raw_header_len;
    const n: usize = @min(@as(usize, declared), avail);
    return .{
        .major = buf[1],
        .minor = buf[2],
        .dmi_revision = buf[3],
        .data = buf[raw_header_len..][0..n],
        .truncated = declared > avail,
    };
}

/// Tablica z gołych danych struktur (np. Linux `/sys/firmware/dmi/tables/DMI`).
pub fn fromTableData(major: u8, minor: u8, data: []const u8) Table {
    return .{ .major = major, .minor = minor, .data = data };
}

/// Zakres napisu wewnątrz obszaru napisów struktury.
pub const Span = struct { start: usize, len: usize };

/// Pojedyncza struktura SMBIOS (SMBIOS 3.x §6.1.2).
pub const Structure = struct {
    /// Typ struktury (bajt 00h). Nazwa `type_id`, bo `type` to słowo kluczowe Zig.
    type_id: u8,
    /// Uchwyt (WORD 02h).
    handle: u16,
    /// Obszar sformatowany łącznie z 4-bajtowym nagłówkiem.
    formatted: []const u8,
    /// Obszar napisów bez końcowego podwójnego NUL (napisy rozdzielone NUL).
    strings: []const u8,
    /// Przesunięcie początku struktury względem `Table.data`.
    offset: usize,
    /// Przesunięcie obszaru napisów względem `Table.data`.
    strings_offset: usize,
    /// Wersja tablicy, z której pochodzi struktura.
    version: Version,

    /// Długość obszaru sformatowanego (bajt 01h).
    pub fn length(self: Structure) usize {
        return self.formatted.len;
    }

    pub fn byte(self: Structure, off: usize) ?u8 {
        if (off >= self.formatted.len) return null;
        return self.formatted[off];
    }

    pub fn word(self: Structure, off: usize) ?u16 {
        if (off + 2 > self.formatted.len) return null;
        return std.mem.readInt(u16, self.formatted[off..][0..2], .little);
    }

    pub fn dword(self: Structure, off: usize) ?u32 {
        if (off + 4 > self.formatted.len) return null;
        return std.mem.readInt(u32, self.formatted[off..][0..4], .little);
    }

    pub fn qword(self: Structure, off: usize) ?u64 {
        if (off + 8 > self.formatted.len) return null;
        return std.mem.readInt(u64, self.formatted[off..][0..8], .little);
    }

    /// Napis o numerze `index` (od 1; 0 = brak napisu). Null dla 0 i indeksu
    /// spoza zestawu.
    pub fn string(self: Structure, index: u8) ?[]const u8 {
        const span = self.stringSpan(index) orelse return null;
        return self.strings[span.start..][0..span.len];
    }

    /// Położenie napisu `index` w `strings` (używane m.in. przez maskowanie).
    pub fn stringSpan(self: Structure, index: u8) ?Span {
        if (index == 0) return null;
        var start: usize = 0;
        var n: usize = 1;
        while (start < self.strings.len) : (n += 1) {
            const rest = self.strings[start..];
            const l = std.mem.indexOfScalar(u8, rest, 0) orelse rest.len;
            if (n == index) return .{ .start = start, .len = l };
            start += l + 1;
        }
        return null;
    }
};

/// Iterator po strukturach. Kończy się na typie 127, końcu danych albo
/// pierwszej uszkodzonej strukturze (wtedy `malformed` = true).
pub const Iterator = struct {
    data: []const u8,
    version: Version,
    pos: usize = 0,
    done: bool = false,
    /// Napotkano uszkodzone dane (długość < 4, wyjście poza bufor, brak
    /// podwójnego NUL). Struktury zwrócone wcześniej są poprawne.
    malformed: bool = false,

    pub fn next(it: *Iterator) ?Structure {
        if (it.done) return null;
        const d = it.data;
        if (it.pos >= d.len) {
            it.done = true;
            return null;
        }
        if (d.len - it.pos < 4) {
            it.done = true;
            it.malformed = true;
            return null;
        }
        const start = it.pos;
        const len: usize = d[start + 1];
        if (len < 4 or len > d.len - start) {
            it.done = true;
            it.malformed = true;
            return null;
        }
        const sstart = start + len;
        var term: ?usize = null;
        var i = sstart;
        while (i + 1 < d.len) : (i += 1) {
            if (d[i] == 0 and d[i + 1] == 0) {
                term = i;
                break;
            }
        }
        var strings: []const u8 = undefined;
        if (term) |t| {
            strings = d[sstart..t];
            it.pos = t + 2;
        } else {
            // Brak podwójnego NUL: oddajemy strukturę z tym, co jest, i kończymy.
            strings = d[sstart..];
            it.pos = d.len;
            it.done = true;
            it.malformed = true;
        }
        const s: Structure = .{
            .type_id = d[start],
            .handle = std.mem.readInt(u16, d[start + 2 ..][0..2], .little),
            .formatted = d[start..sstart],
            .strings = strings,
            .offset = start,
            .strings_offset = sstart,
            .version = it.version,
        };
        if (s.type_id == end_of_table_type) it.done = true;
        return s;
    }
};

// ---------------------------------------------------------------------------
// Pola zinterpretowane
// ---------------------------------------------------------------------------

/// Odwołanie do specyfikacji, np. "SMBIOS 3.x §7.1 type 0, offset 05h".
fn ref(comptime section: []const u8, comptime t: u8, comptime off: u8) []const u8 {
    return comptime std.fmt.comptimePrint("SMBIOS 3.x §{s} type {d}, offset {X:0>2}h", .{ section, t, off });
}

/// Pole napisowe. `raw` = napis dokładnie z tablicy, `value` = przycięty
/// z białych znaków. Wypełniacze OEM nie są odrzucane — mają `placeholder`.
pub const StringField = struct {
    /// Numer napisu w strukturze (0 = brak).
    index: u8,
    /// Napis z tablicy bez zmian (null: indeks 0 albo spoza zestawu).
    raw: ?[]const u8,
    /// Napis po przycięciu spacji/tabulatorów na brzegach.
    value: ?[]const u8,
    /// Wartość jest wypełniaczem („To Be Filled By O.E.M.", „Default string",
    /// same spacje, ...).
    placeholder: bool,
    /// Pole zawiera dane identyfikujące egzemplarz (numer seryjny, asset tag).
    sensitive: bool,
    spec: []const u8,

    /// Wartość do wyświetlenia: null, gdy brak albo wypełniacz.
    pub fn text(self: StringField) ?[]const u8 {
        if (self.placeholder) return null;
        return self.value;
    }
};

/// Pole wyliczeniowe: surowy bajt i nazwa wg tabeli specyfikacji
/// (null dla wartości spoza tabeli).
pub const EnumField = struct {
    raw: u8,
    name: ?[]const u8,
    spec: []const u8,
};

/// Pole liczbowe: surowa wartość i wartość zinterpretowana (null = nieznana).
pub fn Num(comptime T: type) type {
    return struct {
        raw: T,
        value: ?T,
        spec: []const u8,
    };
}

const placeholder_strings = [_][]const u8{
    "To Be Filled By O.E.M.", "To Be Filled By OEM", "To be filled by O.E.M",
    "Default string",         "Default",             "Not Specified",
    "Not Applicable",         "Not Available",       "Not Present",
    "None",                   "N/A",                 "NA",
    "Unknown",                "Unknow",              "Undefined",
    "Unspecified",            "O.E.M.",              "OEM",
    "Fill By OEM",            "System manufacturer", "System Manufacturer",
    "System Product Name",    "System Version",      "System Serial Number",
    "System SKU",             "SKU",                 "Base Board Serial Number",
    "Chassis Serial Number",  "Chassis Manufacture", "Asset Tag",
    "AssetTag",               "No Asset Tag",        "No Asset Information",
    "123456789",              "0123456789",          "1234567890",
    "Empty",                  "NO DIMM",             "Type2 - Board Serial Number",
};

/// Czy napis (już przycięty) jest wypełniaczem OEM. Pusty napis i napis
/// złożony z samych zer też są traktowane jako wypełniacz.
pub fn isPlaceholder(trimmed: []const u8) bool {
    if (trimmed.len == 0) return true;
    for (placeholder_strings) |p| {
        if (std.ascii.eqlIgnoreCase(trimmed, p)) return true;
    }
    for (trimmed) |c| {
        if (c != '0') return false;
    }
    return true;
}

fn strField(s: Structure, off: usize, sensitive: bool, spec: []const u8) ?StringField {
    const idx = s.byte(off) orelse return null;
    const raw = s.string(idx);
    var value: ?[]const u8 = null;
    var placeholder = false;
    if (raw) |r| {
        const t = std.mem.trim(u8, r, " \t\r\n");
        value = t;
        placeholder = isPlaceholder(t);
    }
    return .{
        .index = idx,
        .raw = raw,
        .value = value,
        .placeholder = placeholder,
        .sensitive = sensitive,
        .spec = spec,
    };
}

fn enumField(s: Structure, off: usize, comptime nameFn: fn (u8) ?[]const u8, spec: []const u8) ?EnumField {
    const b = s.byte(off) orelse return null;
    return .{ .raw = b, .name = nameFn(b), .spec = spec };
}

// ---------------------------------------------------------------------------
// Typ 0 — BIOS Information (§7.1)
// ---------------------------------------------------------------------------

/// Rozmiar ROM BIOS: bajt 09h (64 KiB * (n + 1)); FFh = patrz Extended BIOS
/// ROM Size (WORD 18h, SMBIOS 3.1+: bity 15:14 jednostka 00b = MiB, 01b = GiB).
pub const RomSize = struct {
    raw: u8,
    raw_extended: ?u16,
    bytes: ?u64,
    from_extended: bool,
    spec: []const u8,
};

/// Wydanie (major.minor). FFh/FFh = nieobsługiwane przez platformę.
pub const Release = struct {
    major: u8,
    minor: u8,
    supported: bool,
    spec: []const u8,
};

pub const Bios = struct {
    handle: u16,
    vendor: ?StringField,
    version: ?StringField,
    release_date: ?StringField,
    starting_segment: ?u16,
    rom_size: ?RomSize,
    characteristics: ?u64,
    bios_release: ?Release,
    ec_release: ?Release,
};

pub fn decodeBios(s: Structure) ?Bios {
    if (s.type_id != 0) return null;
    var rom: ?RomSize = null;
    if (s.byte(0x09)) |r| {
        const ext = s.word(0x18);
        var size: RomSize = .{ .raw = r, .raw_extended = ext, .bytes = null, .from_extended = false, .spec = ref("7.1", 0, 0x09) };
        if (r != 0xFF) {
            size.bytes = (@as(u64, r) + 1) * 64 * 1024;
        } else if (ext) |e| {
            const n: u64 = e & 0x3FFF;
            size.from_extended = true;
            size.spec = ref("7.1", 0, 0x18);
            size.bytes = switch (e >> 14) {
                0 => n * 1024 * 1024,
                1 => n * 1024 * 1024 * 1024,
                else => null,
            };
        }
        rom = size;
    }
    return .{
        .handle = s.handle,
        .vendor = strField(s, 0x04, false, ref("7.1", 0, 0x04)),
        .version = strField(s, 0x05, false, ref("7.1", 0, 0x05)),
        .release_date = strField(s, 0x08, false, ref("7.1", 0, 0x08)),
        .starting_segment = s.word(0x06),
        .rom_size = rom,
        .characteristics = s.qword(0x0A),
        .bios_release = release(s, 0x14, ref("7.1", 0, 0x14)),
        .ec_release = release(s, 0x16, ref("7.1", 0, 0x16)),
    };
}

fn release(s: Structure, off: usize, spec: []const u8) ?Release {
    const major = s.byte(off) orelse return null;
    const minor = s.byte(off + 1) orelse return null;
    return .{ .major = major, .minor = minor, .supported = !(major == 0xFF and minor == 0xFF), .spec = spec };
}

// ---------------------------------------------------------------------------
// Typ 1 — System Information (§7.2)
// ---------------------------------------------------------------------------

pub const UuidState = enum {
    /// UUID obecny.
    present,
    /// Wszystkie bajty 00h: UUID nieobecny.
    not_present,
    /// Wszystkie bajty FFh: UUID nieustawiony, ale możliwy do ustawienia.
    not_set,
};

/// UUID systemu (16 bajtów od 08h). Od SMBIOS 2.6 pierwsze trzy pola
/// (time_low, time_mid, time_hi_and_version) są zapisane little-endian.
pub const Uuid = struct {
    raw: [16]u8,
    state: UuidState,
    /// Czy przy formatowaniu odwracać kolejność bajtów pierwszych 3 pól.
    little_endian_fields: bool,
    sensitive: bool = true,
    spec: []const u8,

    pub fn format(self: Uuid, buf: *[36]u8) []const u8 {
        return formatUuid(self.raw, self.little_endian_fields, buf);
    }
};

/// Formatuje UUID jako "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX" (wielkie litery,
/// jak dmidecode). `little_endian_fields` = SMBIOS 2.6+.
pub fn formatUuid(raw: [16]u8, little_endian_fields: bool, buf: *[36]u8) []const u8 {
    const order_le = [16]u8{ 3, 2, 1, 0, 5, 4, 7, 6, 8, 9, 10, 11, 12, 13, 14, 15 };
    const order_be = [16]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const order = if (little_endian_fields) order_le else order_be;
    const hex = "0123456789ABCDEF";
    var o: usize = 0;
    for (order, 0..) |src, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buf[o] = '-';
            o += 1;
        }
        buf[o] = hex[raw[src] >> 4];
        buf[o + 1] = hex[raw[src] & 0x0F];
        o += 2;
    }
    return buf[0..36];
}

pub const System = struct {
    handle: u16,
    manufacturer: ?StringField,
    product: ?StringField,
    version: ?StringField,
    serial: ?StringField,
    uuid: ?Uuid,
    wake_up: ?EnumField,
    sku: ?StringField,
    family: ?StringField,
};

pub fn wakeUpTypeName(v: u8) ?[]const u8 {
    return switch (v) {
        0x00 => "Reserved",
        0x01 => "Other",
        0x02 => "Unknown",
        0x03 => "APM Timer",
        0x04 => "Modem Ring",
        0x05 => "LAN Remote",
        0x06 => "Power Switch",
        0x07 => "PCI PME#",
        0x08 => "AC Power Restored",
        else => null,
    };
}

pub fn decodeSystem(s: Structure) ?System {
    if (s.type_id != 1) return null;
    var uuid: ?Uuid = null;
    if (s.length() >= 0x18) {
        var raw: [16]u8 = undefined;
        @memcpy(&raw, s.formatted[0x08..0x18]);
        const all00 = std.mem.allEqual(u8, &raw, 0x00);
        const allFF = std.mem.allEqual(u8, &raw, 0xFF);
        uuid = .{
            .raw = raw,
            .state = if (all00) .not_present else if (allFF) .not_set else .present,
            .little_endian_fields = s.version.atLeast(2, 6),
            .spec = ref("7.2", 1, 0x08),
        };
    }
    return .{
        .handle = s.handle,
        .manufacturer = strField(s, 0x04, false, ref("7.2", 1, 0x04)),
        .product = strField(s, 0x05, false, ref("7.2", 1, 0x05)),
        .version = strField(s, 0x06, false, ref("7.2", 1, 0x06)),
        .serial = strField(s, 0x07, true, ref("7.2", 1, 0x07)),
        .uuid = uuid,
        .wake_up = enumField(s, 0x18, wakeUpTypeName, ref("7.2", 1, 0x18)),
        .sku = strField(s, 0x19, false, ref("7.2", 1, 0x19)),
        .family = strField(s, 0x1A, false, ref("7.2", 1, 0x1A)),
    };
}

// ---------------------------------------------------------------------------
// Typ 2 — Baseboard Information (§7.3)
// ---------------------------------------------------------------------------

pub const Baseboard = struct {
    handle: u16,
    manufacturer: ?StringField,
    product: ?StringField,
    /// Wersja płyty = rewizja (np. "1.02").
    version: ?StringField,
    serial: ?StringField,
    asset_tag: ?StringField,
    feature_flags: ?u8,
    location_in_chassis: ?StringField,
    chassis_handle: ?u16,
    board_type: ?EnumField,
};

pub fn boardTypeName(v: u8) ?[]const u8 {
    return switch (v) {
        0x01 => "Unknown",
        0x02 => "Other",
        0x03 => "Server Blade",
        0x04 => "Connectivity Switch",
        0x05 => "System Management Module",
        0x06 => "Processor Module",
        0x07 => "I/O Module",
        0x08 => "Memory Module",
        0x09 => "Daughter board",
        0x0A => "Motherboard",
        0x0B => "Processor/Memory Module",
        0x0C => "Processor/IO Module",
        0x0D => "Interconnect board",
        else => null,
    };
}

pub fn decodeBaseboard(s: Structure) ?Baseboard {
    if (s.type_id != 2) return null;
    return .{
        .handle = s.handle,
        .manufacturer = strField(s, 0x04, false, ref("7.3", 2, 0x04)),
        .product = strField(s, 0x05, false, ref("7.3", 2, 0x05)),
        .version = strField(s, 0x06, false, ref("7.3", 2, 0x06)),
        .serial = strField(s, 0x07, true, ref("7.3", 2, 0x07)),
        .asset_tag = strField(s, 0x08, true, ref("7.3", 2, 0x08)),
        .feature_flags = s.byte(0x09),
        .location_in_chassis = strField(s, 0x0A, false, ref("7.3", 2, 0x0A)),
        .chassis_handle = s.word(0x0B),
        .board_type = enumField(s, 0x0D, boardTypeName, ref("7.3", 2, 0x0D)),
    };
}

// ---------------------------------------------------------------------------
// Typ 3 — System Enclosure or Chassis (§7.4)
// ---------------------------------------------------------------------------

pub const Chassis = struct {
    handle: u16,
    manufacturer: ?StringField,
    /// `raw` = cały bajt 05h (bit 7 = zamek), `name` wg bitów 6:0.
    chassis_type: ?EnumField,
    lock_present: ?bool,
    version: ?StringField,
    serial: ?StringField,
    asset_tag: ?StringField,
};

/// Typ obudowy (tabela §7.4.1); `v` bez bitu zamka.
pub fn chassisTypeName(v: u8) ?[]const u8 {
    return switch (v & 0x7F) {
        0x01 => "Other",
        0x02 => "Unknown",
        0x03 => "Desktop",
        0x04 => "Low Profile Desktop",
        0x05 => "Pizza Box",
        0x06 => "Mini Tower",
        0x07 => "Tower",
        0x08 => "Portable",
        0x09 => "Laptop",
        0x0A => "Notebook",
        0x0B => "Hand Held",
        0x0C => "Docking Station",
        0x0D => "All in One",
        0x0E => "Sub Notebook",
        0x0F => "Space-saving",
        0x10 => "Lunch Box",
        0x11 => "Main Server Chassis",
        0x12 => "Expansion Chassis",
        0x13 => "SubChassis",
        0x14 => "Bus Expansion Chassis",
        0x15 => "Peripheral Chassis",
        0x16 => "RAID Chassis",
        0x17 => "Rack Mount Chassis",
        0x18 => "Sealed-case PC",
        0x19 => "Multi-system chassis",
        0x1A => "Compact PCI",
        0x1B => "Advanced TCA",
        0x1C => "Blade",
        0x1D => "Blade Enclosure",
        0x1E => "Tablet",
        0x1F => "Convertible",
        0x20 => "Detachable",
        0x21 => "IoT Gateway",
        0x22 => "Embedded PC",
        0x23 => "Mini PC",
        0x24 => "Stick PC",
        else => null,
    };
}

pub fn decodeChassis(s: Structure) ?Chassis {
    if (s.type_id != 3) return null;
    const t = s.byte(0x05);
    return .{
        .handle = s.handle,
        .manufacturer = strField(s, 0x04, false, ref("7.4", 3, 0x04)),
        .chassis_type = enumField(s, 0x05, chassisTypeName, ref("7.4", 3, 0x05)),
        .lock_present = if (t) |b| (b & 0x80) != 0 else null,
        .version = strField(s, 0x06, false, ref("7.4", 3, 0x06)),
        .serial = strField(s, 0x07, true, ref("7.4", 3, 0x07)),
        .asset_tag = strField(s, 0x08, true, ref("7.4", 3, 0x08)),
    };
}

// ---------------------------------------------------------------------------
// Typ 4 — Processor Information (§7.5)
// ---------------------------------------------------------------------------

/// Licznik rdzeni/wątków: bajt (2.5+) i ewentualnie WORD "... 2" (3.0+),
/// używany gdy bajt = FFh (liczba >= 256).
pub const Count = struct {
    raw: u8,
    raw2: ?u16,
    value: ?u16,
    from_extended: bool,
    spec: []const u8,
};

pub const Processor = struct {
    handle: u16,
    socket_designation: ?StringField,
    processor_type: ?EnumField,
    /// Processor Family (06h); FEh = patrz `family2`.
    family: ?u8,
    /// Processor Family 2 (28h, 2.6+).
    family2: ?u16,
    manufacturer: ?StringField,
    /// Processor ID (08h) — dla x86 EAX/EDX z CPUID leaf 1.
    processor_id: ?u64,
    version: ?StringField,
    external_clock_mhz: ?Num(u16),
    max_speed_mhz: ?Num(u16),
    current_speed_mhz: ?Num(u16),
    socket_populated: ?bool,
    cpu_status: ?EnumField,
    upgrade: ?EnumField,
    l1_cache_handle: ?u16,
    l2_cache_handle: ?u16,
    l3_cache_handle: ?u16,
    serial: ?StringField,
    asset_tag: ?StringField,
    part_number: ?StringField,
    core_count: ?Count,
    core_enabled: ?Count,
    thread_count: ?Count,
    /// Thread Enabled (30h, 3.6+).
    thread_enabled: ?Num(u16),
    characteristics: ?u16,
};

pub fn processorTypeName(v: u8) ?[]const u8 {
    return switch (v) {
        0x01 => "Other",
        0x02 => "Unknown",
        0x03 => "Central Processor",
        0x04 => "Math Processor",
        0x05 => "DSP Processor",
        0x06 => "Video Processor",
        else => null,
    };
}

/// Status CPU (bity 2:0 bajtu 18h).
pub fn cpuStatusName(v: u8) ?[]const u8 {
    return switch (v) {
        0 => "Unknown",
        1 => "CPU Enabled",
        2 => "CPU Disabled by User through BIOS Setup",
        3 => "CPU Disabled by BIOS (POST Error)",
        4 => "CPU is Idle, waiting to be enabled",
        7 => "Other",
        else => null,
    };
}

/// Processor Upgrade / typ gniazda (tabela §7.5.5).
/// Wartości 4Ch-57h pochodzą z DSP0134 3.8/3.9.
pub fn processorUpgradeName(v: u8) ?[]const u8 {
    return switch (v) {
        0x01 => "Other",
        0x02 => "Unknown",
        0x03 => "Daughter Board",
        0x04 => "ZIF Socket",
        0x05 => "Replaceable Piggy Back",
        0x06 => "None",
        0x07 => "LIF Socket",
        0x08 => "Slot 1",
        0x09 => "Slot 2",
        0x0A => "370-pin socket",
        0x0B => "Slot A",
        0x0C => "Slot M",
        0x0D => "Socket 423",
        0x0E => "Socket A (Socket 462)",
        0x0F => "Socket 478",
        0x10 => "Socket 754",
        0x11 => "Socket 940",
        0x12 => "Socket 939",
        0x13 => "Socket mPGA604",
        0x14 => "Socket LGA771",
        0x15 => "Socket LGA775",
        0x16 => "Socket S1",
        0x17 => "Socket AM2",
        0x18 => "Socket F (1207)",
        0x19 => "Socket LGA1366",
        0x1A => "Socket G34",
        0x1B => "Socket AM3",
        0x1C => "Socket C32",
        0x1D => "Socket LGA1156",
        0x1E => "Socket LGA1567",
        0x1F => "Socket PGA988A",
        0x20 => "Socket BGA1288",
        0x21 => "Socket rPGA988B",
        0x22 => "Socket BGA1023",
        0x23 => "Socket BGA1224",
        0x24 => "Socket LGA1155",
        0x25 => "Socket LGA1356",
        0x26 => "Socket LGA2011",
        0x27 => "Socket FS1",
        0x28 => "Socket FS2",
        0x29 => "Socket FM1",
        0x2A => "Socket FM2",
        0x2B => "Socket LGA2011-3",
        0x2C => "Socket LGA1356-3",
        0x2D => "Socket LGA1150",
        0x2E => "Socket BGA1168",
        0x2F => "Socket BGA1234",
        0x30 => "Socket BGA1364",
        0x31 => "Socket AM4",
        0x32 => "Socket LGA1151",
        0x33 => "Socket BGA1356",
        0x34 => "Socket BGA1440",
        0x35 => "Socket BGA1515",
        0x36 => "Socket LGA3647-1",
        0x37 => "Socket SP3",
        0x38 => "Socket SP3r2",
        0x39 => "Socket LGA2066",
        0x3A => "Socket BGA1392",
        0x3B => "Socket BGA1510",
        0x3C => "Socket BGA1528",
        0x3D => "Socket LGA4189",
        0x3E => "Socket LGA1200",
        0x3F => "Socket LGA4677",
        0x40 => "Socket LGA1700",
        0x41 => "Socket BGA1744",
        0x42 => "Socket BGA1781",
        0x43 => "Socket BGA1211",
        0x44 => "Socket BGA2422",
        0x45 => "Socket LGA1211",
        0x46 => "Socket LGA2422",
        0x47 => "Socket LGA5773",
        0x48 => "Socket BGA5773",
        0x49 => "Socket AM5",
        0x4A => "Socket SP5",
        0x4B => "Socket SP6",
        0x4C => "Socket BGA883",
        0x4D => "Socket BGA1190",
        0x4E => "Socket BGA4129",
        0x4F => "Socket LGA4710",
        0x50 => "Socket LGA7529",
        0x51 => "Socket BGA1964",
        0x52 => "Socket BGA1792",
        0x53 => "Socket BGA2049",
        0x54 => "Socket BGA2551",
        0x55 => "Socket LGA1851",
        0x56 => "Socket BGA2114",
        0x57 => "Socket BGA2833",
        else => null,
    };
}

fn speedField(s: Structure, off: usize, spec: []const u8) ?Num(u16) {
    const w = s.word(off) orelse return null;
    return .{ .raw = w, .value = if (w == 0) null else w, .spec = spec };
}

fn countField(s: Structure, off8: usize, off16: usize, spec8: []const u8, spec16: []const u8) ?Count {
    const b = s.byte(off8) orelse return null;
    const w = s.word(off16);
    var c: Count = .{ .raw = b, .raw2 = w, .value = null, .from_extended = false, .spec = spec8 };
    if (b == 0xFF) {
        if (w) |x| {
            if (x != 0 and x != 0xFFFF) {
                c.value = x;
                c.from_extended = true;
                c.spec = spec16;
            } else {
                c.value = 0xFF;
            }
        } else {
            c.value = 0xFF;
        }
    } else if (b != 0) {
        c.value = b;
    }
    return c;
}

pub fn decodeProcessor(s: Structure) ?Processor {
    if (s.type_id != 4) return null;
    const status = s.byte(0x18);
    const fam = s.byte(0x06);
    const te = s.word(0x30);
    return .{
        .handle = s.handle,
        .socket_designation = strField(s, 0x04, false, ref("7.5", 4, 0x04)),
        .processor_type = enumField(s, 0x05, processorTypeName, ref("7.5", 4, 0x05)),
        .family = fam,
        .family2 = s.word(0x28),
        .manufacturer = strField(s, 0x07, false, ref("7.5", 4, 0x07)),
        .processor_id = s.qword(0x08),
        .version = strField(s, 0x10, false, ref("7.5", 4, 0x10)),
        .external_clock_mhz = speedField(s, 0x12, ref("7.5", 4, 0x12)),
        .max_speed_mhz = speedField(s, 0x14, ref("7.5", 4, 0x14)),
        .current_speed_mhz = speedField(s, 0x16, ref("7.5", 4, 0x16)),
        .socket_populated = if (status) |b| (b & 0x40) != 0 else null,
        .cpu_status = if (status) |b| EnumField{ .raw = b & 0x07, .name = cpuStatusName(b & 0x07), .spec = ref("7.5", 4, 0x18) } else null,
        .upgrade = enumField(s, 0x19, processorUpgradeName, ref("7.5", 4, 0x19)),
        .l1_cache_handle = s.word(0x1A),
        .l2_cache_handle = s.word(0x1C),
        .l3_cache_handle = s.word(0x1E),
        .serial = strField(s, 0x20, true, ref("7.5", 4, 0x20)),
        .asset_tag = strField(s, 0x21, true, ref("7.5", 4, 0x21)),
        .part_number = strField(s, 0x22, false, ref("7.5", 4, 0x22)),
        .core_count = countField(s, 0x23, 0x2A, ref("7.5", 4, 0x23), ref("7.5", 4, 0x2A)),
        .core_enabled = countField(s, 0x24, 0x2C, ref("7.5", 4, 0x24), ref("7.5", 4, 0x2C)),
        .thread_count = countField(s, 0x25, 0x2E, ref("7.5", 4, 0x25), ref("7.5", 4, 0x2E)),
        .thread_enabled = if (te) |w| Num(u16){ .raw = w, .value = if (w == 0 or w == 0xFFFF) null else w, .spec = ref("7.5", 4, 0x30) } else null,
        .characteristics = s.word(0x26),
    };
}

// ---------------------------------------------------------------------------
// Typ 7 — Cache Information (§7.8)
// ---------------------------------------------------------------------------

/// Rozmiar cache: WORD (bit 15 = ziarnistość 1 KiB / 64 KiB) albo DWORD
/// "Size 2" (3.1+, bit 31 = ziarnistość), używany gdy WORD = FFFFh.
pub const CacheSize = struct {
    raw: u16,
    raw2: ?u32,
    bytes: ?u64,
    from_extended: bool,
    spec: []const u8,
};

pub const Cache = struct {
    handle: u16,
    socket_designation: ?StringField,
    configuration: ?u16,
    /// Poziom cache 1..8 (bity 2:0 konfiguracji + 1).
    level: ?u8,
    socketed: ?bool,
    enabled: ?bool,
    /// 0 = internal, 1 = external, 2 = reserved, 3 = unknown.
    location: ?u2,
    /// 0 = write through, 1 = write back, 2 = zależny od adresu, 3 = unknown.
    operational_mode: ?u2,
    max_size: ?CacheSize,
    installed_size: ?CacheSize,
    speed_ns: ?Num(u8),
    error_correction: ?EnumField,
    system_cache_type: ?EnumField,
    associativity: ?EnumField,
};

/// Typ korekcji błędów cache (§7.8.5).
pub fn cacheErrorCorrectionName(v: u8) ?[]const u8 {
    return switch (v) {
        0x01 => "Other",
        0x02 => "Unknown",
        0x03 => "None",
        0x04 => "Parity",
        0x05 => "Single-bit ECC",
        0x06 => "Multi-bit ECC",
        else => null,
    };
}

/// Typ cache (§7.8.6).
pub fn systemCacheTypeName(v: u8) ?[]const u8 {
    return switch (v) {
        0x01 => "Other",
        0x02 => "Unknown",
        0x03 => "Instruction",
        0x04 => "Data",
        0x05 => "Unified",
        else => null,
    };
}

/// Asocjacyjność (§7.8.7).
pub fn associativityName(v: u8) ?[]const u8 {
    return switch (v) {
        0x01 => "Other",
        0x02 => "Unknown",
        0x03 => "Direct Mapped",
        0x04 => "2-way Set-Associative",
        0x05 => "4-way Set-Associative",
        0x06 => "Fully Associative",
        0x07 => "8-way Set-Associative",
        0x08 => "16-way Set-Associative",
        0x09 => "12-way Set-Associative",
        0x0A => "24-way Set-Associative",
        0x0B => "32-way Set-Associative",
        0x0C => "48-way Set-Associative",
        0x0D => "64-way Set-Associative",
        0x0E => "20-way Set-Associative",
        else => null,
    };
}

fn cacheSize(s: Structure, off16: usize, off32: usize, spec16: []const u8, spec32: []const u8) ?CacheSize {
    const w = s.word(off16) orelse return null;
    const d = s.dword(off32);
    var c: CacheSize = .{ .raw = w, .raw2 = d, .bytes = null, .from_extended = false, .spec = spec16 };
    if (w == 0xFFFF) {
        if (d) |x| {
            const gran: u64 = if (x & 0x8000_0000 != 0) 64 * 1024 else 1024;
            c.bytes = @as(u64, x & 0x7FFF_FFFF) * gran;
            c.from_extended = true;
            c.spec = spec32;
        }
    } else {
        const gran: u64 = if (w & 0x8000 != 0) 64 * 1024 else 1024;
        c.bytes = @as(u64, w & 0x7FFF) * gran;
    }
    return c;
}

pub fn decodeCache(s: Structure) ?Cache {
    if (s.type_id != 7) return null;
    const cfg = s.word(0x05);
    const spd = s.byte(0x0F);
    return .{
        .handle = s.handle,
        .socket_designation = strField(s, 0x04, false, ref("7.8", 7, 0x04)),
        .configuration = cfg,
        .level = if (cfg) |c| @as(u8, @intCast(c & 0x7)) + 1 else null,
        .socketed = if (cfg) |c| (c & 0x08) != 0 else null,
        .enabled = if (cfg) |c| (c & 0x80) != 0 else null,
        .location = if (cfg) |c| @as(u2, @intCast((c >> 5) & 0x3)) else null,
        .operational_mode = if (cfg) |c| @as(u2, @intCast((c >> 8) & 0x3)) else null,
        .max_size = cacheSize(s, 0x07, 0x13, ref("7.8", 7, 0x07), ref("7.8", 7, 0x13)),
        .installed_size = cacheSize(s, 0x09, 0x17, ref("7.8", 7, 0x09), ref("7.8", 7, 0x17)),
        .speed_ns = if (spd) |b| Num(u8){ .raw = b, .value = if (b == 0) null else b, .spec = ref("7.8", 7, 0x0F) } else null,
        .error_correction = enumField(s, 0x10, cacheErrorCorrectionName, ref("7.8", 7, 0x10)),
        .system_cache_type = enumField(s, 0x11, systemCacheTypeName, ref("7.8", 7, 0x11)),
        .associativity = enumField(s, 0x12, associativityName, ref("7.8", 7, 0x12)),
    };
}

// ---------------------------------------------------------------------------
// Typ 16 — Physical Memory Array (§7.17)
// ---------------------------------------------------------------------------

/// Maksymalna pojemność: DWORD 07h w KiB; 8000_0000h = patrz Extended
/// Maximum Capacity (QWORD 0Fh, w bajtach, 2.7+).
pub const Capacity = struct {
    raw: u32,
    raw_extended: ?u64,
    bytes: ?u64,
    from_extended: bool,
    spec: []const u8,
};

pub const MemoryArray = struct {
    handle: u16,
    location: ?EnumField,
    use: ?EnumField,
    error_correction: ?EnumField,
    max_capacity: ?Capacity,
    error_info_handle: ?u16,
    /// Liczba gniazd/urządzeń pamięci w tej macierzy.
    num_devices: ?Num(u16),
};

/// Lokalizacja macierzy pamięci (§7.17.1).
pub fn memoryArrayLocationName(v: u8) ?[]const u8 {
    return switch (v) {
        0x01 => "Other",
        0x02 => "Unknown",
        0x03 => "System board or motherboard",
        0x04 => "ISA add-on card",
        0x05 => "EISA add-on card",
        0x06 => "PCI add-on card",
        0x07 => "MCA add-on card",
        0x08 => "PCMCIA add-on card",
        0x09 => "Proprietary add-on card",
        0x0A => "NuBus",
        0xA0 => "PC-98/C20 add-on card",
        0xA1 => "PC-98/C24 add-on card",
        0xA2 => "PC-98/E add-on card",
        0xA3 => "PC-98/Local bus add-on card",
        0xA4 => "CXL add-on card",
        else => null,
    };
}

/// Przeznaczenie macierzy pamięci (§7.17.2).
pub fn memoryArrayUseName(v: u8) ?[]const u8 {
    return switch (v) {
        0x01 => "Other",
        0x02 => "Unknown",
        0x03 => "System memory",
        0x04 => "Video memory",
        0x05 => "Flash memory",
        0x06 => "Non-volatile RAM",
        0x07 => "Cache memory",
        else => null,
    };
}

/// Typ korekcji błędów pamięci (§7.17.3).
pub fn memoryErrorCorrectionName(v: u8) ?[]const u8 {
    return switch (v) {
        0x01 => "Other",
        0x02 => "Unknown",
        0x03 => "None",
        0x04 => "Parity",
        0x05 => "Single-bit ECC",
        0x06 => "Multi-bit ECC",
        0x07 => "CRC",
        else => null,
    };
}

pub fn decodeMemoryArray(s: Structure) ?MemoryArray {
    if (s.type_id != 16) return null;
    var cap: ?Capacity = null;
    if (s.dword(0x07)) |raw| {
        const ext = s.qword(0x0F);
        var c: Capacity = .{ .raw = raw, .raw_extended = ext, .bytes = null, .from_extended = false, .spec = ref("7.17", 16, 0x07) };
        if (raw == 0x8000_0000) {
            if (ext) |e| {
                c.bytes = e;
                c.from_extended = true;
                c.spec = ref("7.17", 16, 0x0F);
            }
        } else {
            c.bytes = @as(u64, raw) * 1024;
        }
        cap = c;
    }
    const nd = s.word(0x0D);
    return .{
        .handle = s.handle,
        .location = enumField(s, 0x04, memoryArrayLocationName, ref("7.17", 16, 0x04)),
        .use = enumField(s, 0x05, memoryArrayUseName, ref("7.17", 16, 0x05)),
        .error_correction = enumField(s, 0x06, memoryErrorCorrectionName, ref("7.17", 16, 0x06)),
        .max_capacity = cap,
        .error_info_handle = s.word(0x0B),
        .num_devices = if (nd) |n| Num(u16){ .raw = n, .value = n, .spec = ref("7.17", 16, 0x0D) } else null,
    };
}

// ---------------------------------------------------------------------------
// Typ 17 — Memory Device (§7.18)
// ---------------------------------------------------------------------------

pub const SizeState = enum {
    /// Moduł zainstalowany, rozmiar znany.
    installed,
    /// Size = 0: gniazdo puste.
    empty,
    /// Size = FFFFh: rozmiar nieznany (moduł może być obecny).
    unknown,
};

/// Rozmiar modułu (WORD 0Ch): 0 = puste, FFFFh = nieznany, 7FFFh = patrz
/// Extended Size (DWORD 1Ch, bity 30:0 w MiB, 2.7+); bit 15: 1 = KiB, 0 = MiB.
pub const MemorySize = struct {
    raw: u16,
    raw_extended: ?u32,
    state: SizeState,
    bytes: ?u64,
    from_extended: bool,
    spec: []const u8,
};

/// Prędkość w MT/s (WORD; 0 = nieznana; FFFFh = patrz pole rozszerzone
/// DWORD, SMBIOS 3.3+, bity 30:0).
pub const Speed = struct {
    raw: u16,
    raw_extended: ?u32,
    mts: ?u32,
    from_extended: bool,
    spec: []const u8,
};

/// Type Detail (WORD 13h, §7.18.3) — mapa bitowa.
pub const TypeDetail = struct {
    raw: u16,
    spec: []const u8,

    pub const bit_names = [16]?[]const u8{
        null,            "Other",                 "Unknown",                   "Fast-paged",
        "Static column", "Pseudo-static",         "RAMBUS",                    "Synchronous",
        "CMOS",          "EDO",                   "Window DRAM",               "Cache DRAM",
        "Non-volatile",  "Registered (Buffered)", "Unbuffered (Unregistered)", "LRDIMM",
    };

    pub fn has(self: TypeDetail, bit: u4) bool {
        return (self.raw >> bit) & 1 != 0;
    }

    /// Wypełnia `out` nazwami ustawionych bitów i zwraca wypełniony wycinek.
    pub fn names(self: TypeDetail, out: *[16][]const u8) [][]const u8 {
        var n: usize = 0;
        for (bit_names, 0..) |maybe, i| {
            const name = maybe orelse continue;
            if (self.has(@intCast(i))) {
                out[n] = name;
                n += 1;
            }
        }
        return out[0..n];
    }
};

pub const MemoryDevice = struct {
    handle: u16,
    array_handle: ?u16,
    error_info_handle: ?u16,
    /// Szerokość całkowita w bitach (z ECC); FFFFh = nieznana.
    total_width_bits: ?Num(u16),
    /// Szerokość danych w bitach; FFFFh = nieznana.
    data_width_bits: ?Num(u16),
    size: ?MemorySize,
    form_factor: ?EnumField,
    device_set: ?u8,
    device_locator: ?StringField,
    bank_locator: ?StringField,
    memory_type: ?EnumField,
    type_detail: ?TypeDetail,
    speed: ?Speed,
    manufacturer: ?StringField,
    serial: ?StringField,
    asset_tag: ?StringField,
    part_number: ?StringField,
    /// Ranki (Attributes 1Bh, bity 3:0; 0 = nieznane).
    rank: ?Num(u8),
    configured_speed: ?Speed,
    min_voltage_mv: ?Num(u16),
    max_voltage_mv: ?Num(u16),
    configured_voltage_mv: ?Num(u16),
    technology: ?EnumField,

    /// Czy w gnieździe jest moduł (rozmiar znany i > 0 albo nieznany).
    pub fn populated(self: MemoryDevice) bool {
        const sz = self.size orelse return false;
        return sz.state != .empty;
    }
};

/// Form factor (§7.18.1).
pub fn formFactorName(v: u8) ?[]const u8 {
    return switch (v) {
        0x01 => "Other",
        0x02 => "Unknown",
        0x03 => "SIMM",
        0x04 => "SIP",
        0x05 => "Chip",
        0x06 => "DIP",
        0x07 => "ZIP",
        0x08 => "Proprietary Card",
        0x09 => "DIMM",
        0x0A => "TSOP",
        0x0B => "Row of chips",
        0x0C => "RIMM",
        0x0D => "SODIMM",
        0x0E => "SRIMM",
        0x0F => "FB-DIMM",
        0x10 => "Die",
        0x11 => "CAMM",
        else => null,
    };
}

/// Typ pamięci (§7.18.2).
pub fn memoryTypeName(v: u8) ?[]const u8 {
    return switch (v) {
        0x01 => "Other",
        0x02 => "Unknown",
        0x03 => "DRAM",
        0x04 => "EDRAM",
        0x05 => "VRAM",
        0x06 => "SRAM",
        0x07 => "RAM",
        0x08 => "ROM",
        0x09 => "FLASH",
        0x0A => "EEPROM",
        0x0B => "FEPROM",
        0x0C => "EPROM",
        0x0D => "CDRAM",
        0x0E => "3DRAM",
        0x0F => "SDRAM",
        0x10 => "SGRAM",
        0x11 => "RDRAM",
        0x12 => "DDR",
        0x13 => "DDR2",
        0x14 => "DDR2 FB-DIMM",
        0x18 => "DDR3",
        0x19 => "FBD2",
        0x1A => "DDR4",
        0x1B => "LPDDR",
        0x1C => "LPDDR2",
        0x1D => "LPDDR3",
        0x1E => "LPDDR4",
        0x1F => "Logical non-volatile device",
        0x20 => "HBM",
        0x21 => "HBM2",
        0x22 => "DDR5",
        0x23 => "LPDDR5",
        0x24 => "HBM3",
        else => null,
    };
}

/// Technologia pamięci (§7.18.6, 3.2+).
pub fn memoryTechnologyName(v: u8) ?[]const u8 {
    return switch (v) {
        0x01 => "Other",
        0x02 => "Unknown",
        0x03 => "DRAM",
        0x04 => "NVDIMM-N",
        0x05 => "NVDIMM-F",
        0x06 => "NVDIMM-P",
        0x07 => "Intel Optane persistent memory",
        else => null,
    };
}

fn memSpeed(s: Structure, off16: usize, off32: usize, spec16: []const u8, spec32: []const u8) ?Speed {
    const w = s.word(off16) orelse return null;
    const ext = s.dword(off32);
    var sp: Speed = .{ .raw = w, .raw_extended = ext, .mts = null, .from_extended = false, .spec = spec16 };
    if (w == 0xFFFF) {
        if (ext) |e| {
            const v = e & 0x7FFF_FFFF;
            sp.from_extended = true;
            sp.spec = spec32;
            if (v != 0) sp.mts = v;
        }
    } else if (w != 0) {
        sp.mts = w;
    }
    return sp;
}

fn widthField(s: Structure, off: usize, spec: []const u8) ?Num(u16) {
    const w = s.word(off) orelse return null;
    return .{ .raw = w, .value = if (w == 0xFFFF) null else w, .spec = spec };
}

fn voltageField(s: Structure, off: usize, spec: []const u8) ?Num(u16) {
    const w = s.word(off) orelse return null;
    return .{ .raw = w, .value = if (w == 0) null else w, .spec = spec };
}

pub fn decodeMemoryDevice(s: Structure) ?MemoryDevice {
    if (s.type_id != 17) return null;
    var size: ?MemorySize = null;
    if (s.word(0x0C)) |raw| {
        const ext = s.dword(0x1C);
        var sz: MemorySize = .{ .raw = raw, .raw_extended = ext, .state = .installed, .bytes = null, .from_extended = false, .spec = ref("7.18", 17, 0x0C) };
        if (raw == 0) {
            sz.state = .empty;
            sz.bytes = 0;
        } else if (raw == 0xFFFF) {
            sz.state = .unknown;
        } else if (raw == 0x7FFF) {
            if (ext) |e| {
                sz.from_extended = true;
                sz.spec = ref("7.18", 17, 0x1C);
                sz.bytes = @as(u64, e & 0x7FFF_FFFF) * 1024 * 1024;
            } else {
                // 7FFFh bez pola rozszerzonego: niespójne, rozmiar nieznany.
                sz.state = .unknown;
            }
        } else if (raw & 0x8000 != 0) {
            sz.bytes = @as(u64, raw & 0x7FFF) * 1024;
        } else {
            sz.bytes = @as(u64, raw) * 1024 * 1024;
        }
        size = sz;
    }
    const attrs = s.byte(0x1B);
    const td = s.word(0x13);
    return .{
        .handle = s.handle,
        .array_handle = s.word(0x04),
        .error_info_handle = s.word(0x06),
        .total_width_bits = widthField(s, 0x08, ref("7.18", 17, 0x08)),
        .data_width_bits = widthField(s, 0x0A, ref("7.18", 17, 0x0A)),
        .size = size,
        .form_factor = enumField(s, 0x0E, formFactorName, ref("7.18", 17, 0x0E)),
        .device_set = s.byte(0x0F),
        .device_locator = strField(s, 0x10, false, ref("7.18", 17, 0x10)),
        .bank_locator = strField(s, 0x11, false, ref("7.18", 17, 0x11)),
        .memory_type = enumField(s, 0x12, memoryTypeName, ref("7.18", 17, 0x12)),
        .type_detail = if (td) |w| TypeDetail{ .raw = w, .spec = ref("7.18", 17, 0x13) } else null,
        .speed = memSpeed(s, 0x15, 0x54, ref("7.18", 17, 0x15), ref("7.18", 17, 0x54)),
        .manufacturer = strField(s, 0x17, false, ref("7.18", 17, 0x17)),
        .serial = strField(s, 0x18, true, ref("7.18", 17, 0x18)),
        .asset_tag = strField(s, 0x19, true, ref("7.18", 17, 0x19)),
        .part_number = strField(s, 0x1A, false, ref("7.18", 17, 0x1A)),
        .rank = if (attrs) |a| Num(u8){ .raw = a, .value = if (a & 0x0F == 0) null else a & 0x0F, .spec = ref("7.18", 17, 0x1B) } else null,
        .configured_speed = memSpeed(s, 0x20, 0x58, ref("7.18", 17, 0x20), ref("7.18", 17, 0x58)),
        .min_voltage_mv = voltageField(s, 0x22, ref("7.18", 17, 0x22)),
        .max_voltage_mv = voltageField(s, 0x24, ref("7.18", 17, 0x24)),
        .configured_voltage_mv = voltageField(s, 0x26, ref("7.18", 17, 0x26)),
        .technology = enumField(s, 0x28, memoryTechnologyName, ref("7.18", 17, 0x28)),
    };
}

// ---------------------------------------------------------------------------
// Podsumowanie pamięci (heurystyka kanałów)
// ---------------------------------------------------------------------------

/// Pewność wyniku heurystycznego.
pub const Confidence = enum(u8) { none = 0, low = 1, medium = 2, high = 3 };

/// Zgadnięty kanał modułu: `key` = (grupa << 8) | litera/cyfra kanału,
/// grupa = numer kontrolera / gniazda CPU, jeżeli udało się go znaleźć.
pub const ChannelGuess = struct {
    key: u16,
    confidence: Confidence,
};

pub const MemorySummary = struct {
    /// Suma rozmiarów modułów o znanym rozmiarze.
    total_bytes: u64,
    /// Gniazda z modułem (w tym moduły o nieznanym rozmiarze).
    populated_slots: u16,
    /// Liczba struktur typu 17 należących do pamięci systemowej.
    total_slots: u16,
    /// Suma "Number of Memory Devices" z typów 16 (pamięć systemowa), jeśli są.
    declared_slots: ?u32,
    /// Moduły obecne, ale z rozmiarem FFFFh (nieznanym).
    unknown_size_modules: u16,
    /// Typ pamięci pierwszego obsadzonego gniazda (surowy bajt §7.18.2).
    memory_type: ?u8,
    /// Obsadzone gniazda zgłaszają różne typy pamięci.
    mixed_types: bool,
    /// HEURYSTYKA: liczba różnych kanałów wywnioskowana z lokatorów
    /// (Device/Bank Locator). Dla DDR5 to kanały wg nazewnictwa płyty,
    /// nie 32-bitowe podkanały. Null, gdy nie da się wywnioskować.
    channels: ?u8,
    channel_confidence: Confidence,
    channel_method: []const u8,
};

fn channelAfterKeyword(s: []const u8) ?u8 {
    const idx = std.ascii.indexOfIgnoreCase(s, "CHANNEL") orelse return null;
    var i = idx + "CHANNEL".len;
    while (i < s.len and (s[i] == ' ' or s[i] == '_' or s[i] == '-' or s[i] == ':')) : (i += 1) {}
    if (i < s.len and std.ascii.isAlphanumeric(s[i])) return std.ascii.toUpper(s[i]);
    return null;
}

fn channelAfterDimm(s: []const u8) ?u8 {
    var from: usize = 0;
    while (from < s.len) {
        const rel = std.ascii.indexOfIgnoreCase(s[from..], "DIMM") orelse return null;
        var i = from + rel + 4;
        if (i < s.len and (s[i] == ' ' or s[i] == '_' or s[i] == '-')) i += 1;
        if (i < s.len) {
            const c = std.ascii.toUpper(s[i]);
            if (c >= 'A' and c <= 'H') {
                const after_ok = i + 1 == s.len or std.ascii.isDigit(s[i + 1]) or
                    s[i + 1] == ' ' or s[i + 1] == '_' or s[i + 1] == '-';
                if (after_ok) return c;
            }
        }
        from = from + rel + 4;
    }
    return null;
}

fn digitAfter(s: []const u8, keyword: []const u8) ?u8 {
    const idx = std.ascii.indexOfIgnoreCase(s, keyword) orelse return null;
    const i = idx + keyword.len;
    if (i < s.len and std.ascii.isDigit(s[i])) return s[i] - '0';
    return null;
}

/// Grupa kanału: "Controller<d>", "CPU<d>", "Node<d>" albo prefiks "P<d> " (AMD).
fn channelGroup(s: []const u8) ?u8 {
    if (digitAfter(s, "CONTROLLER")) |d| return d;
    if (digitAfter(s, "CPU")) |d| return d;
    if (digitAfter(s, "NODE")) |d| return d;
    if (s.len >= 3 and (s[0] == 'P' or s[0] == 'p') and std.ascii.isDigit(s[1]) and s[2] == ' ') return s[1] - '0';
    return null;
}

/// HEURYSTYKA: zgaduje kanał z lokatorów. Wzorce:
///   * "...CHANNEL A..." (np. "P0 CHANNEL A", "Controller0-ChannelA-DIMM0") -> medium,
///   * "DIMM_A1", "DIMMA1", "DIMM A" -> low.
pub fn guessChannel(device_locator: ?[]const u8, bank_locator: ?[]const u8) ?ChannelGuess {
    const sources = [_]?[]const u8{ bank_locator, device_locator };
    var group: u8 = 0;
    for (sources) |maybe| {
        const s = maybe orelse continue;
        if (channelGroup(s)) |g| {
            group = g;
            break;
        }
    }
    for (sources) |maybe| {
        const s = maybe orelse continue;
        if (channelAfterKeyword(s)) |c| return .{ .key = (@as(u16, group) << 8) | c, .confidence = .medium };
    }
    for (sources) |maybe| {
        const s = maybe orelse continue;
        if (channelAfterDimm(s)) |c| return .{ .key = (@as(u16, group) << 8) | c, .confidence = .low };
    }
    return null;
}

/// Podsumowanie pamięci systemowej. Liczba kanałów jest HEURYSTYKĄ opartą na
/// nazwach lokatorów — patrz `MemorySummary.channel_confidence`.
pub fn summarizeMemory(table: Table) MemorySummary {
    var sys_arrays: [64]u16 = undefined;
    var n_arrays: usize = 0;
    var any_array = false;
    var declared: ?u32 = null;

    var it = table.iterator();
    while (it.next()) |s| {
        const a = decodeMemoryArray(s) orelse continue;
        any_array = true;
        const use = if (a.use) |u| u.raw else 0;
        if (use != 0x03) continue;
        if (n_arrays < sys_arrays.len) {
            sys_arrays[n_arrays] = a.handle;
            n_arrays += 1;
        }
        if (a.num_devices) |nd| declared = (declared orelse 0) + nd.raw;
    }

    var sum: MemorySummary = .{
        .total_bytes = 0,
        .populated_slots = 0,
        .total_slots = 0,
        .declared_slots = declared,
        .unknown_size_modules = 0,
        .memory_type = null,
        .mixed_types = false,
        .channels = null,
        .channel_confidence = .none,
        .channel_method = "brak danych: lokatory nie pasują do znanych wzorców",
    };
    var keys: [32]u16 = undefined;
    var n_keys: usize = 0;
    var min_conf: Confidence = .medium;
    var missing = false;

    it = table.iterator();
    while (it.next()) |s| {
        const d = decodeMemoryDevice(s) orelse continue;
        if (any_array and n_arrays > 0) {
            const ah = d.array_handle orelse continue;
            if (std.mem.indexOfScalar(u16, sys_arrays[0..n_arrays], ah) == null) continue;
        }
        sum.total_slots +|= 1;
        if (!d.populated()) continue;
        sum.populated_slots +|= 1;
        const sz = d.size.?;
        if (sz.bytes) |b| sum.total_bytes +|= b else sum.unknown_size_modules +|= 1;
        if (d.memory_type) |mt| {
            if (sum.memory_type) |prev| {
                if (prev != mt.raw) sum.mixed_types = true;
            } else sum.memory_type = mt.raw;
        }
        const dl = if (d.device_locator) |f| f.value else null;
        const bl = if (d.bank_locator) |f| f.value else null;
        if (guessChannel(dl, bl)) |g| {
            if (std.mem.indexOfScalar(u16, keys[0..n_keys], g.key) == null and n_keys < keys.len) {
                keys[n_keys] = g.key;
                n_keys += 1;
            }
            if (@intFromEnum(g.confidence) < @intFromEnum(min_conf)) min_conf = g.confidence;
        } else missing = true;
    }

    if (n_keys > 0) {
        sum.channels = @intCast(n_keys);
        sum.channel_confidence = if (missing) .low else min_conf;
        sum.channel_method = switch (sum.channel_confidence) {
            .medium => "heurystyka: słowo 'CHANNEL' w lokatorach obsadzonych gniazd",
            else => "heurystyka: wzorzec DIMM_<litera> lub niepełne dane lokatorów",
        };
    }
    return sum;
}

// ---------------------------------------------------------------------------
// Maskowanie danych wrażliwych
// ---------------------------------------------------------------------------

pub const MaskResult = struct {
    strings_masked: usize = 0,
    uuids_zeroed: usize = 0,
};

/// Offsety pól napisowych z danymi wrażliwymi dla danego typu struktury.
fn sensitiveStringOffsets(type_id: u8) []const u8 {
    return switch (type_id) {
        1 => &.{0x07},
        2, 3 => &.{ 0x07, 0x08 },
        4 => &.{ 0x20, 0x21 },
        17 => &.{ 0x18, 0x19 },
        else => &.{},
    };
}

/// Maskuje w miejscu gołe dane tablicy (bez nagłówka): napisy numerów
/// seryjnych i asset tagów (typy 1, 2, 3, 4, 17) zastępuje 'X' tej samej
/// długości, UUID typu 1 zeruje. Długości i offsety struktur pozostają bez zmian.
pub fn maskTableData(data: []u8) MaskResult {
    var res: MaskResult = .{};
    var it: Iterator = .{ .data = data, .version = .{ .major = 3, .minor = 0 } };
    while (it.next()) |s| {
        for (sensitiveStringOffsets(s.type_id)) |off| {
            const idx = s.byte(off) orelse continue;
            const span = s.stringSpan(idx) orelse continue;
            if (span.len == 0) continue;
            @memset(data[s.strings_offset + span.start ..][0..span.len], 'X');
            res.strings_masked += 1;
        }
        if (s.type_id == 1 and s.length() >= 0x18) {
            @memset(data[s.offset + 0x08 ..][0..16], 0);
            res.uuids_zeroed += 1;
        }
    }
    return res;
}

/// Maskuje w miejscu bufor `RawSMBIOSData` (patrz `maskTableData`).
pub fn maskSerials(buf: []u8) Error!MaskResult {
    const t = try fromRawSmbiosData(buf);
    return maskTableData(buf[raw_header_len..][0..t.data.len]);
}

// ---------------------------------------------------------------------------
// Testy — wyłącznie syntetyczne tablice budowane wg DSP0134
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Obszar sformatowany budowanej struktury (offsety bezwzględne od 00h).
const Body = struct {
    buf: [0x100]u8 = [_]u8{0} ** 0x100,
    len: usize,

    fn init(len: usize) Body {
        return .{ .len = len };
    }
    fn b(self: *Body, off: usize, v: u8) void {
        self.buf[off] = v;
    }
    fn w(self: *Body, off: usize, v: u16) void {
        std.mem.writeInt(u16, self.buf[off..][0..2], v, .little);
    }
    fn d(self: *Body, off: usize, v: u32) void {
        std.mem.writeInt(u32, self.buf[off..][0..4], v, .little);
    }
    fn q(self: *Body, off: usize, v: u64) void {
        std.mem.writeInt(u64, self.buf[off..][0..8], v, .little);
    }
    fn bytes(self: *Body, off: usize, src: []const u8) void {
        @memcpy(self.buf[off..][0..src.len], src);
    }
};

const Builder = struct {
    alloc: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,

    fn deinit(self: *Builder) void {
        self.out.deinit(self.alloc);
    }

    fn add(self: *Builder, type_id: u8, handle: u16, body: *Body, strings: []const []const u8) !void {
        body.buf[0] = type_id;
        body.buf[1] = @intCast(body.len);
        body.w(2, handle);
        try self.out.appendSlice(self.alloc, body.buf[0..body.len]);
        if (strings.len == 0) {
            try self.out.appendSlice(self.alloc, &.{ 0, 0 });
        } else {
            for (strings) |s| {
                try self.out.appendSlice(self.alloc, s);
                try self.out.append(self.alloc, 0);
            }
            try self.out.append(self.alloc, 0);
        }
    }

    fn endOfTable(self: *Builder) !void {
        var e = Body.init(4);
        try self.add(127, 0xFEFF, &e, &.{});
    }

    /// Bufor w formacie `RawSMBIOSData`; właściciel: wywołujący.
    fn raw(self: *Builder, major: u8, minor: u8) ![]u8 {
        const buf = try self.alloc.alloc(u8, raw_header_len + self.out.items.len);
        buf[0] = 0;
        buf[1] = major;
        buf[2] = minor;
        buf[3] = 0;
        std.mem.writeInt(u32, buf[4..8], @intCast(self.out.items.len), .little);
        @memcpy(buf[raw_header_len..], self.out.items);
        return buf;
    }
};

const test_uuid = [16]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF };

/// Typowy desktop: typy 0, 1, 2, 3, 4, 7, 16, 17 x2, 127.
fn buildDesktop(bld: *Builder) !void {
    var t0 = Body.init(0x1A);
    t0.b(0x04, 1);
    t0.b(0x05, 2);
    t0.w(0x06, 0xF000);
    t0.b(0x08, 3);
    t0.b(0x09, 0xFF);
    t0.q(0x0A, 0x0000_0000_0000_0080);
    t0.b(0x14, 5);
    t0.b(0x15, 17);
    t0.b(0x16, 0xFF);
    t0.b(0x17, 0xFF);
    t0.w(0x18, 0x0020); // 32 MiB
    try bld.add(0, 0x0000, &t0, &.{ "FakeBIOS Inc.", "F.10", "01/02/2024" });

    var t1 = Body.init(0x1B);
    t1.b(0x04, 1);
    t1.b(0x05, 2);
    t1.b(0x06, 3);
    t1.b(0x07, 4);
    t1.bytes(0x08, &test_uuid);
    t1.b(0x18, 0x06);
    t1.b(0x19, 5);
    t1.b(0x1A, 6);
    try bld.add(1, 0x0001, &t1, &.{ "FakeVendor", "To Be Filled By O.E.M.", "1.0", "FAKE-SERIAL-0001", "Default string", "   " });

    var t2 = Body.init(0x0F);
    t2.b(0x04, 1);
    t2.b(0x05, 2);
    t2.b(0x06, 3);
    t2.b(0x07, 4);
    t2.b(0x08, 5);
    t2.b(0x09, 0x09);
    t2.b(0x0A, 6);
    t2.w(0x0B, 0x0003);
    t2.b(0x0D, 0x0A);
    try bld.add(2, 0x0002, &t2, &.{ "FakeBoards", "X999 FAKE", "1.02", "FAKE-BOARD-SN-02", "FAKE-ASSET-02", "Default string" });

    var t3 = Body.init(0x15);
    t3.b(0x04, 1);
    t3.b(0x05, 0x83); // zamek + Desktop
    t3.b(0x06, 2);
    t3.b(0x07, 3);
    t3.b(0x08, 4);
    try bld.add(3, 0x0003, &t3, &.{ "FakeCases", "Not Specified", "FAKE-CHASSIS-03", "FAKE-ASSET-03" });

    var t4 = Body.init(0x32);
    t4.b(0x04, 1);
    t4.b(0x05, 0x03);
    t4.b(0x06, 0x6B);
    t4.b(0x07, 2);
    t4.q(0x08, 0x178BFBFF_00A60F12);
    t4.b(0x10, 3);
    t4.w(0x12, 100);
    t4.w(0x14, 5750);
    t4.w(0x16, 4500);
    t4.b(0x18, 0x41);
    t4.b(0x19, 0x49);
    t4.w(0x1A, 0x0007);
    t4.w(0x1C, 0x0008);
    t4.w(0x1E, 0x0009);
    t4.b(0x20, 4);
    t4.b(0x21, 5);
    t4.b(0x22, 6);
    t4.b(0x23, 16);
    t4.b(0x24, 16);
    t4.b(0x25, 32);
    t4.w(0x26, 0x00FC);
    t4.w(0x28, 0x006B);
    t4.w(0x2A, 16);
    t4.w(0x2C, 16);
    t4.w(0x2E, 32);
    t4.w(0x30, 32);
    try bld.add(4, 0x0004, &t4, &.{ "AM5", "Advanced Micro Devices, Inc.", "FAKE Ryzen 9 0000X 16-Core Processor  ", "FAKE-CPU-SN-04", "Unknown", "Unknown" });

    var t7 = Body.init(0x1B);
    t7.b(0x04, 1);
    t7.w(0x05, 0x0182); // L3, enabled, internal, write-back
    t7.w(0x07, 0xFFFF);
    t7.w(0x09, 0xFFFF);
    t7.w(0x0B, 0x0002);
    t7.w(0x0D, 0x0002);
    t7.b(0x0F, 1);
    t7.b(0x10, 0x06);
    t7.b(0x11, 0x05);
    t7.b(0x12, 0x08);
    t7.d(0x13, 0x8000_0000 | 1024); // 1024 * 64 KiB = 64 MiB
    t7.d(0x17, 0x0001_0000); // 65536 KiB = 64 MiB
    try bld.add(7, 0x0009, &t7, &.{"L3 - Cache"});

    var t16 = Body.init(0x17);
    t16.b(0x04, 0x03);
    t16.b(0x05, 0x03);
    t16.b(0x06, 0x03);
    t16.d(0x07, 0x8000_0000);
    t16.w(0x0B, 0xFFFE);
    t16.w(0x0D, 4);
    t16.q(0x0F, 256 * 1024 * 1024 * 1024);
    try bld.add(16, 0x0010, &t16, &.{});

    try addDimm(bld, .{ .handle = 0x0011, .size = 0x4000, .type = 0x22, .speed = 4800, .cfg_speed = 6000, .device = "DIMM 0", .bank = "P0 CHANNEL A", .part = "FAKE-PART-DDR5    ", .serial = "FAKE-SERIAL-0011" });
    try addDimm(bld, .{ .handle = 0x0012, .size = 0x4000, .type = 0x22, .speed = 4800, .cfg_speed = 6000, .device = "DIMM 0", .bank = "P0 CHANNEL B", .part = "FAKE-PART-DDR5    ", .serial = "FAKE-SERIAL-0012" });
    try addDimm(bld, .{ .handle = 0x0013, .size = 0, .type = 0x02, .speed = 0, .cfg_speed = 0, .device = "DIMM 1", .bank = "P0 CHANNEL A", .part = "Unknown", .serial = "Unknown" });
    try bld.endOfTable();
}

const DimmOpts = struct {
    handle: u16,
    len: usize = 0x5C,
    array: u16 = 0x0010,
    size: u16,
    ext_size: u32 = 0,
    type: u8,
    form: u8 = 0x09,
    detail: u16 = 0x4080, // Synchronous + Unbuffered
    speed: u16,
    ext_speed: u32 = 0,
    cfg_speed: u16,
    ext_cfg_speed: u32 = 0,
    device: []const u8,
    bank: []const u8,
    part: []const u8,
    serial: []const u8,
    rank: u8 = 2,
    voltage: u16 = 1100,
};

fn addDimm(bld: *Builder, o: DimmOpts) !void {
    var t = Body.init(o.len);
    t.w(0x04, o.array);
    t.w(0x06, 0xFFFE);
    t.w(0x08, if (o.size == 0) 0xFFFF else 64);
    t.w(0x0A, if (o.size == 0) 0xFFFF else 64);
    t.w(0x0C, o.size);
    t.b(0x0E, o.form);
    t.b(0x10, 1);
    t.b(0x11, 2);
    t.b(0x12, o.type);
    t.w(0x13, o.detail);
    if (o.len >= 0x1B) {
        t.w(0x15, o.speed);
        t.b(0x17, 3);
        t.b(0x18, 4);
        t.b(0x19, 5);
        t.b(0x1A, 6);
    }
    if (o.len >= 0x1C) t.b(0x1B, o.rank);
    if (o.len >= 0x22) {
        t.d(0x1C, o.ext_size);
        t.w(0x20, o.cfg_speed);
    }
    if (o.len >= 0x28) {
        t.w(0x22, o.voltage);
        t.w(0x24, o.voltage);
        t.w(0x26, o.voltage);
    }
    if (o.len >= 0x29) t.b(0x28, 0x03);
    if (o.len >= 0x5C) {
        t.d(0x54, o.ext_speed);
        t.d(0x58, o.ext_cfg_speed);
    }
    const strings = [_][]const u8{ o.device, o.bank, "FakeRAM", o.serial, "FAKE-ASSET-17", o.part };
    try bld.add(17, o.handle, &t, &strings);
}

fn desktopRaw(alloc: std.mem.Allocator, major: u8, minor: u8) ![]u8 {
    var bld: Builder = .{ .alloc = alloc };
    defer bld.deinit();
    try buildDesktop(&bld);
    return bld.raw(major, minor);
}

test "smbios: nagłówek RawSMBIOSData i iteracja" {
    const buf = try desktopRaw(testing.allocator, 3, 4);
    defer testing.allocator.free(buf);

    const t = try fromRawSmbiosData(buf);
    try testing.expectEqual(@as(u8, 3), t.major);
    try testing.expectEqual(@as(u8, 4), t.minor);
    try testing.expect(!t.truncated);
    try testing.expectEqual(buf.len - 8, t.data.len);

    const expected = [_]u8{ 0, 1, 2, 3, 4, 7, 16, 17, 17, 17, 127 };
    var it = t.iterator();
    var n: usize = 0;
    while (it.next()) |s| : (n += 1) {
        try testing.expectEqual(expected[n], s.type_id);
        try testing.expectEqual(s.formatted.len, @as(usize, s.formatted[1]));
    }
    try testing.expectEqual(expected.len, n);
    try testing.expect(!it.malformed);
    try testing.expect(it.next() == null);

    try testing.expectError(error.TooShort, fromRawSmbiosData(buf[0..7]));
    // Length większe niż bufor: przycięcie, wynik częściowy.
    const part = try fromRawSmbiosData(buf[0..40]);
    try testing.expect(part.truncated);
    try testing.expectEqual(@as(usize, 32), part.data.len);

    const bare = fromTableData(3, 4, buf[8..]);
    try testing.expectEqual(@as(u8, 1), bare.find(1).?.type_id);
    try testing.expect(bare.find(42) == null);
}

test "smbios: wyszukiwanie napisów (indeks 0, poza zakresem)" {
    const buf = try desktopRaw(testing.allocator, 3, 4);
    defer testing.allocator.free(buf);
    const t = try fromRawSmbiosData(buf);
    const s = t.find(0).?;
    try testing.expect(s.string(0) == null);
    try testing.expectEqualStrings("FakeBIOS Inc.", s.string(1).?);
    try testing.expectEqualStrings("F.10", s.string(2).?);
    try testing.expectEqualStrings("01/02/2024", s.string(3).?);
    try testing.expect(s.string(4) == null);
    try testing.expect(s.string(255) == null);
    const span = s.stringSpan(2).?;
    try testing.expectEqual(@as(usize, 14), span.start);
    try testing.expectEqual(@as(usize, 4), span.len);
    // Struktura bez napisów.
    const a = t.find(16).?;
    try testing.expectEqual(@as(usize, 0), a.strings.len);
    try testing.expect(a.string(1) == null);
}

test "smbios: typ 0 BIOS" {
    const buf = try desktopRaw(testing.allocator, 3, 4);
    defer testing.allocator.free(buf);
    const t = try fromRawSmbiosData(buf);
    const bios = decodeBios(t.find(0).?).?;
    try testing.expectEqualStrings("FakeBIOS Inc.", bios.vendor.?.value.?);
    try testing.expectEqualStrings("F.10", bios.version.?.text().?);
    try testing.expectEqualStrings("01/02/2024", bios.release_date.?.value.?);
    try testing.expectEqual(@as(?u16, 0xF000), bios.starting_segment);
    const rom = bios.rom_size.?;
    try testing.expect(rom.from_extended);
    try testing.expectEqual(@as(?u64, 32 * 1024 * 1024), rom.bytes);
    try testing.expectEqualStrings("SMBIOS 3.x §7.1 type 0, offset 18h", rom.spec);
    try testing.expectEqualStrings("SMBIOS 3.x §7.1 type 0, offset 05h", bios.version.?.spec);
    try testing.expectEqual(@as(u8, 5), bios.bios_release.?.major);
    try testing.expectEqual(@as(u8, 17), bios.bios_release.?.minor);
    try testing.expect(bios.bios_release.?.supported);
    try testing.expect(!bios.ec_release.?.supported);
    try testing.expect(decodeBios(t.find(1).?) == null);

    // Stary BIOS (2.0): rozmiar z bajtu 09h, brak pól 2.4+.
    var bld: Builder = .{ .alloc = testing.allocator };
    defer bld.deinit();
    var t0 = Body.init(0x12);
    t0.b(0x04, 1);
    t0.b(0x09, 0x7F); // (7Fh + 1) * 64 KiB = 8 MiB
    try bld.add(0, 0, &t0, &.{"Old"});
    try bld.endOfTable();
    const old = decodeBios(fromTableData(2, 0, bld.out.items).find(0).?).?;
    try testing.expectEqual(@as(?u64, 8 * 1024 * 1024), old.rom_size.?.bytes);
    try testing.expect(!old.rom_size.?.from_extended);
    try testing.expect(old.bios_release == null);
    try testing.expect(old.version.?.raw == null);
    try testing.expect(old.version.?.index == 0);
}

test "smbios: typ 1 System, wypełniacze i UUID" {
    const buf = try desktopRaw(testing.allocator, 3, 4);
    defer testing.allocator.free(buf);
    const t = try fromRawSmbiosData(buf);
    const sys = decodeSystem(t.find(1).?).?;
    try testing.expectEqualStrings("FakeVendor", sys.manufacturer.?.text().?);
    try testing.expect(sys.product.?.placeholder);
    try testing.expectEqualStrings("To Be Filled By O.E.M.", sys.product.?.value.?);
    try testing.expect(sys.product.?.text() == null);
    try testing.expect(sys.serial.?.sensitive);
    try testing.expect(!sys.manufacturer.?.sensitive);
    try testing.expectEqualStrings("FAKE-SERIAL-0001", sys.serial.?.value.?);
    try testing.expect(sys.sku.?.placeholder);
    try testing.expect(sys.family.?.placeholder);
    try testing.expectEqualStrings("   ", sys.family.?.raw.?);
    try testing.expectEqualStrings("", sys.family.?.value.?);
    try testing.expectEqualStrings("Power Switch", sys.wake_up.?.name.?);

    const uuid = sys.uuid.?;
    try testing.expect(uuid.sensitive);
    try testing.expectEqual(UuidState.present, uuid.state);
    try testing.expect(uuid.little_endian_fields);
    var ubuf: [36]u8 = undefined;
    try testing.expectEqualStrings("33221100-5544-7766-8899-AABBCCDDEEFF", uuid.format(&ubuf));

    // SMBIOS < 2.6: kolejność bajtów bez zamiany.
    const t24 = fromTableData(2, 4, t.data);
    const sys24 = decodeSystem(t24.find(1).?).?;
    try testing.expectEqualStrings("00112233-4455-6677-8899-AABBCCDDEEFF", sys24.uuid.?.format(&ubuf));

    var ff: [16]u8 = undefined;
    @memset(&ff, 0xFF);
    try testing.expectEqualStrings("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", formatUuid(ff, true, &ubuf));
}

test "smbios: placeholder" {
    try testing.expect(isPlaceholder(""));
    try testing.expect(isPlaceholder("default STRING"));
    try testing.expect(isPlaceholder("0000000000"));
    try testing.expect(isPlaceholder("Not Specified"));
    try testing.expect(!isPlaceholder("ASUSTeK COMPUTER INC."));
    try testing.expect(!isPlaceholder("XXXX"));
}

test "smbios: typ 2 Baseboard i typ 3 Chassis" {
    const buf = try desktopRaw(testing.allocator, 3, 4);
    defer testing.allocator.free(buf);
    const t = try fromRawSmbiosData(buf);
    const bb = decodeBaseboard(t.find(2).?).?;
    try testing.expectEqualStrings("FakeBoards", bb.manufacturer.?.text().?);
    try testing.expectEqualStrings("X999 FAKE", bb.product.?.text().?);
    try testing.expectEqualStrings("1.02", bb.version.?.text().?);
    try testing.expect(bb.serial.?.sensitive);
    try testing.expect(bb.asset_tag.?.sensitive);
    try testing.expect(bb.location_in_chassis.?.placeholder);
    try testing.expectEqualStrings("Motherboard", bb.board_type.?.name.?);
    try testing.expectEqual(@as(?u16, 3), bb.chassis_handle);

    const ch = decodeChassis(t.find(3).?).?;
    try testing.expectEqualStrings("FakeCases", ch.manufacturer.?.text().?);
    try testing.expectEqual(@as(u8, 0x83), ch.chassis_type.?.raw);
    try testing.expectEqualStrings("Desktop", ch.chassis_type.?.name.?);
    try testing.expect(ch.lock_present.?);
    try testing.expect(ch.version.?.placeholder);
    try testing.expectEqualStrings("FAKE-CHASSIS-03", ch.serial.?.value.?);
    try testing.expect(ch.serial.?.sensitive);
}

test "smbios: typ 4 Processor (AM5, liczniki rozszerzone)" {
    const buf = try desktopRaw(testing.allocator, 3, 4);
    defer testing.allocator.free(buf);
    const t = try fromRawSmbiosData(buf);
    const p = decodeProcessor(t.find(4).?).?;
    try testing.expectEqualStrings("AM5", p.socket_designation.?.text().?);
    try testing.expectEqualStrings("Advanced Micro Devices, Inc.", p.manufacturer.?.text().?);
    try testing.expectEqualStrings("FAKE Ryzen 9 0000X 16-Core Processor", p.version.?.value.?);
    try testing.expectEqualStrings("Socket AM5", p.upgrade.?.name.?);
    try testing.expectEqualStrings("Central Processor", p.processor_type.?.name.?);
    try testing.expectEqual(@as(?u16, 5750), p.max_speed_mhz.?.value);
    try testing.expectEqual(@as(?u16, 4500), p.current_speed_mhz.?.value);
    try testing.expectEqual(@as(?u16, 100), p.external_clock_mhz.?.value);
    try testing.expectEqual(@as(?u16, 16), p.core_count.?.value);
    try testing.expect(!p.core_count.?.from_extended);
    try testing.expectEqual(@as(?u16, 32), p.thread_count.?.value);
    try testing.expectEqual(@as(?u16, 32), p.thread_enabled.?.value);
    try testing.expect(p.socket_populated.?);
    try testing.expectEqualStrings("CPU Enabled", p.cpu_status.?.name.?);
    try testing.expect(p.serial.?.sensitive);
    try testing.expect(p.asset_tag.?.placeholder);
    try testing.expectEqual(@as(?u16, 0x0009), p.l3_cache_handle);

    try testing.expectEqualStrings("Socket LGA1700", processorUpgradeName(0x40).?);
    try testing.expectEqualStrings("Socket AM4", processorUpgradeName(0x31).?);
    try testing.expectEqualStrings("Socket LGA1200", processorUpgradeName(0x3E).?);
    try testing.expect(processorUpgradeName(0xF0) == null);

    // Serwer: Core Count = FFh -> Core Count 2 = 288; SMBIOS 2.5 bez pól 3.0.
    var bld: Builder = .{ .alloc = testing.allocator };
    defer bld.deinit();
    var big = Body.init(0x30);
    big.b(0x19, 0x4A);
    big.b(0x23, 0xFF);
    big.b(0x24, 0xFF);
    big.b(0x25, 0xFF);
    big.w(0x2A, 288);
    big.w(0x2C, 0);
    big.w(0x2E, 576);
    try bld.add(4, 0x40, &big, &.{});
    var old = Body.init(0x26);
    old.b(0x23, 4);
    old.b(0x24, 0);
    old.b(0x25, 0xFF);
    try bld.add(4, 0x41, &old, &.{});
    try bld.endOfTable();
    var it = fromTableData(3, 0, bld.out.items).iterator();
    const pb = decodeProcessor(it.next().?).?;
    try testing.expectEqual(@as(?u16, 288), pb.core_count.?.value);
    try testing.expect(pb.core_count.?.from_extended);
    try testing.expectEqualStrings("SMBIOS 3.x §7.5 type 4, offset 2Ah", pb.core_count.?.spec);
    try testing.expectEqual(@as(?u16, 0xFF), pb.core_enabled.?.value);
    try testing.expectEqual(@as(?u16, 576), pb.thread_count.?.value);
    try testing.expect(pb.thread_enabled == null);
    try testing.expectEqualStrings("Socket SP5", pb.upgrade.?.name.?);
    try testing.expect(pb.socket_designation.?.raw == null);
    const po = decodeProcessor(it.next().?).?;
    try testing.expectEqual(@as(?u16, 4), po.core_count.?.value);
    try testing.expect(po.core_enabled.?.value == null);
    try testing.expectEqual(@as(?u16, 255), po.thread_count.?.value);
    try testing.expect(po.family2 == null);
}

test "smbios: typ 7 Cache" {
    const buf = try desktopRaw(testing.allocator, 3, 4);
    defer testing.allocator.free(buf);
    const t = try fromRawSmbiosData(buf);
    const c = decodeCache(t.find(7).?).?;
    try testing.expectEqualStrings("L3 - Cache", c.socket_designation.?.text().?);
    try testing.expectEqual(@as(?u8, 3), c.level);
    try testing.expect(c.enabled.?);
    try testing.expect(!c.socketed.?);
    try testing.expectEqual(@as(?u2, 0), c.location);
    try testing.expectEqual(@as(?u2, 1), c.operational_mode);
    try testing.expectEqual(@as(?u64, 64 * 1024 * 1024), c.max_size.?.bytes);
    try testing.expect(c.max_size.?.from_extended);
    try testing.expectEqual(@as(?u64, 64 * 1024 * 1024), c.installed_size.?.bytes);
    try testing.expectEqualStrings("Multi-bit ECC", c.error_correction.?.name.?);
    try testing.expectEqualStrings("Unified", c.system_cache_type.?.name.?);
    try testing.expectEqualStrings("16-way Set-Associative", c.associativity.?.name.?);
}

test "smbios: typ 16 Physical Memory Array" {
    const buf = try desktopRaw(testing.allocator, 3, 4);
    defer testing.allocator.free(buf);
    const t = try fromRawSmbiosData(buf);
    const a = decodeMemoryArray(t.find(16).?).?;
    try testing.expectEqualStrings("System board or motherboard", a.location.?.name.?);
    try testing.expectEqualStrings("System memory", a.use.?.name.?);
    try testing.expectEqualStrings("None", a.error_correction.?.name.?);
    try testing.expect(a.max_capacity.?.from_extended);
    try testing.expectEqual(@as(?u64, 256 * 1024 * 1024 * 1024), a.max_capacity.?.bytes);
    try testing.expectEqual(@as(?u16, 4), a.num_devices.?.value);

    // 2.3: pojemność w KiB z DWORD 07h.
    var bld: Builder = .{ .alloc = testing.allocator };
    defer bld.deinit();
    var b16 = Body.init(0x0F);
    b16.b(0x04, 0x03);
    b16.b(0x05, 0x03);
    b16.b(0x06, 0x05);
    b16.d(0x07, 32 * 1024 * 1024); // 32 GiB w KiB
    b16.w(0x0D, 2);
    try bld.add(16, 0x20, &b16, &.{});
    const a2 = decodeMemoryArray(fromTableData(2, 3, bld.out.items).find(16).?).?;
    try testing.expectEqual(@as(?u64, 32 * 1024 * 1024 * 1024), a2.max_capacity.?.bytes);
    try testing.expect(!a2.max_capacity.?.from_extended);
    try testing.expectEqualStrings("Single-bit ECC", a2.error_correction.?.name.?);
}

test "smbios: typ 17 DDR5 obsadzony i puste gniazdo" {
    const buf = try desktopRaw(testing.allocator, 3, 4);
    defer testing.allocator.free(buf);
    const t = try fromRawSmbiosData(buf);
    var it = t.iterator();
    var devs: [3]MemoryDevice = undefined;
    var n: usize = 0;
    while (it.next()) |s| {
        if (decodeMemoryDevice(s)) |dev| {
            devs[n] = dev;
            n += 1;
        }
    }
    try testing.expectEqual(@as(usize, 3), n);
    const m = devs[0];
    try testing.expect(m.populated());
    try testing.expectEqual(SizeState.installed, m.size.?.state);
    try testing.expectEqual(@as(?u64, 16 * 1024 * 1024 * 1024), m.size.?.bytes);
    try testing.expectEqualStrings("DDR5", m.memory_type.?.name.?);
    try testing.expectEqualStrings("DIMM", m.form_factor.?.name.?);
    try testing.expectEqual(@as(?u32, 4800), m.speed.?.mts);
    try testing.expectEqual(@as(?u32, 6000), m.configured_speed.?.mts);
    try testing.expectEqualStrings("FAKE-PART-DDR5", m.part_number.?.value.?);
    try testing.expectEqualStrings("FAKE-PART-DDR5    ", m.part_number.?.raw.?);
    try testing.expect(m.serial.?.sensitive);
    try testing.expectEqual(@as(?u8, 2), m.rank.?.value);
    try testing.expectEqual(@as(?u16, 1100), m.configured_voltage_mv.?.value);
    try testing.expectEqual(@as(?u16, 64), m.data_width_bits.?.value);
    try testing.expectEqualStrings("DRAM", m.technology.?.name.?);
    try testing.expectEqualStrings("P0 CHANNEL A", m.bank_locator.?.text().?);
    var names_buf: [16][]const u8 = undefined;
    const names = m.type_detail.?.names(&names_buf);
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("Synchronous", names[0]);
    try testing.expectEqualStrings("Unbuffered (Unregistered)", names[1]);

    const e = devs[2];
    try testing.expect(!e.populated());
    try testing.expectEqual(SizeState.empty, e.size.?.state);
    try testing.expect(e.speed.?.mts == null);
    try testing.expect(e.manufacturer.?.text() != null);
    try testing.expect(e.part_number.?.placeholder);
    try testing.expect(e.data_width_bits.?.value == null);
}

test "smbios: typ 17 DDR4, rozmiar rozszerzony, nieznany, KiB, prędkość rozszerzona" {
    var bld: Builder = .{ .alloc = testing.allocator };
    defer bld.deinit();
    // DDR4 w strukturze SMBIOS 2.8 (długość 28h).
    try addDimm(&bld, .{ .handle = 0x30, .len = 0x28, .size = 0x2000, .type = 0x1A, .speed = 3200, .cfg_speed = 2933, .device = "DIMM_A1", .bank = "BANK 0", .part = "FAKE-DDR4-PART", .serial = "FAKE-SERIAL-0030", .voltage = 1200 });
    // 64 GiB: Size = 7FFFh, Extended Size = 65536 MiB.
    try addDimm(&bld, .{ .handle = 0x31, .size = 0x7FFF, .ext_size = 65536, .type = 0x22, .speed = 0xFFFF, .ext_speed = 8000, .cfg_speed = 0xFFFF, .ext_cfg_speed = 7200, .device = "DIMM_B1", .bank = "BANK 1", .part = "FAKE-DDR5-64G", .serial = "FAKE-SERIAL-0031" });
    // Rozmiar nieznany.
    try addDimm(&bld, .{ .handle = 0x32, .size = 0xFFFF, .type = 0x02, .speed = 0, .cfg_speed = 0, .device = "DIMM_A2", .bank = "BANK 2", .part = "Unknown", .serial = "Unknown" });
    // 512 KiB (bit 15 = KiB) w starej strukturze 2.3 (długość 1Bh).
    try addDimm(&bld, .{ .handle = 0x33, .len = 0x1B, .size = 0x8000 | 512, .type = 0x0F, .speed = 133, .cfg_speed = 0, .device = "Onboard", .bank = "Bank", .part = "FAKE", .serial = "FAKE-SERIAL-0033" });
    try bld.endOfTable();
    const t = fromTableData(3, 3, bld.out.items);
    var it = t.iterator();

    const d4 = decodeMemoryDevice(it.next().?).?;
    try testing.expectEqualStrings("DDR4", d4.memory_type.?.name.?);
    try testing.expectEqual(@as(?u64, 8 * 1024 * 1024 * 1024), d4.size.?.bytes);
    try testing.expectEqual(@as(?u32, 3200), d4.speed.?.mts);
    try testing.expectEqual(@as(?u32, 2933), d4.configured_speed.?.mts);
    try testing.expectEqual(@as(?u16, 1200), d4.configured_voltage_mv.?.value);
    try testing.expect(d4.technology == null);
    try testing.expect(d4.speed.?.raw_extended == null);

    const big = decodeMemoryDevice(it.next().?).?;
    try testing.expect(big.size.?.from_extended);
    try testing.expectEqual(@as(?u64, 64 * 1024 * 1024 * 1024), big.size.?.bytes);
    try testing.expectEqualStrings("SMBIOS 3.x §7.18 type 17, offset 1Ch", big.size.?.spec);
    try testing.expectEqual(@as(?u32, 8000), big.speed.?.mts);
    try testing.expect(big.speed.?.from_extended);
    try testing.expectEqual(@as(?u32, 7200), big.configured_speed.?.mts);

    const unk = decodeMemoryDevice(it.next().?).?;
    try testing.expectEqual(SizeState.unknown, unk.size.?.state);
    try testing.expect(unk.size.?.bytes == null);
    try testing.expect(unk.populated());

    const kb = decodeMemoryDevice(it.next().?).?;
    try testing.expectEqual(@as(?u64, 512 * 1024), kb.size.?.bytes);
    try testing.expectEqualStrings("SDRAM", kb.memory_type.?.name.?);
    try testing.expect(kb.rank == null);
    try testing.expect(kb.configured_speed == null);

    try testing.expectEqualStrings("LPDDR4", memoryTypeName(0x1E).?);
    try testing.expectEqualStrings("LPDDR5", memoryTypeName(0x23).?);
    try testing.expectEqualStrings("DDR3", memoryTypeName(0x18).?);
    try testing.expectEqualStrings("DDR2", memoryTypeName(0x13).?);
    try testing.expectEqualStrings("DDR", memoryTypeName(0x12).?);
    try testing.expect(memoryTypeName(0x15) == null);

    const sum = summarizeMemory(t);
    try testing.expectEqual(@as(u16, 4), sum.total_slots);
    try testing.expectEqual(@as(u16, 4), sum.populated_slots);
    try testing.expectEqual(@as(u16, 1), sum.unknown_size_modules);
    try testing.expect(sum.mixed_types);
    try testing.expect(sum.declared_slots == null);
    // "Onboard" nie pasuje do wzorców -> pewność obniżona do low.
    try testing.expectEqual(@as(?u8, 2), sum.channels);
    try testing.expectEqual(Confidence.low, sum.channel_confidence);
}

test "smbios: podsumowanie pamięci i heurystyka kanałów" {
    const buf = try desktopRaw(testing.allocator, 3, 4);
    defer testing.allocator.free(buf);
    const t = try fromRawSmbiosData(buf);
    const sum = summarizeMemory(t);
    try testing.expectEqual(@as(u64, 32 * 1024 * 1024 * 1024), sum.total_bytes);
    try testing.expectEqual(@as(u16, 2), sum.populated_slots);
    try testing.expectEqual(@as(u16, 3), sum.total_slots);
    try testing.expectEqual(@as(?u32, 4), sum.declared_slots);
    try testing.expectEqual(@as(?u8, 0x22), sum.memory_type);
    try testing.expect(!sum.mixed_types);
    try testing.expectEqual(@as(?u8, 2), sum.channels);
    try testing.expectEqual(Confidence.medium, sum.channel_confidence);

    const g1 = guessChannel("Controller1-ChannelA-DIMM0", "BANK 0").?;
    const g0 = guessChannel("Controller0-ChannelA-DIMM0", "BANK 0").?;
    try testing.expect(g1.key != g0.key);
    try testing.expectEqual(Confidence.medium, g0.confidence);
    const g2 = guessChannel("CPU0_DIMM_B2", null).?;
    try testing.expectEqual(Confidence.low, g2.confidence);
    try testing.expectEqual(@as(u16, 'B'), g2.key & 0xFF);
    try testing.expectEqual(@as(u16, 'A'), guessChannel("DIMMA1", null).?.key & 0xFF);
    try testing.expect(guessChannel("DIMM 0", "BANK 0") == null);
    try testing.expect(guessChannel(null, null) == null);
}

test "smbios: uszkodzone dane nie powodują awarii" {
    // Długość < 4.
    {
        const data = [_]u8{ 0, 2, 0, 0, 0, 0 };
        var it = fromTableData(3, 0, &data).iterator();
        try testing.expect(it.next() == null);
        try testing.expect(it.malformed);
    }
    // Długość wychodzi poza bufor.
    {
        const data = [_]u8{ 1, 0x40, 0, 0, 1, 2, 3 };
        var it = fromTableData(3, 0, &data).iterator();
        try testing.expect(it.next() == null);
        try testing.expect(it.malformed);
    }
    // Brak podwójnego NUL: struktura zwrócona, napisy częściowe, koniec.
    {
        const data = [_]u8{ 0, 5, 0, 0, 1, 'a', 'b', 0, 'c' };
        var it = fromTableData(3, 0, &data).iterator();
        const s = it.next().?;
        try testing.expectEqualStrings("ab", s.string(1).?);
        try testing.expectEqualStrings("c", s.string(2).?);
        try testing.expect(s.string(3) == null);
        try testing.expect(it.next() == null);
        try testing.expect(it.malformed);
        const bios = decodeBios(s).?;
        try testing.expect(bios.version == null);
        try testing.expect(bios.rom_size == null);
    }
    // Pusty bufor i ogon krótszy niż nagłówek.
    {
        var it = fromTableData(3, 0, &.{}).iterator();
        try testing.expect(it.next() == null);
        try testing.expect(!it.malformed);
        const data = [_]u8{ 127, 4, 0, 0, 0, 0, 1, 2 };
        var it2 = fromTableData(3, 0, &data).iterator();
        try testing.expectEqual(@as(u8, 127), it2.next().?.type_id);
        try testing.expect(it2.next() == null);
    }

    // Każdy prefiks poprawnej tablicy i losowe śmieci: brak awarii, skończona iteracja.
    const buf = try desktopRaw(testing.allocator, 3, 4);
    defer testing.allocator.free(buf);
    for (0..buf.len + 1) |cut| {
        const t = fromRawSmbiosData(buf[0..cut]) catch continue;
        var it = t.iterator();
        var guard: usize = 0;
        while (it.next()) |s| : (guard += 1) {
            try testing.expect(guard <= t.data.len);
            _ = decodeBios(s);
            _ = decodeSystem(s);
            _ = decodeBaseboard(s);
            _ = decodeChassis(s);
            _ = decodeProcessor(s);
            _ = decodeCache(s);
            _ = decodeMemoryArray(s);
            _ = decodeMemoryDevice(s);
            for (0..256) |i| _ = s.string(@intCast(i));
        }
        _ = summarizeMemory(t);
    }
    var prng = std.Random.DefaultPrng.init(0x5EED);
    const rnd = prng.random();
    var junk: [512]u8 = undefined;
    for (0..200) |_| {
        rnd.bytes(&junk);
        const len = rnd.uintLessThan(usize, junk.len);
        // Wymuszamy często poprawne długości, żeby wejść głębiej w parser.
        if (len > 2) junk[1] = rnd.intRangeAtMost(u8, 4, 0x60);
        const t = fromTableData(3, 4, junk[0..len]);
        var it = t.iterator();
        var guard: usize = 0;
        while (it.next()) |s| : (guard += 1) {
            try testing.expect(guard <= len);
            _ = decodeMemoryDevice(s);
            _ = decodeProcessor(s);
            _ = decodeSystem(s);
        }
        _ = summarizeMemory(t);
        _ = maskTableData(junk[0..len]);
    }
}

test "smbios: maskowanie danych wrażliwych" {
    const buf = try desktopRaw(testing.allocator, 3, 4);
    defer testing.allocator.free(buf);
    const orig = try testing.allocator.dupe(u8, buf);
    defer testing.allocator.free(orig);

    const res = try maskSerials(buf);
    // typ 1: serial; 2: serial+asset; 3: serial+asset; 4: serial+asset; 17 x3: serial+asset.
    try testing.expectEqual(@as(usize, 1 + 2 + 2 + 2 + 6), res.strings_masked);
    try testing.expectEqual(@as(usize, 1), res.uuids_zeroed);
    try testing.expectEqual(orig.len, buf.len);
    try testing.expect(std.mem.indexOf(u8, buf, "FAKE-SERIAL") == null);
    try testing.expect(std.mem.indexOf(u8, buf, "FAKE-ASSET") == null);

    const t0 = try fromRawSmbiosData(orig);
    const t1 = try fromRawSmbiosData(buf);
    var a = t0.iterator();
    var b = t1.iterator();
    while (a.next()) |sa| {
        const sb = b.next().?;
        try testing.expectEqual(sa.offset, sb.offset);
        try testing.expectEqual(sa.strings_offset, sb.strings_offset);
        try testing.expectEqual(sa.strings.len, sb.strings.len);
        try testing.expectEqual(sa.type_id, sb.type_id);
    }
    try testing.expect(b.next() == null);

    const sys = decodeSystem(t1.find(1).?).?;
    try testing.expectEqualStrings("XXXXXXXXXXXXXXXX", sys.serial.?.value.?);
    try testing.expectEqual(UuidState.not_present, sys.uuid.?.state);
    try testing.expectEqualStrings("FakeVendor", sys.manufacturer.?.value.?);
    const bb = decodeBaseboard(t1.find(2).?).?;
    try testing.expectEqualStrings("XXXXXXXXXXXXXXXX", bb.serial.?.value.?);
    try testing.expectEqualStrings("XXXXXXXXXXXXX", bb.asset_tag.?.value.?);
    try testing.expectEqualStrings("X999 FAKE", bb.product.?.value.?);
    const p = decodeProcessor(t1.find(4).?).?;
    try testing.expectEqualStrings("XXXXXXXXXXXXXX", p.serial.?.value.?);
    try testing.expectEqualStrings("FAKE-PART-DDR5", decodeMemoryDevice(t1.find(17).?).?.part_number.?.value.?);

    const s0 = summarizeMemory(t0);
    const s1 = summarizeMemory(t1);
    try testing.expectEqual(s0.total_bytes, s1.total_bytes);
    try testing.expectEqual(s0.channels, s1.channels);

    // Idempotencja.
    const res2 = try maskSerials(buf);
    try testing.expectEqual(res.strings_masked, res2.strings_masked);
    try testing.expectError(error.TooShort, maskSerials(buf[0..4]));
}
