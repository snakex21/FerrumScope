# FerrumScope — narzędzia toolchainu

## Zig

Projekt używa **przypiętej** wersji Zig, niezależnej od wersji systemowej.
Wersja: **0.15.2** (odczyt z `build.zig.zon` -> `minimum_zig_version`).

```sh
python tools/fetch_zig.py           # pobiera i rozpakowuje do tools/zig/
tools/zig/zig-*/zig.exe version
```

Reguła: **nie używamy Zig z `PATH`.** Build jest uruchamiany przez
`tools/zig.sh` (Linux/macOS) albo `tools/zig.cmd` (Windows), które same
weryfikują obecność przypiętej wersji i podpowiadają komendę pobrania,
jeśli jej nie ma. Dzięki temu build na maszynie bez Zig jest jednym
poleceniem, a nie cichą zmianą kompilatora.

Wersja jest sprawdzana w `build.zig` — `build.zig.zon` deklaruje
`minimum_zig_version`, a build odmawia pracy na starszej.
