# Źródłowa hardware database

To jest **źródło prawdy** FerrumScope. Pliki TOML są czytane przez człowieka,
poprawiane ręcznie i wersjonowane w gicie. Kompilator bazy (`tools/hwdb/compile.zig`)
waliduje je i generuje `ferrum-hwdb.bin`.

## Struktura

```
db/source/
├── cpu/
│   ├── intel.toml       # rodziny, wzorce generujące nazwy, pojedyncze SKU
│   ├── amd.toml
│   ├── apple.toml       # Apple Silicon: identyfikacja po `hw.model`, nie CPUID
│   └── hygon.toml
├── gpu/
│   ├── nvidia.toml      # chip (po device_id) + board (po subvendor/subdevice)
│   ├── amd.toml
│   ├── intel.toml
│   └── apple.toml
├── chipset/
├── pci/                 # GENEROWANE — patrz niżej
└── fixtures/            # złote pliki .fcap dla testów regresyjnych
```

## Zasada prowadzenia źródła (provenance) — obowiązkowa

**Wpis bez `source` nie przechodzi kompilacji.** Każdy wpis musi wskazywać, skąd
pochodzi, wraz z rewizją danych:

```toml
source        = "amd-pub"        # identyfikator źródła
source_url    = "https://..."    # gdzie można zweryfikować
source_rev    = "2026-09-25"     # data rewizji, którą opisujemy
confidence    = "high"           # high | medium | low — widoczne w `ferrumscope explain`
```

Dozwolone identyfikatory źródeł są zdefiniowane w `db/source/SOURCES.toml`
i wymagają wpisu w `docs/03-hwdb.md` §4. Każde źródło ma własną licencję
i sposób atrybucji.

## Pliki generowane

`pci/pci.ids.toml` jest **generowany** — nie edytuj ręcznie.

```sh
python tools/hwdb/pciids_import.py           # pobiera cache (pci.ids) i generuje TOML
python tools/hwdb/pciids_import.py --check   # walidacja istniejącego pliku
```

Źródło: PCI ID Repository <https://pci-ids.ucw.cz/>, licencja BSD-like,
**atrybucja wymagana**. W nagłówku pliku zapisywane są: URL, rewizja daty,
`source_sha256` i liczba odrzuconych duplikatów.

Stan po ostatnim imporcie (rewizja `2026-09-25 03:15:01`):

```
858 vendorów, 9915 urządzeń, 377 odrzuconych duplikatów, 0 błędów walidacji
```

Reguła rozstrzygania duplikatów: **pierwsze wystąpienie wygrywa** (źródło zawiera
realne powtórzenia, np. `1089:0001` występuje kilka razy z różnymi nazwami).

## Czego tu **nie ma** i dlaczego

| Źródło | Dlaczego nie |
|---|---|
| Bazy CPU-Z / GPU-Z | Zastrzeżone. Zawartość jest w kwarantannie `reference/`, poza produktem (`reference/README.md`) |
| `hwdata` z Linuksa | GPL-2.0+ — wymagałaby GPL dla całego projektu |
|Wpisy „wzięte z internetu" bez URL | Nieprowadzalne i nieaudytowalne — kompilator odrzuca |

## Dodawanie nowego SKU

1. Sprawdź, czy identyfikator jest już w `pci/pci.ids.toml` (to rozstrzyga warstwę
   chip/board i większość rzeczy jest już tam).
2. Dodaj wpis do odpowiedniego TOML-a z pełnym provenance.
3. Zweryfikuj: `python tools/hwdb/pciids_import.py --check` i `zig build hwdb-check`.
4. Dodaj przypadek do `db/fixtures/golden.toml`, żeby zmiana nazwy łamała test.

## Zasada aktualizacji

- **Nowy SKU istniejącej rodziny** → zmiana w bazie. Program się nie zmienia.
- **Nowa rewizja wymagająca dodatkowej interpretacji** → baza + mały dekoder.
- **Zupełnie nowa metoda odczytu sprzętu** → nowa wersja programu/backendu.
