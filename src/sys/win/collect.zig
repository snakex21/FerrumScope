//! Zebranie pełnej migawki `Snapshot` na Windows (bez sterownika).
//!
//! Każde źródło jest niezależne: błąd jednego (np. brak SMBIOS w maszynie
//! wirtualnej) nie zatrzymuje pozostałych, a stan trafia do `*_status`.

const std = @import("std");
const snap = @import("../snapshot.zig");
const devices = @import("devices.zig");
const storage = @import("storage.zig");

pub const Options = struct {
    /// Odpytywać dyski (SMART). Wyłączane w testach i przy szybkim starcie.
    disks: bool = true,
};

pub fn collect(arena: std.mem.Allocator, opts: Options) snap.Snapshot {
    var s: snap.Snapshot = .{};
    s.is_admin = devices.isAdmin();

    if (devices.readSmbios(arena)) |buf| {
        s.smbios = buf;
        s.smbios_status = .ok;
    } else s.smbios_status = .unavailable;

    if (devices.enumeratePci(arena)) |list| {
        s.pci = list;
        s.pci_status = .ok;
    } else |_| s.pci_status = .failed;

    if (devices.enumerateGpus(arena)) |list| {
        s.gpus = list;
        s.gpu_status = .ok;
    } else |_| s.gpu_status = .failed;

    if (opts.disks) {
        if (storage.enumerate(arena)) |dl| {
            var out: std.ArrayList(snap.DiskRaw) = .empty;
            for (dl.disks) |*d| {
                var r: snap.DiskRaw = .{
                    .index = d.index,
                    .size_bytes = d.size_bytes,
                    .descriptor = arena.dupe(u8, d.raw_descriptor) catch "",
                    .rotational = d.rotational,
                    .health_note = d.health.note,
                    .health_error = d.health.win32_error,
                };
                if (d.raw_nvme_log.len > 0) r.nvme_log = arena.dupe(u8, d.raw_nvme_log) catch null;
                if (d.raw_smart_data.len > 0) r.ata_smart = arena.dupe(u8, d.raw_smart_data) catch null;
                if (d.raw_smart_thresholds.len > 0) r.ata_thresholds = arena.dupe(u8, d.raw_smart_thresholds) catch null;
                r.health = switch (d.health.status) {
                    .ok => .ok,
                    .requires_admin => .requires_admin,
                    .unsupported => .unsupported,
                    .failed => .failed,
                    .not_attempted => .unavailable,
                };
                r.health_source = switch (d.health.source) {
                    .none => "",
                    .nvme_log_02h => "NVMe log 02h (StorageDeviceProtocolSpecificProperty)",
                    .ata_pass_through => "ATA SMART READ DATA (IOCTL_ATA_PASS_THROUGH)",
                    .smart_rcv_drive_data => "ATA SMART (SMART_RCV_DRIVE_DATA)",
                };
                out.append(arena, r) catch {};
            }
            s.disks = out.items;
            s.disk_status = .ok;
            // Surowe bufory skopiowaliśmy do areny — lista z backendu nie jest potrzebna.
            var dl_mut = dl;
            dl_mut.deinit();
        } else |_| s.disk_status = .failed;
    }
    return s;
}
