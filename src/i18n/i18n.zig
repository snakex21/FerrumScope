//! Tłumaczenia interfejsu (GUI, CLI, raporty TXT/HTML).
//!
//! Model jak w gettext: **identyfikatorem komunikatu jest tekst polski**
//! (język źródłowy), np. `t("Producent")`. Katalogi `locales/<kod>.json`
//! mapują identyfikator na tłumaczenie; brakujący wpis spada do angielskiego,
//! a potem do tekstu źródłowego. Dzięki temu strony raportu można budować
//! wprost w docelowym języku, a powiązania formularzy GUI tłumaczą swoje
//! klucze tą samą funkcją.
//!
//! * parametry nazwane: `tf("{used} z {total} zajęte", .{ .used = 2, .total = 4 })`,
//! * liczba mnoga (CLDR, liczby całkowite): wpis katalogu jest obiektem
//!   `{"one": "...", "few": "...", "many": "...", "other": "..."}`,
//!   wybór przez `tp(id, n, args)`; parametr `{n}` jest zawsze dostępny,
//! * wartości techniczne (nazwy instrukcji, MHz, ID PCI) nie przechodzą przez
//!   katalog; klucze eksportu JSON są stałe i angielskie.

const std = @import("std");

pub const locales = [_][]const u8{
    "pl", "en", "bg", "cs", "da", "de", "el", "es", "et", "fi", "fr", "hr", "hu", "it",
    "lt", "lv", "nb", "nl", "pt-BR", "ro", "ru", "sk", "sl", "sr-Latn", "sv", "tr", "uk",
};

/// Nazwy języków w nich samych (do wyboru w GUI).
pub const native_names = [_][]const u8{
    "Polski",     "English", "Български", "Čeština", "Dansk",    "Deutsch",   "Ελληνικά", "Español", "Eesti",
    "Suomi",      "Français", "Hrvatski", "Magyar",  "Italiano", "Lietuvių", "Latviešu", "Norsk bokmål",
    "Nederlands", "Português (Brasil)", "Română", "Русский", "Slovenčina", "Slovenščina", "Srpski", "Svenska",
    "Türkçe",     "Українська",
};

pub const Plural = enum { zero, one, two, few, many, other };

const Entry = union(enum) {
    text: []const u8,
    plural: [6]?[]const u8,
};

const Catalog = std.StringHashMapUnmanaged(Entry);

var arena_state: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);
var current: Catalog = .empty;
var fallback: Catalog = .empty;
var current_code: []const u8 = "pl";
var source_mode: bool = true;

/// Źródło tekstów katalogów (osadzonych w programie przez build.zig).
pub const Source = struct {
    code: []const u8,
    json: []const u8,
};
var sources: []const Source = &.{};

pub fn setSources(s: []const Source) void {
    sources = s;
}

fn findSource(code: []const u8) ?[]const u8 {
    for (sources) |s| if (std.ascii.eqlIgnoreCase(s.code, code)) return s.json;
    return null;
}

fn parseCatalog(alloc: std.mem.Allocator, json: []const u8, out: *Catalog) !void {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    if (v != .object) return error.BadCatalog;
    var it = v.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        if (key.len > 0 and key[0] == '@') continue; // metadane, np. "@locale"
        switch (kv.value_ptr.*) {
            .string => |s| try out.put(alloc, key, .{ .text = s }),
            .object => |o| {
                var forms: [6]?[]const u8 = @splat(null);
                inline for (@typeInfo(Plural).@"enum".fields, 0..) |f, i| {
                    if (o.get(f.name)) |x| if (x == .string) {
                        forms[i] = x.string;
                    };
                }
                try out.put(alloc, key, .{ .plural = forms });
            },
            else => return error.BadCatalog,
        }
    }
}

/// Ustawia język. `pl` = tekst źródłowy (bez katalogu). Nieznany kod → `en`.
pub fn setLocale(code: []const u8) void {
    _ = arena_state.reset(.free_all);
    const a = arena_state.allocator();
    current = .empty;
    fallback = .empty;
    const c = normalizeCode(code);
    current_code = c;
    source_mode = std.mem.eql(u8, c, "pl");
    if (source_mode) {
        // Polski ma katalog tylko dla liczby mnogiej (formy one/few/many).
        if (findSource("pl")) |j| parseCatalog(a, j, &current) catch {};
        return;
    }
    if (findSource(c)) |j| parseCatalog(a, j, &current) catch {};
    if (!std.mem.eql(u8, c, "en")) {
        if (findSource("en")) |j| parseCatalog(a, j, &fallback) catch {};
    }
}

pub fn locale() []const u8 {
    return current_code;
}

/// Kod obsługiwanego języka dla dowolnego tagu (np. `pl-PL` → `pl`,
/// `pt-PT` → `pt-BR`, `sr-Latn-RS` → `sr-Latn`, `no`/`nn` → `nb`). Nieznany → `en`.
pub fn normalizeCode(tag: []const u8) []const u8 {
    for (locales) |l| if (std.ascii.eqlIgnoreCase(l, tag)) return l;
    const dash = std.mem.indexOfAny(u8, tag, "-_") orelse tag.len;
    const lang = tag[0..dash];
    if (std.ascii.eqlIgnoreCase(lang, "pt")) return "pt-BR";
    if (std.ascii.eqlIgnoreCase(lang, "sr")) return "sr-Latn";
    if (std.ascii.eqlIgnoreCase(lang, "no") or std.ascii.eqlIgnoreCase(lang, "nn") or std.ascii.eqlIgnoreCase(lang, "nb")) return "nb";
    for (locales) |l| if (std.ascii.eqlIgnoreCase(l, lang)) return l;
    return "en";
}

/// Kategoria liczby mnogiej CLDR dla liczby całkowitej `n` w języku `code`.
pub fn pluralOf(code: []const u8, n_signed: i64) Plural {
    const n: u64 = @abs(n_signed);
    const m10 = n % 10;
    const m100 = n % 100;
    const lang = code[0 .. std.mem.indexOfScalar(u8, code, '-') orelse code.len];
    const eq = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;
    if (eq(lang, "pl")) {
        if (n == 1) return .one;
        if (m10 >= 2 and m10 <= 4 and !(m100 >= 12 and m100 <= 14)) return .few;
        return .many;
    }
    if (eq(lang, "ru") or eq(lang, "uk")) {
        if (m10 == 1 and m100 != 11) return .one;
        if (m10 >= 2 and m10 <= 4 and !(m100 >= 12 and m100 <= 14)) return .few;
        return .many;
    }
    if (eq(lang, "cs") or eq(lang, "sk")) {
        if (n == 1) return .one;
        if (n >= 2 and n <= 4) return .few;
        return .other;
    }
    if (eq(lang, "hr") or eq(lang, "sr")) {
        if (m10 == 1 and m100 != 11) return .one;
        if (m10 >= 2 and m10 <= 4 and !(m100 >= 12 and m100 <= 14)) return .few;
        return .other;
    }
    if (eq(lang, "sl")) {
        if (m100 == 1) return .one;
        if (m100 == 2) return .two;
        if (m100 == 3 or m100 == 4) return .few;
        return .other;
    }
    if (eq(lang, "lt")) {
        if (m10 == 1 and !(m100 >= 11 and m100 <= 19)) return .one;
        if (m10 >= 2 and !(m100 >= 11 and m100 <= 19)) return .few;
        return .other;
    }
    if (eq(lang, "lv")) {
        if (m10 == 0 or (m100 >= 11 and m100 <= 19)) return .zero;
        if (m10 == 1 and m100 != 11) return .one;
        return .other;
    }
    if (eq(lang, "ro")) {
        if (n == 1) return .one;
        if (n == 0 or (m100 >= 2 and m100 <= 19)) return .few;
        return .other;
    }
    if (eq(lang, "fr") or eq(lang, "pt")) {
        if (n <= 1) return .one;
        return .other;
    }
    // en, de, nl, sv, da, nb, fi, et, el, it, es, bg, hu, tr
    if (n == 1) return .one;
    return .other;
}

fn lookup(id: []const u8) ?Entry {
    if (current.get(id)) |e| return e;
    if (fallback.get(id)) |e| return e;
    return null;
}

/// Tłumaczenie identyfikatora (tekstu polskiego).
pub fn t(id: []const u8) []const u8 {
    if (lookup(id)) |e| switch (e) {
        .text => |s| return s,
        .plural => |f| return f[@intFromEnum(Plural.other)] orelse id,
    };
    return id;
}

fn pickPlural(e: Entry, code: []const u8, n: i64, id: []const u8) []const u8 {
    switch (e) {
        .text => |s| return s,
        .plural => |f| {
            const cat = pluralOf(code, n);
            if (f[@intFromEnum(cat)]) |s| return s;
            if (f[@intFromEnum(Plural.other)]) |s| return s;
            if (f[@intFromEnum(Plural.many)]) |s| return s;
            return id;
        },
    }
}

/// Podstawia `{nazwa}` wartościami pól struktury `args` (napisy jako `{s}`,
/// liczby jako `{d}`). Nieznany `{x}` zostaje bez zmian.
pub fn substitute(alloc: std.mem.Allocator, template: []const u8, args: anytype) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, template, i, '}')) |end| {
                const name = template[i + 1 .. end];
                var done = false;
                inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |fld| {
                    if (!done and std.mem.eql(u8, fld.name, name)) {
                        const v = @field(args, fld.name);
                        const T = @TypeOf(v);
                        const s = switch (@typeInfo(T)) {
                            .int, .comptime_int, .float, .comptime_float => std.fmt.allocPrint(alloc, "{d}", .{v}),
                            else => std.fmt.allocPrint(alloc, "{s}", .{v}),
                        } catch "";
                        out.appendSlice(alloc, s) catch {};
                        done = true;
                    }
                }
                if (done) {
                    i = end + 1;
                    continue;
                }
            }
        }
        out.append(alloc, template[i]) catch {};
        i += 1;
    }
    return out.items;
}

/// Tłumaczenie z parametrami nazwanymi.
pub fn tf(alloc: std.mem.Allocator, id: []const u8, args: anytype) []const u8 {
    return substitute(alloc, t(id), args);
}

/// Tłumaczenie zależne od liczby (`{n}` dostępne zawsze).
pub fn tp(alloc: std.mem.Allocator, id: []const u8, n: i64, args: anytype) []const u8 {
    const tmpl = if (lookup(id)) |e| pickPlural(e, if (source_mode) "pl" else current_code, n, id) else id;
    const s1 = substitute(alloc, tmpl, args);
    return substitute(alloc, s1, .{ .n = n });
}

/// Nazwy parametrów `{x}` w tekście (do testów zgodności katalogów).
pub fn placeholders(s: []const u8, out: *[16][]const u8) [][]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, i, '{')) |a| {
        const b = std.mem.indexOfScalarPos(u8, s, a, '}') orelse break;
        if (n < out.len) {
            out[n] = s[a + 1 .. b];
            n += 1;
        }
        i = b + 1;
    }
    return out[0..n];
}

// ---------------------------------------------------------------------------
// Testy (bez katalogów — reguły i podstawianie)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "i18n: reguły liczby mnogiej CLDR" {
    try testing.expectEqual(Plural.one, pluralOf("pl", 1));
    try testing.expectEqual(Plural.few, pluralOf("pl", 3));
    try testing.expectEqual(Plural.many, pluralOf("pl", 5));
    try testing.expectEqual(Plural.many, pluralOf("pl", 12));
    try testing.expectEqual(Plural.few, pluralOf("pl", 22));
    try testing.expectEqual(Plural.one, pluralOf("ru", 21));
    try testing.expectEqual(Plural.many, pluralOf("ru", 11));
    try testing.expectEqual(Plural.few, pluralOf("cs", 4));
    try testing.expectEqual(Plural.two, pluralOf("sl", 102));
    try testing.expectEqual(Plural.zero, pluralOf("lv", 10));
    try testing.expectEqual(Plural.few, pluralOf("lt", 9));
    try testing.expectEqual(Plural.few, pluralOf("ro", 19));
    try testing.expectEqual(Plural.one, pluralOf("fr", 0));
    try testing.expectEqual(Plural.one, pluralOf("pt-BR", 1));
    try testing.expectEqual(Plural.other, pluralOf("en", 0));
    try testing.expectEqual(Plural.one, pluralOf("sr-Latn", 31));
}

test "i18n: normalizacja kodów języka" {
    try testing.expectEqualStrings("pl", normalizeCode("pl-PL"));
    try testing.expectEqualStrings("pt-BR", normalizeCode("pt-PT"));
    try testing.expectEqualStrings("sr-Latn", normalizeCode("sr-Latn-RS"));
    try testing.expectEqualStrings("nb", normalizeCode("nn-NO"));
    try testing.expectEqualStrings("en", normalizeCode("ja-JP"));
    try testing.expectEqualStrings("de", normalizeCode("de_AT"));
}

test "i18n: parametry nazwane" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = substitute(arena.allocator(), "{used} z {total} zajęte ({x})", .{ .used = 2, .total = @as(u32, 4) });
    try testing.expectEqualStrings("2 z 4 zajęte ({x})", s);
    var buf: [16][]const u8 = undefined;
    const ph = placeholders("{a} i {b}", &buf);
    try testing.expectEqual(@as(usize, 2), ph.len);
    try testing.expectEqualStrings("b", ph[1]);
}

test "i18n: wybór formy z katalogu i spadek do angielskiego" {
    setSources(&.{
        .{ .code = "en", .json = "{\"Dysk\": \"Disk\", \"{n} dysków\": {\"one\": \"{n} disk\", \"other\": \"{n} disks\"}, \"Tylko EN\": \"Only EN\"}" },
        .{ .code = "de", .json = "{\"Dysk\": \"Laufwerk\", \"{n} dysków\": {\"one\": \"{n} Laufwerk\", \"other\": \"{n} Laufwerke\"}}" },
        .{ .code = "pl", .json = "{\"{n} dysków\": {\"one\": \"{n} dysk\", \"few\": \"{n} dyski\", \"many\": \"{n} dysków\"}}" },
    });
    defer setSources(&.{});
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    setLocale("de-DE");
    try testing.expectEqualStrings("Laufwerk", t("Dysk"));
    try testing.expectEqualStrings("Only EN", t("Tylko EN"));
    try testing.expectEqualStrings("1 Laufwerk", tp(a, "{n} dysków", 1, .{}));
    try testing.expectEqualStrings("10 Laufwerke", tp(a, "{n} dysków", 10, .{}));
    setLocale("pl");
    try testing.expectEqualStrings("Dysk", t("Dysk"));
    try testing.expectEqualStrings("3 dyski", tp(a, "{n} dysków", 3, .{}));
    try testing.expectEqualStrings("5 dysków", tp(a, "{n} dysków", 5, .{}));
    setLocale("pl");
}
