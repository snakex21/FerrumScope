//! Strony „Płyta główna”, „Pamięć”, „Grafika”, „Dyski” i „Czujniki”.
//!
//! Wejściem jest wyłącznie `snapshot.Snapshot` (surowe bajty i identyfikatory —
//! z tej maszyny albo z pliku `.sysimg`) plus opcjonalne odczyty na żywo
//! (biblioteki GPU producentów). Interpretacja: `smbios.zig`, `pciids.zig`,
//! `storage_parse.zig`. Każde pole ma źródło i pewność.

const std = @import("std");
const report = @import("report.zig");
const snap = @import("snapshot.zig");
const smbios = @import("smbios.zig");
const pciids = @import("pciids.zig");
const sp = @import("storage_parse.zig");
const gv = @import("win/gpu_vendor.zig");
const links = @import("links.zig");

const Builder = report.Builder;
const Field = report.Field;

pub const Ctx = struct {
    snap: *const snap.Snapshot,
    pci: ?*const pciids.Db = null,
};

// ---------------------------------------------------------------------------
// Pomocnicze
// ---------------------------------------------------------------------------

fn spConf(c: sp.Confidence) report.Confidence {
    return switch (c) {
        .high => .high,
        .medium => .medium,
        .low => .low,
    };
}

fn smConf(c: smbios.Confidence) report.Confidence {
    return switch (c) {
        .none => .unknown,
        .low => .low,
        .medium => .medium,
        .high => .high,
    };
}

/// Pole z napisu SMBIOS: wartość, zaślepka OEM albo brak.
fn strField(b: *Builder, label: []const u8, f: ?smbios.StringField, missing_src: []const u8) void {
    const s = f orelse {
        b.add(.{ .label = label, .value = "—", .state = .unavailable, .confidence = .unknown, .source = missing_src });
        return;
    };
    if (s.value) |v| {
        if (s.placeholder) {
            b.add(.{ .label = label, .value = if (v.len == 0) "(pusty)" else b.dup(v), .state = .placeholder, .confidence = .low, .source = s.spec, .sensitive = s.sensitive });
        } else {
            b.add(.{ .label = label, .value = b.dup(v), .source = s.spec, .sensitive = s.sensitive, .raw = if (s.sensitive) "" else b.fmt("string #{d}", .{s.index}) });
        }
    } else {
        b.add(.{ .label = label, .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.fmt("{s} (napis #{d} nieobecny)", .{ s.spec, s.index }) });
    }
}

fn enumField(b: *Builder, label: []const u8, f: ?smbios.EnumField) void {
    const e = f orelse return;
    b.add(.{ .label = label, .value = e.name orelse b.fmt("nieznany (0x{X:0>2})", .{e.raw}), .raw = b.fmt("0x{X:0>2}", .{e.raw}), .source = e.spec, .confidence = if (e.name != null) .high else .low });
}

pub fn bytesLabel(b: *Builder, n: u64) []const u8 {
    const gib: f64 = @as(f64, @floatFromInt(n)) / (1024.0 * 1024.0 * 1024.0);
    if (n >= 1024 * 1024 * 1024) return b.fmt("{d:.0} GB", .{gib});
    if (n >= 1024 * 1024) return b.fmt("{d} MB", .{n / (1024 * 1024)});
    return b.fmt("{d} KB", .{n / 1024});
}

fn decimalSize(b: *Builder, n: u64) []const u8 {
    const f: f64 = @floatFromInt(n);
    if (n >= 1_000_000_000_000) return b.fmt("{d:.2} TB", .{f / 1e12});
    return b.fmt("{d:.1} GB", .{f / 1e9});
}

fn shortVendor(name: []const u8) []const u8 {
    // „Advanced Micro Devices, Inc. [AMD/ATI]” → „AMD/ATI”.
    if (std.mem.lastIndexOfScalar(u8, name, '[')) |i| {
        if (std.mem.indexOfScalarPos(u8, name, i, ']')) |j| return name[i + 1 .. j];
    }
    return name;
}

fn pciVendor(c: Ctx, vid: u16) ?[]const u8 {
    const db = c.pci orelse return null;
    return db.vendorName(vid);
}

fn pciDevice(c: Ctx, vid: u16, did: u16) ?[]const u8 {
    const db = c.pci orelse return null;
    return db.deviceName(vid, did);
}

fn pciSubsys(c: Ctx, vid: u16, did: u16, sv: u16, sd: u16) ?[]const u8 {
    const db = c.pci orelse return null;
    return db.subsystemName(vid, did, sv, sd);
}

fn pciSource(b: *Builder, c: Ctx) []const u8 {
    if (c.pci) |db| return b.fmt("pci.ids {s}", .{db.version()});
    return "pci.ids (baza niedostępna)";
}

fn collectNote(st: snap.Collect) Field {
    return .{
        .label = "Stan odczytu",
        .value = st.label(),
        .state = switch (st) {
            .ok => .ok,
            .requires_admin => .requires_admin,
            else => .unavailable,
        },
        .confidence = .unknown,
    };
}

fn smbiosTable(c: Ctx) ?smbios.Table {
    const buf = c.snap.smbios orelse return null;
    return smbios.fromRawSmbiosData(buf) catch null;
}

// ---------------------------------------------------------------------------
// Płyta główna
// ---------------------------------------------------------------------------

pub const Chipset = struct {
    name: []const u8,
    vendor: u16,
    device: *const snap.PciDevice,
    method: []const u8,
    confidence: report.Confidence,
};

/// Chipset z identyfikatorów PCI i nazw pci.ids. Heurystyka, jawnie opisana:
///  1. Intel: mostek LPC/eSPI (klasa 06/01) — nazwa pci.ids zawiera model
///     chipsetu („Z690 Chipset LPC/eSPI Controller”).
///  2. AMD (AM4/AM5): urządzenia Promontory mają w nazwie „… Series Chipset …”
///     (np. 1022:43EE „500 Series Chipset USB 3.1 XHCI Controller”).
///  3. Inaczej: nazwa mostka hosta (klasa 06/00) — to kompleks główny CPU,
///     a nie chipset, więc z pewnością `low`.
pub fn detectChipset(b: *Builder, c: Ctx) ?Chipset {
    const db = c.pci orelse return null;
    // 1 i 2: nazwa zawierająca „Chipset”.
    for (c.snap.pci) |*p| {
        if (p.vendor != 0x8086 and p.vendor != 0x1022) continue;
        const name = db.deviceName(p.vendor, p.device) orelse continue;
        const i = std.mem.indexOf(u8, name, "Chipset") orelse continue;
        const is_lpc = p.class != null and p.class.? == 0x06 and p.subclass != null and p.subclass.? == 0x01;
        if (p.vendor == 0x8086 and !is_lpc) continue;
        const vendor = if (p.vendor == 0x8086) "Intel" else "AMD";
        return .{
            .name = b.fmt("{s} {s}", .{ vendor, name[0 .. i + "Chipset".len] }),
            .vendor = p.vendor,
            .device = p,
            .method = b.fmt("nazwa pci.ids urządzenia {X:0>4}:{X:0>4} ({s})", .{ p.vendor, p.device, name }),
            .confidence = .medium,
        };
    }
    for (c.snap.pci) |*p| {
        if (p.class == null or p.class.? != 0x06 or p.subclass == null or p.subclass.? != 0x00) continue;
        const name = db.deviceName(p.vendor, p.device) orelse continue;
        return .{
            .name = b.fmt("{s} {s} (mostek hosta)", .{ shortVendor(db.vendorName(p.vendor) orelse "?"), name }),
            .vendor = p.vendor,
            .device = p,
            .method = "brak urządzenia z nazwą chipsetu; pokazano mostek hosta (kompleks główny CPU)",
            .confidence = .low,
        };
    }
    return null;
}

pub fn buildBoard(arena: std.mem.Allocator, c: Ctx) report.Page {
    var page: report.Page = .{ .id = "board", .title = "Płyta główna" };
    var b = Builder.init(arena, &page);
    const tbl = smbiosTable(c);

    var board: ?smbios.Baseboard = null;
    var system: ?smbios.System = null;
    var bios: ?smbios.Bios = null;
    var chassis: ?smbios.Chassis = null;
    var cpu: ?smbios.Processor = null;
    if (tbl) |t| {
        var it = t.iterator();
        while (it.next()) |s| {
            switch (s.type_id) {
                0 => if (bios == null) {
                    bios = smbios.decodeBios(s);
                },
                1 => if (system == null) {
                    system = smbios.decodeSystem(s);
                },
                2 => if (board == null) {
                    board = smbios.decodeBaseboard(s);
                },
                3 => if (chassis == null) {
                    chassis = smbios.decodeChassis(s);
                },
                4 => if (cpu == null) {
                    cpu = smbios.decodeProcessor(s);
                },
                else => {},
            }
        }
        page.summary = b.fmt("SMBIOS {d}.{d}{s}", .{ t.major, t.minor, if (t.truncated) " (tabela obcięta)" else "" });
    } else {
        page.summary = b.fmt("SMBIOS: {s}", .{c.snap.smbios_status.label()});
    }

    if (board) |bb| {
        const m = if (bb.manufacturer) |f| f.text() orelse "" else "";
        const p = if (bb.product) |f| f.text() orelse "" else "";
        page.headline = b.fmt("{s} {s}", .{ m, p });
    } else page.headline = "Płyta główna nieznana";

    b.section("Płyta główna");
    if (board) |bb| {
        strField(&b, "Producent", bb.manufacturer, "SMBIOS typ 2");
        strField(&b, "Model", bb.product, "SMBIOS typ 2");
        strField(&b, "Rewizja", bb.version, "SMBIOS typ 2");
        strField(&b, "Numer seryjny", bb.serial, "SMBIOS typ 2");
        enumField(&b, "Typ płyty", bb.board_type);
    } else {
        b.add(.{ .label = "SMBIOS typ 2", .value = "—", .state = .unavailable, .confidence = .unknown, .source = if (tbl == null) "brak tabeli SMBIOS" else "tabela nie zawiera struktury typu 2" });
    }

    // --- chipset ---------------------------------------------------------------
    b.section("Chipset");
    if (detectChipset(&b, c)) |cs| {
        b.add(.{ .label = "Chipset", .value = cs.name, .raw = b.fmt("{X:0>4}:{X:0>4} rev {X:0>2}", .{ cs.device.vendor, cs.device.device, cs.device.revision }), .source = cs.method, .confidence = cs.confidence });
        links.chipset(&b, cs.vendor);
    } else {
        b.add(.{ .label = "Chipset", .value = "—", .state = .unavailable, .confidence = .unknown, .source = if (c.snap.pci.len == 0) "brak listy urządzeń PCI" else "nie rozpoznano z pci.ids" });
    }
    for (c.snap.pci) |p| {
        const cls = p.class orelse continue;
        const sub = p.subclass orelse continue;
        const label: ?[]const u8 = if (cls == 0x06 and sub == 0x00 and p.bus == 0 and p.dev == 0 and p.func == 0)
            "Mostek hosta"
        else if (cls == 0x06 and sub == 0x01)
            "Mostek LPC / ISA"
        else if (cls == 0x0C and sub == 0x05)
            "Kontroler SMBus"
        else
            null;
        const l = label orelse continue;
        const name = pciDevice(c, p.vendor, p.device) orelse (if (p.desc.len > 0) p.desc else "nieznane");
        b.add(.{ .label = l, .value = b.dup(name), .raw = b.fmt("{X:0>4}:{X:0>4} rev {X:0>2} @ {x:0>2}:{x:0>2}.{d}", .{ p.vendor, p.device, p.revision, p.bus, p.dev, p.func }), .source = pciSource(&b, c) });
    }

    // --- BIOS -------------------------------------------------------------------
    b.section("BIOS");
    if (bios) |bi| {
        strField(&b, "Producent", bi.vendor, "SMBIOS typ 0");
        strField(&b, "Wersja", bi.version, "SMBIOS typ 0");
        strField(&b, "Data", bi.release_date, "SMBIOS typ 0");
        if (bi.rom_size) |r| if (r.bytes) |n| b.add(.{ .label = "Rozmiar ROM", .value = bytesLabel(&b, n), .raw = b.fmt("0x{X:0>2}", .{r.raw}), .source = r.spec });
        if (bi.bios_release) |r| if (r.supported) b.add(.{ .label = "Wydanie BIOS", .value = b.fmt("{d}.{d}", .{ r.major, r.minor }), .source = r.spec });
        if (bi.ec_release) |r| if (r.supported) b.add(.{ .label = "Firmware EC", .value = b.fmt("{d}.{d}", .{ r.major, r.minor }), .source = r.spec });
    } else b.add(.{ .label = "SMBIOS typ 0", .value = "—", .state = .unavailable, .confidence = .unknown });

    // --- system --------------------------------------------------------------------
    b.section("System");
    if (system) |sy| {
        strField(&b, "Producent", sy.manufacturer, "SMBIOS typ 1");
        strField(&b, "Produkt", sy.product, "SMBIOS typ 1");
        strField(&b, "Wersja", sy.version, "SMBIOS typ 1");
        strField(&b, "Rodzina", sy.family, "SMBIOS typ 1");
        strField(&b, "SKU", sy.sku, "SMBIOS typ 1");
        strField(&b, "Numer seryjny", sy.serial, "SMBIOS typ 1");
        if (sy.uuid) |u| {
            var ub: [36]u8 = undefined;
            switch (u.state) {
                .present => b.add(.{ .label = "UUID", .value = b.dup(u.format(&ub)), .source = u.spec, .sensitive = true }),
                else => b.add(.{ .label = "UUID", .value = @tagName(u.state), .state = .placeholder, .confidence = .low, .source = u.spec }),
            }
        }
    }
    if (chassis) |ch| {
        enumField(&b, "Obudowa", ch.chassis_type);
        strField(&b, "Producent obudowy", ch.manufacturer, "SMBIOS typ 3");
    }

    // --- gniazdo CPU ---------------------------------------------------------------
    if (cpu) |p| {
        b.section("Gniazdo procesora (SMBIOS)");
        enumField(&b, "Gniazdo", p.upgrade);
        strField(&b, "Oznaczenie gniazda", p.socket_designation, "SMBIOS typ 4");
        strField(&b, "Wersja procesora", p.version, "SMBIOS typ 4");
        if (p.external_clock_mhz) |n| if (n.value) |v| b.add(.{ .label = "Zegar zewnętrzny", .value = b.fmt("{d} MHz", .{v}), .source = n.spec, .confidence = .medium });
        if (p.max_speed_mhz) |n| if (n.value) |v| b.add(.{ .label = "Maks. zegar (firmware)", .value = b.fmt("{d} MHz", .{v}), .source = n.spec, .confidence = .low, .note = "wartość wpisana przez producenta płyty" });
        if (p.current_speed_mhz) |n| if (n.value) |v| b.add(.{ .label = "Zegar przy starcie", .value = b.fmt("{d} MHz", .{v}), .source = n.spec, .confidence = .low });
    }

    // --- wentylatory -------------------------------------------------------------------
    b.section("Wentylatory i napięcia płyty");
    b.add(.{ .label = "Wentylatory płyty", .value = "—", .state = .requires_driver, .confidence = .unknown, .source = "wymagają dostępu do układu Super I/O (porty I/O) — tylko przez sterownik jądra; planowane, celowo niezaimplementowane" });

    // --- PCI ------------------------------------------------------------------------------
    b.section("Urządzenia PCI");
    if (c.snap.pci.len == 0) b.add(collectNote(c.snap.pci_status));
    for (c.snap.pci) |p| {
        const dn = pciDevice(c, p.vendor, p.device);
        const vn = pciVendor(c, p.vendor);
        const value = if (dn) |d| b.fmt("{s} {s}", .{ shortVendor(vn orelse "?"), d }) else if (p.desc.len > 0) p.desc else "nieznane";
        b.add(.{
            .label = b.fmt("{x:0>2}:{x:0>2}.{d}", .{ p.bus, p.dev, p.func }),
            .value = value,
            .raw = b.fmt("{X:0>4}:{X:0>4} sub {X:0>4}:{X:0>4} rev {X:0>2}", .{ p.vendor, p.device, p.subvendor, p.subdevice, p.revision }),
            .source = if (dn != null) pciSource(&b, c) else "opis sterownika Windows (brak w pci.ids)",
            .confidence = if (dn != null) .high else .medium,
        });
    }
    return page;
}

// ---------------------------------------------------------------------------
// Pamięć
// ---------------------------------------------------------------------------

pub fn buildMemory(arena: std.mem.Allocator, c: Ctx) report.Page {
    var page: report.Page = .{ .id = "memory", .title = "Pamięć" };
    var b = Builder.init(arena, &page);
    const tbl = smbiosTable(c) orelse {
        page.headline = "Brak danych SMBIOS";
        b.section("Pamięć");
        b.add(collectNote(c.snap.smbios_status));
        return page;
    };
    const sum = smbios.summarizeMemory(tbl);
    const type_name = if (sum.memory_type) |t| smbios.memoryTypeName(t) orelse "?" else "?";
    page.headline = b.fmt("{s} {s}", .{ bytesLabel(&b, sum.total_bytes), type_name });
    page.summary = "Moduły z SMBIOS typ 16/17. Timingi z SPD wymagają dostępu do SMBus — planowane (sterownik).";

    b.section("Podsumowanie");
    b.add(.{ .label = "Rozmiar całkowity", .value = bytesLabel(&b, sum.total_bytes), .raw = b.fmt("{d} B", .{sum.total_bytes}), .source = "suma rozmiarów SMBIOS typ 17", .note = if (sum.unknown_size_modules > 0) "część modułów ma nieznany rozmiar" else "" });
    b.add(.{ .label = "Typ", .value = type_name, .source = "SMBIOS typ 17, offset 12h", .confidence = if (sum.mixed_types) .low else .high, .note = if (sum.mixed_types) "moduły zgłaszają różne typy" else "" });
    b.add(.{ .label = "Gniazda", .value = b.fmt("{d} z {d} zajęte", .{ sum.populated_slots, sum.total_slots }), .source = "liczba struktur SMBIOS typ 17 (pamięć systemowa)" });
    if (sum.channels) |ch| {
        b.add(.{ .label = "Kanały", .value = b.fmt("{d}", .{ch}), .source = sum.channel_method, .confidence = smConf(sum.channel_confidence), .state = .estimate, .note = "heurystyka z nazw gniazd (Device/Bank Locator)" });
    } else {
        b.add(.{ .label = "Kanały", .value = "—", .state = .unavailable, .confidence = .unknown, .source = "nie da się wywnioskować z nazw gniazd" });
    }
    // Prędkość pierwszego obsadzonego modułu — jak „DRAM Frequency” w CPU-Z.
    var it0 = tbl.iterator();
    while (it0.next()) |s0| {
        if (s0.type_id != 17) continue;
        const d0 = smbios.decodeMemoryDevice(s0) orelse continue;
        if (!d0.populated()) continue;
        if (d0.configured_speed) |sp0| if (sp0.mts) |v| {
            b.add(.{ .label = "Prędkość", .value = b.fmt("{d} MT/s", .{v}), .source = sp0.spec });
            b.add(.{ .label = "Częstotliwość DRAM", .value = b.fmt("{d} MHz", .{v / 2}), .source = "Configured Memory Speed / 2 (DDR)", .confidence = .high });
        };
        break;
    }
    b.add(.{ .label = "Timingi (SPD)", .value = "—", .state = .requires_driver, .confidence = .unknown, .source = "odczyt SPD przez SMBus wymaga sterownika — planowane" });

    var it = tbl.iterator();
    while (it.next()) |s| {
        if (s.type_id == 16) {
            const a = smbios.decodeMemoryArray(s) orelse continue;
            b.section("Macierz pamięci (typ 16)");
            enumField(&b, "Położenie", a.location);
            enumField(&b, "Zastosowanie", a.use);
            enumField(&b, "Korekcja błędów", a.error_correction);
            if (a.max_capacity) |m| if (m.bytes) |n| b.add(.{ .label = "Maks. pojemność", .value = bytesLabel(&b, n), .source = m.spec, .confidence = .medium, .note = "deklaracja firmware" });
            if (a.num_devices) |n| if (n.value) |v| b.add(.{ .label = "Liczba gniazd", .value = b.fmt("{d}", .{v}), .source = n.spec });
        }
    }

    it = tbl.iterator();
    while (it.next()) |s| {
        if (s.type_id != 17) continue;
        const d = smbios.decodeMemoryDevice(s) orelse continue;
        const loc = if (d.device_locator) |f| f.text() orelse "?" else "?";
        b.section(b.fmt("Gniazdo {s}", .{loc}));
        strField(&b, "Bank", d.bank_locator, "SMBIOS typ 17");
        if (!d.populated()) {
            b.add(.{ .label = "Moduł", .value = "pusty", .source = if (d.size) |z| z.spec else "SMBIOS typ 17" });
            continue;
        }
        if (d.size) |z| {
            if (z.bytes) |n| {
                b.add(.{ .label = "Rozmiar", .value = bytesLabel(&b, n), .raw = b.fmt("0x{X:0>4}", .{z.raw}), .source = z.spec });
            } else b.add(.{ .label = "Rozmiar", .value = "nieznany", .state = .unavailable, .confidence = .unknown, .source = z.spec });
        }
        enumField(&b, "Typ", d.memory_type);
        if (d.type_detail) |td| {
            var nb: [16][]const u8 = undefined;
            const names = td.names(&nb);
            if (names.len > 0) {
                var lst: std.ArrayList(u8) = .empty;
                for (names, 0..) |n, i| {
                    if (i > 0) lst.appendSlice(arena, ", ") catch {};
                    lst.appendSlice(arena, n) catch {};
                }
                b.add(.{ .label = "Szczegóły typu", .value = lst.items, .raw = b.fmt("0x{X:0>4}", .{td.raw}), .source = td.spec });
            }
        }
        enumField(&b, "Format", d.form_factor);
        if (d.speed) |sp_| if (sp_.mts) |v| b.add(.{ .label = "Prędkość maks.", .value = b.fmt("{d} MT/s", .{v}), .source = sp_.spec });
        if (d.configured_speed) |sp_| if (sp_.mts) |v| b.add(.{ .label = "Prędkość skonfigurowana", .value = b.fmt("{d} MT/s", .{v}), .source = sp_.spec, .note = b.fmt("zegar pamięci ~{d} MHz (DDR: połowa MT/s)", .{v / 2}) });
        strField(&b, "Producent", d.manufacturer, "SMBIOS typ 17");
        strField(&b, "Part number", d.part_number, "SMBIOS typ 17");
        strField(&b, "Numer seryjny", d.serial, "SMBIOS typ 17");
        if (d.rank) |r| if (r.value) |v| b.add(.{ .label = "Ranki", .value = b.fmt("{d}", .{v}), .source = r.spec });
        if (d.configured_voltage_mv) |v| if (v.value) |mv| b.add(.{ .label = "Napięcie", .value = b.fmt("{d:.3} V", .{@as(f64, @floatFromInt(mv)) / 1000.0}), .source = v.spec });
        if (d.data_width_bits) |w| if (w.value) |v| b.add(.{ .label = "Szerokość danych", .value = b.fmt("{d} bit", .{v}), .source = w.spec });
    }
    return page;
}

// ---------------------------------------------------------------------------
// Grafika
// ---------------------------------------------------------------------------

pub const GpuLive = struct {
    libraries: []const gv.LibraryInfo = &.{},
    adapters: []const gv.Adapter = &.{},
};

fn readingField(b: *Builder, label: []const u8, r: ?gv.Reading, fmt_unit: []const u8, why: []const u8) void {
    if (r) |x| {
        b.add(.{ .label = label, .value = b.fmt("{d:.0} {s}", .{ x.value, fmt_unit }), .source = x.source, .confidence = .high });
    } else {
        b.add(.{ .label = label, .value = "—", .state = .unavailable, .confidence = .unknown, .source = why });
    }
}

fn matchVendorAdapter(live: GpuLive, g: snap.GpuAdapter, pci: ?*const snap.PciDevice) ?*const gv.Adapter {
    for (live.adapters) |*a| {
        if (pci) |p| if (a.pci) |loc| {
            if (loc.bus == p.bus and loc.device == p.dev and loc.function == p.func) return a;
        };
    }
    for (live.adapters) |*a| {
        if (a.vendor_id != null and a.device_id != null and a.vendor_id.? == g.vendor and a.device_id.? == g.device) return a;
    }
    return null;
}

fn vendorReason(live: GpuLive, vendor: u16) []const u8 {
    const want: []const u8 = switch (vendor) {
        0x1002 => "atiadlxx",
        0x10DE => "nvapi",
        else => return "brak biblioteki producenta dla tego układu (obsługiwane: AMD ADL, NVIDIA NVAPI)",
    };
    for (live.libraries) |l| {
        if (std.mem.indexOf(u8, l.name, want) != null) return if (l.reason.len > 0) l.reason else @tagName(l.status);
    }
    return "biblioteka producenta nie była odpytywana (tryb replay albo CLI bez --live)";
}

pub fn buildGraphics(arena: std.mem.Allocator, c: Ctx, live: GpuLive) report.Page {
    var page: report.Page = .{ .id = "graphics", .title = "Grafika" };
    var b = Builder.init(arena, &page);
    var first = true;
    page.summary = "DXGI + SetupAPI + pci.ids; zegary/temperatury z bibliotek producenta (opcjonalne, tylko odczyt).";
    if (c.snap.gpus.len == 0) {
        b.section("Karty graficzne");
        b.add(collectNote(c.snap.gpu_status));
    }
    for (c.snap.gpus) |g| {
        if (g.software) continue;
        const pci = c.snap.findPci(g.vendor, g.device, g.subsys);
        const chip = pciDevice(c, g.vendor, g.device);
        const board = pciSubsys(c, g.vendor, g.device, g.subVendor(), g.subDevice());
        const board_vendor = pciVendor(c, g.subVendor());
        if (first) {
            page.headline = b.dup(g.name);
            first = false;
        }
        b.section(b.fmt("GPU: {s}", .{g.name}));
        b.add(.{ .label = "Nazwa (sterownik)", .value = b.dup(g.name), .source = "DXGI_ADAPTER_DESC1.Description" });
        if (chip) |n| b.add(.{ .label = "Układ GPU", .value = n, .source = pciSource(&b, c) }) else b.add(.{ .label = "Układ GPU", .value = "—", .state = .unavailable, .confidence = .unknown, .source = "brak w pci.ids" });
        if (board) |n| {
            b.add(.{ .label = "Karta", .value = b.fmt("{s} {s}", .{ shortVendor(board_vendor orelse ""), n }), .source = b.fmt("{s} (subsystem)", .{pciSource(&b, c)}) });
        } else if (board_vendor) |v| {
            b.add(.{ .label = "Producent karty", .value = v, .source = b.fmt("{s} (subsystem vendor)", .{pciSource(&b, c)}), .confidence = .medium, .note = "modelu karty brak w pci.ids" });
        }
        b.add(.{ .label = "Identyfikator", .value = b.fmt("{X:0>4}:{X:0>4}", .{ g.vendor, g.device }), .raw = b.fmt("VEN_{X:0>4}&DEV_{X:0>4}", .{ g.vendor, g.device }), .source = "DXGI VendorId/DeviceId" });
        b.add(.{ .label = "Subsystem", .value = b.fmt("{X:0>4}:{X:0>4}", .{ g.subVendor(), g.subDevice() }), .raw = b.fmt("0x{X:0>8}", .{g.subsys}), .source = "DXGI SubSysId" });
        b.add(.{ .label = "Rewizja", .value = b.fmt("{X:0>2}", .{g.revision}), .source = "DXGI Revision" });
        b.add(.{ .label = "Pamięć dedykowana", .value = bytesLabel(&b, g.dedicated_vram), .raw = b.fmt("{d} B", .{g.dedicated_vram}), .source = "DXGI DedicatedVideoMemory" });
        b.add(.{ .label = "Pamięć współdzielona", .value = bytesLabel(&b, g.shared_sys), .source = "DXGI SharedSystemMemory" });
        if (pci) |p| {
            b.add(.{ .label = "Lokalizacja PCI", .value = b.fmt("{x:0>2}:{x:0>2}.{d}", .{ p.bus, p.dev, p.func }), .source = "SetupAPI DEVPKEY_Device_BusNumber/Address" });
            if (p.driver_version.len > 0) b.add(.{ .label = "Sterownik", .value = p.driver_version, .source = "DEVPKEY_Device_DriverVersion" });
            if (p.driver_date.len > 0) b.add(.{ .label = "Data sterownika", .value = p.driver_date, .source = "DEVPKEY_Device_DriverDate" });
            if (p.driver_provider.len > 0) b.add(.{ .label = "Dostawca sterownika", .value = p.driver_provider, .source = "DEVPKEY_Device_DriverProvider" });
            if (p.link_cur_width) |w| {
                const sp_ = if (p.link_cur_speed) |s| snap.linkSpeedLabel(s) else "?";
                const mx = if (p.link_max_width) |mw| b.fmt(" (maks. x{d} {s})", .{ mw, if (p.link_max_speed) |s| snap.linkSpeedLabel(s) else "?" }) else "";
                b.add(.{ .label = "Łącze PCIe", .value = b.fmt("x{d} {s}{s}", .{ w, sp_, mx }), .source = "DEVPKEY_PciDevice_CurrentLinkWidth/Speed (pciprop.h)", .note = "karta w stanie oszczędzania energii może zgłaszać niższą prędkość" });
            } else b.add(.{ .label = "Łącze PCIe", .value = "—", .state = .unavailable, .confidence = .unknown, .source = "system nie podał właściwości łącza" });
        } else {
            b.add(.{ .label = "Sterownik / łącze", .value = "—", .state = .unavailable, .confidence = .unknown, .source = "nie znaleziono urządzenia PCI dla tej karty" });
        }

        // --- telemetria producenta ------------------------------------------------
        b.section(b.fmt("Czujniki GPU: {s}", .{g.name}));
        if (matchVendorAdapter(live, g, pci)) |a| {
            const r = a.readings;
            const why = b.fmt("{s}: brak odczytu tej wartości ({s})", .{ a.vendor_library, a.sensor_path });
            b.add(.{ .label = "Źródło", .value = b.fmt("{s} ({s})", .{ a.vendor_library, a.sensor_path }), .source = "biblioteka producenta ładowana dynamicznie, tylko odczyt" });
            readingField(&b, "Zegar GPU", r.gpu_clock_mhz, "MHz", why);
            readingField(&b, "Zegar pamięci", r.mem_clock_mhz, "MHz", why);
            readingField(&b, "Temperatura GPU", r.temp_edge_c, "°C", why);
            readingField(&b, "Hot spot", r.temp_hotspot_c, "°C", why);
            readingField(&b, "Temperatura pamięci", r.temp_mem_c, "°C", why);
            readingField(&b, "Wentylator", r.fan_rpm, "RPM", why);
            readingField(&b, "Wentylator (%)", r.fan_percent, "%", why);
            readingField(&b, "Obciążenie GPU", r.load_percent, "%", why);
            readingField(&b, "Pobór mocy", r.power_w, "W", why);
            if (r.voltage_v) |v| b.add(.{ .label = "Napięcie GPU", .value = b.fmt("{d:.3} V", .{v.value}), .source = v.source });
            if (r.vram_type) |t| b.add(.{ .label = "Typ pamięci", .value = b.dup(t.text.slice()), .source = t.source });
            if (r.driver_version) |t| b.add(.{ .label = "Wersja pakietu sterownika", .value = b.dup(t.text.slice()), .source = t.source });
        } else {
            const why = vendorReason(live, g.vendor);
            for ([_][]const u8{ "Zegar GPU", "Temperatura GPU", "Wentylator", "Obciążenie GPU" }) |l| {
                b.add(.{ .label = l, .value = "—", .state = .unavailable, .confidence = .unknown, .source = why });
            }
        }
        links.gpuScoped(&b, g.vendor, if (board) |n| n else g.name, b.dup(g.name));
    }
    if (first) page.headline = "Brak sprzętowej karty graficznej";
    return page;
}

// ---------------------------------------------------------------------------
// Dyski
// ---------------------------------------------------------------------------

fn derivedField(b: *Builder, label: []const u8, comptime T: type, d: ?sp.Derived(T), comptime f: []const u8) void {
    const x = d orelse return;
    b.add(.{ .label = label, .value = b.fmt(f, .{x.value}), .source = x.source, .confidence = spConf(x.confidence), .note = x.note });
}

pub fn buildStorage(arena: std.mem.Allocator, c: Ctx) report.Page {
    var page: report.Page = .{ .id = "storage", .title = "Dyski" };
    var b = Builder.init(arena, &page);
    page.headline = b.fmt("{d} dysków fizycznych", .{c.snap.disks.len});
    page.summary = if (c.snap.is_admin)
        "IOCTL_STORAGE_QUERY_PROPERTY; zdrowie: NVMe log 02h, ATA SMART (pass-through, tylko odczyt)."
    else
        "IOCTL_STORAGE_QUERY_PROPERTY; zdrowie NVMe bez uprawnień. SMART dysków SATA wymaga uruchomienia jako administrator.";
    if (c.snap.disks.len == 0) {
        b.section("Dyski");
        b.add(collectNote(c.snap.disk_status));
    }
    for (c.snap.disks) |d| {
        const desc = sp.parseDeviceDescriptor(d.descriptor) catch null;
        var mb: [128]u8 = undefined;
        const model = if (desc) |*x| x.modelName(&mb) else "nieznany";
        b.section(b.fmt("Dysk {d}: {s}", .{ d.index, model }));
        b.add(.{ .label = "Model", .value = b.dup(model), .source = "STORAGE_DEVICE_DESCRIPTOR (Vendor/ProductId)" });
        if (desc) |x| {
            if (x.revision_status == .ok) b.add(.{ .label = "Firmware", .value = b.dup(x.product_revision.slice()), .source = "STORAGE_DEVICE_DESCRIPTOR.ProductRevisionOffset" });
            if (x.serial_status == .ok) b.add(.{ .label = "Numer seryjny", .value = b.dup(x.serial.slice()), .source = b.fmt("STORAGE_DEVICE_DESCRIPTOR.SerialNumberOffset ({s})", .{@tagName(x.serial_encoding)}), .sensitive = true });
            b.add(.{ .label = "Magistrala", .value = x.bus_type.name(), .raw = b.fmt("{d}", .{x.bus_type_raw}), .source = "STORAGE_DEVICE_DESCRIPTOR.BusType" });
            if (x.removable) b.add(.{ .label = "Wymienny", .value = "tak", .source = "STORAGE_DEVICE_DESCRIPTOR.RemovableMedia" });
        }
        if (d.size_bytes) |n| b.add(.{ .label = "Pojemność", .value = decimalSize(&b, n), .raw = b.fmt("{d} B", .{n}), .source = "IOCTL_DISK_GET_DRIVE_GEOMETRY_EX / GET_LENGTH_INFO" });
        if (d.rotational) |r| b.add(.{ .label = "Rodzaj", .value = if (r) "HDD (obrotowy)" else "SSD / brak kary wyszukiwania", .source = "StorageDeviceSeekPenaltyProperty", .confidence = .medium });

        // --- zdrowie ---------------------------------------------------------------
        var summary: ?sp.HealthSummary = null;
        var nvme: ?sp.NvmeHealth = null;
        if (d.nvme_log) |log| {
            nvme = sp.parseNvmeHealthLog(log) catch null;
            if (nvme) |n| summary = n.summary;
        } else if (d.ata_smart) |data| {
            const a = sp.parseAtaSmart(data, d.ata_thresholds, .{ .rotational = d.rotational }) catch null;
            if (a) |x| summary = x.summary;
        }
        if (summary) |s| {
            b.add(.{
                .label = "Stan zdrowia",
                .value = switch (s.status) {
                    .ok => "dobry",
                    .warning => "ostrzeżenie",
                    .critical => "krytyczny",
                    .unknown => "nieznany",
                },
                .source = if (d.health_source.len > 0) d.health_source else "SMART / NVMe",
                .note = s.reason,
                .confidence = .medium,
            });
            derivedField(&b, "Temperatura", i32, s.temperature_c, "{d} °C");
            derivedField(&b, "Czas pracy", u64, s.power_on_hours, "{d} h");
            derivedField(&b, "Liczba uruchomień", u64, s.power_cycles, "{d}");
            derivedField(&b, "Zużycie", u8, s.percentage_used, "{d} %");
            if (s.data_written_bytes) |x| b.add(.{ .label = "Zapisano", .value = b.fmt("{d:.2} TB", .{sp.NvmeHealth.bytesToTB(x.value)}), .source = x.source, .confidence = spConf(x.confidence), .note = x.note });
            if (s.data_read_bytes) |x| b.add(.{ .label = "Odczytano", .value = b.fmt("{d:.2} TB", .{sp.NvmeHealth.bytesToTB(x.value)}), .source = x.source, .confidence = spConf(x.confidence) });
            derivedField(&b, "Niebezpieczne wyłączenia", u64, s.unsafe_shutdowns, "{d}");
            derivedField(&b, "Błędy nośnika", u64, s.media_errors, "{d}");
            derivedField(&b, "Realokowane sektory", u64, s.reallocated, "{d}");
            derivedField(&b, "Sektory oczekujące", u64, s.pending, "{d}");
            derivedField(&b, "Nienaprawialne", u64, s.uncorrectable, "{d}");
            if (nvme) |n| b.add(.{ .label = "Zapas (spare)", .value = b.fmt("{d} % (próg {d} %)", .{ n.available_spare, n.available_spare_threshold }), .source = "NVMe log 02h, bajty 3..4" });
        } else {
            b.add(.{
                .label = "Stan zdrowia",
                .value = "—",
                .state = switch (d.health) {
                    .requires_admin => .requires_admin,
                    else => .unavailable,
                },
                .confidence = .unknown,
                .source = if (d.health_note.len > 0) d.health_note else d.health.label(),
                .note = if (d.health_error != 0) b.fmt("kod Win32 {d}", .{d.health_error}) else "",
            });
        }
    }
    return page;
}

// ---------------------------------------------------------------------------
// Czujniki — zbiorczo (CPU obciążenie, GPU, wentylatory, dyski)
// ---------------------------------------------------------------------------

pub fn addSensorSections(b: *Builder, c: Ctx, live: GpuLive) void {
    b.section("Wentylatory");
    var any_fan = false;
    for (live.adapters) |a| {
        if (a.readings.fan_rpm) |r| {
            any_fan = true;
            b.add(.{ .label = b.fmt("GPU: {s}", .{a.name.slice()}), .value = b.fmt("{d:.0} RPM", .{r.value}), .source = r.source });
        }
        if (a.readings.fan_percent) |r| b.add(.{ .label = b.fmt("GPU: {s} (%)", .{a.name.slice()}), .value = b.fmt("{d:.0} %", .{r.value}), .source = r.source });
    }
    if (!any_fan) b.add(.{ .label = "Wentylator GPU", .value = "—", .state = .unavailable, .confidence = .unknown, .source = "brak odczytu z bibliotek producenta (ADL/NVAPI)" });
    b.add(.{ .label = "Wentylatory płyty głównej", .value = "—", .state = .requires_driver, .confidence = .unknown, .source = "Super I/O przez porty I/O wymaga sterownika jądra — planowane" });

    b.section("GPU");
    var any_gpu = false;
    for (live.adapters) |a| {
        const r = a.readings;
        const n = a.name.slice();
        inline for (.{
            .{ "temp_edge_c", "temperatura", "°C" },
            .{ "temp_hotspot_c", "hot spot", "°C" },
            .{ "load_percent", "obciążenie", "%" },
            .{ "gpu_clock_mhz", "zegar", "MHz" },
            .{ "power_w", "moc", "W" },
        }) |m| {
            if (@field(r, m[0])) |x| {
                any_gpu = true;
                b.add(.{ .label = b.fmt("{s} — {s}", .{ n, m[1] }), .value = b.fmt("{d:.0} {s}", .{ x.value, m[2] }), .source = x.source });
            }
        }
    }
    if (!any_gpu) {
        for (live.libraries) |l| b.add(.{ .label = l.name, .value = "—", .state = .unavailable, .confidence = .unknown, .source = l.reason });
        if (live.libraries.len == 0) b.add(.{ .label = "GPU", .value = "—", .state = .unavailable, .confidence = .unknown, .source = "biblioteki producentów nie były odpytywane" });
    }

    b.section("Dyski — temperatury");
    for (c.snap.disks) |d| {
        var t: ?sp.Derived(i32) = null;
        if (d.nvme_log) |log| {
            if (sp.parseNvmeHealthLog(log)) |n| t = n.summary.temperature_c else |_| {}
        } else if (d.ata_smart) |data| {
            if (sp.parseAtaSmart(data, d.ata_thresholds, .{ .rotational = d.rotational })) |a| t = a.summary.temperature_c else |_| {}
        }
        const desc = sp.parseDeviceDescriptor(d.descriptor) catch null;
        var mb: [128]u8 = undefined;
        const model = if (desc) |*x| x.modelName(&mb) else "dysk";
        if (t) |x| {
            b.add(.{ .label = b.fmt("Dysk {d}: {s}", .{ d.index, model }), .value = b.fmt("{d} °C", .{x.value}), .source = x.source, .confidence = spConf(x.confidence) });
        } else {
            b.add(.{ .label = b.fmt("Dysk {d}: {s}", .{ d.index, model }), .value = "—", .state = if (d.health == .requires_admin) .requires_admin else .unavailable, .confidence = .unknown, .source = if (d.health_note.len > 0) d.health_note else d.health.label() });
        }
    }
}
