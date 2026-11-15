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
//! sensors, bench, about), `--list` / `--structured` (wymusza widok) i
//! `--lang=<kod>` (język interfejsu, np. `en`, `de`, `pt-BR`).
//!
//! Język: `--lang=` → `language` w `data\settings.ini` → język Windows.
//! Wszystkie teksty okna przechodzą przez `i18n` (identyfikator = tekst polski).

const std = @import("std");
const w = @import("gui/win32.zig");
const forms = @import("gui/forms.zig");
const present = @import("present.zig");
const app_mod = @import("app.zig");
const ferrum = @import("root.zig");
const pci_embedded = @import("db/pci_embedded.zig");
const update = @import("update/update.zig");
const i18n = @import("i18n/i18n.zig");
const i18n_system = @import("i18n/system.zig");
const settings = @import("settings.zig");

/// Katalogi tłumaczeń osadzone w programie (build.zig → `locales_embedded`).
const locale_sources = i18n.embeddedSources(@import("locales_embedded"));

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
const ID_LANG: u16 = 107;
const ID_SELECTOR0: u16 = 300; // + indeks zakładki
const ID_CELLBTN0: u16 = 400; // + indeks komórki
const ID_PINBTN0: u16 = 700; // + indeks komórki

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
    pin: ?w.HWND = null,
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
    /// Osobny kontener na każdą zakładkę (dziecko `panel`). Ukrycie kontenera
    /// ukrywa wszystkie kontrolki zakładki naraz — także te, których nie ma
    /// w tabelach `cells`/`groups`/`extras` — i wymusza przemalowanie odsłoniętego
    /// obszaru, więc nic z innej zakładki nie „prześwituje”.
    tab_panels: [n_tabs]?w.HWND = @splat(null),
    lv: ?w.HWND = null,
    ttl: ?w.HWND = null,
    btn_refresh: ?w.HWND = null,
    chk_serials: ?w.HWND = null,
    chk_sources: ?w.HWND = null,
    chk_list: ?w.HWND = null,
    /// Wybór języka (zakładka „O programie”, prawy górny róg w wierszu tytułu).
    lang_label: ?w.HWND = null,
    lang_combo: ?w.HWND = null,
    /// Graficzna mapa gniazd pamięci (zakładka Pamięć).
    slot_map: ?w.HWND = null,
    /// Podpis ostatnio narysowanej mapy (wybór + obsadzenie) — przemalowanie
    /// tylko po zmianie.
    slot_map_sig: u64 = std.math.maxInt(u64),
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
    for ([_]?w.HWND{ app.tab, app.lv, app.btn_refresh, app.chk_serials, app.chk_sources, app.chk_list, app.lang_label, app.lang_combo }) |h| setFont(h, f);
    for (app.cells[0..app.n_cells]) |c| {
        setFont(c.pin, f);
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
        // Litery tłumaczone z kontekstem „znacznik” (inaczej kolidowałyby
        // z innymi jednoliterowymi tekstami); objaśnia je tekst „Znaczniki źródeł”.
        .ok => switch (f.confidence) {
            .high => i18n.t("znacznik\x04W"),
            .medium => i18n.t("znacznik\x04Ś"),
            .low => i18n.t("znacznik\x04N"),
            .unknown => "?",
        },
        .estimate => "~",
        .placeholder => i18n.t("znacznik\x04Z"),
        .requires_admin => i18n.t("znacznik\x04A"),
        .requires_driver => i18n.t("znacznik\x04S"),
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
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = report.shownRaw(f, exportOpts());
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, i18n.tf(a, "Źródło: {source}\nPewność: {confidence} · stan: {state}", .{
        .source = if (f.source.len > 0) f.source else "—",
        .confidence = f.confidence.toSlice(),
        .state = f.state.label(),
    })) catch {};
    if (raw.len > 0) {
        out.append(a, '\n') catch {};
        out.appendSlice(a, i18n.tf(a, "Surowo: {raw}", .{ .raw = raw })) catch {};
    }
    if (f.note.len > 0) {
        out.append(a, '\n') catch {};
        out.appendSlice(a, i18n.tf(a, "Uwaga: {note}", .{ .note = f.note })) catch {};
    }
    return widen(&tip_buf, out.items);
}

/// Tworzy kontrolkę z tekstem UTF-8 (np. przetłumaczonym).
fn createText(class: [*:0]const u16, text: []const u8, ex: u32, style: u32, id: u16) ?w.HWND {
    var wb: [1024]u16 = undefined;
    return createChild(class, widen(&wb, text), ex, style, id);
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
        create_parent = app.tab_panels[ti] orelse app.panel;
        // Teksty z forms.zig są identyfikatorami katalogu — tłumaczymy je tutaj.
        if (t.selector) |s| {
            app.sel_label[ti] = createText(L("STATIC"), i18n.t(s.label), 0, child | w.SS_LEFT | w.SS_NOPREFIX | w.SS_ENDELLIPSIS, 0);
            app.sel_combo[ti] = createChild(L("COMBOBOX"), null, 0, child | w.WS_TABSTOP | w.WS_VSCROLL | w.CBS_DROPDOWNLIST, ID_SELECTOR0 + @as(u16, tab));
        }
        for (t.bands) |band| for (band) |*g| {
            if (app.n_groups < max_groups) {
                // Ramka przed swoimi polami i z WS_CLIPSIBLINGS: nie zamalowuje
                // pól, które leżą w jej wnętrzu.
                app.groups[app.n_groups] = .{ .tab = tab, .hwnd = createText(L("BUTTON"), i18n.t(g.title), 0, child | w.WS_CLIPSIBLINGS | w.BS_GROUPBOX, 0) };
                app.n_groups += 1;
            }
            for (g.rows) |row| for (row) |*c| {
                if (app.n_cells >= max_cells) continue;
                const idx = app.n_cells;
                var cc: CellCtl = .{ .tab = tab, .cell = c };
                cc.lbl = createText(L("STATIC"), i18n.t(c.label), 0, child | w.SS_LEFT | w.SS_NOPREFIX | w.SS_ENDELLIPSIS, 0);
                const multi: u32 = if (c.lines > 1) w.ES_MULTILINE else w.ES_AUTOHSCROLL;
                cc.edit = createChild(L("EDIT"), null, 0, child | w.WS_TABSTOP | w.WS_BORDER | w.ES_READONLY | multi, 0);
                cc.mark = createChild(L("STATIC"), null, 0, child | w.SS_NOPREFIX, 0);
                if (c.button.len > 0) {
                    cc.btn = createText(L("BUTTON"), i18n.t(c.button), 0, child | w.WS_TABSTOP | w.BS_PUSHBUTTON, ID_CELLBTN0 + @as(u16, @intCast(idx)));
                }
                if (c.pin) {
                    cc.pin = createText(L("BUTTON"), i18n.t("Przypnij…"), 0, child | w.WS_TABSTOP | w.BS_PUSHBUTTON, ID_PINBTN0 + @as(u16, @intCast(idx)));
                } else if (c.pin_model) {
                    cc.pin = createText(L("BUTTON"), i18n.t("Przypnij nazwę modelu…"), 0, child | w.WS_TABSTOP | w.BS_PUSHBUTTON, ID_PINBTN0 + @as(u16, @intCast(idx)));
                }
                app.cells[idx] = cc;
                app.n_cells += 1;
                addTip(cc.edit);
                addTip(cc.lbl);
            };
        };
    }
    createSpecialTabs();
    create_parent = app.panel;
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
    create_parent = app.tab_panels[ix_bench] orelse app.panel;
    extra(ix_bench, createText(L("BUTTON"), i18n.t("Benchmark i test obciążeniowy"), 0, w.WS_CHILD | w.WS_CLIPSIBLINGS | w.BS_GROUPBOX, 0));
    extra(ix_bench, createText(L("STATIC"), i18n.t("Planowane: test wydajności jednego wątku i wszystkich wątków oraz test stabilności pod obciążeniem.\n\nW tej wersji nic nie jest mierzone ani uruchamiane — zakładka tylko rezerwuje miejsce. Wyniki będą miały to samo źródło i pewność co reszta programu."), 0, st, 0));
    // --- O programie ----------------------------------------------------------
    create_parent = app.tab_panels[ix_about] orelse app.panel;
    extra(ix_about, createChild(L("BUTTON"), L("FerrumScope"), 0, w.WS_CHILD | w.WS_CLIPSIBLINGS | w.BS_GROUPBOX, 0));
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const pci_ver = if (pci_embedded.get()) |db| db.version() else i18n.t("niedostępna");
    const txt = i18n.tf(a, "Wersja {version} · licencja GPL-3.0-or-later\nOtwarte narzędzie do identyfikacji sprzętu. Każda wartość ma źródło i pewność.\nNazwy urządzeń PCI: PCI ID Repository {pci} (GPL-2.0+ lub BSD-3-Clause).\nBaza CPU: własna HWDB z jawnym pochodzeniem wpisów (bez danych CPU-Z/GPU-Z).", .{ .version = present.version, .pci = pci_ver });
    const h = createChild(L("STATIC"), null, 0, st, 0);
    setText(h, txt);
    extra(ix_about, h);
    extra(ix_about, createText(L("BUTTON"), i18n.t("Raport"), 0, w.WS_CHILD | w.WS_CLIPSIBLINGS | w.BS_GROUPBOX, 0));
    extra(ix_about, createText(L("BUTTON"), i18n.t("Eksport TXT…"), 0, w.WS_CHILD | w.WS_TABSTOP | w.BS_PUSHBUTTON, ID_EXPORT_TXT));
    extra(ix_about, createText(L("BUTTON"), i18n.t("Eksport HTML…"), 0, w.WS_CHILD | w.WS_TABSTOP | w.BS_PUSHBUTTON, ID_EXPORT_HTML));
    extra(ix_about, createText(L("BUTTON"), i18n.t("Eksport JSON…"), 0, w.WS_CHILD | w.WS_TABSTOP | w.BS_PUSHBUTTON, ID_EXPORT_JSON));
    extra(ix_about, createText(L("STATIC"), i18n.t("Numery seryjne w raporcie są zamaskowane, chyba że zaznaczono „Pokaż numery seryjne”."), 0, st, 0));
    extra(ix_about, createText(L("BUTTON"), i18n.t("Znaczniki źródeł"), 0, w.WS_CHILD | w.WS_CLIPSIBLINGS | w.BS_GROUPBOX, 0));
    extra(ix_about, createText(L("STATIC"), i18n.t("Najedź na wartość, aby zobaczyć źródło, pewność i surowe dane.\n„Pokaż źródła” dodaje znacznik: W wysoka · Ś średnia · N niska pewność · ~ oszacowanie · Z zaślepka firmware · A wymaga administratora · S wymaga sterownika · – niedostępne."), 0, st, 0));
    // --- Język (prawy górny róg zakładki, w wierszu tytułu; układ w layout()) --
    // Wiersz tytułu należy do wspólnego panelu, nie do kontenera zakładki.
    create_parent = app.panel;
    app.lang_label = createText(L("STATIC"), i18n.t("Język:"), 0, w.WS_CHILD | w.SS_RIGHT | w.SS_NOPREFIX | w.SS_ENDELLIPSIS, 0);
    app.lang_combo = createChild(L("COMBOBOX"), null, 0, w.WS_CHILD | w.WS_TABSTOP | w.WS_VSCROLL | w.CBS_DROPDOWNLIST, ID_LANG);
    if (app.lang_combo) |cb| {
        // Pozycja na liście = indeks w `i18n.locales`.
        for (i18n.native_names) |name| {
            var nb: [64]u16 = undefined;
            _ = w.SendMessageW(cb, w.CB_ADDSTRING, 0, lp(widen(&nb, name)));
        }
        _ = w.SendMessageW(cb, w.CB_SETCURSEL, i18n.indexOf(i18n.locale()) orelse 0, 0);
    }
    // --- Aktualizacje (logika w update/gui.zig, teksty w update/text.zig) -----
    create_parent = app.tab_panels[ix_about] orelse app.panel;
    const ut = update.text.get();
    var ub: [512]u16 = undefined;
    extra(ix_about, createChild(L("BUTTON"), widen(&ub, ut.gui_group), 0, w.WS_CHILD | w.WS_CLIPSIBLINGS | w.BS_GROUPBOX, 0));
    const upd_btn = createChild(L("BUTTON"), widen(&ub, ut.gui_check_button), 0, w.WS_CHILD | w.WS_TABSTOP | w.BS_PUSHBUTTON, update.gui.ID_CHECK);
    const upd_auto = createChild(L("BUTTON"), widen(&ub, ut.gui_auto_checkbox), 0, w.WS_CHILD | w.WS_TABSTOP | w.BS_AUTOCHECKBOX, update.gui.ID_AUTO);
    extra(ix_about, upd_btn);
    extra(ix_about, upd_auto);
    const upd_channel = createChild(L("BUTTON"), widen(&ub, ut.gui_channel_checkbox), 0, w.WS_CHILD | w.WS_TABSTOP | w.BS_AUTOCHECKBOX, update.gui.ID_CHANNEL);
    extra(ix_about, upd_channel);
    const upd_info = createChild(L("STATIC"), null, 0, st, 0);
    setText(upd_info, ut.gui_info);
    extra(ix_about, upd_info);
    update.gui.initControls(upd_btn, upd_auto, upd_channel);
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
    const pin_w: i32 = 70;
    const pin_model_w: i32 = 150;
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
        // Etykieta nieco szersza niż polska — tłumaczenia bywają dłuższe.
        move(app.sel_label[t], x0 + px(4), y + px(4), px(90), px(20));
        move(app.sel_combo[t], x0 + px(98), y, @max(px(200), full_width - px(98)), px(300));
        y += px(M.sel_h) + px(4);
    }
    // Komórki i ramki są tworzone w tej samej kolejności co tu iterujemy.
    var gi: usize = 0;
    while (gi < app.n_groups and app.groups[gi].tab != t) gi += 1;
    var ci: usize = 0;
    while (ci < app.n_cells and app.cells[ci].tab != t) ci += 1;

    // Mapa gniazd pamięci: pas na całą szerokość przed grupami.
    if (forms.tabs[t].slot_map) {
        const mh = slotMapHeight();
        move(app.slot_map, x0, y, full_width, mh);
        y += mh + px(M.gap);
    }
    // Kolumna plakietek po prawej, od góry pierwszego pasa grup. Każdy pas,
    // który zaczyna się obok kolumny, zostawia na nią miejsce.
    var badge_bottom = y;
    {
        var by = y + px(6);
        for (&badges) |*bv| {
            if (bv.hwnd == null or bv.tab != t) continue;
            const bh = badgeHeight(bv.kind);
            move(bv.hwnd, x0 + full_width - px(badge_w), by, px(badge_w), bh);
            badge_bottom = by + bh;
            by += bh + px(4);
        }
    }
    for (forms.tabs[t].bands) |band| {
        const width = if (y < badge_bottom) full_width - px(badge_w) - px(M.gap) else full_width;
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
                    const pin_w = px(if (c.pin_model) M.pin_model_w else M.pin_w);
                    const pw: i32 = if (cc.pin != null) pin_w + px(4) else 0;
                    const bw: i32 = (if (cc.btn != null) px(M.btn_w) + px(4) else 0) + pw;
                    const eh = px(M.edit_h) + px(M.line_h) * (@as(i32, c.lines) - 1);
                    move(cc.lbl, cx, ry + px(3), lw - px(4), px(18));
                    move(cc.edit, cx + lw, ry, @max(px(20), cw - lw - mw - bw), eh);
                    move(cc.mark, cx + cw - mw - bw + px(3), ry + px(3), mw, px(18));
                    show(cc.mark, app.show_sources and t == app.current and !app.list_mode);
                    if (cc.btn) |b| move(b, cx + cw - bw + px(4), ry - px(1), px(M.btn_w), px(M.edit_h) + px(2));
                    if (cc.pin) |b| move(b, cx + cw - pw + px(4), ry - px(1), pin_w, px(M.edit_h) + px(2));
                }
                ry += rowHeight(row);
            }
            gx += gw + px(M.gap);
        }
        y += band_h + px(M.gap);
    }
}

/// Wysokość tekstu kontrolki STATIC przy danej szerokości (DT_CALCRECT,
/// czcionka kontrolki) — ramki zakładek specjalnych mają rozmiar treści,
/// zamiast stałej wysokości, która przy dłuższych tłumaczeniach wychodziła
/// poza okno.
fn textHeight(hh: w.HWND, width: i32) i32 {
    var wb: [2048]u16 = undefined;
    const n = GetWindowTextW(hh, &wb, wb.len);
    const hdc = GetDC(hh);
    defer _ = ReleaseDC(hh, hdc);
    const old = SelectObject(hdc, app.font);
    defer _ = SelectObject(hdc, old);
    var r: w.RECT = .{ .left = 0, .top = 0, .right = width, .bottom = 0 };
    // DT_WORDBREAK | DT_CALCRECT | DT_NOPREFIX
    _ = DrawTextW(hdc, &wb, n, &r, 0x10 | 0x400 | 0x800);
    return r.bottom - r.top + px(4);
}

extern "user32" fn GetWindowTextW(w.HWND, [*]u16, i32) callconv(.winapi) i32;
extern "user32" fn GetDC(?w.HWND) callconv(.winapi) ?*anyopaque;
extern "user32" fn ReleaseDC(?w.HWND, ?*anyopaque) callconv(.winapi) i32;

fn layoutSpecial(t: usize, area: w.RECT) void {
    var y = area.top;
    const x = area.left;
    const width = area.right - area.left;
    const inner_x = x + px(M.pad);
    const inner_w = width - 2 * px(M.pad);
    var bx = inner_x;
    var row_open = false; // trwa wiersz przycisków
    var group: ?w.HWND = null;
    var group_top: i32 = 0;
    for (app.extras[0..app.n_extras]) |e| {
        if (e.tab != t) continue;
        const hh = e.hwnd orelse continue;
        // Kolejność kontrolek jest stała (createSpecialTabs): ramka, treść, ...
        const is_group = isGroupBox(hh);
        const is_button = !is_group and isButton(hh);
        if (is_group) {
            if (row_open) y += px(30);
            row_open = false;
            if (group) |g| {
                move(g, x, group_top, width, y + px(6) - group_top);
                y += px(6) + px(M.gap);
            }
            group = hh;
            group_top = y;
            y += px(M.head) + px(2);
            bx = inner_x;
        } else if (is_button) {
            // Pole wyboru i dłuższe przyciski (aktualizacje) potrzebują więcej miejsca.
            const style: u32 = @bitCast(GetWindowLongW(hh, -16));
            const bw: i32 = if ((style & 0xF) == w.BS_AUTOCHECKBOX) px(230) else if (GetWindowLongW(hh, -12) == update.gui.ID_CHECK) px(170) else px(130);
            if (row_open and bx + bw > inner_x + inner_w) {
                y += px(30);
                bx = inner_x;
            }
            move(hh, bx, y, bw, px(26));
            bx += bw + px(6);
            row_open = true;
        } else {
            if (row_open) y += px(30);
            row_open = false;
            const th = textHeight(hh, inner_w);
            move(hh, inner_x, y, inner_w, th);
            y += th;
            bx = inner_x;
        }
    }
    if (row_open) y += px(30);
    if (group) |g| move(g, x, group_top, width, y + px(6) - group_top);
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
            const f = forms.resolve(p, .{ .label = "", .sect = "@Gniazdo {slot}", .field = "Moduł" }, i);
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

fn sourceText(f: report.Field, a: std.mem.Allocator) []const u8 {
    const raw = report.shownRaw(f, exportOpts());
    if (raw.len == 0 and f.note.len == 0) return f.source;
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, f.source) catch {};
    if (raw.len > 0) {
        out.appendSlice(a, "  ") catch {};
        out.appendSlice(a, i18n.tf(a, "[raw: {raw}]", .{ .raw = raw })) catch {};
    }
    if (f.note.len > 0) {
        out.appendSlice(a, "  — ") catch {};
        out.appendSlice(a, f.note) catch {};
    }
    return out.items;
}

fn sectionVisible(t: usize, title: []const u8) bool {
    const filter = forms.tabs[t].list_sections;
    // Filtr jest identyfikatorem katalogu — tytuły sekcji strony są już przetłumaczone.
    return filter.len == 0 or std.mem.startsWith(u8, title, i18n.t(filter));
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
            var srcm: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&srcm);
            const value = report.shownValue(f, exportOpts(), &vb);
            const r: i32 = @intCast(row);
            if (redo) {
                lvAddRow(lv, r, &.{ f.label, value, statusText(f, &sb), sourceText(f, fba.allocator()) }, @intCast(si + 1));
            } else {
                lvSetText(lv, r, 1, value);
                lvSetText(lv, r, 2, statusText(f, &sb));
                lvSetText(lv, r, 3, sourceText(f, fba.allocator()));
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
    for (app.tab_panels, 0..) |h, i| show(h, i == t and !list);
    for (app.cells[0..app.n_cells]) |c| {
        const vis = !list and c.tab == t;
        show(c.lbl, vis);
        show(c.edit, vis);
        show(c.mark, vis and app.show_sources);
        show(c.btn, vis);
        show(c.pin, vis);
    }
    for (app.groups[0..app.n_groups]) |g| show(g.hwnd, !list and g.tab == t);
    for (app.extras[0..app.n_extras]) |e| show(e.hwnd, e.tab == t);
    for (badges) |bv| show(bv.hwnd, !list and bv.tab == t);
    show(app.slot_map, !list and forms.tabs[t].slot_map);
    for (0..n_tabs) |i| {
        show(app.sel_label[i], i == t);
        show(app.sel_combo[i], i == t);
    }
    show(app.lang_label, t == ix_about);
    show(app.lang_combo, t == ix_about);
}

fn refreshCurrent(full: bool) void {
    const t = app.current;
    if (usesList(t)) {
        // Lista z selektorem (np. dyski) pokazuje i tak całą stronę.
        renderList(t, full);
    } else if (forms.tabs[t].kind == .form) {
        fillForm(t);
        updateBadge(t);
        if (forms.tabs[t].slot_map) updateSlotMap();
    }
    const p = pageOfTab(t);
    setText(app.ttl, if (p) |pp| (if (pp.headline.len > 0) pp.headline else pp.title) else i18n.t(forms.tabs[t].title));
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
    // Filtr: opis (tłumaczony tylko dla „Tekst”) + wzorzec, zakończone podwójnym zerem.
    const desc = switch (kind) {
        .txt => i18n.t("Tekst (*.txt)"),
        .html => "HTML (*.html)",
        .json => "JSON (*.json)",
    };
    const pattern = switch (kind) {
        .txt => L("*.txt"),
        .html => L("*.html"),
        .json => L("*.json"),
    };
    var filter: [256]u16 = undefined;
    const dlen = std.mem.len(widen(filter[0 .. filter.len - pattern.len - 2], desc));
    @memcpy(filter[dlen + 1 ..][0..pattern.len], pattern);
    filter[dlen + 1 + pattern.len] = 0;
    filter[dlen + 2 + pattern.len] = 0;
    var title_buf: [256]u16 = undefined;
    var ofn: w.OPENFILENAMEW = .{
        .hwndOwner = app.hwnd,
        .lpstrFilter = &filter,
        .lpstrFile = &file_buf,
        .nMaxFile = file_buf.len,
        .Flags = w.OFN_OVERWRITEPROMPT | w.OFN_PATHMUSTEXIST | w.OFN_NOCHANGEDIR,
        .lpstrTitle = widen(&title_buf, i18n.t("Eksport raportu FerrumScope")),
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
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const serials = if (app.show_serials) i18n.t("JAWNE (zaznaczona opcja)") else i18n.t("zamaskowane");
    const msg = if (ok)
        i18n.tf(a, "Zapisano raport: {path}\nNumery seryjne: {serials}.", .{ .path = path, .serials = serials })
    else
        i18n.tf(a, "Nie udało się zapisać raportu: {path}\nNumery seryjne: {serials}.", .{ .path = path, .serials = serials });
    var wb: [2048]u16 = undefined;
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
    if (app.current == ix_about) {
        // Wybór języka w prawym górnym rogu zakładki „O programie” (wiersz tytułu
        // jest tu krótki, a ramki poniżej wypełniają już całą wysokość).
        const combo_w = px(170);
        const label_w = px(110);
        const right = pw - pad;
        move(app.lang_combo, right - combo_w, px(4), combo_w, px(300));
        move(app.lang_label, right - combo_w - px(6) - label_w, px(8), label_w, px(20));
        move(app.ttl, pad, px(4), @max(px(60), pw - 2 * pad - combo_w - label_w - px(12)), ttl_h);
    } else move(app.ttl, pad, px(4), pw - 2 * pad, ttl_h);
    const area: w.RECT = .{ .left = pad, .top = px(6) + ttl_h, .right = pw - pad, .bottom = ph - pad };
    move(app.lv, area.left, area.top, area.right - area.left, area.bottom - area.top);
    // Kontenery zakładek zajmują obszar treści; kontrolki układamy we
    // współrzędnych kontenera.
    for (app.tab_panels) |h| move(h, area.left, area.top, area.right - area.left, area.bottom - area.top);
    const local: w.RECT = .{ .left = 0, .top = 0, .right = area.right - area.left, .bottom = area.bottom - area.top };
    const t = app.current;
    switch (forms.tabs[t].kind) {
        .form => layoutForm(t, local),
        .bench, .about => layoutSpecial(t, local),
        .sensors => {},
    }
    // Pasek dolny.
    const by = rc.bottom - m - bar_h;
    // Szerokości z zapasem na dłuższe tłumaczenia (np. niemieckie).
    move(app.btn_refresh, m, by, px(110), bar_h);
    move(app.chk_sources, m + px(120), by, px(130), bar_h);
    move(app.chk_serials, m + px(254), by, px(184), bar_h);
    move(app.chk_list, m + px(442), by, px(180), bar_h);
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
                if (app.slot_map != null and hdr.idFrom == @intFromPtr(app.slot_map.?)) {
                    di.lpszText = widen(&tip_buf, i18n.t("Kliknij gniazdo, aby pokazać szczegóły modułu (to samo co lista „Gniazdo”)."));
                    return 0;
                }
                if (cellByHwnd(hdr.idFrom)) |c| {
                    if (fieldOfCell(c)) |f| di.lpszText = tipText(f.*) else di.lpszText = widen(&tip_buf, i18n.t("Brak tego pola w danych tej maszyny."));
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
                    // Lista „Gniazdo” i mapa gniazd pokazują ten sam wybór.
                    refreshCurrent(true);
                }
                return 0;
            }
            if (id == ID_LANG) {
                if (code == w.CBN_SELCHANGE) {
                    const s = w.SendMessageW(app.lang_combo.?, w.CB_GETCURSEL, 0, 0);
                    if (s >= 0 and s < i18n.locales.len) switchLanguage(hwnd, i18n.locales[@intCast(s)]);
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
                update.gui.ID_CHECK => update.gui.onCheckClicked(hwnd),
                update.gui.ID_AUTO => update.gui.onAutoToggled(@ptrFromInt(@as(usize, @bitCast(lparam)))),
                update.gui.ID_CHANNEL => update.gui.onChannelToggled(@ptrFromInt(@as(usize, @bitCast(lparam)))),
                else => if (id >= ID_PINBTN0 and id < ID_PINBTN0 + max_cells) {
                    const c = &app.cells[id - ID_PINBTN0];
                    if (c.cell.pin_model) pinModelFromClipboard(c) else pinFromClipboard(c);
                } else if (id >= ID_CELLBTN0 and id < ID_CELLBTN0 + max_cells) {
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
        update.gui.WM_UPDATE => {
            update.gui.onMessage(hwnd, lparam);
            return 0;
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

/// Wartość flagi `--lang=<kod>` (ASCII) w `buf`; pusty = brak flagi.
fn argLang(cmd: []const u16, buf: []u8) []const u8 {
    const key = L("--lang=");
    const at = std.mem.indexOf(u16, cmd, key) orelse return "";
    const rest = cmd[at + key.len ..];
    var n: usize = 0;
    while (n < rest.len and n < buf.len and rest[n] != ' ' and rest[n] != '"' and rest[n] < 128) : (n += 1) buf[n] = @intCast(rest[n]);
    return buf[0..n];
}

/// Zmiana języka z listy na zakładce „O programie”.
///
/// Sposób: zapis `language` w `data\settings.ini`, a potem ponowne
/// uruchomienie programu (ta sama ścieżka, te same argumenty, ale z
/// `--lang=<kod> --tab=about`; bez `--post-update=`) i zamknięcie bieżącego
/// okna zwykłą drogą (DestroyWindow → WM_DESTROY, jak przy zamknięciu przez
/// użytkownika — stan i wątki w tle kończą się tak samo). Przebudowa całego
/// interfejsu w nowym procesie jest prostsza i pewniejsza niż podmiana
/// tekstów setek kontrolek w miejscu (strony raportu też są budowane
/// w wybranym języku).
fn switchLanguage(hwnd: w.HWND, code: []const u8) void {
    if (std.mem.eql(u8, code, i18n.locale())) return;
    var s = settings.load();
    s.language = code;
    settings.save(s) catch {};

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = blk: {
        var pb: [std.fs.max_path_bytes]u8 = undefined;
        const exe = std.fs.selfExePath(&pb) catch break :blk false;
        var argv: std.ArrayList([]const u8) = .empty;
        argv.append(a, exe) catch break :blk false;
        const args = std.process.argsAlloc(a) catch break :blk false;
        for (args[1..]) |arg| {
            if (std.mem.startsWith(u8, arg, "--lang=") or std.mem.startsWith(u8, arg, "--tab=") or
                std.mem.startsWith(u8, arg, "--post-update=")) continue;
            argv.append(a, arg) catch break :blk false;
        }
        argv.append(a, std.fmt.allocPrint(a, "--lang={s}", .{code}) catch break :blk false) catch break :blk false;
        argv.append(a, "--tab=about") catch break :blk false;
        var child = std.process.Child.init(argv.items, a);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        child.spawn() catch break :blk false;
        break :blk true;
    };
    if (!ok) {
        var wb: [512]u16 = undefined;
        _ = w.MessageBoxW(hwnd, widen(&wb, i18n.t("Nie udało się uruchomić programu ponownie. Nowy język zostanie użyty przy następnym uruchomieniu.")), L("FerrumScope"), w.MB_OK | w.MB_ICONWARNING);
        return;
    }
    _ = DestroyWindow(hwnd);
}

extern "user32" fn DestroyWindow(w.HWND) callconv(.winapi) w.BOOL;

pub fn wWinMain(inst: w.HINSTANCE, _: ?w.HINSTANCE, cmd_ptr: [*:0]u16, show_cmd: c_int) c_int {
    const cmd = std.mem.span(cmd_ptr);
    // Język przed utworzeniem jakiegokolwiek okna: --lang= → settings.ini → Windows.
    i18n.setSources(&locale_sources);
    var lang_buf: [32]u8 = undefined;
    var explicit = argLang(cmd, &lang_buf);
    if (explicit.len == 0) explicit = settings.load().language;
    i18n.setLocale(i18n_system.resolve(explicit));

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
    for (&app.tab_panels) |*tp| {
        tp.* = w.CreateWindowExW(0, panel_class, null, w.WS_CHILD | w.WS_CLIPCHILDREN | w.WS_CLIPSIBLINGS, 0, 0, 10, 10, app.panel, null, inst, null);
    }
    create_parent = app.panel;
    app.ttl = createChild(L("STATIC"), null, 0, w.WS_CHILD | w.WS_VISIBLE | w.SS_LEFT | w.SS_NOPREFIX | w.SS_ENDELLIPSIS, 0);
    app.lv = createChild(L("SysListView32"), null, 0, w.WS_CHILD | w.WS_TABSTOP | w.LVS_REPORT | w.LVS_SINGLESEL | w.LVS_SHOWSELALWAYS | w.LVS_NOSORTHEADER | w.LVS_SHAREIMAGELISTS, 0);
    if (app.tab == null or app.lv == null) return 1;
    const ex = w.LVS_EX_FULLROWSELECT | w.LVS_EX_DOUBLEBUFFER | w.LVS_EX_LABELTIP;
    _ = w.SendMessageW(app.lv.?, w.LVM_SETEXTENDEDLISTVIEWSTYLE, ex, ex);
    _ = w.SetWindowTheme(app.lv.?, L("Explorer"), null);
    var cb: [128]u16 = undefined;
    lvAddColumn(app.lv.?, 0, widen(&cb, i18n.t("Pole")), col_widths[0]);
    lvAddColumn(app.lv.?, 1, widen(&cb, i18n.t("Wartość")), col_widths[1]);
    lvAddColumn(app.lv.?, 2, widen(&cb, i18n.t("Pewność / stan")), col_widths[2]);
    lvAddColumn(app.lv.?, 3, widen(&cb, i18n.t("Źródło / surowe dane")), 300);

    createForms();
    createBadges(inst);
    createSlotMap(inst);
    create_parent = null;
    const bstyle = w.WS_CHILD | w.WS_VISIBLE | w.WS_TABSTOP;
    app.btn_refresh = createText(L("BUTTON"), i18n.t("Odśwież (F5)"), 0, bstyle | w.BS_PUSHBUTTON, ID_REFRESH);
    app.chk_sources = createText(L("BUTTON"), i18n.t("Pokaż źródła"), 0, bstyle | w.BS_AUTOCHECKBOX, ID_SOURCES);
    app.chk_serials = createText(L("BUTTON"), i18n.t("Pokaż numery seryjne"), 0, bstyle | w.BS_AUTOCHECKBOX, ID_SERIALS);
    app.chk_list = createText(L("BUTTON"), i18n.t("Pełna lista (Ctrl+L)"), 0, bstyle | w.BS_AUTOCHECKBOX, ID_LISTVIEW);

    // Tab control na dno kolejności Z: inaczej zamalowałby rodzeństwo.
    _ = w.SetWindowPos(app.tab.?, @ptrFromInt(1), 0, 0, 0, 0, w.SWP_NOMOVE | w.SWP_NOSIZE | w.SWP_NOACTIVATE);
    applyFonts();
    applyRowHeight();
    for (forms.tabs, 0..) |t, i| {
        var wb: [64]u16 = undefined;
        var ti: w.TCITEMW = .{ .mask = w.TCIF_TEXT, .pszText = widen(&wb, i18n.t(t.title)) };
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
    // `--post-update=<pid>` po aktualizacji albo ciche sprawdzenie (raz na dobę, w tle).
    update.gui.onStart(hwnd, cmd);

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
const vendors = @import("gui/vendors.zig");
const vendor_badge = @import("gui/vendor_badge.zig");
const logos = @import("logos_embedded");

const badge_class = L("FerrumScopeBadge");
const badge_w: i32 = 150;
const badge_h: i32 = 118;
/// Wysokość małej plakietki (producent karty, chipset).
const badge_small_h: i32 = 44;

fn badgeHeight(k: forms.BadgeKind) i32 {
    return px(if (k.small()) badge_small_h else badge_h);
}

const BadgeView = struct {
    hwnd: ?w.HWND = null,
    tab: usize = 0,
    kind: forms.BadgeKind = .cpu,
    text: badge.Text = .{},
    key_buf: [256]u8 = undefined,
    key_len: usize = 0,
    img: ?image.Image = null,
    /// Skąd pochodzi obraz (do podpowiedzi).
    src_buf: [640]u8 = undefined,
    src_len: usize = 0,
    /// Plakietki producentów: klucz (`vendors.zig`), nazwa i model — kopie,
    /// bo strony raportu są przebudowywane co sekundę.
    vkey_buf: [32]u8 = undefined,
    vkey_len: usize = 0,
    name_buf: [96]u8 = undefined,
    model_buf: [96]u8 = undefined,
};
var badges: [8]BadgeView = @splat(.{});

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
    var n = @min(s.len, bv.src_buf.len);
    // Nie tniemy w środku znaku UTF-8 (tłumaczenia bywają dłuższe).
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(bv.src_buf[0..n], s[0..n]);
    bv.src_len = n;
}

/// Wybór obrazu: obraz użytkownika → logo osadzone → rysowana plakietka.
fn loadBadgeImage(bv: *BadgeView) void {
    if (bv.img) |*i| i.deinit();
    bv.img = null;
    const bw: u32 = @intCast(px(badge_w) - px(16));
    const bh: u32 = @intCast(if (bv.kind.small()) badgeHeight(bv.kind) - px(10) else @divTrunc(px(badge_h) * 62, 100));
    if (vendor_badge.category(bv.kind)) |cat| {
        loadVendorImage(bv, cat, bw, bh);
        return;
    }
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
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();
                const ba = arena.allocator();
                setSrc(bv, i18n.tf(ba, "Obraz użytkownika: data\\images\\{file}", .{ .file = rel }));
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
                var arena = std.heap.ArenaAllocator.init(gpa);
                defer arena.deinit();
                const ba = arena.allocator();
                setSrc(bv, i18n.tf(ba, "Logo: assets/logos/{name}.png (Wikimedia Commons, public domain; znak towarowy właściciela, użyty do identyfikacji)", .{ .name = k }));
                return;
            }
        }
    }
    // 3. Rysowana plakietka.
    setSrc(bv, i18n.t("Plakietka rysowana przez FerrumScope (brak logo dla tej serii/producenta)"));
}

/// Obraz plakietki producenta: `data\images\<kategoria>\…` → logo dołączone →
/// rysowana plakietka (`vendors.logoChain`).
fn loadVendorImage(bv: *BadgeView, cat: vendors.Category, bw: u32, bh: u32) void {
    const key: ?[]const u8 = if (bv.vkey_len > 0) bv.vkey_buf[0..bv.vkey_len] else null;
    var cb: vendors.ChainBuf = .{};
    const ch = vendors.logoChain(cat, key, bv.text.badge.model, &cb);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const ba = arena.allocator();
    var dir_buf: [1024]u8 = undefined;
    if (imagesDir(&dir_buf)) |dir| {
        for (ch.images) |rel| {
            var pb: [1200]u8 = undefined;
            const full = std.fmt.bufPrint(&pb, "{s}{s}", .{ dir, rel }) catch continue;
            std.fs.accessAbsolute(full, .{}) catch continue;
            var wb: [1200]u16 = undefined;
            if (image.loadFile(widen(&wb, full), bw, bh)) |img| {
                bv.img = img;
                setSrc(bv, i18n.tf(ba, "Obraz użytkownika: data\\images\\{file}", .{ .file = rel }));
                return;
            }
        }
    }
    for (ch.logos) |k| {
        for (logos.all) |l| {
            if (!std.mem.eql(u8, l.name, k)) continue;
            if (image.loadMemory(l.bytes, bw, bh)) |img| {
                bv.img = img;
                setSrc(bv, i18n.tf(ba, "Logo: assets/logos/{name}.png (Wikimedia Commons, public domain; znak towarowy właściciela, użyty do identyfikacji)", .{ .name = k }));
                return;
            }
        }
    }
    setSrc(bv, i18n.t("Plakietka rysowana przez FerrumScope (brak logo dla tej serii/producenta)"));
}

/// Producent dla plakietki z pól strony (ten sam model co okno).
fn vendorInfo(kind: forms.BadgeKind, p: *const report.Page, idx: usize) vendor_badge.Info {
    const val = struct {
        fn f(pg: *const report.Page, c: forms.Cell, i: usize) []const u8 {
            const fld = forms.resolve(pg, c, i) orelse return "";
            return if (fld.state.isValue()) fld.value else "";
        }
    }.f;
    switch (kind) {
        .board => return vendor_badge.board(
            val(p, .{ .label = "", .sect = "Płyta główna", .field = "Producent" }, 0),
            val(p, .{ .label = "", .sect = "Płyta główna", .field = "Model" }, 0),
        ),
        .chipset => {
            const f = forms.resolve(p, .{ .label = "", .sect = "Chipset", .field = "Chipset" }, 0) orelse return .{};
            return vendor_badge.chipset(f.raw, f.value);
        },
        .memory => {
            if (idx >= p.slots.len) return .{};
            const sl = p.slots[idx];
            if (!sl.occupied) return .{ .name = i18n.t("pusty") };
            return vendor_badge.memory(sl.vendor_key, if (sl.vendor.len > 0) sl.vendor else sl.manufacturer, val(p, .{ .label = "", .sect = "@Gniazdo {slot}", .field = "Part number" }, idx));
        },
        .storage => return vendor_badge.storage(val(p, .{ .label = "", .sect = "@Dysk {index}: {model}", .field = "Model" }, idx)),
        .gpu_partner => {
            const id = badgeField(p, "@GPU: {name}", "Identyfikator", idx);
            const vid: u16 = if (id.len == 9) std.fmt.parseInt(u16, id[0..4], 16) catch 0 else 0;
            return vendor_badge.gpuPartner(vid, badgeField(p, "@GPU: {name}", "Subsystem", idx));
        },
        .cpu, .gpu => return .{},
    }
}

fn copyInto(dst: []u8, s: []const u8) []const u8 {
    var n = @min(s.len, dst.len);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    @memcpy(dst[0..n], s[0..n]);
    return dst[0..n];
}

fn updateVendorBadge(bv: *BadgeView, p: *const report.Page, idx: usize) void {
    const info = vendorInfo(bv.kind, p, idx);
    var kb: [256]u8 = undefined;
    const sig = std.fmt.bufPrint(&kb, "{s}|{s}|{s}|{d}", .{ info.key orelse "", info.name, info.model, app.dpi }) catch "";
    if (std.mem.eql(u8, sig, bv.key_buf[0..bv.key_len])) return;
    @memcpy(bv.key_buf[0..sig.len], sig);
    bv.key_len = sig.len;
    const k = copyInto(&bv.vkey_buf, info.key orelse "");
    bv.vkey_len = k.len;
    bv.text = .{};
    bv.text.badge = .{
        .series = copyInto(&bv.name_buf, if (info.name.len > 0) info.name else "—"),
        .model = if (bv.kind.small()) "" else copyInto(&bv.model_buf, info.model),
    };
    loadBadgeImage(bv);
    _ = w.InvalidateRect(bv.hwnd, null, 1);
}

fn updateBadge(t: usize) void {
    for (&badges) |*bv| {
        if (bv.hwnd == null or bv.tab != t) continue;
        const p = pageOfTab(t) orelse continue;
        if (vendor_badge.category(bv.kind) != null) {
            updateVendorBadge(bv, p, app.sel_index[t]);
            continue;
        }
        var nt: badge.Text = .{};
        if (bv.kind == .cpu) {
            badge.fromCpu(&nt, badgeField(p, "Procesor", "Producent", 0), badgeField(p, "Procesor", "Brand string", 0));
        } else {
            const idx = app.sel_index[t];
            const id = badgeField(p, "@GPU: {name}", "Identyfikator", idx);
            var vid: u16 = 0;
            var did: u16 = 0;
            if (id.len == 9 and id[4] == ':') {
                vid = std.fmt.parseInt(u16, id[0..4], 16) catch 0;
                did = std.fmt.parseInt(u16, id[5..9], 16) catch 0;
            }
            badge.fromGpu(&nt, vid, did, badgeField(p, "@GPU: {name}", "Nazwa (sterownik)", idx));
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
    if (bv.kind.small() or vendor_badge.category(bv.kind) != null) {
        paintVendorBadge(hdc, rc, bv);
        return;
    }
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

/// Plakietka producenta: logo (albo nazwa na jasnym kafelku), pod spodem
/// model — mała plakietka bez modelu.
fn paintVendorBadge(hdc: ?*anyopaque, rc: w.RECT, bv: *const BadgeView) void {
    const b = bv.text.badge;
    const rad = px(10);
    const pen = CreatePen(0, 1, 0x00D0D0D0);
    const br = w.CreateSolidBrush(0x00FFFFFF);
    const op = SelectObject(hdc, pen);
    const ob = SelectObject(hdc, br);
    _ = RoundRect(hdc, 0, 0, rc.right, rc.bottom, rad, rad);
    _ = SelectObject(hdc, op);
    _ = SelectObject(hdc, ob);
    _ = image.DeleteObject(pen);
    _ = w.DeleteObject(br);
    const small = bv.kind.small();
    const area_h = if (small or b.model.len == 0) rc.bottom else @divTrunc(rc.bottom * 72, 100);
    if (bv.img) |img| {
        const x = @divTrunc(rc.right - @as(i32, @intCast(img.w)), 2);
        const y = @divTrunc(area_h - @as(i32, @intCast(img.h)), 2);
        const mdc = CreateCompatibleDC(hdc);
        const old = SelectObject(mdc, img.bmp);
        _ = AlphaBlend(hdc, x, y, @intCast(img.w), @intCast(img.h), mdc, 0, 0, @intCast(img.w), @intCast(img.h), .{});
        _ = SelectObject(mdc, old);
        _ = DeleteDC(mdc);
    } else {
        var tr: w.RECT = .{ .left = px(6), .top = 0, .right = rc.right - px(6), .bottom = area_h };
        drawText(hdc, b.series, &tr, badge_font_big, 0x00404040);
    }
    if (!small and b.model.len > 0) {
        var mr: w.RECT = .{ .left = px(4), .top = area_h, .right = rc.right - px(4), .bottom = rc.bottom - px(4) };
        drawText(hdc, b.model, &mr, badge_font_small, 0x00505050);
    }
}

fn badgeLink(bv: *const BadgeView) ?*const report.Link {
    const p = pageOfTab(bv.tab) orelse return null;
    if (vendor_badge.category(bv.kind) != null) return null;
    if (bv.kind == .cpu) return forms.findLink(p, "cpu_search", "");
    const scope = forms.instanceName(p, "GPU: {name}", app.sel_index[bv.tab]) orelse "";
    return forms.findLink(p, "gpu_search", scope);
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
            // Dłoń tylko nad plakietką z odnośnikiem (CPU/GPU).
            const link = if (bv) |b| badgeLink(b) != null else false;
            _ = SetCursor(w.LoadCursorW(null, @ptrFromInt(@as(usize, if (link) 32649 else 32512)))); // IDC_HAND / IDC_ARROW
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
        for (t.badges) |k| {
            if (n >= badges.len) break;
            badges[n] = .{ .tab = ti, .kind = k };
            badges[n].hwnd = w.CreateWindowExW(0, badge_class, null, w.WS_CHILD, 0, 0, 10, 10, app.tab_panels[ti] orelse app.panel, null, inst, null);
            addTip(badges[n].hwnd);
            n += 1;
        }
    }
}

fn badgeTip(bv: *const BadgeView) [*:0]const u16 {
    if (badgeLink(bv) == null) return widen(&tip_buf, bv.src_buf[0..bv.src_len]);
    var b: [1024]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{s}\n{s}", .{ bv.src_buf[0..bv.src_len], i18n.t("Kliknij: wyszukaj w bazie TechPowerUp (otwiera przeglądarkę).") }) catch bv.src_buf[0..bv.src_len];
    return widen(&tip_buf, s);
}

// ---------------------------------------------------------------------------
// „Przypnij link”: dokładna strona TechPowerUp ze schowka → data\links.toml
// ---------------------------------------------------------------------------

const lookup = ferrum.sys.lookup;
extern "user32" fn OpenClipboard(?w.HWND) callconv(.winapi) w.BOOL;
extern "user32" fn CloseClipboard() callconv(.winapi) w.BOOL;
extern "user32" fn GetClipboardData(u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(?*anyopaque) callconv(.winapi) ?[*:0]const u16;
extern "kernel32" fn GlobalUnlock(?*anyopaque) callconv(.winapi) w.BOOL;

fn clipboardText(buf: []u8) []const u8 {
    if (OpenClipboard(app.hwnd) == 0) return "";
    defer _ = CloseClipboard();
    const h = GetClipboardData(13) orelse return ""; // CF_UNICODETEXT
    const p = GlobalLock(h) orelse return "";
    defer _ = GlobalUnlock(h);
    const s = std.mem.span(p);
    const n = std.unicode.utf16LeToUtf8(buf, s[0..@min(s.len, buf.len / 3)]) catch return "";
    return std.mem.trim(u8, buf[0..n], " \t\r\n");
}

fn pinFromClipboard(c: *const CellCtl) void {
    const st = app.state orelse return;
    const p = pageOfTab(c.tab) orelse return;
    const gpu = std.mem.eql(u8, forms.tabs[c.tab].id, "graphics");
    const idx = app.sel_index[c.tab];
    var mb: [128]u8 = undefined;
    var model_key: []const u8 = "";
    var pci: []const u8 = "";
    var pb: [16]u8 = undefined;
    if (gpu) {
        model_key = lookup.normalizeGpu(&mb, badgeField(p, "@GPU: {name}", "Nazwa (sterownik)", idx));
        const id = badgeField(p, "@GPU: {name}", "Identyfikator", idx);
        if (id.len == 9) pci = std.ascii.lowerString(&pb, id);
    } else {
        model_key = lookup.normalizeCpu(&mb, badgeField(p, "Procesor", "Brand string", 0));
    }
    var cb: [2048]u8 = undefined;
    const url = clipboardText(&cb);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var wb: [4096]u16 = undefined;
    var tb: [128]u16 = undefined;
    const title = widen(&tb, i18n.t("FerrumScope — przypnij link"));
    if (!lookup.validUrl(url)) {
        const msg = i18n.tf(a, "Skopiuj do schowka adres strony tego modelu (https, techpowerup.com albo strona producenta), np. z paska przeglądarki, i kliknij „Przypnij…” ponownie.\n\nModel: {model}", .{ .model = model_key });
        _ = w.MessageBoxW(app.hwnd, widen(&wb, msg), title, w.MB_OK | w.MB_ICONINFORMATION);
        return;
    }
    const msg = i18n.tf(a, "Przypiąć ten adres dla „{model}”?\n\n{url}\n\nZapis: data\\links.toml obok programu (ma pierwszeństwo przed wbudowaną tabelą).", .{ .model = model_key, .url = url });
    const MB_YESNO: u32 = 0x4;
    if (w.MessageBoxW(app.hwnd, widen(&wb, msg), title, MB_YESNO | w.MB_ICONINFORMATION) != 6) return;
    st.pinLink(if (gpu) .gpu else .cpu, model_key, pci, url) catch {
        _ = w.MessageBoxW(app.hwnd, widen(&wb, i18n.t("Nie udało się zapisać data\\links.toml.")), L("FerrumScope"), w.MB_OK | w.MB_ICONWARNING);
        return;
    };
    refreshCurrent(true);
}

// ---------------------------------------------------------------------------
// „Przypnij nazwę modelu…”: nazwa karty graficznej ze schowka → data\gpu_models.toml
// ---------------------------------------------------------------------------

fn pinModelFromClipboard(c: *const CellCtl) void {
    const st = app.state orelse return;
    const p = pageOfTab(c.tab) orelse return;
    const idx = app.sel_index[c.tab];
    const sub = badgeField(p, "@GPU: {name}", "Subsystem", idx);
    if (sub.len != 9 or sub[4] != ':') return;
    const sv = std.fmt.parseInt(u16, sub[0..4], 16) catch return;
    const sd = std.fmt.parseInt(u16, sub[5..9], 16) catch return;
    var cb: [2048]u8 = undefined;
    const clip = clipboardText(&cb);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var wb: [4096]u16 = undefined;
    var tb: [128]u16 = undefined;
    const title = widen(&tb, i18n.t("FerrumScope — przypnij nazwę modelu"));
    const name = if (std.ascii.startsWithIgnoreCase(clip, "http")) null else ferrum.sys.gpu_boards.cleanModelName(clip);
    if (name == null) {
        const msg = i18n.tf(a, "Skopiuj do schowka nazwę modelu tej karty (np. z naklejki, pudełka albo strony producenta; 1–96 znaków, bez cudzysłowu) i kliknij „Przypnij nazwę modelu…” ponownie.\n\nPodsystem: {subsys}", .{ .subsys = sub });
        _ = w.MessageBoxW(app.hwnd, widen(&wb, msg), title, w.MB_OK | w.MB_ICONINFORMATION);
        return;
    }
    const msg = i18n.tf(a, "Przypiąć nazwę „{model}” dla karty o podsystemie {subsys}?\n\nZapis: data\\gpu_models.toml obok programu (ma pierwszeństwo przed tabelą kuratorowaną i pci.ids).", .{ .model = name.?, .subsys = sub });
    const MB_YESNO: u32 = 0x4;
    if (w.MessageBoxW(app.hwnd, widen(&wb, msg), title, MB_YESNO | w.MB_ICONINFORMATION) != 6) return;
    st.pinGpuModel(sv, sd, name.?) catch {
        _ = w.MessageBoxW(app.hwnd, widen(&wb, i18n.t("Nie udało się zapisać data\\gpu_models.toml.")), L("FerrumScope"), w.MB_OK | w.MB_ICONWARNING);
        return;
    };
    refreshCurrent(true);
}

// ---------------------------------------------------------------------------
// Mapa gniazd pamięci (zakładka Pamięć): kafelek na gniazdo, grupy wg kanału
// ---------------------------------------------------------------------------

const slotmap_class = L("FerrumScopeSlotMap");
const ix_memory = forms.tabIndex("memory").?;
const max_tiles = 32;

extern "gdi32" fn CreateCompatibleBitmap(?*anyopaque, i32, i32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn BitBlt(?*anyopaque, i32, i32, i32, i32, ?*anyopaque, i32, i32, u32) callconv(.winapi) w.BOOL;
extern "gdi32" fn MoveToEx(?*anyopaque, i32, i32, ?*anyopaque) callconv(.winapi) w.BOOL;

const SM = struct {
    const caption_h: i32 = 18;
    const tile_h: i32 = 56;
    const tile_w: i32 = 118;
    const gap: i32 = 6;
    const group_gap: i32 = 18;
};

fn slotMapHeight() i32 {
    return px(SM.caption_h) + px(SM.tile_h) + px(4);
}

const Tile = struct { rect: w.RECT, slot: usize };
const Caption = struct { rect: w.RECT, channel: []const u8 };

const Geometry = struct {
    tiles: [max_tiles]Tile = undefined,
    n_tiles: usize = 0,
    caps: [max_tiles]Caption = undefined,
    n_caps: usize = 0,
};

/// Rozmieszczenie kafelków: grupy kanałów w kolejności pierwszego wystąpienia,
/// w grupie — kolejność gniazd ze strony (= kolejność struktur SMBIOS).
fn slotGeometry(slots: []const report.MemSlot, width: i32) Geometry {
    var g: Geometry = .{};
    const n = @min(slots.len, max_tiles);
    if (n == 0) return g;
    var chans: [max_tiles][]const u8 = undefined;
    var n_ch: usize = 0;
    for (slots[0..n]) |sl| {
        var seen = false;
        for (chans[0..n_ch]) |c| {
            if (std.mem.eql(u8, c, sl.channel)) seen = true;
        }
        if (!seen) {
            chans[n_ch] = sl.channel;
            n_ch += 1;
        }
    }
    const ni: i32 = @intCast(n);
    const ng: i32 = @intCast(n_ch);
    const spare = width - (ni - ng) * px(SM.gap) - (ng - 1) * px(SM.group_gap);
    const tw = @max(px(48), @min(px(SM.tile_w), @divTrunc(spare, ni)));
    var x: i32 = 0;
    const top = px(SM.caption_h);
    for (chans[0..n_ch], 0..) |ch, gi| {
        if (gi > 0) x += px(SM.group_gap) - px(SM.gap);
        const gx = x;
        for (slots[0..n], 0..) |sl, i| {
            if (!std.mem.eql(u8, sl.channel, ch)) continue;
            g.tiles[g.n_tiles] = .{ .rect = .{ .left = x, .top = top, .right = x + tw, .bottom = top + px(SM.tile_h) }, .slot = i };
            g.n_tiles += 1;
            x += tw + px(SM.gap);
        }
        if (ch.len > 0) {
            g.caps[g.n_caps] = .{ .rect = .{ .left = gx, .top = 0, .right = x - px(SM.gap), .bottom = top - px(2) }, .channel = ch };
            g.n_caps += 1;
        }
    }
    return g;
}

fn memoryPage() ?*const report.Page {
    return pageOfTab(ix_memory);
}

/// Przemalowuje mapę, gdy zmienił się wybór albo obsadzenie gniazd.
fn updateSlotMap() void {
    const p = memoryPage() orelse return;
    var sig: u64 = app.sel_index[ix_memory] | (@as(u64, p.slots.len) << 8);
    for (p.slots, 0..) |sl, i| {
        if (sl.occupied and i < 48) sig |= @as(u64, 1) << @intCast(16 + i);
    }
    if (sig == app.slot_map_sig) return;
    app.slot_map_sig = sig;
    _ = w.InvalidateRect(app.slot_map, null, 0);
}

fn slotSizeText(buf: []u8, n: u64) []const u8 {
    const gib = n / (1024 * 1024 * 1024);
    if (gib > 0) return std.fmt.bufPrint(buf, "{d} GB", .{gib}) catch "";
    return std.fmt.bufPrint(buf, "{d} MB", .{n / (1024 * 1024)}) catch "";
}

fn drawLeft(hdc: ?*anyopaque, s: []const u8, r: *w.RECT, font: ?w.HFONT, color: u32) void {
    var wb: [128]u16 = undefined;
    const p = widen(&wb, s);
    _ = SelectObject(hdc, font);
    _ = w.SetTextColor(hdc, color);
    _ = DrawTextW(hdc, p, @intCast(std.mem.len(p)), r, DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX | DT_VCENTER);
}

fn paintSlotMap(hwnd: w.HWND) void {
    var ps: PAINTSTRUCT = undefined;
    const hdc_win = BeginPaint(hwnd, &ps);
    defer _ = EndPaint(hwnd, &ps);
    badgeFonts();
    var rc: w.RECT = undefined;
    _ = w.GetClientRect(hwnd, &rc);
    // Podwójne buforowanie — mapa odświeża się razem ze stroną.
    const hdc = CreateCompatibleDC(hdc_win);
    const bmp = CreateCompatibleBitmap(hdc_win, rc.right, rc.bottom);
    const old_bmp = SelectObject(hdc, bmp);
    defer {
        _ = BitBlt(hdc_win, 0, 0, rc.right, rc.bottom, hdc, 0, 0, 0x00CC0020); // SRCCOPY
        _ = SelectObject(hdc, old_bmp);
        _ = w.DeleteObject(bmp);
        _ = DeleteDC(hdc);
    }
    _ = FillRect(hdc, &rc, w.GetSysColorBrush(w.COLOR_WINDOW));
    _ = SetBkMode(hdc, 1);
    const p = memoryPage() orelse return;
    if (p.slots.len == 0) {
        var r = rc;
        drawLeft(hdc, i18n.t("Brak danych SMBIOS typ 17 — mapa gniazd niedostępna."), &r, app.font, toneColor(.muted));
        return;
    }
    const g = slotGeometry(p.slots, rc.right);
    var arena_buf: [512]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);
    for (g.caps[0..g.n_caps]) |c| {
        fba.reset();
        var r = c.rect;
        drawLeft(hdc, i18n.tf(fba.allocator(), "Kanał {channel}", .{ .channel = c.channel }), &r, badge_font_small, toneColor(.muted));
    }
    const sel = app.sel_index[ix_memory];
    for (g.tiles[0..g.n_tiles]) |t| {
        const sl = p.slots[t.slot];
        const selected = t.slot == sel;
        const bg: u32 = if (sl.occupied) 0x00F7EFE6 else 0x00F2F2F2;
        const border: u32 = if (selected) 0x00D77800 else if (sl.occupied) 0x00B0905A else 0x00C8C8C8;
        const pen = CreatePen(0, if (selected) px(3) else 1, border);
        const br = w.CreateSolidBrush(bg);
        const op = SelectObject(hdc, pen);
        const ob = SelectObject(hdc, br);
        _ = RoundRect(hdc, t.rect.left + 1, t.rect.top + 1, t.rect.right - 1, t.rect.bottom - 1, px(8), px(8));
        _ = SelectObject(hdc, op);
        _ = SelectObject(hdc, ob);
        _ = image.DeleteObject(pen);
        _ = w.DeleteObject(br);
        const fg: u32 = if (sl.occupied) 0x00303030 else 0x00909090;
        const lh = @divTrunc(t.rect.bottom - t.rect.top - px(6), 3);
        var nb: [64]u8 = undefined;
        // Wiersz 1: etykieta i numer gniazda.
        var r1: w.RECT = .{ .left = t.rect.left + px(7), .top = t.rect.top + px(3), .right = t.rect.right - px(5), .bottom = t.rect.top + px(3) + lh };
        drawLeft(hdc, std.fmt.bufPrint(&nb, "{s}  #{d}", .{ sl.label, sl.index }) catch sl.label, &r1, badge_font_small, fg);
        // Wiersz 2: rozmiar i typ albo „pusty”.
        var r2: w.RECT = .{ .left = r1.left, .top = r1.bottom, .right = r1.right, .bottom = r1.bottom + lh };
        if (sl.occupied) {
            var sb: [32]u8 = undefined;
            const size = if (sl.size_bytes) |n| slotSizeText(&sb, n) else "?";
            drawLeft(hdc, std.fmt.bufPrint(&nb, "{s} {s}", .{ size, sl.mem_type }) catch size, &r2, app.font, fg);
        } else {
            drawLeft(hdc, i18n.t("pusty"), &r2, app.font, fg);
        }
        // Wiersz 3: producent modułu.
        var r3: w.RECT = .{ .left = r1.left, .top = r2.bottom, .right = r1.right, .bottom = r2.bottom + lh };
        if (sl.occupied) drawLeft(hdc, if (sl.vendor.len > 0) sl.vendor else sl.manufacturer, &r3, app.font, 0x00606060);
    }
}

fn slotAt(hwnd: w.HWND, x: i32, y: i32) ?usize {
    const p = memoryPage() orelse return null;
    var rc: w.RECT = undefined;
    _ = w.GetClientRect(hwnd, &rc);
    const g = slotGeometry(p.slots, rc.right);
    for (g.tiles[0..g.n_tiles]) |t| {
        if (x >= t.rect.left and x < t.rect.right and y >= t.rect.top and y < t.rect.bottom) return t.slot;
    }
    return null;
}

/// Kliknięcie kafelka = wybór w liście „Gniazdo” (obie kontrolki zsynchronizowane).
fn selectSlot(i: usize) void {
    app.sel_index[ix_memory] = i;
    if (app.sel_combo[ix_memory]) |cb| _ = w.SendMessageW(cb, w.CB_SETCURSEL, i, 0);
    refreshCurrent(true);
}

fn slotMapProc(hwnd: w.HWND, msg: u32, wp: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    const WM_PAINT: u32 = 0x000F;
    const WM_LBUTTONUP: u32 = 0x0202;
    const WM_SETCURSOR: u32 = 0x0020;
    const WM_ERASEBKGND: u32 = 0x0014;
    const WM_SIZE: u32 = 0x0005;
    switch (msg) {
        WM_PAINT => {
            paintSlotMap(hwnd);
            return 0;
        },
        WM_ERASEBKGND => return 1,
        WM_SIZE => {
            _ = w.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        WM_LBUTTONUP => {
            const lp_: usize = @bitCast(lparam);
            const x: i32 = @as(i16, @bitCast(@as(u16, @truncate(lp_))));
            const y: i32 = @as(i16, @bitCast(@as(u16, @truncate(lp_ >> 16))));
            if (slotAt(hwnd, x, y)) |i| selectSlot(i);
            return 0;
        },
        WM_SETCURSOR => {
            var pt: w.POINT = undefined;
            _ = GetCursorPos(&pt);
            _ = ScreenToClient(hwnd, &pt);
            const over = slotAt(hwnd, pt.x, pt.y) != null;
            _ = SetCursor(w.LoadCursorW(null, @ptrFromInt(@as(usize, if (over) 32649 else 32512))));
            return 1;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, msg, wp, lparam);
}

extern "user32" fn GetCursorPos(*w.POINT) callconv(.winapi) w.BOOL;
extern "user32" fn ScreenToClient(w.HWND, *w.POINT) callconv(.winapi) w.BOOL;

fn createSlotMap(inst: w.HINSTANCE) void {
    const sc: w.WNDCLASSEXW = .{ .lpfnWndProc = slotMapProc, .hInstance = inst, .lpszClassName = slotmap_class };
    _ = w.RegisterClassExW(&sc);
    app.slot_map = w.CreateWindowExW(0, slotmap_class, null, w.WS_CHILD, 0, 0, 10, 10, app.tab_panels[ix_memory] orelse app.panel, null, inst, null);
    addTip(app.slot_map);
}
