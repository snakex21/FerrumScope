//! Kontrakt sterownika read-only — **projekt, nie zaimplementowany w jądrze**.
//!
//! Ten plik definiuje protokół i **walidację po stronie klienta**. Kod sterownika
//! (KMDF/WDM) jeszcze nie istnieje i w tym etapie **nie zostanie zainstalowany** —
//! patrz `docs/14-windows-signing.md`. To świadome ograniczenie: najpierw
//! kontrakt i testy, potem kod w trybie jądra.
//!
//! # Zakres: dostawca danych, nie skrzynka z narzędziami
//!
//! Sterownik FerrumScope udostępnia **wyłącznie** odczyt kilku z potwierdzonych
//! rejestrów MSR. Nie udostępnia i nie będzie udostępniał:
//!
//! * zapisu MSR — w protokole **nie ma** takiego żądania, więc nie da się go
//!   wywołać nawet przez błąd klienta,
//! * dowolnego odczytu pamięci fizycznej,
//! * dowolnego odczytu pamięci jądra,
//! * dowolnego MMIO,
//! * dowolnego port I/O (port I/O na Windows jest zresztą zamknięty dla
//!   procesów usermode, a sterownik ma je zablokowane).
//!
//! Powód jest praktyczny, nie ideologiczny: sterownik w trybie jądra działa
//! z pełnym zaufaniem systemu. Każda dodatkowa możliwość to powierzchnia
//! ataku, a użytkownik FerrumScope potrzebuje sześciu liczb. Wyjątkiem
//! sterownika narzędzia diagnostycznego byłoby „bo i tak da się wszystko", a
//! to nie jest argument — to odwrotność argumentu.
//!
//! # Allowlist, nie blocklist
//!
//! Odczyt MSR jest dozwolony **tylko** dla rejestrów na liście
//! (`allowed_msr`). Blocklista byłaby bezpieczna tylko wtedy, gdybyśmy znali
//! *wszystkie* niebezpieczne rejestry — a nie znamy i nie będziemy zgadywać.
//! Pozwolenie domyślnie odrzucone jest jedyną orientacją, która się nie psuje
//! z każdym nowym procesorem.
//!
//! Lista jest celowo krótka: `APERF` i `MPERF`, bo to jedyne rejestry, których
//! znaczenie **potwierdziliśmy** w źródłach (Intel SDM, AMD APM). Temperatura
//! i moc są w katalogu metryk, ale ich rejestrów **nie ma** na liście —
//! dopóki nie potwierdzimy układu bitów, sterownik ich nie udostępnia.

const std = @import("std");
const msr = @import("msr.zig");

/// „FSMR" — sygnatura protokołu. Odrzucamy każdą ramkę bez niej, zanim
/// spojrzymy na cokolwiek innego.
pub const protocol_magic: u32 = 0x4653_4D52;

/// Wersja protokołu.
///
/// Klient i sterownik **muszą** zgodzić się co do wersji. Nie używamy
/// „ładniejszej wersji" z kompatybilnością wsteczną: kontrakt jest wąski i
/// każda zmiana znaczenia jest zmianą sensu. Stary klient dostaje błąd
/// wersji, a nie ciche błędne odczyty.
pub const protocol_version: u32 = 1;

/// Najniższa wersja klienta, którą sterownik obsługuje.
pub const min_client_version: u32 = 1;

// ---------------------------------------------------------------------------
// Kody IOCTL
// ---------------------------------------------------------------------------

/// Typ urządzenia: `FILE_DEVICE_UNKNOWN` (0x22).
pub const device_type: u16 = 0x22;
/// Dostęp: `FILE_READ_DATA` (1) — sterownik **nie** udostępnia zapisu.
pub const device_access: u8 = 1;

pub const Function = enum(u16) {
    query_protocol = 0x800,
    query_capabilities = 0x801,
    read_msr = 0x802,
};

/// Buduje kod IOCTL (CTL_CODE) z jawnymi składowymi.
///
/// Rozpisujemy wzór zamiast używać makra, żeby każde pole było widoczne: kod
/// IOCTL jest jednocześnie **uprawnieniem**, a uprawnienie zapisane „na szybko"
/// jako `0x22_0000` jest nieczytelne przy przeglądaniu.
pub fn ioctlCode(f: Function) u32 {
    return (@as(u32, device_type) << 16) |
        (@as(u32, device_access) << 14) |
        (@as(u32, @intFromEnum(f)) << 2) |
        @as(u32, 0); // METHOD_BUFFERED
}

// ---------------------------------------------------------------------------
// Ramki protokołu
// ---------------------------------------------------------------------------

/// Nagłówek wspólny dla żądania i odpowiedzi.
///
/// `struct_size` pozwala odróżnić „klient przysłał za mało pól" od „klient
/// przysłał ich więcej, niż znamy". Drugi przypadek to przyszłość: sterownik
/// ignoruje nieznany ogon, pierwsze odrzuca jako błąd.
pub const Header = extern struct {
    magic: u32 = protocol_magic,
    version: u32 = protocol_version,
    struct_size: u32 = 0,
};

/// Negocjacja wersji. Klient zaczyna od tego żądania.
pub const QueryProtocolRequest = extern struct {
    header: Header = .{},
};

pub const QueryProtocolResponse = extern struct {
    header: Header = .{},
    /// Wersja, którą sterownik faktycznie obsługuje.
    protocol_version: u32 = 0,
    min_client_version: u32 = 0,
    /// Maksymalny `logical_cpu` + 1 **w chwili odpowiedzi**. Zmienia się przy
    /// hotplugu, dlategy klient musi go traktować jako wartość chwilową.
    online_cpu_count: u16 = 0,
};

/// Zdolności backendu — to samo, co `msr.CapabilitySet`, ale w wersji
/// protokołu. Reprezentacja jest tu celowo **osobna** od wewnętrznej: struktury
/// protokołu nie zmieniają się wraz z kodem, bo żyją w dwóch kontekstach
/// kompilacji (klient i przyszły sterownik).
pub const CapabilitiesResponse = extern struct {
    header: Header = .{},
    capabilities: u32 = 0,
    online_cpu_count: u16 = 0,
};

/// Odczyt **jednego** MSR dla **jednego** procesora logicznego.
pub const ReadMsrRequest = extern struct {
    header: Header = .{},
    logical_cpu: u16 = 0,
    msr_index: u32 = 0,
    /// Jawne wyrównanie struktury. Bez tego `sizeof` zależy od ABI i
    /// `struct_size` przestaje być przewidywalne.
    reserved: u32 = 0,
};

/// Kod wyniku żądania. Pokrywa błędy protokołu (`!*`) oraz te z `msr.MsrError`.
pub const Status = enum(i32) {
    ok = 0,
    /// Ramka nie zaczyna się od `protocol_magic`.
    bad_magic = -1,
    /// Wersja spoza zakresu [min_client_version, protocol_version].
    unsupported_version = -2,
    /// `struct_size` mniejszy niż najmniejsza obsługiwana struktura.
    bad_size = -3,
    /// `logical_cpu` poza zakresem online w chwili obsługi.
    invalid_cpu = -4,
    /// Rejestr spoza allowlisty.
    msr_not_allowed = -5,
    /// CPU zdążył zejść z linii między walidacją a odczytem (hotplug).
    cpu_offline = -6,
    /// Błąd odczytu po stronie sprzętu/rdzenia.
    read_failed = -7,

    pub fn toSlice(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok",
            .bad_magic => "bad_magic",
            .unsupported_version => "unsupported_version",
            .bad_size => "bad_size",
            .invalid_cpu => "invalid_cpu",
            .msr_not_allowed => "msr_not_allowed",
            .cpu_offline => "cpu_offline",
            .read_failed => "read_failed",
        };
    }
};

pub const ReadMsrResponse = extern struct {
    header: Header = .{},
    status: Status = .ok,
    value: u64 = 0,
};

pub fn msrStatus(s: Status) ?msr.MsrError {
    return switch (s) {
        .ok => null,
        .bad_magic, .unsupported_version, .bad_size, .msr_not_allowed => null,
        .invalid_cpu, .cpu_offline => .cpu_offline,
        .read_failed => .backend_error,
    };
}

// ---------------------------------------------------------------------------
// Allowlist rejestrów
// ---------------------------------------------------------------------------

pub const AllowedMsr = struct {
    index: u32,
    name: []const u8,
    /// Dlaczego ten rejestr jest na liście — ślad decyzji, nie komentarz.
    reason: []const u8,
};

/// Rejestry, które sterownik **udostępnia**. Lista zamknięta.
///
/// Kolejność i zawartość są **częścią kontraktu**: dodanie wpisu zmienia
/// zachowanie sterownika i musi iść wraz z wersją protokołu.
pub const allowed_msr = [_]AllowedMsr{
    .{
        .index = 0xE8,
        .name = "IA32_APERF",
        .reason = "Intel SDM Vol. 2A + AMD APM Vol. 3 — licznik cykli w stanie pracy",
    },
    .{
        .index = 0xE7,
        .name = "IA32_MPERF",
        .reason = "Intel SDM Vol. 2A + AMD APM Vol. 3 — licznik cykli blisko maksimum",
    },
};

/// Czy rejestr jest dozwolony. Domyślnie **nie**.
pub fn isMsrAllowed(index: u32) bool {
    for (allowed_msr) |a| {
        if (a.index == index) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Walidacja
// ---------------------------------------------------------------------------

pub const Reject = error{
    BadMagic,
    UnsupportedVersion,
    BadSize,
    InvalidCpu,
    MsrNotAllowed,
};

fn rejectName(e: Reject) Status {
    return switch (e) {
        error.BadMagic => .bad_magic,
        error.UnsupportedVersion => .unsupported_version,
        error.BadSize => .bad_size,
        error.InvalidCpu => .invalid_cpu,
        error.MsrNotAllowed => .msr_not_allowed,
    };
}

/// Sprawdza nagłówek ramki.
///
/// Kolejność jest istotna: **najpierw** magic, potem wersja, potem rozmiar.
/// Odwrócenie kolejności pozwoliłoby podawać błędne `struct_size` jako
/// „błąd wersji", co utrudnia diagnozę bez żadnej korzyści.
pub fn validateHeader(h: Header) Reject!void {
    if (h.magic != protocol_magic) return error.BadMagic;
    if (h.version < min_client_version or h.version > protocol_version) {
        return error.UnsupportedVersion;
    }
    if (h.struct_size < @sizeOf(Header)) return error.BadSize;
}

/// Waliduje żądanie odczytu MSR.
///
/// `online_cpu_count` to liczba CPU online **w chwili obsługi**. Sterownik musi
/// ją sprawdzić ponownie po walidacji, tuż przed `Rdmsr` — między tymi
/// momentami CPU może zejść z linii (hotplug, plan oszczędzania energii), a
/// `Rdmsr` dla CPU offline to nie tylko błąd, lecz odczyt z niewłaściwego
/// procesora.
pub fn validateReadMsr(
    req: ReadMsrRequest,
    online_cpu_count: u16,
) Reject!void {
    try validateHeader(req.header);
    // `struct_size` siedzi w **zagnieżdżonym** nagłówku, a nie na poziomie
    // żądania. `validateHeader` sprawdza już minimalny rozmiar nagłówka; tu
    // domykamy minimalny rozmiar całej żądanej struktury.
    if (req.header.struct_size < @sizeOf(ReadMsrRequest)) return error.BadSize;
    if (req.logical_cpu >= online_cpu_count) return error.InvalidCpu;
    if (!isMsrAllowed(req.msr_index)) return error.MsrNotAllowed;
}

/// Czy odpowiedź mieści się w buforze klienta.
///
/// Osobna funkcja, bo to najczęstszy błąd w warstwie IOCTL: sterownik pisze
/// strukturę pełną, klient przydzielił mniej. Bez tego sprawdzenia jądro
/// zapisałoby poza końcem bufora.
pub fn fitsInBuffer(resp_size: u32, buffer_len: u32) bool {
    return resp_size <= buffer_len;
}

pub fn rejectToStatus(e: Reject) Status {
    return rejectName(e);
}

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

const testing = std.testing;

// ---------------------------------------------------------------------------
// Zgodność layoutu C <-> Zig (Etap 3B, krok 9)
//
// Sterownik C pilnuje tych samych wartości przez C_ASSERT w driver/ferrum_msr.c.
// Te testy są drugim końcem tej samej umowy: jeśli kompilator zmieni sposób
// wyrównania structu w jednym z dwóch języków, **jedna** z dwóch stron padnie.
//
// Liczby poniżej to NIE „oczekiwania" — to wartości wymuszone przez C_ASSERT,
// których kompilacja C już potwierdziła. Test sprawdza, że Zig liczy tak samo.
// ---------------------------------------------------------------------------

test "layout: rozmiary struktur zgodne z C_ASSERT w sterowniku" {
    // driver/ferrum_msr.c: C_ASSERT(sizeof(FERRUM_HEADER) == 12);
    try testing.expectEqual(@as(usize, 12), @sizeOf(Header));
    // 12 + 4 + 4 + 2 = 22, wyrównanie do 4 -> 24
    try testing.expectEqual(@as(usize, 24), @sizeOf(QueryProtocolResponse));
    // 12 + 4 + 2 = 18, wyrównanie do 4 -> 20
    try testing.expectEqual(@as(usize, 20), @sizeOf(CapabilitiesResponse));
    try testing.expectEqual(@as(usize, 24), @sizeOf(ReadMsrRequest));
    try testing.expectEqual(@as(usize, 24), @sizeOf(ReadMsrResponse));
}

test "layout: bajtowy układ odpowiedzi zgodny z tym, co widzi sterownik" {
    // Weryfikujemy BAJTY, nie offsety pól. Offset liczony ze wskaźników dawał
    // wynik 20 dla `status` w strukturze o rozmiarze 24 i nagłówku o rozmiarze
    // 12 — sprzeczność, która pokazuje, że metoda ze wskaźników jest tu
    // zawodna (lokalne `var` nie musi leżeć w pamięci tak, jak sugeruje typ).
    // Bajty są jednocześnie bliższe temu, co naprawdę przechodzi przez granicę:
    // rozmiar, wyrównanie, kolejność i endianness.
    var resp = ReadMsrResponse{
        .header = .{ .magic = 0x46534D52, .version = 1, .struct_size = 24 },
        .status = .ok,
        .value = 0x1122334455667788,
    };
    const rb = std.mem.asBytes(&resp);
    try testing.expectEqual(@as(usize, 24), rb.len);
    // magic @0 — 0x46534D52 little-endian
    try testing.expectEqualSlices(u8, &[_]u8{ 0x52, 0x4D, 0x53, 0x46 }, rb[0..4]);
    // version @4 = 1
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00, 0x00, 0x00 }, rb[4..8]);
    // struct_size @8 = 24
    try testing.expectEqualSlices(u8, &[_]u8{ 0x18, 0x00, 0x00, 0x00 }, rb[8..12]);
    // status @12 = 0 — gdyby był na 20, sterownik zobaczyłby tu bajty `value`.
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x00 }, rb[12..16]);
    // value @16 — u64 little-endian
    try testing.expectEqualSlices(u8, &[_]u8{ 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 }, rb[16..24]);
}

test "layout: bajtowy układ żądania odczytu zgodny z C" {
    var req = ReadMsrRequest{
        .header = .{ .magic = 0x46534D52, .version = 1, .struct_size = 24 },
        .logical_cpu = 7,
        .msr_index = 0xE8,
        .reserved = 0,
    };
    const qb = std.mem.asBytes(&req);
    try testing.expectEqual(@as(usize, 24), qb.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x52, 0x4D, 0x53, 0x46 }, qb[0..4]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x18, 0x00, 0x00, 0x00 }, qb[8..12]);
    // logical_cpu @12 = 7 (u16)
    try testing.expectEqualSlices(u8, &[_]u8{ 0x07, 0x00 }, qb[12..14]);
    // wyrównanie do 4 przed msr_index @16 — bajty 14..15 muszą być zerami
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00 }, qb[14..16]);
    // msr_index @16 = 0xE8
    try testing.expectEqualSlices(u8, &[_]u8{ 0xE8, 0x00, 0x00, 0x00 }, qb[16..20]);
    // reserved @20
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x00, 0x00, 0x00 }, qb[20..24]);
}

test "layout: nagłówek odpowiada C_ASSERT(12)" {
    var h = Header{ .magic = 0x46534D52, .version = 1, .struct_size = 24 };
    const hb = std.mem.asBytes(&h);
    try testing.expectEqual(@as(usize, 12), hb.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x52, 0x4D, 0x53, 0x46 }, hb[0..4]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x00, 0x00, 0x00 }, hb[4..8]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x18, 0x00, 0x00, 0x00 }, hb[8..12]);
}

test "layout: kody IOCTL zgodne z CTL_CODE po stronie C" {
    // C_ASSERT(IOCTL_QUERY_PROTOCOL == 0x00226000u) i kolejne.
    // Wzór: (DeviceType << 16) | (Access << 14) | (Function << 2) | Method
    try testing.expectEqual(@as(u32, 0x0022_6000), ioctlCode(.query_protocol));
    try testing.expectEqual(@as(u32, 0x0022_6004), ioctlCode(.query_capabilities));
    try testing.expectEqual(@as(u32, 0x0022_6008), ioctlCode(.read_msr));
}

test "layout: numery funkcji IOCTL zgodne z C" {
    // Sterownik mapuje 0x800/0x801/0x802. Numer zmieniony po jednej stronie
    // oznaczałby, że klient wysyła żądanie, którego sterownik nie obsługuje —
    // cicho, bo `default` zwraca tylko STATUS_INVALID_DEVICE_REQUEST.
    try testing.expectEqual(@as(u16, 0x800), @intFromEnum(Function.query_protocol));
    try testing.expectEqual(@as(u16, 0x801), @intFromEnum(Function.query_capabilities));
    try testing.expectEqual(@as(u16, 0x802), @intFromEnum(Function.read_msr));
}

test "layout: sygnatura i wersja protokołu zgodne ze sterownikiem" {
    try testing.expectEqual(@as(u32, 0x4653_4D52), protocol_magic);
    try testing.expectEqual(@as(u32, 1), protocol_version);
    try testing.expectEqual(@as(u32, 1), min_client_version);
    // Sterownik deklaruje urządzenie jako FILE_DEVICE_UNKNOWN.
    try testing.expectEqual(@as(u16, 0x22), device_type);
    try testing.expectEqual(@as(u8, 1), device_access); // FILE_READ_DATA
}

test "layout: wartości statusów zgodne z C" {
    // Sterownik wysyła te liczby w ciele odpowiedzi. Rozjazd spowodowałby
    // odczyt obcego statusu jako "ok", czyli cichą wartość zmyśloną.
    try testing.expectEqual(@as(i32, 0), @intFromEnum(Status.ok));
    try testing.expectEqual(@as(i32, -1), @intFromEnum(Status.bad_magic));
    try testing.expectEqual(@as(i32, -2), @intFromEnum(Status.unsupported_version));
    try testing.expectEqual(@as(i32, -3), @intFromEnum(Status.bad_size));
    try testing.expectEqual(@as(i32, -4), @intFromEnum(Status.invalid_cpu));
    try testing.expectEqual(@as(i32, -5), @intFromEnum(Status.msr_not_allowed));
    try testing.expectEqual(@as(i32, -6), @intFromEnum(Status.cpu_offline));
    try testing.expectEqual(@as(i32, -7), @intFromEnum(Status.read_failed));
}

test "protokół: zła sygnatura jest odrzucana przed wszystkim innym" {
    const h: Header = .{ .magic = 0xDEAD_BEEF, .version = 99, .struct_size = 0 };
    try testing.expectError(error.BadMagic, validateHeader(h));
    // Kolejność ma znaczenie: mimo złej wersji i rozmiaru zgłaszamy magic,
    // a nie późniejszy błąd — inaczej diagnosa zwija się w „zła wersja".
    try testing.expectEqual(Status.bad_magic, rejectToStatus(error.BadMagic));
}

test "protokół: wersja spoza zakresu jest odrzucana" {
    const base: Header = .{ .struct_size = @sizeOf(ReadMsrRequest) };
    // Za nowa dla klienta.
    var too_new = base;
    too_new.version = protocol_version + 1;
    try testing.expectError(error.UnsupportedVersion, validateHeader(too_new));
    // Za stara dla sterownika.
    var too_old = base;
    too_old.version = min_client_version - 1;
    try testing.expectError(error.UnsupportedVersion, validateHeader(too_old));
    // Dokładnie graniczne wartości przechodzą.
    var lo = base;
    lo.version = min_client_version;
    try validateHeader(lo);
    var hi = base;
    hi.version = protocol_version;
    try validateHeader(hi);
}

test "protokół: za mały struct_size jest błędem, większy to przyszłość" {
    const small: Header = .{ .struct_size = @sizeOf(Header) - 1 };
    try testing.expectError(error.BadSize, validateHeader(small));

    // Klient z nowszego sterownika, znający dodatkowe pola: ignorujemy ogon.
    // Odrzucenie byłoby utrudnieniem bez korzyści — nieznane pola są po prostu
    // nieczytane.
    const future: Header = .{ .struct_size = @sizeOf(ReadMsrRequest) + 64 };
    try validateHeader(future);
}

test "protokół: logical_cpu spoza zakresu jest odrzucone" {
    const ok_req: ReadMsrRequest = .{
        .header = .{ .struct_size = @sizeOf(ReadMsrRequest) },
        .logical_cpu = 15,
        .msr_index = 0xE8,
    };
    try validateReadMsr(ok_req, 16);
    // CPU numer 16 przy 16 online (0..15) — o jeden za daleko.
    try testing.expectError(error.InvalidCpu, validateReadMsr(ok_req, 15));
}

test "protokół: allowlist dopuszcza tylko potwierdzone rejestry" {
    // Dwa jedyne rejestry, których znaczenie potwierdziliśmy.
    try testing.expect(isMsrAllowed(0xE8));
    try testing.expect(isMsrAllowed(0xE7));

    // Temperatura i moc są w katalogu metryk, ale ich rejestry **nie są**
    // potwierdzone, więc sterownik ich nie udostępnia.
    try testing.expect(!isMsrAllowed(0xC001_0014)); // MSR_AMD64_TEMP
    try testing.expect(!isMsrAllowed(0xC001_0064)); // MSR_AMD64_PSTATE_CUR
    try testing.expect(!isMsrAllowed(0x610)); // MSR_IA32_PKG_THERM_STATUS
    try testing.expect(!isMsrAllowed(0)); // MSR 0 nigdy nie jest użyteczny
    try testing.expect(!isMsrAllowed(0xFFFF_FFFF));
}

test "protokół: żądanie odczytu przechodzi walidację tylko dla dozwolonych rejestrów" {
    const good: ReadMsrRequest = .{
        .header = .{ .struct_size = @sizeOf(ReadMsrRequest) },
        .logical_cpu = 0,
        .msr_index = 0xE8,
    };
    try validateReadMsr(good, 8);

    var bad_msr = good;
    bad_msr.msr_index = 0xC001_0014;
    try testing.expectError(error.MsrNotAllowed, validateReadMsr(bad_msr, 8));
}

test "protokół: w protokole nie ma ŻADNEGO zapisu MSR" {
    // To nie jest test w stylu „sprawdź, że funkcja zwraca X” — to test
    // **braku możliwości**. Sprawdzamy, że:
    // 1. zbiór funkcji IOCTL nie zawiera żadnej operacji zapisu,
    // 2. `Function` ma dokładnie tyle wariantów, ile operacji odczytu
    //    opisaliśmy (dodanie zapisu wymagałoby dodania wariantu → błąd kompilacji
    //    w testach poniżej, bo lista się nie zgadza).
    const all = [_]Function{ .query_protocol, .query_capabilities, .read_msr };
    try testing.expectEqual(@typeInfo(Function).@"enum".fields.len, all.len);

    // Sprawdzamy też, że kod IOCTL nie ma prawa do zapisu: bit dostępu to
    // FILE_READ_DATA, nigdy FILE_WRITE_DATA.
    for (all) |f| {
        const code = ioctlCode(f);
        const access = @as(u8, @truncate((code >> 14) & 0x3));
        try testing.expectEqual(@as(u8, device_access), access);
    }
    // Każdy kod ma metodę METHOD_BUFFERED (0) — bez METHOD_NEITHER, który
    // przepuszczałby surowe wskaźniki użytkownika do trybu jądra.
    for (all) |f| {
        try testing.expectEqual(@as(u32, 0), ioctlCode(f) & 0x3);
    }
}

test "protokół: odpowiedź musi mieścić się w buforze klienta" {
    // Sprawdzamy samą funkcję na przypadkach brzegowych, a nie na zgadywanych
    // rozmiarach struktur — te zmienią się wraz z wersją protokołu.
    try testing.expect(fitsInBuffer(8, 8));
    try testing.expect(!fitsInBuffer(9, 8));
    try testing.expect(fitsInBuffer(0, 0));

    const resp = @sizeOf(ReadMsrResponse);
    try testing.expect(fitsInBuffer(resp, resp));
    try testing.expect(!fitsInBuffer(resp + 1, resp));
    try testing.expect(!fitsInBuffer(resp, resp - 1));

    // Dziś żądanie i odpowiedź mają **ten sam** rozmiar (wymuszone wyrównanie
    // przy `u64` w odpowiedzi). Jeśli kiedyś odpowiedź urośnie, stanie się to
    // realnym zagrożeniem: klient przydzielający bufor rozmiaru żądania dostałby
    // zapis poza jego koniec. Test przypomina, żeby przy zmianie układu struktur
    // sprawdzić tę asymetrię **świadomie**, a nie przypadkiem.
    try testing.expectEqual(@sizeOf(ReadMsrRequest), @sizeOf(ReadMsrResponse));
}

test "protokół: brak przepełnienia w walidacji rozmiarów" {
    // Nie mnożymy rozmiarów przez dane z ramki. `struct_size` porównujemy
    // wprost, więc wartość `u32` bliska `maxInt` nie może „zawijać się" do
    // małej wartości i przejść walidację.
    const huge: Header = .{ .struct_size = std.math.maxInt(u32) };
    try validateHeader(huge); // „przyszedł z przyszłości” — dopuszczamy
    var wrapped: ReadMsrRequest = .{
        .header = .{ .struct_size = @sizeOf(ReadMsrRequest) },
        .logical_cpu = 0,
        .msr_index = 0xE8,
    };
    // Gdyby kiedyś ktoś policzył `size * count` w u32, `maxInt * 2` zawinęłoby
    // się do zera. Ten test przypomina, że takiego mnożenia tu nie ma: wynik
    // porównania jest liniowy.
    wrapped.header.struct_size = @sizeOf(ReadMsrRequest);
    try validateReadMsr(wrapped, 4);
}

test "protokół: status mapuje się na błędy MSR dla wspólnego kontraktu" {
    // Warstwa klienta ma jeden typ błędu (`msr.MsrError`), więc statusy
    // protokołu muszą się w niego zmieścić bez zgadywania po stronie dekodera.
    try testing.expect(msrStatus(.ok) == null);
    try testing.expectEqual(msr.MsrError.cpu_offline, msrStatus(.invalid_cpu).?);
    try testing.expectEqual(msr.MsrError.cpu_offline, msrStatus(.cpu_offline).?);
    try testing.expectEqual(msr.MsrError.backend_error, msrStatus(.read_failed).?);
    // Błędy protokołu to nie błędy sprzętu: nie zamieniamy ich na `MsrError`,
    // bo sugerowałoby to, że problem leży w rejestrze, a leży w żądaniu.
    try testing.expect(msrStatus(.bad_magic) == null);
    try testing.expect(msrStatus(.msr_not_allowed) == null);
}

test "protokół: nazwy statusów są stabilne" {
    // Te napisy trafiają do logu i do `--json`. Zmiana nazwy zmienia kontrakt
    // raportu, więc pilnujemy ich jawnie.
    try testing.expectEqualStrings("ok", Status.ok.toSlice());
    try testing.expectEqualStrings("bad_magic", Status.bad_magic.toSlice());
    try testing.expectEqualStrings("msr_not_allowed", Status.msr_not_allowed.toSlice());
    try testing.expectEqualStrings("cpu_offline", Status.cpu_offline.toSlice());
}
