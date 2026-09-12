//! 校验 Fushell bundle，并准备交给引擎的项目参数。
//!
//! JIT bundle 直接让 Flutter 读取 kernel/assets；AOT bundle 还会 `dlopen`
//! 应用快照库，并解析 `FlutterEngineRunsAOTCompiledDartCode` 所要求的四个符号。
//! 所有路径均由 Bundle 持有；只有在引擎不再使用相关路径后，才能调用 [Bundle.deinit]。

const std = @import("std");

/// Validated Flutter bundle paths, using the application’s original assets.
///
/// 路径使用哨兵结尾，因为 Flutter C ABI 会在整个引擎生命周期内保留它们；释放时
/// 必须保持精确的 `[:0]u8` 类型，并存活到 Flutter 释放全部资产引用。
pub const Bundle = struct {
    assets_path: [:0]u8,
    icu_data_path: [:0]u8,
    app_so_path: ?[:0]u8 = null,
    pub fn deinit(self: Bundle, gpa: std.mem.Allocator) void {
        if (self.app_so_path) |app_so| gpa.free(app_so);
        gpa.free(self.assets_path);
        gpa.free(self.icu_data_path);
    }
};

/// 加载 Debug/JIT bundle，并在启动引擎前确认 kernel 与资产输入存在。
pub fn loadJit(gpa: std.mem.Allocator, bundle_path: []const u8) !Bundle {
    if (!try pathExists(gpa, bundle_path)) {
        std.debug.print("Flutter bundle path does not exist: {s}\n", .{bundle_path});
        return error.InvalidFlutterBundle;
    }

    const gtk_assets = try std.fs.path.join(gpa, &.{ bundle_path, "data", "flutter_assets" });
    defer gpa.free(gtk_assets);
    const gtk_icu = try std.fs.path.join(gpa, &.{ bundle_path, "data", "icudtl.dat" });
    defer gpa.free(gtk_icu);
    if (try validateAssetsLayout(gpa, gtk_assets, gtk_icu)) return prepareBundle(gpa, gtk_assets, gtk_icu, null);

    const raw_assets = try std.fs.path.join(gpa, &.{ bundle_path, "flutter_assets" });
    defer gpa.free(raw_assets);
    const raw_icu = try std.fs.path.join(gpa, &.{ bundle_path, "icudtl.dat" });
    defer gpa.free(raw_icu);
    if (try validateAssetsLayout(gpa, raw_assets, raw_icu)) return prepareBundle(gpa, raw_assets, raw_icu, null);

    std.debug.print("Flutter debug/JIT bundle is incomplete. Expected either:\n", .{});
    std.debug.print("  {s}/data/flutter_assets/kernel_blob.bin\n", .{bundle_path});
    std.debug.print("  {s}/data/icudtl.dat\n", .{bundle_path});
    std.debug.print("or:\n", .{});
    std.debug.print("  {s}/flutter_assets/kernel_blob.bin\n", .{bundle_path});
    std.debug.print("  {s}/icudtl.dat\n", .{bundle_path});
    return error.InvalidFlutterBundle;
}

/// 加载 Profile/Release bundle，并解析其 AOT 快照符号。
/// 若打包的 `libapp.so` 不兼容或不完整，会在 Flutter 启动前报错，避免留下
/// 部分初始化的引擎状态。
pub fn loadAot(gpa: std.mem.Allocator, bundle_path: []const u8) !Bundle {
    if (!try pathExists(gpa, bundle_path)) {
        std.debug.print("Flutter bundle path does not exist: {s}\n", .{bundle_path});
        return error.InvalidFlutterBundle;
    }

    const gtk_assets = try std.fs.path.join(gpa, &.{ bundle_path, "data", "flutter_assets" });
    defer gpa.free(gtk_assets);
    const gtk_icu = try std.fs.path.join(gpa, &.{ bundle_path, "data", "icudtl.dat" });
    defer gpa.free(gtk_icu);
    const gtk_app = try std.fs.path.join(gpa, &.{ bundle_path, "lib", "libapp.so" });
    defer gpa.free(gtk_app);
    const gtk_symbols = try std.fs.path.join(gpa, &.{ bundle_path, "lib", "libapp.so.symbols" });
    defer gpa.free(gtk_symbols);
    if (try validateAotLayout(gpa, gtk_assets, gtk_icu, gtk_app, gtk_symbols)) return prepareBundle(gpa, gtk_assets, gtk_icu, gtk_app);

    const raw_assets = try std.fs.path.join(gpa, &.{ bundle_path, "flutter_assets" });
    defer gpa.free(raw_assets);
    const raw_icu = try std.fs.path.join(gpa, &.{ bundle_path, "icudtl.dat" });
    defer gpa.free(raw_icu);
    if (try validateAotLayout(gpa, raw_assets, raw_icu, gtk_app, gtk_symbols)) return prepareBundle(gpa, raw_assets, raw_icu, gtk_app);

    std.debug.print("Flutter AOT bundle is incomplete. Expected:\n", .{});
    std.debug.print("  {s}/lib/libapp.so\n", .{bundle_path});
    std.debug.print("  {s}/lib/libapp.so.symbols\n", .{bundle_path});
    std.debug.print("  {s}/data/flutter_assets/\n", .{bundle_path});
    std.debug.print("  {s}/data/icudtl.dat\n", .{bundle_path});
    std.debug.print("Build it with: flutter build bundle --release (libapp.so via gen_snapshot).\n", .{});
    return error.InvalidFlutterBundle;
}

fn validateAotLayout(gpa: std.mem.Allocator, assets_path: []const u8, icu_data_path: []const u8, app_so_path: []const u8, symbols_path: []const u8) !bool {
    return try pathExists(gpa, assets_path) and
        try pathExists(gpa, icu_data_path) and
        try pathExists(gpa, app_so_path) and
        try pathExists(gpa, symbols_path);
}

fn validateAssetsLayout(gpa: std.mem.Allocator, assets_path: []const u8, icu_data_path: []const u8) !bool {
    const kernel_blob = try std.fs.path.join(gpa, &.{ assets_path, "kernel_blob.bin" });
    defer gpa.free(kernel_blob);
    return try pathExists(gpa, assets_path) and try pathExists(gpa, icu_data_path) and try pathExists(gpa, kernel_blob);
}

fn prepareBundle(gpa: std.mem.Allocator, assets_path: []const u8, icu_data_path: []const u8, app_so_path: ?[]const u8) !Bundle {
    const owned_assets = try gpa.dupeZ(u8, assets_path);
    errdefer gpa.free(owned_assets);
    const owned_icu = try gpa.dupeZ(u8, icu_data_path);
    errdefer gpa.free(owned_icu);
    const owned_app = if (app_so_path) |path| try gpa.dupeZ(u8, path) else null;

    return .{
        .assets_path = owned_assets,
        .icu_data_path = owned_icu,
        .app_so_path = owned_app,
    };
}

fn pathExists(gpa: std.mem.Allocator, path: []const u8) !bool {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    return std.c.access(path_z.ptr, std.c.F_OK) == 0;
}

test "bundle retains original asset paths independently of caller storage" {
    const gpa = std.testing.allocator;
    for ([_]?[]const u8{ null, "bundle/lib/libapp.so" }) |app_path| {
        const assets = try gpa.dupe(u8, "bundle/data/flutter_assets");
        defer gpa.free(assets);
        const icu = try gpa.dupe(u8, "bundle/data/icudtl.dat");
        defer gpa.free(icu);
        const app = if (app_path) |path| try gpa.dupe(u8, path) else null;
        defer if (app) |path| gpa.free(path);

        const bundle = try prepareBundle(gpa, assets, icu, app);
        defer bundle.deinit(gpa);
        @memset(assets, 0);
        @memset(icu, 0);
        if (app) |path| @memset(path, 0);

        try std.testing.expectEqualStrings("bundle/data/flutter_assets", bundle.assets_path);
        try std.testing.expectEqualStrings("bundle/data/icudtl.dat", bundle.icu_data_path);
        try std.testing.expectEqual(@as(u8, 0), bundle.assets_path[bundle.assets_path.len]);
        try std.testing.expectEqual(@as(u8, 0), bundle.icu_data_path[bundle.icu_data_path.len]);
        if (app_path) |path| {
            try std.testing.expectEqualStrings(path, bundle.app_so_path.?);
            try std.testing.expectEqual(@as(u8, 0), bundle.app_so_path.?[bundle.app_so_path.?.len]);
        } else {
            try std.testing.expectEqual(null, bundle.app_so_path);
        }
    }
}

fn prepareBundleAllocationFailure(gpa: std.mem.Allocator, app_path: ?[]const u8) !void {
    const bundle = try prepareBundle(gpa, "bundle/flutter_assets", "bundle/icudtl.dat", app_path);
    defer bundle.deinit(gpa);
}

test "bundle preparation frees partial paths on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, prepareBundleAllocationFailure, .{@as(?[]const u8, null)});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, prepareBundleAllocationFailure, .{@as(?[]const u8, "bundle/lib/libapp.so")});
}
