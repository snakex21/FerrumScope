**Jazyky:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#zostavenie)

Otvorený a transparentný nástroj na zobrazenie informácií o hardvéri pre Windows — „CPU-Z + GPU-Z v jednom“, napísaný v jazyku Zig. Pri každej hodnote je uvedené, **odkiaľ pochádza** (list CPUID, offset SMBIOS, databáza PCI ID, bajt logu NVMe, knižnica výrobcu…) a **s akou istotou** ju program uvádza. Hlavné funkcie nevyžadujú ovládač, žiadna telemetria.

![Karta CPU programu FerrumScope](../docs/screenshots/cpu.png)

## Obsah

- [Funkcie](#funkcie)
- [Snímky obrazovky](#snímky-obrazovky)
- [Jazyk rozhrania](#jazyk-rozhrania)
- [Čo vyžaduje ovládač alebo práva správcu](#čo-vyžaduje-ovládač-alebo-práva-správcu)
- [Zostavenie](#zostavenie)
- [GUI](#gui)
- [Príkazový riadok](#príkazový-riadok)
- [Vyhľadávacie odkazy](#vyhľadávacie-odkazy)
- [Aktualizácie](#aktualizácie)
- [Capture a replay](#capture-a-replay)
- [Model zabezpečenia](#model-zabezpečenia)
- [Zdroje údajov a licencie](#zdroje-údajov-a-licencie)

## Funkcie

- **CPU** — identifikácia z CPUID a z hardvérovej databázy so sledovaným pôvodom záznamov (kódové označenie, mikroarchitektúra, revízia, pätica), rodina/model/stepping, úplný zoznam inštrukčných sád (MMX … AVX-512, AES, SHA, VT-x/AMD-V) s listom a bitom CPUID pri každej z nich, odvodená úroveň x86-64, cache zobrazené ako `8 x 32 KB`, topológia a odhad taktu **bez ovládača** so záťažou jednotlivých jadier aj celkovou.
- **Základná doska** — výrobca, model, revízia a BIOS (SMBIOS typy 0/1/2/3/4), čipová sada odvodená z PCI ID a všetky zariadenia PCI pomenované podľa vstavaného `pci.ids`.
- **Pamäť** — moduly zo SMBIOS typ 17 (slot, veľkosť, DDR4/DDR5, rýchlosť a nastavená rýchlosť, výrobca, číslo dielu, rank, napätie), celková veľkosť a zreteľne označená heuristika kanálov.
- **Grafika** — DXGI a SetupAPI: názvy, ID výrobcu/zariadenia/subsystému/revízie, názov karty z `pci.ids`, verzia a dátum ovládača, vyhradená a zdieľaná pamäť, linka PCIe. Takty, teploty, ventilátor, záťaž a príkon pochádzajú z **AMD ADL** alebo **NVIDIA NVAPI**, ktoré sa načítavajú za behu, len na čítanie a voliteľne.
- **Disky** — model, firmvér, zbernica, veľkosť a sériové číslo (maskované). Log stavu NVMe bez práv správcu, SATA SMART ako správca: teplota, hodiny prevádzky, opotrebenie a uvedené pravidlo hodnotenia stavu.
- **Snímače** — záťaž a takt CPU, snímače GPU, teploty diskov. Snímače CPU založené na MSR cez voliteľný ovládač; ventilátory základnej dosky sú uvedené ako *vyžaduje ovládač (plánované)*.
- **Export správy** — TXT, HTML a JSON. Sériové čísla a UUID sú **predvolene maskované**.
- **Dve zobrazenia** — kompaktné zobrazenie v štýle CPU-Z (predvolené) a úplný zoznam so zdrojom a istotou každého poľa (`Ctrl+L`).
- **27 jazykov rozhrania**, **aktualizátor** so stabilným a testovacím kanálom, tlačidlá **vyhľadávania** v databáze TechPowerUp a na stránkach ovládačov výrobcov.

## Snímky obrazovky

| CPU | Grafika |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Grafika](../docs/screenshots/graphics.png) |

| Základná doska | Pamäť |
|---|---|
| ![Základná doska](../docs/screenshots/board.png) | ![Pamäť](../docs/screenshots/memory.png) |

| Disky (správca, SATA SMART) | Zobrazenie úplného zoznamu |
|---|---|
| ![Disky](../docs/screenshots/admin_storage.png) | ![Úplný zoznam](../docs/screenshots/list_board.png) |

Všetky karty a obe zobrazenia: [docs/screenshots](../docs/screenshots).

## Jazyk rozhrania

GUI, príkazový riadok a správy TXT/HTML sú k dispozícii v 27 jazykoch: poľština (zdrojový jazyk), angličtina, bulharčina, čeština, dánčina, nemčina, gréčtina, španielčina, estónčina, fínčina, francúzština, chorvátčina, maďarčina, taliančina, litovčina, lotyština, nórčina (bokmål), holandčina, portugalčina (Brazília), rumunčina, ruština, slovenčina, slovinčina, srbčina (latinka), švédčina, turečtina a ukrajinčina.

Jazyk sa vyberá v tomto poradí: uložené nastavenie (`data\settings.ini`), jazyk zobrazenia Windows a nakoniec angličtina. Zmeniť ho môžete v GUI (výber jazyka) alebo príkazom `ferrumscope lang <code>` / `--lang=<code>`. Technické hodnoty (názvy inštrukcií, jednotky, PCI ID) sa nikdy neprekladajú a kľúče exportu JSON zostávajú v angličtine. Pre prekladateľov: pozri [locales/README.md](../locales/README.md).

## Čo vyžaduje ovládač alebo práva správcu

| Údaje | Požiadavka |
|---|---|
| CPU, základná doska, pamäť, grafika, stav NVMe, deskriptory diskov | nič (bežný používateľ) |
| SATA SMART | spustenie ako správca; bez toho to program oznámi a funguje ďalej |
| APERF/MPERF, teploty z MSR | ovládač `FerrumScopeMsr.sys` — **neinštaluje sa automaticky** |
| Ventilátory/napätia základnej dosky (Super I/O), časovania SPD (SMBus) | ovládač jadra — **plánované, neimplementované** |

## Zostavenie

Potrebný je iba pevne určený Zig 0.15.2.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` zostaví a spustí GUI. Voliteľný ovládač sa zostavuje samostatne pomocou WDK (`driver/build_driver.bat`) a zostavenie ho nikdy neinštaluje.

## GUI

- Karty: CPU, Cache, Základná doska, Pamäť, Grafika, Disky, Snímače, Bench (zatiaľ prázdna), O programe.
- Podržaním kurzora nad hodnotou zobrazíte jej zdroj, istotu a surovú hodnotu. **Zobraziť zdroje** pridá ku každému poľu malú značku.
- **Úplný zoznam** (`Ctrl+L`) zobrazí všetky polia s ich zdrojom; voľba sa zapamätá. `F5` obnoví statické údaje (SMBIOS, PCI, disky).
- **Štítok/logo** na kartách CPU a Grafika. Priorita: vlastný obrázok → priložené logo výrobcu → štítok nakreslený programom FerrumScope. Vlastné súbory PNG umiestnite vedľa programu do `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (napr. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (napr. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Názvy sú malými písmenami a každý znak, ktorý nie je písmeno ani číslica, je nahradený znakom `-`. Kliknutím na štítok sa otvorí vyhľadávací odkaz.
- Voľby príkazového riadka: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Príkazový riadok

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

## Vyhľadávacie odkazy

Tlačidlá **Vyhľadať** a štítok otvárajú databázu GPU/CPU TechPowerUp. Ak je presná stránka známa, použije sa v tomto poradí:

1. odkaz, ktorý ste si sami pripli — skopírujte adresu stránky v prehliadači a kliknite na **Pripnúť…** vedľa poľa (uloží sa do `data\links.toml`);
2. kurátorovaná tabuľka [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — záznamy sa pridávajú ručne (`source = "manual"`), nikdy nie automatickým prehľadávaním webu; pull requesty sú vítané;
3. inak vyhľadávanie podľa názvu.

Ukladajú sa iba odkazy; z TechPowerUp sa nič nesťahuje. Prijímané adresy: `https://` na techpowerup.com alebo na stránke výrobcu.

## Aktualizácie

FerrumScope kontroluje vydania `snakex21/FerrumScope` na GitHube cez HTTPS — najviac raz denne pri štarte (dá sa vypnúť) alebo na požiadanie v **O programe → Skontrolovať aktualizácie** / `ferrumscope update --check`. Aktualizácia sa nainštaluje iba vtedy, keď stiahnutý zip zodpovedá **zároveň** súčtu SHA-256 v `ferrumscope-update.json` aj v `SHA256SUMS`; predchádzajúci exe sa zachová ako `.old` (`ferrumscope update --rollback`) a priečinok `data\` (nastavenia, pripnuté odkazy, vaše obrázky) sa nikdy nemení. Kanály: **stabilný** (predvolený) a **testovací** (predbežné vydania). Neodosiela sa žiadna telemetria.

## Capture a replay

`.cpuimg` uchováva surové listy CPUID; `.sysimg` uchováva surové SMBIOS, PCI ID, adaptéry DXGI a deskriptory diskov/stránky NVMe/SMART. Oba sú textové súbory a prechádzajú **rovnakými dekódermi** ako živé údaje, takže parsery sa testujú bez hardvéru. `capture-sys` predvolene maskuje sériové čísla a UUID zo SMBIOS (offsety zostávajú platné). Formát: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Model zabezpečenia

- GUI a CLI bežia ako bežný používateľ; nič sa neinštaluje.
- Voliteľný ovládač `FerrumScopeMsr.sys` je **len na čítanie**: tri IOCTL, **zoznam povolených** MSR (APERF/MPERF), každá požiadavka sa overuje v jadre, prístup k zariadeniu je obmedzený na SYSTEM a Administrators (`IoCreateDeviceSecure`), neexistuje žiadna cesta zápisu. Na skutočnom systéme ešte nebol načítaný. Podrobnosti: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Disky dostávajú iba príkazy na čítanie (IOCTL dotazov na úložisko, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Knižnice GPU od výrobcov sa načítavajú iba zo System32 a používajú sa iba dotazovacie funkcie.
- Sériové čísla sú v GUI, správach a súboroch capture maskované, pokiaľ ich výslovne nepožadujete.

## Zdroje údajov a licencie

- Zdrojový kód FerrumScope: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **alebo** BSD-3-Clause.
- Databáza CPU (`db/source/cpu/*.toml`): každý záznam uvádza svoj zdroj (revision guides AMD, rozsahy modelov z jadra Linuxu, verejné výpisy CPUID). Žiadne údaje z CPU-Z ani GPU-Z — pozri [reference/README.md](../reference/README.md).
- Na `assets/logos/` sa licencia GPL **nevzťahuje**. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA a GeForce sú ochranné známky príslušných vlastníkov; logá sa používajú iba na identifikáciu hardvéru a neznamenajú žiadnu podporu ani schválenie. Pôvod jednotlivých súborov: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- Odkazy na TechPowerUp sú obyčajné odkazy, ktoré otvárate vy; žiadne údaje z TechPowerUp sa nesťahujú ani neukladajú.
