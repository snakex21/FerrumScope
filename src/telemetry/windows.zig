//! WindowsTelemetryBackend — dostęp do MSR przez sterownik jądra.
//!
//! # Warstwa, a nie cały program
//!
//! Ten plik to **wyłącznie** „jak rozmawiać ze sterownikiem". Nie zawiera
//! HWDB, nie zna AMD/Intela, nie interpretuje żadnego rejestru. Dostaje surowe
//! `u64` i oddaje je dekoderowi z Etapu 3A. Dekoder nie wie — i nie może wiedzieć —
//! skąd te liczby pochodzą, bo `msr.Backend` jest wspólnym interfejsem.
//!
//! # Transport jest wstrzykiwany
//!
//! Warstwa IO (`Transport`) jest interfejsem, a nie wywołaniem `DeviceIoControl`
//! wpisanym wprost. Powód: mapowanie kodów błędów sterownika na `msr.MsrError`,
//! handshake wersji i lifecycle (detect → handshake → open → use → close) są
//! **właśnie** tą częścią, którą łatwo zepsuć, a najtrudniej przetestować przy
//! realnym sterowniku. Testy używają transportu testowego i sprawdzają dokładnie
//! tę logikę; produkcyjna ścieżka używa `DeviceIoControl`.
//!
//! Gdyby logika siedziała bezpośrednio wokół `DeviceIoControl`, jedynym testem
//! byłby sterownik na maszynie z WDK — czyli dokładnie wtedy, gdy testy są
//! najdroższe i najwolniejsze.
//!
//! # Stan na tej maszynie
//!
//! Sterownika nie ma i nie da się go tu zbudować (brak WDK/MSVC — patrz
//! `docs/08b-windows-msr-backend.md`). `open()` zwraca więc `error.NotInstalled`,
//! a `ferrumscope sensors` mówi o tym wprost, zamiast zmyślać wartość.

const std = @import("std");
const i18n = @import("../i18n/i18n.zig");
const builtin = @import("builtin");
const msr = @import("msr.zig");
const proto = @import("driver_proto.zig");

/// Ścieżka urządzenia. Musi odpowiadać `\DosDevices\...` w sterowniku.
pub const device_path = "\\\\.\\FerrumScopeMsr";

// ---------------------------------------------------------------------------
// Typy Win32
// ---------------------------------------------------------------------------

const DWORD = u32;
const HANDLE = ?*anyopaque;
const BOOL = i32;
const NTSTATUS = i32;

const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
const GENERIC_READ: DWORD = 0x8000_0000;
const OPEN_EXISTING: DWORD = 3;
const FILE_ATTRIBUTE_NORMAL: DWORD = 0x80;
const ERROR_FILE_NOT_FOUND: DWORD = 2;
const ERROR_PATH_NOT_FOUND: DWORD = 3;
const ERROR_ACCESS_DENIED: DWORD = 5;
const ERROR_INVALID_HANDLE: DWORD = 6;
const ERROR_NOT_SUPPORTED: DWORD = 50;
const ERROR_BAD_LENGTH: DWORD = 24;

pub const WinError = struct {
    code: DWORD = 0,
    /// `GetLastError()` po błędzie, zanim cokolwiek innego nadpisało rejestr.
    last_error: DWORD = 0,
};

extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: DWORD,
    dwShareMode: ?*const anyopaque,
    lpSecurityAttributes: ?*const anyopaque,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?*const anyopaque,
) callconv(.winapi) HANDLE;
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

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

/// Warstwa I/O sterownika. Wstrzykiwana, żeby logika była testowalna.
pub const Transport = struct {
    pub const VTable = struct {
        open: *const fn (ctx: *anyopaque, path: []const u8) OpenResult,
        close: *const fn (ctx: *anyopaque, handle: Handle) void,
        ioctl: *const fn (
            ctx: *anyopaque,
            handle: Handle,
            code: u32,
            in_buf: []const u8,
            out_buf: []u8,
        ) IoResult,
        last_error: *const fn (ctx: *anyopaque) DWORD,
    };

    vtable: *const VTable,
    ctx: *anyopaque,
};

/// Uchwyt jest wskaźnikiem, żeby `INVALID_HANDLE_VALUE` dało się wyrazić
/// dosłownie — `?*anyopaque` zamieniłby to na `null` i zrobił dwuznaczność
/// („uchwyt zamknięty" vs „nie udało się otworzyć").
pub const Handle = HANDLE;

pub const OpenResult = union(enum) {
    ok: Handle,
    /// Kod z `GetLastError()` — `null`, gdy transport nie udostępnia przyczyny.
    failed: ?DWORD,
};

pub const IoResult = union(enum) {
    ok,
    failed: ?DWORD,
};

// ---------------------------------------------------------------------------
// Błąd otwarcia — przyczyna widoczna dla CLI
// ---------------------------------------------------------------------------

pub const OpenError = error{
    /// Sterownika nie ma w systemie. Stan normalny, nie awaria.
    NotInstalled,
    /// Sterownik jest, ale proces nie ma do niego dostępu.
    PermissionDenied,
    /// Sterownik odpowiada, ale mówi inną wersją protokołu.
    VersionMismatch,
    /// Odpowiedź sterownika nie mieści się w naszym buforze.
    ProtocolViolation,
    IoFailed,
};

/// Opis przyczyny do pokazania w CLI.
///
/// Rozdzielamy `NotInstalled` od `PermissionDenied`, bo to **różne naprawy**:
/// pierwsza to „zainstaluj sterownik", druga to „uruchom admina". Zgłaszanie
/// obu jako jednego błędu zmuszałoby użytkownika do zgadywania.
pub fn openErrorDetail(e: OpenError) []const u8 {
    return switch (e) {
        error.NotInstalled => i18n.t("sterownik FerrumScopeMsr nie jest zainstalowany"),
        error.PermissionDenied => i18n.t("brak uprawnień do urządzenia (wymagane konto administratora)"),
        error.VersionMismatch => i18n.t("sterownik odpowiada inną wersją protokołu"),
        error.ProtocolViolation => i18n.t("odpowiedź sterownika nie mieści się w buforze"),
        error.IoFailed => i18n.t("błąd I/O przy komunikacji ze sterownikiem"),
    };
}

/// Mapuje błąd Win32 na przyczynę otwarcia.
///
/// `ERROR_FILE_NOT_FOUND` / `ERROR_PATH_NOT_FOUND` oznaczają **brak sterownika**,
/// a nie błąd uprawnień — to rozróżnienie decyduje o tym, co CLI podpowiedzi.
pub fn classifyOpenError(code: ?DWORD) OpenError {
    const c = code orelse return error.IoFailed;
    return switch (c) {
        ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND => error.NotInstalled,
        ERROR_ACCESS_DENIED => error.PermissionDenied,
        else => error.IoFailed,
    };
}

/// Mapuje kod błędu `GetLastError()` po `DeviceIoControl` na `msr.MsrError`.
///
/// Błąd protokołu (`bad_size`, `unsupported_version`) **nie** jest błędem
/// sprzętu, więc nie zamienia się na `backend_error`: zamiana sprawiłaby, że
/// `sensors` zgłaszałoby „błąd backendu" przy pliku z niezgodną wersją.
pub fn classifyIoError(code: ?DWORD) msr.MsrError {
    const c = code orelse return .backend_error;
    return switch (c) {
        ERROR_ACCESS_DENIED => .permission_denied,
        ERROR_BAD_LENGTH, ERROR_INVALID_HANDLE => .backend_error,
        ERROR_NOT_SUPPORTED => .unsupported,
        else => .backend_error,
    };
}

// ---------------------------------------------------------------------------
// Backend
// ---------------------------------------------------------------------------

pub const Backend = struct {
    transport: Transport,
    handle: Handle = null,
    online_cpu_count: u16 = 0,
    capabilities: msr.CapabilitySet = .{},
    /// Otwarta ręcznie w celu diagnostycznym — `false` w normalnym przebiegu.
    diagnostic: bool = false,
    err: WinError = .{},

    /// Otwiera urządzenie i wykonuje handshake protokołu.
    ///
    /// Kolejność jest ustalona: **najpierw** open, potem handshake. Odwrotna
    /// nie ma sensu — nie ma czego wersjonować, dopóki nie ma połączenia.
    pub fn open(t: Transport) OpenError!Backend {
        var self = Backend{ .transport = t };
        const h = switch (t.vtable.open(t.ctx, device_path)) {
            .ok => |h| h,
            .failed => |code| {
                self.err = .{ .code = code orelse 0, .last_error = t.vtable.last_error(t.ctx) };
                return classifyOpenError(code);
            },
        };
        self.handle = h;

        // Handshake: bez zgody wersji nie wolno czytać rejestrów. Sterownik z
        // nowszym protokołem mógłby inaczej interpretować `struct_size`.
        errdefer self.close();

        var req = proto.QueryProtocolRequest{
            .header = .{ .struct_size = @sizeOf(proto.QueryProtocolRequest) },
        };
        var resp: proto.QueryProtocolResponse = undefined;
        try self.ioctl(proto.Function.query_protocol, std.mem.asBytes(&req), std.mem.asBytes(&resp));

        if (resp.header.magic != proto.protocol_magic) return error.ProtocolViolation;
        if (resp.protocol_version < proto.min_client_version or
            resp.protocol_version > proto.protocol_version)
        {
            return error.VersionMismatch;
        }
        self.online_cpu_count = resp.online_cpu_count;
        return self;
    }

    /// Otwiera do diagnostyki, **pomijając handshake**.
    ///
    /// Do `--raw` i logów, gdy trzeba zobaczyć surowe zachowanie sterownika
    /// również wtedy, gdy wersje się nie zgadzają. Nie wolno używać tej ścieżki
    /// do odczytów — jej istnienie przy odczycie byłoby brakiem walidacji.
    pub fn openDiagnostic(t: Transport) OpenError!Backend {
        var self = Backend{ .transport = t, .diagnostic = true };
        const h = switch (t.vtable.open(t.ctx, device_path)) {
            .ok => |h| h,
            .failed => |code| {
                self.err = .{ .code = code orelse 0, .last_error = t.vtable.last_error(t.ctx) };
                return classifyOpenError(code);
            },
        };
        self.handle = h;
        // Zdolności pytamy nawet bez handshake: diagnostyka ma działać właśnie
        // wtedy, gdy protokół się rozjeżdża.
        var req = proto.CapabilitiesResponse{ .header = .{
            .struct_size = @sizeOf(proto.CapabilitiesResponse),
        } };
        var resp: proto.CapabilitiesResponse = undefined;
        _ = self.ioctl(proto.Function.query_capabilities, std.mem.asBytes(&req), std.mem.asBytes(&resp)) catch {
            self.close();
            return error.IoFailed;
        };
        self.online_cpu_count = resp.online_cpu_count;
        return self;
    }

    /// Zamyka uchwyt. Wielokrotne wywołanie jest bezpieczne.
    pub fn close(self: *Backend) void {
        if (self.handle == null) return;
        self.transport.vtable.close(self.transport.ctx, self.handle);
        self.handle = null;
    }

    fn ioctl(self: *Backend, f: proto.Function, in: []const u8, out: []u8) OpenError!void {
        const r = self.transport.vtable.ioctl(
            self.transport.ctx,
            self.handle,
            proto.ioctlCode(f),
            in,
            out,
        );
        switch (r) {
            .ok => return,
            .failed => |code| {
                self.err = .{ .code = code orelse 0, .last_error = self.transport.vtable.last_error(self.transport.ctx) };
                return classifyIoErrorToOpen(classifyIoError(code));
            },
        }
    }

    /// Odczyt MSR na wskazanym procesorze logicznym.
    ///
    /// Walidacja przed wysłaniem jest **powtórzeniem** tej ze sterownika, nie
    /// zamiastką. Sterownik jest granicą zaufania i musi walidować sam; podwójna
    /// walidacja nie szkodzi, a oszczędza round-trip przy oczywistym błędzie.
    pub fn readMsr(self: *Backend, logical_cpu: u16, index: u32) msr.MsrRead {
        if (self.handle == null) return msr.MsrRead.fail(.unavailable);
        if (self.online_cpu_count != 0 and logical_cpu >= self.online_cpu_count) {
            return msr.MsrRead.fail(.cpu_offline);
        }
        if (!proto.isMsrAllowed(index)) return msr.MsrRead.fail(.unsupported);

        var req = proto.ReadMsrRequest{
            .header = .{ .struct_size = @sizeOf(proto.ReadMsrRequest) },
            .logical_cpu = logical_cpu,
            .msr_index = index,
        };
        var resp: proto.ReadMsrResponse = undefined;

        const r = self.transport.vtable.ioctl(
            self.transport.ctx,
            self.handle,
            proto.ioctlCode(proto.Function.read_msr),
            std.mem.asBytes(&req),
            std.mem.asBytes(&resp),
        );
        switch (r) {
            .failed => |code| {
                self.err = .{ .code = code orelse 0, .last_error = self.transport.vtable.last_error(self.transport.ctx) };
                return msr.MsrRead.fail(classifyIoError(code));
            },
            .ok => {},
        }

        if (resp.header.magic != proto.protocol_magic) return msr.MsrRead.fail(.backend_error);
        // Sterownik zwrócił strukturę **krótszą**, niż znamy. Czytanie pola,
        // którego tam nie ma, to odczyt pamięci nieuznaczonej — gorsze niż błąd.
        if (resp.header.struct_size < @sizeOf(proto.ReadMsrResponse)) {
            return msr.MsrRead.fail(.backend_error);
        }
        if (resp.status != .ok) {
            // Status protokołu mapujemy na wspólny kontrakt. Błędy **walidacji**
            // nie są błędami sprzętu, więc `msrStatus` zwraca dla nich `null`
            // i zostawiamy `backend_error` zamiast udawać odczyt.
            return msr.MsrRead.fail(proto.msrStatus(resp.status) orelse .backend_error);
        }
        return msr.MsrRead.ok(resp.value);
    }

    pub fn onlineCpuCount(self: *const Backend) u16 {
        return self.online_cpu_count;
    }

    /// Prawdziwy zegar monotoniczny.
    ///
    /// Zwracanie `0` byłoby kłamstwem: silnik liczy na tej wartości deltę
    /// liczników, a zerowy czas oznaczałby nieskończoną częstotliwość
    /// efektywną. `nanoTimestamp` jest monotoniczny (nie jest zegarem ściennym),
    /// więc przejście czasu systemowego wstecz nic tu nie psuje.
    pub fn monotonicNanos(self: *const Backend) u64 {
        _ = self;
        const t = std.time.nanoTimestamp();
        return if (t < 0) 0 else @intCast(t);
    }

    pub fn sourceName(self: *const Backend) []const u8 {
        _ = self;
        return "Windows driver (" ++ device_path ++ ")";
    }

    /// Adapter do wspólnego interfejsu.
    pub fn api(self: *Backend) msr.Backend {
        return .{ .vtable = vtable(), .ctx = @ptrCast(self) };
    }

    fn vtable() *const msr.Backend.VTable {
        const impl = struct {
            fn read(ctx: *anyopaque, cpu: u16, index: u32) msr.MsrRead {
                const self: *Backend = @ptrCast(@alignCast(ctx));
                return self.readMsr(cpu, index);
            }
            fn count(ctx: *anyopaque) u16 {
                const self: *const Backend = @ptrCast(@alignCast(ctx));
                return self.onlineCpuCount();
            }
            fn caps(ctx: *anyopaque) msr.CapabilitySet {
                const self: *const Backend = @ptrCast(@alignCast(ctx));
                return self.capabilities;
            }
            fn now(ctx: *anyopaque) u64 {
                const self: *const Backend = @ptrCast(@alignCast(ctx));
                return self.monotonicNanos();
            }
            fn name(ctx: *anyopaque) []const u8 {
                const self: *const Backend = @ptrCast(@alignCast(ctx));
                return self.sourceName();
            }
        };
        return &struct {
            const v: msr.Backend.VTable = .{
                .readMsr = impl.read,
                .onlineCpuCount = impl.count,
                .capabilities = impl.caps,
                .monotonicNanos = impl.now,
                .sourceName = impl.name,
            };
        }.v;
    }
};

/// Rzutowanie błędu I/O na błąd otwarcia.
///
/// Istnieje, bo `ioctl()` używa wspólnego `OpenError` dla spójności ścieżki, a
/// `readMsr()` potrzebuje `msr.MsrError`. Jedna funkcja, dwa konteksty —
/// bez niej powstałyby dwie równoległe tabele mapowania, które rozjadą się.
fn classifyIoErrorToOpen(e: msr.MsrError) OpenError {
    return switch (e) {
        .permission_denied => error.PermissionDenied,
        .unsupported => error.NotInstalled,
        .cpu_offline => error.ProtocolViolation,
        .unavailable, .backend_error => error.IoFailed,
    };
}

// ---------------------------------------------------------------------------
// Transport produkcyjny: DeviceIoControl
// ---------------------------------------------------------------------------

pub const deviceIoTransport = struct {
    path_buf: [64]u16 = undefined,

    /// Zamienia ścieżkę na NUL-zakończony UTF-16.
    ///
    /// `CreateFileW` bierze `LPCWSTR`, więc terminator jest **wymagany**.
    /// `utf8ToUtf16Le` go nie dodaje — zwraca liczbę zapisanych jednostek.
    /// Kolejność argumentów w Zigu 0.15 to `(bufor, utf8)`, nie odwrotnie.
    fn toWide(self: *deviceIoTransport, path: []const u8) ?[:0]const u16 {
        if (path.len + 1 > self.path_buf.len) return null;
        const n = std.unicode.utf8ToUtf16Le(self.path_buf[0..path.len], path) catch return null;
        self.path_buf[n] = 0;
        return self.path_buf[0 .. n + 1 :0];
    }

    fn open(ctx: *anyopaque, path: []const u8) OpenResult {
        if (builtin.os.tag != .windows) return .{ .failed = null };
        const self: *deviceIoTransport = @ptrCast(@alignCast(ctx));
        const wide = self.toWide(path) orelse return .{ .failed = ERROR_BAD_LENGTH };
        const h = CreateFileW(
            wide.ptr,
            GENERIC_READ,
            null,
            null,
            OPEN_EXISTING,
            FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (h == null or h == INVALID_HANDLE_VALUE) {
            return .{ .failed = GetLastError() };
        }
        return .{ .ok = h };
    }

    fn close(ctx: *anyopaque, handle: Handle) void {
        _ = ctx;
        if (handle != null) _ = CloseHandle(handle);
    }

    fn ioctl(
        ctx: *anyopaque,
        handle: Handle,
        code: u32,
        in_buf: []const u8,
        out_buf: []u8,
    ) IoResult {
        if (builtin.os.tag != .windows) return .{ .failed = null };
        _ = ctx;
        var returned: DWORD = 0;
        const ok = DeviceIoControl(
            handle,
            code,
            in_buf.ptr,
            @intCast(in_buf.len),
            out_buf.ptr,
            @intCast(out_buf.len),
            &returned,
            null,
        );
        if (ok == 0) return .{ .failed = GetLastError() };
        return .ok;
    }

    fn last_error(ctx: *anyopaque) DWORD {
        _ = ctx;
        return GetLastError();
    }

    pub fn vtable() *const Transport.VTable {
        return &struct {
            const v: Transport.VTable = .{
                .open = open,
                .close = close,
                .ioctl = ioctl,
                .last_error = last_error,
            };
        }.v;
    }

    pub fn transport(self: *deviceIoTransport) Transport {
        return .{ .vtable = vtable(), .ctx = @ptrCast(self) };
    }
};

// ---------------------------------------------------------------------------
// Testy — cała logika bez sterownika
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Transport testowy: odgrywa zaprogramowane odpowiedzi i zapisuje żądania.
///
/// Dzięki niemu testujemy dokładnie to, co w realnym sterowniku byłoby
/// najtrudniejsze: mapowanie błędów, wersje, rozmiary i kolejność.
pub const TestTransport = struct {
    /// Odpowiedź na kolejne `open`. `null` = sukces.
    open_result: ?DWORD = null,
    /// Odpowiedź na `query_protocol`.
    proto_resp: proto.QueryProtocolResponse = .{
        .header = .{
            .magic = proto.protocol_magic,
            .version = proto.protocol_version,
            .struct_size = @sizeOf(proto.QueryProtocolResponse),
        },
        .protocol_version = proto.protocol_version,
        .min_client_version = proto.min_client_version,
        .online_cpu_count = 16,
    },
    /// Odpowiedź na `read_msr`: status i wartość.
    read_status: proto.Status = .ok,
    read_value: u64 = 0,
    /// Błąd `DeviceIoControl` dla `read_msr` (null = brak błędu).
    read_io_error: ?DWORD = null,
    /// Wywołania `close` — do sprawdzenia lifecycle.
    close_calls: u32 = 0,
    open_calls: u32 = 0,
    /// Ostatni kod IOCTL i ostatnie żądanie — do weryfikacji, że backend
    /// **naprawdę** pyta o odpowiednią funkcję.
    last_code: u32 = 0,
    last_msr: u32 = 0,
    last_cpu: u16 = 0,

    fn tOpen(ctx: *anyopaque, path: []const u8) OpenResult {
        _ = path;
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        self.open_calls += 1;
        if (self.open_result) |e| return .{ .failed = e };
        return .{ .ok = @ptrFromInt(0x1234) };
    }

    fn tClose(ctx: *anyopaque, handle: Handle) void {
        _ = handle;
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        self.close_calls += 1;
    }

    fn tIoctl(
        ctx: *anyopaque,
        handle: Handle,
        code: u32,
        in_buf: []const u8,
        out_buf: []u8,
    ) IoResult {
        _ = handle;
        const self: *TestTransport = @ptrCast(@alignCast(ctx));
        self.last_code = code;
        switch (code) {
            proto.ioctlCode(proto.Function.query_protocol) => {
                if (out_buf.len < @sizeOf(proto.QueryProtocolResponse)) return .{ .failed = ERROR_BAD_LENGTH };
                @memcpy(std.mem.sliceAsBytes(out_buf[0..@sizeOf(proto.QueryProtocolResponse)]), std.mem.asBytes(&self.proto_resp));
            },
            proto.ioctlCode(proto.Function.query_capabilities) => {
                if (out_buf.len < @sizeOf(proto.CapabilitiesResponse)) return .{ .failed = ERROR_BAD_LENGTH };
                const r = proto.CapabilitiesResponse{
                    .header = .{
                        .magic = proto.protocol_magic,
                        .version = proto.protocol_version,
                        .struct_size = @sizeOf(proto.CapabilitiesResponse),
                    },
                    .online_cpu_count = 16,
                };
                @memcpy(std.mem.sliceAsBytes(out_buf[0..@sizeOf(proto.CapabilitiesResponse)]), std.mem.asBytes(&r));
            },
            proto.ioctlCode(proto.Function.read_msr) => {
                if (in_buf.len < @sizeOf(proto.ReadMsrRequest)) return .{ .failed = ERROR_BAD_LENGTH };
                const req: *const proto.ReadMsrRequest = @ptrCast(@alignCast(in_buf.ptr));
                self.last_msr = req.msr_index;
                self.last_cpu = req.logical_cpu;
                if (self.read_io_error) |e| return .{ .failed = e };
                if (out_buf.len < @sizeOf(proto.ReadMsrResponse)) return .{ .failed = ERROR_BAD_LENGTH };
                const r = proto.ReadMsrResponse{
                    .header = .{
                        .magic = proto.protocol_magic,
                        .version = proto.protocol_version,
                        .struct_size = @sizeOf(proto.ReadMsrResponse),
                    },
                    .status = self.read_status,
                    .value = self.read_value,
                };
                @memcpy(std.mem.sliceAsBytes(out_buf[0..@sizeOf(proto.ReadMsrResponse)]), std.mem.asBytes(&r));
            },
            else => return .{ .failed = ERROR_NOT_SUPPORTED },
        }
        return .ok;
    }

    fn tLastError(ctx: *anyopaque) DWORD {
        const self: *const TestTransport = @ptrCast(@alignCast(ctx));
        return self.read_io_error orelse 0;
    }

    fn tvtable() *const Transport.VTable {
        return &struct {
            const v: Transport.VTable = .{
                .open = tOpen,
                .close = tClose,
                .ioctl = tIoctl,
                .last_error = tLastError,
            };
        }.v;
    }

    pub fn transport(self: *TestTransport) Transport {
        return .{ .vtable = tvtable(), .ctx = @ptrCast(self) };
    }
};

test "otwarcie: brak sterownika daje NotInstalled, nie PermissionDenied" {
    // To rozróżnienie decyduje o podpowiedzi w CLI: „zainstaluj sterownik"
    // kontra „uruchom admina". Zgłaszanie jednego jako drugiego zaburza użytkownika.
    var t = TestTransport{ .open_result = ERROR_FILE_NOT_FOUND };
    try testing.expectError(error.NotInstalled, Backend.open(t.transport()));
    try testing.expectEqual(@as(u32, 1), t.open_calls);
}

test "otwarcie: brak uprawnień daje PermissionDenied" {
    var t = TestTransport{ .open_result = ERROR_ACCESS_DENIED };
    try testing.expectError(error.PermissionDenied, Backend.open(t.transport()));
}

test "otwarcie: ścieżka nie istnieje to też NotInstalled" {
    var t = TestTransport{ .open_result = ERROR_PATH_NOT_FOUND };
    try testing.expectError(error.NotInstalled, Backend.open(t.transport()));
}

test "handshake: niezgodna wersja protokołu jest odrzucona" {
    // Sterownik nowszy niż nasz. Musimy odmówić, zamiast wersjonować „na oko" —
    // `struct_size` mógłby oznaczać co innego.
    var t = TestTransport{};
    t.proto_resp.protocol_version = proto.protocol_version + 1;
    try testing.expectError(error.VersionMismatch, Backend.open(t.transport()));
}

test "handshake: sterownik starszy niż minimalny klient jest odrzucony" {
    var t = TestTransport{};
    t.proto_resp.protocol_version = proto.min_client_version - 1;
    try testing.expectError(error.VersionMismatch, Backend.open(t.transport()));
}

test "handshake: zła sygnatura w odpowiedzi to ProtocolViolation" {
    var t = TestTransport{};
    t.proto_resp.header.magic = 0xDEAD_BEEF;
    try testing.expectError(error.ProtocolViolation, Backend.open(t.transport()));
}

test "handshake: poprawne otwarcie zapisuje liczbę CPU online" {
    var t = TestTransport{};
    var b = try Backend.open(t.transport());
    defer b.close();
    try testing.expectEqual(@as(u16, 16), b.onlineCpuCount());
    // Handshake **musi** pytać o wersję przed czymkolwiek innym. Gdyby
    // odpytywał najpierw o capabilities, odczyt byłby niewersjonowany.
    try testing.expectEqual(proto.ioctlCode(proto.Function.query_protocol), t.last_code);
}

test "odczyt: dozwolony rejestr wraca jako ok" {
    var t = TestTransport{ .read_value = 0xDEAD_BEEF_CAFE };
    var b = try Backend.open(t.transport());
    defer b.close();

    const r = b.readMsr(3, 0xE8);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF_CAFE), r.get().?);
    // Sprawdzamy, że do sterownika poszło **to, o co prosiliśmy** — nie inny CPU
    // i nie inny rejestr.
    try testing.expectEqual(@as(u16, 3), t.last_cpu);
    try testing.expectEqual(@as(u32, 0xE8), t.last_msr);
}

test "odczyt: rejestr spoza allowlisty nigdy nie wychodzi do sterownika" {
    // Backend odrzuca lokalnie, zanim zużyje round-trip. Ale to **nie**
    // zastępuje walidacji sterownika — ta nadal musi istnieć po stronie jądra.
    var t = TestTransport{};
    var b = try Backend.open(t.transport());
    defer b.close();

    const before = t.last_code;
    const r = b.readMsr(0, 0xC001_0014);
    try testing.expectEqual(msr.MsrError.unsupported, r.status.err);
    // Żadnego IOCTL nie wysłaliśmy dla niedozwolonego rejestru.
    try testing.expectEqual(before, t.last_code);
}

test "odczyt: CPU spoza zakresu to cpu_offline, nie cudzy rejestr" {
    var t = TestTransport{};
    var b = try Backend.open(t.transport());
    defer b.close();

    const before = t.last_code;
    const r = b.readMsr(16, 0xE8);
    try testing.expectEqual(msr.MsrError.cpu_offline, r.status.err);
    // Cichy odczyt dla niewłaściwego procesora byłby gorszy niż brak odczytu:
    // dałby wiarygodną liczbę z innego rdzenia.
    try testing.expectEqual(before, t.last_code);
}

test "odczyt: status cpu_offline ze sterownika wraca jako cpu_offline" {
    var t = TestTransport{ .read_status = .cpu_offline };
    var b = try Backend.open(t.transport());
    defer b.close();
    try testing.expectEqual(msr.MsrError.cpu_offline, b.readMsr(0, 0xE8).status.err);
}

test "odczyt: błąd I/O jest mapowany, nie zamieniany na sukces" {
    var t = TestTransport{ .read_io_error = ERROR_ACCESS_DENIED };
    var b = try Backend.open(t.transport());
    defer b.close();
    try testing.expectEqual(msr.MsrError.permission_denied, b.readMsr(0, 0xE8).status.err);
}

test "odczyt: błąd walidacji ze sterownika to backend_error, nie sprzęt" {
    // `msr_not_allowed` to błąd **żądania**, nie rejestru. Raportowanie go jako
    // `backend_error` kazałoby użytkownikowi szukać awarii sprzętu.
    var t = TestTransport{ .read_status = .msr_not_allowed };
    var b = try Backend.open(t.transport());
    defer b.close();
    const r = b.readMsr(0, 0xE8);
    try testing.expectEqual(msr.MsrError.backend_error, r.status.err);
    // I wartość **nie** może być czytelna.
    try testing.expect(r.get() == null);
}

test "lifecycle: close jest idempotentny" {
    // Podwójne `close` wyzwoliłoby podwójne `CloseHandle` na zawartym
    // uchwytu. W IoT-like backendach to zwykła droga do użycia po zwolnieniu.
    var t = TestTransport{};
    var b = try Backend.open(t.transport());
    b.close();
    b.close();
    try testing.expectEqual(@as(u32, 1), t.close_calls);
}

test "lifecycle: odczyt po zamknięciu to unavailable, nie awaria" {
    var t = TestTransport{};
    var b = try Backend.open(t.transport());
    b.close();
    const r = b.readMsr(0, 0xE8);
    try testing.expectEqual(msr.MsrError.unavailable, r.status.err);
}

test "lifecycle: nieudany handshake zamyka uchwyt" {
    // Uchwyt bez `close` to wyciek. `errdefer` w `open` musi to obsłużyć, bo
    // klient i tak nie dostanie uchwytu, żeby go zamknąć.
    var t = TestTransport{};
    t.proto_resp.protocol_version = 99;
    try testing.expectError(error.VersionMismatch, Backend.open(t.transport()));
    try testing.expectEqual(@as(u32, 1), t.close_calls);
}

test "interfejs: backend wystawia ten sam interfejs co backend sztuczny" {
    var t = TestTransport{};
    var b = try Backend.open(t.transport());
    defer b.close();
    b.capabilities.add(.msr_read);
    b.capabilities.add(.aperf_mperf);

    // Odczyt przez wspólny interfejs — dokładnie tą ścieżką pójdzie dekoder
    // w `sensors`. Jeśli tu coś nie działa, `sensors` nie zadziała.
    const api = b.api();
    try testing.expectEqual(@as(u64, 0), api.readMsr(0, 0xE8).get().?);
    try testing.expect(api.capabilities().has(.aperf_mperf));
    try testing.expectEqual(@as(u16, 16), api.onlineCpuCount());
    try testing.expectEqualStrings("Windows driver (" ++ device_path ++ ")", api.sourceName());
}
