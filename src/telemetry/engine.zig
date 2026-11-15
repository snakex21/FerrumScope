//! Silnik metryk: planowanie odczytów, grupowanie, anulowanie.
//!
//! ## Po co silnik, skoro można czytać w pętli
//!
//! Bo **grupowanie**. Szesnaście metryk „effective clock, core 0..15" potrzebuje
//! tego samego odczytu APERF/MPERF dla tego samego rdzenia, a pakiet i TSC
//! liczone są raz na pakiet. Bez cache'u w obrębie cyklu jeden cykl 100 ms na
//! 16-rdzeniowym CPU robiłby ~50 odczytów MSR zamiast ~19. Na Windows odczyt
//! MSR to przejście do jądra, więc to nie jest optymalizacja, tylko warunek
//! użyteczności.
//!
//! ## Inwentaryzacja statyczna jest osobno
//!
//! Silnik **nie skanuje sprzętu**. Deskryptory metryk są stabilne i podawane z
//! zewnątrz; skan topologii i cache to zadanie `probe`. Dzięki temu odświeżanie
//! czujników co 100 ms nie pociąga za sobą ponownego CPUID.
//!
//! ## Awaria jednego czujnika nie zatrzymuje silnika
//!
//! Każdy poller zwraca `Sample` z własnym statusem. Błąd jednego czujnika to
//! jeden `Sample.status = .unavailable`, a nie wyjątek przerywający cały cykl.

const std = @import("std");
const msr = @import("msr.zig");
const metrics = @import("metrics.zig");
const delta = @import("delta.zig");

// ---------------------------------------------------------------------------
// Czytnik z cache'em
// ---------------------------------------------------------------------------

/// Wynik odczytu z informacją, czy trafił do cache'u.
const CachedRead = struct {
    read: msr.MsrRead,
    /// Czy ta wartość pochodzi z cache'u w obrębie bieżącego cyklu.
    from_cache: bool,
};

const CacheSlot = struct {
    logical_cpu: u16,
    msr_index: u32,
    read: msr.MsrRead = .{},
    filled: bool = false,
};

/// Czytnik z cache'em w obrębie **jednego cyklu**.
///
/// Cache jest zerowany na początku cyklu (`beginCycle`). Bez tego wartości
/// sprzed wielu cykli wyglądałyby jak świeże, a delta z APERF/MPERF nigdy by
/// nie powstała.
pub const Reader = struct {
    api: msr.Backend,
    slots: []CacheSlot,
    filled: usize = 0,

    pub fn init(alloc: std.mem.Allocator, api: msr.Backend, capacity: usize) !Reader {
        const slots = try alloc.alloc(CacheSlot, capacity);
        for (slots) |*s| s.* = .{ .logical_cpu = 0, .msr_index = 0 };
        return .{ .api = api, .slots = slots };
    }

    pub fn deinit(self: *Reader, alloc: std.mem.Allocator) void {
        alloc.free(self.slots);
    }

    /// Wyczyszczenie cache na początku cyklu.
    pub fn beginCycle(self: *Reader) void {
        for (self.slots) |*s| s.filled = false;
        self.filled = 0;
    }

    /// Odczyt z cache'em w obrębie cyklu. Pełny odczyt trafia do slotu;
    /// **błędy nie są cache'owane** — chcemy, żeby następna metryka w tym samym
    /// cyklu spróbowała sama, bo brak uprawnień jest stały, a `unavailable` bywa
    /// chwilowe.
    pub fn read(self: *Reader, logical_cpu: u16, index: u32) CachedRead {
        for (self.slots) |s| {
            if (s.filled and s.logical_cpu == logical_cpu and s.msr_index == index) {
                return .{ .read = s.read, .from_cache = true };
            }
        }
        const r = self.api.readMsr(logical_cpu, index);
        if (r.status.isOk() and self.filled < self.slots.len) {
            self.slots[self.filled] = .{
                .logical_cpu = logical_cpu,
                .msr_index = index,
                .read = r,
                .filled = true,
            };
            self.filled += 1;
        }
        return .{ .read = r, .from_cache = false };
    }

    /// Liczba faktycznych odczytów backendu w bieżącym cyklu.
    pub fn backendReads(self: *const Reader) usize {
        return self.filled;
    }
};

// ---------------------------------------------------------------------------
// Poller
// ---------------------------------------------------------------------------

/// Funkcja produkująca jedną próbkę.
///
/// Zwraca `Sample`, nigdy nie rzuca. Błąd czujnika to `status`, nie wyjątek —
/// inaczej jeden wadliwy czujnik wywracałby cały cykl.
pub const Poller = struct {
    /// Deskryptor, którego dotyczy poller. Silnik używa go do harmonogramu.
    descriptor: metrics.Descriptor,
    /// Wskazanie instancji: rdzeń, CPU, pakiet. Dla metryk `multi_instance`
    /// poller jest uruchamiany raz na instancję.
    instance: u16 = 0,
    /// Funkcja odczytu. `ctx` to stan specyficzny dla dekodera (np. poprzednia
    /// próbka APERF/MPERF).
    read: *const fn (
        ctx: *anyopaque,
        reader: *Reader,
        descriptor: metrics.Descriptor,
        instance: u16,
        now_ns: u64,
    ) metrics.Sample,
    /// Kontekst dla `read`. Silnik go nie interpretuje.
    ///
    /// Domyślnie wskazuje na zmienną modułu, a nie na `const`: `@ptrCast` z
    /// `*const T` na `*anyopaque` gubi kwalifikator `const`, więc placeholder
    /// musi być modyfikowalny. Poller bez stanu i tak nic z tego nie czyta.
    ctx: *anyopaque = &no_ctx,
};

/// Placeholder dla pollera, który nie potrzebuje stanu.
var no_ctx: u8 = 0;

// ---------------------------------------------------------------------------
// Silnik
// ---------------------------------------------------------------------------

pub const Engine = struct {
    reader: Reader,
    pollers: []const Poller,
    alloc: std.mem.Allocator,
    /// Ostatnia próbka każdego pollera, indeksowana jak `pollers`.
    last: []metrics.Sample,
    /// Anulowanie. Ustawiane przez `cancel()`; `poll()` po anulowaniu zwraca
    /// natychmiast i nie czyta hardware.
    cancelled: bool = false,
    /// Licznik cykli — do raportowania, nie do logiki.
    cycles: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, api: msr.Backend, pollers: []const Poller, cache_capacity: usize) !Engine {
        var r = try Reader.init(alloc, api, cache_capacity);
        errdefer r.deinit(alloc);
        const last = try alloc.alloc(metrics.Sample, pollers.len);
        for (last) |*s| s.* = .{ .metric_id = "", .timestamp_ns = 0, .status = .unsupported };
        return .{
            .reader = r,
            .pollers = pollers,
            .alloc = alloc,
            .last = last,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.reader.deinit(self.alloc);
        self.alloc.free(self.last);
    }

    /// Żądanie zakończenia. Silnik nie zatrzymuje się w miejscu — kończy bieżący
    /// cykl i nie zaczyna następnego. Nagłe przerwanie w połowie odczytu
    /// zostawiłoby cache w niespójnym stanie.
    pub fn cancel(self: *Engine) void {
        self.cancelled = true;
    }

    pub fn isCancelled(self: *const Engine) bool {
        return self.cancelled;
    }

    /// Czy dana metryka jest obsługiwana przez ten backend.
    ///
    /// Brak zdolności **nie jest błędem** — metryka po prostu nie powstaje, a
    /// inne działają dalej. To jest dokładnie przypadek, o który prosi plan:
    /// „brak jednego sensora nie może psuć całego metrics engine".
    pub fn isSupported(self: *const Engine, d: metrics.Descriptor) bool {
        return d.isAvailable(self.reader.api.capabilities());
    }

    /// Wykonuje jeden cykl odczytu i zwraca próbki.
    ///
    /// Zwraca **tyle** próbek, ile jest włączonych pollers. Każda ma timestamp
    /// z tego samego momentu, więc porównanie metryk w jednym klatce jest
    /// spójne.
    pub fn poll(self: *Engine, now_ns: u64) []metrics.Sample {
        if (self.cancelled) return self.last;
        self.cycles += 1;
        self.reader.beginCycle();

        for (self.pollers, self.last, 0..) |p, *slot, i| {
            if (!self.isSupported(p.descriptor)) {
                // Brak zdolności: metryka nie powstaje, ale cykl trwa.
                slot.* = .{
                    .metric_id = p.descriptor.id,
                    .timestamp_ns = now_ns,
                    .status = .unsupported,
                    .detail = "brak wymaganej zdolności backendu",
                };
                continue;
            }
            slot.* = p.read(p.ctx, &self.reader, p.descriptor, p.instance, now_ns);
            _ = i;
        }
        return self.last;
    }

    /// Ostatnia próbka po identyfikatorze metryki.
    pub fn sample(self: *const Engine, id: []const u8) ?metrics.Sample {
        for (self.last) |s| {
            if (std.mem.eql(u8, s.metric_id, id)) return s;
        }
        return null;
    }

    /// Liczba odczytów backendu w ostatnim cyklu — do pomiarów wydajności.
    pub fn backendReadsLastCycle(self: *const Engine) usize {
        return self.reader.backendReads();
    }
};

// ---------------------------------------------------------------------------
// Wbudowane pollery
// ---------------------------------------------------------------------------

/// Stan pollera efektywnej częstotliwości: poprzednia próbka APERF/MPERF.
pub const FreqState = struct {
    /// Nominalna częstotliwość TSC w Hz. Wartość stała dla danego CPU.
    nominal_hz: u64,
    /// Szerokość licznika APERF/MPERF.
    width: delta.Width = .b64,
    /// Poprzednia para odczytów per CPU.
    prev: []delta.PerfPoint,
    /// Czy dany CPU miał już pierwszą próbkę. Bez tego pierwszy cykl zwracałby
    /// „brak danych", co jest poprawne, ale mylące w CLI — odróżniamy to polem
    /// `detail`.
    seen: []bool,

    pub fn init(alloc: std.mem.Allocator, nominal_hz: u64, cpu_count: u16, width: delta.Width) !FreqState {
        const prev = try alloc.alloc(delta.PerfPoint, cpu_count);
        for (prev) |*p| p.* = .{ .timestamp_ns = 0, .aperf = 0, .mperf = 0 };
        const seen = try alloc.alloc(bool, cpu_count);
        @memset(seen, false);
        return .{ .nominal_hz = nominal_hz, .width = width, .prev = prev, .seen = seen };
    }

    pub fn deinit(self: *FreqState, alloc: std.mem.Allocator) void {
        alloc.free(self.prev);
        alloc.free(self.seen);
    }
};

/// Poller efektywnej częstotliwości z APERF/MPERF.
///
/// Pierwsze wywołanie dla danego CPU **nie** produkuje liczby: potrzebne są
/// dwie próbki. Zwraca wtedy status `invalid` z powodem, nie `0 Hz`.
pub fn pollEffectiveFrequency(
    ctx: *anyopaque,
    reader: *Reader,
    d: metrics.Descriptor,
    instance: u16,
    now_ns: u64,
) metrics.Sample {
    const st: *FreqState = @ptrCast(@alignCast(ctx));

    if (instance >= st.prev.len) {
        return .{ .metric_id = d.id, .timestamp_ns = now_ns, .status = .cpu_offline };
    }

    const a = reader.read(instance, msr.Msr.aperf).read;
    const m = reader.read(instance, msr.Msr.mperf).read;

    const av = a.get() orelse return statusFrom(d, now_ns, a.status, "APERF niedostępny");
    const mv = m.get() orelse return statusFrom(d, now_ns, m.status, "MPERF niedostępny");

    if (!st.seen[instance]) {
        st.prev[instance] = .{ .timestamp_ns = now_ns, .aperf = av, .mperf = mv };
        st.seen[instance] = true;
        return .{
            .metric_id = d.id,
            .timestamp_ns = now_ns,
            .status = .invalid,
            .detail = "pierwsza próbka: efektywna częstotliwość potrzebuje dwóch punktów",
        };
    }

    const eff = delta.effectiveFrequency(st.prev[instance], .{
        .timestamp_ns = now_ns,
        .aperf = av,
        .mperf = mv,
    }, st.width, st.nominal_hz);

    st.prev[instance] = .{ .timestamp_ns = now_ns, .aperf = av, .mperf = mv };

    return switch (eff) {
        .ok => |hz| .{ .metric_id = d.id, .timestamp_ns = now_ns, .status = .ok, .value = hz },
        .invalid => |e| .{
            .metric_id = d.id,
            .timestamp_ns = now_ns,
            .status = .invalid,
            .detail = @tagName(e),
        },
    };
}

fn statusFrom(d: metrics.Descriptor, now: u64, st: msr.MsrStatus, detail: []const u8) metrics.Sample {
    const s: metrics.SampleStatus = switch (st) {
        .ok => .ok, // nieuzywane: wywołujący sprawdził wcześniej
        .err => |e| switch (e) {
            .unsupported => .unsupported,
            .unavailable => .unavailable,
            .permission_denied => .permission_denied,
            .cpu_offline => .cpu_offline,
            .backend_error => .unavailable,
        },
    };
    return .{ .metric_id = d.id, .timestamp_ns = now, .status = s, .detail = detail };
}

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

const testing = std.testing;
const fake = @import("fake.zig");

const desc_eff = metrics.Descriptor{
    .id = "cpu.core.effective_frequency",
    .category = .effective_frequency,
    .unit = .hertz,
    .scope = .core,
    .source = .derived,
    .preferred_interval_ns = 100_000_000,
    .required_capabilities = &.{.aperf_mperf},
};

fn setupState(cpu_count: u16) !FreqState {
    return FreqState.init(testing.allocator, 4_000_000_000, cpu_count, .b64);
}

test "silnik: brak zdolności nie blokuje całego cyklu" {
    // Backend **bez** APERF/MPERF. Poller efektywnej częstotliwości nie może
    // powodować ani wyjątku, ani przerwania — dostaje status i idziemy dalej.
    var b = try fake.Backend.init(testing.allocator, .{ .cpu_count = 2 });
    defer b.deinit(testing.allocator);
    var st = try setupState(2);
    defer st.deinit(testing.allocator);

    const pollers = [_]Poller{.{ .descriptor = desc_eff, .ctx = @ptrCast(&st), .read = pollEffectiveFrequency }};
    var e = try Engine.init(testing.allocator, b.api(), &pollers, 16);
    defer e.deinit();

    const out = e.poll(1_000);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqual(metrics.SampleStatus.unsupported, out[0].status);
    try testing.expectEqual(@as(?u64, null), out[0].get());
    // Cykl się wykonał, silnik żyje.
    try testing.expectEqual(@as(u64, 1), e.cycles);
}

test "silnik: jedna metryka bez zdolności nie psuje innej" {
    var caps: msr.CapabilitySet = .{};
    caps.add(.aperf_mperf);
    var b = try fake.Backend.init(testing.allocator, .{
        .cpu_count = 1,
        .capabilities = caps,
        .registers = &.{
            .{ .msr_index = msr.Msr.aperf, .behavior = .{ .incrementing = .{ .step = 1000 } } },
            .{ .msr_index = msr.Msr.mperf, .behavior = .{ .incrementing = .{ .step = 1000 } } },
        },
    });
    defer b.deinit(testing.allocator);
    var st = try setupState(1);
    defer st.deinit(testing.allocator);

    // Druga metryka wymaga energii, której backend nie ma.
    const desc_energy: metrics.Descriptor = .{
        .id = "cpu.package.energy",
        .category = .energy,
        .unit = .microjoule,
        .scope = .package,
        .source = .hardware,
        .preferred_interval_ns = 1000,
        .required_capabilities = &.{.energy_counter},
    };
    const pollers = [_]Poller{
        .{ .descriptor = desc_eff, .ctx = @ptrCast(&st), .read = pollEffectiveFrequency },
        .{ .descriptor = desc_energy, .read = pollAlwaysUnsupported },
    };
    var e = try Engine.init(testing.allocator, b.api(), &pollers, 16);
    defer e.deinit();

    b.advanceNanos(100_000_000);
    const out = e.poll(b.monotonicNanos());
    _ = b.advanceNanos(100_000_000);
    const out2 = e.poll(b.monotonicNanos());

    // Metryka energii: unsupported. Efektywna częstotliwość: działa.
    try testing.expectEqual(metrics.SampleStatus.unsupported, out2[1].status);
    try testing.expect(out2[0].get() != null);
    _ = out;
}

fn pollAlwaysUnsupported(
    ctx: *anyopaque,
    reader: *Reader,
    d: metrics.Descriptor,
    instance: u16,
    now_ns: u64,
) metrics.Sample {
    _ = ctx;
    _ = reader;
    _ = instance;
    return .{ .metric_id = d.id, .timestamp_ns = now_ns, .status = .unsupported };
}

test "silnik: efektywna częstotliwość potrzebuje dwóch próbek" {
    var caps: msr.CapabilitySet = .{};
    caps.addAll(&.{ .aperf_mperf, .msr_read });
    var b = try fake.Backend.init(testing.allocator, .{
        .cpu_count = 1,
        .capabilities = caps,
        .registers = &.{
            .{ .msr_index = msr.Msr.aperf, .behavior = .{ .incrementing = .{ .step = 1000 } } },
            .{ .msr_index = msr.Msr.mperf, .behavior = .{ .incrementing = .{ .step = 1000 } } },
        },
    });
    defer b.deinit(testing.allocator);
    var st = try setupState(1);
    defer st.deinit(testing.allocator);

    const pollers = [_]Poller{.{ .descriptor = desc_eff, .ctx = @ptrCast(&st), .read = pollEffectiveFrequency }};
    var e = try Engine.init(testing.allocator, b.api(), &pollers, 16);
    defer e.deinit();

    // Pierwszy cykl: tylko zapamiętanie punktu, bez liczby.
    const first = e.poll(0);
    try testing.expectEqual(metrics.SampleStatus.invalid, first[0].status);
    try testing.expectEqual(@as(?u64, null), first[0].get());

    // Drugi cykl: mamy deltę.
    b.advanceNanos(100_000_000);
    const second = e.poll(b.monotonicNanos());
    try testing.expectEqual(metrics.SampleStatus.ok, second[0].status);
    // APERF i MPERF rosną tak samo -> efektywnie nominalne 4 GHz.
    try testing.expectEqual(@as(?u64, 4_000_000_000), second[0].get());
}

test "silnik: anulowanie kończy odczyty" {
    var caps: msr.CapabilitySet = .{};
    caps.add(.aperf_mperf);
    var b = try fake.Backend.init(testing.allocator, .{
        .cpu_count = 1,
        .capabilities = caps,
        .registers = &.{
            .{ .msr_index = msr.Msr.aperf, .behavior = .{ .incrementing = .{} } },
            .{ .msr_index = msr.Msr.mperf, .behavior = .{ .incrementing = .{} } },
        },
    });
    defer b.deinit(testing.allocator);
    var st = try setupState(1);
    defer st.deinit(testing.allocator);

    const pollers = [_]Poller{.{ .descriptor = desc_eff, .ctx = @ptrCast(&st), .read = pollEffectiveFrequency }};
    var e = try Engine.init(testing.allocator, b.api(), &pollers, 16);
    defer e.deinit();

    _ = e.poll(0);
    const reads_before = b.reads();
    e.cancel();
    try testing.expect(e.isCancelled());
    _ = e.poll(1_000);

    // Po anulowaniu **żaden** odczyt backendu nie powinien się odbyć.
    try testing.expectEqual(reads_before, b.reads());
    // Licznik cykli nie rośnie — silnik jest zatrzymany, nie tylko wyciszony.
    try testing.expectEqual(@as(u64, 1), e.cycles);
}

test "silnik: cache grupuje odczyty w obrębie cyklu" {
    var caps: msr.CapabilitySet = .{};
    caps.add(.aperf_mperf);
    var b = try fake.Backend.init(testing.allocator, .{
        .cpu_count = 1,
        .capabilities = caps,
        .registers = &.{
            .{ .msr_index = msr.Msr.aperf, .behavior = .{ .incrementing = .{} } },
            .{ .msr_index = msr.Msr.mperf, .behavior = .{ .incrementing = .{} } },
        },
    });
    defer b.deinit(testing.allocator);
    var st = try setupState(1);
    defer st.deinit(testing.allocator);

    var r = try Reader.init(testing.allocator, b.api(), 16);
    defer r.deinit(testing.allocator);

    r.beginCycle();
    // Ten sam rejestr, ten sam CPU, wiele razy.
    _ = r.read(0, msr.Msr.aperf);
    _ = r.read(0, msr.Msr.aperf);
    const third = r.read(0, msr.Msr.aperf);
    // Backend wykonał **jeden** odczyt, pozostałe z cache'u.
    try testing.expectEqual(@as(u64, 1), b.reads());
    try testing.expect(third.from_cache);

    // Inny rejestr to osobny odczyt.
    _ = r.read(0, msr.Msr.mperf);
    try testing.expectEqual(@as(u64, 2), b.reads());

    // Nowy cykl czyści cache.
    r.beginCycle();
    _ = r.read(0, msr.Msr.aperf);
    try testing.expectEqual(@as(u64, 3), b.reads());
}

test "silnik: błąd jednego czujnika nie zatrzymuje reszty cyklu" {
    var caps: msr.CapabilitySet = .{};
    caps.addAll(&.{ .aperf_mperf, .msr_read });
    var b = try fake.Backend.init(testing.allocator, .{
        .cpu_count = 2,
        .capabilities = caps,
        // APERF niedostępny przez pierwsze 2 odczyty, potem działa.
        .registers = &.{
            .{ .msr_index = msr.Msr.aperf, .behavior = .{ .flaky = .{ .count = 2, .err = .unavailable, .then = 1000 } } },
            .{ .msr_index = msr.Msr.mperf, .behavior = .{ .incrementing = .{ .step = 1000 } } },
        },
    });
    defer b.deinit(testing.allocator);
    var st = try setupState(2);
    defer st.deinit(testing.allocator);

    const pollers = [_]Poller{
        .{ .descriptor = desc_eff, .instance = 0, .ctx = @ptrCast(&st), .read = pollEffectiveFrequency },
        .{ .descriptor = desc_eff, .instance = 1, .ctx = @ptrCast(&st), .read = pollEffectiveFrequency },
    };
    var e = try Engine.init(testing.allocator, b.api(), &pollers, 16);
    defer e.deinit();

    const out = e.poll(0);
    // Oba rdzenie mają ten sam deskryptor, ale **osobne próbki** z własnym
    // statusem — awaria rdzenia 0 nie stawia statusu rdzenia 1.
    try testing.expectEqual(@as(usize, 2), out.len);
    try testing.expect(out[0].status == .unavailable);
    try testing.expect(out[1].status == .unavailable);
    // Cykl wykonał się do końca mimo obu błędów.
    try testing.expectEqual(@as(u64, 1), e.cycles);
}

test "silnik: każda próbka ma własny timestamp" {
    var caps: msr.CapabilitySet = .{};
    caps.add(.aperf_mperf);
    var b = try fake.Backend.init(testing.allocator, .{
        .cpu_count = 1,
        .capabilities = caps,
        .registers = &.{
            .{ .msr_index = msr.Msr.aperf, .behavior = .{ .incrementing = .{} } },
            .{ .msr_index = msr.Msr.mperf, .behavior = .{ .incrementing = .{} } },
        },
    });
    defer b.deinit(testing.allocator);
    var st = try setupState(1);
    defer st.deinit(testing.allocator);

    const pollers = [_]Poller{.{ .descriptor = desc_eff, .ctx = @ptrCast(&st), .read = pollEffectiveFrequency }};
    var e = try Engine.init(testing.allocator, b.api(), &pollers, 16);
    defer e.deinit();

    b.advanceNanos(250_000_000);
    const out = e.poll(b.monotonicNanos());
    try testing.expectEqual(@as(u64, 250_000_000), out[0].timestamp_ns);
}
