//! Znormalizowany model CPU — wynik dekodera i bazy, wejście dla CLI i GUI.
//!
//! Warstwa `RawCpuInfo` (probe) i warstwa `CpuInfo` (decode + HWDB) są rozdzielone.
//! GUI nigdy nie pyta o surowe dane, a dekoder nigdy nie pyta o sprzęt.
//!
//! Zasada: **`CpuInfo.name` nie bywa pusty.** Gdy baza nie zna procesora,
//! model nadal opisuje, co dało się odczytać (producent, rodzina, model,
//! stepping, brand string), a `match` mówi wprost, jak wiarygodna jest nazwa.

const std = @import("std");
const ids = @import("ids.zig");
const raw = @import("raw.zig");

/// Skąd pochodzi wyświetlana nazwa procesora.
pub const DisplaySource = enum {
    /// Z hardware database — dopasowanie dokładne na sygnaturze.
    hwdb,
    /// Z hardware database — dopasowanie zakresem (rodzina + model).
    hwdb_pattern,
    /// Z CPUID brand string (0x80000002..4). Najczęstszy i najtańszy przypadek.
    brand_string,
    /// Złożona w dekoderze: producent + rodzina + model (bez wpisu w bazie).
    generated,
    /// Nie udało się ustalić niczego poza identyfikatorem CPUID.
    hex_id,
};

/// Jak dobrze dopasowaliśmy się do bazy. Raportowane w JSON-ie, żeby widzieć
/// pokrycie bazy bez zbierania danych osobowych.
///
/// Nazwy odpowiadają **jawnym** poziomom trafienia z `hwdb.HitLevel`. Wcześniej
/// istniał tu poziom `family`, który w rzeczywistości oznaczał „dowolny wpis o
/// zgodnej rodzinie” i przejmował `codename` z niepowiązanego modelu. Teraz
/// taki poziom nazwa się `family_generic` i wymaga wpisu jawnie oznaczonego flagą
/// `family_generic` w bazie.
pub const MatchQuality = enum {
    /// Dopasowanie dokładne: model i stepping w zakresie wpisu.
    exact,
    /// Dopasowanie zakresem modelu, stepping poza zakresem wpisu.
    device,
    /// Dopasowanie zakresem wielu modelu w obrębie rodziny.
    pattern,
    /// Dopasowanie **wyłącznie** na jawny wpis ogólny dla całej rodziny.
    family_generic,
    /// Znamy tylko producenta (z CPUID), baza nie ma żadnego pasującego wpisu.
    vendor_only,
    /// Baza nie wie nic o tej sygnaturze.
    unknown,

    pub fn toSlice(self: MatchQuality) []const u8 {
        return @tagName(self);
    }

    /// Czy wynik można pokazać użytkownikowi jako pewną nazwę.
    ///
    /// `family_generic` jest **niewiarygodny** mimo trafienia: wpis opisuje całą
    /// rodzinę, więc jego nazwa dotyczy rodziny, nie tego układu.
    pub fn isReliable(self: MatchQuality) bool {
        return switch (self) {
            .exact, .device, .pattern => true,
            .family_generic, .vendor_only, .unknown => false,
        };
    }
};

/// Skąd pochodzi konkretne pole znormalizowanego modelu.
///
/// Kluczowe: różne pola **nie muszą** pochodzić z tego samego źródła. Brand string
/// bywa wiarygodny z CPUID, gdy jednocześnie baza nie zna mikroarchitektury —
/// i to jest poprawna sytuacja, nie sprzeczność do rozstrzygania heurystyką.
pub const FieldSource = enum {
    /// Pole nieustalone — nikt o nim nie wie.
    none,
    /// Z CPUID (brand string, sygnatura, cechy).
    cpuid,
    /// Z wpisu bazy dopasowanego do sygnatury. Utrzymywane dla zgodności ze
    /// starszymi polami; nowy kod używa wariantów precyzyjnych poniżej.
    hwdb,
    /// Wygenerowane programu z samej sygnatury, gdy baza nie wiedziała.
    generated,
    /// HWDB trafiony na **konkretny model** (`HitLevel.single_model`).
    hwdb_exact,
    /// HWDB trafiony **zakresem modelu** (`HitLevel.model_range`) — wzorzec.
    hwdb_pattern,
    /// HWDB trafiony **wyłącznie** na jawny wpis `family_generic`.
    ///
    /// Osobne, bo nazwa z takiego wpisu dotyczy rodziny, nie tego układu —
    /// i użytkownik musi to widzieć w polu źródłowym, nie tylko w `match`.
    hwdb_family,
    /// Wyprowadzono z brand stringu przez **regułę z ograniczonym zakresem**.
    ///
    /// Nigdy nie niszczy twardych danych CPUID: brand może tylko wzbogacić
    /// identity o pola, których CPUID nie niesie (`product_name`, `variant`).
    brand_derived,
    /// Z SMBIOS (np. `Socket Designation`).
    ///
    /// Osobne od package/socket: SMBIOS opisuje **slot na płycie**, a nie
    /// gniazdo procesora. `CPU1` czy `J202` to nie jest typ gniazda.
    smbios,
    /// Z informacji platformowej (ACPI, rejestry platformowe).
    platform,
    /// Obserwacja empiryczna / porównanie referencyjne (np. CPU-Z jako oracle).
    ///
    /// To **nie** jest dokumentacja producenta. Nazwa pola ma to mówić wprost,
    /// żeby „zmierziliśmy na sprzęcie" nie czytało się jak „producent potwierdził".
    empirical,
    /// Sprawdzone i celowo **nieznane**. Różne od `none` (nikt o tym nie myślał).
    unknown,

    pub fn toSlice(self: FieldSource) []const u8 {
        return @tagName(self);
    }

    /// Czy to źródło pochodzi z odczytu sprzętu (a nie z bazy/heurystyki).
    ///
    /// Używane przez CLI do oznaczania pól, których **nie wolno** przedstawiać
    /// jako interpretacji.
    pub fn isHardware(self: FieldSource) bool {
        return self == .cpuid;
    }

    /// Czy to źródło jest interpretacją, a nie pomiarem.
    pub fn isDerived(self: FieldSource) bool {
        return switch (self) {
            .hwdb, .hwdb_exact, .hwdb_pattern, .hwdb_family, .brand_derived, .empirical => true,
            else => false,
        };
    }
};

/// Jak mocno ufamy danej interpretacji. Oddzielone od `FieldSource` dlatego, że
/// źródło i pewność to **dwie osie**: wpis może pochodzić z HWDB (źródło), a
/// nadal mieć `low` (pewność).
pub const Confidence = enum {
    /// Nie mamy podstaw do stwierdzenia.
    unknown,
    /// Słabe: obserwacja lub pośrednia dokumentacja, nie pierwotne źródło.
    low,
    /// Umiarkowane: potwierdzone na jednym sprzęcie albo w dokumentacji
    /// obejmującej **sąsiedni** zakres modeli.
    medium,
    /// Wysokie: pierwotne źródło producenta obejmujące dokładnie ten układ.
    high,

    pub fn toSlice(self: Confidence) []const u8 {
        return @tagName(self);
    }
};

/// Typ dowodu stojącego za wpisem bazy.
///
/// Osobny od `Confidence`, bo `high` znaczy różne rzeczy dla `vendor_doc`
/// i dla `reference_observation`: oba mogą być pewne, ale na podstawie
/// zupełnie różnego materiału.
pub const ProvenanceType = enum {
    /// Brak deklaracji.
    none,
    /// Pierwotna dokumentacja producenta obejmująca dokładnie ten układ.
    vendor_doc,
    /// Dokumentacja producenta obejmująca **sąsiedni** zakres modeli.
    vendor_doc_adjacent,
    /// Wniosek z CPUID + dokumentacji, wyprowadzony przez nas.
    derived,
    /// Pomiar na realnym sprzęcie (np. porównanie z CPU-Z jako oracle).
    reference_observation,
    /// Wpis społecznościowy; wymaga niezależnego potwierdzenia.
    community,

    pub fn toSlice(self: ProvenanceType) []const u8 {
        return @tagName(self);
    }
};

/// Skąd pochodzi konkretna interpretacja — URL, typ dowodu, pewność, notatka.
///
/// Jeden typ dla wszystkich nowych pól, bo użytkownik nie powinien musieć
/// sprawdzać osobnej struktury dla `stepping_name` i dla `socket_name`.
pub const Provenance = struct {
    /// Identyfikator dokumentu / URL / notatka źródłowa.
    source_url: ?[]const u8 = null,
    /// Krótki identyfikator źródła (np. `cpu-z-3.01.0-txt`).
    source: ?[]const u8 = null,
    source_type: ProvenanceType = .none,
    confidence: Confidence = .unknown,
    /// Wolny tekst: co dokładnie potwierdza i czego **nie** potwierdza.
    notes: ?[]const u8 = null,

    pub fn isEmpty(self: Provenance) bool {
        return self.source_url == null and self.source == null and
            self.source_type == .none and self.confidence == .unknown and self.notes == null;
    }
};

/// Typ rdzenia na CPU heterogenicznym.
///
/// `unknown` gdy CPUID nie podaje typu — **nie** zgadujemy z liczby rdzeni ani
/// nazwy marketingowej. Intel podaje go w liściu `0x1F`, `EAX[31:16]`:
/// `0x40` = Core (P-core), `0x20` = Atom (E-core).
pub const CoreType = enum {
    unknown,
    /// Intel Core / P-core (`0x1F EAX[31:16] = 0x40`).
    performance,
    /// Intel Atom / E-core (`0x1F EAX[31:16] = 0x20`).
    efficiency,

    pub fn toSlice(self: CoreType) []const u8 {
        return @tagName(self);
    }
};

/// Pojemność listy klas rdzeni w `CpuInfo`.
pub const core_class_capacity: usize = 4;

/// Jedna klasa rdzenia — **vendor-neutral**.
///
/// Trzymamy surową `value` z CPUID obok nazwy. Nazwa jest wygodą, nie danymi:
/// układ, którego numeracji jeszcze nie znamy, wciąż jest opisany, a nie
/// zgubiony. Zakładanie, że każdy heterogeniczny układ ma dokładnie dwie
/// klasy i konkretne wartości, to założenie o sprzęcie wpisane do modelu —
/// Apple i Qualcomm Oryon mają inne numeracje, a przyszłe układy mogą mieć
/// trzecią klasę.
pub const CoreClass = struct {
    /// Wartość raportowana przez sprzęt (Intel: `0x1F EAX[31:16]`).
    value: u8 = 255,
    cores: u16 = 0,
    /// Nazwa klasy; pusta, gdy numeracji nie znamy.
    name: []const u8 = "",

    /// Nazwa dla wartości SDM, którą Intel dokumentuje. Pozostałe wartości
    /// dostają pustą nazwę **zachowując `value`**, żeby dało się je pokazać
    /// bez zmyślania znaczenia.
    pub fn nameForValue(value: u8) []const u8 {
        return switch (value) {
            0x40 => "performance",
            0x20 => "efficiency",
            else => "",
        };
    }
};

pub const CacheInfo = struct {
    level: u8,
    kind: enum { data, instruction, unified },
    /// Rozmiar **jednej instancji**, w bajtach. Nigdy nie jest mnożony przez
    /// `instance_count` — CPUID podaje rozmiar per instancja.
    size_bytes: u64,
    line_size: u16,
    associativity: u16,
    sets: u32,
    /// Liczba wątków współdzielących instancję. 0 gdy nieznana (AMD nie
    /// udostępnia tego pola w liściu 0x8000001D).
    sharing_threads: u32,
    /// Czy `sharing_threads` jest zaufane.
    sharing_known: bool,
    /// Liczba identycznych instancji w pakiecie (nie mnożnik rozmiaru).
    instance_count: u16,
    /// Zakres współdzielenia instancji.
    domain: raw.Domain,
    shared: bool,
    sharing_mask: u32,
};

/// Pojemność bufora cache w `CpuInfo`. Deklaracja jest poza strukturą, bo
/// Zig nie dopuszcza deklaracji między polami kontenera.
pub const cache_capacity: usize = 16;

pub const Frequency = struct {
    hz: u64,
    pub fn mhz(self: Frequency) f64 {
        return @as(f64, @floatFromInt(self.hz)) / 1e6;
    }
    pub fn toSlice(self: Frequency, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d:.2} GHz", .{self.mhz()}) catch "??";
    }
};

/// Znormalizowany opis procesora.
pub const CpuInfo = struct {
    /// Czy odczyt w ogóle się powiódł. Gdy `false`, wszystkie pola poniżej są
    /// wypełnione wartościami zastępczymi, a nie zerami udającymi dane.
    available: bool = false,

    arch: raw.Arch = .other,
    vendor: ids.CpuVendor = .unknown,

    /// Sygnatura CPUID w postaci rozwiniętej (surowa z CPUID leaf 1 EAX).
    signature: ids.Signature = .{ .eax = 0 },
    /// Skąd wzięto sygnaturę. Zawsze `.cpuid` (sprzęt) — pole istnieje po to,
    /// żeby `stepping`, `display_family` i `display_model` miały **ten sam**,
    /// jawnie widoczny rodzaj pochodzenia. Surowych wartości nie wolno mylić
    /// z interpretacjami (`stepping_name`, `codename`), które mają własne pola.
    signature_source: FieldSource = .cpuid,
    /// Rodzina „wyświetlana" (SDM/APM), czyli ta z dokumentacji producenta.
    display_family: u8 = 0,
    display_model: u8 = 0,
    stepping: u8 = 0,

    /// Brand string z CPUID (48 B). Własny bufor, bez wskazania na `RawCpuInfo`,
    /// żeby `CpuInfo` dał się kopiować i serializować.
    brand: [48]u8 = @splat(0),
    brand_valid: bool = false,

    display: DisplaySource = .hex_id,
    match: MatchQuality = .unknown,

    /// Mikroarchitektura i kodowa nazwa z bazy. Puste, gdy baza nie wie.
    microarchitecture: ?[]const u8 = null,
    /// Skąd wzięto `microarchitecture`. Osobne od `display`, bo nazwa i
    /// mikroarchitektura mogą pochodzić z różnych miejsc.
    microarchitecture_source: FieldSource = .none,
    /// Skąd wzięto `codename`.
    codename_source: FieldSource = .none,
    /// Nazwa **siliconu** — fizycznego układu, na którym powstał procesor.
    ///
    /// Osobne od `codename`: Zen 3 występuje na kilku silikonach, a jeden
    /// silikon obsługuje warianty. Puste, gdy baza nie umie go wskazać.
    silicon_family: ?[]const u8 = null,
    /// Linia produktowa: „Ryzen 5000”, „EPYC 7003”.
    product_family: ?[]const u8 = null,
    /// Wariant w obrębie produktu: „3D V-Cache”, „X”, „G”, „K”.
    ///
    /// Uwaga: wariant **nie musi być rozpoznawalny z CPUID**. 5800X i 5800X3D
    /// mają identyczną sygnaturę (Family 19h, Model 0x21) — różni je wyłącznie
    /// brand string. Pole wypełnia więc mechanizm oparty na brand stringu, a nie
    /// dopasowanie wpisu po modelu. Ustalanie tego z bazy po samym zakresie
    /// modeli byłoby zgadywaniem.
    variant: ?[]const u8 = null,
    /// Wariant cache (np. „3D V-Cache”). Osobne od `variant`, bo cache bywa
    /// cechą pakietu, nie rdzenia.
    cache_variant: ?[]const u8 = null,
    /// Skąd wzięto nazwę pokazywaną (`displayName`).
    display_name_source: FieldSource = .none,
    codename: ?[]const u8 = null,
    /// Codename **zawężony** przez regułę brand, np. z „Vermeer / Milan-X”
    /// na „Vermeer”.
    ///
    /// Osobne pole, nie nadpisanie `codename`: wpis szeroki i wpis zawężony to
    /// **dwa różne poziomy pewności**, i użytkownik ma widzieć oba wraz ze
    /// źródłem. `null` = nie zawężono, a nie „nie ma zawężonego".
    ///
    /// Wypełnia się wyłącznie regułą, która ma **niezależne** provenance
    /// (`vendor_doc` i pochodne), nigdy obserwacją referencyjną — inaczej
    /// zawężenie byłoby zgadywaniem podstawionym pod pomiar.
    codename_refined: ?[]const u8 = null,
    codename_refined_source: FieldSource = .none,
    codename_refined_provenance: Provenance = .{},
    /// Znana rewizja z bazy (np. stepping -> "R3"), gdy baza ją podaje.
    revision: ?[]const u8 = null,

    // --- identyfikacja rozszerzona (Etap 3B) --------------------------------
    //
    // Poniższe pola są **interpretacjami**, nie pomiarami. Żadne z nich nie może
    // zostać wyprowadzone z samego CPUID inaczej niż przez bazę z jawnego
    // provenance, bo CPUID tych informacji nie zawiera.

    /// Nazwa kodowa stepppingu, np. `VMR-B2`.
    ///
    /// Osobne od `stepping`, który jest **surowym odczytem CPUID** i ma zostać
    /// taki. `stepping_name` to interpretacja: ten sam stepping w różnych rodzinach
    /// nazywa się inaczej, a litera w nazwie (`B`) bywa stała dla rodziny.
    ///
    /// `null` znaczy „nie umiemy", a nie „brak nazwy w bazie".
    stepping_name: ?[]const u8 = null,
    stepping_name_source: FieldSource = .none,
    /// Provenance `stepping_name` — pozwala odróżnić dokumentację producenta
    /// od obserwacji referencyjnej (np. porównania z CPU-Z).
    stepping_name_provenance: Provenance = .{},

    /// Nazwa gniazda/pakietu, np. `AM4`.
    ///
    /// **Nie** pochodzi z `smbios_socket_designation`: SMBIOS podaje nazwę slotu
    /// na płycie (`CPU1`, `J202`), a nie typ gniazda procesora.
    socket_name: ?[]const u8 = null,
    socket_source: FieldSource = .none,
    socket_confidence: Confidence = .unknown,
    /// Provenance `socket_name`.
    socket_provenance: Provenance = .{},

    /// Liczba kontaktów/-pinów pakietu. **0 = nieznana.**
    ///
    /// Celowo nie wypełniane „na oko": liczba widoczna w narzędziu referencyjnym
    /// bez niezależnego źródła producenta to `unknown`, nie dane.
    package_contacts: u16 = 0,

    /// `Socket Designation` z SMBIOS — **osobno** od `socket_name`.
    ///
    /// Świadomie nie zasypuje pola `socket_name`: wartości typu `CPU1` albo `J202`
    /// identyfikują slot na płycie, a nie typ gniazda. Trzymamy je, bo są
    /// użyteczne diagnostycznie, i jawnie pokazujemy, że to inna kategoria.
    smbios_socket_designation: ?[]const u8 = null,
    smbios_socket_source: FieldSource = .none,

    /// Nazwa produktu wyprowadzona z brand stringu, np. `Ryzen 7 5800X3D`.
    ///
    /// Inna od `product_family` (linia `Ryzen 5000`): tu konkretny SKU.
    product_name: ?[]const u8 = null,
    product_name_source: FieldSource = .none,

    /// Skąd wzięto `variant`. Kluczowe: `brand_derived` znaczy „zinterpretowaliśmy
    /// brand string przez regułę z ograniczonym zakresem", a nie „CPUID to podał".
    variant_source: FieldSource = .none,
    /// Provenance `variant`/`product_name` — prowadzi do reguły bazodanowej.
    variant_provenance: Provenance = .{},

    /// Skąd wzięto `cache_variant`.
    ///
    /// Osobne od `variant_source`, bo pola te pochodzą z **różnych** warstw:
    /// `cache_variant` bywa wprost w wpisie bazy (konkretny SKU), a `variant`
    /// często dopiero po korespondencji z brand stringiem.
    cache_variant_source: FieldSource = .none,

    cores_physical: u16 = 0,
    threads_logical: u16 = 0,
    /// Wątki na jeden rdzeń (SMT width). 1 = brak SMT.
    /// **0 = zmienne** (CPU hybrydowy) — wtedy prawdziwą wartość niesie
    /// `smt_max`, a `hybrid = true`. Podanie jednej liczby wyglądałoby jak
    /// jednolite SMT, a na Alder Lake 8 P-core ma po 2 wątki i 8 E-core po 1.
    threads_per_core: u16 = 1,
    /// Największa liczba wątków na pojedynczy rdzeń, zmierzona.
    /// Równa `threads_per_core` dla CPU jednorodnych.
    smt_max: u16 = 1,
    /// Skąd wzięliśmy topologię — widoczne w `explain` i JSON-ie, żeby nie
    /// udawać, że wszystko pochodzi z jednego autorytatywnego źródła.
    topology_source: raw.TopologySource = .unknown,
    /// Liczba gniazd (pakietów). 0 = nie ustalono.
    packages: u16 = 0,
    /// Liczba dies/CCD w pakiecie, gdy CPUID to podaje.
    dies: u16 = 0,
    /// Czy liczba rdzeni fizycznych jest pewna (przeszła niezmienniki).
    topology_confident: bool = false,
    /// Czy CPU ma SMT. Nie jest to to samo co `threads_per_core > 1`
    /// w przypadku CPU hybrydowego, więc zostawiamy oba pola.
    smt: bool = false,
    /// CPU heterogeniczny: rdzenie mają różną liczbę wątków (Alder Lake).
    hybrid: bool = false,
    /// Więcej niż jedna klasa rdzenia zgłoszona przez sprzęt. Osobne od
    /// `hybrid`: CPU może mieć jedną klasę przy nierównych wątkach (SMT
    /// wyłączony na części rdzeni) albo dwie klasy przy jednakowej szerokości.
    heterogeneous: bool = false,
    /// Klasy rdzeni jako lista, nie doliczone do dwóch pól. Format ma obsłużyć
    /// Apple i Qualcomm Oryon, nie tylko Intel P/E.
    core_class_buf: [core_class_capacity]CoreClass = undefined,
    core_class_len: usize = 0,
    /// Typ rdzenia. `unknown`, gdy CPUID nie podaje typu — nie zgadujemy.
    core_type: CoreType = .unknown,
    /// Liczba rdzeni klasy `0x40` (Intel Core / P-core). **Pochodna** z
    /// `core_class_buf`; kept dla czytelności CLI i bazy.
    p_cores: u16 = 0,
    /// Liczba rdzeni klasy `0x20` (Intel Atom / E-core). **Pochodna** z
    /// `core_class_buf`.
    e_cores: u16 = 0,
    /// Liczba węzłów NUMA widzianych w pomiarze CPUID. 1 na jednopakietowym
    /// CPU. To **nie** jest liczba pakietów: CPUID podaje `NodeId`, a pakiet
    /// i węzeł to różne pojęcia.
    nodes_measured: u16 = 0,

    base_clock: ?Frequency = null,
    max_boost: ?Frequency = null,

    /// Cache'i CPU. Bufor o stałym rozmiarze zamiast slice'a — `CpuInfo` ma być
    /// kopiowalny i serializowalny bez lifetime'ów.
    cache_buf: [cache_capacity]CacheInfo = undefined,
    cache_len: usize = 0,
    features: raw.Features = .{},

    /// Źródło identyfikacji pokazane w `explain`.
    db_source: ?[]const u8 = null,
    db_source_url: ?[]const u8 = null,

    /// Brand string po normalizacji: bez dopełniających spacji i zer.
    /// AMD dopełnia spacjami do 48 bajtów, Intel zerami — oba warianty
    /// muszą dać tę samą nazwę, inaczej native i replay różniłyby się
    /// tylko znakami.
    pub fn coreClassSlice(self: *const CpuInfo) []const CoreClass {
        return self.core_class_buf[0..self.core_class_len];
    }

    pub fn brandSlice(self: *const CpuInfo) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.brand, 0) orelse self.brand.len;
        return std.mem.trim(u8, self.brand[0..end], " \t\x00");
    }

    /// Nazwa do pokazania. Kolejność jest tu świadoma: baza > brand string >
    /// generowana. Brand string ustawiamy tylko wtedy, gdy jest wiarygodny.
    pub fn displayName(self: *const CpuInfo, buf: []u8) []const u8 {
        switch (self.display) {
            .hwdb, .hwdb_pattern => {
                if (self.brand_valid) return self.brandSlice();
                return std.fmt.bufPrint(buf, "{s} (Family {d} Model {d})", .{
                    self.vendor.toSlice(), self.display_family, self.display_model,
                }) catch "Unknown CPU";
            },
            .brand_string => {
                if (self.brand_valid) return self.brandSlice();
                return std.fmt.bufPrint(buf, "{s} (Family {d} Model {d})", .{
                    self.vendor.toSlice(), self.display_family, self.display_model,
                }) catch "Unknown CPU";
            },
            .generated => return std.fmt.bufPrint(buf, "{s} (Family {d} Model {d} Stepping {d})", .{
                self.vendor.toSlice(), self.display_family, self.display_model, self.stepping,
            }) catch "Unknown CPU",
            .hex_id => return std.fmt.bufPrint(buf, "Unknown CPU (Family {d} Model {d} Stepping {d})", .{
                self.display_family, self.display_model, self.stepping,
            }) catch "Unknown CPU",
        }
    }

    /// Czy wynik jest warty pokazania jako „rozpoznany procesor".
    pub fn isIdentified(self: *const CpuInfo) bool {
        return self.available and self.display != .hex_id;
    }

    pub fn cacheSlice(self: *const CpuInfo) []const CacheInfo {
        return self.cache_buf[0..self.cache_len];
    }

    pub fn addCache(self: *CpuInfo, c: CacheInfo) void {
        if (self.cache_len == cache_capacity) return;
        self.cache_buf[self.cache_len] = c;
        self.cache_len += 1;
    }
};

const testing = std.testing;

test "MatchQuality: reliability rozróżnia dopasowanie od zgadywania" {
    try testing.expect(MatchQuality.exact.isReliable());
    // `pattern` jest wiarygodny: reguła zakresowa **celowo** obejmuje wiele
    // modeli, ale autor bazy twierdzi, że dotyczą ich te same rzeczy. To nie
    // jest zgadywanie — pod warunkiem, że trafimy w zakres.
    try testing.expect(MatchQuality.pattern.isReliable());
    // Wpis ogólny dla rodziny mówi o rodzinie, nie o tym układzie.
    try testing.expect(!MatchQuality.family_generic.isReliable());
    try testing.expect(!MatchQuality.vendor_only.isReliable());
    try testing.expect(!MatchQuality.unknown.isReliable());
}

test "CpuInfo: nazwa nigdy nie jest pusta" {
    var info = CpuInfo{ .available = true, .vendor = .amd, .display_family = 0x17, .display_model = 0x71 };
    info.display = .generated;
    var buf: [96]u8 = undefined;
    const name = info.displayName(&buf);
    try testing.expect(name.len > 0);
    try testing.expect(std.mem.indexOf(u8, name, "Family 23") != null);
}

test "CpuInfo: niewiarygodny brand string nie jest używany jako nazwa" {
    var info = CpuInfo{ .available = true, .vendor = .intel, .display = .brand_string };
    // brand_valid = false, ale display twierdzi brand_string -> mamy fallback.
    var buf: [96]u8 = undefined;
    const name = info.displayName(&buf);
    try testing.expect(name.len > 0);
    try testing.expect(std.mem.indexOf(u8, name, "Intel") != null);
}
