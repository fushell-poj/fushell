//! 构建工具与打包 runner 共享的应用实例策略。
//!
//! 项目可省略 `fushell.json`，此时会明确选择相互独立的进程，并避免依赖会话总线。
//! 单实例项目在构建时完成校验并写入规范化 bundle manifest，因此 runner 无需从
//! 可变的源文件推断策略。

const std = @import("std");

pub const source_file_name = "fushell.json";
pub const bundle_file_name = "fushell_application.json";
const max_config_bytes = 64 * 1024;

/// 决定 runner 是独立启动，还是通过会话总线协调。
/// `.single` 是硬性要求：缺少 D-Bus 时必须报错，不得隐式退化为 `.multiple`。
pub const InstanceMode = enum {
    multiple,
    single,
};

/// 打包应用经解析后的实例所有权策略。
///
/// `application_id` 由该值拥有，必须通过 [deinit] 释放。多实例模式下它可以省略；
/// 当 `instance` 为 `.single` 时则必须提供，并按 D-Bus well-known name 校验。
pub const Config = struct {
    application_id: ?[]u8 = null,
    instance: InstanceMode = .multiple,

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        if (self.application_id) |application_id| allocator.free(application_id);
    }
};

/// 从当前项目目录加载可选的源 manifest。
/// 文件不存在不算错误，而是返回多实例默认值。
pub fn loadProject(allocator: std.mem.Allocator, io: std.Io) !Config {
    return loadOptionalFile(allocator, io, .cwd(), source_file_name);
}

/// 加载打包 runner 旁的规范化 manifest。
///
/// bundle manifest 缺失时按普通多实例 bundle 处理；格式错误或版本不受支持时
/// 则按失败关闭原则拒绝启动。
pub fn loadBundle(allocator: std.mem.Allocator, io: std.Io, bundle_path: []const u8) !Config {
    const path = try std.fs.path.join(allocator, &.{ bundle_path, "data", bundle_file_name });
    defer allocator.free(path);
    return loadOptionalFile(allocator, io, .cwd(), path);
}

/// 在 [bundle_path] 中写入确定性的 runner manifest。
/// 生成文件只包含运行时策略，不包含构建工具内部状态。
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

/// 按 schema version 1 严格校验字段与类型。
///
/// 未知键会被拒绝，避免拼错的安全或生命周期策略被静默忽略。返回的 application id
/// 如存在，则由调用方使用的分配器拥有。
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

/// 校验应用总线名称所采用的 D-Bus well-known-name 子集。
/// 名称至少包含两个由点分隔的段；每段以 ASCII 字母或下划线开头，并受 D-Bus
/// 255 字节总长度限制。
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
