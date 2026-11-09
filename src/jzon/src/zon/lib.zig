//! JZON zon
//!
//! ### file: src/jzon/src/zon/lib.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The `jzon.zon` namespace: ZON serialize and deserialize, their options and errors.
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

// --------------------------------------------------------- //
// Public:

/// Turn ZON text into a typed value.
pub const deserialize = @import("deserialize.zig").deserialize;

/// Turn a typed value into ZON text.
pub const serialize = @import("serialize.zig").serialize;

/// The options a ZON deserialize or serialize runs with.
pub const ZonOptions = @import("ZonOptions.zig");

/// Every way a ZON deserialize can fail.
pub const DeserializeError = @import("deserialize.zig").Error;

/// Every way a ZON serialize can fail.
pub const SerializeError = @import("serialize.zig").Error;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Point = struct {
    x: i32,
    y: i32,
};

test "jzon zon: lib, deserialize reads through the namespace" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const point = try deserialize(Point, arena.allocator(), ".{ .x = 1, .y = 2 }", .{});

    try std.testing.expectEqual(@as(i32, 2), point.y);
}

test "jzon zon: lib, serialize writes through the namespace" {
    var buf: [64]u8 = undefined;

    const point: Point = .{
        .x = 1,
        .y = 2,
    };
    const len = try serialize(&buf, point, .{ .layout = .COMPACT });

    try std.testing.expectEqualStrings(".{ .x = 1, .y = 2 }", buf[0..len]);
}

test "jzon zon: lib, error sets are the module sets" {
    try std.testing.expectEqual(
        DeserializeError.Jzon_ZonDeserialize_Truncated,
        @import("deserialize.zig").Error.Jzon_ZonDeserialize_Truncated,
    );
    try std.testing.expectEqual(
        SerializeError.Jzon_ZonSerialize_NoSpaceLeft,
        @import("serialize.zig").Error.Jzon_ZonSerialize_NoSpaceLeft,
    );
}

