//! Backend telemetry do testów i replayu.
//!
//! ## Dlaczego to nie jest „specjalny tryb testowy”
//!
//! `FakeBackend` implementuje **ten sam** interfejs `msr.Backend`, co przyszły
//! sterownik Windows i `/dev/cpu/*/msr` na Linuksie. Dekoder nie wie, czy czyta
//! prawdziwy sprzęt, czy fake — i **nie może** wiedzieć. Jedyna różnica to
//! wartości w polach i to, że `sourceName` mówi „synthetic".
//!
//! Gdyby fake miał osobną ścieżkę w dekoderze, testy badałyby inną ścieżkę niż
//! produkcja. To najczęstszy sposób, w jaki testy przechodzą, a kod nie działa.

const std = @import("std");
const msr = @import("msr.zig");
const metrics = @import("metrics.zig");
const delta = @import("delta.zig");

// ---------------------------------------------------------------------------
// Scenariusze zachowania
// ---------------------------------------------------------------------------

/// Co backend ma zwracać dla danego rejestru.
///
/// Modelujemy to jako **zachowanie**, nie jako typ danych, bo celowo chcemy
/// zasymulować sytuacje, które w prawdziwym sprzęcie zdarzają się rzadko:
/// brak uprawnień po instalacji sterownika, CPU wyłączone przez plan oszczędzania.
pub const Behavior = union(enum) {
    /// Zawsze ta sama wartość.
    constant: u64,
    /// Wartość zależna od licznika odczytów — do testowania delty.
    incrementing: struct {
        start: u64 = 0,
        step: u64 = 1,
        /// Gdy `true`, licznik zawija się na podanej szerokości.
        wraps: bool = false,
        width: delta.Width = .b64,
    },
    /// Wartość zależna od czasu monotonicznego.
    time_ramped: struct {
        start: u64 = 0,
        per_second: u64 = 1_000_000,
    },
    /// Stały błąd: uprawnienia, brak rejestru, CPU offline.
    error_: msr.MsrError,
    /// Błąd tylko przez `count` pierwszych odczytów, potem wartość.
    /// Modeluje „sterownik się nie doczekał" i pojedyncze trzaśnięcia.
    flaky: struct {
        count: u32,
        err: msr.MsrError,
        then: u64,
    },
};

const RegisterState = struct {
    behavior: Behavior = .{ .constant = 0 },
    reads: u64 = 0,
};

pub const Options = struct {
    /// Liczba procesorów logicznych widzianych przez backend.
    cpu_count: u16 = 1,
    /// Zestaw deklarowanych zdolności. Puste = backend nie umie nic.
    capabilities: msr.CapabilitySet = .{},
    /// Zawartość rejestrów: `msr_index -> zachowanie`.
    registers: []const Register = &.{},
    /// Które procesory są offline. Backend ma zwracać `cpu_offline` dla nich.
    offline: []const u16 = &.{},
    /// Nazwa źródła w raporcie.
    source_name: []const u8 = "synthetic",
};

pub const Register = struct {
    msr_index: u32,
    behavior: Behavior,
};

pub const Backend = struct {
    options: Options,
    state: []RegisterState,
    /// Zegar monotoniczny. Testy ustawiają go jawnie (`advanceNanos`),
    /// żeby nie zależeć od szybkości maszyny.
    now_ns: u64 = 0,
    /// Liczba odczytów w całym backendzie — do raportowania wydajności.
    total_reads: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, options: Options) !Backend {
        const state = try alloc.alloc(RegisterState, options.registers.len);
        for (options.registers, state) |r, *s| s.* = .{ .behavior = r.behavior };
        return .{ .options = options, .state = state };
    }

    pub fn deinit(self: *Backend, alloc: std.mem.Allocator) void {
        alloc.free(self.state);
    }

    // --- sterowanie zegarem (testy) -----------------------------------------

    /// Przesuwa zegar monotoniczny. Symulowany backend **nie** czyta czasu
    /// systemu, bo wtedy wynik zależałby od tempa testu.
    pub fn advanceNanos(self: *Backend, ns: u64) void {
        self.now_ns +%= ns;
    }

    pub fn setNow(self: *Backend, ns: u64) void {
        self.now_ns = ns;
    }

    /// Liczba odczytów wykonanych od startu. Używana w pomiarach wydajności.
    pub fn reads(self: *const Backend) u64 {
        return self.total_reads;
    }

    // --- implementacja msr.Backend ------------------------------------------

    fn vtable() *const msr.Backend.VTable {
        const impl = struct {
            fn read(ctx: *anyopaque, logical_cpu: u16, index: u32) msr.MsrRead {
                const self: *Backend = @ptrCast(@alignCast(ctx));
                return self.readMsr(logical_cpu, index);
            }
            fn onlineCount(ctx: *anyopaque) u16 {
                const self: *const Backend = @ptrCast(@alignCast(ctx));
                return self.onlineCpuCount();
            }
            fn caps(ctx: *anyopaque) msr.CapabilitySet {
                const self: *const Backend = @ptrCast(@alignCast(ctx));
                return self.capabilities();
            }
            fn now(ctx: *anyopaque) u64 {
                const self: *const Backend = @ptrCast(@alignCast(ctx));
                return self.monotonicNanos();
            }
            fn name(ctx: *anyopaque) []const u8 {
                const self: *const Backend = @ptrCast(@alignCast(ctx));
                return self.sourceName();
            }
        };
        // Statyczny vtable: żyje tak długo jak program, a `ctx` wskazuje na
        // instancję. Bez alokacji przy każdym backendzie.
        return &struct {
            const t: msr.Backend.VTable = .{
                .readMsr = impl.read,
                .onlineCpuCount = impl.onlineCount,
                .capabilities = impl.caps,
                .monotonicNanos = impl.now,
                .sourceName = impl.name,
            };
        }.t;
    }

    pub fn api(self: *Backend) msr.Backend {
        return .{ .vtable = vtable(), .ctx = @ptrCast(self) };
    }

    pub fn readMsr(self: *Backend, logical_cpu: u16, index: u32) msr.MsrRead {
        self.total_reads += 1;

        if (logical_cpu >= self.options.cpu_count) {
            return msr.MsrRead.fail(.cpu_offline);
        }
        for (self.options.offline) |c| {
            if (c == logical_cpu) return msr.MsrRead.fail(.cpu_offline);
        }
        for (self.options.registers, self.state) |r, *s| {
            if (r.msr_index != index) continue;
            const n = s.reads;
            s.reads += 1;
            return self.valueFor(s.behavior, n);
        }
        return msr.MsrRead.fail(.unsupported);
    }

    fn valueFor(self: *const Backend, b: Behavior, n: u64) msr.MsrRead {
        // `self` jest potrzebne dla zachowania `time_ramped`, które zależy od
        // zegara backendu; pozostałe gałęzie go nie używają.
        return switch (b) {
            .constant => |v| msr.MsrRead.ok(v),
            .incrementing => |i| blk: {
                var v = i.start +% (i.step *% n);
                if (i.wraps) v = i.width.mask(v);
                break :blk msr.MsrRead.ok(v);
            },
            // Mnożymy **przed** dzieleniem, w u128. Kolejność ma znaczenie:
            // `self.now_ns / ns_per_s` to dzielenie całkowite, więc przy
            // `now_ns = 250 ms` dawałoby 0 — ramp stałby na miejscu przy
            // każdym interwale krótszym niż sekunda, a polowanie to 100..1000 ms,
            // czyli zawsze krócej. Delta APERF/MPERF nigdy by nie powstała.
            // u128 chroni przed przepełnieniem: `per_second * now_ns` dla
            // licznika 5 GHz po kilkudziesięciu sekundach przekracza u64.
            .time_ramped => |t| msr.MsrRead.ok(t.start +% @as(u64, @truncate(
                (@as(u128, t.per_second) * self.now_ns) / std.time.ns_per_s,
            ))),
            .error_ => |e| msr.MsrRead.fail(e),
            .flaky => |f| if (n < f.count) msr.MsrRead.fail(f.err) else msr.MsrRead.ok(f.then),
        };
    }

    pub fn onlineCpuCount(self: *const Backend) u16 {
        var n: u16 = 0;
        var i: u16 = 0;
        while (i < self.options.cpu_count) : (i += 1) {
            var is_offline = false;
            for (self.options.offline) |c| {
                if (c == i) {
                    is_offline = true;
                    break;
                }
            }
            if (!is_offline) n += 1;
        }
        return n;
    }

    pub fn capabilities(self: *const Backend) msr.CapabilitySet {
        return self.options.capabilities;
    }

    pub fn monotonicNanos(self: *const Backend) u64 {
        return self.now_ns;
    }

    pub fn sourceName(self: *const Backend) []const u8 {
        return self.options.source_name;
    }
};

const testing = std.testing;

fn apiFor(b: *Backend) msr.Backend {
    return b.api();
}

test "fake backend: poprawny odczyt MSR" {
    var caps: msr.CapabilitySet = .{};
    caps.add(.msr_read);
    var b = try Backend.init(testing.allocator, .{
        .cpu_count = 4,
        .capabilities = caps,
        .registers = &.{.{ .msr_index = msr.Msr.tsc, .behavior = .{ .constant = 0x1234 } }},
    });
    defer b.deinit(testing.allocator);

    const api = apiFor(&b);
    const r = api.readMsr(0, msr.Msr.tsc);
    try testing.expectEqual(@as(?u64, 0x1234), r.get());
}

test "fake backend: nieznany rejestr to unsupported, nie 0" {
    var caps: msr.CapabilitySet = .{};
    caps.add(.msr_read);
    var b = try Backend.init(testing.allocator, .{
        .cpu_count = 2,
        .capabilities = caps,
        .registers = &.{.{ .msr_index = msr.Msr.tsc, .behavior = .{ .constant = 1 } }},
    });
    defer b.deinit(testing.allocator);

    const api = apiFor(&b);
    // Rejestru spoza tabeli nie wolno zwracać jako 0 — 0 °C to wynik, który
    // zmieściłby się w każdym wykresie.
    const r = api.readMsr(0, 0xDEAD_BEEF);
    try testing.expectEqual(@as(?u64, null), r.get());
    try testing.expectEqual(msr.MsrError.unsupported, r.status.err);
}

test "fake backend: permission_denied" {
    var b = try Backend.init(testing.allocator, .{
        .cpu_count = 1,
        .registers = &.{.{ .msr_index = msr.Msr.aperf, .behavior = .{ .error_ = .permission_denied } }},
    });
    defer b.deinit(testing.allocator);

    const api = apiFor(&b);
    const r = api.readMsr(0, msr.Msr.aperf);
    try testing.expectEqual(msr.MsrError.permission_denied, r.status.err);
    try testing.expectEqual(@as(?u64, null), r.get());
}

test "fake backend: CPU offline — numer poza zakresem" {
    var b = try Backend.init(testing.allocator, .{ .cpu_count = 2, .registers = &.{} });
    defer b.deinit(testing.allocator);
    const api = apiFor(&b);
    try testing.expectEqual(msr.MsrError.cpu_offline, api.readMsr(5, msr.Msr.tsc).status.err);
}

test "fake backend: CPU offline — jawna lista offline" {
    // Hotplug: CPU 1 jest wyłączony. Backend ma zwrócić `cpu_offline`, a **nie**
    // czytać rejestru CPU 0 — cichy odczyt dałby wiarygodną liczbę z innego
    // procesora, i to jest groźniejsze niż brak odczytu.
    var caps: msr.CapabilitySet = .{};
    caps.add(.msr_read);
    var b = try Backend.init(testing.allocator, .{
        .cpu_count = 4,
        .capabilities = caps,
        .offline = &.{1},
        .registers = &.{.{ .msr_index = msr.Msr.tsc, .behavior = .{ .constant = 0xABCD } }},
    });
    defer b.deinit(testing.allocator);
    const api = apiFor(&b);
    try testing.expectEqual(msr.MsrError.cpu_offline, api.readMsr(1, msr.Msr.tsc).status.err);
    // Sąsiedzi działają normalnie.
    try testing.expectEqual(@as(?u64, 0xABCD), api.readMsr(2, msr.Msr.tsc).get());
    try testing.expectEqual(@as(u16, 3), api.onlineCpuCount());
}

test "fake backend: licznik rosnący daje sensowną deltę" {
    var b = try Backend.init(testing.allocator, .{
        .cpu_count = 1,
        .registers = &.{
            .{ .msr_index = msr.Msr.aperf, .behavior = .{ .incrementing = .{ .start = 1000, .step = 100 } } },
            .{ .msr_index = msr.Msr.mperf, .behavior = .{ .incrementing = .{ .start = 1000, .step = 100 } } },
        },
    });
    defer b.deinit(testing.allocator);
    const api = apiFor(&b);
    _ = api.readMsr(0, msr.Msr.aperf);
    _ = api.readMsr(0, msr.Msr.mperf);
    b.advanceNanos(100_000_000);
    const a1 = api.readMsr(0, msr.Msr.aperf);
    _ = api.readMsr(0, msr.Msr.mperf);
    try testing.expectEqual(@as(?u64, 1100), a1.get());
}

test "fake backend: time_ramped liczy w ulamku sekundy, nie w calkych sekundach" {
    // Regresja: rampa stala na miejscu przy kazdym interwale krotszym niz
    // sekunda, bo `now_ns / ns_per_s` dawalo zero. To psulo tryb syntetyczny
    // i --watch, bo delta APERF/MPERF nigdy nie powstala.
    const alloc = testing.allocator;
    var b = try Backend.init(alloc, .{
        .cpu_count = 1,
        .registers = &.{
            .{
                .msr_index = 0x100,
                .behavior = .{ .time_ramped = .{ .start = 0, .per_second = 2_000_000_000 } },
            },
        },
    });
    defer b.deinit(alloc);

    const v0 = b.readMsr(0, 0x100).get().?;
    b.advanceNanos(250 * std.time.ns_per_ms);
    const v1 = b.readMsr(0, 0x100).get().?;
    // 250 ms przy 2e9 cykli na sekunde to dokladnie 500 000 000 cykli.
    try testing.expectEqual(@as(u64, 500_000_000), v1 - v0);

    // Nastepne 750 ms musi dac dokladnie kolejne 1 500 000 000 — nie przeskok
    // o jeden "tick" i nie zaokraglenie do calej sekundy.
    b.advanceNanos(750 * std.time.ns_per_ms);
    const v2 = b.readMsr(0, 0x100).get().?;
    try testing.expectEqual(@as(u64, 1_500_000_000), v2 - v1);

    b.advanceNanos(std.time.ns_per_s);
    try testing.expect(b.readMsr(0, 0x100).get().? > v2);
}

test "fake backend: licznik zawijający" {
    var b = try Backend.init(testing.allocator, .{
        .cpu_count = 1,
        .registers = &.{.{ .msr_index = msr.Msr.tsc, .behavior = .{ .incrementing = .{ .start = 0, .step = 1 << 30, .wraps = true, .width = .b32 } } }},
    });
    defer b.deinit(testing.allocator);
    const api = apiFor(&b);
    // Krok 2^30 przy rejestrze 32-bitowym. Wartości dla n=0..4 to:
    //   0, 1<<30, 1<<31, 3<<30, 4<<30 -> po masce 32-bit: ostatnie zero.
    // `3 << 30` = 0xC0000000 **mieści się** w 32 bitach, więc maska go nie
    // zeruje — dopiero czwarte mnożenie przekracza zakres. Pierwsza wersja
    // tego testu oczekiwała zera na czwartym odczycie, co było błędem rachunku.
    try testing.expectEqual(@as(?u64, 0), api.readMsr(0, msr.Msr.tsc).get());
    try testing.expectEqual(@as(?u64, 1 << 30), api.readMsr(0, msr.Msr.tsc).get());
    try testing.expectEqual(@as(?u64, 1 << 31), api.readMsr(0, msr.Msr.tsc).get());
    try testing.expectEqual(@as(?u64, 3 << 30), api.readMsr(0, msr.Msr.tsc).get());
    // n=4 -> 4 * 2^30 = 2^32, przekracza zakres 32-bitowy i jest maskowane do zera.
    try testing.expectEqual(@as(?u64, 0), api.readMsr(0, msr.Msr.tsc).get());
}

test "fake backend: czujnik chwilowo niedostępny, potem działa" {
    var b = try Backend.init(testing.allocator, .{
        .cpu_count = 1,
        .registers = &.{.{ .msr_index = msr.Msr.aperf, .behavior = .{ .flaky = .{ .count = 2, .err = .unavailable, .then = 77 } } }},
    });
    defer b.deinit(testing.allocator);
    const api = apiFor(&b);
    try testing.expectEqual(msr.MsrError.unavailable, api.readMsr(0, msr.Msr.aperf).status.err);
    try testing.expectEqual(msr.MsrError.unavailable, api.readMsr(0, msr.Msr.aperf).status.err);
    // Po dwóch niepowodzeniach backend w końcu odpowiada — silnik nie może się
    // wyłączyć po pojedynczym błędzie.
    try testing.expectEqual(@as(?u64, 77), api.readMsr(0, msr.Msr.aperf).get());
}

test "fake backend: zegar jest jawny, nie zależy od maszyny" {
    var b = try Backend.init(testing.allocator, .{ .cpu_count = 1 });
    defer b.deinit(testing.allocator);
    const api = apiFor(&b);
    try testing.expectEqual(@as(u64, 0), api.monotonicNanos());
    b.advanceNanos(250_000_000);
    try testing.expectEqual(@as(u64, 250_000_000), api.monotonicNanos());
}

test "fake backend: licznik odczytów dla pomiarów wydajności" {
    var b = try Backend.init(testing.allocator, .{
        .cpu_count = 2,
        .registers = &.{.{ .msr_index = msr.Msr.tsc, .behavior = .{ .constant = 1 } }},
    });
    defer b.deinit(testing.allocator);
    const api = apiFor(&b);
    try testing.expectEqual(@as(u64, 0), b.reads());
    _ = api.readMsr(0, msr.Msr.tsc);
    _ = api.readMsr(1, msr.Msr.tsc);
    try testing.expectEqual(@as(u64, 2), b.reads());
}
