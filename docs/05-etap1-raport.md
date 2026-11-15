# FerrumScope — raport Etapu 1

> **STATUS: ZASTĄPIONY — dokument historyczny.**
>
> Ten raport opisuje stan **przed** correctness passem i **nie opisuje bieżącego
> builda**. Nie używaj go jako źródła prawdy o tym, co dziś działa, a co nie.
>
> Aktualny opis stanu: **`docs/06-correctness-pass.md`**
>
> Finalny stan Etapu 1 (po correctness pass):
>
> * `zig build` — **PASS**
> * `zig build test` — **74/74 PASS** (8/8 kroków; wcześniej 61/68)
> * **brand string naprawiony** — `AMD Ryzen 7 5800X3D 8-Core Processor` odczytany
>   z CPUID (liście `0x80000002..4`), znormalizowany i widoczny jako
>   `display=brand_string`; pusty brand string opisany niżej **już nie występuje**
> * **8C/16T naprawione** — zamiast błędnych 16 „rdzeni”; źródło: `quirk_smt_threads`
>   z bazy, bo liść `0x8000001E` opisuje bieżący wątek i bez thread pinning jest
>   niestabilny (pomiar: `0x02` dla ApicId 1 i `0x0C` dla ApicId 6)
> * **96 MB L3 zweryfikowane** — `98304 sets × 16 ways × 64 B = 100663296 B`,
>   poprawnie zdekodowane, nie z mnożenia; dodano guard przeciw podwójnemu
>   liczeniu z liścia 4 i `0x8000001D`
> * **native == replay** — ten sam `CpuInfo` z natywnego backendu i z tego samego
>   capture; brak oczekiwanych różnic
>
> Wszystkie poniższe liczby, twierdzenia o błędach i opisy funkcjonalności
> odnoszą się do **historycznego** stanu przed tym passem.
> Szczegółowy opis przyczyn, decyzji i napraw: `docs/06-correctness-pass.md`.
> Dalszy rozwój platform: `docs/07-etap2-platform-backends.md`.

---

Data: 2026-09-29. Stan w chwili pisania: `zig build` przechodzi, CLI działa, 61/68 testów przechodzi.

---

## 1. Dwie poprawki dokumentacyjne (przed implementacją)

### 1.1 Bloby GPU-Z — status CANDIDATE, nie „baza"

W pierwotnej wersji raportu nazwałem skompresowane bloby GPU-Z bazą danych. To był
wniosek wyprzedzający dowody. Poprawiony status w `docs/01-analiza-referencji.md` §3:

> **CANDIDATE / PROBABLE — niepotwierdzona baza danych.**
> Nie ustalono zawartości ani struktury. Wiemy tylko, że są skompresowane
> (lub zakodowane) niestandardowym algorytmem, towarzyszą programowi i nie są
> w PE. Nie opieramy na tym żadnej decyzji projektowej.

Znaczenie tej korekty: gdyby twierdzenie zostało, wyciągnęlibyśmy z niego wniosek
o podatności ich formatu — którego nie zweryfikowałem. Wniosek „baza jest w RCDATA"
wymagałby odtworzenia struktury, a tego nie zrobiłem.

### 1.2 `dbgeng.dll` — wniosek był zbyt mocny

Zmierzyłem importy i ciągi znakowe zamiast wnioskować z samego faktu importu:

| Fact (zmierzony) | Wartość |
|---|---|
| Funkcje importowane z `dbgeng.dll` | **dokładnie jedna: `DebugCreate`** |
| `NtLoadDriver` / `ZwLoadDriver` | 0 wystąpień |
| `DriverPackageInstall` / `DriverPackageAdd` | 0 wystąpień |
| Ścieżki `\\.\`, `\\Device\`, `\\DosDevices\` | 0 wystąpień |
| `DeviceIoControl` (KERNEL32) | jest — to IPC do sterownika |
| `SeLoadDriverPrivilege` | jest — ładowanie przez rejestr usług |
| `CPUID\...`, `cpuz165`, `_arm64.sys` | są — klasa sterownika i wariant ARM64 |
| `CPUID init driver error %u (0x%X)` | jest — komunikaty o błędach |

`DebugCreate` należy do interfejsu **klienta** debuggera (`IDebugClient`) — służy
do łączenia z *procesem*, nie ze sterownikiem. Biblioteka jest ładowana dynamicznie,
więc jej faktyczne użycie widać dopiero w czasie działania.

**Wniosek skorygowany:** CPU-Z komunikuje się ze sterownikiem przez `DeviceIoControl`
+ `SeLoadDriverPrivilege`. `dbgeng.dll` pozostaje czynnikiem niejednoznacznym.

**Ograniczenie:** nazwa urządzenia sterownika nie występuje w obrazie (budowana
w runtime lub zakodowana), więc identyfikatora urządzenia i kodów IOCTL analiza
statyczna nie odtworzy. Do tego potrzebna jest analiza dynamiczna.

**Konsekwencja dla architektury: żadna.** Model „sterownik wystawia prymitywy,
user-space interpretuje" opiera się na jednoznacznej tabeli importów sterownika,
nie na tej niepewnej hipotezie.

---

## 2. Toolchain

Pigmentowany Zig **0.15.2** w `tools/zig/` (nie z PATH). Pobiera `tools/fetch_zig.py`,
wersja zadeklarowana w `build.zig.zon` → `minimum_zig_version`.

Odkrycie warte zapisania: **Zig 0.15.2 wymaga jawnego typu zwracanego.**
`fn f() {}` jest odrzucane błędem `expected return type expression, found '{'`.
Potwierdzone eksperymentem na pięciu wariantach; jedynie z `void` sygnatura się
parsuje. `tools/fix_implicit_void.py` wykonuje tę migrację idempotentnie.

---

## 3. Co powstało

```
build.zig, build.zig.zon        pipeline: TOML -> baza -> wbudowany snapshot
src/
  root.zig                      korzeń biblioteki
  main.zig                      CLI
  tests.zig                     testy regresyjne na plikach capture
  core/     status ids raw model
  arch/x86/ cpuid               dekoder CPUID + wykonanie (inline asm)
  platform/ backend native replay
  probe/    cpu
  decode/   cpu_x86
  db/       hwdb embedded
  capture/  cpuimg
tools/
  hwdb_compile.zig              kompilator i walidator bazy
  fetch_zig.py, gen_fixtures.py, fix_implicit_void.py
db/source/cpu/ intel.toml amd.toml
db/fixtures/   5 plików .cpuimg
```

**Potok:** `Backend → probe → RawCpuInfo → decode → HWDB → CpuInfo → CLI`.
Probe i dekoder nie wiedzą, skąd pochodzą dane. `ReplayBackend` realizuje ten sam
kontrakt co platforma — te same wskaźniki funkcji, inny kontekst.

**Podział odpowiedzialności bazy:** HWDB **nie** zawiera wpisów na każdy SKU.
Nazwy marketingowe pochodzą z brand stringu CPUID; baza niesie to, czego CPUID nie
mówi — mikroarchitekturę, kodową nazwę i quirks. Każdy wpis ma obowiązkowe
provenance (`source`, `source_url` przy `confidence != low`).

**Quirks w bazie:** `no_brand_string`, `htt_unreliable`, `cache_leaf_ext`,
`extended_model_rule`, `hybrid_cores`. Kod stosuje je, baza tylko opisuje —
dokładnie ten podział, o który prosił plan.

**Baza jest danymi.** Kompilator TOML → walidacja → binarny obraz z sumą SHA-256 →
osadzony w programie jako źródło Zig. Runtime **nie parsuje TOML**.

**Walidacja w kompilatorze:** duplikaty zakresów, nakładanie się reguł, błędne
zakresy (`min > max`), nieznane enumy, brakujące pola obowiązkowe, literówki
w kluczach (nieznany klucz = błąd, nie ciche pominięcie).

---

## 4. Zweryfikowane

| Co | Stan |
|---|---|
| `zig build` | **exit 0** |
| `zig build test` | **61/68 przechodzi, 7 failuje** |
| `ferrumscope cpu` (natywnie, prawdziwy sprzęt) | działa — AMD Zen 3, Family 25 Model 0x21, Vermeer, 16 rdzeni, L3 96 MiB |
| `ferrumscope replay <plik>` | działa — Zen 3 z pliku, 8/16 rdzeni, 4 poziomy cache |
| Kompilacja HWDB (TOML → binarny) | działa jako build step |
| Wbudowana baza w CLI i testach | ta sama zmienna `hwdb_mod_path` |

Przykładowy wynik natywny:

```
  Name        : AMD (Family 25 Model 33)
  Signature   : 0x00A20F12  (Family 25, Model 0x21, Stepping 2)
  Microarch   : Zen 3
  Codename    : Milan-X / Vermeer (EPYC 3rd gen, Ryzen 5000)
  Cores       : 16 physical / 16 logical
      L3 unified         98304 KiB  16-way, line 64 B
  Dmatch      : exact (display=hwdb, decode=matched_exact)
  Db source   : amd-apm
```

---

## 5. Co NIE jest zweryfikowane / znane błędy

**7 niezaliczonych testów.** Nie ukrywam ich — lista:

1. **`decode: nieznana sygnatura…` — oczekiwanie testu jest błędne, nie kod.**
   Test oczekuje `MatchQuality.unknown`, kod zwraca `.vendor_only`. Zachowanie kodu
   jest obronialne: znamy producenta, nie znamy generacji. Do poprawy test.
2. **Testy `platform.native` na prawdziwym sprzęcie.** Kilka asercji zależy od
   konkretnej maszyny. Wymagają poprawki na warunki specyficzne dla platformy.
3. **Pozostałe niepowodzenia nie zostały przeanalizowane pojedynczo** — wymagają
   jednej rundy pracy.

**Obserwacja z uruchomienia natywnego — brand string jest pusty.**
Na maszynie testowej (AMD Zen 3) `display=hwdb`, czyli `brand_valid == false`,
mimo że sygnatura i cache odczytały się poprawnie. Na pliku replay brand string
działa. **Nie ustaliłem przyczyny** i nie zaliczam tego jako naprawionego.
Kandydaci: kolejność bajtów w liściach extended na tym CPU, albo odrzucenie
brand stringu przez walidację „więcej niż 1/4 znaków spoza ASCII".

**Czego nie robiłem:** nie analizowałem dynamicznie CPU-Z/GPU-Z, nie testowałem
na Linuxie/macOS, nie weryfikowałem wydajności, nie mierzyłem startu.

---

## 6. Świadomie odłożone na Etap 2

- Backendy platformowe poza Windows x86-64. `Backend` ma już `Capability`,
  `Requirements` i `min_access`, ale realne implementacje Linux/macOS/USOS
  nie powstały.
- MSR i sterownik Windows (allowlist z `docs/02` §9 zaprojektowana, nie zaimplementowana).
- Cache AMD z liści `0x80000005`/`0x80000006` (K8 — dziś brak danych o cache).
- Format binarny `.fcap` z sekcjami SMBIOS/PCI/USB. Teraz istnieje `.cpuimg`
  (tekstowy) — świadomie czytelny i diffowalny.
- Skalowanie wyszukiwania w bazie. Dziś liniowe; przy >10 tys. wpisów potrzebny
  indeks przedziałowy. **Udokumentowane, nie zaimplementowane.**
- JSON Schema dla TOML-ów, `db/source/SOURCES.toml`, testy regresyjne bazy
  jako osobny krok `zig build test-hwdb`.
- MSR, sensory, GPU, GUI, benchmarki, stress testy — poza zakresem v1 zgodnie z planem.

---

## 7. Rzeczy, które zrobiłem źle i naprawiłem (warto odnotować)

Wszystkie wykryte przez kompilator lub testy, nie przez przegląd kodu:

| Błąd | Skutek, gdyby umknął |
|---|---|
| `defer allocator.free(text)` w pętli po plikach | **Użycie po zwolnieniu** — walidacja czytała zwolniony bufor, baza miała śmieci |
| Brak `args.skip()` po `ArgIterator.initWithAllocator` | Kompilator parsował **własny `.exe`** jako TOML |
| Brak `flush()` przed `file.close()` w generatorze bazy | Wygenerowany plik **ucięty**, brak `};` — cicha utrata danych |
| `defer pool.deinit()` w `buildImage` po dupe | Zwracanie zawartości już zwolnionego bufora |
| Serializacja całego bufora `resolved[8]` w teście | `invalid enum value` na nieinicjalizowanej pamięci |
| `isdigit()` na VID/DID (importer PCI) | Ciche pominięcie 1660 vendorów, w tym całej NVIDIA |
| Leaf 0x16 czytany jako liczba binarna | 3,8 GHz raportowane jako 14 GHz |
| `SSE3`/`SSSE3` wstawione w EDX zamiast ECX w fixture | Fałszywe flagi w teście regresyjnym |
| `c.shared` zamiast liczby wątków jako szerokość SMT | Fałszywa liczba rdzeni |

Wzorzec jest jeden: **ciche pominięcie danych wygląda jak „nie ma takiego
sprzętu"**. Dlatego walidacja źródła bazy i testy złotych plików nie są w tym
projekcie opcjonalne.
