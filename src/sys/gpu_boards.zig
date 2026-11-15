//! Dokładny model karty graficznej (np. „ASRock Radeon RX 7900 XTX Phantom
//! Gaming OC”) — moduł czysty, bez Win32 i bez tłumaczeń.
//!
//! Identyfikatory PCI mówią, jaki to **układ** (1002:744C = Navi 31) i kto
//! zrobił **kartę** (podsystem 1849:xxxx = ASRock), ale nazwa konkretnej
//! wersji karty jest tylko czasem w pci.ids. Kolejność źródeł:
//!
//!   1. **nazwa przypięta przez użytkownika** — `data\gpu_models.toml` obok
//!      programu (przycisk „Przypnij nazwę modelu…” w GUI),
//!   2. **tabela kuratorowana** — `db/source/gpu_boards.toml`, wpisy ręczne
//!      (`source = "manual"`) wyłącznie na podstawie tego, co wykrycie
//!      potwierdza (podsystem i/lub numer części VBIOS),
//!   3. **nazwa podsystemu z pci.ids** — tylko gdy mówi coś więcej niż nazwa
//!      układu (np. „Radeon RX 6800 XT Phantom Gaming D”); samo „Radeon RX
//!      7900 XTX” nie jest nazwą wersji karty,
//!   4. **numer części VBIOS** — wpis tabeli kuratorowanej dopasowany tylko
//!      po przedrostku numeru części (bez podsystemu) — pewność średnia.
//!
//! Brak dopasowania = model nieznany; nic nie jest zgadywane.
//!
//! Format obu plików (podzbiór TOML, jak `lookup.zig`):
//!
//! ```toml
//! [[board]]
//! subsys = "1849:5304"          # podsystem vvvv:dddd (szesnastkowo)
//! vbios_prefix = "113-..."      # opcjonalnie: przedrostek numeru części VBIOS
//! model = "..."                 # nazwa modelu karty
//! source = "manual"             # albo "user"
//! ```

const std = @import("std");

pub const Entry = struct {
    subsys: []const u8 = "",
    vbios_prefix: []const u8 = "",
    model: []const u8 = "",
    source: []const u8 = "",
};

pub const Tables = struct {
    user: []const Entry = &.{},
    curated: []const Entry = &.{},
};

pub const Origin = enum {
    /// Przypięte przez użytkownika (`data\gpu_models.toml`).
    user,
    /// Tabela kuratorowana, dopasowanie po podsystemie I numerze części VBIOS
    /// (najmocniejszy klucz — numer części wyróżnia wersję karty).
    curated,
    /// Tabela kuratorowana, dopasowanie wyłącznie po podsystemie (ten sam
    /// podsystem bywa używany przez kilka wersji karty — niższa pewność).
    curated_subsys,
    /// Nazwa podsystemu z pci.ids (konkretniejsza niż nazwa układu).
    pciids,
    /// Tabela kuratorowana, dopasowanie wyłącznie po numerze części VBIOS.
    vbios,
};

pub const Resolved = struct {
    model: []const u8,
    origin: Origin,
};

pub const Input = struct {
    sub_vendor: u16,
    sub_device: u16,
    /// Numer części VBIOS (ADL `strPartNumber`); pusty = nieznany.
    vbios_part: []const u8 = "",
    /// Nazwa podsystemu z pci.ids (bez producenta), np. „Radeon RX 7900 XTX”.
    pciids_board: ?[]const u8 = null,
    /// Nazwy samego układu (DXGI, pci.ids urządzenia) — do oceny, czy nazwa
    /// podsystemu mówi coś więcej.
    chip_names: []const []const u8 = &.{},
};

fn subsysEql(text: []const u8, sv: u16, sd: u16) bool {
    var b: [9]u8 = undefined;
    const s = std.fmt.bufPrint(&b, "{x:0>4}:{x:0>4}", .{ sv, sd }) catch return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, text, " \t"), s);
}

fn vbiosMatch(prefix: []const u8, part: []const u8) bool {
    return prefix.len > 0 and part.len >= prefix.len and std.ascii.startsWithIgnoreCase(part, prefix);
}

const MatchKind = enum { none, both, subsys, vbios_only };

fn match(e: Entry, in: Input) MatchKind {
    if (e.model.len == 0) return .none;
    const has_sub = e.subsys.len > 0;
    const has_vb = e.vbios_prefix.len > 0;
    if (!has_sub and !has_vb) return .none;
    if (has_sub and !subsysEql(e.subsys, in.sub_vendor, in.sub_device)) return .none;
    if (has_vb and !vbiosMatch(e.vbios_prefix, in.vbios_part)) return .none;
    if (has_sub and has_vb) return .both;
    return if (has_sub) .subsys else .vbios_only;
}

/// Słowa ogólne, które nie wyróżniają wersji karty.
const generic_words = [_][]const u8{ "amd", "ati", "nvidia", "intel", "radeon", "geforce", "rx", "rtx", "gtx", "arc", "graphics", "series" };

fn isGenericWord(w: []const u8, chip_names: []const []const u8) bool {
    for (generic_words) |g| if (std.ascii.eqlIgnoreCase(w, g)) return true;
    for (chip_names) |n| {
        var it = std.mem.tokenizeAny(u8, n, " /[]()-_,");
        while (it.next()) |cw| if (std.ascii.eqlIgnoreCase(w, cw)) return true;
        // „7900XTX” w nazwie układu, „7900 XTX” w nazwie podsystemu (i odwrotnie).
        if (w.len >= 2 and std.ascii.indexOfIgnoreCase(n, w) != null) return true;
    }
    return false;
}

/// Czy nazwa podsystemu z pci.ids mówi coś więcej niż nazwa układu
/// (np. „Phantom Gaming”, „Nitro+”, „TUF”). „Radeon RX 7900 XTX” → nie.
pub fn isSpecificBoardName(board: []const u8, chip_names: []const []const u8) bool {
    var it = std.mem.tokenizeAny(u8, board, " /[]()-_,");
    while (it.next()) |w| {
        if (!isGenericWord(w, chip_names)) return true;
    }
    return false;
}

/// Model karty: przypięty > kuratorowany (podsystem) > pci.ids > VBIOS.
pub fn resolve(t: Tables, in: Input) ?Resolved {
    for (t.user) |e| if (match(e, in) != .none) return .{ .model = e.model, .origin = .user };
    var vbios_hit: ?[]const u8 = null;
    var subsys_hit: ?[]const u8 = null;
    for (t.curated) |e| switch (match(e, in)) {
        // Podsystem + VBIOS wygrywa niezależnie od kolejności wpisów.
        .both => return .{ .model = e.model, .origin = .curated },
        .subsys => if (subsys_hit == null) {
            subsys_hit = e.model;
        },
        .vbios_only => if (vbios_hit == null) {
            vbios_hit = e.model;
        },
        .none => {},
    };
    if (subsys_hit) |m| return .{ .model = m, .origin = .curated_subsys };
    if (in.pciids_board) |b| if (isSpecificBoardName(b, in.chip_names)) return .{ .model = b, .origin = .pciids };
    if (vbios_hit) |m| return .{ .model = m, .origin = .vbios };
    return null;
}

// ---------------------------------------------------------------------------
// Parser i zapis
// ---------------------------------------------------------------------------

pub const ParseError = error{ Malformed, OutOfMemory };

/// Parsuje `[[board]]` z kluczami `subsys`, `vbios_prefix`, `model`, `source`.
/// Nieznane klucze są pomijane; wpisy bez `model` albo bez obu kluczy
/// dopasowania są odrzucane.
pub fn parse(alloc: std.mem.Allocator, text: []const u8) ParseError![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    var cur: ?Entry = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.eql(u8, line, "[[board]]")) {
            if (cur) |e| if (valid(e)) try list.append(alloc, e);
            cur = .{};
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
        if (std.mem.eql(u8, key, "subsys")) e.subsys = v else if (std.mem.eql(u8, key, "vbios_prefix")) e.vbios_prefix = v else if (std.mem.eql(u8, key, "model")) e.model = v else if (std.mem.eql(u8, key, "source")) e.source = v;
    }
    if (cur) |e| if (valid(e)) try list.append(alloc, e);
    return list.toOwnedSlice(alloc);
}

fn valid(e: Entry) bool {
    return e.model.len > 0 and (e.subsys.len > 0 or e.vbios_prefix.len > 0);
}

/// Nazwa modelu wpisana przez użytkownika: przycięta, 1..96 znaków, bez
/// znaków sterujących, cudzysłowu i ukośnika wstecznego (zapis TOML bez
/// sekwencji ucieczki). `null` = odrzucona.
pub fn cleanModelName(raw: []const u8) ?[]const u8 {
    const s = std.mem.trim(u8, raw, " \t\r\n");
    if (s.len == 0 or s.len > 96) return null;
    for (s) |c| if (c < 0x20 or c == 0x7F or c == '"' or c == '\\') return null;
    if (!std.unicode.utf8ValidateSlice(s)) return null;
    return s;
}

/// Nowa treść `data\gpu_models.toml` po przypięciu nazwy dla podsystemu
/// (zastępuje wcześniejszy wpis użytkownika dla tego podsystemu).
pub fn withPinned(alloc: std.mem.Allocator, existing: []const Entry, sub_vendor: u16, sub_device: u16, model: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("# FerrumScope — nazwy modeli kart graficznych przypięte przez użytkownika\n# (pierwszeństwo przed tabelą kuratorowaną i pci.ids).\n");
    for (existing) |x| {
        if (x.vbios_prefix.len == 0 and subsysEql(x.subsys, sub_vendor, sub_device)) continue;
        try writeEntry(w, x);
    }
    var b: [9]u8 = undefined;
    const sub = try std.fmt.bufPrint(&b, "{x:0>4}:{x:0>4}", .{ sub_vendor, sub_device });
    try writeEntry(w, .{ .subsys = sub, .model = model, .source = "user" });
    return out.toOwnedSlice();
}

fn writeEntry(w: *std.Io.Writer, e: Entry) !void {
    try w.writeAll("\n[[board]]\n");
    if (e.subsys.len > 0) try w.print("subsys = \"{s}\"\n", .{e.subsys});
    if (e.vbios_prefix.len > 0) try w.print("vbios_prefix = \"{s}\"\n", .{e.vbios_prefix});
    try w.print("model = \"{s}\"\nsource = \"{s}\"\n", .{ e.model, if (e.source.len > 0) e.source else "user" });
}

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

const testing = std.testing;

test "gpu_boards: nazwa podsystemu pci.ids — konkretna czy tylko nazwa układu" {
    const chips = [_][]const u8{ "AMD Radeon RX 7900 XTX", "Navi 31 [Radeon RX 7900 XT/7900 XTX/7900 GRE/7900M]" };
    try testing.expect(!isSpecificBoardName("Radeon RX 7900 XTX", &chips));
    try testing.expect(!isSpecificBoardName("Navi 31 [Radeon RX 7900 XTX]", &chips));
    try testing.expect(isSpecificBoardName("Radeon RX 7900 XTX Phantom Gaming OC", &chips));
    const nv = [_][]const u8{ "NVIDIA GeForce RTX 4090", "AD102 [GeForce RTX 4090]" };
    try testing.expect(isSpecificBoardName("GeForce RTX 4090 TUF Gaming OC", &nv));
    try testing.expect(!isSpecificBoardName("GeForce RTX 4090", &nv));
}

test "gpu_boards: kolejność — użytkownik, kuratorowany, pci.ids, VBIOS" {
    const chips = [_][]const u8{"AMD Radeon RX 7900 XTX"};
    const in: Input = .{ .sub_vendor = 0x1849, .sub_device = 0x5304, .vbios_part = "113-D7020100-102", .pciids_board = "Radeon RX 7900 XTX", .chip_names = &chips };
    // Nic nie pasuje: pci.ids to tylko nazwa układu → model nieznany.
    try testing.expect(resolve(.{}, in) == null);

    const vb_only = [_]Entry{.{ .vbios_prefix = "113-D702", .model = "Model z VBIOS", .source = "manual" }};
    const r1 = resolve(.{ .curated = &vb_only }, in).?;
    try testing.expectEqual(Origin.vbios, r1.origin);

    var in2 = in;
    in2.pciids_board = "Radeon RX 7900 XTX Phantom Gaming";
    try testing.expectEqual(Origin.pciids, resolve(.{ .curated = &vb_only }, in2).?.origin);

    const cur = [_]Entry{
        .{ .subsys = "1849:5304", .vbios_prefix = "113-XXXX", .model = "Inny BIOS", .source = "manual" },
        .{ .subsys = "1849:5304", .model = "Model kuratorowany", .source = "manual" },
    };
    const r2 = resolve(.{ .curated = &cur }, in2).?;
    try testing.expectEqual(Origin.curated_subsys, r2.origin);
    try testing.expectEqualStrings("Model kuratorowany", r2.model);

    const user = [_]Entry{.{ .subsys = "1849:5304", .model = "Moja karta", .source = "user" }};
    const r3 = resolve(.{ .user = &user, .curated = &cur }, in2).?;
    try testing.expectEqual(Origin.user, r3.origin);
    try testing.expectEqualStrings("Moja karta", r3.model);

    // Inny podsystem — wpis nie pasuje.
    var in3 = in;
    in3.sub_device = 0x5305;
    try testing.expect(resolve(.{ .user = &user, .curated = &cur }, in3) == null);
}

test "gpu_boards: parser, zapis przypięcia i walidacja nazwy" {
    const text =
        \\# komentarz
        \\[[board]]
        \\subsys = "1849:5304"
        \\model = "A"
        \\source = "user"
        \\
        \\[[board]]
        \\model = "bez klucza dopasowania"
        \\
        \\[[board]]
        \\vbios_prefix = "113-ABC"
        \\model = "B"
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const es = try parse(arena.allocator(), text);
    try testing.expectEqual(@as(usize, 2), es.len);
    try testing.expectEqualStrings("1849:5304", es[0].subsys);
    try testing.expectEqualStrings("113-ABC", es[1].vbios_prefix);
    try testing.expectError(error.Malformed, parse(arena.allocator(), "[[board]]\nmodel = bez cudzysłowu\n"));

    const out = try withPinned(testing.allocator, es, 0x1849, 0x5304, "Nowa nazwa");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "model = \"A\"") == null);
    try testing.expect(std.mem.indexOf(u8, out, "model = \"Nowa nazwa\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "model = \"B\"") != null);

    try testing.expectEqualStrings("Radeon RX 7900 XTX Phantom Gaming", cleanModelName("  Radeon RX 7900 XTX Phantom Gaming \r\n").?);
    try testing.expect(cleanModelName("") == null);
    try testing.expect(cleanModelName("a\"b") == null);
    try testing.expect(cleanModelName("a\nb") == null);
}

test "gpu_boards: karta właściciela — VBIOS + podsystem wygrywa, sam podsystem ma niższą pewność" {
    const cur = [_]Entry{
        .{ .subsys = "1849:5304", .model = "ASRock Radeon RX 7900 XTX Phantom Gaming 24GB OC", .source = "user-confirmed (owner's card label)" },
        .{ .subsys = "1849:5304", .vbios_prefix = "113-D70201-810009", .model = "ASRock Radeon RX 7900 XTX Phantom Gaming 24GB OC", .source = "user-confirmed (owner's card label)" },
    };
    const with_vbios = resolve(.{ .curated = &cur }, .{ .sub_vendor = 0x1849, .sub_device = 0x5304, .vbios_part = "113-D70201-810009" }).?;
    try testing.expectEqual(Origin.curated, with_vbios.origin);
    const sub_only = resolve(.{ .curated = &cur }, .{ .sub_vendor = 0x1849, .sub_device = 0x5304 }).?;
    try testing.expectEqual(Origin.curated_subsys, sub_only.origin);
    try testing.expectEqualStrings("ASRock Radeon RX 7900 XTX Phantom Gaming 24GB OC", sub_only.model);
}
