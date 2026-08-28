//! Flutter platform-channel classification, exactly-once response handling, and JSON codecs.

const std = @import("std");
const c = @import("c");
const surface_channel = @import("surface_channel.zig");
const clipboard_service = @import("clipboard_service.zig");

pub const application_channel_name = "dev.fushell/application";

pub const Channel = enum {
    surface,
    text_input,
    platform,
    application,
    unsupported,
};

pub fn classify(name: []const u8) Channel {
    if (std.mem.eql(u8, name, surface_channel.channel_name)) return .surface;
    if (std.mem.eql(u8, name, "flutter/textinput")) return .text_input;
    if (std.mem.eql(u8, name, "flutter/platform")) return .platform;
    if (std.mem.eql(u8, name, application_channel_name)) return .application;
    return .unsupported;
}

pub const SendFn = *const fn (
    context: *anyopaque,
    handle: ?*const c.FlutterPlatformMessageResponseHandle,
    payload: []const u8,
) void;

/// Completes a Flutter response handle at most once and sends an empty response
/// from `deinit` when a malformed or unsupported request takes an early return.
pub const Response = struct {
    context: *anyopaque,
    handle: ?*const c.FlutterPlatformMessageResponseHandle,
    send_fn: SendFn,
    completed: bool = false,
    transferred: bool = false,

    pub fn deinit(self: *Response) void {
        if (!self.completed and !self.transferred) self.send("");
    }

    pub fn send(self: *Response, payload: []const u8) void {
        if (self.completed or self.transferred) return;
        self.completed = true;
        self.send_fn(self.context, self.handle, payload);
    }

    pub fn empty(self: *Response) void {
        self.send("");
    }

    /// Transfers completion ownership to an asynchronous operation.
    pub fn transfer(self: *Response) void {
        if (!self.completed) self.transferred = true;
    }
};

pub fn encodeClipboardText(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    const escaped = try escapeJsonString(gpa, text);
    defer gpa.free(escaped);
    return std.fmt.allocPrint(gpa, "[{{\"text\":\"{s}\"}}]", .{escaped});
}

pub fn encodeClipboardHasStrings(gpa: std.mem.Allocator, has_strings: bool) ![]u8 {
    return std.fmt.allocPrint(gpa, "[{{\"value\":{}}}]", .{has_strings});
}

/// Flutter JSONMethodCodec error envelope: [code, message, details].
pub fn encodeMethodError(gpa: std.mem.Allocator, code: []const u8, message: []const u8) ![]u8 {
    const escaped_code = try escapeJsonString(gpa, code);
    defer gpa.free(escaped_code);
    const escaped_message = try escapeJsonString(gpa, message);
    defer gpa.free(escaped_message);
    return std.fmt.allocPrint(gpa, "[\"{s}\",\"{s}\",null]", .{ escaped_code, escaped_message });
}

pub fn decodeHexAlloc(gpa: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len % 2 != 0) return error.InvalidHex;
    const decoded = try gpa.alloc(u8, encoded.len / 2);
    errdefer gpa.free(decoded);
    for (decoded, 0..) |*byte, index| {
        byte.* = try std.fmt.parseInt(u8, encoded[index * 2 .. index * 2 + 2], 16);
    }
    return decoded;
}

pub fn escapeJsonString(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    for (input) |byte| {
        switch (byte) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            0...0x1f => {
                var encoded: [6]u8 = undefined;
                _ = try std.fmt.bufPrint(&encoded, "\\u{x:0>4}", .{byte});
                try out.appendSlice(gpa, &encoded);
            },
            else => try out.append(gpa, byte),
        }
    }
    return out.toOwnedSlice(gpa);
}

pub fn handleTextInputMessage(runner: anytype, message: c.FlutterPlatformMessage, payload: []const u8, send_fn: SendFn) void {
    var reply: Response = .{
        .context = runner,
        .handle = message.response_handle,
        .send_fn = send_fn,
    };
    runner.active_platform_response = &reply;
    defer runner.active_platform_response = null;
    defer reply.deinit();

    var parsed = std.json.parseFromSlice(std.json.Value, runner.gpa, payload, .{}) catch {
        runner.sendPlatformMethodError(message.response_handle, "BadArguments", "text input message is not valid JSON");
        return;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |m| m,
        else => {
            runner.sendPlatformMethodError(message.response_handle, "BadArguments", "text input message must be a JSON object");
            return;
        },
    };
    const method_value = root.get("method") orelse {
        runner.sendPlatformMethodError(message.response_handle, "BadArguments", "text input message is missing method");
        return;
    };
    const method = switch (method_value) {
        .string => |s| s,
        else => {
            runner.sendPlatformMethodError(message.response_handle, "BadArguments", "text input method must be a string");
            return;
        },
    };
    const args = root.get("args");

    if (std.mem.eql(u8, method, "TextInput.setClient")) {
        if (args == null or args.? != .array or args.?.array.items.len < 2) {
            runner.sendPlatformMethodError(message.response_handle, "BadArguments", "TextInput.setClient expects [clientId, configuration]");
            return;
        }
        const id = switch (args.?.array.items[0]) {
            .integer => |i| i,
            else => {
                runner.sendPlatformMethodError(message.response_handle, "BadArguments", "TextInput.setClient client id must be an integer");
                return;
            },
        };
        const config = args.?.array.items[1];
        var multiline = false;
        var action: []const u8 = "done";
        if (config == .object) {
            if (config.object.get("inputAction")) |ia| {
                if (ia == .string) action = ia.string;
            }
            if (config.object.get("inputType")) |it| {
                if (it == .object) {
                    if (it.object.get("isMultiline")) |ml| {
                        if (ml == .bool) multiline = ml.bool;
                    }
                }
            }
        }
        runner.text_client.clear();
        runner.text_client.client_id = id;
        runner.text_client.active = true;
        runner.text_client.multiline = multiline;
        runner.text_client.input_action = action;
        // TextField 聚焦: 启用 IME + 候选框定位。
        // 优先用引擎提供的 EditableText 几何 (transform + marked rect → 真实光标),
        // 避免 popup 先出现在点击处再跳到光标处的闪烁。
        if (runner.ime) |ime| {
            if (runner.text_client.has_transform and runner.text_client.has_marked_rect) {
                runner.updateImeCursorPosition();
            } else if (runner.focused_host) |focused| {
                // fallback: 焦点窗口的指针位置 (引擎几何未到)。
                ime.setCursorRect(
                    @intFromFloat(@max(focused.pointer_x, 0)),
                    @intFromFloat(@max(focused.pointer_y, 0)),
                    4,
                    24,
                );
            } else {
                ime.setCursorRect(0, 0, 4, 24);
            }
            ime.enable(0, 1);
        }
        runner.sendEmptyPlatformResponse(message.response_handle);
        return;
    }
    if (std.mem.eql(u8, method, "TextInput.setEditableSizeAndTransform")) {
        // EditableText 局部 → Flutter root 变换矩阵 (官方 GTK 嵌入器同款协议)。
        if (args != null and args.? == .object) {
            if (args.?.object.get("transform")) |tv| {
                if (tv == .array and tv.array.items.len == 16) {
                    var ok = true;
                    for (tv.array.items, 0..) |item, i| {
                        runner.text_client.transform[i] = switch (item) {
                            .float => |f| f,
                            .integer => |iv| @floatFromInt(iv),
                            else => {
                                ok = false;
                                break;
                            },
                        };
                    }
                    if (ok) runner.text_client.has_transform = true;
                }
            }
        }
        // transform 到达不代表 rect 到达; 有 rect 时更新候选框位置。
        if (runner.text_client.has_marked_rect) runner.updateImeCursorPosition();
        runner.sendEmptyPlatformResponse(message.response_handle);
        return;
    }
    if (std.mem.eql(u8, method, "TextInput.setMarkedTextRect")) {
        // composing 区域 / 光标矩形 (局部坐标, 无 composing 时即光标)。
        if (args != null and args.? == .object) {
            const o = args.?.object;
            const getF = struct {
                fn getv(m: std.json.ObjectMap, key: []const u8) ?f64 {
                    const v = m.get(key) orelse return null;
                    return switch (v) {
                        .float => |fv| fv,
                        .integer => |iv| @floatFromInt(iv),
                        else => null,
                    };
                }
            }.getv;
            if (getF(o, "x")) |x| {
                runner.text_client.marked_rect_x = x;
                runner.text_client.marked_rect_y = getF(o, "y") orelse 0;
                runner.text_client.marked_rect_w = getF(o, "width") orelse 0;
                runner.text_client.marked_rect_h = getF(o, "height") orelse 0;
                runner.text_client.has_marked_rect = true;
                runner.updateImeCursorPosition();
            }
        }
        runner.sendEmptyPlatformResponse(message.response_handle);
        return;
    }
    if (std.mem.eql(u8, method, "TextInput.setCaretRect")) {
        // 光标矩形 (EditableText 光标移动时发送, Flutter 3.41 独立方法)。
        if (args != null and args.? == .object) {
            const o = args.?.object;
            const getF = struct {
                fn getv(m: std.json.ObjectMap, key: []const u8) ?f64 {
                    const v = m.get(key) orelse return null;
                    return switch (v) {
                        .float => |fv| fv,
                        .integer => |iv| @floatFromInt(iv),
                        else => null,
                    };
                }
            }.getv;
            if (getF(o, "x")) |x| {
                runner.text_client.caret_rect_x = x;
                runner.text_client.caret_rect_y = getF(o, "y") orelse 0;
                runner.text_client.has_caret_rect = true;
                runner.updateImeCursorPosition();
            }
        }
        runner.sendEmptyPlatformResponse(message.response_handle);
        return;
    }
    if (std.mem.eql(u8, method, "TextInput.setEditingState")) {
        // Flutter 端: invokeMethod('TextInput.setEditingState', value.toJSON())
        // → args 直接是 object (不是 [object] array, 与 setClient 不同)。
        if (args == null or args.? != .object) {
            runner.sendPlatformMethodError(message.response_handle, "BadArguments", "TextInput.setEditingState expects an object");
            return;
        }
        const state = args.?;
        if (state == .object) {
            var text: []const u8 = "";
            var base: i64 = 0;
            var extent: i64 = 0;
            if (state.object.get("text")) |t| {
                if (t == .string) text = t.string;
            }
            if (state.object.get("selectionBase")) |b| {
                if (b == .integer) base = b.integer;
            }
            if (state.object.get("selectionExtent")) |e| {
                if (e == .integer) extent = e.integer;
            }
            runner.text_client.applyEditingState(text, base, extent) catch |err| {
                std.debug.print("[error] apply editing state failed: {s}\n", .{@errorName(err)});
            };
        }
        runner.sendEmptyPlatformResponse(message.response_handle);
        return;
    }
    if (std.mem.eql(u8, method, "TextInput.show")) {
        if (runner.text_client.active) {
            if (runner.ime) |ime| ime.enable(0, 1);
        }
        runner.sendEmptyPlatformResponse(message.response_handle);
        return;
    }
    if (std.mem.eql(u8, method, "TextInput.hide")) {
        if (runner.ime) |ime| ime.disable();
        runner.sendEmptyPlatformResponse(message.response_handle);
        return;
    }
    if (std.mem.eql(u8, method, "TextInput.clearClient")) {
        runner.text_client.clear();
        if (runner.ime) |ime| ime.disable();
        runner.sendEmptyPlatformResponse(message.response_handle);
        return;
    }
    // requestAutofill 等当前未实现的方法仍必须完成 response handle。
    runner.sendEmptyPlatformResponse(message.response_handle);
}

/// flutter/platform 通道: Clipboard.setData / getData, 其余空响应。
pub fn handlePlatformChannelMessage(runner: anytype, message: c.FlutterPlatformMessage, payload: []const u8, send_fn: SendFn) void {
    var reply: Response = .{
        .context = runner,
        .handle = message.response_handle,
        .send_fn = send_fn,
    };
    runner.active_platform_response = &reply;
    defer runner.active_platform_response = null;
    defer reply.deinit();

    var parsed = std.json.parseFromSlice(std.json.Value, runner.gpa, payload, .{}) catch {
        runner.sendEmptyPlatformResponse(message.response_handle);
        return;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |m| m,
        else => {
            runner.sendEmptyPlatformResponse(message.response_handle);
            return;
        },
    };
    const method_value = root.get("method") orelse {
        runner.sendEmptyPlatformResponse(message.response_handle);
        return;
    };
    const method = switch (method_value) {
        .string => |s| s,
        else => {
            runner.sendEmptyPlatformResponse(message.response_handle);
            return;
        },
    };
    const args = root.get("args");

    if (std.mem.eql(u8, method, "Clipboard.setData")) {
        const text: ?[]const u8 = if (args) |value| switch (value) {
            .object => |object| if (object.get("text")) |field|
                if (field == .string) field.string else null
            else
                null,
            else => null,
        } else null;
        if (text) |t| {
            runner.clipboard.setText(t) catch |err| {
                std.debug.print("[error] clipboard set failed: {s}\n", .{@errorName(err)});
            };
        } else {
            std.debug.print("[error] Clipboard.setData: no text in args\n", .{});
        }
        runner.sendEmptyPlatformResponse(message.response_handle);
        return;
    }
    if (std.mem.eql(u8, method, "Clipboard.hasStrings")) {
        // Flutter 3.35+: Ctrl+V 前先查剪贴板是否有内容, 期待 {"value": bool}。
        const response = encodeClipboardHasStrings(runner.gpa, runner.clipboard.hasText()) catch |err| {
            std.debug.print("[error] clipboard hasStrings response allocation failed: {s}\n", .{@errorName(err)});
            runner.sendEmptyPlatformResponse(message.response_handle);
            return;
        };
        defer runner.gpa.free(response);
        runner.sendPlatformResponse(message.response_handle, response);
        return;
    }
    if (std.mem.eql(u8, method, "Clipboard.getData")) {
        if (runner.pending_clipboard_read != null) {
            runner.sendPlatformMethodError(message.response_handle, "ClipboardBusy", "another clipboard read is already pending");
            return;
        }
        const start = runner.clipboard.beginReadText() catch |err| {
            const message_text = std.fmt.allocPrint(runner.gpa, "clipboard read failed: {s}", .{@errorName(err)}) catch {
                runner.sendEmptyPlatformResponse(message.response_handle);
                return;
            };
            defer runner.gpa.free(message_text);
            runner.sendPlatformMethodError(message.response_handle, "ClipboardReadFailed", message_text);
            return;
        };
        switch (start) {
            .immediate => |text| {
                defer runner.gpa.free(text);
                const response = encodeClipboardText(runner.gpa, text) catch |err| {
                    std.debug.print("[error] clipboard getData response allocation failed: {s}\n", .{@errorName(err)});
                    runner.sendEmptyPlatformResponse(message.response_handle);
                    return;
                };
                defer runner.gpa.free(response);
                runner.sendPlatformResponse(message.response_handle, response);
            },
            .pending => {
                reply.transfer();
                runner.pending_clipboard_read = .{
                    .destination = .platform,
                    .response_handle = message.response_handle,
                    .deadline_ns = nowNs() + clipboard_service.read_timeout_ns,
                };
            },
        }
        return;
    }
    // SystemSound / HapticFeedback / SystemChrome 等: 空响应 (引擎不阻塞)。
    runner.sendEmptyPlatformResponse(message.response_handle);
}

pub fn handleApplicationChannelMessage(runner: anytype, message: c.FlutterPlatformMessage, payload: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, runner.gpa, payload, .{}) catch {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "invalid JSON request");
        return;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => {
            runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "request must be an object");
            return;
        },
    };
    const method = if (root.get("method")) |value| switch (value) {
        .string => |string| string,
        else => null,
    } else null;

    if (method != null and std.mem.eql(u8, method.?, "ready")) {
        runner.applicationSetReady();
        runner.sendPlatformResponse(message.response_handle, "[null]");
        return;
    }
    if (method == null or !std.mem.eql(u8, method.?, "complete")) {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "unsupported application method");
        return;
    }

    const args = if (root.get("args")) |value| switch (value) {
        .object => |object| object,
        else => null,
    } else null;
    const fields = args orelse {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "complete args must be an object");
        return;
    };
    const id_value = fields.get("id") orelse {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "complete id is required");
        return;
    };
    const exit_value = fields.get("exitCode") orelse {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "complete exitCode is required");
        return;
    };
    const id = switch (id_value) {
        .integer => |value| if (value >= 0) @as(?u64, @intCast(value)) else null,
        else => null,
    } orelse {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "complete id is invalid");
        return;
    };
    const exit_code = switch (exit_value) {
        .integer => |value| if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) @as(?i32, @intCast(value)) else null,
        else => null,
    } orelse {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "complete exitCode is invalid");
        return;
    };
    const stdout_hex = if (fields.get("stdoutHex")) |value| switch (value) {
        .string => |string| string,
        else => null,
    } else "";
    const stderr_hex = if (fields.get("stderrHex")) |value| switch (value) {
        .string => |string| string,
        else => null,
    } else "";
    if (stdout_hex == null or stderr_hex == null or stdout_hex.?.len > 8 * 1024 * 1024 or stderr_hex.?.len > 8 * 1024 * 1024) {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "complete output is invalid or too large");
        return;
    }
    const stdout_bytes = decodeHexAlloc(runner.gpa, stdout_hex.?) catch {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "stdoutHex is invalid");
        return;
    };
    defer runner.gpa.free(stdout_bytes);
    const stderr_bytes = decodeHexAlloc(runner.gpa, stderr_hex.?) catch {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "stderrHex is invalid");
        return;
    };
    defer runner.gpa.free(stderr_bytes);

    runner.applicationComplete(id, exit_code, stdout_bytes, stderr_bytes);
    runner.sendPlatformResponse(message.response_handle, "[null]");
}

pub fn handleSurfaceChannelMessage(runner: anytype, message: c.FlutterPlatformMessage, payload: []const u8) void {
    const request = surface_channel.parseRequest(runner.gpa, payload) catch |err| {
        const code = surface_channel.parseErrorCode(err);
        std.debug.print("[error] Invalid fushell surface message: {s}\n", .{code});
        runner.sendSurfaceError(message.response_handle, null, code, "invalid fushell surface request");
        return;
    };
    defer request.deinit(runner.gpa);

    runner.handleSurfaceRequest(message.response_handle, request) catch |err| {
        const code = runner.surfaceRequestErrorCode(err);
        std.debug.print("[error] Fushell surface request failed: {s}\n", .{code});
        runner.sendSurfaceError(message.response_handle, request.id(), code, "fushell surface request failed");
        return;
    };
}

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "response completes exactly once" {
    const Recorder = struct {
        count: usize = 0,
        payload: []const u8 = "",
        fn send(context: *anyopaque, _: ?*const c.FlutterPlatformMessageResponseHandle, payload: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            self.payload = payload;
        }
    };
    var recorder: Recorder = .{};
    var response: Response = .{ .context = &recorder, .handle = null, .send_fn = Recorder.send };
    response.send("ok");
    response.empty();
    response.deinit();
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqualStrings("ok", recorder.payload);
}

test "response guard completes early return with empty payload" {
    const Recorder = struct {
        count: usize = 0,
        fn send(context: *anyopaque, _: ?*const c.FlutterPlatformMessageResponseHandle, _: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
        }
    };
    var recorder: Recorder = .{};
    {
        var response: Response = .{ .context = &recorder, .handle = null, .send_fn = Recorder.send };
        defer response.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
}

test "method error uses a valid JSONMethodCodec envelope" {
    const encoded = try encodeMethodError(std.testing.allocator, "ClipboardReadFailed", "read failed: \"pipe\"");
    defer std.testing.allocator.free(encoded);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("ClipboardReadFailed", parsed.value.array.items[0].string);
    try std.testing.expectEqualStrings("read failed: \"pipe\"", parsed.value.array.items[1].string);
    try std.testing.expect(parsed.value.array.items[2] == .null);
}

test "clipboard JSON supports escaped payloads larger than four KiB" {
    const gpa = std.testing.allocator;
    const input = try gpa.alloc(u8, 8196);
    defer gpa.free(input);
    @memset(input, 'x');
    input[1] = '"';
    input[2] = '\\';
    input[3] = '\n';
    const encoded = try encodeClipboardText(gpa, input);
    defer gpa.free(encoded);
    try std.testing.expect(encoded.len > 8196);
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(input, parsed.value.array.items[0].object.get("text").?.string);
}
