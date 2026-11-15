//! Zbieranie surowych danych o urządzeniach na Windows — bez sterownika,
//! bez WMI, bez uprawnień administratora:
//!
//! * SMBIOS: `GetSystemFirmwareTable('RSMB')` — cały bufor RawSMBIOSData.
//! * PCI: SetupAPI (`SetupDiGetClassDevsW("PCI")`) + właściwości urządzeń
//!   (`SetupDiGetDevicePropertyW`): identyfikatory z Hardware ID, lokalizacja
//!   bus/dev/func, klasa PCI, wersja i data sterownika, łącze PCIe.
//!   Klucze DEVPKEY: `devpkey.h` i `pciprop.h` z Windows SDK 10.0.26100.
//! * Karty graficzne: DXGI (`CreateDXGIFactory1` → `IDXGIAdapter1::GetDesc1`):
//!   nazwa ze sterownika, VID/DID/SUBSYS/REV, pamięć dedykowana i współdzielona.
//!
//! Wszystko trafia do `snapshot.Snapshot` jako dane **surowe**; nazwy z pci.ids
//! i interpretacja dzieją się później, wspólnie z replay.

const std = @import("std");
const snap = @import("../snapshot.zig");

const BOOL = i32;
const DWORD = u32;
const HDEVINFO = ?*anyopaque;
const HRESULT = i32;

pub const GUID = extern struct {
    d1: u32,
    d2: u16,
    d3: u16,
    d4: [8]u8,
};

const DEVPROPKEY = extern struct {
    fmtid: GUID,
    pid: u32,
};

const SP_DEVINFO_DATA = extern struct {
    cbSize: DWORD = @sizeOf(SP_DEVINFO_DATA),
    ClassGuid: GUID = std.mem.zeroes(GUID),
    DevInst: DWORD = 0,
    Reserved: usize = 0,
};

const FILETIME = extern struct { low: u32, high: u32 };
const SYSTEMTIME = extern struct { year: u16, month: u16, dow: u16, day: u16, hour: u16, minute: u16, second: u16, ms: u16 };

const DIGCF_PRESENT: DWORD = 0x2;
const DIGCF_ALLCLASSES: DWORD = 0x4;

extern "setupapi" fn SetupDiGetClassDevsW(class: ?*const GUID, enumerator: ?[*:0]const u16, parent: ?*anyopaque, flags: DWORD) callconv(.winapi) HDEVINFO;
extern "setupapi" fn SetupDiEnumDeviceInfo(set: HDEVINFO, index: DWORD, data: *SP_DEVINFO_DATA) callconv(.winapi) BOOL;
extern "setupapi" fn SetupDiGetDevicePropertyW(set: HDEVINFO, data: *SP_DEVINFO_DATA, key: *const DEVPROPKEY, ptype: *u32, buf: ?[*]u8, size: DWORD, req: ?*DWORD, flags: DWORD) callconv(.winapi) BOOL;
extern "setupapi" fn SetupDiDestroyDeviceInfoList(set: HDEVINFO) callconv(.winapi) BOOL;
extern "kernel32" fn GetSystemFirmwareTable(sig: DWORD, id: DWORD, buf: ?[*]u8, size: DWORD) callconv(.winapi) u32;
extern "kernel32" fn FileTimeToSystemTime(ft: *const FILETIME, st: *SYSTEMTIME) callconv(.winapi) BOOL;
extern "dxgi" fn CreateDXGIFactory1(riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;
extern "shell32" fn IsUserAnAdmin() callconv(.winapi) BOOL;

const dev_guid = GUID{ .d1 = 0xa45c254e, .d2 = 0xdf1c, .d3 = 0x4efd, .d4 = .{ 0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0 } };
const drv_guid = GUID{ .d1 = 0xa8b865dd, .d2 = 0x2e3d, .d3 = 0x4094, .d4 = .{ 0xad, 0x97, 0xe5, 0x93, 0xa7, 0x0c, 0x75, 0xd6 } };
const pci_guid = GUID{ .d1 = 0x3ab22e31, .d2 = 0x8264, .d3 = 0x4b4e, .d4 = .{ 0x9a, 0xf5, 0xa8, 0xd2, 0xd8, 0xe3, 0x3e, 0x62 } };

const KEY_DeviceDesc = DEVPROPKEY{ .fmtid = dev_guid, .pid = 2 };
const KEY_HardwareIds = DEVPROPKEY{ .fmtid = dev_guid, .pid = 3 };
const KEY_FriendlyName = DEVPROPKEY{ .fmtid = dev_guid, .pid = 14 };
const KEY_BusNumber = DEVPROPKEY{ .fmtid = dev_guid, .pid = 23 };
const KEY_Address = DEVPROPKEY{ .fmtid = dev_guid, .pid = 30 };
const KEY_DriverDate = DEVPROPKEY{ .fmtid = drv_guid, .pid = 2 };
const KEY_DriverVersion = DEVPROPKEY{ .fmtid = drv_guid, .pid = 3 };
const KEY_DriverProvider = DEVPROPKEY{ .fmtid = drv_guid, .pid = 9 };
const KEY_BaseClass = DEVPROPKEY{ .fmtid = pci_guid, .pid = 3 };
const KEY_SubClass = DEVPROPKEY{ .fmtid = pci_guid, .pid = 4 };
const KEY_ProgIf = DEVPROPKEY{ .fmtid = pci_guid, .pid = 5 };
const KEY_CurLinkSpeed = DEVPROPKEY{ .fmtid = pci_guid, .pid = 9 };
const KEY_CurLinkWidth = DEVPROPKEY{ .fmtid = pci_guid, .pid = 10 };
const KEY_MaxLinkSpeed = DEVPROPKEY{ .fmtid = pci_guid, .pid = 11 };
const KEY_MaxLinkWidth = DEVPROPKEY{ .fmtid = pci_guid, .pid = 12 };

comptime {
    std.debug.assert(@sizeOf(SP_DEVINFO_DATA) == 32);
    std.debug.assert(@sizeOf(DEVPROPKEY) == 20);
}

pub fn isAdmin() bool {
    return IsUserAnAdmin() != 0;
}

// ---------------------------------------------------------------------------
// SMBIOS
// ---------------------------------------------------------------------------

pub fn readSmbios(alloc: std.mem.Allocator) ?[]u8 {
    const rsmb: DWORD = ('R' << 24) | ('S' << 16) | ('M' << 8) | 'B';
    const need = GetSystemFirmwareTable(rsmb, 0, null, 0);
    if (need == 0 or need > 16 * 1024 * 1024) return null;
    const buf = alloc.alloc(u8, need) catch return null;
    const got = GetSystemFirmwareTable(rsmb, 0, buf.ptr, need);
    if (got == 0 or got > need) {
        alloc.free(buf);
        return null;
    }
    return buf[0..got];
}

// ---------------------------------------------------------------------------
// PCI przez SetupAPI
// ---------------------------------------------------------------------------

fn prop(set: HDEVINFO, data: *SP_DEVINFO_DATA, key: *const DEVPROPKEY, buf: []u8) ?[]u8 {
    var ptype: u32 = 0;
    var req: DWORD = 0;
    if (SetupDiGetDevicePropertyW(set, data, key, &ptype, buf.ptr, @intCast(buf.len), &req, 0) == 0) return null;
    return buf[0..@min(req, buf.len)];
}

fn propU32(set: HDEVINFO, data: *SP_DEVINFO_DATA, key: *const DEVPROPKEY) ?u32 {
    var b: [8]u8 align(4) = undefined;
    const v = prop(set, data, key, &b) orelse return null;
    if (v.len == 4) return std.mem.readInt(u32, v[0..4], .little);
    if (v.len == 1) return v[0];
    if (v.len == 2) return std.mem.readInt(u16, v[0..2], .little);
    return null;
}

/// Pierwszy napis UTF-16 z właściwości (string albo string list) jako UTF-8.
fn propStr(alloc: std.mem.Allocator, set: HDEVINFO, data: *SP_DEVINFO_DATA, key: *const DEVPROPKEY) []const u8 {
    var b: [2048]u8 align(2) = undefined;
    const v = prop(set, data, key, &b) orelse return "";
    const w16: []const u16 = @as([*]const u16, @ptrCast(@alignCast(v.ptr)))[0 .. v.len / 2];
    const end = std.mem.indexOfScalar(u16, w16, 0) orelse w16.len;
    return std.unicode.utf16LeToUtf8Alloc(alloc, w16[0..end]) catch "";
}

/// Cała lista napisów (REG_MULTI_SZ / DEVPROP_TYPE_STRING_LIST) jako UTF-8,
/// elementy rozdzielone `|`.
fn propList(alloc: std.mem.Allocator, set: HDEVINFO, data: *SP_DEVINFO_DATA, key: *const DEVPROPKEY) []const u8 {
    var b: [4096]u8 align(2) = undefined;
    const v = prop(set, data, key, &b) orelse return "";
    var w16: []u16 = @as([*]u16, @ptrCast(@alignCast(v.ptr)))[0 .. v.len / 2];
    while (w16.len > 0 and w16[w16.len - 1] == 0) w16 = w16[0 .. w16.len - 1];
    for (w16) |*c| {
        if (c.* == 0) c.* = '|';
    }
    return std.unicode.utf16LeToUtf8Alloc(alloc, w16) catch "";
}

fn propDate(alloc: std.mem.Allocator, set: HDEVINFO, data: *SP_DEVINFO_DATA) []const u8 {
    var b: [8]u8 align(4) = undefined;
    const v = prop(set, data, &KEY_DriverDate, &b) orelse return "";
    if (v.len != 8) return "";
    const ft = FILETIME{ .low = std.mem.readInt(u32, v[0..4], .little), .high = std.mem.readInt(u32, v[4..8], .little) };
    var st: SYSTEMTIME = undefined;
    if (FileTimeToSystemTime(&ft, &st) == 0) return "";
    return std.fmt.allocPrint(alloc, "{d:0>4}-{d:0>2}-{d:0>2}", .{ st.year, st.month, st.day }) catch "";
}

/// `PCI\VEN_1002&DEV_744C&SUBSYS_53041849&REV_C8` → identyfikatory.
pub fn parseHardwareId(id: []const u8, out: *snap.PciDevice) bool {
    const ven = hexAfter(id, "VEN_", 4) orelse return false;
    const dev = hexAfter(id, "DEV_", 4) orelse return false;
    out.vendor = @intCast(ven);
    out.device = @intCast(dev);
    if (hexAfter(id, "SUBSYS_", 8)) |ss| {
        out.subdevice = @intCast(ss >> 16);
        out.subvendor = @intCast(ss & 0xFFFF);
    }
    if (hexAfter(id, "REV_", 2)) |r| out.revision = @intCast(r);
    return true;
}

fn hexAfter(s: []const u8, tag: []const u8, n: usize) ?u32 {
    const i = std.ascii.indexOfIgnoreCase(s, tag) orelse return null;
    const start = i + tag.len;
    if (start + n > s.len) return null;
    return std.fmt.parseInt(u32, s[start .. start + n], 16) catch null;
}

pub fn enumeratePci(alloc: std.mem.Allocator) ![]snap.PciDevice {
    const set = SetupDiGetClassDevsW(null, std.unicode.utf8ToUtf16LeStringLiteral("PCI"), null, DIGCF_ALLCLASSES | DIGCF_PRESENT);
    if (set == null or @intFromPtr(set) == std.math.maxInt(usize)) return error.SetupApiFailed;
    defer _ = SetupDiDestroyDeviceInfoList(set);

    var list: std.ArrayList(snap.PciDevice) = .empty;
    var i: DWORD = 0;
    while (i < 4096) : (i += 1) {
        var data: SP_DEVINFO_DATA = .{};
        if (SetupDiEnumDeviceInfo(set, i, &data) == 0) break;
        var d: snap.PciDevice = .{};
        const hwids = propList(alloc, set, &data, &KEY_HardwareIds);
        if (!parseHardwareId(hwids, &d)) continue;
        // Klasa z Hardware ID (`CC_ccssppp`), gdy właściwości PCI jej nie podają
        // (np. mostki hosta nie są urządzeniami PCIe z rejestrem łącza).
        if (hexAfter(hwids, "CC_", 6)) |cc| {
            d.class = @truncate(cc >> 16);
            d.subclass = @truncate(cc >> 8);
            d.progif = @truncate(cc);
        } else if (hexAfter(hwids, "CC_", 4)) |cc| {
            d.class = @truncate(cc >> 8);
            d.subclass = @truncate(cc);
        }
        if (propU32(set, &data, &KEY_BusNumber)) |bus| {
            if (propU32(set, &data, &KEY_Address)) |addr| {
                d.bus = bus;
                d.dev = addr >> 16;
                d.func = addr & 0xFFFF;
                d.location_valid = true;
            }
        }
        if (d.class == null) {
            if (propU32(set, &data, &KEY_BaseClass)) |c| d.class = @truncate(c);
            if (propU32(set, &data, &KEY_SubClass)) |c| d.subclass = @truncate(c);
            if (propU32(set, &data, &KEY_ProgIf)) |c| d.progif = @truncate(c);
        }
        d.desc = propStr(alloc, set, &data, &KEY_FriendlyName);
        if (d.desc.len == 0) d.desc = propStr(alloc, set, &data, &KEY_DeviceDesc);
        d.driver_version = propStr(alloc, set, &data, &KEY_DriverVersion);
        d.driver_provider = propStr(alloc, set, &data, &KEY_DriverProvider);
        d.driver_date = propDate(alloc, set, &data);
        d.link_cur_speed = propU32(set, &data, &KEY_CurLinkSpeed);
        d.link_cur_width = propU32(set, &data, &KEY_CurLinkWidth);
        d.link_max_speed = propU32(set, &data, &KEY_MaxLinkSpeed);
        d.link_max_width = propU32(set, &data, &KEY_MaxLinkWidth);
        try list.append(alloc, d);
    }
    // Kolejność jak w drzewie PCI — stabilna między uruchomieniami i w raporcie.
    std.mem.sort(snap.PciDevice, list.items, {}, struct {
        fn lt(_: void, a: snap.PciDevice, b: snap.PciDevice) bool {
            if (a.bus != b.bus) return a.bus < b.bus;
            if (a.dev != b.dev) return a.dev < b.dev;
            return a.func < b.func;
        }
    }.lt);
    return list.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// DXGI
// ---------------------------------------------------------------------------

const IID_IDXGIFactory1 = GUID{ .d1 = 0x770aae78, .d2 = 0xf26f, .d3 = 0x4dba, .d4 = .{ 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 } };

const DXGI_ADAPTER_DESC1 = extern struct {
    Description: [128]u16,
    VendorId: u32,
    DeviceId: u32,
    SubSysId: u32,
    Revision: u32,
    DedicatedVideoMemory: usize,
    DedicatedSystemMemory: usize,
    SharedSystemMemory: usize,
    AdapterLuid: extern struct { low: u32, high: i32 },
    Flags: u32,
};

/// Obiekt COM: pierwszym polem jest wskaźnik na tablicę metod.
const ComObj = extern struct { vtbl: [*]const *const anyopaque };

fn comRelease(o: *ComObj) void {
    const f: *const fn (*ComObj) callconv(.winapi) u32 = @ptrCast(o.vtbl[2]);
    _ = f(o);
}

pub fn enumerateGpus(alloc: std.mem.Allocator) ![]snap.GpuAdapter {
    var factory_ptr: ?*anyopaque = null;
    if (CreateDXGIFactory1(&IID_IDXGIFactory1, &factory_ptr) < 0 or factory_ptr == null) return error.DxgiFailed;
    const factory: *ComObj = @ptrCast(@alignCast(factory_ptr.?));
    defer comRelease(factory);
    // IDXGIFactory1 vtable: IUnknown(3) + IDXGIObject(4) + IDXGIFactory(5) → EnumAdapters1 = 12.
    const enum1: *const fn (*ComObj, u32, *?*anyopaque) callconv(.winapi) HRESULT = @ptrCast(factory.vtbl[12]);

    var list: std.ArrayList(snap.GpuAdapter) = .empty;
    var i: u32 = 0;
    while (i < 16) : (i += 1) {
        var ad_ptr: ?*anyopaque = null;
        if (enum1(factory, i, &ad_ptr) < 0 or ad_ptr == null) break;
        const ad: *ComObj = @ptrCast(@alignCast(ad_ptr.?));
        defer comRelease(ad);
        // IDXGIAdapter1 vtable: IUnknown(3) + IDXGIObject(4) + IDXGIAdapter(3) → GetDesc1 = 10.
        const getdesc1: *const fn (*ComObj, *DXGI_ADAPTER_DESC1) callconv(.winapi) HRESULT = @ptrCast(ad.vtbl[10]);
        var d: DXGI_ADAPTER_DESC1 = undefined;
        if (getdesc1(ad, &d) < 0) continue;
        const end = std.mem.indexOfScalar(u16, &d.Description, 0) orelse d.Description.len;
        // DXGI potrafi zwrócić ten sam układ dwa razy (np. osobne LUID dla
        // dodatkowego wyjścia). Ta sama karta = te same ID i ta sama pamięć.
        var dup = false;
        for (list.items) |x| {
            if (x.vendor == d.VendorId and x.device == d.DeviceId and x.subsys == d.SubSysId and
                x.dedicated_vram == d.DedicatedVideoMemory) dup = true;
        }
        if (dup) continue;
        try list.append(alloc, .{
            .name = std.unicode.utf16LeToUtf8Alloc(alloc, d.Description[0..end]) catch "",
            .vendor = @truncate(d.VendorId),
            .device = @truncate(d.DeviceId),
            .subsys = d.SubSysId,
            .revision = @truncate(d.Revision),
            .dedicated_vram = d.DedicatedVideoMemory,
            .dedicated_sys = d.DedicatedSystemMemory,
            .shared_sys = d.SharedSystemMemory,
            // DXGI_ADAPTER_FLAG_SOFTWARE = 2 (Microsoft Basic Render Driver).
            .software = (d.Flags & 2) != 0,
        });
    }
    return list.toOwnedSlice(alloc);
}

test "devices: Hardware ID PCI" {
    var d: snap.PciDevice = .{};
    try std.testing.expect(parseHardwareId("PCI\\VEN_1002&DEV_744C&SUBSYS_53041849&REV_C8", &d));
    try std.testing.expectEqual(@as(u16, 0x1002), d.vendor);
    try std.testing.expectEqual(@as(u16, 0x744C), d.device);
    try std.testing.expectEqual(@as(u16, 0x1849), d.subvendor);
    try std.testing.expectEqual(@as(u16, 0x5304), d.subdevice);
    try std.testing.expectEqual(@as(u8, 0xC8), d.revision);
    var e: snap.PciDevice = .{};
    try std.testing.expect(!parseHardwareId("ROOT\\DISPLAY\\0000", &e));
    try std.testing.expect(parseHardwareId("PCI\\VEN_8086&DEV_A780", &e));
    try std.testing.expectEqual(@as(u16, 0), e.subvendor);
}
