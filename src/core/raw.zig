//! Surowe dane CPU — warstwa między platformą a dekoderem.
//!
//! Zasada: `RawCpuInfo` zapisuje **wszystko, co udało się odczytać**, także to,
//! czego dziś nie umiemy zinterpretować. Dzięki temu plik capture zebrany dziś
//! da pełny wynik za rok, gdy dodamy kolejny dekoder.
//!
//! Wszystkie struktury są z góry ustalonego rozmiaru — bez alokacji. Probe
//! działa w fazie „fast scan", więc nie może blokować się na mallocu.

const std = @import("std");
const ids = @import("ids.zig");

pub const Arch = enum {
    x86,
    x86_64,
    arm64,
    riscv64,
    other,

    pub fn toSlice(self: Arch) []const u8 {
        return @tagName(self);
    }
};

/// Cztery rejestry CPUID.
pub const Regs = struct {
    eax: u32 = 0,
    ebx: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
};

/// Wpis obrazu CPUID: leaf + subleaf + wartości.
pub const Leaf = struct {
    leaf: u32,
    subleaf: u32,
    regs: Regs,
};

/// Surowy obraz CPUID.
///
/// Pojemność dobrana tak, aby mieściła komplet standardowego odczytu
/// (leaves podstawowe 0..0x20, extended 0x8000_0000..0x8000_0008, topologia,
/// cache i TLB) z zapasem na przyszłe liście. Przepełnienie jest jawnie
/// zgłaszane przez `dropped`, a nie po cichu nadpisywane.
pub const CpuidImage = struct {
    pub const capacity = 128;

    entries: [capacity]Leaf = undefined,
    len: usize = 0,
    dropped: usize = 0,

    max_basic: u32 = 0,
    max_extended: u32 = 0,

    /// Dodaje leaf; przy braku miejsca zlicza pominięcie zamiast nadpisywać.
    pub fn add(self: *CpuidImage, leaf: u32, subleaf: u32, regs: Regs) void {
        if (self.len == capacity) {
            self.dropped += 1;
            return;
        }
        self.entries[self.len] = .{ .leaf = leaf, .subleaf = subleaf, .regs = regs };
        self.len += 1;
    }

    pub fn get(self: *const CpuidImage, leaf: u32, subleaf: u32) ?Regs {
        for (self.entries[0..self.len]) |e| {
            if (e.leaf == leaf and e.subleaf == subleaf) return e.regs;
        }
        return null;
    }

    pub fn has(self: *const CpuidImage, leaf: u32) bool {
        for (self.entries[0..self.len]) |e| {
            if (e.leaf == leaf) return true;
        }
        return false;
    }

    pub fn slice(self: *const CpuidImage) []const Leaf {
        return self.entries[0..self.len];
    }

    /// Odczyt z pełną kontrolą zakresu.
    ///
    /// `max_basic` to wartość EAX z leaf 0, a `max_extended` to wartość EAX z
    /// leaf 0x80000000 — obie są już pełnymi numerami liści, więc granica jest
    /// proste porównanie. CPUID powyżej maksimum nie istnieje, a na emulatorach
    /// zwraca zawartość poprzedniego odczytu, co dałoby fałszywe dane.
    pub fn getBounded(self: *const CpuidImage, leaf: u32, subleaf: u32) ?Regs {
        if (leaf >= 0x8000_0000) {
            if (self.max_extended == 0 or leaf > self.max_extended) return null;
        } else {
            if (self.max_basic == 0 or leaf > self.max_basic) return null;
        }
        return self.get(leaf, subleaf);
    }
};

/// Zakres współdzielenia instancji cache.
pub const Domain = enum {
    unknown,
    /// Dzielone między wątkami jednego rdzenia (L1, L2 na Zen).
    core,
    /// Dzielone w obrębie CCD / die.
    ccd,
    /// Dzielone w obrębie gniazda, czyli cały pakiet (L3 na Zen).
    package,

    pub fn toSlice(self: Domain) []const u8 {
        return @tagName(self);
    }
};

/// Poziom pamięci cache z CPUID leaf 4 (Intel) / 0x8000001D (AMD Zen).
pub const CacheLevel = struct {
    level: u8,
    cache_type: u8, // 1=data, 2=instruction, 3=unified
    line_size: u16 = 0,
    partitions: u16 = 0,
    ways: u16 = 0,
    sets: u32 = 0,
    /// Rozmiar w bajtach, liczony z pól CPUID (nie z „ways * sets * line").
    size_bytes: u64 = 0,
    /// Czy to cache współdzielony między rdzeniami.
    shared: bool = false,
    /// Liczba logicznych rdzeni współdzielących ten cache.
    /// **0 = nieznana.** AMD w liściu 0x8000001D nie wypełnia tego pola
    /// według formatu Intela (na Zen 3 wychodzi L1d=0, L2=2, L3=1, co nie
    /// odpowiada żadnej rzeczywistej liczbie wątków), więc odczytujemy je
    /// wyłącznie z liścia 4. Mylenie tych rejestrów dawało 16 rdzeni zamiast 8.
    sharing_threads: u32 = 0,
    /// Czy `sharing_threads` pochodzi z wiarygodnego pola (liść 4).
    sharing_known: bool = false,
    /// Ile identycznych instancji tego cache opisuje (na pakiet).
    /// NIE jest mnożnikiem rozmiaru — rozmiar jest już podany per instancja.
    instance_count: u16 = 1,
    /// Gdzie instancje są współdzielone.
    domain: Domain = .unknown,
    /// Które logiczne rdzenia współdzielą ten cache (APIC id), jeśli umiemy.
    sharing_mask: u32 = 0,
};

/// Zbiór cache'ów CPU (bez alokacji).
pub const CacheSet = struct {
    pub const capacity = 24;
    items: [capacity]CacheLevel = undefined,
    len: usize = 0,

    pub fn add(self: *CacheSet, c: CacheLevel) void {
        if (self.len == capacity) return;
        self.items[self.len] = c;
        self.len += 1;
    }
    pub fn slice(self: *const CacheSet) []const CacheLevel {
        return self.items[0..self.len];
    }
};

/// Podstawowy zestaw cech CPU. Czytelna struktura zamiast bitsetu: przy tej
/// liczbie flag bitset tylko straciłby na czytelności JSON-a i `explain`.
pub const Features = struct {
    sse: bool = false,
    sse2: bool = false,
    sse3: bool = false,
    ssse3: bool = false,
    sse4_1: bool = false,
    sse4_2: bool = false,
    aes: bool = false,
    avx: bool = false,
    avx2: bool = false,
    fma: bool = false,
    bmi1: bool = false,
    bmi2: bool = false,
    f16c: bool = false,
    lzcnt: bool = false,
    popcnt: bool = false,
    movbe: bool = false,
    rdrand: bool = false,
    rdseed: bool = false,
    sha: bool = false,
    avx512f: bool = false,
    avx512bw: bool = false,
    avx512cd: bool = false,
    avx512dq: bool = false,
    avx512vl: bool = false,
    amx_bf16: bool = false,
    amx_tile: bool = false,
    // AMD
    fma4: bool = false,
    xop: bool = false,
    tbm: bool = false,
    sse4a: bool = false,

    pub const count = @typeInfo(Features).@"struct".fields.len;

    pub fn countSet(self: Features) usize {
        var n: usize = 0;
        inline for (@typeInfo(Features).@"struct".fields) |f| {
            if (@field(self, f.name)) n += 1;
        }
        return n;
    }
};

/// Skąd wzięliśmy topologię. Istotne diagnostycznie: `derived_from_cache`
/// oznacza wynik oparty na pośrednim wskaźniku, a nie na liściu topologii.
pub const TopologySource = enum {
    unknown,
    /// CPUID leaf 0x0B (standardowa topologia x2APIC; Intel i AMD Zen).
    leaf_0x0b,
    /// CPUID leaf 0x8000001E — rozszerzona topologia AMD (Zen).
    leaf_0x8000001e,
    /// Odtworzone z liczby wątków współdzielących L1d.
    derived_from_cache,
    /// Z hardware database — właściwość rodziny, nie pomiar tej maszyny.
    /// Używane, gdy CPUID nie daje wiarygodnej wartości (AMD, patrz niżej).
    hwdb,
    /// **Thread-pinned hardware CPUID** — wiarygodny pomiar wykonany na każdym
    /// logical procesorze osobno. Najwyższy priorytet, bo jedyna metoda, która
    /// nie zgaduje: opiera się na komplecie odczytów, nie na jednym.
    hardware,

    pub fn toSlice(self: TopologySource) []const u8 {
        return @tagName(self);
    }
};

/// Rodzaj poziomu w hierarchii topologii — **vendor-neutral**.
///
/// Numeracja pochodzi z Intel SDM Vol. 2A (CPUID.1F, `ECX[15:8]`), ale nazwy
/// są celowo generyczne. `performance`/`efficiency` to określenia klas
/// wydajności, używane przez Intel P/E, Apple, Qualcomm Oryon i inne układy —
/// nazwa nie jest własnością „Intela”, tylko znaczeniem rdzenia dla systemu.
/// Kod projektu nie może zakładać, że klasy są dokładnie dwie.
pub const LevelKind = enum(u8) {
    /// Poziom nieważny (konwencja CPUID: po ostatnim poprawnym poziomie
    /// kolejny subleaf zwraca typ 0 i `EAX = 0`).
    invalid = 0,
    /// Wątki na rdzeniu (SMT / SMT2).
    smt = 1,
    /// Rdzeń fizyczny.
    core = 2,
    /// Moduł (Xe: F‑tILE / modular).
    module = 3,
    /// Kafelek (Sapphire Rapids: TILE).
    tile = 4,
    /// Die.
    die = 5,
    /// Grupa die.
    die_group = 6,
    /// Poprawny poziom spoza udokumentowanej numeracji. Nie odrzucamy go —
    /// oznaczenie `other` z surową wartością pozwala pokazać sprzęt, którego
    /// jeszcze nie znamy, zamiast gubić poziom.
    other = 255,

    /// Mapowanie wartości `ECX[15:8]` na poziom. Wartości spoza tabeli nie są
    /// błędem: zachowujemy je jako `other` wraz z numerem.
    pub fn fromCpuid(v: u8) LevelKind {
        return switch (v) {
            0 => .invalid,
            1 => .smt,
            2 => .core,
            3 => .module,
            4 => .tile,
            5 => .die,
            6 => .die_group,
            else => .other,
        };
    }

    pub fn toSlice(self: LevelKind) []const u8 {
        return switch (self) {
            .invalid => "nieważny",
            .smt => "SMT",
            .core => "rdzeń",
            .module => "moduł",
            .tile => "kafelek",
            .die => "die",
            .die_group => "grupa die",
            .other => "inny",
        };
    }
};

/// Jeden poziom topologii odczytany z CPUID.
///
/// Dane są surowe i vendor-neutral: kod przechowuje **numerację SDM** i pozwala
/// później zdecydować, co z niej wynika. Nie wyprowadzamy tu jeszcze nazw
/// Intel- ani AMD-owych.
pub const TopologyLevel = struct {
    /// Indeks subleafa, którym ten poziom odczytano.
    subleaf: u32 = 0,
    /// Rodzaj poziomu (`ECX[15:8]`).
    kind: LevelKind = .invalid,
    /// Numer poziomu (`ECX[7:0]`) — zwykle równy `subleaf`.
    level_number: u8 = 0,
    /// `EAX[4:0]`: liczba bitów do przesunięcia x2APIC w prawo, żeby dostać
    /// unikalny identyfikator tego poziomu. **Kumulatywna** — nie „tyle bitów
    /// ma ten poziom", tylko „tyle trzeba przesunąć od zera".
    shift: u8 = 0,
    /// `EDX[31:0]`: x2APIC ID procesora logicznego, z którego odczytano.
    x2apic: u32 = 0,
    /// `EAX[31:16]`: typ rdzenia przy poziomie Core (0x40 = Core, 0x20 = Atom
    /// na liściu 0x1F). Poza tym poziomem rezerwowe.
    core_type: u16 = 0,
};

/// Zbiór poziomów topologii jednego procesora logicznego (bez alokacji).
pub const LevelSet = struct {
    /// 8 pokrywa 0x1F z pełną hierarchią SMT/Core/Module/Tile/Die/DieGrp
    /// i zapas na przyszłe poziomy. Limit jawny, żeby brak miejsca był
    /// zgłaszany, a nie po cichu obcinany.
    pub const capacity = 8;

    items: [capacity]TopologyLevel = @splat(.{}),
    len: usize = 0,

    pub fn add(self: *LevelSet, l: TopologyLevel) void {
        if (self.len == capacity) return;
        self.items[self.len] = l;
        self.len += 1;
    }

    pub fn slice(self: *const LevelSet) []const TopologyLevel {
        return self.items[0..self.len];
    }
};

/// Pojemność tablic klas rdzeni w `Topology`.
///
/// Deklaracja jest **poza** strukturą, bo Zig nie dopuszcza `const` między
/// polami kontenera. Pojemność 4 mieści Intel P/E, Apple performance/efficiency
/// i Qualcomm Oryon bez zmiany formatu. Nadmiar klas nie jest cichy:
/// `class_len` mówi, ile jest naprawdę wypełnionych.
pub const topology_class_capacity = 4;

/// Topologia rdzeni. Rozróżniamy wartość „z CPUID 1" (bywa zawyżona, gdy
/// hypervisor nie poprawia APIC id) i wartość z liści topologii.
pub const Topology = struct {
    /// Liczba logicznych procesorów widziana przez system (CPUID.1.EBX[23:16]).
    logical_from_leaf1: u8 = 0,
    /// Z CPUID leaf 0x0B — wiarygodniejsze, gdy obecne i spójne.
    logical_from_leaf_b: u8 = 0,
    /// Czy leaf 0x0B zwrócił sensowną wartość (≠ 0 i zgodną z leaf 1).
    leaf_b_valid: bool = false,

    /// Leaf 0x8000001E (AMD Zen) — **pole zachowane, ale celowo NIE używane**
    /// do wyznaczania szerokości SMT. Pomiar na prawdziwej maszynie
    /// (Ryzen 7 5800X3D) dał w dwóch kolejnych odczytach `eax = 0x02`
    /// (ApicId 1) i `eax = 0x0C` (ApicId 6) — wartość zależy od tego, na
    /// którym wątku trafił scheduler. To nie jest „threads per core", tylko
    /// opis bieżącej jednostki. Wykorzystanie tego pola dawało wynik
    /// zależny od przypadku: 8 rdzeni albo 0. Poprawna metoda AMD wymaga
    /// odczytu liścia na **każdym** procesorze logicznym z przypięciem
    /// wątku (thread pinning) — to zadanie Etapu 2.
    threads_per_core_amd_raw: u8 = 0,
    /// AMD podaje tu liczbę rdzeni **na jednostkę obliczeniową** (na Zen = 1),
    /// a nie rdzeni w pakiecie. To pole służy wyłącznie do koraboracji —
    /// mylenie go z „cores per package" zerowało liczbę rdzeni.
    cores_per_unit_amd: u8 = 0,
    node_id_amd: u8 = 0,
    die_id_amd: u8 = 0,
    die_id_valid: bool = false,

    /// Odtworzona szerokość SMT z leaf 0x0B (EAX = liczba bitów przesunięcia).
    smt_from_leaf_b: u8 = 0,

    /// Szerokość SMT z **thread-pinned CPUID** — pomiar na wszystkich CPU.
    smt_from_hardware: u8 = 0,
    /// Liczba rdzeni fizycznych z **thread-pinned CPUID** (liczba różnych id rdzeni).
    physical_from_hardware: u16 = 0,
    /// Czy pomiar objął komplet procesorów i dał spójny wynik.
    hardware_complete: bool = false,
    /// Czy CPU jest hybrydowy: część rdzeni ma inną liczbę wątków niż reszta.
    /// Na Alder Lake 8 P-core po 2 wątki + 8 E-core po 1, więc `24 / 16 = 1.5`
    /// i globalne dzielenie nie ma prawa dać szerokości SMT.
    hybrid: bool = false,
    /// Liczba rdzeni typu Core (P-core) — wiarygodna tylko na Intel 0x1F.
    p_cores: u16 = 0,
    /// Liczba rdzeni typu Atom (E-core) — wiarygodna tylko na Intel 0x1F.
    e_cores: u16 = 0,
    /// Liczba węzłów NUMA widzianych w pomiarze. 1 na jednopakietowym CPU.
    /// Nie jest to liczba pakietów: pakiet i węzeł to różne pojęcia, a CPUID
    /// bezpośrednio podaje tylko `NodeId`.
    nodes_measured: u16 = 0,

    /// **Liczba pakietów (socketów) z pomiaru**, nie z bazy.
    ///
    /// Osobne pole od `nodes_measured`, bo na wielogniazdowej maszynie Intel
    /// liczba pakietów bierze się z bitów x2APIC **powyżej najwyższego
    /// poprawnego shiftu**, a nie z `NodeId`. Myślenie „pakiet = węzeł" daje
    /// na dwóch gniazdach jedną liczbę zamiast dwóch.
    packages_measured: u16 = 0,

    /// Surowa numeracja klas rdzeni (typ rdzenia wg SDM) i liczności.
    ///
    /// Trzymamy **wartość**, nie nazwę i nie indeks „P-core/E-core", bo
    /// projekt ma obsłużyć Apple (performance/efficiency), Qualcomm Oryon
    /// (różne typy) i przyszłe układy z więcej niż dwiema klasami. Klasy
    /// identyfikowane są tym, co sprzęt faktycznie raportuje.
    class_values: [topology_class_capacity]u8 = @splat(255),
    class_counts: [topology_class_capacity]u16 = @splat(0),
    class_len: u8 = 0,

    /// Czy widziano więcej niż jedną klasę rdzenia.
    heterogeneous: bool = false,

    /// Odtworzona szerokość SMT z liczby wątków współdzielących L1d.
    smt_from_cache: u8 = 0,

    source: TopologySource = .unknown,
    /// Czy mieliśmy wystarczająco danych, by uznać topologię za pewną.
    confident: bool = false,

    /// Najlepsza dostępna liczba logicznych rdzeni.
    pub fn bestLogical(self: Topology) u8 {
        if (self.leaf_b_valid and self.logical_from_leaf_b != 0) return self.logical_from_leaf_b;
        return self.logical_from_leaf1;
    }
};

/// Ostrzeżenia zebrane podczas odczytu (np. niespójne leaf-e).
pub const Diagnostics = struct {
    pub const capacity = 16;
    entries: [capacity][96]u8 = undefined,
    lens: [capacity]usize = undefined,
    len: usize = 0,

    pub fn add(self: *Diagnostics, comptime fmt: []const u8, args: anytype) void {
        if (self.len == capacity) return;
        const s = std.fmt.bufPrint(&self.entries[self.len], fmt, args) catch return;
        self.lens[self.len] = s.len;
        self.len += 1;
    }

    pub fn get(self: *const Diagnostics, i: usize) []const u8 {
        if (i >= self.len) return "";
        return self.entries[i][0..self.lens[i]];
    }
};

/// Trzy stany wiedzy o jednym polu modelu.
///
/// Rozróżnienie `unknown` od `unavailable` ma znaczenie diagnostyczne:
/// `unknown` znaczy „nie ustaliliśmy (spróbuj inną ścieżką)”, a
/// `unavailable` — „sprzęt/system tego nie raportuje i nie będzie". Bez tego
/// nie odróżniamy „mieliśmy szansę i nie wykorzystaliśmy” od „nie ma czego czytać”.
pub const Knowledge = enum {
    known,
    unknown,
    unavailable,
};

/// Wartość opcjonalna z jawnym stanem wiedzy.
///
/// Świadomie **nie** używamy `?T`: samo `null` nie mówi, czy brak danych to
/// porażka pomiaru, czy brak możliwości sprzętu.
pub fn Maybe(comptime T: type) type {
    return union(enum) {
        unknown,
        unavailable,
        known: T,

        pub fn value(self: @This()) ?T {
            return switch (self) {
                .known => |v| v,
                else => null,
            };
        }
        pub fn orDefault(self: @This(), d: T) T {
            return self.value() orelse d;
        }
        pub fn isKnown(self: @This()) bool {
            return self == .known;
        }
    };
}

/// Mały obraz CPUID dla **jednego** logical procesora.
///
/// Osobny typ, nie `CpuidImage`, bo skan topologii czyta zaledwie kilka liści
/// na procesor. `CpuidImage` ma pojemność 128, więc 256 logical CPU w tablicy
/// dawało 512 KB kopiowane przez wartość — wystarczająco, by `parse` wywołane
/// z testu wybiło stos. Tutaj liczymy dokładnie to, czego skan potrzebuje:
/// liść 1, cztery subleafe 0xB, sześć subleafów 0x1F i jeden 0x8000001E.
///
/// Interfejs celowo identyczny z `CpuidImage`, żeby zmiana typu nie
/// rozsiewała się po dekodrach.
pub const TopoImage = struct {
    /// 1 (leaf 1) + 4 (0xB) + 6 (0x1F) + 1 (0x8000001E) = 12, z zapasem.
    pub const capacity = 16;

    /// Nazwa `Entry`, a nie `Leaf`: `CpuidImage` ma już zagnieżdżone `Leaf`
    /// i powtórzenie tej nazwy w tym samym pliku daje niejednoznaczną
    /// referencję wewnątrz struktur.
    pub const Entry = struct {
        leaf: u32,
        subleaf: u32,
        regs: Regs,
    };

    len: usize = 0,
    dropped: usize = 0,
    /// `undefined`, nie `@splat`: `Regs` jest strukturą, a `@splat` działa
    /// tylko na wektorach i tablicach. Wpisy poza `len` nigdy nie są czytane —
    /// `slice()` zwraca wyłącznie `0..len` — więc inicjalizacja byłaby tylko
    /// kosztem, bez żadnej korzyści.
    entries: [capacity]Entry = undefined,

    max_basic: u32 = 0,
    max_extended: u32 = 0,

    pub fn add(self: *TopoImage, leaf: u32, subleaf: u32, regs: Regs) void {
        if (self.len == capacity) {
            self.dropped += 1;
            return;
        }
        self.entries[self.len] = .{ .leaf = leaf, .subleaf = subleaf, .regs = regs };
        self.len += 1;
    }

    pub fn get(self: *const TopoImage, leaf: u32, subleaf: u32) ?Regs {
        for (self.entries[0..self.len]) |e| {
            if (e.leaf == leaf and e.subleaf == subleaf) return e.regs;
        }
        return null;
    }

    /// Odczyt z kontrolą zakresu — identyczna semantyka jak w `CpuidImage`.
    pub fn getBounded(self: *const TopoImage, leaf: u32, subleaf: u32) ?Regs {
        if (leaf >= 0x8000_0000) {
            if (self.max_extended == 0 or leaf > self.max_extended) return null;
        } else {
            if (self.max_basic == 0 or leaf > self.max_basic) return null;
        }
        return self.get(leaf, subleaf);
    }

    pub fn slice(self: *const TopoImage) []const Entry {
        return self.entries[0..self.len];
    }
};

/// Jeden logical processor wraz z własnym obrazem CPUID.
///
/// Osobny obraz na CPU jest konieczny: liście topologii (`0xB`, `0x1F`,
/// `0x8000001E`) opisują **ten** procesor, na którym wykonano CPUID, a nie
/// procesor, na którym trafił scheduler.
pub const LogicalCpu = struct {
    /// Identyfikator używany przez API platformy (CPU_SET / grupa Windows).
    id: u16 = 0,
    /// Czy `id` odpowiada numeracji logicznej platformy (0..N-1).
    id_valid: bool = false,

    /// x2APIC id z liścia 0xB / 0x1F — stabilny identyfikator topologii.
    x2apic: u32 = 0,
    x2apic_known: bool = false,

    /// APIC ID z CPUID.1.EDX[31:24] — tylko 8 bitów, przestarzały.
    legacy_apic: u8 = 0,
    legacy_apic_known: bool = false,

    /// Obraz CPUID odczytany **z tego** procesora.
    image: TopoImage = .{},

    /// Czy udało się ten procesor faktycznie odpytać.
    scanned: bool = false,
};

/// Zestaw logical processorów z ich obrazami.
pub const PerCpuImage = struct {
    /// 256 pokrywa wszystko, co spotyka się w praktyce na PC. Limit jest
    /// jawny, żeby brak miejsca był zgłaszany, a nie po cichu obcinany.
    pub const capacity = 256;

    len: usize = 0,
    items: [capacity]LogicalCpu = @splat(.{}),
    /// Ile wpisów zostało odrzuconych z powodu braku miejsca.
    dropped: usize = 0,

    pub fn add(self: *PerCpuImage, c: LogicalCpu) void {
        if (self.len == capacity) {
            self.dropped += 1;
            return;
        }
        self.items[self.len] = c;
        self.len += 1;
    }

    pub fn slice(self: *const PerCpuImage) []const LogicalCpu {
        return self.items[0..self.len];
    }

    pub fn get(self: *const PerCpuImage, id: u16) ?LogicalCpu {
        for (self.items[0..self.len]) |c| {
            if (c.id == id and c.id_valid) return c;
        }
        return null;
    }
};

/// Wynik probe'a CPU: surowy, bez interpretacji.
pub const RawCpuInfo = struct {
    arch: Arch = .other,
    vendor: ids.CpuVendor = .unknown,

    /// Pełny obraz CPUID — źródło prawdy dla dekoderów.
    cpuid: CpuidImage = .{},

    /// Leaf 1, EAX — numeracja, wstępnie rozwinięta w `Signature`.
    signature: ids.Signature = .{ .eax = 0 },

    /// Leaf 0x80000002..0x80000004 — 48 bajtów brand stringu, z NULami w środku.
    brand: [48]u8 = @splat(0),

    caches: CacheSet = .{},
    features: Features = .{},
    topology: Topology = .{},

    /// Obrazy CPUID poszczególnych logical processorów (Etap 2).
    /// Pusty, gdy backend nie ma `cpuid_per_logical_cpu` — wtedy topologia
    /// pochodzi z bieżącego CPU + bazy i jest jawnie oznaczona jako taka.
    per_cpu: PerCpuImage = .{},

    /// Ile CPU faktycznie odpytano (może być mniej niż `per_cpu.len`,
    /// gdy przypinanie wątku zawiodło na części procesorów).
    scanned_cpus: u32 = 0,

    /// Czy brand string jest wiarygodny (a nie np. all-zero na wirtualizacji).
    brand_valid: bool = false,

    diagnostics: Diagnostics = .{},

    /// Czy odczyt CPUID w ogóle się powiódł.
    cpuid_available: bool = false,

    /// Brand string **dokładnie tak, jak zwrócił CPUID**. AMD dopełnia go
    /// spacjami do 48 bajtów, Intel zerami, więc oba warianty muszą działać.
    pub fn brandRaw(self: *const RawCpuInfo) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.brand, 0) orelse self.brand.len;
        return self.brand[0..end];
    }

    /// Brand string po normalizacji — bez otaczających spacji. To jest wartość
    /// pokazywana użytkownikowi i porównywana w testach. Nie jest to zmiana
    /// danych, tylko usunięcie dopełnienia, którego treść nie niesie.
    pub fn brandSlice(self: *const RawCpuInfo) []const u8 {
        return std.mem.trim(u8, self.brandRaw(), " \t\x00");
    }

    /// Wykrywa brand string „wyglądający na śmieci" — typowe na starych
    /// wirtualizatorach, gdzie leaf 0x80000002..4 zwracają same NUL-e albo
    /// wzorce typu „GenuineIntel" w każdym polu.
    pub fn computeBrandValidity(self: *RawCpuInfo) void {
        const s = self.brandSlice();
        if (s.len == 0) {
            self.brand_valid = false;
            return;
        }
        var non_printable: usize = 0;
        var non_space: usize = 0;
        for (s) |c| {
            if (c == ' ') {
                non_space += 1;
                continue;
            }
            if (c < 0x20 or c > 0x7E) {
                non_printable += 1;
                continue;
            }
            non_space += 1;
        }
        // Więcej niż 1/4 znaków spoza ASCII => brand string nie do zaufania.
        self.brand_valid = non_printable * 4 <= s.len;
    }
};

const testing = std.testing;

test "CpuidImage: zapis i odczyt po leaf+subleaf" {
    var img = CpuidImage{};
    img.add(1, 0, .{ .eax = 0x000506E3 });
    img.add(0xB, 2, .{ .eax = 4 });

    try testing.expect(img.get(1, 0).?.eax == 0x000506E3);
    try testing.expect(img.get(0xB, 2).?.eax == 4);
    try testing.expect(img.get(0xB, 1) == null);
    try testing.expect(img.has(0xB));
    try testing.expect(!img.has(0x8000_0002));
}

test "CpuidImage: przepełnienie jest zliczane, nie nadpisywane" {
    var img = CpuidImage{};
    for (0..CpuidImage.capacity + 5) |i| {
        img.add(@intCast(i), 0, .{ .eax = @intCast(i) });
    }
    try testing.expectEqual(CpuidImage.capacity, img.len);
    try testing.expectEqual(@as(usize, 5), img.dropped);
    try testing.expectEqual(@as(u32, 0), img.get(0, 0).?.eax);
    try testing.expectEqual(@as(u32, 127), img.get(127, 0).?.eax);
}

test "CpuidImage: getBounded odrzuca liście powyżej max" {
    var img = CpuidImage{};
    img.max_basic = 4;
    img.max_extended = 0x8000_0008;
    img.add(0x9999_0000, 0, .{ .eax = 0xDEAD });
    // Liść podstawowy ponad maksimum nie istnieje.
    try testing.expect(img.getBounded(0x9999_0000, 0) == null);
    try testing.expect(img.has(0x9999_0000)); // surowy obraz zachowuje, co odczytano
}

test "brand: wykrywanie śmieci w brand stringu" {
    var raw = RawCpuInfo{};
    // Prawdziwy brand string jest dopełniony zerami — tak go też budujemy.
    // Wypełnienie spacjami dalo 48 znaków bez NUL-a, a `brandSlice()` ucina
    // dopiero na pierwszym zerze, więc test porównywał "A" z 48 znakami.
    raw.brand = @splat(0);
    raw.brand[0] = 'A';
    raw.computeBrandValidity();
    try testing.expect(raw.brand_valid);
    try testing.expectEqualStrings("A", raw.brandSlice());

    // Spacje wewnątrz brand stringu są legalne, ale dopełniające są usuwane —
    // inaczej AMD pokazywałby nazwę z 11 spacjami na końcu.
    var padded = RawCpuInfo{};
    padded.brand = @splat(0);
    @memcpy(padded.brand[0..15], "AMD Ryzen 7 580");
    padded.computeBrandValidity();
    try testing.expect(padded.brand_valid);
    try testing.expectEqualStrings("AMD Ryzen 7 580", padded.brandSlice());

    var bad = RawCpuInfo{};
    for (&bad.brand, 0..) |*c, i| c.* = if (i % 3 == 0) 0x01 else @as(u8, 'A');
    bad.computeBrandValidity();
    try testing.expect(!bad.brand_valid);
}
