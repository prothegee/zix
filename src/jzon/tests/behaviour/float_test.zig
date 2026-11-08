//! JZON behaviour float_test
//!
//! ### file: src/jzon/tests/behaviour/float_test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The float path writes what `std.json` writes for the values a record carries,
//! and reads its own output back unchanged.
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

const Sink = jzon.Sink;
const float = jzon.float;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Values a record realistically carries: money, ratios, measurements.
const SAMPLES = [_]f64{
    0.0,
    1.0,
    -1.0,
    0.5,
    2.5,
    -12.75,
    0.1,
    99.99,
    12345.6789,
    -0.000125,
    1e10,
    1e-10,
};

/// The same value through std.json.Stringify, which jzon's output must match.
fn stdRendered(buf: []u8, value: anytype) std.json.Stringify.Error![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    try std.json.Stringify.value(value, .{}, &writer);

    return writer.buffered();
}

test "jzon behaviour: float, renders every sample the way std.json.Stringify does" {
    for (SAMPLES) |sample| {
        var ours: [512]u8 = undefined;
        var sink: Sink = .init(&ours);
        try float.append(&sink, sample);

        var theirs: [512]u8 = undefined;
        const expected = try stdRendered(&theirs, sample);

        try std.testing.expectEqualStrings(expected, sink.filled());
    }
}

test "jzon behaviour: float, renders values that read back as themselves" {
    for (SAMPLES) |sample| {
        var buf: [512]u8 = undefined;
        var sink: Sink = .init(&buf);
        try float.append(&sink, sample);

        try std.testing.expectEqual(sample, try std.fmt.parseFloat(f64, sink.filled()));
    }
}

test "jzon behaviour: float, renders a narrow width as the f64 nearest it" {
    var buf: [512]u8 = undefined;

    var half: Sink = .init(&buf);
    try float.append(&half, @as(f16, 1.5));
    try std.testing.expectEqualStrings("1.5", half.filled());

    var single: Sink = .init(&buf);
    try float.append(&single, @as(f32, 1.5));
    try std.testing.expectEqualStrings("1.5", single.filled());

    // 0.1 has no exact f32, so the f64 it widens to is what gets written, which
    // is what std writes for the same value.
    var inexact: Sink = .init(&buf);
    try float.append(&inexact, @as(f32, 0.1));
    try std.testing.expectEqualStrings("0.10000000149011612", inexact.filled());
}

test "jzon behaviour: float, renders a whole number without a fraction" {
    var buf: [64]u8 = undefined;

    var whole: Sink = .init(&buf);
    try float.append(&whole, @as(f64, 42.0));
    try std.testing.expectEqualStrings("42", whole.filled());

    var negative: Sink = .init(&buf);
    try float.append(&negative, @as(f64, -42.0));
    try std.testing.expectEqualStrings("-42", negative.filled());
}

test "jzon behaviour: float, writes after what the sink already holds" {
    var buf: [64]u8 = undefined;
    var sink: Sink = .init(&buf);

    try sink.literal("{\"ratio\":");
    try float.append(&sink, @as(f64, 2.5));
    try sink.byte('}');

    try std.testing.expectEqualStrings("{\"ratio\":2.5}", sink.filled());
}

test "jzon behaviour: float, reads back every sample it wrote" {
    for (SAMPLES) |sample| {
        var buf: [512]u8 = undefined;
        var sink: Sink = .init(&buf);
        try float.append(&sink, sample);

        try std.testing.expectEqual(sample, try float.parse(f64, sink.filled()));
    }
}

test "jzon behaviour: float, reads the same value std.json reads" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const numbers = [_][]const u8{
        "0",
        "1",
        "-1.5",
        "0.1",
        "12345.6789",
        "1e10",
        "1.2e-3",
        "-0",
    };

    for (numbers) |number| {
        const theirs = try std.json.parseFromSliceLeaky(f64, arena.allocator(), number, .{});

        try std.testing.expectEqual(theirs, try float.parse(f64, number));
    }
}

test "jzon behaviour: float, output parses back through std.json as a number" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    for (SAMPLES) |sample| {
        var buf: [512]u8 = undefined;
        var sink: Sink = .init(&buf);
        try float.append(&sink, sample);

        const parsed = try std.json.parseFromSliceLeaky(
            f64,
            arena.allocator(),
            sink.filled(),
            .{},
        );

        try std.testing.expectEqual(sample, parsed);
    }
}

