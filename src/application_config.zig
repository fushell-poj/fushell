const std = @import("std");

pub const source_file_name = "fushell.json";
pub const bundle_file_name = "fushell_application.json";
const max_config_bytes = 64 * 1024;

pub const InstanceMode = enum {
    multiple,
    single,
};

pub const Config = struct {
    application_id: ?[]u8 = null,
    instance: InstanceMode = .multiple,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        if (self.application_id) |application_id| allocator.free(application_id);
    }
};

pub fn loadProject(allocator: std.mem.Allocator, io: std.Io) !Config {
    return loadOptionalFile(allocator, io, .cwd(), source_file_name);
}

pub fn loadBundle(allocator: std.mem.Allocator, io: std.Io, bundle_path: []const u8) !Config {
    const path = try std.fs.path.join(allocator, &.{ bundle_path, "data", bundle_file_name });
    defer allocator.free(path);
    return loadOptionalFile(allocator, io, .cwd(), path);
}

pub fn writeBundle(allocator: std.mem.Allocator, io: std.Io, bundle_path: []const u8, config: Config) !void {
    const path = try std.fs.path.join(allocator, &.{ bundle_path, "data", bundle_file_name });
    defer allocator.free(path);

    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [512]u8 = undefined;
    const bytes = if (config.application_id) |application_id|
        try std.fmt.bufPrint(&buffer, "{{\"schemaVersion\":1,\"applicationId\":\"{s}\",\"instance\":\"{s}\"}}\n", .{ application_id, @tagName(config.instance) })
    else
        try std.fmt.bufPrint(&buffer, "{{\"schemaVersion\":1,\"instance\":\"{s}\"}}\n", .{@tagName(config.instance)});
    try file.writeStreamingAll(io, bytes);
}

fn loadOptionalFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) !Config {
    const bytes = dir.readFileAlloc(io, path, allocator, .limited(max_config_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(bytes);
    return parse(allocator, bytes);
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Config {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return error.InvalidApplicationConfig;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidApplicationConfig;

    const object = parsed.value.object;
    for (object.keys()) |key| {
        if (!std.mem.eql(u8, key, "schemaVersion") and
            !std.mem.eql(u8, key, "applicationId") and
            !std.mem.eql(u8, key, "instance"))
        {
            return error.UnknownApplicationConfigField;
        }
    }

    if (object.get("schemaVersion")) |value| {
        if (value != .integer or value.integer != 1) return error.UnsupportedApplicationConfigVersion;
    }

    var config: Config = .{};
    errdefer config.deinit(allocator);

    if (object.get("applicationId")) |value| {
        if (value != .string or !isValidApplicationId(value.string)) return error.InvalidApplicationId;
        config.application_id = try allocator.dupe(u8, value.string);
    }

    if (object.get("instance")) |value| {
        if (value != .string) return error.InvalidInstanceMode;
        config.instance = std.meta.stringToEnum(InstanceMode, value.string) orelse return error.InvalidInstanceMode;
    }

    if (config.instance == .single and config.application_id == null) return error.SingleInstanceRequiresApplicationId;
    return config;
}

pub fn isValidApplicationId(value: []const u8) bool {
    if (value.len == 0 or value.len > 255 or value[0] == '.' or value[value.len - 1] == '.') return false;

    var component_count: usize = 0;
    var component_start = true;
    for (value) |byte| {
        if (byte == '.') {
            if (component_start) return false;
            component_count += 1;
            component_start = true;
            continue;
        }
        if (component_start) {
            if (!std.ascii.isAlphabetic(byte) and byte != '_') return false;
            component_start = false;
        } else if (!std.ascii.isAlphanumeric(byte) and byte != '_') {
            return false;
        }
    }
    return !component_start and component_count >= 1;
}

test "application config defaults to multiple instances" {
    var config = try parse(std.testing.allocator, "{}");
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(InstanceMode.multiple, config.instance);
    try std.testing.expect(config.application_id == null);
}

test "application config parses explicit single instance" {
    var config = try parse(
        std.testing.allocator,
        "{\"schemaVersion\":1,\"applicationId\":\"dev.example.App\",\"instance\":\"single\"}",
    );
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(InstanceMode.single, config.instance);
    try std.testing.expectEqualStrings("dev.example.App", config.application_id.?);
}

test "single instance requires a valid application id" {
    try std.testing.expectError(error.SingleInstanceRequiresApplicationId, parse(std.testing.allocator, "{\"instance\":\"single\"}"));
    try std.testing.expectError(error.InvalidApplicationId, parse(std.testing.allocator, "{\"applicationId\":\"invalid\",\"instance\":\"single\"}"));
    try std.testing.expectError(error.InvalidApplicationId, parse(std.testing.allocator, "{\"applicationId\":\"dev.1bad.App\",\"instance\":\"single\"}"));
}

test "application config rejects unknown fields and modes" {
    try std.testing.expectError(error.UnknownApplicationConfigField, parse(std.testing.allocator, "{\"unexpected\":true}"));
    try std.testing.expectError(error.InvalidInstanceMode, parse(std.testing.allocator, "{\"instance\":\"sometimes\"}"));
}
