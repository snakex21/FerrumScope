**Sprachen:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#erstellen)

Ein offenes, transparentes Werkzeug für Hardware-Informationen unter Windows – „CPU-Z + GPU-Z in einem“, geschrieben in Zig. Jeder Wert zeigt, **woher er stammt** (CPUID-Leaf, SMBIOS-Offset, PCI-ID-Datenbank, Byte im NVMe-Log, Herstellerbibliothek …) und **wie zuverlässig** das Programm ihn einschätzt. Für die Hauptfunktionen ist kein Treiber nötig, keine Telemetrie.

![FerrumScope, Registerkarte CPU](../docs/screenshots/cpu.png)

## Inhalt

- [Funktionen](#funktionen)
- [Screenshots](#screenshots)
- [Sprache der Oberfläche](#sprache-der-oberfläche)
- [Was einen Treiber oder Administratorrechte benötigt](#was-einen-treiber-oder-administratorrechte-benötigt)
- [Erstellen](#erstellen)
- [GUI](#gui)
- [Befehlszeile](#befehlszeile)
- [Such-Links](#such-links)
- [Updates](#updates)
- [Aufzeichnung und Wiedergabe](#aufzeichnung-und-wiedergabe)
- [Sicherheitsmodell](#sicherheitsmodell)
- [Datenquellen und Lizenzen](#datenquellen-und-lizenzen)

## Funktionen

- **CPU** – Identifikation über CPUID plus eine Hardware-Datenbank mit nachverfolgter Herkunft (Codename, Mikroarchitektur, Revision, Sockel), Familie/Modell/Stepping, die vollständige Liste der Befehlssätze (MMX … AVX-512, AES, SHA, VT-x/AMD-V) jeweils mit CPUID-Leaf und Bit, das abgeleitete x86-64-Level, Caches in der Form `8 x 32 KB`, Topologie sowie eine Taktschätzung **ohne Treiber** mit Auslastung pro Kern und gesamt.
- **Mainboard** – Hersteller, Modell, Revision und BIOS (SMBIOS-Typen 0/1/2/3/4), der aus den PCI-IDs abgeleitete Chipsatz und jedes PCI-Gerät, benannt anhand der integrierten `pci.ids`.
- **Speicher** – Module aus SMBIOS Typ 17 (Steckplatz, Größe, DDR4/DDR5, Geschwindigkeit und konfigurierte Geschwindigkeit, Hersteller, Teilenummer, Rank, Spannung), die Gesamtgröße und eine klar gekennzeichnete Kanal-Heuristik.
- **Grafik** – DXGI und SetupAPI: Namen, Hersteller-/Geräte-/Subsystem-/Revisions-IDs, der Kartenname aus `pci.ids`, Treiberversion und -datum, dedizierter und gemeinsamer Speicher, der PCIe-Link. Takte, Temperaturen, Lüfter, Auslastung und Leistung stammen aus **AMD ADL** oder **NVIDIA NVAPI**, zur Laufzeit geladen, nur lesend und optional.
- **Laufwerke** – Modell, Firmware, Bus, Größe und Seriennummer (maskiert). NVMe-Zustandslog ohne Administratorrechte, SATA SMART als Administrator: Temperatur, Betriebsstunden, Verschleiß und eine ausdrücklich angegebene Zustandsregel.
- **Sensoren** – CPU-Auslastung und -Takt, GPU-Sensoren, Laufwerkstemperaturen. MSR-basierte CPU-Sensoren über den optionalen Treiber; Mainboard-Lüfter werden als *erfordert Treiber (geplant)* aufgeführt.
- **Berichtsexport** – TXT, HTML und JSON. Seriennummern und UUIDs sind **standardmäßig maskiert**.
- **Zwei Ansichten** – eine kompakte Ansicht im Stil von CPU-Z (Standard) und eine vollständige Liste mit Quelle und Zuverlässigkeit jedes Feldes (`Ctrl+L`).
- **27 Sprachen der Oberfläche**, ein **Updater** mit stabilem und Testkanal, **Such**-Schaltflächen für die TechPowerUp-Datenbank und die Treiberseiten der Hersteller.

## Screenshots

| CPU | Grafik |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Grafik](../docs/screenshots/graphics.png) |

| Mainboard | Speicher |
|---|---|
| ![Mainboard](../docs/screenshots/board.png) | ![Speicher](../docs/screenshots/memory.png) |

| Laufwerke (Administrator, SATA SMART) | Ansicht „Vollständige Liste“ |
|---|---|
| ![Laufwerke](../docs/screenshots/admin_storage.png) | ![Vollständige Liste](../docs/screenshots/list_board.png) |

Alle Registerkarten und beide Ansichten: [docs/screenshots](../docs/screenshots).

## Sprache der Oberfläche

Die GUI, die Befehlszeile und die TXT/HTML-Berichte sind in 27 Sprachen verfügbar: Polnisch (Ausgangssprache), Englisch, Bulgarisch, Tschechisch, Dänisch, Deutsch, Griechisch, Spanisch, Estnisch, Finnisch, Französisch, Kroatisch, Ungarisch, Italienisch, Litauisch, Lettisch, Norwegisch (Bokmål), Niederländisch, Portugiesisch (Brasilien), Rumänisch, Russisch, Slowakisch, Slowenisch, Serbisch (lateinisch), Schwedisch, Türkisch und Ukrainisch.

Die Sprache wird in dieser Reihenfolge gewählt: die gespeicherte Einstellung (`data\settings.ini`), die Anzeigesprache von Windows, dann Englisch. Ändern lässt sie sich in der GUI (Sprachauswahl) oder mit `ferrumscope lang <code>` / `--lang=<code>`. Technische Werte (Befehlsnamen, Einheiten, PCI-IDs) werden nie übersetzt, und die Schlüssel des JSON-Exports bleiben englisch. Für Übersetzer: siehe [locales/README.md](../locales/README.md).

## Was einen Treiber oder Administratorrechte benötigt

| Daten | Voraussetzung |
|---|---|
| CPU, Mainboard, Speicher, Grafik, NVMe-Zustand, Laufwerksbeschreibungen | nichts (normaler Benutzer) |
| SATA SMART | Ausführung als Administrator; ohne diese meldet das Programm dies und arbeitet weiter |
| APERF/MPERF, Temperaturen aus MSR | der Treiber `FerrumScopeMsr.sys` – **wird nicht automatisch installiert** |
| Mainboard-Lüfter/-Spannungen (Super I/O), SPD-Timings (SMBus) | ein Kerneltreiber – **geplant, nicht implementiert** |

## Erstellen

Benötigt wird nur das fest vorgegebene Zig 0.15.2.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` erstellt und startet die GUI. Der optionale Treiber wird separat mit dem WDK erstellt (`driver/build_driver.bat`) und vom Build nie installiert.

## GUI

- Registerkarten: CPU, Cache, Mainboard, Speicher, Grafik, Laufwerke, Sensoren, Bench (Platzhalter), Über.
- Zeigen Sie auf einen Wert, um Quelle, Zuverlässigkeit und Rohwert zu sehen. **Quellen anzeigen** fügt neben jedem Feld eine kleine Markierung hinzu.
- **Vollständige Liste** (`Ctrl+L`) zeigt jedes Feld mit seiner Quelle; die Auswahl wird gespeichert. `F5` aktualisiert die statischen Daten (SMBIOS, PCI, Laufwerke).
- **Abzeichen/Logo** auf den Registerkarten CPU und Grafik. Priorität: eigenes Bild → mitgeliefertes Herstellerlogo → von FerrumScope gezeichnetes Abzeichen. Legen Sie eigene PNG-Dateien neben dem Programm in `data\images\` ab:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (z. B. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (z. B. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Die Namen sind kleingeschrieben, jedes nicht alphanumerische Zeichen wird durch `-` ersetzt. Ein Klick auf das Abzeichen öffnet den Such-Link.
- Befehlszeilenoptionen: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Befehlszeile

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

## Such-Links

Die Schaltflächen **Suchen** und das Abzeichen öffnen die GPU/CPU-Datenbank von TechPowerUp. Ist die genaue Seite bekannt, wird sie verwendet, in dieser Reihenfolge:

1. ein selbst angehefteter Link – kopieren Sie die Seitenadresse im Browser und klicken Sie neben dem Feld auf **Anheften…** (gespeichert in `data\links.toml`);
2. die kuratierte Tabelle [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) – Einträge werden von Hand hinzugefügt (`source = "manual"`), nie durch Crawling; Pull Requests sind willkommen;
3. andernfalls eine Suche nach Name.

Gespeichert werden nur Links; von TechPowerUp wird nichts heruntergeladen. Akzeptierte Adressen: `https://` auf techpowerup.com oder der Website des Herstellers.

## Updates

FerrumScope prüft die GitHub-Releases von `snakex21/FerrumScope` über HTTPS – höchstens einmal täglich beim Start (abschaltbar) oder bei Bedarf über **Über → Nach Updates suchen…** / `ferrumscope update --check`. Ein Update wird erst installiert, wenn das heruntergeladene Zip **sowohl** mit der SHA-256-Summe in `ferrumscope-update.json` **als auch** mit `SHA256SUMS` übereinstimmt; die vorherige exe bleibt als `.old` erhalten (`ferrumscope update --rollback`), und der Ordner `data\` (Einstellungen, angeheftete Links, eigene Bilder) wird nie angerührt. Kanäle: **stable** (Standard) und **test** (Vorabversionen). Es wird keine Telemetrie gesendet.

## Aufzeichnung und Wiedergabe

`.cpuimg` speichert rohe CPUID-Leaves; `.sysimg` speichert rohes SMBIOS, PCI-IDs, DXGI-Adapter sowie Laufwerksbeschreibungen/NVMe-/SMART-Seiten. Beides sind Textdateien und durchlaufen **dieselben Decoder** wie Live-Daten, sodass die Parser ohne Hardware getestet werden. `capture-sys` maskiert standardmäßig Seriennummern und die SMBIOS-UUID (die Offsets bleiben gültig). Format: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Sicherheitsmodell

- GUI und CLI laufen als normaler Benutzer; nichts wird installiert.
- Der optionale Treiber `FerrumScopeMsr.sys` ist **nur lesend**: drei IOCTLs, eine MSR-**Allowlist** (APERF/MPERF), jede Anfrage wird im Kernel validiert, Gerätezugriff nur für SYSTEM und Administratoren (`IoCreateDeviceSecure`), überhaupt kein Schreibpfad. Er wurde bisher noch nicht auf einem realen System geladen. Details: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Laufwerke erhalten nur Lesebefehle (Storage-Query-IOCTLs, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- GPU-Bibliotheken der Hersteller werden nur aus System32 geladen, und es werden nur Abfragefunktionen verwendet.
- Seriennummern werden in GUI, Berichten und Aufzeichnungen maskiert, sofern Sie sie nicht ausdrücklich anfordern.

## Datenquellen und Lizenzen

- Quellcode von FerrumScope: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **oder** BSD-3-Clause.
- CPU-Datenbank (`db/source/cpu/*.toml`): Jeder Eintrag nennt seine Quelle (AMD Revision Guides, Modellbereiche aus dem Linux-Kernel, öffentliche CPUID-Dumps). Keine Daten aus CPU-Z oder GPU-Z – siehe [reference/README.md](../reference/README.md).
- `assets/logos/` fällt **nicht** unter die GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA und GeForce sind Marken ihrer jeweiligen Inhaber; die Logos dienen ausschließlich der Identifikation der Hardware und implizieren keine Billigung. Herkunft pro Datei: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- TechPowerUp-Links sind einfache Links, die Sie selbst öffnen; es werden keine Daten von TechPowerUp heruntergeladen oder gespeichert.
