//! Wspólny model prezentacji: strona -> sekcje -> pola.
//!
//! Każde pole niesie **wartość zinterpretowaną**, opcjonalnie **surową**
//! (np. `0x744C`, bajty z tabeli SMBIOS), **źródło** (skąd dokładnie pochodzi)
//! i **pewność**. To jest wyróżnik FerrumScope: użytkownik zawsze widzi, czy
//! liczba jest odczytem sprzętu, wpisem bazy, czy oszacowaniem.
//!
//! Ten sam model zasila GUI (lista z grupami), CLI (tekst) i eksport
//! (TXT / HTML / JSON). Dzięki temu okno i raport nie mogą się rozjechać.
//!
//! Numery seryjne, UUID i podobne dane są oznaczane `sensitive = true`
//! i domyślnie **maskowane** w raportach (`ExportOptions.include_serials`).

const std = @import("std");
const model = @import("../core/model.zig");

pub const Confidence = model.Confidence;

/// Stan pola. `ok` to odczyt; pozostałe mówią, **dlaczego** wartości nie ma
/// albo dlaczego jest tylko przybliżeniem.
pub const State = enum {
    ok,
    /// Wartość szacowana (np. zegar CPU z licznika wydajności).
    estimate,
    /// Odczyt nie dał wartości; powód jest w polu `source`/`note`.
    unavailable,
    /// Wymaga uprawnień administratora (program działa dalej bez nich).
    requires_admin,
    /// Wymaga sterownika jądra (planowane, celowo niezaimplementowane).
    requires_driver,
    /// Firmware wpisał zaślepkę („To Be Filled By O.E.M.”, „Default string”).
    placeholder,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .ok => "ok",
            .estimate => "oszacowanie",
            .unavailable => "niedostępne",
            .requires_admin => "wymaga administratora",
            .requires_driver => "wymaga sterownika (planowane)",
            .placeholder => "zaślepka firmware",
        };
    }

    pub fn isValue(self: State) bool {
        return self == .ok or self == .estimate or self == .placeholder;
    }
};

pub const Field = struct {
    label: []const u8,
    value: []const u8,
    /// Surowa postać (hex, bajty, liczba przed przeliczeniem). Pusta = brak.
    raw: []const u8 = "",
    /// Skąd pochodzi wartość — konkretnie (np. „SMBIOS typ 2, offset 05h”).
    source: []const u8 = "",
    confidence: Confidence = .high,
    state: State = .ok,
    /// Numer seryjny / UUID / tag — maskowany w raportach domyślnie.
    sensitive: bool = false,
    /// Dodatkowa uwaga (np. dlaczego heurystyka).
    note: []const u8 = "",
};

pub const Link = struct {
    label: []const u8,
    url: []const u8,
    /// Krótki opis do raportu („wyszukiwanie po nazwie”, „po ID urządzenia”).
    note: []const u8 = "",
};

pub const Section = struct {
    title: []const u8,
    fields: std.ArrayList(Field) = .empty,
};

pub const Page = struct {
    id: []const u8,
    title: []const u8,
    /// Nagłówek strony (np. nazwa CPU / model płyty).
    headline: []const u8 = "",
    /// Linijka opisu pod nagłówkiem.
    summary: []const u8 = "",
    sections: std.ArrayList(Section) = .empty,
    links: std.ArrayList(Link) = .empty,

    pub fn fieldCount(self: *const Page) usize {
        var n: usize = 0;
        for (self.sections.items) |s| n += s.fields.items.len;
        return n;
    }
};

/// Pomocnik do budowania strony. Wszystkie napisy żyją w `arena`.
pub const Builder = struct {
    arena: std.mem.Allocator,
    page: *Page,

    pub fn init(arena: std.mem.Allocator, page: *Page) Builder {
        return .{ .arena = arena, .page = page };
    }

    pub fn section(self: *Builder, title: []const u8) void {
        self.page.sections.append(self.arena, .{ .title = title }) catch {};
    }

    pub fn add(self: *Builder, f: Field) void {
        if (self.page.sections.items.len == 0) self.section("Ogólne");
        const s = &self.page.sections.items[self.page.sections.items.len - 1];
        s.fields.append(self.arena, f) catch {};
    }

    pub fn link(self: *Builder, l: Link) void {
        self.page.links.append(self.arena, l) catch {};
    }

    /// Formatowanie do areny; przy braku pamięci zwraca stały tekst zamiast
    /// propagować błąd — brak jednej etykiety nie może zatrzymać raportu.
    pub fn fmt(self: *Builder, comptime f: []const u8, args: anytype) []const u8 {
        return std.fmt.allocPrint(self.arena, f, args) catch "(brak pamięci)";
    }

    pub fn dup(self: *Builder, s: []const u8) []const u8 {
        return self.arena.dupe(u8, s) catch "(brak pamięci)";
    }
};

pub const Report = struct {
    title: []const u8 = "FerrumScope",
    version: []const u8 = "",
    generated: []const u8 = "",
    pages: []const Page,
};

pub const ExportOptions = struct {
    include_serials: bool = false,
};

// ---------------------------------------------------------------------------
// Maskowanie
// ---------------------------------------------------------------------------

/// Maskuje numer seryjny: zostawia 2 pierwsze i 2 ostatnie znaki, resztę
/// zastępuje `*`. Krótkie (≤ 10) maskuje w całości — z 4 jawnych znaków
/// krótkiego numeru dałoby się go odtworzyć.
pub fn mask(value: []const u8, buf: []u8) []const u8 {
    const v = std.mem.trim(u8, value, " ");
    if (v.len == 0) return v;
    const n = @min(v.len, buf.len);
    if (v.len <= 10) {
        @memset(buf[0..n], '*');
        return buf[0..n];
    }
    @memcpy(buf[0..n], v[0..n]);
    for (buf[2 .. n - 2]) |*c| c.* = '*';
    return buf[0..n];
}

/// Wartość do pokazania w raporcie z uwzględnieniem opcji maskowania.
pub fn shownValue(f: Field, opts: ExportOptions, buf: []u8) []const u8 {
    if (f.sensitive and !opts.include_serials and f.state == .ok) return mask(f.value, buf);
    return f.value;
}

pub fn shownRaw(f: Field, opts: ExportOptions) []const u8 {
    if (f.sensitive and !opts.include_serials) return "";
    return f.raw;
}

// ---------------------------------------------------------------------------
// Eksport TXT
// ---------------------------------------------------------------------------

fn pad(w: *std.Io.Writer, s: []const u8, width: usize) !void {
    try w.writeAll(s);
    const len = std.unicode.utf8CountCodepoints(s) catch s.len;
    var i = len;
    while (i < width) : (i += 1) try w.writeByte(' ');
}

pub fn writePageText(w: *std.Io.Writer, p: *const Page, opts: ExportOptions) !void {
    try w.print("== {s} ==\n", .{p.title});
    if (p.headline.len > 0) try w.print("{s}\n", .{p.headline});
    if (p.summary.len > 0) try w.print("{s}\n", .{p.summary});
    for (p.sections.items) |s| {
        try w.print("\n[{s}]\n", .{s.title});
        for (s.fields.items) |f| {
            var mb: [256]u8 = undefined;
            try w.writeAll("  ");
            try pad(w, f.label, 28);
            try w.writeByte(' ');
            try w.writeAll(shownValue(f, opts, &mb));
            if (f.state != .ok) try w.print("  <{s}>", .{f.state.label()});
            try w.writeByte('\n');
            const raw = shownRaw(f, opts);
            if (raw.len > 0 or f.source.len > 0) {
                try w.writeAll("      ");
                if (raw.len > 0) try w.print("raw={s}  ", .{raw});
                if (f.source.len > 0) try w.print("źródło: {s}", .{f.source});
                try w.print("  [pewność: {s}]", .{f.confidence.toSlice()});
                try w.writeByte('\n');
            }
            if (f.note.len > 0) try w.print("      uwaga: {s}\n", .{f.note});
        }
    }
    if (p.links.items.len > 0) {
        try w.writeAll("\n[Odnośniki]\n");
        for (p.links.items) |l| try w.print("  {s}: {s}\n", .{ l.label, l.url });
    }
    try w.writeByte('\n');
}

pub fn writeText(w: *std.Io.Writer, r: Report, opts: ExportOptions) !void {
    try w.print("{s} {s} — raport sprzętu\n", .{ r.title, r.version });
    if (r.generated.len > 0) try w.print("Wygenerowano: {s}\n", .{r.generated});
    try w.print("Numery seryjne: {s}\n\n", .{if (opts.include_serials) "JAWNE (na życzenie)" else "zamaskowane"});
    for (r.pages) |*p| try writePageText(w, p, opts);
}

// ---------------------------------------------------------------------------
// Eksport JSON
// ---------------------------------------------------------------------------

pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...8, 11, 12, 14...0x1F, 0x7F => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

pub fn writeJson(w: *std.Io.Writer, r: Report, opts: ExportOptions) !void {
    try w.writeAll("{\n  \"tool\": ");
    try writeJsonString(w, r.title);
    try w.writeAll(",\n  \"version\": ");
    try writeJsonString(w, r.version);
    try w.writeAll(",\n  \"generated\": ");
    try writeJsonString(w, r.generated);
    try w.print(",\n  \"serials_included\": {},\n  \"pages\": [", .{opts.include_serials});
    for (r.pages, 0..) |*p, pi| {
        if (pi > 0) try w.writeByte(',');
        try w.writeAll("\n    {\"id\": ");
        try writeJsonString(w, p.id);
        try w.writeAll(", \"title\": ");
        try writeJsonString(w, p.title);
        try w.writeAll(", \"headline\": ");
        try writeJsonString(w, p.headline);
        try w.writeAll(", \"summary\": ");
        try writeJsonString(w, p.summary);
        try w.writeAll(",\n     \"sections\": [");
        for (p.sections.items, 0..) |s, si| {
            if (si > 0) try w.writeByte(',');
            try w.writeAll("\n      {\"title\": ");
            try writeJsonString(w, s.title);
            try w.writeAll(", \"fields\": [");
            for (s.fields.items, 0..) |f, fi| {
                var mb: [256]u8 = undefined;
                if (fi > 0) try w.writeByte(',');
                try w.writeAll("\n        {\"label\": ");
                try writeJsonString(w, f.label);
                try w.writeAll(", \"value\": ");
                try writeJsonString(w, shownValue(f, opts, &mb));
                try w.writeAll(", \"raw\": ");
                try writeJsonString(w, shownRaw(f, opts));
                try w.writeAll(", \"source\": ");
                try writeJsonString(w, f.source);
                try w.print(", \"confidence\": \"{s}\", \"state\": \"{s}\", \"sensitive\": {}", .{
                    f.confidence.toSlice(), @tagName(f.state), f.sensitive,
                });
                if (f.sensitive and !opts.include_serials) try w.writeAll(", \"masked\": true");
                if (f.note.len > 0) {
                    try w.writeAll(", \"note\": ");
                    try writeJsonString(w, f.note);
                }
                try w.writeByte('}');
            }
            try w.writeAll("]}");
        }
        try w.writeAll("],\n     \"links\": [");
        for (p.links.items, 0..) |l, li| {
            if (li > 0) try w.writeAll(", ");
            try w.writeAll("{\"label\": ");
            try writeJsonString(w, l.label);
            try w.writeAll(", \"url\": ");
            try writeJsonString(w, l.url);
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
    try w.writeAll("\n  ]\n}\n");
}

// ---------------------------------------------------------------------------
// Eksport HTML (samowystarczalny plik, bez zewnętrznych zasobów)
// ---------------------------------------------------------------------------

pub fn writeHtmlEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(c),
    };
}

const html_head =
    \\<!doctype html>
    \\<html lang="pl"><head><meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>FerrumScope — raport sprzętu</title>
    \\<style>
    \\:root{--bg:#fff;--fg:#1d1d1f;--muted:#6e6e73;--line:#e5e5ea;--head:#f5f5f7;--ok:#107c10;--warn:#b45a00}
    \\@media (prefers-color-scheme: dark){:root{--bg:#1c1c1e;--fg:#f2f2f7;--muted:#a1a1a6;--line:#38383a;--head:#2c2c2e;--ok:#4cd964;--warn:#ffb340}}
    \\body{background:var(--bg);color:var(--fg);font:14px/1.45 "Segoe UI",system-ui,sans-serif;margin:0 auto;max-width:1100px;padding:16px}
    \\h1{font-size:22px;margin:0 0 4px}h2{font-size:18px;margin:28px 0 4px;border-bottom:2px solid var(--line);padding-bottom:4px}
    \\h3{font-size:14px;margin:14px 0 4px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
    \\.meta,.src,.raw{color:var(--muted)}.raw{font-family:Consolas,monospace;font-size:12px}
    \\table{border-collapse:collapse;width:100%;table-layout:fixed}td{border-top:1px solid var(--line);padding:4px 6px;vertical-align:top;overflow-wrap:anywhere}
    \\td.l{width:26%}td.v{width:38%}td.s{font-size:12px}
    \\.st{font-size:11px;padding:1px 6px;border-radius:8px;border:1px solid var(--warn);color:var(--warn);margin-left:6px;white-space:nowrap}
    \\.c-high{color:var(--ok)}.c-low,.c-unknown{color:var(--warn)}
    \\nav a{margin-right:12px}
    \\@media (max-width:640px){td.l,td.v{width:auto}table,tbody,tr,td{display:block}td{border:0;padding:2px 0}tr{border-top:1px solid var(--line);padding:6px 0}}
    \\</style></head><body>
    \\
;

pub fn writeHtml(w: *std.Io.Writer, r: Report, opts: ExportOptions) !void {
    try w.writeAll(html_head);
    try w.writeAll("<h1>");
    try writeHtmlEscaped(w, r.title);
    try w.writeAll(" ");
    try writeHtmlEscaped(w, r.version);
    try w.writeAll(" — raport sprzętu</h1>\n<p class=\"meta\">");
    if (r.generated.len > 0) {
        try w.writeAll("Wygenerowano: ");
        try writeHtmlEscaped(w, r.generated);
        try w.writeAll(" · ");
    }
    try w.print("Numery seryjne: {s}</p>\n<nav>", .{if (opts.include_serials) "jawne (na życzenie)" else "zamaskowane"});
    for (r.pages) |*p| {
        try w.writeAll("<a href=\"#");
        try writeHtmlEscaped(w, p.id);
        try w.writeAll("\">");
        try writeHtmlEscaped(w, p.title);
        try w.writeAll("</a>");
    }
    try w.writeAll("</nav>\n");
    for (r.pages) |*p| {
        try w.writeAll("<h2 id=\"");
        try writeHtmlEscaped(w, p.id);
        try w.writeAll("\">");
        try writeHtmlEscaped(w, p.title);
        try w.writeAll("</h2>\n");
        if (p.headline.len > 0) {
            try w.writeAll("<p><b>");
            try writeHtmlEscaped(w, p.headline);
            try w.writeAll("</b></p>\n");
        }
        if (p.summary.len > 0) {
            try w.writeAll("<p class=\"meta\">");
            try writeHtmlEscaped(w, p.summary);
            try w.writeAll("</p>\n");
        }
        for (p.sections.items) |s| {
            try w.writeAll("<h3>");
            try writeHtmlEscaped(w, s.title);
            try w.writeAll("</h3>\n<table>\n");
            for (s.fields.items) |f| {
                var mb: [256]u8 = undefined;
                try w.writeAll("<tr><td class=\"l\">");
                try writeHtmlEscaped(w, f.label);
                try w.writeAll("</td><td class=\"v\">");
                try writeHtmlEscaped(w, shownValue(f, opts, &mb));
                if (f.state != .ok) {
                    try w.writeAll("<span class=\"st\">");
                    try writeHtmlEscaped(w, f.state.label());
                    try w.writeAll("</span>");
                }
                const raw = shownRaw(f, opts);
                if (raw.len > 0) {
                    try w.writeAll("<br><span class=\"raw\">raw ");
                    try writeHtmlEscaped(w, raw);
                    try w.writeAll("</span>");
                }
                try w.writeAll("</td><td class=\"s\"><span class=\"src\">");
                try writeHtmlEscaped(w, f.source);
                try w.print("</span> <span class=\"c-{s}\">[{s}]</span>", .{ f.confidence.toSlice(), f.confidence.toSlice() });
                if (f.note.len > 0) {
                    try w.writeAll("<br><span class=\"src\">");
                    try writeHtmlEscaped(w, f.note);
                    try w.writeAll("</span>");
                }
                try w.writeAll("</td></tr>\n");
            }
            try w.writeAll("</table>\n");
        }
        if (p.links.items.len > 0) {
            try w.writeAll("<h3>Odnośniki</h3><ul>\n");
            for (p.links.items) |l| {
                try w.writeAll("<li><a rel=\"noopener noreferrer\" href=\"");
                try writeHtmlEscaped(w, l.url);
                try w.writeAll("\">");
                try writeHtmlEscaped(w, l.label);
                try w.writeAll("</a></li>\n");
            }
            try w.writeAll("</ul>\n");
        }
    }
    try w.writeAll("<p class=\"meta\">FerrumScope — GPL-3.0. Nazwy urządzeń PCI: PCI ID Repository (pci-ids.ucw.cz).</p>\n</body></html>\n");
}

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

const testing = std.testing;

fn samplePage(arena: std.mem.Allocator) !Page {
    var p: Page = .{ .id = "board", .title = "Płyta główna", .headline = "ACME X1 <rev>" };
    var b = Builder.init(arena, &p);
    b.section("Płyta");
    b.add(.{ .label = "Producent", .value = "ACME \"Inc\"", .raw = "", .source = "SMBIOS typ 2, offset 04h" });
    b.add(.{ .label = "Numer seryjny", .value = "ABCD1234567", .source = "SMBIOS typ 2, offset 07h", .sensitive = true, .raw = "ABCD1234567" });
    b.add(.{ .label = "Wentylatory", .value = "—", .state = .requires_driver, .confidence = .unknown });
    b.link(.{ .label = "Szukaj", .url = "https://example.invalid/?q=a&b=c" });
    return p;
}

test "report: maskowanie numerów seryjnych" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("AB*******67", mask("ABCD1234567", &buf));
    try testing.expectEqualStrings("******", mask("ABC123", &buf));
    try testing.expectEqualStrings("", mask("   ", &buf));
}

test "report: TXT maskuje serial domyślnie i pokazuje go na życzenie" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try samplePage(arena);
    const pages = [_]Page{p};
    const r = Report{ .version = "t", .pages = &pages };

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeText(&out.writer, r, .{});
    const masked = out.written();
    try testing.expect(std.mem.indexOf(u8, masked, "ABCD1234567") == null);
    try testing.expect(std.mem.indexOf(u8, masked, "AB*******67") != null);
    try testing.expect(std.mem.indexOf(u8, masked, "wymaga sterownika") != null);

    var out2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out2.deinit();
    try writeText(&out2.writer, r, .{ .include_serials = true });
    try testing.expect(std.mem.indexOf(u8, out2.written(), "ABCD1234567") != null);
}

test "report: JSON jest poprawny i maskuje serial" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try samplePage(arena);
    const pages = [_]Page{p};
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeJson(&out.writer, .{ .version = "t", .pages = &pages }, .{});
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, out.written(), .{});
    defer parsed.deinit();
    try testing.expect(std.mem.indexOf(u8, out.written(), "ABCD1234567") == null);
    const fields = parsed.value.object.get("pages").?.array.items[0].object.get("sections").?.array.items[0].object.get("fields").?.array.items;
    try testing.expectEqualStrings("ACME \"Inc\"", fields[0].object.get("value").?.string);
    try testing.expect(fields[1].object.get("masked").?.bool);
}

test "report: HTML escapuje treść i nie zawiera seriala" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = try samplePage(arena);
    const pages = [_]Page{p};
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try writeHtml(&out.writer, .{ .version = "t", .pages = &pages }, .{});
    const h = out.written();
    try testing.expect(std.mem.indexOf(u8, h, "ACME X1 &lt;rev&gt;") != null);
    try testing.expect(std.mem.indexOf(u8, h, "a&amp;b=c") != null);
    try testing.expect(std.mem.indexOf(u8, h, "ABCD1234567") == null);
}
