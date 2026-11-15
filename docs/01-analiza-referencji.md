# FerrumScope — analiza referencyjna CPU-Z i GPU-Z

Status: **analiza zakończona, wnioski zweryfikowane na binariach.**
Narzędzia: `tools/refext/pe_scan.py`, `tools/refext/harvest_ref.py`.
Surowe zrzuty: `reference/dumps/{cpuz,gpuz}.json` (kwarantanna — patrz `reference/README.md`).

Wszystkie liczby poniżej pochodzą z realnego pomiaru plików w `do referencji/`,
nie z domysłów. Tam, gdzie wniosek jest interpretacją, jest to oznaczone.

---

## 0. Szybkie fakty o badanych plikach

| | CPU-Z (`cpuz_x64.exe`) | GPU-Z (`GPU-Z.2.71.0.exe`) |
|---|---|---|
| Rozmiar | 7 447 032 B | 12 428 576 B |
| Format | PE32+ / AMD64 | PE32 / i386 |
| Sekcje | `.text .rdata .data .pdata .rsrc` | `UPX0 UPX1 .rsrc` |
| Pakowanie | **brak** | **UPX 5.x, 23,12 % → 53 758 240 B** |
| Sterowniki w środku | 3 (i386, AMD64, IA64) | brak (payload to narzędzia NVIDIA) |
| Import m.in. | `dbgeng.dll`, `DeviceIoControl`, `IPHLPAPI`, `PSAPI` | `SetupDi*` (106 ciągów), `CM_Get_Device_IDW`, `PSAPI`, `WININET` |

Reprezentatywne metadane: CPU-Z `ProductName = "CPU-Z Application"`, `OriginalFilename = cpuz.exe`,
`VersionInfo` celowo zniekształcone (`3, 0, 1, 0`) — to obfuskacja, nie błąd.
GPU-Z `ProductVersion = 2.71.0.0`, `LegalCopyright = (c) 2007-2026 TechPowerUp`.

---

## 1. Co CPU-Z/GPU-Z czytają bezpośrednio ze sprzętu

**CPU-Z.** Import `dbgeng.dll` + trzy wbudowane sterowniki `cpuz.sys` („CPUID service",
Copyright (C) 2026 CPUID). Sterowniki importują z `ntoskrnl.exe`:
`IoCreateDevice`, `IoCreateSymbolicLink`, `IofCompleteRequest`, `MmMapIoSpace`,
`MmUnmapIoSpace`, `PsGetVersion`, `KeBugCheckEx` — oraz z `HAL.dll`:
`READ_PORT_USHORT/ULONG/UCHAR`, `WRITE_PORT_UCHAR/USHORT/ULONG`,
`KeStallExecutionProcessor`, `KeQueryPerformanceCounter`.

Wniosek (pewny): sterownik **nie zawiera logiki identyfikacyjnej**. Udostępnia
prymitywy — port I/O, mapowany I/O, operacje z IRP, dostęp do przestrzeni
przełącznika trybu (MSR) — a cała interpretacja siedzi w user-space.

### 1.1 Rola `dbgeng.dll` — weryfikacja i korekta wcześniejszego wniosek

Pierwsza wersja tego raportu stwierdziła, że `dbgeng.dll` służy jako „mechanizm
komunikacji ze sterownikiem". **Wniosek był zbyt mocny i został skorygowany.**
Pomiar importów i ciągów daje obraz inny:

| Fact (zmierzony) | Wartość |
|---|---|
| Funkcje importowane z `dbgeng.dll` | **dokładnie jedna: `DebugCreate`** |
| `NtLoadDriver` / `ZwLoadDriver` | 0 wystąpień |
| `DriverPackageInstall` / `DriverPackageAdd` | 0 wystąpień |
| Ścieżki `\\.\`, `\\Device\`, `\\DosDevices\` | 0 wystąpień |
| `DeviceIoControl` (KERNEL32) | **jest** — to IPC do sterownika |
| `LoadLibraryExW` + `GetSystemDirectoryW` | są — dynamiczne ładowanie bibliotek |
| Ładowanie sterownika | `SeLoadDriverPrivilege`, `CPUID\...`, `cpuz165`, `_arm64.sys` |
| Komunikaty błędów | `CPUID init driver error %u (0x%X)`, `CPUID lock driver error %u (0x%X)` |
| Sprawdzanie wersji online | `cpuz=%d.%d.%d.%d`, `InternetOpenUrlW` |

`DebugCreate` należy do interfejsu **klienta** debuggera (`IDebugClient`) — służy do
łączenia się z *procesem*, a nie do komunikacji ze sterownikiem. Z samego faktu
importu nie wynika żadne konkretne zastosowanie: biblioteka jest ładowana dynamicznie,
więc jej użycie widać dopiero w czasie działania.

**Ustalenie, które pozostaje w mocy:** CPU-Z komunikuje się ze sterownikiem przez
`DeviceIoControl`, a sterownik ładuje standardowym mechanizmem `SE_LOAD_DRIVER_PRIVILEGE`
(rejestr usług, klasa `CPUID`). `dbgeng.dll` pozostaje **czynnikiem niejednoznacznym**
i nie jest elementem architektury IPC.

**Ograniczenie tej analizy:** nazwa urządzenia sterownika nie występuje w obrazie
ani jako `\\.\X`, ani jako `\\Device\X` — jest budowana w runtime lub trzymana
w postaci zakodowanej. Analiza statyczna nie pozwala odtworzyć identyfikatora
urządzenia ani kodów IOCTL; do tego potrzebna jest analiza dynamiczna.

**Konsekwencja dla FerrumScope:** nic. Nasz model (sterownik wystawia prymitywy,
user-space interpretuje) pozostaje prawidłowy — opiera się na jednoznacznej tabeli
importów sterownika. Odrzucamy jedynie uzasadnienie „bo używa dbgeng", które
było spekulacją.

**GPU-Z.** Dostęp do sprzętu idzie trzema drogami:
1. **Enumerator systemowy Win32** — `SetupDiCreateDeviceInfoList`, `SetupDiGetClassDevsExW`,
   `SetupDiGetDeviceInstanceIdW`, `CM_Get_Device_IDW`, `CM_Get_Parent` (106 ciągów z „SetupDi").
2. **Ścieżki urządzeń** — `\\.\DISPLAY`, `\\.\PhysicalDrive%d`, oraz potok
   `\\.\pipe\GPUZQueryExternal_%lu_%d_%s` (współdzielenie sensorów między instancjami).
3. **Biblioteki producentów** — `ADL_Display_WriteAndReadI2C`, `Global\Access_ATI_I2C`,
   `NVAPI`, `IGCL`, `OCL` (AMD OpenCL). Czyli dostęp do rejestrów GPU przez API ADL/NVAPI,
   a nie przez własny sterownik.

Format-string potwierdzający krotkę surowych identyfikatorów:

```
Found NVIDIA device: 0x%04X 0x%04X rev 0x%X bus 0x%X dev 0x%X fn 0x%X
```

czyli `(vendor_id, device_id, revision, bus, device, function)` — dokładnie ten sam
zestaw, który planujemy trzymać w `RawPciDevice`.

---

## 2. Co biorą z systemu (nie ze sprzętu)

- `PSAPI.EnumDeviceDrivers`, `GetDeviceDriverFileNameW`, `GetModuleBaseNameW` — wersje
  i nazwy sterowników GPU (stan „sterownik: 32.0.15.7688”).
- `IPHLPAPI`, `GetAdaptersInfo`-rodzina — MAC, IP, typ połączenia (widać `NetWkstaGetInfo`).
- `SetupDi*` — klasa urządzenia, instance ID, parent/child, lokalizacja (PCI bus/dev/func).
- `WININET` (GPU-Z) — aktualizacja bazy online; **to świadomy wybór, my go nie kopiujemy**
  (patrz §10).
- `smbios` (ciąg w GPU-Z) — odczyt tabel SMBIOS przez WMI/aparaturę.
- `USER32/VERSION.dll` — wersja systemu, DPI, motyw.

**CPU-Z pobiera też nazwę procesu/systemu z konfiguracji**, stąd wniosek: oba
narzędzia mają wyraźny podział „sprzęt" vs „system". To zgadza się z naszym założeniem.

---

## 3. Co pochodzi z tabel / hardware database

Rozdzielenie jest **całkowite i widoczne w pliku**:

**CPU-Z — baza w `.data`/`.rdata` jako zwykły tekst, bez kompresji.** Dwa mechanizmy obok siebie:
- jawne nazwy: `"Intel Core i5 5300U"`, `"Intel(R) Core(TM) i9-14900K (24C/32T)"` (UTF-16),
  `"Ryzen 9 5950X"` (UTF-16), `"AMD Ryzen 9"`;
- generowanie nazw z wzorców: `"AMD Sempron II M1%02d"`, `"AMD Athlon II M3%02d"`.

Drugi mechanizm jest istotny architektonicznie: przy **tysiącach** SKU nazwy są
 generowane z `(series, stepping)`, a nie wpisywane ręcznie. To kompresja informacji,
i dokładnie dlatego ich plik CPU ma tylko ~7 MB mimo dużej bazy.

**GPU-Z — baza jest skompresowana, częściowo zaszyfrowana.** Po rozpakowaniu UPX
w zasobach `RT_RCDATA` siedzą cztery rodzaje blobów:

| Zasób | Rozmiar | Nagłówek | Co to jest |
|---|---|---|---|
| 193, 194, 201, 202, 216, 226 | 1,7 MB – 23,5 MB | `4D5A` (MZ) | wbudowane PE: **NVIDIA Firmware Update Utility 5.867.0** (23,5 MB i 19,5 MB), `SETUPAPI.DLL` (2 kopie) |
| 98, 99 | 493 KB, 654 KB | `3c2d8aee…` | blob skompresowany |
| 140, 141, 241, 243 | 52–98 KB | `2f01c393…` | blob skompresowany |

Próba dekompresji (zlib/gzip/deflate/lzma-alone/lzma-raw z lc/lp/pb w 0..4, bz2, xz,
offsety 0..40) **nie daje wyniku** — to własny format, prawdopodobnie z szyfrowaniem.

> **Status tych blobów: CANDIDATE / PROBABLE — nie potwierdzona baza danych.**
> Nie ustalono ich zawartości ani struktury. Wiemy tylko, że (a) są skompresowane
> (lub zakodowane) niestandardowym algorytmem, (b) towarzyszą programowi, (c) nie są
> w PE. Nazywanie ich „bazą GPU" byłoby wnioskiem wyprzedzającym dowody. Traktujemy
> je jako **kandydatów na dane aplikacji** (baza identyfikatorów, definicje sensorów
> lub zasoby pomocnicze) i nie opieramy na tym żadnej decyzji projektowej.

Gdyby ten raport twierdził „baza GPU-Z jest w zasobach RCDATA", wyciągnęlibyśmy
z tego wniosek o podatności ich formatu, którego **nie** zweryfikowaliśmy.
Ta ostrożność jest tu celowa: to jedyna część analizy GPU-Z, która pozostaje
nierozstrzygnięta, i nie wolno jej przedstawiać jako ustalonej.

Wniosek dla nas: **nie da się legalnie ani technicznie „wziąć ich bazy"**. Nie próbujemy —
projektujemy własną, własnymi źródłami (§10).

---

## 4. Family / model / stepping, revision, codename

**CPU-Z** — rozwiązuje to w kodzie, a nie w bazie, i robi to hierarchicznie:
`extended family` / `family` (CPUID leaf 1, EAX bits 27:20 i 11:8) → `extended model`
(bits 19:16) / `model` (bits 7:4) → `stepping` (bits 3:0). Dopiero **do pary (family, model)
przypisana jest nazwa marketingowa**; stepping służy do wersji/rewizji, nie do nazwy.
Bezpośredni dowód: przy 225 trafieniach `cpu.marketing` i 471 `cpu.format` w jednym obrazie
liczą się zarówno `"Intel Core i5 5300U"`, jak i wzorzec `"AMD Sempron II M1%02d"` —
czyli nazwa jest **produktem wzorca + danych CPUID**, a nie wpisem w bazie.

**GPU-Z** — dla GPU idzie *odwrotnie*: najpierw surowe ID, potem dopiero nazwa.
Kod chipów (nazwy architekturalne) trzymane są osobno, w UTF-16, w kroku 16 B:
`Navi 48`, `Navi 31`, `Navi 32`, `Navi 33`, `AD102`, `GTX 680`, `GTX 780 Ti`, `NVAPI`.

**Kluczowe odkrycie:** w całym rozpakowanym obrazie GPU-Z **nie ma pełnych nazw
marketingowych**. Licznik: `Radeon RX 6900` → 0 trafień, `GeForce RTX 4090` → 0,
`RX 7900` → 0, `Arc A770` → 0. Są tylko krótkie formy (`GTX 680`, `4090` ×8 w UTF-16).
To dowodzi, że GPU-Z **składa nazwę z szablonu** (prefiks producenta + rodzina + model
+ sufiks) i dopiero potem rozwiązuje nazwę karty z podsystemu. Nasza baza musi umieć
to samo, ale jawnie i czytelnie — z rozdzieleniem `chip` (AD102) / `board`
(RTX 4090 Founders Edition) / `sku` (partner).

---

## 5. Identyfikacja GPU i subsystem/device IDs

Potwierdzone w GPU-Z: krotka `(vendor, device, revision, bus, dev, fn)` z format-stringu,
uzupełniona o `\\.\DISPLAY`, `SetupDiGetDeviceInstanceIdW` i biblioteki producentów.
Subsystem ID służy do rozróżnienia kart partnerskich tego samego rdzenia — stąd np.
`0x1002:0x73AF` (Radeon RX 6900 XT) ma w rejestrze kilkanaście różnych podsystemów
(PowerColor, XFX, Sapphire, ASRock…). Dokładnie ten sam problem mamy w `db/source/pci/`.

**Wniosek operacyjny:** `device_id` identyfikuje **chip**, `subsys_id` identyfikuje
**konkretną kartę partnerską**. FerrumScope musi trzymać obie warstwy osobno.

---

## 6. Jak organizują wsparcie dla ogromnej liczby generacji

Analyzing 3 techniques, from cheapest to most expensive:

1. **Generowanie nazw z wzorców** (CPU-Z) — skaluje się na tysiące SKU przy kilkuset
   wpisach wzorców. Koszt: pomyłka w wzorcu = pomyłka w całej serii.
2. **Tabela identyfikatorów + składanie nazwy** (GPU-Z) — chip po `device_id`,
   wygląd po `subsys_id`, reszta generowana.
3. **Skompresowane/zaszyfrowane zasoby** (GPU-Z) — baza nie jest czytelna ani edytowalna
   z zewnątrz; wymaga narzędzia producenta do aktualizacji.

**Co bierzemy, a co odrzucamy:** bierzemy (1) i (2), bo dają czytelną bazę i testy
regresyjne. Odrzucamy (3) — nie jest testowalne, nie jest diffowalne, utrudnia
współtworzenie i audit licencyjny.

---

## 7. Fallback dla nieznanego sprzętu

CPU-Z: wzorzec `%02d` dowodzi akceptowania *częściowego* dopasowania — dopasowanie po
`model` bez `stepping` daje nazwę serii, dopiero potem dopisywana jest rewizja.
To jest degradacja „najlepszego dopasowania", nie błąd.

GPU-Z: przy nieznanym `device_id` nie ma żadnego wpisu (0 pełnych nazw = wszystko
generowane), więc **zawsze** istnieje wynik — zbudowany, nie odczytany.

**Lekcja dla naszego API:** `CpuInfo.name` nigdy nie może być `null`. Musi istnieć
jawny stan `MatchQuality { exact, family, family_model, unknown }`, żeby GUI mogło
pokazać „nieznany układ, zgłoś dane" zamiast pustego pola.

---

## 8. Rozdzielenie raw detection / presentation / database

Widać w obu, ale w różnym stopniu:

- **CPU-Z**: wyraźne rozdzielenie sterownik (prymitywy) / user-space (interpretacja) /
  baza (tekst w `.data`). Rozdzielenie *logiczne* jest czyste, choć baza siedzi
  w tym samym pliku co kod.
- **GPU-Z**: rozdzielenie jest **fizyczne** — nazwy sensorów są w `.data` jako UTF-16,
  baza w zasobach RCDATA, kod w `.text`, payload w RCDATA jako osobne PE.

FerrumScope idzie dalej: rozdzielenie na **warstwy procesów**, nie tylko sekcji
(patrz `docs/02-architektura.md`).

---

## 9. Czas startu i kolejność probing

Nie mierzyłem dynamicznie (uruchomienie tych binariów wymagałoby GUI i interakcji),
więc wniosek opieram na strukturze statycznej i oznaczam go jako **interpretację**:

- CPU-Z i GPU-Z są aplikacjami GUI z rozbudowanym UI, więc mają cięższy model
  startu niż ferrumscope CLI; to nie jest porównanie uczciwe.
- Ich kolejność wynika z zależności, nie z harmonogramu: `SetupDi` → szukaj GPU →
  `\\.\DISPLAY` → otwórz adapter → odczytaj ID → dopiero potem buduj widok.
- GPU-Z dodatkowo wykonuje **sprawdzenie aktualizacji przez WININET**, co wprowadza
  oczekiwanie na sieć.

**Nasza decyzja:** FerrumScope startuje od CPUID (koszt: mikrosekundy), a wszystko inne
jest zależne od tego, czy CPUID w ogóle zadziałało. GPU-Z tego nie może zrobić,
bo jego punktem wejścia jest enumeracja urządzeń PCI.

---

## 10. Co bierzemy do FerrumScope (bez kopiowania kodu i danych)

| Z obserwacji | Decyzja w FerrumScope |
|---|---|
| Sterownik = tylko prymitywy | **Przyjmujemy.** `platform/windows/driver`: `MmMapIoSpace`, port I/O, MSR, PCI config. Zero logiki identyfikacyjnej. |
| `SetupDi*` jako źródło topologii PCI | **Przyjmujemy** jako jeden z backendów PCI config. |
| Sterownik ładowany przez `SeLoadDriverPrivilege` (klasa `CPUID`, wariant ARM64) | **Przyjmujemy** jako potwierdzony wzorzec dla naszego sterownika Windows. |
| Krotka `(vendor, device, rev, bus, dev, fn)` | **Przyjmujemy** jako rdzeń `RawPciDevice`. |
| Rozdzielenie chip / subsystem | **Przyjmujemy** jako osobne warstwy w bazie. |
| Generowanie nazw ze wzorców | **Przyjmujemy**, ale z jawną kontrolą jakości: wzorzec musi mieć test. |
| Skompresowana/zaszyfrowana baza GPU-Z | **Odrzucamy.** Nieosiągalna, nieczytelna, nieaudytowalna. |
| Baza CPU-Z w `.data` jako tekst | **Odrzucamy.** |
| Aktualizacja bazy przez WININET | **Odrzucamy.** FerrumScope ma być offline-first; opcjonalny update to osobny, jawny tryb. |
| `dbgeng.dll` jako mechanizm komunikacji ze sterownikiem | **Odrzucamy — wniosek był zbyt mocny.** Zmierzono: 1 import (`DebugCreate`), zero `Nt/ZwLoadDriver`, zero ścieżek `\\.\`. IPC idzie przez `DeviceIoControl` + `SeLoadDriverPrivilege`. Zob. §1.1. |
| Bloby RCDATA w GPU-Z jako źródło danych o GPU | **Odrzucamy.** Zawartość nierozpoznana, status CANDIDATE (§3). |

### Zdobywanie danych o sprzęcie, gdy nie masz sprzętu pod ręką

To był główny problem praktyczny. Rozwiązanie ma trzy niezależne, legalne źródła:

1. **Publiczny rejestr PCI ID** — `https://pci-ids.ucw.cz/` (licencja BSD-like, atrybucja).
   Zaimplementowane: `tools/hwdb/pciids_import.py` → `db/source/pci/pci.ids.toml`.
   Stan faktyczny po uruchomieniu: **858 vendorów, 9915 urządzeń, 0 błędów**,
   377 rozstrzygniętych duplikatów, rewizja `2026-09-25 03:15:01`, sha256 w pliku.
   Zawiera realne wpisy: `0x10DE:0x2684 → "AD102 [GeForce RTX 4090]"`,
   `0x1002:0x73AF → "Navi 21 [Radeon RX 6900 XT]"`,
   `0x1002:0x744C → "Navi 31 [Radeon RX 7900 XT/7900 XTX/7900 GRE/7900M]"`,
   plus tabele podsystemów dla kart partnerskich.
2. **Dokumentacja producentów** — AMD/Intel/NVIDIA publikują tabele SKU i steppingów.
3. **Capture'y `.fcap` od użytkowników** — surowe dane, bez wniosków, bez PII.

Czego **nie robimy**: nie kopiujemy nazw ani tabel z CPU-Z/GPU-Z do `db/source/`.
`tools/refext/harvest_ref.py` zapisuje je do `reference/dumps/` z jawną pieczęcią
„QUARANTINE — NIE do dystrybucji". Służą do walidacji naszych testów, nie do budowy produktu.

---

## 11. Znalezione błędy w naszych własnych narzędziach (dla porządku)

Dwie realne wady wykryte podczas tej analizy, obie naprawione — obie pokazywałyby
„pustą bazę" zamiast błędu:

1. `harvest_ref.py` nie znajdował UPX-a (`tools/refext/bin/upx-5.2.1-win64/upx.exe`
   vs szukane `tools/refext/bin/upx.exe`) → analiza pakowanej binarki bez ostrzeżenia
   o niepełności. Naprawione przez `find_upx()`.
2. `pciids_import.py` używał `str.isdigit()` do sprawdzania VID/DID zapisanych
   szesnastkowo. Literalnie gubił **1660 vendorów**, w tym całą NVIDIA 0x10DE,
   bo `isdigit("10de")` to `False`. Intel/AMD przechodziły, bo ich ID to same cyfry —
   błąd wyglądałby jak „NVIDIA nie ma GPU w bazie". Naprawione na `is_hex()`.

To są dokładnie te klasy błędów, które DLACZEGO walidacja źródłowej bazy jest obowiązkowa,
a nie opcjonalna: **ciche pominięcie połowy danych wygląda jak „nie ma takiego sprzętu"**.
