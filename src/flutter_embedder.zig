const std = @import("std");
const c = @import("c");

pub const Api = struct {
    handle: ?*anyopaque,
    run: EngineRunFn,
    shutdown: EngineShutdownFn,
    send_window_metrics: SendWindowMetricsFn,
    send_pointer_event: SendPointerEventFn,
    send_platform_message: SendPlatformMessageFn,
    send_platform_message_response: SendPlatformMessageResponseFn,
    run_task: RunTaskFn,
    schedule_frame: ScheduleFrameFn,
    on_vsync: OnVsyncFn,
    get_current_time: GetCurrentTimeFn,
    runs_aot_compiled_dart_code: RunsAotCompiledDartCodeFn,
    create_aot_data: CreateAotDataFn,
    collect_aot_data: CollectAotDataFn,

    const EngineRunFn = *const fn (usize, *const c.FlutterRendererConfig, *const c.FlutterProjectArgs, ?*anyopaque, *c.FlutterEngine) callconv(.c) c.FlutterEngineResult;
    const EngineShutdownFn = *const fn (c.FlutterEngine) callconv(.c) c.FlutterEngineResult;
    const SendWindowMetricsFn = *const fn (c.FlutterEngine, *const c.FlutterWindowMetricsEvent) callconv(.c) c.FlutterEngineResult;
    const SendPointerEventFn = *const fn (c.FlutterEngine, *const c.FlutterPointerEvent, usize) callconv(.c) c.FlutterEngineResult;
    const SendPlatformMessageFn = *const fn (c.FlutterEngine, *const c.FlutterPlatformMessage) callconv(.c) c.FlutterEngineResult;
    const SendPlatformMessageResponseFn = *const fn (c.FlutterEngine, ?*const c.FlutterPlatformMessageResponseHandle, [*c]const u8, usize) callconv(.c) c.FlutterEngineResult;
    const RunTaskFn = *const fn (c.FlutterEngine, *const c.FlutterTask) callconv(.c) c.FlutterEngineResult;
    const ScheduleFrameFn = *const fn (c.FlutterEngine) callconv(.c) c.FlutterEngineResult;
    const OnVsyncFn = *const fn (c.FlutterEngine, isize, u64, u64) callconv(.c) c.FlutterEngineResult;
    const GetCurrentTimeFn = *const fn () callconv(.c) u64;
    const RunsAotCompiledDartCodeFn = *const fn () callconv(.c) bool;
    const CreateAotDataFn = *const fn (*const c.FlutterEngineAOTDataSource, *c.FlutterEngineAOTData) callconv(.c) c.FlutterEngineResult;
    const CollectAotDataFn = *const fn (c.FlutterEngineAOTData) callconv(.c) c.FlutterEngineResult;

    pub fn load(allocator: std.mem.Allocator, library_path: []const u8) !Api {
        const path_z = try allocator.dupeZ(u8, library_path);
        defer allocator.free(path_z);

        _ = std.c.dlerror();
        const handle = std.c.dlopen(path_z.ptr, .{ .LAZY = true }) orelse {
            const raw_error = std.c.dlerror() orelse return error.FlutterEngineLoadFailed;
            std.debug.print("dlopen({s}) failed: {s}\n", .{ library_path, std.mem.span(raw_error) });
            return error.FlutterEngineLoadFailed;
        };
        errdefer _ = std.c.dlclose(handle);

        return .{
            .handle = handle,
            .run = try loadSymbol(EngineRunFn, handle, "FlutterEngineRun"),
            .shutdown = try loadSymbol(EngineShutdownFn, handle, "FlutterEngineShutdown"),
            .send_window_metrics = try loadSymbol(SendWindowMetricsFn, handle, "FlutterEngineSendWindowMetricsEvent"),
            .send_pointer_event = try loadSymbol(SendPointerEventFn, handle, "FlutterEngineSendPointerEvent"),
            .send_platform_message = try loadSymbol(SendPlatformMessageFn, handle, "FlutterEngineSendPlatformMessage"),
            .send_platform_message_response = try loadSymbol(SendPlatformMessageResponseFn, handle, "FlutterEngineSendPlatformMessageResponse"),
            .run_task = try loadSymbol(RunTaskFn, handle, "FlutterEngineRunTask"),
            .schedule_frame = try loadSymbol(ScheduleFrameFn, handle, "FlutterEngineScheduleFrame"),
            .on_vsync = try loadSymbol(OnVsyncFn, handle, "FlutterEngineOnVsync"),
            .get_current_time = try loadSymbol(GetCurrentTimeFn, handle, "FlutterEngineGetCurrentTime"),
            .runs_aot_compiled_dart_code = try loadSymbol(RunsAotCompiledDartCodeFn, handle, "FlutterEngineRunsAOTCompiledDartCode"),
            .create_aot_data = try loadSymbol(CreateAotDataFn, handle, "FlutterEngineCreateAOTData"),
            .collect_aot_data = try loadSymbol(CollectAotDataFn, handle, "FlutterEngineCollectAOTData"),
        };
    }

    pub fn deinit(self: *Api) void {
        if (self.handle) |handle| {
            _ = std.c.dlclose(handle);
            self.handle = null;
        }
    }
};

fn loadSymbol(comptime T: type, handle: ?*anyopaque, comptime name: [:0]const u8) !T {
    _ = std.c.dlerror();
    const raw = std.c.dlsym(handle, name.ptr) orelse {
        const raw_error = std.c.dlerror();
        if (raw_error) |message| {
            std.debug.print("dlsym({s}) failed: {s}\n", .{ name, std.mem.span(message) });
        } else {
            std.debug.print("dlsym({s}) failed\n", .{name});
        }
        return error.FlutterEngineSymbolMissing;
    };
    return @ptrCast(raw);
}

pub fn resultName(result: c.FlutterEngineResult) []const u8 {
    return switch (result) {
        c.kSuccess => "kSuccess",
        c.kInvalidLibraryVersion => "kInvalidLibraryVersion",
        c.kInvalidArguments => "kInvalidArguments",
        c.kInternalInconsistency => "kInternalInconsistency",
        else => "<unknown FlutterEngineResult>",
    };
}

pub fn ensureSuccess(result: c.FlutterEngineResult, step: []const u8) !void {
    if (result == c.kSuccess) return;
    std.debug.print("{s} failed: {s} ({d})\n", .{ step, resultName(result), result });
    return error.FlutterEngineCallFailed;
}
