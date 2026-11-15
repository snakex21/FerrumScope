//! Probe CPU: zamiana prymitywów backendu na `RawCpuInfo`.
//!
//! Probe NIE wie, skąd pochodzą dane (platforma czy replay) i NIE interpretuje
//! numeracji — to robi `decode/`. Jego jedyną odpowiedzialnością jest ** zebrać
//! komplet surowych danych i zgłosić, czego nie udało się odczytać.
//!
//! Kolejność odczytu jest tu świadoma: leaf 0 ustala zakres, dopiero potem
//! czytamy extended, a liście z subleaf iterujemy do zera w EAX (konwencja
//! CPUID). Dzięki temu nie czytamy liści, których na danym procesorze nie ma.

const std = @import("std");
const backend = @import("../platform/backend.zig");
const status = @import("../core/status.zig");
const raw = @import("../core/raw.zig");
const ids = @import("../core/ids.zig");
const cpuid = @import("../arch/x86/cpuid.zig");

/// Poziom dostępu wymagany przez probe. Sprawdzany **przed** startem, żeby CLI
/// mogło powiedzieć „wymaga sterownika" zamiast zwracać pustkę.
pub const AccessLevel = enum { user, service, driver };

/// Deklaracja wymagań. Backend porównuje ją ze swoimi możliwościami.
pub const Requirements = struct {
    needs: backend.CapabilitySet,
    optional: backend.CapabilitySet,
    min_access: AccessLevel,
};

/// Wymagania probe'a CPU na tym etapie: CPUID wymagane, reszta opcjonalna.
pub fn requirements() Requirements {
    var needs = backend.CapabilitySet{};
    needs.add(.cpuid);
    return .{
        .needs = needs,
        .optional = .{},
        .min_access = .user,
    };
}

/// Liście podstawowe czytane w całości (bez iteracji po subleaf).
const simple_leaves = [_]u32{
    cpuid.Leaf.signature_and_features, // 0x1
    cpuid.Leaf.frequency, // 0x16
};

/// Liście iterowane po subleaf. Konwencja CPUID: subleaf 0 zwraca EAX == 0,
/// gdy danego liścia nie ma lub lista się skończyła.
const iterated_leaves = [_]u32{
    0x0, // cache type -> leaf 0x4
    0x4,
    0x7,
    0xB,
    0xD,
    0xF,
    0x10,
    0x12,
    0x14,
    0x17,
    0x18,
    0x1B,
    0x1D,
    0x1F,
    0x20,
    0x8000_0001,
    0x8000_0006,
    0x8000_0007,
    0x8000_001D,
    0x8000_001E,
};

const max_subleaves = 16;

// ---------------------------------------------------------------------------
// Skan topologii: CPUID na każdym logical procesorze
// ---------------------------------------------------------------------------

/// Liście topologii czytane **dla każdego** logical processor.
///
/// Zbiór jest celowo mały. Skan po N procesorach kosztuje N × liczba_liści
/// wywołań CPUID, a każde to realne przełączenie kontekstu i setki cykli.
/// Czytamy wyłącznie to, czego potrzebuje dekoder:
///
/// * `0x1` — legacy APIC ID (8 bitów) i sygnatura; jedyne źródło na starszych CPU,
/// * `0xB` — standardowa topologia x2APIC (SMT / Core / Die / Module),
/// * `0x1F` — topologia v2, dodaje Cluster i CoreType (hybrydowe Alder Lake+),
/// * `0x8000001E` — topologia AMD (Compute Unit, Node, Die).
///
/// Liści, których CPU nie deklaruje, **nie czytamy** — patrz `scanTopology`.
const topo_leaf_0b: u32 = 0xB;
const topo_leaf_1f: u32 = 0x1F;
/// Liść `0x1A` — Native Model ID. Dekoder używa go jako potwierdzenia,
/// że wszystkie rdzenie zgłaszają ten sam model procesora. Na CPU
/// hybrydowym nie jest to oczywiste, bo odczyt jest per-procesor.
const topo_leaf_1a: u32 = 0x1A;
const topo_leaf_amd: u32 = 0x8000_001E;

/// Liść 0xB ma najwyżej 4 poziomy; konwencja CPUID kończy listę na EAX == 0.
const topo_subleaves_0b: u32 = 4;
/// Liść 0x1F: podleaf 6 podaje liczbę poziomów. Czytamy 6 i tyle — ani mniej,
/// ani więcej, bo każdy zbędny subleaf to zbędne przełączenie procesora.
const topo_subleaves_1f: u32 = 6;

/// Skan topologii: dla każdego online logical processor odczytujemy liście
/// topologii i składamy `PerCpuImage`.
///
/// Zwraca liczbę faktycznie odczytanych procesorów — może być mniejsza od
/// zadeklarowanej, gdy przypinanie zawiodło na części CPU. Liczba online CPU
/// jest zawsze dostępna niezależnie (`out.topology.logical_from_leaf1`).
pub fn scanTopology(b: backend.Backend, out: *raw.RawCpuInfo) u32 {
    // Bez możliwości CPUID per-CPU **nie zgadujemy**: `per_cpu` zostaje pusty,
    // dekoder widzi brak danych i schodzi do fallbacku. Wypełnianie topologii
    // wartością z bazy przy udawaniu, że to pomiar, byłoby kłamstwem.
    if (!b.hasPinnedCpuid()) return 0;

    // Zakres liści ustalamy **raz** na bieżącym CPU. `max_basic`/`max_extended`
    // są stałe dla całego procesora, więc pytanie o nie osobno dla każdego CPU
    // tylko mnożyłoby koszt.
    var max_basic: u32 = 0;
    var max_extended: u32 = 0;
    if (b.readCpuid(0, 0).getStatus() == .ok) max_basic = b.readCpuid(0, 0).unwrap().?.eax;
    if (b.readCpuid(0x8000_0000, 0).getStatus() == .ok) max_extended = b.readCpuid(0x8000_0000, 0).unwrap().?.eax;

    const want_0b = max_basic >= topo_leaf_0b;
    const want_1f = max_basic >= topo_leaf_1f;
    const want_1a = max_basic >= topo_leaf_1a;
    const want_amd = max_extended >= topo_leaf_amd;

    // Liczba CPU: enumeracja platformy jest dokładniejsza niż leaf 1 (pod
    // hiperwizorem leaf 1 bywa zawyżony), więc wolimy ją, gdy jest dostępna.
    var count: u32 = 0;
    if (b.caps.has(.logical_cpu_enumeration)) {
        const n = b.logicalCpuCount();
        if (n.getStatus() == .ok) count = n.unwrap().?;
    }
    if (count == 0) {
        // Bez enumeracji bierzemy liczbę z liścia 1. Gdyby hypervisor zawyżył tę
        // wartość, przypinanie na nieistniejący CPU zwróci błąd i trafi do
        // diagnostyki — lepsze niż ciche odcięcie albo fałszywa liczba rdzeni.
        const leaf1 = b.readCpuid(0x1, 0);
        if (leaf1.getStatus() == .ok) count = (leaf1.unwrap().?.ebx >> 16) & 0xFF;
    }
    // Limit to jawna granica `PerCpuImage`; poza nią przerywamy, bo lepszy jest
    // brak topologii niż jej obcięta, pozornie pełna wersja.
    if (count == 0 or count > raw.PerCpuImage.capacity) return 0;

    var scanned: u32 = 0;
    var cpu_id: u16 = 0;
    while (cpu_id < count) : (cpu_id += 1) {
        var item: raw.LogicalCpu = .{ .id = cpu_id, .id_valid = true };
        item.image.max_basic = max_basic;
        item.image.max_extended = max_extended;

        // Leaf 1: legacy APIC ID i sygnatura. Bez niego nie odróżnimy rdzeni,
        // gdy CPU nie ma ani 0xB, ani 0x1F.
        const l1 = b.readCpuidOn(cpu_id, 0x1, 0);
        if (l1.getStatus() == .ok) {
            const r1 = l1.unwrap().?;
            item.image.add(0x1, 0, r1);
            item.legacy_apic = @truncate(r1.edx >> 24);
            item.legacy_apic_known = true;
        }

        if (want_0b) {
            var sub: u32 = 0;
            while (sub < topo_subleaves_0b) : (sub += 1) {
                const rr = b.readCpuidOn(cpu_id, topo_leaf_0b, sub);
                if (rr.getStatus() != .ok) break;
                const r = rr.unwrap().?;
                item.image.add(topo_leaf_0b, sub, r);
                if (sub == 0 and r.eax == 0) break; // koniec listy poziomów
            }
        }
        if (want_1f) {
            var sub: u32 = 0;
            while (sub < topo_subleaves_1f) : (sub += 1) {
                const rr = b.readCpuidOn(cpu_id, topo_leaf_1f, sub);
                if (rr.getStatus() != .ok) break;
                const r = rr.unwrap().?;
                item.image.add(topo_leaf_1f, sub, r);
                if (sub == 0 and r.eax == 0) break;
            }
        }
        if (want_1a) {
            const rr = b.readCpuidOn(cpu_id, topo_leaf_1a, 0);
            if (rr.getStatus() == .ok) item.image.add(topo_leaf_1a, 0, rr.unwrap().?);
        }
        if (want_amd) {
            const rr = b.readCpuidOn(cpu_id, topo_leaf_amd, 0);
            if (rr.getStatus() == .ok) item.image.add(topo_leaf_amd, 0, rr.unwrap().?);
        }

        // CPU uznajemy za odczytany, gdy odpowiedział choćby na leaf 1. Inaczej
        // przypięcie zawiodło i ten wpis nie ma prawa wpływać na topologię.
        if (item.legacy_apic_known or item.image.len > 0) {
            item.scanned = true;
            scanned += 1;
            out.per_cpu.add(item);
        } else {
            out.diagnostics.add(
                "topologia: CPU {d} nie odpowiedzial na CPUID (blad affinity)",
                .{cpu_id},
            );
        }
    }
    out.scanned_cpus = scanned;
    return scanned;
}

pub fn run(b: backend.Backend) status.Result(raw.RawCpuInfo) {
    if (!b.hasCpuid()) {
        return .{ .err = status.Failure.init(.unsupported, "backend nie udostepnia CPUID") };
    }

    var out = raw.RawCpuInfo{};
    out.cpuid_available = true;
    out.arch = switch (@import("builtin").cpu.arch) {
        .x86 => .x86,
        .x86_64 => .x86_64,
        .aarch64, .arm => .arm64,
        .riscv64 => .riscv64,
        else => .other,
    };

    // --- leaf 0: producent i maksymalny liść podstawowy ---------------------
    // `Result` to unia, nie optional — `orelse` nie pasuje.
    const l0 = switch (b.readCpuid(cpuid.Leaf.vendor_info, 0)) {
        .ok => |v| v,
        .err => |e| return .{ .err = status.Failure.init(e.status, e.detail) },
    };
    out.cpuid.add(cpuid.Leaf.vendor_info, 0, l0);
    out.cpuid.max_basic = l0.eax;
    out.vendor = ids.CpuVendor.fromLeaf0(l0.ebx, l0.edx, l0.ecx);

    // --- leaf 0x80000000: zakres extended -----------------------------------
    // Czytamy go zawsze, ale ufamy tylko, gdy zwróci sensowną wartość.
    if (b.readCpuid(cpuid.Leaf.ext_function_info, 0).orNull()) |le| {
        out.cpuid.add(cpuid.Leaf.ext_function_info, 0, le);
        if (le.eax >= cpuid.Leaf.ext_function_info) out.cpuid.max_extended = le.eax;
    }

    // --- liście proste ------------------------------------------------------
    for (simple_leaves) |leaf| {
        if (leaf > out.cpuid.max_basic) continue;
        if (b.readCpuid(leaf, 0).orNull()) |r| out.cpuid.add(leaf, 0, r);
    }

    // --- liście iterowane po subleaf ----------------------------------------
    var i: usize = 0;
    while (i < iterated_leaves.len) : (i += 1) {
        const leaf = iterated_leaves[i];
        const extended = leaf >= 0x8000_0000;
        if (extended) {
            if (out.cpuid.max_extended == 0 or leaf > out.cpuid.max_extended) continue;
        } else {
            if (leaf == 0 or leaf > out.cpuid.max_basic) continue;
        }
        var sub: u32 = 0;
        while (sub < max_subleaves) : (sub += 1) {
            const r = b.readCpuid(leaf, sub).orNull() orelse break;
            out.cpuid.add(leaf, sub, r);
            if (sub == 0 and r.eax == 0) break; // liść nie istnieje / lista pusta
        }
    }

    // --- brand string --------------------------------------------------------
    // --- brand string --------------------------------------------------------
    // Liście 0x80000002..4 trzeba czytać jawnie: `brandString()` tylko
    // skleja to, co jest w obrazie, a samo niczego nie odczytuje.
    var brand_leaf: u32 = cpuid.Leaf.ext_brand_1;
    while (brand_leaf <= cpuid.Leaf.ext_brand_3) : (brand_leaf += 1) {
        if (b.readCpuid(brand_leaf, 0).orNull()) |r| out.cpuid.add(brand_leaf, 0, r);
    }
    out.brand = cpuid.brandString(&out.cpuid);
    out.computeBrandValidity();

    // --- normalizacja surowych pól -----------------------------------------
    if (out.cpuid.getBounded(cpuid.Leaf.signature_and_features, 0)) |l1| {
        out.signature = ids.Signature.fromEax(l1.eax);
    } else {
        out.diagnostics.add("brak CPUID leaf 1 — numeracja niedostępna", .{});
    }
    out.caches = cpuid.caches(&out.cpuid);
    out.features = cpuid.features(&out.cpuid);
    out.topology = cpuid.topology(&out.cpuid);

    if (!out.brand_valid and out.brandSlice().len > 0) {
        out.diagnostics.add("brand string odrzucony jako niewiarygodny", .{});
    }
    if (out.cpuid.dropped > 0) {
        out.diagnostics.add("przepelnienie obrazu CPUID: pominieto {d} wpisow", .{out.cpuid.dropped});
    }
    if (out.topology.logical_from_leaf1 != 0 and out.topology.leaf_b_valid and
        out.topology.logical_from_leaf_b != out.topology.logical_from_leaf1)
    {
        out.diagnostics.add("CPUID leaf 1 ({d}) i leaf 0x0B ({d}) roznia sie liczba rdzeni", .{
            out.topology.logical_from_leaf1, out.topology.logical_from_leaf_b,
        });
    }

    // --- skan topologii na wszystkich logical CPU ---------------------------
    // Robimy to PRZED dekodowaniem `topology`, bo wynik zależy od tego, czy
    // backend umiał przypiąć wątek. Gdy nie umiał, `per_cpu` jest puste
    // i dekorator zejdzie do fallbacku — jawnie, nie po cichu.
    if (b.hasPinnedCpuid()) {
        const scanned = scanTopology(b, &out);
        if (scanned == 0) {
            out.diagnostics.add(
                "topologia: backend deklaruje CPUID per-CPU, ale nie udalo sie odczytac zadnego procesora",
                .{},
            );
        }
    }

    return .{ .ok = out };
}

const testing = std.testing;

test "probe: brak CPUID daje unsupported, nie panikę" {
    const empty = backend.Backend{ .name = "pusty" };
    const r = run(empty);
    try testing.expectEqual(status.Status.unsupported, r.getStatus());
    try testing.expect(r.unwrap() == null);
}

test "probe: replay daje ten sam surowy obraz co platforma" {
    var img = raw.CpuidImage{};
    img.max_basic = 0x16;
    img.max_extended = 0x8000_0008;
    img.add(0, 0, .{ .eax = 0x16, .ebx = 0x756E6547, .ecx = 0x6C65746E, .edx = 0x49656E69 });
    img.add(0x8000_0000, 0, .{ .eax = 0x8000_0008 });
    img.add(1, 0, .{ .eax = 0x000B0671, .ebx = 0x00100800, .ecx = 0x7FFAFBFF, .edx = 0x178BFBFF });
    img.add(4, 0, .{ .eax = (1 << 5) | 1, .ebx = (7 << 22) | 63, .ecx = 63, .edx = 0 });
    img.add(0x8000_0002, 0, .{ .eax = 0, .ebx = 0, .ecx = 0x6C65746E, .edx = 0x49656E69 });
    img.add(0x8000_0003, 0, .{ .eax = 0, .ebx = 0, .ecx = 0, .edx = 0 });
    img.add(0x8000_0004, 0, .{ .eax = 0, .ebx = 0, .ecx = 0, .edx = 0 });

    var rp = @import("../platform/replay.zig").Replay.init(img);
    const got = run(rp.create()).unwrap().?;

    try testing.expectEqual(ids.CpuVendor.intel, got.vendor);
    try testing.expectEqual(@as(u32, 0x16), got.cpuid.max_basic);
    try testing.expectEqual(@as(u32, 0x8000_0008), got.cpuid.max_extended);
    // EAX 0x000B0671: family_field=6, ext_model=0xB, model_field=0x7
    // -> model 0xB7 zgodnie z regułą SDM dla rodziny 6.
    try testing.expectEqual(@as(u8, 0xB7), got.signature.displayModel());
    try testing.expectEqual(@as(u8, 6), got.signature.displayFamily());
    // Ta sama sygnatura co z poprzedniego testu, ale leaf 7 nie jest dodany,
    // więc AVX-512/BMI nie mogą być wykryte. Dekoder nie ma prawa zmyślić flag
    // z liścia, którego nie odczytano.
    try testing.expect(got.features.sse2 and got.features.sse3);
    try testing.expect(!got.features.avx2 and !got.features.avx512f);
    try testing.expectEqual(@as(usize, 1), got.caches.len);
}

test "probe: liście spoza zakresu nie są czytane" {
    // Obraz deklaruje max_basic = 1, a my dokładamy leaf 4 — probe ma
    // pominąć go, bo na tym procesorze nie istnieje.
    var img = raw.CpuidImage{};
    img.max_basic = 1;
    img.add(0, 0, .{ .eax = 1, .ebx = 0x68747541, .ecx = 0x444D4163, .edx = 0x69746E65 });
    img.add(1, 0, .{ .eax = 0x00800F12, .ebx = 0x00100800 });
    img.add(4, 0, .{ .eax = 1 }); // poza zakresem — nie powinno zostać przeczytane ponownie

    var rp = @import("../platform/replay.zig").Replay.init(img);
    const got = run(rp.create()).unwrap().?;
    // Jeśli probe czytałby leaf 4 ponownie, obraz by miał wpis 4,1 lub więcej.
    try testing.expect(got.cpuid.get(4, 0) == null);
    try testing.expectEqual(ids.CpuVendor.amd, got.vendor);
    try testing.expectEqual(@as(u8, 0x17), got.signature.displayFamily());
}

test "probe: nieznany producent nie blokuje odczytu" {
    var img = raw.CpuidImage{};
    img.max_basic = 1;
    img.add(0, 0, .{ .eax = 1, .ebx = 0x12345678, .ecx = 0x12345678, .edx = 0x12345678 });
    img.add(1, 0, .{ .eax = 0x000506E3, .ebx = 0x00100800 });
    var rp = @import("../platform/replay.zig").Replay.init(img);
    const got = run(rp.create()).unwrap().?;
    try testing.expectEqual(ids.CpuVendor.unknown, got.vendor);
    try testing.expectEqual(@as(u8, 0x5E), got.signature.displayModel());
}
