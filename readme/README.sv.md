**Språk:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#bygga)

Ett öppet och transparent verktyg för maskinvaruinformation i Windows — "CPU-Z + GPU-Z i ett", skrivet i Zig. Varje värde visar **varifrån det kommer** (CPUID-löv, SMBIOS-offset, PCI ID-databas, byte i NVMe-loggen, tillverkarbibliotek…) och **hur säkert** programmet är på det. Ingen drivrutin krävs för huvudfunktionerna, ingen telemetri.

![FerrumScope, fliken CPU](../docs/screenshots/cpu.png)

## Innehåll

- [Funktioner](#funktioner)
- [Skärmbilder](#skärmbilder)
- [Gränssnittsspråk](#gränssnittsspråk)
- [Vad som kräver drivrutin eller administratörsbehörighet](#vad-som-kräver-drivrutin-eller-administratörsbehörighet)
- [Bygga](#bygga)
- [GUI](#gui)
- [Kommandorad](#kommandorad)
- [Uppslagslänkar](#uppslagslänkar)
- [Uppdateringar](#uppdateringar)
- [Capture och replay](#capture-och-replay)
- [Säkerhetsmodell](#säkerhetsmodell)
- [Datakällor och licenser](#datakällor-och-licenser)

## Funktioner

- **CPU** — identifiering från CPUID plus en maskinvarudatabas med spårat ursprung (kodnamn, mikroarkitektur, revision, sockel), family/model/stepping, den fullständiga listan över instruktionsuppsättningar (MMX … AVX-512, AES, SHA, VT-x/AMD-V) med CPUID-löv och bit för var och en, den härledda x86-64-nivån, cacheminnen visade som `8 x 32 KB`, topologi samt en uppskattning av klockfrekvensen **utan drivrutin** med belastning per kärna och totalt.
- **Moderkort** — tillverkare, modell, revision och BIOS (SMBIOS-typerna 0/1/2/3/4), chipset härlett från PCI-ID:n och varje PCI-enhet namngiven utifrån den inbyggda `pci.ids`.
- **Minne** — moduler från SMBIOS typ 17 (kortplats, storlek, DDR4/DDR5, hastighet och konfigurerad hastighet, tillverkare, artikelnummer, rank, spänning), total storlek och en tydligt märkt kanalheuristik.
- **Grafik** — DXGI och SetupAPI: namn, vendor-/device-/subsystem-/revisions-ID:n, kortnamnet från `pci.ids`, drivrutinsversion och datum, dedikerat och delat minne, PCIe-länken. Klockfrekvenser, temperaturer, fläkt, belastning och effekt kommer från **AMD ADL** eller **NVIDIA NVAPI**, som läses in vid körning, endast läsning och valfritt.
- **Lagring** — modell, firmware, buss, storlek och serienummer (maskerat). NVMe-hälsologg utan administratörsbehörighet, SATA SMART som administratör: temperatur, drifttimmar, slitage och en angiven hälsoregel.
- **Sensorer** — CPU-belastning och klockfrekvens, GPU-sensorer, disktemperaturer. MSR-baserade CPU-sensorer via den valfria drivrutinen; moderkortets fläktar listas som *kräver drivrutin (planerat)*.
- **Rapportexport** — TXT, HTML och JSON. Serienummer och UUID:er är **maskerade som standard**.
- **Två vyer** — en kompakt vy i CPU-Z-stil (standard) och en fullständig lista med källa och tillförlitlighet för varje fält (`Ctrl+L`).
- **27 gränssnittsspråk**, en **uppdaterare** med stabil kanal och testkanal, **uppslagsknappar** för TechPowerUp-databasen och tillverkarnas drivrutinssidor.

## Skärmbilder

| CPU | Grafik |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Grafik](../docs/screenshots/graphics.png) |

| Moderkort | Minne |
|---|---|
| ![Moderkort](../docs/screenshots/board.png) | ![Minne](../docs/screenshots/memory.png) |

| Lagring (administratör, SATA SMART) | Vyn Fullständig lista |
|---|---|
| ![Lagring](../docs/screenshots/admin_storage.png) | ![Fullständig lista](../docs/screenshots/list_board.png) |

Alla flikar och båda vyerna: [docs/screenshots](../docs/screenshots).

## Gränssnittsspråk

GUI:t, kommandoraden och TXT/HTML-rapporterna finns på 27 språk: polska (källspråk), engelska, bulgariska, tjeckiska, danska, tyska, grekiska, spanska, estniska, finska, franska, kroatiska, ungerska, italienska, litauiska, lettiska, norskt bokmål, nederländska, portugisiska (Brasilien), rumänska, ryska, slovakiska, slovenska, serbiska (latinskt alfabet), svenska, turkiska och ukrainska.

Språket väljs i denna ordning: den sparade inställningen (`data\settings.ini`), Windows visningsspråk och sedan engelska. Ändra det i GUI:t (språkväljaren) eller med `ferrumscope lang <code>` / `--lang=<code>`. Tekniska värden (instruktionsnamn, enheter, PCI-ID:n) översätts aldrig, och nycklarna i JSON-exporten förblir på engelska. Översättare: se [locales/README.md](../locales/README.md).

## Vad som kräver drivrutin eller administratörsbehörighet

| Data | Krav |
|---|---|
| CPU, moderkort, minne, grafik, NVMe-hälsa, diskbeskrivningar | inget (vanlig användare) |
| SATA SMART | kör som administratör; utan det meddelar programmet detta och fortsätter att fungera |
| APERF/MPERF, temperaturer från MSR | drivrutinen `FerrumScopeMsr.sys` — **installeras inte automatiskt** |
| Moderkortets fläktar/spänningar (Super I/O), SPD-timingar (SMBus) | en drivrutin i kärnläge — **planerat, inte implementerat** |

## Bygga

Endast den fastlåsta versionen Zig 0.15.2 behövs.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` bygger och startar GUI:t. Den valfria drivrutinen byggs separat med WDK (`driver/build_driver.bat`) och installeras aldrig av bygget.

## GUI

- Flikar: CPU, Cache, Moderkort, Minne, Grafik, Diskar, Sensorer, Bench (platshållare), Om.
- Håll muspekaren över ett värde för att se dess källa, tillförlitlighet och råvärde. **Visa källor** lägger till en liten markör bredvid varje fält.
- **Fullständig lista** (`Ctrl+L`) visar varje fält med dess källa; valet sparas. `F5` uppdaterar statiska data (SMBIOS, PCI, diskar).
- **Märke/logotyp** på flikarna CPU och Grafik. Prioritet: din egen bild → en medföljande tillverkarlogotyp → ett märke ritat av FerrumScope. Lägg dina egna PNG-filer bredvid programmet i `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (t.ex. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (t.ex. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Namnen skrivs med gemener och varje tecken som inte är alfanumeriskt ersätts med `-`. Ett klick på märket öppnar uppslagslänken.
- Kommandoradsalternativ: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Kommandorad

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

## Uppslagslänkar

**Sök**-knapparna och märket öppnar TechPowerUps GPU-/CPU-databas. Den exakta sidan används när den är känd, i denna ordning:

1. en länk som du själv har fäst — kopiera sidans adress i webbläsaren och klicka på **Fäst…** bredvid fältet (sparas i `data\links.toml`);
2. den kurerade tabellen [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — posterna läggs till för hand (`source = "manual"`), aldrig genom crawling; pull requests är välkomna;
3. annars en sökning efter namn.

Endast länkar sparas; ingenting hämtas från TechPowerUp. Godkända adresser: `https://` på techpowerup.com eller tillverkarens webbplats.

## Uppdateringar

FerrumScope kontrollerar GitHub-utgåvor av `snakex21/FerrumScope` via HTTPS — högst en gång per dag vid start (kan stängas av) eller på begäran under **Om → Sök efter uppdateringar…** / `ferrumscope update --check`. En uppdatering installeras först när den hämtade zip-filen stämmer med **både** SHA-256 i `ferrumscope-update.json` och `SHA256SUMS`; den tidigare exe-filen sparas som `.old` (`ferrumscope update --rollback`) och mappen `data\` (inställningar, fästa länkar, dina bilder) rörs aldrig. Kanaler: **stable** (standard) och **test** (förhandsversioner). Ingen telemetri skickas.

## Capture och replay

`.cpuimg` lagrar råa CPUID-löv; `.sysimg` lagrar rå SMBIOS, PCI-ID:n, DXGI-adaptrar och diskbeskrivningar/NVMe-/SMART-sidor. Båda är textfiler och går igenom **samma avkodare** som livedata, så att tolkarna testas utan maskinvara. `capture-sys` maskerar serienummer och SMBIOS-UUID som standard (offseten förblir giltiga). Format: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Säkerhetsmodell

- GUI:t och CLI:t körs som vanlig användare; ingenting installeras.
- Den valfria drivrutinen `FerrumScopeMsr.sys` är **skrivskyddad**: tre IOCTL:er, en **tillåtelselista** för MSR (APERF/MPERF), varje begäran valideras i kärnan, åtkomst till enheten är begränsad till SYSTEM och Administratörer (`IoCreateDeviceSecure`), och det finns ingen skrivväg alls. Den har ännu inte lästs in på ett riktigt system. Detaljer: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Diskarna får endast läskommandon (IOCTL:er för lagringsfrågor, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Tillverkarnas GPU-bibliotek läses endast in från System32, och endast frågefunktioner används.
- Serienummer maskeras i GUI:t, rapporter och captures om du inte uttryckligen begär dem.

## Datakällor och licenser

- FerrumScopes källkod: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **eller** BSD-3-Clause.
- CPU-databasen (`db/source/cpu/*.toml`): varje post anger sin källa (AMD:s revisionsguider, modellintervall i Linuxkärnan, offentliga CPUID-dumpar). Inga data från CPU-Z eller GPU-Z — se [reference/README.md](../reference/README.md).
- `assets/logos/` omfattas **inte** av GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA och GeForce är varumärken som tillhör respektive ägare; logotyperna används endast för att identifiera maskinvara och innebär inget godkännande. Ursprung per fil: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- TechPowerUp-länkar är vanliga länkar som du själv öppnar; inga data från TechPowerUp hämtas eller lagras.
