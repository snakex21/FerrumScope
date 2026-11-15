//! FerrumScope — GUI (czysty Win32, bez zależności zewnętrznych).
//!
//! Dwa widoki tych samych danych (te same `report.Page` z `app.zig`):
//!
//!  * **Widok uporządkowany** (domyślny) — zakładki z ramkami grup i zwartymi
//!    polami „etykieta → wartość” (układ znany z narzędzi typu CPU-Z/GPU-Z;
//!    układ opisany danymi w `gui/forms.zig`). Pola są tylko do odczytu, ale
//!    można je zaznaczać i kopiować. Źródło i pewność wartości pokazuje
//!    podpowiedź po najechaniu, a przełącznik „Pokaż źródła” dodaje mały
//!    znacznik pewności obok każdego pola.
//!  * **Pełna lista** — wszystkie pola strony jedno pod drugim, w grupach,
//!    z kolumnami Pewność/stan i Źródło (wygodne do szukania i kopiowania).
//!
//! Przełączanie: pole wyboru „Pełna lista” albo Ctrl+L; wybór jest zapisywany
//! w HKCU\Software\FerrumScope (`ListView`). F5 = odśwież dane statyczne.
//!
//! Numery seryjne są w oknie zamaskowane, dopóki użytkownik nie zaznaczy
//! „Pokaż numery seryjne” — to samo ustawienie obowiązuje przy eksporcie.
//!
//! Flagi: `--tab=<id>` (cpu, caches, board, memory, graphics, storage,
//! sensors, bench, about) i `--list` / `--structured` (wymusza widok).

const std = @import("std");
const w = @import("gui/win32.zig");
const forms = @import("gui/forms.zig");
const present = @import("present.zig");
const app_mod = @import("app.zig");
const ferrum = @import("root.zig");
const pci_embedded = @import("db/pci_embedded.zig");

const report = ferrum.sys.report;

const L = std.unicode.utf8ToUtf16LeStringLiteral;

const window_title = L("FerrumScope " ++ present.version);
const class_name = L("FerrumScopeGuiWindow");
const reg_key = L("Software\\FerrumScope");
const timer_id: usize = 1;
const refresh_ms: u32 = 1000;

const ID_REFRESH: u16 = 100;
const ID_EXPORT_TXT: u16 = 101;
const ID_EXPORT_HTML: u16 = 102;
const ID_EXPORT_JSON: u16 = 103;
const ID_SERIALS: u16 = 104;
const ID_SOURCES: u16 = 105;
const ID_LISTVIEW: u16 = 106;
const ID_SELECTOR0: u16 = 300; // + indeks zakładki
const ID_CELLBTN0: u16 = 400; // + indeks komórki

const n_tabs = forms.tabs.len;
const max_cells = 256;
const max_groups = 64;
const max_extra = 32;

// ---------------------------------------------------------------------------
// Stan okna
// ---------------------------------------------------------------------------

const CellCtl = struct {
    tab: u8,
    cell: *const forms.Cell,
    lbl: ?w.HWND = null,
    edit: ?w.HWND = null,
    mark: ?w.HWND = null,
    btn: ?w.HWND = null,
    tone: Tone = .normal,
    mark_tone: Tone = .normal,
};

const GroupCtl = struct {
    tab: u8,
    hwnd: ?w.HWND = null,
};

/// Kontrolki zakładek specjalnych (Bench, O programie).
const ExtraCtl = struct {
    tab: u8,
    hwnd: ?w.HWND = null,
};

const App = struct {
    hwnd: ?w.HWND = null,
    tab: ?w.HWND = null,
    tip: ?w.HWND = null,
    /// Panel z tłem okna, nad treścią zakładki — rodzic wszystkich kontrolek
    /// stron. Bez niego wnętrza ramek grup (przezroczystych) nie byłyby
    /// zamalowywane po przełączeniu zakładki.
    panel: ?w.HWND = null,
    lv: ?w.HWND = null,
    ttl: ?w.HWND = null,
    btn_refresh: ?w.HWND = null,
    chk_serials: ?w.HWND = null,
    chk_sources: ?w.HWND = null,
    chk_list: ?w.HWND = null,
    font: ?w.HFONT = null,
    font_title: ?w.HFONT = null,
    row_imgs: ?w.HIMAGELIST = null,
    value_brush: ?w.HBRUSH = null,
    dpi: u32 = 96,
    current: usize = 0,
    show_serials: bool = false,
    show_sources: bool = false,
    list_mode: bool = false,
    cells: [max_cells]CellCtl = undefined,
    n_cells: usize = 0,
    groups: [max_groups]GroupCtl = undefined,
    n_groups: usize = 0,
    extras: [max_extra]ExtraCtl = undefined,
    n_extras: usize = 0,
    sel_label: [n_tabs]?w.HWND = @splat(null),
    sel_combo: [n_tabs]?w.HWND = @splat(null),
    sel_index: [n_tabs]usize = @splat(0),
    sel_count: [n_tabs]usize = @splat(0),
    shown_rows: usize = 0,
    shown_sections: usize = 0,
    shown_key: usize = std.math.maxInt(usize),
    state: ?*app_mod.State = null,
    pages: []report.Page = &.{},
};
var app: App = .{};

const gpa = std.heap.page_allocator;

// ---------------------------------------------------------------------------
// Pomocnicze
// ---------------------------------------------------------------------------

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

fn lp(p: anytype) w.LPARAM {
    return @bitCast(@intFromPtr(p));
}

fn px(v: i32) i32 {
    return @divTrunc(v * @as(i32, @intCast(app.dpi)), 96);
}

fn setText(h: ?w.HWND, s: []const u8) void {
    var wb: [4096]u16 = undefined;
    if (h) |hh| _ = w.SetWindowTextW(hh, widen(&wb, s));
}

fn show(h: ?w.HWND, visible: bool) void {
    if (h) |hh| _ = w.ShowWindow(hh, if (visible) w.SW_SHOW else w.SW_HIDE);
}

fn move(h: ?w.HWND, x: i32, y: i32, cx: i32, cy: i32) void {
    if (h) |hh| _ = w.MoveWindow(hh, x, y, cx, cy, 1);
}

fn checked(h: ?w.HWND) bool {
    const hh = h orelse return false;
    return w.SendMessageW(hh, w.BM_GETCHECK, 0, 0) == w.BST_CHECKED;
}

fn setCheck(h: ?w.HWND, on: bool) void {
    const BM_SETCHECK: u32 = 0x00F1;
    if (h) |hh| _ = w.SendMessageW(hh, BM_SETCHECK, @intFromBool(on), 0);
}

fn makeFont(dpi: u32) ?w.HFONT {
    var ncm: w.NONCLIENTMETRICSW = .{};
    if (w.SystemParametersInfoForDpi(w.SPI_GETNONCLIENTMETRICS, @sizeOf(w.NONCLIENTMETRICSW), &ncm, 0, dpi) != 0) {
        if (w.CreateFontIndirectW(&ncm.lfMessageFont)) |f| return f;
    }
    var lf: w.LOGFONTW = .{ .lfHeight = -@as(i32, @intCast((9 * dpi + 36) / 72)), .lfWeight = w.FW_NORMAL, .lfQuality = w.CLEARTYPE_QUALITY };
    const face = L("Segoe UI");
    @memcpy(lf.lfFaceName[0..face.len], face);
    return w.CreateFontIndirectW(&lf);
}

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
    lf.lfHeight = @divTrunc(lf.lfHeight * 4, 3);
    lf.lfWeight = w.FW_SEMIBOLD;
    lf.lfQuality = w.CLEARTYPE_QUALITY;
    return w.CreateFontIndirectW(&lf);
}

fn setFont(h: ?w.HWND, f: ?w.HFONT) void {
    const ff = f orelse return;
    if (h) |hh| _ = w.SendMessageW(hh, w.WM_SETFONT, @intFromPtr(ff), 1);
}

fn applyFonts() void {
    const f = app.font;
    for ([_]?w.HWND{ app.tab, app.lv, app.btn_refresh, app.chk_serials, app.chk_sources, app.chk_list }) |h| setFont(h, f);
    for (app.cells[0..app.n_cells]) |c| {
        setFont(c.lbl, f);
        setFont(c.edit, f);
        setFont(c.mark, f);
        setFont(c.btn, f);
    }
    for (app.groups[0..app.n_groups]) |g| setFont(g.hwnd, f);
    for (app.extras[0..app.n_extras]) |e| setFont(e.hwnd, f);
    for (app.sel_label, app.sel_combo) |a, b| {
        setFont(a, f);
        setFont(b, f);
    }
    setFont(app.ttl, app.font_title);
}

fn applyRowHeight() void {
    const old = app.row_imgs;
    app.row_imgs = w.ImageList_Create(1, px(22), w.ILC_COLOR32, 1, 0);
    const il: w.LPARAM = if (app.row_imgs) |p| lp(p) else 0;
    if (app.lv) |hh| _ = w.SendMessageW(hh, w.LVM_SETIMAGELIST, w.LVSIL_SMALL, il);
    if (old) |o| _ = w.ImageList_Destroy(o);
}

// ---------------------------------------------------------------------------
// Kolory
// ---------------------------------------------------------------------------

const Tone = enum { normal, muted, good, warn };

fn toneColor(t: Tone) u32 {
    return switch (t) {
        .normal => w.GetSysColor(w.COLOR_WINDOWTEXT),
        .muted => 0x0070_7070,
        .good => 0x0010_7C10,
        .warn => 0x0000_5AB4,
    };
}

fn valueTone(f: report.Field) Tone {
    return switch (f.state) {
        .ok, .estimate => .normal,
        else => .muted,
    };
}

fn markTone(f: report.Field) Tone {
    return switch (f.state) {
        .ok => switch (f.confidence) {
            .high => .good,
            .medium => .normal,
            .low, .unknown => .warn,
        },
        .estimate => .normal,
        else => .warn,
    };
}

/// Krótki znacznik pewności/stanu obok pola (gdy „Pokaż źródła”).
fn markText(f: report.Field) []const u8 {
    return switch (f.state) {
        .ok => switch (f.confidence) {
            .high => "W",
            .medium => "Ś",
            .low => "N",
            .unknown => "?",
        },
        .estimate => "~",
        .placeholder => "Z",
        .requires_admin => "A",
        .requires_driver => "S",
        .unavailable => "–",
    };
}

// ---------------------------------------------------------------------------
// Dane
// ---------------------------------------------------------------------------

fn rebuild() void {
    const st = app.state orelse return;
    app.pages = st.buildPages();
}

fn exportOpts() report.ExportOptions {
    return .{ .include_serials = app.show_serials };
}

fn pageOfTab(t: usize) ?*const report.Page {
    const spec = forms.tabs[t];
    if (spec.page.len == 0) return null;
    return forms.findPage(app.pages, spec.page);
}

fn fieldOfCell(c: *const CellCtl) ?*const report.Field {
    const p = pageOfTab(c.tab) orelse return null;
    return forms.resolve(p, c.cell.*, app.sel_index[c.tab]);
}

/// Treść podpowiedzi: źródło, pewność, surowa wartość, uwaga.
var tip_buf: [2048]u16 = undefined;
fn tipText(f: report.Field) [*:0]const u16 {
    var b: [2048]u8 = undefined;
    const raw = report.shownRaw(f, exportOpts());
    const s = std.fmt.bufPrint(&b, "Źródło: {s}\nPewność: {s} · stan: {s}{s}{s}{s}{s}", .{
        if (f.source.len > 0) f.source else "—",
        f.confidence.toSlice(),
        f.state.label(),
        if (raw.len > 0) "\nSurowo: " else "",
        raw,
        if (f.note.len > 0) "\nUwaga: " else "",
        f.note,
    }) catch "Źródło: (za długie)";
    return widen(&tip_buf, s);
}

// ---------------------------------------------------------------------------
// Widok uporządkowany: tworzenie kontrolek
// ---------------------------------------------------------------------------

/// Rodzic tworzonych kontrolek (panel stron albo okno główne).
var create_parent: ?w.HWND = null;

fn createChild(class: [*:0]const u16, text: ?[*:0]const u16, ex: u32, style: u32, id: u16) ?w.HWND {
    const menu: ?w.HMENU = if (id != 0) @ptrFromInt(id) else null;
    return w.CreateWindowExW(ex, class, text, style, 0, 0, 10, 10, create_parent orelse app.hwnd, menu, null, null);
}

fn addTip(h: ?w.HWND) void {
    const tip = app.tip orelse return;
    const hh = h orelse return;
    var ti: w.TTTOOLINFOW = .{
        .uFlags = w.TTF_IDISHWND | w.TTF_SUBCLASS,
        .hwnd = app.panel orelse app.hwnd,
        .uId = @intFromPtr(hh),
        .lpszText = w.LPSTR_TEXTCALLBACKW,
    };
    _ = w.SendMessageW(tip, w.TTM_ADDTOOLW, 0, lp(&ti));
}

fn createForms() void {
    const child = w.WS_CHILD;
    for (&forms.tabs, 0..) |*t, ti| {
        const tab: u8 = @intCast(ti);
        if (t.selector) |s| {
            var wb: [64]u16 = undefined;
            app.sel_label[ti] = createChild(L("STATIC"), widen(&wb, s.label), 0, child | w.SS_LEFT | w.SS_NOPREFIX, 0);
            app.sel_combo[ti] = createChild(L("COMBOBOX"), null, 0, child | w.WS_TABSTOP | w.WS_VSCROLL | w.CBS_DROPDOWNLIST, ID_SELECTOR0 + @as(u16, tab));
        }
        for (t.bands) |band| for (band) |*g| {
            var wb: [128]u16 = undefined;
            if (app.n_groups < max_groups) {
                app.groups[app.n_groups] = .{ .tab = tab, .hwnd = createChild(L("BUTTON"), widen(&wb, g.title), 0, child | w.BS_GROUPBOX, 0) };
                app.n_groups += 1;
            }
            for (g.rows) |row| for (row) |*c| {
                if (app.n_cells >= max_cells) continue;
                var lb: [128]u16 = undefined;
                const idx = app.n_cells;
                var cc: CellCtl = .{ .tab = tab, .cell = c };
                cc.lbl = createChild(L("STATIC"), widen(&lb, c.label), 0, child | w.SS_LEFT | w.SS_NOPREFIX | w.SS_ENDELLIPSIS, 0);
                const multi: u32 = if (c.lines > 1) w.ES_MULTILINE else w.ES_AUTOHSCROLL;
                cc.edit = createChild(L("EDIT"), null, 0, child | w.WS_TABSTOP | w.WS_BORDER | w.ES_READONLY | multi, 0);
                cc.mark = createChild(L("STATIC"), null, 0, child | w.SS_NOPREFIX, 0);
                if (c.button.len > 0) {
                    var bb: [64]u16 = undefined;
                    cc.btn = createChild(L("BUTTON"), widen(&bb, c.button), 0, child | w.WS_TABSTOP | w.BS_PUSHBUTTON, ID_CELLBTN0 + @as(u16, @intCast(idx)));
                }
                app.cells[idx] = cc;
                app.n_cells += 1;
                addTip(cc.edit);
                addTip(cc.lbl);
            };
        };
    }
    createSpecialTabs();
}

fn extra(tab: usize, h: ?w.HWND) void {
    if (app.n_extras >= max_extra) return;
    app.extras[app.n_extras] = .{ .tab = @intCast(tab), .hwnd = h };
    app.n_extras += 1;
}

const ix_bench = forms.tabIndex("bench").?;
const ix_about = forms.tabIndex("about").?;
const ix_sensors = forms.tabIndex("sensors").?;

fn createSpecialTabs() void {
    @setEvalBranchQuota(50000);
    const st = w.WS_CHILD | w.SS_LEFT | w.SS_NOPREFIX;
    // --- Bench (zapowiedź) ---------------------------------------------------
    extra(ix_bench, createChild(L("BUTTON"), L("Benchmark i test obciążeniowy"), 0, w.WS_CHILD | w.BS_GROUPBOX, 0));
    extra(ix_bench, createChild(L("STATIC"), L("Planowane: test wydajności jednego wątku i wszystkich wątków oraz test " ++
        "stabilności pod obciążeniem.\n\nW tej wersji nic nie jest mierzone ani uruchamiane — zakładka tylko rezerwuje " ++
        "miejsce. Wyniki będą miały to samo źródło i pewność co reszta programu."), 0, st, 0));
    // --- O programie ----------------------------------------------------------
    extra(ix_about, createChild(L("BUTTON"), L("FerrumScope"), 0, w.WS_CHILD | w.BS_GROUPBOX, 0));
    var info: [1024]u8 = undefined;
    const pci_ver = if (pci_embedded.get()) |db| db.version() else "niedostępna";
    const txt = std.fmt.bufPrint(&info, "Wersja {s} · licencja GPL-3.0-or-later\n" ++
        "Otwarte narzędzie do identyfikacji sprzętu. Każda wartość ma źródło i pewność.\n" ++
        "Nazwy urządzeń PCI: PCI ID Repository {s} (GPL-2.0+ lub BSD-3-Clause).\n" ++
        "Baza CPU: własna HWDB z jawnym pochodzeniem wpisów (bez danych CPU-Z/GPU-Z).", .{ present.version, pci_ver }) catch "";
    const h = createChild(L("STATIC"), null, 0, st, 0);
    setText(h, txt);
    extra(ix_about, h);
    extra(ix_about, createChild(L("BUTTON"), L("Raport"), 0, w.WS_CHILD | w.BS_GROUPBOX, 0));
    extra(ix_about, createChild(L("BUTTON"), L("Eksport TXT…"), 0, w.WS_CHILD | w.WS_TABSTOP | w.BS_PUSHBUTTON, ID_EXPORT_TXT));
    extra(ix_about, createChild(L("BUTTON"), L("Eksport HTML…"), 0, w.WS_CHILD | w.WS_TABSTOP | w.BS_PUSHBUTTON, ID_EXPORT_HTML));
    extra(ix_about, createChild(L("BUTTON"), L("Eksport JSON…"), 0, w.WS_CHILD | w.WS_TABSTOP | w.BS_PUSHBUTTON, ID_EXPORT_JSON));
    extra(ix_about, createChild(L("STATIC"), L("Numery seryjne w raporcie są zamaskowane, chyba że zaznaczono „Pokaż numery seryjne”."), 0, st, 0));
    extra(ix_about, createChild(L("BUTTON"), L("Znaczniki źródeł"), 0, w.WS_CHILD | w.BS_GROUPBOX, 0));
    extra(ix_about, createChild(L("STATIC"), L("Najedź na wartość, aby zobaczyć źródło, pewność i surowe dane.\n" ++
        "„Pokaż źródła” dodaje znacznik: W wysoka · Ś średnia · N niska pewność · ~ oszacowanie · " ++
        "Z zaślepka firmware · A wymaga administratora · S wymaga sterownika · – niedostępne."), 0, st, 0));
}

// ---------------------------------------------------------------------------
// Widok uporządkowany: układ i wypełnianie
// ---------------------------------------------------------------------------

const M = struct {
    const pad: i32 = 8;
    const gap: i32 = 6;
    const head: i32 = 18;
    const row: i32 = 24;
    const edit_h: i32 = 21;
    const line_h: i32 = 16;
    const cell_gap: i32 = 10;
    const mark_w: i32 = 14;
    const btn_w: i32 = 76;
    const sel_h: i32 = 28;
};

fn rowHeight(row: forms.Row) i32 {
    var lines: i32 = 1;
    for (row) |c| lines = @max(lines, c.lines);
    return px(M.row) + px(M.line_h) * (lines - 1);
}

fn groupHeight(g: *const forms.Group) i32 {
    var h: i32 = px(M.head) + px(6);
    for (g.rows) |r| h += rowHeight(r);
    return h;
}

fn layoutForm(t: usize, area: w.RECT) void {
    var y = area.top;
    const x0 = area.left;
    const full_width = area.right - area.left;
    if (forms.tabs[t].selector != null) {
        move(app.sel_label[t], x0 + px(4), y + px(4), px(70), px(20));
        move(app.sel_combo[t], x0 + px(78), y, @max(px(200), full_width - px(78)), px(300));
        y += px(M.sel_h) + px(4);
    }
    // Komórki i ramki są tworzone w tej samej kolejności co tu iterujemy.
    var gi: usize = 0;
    while (gi < app.n_groups and app.groups[gi].tab != t) gi += 1;
    var ci: usize = 0;
    while (ci < app.n_cells and app.cells[ci].tab != t) ci += 1;

    const has_badge = forms.tabs[t].badge != null;
    for (forms.tabs[t].bands, 0..) |band, band_i| {
        // Pierwszy pas zakładki z plakietką zostawia miejsce na logo po prawej.
        const width = if (has_badge and band_i == 0) full_width - px(badge_w) - px(M.gap) else full_width;
        if (has_badge and band_i == 0) {
            for (&badges) |*bv| {
                if (bv.hwnd != null and bv.tab == t) move(bv.hwnd, x0 + full_width - px(badge_w), y + px(6), px(badge_w), px(badge_h));
            }
        }
        var total_w: i32 = 0;
        for (band) |g| total_w += g.weight;
        var band_h: i32 = 0;
        for (band) |*g| band_h = @max(band_h, groupHeight(g));
        var gx = x0;
        for (band, 0..) |*g, k| {
            const gw = if (k == band.len - 1) x0 + width - gx else @divTrunc(width * g.weight, total_w) - @divTrunc(px(M.gap), 2);
            move(app.groups[gi].hwnd, gx, y, gw, band_h);
            gi += 1;
            var ry = y + px(M.head);
            const inner_x = gx + px(M.pad);
            const inner_w = gw - 2 * px(M.pad);
            for (g.rows) |row| {
                const n: i32 = @intCast(row.len);
                const cw = @divTrunc(inner_w - (n - 1) * px(M.cell_gap), n);
                for (row, 0..) |c, k2| {
                    const cc = &app.cells[ci];
                    ci += 1;
                    const cx = inner_x + @as(i32, @intCast(k2)) * (cw + px(M.cell_gap));
                    const lw = px(if (c.label_w > 0) c.label_w else if (k2 == 0) g.label_w else 56);
                    const mw: i32 = if (app.show_sources) px(M.mark_w) else 0;
                    const bw: i32 = if (cc.btn != null) px(M.btn_w) + px(4) else 0;
                    const eh = px(M.edit_h) + px(M.line_h) * (@as(i32, c.lines) - 1);
                    move(cc.lbl, cx, ry + px(3), lw - px(4), px(18));
                    move(cc.edit, cx + lw, ry, @max(px(20), cw - lw - mw - bw), eh);
                    move(cc.mark, cx + cw - mw - bw + px(3), ry + px(3), mw, px(18));
                    show(cc.mark, app.show_sources and t == app.current and !app.list_mode);
                    if (cc.btn) |b| move(b, cx + cw - bw + px(4), ry - px(1), px(M.btn_w), px(M.edit_h) + px(2));
                }
                ry += rowHeight(row);
            }
            gx += gw + px(M.gap);
        }
        y += band_h + px(M.gap);
    }
}

fn layoutSpecial(t: usize, area: w.RECT) void {
    var y = area.top;
    const x = area.left;
    const width = area.right - area.left;
    var bx = x + px(M.pad);
    var in_box_y: i32 = 0;
    for (app.extras[0..app.n_extras]) |e| {
        if (e.tab != t) continue;
        const hh = e.hwnd orelse continue;
        var cls: [16]u16 = undefined;
        _ = &cls;
        // Kolejność kontrolek jest stała (createSpecialTabs): ramka, treść, ...
        const is_group = isGroupBox(hh);
        const is_button = !is_group and isButton(hh);
        if (is_group) {
            if (in_box_y != 0) y = in_box_y + px(M.gap);
            const h: i32 = if (t == ix_bench) px(150) else px(124);
            move(hh, x, y, width, h);
            in_box_y = y + h;
            y += px(M.head) + px(2);
            bx = x + px(M.pad);
        } else if (is_button) {
            move(hh, bx, y, px(120), px(26));
            bx += px(126);
        } else {
            if (bx != x + px(M.pad)) y += px(32);
            move(hh, x + px(M.pad), y, width - 2 * px(M.pad), px(80));
            y += px(80);
            bx = x + px(M.pad);
        }
    }
}

extern "user32" fn GetWindowLongW(w.HWND, i32) callconv(.winapi) i32;
extern "user32" fn GetClassNameW(w.HWND, [*]u16, i32) callconv(.winapi) i32;

fn isButton(h: w.HWND) bool {
    var b: [32]u16 = undefined;
    const n = GetClassNameW(h, &b, b.len);
    return n == 6 and std.mem.eql(u16, b[0..6], L("Button"));
}

fn isGroupBox(h: w.HWND) bool {
    if (!isButton(h)) return false;
    const style: u32 = @bitCast(GetWindowLongW(h, -16));
    return (style & 0xF) == w.BS_GROUPBOX;
}

fn fillSelector(t: usize) void {
    const sel = forms.tabs[t].selector orelse return;
    const combo = app.sel_combo[t] orelse return;
    const p = pageOfTab(t) orelse return;
    const n = forms.instanceCount(p, sel.prefix);
    if (n == app.sel_count[t]) return;
    _ = w.SendMessageW(combo, w.CB_RESETCONTENT, 0, 0);
    for (0..n) |i| {
        var wb: [256]u16 = undefined;
        _ = w.SendMessageW(combo, w.CB_ADDSTRING, 0, lp(widen(&wb, forms.instanceName(p, sel.prefix, i) orelse "?")));
    }
    if (app.sel_index[t] >= n) app.sel_index[t] = 0;
    // Pamięć: domyślnie pierwszy OBSADZONY moduł, nie puste gniazdo 0.
    if (app.sel_count[t] == 0 and std.mem.eql(u8, forms.tabs[t].id, "memory")) {
        for (0..n) |i| {
            const f = forms.resolve(p, .{ .label = "", .sect = "@Gniazdo ", .field = "Moduł" }, i);
            if (f == null) {
                app.sel_index[t] = i;
                break;
            }
        }
    }
    app.sel_count[t] = n;
    _ = w.SendMessageW(combo, w.CB_SETCURSEL, app.sel_index[t], 0);
}

fn fillForm(t: usize) void {
    fillSelector(t);
    var vb: [1024]u8 = undefined;
    for (app.cells[0..app.n_cells]) |*c| {
        if (c.tab != t) continue;
        if (fieldOfCell(c)) |f| {
            const v = report.shownValue(f.*, exportOpts(), &vb);
            // Brak wartości pokazujemy razem z powodem — „—” samo nic nie mówi.
            if (std.mem.eql(u8, v, "—") and f.state != .ok) {
                var sb: [160]u8 = undefined;
                setText(c.edit, std.fmt.bufPrint(&sb, "— ({s})", .{f.state.label()}) catch v);
            } else setText(c.edit, v);
            setText(c.mark, markText(f.*));
            c.tone = valueTone(f.*);
            c.mark_tone = markTone(f.*);
        } else {
            setText(c.edit, "—");
            setText(c.mark, "–");
            c.tone = .muted;
            c.mark_tone = .warn;
        }
        if (c.btn) |b| _ = w.EnableWindow(b, @intFromBool(cellLink(c) != null));
    }
}

fn cellLink(c: *const CellCtl) ?*const report.Link {
    const p = pageOfTab(c.tab) orelse return null;
    var scope: []const u8 = "";
    if (forms.tabs[c.tab].selector) |s| scope = forms.instanceName(p, s.prefix, app.sel_index[c.tab]) orelse "";
    return forms.findLink(p, c.cell.button_link, scope);
}

// ---------------------------------------------------------------------------
// Pełna lista (ListView)
// ---------------------------------------------------------------------------

var row_tone: [1024][2]Tone = @splat(.{ .normal, .normal });

fn lvSetText(lv: w.HWND, row: i32, col: i32, s: []const u8) void {
    var wb: [2048]u16 = undefined;
    var item: w.LVITEMW = .{ .iSubItem = col, .pszText = widen(&wb, s) };
    _ = w.SendMessageW(lv, w.LVM_SETITEMTEXTW, @intCast(row), lp(&item));
}

fn lvAddRow(lv: w.HWND, row: i32, cols: []const []const u8, group: i32) void {
    var wb: [2048]u16 = undefined;
    var item: w.LVITEMW = .{ .mask = w.LVIF_TEXT | w.LVIF_GROUPID, .iItem = row, .pszText = widen(&wb, cols[0]), .iGroupId = group };
    _ = w.SendMessageW(lv, w.LVM_INSERTITEMW, 0, lp(&item));
    for (cols[1..], 1..) |c, k| lvSetText(lv, row, @intCast(k), c);
}

fn lvAddColumn(lv: w.HWND, idx: i32, title: [*:0]const u16, width: i32) void {
    var col: w.LVCOLUMNW = .{ .mask = w.LVCF_TEXT | w.LVCF_WIDTH | w.LVCF_SUBITEM, .cx = px(width), .pszText = @constCast(title), .iSubItem = idx };
    _ = w.SendMessageW(lv, w.LVM_INSERTCOLUMNW, @intCast(idx), lp(&col));
}

const col_widths = [_]i32{ 170, 260, 110 };

fn applyColumnWidths() void {
    const lv = app.lv orelse return;
    var rc: w.RECT = undefined;
    _ = w.GetClientRect(lv, &rc);
    const fixed = px(col_widths[0]) + px(col_widths[1]) + px(col_widths[2]) + px(4);
    for (col_widths, 0..) |cw, i| _ = w.SendMessageW(lv, w.LVM_SETCOLUMNWIDTH, i, px(cw));
    _ = w.SendMessageW(lv, w.LVM_SETCOLUMNWIDTH, 3, @max(px(160), rc.right - fixed));
}

fn statusText(f: report.Field, buf: []u8) []const u8 {
    if (f.state == .ok) return std.fmt.bufPrint(buf, "{s}", .{f.confidence.toSlice()}) catch "";
    return std.fmt.bufPrint(buf, "{s}", .{f.state.label()}) catch "";
}

fn sourceText(f: report.Field, buf: []u8) []const u8 {
    const raw = report.shownRaw(f, exportOpts());
    if (raw.len > 0 and f.note.len > 0) return std.fmt.bufPrint(buf, "{s}  [raw: {s}]  — {s}", .{ f.source, raw, f.note }) catch f.source;
    if (raw.len > 0) return std.fmt.bufPrint(buf, "{s}  [raw: {s}]", .{ f.source, raw }) catch f.source;
    if (f.note.len > 0) return std.fmt.bufPrint(buf, "{s}  — {s}", .{ f.source, f.note }) catch f.source;
    return f.source;
}

fn sectionVisible(t: usize, title: []const u8) bool {
    const filter = forms.tabs[t].list_sections;
    return filter.len == 0 or std.mem.startsWith(u8, title, filter);
}

fn listCounts(t: usize, p: *const report.Page) struct { rows: usize, sections: usize } {
    var r: usize = 0;
    var s: usize = 0;
    for (p.sections.items) |sec| {
        if (!sectionVisible(t, sec.title)) continue;
        s += 1;
        r += sec.fields.items.len;
    }
    return .{ .rows = r, .sections = s };
}

fn renderList(t: usize, full: bool) void {
    const lv = app.lv orelse return;
    const p = pageOfTab(t) orelse return;
    const cnt = listCounts(t, p);
    const redo = full or app.shown_key != t or cnt.rows != app.shown_rows or cnt.sections != app.shown_sections;
    if (redo) {
        _ = w.SendMessageW(lv, w.WM_SETREDRAW, 0, 0);
        _ = w.SendMessageW(lv, w.LVM_DELETEALLITEMS, 0, 0);
        _ = w.SendMessageW(lv, w.LVM_REMOVEALLGROUPS, 0, 0);
        _ = w.SendMessageW(lv, w.LVM_ENABLEGROUPVIEW, 1, 0);
        for (p.sections.items, 0..) |s, si| {
            if (!sectionVisible(t, s.title)) continue;
            var wb: [256]u16 = undefined;
            var lg: w.LVGROUP = .{
                .mask = w.LVGF_HEADER | w.LVGF_GROUPID | w.LVGF_STATE,
                .pszHeader = widen(&wb, s.title),
                .iGroupId = @intCast(si + 1),
                .stateMask = w.LVGS_COLLAPSIBLE,
                .state = w.LVGS_COLLAPSIBLE,
            };
            _ = w.SendMessageW(lv, w.LVM_INSERTGROUP, std.math.maxInt(usize), lp(&lg));
        }
    }
    var row: usize = 0;
    for (p.sections.items, 0..) |s, si| {
        if (!sectionVisible(t, s.title)) continue;
        for (s.fields.items) |f| {
            var vb: [1024]u8 = undefined;
            var sb: [64]u8 = undefined;
            var srcb: [2048]u8 = undefined;
            const value = report.shownValue(f, exportOpts(), &vb);
            const r: i32 = @intCast(row);
            if (redo) {
                lvAddRow(lv, r, &.{ f.label, value, statusText(f, &sb), sourceText(f, &srcb) }, @intCast(si + 1));
            } else {
                lvSetText(lv, r, 1, value);
                lvSetText(lv, r, 2, statusText(f, &sb));
                lvSetText(lv, r, 3, sourceText(f, &srcb));
            }
            if (row < row_tone.len) row_tone[row] = .{ valueTone(f), markTone(f) };
            row += 1;
        }
    }
    app.shown_rows = cnt.rows;
    app.shown_sections = cnt.sections;
    app.shown_key = t;
    if (redo) {
        _ = w.SendMessageW(lv, w.WM_SETREDRAW, 1, 0);
        _ = w.InvalidateRect(lv, null, 1);
    }
}

fn onListCustomDraw(cd: *w.NMLVCUSTOMDRAW) w.LRESULT {
    switch (cd.nmcd.dwDrawStage) {
        w.CDDS_PREPAINT => return w.CDRF_NOTIFYITEMDRAW,
        w.CDDS_ITEMPREPAINT => return w.CDRF_NOTIFYSUBITEMDRAW,
        w.CDDS_ITEMPREPAINT | w.CDDS_SUBITEM => {
            const row = cd.nmcd.dwItemSpec;
            const t: Tone = if (row >= row_tone.len) .normal else switch (cd.iSubItem) {
                1 => row_tone[row][0],
                2 => row_tone[row][1],
                3 => .muted,
                else => .normal,
            };
            cd.clrText = toneColor(t);
            return w.CDRF_NEWFONT;
        },
        else => return w.CDRF_DODEFAULT,
    }
}

// ---------------------------------------------------------------------------
// Przełączanie zakładek i widoków
// ---------------------------------------------------------------------------

fn usesList(t: usize) bool {
    const k = forms.tabs[t].kind;
    if (k == .sensors) return true;
    if (k == .bench or k == .about) return false;
    return app.list_mode;
}

fn updateVisibility() void {
    const t = app.current;
    const list = usesList(t);
    show(app.lv, list);
    for (app.cells[0..app.n_cells]) |c| {
        const vis = !list and c.tab == t;
        show(c.lbl, vis);
        show(c.edit, vis);
        show(c.mark, vis and app.show_sources);
        show(c.btn, vis);
    }
    for (app.groups[0..app.n_groups]) |g| show(g.hwnd, !list and g.tab == t);
    for (app.extras[0..app.n_extras]) |e| show(e.hwnd, e.tab == t);
    for (badges) |bv| show(bv.hwnd, !list and bv.tab == t);
    for (0..n_tabs) |i| {
        show(app.sel_label[i], i == t);
        show(app.sel_combo[i], i == t);
    }
}

fn refreshCurrent(full: bool) void {
    const t = app.current;
    if (usesList(t)) {
        // Lista z selektorem (np. dyski) pokazuje i tak całą stronę.
        renderList(t, full);
    } else if (forms.tabs[t].kind == .form) {
        fillForm(t);
        updateBadge(t);
    }
    const p = pageOfTab(t);
    setText(app.ttl, if (p) |pp| (if (pp.headline.len > 0) pp.headline else pp.title) else forms.tabs[t].title);
}

extern "user32" fn RedrawWindow(w.HWND, ?*const w.RECT, ?*anyopaque, u32) callconv(.winapi) w.BOOL;

fn showTab(t: usize) void {
    app.current = t;
    rebuild();
    updateVisibility();
    layout();
    refreshCurrent(true);
    // Ukryte kontrolki poprzedniej zakładki leżą na panelu tab control
    // (rodzeństwo, nie dzieci) — wymuszamy przemalowanie całości.
    // RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW
    if (app.panel) |h| _ = RedrawWindow(h, null, null, 0x0001 | 0x0004 | 0x0080 | 0x0100);
}

fn setListMode(on: bool) void {
    app.list_mode = on;
    setCheck(app.chk_list, on);
    var v: u32 = @intFromBool(on);
    _ = w.RegSetKeyValueW(w.HKEY_CURRENT_USER, reg_key, L("ListView"), w.REG_DWORD, &v, 4);
    showTab(app.current);
}

fn loadListMode() bool {
    var v: u32 = 0;
    var size: u32 = 4;
    if (w.RegGetValueW(w.HKEY_CURRENT_USER, reg_key, L("ListView"), w.RRF_RT_REG_DWORD, null, &v, &size) != 0) return false;
    return v != 0;
}

// ---------------------------------------------------------------------------
// Akcje
// ---------------------------------------------------------------------------

fn openUrl(url: []const u8) void {
    // Otwieramy wyłącznie adresy https zbudowane przez links.zig.
    if (!std.mem.startsWith(u8, url, "https://")) return;
    var wb: [2048]u16 = undefined;
    _ = w.ShellExecuteW(app.hwnd, L("open"), widen(&wb, url), null, null, w.SW_SHOWNORMAL);
}

const ExportKind = enum { txt, html, json };

fn exportReport(kind: ExportKind) void {
    const st = app.state orelse return;
    var file_buf: [1024]u16 = @splat(0);
    const def = switch (kind) {
        .txt => L("ferrumscope-report.txt"),
        .html => L("ferrumscope-report.html"),
        .json => L("ferrumscope-report.json"),
    };
    @memcpy(file_buf[0..def.len], def);
    const filter = switch (kind) {
        .txt => L("Tekst (*.txt)\x00*.txt\x00\x00"),
        .html => L("HTML (*.html)\x00*.html\x00\x00"),
        .json => L("JSON (*.json)\x00*.json\x00\x00"),
    };
    var ofn: w.OPENFILENAMEW = .{
        .hwndOwner = app.hwnd,
        .lpstrFilter = filter.ptr,
        .lpstrFile = &file_buf,
        .nMaxFile = file_buf.len,
        .Flags = w.OFN_OVERWRITEPROMPT | w.OFN_PATHMUSTEXIST | w.OFN_NOCHANGEDIR,
        .lpstrTitle = L("Eksport raportu FerrumScope"),
    };
    if (w.GetSaveFileNameW(&ofn) == 0) return;
    const end = std.mem.indexOfScalar(u16, &file_buf, 0) orelse file_buf.len;
    var pb: [4096]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&pb, file_buf[0..end]) catch return;
    const path = pb[0..n];

    rebuild();
    const r = st.reportOf(app.pages);
    const ok = blk: {
        const f = std.fs.createFileAbsolute(path, .{}) catch break :blk false;
        defer f.close();
        var buf: [16 * 1024]u8 = undefined;
        var fw = f.writer(&buf);
        const wr = &fw.interface;
        (switch (kind) {
            .txt => report.writeText(wr, r, exportOpts()),
            .html => report.writeHtml(wr, r, exportOpts()),
            .json => report.writeJson(wr, r, exportOpts()),
        }) catch break :blk false;
        wr.flush() catch break :blk false;
        break :blk true;
    };
    var mb: [1200]u8 = undefined;
    const msg = std.fmt.bufPrint(&mb, "{s}: {s}\nNumery seryjne: {s}.", .{
        if (ok) "Zapisano raport" else "Nie udało się zapisać raportu",
        path,
        if (app.show_serials) "JAWNE (zaznaczona opcja)" else "zamaskowane",
    }) catch "";
    var wb: [1300]u16 = undefined;
    _ = w.MessageBoxW(app.hwnd, widen(&wb, msg), L("FerrumScope"), w.MB_OK | (if (ok) w.MB_ICONINFORMATION else w.MB_ICONWARNING));
    refreshCurrent(true);
}

fn refreshAll() void {
    const st = app.state orelse return;
    st.loadSnapshot();
    st.tick();
    @memset(&app.sel_count, 0);
    showTab(app.current);
}

// ---------------------------------------------------------------------------
// Układ okna
// ---------------------------------------------------------------------------

fn layout() void {
    const hwnd = app.hwnd orelse return;
    const tab = app.tab orelse return;
    var rc: w.RECT = undefined;
    _ = w.GetClientRect(hwnd, &rc);
    const m = px(6);
    const bar_h = px(26);
    _ = w.MoveWindow(tab, m, m, rc.right - 2 * m, rc.bottom - 3 * m - bar_h, 1);
    var r: w.RECT = .{ .left = m, .top = m, .right = rc.right - m, .bottom = rc.bottom - 2 * m - bar_h };
    _ = w.SendMessageW(tab, w.TCM_ADJUSTRECT, 0, lp(&r));
    move(app.panel, r.left, r.top, r.right - r.left, r.bottom - r.top);
    const pw = r.right - r.left;
    const ph = r.bottom - r.top;
    const pad = px(8);
    const ttl_h = px(26);
    move(app.ttl, pad, px(4), pw - 2 * pad, ttl_h);
    const area: w.RECT = .{ .left = pad, .top = px(6) + ttl_h, .right = pw - pad, .bottom = ph - pad };
    move(app.lv, area.left, area.top, area.right - area.left, area.bottom - area.top);
    const t = app.current;
    switch (forms.tabs[t].kind) {
        .form => layoutForm(t, area),
        .bench, .about => layoutSpecial(t, area),
        .sensors => {},
    }
    // Pasek dolny.
    const by = rc.bottom - m - bar_h;
    move(app.btn_refresh, m, by, px(96), bar_h);
    move(app.chk_sources, m + px(108), by, px(118), bar_h);
    move(app.chk_serials, m + px(230), by, px(170), bar_h);
    move(app.chk_list, m + px(404), by, px(150), bar_h);
    applyColumnWidths();
}

fn cellByHwnd(h: usize) ?*const CellCtl {
    for (app.cells[0..app.n_cells]) |*c| {
        if (c.edit != null and @intFromPtr(c.edit.?) == h) return c;
        if (c.lbl != null and @intFromPtr(c.lbl.?) == h) return c;
        if (c.mark != null and @intFromPtr(c.mark.?) == h) return c;
    }
    return null;
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
                const sel = w.SendMessageW(app.tab.?, w.TCM_GETCURSEL, 0, 0);
                if (sel >= 0) showTab(@intCast(sel));
                return 0;
            }
            if (hdr.code == w.TTN_GETDISPINFOW) {
                const di: *w.NMTTDISPINFOW = @ptrFromInt(@as(usize, @bitCast(lparam)));
                di.lpszText = L("");
                if (badgeOfHwnd(hdr.idFrom)) |bv| {
                    di.lpszText = badgeTip(bv);
                    return 0;
                }
                if (cellByHwnd(hdr.idFrom)) |c| {
                    if (fieldOfCell(c)) |f| di.lpszText = tipText(f.*) else di.lpszText = L("Brak tego pola w danych tej maszyny.");
                }
                return 0;
            }
            if (hdr.code == w.NM_CUSTOMDRAW and hdr.hwndFrom != null and hdr.hwndFrom == app.lv) {
                return onListCustomDraw(@ptrFromInt(@as(usize, @bitCast(lparam))));
            }
            return 0;
        },
        w.WM_COMMAND => {
            const id: u16 = @truncate(wp);
            const code: u16 = @truncate(wp >> 16);
            if (id >= ID_SELECTOR0 and id < ID_SELECTOR0 + n_tabs) {
                if (code == w.CBN_SELCHANGE) {
                    const t = id - ID_SELECTOR0;
                    const s = w.SendMessageW(app.sel_combo[t].?, w.CB_GETCURSEL, 0, 0);
                    if (s >= 0) app.sel_index[t] = @intCast(s);
                    refreshCurrent(true);
                }
                return 0;
            }
            if (code != w.BN_CLICKED) return 0;
            switch (id) {
                ID_REFRESH => refreshAll(),
                ID_EXPORT_TXT => exportReport(.txt),
                ID_EXPORT_HTML => exportReport(.html),
                ID_EXPORT_JSON => exportReport(.json),
                ID_SERIALS => {
                    app.show_serials = checked(app.chk_serials);
                    refreshCurrent(true);
                },
                ID_SOURCES => {
                    app.show_sources = checked(app.chk_sources);
                    updateVisibility();
                    layout();
                },
                ID_LISTVIEW => setListMode(checked(app.chk_list)),
                else => if (id >= ID_CELLBTN0 and id < ID_CELLBTN0 + max_cells) {
                    const c = &app.cells[id - ID_CELLBTN0];
                    if (cellLink(c)) |l| openUrl(l.url);
                },
            }
            return 0;
        },
        w.WM_TIMER => {
            if (wp == timer_id) {
                if (app.state) |st| st.tick();
                rebuild();
                refreshCurrent(false);
            }
            return 0;
        },
        w.WM_CTLCOLORSTATIC => {
            const hdc: ?*anyopaque = @ptrFromInt(wp);
            const ctl: usize = @bitCast(lparam);
            if (cellByHwnd(ctl)) |c| {
                if (c.edit != null and @intFromPtr(c.edit.?) == ctl) {
                    _ = w.SetTextColor(hdc, toneColor(c.tone));
                    _ = w.SetBkColor(hdc, 0x00FAFAFA);
                    return @bitCast(@intFromPtr(app.value_brush));
                }
                if (c.mark != null and @intFromPtr(c.mark.?) == ctl) _ = w.SetTextColor(hdc, toneColor(c.mark_tone));
            }
            // Pasek dolny leży na tle okna, reszta na panelu zakładki.
            for ([_]?w.HWND{ app.chk_serials, app.chk_sources, app.chk_list }) |h| {
                if (h != null and @intFromPtr(h.?) == ctl) {
                    _ = w.SetBkColor(hdc, w.GetSysColor(w.COLOR_BTNFACE));
                    return @bitCast(@intFromPtr(w.GetSysColorBrush(w.COLOR_BTNFACE)));
                }
            }
            _ = w.SetBkColor(hdc, w.GetSysColor(w.COLOR_WINDOW));
            return @bitCast(@intFromPtr(w.GetSysColorBrush(w.COLOR_WINDOW)));
        },
        w.WM_GETMINMAXINFO => {
            const mmi: *w.MINMAXINFO = @ptrFromInt(@as(usize, @bitCast(lparam)));
            mmi.ptMinTrackSize = .{ .x = px(600), .y = px(560) };
            return 0;
        },
        w.WM_DPICHANGED => {
            app.dpi = @intCast((wp >> 16) & 0xFFFF);
            const old = app.font;
            const old_title = app.font_title;
            app.font = makeFont(app.dpi);
            app.font_title = makeTitleFont(app.dpi);
            applyFonts();
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
            if (app.state) |st| st.destroy();
            app.state = null;
            w.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lparam);
}

const panel_class = L("FerrumScopePanel");

/// Panel przekazuje powiadomienia kontrolek do okna głównego — cała logika
/// zostaje w jednym `wndProc`.
fn panelProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (msg) {
        w.WM_COMMAND, w.WM_NOTIFY, w.WM_CTLCOLORSTATIC, w.WM_CTLCOLOREDIT => {
            if (app.hwnd) |main| return wndProc(main, msg, wp, lparam);
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lparam);
}

fn argTab(cmd: []const u16) ?usize {
    const key = L("--tab=");
    const at = std.mem.indexOf(u16, cmd, key) orelse return null;
    const rest = cmd[at + key.len ..];
    var buf: [32]u8 = undefined;
    var n: usize = 0;
    while (n < rest.len and n < buf.len and rest[n] != ' ' and rest[n] < 128) : (n += 1) buf[n] = @intCast(rest[n]);
    return forms.tabIndex(buf[0..n]);
}

pub fn wWinMain(inst: w.HINSTANCE, _: ?w.HINSTANCE, cmd_ptr: [*:0]u16, show_cmd: c_int) c_int {
    const cmd = std.mem.span(cmd_ptr);
    const icc: w.INITCOMMONCONTROLSEX = .{ .dwICC = w.ICC_LISTVIEW_CLASSES | w.ICC_TAB_CLASSES | w.ICC_BAR_CLASSES | w.ICC_STANDARD_CLASSES };
    _ = w.InitCommonControlsEx(&icc);

    const wc: w.WNDCLASSEXW = .{
        .lpfnWndProc = wndProc,
        .hInstance = inst,
        .hCursor = w.LoadCursorW(null, @ptrFromInt(w.IDC_ARROW)),
        .hbrBackground = w.GetSysColorBrush(w.COLOR_BTNFACE),
        .lpszClassName = class_name,
    };
    if (w.RegisterClassExW(&wc) == 0) return 1;
    const pc: w.WNDCLASSEXW = .{
        .lpfnWndProc = panelProc,
        .hInstance = inst,
        .hCursor = w.LoadCursorW(null, @ptrFromInt(w.IDC_ARROW)),
        .hbrBackground = w.GetSysColorBrush(w.COLOR_WINDOW),
        .lpszClassName = panel_class,
    };
    if (w.RegisterClassExW(&pc) == 0) return 1;

    const hwnd = w.CreateWindowExW(0, class_name, window_title, w.WS_OVERLAPPEDWINDOW | w.WS_CLIPCHILDREN, w.CW_USEDEFAULT, w.CW_USEDEFAULT, 660, 640, null, null, inst, null) orelse return 1;
    app.hwnd = hwnd;
    app.dpi = w.GetDpiForWindow(hwnd);
    if (app.dpi == 0) app.dpi = 96;
    app.font = makeFont(app.dpi);
    app.font_title = makeTitleFont(app.dpi);
    app.value_brush = w.CreateSolidBrush(0x00FAFAFA);

    app.tab = createChild(L("SysTabControl32"), null, 0, w.WS_CHILD | w.WS_VISIBLE | w.WS_CLIPSIBLINGS | w.WS_TABSTOP, 0);
    app.tip = w.CreateWindowExW(0, L("tooltips_class32"), null, w.TTS_ALWAYSTIP | w.TTS_NOPREFIX, 0, 0, 0, 0, hwnd, null, inst, null);
    if (app.tip) |tip| {
        _ = w.SendMessageW(tip, w.TTM_SETMAXTIPWIDTH, 0, px(480));
        _ = w.SendMessageW(tip, w.TTM_SETDELAYTIME, w.TTDT_AUTOPOP, 30000);
    }
    app.panel = w.CreateWindowExW(0, panel_class, null, w.WS_CHILD | w.WS_VISIBLE | w.WS_CLIPCHILDREN, 0, 0, 10, 10, hwnd, null, inst, null);
    create_parent = app.panel;
    app.ttl = createChild(L("STATIC"), null, 0, w.WS_CHILD | w.WS_VISIBLE | w.SS_LEFT | w.SS_NOPREFIX | w.SS_ENDELLIPSIS, 0);
    app.lv = createChild(L("SysListView32"), null, 0, w.WS_CHILD | w.WS_TABSTOP | w.LVS_REPORT | w.LVS_SINGLESEL | w.LVS_SHOWSELALWAYS | w.LVS_NOSORTHEADER | w.LVS_SHAREIMAGELISTS, 0);
    if (app.tab == null or app.lv == null) return 1;
    const ex = w.LVS_EX_FULLROWSELECT | w.LVS_EX_DOUBLEBUFFER | w.LVS_EX_LABELTIP;
    _ = w.SendMessageW(app.lv.?, w.LVM_SETEXTENDEDLISTVIEWSTYLE, ex, ex);
    _ = w.SetWindowTheme(app.lv.?, L("Explorer"), null);
    lvAddColumn(app.lv.?, 0, L("Pole"), col_widths[0]);
    lvAddColumn(app.lv.?, 1, L("Wartość"), col_widths[1]);
    lvAddColumn(app.lv.?, 2, L("Pewność / stan"), col_widths[2]);
    lvAddColumn(app.lv.?, 3, L("Źródło / surowe dane"), 300);

    createForms();
    createBadges(inst);
    create_parent = null;
    const bstyle = w.WS_CHILD | w.WS_VISIBLE | w.WS_TABSTOP;
    app.btn_refresh = createChild(L("BUTTON"), L("Odśwież (F5)"), 0, bstyle | w.BS_PUSHBUTTON, ID_REFRESH);
    app.chk_sources = createChild(L("BUTTON"), L("Pokaż źródła"), 0, bstyle | w.BS_AUTOCHECKBOX, ID_SOURCES);
    app.chk_serials = createChild(L("BUTTON"), L("Pokaż numery seryjne"), 0, bstyle | w.BS_AUTOCHECKBOX, ID_SERIALS);
    app.chk_list = createChild(L("BUTTON"), L("Pełna lista (Ctrl+L)"), 0, bstyle | w.BS_AUTOCHECKBOX, ID_LISTVIEW);

    // Tab control na dno kolejności Z: inaczej zamalowałby rodzeństwo.
    _ = w.SetWindowPos(app.tab.?, @ptrFromInt(1), 0, 0, 0, 0, w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOACTIVATE);
    applyFonts();
    applyRowHeight();
    for (forms.tabs, 0..) |t, i| {
        var wb: [64]u16 = undefined;
        var ti: w.TCITEMW = .{ .mask = w.TCIF_TEXT, .pszText = widen(&wb, t.title) };
        _ = w.SendMessageW(app.tab.?, w.TCM_INSERTITEMW, i, lp(&ti));
    }

    app.list_mode = loadListMode();
    if (std.mem.indexOf(u16, cmd, L("--list")) != null) app.list_mode = true;
    if (std.mem.indexOf(u16, cmd, L("--structured")) != null) app.list_mode = false;
    setCheck(app.chk_list, app.list_mode);

    app.state = app_mod.State.create(gpa, .{}) catch return 1;
    app.state.?.tick();

    const start = argTab(cmd) orelse 0;
    _ = w.SendMessageW(app.tab.?, w.TCM_SETCURSEL, start, 0);
    _ = w.SetWindowPos(hwnd, null, 0, 0, px(660), px(640), w.SWP_NOMOVE | w.SWP_NOZORDER | w.SWP_NOACTIVATE);
    showTab(start);
    _ = w.SetTimer(hwnd, timer_id, refresh_ms, null);
    _ = w.ShowWindow(hwnd, show_cmd);
    _ = w.UpdateWindow(hwnd);

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        if (msg.message == w.WM_KEYDOWN) {
            const ctrl = w.GetKeyState(w.VK_CONTROL) < 0;
            if (ctrl and msg.wParam == 'L') {
                setListMode(!app.list_mode);
                continue;
            }
            if (msg.wParam == w.VK_F5) {
                refreshAll();
                continue;
            }
        }
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
    if (app.font) |f| _ = w.DeleteObject(f);
    if (app.font_title) |f| _ = w.DeleteObject(f);
    if (app.row_imgs) |il| _ = w.ImageList_Destroy(il);
    return 0;
}

// ---------------------------------------------------------------------------
// Plakietka / logo (zakładki CPU i Grafika)
// ---------------------------------------------------------------------------

const badge = @import("gui/badge.zig");
const image = @import("gui/image.zig");
const logos = @import("logos_embedded");

const badge_class = L("FerrumScopeBadge");
const badge_w: i32 = 150;
const badge_h: i32 = 118;

const BadgeView = struct {
    hwnd: ?w.HWND = null,
    tab: usize = 0,
    kind: forms.BadgeKind = .cpu,
    text: badge.Text = .{},
    key_buf: [256]u8 = undefined,
    key_len: usize = 0,
    img: ?image.Image = null,
    /// Skąd pochodzi obraz (do podpowiedzi).
    src_buf: [320]u8 = undefined,
    src_len: usize = 0,
};
var badges: [2]BadgeView = .{ .{}, .{} };

const BLENDFUNCTION = extern struct { op: u8 = 0, flags: u8 = 0, alpha: u8 = 255, format: u8 = 1 };
const PAINTSTRUCT = extern struct { hdc: ?*anyopaque, fErase: w.BOOL, rcPaint: w.RECT, fRestore: w.BOOL, fIncUpdate: w.BOOL, rgbReserved: [32]u8 };
extern "user32" fn BeginPaint(w.HWND, *PAINTSTRUCT) callconv(.winapi) ?*anyopaque;
extern "user32" fn EndPaint(w.HWND, *const PAINTSTRUCT) callconv(.winapi) w.BOOL;
extern "user32" fn FillRect(?*anyopaque, *const w.RECT, ?w.HBRUSH) callconv(.winapi) i32;
extern "user32" fn DrawTextW(?*anyopaque, [*]const u16, i32, *w.RECT, u32) callconv(.winapi) i32;
extern "user32" fn SetCursor(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetModuleFileNameW(?*anyopaque, [*]u16, u32) callconv(.winapi) u32;
extern "gdi32" fn CreateCompatibleDC(?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteDC(?*anyopaque) callconv(.winapi) w.BOOL;
extern "gdi32" fn SelectObject(?*anyopaque, ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn RoundRect(?*anyopaque, i32, i32, i32, i32, i32, i32) callconv(.winapi) w.BOOL;
extern "gdi32" fn CreatePen(i32, i32, u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SetBkMode(?*anyopaque, i32) callconv(.winapi) i32;
extern "msimg32" fn AlphaBlend(?*anyopaque, i32, i32, i32, i32, ?*anyopaque, i32, i32, i32, i32, BLENDFUNCTION) callconv(.winapi) w.BOOL;

const DT_CENTER: u32 = 0x1;
const DT_VCENTER: u32 = 0x4;
const DT_SINGLELINE: u32 = 0x20;
const DT_END_ELLIPSIS: u32 = 0x8000;
const DT_NOPREFIX: u32 = 0x800;

fn badgeOfHwnd(h: usize) ?*BadgeView {
    for (&badges) |*bv| if (bv.hwnd != null and @intFromPtr(bv.hwnd.?) == h) return bv;
    return null;
}

fn badgeField(p: *const report.Page, sect: []const u8, label: []const u8, idx: usize) []const u8 {
    const f = forms.resolve(p, .{ .label = "", .sect = sect, .field = label }, idx) orelse return "";
    return f.value;
}

/// Katalog `data\images\` obok programu (UTF-8).
fn imagesDir(buf: []u8) ?[]const u8 {
    var wb: [1024]u16 = undefined;
    const n = GetModuleFileNameW(null, &wb, wb.len);
    if (n == 0 or n >= wb.len) return null;
    const len = std.unicode.utf16LeToUtf8(buf, wb[0..n]) catch return null;
    const dir = std.fs.path.dirname(buf[0..len]) orelse return null;
    const tail = "\\data\\images\\";
    if (dir.len + tail.len > buf.len) return null;
    @memcpy(buf[dir.len..][0..tail.len], tail);
    return buf[0 .. dir.len + tail.len];
}

fn setSrc(bv: *BadgeView, s: []const u8) void {
    const n = @min(s.len, bv.src_buf.len);
    @memcpy(bv.src_buf[0..n], s[0..n]);
    bv.src_len = n;
}

/// Wybór obrazu: obraz użytkownika → logo osadzone → rysowana plakietka.
fn loadBadgeImage(bv: *BadgeView) void {
    if (bv.img) |*i| i.deinit();
    bv.img = null;
    const bw: u32 = @intCast(px(badge_w) - px(16));
    const bh: u32 = @intCast(@divTrunc(px(badge_h) * 62, 100));
    // 1. data\images\ (pierwszeństwo).
    var dir_buf: [1024]u8 = undefined;
    if (imagesDir(&dir_buf)) |dir| {
        var st: [4][96]u8 = undefined;
        var out: [4][]const u8 = undefined;
        const kind: badge.Kind = if (bv.kind == .cpu) .cpu else .gpu;
        for (badge.imageCandidates(kind, bv.text.badge, &st, &out)) |rel| {
            var pb: [1200]u8 = undefined;
            const full = std.fmt.bufPrint(&pb, "{s}{s}", .{ dir, rel }) catch continue;
            std.fs.accessAbsolute(full, .{}) catch continue;
            var wb: [1200]u16 = undefined;
            if (image.loadFile(widen(&wb, full), bw, bh)) |img| {
                bv.img = img;
                var sb: [320]u8 = undefined;
                setSrc(bv, std.fmt.bufPrint(&sb, "Obraz użytkownika: data\\images\\{s}", .{rel}) catch "obraz użytkownika");
                return;
            }
        }
    }
    // 2. Logo dołączone (assets/logos).
    var ks: [6][64]u8 = undefined;
    var ko: [6][]const u8 = undefined;
    for (badge.logoKeys(bv.text.badge, &ks, &ko)) |k| {
        for (logos.all) |l| {
            if (!std.mem.eql(u8, l.name, k)) continue;
            if (image.loadMemory(l.bytes, bw, bh)) |img| {
                bv.img = img;
                var sb: [320]u8 = undefined;
                setSrc(bv, std.fmt.bufPrint(&sb, "Logo: assets/logos/{s}.png (Wikimedia Commons, public domain; znak towarowy właściciela, użyty do identyfikacji)", .{k}) catch "logo");
                return;
            }
        }
    }
    // 3. Rysowana plakietka.
    setSrc(bv, "Plakietka rysowana przez FerrumScope (brak logo dla tej serii/producenta)");
}

fn updateBadge(t: usize) void {
    for (&badges) |*bv| {
        if (bv.hwnd == null or bv.tab != t) continue;
        const p = pageOfTab(t) orelse continue;
        var nt: badge.Text = .{};
        if (bv.kind == .cpu) {
            badge.fromCpu(&nt, badgeField(p, "Procesor", "Producent", 0), badgeField(p, "Procesor", "Brand string", 0));
        } else {
            const idx = app.sel_index[t];
            const id = badgeField(p, "@GPU: ", "Identyfikator", idx);
            var vid: u16 = 0;
            var did: u16 = 0;
            if (id.len == 9 and id[4] == ':') {
                vid = std.fmt.parseInt(u16, id[0..4], 16) catch 0;
                did = std.fmt.parseInt(u16, id[5..9], 16) catch 0;
            }
            badge.fromGpu(&nt, vid, did, badgeField(p, "@GPU: ", "Nazwa (sterownik)", idx));
        }
        var kb: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "{s}|{s}|{s}|{x}|{x}|{d}", .{ nt.badge.vendor, nt.badge.series, nt.badge.model, nt.badge.vid, nt.badge.did, app.dpi }) catch "";
        if (std.mem.eql(u8, key, bv.key_buf[0..bv.key_len])) continue;
        @memcpy(bv.key_buf[0..key.len], key);
        bv.key_len = key.len;
        bv.text = nt;
        // Napisy w `nt` wskazują na jego bufor — po kopiowaniu przepinamy je.
        rebaseText(&bv.text, &nt);
        loadBadgeImage(bv);
        _ = w.InvalidateRect(bv.hwnd, null, 1);
    }
}

fn rebaseText(dst: *badge.Text, src: *const badge.Text) void {
    const base_src = @intFromPtr(&src.buf.data);
    const end_src = base_src + src.buf.data.len;
    inline for (.{ "vendor", "series", "model" }) |name| {
        const s = @field(dst.badge, name);
        const a = @intFromPtr(s.ptr);
        if (s.len > 0 and a >= base_src and a < end_src) {
            @field(dst.badge, name) = dst.buf.data[a - base_src ..][0..s.len];
        }
    }
}

fn drawText(hdc: ?*anyopaque, s: []const u8, r: *w.RECT, font: ?w.HFONT, color: u32) void {
    var wb: [128]u16 = undefined;
    const p = widen(&wb, s);
    const n = std.mem.len(p);
    _ = SelectObject(hdc, font);
    _ = w.SetTextColor(hdc, color);
    _ = DrawTextW(hdc, p, @intCast(n), r, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
}

var badge_font_big: ?w.HFONT = null;
var badge_font_small: ?w.HFONT = null;

fn badgeFonts() void {
    if (badge_font_big != null) return;
    var lf: w.LOGFONTW = .{ .lfHeight = -px(17), .lfWeight = 700, .lfQuality = w.CLEARTYPE_QUALITY };
    const face = L("Segoe UI");
    @memcpy(lf.lfFaceName[0..face.len], face);
    badge_font_big = w.CreateFontIndirectW(&lf);
    lf.lfHeight = -px(12);
    lf.lfWeight = 600;
    badge_font_small = w.CreateFontIndirectW(&lf);
}

fn paintBadge(hwnd: w.HWND, bv: *BadgeView) void {
    var ps: PAINTSTRUCT = undefined;
    const hdc = BeginPaint(hwnd, &ps);
    defer _ = EndPaint(hwnd, &ps);
    badgeFonts();
    var rc: w.RECT = undefined;
    _ = w.GetClientRect(hwnd, &rc);
    _ = FillRect(hdc, &rc, w.GetSysColorBrush(w.COLOR_WINDOW));
    _ = SetBkMode(hdc, 1); // TRANSPARENT
    const b = bv.text.badge;
    const col = b.scheme.colors();
    const rad = px(14);
    if (bv.img) |img| {
        // Logo na jasnym kafelku z cienką ramką, model pod spodem.
        const pen = CreatePen(0, 1, 0x00D0D0D0);
        const br = w.CreateSolidBrush(0x00FFFFFF);
        const op = SelectObject(hdc, pen);
        const ob = SelectObject(hdc, br);
        _ = RoundRect(hdc, 0, 0, rc.right, rc.bottom, rad, rad);
        _ = SelectObject(hdc, op);
        _ = SelectObject(hdc, ob);
        _ = image.DeleteObject(pen);
        _ = w.DeleteObject(br);
        const area_h = @divTrunc(rc.bottom * 68, 100);
        const x = @divTrunc(rc.right - @as(i32, @intCast(img.w)), 2);
        const y = @divTrunc(area_h - @as(i32, @intCast(img.h)), 2) + px(4);
        const mdc = CreateCompatibleDC(hdc);
        const old = SelectObject(mdc, img.bmp);
        _ = AlphaBlend(hdc, x, y, @intCast(img.w), @intCast(img.h), mdc, 0, 0, @intCast(img.w), @intCast(img.h), .{});
        _ = SelectObject(mdc, old);
        _ = DeleteDC(mdc);
        var tr: w.RECT = .{ .left = px(4), .top = area_h, .right = rc.right - px(4), .bottom = rc.bottom - px(4) };
        drawText(hdc, if (b.model.len > 0) b.model else b.series, &tr, badge_font_big, 0x00303030);
        return;
    }
    // Rysowana plakietka: kafelek w barwach serii, tekst producent/seria/model.
    const br = w.CreateSolidBrush(col.bg);
    const pen = CreatePen(0, px(2), col.accent);
    const op = SelectObject(hdc, pen);
    const ob = SelectObject(hdc, br);
    _ = RoundRect(hdc, 1, 1, rc.right - 1, rc.bottom - 1, rad, rad);
    _ = SelectObject(hdc, op);
    _ = SelectObject(hdc, ob);
    _ = image.DeleteObject(pen);
    _ = w.DeleteObject(br);
    const third = @divTrunc(rc.bottom, 3);
    var r1: w.RECT = .{ .left = px(6), .top = px(6), .right = rc.right - px(6), .bottom = third };
    drawText(hdc, b.vendor, &r1, badge_font_small, col.accent);
    var r2: w.RECT = .{ .left = px(6), .top = third, .right = rc.right - px(6), .bottom = 2 * third };
    drawText(hdc, if (b.series.len > 0) b.series else "—", &r2, badge_font_big, col.text);
    var r3: w.RECT = .{ .left = px(6), .top = 2 * third, .right = rc.right - px(6), .bottom = rc.bottom - px(6) };
    drawText(hdc, b.model, &r3, badge_font_small, col.text);
}

fn badgeLink(bv: *const BadgeView) ?*const report.Link {
    const p = pageOfTab(bv.tab) orelse return null;
    if (bv.kind == .cpu) return forms.findLink(p, "Szukaj CPU", "");
    const scope = forms.instanceName(p, "GPU: ", app.sel_index[bv.tab]) orelse "";
    return forms.findLink(p, "Szukaj karty", scope);
}

fn badgeProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    const WM_PAINT: u32 = 0x000F;
    const WM_LBUTTONUP: u32 = 0x0202;
    const WM_SETCURSOR: u32 = 0x0020;
    const WM_ERASEBKGND: u32 = 0x0014;
    const bv = badgeOfHwnd(@intFromPtr(hwnd));
    switch (msg) {
        WM_PAINT => if (bv) |b| {
            paintBadge(hwnd, b);
            return 0;
        },
        WM_ERASEBKGND => return 1,
        WM_LBUTTONUP => if (bv) |b| {
            if (badgeLink(b)) |l| openUrl(l.url);
            return 0;
        },
        WM_SETCURSOR => {
            _ = SetCursor(w.LoadCursorW(null, @ptrFromInt(32649))); // IDC_HAND
            return 1;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lparam);
}

fn createBadges(inst: w.HINSTANCE) void {
    const bc: w.WNDCLASSEXW = .{ .lpfnWndProc = badgeProc, .hInstance = inst, .lpszClassName = badge_class };
    _ = w.RegisterClassExW(&bc);
    var n: usize = 0;
    for (forms.tabs, 0..) |t, ti| {
        const k = t.badge orelse continue;
        if (n >= badges.len) break;
        badges[n] = .{ .tab = ti, .kind = k };
        badges[n].hwnd = w.CreateWindowExW(0, badge_class, null, w.WS_CHILD, 0, 0, 10, 10, app.panel, null, inst, null);
        addTip(badges[n].hwnd);
        n += 1;
    }
}

fn badgeTip(bv: *const BadgeView) [*:0]const u16 {
    var b: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{s}\nKliknij: wyszukaj w bazie TechPowerUp (otwiera przeglądarkę).", .{bv.src_buf[0..bv.src_len]}) catch "";
    return widen(&tip_buf, s);
}
