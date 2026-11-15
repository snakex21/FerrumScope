//! Ustawienia programu przenośnego: `data\settings.ini` obok programu.
//!
//! Katalog `data\` należy do użytkownika (ustawienia, przypięte linki,
//! własne obrazy) i jest zachowywany przy aktualizacji programu.
//!
//! Format: `klucz = wartość` w linii, `#` = komentarz. Nieznane klucze są
//! zachowywane przy zapisie (zgodność w przód).

const std = @import("std");

/// Kanał aktualizacji: `stable` = tylko wydania, `test` = także pre-release.
pub const UpdateChannel = enum {
    stable,
    @"test",

    pub fn parse(v: []const u8) ?UpdateChannel {
        if (std.mem.eql(u8, v, "stable")) return .stable;
        if (std.mem.eql(u8, v, "test")) return .@"test";
        return null;
    }
};

pub const Settings = struct {
    /// Kod języka (np. `pl`, `en`, `pt-BR`); pusty = automatycznie.
    language: []const u8 = "",
    /// Sprawdzanie aktualizacji przy starcie (najwyżej raz na dobę).
    update_check: bool = true,
    /// Czas ostatniego sprawdzenia (sekundy UNIX), 0 = nigdy.
    last_update_check: i64 = 0,
    /// Kanał aktualizacji (`stable` / `test`); nieznana wartość = `stable`.
    update_channel: UpdateChannel = .stable,
    /// Widok „Pełna lista” w GUI.
    list_view: bool = false,
};

pub fn dataDir(buf: []u8) ?[]const u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = std.fs.selfExeDirPath(&dir_buf) catch return null;
    return std.fmt.bufPrint(buf, "{s}{c}data", .{ dir, std.fs.path.sep }) catch null;
}

pub fn path(buf: []u8) ?[]const u8 {
    var d: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dataDir(&d) orelse return null;
    return std.fmt.bufPrint(buf, "{s}{c}settings.ini", .{ dir, std.fs.path.sep }) catch null;
}

/// Parsuje tekst ustawień; napisy wskazują w `text` (musi żyć dłużej niż wynik).
pub fn parse(text: []const u8) Settings {
    var s: Settings = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (std.mem.eql(u8, k, "language")) {
            s.language = v;
        } else if (std.mem.eql(u8, k, "update_check")) {
            s.update_check = !(std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0"));
        } else if (std.mem.eql(u8, k, "last_update_check")) {
            s.last_update_check = std.fmt.parseInt(i64, v, 10) catch 0;
        } else if (std.mem.eql(u8, k, "update_channel")) {
            s.update_channel = UpdateChannel.parse(v) orelse .stable;
        } else if (std.mem.eql(u8, k, "list_view")) {
            s.list_view = std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1");
        }
    }
    return s;
}

pub fn write(w: *std.Io.Writer, s: Settings) !void {
    try w.writeAll("# FerrumScope — ustawienia (data\\settings.ini)\n");
    try w.print("language = {s}\nupdate_check = {}\nlast_update_check = {d}\nupdate_channel = {s}\nlist_view = {}\n", .{
        s.language, s.update_check, s.last_update_check, @tagName(s.update_channel), s.list_view,
    });
}

/// Stan wczytany z dysku (tekst trzymany w buforze statycznym — jeden proces, jeden plik).
var file_buf: [8 * 1024]u8 = undefined;
var lang_buf: [32]u8 = undefined;

pub fn load() Settings {
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const p = path(&pb) orelse return .{};
    const f = std.fs.cwd().openFile(p, .{}) catch return .{};
    defer f.close();
    const n = f.readAll(&file_buf) catch return .{};
    var s = parse(file_buf[0..n]);
    const l = @min(s.language.len, lang_buf.len);
    @memcpy(lang_buf[0..l], s.language[0..l]);
    s.language = lang_buf[0..l];
    return s;
}

pub fn save(s: Settings) !void {
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const p = path(&pb) orelse return error.NoPath;
    if (std.fs.path.dirname(p)) |d| try std.fs.cwd().makePath(d);
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();
    try write(&out.writer, s);
    try std.fs.cwd().writeFile(.{ .sub_path = p, .data = out.written() });
}

test "settings: zapis i odczyt" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{ .language = "pt-BR", .update_check = false, .last_update_check = 1763200000, .list_view = true });
    const s = parse(out.written());
    try std.testing.expectEqualStrings("pt-BR", s.language);
    try std.testing.expect(!s.update_check);
    try std.testing.expectEqual(@as(i64, 1763200000), s.last_update_check);
    try std.testing.expect(s.list_view);
    const d = parse("# pusty\nnieznany = 1\n");
    try std.testing.expect(d.update_check);
    try std.testing.expectEqualStrings("", d.language);
    try std.testing.expectEqual(UpdateChannel.stable, d.update_channel);
}

test "settings: kanał aktualizacji" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, .{ .update_channel = .@"test" });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "update_channel = test\n") != null);
    try std.testing.expectEqual(UpdateChannel.@"test", parse(out.written()).update_channel);
    try std.testing.expectEqual(UpdateChannel.stable, parse("update_channel = stable\n").update_channel);
    // Nieznana wartość = stabilny (bezpieczniej niż przypadkowe wersje testowe).
    try std.testing.expectEqual(UpdateChannel.stable, parse("update_channel = beta\n").update_channel);
}
