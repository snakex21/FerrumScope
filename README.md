# FerrumScope — repozytorium

Szybkie, modularne, wieloplatformowe narzędzie do **identyfikacji, diagnostyki,
monitorowania i testowania sprzętu**. Rdzeń w Zig, ten sam model danych i ta sama
hardware database na Windows / Linux / macOS (Intel i Apple Silicon), z planem
Windows ARM64, Linux ARM64 i modułu diagnostycznego USOS.

**Status: fundamenty projektowe.** Implementacja świadomie nie jest jeszcze robiona —
najpierw ustaliliśmy architekturę, formaty danych i strategię testów.

## Dokumenty

| Dokument | Zawartość |
|---|---|
| [`docs/01-analiza-referencji.md`](docs/01-analiza-referencji.md) | Co faktycznie robią CPU-Z i GPU-Z: co czytają ze sprzętu, co biorą z systemu, co z baz, jak rozwiązują family/model/stepping i identyfikację GPU |
| [`docs/02-architektura.md`](docs/02-architektura.md) | Layout repo, `RawCpuInfo` / `RawGpuInfo` / `CpuInfo` / `GpuInfo`, model capability, skanowanie wielofazowe, podział backendów, plan v1 (CPU-only) |
| [`docs/03-hwdb.md`](docs/03-hwdb.md) | Format źródłowy TOML, format `ferrum-hwdb.bin`, wersjonowanie, walidacja, duplikaty, provenance |
| [`docs/04-fcap-i-testy.md`](docs/04-fcap-i-testy.md) | Format capture/replay i plan testów regresyjnych |
| [`reference/README.md`](reference/README.md) | Kwarantanna referencji i zasady źródeł danych |

## Zasady projektowe

1. **Surowe dane oddzielone od interpretacji.** `Raw*` zapisuje wszystko, co da się
   odczytać, także to, czego dziś nie umiemy zinterpretować. `*Info` to wynik dekodera
   i bazy. GUI nigdy nie pyta sprzętu bezpośrednio.
2. **Baza to dane, nie kod.** Format źródłowy TOML, czytelny dla człowieka;
   osobny kompilator waliduje i generuje `ferrum-hwdb.bin`. Wersja programu ma
   wbudowany snapshot, a nowsza baza może być dołożona z zewnątrz.
3. **Provenance obowiązkowe.** Każdy wpis wie, skąd pochodzi. Dane z zastrzeżonych
   baz (CPU-Z, GPU-Z) **nie wchodzą** do produktu — patrz `reference/README.md`.
4. **Platforma deklaruje możliwości, nie wiedzę.** Zamiast `if Windows` rozsiane po
   rdzeniu: backend raportuje `Capabilities`, probe deklaruje wymagania, brak
   możliwości to `Status.unsupported`, a nie awaria programu.
5. **Nieznany sprzęt to nie błąd.** Dekoder zawsze zwraca nazwę — z bazy albo wygenerowaną
   — wraz z jakością dopasowania (`exact` / `pattern` / `unknown`).
6. **Capture/replay jako fundament testów.** `.fcap` pozwala testować dekodery bez
   sprzętu i zachowuje surowe dane na lata.

## Pierwsza wersja (v1) — CPU-only

`ferrumscope` (CLI) z poprawną identyfikacją CPU na Windows / Linux / macOS,
szybkim startem, działającym `ferrumscope explain cpu`, `capture` i `replay`.
Bez GUI, bez benchmarków, bez stress testów — celowo.

## Narzędzia deweloperskie

```sh
# Legalny import publicznego rejestru PCI ID (BSD-like, z atrybucją)
python tools/hwdb/pciids_import.py
python tools/hwdb/pciids_import.py --check     # walidacja bez pobierania

# Analiza referencyjnych binariów (kwarantanna — nigdy nie trafia do produktu)
bash tools/refext/fetch_tools.sh               # pobiera UPX (GPL) do analizy
python tools/refext/pe_scan.py scan "do referencji/cpuz/cpuz_x64.exe"
python tools/refext/harvest_ref.py --all
```

Stan importu PCI: **858 vendorów, 9915 urządzeń, 0 błędów**, rewizja `2026-09-25`.

## Licencja

Do ustalenia przed pierwszym release. Dane źródłowe zachowują własne licencje —
PCI ID Repository wymaga atrybucji, `hwdata` (odrzucone) jest GPL-2.0+.
