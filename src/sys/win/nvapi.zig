//! NVIDIA NVAPI — odczyt czujników i informacji o kartach NVIDIA.
//!
//! **Zaimplementowane według nagłówków SDK, NIE zweryfikowane na sprzęcie
//! NVIDIA** (maszyna deweloperska ma tylko kartę AMD). Przetestowana jest
//! ścieżka "brak biblioteki" oraz rozmiary/wersje struktur.
//!
//! `nvapi64.dll` jest ładowana dynamicznie z System32. Biblioteka eksportuje
//! tylko `nvapi_QueryInterface(u32 id)`, który zwraca adres funkcji dla jej
//! identyfikatora. Brak DLL, brak eksportu, nieznany identyfikator albo błąd
//! inicjalizacji dają status — nigdy przerwanie procesu.
//!
//! Wywołujemy wyłącznie funkcje odczytu (Get/Enum) oraz Initialize/Unload.
//! Żadna funkcja Set/sterowania zegarami/wentylatorem nie jest deklarowana.
//!
//! ## Źródła (NVIDIA/nvapi na GitHubie, licencja MIT, gałąź main)
//!
//!   * nvapi_interface.h — identyfikatory funkcji dla `nvapi_QueryInterface`
//!     (sprawdzone krzyżowo z LibreHardwareMonitor Interop/NvApi.cs).
//!   * nvapi_lite_common.h — `MAKE_NVAPI_VERSION(type,ver) = sizeof(type) | (ver<<16)`,
//!     NVAPI_SHORT_STRING_MAX=64, NVAPI_MAX_PHYSICAL_GPUS=64, kody NvAPI_Status,
//!     NV_DISPLAY_DRIVER_MEMORY_INFO_V3, sygnatury NvAPI_EnumPhysicalGPUs,
//!     NvAPI_SYS_GetDriverAndBranchVersion, NvAPI_GPU_GetMemoryInfo.
//!   * nvapi.h — NV_GPU_THERMAL_SETTINGS_V2, NV_THERMAL_TARGET,
//!     NV_GPU_CLOCK_FREQUENCIES_V2 (+ VER_2/VER_3), NV_GPU_CLOCK_FREQUENCIES_CURRENT_FREQ=0,
//!     NVAPI_MAX_GPU_PUBLIC_CLOCKS=32, NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS=0 / _MEMORY=4,
//!     NV_GPU_DYNAMIC_PSTATES_INFO_EX, NVAPI_MAX_GPU_UTILIZATIONS=8,
//!     NVAPI_MAX_THERMAL_SENSORS_PER_GPU=3, sygnatury NvAPI_GPU_*.
//!   * Indeks domeny wykorzystania GPU = 0 (NVAPI_GPU_UTILIZATION_DOMAIN_GPU;
//!     opis w nvapi.h przy NvAPI_GPU_GetDynamicPstatesInfoEx, wartość jak w
//!     LHM `NvUtilizationDomain.Gpu`).
//!
//! Konwencja wywołań NVAPI to `__cdecl`; moduł obsługuje tylko proces
//! Windows x86_64 (jedna konwencja wywołań), na innych zwraca `unsupported_api`.

const std = @import("std");
const i18n = @import("../../i18n/i18n.zig");
const builtin = @import("builtin");
const gv = @import("gpu_vendor.zig");

const Allocator = std.mem.Allocator;

pub const dll_name = "nvapi64.dll";

// ---------------------------------------------------------------------------
// Identyfikatory funkcji (nvapi_interface.h)
// ---------------------------------------------------------------------------

pub const Id = struct {
    pub const Initialize: u32 = 0x0150e828;
    pub const Unload: u32 = 0xd22bdd7e;
    pub const GetInterfaceVersionString: u32 = 0x01053fa5;
    pub const SYS_GetDriverAndBranchVersion: u32 = 0x2926aaad;
    pub const GPU_GetMemoryInfo: u32 = 0x07f9b368;
    pub const EnumPhysicalGPUs: u32 = 0xe5ac921f;
    pub const GPU_GetFullName: u32 = 0xceee8e9f;
    pub const GPU_GetPCIIdentifiers: u32 = 0x2ddfb66e;
    pub const GPU_GetBusId: u32 = 0x1be0b8e5;
    pub const GPU_GetBusSlotId: u32 = 0x2a0a350f;
    pub const GPU_GetTachReading: u32 = 0x5f608315;
    pub const GPU_GetDynamicPstatesInfoEx: u32 = 0x60ded2ed;
    pub const GPU_GetThermalSettings: u32 = 0xe3640a56;
    pub const GPU_GetAllClockFrequencies: u32 = 0xdcb616c3;
    /// nvapi_interface.h: { "NvAPI_GPU_GetVbiosVersionString", 0xa561fd7d };
    /// nvapi.h: NvAPI_GPU_GetVbiosVersionString(NvPhysicalGpuHandle, NvAPI_ShortString).
    pub const GPU_GetVbiosVersionString: u32 = 0xa561fd7d;
};

// ---------------------------------------------------------------------------
// Stałe (nvapi_lite_common.h, nvapi.h)
// ---------------------------------------------------------------------------

pub const NVAPI_OK: i32 = 0;
pub const NVAPI_ERROR: i32 = -1;
pub const NVAPI_LIBRARY_NOT_FOUND: i32 = -2;
pub const NVAPI_NVIDIA_DEVICE_NOT_FOUND: i32 = -6;
pub const NVAPI_INCOMPATIBLE_STRUCT_VERSION: i32 = -9;
pub const NVAPI_NOT_SUPPORTED: i32 = -104;

pub const NVAPI_SHORT_STRING_MAX = 64;
pub const NVAPI_MAX_PHYSICAL_GPUS = 64;
pub const NVAPI_MAX_THERMAL_SENSORS_PER_GPU = 3;
pub const NVAPI_MAX_GPU_PUBLIC_CLOCKS = 32;
pub const NVAPI_MAX_GPU_UTILIZATIONS = 8;

pub const NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS = 0;
pub const NVAPI_GPU_PUBLIC_CLOCK_MEMORY = 4;
pub const NV_GPU_CLOCK_FREQUENCIES_CURRENT_FREQ = 0;
pub const NVAPI_GPU_UTILIZATION_DOMAIN_GPU = 0;

pub const NVAPI_THERMAL_TARGET_GPU: i32 = 1;
pub const NVAPI_THERMAL_TARGET_MEMORY: i32 = 2;
pub const NVAPI_THERMAL_TARGET_ALL: u32 = 15;

/// `MAKE_NVAPI_VERSION(typeName, ver)` z nvapi_lite_common.h.
pub fn makeVersion(comptime T: type, comptime ver: u32) u32 {
    return @as(u32, @sizeOf(T)) | (ver << 16);
}

// ---------------------------------------------------------------------------
// Struktury
// ---------------------------------------------------------------------------

pub const NvPhysicalGpuHandle = ?*anyopaque;
pub const ShortString = [NVAPI_SHORT_STRING_MAX]u8;

pub const ThermalSensor = extern struct {
    controller: i32, // NV_THERMAL_CONTROLLER
    defaultMinTemp: i32,
    defaultMaxTemp: i32,
    currentTemp: i32,
    target: i32, // NV_THERMAL_TARGET
};

pub const NV_GPU_THERMAL_SETTINGS_V2 = extern struct {
    version: u32,
    count: u32,
    sensor: [NVAPI_MAX_THERMAL_SENSORS_PER_GPU]ThermalSensor,
};

/// Domena zegara: `bIsPresent:1, reserved:31` (jeden NvU32) + `frequency` (kHz).
pub const ClockDomain = extern struct {
    flags: u32,
    frequency: u32,

    pub fn present(self: ClockDomain) bool {
        return self.flags & 1 != 0;
    }
};

pub const NV_GPU_CLOCK_FREQUENCIES_V2 = extern struct {
    version: u32,
    /// `ClockType:4, reserved:20, reserved1:8` — jeden NvU32, typ w bitach 0..3.
    clock_type_bits: u32,
    domain: [NVAPI_MAX_GPU_PUBLIC_CLOCKS]ClockDomain,
};

pub const Utilization = extern struct {
    flags: u32, // bIsPresent:1
    percentage: u32,
};

pub const NV_GPU_DYNAMIC_PSTATES_INFO_EX = extern struct {
    version: u32,
    flags: u32,
    utilization: [NVAPI_MAX_GPU_UTILIZATIONS]Utilization,
};

pub const NV_DISPLAY_DRIVER_MEMORY_INFO_V3 = extern struct {
    version: u32,
    dedicatedVideoMemory: u32, // KB
    availableDedicatedVideoMemory: u32,
    systemVideoMemory: u32,
    sharedSystemMemory: u32,
    curAvailableDedicatedVideoMemory: u32,
    dedicatedVideoMemoryEvictionsSize: u32,
    dedicatedVideoMemoryEvictionCount: u32,
};

pub const NV_GPU_THERMAL_SETTINGS_VER_2 = makeVersion(NV_GPU_THERMAL_SETTINGS_V2, 2);
pub const NV_GPU_CLOCK_FREQUENCIES_VER_2 = makeVersion(NV_GPU_CLOCK_FREQUENCIES_V2, 2);
pub const NV_GPU_CLOCK_FREQUENCIES_VER_3 = makeVersion(NV_GPU_CLOCK_FREQUENCIES_V2, 3);
pub const NV_GPU_DYNAMIC_PSTATES_INFO_EX_VER = makeVersion(NV_GPU_DYNAMIC_PSTATES_INFO_EX, 1);
pub const NV_DISPLAY_DRIVER_MEMORY_INFO_VER_3 = makeVersion(NV_DISPLAY_DRIVER_MEMORY_INFO_V3, 3);

comptime {
    // Rozmiary wyliczone z nagłówka: 2*u32 + 3*(5*4) = 68; 2*u32 + 32*8 = 264;
    // 2*u32 + 8*8 = 72; 8*u32 = 32.
    std.debug.assert(@sizeOf(NV_GPU_THERMAL_SETTINGS_V2) == 68);
    std.debug.assert(@sizeOf(NV_GPU_CLOCK_FREQUENCIES_V2) == 264);
    std.debug.assert(@sizeOf(NV_GPU_DYNAMIC_PSTATES_INFO_EX) == 72);
    std.debug.assert(@sizeOf(NV_DISPLAY_DRIVER_MEMORY_INFO_V3) == 32);
}

// ---------------------------------------------------------------------------
// Funkcje
// ---------------------------------------------------------------------------

const QueryInterface = *const fn (u32) callconv(.c) ?*anyopaque;

const Fns = struct {
    initialize: ?*const fn () callconv(.c) i32 = null,
    unload: ?*const fn () callconv(.c) i32 = null,
    iface_version: ?*const fn (*ShortString) callconv(.c) i32 = null,
    driver_version: ?*const fn (*u32, *ShortString) callconv(.c) i32 = null,
    enum_gpus: ?*const fn (*[NVAPI_MAX_PHYSICAL_GPUS]NvPhysicalGpuHandle, *u32) callconv(.c) i32 = null,
    full_name: ?*const fn (NvPhysicalGpuHandle, *ShortString) callconv(.c) i32 = null,
    pci_ids: ?*const fn (NvPhysicalGpuHandle, *u32, *u32, *u32, *u32) callconv(.c) i32 = null,
    bus_id: ?*const fn (NvPhysicalGpuHandle, *u32) callconv(.c) i32 = null,
    bus_slot: ?*const fn (NvPhysicalGpuHandle, *u32) callconv(.c) i32 = null,
    memory_info: ?*const fn (NvPhysicalGpuHandle, *NV_DISPLAY_DRIVER_MEMORY_INFO_V3) callconv(.c) i32 = null,
    tach: ?*const fn (NvPhysicalGpuHandle, *u32) callconv(.c) i32 = null,
    pstates: ?*const fn (NvPhysicalGpuHandle, *NV_GPU_DYNAMIC_PSTATES_INFO_EX) callconv(.c) i32 = null,
    thermal: ?*const fn (NvPhysicalGpuHandle, u32, *NV_GPU_THERMAL_SETTINGS_V2) callconv(.c) i32 = null,
    clocks: ?*const fn (NvPhysicalGpuHandle, *NV_GPU_CLOCK_FREQUENCIES_V2) callconv(.c) i32 = null,
    vbios_version: ?*const fn (NvPhysicalGpuHandle, *ShortString) callconv(.c) i32 = null,

    fn load(q: QueryInterface) Fns {
        var f: Fns = .{};
        inline for (.{
            .{ "initialize", Id.Initialize },
            .{ "unload", Id.Unload },
            .{ "iface_version", Id.GetInterfaceVersionString },
            .{ "driver_version", Id.SYS_GetDriverAndBranchVersion },
            .{ "enum_gpus", Id.EnumPhysicalGPUs },
            .{ "full_name", Id.GPU_GetFullName },
            .{ "pci_ids", Id.GPU_GetPCIIdentifiers },
            .{ "bus_id", Id.GPU_GetBusId },
            .{ "bus_slot", Id.GPU_GetBusSlotId },
            .{ "memory_info", Id.GPU_GetMemoryInfo },
            .{ "tach", Id.GPU_GetTachReading },
            .{ "pstates", Id.GPU_GetDynamicPstatesInfoEx },
            .{ "thermal", Id.GPU_GetThermalSettings },
            .{ "clocks", Id.GPU_GetAllClockFrequencies },
            .{ "vbios_version", Id.GPU_GetVbiosVersionString },
        }) |e| {
            if (q(e[1])) |p| @field(f, e[0]) = @ptrCast(@alignCast(p));
        }
        return f;
    }
};

// ---------------------------------------------------------------------------
// Czyste pomocnicze (testowalne)
// ---------------------------------------------------------------------------

/// `NvAPI_GPU_GetPCIIdentifiers` zwraca w `pDeviceId` (device<<16 | vendor),
/// np. 0x268410DE → vendor 0x10DE, device 0x2684.
pub fn splitDeviceId(raw: u32) struct { vendor: u16, device: u16 } {
    return .{ .vendor = @truncate(raw), .device = @truncate(raw >> 16) };
}

/// Wersja sterownika NVAPI jako liczba (np. 56694) → "566.94".
pub fn formatDriverVersion(v: u32, branch: []const u8) gv.Text {
    if (branch.len == 0) return gv.Text.print("{d}.{d:0>2}", .{ v / 100, v % 100 });
    return gv.Text.print("{d}.{d:0>2} ({s})", .{ v / 100, v % 100, branch });
}

/// Wyciąga temperatury z `NV_GPU_THERMAL_SETTINGS_V2` do modelu.
pub fn applyThermal(t: *const NV_GPU_THERMAL_SETTINGS_V2, r: *gv.Readings) usize {
    var n: usize = 0;
    const count = @min(t.count, NVAPI_MAX_THERMAL_SENSORS_PER_GPU);
    for (t.sensor[0..count]) |s| {
        const v: f64 = @floatFromInt(s.currentTemp);
        switch (s.target) {
            NVAPI_THERMAL_TARGET_GPU => if (r.temp_edge_c == null) {
                r.temp_edge_c = gv.reading(v, "C", "NVAPI GPU_GetThermalSettings TARGET_GPU");
                if (r.temp_edge_c != null) n += 1;
            },
            NVAPI_THERMAL_TARGET_MEMORY => if (r.temp_mem_c == null) {
                r.temp_mem_c = gv.reading(v, "C", "NVAPI GPU_GetThermalSettings TARGET_MEMORY");
                if (r.temp_mem_c != null) n += 1;
            },
            else => {},
        }
    }
    return n;
}

/// Wyciąga zegary bieżące (kHz → MHz) z `NV_GPU_CLOCK_FREQUENCIES_V2`.
pub fn applyClocks(c: *const NV_GPU_CLOCK_FREQUENCIES_V2, r: *gv.Readings) usize {
    var n: usize = 0;
    const g = c.domain[NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS];
    if (g.present()) {
        r.gpu_clock_mhz = gv.reading(@as(f64, @floatFromInt(g.frequency)) / 1000.0, "MHz", "NVAPI GPU_GetAllClockFrequencies GRAPHICS CURRENT_FREQ");
        if (r.gpu_clock_mhz != null) n += 1;
    }
    const m = c.domain[NVAPI_GPU_PUBLIC_CLOCK_MEMORY];
    if (m.present()) {
        r.mem_clock_mhz = gv.reading(@as(f64, @floatFromInt(m.frequency)) / 1000.0, "MHz", "NVAPI GPU_GetAllClockFrequencies MEMORY CURRENT_FREQ");
        if (r.mem_clock_mhz != null) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Sesja
// ---------------------------------------------------------------------------

pub const Session = struct {
    alloc: Allocator,
    dll: ?gv.HMODULE = null,
    initialized: bool = false,
    fns: Fns = .{},
    library: gv.LibraryInfo = .{ .name = dll_name },
    adapters: []gv.Adapter = &.{},
    handles: []NvPhysicalGpuHandle = &.{},
    /// Wersja struktury zegarów zaakceptowana przez sterownik (VER_3 lub VER_2).
    clock_ver: u32 = NV_GPU_CLOCK_FREQUENCIES_VER_3,

    /// Ładuje DLL, wywołuje NvAPI_Initialize, wylicza GPU, wykonuje pierwszy
    /// odczyt. Nigdy nie zawodzi — stan opisuje `library.status`/`reason`.
    pub fn open(alloc: Allocator) Session {
        var s: Session = .{ .alloc = alloc };
        if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) {
            s.fail(.unsupported_api, i18n.t("NVAPI: obsługiwany tylko proces Windows x86_64"));
            return s;
        }
        s.dll = gv.loadSystemDll(dll_name);
        const h = s.dll orelse {
            s.fail(.dll_not_found, i18n.t("NVAPI: brak nvapi64.dll w System32 (brak sterownika NVIDIA)"));
            return s;
        };
        const q = gv.getProc(QueryInterface, h, "nvapi_QueryInterface") orelse {
            s.fail(.unsupported_api, i18n.t("NVAPI: brak eksportu nvapi_QueryInterface"));
            return s;
        };
        s.fns = Fns.load(q);
        const init = s.fns.initialize orelse {
            s.fail(.unsupported_api, i18n.t("NVAPI: QueryInterface nie zna NvAPI_Initialize"));
            return s;
        };
        const rc = init();
        if (rc != NVAPI_OK) {
            if (rc == NVAPI_NVIDIA_DEVICE_NOT_FOUND)
                s.fail(.no_adapters, i18n.t("NVAPI: NvAPI_Initialize — brak GPU NVIDIA (NVAPI_NVIDIA_DEVICE_NOT_FOUND)"))
            else
                s.fail(.{ .init_failed = rc }, i18n.t("NVAPI: NvAPI_Initialize zwrócił błąd"));
            return s;
        }
        s.initialized = true;

        if (s.fns.iface_version) |f| {
            var buf = std.mem.zeroes(ShortString);
            if (f(&buf) == NVAPI_OK) s.library.version = gv.Text.fromC(&buf);
        }

        s.enumerate() catch {
            s.fail(.{ .init_failed = NVAPI_ERROR }, i18n.t("NVAPI: brak pamięci przy wyliczaniu GPU"));
            return s;
        };
        if (s.adapters.len == 0) {
            s.fail(.no_adapters, i18n.t("NVAPI: NvAPI_EnumPhysicalGPUs nie zwrócił żadnego GPU"));
            return s;
        }
        s.library.status = .available;
        s.library.reason = i18n.t("NVAPI: dostępne (zaimplementowane wg SDK, niezweryfikowane na sprzęcie NVIDIA)");
        s.poll();
        return s;
    }

    fn fail(self: *Session, st: gv.Status, reason: []const u8) void {
        self.library.status = st;
        self.library.reason = reason;
    }

    fn enumerate(self: *Session) Allocator.Error!void {
        const enum_fn = self.fns.enum_gpus orelse return;
        var hs: [NVAPI_MAX_PHYSICAL_GPUS]NvPhysicalGpuHandle = [_]NvPhysicalGpuHandle{null} ** NVAPI_MAX_PHYSICAL_GPUS;
        var count: u32 = 0;
        if (enum_fn(&hs, &count) != NVAPI_OK) return;
        const n: usize = @min(count, NVAPI_MAX_PHYSICAL_GPUS);
        if (n == 0) return;

        const adapters = try self.alloc.alloc(gv.Adapter, n);
        errdefer self.alloc.free(adapters);
        const handles = try self.alloc.alloc(NvPhysicalGpuHandle, n);
        @memcpy(handles, hs[0..n]);

        var driver: ?gv.TextReading = null;
        if (self.fns.driver_version) |f| {
            var ver: u32 = 0;
            var branch = std.mem.zeroes(ShortString);
            if (f(&ver, &branch) == NVAPI_OK and ver != 0) {
                const b = gv.Text.fromC(&branch);
                const t = formatDriverVersion(ver, b.slice());
                driver = .{ .text = t, .source = "NVAPI SYS_GetDriverAndBranchVersion" };
                if (self.library.version.isEmpty()) {
                    self.library.version = t;
                } else {
                    self.library.version = gv.Text.print("{s}, driver {s}", .{ self.library.version.slice(), t.slice() });
                }
            }
        }

        for (adapters, handles, 0..) |*a, h, i| {
            a.* = .{ .vendor_library = "NVAPI", .native_index = @intCast(i) };
            a.readings.driver_version = driver;
            if (self.fns.full_name) |f| {
                var name = std.mem.zeroes(ShortString);
                if (f(h, &name) == NVAPI_OK) a.name = gv.Text.fromC(&name);
            }
            if (self.fns.vbios_version) |f| {
                var vb = std.mem.zeroes(ShortString);
                if (f(h, &vb) == NVAPI_OK) {
                    const t = gv.Text.fromC(&vb);
                    if (!t.isEmpty()) a.readings.vbios_version = .{ .text = t, .source = "NVAPI GPU_GetVbiosVersionString" };
                }
            }
            if (self.fns.pci_ids) |f| {
                var dev: u32 = 0;
                var sub: u32 = 0;
                var rev: u32 = 0;
                var ext: u32 = 0;
                if (f(h, &dev, &sub, &rev, &ext) == NVAPI_OK and dev != 0) {
                    const d = splitDeviceId(dev);
                    a.vendor_id = d.vendor;
                    a.device_id = d.device;
                    a.subsys_id = sub;
                    a.revision = @truncate(rev);
                }
            }
            if (self.fns.bus_id) |fb| {
                var bus: u32 = 0;
                if (fb(h, &bus) == NVAPI_OK) {
                    var slot: u32 = 0;
                    const have_slot = if (self.fns.bus_slot) |fs| fs(h, &slot) == NVAPI_OK else false;
                    // NVAPI nie podaje numeru funkcji; funkcja VGA GPU to 0.
                    if (have_slot) a.pci = .{ .bus = bus, .device = slot, .function = 0 };
                }
            }
            if (self.fns.memory_info) |f| {
                var m = std.mem.zeroes(NV_DISPLAY_DRIVER_MEMORY_INFO_V3);
                m.version = NV_DISPLAY_DRIVER_MEMORY_INFO_VER_3;
                if (f(h, &m) == NVAPI_OK and m.dedicatedVideoMemory != 0) {
                    a.readings.vram_bytes = gv.reading(@as(f64, @floatFromInt(m.dedicatedVideoMemory)) * 1024.0, "B", "NVAPI GPU_GetMemoryInfo dedicatedVideoMemory");
                }
            }
        }
        self.adapters = adapters;
        self.handles = handles;
    }

    /// Odświeża wyłącznie czujniki dynamiczne (bez przeładowania DLL).
    pub fn poll(self: *Session) void {
        if (self.library.status != .available) return;
        for (self.adapters, self.handles) |*a, h| self.pollAdapter(a, h);
    }

    fn pollAdapter(self: *Session, a: *gv.Adapter, h: NvPhysicalGpuHandle) void {
        const r = &a.readings;
        r.clearDynamic();
        var n: usize = 0;
        if (self.fns.thermal) |f| {
            var t = std.mem.zeroes(NV_GPU_THERMAL_SETTINGS_V2);
            t.version = NV_GPU_THERMAL_SETTINGS_VER_2;
            if (f(h, NVAPI_THERMAL_TARGET_ALL, &t) == NVAPI_OK) n += applyThermal(&t, r);
        }
        if (self.fns.clocks) |f| {
            var c = std.mem.zeroes(NV_GPU_CLOCK_FREQUENCIES_V2);
            c.version = self.clock_ver;
            c.clock_type_bits = NV_GPU_CLOCK_FREQUENCIES_CURRENT_FREQ;
            var rc = f(h, &c);
            if (rc == NVAPI_INCOMPATIBLE_STRUCT_VERSION and self.clock_ver == NV_GPU_CLOCK_FREQUENCIES_VER_3) {
                self.clock_ver = NV_GPU_CLOCK_FREQUENCIES_VER_2;
                c = std.mem.zeroes(NV_GPU_CLOCK_FREQUENCIES_V2);
                c.version = self.clock_ver;
                c.clock_type_bits = NV_GPU_CLOCK_FREQUENCIES_CURRENT_FREQ;
                rc = f(h, &c);
            }
            if (rc == NVAPI_OK) n += applyClocks(&c, r);
        }
        if (self.fns.tach) |f| {
            var rpm: u32 = 0;
            if (f(h, &rpm) == NVAPI_OK) {
                r.fan_rpm = gv.reading(@floatFromInt(rpm), "RPM", "NVAPI GPU_GetTachReading");
                if (r.fan_rpm != null) n += 1;
            }
        }
        if (self.fns.pstates) |f| {
            var p = std.mem.zeroes(NV_GPU_DYNAMIC_PSTATES_INFO_EX);
            p.version = NV_GPU_DYNAMIC_PSTATES_INFO_EX_VER;
            if (f(h, &p) == NVAPI_OK) {
                const u = p.utilization[NVAPI_GPU_UTILIZATION_DOMAIN_GPU];
                if (u.flags & 1 != 0) {
                    r.load_percent = gv.reading(@floatFromInt(u.percentage), "%", "NVAPI GPU_GetDynamicPstatesInfoEx utilization[GPU]");
                    if (r.load_percent != null) n += 1;
                }
            }
        }
        a.sensor_path = if (n > 0) "NVAPI" else "none";
    }

    /// Przenosi listę adapterów do `Result` (sesja przestaje ją posiadać).
    pub fn takeResult(self: *Session) gv.Result {
        const r: gv.Result = .{ .library = self.library, .adapters = self.adapters };
        self.adapters = &.{};
        self.alloc.free(self.handles);
        self.handles = &.{};
        return r;
    }

    pub fn close(self: *Session) void {
        if (self.initialized) {
            if (self.fns.unload) |u| _ = u();
            self.initialized = false;
        }
        if (self.dll) |h| gv.freeDll(h);
        self.dll = null;
        self.alloc.free(self.adapters);
        self.alloc.free(self.handles);
        self.adapters = &.{};
        self.handles = &.{};
    }
};

/// Jednorazowe zapytanie. Zwolnij wynik przez `Result.deinit(alloc)`.
pub fn query(alloc: Allocator) gv.Result {
    var s = Session.open(alloc);
    const r = s.takeResult();
    s.close();
    return r;
}

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

test "makeVersion: wersje struktur zgodne z nagłówkiem" {
    try std.testing.expectEqual(@as(u32, 68 | (2 << 16)), NV_GPU_THERMAL_SETTINGS_VER_2);
    try std.testing.expectEqual(@as(u32, 0x00020044), NV_GPU_THERMAL_SETTINGS_VER_2);
    try std.testing.expectEqual(@as(u32, 264 | (2 << 16)), NV_GPU_CLOCK_FREQUENCIES_VER_2);
    try std.testing.expectEqual(@as(u32, 264 | (3 << 16)), NV_GPU_CLOCK_FREQUENCIES_VER_3);
    try std.testing.expectEqual(@as(u32, 72 | (1 << 16)), NV_GPU_DYNAMIC_PSTATES_INFO_EX_VER);
    try std.testing.expectEqual(@as(u32, 32 | (3 << 16)), NV_DISPLAY_DRIVER_MEMORY_INFO_VER_3);
}

test "splitDeviceId / formatDriverVersion" {
    const d = splitDeviceId(0x268410DE);
    try std.testing.expectEqual(@as(u16, 0x10DE), d.vendor);
    try std.testing.expectEqual(@as(u16, 0x2684), d.device);
    const t = formatDriverVersion(56694, "r565_90");
    try std.testing.expectEqualStrings("566.94 (r565_90)", t.slice());
    const t2 = formatDriverVersion(53203, "");
    try std.testing.expectEqualStrings("532.03", t2.slice());
}

test "applyThermal / applyClocks: syntetyczne dane" {
    var t = std.mem.zeroes(NV_GPU_THERMAL_SETTINGS_V2);
    t.count = 99; // śmieć — przycinany do 3
    t.sensor[0] = .{ .controller = 1, .defaultMinTemp = 0, .defaultMaxTemp = 127, .currentTemp = 48, .target = NVAPI_THERMAL_TARGET_GPU };
    t.sensor[1] = .{ .controller = 1, .defaultMinTemp = 0, .defaultMaxTemp = 127, .currentTemp = 62, .target = NVAPI_THERMAL_TARGET_MEMORY };
    var r: gv.Readings = .{};
    try std.testing.expectEqual(@as(usize, 2), applyThermal(&t, &r));
    try std.testing.expectEqual(@as(f64, 48), r.temp_edge_c.?.value);
    try std.testing.expectEqual(@as(f64, 62), r.temp_mem_c.?.value);

    var c = std.mem.zeroes(NV_GPU_CLOCK_FREQUENCIES_V2);
    c.domain[NVAPI_GPU_PUBLIC_CLOCK_GRAPHICS] = .{ .flags = 1, .frequency = 2520000 };
    c.domain[NVAPI_GPU_PUBLIC_CLOCK_MEMORY] = .{ .flags = 0, .frequency = 10501000 };
    try std.testing.expectEqual(@as(usize, 1), applyClocks(&c, &r));
    try std.testing.expectEqual(@as(f64, 2520), r.gpu_clock_mhz.?.value);
    try std.testing.expect(r.mem_clock_mhz == null);
}

test "Session.open: brak biblioteki / brak GPU nie przerywa procesu" {
    var s = Session.open(std.testing.allocator);
    defer s.close();
    switch (s.library.status) {
        // Maszyna bez NVIDIA: oczekiwane dll_not_found albo no_adapters.
        .dll_not_found, .no_adapters, .unsupported_api, .init_failed => try std.testing.expectEqual(@as(usize, 0), s.adapters.len),
        .available => try std.testing.expect(s.adapters.len > 0),
    }
    try std.testing.expect(s.library.reason.len > 0);
}
