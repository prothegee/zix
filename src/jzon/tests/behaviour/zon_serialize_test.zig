//! JZON behaviour zon_serialize_test
//!
//! ### file: src/jzon/tests/behaviour/zon_serialize_test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Typed values into ZON text, called the way a caller calls it: through
//! `jzon.zon.serialize` only.
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

const SerializeError = jzon.zon.SerializeError;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Status = enum { PENDING, SHIPPED };

/// The shape a `build.zig.zon` holds.
const Package = struct {
    const Name = enum { zix };

    const Semver = struct {
        major: u32,
        minor: u32,
        release_candidate: ?u32,
    };

    name: Name,
    version: []const u8,
    semver: Semver,
    fingerprint: u64,
    paths: []const []const u8,
};

const PACKAGE: Package = .{
    .name = .zix,
    .version = "0.6.0-rc1",
    .semver = .{
        .major = 0,
        .minor = 6,
        .release_candidate = 1,
    },
    .fingerprint = 0x4cc61d74dc93a20b,
    .paths = &.{
        "build.zig",
        "src",
    },
};

/// Render into a fixed buffer and compare with the expected text.
fn expectRenders(
    expected: []const u8,
    value: anytype,
    comptime options: jzon.zon.ZonOptions,
) !void {
    var buf: [1024]u8 = undefined;

    const len = try jzon.zon.serialize(&buf, value, options);

    try std.testing.expectEqualStrings(expected, buf[0..len]);
}

test "jzon behaviour: zon serialize, MULTILINE writes the build.zig.zon layout" {
    const expected =
        \\.{
        \\    .name = .zix,
        \\    .version = "0.6.0-rc1",
        \\    .semver = .{
        \\        .major = 0,
        \\        .minor = 6,
        \\        .release_candidate = 1,
        \\    },
        \\    .fingerprint = 5532141580025307659,
        \\    .paths = .{
        \\        "build.zig",
        \\        "src",
        \\    },
        \\}
    ;

    try expectRenders(expected, PACKAGE, .{});
}

test "jzon behaviour: zon serialize, COMPACT writes one line" {
    const expected = ".{ .name = .zix, .version = \"0.6.0-rc1\", " ++
        ".semver = .{ .major = 0, .minor = 6, .release_candidate = 1 }, " ++
        ".fingerprint = 5532141580025307659, .paths = .{ \"build.zig\", \"src\" } }";

    try expectRenders(expected, PACKAGE, .{ .layout = .COMPACT });
}

test "jzon behaviour: zon serialize, hex_fields writes the fingerprint as hex" {
    var buf: [1024]u8 = undefined;

    const len = try jzon.zon.serialize(&buf, PACKAGE, .{
        .hex_fields = &.{"fingerprint"},
    });
    const text = buf[0..len];

    const hex = ".fingerprint = 0x4cc61d74dc93a20b,";

    try std.testing.expect(std.mem.indexOf(u8, text, hex) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, ".minor = 6,") != null);
}

test "jzon behaviour: zon serialize, hex_fields takes several names" {
    const Masks = struct {
        read: u8,
        write: u8,
        count: u8,
    };
    const value: Masks = .{
        .read = 0xf0,
        .write = 0x0f,
        .count = 2,
    };

    try expectRenders(".{ .read = 0xf0, .write = 0xf, .count = 2 }", value, .{
        .layout = .COMPACT,
        .hex_fields = &.{
            "read",
            "write",
        },
    });
}

test "jzon behaviour: zon serialize, writes enums, optionals and floats" {
    const Reading = struct {
        status: Status,
        note: ?[]const u8,
        ratio: f64,
        limit: f64,
    };
    const value: Reading = .{
        .status = .SHIPPED,
        .note = null,
        .ratio = 0.5,
        .limit = std.math.inf(f64),
    };
    const expected = ".{ .status = .SHIPPED, .note = null, .ratio = 0.5, .limit = inf }";

    try expectRenders(expected, value, .{ .layout = .COMPACT });
}

test "jzon behaviour: zon serialize, quotes a name that is a keyword" {
    const Keyed = struct { @"error": u8 };
    const value: Keyed = .{ .@"error" = 1 };

    try expectRenders(".{ .@\"error\" = 1 }", value, .{ .layout = .COMPACT });
}

test "jzon behaviour: zon serialize, escapes a string" {
    const Note = struct { text: []const u8 };
    const value: Note = .{ .text = "say \"hi\"\n" };

    try expectRenders(".{ .text = \"say \\\"hi\\\"\\n\" }", value, .{ .layout = .COMPACT });
}

test "jzon behaviour: zon serialize, empty containers are .{}" {
    const Empty = struct {
        paths: []const []const u8,
        nested: struct {},
    };
    const value: Empty = .{
        .paths = &.{},
        .nested = .{},
    };

    try expectRenders(".{ .paths = .{}, .nested = .{} }", value, .{ .layout = .COMPACT });
}

test "jzon behaviour: zon serialize, returns how many bytes it wrote" {
    var buf: [1024]u8 = @splat('#');

    const len = try jzon.zon.serialize(&buf, @as(u8, 42), .{});

    try std.testing.expectEqual(@as(usize, 2), len);
    try std.testing.expectEqual(@as(u8, '#'), buf[len]);
}

test "jzon behaviour: zon serialize, buffer too small is no space left" {
    var buf: [16]u8 = undefined;

    try std.testing.expectError(
        SerializeError.Jzon_ZonSerialize_NoSpaceLeft,
        jzon.zon.serialize(&buf, PACKAGE, .{}),
    );
}

test "jzon behaviour: zon serialize, hex field past the buffer is no space left" {
    const Package2 = struct { fingerprint: u64 };
    const value: Package2 = .{ .fingerprint = 0x4cc61d74dc93a20b };

    var buf: [20]u8 = undefined;

    try std.testing.expectError(
        SerializeError.Jzon_ZonSerialize_NoSpaceLeft,
        jzon.zon.serialize(&buf, value, .{
            .layout = .COMPACT,
            .hex_fields = &.{"fingerprint"},
        }),
    );
}

