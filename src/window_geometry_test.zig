const std = @import("std");
const geometry = @import("window_geometry.zig");

// A fake native window deliberately pauses between its two dimension writes.
// This exercises the same external-mutex publication contract used by Host.
const Harness = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    publication: geometry.Publication = .{},
    native_width: i32 = 800,
    native_height: i32 = 600,
    ready: std.atomic.Value(bool) = .init(false),
    stop: std.atomic.Value(bool) = .init(false),
    reads: std.atomic.Value(usize) = .init(0),
    failed: std.atomic.Value(bool) = .init(false),

    fn resize(self: *Harness, width: i32, height: i32) void {
        self.native_width = width;
        std.Thread.yield() catch {};
        self.native_height = height;
    }

    fn raster(self: *Harness) void {
        self.ready.store(true, .release);
        while (!self.stop.load(.acquire)) {
            self.mutex.lockUncancelable(self.io);
            const m = self.publication.metrics;
            const initial = m.width == 800 and m.height == 600 and m.pixel_ratio == 1;
            const configure = m.width == 1002 and m.height == 752 and m.pixel_ratio == 1.25;
            const scale = m.width == 1602 and m.height == 1202 and m.pixel_ratio == 2;
            const native_update = m.width == 960 and m.height == 720 and m.pixel_ratio == 1.5;
            if ((!initial and !configure and !scale and !native_update) or
                m.width != @as(usize, @intCast(self.native_width)) or
                m.height != @as(usize, @intCast(self.native_height)))
            {
                self.failed.store(true, .release);
            }
            self.mutex.unlock(self.io);
            _ = self.reads.fetchAdd(1, .monotonic);
        }
    }
};

test "raster sees coherent configure scale and native updates during resize" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var harness: Harness = .{ .io = threaded.io() };
    {
        const raster = try std.Thread.spawn(.{}, Harness.raster, .{&harness});
        defer {
            harness.stop.store(true, .release);
            raster.join();
        }
        while (!harness.ready.load(.acquire) or harness.reads.load(.monotonic) == 0) {
            std.Thread.yield() catch {};
        }
        const updates = [_]geometry.Metrics{
            geometry.Metrics.fromLogical(801, 601, 150),
            geometry.Metrics.fromLogical(801, 601, 240),
            geometry.Metrics.fromLogical(640, 480, 180),
        };
        for (0..3000) |index| {
            harness.mutex.lockUncancelable(harness.io);
            harness.publication.publishLocked(updates[index % updates.len], &harness, Harness.resize);
            harness.mutex.unlock(harness.io);
            // A Flutter metrics callback runs here, outside the lock, and may reenter.
            harness.mutex.lockUncancelable(harness.io);
            const callback_snapshot = harness.publication.metrics;
            harness.mutex.unlock(harness.io);
            try std.testing.expectEqual(updates[index % updates.len], callback_snapshot);
            std.Thread.yield() catch {};
        }
    }
    try std.testing.expect(!harness.failed.load(.acquire));
    try std.testing.expect(harness.reads.load(.monotonic) > 0);
}
