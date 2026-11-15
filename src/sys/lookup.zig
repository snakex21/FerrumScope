//! Rozwiązywanie odnośnika „Wyszukaj” (TechPowerUp) dla CPU i GPU.
//!
//! Strony bazy TechPowerUp mają numeryczne ID (`/cpu-specs/ryzen-7-5800x3d.c2532`),
//! którego nie da się wyprowadzić z CPUID ani z identyfikatorów PCI. Dlatego:
//!
//!   1. **link przypięty przez użytkownika** — `data\links.toml` obok programu
//!      (przycisk „Przypnij link” w GUI),
//!   2. **tabela kuratorowana** — `db/source/links/techpowerup.toml`, wpisy
//!      dodawane ręcznie (`source = "manual"`), nigdy przez crawling,
//!   3. **wyszukiwanie po nazwie** — dotychczasowe zachowanie (`links.zig`).
//!
//! Format obu plików to podzbiór TOML:
//!
//! ```toml
//! [[cpu]]
//! model = "ryzen 7 5800x3d"     # nazwa znormalizowana (normalizeCpu)
//! url = "https://www.techpowerup.com/cpu-specs/ryzen-7-5800x3d.c2532"
//! source = "manual"
//!
//! [[gpu]]
//! model = "radeon rx 7900 xtx"  # normalizeGpu
//! pci = "1002:744c"             # opcjonalnie: musi się zgadzać, gdy podany
//! url = "https://www.techpowerup.com/gpu-specs/radeon-rx-7900-xtx.c3941"
//! source = "manual"
//! ```

const std = @import("std");
const i18n = @import("../i18n/i18n.zig");

pub const Kind = enum { cpu, gpu };

pub const Entry = struct {
    kind: Kind,
    model: []const u8 = "",
    pci: []const u8 = "",
    url: []const u8 = "",
    source: []const u8 = "",
};

pub const Origin = enum {
    user,
    curated,
    search,

    pub fn label(self: Origin) []const u8 {
        return switch (self) {
            .user => i18n.t("link przypięty przez użytkownika (data\\links.toml)"),
            .curated => i18n.t("tabela kuratorowana (db/source/links/techpowerup.toml)"),
            .search => i18n.t("wyszukiwanie po nazwie"),
        };
    }
};

pub const Resolved = struct { url: []const u8, origin: Origin };

pub const Tables = struct {
    user: []const Entry = &.{},
    curated: []const Entry = &.{},
};

// ---------------------------------------------------------------------------
// Normalizacja nazw
// ---------------------------------------------------------------------------

const drop_words = [_][]const u8{ "amd", "intel", "nvidia", "processor", "cpu", "graphics", "with", "radeon(tm)" };

/// Nazwa modelu do porównań: małe litery, bez znaków (R)/(TM), bez nazwy
/// producenta, bez „Processor”, „N-Core”, częstotliwości i dopisków typu
/// „with Radeon Graphics”. „AMD Ryzen 7 5800X3D 8-Core Processor” → „ryzen 7 5800x3d”.
pub fn normalizeCpu(out: []u8, brand: []const u8) []const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, brand, " \t");
    var stop = false;
    while (it.next()) |raw| {
        if (stop) break;
        var tmp: [64]u8 = undefined;
        var t: usize = 0;
        var i: usize = 0;
        while (i < raw.len and t < tmp.len) : (i += 1) {
            if (raw[i] == '(') {
                // „(R)”, „(TM)” — pomijamy cały nawias.
                while (i < raw.len and raw[i] != ')') i += 1;
                continue;
            }
            tmp[t] = std.ascii.toLower(raw[i]);
            t += 1;
        }
        const w = tmp[0..t];
        if (w.len == 0) continue;
        if (std.mem.eql(u8, w, "@")) break;
        if (std.mem.eql(u8, w, "with")) {
            stop = true;
            continue;
        }
        var skip = false;
        for (drop_words) |d| if (std.mem.eql(u8, w, d)) {
            skip = true;
        };
        if (std.mem.endsWith(u8, w, "-core") or std.mem.endsWith(u8, w, "ghz")) skip = true;
        // „12th Gen”, „13th Gen” — prefiks generacji Intela.
        if (std.mem.eql(u8, w, "gen") or (w.len >= 3 and std.ascii.isDigit(w[0]) and (std.mem.endsWith(u8, w, "th") or std.mem.endsWith(u8, w, "nd") or std.mem.endsWith(u8, w, "rd") or std.mem.endsWith(u8, w, "st")))) skip = true;
        if (skip) continue;
        if (n > 0 and n < out.len) {
            out[n] = ' ';
            n += 1;
        }
        const k = @min(w.len, out.len - n);
        @memcpy(out[n..][0..k], w[0..k]);
        n += k;
    }
    return out[0..n];
}

/// „AMD Radeon RX 7900 XTX” → „radeon rx 7900 xtx”; „NVIDIA GeForce RTX 4090” → „geforce rtx 4090”.
pub fn normalizeGpu(out: []u8, name: []const u8) []const u8 {
    return normalizeCpu(out, name);
}

// ---------------------------------------------------------------------------
// Parser podzbioru TOML
// ---------------------------------------------------------------------------

pub const ParseError = error{ Malformed, OutOfMemory };

/// Parsuje `[[cpu]]` / `[[gpu]]` z kluczami `model`, `pci`, `url`, `source`.
/// Nieznane klucze są pomijane; wpisy bez `model` albo `url` są odrzucane.
pub fn parse(alloc: std.mem.Allocator, text: []const u8) ParseError![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    var cur: ?Entry = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[[cpu]]") or std.mem.eql(u8, line, "[[gpu]]")) {
            if (cur) |e| if (e.model.len > 0 and e.url.len > 0) try list.append(alloc, e);
            cur = .{ .kind = if (line[2] == 'c') .cpu else .gpu };
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
        if (std.mem.eql(u8, key, "model")) e.model = v else if (std.mem.eql(u8, key, "pci")) e.pci = v else if (std.mem.eql(u8, key, "url")) e.url = v else if (std.mem.eql(u8, key, "source")) e.source = v;
    }
    if (cur) |e| if (e.model.len > 0 and e.url.len > 0) try list.append(alloc, e);
    return list.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Walidacja i rozwiązywanie
// ---------------------------------------------------------------------------

const allowed_hosts = [_][]const u8{ "techpowerup.com", "amd.com", "intel.com", "nvidia.com" };

/// Dozwolony link: `https://`, host to techpowerup.com albo strona producenta
/// (amd.com, intel.com, nvidia.com, także subdomeny), bez danych logowania
/// i bez spacji/znaków sterujących.
pub fn validUrl(url: []const u8) bool {
    const pre = "https://";
    if (!std.ascii.startsWithIgnoreCase(url, pre) or url.len > 512) return false;
    for (url) |c| if (c <= ' ' or c == '"' or c == '\\' or c >= 0x7F) return false;
    const rest = url[pre.len..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const host = rest[0..end];
    if (host.len == 0 or std.mem.indexOfAny(u8, host, "@:") != null) return false;
    for (allowed_hosts) |h| {
        if (std.ascii.eqlIgnoreCase(host, h)) return true;
        if (host.len > h.len + 1 and host[host.len - h.len - 1] == '.' and std.ascii.eqlIgnoreCase(host[host.len - h.len ..], h)) return true;
    }
    return false;
}

fn matches(e: Entry, kind: Kind, model: []const u8, pci: []const u8) bool {
    if (e.kind != kind or !std.ascii.eqlIgnoreCase(e.model, model)) return false;
    if (e.pci.len > 0 and pci.len > 0 and !std.ascii.eqlIgnoreCase(e.pci, pci)) return false;
    return validUrl(e.url);
}

/// Link dokładnej strony: przypięty > kuratorowany. `null` = zostaje wyszukiwanie.
pub fn resolve(t: Tables, kind: Kind, model: []const u8, pci: []const u8) ?Resolved {
    if (model.len == 0) return null;
    for (t.user) |e| if (matches(e, kind, model, pci)) return .{ .url = e.url, .origin = .user };
    for (t.curated) |e| if (matches(e, kind, model, pci)) return .{ .url = e.url, .origin = .curated };
    return null;
}

/// Nowa treść `data\links.toml` po przypięciu (zastępuje wpis tego samego modelu).
pub fn withPinned(alloc: std.mem.Allocator, existing: []const Entry, e: Entry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("# FerrumScope — linki przypięte przez użytkownika (pierwszeństwo przed tabelą kuratorowaną).\n");
    for (existing) |x| {
        if (x.kind == e.kind and std.ascii.eqlIgnoreCase(x.model, e.model)) continue;
        try writeEntry(w, x);
    }
    try writeEntry(w, e);
    return out.toOwnedSlice();
}

fn writeEntry(w: *std.Io.Writer, e: Entry) !void {
    try w.print("\n[[{s}]]\nmodel = \"{s}\"\n", .{ @tagName(e.kind), e.model });
    if (e.pci.len > 0) try w.print("pci = \"{s}\"\n", .{e.pci});
    try w.print("url = \"{s}\"\nsource = \"{s}\"\n", .{ e.url, if (e.source.len > 0) e.source else "user" });
}

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

const testing = std.testing;

test "lookup: normalizacja nazw CPU i GPU" {
    var b: [128]u8 = undefined;
    try testing.expectEqualStrings("ryzen 7 5800x3d", normalizeCpu(&b, "AMD Ryzen 7 5800X3D 8-Core Processor           "));
    try testing.expectEqualStrings("core i7-12700k", normalizeCpu(&b, "12th Gen Intel(R) Core(TM) i7-12700K"));
    try testing.expectEqualStrings("xeon gold 6338", normalizeCpu(&b, "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz"));
    try testing.expectEqualStrings("ryzen 7 5700g", normalizeCpu(&b, "AMD Ryzen 7 5700G with Radeon Graphics"));
    try testing.expectEqualStrings("radeon rx 7900 xtx", normalizeGpu(&b, "AMD Radeon RX 7900 XTX"));
    try testing.expectEqualStrings("geforce rtx 4090", normalizeGpu(&b, "NVIDIA GeForce RTX 4090"));
}

test "lookup: walidacja URL" {
    try testing.expect(validUrl("https://www.techpowerup.com/cpu-specs/ryzen-7-5800x3d.c2532"));
    try testing.expect(validUrl("https://techpowerup.com/gpu-specs/x.c1"));
    try testing.expect(validUrl("https://www.amd.com/en/products/processors/desktops/ryzen.html"));
    try testing.expect(!validUrl("http://www.techpowerup.com/cpu-specs/a.c1"));
    try testing.expect(!validUrl("https://techpowerup.com.evil.example/x"));
    try testing.expect(!validUrl("https://eviltechpowerup.com/x"));
    try testing.expect(!validUrl("https://user@techpowerup.com/x"));
    try testing.expect(!validUrl("https://www.techpowerup.com/a b"));
    try testing.expect(!validUrl("javascript:alert(1)"));
}

test "lookup: kolejność — przypięty, kuratorowany, wyszukiwanie" {
    const curated = [_]Entry{
        .{ .kind = .cpu, .model = "ryzen 7 5800x3d", .url = "https://www.techpowerup.com/cpu-specs/ryzen-7-5800x3d.c2532", .source = "manual" },
        .{ .kind = .gpu, .model = "radeon rx 7900 xtx", .pci = "1002:744c", .url = "https://www.techpowerup.com/gpu-specs/radeon-rx-7900-xtx.c3941", .source = "manual" },
    };
    const user = [_]Entry{.{ .kind = .cpu, .model = "ryzen 7 5800x3d", .url = "https://www.techpowerup.com/cpu-specs/moja.c1", .source = "user" }};

    const r1 = resolve(.{ .curated = &curated }, .cpu, "ryzen 7 5800x3d", "").?;
    try testing.expectEqual(Origin.curated, r1.origin);
    const r2 = resolve(.{ .user = &user, .curated = &curated }, .cpu, "ryzen 7 5800x3d", "").?;
    try testing.expectEqual(Origin.user, r2.origin);
    try testing.expect(resolve(.{ .curated = &curated }, .cpu, "ryzen 5 5600x", "") == null);
    // GPU: zgodny model + zgodne PCI; ten sam model z innym ID — brak dokładnego trafienia.
    try testing.expectEqual(Origin.curated, resolve(.{ .curated = &curated }, .gpu, "radeon rx 7900 xtx", "1002:744c").?.origin);
    try testing.expect(resolve(.{ .curated = &curated }, .gpu, "radeon rx 7900 xtx", "1002:7448") == null);
    // Typ musi się zgadzać (CPU nie trafia we wpis GPU).
    try testing.expect(resolve(.{ .curated = &curated }, .cpu, "radeon rx 7900 xtx", "") == null);
}

test "lookup: parser i przypinanie zastępują wpis tego samego modelu" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\# komentarz
        \\[[cpu]]
        \\model = "ryzen 7 5800x3d"
        \\url = "https://www.techpowerup.com/cpu-specs/ryzen-7-5800x3d.c2532"
        \\source = "manual"
        \\
        \\[[gpu]]
        \\model = "bez url"
    ;
    const es = try parse(a, text);
    try testing.expectEqual(@as(usize, 1), es.len);
    try testing.expectEqualStrings("manual", es[0].source);
    const out = try withPinned(a, es, .{ .kind = .cpu, .model = "ryzen 7 5800x3d", .url = "https://www.techpowerup.com/cpu-specs/x.c9" });
    const again = try parse(a, out);
    try testing.expectEqual(@as(usize, 1), again.len);
    try testing.expectEqualStrings("https://www.techpowerup.com/cpu-specs/x.c9", again[0].url);
    try testing.expectError(error.Malformed, parse(a, "[[cpu]]\nmodel = bez cudzysłowu\n"));
}
