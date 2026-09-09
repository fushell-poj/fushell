//! Line-oriented creation wizard. No terminal mode changes or filesystem writes.
//! The caller owns an arena: answers and resolved strings live in that arena.
const std = @import("std");
const cli = @import("cli");
const config = @import("application_config.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Settings = struct {
    output: []const u8,
    project_name: []const u8,
    organization: []const u8,
    description: []const u8,
    application_id: []const u8,
    single_instance: bool,
    pub_get: bool,
};

pub const ProjectNameError = error{
    EmptyProjectName,
    ProjectNameEqFushell,
    ProjectNameMustStartWithLowercase,
    ProjectNameContainsInvalidCharacter,
};

pub fn validateProjectName(value: []const u8) ProjectNameError!void {
    if (value.len == 0)
        return error.EmptyProjectName;

    if (std.mem.eql(u8, value, "fushell"))
        return error.ProjectNameEqFushell;

    if (!std.ascii.isLower(value[0]))
        return error.ProjectNameMustStartWithLowercase;

    for (value) |c| {
        if (!std.ascii.isLower(c) and
            !std.ascii.isDigit(c) and
            c != '_')
        {
            return error.ProjectNameContainsInvalidCharacter;
        }
    }
}

/// Resolve defaults using the final output name, never a random staging name.
pub fn resolve(arena: Allocator, cwd: []const u8, options: cli.create.Options) !Settings {
    const output = options.output orelse return error.MissingProjectDirectory;
    if (output.len == 0 or std.mem.indexOfScalar(u8, output, 0) != null) return error.InvalidProjectDirectory;
    const absolute = try std.fs.path.resolve(arena, &.{ cwd, output });
    const name = options.project_name orelse std.fs.path.basename(absolute);
    try validateProjectName(name);
    const org = options.organization orelse "com.example";
    if (!config.isValidApplicationId(try std.fmt.allocPrint(arena, "{s}.App", .{org}))) return error.InvalidOrganization;
    const id = options.application_id orelse try std.fmt.allocPrint(arena, "{s}.{s}", .{ org, name });
    if (!config.isValidApplicationId(id)) return error.InvalidApplicationId;
    const description = options.description orelse "A Fushell application for Linux/Wayland.";
    if (!std.unicode.utf8ValidateSlice(description) or std.mem.indexOfScalar(u8, description, 0) != null) return error.InvalidDescription;
    return .{ .output = absolute, .project_name = name, .organization = org, .description = description, .application_id = id, .single_instance = options.single_instance orelse false, .pub_get = options.pub_get };
}

fn answer(arena: Allocator, reader: *Io.Reader, writer: *Io.Writer, label: []const u8, default: []const u8) ![]const u8 {
    if (default.len == 0) try writer.print("{s}: ", .{label}) else try writer.print("{s} [{s}]: ", .{ label, default });
    try writer.flush();
    const line = try reader.takeDelimiter('\n') orelse return error.UserInterrupt;
    const text = std.mem.trim(u8, line, " \t\r");
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidWizardInput;
    return arena.dupe(u8, if (text.len == 0) default else text);
}

fn yesNo(arena: Allocator, reader: *Io.Reader, writer: *Io.Writer, label: []const u8) !bool {
    while (true) {
        const value = try answer(arena, reader, writer, label, "y/N");
        if (std.ascii.eqlIgnoreCase(value, "y") or std.ascii.eqlIgnoreCase(value, "yes")) return true;
        if (std.mem.eql(u8, value, "y/N") or std.ascii.eqlIgnoreCase(value, "n") or std.ascii.eqlIgnoreCase(value, "no")) return false;
        try writer.writeAll("Please enter y or n.\n");
    }
}

fn defaultProjectName(arena: Allocator, path: []const u8) ![]const u8 {
    const basename = std.fs.path.basename(path);
    const name = try arena.dupe(u8, basename);

    for (name) |*c| {
        if (c.* == '-') c.* = '_';
    }

    return name;
}

/// CLI overrides are never prompted again. null means an explicit cancellation;
/// EOF/interrupt is error.UserInterrupt. All interaction finishes before writes.
pub fn collect(arena: Allocator, cwd: []const u8, options: cli.create.Options, reader: *Io.Reader, writer: *Io.Writer) !?Settings {
    var selected = options;
    try writer.writeAll("Create a Fushell project (existing files are never overwritten).\n");
    if (selected.output == null) {
        while (true) {
            selected.output = try answer(arena, reader, writer, "Output directory", "");
            if (selected.output.?.len != 0) break;
            try writer.writeAll("An output directory is required.\n");
        }
    }
    const path = try std.fs.path.resolve(arena, &.{ cwd, selected.output.? });
    if (selected.project_name == null) {
        const default_name = try defaultProjectName(arena, path);

        while (true) {
            selected.project_name = try answer(
                arena,
                reader,
                writer,
                "Project name",
                default_name,
            );

            validateProjectName(selected.project_name.?) catch |err| switch (err) {
                error.EmptyProjectName => {
                    try writer.writeAll("Project name cannot be empty.\n");
                    continue;
                },
                error.ProjectNameEqFushell => {
                    try writer.writeAll("'fushell' is reserved for the Fushell SDK.\n");
                    continue;
                },
                error.ProjectNameMustStartWithLowercase => {
                    try writer.writeAll("Project name must start with a lowercase letter.\n");
                    continue;
                },
                error.ProjectNameContainsInvalidCharacter => {
                    try writer.writeAll(
                        "Project name may contain only lowercase letters, digits, and underscores.\n",
                    );
                    continue;
                },
            };

            break;
        }
    }
    if (selected.organization == null) {
        while (true) {
            selected.organization = try answer(arena, reader, writer, "Organization", "com.example");
            if (config.isValidApplicationId(try std.fmt.allocPrint(arena, "{s}.App", .{selected.organization.?}))) break;
            try writer.writeAll("Use dot-separated identifier components, for example dev.example.\n");
        }
    }
    if (selected.description == null) selected.description = try answer(arena, reader, writer, "Description", "A Fushell application for Linux/Wayland.");
    if (selected.single_instance == null) selected.single_instance = try yesNo(arena, reader, writer, "Single instance");
    if (selected.application_id == null) {
        const default_id = try std.fmt.allocPrint(arena, "{s}.{s}", .{ selected.organization.?, selected.project_name.? });
        while (true) {
            selected.application_id = try answer(arena, reader, writer, "Application ID", default_id);
            if (config.isValidApplicationId(selected.application_id.?)) break;
            try writer.writeAll("Use a valid dot-separated application ID, at most 255 bytes.\n");
        }
    }
    const result = try resolve(arena, cwd, selected);
    try writer.print("\nDirectory: {s}\nPackage: {s}\nApplication ID: {s}\nInstance: {s}\nRun pub get: {s}\n", .{
        result.output,                                        result.project_name,                 result.application_id,
        if (result.single_instance) "single" else "multiple", if (result.pub_get) "yes" else "no",
    });
    if (!try yesNo(arena, reader, writer, "Create project")) {
        try writer.writeAll("Cancelled. No project files were written.\n");
        try writer.flush();
        return null;
    }
    return result;
}

test "wizard defaults, CLI precedence, invalid answer retry and cancellation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader: Io.Reader = .fixed("app\n\n\n\nmaybe\nn\n\ny\n");
    var bytes: [8192]u8 = undefined;
    var writer: Io.Writer = .fixed(&bytes);
    const result = (try collect(arena.allocator(), "/tmp", .{}, &reader, &writer)).?;
    try std.testing.expectEqualStrings("/tmp/app", result.output);
    try std.testing.expectEqualStrings("com.example.app", result.application_id);
    try std.testing.expect(!result.single_instance and result.pub_get);
    reader = .fixed("y\n");
    writer = .fixed(&bytes);
    const fixed = (try collect(arena.allocator(), "/tmp", .{ .output = "a folder", .project_name = "hello", .organization = "dev.test", .description = "test", .application_id = "dev.test.Hello", .single_instance = true, .pub_get = false }, &reader, &writer)).?;
    try std.testing.expect(fixed.single_instance and !fixed.pub_get);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Project name [") == null);
    reader = .fixed("app\n\n\n\nn\n\nn\n");
    writer = .fixed(&bytes);
    try std.testing.expect(try collect(arena.allocator(), "/tmp", .{}, &reader, &writer) == null);
    reader = .fixed("");
    writer = .fixed(&bytes);
    try std.testing.expectError(error.UserInterrupt, collect(arena.allocator(), "/tmp", .{}, &reader, &writer));
}

test "defaults use final directory and reject self-dependency and invalid IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dot = try resolve(a, "/tmp/my_app", .{ .output = "." });
    try std.testing.expectEqualStrings("my_app", dot.project_name);
    try std.testing.expectError(error.InvalidProjectName, resolve(a, "/tmp", .{ .output = "fushell" }));
    try std.testing.expectError(error.InvalidApplicationId, resolve(a, "/tmp", .{ .output = "app", .application_id = "a-b.app" }));
    try std.testing.expectError(error.InvalidOrganization, resolve(a, "/tmp", .{ .output = "app", .organization = "bad org" }));
}
