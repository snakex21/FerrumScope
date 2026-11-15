//! Testy regresyjne FerrumScope — Etap 1.
//!
//! Plik stoi w `src/` (nie `src/tests/`), żeby importy względne do `db/`,
//! `probe/`, `decode/` mieściły się w katalogu modułu. Osadzone pliki
//! `.cpuimg` pochodzą z `db/fixtures/` i są wstrzykiwane przez build.zig,
//! więc test sprawdza dokładnie te dane, które leżą w repozytorium.
//!
//! Każdy test przechodzi tę samą ścieżkę co program: `cpuimg -> ReplayBackend
//! -> probe -> decode -> HWDB -> CpuInfo`. Jedyna różnica to backend — realny
//! sprzęt nigdy nie bierze udziału w CI.

const std = @import("std");
const ferrum = @import("root.zig");
const embedded = @import("db/embedded.zig");
const fixtures = @import("fixtures_embedded");

const core = ferrum.core;
const model = core.model;
const raw = core.raw;
const cpuimg = ferrum.capture.cpuimg;
const replay_mod = ferrum.platform.replay;
const status = core.status;
const probe = ferrum.probe.cpu;
const decoder = ferrum.decode.cpu_x86;
const hwdb_mod = ferrum.db.hwdb;

test {
    // Testy deklarowane w bibliotece (core, arch, platform, probe, decode, db).
    std.testing.refAllDeclsRecursive(@This());
}

/// Pełny pipeline na danym pliku capture — dokładnie jak w CLI.
const Result = struct {
    info: model.CpuInfo,
    outcome: decoder.DecodeOutcome,
    raw_info: raw.RawCpuInfo,
};

fn runFixture(text: []const u8) !Result {
    const captured = try cpuimg.parse(text);
    var rp = replay_mod.Replay.init(captured.image);
    // Sekcję per-CPU przekazujemy **warunkowo**, dokładnie jak robi to CLI.
    // Bez tegowarunkowy helper gubiłby dane thread-pinned, a testy sprawdzałyby
    // sam helper, a nie kod, który ma być testowany.
    if (captured.has_per_cpu) rp = rp.withPerCpu(captured.per_cpu);
    rp.source = "fixture";
    const res = probe.run(rp.create());
    // Probe nie może się wyłożyć nawet na danych, których nie zna.
    if (res.getStatus() != .ok) return error.ProbeFailed;
    const raw_info = res.unwrap().?;
    const db = try embedded.load();
    var info = model.CpuInfo{};
    const outcome = decoder.decode(&raw_info, db, &info);
    return .{ .info = info, .outcome = outcome, .raw_info = raw_info };
}

// ---------------------------------------------------------------------------
// 1. Starszy Intel: Core 2 Duo E6600 (Conroe, 2006)
// ---------------------------------------------------------------------------
test "regresja: fixture Intel bez 0x0B/0x1F -> poprawny fallback, nie zmyślony pomiar" {
    // Conroe, `max_basic = 0x10`. Liście 0x0B i 0x1F leżą POZA zakresem, więc
    // CPU ich nie implementuje i per-CPU nie ma czego czytać. Jedyna uczciwa
    // odpowiedź to baza (`hwdb`); `hardware` byłoby twierdzeniem o pomiarze,
    // którego nie było.
    const r = try runFixture(fixtures.intel_legacy_no_topology);
    const i = &r.info;

    try std.testing.expectEqual(raw.TopologySource.hwdb, i.topology_source);
    try std.testing.expectEqual(@as(u16, 2), i.cores_physical);
    try std.testing.expectEqual(@as(u16, 2), i.threads_logical);
}

test "regresja: fixture Intel 0x0B -> 4C/8T z pomiaru" {
    // 0x0B niesie tylko liczbę poziomów SMT. Klucz rdzenia = x2APIC >> shift.
    const r = try runFixture(fixtures.intel_leaf0b);
    const i = &r.info;

    try std.testing.expectEqual(raw.TopologySource.hardware, i.topology_source);
    try std.testing.expectEqual(@as(u16, 4), i.cores_physical);
    try std.testing.expectEqual(@as(u16, 8), i.threads_logical);
    try std.testing.expectEqual(@as(u16, 2), i.threads_per_core);
    try std.testing.expect(i.topology_confident);
}

test "regresja: fixture Intel 0x1F -> 8C/16T z pomiaru" {
    // Ten test bywa FAIL przed poprawką. Fixture zapisywał liść `0x1F` jako
    // `0x1`, więc `measure()` nie znalazł poziomu SMT, odrzucił pomiar, a
    // topologia spadła na `hwdb` z 2 rdzeniami z bazy zamiast 8 z pomiaru.
    // Plik wyglądał poprawnie, bo był to poprawny format — z niewłaściwą
    // zawartością. Taki błąd łapie wyłącznie test sprawdzający wynik, nie
    // test sprawdzający składnię.
    const r = try runFixture(fixtures.intel_leaf1f);
    const i = &r.info;

    try std.testing.expectEqual(raw.TopologySource.hardware, i.topology_source);
    try std.testing.expectEqual(@as(u16, 8), i.cores_physical);
    try std.testing.expectEqual(@as(u16, 16), i.threads_logical);
    try std.testing.expectEqual(@as(u16, 2), i.threads_per_core);
    try std.testing.expect(i.topology_confident);
    // Dekoder musi umieć rozróżnić poziom SMT od Core. SDM mówi, że typ
    // poziomu jest w ECX[15:8], a numer poziomu w ECX[7:0] (równy indeksowi
    // subleafa). Wcześniejszy kod patrzył na ECX[4:0], czyli na bity
    // zarezerwowane — i „poziom 1" zgadzał się przypadkiem tylko dla subleaf 0.
    const smt = r.raw_info.per_cpu.slice()[0].image.get(0x1F, 0).?;
    const core_lvl = r.raw_info.per_cpu.slice()[0].image.get(0x1F, 1).?;
    try std.testing.expectEqual(raw.LevelKind.smt, raw.LevelKind.fromCpuid(@as(u8, @truncate(smt.ecx >> 8))));
    try std.testing.expectEqual(raw.LevelKind.core, raw.LevelKind.fromCpuid(@as(u8, @truncate(core_lvl.ecx >> 8))));
    // ECX[7:0] = numer poziomu = indeks subleafa.
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @truncate(smt.ecx & 0xFF)));
    try std.testing.expectEqual(@as(u8, 1), @as(u8, @truncate(core_lvl.ecx & 0xFF)));
    // EAX[4:0] jest **kumulatywne**: SMT2 = 1 bit, a poziom Core = 4 bity
    // (16 logicznych w pakiecie). To nie „tyle bitów ma ten poziom”.
    try std.testing.expectEqual(@as(u8, 1), @as(u8, @truncate(smt.eax & 0x1F)));
    try std.testing.expectEqual(@as(u8, 4), @as(u8, @truncate(core_lvl.eax & 0x1F)));
    // Terminator po ostatnim poprawnym poziomie: typ 0 i EAX = 0. Dekoder musi
    // na tym skończyć, a nie czytać dalej w nadzieję na kolejny poziom.
    try std.testing.expect(r.raw_info.per_cpu.slice()[0].image.get(0x1F, 2) != null);
    try std.testing.expectEqual(
        raw.LevelKind.invalid,
        raw.LevelKind.fromCpuid(@as(u8, @truncate(r.raw_info.per_cpu.slice()[0].image.get(0x1F, 2).?.ecx >> 8))),
    );
}

test "regresja: x2APIC siedzi w EDX[31:0], a nie w EBX[31:16]" {
    // SDM Vol. 2A dla liści 0x0B/0x1F: `EDX[31:0]` = x2APIC ID bieżącego
    // procesora logicznego. Wcześniejszy dekoder czytał `EBX[31:16]`.
    //
    // Ten test dokumentuje kontrakt danych, bo obie wartości w pliku wyglądają
    // niewinnie: w fixture EBX[31:16] jest zerowe. Dekoder czytający EBX
    // zobaczyłby x2APIC = 0 dla **wszystkich** procesorów, zwinąłby całą
    // maszynę w jeden rdzeń i **nadal** zwróciłby `source = hardware`.
    // To najgorszy rodzaj pomyłki: wynik wiarygodny, liczby zmyślone.
    const r = try runFixture(fixtures.intel_leaf1f);
    const per = r.raw_info.per_cpu.slice();
    try std.testing.expect(per.len >= 4);

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        const l0 = per[i].image.get(0x1F, 0).?;
        try std.testing.expectEqual(@as(u32, @intCast(i)), l0.edx);
        // Pole, którego **nie** wolno tu czytać jako x2APIC.
        try std.testing.expectEqual(@as(u32, 0), l0.ebx >> 16);
    }
    // Gdyby ktoś wrócił do EBX, wyszłby jeden rdzeń zamiast ośmiu.
    try std.testing.expectEqual(@as(u16, 8), r.info.cores_physical);
}

test "regresja: dwa gniazda -> 2 pakiety, 16 rdzeni, 32 wątki, SMT2" {
    const r = try runFixture(fixtures.intel_2xsocket_8core);
    const i = &r.info;

    try std.testing.expectEqual(raw.TopologySource.hardware, i.topology_source);
    try std.testing.expectEqual(@as(u16, 2), i.packages);
    try std.testing.expectEqual(@as(u16, 16), i.cores_physical);
    try std.testing.expectEqual(@as(u16, 32), i.threads_logical);
    try std.testing.expectEqual(@as(u16, 2), i.threads_per_core);
    try std.testing.expect(i.topology_confident);
    // Jedna klasa rdzenia (wszystko Core) na obu gniazdach.
    try std.testing.expect(!i.heterogeneous);
}

test "regresja: CoreId powtarza się między gniazdami, a rdzenie nie są scalane" {
    // Sedno tego fixture. `core_id = (x2apic >> smt_shift) & maska` daje
    // 0..7 w **obu** gniazdach — pole `CoreId` jest lokalne w obrębie pakietu,
    // bo SDM nie obiecuje jego globalnej unikalności. Liczenie samych `core_id`
    // dałoby 8 zamiast 16. Kluczem tożsamości jest `(package_id, core_id)`.
    const r = try runFixture(fixtures.intel_2xsocket_8core);
    const per = r.raw_info.per_cpu.slice();

    const smt_shift: u32 = 1;
    const core_shift: u32 = 4;
    const mask: u32 = (@as(u32, 1) << @intCast(core_shift - smt_shift)) - 1;

    var core_ids = [_]u32{0} ** 8;
    var packages = [_]u32{0} ** 2;
    for (per) |c| {
        const l = c.image.get(0x1F, 0) orelse return error.NoTopologyLeaf;
        const x2apic = l.edx;
        core_ids[@intCast((x2apic >> @intCast(smt_shift)) & mask)] += 1;
        packages[@intCast(x2apic >> @intCast(core_shift))] += 1;
    }

    var distinct: u32 = 0;
    for (core_ids) |n| {
        if (n != 0) distinct += 1;
        // 4 = 2 gniazda × 2 wątki. Gdyby maskowanie zniknęło, ten sam rdzeń
        // z gniazda 1 zlałby się z rdzeniem z gniazda 0.
        try std.testing.expectEqual(@as(u32, 4), n);
    }
    try std.testing.expectEqual(@as(u32, 8), distinct);
    try std.testing.expectEqual(@as(u32, 16), packages[0]);
    try std.testing.expectEqual(@as(u32, 16), packages[1]);

    // A mimo powtarzających się `core_id` dekoder widzi 16 różnych rdzeni.
    try std.testing.expectEqual(@as(u16, 16), r.info.cores_physical);
}

test "regresja: hybryda 12900K -> 16C/24T, 8 P + 8 E, spójnie z pomiarem" {
    // Dwa niezależne błędy, oba wracały jako „0 rdzeni":
    //  1. Globalny shift SMT zamiast per-CPU zawijał 8 wątków E-core do 4
    //     kluczy i dawał 12 rdzeni.
    //  2. Quirk `hybrid_cores` z bazy kasował liczbę rdzeni **zmierzoną**
    //     z 0x1F. Baza nie może być ważniejsza niż sprzęt.
    //
    // 8P + 8E = 16C/24T to i9-**12900K**; i7-12700K ma 8P + 4E. Fixture był
    // nazwany 12700K, co było nieprawdą — nazwa nie zmienia dekodowania, ale
    // fixture musi być odróżnialny od prawdziwego zrzutu.
    const r = try runFixture(fixtures.intel_hybrid_12900k);
    const i = &r.info;

    try std.testing.expectEqual(raw.TopologySource.hardware, i.topology_source);
    try std.testing.expectEqual(@as(u16, 16), i.cores_physical);
    try std.testing.expectEqual(@as(u16, 24), i.threads_logical);
    try std.testing.expect(i.hybrid);
    try std.testing.expect(i.heterogeneous);
    try std.testing.expectEqual(@as(u16, 8), i.p_cores);
    try std.testing.expectEqual(@as(u16, 8), i.e_cores);
    // Jedno gniazdo: 24 logiczne procesory mieszczą się w 5 bitach, więc
    // `package = x2apic >> 5` = 0 dla każdego CPU.
    try std.testing.expectEqual(@as(u16, 1), i.packages);
    // Klasy przychodzą jako lista wartości SDM, nie jako dwa policzone pola.
    const cls = i.coreClassSlice();
    try std.testing.expectEqual(@as(usize, 2), cls.len);
    try std.testing.expectEqual(@as(u16, 8), cls[0].cores);
    try std.testing.expectEqual(@as(u16, 8), cls[1].cores);
    try std.testing.expect(cls[0].value != cls[1].value);
    // Nie ma jednej szerokości SMT, więc `threads_per_core = 0`, a prawdziwą
    // wartość niesie `smt_max`. Podanie `2` wyglądałoby jak jednolite SMT2.
    try std.testing.expectEqual(@as(u16, 0), i.threads_per_core);
    try std.testing.expectEqual(@as(u8, 2), i.smt_max);
    // Dwie klasy naraz = niejedna wartość typu.
    try std.testing.expectEqual(model.CoreType.unknown, i.core_type);
}

test "regresja: sumy wątków zgadzają się z liczbą rdzeni na każdym fixture Intel" {
    // Niezmiennik obejmujący wszystkie cztery przypadki naraz. Gdyby `measure()`
    // zwrócił `complete = false`, `replay` i tak policzyłby coś z bazy — i
    // skąd wiadomo, że to zły rdzeń? Ten test wymusza, żeby suma wątków
    // na rdzenie zgadzała się z tym, co deklaruje system.
    const cases = [_]struct { name: []const u8, data: []const u8, cores: u16, threads: u16, measured: bool, scanned: u32, packages: u16 }{
        .{ .name = "legacy", .data = fixtures.intel_legacy_no_topology, .cores = 2, .threads = 2, .measured = false, .scanned = 0, .packages = 1 },
        .{ .name = "leaf0b", .data = fixtures.intel_leaf0b, .cores = 4, .threads = 8, .measured = true, .scanned = 8, .packages = 1 },
        .{ .name = "leaf1f", .data = fixtures.intel_leaf1f, .cores = 8, .threads = 16, .measured = true, .scanned = 16, .packages = 1 },
        .{ .name = "hybrid", .data = fixtures.intel_hybrid_12900k, .cores = 16, .threads = 24, .measured = true, .scanned = 24, .packages = 1 },
        .{ .name = "2xsocket", .data = fixtures.intel_2xsocket_8core, .cores = 16, .threads = 32, .measured = true, .scanned = 32, .packages = 2 },
    };
    for (cases) |c| {
        const r = try runFixture(c.data);
        try std.testing.expectEqual(c.cores, r.info.cores_physical);
        try std.testing.expectEqual(c.threads, r.info.threads_logical);
        try std.testing.expectEqual(c.packages, r.info.packages);
        // `hardware` tylko tam, gdzie pomiar faktycznie istnieje.
        const want: raw.TopologySource = if (c.measured) .hardware else .hwdb;
        try std.testing.expectEqual(want, r.info.topology_source);
        // Liczba odczytanych CPU musi zgadzać się z tym, co fixture deklaruje.
        // `legacy` jest tu wyjątkiem **z definicji**: liście 0x0B/0x1F leżą poza
        // zakresem, więc sekcji per-CPU w pliku nie ma i nie ma czego czytać.
        // Test nie może wymagać tam kompletu, którego CPU nie opisuje.
        const scanned: u32 = @intCast(r.raw_info.per_cpu.len);
        try std.testing.expectEqual(c.scanned, scanned);
    }
}

test "fixture: Intel Core 2 Duo E6600 — Family 6 Model 0x16" {
    const r = try runFixture(fixtures.intel_core2_e6600);
    const i = &r.info;

    try std.testing.expectEqual(core.ids.CpuVendor.intel, i.vendor);
    try std.testing.expectEqual(@as(u8, 6), i.display_family);
    try std.testing.expectEqual(@as(u8, 0x16), i.display_model);
    try std.testing.expectEqual(@as(u8, 9), i.stepping);
    try std.testing.expectEqualStrings("Intel(R) Core(TM)2 Duo CPU     E6600  @ 2.40GHz", i.brandSlice());
    try std.testing.expectEqualStrings("Core 2", i.microarchitecture.?);
    try std.testing.expectEqualStrings("Conroe", i.codename.?);
    try std.testing.expectEqual(model.MatchQuality.exact, i.match);

    // Ten procesor nie ma leaf 0x0B (pre-Nehalem) — topologia bierze się
    // wyłącznie z CPUID.1, a brak SMT daje 2 rdzenia fizyczne.
    try std.testing.expectEqual(@as(u16, 2), i.threads_logical);
    try std.testing.expectEqual(@as(u16, 2), i.cores_physical);
    try std.testing.expect(!i.smt);
    // Brak leaf 4 => brak danych o cache, nie błąd.
    try std.testing.expectEqual(@as(usize, 0), i.cacheSlice().len);
}

test "fixture: E6600 ma cechy SSE2, ale nie AVX" {
    const r = try runFixture(fixtures.intel_core2_e6600);
    try std.testing.expect(r.info.features.sse2);
    try std.testing.expect(r.info.features.sse3);
    try std.testing.expect(!r.info.features.avx);
    try std.testing.expect(!r.info.features.avx2);
}

// ---------------------------------------------------------------------------
// 2. Nowszy Intel: Core i9-13900K (Raptor Lake, 2022)
// ---------------------------------------------------------------------------
test "fixture: Intel Core i9-13900K — Family 6 Model 0xB7" {
    const r = try runFixture(fixtures.intel_i9_13900k);
    const i = &r.info;

    try std.testing.expectEqual(core.ids.CpuVendor.intel, i.vendor);
    try std.testing.expectEqual(@as(u8, 6), i.display_family);
    try std.testing.expectEqual(@as(u8, 0xB7), i.display_model);
    try std.testing.expectEqualStrings("Raptor Lake", i.microarchitecture.?);
    // Wpis bazy obejmuje `model_min=0xB7 .. model_max=0xBA`, czyli **wiele
    // modeli**. To jest reguła wzorca, więc `.pattern`, nie `.exact` — dawniej
    // każdy wpis trafiający modelowo raportowany był jako `.exact`, co było
    // zawyżeniem: autor bazy świadomie opisał zakres, a nie jeden układ.
    try std.testing.expectEqual(model.MatchQuality.pattern, i.match);
    try std.testing.expect(model.MatchQuality.pattern.isReliable());
    try std.testing.expectEqualStrings("13th Gen Intel(R) Core(TM) i9-13900K", i.brandSlice());

    // 24 wątki.
    try std.testing.expectEqual(@as(u16, 24), i.threads_logical);
    // CPU hybrydowy: threads / smt_width dałoby fałszywą liczbę rdzeni,
    // więc baza niesie quirk i dekoder celowo nie podaje cores_physical.
    try std.testing.expectEqual(@as(u16, 0), i.cores_physical);
    try std.testing.expect(!i.smt);
}

test "fixture: Raptor Lake — 4 poziomy cache i AVX-512 + AMX" {
    const r = try runFixture(fixtures.intel_i9_13900k);
    const c = r.info.cacheSlice();
    try std.testing.expectEqual(@as(usize, 4), c.len);
    try std.testing.expectEqual(@as(u8, 1), c[0].level);
    try std.testing.expect(c[0].kind == .data);
    try std.testing.expectEqual(@as(u64, 48 * 1024), c[0].size_bytes);
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), c[2].size_bytes);
    try std.testing.expectEqual(@as(u64, 24 * 1024 * 1024), c[3].size_bytes);
    try std.testing.expect(c[3].shared);

    const f = r.info.features;
    try std.testing.expect(f.avx and f.avx2 and f.avx512f and f.avx512vl and f.amx_bf16 and f.amx_tile);
}

// ---------------------------------------------------------------------------
// 3. Starszy AMD: Athlon 64 (K8 Hammer, 2004)
// ---------------------------------------------------------------------------
test "fixture: AMD Athlon 64 — Family 15 Model 0x02" {
    const r = try runFixture(fixtures.amd_athlon64_k8);
    const i = &r.info;

    try std.testing.expectEqual(core.ids.CpuVendor.amd, i.vendor);
    try std.testing.expectEqual(@as(u8, 15), i.display_family);
    try std.testing.expectEqual(@as(u8, 0x02), i.display_model);
    try std.testing.expectEqual(@as(u8, 3), i.stepping);
    try std.testing.expectEqualStrings("K8", i.microarchitecture.?);
    try std.testing.expectEqualStrings("Hammer (K8)", i.codename.?);
    try std.testing.expectEqualStrings("AMD Athlon(tm) 64 Processor  3200+", i.brandSlice());

    try std.testing.expectEqual(@as(u16, 1), i.threads_logical);
    try std.testing.expectEqual(@as(u16, 1), i.cores_physical);
    // K8 nie udostępnia leaf 4 — brak cache to wynik, nie awaria.
    try std.testing.expectEqual(@as(usize, 0), i.cacheSlice().len);
}

// ---------------------------------------------------------------------------
// 4. Zen-family AMD: Ryzen 7 5800X (Vermeer, Zen 3, 2020)
// ---------------------------------------------------------------------------
test "fixture: AMD Ryzen 7 5800X — Family 19h Model 0x21 (Zen 3)" {
    const r = try runFixture(fixtures.amd_ryzen7_5800x);
    const i = &r.info;

    try std.testing.expectEqual(core.ids.CpuVendor.amd, i.vendor);
    // Rodzina 19h powstaje z family_field 0x0F + ext_family 0x0A.
    try std.testing.expectEqual(@as(u8, 0x19), i.display_family);
    // Model 0x21 z ext_model 0x2 i model_field 0x1.
    try std.testing.expectEqual(@as(u8, 0x21), i.display_model);
    try std.testing.expectEqualStrings("Zen 3", i.microarchitecture.?);
    // Wpis AMD to zakres (`0x20..0x2F`), więc `.pattern` — patrz komentarz przy
    // 13900K. Nazwa, kod i topologia pozostają bez zmian.
    try std.testing.expectEqual(model.MatchQuality.pattern, i.match);
    try std.testing.expectEqualStrings("AMD Ryzen 7 5800X 8-Core Processor", i.brandSlice());

    try std.testing.expectEqual(@as(u16, 16), i.threads_logical);
    try std.testing.expectEqual(@as(u16, 8), i.cores_physical); // SMT2 z L1d
    try std.testing.expect(i.smt);
}

test "fixture: Zen 3 — cache z liści 0x8000001D" {
    const r = try runFixture(fixtures.amd_ryzen7_5800x);
    const c = r.info.cacheSlice();
    try std.testing.expectEqual(@as(usize, 4), c.len);
    try std.testing.expectEqual(@as(u64, 32 * 1024), c[0].size_bytes);
    try std.testing.expectEqual(@as(u64, 512 * 1024), c[2].size_bytes);
    try std.testing.expectEqual(@as(u64, 32 * 1024 * 1024), c[3].size_bytes);
}

// ---------------------------------------------------------------------------
// 5. Nieznany producent — wynik musi być użyteczny, nie pusty
// ---------------------------------------------------------------------------
test "fixture: nieznany vendor nadal daje użyteczny wynik" {
    const r = try runFixture(fixtures.unknown_vendor);
    const i = &r.info;

    try std.testing.expect(i.available);
    try std.testing.expectEqual(core.ids.CpuVendor.unknown, i.vendor);
    // Rodzina i model odczytujemy mimo nieznanego producenta.
    try std.testing.expectEqual(@as(u8, 6), i.display_family);
    try std.testing.expectEqual(@as(u8, 0x0A), i.display_model);
    try std.testing.expectEqual(@as(u8, 1), i.stepping);

    // Brand string pusty, więc nazwa nie może być pusta ani zmyślona.
    try std.testing.expect(!i.brand_valid);
    try std.testing.expectEqual(model.MatchQuality.unknown, i.match);
    try std.testing.expectEqual(model.DisplaySource.hex_id, i.display);

    var buf: [128]u8 = undefined;
    const name = i.displayName(&buf);
    try std.testing.expect(name.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, name, "Family 6") != null);
    try std.testing.expect(std.mem.indexOf(u8, name, "Model 10") != null);
}

// ---------------------------------------------------------------------------
// Testy przechodzące przez cały pipeline oraz niezmiennik dekodera
// ---------------------------------------------------------------------------
test "pipeline: identyczny wynik dla backendu natywnego i replay (bez tego samego CPU)" {
    // Ten test nie porównuje wyników dwóch backendów — CPU na maszynie
    // testowej nie musi być tym z pliku. Sprawdza, że OBA backendy dają
    // kompletny, niuansowany CpuInfo na własnych danych.
    const native_backend = ferrum.platform.native.create();
    const native_res = probe.run(native_backend);
    var replay_fixture = try replayFrom(fixtures.amd_ryzen7_5800x);
    const replay_res = probe.run(replay_fixture.create());

    try std.testing.expect(native_res.getStatus() == .ok or native_res.getStatus() == .unsupported);
    try std.testing.expectEqual(status_ok(replay_res), true);

    if (native_res.getStatus() == .ok) {
        const n = native_res.unwrap().?;
        try std.testing.expectEqual(@as(bool, true), n.cpuid_available);
        try std.testing.expect(n.signature.familyField() != 0 or n.signature.extFamily() != 0);
    }
}

fn status_ok(r: anytype) bool {
    return r.getStatus() == .ok;
}

fn replayFrom(text: []const u8) !replay_mod.Replay {
    const captured = try cpuimg.parse(text);
    return replay_mod.Replay.init(captured.image);
}

test "hwdb: wbudowana baza jest spójna i zawiera obu producentów" {
    const db = try embedded.load();
    try std.testing.expect(db.count() >= 20);
    try std.testing.expect(!db.isNewerSchema());

    var intel = false;
    var amd = false;
    var i: usize = 0;
    while (i < db.count()) : (i += 1) {
        const e = db.entryAt(i).?;
        // Każdy wpis musi mieć zakres, który da się dopasować.
        try std.testing.expect(e.model_min <= e.model_max);
        try std.testing.expect(e.stepping_min <= e.stepping_max);
        // Provenance jest obowiązkowy: bez source wpis nie powinien istnieć.
        try std.testing.expect(!e.source.isEmpty());
        try std.testing.expect(e.uarch.len > 0);
        if (e.vendor == .intel) intel = true;
        if (e.vendor == .amd) amd = true;
    }
    try std.testing.expect(intel);
    try std.testing.expect(amd);
}

test "hwdb: dopasowanie jest deterministyczne i wybiera najwęższy wpis" {
    const db = try embedded.load();
    // Zen 4 Raphael: Family 19h Model 0x11 stepping 0.
    const sig = core.ids.Signature.fromEax(0x00A10F10);
    const m = db.matchCpu(.amd, sig).?;
    try std.testing.expectEqualStrings("Zen 4", db.text(m.entry.uarch));
    // Wpis bazy obejmuje zakres modeli, więc trafienie jest wzorcem.
    try std.testing.expectEqual(hwdb_mod.HitLevel.model_range, m.level);

    // Ten sam wynik przy powtórzeniu — brak losowości w dopasowaniu.
    const m2 = db.matchCpu(.amd, sig).?;
    try std.testing.expectEqualStrings(db.text(m.entry.uarch), db.text(m2.entry.uarch));
}

// ---------------------------------------------------------------------------
// 6. Złoty capture natywny: AMD Ryzen 7 5800X3D (Vermeer, Zen 3)
//    Zapisany z prawdziwej maszyny komendą `ferrumscope capture`.
//    Zawiera wyłącznie publiczne identyfikatory CPUID — brak danych prywatnych.
//    Sprawdza konkretny CpuInfo, a nie tylko brak awarii.
// ---------------------------------------------------------------------------
test "golden native: Ryzen 7 5800X3D — identyfikacja i topologia" {
    const r = try runFixture(fixtures.amd_ryzen7_5800x3d_native);
    const i = &r.info;

    // Producent i sygnatura.
    try std.testing.expectEqual(core.ids.CpuVendor.amd, i.vendor);
    try std.testing.expectEqual(@as(u8, 0x19), i.display_family);
    try std.testing.expectEqual(@as(u8, 0x21), i.display_model);
    try std.testing.expectEqual(@as(u8, 2), i.stepping);
    try std.testing.expectEqual(@as(u32, 0x00A20F12), i.signature.eax);

    // Brand string prosto z CPUID — nie z bazy.
    try std.testing.expect(i.brand_valid);
    try std.testing.expectEqualStrings("AMD Ryzen 7 5800X3D 8-Core Processor", i.brandSlice());
    try std.testing.expectEqual(model.DisplaySource.brand_string, i.display);

    // Identyfikacja z bazy.
    try std.testing.expectEqualStrings("Zen 3", i.microarchitecture.?);
    try std.testing.expect(i.codename != null);
    try std.testing.expect(std.mem.indexOf(u8, i.codename.?, "Vermeer") != null);
    try std.testing.expectEqual(model.MatchQuality.pattern, i.match);

    // Topologia: 8C/16T, SMT2. To był pierwotny błąd (16 „rdzeni").
    try std.testing.expectEqual(@as(u16, 8), i.cores_physical);
    try std.testing.expectEqual(@as(u16, 16), i.threads_logical);
    try std.testing.expectEqual(@as(u16, 2), i.threads_per_core);
    try std.testing.expect(i.smt);
    try std.testing.expect(i.topology_confident);
    // Na AMD szerokosc SMT pochodzi z **pomiaru** thread-pinned CPUID
    // (`topology_source = hardware`), a nie z bazy. W Etapie 1 ten sam plik
    // musiał zejsc do fallbacku HWDB, bo liść 0x8000001E opisuje biezacy
    // wątek; teraz backend umie przypiac wątek i liczymy różne core id.
    // Test poniżej sprawdza, że stary plik nadal daje `hwdb`.
    try std.testing.expectEqual(raw.TopologySource.hardware, i.topology_source);
}

test "golden native: 5800X3D L3 = 96 MB z poprawnego dekodowania, nie mnożenia" {
    const r = try runFixture(fixtures.amd_ryzen7_5800x3d_native);
    const c = r.info.cacheSlice();

    // Dokładnie 4 poziomy — brak podwójnego liczenia z liścia 4 i 0x8000001D.
    try std.testing.expectEqual(@as(usize, 4), c.len);

    var l3: ?model.CacheInfo = null;
    for (c) |x| {
        if (x.level == 3) {
            try std.testing.expect(l3 == null); // tylko jedna instancja L3 na liście
            l3 = x;
        }
    }
    const big = l3 orelse return error.NoL3;

    // 96 MiB = 98304 KiB. Rozmiar musi wynikać z sets * ways * line_size,
    // a nie z pomnożenia rozmiaru przez liczbę instancji ani rdzeni.
    try std.testing.expectEqual(@as(u64, 96 * 1024 * 1024), big.size_bytes);
    try std.testing.expectEqual(@as(u32, 98304), big.sets); // 0x17FFF + 1
    try std.testing.expectEqual(@as(u16, 16), big.associativity);
    try std.testing.expectEqual(@as(u16, 64), big.line_size);
    // Mnożenie daje dokładnie 96 MiB — to jest właśnie test „nie przypadkiem".
    try std.testing.expectEqual(
        @as(u64, 98304) * 16 * 64,
        big.size_bytes,
    );
    // `instance_count` to liczba instancji, NIE mnożnik rozmiaru.
    try std.testing.expect(big.instance_count >= 1);
    try std.testing.expectEqual(raw.Domain.package, big.domain);
}

test "golden native: 5800X3D — niezmienniki topologii" {
    const r = try runFixture(fixtures.amd_ryzen7_5800x3d_native);
    const i = &r.info;
    // Niezmienniki, które muszą trzymać się dla każdego CPU, nie tylko tego.
    try std.testing.expect(i.threads_per_core >= 1);
    try std.testing.expect(i.threads_logical >= i.cores_physical);
    try std.testing.expect(i.topology_confident);
    try std.testing.expectEqual(
        i.cores_physical * i.threads_per_core,
        i.threads_logical,
    );
}

test "golden native: cache nie zależy od liczby liści w capture" {
    // Ten sam CPU odczytany ze skróconego obrazu (bez liścia 0x8000001E)
    // musi dać tę samą hierarchię cache — wynik topologii/cache nie może
    // zależeć od tego, ile liści trafiło do pliku.
    const full = try runFixture(fixtures.amd_ryzen7_5800x3d_native);
    const captured = try cpuimg.parse(fixtures.amd_ryzen7_5800x3d_native);
    var trimmed = raw.CpuidImage{};
    trimmed.max_basic = captured.image.max_basic;
    trimmed.max_extended = captured.image.max_extended;
    for (captured.image.slice()) |e| {
        if (e.leaf == 0x8000_001E) continue;
        trimmed.add(e.leaf, e.subleaf, e.regs);
    }
    var rp = replay_mod.Replay.init(trimmed);
    const res = probe.run(rp.create());
    const short_info_res = res.getStatus();
    try std.testing.expect(short_info_res == .ok);
    const short_info = res.unwrap().?;
    var out = model.CpuInfo{};
    _ = decoder.decode(&short_info, embedded.load() catch return error.NoDb, &out);

    try std.testing.expectEqual(full.info.cacheSlice().len, out.cacheSlice().len);
    var k: usize = 0;
    while (k < out.cacheSlice().len) : (k += 1) {
        try std.testing.expectEqual(full.info.cacheSlice()[k].size_bytes, out.cacheSlice()[k].size_bytes);
        try std.testing.expectEqual(full.info.cacheSlice()[k].level, out.cacheSlice()[k].level);
    }
    // Bez liścia 0x8000001E topologia jest mniej pewna, ale cache identyczny.
    try std.testing.expectEqual(@as(u16, 16), out.threads_logical);
}

test "golden native: 5800X3D — topologia z pomiaru thread-pinned, nie z bazy" {
    const r = try runFixture(fixtures.amd_ryzen7_5800x3d_native);
    const i = &r.info;

    // 16 CPU odczytanych osobno po przypinaniu wątku.
    try std.testing.expectEqual(@as(usize, 16), r.raw_info.per_cpu.len);
    try std.testing.expectEqual(@as(u32, 16), r.raw_info.scanned_cpus);

    // Źródło **hardware** — pomiar, a nie `hwdb`. To jest sedno Etapu 2:
    // w Etapie 1 ta sama maszyna dawała `hwdb`, bo liść 0x8000001E opisuje
    // bieżący wątek i bez przypinania był bezużyteczny.
    try std.testing.expectEqual(raw.TopologySource.hardware, i.topology_source);
    try std.testing.expectEqual(@as(u16, 8), i.cores_physical);
    try std.testing.expectEqual(@as(u16, 16), i.threads_logical);
    try std.testing.expectEqual(@as(u16, 2), i.threads_per_core);
    try std.testing.expect(i.topology_confident);
}

test "golden native: 5800X3D — każdy core id występuje dokładnie dwa razy" {
    const r = try runFixture(fixtures.amd_ryzen7_5800x3d_native);
    // EBX[7:0] z 0x8000001E to core id. Na Zen 3 z SMT2 każdy z 8 rdzeni
    // ma dwa wątki, więc rozkład musi być dokładnie 2× na rdzeń. Test
    // sprawdza rozkład, a nie tylko sumę — suma mogłaby się zgadzać przy
    // błędnym przypisaniu wątków do rdzeni.
    var counts = [_]u32{0} ** 256;
    for (r.raw_info.per_cpu.slice()) |c| {
        const e = c.image.get(0x8000_001E, 0) orelse return error.NoAmdTopology;
        counts[@as(usize, e.ebx & 0xFF)] += 1;
    }
    var distinct: u32 = 0;
    var i: usize = 0;
    while (i < counts.len) : (i += 1) {
        if (counts[i] == 0) continue;
        distinct += 1;
        // Każdy rdzeń ma dokładnie 2 wątki — żadnego 1, żadnego 3+.
        try std.testing.expectEqual(@as(u32, 2), counts[i]);
    }
    try std.testing.expectEqual(@as(u32, 8), distinct);
}

test "golden native: capture sprzed Etapu 2 nadal działa przez fallback HWDB" {
    // Kompatybilność wsteczna. Plik v1 bez sekcji per-CPU **nie może** udawać,
    // że potrafi CPUID per-procesor, bo dekoder doszedłby do wniosku „nie
    // udało się odczytać" zamiast „tego plik nie zawiera". Fallback HWDB daje
    // ten sam wynik co w Etapie 1: 8C/16T, ale z jawnie innym źródłem.
    const captured = try cpuimg.parse(fixtures.amd_ryzen7_5800x3d_v1);
    try std.testing.expect(!captured.has_per_cpu);
    try std.testing.expectEqual(@as(usize, 0), captured.per_cpu.len);

    var rp = replay_mod.Replay.init(captured.image);
    const b = rp.create();
    try std.testing.expect(!b.hasPinnedCpuid());

    const res = probe.run(b);
    try std.testing.expectEqual(status.Status.ok, res.getStatus());
    var info = model.CpuInfo{};
    const raw_measured = res.unwrap().?;
    const outcome = decoder.decode(&raw_measured, embedded.load() catch return error.NoDb, &info);

    // Identyfikacja i cache identyczne...
    try std.testing.expectEqual(@as(u8, 0x19), info.display_family);
    try std.testing.expectEqual(@as(u8, 0x21), info.display_model);
    try std.testing.expectEqualStrings("AMD Ryzen 7 5800X3D 8-Core Processor", info.brandSlice());
    try std.testing.expectEqual(@as(usize, 4), info.cacheSlice().len);
    // ...a topologia prowadzi do tych samych 8 rdzeni, tyle że z bazy.
    try std.testing.expectEqual(@as(u16, 8), info.cores_physical);
    try std.testing.expectEqual(@as(u16, 16), info.threads_logical);
    try std.testing.expectEqual(raw.TopologySource.hwdb, info.topology_source);
    _ = outcome;
}

test "golden native: replay z per-CPU daje hardware, ten sam plik bez danych daje hwdb" {
    // Ten sam sprzęt, ten sam decoder, dwa pliki. Różnica **wyłącznie** w danych
    // i w tym, co backend zadeklarował. To jest test niezależności modelu
    // od platformy: wynik nie może zależeć od tego, skąd przyszły dane.
    const with_pinned = try runFixture(fixtures.amd_ryzen7_5800x3d_native);
    const captured = try cpuimg.parse(fixtures.amd_ryzen7_5800x3d_v1);
    var rp = replay_mod.Replay.init(captured.image);
    const old = probe.run(rp.create());
    var old_info = model.CpuInfo{};
    const old_raw = old.unwrap().?;
    _ = decoder.decode(&old_raw, embedded.load() catch return error.NoDb, &old_info);

    // Wartości fizyczne są identyczne...
    try std.testing.expectEqual(with_pinned.info.cores_physical, old_info.cores_physical);
    try std.testing.expectEqual(with_pinned.info.threads_logical, old_info.threads_logical);
    try std.testing.expectEqual(with_pinned.info.threads_per_core, old_info.threads_per_core);
    try std.testing.expectEqualStrings(with_pinned.info.brandSlice(), old_info.brandSlice());
    // ...a źródło topologii uczciwie się różni.
    try std.testing.expectEqual(raw.TopologySource.hardware, with_pinned.info.topology_source);
    try std.testing.expectEqual(raw.TopologySource.hwdb, old_info.topology_source);
}

test "regresja: nieznany model rodziny 6 NIE dziedziczy codename z innego wpisu" {
    // Konfiguracja, w której stary matcher zawodził: baza ma wpis
    // Merom/Conroe (Family 6, model 0x0F) i wiele innych wpisów rodziny 6. Dawny
    // `matchCpu` przyznawał `specificity = 1` **dowolnemu** wpisowi o zgodnej
    // rodzinie, więc nieznany model 0x6A raportował się jako „Merom/Conroe”.
    const db = try embedded.load();
    const merom = db.matchCpu(.intel, core.ids.Signature.fromEax(0x000006F2)).?;
    try std.testing.expectEqualStrings("Merom/Conroe", db.text(merom.entry.codename));

    // Ice Lake-SP: rodzina znana, model w bazie nieobecny.
    const unknown = core.ids.Signature.fromEax(0x000606A1);
    try std.testing.expectEqual(@as(u8, 6), unknown.displayFamily());
    try std.testing.expectEqual(@as(u8, 0x6A), unknown.displayModel());

    const m = db.matchCpu(.intel, unknown);
    // Brak trafienia, a nie trafienie „na poziomie rodziny”.
    try std.testing.expect(m == null);
    if (m) |hit| {
        try std.testing.expect(!std.mem.eql(u8, "Merom/Conroe", db.text(hit.entry.codename)));
    }
}

test "regresja: fixture z nieznanym modelem nie dostaje cudzego codename" {
    // `intel_2xsocket_8core` ma model 0x6A, którego nie ma w bazie.
    const r = try runFixture(fixtures.intel_2xsocket_8core);
    const i = &r.info;

    try std.testing.expect(i.microarchitecture == null);
    try std.testing.expect(i.codename == null);
    try std.testing.expectEqual(model.FieldSource.none, i.microarchitecture_source);
    try std.testing.expectEqual(model.FieldSource.none, i.codename_source);

    // Brand string z CPUID **działa** i to jest poprawna sytuacja: nazwa pochodzi
    // z CPUID, a kodname nikt nie umie podać. Jeden heurystyczny poziom dopasowania
    // nie potrafiłby tego rozróżnić — i właśnie dlatego źródła są osobnymi polami.
    try std.testing.expect(i.brand_valid);
    try std.testing.expectEqualStrings("Intel(R) Xeon(R) Gold 6338 CPU @ 2.20GHz", i.brandSlice());
    try std.testing.expectEqual(model.MatchQuality.vendor_only, i.match);
    try std.testing.expectEqual(model.FieldSource.cpuid, i.display_name_source);

    // Regresja Etapu 2 nietknięta: topologia dalej mierzona, nie z bazy.
    try std.testing.expectEqual(raw.TopologySource.hardware, i.topology_source);
    try std.testing.expectEqual(@as(u16, 2), i.packages);
    try std.testing.expectEqual(@as(u16, 16), i.cores_physical);
}

test "regresja: znany model rodziny 6 trafia we właściwy wpis, z dwoma źródłami pól" {
    // `intel_leaf1f` ma model 0x8F (Sapphire Rapids), który jest w bazie.
    const r = try runFixture(fixtures.intel_leaf1f);
    const i = &r.info;

    try std.testing.expectEqualStrings("Sapphire Rapids", i.codename.?);
    try std.testing.expectEqual(model.FieldSource.hwdb_exact, i.codename_source);
    try std.testing.expectEqual(model.FieldSource.hwdb_exact, i.microarchitecture_source);
    // Nazwa pokazana pochodzi z CPUID — inne pole, inne źródło.
    try std.testing.expectEqualStrings("Intel(R) Xeon(R) Platinum 8488C CPU", i.brandSlice());
    try std.testing.expectEqual(model.FieldSource.cpuid, i.display_name_source);
    // Trafienie musi uzasadniać nazwę: nie `.family_generic`, nie `.unknown`.
    try std.testing.expect(i.match != .family_generic);
    try std.testing.expect(i.match != .unknown);
    try std.testing.expect(i.match != .vendor_only);
}

test "hwdb: family_generic działa wyłącznie przy jawnie oznaczonym wpisie" {
    const sig = core.ids.Signature.fromEax(0x000606A1);

    // Wpis SZCZEGÓŁOWY o zgodnej rodzinie nie jest trafieniem rodzinnym, nawet
    // gdyby trafił modelowo. To dokładnie ta luka, która dawała „Merom/Conroe”.
    const detail = hwdb_mod.Entry{
        .vendor = .intel,
        .family_field = 0x6,
        .model_min = 0x0F,
        .model_max = 0x0F,
        .stepping_min = 0,
        .stepping_max = 0xFF,
        .confidence = .high,
    };
    try std.testing.expectEqual(@as(?hwdb_mod.HitLevel, null), detail.hitLevel(sig));

    // Pełny zakres modelu **bez flagi** trafia jak zwykły wzorzec, a nie jak
    // wpis rodzinny — sama szerokość zakresu nie oznacza intencji autora bazy.
    //
    // `stepping_max = 0xFF` jest jawny, bo domyślna wartość pola w strukturze to
    // `0`. Niewywpisanie tego daje zakres `0..0`, w którym **nic** nie trafia —
    // i `hitLevel` uczciwie zwraca wtedy `.no_stepping`. Kompilator bazy
    // zawsze wpisuje `0xFF`, ale ręcznie zbudowany wpis w teście łatwo pominąć.
    const wide = hwdb_mod.Entry{
        .vendor = .intel,
        .family_field = 0x6,
        .model_min = 0x00,
        .model_max = 0xFF,
        .stepping_min = 0,
        .stepping_max = 0xFF,
        .confidence = .high,
    };
    try std.testing.expectEqual(@as(?hwdb_mod.HitLevel, .model_range), wide.hitLevel(sig));

    // Dopiero jawna flaga daje poziom rodziny.
    const generic = hwdb_mod.Entry{
        .vendor = .intel,
        .family_field = 0x6,
        .model_min = 0x00,
        .model_max = 0xFF,
        .stepping_min = 0,
        .stepping_max = 0xFF,
        .family_generic = true,
        .confidence = .low,
    };
    try std.testing.expectEqual(@as(?hwdb_mod.HitLevel, .family_only), generic.hitLevel(sig));
    const hit = hwdb_mod.Match{ .entry = generic, .exact_stepping = false, .level = .family_only };
    // ...ale z niego **nie wolno** brać kwirków: `smt_threads` to własność wariantu,
    // a wzięcie go stworzyłoby szerokość SMT z bazy wyglądającą jak pomiar.
    try std.testing.expect(!hwdb_mod.canUseQuirks(hit));
}

test "dekor: nieznana generacja AMD nie udaje, że ją zna" {
    const db = try embedded.load();
    // Family 19h Model 0xE3 — poza zakresami w bazie.
    const sig = core.ids.Signature.fromEax(0x00E30F10);
    // Dawniej zwracał trafienie `specificity <= 1`, czyli **cudzy** wpis rodziny 19h.
    // Teraz: brak trafienia. Nazwa pochodzi z brand stringu albo jest generowana.
    const m = db.matchCpu(.amd, sig);
    try std.testing.expect(m == null);
}

// ---------------------------------------------------------------------------
// Wersjonowanie bazy. Format jest wewnętrzny, ale `ferrum-hwdb.bin` ma być
// przenoszony między instalacjami, więc zgodność musi być egzekwowana, nie
// zakładana. Testy budują bazę ręcznie — `buildTestDb` z dekodera służy do
// testowania dekodowania, tu chodzi o **walidację nagłówka**.
// ---------------------------------------------------------------------------

const DbOpts = struct {
    format: u16 = hwdb_mod.format_version,
    min_reader: u16 = hwdb_mod.minimum_reader_version,
    features: u32 = 0,
    payload_len: u32 = 0,
    bad_magic: bool = false,
    corrupt_hash: bool = false,
};

/// Minimalna, poprawna baza: 0 wpisów, pusta pula napisów, poprawna suma.
///
/// Zwraca **pełną** alokację. Test ucięcia robi `full[0..n]` dopiero przy
/// użyciu — oddanie wycinka z `syntheticDb` psułoby `free`, bo
/// `std.testing.allocator` widziałby 40 bajtów zamiast przydzielonych 72.
fn syntheticDb(alloc: std.mem.Allocator, o: DbOpts) ![]u8 {
    const buf = try alloc.alloc(u8, hwdb_mod.header_size);
    errdefer alloc.free(buf);
    @memset(buf, 0);
    if (!o.bad_magic) @memcpy(buf[0..8], hwdb_mod.magic);
    std.mem.writeInt(u16, buf[8..10], o.format, .little);
    std.mem.writeInt(u16, buf[10..12], hwdb_mod.schema_version, .little);
    std.mem.writeInt(u16, buf[12..14], o.min_reader, .little);
    std.mem.writeInt(u32, buf[16..20], 1, .little);
    std.mem.writeInt(u32, buf[24..28], o.features, .little);
    std.mem.writeInt(u32, buf[28..32], 0, .little); // bytes puli napisów
    std.mem.writeInt(u32, buf[32..36], 0, .little); // liczba wpisów
    std.mem.writeInt(u32, buf[68..72], o.payload_len, .little);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(buf[hwdb_mod.header_size..]);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    @memcpy(buf[36..68], &digest);
    if (o.corrupt_hash) buf[50] ^= 0xFF;
    return buf;
}

test "hwdb versioning: poprawna baza wczytuje się i deklaruje swoje pola" {
    const db = try syntheticDb(std.testing.allocator, .{ .features = hwdb_mod.FeatureFlags.supported });
    defer std.testing.allocator.free(db);
    const h = try hwdb_mod.Hwdb.init(db);
    try std.testing.expectEqual(@as(u32, 0), h.payload_length);
    try std.testing.expectEqual(hwdb_mod.FeatureFlags.supported, h.feature_flags);
    try std.testing.expectEqual(@as(usize, 0), h.count());
}

test "hwdb versioning: stary format jest odrzucony, nie czytany po cichu" {
    // To jest scenariusz „stary czytnik / nowa baza” odwrócony: nasz czytnik
    // v2 nie może wczytać bazy v1, bo `entry_size` wzrosło z 40 do 52 i czytanie
    // „na wiarę” zwróciłoby przesunięte pola napisowe — czyli **błędną nazwę CPU**.
    const db = try syntheticDb(std.testing.allocator, .{ .format = 1 });
    defer std.testing.allocator.free(db);
    try std.testing.expectError(error.UnsupportedFormat, hwdb_mod.Hwdb.init(db));
}

test "hwdb versioning: baza wymagająca nowszego czytnika jest odrzucona" {
    const db = try syntheticDb(std.testing.allocator, .{ .min_reader = hwdb_mod.minimum_reader_version + 1 });
    defer std.testing.allocator.free(db);
    try std.testing.expectError(error.UnsupportedReader, hwdb_mod.Hwdb.init(db));
}

test "hwdb versioning: nieznana flaga funkcji jest odrzucona" {
    // Bit 31 nie jest zdefiniowany przez nikogo. Nie wolno go zignorować —
    // „nieznane, ale pewnie nieistotne” to dokładnie ta myśl, przez którą nowy
    // format wciska się do starego czytnika i daje błędne dane.
    const db = try syntheticDb(std.testing.allocator, .{ .features = 1 << 31 });
    defer std.testing.allocator.free(db);
    try std.testing.expectError(error.UnknownFeatureFlags, hwdb_mod.Hwdb.init(db));
}

test "hwdb versioning: uszkodzona suma kontrolna jest odrzucona" {
    const db = try syntheticDb(std.testing.allocator, .{ .corrupt_hash = true });
    defer std.testing.allocator.free(db);
    try std.testing.expectError(error.HashMismatch, hwdb_mod.Hwdb.init(db));
}

test "hwdb versioning: zły nagłówek (magic) jest odrzucony" {
    const db = try syntheticDb(std.testing.allocator, .{ .bad_magic = true });
    defer std.testing.allocator.free(db);
    try std.testing.expectError(error.BadMagic, hwdb_mod.Hwdb.init(db));
}

test "hwdb versioning: ucięta baza jest odrzucona" {
    const full = try syntheticDb(std.testing.allocator, .{});
    defer std.testing.allocator.free(full);
    // Ucinamy przy użyciu, nie w fabryce — inaczej `free` dostałby wycinek
    // 40 bajtów z alokacji 72 i zgłosiłby błędny rozmiar.
    const db = full[0..40];
    try std.testing.expectError(error.Truncated, hwdb_mod.Hwdb.init(db));
}

test "hwdb versioning: payload dłuższy niż plik jest odrzucony" {
    // Baza z doklejonymi danymi spoza formatu. Długość w nagłówku musi się
    // zgadzać z rozmiarem pliku, inaczej dopisane bajty byłyby po cichu ignorowane.
    const db = try syntheticDb(std.testing.allocator, .{ .payload_len = 1000 });
    defer std.testing.allocator.free(db);
    try std.testing.expectError(error.Truncated, hwdb_mod.Hwdb.init(db));
}

// ---------------------------------------------------------------------------
// Format v3: fakty sygnatury (`Fact`) i refinament z brand stringu
// (`BrandRule`). Testy ładują **prawdziwą** bazę osadzoną, nie syntetyczną —
// syntetyczna nie zawiera sekcji, których tu sprawdzamy.
// ---------------------------------------------------------------------------

const ids = core.ids;

/// Sygnatura AMD Zen 3 desktop (Ryzen 5000) zmierzona na 5800X3D.
/// 5800X i 5800X3D mają **identyczną** sygnaturę — różni je wyłącznie brand.
const AMD_ZEN3_DESKTOP = 0x00A20F12;

fn synthRaw(vendor: ids.CpuVendor, eax: u32, brand_text: []const u8) raw.RawCpuInfo {
    var r = raw.RawCpuInfo{
        .cpuid_available = true,
        .vendor = vendor,
        .signature = ids.Signature.fromEax(eax),
        .brand_valid = true,
    };
    @memcpy(r.brand[0..brand_text.len], brand_text);
    return r;
}

fn decodeSynth(vendor: ids.CpuVendor, eax: u32, brand_text: []const u8) !model.CpuInfo {
    const db = try embedded.load();
    const r = synthRaw(vendor, eax, brand_text);
    var info: model.CpuInfo = .{};
    _ = decoder.decode(&r, db, &info);
    return info;
}

test "hwdb v3: sekcje Fact i BrandRule są osadzone i policzone" {
    const db = try embedded.load();
    // Milan-B1, Milan-B2, Vermeer-B2, AM4 (db/source/cpu/amd.toml).
    try std.testing.expectEqual(@as(usize, 4), db.factCount());
    try std.testing.expectEqual(@as(usize, 1), db.brandRuleCount());
    // Granice sekcji muszą mieścić się w pliku — inaczej czytnik czytałby bajty
    // spoza końca pliku (albo, co gorsza, z innej sekcji).
    const f = db.factsBounds();
    const b = db.brandRulesBounds();
    try std.testing.expect(f.start >= db.entriesBounds().end);
    try std.testing.expectEqual(f.end, b.start);
    try std.testing.expect(b.end <= embedded.bytes.len);
}

test "hwdb v3: nazwa stepppingu i gniazdo czytają się dla zmierzonej sygnatury" {
    const db = try embedded.load();
    const sig = ids.Signature.fromEax(AMD_ZEN3_DESKTOP);

    const f = db.steppingNameFact(hwdb_mod.VendorId.amd, sig);
    try std.testing.expect(f != null);
    try std.testing.expectEqualStrings("Vermeer-B2", db.text(f.?.stepping_name));

    const s = db.socketFact(hwdb_mod.VendorId.amd, sig);
    try std.testing.expect(s != null);
    try std.testing.expectEqualStrings("AM4", db.text(s.?.socket_name));
}

test "hwdb v3: fakty innego vendora nie trafiają do AMD" {
    const db = try embedded.load();
    const sig = ids.Signature.fromEax(AMD_ZEN3_DESKTOP);
    try std.testing.expect(db.steppingNameFact(.intel, sig) == null);
    try std.testing.expect(db.socketFact(.intel, sig) == null);
}

test "hwdb v3: zakres stepppingu jest respektowany" {
    // stepping 0 to nie stepping 2 — nazwa `Vermeer-B2` go nie opisuje.
    const db = try embedded.load();
    const sig0 = ids.Signature.fromEax(0x00A20F10);
    try std.testing.expect(db.steppingNameFact(.amd, sig0) == null);
}

test "identyfikacja 5800X3D: stepping_name, socket i wariant z brandu" {
    const info = try decodeSynth(.amd, AMD_ZEN3_DESKTOP, "AMD Ryzen 7 5800X3D 8-Core Processor");

    // Surowy stepping to odczyt CPUID i nie wolno mu stać się nazwą.
    try std.testing.expectEqual(@as(u8, 2), info.stepping);
    try std.testing.expectEqualStrings("Vermeer-B2", info.stepping_name orelse "BRAK");
    try std.testing.expectEqualStrings("AM4", info.socket_name orelse "BRAK");
    try std.testing.expectEqualStrings("3D V-Cache", info.variant orelse "BRAK");
    try std.testing.expectEqualStrings("Ryzen 7 5800X3D", info.product_name orelse "BRAK");

    // Architektura i kodname nadal z HWDB — brand ich nie dotykał.
    try std.testing.expectEqualStrings("Zen 3", info.microarchitecture orelse "BRAK");
    try std.testing.expect(info.codename != null);
    try std.testing.expectEqual(ids.CpuVendor.amd, info.vendor);
}

// ---------------------------------------------------------------------------
// §0 Etapu 3A: zawężanie ogólnego codename przez brand refinement
//
// Mechanizm jest przygotowany, ale **pusty w bazie**: podział Vermeer/Milan-X
// na granicy 0x2F/0x30 nie został potwierdzony i nie będziemy go zgadywać.
// Testy poniżej pilnują, żeby bramka provenance blokowała zgadywanie, gdyby
// ktoś kiedyś próbował dodać taki wpis „na oko".
// ---------------------------------------------------------------------------

test "§0: zawężanie codename jest wstrzymane, dopóki provenance jest obserwacją" {
    // Reguła z `refined_codename`, ale `source_type = reference_observation`
    // (dokładnie ten przypadek, który dałoby „Vermeer” z porównania z CPU-Z).
    const observational: hwdb_mod.BrandRule = .{
        .vendor = .amd,
        .ext_family = 0x0A,
        .family_field = 0x0F,
        .refined_codename = .{ .off = 0, .len = 7 },
        .source_type = .reference_observation,
        .brand_pattern = .{ .off = 0, .len = 7 },
    };
    // Bramka musi odmówić: zawężanie na podstawie obserwacji to zgadywanie.
    try std.testing.expect(!observational.canNarrowCodename());

    // Ta sama reguła z dokumentacją producenta przechodzi.
    const documented: hwdb_mod.BrandRule = .{
        .vendor = .amd,
        .ext_family = 0x0A,
        .family_field = 0x0F,
        .refined_codename = .{ .off = 0, .len = 7 },
        .source_type = .vendor_doc,
        .brand_pattern = .{ .off = 0, .len = 7 },
    };
    try std.testing.expect(documented.canNarrowCodename());

    // Wpis społecznościowy też nie wystarcza.
    const community: hwdb_mod.BrandRule = .{
        .vendor = .amd,
        .refined_codename = .{ .off = 0, .len = 7 },
        .source_type = .community,
        .brand_pattern = .{ .off = 0, .len = 7 },
    };
    try std.testing.expect(!community.canNarrowCodename());

    // Pusta wartość to brak zawężenia, nigdy „zawężenie do zera”.
    const empty: hwdb_mod.BrandRule = .{
        .vendor = .amd,
        .source_type = .vendor_doc,
        .brand_pattern = .{ .off = 0, .len = 7 },
    };
    try std.testing.expect(!empty.canNarrowCodename());
}

test "§0: szeroki HWDB nadal zwraca zawężony zakres, a refined pozostaje pusty" {
    // Dopóki niezależnego źródła nie ma, `codename` zostaje szeroki, a
    // `codename_refined` = null. To **celowy stan**, nie regresja.
    const info = try decodeSynth(.amd, AMD_ZEN3_DESKTOP, "AMD Ryzen 7 5800X3D 8-Core Processor");
    try std.testing.expect(info.codename_refined == null);
    try std.testing.expect(info.codename_refined_source == .none);
    // Zakres 0x20..0x2F to wyłącznie Vermeer; Milan-X leży w 0x00..0x0F
    // (AMD Revision Guide 56683), więc nazwa nie może go już wymieniać.
    try std.testing.expectEqualStrings("Vermeer", info.codename orelse "");
    try std.testing.expect(std.mem.indexOf(u8, info.codename orelse "", "Milan") == null);
}

test "§0: zawężony codename nie może nadpisać szerokiego" {
    // Gdyby kiedyś pojawił się zweryfikowany wpis, obie wartości muszą współistnieć.
    // Budujemy model ręcznie, bo baza celowo nie zawiera jeszcze takiego wpisu.
    var info: model.CpuInfo = .{};
    info.codename = "Vermeer / Milan-X (Zen 3)";
    info.codename_refined = "Vermeer";
    info.codename_refined_source = .brand_derived;
    try std.testing.expectEqualStrings("Vermeer / Milan-X (Zen 3)", info.codename.?);
    try std.testing.expectEqualStrings("Vermeer", info.codename_refined.?);
    try std.testing.expectEqual(model.FieldSource.brand_derived, info.codename_refined_source);
}

test "identyfikacja 5800X: ta sama sygnatura, brak wariantu 3D V-Cache" {
    // 5800X i 5800X3D mają identyczną sygnaturę CPUID. Różni je brand, więc
    // ten test dowodzi, że wariant pochodzi z brandu, a nie z dopasowania.
    const info = try decodeSynth(.amd, AMD_ZEN3_DESKTOP, "AMD Ryzen 7 5800X 8-Core Processor");
    try std.testing.expect(info.variant == null);
    try std.testing.expectEqualStrings("Vermeer-B2", info.stepping_name.?);
    try std.testing.expectEqualStrings("AM4", info.socket_name.?);
}

test "identyfikacja: nieznany brand przy znanej sygnaturze zostawia HWDB bez wariantu" {
    const info = try decodeSynth(.amd, AMD_ZEN3_DESKTOP, "AMD Unknown Engineering Sample");
    try std.testing.expect(info.microarchitecture != null);
    try std.testing.expect(info.codename != null);
    try std.testing.expect(info.variant == null);
}

test "identyfikacja: uszkodzony brand nie daje wariantu i nie wywraca dekodera" {
    const db = try embedded.load();
    var r = synthRaw(.amd, AMD_ZEN3_DESKTOP, "");
    r.brand_valid = false;
    var info: model.CpuInfo = .{};
    _ = decoder.decode(&r, db, &info);
    try std.testing.expect(info.variant == null);
}

test "identyfikacja: reguła AMD nie dotyka procesora Intela" {
    // Brand Intela celowo zawiera „5800X3D”. Reguła brand jest ograniczona
    // zakresem w bazie, więc ten tekst nie może jej uruchomić.
    const info = try decodeSynth(.intel, 0x000806F0, "Intel(R) Core(TM) i7-12700K 5800X3D");
    try std.testing.expect(info.variant == null);
    try std.testing.expect(info.product_name == null);
}

test "identyfikacja: brand nie nadpisuje twardych danych CPUID" {
    const before = try decodeSynth(.amd, AMD_ZEN3_DESKTOP, "AMD Ryzen 7 5800X 8-Core Processor");
    const after = try decodeSynth(.amd, AMD_ZEN3_DESKTOP, "AMD Ryzen 7 5800X3D 8-Core Processor");
    // Sygnatura i rodzina są identyczne; brand zmienia **tylko** to, co pochodzi
    // z brandu. Gdyby reguła pisała po `stepping` albo `model`, ten test padłby.
    try std.testing.expectEqual(before.signature.eax, after.signature.eax);
    try std.testing.expectEqual(before.display_family, after.display_family);
    try std.testing.expectEqual(before.display_model, after.display_model);
    try std.testing.expectEqual(before.stepping, after.stepping);
    try std.testing.expectEqual(before.vendor, after.vendor);
}

test "source tracking: surowy stepping to hardware, stepping_name to interpretacja" {
    const info = try decodeSynth(.amd, AMD_ZEN3_DESKTOP, "AMD Ryzen 7 5800X3D 8-Core Processor");

    // Nazwa stepppingu jest wyprowadzona z konwencji AMD dla sąsiedniego
    // zakresu modeli (Revision Guide 56683) — nie z CPU-Z — i to musi być
    // widoczne w polu źródłowym: typ dowodu `vendor_doc_adjacent`, nie `vendor_doc`.
    try std.testing.expect(info.stepping_name_source != model.FieldSource.empirical);
    try std.testing.expect(info.stepping_name_source.isDerived());
    try std.testing.expectEqual(
        model.ProvenanceType.vendor_doc_adjacent,
        info.stepping_name_provenance.source_type,
    );
    try std.testing.expectEqual(model.Confidence.medium, info.stepping_name_provenance.confidence);
    try std.testing.expect(!info.stepping_name_provenance.isEmpty());
}

test "source tracking: pola pochodzą z różnych warstw, każda ze swoim źródłem" {
    const info = try decodeSynth(.amd, AMD_ZEN3_DESKTOP, "AMD Ryzen 7 5800X3D 8-Core Processor");

    // Wariant — z brandu.
    try std.testing.expectEqual(model.FieldSource.brand_derived, info.variant_source);
    // Gniazdo — z bazy.
    try std.testing.expectEqual(model.FieldSource.hwdb_exact, info.socket_source);
    // Kodname — z dopasowanego wzorca HWDB (zakres modeli), nie z pomiaru.
    try std.testing.expectEqual(model.FieldSource.hwdb_pattern, info.codename_source);
    // Surowy stepping — z CPUID, czyli z odczytu sprzętu.
    try std.testing.expectEqual(model.FieldSource.cpuid, info.signature_source);
}

test "source tracking: Socket Designation ze SMBIOS nie staje się socket_name" {
    const info = try decodeSynth(.amd, AMD_ZEN3_DESKTOP, "AMD Ryzen 7 5800X3D 8-Core Processor");
    // Dziś nie odczytujemy SMBIOS, więc pola są puste. Warunek poniżej jest
    // ważny na przyszłość: gdy dodamy odczyt, „CPU1” czy „J202” **nie może**
    // zostać podstawione jako typ gniazda procesora.
    try std.testing.expect(info.smbios_socket_designation == null);
    try std.testing.expectEqual(model.FieldSource.hwdb_exact, info.socket_source);
    try std.testing.expect(info.smbios_socket_source == .none);
}

test "package_contacts zostaje nieznane bez potwierdzonego źródła" {
    const info = try decodeSynth(.amd, AMD_ZEN3_DESKTOP, "AMD Ryzen 7 5800X3D 8-Core Processor");
    // CPU-Z pokazuje 1331, ale nie mamy niezależnego potwierdzenia producenta.
    // Wolno zostawić `unknown`, niedozwolone jest przepisywać obserwację
    // narzędzia referencyjnego jako daną producenta.
    try std.testing.expectEqual(@as(u16, 0), info.package_contacts);
}

// ---------------------------------------------------------------------------
// Przegląd zakresów AMD (2026-11-15): Revision Guides AMD, Linux amd.c, InstLatx64
// ---------------------------------------------------------------------------

fn amdHit(eax: u32) ?struct { uarch: []const u8, codename: []const u8 } {
    const db = embedded.load() catch return null;
    const m = db.matchCpu(.amd, ids.Signature.fromEax(eax)) orelse return null;
    return .{ .uarch = db.text(m.entry.uarch), .codename = db.text(m.entry.codename) };
}

test "hwdb AMD: zakresy modeli wg dokumentacji i publicznych zrzutów CPUID" {
    const cases = [_]struct { eax: u32, uarch: []const u8, codename_has: []const u8 }{
        .{ .eax = 0x00A00F12, .uarch = "Zen 3", .codename_has = "Milan-X" }, // AMD RG 56683
        .{ .eax = 0x00A20F12, .uarch = "Zen 3", .codename_has = "Vermeer" },
        .{ .eax = 0x00A50F00, .uarch = "Zen 3", .codename_has = "Cezanne" },
        .{ .eax = 0x00A40F41, .uarch = "Zen 3+", .codename_has = "Rembrandt" },
        .{ .eax = 0x00A60F12, .uarch = "Zen 4", .codename_has = "Raphael" },
        .{ .eax = 0x00A70F41, .uarch = "Zen 4", .codename_has = "Phoenix" },
        .{ .eax = 0x00870F10, .uarch = "Zen 2", .codename_has = "Matisse" },
        .{ .eax = 0x00860F01, .uarch = "Zen 2", .codename_has = "Renoir" },
        .{ .eax = 0x00800F82, .uarch = "Zen / Zen+", .codename_has = "Pinnacle Ridge" },
        .{ .eax = 0x00B00F21, .uarch = "Zen 5", .codename_has = "Turin" }, // AMD RG 58251
        .{ .eax = 0x00B40F40, .uarch = "Zen 5", .codename_has = "Granite Ridge" },
        .{ .eax = 0x00600F20, .uarch = "Bulldozer / Piledriver", .codename_has = "Vishera" },
    };
    for (cases) |c| {
        const h = amdHit(c.eax) orelse {
            std.debug.print("brak trafienia dla 0x{X:0>8}\n", .{c.eax});
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqualStrings(c.uarch, h.uarch);
        if (std.mem.indexOf(u8, h.codename, c.codename_has) == null) {
            std.debug.print("0x{X:0>8}: '{s}' nie zawiera '{s}'\n", .{ c.eax, h.codename, c.codename_has });
            return error.TestUnexpectedResult;
        }
    }
    // Vermeer nie wymienia już Milan-X (to inny zakres modeli).
    try std.testing.expect(std.mem.indexOf(u8, amdHit(0x00A20F10).?.codename, "Milan") == null);
    // Model bez publicznego produktu nie dostaje cudzej nazwy.
    try std.testing.expect(amdHit(0x00A30F00) == null);
}

test "hwdb AMD: rewizje Milan wprost z AMD Revision Guide 56683" {
    const db = try embedded.load();
    const f = db.steppingNameFact(.amd, ids.Signature.fromEax(0x00A00F12)).?;
    try std.testing.expectEqualStrings("Milan-B2", db.text(f.stepping_name));
}

// ---------------------------------------------------------------------------
// Dane systemowe: replay `.sysimg` przez te same strony co GUI i CLI
// ---------------------------------------------------------------------------

const app = @import("app.zig");
const pci_embedded = @import("db/pci_embedded.zig");
const sysimg = ferrum.capture.sysimg;
const sys_report = ferrum.sys.report;

fn findPage(pages: []const sys_report.Page, id: []const u8) *const sys_report.Page {
    for (pages) |*p| if (std.mem.eql(u8, p.id, id)) return p;
    @panic("brak strony");
}

fn fieldValue(p: *const sys_report.Page, section_prefix: []const u8, label: []const u8) ?[]const u8 {
    for (p.sections.items) |s| {
        if (!std.mem.startsWith(u8, s.title, section_prefix)) continue;
        for (s.fields.items) |f| if (std.mem.eql(u8, f.label, label)) return f.value;
    }
    return null;
}

fn replayState() !*app.State {
    return app.State.create(std.testing.allocator, .{
        .cpu_replay = fixtures.amd_ryzen7_5800x3d_native,
        .cpu_replay_name = "amd_ryzen7_5800x3d_native.cpuimg",
        .sys_replay = fixtures.sys_asrock_b550,
        .sys_replay_name = "asrock_b550_5800x3d_rx7900xtx.sysimg",
        .live = false,
    });
}

test "sysimg replay: płyta, chipset i BIOS z SMBIOS + pci.ids" {
    const st = try replayState();
    defer st.destroy();
    const pages = st.buildPages();
    const board = findPage(pages, "board");
    try std.testing.expectEqualStrings("ASRock B550 Taichi", board.headline);
    try std.testing.expectEqualStrings("AMD 500 Series Chipset", fieldValue(board, "Chipset", "Chipset").?);
    try std.testing.expectEqualStrings("Starship/Matisse Root Complex", fieldValue(board, "Chipset", "Mostek hosta").?);
    try std.testing.expectEqualStrings("P3.20", fieldValue(board, "BIOS", "Wersja").?);
    try std.testing.expectEqualStrings("Socket AM4", fieldValue(board, "Gniazdo", "Gniazdo").?);
}

test "sysimg replay: pamięć z SMBIOS typ 17" {
    const st = try replayState();
    defer st.destroy();
    const mem = findPage(st.buildPages(), "memory");
    try std.testing.expectEqualStrings("32 GB DDR4", mem.headline);
    try std.testing.expectEqualStrings("2 z 4 zajęte", fieldValue(mem, "Podsumowanie", "Gniazda").?);
    try std.testing.expectEqualStrings("4000 MT/s", fieldValue(mem, "Gniazdo DIMM 1", "Prędkość skonfigurowana").?);
    try std.testing.expectEqualStrings("F4-4000C18-16GTZR", fieldValue(mem, "Gniazdo DIMM 1", "Part number").?);
}

test "sysimg replay: mapa gniazd — 2 z 4 (DIMM 1 i DIMM 3), banki P0 CHANNEL A/B" {
    const st = try replayState();
    defer st.destroy();
    const pages = st.buildPages();
    const mem = findPage(pages, "memory");
    try std.testing.expectEqual(@as(usize, 4), mem.slots.len);
    const want_label = [_][]const u8{ "A1", "A2", "B1", "B2" };
    const want_bank = [_][]const u8{ "P0 CHANNEL A", "P0 CHANNEL A", "P0 CHANNEL B", "P0 CHANNEL B" };
    for (mem.slots, 0..) |sl, i| {
        try std.testing.expectEqual(@as(u16, @intCast(i + 1)), sl.index);
        try std.testing.expectEqualStrings(want_label[i], sl.label);
        try std.testing.expectEqualStrings(want_bank[i], sl.bank);
        // Obsadzone: #2 (DIMM 1, kanał A) i #4 (DIMM 1, kanał B) — w numeracji 0..3 to DIMM 1 i DIMM 3.
        try std.testing.expectEqual(i == 1 or i == 3, sl.occupied);
    }
    try std.testing.expectEqualStrings("DIMM 1", mem.slots[1].locator);
    try std.testing.expectEqual(@as(?u64, 16 * 1024 * 1024 * 1024), mem.slots[1].size_bytes);
    try std.testing.expectEqualStrings("DDR4", mem.slots[1].mem_type);
    // Producent „Unknown” (zaślepka) → rozpoznany z numeru części F4-….
    try std.testing.expectEqualStrings("gskill", mem.slots[1].vendor_key);
    try std.testing.expectEqualStrings("pusty", fieldValue(mem, "Mapa gniazd", "#1 DIMM 0").?);
    try std.testing.expect(std.mem.startsWith(u8, fieldValue(mem, "Mapa gniazd", "#2 DIMM 1").?, "16 GB DDR4"));
    try std.testing.expectEqualStrings("dwukanałowo (A+B)", fieldValue(mem, "Mapa gniazd", "Tryb pracy kanałów").?);

    // JSON: tablica `slots` ze stałymi kluczami.
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try sys_report.writeJson(&out.writer, st.reportOf(pages), .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    var found = false;
    for (parsed.value.object.get("pages").?.array.items) |p| {
        const slots = p.object.get("slots") orelse continue;
        found = true;
        try std.testing.expectEqualStrings("memory", p.object.get("id").?.string);
        const s1 = slots.array.items[1].object;
        try std.testing.expectEqual(@as(i64, 2), s1.get("index").?.integer);
        try std.testing.expectEqualStrings("A2", s1.get("label").?.string);
        try std.testing.expectEqualStrings("A", s1.get("channel").?.string);
        try std.testing.expect(s1.get("occupied").?.bool);
        try std.testing.expectEqual(@as(i64, 17179869184), s1.get("size_bytes").?.integer);
        try std.testing.expectEqualStrings("DDR4", s1.get("type").?.string);
        try std.testing.expect(slots.array.items[0].object.get("size_bytes").? == .null);
    }
    try std.testing.expect(found);
}

test "sysimg replay: grafika z DXGI + pci.ids (chip, karta, łącze)" {
    const st = try replayState();
    defer st.destroy();
    const g = findPage(st.buildPages(), "graphics");
    try std.testing.expectEqualStrings("AMD Radeon RX 7900 XTX", g.headline);
    try std.testing.expect(std.mem.startsWith(u8, fieldValue(g, "GPU: AMD Radeon RX 7900 XTX", "Układ GPU").?, "Navi 31"));
    try std.testing.expectEqualStrings("1849:5304", fieldValue(g, "GPU: AMD Radeon RX 7900 XTX", "Subsystem").?);
    // pci.ids zna dla 1849:5304 tylko „Radeon RX 7900 XTX” (nazwa układu) — modelu nie zgadujemy.
    try std.testing.expectEqualStrings("ASRock", fieldValue(g, "GPU: AMD Radeon RX 7900 XTX", "Producent karty").?);
    try std.testing.expectEqualStrings("ASRock (model nieznany)", fieldValue(g, "GPU: AMD Radeon RX 7900 XTX", "Model karty").?);
    try std.testing.expect(std.mem.indexOf(u8, fieldValue(g, "GPU: AMD Radeon RX 7900 XTX", "Łącze PCIe").?, "x16") != null);
    // Replay nie ma bibliotek producenta: czujniki są „niedostępne” z powodem, nie zerem.
    try std.testing.expectEqualStrings("—", fieldValue(g, "Czujniki GPU: AMD Radeon RX 7900 XTX", "Temperatura GPU").?);
    try std.testing.expect(g.links.items.len >= 2);
}

test "sysimg replay: dyski — NVMe log i ATA SMART dekodowane z capture" {
    const st = try replayState();
    defer st.destroy();
    const d = findPage(st.buildPages(), "storage");
    var nvme: usize = 0;
    var healthy: usize = 0;
    for (d.sections.items) |s| {
        for (s.fields.items) |f| {
            if (std.mem.eql(u8, f.label, "Magistrala") and std.mem.eql(u8, f.value, "NVMe")) nvme += 1;
            if (std.mem.eql(u8, f.label, "Stan zdrowia") and std.mem.eql(u8, f.value, "dobry")) healthy += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), nvme);
    try std.testing.expect(healthy >= 8);
}

test "sysimg replay: fixture nie zawiera numerów seryjnych, a raport je maskuje" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = try sysimg.parse(arena.allocator(), fixtures.sys_asrock_b550);
    try std.testing.expect(s.serials_masked);

    const st = try replayState();
    defer st.destroy();
    const pages = st.buildPages();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try sys_report.writeJson(&out.writer, st.reportOf(pages), .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();
    // Każde pole oznaczone jako wrażliwe jest w JSON zamaskowane albo jest zaślepką.
    for (parsed.value.object.get("pages").?.array.items) |p| {
        for (p.object.get("sections").?.array.items) |sec| {
            for (sec.object.get("fields").?.array.items) |f| {
                if (!f.object.get("sensitive").?.bool) continue;
                const v = f.object.get("value").?.string;
                const st_ = f.object.get("state").?.string;
                try std.testing.expect(std.mem.indexOfScalar(u8, v, '*') != null or !std.mem.eql(u8, st_, "ok"));
            }
        }
    }
}

test "gpu_boards: wbudowana tabela kuratorowana parsuje się, a nazwa przypięta ma pierwszeństwo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gb = ferrum.sys.gpu_boards;
    const curated = try gb.parse(arena.allocator(), @import("links_embedded").gpu_boards_text);
    for (curated) |e| try std.testing.expectEqualStrings("manual", e.source);
    const user = [_]gb.Entry{.{ .subsys = "1849:5304", .model = "ASRock Radeon RX 7900 XTX (test)", .source = "user" }};
    const r = gb.resolve(.{ .user = &user, .curated = curated }, .{ .sub_vendor = 0x1849, .sub_device = 0x5304, .pciids_board = "Radeon RX 7900 XTX" }).?;
    try std.testing.expectEqual(gb.Origin.user, r.origin);
}

test "pci.ids: wbudowana baza otwiera się i zna typowe urządzenia" {
    const db = pci_embedded.get().?;
    try std.testing.expect(db.counts().vendors > 2000);
    try std.testing.expectEqualStrings("Starship/Matisse Root Complex", db.deviceName(0x1022, 0x1480).?);
    try std.testing.expect(std.mem.indexOf(u8, pci_embedded.attribution, "BSD") != null);
}

test "CPU page: cache w stylu „8 x 32 KB” i lista instrukcji z replay" {
    const st = try replayState();
    defer st.destroy();
    const cpu = findPage(st.buildPages(), "cpu");
    try std.testing.expectEqualStrings("8 x 32 KB", fieldValue(cpu, "Pamięć podręczna", "L1 Data").?);
    try std.testing.expectEqualStrings("1 x 96 MB", fieldValue(cpu, "Pamięć podręczna", "L3").?);
    const ins = fieldValue(cpu, "Zestaw instrukcji", "Instrukcje").?;
    inline for (.{ "MMX", "SSE4.2", "x86-64", "AVX2", "AES", "SHA" }) |n| {
        try std.testing.expect(std.mem.indexOf(u8, ins, n) != null);
    }
    try std.testing.expectEqualStrings("x86-64-v3", fieldValue(cpu, "Zestaw instrukcji", "Poziom x86-64").?);
}

test "GUI: komórki widoku uporządkowanego wskazują istniejące pola raportu" {
    // Wiązanie nie może zależeć od języka: strony budowane w pl i w en.
    const i18n = ferrum.i18n;
    const loc_sources = i18n.embeddedSources(@import("locales_embedded"));
    i18n.setSources(&loc_sources);
    defer {
        i18n.setSources(&.{});
        i18n.setLocale("pl");
    }
    for ([_][]const u8{ "pl", "en" }) |code| {
        i18n.setLocale(code);
        try checkFormsBinding();
    }
}

fn checkFormsBinding() !void {
    const forms = @import("gui/forms.zig");
    const st = try replayState();
    defer st.destroy();
    const pages = st.buildPages();
    var missing: usize = 0;
    for (forms.tabs) |t| {
        if (t.kind != .form) continue;
        const p = forms.findPage(pages, t.page).?;
        // Moduł 1 jest obsadzony (gniazdo 0 jest puste na tej płycie).
        const idx: usize = if (std.mem.eql(u8, t.id, "memory")) 1 else 0;
        for (t.bands) |band| for (band) |g| for (g.rows) |r| for (r) |c| {
            // Zegary/obciążenie istnieją tylko przy pomiarze na żywo; dyski mają
            // różne zestawy pól (HDD nie ma zużycia, ATA nie ma błędów nośnika).
            if (std.mem.startsWith(u8, c.sect, "Zegary") or std.mem.startsWith(u8, c.sect, "Obciążenie") or
                std.mem.eql(u8, t.id, "storage") or std.mem.startsWith(u8, c.sect, "@Czujniki")) continue;
            if (forms.resolve(p, c, idx) == null) {
                std.debug.print("brak pola [{s}]: {s} / {s} / {s}\n", .{ ferrum.i18n.locale(), t.id, c.sect, c.field });
                missing += 1;
            }
        };
    }
    try std.testing.expectEqual(@as(usize, 0), missing);
    const g = forms.findPage(pages, "graphics").?;
    try std.testing.expectEqual(@as(usize, 1), forms.instanceCount(g, "GPU: {name}"));
    try std.testing.expect(forms.findLink(g, "gpu_search", forms.instanceName(g, "GPU: {name}", 0).?) != null);
}

test "GUI: każdy klucz logo z build.zig ma plik i jest poprawnym PNG" {
    const logos = @import("logos_embedded");
    try std.testing.expect(logos.all.len >= 18);
    for (logos.all) |l| {
        try std.testing.expect(std.mem.startsWith(u8, l.bytes, "\x89PNG\r\n\x1a\n"));
    }
    // Łańcuch dla 5800X3D trafia w `amd-ryzen` (nie ma osobnego `amd-ryzen-7`).
    const badge = @import("gui/badge.zig");
    var t: badge.Text = .{};
    badge.fromCpu(&t, "amd", "AMD Ryzen 7 5800X3D 8-Core Processor");
    var st: [6][64]u8 = undefined;
    var out: [6][]const u8 = undefined;
    var found: ?[]const u8 = null;
    for (badge.logoKeys(t.badge, &st, &out)) |k| {
        for (logos.all) |l| if (found == null and std.mem.eql(u8, l.name, k)) {
            found = l.name;
        };
    }
    try std.testing.expectEqualStrings("amd-ryzen", found.?);
}

// Testy modułów GUI niezależnych od okna (układ formularzy, plakietka, WIC-fit).
comptime {
    _ = @import("gui/forms.zig");
    _ = @import("gui/badge.zig");
    _ = @import("gui/image.zig");
    _ = @import("gui/vendor_badge.zig");
    // Aktualizator: wersje, manifest, SHA256SUMS, podmiana z wycofaniem (bez sieci).
    _ = @import("update/update.zig");
    // Katalogi tłumaczeń: kompletność, parametry, liczba mnoga, literały poza katalogiem.
    _ = @import("i18n/catalog_test.zig");
}
