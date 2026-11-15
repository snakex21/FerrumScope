# FerrumScope — hardware database

Status: format źródłowy jest **wdrożony** (`db/source/pci/pci.ids.toml` generowany
i walidowany przez `tools/hwdb/pciids_import.py`). Format skompilowany i formaty
CPU/GPU są projektem.

---

## 1. Zasady nadrzędne

1. **Baza jest danymi, nie kodem.** Wbudowany i zewnętrzny `ferrum-hwdb.bin` nie wykonuje
   żadnych instrukcji. Parser czyta wyłącznie tablice i ciągi.
2. **Każdy wpis ma prowadzenie źródła** (`source`), z rewizją i datą. Wpis bez
   prowadzenia jest błędem kompilacji.
3. **Kompilacja jest walidacją.** `zig build hwdb` odrzuca bazę z duplikatami,
   nieznanymi referencjami i niespójnym schematem.
4. **Nieznany sprzęt to nie błąd.** Dekoder musi zawsze zwrócić `Name` z `fallback`.
5. **Aktualizacja bazy nie wymaga aktualizacji programu** dla nowych SKU istniejącej
   rodziny; nowa metoda odczytu wymaga nowej wersji programu.

---

## 2. Format źródłowy

### 2.1 CPU — `db/source/cpu/amd.toml`

```toml
# db/source/cpu/amd.toml
[meta]
schema = "ferrum.hwdb.cpu.v1"
source = "amd-pub + pkgs.org + cpuid-observeration"
source_rev = "2026-09-25"
maintainer = "FerrumScope contributors"

# Rodziny z wzorcami generującymi nazwy.
# Wzorzec używa pól podstawionych przez decode/cpu/x86.zig.
[[family]]
id = "zen4"
vendor = 0x0000          # AuthenticAMD
display = "AMD Zen 4"
isa = "x86_64"
launch_year = 2022
source = "amd-pub"
source_url = "https://www.amd.com/en/products/processors"

  # Generowanie nazwy dla całej serii zamiast wpisywania 200 linii.
  [[family.model]]
  extended_family = 0x19   # 25
  model_min = 0x61          # 0x61..0x74
  model_max = 0x74
  name_pattern = "AMD Ryzen 9 {core_count}{suffix} {model_suffix}"
  # suffix dobierany z poniższej tabeli po steppingu
  suffix = "X"
  # jeśli nie pasuje — dekoder schodzi do MatchQuality.pattern
  source = "amd-pub"

  [[family.model.name]]
  stepping_max = 0x1
  display = "AMD Ryzen 9 5950X"

# Pojedynczy, precyzyjny wpis — wygrywa nad wzorcem rodziny.
[[sku]]
vendor = 0x0000
extended_family = 0x19
model = 0x61
stepping = 0x0
display = "AMD Ryzen 9 5950X"
codename = "Vermeer"
cores = 16
threads = 32
base_clock_mhz = 3400
max_boost_mhz = 4900
process_nm = 7
socket = "AM4"
memory_types = ["DDR4"]
launch = "2020-11-05"
source = "amd-pub"
source_url = "https://www.amd.com/en/products/processors/ryzen-9-5950x"
confidence = "high"      # high | medium | low — widoczne w `explain`
notes = """
Pierwszy z 8-rdzeniowych... (opis własny, bez cytowania materiałów
producenta poza nazwą własną i parametrami technicznymi)
"""
```

### 2.2 GPU — `db/source/gpu/nvidia.toml`

```toml
[meta]
schema = "ferrum.hwdb.gpu.v1"
source = "pciids + nvidia-pub"
source_rev = "2026-09-25"

# Chip: po device_id. To jest warstwa "rdzeń + generacja".
[[chip]]
vendor = 0x10DE
device = 0x2684
display = "GeForce RTX 4090"
chip_codename = "AD102"
family = "blackwell"
vram_min_mb = 24564
source = "pciids"

# Karta partnerska: po subvendor/subdevice. Osobna warstwa.
[[board]]
vendor = 0x10DE
device = 0x2684
subvendor = 0x1043
subdevice = 0x8962
display = "ASUS TUF Gaming GeForce RTX 4090"
formfactor = "3-slot"
length_mm = 348
source = "vendor-pub"
confidence = "medium"
```

### 2.3 Zasady walidacji źródła

| Reguła | Konsekwencja błędu |
|---|---|
| `[[sku]]` z tym samym `(vendor, ext_family, model, stepping)` | błąd — duplikat |
| `source` pusty lub brak `source_url` dla wpisu `confidence != "low"` | błąd |
| `chip.display` zawiera `%s`/`%d` | błąd — nazwa nie może być formatowana |
| `family.model.model_min > model_max` | błąd |
| `[[board]]` z nieznanym `(vendor, device)` | ostrzeżenie + korekta przy kompilacji |
| odwołanie `chip_codename` nieistniejącej rodziny | błąd |
| `confidence` spoza enum | błąd |

Walidacja działa dwutorowo: `tools/hwdb/pciids_import.py --check` (lekka, bez zależności)
oraz `zig build hwdb-check` (pełna, wraz z kompilatorem bazy).

---

### 2.4 Sekcje `[[fact]]` i `[[brand_rule]]` (format v3)

Obie są **dane**, nie kod — i obie mają **wymuszony `vendor`**.

```toml
# Fakt o sygnaturze: to, czego CPUID nie zwraca.
[[fact]]
vendor = "amd"            # OBOWIĄZKOWY
ext_family = 0x0A
family_field = 0x0F
model_min = 0x21
model_max = 0x21
stepping_min = 0x02       # wąski zakres: zmierzyliśmy tylko stepping 2
stepping_max = 0x02
stepping_name = "VMR-B2"
source_type = "reference_observation"   # obserwacja, NIE dokumentacja AMD
source = "cpu-z-3.01.0-txt"
source_url = "local oracle: do referencji/cpuz/cpuz_x64.exe -txt"
confidence = "medium"     # brak pierwotnego źródła AMD dla Models 20h-2Fh
notes = "Cyfra 2 = stepping CPUID. Prefiks VMR i litera B = obserwacja."

# Reguła refinamentu z brand stringu.
[[brand_rule]]
vendor = "amd"            # OBOWIĄZKOWY — bez tego reguła byłaby globalna
ext_family = 0x0A
family_field = 0x0F
model_min = 0x20
model_max = 0x2F
brand_pattern = "5800X3D"        # dopasowanie w znormalizowanym brand stringu
product_name = "Ryzen 7 5800X3D"
variant = "3D V-Cache"
cache_variant = "3D V-Cache"
source_type = "derived"
source = "brand-string-5800x3d"
source_url = "CPUID brand string 0x80000002..4"
confidence = "high"
```

**Walidacja wymuszona przez kompilator** (nie konwencją):

| Reguła | Co się dzieje bez niej |
|---|---|
| `vendor` wymagany, nie `unknown`/`other` | globalne „X3D” przypisałoby wariant procesorowi **każdego** producenta |
| `brand_pattern` wymagany, niepusty | dopasowałby każdy brand |
| `source`, `source_type`, `confidence` wymagane | wpis bez pochodzenia to zgadywanie |
| co najmniej jedno z `product_name`/`variant`/`cache_variant` | reguła, która niczego nie ustawia |
| duplikat zakresu odrzucony | dwa różne warianty dla tej samej sygnatwy |
| `package_contacts` ≤ `u16` | cicho obcięta liczba |

### 2.5 Granica: czego te tabele **nie** mogą

* Reguła brand wzbogaca **wyłącznie** `product_name` / `variant` / `cache_variant`.
  Nie wolno jej dotknąć `vendor`, `family`, `model`, `stepping`, topologii ani
  cache zmierzonego ze sprzętu — brand string jest interpretacją.
* `package_contacts = 0` znaczy **„nie wiemy”**. Liczby widzianej w narzędziu
  referencyjnym nie przepisujemy jako danej producenta bez niezależnego źródła.
* `source_type = "reference_observation"` to **obserwacja**, nie dokumentacja —
  i tak jest widoczna w polu źródłowym wyniku.

## 3. Format skompilowany: `ferrum-hwdb.bin`

### 3.1 Nagłówek (little-endian, wersjonowany)

Nagłówek **jest** wersjonowany i ma stały układ bajtowy — nie `extern struct`,
bo kompilator zapisuje pola jawnie, a `extern struct` pozwoliłby cicho rozjechać
się polom po zmianie rozmiaru. Stan faktyczny (format **v3**):

```zig
pub const format_version: u16 = 3;            // 1 → 2 → 3: zawsze z breaking change
pub const minimum_reader_version: u16 = 3;    // = format_version: każda zmiana jest zmianą semantyki
pub const header_size: usize = 80;            // było 72 — doszły liczniki nowych sekcji
pub const entry_size: usize = 52;             // bez zmian w v3
pub const fact_size: usize = 32;              // nowa sekcja
pub const brand_rule_size: usize = 36;        // nowa sekcja

//  0..8   magic       "FERRUMDB"
//  8..10  format_version
// 10..12  schema_version
// 12..14  minimum_reader_version
// 14..16  zarezerwowane (0)
// 16..20  db_revision
// 20..24  built_unix            — znacznik, nie źródło prawdy
// 24..28  feature_flags         — patrz niżej
// 28..32  string_bytes
// 32..36  entry_count
// 36..68  sha256 (zawartość po nagłówku)
// 68..72  payload_length
// 72..76  fact_count           — v3
// 76..80  brand_rule_count     — v3
```

**`feature_flags`** — bity, których **wymaga** baza, a czytnik musi rozumieć:

| Bit | Nazwa | Znaczenie |
|---|---|---|
| 0 | `FAMILY_GENERIC` | baza zawiera wpisy `family_generic` |
| 1 | `SEMANTIC_FIELDS` | pola silicon/product/variant/cache |
| 2 | `IDENTITY_FACTS` | sekcja `Fact` |
| 3 | `BRAND_RULES` | sekcja `BrandRule` |

Czytnik **odrzuca** plik, gdy widzi nieznany bit, zamiast zgadywać jego znaczenia
— dokładnie ta myśl, przez którą nowy format wciska się do starego czytnika
i zwraca złą nazwę CPU. Bity sekcji ustawiamy **warunkowo**: pusta sekcja nie
wymaga dodatkowej umiejętności od czytnika i nie powinna jej deklarować.

**Zasady kompatybilności wstecznej:**

- `format` inny niż znany → biblioteka **odmawia** wczytania, nie zgaduje.
- `minimum_reader_version` wyższy niż `format_version` → **odmawia** wczytania.
- Nieznany bit `feature_flags` → **odmawia** wczytania.
- `payload_length` nie zgadza się z rozmiarem pliku → **odmawia** wczytania
  (dopisane bajty nie mogą być po cichu zignorowane).
- `content_hash` nie pasuje → plik uszkodzony → odrzucamy i używamy wbudowanego.
- `db_revision` niższy niż wbudowany → **wbudowany wygrywa**.

### 3.2 Sekcje

```
Header (80 B)
├── String pool          ciągi UTF-8 (prefikso-współdzielone)   [string_bytes]
├── Entry table          n × 52 B                               [entry_count]
├── Fact table           m × 32 B                               [fact_count]     ← v3
└── BrandRule table      k × 36 B                               [brand_rule_count] ← v3
```

Kolejność sekcji jest **sztywna** i musi zgadzać się z `factsStart()` /
`brandRulesStart()` w czytniku: `strings → entries → facts → brand_rules`.

**Dlaczego `Fact` i `BrandRule` to osobne sekcje, a nie dodatkowe pola `Entry`:**

`Entry` decyduje `MatchQuality`, a `family_generic` opisuje całą rodzinę. Zakres
`0x20..0x3F` obejmuje desktop (AM4) **i** serwer (SP3) w jednym wpisie. Gdyby
`stepping_name` czy `socket_name` siedziały w `Entry`, opisanie gniazda wymusiłoby
rozbicie wpisu — czyli zmianę semantyki dopasowania. Osobne sekcje pozwalają
opisać sygnaturę precyzyjnie, **zostawiając trafienie modelu nietknięte**.

`Fact` ma pola o **różnym zakresie** (`VMR-B2` dotyczy jednego stepppingu, `AM4` —
całego modelu), dlatego czytnik szuka ich osobno (`steppingNameFact`, `socketFact`).
Pojedyncze „pierwsze dopasowanie" ukryłoby gniazdo za węższym wpisem.

`package_contacts = 0` znaczy **„nie wiemy"**, a nie „brak" — dlatego ma osobny
lookup (`packageContactsFact`), bo `0` i `pusty napis` to nie to samo.

### 3.3 Dlaczego taki układ

- **Indeksy zamiast liniowego skanu** — `ferrumscope` musi odpowiedzieć w mikrosekundach.
- **Drzewo przedziałowe dla CPU** — dopasowanie (ext_family, model, stepping) to nie
  prosty klucz, bo trzeba „najlepszego pasowania". Drzewo daje to w O(log n)
  i pozwala zwrócić `MatchQuality` bez skanowania.
- **String pool z kompresją prefiksową** — nazwy GPU powtarzają się masowo
  („Radeon RX 7900 XT/XTX/GRE" występuje w dziesiątkach podsystemów).
- **Provenance osobną sekcją** — kompilacja zachowuje wpisy nawet gdy plik jest
  współdzielony; `ferrumscope explain` pokazuje źródło dla każdego pola.

### 3.4 Wbudowany snapshot i zewnętrzna aktualizacja

```zig
pub const LoadOrder = enum { embedded_only, prefer_embedded, prefer_external };

// Domyślnie dla v1: prefer_embedded.
// Zewnętrzna baza wczytuje się tylko, gdy: format/schema OK, content_hash OK,
// db_revision >= wbudowanej, a użytkownik nie zablokował jej flagą.
```

Baza zewnętrzna jest **czystymi danymi**. Ładowanie jej nie może:
wykonywać kodu, otwierać plików, wywoływać sieci, albo modyfikować ścieżki wyszukiwania.

### 3.5 Regresja bazy

```sh
zig build hwdb-check                 # kompilacja + walidacja
zig build test-hwdb                  # złote przypadki
ferrumscope hwdb check db/source     # walidacja źródła bez kompilacji
ferrumscope hwdb stats               # liczba wpisów, pokrycie, confidence
```

Test regresyjny bazy to złota tabela: dla każdego SKU w `db/fixtures/golden.toml`
podajemy `(vendor, ext_family, model, stepping) → oczekiwane display`. Zmiana nazwy
w bazie **łamie test** — to jest zabezpieczenie przed cichą degradacją danych,
typu tej, którą właśnie naprawiliśmy w importerze (`is_hex` vs `isdigit` gubił
1660 vendorów, w tym całą NVIDIA).

---

## 4. Pochodzenie danych — stan faktyczny

| Źródło | Licencja | Status |
|---|---|---|
| PCI ID Repository (`pci-ids.ucw.cz`) | BSD-like, atrybucja wymagana | **wdrożone** → `db/source/pci/pci.ids.toml` |
| Dokumentacja AMD / Intel / NVIDIA | zastrzeżona, cytowanie dozwolone | do wprowadzania ręcznie, z `source_url` |
| `hwdata` z Linuksa | GPL-2.0+ | **odrzucone** — GPL-2 wymagałaby GPL dla całego projektu |
| CPU-Z / GPU-Z (nazwy, tabele) | zastrzeżone | **quarantine**, `reference/dumps/`, poza produktem |

Stan po uruchomieniu importu (rewizja `2026-09-25 03:15:01`):

```
858 vendorów, 9915 urządzeń, 0 błędów walidacji,
377 rozstrzygniętych duplikatów (przyjęta reguła: pierwsze wystąpienie wygrywa)
```

Reguła rozstrzygania duplikatów jest jawna, bo `pci.ids` realnie zawiera powtórzenia —
np. `1089:0001` występuje kilka razy z różnymi nazwami. Alternatywy rozważone:
ostatnie wystąpienie (zależne od kolejności edycji w źródle — niedobre),
głosowanie po źródłach (dobre, ale wymaga metadanych, których `pci.ids` nie ma).

**Kolejność ładowania bazy na dysku (loader):**
1. wbudowany snapshot (`@embedFile`, zawsze obecny);
2. `ferrum-hwdb.bin` z katalogu aplikacji;
3. `$XDG_CONFIG_HOME/ferrumscope/ferrum-hwdb.bin` (Linux),
   `%PROGRAMDATA%\FerrumScope\ferrum-hwdb.bin` (Windows),
   `~/Library/Application Support/FerrumScope/` (macOS).

Wyższy `db_revision` wygrywa; przy remisie wygrywa ścieżka o wyższym priorytecie.
Każde zastąpienie jest logowane i widoczne w `ferrumscope explain`.
