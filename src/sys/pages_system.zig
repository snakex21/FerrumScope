//! Strony „Płyta główna”, „Pamięć”, „Grafika”, „Dyski” i „Czujniki”.
//!
//! Wejściem jest wyłącznie `snapshot.Snapshot` (surowe bajty i identyfikatory —
//! z tej maszyny albo z pliku `.sysimg`) plus opcjonalne odczyty na żywo
//! (biblioteki GPU producentów). Interpretacja: `smbios.zig`, `pciids.zig`,
//! `storage_parse.zig`. Każde pole ma źródło i pewność.
//!
//! Tytuły sekcji, etykiety pól i opisy przechodzą przez katalog tłumaczeń
//! (`b.t` / `b.tf` / `b.tp`); odwołania do specyfikacji SMBIOS, nazwy API
//! i jednostki zostają bez tłumaczenia.

const std = @import("std");
const report = @import("report.zig");
const snap = @import("snapshot.zig");
const smbios = @import("smbios.zig");
const pciids = @import("pciids.zig");
const sp = @import("storage_parse.zig");
const gv = @import("win/gpu_vendor.zig");
const links = @import("links.zig");
const lookup = @import("lookup.zig");
const i18n = @import("../i18n/i18n.zig");

const Builder = report.Builder;
const Field = report.Field;

pub const Ctx = struct {
    snap: *const snap.Snapshot,
    pci: ?*const pciids.Db = null,
    lookup: lookup.Tables = .{},
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
/// `label` jest już przetłumaczona w miejscu wywołania (przez `b.t`).
fn strField(b: *Builder, label: []const u8, f: ?smbios.StringField, missing_src: []const u8) void {
    const s = f orelse {
        b.add(.{ .label = label, .value = "—", .state = .unavailable, .confidence = .unknown, .source = missing_src });
        return;
    };
    if (s.value) |v| {
        if (s.placeholder) {
            b.add(.{ .label = label, .value = if (v.len == 0) b.t("(pusty)") else b.dup(v), .state = .placeholder, .confidence = .low, .source = s.spec, .sensitive = s.sensitive });
        } else {
            b.add(.{ .label = label, .value = b.dup(v), .source = s.spec, .sensitive = s.sensitive, .raw = if (s.sensitive) "" else b.fmt("string #{d}", .{s.index}) });
        }
    } else {
        b.add(.{ .label = label, .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.tf("{spec} (napis #{index} nieobecny)", .{ .spec = s.spec, .index = s.index }) });
    }
}

/// `label` jest już przetłumaczona w miejscu wywołania (przez `b.t`).
fn enumField(b: *Builder, label: []const u8, f: ?smbios.EnumField) void {
    const e = f orelse return;
    const raw = b.fmt("0x{X:0>2}", .{e.raw});
    b.add(.{ .label = label, .value = e.name orelse b.tf("nieznany ({raw})", .{ .raw = raw }), .raw = raw, .source = e.spec, .confidence = if (e.name != null) .high else .low });
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
    return b.t("pci.ids (baza niedostępna)");
}

fn collectNote(b: *Builder, st: snap.Collect) Field {
    return .{
        .label = b.t("Stan odczytu"),
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
            .method = b.tf("nazwa pci.ids urządzenia {id} ({name})", .{ .id = b.fmt("{X:0>4}:{X:0>4}", .{ p.vendor, p.device }), .name = name }),
            .confidence = .medium,
        };
    }
    for (c.snap.pci) |*p| {
        if (p.class == null or p.class.? != 0x06 or p.subclass == null or p.subclass.? != 0x00) continue;
        const name = db.deviceName(p.vendor, p.device) orelse continue;
        return .{
            .name = b.tf("{vendor} {name} (mostek hosta)", .{ .vendor = shortVendor(db.vendorName(p.vendor) orelse "?"), .name = name }),
            .vendor = p.vendor,
            .device = p,
            .method = b.t("brak urządzenia z nazwą chipsetu; pokazano mostek hosta (kompleks główny CPU)"),
            .confidence = .low,
        };
    }
    return null;
}

pub fn buildBoard(arena: std.mem.Allocator, c: Ctx) report.Page {
    var page: report.Page = .{ .id = "board", .title = "" };
    var b = Builder.init(arena, &page);
    page.title = b.t("Płyta główna");
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
        page.summary = if (t.truncated)
            b.tf("SMBIOS {major}.{minor} (tabela obcięta)", .{ .major = t.major, .minor = t.minor })
        else
            b.fmt("SMBIOS {d}.{d}", .{ t.major, t.minor });
    } else {
        page.summary = b.fmt("SMBIOS: {s}", .{c.snap.smbios_status.label()});
    }

    if (board) |bb| {
        const m = if (bb.manufacturer) |f| f.text() orelse "" else "";
        const p = if (bb.product) |f| f.text() orelse "" else "";
        page.headline = b.fmt("{s} {s}", .{ m, p });
    } else page.headline = b.t("Płyta główna nieznana");

    b.section(b.t("Płyta główna"));
    if (board) |bb| {
        strField(&b, b.t("Producent"), bb.manufacturer, "SMBIOS typ 2");
        strField(&b, b.t("Model"), bb.product, "SMBIOS typ 2");
        strField(&b, b.t("Rewizja"), bb.version, "SMBIOS typ 2");
        strField(&b, b.t("Numer seryjny"), bb.serial, "SMBIOS typ 2");
        enumField(&b, b.t("Typ płyty"), bb.board_type);
    } else {
        b.add(.{ .label = "SMBIOS typ 2", .value = "—", .state = .unavailable, .confidence = .unknown, .source = if (tbl == null) b.t("brak tabeli SMBIOS") else b.t("tabela nie zawiera struktury typu 2") });
    }

    // --- chipset ---------------------------------------------------------------
    b.section(b.t("Chipset"));
    if (detectChipset(&b, c)) |cs| {
        b.add(.{ .label = b.t("Chipset"), .value = cs.name, .raw = b.fmt("{X:0>4}:{X:0>4} rev {X:0>2}", .{ cs.device.vendor, cs.device.device, cs.device.revision }), .source = cs.method, .confidence = cs.confidence });
        links.chipset(&b, cs.vendor);
    } else {
        b.add(.{ .label = b.t("Chipset"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = if (c.snap.pci.len == 0) b.t("brak listy urządzeń PCI") else b.t("nie rozpoznano z pci.ids") });
    }
    for (c.snap.pci) |p| {
        const cls = p.class orelse continue;
        const sub = p.subclass orelse continue;
        const label: ?[]const u8 = if (cls == 0x06 and sub == 0x00 and p.bus == 0 and p.dev == 0 and p.func == 0)
            b.t("Mostek hosta")
        else if (cls == 0x06 and sub == 0x01)
            b.t("Mostek LPC / ISA")
        else if (cls == 0x0C and sub == 0x05)
            b.t("Kontroler SMBus")
        else
            null;
        const l = label orelse continue;
        const name = pciDevice(c, p.vendor, p.device) orelse (if (p.desc.len > 0) p.desc else b.t("nieznane"));
        b.add(.{ .label = l, .value = b.dup(name), .raw = b.fmt("{X:0>4}:{X:0>4} rev {X:0>2} @ {x:0>2}:{x:0>2}.{d}", .{ p.vendor, p.device, p.revision, p.bus, p.dev, p.func }), .source = pciSource(&b, c) });
    }

    // --- BIOS -------------------------------------------------------------------
    b.section(b.t("BIOS"));
    if (bios) |bi| {
        strField(&b, b.t("Producent"), bi.vendor, "SMBIOS typ 0");
        strField(&b, b.t("Wersja"), bi.version, "SMBIOS typ 0");
        strField(&b, b.t("Data"), bi.release_date, "SMBIOS typ 0");
        if (bi.rom_size) |r| if (r.bytes) |n| b.add(.{ .label = b.t("Rozmiar ROM"), .value = bytesLabel(&b, n), .raw = b.fmt("0x{X:0>2}", .{r.raw}), .source = r.spec });
        if (bi.bios_release) |r| if (r.supported) b.add(.{ .label = b.t("Wydanie BIOS"), .value = b.fmt("{d}.{d}", .{ r.major, r.minor }), .source = r.spec });
        if (bi.ec_release) |r| if (r.supported) b.add(.{ .label = b.t("Firmware EC"), .value = b.fmt("{d}.{d}", .{ r.major, r.minor }), .source = r.spec });
    } else b.add(.{ .label = "SMBIOS typ 0", .value = "—", .state = .unavailable, .confidence = .unknown });

    // --- system --------------------------------------------------------------------
    b.section(b.t("System"));
    if (system) |sy| {
        strField(&b, b.t("Producent"), sy.manufacturer, "SMBIOS typ 1");
        strField(&b, b.t("Produkt"), sy.product, "SMBIOS typ 1");
        strField(&b, b.t("Wersja"), sy.version, "SMBIOS typ 1");
        strField(&b, b.t("Rodzina"), sy.family, "SMBIOS typ 1");
        strField(&b, b.t("SKU"), sy.sku, "SMBIOS typ 1");
        strField(&b, b.t("Numer seryjny"), sy.serial, "SMBIOS typ 1");
        if (sy.uuid) |u| {
            var ub: [36]u8 = undefined;
            switch (u.state) {
                .present => b.add(.{ .label = b.t("UUID"), .value = b.dup(u.format(&ub)), .source = u.spec, .sensitive = true }),
                else => b.add(.{ .label = b.t("UUID"), .value = @tagName(u.state), .state = .placeholder, .confidence = .low, .source = u.spec }),
            }
        }
    }
    if (chassis) |ch| {
        enumField(&b, b.t("Obudowa"), ch.chassis_type);
        strField(&b, b.t("Producent obudowy"), ch.manufacturer, "SMBIOS typ 3");
    }

    // --- gniazdo CPU ---------------------------------------------------------------
    if (cpu) |p| {
        b.section(b.t("Gniazdo procesora (SMBIOS)"));
        enumField(&b, b.t("Gniazdo"), p.upgrade);
        strField(&b, b.t("Oznaczenie gniazda"), p.socket_designation, "SMBIOS typ 4");
        strField(&b, b.t("Wersja procesora"), p.version, "SMBIOS typ 4");
        if (p.external_clock_mhz) |n| if (n.value) |v| b.add(.{ .label = b.t("Zegar zewnętrzny"), .value = b.fmt("{d} MHz", .{v}), .source = n.spec, .confidence = .medium });
        if (p.max_speed_mhz) |n| if (n.value) |v| b.add(.{ .label = b.t("Maks. zegar (firmware)"), .value = b.fmt("{d} MHz", .{v}), .source = n.spec, .confidence = .low, .note = b.t("wartość wpisana przez producenta płyty") });
        if (p.current_speed_mhz) |n| if (n.value) |v| b.add(.{ .label = b.t("Zegar przy starcie"), .value = b.fmt("{d} MHz", .{v}), .source = n.spec, .confidence = .low });
    }

    // --- wentylatory -------------------------------------------------------------------
    b.section(b.t("Wentylatory i napięcia płyty"));
    b.add(.{ .label = b.t("Wentylatory płyty"), .value = "—", .state = .requires_driver, .confidence = .unknown, .source = b.t("wymagają dostępu do układu Super I/O (porty I/O) — tylko przez sterownik jądra; planowane, celowo niezaimplementowane") });

    // --- PCI ------------------------------------------------------------------------------
    b.section(b.t("Urządzenia PCI"));
    if (c.snap.pci.len == 0) b.add(collectNote(&b, c.snap.pci_status));
    for (c.snap.pci) |p| {
        const dn = pciDevice(c, p.vendor, p.device);
        const vn = pciVendor(c, p.vendor);
        const value = if (dn) |d| b.fmt("{s} {s}", .{ shortVendor(vn orelse "?"), d }) else if (p.desc.len > 0) p.desc else b.t("nieznane");
        b.add(.{
            .label = b.fmt("{x:0>2}:{x:0>2}.{d}", .{ p.bus, p.dev, p.func }),
            .value = value,
            .raw = b.fmt("{X:0>4}:{X:0>4} sub {X:0>4}:{X:0>4} rev {X:0>2}", .{ p.vendor, p.device, p.subvendor, p.subdevice, p.revision }),
            .source = if (dn != null) pciSource(&b, c) else b.t("opis sterownika Windows (brak w pci.ids)"),
            .confidence = if (dn != null) .high else .medium,
        });
    }
    return page;
}

// ---------------------------------------------------------------------------
// Pamięć
// ---------------------------------------------------------------------------

pub fn buildMemory(arena: std.mem.Allocator, c: Ctx) report.Page {
    var page: report.Page = .{ .id = "memory", .title = "" };
    var b = Builder.init(arena, &page);
    page.title = b.t("Pamięć");
    const tbl = smbiosTable(c) orelse {
        page.headline = b.t("Brak danych SMBIOS");
        b.section(b.t("Pamięć"));
        b.add(collectNote(&b, c.snap.smbios_status));
        return page;
    };
    const sum = smbios.summarizeMemory(tbl);
    const type_name = if (sum.memory_type) |t| smbios.memoryTypeName(t) orelse "?" else "?";
    page.headline = b.fmt("{s} {s}", .{ bytesLabel(&b, sum.total_bytes), type_name });
    page.summary = b.t("Moduły z SMBIOS typ 16/17. Timingi z SPD wymagają dostępu do SMBus — planowane (sterownik).");

    b.section(b.t("Podsumowanie"));
    b.add(.{ .label = b.t("Rozmiar całkowity"), .value = bytesLabel(&b, sum.total_bytes), .raw = b.fmt("{d} B", .{sum.total_bytes}), .source = b.t("suma rozmiarów SMBIOS typ 17"), .note = if (sum.unknown_size_modules > 0) b.t("część modułów ma nieznany rozmiar") else "" });
    b.add(.{ .label = b.t("Typ"), .value = type_name, .source = "SMBIOS typ 17, offset 12h", .confidence = if (sum.mixed_types) .low else .high, .note = if (sum.mixed_types) b.t("moduły zgłaszają różne typy") else "" });
    b.add(.{ .label = b.t("Gniazda"), .value = b.tf("{used} z {total} zajęte", .{ .used = sum.populated_slots, .total = sum.total_slots }), .source = b.t("liczba struktur SMBIOS typ 17 (pamięć systemowa)") });
    if (sum.channels) |ch| {
        b.add(.{ .label = b.t("Kanały"), .value = b.fmt("{d}", .{ch}), .source = sum.channel_method, .confidence = smConf(sum.channel_confidence), .state = .estimate, .note = b.t("heurystyka z nazw gniazd (Device/Bank Locator)") });
    } else {
        b.add(.{ .label = b.t("Kanały"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.t("nie da się wywnioskować z nazw gniazd") });
    }
    // Prędkość pierwszego obsadzonego modułu — jak „DRAM Frequency” w CPU-Z.
    var it0 = tbl.iterator();
    while (it0.next()) |s0| {
        if (s0.type_id != 17) continue;
        const d0 = smbios.decodeMemoryDevice(s0) orelse continue;
        if (!d0.populated()) continue;
        if (d0.configured_speed) |sp0| if (sp0.mts) |v| {
            b.add(.{ .label = b.t("Prędkość"), .value = b.fmt("{d} MT/s", .{v}), .source = sp0.spec });
            b.add(.{ .label = b.t("Częstotliwość DRAM"), .value = b.fmt("{d} MHz", .{v / 2}), .source = "Configured Memory Speed / 2 (DDR)", .confidence = .high });
        };
        break;
    }
    b.add(.{ .label = b.t("Timingi (SPD)"), .value = "—", .state = .requires_driver, .confidence = .unknown, .source = b.t("odczyt SPD przez SMBus wymaga sterownika — planowane") });

    var it = tbl.iterator();
    while (it.next()) |s| {
        if (s.type_id == 16) {
            const a = smbios.decodeMemoryArray(s) orelse continue;
            b.section(b.t("Macierz pamięci (typ 16)"));
            enumField(&b, b.t("Położenie"), a.location);
            enumField(&b, b.t("Zastosowanie"), a.use);
            enumField(&b, b.t("Korekcja błędów"), a.error_correction);
            if (a.max_capacity) |m| if (m.bytes) |n| b.add(.{ .label = b.t("Maks. pojemność"), .value = bytesLabel(&b, n), .source = m.spec, .confidence = .medium, .note = b.t("deklaracja firmware") });
            if (a.num_devices) |n| if (n.value) |v| b.add(.{ .label = b.t("Liczba gniazd"), .value = b.fmt("{d}", .{v}), .source = n.spec });
        }
    }

    it = tbl.iterator();
    while (it.next()) |s| {
        if (s.type_id != 17) continue;
        const d = smbios.decodeMemoryDevice(s) orelse continue;
        const loc = if (d.device_locator) |f| f.text() orelse "?" else "?";
        b.section(b.tf("Gniazdo {slot}", .{ .slot = loc }));
        strField(&b, b.t("Bank"), d.bank_locator, "SMBIOS typ 17");
        if (!d.populated()) {
            b.add(.{ .label = b.t("Moduł"), .value = b.t("pusty"), .source = if (d.size) |z| z.spec else "SMBIOS typ 17" });
            continue;
        }
        if (d.size) |z| {
            if (z.bytes) |n| {
                b.add(.{ .label = b.t("Rozmiar"), .value = bytesLabel(&b, n), .raw = b.fmt("0x{X:0>4}", .{z.raw}), .source = z.spec });
            } else b.add(.{ .label = b.t("Rozmiar"), .value = b.t("nieznany"), .state = .unavailable, .confidence = .unknown, .source = z.spec });
        }
        enumField(&b, b.t("Typ"), d.memory_type);
        if (d.type_detail) |td| {
            var nb: [16][]const u8 = undefined;
            const names = td.names(&nb);
            if (names.len > 0) {
                var lst: std.ArrayList(u8) = .empty;
                for (names, 0..) |n, i| {
                    if (i > 0) lst.appendSlice(arena, ", ") catch {};
                    lst.appendSlice(arena, n) catch {};
                }
                b.add(.{ .label = b.t("Szczegóły typu"), .value = lst.items, .raw = b.fmt("0x{X:0>4}", .{td.raw}), .source = td.spec });
            }
        }
        enumField(&b, b.t("Format"), d.form_factor);
        if (d.speed) |sp_| if (sp_.mts) |v| b.add(.{ .label = b.t("Prędkość maks."), .value = b.fmt("{d} MT/s", .{v}), .source = sp_.spec });
        if (d.configured_speed) |sp_| if (sp_.mts) |v| b.add(.{ .label = b.t("Prędkość skonfigurowana"), .value = b.fmt("{d} MT/s", .{v}), .source = sp_.spec, .note = b.tf("zegar pamięci ~{mhz} MHz (DDR: połowa MT/s)", .{ .mhz = v / 2 }) });
        strField(&b, b.t("Producent"), d.manufacturer, "SMBIOS typ 17");
        strField(&b, b.t("Part number"), d.part_number, "SMBIOS typ 17");
        strField(&b, b.t("Numer seryjny"), d.serial, "SMBIOS typ 17");
        if (d.rank) |r| if (r.value) |v| b.add(.{ .label = b.t("Ranki"), .value = b.fmt("{d}", .{v}), .source = r.spec });
        if (d.configured_voltage_mv) |v| if (v.value) |mv| b.add(.{ .label = b.t("Napięcie"), .value = b.fmt("{d:.3} V", .{@as(f64, @floatFromInt(mv)) / 1000.0}), .source = v.spec });
        if (d.data_width_bits) |w| if (w.value) |v| b.add(.{ .label = b.t("Szerokość danych"), .value = b.fmt("{d} bit", .{v}), .source = w.spec });
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

/// `label` jest już przetłumaczona w miejscu wywołania (przez `b.t`).
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

fn vendorReason(b: *Builder, live: GpuLive, vendor: u16) []const u8 {
    const want: []const u8 = switch (vendor) {
        0x1002 => "atiadlxx",
        0x10DE => "nvapi",
        else => return b.t("brak biblioteki producenta dla tego układu (obsługiwane: AMD ADL, NVIDIA NVAPI)"),
    };
    for (live.libraries) |l| {
        if (std.mem.indexOf(u8, l.name, want) != null) return if (l.reason.len > 0) l.reason else @tagName(l.status);
    }
    return b.t("biblioteka producenta nie była odpytywana (tryb replay albo CLI bez --live)");
}

pub fn buildGraphics(arena: std.mem.Allocator, c: Ctx, live: GpuLive) report.Page {
    var page: report.Page = .{ .id = "graphics", .title = "" };
    var b = Builder.init(arena, &page);
    page.title = b.t("Grafika");
    var first = true;
    page.summary = b.t("DXGI + SetupAPI + pci.ids; zegary/temperatury z bibliotek producenta (opcjonalne, tylko odczyt).");
    if (c.snap.gpus.len == 0) {
        b.section(b.t("Karty graficzne"));
        b.add(collectNote(&b, c.snap.gpu_status));
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
        b.section(b.tf("GPU: {name}", .{ .name = g.name }));
        b.add(.{ .label = b.t("Nazwa (sterownik)"), .value = b.dup(g.name), .source = "DXGI_ADAPTER_DESC1.Description" });
        if (chip) |n| b.add(.{ .label = b.t("Układ GPU"), .value = n, .source = pciSource(&b, c) }) else b.add(.{ .label = b.t("Układ GPU"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.t("brak w pci.ids") });
        if (board) |n| {
            b.add(.{ .label = b.t("Karta"), .value = b.fmt("{s} {s}", .{ shortVendor(board_vendor orelse ""), n }), .source = b.fmt("{s} (subsystem)", .{pciSource(&b, c)}) });
        } else if (board_vendor) |v| {
            b.add(.{ .label = b.t("Producent karty"), .value = v, .source = b.fmt("{s} (subsystem vendor)", .{pciSource(&b, c)}), .confidence = .medium, .note = b.t("modelu karty brak w pci.ids") });
        }
        b.add(.{ .label = b.t("Identyfikator"), .value = b.fmt("{X:0>4}:{X:0>4}", .{ g.vendor, g.device }), .raw = b.fmt("VEN_{X:0>4}&DEV_{X:0>4}", .{ g.vendor, g.device }), .source = "DXGI VendorId/DeviceId" });
        b.add(.{ .label = b.t("Subsystem"), .value = b.fmt("{X:0>4}:{X:0>4}", .{ g.subVendor(), g.subDevice() }), .raw = b.fmt("0x{X:0>8}", .{g.subsys}), .source = "DXGI SubSysId" });
        b.add(.{ .label = b.t("Rewizja"), .value = b.fmt("{X:0>2}", .{g.revision}), .source = "DXGI Revision" });
        b.add(.{ .label = b.t("Pamięć dedykowana"), .value = bytesLabel(&b, g.dedicated_vram), .raw = b.fmt("{d} B", .{g.dedicated_vram}), .source = "DXGI DedicatedVideoMemory" });
        b.add(.{ .label = b.t("Pamięć współdzielona"), .value = bytesLabel(&b, g.shared_sys), .source = "DXGI SharedSystemMemory" });
        if (pci) |p| {
            b.add(.{ .label = b.t("Lokalizacja PCI"), .value = b.fmt("{x:0>2}:{x:0>2}.{d}", .{ p.bus, p.dev, p.func }), .source = "SetupAPI DEVPKEY_Device_BusNumber/Address" });
            if (p.driver_version.len > 0) b.add(.{ .label = b.t("Sterownik"), .value = p.driver_version, .source = "DEVPKEY_Device_DriverVersion" });
            if (p.driver_date.len > 0) b.add(.{ .label = b.t("Data sterownika"), .value = p.driver_date, .source = "DEVPKEY_Device_DriverDate" });
            if (p.driver_provider.len > 0) b.add(.{ .label = b.t("Dostawca sterownika"), .value = p.driver_provider, .source = "DEVPKEY_Device_DriverProvider" });
            if (p.link_cur_width) |w| {
                const sp_ = if (p.link_cur_speed) |s| snap.linkSpeedLabel(s) else "?";
                const mx = if (p.link_max_width) |mw| b.fmt(" ({s})", .{b.tf("maks. x{width} {speed}", .{ .width = mw, .speed = if (p.link_max_speed) |s| snap.linkSpeedLabel(s) else "?" })}) else "";
                b.add(.{ .label = b.t("Łącze PCIe"), .value = b.fmt("x{d} {s}{s}", .{ w, sp_, mx }), .source = "DEVPKEY_PciDevice_CurrentLinkWidth/Speed (pciprop.h)", .note = b.t("karta w stanie oszczędzania energii może zgłaszać niższą prędkość") });
            } else b.add(.{ .label = b.t("Łącze PCIe"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.t("system nie podał właściwości łącza") });
        } else {
            b.add(.{ .label = b.t("Sterownik / łącze"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.t("nie znaleziono urządzenia PCI dla tej karty") });
        }

        // --- telemetria producenta ------------------------------------------------
        b.section(b.tf("Czujniki GPU: {name}", .{ .name = g.name }));
        if (matchVendorAdapter(live, g, pci)) |a| {
            const r = a.readings;
            const why = b.tf("{library}: brak odczytu tej wartości ({path})", .{ .library = a.vendor_library, .path = a.sensor_path });
            b.add(.{ .label = b.t("Źródło"), .value = b.fmt("{s} ({s})", .{ a.vendor_library, a.sensor_path }), .source = b.t("biblioteka producenta ładowana dynamicznie, tylko odczyt") });
            readingField(&b, b.t("Zegar GPU"), r.gpu_clock_mhz, "MHz", why);
            readingField(&b, b.t("Zegar pamięci"), r.mem_clock_mhz, "MHz", why);
            readingField(&b, b.t("Temperatura GPU"), r.temp_edge_c, "°C", why);
            readingField(&b, b.t("Hot spot"), r.temp_hotspot_c, "°C", why);
            readingField(&b, b.t("Temperatura pamięci"), r.temp_mem_c, "°C", why);
            readingField(&b, b.t("Wentylator"), r.fan_rpm, "RPM", why);
            readingField(&b, b.t("Wentylator (%)"), r.fan_percent, "%", why);
            readingField(&b, b.t("Obciążenie GPU"), r.load_percent, "%", why);
            readingField(&b, b.t("Pobór mocy"), r.power_w, "W", why);
            if (r.voltage_v) |v| b.add(.{ .label = b.t("Napięcie GPU"), .value = b.fmt("{d:.3} V", .{v.value}), .source = v.source });
            if (r.vram_type) |t| b.add(.{ .label = b.t("Typ pamięci"), .value = b.dup(t.text.slice()), .source = t.source });
            if (r.driver_version) |t| b.add(.{ .label = b.t("Wersja pakietu sterownika"), .value = b.dup(t.text.slice()), .source = t.source });
        } else {
            const why = vendorReason(&b, live, g.vendor);
            for ([_][]const u8{ b.t("Zegar GPU"), b.t("Temperatura GPU"), b.t("Wentylator"), b.t("Obciążenie GPU") }) |l| {
                b.add(.{ .label = l, .value = "—", .state = .unavailable, .confidence = .unknown, .source = why });
            }
        }
        var gm: [128]u8 = undefined;
        var gp: [16]u8 = undefined;
        const gmodel = lookup.normalizeGpu(&gm, g.name);
        const gpci = std.fmt.bufPrint(&gp, "{x:0>4}:{x:0>4}", .{ g.vendor, g.device }) catch "";
        links.gpuScoped(&b, g.vendor, if (board) |n| n else g.name, b.dup(g.name), lookup.resolve(c.lookup, .gpu, gmodel, gpci));
    }
    if (first) page.headline = b.t("Brak sprzętowej karty graficznej");
    return page;
}

// ---------------------------------------------------------------------------
// Dyski
// ---------------------------------------------------------------------------

/// `label` jest już przetłumaczona w miejscu wywołania (przez `b.t`).
fn derivedField(b: *Builder, label: []const u8, comptime T: type, d: ?sp.Derived(T), comptime f: []const u8) void {
    const x = d orelse return;
    b.add(.{ .label = label, .value = b.fmt(f, .{x.value}), .source = x.source, .confidence = spConf(x.confidence), .note = x.note });
}

pub fn buildStorage(arena: std.mem.Allocator, c: Ctx) report.Page {
    var page: report.Page = .{ .id = "storage", .title = "" };
    var b = Builder.init(arena, &page);
    page.title = b.t("Dyski");
    page.headline = b.tp("{n} dysków fizycznych", c.snap.disks.len, .{});
    page.summary = if (c.snap.is_admin)
        b.t("IOCTL_STORAGE_QUERY_PROPERTY; zdrowie: NVMe log 02h, ATA SMART (pass-through, tylko odczyt).")
    else
        b.t("IOCTL_STORAGE_QUERY_PROPERTY; zdrowie NVMe bez uprawnień. SMART dysków SATA wymaga uruchomienia jako administrator.");
    if (c.snap.disks.len == 0) {
        b.section(b.t("Dyski"));
        b.add(collectNote(&b, c.snap.disk_status));
    }
    for (c.snap.disks) |d| {
        const desc = sp.parseDeviceDescriptor(d.descriptor) catch null;
        var mb: [128]u8 = undefined;
        const model = if (desc) |*x| x.modelName(&mb) else b.t("nieznany");
        b.section(b.tf("Dysk {index}: {model}", .{ .index = d.index, .model = model }));
        b.add(.{ .label = b.t("Model"), .value = b.dup(model), .source = "STORAGE_DEVICE_DESCRIPTOR (Vendor/ProductId)" });
        if (desc) |x| {
            if (x.revision_status == .ok) b.add(.{ .label = b.t("Firmware"), .value = b.dup(x.product_revision.slice()), .source = "STORAGE_DEVICE_DESCRIPTOR.ProductRevisionOffset" });
            if (x.serial_status == .ok) b.add(.{ .label = b.t("Numer seryjny"), .value = b.dup(x.serial.slice()), .source = b.fmt("STORAGE_DEVICE_DESCRIPTOR.SerialNumberOffset ({s})", .{@tagName(x.serial_encoding)}), .sensitive = true });
            b.add(.{ .label = b.t("Magistrala"), .value = x.bus_type.name(), .raw = b.fmt("{d}", .{x.bus_type_raw}), .source = "STORAGE_DEVICE_DESCRIPTOR.BusType" });
            if (x.removable) b.add(.{ .label = b.t("Wymienny"), .value = b.t("tak"), .source = "STORAGE_DEVICE_DESCRIPTOR.RemovableMedia" });
        }
        if (d.size_bytes) |n| b.add(.{ .label = b.t("Pojemność"), .value = decimalSize(&b, n), .raw = b.fmt("{d} B", .{n}), .source = "IOCTL_DISK_GET_DRIVE_GEOMETRY_EX / GET_LENGTH_INFO" });
        if (d.rotational) |r| b.add(.{ .label = b.t("Rodzaj"), .value = if (r) b.t("HDD (obrotowy)") else b.t("SSD / brak kary wyszukiwania"), .source = "StorageDeviceSeekPenaltyProperty", .confidence = .medium });

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
                .label = b.t("Stan zdrowia"),
                .value = switch (s.status) {
                    .ok => b.t("dobry"),
                    .warning => b.t("ostrzeżenie"),
                    .critical => b.t("krytyczny"),
                    .unknown => b.t("nieznany"),
                },
                .source = if (d.health_source.len > 0) d.health_source else "SMART / NVMe",
                .note = s.reason,
                .confidence = .medium,
            });
            derivedField(&b, b.t("Temperatura"), i32, s.temperature_c, "{d} °C");
            derivedField(&b, b.t("Czas pracy"), u64, s.power_on_hours, "{d} h");
            derivedField(&b, b.t("Liczba uruchomień"), u64, s.power_cycles, "{d}");
            derivedField(&b, b.t("Zużycie"), u8, s.percentage_used, "{d} %");
            if (s.data_written_bytes) |x| b.add(.{ .label = b.t("Zapisano"), .value = b.fmt("{d:.2} TB", .{sp.NvmeHealth.bytesToTB(x.value)}), .source = x.source, .confidence = spConf(x.confidence), .note = x.note });
            if (s.data_read_bytes) |x| b.add(.{ .label = b.t("Odczytano"), .value = b.fmt("{d:.2} TB", .{sp.NvmeHealth.bytesToTB(x.value)}), .source = x.source, .confidence = spConf(x.confidence) });
            derivedField(&b, b.t("Niebezpieczne wyłączenia"), u64, s.unsafe_shutdowns, "{d}");
            derivedField(&b, b.t("Błędy nośnika"), u64, s.media_errors, "{d}");
            derivedField(&b, b.t("Realokowane sektory"), u64, s.reallocated, "{d}");
            derivedField(&b, b.t("Sektory oczekujące"), u64, s.pending, "{d}");
            derivedField(&b, b.t("Nienaprawialne"), u64, s.uncorrectable, "{d}");
            if (nvme) |n| b.add(.{ .label = b.t("Zapas (spare)"), .value = b.tf("{spare} % (próg {threshold} %)", .{ .spare = n.available_spare, .threshold = n.available_spare_threshold }), .source = b.t("NVMe log 02h, bajty 3..4") });
        } else {
            b.add(.{
                .label = b.t("Stan zdrowia"),
                .value = "—",
                .state = switch (d.health) {
                    .requires_admin => .requires_admin,
                    else => .unavailable,
                },
                .confidence = .unknown,
                .source = if (d.health_note.len > 0) d.health_note else d.health.label(),
                .note = if (d.health_error != 0) b.tf("kod Win32 {code}", .{ .code = d.health_error }) else "",
            });
        }
    }
    return page;
}

// ---------------------------------------------------------------------------
// Czujniki — zbiorczo (CPU obciążenie, GPU, wentylatory, dyski)
// ---------------------------------------------------------------------------

pub fn addSensorSections(b: *Builder, c: Ctx, live: GpuLive) void {
    b.section(b.t("Wentylatory"));
    var any_fan = false;
    for (live.adapters) |a| {
        if (a.readings.fan_rpm) |r| {
            any_fan = true;
            b.add(.{ .label = b.tf("GPU: {name}", .{ .name = a.name.slice() }), .value = b.fmt("{d:.0} RPM", .{r.value}), .source = r.source });
        }
        if (a.readings.fan_percent) |r| b.add(.{ .label = b.tf("GPU: {name} (%)", .{ .name = a.name.slice() }), .value = b.fmt("{d:.0} %", .{r.value}), .source = r.source });
    }
    if (!any_fan) b.add(.{ .label = b.t("Wentylator GPU"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.t("brak odczytu z bibliotek producenta (ADL/NVAPI)") });
    b.add(.{ .label = b.t("Wentylatory płyty głównej"), .value = "—", .state = .requires_driver, .confidence = .unknown, .source = b.t("Super I/O przez porty I/O wymaga sterownika jądra — planowane") });

    b.section(b.t("GPU"));
    var any_gpu = false;
    for (live.adapters) |a| {
        const r = a.readings;
        const n = a.name.slice();
        inline for (.{
            .{ "temp_edge_c", i18n.N("temperatura"), "°C" },
            .{ "temp_hotspot_c", i18n.N("hot spot"), "°C" },
            .{ "load_percent", i18n.N("obciążenie"), "%" },
            .{ "gpu_clock_mhz", i18n.N("zegar"), "MHz" },
            .{ "power_w", i18n.N("moc"), "W" },
        }) |m| {
            if (@field(r, m[0])) |x| {
                any_gpu = true;
                b.add(.{ .label = b.fmt("{s} — {s}", .{ n, i18n.t(m[1]) }), .value = b.fmt("{d:.0} {s}", .{ x.value, m[2] }), .source = x.source });
            }
        }
    }
    if (!any_gpu) {
        for (live.libraries) |l| b.add(.{ .label = l.name, .value = "—", .state = .unavailable, .confidence = .unknown, .source = l.reason });
        if (live.libraries.len == 0) b.add(.{ .label = b.t("GPU"), .value = "—", .state = .unavailable, .confidence = .unknown, .source = b.t("biblioteki producentów nie były odpytywane") });
    }

    b.section(b.t("Dyski — temperatury"));
    for (c.snap.disks) |d| {
        var t: ?sp.Derived(i32) = null;
        if (d.nvme_log) |log| {
            if (sp.parseNvmeHealthLog(log)) |n| t = n.summary.temperature_c else |_| {}
        } else if (d.ata_smart) |data| {
            if (sp.parseAtaSmart(data, d.ata_thresholds, .{ .rotational = d.rotational })) |a| t = a.summary.temperature_c else |_| {}
        }
        const desc = sp.parseDeviceDescriptor(d.descriptor) catch null;
        var mb: [128]u8 = undefined;
        const model = if (desc) |*x| x.modelName(&mb) else b.t("dysk");
        if (t) |x| {
            b.add(.{ .label = b.tf("Dysk {index}: {model}", .{ .index = d.index, .model = model }), .value = b.fmt("{d} °C", .{x.value}), .source = x.source, .confidence = spConf(x.confidence) });
        } else {
            b.add(.{ .label = b.tf("Dysk {index}: {model}", .{ .index = d.index, .model = model }), .value = "—", .state = if (d.health == .requires_admin) .requires_admin else .unavailable, .confidence = .unknown, .source = if (d.health_note.len > 0) d.health_note else d.health.label() });
        }
    }
}
