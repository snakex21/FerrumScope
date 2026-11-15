//! Układ „widoku uporządkowanego” GUI — wyłącznie dane (bez Win32).
//!
//! Każde pole formularza wskazuje pole strony raportu (`sys/report.zig`) po
//! identyfikatorze strony, sekcji i etykiecie. Okno nie liczy niczego samo:
//! widok uporządkowany i „Pełna lista” pokazują te same `Field` z tego samego
//! modelu — różni je tylko układ.
//!
//! Sekcja zaczynająca się od `@` to sekcja **instancji** (moduł pamięci, karta
//! graficzna, dysk): `@GPU: ` znaczy „n-ta sekcja z prefiksem `GPU: `”, gdzie
//! n wybiera lista rozwijana zakładki.
//!
//! Inspiracją jest wyłącznie *układ* znany z narzędzi typu CPU-Z/GPU-Z
//! (zakładki, ramki grup, pola etykieta → wartość). Żadnych grafik, ikon ani
//! tekstów z tych programów.

pub const Cell = struct {
    /// Etykieta w oknie (krótka).
    label: []const u8,
    /// Sekcja strony: dokładny prefiks tytułu albo `@prefiks` (instancja).
    sect: []const u8,
    /// Etykieta pola w stronie raportu.
    field: []const u8,
    /// Zapasowa etykieta pola, gdy pierwszej brak.
    alt: []const u8 = "",
    /// Wysokość pola w wierszach tekstu (lista instrukcji: 3).
    lines: u8 = 1,
    /// Szerokość etykiety (px przy 96 DPI); 0 = domyślna grupy / komórki.
    label_w: i32 = 0,
    /// Przycisk obok pola: otwiera pierwszy odnośnik strony, którego etykieta
    /// zaczyna się od `button_link` (i pasuje do bieżącej instancji).
    button: []const u8 = "",
    button_link: []const u8 = "",
};

pub const Row = []const Cell;

pub const Group = struct {
    title: []const u8,
    rows: []const Row,
    label_w: i32 = 92,
    /// Udział w szerokości pasa (grupy obok siebie).
    weight: u8 = 1,
};

pub const Band = []const Group;

pub const Selector = struct {
    label: []const u8,
    /// Prefiks sekcji instancji na stronie (`GPU: `, `Dysk `, `Gniazdo `).
    prefix: []const u8,
};

pub const Kind = enum { form, sensors, bench, about };

pub const Tab = struct {
    id: []const u8,
    title: []const u8,
    page: []const u8,
    kind: Kind = .form,
    selector: ?Selector = null,
    bands: []const Band = &.{},
    /// Filtr sekcji w trybie „Pełna lista” (pusty = wszystkie).
    list_sections: []const u8 = "",
    /// Plakietka / logo w prawym górnym rogu (obok pierwszego pasa grup).
    badge: ?BadgeKind = null,
};

pub const BadgeKind = enum { cpu, gpu };

// ---------------------------------------------------------------------------

const P = "Procesor";
const Z = "Zegary";
const C = "Pamięć podręczna";

pub const tabs = [_]Tab{
    .{
        .id = "cpu",
        .title = "CPU",
        .page = "cpu",
        .badge = .cpu,
        .bands = &.{
            &.{.{ .title = "Procesor", .rows = &.{
                &.{.{ .label = "Nazwa", .sect = P, .field = "Nazwa", .button = "Wyszukaj", .button_link = "Szukaj CPU" }},
                &.{ .{ .label = "Nazwa kodowa", .sect = P, .field = "Nazwa kodowa" }, .{ .label = "Rewizja", .sect = P, .field = "Rewizja", .label_w = 56 } },
                &.{ .{ .label = "Gniazdo", .sect = P, .field = "Gniazdo" }, .{ .label = "Technologia", .sect = P, .field = "Technologia", .label_w = 72 } },
                &.{.{ .label = "Specyfikacja", .sect = P, .field = "Brand string" }},
                &.{ .{ .label = "Rodzina", .sect = P, .field = "Rodzina" }, .{ .label = "Model", .sect = P, .field = "Model", .label_w = 42 }, .{ .label = "Stepping", .sect = P, .field = "Stepping", .label_w = 56 } },
                &.{ .{ .label = "Rodzina rozsz.", .sect = P, .field = "Rodzina rozsz." }, .{ .label = "Model rozsz.", .sect = P, .field = "Model rozsz.", .label_w = 76 } },
                &.{.{ .label = "Architektura", .sect = P, .field = "Mikroarchitektura" }},
                &.{.{ .label = "Instrukcje", .sect = "Zestaw instrukcji", .field = "Instrukcje", .lines = 4 }},
            } }},
            &.{
                .{ .title = "Zegary (rdzeń, średnio)", .label_w = 96, .rows = &.{
                    &.{.{ .label = "Zegar rdzeni", .sect = Z, .field = "Zegar rdzeni (średnio)" }},
                    &.{.{ .label = "Mnożnik", .sect = Z, .field = "Mnożnik" }},
                    &.{.{ .label = "Zegar magistrali", .sect = Z, .field = "Zegar magistrali" }},
                    &.{.{ .label = "Zegar bazowy", .sect = Z, .field = "Zegar bazowy" }},
                    &.{.{ .label = "Obciążenie", .sect = "Obciążenie", .field = "Całkowite" }},
                } },
                .{ .title = "Pamięć podręczna", .label_w = 60, .rows = &.{
                    &.{.{ .label = "L1 Dane", .sect = C, .field = "L1 Data" }},
                    &.{.{ .label = "L1 Instr.", .sect = C, .field = "L1 Instruction" }},
                    &.{.{ .label = "L2", .sect = C, .field = "L2" }},
                    &.{.{ .label = "L3", .sect = C, .field = "L3" }},
                } },
            },
            &.{.{ .title = "Topologia", .label_w = 56, .rows = &.{
                &.{ .{ .label = "Rdzenie", .sect = "Topologia", .field = "Rdzenie" }, .{ .label = "Wątki", .sect = "Topologia", .field = "Wątki", .label_w = 44 }, .{ .label = "SMT", .sect = "Topologia", .field = "SMT", .label_w = 36 } },
            } }},
        },
    },
    .{
        .id = "caches",
        .title = "Cache",
        .page = "cpu",
        .list_sections = C,
        .bands = &.{
            &.{.{ .title = "L1 — dane", .rows = &.{
                &.{.{ .label = "Rozmiar", .sect = C, .field = "L1 Data" }},
                &.{.{ .label = "Opis", .sect = C, .field = "L1 Data — opis" }},
            } }},
            &.{.{ .title = "L1 — instrukcje", .rows = &.{
                &.{.{ .label = "Rozmiar", .sect = C, .field = "L1 Instruction" }},
                &.{.{ .label = "Opis", .sect = C, .field = "L1 Instruction — opis" }},
            } }},
            &.{.{ .title = "L2", .rows = &.{
                &.{.{ .label = "Rozmiar", .sect = C, .field = "L2" }},
                &.{.{ .label = "Opis", .sect = C, .field = "L2 — opis" }},
            } }},
            &.{.{ .title = "L3", .rows = &.{
                &.{.{ .label = "Rozmiar", .sect = C, .field = "L3" }},
                &.{.{ .label = "Opis", .sect = C, .field = "L3 — opis" }},
            } }},
        },
    },
    .{
        .id = "board",
        .title = "Płyta główna",
        .page = "board",
        .bands = &.{
            &.{.{ .title = "Płyta główna", .rows = &.{
                &.{.{ .label = "Producent", .sect = "Płyta główna", .field = "Producent" }},
                &.{ .{ .label = "Model", .sect = "Płyta główna", .field = "Model" }, .{ .label = "Rewizja", .sect = "Płyta główna", .field = "Rewizja", .label_w = 56 } },
                &.{.{ .label = "Numer seryjny", .sect = "Płyta główna", .field = "Numer seryjny" }},
                &.{.{ .label = "Gniazdo CPU", .sect = "Gniazdo procesora", .field = "Gniazdo" }},
            } }},
            &.{.{ .title = "Chipset", .rows = &.{
                &.{.{ .label = "Chipset", .sect = "Chipset", .field = "Chipset", .button = "Sterowniki", .button_link = "Sterowniki chipsetu" }},
                &.{.{ .label = "Mostek hosta", .sect = "Chipset", .field = "Mostek hosta" }},
                &.{.{ .label = "Mostek LPC", .sect = "Chipset", .field = "Mostek LPC / ISA" }},
                &.{.{ .label = "SMBus", .sect = "Chipset", .field = "Kontroler SMBus" }},
            } }},
            &.{.{ .title = "BIOS", .rows = &.{
                &.{.{ .label = "Producent", .sect = "BIOS", .field = "Producent" }},
                &.{ .{ .label = "Wersja", .sect = "BIOS", .field = "Wersja" }, .{ .label = "Data", .sect = "BIOS", .field = "Data", .label_w = 40 } },
                &.{ .{ .label = "Rozmiar ROM", .sect = "BIOS", .field = "Rozmiar ROM" }, .{ .label = "Wydanie", .sect = "BIOS", .field = "Wydanie BIOS", .label_w = 56 } },
            } }},
        },
    },
    .{
        .id = "memory",
        .title = "Pamięć",
        .page = "memory",
        .selector = .{ .label = "Gniazdo", .prefix = "Gniazdo " },
        .bands = &.{
            &.{.{ .title = "Ogólne", .rows = &.{
                &.{ .{ .label = "Typ", .sect = "Podsumowanie", .field = "Typ" }, .{ .label = "Rozmiar", .sect = "Podsumowanie", .field = "Rozmiar całkowity", .label_w = 56 } },
                &.{ .{ .label = "Kanały", .sect = "Podsumowanie", .field = "Kanały" }, .{ .label = "Gniazda", .sect = "Podsumowanie", .field = "Gniazda", .label_w = 56 } },
                &.{ .{ .label = "Prędkość", .sect = "Podsumowanie", .field = "Prędkość" }, .{ .label = "Zegar DRAM", .sect = "Podsumowanie", .field = "Częstotliwość DRAM", .label_w = 72 } },
                &.{.{ .label = "Timingi", .sect = "Podsumowanie", .field = "Timingi (SPD)" }},
            } }},
            &.{.{ .title = "Moduł (wybrane gniazdo)", .rows = &.{
                &.{ .{ .label = "Bank", .sect = "@Gniazdo ", .field = "Bank" }, .{ .label = "Rozmiar", .sect = "@Gniazdo ", .field = "Rozmiar", .alt = "Moduł", .label_w = 56 } },
                &.{ .{ .label = "Typ", .sect = "@Gniazdo ", .field = "Typ" }, .{ .label = "Format", .sect = "@Gniazdo ", .field = "Format", .label_w = 56 } },
                &.{ .{ .label = "Prędkość maks.", .sect = "@Gniazdo ", .field = "Prędkość maks." }, .{ .label = "Ustawiona", .sect = "@Gniazdo ", .field = "Prędkość skonfigurowana", .label_w = 64 } },
                &.{.{ .label = "Producent", .sect = "@Gniazdo ", .field = "Producent" }},
                &.{.{ .label = "Part number", .sect = "@Gniazdo ", .field = "Part number" }},
                &.{.{ .label = "Numer seryjny", .sect = "@Gniazdo ", .field = "Numer seryjny" }},
                &.{ .{ .label = "Ranki", .sect = "@Gniazdo ", .field = "Ranki" }, .{ .label = "Napięcie", .sect = "@Gniazdo ", .field = "Napięcie", .label_w = 56 } },
            } }},
        },
    },
    .{
        .id = "graphics",
        .title = "Grafika",
        .page = "graphics",
        .badge = .gpu,
        .selector = .{ .label = "Karta", .prefix = "GPU: " },
        .bands = &.{
            &.{.{ .title = "GPU", .rows = &.{
                &.{.{ .label = "Nazwa", .sect = "@GPU: ", .field = "Nazwa (sterownik)", .button = "Wyszukaj", .button_link = "Szukaj karty" }},
                &.{.{ .label = "Układ", .sect = "@GPU: ", .field = "Układ GPU" }},
                &.{.{ .label = "Karta", .sect = "@GPU: ", .field = "Karta", .alt = "Producent karty" }},
                &.{ .{ .label = "ID urządzenia", .sect = "@GPU: ", .field = "Identyfikator" }, .{ .label = "Subsystem", .sect = "@GPU: ", .field = "Subsystem", .label_w = 64 } },
                &.{ .{ .label = "Rewizja", .sect = "@GPU: ", .field = "Rewizja" }, .{ .label = "Adres PCI", .sect = "@GPU: ", .field = "Lokalizacja PCI", .label_w = 64 } },
                &.{.{ .label = "Magistrala", .sect = "@GPU: ", .field = "Łącze PCIe" }},
            } }},
            &.{
                .{ .title = "Pamięć", .label_w = 96, .rows = &.{
                    &.{.{ .label = "Dedykowana", .sect = "@GPU: ", .field = "Pamięć dedykowana" }},
                    &.{.{ .label = "Współdzielona", .sect = "@GPU: ", .field = "Pamięć współdzielona" }},
                    &.{.{ .label = "Typ", .sect = "@Czujniki GPU: ", .field = "Typ pamięci" }},
                } },
                .{ .title = "Zegary i czujniki", .label_w = 84, .rows = &.{
                    &.{.{ .label = "Zegar GPU", .sect = "@Czujniki GPU: ", .field = "Zegar GPU" }},
                    &.{.{ .label = "Zegar pamięci", .sect = "@Czujniki GPU: ", .field = "Zegar pamięci" }},
                    &.{.{ .label = "Temperatura", .sect = "@Czujniki GPU: ", .field = "Temperatura GPU" }},
                } },
            },
            &.{
                .{ .title = "Obciążenie", .label_w = 80, .rows = &.{
                    &.{.{ .label = "Obciążenie", .sect = "@Czujniki GPU: ", .field = "Obciążenie GPU" }},
                    &.{.{ .label = "Wentylator", .sect = "@Czujniki GPU: ", .field = "Wentylator" }},
                    &.{.{ .label = "Pobór mocy", .sect = "@Czujniki GPU: ", .field = "Pobór mocy" }},
                } },
                .{ .title = "Sterownik", .label_w = 84, .rows = &.{
                    &.{.{ .label = "Wersja", .sect = "@GPU: ", .field = "Sterownik" }},
                    &.{.{ .label = "Data", .sect = "@GPU: ", .field = "Data sterownika" }},
                    &.{.{ .label = "Dostawca", .sect = "@GPU: ", .field = "Dostawca sterownika", .button = "Pobierz", .button_link = "Sterowniki" }},
                } },
            },
        },
    },
    .{
        .id = "storage",
        .title = "Dyski",
        .page = "storage",
        .selector = .{ .label = "Dysk", .prefix = "Dysk " },
        .bands = &.{
            &.{.{ .title = "Urządzenie", .rows = &.{
                &.{.{ .label = "Model", .sect = "@Dysk ", .field = "Model" }},
                &.{ .{ .label = "Firmware", .sect = "@Dysk ", .field = "Firmware" }, .{ .label = "Magistrala", .sect = "@Dysk ", .field = "Magistrala", .label_w = 68 } },
                &.{ .{ .label = "Pojemność", .sect = "@Dysk ", .field = "Pojemność" }, .{ .label = "Rodzaj", .sect = "@Dysk ", .field = "Rodzaj", .label_w = 68 } },
                &.{.{ .label = "Numer seryjny", .sect = "@Dysk ", .field = "Numer seryjny" }},
            } }},
            &.{.{ .title = "Zdrowie (SMART / NVMe)", .rows = &.{
                &.{.{ .label = "Stan", .sect = "@Dysk ", .field = "Stan zdrowia" }},
                &.{ .{ .label = "Temperatura", .sect = "@Dysk ", .field = "Temperatura" }, .{ .label = "Zużycie", .sect = "@Dysk ", .field = "Zużycie", .label_w = 68 } },
                &.{ .{ .label = "Czas pracy", .sect = "@Dysk ", .field = "Czas pracy" }, .{ .label = "Uruchomień", .sect = "@Dysk ", .field = "Liczba uruchomień", .label_w = 68 } },
                &.{ .{ .label = "Zapisano", .sect = "@Dysk ", .field = "Zapisano" }, .{ .label = "Odczytano", .sect = "@Dysk ", .field = "Odczytano", .label_w = 68 } },
                &.{ .{ .label = "Realokowane", .sect = "@Dysk ", .field = "Realokowane sektory" }, .{ .label = "Oczekujące", .sect = "@Dysk ", .field = "Sektory oczekujące", .label_w = 68 } },
                &.{ .{ .label = "Nienaprawialne", .sect = "@Dysk ", .field = "Nienaprawialne" }, .{ .label = "Błędy nośnika", .sect = "@Dysk ", .field = "Błędy nośnika", .label_w = 84 } },
            } }},
        },
    },
    .{ .id = "sensors", .title = "Czujniki", .page = "sensors", .kind = .sensors },
    .{ .id = "bench", .title = "Bench", .page = "", .kind = .bench },
    .{ .id = "about", .title = "O programie", .page = "", .kind = .about },
};

pub fn tabIndex(id: []const u8) ?usize {
    for (tabs, 0..) |t, i| {
        if (eql(t.id, id)) return i;
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

test "forms: identyfikatory zakładek są unikalne, a komórki mają etykiety" {
    const std = @import("std");
    for (tabs, 0..) |t, i| {
        for (tabs[i + 1 ..]) |u| try std.testing.expect(!eql(t.id, u.id));
        for (t.bands) |band| for (band) |g| for (g.rows) |r| {
            try std.testing.expect(r.len >= 1 and r.len <= 3);
            for (r) |c| try std.testing.expect(c.label.len > 0 and c.field.len > 0);
        };
    }
    try std.testing.expectEqual(@as(?usize, 0), tabIndex("cpu"));
}

// ---------------------------------------------------------------------------
// Wiązanie komórek z polami raportu (wspólne dla GUI i testów)
// ---------------------------------------------------------------------------

const report = @import("../sys/report.zig");

pub fn findPage(pages: []const report.Page, id: []const u8) ?*const report.Page {
    for (pages) |*p| if (eql(p.id, id)) return p;
    return null;
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and eql(s[0..prefix.len], prefix);
}

/// Liczba sekcji instancji (np. modułów pamięci) na stronie.
pub fn instanceCount(p: *const report.Page, prefix: []const u8) usize {
    var n: usize = 0;
    for (p.sections.items) |s| {
        if (startsWith(s.title, prefix)) n += 1;
    }
    return n;
}

/// Tytuł n-tej sekcji instancji bez prefiksu (do listy rozwijanej).
pub fn instanceName(p: *const report.Page, prefix: []const u8, index: usize) ?[]const u8 {
    var n: usize = 0;
    for (p.sections.items) |s| {
        if (!startsWith(s.title, prefix)) continue;
        if (n == index) return s.title[prefix.len..];
        n += 1;
    }
    return null;
}

fn section(p: *const report.Page, sect: []const u8, index: usize) ?*const report.Section {
    if (sect.len > 0 and sect[0] == '@') {
        const prefix = sect[1..];
        var n: usize = 0;
        for (p.sections.items) |*s| {
            if (!startsWith(s.title, prefix)) continue;
            if (n == index) return s;
            n += 1;
        }
        return null;
    }
    for (p.sections.items) |*s| {
        if (startsWith(s.title, sect)) return s;
    }
    return null;
}

/// Pole raportu dla komórki formularza; `null` = strona nie ma takiego pola.
pub fn resolve(p: *const report.Page, c: Cell, index: usize) ?*const report.Field {
    const s = section(p, c.sect, index) orelse return null;
    for (s.fields.items) |*f| if (eql(f.label, c.field)) return f;
    if (c.alt.len > 0) {
        for (s.fields.items) |*f| if (eql(f.label, c.alt)) return f;
    }
    return null;
}

/// Pierwszy odnośnik strony o etykiecie zaczynającej się od `prefix`,
/// pasujący do instancji `scope` (pusty scope odnośnika = cała strona).
pub fn findLink(p: *const report.Page, prefix: []const u8, scope: []const u8) ?*const report.Link {
    for (p.links.items) |*l| {
        if (!startsWith(l.label, prefix)) continue;
        if (l.scope.len > 0 and scope.len > 0 and !eql(l.scope, scope)) continue;
        return l;
    }
    return null;
}
