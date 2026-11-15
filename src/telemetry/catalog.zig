//! Katalog metryk telemetrycznych FerrumScope.
//!
//! # Po co katalog
//!
//! Deskryptor opisuje metrykę **raz**, statycznie. Silnik, CLI i przyszłe GUI
//! czytają tę samą listę, więc definicja „effective frequency potrzebuje
//! APERF/MPERF" istnieje w jednym miejscu. Deskryptor opisuje **kontrakt**
//! (kategoria, jednostka, zakres, wymagane zdolności), a nie wynik — wynik to
//! `Sample`, który przychodzi z cyklu pollera.
//!
//! # Dlaczego część metryk jest „nieobsługiwana"
//!
//! Katalog wymienia to, co **chcemy** mierzyć, a `availability` mówi, co
//! backend potrafi. Kategoria `.temperature` istnieje w katalogu niezależnie od
//! tego, czy umiemy ją zmierzyć na danym sprzęcie.
//!
//! To celowe rozdzielenie. Gdyby katalog zawierał wyłącznie to, co działa,
//! brak pomiaru i brak pomysłu wyglądałyby identycznie — a to dwie zupełnie
//! różne sytuacje: „nie umiemy" to informacja dla użytkownika, „nie chcemy" to
//! luka w programie.
//!
//! ## Zasada: nie wymyślamy sensora
//!
//! Żadna metryka **nie** dostaje tu zmyślonego źródła odczytu. Jeśli potrzebuje
//! rejestru, którego znaczenia nie potwierdziliśmy w źródłach producenta
//! (temperatura AMD Zen, napięcie, prąd, status throttling), zostaje z
//! `vendor_support = .unverified`, a czytanie z niej **nie** może nic zwrócić.
//!
//! Wartości `unverified` zostały wyłącznie po to, żeby CLI mogło wypisać
//! „nieobsługiwane: potwierdzenie układu bitów" zamiast „0 °C".

const std = @import("std");
const i18n = @import("../i18n/i18n.zig");
const metrics = @import("metrics.zig");
const msr = @import("msr.zig");

/// Czy umiemy zinterpretować ten czujnik dla danego procesora.
pub const VendorSupport = enum {
    /// Znaczenie i układ bitów potwierdzone w źródle producenta.
    verified,
    /// Zgadujemy, czego nie potwierdziliśmy. Odczyt **nie** jest udostępniany.
    unverified,
    /// W ogóle nie ma takiego czujnika na tej platformie.
    absent,
};

/// Metryka razem z informacją, czy umiemy ją zmierzyć.
pub const Metric = struct {
    descriptor: metrics.Descriptor,
    /// Czy dekoder vendora potrafi zinterpretować surowe dane dla tego CPU.
    vendor_support: VendorSupport,
    /// Dlaczego `unverified` — widoczne w CLI, żeby „brak" nie był tajemnicą.
    /// Np. „temperatura AMD Zen: układ bitów niepotwierdzony w AMD PPR".
    reason: []const u8 = "",

    pub fn isAvailable(self: Metric, caps: msr.CapabilitySet) bool {
        return self.vendor_support == .verified and self.descriptor.isAvailable(caps);
    }

    /// Dlaczego metryka jest niedostępna — albo `null`, gdy jest dostępna.
    ///
    /// Rozróżniamy trzy przyczyny, bo każda oznacza co innego dla użytkownika:
    /// * brak zdolności backendu → potrzebny sterownik albo inny interwał,
    /// * niepotwierdzony czujnik → luka wiedzy, nie brak sprzętu,
    /// * brak czujnika na platformie → tu nic nie pomoże.
    pub fn unavailableReason(self: Metric, caps: msr.CapabilitySet) ?[]const u8 {
        if (self.isAvailable(caps)) return null;
        if (self.vendor_support == .absent) return i18n.t("brak czujnika na tej platformie");
        if (self.vendor_support == .unverified) return i18n.t(self.reason);
        // verified, ale brakuje zdolności. Wypisujemy **pierwszą** brakującą
        // zdolność, bo to ona jest powodem, a nie „brak dostępu" w ogóle.
        for (self.descriptor.required_capabilities) |c| {
            if (!caps.has(c)) return capabilityName(c);
        }
        return i18n.t("brak wymaganych zdolności backendu");
    }
};

/// Nazwa zdolności do raportu. Tekst jest tu, a nie w `msr.zig`, bo to
/// **prezentacja**, a `msr.zig` ma pozostać kontraktem bez warstwy tekstowej.
pub fn capabilityName(c: msr.Capability) []const u8 {
    return switch (c) {
        .msr_read => "MSR access unavailable",
        .per_cpu_msr_read => "per-CPU MSR access unavailable",
        .aperf_mperf => "APERF/MPERF unavailable",
        .energy_counter => "energy counter unavailable",
        .temperature_raw => "raw temperature register unavailable",
        .platform_utilization => "platform utilization unavailable",
    };
}

/// Nominalna częstotliwość w Hz. Wartość z bazy, nie zgadywana.
const base_hz: u64 = 3_800_000_000;
const interval_250ms: u64 = 250 * std.time.ns_per_ms;
const interval_1s: u64 = std.time.ns_per_s;

// ---------------------------------------------------------------------------
// Katalog
// ---------------------------------------------------------------------------

/// Metryki, które **potrafimy** mierzyć dzisiaj.
///
/// Katalog jest celowo krótki. Każda pozycja to deklaracja kontraktu, a nie
/// obietnica: wpis `verified` oznacza „mamy potwierdzone źródło i dekoder", a
/// niekoniecznie „każdy procesor to odczyta".
pub const metrics_available: []const Metric = &.{
    // --- efektywna częstotliwość --------------------------------------------
    // Jedyna metryka, którą umiemy dziś zmierzyć na obu architekturach:
    // APERF/MPERF jest potwierdzone i w Intel SDM, i w AMD APM.
    .{
        .descriptor = .{
            .id = "cpu.core.effective_frequency",
            .category = .effective_frequency,
            .unit = .hertz,
            .scope = .core,
            .source = .hardware,
            .preferred_interval_ns = interval_250ms,
            .required_capabilities = &.{.aperf_mperf},
            .label = "Effective Clock",
            .multi_instance = true,
        },
        .vendor_support = .verified,
    },
    .{
        .descriptor = .{
            .id = "cpu.core.frequency",
            .category = .frequency,
            .unit = .hertz,
            .scope = .core,
            .source = .hardware,
            .preferred_interval_ns = interval_250ms,
            .required_capabilities = &.{.msr_read},
            .label = "Base Clock",
            .multi_instance = true,
        },
        .vendor_support = .verified,
    },
    // --- energia / moc -------------------------------------------------------
    // RAPL jest potwierdzone w Intel SDM. Bez potwierdzonego źródła dla AMD
    // (`TSC_MSx` wymaga PPR per generacja) zostawiamy `unverified` zamiast
    // przeliczać na zgadywanych bitach.
    .{
        .descriptor = .{
            .id = "cpu.package.energy",
            .category = .energy,
            .unit = .microjoule,
            .scope = .package,
            .source = .hardware,
            .preferred_interval_ns = interval_1s,
            .required_capabilities = &.{.energy_counter},
            .label = "Package Energy",
        },
        .vendor_support = .unverified,
        .reason = i18n.N("energy counter: potwierdzone tylko dla Intel RAPL; brak potwierdzonego układu bitów dla AMD"),
    },
    .{
        .descriptor = .{
            .id = "cpu.package.power",
            .category = .power,
            .unit = .microwatt,
            .scope = .package,
            .source = .hardware,
            .preferred_interval_ns = interval_1s,
            .required_capabilities = &.{.energy_counter},
            .label = "Package Power",
        },
        .vendor_support = .unverified,
        .reason = i18n.N("package power: pochodzi z delty energii, której jeszcze nie potwierdziliśmy dla tego CPU"),
    },
    // --- temperatura ---------------------------------------------------------
    .{
        .descriptor = .{
            .id = "cpu.package.temperature",
            .category = .temperature,
            .unit = .millicelsius,
            .scope = .package,
            .source = .hardware,
            .preferred_interval_ns = interval_1s,
            .required_capabilities = &.{.temperature_raw},
            .label = "Package Temp",
        },
        .vendor_support = .unverified,
        .reason = i18n.N("temperature: układ bitów nie jest potwierdzony w AMD PPR — nie zgadujemy przesunięć"),
    },
    // --- napięcie / prąd -----------------------------------------------------
    .{
        .descriptor = .{
            .id = "cpu.core.voltage",
            .category = .voltage,
            .unit = .millivolt,
            .scope = .core,
            .source = .hardware,
            .preferred_interval_ns = interval_250ms,
            .required_capabilities = &.{.msr_read},
            .label = "Core Voltage",
            .multi_instance = true,
        },
        .vendor_support = .unverified,
        .reason = i18n.N("voltage: rejestr napięcia nie ma potwierdzonej maski bitowej w źródłach, którymi dysponujemy"),
    },
    .{
        .descriptor = .{
            .id = "cpu.core.current",
            .category = .current,
            .unit = .milliampere,
            .scope = .core,
            .source = .hardware,
            .preferred_interval_ns = interval_250ms,
            .required_capabilities = &.{.msr_read},
            .label = "Core Current",
            .multi_instance = true,
        },
        .vendor_support = .unverified,
        .reason = i18n.N("current: brak potwierdzonego rejestru prądu dla tej generacji"),
    },
    // --- obciążenie ----------------------------------------------------------
    .{
        .descriptor = .{
            .id = "cpu.logical.utilization",
            .category = .utilization,
            .unit = .percent,
            .scope = .logical_cpu,
            .source = .platform,
            .preferred_interval_ns = interval_1s,
            .required_capabilities = &.{.platform_utilization},
            .label = "Utilization",
            .multi_instance = true,
        },
        .vendor_support = .verified,
    },
    // --- throttling / limity -------------------------------------------------
    .{
        .descriptor = .{
            .id = "cpu.core.throttling",
            .category = .throttling,
            .unit = .none,
            .scope = .core,
            .source = .hardware,
            .preferred_interval_ns = interval_250ms,
            .required_capabilities = &.{.msr_read},
            .label = "Throttling",
            .multi_instance = true,
        },
        .vendor_support = .unverified,
        .reason = i18n.N("throttling: bity statusu nie są potwierdzone dla tej generacji"),
    },
    .{
        .descriptor = .{
            .id = "cpu.package.status",
            .category = .limit_status,
            .unit = .none,
            .scope = .package,
            .source = .hardware,
            .preferred_interval_ns = interval_1s,
            .required_capabilities = &.{.msr_read},
            .label = "Status",
        },
        .vendor_support = .unverified,
        .reason = i18n.N("status: rejestr statusu pakietu nie jest potwierdzony"),
    },
};

/// Buduje rejestr z katalogu. Jeden przebieg, alokacja raz przy starcie.
///
/// `Registry` przyjmuje `[]const Descriptor`, a katalog trzyma `Metric`, więc
/// rozwijamy listę raz — nie przy każdym odczycie.
pub fn buildRegistry(alloc: std.mem.Allocator) !metrics.Registry {
    const out = try alloc.alloc(metrics.Descriptor, metrics_available.len);
    for (metrics_available, out) |m, *d| d.* = m.descriptor;
    return .{ .items = out };
}

/// Metryka o podanym identyfikatorze.
pub fn find(id: []const u8) ?Metric {
    for (metrics_available) |m| {
        if (std.mem.eql(u8, m.descriptor.id, id)) return m;
    }
    return null;
}

/// Backend deklarujący **wszystkie** zdolności.
///
/// Używane w testach, żeby oddzielić dwa pytania: „nie mam dostępu" (brak
/// zdolności) od „nie umiem zinterpretować" (`unverified`). Przy pełnym zestawie
/// zdolności jedyną przyczyną niedostępności może być brak wiedzy.
pub fn allCapabilities() msr.CapabilitySet {
    var set = msr.CapabilitySet{};
    inline for (@typeInfo(msr.Capability).@"enum".fields) |fld| {
        set.add(@enumFromInt(fld.value));
    }
    return set;
}

const testing = std.testing;

test "katalog: wszystkie deskryptory przechodza walidacje" {
    // Deskryptor, którego `validate()` pada, byłby błędem programisty. Odrzucamy
    // go przy starcie programu, a nie przy pierwszym odczycie.
    for (metrics_available) |m| {
        try m.descriptor.validate();
    }
}

test "katalog: identyfikatory sa unikalne" {
    // Dwa wpisy o tym samym `id` nadpisałyby się nawzajem w mapie próbek — a
    // użytkownik zobaczyłby jedną wartość, nie wiedząc, że druga zniknęła.
    for (metrics_available, 0..) |a, i| {
        for (metrics_available[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.descriptor.id, b.descriptor.id));
        }
    }
}

test "katalog: unverified nigdy nie jest dostepne, nawet z petnym backendem" {
    const full = allCapabilities();

    var checked_unverified = false;
    for (metrics_available) |m| {
        if (m.vendor_support == .unverified) {
            checked_unverified = true;
            // Nawet backend ze wszystkimi zdolnościami **nie** wystarczy, bo
            // brakuje potwierdzonego układu bitów. To jest cała pointa bramki:
            // brak wiedzy nie da się zastąpić dostępem.
            try testing.expect(!m.isAvailable(full));
            try testing.expect(m.unavailableReason(full) != null);
        }
    }
    try testing.expect(checked_unverified);
}

test "katalog: brak zdolnosci unieznia tylko te metryki, ktore ich wymagaja" {
    var caps = msr.CapabilitySet{};
    caps.add(.aperf_mperf);

    const eff = find("cpu.core.effective_frequency").?;
    try testing.expect(eff.isAvailable(caps));

    // Ta sama metryka bez APERF jest niedostępna **z powodu** APERF, a nie
    // „z powodu braku dostępu" — komunikat ma prowadzić do konkretnej naprawy.
    try testing.expectEqualStrings("APERF/MPERF unavailable", eff.unavailableReason(.{}).?);

    const freq = find("cpu.core.frequency").?;
    try testing.expect(!freq.isAvailable(caps));
    try testing.expectEqualStrings("MSR access unavailable", freq.unavailableReason(caps).?);
}

test "katalog: powód niedostępności odróżnia brak sprzętu od braku wiedzy" {
    const caps = allCapabilities();

    const temp = find("cpu.package.temperature").?;
    // Pełny backend, a mimo to niedostępne — bo **nie umiemy**, nie dlatego,
    // że nie mamy dostępu. To dwie różne odpowiedzi dla użytkownika.
    try testing.expectEqualStrings(
        "temperature: układ bitów nie jest potwierdzony w AMD PPR — nie zgadujemy przesunięć",
        temp.unavailableReason(caps).?,
    );

    const util = find("cpu.logical.utilization").?;
    try testing.expect(util.isAvailable(caps));
    try testing.expect(util.unavailableReason(caps) == null);
}

test "katalog: interwaly sa z zakresu, ktory obsluguje silnik" {
    // Silnik testuje 100/250/500/1000 ms. Metryka spoza tej siatki jest
    // prawdopodobnie literowką w interwale, a nie świadomym wyborem.
    for (metrics_available) |m| {
        const ns = m.descriptor.preferred_interval_ns;
        try testing.expect(ns == 100 * std.time.ns_per_ms or
            ns == 250 * std.time.ns_per_ms or
            ns == 500 * std.time.ns_per_ms or
            ns == std.time.ns_per_s);
    }
}

test "katalog: efektywna czestotliwosc wymaga APERF i jest zwalidowana" {
    const eff = find("cpu.core.effective_frequency").?;
    try testing.expectEqual(metrics.Category.effective_frequency, eff.descriptor.category);
    try testing.expectEqual(metrics.Scope.core, eff.descriptor.scope);
    try testing.expect(eff.descriptor.multi_instance);
    try testing.expectEqual(@as(usize, 1), eff.descriptor.required_capabilities.len);
    try testing.expectEqual(msr.Capability.aperf_mperf, eff.descriptor.required_capabilities[0]);
    // Nazwa nominalna jest w katalogu, ale **nie** jest odczytem.
    _ = base_hz;
}
