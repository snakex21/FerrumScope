//! Statusy wyników prymitywów i deklarowanych możliwości.
//!
//! Zasada projektowa FerrumScope: **brak możliwości platformy to nie jest błąd
//! programu.** CPU bez MSR, Linux bez `/dev/cpu/N/msr` albo macOS bez dostępu do
//! SMC zwracają `Status.unsupported`, a program działa dalej i mówi wprost,
//! czego nie sprawdził.
//!
//! Jedynymi prawdziwymi błędami programu są: błędna baza, błędny plik capture
//! i błąd wewnętrzny dekodera (`.failed` z komunikatem diagnostycznym).

/// Wynik pojedynczego odczytu, niezależnie od platformy.
pub const Status = enum {
    /// Odczyt wykonany poprawnie.
    ok,
    /// Platforma nie ma tej możliwości w ogóle (brak CPUID na ARM, brak MSR w USOS).
    /// Wynik poprawny: „nie umiemy tego zrobić", nie „sprzęt jest zepsuty".
    unsupported,
    /// Możliwość istnieje, ale proces nie ma do niej dostępu (brak roota,
    /// sterownik niezaładowany). Wymaga komunikatu z instrukcją naprawy.
    denied,
    /// Przekroczony budżet czasu probe'a.
    timeout,
    /// Odczyt wykonany, sprzęt zwrócił błąd.
    failed,
    /// Odczyt poprawny — urządzenia nie ma. To wynik pozytywny, nie błąd.
    absent,
    /// Zależność nie spełniona, probe celowo się wycofał.
    skipped,

    /// Czy status oznacza, że zbiory danych są niekompletne.
    pub fn isDegraded(self: Status) bool {
        return self != .ok;
    }

    pub fn toSlice(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok",
            .unsupported => "unsupported",
            .denied => "denied",
            .timeout => "timeout",
            .failed => "failed",
            .absent => "absent",
            .skipped => "skipped",
        };
    }
};

/// Opis niepowodzenia — `detail` jest diagnostyką dla logu, nie dla UI.
pub const Failure = struct {
    status: Status,
    detail: []const u8 = "",

    pub fn init(status: Status, detail: []const u8) Failure {
        return .{ .status = status, .detail = detail };
    }

    /// Najczęstszy przypadek: platforma po prostu nie umie.
    pub fn unsupported() Failure {
        return .{ .status = .unsupported };
    }
};

/// Wynik prymitywu: sukces albo opisany brak sukcesu.
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: Failure,

        pub fn unwrap(self: @This()) ?T {
            return switch (self) {
                .ok => |v| v,
                .err => null,
            };
        }

        /// Zwraca wartość albo `null`, gdy wystąpił błąd. Wygodne tam, gdzie
        /// brak odczytu jest normalny, a nie wyjątkiem — np. liść CPUID,
        /// którego dany procesor po prostu nie ma.
        pub fn orNull(self: @This()) ?T {
            return switch (self) {
                .ok => |v| v,
                .err => null,
            };
        }

        pub fn getStatus(self: @This()) Status {
            return switch (self) {
                .ok => .ok,
                .err => |e| e.status,
            };
        }
    };
}

test "status: brak możliwości to nie błąd" {
    try @import("std").testing.expect(!Status.unsupported.isDegraded() == false);
    try @import("std").testing.expect(Status.ok.isDegraded() == false);
    try @import("std").testing.expect(Status.absent.isDegraded());
}

test "Result: getStatus rozróżnia ok od braku możliwości" {
    const A: Result(u8) = .{ .ok = 7 };
    const B: Result(u8) = .{ .err = Failure.unsupported() };
    try @import("std").testing.expectEqual(Status.ok, A.getStatus());
    try @import("std").testing.expectEqual(Status.unsupported, B.getStatus());
    try @import("std").testing.expectEqual(@as(?u8, 7), A.unwrap());
    try @import("std").testing.expectEqual(@as(?u8, null), B.unwrap());
}
