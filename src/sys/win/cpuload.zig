//! Obciążenie i zegar CPU **bez sterownika** (Windows).
//!
//! * Obciążenie: `NtQuerySystemInformation(SystemProcessorPerformanceInformation)`
//!   — czasy idle/kernel/user każdego procesora logicznego; obciążenie to
//!   `1 - Δidle / Δ(kernel + user)` między dwiema próbkami. `KernelTime`
//!   zawiera czas bezczynności (dokumentacja winternl.h), stąd tak liczymy.
//!   Ograniczenie: API zwraca procesory **bieżącej grupy** (≤ 64).
//! * Zegar: **oszacowanie**. `CallNtPowerInformation(ProcessorInformation)`
//!   podaje `MaxMhz` (zegar bazowy wg ACPI/_PSS) i `CurrentMhz`, który na
//!   nowszych systemach bywa po prostu bazowym. Lepsze oszacowanie daje licznik
//!   PDH `\Processor Information(*)\% Processor Performance` (ten sam, którego
//!   używa Menedżer zadań): `zegar ≈ MaxMhz × %Performance / 100`.
//!   To NIE jest odczyt APERF/MPERF — ten wymaga sterownika (zakładka Czujniki).

const std = @import("std");

const DWORD = u32;
const LONG = i32;
const BOOL = i32;
const HANDLE = ?*anyopaque;

const SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION = extern struct {
    IdleTime: i64,
    KernelTime: i64,
    UserTime: i64,
    DpcTime: i64,
    InterruptTime: i64,
    InterruptCount: u32,
};

const PROCESSOR_POWER_INFORMATION = extern struct {
    Number: u32,
    MaxMhz: u32,
    CurrentMhz: u32,
    MhzLimit: u32,
    MaxIdleState: u32,
    CurrentIdleState: u32,
};

comptime {
    std.debug.assert(@sizeOf(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION) == 48);
    std.debug.assert(@sizeOf(PROCESSOR_POWER_INFORMATION) == 24);
}

extern "ntdll" fn NtQuerySystemInformation(class: u32, info: ?*anyopaque, len: u32, ret_len: ?*u32) callconv(.winapi) LONG;
extern "powrprof" fn CallNtPowerInformation(level: u32, in: ?*anyopaque, in_len: u32, out: ?*anyopaque, out_len: u32) callconv(.winapi) LONG;

const PDH_HQUERY = ?*anyopaque;
const PDH_HCOUNTER = ?*anyopaque;
const PDH_FMT_DOUBLE: DWORD = 0x00000200;
const PDH_FMT_NOCAP100: DWORD = 0x00008000;

const PDH_FMT_COUNTERVALUE = extern struct {
    CStatus: DWORD,
    doubleValue: f64,
};
const PDH_FMT_COUNTERVALUE_ITEM_W = extern struct {
    szName: ?[*:0]u16,
    FmtValue: PDH_FMT_COUNTERVALUE,
};

comptime {
    std.debug.assert(@sizeOf(PDH_FMT_COUNTERVALUE_ITEM_W) == 24);
}

extern "pdh" fn PdhOpenQueryW(src: ?[*:0]const u16, user: usize, q: *PDH_HQUERY) callconv(.winapi) LONG;
extern "pdh" fn PdhAddEnglishCounterW(q: PDH_HQUERY, path: [*:0]const u16, user: usize, c: *PDH_HCOUNTER) callconv(.winapi) LONG;
extern "pdh" fn PdhCollectQueryData(q: PDH_HQUERY) callconv(.winapi) LONG;
extern "pdh" fn PdhGetFormattedCounterArrayW(c: PDH_HCOUNTER, fmt: DWORD, size: *DWORD, count: *DWORD, items: ?*anyopaque) callconv(.winapi) LONG;
extern "pdh" fn PdhCloseQuery(q: PDH_HQUERY) callconv(.winapi) LONG;

pub const max_cpus = 64;

pub const Sample = struct {
    cpus: u32 = 0,
    /// Obciążenie per procesor logiczny, 0..100. `null` przed drugą próbką.
    load: [max_cpus]?f32 = @splat(null),
    total_load: ?f32 = null,
    /// Zegar bazowy z `ProcessorInformation.MaxMhz` (ACPI) — nie pomiar.
    base_mhz: ?u32 = null,
    /// `CurrentMhz` z tej samej struktury — często równy bazowemu.
    reported_mhz: ?u32 = null,
    /// Oszacowanie per CPU: `MaxMhz × %Processor Performance / 100`.
    est_mhz: [max_cpus]?f32 = @splat(null),
    est_avg_mhz: ?f32 = null,
    est_max_mhz: ?f32 = null,
    /// Czy licznik PDH był dostępny (gdy nie — zegar tylko z PowerInformation).
    pdh_ok: bool = false,
    load_error: ?[]const u8 = null,
};

pub const Sampler = struct {
    prev: [max_cpus]SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION = undefined,
    prev_n: u32 = 0,
    query: PDH_HQUERY = null,
    counter: PDH_HCOUNTER = null,
    pdh_ready: bool = false,
    /// Jeden ciągły bufor: PDH zapisuje tablicę elementów, a za nią nazwy instancji.
    pdh_buf: [32 * 1024]u8 align(8) = undefined,

    pub fn init(self: *Sampler) void {
        self.* = .{};
        _ = self.readTimes();
        if (PdhOpenQueryW(null, 0, &self.query) == 0) {
            const path = std.unicode.utf8ToUtf16LeStringLiteral("\\Processor Information(*)\\% Processor Performance");
            if (PdhAddEnglishCounterW(self.query, path, 0, &self.counter) == 0) {
                _ = PdhCollectQueryData(self.query);
                self.pdh_ready = true;
            }
        }
    }

    pub fn deinit(self: *Sampler) void {
        if (self.query != null) _ = PdhCloseQuery(self.query);
        self.query = null;
        self.pdh_ready = false;
    }

    fn readTimes(self: *Sampler) ?u32 {
        var cur: [max_cpus]SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION = undefined;
        var ret: u32 = 0;
        const st = NtQuerySystemInformation(8, &cur, @sizeOf(@TypeOf(cur)), &ret);
        if (st < 0) return null;
        const n: u32 = @intCast(@min(ret / @sizeOf(SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION), max_cpus));
        self.prev = cur;
        self.prev_n = n;
        return n;
    }

    pub fn sample(self: *Sampler) Sample {
        var out: Sample = .{};
        // --- obciążenie -------------------------------------------------------
        const old = self.prev;
        const old_n = self.prev_n;
        if (self.readTimes()) |n| {
            out.cpus = n;
            if (old_n == n and n > 0) {
                var sum_busy: f64 = 0;
                var sum_all: f64 = 0;
                for (0..n) |i| {
                    const a = old[i];
                    const b = self.prev[i];
                    const idle: f64 = @floatFromInt(b.IdleTime - a.IdleTime);
                    const all: f64 = @floatFromInt((b.KernelTime - a.KernelTime) + (b.UserTime - a.UserTime));
                    if (all > 0) {
                        const busy = std.math.clamp(all - idle, 0, all);
                        out.load[i] = @floatCast(100.0 * busy / all);
                        sum_busy += busy;
                        sum_all += all;
                    }
                }
                if (sum_all > 0) out.total_load = @floatCast(100.0 * sum_busy / sum_all);
            }
        } else out.load_error = "NtQuerySystemInformation(SystemProcessorPerformanceInformation) odrzuciło zapytanie";

        // --- zegar ---------------------------------------------------------------
        var ppi: [max_cpus]PROCESSOR_POWER_INFORMATION = undefined;
        const cpus = if (out.cpus > 0) out.cpus else 1;
        if (CallNtPowerInformation(11, null, 0, &ppi, @intCast(@sizeOf(PROCESSOR_POWER_INFORMATION) * cpus)) == 0) {
            out.base_mhz = ppi[0].MaxMhz;
            out.reported_mhz = ppi[0].CurrentMhz;
        }
        if (self.pdh_ready and out.base_mhz != null and PdhCollectQueryData(self.query) == 0) {
            var count: DWORD = 0;
            var sz: DWORD = self.pdh_buf.len;
            const st = PdhGetFormattedCounterArrayW(self.counter, PDH_FMT_DOUBLE | PDH_FMT_NOCAP100, &sz, &count, &self.pdh_buf);
            if (st == 0) {
                out.pdh_ok = true;
                const base: f64 = @floatFromInt(out.base_mhz.?);
                var sum: f64 = 0;
                var n: u32 = 0;
                var mx: f64 = 0;
                const items: [*]const PDH_FMT_COUNTERVALUE_ITEM_W = @ptrCast(&self.pdh_buf);
                const max_items = self.pdh_buf.len / @sizeOf(PDH_FMT_COUNTERVALUE_ITEM_W);
                for (items[0..@min(count, max_items)]) |it| {
                    if (it.FmtValue.CStatus != 0) continue;
                    const name = it.szName orelse continue;
                    const idx = instanceIndex(std.mem.span(name)) orelse continue;
                    const mhz = base * it.FmtValue.doubleValue / 100.0;
                    if (idx < max_cpus) out.est_mhz[idx] = @floatCast(mhz);
                    sum += mhz;
                    n += 1;
                    mx = @max(mx, mhz);
                }
                if (n > 0) {
                    out.est_avg_mhz = @floatCast(sum / @as(f64, @floatFromInt(n)));
                    out.est_max_mhz = @floatCast(mx);
                }
            }
        }
        return out;
    }
};

/// Nazwa instancji PDH „g,n” → indeks globalny (grupa × 64 + n). `_Total`
/// i sumy grup („0,_Total”) pomijamy.
fn instanceIndex(name: []const u16) ?usize {
    var buf: [32]u8 = undefined;
    if (name.len >= buf.len) return null;
    for (name, 0..) |c, i| buf[i] = if (c < 128) @intCast(c) else '?';
    const s = buf[0..name.len];
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse return null;
    const g = std.fmt.parseInt(usize, s[0..comma], 10) catch return null;
    const n = std.fmt.parseInt(usize, s[comma + 1 ..], 10) catch return null;
    return g * 64 + n;
}

test "cpuload: nazwy instancji PDH" {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expectEqual(@as(?usize, 3), instanceIndex(L("0,3")));
    try std.testing.expectEqual(@as(?usize, 65), instanceIndex(L("1,1")));
    try std.testing.expectEqual(@as(?usize, null), instanceIndex(L("0,_Total")));
    try std.testing.expectEqual(@as(?usize, null), instanceIndex(L("_Total")));
}
