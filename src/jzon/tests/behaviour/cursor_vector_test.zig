//! JZON behaviour cursor_vector_test
//!
//! ### file: src/jzon/tests/behaviour/cursor_vector_test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The lane-at-a-time read scans land on the same byte and bound the same token
//! the byte-at-a-time `Cursor` scans do, across every lane boundary.
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
const cursor_vector = jzon.cursor_vector;

const LANES = jzon.lane.LANES;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Documents the cases below run over, each crossing the lane boundary
/// somewhere different.
const DOCUMENTS = [_][]const u8{
    "",
    "x",
    " x",
    "\t\n\r x",
    "                  x",
    "                                                     x",
    "\"\"",
    "\"short\"",
    "\"a body that runs well past one whole lane of bytes\"",
    "\"escape \\\" sitting in a lane that is otherwise clean\"",
    "\"a backslash \\\\ landing near a lane boundary here too\"",
    "\"\\n\\t\\r back to back with nothing plain between them\"",
};

/// Whether the byte scan and the lane scan failed for the same reason.
fn sameCondition(byte_err: Cursor.Error, lane_err: cursor_vector.Error) bool {
    return switch (byte_err) {
        error.Jzon_Cursor_Truncated => lane_err == error.Jzon_CursorVector_Truncated,
        error.Jzon_Cursor_Unexpected => lane_err == error.Jzon_CursorVector_Unexpected,
    };
}

test "jzon behaviour: cursor_vector, skips the same whitespace the byte scan skips" {
    for (DOCUMENTS) |document| {
        var ours: Cursor = .init(document);
        cursor_vector.skipSpace(&ours);

        var theirs: Cursor = .init(document);
        theirs.skipSpace();

        try std.testing.expectEqual(theirs.pos, ours.pos);
    }
}

test "jzon behaviour: cursor_vector, bounds the same string token the byte scan bounds" {
    for (DOCUMENTS) |document| {
        var ours: Cursor = .init(document);
        const our_result = cursor_vector.stringSpan(&ours);

        var theirs: Cursor = .init(document);
        const their_result = theirs.stringSpan();

        if (their_result) |wanted| {
            const got = try our_result;

            try std.testing.expectEqualStrings(wanted.raw, got.raw);
            try std.testing.expectEqual(wanted.escaped, got.escaped);
            try std.testing.expectEqual(theirs.pos, ours.pos);
        } else |their_err| {
            const our_err = if (our_result) |_| return error.TestExpectedError else |err| err;

            try std.testing.expect(sameCondition(their_err, our_err));
        }
    }
}

test "jzon behaviour: cursor_vector, steps over whitespace runs of every length" {
    for (0..LANES * 3) |run| {
        var document: [LANES * 3 + 1]u8 = @splat(' ');
        document[run] = 'v';

        var cursor: Cursor = .init(document[0 .. run + 1]);
        cursor_vector.skipSpace(&cursor);

        try std.testing.expectEqual(run, cursor.pos);
    }
}

test "jzon behaviour: cursor_vector, reads a string body of every length" {
    for (0..LANES * 2) |body| {
        var document: [LANES * 2 + 2]u8 = @splat('x');
        document[0] = '"';
        document[body + 1] = '"';

        var cursor: Cursor = .init(document[0 .. body + 2]);

        const span = try cursor_vector.stringSpan(&cursor);

        try std.testing.expectEqual(body, span.raw.len);
        try std.testing.expect(!span.escaped);
        try std.testing.expect(cursor.atEnd());
    }
}

test "jzon behaviour: cursor_vector, leaves what follows the token unread" {
    var cursor: Cursor = .init("   \n  \"a body long enough to fill one whole lane\" , rest");

    cursor_vector.skipSpace(&cursor);

    const span = try cursor_vector.stringSpan(&cursor);

    try std.testing.expectEqualStrings("a body long enough to fill one whole lane", span.raw);
    try std.testing.expectEqualStrings(" , rest", cursor.src[cursor.pos..]);
}

test "jzon behaviour: cursor_vector, reports a string that carries an escape" {
    var plain: Cursor = .init("\"a plain body with no escape in it at all, quite long\"");
    const plain_span = try cursor_vector.stringSpan(&plain);

    var escaped: Cursor = .init("\"a body with one \\t escape in it, also quite long here\"");
    const escaped_span = try cursor_vector.stringSpan(&escaped);

    try std.testing.expect(!plain_span.escaped);
    try std.testing.expect(escaped_span.escaped);
}

