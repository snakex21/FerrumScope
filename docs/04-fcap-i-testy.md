# FerrumScope — format `.fcap` i strategia testów capture/replay

Status: projekt. Format jest zaprojektowany tak, żeby plik zebrany **dziś** dał wynik
za rok, gdy dodamy kolejny dekoder.

---

## 1. Dlaczego to jest fundament, a nie dodatek

`.fcap` daje trzy rzeczy naraz:

1. **Testowalność bez sprzętu.** CI nie ma Xeon 9 ani Arc A770. Złoty plik ma.
2. **Zgodność wsteczną danych.** Surowe CPUID ze sprzętu z 2026 r. da pełny wynik
   w 2030 r., gdy dekoder się rozwinie.
3. **Wkład społeczności.** Użytkownik, którego nie mamy, wysyła capture zamiast
   logowania do issue.

Koszt: format trzeba zaprojektować od razu. Dlatego jest w planie **Etapu 4**,
a nie „kiedyś”.

---

## 2. Format

```
+------------------------------------------------------+
| Header (64 B)                                        |
+------------------------------------------------------+
| String pool (UTF-8, prefikso-współdzielony)          |
+------------------------------------------------------+
| Section directory (n × { id, offset, len, crc32 })   |
+------------------------------------------------------+
| Sections (surowe dane, BEZ interpretacji)            |
+------------------------------------------------------+
+ Trailer:  content_hash SHA-256 + podpis opcjonalny   |
+------------------------------------------------------+
```

```zig
pub const Header = extern struct {
    magic:  [8]u8,        // "FERFCAP1"
    format: u16,          // 1
    flags:  u32,          // bit0: kompresja, bit1: podpis, bit2: zanonimizowane
    section_count: u32,
    header_crc: u32,
    // Środowisko — kontekst, nie identyfikacja.
    arch: u8,             // x86 | x86_64 | arm64 | ...
    os_tag: u16,          // stała z katalogu, nie wolna tekstowa nazwa
    tool_version: u32,
    captured_unix: u64,   // wskazówka, nie źródło prawdy
    // Prywatność — jawne flagi, nie domyślnie ukryte.
    privacy: PrivacyLevel,// .full .no_pii .anonymized
};
```

### Sekcje (każda niezależna i opcjonalna)

| ID | Sekcja | Zawartość |
|---|---|---|
| 1 | `Cpuid` | wszystkie odczytane liście: `(leaf, subleaf) → eax,ebx,ecx,edx` |
| 2 | `Msr` | tylko allowlista z `docs/02-architektura.md` §9 |
| 3 | `Smbios` | surowe bloki SMBIOS (type, handle, offset, len) |
| 4 | `PciConfig` | `(bus,dev,fn) → config space`, ograniczone do 4 KB na urządzenie |
| 5 | `PciTopology` | szkielet PCI/PCIe:桥 mostów, sloty, link status/width/speed |
| 6 | `Usb` | identyfikatory urządzeń USB (VID/PID/bcdUSB) |
| 7 | `Smbus` | odpowiedzi transakcji SMBus (adres, komenda, bajty) |
| 8 | `Spd` | surowe bajty SPD modułów RAM |
| 9 | `NvmeIdentify` | surowe identify/log pages |
| 10 | `Storage` | model, serial **zredagowany**, firmware, pojemność |
| 11 | `GpuId` | `(location) → vendor/device/rev/subsys`, VBIOS nagłówek, tekst |
| 12 | `GpuRuntime` | punktowa próbka: zegar, pamięć, temp, moc |
| 13 | `OsInfo` | typ OS, wersja, architektura |
| 14 | `Timeouts` | sekcje, które **nie** zwróciły wyniku i dlaczego |

Sekcja 14 jest najważniejsza diagnostycznie: zapisuje, że `spbus` się nie udało,
więc test „decode nie wywołuje brakującej sekcji” ma materiał.

### Prywatność

Domyślnie `privacy = .no_pii` i `ferrumscope capture` **odrzuca**:
numery seryjne dysków, adresy MAC, hostname, nazwy kont, identyfikatory
systemu operacyjnego (ProductId/DigitalProductId), klucze rejestru zawierające ścieżki użytkownika.

Serial dysku jest zapisywany **tylko** przy `--include-serial`, a wtedy w postaci
szyfrowanej/wytrąpionej. Ścieżki systemu plików nigdy nie trafiają do capture'a.

Reguła: **capture ma być przydatny do identyfikacji sprzętu, a nie do identyfikacji
człowieka ani maszyny.**

### Przenośność

- `format` i `schema` pozwalają czytać pliki ze starszych wersji w nieskończoność
  (reader zna stare sekcje, nieznane pomija z ostrzeżeniem).
- Starszy program **nie** odrzuci nowszego pliku całkowicie: weźmie znane sekcje.
- Selektywność: `ferrumscope capture --sections cpuid,msr` zapisuje tylko to,
  co trzeba — małe pliki do issue.

---

## 3. Replay jako backend

```zig
// replay/backend.zig
pub const ReplayBackend = struct {
    /// Zwraca CPUID dokładnie tak, jak platforma zwróciłaby w dniu capture.
    pub fn cpuid(self: ReplayBackend, leaf: u32, subleaf: u32) Status([4]u32);
    pub fn read_msr(self: ReplayBackend, msr: u32) Status(u64);
    pub fn pci_config(self: ReplayBackend, loc: PciLocation) Status([4096]u8);
    // ... interfejs jest identyczny z platform.Backend
};
```

To jedyny punkt, w którym potrzebujemy jednego interfejsu dla dwóch światów.
Dekodery, normalizacja i baza **nie wiedzą**, czy dane pochodzą z żywego sprzętu,
czy z pliku. To gwarantuje, że testy regresyjne testują dokładnie tę ścieżkę kodu
co program produkcyjny.

---

## 4. Plan testów

### Warstwa 1 — dekodery bez I/O (CI, milisekundy)
Ręcznie skonstruowane obrazy CPUID dla znanych sygnatur (w tym przypadki brzegowe:
`ext_family`/`ext_model`, stepping 0, CPU o `family=0xF` z rozszerzeniami).
Sprawdzamy: dobór wzorca, jakość dopasowania, generowanie nazwy, poprawność `Status`.

### Warstwa 2 — złote pliki `.fcap` (CI)
`db/fixtures/cpu/*.fcap` + `db/fixtures/golden.toml`:

```toml
[[case]]
file = "zen4_5950x.fcap"
expect_name = "AMD Ryzen 9 5950X"
expect_codename = "Vermeer"
expect_cores = 16
expect_threads = 32
expect_match = "exact"
```

Test porównuje **cały** znormalizowany model, nie tylko nazwę — dzięki temu
zmiana w dekoderze, która psuje pole, też łamie test.

### Warstwa 3 — testy bazy
- złota tabela SKU → nazwa (patrz `docs/03-hwdb.md`),
- test „nieznany sprzęt daje fallback, nie `null`",
- test „duplikat w źródle jest wykryty, nie po cichu nadpisany".

### Warstwa 4 — regresja formatu (CI)
Złoty plik `.fcap` zapisany w formacie 1. Test: `capture → replay` zachowuje
bajt w bajt surowe sekcje i daje identyczny model po miesiącu zmian w dekoderze.

### Warstwa 5 — testy platformowe (nightly, nie w PR)
Linux/macOS/Windows na prawdziwym sprzęcie: przechodzimy ścieżkę `platform`,
której CI nie ma. Wymagane dla `platform/*` i dla sterownika.

### Złote pliki: skąd je brać, skoro nie masz całego sprzętu
To jest **ta sama** luka, którą zgłosiłeś przy bazach. Rozwiązanie:
1. **Publiczny rejestr PCI ID** — daje identyfikatory (`pci.ids` → 9915 urządzeń,
   gotowe). Nie daje jednak surowych danych do odtworzenia, więc to materiał
   na `[[chip]]`/`[[board]]`, nie na `.fcap`.
2. **Dokumentacja producentów** — parametry techniczne do `db/source/cpu/*.toml`.
3. **Społeczność** — `ferrumscope capture` + `ferrumscope hwdb add` z odpowiednim
   `source_url`; pull request przechodzi przez walidację, więc śmieci nie wejdą.
4. **Oracle porównawczy** — CPU-Z/GPU-Z używamy w `tools/refext/` **wyłącznie**
   do weryfikacji („czy zgadzamy się z interpretacją?"), nigdy jako źródła danych.

---

## 5. Zasada nadrzędna testów

> Test sprawdza **kontrakt i fallback**, nie implementację.
> „Znamy 4 rzeczy, których nie umiemy" jest wartością tego formatu,
> a nie brakiem — to jest dokładnie ta przewaga nad podejściem,
> które wymaga znajomości każdego SKU na świecie.
