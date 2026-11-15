//! AMD Display Library (ADL) — odczyt czujników i informacji o kartach AMD.
//!
//! Biblioteka `atiadlxx.dll` (64-bit; `atiadlxy.dll` to nazwa 32-bitowa) jest
//! ładowana **dynamicznie** z System32. Brak pliku, stara wersja albo
//! brakujące eksporty dają status zamiast błędu — moduł nigdy nie przerywa
//! procesu. Używamy wyłącznie API z kontekstem (`ADL2_*`) i wyłącznie funkcji
//! odczytu (Get/Caps/Query). Żadna funkcja Set/Overdrive-set/sterowania
//! wentylatorem/resetu nie jest nawet deklarowana.
//!
//! ## Kolejność ścieżek odczytu czujników
//!
//! 1. Overdrive 8 (RDNA/Vega20+): `ADL2_New_QueryPMLogData_Get` → tablica
//!    `ADLSingleSensorData[256]` indeksowana `ADL_PMLOG_*`.
//! 2. OverdriveN (Polaris/Vega): `ADL2_OverdriveN_PerformanceStatus_Get`,
//!    `ADL2_OverdriveN_Temperature_Get`, `ADL2_OverdriveN_FanControl_Get`.
//! 3. Overdrive5 (starsze GCN): `ADL2_Overdrive5_CurrentActivity_Get`,
//!    `ADL2_Overdrive5_Temperature_Get`, `ADL2_Overdrive5_FanSpeed_Get`.
//!
//! Pierwsza ścieżka, która zwróci `ADL_OK` i choć jeden wiarygodny odczyt,
//! jest zapamiętywana dla adaptera i używana przy kolejnych `poll`.
//!
//! ## Źródła stałych i układów struktur
//!
//! GPUOpen display-library (MIT), gałąź master:
//!   * include/adl_defines.h   — ADL_MAX_PATH=256, ADL_MAX_ADAPTERS=250,
//!     kody ADL_OK/ADL_ERR_*, ADL_PMLOG_MAX_SENSORS=256, enum ADL_PMLOG_SENSORS,
//!     ADL_DL_FANCTRL_SPEED_TYPE_PERCENT=1 / _RPM=2.
//!   * include/adl_structures.h — AdapterInfo, ADLSingleSensorData,
//!     ADLPMLogDataOutput, ADLODNPerformanceStatus, ADLODNFanControl,
//!     ADLPMActivity, ADLTemperature, ADLFanSpeedValue, ADLMemoryInfo2,
//!     ADLMemoryInfoX4, ADLVersionsInfo, ADLVersionsInfoX2.
//!   * include/adl_sdk.h — ADL_MAIN_MALLOC_CALLBACK `void* (__stdcall*)(int)`.
//!   * Public-Documents/html/*_8h_source.html (adl.h, adapter.h, overdrive5.h,
//!     overdriveN.h, overdrive8.h, graphics.h) — sygnatury funkcji ADL2_*.
//!   * Sample/Overdrive/Overdrive_Sample.cpp — OD5: temperatura w milistopniach,
//!     zegary w jednostkach 10 kHz (`/100` → MHz).
//!   * Sample/OverdriveN/OverdriveN.cpp — `ADL2_OverdriveN_Temperature_Get(..., 1, ...)`.
//! Typ temperatury ODN (1=EDGE, 2=MEM, ..., 7=HOTSPOT) nie jest w nagłówku
//! AMD; wartości wzięte z LibreHardwareMonitor (MPL-2.0)
//! LibreHardwareMonitorLib/Interop/AtiAdlxx.cs `ADLODNTemperatureType`.
//!
//! ## Konwencja wywołań
//!
//! Moduł jest przeznaczony dla procesu x86_64 — tam istnieje jedna konwencja
//! (Microsoft x64), więc `callconv(.c)` dla funkcji i `.winapi` dla callbacku
//! malloc są równoważne. Na innych architekturach/OS `Session.open` zwraca
//! `unsupported_api` bez dotykania DLL.

const std = @import("std");
const builtin = @import("builtin");
const gv = @import("gpu_vendor.zig");

const Allocator = std.mem.Allocator;

pub const dll_name_64 = "atiadlxx.dll";
pub const dll_name_32 = "atiadlxy.dll";

// ---------------------------------------------------------------------------
// Stałe (adl_defines.h)
// ---------------------------------------------------------------------------

pub const ADL_MAX_PATH = 256; // adl_defines.h:53
pub const ADL_MAX_ADAPTERS = 250; // adl_defines.h:55
pub const ADL_OK = 0; // adl_defines.h:109
pub const ADL_OK_WARNING = 1; // adl_defines.h:107
pub const ADL_ERR = -1; // adl_defines.h:111
pub const ADL_ERR_NOT_SUPPORTED = -8; // adl_defines.h:125
pub const ADL_PMLOG_MAX_SENSORS = 256; // adl_defines.h "#define ADL_PMLOG_MAX_SENSORS 256"
pub const ADL_DL_FANCTRL_SPEED_TYPE_PERCENT = 1; // adl_defines.h:1144
pub const ADL_DL_FANCTRL_SPEED_TYPE_RPM = 2; // adl_defines.h:1145

/// Wybrane wartości `enum ADL_PMLOG_SENSORS` (adl_defines.h, typedef enum ADL_PMLOG_SENSORS).
pub const PmLog = struct {
    pub const CLK_GFXCLK = 1;
    pub const CLK_MEMCLK = 2;
    pub const TEMPERATURE_EDGE = 8;
    pub const TEMPERATURE_MEM = 9;
    pub const FAN_RPM = 14;
    pub const FAN_PERCENTAGE = 15;
    pub const INFO_ACTIVITY_GFX = 19;
    pub const GFX_VOLTAGE = 21; // mV
    pub const ASIC_POWER = 23; // W
    pub const TEMPERATURE_HOTSPOT = 27;
    pub const TEMPERATURE_GFX = 28;
    pub const TEMPERATURE_HOTSPOT_GCD = 50;
    pub const BOARD_POWER = 73; // W
};

/// Typ temperatury dla `ADL2_OverdriveN_Temperature_Get` (patrz nagłówek pliku).
const OdnTemp = struct {
    const edge = 1;
    const mem = 2;
    const hotspot = 7;
};

// ---------------------------------------------------------------------------
// Struktury (adl_structures.h) — układ 1:1 z nagłówkiem, rozmiary sprawdzone.
// ---------------------------------------------------------------------------

/// `AdapterInfo` (adl_structures.h:42), wariant Windows (z polami za `iPresent`).
pub const AdapterInfo = extern struct {
    iSize: c_int,
    iAdapterIndex: c_int,
    strUDID: [ADL_MAX_PATH]u8,
    iBusNumber: c_int,
    iDeviceNumber: c_int,
    iFunctionNumber: c_int,
    iVendorID: c_int,
    strAdapterName: [ADL_MAX_PATH]u8,
    strDisplayName: [ADL_MAX_PATH]u8,
    iPresent: c_int,
    iExist: c_int,
    strDriverPath: [ADL_MAX_PATH]u8,
    strDriverPathExt: [ADL_MAX_PATH]u8,
    strPNPString: [ADL_MAX_PATH]u8,
    iOSDisplayIndex: c_int,
};

pub const ADLSingleSensorData = extern struct {
    supported: c_int,
    value: c_int,
};

pub const ADLPMLogDataOutput = extern struct {
    size: c_int,
    sensors: [ADL_PMLOG_MAX_SENSORS]ADLSingleSensorData,
};

pub const ADLODNPerformanceStatus = extern struct {
    iCoreClock: c_int,
    iMemoryClock: c_int,
    iDCEFClock: c_int,
    iGFXClock: c_int,
    iUVDClock: c_int,
    iVCEClock: c_int,
    iGPUActivityPercent: c_int,
    iCurrentCorePerformanceLevel: c_int,
    iCurrentMemoryPerformanceLevel: c_int,
    iCurrentDCEFPerformanceLevel: c_int,
    iCurrentGFXPerformanceLevel: c_int,
    iUVDPerformanceLevel: c_int,
    iVCEPerformanceLevel: c_int,
    iCurrentBusSpeed: c_int,
    iCurrentBusLanes: c_int,
    iMaximumBusLanes: c_int,
    iVDDC: c_int,
    iVDDCI: c_int,
};

pub const ADLODNFanControl = extern struct {
    iMode: c_int,
    iFanControlMode: c_int,
    iCurrentFanSpeedMode: c_int,
    iCurrentFanSpeed: c_int,
    iTargetFanSpeed: c_int,
    iTargetTemperature: c_int,
    iMinPerformanceClock: c_int,
    iMinFanLimit: c_int,
};

pub const ADLPMActivity = extern struct {
    iSize: c_int,
    iEngineClock: c_int,
    iMemoryClock: c_int,
    iVddc: c_int,
    iActivityPercent: c_int,
    iCurrentPerformanceLevel: c_int,
    iCurrentBusSpeed: c_int,
    iCurrentBusLanes: c_int,
    iMaximumBusLanes: c_int,
    iReserved: c_int,
};

pub const ADLTemperature = extern struct {
    iSize: c_int,
    iTemperature: c_int,
};

pub const ADLFanSpeedValue = extern struct {
    iSize: c_int,
    iSpeedType: c_int,
    iFanSpeed: c_int,
    iFlags: c_int,
};

pub const ADLMemoryInfo2 = extern struct {
    iMemorySize: i64,
    strMemoryType: [ADL_MAX_PATH]u8,
    iMemoryBandwidth: i64,
    iHyperMemorySize: i64,
    iInvisibleMemorySize: i64,
    iVisibleMemorySize: i64,
};

pub const ADLMemoryInfoX4 = extern struct {
    iMemorySize: i64,
    strMemoryType: [ADL_MAX_PATH]u8,
    iMemoryBandwidth: i64,
    iHyperMemorySize: i64,
    iInvisibleMemorySize: i64,
    iVisibleMemorySize: i64,
    iVramVendorRevId: i64,
    iMemoryBandwidthX2: i64,
    iMemoryBitRateX2: i64,
};

pub const ADLVersionsInfo = extern struct {
    strDriverVer: [ADL_MAX_PATH]u8,
    strCatalystVersion: [ADL_MAX_PATH]u8,
    strCatalystWebLink: [ADL_MAX_PATH]u8,
};

pub const ADLVersionsInfoX2 = extern struct {
    strDriverVer: [ADL_MAX_PATH]u8,
    strCatalystVersion: [ADL_MAX_PATH]u8,
    strCrimsonVersion: [ADL_MAX_PATH]u8,
    strCatalystWebLink: [ADL_MAX_PATH]u8,
};

comptime {
    // 2*int + UDID + 4*int + 2*str + 2*int + 3*str + int = 1572
    std.debug.assert(@sizeOf(AdapterInfo) == 1572);
    std.debug.assert(@sizeOf(ADLSingleSensorData) == 8);
    std.debug.assert(@sizeOf(ADLPMLogDataOutput) == 4 + 256 * 8);
    std.debug.assert(@sizeOf(ADLODNPerformanceStatus) == 18 * 4);
    std.debug.assert(@sizeOf(ADLODNFanControl) == 8 * 4);
    std.debug.assert(@sizeOf(ADLPMActivity) == 10 * 4);
    std.debug.assert(@sizeOf(ADLTemperature) == 8);
    std.debug.assert(@sizeOf(ADLFanSpeedValue) == 16);
    std.debug.assert(@sizeOf(ADLMemoryInfo2) == 8 + 256 + 4 * 8);
    std.debug.assert(@sizeOf(ADLMemoryInfoX4) == 8 + 256 + 7 * 8);
    std.debug.assert(@sizeOf(ADLVersionsInfo) == 3 * 256);
    std.debug.assert(@sizeOf(ADLVersionsInfoX2) == 4 * 256);
}

// ---------------------------------------------------------------------------
// Typy funkcji (sygnatury z Public-Documents/html/*_8h_source.html)
// ---------------------------------------------------------------------------

const Ctx = ?*anyopaque; // ADL_CONTEXT_HANDLE
const MallocCb = *const fn (c_int) callconv(.winapi) ?*anyopaque;

const Fns = struct {
    // adl.h / adapter.h
    create: ?*const fn (MallocCb, c_int, *Ctx) callconv(.c) c_int = null,
    destroy: ?*const fn (Ctx) callconv(.c) c_int = null,
    num_adapters: ?*const fn (Ctx, *c_int) callconv(.c) c_int = null,
    adapter_info: ?*const fn (Ctx, [*]AdapterInfo, c_int) callconv(.c) c_int = null,
    active_get: ?*const fn (Ctx, c_int, *c_int) callconv(.c) c_int = null,
    mem_info2: ?*const fn (Ctx, c_int, *ADLMemoryInfo2) callconv(.c) c_int = null,
    mem_info_x4: ?*const fn (Ctx, c_int, *ADLMemoryInfoX4) callconv(.c) c_int = null,
    // graphics.h
    versions: ?*const fn (Ctx, *ADLVersionsInfo) callconv(.c) c_int = null,
    versions_x2: ?*const fn (Ctx, *ADLVersionsInfoX2) callconv(.c) c_int = null,
    // overdrive8.h
    od_caps: ?*const fn (Ctx, c_int, *c_int, *c_int, *c_int) callconv(.c) c_int = null,
    pmlog_get: ?*const fn (Ctx, c_int, *ADLPMLogDataOutput) callconv(.c) c_int = null,
    // overdriveN.h
    odn_perf: ?*const fn (Ctx, c_int, *ADLODNPerformanceStatus) callconv(.c) c_int = null,
    odn_temp: ?*const fn (Ctx, c_int, c_int, *c_int) callconv(.c) c_int = null,
    odn_fan: ?*const fn (Ctx, c_int, *ADLODNFanControl) callconv(.c) c_int = null,
    // overdrive5.h
    od5_activity: ?*const fn (Ctx, c_int, *ADLPMActivity) callconv(.c) c_int = null,
    od5_temp: ?*const fn (Ctx, c_int, c_int, *ADLTemperature) callconv(.c) c_int = null,
    od5_fan: ?*const fn (Ctx, c_int, c_int, *ADLFanSpeedValue) callconv(.c) c_int = null,

    fn load(h: gv.HMODULE) Fns {
        var f: Fns = .{};
        inline for (.{
            .{ "create", "ADL2_Main_Control_Create" },
            .{ "destroy", "ADL2_Main_Control_Destroy" },
            .{ "num_adapters", "ADL2_Adapter_NumberOfAdapters_Get" },
            .{ "adapter_info", "ADL2_Adapter_AdapterInfo_Get" },
            .{ "active_get", "ADL2_Adapter_Active_Get" },
            .{ "mem_info2", "ADL2_Adapter_MemoryInfo2_Get" },
            .{ "mem_info_x4", "ADL2_Adapter_MemoryInfoX4_Get" },
            .{ "versions", "ADL2_Graphics_Versions_Get" },
            .{ "versions_x2", "ADL2_Graphics_VersionsX2_Get" },
            .{ "od_caps", "ADL2_Overdrive_Caps" },
            .{ "pmlog_get", "ADL2_New_QueryPMLogData_Get" },
            .{ "odn_perf", "ADL2_OverdriveN_PerformanceStatus_Get" },
            .{ "odn_temp", "ADL2_OverdriveN_Temperature_Get" },
            .{ "odn_fan", "ADL2_OverdriveN_FanControl_Get" },
            .{ "od5_activity", "ADL2_Overdrive5_CurrentActivity_Get" },
            .{ "od5_temp", "ADL2_Overdrive5_Temperature_Get" },
            .{ "od5_fan", "ADL2_Overdrive5_FanSpeed_Get" },
        }) |e| {
            const T = @typeInfo(@FieldType(Fns, e[0])).optional.child;
            @field(f, e[0]) = gv.getProc(T, h, e[1]);
        }
        return f;
    }
};

/// Callback malloc wymagany przez `ADL2_Main_Control_Create`. Pamięć z
/// domyślnej sterty procesu (wątkowo bezpieczna, bez libc). Funkcje, których
/// używamy, piszą do buforów podanych przez nas, więc ADL nie oddaje nam
/// pamięci z tego callbacku do zwolnienia; ewentualne wewnętrzne alokacje ADL
/// nie mają w API odpowiednika `free` (tak samo w próbkach AMD).
fn adlMalloc(size: c_int) callconv(.winapi) ?*anyopaque {
    if (size <= 0) return null;
    const k32 = std.os.windows.kernel32;
    const heap = k32.GetProcessHeap() orelse return null;
    const HEAP_ZERO_MEMORY: u32 = 0x00000008;
    return k32.HeapAlloc(heap, HEAP_ZERO_MEMORY, @intCast(size));
}

// ---------------------------------------------------------------------------
// Mapowanie PMLog → model (czyste, testowalne)
// ---------------------------------------------------------------------------

pub const Field = enum { gpu_clock, mem_clock, temp_edge, temp_hotspot, temp_mem, fan_rpm, fan_percent, load, power, voltage };

pub const PmMapEntry = struct {
    sensor: u16,
    field: Field,
    unit: []const u8,
    scale: f64,
    source: []const u8,
};

/// Kolejność ma znaczenie: dla danego pola wygrywa **pierwszy** obsługiwany
/// czujnik (np. BOARD_POWER przed ASIC_POWER — tak robi LHM dla RDNA3/Navi3x,
/// gdzie ASIC_POWER bywa niepełny; HOTSPOT przed HOTSPOT_GCD; EDGE przed GFX).
pub const pmlog_map = [_]PmMapEntry{
    .{ .sensor = PmLog.CLK_GFXCLK, .field = .gpu_clock, .unit = "MHz", .scale = 1, .source = "ADL OD8 PMLog ADL_PMLOG_CLK_GFXCLK" },
    .{ .sensor = PmLog.CLK_MEMCLK, .field = .mem_clock, .unit = "MHz", .scale = 1, .source = "ADL OD8 PMLog ADL_PMLOG_CLK_MEMCLK" },
    .{ .sensor = PmLog.TEMPERATURE_EDGE, .field = .temp_edge, .unit = "C", .scale = 1, .source = "ADL OD8 PMLog ADL_PMLOG_TEMPERATURE_EDGE" },
    .{ .sensor = PmLog.TEMPERATURE_GFX, .field = .temp_edge, .unit = "C", .scale = 1, .source = "ADL OD8 PMLog ADL_PMLOG_TEMPERATURE_GFX" },
    .{ .sensor = PmLog.TEMPERATURE_HOTSPOT, .field = .temp_hotspot, .unit = "C", .scale = 1, .source = "ADL OD8 PMLog ADL_PMLOG_TEMPERATURE_HOTSPOT" },
    .{ .sensor = PmLog.TEMPERATURE_HOTSPOT_GCD, .field = .temp_hotspot, .unit = "C", .scale = 1, .source = "ADL OD8 PMLog ADL_PMLOG_TEMPERATURE_HOTSPOT_GCD" },
    .{ .sensor = PmLog.TEMPERATURE_MEM, .field = .temp_mem, .unit = "C", .scale = 1, .source = "ADL OD8 PMLog ADL_PMLOG_TEMPERATURE_MEM" },
    .{ .sensor = PmLog.FAN_RPM, .field = .fan_rpm, .unit = "RPM", .scale = 1, .source = "ADL OD8 PMLog ADL_PMLOG_FAN_RPM" },
    .{ .sensor = PmLog.FAN_PERCENTAGE, .field = .fan_percent, .unit = "%", .scale = 1, .source = "ADL OD8 PMLog ADL_PMLOG_FAN_PERCENTAGE" },
    .{ .sensor = PmLog.INFO_ACTIVITY_GFX, .field = .load, .unit = "%", .scale = 1, .source = "ADL OD8 PMLog ADL_PMLOG_INFO_ACTIVITY_GFX" },
    .{ .sensor = PmLog.BOARD_POWER, .field = .power, .unit = "W", .scale = 1, .source = "ADL OD8 PMLog ADL_PMLOG_BOARD_POWER" },
    .{ .sensor = PmLog.ASIC_POWER, .field = .power, .unit = "W", .scale = 1, .source = "ADL OD8 PMLog ADL_PMLOG_ASIC_POWER" },
    .{ .sensor = PmLog.GFX_VOLTAGE, .field = .voltage, .unit = "V", .scale = 0.001, .source = "ADL OD8 PMLog ADL_PMLOG_GFX_VOLTAGE" },
};

fn fieldPtr(r: *gv.Readings, f: Field) *?gv.Reading {
    return switch (f) {
        .gpu_clock => &r.gpu_clock_mhz,
        .mem_clock => &r.mem_clock_mhz,
        .temp_edge => &r.temp_edge_c,
        .temp_hotspot => &r.temp_hotspot_c,
        .temp_mem => &r.temp_mem_c,
        .fan_rpm => &r.fan_rpm,
        .fan_percent => &r.fan_percent,
        .load => &r.load_percent,
        .power => &r.power_w,
        .voltage => &r.voltage_v,
    };
}

/// Ustawia odczyt tylko, jeśli pole jest jeszcze puste (pierwszy wygrywa).
fn setOnce(r: *gv.Readings, f: Field, value: f64, unit: []const u8, source: []const u8) bool {
    const p = fieldPtr(r, f);
    if (p.* != null) return false;
    p.* = gv.reading(value, unit, source) orelse return false;
    return true;
}

/// Przenosi obsługiwane czujniki z wyniku PMLog do modelu. Zwraca liczbę
/// ustawionych pól. Pole `size` nie jest wiarygodne między wersjami
/// sterownika, więc decyduje wyłącznie flaga `supported` danego czujnika.
pub fn applyPmLog(data: *const ADLPMLogDataOutput, r: *gv.Readings) usize {
    var n: usize = 0;
    for (pmlog_map) |e| {
        const s = data.sensors[e.sensor];
        if (s.supported == 0) continue;
        const v = @as(f64, @floatFromInt(s.value)) * e.scale;
        if (setOnce(r, e.field, v, e.unit, e.source)) n += 1;
    }
    return n;
}

/// Temperatura ODN: dla EDGE sterownik zwraca milistopnie, dla innych typów
/// bywają stopnie (obserwacja LHM). Normalizujemy heurystycznie.
pub fn odnTempToC(raw: c_int) f64 {
    const v: f64 = @floatFromInt(raw);
    return if (@abs(v) >= 1000) v / 1000.0 else v;
}

// ---------------------------------------------------------------------------
// Sesja
// ---------------------------------------------------------------------------

const Method = enum { pmlog, odn, od5 };

const Priv = struct {
    method: ?Method = null,
    od_version: c_int = 0,
};

pub const Session = struct {
    alloc: Allocator,
    dll: ?gv.HMODULE = null,
    ctx: Ctx = null,
    fns: Fns = .{},
    library: gv.LibraryInfo = .{ .name = dll_name_64 },
    adapters: []gv.Adapter = &.{},
    priv: []Priv = &.{},

    /// Ładuje DLL, tworzy kontekst ADL, wylicza adaptery i wykonuje pierwszy
    /// odczyt. Nigdy nie zawodzi — stan opisuje `library.status`/`reason`.
    pub fn open(alloc: Allocator) Session {
        var s: Session = .{ .alloc = alloc };
        if (builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) {
            s.fail(.unsupported_api, "ADL: obsługiwany tylko proces Windows x86_64");
            return s;
        }
        s.dll = gv.loadSystemDll(dll_name_64);
        if (s.dll == null) {
            s.fail(.dll_not_found, "ADL: brak atiadlxx.dll w System32 (brak sterownika AMD)");
            return s;
        }
        s.fns = Fns.load(s.dll.?);
        const create = s.fns.create orelse return s.failRet(.unsupported_api, "ADL: brak eksportu ADL2_Main_Control_Create (za stary sterownik)");
        if (s.fns.destroy == null or s.fns.num_adapters == null or s.fns.adapter_info == null) {
            s.fail(.unsupported_api, "ADL: brak podstawowych eksportów ADL2_Adapter_*");
            return s;
        }

        var ctx: Ctx = null;
        const rc = create(&adlMalloc, 1, &ctx);
        if (rc != ADL_OK or ctx == null) {
            s.fail(.{ .init_failed = rc }, "ADL: ADL2_Main_Control_Create zwrócił błąd");
            return s;
        }
        s.ctx = ctx;

        s.enumerate() catch {
            s.fail(.{ .init_failed = ADL_ERR }, "ADL: brak pamięci przy wyliczaniu adapterów");
            return s;
        };
        if (s.adapters.len == 0) {
            s.fail(.no_adapters, "ADL: sterownik nie zgłosił żadnego adaptera AMD");
            return s;
        }
        s.library.status = .available;
        s.library.reason = "ADL: dostępne";
        s.poll();
        return s;
    }

    fn fail(self: *Session, st: gv.Status, reason: []const u8) void {
        self.library.status = st;
        self.library.reason = reason;
    }

    fn failRet(self: *Session, st: gv.Status, reason: []const u8) Session {
        self.fail(st, reason);
        return self.*;
    }

    /// Odświeża wyłącznie czujniki dynamiczne. Tanie (bez ładowania DLL),
    /// przeznaczone do wołania co ~1 s z jednego wątku.
    pub fn poll(self: *Session) void {
        if (self.library.status != .available) return;
        for (self.adapters, self.priv) |*a, *p| self.pollAdapter(a, p);
    }

    /// Przenosi listę adapterów do `Result` (sesja przestaje ją posiadać).
    pub fn takeResult(self: *Session) gv.Result {
        const r: gv.Result = .{ .library = self.library, .adapters = self.adapters };
        self.adapters = &.{};
        self.alloc.free(self.priv);
        self.priv = &.{};
        return r;
    }

    pub fn close(self: *Session) void {
        if (self.ctx != null) {
            if (self.fns.destroy) |d| _ = d(self.ctx);
            self.ctx = null;
        }
        if (self.dll) |h| gv.freeDll(h);
        self.dll = null;
        self.alloc.free(self.adapters);
        self.alloc.free(self.priv);
        self.adapters = &.{};
        self.priv = &.{};
    }

    // --- wyliczanie -------------------------------------------------------

    fn enumerate(self: *Session) Allocator.Error!void {
        var n: c_int = 0;
        if (self.fns.num_adapters.?(self.ctx, &n) != ADL_OK) return;
        if (n <= 0) return;
        const count: usize = @intCast(@min(n, ADL_MAX_ADAPTERS));

        const infos = try self.alloc.alloc(AdapterInfo, count);
        defer self.alloc.free(infos);
        @memset(std.mem.sliceAsBytes(infos), 0);
        for (infos) |*i| i.iSize = @sizeOf(AdapterInfo);
        const bytes: c_int = @intCast(count * @sizeOf(AdapterInfo));
        if (self.fns.adapter_info.?(self.ctx, infos.ptr, bytes) != ADL_OK) return;

        const driver = self.readDriverVersion();

        var list: std.ArrayList(gv.Adapter) = .empty;
        errdefer list.deinit(self.alloc);
        var privs: std.ArrayList(Priv) = .empty;
        errdefer privs.deinit(self.alloc);

        for (infos) |*info| {
            const ids = gv.parsePnpString(cStr(&info.strPNPString));
            // ADL wylicza tylko karty AMD, ale nie ufamy temu ślepo.
            if (ids.vendor_id) |v| if (v != 0x1002) continue;
            if (!isAmdVendorField(info.iVendorID) and ids.vendor_id == null) continue;

            const pci: ?gv.PciLocation = if (info.iBusNumber >= 0 and info.iDeviceNumber >= 0 and info.iFunctionNumber >= 0)
                .{ .bus = @intCast(info.iBusNumber), .device = @intCast(info.iDeviceNumber), .function = @intCast(info.iFunctionNumber) }
            else
                null;

            // Deduplikacja: jedna pozycja ADL na wyjście ekranu → grupujemy po
            // PCI (a gdy brak — po UDID).
            const dup = findDuplicate(list.items, infos, info, pci);
            if (dup) |idx| {
                // Wolimy indeks aktywny (podłączony) — część zapytań działa
                // tylko na nim.
                if (!self.isActive(list.items[idx].native_index) and self.isActive(info.iAdapterIndex))
                    list.items[idx].native_index = info.iAdapterIndex;
                continue;
            }

            var a: gv.Adapter = .{ .vendor_library = "ADL" };
            a.native_index = info.iAdapterIndex;
            a.name = gv.Text.fromC(&info.strAdapterName);
            a.pci = pci;
            a.vendor_id = ids.vendor_id orelse 0x1002;
            a.device_id = ids.device_id;
            a.subsys_id = ids.subsys_id;
            a.revision = ids.revision;
            if (driver) |d| a.readings.driver_version = d;
            try list.append(self.alloc, a);
            try privs.append(self.alloc, .{});
        }

        // Dane statyczne per fizyczny adapter.
        for (list.items, privs.items) |*a, *p| {
            self.readStatic(a, p);
        }

        self.adapters = try list.toOwnedSlice(self.alloc);
        self.priv = privs.toOwnedSlice(self.alloc) catch |e| {
            self.alloc.free(self.adapters);
            self.adapters = &.{};
            return e;
        };
    }

    fn findDuplicate(items: []const gv.Adapter, infos: []const AdapterInfo, info: *const AdapterInfo, pci: ?gv.PciLocation) ?usize {
        for (items, 0..) |*a, idx| {
            if (pci) |p| {
                if (a.pci) |q| if (p.eql(q)) return idx;
            } else {
                // Porównanie UDID z pozycją, z której powstał adapter.
                for (infos) |*o| {
                    if (o.iAdapterIndex == a.native_index and o.strUDID[0] != 0 and
                        std.mem.eql(u8, cStr(&o.strUDID), cStr(&info.strUDID))) return idx;
                }
            }
        }
        return null;
    }

    fn isActive(self: *Session, index: i32) bool {
        const f = self.fns.active_get orelse return false;
        var st: c_int = 0;
        return f(self.ctx, index, &st) == ADL_OK and st != 0;
    }

    fn readDriverVersion(self: *Session) ?gv.TextReading {
        if (self.fns.versions_x2) |f| {
            var v = std.mem.zeroes(ADLVersionsInfoX2);
            const rc = f(self.ctx, &v);
            // ADL_OK_WARNING: brak linku WWW — pozostałe pola są poprawne.
            if (rc == ADL_OK or rc == ADL_OK_WARNING) {
                const drv = gv.Text.fromC(&v.strDriverVer);
                const crim = gv.Text.fromC(&v.strCrimsonVersion);
                if (!drv.isEmpty()) {
                    self.library.version = if (crim.isEmpty())
                        gv.Text.print("driver {s}", .{drv.slice()})
                    else
                        gv.Text.print("driver {s}, Adrenalin {s}", .{ drv.slice(), crim.slice() });
                    return .{ .text = self.library.version, .source = "ADL ADL2_Graphics_VersionsX2_Get" };
                }
            }
        }
        if (self.fns.versions) |f| {
            var v = std.mem.zeroes(ADLVersionsInfo);
            const rc = f(self.ctx, &v);
            if (rc == ADL_OK or rc == ADL_OK_WARNING) {
                const drv = gv.Text.fromC(&v.strDriverVer);
                if (!drv.isEmpty()) {
                    self.library.version = gv.Text.print("driver {s}", .{drv.slice()});
                    return .{ .text = self.library.version, .source = "ADL ADL2_Graphics_Versions_Get" };
                }
            }
        }
        return null;
    }

    fn readStatic(self: *Session, a: *gv.Adapter, p: *Priv) void {
        const idx: c_int = a.native_index;
        if (self.fns.od_caps) |f| {
            var sup: c_int = 0;
            var en: c_int = 0;
            var ver: c_int = 0;
            if (f(self.ctx, idx, &sup, &en, &ver) == ADL_OK and sup != 0) p.od_version = ver;
        }
        if (self.fns.mem_info_x4) |f| {
            var m = std.mem.zeroes(ADLMemoryInfoX4);
            if (f(self.ctx, idx, &m) == ADL_OK) {
                setMemory(a, m.iMemorySize, &m.strMemoryType, "ADL ADL2_Adapter_MemoryInfoX4_Get");
                if (a.readings.vram_bytes != null) return;
            }
        }
        if (self.fns.mem_info2) |f| {
            var m = std.mem.zeroes(ADLMemoryInfo2);
            if (f(self.ctx, idx, &m) == ADL_OK)
                setMemory(a, m.iMemorySize, &m.strMemoryType, "ADL ADL2_Adapter_MemoryInfo2_Get");
        }
    }

    fn setMemory(a: *gv.Adapter, size: i64, mem_type: []const u8, source: []const u8) void {
        if (size > 0) a.readings.vram_bytes = gv.reading(@floatFromInt(size), "B", source);
        const t = gv.Text.fromC(mem_type);
        if (!t.isEmpty()) a.readings.vram_type = .{ .text = t, .source = source };
    }

    // --- odczyt czujników -------------------------------------------------

    fn pollAdapter(self: *Session, a: *gv.Adapter, p: *Priv) void {
        a.readings.clearDynamic();
        if (p.method) |m| {
            if (self.readVia(m, a)) return;
            a.readings.clearDynamic();
        }
        for ([_]Method{ .pmlog, .odn, .od5 }) |m| {
            if (p.method == m) continue;
            if (self.readVia(m, a)) {
                p.method = m;
                a.sensor_path = switch (m) {
                    .pmlog => "ADL Overdrive8 PMLog",
                    .odn => "ADL OverdriveN",
                    .od5 => "ADL Overdrive5",
                };
                return;
            }
            a.readings.clearDynamic();
        }
        p.method = null;
        a.sensor_path = "none";
    }

    fn readVia(self: *Session, m: Method, a: *gv.Adapter) bool {
        return switch (m) {
            .pmlog => self.readPmLog(a),
            .odn => self.readOdn(a),
            .od5 => self.readOd5(a),
        };
    }

    fn readPmLog(self: *Session, a: *gv.Adapter) bool {
        const f = self.fns.pmlog_get orelse return false;
        var out = std.mem.zeroes(ADLPMLogDataOutput);
        out.size = @sizeOf(ADLPMLogDataOutput);
        if (f(self.ctx, a.native_index, &out) != ADL_OK) return false;
        return applyPmLog(&out, &a.readings) > 0;
    }

    fn readOdn(self: *Session, a: *gv.Adapter) bool {
        const r = &a.readings;
        var n: usize = 0;
        const idx = a.native_index;
        if (self.fns.odn_perf) |f| {
            var ps = std.mem.zeroes(ADLODNPerformanceStatus);
            if (f(self.ctx, idx, &ps) == ADL_OK) {
                // Zegary ODN w jednostkach 10 kHz (jak OD5) — `/100` → MHz.
                if (ps.iCoreClock > 0 and setOnce(r, .gpu_clock, @as(f64, @floatFromInt(ps.iCoreClock)) / 100.0, "MHz", "ADL OverdriveN PerformanceStatus iCoreClock")) n += 1;
                if (ps.iMemoryClock > 0 and setOnce(r, .mem_clock, @as(f64, @floatFromInt(ps.iMemoryClock)) / 100.0, "MHz", "ADL OverdriveN PerformanceStatus iMemoryClock")) n += 1;
                if (setOnce(r, .load, @floatFromInt(ps.iGPUActivityPercent), "%", "ADL OverdriveN PerformanceStatus iGPUActivityPercent")) n += 1;
                if (ps.iVDDC > 0 and setOnce(r, .voltage, @as(f64, @floatFromInt(ps.iVDDC)) / 1000.0, "V", "ADL OverdriveN PerformanceStatus iVDDC")) n += 1;
            }
        }
        if (self.fns.odn_temp) |f| {
            const T = struct { t: c_int, field: Field, src: []const u8 };
            for ([_]T{
                .{ .t = OdnTemp.edge, .field = .temp_edge, .src = "ADL OverdriveN Temperature EDGE(1)" },
                .{ .t = OdnTemp.hotspot, .field = .temp_hotspot, .src = "ADL OverdriveN Temperature HOTSPOT(7)" },
                .{ .t = OdnTemp.mem, .field = .temp_mem, .src = "ADL OverdriveN Temperature MEM(2)" },
            }) |e| {
                var v: c_int = 0;
                if (f(self.ctx, idx, e.t, &v) == ADL_OK and v != 0) {
                    if (setOnce(r, e.field, odnTempToC(v), "C", e.src)) n += 1;
                }
            }
        }
        if (self.fns.odn_fan) |f| {
            var fc = std.mem.zeroes(ADLODNFanControl);
            if (f(self.ctx, idx, &fc) == ADL_OK) {
                const v: f64 = @floatFromInt(fc.iCurrentFanSpeed);
                switch (fc.iCurrentFanSpeedMode) {
                    ADL_DL_FANCTRL_SPEED_TYPE_RPM => {
                        if (setOnce(r, .fan_rpm, v, "RPM", "ADL OverdriveN FanControl iCurrentFanSpeed (RPM)")) n += 1;
                    },
                    ADL_DL_FANCTRL_SPEED_TYPE_PERCENT => {
                        if (setOnce(r, .fan_percent, v, "%", "ADL OverdriveN FanControl iCurrentFanSpeed (%)")) n += 1;
                    },
                    else => {},
                }
            }
        }
        return n > 0;
    }

    fn readOd5(self: *Session, a: *gv.Adapter) bool {
        const r = &a.readings;
        var n: usize = 0;
        const idx = a.native_index;
        if (self.fns.od5_activity) |f| {
            var act = std.mem.zeroes(ADLPMActivity);
            act.iSize = @sizeOf(ADLPMActivity);
            if (f(self.ctx, idx, &act) == ADL_OK) {
                if (act.iEngineClock > 0 and setOnce(r, .gpu_clock, @as(f64, @floatFromInt(act.iEngineClock)) / 100.0, "MHz", "ADL Overdrive5 CurrentActivity iEngineClock")) n += 1;
                if (act.iMemoryClock > 0 and setOnce(r, .mem_clock, @as(f64, @floatFromInt(act.iMemoryClock)) / 100.0, "MHz", "ADL Overdrive5 CurrentActivity iMemoryClock")) n += 1;
                if (setOnce(r, .load, @floatFromInt(act.iActivityPercent), "%", "ADL Overdrive5 CurrentActivity iActivityPercent")) n += 1;
                if (act.iVddc > 0 and setOnce(r, .voltage, @as(f64, @floatFromInt(act.iVddc)) / 1000.0, "V", "ADL Overdrive5 CurrentActivity iVddc")) n += 1;
            }
        }
        if (self.fns.od5_temp) |f| {
            var t = std.mem.zeroes(ADLTemperature);
            t.iSize = @sizeOf(ADLTemperature);
            // Milistopnie (Sample/Overdrive/Overdrive_Sample.cpp).
            if (f(self.ctx, idx, 0, &t) == ADL_OK and t.iTemperature != 0) {
                if (setOnce(r, .temp_edge, @as(f64, @floatFromInt(t.iTemperature)) / 1000.0, "C", "ADL Overdrive5 Temperature (controller 0)")) n += 1;
            }
        }
        if (self.fns.od5_fan) |f| {
            for ([_]c_int{ ADL_DL_FANCTRL_SPEED_TYPE_RPM, ADL_DL_FANCTRL_SPEED_TYPE_PERCENT }) |ty| {
                var fs = std.mem.zeroes(ADLFanSpeedValue);
                fs.iSize = @sizeOf(ADLFanSpeedValue);
                fs.iSpeedType = ty;
                if (f(self.ctx, idx, 0, &fs) != ADL_OK) continue;
                const v: f64 = @floatFromInt(fs.iFanSpeed);
                if (ty == ADL_DL_FANCTRL_SPEED_TYPE_RPM) {
                    if (setOnce(r, .fan_rpm, v, "RPM", "ADL Overdrive5 FanSpeed (RPM)")) n += 1;
                } else {
                    if (setOnce(r, .fan_percent, v, "%", "ADL Overdrive5 FanSpeed (%)")) n += 1;
                }
            }
        }
        return n > 0;
    }
};

/// Jednorazowe zapytanie: otwiera sesję, czyta wszystko, zamyka DLL.
/// Zwolnij wynik przez `Result.deinit(alloc)`.
pub fn query(alloc: Allocator) gv.Result {
    var s = Session.open(alloc);
    const r = s.takeResult();
    s.close();
    return r;
}

/// ADL podaje `iVendorID` raz jako 0x1002, raz jako dziesiętne 1002
/// (dosłowny zapis "1002") — akceptujemy obie formy.
fn isAmdVendorField(v: c_int) bool {
    return v == 0x1002 or v == 1002;
}

fn cStr(buf: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
    return buf[0..end];
}

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

test "PMLog: wartości enum zgodne z adl_defines.h" {
    try std.testing.expectEqual(1, PmLog.CLK_GFXCLK);
    try std.testing.expectEqual(2, PmLog.CLK_MEMCLK);
    try std.testing.expectEqual(8, PmLog.TEMPERATURE_EDGE);
    try std.testing.expectEqual(9, PmLog.TEMPERATURE_MEM);
    try std.testing.expectEqual(14, PmLog.FAN_RPM);
    try std.testing.expectEqual(15, PmLog.FAN_PERCENTAGE);
    try std.testing.expectEqual(19, PmLog.INFO_ACTIVITY_GFX);
    try std.testing.expectEqual(21, PmLog.GFX_VOLTAGE);
    try std.testing.expectEqual(23, PmLog.ASIC_POWER);
    try std.testing.expectEqual(27, PmLog.TEMPERATURE_HOTSPOT);
    try std.testing.expectEqual(73, PmLog.BOARD_POWER);
    for (pmlog_map) |e| try std.testing.expect(e.sensor < ADL_PMLOG_MAX_SENSORS);
}

test "applyPmLog: mapowanie, skala, priorytet i walidacja" {
    var d = std.mem.zeroes(ADLPMLogDataOutput);
    const set = struct {
        fn f(o: *ADLPMLogDataOutput, i: usize, v: c_int) void {
            o.sensors[i] = .{ .supported = 1, .value = v };
        }
    }.f;
    set(&d, PmLog.CLK_GFXCLK, 2450);
    set(&d, PmLog.CLK_MEMCLK, 2487);
    set(&d, PmLog.TEMPERATURE_EDGE, 52);
    set(&d, PmLog.TEMPERATURE_GFX, 99); // przegrywa z EDGE
    set(&d, PmLog.TEMPERATURE_HOTSPOT, 70);
    set(&d, PmLog.TEMPERATURE_MEM, 60);
    set(&d, PmLog.FAN_RPM, 1200);
    set(&d, PmLog.FAN_PERCENTAGE, 250); // śmieć — odrzucony
    set(&d, PmLog.INFO_ACTIVITY_GFX, 37);
    set(&d, PmLog.ASIC_POWER, 200);
    set(&d, PmLog.BOARD_POWER, 310); // wygrywa z ASIC_POWER
    set(&d, PmLog.GFX_VOLTAGE, 875);
    d.sensors[PmLog.TEMPERATURE_HOTSPOT_GCD] = .{ .supported = 0, .value = 1 };

    var r: gv.Readings = .{};
    const n = applyPmLog(&d, &r);
    try std.testing.expectEqual(@as(usize, 9), n);
    try std.testing.expectEqual(@as(f64, 2450), r.gpu_clock_mhz.?.value);
    try std.testing.expectEqual(@as(f64, 2487), r.mem_clock_mhz.?.value);
    try std.testing.expectEqual(@as(f64, 52), r.temp_edge_c.?.value);
    try std.testing.expectEqualStrings("ADL OD8 PMLog ADL_PMLOG_TEMPERATURE_EDGE", r.temp_edge_c.?.source);
    try std.testing.expectEqual(@as(f64, 70), r.temp_hotspot_c.?.value);
    try std.testing.expectEqual(@as(f64, 60), r.temp_mem_c.?.value);
    try std.testing.expectEqual(@as(f64, 1200), r.fan_rpm.?.value);
    try std.testing.expect(r.fan_percent == null);
    try std.testing.expectEqual(@as(f64, 37), r.load_percent.?.value);
    try std.testing.expectEqual(@as(f64, 310), r.power_w.?.value);
    try std.testing.expectEqualStrings("ADL OD8 PMLog ADL_PMLOG_BOARD_POWER", r.power_w.?.source);
    try std.testing.expectApproxEqAbs(@as(f64, 0.875), r.voltage_v.?.value, 1e-9);
    try std.testing.expectEqualStrings("V", r.voltage_v.?.unit);
}

test "applyPmLog: same zera supported → nic" {
    const d = std.mem.zeroes(ADLPMLogDataOutput);
    var r: gv.Readings = .{};
    try std.testing.expectEqual(@as(usize, 0), applyPmLog(&d, &r));
}

test "odnTempToC: milistopnie i stopnie" {
    try std.testing.expectEqual(@as(f64, 45), odnTempToC(45000));
    try std.testing.expectEqual(@as(f64, 45), odnTempToC(45));
}

test "isAmdVendorField" {
    try std.testing.expect(isAmdVendorField(0x1002));
    try std.testing.expect(isAmdVendorField(1002));
    try std.testing.expect(!isAmdVendorField(0x10DE));
}

test "Session.open: dowolny stan biblioteki nie przerywa procesu" {
    var s = Session.open(std.testing.allocator);
    defer s.close();
    try std.testing.expect(s.library.reason.len > 0);
    if (s.library.status == .available) try std.testing.expect(s.adapters.len > 0);
    s.poll();
}
