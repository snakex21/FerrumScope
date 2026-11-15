//! FerrumScope — punkt wejścia CLI (Etap 1).
//!
//! Świadomie mały. Prezentacja jest oddzielona od identyfikacji: CLI wywołuje
//! `probe -> decode -> hwdb` i formatuje gotowy `CpuInfo`. Żadnej logiki
//! „czy to Ryzen" nie ma w tym pliku — ona jest w `decode/` i w bazie.
//!
//! Polecenia (Etap 1):
//!   ferrumscope                     skrót na `cpu`
//!   ferrumscope cpu [--json|--raw]   opis procesora
//!   ferrumscope explain cpu          skąd wzięliśmy każde pole
//!   ferrumscope replay <plik.cpuimg> ten sam pipeline na pliku capture
//!   ferrumscope hwdb                statystyki wbudowanej bazy

const std = @import("std");
const ferrum = @import("root.zig");

const core = ferrum.core;
const model = core.model;
const hwdb_mod = ferrum.db.hwdb;
const embedded = @import("db/embedded.zig");
const replay_mod = ferrum.platform.replay;
const native = ferrum.platform.native;
const backend_mod = ferrum.platform.backend;
const probe = ferrum.probe.cpu;
const decoder = ferrum.decode.cpu_x86;
const cpuimg = ferrum.capture.cpuimg;
const telemimg = ferrum.capture.telemimg;
const msr = ferrum.telemetry.msr;
const metrics = ferrum.telemetry.metrics;
const catalog = ferrum.telemetry.catalog;
const engine = ferrum.telemetry.engine;
const fake = ferrum.telemetry.fake;
const win_msr = ferrum.telemetry.windows_msr;

const present = @import("present.zig");

const version = present.version;

var stdout_buf: [16 * 1024]u8 = undefined;
var stderr_buf: [4 * 1024]u8 = undefined;

var stdout_w: std.fs.File.Writer = undefined;
var stderr_w: std.fs.File.Writer = undefined;
var stdout_ready = false;
var stderr_ready = false;

/// Writer stdout trzymamy w zmiennej globalnej: `File.writer()` zwraca strukturę,
/// której nie wolno traktować jako wartości tymczasowej. Bufor wymaga też
/// jawnego `flush()` — `main()` robi to w `defer`.
fn out() *std.Io.Writer {
    if (!stdout_ready) {
        stdout_w = std.fs.File.stdout().writer(&stdout_buf);
        stdout_ready = true;
    }
    return &stdout_w.interface;
}

fn errw() *std.Io.Writer {
    if (!stderr_ready) {
        stderr_w = std.fs.File.stderr().writer(&stderr_buf);
        stderr_ready = true;
    }
    return &stderr_w.interface;
}

// Literały `\\` w Zig to literały wieloliniowe — każda linia zawiera
// znak nowej linii na końcu. Kontynuacja `"\` z C nie istnieje w Zig.
const Usage = "ferrumscope " ++ version ++ " - identyfikacja sprzętu (Etap 1: CPU)\n" ++
    \\
    \\Użycie:
    \\  ferrumscope cpu                 opis procesora
    \\  ferrumscope cpu --json          wynik w JSON
    \\  ferrumscope cpu --raw           surowe liście CPUID
    \\  ferrumscope explain cpu         skąd wzięliśmy każde pole
    \\  ferrumscope replay <plik>       uruchom pipeline na pliku capture (.cpuimg)
    \\  ferrumscope replay <plik> --json
    \\  ferrumscope compare-captures <a> <b>  porownaj dwa pliki capture
    \\  ferrumscope hwdb                statystyki wbudowanej bazy
    \\  ferrumscope sensors               stan czujnikow (bez sterownika: 'unavailable')
    \\  ferrumscope sensors --synthetic   backend testowy — wartosci NIE sa pomiarem
    \\  ferrumscope sensors --replay <f>  odtworz z pliku telemetry
    \\  ferrumscope sensors --watch       przebieg klatka po klatce
    \\  ferrumscope sensors --bench       koszt cyklu pollingu (fake/replay)
    \\  ferrumscope sensors --json        wynik w JSON
    \\  ferrumscope capture <plik>     zapisz surowy obraz CPUID do pliku .cpuimg
    \\  ferrumscope version             wersja
    \\
;

pub fn main() !u8 {
    defer {
        out().flush() catch {};
        errw().flush() catch {};
    }
    // `GeneralPurposeAllocator.allocator()` przyjmuje `*Self`, więc `gpa`
    // musi być zmienną, nie stałą.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);

    if (argv.len < 2) {
        try out().writeAll(Usage);
        return 0;
    }

    const cmd = argv[1];
    if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) {
        try out().writeAll(Usage);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "version")) {
        try out().print("ferrumscope {s}\n", .{version});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "capture")) {
        if (argv.len < 3) {
            try errw().print("ferrumscope: brak ścieżki wyjściowej dla capture\n", .{});
            return 2;
        }
        return cmdCapture(argv[2]);
    }
    if (std.mem.eql(u8, cmd, "hwdb")) {
        return cmdHwdb();
    }
    if (std.mem.eql(u8, cmd, "explain")) {
        if (argv.len < 3 or !std.mem.eql(u8, argv[2], "cpu")) {
            try errw().print("ferrumscope: 'explain' obsługuje na razie tylko 'cpu'\n", .{});
            return 2;
        }
        return cmdCpu(.explain);
    }
    if (std.mem.eql(u8, cmd, "compare-captures")) {
        if (argv.len < 4) {
            try errw().print("ferrumscope: 'compare-captures' wymaga dwóch plików capture\n", .{});
            return 2;
        }
        return cmdCompareCaptures(alloc, argv[2], argv[3]);
    }
    if (std.mem.eql(u8, cmd, "replay")) {
        if (argv.len < 3) {
            try errw().print("ferrumscope: brak ścieżki pliku capture\n", .{});
            return 2;
        }
        return cmdReplay(alloc, argv[2], argv[3..]);
    }
    if (std.mem.eql(u8, cmd, "cpu") or cmd.len == 0) {
        // Flagi po `cpu` wybierają tryb prezentacji. Bez tej pętli `--json`
        // i `--raw` były cicho ignorowane — najgorszy rodzaj błędu: użytkownik
        // prosi o dane surowe, a dostaje dane przetworzone.
        var mode: Mode = .text;
        for (argv[2..]) |a| {
            if (std.mem.eql(u8, a, "--json")) {
                mode = .json;
            } else if (std.mem.eql(u8, a, "--raw")) {
                mode = .raw;
            } else if (std.mem.eql(u8, a, "--explain")) {
                mode = .explain;
            } else {
                try errw().print("ferrumscope: nieznana opcja '{s}' dla 'cpu'\n", .{a});
                return 2;
            }
        }
        return cmdCpu(mode);
    }

    if (std.mem.eql(u8, cmd, "sensors")) {
        return cmdSensors(alloc, argv[2..]);
    }

    try errw().print("ferrumscope: nieznane polecenie '{s}'\n\n", .{cmd});
    try errw().writeAll(Usage);
    return 2;
}

const Mode = enum { text, json, raw, explain };

fn cmdCpu(mode: Mode) !u8 {
    const b = native.create();
    const res = probe.run(b);
    if (res.getStatus() != .ok) {
        try errw().print("ferrumscope: nie mogę odczytać CPU ({s})\n", .{res.getStatus().toSlice()});
        return 1;
    }
    const raw_info = res.unwrap().?;
    const db = embedded.load() catch {
        try errw().print("ferrumscope: wbudowana baza jest uszkodzona — przebuduj projekt\n", .{});
        return 1;
    };
    return report(raw_info, db, mode, "native");
}

// ---------------------------------------------------------------------------
// `sensors` — stan czujnikow
// ---------------------------------------------------------------------------

/// Backend bez dostępu do MSR — definicja w `present.zig`, wspólna z GUI.
const NoMsrBackend = present.NoMsrBackend;

/// Nominalna częstotliwość używana w trybie syntetycznym.
///
/// APERF/MPERF dają **stosunek** cykli, więc bez skali w Hz nie ma czego
/// skalować. W trybie syntetycznym przyjmujemy typową wartość i **oznaczamy ją**
/// jako założenie testowe — to nie jest pomiar procesora użytkownika.
const synthetic_nominal_hz: u64 = present.nominal_hz_assumed;
/// Syntetyczne „pod boostem": APERF rośnie szybciej niż MPERF.
const synthetic_boost: f64 = 1.40;

fn cmdSensors(alloc: std.mem.Allocator, rest: [][:0]u8) !u8 {
    var watch = false;
    var json = false;
    var bench = false;
    var synthetic = false;
    var replay_path: ?[]const u8 = null;

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.eql(u8, a, "--watch")) {
            watch = true;
        } else if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, a, "--bench")) {
            bench = true;
        } else if (std.mem.eql(u8, a, "--synthetic")) {
            synthetic = true;
        } else if (std.mem.eql(u8, a, "--replay")) {
            i += 1;
            if (i >= rest.len) {
                try errw().print("ferrumscope: --replay wymaga ścieżki pliku\n", .{});
                return 2;
            }
            replay_path = rest[i];
        } else {
            try errw().print("ferrumscope: nieznana opcja '{s}' dla 'sensors'\n", .{a});
            return 2;
        }
    }
    if (replay_path != null and synthetic) {
        try errw().print("ferrumscope: --replay i --synthetic wykluczają się\n", .{});
        return 2;
    }
    if (bench and replay_path == null and !synthetic) synthetic = true;

    if (replay_path) |p| return sensorsReplay(alloc, p, watch, json);
    if (synthetic) return sensorsSynthetic(alloc, watch, json, bench);
    return sensorsNative(alloc, watch, json, bench);
}

/// Brak uprzywilejowanego backendu.
///
/// Dla `--watch` i `--bench` przechodzimy na backend syntetyczny, bo obserwować
/// i mierzyć nie ma czego. Robimy to **z ostrzeżeniem**, żeby nikt nie wziął
/// wartości syntetycznej za pomiar.
fn sensorsNative(alloc: std.mem.Allocator, watch: bool, json: bool, bench: bool) !u8 {
    var tr = win_msr.deviceIoTransport{};
    if (win_msr.Backend.open(tr.transport())) |opened| {
        var b = opened;
        defer b.close();
        if (bench) return runBenchReal(alloc, b.api());
        return runPolls(alloc, b.api(), watch, json, null, null, null);
    } else |e| {
        // Konkretna przyczyna, nie „coś nie działa". `NotInstalled` i
        // `PermissionDenied` mają **różne naprawy**: zainstaluj sterownik
        // kontra uruchom admina.
        try errw().print("ferrumscope: {s}\n", .{win_msr.openErrorDetail(e)});
        if (watch or bench) {
            try errw().print(
                "ferrumscope: przechodzę na dane SYNTETYCZNE (to NIE jest pomiar)\n\n",
                .{},
            );
            return sensorsSynthetic(alloc, watch, json, bench);
        }
        return printSensors(NoMsrBackend.create(), null, json, false);
    }
}

/// Pomiar kosztu cyklu na **prawdziwym** backendzie.
///
/// Osobno od `--bench` syntetycznego (§18): te liczby zawierają koszt przejścia
/// do jądra, którego pomiar na backendzie sztucznym w ogóle nie obejmuje.
/// Mieszane wyniki sugerowałyby, że tani backend jest „w miarę prawdziwy",
/// a jest o rzędy wielkości tańszy.
fn runBenchReal(alloc: std.mem.Allocator, api: msr.Backend) !u8 {
    const w = out();
    try w.print("FerrumScope sensors --bench  [backend REALNY: {s}]\n", .{api.sourceName()});
    try w.print("Tu są koszty przejść user/kernel. Dla porównania użyj --synthetic.\n\n", .{});

    const metric = catalog.find("cpu.core.effective_frequency").?;
    const cpus = api.onlineCpuCount();
    try w.print("  CPU online: {d}\n", .{cpus});
    try w.print("  interwał    cykli     ns/cykl     odczytów MSR/cykl\n", .{});
    try w.print("  ----------  ------   ---------   ------------------\n", .{});

    const intervals = [_]u64{
        100 * std.time.ns_per_ms,
        250 * std.time.ns_per_ms,
        500 * std.time.ns_per_ms,
        std.time.ns_per_s,
    };
    for (intervals) |iv| {
        var freq_state = try engine.FreqState.init(alloc, 1, 1, .b64);
        defer freq_state.deinit(alloc);
        const pollers = [_]engine.Poller{.{
            .descriptor = metric.descriptor,
            .instance = 0,
            .read = engine.pollEffectiveFrequency,
            .ctx = @ptrCast(&freq_state),
        }};
        var eng = try engine.Engine.init(alloc, api, &pollers, 16);
        defer eng.deinit();

        _ = eng.poll(api.monotonicNanos());
        const cycles: usize = 200;
        var timer = try std.time.Timer.start();
        for (0..cycles) |_| {
            _ = eng.poll(api.monotonicNanos());
        }
        const elapsed = timer.read();
        try w.print("  {d: >7} ms  {d: >6}   {d: >9.0}   {d: >18}\n", .{
            iv / std.time.ns_per_ms, cycles, @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(cycles)),
            cpus * 2,
        });
    }
    return 0;
}

fn sensorsSynthetic(alloc: std.mem.Allocator, watch: bool, json: bool, bench: bool) !u8 {
    const aperf_per_s: u64 = @intFromFloat(@as(f64, @floatFromInt(synthetic_nominal_hz)) * synthetic_boost);
    var be = try fake.Backend.init(alloc, .{
        .cpu_count = 1,
        .capabilities = catalog.allCapabilities(),
        .source_name = "syntetyczny (NIE pomiar)",
        .registers = &.{
            .{
                .msr_index = msr.Msr.aperf,
                .behavior = .{ .time_ramped = .{ .start = 0, .per_second = aperf_per_s } },
            },
            .{
                .msr_index = msr.Msr.mperf,
                .behavior = .{ .time_ramped = .{ .start = 0, .per_second = synthetic_nominal_hz } },
            },
        },
    });
    defer be.deinit(alloc);

    if (bench) return runBench(alloc, be.api(), synthetic_nominal_hz);
    return runPolls(alloc, be.api(), watch, json, null, null, &be);
}

/// Replay z pliku. Przyjmuje i standalone `.telemimg`, i `.cpuimg` z sekcją.
fn sensorsReplay(alloc: std.mem.Allocator, path: []const u8, watch: bool, json: bool) !u8 {
    const text = std.fs.cwd().readFileAlloc(alloc, path, 32 * 1024 * 1024) catch |e| {
        try errw().print("ferrumscope: nie mogę czytać '{s}': {t}\n", .{ path, e });
        return 1;
    };
    defer alloc.free(text);

    var img: telemimg.Captured = undefined;
    if (telemimg.parseCpuimgSection(text)) |maybe| {
        img = maybe orelse {
            // Stary capture sprzed Etapu 3A: brak sekcji to **nie błąd**, tylko
            // „nie ma danych". Mylilibyśmy użytkownika, gdybyśmy zgłosili
            // uszkodzony plik.
            try errw().print("ferrumscope: '{s}' nie zawiera sekcji telemetry (stary format)\n", .{path});
            return 1;
        };
    } else |_| {
        img = telemimg.parse(text) catch |e| {
            try errw().print("ferrumscope: '{s}' nie jest plikiem telemetry: {t}\n", .{ path, e });
            return 1;
        };
    }
    if (!img.hasTelemetry()) {
        try errw().print("ferrumscope: '{s}' nie zawiera żadnych odczytów telemetry\n", .{path});
        return 1;
    }

    var be = telemimg.ReplayBackend.init(&img);
    return runPolls(alloc, be.api(), watch, json, &be, &img, null);
}

/// Wspólna pętla pollingu: rozruch, potem klatki.
///
/// `now_of` i `advance` pozwalają sterować zegarem. Backend sterowany
/// syntetycznie ma własne `advanceNanos`, a replay przesuwa kursor klatek —
/// oba dają ten sam czas monotoniczny, więc silnik nie widzi różnicy.
fn runPolls(
    alloc: std.mem.Allocator,
    api: msr.Backend,
    watch: bool,
    json: bool,
    replay: ?*telemimg.ReplayBackend,
    img: ?*const telemimg.Captured,
    clock: ?*fake.Backend,
) !u8 {
    const nominal = if (img) |i| i.nominal_hz else synthetic_nominal_hz;
    if (nominal == 0) {
        try errw().print(
            "ferrumscope: brak nominal_hz w pliku — efektywna częstotliwość jest nieodtwarzalna\n",
            .{},
        );
        return 1;
    }

    const metric = catalog.find("cpu.core.effective_frequency").?;
    var freq_state = try engine.FreqState.init(alloc, nominal, 1, .b64);
    defer freq_state.deinit(alloc);

    const pollers = [_]engine.Poller{.{
        .descriptor = metric.descriptor,
        .instance = 0,
        .read = engine.pollEffectiveFrequency,
        .ctx = @ptrCast(&freq_state),
    }};
    var eng = try engine.Engine.init(alloc, api, &pollers, 16);
    defer eng.deinit();

    const w = out();
    // Rozruch: pierwsza próbka nie daje częstotliwości (potrzeba dwóch punktów).
    // Bez niego `--watch` zacząłby od pustego stanu, a jednorazowy tryb
    // pokazałby „pierwsza próbka" zamiast liczby.
    _ = eng.poll(api.monotonicNanos());

    if (watch) {
        while (true) {
            if (replay) |rp| {
                if (!rp.advanceToNextFrame()) break;
            } else if (clock) |fb| {
                // Przesuwamy **zegar backendu**, nie `sleep`. `sleep` ruszyłby
                // tylko czas rzeczywisty, a liczniki `time_ramped` liczą się od
                // własnego zegara — dwie niezależne osie, delta zerowa i
                // efektywna częstotliwość nigdy by nie powstała.
                fb.advanceNanos(synthetic_interval);
            } else {
                // Backend rzeczywisty: czekamy **naprawdę**. To jedyna ścieżka,
                // na której interwał odczytu jest rzeczywistym czasem, a nie
                // krokiem w zapisanym pliku.
                std.Thread.sleep(synthetic_interval);
            }
            const samples = eng.poll(api.monotonicNanos());
            if (json) {
                try printSensorsJson(w, api, samples);
            } else {
                try printSensorsText(w, api, samples);
            }
            try w.flush();
        }
        return 0;
    }

    // Jednorazowo: przechodzimy do ostatniej klatki, żeby stan był kompletny.
    if (replay) |rp| {
        while (rp.advanceToNextFrame()) {}
    } else if (clock) |fb| {
        fb.advanceNanos(synthetic_interval);
    } else {
        std.Thread.sleep(synthetic_interval);
    }
    const samples = eng.poll(api.monotonicNanos());
    return printSensors(api, samples, json, replay != null);
}

const synthetic_interval: u64 = 250 * std.time.ns_per_ms;

/// Wypisuje stan metryk: wartość tam, gdzie jest, i powód tam, gdzie nie ma.
fn printSensors(api: msr.Backend, samples: ?[]const metrics.Sample, json: bool, real: bool) !u8 {
    const w = out();
    if (json) {
        try printSensorsJson(w, api, samples);
    } else {
        try printSensorsText(w, api, samples);
    }
    // Brak backendu to stan do zgłoszenia, nie awaria programu: użytkownik
    // dostaje pełny raport zamiast pustego ekranu i kodu błędu.
    return if (real or samples == null) 0 else 0;
}

fn printSensorsHeader(w: *std.Io.Writer, api: msr.Backend) !void {
    var buf: [256]u8 = undefined;
    try w.print("FerrumScope sensors  [źródło: {s}]\n", .{api.sourceName()});
    const caps = api.capabilities();
    if (caps.bits == 0) {
        try w.print("  Zdolności backendu: brak — żadna metryka sprzętowa nie może zostać odczytana\n", .{});
    } else {
        try w.print("  Zdolności backendu: {s}\n", .{capsSummary(caps, &buf)});
    }
    try w.print("\n", .{});
}

fn printSensorsText(w: *std.Io.Writer, api: msr.Backend, samples: ?[]const metrics.Sample) !void {
    try printSensorsHeader(w, api);
    const caps = api.capabilities();
    for (catalog.metrics_available) |m| {
        var lbl: [28]u8 = undefined;
        var shown = false;
        if (samples) |list| {
            if (findSample(list, m.descriptor.id)) |s| {
                if (s.get()) |v| {
                    const scaled = @as(f64, @floatFromInt(v)) * m.descriptor.unit.scale();
                    try w.print("  {s} : {d:.2} {s}\n", .{
                        padLabel(&lbl, m.descriptor.label), scaled, unitLabel(m.descriptor.unit),
                    });
                } else {
                    // Próbka **jest**, ale nie ma wartości. Najdokładniejszy
                    // powód to status tej próbki, a nie stan katalogu — inaczej
                    // metryka dostępna zgłaszałaby „brak wymaganych zdolności",
                    // co jest sprzeczne z nagłówkiem powyżej.
                    try w.print("  {s} : {s} ({s})\n", .{
                        padLabel(&lbl, m.descriptor.label), @tagName(s.status), sampleReason(s),
                    });
                }
                shown = true;
            }
        }
        if (!shown) {
            try w.print("  {s} : unavailable ({s})\n", .{
                padLabel(&lbl, m.descriptor.label), reasonFor(m, caps),
            });
        }
    }
}

// Helpery prezentacji są w `present.zig`, żeby GUI mówiło to samo co CLI.
const sampleReason = present.sampleReason;
const findSample = present.findSample;
const reasonFor = present.reasonFor;
const capsSummary = present.capsSummary;
const unitLabel = present.unitLabel;
const writeFeatureNames = present.writeFeatureNames;

fn printSensorsJson(w: *std.Io.Writer, api: msr.Backend, samples: ?[]const metrics.Sample) !void {
    const caps = api.capabilities();
    try w.print("{{\"source\":\"{s}\",\"metrics\":[", .{api.sourceName()});
    for (catalog.metrics_available, 0..) |m, i| {
        if (i != 0) try w.print(",", .{});
        var status: []const u8 = "unavailable";
        var value_json: []const u8 = "null";
        if (samples) |list| {
            if (findSample(list, m.descriptor.id)) |s| {
                if (s.get()) |v| {
                    status = "ok";
                    var buf: [24]u8 = undefined;
                    value_json = try std.fmt.bufPrint(&buf, "{d}", .{v});
                }
            }
        }
        try w.print("{{\"id\":\"{s}\",\"status\":\"{s}\",\"value\":{s},\"reason\":\"{s}\"}}", .{
            m.descriptor.id, status, value_json, reasonFor(m, caps),
        });
    }
    try w.print("]}}\n", .{});
}

/// Wyrównanie etykiety do stałej szerokości.
///
/// Ręczne wyrównanie zamiast `{s:<16}`: tu chcemy wiersza, który da się
/// wyrównać w edytorze i porównać z `diff` na dwóch wyjściach.
fn padLabel(buf: []u8, label: []const u8) []const u8 {
    const width = 17;
    const n = @min(label.len, buf.len);
    @memcpy(buf[0..n], label[0..n]);
    var i = n;
    while (i < width and i < buf.len) : (i += 1) buf[i] = ' ';
    return buf[0..@min(width, buf.len)];
}

/// Pomiar kosztu cyklu pollingu.
///
/// Wyniki są **kosztem silnika na backendzie bez I/O**, a nie odczytu MSR.
/// Prawdziwy odczyt wymaga przełączenia kontekstu na właściwy CPU (albo
/// przypięcia wątku), co na Windows oznacza transition do jądra — tego pomiar
/// w ogóle nie obejmuje. Napisanie inaczej wprowadzałoby w błąd.
fn runBench(alloc: std.mem.Allocator, api: msr.Backend, nominal: u64) !u8 {
    const w = out();
    try w.print("FerrumScope sensors --bench\n", .{});
    try w.print("Źródło: {s}\n", .{api.sourceName()});
    try w.print("UWAGA: to koszt silnika i backendu BEZ I/O. Nie jest to koszt odczytu MSR.\n\n", .{});

    const metric = catalog.find("cpu.core.effective_frequency").?;
    const intervals = [_]u64{
        100 * std.time.ns_per_ms,
        250 * std.time.ns_per_ms,
        500 * std.time.ns_per_ms,
        std.time.ns_per_s,
    };
    const cycles = 2000;

    try w.print("  interwał     cykli    ns/cykl     odczytów MSR/cykl\n", .{});
    try w.print("  ----------   ------   ---------   ------------------\n", .{});

    for (intervals) |iv| {
        var freq_state = try engine.FreqState.init(alloc, nominal, 1, .b64);
        defer freq_state.deinit(alloc);
        const pollers = [_]engine.Poller{.{
            .descriptor = metric.descriptor,
            .instance = 0,
            .read = engine.pollEffectiveFrequency,
            .ctx = @ptrCast(&freq_state),
        }};
        var eng = try engine.Engine.init(alloc, api, &pollers, 16);
        defer eng.deinit();

        // Rozruch poza pomiarem — pierwszy cykl tworzy stan, nie jest kosztem
        // steady state.
        var t: u64 = 0;
        _ = eng.poll(t);

        var timer = try std.time.Timer.start();
        for (0..cycles) |_| {
            t += iv;
            _ = eng.poll(t);
        }
        const elapsed = timer.read();
        const reads = eng.backendReadsLastCycle();
        try w.print("  {d: >8} ms   {d: >6}   {d: >9.0}   {d: >18}\n", .{
            iv / std.time.ns_per_ms, cycles, @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(cycles)),
            reads,
        });
    }
    return 0;
}

fn cmdReplay(alloc: std.mem.Allocator, path: []const u8, rest: [][:0]u8) !u8 {
    const text = std.fs.cwd().readFileAlloc(alloc, path, 8 * 1024 * 1024) catch |e| {
        try errw().print("ferrumscope: nie mogę czytać '{s}': {t}\n", .{ path, e });
        return 1;
    };
    defer alloc.free(text);

    const captured = cpuimg.parse(text) catch |e| {
        try errw().print("ferrumscope: '{s}' nie jest poprawnym plikiem capture: {t}\n", .{ path, e });
        return 1;
    };

    var mode: Mode = .text;
    for (rest) |a| {
        if (std.mem.eql(u8, a, "--json")) {
            mode = .json;
        } else if (std.mem.eql(u8, a, "--raw")) {
            mode = .raw;
        } else if (std.mem.eql(u8, a, "--explain")) {
            mode = .explain;
        } else {
            try errw().print("ferrumscope: nieznana opcja replay '{s}'\n", .{a});
            return 2;
        }
    }

    // Dane per-CPU dołączamy tylko, gdy plik je ma. Bez tej warunkowości replay
    // starego pliku deklarowałby zdolność, której w pliku nie ma.
    var rp = replay_mod.Replay.init(captured.image);
    if (captured.has_per_cpu) rp = rp.withPerCpu(captured.per_cpu);
    rp.source = path;
    const res = probe.run(rp.create());
    if (res.getStatus() != .ok) {
        try errw().print("ferrumscope: replay nie powiódł się ({s})\n", .{res.getStatus().toSlice()});
        return 1;
    }
    const db = embedded.load() catch return 1;
    return report(res.unwrap().?, db, mode, path);
}

fn report(raw_info: core.raw.RawCpuInfo, db: hwdb_mod.Hwdb, mode: Mode, origin: []const u8) !u8 {
    var info = model.CpuInfo{};
    const outcome = decoder.decode(&raw_info, db, &info);
    const w = out();

    switch (mode) {
        .text => {
            var name_buf: [128]u8 = undefined;
            try w.print("FerrumScope {s}  [{s}]\n\n", .{ version, origin });
            try w.print("  Name        : {s}\n", .{info.displayName(&name_buf)});
            try w.print("  Vendor      : {s}\n", .{info.vendor.toSlice()});
            try w.print("  Signature   : 0x{X:0>8}  (Family {d}, Model 0x{X:0>2}, Stepping {d})\n", .{
                info.signature.eax, info.display_family, info.display_model, info.stepping,
            });
            if (info.microarchitecture) |m| try w.print("  Microarch   : {s}\n", .{m});
            if (info.codename) |c| try w.print("  Codename    : {s}\n", .{c});
            // Nazwa kodowa stepppingu to **interpretacja**, nie pomiar, więc
            // zawsze wypisujemy obok niej źródło i pewność. Surowy stepping
            // wypisany wyżej pochodzi z CPUID i tego nie wymaga.
            if (info.stepping_name) |s| try w.print("  Stepping nm : {s} (źródło: {s}, pewność: {s})\n", .{
                s, info.stepping_name_source.toSlice(), info.stepping_name_provenance.confidence.toSlice(),
            });
            if (info.socket_name) |s| try w.print("  Socket      : {s} (źródło: {s}, pewność: {s})\n", .{
                s, info.socket_source.toSlice(), info.socket_confidence.toSlice(),
            });
            if (info.variant) |v| try w.print("  Variant     : {s} (źródło: {s})\n", .{ v, info.variant_source.toSlice() });
            try w.print("  Cores       : {d} physical / {d} logical ({d} wątk/rdzeń, źródło: {s})\n", .{
                info.cores_physical,            info.threads_logical, info.threads_per_core,
                info.topology_source.toSlice(),
            });
            if (info.packages > 1) {
                // Liczba gniazd jest z pomiaru (bity x2APIC powyżej najwyższego
                // shiftu), nie z bazy. Bez tego wiersza maszyna 2-gniazdowa
                // wyglądałaby jak jednoprocesorowa.
                try w.print("  Sockets     : {d} gniazda\n", .{info.packages});
            }
            // Topologia hybrydowa: jedna liczba wątków na rdzeń **nie istnieje**,
            // więc `threads_per_core = 0`. Podział na typy wypisujemy osobno —
            // bez niego użytkownik hybrydy widziłby samą sumę wątków.
            //
            // Klasy wypisujemy z listy wartości SDM, nie z dwóch policzonych pól
            // `p_cores`/`e_cores`: te dwa pola znają tylko Intel P/E, a układ z
            // trzecią klasą albo z inną numeracją musi się dać pokazać bez
            // zmiany tego miejsca w kodzie.
            const classes = info.coreClassSlice();
            if (info.hybrid or classes.len > 1) {
                try w.print("               hybrydowy, maks. {d} wątki/rdzeń:\n", .{info.smt_max});
                for (classes) |c| {
                    if (c.name.len > 0) {
                        try w.print("                 {d} x {s}\n", .{ c.cores, c.name });
                    } else {
                        try w.print("                 {d} x klasa 0x{X:0>2} (numeracja nieznana)\n", .{ c.cores, c.value });
                    }
                }
            } else if (info.core_type != .unknown) {
                try w.print("               typ rdzenia: {s}\n", .{info.core_type.toSlice()});
            }
            // Gdy topologia nie jest pewna, mówimy to wprost, zamiast
            // pokazywać 0 jako gdyby to była liczba rdzeni.
            if (!info.topology_confident and info.threads_logical != 0) {
                try w.print("               UWAGA: liczba rdzeni fizycznych nieustalona (topologia niepewna)\n", .{});
            }
            if (info.smt) try w.print("  SMT         : yes\n", .{});

            if (info.cacheSlice().len > 0) {
                try w.print("  Caches      :\n", .{});
                for (info.cacheSlice()) |c| {
                    try w.print("      L{d} {s: <12} {d: >6} KiB  {d}-way, line {d} B\n", .{
                        c.level,         @tagName(c.kind), (c.size_bytes + 1023) / 1024,
                        c.associativity, c.line_size,
                    });
                }
            }
            var feat_buf: [512]u8 = undefined;
            const feat_list = writeFeatureNames(info.features, &feat_buf);
            try w.print("  Features    : {d} flagów{s}{s}\n", .{
                info.features.countSet(), if (feat_list.len > 0) ": " else "", feat_list,
            });

            try w.print("\n  Dmatch      : {s} (display={s}, decode={s})\n", .{
                info.match.toSlice(), @tagName(info.display), outcome.toSlice(),
            });
            if (info.db_source) |s| try w.print("  Db source   : {s}\n", .{s});
            if (info.db_source_url) |s| try w.print("  Db url      : {s}\n", .{s});
            if (raw_info.diagnostics.len > 0) {
                try w.print("\n  Diagnostics :\n", .{});
                for (0..raw_info.diagnostics.len) |i| {
                    try w.print("      - {s}\n", .{raw_info.diagnostics.get(i)});
                }
            }
        },
        .json => try writeJson(w, &info, outcome, raw_info.cpuid.len),
        .raw => {
            try w.print("# surowy obraz CPUID ({d} liści, max_basic=0x{X}, max_extended=0x{X})\n", .{
                raw_info.cpuid.len, raw_info.cpuid.max_basic, raw_info.cpuid.max_extended,
            });
            for (raw_info.cpuid.slice()) |e| {
                try w.print("leaf 0x{X:0>8} sub 0x{X:0>2}  eax=0x{X:0>8} ebx=0x{X:0>8} ecx=0x{X:0>8} edx=0x{X:0>8}\n", .{
                    e.leaf, e.subleaf, e.regs.eax, e.regs.ebx, e.regs.ecx, e.regs.edx,
                });
            }
            try w.print("\nbrand_raw: \"{s}\"\n", .{raw_info.brandSlice()});

            // Sekcja per-CPU: dane po przypinaniu wątku do każdego procesora.
            // To jest surowa cegiełka, na której stoi cała topologia — bez niej
            // nie ma czego debugować, gdy wynik będzie zły.
            if (raw_info.per_cpu.len > 0) {
                try w.print(
                    "\n# per-logical-CPU ({d} procesorow, odczytanych {d})\n",
                    .{ raw_info.per_cpu.len, raw_info.scanned_cpus },
                );
                for (raw_info.per_cpu.slice()) |c| {
                    try w.print("cpu {d} (apic={d}{s})\n", .{
                        c.id,
                        c.legacy_apic,
                        if (c.legacy_apic_known) "" else "?"[0..0],
                    });
                    for (c.image.slice()) |e| {
                        try w.print("  leaf 0x{X:0>8} sub 0x{X:0>2}  eax=0x{X:0>8} ebx=0x{X:0>8} ecx=0x{X:0>8} edx=0x{X:0>8}\n", .{
                            e.leaf, e.subleaf, e.regs.eax, e.regs.ebx, e.regs.ecx, e.regs.edx,
                        });
                    }
                }
            } else {
                try w.print("\n# per-logical-CPU: brak (backend nie deklaruje cpuid_per_logical_cpu)\n", .{});
            }
        },
        .explain => {
            try w.print("Skąd pochodzą poszczególne pola:\n\n", .{});
            try w.print("  vendor            <- CPUID.0 EBX/EDX/ECX ({s})\n", .{origin});
            try w.print("  family/model      <- CPUID.1 EAX 0x{X:0>8}\n", .{info.signature.eax});
            if (info.microarchitecture) |m|
                try w.print("  microarchitecture <- HWDB (uarch=\"{s}\")\n", .{m})
            else
                try w.print("  microarchitecture <- brak wpisu w HWDB\n", .{});
            if (info.codename) |c|
                try w.print("  codename          <- HWDB (codename=\"{s}\", źródło: {s})\n", .{ c, info.codename_source.toSlice() })
            else
                try w.print("  codename          <- brak wpisu w HWDB\n", .{});
            // Provenance rozbite na osobne pola, bo „źródło” i „pewność” to dwie
            // osie: obserwacja na sprzęcie bywa pewna (mamy własny pomiar) i wciąż
            // nie jest dokumentacją producenta.
            if (info.stepping_name) |s| {
                try w.print("  stepping_name     <- \"{s}\" (źródło: {s}, typ: {s}, pewność: {s})\n", .{
                    s,
                    info.stepping_name_source.toSlice(),
                    info.stepping_name_provenance.source_type.toSlice(),
                    info.stepping_name_provenance.confidence.toSlice(),
                });
                if (info.stepping_name_provenance.notes) |n|
                    try w.print("      notatka        <- {s}\n", .{n});
            } else {
                try w.print("  stepping_name     <- brak wpisu; surowy stepping z CPUID pozostaje nietknięty\n", .{});
            }
            if (info.socket_name) |s| {
                try w.print("  socket_name       <- \"{s}\" (źródło: {s}, typ: {s}, pewność: {s})\n", .{
                    s,
                    info.socket_source.toSlice(),
                    info.socket_provenance.source_type.toSlice(),
                    info.socket_confidence.toSlice(),
                });
                if (info.socket_provenance.notes) |n|
                    try w.print("      notatka        <- {s}\n", .{n});
            }
            if (info.package_contacts != 0)
                try w.print("  package_contacts  <- {d} (z HWDB)\n", .{info.package_contacts})
            else
                try w.print("  package_contacts  <- nieznana (nie zgadujemy liczby pinów)\n", .{});
            // SMBIOS trzymamy osobno: `Socket Designation` to slot na płycie
            // (`CPU1`, `J202`), a nie typ gniazda procesora.
            if (info.smbios_socket_designation) |d|
                try w.print("  smbios_socket     <- \"{s}\" (slot na płycie, NIE typ gniazda)\n", .{d})
            else
                try w.print("  smbios_socket     <- brak odczytu SMBIOS\n", .{});
            if (info.variant) |v| try w.print("  variant           <- \"{s}\" (źródło: {s}, typ: {s}, pewność: {s})\n", .{
                v,
                info.variant_source.toSlice(),
                info.variant_provenance.source_type.toSlice(),
                info.variant_provenance.confidence.toSlice(),
            });
            try w.print("  display           <- {s}\n", .{explainDisplay(info.display)});
            if (info.db_source) |s| try w.print("  provenance        <- \"{s}\"\n", .{s});
            if (info.db_source_url) |s| try w.print("  provenance url    <- {s}\n", .{s});
            try w.print("  decode outcome    <- {s}\n", .{outcome.toSlice()});
        },
    }
    return 0;
}

const explainDisplay = present.explainDisplay;

fn writeJson(w: *std.Io.Writer, info: *const model.CpuInfo, outcome: decoder.DecodeOutcome, leaves: usize) !void {
    var name_buf: [128]u8 = undefined;
    var b1: [256]u8 = undefined;
    var b2: [256]u8 = undefined;
    var b3: [256]u8 = undefined;
    var b4: [256]u8 = undefined;
    var b5: [256]u8 = undefined;
    var b6: [256]u8 = undefined;
    var b7: [256]u8 = undefined;
    var b8: [256]u8 = undefined;
    var b9: [256]u8 = undefined;
    // Osobny bufort dla `cache_variant`: `product_name` i `cache_variant` idą do
    // jednego `print`, więc wspólny bufort oznaczałby, że drugi zapis nadpisze
    // pierwszy. Każde `jsonOptStr` musi dostać własny bufor.
    var b10: [256]u8 = undefined;
    try w.print(
        \\{{
        \\  "available": {s},
        \\  "arch": "{s}",
        \\  "vendor": "{s}",
        \\  "name": "{s}",
        \\  "signature": "0x{X:0>8}",
        \\  "display_family": {d},
        \\  "display_model": {d},
        \\  "stepping": {d},
        \\  "brand": "{s}",
        \\  "microarchitecture": {s},
        \\  "codename": {s},
        \\  "display_source": "{s}",
        \\  "match": "{s}",
        \\  "decode": "{s}",
    , .{ @as([]const u8, if (info.available) "true" else "false"), @tagName(info.arch), info.vendor.toSlice(), info.displayName(&name_buf), info.signature.eax, info.display_family, info.display_model, info.stepping, info.brandSlice(), jsonOptStr(info.microarchitecture, &b1), jsonOptStr(info.codename, &b2), @tagName(info.display), info.match.toSlice(), outcome.toSlice() });
    // Osobne wywołanie `print`, bo Zig dopuszcza maks. 32 argumenty na wywołanie,
    // a pełna lista pól ich przekracza. Podział jest **dokładnie** na granicy
    // placeholderów: powyżej `decode` (14 pól), poniżej pola identyfikacji
    // rozszerzonej (27 pól). Pomieszanie list argumentów między wywołania to
    // „too few arguments" przy pierwszym i przekroczenie limitu przy drugim.
    try w.print(
        \\  "stepping_name": {s},
        \\  "stepping_name_source": "{s}",
        \\  "stepping_name_confidence": "{s}",
        \\  "stepping_name_source_type": "{s}",
        \\  "socket_name": {s},
        \\  "socket_source": "{s}",
        \\  "socket_confidence": "{s}",
        \\  "socket_source_type": "{s}",
        \\  "package_contacts": {d},
        \\  "package_contacts_known": {s},
        \\  "smbios_socket_designation": {s},
        \\  "product_name": {s},
        \\  "variant": {s},
        \\  "variant_source": "{s}",
        \\  "cache_variant": {s},
        \\  "cache_variant_source": "{s}",
        \\  "codename_source": "{s}",
        \\  "microarchitecture_source": "{s}",
        \\  "cores_physical": {d},
        \\  "threads_logical": {d},
        \\  "threads_per_core": {d},
        \\  "topology_source": "{s}",
        \\  "topology_confident": {s},
        \\  "smt": {s},
        \\  "cpuid_leaves": {d},
        \\  "db_source": {s},
        \\  "db_source_url": {s},
        \\  "caches": [
    , .{ jsonOptStr(info.stepping_name, &b5), info.stepping_name_source.toSlice(), info.stepping_name_provenance.confidence.toSlice(), info.stepping_name_provenance.source_type.toSlice(), jsonOptStr(info.socket_name, &b6), info.socket_source.toSlice(), info.socket_confidence.toSlice(), info.socket_provenance.source_type.toSlice(), info.package_contacts, @as([]const u8, if (info.package_contacts != 0) "true" else "false"), jsonOptStr(info.smbios_socket_designation, &b7), jsonOptStr(info.product_name, &b8), jsonOptStr(info.variant, &b9), info.variant_source.toSlice(), jsonOptStr(info.cache_variant, &b10), info.cache_variant_source.toSlice(), info.codename_source.toSlice(), info.microarchitecture_source.toSlice(), info.cores_physical, info.threads_logical, info.threads_per_core, info.topology_source.toSlice(), @as([]const u8, if (info.topology_confident) "true" else "false"), @as([]const u8, if (info.smt) "true" else "false"), leaves, jsonOptStr(info.db_source, &b3), jsonOptStr(info.db_source_url, &b4) });

    for (info.cacheSlice(), 0..) |c, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("\n    {{\"level\": {d}, \"kind\": \"{s}\", \"size_bytes\": {d}, \"line_size\": {d}, \"associativity\": {d}, \"shared\": {s}}}", .{
            c.level,                                            @tagName(c.kind), c.size_bytes, c.line_size, c.associativity,
            @as([]const u8, if (c.shared) "true" else "false"),
        });
    }
    try w.writeAll("\n  ]\n}\n");
}

/// Buduje bezpieczny łańcuch JSON w **buforze wywołującego**. Wersja
/// zwracająca `[]const u8` z lokalnego bufora byłaby wiszącym wskaźnikiem.
fn jsonOptStr(s: ?[]const u8, buf: []u8) []const u8 {
    const v = s orelse return "null";
    if (v.len + 2 > buf.len) return "\"?\"";

    var len: usize = 1; // otwierający cudzysłów
    for (v) |c| {
        const safe = c >= 0x20 and c != '"' and c != '\\' and c < 0x7F;
        const ch: u8 = if (safe) c else '?';
        if (len + 1 >= buf.len) break;
        buf[len] = ch;
        len += 1;
    }
    buf[len] = '"';
    return buf[0 .. len + 1];
}

/// Zapisuje surowy obraz CPUID do pliku `.cpuimg`.
///
/// Zapisujemy **wyłącznie** publiczne identyfikatory CPUID: sygnaturę, liście,
/// flagi, cache i topologię. Żadnych danych prywatnych ani identyfikatorów
/// systemu. Plik służy jako złoty fixture dla testów i jako wsad dla `replay`.
fn cmdCapture(path: []const u8) !u8 {
    const res = probe.run(native.create());
    if (res.getStatus() != .ok) {
        try errw().print("ferrumscope: nie mogę odczytać CPU ({s})\n", .{res.getStatus().toSlice()});
        return 1;
    }
    const raw_info = res.unwrap().?;

    var buf: [64 * 1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    cpuimg.format(&stream, "native", &raw_info.cpuid, &raw_info.per_cpu) catch |e| {
        try errw().print("ferrumscope: nie udało się przygotować capture: {t}\n", .{e});
        return 1;
    };

    if (std.fs.path.dirname(path)) |dir| std.fs.cwd().makePath(dir) catch {};
    var file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch |e| {
        try errw().print("ferrumscope: nie mogę zapisać '{s}': {t}\n", .{ path, e });
        return 1;
    };
    defer file.close();
    file.writeAll(stream.buffered()) catch |e| {
        try errw().print("ferrumscope: zapis '{s}': {t}\n", .{ path, e });
        return 1;
    };
    try out().print("zapisano {s}: {d} liści CPUID + {d} CPU per-procesor, {d} B\n", .{
        path, raw_info.cpuid.len, raw_info.per_cpu.len, stream.buffered().len,
    });
    return 0;
}

/// Wynik wczytania jednego pliku capture przez pełny pipeline.
const Loaded = struct {
    info: model.CpuInfo,
    /// Czy plik zawiera sekcję per-CPU, czyli czy backend umiał przypiąć wątek
    /// do każdego procesora logicznego. To **zdolność platformy**, nie
    /// właściwość procesora — stąd osobna kategoria różnicy.
    has_per_cpu: bool,
    scanned: u32,
    leaves: usize,
};

/// Lista różnic, zgromadzona do jednego wydruku.
///
/// Teksty formatujemy od razu, bo różnice mają różne typy (u16, u8, bool,
/// nazwa) i jeden rekord z polami różnych typów wymagałby unii albo ośmiu
/// wariantów. Bufor ma rozmiar z góry ustalony: `cmdCompareCaptures` nie ma
/// prawa blokować się na mallocu w środku raportowania.
const DiffList = struct {
    pub const cap = 24;
    pub const width = 192;
    buf: [cap][width]u8 = undefined,
    /// Długość **użytej** części każdego wpisu.
    ///
    /// Bez tego `bufPrint` zwraca slice z długością, a my wypisalibyśmy cały
    /// bufor — raport kończyłby się kilkudziesięcioma spacjami na wiersz.
    /// Wygląda to kosmetycznie, ale `buf` poza długością nie jest zainicjalizowany,
    /// więc raport wypisujełby bajty spoza zakresu.
    lens: [cap]usize = @splat(0),
    len: usize = 0,
    /// Czy lista się przepełniła. Gdyby to zdarzyło się po cichu, użytkownik
    /// dostałby raport z pominiętymi wierszami — najgorszy wynik tego polecenia.
    truncated: bool = false,

    fn add(self: *DiffList, comptime fmt: []const u8, args: anytype) void {
        if (self.len == cap) {
            self.truncated = true;
            return;
        }
        const s = std.fmt.bufPrint(&self.buf[self.len], fmt, args) catch {
            self.truncated = true;
            return;
        };
        self.lens[self.len] = s.len;
        self.len += 1;
    }

    fn get(self: *const DiffList, i: usize) []const u8 {
        return self.buf[i][0..self.lens[i]];
    }
};

fn loadCapture(alloc: std.mem.Allocator, path: []const u8) !Loaded {
    const text = std.fs.cwd().readFileAlloc(alloc, path, 8 * 1024 * 1024) catch |e| {
        try errw().print("ferrumscope: nie mogę czytać '{s}': {t}\n", .{ path, e });
        return error.ReadFailed;
    };
    defer alloc.free(text);

    const captured = cpuimg.parse(text) catch |e| {
        try errw().print("ferrumscope: '{s}' nie jest poprawnym plikiem capture: {t}\n", .{ path, e });
        return error.ParseFailed;
    };
    // Sekcję per-CPU dołączamy warunkowo — dokładnie jak robi to `replay`.
    // Bez tego plik bez tej sekcji deklarowałby zdolność, której w nim nie ma.
    var rp = replay_mod.Replay.init(captured.image);
    if (captured.has_per_cpu) rp = rp.withPerCpu(captured.per_cpu);
    rp.source = path;
    const res = probe.run(rp.create());
    if (res.getStatus() != .ok) {
        try errw().print("ferrumscope: '{s}': replay nie powiódł się ({s})\n", .{ path, res.getStatus().toSlice() });
        return error.ProbeFailed;
    }
    const raw_info = res.unwrap().?;
    const db = embedded.load() catch {
        try errw().print("ferrumscope: wbudowana baza jest uszkodzona\n", .{});
        return error.DbFailed;
    };
    var info = model.CpuInfo{};
    _ = decoder.decode(&raw_info, db, &info);
    return .{
        .info = info,
        .has_per_cpu = captured.has_per_cpu,
        .scanned = @intCast(raw_info.per_cpu.len),
        .leaves = raw_info.cpuid.len,
    };
}

/// Porównuje dwa pliki capture przez **znormalizowany model**, nie bajty.
///
/// Porównanie bajtów jest bezwartościowe: te same dwa procesory dają różne
/// pliki zależnie od platformy, na której zapisano, a ten sam plik różni się
/// bajtami przy zmianie kolejności linii. Interesuje jedno pytanie — czy oba
/// pliki opisują **ten sam sprzęt i tę samą wiarygodność pomiaru** — i jeśli
/// nie, to dlaczego.
fn cmdCompareCaptures(alloc: std.mem.Allocator, a_path: []const u8, b_path: []const u8) !u8 {
    const a = try loadCapture(alloc, a_path);
    const b = try loadCapture(alloc, b_path);
    const w = out();

    var name_a: [128]u8 = undefined;
    var name_b: [128]u8 = undefined;
    const brand_a = a.info.brandSlice();
    const brand_b = b.info.brandSlice();

    try w.print("Porownanie znormalizowanego modelu CPU\n\n", .{});
    try w.print("  A: {s}\n     nazwa: {s}\n", .{ a_path, a.info.displayName(&name_a) });
    try w.print("  B: {s}\n     nazwa: {s}\n\n", .{ b_path, b.info.displayName(&name_b) });

    var d = DiffList{};
    var topology_differs = false;
    var identity_differs = false;

    // --- Tozsamosc ------------------------------------------------------------
    if (a.info.vendor != b.info.vendor) {
        identity_differs = true;
        d.add("vendor:             {s}  vs  {s}", .{ a.info.vendor.toSlice(), b.info.vendor.toSlice() });
    }
    if (a.info.signature.eax != b.info.signature.eax) {
        identity_differs = true;
        d.add("sygnatura CPUID.1:  0x{X:0>8}  vs  0x{X:0>8}", .{ a.info.signature.eax, b.info.signature.eax });
    }
    if (!std.mem.eql(u8, brand_a, brand_b)) {
        identity_differs = true;
        d.add("brand string:       '{s}'  vs  '{s}'", .{ brand_a, brand_b });
    }

    // --- Topologia ------------------------------------------------------------
    if (a.info.cores_physical != b.info.cores_physical) {
        topology_differs = true;
        d.add("rdzenie fizyczne:  {d}  vs  {d}", .{ a.info.cores_physical, b.info.cores_physical });
    }
    if (a.info.threads_logical != b.info.threads_logical) {
        topology_differs = true;
        d.add("procesory logiczne: {d}  vs  {d}", .{ a.info.threads_logical, b.info.threads_logical });
    }
    if (a.info.threads_per_core != b.info.threads_per_core) {
        topology_differs = true;
        d.add("watki/rdzen:        {d}  vs  {d}", .{ a.info.threads_per_core, b.info.threads_per_core });
    }
    if (a.info.packages != b.info.packages) {
        topology_differs = true;
        d.add("gniazda:            {d}  vs  {d}", .{ a.info.packages, b.info.packages });
    }
    if (a.info.dies != b.info.dies) {
        topology_differs = true;
        d.add("die:                {d}  vs  {d}", .{ a.info.dies, b.info.dies });
    }
    if (a.info.hybrid != b.info.hybrid or a.info.heterogeneous != b.info.heterogeneous) {
        topology_differs = true;
        d.add("hybrydowy:          {any}/{any}  vs  {any}/{any}", .{
            a.info.hybrid, a.info.heterogeneous, b.info.hybrid, b.info.heterogeneous,
        });
    }
    // Klasy rdzeni porownujemy jako liste wartosci SDM — nazwy sa wygoda, a
    // `value` jest tym, co faktycznie raportowal sprzet.
    {
        const ca = a.info.coreClassSlice();
        const cb = b.info.coreClassSlice();
        if (ca.len != cb.len) {
            topology_differs = true;
            d.add("liczba klas rdzeni: {d}  vs  {d}", .{ ca.len, cb.len });
        } else {
            var k: usize = 0;
            while (k < ca.len) : (k += 1) {
                if (ca[k].value != cb[k].value or ca[k].cores != cb[k].cores) {
                    topology_differs = true;
                    d.add("klasa 0x{X:0>2}:        {d} rdzeni  vs  {d} rdzeni", .{ ca[k].value, ca[k].cores, cb[k].cores });
                }
            }
        }
    }
    if (a.info.cacheSlice().len != b.info.cacheSlice().len) {
        topology_differs = true;
        d.add("liczba cache'ow:    {d}  vs  {d}", .{ a.info.cacheSlice().len, b.info.cacheSlice().len });
    } else {
        for (a.info.cacheSlice(), b.info.cacheSlice()) |ca, cb| {
            if (ca.size_bytes != cb.size_bytes or ca.level != cb.level or ca.kind != cb.kind) {
                topology_differs = true;
                d.add("cache L{d} {s}:     {d} B  vs  {d} B", .{ ca.level, @tagName(ca.kind), ca.size_bytes, cb.size_bytes });
                break;
            }
        }
    }

    // --- Zdolnosci platformy --------------------------------------------------
    // Osobno od modelu, bo to roznica w **wiarygodnosci**, nie w sprzecie.
    var capability_differs = false;
    if (a.has_per_cpu != b.has_per_cpu) {
        capability_differs = true;
        d.add("sekcja per-CPU:     {any}  vs  {any}  (zdolnosc backendu)", .{ a.has_per_cpu, b.has_per_cpu });
    }
    if (a.scanned != b.scanned) {
        capability_differs = true;
        d.add("odczytanych CPU:    {d}  vs  {d}", .{ a.scanned, b.scanned });
    }
    if (a.info.topology_source != b.info.topology_source) {
        capability_differs = true;
        d.add("zrodlo topologii:   {s}  vs  {s}", .{
            a.info.topology_source.toSlice(), b.info.topology_source.toSlice(),
        });
    }

    // --- Roznica samego formatu ----------------------------------------------
    // Liczba zapisanych lisci rozni sie, gdy platforma inaczej iteruje CPUID.
    // To **nie** zmienia opisu procesora, wiec trzymamy to z dala od roznic
    // semantycznych — inaczej porownanie krzyczaloby o roznicy tam, gdzie jej nie ma.
    const format_only = a.leaves != b.leaves;

    // --- Klasyfikacja ---------------------------------------------------------
    // Kolejnosc ma znaczenie: roznica tozsamosci jest silniejsza niz topologia,
    // a brak zdolnosci nie zmienia opisu procesora.
    const Verdict = enum {
        identical,
        format_only,
        missing_capability,
        hardware_mismatch,
        different_cpu,
    };
    const verdict: Verdict = if (identity_differs)
        .different_cpu
    else if (topology_differs)
        .hardware_mismatch
    else if (capability_differs)
        .missing_capability
    else if (format_only)
        .format_only
    else
        .identical;

    if (d.len > 0) {
        try w.print("Roznice:\n", .{});
        for (0..d.len) |k| {
            try w.print("  {s}\n", .{d.get(k)});
        }
        if (d.truncated) {
            try w.print("  ... lista roznic ucieta (pokazano {d} z wiecej)\n", .{DiffList.cap});
        }
        try w.print("\n", .{});
    } else if (format_only) {
        try w.print("Model identyczny; pliki roznia sie tylko liczba zapisanych lisci ({d} vs {d}).\n\n", .{ a.leaves, b.leaves });
    } else {
        try w.print("Model identyczny.\n\n", .{});
    }

    const label = switch (verdict) {
        .identical => "IDENTYCZNE",
        .format_only => "ROZNICA FORMATU (model ten sam)",
        .missing_capability => "BRAK ZDOLNOSCI (model ten sam, pomiar mniej wiarygodny)",
        .hardware_mismatch => "NIEDOPASOWANIE SPRZETU (ta sama sygnatura, inna topologia)",
        .different_cpu => "INNY PROCESOR (rozna sygnatura CPUID)",
    };
    try w.print("Werdykt: {s}\n", .{label});

    // Kod wyjscia ma byc uzyteczny w skryptach: 0 = ten sam sprzet, 1 = inny.
    return switch (verdict) {
        .identical, .format_only, .missing_capability => 0,
        .hardware_mismatch, .different_cpu => 1,
    };
}

fn cmdHwdb() !u8 {
    const db = embedded.load() catch {
        try errw().print("ferrumscope: wbudowana baza jest uszkodzona\n", .{});
        return 1;
    };
    const w = out();
    try w.print("ferrum-hwdb.bin (wbudowana)\n", .{});
    try w.print("  format        : {d}\n", .{hwdb_mod.format_version});
    try w.print("  schema        : {d}\n", .{db.schema});
    try w.print("  db_revision   : {d}\n", .{db.db_revision});
    try w.print("  wpisów        : {d}\n", .{db.count()});

    var by_vendor: [7]usize = [_]usize{0} ** 7;
    var i: usize = 0;
    while (i < db.count()) : (i += 1) {
        const e = db.entryAt(i) orelse continue;
        const idx = @intFromEnum(e.vendor);
        if (idx < by_vendor.len) by_vendor[idx] += 1;
    }
    for (by_vendor, 0..) |n, idx| {
        if (n == 0) continue;
        const v: hwdb_mod.VendorId = @enumFromInt(@as(u8, @intCast(idx)));
        try w.print("    {s: <8} : {d}\n", .{ @tagName(v), n });
    }
    return 0;
}
