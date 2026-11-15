//! Odnośniki „Lookup” (jak w GPU-Z) i strony sterowników producentów.
//!
//! WYŁĄCZNIE odnośniki otwierane ręcznie przez użytkownika. FerrumScope nie
//! pobiera, nie parsuje i nie osadza danych TechPowerUp ani nikogo innego.
//!
//! Dlaczego nie wyszukiwanie po ID urządzenia: przycisk „Lookup” w GPU-Z
//! używa niepublicznego endpointu (`gpu-z.com/gpu-specs/lookup`), którego
//! format nie jest udokumentowany, a TechPowerUp publicznie odmówił
//! ułatwiania automatycznego ruchu do GPUDB. Budujemy więc tylko dwa rodzaje
//! linków, oba stabilne i jawne:
//!   1. lista bazy TechPowerUp filtrowana po producencie (`?mfgr=...`),
//!   2. wyszukiwanie nazwy w obrębie `techpowerup.com/gpu-specs` (lub
//!      `cpu-specs`) przez wyszukiwarkę — trafia na stronę karty po nazwie.
//! Nazwa i ID urządzenia nie są danymi osobowymi; numery seryjne nigdy
//! nie trafiają do URL.

const std = @import("std");
const report = @import("report.zig");
const ids = @import("../core/ids.zig");

/// Kodowanie procentowe zapytania (RFC 3986, spacja → `+`).
pub fn urlEncode(b: *report.Builder, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => out.append(b.arena, c) catch {},
            ' ' => out.append(b.arena, '+') catch {},
            else => {
                var t: [3]u8 = undefined;
                _ = std.fmt.bufPrint(&t, "%{X:0>2}", .{c}) catch {};
                out.appendSlice(b.arena, &t) catch {};
            },
        }
    }
    return out.items;
}

pub const amd_drivers = "https://www.amd.com/en/support/download/drivers.html";
pub const nvidia_drivers = "https://www.nvidia.com/en-us/drivers/";
pub const intel_drivers = "https://www.intel.com/content/www/us/en/support/detect.html";

fn mfgrOfPci(vendor: u16) ?[]const u8 {
    return switch (vendor) {
        0x1002, 0x1022 => "AMD",
        0x10DE => "NVIDIA",
        0x8086 => "Intel",
        else => null,
    };
}

pub fn gpu(b: *report.Builder, vendor: u16, name: []const u8) void {
    if (mfgrOfPci(vendor)) |m| {
        b.link(.{ .label = b.fmt("TechPowerUp GPU DB ({s})", .{m}), .url = b.fmt("https://www.techpowerup.com/gpu-specs/?mfgr={s}&sort=name", .{m}), .note = "lista bazy filtrowana po producencie" });
    }
    if (name.len > 0) {
        b.link(.{
            .label = "Szukaj karty w TechPowerUp",
            .url = b.fmt("https://duckduckgo.com/?q=site%3Atechpowerup.com%2Fgpu-specs+{s}", .{urlEncode(b, name)}),
            .note = "wyszukiwanie po nazwie; ID-lookup GPU-Z jest nieudokumentowany",
        });
    }
    switch (vendor) {
        0x1002, 0x1022 => b.link(.{ .label = "Sterowniki AMD", .url = amd_drivers }),
        0x10DE => b.link(.{ .label = "Sterowniki NVIDIA", .url = nvidia_drivers }),
        0x8086 => b.link(.{ .label = "Sterowniki Intel", .url = intel_drivers }),
        else => {},
    }
}

/// Jak `gpu`, ale każdy odnośnik oznaczony `scope` (np. nazwą karty), żeby GUI
/// mogło pokazać przyciski właściwej karty przy kilku GPU.
pub fn gpuScoped(b: *report.Builder, vendor: u16, name: []const u8, scope: []const u8) void {
    const first = b.page.links.items.len;
    gpu(b, vendor, name);
    for (b.page.links.items[first..]) |*l| l.scope = scope;
}

pub fn cpu(b: *report.Builder, vendor: ids.CpuVendor, name: []const u8) void {
    const m: ?[]const u8 = switch (vendor) {
        .amd => "AMD",
        .intel => "Intel",
        else => null,
    };
    if (m) |mm| b.link(.{ .label = b.fmt("TechPowerUp CPU DB ({s})", .{mm}), .url = b.fmt("https://www.techpowerup.com/cpu-specs/?mfgr={s}&sort=name", .{mm}) });
    if (name.len > 0) {
        b.link(.{ .label = "Szukaj CPU w TechPowerUp", .url = b.fmt("https://duckduckgo.com/?q=site%3Atechpowerup.com%2Fcpu-specs+{s}", .{urlEncode(b, name)}) });
    }
    switch (vendor) {
        .amd => b.link(.{ .label = "Sterowniki chipsetu AMD", .url = amd_drivers }),
        .intel => b.link(.{ .label = "Sterowniki Intel", .url = intel_drivers }),
        else => {},
    }
}

pub fn chipset(b: *report.Builder, vendor: u16) void {
    switch (vendor) {
        0x1022, 0x1002 => b.link(.{ .label = "Sterowniki chipsetu AMD", .url = amd_drivers }),
        0x8086 => b.link(.{ .label = "Sterowniki chipsetu Intel", .url = intel_drivers }),
        else => {},
    }
}

test "links: kodowanie URL i brak danych wrażliwych" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var page: report.Page = .{ .id = "x", .title = "x" };
    var b = report.Builder.init(arena.allocator(), &page);
    try std.testing.expectEqualStrings("AMD+Radeon+RX+7900+XTX%2F%26", urlEncode(&b, "AMD Radeon RX 7900 XTX/&"));
    gpu(&b, 0x1002, "AMD Radeon RX 7900 XTX");
    try std.testing.expectEqual(@as(usize, 3), page.links.items.len);
    try std.testing.expect(std.mem.startsWith(u8, page.links.items[0].url, "https://www.techpowerup.com/gpu-specs/?mfgr=AMD"));
}
