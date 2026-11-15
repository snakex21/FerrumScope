//! Wybór języka interfejsu przy starcie programu (CLI i GUI).
//!
//! Kolejność: jawny wybór (`--lang=`, potem `language` w `data\settings.ini`)
//! → język interfejsu Windows (GetUserDefaultUILanguage → LCIDToLocaleName,
//! zapasowo GetUserDefaultLocaleName) → angielski.

const std = @import("std");
const builtin = @import("builtin");
const i18n = @import("i18n.zig");

const LOCALE_NAME_MAX_LENGTH = 85;

const k32 = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn GetUserDefaultUILanguage() callconv(.winapi) u16;
    extern "kernel32" fn LCIDToLocaleName(lcid: u32, name: [*]u16, len: c_int, flags: u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetUserDefaultLocaleName(name: [*]u16, len: c_int) callconv(.winapi) c_int;
} else struct {};

/// Tag języka systemu (np. `pl-PL`) w `buf`; `null` = nieznany.
pub fn systemTag(buf: []u8) ?[]const u8 {
    if (builtin.os.tag != .windows) {
        const env = std.posix.getenv("LANG") orelse return null;
        const end = std.mem.indexOfAny(u8, env, ".@") orelse env.len;
        const n = @min(end, buf.len);
        @memcpy(buf[0..n], env[0..n]);
        return if (n > 0) buf[0..n] else null;
    }
    var w: [LOCALE_NAME_MAX_LENGTH]u16 = undefined;
    var len = k32.LCIDToLocaleName(k32.GetUserDefaultUILanguage(), &w, w.len, 0);
    if (len <= 1) len = k32.GetUserDefaultLocaleName(&w, w.len);
    if (len <= 1) return null;
    // Nazwy lokalizacji Windows są ASCII (`pl-PL`, `sr-Latn-RS`).
    var n: usize = 0;
    for (w[0..@intCast(len - 1)]) |c| {
        if (n >= buf.len or c == 0 or c > 0x7F) break;
        buf[n] = @intCast(c);
        n += 1;
    }
    return if (n > 0) buf[0..n] else null;
}

/// Kod języka interfejsu: `explicit` (flaga / ustawienie), jeśli niepusty,
/// inaczej język systemu, inaczej `en`. Zawsze zwraca kod z `i18n.locales`.
pub fn resolve(explicit: []const u8) []const u8 {
    const e = std.mem.trim(u8, explicit, " \t\r\n");
    if (e.len > 0 and !std.ascii.eqlIgnoreCase(e, "auto")) return i18n.normalizeCode(e);
    var buf: [LOCALE_NAME_MAX_LENGTH]u8 = undefined;
    if (systemTag(&buf)) |tag| return i18n.normalizeCode(tag);
    return "en";
}

test "i18n system: jawny wybór ma pierwszeństwo, wynik jest zawsze obsługiwany" {
    try std.testing.expectEqualStrings("de", resolve("de-AT"));
    try std.testing.expectEqualStrings("pt-BR", resolve(" pt "));
    try std.testing.expect(i18n.isSupported(resolve("")));
    try std.testing.expect(i18n.isSupported(resolve("auto")));
}
