//! Dekoder CPUID: surowe rejestry -> struktury `core.raw`.
//!
//! Ten plik NIE wie, skąd pochodzą dane. Przyjmuje `CpuidImage`, który dla
//! platformy żywej zbudował probe z wywołań CPUID, a dla testów pochodzi z
//! pliku replay. Dzięki temu każdy test dekodera przechodzi dokładnie tę samą
//! ścieżką co program produkcyjny.

const std = @import("std");
const raw = @import("../../core/raw.zig");

pub const Leaf = struct {
    pub const vendor_info: u32 = 0x0000_0000;
    pub const signature_and_features: u32 = 0x0000_0001;
    pub const cache_params: u32 = 0x0000_0004;
    pub const extended_topology: u32 = 0x0000_000B;
    pub const determinism: u32 = 0x0000_0014;
    pub const frequency: u32 = 0x0000_0016;
    pub const v2_extended_topology: u32 = 0x0000_001F;

    pub const ext_function_info: u32 = 0x8000_0000;
    pub const ext_function_1: u32 = 0x8000_0001;
    pub const ext_brand_1: u32 = 0x8000_0002;
    pub const ext_brand_2: u32 = 0x8000_0003;
    pub const ext_brand_3: u32 = 0x8000_0004;
    pub const ext_power_params: u32 = 0x8000_0006;
    pub const ext_topology: u32 = 0x8000_001E;
    pub const ext_cache_params: u32 = 0x8000_001D;
};

/// Wypełnia 48-bajtowy brand string z liści 0x80000002..4.
///
/// Każdy liść daje 16 bajtów w kolejności EAX, EBX, ECX, EDX. Brak któregokolwiek
/// liścia oznacza brak brand stringu — wtedy zostawiamy same NUL-e i `RawCpuInfo`
/// oznaczy go jako niewiarygodny.
pub fn brandString(img: *const raw.CpuidImage) [48]u8 {
    var out: [48]u8 = @splat(0);
    const sources = [3]u32{ Leaf.ext_brand_1, Leaf.ext_brand_2, Leaf.ext_brand_3 };
    for (sources, 0..) |leaf_id, block| {
        const r = img.getBounded(leaf_id, 0) orelse return @splat(0);
        const regs = [4]u32{ r.eax, r.ebx, r.ecx, r.edx };
        for (regs, 0..) |reg, i| {
            const at = block * 16 + i * 4;
            out[at + 0] = @truncate(reg & 0xFF);
            out[at + 1] = @truncate((reg >> 8) & 0xFF);
            out[at + 2] = @truncate((reg >> 16) & 0xFF);
            out[at + 3] = @truncate((reg >> 24) & 0xFF);
        }
    }
    return out;
}

/// Zbiera flagi cech z leaf 1 (EDX, ECX), leaf 7 (EBX, ECX, EDX) i 0x80000001 (ECX).
///
/// Leaf 7 sprawdzamy z obsługą CPUID faulting: na procesorach, które go nie
/// wspierają, odczyt zwraca wartości liścia 1. Dlatego wymagamy zgody
/// bitu `feature_info` (CPUID.1.ECX[22]) oraz sensownej wartości `max_leaf`.
pub fn features(img: *const raw.CpuidImage) raw.Features {
    var f = raw.Features{};
    const l1 = img.getBounded(Leaf.signature_and_features, 0) orelse return f;

    // --- leaf 1, EDX ---
    f.sse = bit(l1.edx, 25);
    f.sse2 = bit(l1.edx, 26);

    // --- leaf 1, ECX ---
    f.sse3 = bit(l1.ecx, 0);
    f.ssse3 = bit(l1.ecx, 9);
    f.fma = bit(l1.ecx, 12);
    f.sse4_1 = bit(l1.ecx, 19);
    f.sse4_2 = bit(l1.ecx, 20);
    f.movbe = bit(l1.ecx, 22);
    f.popcnt = bit(l1.ecx, 23);
    f.aes = bit(l1.ecx, 25);
    f.avx = bit(l1.ecx, 28);
    f.f16c = bit(l1.ecx, 29);
    f.rdrand = bit(l1.ecx, 30);

    // --- leaf 7, EBX/EDX ---
    // Wymagamy `max_basic >= 7`. Na procesorach bez tego liścia CPUID zwraca
    // tam wartości leaf 1, co dałoby fałszywe AVX-512 i BMI.
    if (img.max_basic >= 7) {
        if (img.getBounded(7, 0)) |l7| {
            f.bmi1 = bit(l7.ebx, 3);
            f.avx2 = bit(l7.ebx, 5);
            f.bmi2 = bit(l7.ebx, 8);
            f.avx512f = bit(l7.ebx, 16);
            f.avx512dq = bit(l7.ebx, 17);
            f.rdseed = bit(l7.ebx, 18);
            f.avx512cd = bit(l7.ebx, 28);
            f.sha = bit(l7.ebx, 29);
            f.avx512bw = bit(l7.ebx, 30);
            f.avx512vl = bit(l7.ebx, 31);
            // AMX: EDX[22] = AMX-BF16, EDX[24] = AMX-TILE
            f.amx_bf16 = bit(l7.edx, 22);
            f.amx_tile = bit(l7.edx, 24);
        }
    }

    // --- leaf 0x80000001, ECX: ABM (lzcnt/popcnt) oraz cechy AMD ---
    if (img.getBounded(Leaf.ext_function_1, 0)) |e1| {
        const ecx1 = e1.ecx;
        f.lzcnt = bit(ecx1, 5); // ABM -> lzcnt
        f.sse4a = bit(ecx1, 6);
        f.fma4 = bit(ecx1, 8);
        f.xop = bit(ecx1, 11);
        f.tbm = bit(ecx1, 21);
    }
    return f;
}

/// Odczyt bitu. Indeks to `u5`, bo przesunięcie `u32` dopuszcza 0..31.
fn bit(v: u32, i: u5) bool {
    return (v & (@as(u32, 1) << i)) != 0;
}

/// Dekoduje cache z deterministic cache parameters (leaf 4) oraz
/// z rozszerzonego leaf 0x8000001D (AMD Zen).
///
/// Oba mają identyczny układ pól, co jest rzadkim ułatwieniem w rodzinie CPUID.
/// Leaf 4 iteruje się po subleaf, aż typ zwróci 0.
pub fn caches(img: *const raw.CpuidImage) raw.CacheSet {
    var set = raw.CacheSet{};

    for ([_]u32{ Leaf.cache_params, Leaf.ext_cache_params }) |leaf_id| {
        if (img.getBounded(leaf_id, 0) == null) continue;
        var subleaf: u32 = 0;
        while (subleaf < 16) : (subleaf += 1) {
            const r = img.get(leaf_id, subleaf) orelse break;
            const kind = @as(u8, @truncate(r.eax & 0x1F));
            if (kind == 0) break; // koniec tablicy cache dla tego leafa

            const level: u8 = @intCast((r.eax >> 5) & 0x7);
            const line: u16 = @as(u16, @truncate(r.ebx & 0xFFF)) + 1;
            const parts: u16 = @as(u16, @truncate((r.ebx >> 12) & 0x3FF)) + 1;
            const ways: u16 = @as(u16, @truncate((r.ebx >> 22) & 0x3FF)) + 1;
            const sets: u32 = r.ecx + 1;

            // EDX[4:0] = „max threads sharing this cache" ma sens **tylko**
            // w liściu 4. W liściu 0x8000001D (AMD) ten rejestr nie opisuje
            // współdzielenia — na Zen 3 wychodzi z niego 0 dla L1d (a L1d jest
            // dzielone przez 2 wątki), 2 dla L2 i 1 dla L3. Traktowanie tego
            // pola jak w Intelu dawało szerokość SMT = 1, czyli 16 „rdzeni".
            const sharing_known = leaf_id == Leaf.cache_params;
            const sharing_threads: u32 = if (sharing_known)
                @as(u32, @truncate(r.edx & 0x1F)) + 1
            else
                0;

            // EDX[25:14] = max cores in package (tylko liść 4). To liczba
            // **instancji** cache, nie mnożnik rozmiaru.
            const instance_count: u16 = if (sharing_known)
                @as(u16, @truncate((r.edx >> 14) & 0xFFF)) + 1
            else
                1;

            // Zmianę typu cache robimy w u64, bo ways*sets*line potrafi
            // przekroczyć u32 przy dużym L3 (np. 96 MB na 16-way).
            const size: u64 = @as(u64, line) * @as(u64, parts) *
                @as(u64, ways) * @as(u64, sets);

            // Zabezpieczenie przed podwójnym liczeniem: niektóre procesory
            // wypełniają ZARÓWNO liść 4, jak i 0x8000001D tym samym cache.
            // Bez tego guarda ten sam L3 trafiłby na listę dwa razy.
            var duplicate = false;
            for (set.slice()) |existing| {
                if (existing.level == level and
                    existing.cache_type == kind and
                    existing.size_bytes == size)
                {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;

            set.add(.{
                .level = level,
                .cache_type = kind,
                .line_size = line,
                .partitions = parts,
                .ways = ways,
                .sets = sets,
                .size_bytes = size,
                .shared = sharing_known and sharing_threads > 1,
                .sharing_threads = sharing_threads,
                .sharing_known = sharing_known,
                .instance_count = instance_count,
                .domain = switch (level) {
                    1, 2 => .core,
                    3 => .package,
                    else => .unknown,
                },
                .sharing_mask = 0,
            });
        }
    }
    return set;
}

/// Topologia: CPUID.1.EBX[23:16] (może zawyżać na wirtualizacji) oraz
/// CPUID.0x0B (liść topologii, wiarygodniejszy, gdy obecny).
pub fn topology(img: *const raw.CpuidImage) raw.Topology {
    var t = raw.Topology{};
    if (img.getBounded(Leaf.signature_and_features, 0)) |l1| {
        t.logical_from_leaf1 = @truncate((l1.ebx >> 16) & 0xFF);
    }
    // AMD Zen: leaf 0x8000001E. To **jedyna** wiarygodna ścieżka dla AMD —
    // leaf 0x0B na Zen 3 zwraca same zera.
    if (img.getBounded(Leaf.ext_topology, 0)) |e| {
        t.threads_per_core_amd_raw = @truncate(e.eax & 0xFF);
        t.cores_per_unit_amd = @truncate((e.ebx >> 8) & 0xFF);
        t.node_id_amd = @truncate(e.ecx & 0xFF);
        t.die_id_amd = @truncate((e.edx >> 8) & 0xFF);
        t.die_id_valid = ((e.edx >> 8) & 0xFF) != 0;
    }

    // Leaf 0x0B: poziom typu SMT ma EBX = liczba logicznych procesorów,
    // a EAX = liczba bitów przesunięcia do rdzenia, czyli threads_per_core
    // = 2^EAX. Sprawdzamy EBX, nie EAX, jako warunek obecności liścia.
    if (img.getBounded(Leaf.extended_topology, 0)) |l0b| {
        if (l0b.ebx != 0) {
            var subleaf: u32 = 0;
            while (subleaf < 8) : (subleaf += 1) {
                const r = img.get(Leaf.extended_topology, subleaf) orelse break;
                const level_type = @as(u8, @truncate((r.ecx >> 8) & 0xFF));
                if (level_type == 0) break;
                if (level_type == 1) { // SMT
                    const logical: u8 = @truncate(r.ebx & 0xFFFF);
                    if (logical != 0 and
                        (t.logical_from_leaf1 == 0 or logical == t.logical_from_leaf1))
                    {
                        t.logical_from_leaf_b = logical;
                        t.leaf_b_valid = true;
                        const shift: u8 = @truncate(r.eax & 0x1F);
                        t.smt_from_leaf_b = if (shift < 16) @as(u8, 1) << @intCast(shift) else 0;
                        t.source = .leaf_0x0b;
                        t.confident = t.smt_from_leaf_b >= 1;
                    }
                    break;
                }
            }
        }
    }
    // AMD: 0x8000001E **nie** jest źródłem szerokości SMT (opis pola
    // `threads_per_core_amd_raw`). Źródła pozostają leaf 0x0B oraz baza.
    return t;
}

/// Topologia z **thread-pinned** CPUID: pomiar na każdym logical procesorze.
///
/// To jest jedyna metoda, która nie zgaduje. Wszystkie poprzednie ścieżki
/// operowały na jednym odczycie, który na AMD opisuje **bieżący wątek**; tu
/// mamy komplet odczytów, więc liczymy różne identyfikatory rdzeni.
///
/// ## Dlaczego liczymy wątki per rdzeń, a nie dzielimy globalnie
///
/// Na CPU hybrydowym część rdzeni ma SMT wyłączone. Alder Lake i7-12700K to
/// 8 P-core (po 2 wątki) + 8 E-core (po 1 wątku) = 24 wątki na 16 rdzeniach.
/// `24 / 16 = 1.5`, więc globalne dzielenie **nie działa** i wcześniejsza
/// wersja zwracała dla hybrydu `0` rdzeni. Liczymy więc wątki dla każdego
/// rdzenia osobno: liczba różnych id rdzeni to liczba rdzeni fizycznych, a
/// maksimum wątków na rdzień to szerokość SMT.
///
/// ## AMD (liść 0x8000001E) — pomiar na Ryzen 7 5800X3D
///
/// `EBX[15:0]` = CoreId, `EBX[19:16]` = ThreadsPerCore (0 = nieznane),
/// `EBX[23:20]` = CoresPerComputeUnit, `ECX[7:0]` = NodeId, `EDX[15:8]` = DieId,
/// `EAX[7:0]` = ExtendedAPICId.
///
/// **CoreId nie jest globalnie unikalny.** W systemach wielopakietowych i
/// wielowęzłowych ten sam CoreId występuje w różnych węzłach, więc kluczem
/// rdzenia jest krotka `(NodeId, DieId, CoreId)`, a nie sam CoreId. Na
/// jednopakietowym 5800X3D oba warianty dają 8, ale na 2-gnyźdowej maszynie
/// liczenie samych CoreId podzieliłoby rdzenie przez dwa.
///
/// ## Intel (liście 0x0B / 0x1F) — semantyka wg SDM Vol. 2A
///
/// Rozkład rejestrów obu liści jest identyczny i **nie** zgadza się z tym, co
/// kod zakładał wcześniej:
///
/// * `EAX[4:0]`  — liczba bitów do przesunięcia x2APIC w prawo, żeby dostać
///   unikalny identyfikator **następnego** poziomu (nie „tyle bitów ma ten
///   poziom"). Wartości są kumulatywne od zera.
/// * `ECX[15:8]` — typ poziomu: 1 = SMT, 2 = Core, 3 = Module, 4 = Tile,
///   5 = Die, 6 = DieGrp.
/// * `ECX[7:0]`  — numer poziomu, równy indeksowi subleafa.
/// * `EDX[31:0]` — **x2APIC ID bieżącego procesora logicznego**.
///
/// x2APIC ID nie jest w `EBX[31:16]`; tam dla tych liści siedzi nic użytecznego,
/// a czytanie go dało wartości wyglądające sensownie i zupełnie błędne.
///
/// ### Dlaczego `core_id` trzeba maskować
///
/// `core = x2apic >> smt_shift` daje unikalne rdzenie **tylko w jednym
/// pakiecie**. Na dwóch gniazdach ten sam rdzeń ma `x2apic` różniący się o
/// `core_shift` bitów, więc `x2apic >> smt_shift` jest różny — a `core_id` po
/// zmaskowaniu do szerokości pola Core (`core_shift - smt_shift` bitów) jest
/// **ten sam**. To nie jest defekt fixture'u, tylko struktura numeracji: pole
/// `CoreId` jest lokalne w obrębie pakietu i **celowo się powtarza** między
/// gniazdami. Dlatego tożsamość rdzenia to krotka `(package_id, core_id)`,
/// a nigdy sam `core_id` — tak jak na AMD ze składniki `(NodeId, DieId, CoreId)`.
pub fn topologyFromPerCpu(per: *const raw.PerCpuImage, logical: u16) raw.Topology {
    var t = raw.Topology{};
    t.logical_from_leaf1 = @intCast(@min(logical, 255));
    if (per.len < 2) return t;

    const best = measure(per, logical, .intel) orelse measure(per, logical, .amd) orelse return t;
    t.smt_from_hardware = best.smt_max;
    t.physical_from_hardware = best.physical;
    t.hardware_complete = best.complete;
    t.hybrid = !best.uniform_smt;
    t.heterogeneous = best.heterogeneous;
    // `p_cores`/`e_cores` to **pochodne** od surowej numeracji klas, a osobny
    // licznik. Dzięki temu warstwa surowa zna tylko wartości SDM, a nazwy
    // pojawiają się dopiero na granicy dekoder/CLI.
    var p_c: u16 = 0;
    var e_c: u16 = 0;
    legacyClassCounts(best, &p_c, &e_c);
    t.p_cores = p_c;
    t.e_cores = e_c;
    t.class_values = best.class_values;
    t.class_counts = best.class_counts;
    t.class_len = best.class_len;
    t.nodes_measured = best.nodes;
    t.packages_measured = best.packages;
    if (best.complete) {
        t.source = .hardware;
        t.confident = true;
    }
    return t;
}

const Which = enum { intel, amd };

/// Wynik pomiaru: to, czego **nie** da się wyliczyć z jednego odczytu.
const Measured = struct {
    physical: u16 = 0,
    smt_max: u8 = 1,
    /// Czy każdy rdzeń ma tyle samo wątków. Fałsz = CPU hybrydowy.
    uniform_smt: bool = true,
    /// Klasy rdzeni wg **surowej numeracji SDM** (`EAX[31:16]`), nie nazwy
    /// „P-core/E-core". Projekt ma obsłużyć Apple, Qualcomm Oryon i układy o
    /// więcej niż dwóch klasach, więc zakładanie dwóch klas byłoby założeniem
    /// o konkretnym sprzęcie wpisanym do formatu danych.
    class_values: [raw.topology_class_capacity]u8 = @splat(255),
    class_counts: [raw.topology_class_capacity]u16 = @splat(0),
    class_len: u8 = 0,
    /// Czy widziano więcej niż jedną klasę rdzenia.
    heterogeneous: bool = false,
    /// Liczba pakietów (gniazd) — z bitów x2APIC powyżej najwyższego shiftu.
    packages: u16 = 0,
    /// Liczba węzłów NUMA (AMD `NodeId`).
    nodes: u16 = 0,
    /// Czy zebrano komplet odczytów. Częściowy zestaw dałby fałszywy wynik.
    complete: bool = false,
};

/// Pochodne liczby klas, których używa dekoder i CLI.
///
/// Trzymamy tu konwersję numeracji SDM na parę (`performance`, `efficiency`),
/// bo to jedyne dwie wartości, które Intel dokumentuje w `EAX[31:16]` liścia
/// 0x1F (0x40 = Core, 0x20 = Atom). **Pozostałe klasy nie giną** — zostają w
/// `class_values`/`class_counts`, żeby przyszły układ z trzecią klasą dał się
/// opisać bez zmiany formatu.
fn legacyClassCounts(m: Measured, p_cores: *u16, e_cores: *u16) void {
    p_cores.* = 0;
    e_cores.* = 0;
    var i: u8 = 0;
    while (i < m.class_len) : (i += 1) {
        switch (m.class_values[i]) {
            0x40 => p_cores.* += m.class_counts[i],
            0x20 => e_cores.* += m.class_counts[i],
            else => {},
        }
    }
}

/// Odczytuje **wszystkie** poprawne subleafe liścia `0x0B` / `0x1F`.
///
/// Konwencja CPUID: po ostatnim poprawnym poziomie kolejny subleaf zwraca typ
/// 0 (i `EAX = 0`), więc iterujemy do `invalid` i nie dalej. Nie zakładamy
/// dwóch poziomów — Sapphire Rapids dodaje Tile i Die, a przyszłe procesory
/// mogą mieć więcej.
fn readIntelLevels(img: *const raw.TopoImage, leaf_id: u32) raw.LevelSet {
    var set = raw.LevelSet{};
    var sub: u32 = 0;
    while (sub < raw.LevelSet.capacity) : (sub += 1) {
        const r = img.get(leaf_id, sub) orelse break;
        const kind = raw.LevelKind.fromCpuid(@truncate(r.ecx >> 8));
        if (kind == .invalid) break;
        const shift: u32 = r.eax & 0x1F;
        if (shift > 31) break;
        set.add(.{
            .subleaf = sub,
            .kind = kind,
            .level_number = @truncate(r.ecx & 0xFF),
            .shift = @intCast(shift),
            // SDM: x2APIC ID dla liści 0x0B/0x1F siedzi w EDX[31:0].
            .x2apic = r.edx,
            .core_type = @truncate(r.eax >> 16),
        });
    }
    return set;
}

/// Tożsamość jednego rdzenia z liścia `0x0B` / `0x1F`.
const IntelId = struct {
    /// Krotka `(package_id, core_id)` złożona w `u64`.
    ///
    /// `core_id` jest zmaskowane do szerokości pola Core, więc **powtarza się**
    /// między pakietami — i właśnie dlatego musi być parowany z `package_id`.
    /// `package_id` to bity x2APIC powyżej najwyższego poprawnego shiftu.
    key: u64 = 0,
    smt_shift: u8 = 0,
    core_type: u16 = 0,
    ok: bool = false,
};

fn intelId(img: *const raw.TopoImage) IntelId {
    var out = IntelId{};

    // 0x1F ma pierwszeństwo nad 0x0B: niesie typ rdzenia, którego 0x0B nie ma.
    var set = readIntelLevels(img, Leaf.v2_extended_topology);
    if (set.len == 0) set = readIntelLevels(img, Leaf.extended_topology);
    if (set.len == 0) return out;

    // Typ rdzenia bierzemy z poziomu Core; przy braku — z pierwszego poziomu,
    // który cokolwiek raportuje.
    var core_type: u16 = 0;
    for (set.slice()) |l| {
        if (l.core_type != 0) {
            core_type = l.core_type;
            if (l.kind == .core) break;
        }
    }

    // Shift SMT z poziomu SMT. Brak poziomu SMT (CPU bez wielowątkowości)
    // oznacza shift 0, a nie błąd.
    var smt_shift: u8 = 0;
    var have_smt = false;
    // Shift Core = granica pola package_id. Gdy nie ma poziomu Core, bierzemy
    // najwyższy poprawny shift ze wszystkich poziomów.
    var core_shift: u8 = 0;
    var have_core = false;
    var max_shift: u8 = 0;
    for (set.slice()) |l| {
        if (l.shift > max_shift) max_shift = l.shift;
        switch (l.kind) {
            .smt => if (!have_smt) {
                smt_shift = l.shift;
                have_smt = true;
            },
            .core => if (!have_core) {
                core_shift = l.shift;
                have_core = true;
            },
            else => {},
        }
    }
    if (!have_core) core_shift = max_shift;
    // `EAX[4:0]` jest kumulatywne, więc poziom Core nie może leżeć poniżej SMT.
    if (core_shift < smt_shift) return out;

    const levels = set.slice();
    const x2apic = levels[0].x2apic;

    // Szerokość pola Core = różnica obu shiftów. To jest dokładnie ta wartość,
    // którą gubimy, biorąc samo `x2apic >> smt_shift`.
    const core_bits: u8 = core_shift - smt_shift;
    const core_mask: u32 = if (core_bits == 0) 0 else if (core_bits >= 32) 0xFFFF_FFFF else (@as(u32, 1) << @intCast(core_bits)) - 1;
    const core_id = (x2apic >> @intCast(smt_shift)) & core_mask;
    const package_id = x2apic >> @intCast(core_shift);

    out.key = (@as(u64, package_id) << 32) | core_id;
    out.smt_shift = smt_shift;
    out.core_type = core_type;
    out.ok = true;
    return out;
}

/// Liczba wątków na rdzeń i liczba rdzeni z kompletu odczytów per-CPU.
///
/// Kluczem rdzenia jest krotka domen (AMD: NodeId+DieId+CoreId, Intel:
/// x2APIC>>shift), nigdy sam CoreId — patrz opis `topologyFromPerCpu`.
fn measure(per: *const raw.PerCpuImage, logical: u16, which: Which) ?Measured {
    // Tablice mają rozmiar `capacity`, żeby uniknąć alokacji w funkcji
    // wywoływanej per-CPU. Dla 256 CPU i 16 rdzeni miejsca jest z dużym zapasem;
    // nadmiar jest jawnie policzony, a nie nadpisany.
    var core_key: [raw.PerCpuImage.capacity]u64 = @splat(0);
    var key_class: [raw.PerCpuImage.capacity]u16 = @splat(0);
    var threads: [raw.PerCpuImage.capacity]u16 = @splat(0);
    // Liczba **unikalnych rdzeni** — wyłącznie licznik deduplikacji.
    // Osobna od zliczania klas, które liczą **typy**: wcześniejsza wersja
    // inkrementowała `p_count` w dwóch miejscach i deklarowała 11 rdzeni na 8
    // wątkach. Dwa liczniki o jednej nazwie, różniące się o 2, to najgorszy
    // rodzaj pomyłki: kod kompiluje się i daje wiarygodnie wyglądający wynik.
    var n_cores: u16 = 0;
    var class_counts: [raw.topology_class_capacity]u16 = @splat(0);
    var class_values: [raw.topology_class_capacity]u8 = @splat(255);
    var class_len: u8 = 0;
    var used_nodes: [raw.PerCpuImage.capacity]u16 = @splat(0);
    var n_nodes: u16 = 0;
    var used_pkgs: [raw.PerCpuImage.capacity]u32 = @splat(0);
    var n_pkgs: u16 = 0;
    var got: usize = 0;

    // Intel: shift SMT jest **per-procesor**, a nie globalny. Na CPU hybrydowym
    // P-core raportuje shift 1 (SMT2), a E-core shift 0 (bez SMT). Użycie
    // jednego shiftu dla całego procesora zawijało 8 wątków E-core do 4
    // kluczy i dawało 12 rdzeni zamiast 16. Dlatego shift czytamy z tego samego
    // CPU, którego klucz liczymy — i to jest sedno: pole opisuje wątek.
    for (per.slice()) |c| {
        var key: u64 = 0;
        var cls: u16 = 0;

        if (which == .intel) {
            const id = intelId(&c.image);
            if (!id.ok) return null;
            key = id.key;
            cls = id.core_type;
            // Pakiet to bity x2APIC powyżej najwyższego poprawnego shiftu —
            // liczymy różne wartości, nie zakładamy wyniku.
            const pkg: u32 = @truncate(id.key >> 32);
            var seen = false;
            var p: u16 = 0;
            while (p < n_pkgs) : (p += 1) {
                if (used_pkgs[p] == pkg) {
                    seen = true;
                    break;
                }
            }
            if (!seen and n_pkgs < used_pkgs.len) {
                used_pkgs[n_pkgs] = pkg;
                n_pkgs += 1;
            }
        } else {
            const e = c.image.get(Leaf.ext_topology, 0) orelse return null;
            // Klucz domenowy: NodeId (ECX[7:0]) + DieId (EDX[15:8]) + CoreId
            // (EBX[15:0]). Na jednopakietowym CPU Node/Die = 0, więc wynik
            // jest identyczny jak przy samym CoreId — ale na maszynie
            // wielowęzłowej to jedyna poprawna kombinacja.
            const node: u16 = @intCast(e.ecx & 0xFF);
            const die: u8 = @truncate((e.edx >> 8) & 0xFF);
            const core: u16 = @truncate(e.ebx & 0xFFFF);
            key = (@as(u64, node) << 24) | (@as(u64, die) << 16) | core;

            var seen = false;
            var k: u16 = 0;
            while (k < n_nodes) : (k += 1) {
                if (used_nodes[k] == node) {
                    seen = true;
                    break;
                }
            }
            if (!seen and n_nodes < used_nodes.len) {
                used_nodes[n_nodes] = node;
                n_nodes += 1;
            }
        }

        got += 1;
        var k: u16 = 0;
        while (k < n_cores) : (k += 1) {
            if (core_key[k] == key and key_class[k] == cls) break;
        }
        if (k == n_cores) {
            if (n_cores == core_key.len) return null; // absurdalna liczba rdzeni
            core_key[n_cores] = key;
            key_class[n_cores] = cls;
            n_cores += 1;
            // Typ liczymy **per rdzeń**, nie per wątek: 16 wątków P-core to
            // 8 rdzeni, nie 16. Wcześniejsza wersja doliczała w pętli po CPU
            // i raportowała 16 P-core + 8 E-core na 16 rdzeniach.
            //
            // Klasy zapisujemy jako **surową wartość SDM** z `EAX[31:16]`, nie
            // jako „P-core/E-core": format ma obsłużyć Apple i Qualcomm, a tam
            // nazwy i wartości są inne.
            if (which == .intel) {
                var ci: u8 = 0;
                while (ci < class_len) : (ci += 1) {
                    if (class_values[ci] == @as(u8, @truncate(cls))) break;
                }
                if (ci == class_len and class_len < class_counts.len) {
                    class_values[ci] = @truncate(cls);
                    class_len += 1;
                }
                if (ci < class_counts.len) class_counts[ci] += 1;
            }
        }
        threads[k] += 1;
    }
    if (n_cores == 0) return null;

    var smt_max: u8 = 1;
    var uniform = true;
    for (threads[0..n_cores]) |t| {
        if (t == 0) {
            uniform = false;
            continue;
        }
        if (t > smt_max) smt_max = @intCast(t);
        if (t != threads[0]) uniform = false;
    }

    // Sumy muszą się zgadzać z liczbą wątków zadeklarowaną przez system.
    // Jeśli nie, odczytaliśmy niekomplet i **nie** podajemy wyniku: lepszy brak
    // pomiaru niż liczba rdzeni, która wygląda wiarygodnie, a jest zmyślona.
    var sum: u32 = 0;
    for (threads[0..n_cores]) |t| sum += t;
    const complete = got == per.len and logical != 0 and sum == logical;

    // Heterogeniczność rozpatrujemy na dwa sposoby naraz, bo to **różne**
    // zjawiska: klasa rdzenia zgłoszona przez sprzęt (`EAX[31:16]`) oraz
    // faktyczna nierówność liczby wątków. CPU może mieć jedną klasę i
    // nierówne wątki (SMT wyłączony na części rdzeni), albo dwie klasy przy
    // jednakowej szerokości. `hybrid` (nierówność wątków) zostaje osobno, żeby
    // nie zgubić informacji, gdy klasa nie jest raportowana.
    var hetero = class_len > 1;
    if (!uniform) hetero = true;

    return .{
        .physical = n_cores,
        .smt_max = smt_max,
        .uniform_smt = uniform,
        .class_values = class_values,
        .class_counts = class_counts,
        .class_len = class_len,
        .heterogeneous = hetero,
        // AMD: liczba węzłów NUMA jest tym, co faktycznie raportuje
        // 0x8000001E. Intel: liczba pakietów z bitów x2APIC powyżej
        // najwyższego shiftu. Na jednopakietowym obie wartości to 1.
        .packages = if (which == .intel) @intCast(@max(n_pkgs, 1)) else @intCast(@max(n_nodes, 1)),
        .nodes = n_nodes,
        .complete = complete,
    };
}

/// Częstotliwość bazowa z leaf 0x16.
///
/// Wartość jest zakodowana jako **BCD**: każdy nibble to jedna cyfra
/// dziesiętna. 3800 MHz to `0x3800`, a nie 14336 — zwykłe odczytanie
/// `eax & 0xFFFF` jako liczby binarnej dałoby 14336 MHz, czyli 14 GHz.
pub fn baseFrequencyHz(img: *const raw.CpuidImage) ?u64 {
    const r = img.getBounded(Leaf.frequency, 0) orelse return null;
    if ((r.eax & 0x8000) == 0) return null; // bit 15 = 0 -> częstotliwość nieznana
    const bcd = r.eax & 0x7FFF;
    var mhz: u32 = 0;
    var scale: u32 = 1000;
    var shift: u5 = 12;
    while (true) {
        const digit: u32 = (bcd >> shift) & 0xF;
        if (digit > 9) return null; // nie-BCD -> nie ufamy danym
        mhz += digit * scale;
        if (shift == 0) break;
        shift -= 4;
        scale /= 10;
    }
    return @as(u64, mhz) * 1_000_000;
}

/// Wykonuje CPUID na bieżącym procesorze.
///
/// Na architekturach bez CPUID zwraca `null` zamiast błędu kompilacji: blok
/// z asemblerem siedzi w gałęzi `comptime`, więc na ARM64 w ogóle nie jest
/// analizowany. Dzięki temu ten sam plik obsługuje docelowe backendy
/// ARM64 i USOS bez `#ifdef`.
pub fn execute(leaf: u32, subleaf: u32) ?raw.Regs {
    if (comptime isX86()) {
        return executeX86(leaf, subleaf);
    } else {
        return null;
    }
}

fn isX86() bool {
    const arch = @import("builtin").cpu.arch;
    return arch == .x86 or arch == .x86_64;
}

fn executeX86(leaf: u32, subleaf: u32) raw.Regs {
    var eax: u32 = leaf;
    var ebx: u32 = undefined;
    var ecx: u32 = subleaf;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (eax),
          [b] "={ebx}" (ebx),
          [c] "={ecx}" (ecx),
          [d] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (subleaf),
        : .{ .cc = true }
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

const testing = std.testing;

fn leaf1(flags_edx: u32, flags_ecx: u32) raw.Regs {
    return .{ .eax = 0x000506E3, .ebx = 0x00100800, .ecx = flags_ecx, .edx = flags_edx };
}

test "brand: sklejanie 3 liści w 48 bajtów" {
    var img = raw.CpuidImage{};
    img.max_extended = 0x8000_0004;
    // Prawdziwe rejestry z AMD Zen 3. Kluczowa rzecz: w brand stringu
    // **najniższy bajt rejestru to pierwszy znak** (0x20444D41 -> "AMD ").
    // To nie jest kodowanie vendor stringu CPUID (0x756E6547), gdzie kolejność
    // jest odwrotna — pomylenie tych dwóch daje „Genuintel" zamiast „Genuine".
    img.add(0x8000_0002, 0, .{ .eax = 0x20444D41, .ebx = 0x657A7952, .ecx = 0x2037206E, .edx = 0x30303835 });
    img.add(0x8000_0003, 0, .{ .eax = 0x20443358, .ebx = 0x6F432D38, .ecx = 0x50206572, .edx = 0x65636F72 });
    img.add(0x8000_0004, 0, .{ .eax = 0x726F7373, .ebx = 0x20202020, .ecx = 0x20202020, .edx = 0x00202020 });

    const b = brandString(&img);
    // Nazwa ma 36 znaków; dopełnienie do 48 bajtów.
    try testing.expectEqualStrings("AMD Ryzen 7 5800X3D 8-Core Processor", b[0..36]);
    // AMD dopełnia SPACJAMI, nie zerami — dlatego `brandSlice` ucina na
    // pierwszym zerze dopiero po wypełnieniu 48 bajtów.
    try testing.expectEqual(@as(usize, 48), b.len);
}

test "brand: dopełnienie spacjami jest usuwane normalizacją" {
    var img = raw.CpuidImage{};
    img.max_extended = 0x8000_0004;
    img.add(0x8000_0002, 0, .{ .eax = 0x20444D41, .ebx = 0x657A7952, .ecx = 0x2037206E, .edx = 0x30303835 });
    img.add(0x8000_0003, 0, .{ .eax = 0x20443358, .ebx = 0x6F432D38, .ecx = 0x50206572, .edx = 0x65636F72 });
    img.add(0x8000_0004, 0, .{ .eax = 0x726F7373, .ebx = 0x20202020, .ecx = 0x20202020, .edx = 0x00202020 });

    var r = raw.RawCpuInfo{};
    r.brand = brandString(&img);
    r.computeBrandValidity();
    try testing.expect(r.brand_valid);
    try testing.expectEqualStrings("AMD Ryzen 7 5800X3D 8-Core Processor", r.brandSlice());
}

test "brand: brak liścia extended daje same zera, a nie śmieci" {
    var img = raw.CpuidImage{};
    img.max_extended = 0;
    const b = brandString(&img);
    for (b) |c| try testing.expectEqual(@as(u8, 0), c);
}

test "features: rdzeń Intel ma SSE/AVX2 z leaf 1 i 7" {
    var img = raw.CpuidImage{};
    img.max_basic = 7;
    // EDX: SSE(25) SSE2(26); ECX: SSE3(0) SSSE3(9) SSE4.1(19) SSE4.2(20) AES(25) AVX(28) F16C(29) RDRAND(30)
    img.add(1, 0, leaf1((1 << 25) | (1 << 26), (1 << 0) | (1 << 9) | (1 << 19) | (1 << 20) | (1 << 25) | (1 << 28) | (1 << 29) | (1 << 30)));
    // leaf 7 EBX: BMI1(3) AVX2(5) BMI2(8) AVX512F(16) SHA(29) AVX512BW(30) AVX512VL(31)
    img.add(7, 0, .{ .eax = 0, .ebx = (1 << 3) | (1 << 5) | (1 << 8) | (1 << 16) | (1 << 29) | (1 << 30) | (1 << 31), .ecx = 0, .edx = 0 });

    const f = features(&img);
    try testing.expect(f.sse and f.sse2 and f.sse3 and f.ssse3);
    try testing.expect(f.sse4_1 and f.sse4_2 and f.aes and f.avx and f.f16c and f.rdrand);
    try testing.expect(f.avx2 and f.bmi1 and f.bmi2 and f.sha);
    try testing.expect(f.avx512f and f.avx512bw and f.avx512vl);
    try testing.expect(!f.fma); // ECX[12] nieustawione
    try testing.expect(!f.amx_bf16);
}

test "features: ABM z leaf 0x80000001 daje lzcnt" {
    var img = raw.CpuidImage{};
    img.max_basic = 1;
    img.max_extended = 0x8000_0001;
    img.add(1, 0, leaf1(0, 0));
    img.add(0x8000_0001, 0, .{ .eax = 0, .ebx = 0, .ecx = 1 << 5, .edx = 0 });
    try testing.expect(features(&img).lzcnt);
}

test "features: bez leaf 7 nie zmyślamy AVX-512" {
    var img = raw.CpuidImage{};
    img.max_basic = 1;
    img.add(1, 0, leaf1((1 << 25) | (1 << 26), (1 << 28)));
    const f = features(&img);
    try testing.expect(f.avx);
    try testing.expect(!f.avx2 and !f.avx512f and !f.bmi1);
}

test "caches: leaf 4 L1/L2/L3 z rozmiarem policzonym z pól" {
    var img = raw.CpuidImage{};
    img.max_basic = 4;
    // L1d: typ 1, poziom 1, line 64, parts 1, ways 8, sets 64, sharing 1
    img.add(4, 0, .{ .eax = (1 << 5) | 1, .ebx = (7 << 22) | (0 << 12) | 63, .ecx = 63, .edx = 0 });
    // L1i: typ 2, poziom 1
    img.add(4, 1, .{ .eax = (1 << 5) | 2, .ebx = (3 << 22) | 63, .ecx = 63, .edx = 0 });
    // L2: typ 3, poziom 2, 4-way, 1024 sets -> 1 MiB
    img.add(4, 2, .{ .eax = (2 << 5) | 3, .ebx = (3 << 22) | 63, .ecx = 1023, .edx = 3 });
    // koniec tablicy
    img.add(4, 3, .{});

    const c = caches(&img);
    try testing.expectEqual(@as(usize, 3), c.len);
    try testing.expectEqual(@as(u64, 32 * 1024), c.items[0].size_bytes);
    try testing.expectEqual(@as(u8, 1), c.items[0].level);
    try testing.expectEqual(@as(u8, 2), c.items[1].cache_type);
    try testing.expectEqual(@as(u64, 64 * 1024 * 4), c.items[2].size_bytes);
    try testing.expectEqual(@as(u8, 2), c.items[2].level);
    try testing.expect(c.items[2].shared);
    // Szerokość SMT bierzemy z liczby wątków współdzielących cache, nie z boola.
    try testing.expectEqual(@as(u32, 1), c.items[0].sharing_threads);
    try testing.expectEqual(@as(u32, 4), c.items[2].sharing_threads);
}

test "topology: leaf 0x0B musi zgadzać się z leaf 1" {
    var img = raw.CpuidImage{};
    img.max_basic = 0x0B;
    img.add(1, 0, .{ .eax = 0, .ebx = (16 << 16), .ecx = 0, .edx = 0 }); // leaf 1: 16 logicznych
    img.add(0x0B, 0, .{ .eax = 0, .ebx = 16, .ecx = 1 << 8, .edx = 0 }); // poziom SMT, 16
    const t = topology(&img);
    try testing.expect(t.leaf_b_valid);
    try testing.expectEqual(@as(u8, 16), t.bestLogical());
}

test "topology: niespójny leaf 0x0B jest odrzucany, nie nadpisuje leaf 1" {
    var img = raw.CpuidImage{};
    img.max_basic = 0x0B;
    img.add(1, 0, .{ .eax = 0, .ebx = (8 << 16), .ecx = 0, .edx = 0 }); // leaf 1 mówi 8
    img.add(0x0B, 0, .{ .eax = 0, .ebx = 64, .ecx = 1 << 8, .edx = 0 }); // 0x0B mówi 64
    const t = topology(&img);
    try testing.expect(!t.leaf_b_valid);
    try testing.expectEqual(@as(u8, 8), t.bestLogical());
}

test "częstotliwość: leaf 0x16 w BCD" {
    var img = raw.CpuidImage{};
    img.max_basic = 0x16;
    // 3800 MHz w BCD to 0x3800, bit 15 = dane ważne.
    img.add(0x16, 0, .{ .eax = 0x8000 | 0x3800, .ebx = 0, .ecx = 0, .edx = 0 });
    try testing.expectEqual(@as(u64, 3_800_000_000), baseFrequencyHz(&img).?);
}

test "częstotliwość: wartość spoza BCD jest odrzucona" {
    var img = raw.CpuidImage{};
    img.max_basic = 0x16;
    img.add(0x16, 0, .{ .eax = 0x8000 | 0x3F00, .ebx = 0, .ecx = 0, .edx = 0 });
    try testing.expect(baseFrequencyHz(&img) == null);
}
test "częstotliwość: bit 15 = 0 oznacza brak danych" {
    var img = raw.CpuidImage{};
    img.max_basic = 0x16;
    img.add(0x16, 0, .{ .eax = 0x3800, .ebx = 0, .ecx = 0, .edx = 0 });
    try testing.expect(baseFrequencyHz(&img) == null);
}
