**Jezici:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#izgradnja)

Otvoren i transparentan alat za informacije o hardveru za Windows — „CPU-Z + GPU-Z u jednom”, napisan u jeziku Zig. Za svaku vrednost prikazuje se **odakle potiče** (CPUID list, SMBIOS pomak, baza PCI ID-ova, bajt NVMe loga, biblioteka proizvođača…) i **koliko je program siguran** u nju. Za glavne funkcije nije potreban drajver, nema telemetrije.

![FerrumScope, kartica CPU](../docs/screenshots/cpu.png)

## Sadržaj

- [Funkcije](#funkcije)
- [Snimci ekrana](#snimci-ekrana)
- [Jezik interfejsa](#jezik-interfejsa)
- [Šta zahteva drajver ili administratorska prava](#šta-zahteva-drajver-ili-administratorska-prava)
- [Izgradnja](#izgradnja)
- [GUI](#gui)
- [Komandna linija](#komandna-linija)
- [Linkovi za pretragu](#linkovi-za-pretragu)
- [Ažuriranja](#ažuriranja)
- [Snimanje i reprodukcija](#snimanje-i-reprodukcija)
- [Model bezbednosti](#model-bezbednosti)
- [Izvori podataka i licence](#izvori-podataka-i-licence)

## Funkcije

- **CPU** — identifikacija na osnovu CPUID-a uz bazu hardvera sa praćenim poreklom podataka (kodno ime, mikroarhitektura, revizija, podnožje), family/model/stepping, kompletan spisak skupova instrukcija (MMX … AVX-512, AES, SHA, VT-x/AMD-V) sa CPUID listom i bitom za svaku, izvedeni x86-64 nivo, keševi prikazani kao `8 x 32 KB`, topologija i procena takta **bez drajvera** sa opterećenjem po jezgru i ukupnim opterećenjem.
- **Matična ploča** — proizvođač, model, revizija i BIOS (SMBIOS tipovi 0/1/2/3/4), čipset izveden iz PCI ID-ova i svaki PCI uređaj imenovan na osnovu ugrađenog `pci.ids`.
- **Memorija** — moduli iz SMBIOS tipa 17 (slot, veličina, DDR4/DDR5, brzina i podešena brzina, proizvođač, broj dela, rank, napon), ukupna veličina i jasno označena heuristika kanala.
- **Grafika** — DXGI i SetupAPI: nazivi, ID-ovi proizvođača/uređaja/podsistema/revizije, naziv kartice iz `pci.ids`, verzija i datum drajvera, namenska i deljena memorija, PCIe veza. Taktovi, temperature, ventilator, opterećenje i snaga dolaze iz **AMD ADL** ili **NVIDIA NVAPI**, koji se učitavaju tokom rada, samo za čitanje i opciono.
- **Diskovi** — model, firmver, magistrala, veličina i serijski broj (maskiran). NVMe log zdravlja bez administratorskih prava, SATA SMART kao administrator: temperatura, sati rada, istrošenost i navedeno pravilo za ocenu zdravlja.
- **Senzori** — opterećenje i takt CPU-a, GPU senzori, temperature diskova. CPU senzori zasnovani na MSR-u preko opcionog drajvera; ventilatori matične ploče navedeni su kao *zahteva drajver (planirano)*.
- **Izvoz izveštaja** — TXT, HTML i JSON. Serijski brojevi i UUID-ovi su **podrazumevano maskirani**.
- **Dva prikaza** — kompaktan prikaz u stilu CPU-Z (podrazumevano) i pun spisak sa izvorom i pouzdanošću svakog polja (`Ctrl+L`).
- **27 jezika interfejsa**, **ažuriranje** sa stabilnim i testnim kanalom, dugmad za **pretragu** baze TechPowerUp i stranica sa drajverima proizvođača.

## Snimci ekrana

| CPU | Grafika |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Grafika](../docs/screenshots/graphics.png) |

| Matična ploča | Memorija |
|---|---|
| ![Matična ploča](../docs/screenshots/board.png) | ![Memorija](../docs/screenshots/memory.png) |

| Diskovi (administrator, SATA SMART) | Prikaz punog spiska |
|---|---|
| ![Diskovi](../docs/screenshots/admin_storage.png) | ![Pun spisak](../docs/screenshots/list_board.png) |

Sve kartice i oba prikaza: [docs/screenshots](../docs/screenshots).

## Jezik interfejsa

GUI, komandna linija i TXT/HTML izveštaji dostupni su na 27 jezika: poljski (izvorni), engleski, bugarski, češki, danski, nemački, grčki, španski, estonski, finski, francuski, hrvatski, mađarski, italijanski, litvanski, letonski, norveški (bokmål), holandski, portugalski (Brazil), rumunski, ruski, slovački, slovenački, srpski (latinica), švedski, turski i ukrajinski.

Jezik se bira ovim redom: sačuvano podešavanje (`data\settings.ini`), jezik prikaza Windows-a, zatim engleski. Možete ga promeniti u GUI-ju (izbor jezika) ili komandom `ferrumscope lang <code>` / `--lang=<code>`. Tehničke vrednosti (nazivi instrukcija, jedinice, PCI ID-ovi) nikada se ne prevode, a ključevi u JSON izvozu ostaju na engleskom. Za prevodioce: pogledajte [locales/README.md](../locales/README.md).

## Šta zahteva drajver ili administratorska prava

| Podaci | Zahtev |
|---|---|
| CPU, matična ploča, memorija, grafika, NVMe zdravlje, opisi diskova | ništa (običan korisnik) |
| SATA SMART | pokretanje kao administrator; bez toga program to prijavljuje i nastavlja da radi |
| APERF/MPERF, temperature iz MSR-a | drajver `FerrumScopeMsr.sys` — **ne instalira se automatski** |
| Ventilatori/naponi matične ploče (Super I/O), SPD tajminzi (SMBus) | drajver jezgra — **planirano, nije implementirano** |

## Izgradnja

Potreban je samo fiksirani Zig 0.15.2.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` gradi i pokreće GUI. Opcioni drajver se gradi zasebno pomoću WDK-a (`driver/build_driver.bat`) i build ga nikada ne instalira.

## GUI

- Kartice: CPU, Keš, Matična ploča, Memorija, Grafika, Diskovi, Senzori, Bench (rezervisano mesto), O programu.
- Zadržite pokazivač iznad vrednosti da vidite njen izvor, pouzdanost i sirovu vrednost. **Prikaži izvore** dodaje malu oznaku pored svakog polja.
- **Pun spisak** (`Ctrl+L`) prikazuje svako polje sa njegovim izvorom; izbor se pamti. `F5` osvežava statičke podatke (SMBIOS, PCI, diskovi).
- **Oznaka/logotip** na karticama CPU i Grafika. Prioritet: vaša sopstvena slika → priloženi logotip proizvođača → oznaka koju crta FerrumScope. Sopstvene PNG datoteke stavite pored programa u `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (npr. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (npr. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Nazivi su malim slovima, a svaki znak koji nije slovo ili cifra zamenjuje se sa `-`. Klik na oznaku otvara link za pretragu.
- Opcije komandne linije: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Komandna linija

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

## Linkovi za pretragu

Dugmad **Potraži** i oznaka otvaraju TechPowerUp bazu GPU/CPU. Tačna stranica se koristi kada je poznata, ovim redom:

1. link koji ste sami prikačili — kopirajte adresu stranice u pregledaču i kliknite **Prikači…** pored polja (čuva se u `data\links.toml`);
2. kurirana tabela [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — unosi se dodaju ručno (`source = "manual"`), nikada automatskim prikupljanjem (crawling); pull request-ovi su dobrodošli;
3. u suprotnom, pretraga po nazivu.

Čuvaju se samo linkovi; ništa se ne preuzima sa TechPowerUp-a. Prihvaćene adrese: `https://` na techpowerup.com ili na sajtu proizvođača.

## Ažuriranja

FerrumScope proverava GitHub izdanja `snakex21/FerrumScope` preko HTTPS-a — najviše jednom dnevno pri pokretanju (može se isključiti) ili na zahtev u **O programu → Proveri ažuriranja** / `ferrumscope update --check`. Ažuriranje se instalira tek kada se preuzeta zip arhiva poklapa **i** sa SHA-256 sumom u `ferrumscope-update.json` **i** sa `SHA256SUMS`; prethodni exe se čuva kao `.old` (`ferrumscope update --rollback`), a fascikla `data\` (podešavanja, prikačeni linkovi, vaše slike) se nikada ne dira. Kanali: **stable** (podrazumevano) i **test** (pre-release verzije). Ne šalje se nikakva telemetrija.

## Snimanje i reprodukcija

`.cpuimg` čuva sirove CPUID listove; `.sysimg` čuva sirove SMBIOS podatke, PCI ID-ove, DXGI adaptere i opise diskova/NVMe/SMART stranice. Oba su tekstualne datoteke i prolaze kroz **iste dekodere** kao podaci uživo, tako da se parseri testiraju bez hardvera. `capture-sys` podrazumevano maskira serijske brojeve i SMBIOS UUID (pomaci ostaju ispravni). Format: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Model bezbednosti

- GUI i CLI rade kao običan korisnik; ništa se ne instalira.
- Opcioni drajver `FerrumScopeMsr.sys` je **samo za čitanje**: tri IOCTL-a, **lista dozvoljenih** MSR registara (APERF/MPERF), svaki zahtev se proverava u jezgru, pristup uređaju ograničen na SYSTEM i administratore (`IoCreateDeviceSecure`), bez ikakve putanje za upis. Još nije učitan na stvarnom sistemu. Detalji: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Diskovi dobijaju samo komande za čitanje (IOCTL-ovi za upit skladišta, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- GPU biblioteke proizvođača učitavaju se samo iz System32 i koriste se samo funkcije za upite.
- Serijski brojevi su maskirani u GUI-ju, izveštajima i snimcima, osim ako ih izričito ne zatražite.

## Izvori podataka i licence

- Izvorni kod programa FerrumScope: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **ili** BSD-3-Clause.
- Baza CPU-a (`db/source/cpu/*.toml`): svaki unos navodi svoj izvor (AMD revision guides, opsezi modela iz Linux kernela, javni CPUID dampovi). Nema podataka iz CPU-Z ili GPU-Z — pogledajte [reference/README.md](../reference/README.md).
- `assets/logos/` **nije** obuhvaćen licencom GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA i GeForce su žigovi svojih vlasnika; logotipi se koriste isključivo za identifikaciju hardvera i ne podrazumevaju nikakvu podršku ili preporuku. Poreklo po datoteci: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- TechPowerUp linkovi su obični linkovi koje otvarate vi; nikakvi podaci sa TechPowerUp-a se ne preuzimaju niti čuvaju.
