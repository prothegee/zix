//! JZON ScanShape
//!
//! ### file: src/jzon/src/deserialize/ScanShape.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The width a generated parse scans at (`ScanPath`), and the two reads that differ
//! between the widths: stepping over whitespace and bounding a string token.
//!
//! ### note:
//!
//! Both widths land the cursor in the same place on the same document and report the
//! same failures, so the width is a cost decision and nothing else. Everything else a
//! parse asks the document costs the same either way, so it goes straight to `Cursor`.
//! The read side keeps the `Scan` prefix so it never shares a file name with the write
//! side's `EmitShape`.
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
const StringSpan = @import("../StringSpan.zig");
const cursor_vector = @import("../cursor_vector.zig");

// --------------------------------------------------------- //
// Fields:

/// How many bytes a scan classifies at once.
scan: ScanPath = .SCALAR,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// Translate a `Cursor` failure into this module's set.
///
/// Param:
/// err - Cursor.Error (the failure the scalar cursor reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn cursorError(err: Cursor.Error) Error {
    return switch (err) {
        error.Jzon_Cursor_Truncated => Error.Jzon_ScanShape_Truncated,
        error.Jzon_Cursor_Unexpected => Error.Jzon_ScanShape_Unexpected,
    };
}

/// Translate a `cursor_vector` failure into this module's set.
///
/// Param:
/// err - cursor_vector.Error (the failure the vector scan reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn cursorVectorError(err: cursor_vector.Error) Error {
    return switch (err) {
        error.Jzon_CursorVector_Truncated => Error.Jzon_ScanShape_Truncated,
        error.Jzon_CursorVector_Unexpected => Error.Jzon_ScanShape_Unexpected,
    };
}

// --------------------------------------------------------- //
// Public:

/// How a read can fail.
///
/// Note:
/// - Truncated means the document ended early. Unexpected means the byte that is
///   there cannot start what was asked for. The stop byte is already recorded by the
///   cursor that failed.
pub const Error = error{
    Jzon_ScanShape_Truncated,
    Jzon_ScanShape_Unexpected,
};

/// How many bytes a scan classifies at once.
pub const ScanPath = enum {
    /// One byte at a time.
    SCALAR,
    /// One vector lane at a time, which pays on whitespace and long strings.
    VECTOR,
};

/// Step over the insignificant whitespace between tokens.
///
/// Param:
/// self - Self (comptime, which width to scan at)
/// cursor - *Cursor (the cursor to advance)
///
/// Return:
/// - void
pub inline fn skipSpace(comptime self: Self, cursor: *Cursor) void {
    switch (self.scan) {
        .SCALAR => cursor.skipSpace(),
        .VECTOR => cursor_vector.skipSpace(cursor),
    }
}

/// Read a string token and return the bytes between its quotes undecoded.
///
/// Param:
/// self - Self (comptime, which width to scan at)
/// cursor - *Cursor (positioned at the opening quote)
///
/// Return:
/// - StringSpan (the undecoded body, plus whether it holds an escape)
/// - Error.Jzon_ScanShape_Truncated when the closing quote never arrives
/// - Error.Jzon_ScanShape_Unexpected when the token does not open with a quote, or
///   carries a raw control byte
pub inline fn stringSpan(comptime self: Self, cursor: *Cursor) Error!StringSpan {
    return switch (self.scan) {
        .SCALAR => cursor.stringSpan() catch |err| cursorError(err),
        .VECTOR => cursor_vector.stringSpan(cursor) catch |err| cursorVectorError(err),
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const LANES = @import("../lane.zig").LANES;

/// Both widths, so a case can check the pair agrees.
const SHAPES = [_]Self{
    .{ .scan = .SCALAR },
    .{ .scan = .VECTOR },
};

test "jzon deserialize: ScanShape, default width is SCALAR" {
    const shape: Self = .{};

    try std.testing.expectEqual(ScanPath.SCALAR, shape.scan);
}

test "jzon deserialize: ScanShape, ScanPath keeps its two names" {
    const names = @typeInfo(ScanPath).@"enum".field_names;

    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("SCALAR", names[0]);
    try std.testing.expectEqualStrings("VECTOR", names[1]);
}

test "jzon deserialize: ScanShape, both widths step over the same whitespace" {
    const documents = [_][]const u8{
        "",
        "x",
        "  x",
        "\t\n\r x",
        "                                   x",
    };

    for (documents) |document| {
        var reached: [SHAPES.len]usize = undefined;

        inline for (SHAPES, 0..) |shape, index| {
            var cursor: Cursor = .init(document);
            shape.skipSpace(&cursor);

            reached[index] = cursor.pos;
        }

        try std.testing.expectEqual(reached[0], reached[1]);
    }
}

test "jzon deserialize: ScanShape, both widths bound the same string token" {
    const documents = [_][]const u8{
        "\"\"",
        "\"plain\"",
        "\"a body that runs well past one whole lane of bytes\"",
        "\"with \\\" an escape in it\"",
    };

    for (documents) |document| {
        var raws: [SHAPES.len][]const u8 = undefined;
        var flags: [SHAPES.len]bool = undefined;

        inline for (SHAPES, 0..) |shape, index| {
            var cursor: Cursor = .init(document);
            const span = try shape.stringSpan(&cursor);

            raws[index] = span.raw;
            flags[index] = span.escaped;
        }

        try std.testing.expectEqualStrings(raws[0], raws[1]);
        try std.testing.expectEqual(flags[0], flags[1]);
    }
}

test "jzon deserialize: ScanShape, cursorError maps truncated" {
    const err = cursorError(error.Jzon_Cursor_Truncated);

    try std.testing.expectEqual(Error.Jzon_ScanShape_Truncated, err);
}

test "jzon deserialize: ScanShape, cursorError maps unexpected" {
    const err = cursorError(error.Jzon_Cursor_Unexpected);

    try std.testing.expectEqual(Error.Jzon_ScanShape_Unexpected, err);
}

test "jzon deserialize: ScanShape, cursorVectorError maps truncated" {
    const err = cursorVectorError(error.Jzon_CursorVector_Truncated);

    try std.testing.expectEqual(Error.Jzon_ScanShape_Truncated, err);
}

test "jzon deserialize: ScanShape, cursorVectorError maps unexpected" {
    const err = cursorVectorError(error.Jzon_CursorVector_Unexpected);

    try std.testing.expectEqual(Error.Jzon_ScanShape_Unexpected, err);
}

test "jzon deserialize: ScanShape, empty document is truncated at both widths" {
    inline for (SHAPES) |shape| {
        var cursor: Cursor = .init("");
        shape.skipSpace(&cursor);

        try std.testing.expect(cursor.atEnd());
        try std.testing.expectError(Error.Jzon_ScanShape_Truncated, shape.stringSpan(&cursor));
    }
}

test "jzon deserialize: ScanShape, whitespace-only document runs to its end" {
    for ([_]usize{ 1, LANES - 1, LANES, LANES + 1, LANES * 3 }) |len| {
        var document: [LANES * 3]u8 = @splat('\t');

        inline for (SHAPES) |shape| {
            var cursor: Cursor = .init(document[0..len]);
            shape.skipSpace(&cursor);

            try std.testing.expect(cursor.atEnd());
        }
    }
}

test "jzon deserialize: ScanShape, token ending on the last byte is read whole" {
    for ([_]usize{ 0, 1, LANES - 2, LANES - 1, LANES, LANES + 1 }) |body| {
        var document: [LANES * 2 + 2]u8 = @splat('x');
        document[0] = '"';
        document[body + 1] = '"';

        const src = document[0 .. body + 2];

        inline for (SHAPES) |shape| {
            var cursor: Cursor = .init(src);
            const span = try shape.stringSpan(&cursor);

            try std.testing.expectEqual(body, span.raw.len);
            try std.testing.expect(cursor.atEnd());
        }
    }
}

test "jzon deserialize: ScanShape, token opening on the last byte is truncated" {
    inline for (SHAPES) |shape| {
        var cursor: Cursor = .init("\"");

        try std.testing.expectError(Error.Jzon_ScanShape_Truncated, shape.stringSpan(&cursor));
    }
}

test "jzon deserialize: ScanShape, escape the document ends on is truncated" {
    // The backslash takes the byte after it, and there is no byte after it.
    const documents = [_][]const u8{
        "\"\\",
        "\"a body long enough to cross one whole lane boundary \\",
    };

    for (documents) |document| {
        inline for (SHAPES) |shape| {
            var cursor: Cursor = .init(document);

            try std.testing.expectError(
                Error.Jzon_ScanShape_Truncated,
                shape.stringSpan(&cursor),
            );
        }
    }
}

test "jzon deserialize: ScanShape, escaped quote stays inside the token" {
    const document = "\"a body with an escaped quote \\\" that does not end it here\"";

    inline for (SHAPES) |shape| {
        var cursor: Cursor = .init(document);
        const span = try shape.stringSpan(&cursor);

        try std.testing.expect(span.escaped);
        try std.testing.expectEqualStrings(document[1 .. document.len - 1], span.raw);
        try std.testing.expect(cursor.atEnd());
    }
}

