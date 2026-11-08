//! JZON generated_emitter
//!
//! ### file: src/jzon/src/serialize/generated_emitter.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The write path generated from the type: turns a typed value into JSON with the
//! shape of the type resolved at compile time.
//!
//! ### note:
//!
//! Every object key, its quotes, its colon and the comma before it are baked into one
//! literal, so a field costs one fixed-size copy plus its value. The output matches
//! `std.json.Stringify` byte for byte under every `EmitShape` pairing.
//!
//! A field type with no JSON form is a compile error naming the type, never a runtime
//! failure. Writes land as they are produced, so a value that runs out of room leaves
//! what fit behind. A caller that needs all-or-nothing keeps its own mark.
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
const Sink = @import("../Sink.zig");
const escape = @import("../escape.zig");
const escape_vector = @import("../escape_vector.zig");
const float = @import("../float.zig");
const integer = @import("../integer.zig");
const reflect = @import("../reflect.zig");

// --------------------------------------------------------- //
// Private:

/// Translate a `Sink` failure into this module's set.
///
/// Param:
/// err - Sink.Error (the failure the sink reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn sinkError(err: Sink.Error) Error {
    return switch (err) {
        error.Jzon_Sink_NoSpaceLeft => Error.Jzon_GeneratedEmitter_NoSpaceLeft,
    };
}

/// Translate an `integer` failure into this module's set.
///
/// Param:
/// err - integer.Error (the failure the integer writer reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn integerError(err: integer.Error) Error {
    return switch (err) {
        error.Jzon_Integer_NoSpaceLeft => Error.Jzon_GeneratedEmitter_NoSpaceLeft,
        error.Jzon_Integer_BadNumber => Error.Jzon_GeneratedEmitter_BadNumber,
    };
}

/// Translate a `float` failure into this module's set.
///
/// Param:
/// err - float.Error (the failure the float writer reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn floatError(err: float.Error) Error {
    return switch (err) {
        error.Jzon_Float_NoSpaceLeft => Error.Jzon_GeneratedEmitter_NoSpaceLeft,
        error.Jzon_Float_BadNumber => Error.Jzon_GeneratedEmitter_BadNumber,
    };
}

/// Translate an `escape` failure into this module's set.
///
/// Param:
/// err - escape.Error (the failure the scalar escape reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn escapeError(err: escape.Error) Error {
    return switch (err) {
        error.Jzon_Escape_NoSpaceLeft => Error.Jzon_GeneratedEmitter_NoSpaceLeft,
        error.Jzon_Escape_BadEscape => Error.Jzon_GeneratedEmitter_BadEscape,
    };
}

/// Translate an `escape_vector` failure into this module's set.
///
/// Param:
/// err - escape_vector.Error (the failure the vector escape reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn escapeVectorError(err: escape_vector.Error) Error {
    return switch (err) {
        error.Jzon_EscapeVector_NoSpaceLeft => Error.Jzon_GeneratedEmitter_NoSpaceLeft,
        error.Jzon_EscapeVector_BadEscape => Error.Jzon_GeneratedEmitter_BadEscape,
    };
}

/// Render a struct as a JSON object, fields in declaration order.
///
/// Param:
/// sink - *Sink (where the object goes)
/// value - anytype (a struct that is not a tuple)
/// shape - EmitShape (comptime, which integer path and which escape scan to run)
///
/// Return:
/// - void
/// - Error.Jzon_GeneratedEmitter_NoSpaceLeft when the object does not fit
fn emitStruct(sink: *Sink, value: anytype, comptime shape: EmitShape) Error!void {
    sink.byte('{') catch |err| return sinkError(err);

    inline for (comptime std.meta.fieldNames(@TypeOf(value)), 0..) |name, index| {
        sink.literal(comptime fieldKey(name, index == 0)) catch |err| return sinkError(err);
        try emit(sink, @field(value, name), shape);
    }

    sink.byte('}') catch |err| return sinkError(err);
}

/// Render a slice as a JSON array.
///
/// Param:
/// sink - *Sink (where the array goes)
/// values - anytype (a slice of any shape `emit` takes)
/// shape - EmitShape (comptime, which integer path and which escape scan to run)
///
/// Return:
/// - void
/// - Error.Jzon_GeneratedEmitter_NoSpaceLeft when the array does not fit
fn emitSlice(sink: *Sink, values: anytype, comptime shape: EmitShape) Error!void {
    sink.byte('[') catch |err| return sinkError(err);

    for (values, 0..) |element, index| {
        if (index != 0) sink.byte(',') catch |err| return sinkError(err);

        try emit(sink, element, shape);
    }

    sink.byte(']') catch |err| return sinkError(err);
}

/// Render a string through whichever escape scan the shape asked for.
///
/// Param:
/// sink - *Sink (where the string goes)
/// text - []const u8 (the bytes to escape and write)
/// shape - EmitShape (comptime, which escape scan to run)
///
/// Return:
/// - void
/// - Error.Jzon_GeneratedEmitter_NoSpaceLeft when the string does not fit
fn emitString(sink: *Sink, text: []const u8, comptime shape: EmitShape) Error!void {
    switch (shape.escapes) {
        .SCALAR => escape.encode(sink, text) catch |err| return escapeError(err),
        .VECTOR => escape_vector.encode(sink, text) catch |err| return escapeVectorError(err),
    }
}

/// The whole punctuation of one object key, as one literal.
///
/// Note:
/// - Everything a field name costs at runtime is this one copy: the comma when it is
///   not the first field, the quotes, the escaped name and the colon.
/// - The name is escaped here, at compile time, so a field spelled with a quote or a
///   control byte still matches what std would write for it.
///
/// Param:
/// name - []const u8 (comptime, the field name)
/// first - bool (comptime, whether this is the object's first field)
///
/// Return:
/// - []const u8 (the literal to copy in ahead of the value)
fn fieldKey(comptime name: []const u8, comptime first: bool) []const u8 {
    comptime {
        // Six is the longest escape any one byte takes, plus room for the comma, both
        // quotes and the colon.
        var buf: [name.len * 6 + 4]u8 = undefined;
        var sink: Sink = .init(&buf);

        sink.literal(if (first) "\"" else ",\"") catch |err| {
            @compileError("jzon emitter: key for " ++ name ++ ": " ++ @errorName(err));
        };
        escape.encodeBody(&sink, name) catch |err| {
            @compileError("jzon emitter: key for " ++ name ++ ": " ++ @errorName(err));
        };
        sink.literal("\":") catch |err| {
            @compileError("jzon emitter: key for " ++ name ++ ": " ++ @errorName(err));
        };

        const final = buf[0..sink.written()].*;

        return &final;
    }
}

// --------------------------------------------------------- //
// Public:

/// How rendering can fail.
///
/// Note:
/// - Only NoSpaceLeft happens in practice. Nothing is allocated, so a full buffer is
///   the whole failure surface.
/// - BadNumber and BadEscape exist so every member of the inner sets maps to a real
///   member here. A write never returns them.
pub const Error = error{
    Jzon_GeneratedEmitter_NoSpaceLeft,
    Jzon_GeneratedEmitter_BadNumber,
    Jzon_GeneratedEmitter_BadEscape,
};

/// Render `value` as JSON.
///
/// Note:
/// - Recursive over the type, not over any runtime shape, so a nested struct or a
///   slice of them costs nothing at runtime beyond its own bytes.
///
/// Param:
/// sink - *Sink (where the JSON text goes)
/// value - anytype (bool, any integer or float width, a string, a slice, an
///   optional, an exhaustive enum, or a struct of those)
/// shape - EmitShape (comptime, which integer path and which escape scan to run)
///
/// Return:
/// - void
/// - Error.Jzon_GeneratedEmitter_NoSpaceLeft when the rendered form does not fit
pub fn emit(sink: *Sink, value: anytype, comptime shape: EmitShape) Error!void {
    const Value = @TypeOf(value);

    switch (@typeInfo(Value)) {
        .bool => {
            if (value) {
                sink.literal("true") catch |err| return sinkError(err);
            } else {
                sink.literal("false") catch |err| return sinkError(err);
            }
        },

        .int => switch (shape.numbers) {
            .FMT => integer.appendFmt(sink, value) catch |err| return integerError(err),
            .TABLE => integer.appendTable(sink, value) catch |err| return integerError(err),
        },

        .float => float.append(sink, value) catch |err| return floatError(err),

        .optional => {
            if (value) |payload| return emit(sink, payload, shape);

            sink.literal("null") catch |err| return sinkError(err);
        },

        .@"enum" => {
            if (!reflect.isExhaustive(Value)) @compileError(
                "jzon emitter: " ++ @typeName(Value) ++
                    " is non-exhaustive, so a value it carries may have no tag name",
            );

            try emitString(sink, @tagName(value), shape);
        },

        .@"struct" => |info| {
            if (info.is_tuple) @compileError(
                "jzon emitter: " ++ @typeName(Value) ++ " is a tuple, which has no object form",
            );

            try emitStruct(sink, value, shape);
        },

        .pointer => |info| {
            if (info.size != .slice) @compileError(
                "jzon emitter: " ++ @typeName(Value) ++
                    " is not a slice, so it has no JSON form",
            );

            if (info.child == u8) return emitString(sink, value, shape);

            try emitSlice(sink, value, shape);
        },

        else => @compileError("jzon emitter: " ++ @typeName(Value) ++ " has no JSON form"),
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const std_emitter = @import("std_emitter.zig");

/// Every pairing of the two axes, so a case can check all of them at once.
const SHAPES = [_]EmitShape{
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

const Nested = struct {
    alpha: i32,
    beta: []const u8,
};

const Status = enum { PENDING, SHIPPED };

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

const Pair = struct {
    left: u8,
    right: u8,
};

const PAIR: Pair = .{
    .left = 1,
    .right = 2,
};

/// What PAIR renders to, so a case can size a buffer against it.
const PAIR_TEXT = "{\"left\":1,\"right\":2}";

/// Render one value under every pairing and require each to match the std path.
fn expectAgreesWithStd(value: anytype) !void {
    var expected_buf: [4096]u8 = undefined;
    var expected: Sink = .init(&expected_buf);
    try std_emitter.emit(&expected, value);

    inline for (SHAPES) |shape| {
        var ours: [4096]u8 = undefined;
        var sink: Sink = .init(&ours);
        try emit(&sink, value, shape);

        try std.testing.expectEqualStrings(expected.filled(), sink.filled());
    }
}

test "jzon serialize: generated_emitter, renders a whole record" {
    var buf: [512]u8 = undefined;
    var sink: Sink = .init(&buf);

    try emit(&sink, RECORD, .{});

    try std.testing.expectEqualStrings(
        "{\"id\":7,\"name\":\"a\\\"b\",\"ratio\":2.5,\"active\":true," ++
            "\"status\":\"SHIPPED\",\"note\":null,\"tags\":[\"one\",\"two\"]," ++
            "\"nested\":{\"alpha\":-3,\"beta\":\"x\"}}",
        sink.filled(),
    );
}

test "jzon serialize: generated_emitter, every pairing renders the same bytes as std" {
    try expectAgreesWithStd(RECORD);
}

test "jzon serialize: generated_emitter, each shape on its own matches std" {
    try expectAgreesWithStd(true);
    try expectAgreesWithStd(false);
    try expectAgreesWithStd(@as(u8, 255));
    try expectAgreesWithStd(@as(i64, -9223372036854775808));
    try expectAgreesWithStd(@as(f64, 0.1));
    try expectAgreesWithStd(@as([]const u8, "text \" with \n escapes"));
    try expectAgreesWithStd(@as([]const u32, &.{ 1, 2, 3 }));
    try expectAgreesWithStd(@as(?u8, null));
    try expectAgreesWithStd(@as(?u8, 9));
    try expectAgreesWithStd(Status.PENDING);
    try expectAgreesWithStd(Nested{
        .alpha = 0,
        .beta = "",
    });
}

test "jzon serialize: generated_emitter, value that does not fit keeps the prefix" {
    var buf: [8]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(
        Error.Jzon_GeneratedEmitter_NoSpaceLeft,
        emit(&sink, RECORD, .{}),
    );

    // Writes land as they are produced, so the prefix that fit is still there. The
    // next key literal is one whole write, so none of it landed.
    try std.testing.expectEqualStrings("{\"id\":7", sink.filled());
}

test "jzon serialize: generated_emitter, sinkError maps no space left" {
    const err = sinkError(error.Jzon_Sink_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_GeneratedEmitter_NoSpaceLeft, err);
}

test "jzon serialize: generated_emitter, integerError maps no space left" {
    const err = integerError(error.Jzon_Integer_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_GeneratedEmitter_NoSpaceLeft, err);
}

test "jzon serialize: generated_emitter, integerError maps bad number" {
    const err = integerError(error.Jzon_Integer_BadNumber);

    try std.testing.expectEqual(Error.Jzon_GeneratedEmitter_BadNumber, err);
}

test "jzon serialize: generated_emitter, floatError maps no space left" {
    const err = floatError(error.Jzon_Float_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_GeneratedEmitter_NoSpaceLeft, err);
}

test "jzon serialize: generated_emitter, floatError maps bad number" {
    const err = floatError(error.Jzon_Float_BadNumber);

    try std.testing.expectEqual(Error.Jzon_GeneratedEmitter_BadNumber, err);
}

test "jzon serialize: generated_emitter, escapeError maps no space left" {
    const err = escapeError(error.Jzon_Escape_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_GeneratedEmitter_NoSpaceLeft, err);
}

test "jzon serialize: generated_emitter, escapeError maps bad escape" {
    const err = escapeError(error.Jzon_Escape_BadEscape);

    try std.testing.expectEqual(Error.Jzon_GeneratedEmitter_BadEscape, err);
}

test "jzon serialize: generated_emitter, escapeVectorError maps no space left" {
    const err = escapeVectorError(error.Jzon_EscapeVector_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_GeneratedEmitter_NoSpaceLeft, err);
}

test "jzon serialize: generated_emitter, escapeVectorError maps bad escape" {
    const err = escapeVectorError(error.Jzon_EscapeVector_BadEscape);

    try std.testing.expectEqual(Error.Jzon_GeneratedEmitter_BadEscape, err);
}

test "jzon serialize: generated_emitter, fills an exact-fit buffer under every pairing" {
    inline for (SHAPES) |shape| {
        var buf: [PAIR_TEXT.len]u8 = undefined;
        var sink: Sink = .init(&buf);

        try emit(&sink, PAIR, shape);

        try std.testing.expectEqualStrings(PAIR_TEXT, sink.filled());
        try std.testing.expectEqual(@as(usize, 0), sink.remaining());
    }
}

test "jzon serialize: generated_emitter, every buffer shorter than the render is no space left" {
    inline for (SHAPES) |shape| {
        for (0..PAIR_TEXT.len) |len| {
            var buf: [PAIR_TEXT.len]u8 = undefined;
            var sink: Sink = .init(buf[0..len]);

            try std.testing.expectError(
                Error.Jzon_GeneratedEmitter_NoSpaceLeft,
                emit(&sink, PAIR, shape),
            );

            // Whatever landed is a prefix of the whole render, never bytes the full
            // buffer would not have produced.
            try std.testing.expect(std.mem.startsWith(u8, PAIR_TEXT, sink.filled()));
        }
    }
}

test "jzon serialize: generated_emitter, escapes a field name that needs it" {
    const Odd = struct {
        @"a\"b": u8,
        @"tab\there": u8,
    };
    const odd: Odd = .{
        .@"a\"b" = 1,
        .@"tab\there" = 2,
    };

    try expectAgreesWithStd(odd);

    var buf: [128]u8 = undefined;
    var sink: Sink = .init(&buf);
    try emit(&sink, odd, .{});

    try std.testing.expectEqualStrings("{\"a\\\"b\":1,\"tab\\there\":2}", sink.filled());
}

test "jzon serialize: generated_emitter, renders the extremes of the integer widths" {
    const Extremes = struct {
        unsigned_high: u64,
        signed_high: i64,
        signed_low: i64,
        narrow: u8,
        one_bit: u1,
    };

    try expectAgreesWithStd(Extremes{
        .unsigned_high = std.math.maxInt(u64),
        .signed_high = std.math.maxInt(i64),
        .signed_low = std.math.minInt(i64),
        .narrow = 255,
        .one_bit = 1,
    });
}

test "jzon serialize: generated_emitter, renders the float widths the way std does" {
    const Widths = struct {
        half: f16,
        single: f32,
        double: f64,
    };

    try expectAgreesWithStd(Widths{
        .half = 1.5,
        .single = 0.1,
        .double = 0.1,
    });
}

test "jzon serialize: generated_emitter, renders the shapes with nothing in them" {
    const Empty = struct {};

    inline for (SHAPES) |shape| {
        var buf: [64]u8 = undefined;
        var sink: Sink = .init(&buf);

        try emit(&sink, Empty{}, shape);
        try emit(&sink, @as([]const u8, ""), shape);
        try emit(&sink, @as([]const u32, &.{}), shape);
        try emit(&sink, @as(?u8, null), shape);

        try std.testing.expectEqualStrings("{}\"\"[]null", sink.filled());
    }
}

test "jzon serialize: generated_emitter, renders a null nested optional" {
    const Held = struct { value: u8 };
    const Wrapper = struct { held: ?Held };

    try expectAgreesWithStd(Wrapper{ .held = null });
}

test "jzon serialize: generated_emitter, renders a filled nested optional" {
    const Held = struct { value: u8 };
    const Wrapper = struct { held: ?Held };

    try expectAgreesWithStd(Wrapper{ .held = .{ .value = 7 } });
}

test "jzon serialize: generated_emitter, renders a value nested several levels deep" {
    const Leaf = struct { value: u8 };
    const Middle = struct {
        leaf: Leaf,
        siblings: []const Leaf,
    };
    const Root = struct { middle: Middle };

    try expectAgreesWithStd(Root{
        .middle = .{
            .leaf = .{ .value = 9 },
            .siblings = &.{
                .{ .value = 1 },
                .{ .value = 2 },
            },
        },
    });
}

test "jzon serialize: generated_emitter, renders a slice of slices" {
    const Grid = struct { rows: []const []const u8 };

    try expectAgreesWithStd(Grid{ .rows = &.{ "one", "", "three" } });
}

test "jzon serialize: generated_emitter, renders a string that fills several lanes" {
    const Long = struct { text: []const u8 };

    try expectAgreesWithStd(Long{
        .text = "a string of well over sixteen bytes, carrying a \" and a \\ and a \n " ++
            "so both scans have to break their clean run more than once",
    });
}

test "jzon serialize: generated_emitter, empty buffer is no space left" {
    inline for (SHAPES) |shape| {
        var buf: [0]u8 = undefined;
        var sink: Sink = .init(&buf);

        try std.testing.expectError(
            Error.Jzon_GeneratedEmitter_NoSpaceLeft,
            emit(&sink, PAIR, shape),
        );
    }
}

