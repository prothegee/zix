//! JZON behaviour round_trip_test
//!
//! ### file: src/jzon/tests/behaviour/round_trip_test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Every write path against every read path: one order rendered by each emitter
//! pairing reads back the same through each parser, at both widths, in both modes.
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

const EmitShape = jzon.EmitShape;
const ScanShape = jzon.ScanShape;
const Sink = jzon.Sink;
const generated_emitter = jzon.generated_emitter;
const generated_parser = jzon.generated_parser;
const scanner_parser = jzon.scanner_parser;
const std_emitter = jzon.std_emitter;
const std_parser = jzon.std_parser;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Every pairing the generated emitter runs with.
const EMIT_SHAPES = [_]EmitShape{
    .{
        .numbers = .FMT,
        .escapes = .SCALAR,
    },
    .{
        .numbers = .FMT,
        .escapes = .VECTOR,
    },
    .{
        .numbers = .TABLE,
        .escapes = .SCALAR,
    },
    .{
        .numbers = .TABLE,
        .escapes = .VECTOR,
    },
};

/// Every width the generated parser runs at.
const SCAN_SHAPES = [_]ScanShape{
    .{ .scan = .SCALAR },
    .{ .scan = .VECTOR },
};

const Status = enum { PENDING, SHIPPED, CANCELLED };

const Totals = struct {
    net_cents: i64,
    tax_cents: i64,
};

const Line = struct {
    sku: []const u8,
    qty: u32,
    price_cents: i64,
};

const Order = struct {
    id: u64,
    customer: []const u8,
    status: Status,
    note: ?[]const u8,
    tags: []const []const u8,
    lines: []const Line,
    totals: Totals,
};

const ORDER: Order = .{
    .id = 4815162342,
    .customer = "Rekha Nair",
    .status = .SHIPPED,
    .note = "leave at the door",
    .tags = &.{ "priority", "gift" },
    .lines = &.{
        .{
            .sku = "AB-1",
            .qty = 2,
            .price_cents = 1299,
        },
        .{
            .sku = "CD-2",
            .qty = 1,
            .price_cents = 4500,
        },
    },
    .totals = .{
        .net_cents = 7098,
        .tax_cents = 710,
    },
};

/// Assert two orders carry the same value in every field.
fn expectSameOrder(expected: Order, actual: Order) !void {
    try std.testing.expectEqual(expected.id, actual.id);
    try std.testing.expectEqualStrings(expected.customer, actual.customer);
    try std.testing.expectEqual(expected.status, actual.status);

    if (expected.note) |note| {
        try std.testing.expectEqualStrings(note, actual.note.?);
    } else {
        try std.testing.expect(actual.note == null);
    }

    try std.testing.expectEqual(expected.tags.len, actual.tags.len);
    for (expected.tags, actual.tags) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }

    try std.testing.expectEqual(expected.lines.len, actual.lines.len);
    for (expected.lines, actual.lines) |want, got| {
        try std.testing.expectEqualStrings(want.sku, got.sku);
        try std.testing.expectEqual(want.qty, got.qty);
        try std.testing.expectEqual(want.price_cents, got.price_cents);
    }

    try std.testing.expectEqual(expected.totals.net_cents, actual.totals.net_cents);
    try std.testing.expectEqual(expected.totals.tax_cents, actual.totals.tax_cents);
}

/// Read one rendering back through every path in both string modes.
fn expectEveryReadPath(expected: Order, rendered: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();

    inline for (.{ jzon.json.Strings.COPY, jzon.json.Strings.BORROW }) |mode| {
        const options: jzon.json.DeserializeOptions = .{ .strings = mode };

        try expectSameOrder(expected, try std_parser.parse(Order, allocator, rendered, options));
        try expectSameOrder(
            expected,
            try scanner_parser.parse(Order, allocator, rendered, options),
        );

        inline for (SCAN_SHAPES) |shape| {
            try expectSameOrder(
                expected,
                try generated_parser.parse(Order, allocator, rendered, options, shape),
            );
        }
    }
}

/// Render `order` through every write path and read each rendering back through
/// every read path in every string mode.
fn expectRoundTrips(order: Order) !void {
    var std_buf: [2048]u8 = undefined;
    var std_sink: Sink = .init(&std_buf);
    try std_emitter.emit(&std_sink, order);

    try expectEveryReadPath(order, std_sink.filled());

    inline for (EMIT_SHAPES) |shape| {
        var buf: [2048]u8 = undefined;
        var sink: Sink = .init(&buf);
        try generated_emitter.emit(&sink, order, shape);

        try expectEveryReadPath(order, sink.filled());
    }
}

test "jzon behaviour: round trip, every write path renders an order every read path reads" {
    try expectRoundTrips(ORDER);
}

test "jzon behaviour: round trip, every pair carries an unset optional" {
    var order = ORDER;
    order.note = null;

    try expectRoundTrips(order);
}

test "jzon behaviour: round trip, every pair carries an order with escapes" {
    var order = ORDER;
    order.customer = "quote \" backslash \\ newline \n tab \t";
    order.note = "a note long enough for the lane scan to take its vector path";

    try expectRoundTrips(order);
}

test "jzon behaviour: round trip, every pair carries empty slices" {
    var order = ORDER;
    order.tags = &.{};
    order.lines = &.{};

    try expectRoundTrips(order);
}

test "jzon behaviour: round trip, every pair carries the extremes of the number widths" {
    var order = ORDER;
    order.id = std.math.maxInt(u64);
    order.totals = .{
        .net_cents = std.math.minInt(i64),
        .tax_cents = std.math.maxInt(i64),
    };

    try expectRoundTrips(order);
}

test "jzon behaviour: round trip, every write path renders the same bytes" {
    var expected_buf: [2048]u8 = undefined;
    var expected: Sink = .init(&expected_buf);
    try std_emitter.emit(&expected, ORDER);

    inline for (EMIT_SHAPES) |shape| {
        var buf: [2048]u8 = undefined;
        var sink: Sink = .init(&buf);
        try generated_emitter.emit(&sink, ORDER, shape);

        try std.testing.expectEqualStrings(expected.filled(), sink.filled());
    }
}

