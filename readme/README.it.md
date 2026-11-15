**Lingue:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#compilazione)

Uno strumento aperto e trasparente per le informazioni sull'hardware in Windows — "CPU-Z + GPU-Z in uno", scritto in Zig. Ogni valore mostra **da dove proviene** (foglia CPUID, offset SMBIOS, database degli ID PCI, byte del log NVMe, libreria del produttore…) e **quanto è affidabile** secondo il programma. Nessun driver necessario per le funzioni principali, nessuna telemetria.

![Scheda CPU di FerrumScope](../docs/screenshots/cpu.png)

## Indice

- [Funzionalità](#funzionalità)
- [Screenshot](#screenshot)
- [Lingua dell'interfaccia](#lingua-dellinterfaccia)
- [Cosa richiede un driver o i diritti di amministratore](#cosa-richiede-un-driver-o-i-diritti-di-amministratore)
- [Compilazione](#compilazione)
- [GUI](#gui)
- [Riga di comando](#riga-di-comando)
- [Link di ricerca](#link-di-ricerca)
- [Aggiornamenti](#aggiornamenti)
- [Capture e replay](#capture-e-replay)
- [Modello di sicurezza](#modello-di-sicurezza)
- [Fonti dei dati e licenze](#fonti-dei-dati-e-licenze)

## Funzionalità

- **CPU** — identificazione da CPUID più un database hardware con provenienza tracciata (nome in codice, microarchitettura, revisione, socket), famiglia/modello/stepping, l'elenco completo dei set di istruzioni (MMX … AVX-512, AES, SHA, VT-x/AMD-V) con la foglia e il bit CPUID di ciascuno, il livello x86-64 ricavato, le cache mostrate come `8 x 32 KB`, la topologia e una stima del clock **senza driver** con carico per core e totale.
- **Scheda madre** — produttore, modello, revisione e BIOS (SMBIOS tipi 0/1/2/3/4), il chipset ricavato dagli ID PCI e ogni dispositivo PCI con il nome preso dal `pci.ids` integrato.
- **Memoria** — moduli da SMBIOS tipo 17 (slot, dimensione, DDR4/DDR5, velocità e velocità configurata, produttore, codice articolo, rank, tensione), la dimensione totale e un'euristica dei canali chiaramente indicata come tale.
- **Grafica** — DXGI e SetupAPI: nomi, ID vendor/device/subsystem/revisione, il nome della scheda da `pci.ids`, versione e data del driver, memoria dedicata e condivisa, il collegamento PCIe. Clock, temperature, ventola, carico e consumo provengono da **AMD ADL** o **NVIDIA NVAPI**, caricate in fase di esecuzione, in sola lettura e opzionali.
- **Dischi** — modello, firmware, bus, dimensione e numero di serie (mascherato). Log di salute NVMe senza diritti di amministratore, SMART SATA come amministratore: temperatura, ore di accensione, usura e una regola di salute dichiarata.
- **Sensori** — carico e clock della CPU, sensori GPU, temperature dei dischi. Sensori CPU basati su MSR tramite il driver opzionale; le ventole della scheda madre sono indicate come *richiede driver (previsto)*.
- **Esportazione del report** — TXT, HTML e JSON. Numeri di serie e UUID sono **mascherati per impostazione predefinita**.
- **Due viste** — una vista compatta in stile CPU-Z (predefinita) e un elenco completo con fonte e affidabilità di ogni campo (`Ctrl+L`).
- **27 lingue dell'interfaccia**, un **aggiornamento automatico** con canali stabile e di test, pulsanti di **ricerca** per il database TechPowerUp e le pagine dei driver dei produttori.

## Screenshot

| CPU | Grafica |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Grafica](../docs/screenshots/graphics.png) |

| Scheda madre | Memoria |
|---|---|
| ![Scheda madre](../docs/screenshots/board.png) | ![Memoria](../docs/screenshots/memory.png) |

| Dischi (amministratore, SMART SATA) | Vista elenco completo |
|---|---|
| ![Dischi](../docs/screenshots/admin_storage.png) | ![Elenco completo](../docs/screenshots/list_board.png) |

Tutte le schede ed entrambe le viste: [docs/screenshots](../docs/screenshots).

## Lingua dell'interfaccia

La GUI, la riga di comando e i report TXT/HTML sono disponibili in 27 lingue: polacco (lingua di origine), inglese, bulgaro, ceco, danese, tedesco, greco, spagnolo, estone, finlandese, francese, croato, ungherese, italiano, lituano, lettone, norvegese bokmål, olandese, portoghese (Brasile), rumeno, russo, slovacco, sloveno, serbo (latino), svedese, turco e ucraino.

La lingua viene scelta in quest'ordine: l'impostazione salvata (`data\settings.ini`), la lingua di visualizzazione di Windows, quindi l'inglese. Puoi cambiarla nella GUI (selettore della lingua) oppure con `ferrumscope lang <code>` / `--lang=<code>`. I valori tecnici (nomi delle istruzioni, unità, ID PCI) non vengono mai tradotti e le chiavi dell'esportazione JSON restano in inglese. Per i traduttori: vedi [locales/README.md](../locales/README.md).

## Cosa richiede un driver o i diritti di amministratore

| Dati | Requisito |
|---|---|
| CPU, scheda madre, memoria, grafica, salute NVMe, descrittori dei dischi | nulla (utente normale) |
| SMART SATA | esecuzione come amministratore; senza, il programma lo segnala e continua a funzionare |
| APERF/MPERF, temperature da MSR | il driver `FerrumScopeMsr.sys` — **non installato automaticamente** |
| Ventole/tensioni della scheda madre (Super I/O), timing SPD (SMBus) | un driver kernel — **previsto, non implementato** |

## Compilazione

Serve solo Zig 0.15.2 (versione fissata).

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` compila e avvia la GUI. Il driver opzionale si compila separatamente con il WDK (`driver/build_driver.bat`) e non viene mai installato dalla compilazione.

## GUI

- Schede: CPU, Cache, Scheda madre, Memoria, Grafica, Dischi, Sensori, Benchmark (segnaposto), Informazioni.
- Passa il mouse su un valore per vederne fonte, affidabilità e valore grezzo. **Mostra fonti** aggiunge un piccolo indicatore accanto a ogni campo.
- **Elenco completo** (`Ctrl+L`) mostra ogni campo con la sua fonte; la scelta viene ricordata. `F5` aggiorna i dati statici (SMBIOS, PCI, dischi).
- **Badge/logo** nelle schede CPU e Grafica. Priorità: la tua immagine → un logo del produttore incluso → un badge disegnato da FerrumScope. Metti i tuoi file PNG accanto al programma in `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (ad es. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (ad es. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  I nomi sono in minuscolo e ogni carattere non alfanumerico è sostituito da `-`. Un clic sul badge apre il link di ricerca.
- Opzioni della riga di comando: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Riga di comando

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

## Link di ricerca

I pulsanti **Cerca** e il badge aprono il database GPU/CPU di TechPowerUp. Quando la pagina esatta è nota viene usata, in quest'ordine:

1. un link che hai fissato tu — copia l'indirizzo della pagina nel browser e fai clic su **Fissa…** accanto al campo (salvato in `data\links.toml`);
2. la tabella curata [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — le voci vengono aggiunte a mano (`source = "manual"`), mai tramite crawling; le pull request sono benvenute;
3. altrimenti una ricerca per nome.

Vengono salvati solo i link; nulla viene scaricato da TechPowerUp. Indirizzi accettati: `https://` su techpowerup.com o sul sito del produttore.

## Aggiornamenti

FerrumScope controlla le release GitHub di `snakex21/FerrumScope` tramite HTTPS — al massimo una volta al giorno all'avvio (disattivabile) oppure su richiesta in **Informazioni → Cerca aggiornamenti…** / `ferrumscope update --check`. Un aggiornamento viene installato solo dopo che lo zip scaricato corrisponde **sia** allo SHA-256 in `ferrumscope-update.json` **sia** a `SHA256SUMS`; l'exe precedente viene conservato come `.old` (`ferrumscope update --rollback`) e la cartella `data\` (impostazioni, link fissati, le tue immagini) non viene mai toccata. Canali: **stabile** (predefinito) e **test** (versioni pre-release). Non viene inviata alcuna telemetria.

## Capture e replay

`.cpuimg` memorizza le foglie CPUID grezze; `.sysimg` memorizza SMBIOS grezzo, ID PCI, adattatori DXGI e descrittori dei dischi/pagine NVMe/SMART. Entrambi sono file di testo e passano per **gli stessi decoder** dei dati in tempo reale, quindi i parser vengono testati senza hardware. `capture-sys` maschera per impostazione predefinita i numeri di serie e l'UUID SMBIOS (gli offset restano validi). Formato: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Modello di sicurezza

- La GUI e la CLI vengono eseguite come utente normale; non viene installato nulla.
- Il driver opzionale `FerrumScopeMsr.sys` è **di sola lettura**: tre IOCTL, una **allowlist** di MSR (APERF/MPERF), ogni richiesta validata nel kernel, accesso al dispositivo limitato a SYSTEM e Administrators (`IoCreateDeviceSecure`), nessun percorso di scrittura. Non è ancora stato caricato su un sistema reale. Dettagli: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- I dischi ricevono solo comandi di lettura (IOCTL di interrogazione dello storage, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Le librerie GPU dei produttori vengono caricate solo da System32 e vengono usate solo funzioni di interrogazione.
- I numeri di serie sono mascherati nella GUI, nei report e nei capture, a meno che tu non li richieda esplicitamente.

## Fonti dei dati e licenze

- Codice sorgente di FerrumScope: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **o** BSD-3-Clause.
- Database CPU (`db/source/cpu/*.toml`): ogni voce cita la propria fonte (revision guide AMD, intervalli di modelli del kernel Linux, dump CPUID pubblici). Nessun dato da CPU-Z o GPU-Z — vedi [reference/README.md](../reference/README.md).
- `assets/logos/` **non** è coperta dalla GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA e GeForce sono marchi dei rispettivi proprietari; i loghi sono usati solo per identificare l'hardware e non implicano alcuna approvazione. Origine di ciascun file: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- I link a TechPowerUp sono semplici link aperti da te; nessun dato di TechPowerUp viene scaricato o memorizzato.
