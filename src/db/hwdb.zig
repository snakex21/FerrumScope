//! Runtime hardware database: wczytanie skompilowanego `ferrum-hwdb.bin`.
//!
//! Zasada z `docs/02-architektura.md`: program **nie parsuje** ciężkich baz
//! tekstowych przy każdym uruchomieniu. Źródło TOML jest kompilowane
//! osobnym narzędziem (`tools/hwdb_compile.zig`) do binarnego `ferrum-hwdb.bin`,
//! który jest wbudowany w program przez `@embedFile` (albo ładowany z dysku).
//!
//! Wczytywanie jest **bez alokacji**: wszystkie napisy to widoki na bajty
//! obrazu. Weryfikacja integralności (SHA-256) dzieje się przed udostępnieniem
//! danych, więc uszkodzony plik jest odrzucany, a nie czytany „na wiarę".
//!
//! Baza **nie wykonuje kodu** — zawiera wyłącznie liczby i napisy.

const std = @import("std");
const ids = @import("../core/ids.zig");

pub const magic = "FERRUMDB";

/// Wersja układu bajtów. Zmiana tego numeru oznacza, że **stary czytnik nie
/// umie poprawnie wczytać pliku** i musi go odrzucić.
///
/// Bump z 1 na 2: wpis dostał pola semantyczne (`silicon_family`,
/// `product_family`, `variant`, `cache_variant`), więc `entry_size` rośnie
/// z 40 do 52, a flaga `family_generic` zmienia pozycję. Czytnik v1 czytający
/// plik v2 wczytałby **błędną zawartość** pól napisowych — nie można tego
/// zostawić jako „wyglądającego podobnie".
pub const format_version: u16 = 3;

/// Najstarszy czytnik, jaki potrafi poprawnie wczytać tę bazę.
///
/// To **osobna** liczba od `format_version`. `format_version` opisuje układ
/// bajtów, a `minimum_reader_version` — kto potrafi zinterpretować semantykę.
/// Baza używająca funkcji, której czytelnik nie zna, podnosi tę wartość i
/// zostawia `format_version` bez zmian.
pub const minimum_reader_version: u16 = 3;

/// Wersja semantyczna schematu. Wyższa niż obsługiwana = pomijamy wpisy.
pub const schema_version: u16 = 1;
/// Identyfikator schematu w plikach źródłowych TOML. Kompilator odrzuci plik
/// z inną wartością, zamiast po cichu generować coś innego.
pub const schema_name = "ferrum.hwdb.cpu.v1";

/// Bity wymagane przez bazę, których czytnik **musi** rozumieć.
///
/// Baza deklaruje tu, czego używa. Czytnik sprawdza, czy zna **wszystkie**
/// wymagane bity; nieznany bit to powód do odrzucenia pliku, nie do zgadywania
/// semantyki. Dziś `format_version` robi to samo, ale po podniesieniu formatu
/// na 3+ pola `feature_flags` staną się jedynym mechanizmem — dlatego wchodzą
/// już teraz, żeby nie wymagać drugiej przeprowadzki migracji.
pub const FeatureFlags = struct {
    pub const FAMILY_GENERIC: u32 = 1 << 0; // wpisy `family_generic` w bazie
    pub const SEMANTIC_FIELDS: u32 = 1 << 1; // pola silicon/product/variant/cache
    /// Sekcja `Fact`: `stepping_name`, `socket_name`, `package_contacts`.
    pub const IDENTITY_FACTS: u32 = 1 << 2;
    /// Sekcja `BrandRule`: refinements z brand stringu.
    pub const BRAND_RULES: u32 = 1 << 3;

    /// Bity, które ten czytnik potrafi zinterpretować.
    pub const supported: u32 = FAMILY_GENERIC | SEMANTIC_FIELDS | IDENTITY_FACTS | BRAND_RULES;

    /// Czy czytnik ogarnia bazę wymagającą tych bitów.
    pub fn canRead(required: u32) bool {
        return required & ~supported == 0;
    }

    /// Bity wymagane przez bazę, których ten czytnik **nie zna**.
    pub fn unknownBits(required: u32) u32 {
        return required & ~supported;
    }
};

/// Baza v3 dodaje dwie sekcje payloadu: `Fact` (fakty o sygnaturze, np. nazwa
/// stepppingu, gniazdo) i `BrandRule` (reguły refinamentu z brand stringu).
///
/// **Osobne od `Entry` celowo.** `Entry` decyduje `MatchQuality`, a `family_generic`
/// opisuje całą rodzinę. Gdyby `stepping_name` czy `socket_name` siedziały w
/// `Entry`, zakres modelu musiałby zwęzić się tylko po to, żeby opisać gniazdo —
/// a `0x20..0x3F` to desktop (AM4) **i** serwer (SP3) w jednym wpisie. Osobna
/// sekcja pozwala opisać fakt precyzyjnie, nie zmieniając trafienia modelu.
pub const header_size: usize = 80;
pub const entry_size: usize = 52;
pub const fact_size: usize = 32;
pub const brand_rule_size: usize = 40;

/// Producent w bazie. Numery są częścią formatu — nie zmieniaj kolejności.
pub const VendorId = enum(u8) {
    intel = 0,
    amd = 1,
    hygon = 2,
    via = 3,
    zhaoxin = 4,
    unknown = 5,
    other = 6,

    pub fn fromCpu(v: ids.CpuVendor) VendorId {
        return switch (v) {
            .intel => .intel,
            .amd => .amd,
            .hygon => .hygon,
            .via => .via,
            .zhaoxin => .zhaoxin,
            .unknown => .unknown,
            .other => .other,
        };
    }

    pub fn toCpu(self: VendorId) ids.CpuVendor {
        return switch (self) {
            .intel => .intel,
            .amd => .amd,
            .hygon => .hygon,
            .via => .via,
            .zhaoxin => .zhaoxin,
            .unknown => .unknown,
            .other => .other,
        };
    }

    pub fn fromSlice(s: []const u8) ?VendorId {
        inline for (@typeInfo(VendorId).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

pub const Confidence = enum(u8) {
    low = 0,
    medium = 1,
    high = 2,

    pub fn fromSlice(s: []const u8) ?Confidence {
        inline for (@typeInfo(Confidence).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// Rodzaj dowodu stojącego za wpisem — **osobny** od `Confidence`.
///
/// `high` znaczy co innego dla dokumentacji producenta, a co innego dla
/// porównania z narzędziem referencyjnym: oba mogą być pewne, ale stoją na
/// innym materiale. Ten typ ma powiedzieć wprost, który to materiał.
pub const SourceType = enum(u8) {
    none = 0,
    /// Pierwotna dokumentacja producenta obejmująca dokładnie ten układ.
    vendor_doc = 1,
    /// Dokumentacja producenta obejmująca **sąsiedni** zakres modeli.
    vendor_doc_adjacent = 2,
    /// Wniosek wyprowadzony przez nas z CPUID + dokumentacji.
    derived = 3,
    /// Pomiar na realnym sprzęcie (np. porównanie z CPU-Z jako oracle).
    reference_observation = 4,
    /// Wpis społecznościowy; wymaga niezależnego potwierdzenia.
    community = 5,

    pub fn fromSlice(s: []const u8) ?SourceType {
        inline for (@typeInfo(SourceType).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @enumFromInt(f.value);
        }
        return null;
    }
};

/// Odniesienie do napisu w puli stringów.
pub const Str = struct {
    off: u16 = 0,
    len: u16 = 0,
    pub fn isEmpty(self: Str) bool {
        return self.len == 0;
    }
};

/// Dziwactwa, o których musi wiedzieć decoder.
///
/// Utrzymujemy je w bazie, bo zależą od konkretnej generacji, a nie od
/// architektury. To jest dokładnie ten podział, o który prosił plan: baza trzyma
/// „quirks", kod trzyma logikę ich stosowania.
pub const Quirk = packed struct(u32) {
    /// CPU nie zwraca wiarygodnego brand stringu — nazwa tylko z bazy.
    no_brand_string: bool = false,
    /// CPUID.1.EBX[23:16] bywa zawyżone (wirtualizacja, maszyna wirtualna
    /// deklarująca więcej rdzeni). Wolno wierzyć leaf 0x0B.
    htt_unreliable: bool = false,
    /// Cache opisuje leaf 0x8000001D, a nie leaf 4 (AMD Zen).
    cache_leaf_ext: bool = false,
    /// Numeracja wymaga reguły rozszerzonego modelu (rodzina 0x0F/0x06).
    extended_model_rule: bool = false,
    /// Ryzen 3+: część rdzeni ma włączone/wyłączone SMT.
    hybrid_cores: bool = false,
    /// Architektoniczna szerokość SMT rodziny (0 = nieznana).
    /// To **właściwość rodziny**, a nie pomiar: na AMD liść 0x8000001E
    /// opisuje bieżący wątek i bez przypięcia do rdzenia (thread pinning)
    /// zwraca różne wartości w zależności od tego, gdzie trafił scheduler.
    /// Dlatego Etap 1 bierze tę wartość z bazy i **mówi o tym wprost**
    /// przez `topology_source = .hwdb`, zamiast udawać pomiar.
    smt_threads: u4 = 0,
    // 5 flagów (5 bitów) + smt_threads (4 bity) = 9; do u32 brakuje 23 bitów.
    _reserved: u23 = 0,
};

/// Jak dokładnie trafiony jest wpis.
///
/// Poprzednia wersja używała `specificity: u3`, gdzie `1` oznaczało „dopasowanie
/// rodziny". To było **niejednoznaczne**: `matchCpu` przyznawał `specificity = 1`
/// dowolnemu wpisowi, którego `family_field` przypadkiem zgadzał się z rodziną,
/// a dekoder brał z niego `codename`. W efekcie nieznany model rodziny 6
/// raportował się jako „Merom/Conroe” — nazwą zupełnie innej generacji.
///
/// Teraz poziom jest **jawnie nazwany**, a wpis musi sam o sobie deklarować, że
/// jest ogólny dla rodziny (`family_generic`). Wpis szczegółowy nie może pełnić
/// roli fallbacku rodzinowego — nawet jeśli przypadkiem trafia.
pub const HitLevel = enum(u8) {
    /// Trafienie wyłącznie na **jawny** wpis `family_generic` tej rodziny.
    ///
    /// Nieosiągalne dla wpisu szczegółowego — nawet gdy `family_field` się zgadza.
    family_only = 0,
    /// Wpis obejmujący **zakres modeli**: reguła wzorca, nie wpis urządzenia.
    model_range = 1,
    /// Wpis **konkretnego modelu**, stepping poza jawnie podanym zakresem.
    no_stepping = 2,
    /// Wpis **konkretnego modelu**, stepping w zakresie lub nieograniczony.
    single_model = 3,

    /// Ranking do rozstrzygania remisów. Kolejność w enumie **jest** rankingiem:
    /// trafienie na konkretny model bije wzorzec, a wzorzec bije wpis ogólny.
    pub fn rank(self: HitLevel) u8 {
        return @intFromEnum(self);
    }
};

/// Wpis bazy: dopasowanie po sygnaturze CPUID -> wiedza o pokoleniu.
///
/// To **nie** jest wpis na każdy SKU. Nazwy marketingowe pochodzą z brand
/// stringu CPUID; baza niesie to, czego CPUID nie zwraca: mikroarchitekturę,
/// kodową nazwę, znane rewizje i dziwactwa.
pub const Entry = struct {
    vendor: VendorId = .unknown,
    ext_family: u8 = 0,
    family_field: u8 = 0,
    /// Zakres modelu „wyświetlanego" włącznie.
    model_min: u8 = 0,
    model_max: u8 = 0,
    stepping_min: u8 = 0,
    stepping_max: u8 = 0,
    confidence: Confidence = .low,
    /// Wpis opisuje **całą rodzinę**, nie konkretny model.
    ///
    /// Bez tej flagi wpis pasujący `model_min == model_max` jest traktowany jako
    /// trafienie konkretnego modelu i **nie może** być użyty jako fallback
    /// rodzinny. To właśnie brak tej flagi powodował fałszywe „Merom/Conroe”
    /// dla nieznanego modelu rodziny 6.
    family_generic: bool = false,
    uarch: Str = .{},
    codename: Str = .{},
    revision: Str = .{},
    source: Str = .{},
    source_url: Str = .{},
    /// Nazwa **siliconu** — fizycznego układu, na którym powstał procesor.
    ///
    /// Osobne od `codename`, bo to nie to samo: Zen 3 występuje na kilku
    /// różnych silikonach, a jeden silikon obsługuje warianty. `codename`
    /// opisuje **generację**; `silicon_family` — konkretny układ.
    silicon_family: Str = .{},
    /// Linia produktowa: „Ryzen 5000”, „EPYC 7003”. Warstwa marketingowa, ale
    /// **jednoznaczna** dla jednego procesora — w przeciwieństwie do `codename`,
    /// który dla zakresu modeli bywa wspólny dla desktopu i serwera.
    product_family: Str = .{},
    /// Wariant w obrębie produktu: „3D V-Cache”, „X”, „G”, „K”.
    variant: Str = .{},
    /// Wariant cache, np. „3D V-Cache”, gdy model ma dodatkowy cache na pakiecie.
    /// Osobne od `variant`, bo cache bywa cechą **pakietu**, nie rdzenia.
    cache_variant: Str = .{},
    quirks: u32 = 0,

    pub fn quirkFlags(self: Entry) Quirk {
        return @bitCast(self.quirks);
    }

    /// Czy wpis pasuje do sygnatury (bez oceny steppingu).
    pub fn matchesFamilyModel(self: Entry, sig: ids.Signature) bool {
        if (self.ext_family != sig.extFamily()) return false;
        if (self.family_field != sig.familyField()) return false;
        const m = sig.displayModel();
        return m >= self.model_min and m <= self.model_max;
    }

    pub fn matchesStepping(self: Entry, sig: ids.Signature) bool {
        const s = sig.stepping();
        return s >= self.stepping_min and s <= self.stepping_max;
    }

    /// Czy wpis **jawnie** opisuje całą rodzinę.
    pub fn isFamilyGeneric(self: Entry) bool {
        return self.family_generic and self.model_min == 0 and self.model_max == 0xFF;
    }

    /// Poziom trafienia tego wpisu dla podpisanej sygnatury, albo `null`, gdy
    /// wpis w ogóle nie pasuje.
    ///
    /// Dwie osie decydujące, rozstrzygane **niezależnie**:
    ///
    /// * **kształt reguły** — `model_min == model_max` to wpis konkretnego modelu
    ///   (`single_model`), zakres wielu modeli to reguła wzorca (`model_range`),
    /// * **trafienie stepppingu** — brak ograniczenia (`0..0xFF`) **nie** obniża
    ///   trafienia; obniża je dopiero jawny zakres, którego model nie dzieli.
    ///
    /// Pierwsza wersja myliła te osie i przez to każdy wpis z domyślnym zakresem
    /// stepppingu przestawał być trafieniem na konkretny model — regresja na
    /// kilku znanych CPU.
    pub fn hitLevel(self: Entry, sig: ids.Signature) ?HitLevel {
        if (self.isFamilyGeneric()) {
            if (self.ext_family != sig.extFamily()) return null;
            if (self.family_field != sig.familyField()) return null;
            return .family_only;
        }
        if (!self.matchesFamilyModel(sig)) return null;
        // Brak jawnego ograniczenia stepppingu to nie „nieznany stepping”, tylko
        // „autor nie rozróżnia rewizji”. Dopiero faktyczny zakres może nie trafić.
        if (self.stepping_min != 0 or self.stepping_max != 0xFF) {
            if (!self.matchesStepping(sig)) return .no_stepping;
        }
        return if (self.model_min == self.model_max) .single_model else .model_range;
    }
};

/// Fakt o sygnaturze: to, czego CPUID **nie zwraca**, a czego nie wolno wyliczyć
/// z samego steppingu.
///
/// Osobna sekcja, nie `Entry`, bo `Entry` decyduje `MatchQuality`. Zakres
/// `0x20..0x3F` to w jednym wpisie desktop (AM4) i serwer (SP3) — opisanie
/// gniazda w `Entry` wymuszałoby rozbicie wpisu, czyli zmianę semantyki
/// dopasowania. Fakt opisuje sygnaturę precyzyjnie i zostawia trafienie nietknięte.
pub const Fact = struct {
    vendor: VendorId = .unknown,
    ext_family: u8 = 0,
    family_field: u8 = 0,
    model_min: u8 = 0,
    model_max: u8 = 0xFF,
    stepping_min: u8 = 0,
    stepping_max: u8 = 0xFF,
    confidence: Confidence = .low,
    source_type: SourceType = .none,
    /// Liczba kontaktów/-pinów. 0 = nieznana. Nigdy nie zgadujemy.
    package_contacts: u16 = 0,
    _reserved: u8 = 0,
    /// Nazwa kodowa stepppingu, np. `VMR-B2`. Interpretacja, nie pomiar.
    stepping_name: Str = .{},
    /// Nazwa gniazda/pakietu, np. `AM4`. Osobne od `Socket Designation` z SMBIOS.
    socket_name: Str = .{},
    source: Str = .{},
    source_url: Str = .{},
    notes: Str = .{},

    pub fn matches(self: Fact, v: VendorId, sig: ids.Signature) bool {
        if (self.vendor != v) return false;
        if (self.ext_family != sig.extFamily()) return false;
        if (self.family_field != sig.familyField()) return false;
        const m = sig.displayModel();
        if (m < self.model_min or m > self.model_max) return false;
        const s = sig.stepping();
        return s >= self.stepping_min and s <= self.stepping_max;
    }
};

/// Reguła refinamentu **z brand stringu**, o ograniczonym zakresie.
///
/// To jest warstwa, której brief wymaga, żeby **nie** była luźnym substring
/// hackiem rozrzuconym po decoderze. Zakres jest obowiązkowy: reguła bez
/// `vendor` jest odrzucana przez kompilator, więc globalne „X3D” nie może
/// przypisać wariantu procesorowi innego producenta.
///
/// Reguła może wzbogacić **wyłącznie** `product_name` / `variant` /
/// `cache_variant`. Nie wolno jej dotknąć `vendor`, `family`, `model`,
/// `stepping`, topologii ani cache zmierzonego ze sprzętu.
pub const BrandRule = struct {
    vendor: VendorId = .unknown,
    ext_family: u8 = 0,
    family_field: u8 = 0,
    model_min: u8 = 0,
    model_max: u8 = 0xFF,
    confidence: Confidence = .low,
    source_type: SourceType = .none,
    /// Bit 0: wzorzec musi być dopasowany **w całości**, a nie jako podciąg.
    exact_match: bool = false,
    /// Wzorzec w znormalizowanym brand stringu, np. `5800X3D`.
    brand_pattern: Str = .{},
    product_name: Str = .{},
    variant: Str = .{},
    cache_variant: Str = .{},
    /// Codename **zawężony** wobec szerokiego wpisu bazy, np. z
    /// „Vermeer / Milan-X” do „Vermeer”.
    ///
    /// Pole przygotowane, ale **puste w bazie**: podział 0x2F/0x30 nie został
    /// potwierdzony i nie będziemy go zgadywać. Wypełni się dopiero przy
    /// wpisie z niezależnym provenance — patrz `canNarrowCodename`.
    refined_codename: Str = .{},
    source: Str = .{},
    source_url: Str = .{},
    notes: Str = .{},

    /// Czy ta reguła może **zawęzić** ogólny codename z wpisu bazy.
    ///
    /// Bramka jest celowo nieprzechodnia dla obserwacji referencyjnych i wpisów
    /// społecznościowych. Zawężenie „Vermeer / Milan-X” → „Vermeer” oparte na
    /// porównaniu z CPU-Z to **zgadywanie udające pomiar**: CPU-Z pokazuje
    /// „Vermeer”, ale nie mamy dokumentu AMD, który mówi, gdzie leży granica
    /// 0x2F/0x30. Do zawężenia potrzebne jest źródło niezależne od obserwacji.
    pub fn canNarrowCodename(self: BrandRule) bool {
        if (self.refined_codename.isEmpty()) return false;
        return switch (self.source_type) {
            .vendor_doc, .vendor_doc_adjacent, .derived => true,
            // Obserwacja referencyjna i wpis społecznościowy NIE wystarczają.
            .none, .reference_observation, .community => false,
        };
    }

    pub fn inScope(self: BrandRule, v: VendorId, sig: ids.Signature) bool {
        if (self.vendor != v) return false;
        if (self.ext_family != sig.extFamily()) return false;
        if (self.family_field != sig.familyField()) return false;
        const m = sig.displayModel();
        return m >= self.model_min and m <= self.model_max;
    }

    /// Sprawdza, czy znormalizowany brand string pasuje do wzorca reguły.
    ///
    /// Oba napisy przyjmujemy **jawnie**: `pattern` to treść brandu, a
    /// `self_pattern` to treść wzorca z puli napisów bazy. `BrandRule` nie ma
    /// dostępu do `Hwdb`, więc sama nie zamieni `Str` na tekst — a gdyby
    /// przyjęła `Str`, sygnatura kusiłaby, by podstawić tam `[]const u8`.
    /// Ten błąd właśnie wyłapał kompilator.
    pub fn matchesBrand(self: BrandRule, pattern: []const u8, self_pattern: []const u8) bool {
        if (self.exact_match) return std.mem.eql(u8, pattern, self_pattern);
        return std.mem.indexOf(u8, pattern, self_pattern) != null;
    }
};

/// Wynik dopasowania: wpis + jakość (jak blisko mu byliśmy).
pub const Match = struct {
    entry: Entry,
    /// Czy trafienie uwzględniało stepping, czy tylko rodzinę i model.
    exact_stepping: bool,
    /// Jawny poziom trafienia. Zastępuje dawną niejednoznaczną `specificity`.
    level: HitLevel,
};

/// Czy `match` może wykorzystać **quirks** wpisu (a także jego `smt_threads`).
///
/// `family_only` **nie** jest dopuszczone. `quirk_smt_threads` opisuje szerokość
/// SMT konkretnego wariantu, a `quirk_no_brand_string` — konkretny model. Wpis
/// ogólny dla rodziny nie może tego wiedzieć, a zastosowanie quirków z wariantu
/// niestosowalnego daje zmyśloną szerokość SMT z jawnym `topology_source = hwdb`,
/// czyli liczbę wyglądającą na pomiar.
///
/// Nazwy (`uarch`, `codename`) są dozwolone **także** na poziomie `family_only`:
/// wpis ogólny opisuje dokładnie to, co wspólne dla rodziny. Nie wolno mu natomiast
/// niczego mierzyć ani przejmować wariantów.
pub fn canUseQuirks(m: Match) bool {
    return m.level != .family_only;
}

pub const LoadError = error{
    Truncated,
    BadMagic,
    UnsupportedFormat,
    /// Nagłówek poprawny, ale baza wymaga czytelnika **nowszego** niż ten.
    ///
    /// Osobne od `UnsupportedFormat`, bo to inna sytuacja: format jest zrozumiały,
    /// a semantyka — nie. Osobny błąd pozwala CLI powiedzieć wprost, że potrzebuje
    /// aktualizacji, zamiast zgadywać przyczynę odmowy.
    UnsupportedReader,
    /// Baza wymaga funkcji (`feature_flags`), której ten czytnik nie zna.
    UnknownFeatureFlags,
    HashMismatch,
    EntryOutOfBounds,
    StringOutOfBounds,
};

/// Wczytana baza — widoki na bajty obrazu, bez własnej pamięci.
pub const Hwdb = struct {
    /// Cały obraz bazy. Wszystkie pozostałe odczyty to widoki na te bajty —
    /// wczytanie nie przydziela pamięci.
    bytes: []const u8,
    /// Wpisów nie kopiujemy do tablicy — `entryAt` dekoduje pola na żądanie
    /// prosto z bajtów obrazu. Dzięki temu wczytanie bazy jest zerowymi
    /// alokacjami, a jedynym kosztem jest weryfikacja sumy kontrolnej.
    db_revision: u32,
    schema: u16,
    built_unix: u64,
    /// Bity funkcji, których baza wymaga od czytelnika.
    feature_flags: u32,
    /// Deklarowana długość payloadu (bajty po nagłówku).
    payload_length: u32,

    /// Czy schema pliku jest nowsza, niż ta obsługiwana. Wpisy o nieznanych
    /// polach są wtedy pomijane zamiast błędnie interpretowane.
    pub fn isNewerSchema(self: Hwdb) bool {
        return self.schema > schema_version;
    }

    /// Sprawdza nagłówek, sumę kontrolną i granice każdego indeksu.
    ///
    /// Kolejność jest istotna: magic -> format -> granice -> hash -> wpisy.
    /// Parsujemy strukturę **przed** zaufaniem do sumy, żeby nie czytać
    /// poza buforem na podstawie danych z pliku.
    pub fn init(bytes: []const u8) LoadError!Hwdb {
        if (bytes.len < header_size) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..8], magic)) return error.BadMagic;

        const format = readU16(bytes, 8);
        if (format != format_version) return error.UnsupportedFormat;

        // Starszy czytnik NIE MOŻE po cichu wczytać nowszej bazy: układ bajtów
        // jest inny, a czytanie „na wiarę" dałoby błędne nazwy. Odrzucamy.
        const min_reader = readU16(bytes, 12);
        if (min_reader > format_version) return error.UnsupportedReader;

        // Baza może wymagać funkcji, których nie znamy. Nieznany bit to brak
        // wiedzy, nie „pewnie nieistotne" — odrzucamy zamiast zgadywać.
        const features = readU32(bytes, 24);
        if (!FeatureFlags.canRead(features)) return error.UnknownFeatureFlags;

        const schema = readU16(bytes, 10);
        const db_revision = readU32(bytes, 16);
        // `built_unix` to **u32** w bajtach 20..24. Bajty 24..28 zajmuje
        // `feature_flags`, więc czytanie u64 z bajtu 20 nachodziłoby na flagę
        // i zwracałoby śmieci. Kompilator też zapisuje tu u32.
        const built_unix = readU32(bytes, 20);
        const string_bytes = readU32(bytes, 28);
        const entry_count = readU32(bytes, 32);
        const fact_count = readU32(bytes, 72);
        const rule_count = readU32(bytes, 76);
        const payload_len = readU32(bytes, 68);

        const strings_start = header_size;
        const strings_end = strings_start + string_bytes;
        if (strings_end > bytes.len) return error.Truncated;

        const entries_start = strings_end;
        const entries_end = entries_start + @as(usize, entry_count) * entry_size;
        if (entries_end > bytes.len) return error.Truncated;

        // Granice nowych sekcji sprawdzamy **przed** zaufaniem do sumy kontrolnej:
        // plik może mieć poprawny nagłówek, a ucięte sekcje na końcu.
        const facts_start = entries_end;
        const facts_end = facts_start + @as(usize, fact_count) * fact_size;
        if (facts_end > bytes.len) return error.Truncated;
        const rules_end = facts_end + @as(usize, rule_count) * brand_rule_size;
        if (rules_end > bytes.len) return error.Truncated;

        // Deklarowana długość payloadu musi zgadzać się z faktycznym plikiem.
        // Niezgodność oznacza, że plik był ucięty albo dopisano do niego dane
        // spoza formatu — obie sytuacje są błędem integralności, nie nośnikiem.
        const expected = header_size + payload_len;
        if (expected != bytes.len) return error.Truncated;

        // Integralność: SHA-256 po obszarze nagłówka.
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(bytes[header_size..]);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        if (!std.mem.eql(u8, &digest, bytes[36..68])) return error.HashMismatch;

        return .{
            .bytes = bytes,
            .db_revision = db_revision,
            .schema = schema,
            .built_unix = built_unix,
            .feature_flags = features,
            .payload_length = payload_len,
        };
    }

    /// Liczba wpisów (z nagłówka, nie z tablicy — ta jest leniwa).
    pub fn count(self: Hwdb) usize {
        return readU32(self.bytes, 32);
    }

    pub fn factCount(self: Hwdb) usize {
        return readU32(self.bytes, 72);
    }

    pub fn brandRuleCount(self: Hwdb) usize {
        return readU32(self.bytes, 76);
    }

    /// Pierwszy początek sekcji `Fact` — za tablicą wpisów.
    fn factsStart(self: Hwdb) usize {
        const start = header_size + self.strings().len;
        return start + self.count() * entry_size;
    }

    fn brandRulesStart(self: Hwdb) usize {
        return self.factsStart() + self.factCount() * fact_size;
    }

    pub fn factAt(self: Hwdb, i: usize) ?Fact {
        if (i >= self.factCount()) return null;
        const base = self.factsStart() + i * fact_size;
        if (base + fact_size > self.bytes.len) return null;
        const b = self.bytes[base .. base + fact_size];
        return .{
            .vendor = @enumFromInt(b[0]),
            .ext_family = b[1],
            .family_field = b[2],
            .model_min = b[3],
            .model_max = b[4],
            .stepping_min = b[5],
            .stepping_max = b[6],
            .confidence = @enumFromInt(b[7]),
            .source_type = @enumFromInt(b[8]),
            .package_contacts = readU16(b, 9),
            .stepping_name = .{ .off = readU16(b, 12), .len = readU16(b, 14) },
            .socket_name = .{ .off = readU16(b, 16), .len = readU16(b, 18) },
            .source = .{ .off = readU16(b, 20), .len = readU16(b, 22) },
            .source_url = .{ .off = readU16(b, 24), .len = readU16(b, 26) },
            .notes = .{ .off = readU16(b, 28), .len = readU16(b, 30) },
        };
    }

    pub fn brandRuleAt(self: Hwdb, i: usize) ?BrandRule {
        if (i >= self.brandRuleCount()) return null;
        const base = self.brandRulesStart() + i * brand_rule_size;
        if (base + brand_rule_size > self.bytes.len) return null;
        const b = self.bytes[base .. base + brand_rule_size];
        return .{
            .vendor = @enumFromInt(b[0]),
            .ext_family = b[1],
            .family_field = b[2],
            .model_min = b[3],
            .model_max = b[4],
            .confidence = @enumFromInt(b[5]),
            .source_type = @enumFromInt(b[6]),
            .exact_match = b[7] != 0,
            .brand_pattern = .{ .off = readU16(b, 8), .len = readU16(b, 10) },
            .product_name = .{ .off = readU16(b, 12), .len = readU16(b, 14) },
            .variant = .{ .off = readU16(b, 16), .len = readU16(b, 18) },
            .cache_variant = .{ .off = readU16(b, 20), .len = readU16(b, 22) },
            .refined_codename = .{ .off = readU16(b, 36), .len = readU16(b, 38) },
            .source = .{ .off = readU16(b, 24), .len = readU16(b, 26) },
            .source_url = .{ .off = readU16(b, 28), .len = readU16(b, 30) },
            .notes = .{ .off = readU16(b, 32), .len = readU16(b, 34) },
        };
    }

    /// Które pole faktu szukamy. Osobne pola mają **różny zakres**: `VMR-B2`
    /// dotyczy konkretnego stepppingu, `AM4` — całego modelu.
    const FactField = enum { stepping_name, socket_name, package_contacts };

    /// Pierwszy pasujący fakt, który **deklaruje** dane pole.
    ///
    /// Osobne lookupi zamiast jednego „pierwszego dopasowania”, bo `Fact` dla
    /// Vermeer to dwa rekordy o różnych zakresach: jeden wąski (stepping 2 →
    /// `VMR-B2`), drugi szeroki (cały model → `AM4`). Pojedyncze `factFor`
    /// zwróciłoby wąski i **ukryłoby gniazdo** dla 5800X3D.
    fn firstFactWith(self: Hwdb, v: VendorId, sig: ids.Signature, field: FactField) ?Fact {
        var i: usize = 0;
        while (i < self.factCount()) : (i += 1) {
            const f = self.factAt(i) orelse continue;
            if (!f.matches(v, sig)) continue;
            const declares = switch (field) {
                .stepping_name => !f.stepping_name.isEmpty(),
                .socket_name => !f.socket_name.isEmpty(),
                .package_contacts => f.package_contacts != 0,
            };
            if (declares) return f;
        }
        return null;
    }

    /// Fakt niosący nazwę kodową stepppingu, albo `null`.
    pub fn steppingNameFact(self: Hwdb, v: VendorId, sig: ids.Signature) ?Fact {
        return self.firstFactWith(v, sig, .stepping_name);
    }

    /// Fakt niosący nazwę gniazda, albo `null`.
    pub fn socketFact(self: Hwdb, v: VendorId, sig: ids.Signature) ?Fact {
        return self.firstFactWith(v, sig, .socket_name);
    }

    /// Fakt niosący liczbę kontaktów, albo `null`.
    ///
    /// Osobno, bo `package_contacts = 0` znaczy **„nie wiemy"**, a nie „brak”.
    /// Bez tego rozróżnienia gniazdo bez potwierdzonej liczby pinów wyglądałoby
    /// jak kompletna dana.
    pub fn packageContactsFact(self: Hwdb, v: VendorId, sig: ids.Signature) ?Fact {
        return self.firstFactWith(v, sig, .package_contacts);
    }

    /// Reguły refinamentu z brandu **w zakresie** tej sygnatury.
    ///
    /// Zwrócone reguły są już przefiltrowane po vendorze i zakresie modelu —
    /// dzieje się to **w bazie**, nie w decoderze, żeby reguła spoza zakresu
    /// nie mogła „wyciec” do innego procesora nawet przez pomyłkę w kodzie.
    pub fn brandRulesFor(self: Hwdb, v: VendorId, sig: ids.Signature, out: []BrandRule) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < self.brandRuleCount()) : (i += 1) {
            if (n >= out.len) break;
            const r = self.brandRuleAt(i) orelse continue;
            if (r.inScope(v, sig)) {
                out[n] = r;
                n += 1;
            }
        }
        return n;
    }

    /// Zwraca wpis bez kopiowania: dekodujemy pola na żądanie.
    pub fn entryAt(self: Hwdb, i: usize) ?Entry {
        if (i >= self.count()) return null;
        const base = header_size + self.strings().len + i * entry_size;
        if (base + entry_size > self.bytes.len) return null;
        const b = self.bytes[base .. base + entry_size];
        return .{
            .vendor = @enumFromInt(b[0]),
            .ext_family = b[1],
            .family_field = b[2],
            .model_min = b[3],
            .model_max = b[4],
            .stepping_min = b[5],
            .stepping_max = b[6],
            .confidence = @enumFromInt(b[7]),
            .family_generic = b[44] != 0,
            .uarch = .{ .off = readU16(b, 8), .len = readU16(b, 10) },
            .codename = .{ .off = readU16(b, 12), .len = readU16(b, 14) },
            .revision = .{ .off = readU16(b, 16), .len = readU16(b, 18) },
            .source = .{ .off = readU16(b, 20), .len = readU16(b, 22) },
            .source_url = .{ .off = readU16(b, 24), .len = readU16(b, 26) },
            .silicon_family = .{ .off = readU16(b, 28), .len = readU16(b, 30) },
            .product_family = .{ .off = readU16(b, 32), .len = readU16(b, 34) },
            .variant = .{ .off = readU16(b, 36), .len = readU16(b, 38) },
            .cache_variant = .{ .off = readU16(b, 40), .len = readU16(b, 42) },
            .quirks = readU32(b, 48),
        };
    }

    fn strings(self: Hwdb) []const u8 {
        return self.bytes[header_size .. header_size + readU32(self.bytes, 28)];
    }

    /// Granice tablicy wpisów — używane przez testy i walidator.
    pub fn entriesBounds(self: Hwdb) struct { start: usize, end: usize } {
        const start = header_size + self.strings().len;
        return .{ .start = start, .end = start + self.count() * entry_size };
    }

    /// Granice sekcji `Fact` — używane przez walidator integralności.
    pub fn factsBounds(self: Hwdb) struct { start: usize, end: usize } {
        const start = self.factsStart();
        return .{ .start = start, .end = start + self.factCount() * fact_size };
    }

    /// Granice sekcji `BrandRule` — używane przez walidator integralności.
    pub fn brandRulesBounds(self: Hwdb) struct { start: usize, end: usize } {
        const start = self.brandRulesStart();
        return .{ .start = start, .end = start + self.brandRuleCount() * brand_rule_size };
    }

    pub fn text(self: Hwdb, s: Str) []const u8 {
        if (s.len == 0) return "";
        const off = @as(usize, s.off);
        const len = @as(usize, s.len);
        if (off + len > self.strings().len) return "";
        return self.strings()[off .. off + len];
    }

    /// Najlepsze dopasowanie dla sygnatury CPUID, albo `null`, gdy **żaden** wpis
    /// nie pasuje.
    ///
    /// `null` znaczy „baza nie wie nic o tej sygnaturze” i jest jedyną poprawną
    /// odpowiedzią, gdy nic nie trafiło. Wcześniejsza wersja zwracała wtedy
    /// **pierwszy wpis danego producenta** jako `specificity = 0`, przez co
    /// `quirk_smt_threads` i `codename` pochodziłyby z niepowiązanego modelu —
    /// ten sam błąd co dopasowanie rodzinowe, tylko poziom niżej.
    ///
    /// Wygrywa trafienie o najwyższym `rank()`, przy remisie wyższe `confidence`.
    pub fn matchCpu(self: Hwdb, vendor: ids.CpuVendor, sig: ids.Signature) ?Match {
        const want = VendorId.fromCpu(vendor);
        var best: ?Match = null;
        const n = self.count();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const e = self.entryAt(i) orelse continue;
            if (e.vendor != want) continue;
            // Wpis, który nie pasuje, **nie** tworzy żadnego trafienia. Wcześniej
            // każdy wpis o zgodnej rodzinie dostawał „trafienie rodzinne” i jego
            // `codename` trafiał do wyniku.
            const level = e.hitLevel(sig) orelse continue;
            const cand = Match{ .entry = e, .exact_stepping = level == .single_model, .level = level };
            if (best == null or better(cand, best.?)) best = cand;
        }
        return best;
    }

    fn better(candidate: Match, current: Match) bool {
        if (candidate.level.rank() != current.level.rank())
            return candidate.level.rank() > current.level.rank();
        return @intFromEnum(candidate.entry.confidence) > @intFromEnum(current.entry.confidence);
    }
};

fn readU16(b: []const u8, at: usize) u16 {
    return @as(u16, b[at]) | (@as(u16, b[at + 1]) << 8);
}

fn readU32(b: []const u8, at: usize) u32 {
    var v: u32 = 0;
    inline for (0..4) |i| v |= @as(u32, b[at + i]) << (i * 8);
    return v;
}

fn readU64(b: []const u8, at: usize) u64 {
    var v: u64 = 0;
    inline for (0..8) |i| v |= @as(u64, b[at + i]) << (i * 8);
    return v;
}

const testing = std.testing;

test "hwdb: uszkodzony plik jest odrzucany, nie czytany na wiarę" {
    try testing.expectError(error.Truncated, Hwdb.init("krotki"));
    var buf: [header_size]u8 = undefined;
    @memset(&buf, 0);
    try testing.expectError(error.BadMagic, Hwdb.init(&buf));
    @memcpy(buf[0..8], magic);
    try testing.expectError(error.UnsupportedFormat, Hwdb.init(&buf));
}

test "hwdb: VendorId mapuje się obie strony" {
    try testing.expectEqual(VendorId.intel, VendorId.fromCpu(.intel));
    try testing.expectEqual(ids.CpuVendor.amd, VendorId.amd.toCpu());
    try testing.expectEqual(VendorId.amd, VendorId.fromSlice("amd").?);
    try testing.expectEqual(@as(?VendorId, null), VendorId.fromSlice("nvidia"));
}

test "hwdb: dopasowanie po rodzinie, modelu i stepppingu" {
    const e = Entry{
        .vendor = .amd,
        .ext_family = 0x0A,
        .family_field = 0x0F,
        .model_min = 0x10,
        .model_max = 0x1F,
        .stepping_min = 0,
        .stepping_max = 1,
    };
    // Family 19h model 11h stepping 0 -> trafienie ze steppingiem.
    const sig = ids.Signature.fromEax(0x00A10F10);
    try testing.expect(e.matchesFamilyModel(sig));
    try testing.expect(e.matchesStepping(sig));
    // Ten sam model, ale stepping 2 poza zakresem.
    const sig2 = ids.Signature.fromEax(0x00A10F12);
    try testing.expect(e.matchesFamilyModel(sig2));
    try testing.expect(!e.matchesStepping(sig2));
    // Model spoza zakresu.
    const sig3 = ids.Signature.fromEax(0x00A00F10);
    try testing.expect(!e.matchesFamilyModel(sig3));
}
