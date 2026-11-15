//! Plakietka procesora / karty graficznej (róg zakładek CPU i Grafika).
//!
//! Kolejność wyboru obrazu:
//!   1. **obraz użytkownika** z `data\images\` obok programu (najwyższy priorytet),
//!   2. **logo dołączone** z `assets/logos/` (Wikimedia Commons, oznaczone jako
//!      public domain; znaki towarowe właścicieli, użyte tylko do identyfikacji;
//!      katalog poza licencją GPL-3.0 — `assets/logos/SOURCES.md`), łańcuch
//!      `logoKeys`: seria → marka → producent,
//!   3. **własna rysowana plakietka** (kafelek z tekstem producent / seria / model)
//!      — zawsze dostępna, także dla nieznanych producentów.
//!
//! Obrazy użytkownika — kolejność szukania (`imageCandidates`):
//!   CPU: `cpu\<producent>-<seria>-<model>.png` → `cpu\<producent>-<seria>.png`
//!        → `cpu\<producent>.png`
//!   GPU: `gpu\<vid>-<did>.png` (np. `1002-744c`) → `gpu\<producent>-<seria>-<model>.png`
//!        → `gpu\<producent>-<seria>.png` → `gpu\<producent>.png`
//! Nazwy: małe litery, znaki inne niż litery/cyfry zamienione na `-`.
//!
//! Moduł jest czysty (bez Win32) i testowany; rysowanie i WIC są w GUI.

const std = @import("std");

pub const Scheme = enum {
    /// Ciemny kafelek, pomarańczowy akcent (AMD CPU).
    amd_cpu,
    /// Ciemny kafelek, czerwony akcent (AMD GPU).
    amd_gpu,
    /// Niebieski kafelek (Intel).
    intel,
    /// Ciemny kafelek, zielony akcent (NVIDIA).
    nvidia,
    /// Neutralny szary.
    neutral,

    /// (tło, akcent, tekst) jako COLORREF 0x00BBGGRR.
    pub fn colors(self: Scheme) struct { bg: u32, accent: u32, text: u32 } {
        return switch (self) {
            .amd_cpu => .{ .bg = 0x0026_2626, .accent = 0x0020_7AE8, .text = 0x00F0_F0F0 },
            .amd_gpu => .{ .bg = 0x0026_2226, .accent = 0x0040_30D8, .text = 0x00F0_F0F0 },
            .intel => .{ .bg = 0x00B5_6800, .accent = 0x00FF_E0B0, .text = 0x00FF_FFFF },
            .nvidia => .{ .bg = 0x0024_2424, .accent = 0x0000_B976, .text = 0x00F0_F0F0 },
            .neutral => .{ .bg = 0x0060_6060, .accent = 0x00D0_D0D0, .text = 0x00FF_FFFF },
        };
    }
};

pub const Badge = struct {
    vendor: []const u8 = "",
    series: []const u8 = "",
    model: []const u8 = "",
    scheme: Scheme = .neutral,
    /// Tylko GPU: identyfikatory PCI (0 = nieznane).
    vid: u16 = 0,
    did: u16 = 0,
};

const Buf = struct {
    data: [192]u8 = undefined,
    len: usize = 0,

    fn add(self: *Buf, s: []const u8) []const u8 {
        const start = self.len;
        const n = @min(s.len, self.data.len - self.len);
        @memcpy(self.data[self.len..][0..n], s[0..n]);
        self.len += n;
        return self.data[start..self.len];
    }
};

/// Pamięć na napisy plakietki (wynik żyje razem z tą strukturą).
pub const Text = struct {
    buf: Buf = .{},
    badge: Badge = .{},
};

fn upperInto(t: *Text, s: []const u8) []const u8 {
    const start = t.buf.len;
    for (s) |c| {
        if (t.buf.len >= t.buf.data.len) break;
        t.buf.data[t.buf.len] = std.ascii.toUpper(c);
        t.buf.len += 1;
    }
    return t.buf.data[start..t.buf.len];
}

/// Słowa brand stringu bez znaczków (R)/(TM)/(C) i bez „Processor”, „CPU”, „xx-Core”.
fn words(brand: []const u8, out: *[16][]const u8) [][]const u8 {
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, brand, " @");
    while (it.next()) |raw| {
        var wd = raw;
        for ([_][]const u8{ "(R)", "(TM)", "(tm)", "(r)", "(C)" }) |mark| {
            if (std.mem.indexOf(u8, wd, mark)) |i| wd = wd[0..i];
        }
        if (wd.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(wd, "processor") or std.ascii.eqlIgnoreCase(wd, "cpu")) continue;
        if (std.ascii.endsWithIgnoreCase(wd, "-core")) continue;
        if (std.mem.endsWith(u8, wd, "GHz")) continue;
        if (n < out.len) {
            out[n] = wd;
            n += 1;
        }
    }
    return out[0..n];
}

/// Plakietka CPU z producenta (`amd`/`intel`/…) i brand stringu CPUID.
pub fn fromCpu(t: *Text, vendor: []const u8, brand: []const u8) void {
    var wb: [16][]const u8 = undefined;
    const ws = words(brand, &wb);
    var b: Badge = .{};
    if (std.ascii.eqlIgnoreCase(vendor, "amd")) {
        b.vendor = "AMD";
        b.scheme = .amd_cpu;
        // „AMD Ryzen 7 5800X3D”, „AMD Ryzen Threadripper 3970X”, „AMD EPYC 7763”.
        var i: usize = if (ws.len > 0 and std.ascii.eqlIgnoreCase(ws[0], "AMD")) 1 else 0;
        if (i < ws.len) {
            const fam = ws[i];
            i += 1;
            const tier_is_word = i < ws.len and (ws[i].len <= 2 or std.ascii.eqlIgnoreCase(ws[i], "Threadripper") or std.ascii.eqlIgnoreCase(ws[i], "PRO") or std.ascii.eqlIgnoreCase(ws[i], "AI"));
            if (std.ascii.eqlIgnoreCase(fam, "Ryzen") and tier_is_word and i + 1 < ws.len) {
                const s0 = t.buf.len;
                _ = upperInto(t, fam);
                _ = t.buf.add(" ");
                _ = upperInto(t, ws[i]);
                b.series = t.buf.data[s0..t.buf.len];
                i += 1;
            } else b.series = upperInto(t, fam);
            if (i < ws.len) b.model = t.buf.add(ws[i]);
        }
    } else if (std.ascii.eqlIgnoreCase(vendor, "intel")) {
        b.vendor = "Intel";
        b.scheme = .intel;
        // „Intel(R) Core(TM) i7-12700K”, „Intel(R) Core(TM) Ultra 7 265K”, „Intel(R) Xeon(R) Gold 6338”.
        var i: usize = if (ws.len > 0 and std.ascii.eqlIgnoreCase(ws[0], "Intel")) 1 else 0;
        if (i < ws.len) {
            const fam = ws[i];
            i += 1;
            if (std.ascii.eqlIgnoreCase(fam, "Core") and i < ws.len) {
                const nxt = ws[i];
                if (nxt.len >= 2 and (nxt[0] == 'i' or nxt[0] == 'I') and std.mem.indexOfScalar(u8, nxt, '-') != null) {
                    const dash = std.mem.indexOfScalar(u8, nxt, '-').?;
                    const s0 = t.buf.len;
                    _ = t.buf.add("CORE ");
                    _ = t.buf.add(nxt[0..dash]);
                    b.series = t.buf.data[s0..t.buf.len];
                    b.model = t.buf.add(nxt[dash + 1 ..]);
                } else if (std.ascii.eqlIgnoreCase(nxt, "Ultra") and i + 2 < ws.len + 1) {
                    const s0 = t.buf.len;
                    _ = t.buf.add("CORE ULTRA");
                    if (i + 1 < ws.len) {
                        _ = t.buf.add(" ");
                        _ = t.buf.add(ws[i + 1]);
                    }
                    b.series = t.buf.data[s0..t.buf.len];
                    if (i + 2 < ws.len) b.model = t.buf.add(ws[i + 2]);
                } else {
                    b.series = "CORE";
                    b.model = t.buf.add(nxt);
                }
            } else {
                b.series = upperInto(t, fam);
                if (i < ws.len) b.model = t.buf.add(ws[i]);
            }
        }
    } else {
        b.vendor = if (vendor.len > 0) upperInto(t, vendor) else "CPU";
        if (ws.len > 0) b.series = t.buf.add(ws[0]);
        if (ws.len > 1) b.model = t.buf.add(ws[1]);
    }
    t.badge = b;
}

/// Plakietka GPU z identyfikatora producenta PCI i nazwy ze sterownika.
pub fn fromGpu(t: *Text, vid: u16, did: u16, name: []const u8) void {
    var wb: [16][]const u8 = undefined;
    const ws = words(name, &wb);
    var b: Badge = .{ .vid = vid, .did = did };
    var i: usize = 0;
    switch (vid) {
        0x1002 => {
            b.vendor = "AMD";
            b.scheme = .amd_gpu;
        },
        0x10DE => {
            b.vendor = "NVIDIA";
            b.scheme = .nvidia;
        },
        0x8086 => {
            b.vendor = "Intel";
            b.scheme = .intel;
        },
        else => b.vendor = "GPU",
    }
    if (ws.len > 0 and (std.ascii.eqlIgnoreCase(ws[0], "AMD") or std.ascii.eqlIgnoreCase(ws[0], "NVIDIA") or std.ascii.eqlIgnoreCase(ws[0], "Intel"))) i = 1;
    // Seria = marka + linia („Radeon RX”, „GeForce RTX”, „Arc A”); model = reszta.
    if (i < ws.len) {
        const s0 = t.buf.len;
        _ = upperInto(t, ws[i]);
        i += 1;
        if (i < ws.len and ws[i].len <= 3 and std.ascii.isAlphabetic(ws[i][0])) {
            _ = t.buf.add(" ");
            _ = upperInto(t, ws[i]);
            i += 1;
        }
        b.series = t.buf.data[s0..t.buf.len];
        if (i < ws.len) {
            const m0 = t.buf.len;
            while (i < ws.len) : (i += 1) {
                if (t.buf.len > m0) _ = t.buf.add(" ");
                _ = t.buf.add(ws[i]);
            }
            b.model = t.buf.data[m0..t.buf.len];
        }
    }
    t.badge = b;
}

/// Nazwa pliku: małe litery, ciągi znaków spoza [a-z0-9] → pojedynczy `-`.
pub fn normalize(out: []u8, parts: []const []const u8) []const u8 {
    var n: usize = 0;
    var dash = false;
    for (parts) |p| {
        if (n > 0) dash = true;
        for (p) |c| {
            if (std.ascii.isAlphanumeric(c)) {
                if (dash and n > 0 and n < out.len) {
                    out[n] = '-';
                    n += 1;
                }
                dash = false;
                if (n < out.len) {
                    out[n] = std.ascii.toLower(c);
                    n += 1;
                }
            } else dash = true;
        }
    }
    return out[0..n];
}

pub const Kind = enum { cpu, gpu };

/// Ścieżki względne (wzgl. `data\images\`) w kolejności prób.
pub fn imageCandidates(kind: Kind, b: Badge, storage: *[4][96]u8, out: *[4][]const u8) [][]const u8 {
    var n: usize = 0;
    const dir = if (kind == .cpu) "cpu\\" else "gpu\\";
    const add = struct {
        fn f(st: *[4][96]u8, o: *[4][]const u8, cnt: *usize, d: []const u8, stem: []const u8) void {
            if (stem.len == 0 or cnt.* >= o.len) return;
            const s = std.fmt.bufPrint(&st[cnt.*], "{s}{s}.png", .{ d, stem }) catch return;
            for (o[0..cnt.*]) |prev| if (std.mem.eql(u8, prev, s)) return;
            o[cnt.*] = s;
            cnt.* += 1;
        }
    }.f;
    var tmp: [96]u8 = undefined;
    if (kind == .gpu and b.vid != 0 and b.did != 0) {
        const s = std.fmt.bufPrint(&tmp, "{x:0>4}-{x:0>4}", .{ b.vid, b.did }) catch "";
        add(storage, out, &n, dir, s);
    }
    if (b.model.len > 0) add(storage, out, &n, dir, normalize(&tmp, &.{ b.vendor, b.series, b.model }));
    if (b.series.len > 0) add(storage, out, &n, dir, normalize(&tmp, &.{ b.vendor, b.series }));
    add(storage, out, &n, dir, normalize(&tmp, &.{b.vendor}));
    return out[0..n];
}

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

const testing = std.testing;

test "badge: AMD Ryzen z brand stringu" {
    var t: Text = .{};
    fromCpu(&t, "amd", "AMD Ryzen 7 5800X3D 8-Core Processor           ");
    try testing.expectEqualStrings("AMD", t.badge.vendor);
    try testing.expectEqualStrings("RYZEN 7", t.badge.series);
    try testing.expectEqualStrings("5800X3D", t.badge.model);
    try testing.expectEqual(Scheme.amd_cpu, t.badge.scheme);

    var t2: Text = .{};
    fromCpu(&t2, "amd", "AMD EPYC 7763 64-Core Processor");
    try testing.expectEqualStrings("EPYC", t2.badge.series);
    try testing.expectEqualStrings("7763", t2.badge.model);

    var t3: Text = .{};
    fromCpu(&t3, "amd", "AMD Ryzen Threadripper 3970X 32-Core Processor");
    try testing.expectEqualStrings("RYZEN THREADRIPPER", t3.badge.series);
    try testing.expectEqualStrings("3970X", t3.badge.model);
}

test "badge: Intel Core i7 / Core Ultra / Xeon" {
    var t: Text = .{};
    fromCpu(&t, "intel", "12th Gen Intel(R) Core(TM) i7-12700K");
    // „12th Gen” przed „Intel” — producent i tak z CPUID, seria z „Core”.
    try testing.expectEqualStrings("Intel", t.badge.vendor);
    var t2: Text = .{};
    fromCpu(&t2, "intel", "Intel(R) Core(TM) i9-13900K");
    try testing.expectEqualStrings("CORE i9", t2.badge.series);
    try testing.expectEqualStrings("13900K", t2.badge.model);
    var t3: Text = .{};
    fromCpu(&t3, "intel", "Intel(R) Core(TM) Ultra 7 265K");
    try testing.expectEqualStrings("CORE ULTRA 7", t3.badge.series);
    try testing.expectEqualStrings("265K", t3.badge.model);
    var t4: Text = .{};
    fromCpu(&t4, "intel", "Intel(R) Xeon(R) Gold 6338 CPU @ 2.00GHz");
    try testing.expectEqualStrings("XEON", t4.badge.series);
    try testing.expectEqualStrings("Gold", t4.badge.model);
}

test "badge: GPU AMD / NVIDIA" {
    var t: Text = .{};
    fromGpu(&t, 0x1002, 0x744C, "AMD Radeon RX 7900 XTX");
    try testing.expectEqualStrings("AMD", t.badge.vendor);
    try testing.expectEqualStrings("RADEON RX", t.badge.series);
    try testing.expectEqualStrings("7900 XTX", t.badge.model);
    var t2: Text = .{};
    fromGpu(&t2, 0x10DE, 0x2684, "NVIDIA GeForce RTX 4090");
    try testing.expectEqualStrings("GEFORCE RTX", t2.badge.series);
    try testing.expectEqualStrings("4090", t2.badge.model);
    try testing.expectEqual(Scheme.nvidia, t2.badge.scheme);
}

test "badge: kolejność szukania obrazów użytkownika (CPU)" {
    var t: Text = .{};
    fromCpu(&t, "amd", "AMD Ryzen 7 5800X3D 8-Core Processor");
    var st: [4][96]u8 = undefined;
    var out: [4][]const u8 = undefined;
    const c = imageCandidates(.cpu, t.badge, &st, &out);
    try testing.expectEqual(@as(usize, 3), c.len);
    try testing.expectEqualStrings("cpu\\amd-ryzen-7-5800x3d.png", c[0]);
    try testing.expectEqualStrings("cpu\\amd-ryzen-7.png", c[1]);
    try testing.expectEqualStrings("cpu\\amd.png", c[2]);
}

test "badge: kolejność szukania obrazów użytkownika (GPU: ID urządzenia najpierw)" {
    var t: Text = .{};
    fromGpu(&t, 0x1002, 0x744C, "AMD Radeon RX 7900 XTX");
    var st: [4][96]u8 = undefined;
    var out: [4][]const u8 = undefined;
    const c = imageCandidates(.gpu, t.badge, &st, &out);
    try testing.expectEqual(@as(usize, 4), c.len);
    try testing.expectEqualStrings("gpu\\1002-744c.png", c[0]);
    try testing.expectEqualStrings("gpu\\amd-radeon-rx-7900-xtx.png", c[1]);
    try testing.expectEqualStrings("gpu\\amd-radeon-rx.png", c[2]);
    try testing.expectEqualStrings("gpu\\amd.png", c[3]);
}

test "badge: brak danych — tylko producent, bez duplikatów" {
    var st: [4][96]u8 = undefined;
    var out: [4][]const u8 = undefined;
    const c = imageCandidates(.cpu, .{ .vendor = "VIA" }, &st, &out);
    try testing.expectEqual(@as(usize, 1), c.len);
    try testing.expectEqualStrings("cpu\\via.png", c[0]);
    var nb: [32]u8 = undefined;
    try testing.expectEqualStrings("amd-ryzen-7", normalize(&nb, &.{ "AMD", "  RYZEN 7 " }));
}

// ---------------------------------------------------------------------------
// Logo dołączone do programu (assets/logos, poza licencją GPL — SOURCES.md)
// ---------------------------------------------------------------------------

/// Klucze logo (nazwy plików bez `.png`) od najbardziej szczegółowego:
/// „seria dokładnie” → krótsza seria → marka → producent. Np. `amd-ryzen-7`
/// → `amd-ryzen` → `amd`; `intel-core-ultra-7` → `intel-core-ultra` →
/// `intel-core` → `intel`. Brak pasującego pliku = rysowana plakietka.
pub fn logoKeys(b: Badge, storage: *[6][64]u8, out: *[6][]const u8) [][]const u8 {
    var full: [64]u8 = undefined;
    var s = normalize(&full, &.{ b.vendor, b.series });
    var n: usize = 0;
    while (s.len > 0 and n < out.len) {
        @memcpy(storage[n][0..s.len], s);
        out[n] = storage[n][0..s.len];
        n += 1;
        const dash = std.mem.lastIndexOfScalar(u8, s, '-') orelse break;
        s = s[0..dash];
    }
    return out[0..n];
}

test "badge: łańcuch logo — seria, marka, producent" {
    var st: [6][64]u8 = undefined;
    var out: [6][]const u8 = undefined;
    var t: Text = .{};
    fromCpu(&t, "amd", "AMD Ryzen 7 5800X3D 8-Core Processor");
    const k = logoKeys(t.badge, &st, &out);
    try testing.expectEqual(@as(usize, 3), k.len);
    try testing.expectEqualStrings("amd-ryzen-7", k[0]);
    try testing.expectEqualStrings("amd-ryzen", k[1]);
    try testing.expectEqualStrings("amd", k[2]);

    var t2: Text = .{};
    fromCpu(&t2, "intel", "Intel(R) Core(TM) Ultra 7 265K");
    const k2 = logoKeys(t2.badge, &st, &out);
    try testing.expectEqualStrings("intel-core-ultra-7", k2[0]);
    try testing.expectEqualStrings("intel", k2[k2.len - 1]);

    var t3: Text = .{};
    fromGpu(&t3, 0x10DE, 0x2684, "NVIDIA GeForce RTX 4090");
    const k3 = logoKeys(t3.badge, &st, &out);
    try testing.expectEqualStrings("nvidia-geforce-rtx", k3[0]);
    try testing.expectEqualStrings("nvidia-geforce", k3[1]);

    // Nieznany producent: tylko jego nazwa — i tak nie będzie pliku, zostaje rysunek.
    const k4 = logoKeys(.{ .vendor = "CPU" }, &st, &out);
    try testing.expectEqual(@as(usize, 1), k4.len);
}
