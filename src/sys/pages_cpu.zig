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
const i18n = @import("../i18n/i18n.zig");

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
    /// Powód braku odczytu MSR. Pusty = domyślny („sterownik … nie jest
    /// załadowany”), tłumaczony przy budowie strony.
    msr_reason: []const u8 = "",
};

pub const CpuInput = struct {
    raw: *const raw.RawCpuInfo,
    info: *const model.CpuInfo,
    outcome: decoder.DecodeOutcome,
    hwdb_entries: usize = 0,
    hwdb_revision: u32 = 0,
    /// Opis źródła danych (ścieżka pliku replay). Pusty = „CPUID na żywo”
    /// (tłumaczone przy budowie strony).
    origin: []const u8 = "",
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

/// Nazwa poziomu cache (etykieta pola; GUI wiąże po `i18n.t("L1 Data")` itd.).
fn cacheName(c: model.CacheInfo) []const u8 {
    return switch (c.level) {
        1 => switch (c.kind) {
            .data => i18n.t("L1 Data"),
            .instruction => i18n.t("L1 Instruction"),
            .unified => i18n.t("L1"),
        },
        2 => i18n.t("L2"),
        3 => i18n.t("L3"),
        4 => i18n.t("L4"),
        else => i18n.t("Cache"),
    };
}

/// Etykieta opisu cache. Pełne identyfikatory (nie szablon), bo formularz GUI
/// wiąże komórki przez `i18n.t("L1 Data — opis")` — tłumaczenie etykiety
/// strony musi być identyczne w każdym języku.
fn cacheDescName(c: model.CacheInfo) []const u8 {
    return switch (c.level) {
        1 => switch (c.kind) {
            .data => i18n.t("L1 Data — opis"),
            .instruction => i18n.t("L1 Instruction — opis"),
            .unified => i18n.t("L1 — opis"),
        },
        2 => i18n.t("L2 — opis"),
        3 => i18n.t("L3 — opis"),
        4 => i18n.t("L4 — opis"),
        else => i18n.t("Cache — opis"),
    };
}

pub fn srcLabel(s: model.FieldSource) []const u8 {
    return switch (s) {
        .cpuid => "CPUID",
        .hwdb_exact => i18n.t("HWDB (dokładny wpis)"),
        .hwdb_pattern => i18n.t("HWDB (zakres modeli)"),
        .hwdb_family => i18n.t("HWDB (cała rodzina)"),
        .hwdb => "HWDB",
        .brand_derived => i18n.t("brand string (reguła HWDB)"),
        .generated => i18n.t("wygenerowane z sygnatury"),
        .smbios => "SMBIOS",
        .platform => i18n.t("platforma"),
        .empirical => i18n.t("obserwacja referencyjna"),
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
    var page: report.Page = .{ .id = "cpu", .title = "" };
    var b = report.Builder.init(arena, &page);
    page.title = b.t("CPU");
    const origin = if (in.origin.len > 0) in.origin else b.t("CPUID na żywo");
    const info = in.info;
    const raw_info = in.raw;

    var nb: [128]u8 = undefined;
    page.headline = b.dup(info.displayName(&nb));
    page.summary = b.tp("Źródło: {origin}. HWDB: {n} wpisów, rewizja {revision}.", in.hwdb_entries, .{ .origin = origin, .revision = in.hwdb_revision });

    // --- identyfikacja -----------------------------------------------------
    b.section(b.t("Procesor"));
    b.add(.{
        .label = b.t("Nazwa"),
        .value = page.headline,
        .source = srcLabel(info.display_name_source),
        .confidence = if (info.match.isReliable()) .high else .medium,
    });
    b.add(.{ .label = b.t("Producent"), .value = info.vendor.toSlice(), .source = "CPUID.0 EBX/EDX/ECX" });
    if (info.brand_valid) {
        b.add(.{ .label = b.t("Brand string"), .value = b.dup(info.brandSlice()), .source = "CPUID 0x80000002..4" });
    } else {
        b.add(.{ .label = b.t("Brand string"), .value = "—", .state = .unavailable, .source = b.t("brak lub niewiarygodny w CPUID"), .confidence = .unknown });
    }
    optField(&b, b.t("Nazwa kodowa"), info.codename, info.codename_source, b.t("brak wpisu w HWDB"));
    optField(&b, b.t("Mikroarchitektura"), info.microarchitecture, info.microarchitecture_source, b.t("brak wpisu w HWDB"));
    if (info.socket_name) |s| {
        b.add(.{ .label = b.t("Gniazdo"), .value = s, .source = srcLabel(info.socket_source), .confidence = info.socket_confidence });
    } else {
        b.add(.{ .label = b.t("Gniazdo"), .value = "—", .state = .unavailable, .source = b.t("brak wpisu w HWDB (gniazda nie zgadujemy; patrz Płyta główna → SMBIOS)"), .confidence = .unknown });
    }
    if (info.stepping_name) |s| {
        b.add(.{
            .label = b.t("Rewizja"),
            .value = s,
            .source = b.fmt("{s} ({s})", .{ srcLabel(info.stepping_name_source), info.stepping_name_provenance.source_type.toSlice() }),
            .confidence = info.stepping_name_provenance.confidence,
            .note = info.stepping_name_provenance.notes orelse "",
        });
    }
    if (info.variant) |v| b.add(.{ .label = b.t("Wariant"), .value = v, .source = srcLabel(info.variant_source), .confidence = confOf(info.variant_source) });
    b.add(.{ .label = b.t("Technologia"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.t("proces technologiczny: brak w HWDB (nie zgadujemy z nazwy)") });
    const sig = info.signature;
    b.add(.{ .label = b.t("Rodzina"), .value = b.fmt("{X}", .{sig.familyField()}), .raw = b.fmt("0x{X}", .{sig.familyField()}), .source = "CPUID.1 EAX[11:8]" });
    b.add(.{ .label = b.t("Model"), .value = b.fmt("{X}", .{sig.modelField()}), .raw = b.fmt("0x{X}", .{sig.modelField()}), .source = "CPUID.1 EAX[7:4]" });
    b.add(.{ .label = b.t("Stepping"), .value = b.fmt("{X}", .{info.stepping}), .source = "CPUID.1 EAX[3:0]" });
    b.add(.{ .label = b.t("Rodzina rozsz."), .value = b.fmt("{X}", .{info.display_family}), .raw = b.fmt("ext_family=0x{X}", .{sig.extFamily()}), .source = "CPUID.1 EAX[27:20] + [11:8] (display family)" });
    b.add(.{ .label = b.t("Model rozsz."), .value = b.fmt("{X}", .{info.display_model}), .raw = b.fmt("ext_model=0x{X}", .{sig.extModel()}), .source = "CPUID.1 EAX[19:16]:[7:4] (display model)" });
    b.add(.{
        .label = b.t("Family / Model / Stepping"),
        .value = b.fmt("{X} / {X} / {X}", .{ info.display_family, info.display_model, info.stepping }),
        .raw = b.fmt("0x{X:0>8}", .{info.signature.eax}),
        .source = b.t("CPUID.1 EAX (display family/model wg SDM/APM)"),
    });

    // --- zegary i obciążenie ------------------------------------------------
    b.section(b.t("Zegary (bez sterownika)"));
    if (in.live) |lv| {
        if (lv.est_avg_mhz) |avg| {
            b.add(.{
                .label = b.t("Zegar rdzeni (średnio)"),
                .value = b.fmt("{d:.0} MHz", .{avg}),
                .state = .estimate,
                .confidence = .medium,
                .source = b.t("PDH \\Processor Information(*)\\% Processor Performance × zegar bazowy"),
                .note = b.t("oszacowanie systemu (jak Menedżer zadań), nie odczyt APERF/MPERF"),
            });
            if (lv.est_max_mhz) |mx| b.add(.{ .label = b.t("Najszybszy rdzeń"), .value = b.fmt("{d:.0} MHz", .{mx}), .state = .estimate, .confidence = .medium, .source = b.t("jw., maksimum po procesorach logicznych") });
        } else {
            b.add(.{ .label = b.t("Zegar rdzeni (średnio)"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = if (lv.pdh_ok) b.t("licznik PDH bez danych (pierwsza próbka)") else b.t("licznik PDH % Processor Performance niedostępny") });
        }
        if (in.bus_mhz) |bus| {
            b.add(.{ .label = b.t("Zegar magistrali"), .value = b.fmt("{d} MHz", .{bus}), .source = "SMBIOS typ 4, offset 12h (External Clock)", .confidence = .medium, .note = b.t("wartość firmware, nie pomiar") });
            if (lv.est_avg_mhz) |avg| {
                const mul = avg / @as(f32, @floatFromInt(@max(bus, 1)));
                b.add(.{ .label = b.t("Mnożnik"), .value = b.fmt("x {d:.1}", .{mul}), .state = .estimate, .confidence = .low, .source = b.t("zegar rdzeni (oszacowanie) / zegar magistrali (SMBIOS)") });
            } else b.add(.{ .label = b.t("Mnożnik"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.t("brak oszacowania zegara rdzeni") });
        } else {
            b.add(.{ .label = b.t("Zegar magistrali"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.t("brak SMBIOS typ 4 External Clock") });
            b.add(.{ .label = b.t("Mnożnik"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.t("brak zegara magistrali") });
        }
        if (lv.base_mhz) |m| b.add(.{ .label = b.t("Zegar bazowy"), .value = b.fmt("{d} MHz", .{m}), .source = "CallNtPowerInformation(ProcessorInformation).MaxMhz (ACPI)", .confidence = .medium });
        if (lv.reported_mhz) |m| b.add(.{ .label = b.t("Zegar zgłaszany przez system"), .value = b.fmt("{d} MHz", .{m}), .source = "CallNtPowerInformation(ProcessorInformation).CurrentMhz", .confidence = .low, .note = b.t("na nowszych Windows zwykle równy bazowemu") });
        if (lv.msr_effective_mhz) |f| {
            b.add(.{ .label = b.t("Zegar efektywny (APERF/MPERF)"), .value = b.fmt("{d:.0} MHz", .{f}), .source = b.t("MSR 0xE7/0xE8 przez FerrumScopeMsr"), .confidence = .medium });
        } else {
            b.add(.{ .label = b.t("Zegar efektywny (APERF/MPERF)"), .value = "—", .state = .requires_driver, .confidence = .unknown, .source = if (lv.msr_reason.len > 0) lv.msr_reason else b.t("sterownik FerrumScopeMsr nie jest załadowany") });
        }

        b.section(b.t("Obciążenie (bez sterownika)"));
        if (lv.total_load) |t| {
            b.add(.{ .label = b.t("Całkowite"), .value = b.fmt("{d:.1} %", .{t}), .source = b.t("NtQuerySystemInformation(SystemProcessorPerformanceInformation), Δ czasów idle/kernel/user") });
        } else {
            b.add(.{ .label = b.t("Całkowite"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.t("potrzebne dwie próbki (odświeżenie za 1 s)") });
        }
        for (0..lv.cpus) |i| {
            const l: ?f32 = if (i < lv.load.len) lv.load[i] else null;
            const f: ?f32 = if (i < lv.est_mhz.len) lv.est_mhz[i] else null;
            const label = b.tf("CPU {index}", .{ .index = i });
            if (l) |pct| {
                const v = if (f) |mhz| b.fmt("{d:>5.1} %   ~{d:.0} MHz", .{ pct, mhz }) else b.fmt("{d:.1} %", .{pct});
                b.add(.{ .label = label, .value = v, .state = if (f != null) .estimate else .ok, .confidence = if (f != null) .medium else .high, .source = b.t("jw. (per procesor logiczny)") });
            } else {
                b.add(.{ .label = label, .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.t("brak drugiej próbki") });
            }
        }
    } else {
        b.add(.{ .label = b.t("Zegary i obciążenie"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.tf("brak pomiaru na żywo ({origin})", .{ .origin = origin }) });
    }

    // --- topologia -----------------------------------------------------------
    b.section(b.t("Topologia"));
    const topo = info.topology_source.toSlice();
    if (info.cores_physical > 0) {
        b.add(.{ .label = b.t("Rdzenie"), .value = b.fmt("{d}", .{info.cores_physical}), .source = b.tf("topologia: {source}", .{ .source = topo }), .confidence = if (info.topology_confident) .high else .low });
    } else b.add(.{ .label = b.t("Rdzenie"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.tf("topologia nieustalona ({source})", .{ .source = topo }) });
    if (info.threads_logical > 0) {
        b.add(.{ .label = b.t("Wątki"), .value = b.fmt("{d}", .{info.threads_logical}), .source = b.tf("topologia: {source}", .{ .source = topo }) });
    } else b.add(.{ .label = b.t("Wątki"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = topo });
    b.add(.{ .label = b.t("SMT"), .value = if (info.smt) b.t("tak") else b.t("nie"), .source = "CPUID" });
    if (info.packages > 0) b.add(.{ .label = b.t("Gniazda (pakiety)"), .value = b.fmt("{d}", .{info.packages}), .source = b.t("identyfikatory APIC (pomiar)") });
    const classes = info.coreClassSlice();
    if (info.hybrid or classes.len > 1) {
        for (classes) |c| {
            const v = if (c.name.len > 0) b.fmt("{d} x {s}", .{ c.cores, c.name }) else b.tf("{cores} x klasa {class}", .{ .cores = c.cores, .class = b.fmt("0x{X:0>2}", .{c.value}) });
            b.add(.{ .label = b.t("Klasa rdzeni"), .value = v, .source = "CPUID 0x1A / 0x1F" });
        }
    }

    // --- cache ---------------------------------------------------------------
    b.section(b.t("Pamięć podręczna"));
    if (info.cacheSlice().len == 0) {
        b.add(.{ .label = b.t("Cache"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.t("brak liści cache w CPUID") });
    }
    for (info.cacheSlice()) |c| {
        const inst = instances(info, c);
        b.add(.{
            .label = cacheName(c),
            .value = cacheLabel(&b, c, inst.n),
            .confidence = if (inst.derived) .medium else .high,
            .note = if (inst.derived) b.t("liczba instancji wyprowadzona z topologii (cache prywatny rdzenia × liczba rdzeni)") else "",
            .raw = b.tf("{bytes} B/instancję", .{ .bytes = c.size_bytes }),
            .source = b.t("CPUID (liść cache: 4 / 0x8000001D)"),
        });
        b.add(.{
            .label = cacheDescName(c),
            .value = if (c.associativity > 0) b.tp("{ways}-way, linia {line} B, {n} zestawów", c.sets, .{ .ways = c.associativity, .line = c.line_size }) else b.tp("linia {line} B, {n} zestawów", c.sets, .{ .line = c.line_size }),
            .source = b.t("CPUID (liść cache: 4 / 0x8000001D)"),
        });
    }

    // --- instrukcje -------------------------------------------------------------
    b.section(b.t("Zestaw instrukcji"));
    const r = isa.decode(&raw_info.cpuid);
    var buf: [1024]u8 = undefined;
    b.add(.{ .label = b.t("Instrukcje"), .value = b.dup(isa.joinPresent(&r, &buf, null)), .raw = b.tp("{n} rozszerzeń", r.count, .{}), .source = "CPUID 1, 7.0, 7.1, 0x80000001 (Intel SDM 2A, AMD APM 3)" });
    b.add(.{ .label = b.t("Poziom x86-64"), .value = r.level.label(), .source = b.t("wyprowadzone z bitów CPUID wg x86-64 psABI §3.1.1"), .confidence = .high });
    const virt = if (r.has("VT-x")) "VT-x" else if (r.has("AMD-V")) "AMD-V" else b.t("nie zgłoszona");
    b.add(.{
        .label = b.t("Wirtualizacja"),
        .value = virt,
        .source = "CPUID.1 ECX[5] (VMX) / 0x80000001 ECX[2] (SVM)",
        .confidence = if (r.hypervisor) .medium else .high,
        .note = if (r.hypervisor) b.t("działamy pod hypervisorem (CPUID.1 ECX[31]) — bit wirtualizacji może być ukryty przez Hyper-V/VBS") else "",
    });
    inline for (.{ isa.Group.simd, isa.Group.avx512, isa.Group.crypto, isa.Group.security }) |g| {
        const s = isa.joinPresent(&r, &buf, g);
        if (s.len > 0) b.add(.{ .label = g.label(), .value = b.dup(s), .source = "CPUID" });
    }

    // --- pochodzenie -------------------------------------------------------------
    b.section(b.t("Pochodzenie danych"));
    b.add(.{ .label = b.t("Dopasowanie HWDB"), .value = info.match.toSlice(), .source = b.fmt("decode={s}", .{in.outcome.toSlice()}) });
    b.add(.{ .label = b.t("Źródło wpisu"), .value = info.db_source orelse "—", .source = info.db_source_url orelse "", .state = if (info.db_source == null) .unavailable else .ok });
    for (0..raw_info.diagnostics.len) |i| {
        b.add(.{ .label = b.t("Diagnostyka"), .value = b.dup(raw_info.diagnostics.get(i)), .source = "probe" });
    }

    var mb: [128]u8 = undefined;
    const lk_model = lookup.normalizeCpu(&mb, if (info.brand_valid) info.brandSlice() else page.headline);
    links.cpu(&b, info.vendor, page.headline, lookup.resolve(in.lookup, .cpu, lk_model, ""));
    return page;
}
