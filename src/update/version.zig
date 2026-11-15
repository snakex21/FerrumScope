//! Wersje semantyczne (SemVer 2.0.0): parsowanie i porównanie.
//!
//! `MAJOR.MINOR.PATCH[-pre][+build]`, opcjonalny prefiks `v`. Metadane
//! budowania (`+...`) są sprawdzane składniowo i pomijane przy porównaniu.
//! Wydanie z sufiksem pre-release jest starsze niż to samo wydanie bez niego
//! (`0.2.0-preview` < `0.2.0`), a identyfikatory porównujemy po kolei:
//! liczbowe liczbowo, liczbowe przed alfanumerycznymi, krótszy zestaw przed
//! dłuższym przy wspólnym początku (`0.2.0-preview.1` < `0.2.0-preview.2`).

const std = @import("std");

/// Wersja bieżącego programu (jedno źródło prawdy: `present.zig`).
pub const current = @import("../present.zig").version;

pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,
    /// Część pre-release bez myślnika (wskazuje w tekst źródłowy); pusta = wydanie.
    pre: []const u8 = "",

    pub fn isPrerelease(self: Version) bool {
        return self.pre.len > 0;
    }
};

pub const ParseError = error{InvalidVersion};

fn parseNum(s: []const u8) ParseError!u64 {
    if (s.len == 0) return error.InvalidVersion;
    if (s.len > 1 and s[0] == '0') return error.InvalidVersion;
    for (s) |c| if (!std.ascii.isDigit(c)) return error.InvalidVersion;
    return std.fmt.parseInt(u64, s, 10) catch error.InvalidVersion;
}

fn isNumeric(id: []const u8) bool {
    for (id) |c| if (!std.ascii.isDigit(c)) return false;
    return id.len > 0;
}

/// Identyfikatory rozdzielone kropkami: niepuste, `[0-9A-Za-z-]`.
fn validIdents(s: []const u8, numeric_rules: bool) bool {
    if (s.len == 0) return false;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |id| {
        if (id.len == 0) return false;
        for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-')) return false;
        if (numeric_rules and isNumeric(id) and id.len > 1 and id[0] == '0') return false;
    }
    return true;
}

pub fn parse(text: []const u8) ParseError!Version {
    var s = std.mem.trim(u8, text, " \t\r\n");
    if (s.len > 0 and (s[0] == 'v' or s[0] == 'V')) s = s[1..];
    if (s.len == 0 or s.len > 128) return error.InvalidVersion;
    if (std.mem.indexOfScalar(u8, s, '+')) |plus| {
        if (!validIdents(s[plus + 1 ..], false)) return error.InvalidVersion;
        s = s[0..plus];
    }
    var pre: []const u8 = "";
    if (std.mem.indexOfScalar(u8, s, '-')) |dash| {
        pre = s[dash + 1 ..];
        if (!validIdents(pre, true)) return error.InvalidVersion;
        s = s[0..dash];
    }
    var it = std.mem.splitScalar(u8, s, '.');
    const major = try parseNum(it.next() orelse return error.InvalidVersion);
    const minor = try parseNum(it.next() orelse return error.InvalidVersion);
    const patch = try parseNum(it.next() orelse return error.InvalidVersion);
    if (it.next() != null) return error.InvalidVersion;
    return .{ .major = major, .minor = minor, .patch = patch, .pre = pre };
}

fn orderIdent(a: []const u8, b: []const u8) std.math.Order {
    const an = isNumeric(a);
    const bn = isNumeric(b);
    if (an and bn) {
        // Długość bez zer wiodących rozstrzyga, potem leksykografia — bez przepełnienia.
        if (a.len != b.len) return std.math.order(a.len, b.len);
        return std.mem.order(u8, a, b);
    }
    if (an) return .lt;
    if (bn) return .gt;
    return std.mem.order(u8, a, b);
}

pub fn order(a: Version, b: Version) std.math.Order {
    inline for (.{ "major", "minor", "patch" }) |f| {
        const o = std.math.order(@field(a, f), @field(b, f));
        if (o != .eq) return o;
    }
    if (a.pre.len == 0 and b.pre.len == 0) return .eq;
    if (a.pre.len == 0) return .gt;
    if (b.pre.len == 0) return .lt;
    var ia = std.mem.splitScalar(u8, a.pre, '.');
    var ib = std.mem.splitScalar(u8, b.pre, '.');
    while (true) {
        const x = ia.next();
        const y = ib.next();
        if (x == null and y == null) return .eq;
        if (x == null) return .lt;
        if (y == null) return .gt;
        const o = orderIdent(x.?, y.?);
        if (o != .eq) return o;
    }
}

/// `true`, gdy `candidate` jest nowsza od `installed`.
pub fn isNewer(candidate: []const u8, installed: []const u8) ParseError!bool {
    return order(try parse(candidate), try parse(installed)) == .gt;
}

// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectOrder(a: []const u8, b: []const u8, o: std.math.Order) !void {
    try testing.expectEqual(o, order(try parse(a), try parse(b)));
    try testing.expectEqual(o.invert(), order(try parse(b), try parse(a)));
}

test "version: parsowanie" {
    const v = try parse("v1.20.3-rc.1+build.5");
    try testing.expectEqual(@as(u64, 1), v.major);
    try testing.expectEqual(@as(u64, 20), v.minor);
    try testing.expectEqual(@as(u64, 3), v.patch);
    try testing.expectEqualStrings("rc.1", v.pre);
    try testing.expect(v.isPrerelease());
    try testing.expect(!(try parse("0.2.0")).isPrerelease());
    _ = try parse(current);

    for ([_][]const u8{ "", "1", "1.2", "1.2.3.4", "01.2.3", "1.2.x", "1.2.3-", "1.2.3-a..b", "1.2.3-01", "1.2.3+", "1.2.3-a b", "v", "-1.2.3" }) |bad| {
        try testing.expectError(error.InvalidVersion, parse(bad));
    }
}

test "version: porównanie z pre-release" {
    try expectOrder("0.2.0-preview", "0.2.0", .lt);
    try expectOrder("0.2.0-preview.2", "0.2.0-preview.1", .gt);
    try expectOrder("0.2.0-preview.10", "0.2.0-preview.9", .gt);
    try expectOrder("0.2.0-dev", "0.2.0", .lt);
    try expectOrder("0.2.0-dev", "0.2.0-preview", .lt);
    try expectOrder("0.2.0", "0.1.9", .gt);
    try expectOrder("1.0.0", "0.99.99", .gt);
    try expectOrder("0.2.1-dev", "0.2.0", .gt);
    try expectOrder("1.0.0-alpha", "1.0.0-alpha.1", .lt);
    try expectOrder("1.0.0-alpha.1", "1.0.0-alpha.beta", .lt);
    try expectOrder("1.0.0-beta.11", "1.0.0-rc.1", .lt);
    try expectOrder("1.0.0+build.1", "1.0.0+build.2", .eq);
    try expectOrder("v1.0.0", "1.0.0", .eq);
    try testing.expect(try isNewer("0.2.0", "0.2.0-dev"));
    try testing.expect(!try isNewer("0.2.0-dev", "0.2.0-dev"));
    try testing.expect(!try isNewer("0.1.0", "0.2.0-dev"));
}
