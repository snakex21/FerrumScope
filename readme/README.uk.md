**Мови:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#збирання)

Відкритий і прозорий інструмент для перегляду відомостей про обладнання у Windows — «CPU-Z + GPU-Z в одному», написаний мовою Zig. Для кожного значення показано, **звідки воно взялося** (лист CPUID, зсув SMBIOS, база ідентифікаторів PCI, байт журналу NVMe, бібліотека виробника…) і **наскільки програма в ньому впевнена**. Для основних функцій драйвер не потрібен, телеметрії немає.

![Вкладка CPU у FerrumScope](../docs/screenshots/cpu.png)

## Зміст

- [Можливості](#можливості)
- [Знімки екрана](#знімки-екрана)
- [Мова інтерфейсу](#мова-інтерфейсу)
- [Що потребує драйвера або прав адміністратора](#що-потребує-драйвера-або-прав-адміністратора)
- [Збирання](#збирання)
- [GUI](#gui)
- [Командний рядок](#командний-рядок)
- [Посилання для пошуку](#посилання-для-пошуку)
- [Оновлення](#оновлення)
- [Capture і replay](#capture-і-replay)
- [Модель безпеки](#модель-безпеки)
- [Джерела даних і ліцензії](#джерела-даних-і-ліцензії)

## Можливості

- **CPU** — ідентифікація за CPUID плюс база даних обладнання з відстежуваним походженням записів (кодова назва, мікроархітектура, ревізія, сокет), family/model/stepping, повний список наборів інструкцій (MMX … AVX-512, AES, SHA, VT-x/AMD-V) із листом і бітом CPUID для кожної, виведений рівень x86-64, кеші у вигляді `8 x 32 KB`, топологія, а також оцінка частоти **без драйвера** з навантаженням для кожного ядра й загальним.
- **Материнська плата** — виробник, модель, ревізія та BIOS (SMBIOS типи 0/1/2/3/4), чипсет, визначений за ідентифікаторами PCI, і всі пристрої PCI з назвами з вбудованого `pci.ids`.
- **Пам’ять** — модулі з SMBIOS типу 17 (слот, обсяг, DDR4/DDR5, швидкість і налаштована швидкість, виробник, номер деталі, ранг, напруга), загальний обсяг і чітко позначена евристика каналів.
- **Графіка** — DXGI і SetupAPI: назви, ідентифікатори vendor/device/subsystem/revision, назва плати з `pci.ids`, версія й дата драйвера, виділена та спільна пам’ять, з’єднання PCIe. Частоти, температури, вентилятор, навантаження й потужність беруться з **AMD ADL** або **NVIDIA NVAPI**, які завантажуються під час роботи, лише для читання й необов’язково.
- **Накопичувачі** — модель, мікропрограма, шина, розмір і серійний номер (замаскований). Журнал стану NVMe без прав адміністратора, SATA SMART — від імені адміністратора: температура, години роботи, знос і явно вказане правило оцінки стану.
- **Датчики** — навантаження й частота CPU, датчики GPU, температури дисків. Датчики CPU на основі MSR — через необов’язковий драйвер; вентилятори материнської плати позначено як *потребує драйвера (заплановано)*.
- **Експорт звіту** — TXT, HTML і JSON. Серійні номери та UUID **типово замасковані**.
- **Два подання** — компактне подання у стилі CPU-Z (типово) і повний список із джерелом і достовірністю кожного поля (`Ctrl+L`).
- **27 мов інтерфейсу**, **оновлювач** зі стабільним і тестовим каналами, кнопки **пошуку** в базі TechPowerUp і на сторінках драйверів виробників.

## Знімки екрана

| CPU | Графіка |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Графіка](../docs/screenshots/graphics.png) |

| Материнська плата | Пам’ять |
|---|---|
| ![Материнська плата](../docs/screenshots/board.png) | ![Пам’ять](../docs/screenshots/memory.png) |

| Накопичувачі (адміністратор, SATA SMART) | Подання повного списку |
|---|---|
| ![Накопичувачі](../docs/screenshots/admin_storage.png) | ![Повний список](../docs/screenshots/list_board.png) |

Усі вкладки та обидва подання: [docs/screenshots](../docs/screenshots).

## Мова інтерфейсу

GUI, командний рядок і звіти TXT/HTML доступні 27 мовами: польською (вихідна), англійською, болгарською, чеською, данською, німецькою, грецькою, іспанською, естонською, фінською, французькою, хорватською, угорською, італійською, литовською, латиською, норвезькою (букмол), нідерландською, португальською (Бразилія), румунською, російською, словацькою, словенською, сербською (латиниця), шведською, турецькою та українською.

Мова вибирається в такому порядку: збережене налаштування (`data\settings.ini`), мова інтерфейсу Windows, потім англійська. Змінити її можна в GUI (вибір мови) або командою `ferrumscope lang <code>` / `--lang=<code>`. Технічні значення (назви інструкцій, одиниці, ідентифікатори PCI) ніколи не перекладаються, а ключі експорту JSON залишаються англійською. Перекладачам: див. [locales/README.md](../locales/README.md).

## Що потребує драйвера або прав адміністратора

| Дані | Вимога |
|---|---|
| CPU, материнська плата, пам’ять, графіка, стан NVMe, дескриптори дисків | нічого (звичайний користувач) |
| SATA SMART | запуск від імені адміністратора; без цього програма повідомляє про це й працює далі |
| APERF/MPERF, температури з MSR | драйвер `FerrumScopeMsr.sys` — **не встановлюється автоматично** |
| Вентилятори/напруги материнської плати (Super I/O), таймінги SPD (SMBus) | драйвер ядра — **заплановано, не реалізовано** |

## Збирання

Потрібен лише закріплений Zig 0.15.2.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` збирає і запускає GUI. Необов’язковий драйвер збирається окремо за допомогою WDK (`driver/build_driver.bat`) і ніколи не встановлюється під час збирання.

## GUI

- Вкладки: CPU, Кеш, Материнська плата, Пам’ять, Графіка, Накопичувачі, Датчики, Тест (заглушка), Про програму.
- Наведіть курсор на значення, щоб побачити його джерело, достовірність і сире значення. **Показати джерела** додає невелику позначку біля кожного поля.
- **Повний список** (`Ctrl+L`) показує кожне поле з його джерелом; вибір запам’ятовується. `F5` оновлює статичні дані (SMBIOS, PCI, диски).
- **Значок/логотип** на вкладках CPU і Графіка. Пріоритет: ваше власне зображення → вбудований логотип виробника → значок, намальований FerrumScope. Покладіть власні файли PNG поруч із програмою в `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (напр. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (напр. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Назви пишуться малими літерами, а кожен символ, що не є літерою чи цифрою, замінюється на `-`. Клацання значка відкриває посилання для пошуку.
- Параметри командного рядка: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Командний рядок

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

## Посилання для пошуку

Кнопки **Знайти** і значок відкривають базу GPU/CPU TechPowerUp. Якщо точна сторінка відома, використовується саме вона, у такому порядку:

1. посилання, яке ви закріпили самі — скопіюйте адресу сторінки в браузері й натисніть **Закріпити…** біля поля (зберігається в `data\links.toml`);
2. кураторська таблиця [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — записи додаються вручну (`source = "manual"`), ніколи автоматичним обходом сайту; pull request’и вітаються;
3. інакше — пошук за назвою.

Зберігаються лише посилання; з TechPowerUp нічого не завантажується. Допустимі адреси: `https://` на techpowerup.com або на сайті виробника.

## Оновлення

FerrumScope перевіряє випуски GitHub `snakex21/FerrumScope` через HTTPS — не частіше ніж раз на день під час запуску (можна вимкнути) або на вимогу в **Про програму → Перевірити оновлення** / `ferrumscope update --check`. Оновлення встановлюється лише тоді, коли завантажений zip-архів відповідає **обом** сумам SHA-256: у `ferrumscope-update.json` і в `SHA256SUMS`; попередній exe зберігається як `.old` (`ferrumscope update --rollback`), а папка `data\` (налаштування, закріплені посилання, ваші зображення) ніколи не змінюється. Канали: **стабільний** (типово) і **тестовий** (попередні випуски). Жодна телеметрія не надсилається.

## Capture і replay

`.cpuimg` зберігає сирі листи CPUID; `.sysimg` зберігає сирі дані SMBIOS, ідентифікатори PCI, адаптери DXGI та дескриптори дисків/сторінки NVMe/SMART. Обидва — текстові файли, і вони проходять через **ті самі декодери**, що й живі дані, тож парсери тестуються без обладнання. `capture-sys` типово маскує серійні номери та UUID SMBIOS (зсуви залишаються коректними). Формат: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Модель безпеки

- GUI і CLI працюють від імені звичайного користувача; нічого не встановлюється.
- Необов’язковий драйвер `FerrumScopeMsr.sys` працює **лише на читання**: три IOCTL, **список дозволених** MSR (APERF/MPERF), кожен запит перевіряється в ядрі, доступ до пристрою обмежено групами SYSTEM та Administrators (`IoCreateDeviceSecure`), шляху запису немає взагалі. На реальній системі його ще не завантажували. Подробиці: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Диски отримують лише команди читання (IOCTL запитів до сховища, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Бібліотеки GPU виробників завантажуються лише з System32, і використовуються тільки функції запиту.
- Серійні номери маскуються в GUI, звітах і файлах capture, якщо ви явно не попросите їх показати.

## Джерела даних і ліцензії

- Вихідний код FerrumScope: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **або** BSD-3-Clause.
- База CPU (`db/source/cpu/*.toml`): кожен запис посилається на своє джерело (AMD revision guides, діапазони моделей із ядра Linux, публічні дампи CPUID). Жодних даних із CPU-Z чи GPU-Z — див. [reference/README.md](../reference/README.md).
- `assets/logos/` **не** підпадає під дію GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA і GeForce є торговельними марками відповідних власників; логотипи використовуються лише для ідентифікації обладнання й не означають жодного схвалення. Походження кожного файлу: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- Посилання на TechPowerUp — це звичайні посилання, які відкриваєте ви; жодні дані TechPowerUp не завантажуються й не зберігаються.
