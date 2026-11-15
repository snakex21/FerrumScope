//! FerrumScope — GUI (czysty Win32, bez zależności zewnętrznych).
//!
//! GUI jest **tylko konsumentem** tego samego pipeline'u co CLI:
//!   * zakładka „CPU": `native.create() -> probe.run -> embedded.load -> decode`,
//!     dokładnie jak `cmdCpu` w `main.zig`;
//!   * zakładka „Sensors": najpierw prawdziwy sterownik (`telemetry/windows.zig`),
//!     a gdy go nie ma — `NoMsrBackend` ze stanem `unavailable` i konkretną
//!     przyczyną. Backendu syntetycznego GUI **nie używa**: liczba w okienku
//!     wygląda jak pomiar, a syntetyczna pomiarem nie jest.
//!
//! Teksty powodów i jednostek pochodzą z `present.zig`, wspólnego z CLI — okno
//! i terminal muszą mówić to samo o tym samym stanie maszyny.
//!
//! Flaga testowa: `--tab=sensors` otwiera okno od razu na zakładce Sensors.

const std = @import("std");
const w = @import("gui/win32.zig");
const ferrum = @import("root.zig");
const present = @import("present.zig");
const embedded = @import("db/embedded.zig");

const model = ferrum.core.model;
const raw = ferrum.core.raw;
const native = ferrum.platform.native;
const probe = ferrum.probe.cpu;
const decoder = ferrum.decode.cpu_x86;
const msr = ferrum.telemetry.msr;
const metrics = ferrum.telemetry.metrics;
const catalog = ferrum.telemetry.catalog;
const engine = ferrum.telemetry.engine;
const win_msr = ferrum.telemetry.windows_msr;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const window_title = L("FerrumScope " ++ present.version);
const class_name = L("FerrumScopeGuiWindow");
const timer_id: usize = 1;
const refresh_ms: u32 = 1000;

// ---------------------------------------------------------------------------
// Stan okna
// ---------------------------------------------------------------------------

/// Uchwyty i parametry okna. Opcjonalne, bo `WM_SIZE` przychodzi już w trakcie
/// `CreateWindowExW`, zanim dzieci istnieją.
const App = struct {
    hwnd: ?w.HWND = null,
    tab: ?w.HWND = null,
    ttl_cpu: ?w.HWND = null,
    hdr_cpu: ?w.HWND = null,
    lv_cpu: ?w.HWND = null,
    ttl_sens: ?w.HWND = null,
    hdr_sens: ?w.HWND = null,
    lv_sens: ?w.HWND = null,
    font: ?w.HFONT = null,
    font_title: ?w.HFONT = null,
    row_imgs: ?w.HIMAGELIST = null,
    dpi: u32 = 96,
    cpu_rows: i32 = 0,
};
var app: App = .{};

/// Stan zakładki Sensors. Zmienne modułu, bo `win_msr.Backend.api()` bierze
/// wskaźnik na backend, a `Engine` — na tablicę pollerów: oba adresy muszą
/// żyć przez cały czas pracy okna.
const S = struct {
    var dev: win_msr.deviceIoTransport = .{};
    var real: win_msr.Backend = undefined;
    var real_open = false;
    var open_error: ?win_msr.OpenError = null;
    var engine_error: ?[]const u8 = null;
    var api: msr.Backend = undefined;
    var freq: engine.FreqState = undefined;
    var pollers: [1]engine.Poller = undefined;
    var eng: engine.Engine = undefined;
    var eng_ready = false;
    var samples: ?[]const metrics.Sample = null;
};

const alloc = std.heap.page_allocator;

// ---------------------------------------------------------------------------
// Pomocnicze: tekst i kontrolki
// ---------------------------------------------------------------------------

/// UTF-8 -> UTF-16 do bufora wywołującego, z obcięciem na granicy znaku.
/// Niepoprawny UTF-8 nie wywraca okna: znaki spoza ASCII zastępujemy `?`.
fn widen(buf: []u16, s: []const u8) [*:0]u16 {
    var n = @min(s.len, buf.len - 1);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    const len = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], s[0..n]) catch blk: {
        for (s[0..n], 0..) |c, i| buf[i] = if (c < 0x80) c else '?';
        break :blk n;
    };
    buf[len] = 0;
    return @ptrCast(buf.ptr);
}

/// `bufPrint` bez propagacji błędu: za długi tekst to sytuacja kosmetyczna,
/// ale mówimy o niej wprost zamiast pokazywać pustą komórkę.
fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, f, args) catch "(tekst za długi do wyświetlenia)";
}

fn lp(p: anytype) w.LPARAM {
    return @bitCast(@intFromPtr(p));
}

/// Skalowanie pikseli do DPI monitora. Wymiary w kodzie są „przy 96 DPI".
fn px(v: i32) i32 {
    return @divTrunc(v * @as(i32, @intCast(app.dpi)), 96);
}

fn setText(h: ?w.HWND, s: []const u8) void {
    var wb: [1024]u16 = undefined;
    if (h) |hh| _ = w.SetWindowTextW(hh, widen(&wb, s));
}

fn lvSetText(lv: w.HWND, row: i32, col: i32, s: []const u8) void {
    var wb: [1024]u16 = undefined;
    var item: w.LVITEMW = .{ .iSubItem = col, .pszText = widen(&wb, s) };
    _ = w.SendMessageW(lv, w.LVM_SETITEMTEXTW, @intCast(row), lp(&item));
}

fn lvAddRow(lv: w.HWND, row: i32, cols: []const []const u8, group: ?i32) void {
    var wb: [1024]u16 = undefined;
    var item: w.LVITEMW = .{ .mask = w.LVIF_TEXT, .iItem = row, .pszText = widen(&wb, cols[0]) };
    if (group) |g| {
        item.mask |= w.LVIF_GROUPID;
        item.iGroupId = g;
    }
    _ = w.SendMessageW(lv, w.LVM_INSERTITEMW, 0, lp(&item));
    for (cols[1..], 1..) |c, k| lvSetText(lv, row, @intCast(k), c);
}

fn lvAddColumn(lv: w.HWND, idx: i32, title: [*:0]const u16, width: i32) void {
    var col: w.LVCOLUMNW = .{
        .mask = w.LVCF_TEXT | w.LVCF_WIDTH | w.LVCF_SUBITEM,
        .cx = px(width),
        .pszText = @constCast(title),
        .iSubItem = idx,
    };
    _ = w.SendMessageW(lv, w.LVM_INSERTCOLUMNW, @intCast(idx), lp(&col));
}

/// Szerokości kolumn (przy 96 DPI). Ostatnia kolumna wypełnia resztę.
const cpu_cols = [_]i32{ 150, 260 };
const sens_cols = [_]i32{ 150, 90, 70 };

fn applyColumnWidths() void {
    if (app.lv_cpu) |lv| {
        for (cpu_cols, 0..) |cw, i| _ = w.SendMessageW(lv, w.LVM_SETCOLUMNWIDTH, i, px(cw));
        _ = w.SendMessageW(lv, w.LVM_SETCOLUMNWIDTH, cpu_cols.len, w.LVSCW_AUTOSIZE_USEHEADER);
    }
    if (app.lv_sens) |lv| {
        for (sens_cols, 0..) |cw, i| _ = w.SendMessageW(lv, w.LVM_SETCOLUMNWIDTH, i, px(cw));
        _ = w.SendMessageW(lv, w.LVM_SETCOLUMNWIDTH, sens_cols.len, w.LVSCW_AUTOSIZE_USEHEADER);
    }
}

/// Czcionka systemowa (zwykle Segoe UI) dla bieżącego DPI. Gdy system nie poda
/// metryk, budujemy Segoe UI 9 pt ręcznie — nigdy nie zostajemy na bitmapowym
/// `System`, który nie ma polskich znaków w każdej stronie kodowej.
fn makeFont(dpi: u32) ?w.HFONT {
    var ncm: w.NONCLIENTMETRICSW = .{};
    if (w.SystemParametersInfoForDpi(w.SPI_GETNONCLIENTMETRICS, @sizeOf(w.NONCLIENTMETRICSW), &ncm, 0, dpi) != 0) {
        if (w.CreateFontIndirectW(&ncm.lfMessageFont)) |f| return f;
    }
    var lf: w.LOGFONTW = .{
        .lfHeight = -@as(i32, @intCast((9 * dpi + 36) / 72)),
        .lfWeight = w.FW_NORMAL,
        .lfQuality = w.CLEARTYPE_QUALITY,
    };
    const face = L("Segoe UI");
    @memcpy(lf.lfFaceName[0..face.len], face);
    return w.CreateFontIndirectW(&lf);
}

/// Czcionka tytułu zakładki: ta sama rodzina co treść, 1,5× i semibold.
fn makeTitleFont(dpi: u32) ?w.HFONT {
    var lf: w.LOGFONTW = .{};
    var ncm: w.NONCLIENTMETRICSW = .{};
    if (w.SystemParametersInfoForDpi(w.SPI_GETNONCLIENTMETRICS, @sizeOf(w.NONCLIENTMETRICSW), &ncm, 0, dpi) != 0) {
        lf = ncm.lfMessageFont;
    } else {
        lf.lfHeight = -@as(i32, @intCast((9 * dpi + 36) / 72));
        const face = L("Segoe UI");
        @memcpy(lf.lfFaceName[0..face.len], face);
    }
    lf.lfHeight = @divTrunc(lf.lfHeight * 3, 2);
    lf.lfWeight = w.FW_SEMIBOLD;
    lf.lfQuality = w.CLEARTYPE_QUALITY;
    return w.CreateFontIndirectW(&lf);
}

fn applyFont() void {
    const f = app.font orelse return;
    const handles = [_]?w.HWND{ app.tab, app.hdr_cpu, app.lv_cpu, app.hdr_sens, app.lv_sens, app.ttl_cpu, app.ttl_sens };
    for (handles) |h| {
        if (h) |hh| _ = w.SendMessageW(hh, w.WM_SETFONT, @intFromPtr(f), 1);
    }
    if (app.font_title) |t| {
        for ([_]?w.HWND{ app.ttl_cpu, app.ttl_sens }) |h| {
            if (h) |hh| _ = w.SendMessageW(hh, w.WM_SETFONT, @intFromPtr(t), 1);
        }
    }
}

/// Wyższe wiersze list. ListView nie ma własności „wysokość wiersza"; bierze ją
/// z wysokości ikon, więc podajemy pustą image listę 1 px × 24 px.
fn applyRowHeight() void {
    const old = app.row_imgs;
    app.row_imgs = w.ImageList_Create(1, px(24), w.ILC_COLOR32, 1, 0);
    const il: w.LPARAM = if (app.row_imgs) |p| lp(p) else 0;
    for ([_]?w.HWND{ app.lv_cpu, app.lv_sens }) |h| {
        if (h) |hh| _ = w.SendMessageW(hh, w.LVM_SETIMAGELIST, w.LVSIL_SMALL, il);
    }
    if (old) |o| _ = w.ImageList_Destroy(o);
}

// ---------------------------------------------------------------------------
// Kolory tekstu (custom draw)
// ---------------------------------------------------------------------------

const Tone = enum { normal, muted, good, warn };

/// COLORREF = 0x00BBGGRR.
fn toneColor(t: Tone) u32 {
    return switch (t) {
        .normal => w.GetSysColor(w.COLOR_WINDOWTEXT),
        .muted => 0x0070_7070, // szary: źródła, jednostki, brak danych
        .good => 0x0010_7C10, // zielony: pomiar ok
        .warn => 0x0000_5AB4, // bursztyn: unavailable / synthetic / stale
    };
}

var cpu_muted: [256]bool = @splat(false);
var sens_tone: [64]Tone = @splat(.normal);
var sens_has_value: [64]bool = @splat(false);

fn cellTone(is_cpu: bool, row: usize, col: i32) Tone {
    if (is_cpu) {
        return switch (col) {
            1 => if (row < cpu_muted.len and cpu_muted[row]) .muted else .normal,
            2 => .muted,
            else => .normal,
        };
    }
    return switch (col) {
        1 => if (row < sens_has_value.len and sens_has_value[row]) .normal else .muted,
        2 => .muted,
        3 => if (row < sens_tone.len) sens_tone[row] else .normal,
        else => .normal,
    };
}

fn onCustomDraw(is_cpu: bool, cd: *w.NMLVCUSTOMDRAW) w.LRESULT {
    switch (cd.nmcd.dwDrawStage) {
        w.CDDS_PREPAINT => return w.CDRF_NOTIFYITEMDRAW,
        w.CDDS_ITEMPREPAINT => return w.CDRF_NOTIFYSUBITEMDRAW,
        w.CDDS_ITEMPREPAINT | w.CDDS_SUBITEM => {
            // Kolor ustawiamy dla każdej komórki: inaczej ostatni zostaje
            // „przyklejony" do kolejnych kolumn.
            cd.clrText = toneColor(cellTone(is_cpu, cd.nmcd.dwItemSpec, cd.iSubItem));
            return w.CDRF_NEWFONT;
        },
        else => return w.CDRF_DODEFAULT,
    }
}

// ---------------------------------------------------------------------------
// Zakładka CPU
// ---------------------------------------------------------------------------

/// Grupy listy CPU (nagłówki sekcji, zwijane).
const Group = enum(i32) { ident = 1, topo, cache, features, origin };
const groups = [_]struct { id: Group, title: []const u8 }{
    .{ .id = .ident, .title = "Identyfikacja" },
    .{ .id = .topo, .title = "Topologia" },
    .{ .id = .cache, .title = "Pamięć podręczna" },
    .{ .id = .features, .title = "Cechy (CPUID)" },
    .{ .id = .origin, .title = "Pochodzenie danych" },
};
var cpu_group: Group = .ident;

fn insertCpuGroups(lv: w.HWND) void {
    _ = w.SendMessageW(lv, w.LVM_ENABLEGROUPVIEW, 1, 0);
    for (groups) |g| {
        var wb: [128]u16 = undefined;
        var lg: w.LVGROUP = .{
            .mask = w.LVGF_HEADER | w.LVGF_GROUPID | w.LVGF_STATE,
            .pszHeader = widen(&wb, g.title),
            .iGroupId = @intFromEnum(g.id),
            .stateMask = w.LVGS_COLLAPSIBLE,
            .state = w.LVGS_COLLAPSIBLE,
        };
        _ = w.SendMessageW(lv, w.LVM_INSERTGROUP, std.math.maxInt(usize), lp(&lg));
    }
}

fn isPlaceholder(v: []const u8) bool {
    return std.mem.eql(u8, v, "unknown") or std.mem.eql(u8, v, "—") or std.mem.eql(u8, v, "unavailable");
}

fn cpuRow(field: []const u8, value: []const u8, source: []const u8) void {
    const lv = app.lv_cpu orelse return;
    const row = app.cpu_rows;
    lvAddRow(lv, row, &.{ field, value, source }, @intFromEnum(cpu_group));
    const r: usize = @intCast(row);
    if (r < cpu_muted.len) cpu_muted[r] = isPlaceholder(value);
    app.cpu_rows += 1;
}

/// Ten sam pipeline co `cmdCpu` + `report()` w trybie tekstowym. Pola, których
/// nie znamy, pokazujemy jako „unknown"/„—" **z powodem** w trzeciej kolumnie.
fn loadCpu() void {
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    var b3: [256]u8 = undefined;
    cpu_group = .ident;

    const res = probe.run(native.create());
    if (res.getStatus() != .ok) {
        setText(app.ttl_cpu, "Procesor niedostępny");
        setText(app.hdr_cpu, "Nie mogę odczytać CPU.");
        cpuRow("CPU", "unavailable", fmt(&b1, "probe.run: {s}", .{res.getStatus().toSlice()}));
        return;
    }
    const raw_info = res.unwrap().?;
    const db = embedded.load() catch {
        setText(app.ttl_cpu, "Baza HWDB niedostępna");
        setText(app.hdr_cpu, "Wbudowana baza HWDB jest uszkodzona — przebuduj projekt.");
        cpuRow("Baza HWDB", "unavailable", "embedded.load() odrzuciło nagłówek lub sumę kontrolną");
        return;
    };

    var info = model.CpuInfo{};
    const outcome = decoder.decode(&raw_info, db, &info);

    setText(app.hdr_cpu, fmt(&b1, "FerrumScope {s}  [native: CPUID na żywo]\r\nHWDB: {d} wpisów, rewizja {d}", .{
        present.version, db.count(), db.db_revision,
    }));

    var name_buf: [128]u8 = undefined;
    const display_name = info.displayName(&name_buf);
    setText(app.ttl_cpu, display_name);
    cpuRow("Nazwa", display_name, present.explainDisplay(info.display));
    cpuRow("Producent", info.vendor.toSlice(), "CPUID.0 EBX/EDX/ECX");
    if (info.brand_valid) {
        cpuRow("Brand string", info.brandSlice(), "CPUID 0x80000002..4");
    } else {
        cpuRow("Brand string", "—", "brak brand stringu w CPUID lub niewiarygodny");
    }
    cpuRow("Sygnatura", fmt(&b1, "0x{X:0>8}", .{info.signature.eax}), "CPUID.1 EAX");
    cpuRow("Family / Model / Stepping", fmt(&b1, "{d} / 0x{X:0>2} / {d}", .{
        info.display_family, info.display_model, info.stepping,
    }), "CPUID.1 EAX (display family/model)");

    if (info.microarchitecture) |m| {
        cpuRow("Mikroarchitektura", m, fmt(&b2, "HWDB (źródło: {s})", .{info.microarchitecture_source.toSlice()}));
    } else cpuRow("Mikroarchitektura", "unknown", "brak wpisu w HWDB");

    if (info.codename) |c| {
        cpuRow("Codename", c, fmt(&b2, "HWDB (źródło: {s})", .{info.codename_source.toSlice()}));
    } else cpuRow("Codename", "unknown", "brak wpisu w HWDB");

    // Nazwa steppingu to interpretacja, nie pomiar — zawsze ze źródłem i pewnością.
    if (info.stepping_name) |s| {
        cpuRow("Stepping (nazwa)", s, fmt(&b2, "źródło: {s}, pewność: {s}", .{
            info.stepping_name_source.toSlice(), info.stepping_name_provenance.confidence.toSlice(),
        }));
    } else cpuRow("Stepping (nazwa)", "—", "brak wpisu; surowy stepping z CPUID powyżej");

    if (info.socket_name) |s| {
        cpuRow("Socket", s, fmt(&b2, "źródło: {s}, pewność: {s}", .{
            info.socket_source.toSlice(), info.socket_confidence.toSlice(),
        }));
    } else cpuRow("Socket", "unknown", "brak wpisu w HWDB (gniazda nie zgadujemy)");

    if (info.variant) |v| {
        cpuRow("Wariant", v, fmt(&b2, "źródło: {s}", .{info.variant_source.toSlice()}));
    } else cpuRow("Wariant", "—", "brak wariantu w HWDB");

    // --- topologia ---------------------------------------------------------
    cpu_group = .topo;
    const topo_src = info.topology_source.toSlice();
    if (info.cores_physical == 0) {
        cpuRow("Rdzenie fizyczne", "unknown", fmt(&b2, "topologia nieustalona (źródło: {s})", .{topo_src}));
    } else if (!info.topology_confident) {
        cpuRow("Rdzenie fizyczne", fmt(&b1, "{d} (niepewne)", .{info.cores_physical}), fmt(&b2, "topologia niepewna (źródło: {s})", .{topo_src}));
    } else {
        cpuRow("Rdzenie fizyczne", fmt(&b1, "{d}", .{info.cores_physical}), fmt(&b2, "topologia: {s}", .{topo_src}));
    }
    if (info.threads_logical == 0) {
        cpuRow("Wątki logiczne", "unknown", fmt(&b2, "źródło: {s}", .{topo_src}));
    } else {
        cpuRow("Wątki logiczne", fmt(&b1, "{d}", .{info.threads_logical}), fmt(&b2, "topologia: {s}", .{topo_src}));
    }
    if (info.threads_per_core == 0) {
        // Hybryda: jedna liczba wątków na rdzeń nie istnieje.
        cpuRow("Wątki / rdzeń", fmt(&b1, "zmienna (maks. {d})", .{info.smt_max}), "topologia hybrydowa");
    } else {
        cpuRow("Wątki / rdzeń", fmt(&b1, "{d}", .{info.threads_per_core}), fmt(&b2, "topologia: {s}", .{topo_src}));
    }
    cpuRow("SMT", if (info.smt) "tak" else "nie", "CPUID");
    if (info.packages == 0) {
        cpuRow("Gniazda (pakiety)", "unknown", "brak pomiaru x2APIC");
    } else {
        cpuRow("Gniazda (pakiety)", fmt(&b1, "{d}", .{info.packages}), "z identyfikatorów APIC (pomiar, nie baza)");
    }
    const classes = info.coreClassSlice();
    if (info.hybrid or classes.len > 1) {
        for (classes) |c| {
            if (c.name.len > 0) {
                cpuRow("Klasa rdzeni", fmt(&b1, "{d} x {s}", .{ c.cores, c.name }), "CPUID 0x1A/0x1F");
            } else {
                cpuRow("Klasa rdzeni", fmt(&b1, "{d} x klasa 0x{X:0>2}", .{ c.cores, c.value }), "numeracja nieznana");
            }
        }
    } else if (info.core_type != .unknown) {
        cpuRow("Typ rdzenia", info.core_type.toSlice(), "CPUID");
    }

    // --- cache ---------------------------------------------------------------
    cpu_group = .cache;
    if (info.cacheSlice().len == 0) {
        cpuRow("Cache", "unknown", "brak liści cache w CPUID");
    }
    for (info.cacheSlice()) |c| {
        const lbl = fmt(&b3, "Cache L{d} {s}", .{ c.level, @tagName(c.kind) });
        const kib = (c.size_bytes + 1023) / 1024;
        const val = if (c.instance_count > 1)
            fmt(&b1, "{d} KiB  × {d}", .{ kib, c.instance_count })
        else
            fmt(&b1, "{d} KiB", .{kib});
        cpuRow(lbl, val, fmt(&b2, "{d}-way, linia {d} B", .{ c.associativity, c.line_size }));
    }

    // --- cechy: lista dzielona na wiersze, żeby nie ginęła za krawędzią -----
    cpu_group = .features;
    addFeatureRows(info.features);

    // --- dopasowanie i pochodzenie ----------------------------------------
    cpu_group = .origin;
    cpuRow("Dopasowanie HWDB", info.match.toSlice(), fmt(&b2, "display={s}, decode={s}", .{
        @tagName(info.display), outcome.toSlice(),
    }));
    cpuRow("Źródło wpisu", info.db_source orelse "—", info.db_source_url orelse
        (if (info.db_source == null) "brak wpisu w HWDB" else ""));
    for (0..raw_info.diagnostics.len) |i| {
        cpuRow("Diagnostyka", raw_info.diagnostics.get(i), "probe");
    }
}

fn addFeatureRows(f: raw.Features) void {
    var line: [160]u8 = undefined;
    var n: usize = 0;
    var first = true;
    var total: usize = 0;
    var lbl_buf: [64]u8 = undefined;
    inline for (@typeInfo(raw.Features).@"struct".fields) |fld| {
        if (@field(f, fld.name)) total += 1;
    }
    const first_lbl = fmt(&lbl_buf, "Cechy ({d})", .{total});
    inline for (@typeInfo(raw.Features).@"struct".fields) |fld| {
        if (@field(f, fld.name)) {
            const name = fld.name;
            if (n > 0 and n + 2 + name.len > 72) {
                cpuRow(if (first) first_lbl else "", line[0..n], if (first) "CPUID" else "");
                first = false;
                n = 0;
            }
            if (n > 0) {
                line[n] = ',';
                line[n + 1] = ' ';
                n += 2;
            }
            @memcpy(line[n..][0..name.len], name);
            n += name.len;
        }
    }
    if (n > 0 or first) {
        cpuRow(if (first) first_lbl else "", if (n > 0) line[0..n] else "—", if (first) (if (n > 0) "CPUID" else "brak flag w CPUID") else "");
    }
}

// ---------------------------------------------------------------------------
// Zakładka Sensors
// ---------------------------------------------------------------------------

/// Ta sama kolejność co `sensorsNative`: najpierw sterownik, potem `NoMsrBackend`.
fn initSensors() void {
    if (win_msr.Backend.open(S.dev.transport())) |opened| {
        S.real = opened;
        S.real_open = true;
        S.api = S.real.api();
        initEngine() catch {
            S.engine_error = "silnik telemetrii: brak pamięci przy inicjalizacji";
            return;
        };
        // Rozruch jak w CLI: pierwsza próbka nie daje częstotliwości.
        S.samples = S.eng.poll(S.api.monotonicNanos());
    } else |e| {
        S.open_error = e;
        S.api = present.NoMsrBackend.create();
    }
}

fn initEngine() !void {
    const metric = catalog.find("cpu.core.effective_frequency").?;
    S.freq = try engine.FreqState.init(alloc, present.nominal_hz_assumed, 1, .b64);
    errdefer S.freq.deinit(alloc);
    S.pollers[0] = .{
        .descriptor = metric.descriptor,
        .instance = 0,
        .read = engine.pollEffectiveFrequency,
        .ctx = @ptrCast(&S.freq),
    };
    S.eng = try engine.Engine.init(alloc, S.api, &S.pollers, 16);
    S.eng_ready = true;
}

fn deinitSensors() void {
    if (S.eng_ready) {
        S.eng.deinit();
        S.freq.deinit(alloc);
        S.eng_ready = false;
    }
    if (S.real_open) {
        S.real.close();
        S.real_open = false;
    }
}

fn updateSensorsHeader() void {
    var b: [768]u8 = undefined;
    var cb: [256]u8 = undefined;
    setText(app.ttl_sens, if (S.open_error != null) "Czujniki — sterownik niedostępny" else "Czujniki — odczyt ze sterownika");
    if (S.open_error) |e| {
        setText(app.hdr_sens, fmt(&b, "Sterownik: {s}\r\nŹródło: {s}\r\n" ++
            "Zdolności backendu: brak — żadna metryka sprzętowa nie może zostać odczytana. " ++
            "Odświeżanie wyłączone (nie ma czego odczytywać).", .{
            win_msr.openErrorDetail(e), S.api.sourceName(),
        }));
        return;
    }
    const caps = S.api.capabilities();
    const cycles: u64 = if (S.eng_ready) S.eng.cycles else 0;
    setText(app.hdr_sens, fmt(&b, "Źródło: {s}\r\nZdolności backendu: {s}\r\n" ++
        "Odświeżanie co {d} s, cykl {d}. {s}Effective Clock skalowany założonym nominałem {d} MHz (nie z pomiaru).", .{
        S.api.sourceName(),
        present.capsSummary(caps, &cb),
        refresh_ms / 1000,
        cycles,
        if (S.engine_error) |m| m else "",
        present.nominal_hz_assumed / 1_000_000,
    }));
}

/// Wypełnia (`insert`) albo odświeża wiersze metryk z katalogu. Logika wyboru
/// statusu i powodu jest ta sama co w `printSensorsText`.
fn refreshSensorRows(insert: bool) void {
    const lv = app.lv_sens orelse return;
    const caps = S.api.capabilities();
    for (catalog.metrics_available, 0..) |m, i| {
        var vb: [64]u8 = undefined;
        var rb: [512]u8 = undefined;
        var value: []const u8 = "—";
        var status: []const u8 = "";
        var tone: Tone = .warn;
        var shown = false;
        if (S.samples) |list| {
            if (present.findSample(list, m.descriptor.id)) |s| {
                if (s.get()) |v| {
                    const scaled = @as(f64, @floatFromInt(v)) * m.descriptor.unit.scale();
                    value = fmt(&vb, "{d:.2}", .{scaled});
                    status = if (s.status == .synthetic) "synthetic — to NIE jest pomiar" else "ok";
                    if (s.status != .synthetic) tone = .good;
                } else {
                    status = fmt(&rb, "{s} — {s}", .{ @tagName(s.status), present.sampleReason(s) });
                }
                shown = true;
            }
        }
        if (!shown) {
            const why = present.reasonFor(m, caps);
            status = if (S.open_error != null and m.descriptor.source != .platform)
                fmt(&rb, "unavailable — {s} ({s})", .{ why, win_msr.openErrorDetail(S.open_error.?) })
            else
                fmt(&rb, "unavailable — {s}", .{why});
        }
        if (i < sens_tone.len) {
            sens_tone[i] = tone;
            sens_has_value[i] = !std.mem.eql(u8, value, "—");
        }
        const row: i32 = @intCast(i);
        if (insert) {
            const label = if (m.descriptor.label.len > 0) m.descriptor.label else m.descriptor.id;
            lvAddRow(lv, row, &.{ label, value, present.unitLabel(m.descriptor.unit), status }, null);
        } else {
            lvSetText(lv, row, 1, value);
            lvSetText(lv, row, 3, status);
        }
    }
}

fn tickSensors() void {
    if (!S.eng_ready) return;
    S.samples = S.eng.poll(S.api.monotonicNanos());
    refreshSensorRows(false);
    updateSensorsHeader();
}

// ---------------------------------------------------------------------------
// Okno
// ---------------------------------------------------------------------------

fn showTab(idx: isize) void {
    const cpu = idx == 0;
    if (app.ttl_cpu) |h| _ = w.ShowWindow(h, if (cpu) w.SW_SHOW else w.SW_HIDE);
    if (app.ttl_sens) |h| _ = w.ShowWindow(h, if (cpu) w.SW_HIDE else w.SW_SHOW);
    if (app.hdr_cpu) |h| _ = w.ShowWindow(h, if (cpu) w.SW_SHOW else w.SW_HIDE);
    if (app.lv_cpu) |h| _ = w.ShowWindow(h, if (cpu) w.SW_SHOW else w.SW_HIDE);
    if (app.hdr_sens) |h| _ = w.ShowWindow(h, if (cpu) w.SW_HIDE else w.SW_SHOW);
    if (app.lv_sens) |h| _ = w.ShowWindow(h, if (cpu) w.SW_HIDE else w.SW_SHOW);
}

fn layout() void {
    const hwnd = app.hwnd orelse return;
    const tab = app.tab orelse return;
    var rc: w.RECT = undefined;
    _ = w.GetClientRect(hwnd, &rc);
    const m = px(8);
    _ = w.MoveWindow(tab, m, m, rc.right - 2 * m, rc.bottom - 2 * m, 1);

    // Obszar treści zakładki we współrzędnych okna głównego: kontrolki są
    // rodzeństwem tab control, nie jego dziećmi.
    var r: w.RECT = .{ .left = m, .top = m, .right = rc.right - m, .bottom = rc.bottom - m };
    _ = w.SendMessageW(tab, w.TCM_ADJUSTRECT, 0, lp(&r));
    const pad = px(10);
    const ttl_h = px(30);
    const hdr_h = px(52);
    const x = r.left + pad;
    const width = @max(0, r.right - r.left - 2 * pad);
    const hdr_top = r.top + pad + ttl_h;
    const lv_top = hdr_top + hdr_h + px(6);
    const lv_h = @max(0, r.bottom - pad - lv_top);
    for ([_]?w.HWND{ app.ttl_cpu, app.ttl_sens }) |h| {
        if (h) |hh| _ = w.MoveWindow(hh, x, r.top + pad, width, ttl_h, 1);
    }
    for ([_]?w.HWND{ app.hdr_cpu, app.hdr_sens }) |h| {
        if (h) |hh| _ = w.MoveWindow(hh, x, hdr_top, width, hdr_h, 1);
    }
    for ([_]?w.HWND{ app.lv_cpu, app.lv_sens }) |h| {
        if (h) |hh| _ = w.MoveWindow(hh, x, lv_top, width, lv_h, 1);
    }
    applyColumnWidths();
}

fn wndProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        w.WM_SIZE => {
            layout();
            return 0;
        },
        w.WM_NOTIFY => {
            const hdr: *const w.NMHDR = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (app.tab != null and hdr.hwndFrom == app.tab and hdr.code == w.TCN_SELCHANGE) {
                showTab(w.SendMessageW(app.tab.?, w.TCM_GETCURSEL, 0, 0));
            }
            if (hdr.code == w.NM_CUSTOMDRAW and hdr.hwndFrom != null and
                (hdr.hwndFrom == app.lv_cpu or hdr.hwndFrom == app.lv_sens))
            {
                const cd: *w.NMLVCUSTOMDRAW = @ptrFromInt(@as(usize, @bitCast(lparam)));
                return onCustomDraw(hdr.hwndFrom == app.lv_cpu, cd);
            }
            return 0;
        },
        w.WM_TIMER => {
            if (wp == timer_id) tickSensors();
            return 0;
        },
        w.WM_CTLCOLORSTATIC => {
            // Nagłówki leżą na białym panelu zakładki; domyślne szare tło
            // STATIC wyglądałoby jak dziura w panelu.
            _ = w.SetBkColor(@ptrFromInt(wp), w.GetSysColor(w.COLOR_WINDOW));
            // Tytuł zwykłym kolorem tekstu, opis pod nim przygaszony.
            const ctl: ?w.HWND = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const muted = ctl != null and (ctl == app.hdr_cpu or ctl == app.hdr_sens);
            _ = w.SetTextColor(@ptrFromInt(wp), toneColor(if (muted) .muted else .normal));
            return @bitCast(@intFromPtr(w.GetSysColorBrush(w.COLOR_WINDOW)));
        },
        w.WM_GETMINMAXINFO => {
            const mmi: *w.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            mmi.ptMinTrackSize = .{ .x = px(480), .y = px(380) };
            return 0;
        },
        w.WM_DPICHANGED => {
            app.dpi = @intCast((wp >> 16) & 0xFFFF);
            const old = app.font;
            const old_title = app.font_title;
            app.font = makeFont(app.dpi);
            app.font_title = makeTitleFont(app.dpi);
            applyFont();
            applyRowHeight();
            if (old) |f| _ = w.DeleteObject(f);
            if (old_title) |f| _ = w.DeleteObject(f);
            const r: *const w.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = w.SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, w.SWP_NOZORDER | w.SWP_NOACTIVATE);
            layout();
            return 0;
        },
        w.WM_DESTROY => {
            _ = w.KillTimer(hwnd, timer_id);
            deinitSensors();
            w.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lparam);
}

fn createChild(class: [*:0]const u16, text: ?[*:0]const u16, ex: u32, style: u32, parent: w.HWND, inst: w.HINSTANCE) ?w.HWND {
    return w.CreateWindowExW(ex, class, text, style, 0, 0, 10, 10, parent, null, inst, null);
}

fn createListView(parent: w.HWND, inst: w.HINSTANCE) ?w.HWND {
    const lv = createChild(L("SysListView32"), null, 0, w.WS_CHILD | w.WS_TABSTOP |
        w.LVS_REPORT | w.LVS_SINGLESEL | w.LVS_SHOWSELALWAYS | w.LVS_NOSORTHEADER | w.LVS_SHAREIMAGELISTS, parent, inst) orelse return null;
    const ex = w.LVS_EX_FULLROWSELECT | w.LVS_EX_DOUBLEBUFFER | w.LVS_EX_LABELTIP;
    _ = w.SendMessageW(lv, w.LVM_SETEXTENDEDLISTVIEWSTYLE, ex, ex);
    // Motyw Eksploratora: płaskie zaznaczenie z poświatą zamiast niebieskiego paska.
    _ = w.SetWindowTheme(lv, L("Explorer"), null);
    return lv;
}

fn wantsSensorsTab(cmd: [*:0]const u16) bool {
    return std.mem.indexOf(u16, std.mem.span(cmd), L("--tab=sensors")) != null;
}

pub fn wWinMain(inst: w.HINSTANCE, _: ?w.HINSTANCE, cmd: [*:0]u16, show: c_int) c_int {
    const icc: w.INITCOMMONCONTROLSEX = .{ .dwICC = w.ICC_LISTVIEW_CLASSES | w.ICC_TAB_CLASSES };
    _ = w.InitCommonControlsEx(&icc);

    const wc: w.WNDCLASSEXW = .{
        .lpfnWndProc = wndProc,
        .hInstance = inst,
        .hCursor = w.LoadCursorW(null, @ptrFromInt(w.IDC_ARROW)),
        .hbrBackground = w.GetSysColorBrush(w.COLOR_BTNFACE),
        .lpszClassName = class_name,
    };
    if (w.RegisterClassExW(&wc) == 0) return 1;

    const hwnd = w.CreateWindowExW(0, class_name, window_title, w.WS_OVERLAPPEDWINDOW | w.WS_CLIPCHILDREN, w.CW_USEDEFAULT, w.CW_USEDEFAULT, 640, 600, null, null, inst, null) orelse return 1;
    app.hwnd = hwnd;
    app.dpi = w.GetDpiForWindow(hwnd);
    if (app.dpi == 0) app.dpi = 96;
    app.font = makeFont(app.dpi);
    app.font_title = makeTitleFont(app.dpi);

    app.tab = createChild(L("SysTabControl32"), null, 0, w.WS_CHILD | w.WS_VISIBLE | w.WS_CLIPSIBLINGS | w.WS_TABSTOP, hwnd, inst);
    const ttl_style = w.WS_CHILD | w.SS_LEFT | w.SS_NOPREFIX | w.SS_ENDELLIPSIS;
    app.ttl_cpu = createChild(L("STATIC"), null, 0, ttl_style, hwnd, inst);
    app.hdr_cpu = createChild(L("STATIC"), null, 0, w.WS_CHILD | w.SS_LEFT | w.SS_NOPREFIX, hwnd, inst);
    app.lv_cpu = createListView(hwnd, inst);
    app.ttl_sens = createChild(L("STATIC"), null, 0, ttl_style, hwnd, inst);
    app.hdr_sens = createChild(L("STATIC"), null, 0, w.WS_CHILD | w.SS_LEFT | w.SS_NOPREFIX, hwnd, inst);
    app.lv_sens = createListView(hwnd, inst);
    if (app.tab == null or app.lv_cpu == null or app.lv_sens == null) return 1;

    // Tab control na dno kolejności Z: inaczej przy odświeżaniu zamalowałby
    // listy, które są jego rodzeństwem.
    _ = w.SetWindowPos(app.tab.?, @ptrFromInt(1), 0, 0, 0, 0, w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOACTIVATE);
    applyFont();
    applyRowHeight();
    insertCpuGroups(app.lv_cpu.?);

    var t1: w.TCITEMW = .{ .mask = w.TCIF_TEXT, .pszText = @constCast(L("CPU")) };
    _ = w.SendMessageW(app.tab.?, w.TCM_INSERTITEMW, 0, lp(&t1));
    var t2: w.TCITEMW = .{ .mask = w.TCIF_TEXT, .pszText = @constCast(L("Sensors")) };
    _ = w.SendMessageW(app.tab.?, w.TCM_INSERTITEMW, 1, lp(&t2));

    lvAddColumn(app.lv_cpu.?, 0, L("Pole"), cpu_cols[0]);
    lvAddColumn(app.lv_cpu.?, 1, L("Wartość"), cpu_cols[1]);
    lvAddColumn(app.lv_cpu.?, 2, L("Źródło / uwagi"), 200);
    lvAddColumn(app.lv_sens.?, 0, L("Metryka"), sens_cols[0]);
    lvAddColumn(app.lv_sens.?, 1, L("Wartość"), sens_cols[1]);
    lvAddColumn(app.lv_sens.?, 2, L("Jednostka"), sens_cols[2]);
    lvAddColumn(app.lv_sens.?, 3, L("Status / powód"), 300);

    loadCpu();
    initSensors();
    updateSensorsHeader();
    refreshSensorRows(true);
    // Timer tylko przy prawdziwym backendzie: bez sterownika nie ma czego
    // odczytywać, a puste cykle co sekundę byłyby spamem bez informacji.
    if (S.eng_ready) _ = w.SetTimer(hwnd, timer_id, refresh_ms, null);

    const start_tab: isize = if (wantsSensorsTab(cmd)) 1 else 0;
    _ = w.SendMessageW(app.tab.?, w.TCM_SETCURSEL, @intCast(start_tab), 0);
    showTab(start_tab);

    _ = w.SetWindowPos(hwnd, null, 0, 0, px(760), px(680), w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
    layout();
    _ = w.ShowWindow(hwnd, show);
    _ = w.UpdateWindow(hwnd);

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
    if (app.font) |f| _ = w.DeleteObject(f);
    if (app.font_title) |f| _ = w.DeleteObject(f);
    if (app.row_imgs) |il| _ = w.ImageList_Destroy(il);
    return 0;
}
