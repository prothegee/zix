//! JZON behaviour zon_round_trip_test
//!
//! ### file: src/jzon/tests/behaviour/zon_round_trip_test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What `jzon.zon.serialize` writes, `jzon.zon.deserialize` reads back to the same
//! value, for every shape ZON covers, in both layouts.
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

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Every layout a round trip runs in.
const LAYOUTS = [_]jzon.zon.ZonOptions.Layout{
    .MULTILINE,
    .COMPACT,
};

const Status = enum { PENDING, SHIPPED, CANCELLED };

const Line = struct {
    sku: []const u8,
    qty: u32,
    price_cents: i64,
};

const Order = struct {
    id: u64,
    customer: []const u8,
    status: Status,
    note: ?[]const u8 = null,
    tags: []const []const u8,
    lines: []const Line,
};

const ORDER: Order = .{
    .id = 4815162342,
    .customer = "Rekha Nair",
    .status = .SHIPPED,
    .note = "leave at the door",
    .tags = &.{
        "priority",
        "gift",
    },
    .lines = &.{
        .{
            .sku = "AB-1",
            .qty = 2,
            .price_cents = 1299,
        },
        .{
            .sku = "CD-2",
            .qty = 1,
            .price_cents = -4500,
        },
    },
};

/// Write a value, read it back, and compare, in every layout.
fn expectRoundTrip(
    comptime Target: type,
    value: Target,
    comptime hex_fields: []const []const u8,
) !void {
    inline for (LAYOUTS) |layout| {
        var buf: [2048]u8 = undefined;
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();

        const len = try jzon.zon.serialize(&buf, value, .{
            .layout = layout,
            .hex_fields = hex_fields,
        });
        const back = try jzon.zon.deserialize(Target, arena.allocator(), buf[0..len], .{});

        try std.testing.expectEqualDeep(value, back);
    }
}

test "jzon behaviour: zon round trip, order record" {
    try expectRoundTrip(Order, ORDER, &.{});
}

test "jzon behaviour: zon round trip, order with null note and no lines" {
    var order = ORDER;
    order.note = null;
    order.lines = &.{};
    order.tags = &.{};

    try expectRoundTrip(Order, order, &.{});
}

test "jzon behaviour: zon round trip, hex fields" {
    const Package = struct {
        major: u32,
        fingerprint: u64,
        offset: ?i32,
    };
    const value: Package = .{
        .major = 6,
        .fingerprint = 0x4cc61d74dc93a20b,
        .offset = -0x1f,
    };

    try expectRoundTrip(Package, value, &.{
        "fingerprint",
        "offset",
    });
}

test "jzon behaviour: zon round trip, integer limits" {
    const Limits = struct {
        low: i64,
        high: u64,
        byte: u8,
    };
    const value: Limits = .{
        .low = std.math.minInt(i64),
        .high = std.math.maxInt(u64),
        .byte = 255,
    };

    try expectRoundTrip(Limits, value, &.{});
    try expectRoundTrip(Limits, value, &.{
        "low",
        "high",
        "byte",
    });
}

test "jzon behaviour: zon round trip, floats" {
    const values = [_]f64{
        0.1,
        -2.5e-300,
        1e300,
        0,
        std.math.inf(f64),
        -std.math.inf(f64),
    };

    try expectRoundTrip([6]f64, values, &.{});
}

test "jzon behaviour: zon round trip, strings with escapes and UTF-8" {
    const texts: []const []const u8 = &.{
        "line\nbreak",
        "quote \" and \\ slash",
        "caf\xc3\xa9",
        "\xff\x00",
        "",
    };

    try expectRoundTrip([]const []const u8, texts, &.{});
}

test "jzon behaviour: zon round trip, nested arrays and slices" {
    const Shape = struct {
        grid: [2][2]u8,
        rows: []const []const u16,
    };
    const value: Shape = .{
        .grid = .{
            .{ 1, 2 },
            .{ 3, 4 },
        },
        .rows = &.{
            &.{ 1, 2, 3 },
            &.{},
        },
    };

    try expectRoundTrip(Shape, value, &.{});
}

test "jzon behaviour: zon round trip, quoted names" {
    const Keyed = struct {
        @"error": Status,
        @"two words": bool,
    };
    const value: Keyed = .{
        .@"error" = .CANCELLED,
        .@"two words" = true,
    };

    try expectRoundTrip(Keyed, value, &.{});
}

