//! Deadline for cancelable, resource-free results. Task-owned temporary resources
//! must be released inside function; allocating return values need explicit drain.
const std = @import("std");
const Io = std.Io;

pub fn call(io: Io, timeout_ms: u32, comptime function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) !@typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.payload {
    const Result = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const Event = union(enum) { result: Result, timeout: Io.Cancelable!void };
    var buffer: [2]Event = undefined;
    var select = Io.Select(Event).init(io, &buffer);
    defer select.cancelDiscard();
    try select.concurrent(.result, function, args);
    try select.concurrent(.timeout, Io.sleep, .{ io, Io.Duration.fromMilliseconds(timeout_ms), .awake });
    switch (try select.await()) {
        .result => |result| return result,
        .timeout => |result| {
            try result;
            return error.Timeout;
        },
    }
}
