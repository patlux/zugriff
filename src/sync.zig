//! A lock and a condition for the agent's few background threads, on
//! pthreads (the app links libc anyway).
const std = @import("std");

pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(m: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&m.inner);
    }

    pub fn unlock(m: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&m.inner);
    }
};

pub const Condition = struct {
    inner: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,

    pub fn wait(c: *Condition, m: *Mutex) void {
        _ = std.c.pthread_cond_wait(&c.inner, &m.inner);
    }

    pub fn signal(c: *Condition) void {
        _ = std.c.pthread_cond_signal(&c.inner);
    }

    pub fn broadcast(c: *Condition) void {
        _ = std.c.pthread_cond_broadcast(&c.inner);
    }
};

test "a waiting thread wakes up" {
    const S = struct {
        const Self = @This();
        m: Mutex = .{},
        c: Condition = .{},
        ready: bool = false,
        fn run(s: *Self) void {
            s.m.lock();
            s.ready = true;
            s.m.unlock();
            s.c.signal();
        }
    };
    var s: S = .{};
    const t = try std.Thread.spawn(.{}, S.run, .{&s});
    s.m.lock();
    while (!s.ready) s.c.wait(&s.m);
    s.m.unlock();
    t.join();
}
