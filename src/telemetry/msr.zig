//! Kontrakt dostępu do rejestrów modelu specyficznych (MSR) i deklaracji
//! możliwości platformy.
//!
//! ## Dlaczego to osobna warstwa
//!
//! Dekoder vendora **nie zna** WinAPI ani syscalli Linuksa. Zna wyłącznie
//! `readMsr(logical_cpu, msr_index)`. Dzięki temu ten sam decoder obsługuje
//! Windows przez sterownik, Linuks przez `/dev/cpu/*/msr` i testy przez backend
//! sztuczny — bez jednego `if (windows)` w kodzie dekodującym.
//!
//! ## Zasada: brak zapisu
//!
//! Ten moduł **nie udostępnia** zapisu do MSR. Zapis zmienia stan procesora i
//! nie ma uzasadnienia w narzędziu diagnostycznym. Gdyby kiedyś był potrzebny
//! (np. do kontrolowanego testu), dostanie **osobny, ograniczony** kontrakt —
//! nie dokładanie `writeMsr` obok `readMsr`.

const std = @import("std");

// ---------------------------------------------------------------------------
// Wynik odczytu MSR
// ---------------------------------------------------------------------------

/// Dlaczego odczyt się nie udał.
///
/// Rozdzielenie `unsupported` od `unavailable` ma znaczenie dla użytkownika:
/// `unsupported` znaczy „ten sprzęt tego nie ma i nie będzie miał” (pokazujemy
/// `—`), a `unavailable` znaczy „jest, ale teraz nie dało się odczytać”
/// (warto ponowić). Zlanie ich w jeden błąd kazałoby GUI odrzucić całą
/// metrykę, gdy jeden czujnik chwilowo zawiódł.
pub const MsrError = enum {
    /// Backend w ogóle nie obsługuje tego rejestru (np. Intel nie ma RAPL
    /// w takiej postaci na danej generacji).
    unsupported,
    /// Rejestr istnieje, ale odczyt chwilowo się nie powiódł.
    unavailable,
    /// Brak uprawnień. Na Windows: sterownik niezaładowany albo proces nie ma
    /// odpowiedniego tokenu. Na Linuksie: brak roota i brak `CAP_SYS_RAWIO`.
    permission_denied,
    /// Wskazany procesor logiczny jest offline.
    ///
    /// Osobno, bo numeracja `logical_cpu` **zmienia się** przy hotplugu i
    /// przy zmianach zarządzania energią. Licznik zapamiętany dla CPU 3
    /// przestaje być ważny, gdy CPU 3 zostanie wyłączony.
    cpu_offline,
    /// Błąd warstwy niżej: sterownik zwrócił `STATUS_*`, I/O się nie powiodło,
    /// upłynął limit czasu.
    backend_error,
};

/// Status odczytu. To **tagged union**, nie `enum` z polem: `enum` nie może
/// przechowywać wartości pola, a chcemy nie tylko rozróżnić „ok" od błędu, ale
/// też **przenieść przyczynę** — inaczej wywołujący musiałby mapować błędy
/// dwukrotnie (raz tu, raz w CLI).
pub const MsrStatus = union(enum) {
    ok,
    err: MsrError,

    pub fn isOk(self: MsrStatus) bool {
        return self == .ok;
    }
};

/// Wynik odczytu: status + wartość.
///
/// Rozdzielenie statusu od wartości zamiast `MsrError!u64` jest celowe — przy
/// `u64` nie da się przechować „nie ma rejestru" inaczej niż wartością
/// `error`, a błąd w chwili przesyłki jest nieodróżnialny od stanu trwałego.
pub const MsrRead = struct {
    status: MsrStatus = .{ .err = .unavailable },
    value: u64 = 0,

    pub fn ok(v: u64) MsrRead {
        return .{ .status = .ok, .value = v };
    }

    pub fn fail(e: MsrError) MsrRead {
        return .{ .status = .{ .err = e } };
    }

    /// Wartość albo `null`. Nigdy nie zwraca „0 przy błędzie" — to klasyczny
    /// sposób na ciche wyciągnięcie fałszywego odczytu temperatury.
    pub fn get(self: MsrRead) ?u64 {
        return if (self.status.isOk()) self.value else null;
    }
};

// ---------------------------------------------------------------------------
// Model możliwości
// ---------------------------------------------------------------------------

/// Zdolności backendu telemetry.
///
/// Lista jest zamknięta z rozmiarem, a nie otwarta na przyszłość: backend
/// deklaruje dokładnie to, co umie, a kod zapytujący sprawdza, czego wymaga.
/// Nowa zdolność = nowa wartość enumu = błąd kompilacji w miejscach, które
/// o niej nie wiedziały.
pub const Capability = enum {
    /// Odczyt dowolnego MSR dla podanego procesora logicznego.
    msr_read,
    /// Odczyt MSR **po wskazanym** procesorze logicznym (wymaga przypięcia
    /// wątku). Bez tego backend może czytać tylko dla CPU, na którym akurat
    /// działa wątek, co daje bezużyteczne wyniki per-core.
    per_cpu_msr_read,
    /// Liczniki APERF/MPERF (IA32, wspólne dla Intela i AMD od Zen).
    aperf_mperf,
    /// Licznik energii (RAPL na Intelu, TSC_MSx na AMD).
    energy_counter,
    /// Surowy rejestr temperatury (bez zinterpretowanej wartości w °C).
    temperature_raw,
    /// Wykorzystanie procesora raportowane przez system operacyjny.
    platform_utilization,

    const max = @typeInfo(Capability).@"enum".fields.len;
    pub const count = max;
};

pub const CapabilitySet = struct {
    bits: u16 = 0,

    pub fn has(self: CapabilitySet, c: Capability) bool {
        return self.bits & (@as(u16, 1) << @intFromEnum(c)) != 0;
    }

    pub fn add(self: *CapabilitySet, c: Capability) void {
        self.bits |= @as(u16, 1) << @intFromEnum(c);
    }

    pub fn addAll(self: *CapabilitySet, comptime T: []const Capability) void {
        inline for (T) |c| self.add(c);
    }

    /// Czy set zawiera **wszystkie** wymagane zdolności.
    pub fn satisfies(self: CapabilitySet, required: []const Capability) bool {
        for (required) |c| {
            if (!self.has(c)) return false;
        }
        return true;
    }
};

// ---------------------------------------------------------------------------
// Backend
// ---------------------------------------------------------------------------

/// Wspólny kontrakt backendu telemetry.
///
/// Implementacje: Windows (przez sterownik), Linux (`/dev/cpu/*/msr`),
/// replay (z capture), sztuczna (testy). Wszystkie implementują **ten sam**
/// interfejs, żeby dekoder nie wiedział, z której pochodzi.
pub const Backend = struct {
    pub const VTable = struct {
        /// Odczyt MSR dla wskazanego procesora logicznego.
        ///
        /// Backend **musi** zwracać `.cpu_offline`, gdy `logical_cpu` nie jest
        /// online, zamiast czytać cudzy rejestr. Cichy odczyt byłby groźniejszy
        /// niż brak odczytu: dałby wiarygodną liczbę z **innego** procesora.
        readMsr: *const fn (ctx: *anyopaque, logical_cpu: u16, msr: u32) MsrRead,

        /// Liczba procesorów logicznych **online** w tej chwili.
        ///
        /// Zmienia się przy hotplugu i przy zmianach zarządzania energią, dlatego
        /// silnik telemetry musi ją odczytywać przy każdym cyklu, a nie cache'ować
        /// na start.
        onlineCpuCount: *const fn (ctx: *anyopaque) u16,

        /// Zdolności backendu. Odczytywane raz — to deklaredzja, nie stan.
        capabilities: *const fn (ctx: *anyopaque) CapabilitySet,

        /// Monotoniczny czas w nanosekundach.
        ///
        /// **Obowiązkowo** monotoniczny. Zegar ściennyny (`GetSystemTimeAsFileTime`,
        /// `CLOCK_REALTIME`) cofa się przy synchronizacji NTP, a delta licznika
        /// na ujemnym interwale jest bez sensu — i cicho dawałaby zmyśloną
        /// częstotliwość.
        monotonicNanos: *const fn (ctx: *anyopaque) u64,

        /// Nazwa źródła do raportu: „amd-hardware", „intel-hardware",
        /// „synthetic", „replay". Użytkownik ma widzieć skąd liczba pochodzi.
        sourceName: *const fn (ctx: *anyopaque) []const u8,
    };

    vtable: *const VTable,
    ctx: *anyopaque,

    pub fn readMsr(self: Backend, logical_cpu: u16, msr: u32) MsrRead {
        return self.vtable.readMsr(self.ctx, logical_cpu, msr);
    }

    pub fn onlineCpuCount(self: Backend) u16 {
        return self.vtable.onlineCpuCount(self.ctx);
    }

    pub fn capabilities(self: Backend) CapabilitySet {
        return self.vtable.capabilities(self.ctx);
    }

    pub fn monotonicNanos(self: Backend) u64 {
        return self.vtable.monotonicNanos(self.ctx);
    }

    pub fn sourceName(self: Backend) []const u8 {
        return self.vtable.sourceName(self.ctx);
    }
};

// ---------------------------------------------------------------------------
// Rejestry
// ---------------------------------------------------------------------------

/// Rejestry, których znaczenie potwierdziliśmy w źródłach.
///
/// Nie ma tu rejestrów temperatury ani power dla AMD: znaczenia tych bitów **nie
/// potwierdziliśmy** w AMD PPR, a zgadywanie przesunięć i masek dałoby
/// wiarygodnie wyglądające, całkowicie zmyślone °C i W. Dopóki źródła nie ma,
/// rejestr nie istnieje w kodzie — dekoder zwraca `unsupported`.
pub const Msr = struct {
    // --- Wspólne dla x86 -----------------------------------------------------
    /// `IA32_APERF` — zlicza cykle wykonane w stanie „pracował” (AC).
    ///
    /// Źródło: Intel SDM Vol. 2A, "APERF — Auxiliary Performance Feature
    /// Register"; AMD APM Volume 3, "APERF".
    pub const aperf: u32 = 0xE8;

    /// `IA32_MPERF` — zlicza cykle w stanie „max/near max" (MC).
    ///
    /// Źródło: Intel SDM Vol. 2A, "MPERF — Maximum Performance Frequency
    /// Counter"; AMD APM Volume 3, "MPERF".
    pub const mperf: u32 = 0xE7;

    /// `IA32_TSC` — zegar referencyjny, stały w trakcie pracy rdzenia.
    /// Używany wyłącznie jako baza nominalnej częstotliwości.
    pub const tsc: u32 = 0x10;

    /// `IA32_THERM_STATUS` (Intel) — status termiczny i throttle.
    ///
    /// Źródło: Intel SDM Vol. 4, "Thermal and Power Management Features",
    /// MSR_IA32_THERM_STATUS. Używane **tylko** do bitów statusu i
    /// progowego, nie do odczytu temperatury w °C.
    pub const therm_status: u32 = 0x19C;

    /// `IA32_TEMP` (AMD Zen, familijnie `MSR_AMD64_TEMP`).
    ///
    /// Źródło: AMD Family 17h/19h PPR — rejestr temperatury, ale **jednostką
    /// jest surowy licznik**, a nie °C. Nie interpretujemy go: `raw` bez
    /// przeliczenia, dopóki nie potwierdzimy skali dla danej generacji.
    pub const amd_temp: u32 = 0xC001_0014;

    /// `MSR_AMD64_PSTATE_CUR` / `MSR_AMD64_PSTATE_BASE`.
    ///
    /// Źródło: AMD Family 17h/19h PPR. Zawiera MHz w polach PstateCurFreq /
    /// PstateMaxFreq. Używane jako **reported** clock, nie effective.
    pub const amd_pstate: u32 = 0xC001_0064;

    // --- RAPL (Intel) --------------------------------------------------------
    /// `MSR_RAPL_POWER_UNIT` — jednostka na RAPL.
    ///
    /// Źródło: Intel SDM Vol. 4, "Running Average Power Limit (RAPL)".
    /// Bits [12:8] = RAPL unit w watach = 2^unit/1e6 W.
    pub const rapl_power_unit: u32 = 0x606;

    /// `MSR_PKG_ENERGY_STATUS` (RAPL package, domena 0).
    pub const rapl_pkg_energy: u32 = 0x611;

    /// `MSR_PP0_ENERGY_STATUS` (RAPL core, domena 0).
    pub const rapl_pp0_energy: u32 = 0x639;
};

/// Czy indeks ma znaczenie **potwierdzone** w źródle.
pub fn isDocumented(index: u32) bool {
    return switch (index) {
        Msr.aperf, Msr.mperf, Msr.tsc, Msr.therm_status, Msr.rapl_power_unit, Msr.rapl_pkg_energy, Msr.rapl_pp0_energy => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Testy kontraktu
// ---------------------------------------------------------------------------

const testing = std.testing;

test "MsrRead: brak wartości przy błędzie, nigdy zero" {
    // Najważniejsza własność kontraktu: błąd **nie** zamienia się w 0.
    // Temperatura 0 °C to wynik, który zmieściłby się w każdym wykresie.
    const bad = MsrRead.fail(.permission_denied);
    try testing.expect(!bad.status.isOk());
    try testing.expectEqual(@as(?u64, null), bad.get());

    const good = MsrRead.ok(0);
    try testing.expect(good.status.isOk());
    try testing.expectEqual(@as(?u64, 0), good.get());
}

test "MsrError: każdy błąd jest odrębny od zera" {
    const all = [_]MsrError{ .unsupported, .unavailable, .permission_denied, .cpu_offline, .backend_error };
    for (all) |e| {
        try testing.expectEqual(@as(?u64, null), MsrRead.fail(e).get());
    }
}

test "CapabilitySet: brak zdolności blokuje tylko to, co jej wymaga" {
    var s = CapabilitySet{};
    s.add(.msr_read);
    try testing.expect(s.has(.msr_read));
    try testing.expect(!s.has(.energy_counter));

    // Metryka wymagająca energii jest niespełnialna...
    const need_energy = [_]Capability{.energy_counter};
    try testing.expect(!s.satisfies(&need_energy));
    // ...ale metryka oparta tylko na MSR nadal jest.
    const need_msr = [_]Capability{.msr_read};
    try testing.expect(s.satisfies(&need_msr));
}

test "CapabilitySet: brak wymaganych zdolności to pusty zbiór" {
    const s = CapabilitySet{};
    const required = [_]Capability{ .msr_read, .aperf_mperf };
    try testing.expect(!s.satisfies(&required));
}
