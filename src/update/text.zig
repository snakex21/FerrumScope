//! Teksty aktualizatora widoczne dla użytkownika (CLI i GUI).
//!
//! Wszystkie w jednym miejscu. Pola z wartościami są szablonami z parametrami
//! nazwanymi (`{version}`, `{err}`, `{channel}`, `{option}`, `{count}`), które
//! wypełnia `write`/`fill`. `get()` zwraca teksty w bieżącym języku (katalog
//! i18n, identyfikator = tekst polski) — wołać w miejscu użycia, nie na
//! poziomie kontenera, bo tłumaczenie działa w czasie wykonania.

const std = @import("std");
const i18n = @import("../i18n/i18n.zig");

pub const Text = struct {
    // --- wspólne --------------------------------------------------------------
    current_version: []const u8,
    latest_version: []const u8,
    notes_header: []const u8,
    no_releases: []const u8,
    up_to_date: []const u8,
    update_available: []const u8,
    check_failed: []const u8,
    apply_failed: []const u8,
    prepare_failed: []const u8,
    applied: []const u8,
    backup_hint: []const u8,
    restart_gui_hint: []const u8,
    downloading: []const u8,
    rollback_done: []const u8,
    rollback_none: []const u8,
    rollback_failed: []const u8,
    auto_on: []const u8,
    auto_off: []const u8,
    settings_failed: []const u8,
    prompt_install: []const u8,
    cancelled: []const u8,
    channel_label: []const u8,
    channel_stable: []const u8,
    channel_test: []const u8,
    channel_set: []const u8,

    // --- CLI ------------------------------------------------------------------
    cli_usage: []const u8,
    cli_bad_option: []const u8,

    // --- GUI ------------------------------------------------------------------
    gui_group: []const u8,
    gui_check_button: []const u8,
    gui_auto_checkbox: []const u8,
    gui_channel_checkbox: []const u8,
    gui_info: []const u8,
    gui_title: []const u8,
    gui_ask_install: []const u8,
    gui_checking: []const u8,
    gui_updated: []const u8,
    gui_restart_failed: []const u8,
};

/// Teksty w bieżącym języku. Wynik ważny do następnego `i18n.setLocale`.
pub fn get() Text {
    return .{
        .current_version = i18n.t("Bieżąca wersja:   {version}"),
        .latest_version = i18n.t("Najnowsza wersja:  {version}"),
        .notes_header = i18n.t("Zmiany:"),
        .no_releases = i18n.t("Brak opublikowanych wydań — nie ma czego aktualizować."),
        .up_to_date = i18n.t("Masz najnowszą wersję."),
        .update_available = i18n.t("Dostępna jest nowsza wersja."),
        .check_failed = i18n.t("Nie udało się sprawdzić aktualizacji: {err}"),
        .apply_failed = i18n.t("Aktualizacja nie powiodła się (przywrócono poprzednie pliki): {err}"),
        .prepare_failed = i18n.t("Pobieranie lub weryfikacja aktualizacji nie powiodła się (nic nie zmieniono): {err}"),
        .applied = i18n.t("Zaktualizowano do wersji {version}."),
        .backup_hint = i18n.t("Poprzednia wersja została zachowana jako *.old (cofnięcie: ferrumscope update --rollback)."),
        .restart_gui_hint = i18n.t("Jeśli okno FerrumScope jest otwarte, uruchom je ponownie."),
        .downloading = i18n.t("Pobieranie i weryfikacja (SHA-256)…"),
        .rollback_done = i18n.t("Przywrócono poprzednią wersję plików: {count}"),
        .rollback_none = i18n.t("Brak kopii zapasowej (*.old) — nie ma czego przywracać."),
        .rollback_failed = i18n.t("Nie udało się przywrócić poprzedniej wersji: {err}"),
        .auto_on = i18n.t("Sprawdzanie aktualizacji przy starcie: włączone."),
        .auto_off = i18n.t("Sprawdzanie aktualizacji przy starcie: wyłączone."),
        .settings_failed = i18n.t("Nie udało się zapisać data\\settings.ini: {err}"),
        .prompt_install = i18n.t("Zainstalować aktualizację? [y/N] "),
        .cancelled = i18n.t("Anulowano."),
        .channel_label = i18n.t("Kanał aktualizacji: {channel}"),
        .channel_stable = i18n.t("stabilny"),
        .channel_test = i18n.t("testowy"),
        .channel_set = i18n.t("Ustawiono kanał aktualizacji: {channel}"),

        .cli_usage = i18n.t("Użycie:\n  ferrumscope update --check [--channel=stable|test]\n                                       sprawdź, czy jest nowsza wersja\n                                       (kod wyjścia: 0 aktualna, 10 dostępna, 1 błąd)\n  ferrumscope update --apply [--yes] [--channel=stable|test]\n                                       pobierz, zweryfikuj i zainstaluj\n  ferrumscope update --rollback        przywróć poprzednią wersję (*.old)\n  ferrumscope update --set-auto on|off sprawdzanie przy starcie GUI\n  ferrumscope update --set-channel stable|test\n                                       kanał: stabilny (tylko wydania) albo testowy\n                                       (także wersje pre-release); --channel zmienia\n                                       kanał tylko dla jednego uruchomienia\n"),
        .cli_bad_option = i18n.t("ferrumscope update: nieznana lub brakująca opcja: {option}"),

        .gui_group = i18n.t("Aktualizacje"),
        .gui_check_button = i18n.t("Sprawdź aktualizacje…"),
        .gui_auto_checkbox = i18n.t("Sprawdzaj przy starcie"),
        .gui_channel_checkbox = i18n.t("Kanał testowy (wersje próbne)"),
        .gui_info = i18n.t("Źródło: wydania GitHub snakex21/FerrumScope. Pobrany plik jest sprawdzany sumą SHA-256 (manifest i SHA256SUMS), a poprzednia wersja zostaje jako kopia *.old. Katalog data\\ nie jest zmieniany."),
        .gui_title = i18n.t("FerrumScope — aktualizacja"),
        .gui_ask_install = i18n.t("Zainstalować teraz? Program uruchomi się ponownie."),
        .gui_checking = i18n.t("Sprawdzanie…"),
        .gui_updated = i18n.t("FerrumScope został zaktualizowany do wersji {version}."),
        .gui_restart_failed = i18n.t("Pliki zaktualizowano, ale nie udało się uruchomić nowej wersji. Uruchom FerrumScope ręcznie."),
    };
}

/// Wypisuje szablon z `Text` z podstawionymi parametrami nazwanymi
/// (liczby całkowite jako `{d}`, reszta jako `{s}`); bez alokacji.
/// Nieznany `{x}` zostaje bez zmian.
pub fn write(out: *std.Io.Writer, template: []const u8, args: anytype) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < template.len) {
        const end_opt = if (template[i] == '{') std.mem.indexOfScalarPos(u8, template, i, '}') else null;
        if (end_opt) |end| {
            const name = template[i + 1 .. end];
            var done = false;
            inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |f| {
                if (!done and std.mem.eql(u8, f.name, name)) {
                    const v = @field(args, f.name);
                    switch (@typeInfo(@TypeOf(v))) {
                        .int, .comptime_int => try out.print("{d}", .{v}),
                        else => try out.print("{s}", .{v}),
                    }
                    done = true;
                }
            }
            if (done) {
                i = end + 1;
                continue;
            }
        }
        try out.writeByte(template[i]);
        i += 1;
    }
}

/// Jak `write`, ale do bufora; zbyt długi wynik jest obcinany.
pub fn fill(buf: []u8, template: []const u8, args: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    write(&w, template, args) catch {};
    return w.buffered();
}

test "text: szablony bez katalogu dają dotychczasowy tekst polski" {
    const t = get();
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("Bieżąca wersja:   1.2.3", fill(&buf, t.current_version, .{ .version = "1.2.3" }));
    try std.testing.expectEqualStrings("Przywrócono poprzednią wersję plików: 4", fill(&buf, t.rollback_done, .{ .count = @as(usize, 4) }));
    try std.testing.expectEqualStrings("Nie udało się zapisać data\\settings.ini: AccessDenied", fill(&buf, t.settings_failed, .{ .err = "AccessDenied" }));
    try std.testing.expectEqualStrings("Bieżąca", fill(buf[0..9], t.current_version, .{ .version = "x" }));
    try std.testing.expect(std.mem.startsWith(u8, t.cli_usage, "Użycie:\n  ferrumscope update --check"));
    try std.testing.expect(std.mem.endsWith(u8, t.cli_usage, "uruchomienia\n"));
}
