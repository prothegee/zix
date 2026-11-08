//! JZON skip
//!
//! ### file: src/jzon/src/deserialize/skip.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Walks past one whole JSON value without building anything out of it, however deep
//! it nests. This is what `unknown = .SKIP` runs on a key the target type lacks.
//!
//! ### note:
//!
//! The walk validates, not merely bounds, so a malformed value fails whether the parse
//! wanted it or not. Nothing is allocated and no string is decoded. A document is
//! untrusted, so the nesting a walk follows is capped at `MAX_DEPTH`. Anything deeper
//! is refused instead of growing the stack.
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
const Cursor = @import("../Cursor.zig");
const ScanShape = @import("ScanShape.zig");
const float = @import("../float.zig");

// --------------------------------------------------------- //
// Private:

/// Translate a `Cursor` failure into this module's set.
///
/// Param:
/// err - Cursor.Error (the failure the cursor reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn cursorError(err: Cursor.Error) Error {
    return switch (err) {
        error.Jzon_Cursor_Truncated => Error.Jzon_Skip_Truncated,
        error.Jzon_Cursor_Unexpected => Error.Jzon_Skip_Unexpected,
    };
}

/// Translate a `ScanShape` failure into this module's set.
///
/// Param:
/// err - ScanShape.Error (the failure the width-picked scan reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn scanShapeError(err: ScanShape.Error) Error {
    return switch (err) {
        error.Jzon_ScanShape_Truncated => Error.Jzon_Skip_Truncated,
        error.Jzon_ScanShape_Unexpected => Error.Jzon_Skip_Unexpected,
    };
}

/// Step over a string token, key or value.
///
/// Param:
/// cursor - *Cursor (positioned at the opening quote)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - void
/// - Error.Jzon_Skip_Truncated or Error.Jzon_Skip_Unexpected when the token is broken
fn stringToken(cursor: *Cursor, comptime shape: ScanShape) Error!void {
    _ = shape.stringSpan(cursor) catch |err| return scanShapeError(err);
}

/// Step over one value sitting `depth` containers deep.
///
/// Param:
/// cursor - *Cursor (positioned at the value, leading whitespace allowed)
/// shape - ScanShape (comptime, which width to scan at)
/// depth - usize (how many containers enclose this value)
///
/// Return:
/// - void
/// - Error.Jzon_Skip_Truncated when the document ends inside the value
/// - Error.Jzon_Skip_Unexpected when the value is malformed, or nests past MAX_DEPTH
fn valueAt(cursor: *Cursor, comptime shape: ScanShape, depth: usize) Error!void {
    if (depth > MAX_DEPTH) return Error.Jzon_Skip_Unexpected;

    shape.skipSpace(cursor);

    const head = cursor.peek() catch |err| return cursorError(err);

    switch (head) {
        '{' => return object(cursor, shape, depth),
        '[' => return array(cursor, shape, depth),
        '"' => return stringToken(cursor, shape),
        't' => cursor.literal("true") catch |err| return cursorError(err),
        'f' => cursor.literal("false") catch |err| return cursorError(err),
        'n' => cursor.literal("null") catch |err| return cursorError(err),
        '-', '0'...'9' => {
            const text = cursor.numberSpan() catch |err| return cursorError(err);

            if (!float.isNumber(text)) return Error.Jzon_Skip_Unexpected;
        },

        else => return Error.Jzon_Skip_Unexpected,
    }
}

/// Step over an object, keys and values alike.
///
/// Param:
/// cursor - *Cursor (positioned at the opening brace)
/// shape - ScanShape (comptime, which width to scan at)
/// depth - usize (how many containers enclose this object)
///
/// Return:
/// - void
/// - Error.Jzon_Skip_Truncated or Error.Jzon_Skip_Unexpected when the object is broken
fn object(cursor: *Cursor, comptime shape: ScanShape, depth: usize) Error!void {
    cursor.expect('{') catch |err| return cursorError(err);
    shape.skipSpace(cursor);

    if (cursor.accept('}')) return;

    while (true) {
        shape.skipSpace(cursor);
        try stringToken(cursor, shape);

        shape.skipSpace(cursor);
        cursor.expect(':') catch |err| return cursorError(err);

        try valueAt(cursor, shape, depth + 1);

        shape.skipSpace(cursor);
        if (cursor.accept(',')) continue;

        cursor.expect('}') catch |err| return cursorError(err);

        return;
    }
}

/// Step over an array, one element at a time.
///
/// Param:
/// cursor - *Cursor (positioned at the opening bracket)
/// shape - ScanShape (comptime, which width to scan at)
/// depth - usize (how many containers enclose this array)
///
/// Return:
/// - void
/// - Error.Jzon_Skip_Truncated or Error.Jzon_Skip_Unexpected when the array is broken
fn array(cursor: *Cursor, comptime shape: ScanShape, depth: usize) Error!void {
    cursor.expect('[') catch |err| return cursorError(err);
    shape.skipSpace(cursor);

    if (cursor.accept(']')) return;

    while (true) {
        try valueAt(cursor, shape, depth + 1);

        shape.skipSpace(cursor);
        if (cursor.accept(',')) continue;

        cursor.expect(']') catch |err| return cursorError(err);

        return;
    }
}

// --------------------------------------------------------- //
// Public:

/// How a walk can fail.
///
/// Note:
/// - Truncated means the document ended inside the value. Unexpected means the value
///   is malformed, or nests past `MAX_DEPTH`.
pub const Error = error{
    Jzon_Skip_Truncated,
    Jzon_Skip_Unexpected,
};

/// How deep a stepped-over value may nest.
///
/// Note:
/// - Well above what a request body ever nests to, and well below what would trouble
///   the stack. std.json caps its own nesting the same way.
pub const MAX_DEPTH = 256;

/// Step over one whole value, whatever shape it is.
///
/// Param:
/// cursor - *Cursor (positioned at the value, leading whitespace allowed)
/// shape - ScanShape (comptime, which width to scan at)
///
/// Return:
/// - void
/// - Error.Jzon_Skip_Truncated when the document ends inside the value
/// - Error.Jzon_Skip_Unexpected when the value is malformed, or nests past MAX_DEPTH
pub fn value(cursor: *Cursor, comptime shape: ScanShape) Error!void {
    return valueAt(cursor, shape, 0);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Both widths, so every case checks the pair agrees.
const SHAPES = [_]ScanShape{
    .{ .scan = .SCALAR },
    .{ .scan = .VECTOR },
};

/// Step over the value at the head of `document` and require what is left.
fn expectLeaves(document: []const u8, rest: []const u8) !void {
    inline for (SHAPES) |shape| {
        var cursor: Cursor = .init(document);
        try value(&cursor, shape);

        try std.testing.expectEqualStrings(rest, cursor.src[cursor.pos..]);
    }
}

/// Require the value at the head of `document` to be refused, at both widths.
fn expectRefused(document: []const u8, failure: Error) !void {
    inline for (SHAPES) |shape| {
        var cursor: Cursor = .init(document);

        try std.testing.expectError(failure, value(&cursor, shape));
    }
}

/// A document `depth` arrays deep, closed again: `[[...]]`.
fn nested(comptime depth: usize) [depth * 2]u8 {
    var document: [depth * 2]u8 = undefined;
    @memset(document[0..depth], '[');
    @memset(document[depth..], ']');

    return document;
}

test "jzon deserialize: skip, steps over each scalar form" {
    try expectLeaves("true,rest", ",rest");
    try expectLeaves("false,rest", ",rest");
    try expectLeaves("null,rest", ",rest");
    try expectLeaves("42,rest", ",rest");
    try expectLeaves("-1.5e10,rest", ",rest");
    try expectLeaves("\"a string\",rest", ",rest");
}

test "jzon deserialize: skip, steps over a whole nested value" {
    try expectLeaves("{\"deep\":[1,2,{\"a\":null}],\"b\":\"x\"},rest", ",rest");
    try expectLeaves("[[[[]]]],rest", ",rest");
    try expectLeaves("{},rest", ",rest");
    try expectLeaves("[],rest", ",rest");
}

test "jzon deserialize: skip, steps over a value laid out with whitespace" {
    try expectLeaves("  { \"deep\" : [ 1 , 2 ] , \"b\" : true }  ,rest", "  ,rest");
    try expectLeaves("  \"padded\"  ,rest", "  ,rest");
}

test "jzon deserialize: skip, value the document ends inside is truncated" {
    const documents = [_][]const u8{
        "",
        "{",
        "{\"a\"",
        "{\"a\":",
        "{\"a\":1",
        "[",
        "[1,2",
        "\"unterminated",
        "tru",
        "nul",
    };

    for (documents) |document| try expectRefused(document, Error.Jzon_Skip_Truncated);
}

test "jzon deserialize: skip, value the grammar does not allow is unexpected" {
    const documents = [_][]const u8{
        "}",
        "]",
        ",",
        "{,}",
        "{\"a\":1,}",
        "{\"a\" 1}",
        "{a:1}",
        "{1:2}",
        "[1,,2]",
        "[1,]",
        "trve",
        "NULL",
    };

    for (documents) |document| try expectRefused(document, Error.Jzon_Skip_Unexpected);
}

test "jzon deserialize: skip, number the grammar does not allow is unexpected" {
    // The cursor bounds a number token without validating it, so the check has to
    // happen here or a document std refuses would be stepped over.
    const documents = [_][]const u8{
        "1.2.3",
        "01",
        "1e",
        "1.",
        "-",
    };

    for (documents) |document| try expectRefused(document, Error.Jzon_Skip_Unexpected);
}

test "jzon deserialize: skip, value it refuses is one std.json refuses too" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const malformed = [_][]const u8{
        "{\"a\":1,}",
        "[1,]",
        "1.2.3",
        "01",
        "trve",
    };

    for (malformed) |document| {
        try expectRefused(document, Error.Jzon_Skip_Unexpected);

        const theirs = std.json.parseFromSliceLeaky(std.json.Value, allocator, document, .{});

        try std.testing.expect(std.meta.isError(theirs));
    }
}

test "jzon deserialize: skip, nesting past the cap is unexpected" {
    const document = nested(MAX_DEPTH + 2);

    try expectRefused(&document, Error.Jzon_Skip_Unexpected);
}

test "jzon deserialize: skip, walks nesting right up to the cap" {
    const document = nested(MAX_DEPTH);

    inline for (SHAPES) |shape| {
        var cursor: Cursor = .init(&document);
        try value(&cursor, shape);

        try std.testing.expect(cursor.atEnd());
    }
}

test "jzon deserialize: skip, steps over empty containers inside a deep one" {
    try expectLeaves("{\"a\":{},\"b\":[],\"c\":{\"d\":[]}}|rest", "|rest");
}

test "jzon deserialize: skip, cursorError maps truncated" {
    const err = cursorError(error.Jzon_Cursor_Truncated);

    try std.testing.expectEqual(Error.Jzon_Skip_Truncated, err);
}

test "jzon deserialize: skip, cursorError maps unexpected" {
    const err = cursorError(error.Jzon_Cursor_Unexpected);

    try std.testing.expectEqual(Error.Jzon_Skip_Unexpected, err);
}

test "jzon deserialize: skip, scanShapeError maps truncated" {
    const err = scanShapeError(error.Jzon_ScanShape_Truncated);

    try std.testing.expectEqual(Error.Jzon_Skip_Truncated, err);
}

test "jzon deserialize: skip, scanShapeError maps unexpected" {
    const err = scanShapeError(error.Jzon_ScanShape_Unexpected);

    try std.testing.expectEqual(Error.Jzon_Skip_Unexpected, err);
}

