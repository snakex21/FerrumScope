//! Pobieranie przez HTTPS — WinHTTP (systemowy stos Windows).
//!
//! Dlaczego WinHTTP, a nie `std.http.Client`:
//!   * jawne limity czasu (rozwiązywanie nazw, połączenie, wysyłka, odbiór) —
//!     klient z biblioteki standardowej Zig 0.15 ich nie ma;
//!   * TLS przez SChannel z magazynem certyfikatów Windows (aktualizowany
//!     przez system, zgodny z firmowymi proxy i politykami);
//!   * systemowe ustawienia proxy (WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY).
//!
//! Przekierowania obsługujemy sami (`WINHTTP_OPTION_REDIRECT_POLICY = NEVER`):
//! każdy kolejny adres musi przejść `manifest.isAllowedUrl` — tylko https
//! do github.com, objects.githubusercontent.com i
//! release-assets.githubusercontent.com. Wyjątek: api.github.com, wyłącznie
//! dla pierwszego żądania na `manifest.releases_api_url` (lista wydań kanału
//! testowego, `Options.allow_api_listing`). Ciasteczka są wyłączone, a jedynym
//! dodatkowym nagłówkiem jest ogólny `User-Agent: FerrumScope-updater`
//! (bez wersji, identyfikatorów ani innej telemetrii).

const std = @import("std");
const builtin = @import("builtin");
const manifest = @import("manifest.zig");

pub const user_agent = "FerrumScope-updater";
pub const max_redirects = 5;

/// Limity czasu w milisekundach.
pub const Timeouts = struct {
    resolve: i32 = 10_000,
    connect: i32 = 10_000,
    send: i32 = 15_000,
    receive: i32 = 30_000,
};

pub const Error = error{
    /// HTTP 404 — dla manifestu znaczy „brak opublikowanych wydań”.
    NotFound,
    HttpStatus,
    Timeout,
    Network,
    TooLarge,
    DisallowedUrl,
    TooManyRedirects,
    Unsupported,
    OutOfMemory,
};

pub const Options = struct {
    /// Pozwala na **pierwsze** żądanie do `manifest.releases_api_url`
    /// (api.github.com, kanał testowy). Przekierowania nadal przechodzą
    /// zwykłą listę dozwolonych hostów, bez api.github.com.
    allow_api_listing: bool = false,
};

/// Pobiera zasób do pamięci (najwyżej `max_bytes`). Zwrócony bufor należy do wołającego.
pub fn get(alloc: std.mem.Allocator, url: []const u8, max_bytes: usize) Error![]u8 {
    return getWith(alloc, url, max_bytes, .{});
}

pub fn getWith(alloc: std.mem.Allocator, url: []const u8, max_bytes: usize, opts: Options) Error![]u8 {
    if (builtin.os.tag != .windows) return error.Unsupported;
    return win.get(alloc, url, max_bytes, .{}, opts);
}

/// Czy wolno wysłać żądanie nr `hop` (0 = pierwsze) na `url`.
pub fn urlAllowed(url: []const u8, hop: usize, opts: Options) bool {
    if (manifest.isAllowedUrl(url)) return true;
    return hop == 0 and opts.allow_api_listing and std.mem.eql(u8, url, manifest.releases_api_url);
}

test "net: api.github.com tylko dla listy wydań, tylko w pierwszym żądaniu" {
    const t = std.testing;
    const api = manifest.releases_api_url;
    try t.expect(!urlAllowed(api, 0, .{}));
    try t.expect(urlAllowed(api, 0, .{ .allow_api_listing = true }));
    try t.expect(!urlAllowed(api, 1, .{ .allow_api_listing = true }));
    try t.expect(!urlAllowed("https://api.github.com/repos/snakex21/FerrumScope/releases/latest", 0, .{ .allow_api_listing = true }));
    try t.expect(!urlAllowed("https://api.github.com/repos/evil/x/releases?per_page=30", 0, .{ .allow_api_listing = true }));
    try t.expect(urlAllowed(manifest.latest_manifest_url, 3, .{}));
}

const win = if (builtin.os.tag == .windows) struct {
    const BOOL = std.os.windows.BOOL;
    const HINTERNET = *anyopaque;

    const WINHTTP_ACCESS_TYPE_DEFAULT_PROXY: u32 = 0;
    const WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY: u32 = 4;
    const WINHTTP_FLAG_SECURE: u32 = 0x00800000;
    const WINHTTP_FLAG_REFRESH: u32 = 0x00000100;
    const WINHTTP_OPTION_REDIRECT_POLICY: u32 = 88;
    const WINHTTP_OPTION_REDIRECT_POLICY_NEVER: u32 = 0;
    const WINHTTP_OPTION_DISABLE_FEATURE: u32 = 63;
    const WINHTTP_DISABLE_COOKIES: u32 = 0x00000001;
    const WINHTTP_QUERY_STATUS_CODE: u32 = 19;
    const WINHTTP_QUERY_LOCATION: u32 = 33;
    const WINHTTP_QUERY_FLAG_NUMBER: u32 = 0x20000000;
    const ERROR_WINHTTP_TIMEOUT: u32 = 12002;

    extern "winhttp" fn WinHttpOpen(?[*:0]const u16, u32, ?[*:0]const u16, ?[*:0]const u16, u32) callconv(.winapi) ?HINTERNET;
    extern "winhttp" fn WinHttpCloseHandle(HINTERNET) callconv(.winapi) BOOL;
    extern "winhttp" fn WinHttpSetTimeouts(HINTERNET, i32, i32, i32, i32) callconv(.winapi) BOOL;
    extern "winhttp" fn WinHttpConnect(HINTERNET, [*:0]const u16, u16, u32) callconv(.winapi) ?HINTERNET;
    extern "winhttp" fn WinHttpOpenRequest(HINTERNET, [*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, ?*const ?[*:0]const u16, u32) callconv(.winapi) ?HINTERNET;
    extern "winhttp" fn WinHttpSetOption(HINTERNET, u32, *const anyopaque, u32) callconv(.winapi) BOOL;
    extern "winhttp" fn WinHttpSendRequest(HINTERNET, ?[*]const u16, u32, ?*anyopaque, u32, u32, usize) callconv(.winapi) BOOL;
    extern "winhttp" fn WinHttpReceiveResponse(HINTERNET, ?*anyopaque) callconv(.winapi) BOOL;
    extern "winhttp" fn WinHttpQueryHeaders(HINTERNET, u32, ?[*:0]const u16, ?*anyopaque, *u32, ?*u32) callconv(.winapi) BOOL;
    extern "winhttp" fn WinHttpQueryDataAvailable(HINTERNET, *u32) callconv(.winapi) BOOL;
    extern "winhttp" fn WinHttpReadData(HINTERNET, [*]u8, u32, *u32) callconv(.winapi) BOOL;

    fn lastError() Error {
        const code: u32 = @intFromEnum(std.os.windows.kernel32.GetLastError());
        return if (code == ERROR_WINHTTP_TIMEOUT) error.Timeout else error.Network;
    }

    fn close(h: ?HINTERNET) void {
        if (h) |x| _ = WinHttpCloseHandle(x);
    }

    fn get(alloc: std.mem.Allocator, url_in: []const u8, max_bytes: usize, to: Timeouts, opts: Options) Error![]u8 {
        const session = WinHttpOpen(std.unicode.utf8ToUtf16LeStringLiteral(user_agent), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse
            WinHttpOpen(std.unicode.utf8ToUtf16LeStringLiteral(user_agent), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, null, null, 0) orelse
            return lastError();
        defer close(session);
        if (WinHttpSetTimeouts(session, to.resolve, to.connect, to.send, to.receive) == 0) return lastError();

        var url_buf: [4096]u8 = undefined;
        var url: []const u8 = url_in;
        var hops: usize = 0;
        while (true) : (hops += 1) {
            if (hops > max_redirects) return error.TooManyRedirects;
            if (!urlAllowed(url, hops, opts)) return error.DisallowedUrl;
            const u = manifest.parseHttpsUrl(url).?;
            const host_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, u.host) catch return error.OutOfMemory;
            defer alloc.free(host_w);
            const path_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, u.path) catch return error.OutOfMemory;
            defer alloc.free(path_w);

            const conn = WinHttpConnect(session, host_w, 443, 0) orelse return lastError();
            defer close(conn);
            const req = WinHttpOpenRequest(conn, std.unicode.utf8ToUtf16LeStringLiteral("GET"), path_w, null, null, null, WINHTTP_FLAG_SECURE | WINHTTP_FLAG_REFRESH) orelse return lastError();
            defer close(req);
            const never: u32 = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
            if (WinHttpSetOption(req, WINHTTP_OPTION_REDIRECT_POLICY, &never, 4) == 0) return lastError();
            const no_cookies: u32 = WINHTTP_DISABLE_COOKIES;
            _ = WinHttpSetOption(req, WINHTTP_OPTION_DISABLE_FEATURE, &no_cookies, 4);
            if (WinHttpSendRequest(req, null, 0, null, 0, 0, 0) == 0) return lastError();
            if (WinHttpReceiveResponse(req, null) == 0) return lastError();

            var status: u32 = 0;
            var len: u32 = 4;
            if (WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, null, &status, &len, null) == 0) return lastError();

            switch (status) {
                200 => return readBody(alloc, req, max_bytes),
                301, 302, 303, 307, 308 => {
                    var loc_w: [2048]u16 = undefined;
                    var loc_len: u32 = @sizeOf(@TypeOf(loc_w));
                    if (WinHttpQueryHeaders(req, WINHTTP_QUERY_LOCATION, null, &loc_w, &loc_len, null) == 0) return error.HttpStatus;
                    const loc16 = loc_w[0 .. loc_len / 2];
                    var loc8: [4096]u8 = undefined;
                    const n = std.unicode.utf16LeToUtf8(&loc8, loc16) catch return error.DisallowedUrl;
                    const loc = loc8[0..n];
                    // Adres względny (`/ścieżka`) — ten sam host. Składamy w osobnym
                    // buforze, bo `u.host` może wskazywać w `url_buf`.
                    var next_buf: [4096]u8 = undefined;
                    const next = if (loc.len > 0 and loc[0] == '/' and !(loc.len > 1 and loc[1] == '/'))
                        std.fmt.bufPrint(&next_buf, "https://{s}{s}", .{ u.host, loc }) catch return error.DisallowedUrl
                    else
                        loc;
                    if (next.len > url_buf.len) return error.DisallowedUrl;
                    @memcpy(url_buf[0..next.len], next);
                    url = url_buf[0..next.len];
                },
                404 => return error.NotFound,
                else => return error.HttpStatus,
            }
        }
    }

    fn readBody(alloc: std.mem.Allocator, req: HINTERNET, max_bytes: usize) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        var chunk: [64 * 1024]u8 = undefined;
        while (true) {
            var avail: u32 = 0;
            if (WinHttpQueryDataAvailable(req, &avail) == 0) return lastError();
            if (avail == 0) break;
            const want: u32 = @min(avail, chunk.len);
            var got: u32 = 0;
            if (WinHttpReadData(req, &chunk, want, &got) == 0) return lastError();
            if (got == 0) break;
            if (out.items.len + got > max_bytes) return error.TooLarge;
            out.appendSlice(alloc, chunk[0..got]) catch return error.OutOfMemory;
        }
        return out.toOwnedSlice(alloc) catch error.OutOfMemory;
    }
} else struct {};
