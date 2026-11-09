//! JZON behaviour zon_deserialize_test
//!
//! ### file: src/jzon/tests/behaviour/zon_deserialize_test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! ZON text into typed values, called the way a caller calls it: through
//! `jzon.zon.deserialize` and `jzon.lastFailure` only.
//!
//! ### note:
//!
//! n/a
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const jzon = @import("jzon");

const DeserializeError = jzon.zon.DeserializeError;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Point = struct {
    x: i32,
    y: i32,
};

/// The shape a `build.zig.zon` holds.
const Package = struct {
    const Name = enum { zix };

    const Semver = struct {
        major: u32,
        minor: u32,
        patch: u32,
        release_candidate: ?u32,
    };

    name: Name,
    version: []const u8,
    semver: Semver,
    fingerprint: u64,
    minimum_zig_version: []const u8,
    paths: []const []const u8,
};

const PACKAGE_TEXT =
    \\// The package manifest.
    \\.{
    \\    .name = .zix,
    \\    .version = "0.6.0-rc1",
    \\    .semver = .{
    \\        .major = 0,
    \\        .minor = 6,
    \\        .patch = 0,
    \\        .release_candidate = 1,
    \\    },
    \\    .fingerprint = 0x4cc61d74dc93a20b,
    \\    .minimum_zig_version = "0.17.0",
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    },
    \\}
    \\
;

/// Parse with a fresh arena and expect a failure.
fn expectFails(
    comptime Target: type,
    src: []const u8,
    comptime options: jzon.zon.ZonOptions,
    expected: DeserializeError,
) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const result = jzon.zon.deserialize(Target, arena.allocator(), src, options);

    try std.testing.expectError(expected, result);
}

/// Whether a slice points inside a document.
fn pointsInto(text: []const u8, src: []const u8) bool {
    const start = @intFromPtr(src.ptr);
    const at = @intFromPtr(text.ptr);

    return at >= start and at + text.len <= start + src.len;
}

test "jzon behaviour: zon deserialize, reads a build.zig.zon manifest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const package = try jzon.zon.deserialize(Package, arena.allocator(), PACKAGE_TEXT, .{});

    try std.testing.expectEqual(Package.Name.zix, package.name);
    try std.testing.expectEqualStrings("0.6.0-rc1", package.version);
    try std.testing.expectEqual(@as(?u32, 1), package.semver.release_candidate);
    try std.testing.expectEqualStrings("0.17.0", package.minimum_zig_version);
    try std.testing.expectEqual(@as(usize, 3), package.paths.len);
    try std.testing.expectEqualStrings("src", package.paths[2]);
}

test "jzon behaviour: zon deserialize, reads a hex fingerprint" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const package = try jzon.zon.deserialize(Package, arena.allocator(), PACKAGE_TEXT, .{});

    try std.testing.expectEqual(@as(u64, 0x4cc61d74dc93a20b), package.fingerprint);
}

test "jzon behaviour: zon deserialize, reads a multiline string" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = ".{\n    .text =\n        \\\\first\n        \\\\second\n    ,\n}";
    const Note = struct { text: []const u8 };
    const note = try jzon.zon.deserialize(Note, arena.allocator(), src, .{});

    try std.testing.expectEqualStrings("first\nsecond", note.text);
}

test "jzon behaviour: zon deserialize, COPY keeps strings out of the document" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const package = try jzon.zon.deserialize(Package, arena.allocator(), PACKAGE_TEXT, .{});

    try std.testing.expect(!pointsInto(package.version, PACKAGE_TEXT));
}

test "jzon behaviour: zon deserialize, BORROW points strings into the document" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const package = try jzon.zon.deserialize(Package, arena.allocator(), PACKAGE_TEXT, .{
        .strings = .BORROW,
    });

    try std.testing.expect(pointsInto(package.version, PACKAGE_TEXT));
}

test "jzon behaviour: zon deserialize, BORROW copies a string with an escape" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = ".{ .text = \"a\\tb\" }";
    const Note = struct { text: []const u8 };
    const note = try jzon.zon.deserialize(Note, arena.allocator(), src, .{
        .strings = .BORROW,
    });

    try std.testing.expectEqualStrings("a\tb", note.text);
    try std.testing.expect(!pointsInto(note.text, src));
}

test "jzon behaviour: zon deserialize, REJECT refuses an unknown key" {
    try expectFails(
        Point,
        ".{ .x = 1, .y = 2, .z = 3 }",
        .{},
        DeserializeError.Jzon_ZonDeserialize_UnknownField,
    );
}

test "jzon behaviour: zon deserialize, SKIP steps over an unknown key" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = ".{ .x = 1, .extra = .{ .a = \"b\", .c = .{ 1, 2 } }, .y = 2 }";
    const point = try jzon.zon.deserialize(Point, arena.allocator(), src, .{
        .unknown = .SKIP,
    });

    try std.testing.expectEqual(@as(i32, 1), point.x);
    try std.testing.expectEqual(@as(i32, 2), point.y);
}

test "jzon behaviour: zon deserialize, missing field without a default fails" {
    try expectFails(
        Point,
        ".{ .x = 1 }",
        .{},
        DeserializeError.Jzon_ZonDeserialize_MissingField,
    );
}

test "jzon behaviour: zon deserialize, missing field with a default takes it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const Flags = struct {
        on: bool,
        note: ?[]const u8 = null,
    };
    const flags = try jzon.zon.deserialize(Flags, arena.allocator(), ".{ .on = true }", .{});

    try std.testing.expect(flags.on);
    try std.testing.expectEqual(@as(?[]const u8, null), flags.note);
}

test "jzon behaviour: zon deserialize, unknown enum tag fails" {
    try expectFails(
        Package.Name,
        ".jzon",
        .{},
        DeserializeError.Jzon_ZonDeserialize_UnknownEnumValue,
    );
}

test "jzon behaviour: zon deserialize, truncated document fails" {
    try expectFails(
        Point,
        ".{ .x = 1, .y = ",
        .{},
        DeserializeError.Jzon_ZonDeserialize_Truncated,
    );
}

test "jzon behaviour: zon deserialize, integer past its type fails" {
    try expectFails(u8, "256", .{}, DeserializeError.Jzon_ZonDeserialize_BadNumber);
}

test "jzon behaviour: zon deserialize, bad escape fails" {
    try expectFails(
        []const u8,
        "\"\\q\"",
        .{},
        DeserializeError.Jzon_ZonDeserialize_BadEscape,
    );
}

test "jzon behaviour: zon deserialize, nesting within max_depth is read" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const grid = try jzon.zon.deserialize([1][1]u8, arena.allocator(), ".{ .{ 7 } }", .{
        .max_depth = 2,
    });

    try std.testing.expectEqual(@as(u8, 7), grid[0][0]);
}

test "jzon behaviour: zon deserialize, nesting past max_depth is refused" {
    try expectFails(
        [1][1]u8,
        ".{ .{ 7 } }",
        .{ .max_depth = 1 },
        DeserializeError.Jzon_ZonDeserialize_Unexpected,
    );
}

test "jzon behaviour: zon deserialize, lastFailure names the unknown key" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = ".{ .x = 1, .zed = 3 }";
    const result = jzon.zon.deserialize(Point, arena.allocator(), src, .{});

    try std.testing.expectError(DeserializeError.Jzon_ZonDeserialize_UnknownField, result);

    const failure = jzon.lastFailure();

    try std.testing.expect(failure.filled);
    try std.testing.expectEqualStrings("zed", failure.field);
    try std.testing.expectEqual(std.mem.indexOf(u8, src, "zed").?, failure.offset);
}

test "jzon behaviour: zon deserialize, lastFailure names the missing field" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const result = jzon.zon.deserialize(Point, arena.allocator(), ".{ .x = 1 }", .{});

    try std.testing.expectError(DeserializeError.Jzon_ZonDeserialize_MissingField, result);
    try std.testing.expectEqualStrings("y", jzon.lastFailure().field);
}

test "jzon behaviour: zon deserialize, lastFailure points at a bad number" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const src = ".{ .x = 1, .y = 9999999999 }";
    const result = jzon.zon.deserialize(Point, arena.allocator(), src, .{});

    try std.testing.expectError(DeserializeError.Jzon_ZonDeserialize_BadNumber, result);

    const failure = jzon.lastFailure();

    try std.testing.expectEqual(std.mem.indexOf(u8, src, "9999").?, failure.offset);
}

test "jzon behaviour: zon deserialize, a later success leaves the failure alone" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const result = jzon.zon.deserialize(Point, arena.allocator(), ".{ .x = 1 }", .{});

    try std.testing.expectError(DeserializeError.Jzon_ZonDeserialize_MissingField, result);

    _ = try jzon.zon.deserialize(Point, arena.allocator(), ".{ .x = 1, .y = 2 }", .{});

    try std.testing.expectEqualStrings("y", jzon.lastFailure().field);
}

