const std = @import("std");
const c = @import("c");

const flutter_default_font_family = "Roboto";

/// Validated Flutter bundle paths plus an optional temporary font overlay.
pub const Bundle = struct {
    assets_path: [:0]u8,
    icu_data_path: [:0]u8,
    app_so_path: ?[:0]u8 = null,
    overlay_assets_path: ?[]u8 = null,

    pub fn deinit(self: Bundle, gpa: std.mem.Allocator) void {
        if (self.overlay_assets_path) |overlay_path| {
            deleteTreeBestEffort(overlay_path);
            gpa.free(overlay_path);
        }
        if (self.app_so_path) |app_so| gpa.free(app_so);
        gpa.free(self.assets_path);
        gpa.free(self.icu_data_path);
    }
};

const FontconfigFont = struct {
    family: []u8,
    path: []u8,

    fn deinit(self: FontconfigFont, gpa: std.mem.Allocator) void {
        gpa.free(self.family);
        gpa.free(self.path);
    }
};

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
    const injected_assets_path = prepareFontconfigAssetsOverlay(gpa, assets_path) catch |err| switch (err) {
        error.SystemFontUnavailable, error.FontManifestAlreadyProvidesDefault => null,
        else => fallback: {
            std.debug.print("[error] System font asset injection failed: {s}; continuing with original bundle assets.\n", .{@errorName(err)});
            break :fallback null;
        },
    };

    if (injected_assets_path) |overlay_path| {
        std.debug.print("Using fontconfig system font asset overlay: {s}\n", .{overlay_path});
        return .{
            .assets_path = try gpa.dupeZ(u8, overlay_path),
            .icu_data_path = try gpa.dupeZ(u8, icu_data_path),
            .app_so_path = if (app_so_path) |p| try gpa.dupeZ(u8, p) else null,
            .overlay_assets_path = overlay_path,
        };
    }

    return .{
        .assets_path = try gpa.dupeZ(u8, assets_path),
        .icu_data_path = try gpa.dupeZ(u8, icu_data_path),
        .app_so_path = if (app_so_path) |p| try gpa.dupeZ(u8, p) else null,
    };
}

fn pathExists(gpa: std.mem.Allocator, path: []const u8) !bool {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    return std.c.access(path_z.ptr, std.c.F_OK) == 0;
}

fn prepareFontconfigAssetsOverlay(gpa: std.mem.Allocator, assets_path: []const u8) ![]u8 {
    const system_font = try resolveFontconfigSansFont(gpa);
    defer system_font.deinit(gpa);

    const manifest_path = try std.fs.path.join(gpa, &.{ assets_path, "FontManifest.json" });
    defer gpa.free(manifest_path);

    if (readFileAllocC(gpa, manifest_path)) |manifest| {
        defer gpa.free(manifest);
        if (manifestHasFontFamily(manifest, system_font.family) and manifestHasFontFamily(manifest, flutter_default_font_family)) {
            return error.FontManifestAlreadyProvidesDefault;
        }
    } else |_| {}

    const assets_abs = try realPathAlloc(gpa, assets_path);
    defer gpa.free(assets_abs);

    const overlay_path = try makeTempOverlayDir(gpa);
    errdefer {
        deleteTreeBestEffort(overlay_path);
        gpa.free(overlay_path);
    }
    try symlinkTopLevelAssets(gpa, assets_abs, overlay_path);

    const font_dir_name = "fushell_system_fonts";
    const font_dir = try std.fs.path.joinZ(gpa, &.{ overlay_path, font_dir_name });
    defer gpa.free(font_dir);
    if (c.mkdir(font_dir.ptr, 0o700) != 0) return error.CreateOverlayFailed;

    const font_basename = std.fs.path.basename(system_font.path);
    const font_asset = try std.fs.path.join(gpa, &.{ font_dir_name, font_basename });
    defer gpa.free(font_asset);
    const font_link = try std.fs.path.joinZ(gpa, &.{ overlay_path, font_asset });
    defer gpa.free(font_link);
    const system_font_path_z = try gpa.dupeZ(u8, system_font.path);
    defer gpa.free(system_font_path_z);
    if (c.symlink(system_font_path_z.ptr, font_link.ptr) != 0) return error.CreateOverlayFailed;

    try writeInjectedFontManifest(gpa, assets_path, overlay_path, system_font.family, font_asset);
    std.debug.print("Resolved fontconfig sans font for Flutter text fallback: {s} ({s}); registering Flutter default alias {s}\n", .{ system_font.family, system_font.path, flutter_default_font_family });
    return overlay_path;
}

fn resolveFontconfigSansFont(gpa: std.mem.Allocator) !FontconfigFont {
    if (c.FcInit() == 0) return error.SystemFontUnavailable;
    const pattern = c.FcNameParse("sans") orelse return error.SystemFontUnavailable;
    defer c.FcPatternDestroy(pattern);
    _ = c.FcConfigSubstitute(null, pattern, c.FcMatchPattern);
    c.FcDefaultSubstitute(pattern);

    var result: c.FcResult = undefined;
    const match = c.FcFontMatch(null, pattern, &result) orelse return error.SystemFontUnavailable;
    defer c.FcPatternDestroy(match);

    var family_value: [*c]c.FcChar8 = null;
    if (c.FcPatternGetString(match, c.FC_FAMILY, 0, &family_value) != c.FcResultMatch or family_value == null) return error.SystemFontUnavailable;
    var file_value: [*c]c.FcChar8 = null;
    if (c.FcPatternGetString(match, c.FC_FILE, 0, &file_value) != c.FcResultMatch or file_value == null) return error.SystemFontUnavailable;

    return .{
        .family = try gpa.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(family_value)))),
        .path = try gpa.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(file_value)))),
    };
}

fn makeTempOverlayDir(gpa: std.mem.Allocator) ![]u8 {
    const tmp_dir = std.c.getenv("TMPDIR") orelse "/tmp";
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        const path = try std.fmt.allocPrint(gpa, "{s}/fushell-flutter-assets-{d}-{d}-{d}", .{ std.mem.span(tmp_dir), c.getpid(), c.time(null), attempt });
        const path_z = try gpa.dupeZ(u8, path);
        defer gpa.free(path_z);
        if (c.mkdir(path_z.ptr, 0o700) == 0) return path;
        gpa.free(path);
    }
    return error.CreateOverlayFailed;
}

fn symlinkTopLevelAssets(gpa: std.mem.Allocator, assets_abs: []const u8, overlay_path: []const u8) !void {
    const assets_abs_z = try gpa.dupeZ(u8, assets_abs);
    defer gpa.free(assets_abs_z);
    const dir = c.opendir(assets_abs_z.ptr) orelse return error.CreateOverlayFailed;
    defer _ = c.closedir(dir);

    while (c.readdir(dir)) |entry| {
        const name = direntName(entry);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (std.mem.eql(u8, name, "FontManifest.json") or std.mem.eql(u8, name, "fushell_system_fonts")) continue;
        const src = try std.fs.path.joinZ(gpa, &.{ assets_abs, name });
        defer gpa.free(src);
        const dst = try std.fs.path.joinZ(gpa, &.{ overlay_path, name });
        defer gpa.free(dst);
        if (c.symlink(src.ptr, dst.ptr) != 0) return error.CreateOverlayFailed;
    }
}

fn writeInjectedFontManifest(gpa: std.mem.Allocator, original_assets_path: []const u8, overlay_path: []const u8, family: []const u8, asset: []const u8) !void {
    const original_manifest_path = try std.fs.path.join(gpa, &.{ original_assets_path, "FontManifest.json" });
    defer gpa.free(original_manifest_path);

    var original_manifest: ?[]u8 = null;
    if (readFileAllocC(gpa, original_manifest_path)) |manifest| {
        original_manifest = manifest;
    } else |err| if (err != error.FileUnavailable) {
        std.debug.print("[warn] failed to read original FontManifest.json: {s}\n", .{@errorName(err)});
    }
    defer if (original_manifest) |manifest| gpa.free(manifest);

    const generated = try buildFontManifest(gpa, original_manifest, family, asset);
    defer gpa.free(generated);
    const overlay_manifest_path = try std.fs.path.joinZ(gpa, &.{ overlay_path, "FontManifest.json" });
    defer gpa.free(overlay_manifest_path);
    try writeFileC(overlay_manifest_path, generated);
}

fn buildFontManifest(gpa: std.mem.Allocator, original_manifest: ?[]const u8, family: []const u8, asset: []const u8) ![]u8 {
    try validateJsonStringFragment(family);
    try validateJsonStringFragment(flutter_default_font_family);
    try validateJsonStringFragment(asset);

    const injected = if (std.mem.eql(u8, family, flutter_default_font_family))
        try std.fmt.allocPrint(gpa, "{{\"family\":\"{s}\",\"fonts\":[{{\"asset\":\"{s}\",\"weight\":400}},{{\"asset\":\"{s}\",\"weight\":800}}]}}", .{ family, asset, asset })
    else
        try std.fmt.allocPrint(gpa, "{{\"family\":\"{s}\",\"fonts\":[{{\"asset\":\"{s}\",\"weight\":400}},{{\"asset\":\"{s}\",\"weight\":800}}]}},{{\"family\":\"{s}\",\"fonts\":[{{\"asset\":\"{s}\",\"weight\":400}},{{\"asset\":\"{s}\",\"weight\":800}}]}}", .{ family, asset, asset, flutter_default_font_family, asset, asset });
    defer gpa.free(injected);

    if (original_manifest == null) return std.fmt.allocPrint(gpa, "[{s}]\n", .{injected});
    const original = original_manifest.?;
    var end = original.len;
    while (end > 0 and std.ascii.isWhitespace(original[end - 1])) end -= 1;
    if (end == 0 or original[end - 1] != ']') return std.fmt.allocPrint(gpa, "[{s}]\n", .{injected});

    var has_existing_entries = false;
    for (original[0 .. end - 1]) |byte| {
        if (!std.ascii.isWhitespace(byte) and byte != '[') {
            has_existing_entries = true;
            break;
        }
    }
    return std.fmt.allocPrint(gpa, "{s}{s}{s}]\n", .{ original[0 .. end - 1], if (has_existing_entries) "," else "", injected });
}

fn manifestHasFontFamily(manifest: []const u8, family: []const u8) bool {
    const needle = std.fmt.allocPrint(std.heap.c_allocator, "\"family\":\"{s}\"", .{family}) catch return false;
    defer std.heap.c_allocator.free(needle);
    return std.mem.indexOf(u8, manifest, needle) != null;
}

fn validateJsonStringFragment(value: []const u8) !void {
    for (value) |byte| if (byte < 0x20 or byte == '"' or byte == '\\') return error.InvalidFontManifestValue;
}

fn readFileAllocC(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const file = c.fopen(path_z.ptr, "rb") orelse return error.FileUnavailable;
    defer _ = c.fclose(file);
    if (c.fseek(file, 0, c.SEEK_END) != 0) return error.FileUnavailable;
    const length = c.ftell(file);
    if (length < 0 or length > 1024 * 1024) return error.FileUnavailable;
    if (c.fseek(file, 0, c.SEEK_SET) != 0) return error.FileUnavailable;
    const buffer = try gpa.alloc(u8, @intCast(length));
    errdefer gpa.free(buffer);
    if (c.fread(buffer.ptr, 1, buffer.len, file) != buffer.len) return error.FileUnavailable;
    return buffer;
}

fn writeFileC(path_z: [:0]const u8, bytes: []const u8) !void {
    const file = c.fopen(path_z.ptr, "wb") orelse return error.FileUnavailable;
    defer _ = c.fclose(file);
    if (c.fwrite(bytes.ptr, 1, bytes.len, file) != bytes.len) return error.FileUnavailable;
}

fn realPathAlloc(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    const resolved = c.realpath(path_z.ptr, null) orelse return error.FileUnavailable;
    defer c.free(resolved);
    return gpa.dupe(u8, std.mem.span(resolved));
}

fn direntName(entry: *c.struct_dirent) []const u8 {
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.d_name)), 0);
}

fn deleteTreeBestEffort(path: []const u8) void {
    const path_z = std.heap.c_allocator.dupeZ(u8, path) catch return;
    defer std.heap.c_allocator.free(path_z);
    const dir = c.opendir(path_z.ptr) orelse {
        _ = c.unlink(path_z.ptr);
        return;
    };
    while (c.readdir(dir)) |entry| {
        const name = direntName(entry);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const child = std.fs.path.joinZ(std.heap.c_allocator, &.{ path, name }) catch continue;
        defer std.heap.c_allocator.free(child);
        if (c.unlink(child.ptr) != 0) deleteTreeBestEffort(child);
    }
    _ = c.closedir(dir);
    _ = c.rmdir(path_z.ptr);
}
