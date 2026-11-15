//! Mapa gniazd pamięci (DIMM) — moduł czysty, bez Win32 i bez tłumaczeń.
//!
//! Wejście: **wszystkie** struktury SMBIOS typ 17 (także puste gniazda),
//! w kolejności z tablicy (to jest kolejność fizyczna, którą raportuje
//! firmware; sekcje „Gniazdo {slot}” strony Pamięć mają tę samą kolejność,
//! więc indeks gniazda = indeks listy rozwijanej w GUI).
//!
//! Wyjście: gniazda numerowane 1..N z lokatorem, bankiem, **krótką etykietą**
//! („A1”, „A2”, „B1”, „B2”, gdy da się wywnioskować kanał; inaczej lokator),
//! kluczem kanału (z `smbios.guessChannel`) i pewnością, stanem obsadzenia
//! oraz rozmiarem/typem/producentem. Do tego podpowiedź trybu pracy kanałów
//! (`Hint`) — zawsze z pewnością; gdy nazw nie da się zinterpretować,
//! podpowiedź mówi „nie wiadomo” zamiast zgadywać.
//!
//! Etykieta „<kanał><pozycja>”:
//!   * lokator w stylu „DIMM_A1” / „DIMMA2” / „CPU0_DIMM_B2” / „A1” — litera
//!     i cyfra wprost z nazwy (nadruk na płycie),
//!   * inaczej (np. „DIMM 1” + bank „P0 CHANNEL A”, „ChannelA-DIMM0”) —
//!     pozycja = kolejność gniazda w obrębie kanału (1, 2, …) w kolejności
//!     struktur. To HEURYSTYKA: pewność etykiety = pewność kanału.
//! Gdy kanały należą do kilku grup (kontrolery / gniazda CPU), etykieta
//! dostaje przedrostek grupy, np. „P1-A1”.

const std = @import("std");
const vendors = @import("../gui/vendors.zig");
const smbios = @import("smbios.zig");

pub const Confidence = smbios.Confidence;

pub const Slot = struct {
    /// Numer 1..N w kolejności struktur typ 17.
    index: u16,
    /// Device Locator (np. „DIMM 0”, „DIMM_A1”); pusty, gdy brak/zaślepka.
    locator: []const u8,
    /// Bank Locator (np. „P0 CHANNEL A”); pusty, gdy brak/zaślepka.
    bank: []const u8,
    /// Krótka etykieta („A1”) albo lokator, gdy kanału nie da się ustalić.
    label: []const u8,
    /// Etykieta jest „<kanał><pozycja>”, a nie kopią lokatora.
    label_derived: bool,
    /// Klucz kanału (`smbios.ChannelGuess.key`): (grupa << 8) | litera.
    channel: ?u16,
    /// Litera/cyfra kanału (np. 'A'); null = nieznany.
    channel_letter: ?u8,
    /// Pozycja w kanale (1-based), gdy etykieta jest wyprowadzona.
    position: ?u8,
    confidence: Confidence,
    occupied: bool,
    /// Rozmiar w bajtach; null = puste albo nieznany.
    size_bytes: ?u64,
    /// Surowy bajt typu pamięci (§7.18.2), np. 0x1A = DDR4.
    mem_type: ?u8,
    /// Producent (pole SMBIOS, bez zaślepek) — pusty, gdy brak.
    manufacturer: []const u8,
    part_number: []const u8,
};

pub const HintKind = enum {
    /// Brak obsadzonych gniazd.
    none,
    /// Jeden moduł — z definicji jeden kanał.
    single_module,
    /// Moduły w co najmniej dwóch różnych kanałach.
    multi_channel,
    /// Wszystkie moduły w jednym kanale (pewność co najmniej średnia).
    same_channel,
    /// Nie da się ustalić z nazw gniazd.
    unknown,
};

pub const Hint = struct {
    kind: HintKind,
    confidence: Confidence,
    /// Litery zajętych kanałów w kolejności pierwszego wystąpienia (np. "AB").
    channels_buf: [8]u8 = undefined,
    channels_len: u8 = 0,
    /// Płyta z 4 gniazdami nazwanymi A1/A2/B1/B2 i dwoma modułami: czy
    /// obsadzono zwykle zalecaną parę A2+B2. Null = nie dotyczy / nie wiadomo.
    recommended_pair: ?bool = null,

    pub fn channels(self: *const Hint) []const u8 {
        return self.channels_buf[0..self.channels_len];
    }
};

pub const Map = struct {
    slots: []Slot,
    hint: Hint,
};

fn text(f: ?smbios.StringField) []const u8 {
    const s = f orelse return "";
    return s.text() orelse "";
}

/// Etykieta jawnie w nazwie: „DIMM_A1”, „DIMMA2”, „CPU0_DIMM_B2”, „A1”.
/// Zwraca (litera, cyfra) albo null.
fn explicitLabel(loc: []const u8) ?struct { letter: u8, digit: u8 } {
    if (loc.len == 2 and std.ascii.isAlphabetic(loc[0]) and std.ascii.isDigit(loc[1])) {
        return .{ .letter = std.ascii.toUpper(loc[0]), .digit = loc[1] - '0' };
    }
    var from: usize = 0;
    while (from < loc.len) {
        const rel = std.ascii.indexOfIgnoreCase(loc[from..], "DIMM") orelse return null;
        var i = from + rel + 4;
        if (i < loc.len and (loc[i] == ' ' or loc[i] == '_' or loc[i] == '-')) i += 1;
        if (i + 1 < loc.len) {
            const c = std.ascii.toUpper(loc[i]);
            if (c >= 'A' and c <= 'H' and std.ascii.isDigit(loc[i + 1]) and (i + 2 == loc.len or !std.ascii.isDigit(loc[i + 2]))) {
                return .{ .letter = c, .digit = loc[i + 1] - '0' };
            }
        }
        from = from + rel + 4;
    }
    return null;
}

fn minConf(a: Confidence, b: Confidence) Confidence {
    return if (@intFromEnum(a) < @intFromEnum(b)) a else b;
}

/// Buduje mapę gniazd. `devices` = wszystkie typ 17 w kolejności tablicy.
/// Napisy etykiet są alokowane w `alloc` (zwykle arena strony).
pub fn build(alloc: std.mem.Allocator, devices: []const smbios.MemoryDevice) !Map {
    const slots = try alloc.alloc(Slot, devices.len);
    var groups_seen: [8]u8 = undefined;
    var n_groups: usize = 0;
    for (devices, 0..) |d, i| {
        const loc = text(d.device_locator);
        const bank = text(d.bank_locator);
        const g = smbios.guessChannel(if (loc.len > 0) loc else null, if (bank.len > 0) bank else null);
        const mt: ?u8 = if (d.memory_type) |m| m.raw else null;
        slots[i] = .{
            .index = @intCast(i + 1),
            .locator = loc,
            .bank = bank,
            .label = if (loc.len > 0) loc else bank,
            .label_derived = false,
            .channel = if (g) |x| x.key else null,
            .channel_letter = if (g) |x| @truncate(x.key & 0xFF) else null,
            .position = null,
            .confidence = if (g) |x| x.confidence else .none,
            .occupied = d.populated(),
            .size_bytes = if (d.populated()) (if (d.size) |z| z.bytes else null) else null,
            .mem_type = if (d.populated()) mt else null,
            .manufacturer = if (d.populated()) text(d.manufacturer) else "",
            .part_number = if (d.populated()) text(d.part_number) else "",
        };
        if (g) |x| {
            const grp: u8 = @truncate(x.key >> 8);
            if (std.mem.indexOfScalar(u8, groups_seen[0..n_groups], grp) == null and n_groups < groups_seen.len) {
                groups_seen[n_groups] = grp;
                n_groups += 1;
            }
        }
    }

    // Etykiety „<kanał><pozycja>”.
    for (slots, 0..) |*s, i| {
        const key = s.channel orelse continue;
        const letter = s.channel_letter.?;
        var pos: u8 = 0;
        if (explicitLabel(s.locator)) |e| {
            if (e.letter == letter) pos = e.digit;
        }
        if (pos == 0) {
            // Kolejność w obrębie kanału.
            pos = 1;
            for (slots[0..i]) |p| {
                if (p.channel != null and p.channel.? == key) pos +|= 1;
            }
        }
        s.position = pos;
        s.label_derived = true;
        const grp: u8 = @truncate(key >> 8);
        s.label = if (n_groups > 1)
            try std.fmt.allocPrint(alloc, "P{d}-{c}{d}", .{ grp, letter, pos })
        else
            try std.fmt.allocPrint(alloc, "{c}{d}", .{ letter, pos });
    }

    return .{ .slots = slots, .hint = hintOf(slots) };
}

fn hintOf(slots: []const Slot) Hint {
    var h: Hint = .{ .kind = .none, .confidence = .none };
    var keys: [16]u16 = undefined;
    var n_keys: usize = 0;
    var occupied: usize = 0;
    var missing = false;
    var conf: Confidence = .high;
    for (slots) |s| {
        if (!s.occupied) continue;
        occupied += 1;
        const k = s.channel orelse {
            missing = true;
            continue;
        };
        conf = minConf(conf, s.confidence);
        if (std.mem.indexOfScalar(u16, keys[0..n_keys], k) == null and n_keys < keys.len) {
            keys[n_keys] = k;
            n_keys += 1;
            if (h.channels_len < h.channels_buf.len) {
                h.channels_buf[h.channels_len] = s.channel_letter.?;
                h.channels_len += 1;
            }
        }
    }
    if (occupied == 0) return h;
    if (occupied == 1) {
        // Jeden moduł pracuje w jednym kanale niezależnie od nazw gniazd.
        h.kind = .single_module;
        h.confidence = .high;
        return h;
    }
    if (n_keys >= 2) {
        h.kind = .multi_channel;
        h.confidence = if (missing) .low else conf;
    } else if (n_keys == 1 and !missing and @intFromEnum(conf) >= @intFromEnum(Confidence.medium)) {
        h.kind = .same_channel;
        h.confidence = conf;
    } else {
        h.kind = .unknown;
        h.confidence = .none;
        h.channels_len = 0;
        return h;
    }
    h.recommended_pair = recommendedPair(slots, occupied);
    return h;
}

/// 4 gniazda = 2 kanały × 2 pozycje (A1, A2, B1, B2), 2 moduły: czy to A2+B2.
fn recommendedPair(slots: []const Slot, occupied: usize) ?bool {
    if (slots.len != 4 or occupied != 2) return null;
    var letters: [2]u8 = undefined;
    var n_letters: usize = 0;
    for (slots) |s| {
        if (!s.label_derived) return null;
        const l = s.channel_letter.?;
        const p = s.position.?;
        if (p < 1 or p > 2) return null;
        if (std.mem.indexOfScalar(u8, letters[0..n_letters], l) == null) {
            if (n_letters == 2) return null;
            letters[n_letters] = l;
            n_letters += 1;
        }
    }
    if (n_letters != 2) return null;
    // Każda para (litera, pozycja) dokładnie raz.
    for (letters[0..n_letters]) |l| {
        var seen: [3]bool = .{ false, false, false };
        for (slots) |s| {
            if (s.channel_letter.? != l) continue;
            if (seen[s.position.?]) return null;
            seen[s.position.?] = true;
        }
        if (!seen[1] or !seen[2]) return null;
    }
    for (slots) |s| {
        if (s.occupied and s.position.? != 2) return false;
    }
    return true;
}

/// Klucz producenta modułu z numeru części — w `gui/vendors.zig` razem z resztą
/// normalizacji producentów.
pub const partNumberVendorKey = vendors.partNumberVendorKey;

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

const testing = std.testing;

fn sf(s: []const u8) ?smbios.StringField {
    return .{ .index = 1, .raw = s, .value = s, .placeholder = false, .sensitive = false, .spec = "" };
}

fn dev(loc: []const u8, bank: []const u8, gb: u64) smbios.MemoryDevice {
    var d = std.mem.zeroes(smbios.MemoryDevice);
    d.device_locator = if (loc.len > 0) sf(loc) else null;
    d.bank_locator = if (bank.len > 0) sf(bank) else null;
    d.size = .{
        .raw = if (gb == 0) 0 else @intCast(gb * 1024),
        .raw_extended = null,
        .state = if (gb == 0) .empty else .installed,
        .bytes = gb * 1024 * 1024 * 1024,
        .from_extended = false,
        .spec = "",
    };
    d.memory_type = .{ .raw = 0x1A, .name = "DDR4", .spec = "" };
    return d;
}

fn labels(m: Map, out: *[8][]const u8) [][]const u8 {
    for (m.slots, 0..) |s, i| out[i] = s.label;
    return out[0..m.slots.len];
}

test "memslots: 2 z 4 obsadzone (AMD „P0 CHANNEL A”/„DIMM 1”) — A2+B2" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const devs = [_]smbios.MemoryDevice{
        dev("DIMM 0", "P0 CHANNEL A", 0),
        dev("DIMM 1", "P0 CHANNEL A", 16),
        dev("DIMM 0", "P0 CHANNEL B", 0),
        dev("DIMM 1", "P0 CHANNEL B", 16),
    };
    const m = try build(arena.allocator(), &devs);
    var lb: [8][]const u8 = undefined;
    const l = labels(m, &lb);
    try testing.expectEqualStrings("A1", l[0]);
    try testing.expectEqualStrings("A2", l[1]);
    try testing.expectEqualStrings("B1", l[2]);
    try testing.expectEqualStrings("B2", l[3]);
    try testing.expect(!m.slots[0].occupied and m.slots[1].occupied);
    try testing.expectEqual(@as(u16, 4), m.slots[3].index);
    try testing.expectEqual(HintKind.multi_channel, m.hint.kind);
    try testing.expectEqualStrings("AB", m.hint.channels());
    try testing.expectEqual(Confidence.medium, m.hint.confidence);
    try testing.expectEqual(@as(?bool, true), m.hint.recommended_pair);
}

test "memslots: 2 z 4 obsadzone, para A1+B1 — nie zalecana" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const devs = [_]smbios.MemoryDevice{
        dev("DIMM_A1", "BANK 0", 8),
        dev("DIMM_A2", "BANK 1", 0),
        dev("DIMM_B1", "BANK 2", 8),
        dev("DIMM_B2", "BANK 3", 0),
    };
    const m = try build(arena.allocator(), &devs);
    try testing.expectEqualStrings("A1", m.slots[0].label);
    try testing.expectEqualStrings("B2", m.slots[3].label);
    // Wzorzec DIMM_<litera> → pewność niska; podpowiedź dalej mówi o dwóch kanałach.
    try testing.expectEqual(Confidence.low, m.slots[0].confidence);
    try testing.expectEqual(HintKind.multi_channel, m.hint.kind);
    try testing.expectEqual(Confidence.low, m.hint.confidence);
    try testing.expectEqual(@as(?bool, false), m.hint.recommended_pair);
}

test "memslots: 4 z 4 obsadzone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const devs = [_]smbios.MemoryDevice{
        dev("ChannelA-DIMM1", "BANK 0", 8),
        dev("ChannelA-DIMM2", "BANK 1", 8),
        dev("ChannelB-DIMM1", "BANK 2", 8),
        dev("ChannelB-DIMM2", "BANK 3", 8),
    };
    const m = try build(arena.allocator(), &devs);
    try testing.expectEqualStrings("A1", m.slots[0].label);
    try testing.expectEqualStrings("A2", m.slots[1].label);
    try testing.expectEqualStrings("B2", m.slots[3].label);
    for (m.slots) |s| try testing.expect(s.occupied);
    try testing.expectEqual(HintKind.multi_channel, m.hint.kind);
    try testing.expect(m.hint.recommended_pair == null);
}

test "memslots: 2 z 2 obsadzone i moduły w jednym kanale" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const two = [_]smbios.MemoryDevice{
        dev("ChannelA-DIMM0", "BANK 0", 16),
        dev("ChannelB-DIMM0", "BANK 2", 16),
    };
    const m = try build(arena.allocator(), &two);
    try testing.expectEqualStrings("A1", m.slots[0].label);
    try testing.expectEqualStrings("B1", m.slots[1].label);
    try testing.expectEqual(HintKind.multi_channel, m.hint.kind);
    try testing.expect(m.hint.recommended_pair == null);

    const same = [_]smbios.MemoryDevice{
        dev("DIMM 0", "P0 CHANNEL A", 8),
        dev("DIMM 1", "P0 CHANNEL A", 8),
        dev("DIMM 0", "P0 CHANNEL B", 0),
        dev("DIMM 1", "P0 CHANNEL B", 0),
    };
    const m2 = try build(arena.allocator(), &same);
    try testing.expectEqual(HintKind.same_channel, m2.hint.kind);
    try testing.expectEqualStrings("A", m2.hint.channels());
    try testing.expectEqual(@as(?bool, false), m2.hint.recommended_pair);
}

test "memslots: nazwy bez kanału („Node0_Dimm1”) — etykieta = lokator, bez zgadywania" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const devs = [_]smbios.MemoryDevice{
        dev("Node0_Dimm1", "", 8),
        dev("Node0_Dimm2", "", 8),
    };
    const m = try build(arena.allocator(), &devs);
    try testing.expectEqualStrings("Node0_Dimm1", m.slots[0].label);
    try testing.expect(!m.slots[0].label_derived);
    try testing.expect(m.slots[0].channel == null);
    try testing.expectEqual(HintKind.unknown, m.hint.kind);
    try testing.expectEqual(Confidence.none, m.hint.confidence);
}

test "memslots: wykrywanie pustych gniazd i jeden moduł" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const devs = [_]smbios.MemoryDevice{
        dev("DIMM_A1", "", 0),
        dev("DIMM_A2", "", 16),
        dev("DIMM_B1", "", 0),
        dev("DIMM_B2", "", 0),
    };
    const m = try build(arena.allocator(), &devs);
    var occ: usize = 0;
    for (m.slots) |s| {
        if (s.occupied) occ += 1 else try testing.expect(s.size_bytes == null and s.mem_type == null);
    }
    try testing.expectEqual(@as(usize, 1), occ);
    try testing.expectEqual(@as(?u64, 16 * 1024 * 1024 * 1024), m.slots[1].size_bytes);
    try testing.expectEqual(HintKind.single_module, m.hint.kind);

    // Brak modułów.
    const none = [_]smbios.MemoryDevice{dev("DIMM_A1", "", 0)};
    try testing.expectEqual(HintKind.none, (try build(arena.allocator(), &none)).hint.kind);
}

test "memslots: kilka grup (dwa gniazda CPU) — przedrostek grupy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const devs = [_]smbios.MemoryDevice{
        dev("CPU0_DIMM_A1", "", 8),
        dev("CPU1_DIMM_A1", "", 8),
    };
    const m = try build(arena.allocator(), &devs);
    try testing.expectEqualStrings("P0-A1", m.slots[0].label);
    try testing.expectEqualStrings("P1-A1", m.slots[1].label);
    try testing.expectEqual(HintKind.multi_channel, m.hint.kind);
}

test "memslots: producent z numeru części" {
    try testing.expectEqualStrings("gskill", partNumberVendorKey("F4-4000C18-16GTZR").?);
    try testing.expectEqualStrings("crucial", partNumberVendorKey("CT16G4DFRA32A").?);
    try testing.expect(partNumberVendorKey("CTX") == null);
    try testing.expect(partNumberVendorKey("") == null);
}
