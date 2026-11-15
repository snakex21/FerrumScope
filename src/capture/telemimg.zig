//! Capture i replay **surowych** odczytów telemetrycznych.
//!
//! # Dlaczego surowe, a nie wynikowe
//!
//! Zapisujemy `APERF = 0x1234`, a nie `effective_clock = 3800 MHz`. To wymóg, nie
//! wybór estetyczny: gdyby plik trzymał wynik, replay nie wykonałby żadnych
//! obliczeń — tylko wypisałby liczbę z pliku. Po poprawce matematyki delty stare
//! pliki pokazywałyby **stare** wyniki i nie pozwoliłyby sprawdzić, czy nowa
//! matematyka działa.
//!
//! Replay implementuje **ten sam** `msr.Backend`, co sterownik Windows i
//! `/dev/cpu/*/msr`. Dekoder nie wie, skąd pochodzą dane — i nie może wiedzieć.
//! Test na backendzie sztucznym i test na replay przechodzą tę samą ścieżkę.
//!
//! # Zgodność wsteczna
//!
//! Format jest **tekstowy, linia po linii**, a sekcja telemetry jest opcjonalna.
//! Plik `.cpuimg` bez linii `telem` parsuje się jak dotychczas, a replay jawnie
//! deklaruje brak danych. Stary capture nie jest „zepsuty" — on po prostu nie
//! zawiera sekcji, której nie potrzebował.
//!
//! To odwrotna sytuacja niż z formatem bazy HWDB, gdzie sekcje są obowiązkowe i
//! wersjonowane: tam brak sekcji oznaczałby plik niekompatybilny; tutaj plik bez
//! sekcji jest po prostu starszy.

const std = @import("std");
const msr = @import("../telemetry/msr.zig");

pub const magic = "ferrum-telemimg";
pub const format_version: u32 = 1;

/// Maksymalna liczba surowych odczytów w pliku. 16384 odczyty × 4 rejestry ×
/// 4 klatki/odczyt ≈ 16 tys. klatek, czyli ~70 minut przy 250 ms — wystarcza na
/// sesję diagnostyczną, a format pozostaje bez alokacji.
pub const max_reads: usize = 16384;

/// Osobny limit na błędy.
///
/// Trzymamy je osobno, bo błąd to **informacja**, nie brak danych:
/// `permission_denied` w capture znaczy „w tej chwili nie było dostępu", a
/// brak rekordu znaczy „nikt tego nie czytał". W `readMsr` wyglądają podobnie,
/// ale diagnostycznie to zupełnie różne sytuacje, więc ich nie mieszamy.
pub const max_failures: usize = 1024;

/// Surowy odczyt zapisany w capture.
pub const RawRead = struct {
    /// Czas monotoniczny w nanosekundach.
    timestamp_ns: u64,
    logical_cpu: u16,
    msr_index: u32,
    value: u64,
};

/// Błąd odczytu zapisany w capture.
pub const Failure = struct {
    timestamp_ns: u64,
    logical_cpu: u16,
    msr_index: u32,
    /// Nazwa pola to `kind`, nie `error`: `error` jest **słowem kluczowym** Zigu
    /// (typ `error{...}`) i nie może być nazwą pola.
    kind: msr.MsrError,
};

/// Odtworzona sekcja telemetry.
pub const Captured = struct {
    reads: [max_reads]RawRead = undefined,
    reads_len: usize = 0,
    failures: [max_failures]Failure = undefined,
    failures_len: usize = 0,
    /// Liczba procesorów logicznych widzianych przez źródło.
    cpu_count: u16 = 0,
    /// Nominalna częstotliwość TSC w Hz.
    ///
    /// **Obowiązkowa** do wyliczenia efektywnej częstotliwości. APERF i MPERF
    /// dają **stosunek** cykli, a nie częstotliwość w Hz — bez skali czasowej
    /// nie ma czego skalować. Dlatego zapisujemy ją obok surowych liczników:
    /// replay musi wykonać te same obliczenia co sprzęt, a sprzęt zna tę
    /// wartość z CPUID, którego tu nie ma.
    ///
    /// `0` = nieznana. Wtedy efektywna częstotliwość zwraca `unavailable`,
    /// a nie zgadywane MHz.
    nominal_hz: u64 = 0,
    /// Nazwa źródła do raportu, np. `synthetic`, `replay`.
    source: []const u8 = "",
    /// Czy sekcja istnieje w ogóle. `false` = stary plik bez telemetry.
    present: bool = false,

    pub fn hasTelemetry(self: Captured) bool {
        return self.present and (self.reads_len > 0 or self.failures_len > 0);
    }

    /// Liczba klatek, czyli unikalnych timestampów.
    ///
    /// Klatka to jeden „moment": odczyty wielu rejestrów dla wielu CPU zebrane
    /// w jednym cyklu pollera. Zakładamy, że rekordy są posortowane po czasie —
    /// capture zapisuje je w kolejności odczytu, a testy tego pilnują.
    pub fn frameCount(self: Captured) usize {
        if (self.reads_len == 0) return 0;
        var n: usize = 1;
        var i: usize = 1;
        while (i < self.reads_len) : (i += 1) {
            if (self.reads[i].timestamp_ns != self.reads[i - 1].timestamp_ns) n += 1;
        }
        return n;
    }
};

pub const ParseError = error{
    /// Tekst nie zaczyna się sygnaturą `ferrum-telemimg`.
    BadMagic,
    UnsupportedFormat,
    /// Linia nie pasuje do żadnego znanego kształtu. Odrzucamy **cały** plik:
    /// tolerowanie uszkodzonej linii dałoby po cichu dane stracone.
    Malformed,
    /// Więcej odczytów niż mieści format. Nie zwracamy cicho pliku
    /// niekompletnego — to najgorszy możliwy błąd w narzędziu diagnostycznym.
    Overflow,
};

/// Parsuje sekcję telemetry. Ściąga wskaźniki na `text`; wynik ważny tak długo,
/// jak żyje bufor wejściowy.
pub fn parse(text: []const u8) ParseError!Captured {
    var out = Captured{ .source = "", .present = true };
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    var saw_magic = false;
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!saw_magic) {
            if (!std.mem.startsWith(u8, line, magic)) return error.BadMagic;
            const rest = std.mem.trim(u8, line[magic.len..], " \t");
            const ver = std.fmt.parseInt(u32, rest, 10) catch return error.Malformed;
            if (ver != format_version) return error.UnsupportedFormat;
            saw_magic = true;
            continue;
        }
        // Prefiks `telem` jest opcjonalny przy czytaniu, bo plik pisany ręcznie
        // nie musi go powtarzać, a `format` go dodaje.
        const body = if (std.mem.startsWith(u8, line, "telem ")) line["telem ".len..] else line;
        try parseLine(body, &out);
    }
    if (!saw_magic) return error.BadMagic;
    return out;
}

/// Wyciąga sekcję telemetry z pliku `.cpuimg` (linie z prefiksem `telem`).
///
/// Osobny, ** liberalny** parser: linie CPUID pomija, a `telem <kw> ...` traktuje
/// jak `<kw> ...`. Linia `telem` z nieznanym słowem kluczowym **odrzuca** cały
/// plik — inaczej literówka w nowym typie rekordu cicho gubiłaby dane.
pub fn parseCpuimgSection(text: []const u8) ParseError!?Captured {
    var out = Captured{ .source = "", .present = true };
    var found = false;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (!std.mem.startsWith(u8, line, "telem ")) continue;
        found = true;
        try parseLine(std.mem.trim(u8, line["telem ".len..], " \t"), &out);
    }
    if (!found) return null;
    return out;
}

fn parseLine(line: []const u8, out: *Captured) ParseError!void {
    // `tokenizeAny`, nie `tokenizeScalar`: rozdzielamy po spacji **i** tabulatorze,
    // a `tokenizeScalar` przyjmuje dokładnie jeden bajt separatora.
    var f = std.mem.tokenizeAny(u8, line, " \t");
    const kw = f.next() orelse return error.Malformed;

    if (std.mem.eql(u8, kw, "cpu_count")) {
        const v = f.next() orelse return error.Malformed;
        out.cpu_count = std.fmt.parseInt(u16, v, 10) catch return error.Malformed;
    } else if (std.mem.eql(u8, kw, "nominal_hz")) {
        const v = f.next() orelse return error.Malformed;
        out.nominal_hz = std.fmt.parseInt(u64, v, 0) catch return error.Malformed;
    } else if (std.mem.eql(u8, kw, "source")) {
        out.source = std.mem.trim(u8, f.rest(), " \t");
    } else if (std.mem.eql(u8, kw, "read")) {
        const ts = f.next() orelse return error.Malformed;
        const cpu = f.next() orelse return error.Malformed;
        const idx = f.next() orelse return error.Malformed;
        const val = f.next() orelse return error.Malformed;
        if (out.reads_len >= max_reads) return error.Overflow;
        out.reads[out.reads_len] = .{
            .timestamp_ns = std.fmt.parseInt(u64, ts, 0) catch return error.Malformed,
            .logical_cpu = std.fmt.parseInt(u16, cpu, 0) catch return error.Malformed,
            .msr_index = std.fmt.parseInt(u32, idx, 0) catch return error.Malformed,
            .value = std.fmt.parseInt(u64, val, 0) catch return error.Malformed,
        };
        out.reads_len += 1;
    } else if (std.mem.eql(u8, kw, "fail")) {
        const ts = f.next() orelse return error.Malformed;
        const cpu = f.next() orelse return error.Malformed;
        const idx = f.next() orelse return error.Malformed;
        const err = f.next() orelse return error.Malformed;
        if (out.failures_len >= max_failures) return error.Overflow;
        out.failures[out.failures_len] = .{
            .timestamp_ns = std.fmt.parseInt(u64, ts, 0) catch return error.Malformed,
            .logical_cpu = std.fmt.parseInt(u16, cpu, 0) catch return error.Malformed,
            .msr_index = std.fmt.parseInt(u32, idx, 0) catch return error.Malformed,
            .kind = parseErrorName(err) orelse return error.Malformed,
        };
        out.failures_len += 1;
    } else {
        return error.Malformed;
    }
}

fn parseErrorName(s: []const u8) ?msr.MsrError {
    inline for (@typeInfo(msr.MsrError).@"enum".fields) |fld| {
        if (std.mem.eql(u8, s, fld.name)) return @enumFromInt(fld.value);
    }
    return null;
}

/// Zapisuje sekcję telemetry.
///
/// Linie `read`/`fail` mają prefiks `telem`, żeby dały się wkleić w plik
/// `.cpuimg` i zostać wyłuskane przez `parseCpuimgSection`. Standalone plik
/// `.telemimg` zaczyna się sygnaturą zamiast tego.
pub fn format(
    w: *std.Io.Writer,
    source: []const u8,
    reads: []const RawRead,
    failures: []const Failure,
    cpu_count: u16,
    nominal_hz: u64,
) !void {
    try w.print("# FerrumScope telemetry capture\n", .{});
    if (source.len != 0) try w.print("# source: {s}\n", .{source});
    // To zdanie jest **treścią** pliku, nie komentarzem autora: czytelnik musi
    // wiedzieć, że liczby tutaj są surowe, a nie zinterpretowane.
    try w.print("# Surowe odczyty rejestrow - interpretacja odbywa sie przy replayu.\n", .{});
    try w.print("{s} {d}\n", .{ magic, format_version });
    // Wszystkie linie danych dostają prefiks `telem` — także `cpu_count`.
    // Bez niego sekcja wklejona do `.cpuimg` gubiłaby liczbę CPU, a replay
    // zadeklarowałby `onlineCpuCount() == 0`.
    try w.print("telem cpu_count {d}\n", .{cpu_count});
    if (nominal_hz != 0) try w.print("telem nominal_hz {d}\n", .{nominal_hz});
    for (reads) |r| {
        try w.print("telem read {d} {d} 0x{X} 0x{X}\n", .{
            r.timestamp_ns, r.logical_cpu, r.msr_index, r.value,
        });
    }
    for (failures) |fl| {
        try w.print("telem fail {d} {d} 0x{X} {s}\n", .{
            fl.timestamp_ns, fl.logical_cpu, fl.msr_index, @tagName(fl.kind),
        });
    }
}

// ---------------------------------------------------------------------------
// Backend replayu
// ---------------------------------------------------------------------------

/// Backend odtwarzający zapisane odczyty.
///
/// Zasada nadrzędna: gdy w pliku **nie ma** odczytu danego rejestru, zwracamy
/// `.unsupported`, a nie `0`. Brak rekordu to „nie wiemy", nie „zero" — i to
/// rozróżnienie jest dokładnie tym, czego brakuje tanim backendom, które
/// wypełniają luki zerami.
pub const ReplayBackend = struct {
    image: *const Captured,
    /// Kursor na bieżącą klatkę. Przesuwany przez `advanceToNextFrame`.
    frame: usize = 0,
    /// Liczba obsłużonych odczytów — do pomiarów wydajności i diagnostyki.
    total_reads: u64 = 0,

    pub fn init(image: *const Captured) ReplayBackend {
        return .{ .image = image };
    }

    pub fn api(self: *ReplayBackend) msr.Backend {
        return .{ .vtable = vtable(), .ctx = @ptrCast(self) };
    }

    pub fn frameCount(self: *const ReplayBackend) usize {
        return self.image.frameCount();
    }

    /// Timestamp klatki o indeksie `i`, licząc od zera.
    fn frameTime(self: *const ReplayBackend, i: usize) u64 {
        if (self.image.reads_len == 0) return 0;
        var seen: usize = 0;
        var k: usize = 0;
        while (k < self.image.reads_len) : (k += 1) {
            if (k == 0 or self.image.reads[k].timestamp_ns != self.image.reads[k - 1].timestamp_ns) {
                if (seen == i) return self.image.reads[k].timestamp_ns;
                seen += 1;
            }
        }
        return self.image.reads[self.image.reads_len - 1].timestamp_ns;
    }

    /// Czas bieżącej klatki. Zegar **nie** idzie sam — decyduje caller, bo inaczej
    /// wynik zależałby od tempa maszyny.
    pub fn currentTime(self: *const ReplayBackend) u64 {
        const total = self.frameCount();
        if (total == 0) return 0;
        if (self.frame >= total) return self.frameTime(total - 1);
        return self.frameTime(self.frame);
    }

    /// Przesuwa kursor na następną klatkę. Zwraca `false` na końcu sekwencji.
    pub fn advanceToNextFrame(self: *ReplayBackend) bool {
        const total = self.frameCount();
        if (self.frame + 1 >= total) {
            self.frame = total;
            return false;
        }
        self.frame += 1;
        return true;
    }

    pub fn hasMore(self: *const ReplayBackend) bool {
        return self.frame + 1 < self.frameCount();
    }

    pub fn isFinished(self: *const ReplayBackend) bool {
        return self.frame >= self.frameCount();
    }

    /// Liczba klatek pozostałych do odtworzenia.
    pub fn remainingFrames(self: *const ReplayBackend) usize {
        const total = self.frameCount();
        return if (self.frame >= total) 0 else total - self.frame;
    }

    /// Odtwarza jeden odczyt dla bieżącej klatki.
    pub fn readMsr(self: *ReplayBackend, logical_cpu: u16, index: u32) msr.MsrRead {
        self.total_reads += 1;
        const now = self.currentTime();

        // Błędy najpierw: gdy w danej chwili odczyt się nie udał, to jest
        // odpowiedź — nawet jeśli ta sama klatka zawiera wartość dla innego CPU.
        for (self.image.failures[0..self.image.failures_len]) |fl| {
            if (fl.timestamp_ns != now) continue;
            if (fl.logical_cpu != logical_cpu or fl.msr_index != index) continue;
            return msr.MsrRead.fail(fl.kind);
        }
        for (self.image.reads[0..self.image.reads_len]) |r| {
            if (r.timestamp_ns != now) continue;
            if (r.logical_cpu != logical_cpu or r.msr_index != index) continue;
            return msr.MsrRead.ok(r.value);
        }
        // Brak wpisu w pliku to **brak wiedzy**, nie wartość 0.
        return msr.MsrRead.fail(.unsupported);
    }

    pub fn onlineCpuCount(self: *const ReplayBackend) u16 {
        return self.image.cpu_count;
    }

    /// Zdolności wynikają **wyłącznie** z zawartości pliku.
    ///
    /// Deklarujemy tylko to, co replay faktycznie zwróci. Gdyby przy pliku
    /// pełnym samych błędów deklarować `msr_read`, silnik pytałby o rejestry,
    /// na które zawsze dostałby `unsupported`, i raportowałby to jako „czujnik
    /// nieudany" zamiast „backend nie umie" — to dwie różne diagnozy.
    pub fn capabilities(self: *const ReplayBackend) msr.CapabilitySet {
        var set = msr.CapabilitySet{};
        if (self.image.reads_len == 0 and self.image.failures_len == 0) return set;
        set.add(.msr_read);
        set.add(.per_cpu_msr_read);
        for (self.image.reads[0..self.image.reads_len]) |r| {
            if (r.msr_index == 0xE8 or r.msr_index == 0xE7) {
                set.add(.aperf_mperf);
                break;
            }
        }
        return set;
    }

    /// Zegar **nie** zwraca czasu systemowego — zwraca czas z pliku. Inaczej
    /// delta liczników zależałaby od szybkości odtwarzania.
    pub fn monotonicNanos(self: *const ReplayBackend) u64 {
        return self.currentTime();
    }

    /// Nominalna częstotliwość z pliku — skala potrzebna do obliczeń.
    pub fn nominalHz(self: *const ReplayBackend) u64 {
        return self.image.nominal_hz;
    }

    pub fn sourceName(self: *const ReplayBackend) []const u8 {
        if (self.image.source.len != 0) return self.image.source;
        return "replay";
    }

    pub fn reads(self: *const ReplayBackend) u64 {
        return self.total_reads;
    }

    fn vtable() *const msr.Backend.VTable {
        const impl = struct {
            fn read(ctx: *anyopaque, logical_cpu: u16, index: u32) msr.MsrRead {
                const self: *ReplayBackend = @ptrCast(@alignCast(ctx));
                return self.readMsr(logical_cpu, index);
            }
            fn onlineCount(ctx: *anyopaque) u16 {
                const self: *const ReplayBackend = @ptrCast(@alignCast(ctx));
                return self.onlineCpuCount();
            }
            fn caps(ctx: *anyopaque) msr.CapabilitySet {
                const self: *const ReplayBackend = @ptrCast(@alignCast(ctx));
                return self.capabilities();
            }
            fn now(ctx: *anyopaque) u64 {
                const self: *const ReplayBackend = @ptrCast(@alignCast(ctx));
                return self.monotonicNanos();
            }
            fn name(ctx: *anyopaque) []const u8 {
                const self: *const ReplayBackend = @ptrCast(@alignCast(ctx));
                return self.sourceName();
            }
        };
        return &struct {
            const v: msr.Backend.VTable = .{
                .readMsr = impl.read,
                .onlineCpuCount = impl.onlineCount,
                .capabilities = impl.caps,
                .monotonicNanos = impl.now,
                .sourceName = impl.name,
            };
        }.v;
    }
};

const testing = std.testing;

fn sampleImage() Captured {
    var img = Captured{ .source = "synthetic", .present = true };
    img.cpu_count = 1;
    // Trzy klatki: t=0, t=250ms, t=500ms. Licznik rośnie o 600 na klatkę.
    img.reads[0] = .{ .timestamp_ns = 0, .logical_cpu = 0, .msr_index = 0xE8, .value = 100 };
    img.reads[1] = .{ .timestamp_ns = 0, .logical_cpu = 0, .msr_index = 0xE7, .value = 200 };
    img.reads[2] = .{ .timestamp_ns = 250_000_000, .logical_cpu = 0, .msr_index = 0xE8, .value = 700 };
    img.reads[3] = .{ .timestamp_ns = 250_000_000, .logical_cpu = 0, .msr_index = 0xE7, .value = 800 };
    img.reads[4] = .{ .timestamp_ns = 500_000_000, .logical_cpu = 0, .msr_index = 0xE8, .value = 1300 };
    img.reads[5] = .{ .timestamp_ns = 500_000_000, .logical_cpu = 0, .msr_index = 0xE7, .value = 1400 };
    img.reads_len = 6;
    return img;
}

test "round-trip: format i parse odtwarzaja surowe odczyty" {
    const reads = [_]RawRead{
        .{ .timestamp_ns = 0, .logical_cpu = 0, .msr_index = 0xE8, .value = 0x1111 },
        .{ .timestamp_ns = 250_000_000, .logical_cpu = 0, .msr_index = 0xE8, .value = 0x3333 },
    };
    const fails = [_]Failure{
        .{ .timestamp_ns = 0, .logical_cpu = 1, .msr_index = 0xE8, .kind = .permission_denied },
    };

    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, "synthetic", &reads, &fails, 2, 3_800_000_000);
    const text = w.buffered();

    const got = try parse(text);
    try testing.expect(got.present);
    try testing.expectEqual(@as(u16, 2), got.cpu_count);
    try testing.expectEqual(@as(usize, 2), got.reads_len);
    try testing.expectEqual(@as(usize, 1), got.failures_len);
    try testing.expectEqual(reads[1].value, got.reads[1].value);
    try testing.expectEqual(reads[1].timestamp_ns, got.reads[1].timestamp_ns);
    try testing.expectEqual(msr.MsrError.permission_denied, got.failures[0].kind);
    // Wartości wracają jako **surowe rejestry**, nie jako zinterpretowane MHz.
    try testing.expectEqual(@as(u64, 0x1111), got.reads[0].value);
}

test "replay: oddaje bajty z pliku, nie wynik obliczony" {
    var img = sampleImage();
    var be = ReplayBackend.init(&img);
    // Gdyby replay zwracał „MHz", znaczyłoby to, że wykonuje obliczenia — i test
    // round-trip delty przestałby cokolwiek sprawdzać.
    try testing.expectEqual(@as(u64, 100), be.readMsr(0, 0xE8).get().?);
}

test "replay: brak rekordu to unsupported, nigdy zero" {
    var img = sampleImage();
    var be = ReplayBackend.init(&img);
    const r = be.readMsr(0, 0x999);
    try testing.expectEqual(msr.MsrError.unsupported, r.status.err);
    // `get()` musi zwrócić null — inaczej ktoś mógłby wyświetlić 0 jako
    // odczyt, a to klasyczny sposób na zmyśloną temperaturę.
    try testing.expect(r.get() == null);
}

test "replay: zapisany blad wraca jako ten sam blad" {
    var img = Captured{ .source = "synthetic", .present = true };
    img.cpu_count = 1;
    img.failures[0] = .{
        .timestamp_ns = 0,
        .logical_cpu = 0,
        .msr_index = 0xE8,
        .kind = .permission_denied,
    };
    img.failures_len = 1;

    var be = ReplayBackend.init(&img);
    try testing.expectEqual(msr.MsrError.permission_denied, be.readMsr(0, 0xE8).status.err);
}

test "replay: kolejne klatki daja kolejne wartosci licznika" {
    var img = sampleImage();
    var be = ReplayBackend.init(&img);
    try testing.expectEqual(@as(usize, 3), be.frameCount());
    try testing.expectEqual(@as(u64, 0), be.monotonicNanos());
    try testing.expectEqual(@as(u64, 100), be.readMsr(0, 0xE8).get().?);

    try testing.expect(be.advanceToNextFrame());
    try testing.expectEqual(@as(u64, 250_000_000), be.monotonicNanos());
    try testing.expectEqual(@as(u64, 700), be.readMsr(0, 0xE8).get().?);

    try testing.expect(be.advanceToNextFrame());
    try testing.expectEqual(@as(u64, 1300), be.readMsr(0, 0xE8).get().?);

    // Na ostatniej klatce kursor jeszcze **na niej stoi**, więc sekwencja nie jest
    // zakończona. Dopiero próba przejścia dalej przesuwa kursor poza koniec.
    try testing.expect(!be.isFinished());
    try testing.expect(!be.advanceToNextFrame());
    try testing.expect(be.isFinished());
    try testing.expectEqual(@as(usize, 0), be.remainingFrames());
}

test "replay: zegare z pliku daja te same delty co zegar sterowany recznie" {
    // Sedno: replay ma robić **te same obliczenia** co backend sterowany
    // jawnym zegarem. Ten sam wzrost licznika na klatkę musi dać tę samą deltę.
    var img = sampleImage();
    var be = ReplayBackend.init(&img);
    const a0 = be.readMsr(0, 0xE8).get().?;
    const m0 = be.readMsr(0, 0xE7).get().?;
    const t0 = be.monotonicNanos();
    try testing.expect(be.advanceToNextFrame());
    const a1 = be.readMsr(0, 0xE8).get().?;
    const m1 = be.readMsr(0, 0xE7).get().?;
    const t1 = be.monotonicNanos();

    try testing.expectEqual(@as(u64, 600), a1 - a0);
    try testing.expectEqual(@as(u64, 600), m1 - m0);
    try testing.expectEqual(@as(u64, 250_000_000), t1 - t0);
}

test "replay: zdolnosci wynikaja z zawartosci pliku, nie z deklaracji" {
    // Plik pusty: backend nie deklaruje niczego. Inaczej silnik pytałby o
    // rejestry, na które zawsze dostaje `unsupported`, i raportowałby to jako
    // awarię czujnika zamiast braku zdolności backendu.
    var empty_img = Captured{ .source = "synthetic", .present = false };
    var be0 = ReplayBackend.init(&empty_img);
    try testing.expectEqual(@as(usize, 0), be0.capabilities().bits);

    var img = sampleImage();
    var be1 = ReplayBackend.init(&img);
    const caps = be1.capabilities();
    try testing.expect(caps.has(.msr_read));
    try testing.expect(caps.has(.per_cpu_msr_read));
    try testing.expect(caps.has(.aperf_mperf));
    // Plik nie zaw energii ani temperatury, więc tych zdolności **nie** deklarujemy.
    try testing.expect(!caps.has(.energy_counter));
    try testing.expect(!caps.has(.temperature_raw));
    try testing.expect(!caps.has(.platform_utilization));
}

test "stary capture bez sekcji telemetry: brak danych, nie blad" {
    // Plik `.cpuimg` zapisany przed Etapem 3A nie ma linii `telem`.
    const old_cpuimg =
        \\# FerrumScope capture
        \\# source: 5800X3D
        \\ferrum-cpuimg 1
        \\arch x86_64
        \\max_basic 0xD
        \\max_extended 0x8000_001E
        \\
        \\leaf 0x00000000 sub 0x00 eax=0x0000000D ebx=0x68747541 ecx=0x444D4163 edx=0x69746E65
    ;
    const got = try parseCpuimgSection(old_cpuimg);
    // `null` = sekcji nie ma. To nie błąd i nie „capture uszkodzony".
    try testing.expect(got == null);
}

test "sekcja telemetry w pliku cpuimg jest wyciagana i parsowana" {
    const mixed =
        \\ferrum-cpuimg 1
        \\arch x86_64
        \\leaf 0x00000001 sub 0x00 eax=0x00A20F12 ebx=0x02100800 ecx=0xFED83203 edx=0x178BFBFF
        \\telem cpu_count 1
        \\telem read 0 0 0xE8 0x64
        \\telem read 250000000 0 0xE8 0x2C8
        \\telem fail 0 0 0x1B8 permission_denied
    ;
    const got = (try parseCpuimgSection(mixed)).?;
    try testing.expect(got.present);
    try testing.expectEqual(@as(u16, 1), got.cpu_count);
    try testing.expectEqual(@as(usize, 2), got.reads_len);
    try testing.expectEqual(@as(u64, 0x64), got.reads[0].value);
    try testing.expectEqual(@as(usize, 1), got.failures_len);
    try testing.expectEqual(@as(usize, 2), got.frameCount());
}

test "uszkodzony rekord telemetry odrzuca caly plik" {
    // Tolerowanie uszkodzonej linii dałoby po cichu dane stracone — w pliku
    // diagnostycznym to najgorsza możliwa porażka: brak danych wyglądałby jak
    // „czujnik milczał".
    const bad =
        \\ferrum-telemimg 1
        \\telem read 0 0 0xE8
    ;
    try testing.expectError(error.Malformed, parse(bad));

    const bad_hex =
        \\ferrum-telemimg 1
        \\telem read 0 0 0xE8 notanumber
    ;
    try testing.expectError(error.Malformed, parse(bad_hex));

    const bad_kw =
        \\ferrum-telemimg 1
        \\telem temperature 60
    ;
    try testing.expectError(error.Malformed, parse(bad_kw));

    const bad_err =
        \\ferrum-telemimg 1
        \\telem fail 0 0 0xE8 niematbledu
    ;
    try testing.expectError(error.Malformed, parse(bad_err));
}

test "nieznana wersja pliku telemetry jest odrzucona" {
    const future =
        \\ferrum-telemimg 99
        \\telem read 0 0 0xE8 0x1
    ;
    try testing.expectError(error.UnsupportedFormat, parse(future));
}

test "plik bez sygnatury to BadMagic" {
    try testing.expectError(error.BadMagic, parse("read 0 0 0xE8 0x1\n"));
    try testing.expectError(error.BadMagic, parse(""));
}

test "replay: silnik liczy efektywną czestotliwość z surowych liczników" {
    // Sedno wymagania „replay wykonuje te same obliczenia co backend
    // sprzętowy": plik trzyma wyłącznie surowe APERF/MPERF, a wartość
    // w Hz wylicza ten sam silnik i ten sam dekoder, co dla backendu
    // na żywo. Gdyby zapis zawierał wynik, ten test niczego by nie sprawdzał.
    const eng_mod = @import("../telemetry/engine.zig");
    const cat = @import("../telemetry/catalog.zig");
    const alloc = testing.allocator;

    const nominal: u64 = 1_000_000_000; // 1 GHz nominalnie
    // APERF rośnie o 1400, MPERF o 1000 na klatkę, czyli boost 1,4x.
    const frames = [_][2]u64{
        .{ 0, 0 },
        .{ 1400, 1000 },
        .{ 2800, 2000 },
    };
    var img = Captured{ .source = "test", .present = true, .cpu_count = 1, .nominal_hz = nominal };
    for (frames, 0..) |f, i| {
        const t: u64 = @as(u64, i) * 250 * std.time.ns_per_ms;
        img.reads[img.reads_len] = .{ .timestamp_ns = t, .logical_cpu = 0, .msr_index = 0xE8, .value = f[0] };
        img.reads_len += 1;
        img.reads[img.reads_len] = .{ .timestamp_ns = t, .logical_cpu = 0, .msr_index = 0xE7, .value = f[1] };
        img.reads_len += 1;
    }

    var be = ReplayBackend.init(&img);
    const metric = cat.find("cpu.core.effective_frequency").?;
    var st = try eng_mod.FreqState.init(alloc, nominal, 1, .b64);
    defer st.deinit(alloc);
    const pollers = [_]eng_mod.Poller{.{
        .descriptor = metric.descriptor,
        .instance = 0,
        .read = eng_mod.pollEffectiveFrequency,
        .ctx = @ptrCast(&st),
    }};
    var en = try eng_mod.Engine.init(alloc, be.api(), &pollers, 16);
    defer en.deinit();

    // Klatka 0 to stan początkowy — częstotliwość wymaga dwóch punktów.
    _ = en.poll(be.monotonicNanos());

    try testing.expect(be.advanceToNextFrame());
    const s1 = en.poll(be.monotonicNanos());
    // Kopiujemy wartość **przed** następnym `poll`, bo zwracany slice jest
    // unieważniany przez kolejny cykl.
    const v1 = s1[0].get().?;
    // 1400/1000 × 1 GHz = 1,4 GHz
    try testing.expectEqual(@as(u64, 1_400_000_000), v1);

    try testing.expect(be.advanceToNextFrame());
    const s2 = en.poll(be.monotonicNanos());
    // Druga klatka daje tę samą wartość: stosunek APERF do MPERF się nie zmienił.
    try testing.expectEqual(@as(u64, 1_400_000_000), s2[0].get().?);
}

test "replay: brak nominal_hz uniemożliwia obliczenie, zamiast zgadywać MHz" {
    // APERF i MPERF to **stosunek**. Bez skali w Hz nie ma czego skalować, więc
    // wartość musi zniknąć, a nie stać się „chybnym" oszacowaniem.
    const eng_mod = @import("../telemetry/engine.zig");
    const cat = @import("../telemetry/catalog.zig");
    const alloc = testing.allocator;

    var img = Captured{ .source = "bez-skali", .present = true, .cpu_count = 1, .nominal_hz = 0 };
    img.reads[0] = .{ .timestamp_ns = 0, .logical_cpu = 0, .msr_index = 0xE8, .value = 0 };
    img.reads[1] = .{ .timestamp_ns = 0, .logical_cpu = 0, .msr_index = 0xE7, .value = 0 };
    img.reads[2] = .{ .timestamp_ns = 250_000_000, .logical_cpu = 0, .msr_index = 0xE8, .value = 1400 };
    img.reads[3] = .{ .timestamp_ns = 250_000_000, .logical_cpu = 0, .msr_index = 0xE7, .value = 1000 };
    img.reads_len = 4;

    var be = ReplayBackend.init(&img);
    try testing.expectEqual(@as(u64, 0), be.nominalHz());

    const metric = cat.find("cpu.core.effective_frequency").?;
    var st = try eng_mod.FreqState.init(alloc, 0, 1, .b64);
    defer st.deinit(alloc);
    const pollers = [_]eng_mod.Poller{.{
        .descriptor = metric.descriptor,
        .instance = 0,
        .read = eng_mod.pollEffectiveFrequency,
        .ctx = @ptrCast(&st),
    }};
    var en = try eng_mod.Engine.init(alloc, be.api(), &pollers, 16);
    defer en.deinit();

    _ = en.poll(be.monotonicNanos());
    try testing.expect(be.advanceToNextFrame());
    const s = en.poll(be.monotonicNanos());
    // Próba istnieje, ale **nie ma wartości** — i to jest właściwa odpowiedź.
    try testing.expect(s[0].get() == null);
    try testing.expect(s[0].status != .ok);
}

test "replay: nieznany rejestr z przyszłej wersji nie psuje sekwencji" {
    // Zapis z nowszej wersji programu może zawierać rejestr, którego my nie
    // znamy. Replay jest **transportem surowych bajtów**: jeśli rekord jest w
    // pliku, zwraca go wiernie i nie ma prawa go odfiltrowywać — filtracja
    // zabiłaby możliwość odtworzenia zapisu z innej wersji.
    //
    // Odporność na przyszłość polega więc nie na replayu, tylko na tym, że
    // **dekoder nigdy nie prosi o rejestr, którego nie zna**.
    const future_msr: u32 = 0xDEAD;
    const reads = [_]RawRead{
        .{ .timestamp_ns = 0, .logical_cpu = 0, .msr_index = 0xE8, .value = 100 },
        .{ .timestamp_ns = 0, .logical_cpu = 0, .msr_index = future_msr, .value = 7 },
    };
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try format(&w, "przyszlosc", &reads, &.{}, 1, 1000);

    // Plik z nieznanym rejestrem parsuje się bez błędu i zachowuje go w całości.
    const got = try parse(w.buffered());
    try testing.expectEqual(@as(usize, 2), got.reads_len);

    var be = ReplayBackend.init(&got);
    // Replay oddaje zapisany bajt wiernie — jest transportem, nie filtrem.
    try testing.expectEqual(@as(u64, 7), be.readMsr(0, future_msr).get().?);
    // Rejestr znany czyta się bez zakłóceń.
    try testing.expectEqual(@as(u64, 100), be.readMsr(0, 0xE8).get().?);

    // Właściwy mechanizm: dekoder czyta wyłącznie rejestry, które **zna**
    // (tu APERF i MPERF). Nieznany indeks nigdy nie jest odpytywany, więc nie
    // może zostać zinterpretowany ani namieszać w wyniku. To jest cała
    // kompatybilność w przód — nie żadna walidacja po stronie transportu.
    const known = [_]u32{ 0xE8, 0xE7 };
    for (known) |idx| {
        _ = be.readMsr(0, idx);
    }
    try testing.expect(be.capabilities().has(.aperf_mperf));
}
