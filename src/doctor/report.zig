//! Owned, structured diagnostic results. Probes never write to the terminal.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Status = enum { ok, info, warning, @"error" };
pub const Check = struct {
    id: []const u8,
    title: []const u8,
    status: Status,
    summary: []const u8,
    details: []const []const u8,
    remedy: ?[]const u8,
};

pub const Report = struct {
    allocator: Allocator,
    checks: std.ArrayList(Check) = .empty,

    pub fn init(allocator: Allocator) Report {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Report) void {
        for (self.checks.items) |check| freeCheck(self.allocator, check);
        self.checks.deinit(self.allocator);
        self.* = undefined;
    }

    /// Own every value, including temporary probe output. Make untrusted path and
    /// process text safe for terminals and valid UTF-8 for the JSON renderer.
    pub fn add(self: *Report, id: []const u8, title: []const u8, severity: Status, summary: []const u8, details: []const []const u8, remedy: ?[]const u8) !void {
        const a = self.allocator;
        const owned_id = try safeText(a, id);
        errdefer a.free(owned_id);
        const owned_title = try safeText(a, title);
        errdefer a.free(owned_title);
        const owned_summary = try safeText(a, summary);
        errdefer a.free(owned_summary);
        const owned_remedy = if (remedy) |text| try safeText(a, text) else null;
        errdefer if (owned_remedy) |text| a.free(text);
        const owned_details = try a.alloc([]const u8, details.len);
        errdefer a.free(owned_details);
        var initialized: usize = 0;
        errdefer for (owned_details[0..initialized]) |text| a.free(text);
        for (details, owned_details) |text, *dest| {
            dest.* = try safeText(a, text);
            initialized += 1;
        }
        try self.checks.append(a, .{ .id = owned_id, .title = owned_title, .status = severity, .summary = owned_summary, .details = owned_details, .remedy = owned_remedy });
    }

    pub fn status(self: *const Report) Status {
        var result: Status = .ok;
        for (self.checks.items) |check| {
            if (@intFromEnum(check.status) > @intFromEnum(result)) result = check.status;
        }
        return result;
    }

    pub fn hasErrors(self: *const Report) bool {
        return self.status() == .@"error";
    }
};

fn freeCheck(a: Allocator, check: Check) void {
    a.free(check.id);
    a.free(check.title);
    a.free(check.summary);
    if (check.remedy) |text| a.free(text);
    for (check.details) |text| a.free(text);
    a.free(check.details);
}

/// Preserve Unicode, but escape terminal control sequences and invalid bytes.
fn safeText(a: Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < text.len) {
        const byte = text[i];
        const length = std.unicode.utf8ByteSequenceLength(byte) catch 0;
        if (byte >= 32 and byte != 127 and length != 0 and i + length <= text.len and std.unicode.utf8ValidateSlice(text[i..][0..length])) {
            try out.appendSlice(a, text[i..][0..length]);
            i += length;
        } else {
            try out.appendSlice(a, &.{ '\\', 'x', hex[byte >> 4], hex[byte & 0x0f] });
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

pub fn renderHuman(writer: *std.Io.Writer, report: *const Report, verbose: bool) !void {
    for (report.checks.items) |check| {
        const marker = switch (check.status) {
            .ok => "[✓]",
            .info => "[i]",
            .warning => "[!]",
            .@"error" => "[✗]",
        };
        try writer.print("{s} {s}\n    {s}\n", .{ marker, check.title, check.summary });
        // Failure details are actionable even without --verbose.
        if (verbose or check.status == .warning or check.status == .@"error") {
            for (check.details) |detail| try writer.print("    • {s}\n", .{detail});
        }
        if (check.remedy) |remedy| try writer.print("    Remedy: {s}\n", .{remedy});
        try writer.writeByte('\n');
    }
    try writer.writeAll(switch (report.status()) {
        .@"error" => "Some checks failed; see the affected build/runtime capabilities above.\n",
        .warning => "Checks completed with warnings.\n",
        .info => "Checks completed; some checks were skipped or informational.\n",
        .ok => "All performed checks passed.\n",
    });
}

/// One versioned JSON document on stdout, including the same details at every verbosity.
pub fn renderMachine(writer: *std.Io.Writer, report: *const Report) !void {
    try std.json.Stringify.value(.{ .schemaVersion = @as(u32, 1), .status = report.status(), .checks = report.checks.items }, .{}, writer);
    try writer.writeByte('\n');
}

fn allocationScenario(a: Allocator) !void {
    var report = Report.init(a);
    defer report.deinit();
    try report.add("test", "A title", .warning, "quote\" / unicode 文本 / bad \xff / ESC \x1b", &.{ "detail", "other" }, "repair");
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    renderMachine(&out.writer, &report) catch return error.OutOfMemory;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("warning", parsed.value.object.get("status").?.string);
    try std.testing.expect(!report.hasErrors());
}

test "report owns values, emits valid JSON, and cleans up on allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

test "failure details are visible without verbose and skipped is not all-pass" {
    var report = Report.init(std.testing.allocator);
    defer report.deinit();
    try report.add("test", "Test", .warning, "incomplete", &.{"specific reason"}, null);
    var buffer: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    try renderHuman(&out, &report, false);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "specific reason") != null);
    try report.add("failure", "Failure", .@"error", "error", &.{}, null);
    try std.testing.expect(report.hasErrors());
}
