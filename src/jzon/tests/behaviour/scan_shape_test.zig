//! JZON behaviour scan_shape_test
//!
//! ### file: src/jzon/tests/behaviour/scan_shape_test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Both read scan widths leave the cursor on the same byte, bound the same string
//! token, and fail for the same reason.
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

const Cursor = jzon.Cursor;
const ScanShape = jzon.ScanShape;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Both widths, so every case asserts the pair agrees.
const SHAPES = [_]ScanShape{
    .{ .scan = .SCALAR },
    .{ .scan = .VECTOR },
};

/// One document and the failure both widths must report on it.
const FailureCase = struct {
    document: []const u8,
    failure: ScanShape.Error,
};

test "jzon behaviour: ScanShape, width defaults to the byte at a time one" {
    const shape: ScanShape = .{};

    try std.testing.expectEqual(ScanShape.ScanPath.SCALAR, shape.scan);
}

test "jzon behaviour: ScanShape, both widths leave the cursor on the same byte" {
    const documents = [_][]const u8{
        "",
        "x",
        "   x",
        "\t\n\r\t x",
        "                                            x",
        "                                             ",
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

test "jzon behaviour: ScanShape, both widths bound the same string token" {
    const documents = [_][]const u8{
        "\"\"",
        "\"plain\"",
        "\"a body that runs well past one whole lane of bytes\"",
        "\"with \\\" an escape in it\"",
        "\"\\u00e9\"",
    };

    for (documents) |document| {
        var raws: [SHAPES.len][]const u8 = undefined;
        var flags: [SHAPES.len]bool = undefined;
        var reached: [SHAPES.len]usize = undefined;

        inline for (SHAPES, 0..) |shape, index| {
            var cursor: Cursor = .init(document);
            const span = try shape.stringSpan(&cursor);

            raws[index] = span.raw;
            flags[index] = span.escaped;
            reached[index] = cursor.pos;
        }

        try std.testing.expectEqualStrings(raws[0], raws[1]);
        try std.testing.expectEqual(flags[0], flags[1]);
        try std.testing.expectEqual(reached[0], reached[1]);
    }
}

test "jzon behaviour: ScanShape, both widths report the same failure" {
    const cases = [_]FailureCase{
        .{
            .document = "",
            .failure = ScanShape.Error.Jzon_ScanShape_Truncated,
        },
        .{
            .document = "\"never closed",
            .failure = ScanShape.Error.Jzon_ScanShape_Truncated,
        },
        .{
            .document = "not a string",
            .failure = ScanShape.Error.Jzon_ScanShape_Unexpected,
        },
        .{
            .document = "\"a raw \x01 control byte\"",
            .failure = ScanShape.Error.Jzon_ScanShape_Unexpected,
        },
    };

    for (cases) |case| {
        inline for (SHAPES) |shape| {
            var cursor: Cursor = .init(case.document);

            try std.testing.expectError(case.failure, shape.stringSpan(&cursor));
        }
    }
}

test "jzon behaviour: ScanShape, one walk over a document ends on the same byte at both widths" {
    const document = "  { \"key\" : \"a value long enough to fill one whole lane\" }  ";

    var reached: [SHAPES.len]usize = undefined;

    inline for (SHAPES, 0..) |shape, index| {
        var cursor: Cursor = .init(document);

        shape.skipSpace(&cursor);
        try cursor.expect('{');

        shape.skipSpace(&cursor);
        const key = try shape.stringSpan(&cursor);
        try std.testing.expectEqualStrings("key", key.raw);

        shape.skipSpace(&cursor);
        try cursor.expect(':');

        shape.skipSpace(&cursor);
        _ = try shape.stringSpan(&cursor);

        shape.skipSpace(&cursor);
        try cursor.expect('}');

        shape.skipSpace(&cursor);
        reached[index] = cursor.pos;
    }

    try std.testing.expectEqual(document.len, reached[0]);
    try std.testing.expectEqual(reached[0], reached[1]);
}

