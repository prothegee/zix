//! zix jzon floats.
//!
//! What:
//! - The JSON number form of a float, written to match `std.json.Stringify` byte
//!   for byte so the two are interchangeable.
//!
//! Note:
//! - std renders through f64: a value that survives the cast is written as a
//!   number, one that does not is written as a JSON string carrying its full
//!   precision. That is why an f32 comes out as the f64 nearest it, `0.1` as
//!   `0.10000000149011612`, and why an f128 that f64 cannot hold comes out
//!   quoted.
//! - Two values have no JSON form at all. std writes a NaN as the string `"nan"`,
//!   and an infinity as the bare word `inf`, which no JSON parser accepts. jzon
//!   writes both the same way rather than disagree with the default path, so a
//!   field that can hold either needs the caller to rule it out first.
//! - Reading a float back belongs here too and arrives with the parser.

const std = @import("std");

const Sink = @import("sink.zig").Sink;

/// How writing a float can fail. Nothing is allocated, so a full buffer is all
/// of it.
pub const WriteError = @import("sink.zig").Error;

/// Write a float as JSON.
///
/// Note:
/// - The digits are formatted into the sink's unwritten tail, so nothing is
///   copied twice and no scratch buffer bounds the value's width. A decimal f64
///   runs to 326 characters at its smallest, which is why no fixed scratch is
///   used here.
///
/// Param:
/// sink - *Sink (where the number goes)
/// value - anytype (any float width)
///
/// Return:
/// - void
/// - error.NoSpaceLeft when the rendered form does not fit
pub fn append(sink: *Sink, value: anytype) WriteError!void {
    // Reject a non-float at compile time, so an integer cannot reach the float
    // spelling by accident.
    _ = floatInfo(@TypeOf(value));

    const narrowed: f64 = @floatCast(value);

    if (narrowed == value) {
        const printed = std.fmt.bufPrint(sink.tail(), "{}", .{narrowed}) catch
            return error.NoSpaceLeft;

        return sink.commit(printed.len);
    }

    try sink.byte('"');

    const printed = std.fmt.bufPrint(sink.tail(), "{}", .{value}) catch
        return error.NoSpaceLeft;
    try sink.commit(printed.len);

    try sink.byte('"');
}

/// The float facts of T, or a compile error naming the type that is not one.
///
/// Note:
/// - Inline so the width stays comptime-known at the call site.
inline fn floatInfo(comptime T: type) std.builtin.Type.Float {
    return switch (@typeInfo(T)) {
        .float => |info| info,
        else => @compileError("jzon float: " ++ @typeName(T) ++ " is not a float"),
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

/// The same value through std.json.Stringify, which jzon's output must match.
fn stdRendered(buf: []u8, value: anytype) []const u8 {
    var writer = std.Io.Writer.fixed(buf);
    std.json.Stringify.value(value, .{}, &writer) catch unreachable;

    return writer.buffered();
}

/// Write one value and assert it reads back as `expected`.
fn expectRendered(expected: []const u8, value: anytype) !void {
    var buf: [512]u8 = undefined;
    var sink: Sink = .init(&buf);
    try append(&sink, value);

    try std.testing.expectEqualStrings(expected, sink.filled());
}

test "zix jzon: float writes the plain values as JSON numbers" {
    try expectRendered("0", @as(f64, 0.0));
    try expectRendered("1", @as(f64, 1.0));
    try expectRendered("-1.5", @as(f64, -1.5));
    try expectRendered("3.5", @as(f64, 3.5));
    try expectRendered("0.1", @as(f64, 0.1));
    try expectRendered("12345.6789", @as(f64, 12345.6789));
}

test "zix jzon: float writes an f32 as the f64 nearest it, the way std does" {
    try expectRendered("1.5", @as(f32, 1.5));
    try expectRendered("0.10000000149011612", @as(f32, 0.1));
    try expectRendered("1.5", @as(f16, 1.5));
}

test "zix jzon: float agrees with std.json.Stringify byte for byte" {
    const samples = [_]f64{
        0.0,                    -0.0,                   1.0,
        -1.0,                   0.5,                    -0.5,
        0.1,                    12345.6789,             1e21,
        1e-7,                   1e300,                  1e-300,
        std.math.floatMax(f64), std.math.floatMin(f64), std.math.floatTrueMin(f64),
    };

    for (samples) |sample| {
        var ours: [512]u8 = undefined;
        var sink: Sink = .init(&ours);
        try append(&sink, sample);

        var theirs: [512]u8 = undefined;
        try std.testing.expectEqualStrings(stdRendered(&theirs, sample), sink.filled());
    }
}

test "zix jzon: float quotes a value f64 cannot hold, the way std does" {
    var ours: [512]u8 = undefined;
    var sink: Sink = .init(&ours);
    try append(&sink, @as(f128, 0.1));

    try std.testing.expectEqualStrings("\"0.1\"", sink.filled());

    var theirs: [512]u8 = undefined;
    try std.testing.expectEqualStrings(stdRendered(&theirs, @as(f128, 0.1)), sink.filled());
}

test "zix jzon: float spells NaN and infinity the way std does, neither of them JSON" {
    var nan_buf: [64]u8 = undefined;
    var nan_sink: Sink = .init(&nan_buf);
    try append(&nan_sink, std.math.nan(f64));
    try std.testing.expectEqualStrings("\"nan\"", nan_sink.filled());

    var inf_buf: [64]u8 = undefined;
    var inf_sink: Sink = .init(&inf_buf);
    try append(&inf_sink, std.math.inf(f64));
    try std.testing.expectEqualStrings("inf", inf_sink.filled());

    var std_buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(stdRendered(&std_buf, std.math.inf(f64)), inf_sink.filled());
}

test "zix jzon: float reports a buffer the digits do not fit in" {
    var buf: [4]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(error.NoSpaceLeft, append(&sink, @as(f64, 12345.6789)));
    try std.testing.expectEqual(@as(usize, 0), sink.written());
}
