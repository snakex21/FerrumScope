**Languages:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#bouwen)

Een open, transparant hulpprogramma voor hardware-informatie onder Windows — "CPU-Z + GPU-Z in één", geschreven in Zig. Bij elke waarde staat **waar die vandaan komt** (CPUID-leaf, SMBIOS-offset, PCI ID-database, NVMe-logbyte, bibliotheek van de fabrikant…) en **hoe zeker** het programma ervan is. Voor de belangrijkste functies is geen stuurprogramma nodig, en er is geen telemetrie.

![FerrumScope-tabblad CPU](../docs/screenshots/cpu.png)

## Inhoud

- [Functies](#functies)
- [Schermafbeeldingen](#schermafbeeldingen)
- [Interfacetaal](#interfacetaal)
- [Wat een stuurprogramma of beheerdersrechten vereist](#wat-een-stuurprogramma-of-beheerdersrechten-vereist)
- [Bouwen](#bouwen)
- [GUI](#gui)
- [Opdrachtregel](#opdrachtregel)
- [Opzoeklinks](#opzoeklinks)
- [Updates](#updates)
- [Capture en replay](#capture-en-replay)
- [Beveiligingsmodel](#beveiligingsmodel)
- [Gegevensbronnen en licenties](#gegevensbronnen-en-licenties)

## Functies

- **CPU** — identificatie via CPUID plus een hardwaredatabase met bijgehouden herkomst (codenaam, microarchitectuur, revisie, socket), familie/model/stepping, de volledige lijst met instructiesets (MMX … AVX-512, AES, SHA, VT-x/AMD-V) met bij elke instructieset de CPUID-leaf en -bit, het afgeleide x86-64-niveau, caches weergegeven als `8 x 32 KB`, topologie en een kloksnelheidsschatting **zonder stuurprogramma** met belasting per kern en in totaal.
- **Moederbord** — fabrikant, model, revisie en BIOS (SMBIOS-typen 0/1/2/3/4), de chipset afgeleid uit PCI-ID's, en elk PCI-apparaat met een naam uit de ingebouwde `pci.ids`.
- **Geheugen** — modules uit SMBIOS type 17 (sleuf, grootte, DDR4/DDR5, snelheid en geconfigureerde snelheid, fabrikant, onderdeelnummer, rank, spanning), de totale grootte en een duidelijk gemarkeerde heuristiek voor kanalen.
- **Grafisch** — DXGI en SetupAPI: namen, vendor-/device-/subsystem-/revisie-ID's, de kaartnaam uit `pci.ids`, versie en datum van het stuurprogramma, toegewezen en gedeeld geheugen, de PCIe-link. Klokken, temperaturen, ventilator, belasting en vermogen komen uit **AMD ADL** of **NVIDIA NVAPI**, die tijdens het uitvoeren worden geladen, alleen-lezen en optioneel.
- **Opslag** — model, firmware, bus, grootte en serienummer (gemaskeerd). NVMe-statuslog zonder beheerdersrechten, SATA SMART als administrator: temperatuur, inschakeluren, slijtage en een vermelde gezondheidsregel.
- **Sensoren** — CPU-belasting en -klok, GPU-sensoren, schijftemperaturen. CPU-sensoren op basis van MSR via het optionele stuurprogramma; ventilatoren van het moederbord worden vermeld als *vereist stuurprogramma (gepland)*.
- **Rapportexport** — TXT, HTML en JSON. Serienummers en UUID's worden **standaard gemaskeerd**.
- **Twee weergaven** — een compacte weergave in CPU-Z-stijl (standaard) en een volledige lijst met de bron en betrouwbaarheid van elk veld (`Ctrl+L`).
- **27 interfacetalen**, een **updater** met een stabiel en een testkanaal, en **opzoek**knoppen voor de TechPowerUp-database en de stuurprogrammapagina's van fabrikanten.

## Schermafbeeldingen

| CPU | Grafisch |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Grafisch](../docs/screenshots/graphics.png) |

| Moederbord | Geheugen |
|---|---|
| ![Moederbord](../docs/screenshots/board.png) | ![Geheugen](../docs/screenshots/memory.png) |

| Opslag (administrator, SATA SMART) | Weergave als volledige lijst |
|---|---|
| ![Opslag](../docs/screenshots/admin_storage.png) | ![Volledige lijst](../docs/screenshots/list_board.png) |

Alle tabbladen en beide weergaven: [docs/screenshots](../docs/screenshots).

## Interfacetaal

De GUI, de opdrachtregel en de TXT/HTML-rapporten zijn beschikbaar in 27 talen: Pools (brontaal), Engels, Bulgaars, Tsjechisch, Deens, Duits, Grieks, Spaans, Estisch, Fins, Frans, Kroatisch, Hongaars, Italiaans, Litouws, Lets, Noors (Bokmål), Nederlands, Portugees (Brazilië), Roemeens, Russisch, Slowaaks, Sloveens, Servisch (Latijns schrift), Zweeds, Turks en Oekraïens.

De taal wordt in deze volgorde gekozen: de opgeslagen instelling (`data\settings.ini`), de weergavetaal van Windows, en anders Engels. Wijzig de taal in de GUI (taalkeuzelijst) of met `ferrumscope lang <code>` / `--lang=<code>`. Technische waarden (instructienamen, eenheden, PCI-ID's) worden nooit vertaald, en de sleutels van de JSON-export blijven in het Engels. Vertalers: zie [locales/README.md](../locales/README.md).

## Wat een stuurprogramma of beheerdersrechten vereist

| Gegevens | Vereiste |
|---|---|
| CPU, moederbord, geheugen, grafisch, NVMe-status, schijfdescriptors | niets (gewone gebruiker) |
| SATA SMART | uitvoeren als administrator; zonder dat meldt het programma dit en blijft het werken |
| APERF/MPERF, temperaturen uit MSR | het stuurprogramma `FerrumScopeMsr.sys` — **wordt niet automatisch geïnstalleerd** |
| Ventilatoren/spanningen van het moederbord (Super I/O), SPD-timings (SMBus) | een kernelstuurprogramma — **gepland, niet geïmplementeerd** |

## Bouwen

Alleen de vastgezette versie Zig 0.15.2 is nodig.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` bouwt en start de GUI. Het optionele stuurprogramma wordt apart gebouwd met de WDK (`driver/build_driver.bat`) en wordt nooit door de build geïnstalleerd.

## GUI

- Tabbladen: CPU, Cache, Moederbord, Geheugen, Grafisch, Opslag, Sensoren, Bench (placeholder), Over.
- Beweeg de muis over een waarde om de bron, betrouwbaarheid en ruwe waarde te zien. **Bronnen tonen** voegt naast elk veld een kleine markering toe.
- **Volledige lijst** (`Ctrl+L`) toont elk veld met zijn bron; de keuze wordt onthouden. `F5` vernieuwt de statische gegevens (SMBIOS, PCI, schijven).
- **Badge/logo** op de tabbladen CPU en Grafisch. Prioriteit: uw eigen afbeelding → een meegeleverd logo van de fabrikant → een badge getekend door FerrumScope. Plaats uw eigen PNG-bestanden naast het programma in `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (bijv. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (bijv. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Namen zijn in kleine letters, waarbij elk niet-alfanumeriek teken is vervangen door `-`. Een klik op de badge opent de opzoeklink.
- Opdrachtregelopties: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Opdrachtregel

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

## Opzoeklinks

De knoppen **Zoeken** en de badge openen de GPU-/CPU-database van TechPowerUp. Als de exacte pagina bekend is, wordt die gebruikt, in deze volgorde:

1. een link die u zelf hebt vastgezet — kopieer het paginaadres in uw browser en klik op **Vastzetten…** naast het veld (opgeslagen in `data\links.toml`);
2. de samengestelde tabel [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — vermeldingen worden met de hand toegevoegd (`source = "manual"`), nooit door crawlen; pull requests zijn welkom;
3. anders een zoekopdracht op naam.

Er worden alleen links opgeslagen; er wordt niets van TechPowerUp gedownload. Geaccepteerde adressen: `https://` op techpowerup.com of op de site van de fabrikant.

## Updates

FerrumScope controleert de GitHub-releases van `snakex21/FerrumScope` via HTTPS — hoogstens één keer per dag bij het starten (kan worden uitgeschakeld), of op verzoek via **Over → Controleren op updates** / `ferrumscope update --check`. Een update wordt pas geïnstalleerd als de gedownloade zip overeenkomt met **zowel** de SHA-256 in `ferrumscope-update.json` als `SHA256SUMS`; de vorige exe wordt bewaard als `.old` (`ferrumscope update --rollback`) en de map `data\` (instellingen, vastgezette links, uw afbeeldingen) wordt nooit aangeraakt. Kanalen: **stabiel** (standaard) en **test** (pre-releases). Er wordt geen telemetrie verzonden.

## Capture en replay

`.cpuimg` bevat ruwe CPUID-leaves; `.sysimg` bevat ruwe SMBIOS-gegevens, PCI-ID's, DXGI-adapters en schijfdescriptors/NVMe-/SMART-pagina's. Beide zijn tekstbestanden en gaan door **dezelfde decoders** als live gegevens, zodat de parsers zonder hardware worden getest. `capture-sys` maskeert standaard serienummers en de SMBIOS-UUID (offsets blijven geldig). Formaat: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Beveiligingsmodel

- De GUI en de CLI draaien als gewone gebruiker; er wordt niets geïnstalleerd.
- Het optionele stuurprogramma `FerrumScopeMsr.sys` is **alleen-lezen**: drie IOCTL's, een **allowlist** voor MSR's (APERF/MPERF), elke aanvraag wordt in de kernel gevalideerd, toegang tot het apparaat is beperkt tot SYSTEM en Administrators (`IoCreateDeviceSecure`), en er is helemaal geen schrijfpad. Het is nog niet op een echt systeem geladen. Details: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Schijven ontvangen alleen leesopdrachten (storage query IOCTL's, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- GPU-bibliotheken van fabrikanten worden alleen uit System32 geladen, en alleen queryfuncties worden gebruikt.
- Serienummers worden gemaskeerd in de GUI, rapporten en captures, tenzij u er uitdrukkelijk om vraagt.

## Gegevensbronnen en licenties

- Broncode van FerrumScope: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **of** BSD-3-Clause.
- CPU-database (`db/source/cpu/*.toml`): elke vermelding noemt haar bron (revision guides van AMD, modelbereiken uit de Linux-kernel, openbare CPUID-dumps). Geen gegevens uit CPU-Z of GPU-Z — zie [reference/README.md](../reference/README.md).
- `assets/logos/` valt **niet** onder de GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA en GeForce zijn handelsmerken van hun respectieve eigenaars; de logo's worden uitsluitend gebruikt om hardware te identificeren en impliceren geen goedkeuring of steun. Herkomst per bestand: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- Links naar TechPowerUp zijn gewone links die u zelf opent; er worden geen gegevens van TechPowerUp gedownload of opgeslagen.
