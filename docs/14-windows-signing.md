# Podpisywanie sterownika Windows — ścieżki

Status: **sterownik zbudowany i podpisany testowo; nie zainstalowany.**
**Nie zmieniono konfiguracji systemu** — w szczególności nie ruszono `TESTSIGNING`.

Dokument nie jest instrukcją „włącz to, żeby zadziałało". Jest opisem dwóch
osobnych ścieżek, z których tylko jedna prowadzi do sterownika, który warto
wysłać użytkownikom.

## 0. Stan faktyczny

| Element | Stan |
|---|---|
| Kod sterownika (WDM) | istnieje: `driver/ferrum_msr.c` |
| Kontrakt protokołu | istnieje, przetestowany: `src/telemetry/driver_proto.zig` |
| Plik `.sys` | `driver/build/FerrumScopeMsr.sys` (`driver/build_driver.bat`) |
| Podpis testowy | `.sys` + `driver/package/ferrumscopemsr.cat`, `CN=FerrumScope MSR DEV` (`driver/sign_test.ps1`, `driver/make_cat.bat`) |
| Instalacja | nie wykonano |
| Zmiana `TESTSIGNING` / trybu bezpiecznego rozruchu | **nie wykonano** |

Kontrakt i model bezpieczeństwa są napisane **przed** kodem, nie po. Sterownik
będzie miał nie więcej możliwości, niż wynika z `allowed_msr` i z testów, które
już istnieją.

## 1. Ścieżka deweloperska (test signing)

Dla pracy własnej i na maszynach deweloperskich. **Nie nadaje się do
dystrybucji.**

### Wymagania

* Windows 10/11 x64, tryb **bezpiecznego rozruchu** może być wyłączony **tylko**
  na maszynie deweloperskiej,
* certyfikat testowy (self-signed) wygenerowany lokalnie,
* `TESTSIGNING` włączony **na maszynie deweloperskiej**.

### Krok po kroku

1. Zbudować sterownik w konfiguracji Release z podpisem testowym.
2. Podpisać `.sys` certyfikatem testowym (`signtool sign /fd SHA256`).
3. Zainstalować: `sc create`, `sc start`, `pnputil` dla INF.
4. Klient otwiera `\\.\FerrumScopeMsr` i wykonuje `IOCTL_QUERY_PROTOCOL`.

### Czego ta ścieżka **nie** daje

* sterownik jest niezaufany dla systemu — brak ochrony przed złośliwym kodem,
* użytkownik widzi monit o nieznanym sterowniku przy każdym bocie,
* **nie wolno** tego używać na maszynie użytkownika końcowego.

### Decyzja o systemie

Włączenie `TESTSIGNING` albo wyłączenie Secure Boot to **zmiana ustawień
zabezpieczeń maszyny**. Nie wykonujemy jej automatycznie ani nie proponujemy
użytkownikowi „dla wygody". To decyzja właściciela maszyny, z pełną świadomością
konsekwencji, a program nie ma prawa jej podejmować za niego.

Jeśli kiedyś potrzebne będzie lokalne testowanie sterownika, proponujemy
**maszynę wirtualną poświęconą testom**, a nie zmianę konfiguracji maszyny
roboczej.

## 2. Ścieżka produkcyjna (Microsoft Hardware Dev Center)

Dla sterownika, który ma trafić do użytkowników.

### Wymagania

* konto w **Microsoft Partner Center** i akceptacja programu partnerskiego,
* sterownik spełniający wymagania HLK (Windows Hardware Lab Kit),
* certyfikat podpisywania kodem (WHQL / attestation) wydany przez Microsoft,
* pakiet `.cab` z INF, SYS i podpisem.

### Ścieżka

1. Wypełnić ankietę deklaracyjną w Dev Center (nazwa, funkcja, zakres).
2. Uruchomić **HLK** na Windows 10/11 w wersjach objętych testem.
3. Przesłać logi do Microsoft, jeśli HLK zgłosi błędy.
4. Otrzymać podpisany pakiet i certyfikat.
5. Podpisać produkcyjny `.sys` certyfikatem partnerskim.
6. Przesłać do dystrybucji.

### Ocena zgodności dla naszego zakresu

Nasz sterownik **tylko czyta** dwa rejestry MSR i odpowiada na trzy IOCTL.
Nie ma: zapisu rejestrów, dostępu do pamięci jądra, MMIO, port I/O, DMA
ani obsługi plug-and-play. To najprostszy możliwy zakres i **powinien** przejść
weryfikację bez zastrzeżeń.

HLK zweryfikuje m.in.:

* poprawność obsługi `IRP_MJ_DEVICE_CONTROL` i `METHOD_BUFFERED`,
* walidację buforów wejściowych i wyjściowych,
* zachowanie przy zamkniętym uchwytem i anulowaniu I/O,
* brak wycieków zasobów przy kolejnych żądaniach,
* poprawność przy przejściu CPU ze stanu online do offline.

To są dokładnie te przypadki, które opisuje `docs/SECURITY-MODEL.md`. Sterownik
zgodny z tym dokumentem powinien przejść bez poprawek; sterownik niezgodny —
nie powinien być podpisywany.

## 3. Czego **nie** zrobiliśmy i dlaczego

| Decyzja | Powód |
|---|---|
| Nie napisaliśmy kodu sterownika | Kontrakt i testy dają ochronę wcześniej niż kod w trybie jądra. Sterownik pisany „na oko", potem testowany, to najdroższa kolejność. |
| Nie podpisaliśmy niczego | Nie ma `.sys`. |
| Nie zmieniliśmy `TESTSIGNING` | To decyzja właściciela maszyny, nie zadanie programu. |
| Nie wyłączaliśmy Secure Boot | j.w. |
| Nie utworzyliśmy konta w Dev Center | Wymagałoby danych osobowych i akceptacji umowy w imieniu użytkownika. |

## 4. Warunki do podpisania

Sterownik jest gotowy do podpisania dopiero wtedy, gdy **wszystkie** poniższe są
prawdą:

1. Kod sterownika realizuje **wyłącznie** operacje z `driver_proto.Function`.
2. Walidacja ramki jest wykonana w sterowniku, nie tylko w kliencie.
3. Stan CPU sprawdzany jest ponownie tuż przed `Rdmsr`.
4. `METHOD_BUFFERED`, brak `METHOD_NEITHER`.
5. `allowed_msr` zawiera wyłącznie rejestry z potwierdzonym źródłem.
6. Sterownik przechodzi Driver Verifier bez błędów.
7. Sterownik przechodzi HLK.
8. Każdy test w `docs/SECURITY-MODEL.md` §10 ma odpowiednik po stronie
   sterownika (weryfikowany w trybie jądra, nie tylko logiką klienta).

Punkty 1–5 są dziś spełnione **na poziomie kontraktu i kodu klienta**. Punkty
6–8 wymagają kodu sterownika, którego jeszcze nie ma.
