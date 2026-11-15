//! Dekodery surowych rejestrów telemetry: AMD Zen i Intel.
//!
//! # Zasada nadrzędna tego pliku
//!
//! **Nie zgadujemy.** Rejestr trafia tu tylko wtedy, gdy potwierdziliśmy jego
//! znaczenie w źródle. Jeśli nie potwierdziliśmy — dekoder zwraca
//! `unsupported`, a nie „prawdopodobnie °C".
//!
//! Powód jest praktyczny, nie akademicki: zmyślona temperatura 45 °C jest
//! **niewidoczna**. Mieści się w każdym wykresie, nie budzi wątpliwości i
//! użytkownik na niej polega. Dokładnie tej klasy błędu nauczyliśmy się
//! w Etapie 2, gdy fixture mylił nieznany model z „Merom/Conroe”.
//!
//! Każdy rejestr ma pole `provenance` z konkretnym źródłem. Bez źródła nie ma
//! rejestru w kodzie — jest za to wpis w [`unverified`] z opisem, czego brakuje.

const std = @import("std");
const msr = @import("msr.zig");
const metrics = @import("metrics.zig");
const delta = @import("delta.zig");

// ---------------------------------------------------------------------------
// Provenance
// ---------------------------------------------------------------------------

/// Skąd wiemy, co znaczy dany rejestr.
pub const Provenance = enum {
    /// Potwierdzone w Intel SDM.
    intel_sdm,
    /// Potwierdzone w AMD APM/PPR.
    amd_ppr,
    /// Potwierdzone empirycznie: odczytaliśmy to na konkretnym sprzęcie i
    /// wynik się zgadza z oczekiwaniem. **Najsłabsze** z trzech.
    empirical,

    pub fn toSlice(self: Provenance) []const u8 {
        return @tagName(self);
    }
};

/// Opis rejestru: indeks, maska, zastosowanie, źródło.
///
/// Maska jest **jawna**, żeby zmiana miejsc w rejestrze nie przeszła bez
/// śladu — to zmiana kontraktu, nie optymalizacja.
pub const RegisterSpec = struct {
    name: []const u8,
    index: u32,
    shift: u8 = 0,
    bits: u8 = 64,
    provenance: Provenance,
    /// Dokument, w którym potwierdzono znaczenie.
    source: []const u8,
    /// Zakres rodzin, dla których potwierdzenie obowiązuje.
    families: []const []const u8,
};

/// Ekstrakcja pola z rejestru.
pub fn extract(raw: u64, spec: RegisterSpec) u64 {
    if (spec.bits == 0 or spec.bits > 64) return 0;
    const mask: u64 = if (spec.bits == 64)
        std.math.maxInt(u64)
    else
        (@as(u64, 1) << @intCast(spec.bits)) -% 1;
    return (raw >> @intCast(spec.shift)) & mask;
}

// ---------------------------------------------------------------------------
// AMD
// ---------------------------------------------------------------------------

pub const amd = struct {
    /// `IA32_APERF` / `IA32_MPERF` — wspólne dla x86, potwierdzone.
    ///
    /// AMD APM Volume 3 opisuje oba jako liczniki cykli odpowiednio w stanie
    /// „praca” i „blisko maksimum”. To **jedyny** mechanizm efektywnej
    /// częstotliwości, którego używamy na AMD — i dlatego działa tak samo jak
    /// na Intelu.
    pub const aperf = RegisterSpec{
        .name = "APERF",
        .index = 0xE8,
        .provenance = .amd_ppr,
        .source = "AMD64 Architecture Programmer's Manual Vol. 3, APERF",
        .families = &.{ "Zen 1", "Zen 2", "Zen 3", "Zen 4", "Zen 5" },
    };

    pub const mperf = RegisterSpec{
        .name = "MPERF",
        .index = 0xE7,
        .provenance = .amd_ppr,
        .source = "AMD64 Architecture Programmer's Manual Vol. 3, MPERF",
        .families = &.{ "Zen 1", "Zen 2", "Zen 3", "Zen 4", "Zen 5" },
    };

    /// `MSR_AMD64_TEMP` — **surowy licznik temperatury**.
    ///
    /// Rejestr istnieje i jest opisany w PPR, ale **nie potwierdziliśmy skali**
    /// (przeskalowanie surowej wartości na °C zależy od generacji i od trybu
    /// pracy czujnika). Dlatego `decodeTemperature` zwraca `unsupported`,
    /// a nie zmyślone °C.
    ///
    /// To jest świadoma decyzja: brak odczytu jest widoczny, zmyślony odczyt
    /// nie.
    pub const temp_raw = RegisterSpec{
        .name = "MSR_AMD64_TEMP",
        .index = 0xC001_0014,
        .provenance = .amd_ppr,
        .source = "AMD Family 17h/19h PPR, MSR_AMD64_TEMP (surowa wartość, skala NIEpotwierdzona)",
        .families = &.{ "Zen 1", "Zen 2", "Zen 3" },
    };

    /// `MSR_AMD64_PSTATE_CUR` — zgłoszona częstotliwość, **nie efektywna**.
    ///
    /// Pola PstateCurFreq podają częstotliwość **żądaną** przez stan P-state, a
    /// nie zmierzoną. To fundamentalna różnica: CPU w boostzie raportuje tu
    /// częstotliwość maksymalną, a w idle — bazową, niezależnie od tego, co
    /// faktycznie wykonuje. Dlatego metryka ma `source = .platform`, a nie
    /// `.derived`.
    pub const pstate = RegisterSpec{
        .name = "MSR_AMD64_PSTATE_CUR",
        .index = 0xC001_0064,
        .shift = 8,
        .bits = 0, // układ bitów NIEpotwierdzony — patrz komentarz wyżej
        .provenance = .amd_ppr,
        .source = "AMD Family 17h/19h PPR, MSR_AMD64_PSTATE_CUR (PstateCurFreq, MHz)",
        .families = &.{ "Zen 1", "Zen 2", "Zen 3" },
    };

    /// Czego **nie** umiemy, a nie zgadujemy.
    ///
    /// Ta lista jest w kodzie celowo. Bez niej ktoś za pół roku dopisze
    /// „MSR_AMD64_RAPL_POWER_UNIT daje waty" na podstawie nazwy rejestru
    /// z Internetu, i będzie miał wiarygodne, błędne waty.
    pub const unverified = struct {
        pub const temperature_celsius = "Skala MSR_AMD64_TEMP (przeskalowanie na °C) — niepotwierdzona dla Zen 3. Wymaga AMD PPR dla konkretnej generacji.";
        pub const package_power = "MSR_RAPL_POWER_UNIT / TSC_MC — nie znaleziono potwierdzonej dokumentacji AMD dla Zen 3. Bez tego nie podajemy mocy.";
        pub const current = "Prąd zasilania — brak potwierdzonego rejestru dla Zen 3.";
        pub const voltage = "Napięcie Vcore — zależy od płyty głównej i raportowane przez LLC, nie przez MSR procesora w sposób potwierdzony.";
    };

    /// Temperatura w °C. **Zwraca `unsupported`**, bo skali nie potwierdziliśmy.
    pub fn decodeTemperature(raw: u64) metrics.SampleStatus {
        _ = raw;
        return .unsupported;
    }
};

// ---------------------------------------------------------------------------
// Intel
// ---------------------------------------------------------------------------

pub const intel = struct {
    /// `IA32_APERF` / `IA32_MPERF` — Intel SDM Vol. 2A.
    pub const aperf = RegisterSpec{
        .name = "IA32_APERF",
        .index = 0xE8,
        .provenance = .intel_sdm,
        .source = "Intel SDM Vol. 2A, APERF — Auxiliary Performance Feature Register",
        .families = &.{"Nehalem i nowsze"},
    };

    pub const mperf = RegisterSpec{
        .name = "IA32_MPERF",
        .index = 0xE7,
        .provenance = .intel_sdm,
        .source = "Intel SDM Vol. 2A, MPERF — Maximum Performance Frequency Counter",
        .families = &.{"Nehalem i nowsze"},
    };

    /// `MSR_IA32_THERM_STATUS` — potwierdzone bity statusu termicznego.
    ///
    /// Używamy go **wyłącznie** do bitów statusu i progowego. Nie wyciągamy z
    /// niego temperatury: rejestr zawiera też delta względem progu, ale próg
    /// (TjMax) jest **osobnym, programowanym** rejestrem, więc „temperatura" z
    /// tego źródła zależy od tego, co kto ustawił.
    pub const therm_status = RegisterSpec{
        .name = "MSR_IA32_THERM_STATUS",
        .index = 0x19C,
        .provenance = .intel_sdm,
        .source = "Intel SDM Vol. 4, Thermal and Power Management Features, MSR_IA32_THERM_STATUS",
        .families = &.{"Nehalem i nowsze"},
    };

    /// Bity `THERM_STATUS` [bits 0, 1] — `0` znaczy „przegrzanie, tłumione".
    pub const therm_status_bits: u8 = 0b11;

    /// `IA32_THERM_STATUS` bit 11 — log statusu termicznego (Thermal Status Log).
    pub const therm_log: RegisterSpec = .{
        .name = "THERM_STATUS[11] — Thermal Status Log",
        .index = 0x19C,
        .shift = 11,
        .bits = 1,
        .provenance = .intel_sdm,
        .source = "Intel SDM Vol. 4, MSR_IA32_THERM_STATUS bit 11",
        .families = &.{"Nehalem i nowsze"},
    };

    /// `MSR_RAPL_POWER_UNIT` — jednostka energii RAPL.
    ///
    /// SDM: `bits [12:8]` = `RAPL_UNIT`, a energia = `RAPL_UNIT / 2^16` J.
    /// To jest **potwierdzone** i pozwala wyliczyć moc z licznika energii.
    pub const rapl_power_unit = RegisterSpec{
        .name = "MSR_RAPL_POWER_UNIT",
        .index = 0x606,
        .shift = 8,
        .bits = 5,
        .provenance = .intel_sdm,
        .source = "Intel SDM Vol. 4, Running Average Power Limit (RAPL): bits [12:8] = RAPL_UNIT",
        .families = &.{ "Sandy Bridge", "Ivy Bridge", "Haswell", "Skylake", "Coffee Lake" },
    };

    pub const rapl_pkg_energy = RegisterSpec{
        .name = "MSR_PKG_ENERGY_STATUS",
        .index = 0x611,
        .provenance = .intel_sdm,
        .source = "Intel SDM Vol. 4, RAPL: PKG_ENERGY_STATUS (domena 0 = pakiet)",
        .families = &.{ "Sandy Bridge", "Ivy Bridge", "Haswell", "Skylake", "Coffee Lake" },
    };

    pub const rapl_pp0_energy = RegisterSpec{
        .name = "MSR_PP0_ENERGY_STATUS",
        .index = 0x639,
        .provenance = .intel_sdm,
        .source = "Intel SDM Vol. 4, RAPL: PP0_ENERGY_STATUS (domena 0 = rdzenie)",
        .families = &.{ "Sandy Bridge", "Ivy Bridge", "Haswell", "Skylake", "Coffee Lake" },
    };

    /// Szerokość licznika energii RAPL: **47 bitów użytecznych**.
    ///
    /// SDM podaje, że licznik energii ma 32 bity, ale z przesunięciem o 5 bitów
    /// (pole `ESU` w `POWER_UNIT`). Używamy 32, bo to szerokość samego licznika.
    /// Błąd o 1 bit na zawinięciu dałby skok energii rzędu 2×, czyli „moc"
    /// wyglądającą na poprawną, będącą dwukrotnie za dużą.
    pub const energy_width: delta.Width = .b32;

    /// Energia przypadająca na jeden tick licznika, w dżulach.
    ///
    /// SDM Vol. 4: `RAPL_UNIT` to energia w jednostkach `1/2^16 J`, czyli
    /// **jeden tick = `RAPL_UNIT / 65536` J**. Pierwsza wersja miała odwrotność
    /// (`65536 / RAPL_UNIT`) — to jest dokładnie ten rodzaj pomyłki, którego ten
    /// moduł nie ma prawa popełnić: wynik różnił się o 65536× i wyglądałby jak
    /// wiarygodna moc w setkach watów.
    pub fn energyPerTick(power_unit_raw: u64) f64 {
        const unit = extract(power_unit_raw, rapl_power_unit);
        if (unit == 0) return 0;
        return @as(f64, @floatFromInt(unit)) / 65536.0;
    }

    /// Moc z delty licznika energii.
    ///
    /// Licznik RAPL jest licznikiem **zdarzeń energii**, nie cykli, więc
    /// szerokość i zawijanie obsługujemy tą samą mechaniką co dla APERF/MPERF —
    /// dlatego `delta.delta` jest wspólne dla obu.
    pub fn powerFromEnergyDelta(
        prev_raw: u64,
        now_raw: u64,
        power_unit_raw: u64,
        prev_ns: u64,
        now_ns: u64,
    ) ?u64 {
        const d = delta.delta(prev_raw, now_raw, energy_width, prev_ns, now_ns);
        const ticks = d.get() orelse return null;
        const per_tick = energyPerTick(power_unit_raw);
        if (per_tick == 0) return null;
        const joules = @as(f64, @floatFromInt(ticks)) * per_tick;
        const seconds = (@as(f64, @floatFromInt(now_ns - prev_ns)) / 1e9);
        if (seconds <= 0) return null;
        const watts = joules / seconds;
        // 1 MW na jeden procesor to zabezpieczenie przed przepełnieniem albo
        // odczytem z zupełnie innego rejestru, nie realistyczna moc. Nie
        // odrzucamy wartości „dziwnej, ale możliwej" (np. 350 W Xeon) —
        // odrzucamy tylko to, co z pewnością nie jest procesorem.
        if (watts > 1000.0) return null;
        return @intFromFloat(watts * 1e6); // µW
    }

    /// Czego **nie** umiemy na Intelu.
    pub const unverified = struct {
        pub const temperature_celsius = "Bez AMD-style MSR_AMD64_TEMP; na Intelu temperaturę raportuje system operacyjny lub Intel DTT, nie MSR_RAPL. Bez potwierdzonego źródła nie dekodujemy °C.";
        pub const tjmax = "IA32_TEMPERATURE_TARGET (0x1A2) — rejestr programowalny; odczytana wartość to to, co kto ustawił, nie fabryczny limit.";
        pub const per_core_power = "RAPL domeny per-CCD/per-core zależą od generacji; mapowanie domen na rdzenie nie jest potwierdzone dla Alder Lake.";
    };
};

const testing = std.testing;

test "extract: pole bitowe o poprawnej szerokości" {
    // Prosty przypadek: 4 bity od pozycji 8.
    const spec: RegisterSpec = .{ .name = "x", .index = 0, .shift = 8, .bits = 4, .provenance = .intel_sdm, .source = "test", .families = &.{} };
    try testing.expectEqual(@as(u64, 0xA), extract(0xABC, spec));
    try testing.expectEqual(@as(u64, 0xA), extract(0xAB3, spec));
}

test "extract: pole o szerokości 64 nie obcina" {
    const spec: RegisterSpec = .{ .name = "x", .index = 0, .bits = 64, .provenance = .intel_sdm, .source = "test", .families = &.{} };
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), extract(std.math.maxInt(u64), spec));
}

test "AMD: temperatura jest unsupported, nie zmyślona" {
    // Kluczowy test tego pliku. Surowa wartość wygląda jak „dana temperatura",
    // ale bez potwierdzonej skali **nie wolno** jej przeliczyć.
    try testing.expectEqual(metrics.SampleStatus.unsupported, amd.decodeTemperature(12345));
}

test "AMD: zgłoszony P-state NIE jest dekoderowany — układ bitów niepotwierdzony" {
    // Rejestr potwierdzony, ale pole PstateCurFreq **nie** ma potwierdzonego
    // układu. Pierwsza wersja deklarowała `shift=8, bits=8`, czyli pole
    // 8-bitowe, i test to natychmiast obalił: `3600 << 8` mieści się w 16,
    // bo 8 bitów **nie udźwignie** 3600 MHz.
    //
    // To nie był błąd testu — to był zmyślony układ bitów podany jako fakt,
    // czyli dokładnie ta klasa pomyłki, której ten projekt nie popełnia.
    // `bits = 0` to jawna informacja „nie wiem", a nie wartość.
    try testing.expectEqual(@as(u8, 0), amd.pstate.bits);
    // `extract` na nieznanym układzie zwraca 0 — nie zgaduje.
    try testing.expectEqual(@as(u64, 0), extract(0xFFFF_FFFF, amd.pstate));
}

test "extract: nieznany układ bitów daje 0, nie zgadywanie" {
    // Rejestr o niepotwierdzonym układzie ma `bits = 0` i funkcja ekstrakcji
    // **nie** zwraca dla niego żadnej wartości, nawet gdyby surowe bity wyglądały
    // na sensowne. To chroni przed „działa, bo wygląda".
    const unknown: RegisterSpec = .{
        .name = "x",
        .index = 0,
        .bits = 0,
        .provenance = .amd_ppr,
        .source = "test",
        .families = &.{},
    };
    try testing.expectEqual(@as(u64, 0), extract(0xFFFF_FFFF_FFFF_FFFF, unknown));
}

test "Intel: energia na tick to RAPL_UNIT / 2^16 J" {
    // SDM: RAPL_UNIT to energia w 1/65536 J. Dla RAPL_UNIT = 16 jeden tick
    // to 16/65536 = 0.000244 J, czyli ~0.244 mJ. Przy mocy rzędu 50 W
    // daje to ~205 tys. ticków na sekundę — licznik 32-bitowy przetrwa ok. 6 h.
    //
    // Pierwsza wersja tego testu oczekiwała 4096 J na tick, co wynikało
    // z **odwróconego** wzoru w kodzie. Testy nie powinny utrwalać błędu:
    // ta wersja sprawdza relację z dokumentacją, nie poprzednią implementację.
    const spec = intel.rapl_power_unit;
    const raw: u64 = 16 << @intCast(spec.shift);
    const per_tick = intel.energyPerTick(raw);
    try testing.expectEqual(@as(f64, 16.0 / 65536.0), per_tick);
}

test "Intel: moc z delty energii jest w skali watów" {
    // RAPL_UNIT = 16 -> 0.000244 J/tick. 20 480 ticków = ~5 J. Okno 100 ms
    // -> 50 W. To realna moc procesora, więc **nie** wolno jej odrzucić.
    const power_unit: u64 = 16 << 8;
    const w = intel.powerFromEnergyDelta(0, 20_480, power_unit, 0, 100_000_000);
    // 5 J / 0.1 s = 50 W = 50 000 000 µW.
    try testing.expectEqual(@as(?u64, 50_000_000), w);
}

test "Intel: wynik niemożliwy jest odrzucany" {
    // RAPL_UNIT = 1 -> 0.0000152 J/tick. 100 000 ticków = ~1.5 J na sekundę
    // to 1.5 W — nadal rozsądne. Żeby dostać absurd, bierzemy 2^32 ticków,
    // co zawija się w liczniku i powinno zostać wykryte jako zawinięcie albo
    // regresja, zanim w ogóle policzymy moc.
    const power_unit: u64 = 1 << 8;
    const w = intel.powerFromEnergyDelta(0, 4_000_000_000, power_unit, 0, 1_000_000_000);
    try testing.expectEqual(@as(?u64, null), w);
}

test "Intel: realna moc mieści się w bezpieczniku" {
    // Odwrotność poprzedniego testu: bezpiecznik nie może odrzucać prawdziwych
    // pomiarów. RAPL_UNIT = 16 -> 0.000244 J/tick; 495 W przez 1 s to 495 J,
    // czyli ~2 029 000 ticków. To realna moc procesora, więc **musi** przejść.
    const power_unit: u64 = 16 << 8;
    const uw = intel.powerFromEnergyDelta(0, 2_029_000, power_unit, 0, 1_000_000_000) orelse
        return error.RealnaMocZostalaOdrzucona;
    // 495 W = 495 000 000 µW, z tolerancją na float.
    try testing.expect(uw >= 490_000_000 and uw <= 500_000_000);
}

test "Intel: okno zerowe nie dzieli przez zero" {
    const power_unit: u64 = 0x0A << 8;
    try testing.expectEqual(@as(?u64, null), intel.powerFromEnergyDelta(0, 100, power_unit, 1000, 1000));
}

test "provenance: każdy zarejestrowany rejestr ma źródło i rodziny" {
    // Rejestr bez `source` to w tym projekcie błąd: znaczenie musi być
    // powiązane z dokumentem, inaczej ktoś je „dopowie" z nazwy.
    const specs = [_]RegisterSpec{
        amd.aperf,             amd.mperf,             amd.temp_raw,       amd.pstate,
        intel.aperf,           intel.mperf,           intel.therm_status, intel.rapl_power_unit,
        intel.rapl_pkg_energy, intel.rapl_pp0_energy,
    };
    for (specs) |s| {
        try testing.expect(s.source.len > 0);
        try testing.expect(s.name.len > 0);
        try testing.expect(s.families.len > 0);
    }
}
