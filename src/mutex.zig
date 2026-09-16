const std = @import("std");

pub const SpinMutex = struct {
    const Self = @This();

    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    pub fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *SpinMutex) void {
        self.state.store(0, .release);
    }
};

// --- Tests ---

test "spin mutex lock and unlock toggle the state" {
    var m = SpinMutex{};
    try std.testing.expectEqual(@as(u8, 0), m.state.load(.monotonic));
    m.lock();
    try std.testing.expectEqual(@as(u8, 1), m.state.load(.monotonic));
    m.unlock();
    try std.testing.expectEqual(@as(u8, 0), m.state.load(.monotonic));
    // Re-acquire after release works.
    m.lock();
    try std.testing.expectEqual(@as(u8, 1), m.state.load(.monotonic));
    m.unlock();
}

test "spin mutex serializes concurrent increments" {
    const Worker = struct {
        fn run(m: *SpinMutex, counter: *u64) void {
            var i: usize = 0;
            while (i < 2000) : (i += 1) {
                m.lock();
                counter.* += 1;
                m.unlock();
            }
        }
    };
    var m = SpinMutex{};
    var counter: u64 = 0;
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{ &m, &counter });
    }
    for (threads) |t| t.join();
    try std.testing.expectEqual(@as(u64, 8000), counter);
    try std.testing.expectEqual(@as(u8, 0), m.state.load(.monotonic));
}
