//! JZON behaviour sink_test
//!
//! ### file: src/jzon/tests/behaviour/sink_test.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What a caller sees from `Sink`: writes land in order, the three position
//! readings agree, and a reserved region is the caller's to fill.
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

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "jzon behaviour: Sink, writes land in call order" {
    var buf: [64]u8 = undefined;
    var sink: Sink = .init(&buf);

    try sink.byte('{');
    try sink.literal("\"name\":");
    try sink.byte('"');
    try sink.bytes("zix");
    try sink.byte('"');
    try sink.byte('}');

    try std.testing.expectEqualStrings("{\"name\":\"zix\"}", sink.filled());
}

test "jzon behaviour: Sink, literal and bytes produce the same run" {
    var literal_buf: [16]u8 = undefined;
    var literal_sink: Sink = .init(&literal_buf);
    try literal_sink.literal("\"total\":");

    var bytes_buf: [16]u8 = undefined;
    var bytes_sink: Sink = .init(&bytes_buf);
    try bytes_sink.bytes("\"total\":");

    try std.testing.expectEqualStrings(literal_sink.filled(), bytes_sink.filled());
}

test "jzon behaviour: Sink, written, remaining and filled agree at every step" {
    var buf: [10]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectEqual(@as(usize, 0), sink.written());
    try std.testing.expectEqual(@as(usize, 10), sink.remaining());
    try std.testing.expectEqual(@as(usize, 0), sink.filled().len);

    try sink.bytes("abcd");

    try std.testing.expectEqual(@as(usize, 4), sink.written());
    try std.testing.expectEqual(@as(usize, 6), sink.remaining());
    try std.testing.expectEqual(sink.written(), sink.filled().len);
    try std.testing.expectEqual(buf.len, sink.written() + sink.remaining());
}

test "jzon behaviour: Sink, reserve hands over exactly the room asked for" {
    var buf: [16]u8 = undefined;
    var sink: Sink = .init(&buf);

    try sink.byte('[');

    const region = try sink.reserve(5);

    try std.testing.expectEqual(@as(usize, 5), region.len);

    @memcpy(region, "12345");
    try sink.byte(']');

    try std.testing.expectEqualStrings("[12345]", sink.filled());
}

test "jzon behaviour: Sink, tail and commit carry a foreign writer's output" {
    var buf: [32]u8 = undefined;
    var sink: Sink = .init(&buf);

    try sink.literal("id=");

    const printed = try std.fmt.bufPrint(sink.tail(), "{d}", .{987654});
    try sink.commit(printed.len);

    try std.testing.expectEqualStrings("id=987654", sink.filled());
    try std.testing.expectEqual(@as(usize, 9), sink.written());
}

test "jzon behaviour: Sink, reset makes the buffer reusable" {
    var buf: [16]u8 = undefined;
    var sink: Sink = .init(&buf);

    try sink.bytes("first pass");

    try std.testing.expectEqual(@as(usize, 10), sink.written());

    sink.reset();

    try std.testing.expectEqual(@as(usize, 0), sink.written());
    try std.testing.expectEqual(buf.len, sink.remaining());

    try sink.bytes("second");

    try std.testing.expectEqualStrings("second", sink.filled());
}

