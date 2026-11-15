//! Plakietki producentów na zakładkach Płyta główna, Pamięć, Dyski i Grafika
//! (producent karty) — moduł czysty, bez Win32.
//!
//! Z wartości pól strony raportu (te same `report.Field`, które widzi okno)
//! wyznacza klucz producenta (`vendors.zig`), nazwę do rysowanej plakietki
//! i model. Łańcuch obrazów jest wspólny z `vendors.logoChain`:
//! obraz użytkownika `data\images\<kategoria>\<klucz>[-<model>].png` →
//! logo dołączone `assets/logos/<klucz>.png` → rysowana plakietka z nazwą.

const std = @import("std");
const forms = @import("forms.zig");
const vendors = @import("vendors.zig");

pub const Info = struct {
    /// Klucz producenta (`asrock`, `gskill`, …); null = nierozpoznany.
    key: ?[]const u8 = null,
    /// Nazwa na rysowanej plakietce (nazwa wyświetlana albo surowy napis).
    name: []const u8 = "",
    /// Model (do obrazu użytkownika `<klucz>-<model>.png` i podpisu).
    model: []const u8 = "",
};

/// Kategoria katalogu `data\images\<kategoria>\` dla plakietki producenta;
/// null dla plakietek CPU/GPU (te mają własny łańcuch w `badge.zig`).
pub fn category(k: forms.BadgeKind) ?vendors.Category {
    return switch (k) {
        .board => .board,
        .chipset => .chipset,
        .memory => .memory,
        .storage => .storage,
        .gpu_partner => .gpu,
        .cpu, .gpu => null,
    };
}

fn named(key: ?[]const u8, raw: []const u8, model: []const u8) Info {
    const k = key orelse return .{ .name = std.mem.trim(u8, raw, " \t"), .model = model };
    return .{ .key = k, .name = vendors.displayName(k), .model = model };
}

/// Płyta główna: producent z SMBIOS typ 2 („ASRock”, „ASUSTeK COMPUTER INC.”).
pub fn board(manufacturer: []const u8, product: []const u8) Info {
    return named(vendors.normalize(manufacturer), manufacturer, product);
}

/// Identyfikator producenta z początku pola surowego „vvvv:dddd …”.
fn leadingVid(raw: []const u8) ?u16 {
    if (raw.len < 4) return null;
    return std.fmt.parseInt(u16, raw[0..4], 16) catch null;
}

/// Chipset: producent z identyfikatora PCI (pole surowe „1022:43EE rev …”),
/// a gdy go brak — z nazwy („AMD 500 Series Chipset”).
pub fn chipset(raw_ids: []const u8, name: []const u8) Info {
    if (leadingVid(raw_ids)) |vid| if (vendors.pciVendor(vid)) |k| return named(k, name, "");
    return named(vendors.normalize(name), name, "");
}

/// Producent karty graficznej z podsystemu „vvvv:dddd” (pole „Subsystem”).
/// Karta referencyjna (podsystem = producent układu albo pusty) → producent układu.
pub fn gpuPartner(chip_vid: u16, subsys: []const u8) Info {
    const sv = leadingVid(subsys) orelse return .{};
    if (vendors.isReference(chip_vid, sv)) return named(vendors.pciVendor(chip_vid), "", "");
    return named(vendors.gpuPartner(sv), "", "");
}

/// Moduł pamięci: klucz wyznaczony już przez stronę (`report.MemSlot.vendor_key`).
pub fn memory(vendor_key: []const u8, vendor_name: []const u8, part_number: []const u8) Info {
    return named(if (vendor_key.len > 0) vendor_key else null, vendor_name, part_number);
}

/// Dysk: producent z nazwy modelu („WDC WD40EFRX”, „Samsung SSD 980 PRO 1TB”).
pub fn storage(model: []const u8) Info {
    return named(vendors.normalize(model), "", model);
}

// ---------------------------------------------------------------------------
// Testy: łańcuch obrazów dla każdej kategorii
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectChain(k: forms.BadgeKind, info: Info, first_image: []const u8, logo: []const u8) !void {
    var buf: vendors.ChainBuf = .{};
    const ch = vendors.logoChain(category(k).?, info.key, info.model, &buf);
    try testing.expect(ch.images.len > 0);
    try testing.expectEqualStrings(first_image, ch.images[0]);
    try testing.expect(ch.logos.len > 0);
    try testing.expectEqualStrings(logo, ch.logos[0]);
}

test "vendor_badge: łańcuch obrazów — płyta, chipset, pamięć, dysk, karta" {
    const b = board("ASRock", "B550 Taichi");
    try testing.expectEqualStrings("ASRock", b.name);
    try expectChain(.board, b, "board\\asrock-b550-taichi.png", "asrock");

    const c = chipset("1022:43EE rev 00", "AMD 500 Series Chipset");
    try testing.expectEqualStrings("amd", c.key.?);
    try expectChain(.chipset, c, "chipset\\amd.png", "amd");

    const m = memory("gskill", "G.SKILL", "F4-4000C18-16GTZR");
    try expectChain(.memory, m, "memory\\gskill-f4-4000c18-16gtzr.png", "gskill");

    const d = storage("Samsung SSD 980 PRO 1TB");
    try testing.expectEqualStrings("samsung", d.key.?);
    try expectChain(.storage, d, "storage\\samsung-samsung-ssd-980-pro-1tb.png", "samsung");

    const g = gpuPartner(0x1002, "1849:5304");
    try testing.expectEqualStrings("asrock", g.key.?);
    try expectChain(.gpu_partner, g, "gpu\\asrock.png", "asrock");

    // Karta referencyjna: producent układu.
    try testing.expectEqualStrings("amd", gpuPartner(0x1002, "1002:0E3B").key.?);
}

test "vendor_badge: nierozpoznany producent — sama nazwa, bez logo" {
    const b = board("Nieznana Firma Sp. z o.o.", "X1");
    try testing.expect(b.key == null);
    try testing.expectEqualStrings("Nieznana Firma Sp. z o.o.", b.name);
    var buf: vendors.ChainBuf = .{};
    const ch = vendors.logoChain(.board, b.key, b.model, &buf);
    try testing.expectEqual(@as(usize, 0), ch.logos.len);
    try testing.expectEqualStrings("board\\x1.png", ch.images[0]);
    try testing.expect(gpuPartner(0x1002, "").key == null);
}
