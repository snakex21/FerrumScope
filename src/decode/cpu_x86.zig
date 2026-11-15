//! Dekoder CPU x86: `RawCpuInfo` + hardware database -> `CpuInfo`.
//!
//! To jest jedyne miejsce, które łączy surowe dane z bazą. Nie wykonuje I/O,
//! nie zna platformy — dostaje gotową `RawCpuInfo` i gotowy `Hwdb`.
//!
//! Hierarchia nazwy (od najlepszego źródła):
//!
//! 1. wpis bazy pasujący dokładnie + wiarygodny brand string -> brand string,
//!    a z bazy dokładamy mikroarchitekturę i kodową nazwę;
//! 2. brand string bez wpisu w bazie -> brand string, `match = vendor_only`;
//! 3. wpis bazy bez brand stringu -> nazwa z bazy (`hwdb_pattern`);
//! 4. producent znany, model nie -> nazwa generowana „AMD (Family 23 Model 113)";
//! 5. nic nie wiemy -> `hex_id`, ale **nadal** wypisujemy surowe pola.
//!
//! Cel ostatniego punktu: `ferrumscope` nigdy nie pokazuje pustego pola.

const std = @import("std");
const raw = @import("../core/raw.zig");
const ids = @import("../core/ids.zig");
const model = @import("../core/model.zig");
const hwdb = @import("../db/hwdb.zig");
const cpuid = @import("../arch/x86/cpuid.zig");

pub const DecodeOutcome = enum {
    /// Baza dopasowała wpis ze steppingiem.
    matched_exact,
    /// Baza dopasowała wpis, ale stepping jest poza zakresem.
    matched_family_model,
    /// Dopasowanie **wzorcem**: wpis obejmuje zakres wielu modeli rodziny.
    matched_pattern,
    /// Dopasowanie wyłącznie na **jawny** wpis `family_generic` — opisuje całą
    /// rodzinę, więc nie mówi nic o tym konkretnym układzie.
    matched_family,
    /// Znamy producenta, nie znamy generacji.
    matched_vendor,
    /// Baza nie wie; nazwa pochodzi z brand stringu lub jest generowana.
    from_brand,
    generated,
    unknown,

    pub fn toSlice(self: DecodeOutcome) []const u8 {
        return @tagName(self);
    }
};

/// Dekoduje surowe dane do znormalizowanego modelu. Bez alokacji.
pub fn decode(in: *const raw.RawCpuInfo, db: hwdb.Hwdb, out: *model.CpuInfo) DecodeOutcome {
    out.* = .{};
    if (!in.cpuid_available) {
        out.vendor = in.vendor;
        out.display = .hex_id;
        out.match = .unknown;
        return .unknown;
    }

    out.available = true;
    out.arch = in.arch;
    out.vendor = in.vendor;
    out.signature = in.signature;
    out.signature_source = .cpuid;
    out.display_family = in.signature.displayFamily();
    out.display_model = in.signature.displayModel();
    out.stepping = in.signature.stepping();
    out.brand = in.brand;
    out.brand_valid = in.brand_valid;
    out.features = in.features;

    // --- cache ---------------------------------------------------------------
    for (in.caches.slice()) |c| {
        out.addCache(.{
            .level = c.level,
            .kind = switch (c.cache_type) {
                1 => .data,
                2 => .instruction,
                3 => .unified,
                else => .unified,
            },
            .size_bytes = c.size_bytes,
            .line_size = c.line_size,
            .associativity = c.ways,
            .sets = c.sets,
            .sharing_threads = c.sharing_threads,
            .sharing_known = c.sharing_known,
            .instance_count = c.instance_count,
            .domain = c.domain,
            .shared = c.shared,
            .sharing_mask = c.sharing_mask,
        });
    }

    // --- dopasowanie do bazy ------------------------------------------------
    // Robimy to PRZED topologią, bo baza może dostarczyć wiarygodną szerokość
    // SMT rodziny — potrzebną wtedy, gdy CPUID takiej wartości nie daje.
    var best: ?hwdb.Match = null;
    if (db.count() > 0) best = db.matchCpu(in.vendor, in.signature);
    // Quirks (w tym `smt_threads`) stosujemy **tylko** przy trafieniu na konkretny
    // model. Wpis `family_generic` opisuje rodzinę, a `smt_threads` jest własnością
    // wariantu — wzięcie go z wpisu ogólnego dałoby szerokość SMT z bazy z jawnym
    // `topology_source = hwdb`, czyli liczbę wyglądającą na pomiar.
    const db_smt: u8 = if (best) |m|
        (if (hwdb.canUseQuirks(m)) m.entry.quirkFlags().smt_threads else 0)
    else
        0;
    // Pomiar per-CPU liczymy **raz** i przekazujemy do `decodeTopology`.
    // `CpuInfo` przechowuje tylko gotowe, znormalizowane wartości — nie trzymamy
    // w nim surowej topologii, bo model ma opisywać CPU, a nie etapy pośrednie.
    const hw_topo = cpuid.topologyFromPerCpu(&in.per_cpu, in.topology.logical_from_leaf1);

    // --- topologia -----------------------------------------------------------
    decodeTopology(in, out, db_smt, hw_topo);

    if (best) |m| {
        // Źródło nazw zależy od **poziomu trafienia**, nie od jednego globalnego
        // „hwdb". Wpis dopasowany wzorcem na zakresie modeli jest interpretacją
        // wzorca, a `family_generic` mówi wprost, że nazwa dotyczy rodziny, a nie
        // tego układu. Użytkownik musi widzieć tę różnicę w polu źródłowym.
        const name_source = sourceForLevel(m.level);
        out.microarchitecture = optionalText(db, m.entry.uarch);
        out.microarchitecture_source = if (out.microarchitecture == null) .none else name_source;
        out.codename = optionalText(db, m.entry.codename);
        out.codename_source = if (out.codename == null) .none else name_source;
        out.silicon_family = optionalText(db, m.entry.silicon_family);
        out.product_family = optionalText(db, m.entry.product_family);
        out.cache_variant = optionalText(db, m.entry.cache_variant);
        // `variant` **nie** pochodzi z dopasowania po modelu: 5800X i 5800X3D
        // mają tę samą sygnaturę CPUID, a różni je wyłącznie brand string.
        // Dlatego wpis bazy nie wypełnia tego pola dla modelu, tylko dla
        // produktu, i to dopiero po korespondencji z brand stringem.
        out.variant = optionalText(db, m.entry.variant);
        out.revision = optionalText(db, m.entry.revision);
        out.db_source = optionalText(db, m.entry.source);
        out.db_source_url = optionalText(db, m.entry.source_url);

        // Quirks tylko przy trafieniu na konkretny model — patrz `canUseQuirks`.
        if (hwdb.canUseQuirks(m)) {
            const q = m.entry.quirkFlags();
            if (q.no_brand_string) out.brand_valid = false;
            if (q.htt_unreliable and in.topology.leaf_b_valid) {
                out.threads_logical = in.topology.logical_from_leaf_b;
            }
            if (q.hybrid_cores) {
                // Alder Lake: część rdzeni ma SMT wyłączone, więc dzielenie
                // threads / smt_width dałoby fałszywą liczbę. Wolimy nie podawać
                // liczby niż podać błędną.
                //
                // Ten quirk **nie może** kasować wyniku pomiaru. Powstał, gdy pomiaru
                // per-CPU jeszcze nie było, i od tamtej pory kasował wszystko —
                // także liczbę rdzeni **zmierzoną** z liścia 0x1F, gdzie widać
                // osobno, ile jest P-core, a ile E-core. Uznanie wpisu w bazie za
                // ważniejszy niż sprzęt to dokładnie odwrotność podejścia CPU-Z.
                const measured = hw_topo.hardware_complete and hw_topo.physical_from_hardware > 0;
                if (!measured) {
                    out.cores_physical = 0;
                    out.smt = false;
                }
            }
        }
    }

    // --- wybór nazwy ---------------------------------------------------------
    //
    // Ustawienie trzech pól naraz (`display`, `match`, `display_name_source`)
    // idzie przez jeden helper. Rozdzielenie ich na osobne przypisania w każdej
    // gałęzi jest dokładnie tym, przez co pola potrafią się rozjechać: nazwa
    // z brand stringu przy `match = .unknown` jest sytuacją poprawną, ale
    // zapisaną ręcznie w czterech miejscach.
    const finish = struct {
        fn set(
            o: *model.CpuInfo,
            d: model.DisplaySource,
            q: model.MatchQuality,
            outcome: DecodeOutcome,
        ) DecodeOutcome {
            o.display = d;
            o.match = q;
            o.display_name_source = switch (d) {
                .brand_string => .cpuid,
                .hwdb, .hwdb_pattern => .hwdb,
                .generated => .generated,
                .hex_id => .none,
            };
            return outcome;
        }
    }.set;

    const m = best;
    if (m) |match| {
        // --- fakty sygnatury i refinament z brandu (format v3) -----------------
        //
        // Musi być **przed** `return switch` poniżej. Blok po nim był
        // nieosiągalny: wykonywałby się wyłącznie dla `best == null`, a wtedy
        // warunek `if (best != null)` i tak by go wyłączył. Żadne pole
        // identyfikacji nie byłoby wypełnione.
        //
        // Oba kroki działają **wyłącznie** po trafieniu na wpis bazy. Gdy
        // `matchCpu` zwrócił `null`, nie zgadujemy wariantu z brand stringu —
        // heurystyka przejęłaby wtedy rolę odczytu i podsunęłaby nazwę bez
        // pokonania. Dokładnie tego pilnujemy też w walidacji `[[brand_rule]]`.
        applySignatureFacts(db, in.vendor, in.signature, out);
        applyBrandRefinement(db, in.vendor, in.signature, out);

        return switch (match.level) {
            // Wpis **konkretnego modelu** ze steppingiem w zakresie (lub bez
            // ograniczenia). To najwyższa pewność, jaką baza może dać.
            .single_model => finish(
                out,
                if (out.brand_valid) .brand_string else .hwdb,
                .exact,
                .matched_exact,
            ),
            // Wpis obejmujący **zakres modeli**: reguła wzorca, nie wpis
            // urządzenia. Dawniej taki wpis raportowany był jako `exact` — to
            // było zawyżenie: reguła celowo obejmuje wiele modeli.
            .model_range => finish(
                out,
                if (out.brand_valid) .brand_string else .hwdb_pattern,
                .pattern,
                .matched_pattern,
            ),
            // Model trafiony, stepping poza jawnie podanym zakresem: wiemy który
            // układ, nie wiemy która rewizja.
            .no_stepping => finish(
                out,
                if (out.brand_valid) .brand_string else .hwdb_pattern,
                .device,
                .matched_family_model,
            ),
            // **Jawny** wpis `family_generic`. Nazwa dotyczy rodziny, nie tego
            // układu, więc poziom trafienia mówi wprost, że jej nie uzasadniamy.
            // Wcześniej tę gałąź obsługiwał wpis szczegółowy o zgodnej rodzinie —
            // stąd cudze „Merom/Conroe” dla nieznanego modelu rodziny 6.
            .family_only => finish(
                out,
                if (out.brand_valid) .brand_string else .generated,
                .family_generic,
                .matched_family,
            ),
        };
    }

    // Baza nie ma **żadnego** pasującego wpisu. `matchCpu` zwraca tu `null` i nie
    // podstawia wpisu „na siłę" — producent znamy z CPUID, więc `vendor_only`
    // wynika z odczytu, a nie z przypadkowego wpisu bazy.
    if (out.brand_valid) {
        return finish(out, .brand_string, if (in.vendor == .unknown) .unknown else .vendor_only, .from_brand);
    }
    if (in.vendor != .unknown) {
        return finish(out, .generated, .vendor_only, .generated);
    }
    return finish(out, .hex_id, .unknown, .unknown);
}

fn decodeTopology(
    in: *const raw.RawCpuInfo,
    out: *model.CpuInfo,
    db_smt: u8,
    hw: raw.Topology,
) void {
    const t = in.topology;
    const logical: u16 = t.bestLogical();
    out.threads_logical = logical;

    // Priorytet źródeł szerokości SMT:
    //   1. leaf 0x0B — EAX = liczba bitów przesunięcia, threads = 2^EAX;
    //   2. wątki współdzielące L1d z liścia 4 (pole `sharing_known`);
    //   3. HWDB — architektoniczna szerokość SMT rodziny (`smt_threads`);
    //   4. 1 (brak SMT albo brak danych).
    //
    // Liść 0x8000001E (AMD) celowo NIE występuje na tej liście. Opisuje on
    // **bieżący** wątek i bez przypięcia do rdzenia zwraca różne wartości:
    // na Ryzen 7 5800X3D dwa kolejne odczyty dały `eax = 0x02` (ApicId 1)
    // i `eax = 0x0C` (ApicId 6), a `0x0C = 2 × ApicId`. Użycie tego pola
    // dawało wynik zależny od tego, gdzie trafił scheduler: 8 rdzeni albo 0.
    var smt: u16 = 0;
    var source: raw.TopologySource = .unknown;
    // Czy szerokość SMT jest **faktycznie poznana**, a nie tylko domyślnie 1.
    // Bez tego rozróżnienia `logical / 1` wygląda jak pomiar, a jest zgadywaniem:
    // 4 wątki na Core 2 E6600 dałyby „4 rdzenie", choć CPU ma 2.
    var smt_known = false;

    if (hw.smt_from_hardware >= 1 and hw.hardware_complete) {
        // **Priorytet 1**: thread-pinned hardware CPUID. Jedyna metoda, która
        // operuje na komplecie odczytów, a nie na jednym — jedynym, który na
        // AMD opisuje bieżący wątek.
        smt = hw.smt_from_hardware;
        source = .hardware;
        smt_known = true;
    } else if (t.smt_from_leaf_b >= 1) {
        smt = t.smt_from_leaf_b;
        source = .leaf_0x0b;
        smt_known = true;
    } else {
        for (in.caches.slice()) |c| {
            if (c.level == 1 and c.cache_type == 1 and c.sharing_known and c.sharing_threads > 0) {
                smt = @intCast(c.sharing_threads);
                source = .derived_from_cache;
                smt_known = true;
                break;
            }
        }
    }
    if (smt == 0 and db_smt >= 1) {
        smt = db_smt;
        source = .hwdb;
        // Wartość z bazy jest właściwością rodziny, więc **wiemy**, jaka jest
        // szerokość SMT — to nie jest zgadywanie.
        smt_known = true;
    }
    if (smt == 0) smt = 1;

    out.threads_per_core = smt;
    // Na hybrydzie nie ma **jednej** szerokości SMT, więc `threads_per_core = 0`
    // („nieznana, bo zmienna") i prawdziwą wartość niesie `smt_max`.
    // Podanie `2` wyglądałoby jak jednolite SMT2, a to fałsz.
    if (hw.hybrid) {
        out.threads_per_core = 0;
        out.smt = hw.smt_from_hardware > 1;
    } else {
        out.smt = smt > 1;
    }
    out.smt_max = hw.smt_from_hardware;
    out.topology_source = source;
    // Liczba pakietów z pomiaru, gdy jest. Wcześniej było tu sztywno `1`:
    // Intel podaje liczbę gniazd bitami x2APIC powyżej najwyższego shiftu, a
    // `NodeId` (AMD) o gniazdach nie mówi nic. Domyślenie do 1 przy
    // niepewnym pomiarze to zgadywanie wyglądające jak pomiar.
    out.packages = if (hw.hardware_complete and hw.packages_measured > 0)
        hw.packages_measured
    else
        @as(u16, if (logical > 0) 1 else 0);
    if (t.die_id_valid) out.dies = @as(u16, t.die_id_amd) + 1;

    // Klasy rdzeni wnosi **wyłącznie** pomiar (`EAX[31:16]` liścia 0x1F).
    // Bez pomiaru lista jest pusta, a `core_type = unknown` — nigdy nie zgadujemy
    // typu z nazwy marketingowej ani z liczby rdzeni.
    out.hybrid = hw.hybrid;
    out.heterogeneous = hw.heterogeneous;
    out.nodes_measured = hw.nodes_measured;
    out.core_class_len = 0;
    var ci: u8 = 0;
    while (ci < hw.class_len and ci < out.core_class_buf.len) : (ci += 1) {
        out.core_class_buf[ci] = .{
            .value = hw.class_values[ci],
            .cores = hw.class_counts[ci],
            .name = model.CoreClass.nameForValue(hw.class_values[ci]),
        };
        out.core_class_len += 1;
    }
    out.p_cores = hw.p_cores;
    out.e_cores = hw.e_cores;
    // `core_type` opisuje **jedną** klasę. Dwie klasy albo brak raportowania to
    // `unknown`. Poprzednia wersja patrzyła na `hybrid`, czyli na nierówność
    // liczby wątków, i z tego wnioskowała o klasie — zależność bez pokrycia:
    // CPU z jedną klasą i wyłączonym SMT na części rdzeni też ma `hybrid`.
    out.core_type = blk: {
        if (out.core_class_len != 1) break :blk .unknown;
        break :blk switch (out.core_class_buf[0].value) {
            0x40 => .performance,
            0x20 => .efficiency,
            else => .unknown,
        };
    };

    // --- Priorytet 1: pomiar thread-pinned hardware CPUID --------------------
    // Liczba rdzeni stąd jest **zmierzona**: `measure()` policzył różne
    // identyfikatory rdzeni i sprawdził, że suma wątków na rdzenie zgadza się
    // z liczbą logicznych procesorów zadeklarowaną przez system.
    //
    // Dlatego **nie** wymagamy tu `logical == physical * smt`. Na CPU hybrydowym
    // (8 P-core po 2 wątki + 8 E-core po 1) mamy 24 wątki na 16 rdzeniach,
    // więc `24 == 16 * 2` jest fałszywe — i stary warunek oddawał hybrydowi
    // `0` rdzeni. Wartość z pomiaru jest wiarygodna bez ilorazu.
    if (hw.hardware_complete and hw.physical_from_hardware > 0) {
        out.cores_physical = hw.physical_from_hardware;
        out.topology_confident = true;
        if (t.die_id_valid) out.dies = @as(u16, t.die_id_amd) + 1;
        return;
    }

    // --- Pozostałe źródła: obliczamy z ilorazu -------------------------------
    // Dzielimy **tylko** gdy szerokość SMT jest faktycznie znana. Przy braku
    // pomiaru i braku wiedzy o SMT liczba rdzeni fizycznych jest `unknown`,
    // a nie `logical / 1` — inaczej 4 wątki wyglądałyby jak 4 rdzenie.
    var physical: u16 = 0;
    if (smt_known and logical > 0 and smt > 0 and logical >= smt and logical % smt == 0) {
        physical = logical / smt;
    }

    // Niezmiennik: logical == physical * threads_per_core oraz physical >= 1.
    // Gdy się nie zgadza (np. Alder Lake, gdzie część rdzeni ma SMT wyłączone),
    // **nie podajemy** liczby rdzeni, zamiast podać błędną.
    const confident = physical >= 1 and physical * smt == logical;
    out.cores_physical = if (confident) physical else 0;
    out.topology_confident = confident;
}

fn optionalText(db: hwdb.Hwdb, s: hwdb.Str) ?[]const u8 {
    if (s.isEmpty()) return null;
    const t = db.text(s);
    return if (t.len == 0) null else t;
}

/// Mapowanie poziomu trafienia na `FieldSource` dla pól nazewniczych.
///
/// Osobne wartości zamiast jednego „hwdb”, bo nazwa z wzorca i nazwa z wpisu
/// rodzinnego mają **różną wartość poznawczą** — a dotąd zapisywałyśmy to samo.
fn sourceForLevel(level: hwdb.HitLevel) model.FieldSource {
    return switch (level) {
        .single_model => .hwdb_exact,
        .model_range, .no_stepping => .hwdb_pattern,
        .family_only => .hwdb_family,
    };
}

fn toModelConfidence(c: hwdb.Confidence) model.Confidence {
    return switch (c) {
        .low => .low,
        .medium => .medium,
        .high => .high,
    };
}

fn toModelSourceType(s: hwdb.SourceType) model.ProvenanceType {
    return switch (s) {
        .none => .none,
        .vendor_doc => .vendor_doc,
        .vendor_doc_adjacent => .vendor_doc_adjacent,
        .derived => .derived,
        .reference_observation => .reference_observation,
        .community => .community,
    };
}

fn factProvenance(db: hwdb.Hwdb, f: hwdb.Fact) model.Provenance {
    return .{
        .source = optionalText(db, f.source),
        .source_url = optionalText(db, f.source_url),
        .source_type = toModelSourceType(f.source_type),
        .confidence = toModelConfidence(f.confidence),
        .notes = optionalText(db, f.notes),
    };
}

/// Pole źródłowe faktu. Obserwacja referencyjna (np. porównanie z CPU-Z) to
/// **nie** dokumentacja — użytkownik ma widzieć tę różnicę w polu, a nie tylko
/// dopiero w provenance.
fn factSource(t: hwdb.SourceType) model.FieldSource {
    return switch (t) {
        .reference_observation => .empirical,
        else => .hwdb_exact,
    };
}

/// Nakłada fakty z bazy: `stepping_name`, `socket_name`, `package_contacts`.
///
/// Każde pole ma **własny** zakres: `Vermeer-B2` dotyczy konkretnego stepppingu, a
/// `AM4` — całego modelu. Stąd osobne lookupy w `Hwdb` zamiast jednego
/// „pierwszego dopasowania”, które ukryłoby gniazdo za węższym wpisem.
///
/// Surowe `stepping` z CPUID pozostaje nietknięte — `stepping_name` jest
/// **nazwą**, czyli interpretacją, i dlatego niesie własne źródło i provenance.
fn applySignatureFacts(db: hwdb.Hwdb, vendor: ids.CpuVendor, sig: ids.Signature, out: *model.CpuInfo) void {
    const v = hwdb.VendorId.fromCpu(vendor);

    if (db.steppingNameFact(v, sig)) |f| {
        if (optionalText(db, f.stepping_name)) |name| {
            out.stepping_name = name;
            out.stepping_name_source = factSource(f.source_type);
            out.stepping_name_provenance = factProvenance(db, f);
        }
    }

    if (db.socketFact(v, sig)) |f| {
        if (optionalText(db, f.socket_name)) |name| {
            out.socket_name = name;
            out.socket_source = factSource(f.source_type);
            out.socket_confidence = toModelConfidence(f.confidence);
            out.socket_provenance = factProvenance(db, f);
        }
    }

    // `0` znaczy „nie wiemy" i zostaje `unknown` — nigdy nie zgadujemy liczby
    // kontaktów na podstawie tego, że pokazał ją narzędź referencyjne.
    if (db.packageContactsFact(v, sig)) |f| {
        out.package_contacts = f.package_contacts;
    }
}

/// Normalizuje brand string do porównywania: scala ciągi białych znaków i NULi
/// do pojedynczej spacji, obcinając brzegi.
///
/// CPUID daje 48 bajtów dopełnionych zerami/spacjami, więc surowy napis ma długi
/// ogon. Reguły w bazie zapisujemy w postaci znormalizowanej — inaczej trafienie
/// zależałoby od ilości paddingu, a nie od treści brand stringu.
fn normalizeBrand(raw_brand: []const u8, buf: []u8) []const u8 {
    var n: usize = 0;
    var pending_space = false;
    for (raw_brand) |c| {
        if (c == ' ' or c == '\t' or c == 0) {
            pending_space = n > 0;
            continue;
        }
        if (pending_space) {
            if (n >= buf.len) break;
            buf[n] = ' ';
            n += 1;
            pending_space = false;
        }
        if (n >= buf.len) break;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

/// Opcjonalny refinament z brand stringu — **wyłącznie** pola, których CPUID nie
/// niesie (`product_name`, `variant`, `cache_variant`).
///
/// Świadomie **nie** dotykamy `vendor`, `family`, `model`, `stepping`, topologii
/// ani cache zmierzonego ze sprzętu: brand string jest interpretacją i ma prawo
/// wzbogacić identity, nie je przepisywać.
///
/// Reguły są przefiltrowane w bazie (`Hwdb.brandRulesFor`) po vendorze i zakresie
/// modelu, więc wzorzec spoza zakresu nie trafi tu nawet przy pomyłce w kodzie.
fn applyBrandRefinement(db: hwdb.Hwdb, vendor: ids.CpuVendor, sig: ids.Signature, out: *model.CpuInfo) void {
    if (!out.brand_valid) return;
    var buf: [128]u8 = undefined;
    const brand = normalizeBrand(out.brandSlice(), &buf);
    if (brand.len == 0) return;

    var rules: [16]hwdb.BrandRule = undefined;
    const n = db.brandRulesFor(hwdb.VendorId.fromCpu(vendor), sig, &rules);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const r = rules[i];
        if (!r.matchesBrand(brand, db.text(r.brand_pattern))) continue;

        // Wpis bazy ma pierwszeństwo: jest związany z sygnaturą, brand tylko
        // dopełnia. Gdy model już podał `variant`, brand go **nie** nadpisuje.
        if (out.variant == null) {
            if (optionalText(db, r.variant)) |v| {
                out.variant = v;
                out.variant_source = .brand_derived;
                out.variant_provenance = .{
                    .source = optionalText(db, r.source),
                    .source_url = optionalText(db, r.source_url),
                    .source_type = toModelSourceType(r.source_type),
                    .confidence = toModelConfidence(r.confidence),
                    .notes = optionalText(db, r.notes),
                };
            }
        }
        if (out.product_name == null) {
            if (optionalText(db, r.product_name)) |p| {
                out.product_name = p;
                out.product_name_source = .brand_derived;
            }
        }
        if (out.cache_variant == null) {
            if (optionalText(db, r.cache_variant)) |c| {
                out.cache_variant = c;
                out.cache_variant_source = .brand_derived;
            }
        }
        // Zawężenie codename: **tylko** reguła z niezależnym provenance.
        // Obserwacja referencyjna nie wystarcza — patrz `canNarrowCodename`.
        // `codename_refined` jest osobnym polem, nie nadpisaniem `codename`,
        // żeby użytkownik widział oba poziomy wraz ze źródłami.
        if (r.canNarrowCodename()) {
            if (optionalText(db, r.refined_codename)) |cn| {
                out.codename_refined = cn;
                out.codename_refined_source = .brand_derived;
                out.codename_refined_provenance = .{
                    .source = optionalText(db, r.source),
                    .source_url = optionalText(db, r.source_url),
                    .source_type = toModelSourceType(r.source_type),
                    .confidence = toModelConfidence(r.confidence),
                    .notes = optionalText(db, r.notes),
                };
            }
        }
        // Jedna reguła na SKU. Kolejne dopasowania byłyby zgadywaniem kolejności
        // a nie faktem, a reguły o różnych wzorcach i tak walidacja odrzuca.
        break;
    }
}

const testing = std.testing;

/// Wpis testowy podany **tekstem**. `hwdb.Entry` przechowuje offsety w puli
/// napisów, co w teście byłoby bez sensu — tutaj chcemy pisać czytelnie.
const TestEntry = struct {
    vendor: hwdb.VendorId = .unknown,
    ext_family: u8 = 0,
    family_field: u8 = 0,
    model_min: u8 = 0,
    model_max: u8 = 0,
    stepping_min: u8 = 0,
    stepping_max: u8 = 0xFF,
    uarch: []const u8 = "",
    codename: []const u8 = "",
    revision: []const u8 = "",
    source: []const u8 = "",
    source_url: []const u8 = "",
    confidence: hwdb.Confidence = .low,
    quirks: u32 = 0,
    /// Wpis ogólny dla rodziny. Domyślnie false, bo testy dekodera celowo
    /// budują **szczegółowe** wpisy — dokładnie te, które nie mogą być
    /// fallbackem rodzinnym.
    family_generic: bool = false,
};

/// Buduje poprawną bazę z jednym wpisem, licząc sumę kontrolną — dzięki temu
/// test dekodera sprawdza dokładnie tę ścieżkę wczytywania, co program.
fn buildTestDb(entries: []const TestEntry) ![]u8 {
    // String pool: uzbieramy napisy i zapamiętujemy offsety.
    var pool: std.ArrayList(u8) = .empty;
    defer pool.deinit(testing.allocator);
    var resolved: [hwdb_test_max]hwdb.Entry = undefined;
    var count: usize = 0;
    for (entries, 0..) |e, i| {
        resolved[i] = .{
            .vendor = e.vendor,
            .ext_family = e.ext_family,
            .family_field = e.family_field,
            .model_min = e.model_min,
            .model_max = e.model_max,
            .stepping_min = e.stepping_min,
            .stepping_max = e.stepping_max,
            .confidence = e.confidence,
            .quirks = e.quirks,
            .family_generic = e.family_generic,
            .uarch = try intern(testing.allocator, &pool, e.uarch),
            .codename = try intern(testing.allocator, &pool, e.codename),
            .revision = try intern(testing.allocator, &pool, e.revision),
            .source = try intern(testing.allocator, &pool, e.source),
            .source_url = try intern(testing.allocator, &pool, e.source_url),
        };
        count += 1;
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try buf.appendNTimes(testing.allocator, 0, hwdb.header_size);
    @memset(buf.items, 0);
    @memcpy(buf.items[0..8], hwdb.magic);
    putU16(buf.items, 8, hwdb.format_version);
    putU16(buf.items, 10, hwdb.schema_version);
    // Pola nagłówka wymagane przez walidację: minimalna wersja czytelnika,
    // wymagane funkcje i długość payloadu. Bez nich `init` odrzuci nawet bazę
    // zbudowaną przez test — co jest dokładnie sygnałem, że walidacja działa.
    putU16(buf.items, 12, hwdb.minimum_reader_version);
    putU32(buf.items, 16, 1);
    putU64(buf.items, 20, 0);
    putU32(buf.items, 24, hwdb.FeatureFlags.supported);
    putU32(buf.items, 28, @intCast(pool.items.len));
    putU32(buf.items, 32, @intCast(count));
    putU32(buf.items, 68, @intCast(pool.items.len + count * hwdb.entry_size));
    try buf.appendSlice(testing.allocator, pool.items);
    for (resolved[0..count]) |e| {
        var rec: [hwdb.entry_size]u8 = @splat(0);
        rec[0] = @intFromEnum(e.vendor);
        rec[1] = e.ext_family;
        rec[2] = e.family_field;
        rec[3] = e.model_min;
        rec[4] = e.model_max;
        rec[5] = e.stepping_min;
        rec[6] = e.stepping_max;
        rec[7] = @intFromEnum(e.confidence);
        putU16(&rec, 8, e.uarch.off);
        putU16(&rec, 10, e.uarch.len);
        putU16(&rec, 12, e.codename.off);
        putU16(&rec, 14, e.codename.len);
        putU16(&rec, 16, e.revision.off);
        putU16(&rec, 18, e.revision.len);
        putU16(&rec, 20, e.source.off);
        putU16(&rec, 22, e.source.len);
        putU16(&rec, 24, e.source_url.off);
        putU16(&rec, 26, e.source_url.len);
        // Pola semantyczne: w teście puste, ale pozycje muszą być wyzerowane —
        // rekord jest zerowany przez `@splat(0)`, więc wystarczy ich nie wypełniać.
        rec[44] = if (e.family_generic) 1 else 0;
        putU32(&rec, 48, e.quirks);
        try buf.appendSlice(testing.allocator, &rec);
    }
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(buf.items[hwdb.header_size..]);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    @memcpy(buf.items[36..68], &digest);
    return testing.allocator.dupe(u8, buf.items);
}

const hwdb_test_max = 8;

fn intern(alloc: std.mem.Allocator, pool: *std.ArrayList(u8), text: []const u8) !hwdb.Str {
    if (text.len == 0) return .{};
    const off: u16 = @intCast(pool.items.len);
    try pool.appendSlice(alloc, text);
    return .{ .off = off, .len = @intCast(text.len) };
}

fn putU16(b: []u8, at: usize, v: u16) void {
    b[at] = @truncate(v & 0xFF);
    b[at + 1] = @truncate(v >> 8);
}
fn putU32(b: []u8, at: usize, v: u32) void {
    inline for (0..4) |i| b[at + i] = @truncate(v >> (i * 8));
}
fn putU64(b: []u8, at: usize, v: u64) void {
    inline for (0..8) |i| b[at + i] = @truncate(v >> (i * 8));
}

test "decode: wpis bazy trafia dokładnie i daje mikroarchitekturę" {
    const bytes = try buildTestDb(&[_]TestEntry{.{
        .vendor = .intel,
        .ext_family = 0,
        .family_field = 6,
        .model_min = 0x5E,
        .model_max = 0x5E,
        .stepping_min = 0,
        .stepping_max = 9,
        .uarch = "Skylake",
        .codename = "Skylake",
        .source = "intel-sdm",
        .source_url = "https://example.invalid/intel",
        .confidence = .high,
    }});
    defer testing.allocator.free(bytes);
    const db = try hwdb.Hwdb.init(bytes);

    var r = raw.RawCpuInfo{};
    r.cpuid_available = true;
    r.vendor = .intel;
    r.signature = ids.Signature.fromEax(0x000506E3);
    r.brand = @splat(0);
    const b = "Intel(R) Core(TM) i5-6500 CPU @ 3.20GHz";
    @memcpy(r.brand[0..b.len], b);
    r.computeBrandValidity();

    var out = model.CpuInfo{};
    const outcome = decode(&r, db, &out);
    try testing.expectEqual(DecodeOutcome.matched_exact, outcome);
    try testing.expectEqual(model.MatchQuality.exact, out.match);
    try testing.expectEqualStrings("Skylake", out.microarchitecture.?);
    try testing.expectEqualStrings("Intel(R) Core(TM) i5-6500 CPU @ 3.20GHz", out.brandSlice());
    try testing.expectEqual(@as(u8, 6), out.display_family);
    try testing.expectEqual(@as(u8, 0x5E), out.display_model);
}

test "decode: stepping poza zakresem daje device, nie exact" {
    const bytes = try buildTestDb(&[_]TestEntry{.{
        .vendor = .amd,
        .ext_family = 0x0A,
        .family_field = 0x0F,
        .model_min = 0x10,
        .model_max = 0x1F,
        .stepping_min = 0,
        .stepping_max = 1,
        .uarch = "Zen 4",
        .codename = "Raphael",
        .source = "amd-apm",
        .confidence = .high,
    }});
    defer testing.allocator.free(bytes);
    const db = try hwdb.Hwdb.init(bytes);

    var r = raw.RawCpuInfo{};
    r.cpuid_available = true;
    r.vendor = .amd;
    r.signature = ids.Signature.fromEax(0x00A10F12); // stepping 2, poza zakresem
    r.computeBrandValidity();

    var out = model.CpuInfo{};
    const outcome = decode(&r, db, &out);
    try testing.expectEqual(DecodeOutcome.matched_family_model, outcome);
    try testing.expectEqual(model.MatchQuality.device, out.match);
    try testing.expectEqualStrings("Zen 4", out.microarchitecture.?);
    try testing.expectEqual(@as(u8, 0x19), out.display_family);
}

test "decode: nieznana sygnatura nadal daje użyteczny wynik" {
    const bytes = try buildTestDb(&[_]TestEntry{.{
        .vendor = .amd,
        .ext_family = 0x0A,
        .family_field = 0x0F,
        .model_min = 0x10,
        .model_max = 0x1F,
        .uarch = "Zen 4",
        .source = "amd-apm",
    }});
    defer testing.allocator.free(bytes);
    const db = try hwdb.Hwdb.init(bytes);

    var r = raw.RawCpuInfo{};
    r.cpuid_available = true;
    r.vendor = .amd;
    // Sygnatura 0x00B50F33: family_field=0x0F, ext_family=0x0B -> rodzina
    // 0x0F + 0x0B = 0x1A (26h), model = (0x5<<4)|0x3 = 0x53 — poza zakresami
    // bazy. Baza zna jednak AMD jako producenta.
    r.signature = ids.Signature.fromEax(0x00B50F33); // rodzina 26h, model 0x53
    const b = "AMD Ryzen 9 9950X 16-Core Processor";
    @memcpy(r.brand[0..b.len], b);
    r.computeBrandValidity();

    var out = model.CpuInfo{};
    const outcome = decode(&r, db, &out);
    // DECYZJA KONTRAKTOWA: baza nie zna rodziny 21h, ale zna AMD jako
    // producenta. Kontrakt MatchQuality przewiduje dla tego `.vendor_only`
    // („znamy producenta, nie znamy generacji"), a nie `.unknown`
    // („nie wiemy nic"). Nazwa i tak pochodzi z brand stringu CPUID, a pole
    // `match` mówi wprost, jak dobrze ją uzasadniliśmy. `.unknown` przy
    // działającym brand stringu kłamałoby na brak wiedzy.
    // `outcome` i `match` opisują dwie RÓŻNE osie i nie wolno ich zlewać:
    //   * outcome = skąd wzięła się nazwa  -> tu z brand stringu CPUID,
    //   * match   = jak dobrze baza ją uzasadnia -> tu tylko sam producent.
    // Nazwa jest prawdziwa, ale baza nie zna rodziny 21h, więc `.vendor_only`.
    try testing.expectEqual(DecodeOutcome.from_brand, outcome);
    try testing.expectEqual(model.MatchQuality.vendor_only, out.match);
    try testing.expectEqual(model.DisplaySource.brand_string, out.display);
    try testing.expectEqualStrings("AMD Ryzen 9 9950X 16-Core Processor", out.brandSlice());
    // Rodzina 26h (0x1A), nie 21h — 0x0F + ext_family 0x0B.
    try testing.expectEqual(@as(u8, 0x1A), out.display_family);
    try testing.expect(out.isIdentified());

    var buf: [96]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, out.displayName(&buf), "9950X") != null);
}

test "decode: nieznany producent bez brandu wciąż zwraca pola" {
    const bytes = try buildTestDb(&[_]TestEntry{.{
        .vendor = .intel,
        .ext_family = 0,
        .family_field = 6,
        .model_min = 0x5E,
        .model_max = 0x5E,
        .uarch = "Skylake",
    }});
    defer testing.allocator.free(bytes);
    const db = try hwdb.Hwdb.init(bytes);

    var r = raw.RawCpuInfo{};
    r.cpuid_available = true;
    r.vendor = .unknown;
    // EAX 0x00010FA2: family_field=0x0F, ext_family=0 -> rodzina 15;
    // ext_model=0x1, model_field=0xA -> model 0x1A (reguła SDM dla 0x0F).
    r.signature = ids.Signature.fromEax(0x00010FA2);
    r.computeBrandValidity(); // brand pusty -> niewazny

    var out = model.CpuInfo{};
    const outcome = decode(&r, db, &out);
    try testing.expectEqual(DecodeOutcome.unknown, outcome);
    try testing.expectEqual(model.MatchQuality.unknown, out.match);
    try testing.expectEqual(@as(u8, 15), out.display_family);
    try testing.expectEqual(@as(u8, 0x1A), out.display_model);

    var buf: [96]u8 = undefined;
    const name = out.displayName(&buf);
    try testing.expect(name.len > 0);
    try testing.expect(std.mem.indexOf(u8, name, "Family 15") != null);
}

test "decode: quirk no_brand_string odrzuca brand i bierze nazwę z bazy" {
    var q: hwdb.Quirk = .{};
    q.no_brand_string = true;
    const bytes = try buildTestDb(&[_]TestEntry{.{
        .vendor = .intel,
        .ext_family = 0,
        .family_field = 6,
        .model_min = 0x0F,
        .model_max = 0x0F,
        .stepping_min = 0,
        .stepping_max = 15,
        .uarch = "Conroe",
        .codename = "Conroe",
        .quirks = @bitCast(q),
        .source = "intel-sdm",
    }});
    defer testing.allocator.free(bytes);
    const db = try hwdb.Hwdb.init(bytes);

    var r = raw.RawCpuInfo{};
    r.cpuid_available = true;
    r.vendor = .intel;
    // Family 6, model 0x0F, stepping 2 — sygnatura Core 2 (Conroe).
    r.signature = ids.Signature.fromEax(0x000006F2);
    const b = "Intel(R) Core(TM)2 Duo CPU";
    @memcpy(r.brand[0..b.len], b);
    r.computeBrandValidity();
    try testing.expect(r.brand_valid);

    var out = model.CpuInfo{};
    const outcome = decode(&r, db, &out);
    try testing.expectEqual(DecodeOutcome.matched_exact, outcome);
    try testing.expect(!out.brand_valid); // quirk zdjął wiarygodność brandu
    try testing.expectEqual(model.DisplaySource.hwdb, out.display);
    try testing.expectEqualStrings("Conroe", out.microarchitecture.?);
}

test "decode: hybrid cores nie podaje błędnej liczby rdzeni" {
    var q: hwdb.Quirk = .{};
    q.hybrid_cores = true;
    const bytes = try buildTestDb(&[_]TestEntry{.{
        .vendor = .intel,
        .ext_family = 0,
        .family_field = 6,
        .model_min = 0x97,
        .model_max = 0x9A,
        .stepping_min = 0,
        .stepping_max = 15,
        .uarch = "Alder Lake",
        .quirks = @bitCast(q),
    }});
    defer testing.allocator.free(bytes);
    const db = try hwdb.Hwdb.init(bytes);

    var r = raw.RawCpuInfo{};
    r.cpuid_available = true;
    r.vendor = .intel;
    r.signature = ids.Signature.fromEax(0x00090672);
    r.topology = .{ .logical_from_leaf1 = 20, .leaf_b_valid = true, .logical_from_leaf_b = 20 };
    r.computeBrandValidity();

    var out = model.CpuInfo{};
    _ = decode(&r, db, &out);
    try testing.expectEqual(@as(u16, 0), out.cores_physical);
    try testing.expect(!out.smt);
    try testing.expectEqual(@as(u16, 20), out.threads_logical);
}
