# FerrumScope

Open, transparent hardware information tool for Windows — "CPU-Z + GPU-Z in one", written in Zig. Every value shows **where it came from** (CPUID leaf, SMBIOS offset, PCI ID database, NVMe log byte, vendor library…) and **how confident** the program is about it.

| CPU | Graphics |
|---|---|
| ![CPU tab](docs/screenshots/cpu.png) | ![Graphics tab](docs/screenshots/graphics.png) |

| Mainboard | Memory |
|---|---|
| ![Mainboard tab](docs/screenshots/board.png) | ![Memory tab](docs/screenshots/memory.png) |

| Storage (administrator: SATA SMART) | Full list view |
|---|---|
| ![Storage tab](docs/screenshots/admin_storage.png) | ![Full list view](docs/screenshots/list_board.png) |

More screenshots: [docs/screenshots](docs/screenshots) (all tabs, both views).

<a id="languages"></a>

## Languages / Języki

- [🇬🇧 English](#en)
- [🇵🇱 Polski](#pl)

---

<a id="en"></a>

## 🇬🇧 English

### Table of contents

- [Features](#en-features)
- [What needs a driver or admin rights](#en-limits)
- [Build](#en-build)
- [GUI](#en-gui)
- [CLI usage](#en-cli)
- [Capture and replay](#en-capture)
- [Security model](#en-security)
- [Data sources and licenses](#en-licenses)

<a id="en-features"></a>

### Features

- **CPU** — identification from CPUID plus a provenance-tracked hardware database (codename, microarchitecture, revision, socket), family/model/stepping, full instruction-set list (MMX … AVX-512, AES, SHA, VT-x/AMD-V) with the CPUID leaf/bit for each, derived x86-64 level, caches shown as `8 x 32 KB`, topology, **driverless** clock estimate and per-core/total load.
- **Mainboard** — vendor, model, revision, BIOS vendor/version/date (SMBIOS types 0/1/2/3/4), chipset derived from PCI IDs, full PCI device list named from the built-in `pci.ids`.
- **Memory** — modules from SMBIOS type 17: slot, size, DDR4/DDR5…, speed and configured speed, manufacturer, part number, rank, voltage; total size and a clearly labelled channel heuristic.
- **Graphics** — DXGI + SetupAPI: names, vendor/device/subsystem/revision IDs, board name from `pci.ids`, driver version/date, dedicated/shared memory, PCIe link. Clocks, temperatures, fan, load and power through **AMD ADL** or **NVIDIA NVAPI**, loaded at runtime, read-only and optional.
- **Storage** — model, firmware, bus, size, serial (masked); NVMe health log (no admin needed) and SATA SMART (admin) with temperature, power-on hours, wear and a stated health rule.
- **Sensors** — CPU load/clock, GPU sensors, disk temperatures; MSR-based CPU sensors through the optional driver; motherboard fans are listed as *requires driver (planned)*.
- **Lookup** buttons (TechPowerUp GPU/CPU database search) and vendor driver pages — links only, nothing is fetched or embedded.
- **Report export** — TXT, HTML and JSON. Serial numbers and UUIDs are **masked by default**.
- Two GUI views: a compact **structured view** (default) and a **full list** with the source/confidence of every field (`Ctrl+L`).

<a id="en-limits"></a>

### What needs a driver or admin rights

| Data | Requirement |
|---|---|
| CPU, mainboard, memory, graphics, NVMe health, disk descriptors | nothing (regular user) |
| SATA SMART | run as administrator; without it the program says so and keeps working |
| APERF/MPERF, temperatures from MSR | `FerrumScopeMsr.sys` driver — **not installed automatically**, not signed for production |
| Motherboard fans/voltages (Super I/O), SPD timings (SMBus) | kernel driver — **planned, not implemented** |

<a id="en-build"></a>

### Build

Requires only the pinned Zig 0.15.2 (no Visual Studio needed for the program itself).

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` builds and starts the GUI. The optional driver is built separately with the WDK (`driver/build_driver.bat`) and is never installed by the build.

<a id="en-gui"></a>

### GUI

- Tabs: CPU, Cache, Mainboard, Memory, Graphics, Storage, Sensors, Bench (placeholder), About.
- Hover a value to see its source, confidence and raw value. **Show sources** adds a small confidence marker (W high · Ś medium · N low · ~ estimate · Z firmware placeholder · A needs admin · S needs driver).
- **Full list** (`Ctrl+L`) shows every field of the page with its source; the choice is remembered. `F5` refreshes static data (SMBIOS, PCI, disks).
- **Badge/logo** on the CPU and Graphics tabs. Priority: your own image → bundled logo → a badge drawn by FerrumScope. Put your own PNGs next to the program in `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (e.g. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (e.g. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Names are lowercase with non-alphanumerics replaced by `-`. Clicking the badge opens the lookup link.
- Command line: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`.

<a id="en-cli"></a>

### CLI usage

```sh
ferrumscope cpu [--json|--raw|--explain]
ferrumscope board | memory | gpu | storage | sensors-all
ferrumscope report --format=html -o report.html           # txt | html | json
ferrumscope report --format=json --include-serials        # serials shown only on request
ferrumscope report --sys-replay db/fixtures/sys/asrock_b550_5800x3d_rx7900xtx.sysimg \
                   --cpu-replay db/fixtures/amd_ryzen7_5800x3d_native.cpuimg
ferrumscope capture cpu.cpuimg         # raw CPUID
ferrumscope capture-sys system.sysimg [--include-serials]
ferrumscope sensors                    # MSR telemetry (needs the driver)
```

<a id="en-capture"></a>

### Capture and replay

`.cpuimg` stores raw CPUID leaves; `.sysimg` stores raw SMBIOS, PCI IDs, DXGI adapters and disk descriptors/NVMe/SMART pages. Both are text files and run through the **same decoders** as live data, so parsers are unit-tested without hardware. `capture-sys` masks serial numbers and the SMBIOS UUID by default (offsets stay valid). Format: [docs/04-fcap-i-testy.md](docs/04-fcap-i-testy.md).

<a id="en-security"></a>

### Security model (summary)

- The GUI and CLI run as a normal user; nothing is installed.
- The optional `FerrumScopeMsr.sys` driver is **read-only**: three IOCTLs, an MSR **allowlist** (APERF/MPERF), every request validated in the kernel, device ACL limited to SYSTEM and Administrators (`IoCreateDeviceSecure`), no write path at all. It has not been loaded on a real system yet. Details: [docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md).
- Disk access sends only read commands (storage query IOCTLs, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Vendor GPU libraries are loaded only from System32 and only query functions are used.
- Serial numbers are masked in the GUI, reports and captures unless you explicitly ask for them.

<a id="en-licenses"></a>

### Data sources and licenses

- FerrumScope source code: **GPL-3.0-or-later** ([LICENSE](LICENSE)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **or** BSD-3-Clause (header kept in the file and embedded in the program).
- CPU database (`db/source/cpu/*.toml`): every entry cites its source (AMD revision guides, Linux kernel model ranges, public CPUID dumps). No data from CPU-Z/GPU-Z — see [reference/README.md](reference/README.md).
- `assets/logos/` is **not** covered by the GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA and GeForce are trademarks of their respective owners; the logos are used only to identify hardware and imply no endorsement. Per-file origin: [assets/logos/SOURCES.md](assets/logos/SOURCES.md).
- TechPowerUp links are plain links opened by the user; no TechPowerUp data is downloaded or stored.

---

<a id="pl"></a>

## 🇵🇱 Polski

### Spis treści

- [Funkcje](#pl-funkcje)
- [Co wymaga sterownika lub uprawnień administratora](#pl-ograniczenia)
- [Budowanie](#pl-budowanie)
- [GUI](#pl-gui)
- [Użycie CLI](#pl-cli)
- [Capture i replay](#pl-capture)
- [Model bezpieczeństwa](#pl-bezpieczenstwo)
- [Źródła danych i licencje](#pl-licencje)

<a id="pl-funkcje"></a>

### Funkcje

- **CPU** — identyfikacja z CPUID i bazy sprzętu z jawnym pochodzeniem wpisów (nazwa kodowa, mikroarchitektura, rewizja, gniazdo), family/model/stepping, pełna lista instrukcji (MMX … AVX-512, AES, SHA, VT-x/AMD-V) z liściem/bitem CPUID dla każdej, poziom x86-64, cache jako `8 x 32 KB`, topologia, **bez sterownika**: oszacowanie zegara i obciążenie rdzeni.
- **Płyta główna** — producent, model, rewizja, BIOS (producent/wersja/data) z SMBIOS (typy 0/1/2/3/4), chipset z identyfikatorów PCI, lista urządzeń PCI z nazwami z wbudowanej bazy `pci.ids`.
- **Pamięć** — moduły z SMBIOS typ 17: gniazdo, rozmiar, DDR4/DDR5…, prędkość i prędkość ustawiona, producent, part number, ranki, napięcie; suma i jawnie opisana heurystyka liczby kanałów.
- **Grafika** — DXGI + SetupAPI: nazwy, ID producenta/urządzenia/subsystemu/rewizji, nazwa karty z `pci.ids`, wersja/data sterownika, pamięć dedykowana/współdzielona, łącze PCIe. Zegary, temperatury, wentylator, obciążenie i moc przez **AMD ADL** albo **NVIDIA NVAPI** — ładowane w czasie działania, tylko odczyt, opcjonalne.
- **Dyski** — model, firmware, magistrala, pojemność, numer seryjny (maskowany); log zdrowia NVMe (bez administratora) i SMART SATA (administrator): temperatura, czas pracy, zużycie, stan zdrowia według jawnej reguły.
- **Czujniki** — obciążenie/zegar CPU, czujniki GPU, temperatury dysków; czujniki CPU z MSR przez opcjonalny sterownik; wentylatory płyty jako *wymaga sterownika (planowane)*.
- Przyciski **Wyszukaj** (baza GPU/CPU TechPowerUp) i strony sterowników producentów — wyłącznie odnośniki.
- **Eksport raportu** — TXT, HTML, JSON. Numery seryjne i UUID są **domyślnie maskowane**.
- Dwa widoki GUI: zwarty **widok uporządkowany** (domyślny) i **pełna lista** ze źródłem i pewnością każdego pola (`Ctrl+L`).

<a id="pl-ograniczenia"></a>

### Co wymaga sterownika lub uprawnień administratora

| Dane | Wymaganie |
|---|---|
| CPU, płyta, pamięć, grafika, zdrowie NVMe, deskryptory dysków | nic (zwykły użytkownik) |
| SMART dysków SATA | uruchomienie jako administrator; bez tego program to mówi i działa dalej |
| APERF/MPERF, temperatury z MSR | sterownik `FerrumScopeMsr.sys` — **nie jest instalowany automatycznie** |
| Wentylatory/napięcia płyty (Super I/O), timingi SPD (SMBus) | sterownik jądra — **planowane, niezaimplementowane** |

<a id="pl-budowanie"></a>

### Budowanie

Wystarczy przypięty Zig 0.15.2.

```sh
python tools/fetch_zig.py                         # pobiera Zig 0.15.2 i sprawdza SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` buduje i uruchamia GUI. Sterownik buduje się osobno (WDK, `driver/build_driver.bat`); build nigdy go nie instaluje.

<a id="pl-gui"></a>

### GUI

- Zakładki: CPU, Cache, Płyta główna, Pamięć, Grafika, Dyski, Czujniki, Bench (zapowiedź), O programie.
- Najechanie na wartość pokazuje źródło, pewność i wartość surową. **Pokaż źródła** dodaje mały znacznik pewności (W wysoka · Ś średnia · N niska · ~ oszacowanie · Z zaślepka firmware · A wymaga administratora · S wymaga sterownika).
- **Pełna lista** (`Ctrl+L`) — wszystkie pola strony ze źródłem; wybór jest zapamiętywany. `F5` odświeża dane statyczne.
- **Plakietka/logo** na zakładkach CPU i Grafika. Kolejność: Twój obraz → logo dołączone do programu → plakietka rysowana przez FerrumScope. Własne pliki PNG umieść obok programu w `data\images\`:
  - CPU: `cpu\<producent>-<seria>-<model>.png` → `cpu\<producent>-<seria>.png` → `cpu\<producent>.png` (np. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (np. `gpu\1002-744c.png`) → `gpu\<producent>-<seria>-<model>.png` → `gpu\<producent>-<seria>.png` → `gpu\<producent>.png`

  Nazwy małymi literami, znaki inne niż litery i cyfry zamienione na `-`. Kliknięcie plakietki otwiera wyszukiwanie.
- Parametry: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`.

<a id="pl-cli"></a>

### Użycie CLI

```sh
ferrumscope cpu [--json|--raw|--explain]
ferrumscope board | memory | gpu | storage | sensors-all
ferrumscope report --format=html -o raport.html           # txt | html | json
ferrumscope report --format=json --include-serials        # numery seryjne tylko na życzenie
ferrumscope report --sys-replay db/fixtures/sys/asrock_b550_5800x3d_rx7900xtx.sysimg \
                   --cpu-replay db/fixtures/amd_ryzen7_5800x3d_native.cpuimg
ferrumscope capture-sys system.sysimg [--include-serials]
ferrumscope sensors                    # telemetria MSR (wymaga sterownika)
```

<a id="pl-capture"></a>

### Capture i replay

`.cpuimg` przechowuje surowe liście CPUID, `.sysimg` — surowe SMBIOS, identyfikatory PCI, adaptery DXGI oraz deskryptory/strony NVMe/SMART dysków. Oba pliki są tekstowe i przechodzą przez **te same dekodery** co dane na żywo. `capture-sys` domyślnie maskuje numery seryjne i UUID (offsety pozostają poprawne). Format: [docs/04-fcap-i-testy.md](docs/04-fcap-i-testy.md).

<a id="pl-bezpieczenstwo"></a>

### Model bezpieczeństwa (skrót)

- GUI i CLI działają jako zwykły użytkownik; nic nie jest instalowane.
- Opcjonalny sterownik `FerrumScopeMsr.sys` jest **tylko do odczytu**: trzy IOCTL, **allowlista** MSR (APERF/MPERF), walidacja każdej ramki w jądrze, dostęp tylko dla SYSTEM i Administratorów (`IoCreateDeviceSecure`), brak jakiejkolwiek ścieżki zapisu. Nie był jeszcze ładowany. Szczegóły: [docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md).
- Do dysków wysyłane są wyłącznie polecenia odczytu.
- Biblioteki GPU producentów są ładowane tylko z System32 i używane wyłącznie do odczytu.
- Numery seryjne są maskowane w GUI, raportach i plikach capture, chyba że jawnie poprosisz o ich pokazanie.

<a id="pl-licencje"></a>

### Źródła danych i licencje

- Kod FerrumScope: **GPL-3.0-or-later** ([LICENSE](LICENSE)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **lub** BSD-3-Clause.
- Baza CPU: każdy wpis ma źródło (AMD Revision Guides, zakresy modeli z jądra Linux, publiczne zrzuty CPUID). Bez danych z CPU-Z/GPU-Z — [reference/README.md](reference/README.md).
- Katalog `assets/logos/` **nie** jest objęty GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA i GeForce są znakami towarowymi swoich właścicieli; logo służą wyłącznie identyfikacji sprzętu i nie oznaczają poparcia. Pochodzenie plików: [assets/logos/SOURCES.md](assets/logos/SOURCES.md).
- Odnośniki TechPowerUp to zwykłe linki otwierane przez użytkownika; żadne dane TechPowerUp nie są pobierane ani przechowywane.
