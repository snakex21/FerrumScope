**Languages:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#compilare)

Un instrument deschis și transparent de informații despre hardware pentru Windows — „CPU-Z + GPU-Z într-unul singur”, scris în Zig. Fiecare valoare arată **de unde provine** (frunza CPUID, offsetul SMBIOS, baza de date PCI ID, octetul din jurnalul NVMe, biblioteca producătorului…) și **cât de sigur** este programul de ea. Funcțiile principale nu necesită niciun driver și nu există telemetrie.

![Fila CPU din FerrumScope](../docs/screenshots/cpu.png)

## Cuprins

- [Funcționalități](#funcționalități)
- [Capturi de ecran](#capturi-de-ecran)
- [Limba interfeței](#limba-interfeței)
- [Ce necesită un driver sau drepturi de administrator](#ce-necesită-un-driver-sau-drepturi-de-administrator)
- [Compilare](#compilare)
- [GUI](#gui)
- [Linia de comandă](#linia-de-comandă)
- [Linkuri de căutare](#linkuri-de-căutare)
- [Actualizări](#actualizări)
- [Captură și redare](#captură-și-redare)
- [Modelul de securitate](#modelul-de-securitate)
- [Surse de date și licențe](#surse-de-date-și-licențe)

## Funcționalități

- **CPU** — identificare din CPUID plus o bază de date hardware cu proveniență urmărită (nume de cod, microarhitectură, revizie, soclu), familie/model/stepping, lista completă a seturilor de instrucțiuni (MMX … AVX-512, AES, SHA, VT-x/AMD-V) cu frunza și bitul CPUID ale fiecăreia, nivelul x86-64 derivat, cache-uri afișate ca `8 x 32 KB`, topologie și o estimare a frecvenței **fără driver**, cu sarcina pe fiecare nucleu și totală.
- **Placă de bază** — producător, model, revizie și BIOS (SMBIOS tipurile 0/1/2/3/4), chipsetul dedus din PCI ID-uri și fiecare dispozitiv PCI denumit pe baza fișierului `pci.ids` încorporat.
- **Memorie** — module din SMBIOS tip 17 (slot, dimensiune, DDR4/DDR5, viteză și viteză configurată, producător, cod de produs, rank, tensiune), dimensiunea totală și o euristică a canalelor marcată clar ca atare.
- **Grafică** — DXGI și SetupAPI: nume, ID-uri de producător/dispozitiv/subsistem/revizie, numele plăcii din `pci.ids`, versiunea și data driverului, memoria dedicată și partajată, legătura PCIe. Frecvențele, temperaturile, ventilatorul, sarcina și puterea provin din **AMD ADL** sau **NVIDIA NVAPI**, încărcate la rulare, doar în citire și opționale.
- **Stocare** — model, firmware, magistrală, dimensiune și număr de serie (mascat). Jurnalul de sănătate NVMe fără drepturi de administrator, SMART SATA ca administrator: temperatură, ore de funcționare, uzură și o regulă de sănătate declarată explicit.
- **Senzori** — sarcina și frecvența CPU, senzorii GPU, temperaturile discurilor. Senzorii CPU bazați pe MSR prin driverul opțional; ventilatoarele plăcii de bază sunt afișate ca *necesită driver (planificat)*.
- **Export de rapoarte** — TXT, HTML și JSON. Numerele de serie și UUID-urile sunt **mascate implicit**.
- **Două vizualizări** — o vizualizare compactă în stilul CPU-Z (implicită) și o listă completă cu sursa și încrederea fiecărui câmp (`Ctrl+L`).
- **27 de limbi ale interfeței**, un **actualizator** cu canale stabil și de test, butoane de **căutare** pentru baza de date TechPowerUp și paginile de drivere ale producătorilor.

## Capturi de ecran

| CPU | Grafică |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Grafică](../docs/screenshots/graphics.png) |

| Placă de bază | Memorie |
|---|---|
| ![Placă de bază](../docs/screenshots/board.png) | ![Memorie](../docs/screenshots/memory.png) |

| Stocare (administrator, SMART SATA) | Vizualizare listă completă |
|---|---|
| ![Stocare](../docs/screenshots/admin_storage.png) | ![Listă completă](../docs/screenshots/list_board.png) |

Toate filele și ambele vizualizări: [docs/screenshots](../docs/screenshots).

## Limba interfeței

GUI-ul, linia de comandă și rapoartele TXT/HTML sunt disponibile în 27 de limbi: poloneză (limba sursă), engleză, bulgară, cehă, daneză, germană, greacă, spaniolă, estonă, finlandeză, franceză, croată, maghiară, italiană, lituaniană, letonă, norvegiană (bokmål), neerlandeză, portugheză (Brazilia), română, rusă, slovacă, slovenă, sârbă (alfabet latin), suedeză, turcă și ucraineană.

Limba este aleasă în această ordine: setarea salvată (`data\settings.ini`), limba de afișare a Windows, apoi engleza. Se schimbă din GUI (selectorul de limbă) sau cu `ferrumscope lang <code>` / `--lang=<code>`. Valorile tehnice (nume de instrucțiuni, unități, PCI ID-uri) nu sunt traduse niciodată, iar cheile exportului JSON rămân în engleză. Pentru traducători: vezi [locales/README.md](../locales/README.md).

## Ce necesită un driver sau drepturi de administrator

| Date | Cerință |
|---|---|
| CPU, placă de bază, memorie, grafică, sănătate NVMe, descriptori de disc | nimic (utilizator obișnuit) |
| SMART SATA | rulare ca administrator; fără aceasta programul o semnalează și continuă să funcționeze |
| APERF/MPERF, temperaturi din MSR | driverul `FerrumScopeMsr.sys` — **nu se instalează automat** |
| Ventilatoare/tensiuni ale plăcii de bază (Super I/O), timinguri SPD (SMBus) | un driver de kernel — **planificat, neimplementat** |

## Compilare

Este necesar doar Zig 0.15.2 (versiunea fixată).

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` compilează și pornește GUI-ul. Driverul opțional se compilează separat cu WDK (`driver/build_driver.bat`) și nu este instalat niciodată de procesul de compilare.

## GUI

- File: CPU, Cache, Placă de bază, Memorie, Grafică, Stocare, Senzori, Bench (rezervat), Despre.
- Treceți cu mouse-ul peste o valoare pentru a vedea sursa, încrederea și valoarea brută. **Afișează sursele** adaugă un mic marcaj lângă fiecare câmp.
- **Lista completă** (`Ctrl+L`) afișează fiecare câmp cu sursa sa; alegerea este reținută. `F5` reîmprospătează datele statice (SMBIOS, PCI, discuri).
- **Insignă/logo** pe filele CPU și Grafică. Prioritate: imaginea proprie → un logo de producător inclus → o insignă desenată de FerrumScope. Puneți propriile fișiere PNG lângă program, în `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (de ex. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (de ex. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Numele sunt cu litere mici, iar fiecare caracter non-alfanumeric este înlocuit cu `-`. Un clic pe insignă deschide linkul de căutare.
- Opțiuni de linie de comandă: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Linia de comandă

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

## Linkuri de căutare

Butoanele **Caută** și insigna deschid baza de date GPU/CPU TechPowerUp. Pagina exactă este folosită atunci când este cunoscută, în această ordine:

1. un link pe care l-ați fixat chiar dumneavoastră — copiați adresa paginii din browser și faceți clic pe **Fixează…** lângă câmp (salvat în `data\links.toml`);
2. tabelul întreținut manual [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — intrările sunt adăugate de mână (`source = "manual"`), niciodată prin crawling; pull request-urile sunt binevenite;
3. altfel, o căutare după nume.

Sunt stocate doar linkuri; nu se descarcă nimic de pe TechPowerUp. Adrese acceptate: `https://` pe techpowerup.com sau pe site-ul producătorului.

## Actualizări

FerrumScope verifică versiunile GitHub ale `snakex21/FerrumScope` prin HTTPS — cel mult o dată pe zi la pornire (se poate dezactiva) sau la cerere din **Despre → Caută actualizări…** / `ferrumscope update --check`. O actualizare este instalată doar după ce arhiva zip descărcată corespunde **atât** sumei SHA-256 din `ferrumscope-update.json`, cât și celei din `SHA256SUMS`; exe-ul anterior este păstrat ca `.old` (`ferrumscope update --rollback`), iar folderul `data\` (setări, linkuri fixate, imaginile proprii) nu este atins niciodată. Canale: **stabil** (implicit) și **de test** (versiuni preliminare). Nu se trimite nicio telemetrie.

## Captură și redare

`.cpuimg` stochează frunze CPUID brute; `.sysimg` stochează SMBIOS brut, PCI ID-uri, adaptoare DXGI și descriptori de disc/pagini NVMe/SMART. Ambele sunt fișiere text și trec prin **aceleași decodoare** ca datele în timp real, astfel încât parserele sunt testate fără hardware. `capture-sys` maschează implicit numerele de serie și UUID-ul SMBIOS (offseturile rămân valide). Format: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Modelul de securitate

- GUI-ul și CLI-ul rulează ca utilizator obișnuit; nu se instalează nimic.
- Driverul opțional `FerrumScopeMsr.sys` este **doar în citire**: trei IOCTL-uri, o **listă de permisiuni** MSR (APERF/MPERF), fiecare cerere validată în kernel, accesul la dispozitiv limitat la SYSTEM și Administratori (`IoCreateDeviceSecure`), fără nicio cale de scriere. Nu a fost încă încărcat pe un sistem real. Detalii: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Discurile primesc doar comenzi de citire (IOCTL-uri de interogare a stocării, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Bibliotecile GPU ale producătorilor sunt încărcate doar din System32 și sunt folosite doar funcțiile de interogare.
- Numerele de serie sunt mascate în GUI, rapoarte și capturi, cu excepția cazului în care le cereți explicit.

## Surse de date și licențe

- Codul sursă FerrumScope: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **sau** BSD-3-Clause.
- Baza de date CPU (`db/source/cpu/*.toml`): fiecare intrare își citează sursa (ghidurile de revizii AMD, intervalele de modele din kernelul Linux, dump-uri CPUID publice). Nu conține date din CPU-Z sau GPU-Z — vezi [reference/README.md](../reference/README.md).
- `assets/logos/` **nu** este acoperit de GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA și GeForce sunt mărci comerciale ale proprietarilor lor; logourile sunt folosite doar pentru identificarea hardware-ului și nu implică nicio susținere din partea acestora. Originea fiecărui fișier: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- Linkurile TechPowerUp sunt simple linkuri deschise de dumneavoastră; nu se descarcă și nu se stochează nicio dată TechPowerUp.
