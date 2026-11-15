//! Backend natywny — jedyne miejsce w programie, które pyta system.
//!
//! Uruchamiany na Windows, Linux i macOS. Nie wie nic o GUI, bazie ani
//! dekodowaniu: wystawia wyłącznie prymitywy zgodne z `platform/backend.zig`.
//!
//! Rozdzielenie per system odbywa się **wyłącznie tutaj** (`builtin.os.tag`).
//! `core/`, `decode/` i `probe/` nie zawierają ani jednego `if windows`.

const std = @import("std");
const builtin = @import("builtin");
const backend = @import("backend.zig");
const status = @import("../core/status.zig");
const raw = @import("../core/raw.zig");
const cpuid = @import("../arch/x86/cpuid.zig");

// Wybór implementacji platformowej **wyłącznie** tu. `core/`, `decode/` i
// `probe/` nie zawierają ani jednego `if windows` / `if linux` — to jest cała
// raison d'être tego pliku.
const win_backend = @import("windows.zig");
const linux_backend = @import("linux.zig");

comptime {
    // Importujemy tylko moduł systemu, na którym budujemy. Dzięki temu build
    // pod Windows nie musi kompilować syscalli linuksowych i odwrotnie, a błędna
    // ścieżka nie może się „przypadkiem" skompilować.
    switch (@import("builtin").os.tag) {
        .windows => _ = win_backend,
        .linux => _ = linux_backend,
        else => {},
    }
}

pub fn cpuidRead(_: ?*anyopaque, leaf: u32, subleaf: u32) status.Result(backend.Regs) {
    const r = cpuid.execute(leaf, subleaf) orelse return .{
        .err = status.Failure.init(.unsupported, "CPUID niedostepne na tej architekturze"),
    };
    return .{ .ok = r };
}

/// Krótki opis systemu. Znamy tylko fakty architektoniczne (`builtin`), a nie
/// wersję marketingową — wersję doda etap 2, przez publiczne API platformy.
pub fn osInfo(_: ?*anyopaque, _: []u8) status.Result(backend.OsInfo) {
    var info = backend.OsInfo{};
    info.kind = switch (builtin.os.tag) {
        .windows => .windows,
        .linux, .freebsd, .netbsd, .openbsd => .linux,
        .macos, .ios, .tvos, .watchos => .macos,
        else => .unknown,
    };
    info.arch = switch (builtin.cpu.arch) {
        .x86 => .x86,
        .x86_64 => .x86_64,
        .aarch64, .arm => .arm64,
        .riscv64 => .riscv64,
        else => .other,
    };
    // Wersja identyfikuje budowę i model docelowy, nie wersję systemu.
    // Odczyt wersji systemu to zadanie Etapu 2 (publiczne API platformy).
    _ = std.fmt.bufPrint(&info.version, "{d}.{d}.{d}", .{
        @intFromEnum(builtin.os.tag),
        @intFromEnum(builtin.cpu.arch),
        @intFromEnum(builtin.abi),
    }) catch "unknown";
    return .{ .ok = info };
}

/// Tworzy backend natywny dla bieżącego procesu.
pub fn create() backend.Backend {
    return switch (@import("builtin").os.tag) {
        .windows => win_backend.create(),
        .linux => linux_backend.create(),
        else => createPortable(),
    };
}

/// Backend dla platform, dla których Etap 2 świadomie **nie** implementuje
/// przypinania wątku. Świadomy brak, a nie przypadkowy: macOS wymaga osobnego
/// podejścia (brak publicznego API do affinity per-processor), a Etap 2 ma
/// tylko Windows i Linux.
fn createPortable() backend.Backend {
    var caps = backend.CapabilitySet{};
    caps.add(.os_info);
    if (cpuid.execute(0, 0) != null) caps.add(.cpuid);
    return .{
        .name = "native-portable",
        .caps = caps,
        .ctx = null,
        .cpuid = cpuidRead,
        .os_info = osInfo,
    };
}

const testing = std.testing;

test "native: backend deklaruje CPUID na x86" {
    if (comptime !(builtin.cpu.arch == .x86 or builtin.cpu.arch == .x86_64)) {
        return error.SkipZigTest;
    }
    const b = create();
    try testing.expect(b.hasCpuid());
    try testing.expect(b.caps.has(.os_info));
    try testing.expect(b.readCpuid(0, 0).getStatus() == .ok);
}

test "native: leaf 0 zwraca maksymalne numery liści" {
    if (comptime !(builtin.cpu.arch == .x86 or builtin.cpu.arch == .x86_64)) {
        return error.SkipZigTest;
    }
    const b = create();
    const l0 = b.readCpuid(0, 0).unwrap().?;
    // Maksymalny liść podstawowy ma być >= 1, a extended >= 0x80000000.
    try testing.expect(l0.eax >= 1);
    const le = b.readCpuid(0x8000_0000, 0).unwrap().?;
    try testing.expect(le.eax >= 0x8000_0000);
}
