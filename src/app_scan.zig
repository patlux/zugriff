//! Rescans of the installed applications.
//!
//! The agent scans once at startup and again on every show, so an app that
//! was installed or removed while the agent runs is right the next time the
//! palette opens. Scans run on their own thread; a show only raises a flag
//! and never waits for the answer.
const std = @import("std");
const sync = @import("sync.zig");

/// Runs `scan` on its thread whenever `rescan` asks, and hands each result
/// to `deliver`, on that thread. `T` is what a scan returns.
pub fn Scanner(comptime T: type) type {
    return struct {
        const Self = @This();

        ctx: *anyopaque,
        scan: *const fn (ctx: *anyopaque) ?T,
        deliver: *const fn (ctx: *anyopaque, result: T) void,
        mutex: sync.Mutex = .{},
        cond: sync.Condition = .{},
        pending: bool = false,
        stopping: bool = false,
        thread: ?std.Thread = null,

        pub fn start(s: *Self) !void {
            s.thread = try std.Thread.spawn(.{}, serve, .{s});
        }

        /// Asks for a fresh result; returns at once.
        pub fn rescan(s: *Self) void {
            s.mutex.lock();
            s.pending = true;
            s.mutex.unlock();
            s.cond.signal();
        }

        /// Ends the thread after the scan it is in, and waits for it.
        pub fn stop(s: *Self) void {
            s.mutex.lock();
            s.stopping = true;
            s.mutex.unlock();
            s.cond.signal();
            if (s.thread) |t| t.join();
            s.thread = null;
        }

        fn serve(s: *Self) void {
            while (true) {
                s.mutex.lock();
                while (!s.pending and !s.stopping) s.cond.wait(&s.mutex);
                if (s.stopping) {
                    s.mutex.unlock();
                    return;
                }
                // Requests that queued up before this scan get its answer;
                // one that arrives during the scan earns another scan: its
                // app may have landed after the folder was read.
                s.pending = false;
                s.mutex.unlock();
                if (s.scan(s.ctx)) |result| s.deliver(s.ctx, result);
            }
        }
    };
}

const testing = std.testing;

const Fake = struct {
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    installed: usize = 1,
    scans: usize = 0,
    results: [8]usize = undefined,
    delivered: usize = 0,
    /// The scan waits until the test opens the gate.
    gate: usize = std.math.maxInt(usize),

    fn scan(ctx: *anyopaque) ?usize {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.mutex.lock();
        defer f.mutex.unlock();
        f.scans += 1;
        f.cond.broadcast();
        while (f.scans > f.gate) f.cond.wait(&f.mutex);
        return f.installed;
    }

    fn deliver(ctx: *anyopaque, n: usize) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.mutex.lock();
        defer f.mutex.unlock();
        f.results[f.delivered] = n;
        f.delivered += 1;
        f.cond.broadcast();
    }

    fn waitDelivered(f: *Fake, n: usize) void {
        f.mutex.lock();
        defer f.mutex.unlock();
        while (f.delivered < n) f.cond.wait(&f.mutex);
    }
};

test "a rescan finds an app installed since the last scan" {
    var fake: Fake = .{ .gate = 100 };
    var s: Scanner(usize) = .{ .ctx = &fake, .scan = Fake.scan, .deliver = Fake.deliver };
    try s.start();
    defer s.stop();
    s.rescan();
    fake.waitDelivered(1);
    fake.mutex.lock();
    fake.installed = 2;
    fake.mutex.unlock();
    s.rescan();
    fake.waitDelivered(2);
    try testing.expectEqual(@as(usize, 1), fake.results[0]);
    try testing.expectEqual(@as(usize, 2), fake.results[1]);
}

test "requests during a scan collapse into one more scan" {
    var fake: Fake = .{ .gate = 0 };
    var s: Scanner(usize) = .{ .ctx = &fake, .scan = Fake.scan, .deliver = Fake.deliver };
    try s.start();
    s.rescan();
    // The first scan is running and held at the gate.
    fake.mutex.lock();
    while (fake.scans < 1) fake.cond.wait(&fake.mutex);
    fake.mutex.unlock();
    for (0..5) |_| s.rescan();
    fake.mutex.lock();
    fake.gate = 100;
    fake.mutex.unlock();
    fake.cond.broadcast();
    fake.waitDelivered(2);
    s.stop();
    try testing.expectEqual(@as(usize, 2), fake.scans);
    try testing.expectEqual(@as(usize, 2), fake.delivered);
}
