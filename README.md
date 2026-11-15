**Languages:** [English](README.md) · [Polski](readme/README.pl.md) · [Български](readme/README.bg.md) · [Čeština](readme/README.cs.md) · [Dansk](readme/README.da.md) · [Deutsch](readme/README.de.md) · [Ελληνικά](readme/README.el.md) · [Español](readme/README.es.md) · [Eesti](readme/README.et.md) · [Suomi](readme/README.fi.md) · [Français](readme/README.fr.md) · [Hrvatski](readme/README.hr.md) · [Magyar](readme/README.hu.md) · [Italiano](readme/README.it.md) · [Lietuvių](readme/README.lt.md) · [Latviešu](readme/README.lv.md) · [Norsk bokmål](readme/README.nb.md) · [Nederlands](readme/README.nl.md) · [Português (Brasil)](readme/README.pt-BR.md) · [Română](readme/README.ro.md) · [Русский](readme/README.ru.md) · [Slovenčina](readme/README.sk.md) · [Slovenščina](readme/README.sl.md) · [Srpski](readme/README.sr-Latn.md) · [Svenska](readme/README.sv.md) · [Türkçe](readme/README.tr.md) · [Українська](readme/README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#build)

An open, transparent hardware information tool for Windows — "CPU-Z + GPU-Z in one", written in Zig. Every value shows **where it came from** (CPUID leaf, SMBIOS offset, PCI ID database, NVMe log byte, vendor library…) and **how confident** the program is about it. No driver needed for the main features, no telemetry.

![FerrumScope CPU tab](docs/screenshots/cpu.png)

## Contents

- [Features](#features)
- [Screenshots](#screenshots)
- [Interface language](#interface-language)
- [What needs a driver or admin rights](#what-needs-a-driver-or-admin-rights)
- [Build](#build)
- [GUI](#gui)
- [Command line](#command-line)
- [Lookup links](#lookup-links)
- [Updates](#updates)
- [Capture and replay](#capture-and-replay)
- [Security model](#security-model)
- [Data sources and licenses](#data-sources-and-licenses)

## Features

- **CPU** — identification from CPUID plus a provenance-tracked hardware database (codename, microarchitecture, revision, socket), family/model/stepping, the full instruction-set list (MMX … AVX-512, AES, SHA, VT-x/AMD-V) with the CPUID leaf and bit of each, the derived x86-64 level, caches shown as `8 x 32 KB`, topology, and a **driverless** clock estimate with per-core and total load.
- **Mainboard** — vendor, model, revision and BIOS (SMBIOS types 0/1/2/3/4), the chipset derived from PCI IDs, and every PCI device named from the built-in `pci.ids`.
- **Memory** — modules from SMBIOS type 17 (slot, size, DDR4/DDR5, speed and configured speed, manufacturer, part number, rank, voltage), the total size, and a clearly labelled channel heuristic.
- **Graphics** — DXGI and SetupAPI: names, vendor/device/subsystem/revision IDs, the board name from `pci.ids`, driver version and date, dedicated and shared memory, the PCIe link. Clocks, temperatures, fan, load and power come from **AMD ADL** or **NVIDIA NVAPI**, loaded at runtime, read-only and optional.
- **Storage** — model, firmware, bus, size and serial (masked). NVMe health log without admin rights, SATA SMART as administrator: temperature, power-on hours, wear and a stated health rule.
- **Sensors** — CPU load and clock, GPU sensors, disk temperatures. MSR-based CPU sensors through the optional driver; motherboard fans are listed as *requires driver (planned)*.
- **Report export** — TXT, HTML and JSON. Serial numbers and UUIDs are **masked by default**.
- **Two views** — a compact CPU-Z-style view (default) and a full list with the source and confidence of every field (`Ctrl+L`).
- **27 interface languages**, an **updater** with stable and test channels, **lookup** buttons for the TechPowerUp database and vendor driver pages.

## Screenshots

| CPU | Graphics |
|---|---|
| ![CPU](docs/screenshots/cpu.png) | ![Graphics](docs/screenshots/graphics.png) |

| Mainboard | Memory |
|---|---|
| ![Mainboard](docs/screenshots/board.png) | ![Memory](docs/screenshots/memory.png) |

| Storage (administrator, SATA SMART) | Full list view |
|---|---|
| ![Storage](docs/screenshots/admin_storage.png) | ![Full list](docs/screenshots/list_board.png) |

All tabs and both views: [docs/screenshots](docs/screenshots).

## Interface language

The GUI, the command line and TXT/HTML reports are available in 27 languages: Polish (source), English, Bulgarian, Czech, Danish, German, Greek, Spanish, Estonian, Finnish, French, Croatian, Hungarian, Italian, Lithuanian, Latvian, Norwegian Bokmål, Dutch, Portuguese (Brazil), Romanian, Russian, Slovak, Slovenian, Serbian (Latin), Swedish, Turkish and Ukrainian.

The language is chosen in this order: the saved setting (`data\settings.ini`), the Windows display language, then English. Change it in the GUI (language picker) or with `ferrumscope lang <code>` / `--lang=<code>`. Technical values (instruction names, units, PCI IDs) are never translated, and JSON export keys stay in English. Translators: see [locales/README.md](locales/README.md).

## What needs a driver or admin rights

| Data | Requirement |
|---|---|
| CPU, mainboard, memory, graphics, NVMe health, disk descriptors | nothing (regular user) |
| SATA SMART | run as administrator; without it the program says so and keeps working |
| APERF/MPERF, temperatures from MSR | the `FerrumScopeMsr.sys` driver — **not installed automatically** |
| Motherboard fans/voltages (Super I/O), SPD timings (SMBus) | a kernel driver — **planned, not implemented** |

## Build

Only the pinned Zig 0.15.2 is needed.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` builds and starts the GUI. The optional driver is built separately with the WDK (`driver/build_driver.bat`) and is never installed by the build.

## GUI

- Tabs: CPU, Cache, Mainboard, Memory, Graphics, Storage, Sensors, Bench (placeholder), About.
- Hover a value to see its source, confidence and raw value. **Show sources** adds a small marker next to each field.
- **Full list** (`Ctrl+L`) shows every field with its source; the choice is remembered. `F5` refreshes static data (SMBIOS, PCI, disks).
- **Badge/logo** on the CPU and Graphics tabs. Priority: your own image → a bundled vendor logo → a badge drawn by FerrumScope. Put your own PNG files next to the program in `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (e.g. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (e.g. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Names are lowercase with every non-alphanumeric character replaced by `-`. Clicking the badge opens the lookup link.
- Command-line options: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Command line

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

## Lookup links

The **Search** buttons and the badge open the TechPowerUp GPU/CPU database. The exact page is used when it is known, in this order:

1. a link you pinned yourself — copy the page address in your browser and click **Pin…** next to the field (saved in `data\links.toml`);
2. the curated table [`db/source/links/techpowerup.toml`](db/source/links/techpowerup.toml) — entries are added by hand (`source = "manual"`), never by crawling; pull requests welcome;
3. otherwise a search by name.

Only links are stored; nothing is downloaded from TechPowerUp. Accepted addresses: `https://` on techpowerup.com or the vendor's site.

## Updates

FerrumScope checks GitHub releases of `snakex21/FerrumScope` over HTTPS — at most once a day on start (can be turned off), or on demand in **About → Check for updates** / `ferrumscope update --check`. An update is installed only after the downloaded zip matches **both** the SHA-256 in `ferrumscope-update.json` and `SHA256SUMS`; the previous exe is kept as `.old` (`ferrumscope update --rollback`) and the `data\` folder (settings, pinned links, your images) is never touched. Channels: **stable** (default) and **test** (pre-releases). No telemetry is sent.

## Capture and replay

`.cpuimg` stores raw CPUID leaves; `.sysimg` stores raw SMBIOS, PCI IDs, DXGI adapters and disk descriptors/NVMe/SMART pages. Both are text files and go through **the same decoders** as live data, so the parsers are tested without hardware. `capture-sys` masks serial numbers and the SMBIOS UUID by default (offsets stay valid). Format: [docs/04-fcap-i-testy.md](docs/04-fcap-i-testy.md).

## Security model

- The GUI and CLI run as a normal user; nothing is installed.
- The optional `FerrumScopeMsr.sys` driver is **read-only**: three IOCTLs, an MSR **allowlist** (APERF/MPERF), every request validated in the kernel, device access limited to SYSTEM and Administrators (`IoCreateDeviceSecure`), no write path at all. It has not been loaded on a real system yet. Details: [docs/SECURITY-MODEL.md](docs/SECURITY-MODEL.md).
- Disks receive only read commands (storage query IOCTLs, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Vendor GPU libraries are loaded only from System32, and only query functions are used.
- Serial numbers are masked in the GUI, reports and captures unless you explicitly ask for them.

## Data sources and licenses

- FerrumScope source code: **GPL-3.0-or-later** ([LICENSE](LICENSE), [NOTICE.md](NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **or** BSD-3-Clause.
- CPU database (`db/source/cpu/*.toml`): every entry cites its source (AMD revision guides, Linux kernel model ranges, public CPUID dumps). No data from CPU-Z or GPU-Z — see [reference/README.md](reference/README.md).
- `assets/logos/` is **not** covered by the GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA and GeForce are trademarks of their respective owners; the logos are used only to identify hardware and imply no endorsement. Per-file origin: [assets/logos/SOURCES.md](assets/logos/SOURCES.md).
- TechPowerUp links are plain links opened by you; no TechPowerUp data is downloaded or stored.
