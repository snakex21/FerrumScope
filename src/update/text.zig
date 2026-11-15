//! Teksty aktualizatora widoczne dla użytkownika (CLI i GUI).
//!
//! Wszystkie w jednym miejscu, jako zwykłe literały bez znaczników formatu:
//! kod skleja je z wartościami (wersja, notatki) w miejscu użycia. Dzięki temu
//! całą strukturę da się później przenieść do katalogu i18n bez zmiany logiki.

pub const Text = struct {
    // --- wspólne --------------------------------------------------------------
    current_version: []const u8 = "Bieżąca wersja:   ",
    latest_version: []const u8 = "Najnowsza wersja:  ",
    notes_header: []const u8 = "Zmiany:",
    no_releases: []const u8 = "Brak opublikowanych wydań — nie ma czego aktualizować.",
    up_to_date: []const u8 = "Masz najnowszą wersję.",
    update_available: []const u8 = "Dostępna jest nowsza wersja.",
    check_failed: []const u8 = "Nie udało się sprawdzić aktualizacji: ",
    apply_failed: []const u8 = "Aktualizacja nie powiodła się (przywrócono poprzednie pliki): ",
    prepare_failed: []const u8 = "Pobieranie lub weryfikacja aktualizacji nie powiodła się (nic nie zmieniono): ",
    applied: []const u8 = "Zaktualizowano do wersji ",
    backup_hint: []const u8 = "Poprzednia wersja została zachowana jako *.old (cofnięcie: ferrumscope update --rollback).",
    restart_gui_hint: []const u8 = "Jeśli okno FerrumScope jest otwarte, uruchom je ponownie.",
    downloading: []const u8 = "Pobieranie i weryfikacja (SHA-256)…",
    rollback_done: []const u8 = "Przywrócono poprzednią wersję plików: ",
    rollback_none: []const u8 = "Brak kopii zapasowej (*.old) — nie ma czego przywracać.",
    rollback_failed: []const u8 = "Nie udało się przywrócić poprzedniej wersji: ",
    auto_on: []const u8 = "Sprawdzanie aktualizacji przy starcie: włączone.",
    auto_off: []const u8 = "Sprawdzanie aktualizacji przy starcie: wyłączone.",
    settings_failed: []const u8 = "Nie udało się zapisać data\\settings.ini: ",
    prompt_install: []const u8 = "Zainstalować aktualizację? [y/N] ",
    cancelled: []const u8 = "Anulowano.",
    channel_label: []const u8 = "Kanał aktualizacji: ",
    channel_stable: []const u8 = "stabilny",
    channel_test: []const u8 = "testowy",
    channel_set: []const u8 = "Ustawiono kanał aktualizacji: ",

    // --- CLI ------------------------------------------------------------------
    cli_usage: []const u8 =
        \\Użycie:
        \\  ferrumscope update --check [--channel=stable|test]
        \\                                       sprawdź, czy jest nowsza wersja
        \\                                       (kod wyjścia: 0 aktualna, 10 dostępna, 1 błąd)
        \\  ferrumscope update --apply [--yes] [--channel=stable|test]
        \\                                       pobierz, zweryfikuj i zainstaluj
        \\  ferrumscope update --rollback        przywróć poprzednią wersję (*.old)
        \\  ferrumscope update --set-auto on|off sprawdzanie przy starcie GUI
        \\  ferrumscope update --set-channel stable|test
        \\                                       kanał: stabilny (tylko wydania) albo testowy
        \\                                       (także wersje pre-release); --channel zmienia
        \\                                       kanał tylko dla jednego uruchomienia
        \\
    ,
    cli_bad_option: []const u8 = "ferrumscope update: nieznana lub brakująca opcja: ",

    // --- GUI ------------------------------------------------------------------
    gui_group: []const u8 = "Aktualizacje",
    gui_check_button: []const u8 = "Sprawdź aktualizacje…",
    gui_auto_checkbox: []const u8 = "Sprawdzaj przy starcie",
    gui_channel_checkbox: []const u8 = "Kanał testowy (wersje próbne)",
    gui_info: []const u8 = "Źródło: wydania GitHub snakex21/FerrumScope. Pobrany plik jest sprawdzany sumą SHA-256 " ++
        "(manifest i SHA256SUMS), a poprzednia wersja zostaje jako kopia *.old. Katalog data\\ nie jest zmieniany.",
    gui_title: []const u8 = "FerrumScope — aktualizacja",
    gui_ask_install: []const u8 = "Zainstalować teraz? Program uruchomi się ponownie.",
    gui_checking: []const u8 = "Sprawdzanie…",
    gui_updated: []const u8 = "FerrumScope został zaktualizowany do wersji ",
    gui_restart_failed: []const u8 = "Pliki zaktualizowano, ale nie udało się uruchomić nowej wersji. Uruchom FerrumScope ręcznie.",
};

pub const t: Text = .{};
