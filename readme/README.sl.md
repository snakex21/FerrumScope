**Languages:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#gradnja)

Odprto in pregledno orodje za podatke o strojni opremi v sistemu Windows — „CPU-Z + GPU-Z v enem“, napisano v jeziku Zig. Pri vsaki vrednosti je prikazano, **od kod izvira** (list CPUID, odmik SMBIOS, baza ID-jev PCI, bajt dnevnika NVMe, knjižnica proizvajalca …) in **kako zanesljiva** je po oceni programa. Za glavne funkcije gonilnik ni potreben, telemetrije ni.

![Zavihek CPU v FerrumScope](../docs/screenshots/cpu.png)

## Vsebina

- [Funkcije](#funkcije)
- [Posnetki zaslona](#posnetki-zaslona)
- [Jezik vmesnika](#jezik-vmesnika)
- [Kaj zahteva gonilnik ali skrbniške pravice](#kaj-zahteva-gonilnik-ali-skrbniške-pravice)
- [Gradnja](#gradnja)
- [Grafični vmesnik](#grafični-vmesnik)
- [Ukazna vrstica](#ukazna-vrstica)
- [Povezave za iskanje](#povezave-za-iskanje)
- [Posodobitve](#posodobitve)
- [Zajem in ponovno predvajanje](#zajem-in-ponovno-predvajanje)
- [Varnostni model](#varnostni-model)
- [Viri podatkov in licence](#viri-podatkov-in-licence)

## Funkcije

- **CPU** — prepoznavanje iz CPUID in baze strojne opreme s sledenjem izvora (kodno ime, mikroarhitektura, revizija, podnožje), družina/model/stepping, celoten seznam naborov ukazov (MMX … AVX-512, AES, SHA, VT-x/AMD-V) z listom CPUID in bitom za vsakega, izpeljana raven x86-64, predpomnilniki v obliki `8 x 32 KB`, topologija ter ocena takta **brez gonilnika** z obremenitvijo posameznih jeder in skupno obremenitvijo.
- **Matična plošča** — proizvajalec, model, revizija in BIOS (SMBIOS tipi 0/1/2/3/4), nabor čipov, izpeljan iz ID-jev PCI, in vse naprave PCI z imeni iz vgrajene datoteke `pci.ids`.
- **Pomnilnik** — moduli iz SMBIOS tip 17 (reža, velikost, DDR4/DDR5, hitrost in nastavljena hitrost, proizvajalec, številka dela, rank, napetost), skupna velikost in jasno označena hevristika kanalov.
- **Grafika** — DXGI in SetupAPI: imena, ID-ji proizvajalca/naprave/podsistema/revizije, ime kartice iz `pci.ids`, različica in datum gonilnika, namenski in skupni pomnilnik, povezava PCIe. Takti, temperature, ventilator, obremenitev in moč prihajajo iz **AMD ADL** ali **NVIDIA NVAPI**, ki se naložita med izvajanjem, samo za branje in neobvezno.
- **Diski** — model, vdelana programska oprema, vodilo, velikost in serijska številka (zakrita). Dnevnik stanja NVMe brez skrbniških pravic, SATA SMART kot skrbnik: temperatura, ure delovanja, obraba in navedeno pravilo za oceno stanja.
- **Senzorji** — obremenitev in takt CPU, senzorji GPU, temperature diskov. Senzorji CPU na podlagi MSR prek neobveznega gonilnika; ventilatorji matične plošče so navedeni kot *zahteva gonilnik (načrtovano)*.
- **Izvoz poročila** — TXT, HTML in JSON. Serijske številke in UUID-ji so **privzeto zakriti**.
- **Dva pogleda** — kompakten pogled v slogu CPU-Z (privzeto) in celoten seznam z virom in zanesljivostjo vsakega polja (`Ctrl+L`).
- **27 jezikov vmesnika**, **posodabljalnik** s stabilnim in testnim kanalom ter gumbi za **iskanje** v bazi TechPowerUp in na straneh z gonilniki proizvajalcev.

## Posnetki zaslona

| CPU | Grafika |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Grafika](../docs/screenshots/graphics.png) |

| Matična plošča | Pomnilnik |
|---|---|
| ![Matična plošča](../docs/screenshots/board.png) | ![Pomnilnik](../docs/screenshots/memory.png) |

| Diski (skrbnik, SATA SMART) | Pogled celotnega seznama |
|---|---|
| ![Diski](../docs/screenshots/admin_storage.png) | ![Celoten seznam](../docs/screenshots/list_board.png) |

Vsi zavihki in oba pogleda: [docs/screenshots](../docs/screenshots).

## Jezik vmesnika

Grafični vmesnik, ukazna vrstica in poročila TXT/HTML so na voljo v 27 jezikih: poljščina (izvorni jezik), angleščina, bolgarščina, češčina, danščina, nemščina, grščina, španščina, estonščina, finščina, francoščina, hrvaščina, madžarščina, italijanščina, litovščina, latvijščina, norveščina (bokmål), nizozemščina, portugalščina (Brazilija), romunščina, ruščina, slovaščina, slovenščina, srbščina (latinica), švedščina, turščina in ukrajinščina.

Jezik se izbere v tem vrstnem redu: shranjena nastavitev (`data\settings.ini`), jezik prikaza sistema Windows, nato angleščina. Spremenite ga v grafičnem vmesniku (izbirnik jezika) ali z `ferrumscope lang <code>` / `--lang=<code>`. Tehnične vrednosti (imena ukazov, enote, ID-ji PCI) se nikoli ne prevajajo, ključi izvoza JSON pa ostanejo v angleščini. Prevajalci: glejte [locales/README.md](../locales/README.md).

## Kaj zahteva gonilnik ali skrbniške pravice

| Podatki | Zahteva |
|---|---|
| CPU, matična plošča, pomnilnik, grafika, stanje NVMe, opisniki diskov | nič (običajni uporabnik) |
| SATA SMART | zagon kot skrbnik; brez tega program to sporoči in deluje naprej |
| APERF/MPERF, temperature iz MSR | gonilnik `FerrumScopeMsr.sys` — **ni nameščen samodejno** |
| Ventilatorji/napetosti matične plošče (Super I/O), časovne nastavitve SPD (SMBus) | gonilnik jedra — **načrtovano, ni izvedeno** |

## Gradnja

Potreben je le pripeti Zig 0.15.2.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` zgradi in zažene grafični vmesnik. Neobvezni gonilnik se gradi ločeno z WDK (`driver/build_driver.bat`) in ga gradnja nikoli ne namesti.

## Grafični vmesnik

- Zavihki: CPU, Predpomnilniki, Matična plošča, Pomnilnik, Grafika, Diski, Senzorji, Test (rezervirano mesto), O programu.
- Premaknite kazalec na vrednost, da vidite njen vir, zanesljivost in surovo vrednost. **Prikaži vire** ob vsakem polju doda majhno oznako.
- **Celoten seznam** (`Ctrl+L`) prikaže vsa polja z virom; izbira se zapomni. `F5` osveži statične podatke (SMBIOS, PCI, diski).
- **Značka/logotip** na zavihkih CPU in Grafika. Prednost: vaša lastna slika → priloženi logotip proizvajalca → značka, ki jo nariše FerrumScope. Lastne datoteke PNG postavite ob program v `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (npr. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (npr. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Imena so z malimi črkami, vsak znak, ki ni črka ali številka, pa je zamenjan z `-`. Klik na značko odpre povezavo za iskanje.
- Možnosti ukazne vrstice: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Ukazna vrstica

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

## Povezave za iskanje

Gumbi **Poišči** in značka odprejo bazo GPU/CPU TechPowerUp. Natančna stran se uporabi, kadar je znana, v tem vrstnem redu:

1. povezava, ki ste jo pripeli sami — v brskalniku kopirajte naslov strani in kliknite **Pripni…** ob polju (shrani se v `data\links.toml`);
2. urejena tabela [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — vnose dodajamo ročno (`source = "manual"`), nikoli s samodejnim pajkanjem; zahteve za združitev (pull requests) so dobrodošle;
3. sicer iskanje po imenu.

Shranjujejo se le povezave; s TechPowerUp se nič ne prenaša. Sprejeti naslovi: `https://` na techpowerup.com ali na strani proizvajalca.

## Posodobitve

FerrumScope prek HTTPS preverja izdaje GitHub repozitorija `snakex21/FerrumScope` — največ enkrat na dan ob zagonu (to je mogoče izklopiti) ali na zahtevo v **O programu → Preveri posodobitve…** / `ferrumscope update --check`. Posodobitev se namesti šele, ko preneseni zip ustreza **obema** vsotama SHA-256, tisti v `ferrumscope-update.json` in tisti v `SHA256SUMS`; prejšnja izvršljiva datoteka (exe) se ohrani kot `.old` (`ferrumscope update --rollback`), mape `data\` (nastavitve, pripete povezave, vaše slike) pa posodobitev nikoli ne spremeni. Kanala: **stabilni** (privzeto) in **testni** (predizdaje). Telemetrija se ne pošilja.

## Zajem in ponovno predvajanje

`.cpuimg` hrani surove liste CPUID; `.sysimg` hrani surove podatke SMBIOS, ID-je PCI, vmesnike DXGI in opisnike diskov ter strani NVMe/SMART. Obe sta besedilni datoteki in gresta skozi **iste dekoderje** kot podatki v živo, zato so razčlenjevalniki preizkušeni brez strojne opreme. `capture-sys` privzeto zakrije serijske številke in UUID SMBIOS (odmiki ostanejo veljavni). Oblika: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Varnostni model

- Grafični vmesnik in CLI tečeta kot običajni uporabnik; nič se ne namesti.
- Neobvezni gonilnik `FerrumScopeMsr.sys` je **samo za branje**: trije IOCTL-ji, **seznam dovoljenih** MSR (APERF/MPERF), vsaka zahteva se preveri v jedru, dostop do naprave je omejen na SYSTEM in skrbnike (`IoCreateDeviceSecure`), poti za pisanje sploh ni. Na resničnem sistemu še ni bil naložen. Podrobnosti: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Diski prejmejo samo ukaze za branje (IOCTL-ji za poizvedbo shrambe, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Knjižnice GPU proizvajalcev se nalagajo samo iz System32 in uporabljajo se samo poizvedbene funkcije.
- Serijske številke so v grafičnem vmesniku, poročilih in zajemih zakrite, razen če jih izrecno zahtevate.

## Viri podatkov in licence

- Izvorna koda FerrumScope: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **ali** BSD-3-Clause.
- Baza CPU (`db/source/cpu/*.toml`): vsak vnos navaja svoj vir (AMD revision guides, razponi modelov iz jedra Linux, javni izpisi CPUID). Brez podatkov iz CPU-Z ali GPU-Z — glejte [reference/README.md](../reference/README.md).
- Za `assets/logos/` licenca GPL **ne** velja. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA in GeForce so blagovne znamke svojih lastnikov; logotipi se uporabljajo samo za prepoznavanje strojne opreme in ne pomenijo nikakršne podpore. Izvor posameznih datotek: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- Povezave TechPowerUp so navadne povezave, ki jih odprete sami; nobeni podatki TechPowerUp se ne prenašajo ali shranjujejo.
