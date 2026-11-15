**Languages:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#ehitamine)

Avatud ja läbipaistev riistvarateabe tööriist Windowsile — „CPU-Z + GPU-Z ühes”, kirjutatud Zigis. Iga väärtuse juures on näha, **kust see pärineb** (CPUID leht, SMBIOS-i nihe, PCI ID andmebaas, NVMe logi bait, tootja teek…) ja **kui kindel** programm selles on. Põhifunktsioonid ei vaja draiverit, telemeetriat pole.

![FerrumScope'i CPU sakk](../docs/screenshots/cpu.png)

## Sisukord

- [Funktsioonid](#funktsioonid)
- [Ekraanipildid](#ekraanipildid)
- [Liidese keel](#liidese-keel)
- [Mis vajab draiverit või administraatoriõigusi](#mis-vajab-draiverit-või-administraatoriõigusi)
- [Ehitamine](#ehitamine)
- [GUI](#gui)
- [Käsurida](#käsurida)
- [Otsingulingid](#otsingulingid)
- [Värskendused](#värskendused)
- [Salvestamine ja taasesitus](#salvestamine-ja-taasesitus)
- [Turvamudel](#turvamudel)
- [Andmeallikad ja litsentsid](#andmeallikad-ja-litsentsid)

## Funktsioonid

- **CPU** — tuvastamine CPUID-i põhjal koos riistvara andmebaasiga, mille iga kirje päritolu on jälgitav (koodnimi, mikroarhitektuur, revisjon, sokkel), pere/mudel/stepping, täielik käsustike loend (MMX … AVX-512, AES, SHA, VT-x/AMD-V) iga CPUID lehe ja bitiga, tuletatud x86-64 tase, vahemälud kujul `8 x 32 KB`, topoloogia ning **draiverita** taktihinnang tuumapõhise ja kogukoormusega.
- **Emaplaat** — tootja, mudel, revisjon ja BIOS (SMBIOS tüübid 0/1/2/3/4), PCI ID-dest tuletatud kiibistik ning iga PCI-seade nimega sisseehitatud failist `pci.ids`.
- **Mälu** — moodulid SMBIOS tüübist 17 (pesa, suurus, DDR4/DDR5, kiirus ja seadistatud kiirus, tootja, osa number, rank, pinge), kogusuurus ning selgelt märgistatud kanaliheuristika.
- **Graafika** — DXGI ja SetupAPI: nimed, vendor/device/subsystem/revision ID-d, kaardi nimi failist `pci.ids`, draiveri versioon ja kuupäev, eraldatud ja ühismälu, PCIe link. Taktid, temperatuurid, ventilaator, koormus ja võimsus pärinevad teekidest **AMD ADL** või **NVIDIA NVAPI**, mis laaditakse käitusajal, ainult lugemiseks ja valikuliselt.
- **Salvestus** — mudel, püsivara, siin, suurus ja seerianumber (maskitud). NVMe seisundilogi ilma administraatoriõigusteta, SATA SMART administraatorina: temperatuur, töötunnid, kulumine ja välja öeldud seisundireegel.
- **Andurid** — CPU koormus ja takt, GPU andurid, ketaste temperatuurid. MSR-põhised CPU andurid valikulise draiveri kaudu; emaplaadi ventilaatorid on märgitud kui *nõuab draiverit (kavas)*.
- **Aruande eksport** — TXT, HTML ja JSON. Seerianumbrid ja UUID-d on **vaikimisi maskitud**.
- **Kaks vaadet** — kompaktne CPU-Z-laadne vaade (vaikimisi) ja täielik loend iga välja allika ja usaldusväärsusega (`Ctrl+L`).
- **27 liidese keelt**, **värskendaja** stabiilse ja testkanaliga ning **otsingunupud** TechPowerUpi andmebaasi ja tootjate draiverilehtede jaoks.

## Ekraanipildid

| CPU | Graafika |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Graafika](../docs/screenshots/graphics.png) |

| Emaplaat | Mälu |
|---|---|
| ![Emaplaat](../docs/screenshots/board.png) | ![Mälu](../docs/screenshots/memory.png) |

| Salvestus (administraator, SATA SMART) | Täieliku loendi vaade |
|---|---|
| ![Salvestus](../docs/screenshots/admin_storage.png) | ![Täielik loend](../docs/screenshots/list_board.png) |

Kõik sakid ja mõlemad vaated: [docs/screenshots](../docs/screenshots).

## Liidese keel

GUI, käsurida ja TXT/HTML-aruanded on saadaval 27 keeles: poola (lähtekeel), inglise, bulgaaria, tšehhi, taani, saksa, kreeka, hispaania, eesti, soome, prantsuse, horvaadi, ungari, itaalia, leedu, läti, norra (bokmål), hollandi, portugali (Brasiilia), rumeenia, vene, slovaki, sloveeni, serbia (ladina), rootsi, türgi ja ukraina.

Keel valitakse selles järjekorras: salvestatud seade (`data\settings.ini`), Windowsi kuvakeel, seejärel inglise keel. Keelt saab muuta GUI-s (keelevalija) või käsuga `ferrumscope lang <code>` / `--lang=<code>`. Tehnilisi väärtusi (käskude nimed, ühikud, PCI ID-d) ei tõlgita kunagi ning JSON-ekspordi võtmed jäävad ingliskeelseks. Tõlkijatele: vt [locales/README.md](../locales/README.md).

## Mis vajab draiverit või administraatoriõigusi

| Andmed | Nõue |
|---|---|
| CPU, emaplaat, mälu, graafika, NVMe seisund, ketaste deskriptorid | mitte midagi (tavakasutaja) |
| SATA SMART | käivitamine administraatorina; ilma selleta teatab programm sellest ja töötab edasi |
| APERF/MPERF, temperatuurid MSR-ist | draiver `FerrumScopeMsr.sys` — **ei installita automaatselt** |
| Emaplaadi ventilaatorid/pinged (Super I/O), SPD ajastused (SMBus) | tuumadraiver — **kavas, teostamata** |

## Ehitamine

Vaja on ainult fikseeritud Zig 0.15.2.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` ehitab ja käivitab GUI. Valikuline draiver ehitatakse eraldi WDK-ga (`driver/build_driver.bat`) ja ehitamine ei installi seda kunagi.

## GUI

- Sakid: CPU, Vahemälu, Emaplaat, Mälu, Graafika, Salvestus, Andurid, Test (kohatäide), Teave.
- Liigu väärtuse kohale, et näha selle allikat, usaldusväärsust ja toorväärtust. **Näita allikaid** lisab iga välja kõrvale väikese märgi.
- **Täielik loend** (`Ctrl+L`) näitab iga välja koos allikaga; valik jäetakse meelde. `F5` värskendab staatilisi andmeid (SMBIOS, PCI, kettad).
- **Märk/logo** CPU ja Graafika sakil. Järjekord: teie oma pilt → kaasasolev tootja logo → FerrumScope'i joonistatud märk. Pange oma PNG-failid programmi kõrvale kausta `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (nt `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (nt `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Nimed kirjutatakse väiketähtedega ja iga mittetähtnumbriline märk asendatakse märgiga `-`. Märgil klõpsamine avab otsingulingi.
- Käsurea suvandid: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Käsurida

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

## Otsingulingid

**Otsi** nupud ja märk avavad TechPowerUpi GPU/CPU andmebaasi. Kui täpne leht on teada, kasutatakse seda selles järjekorras:

1. teie enda kinnitatud link — kopeerige lehe aadress brauserist ja klõpsake välja kõrval **Kinnita…** (salvestatakse faili `data\links.toml`);
2. hallatud tabel [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — kirjed lisatakse käsitsi (`source = "manual"`), mitte kunagi roomamise teel; pull request'id on teretulnud;
3. muul juhul otsing nime järgi.

Salvestatakse ainult lingid; TechPowerUpist ei laadita midagi alla. Lubatud aadressid: `https://` saidil techpowerup.com või tootja saidil.

## Värskendused

FerrumScope kontrollib projekti `snakex21/FerrumScope` GitHubi väljalaskeid HTTPS-i kaudu — kõige rohkem kord päevas käivitamisel (saab välja lülitada) või nõudmisel menüüs **Teave → Otsi värskendusi** / `ferrumscope update --check`. Värskendus installitakse alles siis, kui allalaaditud zip vastab **nii** failis `ferrumscope-update.json` kui ka failis `SHA256SUMS` olevale SHA-256 summale; eelmine exe säilitatakse kui `.old` (`ferrumscope update --rollback`) ja kausta `data\` (seaded, kinnitatud lingid, teie pildid) ei puututa kunagi. Kanalid: **stable** (vaikimisi) ja **test** (eelversioonid). Telemeetriat ei saadeta.

## Salvestamine ja taasesitus

`.cpuimg` salvestab toored CPUID lehed; `.sysimg` salvestab toore SMBIOS-i, PCI ID-d, DXGI adapterid ning ketaste deskriptorid ja NVMe/SMART lehed. Mõlemad on tekstifailid ja läbivad **samad dekoodrid** nagu reaalajas andmed, nii et parsereid testitakse ilma riistvarata. `capture-sys` maskib vaikimisi seerianumbrid ja SMBIOS-i UUID (nihked jäävad kehtivaks). Vorming: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Turvamudel

- GUI ja CLI töötavad tavakasutajana; midagi ei installita.
- Valikuline draiver `FerrumScopeMsr.sys` on **ainult lugemiseks**: kolm IOCTL-i, MSR-i **lubatud loend** (APERF/MPERF), iga päringut kontrollitakse tuumas, seadmele pääsevad ligi ainult SYSTEM ja administraatorid (`IoCreateDeviceSecure`), kirjutamisteed pole üldse. Seda pole veel päris süsteemis laaditud. Üksikasjad: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Ketastele saadetakse ainult lugemiskäske (salvestuspäringu IOCTL-id, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Tootjate GPU teegid laaditakse ainult kaustast System32 ja kasutatakse ainult päringufunktsioone.
- Seerianumbrid on GUI-s, aruannetes ja salvestistes maskitud, kui te neid selgesõnaliselt ei küsi.

## Andmeallikad ja litsentsid

- FerrumScope'i lähtekood: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **või** BSD-3-Clause.
- CPU andmebaas (`db/source/cpu/*.toml`): iga kirje viitab oma allikale (AMD revisjonijuhendid, Linuxi tuuma mudelivahemikud, avalikud CPUID tõmmised). CPU-Z ega GPU-Z andmeid pole — vt [reference/README.md](../reference/README.md).
- `assets/logos/` **ei** kuulu GPL-i alla. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA ja GeForce on nende vastavate omanike kaubamärgid; logosid kasutatakse ainult riistvara tuvastamiseks ja need ei tähenda heakskiitu. Failipõhine päritolu: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- TechPowerUpi lingid on tavalised lingid, mida avate teie; TechPowerUpi andmeid ei laadita alla ega salvestata.
