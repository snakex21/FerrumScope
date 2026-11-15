//! Kompilator hardware database: TOML -> walidacja -> `ferrum-hwdb.bin`.
//!
//! Uruchamiany jako build step. Robi trzy rzeczy w kolejności:
//!
//! 1. **Parsuje** ograniczony podzbiór TOML (tylko to, czego potrzebujemy).
//! 2. **Waliduje** semantykę: duplikaty, nakładanie się reguł, błędne zakresy,
//!    nieznane wartości enumów, brakujące pola obowiązkowe, literówki w kluczach.
//! 3. **Serializuje** do binarnego formatu z sumą SHA-256.
//!
//! Baza **nie wykonuje kodu**. Kompilator jest jedynym miejscem, w którym tekst
//! TOML jest w ogóle interpretowany — runtime dostaje gotowe bajty.
//!
//! Podzbiór TOML jest celowo wąski: `[meta]`, `[[entry]]`, `klucz = wartość`,
//! gdzie wartość to napis w cudzysłowie, liczba (dziesiętna lub `0x…`) albo
//! `true`/`false`. Nieobsługiwane konstrukcje są **błędem**, a nie pominięciem —
//! inaczej literówka w kluczu cicho pominęłaby wpis.

const std = @import("std");
const ferrum = @import("ferrum");
const hwdb = ferrum.db.hwdb;

const Writer = std.fs.File.Writer;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

var stdout_buf: [64 * 1024]u8 = undefined;
var stdout_w: std.fs.File.Writer = undefined;
var stdout_ready = false;

/// Writer trzymamy w globalnej zmiennej: `File.writer()` zwraca strukturę,
/// której nie wolno używać jako wartości tymczasowej. Poza tym bufor wymaga
/// jawnego `flush()` — inaczej końcówka komunikatu zostaje w pamięci.
fn stdout() *std.Io.Writer {
    if (!stdout_ready) {
        stdout_w = std.fs.File.stdout().writer(&stdout_buf);
        stdout_ready = true;
    }
    return &stdout_w.interface;
}

fn print(comptime fmt: []const u8, args: anytype) void {
    stdout().print(fmt, args) catch {};
}

fn fail(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("hwdb: BŁĄD: " ++ fmt ++ "\n", args);
}

/// Wpis w trakcie parsowania — pola opcjonalne, bo to zadanie walidatora:
/// brakujące pole obowiązkowe musi dać błąd, a nie wartość domyślną.
const Pending = struct {
    file: []const u8,
    line: usize,
    vendor: ?[]const u8 = null,
    ext_family: ?u64 = null,
    family_field: ?u64 = null,
    model_min: ?u64 = null,
    model_max: ?u64 = null,
    stepping_min: ?u64 = null,
    stepping_max: ?u64 = null,
    uarch: ?[]const u8 = null,
    codename: ?[]const u8 = null,
    revision: ?[]const u8 = null,
    source: ?[]const u8 = null,
    source_url: ?[]const u8 = null,
    confidence: ?[]const u8 = null,
    /// Wpis opisuje **całą rodzinę**, nie konkretny model.
    ///
    /// Wymaga `model_min = 0` i `model_max = 0xFF`. Bez tej flagi wpis szczegółowy
    /// nigdy nie może być fallbackem rodzinnym — to warunek, którego brakowało,
    /// przez co nieznany model rodziny 6 raportował się jako „Merom/Conroe".
    family_generic: bool = false,
    /// Nazwa **siliconu** — fizycznego układu, na którym powstał procesor.
    ///
    /// Osobne od `codename`, bo to nie to samo: Zen 3 występuje na kilku
    /// różnych silikonach, a jeden silikon obsługuje warianty. `codename`
    /// opisuje **generację**; `silicon_family` — konkretny układ.
    silicon_family: ?[]const u8 = null,
    /// Linia produktowa: „Ryzen 5000”, „EPYC 7003”. Warstwa marketingowa, ale
    /// **jednoznaczna** dla jednego procesora — w przeciwieństwie do `codename`,
    /// który dla zakresu modeli bywa wspólny dla desktopu i serwera.
    product_family: ?[]const u8 = null,
    /// Wariant w obręcie produktu: „3D V-Cache”, „X”, „G”, „K”.
    variant: ?[]const u8 = null,
    /// Wariant cache, np. „3D V-Cache”, gdy model ma dodatkowy cache na pakiecie.
    /// Osobne od `variant`, bo cache bywa cechą **pakietu**, nie rdzenia.
    cache_variant: ?[]const u8 = null,
    quirk_no_brand_string: bool = false,
    quirk_htt_unreliable: bool = false,
    quirk_cache_leaf_ext: bool = false,
    quirk_extended_model_rule: bool = false,
    quirk_hybrid_cores: bool = false,
    quirk_smt_threads: u4 = 0,
};

/// Rekord `[[fact]]` — fakt o sygnaturze (`stepping_name`, `socket_name`).
///
/// Osobny typ od `Pending`, bo `Fact` **nie** jest wpisem bazy: nie bierze
/// udziału w `MatchQuality` i nie może przywłaszczyć sobie `codename`.
/// Zakres `0x20..0x3F` to w jednym wpisie desktop i serwer, więc opisanie
/// gniazda w `Entry` wymusiłoby rozbicie wpisu — czyli zmianę semantyki
/// dopasowania. Fakt pozwala opisać to precyzyjnie, nie ruszając trafienia.
const PendingFact = struct {
    file: []const u8,
    line: usize,
    vendor: ?[]const u8 = null,
    ext_family: ?u64 = null,
    family_field: ?u64 = null,
    model_min: ?u64 = null,
    model_max: ?u64 = null,
    stepping_min: ?u64 = null,
    stepping_max: ?u64 = null,
    confidence: ?[]const u8 = null,
    source_type: ?[]const u8 = null,
    package_contacts: ?u64 = null,
    stepping_name: ?[]const u8 = null,
    socket_name: ?[]const u8 = null,
    source: ?[]const u8 = null,
    source_url: ?[]const u8 = null,
    notes: ?[]const u8 = null,
};

/// Rekord `[[brand_rule]]` — reguła refinamentu z brand stringu.
const PendingRule = struct {
    file: []const u8,
    line: usize,
    vendor: ?[]const u8 = null,
    ext_family: ?u64 = null,
    family_field: ?u64 = null,
    model_min: ?u64 = null,
    model_max: ?u64 = null,
    confidence: ?[]const u8 = null,
    source_type: ?[]const u8 = null,
    brand_exact: bool = false,
    brand_pattern: ?[]const u8 = null,
    product_name: ?[]const u8 = null,
    variant: ?[]const u8 = null,
    cache_variant: ?[]const u8 = null,
    refined_codename: ?[]const u8 = null,
    source: ?[]const u8 = null,
    source_url: ?[]const u8 = null,
    notes: ?[]const u8 = null,
};

const Parser = struct {
    pending: std.ArrayList(Pending) = .empty,
    facts: std.ArrayList(PendingFact) = .empty,
    rules: std.ArrayList(PendingRule) = .empty,
    errors: usize = 0,
    meta_seen: bool = false,

    fn err(self: *Parser, file: []const u8, line: usize, comptime fmt: []const u8, args: anytype) void {
        fail("{s}:{d}: " ++ fmt, .{ file, line } ++ args);
        self.errors += 1;
    }
};

pub fn main() u8 {
    defer stdout().flush() catch {};
    // Na Windows `std.process.args()` jest celowo niedostępne — używamy
    // wariantu z alokatorem, który działa na wszystkich platformach.
    var args = std.process.ArgIterator.initWithAllocator(allocator) catch {
        fail("nie mogę odczytać argumentów wiersza poleceń", .{});
        return 2;
    };
    defer args.deinit();
    // Pomijamy argv[0] (ścieżkę programu) — inaczej kompilator próbowałby
    // parsować własny plik wykonywalny jako plik TOML.
    _ = args.skip();
    var out_path: ?[]const u8 = null;
    var inputs: std.ArrayList([]const u8) = .empty;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-o")) {
            out_path = args.next() orelse {
                fail("brak ścieżki po -o", .{});
                return 2;
            };
        } else if (std.mem.startsWith(u8, a, "--schema=")) {
            const s = a["--schema=".len..];
            if (!std.mem.eql(u8, s, hwdb.schema_name)) {
                fail("nieznany schemat '{s}' (oczekiwany '{s}')", .{ s, hwdb.schema_name });
                return 2;
            }
        } else {
            inputs.append(allocator, a) catch return 2;
        }
    }

    if (inputs.items.len == 0) {
        fail("brak plików wejściowych", .{});
        return 2;
    }

    var p = Parser{};

    // Teksty plików trzymamy do końca `main`. `Pending` przechowuje slice'y
    // wskazujące **w ich treść**, więc zwolnienie pliku tuż po sparsowaniu
    // powodowałoby użycie po zwolnieniu — walidacja czytałaby śmieci.
    var texts: std.ArrayList([]u8) = .empty;
    defer {
        for (texts.items) |t| allocator.free(t);
        texts.deinit(allocator);
    }

    for (inputs.items) |path| {
        const text = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch |e| {
            fail("nie mogę czytać '{s}': {t}", .{ path, e });
            return 2;
        };
        texts.append(allocator, text) catch {
            fail("brak pamięci na przechowanie treści pliku", .{});
            return 2;
        };
        parseFile(&p, path, text);
    }

    if (p.errors != 0) {
        fail("walidacja nie powiodła się: {d} błędów", .{p.errors});
        return 1;
    }
    if (p.pending.items.len == 0) {
        fail("baza nie zawiera żadnego wpisu", .{});
        return 1;
    }
    validate(p.pending.items) catch |e| {
        fail("walidacja semantyczna: {t}", .{e});
        return 1;
    };
    validateFacts(p.facts.items) catch |e| {
        fail("walidacja faktow: {t}", .{e});
        return 1;
    };
    validateBrandRules(p.rules.items) catch |e| {
        fail("walidacja reguł brand: {t}", .{e});
        return 1;
    };

    const out = out_path orelse {
        fail("wymagany argument -o <ścieżka>", .{});
        return 2;
    };
    const image = buildImage(p.pending.items, p.facts.items, p.rules.items) catch |e| {
        fail("serializacja bazy: {t}", .{e});
        return 1;
    };
    defer allocator.free(image);

    if (std.mem.endsWith(u8, out, ".zig")) {
        writeZig(out, image) catch |e| {
            fail("zapis '{s}': {t}", .{ out, e });
            return 1;
        };
        print("hwdb: {d} wpisów -> {s} ({d} B)\n", .{ p.pending.items.len, out, image.len });
    } else {
        if (std.fs.path.dirname(out)) |dir| std.fs.cwd().makePath(dir) catch {};
        var file = std.fs.cwd().createFile(out, .{ .truncate = true }) catch |e| {
            fail("zapis '{s}': {t}", .{ out, e });
            return 1;
        };
        defer file.close();
        file.writeAll(image) catch |e| {
            fail("zapis '{s}': {t}", .{ out, e });
            return 1;
        };
        print("hwdb: {d} wpisów -> {s} ({d} B)\n", .{ p.pending.items.len, out, image.len });
    }
    return 0;
}

/// Emituje obraz bazy jako **źródło Zig** z tablicą bajtów.
///
/// Dlaczego nie `@embedFile`: build potrzebuje pliku, którego zawartość zależy
/// od wyniku innego kroku. Wygenerowane źródło jest zwykłym modułem, więc nie
/// ma tu żadnej kolejności ani magicznych ścieżek — tylko zwykły import.
fn writeZig(path: []const u8, image: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
    var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();

    // `File` nie ma metody `print` w tej wersji std — piszemy przez writer.
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(&wbuf);
    const w = &fw.interface;

    try w.writeAll(
        \\// Plik wygenerowany przez tools/hwdb_compile.zig — nie edytuj ręcznie.
        \\// Zawiera binarny obraz ferrum-hwdb.bin.
        \\
        \\
    );
    try w.writeAll("pub const bytes = [_]u8{\n");
    for (image, 0..) |b, i| {
        if (i % 16 == 0) try w.writeAll("    ");
        try w.print("0x{X:0>2}, ", .{b});
        if (i % 16 == 15) try w.writeAll("\n");
    }
    try w.writeAll("};\n\n");
    try w.print("pub const image_len = {d};\n", .{image.len});
    // Bez flushu ostatnie kilkaset bajtów zostaje w buforze i wygenerowany
    // plik byłby ucięty — plik bez `};` nie kompiluje się, więc błąd jest
    // widoczny, ale kosztowny do zdiagnozowania.
    try w.flush();
}

/// Serializuje wpisy do binarnego obrazu (nagłówek + pula napisów + wpisy).

fn parseFile(p: *Parser, path: []const u8, text: []const u8) void {
    const base = std.fs.path.basename(path);
    var in_entry = false;
    var saw_meta = false;
    var saw_entry = false;
    var current = Pending{ .file = base, .line = 0 };
    var cur_fact: ?PendingFact = null;
    var cur_rule: ?PendingRule = null;
    const Section = enum { none, entry, fact, rule };
    var sect: Section = .none;

    var it = std.mem.splitScalar(u8, text, '\n');
    var lineno: usize = 0;
    while (it.next()) |raw_line| {
        lineno += 1;
        var line = std.mem.trim(u8, raw_line, " \t\r");
        // komentarze: '#' poza napisem
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOfScalar(u8, line, '"')) |q| {
            // usuń część komentarza za napisem
            if (std.mem.indexOfScalarPos(u8, line, q + 1, '"')) |q2| {
                if (std.mem.indexOfScalarPos(u8, line, q2 + 1, '#')) |h| {
                    line = std.mem.trim(u8, line[0..h], " \t\r");
                }
            }
        }
        if (line.len == 0) continue;

        if (std.mem.eql(u8, line, "[meta]")) {
            saw_meta = true;
            p.meta_seen = true;
            in_entry = false;
            sect = .none;
            continue;
        }
        if (std.mem.eql(u8, line, "[[entry]]")) {
            if (sect == .entry) {
                p.pending.append(allocator, current) catch @panic("OOM");
                saw_entry = true;
            }
            current = Pending{ .file = base, .line = lineno };
            in_entry = true;
            sect = .entry;
            continue;
        }
        if (std.mem.eql(u8, line, "[[fact]]")) {
            if (cur_fact) |f| p.facts.append(allocator, f) catch @panic("OOM");
            cur_fact = PendingFact{ .file = base, .line = lineno };
            in_entry = false;
            sect = .fact;
            continue;
        }
        if (std.mem.eql(u8, line, "[[brand_rule]]")) {
            if (cur_rule) |r| p.rules.append(allocator, r) catch @panic("OOM");
            cur_rule = PendingRule{ .file = base, .line = lineno };
            in_entry = false;
            sect = .rule;
            continue;
        }
        if (line[0] == '[') {
            p.err(base, lineno, "nieznana tabela '{s}' (dozwolone: [meta], [[entry]], [[fact]], [[brand_rule]])", .{line});
            continue;
        }
        if (line[0] == '#') continue;

        // key = value
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            p.err(base, lineno, "oczekiwano 'klucz = wartość', znaleziono '{s}'", .{preview(line)});
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value_text = std.mem.trim(u8, line[eq + 1 ..], " \t\r");

        if (!in_entry) {
            if (saw_meta and std.mem.eql(u8, key, "schema")) {
                const s = tryUnquote(value_text);
                if (s) |v| {
                    if (!std.mem.eql(u8, v, hwdb.schema_name)) {
                        p.err(base, lineno, "nieznany schemat '{s}' (oczekiwany '{s}')", .{ v, hwdb.schema_name });
                    }
                } else |e| p.err(base, lineno, "{s}", .{@errorName(e)});
                continue;
            }
            switch (sect) {
                .fact => {
                    if (cur_fact) |*f| parseFactKey(p, f, key, value_text, lineno);
                    continue;
                },
                .rule => {
                    if (cur_rule) |*r| parseRuleKey(p, r, key, value_text, lineno);
                    continue;
                },
                .none => continue,
                .entry => {},
            }
        }
        parseKey(p, &current, key, value_text, lineno);
    }
    if (sect == .entry) {
        p.pending.append(allocator, current) catch @panic("OOM");
        saw_entry = true;
    }
    if (cur_fact) |f| p.facts.append(allocator, f) catch @panic("OOM");
    if (cur_rule) |r| p.rules.append(allocator, r) catch @panic("OOM");
    if (!saw_meta) p.err(base, lineno, "brak sekcji [meta]", .{});
    if (!saw_entry) p.err(base, lineno, "plik nie zawiera żadnego [[entry]]", .{});
}

/// Klucze `[[fact]]`. Celowo własne parsery zamiast współdzielenia z `[[entry]]`:
/// `Fact` ma inne dozwolone pola, a pomylenie klucza ma być błędem, nie cichym
/// pominięciem.
fn parseFactKey(p: *Parser, f: *PendingFact, key: []const u8, v: []const u8, line: usize) void {
    if (std.mem.eql(u8, key, "vendor")) {
        f.vendor = pfString(p, f.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "stepping_name")) {
        f.stepping_name = pfString(p, f.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "socket_name")) {
        f.socket_name = pfString(p, f.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "source")) {
        f.source = pfString(p, f.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "source_url")) {
        f.source_url = pfString(p, f.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "notes")) {
        f.notes = pfString(p, f.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "confidence")) {
        f.confidence = pfString(p, f.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "source_type")) {
        f.source_type = pfString(p, f.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "package_contacts")) {
        f.package_contacts = pfInt(p, f.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "ext_family")) {
        f.ext_family = pfInt(p, f.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "family_field")) {
        f.family_field = pfInt(p, f.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "model_min")) {
        f.model_min = pfInt(p, f.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "model_max")) {
        f.model_max = pfInt(p, f.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "stepping_min")) {
        f.stepping_min = pfInt(p, f.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "stepping_max")) {
        f.stepping_max = pfInt(p, f.file, key, v, line) orelse return;
    } else {
        p.err(f.file, line, "nieznany klucz '{s}' w [[fact]] (literówka?)", .{key});
    }
}

fn parseRuleKey(p: *Parser, r: *PendingRule, key: []const u8, v: []const u8, line: usize) void {
    if (std.mem.eql(u8, key, "vendor")) {
        r.vendor = pfString(p, r.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "brand_pattern")) {
        r.brand_pattern = pfString(p, r.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "product_name")) {
        r.product_name = pfString(p, r.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "variant")) {
        r.variant = pfString(p, r.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "cache_variant")) {
        r.cache_variant = pfString(p, r.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "refined_codename")) {
        r.refined_codename = pfString(p, r.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "source")) {
        r.source = pfString(p, r.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "source_url")) {
        r.source_url = pfString(p, r.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "notes")) {
        r.notes = pfString(p, r.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "confidence")) {
        r.confidence = pfString(p, r.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "source_type")) {
        r.source_type = pfString(p, r.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "brand_exact")) {
        r.brand_exact = std.mem.eql(u8, v, "true");
    } else if (std.mem.eql(u8, key, "ext_family")) {
        r.ext_family = pfInt(p, r.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "family_field")) {
        r.family_field = pfInt(p, r.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "model_min")) {
        r.model_min = pfInt(p, r.file, key, v, line) orelse return;
    } else if (std.mem.eql(u8, key, "model_max")) {
        r.model_max = pfInt(p, r.file, key, v, line) orelse return;
    } else {
        p.err(r.file, line, "nieznany klucz '{s}' w [[brand_rule]] (literówka?)", .{key});
    }
}

fn pfString(p: *Parser, file: []const u8, key: []const u8, v: []const u8, line: usize) ?[]const u8 {
    const s = tryUnquote(v) catch {
        p.err(file, line, "klucz '{s}' wymaga wartości w cudzysłowie", .{key});
        return null;
    };
    return s;
}

fn pfInt(p: *Parser, file: []const u8, key: []const u8, v: []const u8, line: usize) ?u64 {
    return std.fmt.parseInt(u64, v, 0) catch {
        p.err(file, line, "klucz '{s}' wymaga liczby, znaleziono '{s}'", .{ key, v });
        return null;
    };
}

/// Walidacja faktów. Zasada: `vendor` i `source` są **obowiązkowe**, bo fakt
/// bez źródła to zgadywanie, a `source_type` musi istnieć, żeby odróżnić
/// dokumentację producenta od obserwacji referencyjnej.
fn validateFacts(items: []const PendingFact) !void {
    var seen: std.ArrayList([8]u32) = .empty;
    defer seen.deinit(allocator);
    for (items) |it| {
        const vendor_s = it.vendor orelse {
            fail("{s}:{d}: [[fact]] wymaga pola 'vendor'", .{ it.file, it.line });
            return error.MissingField;
        };
        const vendor = hwdb.VendorId.fromSlice(vendor_s) orelse {
            fail("{s}:{d}: nieznany vendor '{s}'", .{ it.file, it.line, vendor_s });
            return error.UnknownEnum;
        };
        if (vendor == .unknown or vendor == .other) {
            fail("{s}:{d}: [[fact]] musi dotyczyć konkretnego producenta, '{s}' jest za szerokie", .{ it.file, it.line, vendor_s });
            return error.UnknownEnum;
        }
        if (it.source == null or it.source.?.len == 0) {
            fail("{s}:{d}: [[fact]] wymaga pola 'source' (bez pochodzenia to zgadywanie)", .{ it.file, it.line });
            return error.MissingField;
        }
        if (it.source_type) |st| {
            if (hwdb.SourceType.fromSlice(st) == null) {
                fail("{s}:{d}: nieznany source_type '{s}'", .{ it.file, it.line, st });
                return error.UnknownEnum;
            }
        } else {
            fail("{s}:{d}: [[fact]] wymaga pola 'source_type'", .{ it.file, it.line });
            return error.MissingField;
        }
        if (it.confidence) |c| {
            if (hwdb.Confidence.fromSlice(c) == null) {
                fail("{s}:{d}: nieznane confidence '{s}'", .{ it.file, it.line, c });
                return error.UnknownEnum;
            }
        } else {
            fail("{s}:{d}: [[fact]] wymaga pola 'confidence'", .{ it.file, it.line });
            return error.MissingField;
        }
        if (it.stepping_name == null and it.socket_name == null and it.package_contacts == null) {
            fail("{s}:{d}: [[fact]] nie deklaruje żadnego pola (stepping_name/socket_name/package_contacts)", .{ it.file, it.line });
            return error.MissingField;
        }
        if (it.package_contacts) |n| {
            if (n > std.math.maxInt(u16)) {
                fail("{s}:{d}: package_contacts={d} poza zakresem u16", .{ it.file, it.line, n });
                return error.OutOfRange;
            }
        }
        const mmin = it.model_min orelse 0;
        const mmax = it.model_max orelse 0xFF;
        const smin = it.stepping_min orelse 0;
        const smax = it.stepping_max orelse 0xFF;
        if (mmin > mmax or mmin > 0xFF or mmax > 0xFF) {
            fail("{s}:{d}: niespójny zakres modeli {d}..{d}", .{ it.file, it.line, mmin, mmax });
            return error.InvalidRange;
        }
        if (smin > smax or smin > 0xFF or smax > 0xFF) {
            fail("{s}:{d}: niespójny zakres steppingów {d}..{d}", .{ it.file, it.line, smin, smax });
            return error.InvalidRange;
        }
        const key = [8]u32{ @intFromEnum(vendor), @intCast(it.ext_family orelse 0), @intCast(it.family_field orelse 0), @intCast(mmin), @intCast(mmax), @intCast(smin), @intCast(smax), 0 };
        for (seen.items) |prev| {
            if (std.mem.eql(u32, &prev, &key)) {
                fail("{s}:{d}: duplikat — identyczny zakres faktów już zdefiniowany", .{ it.file, it.line });
                return error.DuplicatedEntry;
            }
        }
        seen.append(allocator, key) catch @panic("OOM");
    }
}

/// Walidacja reguł brand. Tu jest **najważniejsza** reguła tego formatu:
/// `vendor` jest obowiązkowy i **nie może** być `unknown`/`other`.
///
/// Gdyby dopuścić regułę bez zakresu, globalny wzorzec typu „X3D” przypisałby
/// wariant procesorowi dowolnego producenta — dokładnie ten błąd, przed którym
/// brief stanowczo nas przestrzega. Reguła brand ma być *danych*, a nie
/// rozpowszechnionym ifem w decoderze.
fn validateBrandRules(items: []const PendingRule) !void {
    var seen: std.ArrayList([8]u32) = .empty;
    defer seen.deinit(allocator);
    for (items) |it| {
        const vendor_s = it.vendor orelse {
            fail("{s}:{d}: [[brand_rule]] wymaga pola 'vendor' (reguła bez zakresu byłaby globalna)", .{ it.file, it.line });
            return error.MissingField;
        };
        const vendor = hwdb.VendorId.fromSlice(vendor_s) orelse {
            fail("{s}:{d}: nieznany vendor '{s}'", .{ it.file, it.line, vendor_s });
            return error.UnknownEnum;
        };
        if (vendor == .unknown or vendor == .other) {
            fail("{s}:{d}: reguła brand musi być ograniczona do konkretnego producenta; '{s}' pozwoliłoby dopasować wzorzec globalnie", .{ it.file, it.line, vendor_s });
            return error.UnknownEnum;
        }
        const pattern = it.brand_pattern orelse {
            fail("{s}:{d}: [[brand_rule]] wymaga pola 'brand_pattern'", .{ it.file, it.line });
            return error.MissingField;
        };
        if (pattern.len == 0) {
            fail("{s}:{d}: brand_pattern nie może być pusty (dopasowałby każdy brand)", .{ it.file, it.line });
            return error.MissingField;
        }
        if (it.product_name == null and it.variant == null and it.cache_variant == null and it.refined_codename == null) {
            fail("{s}:{d}: reguła nie ustawia żadnego pola (product_name/variant/cache_variant/refined_codename)", .{ it.file, it.line });
            return error.MissingField;
        }
        // Zawężanie codename z „Vermeer / Milan-X” do „Vermeer” **wymaga
        // niezależnego źródła**. Obserwacja referencyjna (np. porównanie z CPU-Z)
        // pokazuje nazwę, ale nie mamy dokumentu AMD z granicą 0x2F/0x30 —
        // zawężenie na jej podstawie to zgadywanie podstawione pod pomiar.
        if (it.refined_codename) |rc| {
            if (rc.len == 0) {
                fail("{s}:{d}: refined_codename nie może być pusty (użyj brand_pattern albo usuń klucz)", .{ it.file, it.line });
                return error.MissingField;
            }
            const st = it.source_type.?;
            if (std.mem.eql(u8, st, "reference_observation") or
                std.mem.eql(u8, st, "community") or std.mem.eql(u8, st, "none"))
            {
                fail("{s}:{d}: refined_codename wymaga niezależnego źródła; source_type='{s}' to obserwacja, a zawężanie na niej byłoby zgadywaniem", .{ it.file, it.line, st });
                return error.UnverifiedNarrowing;
            }
        }
        if (it.source == null or it.source.?.len == 0) {
            fail("{s}:{d}: [[brand_rule]] wymaga pola 'source'", .{ it.file, it.line });
            return error.MissingField;
        }
        if (it.source_type) |st| {
            if (hwdb.SourceType.fromSlice(st) == null) {
                fail("{s}:{d}: nieznany source_type '{s}'", .{ it.file, it.line, st });
                return error.UnknownEnum;
            }
        } else {
            fail("{s}:{d}: [[brand_rule]] wymaga pola 'source_type'", .{ it.file, it.line });
            return error.MissingField;
        }
        if (it.confidence) |c| {
            if (hwdb.Confidence.fromSlice(c) == null) {
                fail("{s}:{d}: nieznane confidence '{s}'", .{ it.file, it.line, c });
                return error.UnknownEnum;
            }
        } else {
            fail("{s}:{d}: [[brand_rule]] wymaga pola 'confidence'", .{ it.file, it.line });
            return error.MissingField;
        }
        const mmin = it.model_min orelse 0;
        const mmax = it.model_max orelse 0xFF;
        if (mmin > mmax or mmin > 0xFF or mmax > 0xFF) {
            fail("{s}:{d}: niespójny zakres modeli {d}..{d}", .{ it.file, it.line, mmin, mmax });
            return error.InvalidRange;
        }
        const key = [8]u32{ @intFromEnum(vendor), @intCast(it.ext_family orelse 0), @intCast(it.family_field orelse 0), @intCast(mmin), @intCast(mmax), 0, 0, 0 };
        for (seen.items) |prev| {
            if (std.mem.eql(u32, &prev, &key)) {
                fail("{s}:{d}: duplikat — reguła o tym samym zakresie już zdefiniowana", .{ it.file, it.line });
                return error.DuplicatedEntry;
            }
        }
        seen.append(allocator, key) catch @panic("OOM");
    }
}

fn parseKey(p: *Parser, cur: *Pending, key: []const u8, value_text: []const u8, lineno: usize) void {
    if (std.mem.eql(u8, key, "vendor")) {
        cur.vendor = wantString(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "uarch")) {
        cur.uarch = wantString(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "codename")) {
        cur.codename = wantString(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "revision")) {
        cur.revision = wantString(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "source")) {
        cur.source = wantString(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "source_url")) {
        cur.source_url = wantString(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "confidence")) {
        cur.confidence = wantString(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "family_generic")) {
        cur.family_generic = wantBool(p, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "silicon_family")) {
        cur.silicon_family = wantString(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "product_family")) {
        cur.product_family = wantString(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "variant")) {
        cur.variant = wantString(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "cache_variant")) {
        cur.cache_variant = wantString(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "ext_family")) {
        cur.ext_family = wantInt(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "family_field")) {
        cur.family_field = wantInt(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "model_min")) {
        cur.model_min = wantInt(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "model_max")) {
        cur.model_max = wantInt(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "stepping_min")) {
        cur.stepping_min = wantInt(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "stepping_max")) {
        cur.stepping_max = wantInt(p, cur, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "quirk_no_brand_string")) {
        cur.quirk_no_brand_string = wantBool(p, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "quirk_htt_unreliable")) {
        cur.quirk_htt_unreliable = wantBool(p, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "quirk_cache_leaf_ext")) {
        cur.quirk_cache_leaf_ext = wantBool(p, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "quirk_extended_model_rule")) {
        cur.quirk_extended_model_rule = wantBool(p, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "quirk_hybrid_cores")) {
        cur.quirk_hybrid_cores = wantBool(p, key, value_text, lineno) orelse return;
    } else if (std.mem.eql(u8, key, "quirk_smt_threads")) {
        const v = wantInt(p, cur, key, value_text, lineno) orelse return;
        if (v < 1 or v > 15) {
            p.err(cur.file, lineno, "quirk_smt_threads musi byc w zakresie 1..15, jest {d}", .{v});
            return;
        }
        cur.quirk_smt_threads = @intCast(v);
    } else {
        // Klucz bez walidacji wyglądałby dobrze, ale nic nie robiłby.
        p.err(cur.file, lineno, "nieznany klucz '{s}' w [[entry]] (literówka?)", .{key});
    }
}

/// Skraca fragment w komunikacie błędu. Bez tego próba wczytania pliku
/// binarnego wypisałaby w terminal setki kilobajtów śmieci zamiast diagnozy.
fn preview(s: []const u8) []const u8 {
    const max = 48;
    if (s.len <= max) return s;
    return s[0..max];
}

fn tryUnquote(s: []const u8) ![]const u8 {
    if (s.len < 2 or s[0] != '"') return error.MissingQuotes;
    if (s[s.len - 1] != '"') return error.MissingQuotes;
    return s[1 .. s.len - 1];
}

fn wantString(p: *Parser, cur: *Pending, key: []const u8, v: []const u8, line: usize) ?[]const u8 {
    const s = tryUnquote(v) catch {
        p.err(cur.file, line, "klucz '{s}' wymaga wartości w cudzysłowie", .{key});
        return null;
    };
    return s;
}

fn wantInt(p: *Parser, cur: *Pending, key: []const u8, v: []const u8, line: usize) ?u64 {
    // base 0: obsługuje 0x1A, 26 i ewentualne 0o/0b. `isdigit()` odrzuciłoby
    // 'A' — ten sam błąd, który gubił połowę vendorów w imporcie pci.ids.
    return std.fmt.parseInt(u64, v, 0) catch {
        p.err(cur.file, line, "klucz '{s}' wymaga liczby, znaleziono '{s}'", .{ key, v });
        return null;
    };
}

fn wantBool(p: *Parser, key: []const u8, v: []const u8, line: usize) ?bool {
    if (std.mem.eql(u8, v, "true")) return true;
    if (std.mem.eql(u8, v, "false")) return false;
    p.err("<inline>", line, "klucz '{s}' wymaga true/false, znaleziono '{s}'", .{ key, v });
    return null;
}

const ResolveError = error{
    DuplicatedEntry,
    OverlappingRules,
    InvalidRange,
    UnknownEnum,
    MissingField,
    OutOfRange,
};

/// Walidacja semantyczna. Zwraca `error.X` przy pierwszym problemie i wypisuje
/// wszystkie z nich — chcemy widzieć pełną listę, a nie jeden błąd po poprawkach.
fn validate(items: []const Pending) !void {
    var seen_entries: std.ArrayList([8]u32) = .empty;
    defer seen_entries.deinit(allocator);

    for (items, 0..) |it, idx| {
        const vendor_s = it.vendor orelse {
            report(it, "brak wymaganego pola 'vendor'", .{});
            return error.MissingField;
        };
        const vendor = hwdb.VendorId.fromSlice(vendor_s) orelse {
            report(it, "nieznany vendor '{s}'", .{vendor_s});
            return error.UnknownEnum;
        };
        const conf_s = it.confidence orelse {
            report(it, "brak wymaganego pola 'confidence'", .{});
            return error.MissingField;
        };
        const conf = hwdb.Confidence.fromSlice(conf_s) orelse {
            report(it, "nieznany confidence '{s}' (dozwolone: low, medium, high)", .{conf_s});
            return error.UnknownEnum;
        };
        if (it.uarch == null or it.uarch.?.len == 0) {
            report(it, "brak wymaganego pola 'uarch'", .{});
            return error.MissingField;
        }
        if (it.source == null or it.source.?.len == 0) {
            report(it, "brak wymaganego pola 'source' (provenance jest obowiązkowe)", .{});
            return error.MissingField;
        }
        if (conf != .low) {
            if (it.source_url == null or it.source_url.?.len == 0) {
                report(it, "confidence != low wymaga pola 'source_url'", .{});
                return error.MissingField;
            }
        }

        const ef = it.ext_family orelse 0;
        const ff = it.family_field orelse 0;
        const mmin = it.model_min orelse 0;
        const mmax = it.model_max orelse 0;
        const smin = it.stepping_min orelse 0;
        const smax = it.stepping_max orelse 0xFF;

        if (mmin > mmax) {
            report(it, "błędny zakres modelu: model_min({d}) > model_max({d})", .{ mmin, mmax });
            return error.InvalidRange;
        }
        if (smin > smax) {
            report(it, "błędny zakres stepppingu: stepping_min({d}) > stepping_max({d})", .{ smin, smax });
            return error.InvalidRange;
        }
        if (ef > 0xFF or ff > 0xF or mmax > 0xFF or smax > 0xFF) {
            report(it, "wartość poza zakresem CPUID", .{});
            return error.OutOfRange;
        }
        // Wpis `family_generic` musi faktycznie obejmować całą rodzinę. Bez tego
        // flaga byłaby martwa albo — co gorsza — pozornie działałaby na części
        // zakresu, a matcher i tak nie doszedłby do `family_only`.
        if (it.family_generic and (mmin != 0 or mmax != 0xFF)) {
            report(it, "family_generic wymaga model_min = 0 i model_max = 0xFF (opis całej rodziny), a podano model 0x{x:0>2}-0x{x:0>2}", .{ mmin, mmax });
            return error.InvalidRange;
        }

        const key = [8]u32{ @intFromEnum(vendor), @intCast(ef), @intCast(ff), @intCast(mmin), @intCast(mmax), @intCast(smin), @intCast(smax), @intFromBool(it.family_generic) };
        for (seen_entries.items, 0..) |prev, j| {
            if (std.mem.eql(u32, &prev, &key)) {
                report(items[j], "duplikat — identyczny zakres już zdefiniowany wcześniej", .{});
                report(it, "duplikat powyższego wpisu", .{});
                return error.DuplicatedEntry;
            }
            // Nakładanie: ten sam producent i rodzina, zakresy modelu się przecinają.
            //
            // Wyjątek: wpis `family_generic` ma **najniższy** priorytet, więc nie
            // koliduje z wpisami szczegółowymi — istnieje właśnie po to, by
            // obsłużyć model nieznany. Nakładanie dwóch reguł **równego**
            // priorytetu pozostaje błędem.
            const prev_generic = prev[7] != 0;
            const cur_generic = key[7] != 0;
            if (prev[0] == key[0] and prev[1] == key[1] and prev[2] == key[2] and
                !prev_generic and !cur_generic and
                rangesOverlap(prev[3], prev[4], key[3], key[4]))
            {
                report(items[j], "reguła nakłada się na wpis poniżej (model 0x{x:0>2}-0x{x:0>2})", .{ prev[3], prev[4] });
                report(it, "reguła nakłada się na wpis powyżej (model 0x{x:0>2}-0x{x:0>2})", .{ key[3], key[4] });
                return error.OverlappingRules;
            }
        }
        seen_entries.append(allocator, key) catch @panic("OOM");
        _ = idx;
    }
}

fn rangesOverlap(a_min: u32, a_max: u32, b_min: u32, b_max: u32) bool {
    return a_min <= b_max and b_min <= a_max;
}

fn report(it: Pending, comptime fmt: []const u8, args: anytype) void {
    fail("{s}:{d}: " ++ fmt, .{ it.file, it.line } ++ args);
}

fn buildImage(items: []const Pending, fact_items: []const PendingFact, rule_items: []const PendingRule) ![]u8 {
    var pool: std.ArrayList(u8) = .empty;
    defer pool.deinit(allocator);

    var entries: std.ArrayList(hwdb.Entry) = .empty;
    defer entries.deinit(allocator);

    for (items) |it| {
        var q: hwdb.Quirk = .{};
        q.no_brand_string = it.quirk_no_brand_string;
        q.htt_unreliable = it.quirk_htt_unreliable;
        q.cache_leaf_ext = it.quirk_cache_leaf_ext;
        q.extended_model_rule = it.quirk_extended_model_rule;
        q.hybrid_cores = it.quirk_hybrid_cores;
        q.smt_threads = it.quirk_smt_threads;
        // `validate()` przeszedł już wcześniej, więc te wartości na pewno istnieją.
        // Gdyby nie, wolimy błąd kompilacji bazy niż cichy wpis z zerami.
        const vendor = hwdb.VendorId.fromSlice(it.vendor orelse return error.MissingField) orelse
            return error.UnknownEnum;
        const confidence = hwdb.Confidence.fromSlice(it.confidence orelse return error.MissingField) orelse
            return error.UnknownEnum;
        try entries.append(allocator, .{
            .vendor = vendor,
            .ext_family = @intCast(it.ext_family orelse 0),
            .family_field = @intCast(it.family_field orelse 0),
            .model_min = @intCast(it.model_min orelse 0),
            .model_max = @intCast(it.model_max orelse 0),
            .stepping_min = @intCast(it.stepping_min orelse 0),
            .stepping_max = @intCast(it.stepping_max orelse 0xFF),
            .confidence = confidence,
            .family_generic = it.family_generic,
            .uarch = try intern(&pool, it.uarch orelse ""),
            .codename = try intern(&pool, it.codename orelse ""),
            .revision = try intern(&pool, it.revision orelse ""),
            .source = try intern(&pool, it.source orelse ""),
            .source_url = try intern(&pool, it.source_url orelse ""),
            .silicon_family = try intern(&pool, it.silicon_family orelse ""),
            .product_family = try intern(&pool, it.product_family orelse ""),
            .variant = try intern(&pool, it.variant orelse ""),
            .cache_variant = try intern(&pool, it.cache_variant orelse ""),
            .quirks = @bitCast(q),
        });
    }

    var facts: std.ArrayList(hwdb.Fact) = .empty;
    defer facts.deinit(allocator);

    for (fact_items) |it| {
        const vendor = hwdb.VendorId.fromSlice(it.vendor orelse return error.MissingField) orelse
            return error.UnknownEnum;
        const confidence = hwdb.Confidence.fromSlice(it.confidence orelse return error.MissingField) orelse
            return error.UnknownEnum;
        const source_type = hwdb.SourceType.fromSlice(it.source_type orelse return error.MissingField) orelse
            return error.UnknownEnum;
        try facts.append(allocator, .{
            .vendor = vendor,
            .ext_family = @intCast(it.ext_family orelse 0),
            .family_field = @intCast(it.family_field orelse 0),
            .model_min = @intCast(it.model_min orelse 0),
            .model_max = @intCast(it.model_max orelse 0xFF),
            .stepping_min = @intCast(it.stepping_min orelse 0),
            .stepping_max = @intCast(it.stepping_max orelse 0xFF),
            .confidence = confidence,
            .source_type = source_type,
            .package_contacts = @intCast(it.package_contacts orelse 0),
            .stepping_name = try intern(&pool, it.stepping_name orelse ""),
            .socket_name = try intern(&pool, it.socket_name orelse ""),
            .source = try intern(&pool, it.source orelse ""),
            .source_url = try intern(&pool, it.source_url orelse ""),
            .notes = try intern(&pool, it.notes orelse ""),
        });
    }

    var rules: std.ArrayList(hwdb.BrandRule) = .empty;
    defer rules.deinit(allocator);

    for (rule_items) |it| {
        const vendor = hwdb.VendorId.fromSlice(it.vendor orelse return error.MissingField) orelse
            return error.UnknownEnum;
        const confidence = hwdb.Confidence.fromSlice(it.confidence orelse return error.MissingField) orelse
            return error.UnknownEnum;
        const source_type = hwdb.SourceType.fromSlice(it.source_type orelse return error.MissingField) orelse
            return error.UnknownEnum;
        try rules.append(allocator, .{
            .vendor = vendor,
            .ext_family = @intCast(it.ext_family orelse 0),
            .family_field = @intCast(it.family_field orelse 0),
            .model_min = @intCast(it.model_min orelse 0),
            .model_max = @intCast(it.model_max orelse 0xFF),
            .confidence = confidence,
            .source_type = source_type,
            .exact_match = it.brand_exact,
            .brand_pattern = try intern(&pool, it.brand_pattern orelse ""),
            .product_name = try intern(&pool, it.product_name orelse ""),
            .variant = try intern(&pool, it.variant orelse ""),
            .cache_variant = try intern(&pool, it.cache_variant orelse ""),
            .refined_codename = try intern(&pool, it.refined_codename orelse ""),
            .source = try intern(&pool, it.source orelse ""),
            .source_url = try intern(&pool, it.source_url orelse ""),
            .notes = try intern(&pool, it.notes orelse ""),
        });
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    // Payload = pula napisów + tablica wpisów + fakty + reguły brand. Liczymy przed
    // zapisem nagłówka, bo `payload_len` musi tam trafić, a nagłówek piszemy
    // przed payloadem. Kolejność sekcji musi zgadzać się z `factsStart()` i
    // `brandRulesStart()` w czytniku.
    const payload_len = pool.items.len + entries.items.len * hwdb.entry_size +
        facts.items.len * hwdb.fact_size + rules.items.len * hwdb.brand_rule_size;
    try out.appendNTimes(allocator, 0, hwdb.header_size);
    @memset(out.items, 0);
    @memcpy(out.items[0..8], hwdb.magic);
    putU16(out.items, 8, hwdb.format_version);
    putU16(out.items, 10, hwdb.schema_version);
    // Najstarszy czytnik zdolny poprawnie zinterpretować tę bazę. Równe
    // `format_version`, bo każda zmiana formatu jest dziś zmianą semantyki.
    putU16(out.items, 12, hwdb.minimum_reader_version);
    putU16(out.items, 14, 0);
    putU32(out.items, 16, 1); // db_revision
    putU32(out.items, 20, 0); // built_unix — znacznik, nie źródło prawdy
    // Funkcje, których wymaga ta baza. Czytnik odrzuca plik, jeśli nie zna
    // któregokolwiek z tych bitów — zamiast zgadywać ich znaczenie.
    //
    // Bity sekcji ustawiamy **warunkowo**: flaga ma deklarować, czego baza
    // faktycznie używa. Pusta sekcja nie wymaga żadnej dodatkowej umiejętności
    // od czytnika i nie powinna jej deklarować.
    var feature_bits: u32 = hwdb.FeatureFlags.FAMILY_GENERIC | hwdb.FeatureFlags.SEMANTIC_FIELDS;
    if (facts.items.len > 0) feature_bits |= hwdb.FeatureFlags.IDENTITY_FACTS;
    if (rules.items.len > 0) feature_bits |= hwdb.FeatureFlags.BRAND_RULES;
    putU32(out.items, 24, feature_bits);
    putU32(out.items, 28, @intCast(pool.items.len));
    putU32(out.items, 32, @intCast(entries.items.len));
    // Liczniki nowych sekcji: 72 = fakty, 76 = reguły brand.
    putU32(out.items, 72, @intCast(facts.items.len));
    putU32(out.items, 76, @intCast(rules.items.len));
    // Długość payloadu pozwala wykryć plik ucięty albo dopisany spoza formatu.
    putU32(out.items, 68, @intCast(payload_len));
    try out.appendSlice(allocator, pool.items);
    for (entries.items) |e| {
        var rec: [hwdb.entry_size]u8 = @splat(0);
        rec[0] = @intFromEnum(e.vendor);
        rec[1] = e.ext_family;
        rec[2] = e.family_field;
        rec[3] = e.model_min;
        rec[4] = e.model_max;
        rec[5] = e.stepping_min;
        rec[6] = e.stepping_max;
        rec[7] = @intFromEnum(e.confidence);
        // Flaga `family_generic` siedzi w bajcie 44, po czterech polach
        // semantycznych. W poprzednim układzie (40 bajtów) była w bajcie 28 —
        // stąd bump `format_version`: czytnik v1 czytałby tu bajt 44 spoza rekordu.
        rec[44] = if (e.family_generic) 1 else 0;
        putU16(&rec, 8, e.uarch.off);
        putU16(&rec, 10, e.uarch.len);
        putU16(&rec, 12, e.codename.off);
        putU16(&rec, 14, e.codename.len);
        putU16(&rec, 16, e.revision.off);
        putU16(&rec, 18, e.revision.len);
        putU16(&rec, 20, e.source.off);
        putU16(&rec, 22, e.source.len);
        putU16(&rec, 24, e.source_url.off);
        putU16(&rec, 26, e.source_url.len);
        putU16(&rec, 28, e.silicon_family.off);
        putU16(&rec, 30, e.silicon_family.len);
        putU16(&rec, 32, e.product_family.off);
        putU16(&rec, 34, e.product_family.len);
        putU16(&rec, 36, e.variant.off);
        putU16(&rec, 38, e.variant.len);
        putU16(&rec, 40, e.cache_variant.off);
        putU16(&rec, 42, e.cache_variant.len);
        putU32(&rec, 48, e.quirks);
        try out.appendSlice(allocator, &rec);
    }
    // Sekcja `Fact` — za wpisami, zgodnie z `Hwdb.factsStart()`.
    for (facts.items) |f| {
        var rec: [hwdb.fact_size]u8 = @splat(0);
        rec[0] = @intFromEnum(f.vendor);
        rec[1] = f.ext_family;
        rec[2] = f.family_field;
        rec[3] = f.model_min;
        rec[4] = f.model_max;
        rec[5] = f.stepping_min;
        rec[6] = f.stepping_max;
        rec[7] = @intFromEnum(f.confidence);
        rec[8] = @intFromEnum(f.source_type);
        putU16(&rec, 9, f.package_contacts);
        putU16(&rec, 12, f.stepping_name.off);
        putU16(&rec, 14, f.stepping_name.len);
        putU16(&rec, 16, f.socket_name.off);
        putU16(&rec, 18, f.socket_name.len);
        putU16(&rec, 20, f.source.off);
        putU16(&rec, 22, f.source.len);
        putU16(&rec, 24, f.source_url.off);
        putU16(&rec, 26, f.source_url.len);
        putU16(&rec, 28, f.notes.off);
        putU16(&rec, 30, f.notes.len);
        try out.appendSlice(allocator, &rec);
    }
    // Sekcja `BrandRule` — na końcu payloadu, zgodnie z `Hwdb.brandRulesStart()`.
    for (rules.items) |r| {
        var rec: [hwdb.brand_rule_size]u8 = @splat(0);
        rec[0] = @intFromEnum(r.vendor);
        rec[1] = r.ext_family;
        rec[2] = r.family_field;
        rec[3] = r.model_min;
        rec[4] = r.model_max;
        rec[5] = @intFromEnum(r.confidence);
        rec[6] = @intFromEnum(r.source_type);
        rec[7] = if (r.exact_match) 1 else 0;
        putU16(&rec, 8, r.brand_pattern.off);
        putU16(&rec, 10, r.brand_pattern.len);
        putU16(&rec, 12, r.product_name.off);
        putU16(&rec, 14, r.product_name.len);
        putU16(&rec, 16, r.variant.off);
        putU16(&rec, 18, r.variant.len);
        putU16(&rec, 20, r.cache_variant.off);
        putU16(&rec, 22, r.cache_variant.len);
        putU16(&rec, 24, r.source.off);
        putU16(&rec, 26, r.source.len);
        putU16(&rec, 28, r.source_url.off);
        putU16(&rec, 30, r.source_url.len);
        putU16(&rec, 32, r.notes.off);
        putU16(&rec, 34, r.notes.len);
        putU16(&rec, 36, r.refined_codename.off);
        putU16(&rec, 38, r.refined_codename.len);
        try out.appendSlice(allocator, &rec);
    }
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(out.items[hwdb.header_size..]);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    @memcpy(out.items[36..68], &digest);

    // Przenosimy własność bufora do wywołującego: `out.deinit()` poniżej
    // zwolniłby tylko listę, a zawartość musi żyć do końca użycia.
    const owned = try allocator.dupe(u8, out.items);
    return owned;
}

fn intern(pool: *std.ArrayList(u8), text: []const u8) !hwdb.Str {
    if (text.len == 0) return .{};
    if (pool.items.len + text.len > std.math.maxInt(u16)) return error.StringPoolOverflow;
    const off: u16 = @intCast(pool.items.len);
    try pool.appendSlice(allocator, text);
    return .{ .off = off, .len = @intCast(text.len) };
}

fn putU16(b: []u8, at: usize, v: u16) void {
    b[at] = @truncate(v & 0xFF);
    b[at + 1] = @truncate(v >> 8);
}
fn putU32(b: []u8, at: usize, v: u32) void {
    // `inline for` daje indeks comptime — przesunięcie mieści się w u5,
    // bez ręcznych rzutowań, które przy zwykłym `for` były błędem typu.
    inline for (0..4) |i| b[at + i] = @truncate(v >> (i * 8));
}

// ---------------------------------------------------------------------------
// Walidacja semantyczna: duplikaty, nakładanie zakresów, martwe flagi.
//
// Te testy wymagają własnego pliku TOML. Budują `Pending` ręcznie, bo to ta sama
// struktura, którą wypełnia parser, a dzięki temu sprawdzamy sam walidator, a
// nie to, czy parser czytanie tekstu.
// ---------------------------------------------------------------------------

/// Wpis testowy z minimalnym kompletem pól wymaganych przez `validate()`.
fn testEntry(model_min: u64, model_max: u64, generic: bool) Pending {
    return .{
        .file = "test.toml",
        .line = 1,
        .vendor = "intel",
        .ext_family = 0,
        .family_field = 6,
        .model_min = model_min,
        .model_max = model_max,
        .stepping_min = 0,
        .stepping_max = 0xFF,
        .uarch = "x86-64",
        .source = "test",
        .source_url = "https://example.invalid",
        .confidence = "medium",
        .family_generic = generic,
    };
}

test "walidator: nakładanie się reguł o tym samym priorytecie jest błędem" {
    // Dwa zakresy modelu tej samej rodziny, oba szczegółowe, zakresy przecinają
    // się. Który wygrałby w matcherze? Dopóki autor bazy tego jawnie nie
    // rozstrzygnie, wynik zależałby od kolejności wpisów w pliku — a kolejność
    // wpisów nie jest częścią kontraktu i zmiana jednej linii po cichu
    // przesuwałaby dopasowanie.
    const items = [_]Pending{ testEntry(0x0F, 0x1F, false), testEntry(0x1A, 0x2A, false) };
    try std.testing.expectError(error.OverlappingRules, validate(&items));
}

test "walidator: wpis family_generic współistnieje z wpisami szczegółowymi" {
    // Wpis ogólny ma z definicji zakres `0x00..0xFF`, czyli nakłada się na
    // wszystko w rodzinie. Bez tego wyjątku nie dałoby się w ogóle zarejestrować
    // wpisu ogólnego — a to właśnie on obsługuje model nieznany bazy, i to on
    // jest właściwym odpowiednikiem dawnego, błędnego fallbacku rodzinnego.
    const items = [_]Pending{ testEntry(0x0F, 0x0F, false), testEntry(0x00, 0xFF, true) };
    try validate(&items);
}

test "walidator: family_generic musi obejmować całą rodzinę" {
    // Wąski zakres z flagą `family_generic` to **martwa flaga**: `isFamilyGeneric()`
    // wymaga `0x00..0xFF`, więc `hitLevel` nigdy by takiego wpisu nie użył, a autor
    // bazy myślałby, że opisał całą rodzinę. Lepiej odmówić na kompilacji bazy
    // niż cicho zignorować.
    const items = [_]Pending{testEntry(0x0F, 0x1F, true)};
    try std.testing.expectError(error.InvalidRange, validate(&items));
}
