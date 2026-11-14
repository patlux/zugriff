//! Log lines with when and who: the local time to the millisecond, the
//! process's role (`agent`, `daemon`, `ui`) and pid, and the time since the
//! process started, before nanoui's usual `info(scope): message`:
//!
//!     16:45:12.345 ui 51570 +86ms info(zugriff): panel configured
//!
//! The roles matter with `--unload-mode process`, where the daemon and the
//! UI process write into the same terminal.
const std = @import("std");

/// The process's part, set once by `main` before anything logs.
var role: []const u8 = "cli";
/// `CLOCK_MONOTONIC` when `main` started, in µs.
var start_us: i64 = 0;

/// At the start of `main`: the time since then is in every line.
pub fn start() void {
    start_us = monotonicUs();
}

pub fn setRole(r: []const u8) void {
    role = r;
}

/// Milliseconds since `start`.
pub fn sinceStartMs() i64 {
    return @divTrunc(monotonicUs() - start_us, 1000);
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var buffer: [64]u8 = undefined;
    const t = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    var stamp: [16]u8 = undefined;
    // A log line that cannot be written has nowhere else to go.
    t.setColor(.dim) catch return;
    t.writer.print("{s} {s} {d} +{d}ms ", .{ clock(&stamp), role, std.c.getpid(), sinceStartMs() }) catch return;
    t.setColor(.reset) catch return;
    std.log.defaultLogFileTerminal(level, scope, format, args, t) catch return;
}

/// The local wall clock as `HH:MM:SS.mmm`.
fn clock(buf: *[16]u8) []const u8 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    const secs: c_long = @intCast(ts.sec);
    var tm: Tm = undefined;
    if (localtime_r(&secs, &tm) == null) return "--:--:--.---";
    const ms = @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
    return std.mem.print(buf, "{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        @as(u32, @intCast(tm.hour)),
        @as(u32, @intCast(tm.min)),
        @as(u32, @intCast(tm.sec)),
        @as(u32, @intCast(ms)),
    }) catch "--:--:--.---";
}

fn monotonicUs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.us_per_s + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_us);
}

/// `struct tm` of macOS.
const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const c_long, out: *Tm) ?*Tm;

test "the clock reads as HH:MM:SS.mmm" {
    var buf: [16]u8 = undefined;
    const s = clock(&buf);
    try std.testing.expectEqual(@as(usize, 12), s.len);
    try std.testing.expectEqual(@as(u8, ':'), s[2]);
    try std.testing.expectEqual(@as(u8, '.'), s[8]);
}
