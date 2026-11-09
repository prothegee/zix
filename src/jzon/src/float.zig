//! JZON float
//!
//! ### file: src/jzon/src/float.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! JSON floats in both directions: the number form of a float, written to match
//! `std.json.Stringify` byte for byte (`append`), read back with the RFC8259 grammar
//! checked (`parse`, `isNumber`).
//!
//! ### note:
//!
//! std renders through f64. A value that survives the cast is written as a number, one
//! that does not is written as a JSON string with its full precision. That is why an
//! f32 `0.1` comes out as `0.10000000149011612`, and why an f128 that f64 cannot hold
//! comes out quoted.
//!
//! Two values have no JSON form at all. std writes NaN as the string `"nan"` and an
//! infinity as the bare word `inf`, which no JSON parser accepts. jzon writes both the
//! same way so the two serialize paths never disagree. A field that can hold either
//! needs the caller to rule it out first.
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
const Sink = @import("Sink.zig");

// --------------------------------------------------------- //
// Private:

/// Every failure a private function here can hand back: this module's own set joined
/// with the sink's.
const Inner = Error || Sink.Error;

/// Translate a failure from inside the module into this module's public set.
///
/// Param:
/// err - Inner (the failure a private function handed back)
///
/// Return:
/// - Error (the same failure under this module's name)
inline fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.Jzon_Float_NoSpaceLeft => Error.Jzon_Float_NoSpaceLeft,
        error.Jzon_Float_BadNumber => Error.Jzon_Float_BadNumber,
        error.Jzon_Sink_NoSpaceLeft => Error.Jzon_Float_NoSpaceLeft,
    };
}

/// Format a float into the sink's unwritten tail, then accept the bytes.
///
/// Note:
/// - Writing straight into the tail means nothing is copied twice, and no fixed
///   scratch bounds the width. A decimal f64 runs to 326 characters at its smallest.
///
/// Param:
/// sink - *Sink (where the digits go)
/// value - anytype (any float width)
///
/// Return:
/// - void
/// - Error.Jzon_Float_NoSpaceLeft when the digits do not fit the tail
/// - Error.Jzon_Sink_NoSpaceLeft when the sink refuses the digits
fn printInto(sink: *Sink, value: anytype) Inner!void {
    const printed = std.fmt.bufPrint(sink.tail(), "{}", .{value}) catch |err| switch (err) {
        error.NoSpaceLeft => return Error.Jzon_Float_NoSpaceLeft,
    };

    try sink.commit(printed.len);
}

/// The body of `append`, failing with the inner set.
fn appendInto(sink: *Sink, value: anytype) Inner!void {
    // Reject a non-float at compile time, so an integer cannot reach the float
    // spelling by accident.
    _ = floatInfo(@TypeOf(value));

    const narrowed: f64 = @floatCast(value);

    if (narrowed == value) return printInto(sink, narrowed);

    try sink.byte('"');
    try printInto(sink, value);
    try sink.byte('"');
}

/// How many digits in a row start at `from`.
///
/// Param:
/// text - []const u8 (the bytes to scan)
/// from - usize (where the run starts)
///
/// Return:
/// - usize (the length of the digit run, 0 when `from` is not a digit)
fn digitRun(text: []const u8, from: usize) usize {
    var pos = from;
    while (pos < text.len and text[pos] >= '0' and text[pos] <= '9') : (pos += 1) {}

    return pos - from;
}

/// The float facts of a type, or a compile error naming the type that is not one.
///
/// Note:
/// - Inline so the width stays comptime-known at the call site.
///
/// Param:
/// Target - type (comptime, the type to inspect)
///
/// Return:
/// - std.builtin.Type.Float (the bit width)
inline fn floatInfo(comptime Target: type) std.builtin.Type.Float {
    return switch (@typeInfo(Target)) {
        .float => |info| info,
        else => @compileError("jzon float: " ++ @typeName(Target) ++ " is not a float"),
    };
}

// --------------------------------------------------------- //
// Public:

/// How a float write or read can fail.
///
/// Note:
/// - NoSpaceLeft comes from a write only. Nothing is allocated, so a full buffer is
///   the whole write surface.
/// - BadNumber comes from a read only. Text the JSON grammar does not allow reports
///   the same way as unreadable digits: this is not a number a field can take.
pub const Error = error{
    Jzon_Float_NoSpaceLeft,
    Jzon_Float_BadNumber,
};

/// Write a float as JSON.
///
/// Note:
/// - A plain value that does not fit leaves the sink as it was. A quoted value
///   (one f64 cannot hold, or NaN) can leave its opening quote and digits behind
///   when the closing quote is what does not fit.
///
/// Param:
/// sink - *Sink (where the number goes)
/// value - anytype (any float width)
///
/// Return:
/// - void
/// - Error.Jzon_Float_NoSpaceLeft when the rendered form does not fit
pub fn append(sink: *Sink, value: anytype) Error!void {
    return appendInto(sink, value) catch |err| innerError(err);
}

/// Read a float out of a number token's bytes.
///
/// Note:
/// - The RFC8259 section 6 grammar is checked here, not left to `std.fmt`, which
///   also reads `inf`, `nan` and hex floats. A token from a read cursor was bounded,
///   not validated, so the check has to live on this side.
/// - A value too large for the type becomes an infinity, not a failure, which is what
///   std.json does with the same text.
///
/// Param:
/// Target - type (comptime, the float type to produce)
/// text - []const u8 (the number token's bytes, as `Cursor.numberSpan` returns them)
///
/// Return:
/// - Target (the value)
/// - Error.Jzon_Float_BadNumber when the text is not a JSON number
pub fn parse(comptime Target: type, text: []const u8) Error!Target {
    // Reject a non-float at compile time, so an integer cannot reach the float
    // reading by accident.
    _ = floatInfo(Target);

    if (!isNumber(text)) return Error.Jzon_Float_BadNumber;

    return std.fmt.parseFloat(Target, text) catch |err| switch (err) {
        error.InvalidCharacter => Error.Jzon_Float_BadNumber,
    };
}

/// Whether `text` is one whole JSON number and nothing else (RFC8259 section 6).
///
/// Note:
/// - A leading zero is allowed only as the whole integer part, a fraction needs at
///   least one digit after the point, and an exponent needs at least one digit after
///   its optional sign.
/// - This is the grammar for any JSON number, not only one a float reads. A parse
///   stepping over a value it does not want asks the same question, so `1.2.3` is
///   refused whether the number is read or skipped.
///
/// Param:
/// text - []const u8 (the number token's bytes)
///
/// Return:
/// - bool (true when the whole text is one JSON number)
pub fn isNumber(text: []const u8) bool {
    var pos: usize = 0;

    if (pos < text.len and text[pos] == '-') pos += 1;

    const whole = digitRun(text, pos);
    if (whole == 0) return false;
    if (text[pos] == '0' and whole > 1) return false;

    pos += whole;

    if (pos < text.len and text[pos] == '.') {
        pos += 1;

        const fraction = digitRun(text, pos);
        if (fraction == 0) return false;

        pos += fraction;
    }

    if (pos < text.len and (text[pos] == 'e' or text[pos] == 'E')) {
        pos += 1;

        if (pos < text.len and (text[pos] == '+' or text[pos] == '-')) pos += 1;

        const exponent = digitRun(text, pos);
        if (exponent == 0) return false;

        pos += exponent;
    }

    return pos == text.len;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// The extremes of f64 the edge cases write and read back.
const F64_EXTREMES = [_]f64{
    std.math.floatMax(f64),
    -std.math.floatMax(f64),
    std.math.floatMin(f64),
    std.math.floatTrueMin(f64),
    std.math.floatEps(f64),
};

/// The same value through std.json.Stringify, which this module's output must match.
fn stdRendered(buf: []u8, value: anytype) ![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    try std.json.Stringify.value(value, .{}, &writer);

    return writer.buffered();
}

/// Write one value and require the bytes to be `expected`.
fn expectRendered(expected: []const u8, value: anytype) !void {
    var buf: [512]u8 = undefined;
    var sink: Sink = .init(&buf);
    try append(&sink, value);

    try std.testing.expectEqualStrings(expected, sink.filled());
}

/// Write one value both here and through std, and require the same bytes.
fn expectSameAsStd(value: anytype) !void {
    var ours: [512]u8 = undefined;
    var sink: Sink = .init(&ours);
    try append(&sink, value);

    var theirs: [512]u8 = undefined;

    try std.testing.expectEqualStrings(try stdRendered(&theirs, value), sink.filled());
}

test "jzon: float, append writes plain values as JSON numbers" {
    try expectRendered("0", @as(f64, 0.0));
    try expectRendered("1", @as(f64, 1.0));
    try expectRendered("-1.5", @as(f64, -1.5));
    try expectRendered("3.5", @as(f64, 3.5));
    try expectRendered("0.1", @as(f64, 0.1));
    try expectRendered("12345.6789", @as(f64, 12345.6789));
}

test "jzon: float, append writes an f32 as the f64 nearest it" {
    try expectRendered("1.5", @as(f32, 1.5));
    try expectRendered("0.10000000149011612", @as(f32, 0.1));
    try expectRendered("1.5", @as(f16, 1.5));
}

test "jzon: float, append matches std.json.Stringify byte for byte" {
    const samples = [_]f64{
        0.0,
        -0.0,
        1.0,
        -1.0,
        0.5,
        -0.5,
        0.1,
        12345.6789,
        1e21,
        1e-7,
        1e300,
        1e-300,
        std.math.floatMax(f64),
        std.math.floatMin(f64),
        std.math.floatTrueMin(f64),
    };

    for (samples) |sample| try expectSameAsStd(sample);
}

test "jzon: float, append quotes a value f64 cannot hold" {
    try expectRendered("\"0.1\"", @as(f128, 0.1));
    try expectSameAsStd(@as(f128, 0.1));
}

test "jzon: float, append spells NaN and infinity the way std does" {
    try expectRendered("\"nan\"", std.math.nan(f64));
    try expectRendered("inf", std.math.inf(f64));
    try expectSameAsStd(std.math.inf(f64));
}

test "jzon: float, append into a small buffer is no space left" {
    var buf: [4]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(
        Error.Jzon_Float_NoSpaceLeft,
        append(&sink, @as(f64, 12345.6789)),
    );
    try std.testing.expectEqual(@as(usize, 0), sink.written());
}

test "jzon: float, parse reads back what append wrote" {
    const samples = [_]f64{
        0.0,
        1.0,
        -1.0,
        0.5,
        0.1,
        12345.6789,
        -0.000125,
        1e21,
        1e-300,
    };

    for (samples) |sample| {
        var buf: [512]u8 = undefined;
        var sink: Sink = .init(&buf);
        try append(&sink, sample);

        try std.testing.expectEqual(sample, try parse(f64, sink.filled()));
    }
}

test "jzon: float, parse takes every part of the JSON number grammar" {
    try std.testing.expectEqual(@as(f64, 0), try parse(f64, "0"));
    try std.testing.expectEqual(@as(f64, -0.5), try parse(f64, "-0.5"));
    try std.testing.expectEqual(@as(f64, 42), try parse(f64, "42"));
    try std.testing.expectEqual(@as(f64, 1200), try parse(f64, "1.2e3"));
    try std.testing.expectEqual(@as(f64, 1200), try parse(f64, "1.2E+3"));
    try std.testing.expectEqual(@as(f64, 0.0012), try parse(f64, "1.2e-3"));
}

test "jzon: float, parse of text the JSON grammar does not allow is bad number" {
    const samples = [_][]const u8{
        "",
        "-",
        "007",
        "1.",
        ".5",
        "1e",
        "1e+",
        "+1",
        "1 ",
        // std.fmt reads these three, and none of them is JSON.
        "inf",
        "nan",
        "0x1p3",
    };

    for (samples) |sample| {
        try std.testing.expectError(Error.Jzon_Float_BadNumber, parse(f64, sample));
    }
}

test "jzon: float, parse past the width of a narrow type widens like std.json" {
    try std.testing.expectEqual(std.math.inf(f32), try parse(f32, "1e300"));
    try std.testing.expectEqual(@as(f16, 1.5), try parse(f16, "1.5"));
}

test "jzon: float, innerError renames sink no space left to its own name" {
    const err = innerError(error.Jzon_Sink_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_Float_NoSpaceLeft, err);
}

test "jzon: float, isNumber takes a whole JSON number" {
    const samples = [_][]const u8{
        "0",
        "-0",
        "7",
        "-12",
        "0.5",
        "1.25e10",
        "1E-3",
        "1e+0",
    };

    for (samples) |sample| try std.testing.expect(isNumber(sample));
}

test "jzon: float, isNumber refuses a second fraction" {
    try std.testing.expect(!isNumber("1.2.3"));
}

test "jzon: float, append writes the extremes of f64 the way std does" {
    for (F64_EXTREMES) |sample| try expectSameAsStd(sample);

    try expectSameAsStd(@as(f64, 1e308));
    try expectSameAsStd(@as(f64, 1e-308));
}

test "jzon: float, append writes both zeroes the way std does" {
    try expectSameAsStd(@as(f64, 0.0));
    try expectSameAsStd(@as(f64, -0.0));
}

test "jzon: float, append spells NaN as a string" {
    try expectRendered("\"nan\"", std.math.nan(f64));
    try expectSameAsStd(std.math.nan(f64));
}

test "jzon: float, append spells negative infinity as a bare word" {
    try expectRendered("-inf", -std.math.inf(f64));
    try expectSameAsStd(-std.math.inf(f64));
}

test "jzon: float, append output for infinity is not valid JSON" {
    // No JSON parser takes this. jzon writes it only so the two serialize paths never
    // disagree.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var buf: [64]u8 = undefined;
    var sink: Sink = .init(&buf);
    try append(&sink, std.math.inf(f64));

    const read = std.json.parseFromSliceLeaky(f64, arena.allocator(), sink.filled(), .{});

    try std.testing.expect(std.meta.isError(read));
}

test "jzon: float, append writes an f128 that f64 can hold as a bare number" {
    try expectRendered("0.5", @as(f128, 0.5));
}

test "jzon: float, append fills an exact-fit buffer" {
    var buf: [10]u8 = undefined;
    var sink: Sink = .init(&buf);
    try append(&sink, @as(f64, 12345.6789));

    try std.testing.expectEqualStrings("12345.6789", sink.filled());
    try std.testing.expectEqual(@as(usize, 0), sink.remaining());
}

test "jzon: float, append one byte short is no space left" {
    var buf: [9]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(
        Error.Jzon_Float_NoSpaceLeft,
        append(&sink, @as(f64, 12345.6789)),
    );
    try std.testing.expectEqual(@as(usize, 0), sink.written());
}

test "jzon: float, append without room for the closing quote keeps what landed" {
    // "0.1" is five bytes with its quotes, so four is one short of the whole spelling
    // and the bytes that did land stay put.
    var buf: [4]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(Error.Jzon_Float_NoSpaceLeft, append(&sink, @as(f128, 0.1)));
    try std.testing.expectEqualStrings("\"0.1", sink.filled());
}

test "jzon: float, append into an empty buffer is no space left" {
    var buf: [0]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(Error.Jzon_Float_NoSpaceLeft, append(&sink, @as(f64, 1.0)));
}

test "jzon: float, append writes every width it is handed" {
    inline for (.{ f16, f32, f64, f80, f128 }) |Width| {
        try expectRendered("1.25", @as(Width, 1.25));
    }
}

test "jzon: float, parse of a word std.fmt reads as a number is bad number" {
    // std.fmt.parseFloat takes all four of these. None of them is JSON, and a read
    // cursor bounds a token without checking its grammar, so the refusal happens here.
    const samples = [_][]const u8{
        "inf",
        "-inf",
        "nan",
        "0x1p3",
    };

    for (samples) |sample| {
        try std.testing.expectError(Error.Jzon_Float_BadNumber, parse(f64, sample));
    }
}

test "jzon: float, parse of a number missing a part the grammar needs is bad number" {
    const samples = [_][]const u8{
        "",
        "-",
        ".",
        ".5",
        "1.",
        "1e",
        "1e-",
        "--1",
    };

    for (samples) |sample| {
        try std.testing.expectError(Error.Jzon_Float_BadNumber, parse(f64, sample));
    }
}

test "jzon: float, parse takes a zero that is the whole integer part" {
    try std.testing.expectEqual(@as(f64, 0), try parse(f64, "0"));
    try std.testing.expectEqual(@as(f64, 0.5), try parse(f64, "0.5"));
    try std.testing.expectEqual(@as(f64, -0.5), try parse(f64, "-0.5"));
}

test "jzon: float, parse with a leading zero RFC8259 does not allow is bad number" {
    const samples = [_][]const u8{
        "01",
        "-01",
        "007",
    };

    for (samples) |sample| {
        try std.testing.expectError(Error.Jzon_Float_BadNumber, parse(f64, sample));
    }
}

test "jzon: float, parse with anything trailing the number is bad number" {
    const samples = [_][]const u8{
        "1 ",
        "1,",
        "1.5x",
        "+1",
    };

    for (samples) |sample| {
        try std.testing.expectError(Error.Jzon_Float_BadNumber, parse(f64, sample));
    }
}

test "jzon: float, parse past a width reads infinity like std.json" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const ours = try parse(f32, "1e300");
    const theirs = try std.json.parseFromSliceLeaky(f32, arena.allocator(), "1e300", .{});

    try std.testing.expectEqual(std.math.inf(f32), ours);
    try std.testing.expectEqual(theirs, ours);
}

test "jzon: float, parse reads the extremes of f64 back from append" {
    for (F64_EXTREMES) |sample| {
        var buf: [512]u8 = undefined;
        var sink: Sink = .init(&buf);
        try append(&sink, sample);

        try std.testing.expectEqual(sample, try parse(f64, sink.filled()));
    }
}

test "jzon: float, innerError keeps its own no space left" {
    const err = innerError(error.Jzon_Float_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_Float_NoSpaceLeft, err);
}

test "jzon: float, innerError keeps its own bad number" {
    const err = innerError(error.Jzon_Float_BadNumber);

    try std.testing.expectEqual(Error.Jzon_Float_BadNumber, err);
}

