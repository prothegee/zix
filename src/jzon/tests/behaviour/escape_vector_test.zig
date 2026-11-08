//! JZON behaviour escape_vector_test
//!
//! ### file: src/jzon/tests/behaviour/escape_vector_test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The lane-at-a-time escape writes what the byte-at-a-time escape and
//! `std.json` write, over strings that cross lane boundaries.
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
const escape = jzon.escape;
const escape_vector = jzon.escape_vector;

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Strings a record realistically carries, long enough that most of them cross
/// at least one lane boundary.
const SAMPLES = [_][]const u8{
    "",
    "id",
    "a product name that runs comfortably past a single lane of bytes",
    "quoted \"value\" inside a sentence long enough to be scanned in lanes",
    "a windows path C:\\Users\\someone\\Documents\\report.txt written out",
    "line one\nline two\nline three\nand a fourth to push it well past a lane",
    "tab\tseparated\tfields\tacross\tenough\tcolumns\tto\tfill\tseveral\tlanes",
    "utf8 text with \xc3\xa9 and \xe2\x82\xac and \xf0\x9f\x92\xa9 spread through it",
};

/// The same string through std.json.Stringify, which both scans must match.
fn stdEncoded(buf: []u8, text: []const u8) std.json.Stringify.Error![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    try std.json.Stringify.value(text, .{}, &writer);

    return writer.buffered();
}

test "jzon behaviour: escape_vector, writes what the scalar escape writes" {
    for (SAMPLES) |sample| {
        var vector_buf: [512]u8 = undefined;
        var vector_sink: Sink = .init(&vector_buf);
        try escape_vector.encode(&vector_sink, sample);

        var scalar_buf: [512]u8 = undefined;
        var scalar_sink: Sink = .init(&scalar_buf);
        try escape.encode(&scalar_sink, sample);

        try std.testing.expectEqualStrings(scalar_sink.filled(), vector_sink.filled());
    }
}

test "jzon behaviour: escape_vector, matches std.json.Stringify byte for byte" {
    for (SAMPLES) |sample| {
        var ours: [512]u8 = undefined;
        var sink: Sink = .init(&ours);
        try escape_vector.encode(&sink, sample);

        var theirs: [512]u8 = undefined;
        const expected = try stdEncoded(&theirs, sample);

        try std.testing.expectEqualStrings(expected, sink.filled());
    }
}

test "jzon behaviour: escape_vector, output decodes back to the input" {
    for (SAMPLES) |sample| {
        var encoded: [512]u8 = undefined;
        var writer: Sink = .init(&encoded);
        try escape_vector.encodeBody(&writer, sample);

        var decoded: [512]u8 = undefined;
        var reader: Sink = .init(&decoded);
        try escape.decode(&reader, writer.filled());

        try std.testing.expectEqualStrings(sample, reader.filled());
    }
}

test "jzon behaviour: escape_vector, body leaves out the quotes encode adds" {
    const sample = "a body long enough to take the lane path, with a \" in it";

    var body_buf: [256]u8 = undefined;
    var body: Sink = .init(&body_buf);
    try escape_vector.encodeBody(&body, sample);

    var whole_buf: [256]u8 = undefined;
    var whole: Sink = .init(&whole_buf);
    try escape_vector.encode(&whole, sample);

    const inner = whole.filled()[1 .. whole.written() - 1];

    try std.testing.expectEqual(body.written() + 2, whole.written());
    try std.testing.expectEqualStrings(body.filled(), inner);
}

test "jzon behaviour: escape_vector, writes after what the sink already holds" {
    var buf: [256]u8 = undefined;
    var sink: Sink = .init(&buf);

    try sink.literal("{\"name\":");
    try escape_vector.encode(&sink, "a value long enough to be scanned a lane at a time");
    try sink.byte('}');

    try std.testing.expectEqualStrings(
        "{\"name\":\"a value long enough to be scanned a lane at a time\"}",
        sink.filled(),
    );
}

