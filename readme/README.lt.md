**Languages:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#kompiliavimas)

Atviras ir skaidrus aparatūros informacijos įrankis Windows sistemai — „CPU-Z + GPU-Z viename“, parašytas Zig kalba. Prie kiekvienos reikšmės parodoma, **iš kur ji gauta** (CPUID lapas, SMBIOS poslinkis, PCI ID duomenų bazė, NVMe žurnalo baitas, gamintojo biblioteka…) ir **kiek** programa ja **tikra**. Pagrindinėms funkcijoms tvarkyklės nereikia, telemetrijos nėra.

![FerrumScope CPU skirtukas](../docs/screenshots/cpu.png)

## Turinys

- [Funkcijos](#funkcijos)
- [Ekrano kopijos](#ekrano-kopijos)
- [Sąsajos kalba](#sąsajos-kalba)
- [Kam reikia tvarkyklės arba administratoriaus teisių](#kam-reikia-tvarkyklės-arba-administratoriaus-teisių)
- [Kompiliavimas](#kompiliavimas)
- [GUI](#gui)
- [Komandinė eilutė](#komandinė-eilutė)
- [Paieškos nuorodos](#paieškos-nuorodos)
- [Naujinimai](#naujinimai)
- [Įrašymas ir atkūrimas](#įrašymas-ir-atkūrimas)
- [Saugos modelis](#saugos-modelis)
- [Duomenų šaltiniai ir licencijos](#duomenų-šaltiniai-ir-licencijos)

## Funkcijos

- **CPU** — identifikavimas pagal CPUID ir aparatūros duomenų bazę, kurios kiekvieno įrašo kilmė atsekama (kodinis pavadinimas, mikroarchitektūra, revizija, lizdas), šeima/modelis/stepping, visas instrukcijų rinkinių sąrašas (MMX … AVX-512, AES, SHA, VT-x/AMD-V) su kiekvieno CPUID lapu ir bitu, išvestas x86-64 lygis, talpyklos formatu `8 x 32 KB`, topologija ir **be tvarkyklės** apskaičiuotas dažnio įvertis su kiekvieno branduolio ir bendra apkrova.
- **Pagrindinė plokštė** — gamintojas, modelis, revizija ir BIOS (SMBIOS tipai 0/1/2/3/4), iš PCI ID nustatytas mikroschemų rinkinys ir kiekvienas PCI įrenginys, pavadintas pagal įtaisytąjį `pci.ids`.
- **Atmintis** — moduliai iš SMBIOS 17 tipo (lizdas, dydis, DDR4/DDR5, sparta ir sukonfigūruota sparta, gamintojas, dalies numeris, rangas, įtampa), bendras dydis ir aiškiai pažymėta kanalų euristika.
- **Grafika** — DXGI ir SetupAPI: pavadinimai, vendor/device/subsystem/revision ID, plokštės pavadinimas iš `pci.ids`, tvarkyklės versija ir data, skirtoji ir bendroji atmintis, PCIe jungtis. Dažniai, temperatūros, ventiliatorius, apkrova ir galia gaunami iš **AMD ADL** arba **NVIDIA NVAPI**, kurios įkeliamos vykdymo metu, tik skaitymui ir pasirinktinai.
- **Atmintinės** — modelis, mikroprograma, magistralė, dydis ir serijos numeris (paslėptas). NVMe būklės žurnalas be administratoriaus teisių, SATA SMART administratoriaus teisėmis: temperatūra, veikimo valandos, nusidėvėjimas ir nurodyta būklės taisyklė.
- **Jutikliai** — CPU apkrova ir dažnis, GPU jutikliai, diskų temperatūros. MSR pagrįsti CPU jutikliai per pasirenkamą tvarkyklę; pagrindinės plokštės ventiliatoriai pažymėti kaip *reikia tvarkyklės (planuojama)*.
- **Ataskaitų eksportas** — TXT, HTML ir JSON. Serijos numeriai ir UUID **pagal numatytuosius nustatymus paslėpti**.
- **Du rodiniai** — kompaktiškas CPU-Z stiliaus rodinys (numatytasis) ir visas sąrašas su kiekvieno lauko šaltiniu ir patikimumu (`Ctrl+L`).
- **27 sąsajos kalbos**, **naujinimo priemonė** su stabiliu ir bandomuoju kanalu, **paieškos** mygtukai TechPowerUp duomenų bazei ir gamintojų tvarkyklių puslapiams.

## Ekrano kopijos

| CPU | Grafika |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Grafika](../docs/screenshots/graphics.png) |

| Pagrindinė plokštė | Atmintis |
|---|---|
| ![Pagrindinė plokštė](../docs/screenshots/board.png) | ![Atmintis](../docs/screenshots/memory.png) |

| Atmintinės (administratorius, SATA SMART) | Viso sąrašo rodinys |
|---|---|
| ![Atmintinės](../docs/screenshots/admin_storage.png) | ![Visas sąrašas](../docs/screenshots/list_board.png) |

Visi skirtukai ir abu rodiniai: [docs/screenshots](../docs/screenshots).

## Sąsajos kalba

GUI, komandinė eilutė ir TXT/HTML ataskaitos prieinamos 27 kalbomis: lenkų (šaltinio kalba), anglų, bulgarų, čekų, danų, vokiečių, graikų, ispanų, estų, suomių, prancūzų, kroatų, vengrų, italų, lietuvių, latvių, norvegų (bokmål), nyderlandų, portugalų (Brazilija), rumunų, rusų, slovakų, slovėnų, serbų (lotyniška), švedų, turkų ir ukrainiečių.

Kalba parenkama tokia tvarka: įrašytas nustatymas (`data\settings.ini`), Windows rodymo kalba, tada anglų. Ją galima pakeisti GUI (kalbos parinkiklis) arba komanda `ferrumscope lang <code>` / `--lang=<code>`. Techninės reikšmės (instrukcijų pavadinimai, vienetai, PCI ID) niekada neverčiamos, o JSON eksporto raktai lieka angliški. Vertėjams: žr. [locales/README.md](../locales/README.md).

## Kam reikia tvarkyklės arba administratoriaus teisių

| Duomenys | Reikalavimas |
|---|---|
| CPU, pagrindinė plokštė, atmintis, grafika, NVMe būklė, diskų aprašai | nieko (paprastas naudotojas) |
| SATA SMART | paleisti administratoriaus teisėmis; be jų programa apie tai praneša ir veikia toliau |
| APERF/MPERF, temperatūros iš MSR | tvarkyklė `FerrumScopeMsr.sys` — **neįdiegiama automatiškai** |
| Pagrindinės plokštės ventiliatoriai/įtampos (Super I/O), SPD laikai (SMBus) | branduolio tvarkyklė — **planuojama, neįgyvendinta** |

## Kompiliavimas

Reikia tik fiksuotos Zig 0.15.2 versijos.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` sukompiliuoja ir paleidžia GUI. Pasirenkama tvarkyklė kompiliuojama atskirai su WDK (`driver/build_driver.bat`) ir kompiliavimo metu niekada neįdiegiama.

## GUI

- Skirtukai: CPU, Talpykla, Pagrindinė plokštė, Atmintis, Grafika, Atmintinės, Jutikliai, Testas (užpildas), Apie.
- Užveskite žymeklį ant reikšmės, kad matytumėte jos šaltinį, patikimumą ir neapdorotą reikšmę. **Rodyti šaltinius** prie kiekvieno lauko prideda mažą žymą.
- **Visas sąrašas** (`Ctrl+L`) rodo kiekvieną lauką su šaltiniu; pasirinkimas įsimenamas. `F5` atnaujina statinius duomenis (SMBIOS, PCI, diskai).
- **Ženklelis/logotipas** CPU ir Grafikos skirtukuose. Pirmenybė: jūsų paveikslėlis → kartu pateiktas gamintojo logotipas → FerrumScope nupieštas ženklelis. Savo PNG failus dėkite šalia programos, aplanke `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (pvz., `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (pvz., `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Pavadinimai rašomi mažosiomis raidėmis, o kiekvienas ne raidinis skaitmeninis simbolis pakeičiamas `-`. Spustelėjus ženklelį atveriama paieškos nuoroda.
- Komandinės eilutės parinktys: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Komandinė eilutė

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

## Paieškos nuorodos

**Ieškoti** mygtukai ir ženklelis atveria TechPowerUp GPU/CPU duomenų bazę. Kai tikslus puslapis žinomas, naudojamas jis, tokia tvarka:

1. jūsų pačių prisegta nuoroda — nukopijuokite puslapio adresą naršyklėje ir spustelėkite **Prisegti…** šalia lauko (įrašoma į `data\links.toml`);
2. prižiūrima lentelė [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — įrašai pridedami rankiniu būdu (`source = "manual"`), niekada ne automatiniu nuskaitymu; pull request'ai laukiami;
3. kitu atveju paieška pagal pavadinimą.

Saugomos tik nuorodos; iš TechPowerUp nieko neatsisiunčiama. Priimami adresai: `https://` svetainėje techpowerup.com arba gamintojo svetainėje.

## Naujinimai

FerrumScope per HTTPS tikrina `snakex21/FerrumScope` GitHub leidimus — ne dažniau kaip kartą per dieną paleidžiant (galima išjungti) arba pareikalavus per **Apie → Tikrinti naujinimus** / `ferrumscope update --check`. Naujinimas įdiegiamas tik tada, kai atsisiųstas zip atitinka **ir** `ferrumscope-update.json`, **ir** `SHA256SUMS` nurodytą SHA-256 sumą; ankstesnis exe išsaugomas kaip `.old` (`ferrumscope update --rollback`), o aplankas `data\` (nustatymai, prisegtos nuorodos, jūsų paveikslėliai) niekada neliečiamas. Kanalai: **stable** (numatytasis) ir **test** (išankstinės versijos). Telemetrija nesiunčiama.

## Įrašymas ir atkūrimas

`.cpuimg` saugo neapdorotus CPUID lapus; `.sysimg` saugo neapdorotus SMBIOS, PCI ID, DXGI adapterius ir diskų aprašus bei NVMe/SMART puslapius. Abu yra tekstiniai failai ir apdorojami **tais pačiais dekoderiais** kaip ir tiesioginiai duomenys, todėl analizatoriai testuojami be aparatūros. `capture-sys` pagal numatytuosius nustatymus paslepia serijos numerius ir SMBIOS UUID (poslinkiai lieka galiojantys). Formatas: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Saugos modelis

- GUI ir CLI veikia kaip paprastas naudotojas; nieko neįdiegiama.
- Pasirenkama tvarkyklė `FerrumScopeMsr.sys` yra **tik skaitymui**: trys IOCTL, MSR **leidžiamųjų sąrašas** (APERF/MPERF), kiekviena užklausa tikrinama branduolyje, prieiga prie įrenginio apribota SYSTEM ir administratoriams (`IoCreateDeviceSecure`), rašymo kelio visai nėra. Ji dar nebuvo įkelta realioje sistemoje. Išsamiau: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Diskams siunčiamos tik skaitymo komandos (saugyklos užklausų IOCTL, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Gamintojų GPU bibliotekos įkeliamos tik iš System32 ir naudojamos tik užklausų funkcijos.
- Serijos numeriai GUI, ataskaitose ir įrašuose paslepiami, nebent aiškiai jų paprašote.

## Duomenų šaltiniai ir licencijos

- FerrumScope pirminis kodas: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **arba** BSD-3-Clause.
- CPU duomenų bazė (`db/source/cpu/*.toml`): kiekvienas įrašas nurodo savo šaltinį (AMD revizijų vadovai, Linux branduolio modelių intervalai, vieši CPUID išrašai). Jokių CPU-Z ar GPU-Z duomenų — žr. [reference/README.md](../reference/README.md).
- `assets/logos/` **netaikoma** GPL licencija. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA ir GeForce yra atitinkamų savininkų prekių ženklai; logotipai naudojami tik aparatūrai identifikuoti ir nereiškia jokio pritarimo. Kiekvieno failo kilmė: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- TechPowerUp nuorodos yra paprastos nuorodos, kurias atveriate jūs; TechPowerUp duomenys neatsisiunčiami ir nesaugomi.
