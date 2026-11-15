//! Identyfikatory i numeracja x86.
//!
//! Numeracja CPUID (family/model/stepping) jest tu rozwinięta ręcznie, a nie
//! „zrób `eax & 0xF`". Powód: reguła z Intel SDM i AMD APM mówi, że bity
//! rozszerzone wchodzą w numerację **warunkowo** — tylko dla określonych rodzin.
//! Pominięcie warunku daje błędne `model` dla Zen i dla większości Inteli
//! (np. Skylake to Model 0x5E, a nie 0x0E).

const std = @import("std");

/// Producent CPU rozpoznany po ciągu z CPUID leaf 0.
pub const CpuVendor = enum {
    intel,
    amd,
    // Zdarzają się w serwerach; nie zaimplementowaliśmy jeszcze ich dekodera,
    // ale rozpoznajemy je, żeby raportować „znany producent, brak wpisu w bazie”
    // zamiast „nieznany sprzęt".
    hygon,
    via,
    zhaoxin,
    unknown,
    /// Nieprzypisany identyfikator (gdy dekodujemy z pliku capture, nie z CPUID).
    other,

    /// Kolejność bajtów CPUID to EBX, EDX, ECX (nie pamiętaj, to nie jest ASCII).
    pub fn fromLeaf0(bx: u32, dx: u32, cx: u32) CpuVendor {
        // Kolejność bajtów to EBX, EDX, ECX — to NIE jest ASCII.
        const v = [12]u8{
            @truncate(bx & 0xFF),         @truncate((bx >> 8) & 0xFF),
            @truncate((bx >> 16) & 0xFF), @truncate((bx >> 24) & 0xFF),
            @truncate(dx & 0xFF),         @truncate((dx >> 8) & 0xFF),
            @truncate((dx >> 16) & 0xFF), @truncate((dx >> 24) & 0xFF),
            @truncate(cx & 0xFF),         @truncate((cx >> 8) & 0xFF),
            @truncate((cx >> 16) & 0xFF), @truncate((cx >> 24) & 0xFF),
        };
        inline for (.{
            .{ "GenuineIntel", CpuVendor.intel },
            .{ "AuthenticAMD", CpuVendor.amd },
            .{ "HygonGenuine", CpuVendor.hygon },
            .{ "CentaurHauls", CpuVendor.via },
            .{ "  Shanghai  ", CpuVendor.zhaoxin },
        }) |pair| {
            if (std.mem.eql(u8, &v, pair[0])) return pair[1];
        }
        return .unknown;
    }

    pub fn toSlice(self: CpuVendor) []const u8 {
        return switch (self) {
            .intel => "Intel",
            .amd => "AMD",
            .hygon => "Hygon",
            .via => "VIA",
            .zhaoxin => "Zhaoxin",
            .unknown => "unknown",
            .other => "other",
        };
    }
};

/// Pola CPUID leaf 1, EAX — bez interpretacji.
pub const Signature = struct {
    eax: u32,

    pub const steppings_bits: u4 = 0xF;
    pub const model_bits: u4 = 0xF;
    pub const family_bits: u4 = 0xF;
    pub const ext_model_bits: u4 = 0xF;
    pub const ext_family_bits: u8 = 0xFF;

    pub fn fromEax(eax: u32) Signature {
        return .{ .eax = eax };
    }

    pub fn stepping(self: Signature) u8 {
        return @truncate(self.eax & 0xF);
    }
    /// `family` w znaczeniu Intel SDM: pole 4-bitowe, **bez** rozszerzenia.
    pub fn familyField(self: Signature) u8 {
        return @truncate((self.eax >> 8) & 0xF);
    }
    /// `model` w znaczeniu Intel SDM: pole 4-bitowe, **bez** rozszerzenia.
    pub fn modelField(self: Signature) u8 {
        return @truncate((self.eax >> 4) & 0xF);
    }
    pub fn extModel(self: Signature) u8 {
        return @truncate((self.eax >> 16) & 0xF);
    }
    pub fn extFamily(self: Signature) u8 {
        return @truncate((self.eax >> 20) & 0xFF);
    }
    pub fn processorType(self: Signature) u8 {
        return @truncate((self.eax >> 12) & 0x3);
    }
    pub fn hasApic(self: Signature) bool {
        return (self.eax & (1 << 9)) != 0;
    }
    pub fn isHtt(self: Signature) bool {
        return (self.eax & (1 << 28)) != 0;
    }

    /// Rodzina „wyświetlana" — ta, którą producent podaje w dokumentacji.
    /// Rozszerzenie dochodzi wyłącznie dla rodziny 0x0F.
    pub fn displayFamily(self: Signature) u8 {
        if (self.familyField() == 0x0F) {
            return self.familyField() +% self.extFamily();
        }
        return self.familyField();
    }

    /// Model „wyświetlany". Rozszerzenie dochodzi dla rodzin 0x0F oraz 0x06
    /// (K10/K11 i cała generacja Core od Westmere w górę).
    pub fn displayModel(self: Signature) u8 {
        return switch (self.familyField()) {
            0x0F, 0x06 => (self.extModel() << 4) +% self.modelField(),
            else => self.modelField(),
        };
    }

    /// Klucz do dopasowania w bazie. Świadomie **nie** jest tożsamy z
    /// `displayFamily/displayModel`: baza trzyma oba warianty, żeby dało się
    /// opisać wyjątki (np. rodzinę 0x06 z nietypowym ext_model).
    pub fn rawKey(self: Signature) u64 {
        return (@as(u64, self.extFamily()) << 32) |
            (@as(u64, self.familyField()) << 24) |
            (@as(u64, self.extModel()) << 16) |
            (@as(u64, self.modelField()) << 8) |
            self.stepping();
    }
};

test "numeracja: Intel Skylake to Family 6 Model 0x5E" {
    const s = Signature.fromEax(0x000506E3);
    try std.testing.expectEqual(@as(u8, 0x06), s.familyField());
    try std.testing.expectEqual(@as(u8, 0x5E), s.displayModel());
    try std.testing.expectEqual(@as(u8, 6), s.displayFamily());
    try std.testing.expectEqual(@as(u8, 3), s.stepping());
}

test "numeracja: Intel Pentium III (family 6) bez rozszerzenia modelu" {
    const s = Signature.fromEax(0x000006B1);
    try std.testing.expectEqual(@as(u8, 0x0B), s.displayModel());
    try std.testing.expectEqual(@as(u8, 6), s.displayFamily());
}

test "numeracja: AMD Zen to Family 17h Model 01h" {
    const s = Signature.fromEax(0x00800F12);
    try std.testing.expectEqual(@as(u8, 0x0F), s.familyField());
    try std.testing.expectEqual(@as(u8, 0x17), s.displayFamily());
    try std.testing.expectEqual(@as(u8, 0x01), s.displayModel());
}

test "numeracja: AMD Zen 2 używa rozszerzonego modelu" {
    const s = Signature.fromEax(0x00830F11);
    try std.testing.expectEqual(@as(u8, 0x17), s.displayFamily());
    try std.testing.expectEqual(@as(u8, 0x31), s.displayModel());
}

test "rodzina 0x0F bez rozszerzenia nie wycieka pól wyższych" {
    const s = Signature.fromEax(0x000F0FF0);
    try std.testing.expectEqual(@as(u8, 0x0F), s.displayFamily());
}

test "producent: kolejność bajtów CPUID to EBX, EDX, ECX" {
    // "GenuineIntel" = EBX 0x756E6547, EDX 0x49656E69, ECX 0x6C65746E
    try std.testing.expectEqual(CpuVendor.intel, CpuVendor.fromLeaf0(0x756E6547, 0x49656E69, 0x6C65746E));
    // "AuthenticAMD" = EBX 0x68747541, EDX 0x69746E65, ECX 0x444D4163
    try std.testing.expectEqual(CpuVendor.amd, CpuVendor.fromLeaf0(0x68747541, 0x69746E65, 0x444D4163));
    try std.testing.expectEqual(CpuVendor.unknown, CpuVendor.fromLeaf0(0, 0, 0));
}
