//! Wspólna warstwa prezentacji CLI i GUI.
//!
//! Wydzielone z `main.zig` bez zmiany logiki: oba programy muszą mówić **to
//! samo** o tym samym stanie. Gdyby GUI miało własne „powody niedostępności",
//! CLI i okno mogłyby się różnić w diagnozie tej samej maszyny.
//!
//! Tu jest tylko tekst i backend bez dostępu do MSR. Żadnej logiki odczytu.

const std = @import("std");
const msr = @import("telemetry/msr.zig");
const metrics = @import("telemetry/metrics.zig");
const catalog = @import("telemetry/catalog.zig");
const raw = @import("core/raw.zig");
const model = @import("core/model.zig");

pub const version = "0.2.0-dev";

/// Nominalna częstotliwość używana do skalowania APERF/MPERF.
///
/// APERF/MPERF dają **stosunek** cykli, więc bez skali w Hz nie ma czego
/// skalować. Przyjmujemy typową wartość i **oznaczamy ją** jako założenie —
/// to nie jest pomiar procesora użytkownika. CLI i GUI muszą używać tej samej.
pub const nominal_hz_assumed: u64 = 3_800_000_000;

pub fn explainDisplay(d: model.DisplaySource) []const u8 {
    return switch (d) {
        .brand_string => "brand string z CPUID (0x80000002..4)",
        .hwdb => "wpis HWDB (dokładne trafienie)",
        .hwdb_pattern => "wpis HWDB (dopasowanie wzorcem rodziny)",
        .generated => "wygenerowana z sygnatury CPUID",
        .hex_id => "identyfikator CPUID — brak lepszej informacji",
    };
}

/// Backend dla platformy, na której **nie ma** dostępu do MSR.
///
/// To nie jest „tryb testowy". Deklaruje **zero** zdolności i zwraca
/// `permission_denied`, a implementuje dokładnie ten sam interfejs co sterownik
/// i backend sztuczny. Dzięki temu `sensors` na Windows bez sterownika wypisuje
/// `unavailable` z powodem, zamiast zmyślonej wartości — a dekoder nie musi
/// wiedzieć, że sprzętu nie ma.
pub const NoMsrBackend = struct {
    var storage: NoMsrBackend = .{};

    fn vtable() *const msr.Backend.VTable {
        const impl = struct {
            fn read(_: *anyopaque, _: u16, _: u32) msr.MsrRead {
                return msr.MsrRead.fail(.permission_denied);
            }
            fn count(_: *anyopaque) u16 {
                return 0;
            }
            fn caps(_: *anyopaque) msr.CapabilitySet {
                return .{};
            }
            fn now(_: *anyopaque) u64 {
                return 0;
            }
            fn name(_: *anyopaque) []const u8 {
                return "brak dostępu do MSR (sterownik niezaładowany lub nie zaimplementowany)";
            }
        };
        return &struct {
            const v: msr.Backend.VTable = .{
                .readMsr = impl.read,
                .onlineCpuCount = impl.count,
                .capabilities = impl.caps,
                .monotonicNanos = impl.now,
                .sourceName = impl.name,
            };
        }.v;
    }

    pub fn create() msr.Backend {
        return .{ .vtable = vtable(), .ctx = @ptrCast(&storage) };
    }
};

/// Powód braku wartości w próbce: jej własny `detail`, a gdy pusty — powód
/// z katalogu. Kolejność jest celowa: `detail` mówi, co konkretnie nie
/// wyszło („pierwsza próbka"), i jest bardziej użyteczny niż ogólny stan katalogu.
pub fn sampleReason(s: metrics.Sample) []const u8 {
    if (s.detail.len != 0) return s.detail;
    return "brak wartości w próbce";
}

pub fn findSample(list: []const metrics.Sample, id: []const u8) ?metrics.Sample {
    for (list) |s| {
        if (std.mem.eql(u8, s.metric_id, id)) return s;
    }
    return null;
}

/// Powód niedostępności — **korzeń**, a nie pierwsza brakująca zdolność.
///
/// Gdy backend nie umie czytać żadnego MSR, mówimy o tym jednym zdaniu.
/// „APERF/MPERF unavailable" sugerowałoby, że inne rejestry działają, a to
/// byłoby kłamstwo diagnostyczne: nie działają żadne.
pub fn reasonFor(m: catalog.Metric, caps: msr.CapabilitySet) []const u8 {
    if (caps.has(.msr_read)) return m.unavailableReason(caps) orelse "brak wymaganych zdolności";
    if (m.descriptor.source == .platform) return catalog.capabilityName(.platform_utilization);
    return catalog.capabilityName(.msr_read);
}

/// Lista zdolności backendu po przecinku.
///
/// Wypisujemy **nazwy**, nie tylko liczbę. Użytkownik pytający „dlaczego nie
/// widzę temperatury" musi zobaczyć, czego brakuje — sama liczba „4 z 6" nic
/// nie mówi.
pub fn capsSummary(caps: msr.CapabilitySet, buf: []u8) []const u8 {
    if (caps.bits == 0) return "brak";
    var w: usize = 0;
    inline for (@typeInfo(msr.Capability).@"enum".fields) |fld| {
        const c: msr.Capability = @enumFromInt(fld.value);
        // `inline for` **nie przyjmuje** `continue` — kontrola przepływu w pętli
        // inline musi być comptime. „Wypisz albo pomiń" realizujemy więc warunkiem.
        if (caps.has(c)) {
            if (w > 0 and w + 2 <= buf.len) {
                buf[w] = ',';
                buf[w + 1] = ' ';
                w += 2;
            }
            const name = @tagName(c);
            const n = @min(name.len, buf.len - w);
            @memcpy(buf[w .. w + n], name[0..n]);
            w += n;
        }
    }
    return buf[0..w];
}

pub fn unitLabel(u: metrics.Unit) []const u8 {
    return switch (u) {
        .hertz => "MHz",
        .millicelsius => "°C",
        .millivolt => "mV",
        .microwatt => "W",
        .microjoule => "J",
        .percent => "%",
        .milliampere => "mA",
        .bits_per_second => "bit/s",
        .none => "",
    };
}

/// Zapisuje nazwy **włączonych** cech do bufora podanego przez wywołującego.
///
/// Kolejność jest stała (zależy od deklaracji `raw.Features`), więc wyjście CLI
/// jest deterministyczne. Bez alokacji.
pub fn writeFeatureNames(f: raw.Features, buf: []u8) []const u8 {
    // Zbieramy nazwy, potem sklejamy. Bez `continue` wewnątrz `inline for` —
    // kontrola przepływu w takim bloku jest źródłem błędów kompilacji.
    var names: [32][]const u8 = undefined;
    var count: usize = 0;
    inline for (@typeInfo(raw.Features).@"struct".fields) |field| {
        if (@field(f, field.name) and count < names.len) {
            names[count] = field.name;
            count += 1;
        }
    }

    var pos: usize = 0;
    for (names[0..count], 0..) |name, i| {
        if (i > 0 and pos + 2 <= buf.len) {
            buf[pos] = ',';
            buf[pos + 1] = ' ';
            pos += 2;
        }
        if (pos + name.len > buf.len) break;
        @memcpy(buf[pos..][0..name.len], name);
        pos += name.len;
    }
    return buf[0..pos];
}
