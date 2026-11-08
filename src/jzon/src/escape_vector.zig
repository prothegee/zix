//! JZON escape_vector
//!
//! ### file: src/jzon/src/escape_vector.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! JSON string escape writing, scanned a vector lane at a time. Same output as
//! `escape.encodeBody`, byte for byte.
//!
//! ### note:
//!
//! This pays on long strings and costs on short ones. A string shorter than one lane
//! never enters the vector loop, and one just over a lane pays the vector setup for a
//! single comparison. Pick it for text, not for identifiers.
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
const escape = @import("escape.zig");
const lane = @import("lane.zig");
const Sink = @import("Sink.zig");

const Chunk = lane.Chunk;
const LANES = lane.LANES;

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
        error.Jzon_Sink_NoSpaceLeft => Error.Jzon_EscapeVector_NoSpaceLeft,
    };
}

/// Translate an `escape` failure into this module's set.
///
/// Note:
/// - Only `escape.spell` is called from here, and it only writes, so BadEscape is not
///   expected. It still maps to a real member, so a change in `escape` shows up as an
///   error, not as undefined behaviour.
///
/// Param:
/// err - escape.Error (the failure the scalar escape reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn escapeError(err: escape.Error) Error {
    return switch (err) {
        error.Jzon_Escape_NoSpaceLeft => Error.Jzon_EscapeVector_NoSpaceLeft,
        error.Jzon_Escape_BadEscape => Error.Jzon_EscapeVector_BadEscape,
    };
}

/// Whether any byte in one lane has to be escaped.
///
/// Param:
/// chunk - Chunk (one lane of text)
///
/// Return:
/// - bool (true when the lane holds at least one byte to escape)
inline fn anyEscaped(chunk: Chunk) bool {
    return lane.firstEscaped(chunk) != null;
}

// --------------------------------------------------------- //
// Public:

/// How escaping can fail: no room for the escaped bytes, or an escape the rules do
/// not spell.
///
/// Note:
/// - Encoding never reports BadEscape in practice. It is here so the translation from
///   `escape.Error` covers every member.
pub const Error = error{
    Jzon_EscapeVector_NoSpaceLeft,
    Jzon_EscapeVector_BadEscape,
};

/// Write `text` as a complete JSON string, quotes included.
///
/// Param:
/// sink - *Sink (where the string goes)
/// text - []const u8 (the bytes to escape and write)
///
/// Return:
/// - void
/// - Error.Jzon_EscapeVector_NoSpaceLeft when the escaped form does not fit
pub fn encode(sink: *Sink, text: []const u8) Error!void {
    sink.byte('"') catch |err| return sinkError(err);
    try encodeBody(sink, text);
    sink.byte('"') catch |err| return sinkError(err);
}

/// Write `text` escaped, without the surrounding quotes.
///
/// Note:
/// - A clean lane advances the scan and writes nothing. The run of clean bytes is
///   only copied when an escape interrupts it or the text ends, so a string with no
///   escape costs one copy however long it is.
///
/// Param:
/// sink - *Sink (where the bytes go)
/// text - []const u8 (the bytes to escape and write)
///
/// Return:
/// - void
/// - Error.Jzon_EscapeVector_NoSpaceLeft when the escaped form does not fit
pub fn encodeBody(sink: *Sink, text: []const u8) Error!void {
    var clean_from: usize = 0;
    var index: usize = 0;

    while (index + LANES <= text.len) : (index += LANES) {
        const chunk: Chunk = text[index..][0..LANES].*;
        if (!anyEscaped(chunk)) continue;

        var offset = index;
        while (offset < index + LANES) : (offset += 1) {
            const byte = text[offset];
            if (!escape.isEscaped(byte)) continue;

            sink.bytes(text[clean_from..offset]) catch |err| return sinkError(err);
            escape.spell(sink, byte) catch |err| return escapeError(err);

            clean_from = offset + 1;
        }
    }

    while (index < text.len) : (index += 1) {
        const byte = text[index];
        if (!escape.isEscaped(byte)) continue;

        sink.bytes(text[clean_from..index]) catch |err| return sinkError(err);
        escape.spell(sink, byte) catch |err| return escapeError(err);

        clean_from = index + 1;
    }

    sink.bytes(text[clean_from..]) catch |err| return sinkError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Every sample the cases below run over, chosen so each one crosses the lane
/// boundary somewhere different.
const SAMPLES = [_][]const u8{
    "",
    "short",
    "exactly sixteen!",
    "a string that runs well past one whole lane of bytes",
    "\"",
    "escape \" at the head of a lane that is otherwise clean",
    "a lane ending on an escape \\",
    "control \x00 in the middle of a long enough run to vectorize",
    "\n\r\t\x08\x0c back to back with nothing clean between them at all",
    "utf8 \xc3\xa9 \xe2\x82\xac \xf0\x9f\x92\xa9 past a lane boundary for sure",
};

/// Encode `text` with both widths and require the same bytes.
fn expectSameBody(text: []const u8) !void {
    var vector_buf: [1024]u8 = undefined;
    var vector_sink: Sink = .init(&vector_buf);
    try encodeBody(&vector_sink, text);

    var scalar_buf: [1024]u8 = undefined;
    var scalar_sink: Sink = .init(&scalar_buf);
    try escape.encodeBody(&scalar_sink, text);

    try std.testing.expectEqualStrings(scalar_sink.filled(), vector_sink.filled());
}

test "jzon: escape_vector, encode writes what the scalar encode writes" {
    for (SAMPLES) |sample| {
        var vector_buf: [512]u8 = undefined;
        var vector_sink: Sink = .init(&vector_buf);
        try encode(&vector_sink, sample);

        var scalar_buf: [512]u8 = undefined;
        var scalar_sink: Sink = .init(&scalar_buf);
        try escape.encode(&scalar_sink, sample);

        try std.testing.expectEqualStrings(scalar_sink.filled(), vector_sink.filled());
    }
}

test "jzon: escape_vector, encodeBody matches the scalar body on every sample" {
    for (SAMPLES) |sample| {
        try expectSameBody(sample);
    }
}

test "jzon: escape_vector, encodeBody matches with a newline at every position" {
    // One escape walked through every position of a string long enough to cross two
    // lane boundaries, so the hit lands in a leading lane, a trailing lane, and the
    // scalar remainder in turn.
    var text: [40]u8 = undefined;

    for (0..text.len) |offset| {
        @memset(&text, 'x');
        text[offset] = '\n';

        try expectSameBody(&text);
    }
}

test "jzon: escape_vector, encode into a small buffer is no space left" {
    var buf: [4]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(
        Error.Jzon_EscapeVector_NoSpaceLeft,
        encode(&sink, "a string far longer than four bytes"),
    );
}

test "jzon: escape_vector, encodeBody matches at every length up to three lanes" {
    var text: [LANES * 3]u8 = undefined;
    @memset(&text, 'x');

    for (0..text.len + 1) |len| {
        try expectSameBody(text[0..len]);
    }
}

test "jzon: escape_vector, encodeBody matches with a quote at every position" {
    var text: [LANES * 3]u8 = undefined;

    for (0..text.len) |offset| {
        @memset(&text, 'x');
        text[offset] = '"';

        try expectSameBody(&text);
    }
}

test "jzon: escape_vector, encodeBody matches on a string of nothing but escapes" {
    var text: [LANES * 2]u8 = undefined;

    for (&text, 0..) |*byte, index| {
        byte.* = @intCast(index % 0x20);
    }

    try expectSameBody(&text);
}

test "jzon: escape_vector, encodeBody matches over every single byte" {
    for (0..256) |value| {
        const text = [_]u8{@intCast(value)};

        try expectSameBody(&text);
    }
}

test "jzon: escape_vector, leaves every byte from 0x20 raw except quote and backslash" {
    // 0x20 through 0x5f, the run that holds both bytes above 0x1f that still have to
    // be escaped.
    var text: [LANES * 4]u8 = undefined;

    for (&text, 0..) |*byte, index| {
        byte.* = @intCast(0x20 + index);
    }

    var buf: [512]u8 = undefined;
    var sink: Sink = .init(&buf);
    try encodeBody(&sink, &text);

    // Only the quote and the backslash are in this run, and each costs one extra
    // byte, so the body is two longer than the input.
    try std.testing.expectEqual(text.len + 2, sink.written());
}

test "jzon: escape_vector, encode on an empty string writes only the quotes" {
    var buf: [8]u8 = undefined;
    var sink: Sink = .init(&buf);

    try encode(&sink, "");

    try std.testing.expectEqualStrings("\"\"", sink.filled());
}

test "jzon: escape_vector, encode fills an exact-fit buffer" {
    // "a\nbcde" is nine bytes once escaped and quoted.
    var buf: [9]u8 = undefined;
    var sink: Sink = .init(&buf);

    try encode(&sink, "a\nbcde");

    try std.testing.expectEqualStrings("\"a\\nbcde\"", sink.filled());
    try std.testing.expectEqual(@as(usize, 0), sink.remaining());
}

test "jzon: escape_vector, encode one byte short is no space left" {
    var buf: [8]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(Error.Jzon_EscapeVector_NoSpaceLeft, encode(&sink, "a\nbcde"));
}

test "jzon: escape_vector, buffer that runs out inside a lane is no space left" {
    // The clean run ahead of the escape is copied first, so the room it takes is
    // gone before the escape's own spelling is attempted.
    var buf: [20]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(
        Error.Jzon_EscapeVector_NoSpaceLeft,
        encode(&sink, "a long clean run of bytes then a \" quote"),
    );
}

test "jzon: escape_vector, encode into an empty buffer is no space left" {
    var buf: [0]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(Error.Jzon_EscapeVector_NoSpaceLeft, encode(&sink, ""));
}

test "jzon: escape_vector, escapeError renames no space left to its own name" {
    const err = escapeError(error.Jzon_Escape_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_EscapeVector_NoSpaceLeft, err);
}

test "jzon: escape_vector, escapeError renames bad escape to its own name" {
    const err = escapeError(error.Jzon_Escape_BadEscape);

    try std.testing.expectEqual(Error.Jzon_EscapeVector_BadEscape, err);
}

