//! Backend replay — realizuje **ten sam kontrakt** co platforma żywa,
//! ale odczytuje dane z pliku capture zamiast ze sprzętu.
//!
//! To jest fundament testów regresyjnych: dekoder, baza i CLI nie widzą różnicy
//! między prawdziwym procesorem a obrazem CPUID z pliku. Dzięki temu każdy
//! test dekodera przechodzi dokładnie tę samą ścieżką, co program produkcyjny.

const std = @import("std");
const backend = @import("backend.zig");
const status = @import("../core/status.zig");
const raw = @import("../core/raw.zig");

/// Stan replay: obraz CPUID odczytany z pliku (albo z pamięci).
pub const Replay = struct {
    image: raw.CpuidImage = .{},
    /// Odczyty per-logical-CPU z pliku capture. Puste dla plików v1 — wtedy
    /// replay **nie deklaruje** `cpuid_per_logical_cpu`, bo dekoder potrzebuje
    /// tych danych, a udawanie ich posiadania dałoby fałszywe
    /// `topology_source = hardware`. Stary plik → stary wynik: to jest
    /// kompatybilność wsteczna, a nie skrót.
    per_cpu: raw.PerCpuImage = .{},
    /// Ścieżka pliku źródłowego — wyłącznie diagnostyka, nigdy do wyniku.
    source: []const u8 = "",

    pub fn init(image: raw.CpuidImage) Replay {
        return .{ .image = image };
    }

    /// Dokłada dane thread-pinned odczytane z pliku capture.
    pub fn withPerCpu(self: Replay, per: raw.PerCpuImage) Replay {
        var copy = self;
        copy.per_cpu = per;
        return copy;
    }

    /// Ustawia granice odczytu, gdy obraz pochodzi z pliku z jawnie
    /// zadeklarowanym zakresem liści.
    pub fn withLimits(self: Replay, max_basic: u32, max_extended: u32) Replay {
        var copy = self;
        copy.image.max_basic = max_basic;
        copy.image.max_extended = max_extended;
        return copy;
    }

    /// Tworzy backend spełniający kontrakt `platform.Backend`.
    pub fn create(self: *Replay) backend.Backend {
        var caps = backend.CapabilitySet{};
        caps.add(.cpuid);
        // Replay świadomie NIE deklaruje `os_info`: plik capture nie zawiera
        // danych systemowych w tym etapie, więc deklaracja byłaby fałszywa.
        // `cpuid_per_logical_cpu` deklarujemy **wyłącznie** wtedy, gdy plik ma
        // sekcję per-CPU. Deklaracja bez danych to kłamstwo: probe wierzyłby, że
        // potrafi, wracałby z pustym skanem, a topologia wyglądałaby na
        // „nie udało się odczytać" zamiast „tego plik nie zawiera".
        if (self.per_cpu.len > 0) {
            caps.add(.cpuid_per_logical_cpu);
            caps.add(.logical_cpu_enumeration);
        }
        return .{
            .name = "replay",
            .caps = caps,
            .ctx = self,
            .cpuid = cpuidRead,
            .cpuid_pinned = if (self.per_cpu.len > 0) cpuidPinned else null,
            .logical_cpu_count = if (self.per_cpu.len > 0) logicalCpuCount else null,
        };
    }
};

/// CPUID z obrazu konkretnego logical procesora.
///
/// Ścieżka jest **ta sama** co na platformie żywej: probe woła `readCpuidOn`
/// przez abstrakcyjny `Backend` i nie wie, że pod spodem jest tablica z pliku
/// zamiast `SetThreadGroupAffinity`. Dzięki temu dekoder nie ma osobnej gałęzi
/// dla replay, a testy regresyjne przechodzą dokładnie tą samą ścieżką.
fn cpuidPinned(ctx: ?*anyopaque, logical_cpu: u16, leaf: u32, subleaf: u32) status.Result(backend.Regs) {
    const self: *Replay = @ptrCast(@alignCast(ctx orelse
        return .{ .err = status.Failure.init(.failed, "replay bez kontekstu") }));
    const c = self.per_cpu.get(logical_cpu) orelse return .{ .err = status.Failure.init(
        .absent,
        "brak tego logical CPU w capture",
    ) };
    if (c.image.getBounded(leaf, subleaf)) |r| return .{ .ok = r };
    return .{ .err = status.Failure.init(.absent, "brak tego leafa w capture dla tego CPU") };
}

fn logicalCpuCount(ctx: ?*anyopaque) status.Result(u32) {
    const self: *Replay = @ptrCast(@alignCast(ctx orelse
        return .{ .err = status.Failure.init(.failed, "replay bez kontekstu") }));
    if (self.per_cpu.len == 0) {
        return .{ .err = status.Failure.init(.unsupported, "capture bez sekcji per-CPU") };
    }
    return .{ .ok = @intCast(self.per_cpu.len) };
}

fn cpuidRead(ctx: ?*anyopaque, leaf: u32, subleaf: u32) status.Result(backend.Regs) {
    const self: *Replay = @ptrCast(@alignCast(ctx orelse
        return .{ .err = status.Failure.init(.failed, "replay bez kontekstu") }));
    if (self.image.getBounded(leaf, subleaf)) |r| return .{ .ok = r };
    // Brak liścia w pliku to nie błąd: obraz po prostu nie zawiera tego,
    // co odczytano na maszynie, z której pochodzi.
    return .{ .err = status.Failure.init(.absent, "brak tego leafa w capture") };
}

const testing = std.testing;

fn sampleImage() raw.CpuidImage {
    var img = raw.CpuidImage{};
    img.max_basic = 0x16;
    img.max_extended = 0x8000_0008;
    img.add(0, 0, .{ .eax = 0x0000_0016, .ebx = 0x756E6547, .ecx = 0x6C65746E, .edx = 0x49656E69 });
    img.add(1, 0, .{ .eax = 0x000506E3, .ebx = 0x00100800, .ecx = 0x00000000, .edx = 0x178BFBFF });
    return img;
}

test "replay: implementuje ten sam kontrakt co platforma" {
    var r = Replay.init(sampleImage());
    const b = r.create();
    try testing.expect(b.hasCpuid());
    try testing.expect(!b.caps.has(.os_info));
    try testing.expectEqualStrings("replay", b.name);

    const got = b.readCpuid(0, 0).unwrap().?;
    try testing.expectEqual(@as(u32, 0x0000_0016), got.eax);
    try testing.expectEqual(@as(u32, 0x756E6547), got.ebx);
}

test "replay: liść poza zakresem daje absent, nie awarię" {
    var r = Replay.init(sampleImage());
    const b = r.create();
    const res = b.readCpuid(0x8000_0004, 0);
    try testing.expectEqual(status.Status.absent, res.getStatus());
    try testing.expectEqual(status.Status.absent, b.readCpuid(0x99, 0).getStatus());
}

test "replay: ten sam backend obsługuje wiele odczytów sekwencyjnie" {
    var r = Replay.init(sampleImage());
    const b = r.create();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try testing.expectEqual(@as(u32, 0x0000_0016), b.readCpuid(0, 0).unwrap().?.eax);
    }
}

test "replay: plik v1 bez sekcji per-CPU nie deklaruje CPUID per-procesor" {
    var r = Replay.init(sampleImage());
    const b = r.create();
    // To jest **kompatybilność wsteczna**: stary plik daje stary wynik.
    // Deklarowanie możliwości mimo jej braku sprawiłoby, że topologia wyglądała
    // jak awaria, a nie jak brak danych w pliku.
    try testing.expect(!b.hasPinnedCpuid());
    try testing.expect(!b.caps.has(.logical_cpu_enumeration));
    try testing.expectEqual(status.Status.unsupported, b.readCpuidOn(0, 1, 0).getStatus());
}

test "replay: sekcja per-CPU daje tę samą topologię co platforma żywa" {
    var img = sampleImage();
    img.max_extended = 0x8000_001E;
    // Cztery CPU, dwa rdzenie: EBX[7:0] = 0,0,1,1 — tak raportuje Zen 3.
    var per = raw.PerCpuImage{};
    const cores = [_]u32{ 0, 0, 1, 1 };
    for (cores, 0..) |core, i| {
        per.items[i] = .{ .id = @intCast(i), .id_valid = true, .scanned = true };
        per.items[i].image.max_basic = img.max_basic;
        per.items[i].image.max_extended = img.max_extended;
        per.items[i].image.add(0x8000_001E, 0, .{ .eax = @intCast(i), .ebx = core });
    }
    per.len = 4;

    var r = Replay.init(img);
    var full = r.withPerCpu(per);
    const b = full.create();
    try testing.expect(b.hasPinnedCpuid());
    try testing.expectEqual(@as(u32, 4), b.logicalCpuCount().unwrap().?);

    // Ten sam algorytm, co na platformie żywej — bez żadnej ścieżki dla replay.
    const cpuid_mod = @import("../arch/x86/cpuid.zig");
    const topo = cpuid_mod.topologyFromPerCpu(&full.per_cpu, 4);
    try testing.expect(topo.hardware_complete);
    try testing.expectEqual(@as(u16, 2), topo.physical_from_hardware);
    try testing.expectEqual(@as(u8, 2), topo.smt_from_hardware);
    try testing.expectEqual(raw.TopologySource.hardware, topo.source);
}

test "replay: brak CPU w capture daje absent, nie awarię" {
    const img = sampleImage();
    var per = raw.PerCpuImage{};
    per.items[0] = .{ .id = 0, .id_valid = true, .scanned = true };
    per.items[0].image.max_basic = img.max_basic;
    per.items[0].image.max_extended = img.max_extended;
    // Liść 1 **jest** w obrazie tego CPU — inaczej `ok` byłoby fałszywym
    // oczekiwaniem, a `absent` poprawną odpowiedzią.
    per.items[0].image.add(0x1, 0, .{ .eax = 0x000506E3, .ebx = 0x00100800, .ecx = 0, .edx = 0x178BFBFF });
    per.len = 1;
    var r = Replay.init(img);
    var full = r.withPerCpu(per);
    const b = full.create();
    try testing.expectEqual(status.Status.ok, b.readCpuidOn(0, 1, 0).getStatus());
    // CPU 7 nie istnieje w capture — `absent`, nie awaria.
    try testing.expectEqual(status.Status.absent, b.readCpuidOn(7, 1, 0).getStatus());
    // Liść 4 jest w zakresie, ale go nie odczytano — też `absent`.
    try testing.expectEqual(status.Status.absent, b.readCpuidOn(0, 4, 0).getStatus());
}

test "replay: withLimits odrzuca liście spoza zadeklarowanego zakresu" {
    var r = Replay.init(sampleImage());
    var limited = r.withLimits(1, 0x8000_0000);
    const b = limited.create();
    try testing.expectEqual(status.Status.ok, b.readCpuid(1, 0).getStatus());
    try testing.expectEqual(status.Status.absent, b.readCpuid(4, 0).getStatus());
    try testing.expectEqual(status.Status.absent, b.readCpuid(0x8000_0002, 0).getStatus());
}
