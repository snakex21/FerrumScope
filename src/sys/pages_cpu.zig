//! Strona „CPU” — identyfikacja (CPUID + HWDB), zegary i obciążenie bez
//! sterownika, topologia, cache w stylu „8 x 32 KB”, pełna lista instrukcji.
//!
//! Wejście jest już zdekodowane (`CpuInfo`) i zmierzone (`LiveCpu`); tu tylko
//! układamy pola z podaniem źródła i pewności. Ta sama funkcja zasila GUI,
//! CLI i eksport.

const std = @import("std");
const raw = @import("../core/raw.zig");
const model = @import("../core/model.zig");
const decoder = @import("../decode/cpu_x86.zig");
const isa = @import("../decode/isa_x86.zig");
const report = @import("report.zig");
const links = @import("links.zig");
const lookup = @import("lookup.zig");

/// Pomiary na żywo (bez sterownika). Wszystkie pola opcjonalne: replay ich nie ma.
pub const LiveCpu = struct {
    cpus: u32 = 0,
    load: []const ?f32 = &.{},
    total_load: ?f32 = null,
    base_mhz: ?u32 = null,
    reported_mhz: ?u32 = null,
    est_mhz: []const ?f32 = &.{},
    est_avg_mhz: ?f32 = null,
    est_max_mhz: ?f32 = null,
    pdh_ok: bool = false,
    /// Częstotliwość efektywna z APERF/MPERF (sterownik). `null` = brak.
    msr_effective_mhz: ?f64 = null,
    msr_reason: []const u8 = "sterownik FerrumScopeMsr nie jest załadowany",
};

pub const CpuInput = struct {
    raw: *const raw.RawCpuInfo,
    info: *const model.CpuInfo,
    outcome: decoder.DecodeOutcome,
    hwdb_entries: usize = 0,
    hwdb_revision: u32 = 0,
    /// Opis źródła danych (np. „CPUID na żywo” albo ścieżka pliku replay).
    origin: []const u8 = "CPUID na żywo",
    live: ?LiveCpu = null,
    /// Zegar zewnętrzny (magistrali) z SMBIOS typ 4, offset 12h. `null` = brak.
    bus_mhz: ?u32 = null,
    /// Tabele linków TechPowerUp (przypięte + kuratorowane).
    lookup: lookup.Tables = .{},
};

fn kb(bytes: u64) u64 {
    return (bytes + 1023) / 1024;
}

pub const Instances = struct { n: u32, derived: bool };

/// Liczba instancji cache. CPUID podaje ją wprost tylko, gdy zna liczbę wątków
/// współdzielących (Intel liść 4). Dla AMD (0x8000001D bez tej liczby) cache
/// prywatny rdzenia (L1/L2, domena `core`) ma tyle instancji, ile rdzeni —
/// to **wyprowadzenie** z topologii, oznaczane jako takie.
pub fn instances(info: *const model.CpuInfo, c: model.CacheInfo) Instances {
    if (c.instance_count > 1) return .{ .n = c.instance_count, .derived = false };
    const per_core = c.domain == .core or (c.domain == .unknown and !c.shared and c.level <= 2);
    if (per_core and info.cores_physical > 1) return .{ .n = info.cores_physical, .derived = true };
    if (c.domain == .package and info.packages > 1) return .{ .n = info.packages, .derived = true };
    return .{ .n = 1, .derived = false };
}

/// „8 x 32 KB”, „1 x 96 MB” — jak w CPU-Z. Rozmiar jest per instancja.
pub fn cacheLabel(b: *report.Builder, c: model.CacheInfo, count: u32) []const u8 {
    const n: u32 = if (count == 0) 1 else count;
    const k = kb(c.size_bytes);
    if (k >= 1024 and k % 1024 == 0) return b.fmt("{d} x {d} MB", .{ n, k / 1024 });
    return b.fmt("{d} x {d} KB", .{ n, k });
}

fn cacheName(c: model.CacheInfo) []const u8 {
    return switch (c.level) {
        1 => switch (c.kind) {
            .data => "L1 Data",
            .instruction => "L1 Instruction",
            .unified => "L1",
        },
        2 => "L2",
        3 => "L3",
        4 => "L4",
        else => "Cache",
    };
}

pub fn srcLabel(s: model.FieldSource) []const u8 {
    return switch (s) {
        .cpuid => "CPUID",
        .hwdb_exact => "HWDB (dokładny wpis)",
        .hwdb_pattern => "HWDB (zakres modeli)",
        .hwdb_family => "HWDB (cała rodzina)",
        .hwdb => "HWDB",
        .brand_derived => "brand string (reguła HWDB)",
        .generated => "wygenerowane z sygnatury",
        .smbios => "SMBIOS",
        .platform => "platforma",
        .empirical => "obserwacja referencyjna",
        .unknown, .none => "—",
    };
}

fn confOf(s: model.FieldSource) report.Confidence {
    return switch (s) {
        .cpuid => .high,
        .hwdb_exact => .high,
        .hwdb_pattern, .brand_derived => .medium,
        .hwdb_family, .hwdb, .generated, .empirical => .low,
        else => .unknown,
    };
}

fn optField(b: *report.Builder, label: []const u8, v: ?[]const u8, src: model.FieldSource, missing: []const u8) void {
    if (v) |s| {
        b.add(.{ .label = label, .value = s, .source = srcLabel(src), .confidence = confOf(src) });
    } else {
        b.add(.{ .label = label, .value = "—", .state = .unavailable, .source = missing, .confidence = .unknown });
    }
}

pub fn build(arena: std.mem.Allocator, in: CpuInput) report.Page {
    var page: report.Page = .{ .id = "cpu", .title = "CPU" };
    var b = report.Builder.init(arena, &page);
    const info = in.info;
    const raw_info = in.raw;

    var nb: [128]u8 = undefined;
    page.headline = b.dup(info.displayName(&nb));
    page.summary = b.fmt("Źródło: {s}. HWDB: {d} wpisów, rewizja {d}.", .{ in.origin, in.hwdb_entries, in.hwdb_revision });

    // --- identyfikacja -----------------------------------------------------
    b.section("Procesor");
    b.add(.{
        .label = "Nazwa",
        .value = page.headline,
        .source = srcLabel(info.display_name_source),
        .confidence = if (info.match.isReliable()) .high else .medium,
    });
    b.add(.{ .label = "Producent", .value = info.vendor.toSlice(), .source = "CPUID.0 EBX/EDX/ECX" });
    if (info.brand_valid) {
        b.add(.{ .label = "Brand string", .value = b.dup(info.brandSlice()), .source = "CPUID 0x80000002..4" });
    } else {
        b.add(.{ .label = "Brand string", .value = "—", .state = .unavailable, .source = "brak lub niewiarygodny w CPUID", .confidence = .unknown });
    }
    optField(&b, "Nazwa kodowa", info.codename, info.codename_source, "brak wpisu w HWDB");
    optField(&b, "Mikroarchitektura", info.microarchitecture, info.microarchitecture_source, "brak wpisu w HWDB");
    if (info.socket_name) |s| {
        b.add(.{ .label = "Gniazdo", .value = s, .source = srcLabel(info.socket_source), .confidence = info.socket_confidence });
    } else {
        b.add(.{ .label = "Gniazdo", .value = "—", .state = .unavailable, .source = "brak wpisu w HWDB (gniazda nie zgadujemy; patrz Płyta główna → SMBIOS)", .confidence = .unknown });
    }
    if (info.stepping_name) |s| {
        b.add(.{
            .label = "Rewizja",
            .value = s,
            .source = b.fmt("{s} ({s})", .{ srcLabel(info.stepping_name_source), info.stepping_name_provenance.source_type.toSlice() }),
            .confidence = info.stepping_name_provenance.confidence,
            .note = info.stepping_name_provenance.notes orelse "",
        });
    }
    if (info.variant) |v| b.add(.{ .label = "Wariant", .value = v, .source = srcLabel(info.variant_source), .confidence = confOf(info.variant_source) });
    b.add(.{ .label = "Technologia", .value = "—", .state = .unavailable, .confidence = .unknown, .source = "proces technologiczny: brak w HWDB (nie zgadujemy z nazwy)" });
    const sig = info.signature;
    b.add(.{ .label = "Rodzina", .value = b.fmt("{X}", .{sig.familyField()}), .raw = b.fmt("0x{X}", .{sig.familyField()}), .source = "CPUID.1 EAX[11:8]" });
    b.add(.{ .label = "Model", .value = b.fmt("{X}", .{sig.modelField()}), .raw = b.fmt("0x{X}", .{sig.modelField()}), .source = "CPUID.1 EAX[7:4]" });
    b.add(.{ .label = "Stepping", .value = b.fmt("{X}", .{info.stepping}), .source = "CPUID.1 EAX[3:0]" });
    b.add(.{ .label = "Rodzina rozsz.", .value = b.fmt("{X}", .{info.display_family}), .raw = b.fmt("ext_family=0x{X}", .{sig.extFamily()}), .source = "CPUID.1 EAX[27:20] + [11:8] (display family)" });
    b.add(.{ .label = "Model rozsz.", .value = b.fmt("{X}", .{info.display_model}), .raw = b.fmt("ext_model=0x{X}", .{sig.extModel()}), .source = "CPUID.1 EAX[19:16]:[7:4] (display model)" });
    b.add(.{
        .label = "Family / Model / Stepping",
        .value = b.fmt("{X} / {X} / {X}", .{ info.display_family, info.display_model, info.stepping }),
        .raw = b.fmt("0x{X:0>8}", .{info.signature.eax}),
        .source = "CPUID.1 EAX (display family/model wg SDM/APM)",
    });

    // --- zegary i obciążenie ------------------------------------------------
    b.section("Zegary (bez sterownika)");
    if (in.live) |lv| {
        if (lv.est_avg_mhz) |avg| {
            b.add(.{
                .label = "Zegar rdzeni (średnio)",
                .value = b.fmt("{d:.0} MHz", .{avg}),
                .state = .estimate,
                .confidence = .medium,
                .source = "PDH \\Processor Information(*)\\% Processor Performance × zegar bazowy",
                .note = "oszacowanie systemu (jak Menedżer zadań), nie odczyt APERF/MPERF",
            });
            if (lv.est_max_mhz) |mx| b.add(.{ .label = "Najszybszy rdzeń", .value = b.fmt("{d:.0} MHz", .{mx}), .state = .estimate, .confidence = .medium, .source = "jw., maksimum po procesorach logicznych" });
        } else {
            b.add(.{ .label = "Zegar rdzeni (średnio)", .value = "—", .state = .unavailable, .confidence = .unknown, .source = if (lv.pdh_ok) "licznik PDH bez danych (pierwsza próbka)" else "licznik PDH % Processor Performance niedostępny" });
        }
        if (in.bus_mhz) |bus| {
            b.add(.{ .label = "Zegar magistrali", .value = b.fmt("{d} MHz", .{bus}), .source = "SMBIOS typ 4, offset 12h (External Clock)", .confidence = .medium, .note = "wartość firmware, nie pomiar" });
            if (lv.est_avg_mhz) |avg| {
                const mul = avg / @as(f32, @floatFromInt(@max(bus, 1)));
                b.add(.{ .label = "Mnożnik", .value = b.fmt("x {d:.1}", .{mul}), .state = .estimate, .confidence = .low, .source = "zegar rdzeni (oszacowanie) / zegar magistrali (SMBIOS)" });
            } else b.add(.{ .label = "Mnożnik", .value = "—", .state = .unavailable, .confidence = .unknown, .source = "brak oszacowania zegara rdzeni" });
        } else {
            b.add(.{ .label = "Zegar magistrali", .value = "—", .state = .unavailable, .confidence = .unknown, .source = "brak SMBIOS typ 4 External Clock" });
            b.add(.{ .label = "Mnożnik", .value = "—", .state = .unavailable, .confidence = .unknown, .source = "brak zegara magistrali" });
        }
        if (lv.base_mhz) |m| b.add(.{ .label = "Zegar bazowy", .value = b.fmt("{d} MHz", .{m}), .source = "CallNtPowerInformation(ProcessorInformation).MaxMhz (ACPI)", .confidence = .medium });
        if (lv.reported_mhz) |m| b.add(.{ .label = "Zegar zgłaszany przez system", .value = b.fmt("{d} MHz", .{m}), .source = "CallNtPowerInformation(ProcessorInformation).CurrentMhz", .confidence = .low, .note = "na nowszych Windows zwykle równy bazowemu" });
        if (lv.msr_effective_mhz) |f| {
            b.add(.{ .label = "Zegar efektywny (APERF/MPERF)", .value = b.fmt("{d:.0} MHz", .{f}), .source = "MSR 0xE7/0xE8 przez FerrumScopeMsr", .confidence = .medium });
        } else {
            b.add(.{ .label = "Zegar efektywny (APERF/MPERF)", .value = "—", .state = .requires_driver, .confidence = .unknown, .source = lv.msr_reason });
        }

        b.section("Obciążenie (bez sterownika)");
        if (lv.total_load) |t| {
            b.add(.{ .label = "Całkowite", .value = b.fmt("{d:.1} %", .{t}), .source = "NtQuerySystemInformation(SystemProcessorPerformanceInformation), Δ czasów idle/kernel/user" });
        } else {
            b.add(.{ .label = "Całkowite", .value = "—", .state = .unavailable, .confidence = .unknown, .source = "potrzebne dwie próbki (odświeżenie za 1 s)" });
        }
        for (0..lv.cpus) |i| {
            const l: ?f32 = if (i < lv.load.len) lv.load[i] else null;
            const f: ?f32 = if (i < lv.est_mhz.len) lv.est_mhz[i] else null;
            const label = b.fmt("CPU {d}", .{i});
            if (l) |pct| {
                const v = if (f) |mhz| b.fmt("{d:>5.1} %   ~{d:.0} MHz", .{ pct, mhz }) else b.fmt("{d:.1} %", .{pct});
                b.add(.{ .label = label, .value = v, .state = if (f != null) .estimate else .ok, .confidence = if (f != null) .medium else .high, .source = "jw. (per procesor logiczny)" });
            } else {
                b.add(.{ .label = label, .value = "—", .state = .unavailable, .confidence = .unknown, .source = "brak drugiej próbki" });
            }
        }
    } else {
        b.add(.{ .label = "Zegary i obciążenie", .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.fmt("brak pomiaru na żywo ({s})", .{in.origin}) });
    }

    // --- topologia -----------------------------------------------------------
    b.section("Topologia");
    const topo = info.topology_source.toSlice();
    if (info.cores_physical > 0) {
        b.add(.{ .label = "Rdzenie", .value = b.fmt("{d}", .{info.cores_physical}), .source = b.fmt("topologia: {s}", .{topo}), .confidence = if (info.topology_confident) .high else .low });
    } else b.add(.{ .label = "Rdzenie", .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.fmt("topologia nieustalona ({s})", .{topo}) });
    if (info.threads_logical > 0) {
        b.add(.{ .label = "Wątki", .value = b.fmt("{d}", .{info.threads_logical}), .source = b.fmt("topologia: {s}", .{topo}) });
    } else b.add(.{ .label = "Wątki", .value = "—", .state = .unavailable, .confidence = .unknown, .source = topo });
    b.add(.{ .label = "SMT", .value = if (info.smt) "tak" else "nie", .source = "CPUID" });
    if (info.packages > 0) b.add(.{ .label = "Gniazda (pakiety)", .value = b.fmt("{d}", .{info.packages}), .source = "identyfikatory APIC (pomiar)" });
    const classes = info.coreClassSlice();
    if (info.hybrid or classes.len > 1) {
        for (classes) |c| {
            const v = if (c.name.len > 0) b.fmt("{d} x {s}", .{ c.cores, c.name }) else b.fmt("{d} x klasa 0x{X:0>2}", .{ c.cores, c.value });
            b.add(.{ .label = "Klasa rdzeni", .value = v, .source = "CPUID 0x1A / 0x1F" });
        }
    }

    // --- cache ---------------------------------------------------------------
    b.section("Pamięć podręczna");
    if (info.cacheSlice().len == 0) {
        b.add(.{ .label = "Cache", .value = "—", .state = .unavailable, .confidence = .unknown, .source = "brak liści cache w CPUID" });
    }
    for (info.cacheSlice()) |c| {
        const inst = instances(info, c);
        b.add(.{
            .label = cacheName(c),
            .value = cacheLabel(&b, c, inst.n),
            .confidence = if (inst.derived) .medium else .high,
            .note = if (inst.derived) "liczba instancji wyprowadzona z topologii (cache prywatny rdzenia × liczba rdzeni)" else "",
            .raw = b.fmt("{d} B/instancję", .{c.size_bytes}),
            .source = "CPUID (liść cache: 4 / 0x8000001D)",
        });
        b.add(.{
            .label = b.fmt("{s} — opis", .{cacheName(c)}),
            .value = if (c.associativity > 0) b.fmt("{d}-way, linia {d} B, {d} zestawów", .{ c.associativity, c.line_size, c.sets }) else b.fmt("linia {d} B, {d} zestawów", .{ c.line_size, c.sets }),
            .source = "CPUID (liść cache: 4 / 0x8000001D)",
        });
    }

    // --- instrukcje -------------------------------------------------------------
    b.section("Zestaw instrukcji");
    const r = isa.decode(&raw_info.cpuid);
    var buf: [1024]u8 = undefined;
    b.add(.{ .label = "Instrukcje", .value = b.dup(isa.joinPresent(&r, &buf, null)), .raw = b.fmt("{d} rozszerzeń", .{r.count}), .source = "CPUID 1, 7.0, 7.1, 0x80000001 (Intel SDM 2A, AMD APM 3)" });
    b.add(.{ .label = "Poziom x86-64", .value = r.level.label(), .source = "wyprowadzone z bitów CPUID wg x86-64 psABI §3.1.1", .confidence = .high });
    const virt = if (r.has("VT-x")) "VT-x" else if (r.has("AMD-V")) "AMD-V" else "nie zgłoszona";
    b.add(.{
        .label = "Wirtualizacja",
        .value = virt,
        .source = "CPUID.1 ECX[5] (VMX) / 0x80000001 ECX[2] (SVM)",
        .confidence = if (r.hypervisor) .medium else .high,
        .note = if (r.hypervisor) "działamy pod hypervisorem (CPUID.1 ECX[31]) — bit wirtualizacji może być ukryty przez Hyper-V/VBS" else "",
    });
    inline for (.{ isa.Group.simd, isa.Group.avx512, isa.Group.crypto, isa.Group.security }) |g| {
        const s = isa.joinPresent(&r, &buf, g);
        if (s.len > 0) b.add(.{ .label = g.label(), .value = b.dup(s), .source = "CPUID" });
    }

    // --- pochodzenie -------------------------------------------------------------
    b.section("Pochodzenie danych");
    b.add(.{ .label = "Dopasowanie HWDB", .value = info.match.toSlice(), .source = b.fmt("decode={s}", .{in.outcome.toSlice()}) });
    b.add(.{ .label = "Źródło wpisu", .value = info.db_source orelse "—", .source = info.db_source_url orelse "", .state = if (info.db_source == null) .unavailable else .ok });
    for (0..raw_info.diagnostics.len) |i| {
        b.add(.{ .label = "Diagnostyka", .value = b.dup(raw_info.diagnostics.get(i)), .source = "probe" });
    }

    var mb: [128]u8 = undefined;
    const lk_model = lookup.normalizeCpu(&mb, if (info.brand_valid) info.brandSlice() else page.headline);
    links.cpu(&b, info.vendor, page.headline, lookup.resolve(in.lookup, .cpu, lk_model, ""));
    return page;
}
