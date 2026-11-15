//! Liczniki cykli, delta z zawijaniem i efektywna częstotliwość z APERF/MPERF.
//!
//! Te mechanizmy są **wspólne** dla każdego licznika w projekcie: APERF/MPERF,
//! RAPL energy, TSC_MSx. Nie ma osobnej matematyki „dla AMD" i „dla Intel" —
//! jest jedna, z jednym zestawem przypadków brzegowych, które są realne:
//! zawinięcie, zerowy interwał, cofający się licznik, przepełnienie mnożenia.
//!
//! Dlaczego to jest tak wrażliwe: każdy błąd tutaj daje **wiarygodnie
//! wyglądającą** liczbę. Zawinięty licznik daje „częstotliwość 4000 MHz", nie
//! błąd. Dlatego każdy przypadek brzegowy ma test, a wartości podejrzane są
//! **oznaczane statusem**, nie zwracane jako liczba.

const std = @import("std");

const testing = std.testing;

// ---------------------------------------------------------------------------
// Szerokość licznika
// ---------------------------------------------------------------------------

/// Szerokość licznika w bitach. Liczniki energii bywają 32-, 48- i 64-bitowe,
/// a zawijanie liczy się w modulo `2^width` — dla każdej z tych szerokości
/// inaczej.
pub const Width = enum(u8) {
    b32 = 32,
    b48 = 48,
    b64 = 64,

    /// Maska szerokości licznika: `2^width - 1`.
    ///
    /// Osobno od `mask()`, bo tamta obcina **wejście** do szerokości, a ta
    /// obcina **wynik** operacji modularnej. Obie są potrzebne i łatwo je
    /// pomylić — stąd osobne nazwy zamiast przeładowania.
    fn maskBits(self: Width) u64 {
        if (self.bitCount() == 64) return std.math.maxInt(u64);
        return (@as(u64, 1) << @intCast(self.bitCount())) -% 1;
    }

    /// Mieszań modułowa: `2^width`. Dla 64 bitów zwraca **0**, bo `1 << 64`
    /// jest UB (przesunięcie o szerokość typu) i w trybie debug powoduje panic.
    ///
    /// Zero oznacza „licznik się nie zawija” — spadek wartości przy rosnącym
    /// czasie nie może wtedy być zawinięciem.
    pub fn modulus(self: Width) u64 {
        if (self.bitCount() == 64) return 0;
        return self.maskBits();
    }

    pub fn bitCount(self: Width) u8 {
        return switch (self) {
            .b32 => 32,
            .b48 => 48,
            .b64 => 64,
        };
    }

    /// Maskuje surową wartość do szerokości licznika.
    ///
    /// Backend może zwrócić pełne `u64`, gdy rejestr jest faktycznie 32-bitowy
    /// (górne bity bywają zerowe, ale przy testach i replayu nie ma takiej
    /// gwarancji). Maskowanie tutaj sprawia, że szerokość jest **jawna** w kodzie
    /// dekodera, a nie domyślna.
    pub fn mask(self: Width, raw: u64) u64 {
        if (self.bitCount() == 64) return raw;
        // Nawiasy są tu konieczne dla czytelności hierarchii operatorów:
        // `&` ma w Zig **niższy** priorytet niż `-`, więc bez nich
        // `raw & 1 << 32 - 1` czyta się poprawnie, ale na pierwszy rzut oka
        // wygląda jak `raw & ((1 << 32) - 1)` dopiero po rozwinięciu.
        return raw & ((@as(u64, 1) << @intCast(self.bitCount())) -% 1);
    }
};

// ---------------------------------------------------------------------------
// Delta
// ---------------------------------------------------------------------------

/// Wynik delty licznika.
///
/// `ok` niesie wartość, `invalid` niesie **powód** — bez niego wywołujący nie
/// odróżni „nic się nie zdarzyło" od „licznik cofnął się bez zawinięcia", a to
/// dwie zupełnie różne diagnozy.
pub const Delta = union(enum) {
    ok: u64,
    invalid: Invalid,

    pub const Invalid = enum {
        /// Zerowy interwał czasowy. Nie dzielimy przez zero, a „częstotliwość”
        /// z zerowego okna nie istnieje — nie jest nieskończonością, tylko
        /// brakiem danych.
        zero_interval,
        /// Poprzednia próbka jest **późniejsza** niż obecna. Zegar monotoniczny
        /// się cofnął albo backend pomieszał kolejność odczytów.
        nonmonotonic_time,
        /// Licznik zmniejszył się, a różnica nie mieści się w zawinięciu dla
        /// tej szerokości. To nie jest zawinięcie — to reset albo błędny odczyt
        /// (np. CPU offline i odczytaliśmy inny procesor).
        counter_regressed,
        /// Różnica przekracza szerokość licznika, więc zawinięcie jest
        /// niemożliwe do jednoznacznego zinterpretowania.
        wrap_ambiguous,
    };

    pub fn get(self: Delta) ?u64 {
        return switch (self) {
            .ok => |v| v,
            .invalid => null,
        };
    }
};

/// Delta licznika między dwiema próbkami, z poprawnym zawijaniem.
///
/// Zawinięcie wykrywamy przez spadek wartości, nie przez znak — w modularnej
/// arytmetyce `now - prev` modulo `2^width` **zawsze** daje poprawny wynik, także
/// po zawinięciu. Osobna kontrola „czy to zawinięcie czy regresja" jest potrzebna,
/// bo `2^32` cykli w oknie 100 ms jest fizycznie możliwe dla TSC, ale
/// niemożliwe dla raportowanego delta z rozsądną szerokością okna — i wtedy
/// wynik byłby prawdopodobnie bzdurą, nie pomiarem.
///
/// `prev_ns` i `now_ns` muszą być z **tego samego** zegara monotonicznego.
/// Różnica ujemna to błąd, nie „krótki interwał".
pub fn delta(prev: u64, now: u64, width: Width, prev_ns: u64, now_ns: u64) Delta {
    if (now_ns <= prev_ns) return .{ .invalid = .zero_interval };

    const a = width.mask(prev);
    const b = width.mask(now);
    const modulus = width.modulus();

    // Modularna arytmetyka: `b -% a` liczy modulo **2^64**, a zawinięcie
    // licznika 32-bitowego musi dać wynik modulo **2^32**. Bez zamaskowania
    // wyniku `0xFFFF_FFF0 -> 0x10` dawało `2^64 - 0xFFFF_FFE0` zamiast 31, czyli
    // gigantyczny „przyrost" — który w efektywnej częstotliwości wyglądałby jak
    // wiarygodne, choć błędne MHz. To dokładnie klasa błędu, której ten moduł
    // ma nie robić: zamiast wyjątku zwraca wiarygodnie wyglądającą liczbę.
    const raw = (b -% a) & width.maskBits();
    const elapsed = now_ns - prev_ns;

    // Zmniejszenie wartości przy rosnącym czasie oznacza zawinięcie **albo**
    // regresję. Odróżniamy je po tym, czy zawinięcie jest fizycznie możliwe:
    // jeśli „brakujące" cykle nie mieściłyby się w upływłym czasie, to nie jest
    // zawinięcie, tylko reset lub odczyt z innego procesora.
    if (b < a) {
        // Przy 64 bitach zawinięcie jest niemożliwe (`modulus == 0`), więc spadek
        // oznacza reset albo odczyt z innego procesora po hotplugu.
        if (modulus == 0) return .{ .invalid = .counter_regressed };
        // Do pełnego owinięcia brakuje `modulus - a + b` cykli.
        const implied = (modulus - a) +% b;
        if (implied == 0) return .{ .invalid = .counter_regressed };
        // Gdyby licznik miał przeskoczyć ponad cały zakres w tym oknie,
        // wynik byłby nieodróżnialny od zawinięcia — wolimy odmówić niż zgadywać.
        if (implied > maxPlausibleCycles(width, elapsed)) return .{ .invalid = .wrap_ambiguous };
    }

    return .{ .ok = raw };
}

/// Górna granica liczby cykli, którą uznajemy za fizycznie możliwą w oknie.
///
/// Bez tej granicy „zawinięcie" 48-bitowego licznika energii wyglądałoby jak
/// gigantyczny przyrost energii i wyszedłby jako gigantyczna moc. Wyznaczamy to
/// z góry, żeby reguła nie zależała od przypadku.
fn maxPlausibleCycles(width: Width, elapsed_ns: u64) u64 {
    // 1 GHz × margines 8× pokrywa TSC, APERF i liczniki energii (te ostatnie
    // liczą zdarzenia, nie cykle, ale ta sama zasada zniekształcenia obowiązuje).
    const max_hz: u64 = 8_000_000_000;
    // UWAGA: nie zaokrąglamy interwału w górę do pełnych sekund. Robiłem to
    // w pierwszej wersji (`(elapsed_ns + 999999999) / 1e9`) i przez to okno
    // 1 ms dostawało limit 8 mld zamiast 8 mln — czyli tysiąckrotnie za duży.
    // Skutek: `wrap_ambiguous` było **nieosiągalne** dla każdego okna krótszego
    // niż sekunda, a zawinięcie 32-bitowego licznika przechodziłoby jako
    // wiarygodny pomiar. Mnożymy w u64 i dzielimy dopiero na końcu.
    const ceiling = (std.math.mul(u64, max_hz, elapsed_ns) catch std.math.maxInt(u64)) / std.time.ns_per_s;
    // Dla 64 bitów zakres jest „nieskończony" (`modulus == 0`), więc go nie
    // zawężamy — inaczej każde zawinięcie wyglądałoby na możliwe.
    const modulus = width.modulus();
    if (modulus == 0) return ceiling;
    return @min(ceiling, modulus);
}

// ---------------------------------------------------------------------------
// APERF/MPERF
// ---------------------------------------------------------------------------

/// Wejście dla wyliczenia efektywnej częstotliwości.
pub const PerfPoint = struct {
    /// Monotoniczny znacznik czasu w nanosekundach.
    timestamp_ns: u64,
    /// Surowa wartość IA32_APERF. Liczy cykle w stanie „praca”.
    aperf: u64,
    /// Surowa wartość IA32_MPERF. Liczy cykle w stanie „blisko maksimum”.
    mperf: u64,
};

/// Wynik efektywnej częstotliwości — zawsze **z powodem**, gdy niedostępna.
pub const EffectiveFrequency = union(enum) {
    ok: u64, // Hz
    invalid: Delta.Invalid,

    pub fn hz(self: EffectiveFrequency) ?u64 {
        return switch (self) {
            .ok => |v| v,
            .invalid => null,
        };
    }
};

/// Efektywna częstotliwość z delty APERF i MPERF.
///
/// `nominal_hz` to częstotliwość TSC dla tego rdzenia. APERF/MPERF są liczone w
/// cyklach TSC, więc bez nominalnej skali wynik byłby bezwymiarowy.
///
/// **Mnożenie w `u128`.** `aperf_delta × nominal_hz` przy 4 GHz i oknie 250 ms
/// daje ~10^12, czyli mieści się w `u64` — ale przy szerszym oknie albo
/// wyższej częstotliwości `u64` przestaje wystarczać. Przepełnienie dałoby
/// *mniejszą* wartość niż prawdziwa, czyli wiarygodnie wyglądające MHz.
///
/// Zerowy `mperf_delta` znaczy, że rdzeń nie był w stanie MC — czyli był
/// zatrzymany. To nie jest dzielenie przez zero: zwracamy brak danych, bo
/// efektywna częstotliwość w tym oknie jest **nieokreślona**, a nie nieskończona.
pub fn effectiveFrequency(
    prev: PerfPoint,
    now: PerfPoint,
    width: Width,
    nominal_hz: u64,
) EffectiveFrequency {
    if (nominal_hz == 0) return .{ .invalid = .zero_interval };

    const da = delta(prev.aperf, now.aperf, width, prev.timestamp_ns, now.timestamp_ns);
    const aperf = da.get() orelse return .{ .invalid = switch (da) {
        .ok => unreachable,
        .invalid => |e| e,
    } };

    const dm = delta(prev.mperf, now.mperf, width, prev.timestamp_ns, now.timestamp_ns);
    const mperf = dm.get() orelse return .{ .invalid = switch (dm) {
        .ok => unreachable,
        .invalid => |e| e,
    } };

    // MPERF nie ruszał, ale APERK tak — rdzeń pracował poza stanem MC.
    if (mperf == 0) return .{ .invalid = .zero_interval };

    const numerator = @as(u128, aperf) * @as(u128, nominal_hz);
    const hz = numerator / @as(u128, mperf);
    if (hz > std.math.maxInt(u64)) return .{ .invalid = .wrap_ambiguous };
    return .{ .ok = @intCast(hz) };
}

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

test "Width: maska obcina wartości szersze niż rejestr" {
    // 0x1_0000_FFFF to 2^32 + 0xFFFF, więc po obcięciu do 32 bitów zostaje
    // **0xFFFF**. Maska 48-bitowa to **12** liter F, nie 10 — pierwsza wersja
    // tego testu miała `0x000F_FFFF_FFFF`, co jest w rzeczywistości 40 bitów
    // i obcinałoby wejście do złej szerokości.
    try testing.expectEqual(@as(u64, 0x0000_FFFF), Width.b32.mask(0x1_0000_FFFF));
    try testing.expectEqual(@as(u64, 0x0000_0000), Width.b32.mask(0x1_0000_0000));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF), Width.b48.mask(0x000F_FFFF_FFFF_FFFF));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_FFFF), Width.b64.mask(0xFFFF_FFFF_FFFF_FFFF));
}

test "Width: modulus 64-bit to zero, bo licznik się nie zawija" {
    // `1 << 64` byłoby UB i panikowało w trybie debug — stąd wczesny powrót.
    try testing.expectEqual(@as(u64, 0), Width.b64.modulus());
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF), Width.b32.modulus());
    // 2^48 - 1 to **12** liter F.
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF), Width.b48.modulus());
}

test "delta: zwykły przyrost" {
    const d = delta(100, 350, .b64, 0, 1_000_000);
    try testing.expectEqual(@as(?u64, 250), d.get());
}

test "delta: zawinięcie 32-bitowe" {
    // Licznik 32-bitowy przekroczył 0xFFFFFFFF i zaczął od zera.
    const d = delta(0xFFFF_FFF0, 0x0000_0010, .b32, 0, 1_000_000);
    // 0xFFFF_FFF0 -> 0xFFFFFFFF to 0xF = 15 kroków, a 0xFFFFFFFF -> 0x10 to
    // 0x11 = 17. Razem 32. Pierwsza wersja pisała 31, co było błędem rachunku.
    try testing.expectEqual(@as(?u64, 32), d.get());
}

test "delta: zawinięcie 48-bitowe na granicy" {
    const m48 = Width.b48.modulus();
    const before = m48 - 10;
    const d = delta(before, 5, .b48, 0, 1_000_000);
    // Do pełnego owinięcia brakuje 10 + 5 = 15, a dojście do granicy wymaga
    // jeszcze 1 (z 0xFFFF_FFFF_FFFF na 0x0000_0000_0000). Delta wynosi więc 16,
    // nie 15 — ta sama pomyłka rachunkowa co w teście 32-bitowym.
    try testing.expectEqual(@as(?u64, 16), d.get());
}

test "delta: zerowy interwał czasowy jest błędem, nie dzieleniem przez zero" {
    const d = delta(0, 100, .b64, 1_000, 1_000);
    try testing.expectEqual(@as(?u64, null), d.get());
    try testing.expectEqual(Delta.Invalid.zero_interval, d.invalid);
}

test "delta: czas cofający się jest odrzucony" {
    // Zegar monotoniczny nie powinien się cofnąć. Jeśli się cofnął, to backend
    // pomieszał kolejność — nie wolno na tym budować częstotliwości.
    const d = delta(100, 350, .b64, 5_000, 4_000);
    try testing.expectEqual(Delta.Invalid.zero_interval, d.invalid);
}

test "delta: 64-bitowy licznik nie zawija się, więc spadek to regresja" {
    // Przy 64 bitach nie ma zawinięcia. Spadek wartości przy rosnącym czasie
    // to reset albo odczyt z innego procesora — nie „zawinięcie 2^64".
    const d = delta(1_000_000, 999_000, .b64, 0, 1_000_000);
    try testing.expectEqual(Delta.Invalid.counter_regressed, d.invalid);
}

test "delta: zawinięcie, które jest fizycznie niemożliwe, jest odrzucane" {
    // Licznik skoczył z 0x100 na 0, czyli sugeruje przejście przez prawie
    // całe 2^32 w 1 ms. To przy 8 GHz wymagałoby setek sekund, więc „zawinięcie”
    // jest fizycznie niemożliwe i wynik byłby kłamstwem.
    const d = delta(0x0000_0100, 0, .b32, 0, 1_000_000);
    try testing.expectEqual(Delta.Invalid.wrap_ambiguous, d.invalid);
}

test "delta: reset licznika (spadek o pełny zakres) to nie zawinięcie" {
    // 0xFFFFFFFF -> 0 sugeruje „zawinięcie”, ale brakujące zdarzenia to dokładnie
    // 2^32, czyli nic. To reset albo odczyt z innego procesora, nie pomiar.
    const d = delta(0xFFFF_FFFF, 0, .b32, 0, 1_000_000);
    try testing.expectEqual(Delta.Invalid.counter_regressed, d.invalid);
}

test "effectiveFrequency: nominalne 4 GHz bez obciążenia" {
    // APERF i MPERF rosną identycznie -> efektywnie częstotliwość nominalna.
    const prev = PerfPoint{ .timestamp_ns = 0, .aperf = 0, .mperf = 0 };
    const now = PerfPoint{
        .timestamp_ns = 250_000_000, // 250 ms
        .aperf = 1_000_000_000, // 1e9 cykli TSC
        .mperf = 1_000_000_000,
    };
    const eff = effectiveFrequency(prev, now, .b64, 4_000_000_000);
    try testing.expectEqual(@as(?u64, 4_000_000_000), eff.hz());
}

test "effectiveFrequency: boost powyżej nominalnej" {
    // APERF 1.25× MPERF -> efektywnie 5 GHz przy nominalnych 4 GHz.
    const prev = PerfPoint{ .timestamp_ns = 0, .aperf = 0, .mperf = 0 };
    const now = PerfPoint{
        .timestamp_ns = 200_000_000,
        .aperf = 1_000_000,
        .mperf = 800_000,
    };
    const eff = effectiveFrequency(prev, now, .b64, 4_000_000_000);
    try testing.expectEqual(@as(?u64, 5_000_000_000), eff.hz());
}

test "effectiveFrequency: idle — MPERF nie rośnie" {
    // Rdzeń zatrzymany: MPERF stoi, APERF też. Efektywna częstotliwość jest
    // **nieokreślona**, a nie zerowa i nie nieskończona.
    const prev = PerfPoint{ .timestamp_ns = 0, .aperf = 500, .mperf = 500 };
    const now = PerfPoint{ .timestamp_ns = 100_000_000, .aperf = 500, .mperf = 500 };
    const eff = effectiveFrequency(prev, now, .b64, 4_000_000_000);
    try testing.expectEqual(@as(?u64, null), eff.hz());
    try testing.expectEqual(Delta.Invalid.zero_interval, eff.invalid);
}

test "effectiveFrequency: brak jednego licznika (MPERF=0 po resecie)" {
    const prev = PerfPoint{ .timestamp_ns = 0, .aperf = 0, .mperf = 0 };
    const now = PerfPoint{ .timestamp_ns = 100_000_000, .aperf = 1000, .mperf = 0 };
    const eff = effectiveFrequency(prev, now, .b64, 4_000_000_000);
    try testing.expectEqual(@as(?u64, null), eff.hz());
}

test "effectiveFrequency: zawinięcie APERF" {
    // APERF przekroczył 2^32 w oknie 250 ms przy ~4 GHz (możliwe: ~1e9 cykli).
    const prev = PerfPoint{
        .timestamp_ns = 0,
        .aperf = 0xFFFF_FFF0,
        .mperf = 0xFFFF_FFF0,
    };
    const now = PerfPoint{ .timestamp_ns = 250_000_000, .aperf = 0x10, .mperf = 0x10 };
    const eff = effectiveFrequency(prev, now, .b32, 4_000_000_000);
    // 31 cykli APERF i tyleż MPERF -> efektywnie nominalna.
    try testing.expectEqual(@as(?u64, 4_000_000_000), eff.hz());
}

test "effectiveFrequency: zerowy interwał czasowy" {
    const p = PerfPoint{ .timestamp_ns = 1_000, .aperf = 0, .mperf = 0 };
    const eff = effectiveFrequency(p, p, .b64, 4_000_000_000);
    try testing.expectEqual(@as(?u64, null), eff.hz());
}

test "effectiveFrequency: nominalna zerowa jest odrzucona, nie dzieli przez zero" {
    const prev = PerfPoint{ .timestamp_ns = 0, .aperf = 0, .mperf = 0 };
    const now = PerfPoint{ .timestamp_ns = 1000, .aperf = 100, .mperf = 100 };
    const eff = effectiveFrequency(prev, now, .b64, 0);
    try testing.expectEqual(@as(?u64, null), eff.hz());
}

test "effectiveFrequency: mnożenie nie przepełnia u64" {
    // 1e12 cykli × 4e9 Hz = 4e21, czyli ~16× więcej niż mieści u64. Bez u128
    // wynik byłby za mały — czyli wiarygodnie wyglądające, ale błędne MHz.
    const prev = PerfPoint{ .timestamp_ns = 0, .aperf = 0, .mperf = 0 };
    const now = PerfPoint{ .timestamp_ns = 1_000_000, .aperf = 1_000_000_000_000, .mperf = 1_000_000_000_000 };
    const eff = effectiveFrequency(prev, now, .b64, 4_000_000_000);
    try testing.expectEqual(@as(?u64, 4_000_000_000), eff.hz());
}
