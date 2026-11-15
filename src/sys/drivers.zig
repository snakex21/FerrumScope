//! Odnośniki „Pobierz sterowniki” — dokładna strona producenta, gdy da się ją
//! ustalić, inaczej strona ogólna. Wyłącznie odnośniki (nic nie pobieramy).
//!
//! Kolejność (jak w `lookup.zig`):
//!   1. link przypięty przez użytkownika — `data\driver_links.toml`,
//!   2. tabela kuratorowana — `db/source/links/drivers.toml` (`source = "manual"`),
//!   3. adres **wyprowadzony** z wykrytych danych (AMD ma przewidywalne adresy:
//!      `…/drivers.html/chipsets/<gniazdo>/<chipset>.html`,
//!      `…/drivers.html/graphics/radeon-rx/radeon-rx-<seria>-series/amd-radeon-rx-<model>.html`),
//!   4. ogólna strona sterowników producenta.
//!
//! Format plików TOML:
//! ```toml
//! [[chipset]]
//! model = "am4/b550"        # gniazdo/chipset, małe litery
//! url = "https://www.amd.com/en/support/downloads/drivers.html/chipsets/am4/b550.html"
//! source = "manual"
//!
//! [[gpu]]
//! model = "radeon rx 7900 xtx"   # lookup.normalizeGpu
//! url = "https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-7000-series/amd-radeon-rx-7900-xtx.html"
//! source = "manual"
//! ```

const std = @import("std");

pub const amd_base = "https://www.amd.com/en/support/downloads/drivers.html";
pub const amd_generic = "https://www.amd.com/en/support/download/drivers.html";
pub const nvidia_search = "https://www.nvidia.com/en-us/drivers/";
pub const intel_dsa = "https://www.intel.com/content/www/us/en/support/detect.html";

pub const Kind = enum { chipset, gpu };

pub const Entry = struct {
    kind: Kind,
    model: []const u8 = "",
    url: []const u8 = "",
    source: []const u8 = "",
};

pub const Origin = enum { user, curated, derived, generic };

pub const Resolved = struct { url: []const u8, origin: Origin };

pub const Tables = struct {
    user: []const Entry = &.{},
    curated: []const Entry = &.{},
};

// ---------------------------------------------------------------------------
// Chipset AMD: gniazdo + model z nazwy płyty / SMBIOS / serii chipsetu
// ---------------------------------------------------------------------------

pub const AmdChipset = struct {
    socket: []const u8, // "am4", "am5"
    model: [8]u8 = undefined,
    model_len: usize = 0,

    pub fn modelSlice(self: *const AmdChipset) []const u8 {
        return self.model[0..self.model_len];
    }
};

/// Chipsety AMD dla platform konsumenckich i ich gniazda.
const amd_chipsets = [_]struct { name: []const u8, socket: []const u8 }{
    .{ .name = "a320", .socket = "am4" },  .{ .name = "b350", .socket = "am4" },  .{ .name = "x370", .socket = "am4" },
    .{ .name = "b450", .socket = "am4" },  .{ .name = "x470", .socket = "am4" },  .{ .name = "a520", .socket = "am4" },
    .{ .name = "b550", .socket = "am4" },  .{ .name = "x570", .socket = "am4" },  .{ .name = "a620", .socket = "am5" },
    .{ .name = "b650", .socket = "am5" },  .{ .name = "b650e", .socket = "am5" }, .{ .name = "x670", .socket = "am5" },
    .{ .name = "x670e", .socket = "am5" }, .{ .name = "b840", .socket = "am5" },  .{ .name = "b850", .socket = "am5" },
    .{ .name = "x870", .socket = "am5" },  .{ .name = "x870e", .socket = "am5" }, .{ .name = "trx40", .socket = "strx4" },
};

/// Model chipsetu z nazwy płyty (SMBIOS typ 2 „Product”, np. „B550 Taichi”,
/// „ROG STRIX X670E-E GAMING WIFI”) — dopasowanie całych tokenów do tabeli.
pub fn amdChipsetFromBoard(product: []const u8) ?AmdChipset {
    var it = std.mem.tokenizeAny(u8, product, " -_/()");
    var best: ?AmdChipset = null;
    while (it.next()) |tok| {
        if (tok.len < 4 or tok.len > 6) continue;
        var low: [8]u8 = undefined;
        for (tok, 0..) |c, i| low[i] = std.ascii.toLower(c);
        const l = low[0..tok.len];
        for (amd_chipsets) |cs| {
            if (std.mem.eql(u8, cs.name, l)) {
                var r: AmdChipset = .{ .socket = cs.socket, .model_len = l.len };
                @memcpy(r.model[0..l.len], l);
                // Dłuższa nazwa wygrywa (X670E przed X670).
                if (best == null or best.?.model_len < r.model_len) best = r;
            }
        }
    }
    return best;
}

pub fn amdChipsetUrl(buf: []u8, c: AmdChipset) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/chipsets/{s}/{s}.html", .{ amd_base, c.socket, c.modelSlice() }) catch amd_generic;
}

// ---------------------------------------------------------------------------
// Radeon RX: seria + slug modelu
// ---------------------------------------------------------------------------

/// „AMD Radeon RX 7900 XTX” → seria `radeon-rx-7000-series`, model
/// `amd-radeon-rx-7900-xtx`. Tylko karty Radeon RX z 4-cyfrowym numerem.
pub fn amdGpuUrl(buf: []u8, name: []const u8) ?[]const u8 {
    var low: [96]u8 = undefined;
    if (name.len > low.len) return null;
    for (name, 0..) |c, i| low[i] = std.ascii.toLower(c);
    const s = low[0..name.len];
    const at = std.mem.indexOf(u8, s, "radeon rx ") orelse return null;
    const rest = std.mem.trim(u8, s[at + "radeon rx ".len ..], " ");
    if (rest.len < 4 or !std.ascii.isDigit(rest[0])) return null;
    for (rest[0..4]) |c| if (!std.ascii.isDigit(c)) return null;
    const gen = rest[0];
    if (gen != '5' and gen != '6' and gen != '7' and gen != '9') return null;
    var slug: [64]u8 = undefined;
    var n: usize = 0;
    var dash = false;
    for (rest) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (dash and n > 0) {
                slug[n] = '-';
                n += 1;
            }
            dash = false;
            if (n >= slug.len - 1) break;
            slug[n] = c;
            n += 1;
        } else dash = true;
    }
    return std.fmt.bufPrint(buf, "{s}/graphics/radeon-rx/radeon-rx-{c}000-series/amd-radeon-rx-{s}.html", .{ amd_base, gen, slug[0..n] }) catch null;
}

// ---------------------------------------------------------------------------
// Tabele i rozwiązywanie
// ---------------------------------------------------------------------------

pub fn parse(alloc: std.mem.Allocator, text: []const u8) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    var cur: ?Entry = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[[chipset]]") or std.mem.eql(u8, line, "[[gpu]]")) {
            if (cur) |e| if (e.model.len > 0 and e.url.len > 0) try list.append(alloc, e);
            cur = .{ .kind = if (line[2] == 'c') .chipset else .gpu };
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.Malformed;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len < 2 or val[0] != '"') return error.Malformed;
        const close = std.mem.indexOfScalarPos(u8, val, 1, '"') orelse return error.Malformed;
        val = val[1..close];
        const e = if (cur) |*c| c else continue;
        const v = try alloc.dupe(u8, val);
        if (std.mem.eql(u8, key, "model")) e.model = v else if (std.mem.eql(u8, key, "url")) e.url = v else if (std.mem.eql(u8, key, "source")) e.source = v;
    }
    if (cur) |e| if (e.model.len > 0 and e.url.len > 0) try list.append(alloc, e);
    return list.toOwnedSlice(alloc);
}

/// Tylko https na stronach producentów sterowników.
pub fn validUrl(url: []const u8) bool {
    const pre = "https://";
    if (!std.ascii.startsWithIgnoreCase(url, pre) or url.len > 512) return false;
    for (url) |c| if (c <= ' ' or c == '"' or c == '\\' or c >= 0x7F) return false;
    const rest = url[pre.len..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const host = rest[0..end];
    if (std.mem.indexOfAny(u8, host, "@:") != null) return false;
    for ([_][]const u8{ "amd.com", "nvidia.com", "intel.com" }) |h| {
        if (std.ascii.eqlIgnoreCase(host, h)) return true;
        if (host.len > h.len + 1 and host[host.len - h.len - 1] == '.' and std.ascii.eqlIgnoreCase(host[host.len - h.len ..], h)) return true;
    }
    return false;
}

fn fromTables(t: Tables, kind: Kind, model: []const u8) ?Resolved {
    if (model.len == 0) return null;
    for (t.user) |e| if (e.kind == kind and std.ascii.eqlIgnoreCase(e.model, model) and validUrl(e.url)) return .{ .url = e.url, .origin = .user };
    for (t.curated) |e| if (e.kind == kind and std.ascii.eqlIgnoreCase(e.model, model) and validUrl(e.url)) return .{ .url = e.url, .origin = .curated };
    return null;
}

/// Sterowniki chipsetu. `vendor` = PCI vendor chipsetu; `board_product` = SMBIOS typ 2.
pub fn chipset(buf: []u8, t: Tables, vendor: u16, board_product: []const u8) Resolved {
    if (vendor == 0x8086) return .{ .url = intel_dsa, .origin = .generic };
    if (amdChipsetFromBoard(board_product)) |c| {
        var kb: [24]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "{s}/{s}", .{ c.socket, c.modelSlice() }) catch "";
        if (fromTables(t, .chipset, key)) |r| return r;
        return .{ .url = amdChipsetUrl(buf, c), .origin = .derived };
    }
    return .{ .url = amd_generic, .origin = .generic };
}

/// Sterowniki karty graficznej. `model_key` = lookup.normalizeGpu(nazwa).
pub fn gpu(buf: []u8, t: Tables, vendor: u16, name: []const u8, model_key: []const u8) Resolved {
    if (fromTables(t, .gpu, model_key)) |r| return r;
    switch (vendor) {
        0x1002 => {
            if (amdGpuUrl(buf, name)) |u| return .{ .url = u, .origin = .derived };
            return .{ .url = amd_generic, .origin = .generic };
        },
        0x10DE => return .{ .url = nvidia_search, .origin = .generic },
        0x8086 => return .{ .url = intel_dsa, .origin = .generic },
        else => return .{ .url = amd_generic, .origin = .generic },
    }
}

// ---------------------------------------------------------------------------
// Testy (adresy wyprowadzone sprawdzone pojedynczym GET 2026-11-15: HTTP 200;
// nieistniejący chipset zwraca prawdziwe 404, więc 200 coś znaczy)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "drivers: chipset AMD z nazwy płyty" {
    var b: [256]u8 = undefined;
    const c1 = amdChipsetFromBoard("B550 Taichi").?;
    try testing.expectEqualStrings("https://www.amd.com/en/support/downloads/drivers.html/chipsets/am4/b550.html", amdChipsetUrl(&b, c1));
    const c2 = amdChipsetFromBoard("ROG STRIX X670E-E GAMING WIFI").?;
    try testing.expectEqualStrings("am5", c2.socket);
    try testing.expectEqualStrings("x670e", c2.modelSlice());
    try testing.expect(amdChipsetFromBoard("Z790 AORUS ELITE") == null);
    try testing.expect(amdChipsetFromBoard("PRIME B650M-A") == null); // „B650M” to wariant płyty, nie nazwa chipsetu
}

test "drivers: Radeon RX — seria i slug modelu" {
    var b: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-7000-series/amd-radeon-rx-7900-xtx.html",
        amdGpuUrl(&b, "AMD Radeon RX 7900 XTX").?,
    );
    try testing.expectEqualStrings(
        "https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-6000-series/amd-radeon-rx-6800-xt.html",
        amdGpuUrl(&b, "AMD Radeon RX 6800 XT").?,
    );
    try testing.expectEqualStrings(
        "https://www.amd.com/en/support/downloads/drivers.html/graphics/radeon-rx/radeon-rx-9000-series/amd-radeon-rx-9070-xt.html",
        amdGpuUrl(&b, "AMD Radeon RX 9070 XT").?,
    );
    try testing.expect(amdGpuUrl(&b, "AMD Radeon Pro W7900") == null);
    try testing.expect(amdGpuUrl(&b, "AMD Radeon(TM) Graphics") == null);
}

test "drivers: kolejność — przypięty, kuratorowany, wyprowadzony, ogólny" {
    var b: [256]u8 = undefined;
    const curated = [_]Entry{.{ .kind = .chipset, .model = "am4/b550", .url = "https://www.amd.com/en/support/downloads/drivers.html/chipsets/am4/b550.html", .source = "manual" }};
    const user = [_]Entry{.{ .kind = .chipset, .model = "am4/b550", .url = "https://www.amd.com/moja", .source = "user" }};
    try testing.expectEqual(Origin.curated, chipset(&b, .{ .curated = &curated }, 0x1022, "B550 Taichi").origin);
    try testing.expectEqual(Origin.user, chipset(&b, .{ .user = &user, .curated = &curated }, 0x1022, "B550 Taichi").origin);
    try testing.expectEqual(Origin.derived, chipset(&b, .{}, 0x1022, "X570 AORUS MASTER").origin);
    try testing.expectEqual(Origin.generic, chipset(&b, .{}, 0x1022, "Nieznana płyta").origin);
    try testing.expectEqualStrings(intel_dsa, chipset(&b, .{}, 0x8086, "Z790").url);
    try testing.expectEqualStrings(nvidia_search, gpu(&b, .{}, 0x10DE, "NVIDIA GeForce RTX 4090", "geforce rtx 4090").url);
    try testing.expectEqual(Origin.derived, gpu(&b, .{}, 0x1002, "AMD Radeon RX 7900 XTX", "radeon rx 7900 xtx").origin);
    try testing.expect(!validUrl("https://evil.example/amd.com"));
    try testing.expect(validUrl("https://www.amd.com/en/support/download/drivers.html"));
}
