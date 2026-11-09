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

/// Bytes of a whitespace run stepped one at a time before the lane loop takes over.
///
/// Note:
/// - Covers the common gaps laid-out JSON puts between tokens: one space after `:` or
///   `,`, or a newline plus a short indent. Measured over 2, 3, 4, and 8: 4 keeps most
///   of the laid-out gain without slowing long runs.
const SHORT_RUN = 4;

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

/// Step over a whitespace run longer than SHORT_RUN, a lane at a time.
///
/// Note:
/// - A lane of whitespace advances the cursor by the whole lane. The first lane that
///   holds anything else lands the cursor exactly on it. A tail shorter than a lane
///   is finished by the scalar skip.
///
/// Param:
/// cursor - *Cursor (the cursor to advance, sitting inside a whitespace run)
///
/// Return:
/// - void
inline fn skipLongRun(cursor: *Cursor) void {
    const src = cursor.src;
    var pos = cursor.pos;

    while (pos + LANES <= src.len) {
        const chunk: Chunk = src[pos..][0..LANES].*;

        if (firstOther(chunk)) |offset| {
            cursor.pos = pos + offset;

            return;
        }

        pos += LANES;
    }

    cursor.pos = pos;
    cursor.skipSpace();
}

/// Every failure the private scan can hand back: this module's own set joined with
/// the scalar cursor's.
const Inner = Error || Cursor.Error;

/// Translate a failure from the private scan into this module's public set.
///
/// Param:
/// err - Inner (the failure the scan handed back)
///
/// Return:
/// - Error (the same failure under this module's name)
inline fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Jzon_CursorVector_Truncated => Error.Jzon_CursorVector_Truncated,
        error.Jzon_CursorVector_Unexpected => Error.Jzon_CursorVector_Unexpected,
        error.Jzon_Cursor_Truncated => Error.Jzon_CursorVector_Truncated,
        error.Jzon_Cursor_Unexpected => Error.Jzon_CursorVector_Unexpected,
    };
}

/// The body of `stringSpan`, failing with the scalar cursor's set.
///
/// Note:
/// - Scans on local copies of `src` and `pos` and writes the position back once.
///   Through the pointer, the compiler has to assume a byte read may change the
///   position and reloads it on every step (measured).
/// - A failure goes through `Cursor.stopAt`, so both widths note the same stop byte.
///
/// Param:
/// cursor - *Cursor (positioned at the opening quote)
///
/// Return:
/// - StringSpan (the undecoded body, plus whether it holds an escape)
/// - Inner (a scalar cursor failure, untranslated)
fn spanInto(cursor: *Cursor) Inner!StringSpan {
    try cursor.expect('"');

    const src = cursor.src;
    const start = cursor.pos;
    var pos = start;
    var escaped = false;

    while (true) {
        if (pos + LANES <= src.len) {
            const chunk: Chunk = src[pos..][0..LANES].*;

            if (lane.firstEscaped(chunk)) |offset| {
                pos += offset;
            } else {
                pos += LANES;

                continue;
            }
        }

        if (pos == src.len) {
            cursor.pos = pos;

            return cursor.stopAt(Cursor.Error.Jzon_Cursor_Truncated);
        }

        const byte = src[pos];

        if (byte == '"') {
            cursor.pos = pos + 1;

            return .{
                .raw = src[start..pos],
                .escaped = escaped,
            };
        }

        if (byte < 0x20) {
            cursor.pos = pos;

            return cursor.stopAt(Cursor.Error.Jzon_Cursor_Unexpected);
        }

        if (byte == '\\') {
            if (pos + 1 == src.len) {
                cursor.pos = pos;

                return cursor.stopAt(Cursor.Error.Jzon_Cursor_Truncated);
            }

            escaped = true;
            pos += 2;

            continue;
        }

        pos += 1;
    }
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
/// - The first byte is checked on its own and, when it is not whitespace, the cursor
///   is left untouched. A minified document always takes this exit, and returning
///   before the run setup is what keeps it at the scalar speed (measured).
/// - The rest of the first SHORT_RUN bytes are stepped one at a time. A laid-out
///   document almost always stops inside the run, so it never loads a lane.
/// - A run longer than SHORT_RUN goes to `skipLongRun`, a lane at a time.
///
/// Param:
/// cursor - *Cursor (the cursor to advance)
///
/// Return:
/// - void
pub fn skipSpace(cursor: *Cursor) void {
    const src = cursor.src;
    var pos = cursor.pos;

    if (pos >= src.len or !Cursor.isSpace(src[pos])) return;

    const stop = @min(pos + SHORT_RUN, src.len);

    pos += 1;
    while (pos < stop and Cursor.isSpace(src[pos])) pos += 1;

    cursor.pos = pos;

    if (pos < stop or pos == src.len) return;

    skipLongRun(cursor);
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
    return spanInto(cursor) catch |err| innerError(err);
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

/// Skip whitespace in `src` with both widths and require the same position.
fn expectSameSkip(src: []const u8) !void {
    var ours: Cursor = .init(src);
    skipSpace(&ours);

    var theirs: Cursor = .init(src);
    theirs.skipSpace();

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

test "jzon: cursor_vector, skipSpace agrees with the scalar skip at every run length" {
    // Each run is tried three ways: ending on a token with less than a lane after it,
    // ending on a token with more than a lane after it, and ending the document.
    for (0..LANES * 3) |run| {
        var document: [LANES * 5]u8 = @splat('x');
        @memset(document[0..run], ' ');

        try expectSameSkip(document[0 .. run + 1]);
        try expectSameSkip(document[0 .. run + 1 + LANES]);
        try expectSameSkip(document[0..run]);
    }
}

test "jzon: cursor_vector, skipSpace on a run of exactly SHORT_RUN lands on the token" {
    var document: [SHORT_RUN + LANES]u8 = @splat('x');
    @memset(document[0..SHORT_RUN], '\n');

    var cursor: Cursor = .init(&document);
    skipSpace(&cursor);

    try std.testing.expectEqual(@as(usize, SHORT_RUN), cursor.pos);
}

test "jzon: cursor_vector, skipSpace on a run one past SHORT_RUN lands on the token" {
    var document: [SHORT_RUN + 1 + LANES]u8 = @splat('x');
    @memset(document[0 .. SHORT_RUN + 1], '\t');

    var cursor: Cursor = .init(&document);
    skipSpace(&cursor);

    try std.testing.expectEqual(@as(usize, SHORT_RUN + 1), cursor.pos);
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
            try std.testing.expectError(innerError(failure), our_span);
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

test "jzon: cursor_vector, skipSpace on an empty document stays at the start" {
    var cursor: Cursor = .init("");

    skipSpace(&cursor);

    try std.testing.expectEqual(@as(usize, 0), cursor.pos);
}

test "jzon: cursor_vector, skipSpace on a token leaves the cursor in place" {
    var cursor: Cursor = .init("{\"id\": 1}");
    cursor.pos = 2;

    skipSpace(&cursor);

    try std.testing.expectEqual(@as(usize, 2), cursor.pos);
}

test "jzon: cursor_vector, skipSpace on a cursor already at the end stays there" {
    var cursor: Cursor = .init("1 ");
    cursor.pos = 2;

    skipSpace(&cursor);

    try std.testing.expectEqual(@as(usize, 2), cursor.pos);
}

test "jzon: cursor_vector, skipSpace on a run of one lands on the token" {
    var cursor: Cursor = .init(" x");

    skipSpace(&cursor);

    try std.testing.expectEqual(@as(usize, 1), cursor.pos);
}

test "jzon: cursor_vector, innerError keeps its own truncated" {
    const err = innerError(error.Jzon_CursorVector_Truncated);

    try std.testing.expectEqual(Error.Jzon_CursorVector_Truncated, err);
}

test "jzon: cursor_vector, innerError keeps its own unexpected" {
    const err = innerError(error.Jzon_CursorVector_Unexpected);

    try std.testing.expectEqual(Error.Jzon_CursorVector_Unexpected, err);
}

test "jzon: cursor_vector, innerError renames cursor truncated to its own name" {
    const err = innerError(error.Jzon_Cursor_Truncated);

    try std.testing.expectEqual(Error.Jzon_CursorVector_Truncated, err);
}

test "jzon: cursor_vector, innerError renames cursor unexpected to its own name" {
    const err = innerError(error.Jzon_Cursor_Unexpected);

    try std.testing.expectEqual(Error.Jzon_CursorVector_Unexpected, err);
}

