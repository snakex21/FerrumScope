//! Stan aplikacji wspólny dla GUI i CLI: zbiera dane (na żywo albo z plików
//! capture), utrzymuje próbkowanie na żywo (obciążenie/zegar CPU, biblioteki
//! GPU, sterownik MSR) i buduje strony raportu.
//!
//! GUI i CLI nie mają własnej logiki odczytu — obie warstwy wołają `State`.

const std = @import("std");
const builtin = @import("builtin");
const ferrum = @import("root.zig");
const present = @import("present.zig");
const i18n = @import("i18n/i18n.zig");
const embedded = @import("db/embedded.zig");
const pci_embedded = @import("db/pci_embedded.zig");

const raw = ferrum.core.raw;
const model = ferrum.core.model;
const native = ferrum.platform.native;
const replay_mod = ferrum.platform.replay;
const probe = ferrum.probe.cpu;
const decoder = ferrum.decode.cpu_x86;
const cpuimg = ferrum.capture.cpuimg;
const sysimg = ferrum.capture.sysimg;
const report = ferrum.sys.report;
const snapshot = ferrum.sys.snapshot;
const pages_cpu = ferrum.sys.pages_cpu;
const pages_system = ferrum.sys.pages_system;
const gv = @import("sys/win/gpu_vendor.zig");
const lookup = ferrum.sys.lookup;
const links_embedded = @import("links_embedded");
const msr = ferrum.telemetry.msr;
const metrics = ferrum.telemetry.metrics;
const catalog = ferrum.telemetry.catalog;
const engine = ferrum.telemetry.engine;

const is_windows = builtin.os.tag == .windows;
const win = ferrum.sys.win;

pub const Options = struct {
    /// Tekst pliku `.cpuimg` zamiast CPUID na żywo.
    cpu_replay: ?[]const u8 = null,
    cpu_replay_name: []const u8 = "",
    /// Tekst pliku `.sysimg` zamiast odczytu systemu.
    sys_replay: ?[]const u8 = null,
    sys_replay_name: []const u8 = "",
    /// Pomiary na żywo (CPU load/zegar, biblioteki GPU, MSR).
    live: bool = true,
    /// Odczyt SMART/NVMe dysków.
    disks: bool = true,
};

/// Stan sterownika MSR (zakładka Czujniki) — przeniesiony z dawnego gui_main.
const Msr = struct {
    dev: if (is_windows) ferrum.telemetry.windows_msr.deviceIoTransport else void = if (is_windows) .{} else {},
    real: if (is_windows) ferrum.telemetry.windows_msr.Backend else void = undefined,
    real_open: bool = false,
    open_error_text: []const u8 = "",
    api: msr.Backend = undefined,
    freq: engine.FreqState = undefined,
    pollers: [1]engine.Poller = undefined,
    eng: engine.Engine = undefined,
    eng_ready: bool = false,
    samples: ?[]const metrics.Sample = null,
};

pub const State = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    snap_arena: std.heap.ArenaAllocator,
    links_arena: std.heap.ArenaAllocator,
    links: lookup.Tables = .{},
    driver_links: ferrum.sys.drivers.Tables = .{},
    page_arena: std.heap.ArenaAllocator,
    snap: snapshot.Snapshot = .{},

    cpu_ok: bool = false,
    /// Powód braku CPU: identyfikator `i18n.N` albo nazwa stanu probe;
    /// tłumaczony przy budowie strony (język może się zmienić w trakcie).
    cpu_error: []const u8 = "",
    cpu_raw: raw.RawCpuInfo = .{},
    cpu_info: model.CpuInfo = .{},
    outcome: decoder.DecodeOutcome = .unknown,
    hwdb_entries: usize = 0,
    hwdb_revision: u32 = 0,
    /// Nazwa pliku replay. Pusty = „CPUID na żywo” (tłumaczone na stronie).
    cpu_origin: []const u8 = "",

    sampler: if (is_windows) win.cpuload.Sampler else void = undefined,
    sampler_ready: bool = false,
    sample: if (is_windows) win.cpuload.Sample else void = undefined,
    have_sample: bool = false,

    adl: if (is_windows) ?win.adl.Session else void = if (is_windows) null else {},
    nv: if (is_windows) ?win.nvapi.Session else void = if (is_windows) null else {},
    msr_state: Msr = .{},

    pub fn create(gpa: std.mem.Allocator, opts: Options) !*State {
        const s = try gpa.create(State);
        s.* = .{
            .gpa = gpa,
            .opts = opts,
            .snap_arena = std.heap.ArenaAllocator.init(gpa),
            .page_arena = std.heap.ArenaAllocator.init(gpa),
            .links_arena = std.heap.ArenaAllocator.init(gpa),
        };
        s.loadLinks();
        s.loadCpu();
        s.loadSnapshot();
        // Backend MSR musi istnieć zawsze — strona Czujniki pyta o zdolności.
        s.msr_state.api = present.NoMsrBackend.create();
        // Identyfikator katalogu; tłumaczony przy wyświetleniu (`i18n.t`).
        s.msr_state.open_error_text = i18n.N("pomiary na żywo wyłączone (replay / testy)");
        if (opts.live and is_windows) s.startLive();
        return s;
    }

    pub fn destroy(self: *State) void {
        if (is_windows) {
            if (self.sampler_ready) self.sampler.deinit();
            if (self.adl) |*a| a.close();
            if (self.nv) |*n| n.close();
            self.closeMsr();
        }
        self.snap_arena.deinit();
        self.page_arena.deinit();
        self.links_arena.deinit();
        self.gpa.destroy(self);
    }

    // --- CPU ------------------------------------------------------------------

    fn loadCpu(self: *State) void {
        var res: @TypeOf(probe.run(native.create())) = undefined;
        if (self.opts.cpu_replay) |text| {
            const captured = cpuimg.parse(text) catch {
                self.cpu_error = i18n.N("plik .cpuimg jest niepoprawny");
                return;
            };
            var rp = replay_mod.Replay.init(captured.image);
            if (captured.has_per_cpu) rp = rp.withPerCpu(captured.per_cpu);
            rp.source = self.opts.cpu_replay_name;
            res = probe.run(rp.create());
            self.cpu_origin = self.opts.cpu_replay_name;
        } else {
            res = probe.run(native.create());
        }
        if (res.getStatus() != .ok) {
            self.cpu_error = res.getStatus().toSlice();
            return;
        }
        self.cpu_raw = res.unwrap().?;
        const db = embedded.load() catch {
            self.cpu_error = i18n.N("wbudowana baza HWDB jest uszkodzona");
            return;
        };
        self.hwdb_entries = db.count();
        self.hwdb_revision = db.db_revision;
        self.outcome = decoder.decode(&self.cpu_raw, db, &self.cpu_info);
        self.cpu_ok = true;
    }

    // --- migawka systemu ---------------------------------------------------------

    pub fn loadSnapshot(self: *State) void {
        _ = self.snap_arena.reset(.free_all);
        const a = self.snap_arena.allocator();
        if (self.opts.sys_replay) |text| {
            self.snap = sysimg.parse(a, text) catch .{};
            self.snap.replay_source = self.opts.sys_replay_name;
            return;
        }
        if (is_windows) {
            self.snap = win.collect.collect(a, .{ .disks = self.opts.disks });
        } else {
            self.snap = .{};
        }
    }

    // --- pomiary na żywo -----------------------------------------------------------

    fn startLive(self: *State) void {
        if (!is_windows) return;
        if (self.opts.cpu_replay == null) {
            self.sampler.init();
            self.sampler_ready = true;
        }
        if (self.opts.sys_replay == null) {
            self.adl = win.adl.Session.open(self.gpa);
            self.nv = win.nvapi.Session.open(self.gpa);
        }
        self.openMsr();
    }

    /// Jedno odświeżenie pomiarów (GUI: co 1 s).
    pub fn tick(self: *State) void {
        if (!is_windows) return;
        if (self.sampler_ready) {
            self.sample = self.sampler.sample();
            self.have_sample = true;
        }
        if (self.adl) |*a| a.poll();
        if (self.nv) |*n| n.poll();
        if (self.msr_state.eng_ready) self.msr_state.samples = self.msr_state.eng.poll(self.msr_state.api.monotonicNanos());
    }

    fn openMsr(self: *State) void {
        if (!is_windows) return;
        const m = &self.msr_state;
        const wm = ferrum.telemetry.windows_msr;
        if (wm.Backend.open(m.dev.transport())) |opened| {
            m.real = opened;
            m.real_open = true;
            m.api = m.real.api();
            const metric = catalog.find("cpu.core.effective_frequency").?;
            m.freq = engine.FreqState.init(self.gpa, present.nominal_hz_assumed, 1, .b64) catch return;
            m.pollers[0] = .{ .descriptor = metric.descriptor, .instance = 0, .read = engine.pollEffectiveFrequency, .ctx = @ptrCast(&m.freq) };
            m.eng = engine.Engine.init(self.gpa, m.api, &m.pollers, 16) catch return;
            m.eng_ready = true;
            m.samples = m.eng.poll(m.api.monotonicNanos());
        } else |e| {
            m.open_error_text = wm.openErrorDetail(e);
            m.api = present.NoMsrBackend.create();
        }
    }

    fn closeMsr(self: *State) void {
        if (!is_windows) return;
        const m = &self.msr_state;
        if (m.eng_ready) {
            m.eng.deinit();
            m.freq.deinit(self.gpa);
            m.eng_ready = false;
        }
        if (m.real_open) {
            m.real.close();
            m.real_open = false;
        }
    }

    // --- strony ------------------------------------------------------------------

    fn gpuLive(self: *State, a: std.mem.Allocator) pages_system.GpuLive {
        if (!is_windows) return .{};
        var libs: std.ArrayList(gv.LibraryInfo) = .empty;
        var ads: std.ArrayList(gv.Adapter) = .empty;
        if (self.adl) |*s| {
            libs.append(a, s.library) catch {};
            ads.appendSlice(a, s.adapters) catch {};
        }
        if (self.nv) |*s| {
            libs.append(a, s.library) catch {};
            ads.appendSlice(a, s.adapters) catch {};
        }
        return .{ .libraries = libs.items, .adapters = ads.items };
    }

    fn liveCpu(self: *State) ?pages_cpu.LiveCpu {
        if (!is_windows or !self.have_sample) return null;
        const s = &self.sample;
        var lv: pages_cpu.LiveCpu = .{
            .cpus = s.cpus,
            .load = s.load[0..s.cpus],
            .total_load = s.total_load,
            .base_mhz = s.base_mhz,
            .reported_mhz = s.reported_mhz,
            .est_mhz = s.est_mhz[0..s.cpus],
            .est_avg_mhz = s.est_avg_mhz,
            .est_max_mhz = s.est_max_mhz,
            .pdh_ok = s.pdh_ok,
        };
        if (self.msr_state.open_error_text.len > 0) lv.msr_reason = i18n.t(self.msr_state.open_error_text);
        if (self.msr_state.samples) |list| {
            if (present.findSample(list, "cpu.core.effective_frequency")) |smp| {
                if (smp.get()) |v| lv.msr_effective_mhz = @as(f64, @floatFromInt(v)) / 1e6;
            }
        }
        return lv;
    }

    // --- linki TechPowerUp ----------------------------------------------------

    /// Ścieżka `data\links.toml` obok programu (UTF-8, w `buf`).
    pub fn userLinksPath(buf: []u8) ?[]const u8 {
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = std.fs.selfExeDirPath(&dir_buf) catch return null;
        return std.fmt.bufPrint(buf, "{s}{c}data{c}links.toml", .{ dir, std.fs.path.sep, std.fs.path.sep }) catch null;
    }

    /// `data\\driver_links.toml` obok programu (strony sterowników przypięte przez użytkownika).
    pub fn driverLinksPath(buf: []u8) ?[]const u8 {
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = std.fs.selfExeDirPath(&dir_buf) catch return null;
        return std.fmt.bufPrint(buf, "{s}{c}data{c}driver_links.toml", .{ dir, std.fs.path.sep, std.fs.path.sep }) catch null;
    }

    /// Tabela kuratorowana (osadzona) + linki przypięte przez użytkownika.
    pub fn loadLinks(self: *State) void {
        _ = self.links_arena.reset(.free_all);
        const a = self.links_arena.allocator();
        self.links.curated = lookup.parse(a, links_embedded.text) catch &.{};
        self.driver_links.curated = ferrum.sys.drivers.parse(a, links_embedded.drivers_text) catch &.{};
        self.driver_links.user = &.{};
        {
            var dpb: [std.fs.max_path_bytes]u8 = undefined;
            if (driverLinksPath(&dpb)) |dp| {
                if (std.fs.cwd().readFileAlloc(a, dp, 256 * 1024)) |dt| {
                    self.driver_links.user = ferrum.sys.drivers.parse(a, dt) catch &.{};
                } else |_| {}
            }
        }
        self.links.user = &.{};
        var pb: [std.fs.max_path_bytes]u8 = undefined;
        const path = userLinksPath(&pb) orelse return;
        const text = std.fs.cwd().readFileAlloc(a, path, 256 * 1024) catch return;
        self.links.user = lookup.parse(a, text) catch &.{};
    }

    /// Przypina dokładny link dla modelu (zapis do `data\links.toml`).
    pub fn pinLink(self: *State, kind: lookup.Kind, model_key: []const u8, pci: []const u8, url: []const u8) !void {
        if (!lookup.validUrl(url) or model_key.len == 0) return error.InvalidUrl;
        var pb: [std.fs.max_path_bytes]u8 = undefined;
        const path = userLinksPath(&pb) orelse return error.NoPath;
        if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch {};
        const text = try lookup.withPinned(self.gpa, self.links.user, .{ .kind = kind, .model = model_key, .pci = pci, .url = url, .source = "user" });
        defer self.gpa.free(text);
        try std.fs.cwd().writeFile(.{ .sub_path = path, .data = text });
        self.loadLinks();
    }

    /// Zegar zewnętrzny CPU z SMBIOS typ 4 (do „Zegar magistrali” i mnożnika).
    fn busMhz(self: *State) ?u32 {
        const buf = self.snap.smbios orelse return null;
        const t = ferrum.sys.smbios.fromRawSmbiosData(buf) catch return null;
        const s = t.find(4) orelse return null;
        const p = ferrum.sys.smbios.decodeProcessor(s) orelse return null;
        const n = p.external_clock_mhz orelse return null;
        const v = n.value orelse return null;
        return if (v > 0) v else null;
    }

    pub fn cpuPage(self: *State, a: std.mem.Allocator) report.Page {
        if (!self.cpu_ok) {
            var p: report.Page = .{ .id = "cpu", .title = "" };
            var b = report.Builder.init(a, &p);
            p.title = b.t("CPU");
            p.headline = b.t("Procesor niedostępny");
            b.section(b.t("Procesor"));
            b.add(.{ .label = b.t("CPU"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = i18n.t(self.cpu_error) });
            return p;
        }
        return pages_cpu.build(a, .{
            .raw = &self.cpu_raw,
            .info = &self.cpu_info,
            .outcome = self.outcome,
            .hwdb_entries = self.hwdb_entries,
            .hwdb_revision = self.hwdb_revision,
            .origin = self.cpu_origin,
            .live = self.liveCpu(),
            .bus_mhz = self.busMhz(),
            .lookup = self.links,
        });
    }

    fn sensorsPage(self: *State, a: std.mem.Allocator, ctx: pages_system.Ctx, live: pages_system.GpuLive) report.Page {
        var p: report.Page = .{ .id = "sensors", .title = "" };
        var b = report.Builder.init(a, &p);
        const m = &self.msr_state;
        p.title = b.t("Czujniki");
        p.headline = if (m.real_open) b.t("Czujniki — sterownik MSR załadowany") else b.t("Czujniki — bez sterownika");
        p.summary = b.t("Czujniki CPU z MSR wymagają sterownika FerrumScopeMsr (nie jest instalowany automatycznie). GPU i dyski — bez sterownika.");
        const open_error = i18n.t(m.open_error_text);

        b.section(b.t("CPU — obciążenie i zegar (bez sterownika)"));
        if (self.liveCpu()) |lv| {
            if (lv.total_load) |t| b.add(.{ .label = b.t("Obciążenie całkowite"), .value = b.fmt("{d:.1} %", .{t}), .source = "NtQuerySystemInformation(SystemProcessorPerformanceInformation)" });
            if (lv.est_avg_mhz) |f| b.add(.{ .label = b.t("Zegar rdzeni (średnio)"), .value = b.fmt("{d:.0} MHz", .{f}), .state = .estimate, .confidence = .medium, .source = b.t("PDH % Processor Performance × zegar bazowy") });
        } else b.add(.{ .label = b.t("Obciążenie"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.t("brak pomiaru na żywo (replay albo pierwsza próbka)") });

        b.section(b.t("CPU — MSR (sterownik FerrumScopeMsr)"));
        const caps = m.api.capabilities();
        for (catalog.metrics_available) |metric| {
            const label = if (metric.descriptor.label.len > 0) metric.descriptor.label else metric.descriptor.id;
            var done = false;
            if (m.samples) |list| {
                if (present.findSample(list, metric.descriptor.id)) |smp| {
                    if (smp.get()) |v| {
                        const scaled = @as(f64, @floatFromInt(v)) * metric.descriptor.unit.scale();
                        b.add(.{ .label = label, .value = b.fmt("{d:.2} {s}", .{ scaled, present.unitLabel(metric.descriptor.unit) }), .source = m.api.sourceName(), .confidence = .medium, .state = if (smp.status == .synthetic) .estimate else .ok });
                    } else {
                        b.add(.{ .label = label, .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.fmt("{s} — {s}", .{ @tagName(smp.status), present.sampleReason(smp) }) });
                    }
                    done = true;
                }
            }
            if (!done) {
                const why = present.reasonFor(metric, caps);
                const st: report.State = if (m.real_open or metric.descriptor.source == .platform) .unavailable else .requires_driver;
                b.add(.{ .label = label, .value = "—", .state = st, .confidence = .unknown, .source = if (open_error.len > 0) b.fmt("{s} ({s})", .{ why, open_error }) else why });
            }
        }
        pages_system.addSensorSections(&b, ctx, live);
        return p;
    }

    /// Buduje wszystkie strony od nowa w świeżej arenie (poprzednie wyniki
    /// przestają być ważne).
    pub fn buildPages(self: *State) []report.Page {
        _ = self.page_arena.reset(.retain_capacity);
        const a = self.page_arena.allocator();
        const ctx: pages_system.Ctx = .{ .snap = &self.snap, .pci = pci_embedded.get(), .lookup = self.links, .drivers = self.driver_links };
        const live = self.gpuLive(a);
        const pages = a.alloc(report.Page, 6) catch return &.{};
        pages[0] = self.cpuPage(a);
        pages[1] = pages_system.buildBoard(a, ctx);
        pages[2] = pages_system.buildMemory(a, ctx);
        pages[3] = pages_system.buildGraphics(a, ctx, live);
        pages[4] = pages_system.buildStorage(a, ctx);
        pages[5] = self.sensorsPage(a, ctx, live);
        if (self.snap.replay_source) |src| {
            for (pages[1..5]) |*p| p.summary = if (self.snap.serials_masked)
                i18n.tf(a, "REPLAY: {source} (numery seryjne zamaskowane przy capture). {summary}", .{ .source = src, .summary = p.summary })
            else
                i18n.tf(a, "REPLAY: {source}. {summary}", .{ .source = src, .summary = p.summary });
        }
        return pages;
    }

    pub fn reportOf(self: *State, pages: []const report.Page) report.Report {
        _ = self;
        return .{ .title = "FerrumScope", .version = present.version, .pages = pages, .generated = timestamp() };
    }
};

var ts_buf: [32]u8 = undefined;

/// Czas UTC wygenerowania raportu (bez strefy lokalnej — raport może trafić
/// do kogoś w innej strefie).
pub fn timestamp() []const u8 {
    const now: u64 = @intCast(@max(0, std.time.timestamp()));
    const es = std.time.epoch.EpochSeconds{ .secs = now };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(&ts_buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} UTC", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(),
    }) catch "";
}
