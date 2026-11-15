//! Czytanie plików capture w formacie tekstowym `.cpuimg`.
//!
//! Format jest **tekstowy celowo**: pliki testowe mają być czytelne dla
//! człowieka, diffowalne w gitre i możliwe do napisania ręcznie. Format binarny
//! `.fcap` (z kompresją i sekcjami SMBIOS/PCI) jest sprawą Etapu 4; na tym
//! etapie `.cpuimg` pełni rolę pliku wejściowego replay i podstawę testów.
//!
//! Składnia (jedna instrukcja w linii, `#` zaczyna komentarz):
//!
//! ```text
//! ferrum-cpuimg 1
//! arch          x86_64
//! max_basic     0x16
//! max_extended  0x80000008
//! leaf 0x0 sub 0x0 eax=0x00000016 ebx=0x756E6547 ecx=0x6C65746E edx=0x49656E69
//! leaf 0x1 sub 0x0 eax=0x000B0671 ebx=0x00100800 ecx=0x7FFAFBFF edx=0x178BFBFF
//! ```
//!
//! Wartości `0x...` są szesnastkowe; `0x1A` i `26` to to samo. Rejestry, których
//! nie podano, przyjmują wartość 0 — dzięki temu pliki testowe są krótsze.

const std = @import("std");
const raw = @import("../core/raw.zig");

pub const magic = "ferrum-cpuimg";
pub const format_version: u32 = 1;

pub const ParseError = error{
    BadMagic,
    UnsupportedFormat,
    Malformed,
    UnknownInstruction,
    LeafOutOfRange,
};

pub const Captured = struct {
    arch: raw.Arch = .x86_64,
    image: raw.CpuidImage = .{},
    /// Odczyty per-logical-CPU (thread-pinned). Puste w plikach v1 — wtedy
    /// replay nie deklaruje `cpuid_per_logical_cpu`, dekorator schodzi do
    /// fallbacku i stare pliki zachowują swoje dotychczasowe zachowanie.
    per_cpu: raw.PerCpuImage = .{},
    /// Ścieżka źródłowa (diagnostyka).
    source: []const u8 = "",
    /// Czy plik zawierał sekcję per-CPU. Rozróżniamy „plik stary" od „pliku
    /// nowego bez danych" — to daje inną diagnostykę.
    has_per_cpu: bool = false,

    /// Zwraca wpis dla `id`, tworząc go przy pierwszym użyciu.
    ///
    /// Kolejność wpisów w pliku nie musi być rosnąca po `id`, więc szukamy
    /// liniowo. Dla plików testowych (16 CPU × kilka liści) to bez znaczenia,
    /// a brak sortowania utrzymuje format czytelnym i diffowalnym.
    pub fn perCpuEntry(self: *Captured, id: u16) *raw.LogicalCpu {
        for (self.per_cpu.items[0..self.per_cpu.len]) |*c| {
            if (c.id == id) return c;
        }
        if (self.per_cpu.len == raw.PerCpuImage.capacity) {
            // Przepełnienie jest niemożliwe dla poprawnych plików (limit 256 CPU
            // odpowiada rozmiarowi obrazu), a gdyby jednak, ostatni wpis pełni rolę
            // ślepego zbiornika zamiast powodować ciche nadpisanie wcześniejszych.
            return &self.per_cpu.items[raw.PerCpuImage.capacity - 1];
        }
        self.per_cpu.items[self.per_cpu.len] = .{
            .id = id,
            .id_valid = true,
            .image = .{
                .max_basic = self.image.max_basic,
                .max_extended = self.image.max_extended,
            },
        };
        self.per_cpu.len += 1;
        return &self.per_cpu.items[self.per_cpu.len - 1];
    }
};

/// Parsuje plik capture. Wszystkie napisy wskazują na `text` — wynik jest
/// ważny tak długo, jak żyje bufor wejściowy.
pub fn parse(text: []const u8) ParseError!Captured {
    var out = Captured{ .source = "" };

    // Nagłówek sprawdzamy **zanim** zinterpretujemy cokolwiek. Bez tego plik
    // obcego formatu dawał błąd „nieznana instrukcja" zamiast „to nie jest
    // plik capture" — czyli diagnozę prowadzącą na zły trop.
    if (std.mem.indexOf(u8, text, magic) == null) return error.BadMagic;

    var saw_magic = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, magic)) {
            var words = std.mem.tokenizeAny(u8, line, " \t");
            _ = words.next(); // magic
            const ver = words.next() orelse return error.Malformed;
            if (try parseInt(ver) != format_version) return error.UnsupportedFormat;
            saw_magic = true;
            continue;
        }

        var words = std.mem.tokenizeAny(u8, line, " \t");
        const instr = words.next() orelse continue;
        if (std.mem.eql(u8, instr, "arch")) {
            const a = words.next() orelse return error.Malformed;
            out.arch = try parseArch(a);
        } else if (std.mem.eql(u8, instr, "max_basic")) {
            out.image.max_basic = @intCast(try parseInt(words.next() orelse return error.Malformed));
        } else if (std.mem.eql(u8, instr, "max_extended")) {
            out.image.max_extended = @intCast(try parseInt(words.next() orelse return error.Malformed));
        } else if (std.mem.eql(u8, instr, "leaf")) {
            const leaf = @as(u32, @intCast(try parseInt(words.next() orelse return error.Malformed)));
            var subleaf: u32 = 0;
            var regs = raw.Regs{};
            while (words.next()) |token| {
                if (std.mem.eql(u8, token, "sub")) {
                    const s = words.next() orelse return error.Malformed;
                    subleaf = @intCast(try parseInt(s));
                } else if (std.mem.startsWith(u8, token, "eax=")) {
                    regs.eax = @intCast(try parseInt(token[4..]));
                } else if (std.mem.startsWith(u8, token, "ebx=")) {
                    regs.ebx = @intCast(try parseInt(token[4..]));
                } else if (std.mem.startsWith(u8, token, "ecx=")) {
                    regs.ecx = @intCast(try parseInt(token[4..]));
                } else if (std.mem.startsWith(u8, token, "edx=")) {
                    regs.edx = @intCast(try parseInt(token[4..]));
                } else {
                    return error.UnknownInstruction;
                }
            }
            out.image.add(leaf, subleaf, regs);
        } else if (std.mem.eql(u8, instr, "per_cpu")) {
            // `per_cpu <id> leaf 0x.. sub 0x.. eax=.. ebx=.. ecx=.. edx=..`
            // Jedna linia = jeden (CPU, leaf, subleaf). Wybrane celowo zamiast
            // zagnieżdżonych sekcji: pozostaje diffowalne w gitre i łatwe do
            // napisania ręcznie przy generowaniu fixture'ów.
            out.has_per_cpu = true;
            const id = @as(u16, @intCast(try parseInt(words.next() orelse return error.Malformed)));
            const kw = words.next() orelse return error.Malformed;
            if (!std.mem.eql(u8, kw, "leaf")) return error.Malformed;
            const leaf = @as(u32, @intCast(try parseInt(words.next() orelse return error.Malformed)));
            var subleaf: u32 = 0;
            var regs = raw.Regs{};
            while (words.next()) |token| {
                if (std.mem.eql(u8, token, "sub")) {
                    const s = words.next() orelse return error.Malformed;
                    subleaf = @intCast(try parseInt(s));
                } else if (std.mem.startsWith(u8, token, "eax=")) {
                    regs.eax = @intCast(try parseInt(token[4..]));
                } else if (std.mem.startsWith(u8, token, "ebx=")) {
                    regs.ebx = @intCast(try parseInt(token[4..]));
                } else if (std.mem.startsWith(u8, token, "ecx=")) {
                    regs.ecx = @intCast(try parseInt(token[4..]));
                } else if (std.mem.startsWith(u8, token, "edx=")) {
                    regs.edx = @intCast(try parseInt(token[4..]));
                } else {
                    return error.UnknownInstruction;
                }
            }
            const entry = out.perCpuEntry(id);
            entry.image.add(leaf, subleaf, regs);
            if (leaf == 0x1) {
                // Initial APIC ID siedzi w **EBX[31:24]**, nie w EDX. EDX to
                // zbiór bitów cech (EDX[31:24] bywa zerowe albo zawiera flagi),
                // więc wcześniejszy odczyt z EDX dawał na przykład 191 zamiast
                // numeru procesora — i nie pasował do niczego, co da się porównać.
                entry.legacy_apic = @truncate(regs.ebx >> 24);
                entry.legacy_apic_known = true;
            }
            entry.scanned = true;
        } else {
            return error.UnknownInstruction;
        }
    }
    if (!saw_magic) return error.BadMagic;
    return out;
}

fn parseArch(s: []const u8) ParseError!raw.Arch {
    if (std.mem.eql(u8, s, "x86")) return .x86;
    if (std.mem.eql(u8, s, "x86_64")) return .x86_64;
    if (std.mem.eql(u8, s, "arm64")) return .arm64;
    if (std.mem.eql(u8, s, "riscv64")) return .riscv64;
    return error.Malformed;
}

/// Liczba w systemie 10 lub 16. Świadomie **nie** `str.isdigit()`: wartości
/// `0x1a` zawierają litery i taka kontrola odrzuciłaby poprawne wejście —
/// dokładnie ten błąd, który w narzędziu importującym rejestr PCI gubił
/// połowę vendorów (patrz `docs/01-analiza-referencji.md` §11).
fn parseInt(s: []const u8) ParseError!u64 {
    if (s.len == 0) return error.Malformed;
    return std.fmt.parseInt(u64, s, 0) catch error.Malformed;
}

/// Zapisuje obraz CPUID do formatu `.cpuimg`.
///
/// Round-trip `format` -> `parse` musi odtworzyć tę samą zawartość; pilnuje
/// tego test poniżej. Bez niego capture zapisany na dysk mógłby po reparsie
/// dać inne dane niż odczytane ze sprzętu — najgorszy rodzaj cichego błędu.
pub fn format(
    w: *std.Io.Writer,
    source: []const u8,
    img: *const raw.CpuidImage,
    per: *const raw.PerCpuImage,
) !void {
    try w.print("# FerrumScope capture\n", .{});
    if (source.len != 0) try w.print("# source: {s}\n", .{source});
    try w.print("# Zawiera wylacznie publiczne dane CPUID — brak danych prywatnych.\n", .{});
    try w.print("ferrum-cpuimg {d}\n", .{format_version});
    try w.print("arch {s}\n", .{@tagName(raw.Arch.x86_64)});
    try w.print("max_basic 0x{X}\n", .{img.max_basic});
    try w.print("max_extended 0x{X}\n", .{img.max_extended});
    try w.print("\n", .{});
    for (img.slice()) |e| {
        try w.print(
            "leaf 0x{X:0>8} sub 0x{X:0>2} eax=0x{X:0>8} ebx=0x{X:0>8} ecx=0x{X:0>8} edx=0x{X:0>8}\n",
            .{ e.leaf, e.subleaf, e.regs.eax, e.regs.ebx, e.regs.ecx, e.regs.edx },
        );
    }
    // Sekcja per-logical-CPU. Bez niej replay nie deklaruje
    // `cpuid_per_logical_cpu`, a topologia schodzi do fallbacku — plik pozostaje
    // kompatybilny z v1, ale nie odtwarza pomiaru przypinaniem wątku.
    for (per.slice()) |c| {
        for (c.image.slice()) |e| {
            try w.print(
                "per_cpu {d} leaf 0x{X:0>8} sub 0x{X:0>2} eax=0x{X:0>8} ebx=0x{X:0>8} ecx=0x{X:0>8} edx=0x{X:0>8}\n",
                .{ c.id, e.leaf, e.subleaf, e.regs.eax, e.regs.ebx, e.regs.ecx, e.regs.edx },
            );
        }
    }
}

const testing = std.testing;

test "round-trip: format i parse odtwarzaja ten sam obraz" {
    var img = raw.CpuidImage{};
    img.max_basic = 0x0D;
    img.max_extended = 0x8000_001E;
    img.add(0, 0, .{ .eax = 0x0D, .ebx = 0x68747541, .ecx = 0x444D4163, .edx = 0x69746E65 });
    img.add(1, 0, .{ .eax = 0x00A20F12, .ebx = 0x02100800, .ecx = 0xFED83203, .edx = 0x178BFBFF });
    img.add(0x8000_001E, 0, .{ .eax = 0x00000002, .ebx = 0x00000101 });

    // Dwa CPU, oba z tym samym rdzeniem (EBX[7:0] = 0) i różnym numerem
    // logical procesora (EAX[7:0] = 0 i 1) — dokładnie tak, jak raportuje
    // Zen 3: rdzień 0 ma wątki 0 i 1.
    var per = raw.PerCpuImage{};
    per.items[0] = .{ .id = 0, .id_valid = true, .scanned = true };
    per.items[0].image.max_basic = 0x0D;
    per.items[0].image.max_extended = 0x8000_001E;
    per.items[0].image.add(0x1, 0, .{ .eax = 0x00A20F12, .ebx = 0x02100800, .ecx = 0xFED83203, .edx = 0x178BFBFF });
    per.items[0].image.add(0x8000_001E, 0, .{ .eax = 0x00000000, .ebx = 0x00000100 });
    per.items[1] = .{ .id = 1, .id_valid = true, .scanned = true };
    per.items[1].image.max_basic = 0x0D;
    per.items[1].image.max_extended = 0x8000_001E;
    per.items[1].image.add(0x1, 0, .{ .eax = 0x00A20F12, .ebx = 0x02100800, .ecx = 0xFED83203, .edx = 0x178BFBFF });
    per.items[1].image.add(0x8000_001E, 0, .{ .eax = 0x00000001, .ebx = 0x00000100 });
    per.len = 2;

    var buf: [8192]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try format(&stream, "test", &img, &per);

    const back = try parse(stream.buffered());
    try testing.expectEqual(img.max_basic, back.image.max_basic);
    try testing.expectEqual(img.max_extended, back.image.max_extended);
    try testing.expectEqual(img.len, back.image.len);
    var i: usize = 0;
    while (i < img.len) : (i += 1) {
        try testing.expectEqual(img.entries[i].leaf, back.image.entries[i].leaf);
        try testing.expectEqual(img.entries[i].subleaf, back.image.entries[i].subleaf);
        try testing.expectEqual(img.entries[i].regs.eax, back.image.entries[i].regs.eax);
        try testing.expectEqual(img.entries[i].regs.ebx, back.image.entries[i].regs.ebx);
        try testing.expectEqual(img.entries[i].regs.ecx, back.image.entries[i].regs.ecx);
        try testing.expectEqual(img.entries[i].regs.edx, back.image.entries[i].regs.edx);
    }

    // Sekcja per-CPU musi przeżyć round-trip **w całości**. Gdyby gubiła jeden
    // rejestr, replay podawałby inną topologię niż native, a plik wyglądałby
    // na poprawny.
    try testing.expect(back.has_per_cpu);
    try testing.expectEqual(per.len, back.per_cpu.len);
    var c: usize = 0;
    while (c < per.len) : (c += 1) {
        try testing.expectEqual(per.items[c].id, back.per_cpu.items[c].id);
        const a = per.items[c].image;
        const b = back.per_cpu.items[c].image;
        try testing.expectEqual(a.len, b.len);
        var j: usize = 0;
        while (j < a.len) : (j += 1) {
            try testing.expectEqual(a.entries[j].leaf, b.entries[j].leaf);
            try testing.expectEqual(a.entries[j].subleaf, b.entries[j].subleaf);
            try testing.expectEqual(a.entries[j].regs.eax, b.entries[j].regs.eax);
            try testing.expectEqual(a.entries[j].regs.ebx, b.entries[j].regs.ebx);
            try testing.expectEqual(a.entries[j].regs.ecx, b.entries[j].regs.ecx);
            try testing.expectEqual(a.entries[j].regs.edx, b.entries[j].regs.edx);
        }
    }
}

const sample =
    \\ferrum-cpuimg 1
    \\# komentarz
    \\arch x86_64
    \\max_basic 0x16
    \\max_extended 0x80000008
    \\leaf 0x0 sub 0x0 eax=0x00000016 ebx=0x756E6547 ecx=0x6C65746E edx=0x49656E69
    \\leaf 0x1 sub 0x0 eax=0x000B0671 ebx=0x00100800 ecx=0x7FFAFBFF edx=0x178BFBFF
;

test "cpuimg: parsowanie podstawowych instrukcji" {
    const c = try parse(sample);
    try testing.expectEqual(raw.Arch.x86_64, c.arch);
    try testing.expectEqual(@as(u32, 0x16), c.image.max_basic);
    try testing.expectEqual(@as(u32, 0x8000_0008), c.image.max_extended);
    try testing.expectEqual(@as(usize, 2), c.image.len);
    try testing.expectEqual(@as(u32, 0x000B0671), c.image.get(1, 0).?.eax);
    try testing.expectEqual(@as(u32, 0x756E6547), c.image.get(0, 0).?.ebx);
}

test "cpuimg: wartości szesnastkowe z literami są akceptowane" {
    // 'a' w hex nie jest cyfrą dziesiętną — implementacja musi używać base 0.
    const c = try parse(
        \\ferrum-cpuimg 1
        \\max_basic 0x1a
        \\leaf 0x0 eax=0x1a
    );
    try testing.expectEqual(@as(u32, 26), c.image.max_basic);
    try testing.expectEqual(@as(u32, 26), c.image.get(0, 0).?.eax);
}

test "cpuimg: błędne wejście jest odrzucane z konkretnym błędem" {
    try testing.expectError(error.BadMagic, parse("cos innego\n"));
    try testing.expectError(error.UnsupportedFormat, parse("ferrum-cpuimg 99\n"));
    try testing.expectError(error.Malformed, parse("ferrum-cpuimg 1\narch\n"));
    try testing.expectError(
        error.Malformed,
        parse("ferrum-cpuimg 1\nleaf 0x0 eax=nieliczba\n"),
    );
    try testing.expectError(
        error.UnknownInstruction,
        parse("ferrum-cpuimg 1\ncos 0x0\n"),
    );
}

test "cpuimg: brak linii leaf daje pusty, ale poprawny obraz" {
    const c = try parse("ferrum-cpuimg 1\nmax_basic 4\n");
    try testing.expectEqual(@as(usize, 0), c.image.len);
    try testing.expectEqual(@as(u32, 4), c.image.max_basic);
}
