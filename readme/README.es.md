**Languages:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#compilación)

Una herramienta abierta y transparente de información de hardware para Windows — «CPU-Z + GPU-Z en uno», escrita en Zig. Cada valor muestra **de dónde procede** (hoja CPUID, offset de SMBIOS, base de datos de ID PCI, byte del log NVMe, biblioteca del fabricante…) y **con qué confianza** lo afirma el programa. Las funciones principales no necesitan controlador y no hay telemetría.

![Pestaña CPU de FerrumScope](../docs/screenshots/cpu.png)

## Contenido

- [Características](#características)
- [Capturas de pantalla](#capturas-de-pantalla)
- [Idioma de la interfaz](#idioma-de-la-interfaz)
- [Qué requiere un controlador o permisos de administrador](#qué-requiere-un-controlador-o-permisos-de-administrador)
- [Compilación](#compilación)
- [GUI](#gui)
- [Línea de comandos](#línea-de-comandos)
- [Enlaces de búsqueda](#enlaces-de-búsqueda)
- [Actualizaciones](#actualizaciones)
- [Captura y replay](#captura-y-replay)
- [Modelo de seguridad](#modelo-de-seguridad)
- [Fuentes de datos y licencias](#fuentes-de-datos-y-licencias)

## Características

- **CPU** — identificación a partir de CPUID y de una base de datos de hardware con procedencia documentada (nombre en clave, microarquitectura, revisión, zócalo), familia/modelo/stepping, la lista completa del conjunto de instrucciones (MMX … AVX-512, AES, SHA, VT-x/AMD-V) con la hoja y el bit de CPUID de cada una, el nivel x86-64 derivado, las cachés mostradas como `8 x 32 KB`, la topología y una estimación del reloj **sin controlador** con la carga por núcleo y total.
- **Placa base** — fabricante, modelo, revisión y BIOS (SMBIOS tipos 0/1/2/3/4), el chipset deducido de los ID PCI y todos los dispositivos PCI con su nombre según el `pci.ids` integrado.
- **Memoria** — módulos según SMBIOS tipo 17 (ranura, tamaño, DDR4/DDR5, velocidad y velocidad configurada, fabricante, número de pieza, rank, voltaje), el tamaño total y una heurística de canales claramente señalada.
- **Gráficos** — DXGI y SetupAPI: nombres, ID de fabricante/dispositivo/subsistema/revisión, el nombre de la tarjeta según `pci.ids`, versión y fecha del controlador, memoria dedicada y compartida, el enlace PCIe. Los relojes, temperaturas, ventilador, carga y consumo proceden de **AMD ADL** o **NVIDIA NVAPI**, cargadas en tiempo de ejecución, en solo lectura y de forma opcional.
- **Almacenamiento** — modelo, firmware, bus, tamaño y número de serie (oculto). Log de salud NVMe sin permisos de administrador, SMART de SATA como administrador: temperatura, horas de funcionamiento, desgaste y una regla de salud explícita.
- **Sensores** — carga y reloj de la CPU, sensores de la GPU, temperaturas de los discos. Sensores de CPU basados en MSR mediante el controlador opcional; los ventiladores de la placa base aparecen como *requiere controlador (previsto)*.
- **Exportación de informes** — TXT, HTML y JSON. Los números de serie y los UUID están **ocultos por defecto**.
- **Dos vistas** — una vista compacta al estilo de CPU-Z (por defecto) y una lista completa con la fuente y la confianza de cada campo (`Ctrl+L`).
- **27 idiomas de interfaz**, un **actualizador** con canales estable y de prueba, y botones de **búsqueda** para la base de datos de TechPowerUp y las páginas de controladores de los fabricantes.

## Capturas de pantalla

| CPU | Gráficos |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Gráficos](../docs/screenshots/graphics.png) |

| Placa base | Memoria |
|---|---|
| ![Placa base](../docs/screenshots/board.png) | ![Memoria](../docs/screenshots/memory.png) |

| Almacenamiento (administrador, SMART de SATA) | Vista de lista completa |
|---|---|
| ![Almacenamiento](../docs/screenshots/admin_storage.png) | ![Lista completa](../docs/screenshots/list_board.png) |

Todas las pestañas y ambas vistas: [docs/screenshots](../docs/screenshots).

## Idioma de la interfaz

La GUI, la línea de comandos y los informes TXT/HTML están disponibles en 27 idiomas: polaco (idioma de origen), inglés, búlgaro, checo, danés, alemán, griego, español, estonio, finés, francés, croata, húngaro, italiano, lituano, letón, noruego bokmål, neerlandés, portugués (Brasil), rumano, ruso, eslovaco, esloveno, serbio (latino), sueco, turco y ucraniano.

El idioma se elige en este orden: el ajuste guardado (`data\settings.ini`), el idioma de visualización de Windows y, por último, el inglés. Se puede cambiar en la GUI (selector de idioma) o con `ferrumscope lang <code>` / `--lang=<code>`. Los valores técnicos (nombres de instrucciones, unidades, ID PCI) nunca se traducen, y las claves de la exportación JSON se mantienen en inglés. Traductores: consulten [locales/README.md](../locales/README.md).

## Qué requiere un controlador o permisos de administrador

| Datos | Requisito |
|---|---|
| CPU, placa base, memoria, gráficos, salud de NVMe, descriptores de discos | nada (usuario normal) |
| SMART de SATA | ejecutar como administrador; sin ello el programa lo indica y sigue funcionando |
| APERF/MPERF, temperaturas desde MSR | el controlador `FerrumScopeMsr.sys` — **no se instala automáticamente** |
| Ventiladores/voltajes de la placa base (Super I/O), timings del SPD (SMBus) | un controlador de kernel — **previsto, no implementado** |

## Compilación

Solo se necesita la versión fijada Zig 0.15.2.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` compila e inicia la GUI. El controlador opcional se compila por separado con el WDK (`driver/build_driver.bat`) y la compilación nunca lo instala.

## GUI

- Pestañas: CPU, Cachés, Placa base, Memoria, Gráficos, Unidades, Sensores, Pruebas (reservada), Acerca de.
- Pase el ratón sobre un valor para ver su fuente, su confianza y el valor en bruto. **Mostrar fuentes** añade un pequeño marcador junto a cada campo.
- **Lista completa** (`Ctrl+L`) muestra todos los campos con su fuente; la elección se recuerda. `F5` actualiza los datos estáticos (SMBIOS, PCI, discos).
- **Distintivo/logotipo** en las pestañas CPU y Gráficos. Prioridad: su propia imagen → un logotipo del fabricante incluido → un distintivo dibujado por FerrumScope. Coloque sus propios archivos PNG junto al programa, en `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (p. ej. `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (p. ej. `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Los nombres van en minúsculas y cada carácter no alfanumérico se sustituye por `-`. Al hacer clic en el distintivo se abre el enlace de búsqueda.
- Opciones de línea de comandos: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Línea de comandos

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

## Enlaces de búsqueda

Los botones **Buscar** y el distintivo abren la base de datos de GPU/CPU de TechPowerUp. Se usa la página exacta cuando se conoce, en este orden:

1. un enlace que haya fijado usted mismo: copie la dirección de la página en el navegador y haga clic en **Fijar…** junto al campo (se guarda en `data\links.toml`);
2. la tabla seleccionada [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml): las entradas se añaden a mano (`source = "manual"`), nunca mediante rastreo; se aceptan pull requests;
3. en otro caso, una búsqueda por nombre.

Solo se guardan enlaces; no se descarga nada de TechPowerUp. Direcciones aceptadas: `https://` en techpowerup.com o en el sitio del fabricante.

## Actualizaciones

FerrumScope consulta las versiones publicadas en GitHub de `snakex21/FerrumScope` por HTTPS: como máximo una vez al día al iniciarse (se puede desactivar) o a petición en **Acerca de → Buscar actualizaciones…** / `ferrumscope update --check`. Una actualización solo se instala después de que el zip descargado coincida **tanto** con el SHA-256 de `ferrumscope-update.json` como con `SHA256SUMS`; el exe anterior se conserva como `.old` (`ferrumscope update --rollback`) y la carpeta `data\` (ajustes, enlaces fijados, sus imágenes) nunca se toca. Canales: **estable** (por defecto) y **de prueba** (versiones preliminares). No se envía ninguna telemetría.

## Captura y replay

`.cpuimg` almacena hojas CPUID en bruto; `.sysimg` almacena SMBIOS en bruto, ID PCI, adaptadores DXGI y descriptores de discos/páginas NVMe/SMART. Ambos son archivos de texto y pasan por **los mismos decodificadores** que los datos en vivo, de modo que los analizadores se prueban sin hardware. `capture-sys` oculta por defecto los números de serie y el UUID de SMBIOS (los offsets siguen siendo válidos). Formato: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Modelo de seguridad

- La GUI y la CLI se ejecutan como usuario normal; no se instala nada.
- El controlador opcional `FerrumScopeMsr.sys` es **de solo lectura**: tres IOCTL, una **lista de permitidos** de MSR (APERF/MPERF), cada solicitud se valida en el kernel, el acceso al dispositivo está limitado a SYSTEM y Administradores (`IoCreateDeviceSecure`) y no existe ninguna ruta de escritura. Todavía no se ha cargado en un sistema real. Detalles: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Los discos solo reciben comandos de lectura (IOCTL de consulta de almacenamiento, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- Las bibliotecas de GPU de los fabricantes solo se cargan desde System32 y solo se usan funciones de consulta.
- Los números de serie están ocultos en la GUI, los informes y las capturas, salvo que los solicite explícitamente.

## Fuentes de datos y licencias

- Código fuente de FerrumScope: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **o** BSD-3-Clause.
- Base de datos de CPU (`db/source/cpu/*.toml`): cada entrada cita su fuente (guías de revisión de AMD, rangos de modelos del kernel de Linux, volcados públicos de CPUID). Sin datos de CPU-Z ni de GPU-Z: véase [reference/README.md](../reference/README.md).
- `assets/logos/` **no** está cubierto por la GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA y GeForce son marcas comerciales de sus respectivos propietarios; los logotipos se usan únicamente para identificar el hardware y no implican ningún respaldo. Origen de cada archivo: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- Los enlaces de TechPowerUp son simples enlaces que abre usted; no se descarga ni se almacena ningún dato de TechPowerUp.
