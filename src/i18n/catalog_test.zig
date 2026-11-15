//! Testy katalogów tłumaczeń (`locales/*.json`) względem kodu źródłowego.
//!
//! Skaner przechodzi `src/**/*.zig` tokenizerem Zig i zbiera identyfikatory
//! komunikatów: literał napisu podany wprost jako argument `.t(`, `.N(`,
//! `.tf(` / `.tp(` (pierwszy argument albo — gdy pierwszy jest alokatorem —
//! drugi). Do tego dochodzą identyfikatory z tablic `src/gui/forms.zig`
//! (etykiety, tytuły, sekcje, pola), tłumaczone w oknie w miejscu użycia.
//!
//! Sprawdzamy:
//!   * `en.json` zawiera każdy identyfikator (angielski jest językiem zapasowym),
//!   * żaden katalog nie ma kluczy spoza kodu,
//!   * parametry `{nazwa}` tłumaczenia = parametry identyfikatora,
//!   * wpisy liczby mnogiej mają `other` i kategorie wymagane przez język,
//!   * w kodzie GUI/CLI/stron nie ma polskich literałów poza katalogiem.
//!
//! Testy czytają pliki względem katalogu głównego projektu (build.zig ustawia
//! cwd uruchomienia testów na `b.path(".")`).

const std = @import("std");
const i18n = @import("i18n.zig");
const forms = @import("../gui/forms.zig");
const embedded = @import("locales_embedded");

/// Języki, których katalogi są jeszcze w przygotowaniu: dla nich test
/// kompletności nie wymaga wszystkich identyfikatorów (pozostałe testy —
/// nadmiarowe klucze, parametry, formy liczby mnogiej — obowiązują zawsze).
/// Tłumacz po ukończeniu katalogu usuwa swój kod z tej listy.
pub const pending_locales = [_][]const u8{
    "bg", "cs", "da", "de",    "el", "es", "et", "fi", "fr",      "hr", "hu", "it", "lt",
    "lv", "nb", "nl", "pt-BR", "ro", "ru", "sk", "sl", "sr-Latn", "sv", "tr", "uk",
};

/// Pliki, w których nie może być polskich literałów poza wywołaniami katalogu.
const strict_files = [_][]const u8{
    "src/gui_main.zig",
    "src/gui/forms.zig",
    "src/main.zig",
    "src/sys/pages_cpu.zig",
    "src/sys/pages_system.zig",
    "src/sys/report.zig",
    "src/app.zig",
};

/// Świadome wyjątki skanera polskich literałów: (plik, fragment literału).
const hardcoded_allow = [_]struct { file: []const u8, needle: []const u8 }{
    // Strona przykładowa `samplePage` używana wyłącznie przez testy eksportu.
    .{ .file = "src/sys/report.zig", .needle = "\"Płyta" },
};

const Kind = enum { text, plural };

const Ids = struct {
    map: std.StringArrayHashMapUnmanaged(Kind) = .empty,

    fn put(self: *Ids, a: std.mem.Allocator, id: []const u8, k: Kind) !void {
        const gop = try self.map.getOrPut(a, id);
        if (!gop.found_existing or k == .plural) gop.value_ptr.* = k;
    }
};

const Literal = struct { start: usize, catalog: bool };

/// Wynik skanowania jednego pliku: identyfikatory i polskie literały poza katalogiem.
const FileScan = struct {
    hardcoded: std.ArrayList([]const u8) = .empty,
};

fn hasPolish(s: []const u8) bool {
    const letters = [_][]const u8{ "ą", "ć", "ę", "ł", "ń", "ó", "ś", "ź", "ż", "Ą", "Ć", "Ę", "Ł", "Ń", "Ó", "Ś", "Ź", "Ż" };
    for (letters) |l| if (std.mem.indexOf(u8, s, l) != null) return true;
    return false;
}

const form_keys = [_][]const u8{ "label", "title", "sect", "field", "alt", "button", "prefix" };
/// Pola `forms.Cell` będące identyfikatorami wiązania (tłumaczone w `forms.resolve`)
/// — w forms.zig i gui_main.zig, np. `.{ .sect = "@Gniazdo {slot}", .field = "Moduł" }`.
const binding_keys = [_][]const u8{ "sect", "field", "alt" };

fn scanSource(a: std.mem.Allocator, path: []const u8, src: [:0]const u8, ids: *Ids, out: *FileScan) !void {
    var toks: std.ArrayList(std.zig.Token) = .empty;
    var tz = std.zig.Tokenizer.init(src);
    while (true) {
        const tk = tz.next();
        if (tk.tag == .eof) break;
        try toks.append(a, tk);
    }
    const T = toks.items;
    const is_forms = std.mem.endsWith(u8, path, "gui/forms.zig");

    // Zakresy bloków `test` (pomijane).
    var in_test = try a.alloc(bool, T.len);
    @memset(in_test, false);
    var i: usize = 0;
    while (i < T.len) : (i += 1) {
        if (T[i].tag != .keyword_test) continue;
        var j = i;
        while (j < T.len and T[j].tag != .l_brace) : (j += 1) {}
        var depth: usize = 0;
        while (j < T.len) : (j += 1) {
            if (T[j].tag == .l_brace) depth += 1;
            if (T[j].tag == .r_brace) {
                depth -= 1;
                if (depth == 0) break;
            }
        }
        for (i..@min(j + 1, T.len)) |k| in_test[k] = true;
        i = j;
    }

    var catalog = try a.alloc(bool, T.len);
    @memset(catalog, false);

    i = 0;
    while (i + 2 < T.len) : (i += 1) {
        if (in_test[i]) continue;
        if (T[i].tag != .period or T[i + 1].tag != .identifier or T[i + 2].tag != .l_paren) continue;
        const name = src[T[i + 1].loc.start..T[i + 1].loc.end];
        const is_t = std.mem.eql(u8, name, "t") or std.mem.eql(u8, name, "N");
        const is_tf = std.mem.eql(u8, name, "tf");
        const is_tp = std.mem.eql(u8, name, "tp");
        if (!is_t and !is_tf and !is_tp) continue;
        var k = i + 3;
        if (k >= T.len) break;
        if (T[k].tag != .string_literal and !is_t) {
            // Pierwszy argument to alokator: msgid jest po pierwszym przecinku.
            var depth: usize = 0;
            while (k < T.len) : (k += 1) {
                switch (T[k].tag) {
                    .l_paren, .l_brace, .l_bracket => depth += 1,
                    .r_paren, .r_brace, .r_bracket => {
                        if (depth == 0) break;
                        depth -= 1;
                    },
                    .comma => if (depth == 0) break,
                    else => {},
                }
            }
            if (k >= T.len or T[k].tag != .comma) continue;
            k += 1;
        }
        if (k >= T.len or T[k].tag != .string_literal) continue;
        const lit = src[T[k].loc.start..T[k].loc.end];
        const id = std.zig.string_literal.parseAlloc(a, lit) catch continue;
        try ids.put(a, id, if (is_tp) .plural else .text);
        catalog[k] = true;
    }

    // Identyfikatory wiązania komórek formularzy (`.sect`/`.field`/`.alt = "…"`).
    const binds = is_forms or std.mem.endsWith(u8, path, "gui_main.zig");
    for (T, 0..) |tk, idx| {
        if (!binds) break;
        if (in_test[idx] or tk.tag != .string_literal or idx < 3) continue;
        if (T[idx - 1].tag != .equal or T[idx - 2].tag != .identifier or T[idx - 3].tag != .period) continue;
        const key = src[T[idx - 2].loc.start..T[idx - 2].loc.end];
        for (binding_keys) |bk| if (std.mem.eql(u8, key, bk)) {
            const id = std.zig.string_literal.parseAlloc(a, src[tk.loc.start..tk.loc.end]) catch break;
            if (id.len == 0) break;
            try ids.put(a, if (id[0] == '@') id[1..] else id, .text);
            catalog[idx] = true;
        };
    }

    // Polskie literały poza katalogiem.
    for (T, 0..) |tk, idx| {
        if (in_test[idx] or catalog[idx]) continue;
        if (tk.tag != .string_literal and tk.tag != .multiline_string_literal_line) continue;
        const lit = src[tk.loc.start..tk.loc.end];
        if (!hasPolish(lit)) continue;
        if (is_forms and idx >= 3 and T[idx - 1].tag == .equal and T[idx - 2].tag == .identifier) {
            const key = src[T[idx - 2].loc.start..T[idx - 2].loc.end];
            var ok = idx >= 3 and T[idx - 3].tag == .keyword_const;
            if (T[idx - 3].tag == .period) for (form_keys) |fk| {
                if (std.mem.eql(u8, key, fk)) ok = true;
            };
            if (ok) continue;
        }
        var allowed = false;
        for (hardcoded_allow) |al| {
            if (std.mem.endsWith(u8, path, al.file) and std.mem.indexOf(u8, lit, al.needle) != null) allowed = true;
        }
        if (allowed) continue;
        const line = std.mem.count(u8, src[0..tk.loc.start], "\n") + 1;
        try out.hardcoded.append(a, try std.fmt.allocPrint(a, "{s}:{d}: {s}", .{ path, line, lit }));
    }
}

fn formsIds(a: std.mem.Allocator, ids: *Ids) !void {
    for (forms.tabs) |tab| {
        try ids.put(a, tab.title, .text);
        if (tab.selector) |s| {
            try ids.put(a, s.label, .text);
            try ids.put(a, s.prefix, .text);
        }
        for (tab.bands) |band| for (band) |g| {
            try ids.put(a, g.title, .text);
            for (g.rows) |r| for (r) |c| {
                try ids.put(a, c.label, .text);
                try ids.put(a, if (c.sect.len > 0 and c.sect[0] == '@') c.sect[1..] else c.sect, .text);
                try ids.put(a, c.field, .text);
                if (c.alt.len > 0) try ids.put(a, c.alt, .text);
                if (c.button.len > 0) try ids.put(a, c.button, .text);
            };
        };
    }
}

const Scan = struct {
    ids: Ids = .{},
    hardcoded: std.ArrayList([]const u8) = .empty,
};

fn scanAll(a: std.mem.Allocator) !Scan {
    var res: Scan = .{};
    var dir = try std.fs.cwd().openDir("src", .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next()) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.path, ".zig")) continue;
        const rel = try std.fmt.allocPrint(a, "src/{s}", .{e.path});
        std.mem.replaceScalar(u8, rel, '\\', '/');
        // Testy i sam rdzeń i18n nie definiują komunikatów interfejsu.
        if (std.mem.eql(u8, rel, "src/tests.zig") or std.mem.startsWith(u8, rel, "src/i18n/")) continue;
        const src = try dir.readFileAllocOptions(a, e.path, 16 * 1024 * 1024, null, .of(u8), 0);
        var fs_: FileScan = .{};
        try scanSource(a, rel, src, &res.ids, &fs_);
        var strict = false;
        for (strict_files) |sf| if (std.mem.eql(u8, sf, rel)) {
            strict = true;
        };
        if (strict) try res.hardcoded.appendSlice(a, fs_.hardcoded.items);
    }
    try formsIds(a, &res.ids);
    return res;
}

fn placeholderSet(a: std.mem.Allocator, s: []const u8, drop_n: bool) ![]const []const u8 {
    var buf: [16][]const u8 = undefined;
    var list: std.ArrayList([]const u8) = .empty;
    for (i18n.placeholders(s, &buf)) |p| {
        if (drop_n and std.mem.eql(u8, p, "n")) continue;
        var dup = false;
        for (list.items) |x| if (std.mem.eql(u8, x, p)) {
            dup = true;
        };
        if (!dup) try list.append(a, p);
    }
    std.mem.sort([]const u8, list.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return list.items;
}

fn sameSet(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

fn isPending(code: []const u8) bool {
    for (pending_locales) |p| if (std.mem.eql(u8, p, code)) return true;
    return false;
}

/// Kategorie liczby mnogiej, które język faktycznie wybiera (n = 0..1000).
fn requiredCategories(code: []const u8) [6]bool {
    var req: [6]bool = @splat(false);
    var n: i64 = 0;
    while (n <= 1000) : (n += 1) req[@intFromEnum(i18n.pluralOf(code, n))] = true;
    req[@intFromEnum(i18n.Plural.other)] = true;
    return req;
}

fn jsonOf(code: []const u8) []const u8 {
    for (embedded.codes, embedded.jsons) |c, j| if (std.mem.eql(u8, c, code)) return j;
    return "";
}

const sources = i18n.embeddedSources(embedded);

test "i18n: lista języków w build.zig = i18n.locales, każdy katalog ma @locale" {
    try std.testing.expectEqual(i18n.locales.len, embedded.codes.len);
    for (i18n.locales, embedded.codes, 0..) |l, c, i| {
        try std.testing.expectEqualStrings(l, c);
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), embedded.jsons[i], .{});
        try std.testing.expect(v == .object);
        const meta = v.object.get("@locale") orelse return error.MissingLocaleMeta;
        try std.testing.expectEqualStrings(c, meta.string);
    }
}

test "i18n: katalogi są kompletne i zgodne z kodem (parametry, liczba mnoga)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const scan = try scanAll(a);
    const ids = scan.ids.map;
    try std.testing.expect(ids.count() > 300);

    var errors: usize = 0;
    for (embedded.codes, embedded.jsons) |code, json| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
        const obj = v.object;
        const req = requiredCategories(code);
        // 1. Nadmiarowe klucze, parametry, formy liczby mnogiej.
        var it = obj.iterator();
        while (it.next()) |kv| {
            const key = kv.key_ptr.*;
            if (key.len > 0 and key[0] == '@') continue;
            const kind = ids.get(key) orelse {
                std.debug.print("[{s}] klucz spoza kodu: \"{s}\"\n", .{ code, key });
                errors += 1;
                continue;
            };
            const src_ph = try placeholderSet(a, i18n.stripContext(key), kind == .plural);
            switch (kv.value_ptr.*) {
                .string => |s| {
                    if (kind == .plural) {
                        std.debug.print("[{s}] \"{s}\": wpis liczby mnogiej musi być obiektem\n", .{ code, key });
                        errors += 1;
                    } else if (!sameSet(src_ph, try placeholderSet(a, s, false))) {
                        std.debug.print("[{s}] \"{s}\": inne parametry {{}} niż w identyfikatorze\n", .{ code, key });
                        errors += 1;
                    }
                },
                .object => |o| {
                    if (kind != .plural) {
                        std.debug.print("[{s}] \"{s}\": obiekt liczby mnogiej dla identyfikatora bez tp()\n", .{ code, key });
                        errors += 1;
                        continue;
                    }
                    inline for (@typeInfo(i18n.Plural).@"enum".fields, 0..) |f, ci| {
                        if (o.get(f.name)) |form| {
                            if (form != .string or !sameSet(src_ph, try placeholderSet(a, form.string, true))) {
                                std.debug.print("[{s}] \"{s}\".{s}: inne parametry {{}} niż w identyfikatorze\n", .{ code, key, f.name });
                                errors += 1;
                            }
                        } else if (req[ci]) {
                            std.debug.print("[{s}] \"{s}\": brak formy \"{s}\"\n", .{ code, key, f.name });
                            errors += 1;
                        }
                    }
                    var oit = o.iterator();
                    while (oit.next()) |fkv| {
                        if (std.meta.stringToEnum(i18n.Plural, fkv.key_ptr.*) == null) {
                            std.debug.print("[{s}] \"{s}\": nieznana kategoria \"{s}\"\n", .{ code, key, fkv.key_ptr.* });
                            errors += 1;
                        }
                    }
                },
                else => {
                    std.debug.print("[{s}] \"{s}\": wartość musi być napisem albo obiektem\n", .{ code, key });
                    errors += 1;
                },
            }
        }
        // 2. Kompletność: en (i każdy nie-„pending”) ma wszystko; pl tylko liczbę mnogą.
        const is_pl = std.mem.eql(u8, code, "pl");
        if (!is_pl and isPending(code)) continue;
        var missing: usize = 0;
        var iit = ids.iterator();
        while (iit.next()) |kv| {
            if (is_pl and kv.value_ptr.* != .plural) continue;
            if (obj.get(kv.key_ptr.*) == null) {
                if (missing < 40) std.debug.print("[{s}] brak tłumaczenia: \"{s}\"\n", .{ code, kv.key_ptr.* });
                missing += 1;
            }
        }
        if (missing > 0) std.debug.print("[{s}] brakujących wpisów: {d}\n", .{ code, missing });
        errors += missing;
    }
    try std.testing.expectEqual(@as(usize, 0), errors);
}

test "i18n: brak polskich literałów poza katalogiem w kodzie GUI/CLI/stron" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const scan = try scanAll(arena.allocator());
    for (scan.hardcoded.items) |h| std.debug.print("literał poza katalogiem: {s}\n", .{h});
    try std.testing.expectEqual(@as(usize, 0), scan.hardcoded.items.len);
}

test "i18n: liczba mnoga na prawdziwych wpisach katalogu (pl, en)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    i18n.setSources(&sources);
    defer {
        i18n.setSources(&.{});
        i18n.setLocale("pl");
    }
    const pl = try std.json.parseFromSliceLeaky(std.json.Value, a, jsonOf("pl"), .{});
    const en = try std.json.parseFromSliceLeaky(std.json.Value, a, jsonOf("en"), .{});
    var checked: usize = 0;
    var it = pl.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .object) continue;
        const id = kv.key_ptr.*;
        const forms_pl = kv.value_ptr.object;
        const forms_en = en.object.get(id).?.object;
        i18n.setLocale("pl");
        // 1 → one, 3/22 → few, 5/12 → many.
        const cases = [_]struct { n: i64, cat: []const u8 }{ .{ .n = 1, .cat = "one" }, .{ .n = 3, .cat = "few" }, .{ .n = 22, .cat = "few" }, .{ .n = 5, .cat = "many" }, .{ .n = 12, .cat = "many" } };
        for (cases) |c| {
            const want = i18n.substitute(a, forms_pl.get(c.cat).?.string, .{ .n = c.n });
            const got = i18n.tp(a, id, c.n, .{});
            // Inne parametry zostają w obu napisach jako `{x}`.
            try std.testing.expectEqualStrings(want, got);
        }
        i18n.setLocale("en");
        try std.testing.expectEqualStrings(i18n.substitute(a, forms_en.get("one").?.string, .{ .n = 1 }), i18n.tp(a, id, 1, .{}));
        try std.testing.expectEqualStrings(i18n.substitute(a, forms_en.get("other").?.string, .{ .n = 7 }), i18n.tp(a, id, 7, .{}));
        checked += 1;
    }
    try std.testing.expect(checked > 0);
}
