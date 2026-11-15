//! Instalacja aktualizacji: weryfikacja, rozpakowanie, podmiana plików,
//! wycofanie i przywracanie kopii.
//!
//! Przebieg (dwie fazy, żeby przerwanie w trakcie pobierania niczego nie psuło):
//!
//!  1. `prepare` — pobiera archiwum i `SHA256SUMS` do **nowego** katalogu
//!     roboczego `<katalog programu>\.ferrumscope-update\`, sprawdza rozmiar
//!     i SHA-256 względem manifestu **oraz** względem `SHA256SUMS` (obie sumy
//!     muszą się zgadzać), po czym rozpakowuje wyłącznie pliki z listy
//!     `managed_files` do `...\files\`. Ścieżki z `..`, `\`, `:` albo
//!     zaczynające się od `/` odrzucają całe archiwum. Przy każdym błędzie
//!     katalog roboczy jest usuwany, a pliki programu pozostają nietknięte.
//!     Katalog roboczy leży obok programu (ten sam wolumin), dzięki czemu
//!     podmiana w fazie 2 to same atomowe zmiany nazw.
//!  2. `commit` — dla każdego pliku: `nazwa` -> `nazwa.old` (kopia na wypadek
//!     wycofania), plik nowy na miejsce. Windows pozwala zmienić nazwę
//!     działającego `.exe`, więc program może podmienić sam siebie. Błąd na
//!     dowolnym kroku wycofuje wszystkie wcześniejsze kroki (przywraca `.old`).
//!
//! Kopie `.old` zostają po udanej aktualizacji — `rollback` zamienia je
//! z powrotem. Katalog `data\` (ustawienia, linki, obrazy użytkownika) nie
//! jest nigdy czytany ani zmieniany.

const std = @import("std");
const manifest = @import("manifest.zig");
const net = @import("net.zig");
const builtin = @import("builtin");

pub const stage_dir_name = ".ferrumscope-update";
const files_sub = stage_dir_name ++ "/files";

/// Pliki, które aktualizacja może podmienić (ścieżki względne, separator `/`).
pub const managed_files = [_][]const u8{
    "ferrumscope.exe",
    "ferrumscope-gui.exe",
    "LICENSE",
    "NOTICE.md",
    "README.md",
    "CHANGELOG.md",
    "assets/logos/SOURCES.md",
};
/// Indeksy w `managed_files` plików obowiązkowych w archiwum.
const required = [_]usize{ 0, 1 };

pub const old_suffix = ".old";
pub const rollback_tmp_suffix = ".rollback-tmp";

/// Limit rozmiaru pojedynczego pliku po rozpakowaniu.
pub const max_entry_size: u64 = 150 * 1024 * 1024;
/// Limit rozmiaru `SHA256SUMS`.
pub const max_sums_size: usize = 64 * 1024;

pub const Error = error{
    SizeMismatch,
    HashMismatch,
    SumsMissing,
    SumsMismatch,
    BadSums,
    UnsafePath,
    DuplicateEntry,
    EntryTooLarge,
    MissingFile,
    BackupLocked,
    NoBackup,
    NothingStaged,
    InjectedFailure,
};

// ---------------------------------------------------------------------------
// Weryfikacja
// ---------------------------------------------------------------------------

/// Rozmiar + SHA-256 względem manifestu i względem `SHA256SUMS`.
pub fn verifyArchive(bytes: []const u8, m: *const manifest.Manifest, sums_text: []const u8) Error!void {
    if (bytes.len != m.size) return error.SizeMismatch;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (!std.mem.eql(u8, &digest, &m.sha256)) return error.HashMismatch;
    const listed = manifest.findSum(sums_text, m.fileName()) catch return error.BadSums;
    const sum = listed orelse return error.SumsMissing;
    if (!std.mem.eql(u8, &digest, &sum)) return error.SumsMismatch;
}

// ---------------------------------------------------------------------------
// Rozpakowanie
// ---------------------------------------------------------------------------

/// Klasyfikuje nazwę z archiwum: indeks w `managed_files`, `null` = pomiń
/// (katalog albo plik spoza listy), błąd = niebezpieczna ścieżka.
pub fn classifyEntry(name: []const u8) error{UnsafePath}!?usize {
    if (name.len == 0 or name.len > 260) return error.UnsafePath;
    if (name[0] == '/') return error.UnsafePath;
    for (name) |c| if (c < 0x20 or c == '\\' or c == ':' or c == 0x7f) return error.UnsafePath;
    const is_dir = name[name.len - 1] == '/';
    const body = if (is_dir) name[0 .. name.len - 1] else name;
    var it = std.mem.splitScalar(u8, body, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafePath;
        // Windows obcina końcowe kropki i spacje — „ferrumscope.exe.” to też ten plik.
        if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.UnsafePath;
    }
    if (is_dir) return null;
    for (managed_files, 0..) |f, i| if (std.mem.eql(u8, f, name)) return i;
    return null;
}

/// Rozpakowuje do `dest` wyłącznie pliki z `managed_files`.
pub fn extractArchive(dir: std.fs.Dir, zip_sub: []const u8, dest: std.fs.Dir) !void {
    const file = try dir.openFile(zip_sub, .{});
    defer file.close();
    var rbuf: [8192]u8 = undefined;
    var reader = file.reader(&rbuf);
    var iter = try std.zip.Iterator.init(&reader);
    var seen = [_]bool{false} ** managed_files.len;
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |entry| {
        if (entry.filename_len == 0 or entry.filename_len > 260) return error.UnsafePath;
        const name = name_buf[0..entry.filename_len];
        try reader.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        try reader.interface.readSliceAll(name);
        const idx = try classifyEntry(name) orelse continue;
        if (seen[idx]) return error.DuplicateEntry;
        seen[idx] = true;
        if (entry.uncompressed_size > max_entry_size) return error.EntryTooLarge;
        try entry.extract(&reader, .{}, &name_buf, dest);
    }
    for (required) |i| if (!seen[i]) return error.MissingFile;
}

// ---------------------------------------------------------------------------
// Faza 1: przygotowanie
// ---------------------------------------------------------------------------

pub fn removeStage(app_dir: std.fs.Dir) void {
    app_dir.deleteTree(stage_dir_name) catch {};
}

/// Faza 1 bez sieci (testy i `prepare`): zapis, weryfikacja, rozpakowanie.
pub fn prepareFromBytes(app_dir: std.fs.Dir, m: *const manifest.Manifest, zip_bytes: []const u8, sums_text: []const u8) !void {
    removeStage(app_dir);
    var stage = try app_dir.makeOpenPath(stage_dir_name, .{});
    defer stage.close();
    errdefer removeStage(app_dir);
    const zip_name = m.fileName();
    try stage.writeFile(.{ .sub_path = zip_name, .data = zip_bytes });
    try verifyArchive(zip_bytes, m, sums_text);
    var files = try stage.makeOpenPath("files", .{});
    defer files.close();
    try extractArchive(stage, zip_name, files);
}

/// Faza 1: pobranie archiwum i `SHA256SUMS`, potem `prepareFromBytes`.
pub fn prepare(alloc: std.mem.Allocator, app_dir: std.fs.Dir, m: *const manifest.Manifest) !void {
    const zip = try net.get(alloc, m.url, @intCast(m.size));
    defer alloc.free(zip);
    var ub: [512]u8 = undefined;
    const sums = try net.get(alloc, try m.sumsUrl(&ub), max_sums_size);
    defer alloc.free(sums);
    try prepareFromBytes(app_dir, m, zip, sums);
}

// ---------------------------------------------------------------------------
// Faza 2: podmiana
// ---------------------------------------------------------------------------

/// Wstrzykiwanie awarii w testach.
pub const Hooks = struct {
    /// Awaria po zrobieniu kopii `.old` pliku nr N, przed wstawieniem nowego.
    fail_at: ?usize = null,
};

fn exists(dir: std.fs.Dir, sub: []const u8) bool {
    dir.access(sub, .{}) catch return false;
    return true;
}

fn pathBuf(buf: []u8, a: []const u8, b: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ a, b }) catch unreachable;
}

fn stagedPath(buf: []u8, f: []const u8) []const u8 {
    return pathBuf(buf, files_sub ++ "/", f);
}

/// Zmiana nazwy w obrębie katalogu programu.
///
/// Na Windows przez `MoveFileExW`, nie `Dir.rename`: biblioteka Zig otwiera
/// plik źródłowy z prawem zapisu (GENERIC_WRITE), a tego system odmawia dla
/// działającego `.exe` (AccessDenied). `MoveFileExW` potrzebuje tylko prawa
/// DELETE, więc działający program może zmienić nazwę samego siebie.
fn renameFile(dir: std.fs.Dir, old_sub: []const u8, new_sub: []const u8) !void {
    if (builtin.os.tag != .windows) return dir.rename(old_sub, new_sub);
    var db: [std.fs.max_path_bytes]u8 = undefined;
    const base = try dir.realpath(".", &db);
    var ob: [std.fs.max_path_bytes]u8 = undefined;
    var nb: [std.fs.max_path_bytes]u8 = undefined;
    const o = try std.fmt.bufPrint(&ob, "{s}\\{s}", .{ base, old_sub });
    const n = try std.fmt.bufPrint(&nb, "{s}\\{s}", .{ base, new_sub });
    std.mem.replaceScalar(u8, o, '/', '\\');
    std.mem.replaceScalar(u8, n, '/', '\\');
    const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;
    std.os.windows.MoveFileEx(o, n, MOVEFILE_REPLACE_EXISTING) catch |e| return switch (e) {
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        else => error.RenameFailed,
    };
}

/// Faza 2. Zwraca liczbę podmienionych plików.
pub fn commit(app_dir: std.fs.Dir, hooks: Hooks) !usize {
    var staged = [_]bool{false} ** managed_files.len;
    var any = false;
    for (managed_files, 0..) |f, i| {
        var sb: [400]u8 = undefined;
        staged[i] = exists(app_dir, stagedPath(&sb, f));
        any = any or staged[i];
    }
    if (!any) return error.NothingStaged;
    for (required) |i| if (!staged[i]) return error.MissingFile;

    // Kontrola wstępna: stare kopie `.old` muszą dać się usunąć (np. działający
    // proces sprzed poprzedniej aktualizacji je blokuje) — zanim cokolwiek ruszymy.
    for (managed_files, 0..) |f, i| {
        if (!staged[i]) continue;
        var ob: [400]u8 = undefined;
        app_dir.deleteFile(pathBuf(&ob, f, old_suffix)) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return error.BackupLocked,
        };
    }

    var backed = [_]bool{false} ** managed_files.len;
    var moved = [_]bool{false} ** managed_files.len;
    for (managed_files, 0..) |f, i| {
        if (!staged[i]) continue;
        step(app_dir, f, &backed[i], &moved[i], hooks.fail_at == i) catch |e| {
            undo(app_dir, &backed, &moved);
            return e;
        };
    }
    removeStage(app_dir);
    var n: usize = 0;
    for (moved) |m| n += @intFromBool(m);
    return n;
}

fn step(app_dir: std.fs.Dir, f: []const u8, backed: *bool, moved: *bool, inject: bool) !void {
    var ob: [400]u8 = undefined;
    const old_path = pathBuf(&ob, f, old_suffix);
    var sb: [400]u8 = undefined;
    if (std.fs.path.dirname(f)) |d| try app_dir.makePath(d);
    if (exists(app_dir, f)) {
        try renameFile(app_dir, f, old_path);
        backed.* = true;
    }
    if (inject) return error.InjectedFailure;
    try renameFile(app_dir, stagedPath(&sb, f), f);
    moved.* = true;
}

/// Wycofanie częściowej podmiany (od końca): nowy plik wraca do katalogu
/// roboczego, kopia `.old` na swoje miejsce.
fn undo(app_dir: std.fs.Dir, backed: *const [managed_files.len]bool, moved: *const [managed_files.len]bool) void {
    var i: usize = managed_files.len;
    while (i > 0) {
        i -= 1;
        const f = managed_files[i];
        var ob: [400]u8 = undefined;
        var sb: [400]u8 = undefined;
        if (moved[i]) renameFile(app_dir, f, stagedPath(&sb, f)) catch {
            app_dir.deleteFile(f) catch {};
        };
        if (backed[i]) renameFile(app_dir, pathBuf(&ob, f, old_suffix), f) catch {};
    }
}

/// `update --rollback`: przywraca pliki `*.old`. Zwraca liczbę przywróconych.
pub fn rollback(app_dir: std.fs.Dir) !usize {
    var n: usize = 0;
    for (managed_files) |f| {
        var ob: [400]u8 = undefined;
        const old_path = pathBuf(&ob, f, old_suffix);
        if (!exists(app_dir, old_path)) continue;
        var tb: [400]u8 = undefined;
        const tmp = pathBuf(&tb, f, rollback_tmp_suffix);
        app_dir.deleteFile(tmp) catch {};
        const had_current = exists(app_dir, f);
        if (had_current) try renameFile(app_dir, f, tmp);
        renameFile(app_dir, old_path, f) catch |e| {
            if (had_current) renameFile(app_dir, tmp, f) catch {};
            return e;
        };
        // Działającego .exe nie da się usunąć — sprząta go `cleanupLeftovers`.
        app_dir.deleteFile(tmp) catch {};
        n += 1;
    }
    if (n == 0) return error.NoBackup;
    return n;
}

/// Usuwa pozostałości po wycofaniu (`*.rollback-tmp`). Bezpieczne do
/// wywołania przy każdym starcie; błędy są ignorowane.
pub fn cleanupLeftovers(app_dir: std.fs.Dir) void {
    for (managed_files) |f| {
        var tb: [400]u8 = undefined;
        app_dir.deleteFile(pathBuf(&tb, f, rollback_tmp_suffix)) catch {};
    }
}

/// Katalog z plikami programu (tam, gdzie leży uruchomiony `.exe`).
pub fn openAppDir() !std.fs.Dir {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = try std.fs.selfExeDirPath(&buf);
    return std.fs.cwd().openDir(p, .{});
}

// ---------------------------------------------------------------------------
// Testy (bez sieci, na plikach w katalogu tymczasowym)
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestEntry = struct { name: []const u8, data: []const u8 };

/// Minimalny zapis ZIP (metoda store) — tylko do testów.
fn makeZip(alloc: std.mem.Allocator, entries: []const TestEntry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    var offsets: [16]u32 = undefined;
    for (entries, 0..) |e, i| {
        offsets[i] = @intCast(out.written().len);
        const crc = std.hash.Crc32.hash(e.data);
        try w.writeAll("PK\x03\x04");
        try w.writeInt(u16, 20, .little); // wersja
        try w.writeInt(u16, 0, .little); // flagi
        try w.writeInt(u16, 0, .little); // store
        try w.writeInt(u16, 0, .little); // czas
        try w.writeInt(u16, 0x5b6f, .little); // data
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, @intCast(e.data.len), .little);
        try w.writeInt(u32, @intCast(e.data.len), .little);
        try w.writeInt(u16, @intCast(e.name.len), .little);
        try w.writeInt(u16, 0, .little);
        try w.writeAll(e.name);
        try w.writeAll(e.data);
    }
    const cd_start: u32 = @intCast(out.written().len);
    for (entries, 0..) |e, i| {
        const crc = std.hash.Crc32.hash(e.data);
        try w.writeAll("PK\x01\x02");
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0x5b6f, .little);
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, @intCast(e.data.len), .little);
        try w.writeInt(u32, @intCast(e.data.len), .little);
        try w.writeInt(u16, @intCast(e.name.len), .little);
        try w.writeInt(u16, 0, .little); // extra
        try w.writeInt(u16, 0, .little); // komentarz
        try w.writeInt(u16, 0, .little); // dysk
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u32, 0, .little);
        try w.writeInt(u32, offsets[i], .little);
        try w.writeAll(e.name);
    }
    const cd_end: u32 = @intCast(out.written().len);
    try w.writeAll("PK\x05\x06");
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, @intCast(entries.len), .little);
    try w.writeInt(u16, @intCast(entries.len), .little);
    try w.writeInt(u32, cd_end - cd_start, .little);
    try w.writeInt(u32, cd_start, .little);
    try w.writeInt(u16, 0, .little);
    return out.toOwnedSlice();
}

const test_version = "9.9.9";
const test_zip_name = "FerrumScope-" ++ test_version ++ "-windows-x64.zip";

/// Manifest dla danych bajtów (poprawny adres, rozmiar i suma).
fn testManifest(bytes: []const u8) !manifest.Manifest {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var jb: [1024]u8 = undefined;
    const json = try std.fmt.bufPrint(&jb, "{{\"version\":\"{s}\",\"url\":\"{s}v{s}/{s}\",\"sha256\":\"{s}\",\"size\":{d}}}", .{
        test_version, manifest.release_prefix, test_version, test_zip_name, hex, bytes.len,
    });
    return manifest.parse(testing.allocator, json);
}

fn sumsFor(buf: []u8, bytes: []const u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.bufPrint(buf, "{s}  {s}\n", .{ hex, test_zip_name }) catch unreachable;
}

fn expectContent(dir: std.fs.Dir, sub: []const u8, want: []const u8) !void {
    var buf: [256]u8 = undefined;
    const got = try dir.readFile(sub, &buf);
    try testing.expectEqualStrings(want, got);
}

const good_entries = [_]TestEntry{
    .{ .name = "ferrumscope.exe", .data = "NEW-CLI" },
    .{ .name = "ferrumscope-gui.exe", .data = "NEW-GUI" },
    .{ .name = "README.md", .data = "NEW-README" },
    .{ .name = "assets/", .data = "" },
    .{ .name = "assets/logos/", .data = "" },
    .{ .name = "assets/logos/SOURCES.md", .data = "NEW-SOURCES" },
    .{ .name = "ignored.txt", .data = "nie z listy" },
};

fn seedApp(dir: std.fs.Dir) !void {
    try dir.writeFile(.{ .sub_path = "ferrumscope.exe", .data = "OLD-CLI" });
    try dir.writeFile(.{ .sub_path = "ferrumscope-gui.exe", .data = "OLD-GUI" });
    try dir.writeFile(.{ .sub_path = "README.md", .data = "OLD-README" });
    try dir.makePath("data");
    try dir.writeFile(.{ .sub_path = "data/settings.ini", .data = "update_check = true\n" });
}

test "apply: klasyfikacja nazw i path traversal" {
    try testing.expectEqual(@as(?usize, 0), try classifyEntry("ferrumscope.exe"));
    try testing.expectEqual(@as(?usize, 6), try classifyEntry("assets/logos/SOURCES.md"));
    try testing.expectEqual(@as(?usize, null), try classifyEntry("assets/"));
    try testing.expectEqual(@as(?usize, null), try classifyEntry("inny.dll"));
    for ([_][]const u8{
        "../ferrumscope.exe",   "a/../../x",        "/ferrumscope.exe", "..\\ferrumscope.exe",
        "C:/Windows/evil.exe",  "ferrumscope.exe.", "a//b",             "./ferrumscope.exe",
        "data/settings.ini/..", "ferrumscope.exe ", "",                 "x\x00y",
    }) |bad| try testing.expectError(error.UnsafePath, classifyEntry(bad));
}

test "apply: archiwum z path traversal jest odrzucane w całości" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try seedApp(tmp.dir);
    const zip = try makeZip(testing.allocator, &.{
        .{ .name = "ferrumscope.exe", .data = "NEW-CLI" },
        .{ .name = "ferrumscope-gui.exe", .data = "NEW-GUI" },
        .{ .name = "../evil.exe", .data = "EVIL" },
    });
    defer testing.allocator.free(zip);
    var m = try testManifest(zip);
    defer m.deinit();
    var sb: [256]u8 = undefined;
    try testing.expectError(error.UnsafePath, prepareFromBytes(tmp.dir, &m, zip, sumsFor(&sb, zip)));
    try testing.expect(!exists(tmp.dir, stage_dir_name));
    try testing.expect(!exists(tmp.dir, "evil.exe"));
    try expectContent(tmp.dir, "ferrumscope.exe", "OLD-CLI");
}

test "apply: niezgodna suma lub rozmiar — odrzucenie i usunięcie" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try seedApp(tmp.dir);
    const zip = try makeZip(testing.allocator, &good_entries);
    defer testing.allocator.free(zip);
    var m = try testManifest(zip);
    defer m.deinit();
    var sb: [256]u8 = undefined;
    const sums = sumsFor(&sb, zip);

    // Podmieniony bajt: suma manifestu się nie zgadza.
    const bad = try testing.allocator.dupe(u8, zip);
    defer testing.allocator.free(bad);
    bad[10] ^= 0xff;
    try testing.expectError(error.HashMismatch, prepareFromBytes(tmp.dir, &m, bad, sums));
    try testing.expect(!exists(tmp.dir, stage_dir_name));

    // Inny rozmiar.
    try testing.expectError(error.SizeMismatch, prepareFromBytes(tmp.dir, &m, zip[0 .. zip.len - 1], sums));
    try testing.expect(!exists(tmp.dir, stage_dir_name));

    // Manifest zgodny, ale SHA256SUMS wskazuje inną sumę.
    var other: [256]u8 = undefined;
    try testing.expectError(error.SumsMismatch, prepareFromBytes(tmp.dir, &m, zip, sumsFor(&other, "inne bajty")));
    // SHA256SUMS bez wpisu dla archiwum.
    try testing.expectError(error.SumsMissing, prepareFromBytes(tmp.dir, &m, zip, "3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c  inny.zip\n"));
    try testing.expectError(error.BadSums, prepareFromBytes(tmp.dir, &m, zip, "śmieci\n"));
    try testing.expect(!exists(tmp.dir, stage_dir_name));
    try expectContent(tmp.dir, "ferrumscope.exe", "OLD-CLI");
    try expectContent(tmp.dir, "ferrumscope-gui.exe", "OLD-GUI");
}

test "apply: archiwum bez obowiązkowego pliku" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const zip = try makeZip(testing.allocator, &.{.{ .name = "ferrumscope.exe", .data = "NEW-CLI" }});
    defer testing.allocator.free(zip);
    var m = try testManifest(zip);
    defer m.deinit();
    var sb: [256]u8 = undefined;
    try testing.expectError(error.MissingFile, prepareFromBytes(tmp.dir, &m, zip, sumsFor(&sb, zip)));
    try testing.expect(!exists(tmp.dir, stage_dir_name));
}

test "apply: pełna podmiana, kopie .old i rollback; data\\ nietknięte" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try seedApp(tmp.dir);
    const zip = try makeZip(testing.allocator, &good_entries);
    defer testing.allocator.free(zip);
    var m = try testManifest(zip);
    defer m.deinit();
    var sb: [256]u8 = undefined;
    try prepareFromBytes(tmp.dir, &m, zip, sumsFor(&sb, zip));
    try testing.expect(!exists(tmp.dir, stage_dir_name ++ "/files/ignored.txt"));

    try testing.expectEqual(@as(usize, 4), try commit(tmp.dir, .{}));
    try expectContent(tmp.dir, "ferrumscope.exe", "NEW-CLI");
    try expectContent(tmp.dir, "ferrumscope-gui.exe", "NEW-GUI");
    try expectContent(tmp.dir, "README.md", "NEW-README");
    try expectContent(tmp.dir, "assets/logos/SOURCES.md", "NEW-SOURCES");
    try expectContent(tmp.dir, "ferrumscope.exe.old", "OLD-CLI");
    try expectContent(tmp.dir, "ferrumscope-gui.exe.old", "OLD-GUI");
    try expectContent(tmp.dir, "README.md.old", "OLD-README");
    try testing.expect(!exists(tmp.dir, "assets/logos/SOURCES.md.old"));
    try testing.expect(!exists(tmp.dir, stage_dir_name));
    try expectContent(tmp.dir, "data/settings.ini", "update_check = true\n");

    try testing.expectEqual(@as(usize, 3), try rollback(tmp.dir));
    try expectContent(tmp.dir, "ferrumscope.exe", "OLD-CLI");
    try expectContent(tmp.dir, "ferrumscope-gui.exe", "OLD-GUI");
    try expectContent(tmp.dir, "README.md", "OLD-README");
    try testing.expect(!exists(tmp.dir, "ferrumscope.exe.old"));
    try testing.expect(!exists(tmp.dir, "ferrumscope.exe" ++ rollback_tmp_suffix));
    try testing.expectError(error.NoBackup, rollback(tmp.dir));
    try expectContent(tmp.dir, "data/settings.ini", "update_check = true\n");
}

test "apply: awaria w trakcie podmiany wycofuje wszystko" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try seedApp(tmp.dir);
    const zip = try makeZip(testing.allocator, &good_entries);
    defer testing.allocator.free(zip);
    var m = try testManifest(zip);
    defer m.deinit();
    var sb: [256]u8 = undefined;
    for ([_]usize{ 0, 1, 4, 6 }) |fail_at| {
        try prepareFromBytes(tmp.dir, &m, zip, sumsFor(&sb, zip));
        try testing.expectError(error.InjectedFailure, commit(tmp.dir, .{ .fail_at = fail_at }));
        try expectContent(tmp.dir, "ferrumscope.exe", "OLD-CLI");
        try expectContent(tmp.dir, "ferrumscope-gui.exe", "OLD-GUI");
        try expectContent(tmp.dir, "README.md", "OLD-README");
        try testing.expect(!exists(tmp.dir, "assets/logos/SOURCES.md"));
        for (managed_files) |f| {
            var ob: [400]u8 = undefined;
            try testing.expect(!exists(tmp.dir, pathBuf(&ob, f, old_suffix)));
        }
        try expectContent(tmp.dir, "data/settings.ini", "update_check = true\n");
    }
    // Po nieudanych próbach poprawna podmiana nadal działa.
    try prepareFromBytes(tmp.dir, &m, zip, sumsFor(&sb, zip));
    _ = try commit(tmp.dir, .{});
    try expectContent(tmp.dir, "ferrumscope.exe", "NEW-CLI");
}

test "apply: commit bez przygotowanych plików" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try seedApp(tmp.dir);
    try testing.expectError(error.NothingStaged, commit(tmp.dir, .{}));
    try testing.expectError(error.NoBackup, rollback(tmp.dir));
}
