//! `ferrumscope update` — sprawdzanie, instalacja, wycofanie, ustawienie.
//!
//! Kody wyjścia `--check`: 0 = aktualna (albo brak wydań), 10 = dostępna
//! nowsza wersja, 1 = błąd. Złe opcje: 2 (jak reszta CLI).

const std = @import("std");
const upd = @import("update.zig");
const settings = @import("../settings.zig");
const t = upd.text.t;

pub const exit_up_to_date: u8 = 0;
pub const exit_available: u8 = 10;
pub const exit_error: u8 = 1;
pub const exit_usage: u8 = 2;

pub fn run(alloc: std.mem.Allocator, args: []const [:0]const u8, out: *std.Io.Writer, err: *std.Io.Writer) u8 {
    return runInner(alloc, args, out, err) catch |e| {
        err.print("ferrumscope update: {s}\n", .{@errorName(e)}) catch {};
        return exit_error;
    };
}

const channel_flag = "--channel=";

pub fn channelName(c: upd.Channel) []const u8 {
    return switch (c) {
        .stable => t.channel_stable,
        .@"test" => t.channel_test,
    };
}

fn has(args: []const [:0]const u8, flag: []const u8) bool {
    for (args) |a| if (std.mem.eql(u8, a, flag)) return true;
    return false;
}

fn runInner(alloc: std.mem.Allocator, args: []const [:0]const u8, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    if (args.len == 0 or has(args, "-h") or has(args, "--help")) {
        try out.writeAll(t.cli_usage);
        return if (args.len == 0) exit_usage else 0;
    }
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "--check") or std.mem.eql(u8, cmd, "--apply")) {
        const apply_mode = std.mem.eql(u8, cmd, "--apply");
        var channel: ?upd.Channel = null;
        var yes = false;
        for (args[1..]) |a| {
            if (apply_mode and std.mem.eql(u8, a, "--yes")) {
                yes = true;
            } else if (std.mem.startsWith(u8, a, channel_flag)) {
                channel = upd.Channel.parse(a[channel_flag.len..]) orelse return badOption(err, a);
            } else return badOption(err, a);
        }
        const ch = channel orelse settings.load().update_channel;
        return if (apply_mode) cmdApply(alloc, ch, yes, out, err) else cmdCheck(alloc, ch, out, err);
    }
    if (std.mem.eql(u8, cmd, "--set-channel")) {
        if (args.len != 2) return badOption(err, cmd);
        const ch = upd.Channel.parse(args[1]) orelse return badOption(err, args[1]);
        var s = settings.load();
        s.update_channel = ch;
        settings.save(s) catch |e| {
            try err.print("{s}{s}\n", .{ t.settings_failed, @errorName(e) });
            return exit_error;
        };
        try out.print("{s}{s}\n", .{ t.channel_set, channelName(ch) });
        return 0;
    }
    if (std.mem.eql(u8, cmd, "--rollback") and args.len == 1) return cmdRollback(out, err);
    if (std.mem.eql(u8, cmd, "--set-auto")) {
        if (args.len != 2) return badOption(err, cmd);
        const on = std.mem.eql(u8, args[1], "on");
        if (!on and !std.mem.eql(u8, args[1], "off")) return badOption(err, args[1]);
        var s = settings.load();
        s.update_check = on;
        settings.save(s) catch |e| {
            try err.print("{s}{s}\n", .{ t.settings_failed, @errorName(e) });
            return exit_error;
        };
        try out.print("{s}\n", .{if (on) t.auto_on else t.auto_off});
        return 0;
    }
    return badOption(err, cmd);
}

fn badOption(err: *std.Io.Writer, what: []const u8) u8 {
    err.print("{s}{s}\n\n{s}", .{ t.cli_bad_option, what, t.cli_usage }) catch {};
    return exit_usage;
}

fn printChannel(out: *std.Io.Writer, channel: upd.Channel) !void {
    try out.print("{s}{s}\n", .{ t.channel_label, channelName(channel) });
}

fn printInfo(out: *std.Io.Writer, m: *const upd.manifest.Manifest) !void {
    try out.print("{s}{s}\n{s}{s}", .{ t.current_version, upd.version.current, t.latest_version, m.version });
    if (m.published.len > 0) try out.print(" ({s})", .{m.published});
    try out.writeAll("\n");
    if (m.notes.len > 0) try out.print("\n{s}\n{s}\n", .{ t.notes_header, std.mem.trimRight(u8, m.notes, " \r\n") });
}

fn cmdCheck(alloc: std.mem.Allocator, channel: upd.Channel, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    try printChannel(out, channel);
    var c = upd.check(alloc, channel) catch |e| {
        try err.print("{s}{s}\n", .{ t.check_failed, @errorName(e) });
        return exit_error;
    };
    defer c.deinit();
    switch (c) {
        .no_releases => {
            try out.print("{s}{s}\n{s}\n", .{ t.current_version, upd.version.current, t.no_releases });
            return exit_up_to_date;
        },
        .up_to_date => |*m| {
            try printInfo(out, m);
            try out.print("\n{s}\n", .{t.up_to_date});
            return exit_up_to_date;
        },
        .available => |*m| {
            try printInfo(out, m);
            try out.print("\n{s}\n", .{t.update_available});
            return exit_available;
        },
    }
}

fn askYes(out: *std.Io.Writer) bool {
    out.writeAll(t.prompt_install) catch return false;
    out.flush() catch return false;
    var buf: [64]u8 = undefined;
    var r = std.fs.File.stdin().reader(&buf);
    const line = r.interface.takeDelimiterExclusive('\n') catch return false;
    const ans = std.mem.trim(u8, line, " \t\r");
    return std.ascii.eqlIgnoreCase(ans, "y") or std.ascii.eqlIgnoreCase(ans, "yes") or
        std.ascii.eqlIgnoreCase(ans, "t") or std.ascii.eqlIgnoreCase(ans, "tak");
}

fn cmdApply(alloc: std.mem.Allocator, channel: upd.Channel, yes: bool, out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    try printChannel(out, channel);
    var c = upd.check(alloc, channel) catch |e| {
        try err.print("{s}{s}\n", .{ t.check_failed, @errorName(e) });
        return exit_error;
    };
    defer c.deinit();
    const m = switch (c) {
        .no_releases => {
            try out.print("{s}\n", .{t.no_releases});
            return 0;
        },
        .up_to_date => |*m| {
            try printInfo(out, m);
            try out.print("\n{s}\n", .{t.up_to_date});
            return 0;
        },
        .available => |*m| m,
    };
    try printInfo(out, m);
    try out.writeAll("\n");
    if (!yes and !askYes(out)) {
        try out.print("{s}\n", .{t.cancelled});
        return 0;
    }
    try out.print("{s}\n", .{t.downloading});
    try out.flush();

    var dir = try upd.apply.openAppDir();
    defer dir.close();
    upd.apply.cleanupLeftovers(dir);
    upd.apply.prepare(alloc, dir, m) catch |e| {
        try err.print("{s}{s}\n", .{ t.prepare_failed, @errorName(e) });
        return exit_error;
    };
    _ = upd.apply.commit(dir, .{}) catch |e| {
        upd.apply.removeStage(dir);
        try err.print("{s}{s}\n", .{ t.apply_failed, @errorName(e) });
        return exit_error;
    };
    try out.print("{s}{s}.\n{s}\n{s}\n", .{ t.applied, m.version, t.backup_hint, t.restart_gui_hint });
    return 0;
}

fn cmdRollback(out: *std.Io.Writer, err: *std.Io.Writer) !u8 {
    var dir = try upd.apply.openAppDir();
    defer dir.close();
    upd.apply.cleanupLeftovers(dir);
    const n = upd.apply.rollback(dir) catch |e| switch (e) {
        error.NoBackup => {
            try out.print("{s}\n", .{t.rollback_none});
            return exit_error;
        },
        else => {
            try err.print("{s}{s}\n", .{ t.rollback_failed, @errorName(e) });
            return exit_error;
        },
    };
    try out.print("{s}{d}\n{s}\n", .{ t.rollback_done, n, t.restart_gui_hint });
    return 0;
}

test "cli: opcje bez sieci" {
    var o: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer o.deinit();
    var e: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer e.deinit();
    const a = std.testing.allocator;
    try std.testing.expectEqual(exit_usage, run(a, &.{}, &o.writer, &e.writer));
    try std.testing.expectEqual(exit_usage, run(a, &.{"--bogus"}, &o.writer, &e.writer));
    try std.testing.expectEqual(exit_usage, run(a, &.{ "--set-auto", "maybe" }, &o.writer, &e.writer));
    try std.testing.expectEqual(exit_usage, run(a, &.{ "--apply", "--force" }, &o.writer, &e.writer));
    try std.testing.expectEqual(exit_usage, run(a, &.{ "--check", "x" }, &o.writer, &e.writer));
    try std.testing.expectEqual(exit_usage, run(a, &.{ "--check", "--channel=beta" }, &o.writer, &e.writer));
    try std.testing.expectEqual(exit_usage, run(a, &.{ "--check", "--yes" }, &o.writer, &e.writer));
    try std.testing.expectEqual(exit_usage, run(a, &.{ "--set-channel", "nightly" }, &o.writer, &e.writer));
    try std.testing.expectEqual(exit_usage, run(a, &.{"--set-channel"}, &o.writer, &e.writer));
    try std.testing.expectEqual(@as(u8, 0), run(a, &.{"--help"}, &o.writer, &e.writer));
}
