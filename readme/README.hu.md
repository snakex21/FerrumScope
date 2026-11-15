**Languages:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#fordítás)

Nyílt, átlátható hardverinformációs eszköz Windowsra — „CPU-Z + GPU-Z egyben”, Zig nyelven írva. Minden érték megmutatja, **honnan származik** (CPUID levél, SMBIOS eltolás, PCI ID adatbázis, NVMe napló bájtja, gyártói könyvtár…) és **mennyire biztos** benne a program. A fő funkciókhoz nem kell illesztőprogram, és nincs telemetria.

![A FerrumScope CPU lapja](../docs/screenshots/cpu.png)

## Tartalom

- [Funkciók](#funkciók)
- [Képernyőképek](#képernyőképek)
- [Felület nyelve](#felület-nyelve)
- [Mihez kell illesztőprogram vagy rendszergazdai jog](#mihez-kell-illesztőprogram-vagy-rendszergazdai-jog)
- [Fordítás](#fordítás)
- [GUI](#gui)
- [Parancssor](#parancssor)
- [Keresési hivatkozások](#keresési-hivatkozások)
- [Frissítések](#frissítések)
- [Rögzítés és visszajátszás](#rögzítés-és-visszajátszás)
- [Biztonsági modell](#biztonsági-modell)
- [Adatforrások és licencek](#adatforrások-és-licencek)

## Funkciók

- **CPU** — azonosítás a CPUID és egy eredetkövetéssel ellátott hardveradatbázis alapján (kódnév, mikroarchitektúra, revízió, foglalat), család/modell/stepping, a teljes utasításkészlet-lista (MMX … AVX-512, AES, SHA, VT-x/AMD-V) mindegyik CPUID levelével és bitjével, a származtatott x86-64 szint, a gyorsítótárak `8 x 32 KB` formában, topológia, valamint **illesztőprogram nélküli** órajelbecslés magonkénti és teljes terheléssel.
- **Alaplap** — gyártó, modell, revízió és BIOS (SMBIOS 0/1/2/3/4-es típus), a PCI azonosítókból származtatott lapkakészlet, és minden PCI eszköz a beépített `pci.ids` alapján megnevezve.
- **Memória** — modulok az SMBIOS 17-es típusból (foglalat, méret, DDR4/DDR5, sebesség és beállított sebesség, gyártó, cikkszám, rank, feszültség), a teljes méret, valamint egy egyértelműen jelölt csatornaheurisztika.
- **Grafika** — DXGI és SetupAPI: nevek, gyártó/eszköz/alrendszer/revízió azonosítók, a kártya neve a `pci.ids` alapján, illesztőprogram verziója és dátuma, dedikált és megosztott memória, a PCIe kapcsolat. Az órajelek, hőmérsékletek, ventilátor, terhelés és teljesítmény az **AMD ADL** vagy az **NVIDIA NVAPI** könyvtárból származnak, amelyek futásidőben töltődnek be, csak olvasnak és opcionálisak.
- **Tárolók** — modell, firmware, busz, méret és sorozatszám (maszkolva). NVMe állapotnapló rendszergazdai jog nélkül, SATA SMART rendszergazdaként: hőmérséklet, bekapcsolt órák, kopás és egy kimondott állapotszabály.
- **Érzékelők** — CPU terhelés és órajel, GPU érzékelők, lemezhőmérsékletek. MSR-alapú CPU-érzékelők az opcionális illesztőprogramon keresztül; az alaplapi ventilátorok *illesztőprogram szükséges (tervezett)* jelöléssel szerepelnek.
- **Jelentés exportálása** — TXT, HTML és JSON. A sorozatszámok és UUID-k **alapértelmezés szerint maszkolva** vannak.
- **Két nézet** — egy kompakt, CPU-Z-stílusú nézet (alapértelmezett) és egy teljes lista minden mező forrásával és megbízhatóságával (`Ctrl+L`).
- **27 felületi nyelv**, **frissítő** stabil és teszt csatornával, **keresés** gombok a TechPowerUp adatbázishoz és a gyártók illesztőprogram-oldalaihoz.

## Képernyőképek

| CPU | Grafika |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Grafika](../docs/screenshots/graphics.png) |

| Alaplap | Memória |
|---|---|
| ![Alaplap](../docs/screenshots/board.png) | ![Memória](../docs/screenshots/memory.png) |

| Tárolók (rendszergazda, SATA SMART) | Teljes lista nézet |
|---|---|
| ![Tárolók](../docs/screenshots/admin_storage.png) | ![Teljes lista](../docs/screenshots/list_board.png) |

Minden lap és mindkét nézet: [docs/screenshots](../docs/screenshots).

## Felület nyelve

A GUI, a parancssor és a TXT/HTML jelentések 27 nyelven érhetők el: lengyel (forrásnyelv), angol, bolgár, cseh, dán, német, görög, spanyol, észt, finn, francia, horvát, magyar, olasz, litván, lett, norvég (bokmål), holland, portugál (brazíliai), román, orosz, szlovák, szlovén, szerb (latin), svéd, török és ukrán.

A nyelv kiválasztásának sorrendje: a mentett beállítás (`data\settings.ini`), a Windows megjelenítési nyelve, végül az angol. Módosítható a GUI-ban (nyelvválasztó) vagy a `ferrumscope lang <code>` / `--lang=<code>` paranccsal. A technikai értékek (utasításnevek, mértékegységek, PCI azonosítók) soha nem kerülnek fordításra, és a JSON export kulcsai angolul maradnak. Fordítóknak: lásd [locales/README.md](../locales/README.md).

## Mihez kell illesztőprogram vagy rendszergazdai jog

| Adat | Követelmény |
|---|---|
| CPU, alaplap, memória, grafika, NVMe állapot, lemezleírók | semmi (normál felhasználó) |
| SATA SMART | futtatás rendszergazdaként; enélkül a program jelzi ezt, és tovább működik |
| APERF/MPERF, hőmérsékletek MSR-ből | a `FerrumScopeMsr.sys` illesztőprogram — **nem települ automatikusan** |
| Alaplapi ventilátorok/feszültségek (Super I/O), SPD időzítések (SMBus) | kernel-illesztőprogram — **tervezett, nincs megvalósítva** |

## Fordítás

Csak a rögzített Zig 0.15.2 szükséges.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

A `ferrumscope-gui.bat` lefordítja és elindítja a GUI-t. Az opcionális illesztőprogram külön, a WDK-val fordítható (`driver/build_driver.bat`), és a fordítás soha nem telepíti.

## GUI

- Lapok: CPU, Gyorsítótárak, Alaplap, Memória, Grafika, Tárolók, Érzékelők, Teszt (helyőrző), Névjegy.
- Vigye az egeret egy érték fölé a forrás, a megbízhatóság és a nyers érték megtekintéséhez. A **Források mutatása** egy kis jelölőt tesz minden mező mellé.
- A **Teljes lista** (`Ctrl+L`) minden mezőt a forrásával együtt mutat; a választást a program megjegyzi. Az `F5` frissíti a statikus adatokat (SMBIOS, PCI, lemezek).
- **Jelvény/logó** a CPU és a Grafika lapon. Prioritás: saját kép → mellékelt gyártói logó → a FerrumScope által rajzolt jelvény. Saját PNG fájljait a program mellé, a `data\images\` mappába helyezze:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (pl. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (pl. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  A nevek kisbetűsek, és minden nem alfanumerikus karakter helyére `-` kerül. A jelvényre kattintva megnyílik a keresési hivatkozás.
- Parancssori kapcsolók: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Parancssor

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

## Keresési hivatkozások

A **Keresés** gombok és a jelvény a TechPowerUp GPU/CPU adatbázisát nyitják meg. Ha a pontos oldal ismert, azt használja, ebben a sorrendben:

1. egy saját maga által rögzített hivatkozás — másolja ki az oldal címét a böngészőből, és kattintson a mező melletti **Rögzítés…** gombra (mentés helye: `data\links.toml`);
2. a gondozott tábla: [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — a bejegyzéseket kézzel adják hozzá (`source = "manual"`), soha nem webes bejárással; a pull requestek szívesen látottak;
3. egyébként keresés név alapján.

Csak hivatkozások tárolódnak; a TechPowerUp oldaláról semmi sem töltődik le. Elfogadott címek: `https://` a techpowerup.com vagy a gyártó oldalán.

## Frissítések

A FerrumScope HTTPS-en keresztül ellenőrzi a `snakex21/FerrumScope` GitHub-kiadásait — indításkor legfeljebb naponta egyszer (kikapcsolható), vagy igény szerint a **Névjegy → Frissítések keresése** menüben / a `ferrumscope update --check` paranccsal. Egy frissítés csak akkor települ, ha a letöltött zip **mind** a `ferrumscope-update.json` fájlban, **mind** a `SHA256SUMS` fájlban szereplő SHA-256 értékkel egyezik; az előző exe `.old` néven megmarad (`ferrumscope update --rollback`), a `data\` mappához (beállítások, rögzített hivatkozások, saját képek) pedig soha nem nyúl. Csatornák: **stable** (alapértelmezett) és **test** (előzetes kiadások). Semmilyen telemetria nem kerül elküldésre.

## Rögzítés és visszajátszás

A `.cpuimg` nyers CPUID leveleket tárol; a `.sysimg` nyers SMBIOS-t, PCI azonosítókat, DXGI adaptereket és lemezleírókat/NVMe/SMART oldalakat. Mindkettő szövegfájl, és **ugyanazokon a dekódolókon** megy át, mint az élő adatok, így a feldolgozók hardver nélkül is tesztelhetők. A `capture-sys` alapértelmezés szerint maszkolja a sorozatszámokat és az SMBIOS UUID-t (az eltolások érvényesek maradnak). Formátum: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Biztonsági modell

- A GUI és a CLI normál felhasználóként fut; semmi sem települ.
- Az opcionális `FerrumScopeMsr.sys` illesztőprogram **csak olvas**: három IOCTL, MSR **engedélyezési lista** (APERF/MPERF), minden kérés ellenőrzése a kernelben, az eszközhöz csak a SYSTEM és a rendszergazdák férnek hozzá (`IoCreateDeviceSecure`), írási útvonal egyáltalán nincs. Valós rendszeren még nem volt betöltve. Részletek: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- A lemezek csak olvasási parancsokat kapnak (storage query IOCTL-ek, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- A gyártói GPU-könyvtárak csak a System32 mappából töltődnek be, és csak lekérdező függvények használatosak.
- A sorozatszámok a GUI-ban, a jelentésekben és a rögzítésekben maszkolva vannak, hacsak kifejezetten nem kéri őket.

## Adatforrások és licencek

- A FerrumScope forráskódja: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **vagy** BSD-3-Clause.
- CPU adatbázis (`db/source/cpu/*.toml`): minden bejegyzés megjelöli a forrását (AMD revision guide-ok, a Linux kernel modelltartományai, nyilvános CPUID dumpok). Nincsenek adatok a CPU-Z-ből vagy a GPU-Z-ből — lásd [reference/README.md](../reference/README.md).
- Az `assets/logos/` mappára **nem** vonatkozik a GPL. Az AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA és GeForce a megfelelő tulajdonosaik védjegyei; a logók kizárólag a hardver azonosítására szolgálnak, és nem jelentenek támogatást vagy jóváhagyást. Fájlonkénti eredet: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- A TechPowerUp hivatkozások egyszerű linkek, amelyeket Ön nyit meg; semmilyen TechPowerUp adat nem töltődik le és nem tárolódik.
