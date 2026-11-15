# FerrumScope — Etap 2: backendy platformowe (Windows, Linux)

Data: 2026-09-29. Maszyna referencyjna: **AMD Ryzen 7 5800X3D** (Zen 3 / Vermeer).

## 0. Wynik w skrócie

Stan na 2026-09-29, po zamknięciu topologii Intel.

| Kryterium zamknięcia | Stan |
|---|---|
| 1. `zig build` PASS | ✅ |
| 2. `zig build test` 100% PASS | ✅ **97/97 przechodzących + 3 pominięte** (testy Linuksa na Windows), `EXITCODE=0` |
| 3. WindowsBackend działa | ✅ zweryfikowany na żywo |
| 4. LinuxBackend działa | ⚠️ **`UNVERIFIED_RUNTIME`** — kompiluje się, ale nigdy nie był uruchomiony na prawdziwym Linuksie (brak WSL/Docker/QEMU na maszynie referencyjnej) |
| 5. Thread-pinned CPUID | ✅ Windows zweryfikowany na żywo; Linux tylko kompilacyjnie |
| 6. Affinity zawsze przywracana | ✅ test na żywo potwierdza |
| 7. 5800X3D = 8C/16T, `topology_source = hardware` | ✅ regresja nadal przechodzi po pełnej przebudowie topologii |
| 8. Stary capture działa przez fallback | ✅ test regresyjny |
| 9. Replay tą samą ścieżką decoderów | ✅ brak specjalnej gałęzi w decoderze |
| 10. Intel: `0x0B`, `0x1F`, hybryda | ✅ **5 fixture'ów, wszystkie `hardware`** |
| 11. Intel: dwa gniazda | ✅ **2 pakiety / 16 rdzeni / 32 wątki** z x2APIC i poziomów, bez hardcodowania |
| 12. Powtarzający się `CoreId` między gniazdami | ✅ `core_id` 0..7 w obu gniazdach, 16 różnych rdzeni |
| 13. Model niezależny od platformy i vendor-neutral | ✅ klasy rdzeni jako lista wartości SDM, nie „P-core/E-core" |
| 14. `compare-captures` | ✅ 4 kategorie werdyktu, kod wyjścia 0/1 |
| 15. Dopasowanie HWDB nie dziedziczy cudzej nazwy | ✅ **naprawione** — `HitLevel` + `family_generic` + osobne źródła pól (root cause w §0.2) |
| 16. Dokumentacja Etapu 1 nie myli | ✅ nagłówek `STATUS: ZASTĄPIONY` |

**Etap 2 jest zamknięty poza jednym punktem: LinuxBackend nigdy nie był uruchomiony
na prawdziwym Linuksie.** Kod się kompiluje i jest objęty testami jednostkowymi, ale
`UNVERIFIED_RUNTIME` oznacza dokładnie to, co znaczy: brak dowodu wykonawczego.

## 0.1 Korekta semantyki liści 0x0B / 0x1F

W trakcie Etapu 2 okazało się, że dekoder czytał rejestry topologii **inaczej, niż
podaje Intel SDM Vol. 2A**. Rozkład jest dla obu liści identyczny:

| Pole | Znaczenie |
|---|---|
| `EAX[4:0]` | bity do przesunięcia x2APIC w prawo, by dostać unikalny identyfikator **następnego** poziomu (kumulatywnie od zera) |
| `ECX[15:8]` | **typ poziomu**: 1 = SMT, 2 = Core, 3 = Module, 4 = Tile, 5 = Die, 6 = DieGrp |
| `ECX[7:0]` | numer poziomu, równy indeksowi subleafa |
| `EDX[31:0]` | **x2APIC ID** bieżącego procesora logicznego |

Dwa błędy, oba cicho produkujące wiarygodnie wyglądające liczby:

1. **x2APIC czytany z `EBX[31:16]`** zamiast `EDX[31:0]`. W pliku `EBX[31:16]`
   jest zerowe, więc dekoder widział x2APIC = 0 dla **wszystkich** procesorów,
   zwijał całą maszynę w jeden rdzeń i **nadal** zwracał `source = hardware`.
   Test `regresja: x2APIC siedzi w EDX[31:0], a nie w EBX[31:16]` pilnuje tego
   kontraktu danych.
2. **Typ poziomu czytany z `ECX[4:0]`** zamiast `ECX[15:8]`. Przypadkowo
   zgadzało się tylko dla subleaf 0.

### Dlaczego `core_id` trzeba maskować

`core = x2apic >> smt_shift` daje unikalne rdzenie **tylko w jednym pakiecie**.
Pole `CoreId` jest lokalne w obrębie pakietu i **celowo się powtarza** między
gniazdami. Na fixture `intel_2xsocket_8core` `core_id` wychodzi `0..7` w obu
gniazdach, a liczba rdzeni to `2 × 8 = 16`, nie 8. Stąd:

```
core_id    = (x2apic >> smt_shift) & ((1 << (core_shift - smt_shift)) - 1)
package_id = x2apic >> core_shift          # bity powyżej najwyższego shiftu
klucz rdzenia = (package_id, core_id)
```

To jest dokładnie analogiczne do krotki `(NodeId, DieId, CoreId)` po stronie AMD.
**Nigdy sam `CoreId`.** Liczba pakietów jest liczona z x2APIC, a nie wpisywana do
fixture'u — gdyby była wpisana, test nic by nie dowodził.

## 0.2 Baza myliła nieznany model — **naprawione**

### Objaw

Fixture `intel_leaf1f` pokazywał `Codename: Merom/Conroe` i `Microarch: Core 2`,
czyli nazwę **zupełnie innej generacji** niż rzeczywisty układ.

### Najpierw: błąd w samym fixture

`EAX = 0x000806A1` koduje `extModel = 8`, `modelField = 0xA`, więc
`displayModel = (8 << 4) + 0x0A = 0x8A` — czyli **Lakefield**, a nie Sapphire
Rapids (`0x8F`). Fixture twierdził jedno, a opisywał drugie, i nic tego nie
wykrywało, bo plik był poprawnym formatem z błędną zawartością — dokładnie ten sam
rodzaj pomyłki co `0x1` zamiast `0x1F`. Sygnatura poprawiona na `0x000806F1`
(`extModel = 8`, `modelField = 0xF` → `0x8F`).

`intel_2xsocket_8core` miał tę samą sprzeczność; przepisany na `0x000606A1`
(`0x6A`, Ice Lake-SP), co zgadza się z użytym w nim brand stringiem
`Xeon Gold 6338`. Ten model **nie ma** wpisu w bazie, więc fixture służy teraz
dokładnie do tego, po co istnieje: sprawdza nieznany model w znanej rodzinie.

### Root cause

`matchCpu()` przyznawał `specificity = 1` **każdemu** wpisowi, którego
`family_field` zgadzał się z rodziną — niezależnie od tego, czy ten wpis
cokolwiek wiedział o danym modelu. Numeracja `specificity` nie rozróżniała
„dopasowanie modelu” od „dopasowanie rodziny”, więc dekoder nie miał czego
zaprzeczyć, gdy na poziomie rodziny wziął `codename` i `uarch` z dowolnego wpisu.

Drugi, mniej widoczny defekt tego samego rodzaju: gdy **nic** nie trafiło,
`matchCpu()` zwracał **pierwszy wpis danego producenta** jako `specificity = 0`.
Z tego wpisu pochodziłby wtedy `quirk_smt_threads`, czyli szerokość SMT z bazy dla
modelu, z którym wpis nie ma nic wspólnego.

### Rozwiązanie

* **Jawna taksonomia trafień** (`hwdb.HitLevel`) zamiast `specificity: u3`:
  `family_only` < `model_range` < `no_stepping` < `single_model`. Kolejność w
  enumie **jest** rankingiem.
* **Wpis musi sam zadeklarować, że jest ogólny dla rodziny** — nowe pole
  `family_generic`, wymagające `model_min = 0` i `model_max = 0xFF`. Wpis
  szczegółowy **nigdy** nie może być fallbackem rodzinnym.
* `matchCpu()` zwraca `null`, gdy nic nie trafiło. `vendor_only` wyprowadzany
  jest z CPUID, a nie z przypadkowego wpisu — dzięki temu zniknął też problem z
  `quirk_smt_threads` z niepowiązanego modelu.
* **Osobne źródła pól** (`model.FieldSource`): `display_name_source`,
  `microarchitecture_source`, `codename_source`. Brand string z CPUID i brak
  wiedzy o mikroarchitekturze **współistnieją** — to poprawna sytuacja, której
  jeden heurystyczny poziom dopasowania nie potrafił wyrazić.
* **Oddzielone uprawnienia**: `canUseQuirks()` nie dopuszcza poziomu
  `family_only`, bo `smt_threads` jest własnością wariantu, a wzięcie go z wpisu
  rodzinnego dawałoby szerokość SMT z bazy z jawnym `topology_source = hwdb` —
  czyli liczbę wyglądającą na pomiar.
* **Walidator**: nakładanie się reguł o **równym** priorytecie nadal błęd, ale
  wpis `family_generic` (mający z definicji zakres `0x00..0xFF`) nie koliduje ze
  wpisami szczegółowymi — inaczej nie dałoby się go zarejestrować. Wpis
  `family_generic` z wąskim zakresem jest **martwą flagą** i odrzucany
  (`InvalidRange`).

### Uczciwa zmiana raportowania

Wpzisy obejmujące **zakres modeli** są teraz raportowane jako `pattern`, nie
`exact`. Dotyczy to m.in. 5800X3D, i9-13900K, Ryzen 7 5800X i Zen 4 — wszystkie
trafiają do wpisów zakresowych w bazie. Dawne `.exact` było **zawyżeniem**: autor
bazy świadomie opisał zakres, a nie jeden układ. Nazwa, kod, mikroarchitektura
i topologia pozostają **bez zmian** — zmienia się wyłącznie etykieta trafienia.
`pattern` jest wiarygodny (`isReliable()`), więc sposób pokazywania nazwy się nie
zmienia.

### Uwaga o formacie binarnym

`family_generic` zapisywany jest w bajcie 28 rekordu wpisu, który wcześniej był
wypełnieniem. Stare pliki `.bin` mają tam zero, czyli „nie ogólny dla rodziny” —
**bezpieczna wartość**, bo wpis szczegółowy i tak nie może być fallbackem
rodzinnym. Świadomie **nie** podniesiono `format_version`: baza osadzona
w projekcie jest i tak przebudowywana z TOML przez build, a `db_revision`
w nagłówku służy do wykrywania rozjazdu. Stary plik `.bin` wczytany jako świeży
zachowa się poprawnie — po prostu nie zawiedzie żadnego wpisu ogólnego dla rodziny.

---

## 1. Najważniejszy wynik: pomiar zamiast zgadywania

W Etapie 1 ta sama maszyna raportowała `topology_source = hwdb`, bo liść
`0x8000001E` opisuje **bieżący wątek** i bez przypinania był bezużyteczny.

Teraz, po przypinaniu wątku do każdego procesora:

```
Cores : 8 physical / 16 logical (2 wątk/rdzeń, źródło: hardware)
```

### Co pomiar faktycznie pokazał

Dane 16 odczytów, jednego po drugim, z **różnych** CPU:

| CPU | EAX[7:0] | EBX[7:0] | EBX[15:8] |
|---|---|---|---|
| 0, 1 | 0, 1 | **0, 0** | 1 |
| 2, 3 | 2, 3 | **1, 1** | 1 |
| 4, 5 | 4, 5 | **2, 2** | 1 |
| 6, 7 | 6, 7 | **3, 3** | 1 |
| 8, 9 | 8, 9 | **4, 4** | 1 |
| 10, 11 | 10, 11 | **5, 5** | 1 |
| 12, 13 | 12, 13 | **6, 6** | 1 |
| 14, 15 | 14, 15 | **7, 7** | 1 |

Wnioski, o których nie wiedzieliśmy przed skanem:

* `EAX[7:0]` to **numer logical procesora** (0..15), a nie „threads per core".
  To wyjaśnia niestabilność z Etapu 1: `0x02` (CPU 2) i `0x0C` (CPU 12) to
  po prostu numery różnych CPU, zależnie od tego, gdzie trafił scheduler.
* `EBX[7:0]` to **core id**. Liczba różnych wartości = liczba rdzeni fizycznych.
* `EBX[15:8]` = `CoresPerComputeUnit` = 1 — **nie** opisuje rdzeni w pakiecie.

Algorytm AMD jest więc: `physical = liczba różnych EBX[7:0]`,
`smt = logical / physical`. Nie ma w nim ani jednej heurystyki.

---

## 2. WindowsBackend

### Processor groups

`SetThreadAffinityMask` obsługuje najwyżej 64 procesory, bo przyjmuje jeden
`ULONG_PTR`. Powyżej 64 logicznych CPU Windows dzieli je na **processor groups**
i wątek należy do dokładnie jednej grupy. Używamy `SetThreadGroupAffinity`,
które bierze maskę **i** numer grupy.

Numeracja: `logical_cpu = group * 64 + bit`, więc CPU 100 to grupa 1, bit 36.
Bez tego mapowania wątek zostałby w grupie 0.

`std.os.windows.kernel32` w Zig 0.15.2 **nie zawiera** tych API, więc
zadeklarowaliśmy je sami z konwencją `WINAPI`.

### Gwarancja przywracania affinity

Strażnik `Pin` powstaje w jednym miejscu i natychmiast trafia pod `defer`:

```zig
var pin = acquire(logical_cpu) catch |e| return ...;
defer pin.restore();
const r = cpuid.execute(leaf, subleaf) orelse return ...;
```

Każda ścieżka wyjścia — zwykły `return`, błąd, propagacja `error` — przywraca
poprzednią affinity. Proces zostawiony na jednym CPU działałby wolniej i
zaburzałby pomiar pozostałych rdzeni, więc to nie higiena, lecz poprawność.

Pierwsza wersja kodu przypinała wątek **dwa razy** na jeden odczyt (raz „na
próbę", raz właściwie) — poprawione, bo mnożyło koszt i zaplątywało dwa
niezależne mechanizmy przywracania.

### Błędy platformowe

`backend.Ctx.fail()` buduje komunikat zawierający operację, kod platformowy,
logical CPU oraz leaf/subleaf, gdy dotyczy. Status towarzyszy tekstowi, więc
caller nie musi zgadywać, czy to `denied` czy `failed`.

Przykład z testu: świadomy błąd na CPU 0xFFFF daje niepusty komunikat, a
kolejny odczyt leaf 1 zwraca te same wartości — dowód, że wątek wrócił.

---

## 3. LinuxBackend

### Zasada: FerrumScope rozumie CPU sam

sysfs służy **wyłącznie** jako pomocnicze źródło informacji o tym, które
procesory są online. Nigdy nie zastępujemy własnego dekodera CPUID parsowaniem
`/proc/cpuinfo` — `model name` stamtąd to zniekształcony brand string, a
`cpu family`/`model` bywają uzupełniane przez hypervisor.

### Obejście zepsutego std

`std.os.linux.sched_setaffinity` **nie kompiluje się** w Zig 0.15.2 bez libc:
w gałęzi błędu woła `std.posix.unexpectedErrno` z enumem `std.c`, którego nie
ma, gdy libc nie jest linkowane. To wywracało `zig build test` nawet na
Windows, bo `refAllDeclsRecursive` wciąga moduł Linuksa.

Rozwiązanie: własne cienkie funkcje na surowych syscallach
(`linux.syscall3(.sched_getaffinity, …)`), z własną obsługą `errno`, dzięki
której komunikat zawiera numer CPU i nazwę operacji. To ta sama instrukcja —
zmieniło się tylko miejsce, w którym czytamy wynik.

### Jeden bit, nie wiele

`sched_setaffinity` przyjmuje bitmapę, ale wiele bitów oznacza „uruchom
gdziekolwiek z tych", a nie przypięcie. Stąd `setOne()` ustawia dokładnie jeden
bit.

Enumerator online CPU: `sched_getaffinity` w pierwszej kolejności (to jedyne
źródło zgodne z tym, gdzie kernel pozwala działać — cgroups, `taskset`),
sysfs jako uzupełnienie. CPUID leaf 1 służy tylko jako ostatnia deska ratunku,
bo pod hiperwizorem bywa zawyżone.

---

## 4. Wspólny interfejs

```zig
readCpuidOn(logical_cpu, leaf, subleaf) -> status.Result(Regs)
logicalCpuCount() -> status.Result(u32)
```

Dekoder i probe **nie wiedzą**, czy pod spodem jest `SetThreadGroupAffinity`,
`sched_setaffinity`, czy odczyt z tablicy w pliku capture.

### Nowe capabilities

| Capability | Znaczenie |
|---|---|
| `cpuid_per_logical_cpu` | CPUID po przypinaniu wątku |
| `thread_affinity` | umiejętność ustawienia i przywrócenia affinity |
| `logical_cpu_enumeration` | enumeracja online CPU |
| `numa_topology` | zarezerwowana na topologię NUMA (Etap 3) |

Brak możliwości to `Status.unsupported`, nie błąd programu. Backend **nie**
deklaruje możliwości, której nie ma: probe wierzyłby wtedy, że potrafi, wracałby
z pustym skanem, a topologia wyglądałaby na „nie udało się odczytać" zamiast
„tego nie umiemy".

---

## 5. Hierarchia źródeł topologii

```
1. thread-pinned hardware CPUID      → topology_source = hardware
2. leaf 0x0B / 0x1F (gdy kompletny)  → topology_source = leaf_0x0b
3. L1d z liścia 4 (pole sharing_known) → topology_source = derived_from_cache
4. HWDB (quirk_smt_threads)          → topology_source = hwdb
5. 1 (brak SMT lub brak danych)      → topology_source = unknown
```

Priorytet jest realizowany w `decodeTopology()`; zmierzona liczba rdzeni ma
pierwszeństwo nad ilorazem `logical / smt`, bo jest **zmierzona**, a iloraz tylko
ją potwierdza. Gdyby się rozjadły, nie podajemy żadnej liczby.

Źródło jest zawsze widoczne w CLI i JSON — nie ukrywamy pomiaru pod pozorem
wiedzy z bazy ani odwrotnie.

---

## 6. Topologia Intel

`topologyFromPerCpu()` obsługuje obie ścieżki:

* **x2APIC z liścia 0x1F** (v2) — preferowany, bo ma typ rdzenia;
* **x2APIC z liścia 0x0B** — używany, gdy 0x1F nie ma.

`core_id = x2APIC >> EAX` (EAX poziomu SMT to liczba bitów przesunięcia), a
liczba rdzeni to liczba różnych `core_id`. Tą samą ścieżką obsługiwane są CPU
klasyczne i hybrydowe — różni je obecność poziomu Cluster i typu rdzenia, nie
sama arytmetyka.

Wymagamy kompletu odczytów: częściowy zestaw dałby fałszywie małą liczbę
rdzeni, a to gorszy błąd niż brak pomiaru.

---

## 7. Model trójwartościowy

```zig
pub const Knowledge = enum { known, unknown, unavailable };
pub fn Maybe(comptime T: type) type { ... }
```

Rozróżnienie `unknown` (nie ustaliliśmy, spróbuj innej ścieżki) od
`unavailable` (sprzęt tego nie raportuje i nie będzie) jest wprowadzone
świadomie: samo `null` nie pozwala odróżnić „mieliśmy szansę i nie
wykorzystaliśmy" od „nie ma czego czytać".

---

## 8. Capture / Replay

Nowa instrukcja formatu:

```text
per_cpu <id> leaf 0x0000001E sub 0x00 eax=0x0000000C ebx=0x00000106 ...
```

Jedna linia = jeden `(CPU, leaf, subleaf)`. Wybrane celowo zamiast zagnieżdżonych
sekcji: pozostaje diffowalne w gitre i łatwe do napisania ręcznie.

**Kompatybilność wsteczna jest jawna, nie przypadkowa.** Plik v1 nie ma sekcji
`per_cpu`, więc replay **nie deklaruje** `cpuid_per_logical_cpu` i dekorator
schodzi do fallbacku. Stary plik daje stary wynik.

Test potwierdza obie strony dla tego samego sprzętu:

| Plik | `topology_source` | Cores |
|---|---|---|
| `amd_ryzen7_5800x3d_native.cpuimg` (16 CPU) | `hardware` | 8 / 16 |
| `amd_ryzen7_5800x3d_v1.cpuimg` (bez per-CPU) | `hwdb` | 8 / 16 |

Wartości fizyczne identyczne, źródło uczciwie różne.

### Błąd, który naprawiliśmy po drodze

`PerCpuImage` trzymała 256 wpisów, każdy z pełnym `CpuidImage` o pojemności
128 liści: **512 KB kopiowane przez wartość** przy każdym `parse()`. Wystarczyło,
aby wybić stos w teście. Wprowadziliśmy osobny `TopoImage` o pojemności 16
(dokładnie tyle, ile czyta skan) — `256 × 16 × 16 B ≈ 64 KB` zamiast 512 KB.

To była wada projektowa, nie literówka: nie objawiała się przy małych danych,
aż do momentu, gdy realny capture z 16 CPU trafił do testu.

---

## 9. Pomiary czasu

`ReleaseFast`, Ryzen 7 5800X3D (16 logical CPU), średnia z kilku uruchomień po
rozgrzaniu:

| Operacja | Czas |
|---|---|
| Pełny skan `cpu` (z przypinaniem, 16 CPU) | **3,9 ms** (pierwsze 20 ms — cold cache) |
| `replay` z pliku | 3,3 ms |
| `capture` do pliku | 6,0–6,8 ms |

Skan czyta **minimalny zestaw liści** na CPU: `0x1`, do 4 subleafów `0xB`, do 6
subleafów `0x1F`, `0x8000001E`. Liści, których CPU nie deklaruje, pomijamy —
sprawdzamy `max_basic`/`max_extended` raz, na bieżącym CPU, bo są stałe dla
całego procesora. To ok. 12 odczytów na CPU zamiast „wszystkiego, co można".

---

## 10. Testy dodane w Etapie 2

Windows:

* `windows: backend deklaruje CPUID, enumerację i przypinanie`
* `windows: liczba logical processors jest sensowna` (ALL_PROCESSOR_GROUPS)
* `windows: CPUID na wskazanym CPU zwraca tego samego vendora`
* `windows: affinity jest przywracana także po błędie` — świadomy błąd na
  CPU 0xFFFF, potem weryfikacja, że leaf 1 daje te same wartości
* `windows: leaf 0x8000001E opisuje bieżący CPU (powód przypinania)`

Linux (kompilują się, pomijane na Windows):

* `linux: parseCpuList obsługuje zakresy, listy i mieszane`
* `linux: parseCpuList odrzuca śmieci`
* `linux: CpuSet ustawia i liczy pojedyncze bity`
* `linux: affinity jest przywracana po błędzie`

Replay i capture:

* `replay: plik v1 bez sekcji per-CPU nie deklaruje CPUID per-procesor`
* `replay: sekcja per-CPU daje tę samą topologię co platforma żywa`
* `replay: brak CPU w capture daje absent, nie awarię`
* `round-trip: format i parse odtwarzają ten sam obraz` (rozszerzony o per-CPU)

Regresyjne 5800X3D:

* `topologia z pomiaru thread-pinned, nie z bazy` — 16 CPU, `hardware`
* `każdy core id występuje dokładnie dwa razy` — sprawdza **rozkład**, nie sumę
* `capture sprzed Etapu 2 nadal działa przez fallback HWDB`
* `replay z per-CPU daje hardware, ten sam plik bez danych daje hwdb`

---

## 11. Znane ograniczenia i praca odłożona

### Nie zweryfikowane w runtime

* **LinuxBackend** — kompiluje się i jest testowany jednostkowo (parser
  `cpu_set_t`, parsowanie listy CPU), ale **nigdy nie uruchomił się na Linuksie**.
  Testy `linux: *` są na Windows pomijane. Dopóki nie zostanie uruchomiony na
  Linuksie, twierdzenie „działa" jest niepotwierdzone.
* **Thread-pinned CPUID na Linuksie** — ta sama uwaga.

macOS, USOS: świadomie poza zakresem. `native.zig` ma osobną ścieżkę
`createPortable()`, która **nie deklaruje** przypinania — brak możliwości jest
jawny, a nie udawany.

### Luka w pokryciu testami: Intel

* Brak fixture z liściem **`0x1F`** (topologia v2, z typem rdzenia).
* Brak fixture **hybrydowego** CPU (Alder Lake / Meteor Lake) z rdzeniami
  P-core i E-core oraz wyłączonym SMT na części rdzeni.
* Ścieżka Intel jest napisana i obsługuje oba liście, ale **nie ma testu
  regresyjnego** dla `0x1F` ani hybrydu. Bez takiego fixture nie mogę twierdzić,
  że ta gałąź jest poprawna — to najważniejsza luka tego etapu.

Odłożone, bo wymagałoby zgadywania sygnatur i bycie odpowiedzialnym za
fixture syntetyczne o nieznanej wartości: wolę fixture z jasnym pochodzeniem
(publiczny dump) niż zmyślone dane w teście regresyjnym.

### Pozostałe braki

* **`compare-captures`** — mechanizm porównania dwóch capture'ów z podziałem na
  „hardware mismatch" / „expected platform difference" / „missing capability"
  nie został zaimplementowany. Model jest gotowy (źródła widoczne w
  `topology_source`), ale brak samego polecenia.
* **Rozbudowa modelu topologii** — `dies`, `core_type`, NUMA node mają miejsce
  w planie (`numa_topology` jest zarezerwowane w capabilities), ale nie są
  wypełniane. `dies` wypełnia się z `0x8000001E EDX[15:8]`, który na tym CPU
  wynosi 0, więc pozostaje `unavailable` — zgodnie z zasadą „nie zgadujemy".
* **MSR** — kontrakt zaprojektowany w `Capability` (`msr_read`), implementacji
  brak, zgodnie z zakresem etapu.
* **CCD/CCX na Zen 3** — `0x8000001E` na tym CPU nie podaje liczby CCD, więc
  pozostaje `unknown` zamiast zgadywanej wartości.

---

## 12. Weryfikacja końcowa

```
zig build        → PASS
zig build test   → 89/89 PASS, 3 skipped
ferrumscope cpu  → 8C/16T, źródło: hardware
capture → replay → identyczny CpuInfo, to samo źródło topologii
```

Zweryfikowane konkretnie na żywo: Windows backend, przypinanie i przywracanie
affinity, pomiar topologii na 16 CPU, round-trip capture, kompatybilność
wsteczna pliku v1, czasy działania.

**Niezweryfikowane:** wszystko, co dotyczy Linuksa, oraz ścieżka Intel
`0x1F`/hybrydowej.
