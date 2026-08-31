const std = @import("std");
const builtin = @import("builtin");

pub const channel_name = "flutter/mousecursor";
pub const success_envelope = "\x00\x00";
pub const bad_arguments_envelope =
    "\x01\x07\x0dBad Arguments\x07\x21Argument map missing or malformed\x00";

const activate_method = "activateSystemCursor";
const native_endian = builtin.cpu.arch.endian();

const value_int32: u8 = 3;
const value_int64: u8 = 4;
const value_string: u8 = 7;
const value_map: u8 = 13;

pub const Shape = enum {
    hidden,
    default,
    context_menu,
    help,
    pointer,
    progress,
    wait,
    cell,
    crosshair,
    text,
    vertical_text,
    alias,
    copy,
    move,
    no_drop,
    not_allowed,
    grab,
    grabbing,
    all_scroll,
    col_resize,
    row_resize,
    n_resize,
    e_resize,
    s_resize,
    w_resize,
    ne_resize,
    nw_resize,
    se_resize,
    sw_resize,
    ew_resize,
    ns_resize,
    nesw_resize,
    nwse_resize,
    zoom_in,
    zoom_out,
};

pub const ActivateRequest = struct {
    device: i64,
    kind: []const u8,
    shape: Shape,
};

pub const Request = union(enum) {
    activate_system_cursor: ActivateRequest,
    unsupported,
};

const CursorKindMapping = struct {
    kind: []const u8,
    shape: Shape,
};

const cursor_kind_mappings = [_]CursorKindMapping{
    .{ .kind = "none", .shape = .hidden },
    .{ .kind = "basic", .shape = .default },
    .{ .kind = "click", .shape = .pointer },
    .{ .kind = "forbidden", .shape = .not_allowed },
    .{ .kind = "wait", .shape = .wait },
    .{ .kind = "progress", .shape = .progress },
    .{ .kind = "contextMenu", .shape = .context_menu },
    .{ .kind = "help", .shape = .help },
    .{ .kind = "text", .shape = .text },
    .{ .kind = "verticalText", .shape = .vertical_text },
    .{ .kind = "cell", .shape = .cell },
    .{ .kind = "precise", .shape = .crosshair },
    .{ .kind = "move", .shape = .move },
    .{ .kind = "grab", .shape = .grab },
    .{ .kind = "grabbing", .shape = .grabbing },
    .{ .kind = "noDrop", .shape = .no_drop },
    .{ .kind = "alias", .shape = .alias },
    .{ .kind = "copy", .shape = .copy },
    .{ .kind = "disappearing", .shape = .default },
    .{ .kind = "allScroll", .shape = .all_scroll },
    .{ .kind = "resizeLeftRight", .shape = .ew_resize },
    .{ .kind = "resizeUpDown", .shape = .ns_resize },
    .{ .kind = "resizeUpLeftDownRight", .shape = .nwse_resize },
    .{ .kind = "resizeUpRightDownLeft", .shape = .nesw_resize },
    .{ .kind = "resizeUp", .shape = .n_resize },
    .{ .kind = "resizeDown", .shape = .s_resize },
    .{ .kind = "resizeLeft", .shape = .w_resize },
    .{ .kind = "resizeRight", .shape = .e_resize },
    .{ .kind = "resizeUpLeft", .shape = .nw_resize },
    .{ .kind = "resizeUpRight", .shape = .ne_resize },
    .{ .kind = "resizeDownLeft", .shape = .sw_resize },
    .{ .kind = "resizeDownRight", .shape = .se_resize },
    .{ .kind = "resizeColumn", .shape = .col_resize },
    .{ .kind = "resizeRow", .shape = .row_resize },
    .{ .kind = "zoomIn", .shape = .zoom_in },
    .{ .kind = "zoomOut", .shape = .zoom_out },
};

pub fn shapeForKind(kind: []const u8) Shape {
    for (cursor_kind_mappings) |mapping| {
        if (std.mem.eql(u8, mapping.kind, kind)) return mapping.shape;
    }
    return .default;
}

pub fn decodeRequest(payload: []const u8) !Request {
    var decoder = Decoder{ .payload = payload };
    const method = try decoder.readString();
    if (!std.mem.eql(u8, method, activate_method)) return .unsupported;

    if (try decoder.readByte() != value_map) return error.InvalidArguments;
    const field_count = try decoder.readSize();
    if (field_count > decoder.remaining() / 2) return error.InvalidArguments;

    var device: ?i64 = null;
    var kind: ?[]const u8 = null;
    for (0..field_count) |_| {
        const key = decoder.readString() catch return error.InvalidArguments;
        if (std.mem.eql(u8, key, "device")) {
            if (device != null) return error.InvalidArguments;
            device = decoder.readInteger() catch return error.InvalidArguments;
        } else if (std.mem.eql(u8, key, "kind")) {
            if (kind != null) return error.InvalidArguments;
            kind = decoder.readString() catch return error.InvalidArguments;
        } else {
            return error.InvalidArguments;
        }
    }
    if (decoder.remaining() != 0) return error.InvalidArguments;

    const cursor_kind = kind orelse return error.InvalidArguments;
    return .{ .activate_system_cursor = .{
        .device = device orelse return error.InvalidArguments,
        .kind = cursor_kind,
        .shape = shapeForKind(cursor_kind),
    } };
}

const Decoder = struct {
    payload: []const u8,
    offset: usize = 0,

    fn remaining(self: *const Decoder) usize {
        return self.payload.len - self.offset;
    }

    fn readByte(self: *Decoder) !u8 {
        if (self.offset == self.payload.len) return error.TruncatedMessage;
        defer self.offset += 1;
        return self.payload[self.offset];
    }

    fn readBytes(self: *Decoder, len: usize) ![]const u8 {
        if (len > self.remaining()) return error.TruncatedMessage;
        const bytes = self.payload[self.offset..][0..len];
        self.offset += len;
        return bytes;
    }

    fn readSize(self: *Decoder) !usize {
        const prefix = try self.readByte();
        return switch (prefix) {
            0...253 => prefix,
            254 => @intCast(std.mem.readInt(u16, (try self.readBytes(2))[0..2], native_endian)),
            255 => @intCast(std.mem.readInt(u32, (try self.readBytes(4))[0..4], native_endian)),
        };
    }

    fn readString(self: *Decoder) ![]const u8 {
        if (try self.readByte() != value_string) return error.UnexpectedValueType;
        const value = try self.readBytes(try self.readSize());
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        return value;
    }

    fn readInteger(self: *Decoder) !i64 {
        return switch (try self.readByte()) {
            value_int32 => std.mem.readInt(i32, (try self.readBytes(4))[0..4], native_endian),
            value_int64 => std.mem.readInt(i64, (try self.readBytes(8))[0..8], native_endian),
            else => error.UnexpectedValueType,
        };
    }
};

fn payloadFromHex(comptime hex: []const u8) ![]const u8 {
    const Fixture = struct {
        var bytes: [hex.len / 2]u8 = undefined;
    };
    return try std.fmt.hexToBytes(&Fixture.bytes, hex);
}

test "decode Flutter framework mouse cursor fixtures" {
    const click = try payloadFromHex("0714616374697661746553797374656d437572736f720d020706646576696365030100000007046b696e640705636c69636b");
    const click_request = try decodeRequest(click);
    try std.testing.expectEqual(@as(i64, 1), click_request.activate_system_cursor.device);
    try std.testing.expectEqualStrings("click", click_request.activate_system_cursor.kind);
    try std.testing.expectEqual(.pointer, click_request.activate_system_cursor.shape);

    const none64 = try payloadFromHex("0714616374697661746553797374656d437572736f720d02070664657669636504000000000100000007046b696e6407046e6f6e65");
    const none_request = try decodeRequest(none64);
    try std.testing.expectEqual(@as(i64, 0x100000000), none_request.activate_system_cursor.device);
    try std.testing.expectEqual(.hidden, none_request.activate_system_cursor.shape);

    const unknown_method = try payloadFromHex("0712667574757265437572736f724d6574686f640d020706646576696365030100000007046b696e6407056261736963");
    try std.testing.expectEqual(.unsupported, std.meta.activeTag(try decodeRequest(unknown_method)));
}

test "reject malformed activate request" {
    const missing_device = try payloadFromHex("0714616374697661746553797374656d437572736f720d0107046b696e64070474657874");
    try std.testing.expectError(error.InvalidArguments, decodeRequest(missing_device));

    const click = try payloadFromHex("0714616374697661746553797374656d437572736f720d020706646576696365030100000007046b696e640705636c69636b");
    var trailing: [128]u8 = undefined;
    @memcpy(trailing[0..click.len], click);
    trailing[click.len] = 0;
    try std.testing.expectError(error.InvalidArguments, decodeRequest(trailing[0 .. click.len + 1]));
}

test "response envelopes match Flutter StandardMethodCodec" {
    const expected_success = try payloadFromHex("0000");
    try std.testing.expectEqualSlices(u8, expected_success, success_envelope);

    const expected_error = try payloadFromHex("01070d42616420417267756d656e74730721417267756d656e74206d6170206d697373696e67206f72206d616c666f726d656400");
    try std.testing.expectEqualSlices(u8, expected_error, bad_arguments_envelope);
}

test "map all Flutter 3.41 system cursor kinds" {
    try std.testing.expectEqual(@as(usize, 36), cursor_kind_mappings.len);
    for (cursor_kind_mappings) |mapping| {
        try std.testing.expectEqual(mapping.shape, shapeForKind(mapping.kind));
    }
    try std.testing.expectEqual(.nwse_resize, shapeForKind("resizeUpLeftDownRight"));
    try std.testing.expectEqual(.nesw_resize, shapeForKind("resizeUpRightDownLeft"));
    try std.testing.expectEqual(.default, shapeForKind("futureCursorKind"));
}
