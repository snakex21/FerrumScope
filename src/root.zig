//! Korzeń biblioteki FerrumScope — jeden punkt wejścia dla wszystkich warstw.
//!
//! Używamy go z trzech miejsc:
//!   * `src/cli/main.zig`      — program
//!   * `src/tests/all.zig`     — testy
//!   * `tools/hwdb_compile.zig` — kompilator bazy (build step)
//!
//! Dzięki wspólnemu korzeniowi kompilator bazy używa **tych samych** struktur
//! co runtime. Gdyby format wpisu zmienił się w `db/hwdb.zig`, kompilator
//! przestanie się kompilować — zamiast po cichu generować bazę w złym formacie.

pub const core = struct {
    pub const status = @import("core/status.zig");
    pub const ids = @import("core/ids.zig");
    pub const raw = @import("core/raw.zig");
    pub const model = @import("core/model.zig");
};

pub const arch = struct {
    pub const x86 = struct {
        pub const cpuid = @import("arch/x86/cpuid.zig");
    };
};

pub const bus = struct {};

pub const telemetry = struct {
    pub const msr = @import("telemetry/msr.zig");
    pub const delta = @import("telemetry/delta.zig");
    pub const metrics = @import("telemetry/metrics.zig");
    pub const catalog = @import("telemetry/catalog.zig");
    pub const driver_proto = @import("telemetry/driver_proto.zig");
    pub const windows_msr = @import("telemetry/windows.zig");
    pub const engine = @import("telemetry/engine.zig");
    pub const fake = @import("telemetry/fake.zig");
    pub const vendor = @import("telemetry/vendor.zig");
};

pub const platform = struct {
    pub const backend = @import("platform/backend.zig");
    pub const native = @import("platform/native.zig");
    pub const replay = @import("platform/replay.zig");
    pub const windows = @import("platform/windows.zig");
    pub const linux = @import("platform/linux.zig");
};

pub const probe = struct {
    pub const cpu = @import("probe/cpu.zig");
};

pub const decode = struct {
    pub const cpu_x86 = @import("decode/cpu_x86.zig");
    pub const isa_x86 = @import("decode/isa_x86.zig");
};

pub const db = struct {
    pub const hwdb = @import("db/hwdb.zig");
};

pub const capture = struct {
    pub const cpuimg = @import("capture/cpuimg.zig");
    pub const telemimg = @import("capture/telemimg.zig");
    pub const sysimg = @import("capture/sysimg.zig");
};

/// Dane systemowe bez sterownika: SMBIOS, PCI (pci.ids), GPU, dyski, raport.
/// Moduły czyste (parsery, strony, eksport) są wieloplatformowe; zbieranie
/// danych na Windows siedzi w `sys.win` i istnieje tylko na Windows.
pub const sys = struct {
    pub const report = @import("sys/report.zig");
    pub const snapshot = @import("sys/snapshot.zig");
    pub const smbios = @import("sys/smbios.zig");
    pub const pciids = @import("sys/pciids.zig");
    pub const pciids_format = @import("sys/pciids_format.zig");
    pub const storage_parse = @import("sys/storage_parse.zig");
    pub const links = @import("sys/links.zig");
    pub const lookup = @import("sys/lookup.zig");
    pub const pages_cpu = @import("sys/pages_cpu.zig");
    pub const pages_system = @import("sys/pages_system.zig");
    pub const win = if (builtin.os.tag == .windows) struct {
        pub const devices = @import("sys/win/devices.zig");
        pub const cpuload = @import("sys/win/cpuload.zig");
        pub const storage = @import("sys/win/storage.zig");
        pub const gpu_vendor = @import("sys/win/gpu_vendor.zig");
        pub const adl = @import("sys/win/adl.zig");
        pub const nvapi = @import("sys/win/nvapi.zig");
        pub const collect = @import("sys/win/collect.zig");
    } else struct {};
};

test {
    // `zig build test` uruchamia też testy deklarowane w tych plikach,
    // nawet gdy nic ich nie importuje. Bez tego blokiem testy zostałyby martwe.
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
const builtin = @import("builtin");
