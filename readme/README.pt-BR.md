**Idiomas:** [English](../README.md) · [Polski](README.pl.md) · [Български](README.bg.md) · [Čeština](README.cs.md) · [Dansk](README.da.md) · [Deutsch](README.de.md) · [Ελληνικά](README.el.md) · [Español](README.es.md) · [Eesti](README.et.md) · [Suomi](README.fi.md) · [Français](README.fr.md) · [Hrvatski](README.hr.md) · [Magyar](README.hu.md) · [Italiano](README.it.md) · [Lietuvių](README.lt.md) · [Latviešu](README.lv.md) · [Norsk bokmål](README.nb.md) · [Nederlands](README.nl.md) · [Português (Brasil)](README.pt-BR.md) · [Română](README.ro.md) · [Русский](README.ru.md) · [Slovenčina](README.sk.md) · [Slovenščina](README.sl.md) · [Srpski](README.sr-Latn.md) · [Svenska](README.sv.md) · [Türkçe](README.tr.md) · [Українська](README.uk.md)

# FerrumScope

[![CI](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml/badge.svg)](https://github.com/snakex21/FerrumScope/actions/workflows/ci.yml) [![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](../LICENSE) [![Zig](https://img.shields.io/badge/Zig-0.15.2-F7A41D?logo=zig)](../build.zig.zon) [![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)](#compilação)

Uma ferramenta aberta e transparente de informações de hardware para Windows — "CPU-Z + GPU-Z em um só", escrita em Zig. Cada valor mostra **de onde veio** (folha CPUID, offset SMBIOS, banco de dados de IDs PCI, byte do log NVMe, biblioteca do fabricante…) e **qual o grau de confiança** do programa nele. Nenhum driver é necessário para as funções principais, e não há telemetria.

![Aba CPU do FerrumScope](../docs/screenshots/cpu.png)

## Conteúdo

- [Recursos](#recursos)
- [Capturas de tela](#capturas-de-tela)
- [Idioma da interface](#idioma-da-interface)
- [O que requer driver ou direitos de administrador](#o-que-requer-driver-ou-direitos-de-administrador)
- [Compilação](#compilação)
- [GUI](#gui)
- [Linha de comando](#linha-de-comando)
- [Links de pesquisa](#links-de-pesquisa)
- [Atualizações](#atualizações)
- [Captura e replay](#captura-e-replay)
- [Modelo de segurança](#modelo-de-segurança)
- [Fontes de dados e licenças](#fontes-de-dados-e-licenças)

## Recursos

- **CPU** — identificação a partir do CPUID e de um banco de dados de hardware com procedência rastreada (codinome, microarquitetura, revisão, soquete), família/modelo/stepping, a lista completa do conjunto de instruções (MMX … AVX-512, AES, SHA, VT-x/AMD-V) com a folha e o bit CPUID de cada uma, o nível x86-64 derivado, caches exibidos como `8 x 32 KB`, topologia e uma estimativa de clock **sem driver** com carga por núcleo e total.
- **Placa-mãe** — fabricante, modelo, revisão e BIOS (SMBIOS tipos 0/1/2/3/4), o chipset deduzido dos IDs PCI e todos os dispositivos PCI nomeados a partir do `pci.ids` embutido.
- **Memória** — módulos do SMBIOS tipo 17 (slot, tamanho, DDR4/DDR5, velocidade e velocidade configurada, fabricante, part number, rank, tensão), o tamanho total e uma heurística de canais claramente identificada como tal.
- **Gráficos** — DXGI e SetupAPI: nomes, IDs de fabricante/dispositivo/subsistema/revisão, o nome da placa a partir do `pci.ids`, versão e data do driver, memória dedicada e compartilhada, o link PCIe. Clocks, temperaturas, ventoinha, carga e consumo vêm do **AMD ADL** ou do **NVIDIA NVAPI**, carregados em tempo de execução, somente leitura e opcionais.
- **Armazenamento** — modelo, firmware, barramento, tamanho e número de série (mascarado). Log de saúde NVMe sem direitos de administrador, SATA SMART como administrador: temperatura, horas ligado, desgaste e uma regra de saúde explícita.
- **Sensores** — carga e clock da CPU, sensores da GPU, temperaturas dos discos. Sensores de CPU baseados em MSR por meio do driver opcional; as ventoinhas da placa-mãe aparecem como *requer driver (planejado)*.
- **Exportação de relatórios** — TXT, HTML e JSON. Números de série e UUIDs são **mascarados por padrão**.
- **Duas visualizações** — uma visualização compacta no estilo do CPU-Z (padrão) e uma lista completa com a fonte e a confiança de cada campo (`Ctrl+L`).
- **27 idiomas de interface**, um **atualizador** com canais estável e de teste, botões de **pesquisa** para o banco de dados da TechPowerUp e para as páginas de drivers dos fabricantes.

## Capturas de tela

| CPU | Gráficos |
|---|---|
| ![CPU](../docs/screenshots/cpu.png) | ![Gráficos](../docs/screenshots/graphics.png) |

| Placa-mãe | Memória |
|---|---|
| ![Placa-mãe](../docs/screenshots/board.png) | ![Memória](../docs/screenshots/memory.png) |

| Armazenamento (administrador, SATA SMART) | Visualização em lista completa |
|---|---|
| ![Armazenamento](../docs/screenshots/admin_storage.png) | ![Lista completa](../docs/screenshots/list_board.png) |

Todas as abas e ambas as visualizações: [docs/screenshots](../docs/screenshots).

## Idioma da interface

A GUI, a linha de comando e os relatórios TXT/HTML estão disponíveis em 27 idiomas: polonês (original), inglês, búlgaro, tcheco, dinamarquês, alemão, grego, espanhol, estoniano, finlandês, francês, croata, húngaro, italiano, lituano, letão, norueguês bokmål, holandês, português (Brasil), romeno, russo, eslovaco, esloveno, sérvio (latino), sueco, turco e ucraniano.

O idioma é escolhido nesta ordem: a configuração salva (`data\settings.ini`), o idioma de exibição do Windows e, por fim, o inglês. Altere-o na GUI (seletor de idioma) ou com `ferrumscope lang <code>` / `--lang=<code>`. Valores técnicos (nomes de instruções, unidades, IDs PCI) nunca são traduzidos, e as chaves da exportação JSON permanecem em inglês. Tradutores: vejam [locales/README.md](../locales/README.md).

## O que requer driver ou direitos de administrador

| Dados | Requisito |
|---|---|
| CPU, placa-mãe, memória, gráficos, saúde NVMe, descritores de disco | nada (usuário comum) |
| SATA SMART | executar como administrador; sem isso o programa avisa e continua funcionando |
| APERF/MPERF, temperaturas via MSR | o driver `FerrumScopeMsr.sys` — **não é instalado automaticamente** |
| Ventoinhas/tensões da placa-mãe (Super I/O), timings SPD (SMBus) | um driver de kernel — **planejado, não implementado** |

## Compilação

Só é necessário o Zig 0.15.2 fixado.

```sh
python tools/fetch_zig.py                         # downloads Zig 0.15.2 and verifies its SHA-256
tools/zig/zig-x86_64-windows-0.15.2/zig build     # zig-out/bin/ferrumscope.exe + ferrumscope-gui.exe
tools/zig/zig-x86_64-windows-0.15.2/zig build test
tools/zig/zig-x86_64-windows-0.15.2/zig build -Doptimize=ReleaseSafe
```

`ferrumscope-gui.bat` compila e inicia a GUI. O driver opcional é compilado separadamente com o WDK (`driver/build_driver.bat`) e nunca é instalado pela compilação.

## GUI

- Abas: CPU, Cache, Placa-mãe, Memória, Gráficos, Unidades, Sensores, Bench (reservada), Sobre.
- Passe o mouse sobre um valor para ver a fonte, a confiança e o valor bruto. **Mostrar fontes** adiciona um pequeno marcador ao lado de cada campo.
- **Lista completa** (`Ctrl+L`) mostra todos os campos com a respectiva fonte; a escolha é lembrada. `F5` atualiza os dados estáticos (SMBIOS, PCI, discos).
- **Emblema/logo** nas abas CPU e Gráficos. Prioridade: sua própria imagem → um logo de fabricante incluído → um emblema desenhado pelo FerrumScope. Coloque seus próprios arquivos PNG ao lado do programa em `data\images\`:
  - CPU: `cpu\<vendor>-<series>-<model>.png` → `cpu\<vendor>-<series>.png` → `cpu\<vendor>.png` (ex.: `cpu\amd-ryzen-7-5800x3d.png`)
  - GPU: `gpu\<vid>-<did>.png` (ex.: `gpu\1002-744c.png`) → `gpu\<vendor>-<series>-<model>.png` → `gpu\<vendor>-<series>.png` → `gpu\<vendor>.png`

  Os nomes ficam em minúsculas, com todo caractere não alfanumérico substituído por `-`. Clicar no emblema abre o link de pesquisa.
- Opções de linha de comando: `--tab=cpu|caches|board|memory|graphics|storage|sensors|bench|about`, `--list`, `--structured`, `--lang=<code>`.

## Linha de comando

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

## Links de pesquisa

Os botões **Pesquisar** e o emblema abrem o banco de dados de GPUs/CPUs da TechPowerUp. A página exata é usada quando é conhecida, nesta ordem:

1. um link que você mesmo fixou — copie o endereço da página no navegador e clique em **Fixar…** ao lado do campo (salvo em `data\links.toml`);
2. a tabela curada [`db/source/links/techpowerup.toml`](../db/source/links/techpowerup.toml) — as entradas são adicionadas manualmente (`source = "manual"`), nunca por rastreamento automático; pull requests são bem-vindos;
3. caso contrário, uma busca por nome.

Apenas links são armazenados; nada é baixado da TechPowerUp. Endereços aceitos: `https://` em techpowerup.com ou no site do fabricante.

## Atualizações

O FerrumScope verifica as releases do GitHub de `snakex21/FerrumScope` via HTTPS — no máximo uma vez por dia ao iniciar (pode ser desativado) ou sob demanda em **Sobre → Verificar atualizações** / `ferrumscope update --check`. Uma atualização só é instalada depois que o zip baixado corresponde **tanto** ao SHA-256 em `ferrumscope-update.json` **quanto** ao `SHA256SUMS`; o exe anterior é mantido como `.old` (`ferrumscope update --rollback`) e a pasta `data\` (configurações, links fixados, suas imagens) nunca é alterada. Canais: **estável** (padrão) e **teste** (pré-lançamentos). Nenhuma telemetria é enviada.

## Captura e replay

`.cpuimg` armazena folhas CPUID brutas; `.sysimg` armazena SMBIOS bruto, IDs PCI, adaptadores DXGI e descritores de disco/páginas NVMe/SMART. Ambos são arquivos de texto e passam **pelos mesmos decodificadores** que os dados ao vivo, de modo que os parsers são testados sem hardware. `capture-sys` mascara por padrão os números de série e o UUID do SMBIOS (os offsets continuam válidos). Formato: [docs/04-fcap-i-testy.md](../docs/04-fcap-i-testy.md).

## Modelo de segurança

- A GUI e a CLI são executadas como usuário comum; nada é instalado.
- O driver opcional `FerrumScopeMsr.sys` é **somente leitura**: três IOCTLs, uma **lista de permissões** de MSR (APERF/MPERF), cada requisição validada no kernel, acesso ao dispositivo restrito a SYSTEM e Administradores (`IoCreateDeviceSecure`), sem nenhum caminho de escrita. Ele ainda não foi carregado em um sistema real. Detalhes: [docs/SECURITY-MODEL.md](../docs/SECURITY-MODEL.md).
- Os discos recebem apenas comandos de leitura (IOCTLs de consulta de armazenamento, NVMe Get Log Page 02h, ATA SMART READ DATA/THRESHOLDS).
- As bibliotecas de GPU dos fabricantes são carregadas apenas de System32, e somente funções de consulta são usadas.
- Os números de série são mascarados na GUI, nos relatórios e nas capturas, a menos que você os solicite explicitamente.

## Fontes de dados e licenças

- Código-fonte do FerrumScope: **GPL-3.0-or-later** ([LICENSE](../LICENSE), [NOTICE.md](../NOTICE.md)).
- `db/source/pci/pci.ids`: PCI ID Repository, GPL-2.0-or-later **ou** BSD-3-Clause.
- Banco de dados de CPUs (`db/source/cpu/*.toml`): cada entrada cita sua fonte (guias de revisão da AMD, faixas de modelos do kernel Linux, dumps públicos de CPUID). Nenhum dado do CPU-Z ou do GPU-Z — veja [reference/README.md](../reference/README.md).
- `assets/logos/` **não** é coberto pela GPL. AMD, Ryzen, Threadripper, EPYC, Radeon, Intel, Core, Xeon, NVIDIA e GeForce são marcas comerciais de seus respectivos proprietários; os logos são usados apenas para identificar o hardware e não implicam nenhum endosso. Origem de cada arquivo: [assets/logos/SOURCES.md](../assets/logos/SOURCES.md).
- Os links da TechPowerUp são links simples abertos por você; nenhum dado da TechPowerUp é baixado ou armazenado.
