const std = @import("std");

pub const channel_name = "dev.fushell/surface";
pub const open_window_method = "window.open";
pub const close_window_method = "window.close";
pub const update_window_method = "window.update";
pub const update_layer_method = "layer.update";
pub const exit_method = "process.exit";

pub const Request = union(enum) {
    open_window: OpenWindowRequest,
    close_window: CloseWindowRequest,
    update_window: WindowUpdateRequest,
    update_layer: LayerUpdateRequest,
    exit: ExitRequest,

    pub fn id(self: Request) i64 {
        return switch (self) {
            .open_window => |request| request.id,
            .close_window => |request| request.id,
            .update_window => |request| request.id,
            .update_layer => |request| request.id,
            .exit => |request| request.id,
        };
    }

    pub fn deinit(self: Request, gpa: std.mem.Allocator) void {
        switch (self) {
            .open_window => |request| request.deinit(gpa),
            .close_window => {},
            .update_window => |request| request.deinit(gpa),
            .update_layer => {},
            .exit => {},
        }
    }
};

/// window.open: 创建新窗口 (可指定父窗口), 成功后回复窗口 id (= Flutter view_id)。
pub const OpenWindowRequest = struct {
    id: i64,
    role: Role,
    /// 父窗口 id (= 父 view_id); null = 无父。
    parent: ?i64 = null,

    pub fn deinit(self: OpenWindowRequest, gpa: std.mem.Allocator) void {
        switch (self.role) {
            .window => |window| {
                gpa.free(window.title);
                gpa.free(window.app_id);
            },
            .layer => |layer| {
                gpa.free(layer.namespace);
            },
        }
    }
};

pub const CloseWindowRequest = struct {
    id: i64,
    window_id: i64,
};

pub const WindowUpdateRequest = struct {
    id: i64,
    window_id: i64,
    update: WindowSurfaceUpdate,

    pub fn deinit(self: WindowUpdateRequest, gpa: std.mem.Allocator) void {
        if (self.update.title) |title| gpa.free(title);
        if (self.update.app_id) |app_id| gpa.free(app_id);
    }
};

pub const LayerUpdateRequest = struct {
    id: i64,
    window_id: i64,
    update: LayerSurfaceUpdate,
};

pub const ExitRequest = struct {
    id: i64,
    code: i64,
};

pub const Role = union(enum) {
    window: WindowRole,
    layer: LayerRole,
};

pub const WindowRole = struct {
    title: []u8,
    app_id: []u8,
    width: ?i32 = null,
    height: ?i32 = null,
};

pub const LayerRole = struct {
    namespace: []u8,
    layer: Layer,
    anchors: AnchorMask,
    margins: Margins = .{},
    exclusive_zone: i32 = -1,
    keyboard_interactivity: KeyboardInteractivity = .none,
    width: ?i32 = null,
    height: ?i32 = null,
};

pub const LayerSurfaceUpdate = struct {
    width: ?i32 = null,
    height: ?i32 = null,
    anchors: ?AnchorMask = null,
    margins: ?Margins = null,
    exclusive_zone: ?i32 = null,
    keyboard_interactivity: ?KeyboardInteractivity = null,

    pub fn isEmpty(self: LayerSurfaceUpdate) bool {
        return self.width == null and
            self.height == null and
            self.anchors == null and
            self.margins == null and
            self.exclusive_zone == null and
            self.keyboard_interactivity == null;
    }

    pub fn affectsLayout(self: LayerSurfaceUpdate) bool {
        return self.width != null or
            self.height != null or
            self.anchors != null or
            self.margins != null or
            self.exclusive_zone != null;
    }
};

pub const WindowSurfaceUpdate = struct {
    title: ?[]u8 = null,
    app_id: ?[]u8 = null,

    pub fn isEmpty(self: WindowSurfaceUpdate) bool {
        return self.title == null and self.app_id == null;
    }
};

pub const Layer = enum {
    background,
    bottom,
    top,
    overlay,
};

pub const KeyboardInteractivity = enum {
    none,
    exclusive,
    on_demand,
};

pub const AnchorMask = packed struct(u8) {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
    _padding: u4 = 0,

    pub fn isEmpty(self: AnchorMask) bool {
        return !self.top and !self.bottom and !self.left and !self.right;
    }
};

pub const Margins = struct {
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,
};

pub const ParseError = error{
    InvalidSurfaceInitPayload,
    UnsupportedSurfaceMethod,
    UnsupportedSurfaceRole,
    MissingRequiredSurfaceField,
    InvalidSurfaceField,
    OutOfMemory,
};

pub fn parseRequest(gpa: std.mem.Allocator, bytes: []const u8) ParseError!Request {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return error.InvalidSurfaceInitPayload;
    defer parsed.deinit();

    const root = object(parsed.value) orelse return error.InvalidSurfaceInitPayload;
    const id = requiredInt(root, "id") catch return error.InvalidSurfaceField;
    const method = requiredString(root, "method") catch return error.MissingRequiredSurfaceField;

    if (std.mem.eql(u8, method, open_window_method)) {
        const role_value = root.get("role") orelse return error.MissingRequiredSurfaceField;
        const role_object = object(role_value) orelse return error.InvalidSurfaceField;
        const parent = (optionalInt(root, "parent") catch return error.InvalidSurfaceField);
        return .{ .open_window = .{ .id = id, .role = try parseRole(gpa, role_object), .parent = parent } };
    }

    if (std.mem.eql(u8, method, close_window_method)) {
        const window_id = requiredInt(root, "windowId") catch return error.MissingRequiredSurfaceField;
        return .{ .close_window = .{ .id = id, .window_id = window_id } };
    }

    if (std.mem.eql(u8, method, update_layer_method)) {
        const window_id = requiredInt(root, "windowId") catch return error.MissingRequiredSurfaceField;
        const update_value = root.get("update") orelse return error.MissingRequiredSurfaceField;
        const update_object = object(update_value) orelse return error.InvalidSurfaceField;
        return .{ .update_layer = .{ .id = id, .window_id = window_id, .update = try parseLayerSurfaceUpdate(update_object) } };
    }

    if (std.mem.eql(u8, method, update_window_method)) {
        const window_id = requiredInt(root, "windowId") catch return error.MissingRequiredSurfaceField;
        const update_value = root.get("update") orelse return error.MissingRequiredSurfaceField;
        const update_object = object(update_value) orelse return error.InvalidSurfaceField;
        return .{ .update_window = .{ .id = id, .window_id = window_id, .update = try parseWindowSurfaceUpdate(gpa, update_object) } };
    }

    if (std.mem.eql(u8, method, exit_method)) {
        const code = (optionalInt(root, "code") catch return error.InvalidSurfaceField) orelse 0;
        return .{ .exit = .{ .id = id, .code = code } };
    }

    return error.UnsupportedSurfaceMethod;
}

pub fn successResponse(gpa: std.mem.Allocator, id: i64) ![]u8 {
    return try std.fmt.allocPrint(gpa, "{{\"id\":{d},\"ok\":true}}", .{id});
}

/// window.open 成功响应: 带窗口 id (= Flutter view_id)。
pub fn openSuccessResponse(gpa: std.mem.Allocator, id: i64, window_id: i64) ![]u8 {
    return try std.fmt.allocPrint(gpa, "{{\"id\":{d},\"ok\":true,\"windowId\":{d}}}", .{ id, window_id });
}

pub fn errorResponse(gpa: std.mem.Allocator, id: ?i64, code: []const u8, message: []const u8) ![]u8 {
    if (id) |request_id| {
        return try std.fmt.allocPrint(gpa, "{{\"id\":{d},\"ok\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ request_id, code, message });
    }
    return try std.fmt.allocPrint(gpa, "{{\"ok\":false,\"error\":{{\"code\":\"{s}\",\"message\":\"{s}\"}}}}", .{ code, message });
}

pub fn parseErrorCode(err: ParseError) []const u8 {
    return switch (err) {
        error.InvalidSurfaceInitPayload => "InvalidSurfaceInitPayload",
        error.UnsupportedSurfaceMethod => "UnsupportedSurfaceMethod",
        error.UnsupportedSurfaceRole => "UnsupportedSurfaceRole",
        error.MissingRequiredSurfaceField => "MissingRequiredSurfaceField",
        error.InvalidSurfaceField => "InvalidSurfaceField",
        error.OutOfMemory => "OutOfMemory",
    };
}

fn parseRole(gpa: std.mem.Allocator, role_object: std.json.ObjectMap) ParseError!Role {
    const kind = requiredString(role_object, "kind") catch return error.MissingRequiredSurfaceField;
    if (std.mem.eql(u8, kind, "window")) {
        return .{ .window = try parseWindowRole(gpa, role_object) };
    }
    if (std.mem.eql(u8, kind, "layer")) {
        return .{ .layer = try parseLayerRole(gpa, role_object) };
    }
    return error.UnsupportedSurfaceRole;
}

fn parseWindowRole(gpa: std.mem.Allocator, role_object: std.json.ObjectMap) ParseError!WindowRole {
    return .{
        .title = try duplicateRequiredString(gpa, role_object, "title"),
        .app_id = try duplicateRequiredString(gpa, role_object, "appId"),
        .width = optionalPositiveI32(role_object, "width") catch return error.InvalidSurfaceField,
        .height = optionalPositiveI32(role_object, "height") catch return error.InvalidSurfaceField,
    };
}

fn parseLayerRole(gpa: std.mem.Allocator, role_object: std.json.ObjectMap) ParseError!LayerRole {
    const exclusive_zone = (optionalI32(role_object, "exclusiveZone") catch return error.InvalidSurfaceField) orelse -1;
    const keyboard = (optionalString(role_object, "keyboardInteractivity") catch return error.InvalidSurfaceField) orelse "none";
    return .{
        .namespace = try duplicateRequiredString(gpa, role_object, "namespace"),
        .layer = parseLayer(requiredString(role_object, "layer") catch return error.MissingRequiredSurfaceField) catch return error.InvalidSurfaceField,
        .anchors = parseAnchors(role_object.get("anchors") orelse return error.MissingRequiredSurfaceField) catch return error.InvalidSurfaceField,
        .margins = (parseMargins(role_object.get("margins")) catch return error.InvalidSurfaceField) orelse .{},
        .exclusive_zone = exclusive_zone,
        .keyboard_interactivity = parseKeyboardInteractivity(keyboard) catch return error.InvalidSurfaceField,
        .width = optionalNonNegativeI32(role_object, "width") catch return error.InvalidSurfaceField,
        .height = optionalNonNegativeI32(role_object, "height") catch return error.InvalidSurfaceField,
    };
}

fn parseLayerSurfaceUpdate(update_object: std.json.ObjectMap) ParseError!LayerSurfaceUpdate {
    const anchors = if (update_object.get("anchors")) |anchors_value|
        parseAnchors(anchors_value) catch return error.InvalidSurfaceField
    else
        null;
    return .{
        .width = optionalNonNegativeI32(update_object, "width") catch return error.InvalidSurfaceField,
        .height = optionalNonNegativeI32(update_object, "height") catch return error.InvalidSurfaceField,
        .anchors = anchors,
        .margins = parseMargins(update_object.get("margins")) catch return error.InvalidSurfaceField,
        .exclusive_zone = optionalI32(update_object, "exclusiveZone") catch return error.InvalidSurfaceField,
        .keyboard_interactivity = optionalKeyboardInteractivity(update_object, "keyboardInteractivity") catch return error.InvalidSurfaceField,
    };
}

fn parseWindowSurfaceUpdate(gpa: std.mem.Allocator, update_object: std.json.ObjectMap) ParseError!WindowSurfaceUpdate {
    return .{
        .title = try duplicateOptionalString(gpa, update_object, "title"),
        .app_id = try duplicateOptionalString(gpa, update_object, "appId"),
    };
}

fn parseLayer(value: []const u8) !Layer {
    if (std.mem.eql(u8, value, "background")) return .background;
    if (std.mem.eql(u8, value, "bottom")) return .bottom;
    if (std.mem.eql(u8, value, "top")) return .top;
    if (std.mem.eql(u8, value, "overlay")) return .overlay;
    return error.InvalidSurfaceField;
}

fn parseKeyboardInteractivity(value: []const u8) !KeyboardInteractivity {
    if (std.mem.eql(u8, value, "none")) return .none;
    if (std.mem.eql(u8, value, "exclusive")) return .exclusive;
    if (std.mem.eql(u8, value, "onDemand")) return .on_demand;
    return error.InvalidSurfaceField;
}

fn optionalKeyboardInteractivity(obj: std.json.ObjectMap, key: []const u8) !?KeyboardInteractivity {
    const value = try optionalString(obj, key);
    return if (value) |string| try parseKeyboardInteractivity(string) else null;
}

fn parseAnchors(value: std.json.Value) !AnchorMask {
    const array = switch (value) {
        .array => |items| items,
        else => return error.InvalidSurfaceField,
    };
    if (array.items.len == 0) return error.InvalidSurfaceField;
    var mask: AnchorMask = .{};
    for (array.items) |item| {
        const anchor = switch (item) {
            .string => |string| string,
            else => return error.InvalidSurfaceField,
        };
        if (std.mem.eql(u8, anchor, "top")) mask.top = true else if (std.mem.eql(u8, anchor, "bottom")) mask.bottom = true else if (std.mem.eql(u8, anchor, "left")) mask.left = true else if (std.mem.eql(u8, anchor, "right")) mask.right = true else return error.InvalidSurfaceField;
    }
    return mask;
}

fn parseMargins(value: ?std.json.Value) !?Margins {
    const margin_value = value orelse return null;
    const margin_object = object(margin_value) orelse return error.InvalidSurfaceField;
    return .{
        .top = (optionalI32(margin_object, "top") catch return error.InvalidSurfaceField) orelse 0,
        .right = (optionalI32(margin_object, "right") catch return error.InvalidSurfaceField) orelse 0,
        .bottom = (optionalI32(margin_object, "bottom") catch return error.InvalidSurfaceField) orelse 0,
        .left = (optionalI32(margin_object, "left") catch return error.InvalidSurfaceField) orelse 0,
    };
}

fn duplicateRequiredString(gpa: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ParseError![]u8 {
    return try gpa.dupe(u8, requiredString(obj, key) catch return error.MissingRequiredSurfaceField);
}

fn duplicateOptionalString(gpa: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ParseError!?[]u8 {
    const value = optionalString(obj, key) catch return error.InvalidSurfaceField;
    return if (value) |string| try gpa.dupe(u8, string) else null;
}

fn requiredString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = optionalString(obj, key) catch return error.InvalidSurfaceField;
    return value orelse return error.MissingRequiredSurfaceField;
}

fn optionalString(obj: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |string| string,
        else => error.InvalidSurfaceField,
    };
}

fn requiredInt(obj: std.json.ObjectMap, key: []const u8) !i64 {
    const value = optionalInt(obj, key) catch return error.InvalidSurfaceField;
    return value orelse return error.MissingRequiredSurfaceField;
}

fn optionalPositiveI32(obj: std.json.ObjectMap, key: []const u8) !?i32 {
    const value = try optionalI32(obj, key);
    if (value) |unwrapped| {
        if (unwrapped <= 0) return error.InvalidSurfaceField;
    }
    return value;
}

fn optionalNonNegativeI32(obj: std.json.ObjectMap, key: []const u8) !?i32 {
    const value = try optionalI32(obj, key);
    if (value) |unwrapped| {
        if (unwrapped < 0) return error.InvalidSurfaceField;
    }
    return value;
}

fn optionalI32(obj: std.json.ObjectMap, key: []const u8) !?i32 {
    const optional_value = try optionalInt(obj, key);
    const value = optional_value orelse return null;
    if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) return error.InvalidSurfaceField;
    return @intCast(value);
}

fn optionalInt(obj: std.json.ObjectMap, key: []const u8) !?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |integer| integer,
        else => error.InvalidSurfaceField,
    };
}

fn object(value: std.json.Value) ?std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => null,
    };
}

test "parse window open request" {
    const json =
        \\{"id":1,"method":"window.open","role":{"kind":"window","title":"Smoke","appId":"dev.fushell.smoke","width":800,"height":600}}
    ;
    const request = try parseRequest(std.testing.gpa, json);
    defer request.deinit(std.testing.gpa);
    try std.testing.expectEqual(@as(i64, 1), request.id());
    try std.testing.expectEqualStrings("Smoke", request.open_window.role.window.title);
    try std.testing.expectEqual(@as(?i32, 800), request.open_window.role.window.width);
    try std.testing.expectEqual(@as(?i64, null), request.open_window.parent);
}

test "parse window open with parent" {
    const json =
        \\{"id":2,"method":"window.open","parent":7,"role":{"kind":"window","title":"Child","appId":"dev.fushell.child"}}
    ;
    const request = try parseRequest(std.testing.gpa, json);
    defer request.deinit(std.testing.gpa);
    try std.testing.expectEqual(@as(?i64, 7), request.open_window.parent);
}

test "parse layer open request" {
    const json =
        \\{"id":3,"method":"window.open","role":{"kind":"layer","namespace":"panel","layer":"top","anchors":["top","left","right"],"margins":{"top":1,"right":2,"bottom":3,"left":4},"exclusiveZone":32,"keyboardInteractivity":"onDemand"}}
    ;
    const request = try parseRequest(std.testing.gpa, json);
    defer request.deinit(std.testing.gpa);
    try std.testing.expectEqual(@as(i64, 3), request.id());
    try std.testing.expectEqual(.top, request.open_window.role.layer.layer);
    try std.testing.expect(request.open_window.role.layer.anchors.top);
    try std.testing.expect(!request.open_window.role.layer.anchors.bottom);
    try std.testing.expectEqual(@as(i32, 32), request.open_window.role.layer.exclusive_zone);
    try std.testing.expectEqual(.on_demand, request.open_window.role.layer.keyboard_interactivity);
}

test "parse close window request" {
    const json =
        \\{"id":4,"method":"window.close","windowId":9}
    ;
    const request = try parseRequest(std.testing.gpa, json);
    defer request.deinit(std.testing.gpa);
    try std.testing.expectEqual(@as(i64, 9), request.close_window.window_id);
}

test "parse layer update request" {
    const json =
        \\{"id":5,"method":"layer.update","windowId":3,"update":{"width":0,"height":32,"anchors":["top","left","right"],"margins":{"top":0,"right":1,"bottom":2,"left":3},"exclusiveZone":32,"keyboardInteractivity":"none"}}
    ;
    const request = try parseRequest(std.testing.gpa, json);
    defer request.deinit(std.testing.gpa);
    try std.testing.expectEqual(@as(i64, 3), request.update_layer.window_id);
    try std.testing.expectEqual(@as(?i32, 0), request.update_layer.update.width);
    try std.testing.expectEqual(@as(?i32, 32), request.update_layer.update.height);
    try std.testing.expect(request.update_layer.update.anchors.?.top);
    try std.testing.expectEqual(@as(?i32, 32), request.update_layer.update.exclusive_zone);
    try std.testing.expectEqual(@as(?KeyboardInteractivity, .none), request.update_layer.update.keyboard_interactivity);
}

test "parse window update request" {
    const json =
        \\{"id":6,"method":"window.update","windowId":2,"update":{"title":"New title","appId":"dev.fushell.new"}}
    ;
    const request = try parseRequest(std.testing.gpa, json);
    defer request.deinit(std.testing.gpa);
    try std.testing.expectEqual(@as(i64, 2), request.update_window.window_id);
    try std.testing.expectEqualStrings("New title", request.update_window.update.title.?);
    try std.testing.expectEqualStrings("dev.fushell.new", request.update_window.update.app_id.?);
}

test "parse empty update requests" {
    const layer_json =
        \\{"id":7,"method":"layer.update","windowId":1,"update":{}}
    ;
    const layer_request = try parseRequest(std.testing.gpa, layer_json);
    defer layer_request.deinit(std.testing.gpa);
    try std.testing.expect(layer_request.update_layer.update.isEmpty());

    const window_json =
        \\{"id":8,"method":"window.update","windowId":1,"update":{}}
    ;
    const window_request = try parseRequest(std.testing.gpa, window_json);
    defer window_request.deinit(std.testing.gpa);
    try std.testing.expect(window_request.update_window.update.isEmpty());
}

test "parse exit request" {
    const json =
        \\{"id":9,"method":"process.exit","code":2}
    ;
    const request = try parseRequest(std.testing.gpa, json);
    defer request.deinit(std.testing.gpa);
    try std.testing.expectEqual(@as(i64, 2), request.exit.code);
}

test "reject invalid update values" {
    const negative_size =
        \\{"id":10,"method":"layer.update","windowId":1,"update":{"height":-1}}
    ;
    try std.testing.expectError(error.InvalidSurfaceField, parseRequest(std.testing.gpa, negative_size));

    const empty_anchors =
        \\{"id":11,"method":"layer.update","windowId":1,"update":{"anchors":[]}}
    ;
    try std.testing.expectError(error.InvalidSurfaceField, parseRequest(std.testing.gpa, empty_anchors));
}

test "reject unsupported method" {
    const json =
        \\{"id":12,"method":"window.spawn","entrypoint":"settings"}
    ;
    try std.testing.expectError(error.UnsupportedSurfaceMethod, parseRequest(std.testing.gpa, json));
}

test "encode responses" {
    const ok = try successResponse(std.testing.gpa, 7);
    defer std.testing.gpa.free(ok);
    try std.testing.expectEqualStrings("{\"id\":7,\"ok\":true}", ok);

    const err = try errorResponse(std.testing.gpa, null, "Bad", "bad request");
    defer std.testing.gpa.free(err);
    try std.testing.expect(std.mem.indexOf(u8, err, "\"ok\":false") != null);
}
