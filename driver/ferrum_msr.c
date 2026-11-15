/*
 * FerrumScope — minimalny sterownik odczytu MSR (Etap 3B)
 * ===========================================================
 *
 * ZAKRES — celowo mikroskopijny:
 *   + handshake protokołu (magic + wersja)
 *   + zapytanie o zdolności
 *   + odczyt MSR z allowlisty, na wskazanym procesorze logicznym
 *
 * ZAKRES — celowo wykluczony (brak implementacji, nie brak użycia):
 *   - zapis MSR
 *   - dowolny odczyt pamięci fizycznej / pamięci jądra
 *   - dowolne MMIO
 *   - dowolne port I/O
 *   - HWDB, logika AMD/Intel, dekodowanie temperatur i mocy
 *
 * Sterownik jest DOSTARCĄ DANYCH, nie skrzynką z narzędziami.
 *
 * ---------------------------------------------------------------------------
 * Dlaczego NIE MA DPC
 * ---------------------------------------------------------------------------
 * Wersja poprzedniej rewizji tego pliku odczytywała MSR w DPC
 * skierowanym na wskazany procesor. To było zbędne i wprowadzało realne
 * ryzyko: kontekst DPC leżał na stosie wątku IOCTL, więc przy timeoutcie
 * nie dało się go bezpiecznie zwolnić — a DPC mógł dobiec później, dając
 * use-after-return.
 *
 * DPC **nie jest potrzebny**. `IRP_MJ_DEVICE_CONTROL` wykonuje się w kontekście
 * wątku wywołującego na IRQL = PASSIVE_LEVEL, a `KeSetSystemGroupAffinityThread`
 * na tym IRQL ustawia powinowactwo **bieżącego wątku**. Możemy więc:
 *
 *     1. zapisać poprzednią group affinity,
 *     2. przypiąć wątek do jednego konkretnego procesora logicznego,
 *     3. POTWIERDZIĆ, że wątek faktycznie tam trafił,
 *     4. wykonać `__readmsr`,
 *     5. zawsze przywrócić powinowactwo.
 *
 * Wszystko synchronicznie, bez timeoutu, bez oczekiwania na zdarzenie, bez
 * puli, bez callbacka. Usunięte: timeout DPC, problem lifetime kontekstu,
 * asynchroniczne ukończenie, wyścig o kontekst.
 *
 * Krok 3 jest tu **nieopcjonalny**. Ustawienie maski powinowactwa nie jest
 * tym samym co natychmiastowa migracja wątku. Bez potwierdzenia `__readmsr`
 * mógłby przeczytać rejestr procesora innego niż żądany — a liczba wyglądałaby
 * wiarygodnie i dotyczyłaby innego rdzenia. Jeśli potwierdzenie nie nastąpi
 * w ograniczonym czasie, zwracamy błąd i **nie czytamy w ogóle**.
 *
 * ---------------------------------------------------------------------------
 * IRQL
 * ---------------------------------------------------------------------------
 * Wymagany IRQL: PASSIVE_LEVEL. `KeSetSystemGroupAffinityThread` zmienia
 * powinowactwo natychmiastowo tylko poniżej APC_LEVEL; wyżej zmiana zostalaby
 * odłożona do obniżenia IRQL, a wątek zdążyłby wykonać `__readmsr` na
 * niewłaściwym CPU. Dlatego IRQL sprawdzamy i zwracamy błąd, zamiast ufać,
 * że zawsze będzie właściwy.
 *
 * ---------------------------------------------------------------------------
 * PROCESSOR GROUPS
 * ---------------------------------------------------------------------------
 * Numeracja logiczna w Windows to `grupa * MaxPerGroup + indeks`. Nie używamy
 * na ślepo `% 64` — `KeGetMaximumProcessorNumberPerGroup()` zwraca wartość
 * faktyczną dla danego systemu. Walidujemy: grupa istnieje, indeks w grupie
 * istnieje, procesor jest aktywny (nie offline).
 */

#include <ntddk.h>

/*
 * ---------------------------------------------------------------------------
 * CZEGO NIE MA W TYM WDK — stwierdzone przez KOMPILATOR
 * ---------------------------------------------------------------------------
 * W wdm.h te WDK (10.0.26100.0) nie są zadeklarowane:
 *   KeGetProcessorNumberEx, KeRevertToGroupAffinity,
 *   KeGetMaximumProcessorNumberPerGroup
 * Kompilator zgłasza dla nich C4013 "niezdefiniowany", a w konsekwencji
 * błędy "niezadeklarowany identyfikator".
 *
 * Typ dla `KeGetCurrentProcessorNumberEx` to `PROCESSOR_NUMBER` z `um/winnt.h`
 * — **nie** `KPROCESSOR_NUMBER`, której w tym WDK dla trybu jądra brakuje.
 * Używamy typedefu, który SDK już dostarcza, zamiast pisać własny struct:
 * wcześniejsza próba własnego typedefu kolidowała z user-mode
 * `PPROCESSOR_NUMBER` (kompilator: C2371 "zmiana definicji", różne typy
 * podstawowe). Uwierzyłem wtedy grepowi, gdzie należało uwierzyć
 * kompilatorowi.
 *
 * Jednocześnie ntoskrnl.lib EKSPORTUJE (potwierdzone `dumpbin /exports`):
 *   KeSetSystemGroupAffinityThread, KeRevertToUserGroupAffinityThread,
 *   KeGetCurrentProcessorNumberEx, KeQueryActiveProcessorCountEx
 *
 * Wniosek: mechanizm zmiany powinowactwa jest w jądrze dostępny, więc
 * budujemy na nim. NIE deklarujemy sygnatur funkcji, których jądro nie
 * eksportuje — niezgodna sygnatura to wywołanie losowego adresu, czyli BSOD.
 */

/*
 * Procesorów w grupie. Jądro udostępnia `KeGetMaximumProcessorNumberPerGroup()`,
 * ale ten WDK go nie deklaruje ani nie eksportuje. Wartość 64 to **nie jest
 * założenie przypadkowe**: to wartość architektoniczna grupy procesorów na
 * każdej wydanej wersji Windows.
 *
 * Bezpieczeństwa NIE daje ta stała, tylko **potwierdzenie rzeczywistego
 * procesora** po ustawieniu powinowactwa (patrz niżej). Gdyby mapa
 * group/indeks była zła, wątek nie potwierdziłby migracji i zwrócił
 * CPU_OFFLINE — zamiast czytać rejestr niewłaściwego rdzenia. Stała jest
 * więc wejściem, a nie zabezpieczeniem.
 */
#define FERRUM_PROCESSORS_PER_GROUP 64u

/* ------------------------------------------------------------------ */
/* Protokół — musi odpowiadać src/telemetry/driver_proto.zig         */
/* ------------------------------------------------------------------ */

#define FERRUM_MAGIC            0x46534D52u   /* "FSMR" */
#define FERRUM_PROTOCOL_VERSION 1u
#define FERRUM_MIN_CLIENT       1u

/* FILE_DEVICE_UNKNOWN(0x22), FILE_READ_DATA(1), METHOD_BUFFERED(0) */
#define FERCTL_READ(a) CTL_CODE(0x22, (a), METHOD_BUFFERED, FILE_READ_DATA)
#define IOCTL_QUERY_PROTOCOL     FERCTL_READ(0x800)
#define IOCTL_QUERY_CAPABILITIES FERCTL_READ(0x801)
#define IOCTL_READ_MSR           FERCTL_READ(0x802)

typedef struct _FERRUM_HEADER {
    UINT32 Magic;
    UINT32 Version;
    UINT32 StructSize;
} FERRUM_HEADER;

typedef LONG FERRUM_STATUS;
#define FERRUM_OK                    0
#define FERRUM_BAD_MAGIC           (-1)
#define FERRUM_UNSUPPORTED_VERSION (-2)
#define FERRUM_BAD_SIZE            (-3)
#define FERRUM_INVALID_CPU         (-4)
#define FERRUM_MSR_NOT_ALLOWED     (-5)
#define FERRUM_CPU_OFFLINE         (-6)
#define FERRUM_READ_FAILED         (-7)

typedef struct _FERRUM_QUERY_PROTOCOL_RESP {
    FERRUM_HEADER Header;
    UINT32 ProtocolVersion;
    UINT32 MinClientVersion;
    UINT16 OnlineCpuCount;
} FERRUM_QUERY_PROTOCOL_RESP;

typedef struct _FERRUM_CAPS_RESP {
    FERRUM_HEADER Header;
    UINT32 Capabilities;
    UINT16 OnlineCpuCount;
} FERRUM_CAPS_RESP;

typedef struct _FERRUM_READ_MSR_REQ {
    FERRUM_HEADER Header;
    UINT16 LogicalCpu;
    UINT32 MsrIndex;
    UINT32 Reserved;
} FERRUM_READ_MSR_REQ;

typedef struct _FERRUM_READ_MSR_RESP {
    FERRUM_HEADER Header;
    FERRUM_STATUS Status;
    UINT64 Value;
} FERRUM_READ_MSR_RESP;

/* Kolejność musi odpowiadać `msr.Capability` w src/telemetry/msr.zig. */
#define CAP_MSR_READ         0x1u
#define CAP_PER_CPU_MSR_READ 0x2u
#define CAP_APERF_MPERF      0x4u
#define CAP_ENERGY_COUNTER   0x8u
#define CAP_TEMPERATURE_RAW  0x10u
#define CAP_PLATFORM_UTIL    0x20u

/*
 * Allowlist Etapu 3B: WYŁĄCZNIE rejestry potrzebne do pierwszego pomiaru
 * APERF/MPERF. Nic więcej.
 *
 * Temperatura (0xC0010014) i liczniki energii (0xC0010293/94) są kandydatami
 * Etapu 3C i w tabeli researchowej mają status UNVERIFIED — brak potwierdzonego
 * układu bitów. Dodanie ich teraz dałoby wiarygodnie wyglądające, całkowicie
 * zmyślone wartości. Nie wchodzą i nie będą wchodzić, dopóki nie potwierdzimy
 * ich w dokumentacji producenta dla tej konkretnej generacji.
 */
#define FERRUM_MSR_APERF 0xE8u
#define FERRUM_MSR_MPERF 0xE7u

static BOOLEAN FerrumMsrAllowed(UINT32 Index) {
    return (Index == FERRUM_MSR_APERF) || (Index == FERRUM_MSR_MPERF);
}

/* ------------------------------------------------------------------ */
/* Zgodność rozmiarów z klientem Zig                                   */
/* ------------------------------------------------------------------ */
/*
 * Te wartości muszą zgadzać się z tym, co wylicza kompilator Zig w
 * src/telemetry/driver_proto.zig. Asercje są celowo **sztywne**: rozjazd
 * rozmiaru o jeden bajt oznaczałby ciche, błędne parsowanie odpowiedzi
 * sterownika — gorsze od braku sterownika.
 *
 * Sprawdzenie drugiej strony: driver/layout_probe.c wypisuje te wartości,
 * a test Zig porównuje je z oczekiwanymi.
 */
C_ASSERT(sizeof(FERRUM_HEADER)                == 12);
C_ASSERT(sizeof(FERRUM_QUERY_PROTOCOL_RESP)   == 24); /* 12+4+4+2 -> wyrównanie do 4 */
C_ASSERT(sizeof(FERRUM_CAPS_RESP)             == 20); /* 12+4+2   -> wyrównanie do 4 */
C_ASSERT(sizeof(FERRUM_READ_MSR_REQ)          == 24);
C_ASSERT(sizeof(FERRUM_READ_MSR_RESP)         == 24);
/* CTL_CODE(DeviceType, Function, Method, Access) = (DeviceType << 16) | (Access << 14) | (Function << 2) | Method
 *  query_protocol: (0x22<<16) | (1<<14) | (0x800<<2) | 0 = 0x00226000
 *  query_capab.  : (0x22<<16) | (1<<14) | (0x801<<2) | 0 = 0x00226004
 *  read_msr      : (0x22<<16) | (1<<14) | (0x802<<2) | 0 = 0x00226008
 * Wczesniejsza rewizja pliku miala tu 0x00222000/04/08 — pomylone, bo pominela
 * przesuniecie Function<<2 oraz bit dostepu FILE_READ_DATA<<14. Sam makro
 * CTL_CODE bylo poprawne; blad byl w recznie wpisanych wartosciach
 * oczekiwanych, co kompilator zglosil jako "ujemny indeks dolny" przez
 * __C_ASSERT__. */
C_ASSERT(IOCTL_QUERY_PROTOCOL     == 0x00226000u);
C_ASSERT(IOCTL_QUERY_CAPABILITIES == 0x00226004u);
C_ASSERT(IOCTL_READ_MSR           == 0x00226008u);

/* Ile prób potwierdzenia faktycznej migracji wątku. Każda to krótkie
 * oczekiwanie w KeStallExecutionProcessor; przy obciążonym systemie kilkaset
 * prób w zupełności wystarcza, a górna granica gwarantuje, że wątek nie krąży
 * w nieskończoność. */
#define FERRUM_MIGRATION_ATTEMPTS 10000u

/* ------------------------------------------------------------------ */
/* Odczyt na wskazanym procesorze logicznym — SYNCHRONICZNIE          */
/* ------------------------------------------------------------------ */

static FERRUM_STATUS
FerrumReadMsrOnCpu(UINT16 LogicalCpu, UINT32 MsrIndex, UINT64 *OutValue)
{
    GROUP_AFFINITY Target;
    GROUP_AFFINITY Previous;
    PROCESSOR_NUMBER ProcNum;
    ULONG MaxPerGroup;
    ULONG GroupActive;
    ULONG Group;
    ULONG IndexInGroup;
    ULONG CurrentIndex;
    UINT64 Value;
    FERRUM_STATUS Status;
    ULONG Attempt;
    int Confirmed;

    Status = FERRUM_CPU_OFFLINE;
    Value  = 0;
    Confirmed = 0;

    /*
     * IRQL musi być PASSIVE_LEVEL. Powyżej APC_LEVEL zmiana powinowactwa
     * zostałaby odłożona do obniżenia IRQL i wątek zdążyłby wykonać
     * `__readmsr` na niewłaściwym procesorze. Wolimy błąd niż cichy odczyt.
     */
    if (KeGetCurrentIrql() > APC_LEVEL) {
        return FERRUM_READ_FAILED;
    }

    MaxPerGroup = FERRUM_PROCESSORS_PER_GROUP;
    if (MaxPerGroup == 0) {
        return FERRUM_READ_FAILED;
    }

    /* Numeracja logiczna: grupa * MaxPerGroup + indeks w grupie. */
    Group        = (ULONG)LogicalCpu / MaxPerGroup;
    IndexInGroup = (ULONG)LogicalCpu % MaxPerGroup;

    /*
     * Grupa musi istnieć i mieć aktywne procesory.
     * `KeQueryActiveProcessorCountEx(grupa)` zwraca 0 dla grupy nieistniejącej
     * lub w pełni offline — obie sytuacje kończą się tak samo i obie są
     * powodem do odmowy, nigdy do odczytu.
     */
    GroupActive = (ULONG)KeQueryActiveProcessorCountEx((USHORT)Group);
    if (GroupActive == 0) {
        return FERRUM_INVALID_CPU;
    }
    if (IndexInGroup >= GroupActive) {
        return FERRUM_INVALID_CPU;
    }

    RtlZeroMemory(&Target, sizeof(Target));
    Target.Group = (USHORT)Group;
    Target.Mask  = ((KAFFINITY)1) << IndexInGroup;
    Target.Reserved[0] = 0;
    Target.Reserved[1] = 0;
    Target.Reserved[2] = 0;
    RtlZeroMemory(&Previous, sizeof(Previous));

    /*
     * Ustawiamy powinowactwo. `PreviousGroupAffinity` musi być prawdziwym
     * buforem — przekazanie NULL oznacza „nie zmieniaj powinowactwa".
     */
    KeSetSystemGroupAffinityThread(&Target, &Previous);

    /*
     * KROK 3 — potwierdzenie faktycznej migracji.
     *
     * `KeGetCurrentProcessorNumberEx` zwraca **systemowy** indeks
     * logicznego procesora, na którym wątek faktycznie się znajduje.
     * Porównujemy go z żądanym `LogicalCpu`.
     */
    for (Attempt = 0; Attempt < FERRUM_MIGRATION_ATTEMPTS; Attempt++) {
        RtlZeroMemory(&ProcNum, sizeof(ProcNum));
        CurrentIndex = KeGetCurrentProcessorNumberEx(&ProcNum);
        if (CurrentIndex == (ULONG)LogicalCpu) {
            Confirmed = 1;
            break;
        }
        KeStallExecutionProcessor(1);
    }

    /*
     * KROK 4 — odczyt. WYKONUJEMY GO TYLKO po potwierdzeniu.
     * Bez potwierdzenia zwracamy błąd i `Value` zostaje zerem.
     */
    if (Confirmed) {
        /*
         * `__readmsr` na rejestrze, którego procesor (albo hypervisor —
         * na tej maszynie HypervisorPresent=True, Windows działa w partycji
         * root Hyper-V) nie obsługuje, kończy się #GP. Bez SEH to BSOD.
         * Z SEH: odmowa odczytu, przywrócenie powinowactwa poniżej i tak
         * się wykona, bo jesteśmy przed jedynym wyjściem z funkcji.
         */
        __try {
            Value  = (UINT64)__readmsr(MsrIndex);
            Status = FERRUM_OK;
        } __except (EXCEPTION_EXECUTE_HANDLER) {
            Value  = 0;
            Status = FERRUM_READ_FAILED;
        }
    }

    /*
     * KROK 5 — przywrócenie powinowactwa.
     *
     * Używamy `KeRevertToUserGroupAffinityThread`, bo `KeRevertToGroupAffinity`
     * w tym WDK nie jest zadeklarowane. Oba wykonują to samo przywrócenie
     * zapisanej maski; ten wariant jest eksportowany przez ntoskrnl.
     *
     * Jeden wyjście, bez `continue`/`break`/`return` powyżej, więc przywrócenie
     * **zawsze** się wykona: także po nieudanym odczycie i po każdym błędzie.
     * Wątek zostawiony na jednym CPU działałby wolniej i zaburzałby pomiar
     * pozostałych rdzeni, więc to nie higiena, lecz poprawność pomiaru.
     */
    KeRevertToUserGroupAffinityThread(&Previous);

    if (Status == FERRUM_OK) {
        *OutValue = Value;
    }
    return Status;
}

/* ------------------------------------------------------------------ */
/* Walidacja żądań — GRANICA ZUFNOŚCI                                  */
/* ------------------------------------------------------------------ */
/*
 * Klient jest procesem usermode: może być przejęty, a jego bufor może
 * wskazywać gdziekolwiek. Każda decyzja o dopuszczeniu odczytu zapada
 * **tutaj**, nie w kodzie klienta. Walidacja w kliencie jest wyłącznie
 * oszczędnością round-tripu.
 *
 * Kolejność: magic -> wersja -> rozmiar -> CPU -> rejestr.
 * Odwrócenie kolejności pozwoliłoby raportować zły rozmiar jako „złą wersję”.
 */

static FERRUM_STATUS
FerrumValidateHeader(const FERRUM_HEADER *Hdr)
{
    if (Hdr->Magic != FERRUM_MAGIC) {
        return FERRUM_BAD_MAGIC;
    }
    if (Hdr->Version < FERRUM_MIN_CLIENT || Hdr->Version > FERRUM_PROTOCOL_VERSION) {
        return FERRUM_UNSUPPORTED_VERSION;
    }
    if (Hdr->StructSize < sizeof(FERRUM_HEADER)) {
        return FERRUM_BAD_SIZE;
    }
    return FERRUM_OK;
}

static FERRUM_STATUS
FerrumValidateRead(const FERRUM_READ_MSR_REQ *Req, ULONG OnlineCpuCount)
{
    FERRUM_STATUS S = FerrumValidateHeader(&Req->Header);
    if (S != FERRUM_OK) {
        return S;
    }
    if (Req->Header.StructSize < sizeof(FERRUM_READ_MSR_REQ)) {
        return FERRUM_BAD_SIZE;
    }
    if (Req->LogicalCpu >= OnlineCpuCount) {
        return FERRUM_INVALID_CPU;
    }
    if (!FerrumMsrAllowed(Req->MsrIndex)) {
        return FERRUM_MSR_NOT_ALLOWED;
    }
    return FERRUM_OK;
}

/* ------------------------------------------------------------------ */
/* Obsługa IRP                                                         */
/* ------------------------------------------------------------------ */

static ULONG OnlineCpuCount(void) {
    return (ULONG)KeQueryActiveProcessorCountEx(ALL_PROCESSOR_GROUPS);
}

static NTSTATUS
FerrumComplete(PDEVICE_OBJECT DeviceObject, PIRP Irp, NTSTATUS Status, ULONG_PTR Info)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    Irp->IoStatus.Status = Status;
    Irp->IoStatus.Information = Info;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return Status;
}

static NTSTATUS
FerrumDispatchCreate(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    return FerrumComplete(DeviceObject, Irp, STATUS_SUCCESS, 0);
}

static NTSTATUS
FerrumDispatchClose(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    return FerrumComplete(DeviceObject, Irp, STATUS_SUCCESS, 0);
}

static NTSTATUS
FerrumDispatchUnsupported(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    return FerrumComplete(DeviceObject, Irp, STATUS_NOT_SUPPORTED, 0);
}

static NTSTATUS
FerrumDispatchDeviceControl(PDEVICE_OBJECT DeviceObject, PIRP Irp)
{
    PIO_STACK_LOCATION Stack;
    PVOID InBuf, OutBuf;
    ULONG InLen, OutLen;
    ULONG Ioctl;
    ULONG Online;
    FERRUM_STATUS FStatus;
    FERRUM_HEADER *Hdr;

    Stack = IoGetCurrentIrpStackLocation(Irp);
    Ioctl = Stack->Parameters.DeviceIoControl.IoControlCode;
    InBuf  = Irp->AssociatedIrp.SystemBuffer;   /* METHOD_BUFFERED */
    InLen  = Stack->Parameters.DeviceIoControl.InputBufferLength;
    OutBuf = Irp->AssociatedIrp.SystemBuffer;
    OutLen = Stack->Parameters.DeviceIoControl.OutputBufferLength;
    Online = OnlineCpuCount();

    /*
     * `SystemBuffer` jest wspólny dla wejścia i wyjścia przy METHOD_BUFFERED.
     * Zanim odczytamy **cokolwiek**, sprawdzamy, że klient przydzielił bufor
     * dla żądanej struktury. Zwykłe `InLen`/`OutLen` nie wystarcza, bo
     * sterownik nie ma prawa skasować pamięci procesu — ma prawo pominąć
     * operację, gdy rozmiar się nie zgadza.
     */

    switch (Ioctl) {

    case IOCTL_QUERY_PROTOCOL: {
        FERRUM_QUERY_PROTOCOL_RESP *R = (FERRUM_QUERY_PROTOCOL_RESP *)OutBuf;

        if (InLen < sizeof(FERRUM_HEADER) || OutLen < sizeof(*R)) {
            return FerrumComplete(DeviceObject, Irp, STATUS_BUFFER_TOO_SMALL, 0);
        }
        Hdr = (FERRUM_HEADER *)InBuf;
        FStatus = FerrumValidateHeader(Hdr);
        if (FStatus != FERRUM_OK) {
            return FerrumComplete(DeviceObject, Irp, STATUS_INVALID_PARAMETER, 0);
        }

        RtlZeroMemory(R, sizeof(*R));
        R->Header.Magic      = FERRUM_MAGIC;
        R->Header.Version    = FERRUM_PROTOCOL_VERSION;
        R->Header.StructSize = (UINT32)sizeof(*R);
        R->ProtocolVersion   = FERRUM_PROTOCOL_VERSION;
        R->MinClientVersion  = FERRUM_MIN_CLIENT;
        R->OnlineCpuCount    = (UINT16)Online;

        return FerrumComplete(DeviceObject, Irp, STATUS_SUCCESS, sizeof(*R));
    }

    case IOCTL_QUERY_CAPABILITIES: {
        FERRUM_CAPS_RESP *R = (FERRUM_CAPS_RESP *)OutBuf;

        if (InLen < sizeof(FERRUM_HEADER) || OutLen < sizeof(*R)) {
            return FerrumComplete(DeviceObject, Irp, STATUS_BUFFER_TOO_SMALL, 0);
        }
        Hdr = (FERRUM_HEADER *)InBuf;
        FStatus = FerrumValidateHeader(Hdr);
        if (FStatus != FERRUM_OK) {
            return FerrumComplete(DeviceObject, Irp, STATUS_INVALID_PARAMETER, 0);
        }

        RtlZeroMemory(R, sizeof(*R));
        R->Header.Magic      = FERRUM_MAGIC;
        R->Header.Version    = FERRUM_PROTOCOL_VERSION;
        R->Header.StructSize = (UINT32)sizeof(*R);
        /* Deklarujemy dokładnie to, co umiemy. Energia i temperatura wymagają
         * rejestrów, których nie potwierdziliśmy. */
        R->Capabilities   = CAP_MSR_READ | CAP_PER_CPU_MSR_READ | CAP_APERF_MPERF;
        R->OnlineCpuCount = (UINT16)Online;

        return FerrumComplete(DeviceObject, Irp, STATUS_SUCCESS, sizeof(*R));
    }

    case IOCTL_READ_MSR: {
        FERRUM_READ_MSR_REQ *Req = (FERRUM_READ_MSR_REQ *)InBuf;
        FERRUM_READ_MSR_RESP *R = (FERRUM_READ_MSR_RESP *)OutBuf;
        UINT64 Value;

        if (InLen < sizeof(FERRUM_READ_MSR_REQ) || OutLen < sizeof(*R)) {
            return FerrumComplete(DeviceObject, Irp, STATUS_BUFFER_TOO_SMALL, 0);
        }

        FStatus = FerrumValidateRead(Req, Online);
        if (FStatus != FERRUM_OK) {
            /*
             * Błąd **walidacji** zwracamy w ciele odpowiedzi ze statusem, nie
             * jako `STATUS_*`. Klient dzięki temu wie, która walidacja nie
             * przeszła, zamiast odróżniać „zły rozmiar" od „błąd I/O" po
             * naścieżce Win32.
             */
            RtlZeroMemory(R, sizeof(*R));
            R->Header.Magic      = FERRUM_MAGIC;
            R->Header.Version    = FERRUM_PROTOCOL_VERSION;
            R->Header.StructSize = (UINT32)sizeof(*R);
            R->Status = FStatus;
            return FerrumComplete(DeviceObject, Irp, STATUS_SUCCESS, sizeof(*R));
        }

        FStatus = FerrumReadMsrOnCpu(Req->LogicalCpu, Req->MsrIndex, &Value);

        RtlZeroMemory(R, sizeof(*R));
        R->Header.Magic      = FERRUM_MAGIC;
        R->Header.Version    = FERRUM_PROTOCOL_VERSION;
        R->Header.StructSize = (UINT32)sizeof(*R);
        R->Status = FStatus;
        R->Value  = (FStatus == FERRUM_OK) ? Value : 0;

        return FerrumComplete(DeviceObject, Irp, STATUS_SUCCESS, sizeof(*R));
    }

    default:
        /*
         * Nieznany IOCTL. Żadnego innego kodu nie obsługujemy — w szczególności
         * żadnego zapisu. Brak operacji zapisu jest **strukturalny**: nie ma
         * przypadku, nie ma funkcji, nie ma ścieżki.
         */
        return FerrumComplete(DeviceObject, Irp, STATUS_INVALID_DEVICE_REQUEST, 0);
    }
}

static VOID
FerrumDriverUnload(PDRIVER_OBJECT DriverObject)
{
    UNICODE_STRING SymLink;

    UNREFERENCED_PARAMETER(DriverObject);
    RtlInitUnicodeString(&SymLink, L"\\DosDevices\\FerrumScopeMsr");
    IoDeleteSymbolicLink(&SymLink);
}

NTSTATUS
DriverEntry(PDRIVER_OBJECT DriverObject, PUNICODE_STRING RegistryPath)
{
    UNICODE_STRING DevName, SymLink;
    PDEVICE_OBJECT DeviceObject = NULL;
    NTSTATUS Status;
    ULONG i;

    UNREFERENCED_PARAMETER(RegistryPath);

    /*
     * Domyślnie WSZYSTKIE MajorFunction odrzucają. Dopiero potem przydzielamy
     * te trzy, które obsługujemy. Gdyby kiedyś ktoś dopisał obsługę nowego
     * IRP i zapomniał zaktualizować tego miejsca, funkcja domyślna i tak
     * zwróci błąd zamiast wykonać niezainicjalizowany wskaźnik.
     */
    for (i = 0; i <= IRP_MJ_MAXIMUM_FUNCTION; i++) {
        DriverObject->MajorFunction[i] = FerrumDispatchUnsupported;
    }
    DriverObject->MajorFunction[IRP_MJ_CREATE]         = FerrumDispatchCreate;
    DriverObject->MajorFunction[IRP_MJ_CLOSE]          = FerrumDispatchClose;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = FerrumDispatchDeviceControl;
    DriverObject->DriverUnload = FerrumDriverUnload;

    RtlInitUnicodeString(&DevName, L"\\Device\\FerrumScopeMsr");
    RtlInitUnicodeString(&SymLink, L"\\DosDevices\\FerrumScopeMsr");

    Status = IoCreateDevice(DriverObject, 0, &DevName, FILE_DEVICE_UNKNOWN,
                            FILE_DEVICE_SECURE_OPEN, FALSE, &DeviceObject);
    if (!NT_SUCCESS(Status)) {
        return Status;
    }

    Status = IoCreateSymbolicLink(&SymLink, &DevName);
    if (!NT_SUCCESS(Status)) {
        IoDeleteDevice(DeviceObject);
        return Status;
    }

    DeviceObject->Flags &= ~DO_DEVICE_INITIALIZING;
    return STATUS_SUCCESS;
}
