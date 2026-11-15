//! Vendor-neutral model metryk dynamicznych.
//!
//! Model jest celowo **niezależny od platformy**: zakłada, że ktoś może zmierzyć
//! zegary, temperatury, moc i prąd na dowolnym układzie. Nie kodujemy „AMD
//! ma temperaturę w tym rejestrze" ani „Intel ma tu 16 rdzeni" — to są decyzje
//! backendów i dekoderów, nie formatu danych.
//!
//! ## Dlaczego `source` jest osobnym polem
//!
//! Bo `Memory Temperature: 45 °C` i `Memory Temperature: 45 °C` (z cache
//! CPU) to **nie** ta sama informacja. Pole `source` mówi, skąd liczba
//! pochodzi: z hardware, z platformy, z estymacji, czy z brand stringu. Bez
//! niego użytkownik nie ma jak ocenić, czy może jej ufać.

const std = @import("std");
const msr = @import("msr.zig");
const delta = @import("delta.zig");

// ---------------------------------------------------------------------------
// Klasyfikacja
// ---------------------------------------------------------------------------

/// Co opisuje metryka. Lista zamknięta, żeby CLI i przyszłe GUI mogły się po
/// niej poruszać bez zgadywania nazw.
pub const Category = enum {
    frequency,
    effective_frequency,
    temperature,
    voltage,
    power,
    energy,
    utilization,
    current,
    throttling,
    limit_status,

    pub fn toSlice(self: Category) []const u8 {
        return @tagName(self);
    }
};

/// Do czego się metryka odnosi.
///
/// Hierarchia odpowiada temu, jak sprzęt rzeczywiście jest zorganizowany
/// (część AMD ma CCD, część Intel ma pakiet z rdzeniami hybrydowymi), ale nie
/// zakłada, że **jakikolwiek** układ ma wszystkie poziomy. Metryka o zakresie
/// `.ccd` po prostu nie istnieje na procesorze bez CCD.
pub const Scope = enum {
    system,
    package,
    die,
    ccd,
    core,
    logical_cpu,

    pub fn toSlice(self: Scope) []const u8 {
        return @tagName(self);
    }
};

/// Jednostka. `none` dla metryk, które nie są liczbą (np. status throttling).
pub const Unit = enum {
    hertz,
    millicelsius,
    millivolt,
    microwatt,
    microjoule,
    percent,
    milliampere,
    bits_per_second,
    none,

    /// Przeskok do czytelnej jednostki: Hz -> MHz, W -> mW.
    /// Wartość zostaje w bazowej jednostce, to tylko sposób pokazania.
    pub fn scale(self: Unit) f64 {
        return switch (self) {
            .hertz => 1e-6,
            .millicelsius => 1e-3,
            .millivolt => 1e-3,
            .microwatt => 1e-6,
            .microjoule => 1e-6,
            .percent => 1e-2,
            .milliampere => 1e-3,
            .bits_per_second, .none => 1.0,
        };
    }

    pub fn toSlice(self: Unit) []const u8 {
        return @tagName(self);
    }
};

/// Skąd pochodzi wartość.
pub const Source = enum {
    /// Odczyt rejestru sprzętowego.
    hardware,
    /// Wartość zgłoszona przez system operacyjny (np. wykorzystanie CPU).
    platform,
    /// Obliczona z innych pomiarów (np. efektywna częstotliwość z APERF/MPERF).
    derived,
    /// Wydedukowana z brand stringu — **nie** z CPUID. Np. „3D V-Cache”
    /// dla 5800X3D, bo 5800X i 5800X3D mają identyczną sygnaturę CPUID.
    brand_derived,
    /// Wartość z testu lub z capture — nie pochodzi z prawdziwego sprzętu.
    synthetic,

    pub fn toSlice(self: Source) []const u8 {
        return @tagName(self);
    }

    /// Czy wartość reprezentuje **prawdziwy sprzęt**.
    ///
    /// Używane przez CLI do oznaczenia wyników testowych, żeby nie dało się
    /// pomylić odczytu z fake backendu z rzeczywistym pomiarem.
    pub fn isRealHardware(self: Source) bool {
        return self == .hardware or self == .platform;
    }
};

/// Status pojedynczej próbki.
///
/// Rozróżnienie `unavailable` od `unsupported` wraca z kontraktu MSR i tu ma
/// sens: `unsupported` znaczy „nie będzie nigdy", `unavailable` znaczy „spróbuj
/// później". CLI pokazuje je inaczej.
pub const SampleStatus = enum {
    ok,
    /// Metryka istnieje, ale odczyt się nie powiódł.
    unavailable,
    /// Sprzęt tego nie obsługuje.
    unsupported,
    /// Brak uprawnień (sterownik, root).
    permission_denied,
    /// Procesor logiczny offline.
    cpu_offline,
    /// Wyliczenie niemożliwe: zły interwał, zawinięcie, brak jednego licznika.
    invalid,
    /// Próba wyprodukowana z danych syntetycznych/replay.
    synthetic,

    pub fn toSlice(self: SampleStatus) []const u8 {
        return @tagName(self);
    }
};

// ---------------------------------------------------------------------------
// Deskryptor
// ---------------------------------------------------------------------------

/// Opis metryki — deklaracja, nie pomiar.
///
/// Oddzielenie deskryptora od próbki pozwala cache'ować stabilne metadane
/// (jednostka, zakres, wymagane zdolności) i nie odczytywać ich przy każdym
/// odświeżeniu. To ma znaczenie wydajnościowe: deskryptor jest stały, próbki
/// przychodzą co 100 ms.
pub const Descriptor = struct {
    /// Stabilny identyfikator, np. `"cpu.package.temperature"`. Używany jako
    /// klucz w mapie i w CLI, więc musi być znaczny, nie generowany z kolejności.
    id: []const u8,
    category: Category,
    unit: Unit,
    scope: Scope,
    source: Source,
    /// Zalecany interwał odświeżania w nanosekundach. Sugestia, nie przymus —
    /// wolniejszy czujnik nie potrzebuje 100 ms.
    preferred_interval_ns: u64,
    /// Zdolności, bez których metryka nie powstaje. Pusta lista = metryka
    /// nie potrzebuje backendu (np. liczona z innych metryk).
    required_capabilities: []const msr.Capability = &.{},
    /// Etykieta do UI, np. „Package". Osobna od `id`, bo `id` jest maszynowy.
    label: []const u8 = "",
    /// Czy wartość dotyczy całego systemu, czy pojedynczej instancji.
    /// Wielowątkowe metryki (temperatura per rdzeń) mają wiele instancji.
    multi_instance: bool = false,

    /// Walidacja deskryptora. Wykonana raz przy rejestracji, nie przy każdym
    /// odczycie — błędny deskryptor to błąd programisty, nie dane.
    ///
    /// Sprawdzamy to, co faktycznie psuje prezentację: pusty identyfikator
    /// (kolizje w mapie) i interwał zerowy (pętla bez końca).
    pub fn validate(self: Descriptor) !void {
        if (self.id.len == 0) return error.EmptyId;
        if (self.preferred_interval_ns == 0) return error.ZeroInterval;
        if (self.source == .hardware and self.required_capabilities.len == 0) {
            // Metryka sprzętowa bez wymaganych zdolności oznaczałaby, że każdy
            // backend ją „wspiera", choć żaden nie umie jej odczytać.
            return error.HardwareMetricWithoutCapabilities;
        }
    }

    /// Czy backend o podanych zdolnościach może tę metrykę obsłużyć.
    pub fn isAvailable(self: Descriptor, caps: msr.CapabilitySet) bool {
        return caps.satisfies(self.required_capabilities);
    }
};

// ---------------------------------------------------------------------------
// Próbkа
// ---------------------------------------------------------------------------

/// Pojedynczy pomiar z zawsze obecnym timestampem.
pub const Sample = struct {
    metric_id: []const u8,
    timestamp_ns: u64,
    status: SampleStatus,
    /// Wartość w jednostce `Descriptor.unit`. `0` przy błędzie jest **bezpieczne
    /// tylko dlatego**, że status nie pozwala jej odczytać jako prawdziwej.
    value: u64 = 0,
    /// Uwagi dodatkowe: przyczyna błędu, jednostka alternatywna, ostrzeżenie.
    detail: []const u8 = "",

    /// Wartość albo `null`. Ścieżka bezpieczna: kod, który nie sprawdzi statusu,
    /// dostanie `null` zamiast zmyślonej liczby.
    pub fn get(self: Sample) ?u64 {
        return if (self.status == .ok or self.status == .synthetic) self.value else null;
    }

    pub fn isValid(self: Sample) bool {
        return self.get() != null;
    }
};

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

/// Rejestr deskryptorów: jeden wątek odczytuje, wszyscy patrzą.
///
/// Silnik nie skanuje sprzętu przy każdym odświeżeniu — deskryptory są
/// stabilne i rejestrowane raz, przy inicjalizacji. To rozdzielenie
/// „inwentaryzacja statyczna" od „odczyty dynamiczne" jest wymagane wprost przez
/// plan Etapu 3.
pub const Registry = struct {
    items: []const Descriptor = &.{},

    pub fn find(self: Registry, id: []const u8) ?Descriptor {
        for (self.items) |d| {
            if (std.mem.eql(u8, d.id, id)) return d;
        }
        return null;
    }

    /// Deskryptory, które backend potrafi obsłużyć. Te pozostałe **nie są
    /// błędem** — po prostu nie powstają.
    pub fn availableFor(self: Registry, caps: msr.CapabilitySet, alloc: std.mem.Allocator) ![]Descriptor {
        var list: std.ArrayList(Descriptor) = .empty;
        errdefer list.deinit(alloc);
        for (self.items) |d| {
            if (d.isAvailable(caps)) try list.append(alloc, d);
        }
        return list.toOwnedSlice(alloc);
    }
};

const testing = std.testing;

test "Descriptor: pusty identyfikator to błąd" {
    // Pusty `id` kolidowałby w mapie próbek — dwa różne odczyty trafiłyby
    // pod ten sam klucz i jeden nadpisałby drugi po cichu.
    const d: Descriptor = .{
        .id = "",
        .category = .temperature,
        .unit = .millicelsius,
        .scope = .package,
        .source = .hardware,
        .preferred_interval_ns = 250_000_000,
        .required_capabilities = &.{.msr_read},
    };
    try testing.expectError(error.EmptyId, d.validate());
}

test "Descriptor: zerowy interwał to błąd" {
    // Interwał 0 = ciasna pętla bez końca. Odrzucamy przy rejestracji,
    // a nie przy pierwszym ticku.
    const d: Descriptor = .{
        .id = "cpu.freq",
        .category = .frequency,
        .unit = .hertz,
        .scope = .core,
        .source = .hardware,
        .preferred_interval_ns = 0,
        .required_capabilities = &.{},
    };
    try testing.expectError(error.ZeroInterval, d.validate());
}

test "Descriptor: metryka sprzętowa musi deklarować zdolności" {
    // Bez `required_capabilities` każdy backend uważałby ją za obsługiwaną —
    // także taki, który nie ma ani jednego MSR. Potem brak odczytu wyglądałby
    // jak „czujnik zawiódł", zamiast „nie ma takiego czujnika”.
    const d: Descriptor = .{
        .id = "cpu.package.temp",
        .category = .temperature,
        .unit = .millicelsius,
        .scope = .package,
        .source = .hardware,
        .preferred_interval_ns = 250_000_000,
    };
    try testing.expectError(error.HardwareMetricWithoutCapabilities, d.validate());
}

test "Descriptor: poprawny deskryptor przechodzi" {
    const d: Descriptor = .{
        .id = "cpu.package.temperature",
        .category = .temperature,
        .unit = .millicelsius,
        .scope = .package,
        .source = .hardware,
        .preferred_interval_ns = 250_000_000,
        .required_capabilities = &.{ .msr_read, .temperature_raw },
    };
    try d.validate();
}

test "Descriptor: brak zdolności blokuje tylko tę metrykę" {
    const temp: Descriptor = .{
        .id = "cpu.package.temperature",
        .category = .temperature,
        .unit = .millicelsius,
        .scope = .package,
        .source = .hardware,
        .preferred_interval_ns = 250_000_000,
        .required_capabilities = &.{ .msr_read, .temperature_raw },
    };
    const freq: Descriptor = .{
        .id = "cpu.core.effective_frequency",
        .category = .effective_frequency,
        .unit = .hertz,
        .scope = .core,
        .source = .derived,
        .preferred_interval_ns = 100_000_000,
        .required_capabilities = &.{.aperf_mperf},
    };

    var caps: msr.CapabilitySet = .{};
    caps.add(.msr_read);
    caps.add(.aperf_mperf);

    // Backend bez `temperature_raw` nie da temperatury...
    try testing.expect(!temp.isAvailable(caps));
    // ...ale efektywną częstotliwość policzy, bo ma APERF/MPERF.
    try testing.expect(freq.isAvailable(caps));
}

test "Sample: błąd nigdy nie zamienia się w wartość" {
    const bad: Sample = .{ .metric_id = "x", .timestamp_ns = 1, .status = .permission_denied, .value = 0 };
    try testing.expectEqual(@as(?u64, null), bad.get());
    try testing.expect(!bad.isValid());
}

test "Sample: wartość syntetyczna jest czytelna, ale nie jest sprzętem" {
    const syn: Sample = .{ .metric_id = "x", .timestamp_ns = 1, .status = .synthetic, .value = 65_000 };
    try testing.expectEqual(@as(?u64, 65_000), syn.get());
    // Źródło nadal decyduje, czy to prawdziwy pomiar.
    try testing.expect(!Source.synthetic.isRealHardware());
    try testing.expect(Source.hardware.isRealHardware());
    try testing.expect(!Source.brand_derived.isRealHardware());
}

test "Registry: brak zdolności nie jest błędem, tylko pustą listą" {
    const reg: Registry = .{ .items = &.{
        .{
            .id = "cpu.package.temperature",
            .category = .temperature,
            .unit = .millicelsius,
            .scope = .package,
            .source = .hardware,
            .preferred_interval_ns = 250_000_000,
            .required_capabilities = &.{ .msr_read, .temperature_raw },
        },
    } };
    const caps: msr.CapabilitySet = .{};
    const got = try reg.availableFor(caps, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "Registry: znalezienie po identyfikatorze" {
    const reg: Registry = .{ .items = &.{
        .{
            .id = "cpu.package.temperature",
            .category = .temperature,
            .unit = .millicelsius,
            .scope = .package,
            .source = .hardware,
            .preferred_interval_ns = 250_000_000,
            .required_capabilities = &.{.msr_read},
        },
    } };
    try testing.expect(reg.find("cpu.package.temperature") != null);
    try testing.expectEqual(@as(?Descriptor, null), reg.find("nie.ma.takiego"));
}

test "Unit: skala do jednostki czytelnej" {
    try testing.expectEqual(@as(f64, 1e-6), Unit.hertz.scale());
    try testing.expectEqual(@as(f64, 1e-3), Unit.millicelsius.scale());
}
