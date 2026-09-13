const std = @import("std");
const channel = @import("surface_channel.zig");
const Zone = channel.LayerExclusiveZone;
const auto: Zone = .auto;

test "auto reservation selects exactly the eight unique edge anchor sets" {
    for (0..16) |bits| {
        const a: channel.AnchorMask = @bitCast(@as(u8, @intCast(bits)));
        const count = @popCount(@as(u8, @intCast(bits)));
        const valid = count == 1 or count == 3;
        try std.testing.expectEqual(valid, Zone.exclusiveEdge(a) != null);
        if (valid) try auto.validate(a) else try std.testing.expectError(error.InvalidSurfaceField, auto.validate(a));
    }
}

test "auto reservation uses logical extent plus only opposite margin on all edges" {
    const margins: channel.Margins = .{ .top = 8, .right = 11, .bottom = 3, .left = 5 };
    const cases = [_]struct { a: channel.AnchorMask, zone: i32 }{
        .{ .a = .{ .top = true }, .zone = 51 },
        .{ .a = .{ .top = true, .left = true, .right = true }, .zone = 51 },
        .{ .a = .{ .bottom = true }, .zone = 56 },
        .{ .a = .{ .bottom = true, .left = true, .right = true }, .zone = 56 },
        .{ .a = .{ .left = true }, .zone = 111 },
        .{ .a = .{ .left = true, .top = true, .bottom = true }, .zone = 111 },
        .{ .a = .{ .right = true }, .zone = 105 },
        .{ .a = .{ .right = true, .top = true, .bottom = true }, .zone = 105 },
    };
    for (cases) |case| try std.testing.expectEqual(case.zone, auto.resolve(case.a, margins, 100, 48));
    try std.testing.expectEqual(@as(i32, 48), auto.resolve(.{ .top = true }, .{ .top = 8 }, 100, 48));
}

test "auto reservation saturates negative and overflowing totals without ignore sentinel" {
    const a: channel.AnchorMask = .{ .top = true };
    try std.testing.expectEqual(@as(i32, 0), auto.resolve(a, .{ .bottom = -49 }, 100, 48));
    try std.testing.expectEqual(@as(i32, 0), auto.resolve(a, .{ .bottom = std.math.minInt(i32) }, 100, 48));
    try std.testing.expectEqual(@as(i32, 47), auto.resolve(a, .{ .bottom = -1 }, 100, 48));
    try std.testing.expectEqual(std.math.maxInt(i32), auto.resolve(a, .{ .bottom = 10 }, 100, std.math.maxInt(i32)));
    try std.testing.expectEqual(@as(i32, 0), auto.resolve(a, .{ .bottom = 10 }, 100, 0));
}

test "zero requested axes require opposite anchors for every reservation mode" {
    for ([_]Zone{ .auto, .none, .ignore_other_zones, .{ .fixed = 48 } }) |mode| {
        try mode.validateSize(.{ .top = true, .left = true, .right = true }, 0, 48);
        try mode.validateSize(.{ .left = true, .top = true, .bottom = true }, 48, 0);
        try std.testing.expectError(error.InvalidSurfaceField, mode.validateSize(.{ .top = true }, 0, 48));
        try std.testing.expectError(error.InvalidSurfaceField, mode.validateSize(.{ .top = true, .left = true, .right = true }, 0, 0));
    }
}

test "fixed none and ignore reservation never depend on geometry" {
    for ([_]Zone{ .none, .ignore_other_zones, .{ .fixed = 48 } }, [_]i32{ 0, -1, 48 }) |mode, value| {
        try mode.validate(.{});
        try std.testing.expectEqual(value, mode.resolve(.{}, .{ .top = 99 }, 500, 80));
    }
    try std.testing.expectError(error.InvalidSurfaceField, (Zone{ .fixed = -1 }).validate(.{}));
    try std.testing.expectError(error.InvalidSurfaceField, (Zone{ .fixed = 0 }).validate(.{}));
}

test "exclusive zone wire defaults none and omitted update preserves mode" {
    const request = try channel.parseRequest(std.testing.allocator,
        \\{"id":1,"method":"window.open","role":{"kind":"layer","namespace":"panel","layer":"top","anchors":["top","left","right"],"height":48}}
    );
    defer request.deinit(std.testing.allocator);
    try std.testing.expectEqual(Zone.none, request.open_window.role.layer.exclusive_zone);
    const update = try channel.parseRequest(std.testing.allocator,
        \\{"id":2,"method":"layer.update","windowId":1,"update":{"height":56}}
    );
    defer update.deinit(std.testing.allocator);
    try std.testing.expect(update.update_layer.update.exclusive_zone == null);
}

test "exclusive zone wire accepts only auto or supported integers" {
    const values = [_][]const u8{ "-1", "0", "48", "2147483647", "\"auto\"" };
    const modes = [_]Zone{ .ignore_other_zones, .none, .{ .fixed = 48 }, .{ .fixed = std.math.maxInt(i32) }, .auto };
    for (values, modes) |value, mode| {
        const json = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":1,\"method\":\"layer.update\",\"windowId\":1,\"update\":{{\"exclusiveZone\":{s}}}}}", .{value});
        defer std.testing.allocator.free(json);
        const request = try channel.parseRequest(std.testing.allocator, json);
        defer request.deinit(std.testing.allocator);
        try std.testing.expectEqualDeep(mode, request.update_layer.update.exclusive_zone.?);
    }
}

test "exclusive zone wire rejects invalid values and ambiguous auto create" {
    for ([_][]const u8{ "-2", "-2147483649", "2147483648", "1.0", "null", "true", "{}", "[]", "\"none\"", "\"AUTO\"", "\"-1\"" }) |value| {
        const update = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":1,\"method\":\"layer.update\",\"windowId\":1,\"update\":{{\"exclusiveZone\":{s}}}}}", .{value});
        defer std.testing.allocator.free(update);
        try std.testing.expectError(error.InvalidSurfaceField, channel.parseRequest(std.testing.allocator, update));
        const create = try std.fmt.allocPrint(std.testing.allocator, "{{\"id\":1,\"method\":\"window.open\",\"role\":{{\"kind\":\"layer\",\"namespace\":\"panel\",\"layer\":\"top\",\"anchors\":[\"top\"],\"exclusiveZone\":{s}}}}}", .{value});
        defer std.testing.allocator.free(create);
        try std.testing.expectError(error.InvalidSurfaceField, channel.parseRequest(std.testing.allocator, create));
    }
    try std.testing.expectError(error.InvalidSurfaceField, channel.parseRequest(std.testing.allocator,
        \\{"id":1,"method":"window.open","role":{"kind":"layer","namespace":"panel","layer":"top","anchors":["top","left"],"exclusiveZone":"auto"}}
    ));
}
