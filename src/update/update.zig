//! Aktualizator FerrumScope — punkt wejścia modułu (wspólny dla CLI i GUI).
//!
//!   * `version`  — SemVer: parsowanie i porównanie (z pre-release);
//!   * `manifest` — `ferrumscope-update.json`, `SHA256SUMS`, lista wydań, lista dozwolonych adresów;
//!   * `net`      — HTTPS przez WinHTTP (limity czasu, kontrola przekierowań);
//!   * `apply`    — weryfikacja, rozpakowanie, podmiana z kopią `.old`, wycofanie;
//!   * `cli`      — polecenie `ferrumscope update`;
//!   * `gui`      — przycisk, pola wyboru i sprawdzanie przy starcie w oknie;
//!   * `text`     — wszystkie teksty dla użytkownika.
//!
//! Źródło wydań: wyłącznie `github.com/snakex21/FerrumScope/releases`.
//! Kanały (`update_channel` w `data\settings.ini`):
//!   * `stable` — `releases/latest/download/ferrumscope-update.json`
//!     (GitHub pomija tam pre-release); manifest z wersją pre-release jest
//!     dodatkowo ignorowany;
//!   * `test` — lista `api.github.com/repos/snakex21/FerrumScope/releases`,
//!     najwyższa wersja SemVer spośród wydań niebędących szkicem (także
//!     pre-release), potem manifest tego wydania z github.com.

const std = @import("std");
const builtin = @import("builtin");

pub const version = @import("version.zig");
pub const manifest = @import("manifest.zig");
pub const net = @import("net.zig");
pub const apply = @import("apply.zig");
pub const text = @import("text.zig");
pub const cli = @import("cli.zig");
pub const gui = if (builtin.os.tag == .windows) @import("gui.zig") else struct {};

const settings = @import("../settings.zig");

pub const Channel = settings.UpdateChannel;

/// Limit rozmiaru manifestu.
pub const max_manifest_size: usize = 64 * 1024;
/// Automatyczne sprawdzanie najwyżej raz na tyle sekund.
pub const auto_interval_s: i64 = 24 * 60 * 60;

pub const Check = union(enum) {
    /// Brak opublikowanych wydań w danym kanale.
    no_releases,
    up_to_date: manifest.Manifest,
    available: manifest.Manifest,

    pub fn deinit(self: *Check) void {
        switch (self.*) {
            .no_releases => {},
            .up_to_date, .available => |*m| m.deinit(),
        }
    }
};

/// Klasyfikacja manifestu względem wersji zainstalowanej (bez sieci).
/// Kanał stabilny nigdy nie proponuje wersji pre-release. Przejmuje `m`.
pub fn classify(m: manifest.Manifest, installed: []const u8, channel: Channel) !Check {
    var mm = m;
    errdefer mm.deinit();
    const cand = try version.parse(mm.version);
    if (channel == .stable and cand.isPrerelease()) return .{ .up_to_date = mm };
    const newer = version.order(cand, try version.parse(installed)) == .gt;
    return if (newer) .{ .available = mm } else .{ .up_to_date = mm };
}

/// Źródło danych — prawdziwa sieć albo podróbka w testach.
pub const Fetcher = struct {
    ctx: ?*anyopaque = null,
    getFn: *const fn (ctx: ?*anyopaque, alloc: std.mem.Allocator, url: []const u8, max: usize, opts: net.Options) net.Error![]u8,

    fn get(self: Fetcher, alloc: std.mem.Allocator, url: []const u8, max: usize, opts: net.Options) net.Error![]u8 {
        return self.getFn(self.ctx, alloc, url, max, opts);
    }
};

fn netGet(_: ?*anyopaque, alloc: std.mem.Allocator, url: []const u8, max: usize, opts: net.Options) net.Error![]u8 {
    return net.getWith(alloc, url, max, opts);
}

pub const real_fetcher: Fetcher = .{ .getFn = netGet };

pub const CheckError = error{
    /// Manifest wybranego wydania podaje inną wersję niż tag.
    ManifestMismatch,
};

/// Sprawdza kanał i porównuje z bieżącą wersją programu.
pub fn check(alloc: std.mem.Allocator, channel: Channel) !Check {
    return checkWith(alloc, channel, version.current, real_fetcher);
}

pub fn checkWith(alloc: std.mem.Allocator, channel: Channel, installed: []const u8, f: Fetcher) !Check {
    switch (channel) {
        .stable => {
            const body = f.get(alloc, manifest.latest_manifest_url, max_manifest_size, .{}) catch |e| switch (e) {
                error.NotFound => return .no_releases,
                else => return e,
            };
            defer alloc.free(body);
            return classify(try manifest.parse(alloc, body), installed, channel);
        },
        .@"test" => {
            const listing = f.get(alloc, manifest.releases_api_url, manifest.max_listing_size, .{ .allow_api_listing = true }) catch |e| switch (e) {
                error.NotFound => return .no_releases,
                else => return e,
            };
            defer alloc.free(listing);
            var arena = std.heap.ArenaAllocator.init(alloc);
            defer arena.deinit();
            const sel = try manifest.selectRelease(arena.allocator(), listing, channel) orelse return .no_releases;
            const body = try f.get(alloc, sel.manifest_url, max_manifest_size, .{});
            defer alloc.free(body);
            var m = try manifest.parse(alloc, body);
            if (!std.mem.eql(u8, m.version, sel.version)) {
                m.deinit();
                return error.ManifestMismatch;
            }
            return classify(m, installed, channel);
        },
    }
}

/// Czy wolno teraz sprawdzić automatycznie (ustawienie + limit raz na dobę).
pub fn shouldAutoCheck(s: settings.Settings, now_s: i64) bool {
    if (!s.update_check) return false;
    if (s.last_update_check <= 0 or s.last_update_check > now_s) return true;
    return now_s - s.last_update_check >= auto_interval_s;
}

test {
    std.testing.refAllDeclsRecursive(@This());
}

test "update: limit sprawdzania raz na dobę" {
    const now: i64 = 1_763_200_000;
    try std.testing.expect(shouldAutoCheck(.{}, now));
    try std.testing.expect(!shouldAutoCheck(.{ .update_check = false }, now));
    try std.testing.expect(!shouldAutoCheck(.{ .last_update_check = now - 3600 }, now));
    try std.testing.expect(shouldAutoCheck(.{ .last_update_check = now - auto_interval_s }, now));
    // Zegar cofnięty: czas z przyszłości nie blokuje sprawdzania na zawsze.
    try std.testing.expect(shouldAutoCheck(.{ .last_update_check = now + 999_999 }, now));
}

// --- podróbka sieci: adres -> treść ------------------------------------------

const FakeNet = struct {
    routes: []const [2][]const u8,
    /// Adresy, o które poproszono (do sprawdzenia, że kanał stabilny nie pyta API).
    asked_api: bool = false,

    fn get(ctx: ?*anyopaque, alloc: std.mem.Allocator, url: []const u8, max: usize, opts: net.Options) net.Error![]u8 {
        const self: *FakeNet = @ptrCast(@alignCast(ctx.?));
        if (!net.urlAllowed(url, 0, opts)) return error.DisallowedUrl;
        if (std.mem.eql(u8, url, manifest.releases_api_url)) self.asked_api = true;
        for (self.routes) |r| if (std.mem.eql(u8, r[0], url)) {
            if (r[1].len > max) return error.TooLarge;
            return alloc.dupe(u8, r[1]) catch error.OutOfMemory;
        };
        return error.NotFound;
    }

    fn fetcher(self: *FakeNet) Fetcher {
        return .{ .ctx = self, .getFn = get };
    }
};

fn fakeManifest(comptime ver: []const u8) []const u8 {
    return "{\"version\":\"" ++ ver ++ "\",\"url\":\"" ++ manifest.release_prefix ++ "v" ++ ver ++ "/FerrumScope-" ++ ver ++
        "-windows-x64.zip\",\"sha256\":\"3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c\",\"size\":10,\"notes\":\"" ++ ver ++ "\"}";
}

fn manifestUrl(comptime ver: []const u8) []const u8 {
    return manifest.release_prefix ++ "v" ++ ver ++ "/" ++ manifest.manifest_name;
}

const fake_routes = [_][2][]const u8{
    // `releases/latest` = najnowsze wydanie stabilne.
    .{ manifest.latest_manifest_url, fakeManifest("0.2.0") },
    .{ manifest.releases_api_url, manifest.test_listing },
    .{ manifestUrl("0.2.0"), fakeManifest("0.2.0") },
    .{ manifestUrl("0.3.0-preview.1"), fakeManifest("0.3.0-preview.1") },
    .{ manifestUrl("0.3.0-preview.2"), fakeManifest("0.3.0-preview.2") },
    .{ manifestUrl("0.4.0"), fakeManifest("0.4.0") },
};

fn expectCheck(channel: Channel, installed: []const u8, routes: []const [2][]const u8, tag: std.meta.Tag(Check), ver: ?[]const u8) !void {
    var fake: FakeNet = .{ .routes = routes };
    var c = try checkWith(std.testing.allocator, channel, installed, fake.fetcher());
    defer c.deinit();
    try std.testing.expectEqual(tag, std.meta.activeTag(c));
    switch (c) {
        .no_releases => try std.testing.expect(ver == null),
        .up_to_date, .available => |m| try std.testing.expectEqualStrings(ver.?, m.version),
    }
    try std.testing.expectEqual(channel == .@"test", fake.asked_api);
}

test "update: kanał stabilny i testowy (podróbka sieci)" {
    // Stabilny: tylko 0.2.0 (pre-release i szkic pominięte), bez zapytania do API.
    try expectCheck(.stable, "0.2.0-dev", &fake_routes, .available, "0.2.0");
    try expectCheck(.stable, "0.2.0", &fake_routes, .up_to_date, "0.2.0");
    try expectCheck(.stable, "0.3.0-preview.1", &fake_routes, .up_to_date, "0.2.0");
    // Testowy: najnowsze nie-szkicowe wydanie = 0.3.0-preview.2 (szkic 0.4.0 pominięty).
    try expectCheck(.@"test", "0.2.0-dev", &fake_routes, .available, "0.3.0-preview.2");
    try expectCheck(.@"test", "0.2.0", &fake_routes, .available, "0.3.0-preview.2");
    try expectCheck(.@"test", "0.3.0-preview.1", &fake_routes, .available, "0.3.0-preview.2");
    try expectCheck(.@"test", "0.3.0-preview.2", &fake_routes, .up_to_date, "0.3.0-preview.2");
    // 0.3.0-preview.2 < 0.3.0: zainstalowane wydanie nie jest „aktualizowane” do preview.
    try expectCheck(.@"test", "0.3.0", &fake_routes, .up_to_date, "0.3.0-preview.2");
    // Brak wydań (404) w obu kanałach.
    try expectCheck(.stable, "0.2.0-dev", &.{}, .no_releases, null);
    try expectCheck(.@"test", "0.2.0-dev", &.{}, .no_releases, null);
    try expectCheck(.@"test", "0.2.0-dev", &.{.{ manifest.releases_api_url, "[]" }}, .no_releases, null);
}

test "update: odrzucenia w kanałach" {
    const a = std.testing.allocator;
    // Manifest wybranego wydania podaje inną wersję niż tag.
    {
        var fake: FakeNet = .{ .routes = &.{
            .{ manifest.releases_api_url, manifest.test_listing },
            .{ manifestUrl("0.3.0-preview.2"), fakeManifest("0.3.0-preview.1") },
        } };
        try std.testing.expectError(error.ManifestMismatch, checkWith(a, .@"test", "0.2.0", fake.fetcher()));
    }
    // Kanał stabilny: manifest `latest` z wersją pre-release nie jest proponowany.
    {
        var fake: FakeNet = .{ .routes = &.{.{ manifest.latest_manifest_url, fakeManifest("0.9.0-rc.1") }} };
        var c = try checkWith(a, .stable, "0.2.0", fake.fetcher());
        defer c.deinit();
        try std.testing.expect(c == .up_to_date);
    }
    // Lista wydań nie jest JSON-em tablicy.
    {
        var fake: FakeNet = .{ .routes = &.{.{ manifest.releases_api_url, "{\"message\":\"API rate limit exceeded\"}" }} };
        try std.testing.expectError(error.InvalidListing, checkWith(a, .@"test", "0.2.0", fake.fetcher()));
    }
}
