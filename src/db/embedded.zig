//! Dostęp do wbudowanego snapshotu hardware database.
//!
//! Plik `ferrum-hwdb.bin` jest **osadzony w binarnym programie** w trakcie
//! builda (build.zig uruchamia `hwdb-compile`, a `@embedFile` w module
//! `hwdb_embedded` wciąga wynik). Dzięki temu:
//!
//!   * program działa w pełni offline, bez żadnych plików obok,
//!   * runtime **nie parsuje** TOML — tylko bajty (patrz `docs/03-hwdb.md`),
//!   * niespójna baza psuje build, a nie pierwsze uruchomienie.
//!
//! Opcjonalnie można wczytać nowszą bazę z dysku — patrz `db/hwdb.zig` i
//! `loadExternal`. Zasada: wbudowany snapshot wygrywa, chyba że plik zewnętrzny
//! ma wyższy `db_revision` i użytkownik nie zablokował go jawnie.

const std = @import("std");
const hwdb = @import("hwdb.zig");

const embedded = @import("hwdb_embedded");

/// Bajty wbudowanej bazy — ważne przez cały czas życia programu.
/// Bajty wbudowanej bazy — ważne przez cały czas życia programu.
/// `&` jest konieczne: wygenerowany moduł deklaruje tablicę `[_]u8{...}`,
/// a tutaj potrzebujemy slice'a.
pub const bytes: []const u8 = &embedded.bytes;

/// Otwiera bazę wbudowaną. Weryfikuje nagłówek i sumę kontrolną, więc
/// uszkodzony build failuje przy starcie, a nie po dziwnym wyniku.
pub fn load() !hwdb.Hwdb {
    return hwdb.Hwdb.init(bytes);
}

/// Ścieżki sprawdzane przez CLI przy szukaniu zewnętrznej bazy, w kolejności
/// rosnącego priorytetu. Zwracana jest pierwsza istniejąca i poprawna.
pub const external_search_paths = [_][]const u8{
    "ferrum-hwdb.bin", // obok programu / w katalogu roboczym
};

/// Próbuje wczytać zewnętrzną bazę. Zwraca `null`, gdy nic nie znaleziono lub
/// plik jest niepoprawny — to sytuacja tolerowana, nie błąd programu.
pub fn loadExternal(allocator: std.mem.Allocator, builtin: hwdb.Hwdb) !?hwdb.Hwdb {
    for (external_search_paths) |p| {
        const data = std.fs.cwd().readFileAlloc(allocator, p, 64 * 1024 * 1024) catch continue;
        defer allocator.free(data);
        const db = hwdb.Hwdb.init(data) catch continue;
        // Zasada: wbudowany snapshot wygrywa przy remisie. Zewnętrzna baza
        // musi być świeższa, inaczej użytkownik straciłby naprawę.
        if (db.db_revision < builtin.db_revision) continue;
        return db;
    }
    return null;
}

const testing = std.testing;

test "embedded: wbudowana baza jest spójna i niepusta" {
    const db = try load();
    try testing.expect(db.count() > 0);
    try testing.expectEqual(@as(u32, hwdb.format_version), hwdb.format_version);
    try testing.expect(!db.isNewerSchema());
}

test "embedded: baza zawiera wpisy Intel i AMD" {
    const db = try load();
    var intel = false;
    var amd = false;
    var i: usize = 0;
    while (i < db.count()) : (i += 1) {
        const e = db.entryAt(i).?;
        if (e.vendor == .intel) intel = true;
        if (e.vendor == .amd) amd = true;
    }
    try testing.expect(intel);
    try testing.expect(amd);
}
