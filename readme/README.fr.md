**Languages:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#compilation)

Un outil d'information matérielle ouvert et transparent pour Windows — « CPU-Z + GPU-Z en un », écrit en Zig. Chaque valeur indique **d'où elle provient** (feuille CPUID, offset SMBIOS, base des ID PCI, octet du journal NVMe, bibliothèque du fabricant…) et **quel degré de fiabilité** le programme lui accorde. Aucun pilote n'est nécessaire pour les fonctions principales, aucune télémétrie.

![Onglet CPU de FerrumScope](../docs/screenshots/cpu.png)

## Sommaire

- [Fonctionnalités](#fonctionnalités)
- [Captures d'écran](#captures-décran)
- [Langue de l'interface](#langue-de-linterface)
- [Ce qui nécessite un pilote ou des droits d'administrateur](#ce-qui-nécessite-un-pilote-ou-des-droits-dadministrateur)
- [Compilation](#compilation)
- [Interface graphique](#interface-graphique)
- [Ligne de commande](#ligne-de-commande)
- [Liens de recherche](#liens-de-recherche)
- [Mises à jour](#mises-à-jour)
- [Capture et replay](#capture-et-replay)
- [Modèle de sécurité](#modèle-de-sécurité)
- [Sources de données et licences](#sources-de-données-et-licences)

## Fonctionnalités

- **CPU** — identification via CPUID et une base de données matérielle dont la provenance est tracée (nom de code, microarchitecture, révision, socket), family/model/stepping, la liste complète des jeux d'instructions (MMX … AVX-512, AES, SHA, VT-x/AMD-V) avec la feuille et le bit CPUID de chacun, le niveau x86-64 déduit, les caches affichés sous la forme `8 x 32 KB`, la topologie et une estimation de fréquence **sans pilote** avec la charge par cœur et totale.
- **Carte mère** — fabricant, modèle, révision et BIOS (SMBIOS types 0/1/2/3/4), le chipset déduit des ID PCI, et chaque périphérique PCI nommé grâce au fichier `pci.ids` intégré.
- **Mémoire** — modules issus de SMBIOS type 17 (emplacement, taille, DDR4/DDR5, vitesse et vitesse configurée, fabricant, référence, rang, tension), la taille totale et une heuristique de canaux clairement signalée comme telle.
- **Graphique** — DXGI et SetupAPI : noms, ID fabricant/périphérique/sous-système/révision, le nom de la carte d'après `pci.ids`, version et date du pilote, mémoire dédiée et partagée, liaison PCIe. Fréquences, températures, ventilateur, charge et consommation proviennent d'**AMD ADL** ou de **NVIDIA NVAPI**, chargées à l'exécution, en lecture seule et facultatives.
- **Stockage** — modèle, firmware, bus, taille et numéro de série (masqué). Journal de santé NVMe sans droits d'administrateur, SMART SATA en tant qu'administrateur : température, heures de fonctionnement, usure et règle de santé explicite.
- **Capteurs** — charge et fréquence du CPU, capteurs GPU, températures des disques. Capteurs CPU basés sur les MSR via le pilote facultatif ; les ventilateurs de la carte mère sont indiqués comme *nécessite un pilote (prévu)*.
- **Export de rapport** — TXT, HTML et JSON. Les numéros de série et les UUID sont **masqués par défaut**.
- **Deux vues** — une vue compacte de type CPU-Z (par défaut) et une liste complète avec la source et la fiabilité de chaque champ (`Ctrl+L`).
- **27 langues d'interface**, un **outil de mise à jour** avec canaux stable et test, des boutons de **recherche** pour la base TechPowerUp et les pages de pilotes des fabricants.

## Captures d'écran

| CPU | Graphique |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Graphique](../docs/screenshots/graphics.png) |

| Carte mère | Mémoire |
|---|---|
| ![Carte mère](../docs/screenshots/board.png) | ![Mémoire](../docs/screenshots/memory.png) |

| Stockage (administrateur, SMART SATA) | Vue liste complète |
|---|---|
| ![Stockage](../docs/screenshots/admin_storage.png) | ![Liste complète](../docs/screenshots/list_board.png) |

Tous les onglets et les deux vues : [docs/screenshots](../docs/screenshots).

## Langue de l'interface

L'interface graphique, la ligne de commande et les rapports TXT/HTML sont disponibles en 27 langues : polonais (langue source), anglais, bulgare, tchèque, danois, allemand, grec, espagnol, estonien, finnois, français, croate, hongrois, italien, lituanien, letton, norvégien bokmål, néerlandais, portugais (Brésil), roumain, russe, slovaque, slovène, serbe (latin), suédois, turc et ukrainien.

La langue est choisie dans cet ordre : le paramètre enregistré (`data\settings.ini`), la langue d'affichage de Windows, puis l'anglais. Vous pouvez la changer dans l'interface graphique (sélecteur de langue) ou avec `ferrumscope lang <code>` / `--lang=<code>`. Les valeurs techniques (noms d'instructions, unités, ID PCI) ne sont jamais traduites, et les clés de l'export JSON restent en anglais. Traducteurs : voir [locales/README.md](../locales/README.md).

## Ce qui nécessite un pilote ou des droits d'administrateur

| Données | Exigence |
|---|---|
| CPU, carte mère, mémoire, graphique, santé NVMe, descripteurs des disques | rien (utilisateur standard) |
| SMART SATA | exécution en tant qu'administrateur ; sans cela, le programme le signale et continue de fonctionner |
| APERF/MPERF, températures issues des MSR | le pilote `FerrumScopeMsr.sys` — **non installé automatiquement** |
| Ventilateurs/tensions de la carte mère (Super I/O), timings SPD (SMBus) | un pilote noyau — **prévu, non implémenté** |

## Compilation

Seul Zig 0.15.2 (version fixée) est nécessaire.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` compile et lance l'interface graphique. Le pilote facultatif est compilé séparément avec le WDK (`driver/build_driver.bat`) et n'est jamais installé par la compilation.

## Interface graphique

- Onglets : CPU, Caches, Carte mère, Mémoire, Graphique, Stockage, Capteurs, Bench (réservé), À propos.
- Survolez une valeur pour voir sa source, sa fiabilité et sa valeur brute. **Afficher les sources** ajoute un petit repère à côté de chaque champ.
- **Liste complète** (`Ctrl+L`) affiche chaque champ avec sa source ; ce choix est mémorisé. `F5` actualise les données statiques (SMBIOS, PCI, disques).
- **Badge/logo** sur les onglets CPU et Graphique. Priorité : votre propre image → un logo de fabricant fourni → un badge dessiné par FerrumScope. Placez vos propres fichiers PNG à côté du programme, dans `data\images\` :
  - CPU : `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (par ex. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU : `gpu\<vid>-<did>.png` (par ex. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Les noms sont en minuscules, chaque caractère non alphanumérique étant remplacé par `-`. Un clic sur le badge ouvre le lien de recherche.
- Options de ligne de commande : `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Ligne de commande

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

## Liens de recherche

Les boutons **Rechercher** et le badge ouvrent la base GPU/CPU de TechPowerUp. La page exacte est utilisée lorsqu'elle est connue, dans cet ordre :

1. un lien que vous avez épinglé vous-même — copiez l'adresse de la page dans votre navigateur et cliquez sur **Épingler…** à côté du champ (enregistré dans `data\links.toml`) ;
2. la table maintenue manuellement [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — les entrées sont ajoutées à la main (`source = "manual"`), jamais par exploration automatique ; les pull requests sont les bienvenues ;
3. sinon, une recherche par nom.

Seuls les liens sont enregistrés ; rien n'est téléchargé depuis TechPowerUp. Adresses acceptées : `https://` sur techpowerup.com ou sur le site du fabricant.

## Mises à jour

FerrumScope vérifie les versions GitHub de `snakex21/FerrumScope` via HTTPS — au plus une fois par jour au démarrage (désactivable), ou à la demande dans **À propos → Rechercher des mises à jour** / `ferrumscope update --check`. Une mise à jour n'est installée que si le zip téléchargé correspond **à la fois** au SHA-256 de `ferrumscope-update.json` et à `SHA256SUMS` ; l'exécutable précédent est conservé en `.old` (`ferrumscope update --rollback`) et le dossier `data\` (paramètres, liens épinglés, vos images) n'est jamais modifié. Canaux : **stable** (par défaut) et **test** (préversions). Aucune télémétrie n'est envoyée.

## Capture et replay

`.cpuimg` stocke les feuilles CPUID brutes ; `.sysimg` stocke les données brutes SMBIOS, les ID PCI, les adaptateurs DXGI et les descripteurs de disques/pages NVMe/SMART. Ce sont deux fichiers texte qui passent par **les mêmes décodeurs** que les données en direct, ce qui permet de tester les analyseurs sans matériel. `capture-sys` masque par défaut les numéros de série et l'UUID SMBIOS (les offsets restent valides). Format : [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Modèle de sécurité

- L'interface graphique et la CLI s'exécutent en tant qu'utilisateur standard ; rien n'est installé.
- Le pilote facultatif `FerrumScopeMsr.sys` est en **lecture seule** : trois IOCTL, une **liste d'autorisation** de MSR (APERF/MPERF), chaque requête validée dans le noyau, accès au périphérique limité à SYSTEM et aux Administrateurs (`IoCreateDeviceSecure`), aucun chemin d'écriture. Il n'a encore jamais été chargé sur un système réel. Détails : [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Les disques ne reçoivent que des commandes de lecture (IOCTL de requête de stockage, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Les bibliothèques GPU des fabricants ne sont chargées que depuis System32, et seules les fonctions de requête sont utilisées.
- Les numéros de série sont masqués dans l'interface graphique, les rapports et les captures, sauf si vous les demandez explicitement.

## Sources de données et licences

- Code source de FerrumScope : **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids` : PCI ID Repository, GPL-2.0-or-later **ou** BSD-3-Clause.
- Base CPU (`db/source/cpu/*.toml`) : chaque entrée cite sa source (guides de révision AMD, plages de modèles du noyau Linux, dumps CPUID publics). Aucune donnée de CPU-Z ni de GPU-Z — voir [reference/README.md](../reference/README.md).
- `assets/logos/` n'est **pas** couvert par la GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA et GeForce sont des marques de leurs propriétaires respectifs ; les logos sont utilisés uniquement pour identifier le matériel et n'impliquent aucune approbation. Origine de chaque fichier : [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- Les liens TechPowerUp sont de simples liens que vous ouvrez vous-même ; aucune donnée de TechPowerUp n'est téléchargée ni stockée.
