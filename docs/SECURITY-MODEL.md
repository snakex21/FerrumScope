# Model bezpieczeństwa — FerrumScope

Status: **sterownik zbudowany i podpisany testowo, ale NIE załadowany i nie
zainstalowany.** Kod jądra istnieje (`driver/ferrum_msr.c`), kompiluje się i
linkuje, jednak żadna z własności opisanych niżej nie została jeszcze
zweryfikowana **wykonaniem** w trybie jądra. Kod klienta i walidacja protokołu
**są** realne i przetestowane (`src/telemetry/driver_proto.zig`).

## 1. Warstwy i kierunek zaufania

```
CLI / GUI  (proces usermode, bez uprawnień)
      │  otwiera urządzenie, wysyła IOCTL z buforem METHOD_BUFFERED
      ▼
core / usługa  (opcjonalnie: proces pośredni z podwyższonymi uprawnieniami)
      │
      ▼
service / driver  (tryb jądra — pełne zaufanie systemu)
      │  waliduje KAŻDĄ ramkę, dopiero potem robi Rdmsr
      ▼
sprzęt  (MSR)
```

Zasada: **ufamy tylko temu, co zweryfikowaliśmy.** Warstwa klientowa jest
niewiarygodna z definicji — proces usermode może być przejęty, a jego bufor
może wskazywać gdziekolwiek. Każda decyzja o dopuszczeniu odczytu zapada
**w sterowniku**, po walidacji.

### Dlaczego osobna warstwa usługi

Dziś CLI gada bezpośrednio ze sterownikiem. Usługa pośrednia jest opcjonalna i
przewidziana na wypadek, gdyby kiedyś sterownik musiał działać z innymi
uprawnieniami niż klient. Nie budujemy jej wcześniej, niż będzie potrzebna —
usługa, która nie ma zadania, jest tylko dodatkową powierzchnią ataku.

## 2. Zakres sterownika — dostawca danych, nie skrzynka z narzędziami

Sterownik **udostępnia wyłącznie**: `IOCTL_QUERY_PROTOCOL`,
`IOCTL_QUERY_CAPABILITIES`, `IOCTL_READ_MSR`.

Sterownik **nie udostępnia i nie będzie udostępniał**:

| Możliwość | Dlaczego nie |
|---|---|
| zapis MSR | nie istnieje żądanie zapisu — nie da się go wywołać nawet błędem klienta |
| dowolny odczyt pamięci fizycznej | pojedynczy błędny indeks = pełne odczytanie dowolnego miejsca w RAM |
| dowolny odczyt pamięci jądra | to jest praktycznie dowolne uprawnienia w systemie |
| dowolne MMIO | dostęp do rejestrów urządzeń, w tym do kontrolerów DMA |
| dowolne port I/O | zamknięte dla usermode; sterownik ma je zablokowane |

Każda dodatkowa możliwość w trybie jądra to **nowa klasa ataku**. Użytkownik
FerrumScope potrzebuje sześciu liczb. Argument „a sterowniki monitorujące mają
wszystko" jest odwróceniem argumentu: szerszy sterownik znaczy szerszą
powierzchnię, nie lepszy.

### 2.1 Stan implementacji (Etap 3B, 2026-09-29)

Granica zaufania **przeszła z planu na kod**: `driver/ferrum_msr.c` zawiera
walidację po stronie jądra, w kolejności magic → wersja → rozmiar → CPU →
rejestr, zgodną z testami po stronie klienta.

To zmienia ocenę — i tylko ją:

* **Walidacja jest teraz w jądrze**, a nie wyłącznie w kliencie. Poprzednio
  opisywała ją tylko tabela testów w `driver_proto.zig`.
* **Sterownik jest zbudowany** (`driver/build/FerrumScopeMsr.sys`, ręczny
  łańcuch `cl /kernel` + `link /driver`, patrz `driver/build_driver.bat`),
  podpisany testowo, a paczka ma katalog `driver/package/ferrumscopemsr.cat`.
  Walidacja jest **skompilowana, ale nieuruchomiona w trybie jądra**. Kod,
  który nigdy nie został wykonany, jest hipotezą o poprawności, nie faktem.
* **Odczyt nie używa DPC.** Wątek IOCTL (PASSIVE_LEVEL) jest przypinany przez
  `KeSetSystemGroupAffinityThread`, migracja jest **potwierdzana**
  `KeGetCurrentProcessorNumberEx` przed odczytem, a `__readmsr` jest owinięty
  w `__try/__except` (#GP → `FERRUM_READ_FAILED` zamiast BSOD).

Dlatego nie zmieniam pozycji „nieoceniony” na „oceniony”. Zmieniam **uzasadnienie**:
nie brakuje kodu ani narzędzi, brakuje załadowania sterownika (`TESTSIGNING`
wymaga zgody właściciela maszyny i restartu).

Brak zapisu MSR jest w kodzie **strukturalny**: `IRP_MJ_DEVICE_CONTROL`
obsługuje trzy znane kody, a `default` zwraca
`STATUS_INVALID_DEVICE_REQUEST`. Nie ma operacji zapisu, nie ma funkcji, nie ma
ścieżki — nie da się jej wywołać nawet błędem klienta.

## 3. Allowlist MSR, nie blocklist

Odczyt jest dozwolony **tylko** dla rejestrów na liście. Blocklista byłaby
bezpieczna, gdybyśmy znali wszystkie niebezpieczne rejestry — a nie znamy i nie
będziemy zgadywać. Pozwolenie domyślnie odrzucone to jedyna orientacja, która
nie psuje się z każdym nowym procesorem.

Lista jest dziś **dwa pozycje**: `0xE8` (APERF) i `0xE7` (MPERF) — jedyne, których
znaczenie potwierdziliśmy w Intel SDM i AMD APM.

Temperatura (`0xC0010014`) i P-state (`0xC0010064`) są w katalogu metryk, ale
**nie ma ich** na liście. Są w katalogu jako `unverified` i tak długo tam
zostaną, dopóki nie potwierdzimy układu bitów. To celowe: udostępnienie
niepotwierdzonego rejestru dałoby wiarygodnie wyglądające, całkowicie zmyślone
wartości.

Test `protokół: allowlist dopuszcza tylko potwierdzone rejestry` pilnuje tego
mechanicznie — dodanie rejestru do listy bez zmiany testu nie przejdzie.

## 4. Wejście niezaufane — walidacja każdej ramki

Wszystkie ramki przychodzą z procesu usermode i są **wrogie z założenia**.
Kolejność walidacji jest ustalona, bo kolejność błędów jest diagnostyką:

| # | Sprawdzenie | Błąd | Dlaczego w tej kolejności |
|---|---|---|---|
| 1 | `magic == protocol_magic` | `bad_magic` | Zanim spojrzymy na cokolwiek innego. Ramka bez sygnatury nie jest naszą ramką. |
| 2 | `min_client_version <= version <= protocol_version` | `unsupported_version` | Nie „ładniejszej wersji": kontrakt jest wąski i każda zmiana znaczenia jest zmianą sensu. |
| 3 | `struct_size >= @sizeOf(...)` | `bad_size` | Za mało pól = nie wiemy, czego nie dostaliśmy. Więcej pól = przyszłość, ogon pomijamy. |
| 4 | `logical_cpu < online_cpu_count` | `invalid_cpu` | Po rozmiarze, bo `logical_cpu` leży w strukturze o sprawdzonym rozmiarze. |
| 5 | `isMsrAllowed(msr_index)` | `msr_not_allowed` | Na końcu: najdroższe i najbardziej specyficzne. |

**Magic przed wersją** ma znaczenie praktyczne: gdyby odwrócić, zły `struct_size`
zgłosiłby się jako „zła wersja", a diagnosa zwijałaby się w złą stronę.

## 5. CPU offline i wyścig hotplug

Numeracja procesorów logicznych **zmienia się** przy hotplugu i przy zmianach
zarządzania energią. Licznik zapamiętany dla CPU 3 przestaje być ważny, gdy CPU 3
zostanie wyłączony.

Dlatego sterownik musi:

1. pobrać `online_cpu_count` w chwili obsługi żądania,
2. zwalidować `logical_cpu` względem **tej** wartości,
3. **ponownie** sprawdzić stan CPU bezpośrednio przed `Rdmsr`.

Pomiędzy (2) a (3) CPU może zejść z linii. `Rdmsr` dla CPU offline to nie tylko
błąd — to odczyt z **niewłaściwego procesora**, czyli liczba wyglądająca
wiarygodnie, a dotycząca innego rdzenia. To najgorszy możliwy wynik: cichy i
mylący.

Dlatego `MsrError.cpu_offline` jest **osobnym** statusem, a nie podkategorią
`unavailable`. Użytkownik ma wiedzieć, że licznik dotyczył innego CPU.

## 6. Długości buforów i przepełnienia

* `METHOD_BUFFERED` — jądro kopiuje bufor użytkownika w bufor jądra. **Nigdy**
  `METHOD_NEITHER`, który przepuszczałby surowe wskaźniki usermode do trybu
  jądra i zamienia każdy błąd klienta w dowolny zapis.
* Sterownik **nie może** zapisać więcej, niż klient przydzielił. Test
  `fitsInBuffer` to sprawdza; rozmiar odpowiedzi i żądania są dziś równe (24 B),
  a test pilnuje tej inwarianty — bo gdyby odpowiedź urosła, klient
  przydzielający bufor rozmiaru żądania dostałby zapis poza koniec.
* Nie mnożymy rozmiarów przez dane z ramki. `struct_size` porównujemy wprost,
  więc wartość bliska `maxInt(u32)` nie zawinie się do małej i nie przejdzie
  walidacji.
* `logical_cpu` to `u16`, `msr_index` to `u32`. Nie ma mnożenia `count * size`
  po stronie klienta ani sterownika, więc nie ma czego przepełnić.

## 7. Nieautoryzowany klient

Sterownik jest urządzeniem systemowym. Domyślna polityka:

* urządzenie tworzy się tylko dla administratorów, nie dla wszystkich sesji,
* `FILE_READ_DATA` w kodach IOCTL — brak `FILE_WRITE_DATA` w całym protokole,
* brak trybu „wszystko dozwolone dla debugowania". Jeśli kiedyś będzie potrzebny,
  ma być **jawnym** przełącznikiem budowania, nie ukrytą furtką.

Test `protokół: w protokole nie ma ŻADNEGO zapisu MSR` sprawdza to mechanicznie:
zbiór wariantów `Function` musi mieć dokładnie tyle elementów, ile operacji
odczytu opisaliśmy. Dodanie zapisu wymaga dodania wariantu → rozbieżność → błąd
testu.

## 8. Czego **nie** robimy

* **Nie podpisujemy i nie instalujemy sterownika w tym etapie.** Zmiana
  TESTSIGNING na maszynie użytkownika to decyzja właściciela maszyny, nie
  zadanie programisty. Patrz `docs/14-windows-signing.md`.
* **Nie ufamy danych z capture/replay jako pomiarowi.** Backend replayu i
  syntetyczny deklarują `sourceName` z jawnym oznaczeniem, a `Source` ma osobne
  pole `isRealHardware()`. Wartość syntetyczna nie może być przedstawiona jako
  pomiar — to ta sama klasa błędu co zmyślona temperatura.
* **Nie rozszerzamy allowlisty „na wiarę".** Każdy wpis wymaga potwierdzonego
  źródła i powoduje zapis w `allowed_msr[].reason`.

## 9. Ryzyka, które zostają

| Ryzyko | Stan |
|---|---|
| Błąd walidacji w kodzie sterownika | **Nadal nieoceniony.** Kod jądra **istnieje** (`driver/ferrum_msr.c`), jest **skompilowany i podpisany testowo**, ale **nie został uruchomiony**. Klient jest testowany i **nie jest** granicą zaufania. |
| Kontekst DPC na stosie przy timeout | **Usunięte.** Odczyt nie używa już DPC — synchroniczne przypięcie wątku IOCTL, bez timeoutu i bez kontekstu o niepewnym czasie życia (`driver/ferrum_msr.c:20-46`). |
| Wyścig hotplug | **Zaimplementowany, nieprzetestowany.** Grupa/indeks sprawdzane `KeQueryActiveProcessorCountEx`, a po przypięciu wątku migracja potwierdzana `KeGetCurrentProcessorNumberEx`; bez potwierdzenia brak odczytu. Poprawność w jądrze niesprawdzona. |
| #GP przy `__readmsr` (np. pod Hyper-V) | **Zaimplementowane, nieprzetestowane.** `__try/__except` zamienia wyjątek na `FERRUM_READ_FAILED` (`driver/ferrum_msr.c:325-331`). |
| Odczyt MSR jako kanał boczny (side channel) | Odczyt `APERF`/`MPERF` nie ujawnia kluczy; allowlista zamyka najczęstsze rejestry wykrywające maszynę wirtualną i cechy procesora. Pełna ocena wymaga decyzji o zagrożeniach wielodzielnikowych. |
| Denial of service przez częste odczyty | Cykl 100 ms × 16 CPU × 2 rejestry = 320 odczytów/s. Sterownik powinien odrzucać żądania szybsze niż minimalny interwał; **nie zaimplementowane**. |
| Zgodność z zasadami podpisywania Microsoftu | Kod nie był oceniany przez HLK/attestation. Wymaga WDK i ścieżki Dev Center. |

## 10. Co weryfikuje kod dziś

Testy w `src/telemetry/driver_proto.zig`:

| Test | Co pilnuje |
|---|---|
| `zła sygnatura jest odrzucana przed wszystkim innym` | kolejność walidacji |
| `wersja spoza zakresu jest odrzucana` | handshake, wartości graniczne inclusive |
| `za mały struct_size jest błędem, większy to przyszłość` | zgodność wsteczna i ewolucja protokołu |
| `logical_cpu spoza zakresu jest odrzucone` | indeks CPU |
| `allowlist dopuszcza tylko potwierdzone rejestry` | brak rejestrów niepotwierdzonych |
| `w protokole nie ma ŻADNEGO zapisu MSR` | brak ścieżki zapisu, brak `FILE_WRITE_DATA`, brak `METHOD_NEITHER` |
| `odpowiedź musi mieścić się w buforze klienta` | długości buforów |
| `brak przepełnienia w walidacji rozmiarów` | brak mnożenia rozmiarów |
| `status mapuje się na błędy MSR` | spójność z `msr.Backend` |
| `nazwy statusów są stabilne` | kontrakt raportu |

Te testy **nie** zastępują testów w trybie jądra (Driver Verifier, HLK). Pilnują
logiki, którą sterownik ma powielić, i przypominają, by zrobić to świadomie.

### 10.1 Testy backendu user-mode (Etap 3B)

`src/telemetry/windows.zig` — **17 testów**, przechodzą **bez sterownika** dzięki
wstrzykniętej warstwie transportu. Pokrywają to, co przy realnym sterowniku
byłoby najtrudniejsze: rozróżnienie `NotInstalled` / `PermissionDenied`,
handshake wersji (starszy, nowszy, zła sygnatura), odrzucenie rejestru
spoza allowlisty **bez** round-tripu, mapowanie statusów sterownika na
`msr.MsrError`, idempotentność `close` i zamknięcie uchwytu przy nieudanym
handshake.

To **nie** jest weryfikacja sterownika. To weryfikacja warstwy, która ze
sterownikiem rozmawia — i która zrobiłaby błąd identycznie, gdyby sterownik
był poprawny lub nie.
