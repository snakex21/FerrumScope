//! `pciids-compile` — kompilator bazy PCI ID uruchamiany jako krok budowania.
//!
//! Użycie:
//!   pciids-compile <pci.ids> -o <out.zig> [--bin <out.bin>] [--strict]
//!   pciids-compile <pci.ids> -o <out.bin>
//!
//! Wejściem jest `db/source/pci/pci.ids` z PCI ID Repository
//! (https://pci-ids.ucw.cz/, GPL-2.0-or-later LUB BSD-3-Clause). Parser
//! i serializacja żyją w `src/sys/pciids_format.zig` (moduł `pciids_format`),
//! żeby runtime (`src/sys/pciids.zig`) i to narzędzie dzieliły jeden opis
//! formatu.
//!
//! Gdy wyjściem jest `.zig`, narzędzie zapisuje **dwa** pliki w tym samym
//! katalogu: binarny obraz (domyślnie `<out>.bin`, albo ścieżka z `--bin`)
//! oraz źródło Zig, które osadza go przez `@embedFile`. To tańsze niż
//! literał tablicy bajtów (obraz ma ok. 1 MB — literał to kilka MB źródła
//! do sparsowania przy każdej kompilacji programu). Obraz musi leżeć obok
//! `.zig`, bo `@embedFile` nie sięga poza katalog modułu.
//!
//! Błędne linie wejścia są liczone i raportowane, ale nie przerywają
//! budowania (chyba że podano `--strict`). Duplikaty: wygrywa pierwszy wpis.

const std = @import("std");
const format = @import("pciids_format");

fn fail(comptime f: []const u8, args: anytype) void {
    std.debug.print("pciids: BŁĄD: " ++ f ++ "\n", args);
}

fn note(comptime f: []const u8, args: anytype) void {
    std.debug.print("pciids: " ++ f ++ "\n", args);
}

/// Podsumowanie idzie na stdout (jak w `hwdb-compile`), ostrzeżenia na stderr.
fn summary(comptime f: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var fw = std.fs.File.stdout().writer(&buf);
    fw.interface.print("pciids: " ++ f ++ "\n", args) catch {};
    fw.interface.flush() catch {};
}

const Options = struct {
    input: []const u8,
    out: []const u8,
    bin: ?[]const u8 = null,
    strict: bool = false,
};

fn parseArgs(args: []const []const u8) ?Options {
    var input: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var bin: ?[]const u8 = null;
    var strict = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--bin")) {
            i += 1;
            if (i >= args.len) {
                fail("brak ścieżki po {s}", .{a});
                return null;
            }
            if (a[1] == 'o') out = args[i] else bin = args[i];
        } else if (std.mem.eql(u8, a, "--strict")) {
            strict = true;
        } else if (input == null) {
            input = a;
        } else {
            fail("nadmiarowy argument '{s}'", .{a});
            return null;
        }
    }
    return .{
        .input = input orelse {
            fail("użycie: pciids-compile <pci.ids> -o <out.zig|out.bin> [--bin <out.bin>] [--strict]", .{});
            return null;
        },
        .out = out orelse {
            fail("wymagany argument -o <ścieżka>", .{});
            return null;
        },
        .bin = bin,
        .strict = strict,
    };
}

pub fn main() u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Na Windows `std.process.args()` jest niedostępne — wariant z alokatorem.
    const argv = std.process.argsAlloc(arena) catch {
        fail("nie mogę odczytać argumentów wiersza poleceń", .{});
        return 2;
    };
    const opts = parseArgs(argv[1..]) orelse return 2;

    var timer = std.time.Timer.start() catch null;

    const text = std.fs.cwd().readFileAlloc(arena, opts.input, 64 * 1024 * 1024) catch |e| {
        fail("nie mogę czytać '{s}': {t}", .{ opts.input, e });
        return 2;
    };
    var parsed = format.parse(arena, text) catch |e| {
        fail("parsowanie: {t}", .{e});
        return 1;
    };
    const image = format.serialize(arena, &parsed) catch |e| {
        fail("serializacja: {t}", .{e});
        return 1;
    };

    if (parsed.malformed != 0) {
        note("{d} linii nie dało się zinterpretować (pominięte), pierwsze:", .{parsed.malformed});
        for (parsed.malformed_lines) |ln| note("  {s}:{d}", .{ opts.input, ln });
    }
    if (std.mem.indexOf(u8, parsed.attribution, "BSD License") == null) {
        note("UWAGA: nagłówek wejścia nie zawiera informacji o licencji", .{});
    }

    if (std.mem.endsWith(u8, opts.out, ".zig")) {
        const bin_path = opts.bin orelse std.fmt.allocPrint(arena, "{s}.bin", .{opts.out[0 .. opts.out.len - 4]}) catch return 1;
        const zig_dir = std.fs.path.dirname(opts.out) orelse ".";
        const bin_dir = std.fs.path.dirname(bin_path) orelse ".";
        if (!std.mem.eql(u8, zig_dir, bin_dir)) {
            fail("obraz '{s}' musi leżeć w katalogu '{s}' (wymóg @embedFile)", .{ bin_path, zig_dir });
            return 2;
        }
        writeFile(bin_path, image) catch |e| {
            fail("zapis '{s}': {t}", .{ bin_path, e });
            return 1;
        };
        writeZig(opts.out, std.fs.path.basename(bin_path), &parsed, image.len) catch |e| {
            fail("zapis '{s}': {t}", .{ opts.out, e });
            return 1;
        };
    } else {
        writeFile(opts.out, image) catch |e| {
            fail("zapis '{s}': {t}", .{ opts.out, e });
            return 1;
        };
    }

    const ms: u64 = if (timer) |*t| t.read() / std.time.ns_per_ms else 0;
    summary(
        "pci.ids {s}: {d} producentów, {d} urządzeń, {d} podsystemów, {d} klas, {d} podklas, {d} prog-if; " ++
            "{d} duplikatów, {d} błędnych linii -> {s} ({d} B, {d} ms)",
        .{
            parsed.version,
            parsed.vendors.len,
            parsed.devices.len,
            parsed.subsystems.len,
            parsed.classes.len,
            parsed.subclasses.len,
            parsed.progifs.len,
            parsed.duplicates,
            parsed.malformed,
            opts.out,
            image.len,
            ms,
        },
    );
    if (opts.strict and parsed.malformed != 0) return 1;
    return 0;
}

fn writeFile(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
    var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(data);
}

/// Emituje moduł Zig osadzający obraz i metadane źródła.
fn writeZig(path: []const u8, bin_name: []const u8, p: *const format.Parsed, image_len: usize) !void {
    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
    var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    var wbuf: [4096]u8 = undefined;
    var fw = f.writer(&wbuf);
    try emitZig(&fw.interface, bin_name, p, image_len);
    // Bez flushu koniec pliku zostałby w buforze.
    try fw.interface.flush();
}

fn emitZig(w: *std.Io.Writer, bin_name: []const u8, p: *const format.Parsed, image_len: usize) !void {
    try w.writeAll(
        \\// Plik wygenerowany przez tools/pciids_compile.zig — nie edytuj ręcznie.
        \\// Źródło: PCI ID Repository (https://pci-ids.ucw.cz/), plik pci.ids,
        \\// licencja GPL-2.0-or-later LUB BSD-3-Clause (nagłówek: `attribution`).
        \\
        \\
    );
    try w.print("pub const bytes: []const u8 = @embedFile(\"{f}\");\n", .{std.zig.fmtString(bin_name)});
    try w.print("pub const image_len = {d};\n", .{image_len});
    try w.print("pub const source_version: []const u8 = \"{f}\";\n", .{std.zig.fmtString(p.version)});
    try w.print("pub const source_date: []const u8 = \"{f}\";\n", .{std.zig.fmtString(p.date)});
    try w.print("pub const attribution: []const u8 = \"{f}\";\n", .{std.zig.fmtString(p.attribution)});
}

// ---------------------------------------------------------------------------
// Testy parsera (logika w `pciids_format`, tu sprawdzamy kontrakt narzędzia).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parser: CRLF, nagłówek, wersja i licencja" {
    const text =
        "#\r\n" ++
        "#\tVersion: 2026.09.25\r\n" ++
        "#\tDate:    2026-09-25 03:15:01\r\n" ++
        "#\tThis file can be distributed under either the GNU General Public License\r\n" ++
        "#\t(version 2 or higher) or the 3-clause BSD License.\r\n" ++
        "\r\n" ++
        "# komentarz poza nagłówkiem\r\n" ++
        "8086  Intel Corporation\r\n" ++
        "\ta780  Raptor Lake-S GT1 [UHD Graphics 770]\r\n" ++
        "\t\t1043 8882  ROG STRIX Z790\r\n";
    var p = try format.parse(testing.allocator, text);
    defer p.deinit(testing.allocator);

    try testing.expectEqualStrings("2026.09.25", p.version);
    try testing.expectEqualStrings("2026-09-25 03:15:01", p.date);
    try testing.expect(std.mem.indexOf(u8, p.attribution, "3-clause BSD License.") != null);
    try testing.expect(std.mem.indexOf(u8, p.attribution, "komentarz") == null);
    try testing.expect(std.mem.indexOfScalar(u8, p.attribution, '\r') == null);
    try testing.expectEqual(@as(usize, 1), p.vendors.len);
    try testing.expectEqualStrings("Intel Corporation", p.vendors[0].name);
    try testing.expectEqual(@as(u16, 0xa780), p.devices[0].did);
    try testing.expectEqualStrings("Raptor Lake-S GT1 [UHD Graphics 770]", p.devices[0].name);
    try testing.expectEqual(@as(usize, 1), p.subsystems.len);
    try testing.expectEqual(@as(u16, 0x1043), p.subsystems[0].svid);
    try testing.expectEqual(@as(u16, 0x8882), p.subsystems[0].sdid);
    try testing.expectEqualStrings("ROG STRIX Z790", p.subsystems[0].name);
    try testing.expectEqual(@as(u32, 0), p.malformed);
}

test "parser: duplikaty — wygrywa pierwszy, dzieci się scalają" {
    const text =
        "1022  Advanced Micro Devices, Inc. [AMD]\n" ++
        "\t1480  Starship/Matisse Root Complex\n" ++
        "\t1480  DRUGI (odrzucony)\n" ++
        "\t\t1462 7c56  MSI board\n" ++
        "1022  AMD duplikat\n" ++
        "\t1630  Renoir/Cezanne Root Complex\n" ++
        "\t\t1462 7c56  MSI board duplikat\n";
    // Ostatni podsystem jest pod 1630, więc nie jest duplikatem.
    var p = try format.parse(testing.allocator, text);
    defer p.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), p.vendors.len);
    try testing.expectEqualStrings("Advanced Micro Devices, Inc. [AMD]", p.vendors[0].name);
    try testing.expectEqual(@as(usize, 2), p.devices.len);
    try testing.expectEqualStrings("Starship/Matisse Root Complex", p.devices[0].name);
    try testing.expectEqual(@as(u16, 0x1630), p.devices[1].did);
    try testing.expectEqual(@as(usize, 2), p.subsystems.len);
    try testing.expectEqual(@as(u32, 2), p.duplicates);
}

test "parser: sortowanie niezależne od kolejności w pliku" {
    const text =
        "8086  Intel\n" ++
        "\tffff  B\n" ++
        "\t0001  A\n" ++
        "1002  AMD\n";
    var p = try format.parse(testing.allocator, text);
    defer p.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 0x1002), p.vendors[0].vid);
    try testing.expectEqual(@as(u16, 0x8086), p.vendors[1].vid);
    try testing.expectEqual(@as(u16, 0x0001), p.devices[0].did);
    try testing.expectEqual(@as(u16, 0xffff), p.devices[1].did);
}

test "parser: sekcja klas i powrót do producentów" {
    const text =
        "C 03  Display controller\n" ++
        "\t00  VGA compatible controller\n" ++
        "\t\t00  VGA controller\n" ++
        "\t02  3D controller\n" ++
        "C 01  Mass storage controller\n" ++
        "\t08  Non-Volatile memory controller\n" ++
        "\t\t02  NVM Express\n" ++
        "C ff  Unassigned class\n" ++
        "abcd  Vendor po klasach\n" ++
        "\t0001  Urządzenie\n";
    var p = try format.parse(testing.allocator, text);
    defer p.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 3), p.classes.len);
    try testing.expectEqual(@as(u8, 0x01), p.classes[0].class);
    try testing.expectEqual(@as(u8, 0xff), p.classes[2].class);
    try testing.expectEqual(@as(usize, 3), p.subclasses.len);
    try testing.expectEqual(@as(usize, 2), p.progifs.len);
    try testing.expectEqualStrings("NVM Express", p.progifs[0].name);
    try testing.expectEqual(@as(u8, 0x01), p.progifs[0].class);
    try testing.expectEqual(@as(u8, 0x08), p.progifs[0].sub);
    try testing.expectEqual(@as(usize, 1), p.vendors.len);
    try testing.expectEqual(@as(usize, 1), p.devices.len);
    try testing.expectEqual(@as(u32, 0), p.malformed);
}

test "parser: błędne linie są liczone, nie przerywają i nie przypinają dzieci" {
    const text =
        "zzzz  Zły vendor\n" ++ // 1: zły hex
        "\t0001  Sierota\n" ++ // 2: brak producenta
        "10de  NVIDIA\n" ++ // 3
        "\t12  Za krótki id\n" ++ // 4
        "\t\t1043 0001  Podsystem bez urządzenia\n" ++ // 5
        "\t2684\n" ++ // 6: brak nazwy
        "\t2685  OK\n" ++ // 7
        "\t\t1043  brak sdid\n" ++ // 8
        "\t\t\t0000  za głęboko\n" ++ // 9
        "C xx  Zła klasa\n" ++ // 10
        "\t00  Podklasa bez klasy\n" ++ // 11
        "X 00  Nieznana sekcja\n"; // 12
    var p = try format.parse(testing.allocator, text);
    defer p.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 10), p.malformed);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 4, 5, 6, 8, 9, 10, 11, 12 }, p.malformed_lines);
    try testing.expectEqual(@as(usize, 1), p.vendors.len);
    try testing.expectEqual(@as(usize, 1), p.devices.len);
    try testing.expectEqualStrings("OK", p.devices[0].name);
    try testing.expectEqual(@as(usize, 0), p.subsystems.len);
    try testing.expectEqual(@as(usize, 0), p.classes.len);
}

test "parser: tabulatory w nazwie i białe znaki na końcu" {
    const text = "1af4  Red Hat, Inc. \t \n\t1000  Virtio network device\t\t\t<-- komentarz\n";
    var p = try format.parse(testing.allocator, text);
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings("Red Hat, Inc.", p.vendors[0].name);
    try testing.expectEqualStrings("Virtio network device\t\t\t<-- komentarz", p.devices[0].name);
}

test "emitZig: poprawne literały i @embedFile" {
    var p = try format.parse(testing.allocator, "#\tVersion: 1.0\n#\tCudzysłów \"x\" i \\\n");
    defer p.deinit(testing.allocator);
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try emitZig(&w, "ferrum-pciids.bin", &p, 123);
    const out = w.buffered();
    try testing.expect(std.mem.indexOf(u8, out, "@embedFile(\"ferrum-pciids.bin\")") != null);
    try testing.expect(std.mem.indexOf(u8, out, "source_version: []const u8 = \"1.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\\\"x\\\" i \\\\") != null);
    try testing.expect(std.mem.indexOf(u8, out, "pub const image_len = 123;") != null);
}

test "parseArgs" {
    const o = parseArgs(&.{ "pci.ids", "-o", "x.zig", "--bin", "x.bin", "--strict" }).?;
    try testing.expectEqualStrings("pci.ids", o.input);
    try testing.expectEqualStrings("x.zig", o.out);
    try testing.expectEqualStrings("x.bin", o.bin.?);
    try testing.expect(o.strict);
    try testing.expect(parseArgs(&.{"pci.ids"}) == null);
}

test {
    _ = format;
}
