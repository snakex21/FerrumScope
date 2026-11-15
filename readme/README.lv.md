**Languages:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#būvēšana)

Atvērts un caurskatāms aparatūras informācijas rīks Windows sistēmai — “CPU-Z + GPU-Z vienā”, rakstīts Zig valodā. Katrai vērtībai tiek parādīts, **no kurienes tā iegūta** (CPUID lapa, SMBIOS nobīde, PCI ID datubāze, NVMe žurnāla baits, ražotāja bibliotēka…) un **cik pārliecināta** par to ir programma. Galvenajām funkcijām draiveris nav vajadzīgs, telemetrijas nav.

![FerrumScope CPU cilne](../docs/screenshots/cpu.png)

## Saturs

- [Iespējas](#iespējas)
- [Ekrānuzņēmumi](#ekrānuzņēmumi)
- [Saskarnes valoda](#saskarnes-valoda)
- [Kam vajag draiveri vai administratora tiesības](#kam-vajag-draiveri-vai-administratora-tiesības)
- [Būvēšana](#būvēšana)
- [GUI](#gui)
- [Komandrinda](#komandrinda)
- [Meklēšanas saites](#meklēšanas-saites)
- [Atjauninājumi](#atjauninājumi)
- [Ierakstīšana un atskaņošana](#ierakstīšana-un-atskaņošana)
- [Drošības modelis](#drošības-modelis)
- [Datu avoti un licences](#datu-avoti-un-licences)

## Iespējas

- **CPU** — identificēšana no CPUID kopā ar aparatūras datubāzi, kuras katra ieraksta izcelsme ir izsekojama (koda nosaukums, mikroarhitektūra, revīzija, ligzda), saime/modelis/stepping, pilns instrukciju kopu saraksts (MMX … AVX-512, AES, SHA, VT-x/AMD-V) ar katras CPUID lapu un bitu, atvasinātais x86-64 līmenis, kešatmiņas formātā `8 x 32 KB`, topoloģija un **bez draivera** iegūts takts novērtējums ar katra kodola un kopējo noslodzi.
- **Mātesplate** — ražotājs, modelis, revīzija un BIOS (SMBIOS tipi 0/1/2/3/4), no PCI ID atvasināts mikroshēmojums un katra PCI ierīce ar nosaukumu no iebūvētā `pci.ids`.
- **Atmiņa** — moduļi no SMBIOS 17. tipa (slots, izmērs, DDR4/DDR5, ātrums un konfigurētais ātrums, ražotājs, daļas numurs, rangs, spriegums), kopējais izmērs un skaidri apzīmēta kanālu heiristika.
- **Grafika** — DXGI un SetupAPI: nosaukumi, vendor/device/subsystem/revision ID, kartes nosaukums no `pci.ids`, draivera versija un datums, atvēlētā un koplietojamā atmiņa, PCIe saite. Takts, temperatūras, ventilators, noslodze un jauda tiek iegūti no **AMD ADL** vai **NVIDIA NVAPI**, kas tiek ielādētas izpildes laikā, tikai lasīšanai un neobligāti.
- **Krātuve** — modelis, programmaparatūra, kopne, izmērs un sērijas numurs (maskēts). NVMe veselības žurnāls bez administratora tiesībām, SATA SMART kā administratoram: temperatūra, darba stundas, nolietojums un norādīts veselības noteikums.
- **Sensori** — CPU noslodze un takts, GPU sensori, disku temperatūras. MSR CPU sensori caur neobligātu draiveri; mātesplates ventilatori ir atzīmēti kā *vajag draiveri (plānots)*.
- **Atskaites eksports** — TXT, HTML un JSON. Sērijas numuri un UUID **pēc noklusējuma ir maskēti**.
- **Divi skati** — kompakts CPU-Z stila skats (noklusējums) un pilns saraksts ar katra lauka avotu un ticamību (`Ctrl+L`).
- **27 saskarnes valodas**, **atjauninātājs** ar stabilo un testa kanālu, **meklēšanas** pogas TechPowerUp datubāzei un ražotāju draiveru lapām.

## Ekrānuzņēmumi

| CPU | Grafika |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Grafika](../docs/screenshots/graphics.png) |

| Mātesplate | Atmiņa |
|---|---|
| ![Mātesplate](../docs/screenshots/board.png) | ![Atmiņa](../docs/screenshots/memory.png) |

| Krātuve (administrators, SATA SMART) | Pilnā saraksta skats |
|---|---|
| ![Krātuve](../docs/screenshots/admin_storage.png) | ![Pilns saraksts](../docs/screenshots/list_board.png) |

Visas cilnes un abi skati: [docs/screenshots](../docs/screenshots).

## Saskarnes valoda

GUI, komandrinda un TXT/HTML atskaites ir pieejamas 27 valodās: poļu (avota valoda), angļu, bulgāru, čehu, dāņu, vācu, grieķu, spāņu, igauņu, somu, franču, horvātu, ungāru, itāļu, lietuviešu, latviešu, norvēģu (bokmål), nīderlandiešu, portugāļu (Brazīlija), rumāņu, krievu, slovāku, slovēņu, serbu (latīņu), zviedru, turku un ukraiņu.

Valoda tiek izvēlēta šādā secībā: saglabātais iestatījums (`data\settings.ini`), Windows attēlošanas valoda, tad angļu. To var mainīt GUI (valodas izvēlne) vai ar `ferrumscope lang <code>` / `--lang=<code>`. Tehniskās vērtības (instrukciju nosaukumi, mērvienības, PCI ID) nekad netiek tulkotas, un JSON eksporta atslēgas paliek angļu valodā. Tulkotājiem: skatiet [locales/README.md](../locales/README.md).

## Kam vajag draiveri vai administratora tiesības

| Dati | Prasība |
|---|---|
| CPU, mātesplate, atmiņa, grafika, NVMe veselība, disku deskriptori | nekas (parasts lietotājs) |
| SATA SMART | palaišana kā administratoram; bez tā programma par to paziņo un turpina darbu |
| APERF/MPERF, temperatūras no MSR | draiveris `FerrumScopeMsr.sys` — **netiek instalēts automātiski** |
| Mātesplates ventilatori/spriegumi (Super I/O), SPD taimingi (SMBus) | kodola draiveris — **plānots, nav realizēts** |

## Būvēšana

Vajadzīga tikai fiksētā Zig 0.15.2 versija.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` uzbūvē un palaiž GUI. Neobligātais draiveris tiek būvēts atsevišķi ar WDK (`driver/build_driver.bat`), un būvēšana to nekad neinstalē.

## GUI

- Cilnes: CPU, Kešatmiņa, Mātesplate, Atmiņa, Grafika, Krātuve, Sensori, Tests (aizstājējs), Par programmu.
- Novietojiet kursoru uz vērtības, lai redzētu tās avotu, ticamību un neapstrādāto vērtību. **Rādīt avotus** pie katra lauka pievieno nelielu atzīmi.
- **Pilns saraksts** (`Ctrl+L`) parāda katru lauku ar tā avotu; izvēle tiek atcerēta. `F5` atsvaidzina statiskos datus (SMBIOS, PCI, diski).
- **Emblēma/logotips** CPU un Grafikas cilnē. Prioritāte: jūsu attēls → komplektā iekļautais ražotāja logotips → FerrumScope zīmēta emblēma. Savus PNG failus novietojiet blakus programmai mapē `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (piem., `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (piem., `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Nosaukumi tiek rakstīti ar mazajiem burtiem, un katra rakstzīme, kas nav burts vai cipars, tiek aizstāta ar `-`. Noklikšķinot uz emblēmas, tiek atvērta meklēšanas saite.
- Komandrindas opcijas: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Komandrinda

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

## Meklēšanas saites

**Meklēt** pogas un emblēma atver TechPowerUp GPU/CPU datubāzi. Ja precīzā lapa ir zināma, tiek izmantota tā, šādā secībā:

1. jūsu pašu piesprausta saite — nokopējiet lapas adresi pārlūkā un noklikšķiniet **Piespraust…** blakus laukam (saglabājas `data\links.toml`);
2. uzturētā tabula [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — ieraksti tiek pievienoti manuāli (`source = "manual"`), nekad ar automātisku rāpošanu; pull request ir gaidīti;
3. citādi meklēšana pēc nosaukuma.

Tiek saglabātas tikai saites; no TechPowerUp nekas netiek lejupielādēts. Pieņemtās adreses: `https://` vietnē techpowerup.com vai ražotāja vietnē.

## Atjauninājumi

FerrumScope caur HTTPS pārbauda `snakex21/FerrumScope` GitHub laidienus — ne biežāk kā reizi dienā startējot (var izslēgt) vai pēc pieprasījuma sadaļā **Par programmu → Pārbaudīt atjauninājumus** / `ferrumscope update --check`. Atjauninājums tiek instalēts tikai tad, ja lejupielādētais zip atbilst SHA-256 summai **gan** failā `ferrumscope-update.json`, **gan** `SHA256SUMS`; iepriekšējais exe tiek saglabāts kā `.old` (`ferrumscope update --rollback`), un mape `data\` (iestatījumi, piespraustās saites, jūsu attēli) nekad netiek aizskarta. Kanāli: **stable** (noklusējums) un **test** (pirmsizlaides versijas). Telemetrija netiek sūtīta.

## Ierakstīšana un atskaņošana

`.cpuimg` saglabā neapstrādātas CPUID lapas; `.sysimg` saglabā neapstrādātu SMBIOS, PCI ID, DXGI adapterus un disku deskriptorus, kā arī NVMe/SMART lapas. Abi ir teksta faili un iet caur **tiem pašiem dekoderiem** kā tiešie dati, tāpēc parsētāji tiek testēti bez aparatūras. `capture-sys` pēc noklusējuma maskē sērijas numurus un SMBIOS UUID (nobīdes paliek derīgas). Formāts: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Drošības modelis

- GUI un CLI darbojas kā parasts lietotājs; nekas netiek instalēts.
- Neobligātais draiveris `FerrumScopeMsr.sys` ir **tikai lasīšanai**: trīs IOCTL, MSR **atļauto saraksts** (APERF/MPERF), katrs pieprasījums tiek pārbaudīts kodolā, piekļuve ierīcei ir ierobežota līdz SYSTEM un administratoriem (`IoCreateDeviceSecure`), rakstīšanas ceļa vispār nav. Tas vēl nav ielādēts reālā sistēmā. Sīkāk: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Diskiem tiek sūtītas tikai lasīšanas komandas (krātuves vaicājumu IOCTL, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Ražotāju GPU bibliotēkas tiek ielādētas tikai no System32, un tiek izmantotas tikai vaicājumu funkcijas.
- Sērijas numuri GUI, atskaitēs un ierakstos ir maskēti, ja vien jūs tos skaidri nepieprasāt.

## Datu avoti un licences

- FerrumScope pirmkods: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **vai** BSD-3-Clause.
- CPU datubāze (`db/source/cpu/*.toml`): katrs ieraksts norāda savu avotu (AMD revīziju rokasgrāmatas, Linux kodola modeļu diapazoni, publiski CPUID izmeti). Nav datu no CPU-Z vai GPU-Z — skatiet [reference/README.md](../reference/README.md).
- Uz `assets/logos/` GPL **neattiecas**. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA un GeForce ir to attiecīgo īpašnieku preču zīmes; logotipi tiek izmantoti tikai aparatūras identificēšanai un nenozīmē nekādu atbalstu. Katra faila izcelsme: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- TechPowerUp saites ir parastas saites, kuras atverat jūs; TechPowerUp dati netiek lejupielādēti vai saglabāti.
