//! Backend Windows: wyliczanie dysków fizycznych i odczyt zdrowia (SMART).
//!
//! Zasady bezpieczeństwa (twarde):
//!   * wyłącznie IOCTL-e odczytowe; do dysku nie trafia żadna komenda
//!     zapisująca ani zmieniająca stan (żadnych SMART ENABLE/DISABLE,
//!     AUTOSAVE, EXECUTE OFFLINE / self-test, żadnych komend admin NVMe poza
//!     odczytem logu przez udokumentowane IOCTL_STORAGE_QUERY_PROPERTY),
//!   * ATA: tylko SMART READ DATA (B0h/D0h) i READ THRESHOLDS (B0h/D1h),
//!   * żadnych sterowników ani usług.
//!
//! Poziomy dostępu:
//!   * `\\.\PhysicalDriveN` otwierany z dostępem 0 (tylko zapytania) działa
//!     bez uprawnień administratora — wystarcza na deskryptor urządzenia,
//!     rozmiar (IOCTL_DISK_GET_DRIVE_GEOMETRY_EX), podpowiedź SSD/HDD
//!     (seek penalty) i zwykle log zdrowia NVMe,
//!   * ATA pass-through i SMART_RCV_DRIVE_DATA wymagają uchwytu
//!     GENERIC_READ|GENERIC_WRITE, czyli administratora. Odmowa dostępu to
//!     status `requires_admin`, nie błąd.
//!
//! Jeden niedziałający dysk nie zatrzymuje pozostałych — każdy wynik niesie
//! własny status i kod błędu Win32. Surowe bajty (deskryptor, log NVMe,
//! strony SMART) są zachowane, żeby integrator mógł je zapisać do replay.

const std = @import("std");
const builtin = @import("builtin");
pub const parse = @import("../storage_parse.zig");

// ---------------------------------------------------------------------------
// Win32
// ---------------------------------------------------------------------------

const DWORD = u32;
const BOOL = i32;
const HANDLE = *anyopaque;

const INVALID_HANDLE_VALUE: usize = std.math.maxInt(usize);
const GENERIC_READ: DWORD = 0x8000_0000;
const GENERIC_WRITE: DWORD = 0x4000_0000;
const FILE_SHARE_READ: DWORD = 0x1;
const FILE_SHARE_WRITE: DWORD = 0x2;
const OPEN_EXISTING: DWORD = 3;

pub const ERROR_INVALID_FUNCTION: DWORD = 1;
pub const ERROR_FILE_NOT_FOUND: DWORD = 2;
pub const ERROR_PATH_NOT_FOUND: DWORD = 3;
pub const ERROR_ACCESS_DENIED: DWORD = 5;
pub const ERROR_GEN_FAILURE: DWORD = 31;
pub const ERROR_NOT_SUPPORTED: DWORD = 50;
pub const ERROR_INVALID_PARAMETER: DWORD = 87;
pub const ERROR_IO_DEVICE: DWORD = 1117;
pub const ERROR_NOT_READY: DWORD = 21;
/// Własny kod: IOCTL się udał, ale odpowiedź jest niepoprawna lub pusta.
pub const ERROR_BAD_RESPONSE: DWORD = 0xE000_0001;
/// Własny kod: urządzenie ustawiło bit ERR w rejestrze statusu ATA.
pub const ERROR_ATA_DEVICE_ERROR: DWORD = 0xE000_0002;

extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?*anyopaque,
) callconv(.winapi) usize;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn DeviceIoControl(
    hDevice: HANDLE,
    dwIoControlCode: DWORD,
    lpInBuffer: ?*const anyopaque,
    nInBufferSize: DWORD,
    lpOutBuffer: ?*anyopaque,
    nOutBufferSize: DWORD,
    lpBytesReturned: ?*DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

fn ctlCode(device_type: u32, function: u32, method: u32, access: u32) u32 {
    return (device_type << 16) | (access << 14) | (function << 2) | method;
}

const FILE_ANY_ACCESS = 0;
const FILE_READ_ACCESS = 1;
const FILE_WRITE_ACCESS = 2;
const METHOD_BUFFERED = 0;

const IOCTL_STORAGE_QUERY_PROPERTY = 0x002D_1400;
const IOCTL_DISK_GET_DRIVE_GEOMETRY_EX = 0x0007_00A0;
const IOCTL_DISK_GET_LENGTH_INFO = 0x0007_405C;
const IOCTL_ATA_PASS_THROUGH = 0x0004_D02C;
const SMART_RCV_DRIVE_DATA = 0x0007_C088;

comptime {
    std.debug.assert(IOCTL_STORAGE_QUERY_PROPERTY == ctlCode(0x2D, 0x500, METHOD_BUFFERED, FILE_ANY_ACCESS));
    std.debug.assert(IOCTL_DISK_GET_DRIVE_GEOMETRY_EX == ctlCode(0x07, 0x28, METHOD_BUFFERED, FILE_ANY_ACCESS));
    std.debug.assert(IOCTL_DISK_GET_LENGTH_INFO == ctlCode(0x07, 0x17, METHOD_BUFFERED, FILE_READ_ACCESS));
    std.debug.assert(IOCTL_ATA_PASS_THROUGH == ctlCode(0x04, 0x40B, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS));
    std.debug.assert(SMART_RCV_DRIVE_DATA == ctlCode(0x07, 0x22, METHOD_BUFFERED, FILE_READ_ACCESS | FILE_WRITE_ACCESS));
}

// STORAGE_PROPERTY_ID
const StorageDeviceProperty = 0;
const StorageDeviceSeekPenaltyProperty = 7;
const StorageAdapterProtocolSpecificProperty = 49;
const StorageDeviceProtocolSpecificProperty = 50;
// STORAGE_QUERY_TYPE
const PropertyStandardQuery = 0;
// STORAGE_PROTOCOL_TYPE
const ProtocolTypeNvme = 3;
// STORAGE_PROTOCOL_NVME_DATA_TYPE
const NVMeDataTypeLogPage = 2;
const NVME_LOG_PAGE_HEALTH_INFO = 0x02;

/// `STORAGE_PROPERTY_QUERY` bez końcowej tablicy (FIELD_OFFSET(AdditionalParameters) = 8).
const STORAGE_PROPERTY_QUERY = extern struct {
    PropertyId: u32,
    QueryType: u32,
    AdditionalParameters: [4]u8 = .{ 0, 0, 0, 0 },
};

/// `STORAGE_PROTOCOL_SPECIFIC_DATA` (winioctl.h, Windows 10+).
const STORAGE_PROTOCOL_SPECIFIC_DATA = extern struct {
    ProtocolType: u32,
    DataType: u32,
    ProtocolDataRequestValue: u32,
    ProtocolDataRequestSubValue: u32,
    ProtocolDataOffset: u32,
    ProtocolDataLength: u32,
    FixedProtocolReturnData: u32,
    ProtocolDataRequestSubValue2: u32,
    ProtocolDataRequestSubValue3: u32,
    ProtocolDataRequestSubValue4: u32,
};

/// Bufor zapytania NVMe: STORAGE_PROPERTY_QUERY (do AdditionalParameters)
/// + STORAGE_PROTOCOL_SPECIFIC_DATA + 512 B logu. Odpowiedź przychodzi w tym
/// samym buforze jako STORAGE_PROTOCOL_DATA_DESCRIPTOR { Version, Size,
/// ProtocolSpecificData } + dane — układ bajtów jest identyczny.
const NvmeQueryBuffer = extern struct {
    property_id: u32, // w odpowiedzi: Version
    query_type: u32, // w odpowiedzi: Size
    spec: STORAGE_PROTOCOL_SPECIFIC_DATA,
    data: [parse.nvme_log_size]u8,
};

/// `STORAGE_PROTOCOL_DATA_DESCRIPTOR` = Version + Size + SPECIFIC_DATA.
const protocol_data_descriptor_size = 8 + @sizeOf(STORAGE_PROTOCOL_SPECIFIC_DATA);

/// `ATA_PASS_THROUGH_EX` (ntddscsi.h). `DataBufferOffset` to ULONG_PTR.
const ATA_PASS_THROUGH_EX = extern struct {
    Length: u16,
    AtaFlags: u16,
    PathId: u8,
    TargetId: u8,
    Lun: u8,
    ReservedAsUchar: u8,
    DataTransferLength: u32,
    TimeOutValue: u32,
    ReservedAsUlong: u32,
    DataBufferOffset: usize,
    PreviousTaskFile: [8]u8,
    CurrentTaskFile: [8]u8,
};

const AtaBuffer = extern struct {
    apt: ATA_PASS_THROUGH_EX,
    data: [parse.ata_smart_size]u8,
};

const ATA_FLAGS_DRDY_REQUIRED: u16 = 0x01;
const ATA_FLAGS_DATA_IN: u16 = 0x02;
const ATA_CMD_SMART: u8 = 0xB0;
const SMART_READ_DATA: u8 = 0xD0;
const SMART_READ_THRESHOLDS: u8 = 0xD1;
const SMART_CYL_LOW: u8 = 0x4F;
const SMART_CYL_HI: u8 = 0xC2;

/// `SENDCMDINPARAMS` (pack 1) bez 1-bajtowego bBuffer = 32 B.
const sendcmd_in_size = 32;
/// `SENDCMDOUTPARAMS` bez bBuffer = 16 B; dane SMART zaczynają się na 16.
const sendcmd_out_header = 16;

comptime {
    std.debug.assert(@sizeOf(STORAGE_PROPERTY_QUERY) == 12);
    std.debug.assert(@offsetOf(STORAGE_PROPERTY_QUERY, "AdditionalParameters") == 8);
    std.debug.assert(@sizeOf(STORAGE_PROTOCOL_SPECIFIC_DATA) == 40);
    std.debug.assert(protocol_data_descriptor_size == 48);
    std.debug.assert(@offsetOf(NvmeQueryBuffer, "spec") == 8);
    std.debug.assert(@offsetOf(NvmeQueryBuffer, "data") == 48);
    std.debug.assert(@sizeOf(NvmeQueryBuffer) == 560);
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@offsetOf(ATA_PASS_THROUGH_EX, "DataBufferOffset") == 24);
        std.debug.assert(@offsetOf(ATA_PASS_THROUGH_EX, "CurrentTaskFile") == 40);
        std.debug.assert(@sizeOf(ATA_PASS_THROUGH_EX) == 48);
        std.debug.assert(@offsetOf(AtaBuffer, "data") == 48);
    } else {
        std.debug.assert(@sizeOf(ATA_PASS_THROUGH_EX) == 40);
    }
}

// ---------------------------------------------------------------------------
// Typy wyniku
// ---------------------------------------------------------------------------

/// Poziom dostępu uchwytu, którym wykonano zapytanie.
pub const AccessLevel = enum {
    none,
    /// dwDesiredAccess = 0 — działa bez administratora.
    query_only,
    /// GENERIC_READ.
    read,
    /// GENERIC_READ | GENERIC_WRITE (wymagany przez ATA pass-through).
    /// Uchwyt nie służy do zapisu — tego poziomu wymaga sam IOCTL.
    read_write,

    pub fn toSlice(self: AccessLevel) []const u8 {
        return @tagName(self);
    }
};

pub const QueryStatus = enum {
    not_attempted,
    ok,
    /// Brak uprawnień — uruchom jako administrator.
    requires_admin,
    /// Magistrala, mostek USB albo sterownik nie obsługują zapytania.
    unsupported,
    /// Zapytanie nie powiodło się — patrz `win32_error`.
    failed,

    pub fn toSlice(self: QueryStatus) []const u8 {
        return @tagName(self);
    }
};

pub const HealthSource = enum {
    none,
    /// IOCTL_STORAGE_QUERY_PROPERTY, ProtocolTypeNvme, log 02h.
    nvme_log_02h,
    /// IOCTL_ATA_PASS_THROUGH, SMART READ DATA / READ THRESHOLDS.
    ata_pass_through,
    /// SMART_RCV_DRIVE_DATA (stary interfejs SMART, fallback).
    smart_rcv_drive_data,

    pub fn toSlice(self: HealthSource) []const u8 {
        return @tagName(self);
    }
};

pub const HealthResult = struct {
    source: HealthSource = .none,
    status: QueryStatus = .not_attempted,
    /// Kod Win32 (albo własny `ERROR_BAD_RESPONSE` / `ERROR_ATA_DEVICE_ERROR`);
    /// 0 przy sukcesie.
    win32_error: u32 = 0,
    access: AccessLevel = .none,
    /// Krótki opis dla użytkownika (statyczny tekst).
    note: []const u8 = "",
};

pub const Disk = struct {
    index: u32,
    path_buf: [32]u8 = undefined,
    path_len: u8 = 0,

    /// Błąd CreateFileW z dostępem 0 (0 = otwarty).
    open_error: u32 = 0,

    descriptor_status: QueryStatus = .not_attempted,
    descriptor_error: u32 = 0,
    descriptor_access: AccessLevel = .none,
    descriptor: ?parse.DeviceDescriptor = null,
    bus: parse.BusType = .unknown,

    size_bytes: ?u64 = null,
    size_source: []const u8 = "",
    size_error: u32 = 0,
    /// Z DEVICE_SEEK_PENALTY_DESCRIPTOR: true = dysk obrotowy (HDD).
    rotational: ?bool = null,

    health: HealthResult = .{},
    nvme: ?parse.NvmeHealth = null,
    ata: ?parse.AtaSmart = null,

    /// Surowe bajty do replay; puste, gdy nie odczytano. Własność listy.
    raw_descriptor: []u8 = &.{},
    raw_nvme_log: []u8 = &.{},
    raw_smart_data: []u8 = &.{},
    raw_smart_thresholds: []u8 = &.{},

    elapsed_ms: f64 = 0,

    pub fn path(self: *const Disk) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Wspólne podsumowanie zdrowia (NVMe albo ATA), jeśli dostępne.
    pub fn summary(self: *const Disk) ?parse.HealthSummary {
        if (self.nvme) |*n| return n.summary;
        if (self.ata) |*a| return a.summary;
        return null;
    }

    fn freeRaw(self: *Disk, alloc: std.mem.Allocator) void {
        inline for (.{ "raw_descriptor", "raw_nvme_log", "raw_smart_data", "raw_smart_thresholds" }) |f| {
            if (@field(self, f).len != 0) alloc.free(@field(self, f));
            @field(self, f) = &.{};
        }
    }
};

pub const DiskList = struct {
    alloc: std.mem.Allocator,
    disks: []Disk,
    total_ms: f64 = 0,

    pub fn deinit(self: *DiskList) void {
        for (self.disks) |*d| d.freeRaw(self.alloc);
        self.alloc.free(self.disks);
        self.disks = &.{};
    }
};

pub const max_disks = 64;
/// Po tylu kolejnych „nie znaleziono" kończymy wyliczanie (numeracja
/// PhysicalDriveN może mieć dziury po odłączonych dyskach).
pub const max_consecutive_missing = 8;

// ---------------------------------------------------------------------------
// Warstwa I/O
// ---------------------------------------------------------------------------

const Io = struct {
    ok: bool,
    bytes: u32,
    err: u32,
};

fn openDisk(path_w: [*:0]const u16, access: DWORD) union(enum) { handle: HANDLE, err: u32 } {
    const h = CreateFileW(path_w, access, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, 0, null);
    if (h == INVALID_HANDLE_VALUE or h == 0) return .{ .err = GetLastError() };
    return .{ .handle = @ptrFromInt(h) };
}

fn ioctl(h: HANDLE, code: u32, in: ?[]const u8, out: []u8) Io {
    var returned: DWORD = 0;
    const ok = DeviceIoControl(
        h,
        code,
        if (in) |i| i.ptr else null,
        if (in) |i| @intCast(i.len) else 0,
        out.ptr,
        @intCast(out.len),
        &returned,
        null,
    );
    if (ok == 0) return .{ .ok = false, .bytes = 0, .err = GetLastError() };
    return .{ .ok = true, .bytes = returned, .err = 0 };
}

fn classify(err: u32) QueryStatus {
    return switch (err) {
        ERROR_ACCESS_DENIED => .requires_admin,
        ERROR_INVALID_FUNCTION,
        ERROR_NOT_SUPPORTED,
        ERROR_INVALID_PARAMETER,
        ERROR_IO_DEVICE,
        ERROR_GEN_FAILURE,
        ERROR_BAD_RESPONSE,
        ERROR_ATA_DEVICE_ERROR,
        => .unsupported,
        else => .failed,
    };
}

// ---------------------------------------------------------------------------
// Zapytania
// ---------------------------------------------------------------------------

fn queryDescriptor(alloc: std.mem.Allocator, h: HANDLE, d: *Disk) !void {
    const q: STORAGE_PROPERTY_QUERY = .{ .PropertyId = StorageDeviceProperty, .QueryType = PropertyStandardQuery };
    var small: [1024]u8 align(8) = undefined;
    var r = ioctl(h, IOCTL_STORAGE_QUERY_PROPERTY, std.mem.asBytes(&q), &small);
    var bytes: []const u8 = small[0..r.bytes];
    var big: []u8 = &.{};
    defer if (big.len != 0) alloc.free(big);

    if (r.ok and r.bytes >= 8) {
        const want = std.mem.readInt(u32, small[4..8], .little);
        if (want > small.len and want <= 64 * 1024) {
            big = try alloc.alloc(u8, want);
            r = ioctl(h, IOCTL_STORAGE_QUERY_PROPERTY, std.mem.asBytes(&q), big);
            bytes = big[0..r.bytes];
        }
    }
    if (!r.ok) {
        d.descriptor_status = classify(r.err);
        d.descriptor_error = r.err;
        return;
    }
    d.raw_descriptor = try alloc.dupe(u8, bytes);
    if (parse.parseDeviceDescriptor(bytes)) |desc| {
        d.descriptor = desc;
        d.bus = desc.bus_type;
        d.descriptor_status = .ok;
    } else |_| {
        d.descriptor_status = .failed;
        d.descriptor_error = ERROR_BAD_RESPONSE;
    }
}

fn querySize(h: HANDLE, d: *Disk) void {
    var geo: [256]u8 align(8) = undefined;
    const r = ioctl(h, IOCTL_DISK_GET_DRIVE_GEOMETRY_EX, null, &geo);
    // DISK_GEOMETRY_EX: DISK_GEOMETRY (24 B) + LARGE_INTEGER DiskSize.
    if (r.ok and r.bytes >= 32) {
        d.size_bytes = std.mem.readInt(u64, geo[24..32], .little);
        d.size_source = "IOCTL_DISK_GET_DRIVE_GEOMETRY_EX DiskSize";
        return;
    }
    d.size_error = r.err;
    // GET_LENGTH_INFO wymaga FILE_READ_ACCESS — z uchwytem 0 zwykle odmowa,
    // ale bywa dostępne przez filtr; próbujemy bez kosztów.
    var len: [8]u8 align(8) = undefined;
    const r2 = ioctl(h, IOCTL_DISK_GET_LENGTH_INFO, null, &len);
    if (r2.ok and r2.bytes >= 8) {
        d.size_bytes = std.mem.readInt(u64, &len, .little);
        d.size_source = "IOCTL_DISK_GET_LENGTH_INFO";
        d.size_error = 0;
    }
}

fn querySeekPenalty(h: HANDLE, d: *Disk) void {
    const q: STORAGE_PROPERTY_QUERY = .{ .PropertyId = StorageDeviceSeekPenaltyProperty, .QueryType = PropertyStandardQuery };
    // DEVICE_SEEK_PENALTY_DESCRIPTOR { Version, Size, BOOLEAN IncursSeekPenalty }.
    var out: [12]u8 align(4) = undefined;
    const r = ioctl(h, IOCTL_STORAGE_QUERY_PROPERTY, std.mem.asBytes(&q), &out);
    if (r.ok and r.bytes >= 9) d.rotational = out[8] != 0;
}

/// Wynik pojedynczej próby odczytu zdrowia.
const Attempt = struct {
    status: QueryStatus,
    err: u32,
};

fn nvmeQuery(h: HANDLE, property_id: u32, out_log: *[parse.nvme_log_size]u8) Attempt {
    var buf: NvmeQueryBuffer = std.mem.zeroes(NvmeQueryBuffer);
    buf.property_id = property_id;
    buf.query_type = PropertyStandardQuery;
    buf.spec = .{
        .ProtocolType = ProtocolTypeNvme,
        .DataType = NVMeDataTypeLogPage,
        .ProtocolDataRequestValue = NVME_LOG_PAGE_HEALTH_INFO,
        .ProtocolDataRequestSubValue = 0,
        .ProtocolDataOffset = @sizeOf(STORAGE_PROTOCOL_SPECIFIC_DATA),
        .ProtocolDataLength = parse.nvme_log_size,
        .FixedProtocolReturnData = 0,
        .ProtocolDataRequestSubValue2 = 0,
        .ProtocolDataRequestSubValue3 = 0,
        .ProtocolDataRequestSubValue4 = 0,
    };
    const bytes = std.mem.asBytes(&buf);
    const r = ioctl(h, IOCTL_STORAGE_QUERY_PROPERTY, bytes, bytes);
    if (!r.ok) return .{ .status = classify(r.err), .err = r.err };

    // Walidacja wg dokumentacji Microsoft "Working with NVMe drives".
    const version = buf.property_id;
    const size = buf.query_type;
    if (version != protocol_data_descriptor_size or size != protocol_data_descriptor_size)
        return .{ .status = .unsupported, .err = ERROR_BAD_RESPONSE };
    const off = buf.spec.ProtocolDataOffset;
    const len = buf.spec.ProtocolDataLength;
    if (off < @sizeOf(STORAGE_PROTOCOL_SPECIFIC_DATA) or len < parse.nvme_log_size)
        return .{ .status = .unsupported, .err = ERROR_BAD_RESPONSE };
    const start: usize = 8 + @as(usize, off);
    if (start + parse.nvme_log_size > bytes.len or start + parse.nvme_log_size > r.bytes)
        return .{ .status = .unsupported, .err = ERROR_BAD_RESPONSE };
    @memcpy(out_log, bytes[start..][0..parse.nvme_log_size]);
    return .{ .status = .ok, .err = 0 };
}

fn nvmeTryHandle(h: HANDLE, log: *[parse.nvme_log_size]u8) Attempt {
    const a = nvmeQuery(h, StorageDeviceProtocolSpecificProperty, log);
    if (a.status == .ok) return a;
    const b = nvmeQuery(h, StorageAdapterProtocolSpecificProperty, log);
    if (b.status == .ok) return b;
    // Odmowa dostępu jest ważniejsza niż „nieobsługiwane" — mówi, co zrobić.
    if (a.status == .requires_admin or b.status == .requires_admin)
        return .{ .status = .requires_admin, .err = ERROR_ACCESS_DENIED };
    return a;
}

fn readNvme(alloc: std.mem.Allocator, h0: HANDLE, path_w: [*:0]const u16, d: *Disk) !void {
    var log: [parse.nvme_log_size]u8 = undefined;
    var access: AccessLevel = .query_only;
    var a = nvmeTryHandle(h0, &log);
    if (a.status == .requires_admin) {
        switch (openDisk(path_w, GENERIC_READ)) {
            .handle => |h| {
                defer _ = CloseHandle(h);
                access = .read;
                a = nvmeTryHandle(h, &log);
            },
            .err => |e| a = .{ .status = classify(e), .err = e },
        }
    }
    d.health = .{ .source = .nvme_log_02h, .status = a.status, .win32_error = a.err, .access = access };
    switch (a.status) {
        .ok => {
            d.raw_nvme_log = try alloc.dupe(u8, &log);
            d.nvme = parse.parseNvmeHealthLog(&log) catch null;
            d.health.note = "NVMe SMART/Health log 02h";
        },
        .requires_admin => d.health.note = "NVMe health log requires administrator",
        .unsupported => d.health.note = "NVMe health log not supported by driver",
        else => d.health.note = "NVMe health log query failed",
    }
}

fn ataSmartCommand(h: HANDLE, feature: u8, out: *[parse.ata_smart_size]u8) Attempt {
    var buf: AtaBuffer = std.mem.zeroes(AtaBuffer);
    buf.apt.Length = @sizeOf(ATA_PASS_THROUGH_EX);
    buf.apt.AtaFlags = ATA_FLAGS_DATA_IN | ATA_FLAGS_DRDY_REQUIRED;
    buf.apt.DataTransferLength = parse.ata_smart_size;
    buf.apt.TimeOutValue = 5;
    buf.apt.DataBufferOffset = @offsetOf(AtaBuffer, "data");
    // Features, SectorCount, LBA low, LBA mid, LBA high, Device, Command.
    buf.apt.CurrentTaskFile = .{ feature, 1, 1, SMART_CYL_LOW, SMART_CYL_HI, 0xA0, ATA_CMD_SMART, 0 };
    std.debug.assert(feature == SMART_READ_DATA or feature == SMART_READ_THRESHOLDS);
    const bytes = std.mem.asBytes(&buf);
    const r = ioctl(h, IOCTL_ATA_PASS_THROUGH, bytes, bytes);
    if (!r.ok) return .{ .status = classify(r.err), .err = r.err };
    const status_reg = buf.apt.CurrentTaskFile[6];
    if (status_reg & 0x01 != 0) return .{ .status = .unsupported, .err = ERROR_ATA_DEVICE_ERROR };
    if (r.bytes < @offsetOf(AtaBuffer, "data") + parse.ata_smart_size or allZero(&buf.data))
        return .{ .status = .unsupported, .err = ERROR_BAD_RESPONSE };
    out.* = buf.data;
    return .{ .status = .ok, .err = 0 };
}

fn smartRcvCommand(h: HANDLE, feature: u8, out: *[parse.ata_smart_size]u8) Attempt {
    std.debug.assert(feature == SMART_READ_DATA or feature == SMART_READ_THRESHOLDS);
    var in: [sendcmd_in_size]u8 = [_]u8{0} ** sendcmd_in_size;
    std.mem.writeInt(u32, in[0..4], parse.ata_smart_size, .little); // cBufferSize
    // IDEREGS: Features, SectorCount, SectorNumber, CylLow, CylHigh, DriveHead, Command.
    in[4] = feature;
    in[5] = 1;
    in[6] = 1;
    in[7] = SMART_CYL_LOW;
    in[8] = SMART_CYL_HI;
    in[9] = 0xA0;
    in[10] = ATA_CMD_SMART;
    in[12] = 0; // bDriveNumber
    var outb: [sendcmd_out_header + parse.ata_smart_size]u8 align(4) = [_]u8{0} ** (sendcmd_out_header + parse.ata_smart_size);
    const r = ioctl(h, SMART_RCV_DRIVE_DATA, &in, &outb);
    if (!r.ok) return .{ .status = classify(r.err), .err = r.err };
    // DRIVERSTATUS: bDriverError, bIDEError.
    if (outb[4] != 0 or outb[5] != 0) return .{ .status = .unsupported, .err = ERROR_ATA_DEVICE_ERROR };
    const data = outb[sendcmd_out_header..][0..parse.ata_smart_size];
    if (r.bytes < outb.len or allZero(data)) return .{ .status = .unsupported, .err = ERROR_BAD_RESPONSE };
    out.* = data.*;
    return .{ .status = .ok, .err = 0 };
}

fn allZero(b: []const u8) bool {
    for (b) |c| if (c != 0) return false;
    return true;
}

fn readAta(alloc: std.mem.Allocator, path_w: [*:0]const u16, d: *Disk) !void {
    d.health = .{ .source = .ata_pass_through };
    const h = switch (openDisk(path_w, GENERIC_READ | GENERIC_WRITE)) {
        .handle => |hh| hh,
        .err => |e| {
            d.health.status = classify(e);
            d.health.win32_error = e;
            d.health.note = if (e == ERROR_ACCESS_DENIED and d.bus == .usb)
                "ATA SMART requires administrator (USB bridges are often unsupported anyway)"
            else if (e == ERROR_ACCESS_DENIED)
                "ATA SMART requires administrator"
            else
                "cannot open disk for ATA SMART";
            return;
        },
    };
    defer _ = CloseHandle(h);
    d.health.access = .read_write;

    var data: [parse.ata_smart_size]u8 = undefined;
    var thr: [parse.ata_smart_size]u8 = undefined;
    var have_thr = false;

    var a = ataSmartCommand(h, SMART_READ_DATA, &data);
    if (a.status == .ok) {
        have_thr = ataSmartCommand(h, SMART_READ_THRESHOLDS, &thr).status == .ok;
    } else {
        const first = a;
        a = smartRcvCommand(h, SMART_READ_DATA, &data);
        if (a.status == .ok) {
            d.health.source = .smart_rcv_drive_data;
            have_thr = smartRcvCommand(h, SMART_READ_THRESHOLDS, &thr).status == .ok;
        } else {
            // Zgłaszamy błąd pierwszej (głównej) ścieżki.
            a = first;
        }
    }

    d.health.status = a.status;
    d.health.win32_error = a.err;
    switch (a.status) {
        .ok => {
            d.raw_smart_data = try alloc.dupe(u8, &data);
            if (have_thr) d.raw_smart_thresholds = try alloc.dupe(u8, &thr);
            d.ata = parse.parseAtaSmart(&data, if (have_thr) &thr else null, .{ .rotational = d.rotational }) catch null;
            d.health.note = if (have_thr) "ATA SMART data + thresholds" else "ATA SMART data (thresholds unavailable)";
        },
        .requires_admin => d.health.note = "ATA SMART requires administrator",
        .unsupported => d.health.note = if (d.bus == .usb)
            "SMART not supported by bus/bridge"
        else
            "ATA SMART not supported by device/driver",
        else => d.health.note = "ATA SMART query failed",
    }
}

fn probeDisk(alloc: std.mem.Allocator, index: u32, d: *Disk) !bool {
    const t0 = std.time.nanoTimestamp();
    defer d.elapsed_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1e6;

    const p = std.fmt.bufPrint(&d.path_buf, "\\\\.\\PhysicalDrive{d}", .{index}) catch unreachable;
    d.path_len = @intCast(p.len);
    var path_w: [40:0]u16 = undefined;
    for (p, 0..) |c, i| path_w[i] = c;
    path_w[p.len] = 0;
    const pw: [*:0]const u16 = @ptrCast(&path_w);

    const h0 = switch (openDisk(pw, 0)) {
        .handle => |h| h,
        .err => |e| {
            d.open_error = e;
            return !(e == ERROR_FILE_NOT_FOUND or e == ERROR_PATH_NOT_FOUND);
        },
    };
    defer _ = CloseHandle(h0);

    d.descriptor_access = .query_only;
    try queryDescriptor(alloc, h0, d);
    querySize(h0, d);
    querySeekPenalty(h0, d);

    switch (d.bus) {
        .nvme => try readNvme(alloc, h0, pw, d),
        .sata, .ata => try readAta(alloc, pw, d),
        .usb => try readAta(alloc, pw, d),
        .scsi, .raid, .sas, .unknown => {
            // Dyski za kontrolerem RAID/SCSI (np. Intel RST) mogą być NVMe
            // albo SATA — najpierw zapytanie bez uprawnień, potem ATA.
            try readNvme(alloc, h0, pw, d);
            if (d.health.status != .ok) {
                const nvme_health = d.health;
                try readAta(alloc, pw, d);
                if (d.health.status == .unsupported and nvme_health.status == .requires_admin) d.health = nvme_health;
            }
        },
        else => d.health = .{ .status = .unsupported, .note = "health data not available for this bus type" },
    }
    return true;
}

/// Wylicza `\\.\PhysicalDrive0..63`, kończy po `max_consecutive_missing`
/// kolejnych nieistniejących numerach. Zwraca błąd wyłącznie przy braku
/// pamięci; błędy poszczególnych dysków są w ich wynikach.
pub fn enumerate(alloc: std.mem.Allocator) !DiskList {
    const t0 = std.time.nanoTimestamp();
    var list: std.ArrayList(Disk) = .empty;
    errdefer {
        for (list.items) |*d| d.freeRaw(alloc);
        list.deinit(alloc);
    }
    var missing: u32 = 0;
    var i: u32 = 0;
    while (i < max_disks and missing < max_consecutive_missing) : (i += 1) {
        var d: Disk = .{ .index = i };
        const exists = probeDisk(alloc, i, &d) catch |e| {
            d.freeRaw(alloc);
            return e;
        };
        if (!exists) {
            missing += 1;
            continue;
        }
        missing = 0;
        list.append(alloc, d) catch |e| {
            d.freeRaw(alloc);
            return e;
        };
    }
    return .{
        .alloc = alloc,
        .disks = try list.toOwnedSlice(alloc),
        .total_ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1e6,
    };
}

// ---------------------------------------------------------------------------
// Testy
// ---------------------------------------------------------------------------

test "classify win32 errors" {
    try std.testing.expectEqual(QueryStatus.requires_admin, classify(ERROR_ACCESS_DENIED));
    try std.testing.expectEqual(QueryStatus.unsupported, classify(ERROR_NOT_SUPPORTED));
    try std.testing.expectEqual(QueryStatus.unsupported, classify(ERROR_INVALID_FUNCTION));
    try std.testing.expectEqual(QueryStatus.failed, classify(ERROR_NOT_READY));
}

test "enumerate runs and frees (read-only IOCTLs)" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var list = try enumerate(std.testing.allocator);
    defer list.deinit();
    for (list.disks) |*d| {
        try std.testing.expect(d.path().len > 0);
        if (d.health.status == .ok) try std.testing.expect(d.summary() != null);
    }
}
