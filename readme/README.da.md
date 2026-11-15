**Languages:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#byg)

Et åbent og gennemsigtigt værktøj til hardwareinformation til Windows — "CPU-Z + GPU-Z i ét", skrevet i Zig. Hver værdi viser, **hvor den kommer fra** (CPUID-leaf, SMBIOS-offset, PCI ID-database, NVMe-logbyte, producentbibliotek…), og **hvor sikkert** programmet er på den. Ingen driver nødvendig til hovedfunktionerne, ingen telemetri.

![FerrumScope, fanen CPU](../docs/screenshots/cpu.png)

## Indhold

- [Funktioner](#funktioner)
- [Skærmbilleder](#skærmbilleder)
- [Grænsefladesprog](#grænsefladesprog)
- [Hvad kræver en driver eller administratorrettigheder](#hvad-kræver-en-driver-eller-administratorrettigheder)
- [Byg](#byg)
- [GUI](#gui)
- [Kommandolinje](#kommandolinje)
- [Opslagslinks](#opslagslinks)
- [Opdateringer](#opdateringer)
- [Capture og replay](#capture-og-replay)
- [Sikkerhedsmodel](#sikkerhedsmodel)
- [Datakilder og licenser](#datakilder-og-licenser)

## Funktioner

- **CPU** — identifikation fra CPUID plus en hardwaredatabase med sporbar oprindelse (kodenavn, mikroarkitektur, revision, sokkel), familie/model/stepping, den fulde liste over instruktionssæt (MMX … AVX-512, AES, SHA, VT-x/AMD-V) med CPUID-leaf og bit for hver enkelt, det afledte x86-64-niveau, cacher vist som `8 x 32 KB`, topologi og et klokfrekvensestimat **uden driver** med belastning pr. kerne og i alt.
- **Bundkort** — producent, model, revision og BIOS (SMBIOS type 0/1/2/3/4), chipsettet udledt af PCI-id'er og alle PCI-enheder navngivet ud fra den indbyggede `pci.ids`.
- **Hukommelse** — moduler fra SMBIOS type 17 (slot, størrelse, DDR4/DDR5, hastighed og konfigureret hastighed, producent, varenummer, rank, spænding), den samlede størrelse og en tydeligt mærket kanalheuristik.
- **Grafik** — DXGI og SetupAPI: navne, vendor-/device-/subsystem-/revisions-id'er, kortnavnet fra `pci.ids`, driverversion og -dato, dedikeret og delt hukommelse, PCIe-linket. Klokfrekvenser, temperaturer, ventilator, belastning og effekt kommer fra **AMD ADL** eller **NVIDIA NVAPI**, som indlæses under kørsel, skrivebeskyttet og valgfrit.
- **Drev** — model, firmware, bus, størrelse og serienummer (maskeret). NVMe-helbredslog uden administratorrettigheder, SATA SMART som administrator: temperatur, driftstimer, slid og en angivet helbredsregel.
- **Sensorer** — CPU-belastning og -klokfrekvens, GPU-sensorer, drevtemperaturer. MSR-baserede CPU-sensorer via den valgfrie driver; bundkortventilatorer vises som *kræver driver (planlagt)*.
- **Rapporteksport** — TXT, HTML og JSON. Serienumre og UUID'er er **maskeret som standard**.
- **To visninger** — en kompakt visning i CPU-Z-stil (standard) og en fuld liste med kilde og sikkerhed for hvert felt (`Ctrl+L`).
- **27 grænsefladesprog**, en **opdatering** med stabil kanal og testkanal samt **opslagsknapper** til TechPowerUp-databasen og producenternes driversider.

## Skærmbilleder

| CPU | Grafik |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Grafik](../docs/screenshots/graphics.png) |

| Bundkort | Hukommelse |
|---|---|
| ![Bundkort](../docs/screenshots/board.png) | ![Hukommelse](../docs/screenshots/memory.png) |

| Drev (administrator, SATA SMART) | Visning som fuld liste |
|---|---|
| ![Drev](../docs/screenshots/admin_storage.png) | ![Fuld liste](../docs/screenshots/list_board.png) |

Alle faner og begge visninger: [docs/screenshots](../docs/screenshots).

## Grænsefladesprog

GUI'en, kommandolinjen og TXT/HTML-rapporterne findes på 27 sprog: polsk (kildesprog), engelsk, bulgarsk, tjekkisk, dansk, tysk, græsk, spansk, estisk, finsk, fransk, kroatisk, ungarsk, italiensk, litauisk, lettisk, norsk bokmål, nederlandsk, portugisisk (Brasilien), rumænsk, russisk, slovakisk, slovensk, serbisk (latinsk), svensk, tyrkisk og ukrainsk.

Sproget vælges i denne rækkefølge: den gemte indstilling (`data\settings.ini`), Windows' visningssprog og derefter engelsk. Skift det i GUI'en (sprogvælgeren) eller med `ferrumscope lang <code>` / `--lang=<code>`. Tekniske værdier (instruktionsnavne, enheder, PCI-id'er) oversættes aldrig, og nøglerne i JSON-eksporten forbliver på engelsk. Oversættere: se [locales/README.md](../locales/README.md).

## Hvad kræver en driver eller administratorrettigheder

| Data | Krav |
|---|---|
| CPU, bundkort, hukommelse, grafik, NVMe-helbred, drevbeskrivelser | intet (almindelig bruger) |
| SATA SMART | kør som administrator; uden det oplyser programmet det og fortsætter med at virke |
| APERF/MPERF, temperaturer fra MSR | driveren `FerrumScopeMsr.sys` — **installeres ikke automatisk** |
| Bundkortventilatorer/-spændinger (Super I/O), SPD-timings (SMBus) | en kernedriver — **planlagt, ikke implementeret** |

## Byg

Kun den fastlåste Zig 0.15.2 er nødvendig.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` bygger og starter GUI'en. Den valgfrie driver bygges separat med WDK (`driver/build_driver.bat`) og installeres aldrig af byggeprocessen.

## GUI

- Faner: CPU, Cache, Bundkort, Hukommelse, Grafik, Drev, Sensorer, Benchmark (pladsholder), Om.
- Hold musen over en værdi for at se dens kilde, sikkerhed og råværdi. **Vis kilder** tilføjer en lille markør ved hvert felt.
- **Fuld liste** (`Ctrl+L`) viser alle felter med deres kilde; valget huskes. `F5` opdaterer statiske data (SMBIOS, PCI, drev).
- **Mærkat/logo** på fanerne CPU og Grafik. Prioritet: dit eget billede → et medfølgende producentlogo → et mærkat tegnet af FerrumScope. Læg dine egne PNG-filer ved siden af programmet i `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (f.eks. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (f.eks. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Navnene skrives med små bogstaver, og alle tegn, der ikke er bogstaver eller cifre, erstattes af `-`. Et klik på mærkatet åbner opslagslinket.
- Kommandolinjeindstillinger: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Kommandolinje

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

## Opslagslinks

Knapperne **Slå op** og mærkatet åbner TechPowerUps GPU-/CPU-database. Den præcise side bruges, når den er kendt, i denne rækkefølge:

1. et link, du selv har fastgjort — kopiér sidens adresse i din browser, og klik på **Fastgør…** ved siden af feltet (gemmes i `data\links.toml`);
2. den kuraterede tabel [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — poster tilføjes manuelt (`source = "manual"`), aldrig ved crawling; pull requests er velkomne;
3. ellers en søgning efter navn.

Der gemmes kun links; intet downloades fra TechPowerUp. Accepterede adresser: `https://` på techpowerup.com eller producentens websted.

## Opdateringer

FerrumScope tjekker GitHub-udgivelser af `snakex21/FerrumScope` via HTTPS — højst én gang om dagen ved opstart (kan slås fra) eller efter behov under **Om → Søg efter opdateringer** / `ferrumscope update --check`. En opdatering installeres kun, når den downloadede zip-fil stemmer overens med **både** SHA-256 i `ferrumscope-update.json` og `SHA256SUMS`; den forrige exe-fil bevares som `.old` (`ferrumscope update --rollback`), og mappen `data\` (indstillinger, fastgjorte links, dine billeder) røres aldrig. Kanaler: **stable** (standard) og **test** (prøveversioner). Der sendes ingen telemetri.

## Capture og replay

`.cpuimg` gemmer rå CPUID-leaves; `.sysimg` gemmer rå SMBIOS, PCI-id'er, DXGI-adaptere og drevbeskrivelser/NVMe-/SMART-sider. Begge er tekstfiler og går gennem **de samme dekodere** som live-data, så parserne testes uden hardware. `capture-sys` maskerer som standard serienumre og SMBIOS-UUID'et (offsets forbliver gyldige). Format: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Sikkerhedsmodel

- GUI'en og CLI'en kører som almindelig bruger; intet installeres.
- Den valgfrie driver `FerrumScopeMsr.sys` er **skrivebeskyttet**: tre IOCTL'er, en **tilladelsesliste** over MSR'er (APERF/MPERF), hver anmodning valideres i kernen, adgang til enheden er begrænset til SYSTEM og Administratorer (`IoCreateDeviceSecure`), og der findes overhovedet ingen skrivevej. Den er endnu ikke blevet indlæst på et rigtigt system. Detaljer: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Drev modtager kun læsekommandoer (storage query-IOCTL'er, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Producenternes GPU-biblioteker indlæses kun fra System32, og kun forespørgselsfunktioner bruges.
- Serienumre maskeres i GUI'en, rapporter og captures, medmindre du udtrykkeligt beder om dem.

## Datakilder og licenser

- FerrumScopes kildekode: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **eller** BSD-3-Clause.
- CPU-database (`db/source/cpu/*.toml`): hver post angiver sin kilde (AMD's revision guides, modelintervaller fra Linux-kernen, offentlige CPUID-dumps). Ingen data fra CPU-Z eller GPU-Z — se [reference/README.md](../reference/README.md).
- `assets/logos/` er **ikke** omfattet af GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA og GeForce er varemærker tilhørende deres respektive ejere; logoerne bruges udelukkende til at identificere hardware og indebærer ingen anbefaling. Oprindelse pr. fil: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- TechPowerUp-links er almindelige links, som du selv åbner; der downloades eller gemmes ingen data fra TechPowerUp.
