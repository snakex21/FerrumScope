**Języki:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#kompilacja)

Otwarte, przejrzyste narzędzie do informacji o sprzęcie dla Windows — „CPU-Z + GPU-Z w jednym”, napisane w Zig. Każda wartość pokazuje, **skąd pochodzi** (liść CPUID, offset SMBIOS, baza PCI ID, bajt logu NVMe, biblioteka producenta…) i **jak bardzo** program jest jej **pewien**. Główne funkcje nie wymagają sterownika, brak telemetrii.

![Zakładka CPU w FerrumScope](../docs/screenshots/cpu.png)

## Spis treści

- [Funkcje](#funkcje)
- [Zrzuty ekranu](#zrzuty-ekranu)
- [Język interfejsu](#język-interfejsu)
- [Co wymaga sterownika lub uprawnień administratora](#co-wymaga-sterownika-lub-uprawnień-administratora)
- [Kompilacja](#kompilacja)
- [GUI](#gui)
- [Wiersz poleceń](#wiersz-poleceń)
- [Linki wyszukiwania](#linki-wyszukiwania)
- [Aktualizacje](#aktualizacje)
- [Capture i replay](#capture-i-replay)
- [Model bezpieczeństwa](#model-bezpieczeństwa)
- [Źródła danych i licencje](#źródła-danych-i-licencje)

## Funkcje

- **CPU** — identyfikacja z CPUID oraz baza sprzętu ze śledzonym pochodzeniem danych (nazwa kodowa, mikroarchitektura, rewizja, gniazdo), family/model/stepping, pełna lista zestawów instrukcji (MMX … AVX-512, AES, SHA, VT-x/AMD-V) z liściem i bitem CPUID każdego z nich, wyliczony poziom x86-64, pamięć podręczna w postaci `8 x 32 KB`, topologia oraz **bez sterownika** szacowanie taktowania z obciążeniem każdego rdzenia i całkowitym.
- **Płyta główna** — producent, model, rewizja i BIOS (SMBIOS typy 0/1/2/3/4), chipset ustalony na podstawie PCI ID oraz każde urządzenie PCI nazwane według wbudowanego `pci.ids`.
- **Pamięć** — moduły z SMBIOS typ 17 (gniazdo, pojemność, DDR4/DDR5, prędkość i prędkość skonfigurowana, producent, numer części, rank, napięcie), łączna pojemność oraz wyraźnie oznaczona heurystyka kanałów.
- **Grafika** — DXGI i SetupAPI: nazwy, identyfikatory vendor/device/subsystem/revision, nazwa karty z `pci.ids`, wersja i data sterownika, pamięć dedykowana i współdzielona, łącze PCIe. Taktowania, temperatury, wentylator, obciążenie i pobór mocy pochodzą z **AMD ADL** lub **NVIDIA NVAPI**, ładowanych w czasie działania, tylko do odczytu i opcjonalnych.
- **Dyski** — model, firmware, magistrala, pojemność i numer seryjny (maskowany). Log zdrowia NVMe bez uprawnień administratora, SATA SMART jako administrator: temperatura, godziny pracy, zużycie i jawnie podana reguła oceny stanu.
- **Czujniki** — obciążenie i taktowanie CPU, czujniki GPU, temperatury dysków. Czujniki CPU oparte na MSR przez opcjonalny sterownik; wentylatory płyty głównej są wymienione jako *wymaga sterownika (planowane)*.
- **Eksport raportu** — TXT, HTML i JSON. Numery seryjne i UUID są **domyślnie maskowane**.
- **Dwa widoki** — kompaktowy widok w stylu CPU-Z (domyślny) i pełna lista ze źródłem i pewnością każdego pola (`Ctrl+L`).
- **27 języków interfejsu**, **aktualizator** z kanałem stabilnym i testowym, przyciski **wyszukiwania** w bazie TechPowerUp i na stronach sterowników producentów.

## Zrzuty ekranu

| CPU | Grafika |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Grafika](../docs/screenshots/graphics.png) |

| Płyta główna | Pamięć |
|---|---|
| ![Płyta główna](../docs/screenshots/board.png) | ![Pamięć](../docs/screenshots/memory.png) |

| Dyski (administrator, SATA SMART) | Widok pełnej listy |
|---|---|
| ![Dyski](../docs/screenshots/admin_storage.png) | ![Pełna lista](../docs/screenshots/list_board.png) |

Wszystkie zakładki i oba widoki: [docs/screenshots](../docs/screenshots).

## Język interfejsu

GUI, wiersz poleceń oraz raporty TXT/HTML są dostępne w 27 językach: polskim (źródłowym), angielskim, bułgarskim, czeskim, duńskim, niemieckim, greckim, hiszpańskim, estońskim, fińskim, francuskim, chorwackim, węgierskim, włoskim, litewskim, łotewskim, norweskim (bokmål), niderlandzkim, portugalskim (Brazylia), rumuńskim, rosyjskim, słowackim, słoweńskim, serbskim (alfabet łaciński), szwedzkim, tureckim i ukraińskim.

Język jest wybierany w tej kolejności: zapisane ustawienie (`data\settings.ini`), język wyświetlania Windows, a na końcu angielski. Zmienisz go w GUI (wybór języka) albo poleceniem `ferrumscope lang <code>` / `--lang=<code>`. Wartości techniczne (nazwy instrukcji, jednostki, PCI ID) nigdy nie są tłumaczone, a klucze eksportu JSON pozostają po angielsku. Dla tłumaczy: zobacz [locales/README.md](../locales/README.md).

## Co wymaga sterownika lub uprawnień administratora

| Dane | Wymaganie |
|---|---|
| CPU, płyta główna, pamięć, grafika, stan NVMe, deskryptory dysków | nic (zwykły użytkownik) |
| SATA SMART | uruchomienie jako administrator; bez tego program to zgłasza i działa dalej |
| APERF/MPERF, temperatury z MSR | sterownik `FerrumScopeMsr.sys` — **nie jest instalowany automatycznie** |
| Wentylatory/napięcia płyty głównej (Super I/O), timingi SPD (SMBus) | sterownik jądra — **planowany, niezaimplementowany** |

## Kompilacja

Potrzebny jest tylko przypięty Zig 0.15.2.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` kompiluje i uruchamia GUI. Opcjonalny sterownik kompiluje się osobno za pomocą WDK (`driver/build_driver.bat`) i nigdy nie jest instalowany przez proces kompilacji.

## GUI

- Zakładki: CPU, Pamięć podręczna, Płyta główna, Pamięć, Grafika, Dyski, Czujniki, Bench (zarezerwowana), O programie.
- Najedź na wartość, aby zobaczyć jej źródło, pewność i surową wartość. **Pokaż źródła** dodaje mały znacznik obok każdego pola.
- **Pełna lista** (`Ctrl+L`) pokazuje każde pole wraz ze źródłem; wybór jest zapamiętywany. `F5` odświeża dane statyczne (SMBIOS, PCI, dyski).
- **Odznaka/logo** na zakładkach CPU i Grafika. Priorytet: własny obraz → dołączone logo producenta → odznaka rysowana przez FerrumScope. Własne pliki PNG umieść obok programu w `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (np. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (np. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Nazwy są pisane małymi literami, a każdy znak niebędący literą ani cyfrą jest zastępowany przez `-`. Kliknięcie odznaki otwiera link wyszukiwania.
- Opcje wiersza poleceń: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Wiersz poleceń

```sh
ferrumscope cpu [--json|--raw|--explain]
ferrumscope board | memory | gpu | storage | sensors-all
ferrumscope report --format=html -o report.html           # txt | html | json
ferrumscope report --format=json --include-serials        # serial numbers only on request
ferrumscope report --sys-replay db/fixtures/sys/asrock_b550_5800x3d_rx7900xtx.sysimg \
                   --cpu-replay db/fixtures/amd_ryzen7_5800x3d_native.cpuimg
ferrumscope capture cpu.cpuimg                            # raw CPUID
ferrumscope capture-sys system.sysimg [--include-serials] # raw SMBIOS/PCI/GPU/disks
ferrumscope update --check [--channel=stable|test]
ferrumscope lang [<code>]
ferrumscope sensors                                       # MSR telemetry (needs the driver)
```

## Linki wyszukiwania

Przyciski **Wyszukaj** i odznaka otwierają bazę GPU/CPU TechPowerUp. Jeśli dokładna strona jest znana, używana jest ona, w tej kolejności:

1. link przypięty przez Ciebie — skopiuj adres strony w przeglądarce i kliknij **Przypnij…** obok pola (zapisywany w `data\links.toml`);
2. kuratorowana tabela [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — wpisy są dodawane ręcznie (`source = "manual"`), nigdy przez crawling; pull requesty mile widziane;
3. w przeciwnym razie wyszukiwanie po nazwie.

Zapisywane są wyłącznie linki; nic nie jest pobierane z TechPowerUp. Akceptowane adresy: `https://` w domenie techpowerup.com lub na stronie producenta.

## Aktualizacje

FerrumScope sprawdza wydania `snakex21/FerrumScope` na GitHubie przez HTTPS — najwyżej raz dziennie przy starcie (można to wyłączyć) albo na żądanie w **O programie → Sprawdź aktualizacje** / `ferrumscope update --check`. Aktualizacja jest instalowana dopiero wtedy, gdy pobrany plik zip zgadza się **zarówno** z SHA-256 w `ferrumscope-update.json`, jak i z `SHA256SUMS`; poprzedni plik exe jest zachowywany jako `.old` (`ferrumscope update --rollback`), a folder `data\` (ustawienia, przypięte linki, Twoje obrazy) nigdy nie jest ruszany. Kanały: **stable** (domyślny) i **test** (wersje przedpremierowe). Żadna telemetria nie jest wysyłana.

## Capture i replay

`.cpuimg` przechowuje surowe liście CPUID; `.sysimg` przechowuje surowe dane SMBIOS, PCI ID, adaptery DXGI oraz deskryptory dysków i strony NVMe/SMART. Oba są plikami tekstowymi i przechodzą przez **te same dekodery** co dane na żywo, dzięki czemu parsery są testowane bez sprzętu. `capture-sys` domyślnie maskuje numery seryjne i UUID SMBIOS (offsety pozostają poprawne). Format: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Model bezpieczeństwa

- GUI i CLI działają jako zwykły użytkownik; nic nie jest instalowane.
- Opcjonalny sterownik `FerrumScopeMsr.sys` działa **tylko do odczytu**: trzy IOCTL, **lista dozwolonych** MSR (APERF/MPERF), każde żądanie walidowane w jądrze, dostęp do urządzenia ograniczony do SYSTEM i Administratorów (`IoCreateDeviceSecure`), brak jakiejkolwiek ścieżki zapisu. Nie był jeszcze ładowany na prawdziwym systemie. Szczegóły: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Do dysków wysyłane są wyłącznie polecenia odczytu (IOCTL zapytań o nośnik, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Biblioteki GPU producentów są ładowane wyłącznie z System32 i używane są tylko funkcje odpytujące.
- Numery seryjne są maskowane w GUI, raportach i plikach capture, chyba że wyraźnie o nie poprosisz.

## Źródła danych i licencje

- Kod źródłowy FerrumScope: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **lub** BSD-3-Clause.
- Baza procesorów (`db/source/cpu/*.toml`): każdy wpis podaje swoje źródło (revision guides AMD, zakresy modeli z jądra Linux, publiczne zrzuty CPUID). Żadnych danych z CPU-Z ani GPU-Z — zobacz [reference/README.md](../reference/README.md).
- `assets/logos/` **nie** jest objęty licencją GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA i GeForce są znakami towarowymi ich odpowiednich właścicieli; loga są używane wyłącznie do identyfikacji sprzętu i nie oznaczają żadnego poparcia. Pochodzenie każdego pliku: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- Linki TechPowerUp to zwykłe linki otwierane przez Ciebie; żadne dane TechPowerUp nie są pobierane ani przechowywane.
