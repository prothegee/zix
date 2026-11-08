//! JZON cursor_vector
//!
//! ### file: src/jzon/src/cursor_vector.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The two scans a parse repeats most, a vector lane at a time: stepping over the
//! whitespace between tokens, and finding where a string token ends.
//!
//! ### note:
//!
//! `Cursor` still owns the position, the bounds, and the stop record. Both widths leave
//! the cursor in the same place, with the same failure and the same stop byte. The lane
//! setup only pays on laid-out documents and long strings, which is why the width is a
//! call-site choice.
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
const Cursor = @import("Cursor.zig");
const lane = @import("lane.zig");
const StringSpan = @import("StringSpan.zig");

const Chunk = lane.Chunk;
const LANES = lane.LANES;

// --------------------------------------------------------- //
// Private:

/// Where the first byte that is not whitespace sits inside one lane.
///
/// Note:
/// - The comparisons are built from `Cursor.WHITESPACE`, so the set is the one the
///   scalar rule answers for and the two cannot drift apart.
///
/// Param:
/// chunk - Chunk (one lane of the document)
///
/// Return:
/// - usize (the offset inside the lane of the first byte to stop on)
/// - null when the whole lane is whitespace
inline fn firstOther(chunk: Chunk) ?usize {
    var spaces: @Vector(LANES, bool) = @splat(false);

    inline for (Cursor.WHITESPACE) |allowed| {
        const wanted: Chunk = @splat(allowed);
        spaces = spaces | (chunk == wanted);
    }

    // The lane index comes back at its own narrow width, which the caller wants as an
    // offset it can add to a position.
    const offset = std.simd.firstTrue(~spaces) orelse return null;

    return offset;
}

/// Translate a `Cursor` failure into this module's set.
///
/// Param:
/// err - Cursor.Error (the failure the scalar cursor reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn cursorError(err: Cursor.Error) Error {
    return switch (err) {
        error.Jzon_Cursor_Truncated => Error.Jzon_CursorVector_Truncated,
        error.Jzon_Cursor_Unexpected => Error.Jzon_CursorVector_Unexpected,
    };
}

/// Record the stop byte through `Cursor.stopAt`, then return the failure under this
/// module's name.
///
/// Note:
/// - The stop record stays in one place (`Cursor.stopAt`), so both widths note the
///   same byte the same way.
///
/// Param:
/// cursor - *const Cursor (the cursor that stopped)
/// err - Cursor.Error (the failure, in the scalar cursor's set)
///
/// Return:
/// - Error (the same failure under this module's name)
fn recordStop(cursor: *const Cursor, err: Cursor.Error) Error {
    return cursorError(cursor.stopAt(err));
}

// --------------------------------------------------------- //
// Public:

/// How a read can fail.
///
/// Note:
/// - Truncated means the document ended early. Unexpected means the byte that is
///   there cannot start what was asked for. Same meaning as `Cursor.Error`, under this
///   module's own name.
pub const Error = error{
    Jzon_CursorVector_Truncated,
    Jzon_CursorVector_Unexpected,
};

/// Step over the insignificant whitespace between tokens.
///
/// Note:
/// - The byte under the cursor is asked first, before any lane is loaded. A minified
///   document answers there and never reaches the lane loop.
/// - A lane of whitespace advances the cursor by the whole lane. The first lane that
///   holds anything else lands the cursor exactly on it.
///
/// Param:
/// cursor - *Cursor (the cursor to advance)
///
/// Return:
/// - void
pub fn skipSpace(cursor: *Cursor) void {
    if (cursor.pos == cursor.src.len or !Cursor.isSpace(cursor.src[cursor.pos])) return;

    while (cursor.pos + LANES <= cursor.src.len) {
        const chunk: Chunk = cursor.src[cursor.pos..][0..LANES].*;

        if (firstOther(chunk)) |offset| {
            cursor.pos += offset;

            return;
        }

        cursor.pos += LANES;
    }

    cursor.skipSpace();
}

/// Read a string token, both quotes included, and return the bytes between them
/// undecoded.
///
/// Note:
/// - A lane with nothing of interest advances the cursor whole. Otherwise the cursor
///   lands on the first byte that matters and that one byte is read, which lets a
///   backslash take the byte after it even when the two sit in different lanes.
/// - The result is what `Cursor.stringSpan` returns for the same document, failures
///   and their stop byte included.
///
/// Param:
/// cursor - *Cursor (positioned at the opening quote)
///
/// Return:
/// - StringSpan (the undecoded body, plus whether it holds an escape)
/// - Error.Jzon_CursorVector_Truncated when the closing quote never arrives
/// - Error.Jzon_CursorVector_Unexpected when the token does not open with a quote, or
///   carries a raw control byte
pub fn stringSpan(cursor: *Cursor) Error!StringSpan {
    cursor.expect('"') catch |err| return cursorError(err);

    const start = cursor.pos;
    var escaped = false;

    while (true) {
        if (cursor.pos + LANES <= cursor.src.len) {
            const chunk: Chunk = cursor.src[cursor.pos..][0..LANES].*;

            if (lane.firstEscaped(chunk)) |offset| {
                cursor.pos += offset;
            } else {
                cursor.pos += LANES;

                continue;
            }
        }

        if (cursor.pos == cursor.src.len) {
            return recordStop(cursor, Cursor.Error.Jzon_Cursor_Truncated);
        }

        const byte = cursor.src[cursor.pos];

        if (byte == '"') {
            const raw = cursor.src[start..cursor.pos];
            cursor.pos += 1;

            return .{
                .raw = raw,
                .escaped = escaped,
            };
        }

        if (byte < 0x20) return recordStop(cursor, Cursor.Error.Jzon_Cursor_Unexpected);

        if (byte == '\\') {
            if (cursor.pos + 1 == cursor.src.len) {
                return recordStop(cursor, Cursor.Error.Jzon_Cursor_Truncated);
            }

            escaped = true;
            cursor.pos += 2;

            continue;
        }

        cursor.pos += 1;
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const Failure = @import("deserialize/Failure.zig");

/// Every document the cases below run over, chosen so each one crosses the lane
/// boundary somewhere different.
const DOCUMENTS = [_][]const u8{
    "",
    " ",
    "   \t\n\r  x",
    "                                   deep past two whole lanes",
    "\"\"",
    "\"short\"",
    "\"a string body that runs well past one whole lane of bytes\"",
    "\"escape \\\" in a lane that is otherwise clean and rather long\"",
    "\"a lane boundary landing right on an escape \\\\ here\"",
    "\"\\u00e9\\ud83d\\udca9 back to back escapes with nothing plain between\"",
};

/// Documents both widths must refuse, with the stop byte each one records.
const FAILING_DOCUMENTS = [_][]const u8{
    "\"a body long enough to fill a whole lane but never closed",
    "\"a body long enough to fill a whole lane ending on \\",
    "\"a body long enough to fill a whole lane\x01 and then some\"",
    "\"a\x01b\"",
    "\"open",
};

/// Read `src` with both widths and require the same span and the same position.
fn expectSameSpan(src: []const u8) !void {
    var ours: Cursor = .init(src);
    const got = try stringSpan(&ours);

    var theirs: Cursor = .init(src);
    const wanted = try theirs.stringSpan();

    try std.testing.expectEqualStrings(wanted.raw, got.raw);
    try std.testing.expectEqual(wanted.escaped, got.escaped);
    try std.testing.expectEqual(theirs.pos, ours.pos);
}

test "jzon: cursor_vector, skipSpace stops where the scalar skip stops" {
    for (DOCUMENTS) |document| {
        var ours: Cursor = .init(document);
        skipSpace(&ours);

        var theirs: Cursor = .init(document);
        theirs.skipSpace();

        try std.testing.expectEqual(theirs.pos, ours.pos);
    }
}

test "jzon: cursor_vector, skipSpace steps over runs longer than one lane" {
    // Two whole lanes of whitespace and one byte more, so the lane loop runs twice and
    // the scalar tail finishes the job.
    var document: [LANES * 2 + 1 + 3]u8 = @splat(' ');
    document[LANES * 2 + 1] = 'a';

    var cursor: Cursor = .init(&document);
    skipSpace(&cursor);

    try std.testing.expectEqual(@as(usize, LANES * 2 + 1), cursor.pos);
}

test "jzon: cursor_vector, stringSpan reads what the scalar span reads" {
    for (DOCUMENTS) |document| {
        var ours: Cursor = .init(document);
        const our_span = stringSpan(&ours);

        var theirs: Cursor = .init(document);
        const their_span = theirs.stringSpan();

        if (their_span) |wanted| {
            const got = try our_span;

            try std.testing.expectEqualStrings(wanted.raw, got.raw);
            try std.testing.expectEqual(wanted.escaped, got.escaped);
            try std.testing.expectEqual(theirs.pos, ours.pos);
        } else |failure| {
            try std.testing.expectError(cursorError(failure), our_span);
        }
    }
}

test "jzon: cursor_vector, stringSpan agrees with the scalar span at every position" {
    // One escape walked through every position of a body long enough to cross two lane
    // boundaries, so the hit lands in a leading lane, a trailing lane, and the scalar
    // tail in turn.
    var document: [40]u8 = undefined;

    for (1..document.len - 3) |offset| {
        @memset(&document, 'x');
        document[0] = '"';
        document[offset] = '\\';
        document[offset + 1] = 't';
        document[document.len - 1] = '"';

        try expectSameSpan(&document);
    }
}

test "jzon: cursor_vector, stringSpan leaves the bytes after the token unread" {
    var cursor: Cursor = .init("\"a body long enough to fill a whole lane and more\",rest");

    const span = try stringSpan(&cursor);

    try std.testing.expect(!span.escaped);
    try std.testing.expectEqualStrings(",rest", cursor.src[cursor.pos..]);
}

test "jzon: cursor_vector, stringSpan reads a quote that lands on a lane boundary" {
    // The opening quote takes one byte, so a body of LANES - 1 puts the closing quote
    // at the last byte of the first lane, and a body of LANES puts it at the first
    // byte of the second.
    for ([_]usize{ LANES - 2, LANES - 1, LANES, LANES + 1 }) |body| {
        var document: [LANES * 2 + 2]u8 = @splat('x');
        document[0] = '"';
        document[body + 1] = '"';

        try expectSameSpan(document[0 .. body + 2]);
    }
}

test "jzon: cursor_vector, stringSpan reads an escape split across a lane boundary" {
    // Walk a two-byte escape through every position, so its backslash sits in one
    // lane and its spelling in the next.
    for (1..LANES * 2) |offset| {
        var document: [LANES * 2 + 4]u8 = @splat('x');
        document[0] = '"';
        document[offset] = '\\';
        document[offset + 1] = 't';
        document[document.len - 1] = '"';

        try expectSameSpan(&document);
    }
}

test "jzon: cursor_vector, stringSpan on a token the document ends inside is truncated" {
    var unterminated: Cursor = .init(FAILING_DOCUMENTS[0]);
    try std.testing.expectError(Error.Jzon_CursorVector_Truncated, stringSpan(&unterminated));

    var trailing_backslash: Cursor = .init(FAILING_DOCUMENTS[1]);
    try std.testing.expectError(
        Error.Jzon_CursorVector_Truncated,
        stringSpan(&trailing_backslash),
    );

    var empty: Cursor = .init("");
    try std.testing.expectError(Error.Jzon_CursorVector_Truncated, stringSpan(&empty));
}

test "jzon: cursor_vector, stringSpan with a raw control byte is unexpected" {
    var short: Cursor = .init(FAILING_DOCUMENTS[3]);
    try std.testing.expectError(Error.Jzon_CursorVector_Unexpected, stringSpan(&short));

    // Past the first lane, so the byte is found by the lane scan, not by the tail.
    var long: Cursor = .init(FAILING_DOCUMENTS[2]);
    try std.testing.expectError(Error.Jzon_CursorVector_Unexpected, stringSpan(&long));
}

test "jzon: cursor_vector, stringSpan on a token without a quote is unexpected" {
    var cursor: Cursor = .init("not a string at all, though long enough for a lane");

    try std.testing.expectError(Error.Jzon_CursorVector_Unexpected, stringSpan(&cursor));
    try std.testing.expectEqual(@as(usize, 0), cursor.pos);
}

test "jzon: cursor_vector, stringSpan failure notes the same stop byte as the scalar" {
    for (FAILING_DOCUMENTS) |document| {
        Failure.reset();
        var theirs: Cursor = .init(document);
        try std.testing.expect(std.meta.isError(theirs.stringSpan()));
        const wanted = Failure.lastFailure();

        Failure.reset();
        var ours: Cursor = .init(document);
        try std.testing.expect(std.meta.isError(stringSpan(&ours)));
        const got = Failure.lastFailure();

        try std.testing.expect(got.filled);
        try std.testing.expectEqual(wanted.offset, got.offset);
    }
}

test "jzon: cursor_vector, skipSpace on a document shorter than a lane lands on the token" {
    var cursor: Cursor = .init("  x");

    skipSpace(&cursor);

    try std.testing.expectEqual(@as(usize, 2), cursor.pos);
}

test "jzon: cursor_vector, skipSpace on short whitespace lands at the end" {
    var cursor: Cursor = .init("   ");

    skipSpace(&cursor);

    try std.testing.expect(cursor.atEnd());
}

test "jzon: cursor_vector, skipSpace on a document of whitespace to its end lands at the end" {
    var document: [LANES * 3]u8 = @splat('\n');
    var cursor: Cursor = .init(&document);

    skipSpace(&cursor);

    try std.testing.expect(cursor.atEnd());
}

test "jzon: cursor_vector, skipSpace stops on a control byte outside the whitespace set" {
    // 0x0b and 0x0c are control bytes that JSON does not count as whitespace, so the
    // skip leaves them for the token that follows to report.
    for ([_]u8{ 0x00, 0x0b, 0x0c, 0x1f }) |byte| {
        var document: [LANES + 2]u8 = @splat(' ');
        document[LANES + 1] = byte;

        var cursor: Cursor = .init(&document);
        skipSpace(&cursor);

        try std.testing.expectEqual(@as(usize, LANES + 1), cursor.pos);
    }
}

test "jzon: cursor_vector, cursorError renames truncated to its own name" {
    const err = cursorError(error.Jzon_Cursor_Truncated);

    try std.testing.expectEqual(Error.Jzon_CursorVector_Truncated, err);
}

test "jzon: cursor_vector, cursorError renames unexpected to its own name" {
    const err = cursorError(error.Jzon_Cursor_Unexpected);

    try std.testing.expectEqual(Error.Jzon_CursorVector_Unexpected, err);
}

test "jzon: cursor_vector, recordStop notes the cursor position" {
    var cursor: Cursor = .init("abcdef");
    cursor.pos = 4;
    Failure.reset();

    const err = recordStop(&cursor, error.Jzon_Cursor_Unexpected);
    const failure = Failure.lastFailure();

    try std.testing.expectEqual(Error.Jzon_CursorVector_Unexpected, err);
    try std.testing.expect(failure.filled);
    try std.testing.expectEqual(@as(usize, 4), failure.offset);
}

