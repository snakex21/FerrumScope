//! Aktualizator w oknie GUI.
//!
//! Wszystko, co trwa (sieć, weryfikacja, rozpakowanie), dzieje się w wątku
//! roboczym; wynik wraca do okna komunikatem `WM_UPDATE` (WM_APP + 0x55)
//! z wskaźnikiem na `Msg` w LPARAM. Okno (wątek główny) pokazuje pytania
//! i wykonuje szybką fazę `commit` (same zmiany nazw), więc zamknięcie okna
//! w trakcie pobierania nie zostawia programu w połowie podmiany.
//!
//! Ponowne uruchomienie po aktualizacji: stary proces startuje nowy
//! `ferrumscope-gui.exe --post-update=<pid>` (ta sama ścieżka — plik jest już
//! nowy) i zamyka okno. Nowy proces czeka, aż stary się zakończy, sprząta
//! pozostałości i informuje o nowej wersji. Kopie `.old` zostają do
//! `ferrumscope update --rollback`.
//!
//! Sprawdzanie przy starcie: tylko gdy `update_check` w `data\settings.ini`
//! i najwyżej raz na 24 h (`last_update_check`), w tle, bez żadnego
//! komunikatu przy błędzie. Ustawienia czyta i zapisuje wyłącznie wątek główny.

const std = @import("std");
const w = @import("../gui/win32.zig");
const upd = @import("update.zig");
const settings = @import("../settings.zig");
const t = upd.text.t;

const L = std.unicode.utf8ToUtf16LeStringLiteral;
const gpa = std.heap.page_allocator;

pub const WM_UPDATE: u32 = 0x8000 + 0x55;
pub const ID_CHECK: u16 = 110;
pub const ID_AUTO: u16 = 111;
pub const ID_CHANNEL: u16 = 112;

const post_update_flag = "--post-update=";

extern "user32" fn PostMessageW(?w.HWND, u32, w.WPARAM, w.LPARAM) callconv(.winapi) w.BOOL;
extern "user32" fn DestroyWindow(w.HWND) callconv(.winapi) w.BOOL;
extern "kernel32" fn OpenProcess(u32, w.BOOL, u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WaitForSingleObject(*anyopaque, u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(*anyopaque) callconv(.winapi) w.BOOL;

const SYNCHRONIZE: u32 = 0x00100000;
const MB_YESNO: u32 = 0x4;
const MB_ICONQUESTION: u32 = 0x20;
const IDYES: i32 = 6;
const BM_SETCHECK: u32 = 0x00F1;

const Job = enum { auto_check, manual_check, prepare };

const Msg = struct {
    job: Job,
    check: ?upd.Check = null,
    err: ?anyerror = null,
};

/// Stan wątku głównego.
var busy = false;
var check_btn: ?w.HWND = null;
/// Manifest czekający na decyzję / instalację (własność wątku głównego;
/// w czasie `prepare` czyta go tylko wątek roboczy).
var pending: ?upd.Check = null;

// ---------------------------------------------------------------------------
// Kontrolki
// ---------------------------------------------------------------------------

/// Po utworzeniu przycisku i pola wyboru na zakładce „O programie”.
pub fn initControls(btn: ?w.HWND, auto_box: ?w.HWND, channel_box: ?w.HWND) void {
    check_btn = btn;
    const s = settings.load();
    if (auto_box) |h| _ = w.SendMessageW(h, BM_SETCHECK, @intFromBool(s.update_check), 0);
    if (channel_box) |h| _ = w.SendMessageW(h, BM_SETCHECK, @intFromBool(s.update_channel == .@"test"), 0);
}

/// Pole „Kanał testowy”: zaznaczone = `test`, puste = `stable`.
pub fn onChannelToggled(channel_box: ?w.HWND) void {
    const h = channel_box orelse return;
    var s = settings.load();
    s.update_channel = if (w.SendMessageW(h, w.BM_GETCHECK, 0, 0) == w.BST_CHECKED) .@"test" else .stable;
    settings.save(s) catch {};
}

pub fn onAutoToggled(auto_box: ?w.HWND) void {
    const h = auto_box orelse return;
    var s = settings.load();
    s.update_check = w.SendMessageW(h, w.BM_GETCHECK, 0, 0) == w.BST_CHECKED;
    settings.save(s) catch {};
}

pub fn onCheckClicked(hwnd: w.HWND) void {
    if (busy) return;
    startWorker(hwnd, .manual_check);
}

// ---------------------------------------------------------------------------
// Start programu
// ---------------------------------------------------------------------------

/// Wywoływane po pokazaniu okna. Obsługuje `--post-update=<pid>` albo
/// uruchamia ciche sprawdzanie przy starcie.
pub fn onStart(hwnd: w.HWND, cmd: []const u16) void {
    if (postUpdatePid(cmd)) |pid| {
        if (OpenProcess(SYNCHRONIZE, 0, pid)) |h| {
            _ = WaitForSingleObject(h, 15_000);
            _ = CloseHandle(h);
        }
        if (upd.apply.openAppDir()) |d| {
            var dir = d;
            upd.apply.cleanupLeftovers(dir);
            dir.close();
        } else |_| {}
        box(hwnd, &.{ t.gui_updated, upd.version.current, "." }, w.MB_OK | w.MB_ICONINFORMATION);
        return;
    }
    const s = settings.load();
    if (upd.shouldAutoCheck(s, std.time.timestamp())) startWorker(hwnd, .auto_check);
}

fn postUpdatePid(cmd: []const u16) ?u32 {
    const key = L(post_update_flag);
    const at = std.mem.indexOf(u16, cmd, key) orelse return null;
    var pid: u32 = 0;
    var n: usize = 0;
    for (cmd[at + key.len ..]) |c| {
        if (c < '0' or c > '9') break;
        pid = std.math.mul(u32, pid, 10) catch return null;
        pid = std.math.add(u32, pid, c - '0') catch return null;
        n += 1;
    }
    return if (n == 0) null else pid;
}

// ---------------------------------------------------------------------------
// Wątek roboczy
// ---------------------------------------------------------------------------

fn startWorker(hwnd: w.HWND, job: Job) void {
    busy = true;
    if (job != .auto_check) if (check_btn) |b| {
        _ = w.EnableWindow(b, 0);
    };
    // Kanał czyta wątek główny (ustawień nie dotyka wątek roboczy).
    const channel = settings.load().update_channel;
    const th = std.Thread.spawn(.{}, worker, .{ hwnd, job, channel }) catch {
        finish();
        return;
    };
    th.detach();
}

fn finish() void {
    busy = false;
    if (check_btn) |b| _ = w.EnableWindow(b, 1);
}

fn worker(hwnd: w.HWND, job: Job, channel: upd.Channel) void {
    const msg = gpa.create(Msg) catch return;
    msg.* = .{ .job = job };
    switch (job) {
        .auto_check, .manual_check => {
            if (upd.check(gpa, channel)) |c| {
                msg.check = c;
            } else |e| msg.err = e;
        },
        .prepare => {
            const m: *const upd.manifest.Manifest = &pending.?.available;
            if (upd.apply.openAppDir()) |d| {
                var dir = d;
                defer dir.close();
                upd.apply.cleanupLeftovers(dir);
                upd.apply.prepare(gpa, dir, m) catch |e| {
                    msg.err = e;
                };
            } else |e| msg.err = e;
        },
    }
    if (PostMessageW(hwnd, WM_UPDATE, 0, @bitCast(@intFromPtr(msg))) == 0) {
        // Okno już nie istnieje — sprzątamy sami.
        if (msg.check) |*c| c.deinit();
        gpa.destroy(msg);
    }
}

// ---------------------------------------------------------------------------
// Wyniki (wątek główny)
// ---------------------------------------------------------------------------

pub fn onMessage(hwnd: w.HWND, lparam: w.LPARAM) void {
    const msg: *Msg = @ptrFromInt(@as(usize, @bitCast(lparam)));
    defer gpa.destroy(msg);
    switch (msg.job) {
        .auto_check, .manual_check => onCheckResult(hwnd, msg),
        .prepare => onPrepared(hwnd, msg.err),
    }
}

fn recordCheck() void {
    var s = settings.load();
    s.last_update_check = std.time.timestamp();
    settings.save(s) catch {};
}

fn onCheckResult(hwnd: w.HWND, msg: *Msg) void {
    const manual = msg.job == .manual_check;
    recordCheck();
    if (msg.err) |e| {
        finish();
        if (manual) box(hwnd, &.{ t.check_failed, @errorName(e) }, w.MB_OK | w.MB_ICONWARNING);
        return;
    }
    var c = msg.check.?;
    switch (c) {
        .no_releases => {
            finish();
            if (manual) box(hwnd, &.{ t.current_version, upd.version.current, "\n\n", t.no_releases }, w.MB_OK | w.MB_ICONINFORMATION);
        },
        .up_to_date => |m| {
            finish();
            if (manual) box(hwnd, &.{ t.current_version, upd.version.current, "\n", t.latest_version, m.version, "\n\n", t.up_to_date }, w.MB_OK | w.MB_ICONINFORMATION);
            c.deinit();
            return;
        },
        .available => |m| {
            const notes = std.mem.trimRight(u8, m.notes, " \r\n");
            const has_notes = notes.len > 0;
            const yes = askBox(hwnd, &.{
                t.update_available,
                "\n\n",
                t.current_version,
                upd.version.current,
                "\n",
                t.latest_version,
                m.version,
                "\n",
                if (has_notes) "\n" else "",
                if (has_notes) t.notes_header else "",
                if (has_notes) "\n" else "",
                notes,
                "\n\n",
                t.gui_ask_install,
            });
            if (!yes) {
                c.deinit();
                finish();
                return;
            }
            if (pending) |*p| p.deinit();
            pending = c;
            if (check_btn) |b| _ = w.EnableWindow(b, 0);
            const th = std.Thread.spawn(.{}, worker, .{ hwnd, Job.prepare, upd.Channel.stable }) catch |e| {
                onPrepared(hwnd, e);
                return;
            };
            th.detach();
            return;
        },
    }
}

fn onPrepared(hwnd: w.HWND, err: ?anyerror) void {
    defer {
        if (pending) |*p| p.deinit();
        pending = null;
        finish();
    }
    if (err) |e| {
        box(hwnd, &.{ t.prepare_failed, @errorName(e) }, w.MB_OK | w.MB_ICONWARNING);
        return;
    }
    var dir = upd.apply.openAppDir() catch |e| {
        box(hwnd, &.{ t.apply_failed, @errorName(e) }, w.MB_OK | w.MB_ICONWARNING);
        return;
    };
    defer dir.close();
    _ = upd.apply.commit(dir, .{}) catch |e| {
        upd.apply.removeStage(dir);
        box(hwnd, &.{ t.apply_failed, @errorName(e) }, w.MB_OK | w.MB_ICONWARNING);
        return;
    };
    restart(hwnd);
}

/// Start nowej wersji (ta sama ścieżka) z `--post-update=<pid>` i zamknięcie okna.
fn restart(hwnd: w.HWND) void {
    var pb: [std.fs.max_path_bytes]u8 = undefined;
    const exe = std.fs.selfExePath(&pb) catch {
        box(hwnd, &.{t.gui_restart_failed}, w.MB_OK | w.MB_ICONWARNING);
        return;
    };
    var ab: [32]u8 = undefined;
    const arg = std.fmt.bufPrint(&ab, post_update_flag ++ "{d}", .{std.os.windows.GetCurrentProcessId()}) catch unreachable;
    var child = std.process.Child.init(&.{ exe, arg }, gpa);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        box(hwnd, &.{t.gui_restart_failed}, w.MB_OK | w.MB_ICONWARNING);
        return;
    };
    _ = DestroyWindow(hwnd);
}

// ---------------------------------------------------------------------------
// MessageBox z kawałków UTF-8
// ---------------------------------------------------------------------------

fn boxRaw(hwnd: w.HWND, parts: []const []const u8, flags: u32) i32 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    for (parts) |p| buf.appendSlice(gpa, p) catch return 0;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(gpa, buf.items) catch return 0;
    defer gpa.free(wide);
    const caption = std.unicode.utf8ToUtf16LeAllocZ(gpa, t.gui_title) catch return 0;
    defer gpa.free(caption);
    return w.MessageBoxW(hwnd, wide, caption, flags);
}

fn box(hwnd: w.HWND, parts: []const []const u8, flags: u32) void {
    _ = boxRaw(hwnd, parts, flags);
}

fn askBox(hwnd: w.HWND, parts: []const []const u8) bool {
    return boxRaw(hwnd, parts, MB_YESNO | MB_ICONQUESTION) == IDYES;
}

test "gui: --post-update=<pid>" {
    try std.testing.expectEqual(@as(?u32, 1234), postUpdatePid(L("ferrumscope-gui.exe --post-update=1234 --tab=about")));
    try std.testing.expectEqual(@as(?u32, null), postUpdatePid(L("ferrumscope-gui.exe --post-update=")));
    try std.testing.expectEqual(@as(?u32, null), postUpdatePid(L("ferrumscope-gui.exe")));
    try std.testing.expectEqual(@as(?u32, null), postUpdatePid(L("--post-update=99999999999")));
}
