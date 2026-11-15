//! Kontrakt platformy. Jedyne miejsce w programie, które wie, skąd pochodzą
//! dane — i jedyne, w którym wolno rozgałęziać się po systemie operacyjnym.
//!
//! Zasada projektowa z `docs/02-architektura.md`: **decoder i probe nie wiedzą,
//! czy dane pochodzą z Windows, Linux, macOS, USOS, czy z pliku capture.**
//! Widzą wyłącznie `Backend`.

const std = @import("std");
const status = @import("../core/status.zig");
const raw = @import("../core/raw.zig");

pub const Regs = raw.Regs;

/// Możliwości, jakie platforma może udostępnić.
///
/// Lista jest celowo zamknięta i wspólna dla wszystkich systemów. Backend
/// deklaruje, co **ma**; probe deklaruje, czego **potrzebuje**. Brak możliwości
/// to `Status.unsupported`, a nie błąd programu.
pub const Capability = enum {
    /// Odczyt CPUID — podstawa identyfikacji CPU na x86/x86_64.
    cpuid,
    /// Odczyt MSR (przestrzeń przełącznika trybu).
    msr_read,
    msr_write,
    /// Odczyt przestrzeni konfiguracyjnej PCI.
    pci_config,
    /// Porty I/O x86.
    io_ports,
    /// Transakcje SMBus/I2C.
    smbus,
    i2c,
    /// Polecenia administracyjne NVMe.
    nvme_admin,
    /// Tabele SMBIOS/DMI.
    smbios,
    /// Informacje o systemie operacyjnym.
    os_info,
    /// Magistrala GPU właściwa dla platformy.
    gpubus,
    /// Biblioteka AMD ADL.
    vendor_adl,
    /// Biblioteka NVIDIA NVAPI.
    vendor_nvapi,
    /// Biblioteka Intel IGCL.
    vendor_igcl,
    /// CPUID wykonane **po przypinaniu wątku** do wybranego logical processor.
    ///
    /// To zdolność, która odróżnia topologię od zgadywania: liście `0xB`,
    /// `0x1F` i `0x8000001E` opisują procesor, na którym wykonano CPUID.
    /// Bez tego jedynym źródłem pozostaje fallback z bazy.
    cpuid_per_logical_cpu,
    /// Ustawianie i przywracanie affinity bieżącego wątku.
    thread_affinity,
    /// Enumeracja online logical processors.
    logical_cpu_enumeration,
    /// Topologia NUMA (node per CPU).
    numa_topology,

    /// Indeks bitu w masce. Kolejność jest częścią kontraktu — nie zmieniaj
    /// kolejności istniejących pól, dodawaj nowe na końcu.
    pub fn bit(self: Capability) u6 {
        return @intFromEnum(self);
    }
};

/// Wspólny kontekst platformy: bufor na ostatni błąd.
///
/// `status.Failure.detail` to `[]const u8`, więc komunikat musi gdzieś żyć.
/// Zamiast statycznego bufora globalnego backend trzyma własny kontekst —
/// dwa niezależne backendy nie nadpisują sobie komunikatów.
pub const Ctx = struct {
    pub const buf_len = 512;

    last_error_buf: [buf_len]u8 = @splat(0),
    last_error_len: usize = 0,
    /// Czy od ostatniego wywołania zdarzył się błąd.
    had_error: bool = false,
    /// Status towarzyszący `last_error_buf`. Bez niego zwrócilibyśmy sam tekst
    /// i każdy caller musiałby zgadywać, czy to `denied` czy `failed`.
    last_status: status.Status = .ok,

    /// Buduje błąd z kompletnym kontekstem: operacja, kod platformowy,
    /// logical CPU oraz leaf/subleaf, jeśli dotyczy.
    ///
    /// Numery są opcjonalne (`null`), bo nie każde API dotyczy CPU i liścia —
    /// ale gdy dotyczą, muszą się tu znaleźć, bo poza logiem nikt ich nie zobaczy.
    pub fn fail(
        self: *Ctx,
        st: status.Status,
        op: []const u8,
        code: u32,
        logical_cpu: ?u16,
        leaf: ?u32,
        subleaf: ?u32,
    ) status.Failure {
        self.last_status = st;
        self.had_error = true;
        // Budujemy komunikat sekwencyjnie, a nie jednym wyrażeniem z `++`:
        // warunkowe fragmenty w wyrażeniu formatującym są w Zig pułapką
        // (nieużywane przechwyty), a tutaj warunków są trzy.
        var w = std.Io.Writer.fixed(&self.last_error_buf);
        w.print("{s}: kod={d} (0x{X})", .{ op, code, code }) catch {};
        if (logical_cpu) |c| w.print(" cpu={d}", .{c}) catch {};
        if (leaf) |l| w.print(" leaf=0x{X}", .{l}) catch {};
        if (subleaf) |sl| w.print(" subleaf=0x{X}", .{sl}) catch {};
        self.last_error_len = w.buffered().len;

        if (self.last_error_len == 0) {
            // Bufor pełny albo pusty komunikat to też diagnoza — mówimy wprost,
            // że treść się nie zmieściła, zamiast zostawić śmieci.
            const msg = "komunikat bledu platformy przekroczyl bufor";
            const n = @min(msg.len, self.last_error_buf.len);
            @memcpy(self.last_error_buf[0..n], msg[0..n]);
            self.last_error_len = n;
        }
        return status.Failure.init(st, self.last_error_buf[0..self.last_error_len]);
    }

    /// Ostatni błąd platformowy — pusty, jeśli nie było błędu.
    pub fn lastError(self: *const Ctx) []const u8 {
        return self.last_error_buf[0..self.last_error_len];
    }

    /// Ostatni błąd jako kompletny `Failure` (status + opis).
    pub fn lastFailure(self: *const Ctx) status.Failure {
        return status.Failure.init(self.last_status, self.lastError());
    }

    pub fn clearError(self: *Ctx) void {
        self.last_error_len = 0;
        self.had_error = false;
        self.last_status = .ok;
    }
};

/// Zbiór możliwości — maska bitowa.
pub const CapabilitySet = struct {
    bits: u64 = 0,

    pub fn has(self: CapabilitySet, c: Capability) bool {
        return (self.bits & (@as(u64, 1) << c.bit())) != 0;
    }

    pub fn add(self: *CapabilitySet, c: Capability) void {
        self.bits |= (@as(u64, 1) << c.bit());
    }

    pub fn count(self: CapabilitySet) usize {
        return @popCount(self.bits);
    }
};

/// Minimalne informacje o systemie. Zwraca wyłącznie warstwa platformowa.
pub const OsInfo = struct {
    /// Nazwa systemu operacyjnego z **zamkniętego katalogu**, nie wolny tekst
    /// z systemu (dla porównywalności między platformami).
    kind: enum { windows, linux, macos, usos, unknown } = .unknown,
    version: [64]u8 = @splat(0),
    arch: raw.Arch = .other,

    pub fn versionSlice(self: *const OsInfo) []const u8 {
        const end = std.mem.indexOfScalar(u8, &self.version, 0) orelse self.version.len;
        return self.version[0..end];
    }
};

/// Odczyt CPUID. Kontekst jest potrzebny, bo backend replay jest stanowy
/// (przechowuje obraz z pliku), a natywny — nie.
pub const CpuidFn = *const fn (ctx: ?*anyopaque, leaf: u32, subleaf: u32) status.Result(Regs);

/// Odczyt CPUID **po przypinaniu wątku** do `logical_cpu`.
///
/// Zwraca `unsupported`, gdy backend nie potrafi przypiąć wątku — wtedy
/// topologia pochodzi z fallbacku, a nie z zgadywania. Implementacja ma
/// obowiązek przywrócić poprzednią affinity **także po błędzie**.
pub const CpuidPinnedFn = *const fn (
    ctx: ?*anyopaque,
    logical_cpu: u16,
    leaf: u32,
    subleaf: u32,
) status.Result(Regs);

/// Liczba online logical processors. `unsupported`, gdy brak enumeracji —
/// wtedy używamy liczby z CPUID leaf 1.
pub const LogicalCpuCountFn = *const fn (ctx: ?*anyopaque) status.Result(u32);

/// Odczyt informacji o systemie.
pub const OsInfoFn = *const fn (ctx: ?*anyopaque, buf: []u8) status.Result(OsInfo);

/// Uzasadnienie braku możliwości — dla UI i logu, nie dla użytkownika końcowego.
pub const Unavailable = struct {
    capability: Capability,
    reason: []const u8,
};

/// Backend: zestaw prymitywów udostępnianych przez jedną platformę
/// (albo przez plik capture).
pub const Backend = struct {
    /// Nazwa do diagnostyki: "native-windows", "replay", ...
    name: []const u8,
    caps: CapabilitySet = .{},
    /// Kontekst przekazywany do wszystkich prymitywów.
    ctx: ?*anyopaque = null,

    cpuid: ?CpuidFn = null,
    os_info: ?OsInfoFn = null,
    /// Odczyt CPUID na wskazanym logical procesorze. `null` = backend tego nie umie.
    cpuid_pinned: ?CpuidPinnedFn = null,
    /// Liczba online logical processors. `null` = backend nie enumeruje.
    logical_cpu_count: ?LogicalCpuCountFn = null,

    /// Czy backend ma CPUID. Probe sprawdza to **przed** odczytem i zwraca
    /// `Status.unsupported` zamiast wołać `null`.
    pub fn hasCpuid(self: Backend) bool {
        return self.cpuid != null and self.caps.has(.cpuid);
    }

    /// Odczyt CPUID z kontrolą możliwości — jedyne miejsce, w którym backend
    /// może zwrócić „nie umiem", więc caller nie musi sprawdzać `null`.
    pub fn readCpuid(self: Backend, leaf: u32, subleaf: u32) status.Result(Regs) {
        const f = self.cpuid orelse
            return .{ .err = status.Failure.init(.unsupported, "backend nie udostepnia CPUID") };
        return f(self.ctx, leaf, subleaf);
    }

    pub fn readOsInfo(self: Backend, buf: []u8) status.Result(OsInfo) {
        const f = self.os_info orelse
            return .{ .err = status.Failure.init(.unsupported, "backend nie udostepnia OS info") };
        return f(self.ctx, buf);
    }

    /// Czy backend potrafi odczytać CPUID z dowolnego logical procesora.
    /// Odpowiada temu, czy `readCpuidOn` ma sens — nie wołamy go inaczej.
    pub fn hasPinnedCpuid(self: Backend) bool {
        return self.cpuid_pinned != null and self.caps.has(.cpuid_per_logical_cpu);
    }

    /// CPUID na konkretnym logical procesorze.
    ///
    /// Dekoder i probe wołają to z abstrakcyjnym `logical_cpu` i nie wiedzą,
    /// czy pod spodem jest `SetThreadGroupAffinity`, `sched_setaffinity`, czy
    /// odczyt z tablicy w pliku capture.
    pub fn readCpuidOn(self: Backend, logical_cpu: u16, leaf: u32, subleaf: u32) status.Result(Regs) {
        const f = self.cpuid_pinned orelse return .{ .err = status.Failure.init(
            .unsupported,
            "backend nie udostepnia CPUID na wybranym logical CPU",
        ) };
        return f(self.ctx, logical_cpu, leaf, subleaf);
    }

    pub fn logicalCpuCount(self: Backend) status.Result(u32) {
        const f = self.logical_cpu_count orelse
            return .{ .err = status.Failure.init(.unsupported, "backend nie enumeruje logical CPU") };
        return f(self.ctx);
    }
};

const testing = std.testing;

test "CapabilitySet: dodawanie i sprawdzanie bitów" {
    var set = CapabilitySet{};
    try testing.expect(!set.has(.cpuid));
    set.add(.cpuid);
    set.add(.smbus);
    try testing.expect(set.has(.cpuid));
    try testing.expect(set.has(.smbus));
    try testing.expect(!set.has(.msr_read));
    try testing.expectEqual(@as(usize, 2), set.count());
}

test "Backend: brak CPUID daje unsupported, a nie awarię" {
    const b = Backend{ .name = "pusty" };
    try testing.expect(!b.hasCpuid());
    const r = b.readCpuid(0, 0);
    try testing.expectEqual(status.Status.unsupported, r.getStatus());
}

test "Capability: indeksy bitów są unikalne i stabilne" {
    // Kolejność pól Capability jest częścią kontraktu z bazą i przyszłymi
    // wersjami formatu. Test blokuje przypadkowe wstawienie nowego pola w środek.
    try testing.expectEqual(@as(u6, 0), Capability.cpuid.bit());
    try testing.expectEqual(@as(u6, 1), Capability.msr_read.bit());
    try testing.expectEqual(@as(u6, 2), Capability.msr_write.bit());
    try testing.expectEqual(@as(u6, 3), Capability.pci_config.bit());
    try testing.expect(Capability.vendor_nvapi.bit() > Capability.cpuid.bit());
}
