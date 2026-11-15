**Språk:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#bygging)

Et åpent og gjennomsiktig verktøy for maskinvareinformasjon for Windows — «CPU-Z + GPU-Z i ett», skrevet i Zig. Hver verdi viser **hvor den kommer fra** (CPUID-blad, SMBIOS-forskyvning, PCI ID-database, NVMe-loggbyte, produsentbibliotek …) og **hvor sikkert** programmet er på den. Ingen driver trengs for hovedfunksjonene, ingen telemetri.

![FerrumScope, CPU-fanen](../docs/screenshots/cpu.png)

## Innhold

- [Funksjoner](#funksjoner)
- [Skjermbilder](#skjermbilder)
- [Grensesnittspråk](#grensesnittspråk)
- [Hva krever en driver eller administratorrettigheter](#hva-krever-en-driver-eller-administratorrettigheter)
- [Bygging](#bygging)
- [GUI](#gui)
- [Kommandolinje](#kommandolinje)
- [Oppslagslenker](#oppslagslenker)
- [Oppdateringer](#oppdateringer)
- [Capture og replay](#capture-og-replay)
- [Sikkerhetsmodell](#sikkerhetsmodell)
- [Datakilder og lisenser](#datakilder-og-lisenser)

## Funksjoner

- **CPU** — identifikasjon fra CPUID pluss en maskinvaredatabase med sporet opprinnelse (kodenavn, mikroarkitektur, revisjon, sokkel), family/model/stepping, den fullstendige listen over instruksjonssett (MMX … AVX-512, AES, SHA, VT-x/AMD-V) med CPUID-blad og bit for hvert av dem, det utledede x86-64-nivået, hurtigbuffere vist som `8 x 32 KB`, topologi og et klokkeestimat **uten driver** med belastning per kjerne og totalt.
- **Hovedkort** — produsent, modell, revisjon og BIOS (SMBIOS-typene 0/1/2/3/4), brikkesettet utledet fra PCI-ID-er, og hver PCI-enhet navngitt ut fra den innebygde `pci.ids`.
- **Minne** — moduler fra SMBIOS type 17 (spor, størrelse, DDR4/DDR5, hastighet og konfigurert hastighet, produsent, delenummer, rank, spenning), total størrelse og en tydelig merket kanalheuristikk.
- **Grafikk** — DXGI og SetupAPI: navn, vendor/device/subsystem/revision-ID-er, kortnavnet fra `pci.ids`, driverversjon og -dato, dedikert og delt minne, PCIe-lenken. Klokker, temperaturer, vifte, belastning og effekt kommer fra **AMD ADL** eller **NVIDIA NVAPI**, som lastes ved kjøring, kun leses og er valgfrie.
- **Lagring** — modell, fastvare, buss, størrelse og serienummer (maskert). NVMe-helselogg uten administratorrettigheter, SATA SMART som administrator: temperatur, driftstimer, slitasje og en eksplisitt helseregel.
- **Sensorer** — CPU-belastning og -klokke, GPU-sensorer, disktemperaturer. MSR-baserte CPU-sensorer via den valgfrie driveren; hovedkortvifter er oppført som *krever driver (planlagt)*.
- **Rapporteksport** — TXT, HTML og JSON. Serienumre og UUID-er er **maskert som standard**.
- **To visninger** — en kompakt visning i CPU-Z-stil (standard) og en full liste med kilde og sikkerhet for hvert felt (`Ctrl+L`).
- **27 grensesnittspråk**, en **oppdaterer** med stabil kanal og testkanal, og **oppslagsknapper** for TechPowerUp-databasen og produsentenes driversider.

## Skjermbilder

| CPU | Grafikk |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Grafikk](../docs/screenshots/graphics.png) |

| Hovedkort | Minne |
|---|---|
| ![Hovedkort](../docs/screenshots/board.png) | ![Minne](../docs/screenshots/memory.png) |

| Lagring (administrator, SATA SMART) | Visning med full liste |
|---|---|
| ![Lagring](../docs/screenshots/admin_storage.png) | ![Full liste](../docs/screenshots/list_board.png) |

Alle faner og begge visninger: [docs/screenshots](../docs/screenshots).

## Grensesnittspråk

GUI-et, kommandolinjen og TXT/HTML-rapportene er tilgjengelige på 27 språk: polsk (kildespråk), engelsk, bulgarsk, tsjekkisk, dansk, tysk, gresk, spansk, estisk, finsk, fransk, kroatisk, ungarsk, italiensk, litauisk, latvisk, norsk bokmål, nederlandsk, portugisisk (Brasil), rumensk, russisk, slovakisk, slovensk, serbisk (latinsk), svensk, tyrkisk og ukrainsk.

Språket velges i denne rekkefølgen: den lagrede innstillingen (`data\settings.ini`), visningsspråket i Windows, deretter engelsk. Du endrer det i GUI-et (språkvelgeren) eller med `ferrumscope lang <code>` / `--lang=<code>`. Tekniske verdier (instruksjonsnavn, enheter, PCI-ID-er) blir aldri oversatt, og nøklene i JSON-eksporten forblir på engelsk. For oversettere: se [locales/README.md](../locales/README.md).

## Hva krever en driver eller administratorrettigheter

| Data | Krav |
|---|---|
| CPU, hovedkort, minne, grafikk, NVMe-helse, diskbeskrivelser | ingenting (vanlig bruker) |
| SATA SMART | kjør som administrator; uten det sier programmet ifra og fortsetter å fungere |
| APERF/MPERF, temperaturer fra MSR | driveren `FerrumScopeMsr.sys` — **installeres ikke automatisk** |
| Hovedkortvifter/-spenninger (Super I/O), SPD-timinger (SMBus) | en kjernedriver — **planlagt, ikke implementert** |

## Bygging

Kun den fastlåste Zig 0.15.2 trengs.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` bygger og starter GUI-et. Den valgfrie driveren bygges separat med WDK (`driver/build_driver.bat`) og installeres aldri av byggeprosessen.

## GUI

- Faner: CPU, Hurtigbuffer, Hovedkort, Minne, Grafikk, Disker, Sensorer, Bench (plassholder), Om.
- Hold pekeren over en verdi for å se kilden, sikkerheten og råverdien. **Vis kilder** legger til en liten markør ved hvert felt.
- **Full liste** (`Ctrl+L`) viser hvert felt med kilden; valget huskes. `F5` oppdaterer statiske data (SMBIOS, PCI, disker).
- **Merke/logo** på fanene CPU og Grafikk. Prioritet: ditt eget bilde → en medfølgende produsentlogo → et merke tegnet av FerrumScope. Legg dine egne PNG-filer ved siden av programmet i `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (f.eks. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (f.eks. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Navnene skrives med små bokstaver, og hvert tegn som ikke er en bokstav eller et siffer erstattes med `-`. Et klikk på merket åpner oppslagslenken.
- Kommandolinjevalg: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

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

## Oppslagslenker

Knappene **Slå opp** og merket åpner GPU/CPU-databasen til TechPowerUp. Den nøyaktige siden brukes når den er kjent, i denne rekkefølgen:

1. en lenke du har festet selv — kopier sideadressen i nettleseren og klikk **Fest…** ved feltet (lagres i `data\links.toml`);
2. den kuraterte tabellen [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — oppføringene legges til for hånd (`source = "manual"`), aldri ved crawling; pull requests er velkomne;
3. ellers et søk etter navn.

Bare lenker lagres; ingenting lastes ned fra TechPowerUp. Godtatte adresser: `https://` på techpowerup.com eller produsentens nettsted.

## Oppdateringer

FerrumScope sjekker GitHub-utgivelsene til `snakex21/FerrumScope` over HTTPS — høyst én gang om dagen ved oppstart (kan slås av), eller ved behov via **Om → Se etter oppdateringer** / `ferrumscope update --check`. En oppdatering installeres bare når den nedlastede zip-filen samsvarer med **både** SHA-256 i `ferrumscope-update.json` og `SHA256SUMS`; den forrige exe-filen beholdes som `.old` (`ferrumscope update --rollback`), og mappen `data\` (innstillinger, festede lenker, dine bilder) blir aldri rørt. Kanaler: **stable** (standard) og **test** (forhåndsversjoner). Ingen telemetri sendes.

## Capture og replay

`.cpuimg` lagrer rå CPUID-blader; `.sysimg` lagrer rå SMBIOS, PCI-ID-er, DXGI-adaptere og diskbeskrivelser/NVMe-/SMART-sider. Begge er tekstfiler og går gjennom **de samme dekoderne** som direkte data, slik at parserne testes uten maskinvare. `capture-sys` maskerer serienumre og SMBIOS-UUID-en som standard (forskyvningene forblir gyldige). Format: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Sikkerhetsmodell

- GUI-et og CLI-et kjører som vanlig bruker; ingenting installeres.
- Den valgfrie driveren `FerrumScopeMsr.sys` er **skrivebeskyttet**: tre IOCTL-er, en **tillatelsesliste** for MSR (APERF/MPERF), hver forespørsel valideres i kjernen, tilgang til enheten er begrenset til SYSTEM og Administratorer (`IoCreateDeviceSecure`), og det finnes ingen skrivevei i det hele tatt. Den har ennå ikke vært lastet på et ekte system. Detaljer: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Disker mottar bare lesekommandoer (IOCTL-er for lagringsspørringer, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Produsentenes GPU-biblioteker lastes bare fra System32, og bare spørrefunksjoner brukes.
- Serienumre maskeres i GUI-et, rapporter og capture-filer med mindre du uttrykkelig ber om dem.

## Datakilder og lisenser

- Kildekoden til FerrumScope: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **eller** BSD-3-Clause.
- CPU-databasen (`db/source/cpu/*.toml`): hver oppføring oppgir sin kilde (AMD revision guides, modellområder fra Linux-kjernen, offentlige CPUID-dumper). Ingen data fra CPU-Z eller GPU-Z — se [reference/README.md](../reference/README.md).
- `assets/logos/` er **ikke** omfattet av GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA og GeForce er varemerker som tilhører sine respektive eiere; logoene brukes kun til å identifisere maskinvare og innebærer ingen godkjenning. Opprinnelse per fil: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- TechPowerUp-lenker er vanlige lenker som du selv åpner; ingen data fra TechPowerUp lastes ned eller lagres.
