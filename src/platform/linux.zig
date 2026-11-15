//! Backend Linux — CPUID na wskazanym procesorze przez `sched_setaffinity`.
//!
//! ## Zasada: FerrumScope rozumie CPU sam
//!
//! Wykorzystujemy sysfs **wyłącznie** jako pomocnicze źródło informacji
//! o tym, które procesory są online. Nigdy nie zastępujemy własnego dekodera
//! CPUID parsowaniem `/proc/cpuinfo` — `model name` stamtąd to zniekształcony
//! brand string, a `cpu family`/`model` bywają uzupełniane przez hypervisor.
//! Wszystko, co opisuje sam procesor, czytamy z CPUID na konkretnym CPU.
//!
//! ## CPU_SET i numery
//!
//! Linux numeruje procesory 0..N-1, a `sched_setaffinity` przyjmuje bitmapę
//! `cpu_set_t` (1024 bity). Kernel pozwala ustawić **dokładnie jeden** bit —
//! ustawienie wielu oznacza „uruchom gdziekolwiek z tych", a nie „przypnij".
//! Stąd `logical_cpu` przekładamy na pojedynczy bit.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("backend.zig");
const status = @import("../core/status.zig");
const raw = @import("../core/raw.zig");
const cpuid = @import("../arch/x86/cpuid.zig");
const linux = std.os.linux;

/// Stan backendu Linux — jeden na proces.
pub const Ctx = struct {
    error_buf: backend.Ctx = .{},

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

/// Bitmapa procesorów — cienka nakładka na `linux.cpu_set_t`.
///
/// Używamy typu std, bo `sched_setaffinity` przyjmuje właśnie `*const cpu_set_t`
/// i rzutowanie naszej własnej struktury wymagałoby `@ptrCast` na nieczytelne.
/// Zewnętrzna powłoka daje testowalne `set`/`has`/`count` bez ujawniania, że
/// bitmapa to zwykła tablica słów maszynowych.
pub const CpuSet = struct {
    pub const bits = 1024;

    raw: linux.cpu_set_t = @splat(0),

    /// Ustawia **dokładnie jeden** bit. Wiele bitów oznaczałoby „uruchom
    /// gdziekolwiek z tych" (rozszerzenie sched_setaffinity), a nie przypięcie.
    pub fn setOne(self: *CpuSet, cpu: u32) void {
        if (cpu >= bits) return;
        self.raw[cpu / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
    }

    pub fn has(self: *const CpuSet, cpu: u32) bool {
        if (cpu >= bits) return false;
        return (self.raw[cpu / @bitSizeOf(usize)] &
            (@as(usize, 1) << @intCast(cpu % @bitSizeOf(usize)))) != 0;
    }

    pub fn count(self: *const CpuSet) u32 {
        var n: u32 = 0;
        for (self.raw) |w| n += @popCount(w);
        return n;
    }
};

/// Błąd `errno` jako liczba, gotowa do `Ctx.fail`.
fn errnoCode(e: linux.E) u32 {
    return @intCast(@intFromEnum(e));
}

// ---------------------------------------------------------------------------
// Cienkie nakładki na surowe syscalle
//
// `std.os.linux.sched_setaffinity` w Zig 0.15.2 jest **zepsuty** przy budowaniu
// bez libc: w gałęzi błędu woła `std.posix.unexpectedErrno` z enumem `std.c`,
// którego nie ma, gdy libc nie jest linkowane. Kompilacja pada w `zig build test`
// nawet na Windows, bo `refAllDeclsRecursive` wciąga moduł Linuksa.
//
// Dlatego wołamy syscall bezpośrednio. To nie obejście „na siłę" — to ta sama
// instrukcja, tylko z własną obsługą `errno`, dzięki której komunikat błędu
// zawiera numer CPU i nazwę operacji.
// ---------------------------------------------------------------------------

fn sysGetAffinity(set: *linux.cpu_set_t) usize {
    return linux.syscall3(.sched_getaffinity, 0, @sizeOf(linux.cpu_set_t), @intFromPtr(set));
}

fn sysSetAffinity(set: *const linux.cpu_set_t) usize {
    return linux.syscall2(.sched_setaffinity, 0, @intFromPtr(set));
}

// ---------------------------------------------------------------------------
// Enumeracja
// ---------------------------------------------------------------------------

/// Liczba online logical processors.
///
/// Kolejność źródeł jest świadoma:
///   1. `sched_getaffinity` — maska, którą faktycznie dostajemy. To jedyne
///      źródło zgodne z tym, gdzie kernel pozwoli nam działać (cgroups, `taskset`).
///   2. sysfs `online` — pełna lista online, gdyby maska była zawężona.
///
/// Samo CPUID leaf 1 **nie** służy do tego: pod hiperwizorem zawyża liczbę
/// wątków, bo hypervisor nie zawsze poprawia APIC id.
pub fn logicalCpuCount(_: ?*anyopaque) status.Result(u32) {
    var set: CpuSet = .{};
    const rc = sysGetAffinity(&set.raw);
    switch (linux.E.init(rc)) {
        .SUCCESS => {
            const n = set.count();
            if (n == 0) {
                return .{ .err = global_ctx.fail(.failed, "sched_getaffinity", 0, null, null, null) };
            }
            return .{ .ok = n };
        },
        else => |e| {
            return .{ .err = global_ctx.fail(
                .failed,
                "sched_getaffinity",
                errnoCode(e),
                null,
                null,
                null,
            ) };
        },
    }
}

/// Lista online logical processorów z sysfs (`N`, albo zakresy `0-3,8-11`).
///
/// Zwraca `unsupported`, gdy pliku nie ma (np. nietypowe jądro, kontener bez
/// montowanego sysfs). Wtedy używamy `sched_getaffinity`, a brak pliku **nie**
/// jest błędem programu.
pub fn onlineCpusFromSysfs(text_buf: []u8, out: []u32) ![]u32 {
    const file = std.fs.openFileAbsolute("/sys/devices/system/cpu/online", .{}) catch
        return error.NotAvailable;
    defer file.close();
    const n = try file.readAll(text_buf);
    const text = std.mem.trim(u8, text_buf[0..n], " \t\r\n");
    return parseCpuList(text, out);
}

/// Parsuje format listy CPU: `0-15`, `0-3,8-11`, `0`, `0,2,4`.
///
/// Osobna, testowalna funkcja — sysfs to jedyne miejsce, gdzie dotykamy
/// formatu specyficznego dla platformy, więc warto je testować bez systemu.
pub fn parseCpuList(text: []const u8, out: []u32) ![]u32 {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        if (part.len == 0) continue;
        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const lo = std.fmt.parseInt(u32, part[0..dash], 10) catch return error.BadCpuList;
            const hi = std.fmt.parseInt(u32, part[dash + 1 ..], 10) catch return error.BadCpuList;
            if (hi < lo or hi >= CpuSet.bits) return error.BadCpuList;
            var c = lo;
            while (c <= hi) : (c += 1) {
                if (n == out.len) return error.NoSpace;
                out[n] = c;
                n += 1;
            }
        } else {
            const v = std.fmt.parseInt(u32, part, 10) catch return error.BadCpuList;
            if (v >= CpuSet.bits) return error.BadCpuList;
            if (n == out.len) return error.NoSpace;
            out[n] = v;
            n += 1;
        }
    }
    return out[0..n];
}

// ---------------------------------------------------------------------------
// Przypinanie wątku
// ---------------------------------------------------------------------------

pub const PinError = error{ Platform, Unsupported };

/// Strażnik przypisania wątku — patrz komentarz w `windows.zig`.
/// Obowiązek `defer restore()` jest ten sam: bez tego proces zostaje
/// przypięty do jednego rdzenia, co zaburza pomiar pozostałych.
const Pin = struct {
    previous: CpuSet,

    fn restore(self: *const Pin) void {
        // Przywrócenie nie może samo w sobie przerwać programu, więc błąd
        // zostaje zapisany w kontekście i jest widoczny w `explain`.
        switch (linux.E.init(sysSetAffinity(&self.previous.raw))) {
            .SUCCESS => {},
            else => |e| {
                _ = global_ctx.fail(.failed, "sched_setaffinity(restore)", errnoCode(e), null, null, null);
            },
        }
    }
};

fn acquire(logical_cpu: u32) !Pin {
    var previous: CpuSet = .{};
    const rc = sysGetAffinity(&previous.raw);
    switch (linux.E.init(rc)) {
        .SUCCESS => {},
        else => |e| {
            _ = global_ctx.fail(
                .failed,
                "sched_getaffinity",
                errnoCode(e),
                @intCast(logical_cpu),
                null,
                null,
            );
            return error.Platform;
        },
    }

    if (logical_cpu >= CpuSet.bits) {
        _ = global_ctx.fail(.unsupported, "sched_setaffinity", 0, @intCast(logical_cpu), null, null);
        return error.Unsupported;
    }

    var desired: CpuSet = .{};
    desired.setOne(logical_cpu);
    switch (linux.E.init(sysSetAffinity(&desired.raw))) {
        .SUCCESS => {},
        else => |e| {
            _ = global_ctx.fail(
                .failed,
                "sched_setaffinity",
                errnoCode(e),
                @intCast(logical_cpu),
                null,
                null,
            );
            return error.Platform;
        },
    }
    return .{ .previous = previous };
}

/// Wykonuje `body` przypięty do `logical_cpu`, zawsze przywracając affinity.
pub fn withPinned(logical_cpu: u16, body: *const fn (u16) anyerror!void) !void {
    var pin = try acquire(logical_cpu);
    defer pin.restore();
    try body(logical_cpu);
}

/// CPUID na wskazanym logical procesorze.
pub fn cpuidPinned(_: ?*anyopaque, logical_cpu: u16, leaf: u32, subleaf: u32) status.Result(backend.Regs) {
    var pin = acquire(logical_cpu) catch |e| return .{ .err = switch (e) {
        error.Unsupported => status.Failure.init(.unsupported, "sched_setaffinity odrzucil ten CPU"),
        error.Platform => global_ctx.error_buf.lastFailure(),
    } };
    defer pin.restore();

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

pub fn create() backend.Backend {
    var caps = backend.CapabilitySet{};
    caps.add(.os_info);
    if (cpuid.execute(0, 0) != null) {
        caps.add(.cpuid);
        caps.add(.thread_affinity);
        caps.add(.cpuid_per_logical_cpu);
        // Enumeracja: `sched_getaffinity` jest dostępne zawsze w Linuksie, więc
        // deklarujemy możliwość, gdy tylko CPUID odpowiada.
        caps.add(.logical_cpu_enumeration);
    }
    return .{
        .name = "native-linux",
        .caps = caps,
        .ctx = @ptrCast(&global_ctx),
        .cpuid = cpuidRead,
        .cpuid_pinned = cpuidPinned,
        .logical_cpu_count = logicalCpuCount,
        .os_info = osInfo,
    };
}

pub fn osInfo(_: ?*anyopaque, buf: []u8) status.Result(backend.OsInfo) {
    var info = backend.OsInfo{};
    info.kind = .linux;
    info.arch = switch (builtin.cpu.arch) {
        .x86_64 => .x86_64,
        .x86 => .x86,
        .aarch64, .arm => .arm64,
        .riscv64 => .riscv64,
        else => .other,
    };
    _ = std.fmt.bufPrint(&info.version, "{d}.{d}.{d}", .{
        @intFromEnum(builtin.os.tag),
        @intFromEnum(builtin.cpu.arch),
        @intFromEnum(builtin.abi),
    }) catch "unknown";
    _ = buf;
    return .{ .ok = info };
}

const testing = std.testing;

/// `status.Result` to unia, a nie unia błędów — `catch` tu nie zadziała.
fn okOrSkip(comptime T: type, r: status.Result(T)) error{SkipZigTest}!T {
    return r.unwrap() orelse error.SkipZigTest;
}

test "linux: parseCpuList obsługuje zakresy, listy i mieszane" {
    var buf: [64]u32 = undefined;
    const a = try parseCpuList("0-3", &buf);
    try testing.expectEqual(@as(usize, 4), a.len);
    try testing.expectEqual(@as(u32, 3), a[3]);

    const b = try parseCpuList("0,2,4", &buf);
    try testing.expectEqual(@as(usize, 3), b.len);
    try testing.expectEqual(@as(u32, 4), b[2]);

    const c = try parseCpuList(" 0-1 , 8-9 \n", &buf);
    try testing.expectEqual(@as(usize, 4), c.len);
    try testing.expectEqual(@as(u32, 1), c[1]);
    try testing.expectEqual(@as(u32, 8), c[2]);
    try testing.expectEqual(@as(u32, 9), c[3]);

    const single = try parseCpuList("7", &buf);
    try testing.expectEqual(@as(usize, 1), single.len);
    try testing.expectEqual(@as(u32, 7), single[0]);
}

test "linux: parseCpuList odrzuca śmieci" {
    var buf: [64]u32 = undefined;
    try testing.expectError(error.BadCpuList, parseCpuList("abc", &buf));
    try testing.expectError(error.BadCpuList, parseCpuList("5-1", &buf));
    try testing.expectError(error.BadCpuList, parseCpuList("99999", &buf));
    // Za mało miejsca musi być zgłoszone, nie obcięte po cichu.
    var tiny: [2]u32 = undefined;
    try testing.expectError(error.NoSpace, parseCpuList("0-9", &tiny));
}

test "linux: CpuSet ustawia i liczy pojedyncze bity" {
    var s: CpuSet = .{};
    s.setOne(0);
    s.setOne(63);
    s.setOne(64);
    s.setOne(1023);
    try testing.expectEqual(@as(u32, 4), s.count());
    try testing.expect(s.has(0));
    try testing.expect(s.has(64));
    try testing.expect(s.has(1023));
    try testing.expect(!s.has(65));
    // Poza zakresem nic nie ustawiamy — cicho, bo to nie błąd wywołującego.
    s.setOne(1024);
    try testing.expectEqual(@as(u32, 4), s.count());
}

test "linux: backend deklaruje CPUID i przypinanie" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const b = create();
    try testing.expect(b.hasCpuid());
    try testing.expect(b.hasPinnedCpuid());
    try testing.expect(b.caps.has(.thread_affinity));
}

test "linux: CPUID na wskazanym CPU daje ten sam vendor" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const b = create();
    const here = try okOrSkip(backend.Regs, b.readCpuid(0, 0));
    const zero = try okOrSkip(backend.Regs, b.readCpuidOn(0, 0, 0));
    try testing.expectEqual(here.ebx, zero.ebx);
    try testing.expectEqual(here.ecx, zero.ecx);
    try testing.expectEqual(here.edx, zero.edx);
}

test "linux: affinity jest przywracana po błędzie" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const b = create();
    const before = try okOrSkip(u32, b.logicalCpuCount());
    // Wywołujemy świadomy błąd: CPU o numerze ponad zakres.
    const r = b.readCpuidOn(4096, 0, 0);
    try testing.expect(r.getStatus() != .ok);
    // Po błędzie procesor nadal powinien widzieć tę samą liczbę CPU, co wcześniej.
    const after = try okOrSkip(u32, b.logicalCpuCount());
    try testing.expectEqual(before, after);
}
