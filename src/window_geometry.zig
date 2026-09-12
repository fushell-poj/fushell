//! Geometry shared between platform resize and raster presentation.
//! Callers serialize Publication access and native resize with the same mutex.
const std = @import("std");

/// Layer-shell client requests, independent of compositor-configured dimensions.
/// Zero asks the compositor to choose that dimension from the layer anchors.
pub const LayerSizeRequest = struct {
    width: u32 = 0,
    height: u32 = 0,

    pub fn updated(self: LayerSizeRequest, width: ?i32, height: ?i32) LayerSizeRequest {
        return .{
            .width = if (width) |value| @intCast(@max(value, 0)) else self.width,
            .height = if (height) |value| @intCast(@max(value, 0)) else self.height,
        };
    }
};

/// A zero layer configure dimension delegates that axis to the client.
/// Keep the retained request separate from the resulting effective dimension.
pub fn resolveLayerDimension(configured: u32, requested: u32, previous: i32, fallback: i32) i32 {
    const chosen = if (configured > 0) configured else requested;
    if (chosen > 0) return @intCast(@min(chosen, std.math.maxInt(i32)));
    return if (previous > 0) previous else @max(fallback, 1);
}

test "layer configure resolves zero axes independently without changing requests" {
    var request = (LayerSizeRequest{}).updated(640, 32);
    try std.testing.expectEqual(@as(i32, 640), resolveLayerDimension(0, request.width, 0, 800));
    try std.testing.expectEqual(@as(i32, 32), resolveLayerDimension(0, request.height, 0, 600));
    // Mixed configure: compositor chooses width, client chooses requested height.
    try std.testing.expectEqual(@as(i32, 1280), resolveLayerDimension(1280, request.width, 640, 800));
    try std.testing.expectEqual(@as(i32, 32), resolveLayerDimension(0, request.height, 32, 600));
    request = request.updated(960, null);
    try std.testing.expectEqual(@as(i32, 960), resolveLayerDimension(0, request.width, 1280, 800));
    try std.testing.expectEqual(@as(u32, 32), request.height);
    request = request.updated(0, null);
    try std.testing.expectEqual(@as(i32, 1706), resolveLayerDimension(0, request.width, 1706, 800));
    try std.testing.expectEqual(@as(u32, 0), request.width);
}

test "automatic initial layer configure uses positive bounded fallback" {
    try std.testing.expectEqual(@as(i32, 800), resolveLayerDimension(0, 0, 0, 800));
    try std.testing.expectEqual(@as(i32, 600), resolveLayerDimension(0, 0, 0, 600));
    try std.testing.expectEqual(@as(i32, 1), resolveLayerDimension(0, 0, -1, 0));
    try std.testing.expectEqual(std.math.maxInt(i32), resolveLayerDimension(std.math.maxInt(u32), 32, 0, 800));
    try std.testing.expectEqual(std.math.maxInt(i32), resolveLayerDimension(0, std.math.maxInt(u32), 0, 800));
}

pub const Metrics = struct {
    width: usize,
    height: usize,
    pixel_ratio: f64,

    pub fn fromLogical(width: i32, height: i32, scale_120: u32) Metrics {
        const scale = if (scale_120 == 0) 120 else scale_120;
        return .{
            .width = physicalFromLogical(width, scale),
            .height = physicalFromLogical(height, scale),
            .pixel_ratio = @as(f64, @floatFromInt(scale)) / 120.0,
        };
    }
};

fn physicalFromLogical(size: i32, scale_120: u32) usize {
    const logical: u64 = @intCast(@max(size, 1));
    const physical = (logical * scale_120 + 119) / 120;
    // wl_egl_window dimensions are signed 32-bit integers.
    return @intCast(@min(physical, std.math.maxInt(i32)));
}

pub const Publication = struct {
    metrics: Metrics = Metrics.fromLogical(800, 600, 120),

    /// The caller holds the presentation mutex through resize and publication.
    /// resize must be synchronous and must not dispatch events or call Flutter.
    pub fn publishLocked(self: *Publication, next: Metrics, context: anytype, comptime resize: anytype) void {
        if (self.metrics.width != next.width or self.metrics.height != next.height) {
            resize(context, @as(i32, @intCast(next.width)), @as(i32, @intCast(next.height)));
        }
        // Publish scale even when rounding leaves both physical dimensions unchanged.
        self.metrics = next;
    }
};

test "fractional geometry rounds upward and bounds native dimensions" {
    const m = Metrics.fromLogical(801, 601, 150);
    try std.testing.expectEqual(@as(usize, 1002), m.width);
    try std.testing.expectEqual(@as(usize, 752), m.height);
    try std.testing.expectEqual(@as(f64, 1.25), m.pixel_ratio);
    const below_one = Metrics.fromLogical(801, 601, 90);
    try std.testing.expectEqual(@as(usize, 601), below_one.width);
    try std.testing.expectEqual(@as(usize, 451), below_one.height);
    try std.testing.expectEqual(@as(f64, 0.75), below_one.pixel_ratio);
    const smallest_scale = Metrics.fromLogical(1, 1, 1);
    try std.testing.expectEqual(@as(usize, 1), smallest_scale.width);
    try std.testing.expectEqual(@as(f64, 1.0 / 120.0), smallest_scale.pixel_ratio);
    const empty = Metrics.fromLogical(0, -1, 0);
    try std.testing.expectEqual(@as(usize, 1), empty.width);
    try std.testing.expectEqual(@as(usize, 1), empty.height);
    const huge = Metrics.fromLogical(std.math.maxInt(i32), std.math.maxInt(i32), std.math.maxInt(u32));
    try std.testing.expectEqual(@as(usize, std.math.maxInt(i32)), huge.width);
}

test "publication follows native resize and includes scale-only changes" {
    const Native = struct {
        publication: *Publication,
        calls: usize = 0,
        width: i32 = 800,
        height: i32 = 600,

        fn resize(self: *@This(), width: i32, height: i32) void {
            std.debug.assert(self.publication.metrics.width == @as(usize, @intCast(self.width)));
            std.debug.assert(self.publication.metrics.height == @as(usize, @intCast(self.height)));
            self.width = width;
            self.height = height;
            self.calls += 1;
        }
    };
    var publication: Publication = .{};
    var native: Native = .{ .publication = &publication };
    publication.publishLocked(Metrics.fromLogical(100, 200, 240), &native, Native.resize);
    try std.testing.expectEqual(@as(i32, 200), native.width);
    try std.testing.expectEqual(@as(i32, 400), native.height);
    try std.testing.expectEqual(@as(usize, 1), native.calls);
    publication.publishLocked(Metrics.fromLogical(200, 400, 120), &native, Native.resize);
    try std.testing.expectEqual(@as(usize, 1), native.calls);
    try std.testing.expectEqual(@as(f64, 1), publication.metrics.pixel_ratio);
}
