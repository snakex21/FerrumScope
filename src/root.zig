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
};

pub const db = struct {
    pub const hwdb = @import("db/hwdb.zig");
};

pub const capture = struct {
    pub const cpuimg = @import("capture/cpuimg.zig");
    pub const telemimg = @import("capture/telemimg.zig");
};

test {
    // `zig build test` uruchamia też testy deklarowane w tych plikach,
    // nawet gdy nic ich nie importuje. Bez tego blokiem testy zostałyby martwe.
    std.testing.refAllDeclsRecursive(@This());
}

const std = @import("std");
