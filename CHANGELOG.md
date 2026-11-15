# Changelog

All notable changes to FerrumScope. Format based on [Keep a Changelog](https://keepachangelog.com/).

## [0.2.0-dev] — 2026-11-15

### Added
- **Driverless system information** (Windows): mainboard and BIOS (SMBIOS), chipset from PCI IDs, memory modules (SMBIOS type 17), graphics adapters (DXGI + SetupAPI: IDs, driver version/date, memory, PCIe link), storage (descriptor, size, NVMe health log, SATA SMART as administrator).
- **CPU**: clock estimate and per-core/total load without the driver, full instruction-set list with CPUID provenance and x86-64 level, caches shown as `8 x 32 KB`, bus clock (SMBIOS) and estimated multiplier.
- **GPU telemetry**: optional, read-only AMD ADL (OD8/OverdriveN/Overdrive5) and NVIDIA NVAPI loaders (NVAPI not verified on NVIDIA hardware).
- **pci.ids** compiled into the program at build time (`tools/pciids_compile.zig`).
- **Report export** TXT/HTML/JSON with serial numbers masked by default; CLI `report`, `board`, `memory`, `gpu`, `storage`, `sensors-all`.
- **`.sysimg` capture/replay** for SMBIOS/PCI/GPU/disk raw data (`capture-sys`, `--sys-replay`), with serial masking; a masked fixture of a real machine drives regression tests.
- **GUI**: CPU-Z-style structured view (group boxes, compact read-only fields, instance selectors) and a full list view (`Ctrl+L`, remembered); source/confidence tooltips and markers; lookup and driver buttons; export buttons; CPU/GPU badge with user images (`data\images\`), bundled vendor logos (`assets/logos/`, outside GPL) or a self-drawn badge.
- `tools/uia_select_tab.zig` + `tools/gui_screenshots.ps1` for reproducible screenshots via UI Automation and PrintWindow.
- `LICENSE` (GPL-3.0), `NOTICE.md`, bilingual README.

### Changed
- **AMD HWDB** re-verified against AMD Revision Guides (56683, 58251), Linux `amd.c` model ranges and public CPUID dumps: Family 19h 20h–2Fh is *Vermeer*, 00h–0Fh *Milan / Milan-X*; Zen 5 moved to Family 1Ah; Family 17h/15h/16h ranges and Hygon (Family 18h) fixed.
- The CPU-Z–sourced `VMR-B2` stepping name replaced with `Vermeer-B2`, derived from AMD's documented revision naming (vendor_doc_adjacent); Milan B1/B2 added from AMD documentation.
- `tools/fetch_zig.py` verifies the SHA-256 of the pinned Zig 0.15.2 archive.
- Serial numbers are now fully masked (no partial characters).

### Fixed (driver, compiled only — not installed or loaded)
- `DriverUnload` deletes the device object.
- Device created with `IoCreateDeviceSecure` and an admin-only SDDL `D:P(A;;GA;;;SY)(A;;GA;;;BA)`.
- CPU index → processor group mapping via `KeGetProcessorNumberFromIndex`.

### Removed
- Scratch file `tools/_iso.zig`; outdated GUI screenshots.

## [0.1.0-dev] — 2026-10-15
- CPU identification (CPUID + HWDB), `.cpuimg` capture/replay, MSR telemetry foundation, read-only MSR driver sources, first Win32 GUI (CPU and Sensors tabs).
