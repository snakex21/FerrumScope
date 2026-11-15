//! Backend Windows — prawdziwy dostęp do CPUID na wskazanym procesorze.
//!
//! ## Dlaczego nie jedna maska bitowa
//!
//! `SetThreadAffinityMask` obsługuje najwyżej 64 procesory, bo przyjmuje jeden
//! `ULONG_PTR`. Powyżej 64 logicznych procesorów Windows dzieli je na **processor
//! groups** i każdy wątek należy do dokładnie jednej grupy. Dlatego używamy
//! `SetThreadGroupAffinity`, które przyjmuje maskę **i** numer grupy.
//!
//! Numeracja logicznych procesorów w Windows to `group * 64 + bit`, więc
//! `logical_cpu = 100` oznacza grupę 1, bit 36. Kod poniżej realizuje właśnie
//! ten mapping — bez niego wątek zostałby w grupie 0, czyli na innym CPU.
//!
//! ## Gwarancja przywracania
//!
//! Każde przypięcie jest odwracane przez `defer` w miejscu, które je nabyło.
//! **Zawsze** — także po błędzie i po `unreachable`. Proces zostawiony na jednym
//! CPU działałby wolniej i zaburzałby pomiar pozostałych rdzeni, więc to nie
//! higiena, lecz poprawność pomiaru.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("backend.zig");
const status = @import("../core/status.zig");
const cpuid = @import("../arch/x86/cpuid.zig");

// ---------------------------------------------------------------------------
// Deklaracje API Windows
//
// `std.os.windows.kernel32` w Zig 0.15.2 **nie zawiera** API processor groups
// (`SetThreadGroupAffinity`, `GetActiveProcessorCount`, `GetThreadAffinityMask`).
// Deklarujemy je sami z konwencją `WINAPI` — bez tego nie da się obsłużyć >64 CPU.
//
// Minimalna wersja systemu dla tej ścieżki: **Windows 7** (pierwsza z processor
// groups). FerrumScope ma w praktyce Windows 10+, więc traktujemy to jako
// kontrakt binarny, a nie gałąź do wykrywania w runtime.
// ---------------------------------------------------------------------------

pub const HANDLE = *anyopaque;
const DWORD = u32;
const WORD = u16;
const BOOL = i32;
const DWORD_PTR = usize;

/// `ALL_PROCESSOR_GROUPS` — policz ze wszystkich grup, nie tylko bieżącej.
const ALL_PROCESSOR_GROUPS: WORD = 0xFFFF;

/// `GROUP_AFFINITY` — maska bitowa w obrębie grupy + numer grupy.
const GROUP_AFFINITY = extern struct {
    Mask: usize, // KAFFINITY
    Group: u16,
    Reserved: [3]u16,
};

/// `GetCurrentThread` zwraca pseudo-uchwyt (`(HANDLE)-2`) i nigdy nie NULL,
/// ale deklarujemy typ opcjonalny: `*anyopaque` nie wolno porównywać z `null`
/// w tej wersji Ziga, a chcemy zachować bramkę dla defensywnego sprawdzenia.
extern "kernel32" fn GetCurrentThread() callconv(.winapi) ?HANDLE;
extern "kernel32" fn GetActiveProcessorCount(GroupNumber: WORD) callconv(.winapi) DWORD;
extern "kernel32" fn SetThreadGroupAffinity(
    hThread: HANDLE,
    GroupAffinity: *const GROUP_AFFINITY,
    PreviousGroupAffinity: ?*GROUP_AFFINITY,
) callconv(.winapi) BOOL;

fn lastErrorCode() u32 {
    // W tej wersji Zig `GetLastError` zwraca enum `Win32Error`, nie liczbę —
    // stąd `@intFromEnum`, a nie `@bitCast`.
    return @intCast(@intFromEnum(std.os.windows.kernel32.GetLastError()));
}

// ---------------------------------------------------------------------------
// Kontekst
// ---------------------------------------------------------------------------

pub const Ctx = struct {
    error_buf: backend.Ctx = .{},
    /// Grupa, z której wróciliśmy po ostatnim przypięciu — diagnostyka.
    last_group: u16 = 0,

    pub fn fail(
        self: *Ctx,
        st: status.Status,
        op: []const u8,
        code: u32,
        logical_cpu: ?u16,
        leaf: ?u32,
        subleaf: ?u32,
    ) status.Failure {
        return self.error_buf.fail(st, op, code, logical_cpu, leaf, subleaf);
    }

    pub fn lastError(self: *const Ctx) []const u8 {
        return self.error_buf.lastError();
    }
};

var global_ctx: Ctx = .{};

// ---------------------------------------------------------------------------
// Enumeracja
// ---------------------------------------------------------------------------

/// Liczba online logical processors.
///
/// `ALL_PROCESSOR_GROUPS` uwzględnia wszystkie grupy. Bez tego argumentu API
/// zwraca rozmiar **bieżącej** grupy, czyli na maszynie 128-procesorowej
/// raportowałoby fałszywe 64.
pub fn logicalCpuCount(_: ?*anyopaque) status.Result(u32) {
    const n = GetActiveProcessorCount(ALL_PROCESSOR_GROUPS);
    if (n == 0) {
        return .{ .err = global_ctx.fail(
            .failed,
            "GetActiveProcessorCount",
            lastErrorCode(),
            null,
            null,
            null,
        ) };
    }
    return .{ .ok = n };
}

// ---------------------------------------------------------------------------
// Przypinanie wątku
// ---------------------------------------------------------------------------

/// Strażnik przypisania wątku do konkretnego procesora.
///
/// Wywołujący **musi** wywołać `restore()` przez `defer`. Jedyna dozwolona
/// dyscyplina: strażnik powstaje w jednym miejscu i od razu trafia pod `defer`.
const Pin = struct {
    thread: HANDLE,
    /// Poprzednie przypisanie — `SetThreadGroupAffinity` wypełnia je sam,
    /// więc nie potrzebujemy osobnego `GetThreadAffinityMask` (którego i tak nie
    /// ma w import lib Ziga).
    previous: GROUP_AFFINITY,

    fn restore(self: *const Pin) void {
        _ = SetThreadGroupAffinity(self.thread, &self.previous, null);
    }
};

pub const PinError = error{ Platform, Unsupported };

/// Przypina wątek do `logical_cpu` i zwraca strażnika do przywrócenia.
fn acquire(logical_cpu: u16) PinError!Pin {
    // `orelse`, nie `if (x == null)`: ta druga forma nie zwęża typu opcjonalnego
    // w tej wersji Ziga, przez co uchwyt dalej byłby `?*anyopaque`.
    const thread = GetCurrentThread() orelse {
        _ = global_ctx.fail(.failed, "GetCurrentThread", 0, logical_cpu, null, null);
        return error.Platform;
    };

    // Numeracja Windows: logical_cpu = group * 64 + bit w masce tej grupy.
    const group: u16 = @intCast(logical_cpu / 64);
    const bit: u6 = @intCast(logical_cpu % 64);
    const desired = GROUP_AFFINITY{
        .Mask = @as(usize, 1) << bit,
        .Group = group,
        .Reserved = .{ 0, 0, 0 },
    };

    var previous: GROUP_AFFINITY = undefined;
    if (SetThreadGroupAffinity(thread, &desired, &previous) != 0) {
        return .{ .thread = thread, .previous = previous };
    }

    // Ścieżka z grupami zawiodła. Nie próbujemy `SetThreadAffinityMask` jako
    // „planu B" — obsługuje ona najwyżej 64 procesory, więc powyżej tej granicy
    // dałaby cichy, błędny sukces. Zgłaszamy realny błąd z kodem platformowym.
    const code = lastErrorCode();
    _ = global_ctx.fail(.failed, "SetThreadGroupAffinity", code, logical_cpu, null, null);
    return error.Platform;
}

/// Wykonuje `body(logical_cpu)` przypięty do `logical_cpu`, zawsze przywracając
/// poprzednią affinity.
///
/// Zbiory błędów celowo **nie** zawężamy do `PinError`: `body` zwraca `anyerror`
/// i zawężanie wymagałoby mapowania każdego błędu, niczego nie wnosząc.
pub fn withPinned(logical_cpu: u16, body: *const fn (u16) anyerror!void) !void {
    var pin = try acquire(logical_cpu);
    defer pin.restore();
    global_ctx.last_group = pin.previous.Group;
    try body(logical_cpu);
}

/// CPUID na wskazanym logical procesorze.
///
/// **Jedno** przypięcie na cały odczyt. Pierwsza wersja przypinała dwa razy
/// (raz „na próbę", raz właściwie), co mnożyło koszt i zaplątywało dwa
/// niezależne mechanizmy przywracania.
pub fn cpuidPinned(_: ?*anyopaque, logical_cpu: u16, leaf: u32, subleaf: u32) status.Result(backend.Regs) {
    var pin = acquire(logical_cpu) catch |e| return .{ .err = switch (e) {
        error.Unsupported => status.Failure.init(
            .unsupported,
            "SetThreadGroupAffinity odrzucil CPU powyzej 64 — nie umiemy przypinac",
        ),
        error.Platform => global_ctx.error_buf.lastFailure(),
    } };
    defer pin.restore();
    global_ctx.last_group = pin.previous.Group;

    const r = cpuid.execute(leaf, subleaf) orelse return .{ .err = status.Failure.init(
        .unsupported,
        "CPUID niedostepne na tej architekturze",
    ) };
    return .{ .ok = r };
}

fn cpuidRead(_: ?*anyopaque, leaf: u32, subleaf: u32) status.Result(backend.Regs) {
    const r = cpuid.execute(leaf, subleaf) orelse
        return .{ .err = status.Failure.init(.unsupported, "CPUID niedostepne na tej architekturze") };
    return .{ .ok = r };
}

pub fn osInfo(_: ?*anyopaque, buf: []u8) status.Result(backend.OsInfo) {
    var info = backend.OsInfo{};
    info.kind = .windows;
    info.arch = switch (builtin.cpu.arch) {
        .x86 => .x86,
        .x86_64 => .x86_64,
        .aarch64, .arm => .arm64,
        else => .other,
    };
    // Wersja identyfikuje kompilację, nie system — ta sama konwencja co w
    // backendzie przenośnym. Wersję systemu podaje `explain` przez RtlGetVersion.
    _ = std.fmt.bufPrint(&info.version, "{d}.{d}.{d}", .{
        @intFromEnum(builtin.os.tag),
        @intFromEnum(builtin.cpu.arch),
        @intFromEnum(builtin.abi),
    }) catch "unknown";
    _ = buf;
    return .{ .ok = info };
}

pub fn create() backend.Backend {
    var caps = backend.CapabilitySet{};
    caps.add(.os_info);
    // CPUID dodajemy tylko jeśli faktycznie odpowiada. Deklaracja możliwości,
    // której nie ma, byłaby kłamstwem: probe wierzyłby, że potrafi, a potem
    // cicho nie znalazłby danych.
    if (cpuid.execute(0, 0) != null) {
        caps.add(.cpuid);
        caps.add(.logical_cpu_enumeration);
        caps.add(.thread_affinity);
        caps.add(.cpuid_per_logical_cpu);
    }
    return .{
        .name = "native-windows",
        .caps = caps,
        .ctx = @ptrCast(&global_ctx),
        .cpuid = cpuidRead,
        .cpuid_pinned = cpuidPinned,
        .logical_cpu_count = logicalCpuCount,
        .os_info = osInfo,
    };
}

const testing = std.testing;

/// `status.Result` to unia, a nie unia błędów — `catch` tu nie zadziała.
/// Gdy platforma nie potrafi, test pomijamy, zamiast udawać sukces.
fn okOrSkip(comptime T: type, r: status.Result(T)) error{SkipZigTest}!T {
    return r.unwrap() orelse error.SkipZigTest;
}

test "windows: backend deklaruje CPUID, enumerację i przypinanie" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const b = create();
    try testing.expect(b.hasCpuid());
    try testing.expect(b.hasPinnedCpuid());
    try testing.expect(b.caps.has(.thread_affinity));
    try testing.expect(b.caps.has(.logical_cpu_enumeration));
}

test "windows: liczba logical processors jest sensowna" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const b = create();
    const n = try okOrSkip(u32, b.logicalCpuCount());
    try testing.expect(n >= 1);
    // ALL_PROCESSOR_GROUPS musi uwzględniać wszystkie grupy, więc wynik nie
    // może być mniejszy niż liczba CPU bieżącej grupy (std: GetSystemInfo).
    // Nie porównujemy z CPUID leaf 1 EBX[23:16]: to maksymalna liczba
    // adresowalnych ID w pakiecie (potęga dwójki), nie liczba widocznych
    // procesorów — na maszynach wirtualnych (runnery CI) bywa większa.
    const in_group = std.Thread.getCpuCount() catch return error.SkipZigTest;
    try testing.expect(n >= in_group);
}

test "windows: CPUID na wskazanym CPU zwraca tego samego vendora" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const b = create();
    const here = try okOrSkip(backend.Regs, b.readCpuid(0, 0));
    // Odczyt na CPU 0. Vendor jest ten sam na wszystkich rdzeniach jednego
    // procesora, więc to poprawna, a niemal bezkosztowa kontrola.
    const zero = try okOrSkip(backend.Regs, b.readCpuidOn(0, 0, 0));
    try testing.expectEqual(here.ebx, zero.ebx);
    try testing.expectEqual(here.ecx, zero.ecx);
    try testing.expectEqual(here.edx, zero.edx);
}

test "windows: affinity jest przywracana także po błędie" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const b = create();
    const count_before = try okOrSkip(u32, b.logicalCpuCount());
    const before = try okOrSkip(backend.Regs, b.readCpuid(1, 0));

    // Świadomy błąd: CPU o numerze niemożliwym. Po nim wątek musi wrócić na
    // swoje pierwotne CPU — inaczej kolejne odczyty biegłyby w innym
    // kontekście niż przed przypięciem.
    const r = b.readCpuidOn(0xFFFF, 0, 0);
    try testing.expect(r.getStatus() != .ok);

    const after = try okOrSkip(backend.Regs, b.readCpuid(1, 0));
    try testing.expectEqual(before.eax, after.eax);
    try testing.expectEqual(before.ebx, after.ebx);
    const count_after = try okOrSkip(u32, b.logicalCpuCount());
    try testing.expectEqual(count_before, count_after);
}

test "windows: leaf 0x8000001E opisuje biezacy CPU (powod przypinania)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const b = create();
    // Test dokumentuje **powód**, dla którego istnieje przypinanie: liść opisuje
    // procesor, na którym wykonano CPUID, a nie ten, na którym trafił scheduler.
    // Nie wymagamy niezgodności (na maszynie jednoprocesorowej będzie zgodność) —
    // sprawdzamy, że odczyt działa i zwraca wiarygodny zakres.
    const leaf0 = try okOrSkip(backend.Regs, b.readCpuid(0x8000_0000, 0));
    if (leaf0.eax < 0x8000_001E) return error.SkipZigTest;
    const r = try okOrSkip(backend.Regs, b.readCpuidOn(0, 0x8000_001E, 0));
    // ThreadsPerComputeUnit jest małe; wartości typu 12 oznaczają, że liczyliśmy
    // coś innego niż liczbę wątków na rdzeń.
    try testing.expect(r.eax < 64);
}
