const std = @import("std");

/// FerrumScope — build system.
///
/// Kolejność zależności wynika z architektury, nie z przypadku:
///
///   1. `hwdb-compile` (build step) czyta `db/source/cpu/*.toml`, waliduje
///      i serializuje do **źródła Zig** z tablicą bajtów `ferrum-hwdb.bin`;
///   2. wygenerowane źródło jest zwykłym modułem, importowanym przez CLI
///      i przez testy pod nazwą `hwdb_embedded`.
///
/// Dzięki temu program działa w pełni offline i **runtime nie parsuje TOML**
/// (`docs/03-hwdb.md` §3). A baza niespójna psuje build, a nie pierwsze
/// uruchomienie programu.
///
/// Korzystamy wyłącznie z przypiętego toolchainu (`tools/TOOLCHAIN.md`).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- 1. kompilator hardware database -----------------------------------
    const hwdb_compile_mod = b.createModule(.{
        .root_source_file = b.path("tools/hwdb_compile.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Kompilator importuje tę samą bibliotekę co runtime — gdy zmienimy
    // format wpisu, przestanie się kompilować obie strony naraz.
    hwdb_compile_mod.addImport("ferrum", b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    }));

    const hwdb_exe = b.addExecutable(.{
        .name = "hwdb-compile",
        .root_module = hwdb_compile_mod,
    });

    const run_hwdb = b.addRunArtifact(hwdb_exe);
    run_hwdb.addArg("--schema=ferrum.hwdb.cpu.v1");
    // `addFileArg` deklaruje zależność: zmiana TOML przebudowuje bazę.
    run_hwdb.addFileArg(b.path("db/source/cpu/intel.toml"));
    run_hwdb.addFileArg(b.path("db/source/cpu/amd.toml"));
    run_hwdb.addArg("-o");
    const hwdb_mod_path = run_hwdb.addOutputFileArg("ferrum-hwdb.zig");

    // --- 1b. kompilator bazy PCI ID ------------------------------------------
    // `db/source/pci/pci.ids` (PCI ID Repository, GPL-2.0+ LUB BSD-3) jest
    // kompilowany do zwartego obrazu binarnego osadzanego w programie.
    const pciids_format_mod = b.createModule(.{
        .root_source_file = b.path("src/sys/pciids_format.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pciids_compile_mod = b.createModule(.{
        .root_source_file = b.path("tools/pciids_compile.zig"),
        .target = target,
        .optimize = optimize,
    });
    pciids_compile_mod.addImport("pciids_format", pciids_format_mod);
    const pciids_exe = b.addExecutable(.{ .name = "pciids-compile", .root_module = pciids_compile_mod });
    const run_pciids = b.addRunArtifact(pciids_exe);
    run_pciids.addFileArg(b.path("db/source/pci/pci.ids"));
    run_pciids.addArg("-o");
    const pciids_mod_path = run_pciids.addOutputFileArg("ferrum-pciids.zig");
    // Obraz binarny obok .zig (ten sam katalog cache) — wymóg @embedFile.
    run_pciids.addArg("--bin");
    _ = run_pciids.addOutputFileArg("ferrum-pciids.bin");

    // --- 2. pliki capture dla testów regresyjnych --------------------------
    const generated = b.addWriteFiles();
    const fixture_names = [_][]const u8{
        "intel_core2_e6600",
        "intel_i9_13900k",
        "amd_athlon64_k8",
        "amd_ryzen7_5800x",
        "unknown_vendor",
        // Złoty capture z prawdziwej maszyny: AMD Ryzen 7 5800X3D.
        // Zawiera wyłącznie publiczne identyfikatory CPUID.
        "amd_ryzen7_5800x3d_native",
        // Ten sam sprzęt BEZ sekcji per-CPU (plik z Etapu 1). Test kompatybilności
        // wstecznej: stary plik musi działać i zejść do fallbacku HWDB.
        "amd_ryzen7_5800x3d_v1",
        // Fixture'y topologii Intel. Wszystkie są `synthetic_spec_fixture`:
        // zbudowane wg Intel SDM Vol. 2, NIE zrzutem kupionego SKU.
        // Nagłówek każdego pliku mówi to wprost.
        "intel_legacy_no_topology",
        "intel_leaf0b",
        "intel_leaf1f",
        // 8P + 8E = 16C/24T to topologia i9-12900K. i7-12700K ma 8P + 4E,
        // więc poprzednia nazwa `intel_hybrid_12700k` była nieprawdziwa.
        "intel_hybrid_12900k",
        // Dwa gniazda: CoreId 0..7 powtarza się w obu, rozróżnia je pakiet.
        "intel_2xsocket_8core",
    };
    for (fixture_names) |n| {
        _ = generated.addCopyFile(
            b.path(b.fmt("db/fixtures/{s}.cpuimg", .{n})),
            b.fmt("{s}.cpuimg", .{n}),
        );
    }
    // Capture systemowy (SMBIOS/PCI/GPU/dyski) z zamaskowanymi numerami seryjnymi.
    _ = generated.addCopyFile(b.path("db/fixtures/sys/asrock_b550_5800x3d_rx7900xtx.sysimg"), "sys_asrock_b550.sysimg");
    const fixtures_mod = generated.add("fixtures_embedded.zig",
        \\// Plik generowany przez build.zig. Nie edytuj ręcznie.
        \\pub const intel_core2_e6600 = @embedFile("intel_core2_e6600.cpuimg");
        \\pub const intel_i9_13900k = @embedFile("intel_i9_13900k.cpuimg");
        \\pub const amd_athlon64_k8 = @embedFile("amd_athlon64_k8.cpuimg");
        \\pub const amd_ryzen7_5800x = @embedFile("amd_ryzen7_5800x.cpuimg");
        \\pub const unknown_vendor = @embedFile("unknown_vendor.cpuimg");
        \\pub const amd_ryzen7_5800x3d_native = @embedFile("amd_ryzen7_5800x3d_native.cpuimg");
        \\pub const amd_ryzen7_5800x3d_v1 = @embedFile("amd_ryzen7_5800x3d_v1.cpuimg");
        \\pub const intel_legacy_no_topology = @embedFile("intel_legacy_no_topology.cpuimg");
        \\pub const intel_leaf0b = @embedFile("intel_leaf0b.cpuimg");
        \\pub const intel_leaf1f = @embedFile("intel_leaf1f.cpuimg");
        \\pub const intel_hybrid_12900k = @embedFile("intel_hybrid_12900k.cpuimg");
        \\pub const intel_2xsocket_8core = @embedFile("intel_2xsocket_8core.cpuimg");
        \\pub const sys_asrock_b550 = @embedFile("sys_asrock_b550.sysimg");
    );

    // --- 3. CLI --------------------------------------------------------------
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addAnonymousImport("hwdb_embedded", .{ .root_source_file = hwdb_mod_path });
    cli_mod.addAnonymousImport("fixtures_embedded", .{ .root_source_file = fixtures_mod });
    cli_mod.addAnonymousImport("pciids_embedded", .{ .root_source_file = pciids_mod_path });

    const cli = b.addExecutable(.{
        .name = "ferrumscope",
        .root_module = cli_mod,
    });
    b.installArtifact(cli);

    const run_cli = b.addRunArtifact(cli);
    if (b.args) |args| run_cli.addArgs(args);
    b.step("run", "Uruchom ferrumscope (np. `zig build run -- cpu`)").dependOn(&run_cli.step);

    // --- 3b. GUI (tylko Windows) ---------------------------------------------
    // Czysty Win32, bez zależności zewnętrznych. Na innych systemach artefaktu
    // nie ma, żeby `zig build` nie padał; `gui-run` mówi wtedy wprost dlaczego.
    const gui_run_step = b.step("gui-run", "Uruchom ferrumscope-gui (tylko Windows)");
    if (target.result.os.tag == .windows) {
        const gui_mod = b.createModule(.{
            .root_source_file = b.path("src/gui_main.zig"),
            .target = target,
            .optimize = optimize,
        });
        // Ta sama osadzona baza co CLI. `fixtures_embedded` GUI nie potrzebuje —
        // to wyłącznie dane testów.
        gui_mod.addAnonymousImport("hwdb_embedded", .{ .root_source_file = hwdb_mod_path });
        gui_mod.addAnonymousImport("pciids_embedded", .{ .root_source_file = pciids_mod_path });

        const gui = b.addExecutable(.{
            .name = "ferrumscope-gui",
            .root_module = gui_mod,
            // Common Controls v6 + DPI PerMonitorV2 + asInvoker.
            .win32_manifest = b.path("src/gui/ferrumscope-gui.manifest"),
        });
        gui.subsystem = .Windows;
        b.installArtifact(gui);

        const run_gui = b.addRunArtifact(gui);
        if (b.args) |args| run_gui.addArgs(args);
        gui_run_step.dependOn(&run_gui.step);
    } else {
        gui_run_step.dependOn(&b.addFail("ferrumscope-gui istnieje tylko dla Windows").step);
    }

    // --- 4. testy ------------------------------------------------------------
    const test_step = b.step("test", "Uruchom wszystkie testy");

    const lib_tests = b.addTest(.{
        .name = "ferrumscope-lib-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Testy dostają tę samą osadzoną bazę co CLI — inaczej testowałyby inny
    // plik niż program produkcyjny.
    lib_tests.root_module.addAnonymousImport("hwdb_embedded", .{ .root_source_file = hwdb_mod_path });
    lib_tests.root_module.addAnonymousImport("fixtures_embedded", .{ .root_source_file = fixtures_mod });
    lib_tests.root_module.addAnonymousImport("pciids_embedded", .{ .root_source_file = pciids_mod_path });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    test_step.dependOn(&run_lib_tests.step);

    // Testy kompilatora bazy: duplikaty, nakładanie zakresów, błędne enumy.
    const hwdb_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/hwdb_compile.zig"),
        .target = target,
        .optimize = optimize,
    });
    hwdb_test_mod.addImport("ferrum", b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const hwdb_tests = b.addTest(.{ .name = "hwdb-compile-test", .root_module = hwdb_test_mod });
    test_step.dependOn(&b.addRunArtifact(hwdb_tests).step);

    // Testy kompilatora PCI ID (parser pci.ids, serializacja, wiersz poleceń).
    const pciids_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/pciids_compile.zig"),
        .target = target,
        .optimize = optimize,
    });
    pciids_test_mod.addImport("pciids_format", pciids_format_mod);
    const pciids_tests = b.addTest(.{ .name = "pciids-compile-test", .root_module = pciids_test_mod });
    test_step.dependOn(&b.addRunArtifact(pciids_tests).step);

    // --- 5. walidacja bazy bez kompilacji programu ---------------------------
    b.step("hwdb-check", "Skompiluj i zwaliduj bazę").dependOn(&run_hwdb.step);
}
