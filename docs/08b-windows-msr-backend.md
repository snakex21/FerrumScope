# 08b — Windows MSR backend (Etap 3B)

Status: **sterownik ZBUDOWANY i podpisany testowo, ale JESZCZE NIE ZAŁADOWANY.**

`zig build` PASS, `zig build test` **245 passed / 3 skipped (Linux runtime) / 0 failed**
(baza 220 → +25 testów).

Sterownik kompiluje się, linkuje i ma prawidłowy podpis Authenticode.
**Nie został załadowany** — BCD nietknięty, brak usługi, 0 sterowników `*ferrum*`.
Dlatego wszystko, co wymaga wykonania kodu w jądrze (realny odczyt MSR,
poprawność przełączenia procesora, zachowanie przy błędach), pozostaje
**niesprawdzone**. Szczegóły w §4.

> **Korekta poprzedniej wersji tego dokumentu.** Twierdziła, że „nie ma
> narzędzi do zbudowania sterownika" i „brak WDK/MSVC". To było **nieprawdziwe
> w dwóch punktach**: MSVC 19.44.35207 był zainstalowany od początku (tylko nie
> było go w PATH, a moje sprawdzenie użyło złej składni zmiennej), a WDK
> zainstalowało się poprawnie. Prawdziwym problemem była **integracja WDK z
> Visual Studio Build Tools** — opisana w §1.

## 0. CPU-Z: weryfikacja drogi uprzywilejowanej

Wniosek z Etapu 3A („CPU-Z czyta MSR bez własnego sterownika, więc nie trzeba
pisać własnego") był **fałszywy** i został obalony pomiarem na żywo.

**VERIFIED:**

| Obserwacja | Wartość |
|---|---|
| CPU-Z ma własny sterownik jądra | tak |
| Usługa | `cpuz165`, typ sterownik trybu jądra, start na żądanie |
| Ścieżka obrazu | `C:\ProgramData\CPUID Software\cpuz\<losowa nazwa>` |
| Rozszerzenie | **brak `.sys`** — sama losowa nazwa |
| Sterownik `Running` | 342 ms → 8694 ms (18 próbek, polling co 300 ms) |
| Usunięty | do 9179 ms, **przed** wyjściem procesu (~9857 ms) |
| Plik obrazu na dysku w trakcie pracy | **nie istnieje** |
| Urządzenia (napisy) | `\Device\cpuz165`, `\DosDevices\CPUZ165`, `\DosDevices\Global\CPUZ165` |
| Uprawnienie (napisy) | `@SeLoadDriverPrivilege` |
| Sprzątanie (napisy) | `-removeservice`, `KRemoveService=%d` |

**STRONG INFERENCE:** user-mode otwiera `\\.\CPUZ165`.
**UNKNOWN (celowo nie zbadane):** numery IOCTL, format żądań, obsługa
hybrydowych rdzeni.

Dwie obserwacje są niedoczywiste i potwierdzone pomiarem:

* **plik obrazu kasowany po załadowaniu** — katalog pusty przy każdej z 18
  próbek, mimo działającego sterownika. Plik znika, sterownik zostaje
  zmapowany; to utrudnianie wyciągnięcia binarki.
* **usunięcie przed wyjściem procesu** — lifecycle „załaduj → użyj → usuń",
  a nie „zostaw do restartu".

Model architektury: `CreateService(SERVICE_KERNEL_DRIVER, DEMAND_START)` →
`StartService` → otwarcie `\\.\<nazwa>` → `DeviceIoControl` → odczyt MSR na
docelowym CPU → zamknięcie → `DeleteService`. **Dokładnie tę ścieżkę
odtwarzamy własnym sterownikiem.**

Nie kopiowano kodu, protokołu ani implementacji CPU-Z. Pomiar dotyczył
wyłącznie obserwacji systemowych (SCM, dziennik zdarzeń, napisy, timeline).

Pełne zestawienie: `docs/research/cpuz-detection-model.md` §0.1.

## 1. Ustawienie środowiska (zmierzone, nie zgadnięte)

| Element | Stan | Wpływ |
|---|---|---|
| Uprzywilejowany proces | **ADMIN=True** | `CreateService`/`StartService` są możliwe |
| Secure Boot | **wyłączony** | przeszkoda zniesiona |
| `testsigning` | **nie ustawione jawnie** (domyślnie wyłączony) | **wymaga restartu** — nietknięte |
| MSVC | **14.44.35207 / kompilator 19.44.35227**, `Hostx64\x64` | był zainstalowany od początku |
| Windows SDK | **10.0.26100.0** (Include, Lib, bin) | był obecny |
| WDK | **10.0.26100.6584** (winget `Microsoft.WindowsWDK.10.0.26100`) | zainstalowany w tym etapie |
| `signtool.exe` | `Windows Kits\10\bin\10.0.26100.0\x64\` | był obecny |
| **Integracja WDK ↔ VS Build Tools** | **NIE DZIAŁA** — patrz niżej | wymusza budowę ręczną |
| HVCI / Memory Integrity | **nieaktywne** (brak klucza `HypervisorEnforcedCodeIntegrity`) | brak wymogu podpisu Microsoft dla HVCI |
| `HypervisorPresent` | True, `hypervisorlaunchtype Auto` | VBS nie wymusza podpisu |

**Dlaczego nie MSBuild.** `vs_installer.exe modify --add Microsoft.VisualStudio.Component.Windows.Driver.Kit`
kończy się **kodem 1**, a `.vcxproj` z `PlatformToolset=WindowsKernelModeDriver10.0`
pada **MSB8020** („nie można odnaleźć narzędzi kompilacji"). WDK z winget
dostarcza nagłówki `km` i biblioteki, ale nie rejestruje się w istniejącej
instancji Build Tools. Dlatego budowa idzie ręcznie: `vcvars64.bat` → `cl /kernel`
→ `link /driver`. Receptura w `driver/build_driver.bat`.

**Dwie niespodzianki tego toolchainu** (obie wykryte empirycznie):

1. `_AMD64_` **nie jest definiowane automatycznie**, choć kompilator celuje
   w x64 (`_WIN64` jest zdefiniowane). Bez `/D_AMD64_` `ntdef.h:187` kończy
   kompilację: `#error "No Target Architecture"`.
2. `/DNTDDI_VERSION=NTDDI_WIN10` **nie działa** — nazwa-symbol, który preprocesor
   widzi w `#if` jako `0`, więc bramka `>= NTDDI_WIN7` daje fałsz i API processor
   groups są niezadeklarowane. Potrzebna liczba: `0x0A000000`.

## 2. Co powstało i jest zweryfikowane

### Backend user-mode — `src/telemetry/windows.zig`

Implementuje wspólny `msr.Backend`, więc dekoder **nie wie**, że źródłem jest
sterownik Windows. Ten sam interfejs co backend sztuczny i replay.

**Transport jest wstrzykiwany.** To najważniejsza decyzja projektowa tego
etapu: logika mapowania błędów, handshake i lifecycle są właśnie tą częścią,
którą najłatwiej zepsuć i najtrudniej przetestować przy realnym sterowniku.
Testy używają transportu testowego, produkcja używa `DeviceIoControl`.

Gdyby logika siedziała wokół `DeviceIoControl`, jedynym testem byłby sterownik
na maszynie z WDK — czyli dokładnie wtedy, gdy testy są najdroższe i
najwolniejsze. **17 testów backendu przechodzi bez sterownika.**

| Obszar | Testy |
|---|---|
| `NotInstalled` ≠ `PermissionDenied` | brak sterownika / brak uprawnień / ścieżka nie istnieje |
| Handshake wersji | nowszy sterownik, starszy sterownik, zła sygnatura |
| Handshake pierwszeństwa | pierwsze zapytanie to `query_protocol` |
| Odczyt | dozwolony rejestr wraca jako `ok`, sprawdzamy CPU i indeks w żądaniu |
| Allowlist | rejestr spoza listy **nie wychodzi** do sterownika w ogóle |
| CPU offline | CPU spoza zakresu → `cpu_offline`, bez round-tripu |
| Mapowanie statusów | `cpu_offline` ze sterownika, błąd I/O, błąd walidacji |
| Lifecycle | `close` idempotentny, odczyt po zamknięciu, handshake-failure zamyka uchwyt |
| Interfejs | odczyt przez wspólne `api()` — ta sama ścieżka co `sensors` |

Rozróżnienie `NotInstalled` / `PermissionDenied` ma znaczenie praktyczne:
to **różne naprawy** — „zainstaluj sterownik" kontra „uruchom admina".

### Źródło sterownika — `driver/ferrum_msr.c` + `.inf`

Pełny sterownik WDM. **Skompilowany, zlinkowany i podpisany testowo**
(`driver/build/FerrumScopeMsr.sys`, 11 656 B), **ale nie załadowany** — brak
weryfikacji wykonaniem w jądrze. Zawiera:

* handshake protokołu, zapytanie o zdolności, odczyt allowlisty (`0xE7`/`0xE8`),
* odczyt na **wskazanym** procesorze **bez DPC**: wątek IOCTL (PASSIVE_LEVEL)
  przypinany `KeSetSystemGroupAffinityThread`, migracja **potwierdzana**
  `KeGetCurrentProcessorNumberEx`, potem `__readmsr`, zawsze
  `KeRevertToUserGroupAffinityThread`,
* obsługę **processor groups**: `logical_cpu = group * 64 + bit`;
  `KeSetSystemAffinityThread` zawiódłby cicho powyżej 64 CPU,
* walidację **po stronie jądra**, w kolejności magic → wersja → rozmiar → CPU
  → rejestr,
* wyścig hotplug: grupa/indeks sprawdzane `KeQueryActiveProcessorCountEx`,
  bez potwierdzonej migracji **nie ma odczytu**,
* `__readmsr` w `__try/__except` — #GP (np. pod Hyper-V) daje
  `FERRUM_READ_FAILED`, nie BSOD,
* `C_ASSERT` na rozmiary struktur i kody IOCTL względem `driver_proto.zig`.

**Brak zapisu MSR jest strukturalny:** nie ma operacji zapisu, nie ma funkcji,
nie ma ścieżki. Zgłoszony jako `STATUS_INVALID_DEVICE_REQUEST`.

### CLI

`sensors` próbuje teraz sterownika **w pierwszej kolejności**, a dopiero
potem przechodzi na dane syntetyczne. Odwrócenie tej kolejności sprawiłoby,
że maszyna ze sterownikiem pokazywałaby wartości testowe i wyglądała na
działający pomiar.

Zmierzone na tej maszynie:

```
$ ferrumscope sensors
Effective Clock   : unavailable (MSR access unavailable)     exit 0
$ ferrumscope cpu
Name        : AMD Ryzen 7 5800X3D 8-Core Processor           exit 0
Variant     : 3D V-Cache (źródło: brand_derived)
```

`cpu` działa normalnie, `sensors` podaje konkretną przyczynę — wymóg §17
spełniony i **zweryfikowany uruchomieniem**.

## 3. Punkt 0 §Etapu 3B — zawężanie codename

Bez zmian. `Vermeer / Milan-X` nadal szeroki, `refined_codename` pusty, bramka
provenance odrzuca obserwacyjne `source_type`.

## 4. Czego **nie** zweryfikowałem

* **Załadowania sterownika** — `.sys` jest zbudowany i podpisany testowo, ale
  `TESTSIGNING` nie jest włączony, usługa nie istnieje.
* **Realnego odczytu MSR z 5800X3D** — sterownik nie jest załadowany.
* **Per-logical-CPU execution na hardware** — poprawność przypięcia wątku
  (`KeSetSystemGroupAffinityThread` + potwierdzenie migracji)
  i processor groups **nie** została sprawdzona w jądrze. Kod jest napisany
  zgodnie z dokumentacją, ale „zgodny z dokumentacją" to nie „przetestowany".
* **Capture z prawdziwego sprzętu** i **replay tego capture** — etapy 13/14
  wymagają realnego backendu.
* **Porównania z CPU-Z** — etap 14.
* **Testu idle/load** — etap 15.
* **Wydajności realnego backendu** — etap 18. `runBenchReal` jest napisany
  i odrębny od `--bench` syntetycznego, ale **nigdy nie był uruchomiony**,
  bo nie ma backendu.
* **Walidacji bez BSOD** — etap 16 wymaga sterownika. Testy po stronie klienta
  istnieją i przechodzą, ale **klient nie jest granicą zaufania**.

## 5. Znane ryzyko w kodzie sterownika

**Usunięte.** Poprzednia rewizja czytała MSR w DPC z kontekstem na stosie
wątku IOCTL — przy timeout nie dało się go bezpiecznie zwolnić. Obecny kod
nie używa DPC: odczyt jest synchroniczny w wątku IOCTL po przypięciu i
potwierdzeniu procesora (`driver/ferrum_msr.c:20-46`). Pozostałe ryzyko to
zachowanie `__readmsr` pod Hyper-V — złagodzone przez `__try/__except`,
ale **nieprzetestowane** w jądrze.

## 6. Blokada: co trzeba zrobić, żeby domknąć Etap 3B

Ponumerowane kroki, każdy z wpływem i sposobem powrotu.

### Krok A — zainstalować WDK (bez restartu, odwracalne)

**Co:** Visual Studio Build Tools + „Windows Driver Kit".
**Dlaczego:** bez `cl.exe`, `wdm.h` i `ntoskrnl.lib` sterownika nie da się zbudować.
**Stan: WYKONANE.** WDK 10.0.26100 + MSVC 19.44; budowa ręczna przez
`driver/build_driver.bat` (MSBuild+WDK pada na MSB8020, patrz §1).
**Wpływ:** dodaje narzędzia do systemu. Nie zmienia polityki bezpieczeństwa.
**Powrót:** panel sterowania → Odinstaluj programy.

### Krok B — włączyć tryb testowy (**WYMAGA RESTARTU**)

**Co:**
```
bcdedit /set {current} testsigning on
```
**Dlaczego:** na x64 Windows 10/11 sterownik podpisany wyłącznie certyfikatem
testowym wczytuje się **tylko** w trybie testowym. Bez tego kodu integracji
odmówią załadowania.
**Wpływ:** Secure Boot jest **już wyłączony** na tej maszynie, więc tryb testowy
jest tu spójny z istniejącą konfiguracją. Zmiana dotyczy wyłącznie
podpisywania sterowników.
**Powrót:**
```
bcdedit /set {current} testsigning off
```
i restart. Stan wyjściowy jest znany: `testsigning` nie było ustawione jawnie.

> **Nie wykonuję tego samodzielnie.** Brief jest jednoznaczny: zatrzymać się
> przed zmianą wymagającą restartu. Decyzja należy do właściciela maszyny.
> Powyżej podaję dokładne polecenie i sposób powrotu — wystarczy wykonać je
> ręcznie i zrestartować.

### Krok C — zbudować i podpisać testowo

**Co:**
```
cl /kernel /W4 /O2 /GS /D_KERNEL_MODE ferrum_msr.c /link /subsystem:native /entry:DriverEntry
makecert /n "FerrumScope MSR DEV" /r /h0 /e /sk /ss PrivateCertStore
signtool sign /v /fd SHA256 /a /n "FerrumScope MSR DEV" /s My /t ... ferrum_msr.sys
```
**Dlaczego:** sterownik bez podpisu nie wczyta się w trybie testowym.
**Wpływ:** lokalny certyfikat, brak wpływu na system poza katalogiem
certyfikatów użytkownika.
**Powrót:** usunięcie pliku i certyfikatu.
**Stan: WYKONANE.** `driver/build_driver.bat` + `driver/sign_test.ps1`
(certyfikat `CN=FerrumScope MSR DEV`, `CurrentUser\My`). Paczka INF:
`driver/make_cat.bat` → `driver/package/` z `ferrumscopemsr.cat`
(Inf2Cat: 0 błędów, 0 ostrzeżeń; katalog podpisany tym samym certyfikatem).
`signtool verify /pa` zgłasza niezaufany root — **oczekiwane**, certyfikat
testowy nie jest w Trusted Root i nie zostanie tam dodany bez zgody.

### Krok D — instalacja i test

**Co:** `sc.exe create FerrumScopeMsr type= kernel start= demand binPath= C:\...\FerrumScopeMsr.sys`,
potem `sc.exe start FerrumScopeMsr` i `ferrumscope sensors`.
(W PowerShell `sc` to alias `Set-Content` — trzeba pisać `sc.exe`.)
**Powrót:** `sc.exe stop FerrumScopeMsr`, `sc.exe delete FerrumScopeMsr`.

Po krokach A–D domknięte stają się punkty 4, 8, 10, 11, 12, 13, 14, 17 i 18.
Kroki A i C są wykonane; brakuje kroku B (`TESTSIGNING` + restart) i D.

## 7. Podpisywanie — rozdzielone ścieżki

**Development.** Certyfikat self-signed (makecert / New-SelfSignedCertificate),
podpis `signtool`, `testsigning on` + restart. Sterownik wczytuje się w trybie
testowym, Windows pokazuje ostrzeżenie o niezaufanym sterowniku. **Wyłącznie
na maszynie deweloperskiej**, nie na maszynie użytkownika.

**Production.** Microsoft Partner Center + Hardware Dev Center, ankieta
deklaracyjna, HLK (Windows Hardware Lab Kit), podpis przez Microsoft
(attestation lub WHQL), certyfikat partnerski, podpis produkcyjny `.sys`.

**Czego nie twierdzę:** samo posiadanie certyfikatu EV **nie** daje
produkcyjnego podpisu dla sterownika. EV dotyczy podpisywania **wykonawczego**
(`signtool sign`), nie obrazu jądra. Obraz `.sys` podpisuje się certyfikatem
wydanym przez Microsoft dla konkretnej organizacji, po pozytywnym HLK.
Certyfikat EV bez ścieżki Microsoft **nie** wystarczy i nie jest substytutem.
Mechanizmów Code Integrity nie omija się żadnym sposobem — sterownik
podpisany inaczej po prostu się nie wczyta.

## 8. Linux

`UNVERIFIED_RUNTIME` — bez zmian. Brak jakiegokolwiek testu w tym etapie.
Linux pozostaje osobnym backendem i nie blokuje 3B.

## 9. §19 — kandydaci na Etap 3C (research, bez implementacji)

**Nic z tej tabeli nie trafiło do allowlisty.** To tabela kandydatów do
zbadania, nie lista do użycia.

| Rejestr | Znaczenie | Dokumentacja | Zakres rodzinny | Pewność | Kandydat 3C? |
|---|---|---|---|---|---|
| `0xC0010064` PSTATE_CURRENT | P-state / FID / VID | AMD APM Vol. 3, PPR per generacja | Zen 1–3 | **UNVERIFIED** — CPU-Z czyta (linia `PStateReg` w raporcie, VERIFIED), ale **kodowanie** FID/VID niepotwierdzone | tak, po zdobyciu PPR |
| `0xC0010014` MSR_AMD64_TEMP | temperatura rdzenia | AMD PPR per generacja | Zen 1–3 (inny układ w Zen 4/5) | **UNVERIFIED** — układ bitów i czynnik przeliczenia zależą od generacji | tak |
| `0xC0010293` TSC_MSx | licznik energii | AMD PPR | Zen 1–3 | **UNVERIFIED** | tak |
| `0xC0010294` TSC_MSx | status energii | AMD PPR | Zen 1–3 | **UNVERIFIED** | tak |
| `0xC0010064` P-state def. `0xC0010061` | P-state base/freq | AMD APM | Zen 1–3 | **UNVERIFIED** | tak |
| `0x610` PACKAGE_THERM_STATUS | status termiczny | Intel SDM Vol. 4 | Skylake+ | **UNVERIFIED** dla tej konfiguracji | tak (osobno) |

Wszystkie mają **UNVERIFIED**, bo dysponujemy publiczną dokumentacją
i raportem CPU-Z, a nie **PPR** dla konkretnej generacji. Dodanie któregokolwiek
do allowlisty wymagałoby potwierdzenia układu bitów w źródle producenta dla
`Family 25 / Model 33`, a nie przeniesienia wartości z innej generacji.
Zakres `0x20..0x3F` obejmuje AM4 **i** SP3, gdzie układy się różnią — to
dokładnie ten sam problem, który w Etapie 3B ograniczył `socket_name`
do `0x21`.

## 10. Zmiana w `docs/SECURITY-MODEL.md`

Sekcja 2 dostała odniesienie do realnego kodu sterownika i jawne
wyodrębnienie dwóch faktów: walidacja jest teraz **zaimplementowana po
stronie jądra** (nie tylko w kliencie), a testy klienta **nie zastępują**
testów w trybie jądra. Sekcja 9 (ryzyka) dostała pozycję o braku testów
pod obciążeniem i o opisanym ograniczeniu DPC.

## 11. Punkt 0 Etapu 3B

Nietknięty — patrz §3.
