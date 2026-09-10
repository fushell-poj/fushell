//! Flutter platform-channel classification, exactly-once response handling, and channel codecs.

const std = @import("std");
const c = @import("c");
const surface_channel = @import("surface_channel.zig");
const mouse_cursor = @import("mouse_cursor.zig");
const clipboard_service = @import("clipboard_service.zig");
const application_output = @import("application_output.zig");

pub const application_channel_name = "dev.fushell/application";
pub const window_events_channel_name = "dev.fushell/window-events";

pub const Channel = enum {
    surface,
    text_input,
    platform,
    mouse_cursor,
    application,
    unsupported,
};

pub fn classify(name: []const u8) Channel {
    if (std.mem.eql(u8, name, surface_channel.channel_name)) return .surface;
    if (std.mem.eql(u8, name, "flutter/textinput")) return .text_input;
    if (std.mem.eql(u8, name, "flutter/platform")) return .platform;
    if (std.mem.eql(u8, name, mouse_cursor.channel_name)) return .mouse_cursor;
    if (std.mem.eql(u8, name, application_channel_name)) return .application;
    return .unsupported;
}

pub const ResponseSendResult = enum {
    sent,
    not_requested,
    engine_unavailable,
    engine_failed,
    already_completed,
};

pub fn responseSendIsFatal(result: ResponseSendResult) bool {
    return result == .engine_unavailable or result == .engine_failed;
}

pub const SendFn = *const fn (
    context: *anyopaque,
    handle: ?*const c.FlutterPlatformMessageResponseHandle,
    payload: []const u8,
) ResponseSendResult;

/// Completes a Flutter response handle at most once and sends an empty response
/// from `deinit` when a malformed or unsupported request takes an early return.
pub const Response = struct {
    context: *anyopaque,
    handle: ?*const c.FlutterPlatformMessageResponseHandle,
    send_fn: SendFn,
    completed: bool = false,
    transferred: bool = false,

    pub fn deinit(self: *Response) void {
        if (!self.completed and !self.transferred) _ = self.send("");
    }

    pub fn send(self: *Response, payload: []const u8) ResponseSendResult {
        if (self.completed or self.transferred) return .already_completed;
        self.completed = true;
        return self.send_fn(self.context, self.handle, payload);
    }

    pub fn empty(self: *Response) ResponseSendResult {
        return self.send("");
    }

    /// Transfers completion ownership to an asynchronous operation.
    pub fn transfer(self: *Response) void {
        if (!self.completed) self.transferred = true;
    }
};

pub fn encodeWindowClosedEvent(gpa: std.mem.Allocator, window_id: i64) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "{{\"event\":\"window.closed\",\"windowId\":{d}}}",
        .{window_id},
    );
}

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

pub fn validateWriteDataHex(encoded: []const u8) !void {
    if (encoded.len > 65_536) return error.OutputFrameTooLarge;
    if (encoded.len % 2 != 0) return error.InvalidHex;
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

fn textInputConfiguration(config: std.json.Value) !struct { action: []const u8, multiline: bool } {
    if (config != .object) return error.BadArguments;
    var action: []const u8 = "TextInputAction.done";
    if (config.object.get("inputAction")) |value| {
        if (value != .string) return error.BadArguments;
        action = value.string;
    }
    var multiline = false;
    if (config.object.get("inputType")) |value| {
        if (value != .object) return error.BadArguments;
        if (value.object.get("name")) |name| {
            if (name != .string) return error.BadArguments;
            multiline = std.mem.eql(u8, name.string, "TextInputType.multiline");
        } else if (value.object.get("isMultiline")) |legacy| {
            if (legacy != .bool) return error.BadArguments;
            multiline = legacy.bool;
        }
    }
    return .{ .action = action, .multiline = multiline };
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
        if (args == null or args.? != .array or args.?.array.items.len != 2) {
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
        const configuration = textInputConfiguration(config) catch {
            runner.sendPlatformMethodError(message.response_handle, "BadArguments", "Invalid text input configuration");
            return;
        };
        runner.text_client.clear();
        runner.text_client.setInputAction(configuration.action) catch {
            runner.sendPlatformMethodError(message.response_handle, "OutOfMemory", "Unable to retain input action");
            return;
        };
        runner.text_client.client_id = id;
        runner.text_client.active = true;
        runner.text_client.multiline = configuration.multiline;
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
        const values = if (args != null and args.? == .object) args.?.object.get("transform") else null;
        if (values == null or values.? != .array or values.?.array.items.len != 16) {
            runner.sendPlatformMethodError(message.response_handle, "BadArguments", "transform must contain 16 numbers");
            return;
        }
        var transform: [16]f64 = undefined;
        for (values.?.array.items, 0..) |value, i| {
            const number: f64 = switch (value) {
                .float => |f| f,
                .integer => |n| @floatFromInt(n),
                else => {
                    runner.sendPlatformMethodError(message.response_handle, "BadArguments", "transform must contain numbers");
                    return;
                },
            };
            if (!std.math.isFinite(number)) {
                runner.sendPlatformMethodError(message.response_handle, "BadArguments", "transform must contain finite numbers");
                return;
            }
            transform[i] = number;
        }
        runner.text_client.transform = transform;
        runner.text_client.has_transform = true;
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
        if (args == null or args.? != .object) {
            runner.sendPlatformMethodError(message.response_handle, "BadArguments", "TextInput.setEditingState expects an object");
            return;
        }
        const fields = args.?.object;
        const text = fields.get("text");
        if (text == null or text.? != .string) {
            runner.sendPlatformMethodError(message.response_handle, "BadArguments", "Editing text must be a string");
            return;
        }
        var offsets = [_]i64{ 0, 0, -1, -1 };
        for ([_][]const u8{ "selectionBase", "selectionExtent", "composingBase", "composingExtent" }, 0..) |key, i| {
            if (fields.get(key)) |value| {
                if (value != .integer) {
                    runner.sendPlatformMethodError(message.response_handle, "BadArguments", "Editing offsets must be integers");
                    return;
                }
                offsets[i] = value.integer;
            }
        }
        runner.text_client.applyEditingStateWithComposing(text.?.string, offsets[0], offsets[1], offsets[2], offsets[3]) catch |err| {
            runner.sendPlatformMethodError(message.response_handle, @errorName(err), "Unable to update editing state");
            return;
        };
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

pub fn handleMouseCursorMessage(runner: anytype, message: c.FlutterPlatformMessage, payload: []const u8, send_fn: SendFn) void {
    var reply: Response = .{
        .context = runner,
        .handle = message.response_handle,
        .send_fn = send_fn,
    };
    runner.active_platform_response = &reply;
    defer runner.active_platform_response = null;
    defer reply.deinit();

    const request = mouse_cursor.decodeRequest(payload) catch {
        _ = reply.send(mouse_cursor.bad_arguments_envelope);
        return;
    };
    switch (request) {
        .unsupported => _ = reply.empty(),
        .activate_system_cursor => |activate| {
            // Flutter 的 device 对应 engine pointer device id；Fushell 当前只向引擎
            // 注册 device 0 和单个 wl_pointer，因此验证 wire type 后由共享 pointer 处理。
            _ = activate.device;
            if (!runner.state.activateCursorShape(activate.shape)) {
                _ = reply.empty();
                return;
            }
            _ = reply.send(mouse_cursor.success_envelope);
        },
    }
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
    if (method == null) {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "application method is required");
        return;
    }

    const args = if (root.get("args")) |value| switch (value) {
        .object => |object| object,
        else => null,
    } else null;
    const fields = args orelse {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "application args must be an object");
        return;
    };
    const id_value = fields.get("id") orelse {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "application id is required");
        return;
    };
    const id = switch (id_value) {
        .integer => |value| if (value >= 0) @as(?u64, @intCast(value)) else null,
        else => null,
    } orelse {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "application id is invalid");
        return;
    };

    if (std.mem.eql(u8, method.?, "write")) {
        if (fields.count() != 3) {
            runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "write args must contain only id, stream, and dataHex");
            return;
        }
        const stream_value = fields.get("stream") orelse {
            runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "write stream is required");
            return;
        };
        const stream = switch (stream_value) {
            .integer => |value| switch (value) {
                1 => application_output.Stream.stdout,
                2 => application_output.Stream.stderr,
                else => null,
            },
            else => null,
        } orelse {
            runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "write stream must be 1 or 2");
            return;
        };
        const data_value = fields.get("dataHex") orelse {
            runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "write dataHex is required");
            return;
        };
        const data_hex = switch (data_value) {
            .string => |value| value,
            else => null,
        } orelse {
            runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "write dataHex must be a string");
            return;
        };
        validateWriteDataHex(data_hex) catch |err| {
            const code = if (err == error.OutputFrameTooLarge) "ApplicationOutputLimit" else "ApplicationProtocol";
            runner.sendPlatformMethodError(message.response_handle, code, "write dataHex has an invalid frame size");
            return;
        };
        const data = decodeHexAlloc(runner.gpa, data_hex) catch {
            runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "write dataHex is invalid");
            return;
        };
        defer runner.gpa.free(data);
        switch (runner.applicationWrite(message.response_handle, id, stream, data)) {
            .committed, .detached => runner.sendPlatformResponse(message.response_handle, "[null]"),
            .pending => runner.deferApplicationWriteResponse(message.response_handle, id),
            .failed => {},
        }
        return;
    }

    if (!std.mem.eql(u8, method.?, "complete")) {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "unsupported application method");
        return;
    }
    if (fields.count() != 2) {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "complete args must contain only id and exitCode");
        return;
    }
    const exit_value = fields.get("exitCode") orelse {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "complete exitCode is required");
        return;
    };
    const exit_code = switch (exit_value) {
        .integer => |value| if (value >= 0 and value <= 255) @as(?i32, @intCast(value)) else null,
        else => null,
    } orelse {
        runner.sendPlatformMethodError(message.response_handle, "ApplicationProtocol", "complete exitCode must be between 0 and 255");
        return;
    };

    runner.applicationComplete(message.response_handle, id, exit_code);
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

test "classify Flutter mouse cursor channel" {
    try std.testing.expectEqual(.mouse_cursor, classify(mouse_cursor.channel_name));
}

test "mouse cursor channel returns codec-compatible responses exactly once" {
    const FakeState = struct {
        available: bool,
        call_count: usize = 0,
        last_shape: ?mouse_cursor.Shape = null,

        fn activateCursorShape(self: *@This(), shape: mouse_cursor.Shape) bool {
            if (!self.available) return false;
            self.call_count += 1;
            self.last_shape = shape;
            return true;
        }
    };
    const FakeRunner = struct {
        state: *FakeState,
        active_platform_response: ?*Response = null,
        response_count: usize = 0,
        response_payload: []const u8 = "",

        fn send(context: *anyopaque, _: ?*const c.FlutterPlatformMessageResponseHandle, payload: []const u8) ResponseSendResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.response_count += 1;
            self.response_payload = payload;
            return .sent;
        }
    };
    const message = std.mem.zeroes(c.FlutterPlatformMessage);

    const click = try decodeHexAlloc(std.testing.allocator, "0714616374697661746553797374656d437572736f720d020706646576696365030100000007046b696e640705636c69636b");
    defer std.testing.allocator.free(click);
    var available_state: FakeState = .{ .available = true };
    var success_runner: FakeRunner = .{ .state = &available_state };
    handleMouseCursorMessage(&success_runner, message, click, FakeRunner.send);
    try std.testing.expectEqual(@as(usize, 1), success_runner.response_count);
    try std.testing.expectEqualStrings(mouse_cursor.success_envelope, success_runner.response_payload);
    try std.testing.expectEqual(@as(usize, 1), available_state.call_count);
    try std.testing.expectEqual(.pointer, available_state.last_shape.?);

    var missing_state: FakeState = .{ .available = false };
    var missing_runner: FakeRunner = .{ .state = &missing_state };
    handleMouseCursorMessage(&missing_runner, message, click, FakeRunner.send);
    try std.testing.expectEqual(@as(usize, 1), missing_runner.response_count);
    try std.testing.expectEqualStrings("", missing_runner.response_payload);

    const malformed = try decodeHexAlloc(std.testing.allocator, "0714616374697661746553797374656d437572736f720d0107046b696e64070474657874");
    defer std.testing.allocator.free(malformed);
    var malformed_runner: FakeRunner = .{ .state = &available_state };
    handleMouseCursorMessage(&malformed_runner, message, malformed, FakeRunner.send);
    try std.testing.expectEqual(@as(usize, 1), malformed_runner.response_count);
    try std.testing.expectEqualStrings(mouse_cursor.bad_arguments_envelope, malformed_runner.response_payload);
    try std.testing.expectEqual(@as(usize, 1), available_state.call_count);

    const unknown = try decodeHexAlloc(std.testing.allocator, "0712667574757265437572736f724d6574686f640d020706646576696365030100000007046b696e6407056261736963");
    defer std.testing.allocator.free(unknown);
    var unknown_runner: FakeRunner = .{ .state = &available_state };
    handleMouseCursorMessage(&unknown_runner, message, unknown, FakeRunner.send);
    try std.testing.expectEqual(@as(usize, 1), unknown_runner.response_count);
    try std.testing.expectEqualStrings("", unknown_runner.response_payload);
    try std.testing.expectEqual(@as(usize, 1), available_state.call_count);
}

test "window close event carries the completed view id" {
    const payload = try encodeWindowClosedEvent(std.testing.allocator, 42);
    defer std.testing.allocator.free(payload);

    try std.testing.expectEqualStrings(
        "{\"event\":\"window.closed\",\"windowId\":42}",
        payload,
    );
}

test "application write hex validation enforces even 32 KiB frames" {
    try validateWriteDataHex("");
    try validateWriteDataHex("00");
    try validateWriteDataHex(&[_]u8{'a'} ** 65_536);
    try std.testing.expectError(error.InvalidHex, validateWriteDataHex("0"));
    try std.testing.expectError(error.OutputFrameTooLarge, validateWriteDataHex(&[_]u8{'a'} ** 65_538));
}

test "response completes exactly once" {
    const Recorder = struct {
        count: usize = 0,
        payload: []const u8 = "",
        fn send(context: *anyopaque, _: ?*const c.FlutterPlatformMessageResponseHandle, payload: []const u8) ResponseSendResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            self.payload = payload;
            return .sent;
        }
    };
    var recorder: Recorder = .{};
    var response: Response = .{ .context = &recorder, .handle = null, .send_fn = Recorder.send };
    _ = response.send("ok");
    response.empty();
    response.deinit();
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expectEqualStrings("ok", recorder.payload);
}

test "response guard completes early return with empty payload" {
    const Recorder = struct {
        count: usize = 0,
        fn send(context: *anyopaque, _: ?*const c.FlutterPlatformMessageResponseHandle, _: []const u8) ResponseSendResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            return .sent;
        }
    };
    var recorder: Recorder = .{};
    {
        var response: Response = .{ .context = &recorder, .handle = null, .send_fn = Recorder.send };
        defer response.deinit();
    }
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
}

test "injected response failure remains exactly once and is fatal" {
    const Recorder = struct {
        count: usize = 0,
        fn send(context: *anyopaque, _: ?*const c.FlutterPlatformMessageResponseHandle, _: []const u8) ResponseSendResult {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.count += 1;
            return .engine_failed;
        }
    };
    var recorder: Recorder = .{};
    var response: Response = .{ .context = &recorder, .handle = null, .send_fn = Recorder.send };
    try std.testing.expectEqual(ResponseSendResult.engine_failed, response.send("failure"));
    try std.testing.expectEqual(ResponseSendResult.already_completed, response.send("retry"));
    response.deinit();
    try std.testing.expectEqual(@as(usize, 1), recorder.count);
    try std.testing.expect(responseSendIsFatal(.engine_failed));
    try std.testing.expect(!responseSendIsFatal(.sent));
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

const TextInputTestRunner = struct {
    gpa: std.mem.Allocator,
    text_client: @import("text_input.zig").Client,
    active_platform_response: ?*Response = null,
    response_count: usize = 0,
    error_code: ?[]const u8 = null,
    cursor_updates: usize = 0,
    ime: ?*Ime = null,
    focused_host: ?*struct { pointer_x: f64, pointer_y: f64 } = null,

    const Ime = struct {
        fn enable(_: *@This(), _: u32, _: u32) void {}
        fn disable(_: *@This()) void {}
        fn setCursorRect(_: *@This(), _: i32, _: i32, _: i32, _: i32) void {}
    };

    fn send(context: *anyopaque, _: ?*const c.FlutterPlatformMessageResponseHandle, _: []const u8) ResponseSendResult {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.response_count += 1;
        return .sent;
    }

    fn sendEmptyPlatformResponse(self: *@This(), _: ?*const c.FlutterPlatformMessageResponseHandle) void {
        _ = self.active_platform_response.?.empty();
    }

    fn sendPlatformMethodError(self: *@This(), _: ?*const c.FlutterPlatformMessageResponseHandle, code: []const u8, _: []const u8) void {
        self.error_code = code;
        _ = self.active_platform_response.?.send("error");
    }

    fn updateImeCursorPosition(self: *@This()) void {
        self.cursor_updates += 1;
    }

    fn dispatch(self: *@This(), payload: []const u8) !void {
        self.error_code = null;
        const previous_count = self.response_count;
        handleTextInputMessage(self, std.mem.zeroes(c.FlutterPlatformMessage), payload, send);
        try std.testing.expectEqual(previous_count + 1, self.response_count);
        try std.testing.expect(self.active_platform_response == null);
    }
};

test "text input handler owns parsed action through Enter and repeated client lifecycle" {
    var parser_storage: [16384]u8 = undefined;
    var parser = std.heap.FixedBufferAllocator.init(&parser_storage);
    var runner: TextInputTestRunner = .{
        .gpa = parser.allocator(),
        .text_client = .init(std.testing.allocator),
    };
    defer runner.text_client.deinit();
    for (0..3) |_| {
        parser.reset();
        // The JSON escape forces action storage into the parser's allocation.
        try runner.dispatch(
            \\{"method":"TextInput.setClient","args":[42,{"inputAction":"TextInputAction.sen\u0064","inputType":{"name":"TextInputType.multiline"}}]}
        );
        try std.testing.expect(runner.error_code == null);
        @memset(&parser_storage, 0xa5);
        var output: [256]u8 = undefined;
        const action = try runner.text_client.buildActionMessage(&output);
        try std.testing.expectEqualStrings(
            \\{"method":"TextInputClient.performAction","args":[42,"TextInputAction.send"]}
        , action);
        try std.testing.expect(runner.text_client.multiline);
        parser.reset();
        try runner.dispatch(
            \\{"method":"TextInput.clearClient"}
        );
        try std.testing.expect(!runner.text_client.active);
        try std.testing.expectEqualStrings("TextInputAction.done", runner.text_client.input_action);
        parser.reset();
        try runner.dispatch(
            \\{"method":"TextInput.setClient","args":[43,{}]}
        );
        try std.testing.expect(runner.text_client.active);
        try std.testing.expect(!runner.text_client.multiline);
        try std.testing.expectEqualStrings("TextInputAction.done", runner.text_client.input_action);
    }
}

test "text input handler rejects malformed state without partial mutation" {
    var runner: TextInputTestRunner = .{ .gpa = std.testing.allocator, .text_client = .init(std.testing.allocator) };
    defer runner.text_client.deinit();
    try runner.dispatch(
        \\{"method":"TextInput.setClient","args":[7,{"inputAction":"TextInputAction.send"}]}
    );
    try runner.text_client.applyEditingState("kept", 2, 2);
    runner.text_client.has_transform = true;
    runner.text_client.transform = [_]f64{7} ** 16;
    for ([_][]const u8{
        \\{"method":"TextInput.setClient","args":[9,null]}
        ,
        \\{"method":"TextInput.setClient","args":[9,{"inputAction":false}]}
        ,
        \\{"method":"TextInput.setClient","args":[9,{"inputType":{"name":3}}]}
        ,
        \\{"method":"TextInput.setEditingState","args":{"text":3,"selectionBase":0,"selectionExtent":0}}
        ,
        \\{"method":"TextInput.setEditingState","args":{"text":"lost","selectionBase":"bad","selectionExtent":0}}
        ,
        \\{"method":"TextInput.setEditableSizeAndTransform","args":{"transform":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,"bad"]}}
        ,
    }) |payload| {
        try runner.dispatch(payload);
        try std.testing.expect(runner.error_code != null);
        try std.testing.expectEqualStrings("BadArguments", runner.error_code.?);
        try std.testing.expect(runner.text_client.active);
        try std.testing.expectEqual(@as(i64, 7), runner.text_client.client_id);
        try std.testing.expectEqualStrings("TextInputAction.send", runner.text_client.input_action);
        try std.testing.expectEqualStrings("kept", runner.text_client.state.text.items);
        try std.testing.expectEqual(@as(i64, 2), runner.text_client.state.selection_base);
        try std.testing.expectEqual([_]f64{7} ** 16, runner.text_client.transform);
        try std.testing.expectEqual(@as(usize, 0), runner.cursor_updates);
    }
}

test "text input handler preserves UTF16 composition and clears omitted ranges" {
    var runner: TextInputTestRunner = .{ .gpa = std.testing.allocator, .text_client = .init(std.testing.allocator) };
    defer runner.text_client.deinit();
    try runner.dispatch(
        \\{"method":"TextInput.setClient","args":[7,{"inputType":{"name":"TextInputType.text"}}]}
    );
    try std.testing.expect(!runner.text_client.multiline);
    try runner.dispatch(
        \\{"method":"TextInput.setEditingState","args":{"text":"A😀中Z","selectionBase":3,"selectionExtent":4,"composingBase":1,"composingExtent":4}}
    );
    try std.testing.expect(runner.error_code == null);
    try std.testing.expectEqual(@as(i64, 1), runner.text_client.state.composing_start);
    try std.testing.expectEqual(@as(i64, 8), runner.text_client.state.composing_end);
    const update = try runner.text_client.buildUpdateMessageAlloc();
    defer std.testing.allocator.free(update);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, update, .{});
    defer parsed.deinit();
    const fields = parsed.value.object.get("args").?.array.items[1].object;
    try std.testing.expectEqual(@as(i64, 1), fields.get("composingBase").?.integer);
    try std.testing.expectEqual(@as(i64, 4), fields.get("composingExtent").?.integer);
    try std.testing.expectEqual(@as(i64, 3), fields.get("selectionBase").?.integer);
    try runner.dispatch(
        \\{"method":"TextInput.setEditingState","args":{"text":"done","selectionBase":4,"selectionExtent":4}}
    );
    try std.testing.expectEqual(@as(i64, -1), runner.text_client.state.composing_start);
    try std.testing.expectEqual(@as(i64, -1), runner.text_client.state.composing_end);
}

test "text input handler reports action allocation failure without an active partial client" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var runner: TextInputTestRunner = .{ .gpa = std.testing.allocator, .text_client = .init(failing.allocator()) };
    defer runner.text_client.deinit();
    try runner.dispatch(
        \\{"method":"TextInput.setClient","args":[1,{"inputAction":"TextInputAction.send"}]}
    );
    try std.testing.expect(runner.error_code != null);
    try std.testing.expectEqualStrings("OutOfMemory", runner.error_code.?);
    try std.testing.expect(!runner.text_client.active);
    try std.testing.expectEqual(@as(i64, -1), runner.text_client.client_id);
    try std.testing.expectEqualStrings("TextInputAction.done", runner.text_client.input_action);
}
