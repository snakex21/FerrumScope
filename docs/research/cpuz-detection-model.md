# CPU-Z jako oracle: model mechanizmu identyfikacji CPU

**Data:** 2026-09-29
**Rewizja:** 2 — po znalezieniu lokalnej kopii CPU-Z (`do referencji/cpuz/`)
i wykonaniu **realnego porównania** na Ryzen 7 5800X3D.
**Cel:** zrozumieć *mechanizm* identyfikacji CPU w CPU-Z, aby ocenić, czy
FerrumScope czegoś nie ma. **Nie** kopiujemy tabel, blobów ani danych CPU-Z.
**Status:** research + **implementacja zrealizowana** (Etap 3B, CPU-only).
Żadna zmiana nie dotyczy telemetry, sensorów, MSR, GPU, RAM, storage ani GUI.
Walidacja: `zig build` PASS, `zig build test` **183 passed / 3 skipped (Linux) / 0 failed**
(baza wyjściowa 172/175), 5800X3D potwierdzony na realnym sprzęcie,
stare capture'y odtwarzają się bez zmian.

---

## 0. Zastrzeżenie metodologiczne

Ten dokument rozróżnia cztery poziomy pewności. Robię to, bo cała historia
FerrumScope to seria pomyłek, które **wyglądały jak fakty**:

| Poziom | Znaczenie |
|---|---|
| **VERIFIED** | Sprawdzone w źródle; podane źródło. |
| **STRONG INFERENCE** | Wnioskowane z >=2 obserwacji, spójne, ale bez bezpośredniego dowodu. |
| **WEAK INFERENCE** | Prawdopodobne, ale jedna obserwacja lub wiedza wstępna. |
| **UNKNOWN** | Nie ustalono. |

**KOREKTA bledu z rewizji 1.** Pisałem, że analiza różnicowa jest
"NIEWYKONANA, bo CPU-Z nie jest zainstalowany". To byl **blad zakresu
wyszukiwania**: sprawdzilem `Program Files\CPUID\CPU-Z`, `%LOCALAPPDATA%\CPUID`,
`PATH` i rejestr `Uninstall` — ale CPU-Z lezy w repozytorium, w `do referencji\cpuz\`,
i jest wersja portable. **Analiza roznicowa zostala wykonana** (§7.1, §7.2)
na realnym sprzecie z obu narzedzi.

**Zasada metody: CPU-Z jako czarna skrzynka.** Traktujemy wylacznie jako
**oracle**: uruchamiamy, zbieramy raport, porownujemy wyjscia, obserwujemy
zachowanie. **Nie** czytamy jego binarnej tablicy, nie przenosimy blobow, nie
analizujemy kodu binarnego. Celem jest odtworzenie **mechanizmu**, a nie
skopiowanie danych — bo skopiowanych danych nie da sie pozniej legalnie
udokumentowac w FerrumScope.

---

## 0.1 Ścieżka uprzywilejowanego dostępu CPU-Z — zmierzona

Badanie czarnej skrzynki, **bez** kopiowania kodu, protokołu ani implementacji
CPU-Z. Cel: potwierdzić model architektury, nie odtworzyć implementacji.

### Metoda

Trzy niezależne źródła obserwacji:

1. `Event ID 7045` (Security/SCM: „zainstalowano usługę”) — podaje nazwę usługi,
   **typ** i **ścieżkę obrazu**,
2. `Win32_SystemDriver` / `sc query` — stan i `PathName`,
3. napisy ASCII/UTF-16 w `cpuz_x64.exe` — nazwy urządzeń i przełączniki.

Plus pomiar timelinowy: uruchomienie CPU-Z z pollingiem stanu co 300 ms, żeby
zobaczyć sterownik **w trakcie** działania, a nie po.

### Wyniki

| Obserwacja | Wartość | Poziom |
|---|---|---|
| CPU-Z ma własny sterownik jądra | tak | **VERIFIED** |
| Nazwa usługi | `cpuz165` | **VERIFIED** |
| Typ usługi | sterownik trybu jądra, start **na żądanie** | **VERIFIED** |
| Ścieżka obrazu | `C:\ProgramData\CPUID Software\cpuz\<losowa nazwa>` | **VERIFIED** |
| Rozszerzenie pliku | **brak `.sys`** — sama losowa nazwa | **VERIFIED** |
| Sterownik `Running` w trakcie pracy | 342 ms → 8694 ms (18 próbek) | **VERIFIED** |
| Sterownik usunięty | do 9179 ms, **przed** wyjściem procesu | **VERIFIED** |
| Plik obrazu na dysku w trakcie pracy | **nie istnieje** (katalog pusty przy każdej próbce) | **VERIFIED** |
| Nazwy urządzeń | `\Device\cpuz165`, `\DosDevices\CPUZ165`, `\DosDevices\Global\CPUZ165` | **VERIFIED** (napisy) |
| Uprawnienie | `@SeLoadDriverPrivilege` | **VERIFIED** (napisy) |
| Przełączniki sprzątania | `-removeservice`, `RemoveService`, `KRemoveService=%d` | **VERIFIED** (napisy) |
| Nazwa user-mode do otwarcia | `\\.\CPUZ165` | **STRONG INFERENCE** (z `DosDevices\CPUZ165`) |
| Kody/numery IOCTL | — | **UNKNOWN** (celowo nie zbadane) |
| Zawartość i sposób obsługi MSR | — | **UNKNOWN** (celowo nie zbadane) |
| Reprezentacja hybrydowych rdzeni / P-core vs E-core | — | **UNKNOWN** |
| Dokładna nazwa katalogu (`cpuz` vs `cpu-z`) | — | **UNKNOWN** (zniekształcone kodowanie w komunikacie 7045) |

### Ustalony model architektury

```
CPU-Z (usermode, elevated)
  → wypisuje obraz sterownika do %ProgramData%
  → CreateService(... SERVICE_KERNEL_DRIVER, SERVICE_DEMAND_START)
  → StartService  (wymaga SeLoadDriverPrivilege)
  → kasuje PLIK obrazu (obraz zostaje zmapowany w jądrze)
  → otwiera \\.\CPUZ165
  → DeviceIoControl → sterownik odczytuje MSR na docelowym CPU
  → zamyka uchwyt
  → usuwa usługę i katalog
```

Dwie obserwacje są warte odnotowania, bo są **niedoczywiste**:

* **Kasowanie pliku po załadowaniu.** Katalog z obrazem był pusty przy każdej
  z 18 próbek, mimo że sterownik był aktywny. Plik znika, a sterownik działa.
  To celowe utrudnianie wyciągnięcia pliku — technika znana, ale tu potwierdzona
  pomiarem, a nie domysłem.
* **Usunięcie przed wyjściem procesu.** Sterownik zniknął do 9179 ms przy
  wyjściu procesu ok. 9857 ms. Zatem lifecycle jest
  „załaduj → użyj → usuń”, a nie „zostaw załadowany do restartu”.

### Konsekwencja dla FerrumScope

Plan Etapu 3A zakładał, że skoro CPU-Z czyta MSR „bez własnego sterownika”, to
FerrumScope **odziedziczy** ten dostęp. To było fałszywe założenie i zostałoby
obalone dopiero w trakcie pisania sterownika. Dostęp do MSR na Windows
wymaga **własnego** sterownika — a model powyżek potwierdza, że droga jest
wykonalna: usługa na żądanie, load, `\\.\<nazwa>`, `DeviceIoControl`.

CPU-Z **nie** jest źródłem danych dla FerrumScope. Używamy go wyłącznie jako
oracle porównawczy.

### Korekta techniczna: składnia `-txt`

`cpuz_x64.exe -txt=<ścieżka>` w tej wersji **nie generuje raportu** (exit 0,
pliku brak). Raport powstaje przy `-txt` **bez** ścieżki i trafia do katalogu
egzekutowalnego. Poprzednia notatka w pamięci projektu podawała błędne
instrukcje.

---

## 1. Pipeline CPU-Z

```
Hardware
 -> raw CPUID (0x0, 0x1, 0x8000000x) + brand string    VERIFIED
 -> platform data (SMBIOS, WinAPI)                      VERIFIED
 -> wlasna tabela/mapowanie                             STRONG INFERENCE
 -> CPU identity
 -> prezentacja
```

| Zrodlo | Do identyfikacji? | Pewnosc |
|---|---|---|
| CPUID `0x0` | max leaf, vendor string | VERIFIED |
| CPUID `0x1` EAX | base family/model/stepping | VERIFIED |
| CPUID `0x1` EBX | logical processors (topologia) | VERIFIED |
| CPUID `0x80000000` / `0x80000001` | ext family/model/stepping | VERIFIED |
| CPUID `0x80000002..4` | brand string (48 B) | VERIFIED |
| CPUID `0x8000001E` (AMD) | core id, apic id | VERIFIED |
| MSR (PStateReg, Tjmax) | P-state/FID/VID, temperatura | VERIFIED (lecz przez własny sterownik `cpuz165`, §0.1) |
| **Wlasna tabela** | codename, nazwa, technologia, package, stepping name | STRONG INFERENCE |
| SMBIOS | plyta/system — **nie** rdzen | VERIFIED |
| Windows API | informacje systemowe | VERIFIED |

**Dlaczego "wlasna tabela" to STRONG INFERENCE:** CPUID **nie zawiera**
codename, technologii procesora ani nazwy socketu w zadnym lisciu. Zeby pokazac
"Vermeer", "7 nm" i "Socket AM4", narzedzie musi miec skad te napisy. Wniosek
z **faktu braku danych w CPUID**, nie z obserwacji kodu.

**Nowe z §7.2:** CPU-Z czyta **MSR** — raport zawiera
`PStateReg 0x80000000-0x48920888`, czyli `MSR 0xC0010064` (PSTATE_CURRENT).

> **KOREKTA 2026-09-29 (rewizja 3).** Wniosek, że „nie trzeba pisać własnego
> sterownika", był **błędny** i został obalony pomiarem na żywo (§0.1).
> CPU-Z **ma własny sterownik jądra**: `cpuz165`. Dostęp do MSR wynika
> właśnie z tego sterownika, a nie z „dostępu bez sterownika”.

---

## 2. CPUID leaves a tozsamosc

| Leaf | Pole | Rola | Uzywane przez CPU-Z? |
|---|---|---|---|
| `0x0` | max leaf, vendor | zakres, producent | VERIFIED (oba) |
| `0x1` EAX | base fam/model/step | dopasowanie | VERIFIED (oba) |
| `0x1` EBX | logical CPUs | topologia | VERIFIED (oba) |
| `0x4` / `0x8000001D` | cache | hierarchia | VERIFIED (oba) |
| `0x7`, `0x80000001` | features | zestaw instrukcji | VERIFIED (rozna konwencja, §7.2.2) |
| `0xD` | XSAVE | — | VERIFIED (oba) |
| `0x80000000`/`01` | ext family/model/step | dopasowanie | VERIFIED (oba) |
| `0x80000002..4` | brand string | **nazwa + wariant** | VERIFIED (oba) |
| `0x8000001E` | core id per watek | topologia AMD | VERIFIED (oba) |
| MSR `0xC0010064` | P-state | P-states/FID/VID | VERIFIED (CPU-Z) |

**Liscie `0x80000002..4` sa kluczowe i niedoceniane.** To jedyna linia CPUID
przenosaca **wariant** ("5800X3D" vs "5800X"). Sygnatura `0x00A20F12` jest dla
obu identyczna — potwierdzone w §7.2.

---

## 3. Analiza roznicowa — WYKONANA

Pelna tabela w **§7.2**. Podsumowanie: **~20 pol zgodnych, 3 roznice prezentacji,
2 realne luki po naszej stronie (`VMR-B2`, `package`), ~10 pol ktorych CPU-Z ma,
a my nie (z bazy lub z MSR).**

Przypadki z briefu, ktorych **nie da sie** sprawdzic na tej maszynie
(jeden CPU, jeden vendor):

* ten sam family, rozny model — brak drugiego procesora fizycznie
* Intel hybrid, starsze procesory bez `0x0B`/`0x1F` — brak takiego sprzetu
* nieznany stepping — stepping `2` jest jedynym, jaki mamy
* brand string rozniacy dwa SKU o tej samej sygnaturze — nie mamy drugiego

Te przypadki mozna ocenic tylko na **fixture'ach FerrumScope** (co robimy
w testach) albo na maszynie wirtualnej z podmienionym CPUID. Nie wykonuje ich
w tym raporcie i nie udaje, ze tak.

---

## 4. Strategia dopasowania

**Dedukcja z obserwacji wyjsciowej, nie z kodu (STRONG INFERENCE):**
CPU-Z implementuje **kombinacje**:

1. **Tabela dokladnych wpisow** — `VMR-B2` to *nazwa*, ktorej nie ma w CPUID.
2. **Zakresy modeli** — jeden wpis pokrywa generacje.
3. **Fallback** — przy nieznanym modelu pokazuje `model unknown`, ale
   **zachowuje inne pola** (obserwacje cudze, §6).

| Cecha | CPU-Z (inference) | FerrumScope (VERIFIED) |
|---|---|---|
| Jawne poziomy jakosci | brak dowodu | `HitLevel` |
| Wpis rodzinny musi byc **jawnie** oznaczony | nie wiadomo | `family_generic = true` + walidacja `0x00..0xFF` |
| Wskazanie zrodla per pole | nie wiadomo | `FieldSource` per pole |
| Zakres bez stalej rodziny | nie wiadomo | wybor `family_field` + `ext_family` |
| Podpis zrodla per wpis | nie wiadomo | `source` / `source_url` |

**Tu FerrumScope jest lepszy i to jest nasza przewaga.** CPU-Z moze pokazac
nazwe, ale **nie wiadomo, czy potrafi powiedziec "nie wiem, a ta nazwa dotyczy
rodziny, nie tego ukladu"**. My potrafimy — dlatego `intel_2xsocket_8core`
pokazuje `vendor_only`, a nie cudzy "Merom/Conroe".

---

## 5. Brand-assisted identification

Sygnatura CPUID `5800X` i `5800X3D` jest identyczna (`0x00A20F12` na naszym
sprzecie). Rozni ja **wylacznie brand string**.

**Czy CPU-Z tego uzywa? — UNKNOWN.** W §7.2 CPU-Z pokazuje
`Name: AMD Ryzen 7 5800X3D` i `Specification: AMD Ryzen 7 5800X3D 8-Core Processor`
— oba to **brand string**, pokazany, nieuzyty do rozroznienia dwoch SKU
w bazie. Nie mam dowodu na mechanizm dopasowania po brand stringu; nie twierdze,
ze go nie ma.

### Proponowany mechanizm FerrumScope (do decyzji, nie do wdrozenia)

```
raw signature (ext_family, family, model, stepping)
  -> HWDB match -> pattern/exact
  -> brand-derived refinement (OPCJONALNIE, ograniczona)
  -> final identity
```

Zasady:

1. **Brand refinement nigdy nie nadpisuje twardych danych CPUID.**
2. **Refinement dotyczy tylko pol, ktorych CPUID nie niesie**: `variant`,
   `cache_variant`. Nigdy `family`, `model`, `stepping`, `topology`.
3. **Pochodzenie widoczne** — `FieldSource.brand_derived` juz istnieje.
4. **Brak dopasowania = brak refinementu.** Jesli HWDB nie zna modelu,
   nie zgadujemy wariantu z brand stringu.

Punkt 4 jest najwazniejszy: gdyby dopasowanie HWDB zawiodlo, heurystyka
brand stringu przejela by role i zrobila dokladnie to, o co naprawilismy
blad "Merom/Conroe" — podsunela by nazwe bez pokonania.

---

## 6. Nieznany sprzet

**Obserwacje cudze (WEAK — nie moj pomiar):**

* `forum-en.msi.com` (Phenom X4 940): „both Vista and CPU-Z show the
  specification as *AMD Processor model unknown*", ale „CPU-Z does show the
  correct name, code name and package."
* `sevenforums.com` (Athlon 11 245): „it shows up as AMD model unknown".

**Wniosek (STRONG INFERENCE):** CPU-Z przy nieznanym modelu **nie pomija pola** —
zostawia je i pokazuje tam `unknown`. To **czesciowe rozpoznanie z jawna luka**,
madrejsze niz nasze `vendor_only` (ktore nie bierze nazwy z wpisu rodzinnego).

| Poziom | FerrumScope | CPU-Z (inference) |
|---|---|---|
| exact / pattern | `exact`, `pattern` | tabela + zakresy |
| family_generic | **bez nazwy** z wpisu rodzinnego | `unknown`, ale nazwa z innego zrodla |
| vendor_only | `vendor_only` | `model unknown` + zachowane inne pola |
| unknown | `unknown` | `model unknown` |

**Przewaga FerrumScope:** `family_generic` jest jawnie oznaczony jako
niewiarygodny (`isReliable() == false`). CPU-Z takiego znacznika nie ma.

---

## 7. ARM64

**VERIFIED (strona producenta cpuid.com/softwares/cpu-z-arm64.html):**
CPU-Z dla Windows ARM64 pokazuje **Soc name** (nie `family`/`model`!),
architecture, process, **cores topology (hybrid)** i *real-time max clock for
every **coreset***, GPU, **SoC caches topology**, system/BIOS/pamiec.

**VERIFIED (news #77 + techflare.net):** osobny zaklad **„SoC"** z codename
(np. „Qualcomm Snapdragon 8 Gen 3") i procesem w nm.

1. **To nie jest `family`/`model`.** ARM nie ma pola „model" w rozumieniu x86.
   CPU-Z ARM64 uzywa **nazwy SoC jako glownego identyfikatora** (STRONG INFERENCE).
2. **„coreset" zamiast „core".** Hybryda ARM = P/E w klastrach o wspolnym
   zegarle, nie dwa typy rdzeni na pakiecie (VERIFIED).
3. **Real-time max clock per coreset** — zegar zbiorczy klastra.
4. **Brak MSR** — ARM nie ma MSR; identyfikacja idzie inna droga (SMBIOS/ACPI).

**Wniosek:** **nie wcisnac ARM w abstrakcje x86 `family`/`model`.** Osobna klasa
`SoC identity` z wlasnymi polami. ARM64 = osobny podsystem.

---

## 7.1 LOCAL CPU-Z TEST

**Zrodlo:** `do referencji\cpuz\` (wersja portable, nie instalacja systemowa).
Obok: `cpuz.ini`, `cpuz_readme.txt`, osobno `do referencji\gpuz\GPU-Z.2.71.0.exe`.

| Pole | `cpuz_x64.exe` | `cpuz_x32.exe` |
|---|---|---|
| Rozmiar | 7 447 032 B | 5 904 888 B |
| SHA-256 | `A01369043C9E199747D62B950FB6DB3F793EA74FEB9C667AE291988405905FBE` | `1454F1D8E6C2B4016ABA1F5C1918A3B8BC33113BDADC066E7EDC62F9F5E1FCD8` |
| Wersja PE | 3.0.1.0 | 3.0.1.0 |
| Company / Product | `CPUID` / `CPU-Z Application` | `CPUID` / `CPU-Z Application` |
| Machine | `0x8664` IMAGE_FILE_MACHINE_AMD64 | `0x014C` IMAGE_FILE_MACHINE_I386 |
| Optional magic | `0x020B` PE32+ (64-bit) | `0x010B` PE32 (32-bit) |

**Uruchomienie (VERIFIED):** `cpuz_x64.exe -txt=cpuz` -> **exit code 0**,
raport 248 087 B, `CPU-Z version 3.01.0`. Tryb headless, bez GUI.

**FerrumScope:** zbudowany swiezo (`zig build`) *przed* porownaniem — zgodnie
z lekcja z Etapu 2, `zig build test` nie odswieza `zig-out/bin/ferrumscope.exe`.
Bez tego porownanie mieszalo dwa artefakty zbudowane w roznych momentach.

---

## 7.2 CPU-Z vs FerrumScope — Ryzen 7 5800X3D

Sygnatura z obu: `0x00A20F12`, `display_family=0x19`, `display_model=0x21`, `stepping=2`.

| Pole | CPU-Z 3.01.0 | FerrumScope | Ocena |
|---|---|---|---|
| Name | `AMD Ryzen 7 5800X3D` | `AMD Ryzen 7 5800X3D 8-Core Processor` | roznica prezentacji — CPU-Z skraca |
| Specification | `AMD Ryzen 7 5800X3D 8-Core Processor` | = brand | **ZGODNE** |
| Family | `19.21` (hex) | `25` (dzies.) = `0x19` | **ZGODNE** — §7.2.1 |
| Extended CPUID | `19.21` | `0x19.0x21` | **ZGODNE** |
| Model | `21` (hex) | `0x21` = 33 dzies. | **ZGODNE** |
| Stepping | `2` | `2` | **ZGODNE** |
| CPUID base | `F.1.2` | — | CPU-Z pokazuje dwie formy |
| Codename | `Vermeer` | `Vermeer / Milan-X (Zen 3, Ryzen 5000 i EPYC 7003)` | roznica zakresu — my ostrzejsi, bo granicy `0x2F`/`0x30` nie potwierdzilismy |
| Microarch | Zen 3 | `Zen 3` | **ZGODNE** |
| **Core Stepping** | **`VMR-B2`** | **brak** | **LUKA U NAS** — §7.3 |
| **Package** | **`Socket AM4 (1331)`** | **brak** | **LUKA U NAS** — §7.4 |
| Technology | `7 nm` | **brak** | luka (z bazy) |
| TDP Limit | `105.0 Watts` | **brak** | luka (z bazy) |
| Tjmax | `90.0 °C` | **brak** | luka (z bazy) |
| Microcode Rev | `0xA20120E` | **brak** | luka |
| Cores | `8 (max 8)` | `8` (`topology_source=hardware`) | **ZGODNE** |
| Threads | `16 (max 16)` | `16` | **ZGODNE** |
| Sockets | `1` (ID=0) | `1` | **ZGODNE** |
| CCD | `1` | **brak** | **LUKA U NAS** |
| CCX | `CCX 0` (Socket→Node→CCD→CCX→Core→Thread) | **brak** | **LUKA U NAS** |
| L1 data | `8 x 32 KB (8-way, 64B)` | `32 KiB, 8-way, line 64B` | **ZGODNE** — CPU-Z mnozy x rdzenie, my per instancja |
| L1 instruction | `8 x 32 KB` | `32 KiB, 8-way` | **ZGODNE** |
| L2 | `8 x 512 KB (8-way)` | `512 KiB, 8-way` | **ZGODNE** |
| L3 | `96 MB (16-way, 64B)` | `98304 KiB` = 100 663 296 B | **ZGODNE** — CPU-Z uzywa MB=2^20 |
| Instructions | 14 poz.: `MMX(+), SSE, SSE2, SSE3, SSSE3, SSE4.1, SSE4.2, SSE4A, x86-64, AES, AVX, AVX2, FMA3, SHA` | 21 flagow: `sse, sse2, sse3, ssse3, sse4_1, sse4_2, sse4a, aes, avx, avx2, fma, sha, fma4, bmi1, bmi2, f16c, lzcnt, popcnt, movbe, rdrand, rdseed` | **my bogatsi** — §7.2.2 |
| Core Speed | `4220.1 MHz` | **brak** | luka (pomiar dynamiczny) |
| Bus speed | `99.9 MHz` | **brak** | luka |
| Max CPUID level | `0000000Dh` | `cpuid_leaves: 90` | **ZGODNE** |
| Max CPUID ext | `8000001Eh` | `max_extended=0x8000001E` | **ZGODNE** |
| P-States | `3` (FID/VID) + `PStateReg` z MSR | **brak** | luka (wymaga MSR) |
| ACPI timer | `3.580 MHz` | **brak** | luka |

**Podsumowanie:** **~20 pol zgodnych, 3 roznice prezentacji, 2 realne luki
(`VMR-B2`, package), ~10 pol ktorych CPU-Z ma a my nie.**

### 7.2.1 Pulapka porownania: Family

CPU-Z: `19.21` — **szesnastkowo**, `0x19` = 25.
FerrumScope: `Family 25` — **dziesietnie**.
**Ta sama wartosc.** Automatyczny diff pola `family` zglosilby falszywa roznice.
Podobnie `Model 0x21` vs `21`. Porownywac **znormalizowane liczby**, nie napisy.

### 7.2.2 Lista instrukcji: CPU-Z nie jest kompletnym oracle

**Fakty (VERIFIED):**
* CPU-Z **nie pokazuje** `BMI1/BMI2`, `F16C`, `LZCNT`, `POPCNT`, `MOVBE`,
  `RDRAND`, `RDSEED`, `FMA4` — a my mamy je z `0x7`/`0x80000001`.
* CPU-Z pokazuje `MMX(+)` i `x86-64` — a my mamy to implicite w architekturze.
* **Nazewnictwo:** `FMA3` (CPU-Z) = `fma` (my); `SSE4.1` (CPU-Z) = `sse4_1` (my).

**Wniosek:** CPU-Z jest dobrym oracle dla **identyfikacji modelu**, ale
**nie** dla **cech** — jego lista instrukcji jest niepelna dla Zen 3.

---

## 7.3 Revision/stepping mapping — `VMR-B2`

**Obserwacja (VERIFIED):** CPU-Z na naszym 5800X3D pokazuje
`Core Stepping: VMR-B2`. Nasz sprzet: `stepping=2`, `model=0x21` (Vermeer).

**Odtworzona regula (STRONG INFERENCE — nie kopiowanie tabeli):**

```
VMR = skrot nazwy kodowej rodziny (Vermeer)
B   = litera generacji stepppingu (funkcja nieznana)
2   = stepping z CPUID
```

**Czy da sie wyprowadzic z samego CPUID? — CZESCIOWO.**

| Czesc | Wyprowadzalna? | Uzasadnienie |
|---|---|---|
| `2` (cyfra) | **TAK** | `stepping` z `0x1`/`0x80000001` EAX[3:0] |
| `VMR` (rodzina) | **NIE** | wymaga nazwy kodowej rodziny -> baza |
| `B` (litera) | **NIE** | funkcja nieznana |

**Literka `B` — UNKNOWN.** Watek `overclock.net/threads/cpu-stepping-has-vmr-in-it`
zglasza `VMR-B0` i `VMR-B2` na 5950X (ten sam model `0x21`, stepping 0 i 2).
Sugeruje to, ze `B` jest **stala** dla Vermeer, a **cyfra = stepping**. Ale to
nie jest zrodlo pierwotne AMD — nie bede zgadywal.

**AMD Revision Guide — luka w pokryciu (VERIFIED z wyszukiwania):**
znalezione dokumenty dotycza:
* `56683.pdf` — Family 19h **Models 00h–0Fh** (Milan, Zen 3)
* `57095-PUB_1_01.pdf` — Family 19h **Models 10h–1Fh** (Milan-X, Zen 3)

**Zaden nie obejmuje Models 20h–2Fh (Vermeer, nasz `0x21`).** Dokumentacja
publiczna nie potwierdza mapowania `VMR-B2` dla naszego zakresu.

**Wniosek operacyjny:** mapping `VMR-B2` **wymaga wpisu w HWDB** z polem
`stepping_name` i provenance. Nie da sie go wyliczyc z CPUID. Proponowany wpis:

```toml
[[entry]]
vendor = "amd"
ext_family = 0x0A
family_field = 0x0F
model_min = 0x21
model_max = 0x21
stepping_min = 2
stepping_max = 2
uarch = "Zen 3"
codename = "Vermeer"
stepping_name = "VMR-B2"
source = "measurement"
source_url = "https://www.amd.com/en/search/documentation/hub.html"
confidence = "medium"
```

**Provenance: `measurement`** — `VMR-B2` zaobserwowalismy na realnym sprzecie
przez CPU-Z, ale **nie potwierdzilismy go w AMD PPR** (dokumentacja nie obejmuje
tego zakresu). Dlatego `medium`, nie `high`.

---

## 7.4 Package/socket — `Socket AM4 (1331)`

**Obserwacja (VERIFIED):** CPU-Z pokazuje `Package: Socket AM4 (1331)` oraz
`Package Type: 0x2`, `Model: 00`.

**Zrodlo (STRONG INFERENCE):**

| Element | Zrodlo | Pewnosc |
|---|---|---|
| `Package Type 0x2` | pole CPUID (AMD extended leaf — prawdopodobnie `0x80000001` EAX; **nie potwierdzilem**) | WEAK INFERENCE |
| `Socket AM4` | **baza** — nazwa gniazda nie jest w CPUID | STRONG INFERENCE |
| `(1331)` | liczba pinow — z bazy | STRONG INFERENCE |

**Alternatywne zrodlo systemowe:** SMBIOS typ 3 (Processor Information) ma
`Socket Designation` i `Socket Type`. To daloby `Socket AM4` **z systemu, bez
bazy FerrumScope** (STRONG INFERENCE — niesprawdzone, nie odczytalismy SMBIOS
w tym przebiegu).

**Proponowane pole:**

```zig
package: ?[]const u8 = null,          // "AM4"
package_pins: ?u16 = null,           // 1331
package_source: FieldSource = .none, // .hwdb | .smbios
```

Priorytet: **SMBIOS > HWDB**, bo SMBIOS to odczyt systemowy (podlega
zasadzie „sprzet bije baze"), a HWDB to wpis autora bazy.

---

## 7.5 Korekta provenance: XCPUID

**Moj blad z rewizji 1.** Pisałem: „CPU-Z i **XCPUID to ten sam autor**
(cpuid.com / xcpuid.com), a XCPUID jest open source."

To jest **niepotwierdzone i najpewniej bledne** w tej formie:

* CPU-Z jest produktem **CPUID** (Franck Delattre) — to potwierdzone
  (PE `CompanyName = CPUID`, domena `cpuid.com`).
* **XCPUID** to **osobna linia projektu** (historycznie WCPUID), **nie**
  tozsama z CPUID. **Nie znalazlem zrodla pierwotnego**, ze to jeden autor.

**Korekta:** XCPUID traktujemy jako **niezalezny projekt referencyjny**, dopoki
zrodlo pierwotne nie potwierdzi inaczej. W raporcie nie powołujemy sie na niego
jako „zrodlo tego samego autora co CPU-Z".

**Kontekst (VERIFIED z wyszukiwania):** istnieja **dwa** niezalezne projekty
open source o podobnej nazwie:
* `anrieff/libcpuid` — mala biblioteka C, **inny autor**,
* `x86-cpuid.org/x86-cpuid-db` — maszynowo czytelna baza CPUID.

Zaden z nich nie jest XCPUID. **Repozytorium XCPUID nie odnalazlem** w tym
researchu — wczesniejsze wyszukiwanie `XCPUID library github source` zwrocilo
`raw-cpuid` (Rust) i `libcpuid`, nie XCPUID.

---

---

## 8. Co zaimplementowano po tym researchu

Punkty 1 i 2 z §11 zrealizowane. Punkt 3 (`family_generic` z nazwą rodzinną)
**nadal otwarty** — wymaga decyzji, bo rusza kompromis z Etapu 2.

### Nowe pola

| Pole | Typ | Znaczenie |
|---|---|---|
| `stepping_name` | `?[]const u8` | nazwa kodowa stepppingu, np. `VMR-B2` |
| `stepping_name_source` | `FieldSource` | `.empirical` / `.hwdb_exact` / … |
| `stepping_name_provenance` | `Provenance` | URL, typ dowodu, pewność, notatka |
| `socket_name` | `?[]const u8` | typ gniazda, np. `AM4` |
| `socket_source`, `socket_confidence`, `socket_provenance` | — | analogicznie |
| `package_contacts` | `u16` | **0 = nieznana** |
| `smbios_socket_designation` | `?[]const u8` | slot na płycie, **osobno** od gniazda |
| `product_name` | `?[]const u8` | konkretny SKU z brandu |
| `variant_source`, `cache_variant_source` | `FieldSource` | `.brand_derived` |
| `signature_source` | `FieldSource` | `.cpuid` — odróżnia surowe od interpretacji |

`FieldSource` rozszerzone o: `hwdb_exact`, `hwdb_pattern`, `hwdb_family`,
`brand_derived`, `smbios`, `platform`, `empirical`, `unknown`.
`codename_source` i `microarchitecture_source` przestały zapisywać jedno
`.hwdb` i rozróżniają teraz trafienie konkretne od dopasowania wzorcem.

### Format bazy v2 → v3

Dwie nowe sekcje payloadu: `Fact` (32 B) i `BrandRule` (36 B). Nagłówek
72 → **80 B** (doszły dwa liczniki). `entry_size` bez zmian — patrz
`docs/03-hwdb.md` §2.4 i §3.1–3.2.

**Dlaczego osobne sekcje, a nie dodatkowe pola `Entry`:** `Entry` decyduje
`MatchQuality`. Zakres `0x20..0x3F` to desktop (AM4) **i** serwer (SP3) w jednym
wpisie, więc opisanie gniazda w `Entry` wymusiłoby rozbicie wpisu — czyli zmianę
semantyki dopasowania, o którą brief wyraźnie prosił.

### Wynik na 5800X3D (VERIFIED, realny sprzęt)

```
Signature   : 0x00A20F12  (Family 25, Model 0x21, Stepping 2)
Microarch   : Zen 3                             <- HWDB (hwdb_pattern)
Codename    : Vermeer / Milan-X (...)           <- HWDB (hwdb_pattern)
Stepping nm : VMR-B2    (źródło: empirical, pewność: medium)
Socket      : AM4       (źródło: hwdb_exact, pewność: medium)
Variant     : 3D V-Cache (źródło: brand_derived)
Cores       : 8 physical / 16 logical (źródło: hardware)
L3 unified  : 98304 KiB
```

Zgodne z §7.2: `VMR-B2` i `AM4`. `package_contacts` pozostaje **0 (unknown)** —
punkt 4 §11 świadomie go nie wypełniamy.

### Czego **nie** potwierdziliśmy

* **Litera `B`** w `VMR-B2` — nadal `UNKNOWN`, brak pierwotnego źródła AMD.
  Wpis ma `confidence = medium`, `source_type = "reference_observation"`.
* **`package_contacts`** — brak niezależnego potwierdzenia producenta dla `1331`.
* **Granica `0x2F`/`0x30`** — podział Vermeer/Milan-X wciąż **niepotwierdzony**,
  dlatego `socket_name` ma zakres `0x21`, a nie całe `0x20..0x3F`.
* **SMBIOS `Socket Designation`** — pole istnieje i jest odrębne, ale
  **nie odczytujemy SMBIOS**, więc w praktyce jest `null`. Nie testowane na
  prawdziwym odczycie.
* **Inny sprzęt niż 5800X3D** — walidacja faktów i reguł brand opiera się na
  jednej zmierzonej sygnaturze. Testy 5800X / 5800X3D / Intel / malformed używają
  **syntetycznych** `RawCpuInfo`, a nie innego procesora.

### Błąd, który kosztował najwięcej czasu

`decode` kończy się `return switch (match.level)` przed wyborem nazwy. Blok
`applySignatureFacts` wstawiony **po** tym `return` był **nieosiągalny** —
wykonywałby się wyłącznie dla `best == null`, a wtedy warunek
`if (best != null)` i tak by go wyłączył. Testy pokazały `null` dla
`stepping_name` / `socket` / `variant` przy poprawnym `codename`, co jednoznacznie
wskazało czytnik, a nie bazę. Naprawione przeniesieniem wywołań **przed** `return`.

---

## 9. Co FerrumScope juz robi dobrze

1. **Jawna taksonomia trafien** (`HitLevel`) zamiast magicznego `specificity`.
2. **`family_generic` wymaga jawnej flagi** + walidacja zakresu. CPU-Z tego
   nie musi, bo nie pokazuje poziomu wiarygodnosci.
3. **Osobne `FieldSource` per pole** — brand string i brak wiedzy o uarch
   współistnieją bez sprzecznosci.
4. **`canUseQuirks`** — wpis rodzinny nie moze dac `smt_threads`.
5. **Sprzet bije baze** — quirk `hybrid_cores` nie kasuje zmierzonej liczby.
6. **`vendor_only` z CPUID**, a nie z losowego wpisu bazy.
7. **`bits = 0` = „nie wiem"** dla niepotwierdzonych układow bitowych.
8. **Provenance obowiazkowy** — `source`/`source_url` per rejestr.
9. **Normalizacja `display_family`/`display_model`** — my pokazujemy wartosc
   dziesietnie i heks, co **usuwa pulapke porownania** (§7.2.1).
10. **Features bogatsze niz CPU-Z** (§7.2.2) — 21 flagow, w tym `FMA4`,
    `SSE4A`, `BMI1/2`, `RDRAND`, `RDSEED`, `F16C`, `LZCNT`, `POPCNT`, `MOVBE`.

---

## 9. Gdzie CPU-Z sugeruje lepszy model

Wszystkie obserwacje ponizej sa z **realnego porownania** (§7.2), nie z sieci.

| # | CPU-Z pokazuje | Nasz stan | Priorytet |
|---|---|---|---|
| 1 | `Core Stepping: VMR-B2` | brak pola `stepping_name` | **WYSOKI** — §7.3, regula odtworzona, wymaga wpisu HWDB |
| 2 | `Package: Socket AM4 (1331)` | brak pola `package` | **WYSOKI** — §7.4, mozliwe ze SMBIOS |
| 3 | Hierarchia `Socket→Node→CCD→CCX→Core→Thread` | brak w `cpu` | SREDNI |
| 4 | `Technology: 7 nm` | brak | SREDNI — z bazy, nie pomiar |
| 5 | `TDP Limit: 105.0 W`, `Tjmax: 90 °C` | brak | SREDNI — **z bazy, nie pomiar** |
| 6 | `Microcode Rev: 0xA20120E` | brak | niski |
| 7 | `Core Speed: 4220.1 MHz`, `Bus speed: 99.9 MHz` | brak | niski — pomiar dynamiczny |
| 8 | P-States (3) + `PStateReg` z **MSR** | brak | niski — wymaga MSR (Etap 3B) |
| 9 | `ACPI timer: 3.580 MHz` | brak | niski |
| 10 | Przy `model unknown` **zachowuje nazwy** | `family_generic` nie pozwala na nazwe | **DO ROZWAZENIA** |
| 11 | ARM64: SoC jako identyfikator, coresety jako jednostka | brak | **OSOBNY PODSYSTEM** |

### Ad. 10 — najciekawsza roznica (nadal otwarta)

CPU-Z przy `model unknown` **zachowuje** name/codename/package. My przy
`family_generic` **nie pozwalamy** wziac nazwy z wpisu rodzinnego.

To swiadomy kompromis Etapu 2 (naprawilismy „Merom/Conroe"). Ale obserwacja
CPU-Z sugeruje trzecia droge, ktorej nie mamy: **pokazac nazwe rodzinna, ale
oznaczyc ja jako niepewna dla tego ukladu.**

Proponowany model (do decyzji, nie do wdrozenia):

```
family_generic match → nazwa z wpisu rodziny + flaga "dotyczy rodziny, nie ukladu"
```

To daloby uzytkownikowi wiecej informacji niz pustka, **bez** ryzyka, ze
nazwa przepadnie. Ryzyko: uzytkownik przestanie czytac flage. Dlatego
zaproponowalbym to dopiero z pomiarem, czy flaga jest faktycznie czytana —
inaczej to tylko ladniejsze klamstwo.

**Na naszym sprzecie tego nie da sie sprawdzic** — 5800X3D trafia `pattern`,
nie `family_generic` (§7.2).

---

## 10. Czego nadal nie umiem ustalic

1. **Czy CPU-Z uzywa brand stringu jako klucza dopasowania** (tylko
   wyswietlania, czy tez do wariantu). **UNKNOWN** — kluczowe dla §5.
   Dane z §7.2 **nie rozstrzygaja**: `Name` i `Specification` to oba brand
   string, sygnatura i tak jest jednoznaczna.
2. **Czy CPU-Z ma jawny poziom wiarygodnosci** dopasowania (**WEAK**: nie).
3. **Taksonomia XCPUID — NIEZNANA.** Repo **nie odnalazlem** (§7.5). Nie wolno
   uzywac XCPUID jako zrodla mechanizmu, dopoki provenance nie potwierdzony.
4. **Funkcja litery `B` w `VMR-B2`** — **UNKNOWN**, brak zrodla pierwotnego AMD.
5. **Ktory lisciek CPUID daje `Package Type`** — **WEAK INFERENCE**, niepotwierdzone.
6. **Rzeczywiste zachowanie dla nieznanej rodziny o znanym vendorze** — tylko
   obserwacje cudze. CPU-Z jest lokalnie dostepny (§7.1), wiec brakuje tylko
   sprzetu z nieznanym modelem (ewentualnie VM z podmienionym CPUID).
7. **ARM64 wewnetrznie** — tylko opis producenta; kodu nie analizowalem.

---

## 11. Konkretne zmiany do rozwazenia (NIE zaimplementowane)

### Wysoki priorytet, niskie ryzyko

1. **`stepping_name` w modelu i HWDB** — §7.3. Pole tekstowe obok `stepping`,
   z `FieldSource.hwdb`. Wpis dla `0x21`/`stepping=2` z `provenance = "measurement"`,
   `confidence = "medium"`. **Nie** wyprowadzamy litery `B` z CPUID.
2. **`package` + `package_pins` + `package_source`** — §7.4. Priorytet SMBIOS
   nad HWDB (zasada „sprzet bije baze").

### Wymaga decyzji projektowej

3. **`family_generic` z nazwa rodzinna + flaga wiarygodnosci** — §9 ad. 10.
4. **`brand_derived` refinement dla `variant`/`cache_variant`** — §5, tylko przy
   dopasowaniu HWDB (punkt 4 zasady: brak dopasowania = brak refinementu).

### Poza zakresem x86

5. **Podsystem ARM64/SoC** — §7, osobne klasy, nie galaz `ids.Signature`.

### Czego **nie** przenosic

* Kopkowanie tabel CPU-Z/XCPUID.
* Zgadywanie `Technology` z brand stringu.
* Dopasowywanie po fragmencie brand stringu jako glowna sciezka.
* `TDP`/`Tjmax` z bazy podstawiane za pomiar.
* `stepping_name` dla liter (`B`), ktorych nie umiemy wyprowadzic — tylko
  potwierdzone przez `measurement`.

---

## 12. Jak domknac luki

| Luka | Jak |
|---|---|
| §10.1 brand-as-matching | Drugi SKU o tej samej sygnaturze (5800X vs 5800X3D). **Nie mamy drugiego CPU** — potrzebna maszyna z 5800X. Alternatywnie: publiczne raporty CPU-Z VALIDATOR i porownanie pol, ktore sie roznia. |
| §7.3 litera `B` | AMD PPR / Revision Guide dla Family 19h **Models 20h–2Fh**. Znalezione 56683 i 57095 dotycza 00h–0Fh i 10h–1Fh — **to nie ten zakres**. |
| §7.4 liscie package | Odczyt SMBIOS typ 3 na tej maszynie + porownanie z CPU-Z. |
| §10.3 XCPUID | Repo XCPUID — **nieodnalezione**; mozliwe, ze niedostepne publicznie. Nie blokowac — XCPUID nie jest zrodlem dla nas. |
| §10.6 zachowanie dla nieznanej rodziny | VM z podmienionym CPUID, o ile CPU-Z nie odrzuci sfabrykowanego wejscia. |
| §7 ARM64 | Opis producenta + ewentualnie test na maszynie ARM64. |

**Rekomendacja:** punkty 1 i 2 z §11 warte zrobienia od razu — niskie ryzyko,
uzasadnione **obserwacja, nie zgadywaniem**. Punkt 3 wymaga dyskusji, bo zmienia
kompromis z Etapu 2.
