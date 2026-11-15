//! Pełna lista rozszerzeń zestawu instrukcji x86 — dekodowana wprost z obrazu
//! CPUID (`raw.CpuidImage`), z podaniem liścia, rejestru i bitu dla każdej
//! pozycji. Lista jest danymi (tablica `table`), nie łańcuchem `if`-ów.
//!
//! Źródła bitów: Intel SDM Vol. 2A, „CPUID — CPU Identification”
//! (Table 3-8, 3-10 i liść 07H) oraz AMD64 APM Vol. 3, Appendix E
//! („Obtaining Processor Information Via the CPUID Instruction”).
//!
//! Poziomy x86-64-v2/v3/v4 — według „x86-64 psABI”, rozdz. 3.1.1
//! (Micro-Architecture Levels). Poziom jest **wyprowadzony** z bitów, nie
//! odczytany; tak też jest oznaczany.
//!
//! VT-x (VMX) i AMD-V (SVM) bywają **ukryte** przez hypervisor (np. Hyper-V
//! z włączonym VBS): wtedy bit jest 0, choć procesor je ma. Bit 31 ECX
//! liścia 1 mówi, że działamy pod hypervisorem — wtedy to zaznaczamy.

const std = @import("std");
const raw = @import("../core/raw.zig");
const i18n = @import("../i18n/i18n.zig");

pub const Reg = enum { eax, ebx, ecx, edx };

pub const Group = enum {
    base,
    simd,
    avx512,
    crypto,
    virtualization,
    bitmanip,
    memory,
    security,
    other,

    pub fn label(self: Group) []const u8 {
        return switch (self) {
            .base => i18n.t("Podstawowe / 64-bit"),
            .simd => i18n.t("SIMD (MMX / SSE / AVX)"),
            .avx512 => i18n.t("AVX-512 / AMX"),
            .crypto => i18n.t("Kryptografia"),
            .virtualization => i18n.t("Wirtualizacja"),
            .bitmanip => i18n.t("Operacje bitowe"),
            .memory => i18n.t("Pamięć / cache"),
            .security => i18n.t("Bezpieczeństwo"),
            .other => i18n.t("Inne"),
        };
    }
};

pub const Bit = struct {
    name: []const u8,
    group: Group,
    leaf: u32,
    sub: u32 = 0,
    reg: Reg,
    bit: u5,
    /// Tylko u tego producenta (np. 3DNow!). `null` = oba.
    vendor_only: ?enum { intel, amd } = null,
};

/// Tabela bitów. Kolejność = kolejność wyświetlania (jak w CPU-Z: od MMX).
pub const table = [_]Bit{
    // --- podstawowe ----------------------------------------------------------
    .{ .name = "MMX", .group = .simd, .leaf = 1, .reg = .edx, .bit = 23 },
    .{ .name = "MMX+", .group = .simd, .leaf = 0x80000001, .reg = .edx, .bit = 22, .vendor_only = .amd },
    .{ .name = "3DNow!", .group = .simd, .leaf = 0x80000001, .reg = .edx, .bit = 31, .vendor_only = .amd },
    .{ .name = "3DNow!+", .group = .simd, .leaf = 0x80000001, .reg = .edx, .bit = 30, .vendor_only = .amd },
    .{ .name = "SSE", .group = .simd, .leaf = 1, .reg = .edx, .bit = 25 },
    .{ .name = "SSE2", .group = .simd, .leaf = 1, .reg = .edx, .bit = 26 },
    .{ .name = "SSE3", .group = .simd, .leaf = 1, .reg = .ecx, .bit = 0 },
    .{ .name = "SSSE3", .group = .simd, .leaf = 1, .reg = .ecx, .bit = 9 },
    .{ .name = "SSE4.1", .group = .simd, .leaf = 1, .reg = .ecx, .bit = 19 },
    .{ .name = "SSE4.2", .group = .simd, .leaf = 1, .reg = .ecx, .bit = 20 },
    .{ .name = "SSE4A", .group = .simd, .leaf = 0x80000001, .reg = .ecx, .bit = 6, .vendor_only = .amd },
    .{ .name = "x86-64", .group = .base, .leaf = 0x80000001, .reg = .edx, .bit = 29 },
    .{ .name = "NX", .group = .security, .leaf = 0x80000001, .reg = .edx, .bit = 20 },
    .{ .name = "CMPXCHG16B", .group = .base, .leaf = 1, .reg = .ecx, .bit = 13 },
    .{ .name = "LAHF/SAHF", .group = .base, .leaf = 0x80000001, .reg = .ecx, .bit = 0 },
    .{ .name = "POPCNT", .group = .bitmanip, .leaf = 1, .reg = .ecx, .bit = 23 },
    .{ .name = "LZCNT/ABM", .group = .bitmanip, .leaf = 0x80000001, .reg = .ecx, .bit = 5 },
    .{ .name = "MOVBE", .group = .base, .leaf = 1, .reg = .ecx, .bit = 22 },
    .{ .name = "RDTSCP", .group = .base, .leaf = 0x80000001, .reg = .edx, .bit = 27 },
    .{ .name = "XSAVE", .group = .base, .leaf = 1, .reg = .ecx, .bit = 26 },
    // --- wirtualizacja ---------------------------------------------------------
    .{ .name = "VT-x", .group = .virtualization, .leaf = 1, .reg = .ecx, .bit = 5 },
    .{ .name = "AMD-V", .group = .virtualization, .leaf = 0x80000001, .reg = .ecx, .bit = 2, .vendor_only = .amd },
    // --- AVX -------------------------------------------------------------------
    .{ .name = "AVX", .group = .simd, .leaf = 1, .reg = .ecx, .bit = 28 },
    .{ .name = "AVX2", .group = .simd, .leaf = 7, .reg = .ebx, .bit = 5 },
    .{ .name = "FMA3", .group = .simd, .leaf = 1, .reg = .ecx, .bit = 12 },
    .{ .name = "FMA4", .group = .simd, .leaf = 0x80000001, .reg = .ecx, .bit = 16, .vendor_only = .amd },
    .{ .name = "XOP", .group = .simd, .leaf = 0x80000001, .reg = .ecx, .bit = 11, .vendor_only = .amd },
    .{ .name = "F16C", .group = .simd, .leaf = 1, .reg = .ecx, .bit = 29 },
    .{ .name = "AVX-VNNI", .group = .simd, .leaf = 7, .sub = 1, .reg = .eax, .bit = 4 },
    .{ .name = "AVX-IFMA", .group = .simd, .leaf = 7, .sub = 1, .reg = .eax, .bit = 23 },
    // --- AVX-512 / AMX -----------------------------------------------------------
    .{ .name = "AVX512F", .group = .avx512, .leaf = 7, .reg = .ebx, .bit = 16 },
    .{ .name = "AVX512DQ", .group = .avx512, .leaf = 7, .reg = .ebx, .bit = 17 },
    .{ .name = "AVX512IFMA", .group = .avx512, .leaf = 7, .reg = .ebx, .bit = 21 },
    .{ .name = "AVX512PF", .group = .avx512, .leaf = 7, .reg = .ebx, .bit = 26 },
    .{ .name = "AVX512ER", .group = .avx512, .leaf = 7, .reg = .ebx, .bit = 27 },
    .{ .name = "AVX512CD", .group = .avx512, .leaf = 7, .reg = .ebx, .bit = 28 },
    .{ .name = "AVX512BW", .group = .avx512, .leaf = 7, .reg = .ebx, .bit = 30 },
    .{ .name = "AVX512VL", .group = .avx512, .leaf = 7, .reg = .ebx, .bit = 31 },
    .{ .name = "AVX512VBMI", .group = .avx512, .leaf = 7, .reg = .ecx, .bit = 1 },
    .{ .name = "AVX512VBMI2", .group = .avx512, .leaf = 7, .reg = .ecx, .bit = 6 },
    .{ .name = "AVX512VNNI", .group = .avx512, .leaf = 7, .reg = .ecx, .bit = 11 },
    .{ .name = "AVX512BITALG", .group = .avx512, .leaf = 7, .reg = .ecx, .bit = 12 },
    .{ .name = "AVX512VPOPCNTDQ", .group = .avx512, .leaf = 7, .reg = .ecx, .bit = 14 },
    .{ .name = "AVX512VP2INTERSECT", .group = .avx512, .leaf = 7, .reg = .edx, .bit = 8 },
    .{ .name = "AVX512FP16", .group = .avx512, .leaf = 7, .reg = .edx, .bit = 23 },
    .{ .name = "AVX512BF16", .group = .avx512, .leaf = 7, .sub = 1, .reg = .eax, .bit = 5 },
    .{ .name = "AMX-BF16", .group = .avx512, .leaf = 7, .reg = .edx, .bit = 22 },
    .{ .name = "AMX-TILE", .group = .avx512, .leaf = 7, .reg = .edx, .bit = 24 },
    .{ .name = "AMX-INT8", .group = .avx512, .leaf = 7, .reg = .edx, .bit = 25 },
    // --- kryptografia ------------------------------------------------------------
    .{ .name = "AES", .group = .crypto, .leaf = 1, .reg = .ecx, .bit = 25 },
    .{ .name = "PCLMULQDQ", .group = .crypto, .leaf = 1, .reg = .ecx, .bit = 1 },
    .{ .name = "SHA", .group = .crypto, .leaf = 7, .reg = .ebx, .bit = 29 },
    .{ .name = "VAES", .group = .crypto, .leaf = 7, .reg = .ecx, .bit = 9 },
    .{ .name = "VPCLMULQDQ", .group = .crypto, .leaf = 7, .reg = .ecx, .bit = 10 },
    .{ .name = "GFNI", .group = .crypto, .leaf = 7, .reg = .ecx, .bit = 8 },
    .{ .name = "RDRAND", .group = .crypto, .leaf = 1, .reg = .ecx, .bit = 30 },
    .{ .name = "RDSEED", .group = .crypto, .leaf = 7, .reg = .ebx, .bit = 18 },
    // --- operacje bitowe -----------------------------------------------------------
    .{ .name = "BMI1", .group = .bitmanip, .leaf = 7, .reg = .ebx, .bit = 3 },
    .{ .name = "BMI2", .group = .bitmanip, .leaf = 7, .reg = .ebx, .bit = 8 },
    .{ .name = "ADX", .group = .bitmanip, .leaf = 7, .reg = .ebx, .bit = 19 },
    .{ .name = "TBM", .group = .bitmanip, .leaf = 0x80000001, .reg = .ecx, .bit = 21, .vendor_only = .amd },
    // --- pamięć / cache -----------------------------------------------------------
    .{ .name = "ERMS", .group = .memory, .leaf = 7, .reg = .ebx, .bit = 9 },
    .{ .name = "FSRM", .group = .memory, .leaf = 7, .reg = .edx, .bit = 4 },
    .{ .name = "CLFLUSHOPT", .group = .memory, .leaf = 7, .reg = .ebx, .bit = 23 },
    .{ .name = "CLWB", .group = .memory, .leaf = 7, .reg = .ebx, .bit = 24 },
    .{ .name = "MOVDIRI", .group = .memory, .leaf = 7, .reg = .ecx, .bit = 27 },
    .{ .name = "MOVDIR64B", .group = .memory, .leaf = 7, .reg = .ecx, .bit = 28 },
    .{ .name = "1 GB pages", .group = .memory, .leaf = 0x80000001, .reg = .edx, .bit = 26 },
    .{ .name = "RTM (TSX)", .group = .memory, .leaf = 7, .reg = .ebx, .bit = 11 },
    // --- bezpieczeństwo ---------------------------------------------------------
    .{ .name = "SMEP", .group = .security, .leaf = 7, .reg = .ebx, .bit = 7 },
    .{ .name = "SMAP", .group = .security, .leaf = 7, .reg = .ebx, .bit = 20 },
    .{ .name = "UMIP", .group = .security, .leaf = 7, .reg = .ecx, .bit = 2 },
    .{ .name = "PKU", .group = .security, .leaf = 7, .reg = .ecx, .bit = 3 },
    .{ .name = "CET-SS", .group = .security, .leaf = 7, .reg = .ecx, .bit = 7 },
    .{ .name = "CET-IBT", .group = .security, .leaf = 7, .reg = .edx, .bit = 20 },
    .{ .name = "SGX", .group = .security, .leaf = 7, .reg = .ebx, .bit = 2 },
    // --- inne -------------------------------------------------------------------
    .{ .name = "RDPID", .group = .other, .leaf = 7, .reg = .ecx, .bit = 22 },
    .{ .name = "SERIALIZE", .group = .other, .leaf = 7, .reg = .edx, .bit = 14 },
    .{ .name = "HYBRID", .group = .other, .leaf = 7, .reg = .edx, .bit = 15 },
    .{ .name = "EIST", .group = .other, .leaf = 1, .reg = .ecx, .bit = 7, .vendor_only = .intel },
    .{ .name = "HTT", .group = .other, .leaf = 1, .reg = .edx, .bit = 28 },
};

pub const max_bits = table.len;

pub const Level = enum {
    unknown,
    v1,
    v2,
    v3,
    v4,

    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .unknown => "—",
            .v1 => "x86-64 (v1)",
            .v2 => "x86-64-v2",
            .v3 => "x86-64-v3",
            .v4 => "x86-64-v4",
        };
    }
};

pub const Result = struct {
    present: [max_bits]bool = @splat(false),
    count: usize = 0,
    level: Level = .unknown,
    /// CPUID.1:ECX[31] — działamy pod hypervisorem; VT-x/AMD-V mogą być ukryte.
    hypervisor: bool = false,

    pub fn has(self: *const Result, name: []const u8) bool {
        for (table, 0..) |b, i| {
            if (std.mem.eql(u8, b.name, name)) return self.present[i];
        }
        return false;
    }
};

fn regOf(r: raw.Regs, reg: Reg) u32 {
    return switch (reg) {
        .eax => r.eax,
        .ebx => r.ebx,
        .ecx => r.ecx,
        .edx => r.edx,
    };
}

fn bitSet(img: *const raw.CpuidImage, leaf: u32, sub: u32, reg: Reg, bit: u5) bool {
    const r = img.getBounded(leaf, sub) orelse return false;
    return (regOf(r, reg) >> bit) & 1 == 1;
}

pub fn decode(img: *const raw.CpuidImage) Result {
    var out: Result = .{};
    for (table, 0..) |b, i| {
        if (bitSet(img, b.leaf, b.sub, b.reg, b.bit)) {
            out.present[i] = true;
            out.count += 1;
        }
    }
    out.hypervisor = bitSet(img, 1, 0, .ecx, 31);
    out.level = level(&out, img);
    return out;
}

/// psABI 3.1.1. v1: CMOV, CX8, FPU, FXSR, MMX, OSFXSR, SCE, SSE, SSE2 — sprawdzamy
/// bit long mode + SSE2 (reszta jest obowiązkowa w każdym CPU z LM).
fn level(r: *const Result, img: *const raw.CpuidImage) Level {
    if (!(r.has("x86-64") and r.has("SSE2"))) return .unknown;
    const v2 = r.has("CMPXCHG16B") and r.has("LAHF/SAHF") and r.has("POPCNT") and
        r.has("SSE3") and r.has("SSE4.1") and r.has("SSE4.2") and r.has("SSSE3");
    if (!v2) return .v1;
    // OSXSAVE (1:ECX[27]) jest wymagany przez v3 obok bitów AVX.
    const osxsave = bitSet(img, 1, 0, .ecx, 27);
    const v3 = r.has("AVX") and r.has("AVX2") and r.has("BMI1") and r.has("BMI2") and
        r.has("F16C") and r.has("FMA3") and r.has("LZCNT/ABM") and r.has("MOVBE") and osxsave;
    if (!v3) return .v2;
    const v4 = r.has("AVX512F") and r.has("AVX512BW") and r.has("AVX512CD") and
        r.has("AVX512DQ") and r.has("AVX512VL");
    return if (v4) .v4 else .v3;
}

/// Lista nazw obecnych rozszerzeń w kolejności tabeli, rozdzielona `, `.
pub fn joinPresent(r: *const Result, buf: []u8, group: ?Group) []const u8 {
    var n: usize = 0;
    for (table, 0..) |b, i| {
        if (!r.present[i]) continue;
        if (group) |g| if (b.group != g) continue;
        const sep: []const u8 = if (n > 0) ", " else "";
        if (n + sep.len + b.name.len > buf.len) break;
        @memcpy(buf[n..][0..sep.len], sep);
        n += sep.len;
        @memcpy(buf[n..][0..b.name.len], b.name);
        n += b.name.len;
    }
    return buf[0..n];
}

pub fn sourceOf(b: Bit, buf: []u8) []const u8 {
    if (b.sub != 0) {
        return std.fmt.bufPrint(buf, "CPUID 0x{X}.{d} {s}[{d}]", .{ b.leaf, b.sub, @tagName(b.reg), b.bit }) catch "CPUID";
    }
    return std.fmt.bufPrint(buf, "CPUID 0x{X} {s}[{d}]", .{ b.leaf, @tagName(b.reg), b.bit }) catch "CPUID";
}

// ---------------------------------------------------------------------------
// Testy — obrazy CPUID budowane ręcznie (bity wg SDM/APM).
// ---------------------------------------------------------------------------

const testing = std.testing;

fn zen3Image() raw.CpuidImage {
    var img: raw.CpuidImage = .{ .max_basic = 0x10, .max_extended = 0x80000020 };
    // Bity zgodne z publicznymi zrzutami CPUID Ryzen 5000 (Zen 3).
    img.add(1, 0, .{ .eax = 0x00A20F12, .ebx = 0, .ecx = 0x7ED8320B, .edx = 0x178BFBFF });
    img.add(7, 0, .{ .eax = 0, .ebx = 0x219C97A9, .ecx = 0x0040069C, .edx = 0x00000010 });
    img.add(0x80000001, 0, .{ .eax = 0, .ebx = 0, .ecx = 0x75C237FF, .edx = 0x2FD3FBFF });
    return img;
}

test "isa: Zen 3 — x86-64-v3, AES, SHA, AMD-V, brak AVX-512" {
    const img = zen3Image();
    const r = decode(&img);
    try testing.expect(r.has("MMX"));
    try testing.expect(r.has("x86-64"));
    try testing.expect(r.has("AVX2"));
    try testing.expect(r.has("AES"));
    try testing.expect(r.has("SHA"));
    try testing.expect(r.has("VAES"));
    try testing.expect(r.has("AMD-V"));
    try testing.expect(!r.has("AVX512F"));
    try testing.expectEqual(Level.v3, r.level);
    var buf: [512]u8 = undefined;
    const s = joinPresent(&r, &buf, null);
    try testing.expect(std.mem.startsWith(u8, s, "MMX, MMX+"));
}

test "isa: hypervisor ukrywa VT-x — flaga jest ustawiona" {
    var img: raw.CpuidImage = .{ .max_basic = 1, .max_extended = 0x80000001 };
    img.add(1, 0, .{ .eax = 0x000906EA, .ebx = 0, .ecx = 0x80000000 | (1 << 0) | (1 << 23), .edx = (1 << 23) | (1 << 25) | (1 << 26) });
    const r = decode(&img);
    try testing.expect(r.hypervisor);
    try testing.expect(!r.has("VT-x"));
    try testing.expect(r.has("MMX"));
    try testing.expectEqual(Level.unknown, r.level); // brak liścia 0x80000001 z LM
}

test "isa: pusty obraz nie wywraca dekodera" {
    const img: raw.CpuidImage = .{};
    const r = decode(&img);
    try testing.expectEqual(@as(usize, 0), r.count);
    try testing.expectEqual(Level.unknown, r.level);
}

test "isa: źródło bitu jest czytelne" {
    var buf: [64]u8 = undefined;
    for (table) |b| {
        if (std.mem.eql(u8, b.name, "AVX512BF16")) {
            try testing.expectEqualStrings("CPUID 0x7.1 eax[5]", sourceOf(b, &buf));
            return;
        }
    }
    return error.TestUnexpectedResult;
}
