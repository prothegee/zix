//! JZON std_emitter
//!
//! ### file: src/jzon/src/serialize/std_emitter.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! The std-backed write path: renders a value through `std.json.Stringify` into a
//! caller-owned buffer. It takes every shape std takes.
//!
//! ### note:
//!
//! Nothing is allocated. std writes into the sink's unwritten tail through a fixed
//! writer, and the sink only advances once the whole value has landed. So a value too
//! large for the buffer leaves the sink exactly as it was. That is stricter than the
//! generated emitter, which writes as it goes.
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
const Sink = @import("../Sink.zig");

// --------------------------------------------------------- //
// Private:

/// Every failure this module can hand back before translation: its own set joined
/// with the sink's.
const Inner = Error || Sink.Error;

/// Translate a failure from inside the module into this module's public set.
///
/// Param:
/// err - Inner (the failure a sink call or this module handed back)
///
/// Return:
/// - Error (the same failure under this module's name)
inline fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Jzon_StdEmitter_NoSpaceLeft => Error.Jzon_StdEmitter_NoSpaceLeft,
        error.Jzon_Sink_NoSpaceLeft => Error.Jzon_StdEmitter_NoSpaceLeft,
    };
}

// --------------------------------------------------------- //
// Public:

/// How rendering can fail.
///
/// Note:
/// - Nothing is allocated, so a full buffer is the whole failure surface.
pub const Error = error{
    Jzon_StdEmitter_NoSpaceLeft,
};

/// Render `value` as JSON.
///
/// Note:
/// - A fixed writer fails only when it runs out of room, so `WriteFailed` means the
///   buffer is full.
///
/// Param:
/// sink - *Sink (where the JSON text goes)
/// value - anytype (any shape std.json.Stringify renders)
///
/// Return:
/// - void
/// - Error.Jzon_StdEmitter_NoSpaceLeft when the rendered form does not fit
pub fn emit(sink: *Sink, value: anytype) Error!void {
    var writer = std.Io.Writer.fixed(sink.tail());

    std.json.Stringify.value(value, .{}, &writer) catch |err| switch (err) {
        error.WriteFailed => return Error.Jzon_StdEmitter_NoSpaceLeft,
    };

    sink.commit(writer.buffered().len) catch |err| return innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

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

test "jzon serialize: std_emitter, renders a whole record" {
    var buf: [512]u8 = undefined;
    var sink: Sink = .init(&buf);

    try emit(&sink, RECORD);

    try std.testing.expectEqualStrings(
        "{\"id\":7,\"name\":\"a\\\"b\",\"ratio\":2.5,\"active\":true," ++
            "\"status\":\"SHIPPED\",\"note\":null,\"tags\":[\"one\",\"two\"]," ++
            "\"nested\":{\"alpha\":-3,\"beta\":\"x\"}}",
        sink.filled(),
    );
}

test "jzon serialize: std_emitter, writes after what the sink already holds" {
    var buf: [64]u8 = undefined;
    var sink: Sink = .init(&buf);

    try sink.literal("{\"body\":");
    try emit(&sink, @as(u32, 42));
    try sink.byte('}');

    try std.testing.expectEqualStrings("{\"body\":42}", sink.filled());
}

test "jzon serialize: std_emitter, value that does not fit leaves the sink untouched" {
    var buf: [16]u8 = undefined;
    var sink: Sink = .init(&buf);
    try sink.literal("[");

    try std.testing.expectError(Error.Jzon_StdEmitter_NoSpaceLeft, emit(&sink, RECORD));
    try std.testing.expectEqualStrings("[", sink.filled());
}

test "jzon serialize: std_emitter, innerError renames sink no space left to its own name" {
    const err = innerError(error.Jzon_Sink_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_StdEmitter_NoSpaceLeft, err);
}

test "jzon serialize: std_emitter, fills an exact-fit buffer" {
    var buf: [PAIR_TEXT.len]u8 = undefined;
    var sink: Sink = .init(&buf);

    try emit(&sink, PAIR);

    try std.testing.expectEqualStrings(PAIR_TEXT, sink.filled());
    try std.testing.expectEqual(@as(usize, 0), sink.remaining());
}

test "jzon serialize: std_emitter, one byte short is no space left and writes nothing" {
    var buf: [PAIR_TEXT.len - 1]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(Error.Jzon_StdEmitter_NoSpaceLeft, emit(&sink, PAIR));
    try std.testing.expectEqual(@as(usize, 0), sink.written());
}

test "jzon serialize: std_emitter, failed render keeps an earlier write in place" {
    var buf: [8]u8 = undefined;
    var sink: Sink = .init(&buf);
    try sink.literal("[");

    try std.testing.expectError(Error.Jzon_StdEmitter_NoSpaceLeft, emit(&sink, PAIR));
    try std.testing.expectEqualStrings("[", sink.filled());
    try std.testing.expectEqual(@as(usize, 1), sink.written());
}

test "jzon serialize: std_emitter, empty buffer is no space left" {
    var buf: [0]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(Error.Jzon_StdEmitter_NoSpaceLeft, emit(&sink, PAIR));
}

test "jzon serialize: std_emitter, renders the shapes with nothing in them" {
    const Empty = struct {};

    var buf: [64]u8 = undefined;
    var sink: Sink = .init(&buf);

    try emit(&sink, Empty{});
    try emit(&sink, @as([]const u8, ""));
    try emit(&sink, @as([]const u32, &.{}));
    try emit(&sink, @as(?u8, null));

    try std.testing.expectEqualStrings("{}\"\"[]null", sink.filled());
}

test "jzon serialize: std_emitter, renders the extremes of the integer widths" {
    const Extremes = struct {
        unsigned_high: u64,
        signed_high: i64,
        signed_low: i64,
        narrow: u8,
    };

    var buf: [256]u8 = undefined;
    var sink: Sink = .init(&buf);

    try emit(&sink, Extremes{
        .unsigned_high = std.math.maxInt(u64),
        .signed_high = std.math.maxInt(i64),
        .signed_low = std.math.minInt(i64),
        .narrow = 255,
    });

    try std.testing.expectEqualStrings(
        "{\"unsigned_high\":18446744073709551615," ++
            "\"signed_high\":9223372036854775807," ++
            "\"signed_low\":-9223372036854775808," ++
            "\"narrow\":255}",
        sink.filled(),
    );
}

test "jzon serialize: std_emitter, renders a value nested several levels deep" {
    const Leaf = struct { value: u8 };
    const Middle = struct { leaf: Leaf };
    const Root = struct { middle: Middle };

    var buf: [128]u8 = undefined;
    var sink: Sink = .init(&buf);

    try emit(&sink, Root{ .middle = .{ .leaf = .{ .value = 9 } } });

    try std.testing.expectEqualStrings(
        "{\"middle\":{\"leaf\":{\"value\":9}}}",
        sink.filled(),
    );
}

test "jzon serialize: std_emitter, innerError keeps its own no space left" {
    const err = innerError(error.Jzon_StdEmitter_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_StdEmitter_NoSpaceLeft, err);
}

