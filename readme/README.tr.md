**Languages:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#derleme)

Windows için açık ve şeffaf bir donanım bilgi aracı — Zig ile yazılmış "CPU-Z + GPU-Z bir arada". Her değerin **nereden geldiği** (CPUID yaprağı, SMBIOS ofseti, PCI ID veritabanı, NVMe günlük baytı, üretici kitaplığı…) ve programın ondan **ne kadar emin** olduğu gösterilir. Ana özellikler için sürücü gerekmez, telemetri yoktur.

![FerrumScope CPU sekmesi](../docs/screenshots/cpu.png)

## İçindekiler

- [Özellikler](#özellikler)
- [Ekran görüntüleri](#ekran-görüntüleri)
- [Arayüz dili](#arayüz-dili)
- [Sürücü veya yönetici hakları gerektirenler](#sürücü-veya-yönetici-hakları-gerektirenler)
- [Derleme](#derleme)
- [GUI](#gui)
- [Komut satırı](#komut-satırı)
- [Arama bağlantıları](#arama-bağlantıları)
- [Güncellemeler](#güncellemeler)
- [Kayıt ve yeniden oynatma](#kayıt-ve-yeniden-oynatma)
- [Güvenlik modeli](#güvenlik-modeli)
- [Veri kaynakları ve lisanslar](#veri-kaynakları-ve-lisanslar)

## Özellikler

- **CPU** — CPUID'den ve her kaydın kaynağı izlenebilen bir donanım veritabanından tanımlama (kod adı, mikromimari, revizyon, soket), aile/model/stepping, her birinin CPUID yaprağı ve biti ile tam komut seti listesi (MMX … AVX-512, AES, SHA, VT-x/AMD-V), türetilmiş x86-64 düzeyi, `8 x 32 KB` biçiminde gösterilen önbellekler, topoloji ve çekirdek başına ve toplam yük ile **sürücüsüz** saat hızı tahmini.
- **Anakart** — üretici, model, revizyon ve BIOS (SMBIOS türleri 0/1/2/3/4), PCI kimliklerinden türetilen yonga seti ve yerleşik `pci.ids` dosyasından adlandırılan her PCI aygıtı.
- **Bellek** — SMBIOS tür 17'den modüller (yuva, boyut, DDR4/DDR5, hız ve yapılandırılmış hız, üretici, parça numarası, rank, voltaj), toplam boyut ve açıkça etiketlenmiş bir kanal sezgiseli.
- **Grafik** — DXGI ve SetupAPI: adlar, vendor/device/subsystem/revision kimlikleri, `pci.ids` dosyasından kart adı, sürücü sürümü ve tarihi, ayrılmış ve paylaşılan bellek, PCIe bağlantısı. Saat hızları, sıcaklıklar, fan, yük ve güç, çalışma zamanında salt okunur ve isteğe bağlı olarak yüklenen **AMD ADL** veya **NVIDIA NVAPI** kitaplıklarından gelir.
- **Depolama** — model, bellenim, veri yolu, boyut ve seri numarası (maskeli). Yönetici hakları olmadan NVMe sağlık günlüğü, yönetici olarak SATA SMART: sıcaklık, çalışma saatleri, aşınma ve açıkça belirtilen bir sağlık kuralı.
- **Sensörler** — CPU yükü ve saat hızı, GPU sensörleri, disk sıcaklıkları. İsteğe bağlı sürücü üzerinden MSR tabanlı CPU sensörleri; anakart fanları *sürücü gerektirir (planlanıyor)* olarak listelenir.
- **Rapor dışa aktarma** — TXT, HTML ve JSON. Seri numaraları ve UUID'ler **varsayılan olarak maskelenir**.
- **İki görünüm** — kompakt, CPU-Z tarzı bir görünüm (varsayılan) ve her alanın kaynağını ve güvenilirliğini gösteren tam liste (`Ctrl+L`).
- **27 arayüz dili**, kararlı ve test kanallı bir **güncelleyici**, TechPowerUp veritabanı ve üretici sürücü sayfaları için **arama** düğmeleri.

## Ekran görüntüleri

| CPU | Grafik |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Grafik](../docs/screenshots/graphics.png) |

| Anakart | Bellek |
|---|---|
| ![Anakart](../docs/screenshots/board.png) | ![Bellek](../docs/screenshots/memory.png) |

| Depolama (yönetici, SATA SMART) | Tam liste görünümü |
|---|---|
| ![Depolama](../docs/screenshots/admin_storage.png) | ![Tam liste](../docs/screenshots/list_board.png) |

Tüm sekmeler ve her iki görünüm: [docs/screenshots](../docs/screenshots).

## Arayüz dili

GUI, komut satırı ve TXT/HTML raporları 27 dilde kullanılabilir: Lehçe (kaynak dil), İngilizce, Bulgarca, Çekçe, Danca, Almanca, Yunanca, İspanyolca, Estonca, Fince, Fransızca, Hırvatça, Macarca, İtalyanca, Litvanca, Letonca, Norveççe (Bokmål), Felemenkçe, Portekizce (Brezilya), Rumence, Rusça, Slovakça, Slovence, Sırpça (Latin), İsveççe, Türkçe ve Ukraynaca.

Dil şu sırayla seçilir: kayıtlı ayar (`data\settings.ini`), Windows görüntüleme dili, ardından İngilizce. GUI'de (dil seçici) veya `ferrumscope lang <code>` / `--lang=<code>` ile değiştirilebilir. Teknik değerler (komut adları, birimler, PCI kimlikleri) asla çevrilmez ve JSON dışa aktarma anahtarları İngilizce kalır. Çevirmenler için: [locales/README.md](../locales/README.md).

## Sürücü veya yönetici hakları gerektirenler

| Veri | Gereksinim |
|---|---|
| CPU, anakart, bellek, grafik, NVMe sağlığı, disk tanımlayıcıları | hiçbir şey (normal kullanıcı) |
| SATA SMART | yönetici olarak çalıştırma; bu olmadan program durumu bildirir ve çalışmaya devam eder |
| APERF/MPERF, MSR'den sıcaklıklar | `FerrumScopeMsr.sys` sürücüsü — **otomatik olarak yüklenmez** |
| Anakart fanları/voltajları (Super I/O), SPD zamanlamaları (SMBus) | bir çekirdek sürücüsü — **planlanıyor, uygulanmadı** |

## Derleme

Yalnızca sabitlenmiş Zig 0.15.2 gerekir.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` GUI'yi derler ve başlatır. İsteğe bağlı sürücü WDK ile ayrı olarak derlenir (`driver/build_driver.bat`) ve derleme tarafından asla yüklenmez.

## GUI

- Sekmeler: CPU, Önbellek, Anakart, Bellek, Grafik, Depolama, Sensörler, Test (yer tutucu), Hakkında.
- Kaynağını, güvenilirliğini ve ham değerini görmek için bir değerin üzerine gelin. **Kaynakları göster** her alanın yanına küçük bir işaret ekler.
- **Tam liste** (`Ctrl+L`) her alanı kaynağıyla birlikte gösterir; seçim hatırlanır. `F5` statik verileri (SMBIOS, PCI, diskler) yeniler.
- CPU ve Grafik sekmelerinde **rozet/logo**. Öncelik: kendi görüntünüz → programla gelen üretici logosu → FerrumScope'un çizdiği rozet. Kendi PNG dosyalarınızı programın yanındaki `data\images\` klasörüne koyun:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (ör. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (ör. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Adlar küçük harfle yazılır ve alfasayısal olmayan her karakter `-` ile değiştirilir. Rozete tıklamak arama bağlantısını açar.
- Komut satırı seçenekleri: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Komut satırı

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

## Arama bağlantıları

**Ara** düğmeleri ve rozet, TechPowerUp GPU/CPU veritabanını açar. Tam sayfa biliniyorsa şu sırayla o kullanılır:

1. kendi sabitlediğiniz bağlantı — sayfa adresini tarayıcınızdan kopyalayın ve alanın yanındaki **Sabitle…** düğmesine tıklayın (`data\links.toml` dosyasına kaydedilir);
2. düzenlenmiş tablo [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — kayıtlar elle eklenir (`source = "manual"`), asla tarama yoluyla eklenmez; pull request'ler memnuniyetle karşılanır;
3. aksi halde ada göre arama.

Yalnızca bağlantılar saklanır; TechPowerUp'tan hiçbir şey indirilmez. Kabul edilen adresler: techpowerup.com veya üreticinin sitesinde `https://`.

## Güncellemeler

FerrumScope, `snakex21/FerrumScope` GitHub sürümlerini HTTPS üzerinden denetler — başlangıçta günde en fazla bir kez (kapatılabilir) veya istek üzerine **Hakkında → Güncellemeleri denetle** / `ferrumscope update --check` ile. Güncelleme yalnızca indirilen zip, **hem** `ferrumscope-update.json` **hem de** `SHA256SUMS` içindeki SHA-256 ile eşleştiğinde yüklenir; önceki exe `.old` olarak saklanır (`ferrumscope update --rollback`) ve `data\` klasörüne (ayarlar, sabitlenmiş bağlantılar, görüntüleriniz) asla dokunulmaz. Kanallar: **stable** (varsayılan) ve **test** (ön sürümler). Telemetri gönderilmez.

## Kayıt ve yeniden oynatma

`.cpuimg` ham CPUID yapraklarını saklar; `.sysimg` ham SMBIOS'u, PCI kimliklerini, DXGI bağdaştırıcılarını ve disk tanımlayıcıları/NVMe/SMART sayfalarını saklar. Her ikisi de metin dosyasıdır ve canlı verilerle **aynı kod çözücülerden** geçer; böylece ayrıştırıcılar donanım olmadan test edilir. `capture-sys` varsayılan olarak seri numaralarını ve SMBIOS UUID'sini maskeler (ofsetler geçerli kalır). Biçim: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Güvenlik modeli

- GUI ve CLI normal kullanıcı olarak çalışır; hiçbir şey yüklenmez.
- İsteğe bağlı `FerrumScopeMsr.sys` sürücüsü **salt okunurdur**: üç IOCTL, bir MSR **izin listesi** (APERF/MPERF), her istek çekirdekte doğrulanır, aygıta erişim SYSTEM ve Yöneticiler ile sınırlıdır (`IoCreateDeviceSecure`), hiçbir yazma yolu yoktur. Henüz gerçek bir sistemde yüklenmedi. Ayrıntılar: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Disklere yalnızca okuma komutları gönderilir (depolama sorgusu IOCTL'leri, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Üreticilerin GPU kitaplıkları yalnızca System32'den yüklenir ve yalnızca sorgu işlevleri kullanılır.
- Seri numaraları, açıkça istemediğiniz sürece GUI'de, raporlarda ve kayıtlarda maskelenir.

## Veri kaynakları ve lisanslar

- FerrumScope kaynak kodu: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **veya** BSD-3-Clause.
- CPU veritabanı (`db/source/cpu/*.toml`): her kayıt kaynağını belirtir (AMD revizyon kılavuzları, Linux çekirdeği model aralıkları, herkese açık CPUID dökümleri). CPU-Z veya GPU-Z'den veri yoktur — bkz. [reference/README.md](../reference/README.md).
- `assets/logos/` GPL kapsamında **değildir**. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA ve GeForce ilgili sahiplerinin ticari markalarıdır; logolar yalnızca donanımı tanımlamak için kullanılır ve herhangi bir onay anlamına gelmez. Dosya bazında kaynak: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- TechPowerUp bağlantıları sizin açtığınız düz bağlantılardır; hiçbir TechPowerUp verisi indirilmez veya saklanmaz.
