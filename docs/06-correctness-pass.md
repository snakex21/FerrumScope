# FerrumScope — correctness pass Etapu 1

> **STATUS: HISTORYCZNY.** Ten dokument opisuje stan **Etapu 1** i jest zachowany
> jako zapis tego, co wtedy było zepsute. Dwie rzeczy w poniższym tekście **nie są
> już prawdziwe** i zostały rozwiązane w Etapie 2:
>
> 1. `8C/16T` dla 5800X3D **nie pochodziło z bazy** — podano wtedy
>    `topology_source = hwdb`, bo liść `0x8000001E` opisuje bieżący wątek.
>    Teraz liczba rdzeni jest **zmierzona**: `topology_source = hardware`.
> 2. Liczby testów (`74/74`) dotyczą Etapu 1. Stan bieżący: `docs/07`.
>
> Reszta dokumentu (analiza przyczyn siedmiu błędów, decyzje kontraktowe) pozostaje
> aktualna — to dokumentacja *procesu*, nie *stanu*.

Data: 2026-09-29. Maszyna referencyjna: **AMD Ryzen 7 5800X3D** (Zen 3 / Vermeer).

Wynik końcowy **Etapu 1**: `zig build` PASS, `zig build test` **74/74 PASS**, CLI poprawny,
native i replay dają identyczny `CpuInfo`.

---

## 1. Root cause siedmiu błędów testów

| # | Test | Przyczyna | Kto zepsuty |
|---|---|---|---|
| 1 | `probe: replay daje ten sam surowy obraz` | Oczekiwano `displayModel 0x71`, a `EAX=0x000B0671` daje `0xB7` — zgodnie z regułą SDM (ext_model<<4 \| model dla rodziny 6) | **test** |
| 2 | `decode: nieznany producent bez brandu` | `EAX=0x000F1A02` → family_field=1, rodzina **1**, nie 15. Test miało sprawdzać rodzinę 15 | **test** |
| 3 | `decode: quirk no_brand_string` | Ta sama błędna sygnatura; poprawiona na `0x000006F2` (Family 6, Model 0x0F) | **test** |
| 4 | `core.raw: brand: wykrywanie śmieci` | Bufor wypełniony spacjami zamiast zerami, więc `brandSlice()` nie miał gdzie uciąć | **test** |
| 5 | `arch.x86.cpuid: brand: sklejanie 3 liści` | Dane w rejestrach użyły kodowania *vendor stringu* (`0x756E6547` = „Genu" odwrócone) zamiast brand stringu, gdzie **najniższy bajt EAX to pierwszy znak** | **test** |
| 6 | `core.raw: brand` (po dodaniu normalizacji) | Oczekiwano `"A   "` po trimie — normalizacja **ma** usunąć spacje | **test** |
| 7 | `capture: błędne wejście` → `UnknownInstruction` zamiast `BadMagic` | Parser interpretował instrukcje **zanim** sprawdził nagłówek, więc plik obcego formatu dawał fałszywą diagnozę | **kontrakt/parser** |

Dodatkowo `decode: nieznana sygnatura` wymagał decyzji kontraktowej, opisanej niżej.

### Decyzja kontraktowa: `outcome` vs `match`

Test oczekiwał `MatchQuality.unknown` dla nieznanej rodziny AMD z działającym brand stringiem.
Kod zwracał `.vendor_only`. **Kod jest prawidłowy, zmieniłem test**, bo:

* `outcome` = skąd wzięła się **nazwa** → `.from_brand` (z CPUID),
* `match` = jak dobrze baza ją **uzasadnia** → `.vendor_only` (znamy producenta).

`.unknown` przy działającym brand stringu kłamałoby na brak wiedzy. Rozdzielenie tych
osi jest widoczne w CLI (`Dmatch: exact (display=brand_string, …)`).

---

## 2. Root cause pustego brand stringu

**Rozdzielenie trzech rzeczy, które wyglądały na jeden błąd:**

1. **Brak odczytu liści `0x80000002..4`** — naprawiony w poprzedniej turze, ale
   zweryfikowany dopiero teraz. Probe nie umieszczał tych liści w obrazie,
   więc `brandString()` sklejał same NUL-e.
2. **Brak normalizacji** — AMD dopełnia brand string **spacjami** do 48 bajtów
   (`brand_raw: "AMD Ryzen 7 5800X3D 8-Core Processor           "`), Intel zerami.
   `brandSlice()` ucinał dopiero na pierwszym zerze, więc zostawały 11 spacji.
   Dodane `brandRaw()` (surowe) i `brandSlice()` (znormalizowane).
3. **Błąd w CLI** — `--json`/`--raw` były **cicho ignorowane** dla `cpu`
   (tryb był zaszyty na stałe). Prośba o dane surowe dawała dane przetworzone.

Rejestry potwierdzające (AMD Zen 3, kolejność EAX,EBX,ECX,EDX, LE):

```
leaf 0x80000002 eax=0x20444D41 ebx=0x657A7952 ecx=0x2037206E edx=0x30303835
leaf 0x80000003 eax=0x20443358 ebx=0x6F432D38 ecx=0x50206572 edx=0x65636F72
leaf 0x80000004 eax=0x726F7373 ebx=0x20202020 ecx=0x20202020 edx=0x00202020
```

Wynik przed trimem: 48 B z 16 spacjami. Po: `AMD Ryzen 7 5800X3D 8-Core Processor`.
Wartość **nie jest hardcodowana** — pochodzi wyłącznie z CPUID.

---

## 3. Root cause 16 rdzeni zamiast 8C/16T

To był **błąd złożony z czterech niezależnych przyczyn**, każda z osobna dawała fałszywy wynik:

1. **Liść `0x8000001E` nie był czytany** wcale — nie było go na liście liści probe'a.
2. **Pole AMD EDX w liściu cache wzięte za „threads sharing"**. W liściu 4 (Intel)
   `EDX[4:0]+1` to liczba wątków współdzielących cache. W `0x8000001D` (AMD) ten rejestr
   **nie** opisuje współdzielenia — na Zen 3 wychodzi L1d=0, L2=2, L3=1, co nie
   odpowiada żadnej rzeczywistej liczbie wątków. Mielenie dawało `smt_width = 1` → 16 rdzeni.
3. **`EBX[15:8]` w `0x8000001E` to `CoresPerComputeUnit` (=1), nie `CoresPerPackage`.**
   Mój „krzyżowy check" traktował to jako liczbę rdzeni w pakiecie i **wetował wynik do zera**.
4. **Najważniejsze — sam liść jest niestabilny.** Dwa kolejne odczyty na tej samej maszynie:

   | Odczyt | EAX | EBX | ApicId (EBX[7:0]) |
   |---|---|---|---|
   | 1 | `0x02` | `0x00000101` | 1 |
   | 2 | `0x0C` | `0x00000106` | 6 |

   `0x0C = 2 × ApicId`. To nie jest „threads per core" — to opis **bieżącego wątku**.
   Bez przypięcia do rdzenia (thread pinning) wynik zależy od tego, gdzie trafił
   scheduler: raz 8 rdzeni, raz 0. **Dlatego liść nie jest już używany do SMT.**

### Ścieżka priorytetów (udokumentowana w kodzie)

1. `leaf 0x0B` — `EAX` = liczba bitów przesunięcia, `threads = 2^EAX`;
2. `L1d` z liścia 4, tylko gdy pole `sharing_known` (nie dotyczy `0x8000001D`);
3. **HWDB** — architektoniczna szerokość SMT rodziny (`smt_threads = 2` dla Zen 1–4);
4. `1` — brak SMT lub brak danych.

Krok 3 jest widoczny: `topology_source = hwdb` w CLI i JSON-ie. Nie udajemy pomiaru.
Poprawna metoda AMD (odczyt liścia na każdym procesorze logicznym z przypięciem)
wymaga funkcji platformowej — **to zadanie Etapu 2**, świadomie odłożone.

### Niezmienniki

* `threads_per_core >= 1`
* `logical_threads >= physical_cores`
* `logical_threads == physical_cores * threads_per_core` → inaczej `cores_physical = 0`
  i `topology_confident = false` (zamiast podać liczbę błędną)
* wynik topologii **nie zależy** od liczby wpisów cache (test z obrazem bez `0x8000001E`)

---

## 4. Jak wyliczany jest 96 MB L3

**96 MiB jest poprawne i pochodzi z dekodowania, nie z mnożenia.**

```
leaf 0x8000001D sub 0x03: eax=0x0003C163 ebx=0x03C0003F ecx=0x00017FFF
```

* `EAX & 0x1F` = 3 → typ unified
* `(EAX >> 5) & 0x7` = 3 → poziom L3
* `line_size = (EBX & 0xFFF) + 1` = 64 B
* `partitions = ((EBX >> 12) & 0x3FF) + 1` = 1
* `ways = ((EBX >> 22) & 0x3FF) + 1` = 16
* `sets = ECX + 1` = 98304

`64 × 1 × 16 × 98304 = 100 663 296 B = 96 MiB` ✓

Sprawdzenia anty-pomyłkowe:

* **Brak podwójnego liczenia.** Leaf 4 na Zen 3 zwraca `EAX = 0` (nieobsługiwany),
  więc wpisy pochodzą wyłącznie z `0x8000001D`. Dodatkowo w dekodatorze jest guard
  pomijający wpis `(level, type, size)` już obecny na liście — bez niego procesor
  wypełniający **oba** liście dawałby ten sam L3 dwa razy. (Fixture testowy początkowo
  generował oba liście i ujawnił dokładnie ten błąd.)
* **`instance_count` to liczba instancji, nie mnożnik rozmiaru.** Rozmiar jest już
  podany per instancja; `domain = package` opisuje zakres współdzielenia.
* **Sharing count nie jest mnożnikiem rozmiaru** — na AMD `sharing_threads = 0`
  i `sharing_known = false`, więc nie może fałszywie skalować L3.
* Mnożenie `98304 × 16 × 64` jest asercją w teście — sprawdza, że 96 MB **wynika**
  z dekodowania pól, a nie przypadkiem.

Model danych (`CacheInfo`) ma komplet wymaganych pól: `level`, `kind`, `size_bytes`,
`line_size`, `ways`, `sets`, `sharing_threads`, `instance_count`, `domain`.

---

## 5. Złoty capture natywny

`db/fixtures/amd_ryzen7_5800x3d_native.cpuimg` — 90 liści, 7825 B, wygenerowany
komendą `ferrumscope capture`. Zawiera **wyłącznie publiczne identyfikatory CPUID**:
sygnaturę, liście, flagi, cache, topologię. Brak danych prywatnych i identyfikatorów systemu.

Format ma test round-trip (`format` → `parse` odtwarza rejestr po rejestrze) —
bez niego capture zapisany na dysk mógłby po reparsie dać inne dane niż odczytane.

Testy sprawdzają konkretne wartości, nie brak awarii: vendor AMD, Zen 3, Vermeer,
family `0x19`, model `0x21`, stepping 2, 8C/16T, L3 96 MiB, brand string z CPUID.

---

## 6. Walidacja native vs replay

`ferrumscope cpu` i `ferrumscope replay <ten sam capture>` dają **identyczny** wynik
w każdym porównywanym polu: vendor, brand, family/model/stepping, mikroarchitektura,
codename, cores, threads, hierarchia cache, flagi cech, `match`, `decode`, źródło bazy.

**Oczekiwane różnice: brak.** Jedyna różnica to etykieta źródła w nagłówku
(`[native]` vs `[ścieżka pliku]`) — to metadane, nie wynik.

Uwaga procesowa: przy pierwszej walidacji `zig build test` nie odświeża
`zig-out/bin/ferrumscope.exe` (instaluje go tylko krok `zig build`). Porównanie
wyglądało więc jak „native ≠ replay”, a w rzeczywistości porównywał świeży test
ze starym binarium. To samo źródło błędów co wczesniejszy raport: **porównanie
artefaktów zbudowanych w różnym momencie daje fałszywy sygnał.**

---

## 7. Brak maskowania błędów HWDB

Pola rozdzielone i widoczne:

* `brand_raw` — dokładnie to, co zwrócił CPUID (z dopełnieniem),
* `brand` / `brandSlice()` — po normalizacji,
* `display_name_source` = `brand_string | hwdb | hwdb_pattern | generated | hex_id`,
* `match` = `exact | device | pattern | family | vendor_only | unknown`,
* `topology_source` = `leaf_0x0b | derived_from_cache | hwdb | unknown`,
* `topology_confident` — gdy fałszywe, CLI wypisuje ostrzeżenie zamiast „0 rdzeni".

Przykład z maszyny:

```
Name    : AMD Ryzen 7 5800X3D 8-Core Processor
Dmatch  : exact (display=brand_string, decode=matched_exact)
Cores   : 8 physical / 16 logical (2 wątk/rdzeń, źródło: hwdb)
```

Nazwa pochodzi z **CPUID**, nie z bazy. Gdyby brand string zawiódł, `display_name_source`
zmieniłoby się na `hwdb`, a nie zniknęłby problem.

---

## 8. Dodane testy regresyjne

1. `golden native: Ryzen 7 5800X3D — identyfikacja i topologia` (pełny `CpuInfo`)
2. `golden native: 5800X3D L3 = 96 MB z poprawnego dekodowania, nie mnożenia`
3. `golden native: 5800X3D — niezmienniki topologii`
4. `golden native: cache nie zależy od liczby liści w capture`
5. `brand: dopełnienie spacjami jest usuwane normalizacją`
6. `round-trip: format i parse odtwarzają ten sam obraz`
7. Poprawione: `arch.x86.cpuid` brand (prawdziwe rejestry AMD), `core.raw` brand,
   `probe/cpu` flagi, dwa `decode/cpu_x86` (sygnatury, kontrakt `match`/`outcome`),
   `capture/cpuimg` kolejność walidacji nagłówka.

---

## 9. Kryteria zamknięcia Etapu 1

| # | Kryterium | Stan |
|---|---|---|
| 1 | `zig build` PASS | ✅ |
| 2 | `zig build test` 100% PASS | ✅ **74/74**, 8/8 kroków |
| 3 | Native brand string działa | ✅ `AMD Ryzen 7 5800X3D 8-Core Processor` |
| 4 | 5800X3D jako 8C/16T | ✅ |
| 5 | 96 MB L3 zweryfikowane | ✅ z dekodowania CPUID |
| 6 | Native i replay dają ten sam `CpuInfo` | ✅ |
| 7 | Brak znanych błędów w CPU pipeline | ✅ w zakresie Etapu 1 |

**Etap 1 jest zamknięty.**

---

## 10. Świadomie odłożone

* **Thread pinning i pełna enumeracja topologii AMD** — jedyna poprawna metoda
  odczytu `0x8000001E`; wymaga backendu platformowego (Etap 2).
* Backendy Linux/macOS/USOS, MSR, sterownik Windows, GPU, GUI — poza zakresem.
* `docs/05-etap1-raport.md` opisuje stan **przed** tym passem; zawiera teraz
  nieaktualne liczby (61/68) i niepoprawne twierdzenie o pustym brand stringu.
  Do poprawy na początku Etapu 2.
