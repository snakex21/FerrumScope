//! Migawka systemu — **surowe** dane zebrane z platformy (albo z pliku
//! `.sysimg`), niezależne od systemu operacyjnego.
//!
//! Zasada FerrumScope: platforma zbiera bajty i identyfikatory, a interpretacja
//! (SMBIOS, nazwy z pci.ids, SMART) dzieje się w modułach `sys/*` i `sys/pages`
//! wspólnie dla odczytu na żywo i dla replay. Dzięki temu dekodery są testowane
//! na plikach capture bez sprzętu.

const std = @import("std");
const i18n = @import("../i18n/i18n.zig");

pub const Collect = enum {
    ok,
    unavailable,
    requires_admin,
    unsupported,
    failed,

    pub fn label(self: Collect) []const u8 {
        return switch (self) {
            .ok => i18n.t("ok"),
            .unavailable => i18n.t("niedostępne"),
            .requires_admin => i18n.t("wymaga administratora"),
            .unsupported => i18n.t("nieobsługiwane"),
            .failed => i18n.t("błąd odczytu"),
        };
    }
};

pub const PciDevice = struct {
    bus: u32 = 0,
    dev: u32 = 0,
    func: u32 = 0,
    location_valid: bool = false,
    vendor: u16 = 0,
    device: u16 = 0,
    subvendor: u16 = 0,
    subdevice: u16 = 0,
    revision: u8 = 0,
    class: ?u8 = null,
    subclass: ?u8 = null,
    progif: ?u8 = null,
    /// Opis urządzenia z systemu (INF sterownika), nie z pci.ids.
    desc: []const u8 = "",
    driver_version: []const u8 = "",
    /// `RRRR-MM-DD` (z FILETIME DEVPKEY_Device_DriverDate).
    driver_date: []const u8 = "",
    driver_provider: []const u8 = "",
    /// Kodowanie rejestru PCIe Link Status: 1 = 2.5 GT/s, 2 = 5, 3 = 8, 4 = 16, 5 = 32, 6 = 64.
    link_cur_speed: ?u32 = null,
    link_cur_width: ?u32 = null,
    link_max_speed: ?u32 = null,
    link_max_width: ?u32 = null,
};

pub const GpuAdapter = struct {
    /// `DXGI_ADAPTER_DESC1.Description` — tekst sterownika.
    name: []const u8 = "",
    vendor: u16 = 0,
    device: u16 = 0,
    /// `SubSysId` = (subsystem device << 16) | subsystem vendor.
    subsys: u32 = 0,
    revision: u8 = 0,
    dedicated_vram: u64 = 0,
    dedicated_sys: u64 = 0,
    shared_sys: u64 = 0,
    software: bool = false,

    pub fn subVendor(self: GpuAdapter) u16 {
        return @truncate(self.subsys);
    }
    pub fn subDevice(self: GpuAdapter) u16 {
        return @truncate(self.subsys >> 16);
    }
};

pub const DiskRaw = struct {
    index: u32 = 0,
    size_bytes: ?u64 = null,
    /// Bajty STORAGE_DEVICE_DESCRIPTOR (numer seryjny może być zamaskowany).
    descriptor: []const u8 = "",
    nvme_log: ?[]const u8 = null,
    ata_smart: ?[]const u8 = null,
    ata_thresholds: ?[]const u8 = null,
    health: Collect = .unavailable,
    /// Kod błędu Win32 przy `health = failed` (0 = brak).
    health_error: u32 = 0,
    health_note: []const u8 = "",
    /// Źródło zdrowia: "NVMe log 02h", "ATA SMART (pass-through)" itd.
    health_source: []const u8 = "",
    /// Podpowiedź HDD/SSD z IOCTL_STORAGE_QUERY_PROPERTY (seek penalty).
    rotational: ?bool = null,
};

pub const Snapshot = struct {
    /// Bufor `RawSMBIOSData` (GetSystemFirmwareTable 'RSMB').
    smbios: ?[]const u8 = null,
    smbios_status: Collect = .unavailable,
    pci: []const PciDevice = &.{},
    pci_status: Collect = .unavailable,
    gpus: []const GpuAdapter = &.{},
    gpu_status: Collect = .unavailable,
    disks: []const DiskRaw = &.{},
    disk_status: Collect = .unavailable,
    /// Czy dane pochodzą z pliku (replay), a nie z tej maszyny.
    replay_source: ?[]const u8 = null,
    /// Czy numery seryjne zostały zamaskowane przy capture.
    serials_masked: bool = false,
    is_admin: bool = false,

    pub fn findPci(self: *const Snapshot, vendor: u16, device: u16, subsys: u32) ?*const PciDevice {
        var fallback: ?*const PciDevice = null;
        for (self.pci) |*p| {
            if (p.vendor != vendor or p.device != device) continue;
            const ss = (@as(u32, p.subdevice) << 16) | p.subvendor;
            if (ss == subsys) return p;
            if (fallback == null) fallback = p;
        }
        return fallback;
    }
};

/// Prędkość łącza PCIe z kodowania Link Status na tekst.
pub fn linkSpeedLabel(code: u32) []const u8 {
    return switch (code) {
        1 => "2.5 GT/s (PCIe 1.x)",
        2 => "5 GT/s (PCIe 2.0)",
        3 => "8 GT/s (PCIe 3.0)",
        4 => "16 GT/s (PCIe 4.0)",
        5 => "32 GT/s (PCIe 5.0)",
        6 => "64 GT/s (PCIe 6.0)",
        else => i18n.t("nieznane kodowanie"),
    };
}

test "snapshot: findPci preferuje zgodny subsystem" {
    const devs = [_]PciDevice{
        .{ .vendor = 0x1002, .device = 0x744C, .subvendor = 0x1111, .subdevice = 0x2222 },
        .{ .vendor = 0x1002, .device = 0x744C, .subvendor = 0x1849, .subdevice = 0x5304 },
    };
    const s = Snapshot{ .pci = &devs };
    const p = s.findPci(0x1002, 0x744C, 0x53041849).?;
    try std.testing.expectEqual(@as(u16, 0x1849), p.subvendor);
    try std.testing.expect(s.findPci(0x10DE, 1, 0) == null);
    try std.testing.expectEqualStrings("16 GT/s (PCIe 4.0)", linkSpeedLabel(4));
}
