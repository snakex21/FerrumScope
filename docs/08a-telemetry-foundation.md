# 08a — Fundament telemetryczny (Etap 3A)

Status: **ukończony.** `zig build` PASS, `zig build test` **220 passed / 3 skipped (Linux runtime) / 0 failed** — baza wyjściowa Etapu 3A była 186, doszło 34 testy.

Nie rozpoczęto Etapu 3B, GPU, RAM/SPD, storage ani GUI. Sterownika **nie
napisano, nie podpisano i nie zainstalowano**; `TESTSIGNING` **nie był zmieniany**.

## 0. Punkt otwarty: zawężanie codename (§0 briefu)

Szeroki wpis bazy nadal zwraca `Vermeer / Milan-X`. **Nie rozwiązaliśmy tego
zgadywaniem** — podział na granicy `0x2F`/`0x30` pozostaje niepotwierdzony.

Przygotowaliśmy **mechanizm** z bramką provenance:

* `BrandRule.refined_codename` (pole w formacie, **puste w bazie**),
* `BrandRule.canNarrowCodename()` — przepuszcza wyłącznie `vendor_doc`,
  `vendor_doc_adjacent` i `derived`; **odrzuca** `reference_observation`,
  `community` i `none`,
* kompilator bazy **odrzuca wpis** z `refined_codename` i obserwacyjnym
  `source_type` (`error.UnverifiedNarrowing`),
* model ma osobne pola `codename_refined` + źródło + provenance, więc zawężony
  i szeroki codename **współistnieją** zamiast nadpisywać się nawzajem.

Uzasadnienie: zawężenie „Vermeer / Milan-X" → „Vermeer" oparte na porównaniu
z CPU-Z to obserwacja narzędzia referencyjnego, nie dokumentacja AMD.
`refined_codename` ma puste `confidence` i `source_type = reference_observation`
dokładnie wtedy, gdy pochodziłoby z CPU-Z — i wtedy bramka je blokuje.

## 1. Co było gotowe, a co powstało w tym etapie

| Element | Stan wejściowy | Praca w Etapie 3A |
|---|---|---|
| Kontrakt MSR + statusy | gotowy, przetestowany | — |
| Model zdolności | gotowy | — |
| Model metryk (kategorie/scope) | gotowy | — |
| Silnik pollingu | gotowy, przetestowany | — |
| Matematyka liczników (32/48/64) | gotowa | — |
| APERF/MPERF | gotowy | — |
| Backend sztuczny | gotowy | **naprawiony błąd `time_ramped`** |
| Dekodery AMD/Intel | gotowe, „nie zgadujemy" | — |
| **Katalog metryk** | brak | nowy: `src/telemetry/catalog.zig` |
| **Capture/replay telemetry** | brak | nowy: `src/capture/telemimg.zig` |
| **CLI `sensors`** | brak | nowy: `cmdSensors` w `main.zig` |
| **Kontrakt sterownika** | brak | nowy: `src/telemetry/driver_proto.zig` |
| **Model bezpieczeństwa** | brak | nowy: `docs/SECURITY-MODEL.md` |
| **Podpisywanie** | brak | nowy: `docs/14-windows-signing.md` |

## 2. Błąd, który wykryło uruchomienie programu

`fake.Backend` z `time_ramped` liczył wartość jako
`start + per_second * (now_ns / ns_per_s)`. To dzielenie **całkowite przez
sekundę**, więc przy 250 ms dawało **zero**. Polowanie to 100–1000 ms, czyli
zawsze krócej niż sekunda — rampa stała w miejscu, a delta APERF/MPERF nigdy by
nie powstała.

Sam kod był „zielony": `zig build` przechodził, testy przechodziły. Wykryło to
uruchomienie `sensors --synthetic`, które wypisało `unavailable` dla metryki, którą
backend deklarował jako dostępną.

Naprawione mnożeniem **przed** dzieleniem, w `u128` (bo `per_second * now_ns`
dla licznika 5 GHz po kilkudziesięciu sekundach przekracza `u64`). Dodano test
regresyjny `time_ramped liczy w ułamku sekundy`.

**Wniosek: zielony build i zielone testy nie wystarczają, gdy nic nie zjada
wyników w czasie rzeczywistym.** Metryka bez realnego odczytu była zawsze
„niedostępna" i nic tego nie zauważało.

## 3. Katalog metryk i bramka `unverified`

Katalog wymienia to, co **chcemy** mierzyć, a `availability` mówi, co backend
potrafi. Metryka z katalogu może być `unverified` — i wtedy **żaden** backend,
nawet ze wszystkimi zdolnościami, nie wystarczy.

| Metryka | Stan | Powód |
|---|---|---|
| `cpu.core.effective_frequency` | `verified` | APERF/MPERF potwierdzone w Intel SDM i AMD APM |
| `cpu.core.frequency` | `verified` | rejestr potwierdzony |
| `cpu.logical.utilization` | `verified` | ACPI/rdpmc |
| `cpu.package.energy` | `unverified` | RAPL potwierdzone tylko dla Intel; brak potwierdzonego układu bitów dla AMD |
| `cpu.package.power` | `unverified` | pochodzi z delty energii |
| `cpu.package.temperature` | `unverified` | układ bitów niepotwierdzony w AMD PPR |
| `cpu.core.voltage` | `unverified` | brak potwierdzonej maski bitowej |
| `cpu.core.current` | `unverified` | brak potwierdzonego rejestru |
| `cpu.core.throttling` | `unverified` | bity statusu niepotwierdzone |
| `cpu.package.status` | `unverified` | rejestr statusu pakietu niepotwierdzony |

Osiem z dziesięciu metryk jest `unverified` i tak pozostanie, dopóki nie
potwierdzimy układów bitów. **Świadomie nie zgadywaliśmy** żadnego przesunięcia.

Rozróżnienie trzech przyczyn niedostępności ma znaczenie diagnostyczne:

* `brak wymaganych zdolności backendu` — potrzebny sterownik,
* powód `unverified` — luka wiedzy, nie brak sprzętu,
* `brak czujnika na tej platformie` — nic nie pomoże.

Gdy backend nie umie czytać **żadnego** MSR, `sensors` mówi „MSR access
unavailable", a nie „APERF/MPERF unavailable" — ta druga odpowiedź sugerowałaby,
że inne rejestry działają.

## 4. Capture/replay — dlaczego surowe odczyty

Format `telemimg` zapisuje `APERF = 0x1234`, **nie** `effective_clock = 3800 MHz`.
Gdyby plik trzymał wynik, replay nie wykonałby żadnych obliczeń i po poprawce
matematyki delty pokazywałby stare wartości — nie dałoby się sprawdzić, czy nowa
matematyka działa.

Replay implementuje **ten sam** `msr.Backend` co przyszły sterownik i backend
sztuczny. Dekoder nie wie, skąd pochodzą dane i nie może wiedzieć.

Trzy rzeczy wynikające z projektu, nie z przypadku:

* **Brak rekordu to `unsupported`, nigdy `0`.** Brak wiedzy i wartość zero to
  różne stany; `get()` zwraca `null`, więc nikt nie wyświetli zera jako pomiaru.
* **Błędy są osobnym typem rekordu.** `permission_denied` znaczy „w tej chwili nie
  było dostępu", a brak rekordu znaczy „nikt tego nie czytał". W `readMsr` wyglądają
  podobnie, diagnostycznie to zupełnie różne sytuacje.
* **Zegar pochodzi z pliku, nie z systemu.** Inaczej delta liczników zależałaby od
  tempa odtwarzania.

### Zgodność wsteczna

Format jest tekstowy, a sekcja telemetry **opcjonalna**. Plik `.cpuimg` bez linii
`telem` parsuje się jak dotychczas, a `sensors --replay` mówi wprost
„stary format" zamiast zgłaszać uszkodzony plik.

Uszkodzony rekord **odrzuca cały plik**: tolerowanie jednej złej linii dałoby po
cichu dane stracone, a w pliku diagnostycznym brak danych wyglądałby jak
„czujnik milczał".

### `nominal_hz` jest obowiązkowy

APERF i MPERF to **stosunek** cykli, a nie częstotliwość w Hz. Bez skali
czasowej nie ma czego skalować, dlatego capture zapisuje ją obok surowych
liczników. Gdy jej brakuje, efektywna częstotliwość zwraca `unavailable`, a nie
zgadywane MHz. Test `brak nominal_hz uniemożliwia obliczenie` to pilnuje.

## 5. CLI

```
ferrumscope sensors                    stan czujników
ferrumscope sensors --synthetic        backend testowy (wartości NIE są pomiarem)
ferrumscope sensors --replay <plik>    odtwórz z pliku
ferrumscope sensors --watch            przebieg klatka po klatce
ferrumscope sensors --bench            koszt cyklu pollingu
ferrumscope sensors --json             wynik w JSON
```

Na obecnym Windows **bez** uprzywilejowanego backendu:

```
FerrumScope sensors  [źródło: brak dostępu do MSR (sterownik niezaładowany lub nie zaimplementowany)]
  Zdolności backendu: brak — żadna metryka sprzętowa nie może zostać odczytana

  Effective Clock   : unavailable (MSR access unavailable)
  ...
```

To jest wymagany wynik: brak wartości zmyślonej, konkretny powód, kod wyjścia 0.
Backend „brak dostępu" deklaruje **zero** zdolności i zwraca
`permission_denied`, implementując ten sam interfejs — dekoder nie musi wiedzieć,
że sprzętu nie ma.

Gdy próbka istnieje, ale nie ma wartości (np. pierwszy odczyt), wypisujemy
**status tej próbki**, nie stan katalogu. Inaczej metryka dostępna zgłaszałaby
„brak wymaganych zdolności", co jest sprzeczne z nagłówkiem powyżej.

## 6. Wydajność (§15)

Zmierzone na backendzie sztucznym, 2000 cykli na interwał, 1 CPU, 1 metryka:

| interwał | cykli | ns/cykl | odczyty MSR/cykl |
|---|---|---|---|
| 100 ms | 2000 | 452 | 2 |
| 250 ms | 2000 | 458 | 2 |
| 500 ms | 2000 | 448 | 2 |
| 1000 ms | 2000 | 555 | 2 |

**To nie jest koszt odczytu MSR.** Prawdziwy odczyt wymaga przełączenia
kontekstu na właściwy CPU (albo przypięcia wątku), co na Windows oznacza
transition do jądra — pomiar tego w ogóle nie obejmuje.

Liczba odczytów jest stała (2: APERF + MPERF) niezależnie od interwału, co
potwierdza, że cache silnika faktycznie grupuje odczyty w obrębie cyklu.
Koszt jest **niezależny od interwału** — interwał wpływa na częstotliwość
wywołań, nie na koszt pojedynczego cyklu.

Punkty procentowe: 0,0000452–0,0000555% interwału. Zapas jest duży, ale to
dane syntetyczne i decyzja o częstotliwości należy do Etapu 3B.

## 7. Kontrakt sterownika (§12) — projekt, bez kodu jądra

Trzy IOCTL: `QUERY_PROTOCOL`, `QUERY_CAPABILITIES`, `READ_MSR`. Nic więcej.

**Allowlist, nie blocklist.** Dozwolone są dwa rejestry: `0xE8` i `0xE7`.
Temperatura i P-state są w katalogu jako `unverified`, ale **nie ma ich**
na liście. Blocklista byłaby bezpieczna tylko wtedy, gdybyśmy znali wszystkie
niebezpieczne rejestry — a nie znamy i nie będziemy zgadywać.

Test `w protokole nie ma ŻADNEGO zapisu MSR` sprawdza to mechanicznie: zbiór
wariantów `Function` musi mieć dokładnie tyle elementów, ile operacji odczytu
opisaliśmy, a kody IOCTL nie mogą mieć prawa do zapisu ani `METHOD_NEITHER`.

Kolejność walidacji jest ustalona i testowana: **magic → wersja → rozmiar →
CPU → rejestr**. Magic pierwsze, bo ramka bez sygnatury nie jest naszą ramką;
odwrócenie kolejności pozwoliłoby zgłosić zły rozmiar jako „złą wersję”.

`cpu_offline` jest osobnym statusem, nie podkategorią `unavailable`: `Rdmsr` dla
CPU, które zdążyło zejść z linii, to odczyt z **niewłaściwego procesora** —
liczba wyglądająca wiarygodnie, a dotycząca innego rdzenia.

## 8. Bezpieczeństwo i podpisywanie

`docs/SECURITY-MODEL.md` opisuje warstwy, zakres sterownika, walidację każdej
ramki, wyścig hotplug, długości buforów, nieautoryzowanego klienta oraz to, czego
**nie** robimy. Dokument ma też tabelę ryzyk, w tym otwarte: sterownika nie ma, więc
walidacja klienta **nie jest** granicą zaufania i żadna własność opisana w §5–§7
nie została zweryfikowana w trybie jądra.

`docs/14-windows-signing.md` rozdziela ścieżkę deweloperską (test signing, wyłącznie
na maszynie deweloperskiej) od produkcyjnej (Microsoft Hardware Dev Center, HLK).
Nie zmieniliśmy `TESTSIGNING`, nie wyłączaliśmy Secure Boot i nie utworzyliśmy konta
w Dev Center. Zmiana konfiguracji zabezpieczeń maszyny to decyzja jej właściciela,
nie programisty — i dokument mówi to wprost.

## 9. Czego **nie** zweryfikowaliśmy

* **Żadnego pomiaru na prawdziwym sprzęcie.** `platform/windows.zig` nie ma
  backendu MSR, a sterownika nie ma. Wszystkie liczby pochodzą z backendu
  sztucznego i z plików zapisanych ręcznie.
* **Repla na zapisie z realnego backendu.** Round-trip testuje format i replay,
  ale plik pochodzi z backendu sztucznego, nie z 5800X3D.
* **Kod w trybie jądra.** Wszystko w §7 jest walidacją **klienta**, którą
  sterownik ma powielić. Testy pilnują logiki, nie zastępują Driver Verifier ani HLK.
* **Wydajności odczytu MSR.** Zmierzono koszt silnika bez I/O (§6).
* **`--watch` na długich sesjach.** Przetestowane klatkowo, nie pod obciążeniem
  przez minuty.

## 10. Zmiany poza telemetryką

Format HWDB pozostał w wersji 3, ale `BrandRule` urósł z 36 do **40 B** o pole
`refined_codename` (offsety 36–39). `entry_size` bez zmian, semantyka
`family_generic` nietknięta. Zmiany `codename_source` z `.hwdb` na
`hwdb_exact` / `hwdb_pattern` pochodzą z Etapu 3B i pozostały zgodne z testami.
