//! Manifest aktualizacji (`ferrumscope-update.json`), lista sum `SHA256SUMS`
//! i lista dozwolonych adresów.
//!
//! Manifest jest publikowany przez `.github/workflows/release.yml` obok
//! archiwum. Ufamy mu tylko w granicach walidacji poniżej: adres archiwum musi
//! wskazywać **dokładnie** wydanie repozytorium snakex21/FerrumScope na
//! github.com (https), nazwa pliku i tag muszą zgadzać się z wersją, a suma
//! i rozmiar muszą być sensowne. Wszystko inne jest odrzucane.

const std = @import("std");
const version = @import("version.zig");

pub const owner_repo = "snakex21/FerrumScope";
pub const release_prefix = "https://github.com/" ++ owner_repo ++ "/releases/download/";
pub const latest_manifest_url = "https://github.com/" ++ owner_repo ++ "/releases/latest/download/ferrumscope-update.json";
pub const manifest_name = "ferrumscope-update.json";
pub const sums_name = "SHA256SUMS";
/// Lista wydań (kanał testowy). Jedyny adres, dla którego wolno użyć
/// api.github.com — `net.get` dopuszcza go tylko z `allow_api_listing`.
pub const releases_api_url = "https://api.github.com/repos/" ++ owner_repo ++ "/releases?per_page=30";
/// Limit rozmiaru listy wydań.
pub const max_listing_size: usize = 2 * 1024 * 1024;

/// Limit rozmiaru archiwum (wyłącznie: `size < max_size`).
pub const max_size: u64 = 200 * 1024 * 1024;
/// Limit długości notatek wydania w manifeście.
pub const max_notes: usize = 16 * 1024;

/// Hosty, na które wolno przejść (także przez przekierowanie). Tylko https:443.
pub const allowed_hosts = [_][]const u8{
    "github.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
};

pub const Error = error{
    InvalidManifest,
    InvalidListing,
    BadVersion,
    BadUrl,
    BadSha256,
    BadSize,
    NotesTooLong,
    OutOfMemory,
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    version: []const u8,
    url: []const u8,
    sha256: [32]u8,
    size: u64,
    notes: []const u8,
    published: []const u8,

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Nazwa pliku archiwum (ostatni segment adresu).
    pub fn fileName(self: *const Manifest) []const u8 {
        return self.url[std.mem.lastIndexOfScalar(u8, self.url, '/').? + 1 ..];
    }

    /// Adres `SHA256SUMS` tego samego wydania (ten sam tag co archiwum).
    pub fn sumsUrl(self: *const Manifest, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "{s}v{s}/{s}", .{ release_prefix, self.version, sums_name });
    }
};

const Raw = struct {
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
    size: i64,
    notes: []const u8 = "",
    published: []const u8 = "",
};

/// Oczekiwana nazwa archiwum dla wersji — ta sama reguła co w workflow.
pub fn zipName(buf: []u8, ver: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "FerrumScope-{s}-windows-x64.zip", .{ver});
}

pub fn parseHex32(hex: []const u8) ?[32]u8 {
    if (hex.len != 64) return null;
    var out: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, hex) catch return null;
    return out;
}

/// Adres archiwum: `https://github.com/snakex21/FerrumScope/releases/download/v<ver>/FerrumScope-<ver>-windows-x64.zip`.
pub fn validateAssetUrl(url: []const u8, ver: []const u8) bool {
    if (!std.mem.startsWith(u8, url, release_prefix)) return false;
    const rest = url[release_prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    const tag = rest[0..slash];
    const file = rest[slash + 1 ..];
    if (tag.len != ver.len + 1 or tag[0] != 'v' or !std.mem.eql(u8, tag[1..], ver)) return false;
    var nb: [160]u8 = undefined;
    const want = zipName(&nb, ver) catch return false;
    return std.mem.eql(u8, file, want);
}

/// Adres manifestu w wydaniu: `.../releases/download/v<ver>/ferrumscope-update.json`.
pub fn validateManifestUrl(url: []const u8, ver: []const u8) bool {
    if (!std.mem.startsWith(u8, url, release_prefix)) return false;
    const rest = url[release_prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    const tag = rest[0..slash];
    if (tag.len != ver.len + 1 or tag[0] != 'v' or !std.mem.eql(u8, tag[1..], ver)) return false;
    return std.mem.eql(u8, rest[slash + 1 ..], manifest_name);
}

// ---------------------------------------------------------------------------
// Lista wydań (kanał testowy): GET api.github.com/repos/<repo>/releases
// ---------------------------------------------------------------------------

pub const Channel = @import("../settings.zig").UpdateChannel;

/// Wybrane wydanie: wersja (bez `v`) i adres jego manifestu.
pub const Selected = struct {
    version: []const u8,
    manifest_url: []const u8,
};

const AssetRaw = struct {
    name: []const u8,
    browser_download_url: []const u8,
};

const ReleaseRaw = struct {
    tag_name: []const u8,
    draft: bool = false,
    prerelease: bool = false,
    assets: []const AssetRaw = &.{},
};

/// Wybiera wydanie z listy GitHub API. Pomija szkice, tagi niebędące SemVer
/// i wydania bez poprawnego manifestu (adres spoza listy dozwolonych = brak).
/// `stable` pomija też pre-release (flaga GitHub **albo** sufiks w wersji).
/// Spośród pozostałych bierze najwyższą wersję SemVer — kolejność listy
/// (data utworzenia) nie decyduje. Napisy wyniku żyją w `arena`.
pub fn selectRelease(arena: std.mem.Allocator, listing: []const u8, channel: Channel) Error!?Selected {
    const list = std.json.parseFromSliceLeaky([]const ReleaseRaw, arena, listing, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidListing,
    };
    var best: ?Selected = null;
    var best_v: version.Version = undefined;
    for (list) |r| {
        if (r.draft) continue;
        if (r.tag_name.len < 2 or r.tag_name[0] != 'v') continue;
        const ver = r.tag_name[1..];
        if (std.mem.indexOfScalar(u8, ver, '+') != null) continue;
        const v = version.parse(ver) catch continue;
        if (channel == .stable and (r.prerelease or v.isPrerelease())) continue;
        const url = for (r.assets) |a| {
            if (std.mem.eql(u8, a.name, manifest_name)) break a.browser_download_url;
        } else continue;
        if (!validateManifestUrl(url, ver)) continue;
        if (best == null or version.order(v, best_v) == .gt) {
            best = .{ .version = ver, .manifest_url = url };
            best_v = v;
        }
    }
    return best;
}

pub fn parse(gpa: std.mem.Allocator, text: []const u8) Error!Manifest {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const raw = std.json.parseFromSliceLeaky(Raw, a, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidManifest,
    };
    _ = version.parse(raw.version) catch return error.BadVersion;
    // Wersja w manifeście bez prefiksu `v` (tag go dodaje).
    if (raw.version.len == 0 or raw.version[0] == 'v' or raw.version[0] == 'V') return error.BadVersion;
    if (!validateAssetUrl(raw.url, raw.version)) return error.BadUrl;
    const digest = parseHex32(raw.sha256) orelse return error.BadSha256;
    if (raw.size <= 0 or @as(u64, @intCast(raw.size)) >= max_size) return error.BadSize;
    if (raw.notes.len > max_notes) return error.NotesTooLong;
    return .{
        .arena = arena,
        .version = raw.version,
        .url = raw.url,
        .sha256 = digest,
        .size = @intCast(raw.size),
        .notes = raw.notes,
        .published = raw.published,
    };
}

// ---------------------------------------------------------------------------
// SHA256SUMS (format `sha256sum`: `<64 hex><spacja><spacja|*><nazwa>`)
// ---------------------------------------------------------------------------

pub const SumsError = error{ BadSums, DuplicateSum };

/// Szuka sumy pliku `name`. Błędna linia albo powtórzona nazwa = błąd całego pliku.
pub fn findSum(text: []const u8, name: []const u8) SumsError!?[32]u8 {
    var found: ?[32]u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line.len < 66 or line[64] != ' ') return error.BadSums;
        const digest = parseHex32(line[0..64]) orelse return error.BadSums;
        var file = line[65..];
        if (file.len > 0 and (file[0] == ' ' or file[0] == '*')) file = file[1..];
        if (file.len == 0) return error.BadSums;
        if (std.mem.eql(u8, file, name)) {
            if (found != null) return error.DuplicateSum;
            found = digest;
        }
    }
    return found;
}

// ---------------------------------------------------------------------------
// Adresy https i lista dozwolonych hostów
// ---------------------------------------------------------------------------

pub const HttpsUrl = struct {
    host: []const u8,
    /// Ścieżka z zapytaniem, zaczyna się od `/`.
    path: []const u8,
};

/// Rozbija `https://host/ścieżka`. Odrzuca inne schematy, dane logowania,
/// porty inne niż domyślny, spacje i znaki sterujące.
pub fn parseHttpsUrl(url: []const u8) ?HttpsUrl {
    const scheme = "https://";
    if (url.len <= scheme.len or !std.ascii.eqlIgnoreCase(url[0..scheme.len], scheme)) return null;
    for (url) |c| if (c <= 0x20 or c >= 0x7f or c == '\\') return null;
    const rest = url[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    var host = rest[0..slash];
    if (host.len == 0 or std.mem.indexOfScalar(u8, host, '@') != null) return null;
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| {
        if (!std.mem.eql(u8, host[colon + 1 ..], "443")) return null;
        host = host[0..colon];
    }
    return .{ .host = host, .path = rest[slash..] };
}

pub fn isAllowedHost(host: []const u8) bool {
    for (allowed_hosts) |h| if (std.ascii.eqlIgnoreCase(host, h)) return true;
    return false;
}

/// Adres, na który wolno wysłać żądanie (pierwsze albo po przekierowaniu).
pub fn isAllowedUrl(url: []const u8) bool {
    const u = parseHttpsUrl(url) orelse return false;
    return isAllowedHost(u.host);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const valid_json =
    \\{
    \\  "version": "0.3.0",
    \\  "url": "https://github.com/snakex21/FerrumScope/releases/download/v0.3.0/FerrumScope-0.3.0-windows-x64.zip",
    \\  "sha256": "3A0ED1E8799A2F8CE2A6E6290A9FF22E6906F8227865911FB7DDEDC3CC14CB0C",
    \\  "size": 1234567,
    \\  "notes": "Nowości:\n- aktualizator",
    \\  "published": "2026-11-15T10:00:00Z",
    \\  "extra": [1, 2, 3]
    \\}
;

fn withField(comptime field: []const u8, comptime value: []const u8) []const u8 {
    const fields = .{
        .{ "version", "\"0.3.0\"" },
        .{ "url", "\"https://github.com/snakex21/FerrumScope/releases/download/v0.3.0/FerrumScope-0.3.0-windows-x64.zip\"" },
        .{ "sha256", "\"3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c\"" },
        .{ "size", "1234567" },
    };
    comptime var s: []const u8 = "{";
    comptime var first = true;
    inline for (fields) |f| {
        const v = if (comptime std.mem.eql(u8, f[0], field)) value else f[1];
        if (v.len == 0) continue;
        s = s ++ (if (first) "" else ",") ++ "\"" ++ f[0] ++ "\":" ++ v;
        first = false;
    }
    return s ++ "}";
}

fn expectBad(comptime field: []const u8, comptime value: []const u8, err: Error) !void {
    try testing.expectError(err, parse(testing.allocator, comptime withField(field, value)));
}

test "manifest: poprawny" {
    var m = try parse(testing.allocator, valid_json);
    defer m.deinit();
    try testing.expectEqualStrings("0.3.0", m.version);
    try testing.expectEqual(@as(u64, 1234567), m.size);
    try testing.expectEqual(@as(u8, 0x3a), m.sha256[0]);
    try testing.expectEqual(@as(u8, 0x0c), m.sha256[31]);
    try testing.expectEqualStrings("Nowości:\n- aktualizator", m.notes);
    try testing.expectEqualStrings("FerrumScope-0.3.0-windows-x64.zip", m.fileName());
    var b: [256]u8 = undefined;
    try testing.expectEqualStrings("https://github.com/snakex21/FerrumScope/releases/download/v0.3.0/SHA256SUMS", try m.sumsUrl(&b));
    // Bez pól opcjonalnych.
    var m2 = try parse(testing.allocator, comptime withField("none", ""));
    defer m2.deinit();
    try testing.expectEqualStrings("", m2.notes);
}

test "manifest: każde błędne pole" {
    try testing.expectError(error.InvalidManifest, parse(testing.allocator, "nie json"));
    try testing.expectError(error.InvalidManifest, parse(testing.allocator, "[]"));
    // Brak pól wymaganych.
    try expectBad("version", "", error.InvalidManifest);
    try expectBad("url", "", error.InvalidManifest);
    try expectBad("sha256", "", error.InvalidManifest);
    try expectBad("size", "", error.InvalidManifest);
    // Złe typy.
    try expectBad("size", "true", error.InvalidManifest);
    try expectBad("size", "\"abc\"", error.InvalidManifest);
    try expectBad("url", "null", error.InvalidManifest);
    try expectBad("size", "1.5", error.InvalidManifest);
    try expectBad("version", "3", error.InvalidManifest);
    // Wersja.
    try expectBad("version", "\"0.3\"", error.BadVersion);
    try expectBad("version", "\"v0.3.0\"", error.BadVersion);
    try expectBad("version", "\"0.3.0/../x\"", error.BadVersion);
    // Suma.
    try expectBad("sha256", "\"abc\"", error.BadSha256);
    try expectBad("sha256", "\"zz0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c\"", error.BadSha256);
    try expectBad("sha256", "\"3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c00\"", error.BadSha256);
    // Rozmiar.
    try expectBad("size", "0", error.BadSize);
    try expectBad("size", "-5", error.BadSize);
    try expectBad("size", "209715200", error.BadSize);
    try expectBad("size", "999999999999", error.BadSize);
}

test "manifest: notatki za długie" {
    const long = "x" ** (max_notes + 1);
    const json = "{\"version\":\"0.3.0\",\"url\":\"https://github.com/snakex21/FerrumScope/releases/download/v0.3.0/FerrumScope-0.3.0-windows-x64.zip\"," ++
        "\"sha256\":\"3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c\",\"size\":10,\"notes\":\"" ++ long ++ "\"}";
    try testing.expectError(error.NotesTooLong, parse(testing.allocator, json));
}

test "manifest: lista dozwolonych adresów archiwum" {
    const v = "0.3.0";
    try testing.expect(validateAssetUrl("https://github.com/snakex21/FerrumScope/releases/download/v0.3.0/FerrumScope-0.3.0-windows-x64.zip", v));
    const bad = [_][]const u8{
        "http://github.com/snakex21/FerrumScope/releases/download/v0.3.0/FerrumScope-0.3.0-windows-x64.zip",
        "https://github.com/snakex21/FerrumScopeX/releases/download/v0.3.0/FerrumScope-0.3.0-windows-x64.zip",
        "https://github.com/evil/FerrumScope/releases/download/v0.3.0/FerrumScope-0.3.0-windows-x64.zip",
        "https://github.com.evil.com/snakex21/FerrumScope/releases/download/v0.3.0/FerrumScope-0.3.0-windows-x64.zip",
        "https://evil.com/snakex21/FerrumScope/releases/download/v0.3.0/FerrumScope-0.3.0-windows-x64.zip",
        "https://user@github.com/snakex21/FerrumScope/releases/download/v0.3.0/FerrumScope-0.3.0-windows-x64.zip",
        "https://github.com:8443/snakex21/FerrumScope/releases/download/v0.3.0/FerrumScope-0.3.0-windows-x64.zip",
        "https://github.com/snakex21/FerrumScope/releases/download/v0.2.9/FerrumScope-0.3.0-windows-x64.zip",
        "https://github.com/snakex21/FerrumScope/releases/download/v0.3.0/FerrumScope-0.3.0-windows-x64.exe",
        "https://github.com/snakex21/FerrumScope/releases/download/v0.3.0/../../x/FerrumScope-0.3.0-windows-x64.zip",
        "https://github.com/snakex21/FerrumScope/releases/download/v0.3.0/FerrumScope-0.3.0-windows-x64.zip?x=1",
        "https://github.com/snakex21/FerrumScope/releases/latest/download/FerrumScope-0.3.0-windows-x64.zip",
        "",
    };
    for (bad) |u| try testing.expect(!validateAssetUrl(u, v));
    try expectBad("url", "\"https://evil.example/FerrumScope-0.3.0-windows-x64.zip\"", error.BadUrl);
}

test "manifest: hosty przekierowań" {
    try testing.expect(isAllowedUrl("https://github.com/snakex21/FerrumScope/releases/latest/download/ferrumscope-update.json"));
    try testing.expect(isAllowedUrl("https://objects.githubusercontent.com/github-production-release-asset/1?x=y"));
    try testing.expect(isAllowedUrl("https://release-assets.githubusercontent.com/github-production-release-asset/1?sig=a%2Fb"));
    try testing.expect(isAllowedUrl("HTTPS://GitHub.com:443/a"));
    try testing.expect(!isAllowedUrl("http://github.com/a"));
    try testing.expect(!isAllowedUrl("https://github.com.evil.com/a"));
    try testing.expect(!isAllowedUrl("https://evil.com/github.com/a"));
    try testing.expect(!isAllowedUrl("https://user:pw@github.com/a"));
    try testing.expect(!isAllowedUrl("https://github.com:80/a"));
    try testing.expect(!isAllowedUrl("https://github.com"));
    try testing.expect(!isAllowedUrl("https://github.com/a b"));
    try testing.expect(!isAllowedUrl("ftp://github.com/a"));
    try testing.expect(!isAllowedUrl("https://raw.githubusercontent.com/a"));
    const u = parseHttpsUrl("https://github.com/a/b?c=d").?;
    try testing.expectEqualStrings("github.com", u.host);
    try testing.expectEqualStrings("/a/b?c=d", u.path);
}

test "manifest: SHA256SUMS" {
    const sums =
        "3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c  FerrumScope-0.3.0-windows-x64.zip\r\n" ++
        "02AA270F183DA276E5B5920B1DAC44A63F1A49E55050EBDE3AECC9EB82F93239 *ferrumscope-update.json\n" ++
        "\n";
    const a = (try findSum(sums, "FerrumScope-0.3.0-windows-x64.zip")).?;
    try testing.expectEqual(@as(u8, 0x3a), a[0]);
    const b = (try findSum(sums, "ferrumscope-update.json")).?;
    try testing.expectEqual(@as(u8, 0x02), b[0]);
    try testing.expect((try findSum(sums, "inny.zip")) == null);
    try testing.expect((try findSum("", "x")) == null);
    try testing.expectError(error.BadSums, findSum("abc  x\n", "x"));
    try testing.expectError(error.BadSums, findSum("3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c\n", "x"));
    try testing.expectError(error.BadSums, findSum("3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cbXX  x\n", "x"));
    try testing.expectError(error.DuplicateSum, findSum(
        "3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c  x\n" ++
            "02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239  x\n",
        "x",
    ));
}

/// Lista wydań do testów (kolejność celowo inna niż kolejność wersji).
pub const test_listing =
    \\[
    \\  {"tag_name":"v0.4.0","draft":true,"prerelease":false,"assets":[
    \\    {"name":"ferrumscope-update.json","browser_download_url":"https://github.com/snakex21/FerrumScope/releases/download/v0.4.0/ferrumscope-update.json"}]},
    \\  {"tag_name":"v0.3.0-preview.1","draft":false,"prerelease":true,"assets":[
    \\    {"name":"ferrumscope-update.json","browser_download_url":"https://github.com/snakex21/FerrumScope/releases/download/v0.3.0-preview.1/ferrumscope-update.json"}]},
    \\  {"tag_name":"v0.3.0-preview.2","draft":false,"prerelease":true,"html_url":"x","assets":[
    \\    {"name":"SHA256SUMS","browser_download_url":"https://github.com/snakex21/FerrumScope/releases/download/v0.3.0-preview.2/SHA256SUMS"},
    \\    {"name":"ferrumscope-update.json","browser_download_url":"https://github.com/snakex21/FerrumScope/releases/download/v0.3.0-preview.2/ferrumscope-update.json"}]},
    \\  {"tag_name":"v9.0.0","draft":false,"prerelease":false,"assets":[
    \\    {"name":"ferrumscope-update.json","browser_download_url":"https://evil.example/snakex21/FerrumScope/releases/download/v9.0.0/ferrumscope-update.json"}]},
    \\  {"tag_name":"v8.0.0","draft":false,"prerelease":false,"assets":[]},
    \\  {"tag_name":"nightly","draft":false,"prerelease":true,"assets":[]},
    \\  {"tag_name":"v0.2.0","draft":false,"prerelease":false,"assets":[
    \\    {"name":"ferrumscope-update.json","browser_download_url":"https://github.com/snakex21/FerrumScope/releases/download/v0.2.0/ferrumscope-update.json"}]},
    \\  {"tag_name":"v0.1.0","draft":false,"prerelease":false,"assets":[
    \\    {"name":"ferrumscope-update.json","browser_download_url":"https://github.com/snakex21/FerrumScope/releases/download/v0.1.0/ferrumscope-update.json"}]}
    \\]
;

test "manifest: wybór wydania z listy (kanały)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Stabilny: pomija szkic, pre-release, manifest spoza listy dozwolonych i wydanie bez manifestu.
    const s = (try selectRelease(a, test_listing, .stable)).?;
    try testing.expectEqualStrings("0.2.0", s.version);
    try testing.expectEqualStrings("https://github.com/snakex21/FerrumScope/releases/download/v0.2.0/ferrumscope-update.json", s.manifest_url);
    // Testowy: najwyższa wersja spośród nie-szkiców (preview.2 > preview.1 > 0.2.0).
    const t = (try selectRelease(a, test_listing, .@"test")).?;
    try testing.expectEqualStrings("0.3.0-preview.2", t.version);
    // Pusta lista / same szkice = brak wydań.
    try testing.expect((try selectRelease(a, "[]", .@"test")) == null);
    try testing.expect((try selectRelease(a, "[{\"tag_name\":\"v1.0.0\",\"draft\":true}]", .stable)) == null);
    // Wersja z sufiksem bez flagi prerelease nie trafia do kanału stabilnego.
    const unflagged = "[{\"tag_name\":\"v1.0.0-rc.1\",\"prerelease\":false,\"assets\":[{\"name\":\"ferrumscope-update.json\"," ++
        "\"browser_download_url\":\"https://github.com/snakex21/FerrumScope/releases/download/v1.0.0-rc.1/ferrumscope-update.json\"}]}]";
    try testing.expect((try selectRelease(a, unflagged, .stable)) == null);
    try testing.expectEqualStrings("1.0.0-rc.1", (try selectRelease(a, unflagged, .@"test")).?.version);
    try testing.expectError(error.InvalidListing, selectRelease(a, "{\"message\":\"Not Found\"}", .@"test"));
    try testing.expectError(error.InvalidListing, selectRelease(a, "nie json", .stable));
}

test "manifest: adres manifestu w wydaniu" {
    try testing.expect(validateManifestUrl("https://github.com/snakex21/FerrumScope/releases/download/v0.3.0/ferrumscope-update.json", "0.3.0"));
    try testing.expect(!validateManifestUrl("https://github.com/snakex21/FerrumScope/releases/download/v0.3.1/ferrumscope-update.json", "0.3.0"));
    try testing.expect(!validateManifestUrl("https://github.com/other/FerrumScope/releases/download/v0.3.0/ferrumscope-update.json", "0.3.0"));
    try testing.expect(!validateManifestUrl("http://github.com/snakex21/FerrumScope/releases/download/v0.3.0/ferrumscope-update.json", "0.3.0"));
    try testing.expect(!validateManifestUrl("https://github.com/snakex21/FerrumScope/releases/download/v0.3.0/x/../ferrumscope-update.json", "0.3.0"));
    // api.github.com nie jest na ogólnej liście dozwolonych hostów.
    try testing.expect(!isAllowedUrl(releases_api_url));
}
