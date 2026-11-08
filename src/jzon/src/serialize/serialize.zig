//! JZON serialize
//!
//! ### file: src/jzon/src/serialize/serialize.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The one call that turns a typed value into JSON text: runs the write path the
//! options name over the caller's buffer and reports how many bytes the value took.
//!
//! ### note:
//!
//! Nothing is allocated. A value that does not fit is `Jzon_Serialize_NoSpaceLeft` and
//! no length. What the buffer holds afterwards differs by path: `.STD` leaves it as it
//! found it, a generated path leaves the prefix that fit. Neither is a rendered value.
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
const EmitShape = @import("EmitShape.zig");
const SerializeOptions = @import("SerializeOptions.zig");
const Sink = @import("../Sink.zig");
const generated_emitter = @import("generated_emitter.zig");
const std_emitter = @import("std_emitter.zig");

// --------------------------------------------------------- //
// Private:

/// The pairing `.GENERATED_FMT` runs.
const SHAPE_FMT: EmitShape = .{
    .numbers = .FMT,
    .escapes = .SCALAR,
};

/// The pairing `.GENERATED` runs.
const SHAPE_TABLE: EmitShape = .{
    .numbers = .TABLE,
    .escapes = .SCALAR,
};

/// The pairing `.GENERATED_VECTOR` runs.
const SHAPE_VECTOR: EmitShape = .{
    .numbers = .TABLE,
    .escapes = .VECTOR,
};

/// Translate a `std_emitter` failure into the public set.
///
/// Param:
/// err - std_emitter.Error (the failure the std path reported)
///
/// Return:
/// - Error (the same failure under the public name)
fn stdEmitterError(err: std_emitter.Error) Error {
    return switch (err) {
        error.Jzon_StdEmitter_NoSpaceLeft => Error.Jzon_Serialize_NoSpaceLeft,
    };
}

/// Translate a `generated_emitter` failure into the public set.
///
/// Param:
/// err - generated_emitter.Error (the failure the generated path reported)
///
/// Return:
/// - Error (the same failure under the public name)
fn generatedEmitterError(err: generated_emitter.Error) Error {
    return switch (err) {
        error.Jzon_GeneratedEmitter_NoSpaceLeft => Error.Jzon_Serialize_NoSpaceLeft,
        error.Jzon_GeneratedEmitter_BadNumber => Error.Jzon_Serialize_BadNumber,
        error.Jzon_GeneratedEmitter_BadEscape => Error.Jzon_Serialize_BadEscape,
    };
}

/// Run one generated pairing and translate its failure.
///
/// Param:
/// sink - *Sink (where the JSON text goes)
/// value - anytype (the value to render)
/// shape - EmitShape (comptime, the pairing to run)
///
/// Return:
/// - void
/// - Error.Jzon_Serialize_NoSpaceLeft when the rendered form does not fit
fn emitGenerated(sink: *Sink, value: anytype, comptime shape: EmitShape) Error!void {
    generated_emitter.emit(sink, value, shape) catch |err| return generatedEmitterError(err);
}

// --------------------------------------------------------- //
// Public:

/// How a render can fail.
///
/// Note:
/// - Only NoSpaceLeft happens in practice. Nothing is allocated, so a full buffer is
///   the whole failure surface.
/// - BadNumber and BadEscape exist so every member of the inner sets maps to a real
///   member here. A render never returns them.
pub const Error = error{
    Jzon_Serialize_NoSpaceLeft,
    Jzon_Serialize_BadNumber,
    Jzon_Serialize_BadEscape,
};

/// Render `value` as JSON into `buf`.
///
/// Note:
/// - The strategy is comptime, so only the path it names is compiled in. A shape the
///   generated paths refuse still renders under the default `.STD`.
///
/// Param:
/// buf - []u8 (where the JSON text goes, caller owned)
/// value - anytype (the value to render)
/// options - SerializeOptions (comptime, which write path runs)
///
/// Usage:
/// ```zig
/// var buf: [64 * 1024]u8 = undefined;
///
/// const len = try jzon.serialize(&buf, order, .{});
/// const faster = try jzon.serialize(&buf, order, .{ .strategy = .GENERATED });
/// ```
///
/// Return:
/// - usize (how many bytes of `buf` the value took)
/// - Error.Jzon_Serialize_NoSpaceLeft when the rendered form does not fit
pub fn serialize(
    buf: []u8,
    value: anytype,
    comptime options: SerializeOptions,
) Error!usize {
    var sink: Sink = .init(buf);

    switch (options.strategy) {
        .STD => std_emitter.emit(&sink, value) catch |err| return stdEmitterError(err),
        .GENERATED_FMT => try emitGenerated(&sink, value, SHAPE_FMT),
        .GENERATED => try emitGenerated(&sink, value, SHAPE_TABLE),
        .GENERATED_VECTOR => try emitGenerated(&sink, value, SHAPE_VECTOR),
    }

    return sink.written();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Strategy = SerializeOptions.Strategy;

/// Every strategy, so a case can check all of them at once.
const STRATEGIES = [_]Strategy{ .STD, .GENERATED_FMT, .GENERATED, .GENERATED_VECTOR };

/// Every strategy generated from the type, which write as they go.
const GENERATED = [_]Strategy{ .GENERATED_FMT, .GENERATED, .GENERATED_VECTOR };

const Status = enum { PENDING, SHIPPED };

const Nested = struct {
    alpha: i32,
    beta: []const u8,
};

const Record = struct {
    id: u64,
    name: []const u8,
    ratio: f64,
    active: bool,
    status: Status,
    note: ?[]const u8,
    tags: []const []const u8,
    nested: Nested,
};

const RECORD: Record = .{
    .id = 7,
    .name = "a\"b",
    .ratio = 2.5,
    .active = true,
    .status = .SHIPPED,
    .note = null,
    .tags = &.{ "one", "two" },
    .nested = .{
        .alpha = -3,
        .beta = "x",
    },
};

const RENDERED =
    "{\"id\":7,\"name\":\"a\\\"b\",\"ratio\":2.5,\"active\":true," ++
    "\"status\":\"SHIPPED\",\"note\":null,\"tags\":[\"one\",\"two\"]," ++
    "\"nested\":{\"alpha\":-3,\"beta\":\"x\"}}";

const NESTED: Nested = .{
    .alpha = -3,
    .beta = "x",
};

const NESTED_RENDERED = "{\"alpha\":-3,\"beta\":\"x\"}";

test "jzon serialize: serialize, renders a record through every strategy" {
    inline for (STRATEGIES) |strategy| {
        var buf: [512]u8 = undefined;
        const len = try serialize(&buf, RECORD, .{ .strategy = strategy });

        try std.testing.expectEqualStrings(RENDERED, buf[0..len]);
    }
}

test "jzon serialize: serialize, returns the length of what it wrote" {
    var buf: [64]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 4), try serialize(&buf, true, .{}));
    try std.testing.expectEqual(@as(usize, 2), try serialize(&buf, @as([]const u8, ""), .{}));

    const numbers: []const u32 = &.{ 1, 2, 3 };

    try std.testing.expectEqual(@as(usize, 7), try serialize(&buf, numbers, .{}));
}

test "jzon serialize: serialize, value that does not fit is no space left" {
    inline for (STRATEGIES) |strategy| {
        var buf: [8]u8 = undefined;

        try std.testing.expectError(
            Error.Jzon_Serialize_NoSpaceLeft,
            serialize(&buf, RECORD, .{ .strategy = strategy }),
        );
    }
}

test "jzon serialize: serialize, STD renders a shape the generated paths refuse" {
    // A tuple has no object form, so only the default path takes it. That is the
    // whole reason the default is the std-backed one.
    var buf: [32]u8 = undefined;
    const len = try serialize(&buf, .{ @as(u8, 1), true }, .{});

    try std.testing.expectEqualStrings("[1,true]", buf[0..len]);
}

test "jzon serialize: serialize, stdEmitterError maps no space left" {
    const err = stdEmitterError(error.Jzon_StdEmitter_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_Serialize_NoSpaceLeft, err);
}

test "jzon serialize: serialize, generatedEmitterError maps no space left" {
    const err = generatedEmitterError(error.Jzon_GeneratedEmitter_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_Serialize_NoSpaceLeft, err);
}

test "jzon serialize: serialize, generatedEmitterError maps bad number" {
    const err = generatedEmitterError(error.Jzon_GeneratedEmitter_BadNumber);

    try std.testing.expectEqual(Error.Jzon_Serialize_BadNumber, err);
}

test "jzon serialize: serialize, generatedEmitterError maps bad escape" {
    const err = generatedEmitterError(error.Jzon_GeneratedEmitter_BadEscape);

    try std.testing.expectEqual(Error.Jzon_Serialize_BadEscape, err);
}

test "jzon serialize: serialize, fills a buffer that is exactly big enough" {
    inline for (STRATEGIES) |strategy| {
        var buf: [NESTED_RENDERED.len]u8 = undefined;
        const len = try serialize(&buf, NESTED, .{ .strategy = strategy });

        try std.testing.expectEqual(buf.len, len);
        try std.testing.expectEqualStrings(NESTED_RENDERED, buf[0..len]);
    }
}

test "jzon serialize: serialize, one byte short is no space left" {
    inline for (STRATEGIES) |strategy| {
        var buf: [NESTED_RENDERED.len - 1]u8 = undefined;

        try std.testing.expectError(
            Error.Jzon_Serialize_NoSpaceLeft,
            serialize(&buf, NESTED, .{ .strategy = strategy }),
        );
    }
}

test "jzon serialize: serialize, empty buffer is no space left" {
    const empty: []const u32 = &.{};

    inline for (STRATEGIES) |strategy| {
        var buf: [0]u8 = undefined;

        try std.testing.expectError(
            Error.Jzon_Serialize_NoSpaceLeft,
            serialize(&buf, true, .{ .strategy = strategy }),
        );
        try std.testing.expectError(
            Error.Jzon_Serialize_NoSpaceLeft,
            serialize(&buf, empty, .{ .strategy = strategy }),
        );
    }
}

test "jzon serialize: serialize, generated strategy leaves the prefix that fit" {
    // Writes land as they are produced, so a failed render is not a rollback. No
    // length comes back, so the prefix is not a value a caller can read, only bytes
    // it is free to overwrite.
    inline for (GENERATED) |strategy| {
        var buf: [10]u8 = @splat('#');

        try std.testing.expectError(
            Error.Jzon_Serialize_NoSpaceLeft,
            serialize(&buf, NESTED, .{ .strategy = strategy }),
        );

        // The brace and the whole first key literal fit, the integer after them does
        // not. How much of that integer landed differs by path, so only what every
        // one of them wrote is checked.
        try std.testing.expect(std.mem.startsWith(u8, &buf, "{\"alpha\":"));
    }
}

test "jzon serialize: serialize, renders the extremes of the number widths" {
    inline for (STRATEGIES) |strategy| {
        var buf: [64]u8 = undefined;
        const options: SerializeOptions = .{ .strategy = strategy };

        const widest = try serialize(&buf, @as(u64, std.math.maxInt(u64)), options);
        try std.testing.expectEqualStrings("18446744073709551615", buf[0..widest]);

        const lowest = try serialize(&buf, @as(i64, std.math.minInt(i64)), options);
        try std.testing.expectEqualStrings("-9223372036854775808", buf[0..lowest]);

        const narrow = try serialize(&buf, @as(u1, 1), options);
        try std.testing.expectEqualStrings("1", buf[0..narrow]);
    }
}

test "jzon serialize: serialize, renders a field name that needs escaping" {
    const Awkward = struct {
        @"a\"b": u8,
        @"tab\there": u8,
    };
    const awkward: Awkward = .{
        .@"a\"b" = 1,
        .@"tab\there" = 2,
    };

    inline for (STRATEGIES) |strategy| {
        var buf: [64]u8 = undefined;
        const len = try serialize(&buf, awkward, .{ .strategy = strategy });

        try std.testing.expectEqualStrings("{\"a\\\"b\":1,\"tab\\there\":2}", buf[0..len]);
    }
}

test "jzon serialize: serialize, renders a deeply nested value" {
    const Leaf = struct { value: u8 };
    const Middle = struct { leaf: Leaf };
    const Outer = struct { middle: Middle };

    const outer: Outer = .{ .middle = .{ .leaf = .{ .value = 7 } } };

    inline for (STRATEGIES) |strategy| {
        var buf: [64]u8 = undefined;
        const len = try serialize(&buf, outer, .{ .strategy = strategy });

        try std.testing.expectEqualStrings(
            "{\"middle\":{\"leaf\":{\"value\":7}}}",
            buf[0..len],
        );
    }
}

