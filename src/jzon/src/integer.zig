//! JZON integer
//!
//! ### file: src/jzon/src/integer.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! JSON integers in both directions: two ways to write one (`appendFmt`, `appendTable`)
//! and one way to read one back with the target type's range enforced (`parse`).
//!
//! ### note:
//!
//! Both write paths emit the same bytes, so a caller picks on cost alone. The digit
//! conversion is the same in both (two digits per step out of `std.fmt.digits2`). What
//! separates them is the work around it: `appendFmt` runs the `std.fmt` width and
//! alignment pass, `appendTable` runs the loop over a stack buffer and copies once.
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

/// Translate a `Sink` failure into this module's set.
///
/// Param:
/// err - Sink.Error (the failure the sink reported)
///
/// Return:
/// - Error (the same failure under this module's name)
fn sinkError(err: Sink.Error) Error {
    return switch (err) {
        error.Jzon_Sink_NoSpaceLeft => Error.Jzon_Integer_NoSpaceLeft,
    };
}

/// The integer facts of a type, or a compile error naming the type that is not one.
///
/// Note:
/// - Inline so the fields stay comptime-known at the call site, which is what lets a
///   width be built from `info.bits`.
///
/// Param:
/// Target - type (comptime, the type to inspect)
///
/// Return:
/// - std.builtin.Type.Int (the signedness and bit width)
inline fn intInfo(comptime Target: type) std.builtin.Type.Int {
    return switch (@typeInfo(Target)) {
        .int => |info| info,
        else => @compileError("jzon integer: " ++ @typeName(Target) ++ " is not an integer"),
    };
}

// --------------------------------------------------------- //
// Public:

/// How an integer write or read can fail.
///
/// Note:
/// - NoSpaceLeft comes from a write only. Nothing is allocated, so a full buffer is
///   the whole write surface.
/// - BadNumber comes from a read only. A value the target type cannot hold reports
///   the same way as a malformed one: the text is not a number this field takes.
pub const Error = error{
    Jzon_Integer_NoSpaceLeft,
    Jzon_Integer_BadNumber,
};

/// Upper bound on the decimal length of any value of a type, sign included.
///
/// Note:
/// - log10(2) is just under 1/3, so bits / 3 + 1 never under-counts the digits.
///
/// Param:
/// Target - type (comptime, the integer type to bound)
///
/// Return:
/// - comptime_int (the widest decimal length a value of the type can take)
pub fn maxDigits(comptime Target: type) comptime_int {
    const info = intInfo(Target);
    const sign: comptime_int = if (info.signedness == .signed) 1 else 0;
    const magnitude_bits: comptime_int = @as(comptime_int, info.bits) - sign;

    return @max(magnitude_bits, 1) / 3 + 1 + sign;
}

/// Write an integer through `std.fmt`.
///
/// Note:
/// - Formats into the sink's unwritten tail, so the digits are not copied twice.
/// - A failed write leaves the sink as it was.
///
/// Param:
/// sink - *Sink (where the digits go)
/// value - anytype (any integer width, signed or unsigned)
///
/// Return:
/// - void
/// - Error.Jzon_Integer_NoSpaceLeft when the digits do not fit
pub fn appendFmt(sink: *Sink, value: anytype) Error!void {
    // Reject a non-integer at compile time, so both write paths take the same types.
    _ = intInfo(@TypeOf(value));

    const printed = std.fmt.bufPrint(sink.tail(), "{d}", .{value}) catch |err| switch (err) {
        error.NoSpaceLeft => return Error.Jzon_Integer_NoSpaceLeft,
    };

    sink.commit(printed.len) catch |err| return sinkError(err);
}

/// Write an integer straight into the sink.
///
/// Note:
/// - `@abs` on a signed value gives the unsigned type of the same width, so the most
///   negative value converts without overflowing.
/// - The running value is held at 8 bits or wider whatever the type is, so a narrow
///   type still compares against the 100 and 10 the loop needs.
/// - A failed write leaves the sink as it was.
///
/// Param:
/// sink - *Sink (where the digits go)
/// value - anytype (any integer width, signed or unsigned)
///
/// Return:
/// - void
/// - Error.Jzon_Integer_NoSpaceLeft when the digits do not fit
pub fn appendTable(sink: *Sink, value: anytype) Error!void {
    const Value = @TypeOf(value);
    const info = intInfo(Value);
    const Magnitude = @Int(.unsigned, @max(info.bits, 8));

    var digits: [maxDigits(Value)]u8 = undefined;
    var start: usize = digits.len;
    var rest: Magnitude = @abs(value);

    while (rest >= 100) : (rest = @divTrunc(rest, 100)) {
        start -= 2;
        digits[start..][0..2].* = std.fmt.digits2(@intCast(rest % 100));
    }

    if (rest < 10) {
        start -= 1;
        digits[start] = '0' + @as(u8, @intCast(rest));
    } else {
        start -= 2;
        digits[start..][0..2].* = std.fmt.digits2(@intCast(rest));
    }

    if (info.signedness == .signed and value < 0) {
        start -= 1;
        digits[start] = '-';
    }

    sink.bytes(digits[start..]) catch |err| return sinkError(err);
}

/// Read an integer out of a number token's bytes.
///
/// Note:
/// - RFC8259 section 6 allows a leading zero only when it is the whole integer part,
///   so `007` is refused, not read as 7.
/// - A minus sign against an unsigned type is refused outright, `-0` included, so the
///   sign is a type error, not a value that happens to fit.
/// - A fraction or an exponent is not an integer, so `1.0` and `1e2` are refused
///   here. A float field reads those through the float path.
///
/// Param:
/// Target - type (comptime, the integer type to produce)
/// text - []const u8 (the number token's bytes, as `Cursor.numberSpan` returns them)
///
/// Return:
/// - Target (the value)
/// - Error.Jzon_Integer_BadNumber when the text is not an integer, or holds one the
///   type cannot carry
pub fn parse(comptime Target: type, text: []const u8) Error!Target {
    const info = intInfo(Target);
    const Magnitude = @Int(.unsigned, @max(info.bits, 8));
    const Wide = @Int(.signed, @max(info.bits, 8) + 1);

    if (text.len == 0) return Error.Jzon_Integer_BadNumber;

    const negative = text[0] == '-';
    const digits = if (negative) text[1..] else text;

    if (negative and info.signedness == .unsigned) return Error.Jzon_Integer_BadNumber;
    if (digits.len == 0) return Error.Jzon_Integer_BadNumber;
    if (digits[0] == '0' and digits.len > 1) return Error.Jzon_Integer_BadNumber;

    var magnitude: Magnitude = 0;

    for (digits) |byte| {
        const digit = byte -% '0';
        if (digit > 9) return Error.Jzon_Integer_BadNumber;

        const scaled = @mulWithOverflow(magnitude, 10);
        if (scaled[1] != 0) return Error.Jzon_Integer_BadNumber;

        const summed = @addWithOverflow(scaled[0], @as(Magnitude, digit));
        if (summed[1] != 0) return Error.Jzon_Integer_BadNumber;

        magnitude = summed[0];
    }

    if (!negative) return std.math.cast(Target, magnitude) orelse Error.Jzon_Integer_BadNumber;

    return std.math.cast(Target, -@as(Wide, magnitude)) orelse Error.Jzon_Integer_BadNumber;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Every width the edge cases walk, from one bit to 128.
const WIDTHS = .{ u1, u8, i8, u16, i16, u32, i32, u64, i64, u128, i128 };

/// Write one value both ways and require both to match `expected`.
fn expectBothPaths(expected: []const u8, value: anytype) !void {
    var fmt_buf: [64]u8 = undefined;
    var fmt_sink: Sink = .init(&fmt_buf);
    try appendFmt(&fmt_sink, value);

    var table_buf: [64]u8 = undefined;
    var table_sink: Sink = .init(&table_buf);
    try appendTable(&table_sink, value);

    try std.testing.expectEqualStrings(expected, fmt_sink.filled());
    try std.testing.expectEqualStrings(expected, table_sink.filled());
}

test "jzon: integer, both paths write the same digits" {
    try expectBothPaths("0", @as(u64, 0));
    try expectBothPaths("7", @as(u64, 7));
    try expectBothPaths("42", @as(u64, 42));
    try expectBothPaths("100", @as(u64, 100));
    try expectBothPaths("12345", @as(u32, 12345));
    try expectBothPaths("-1", @as(i32, -1));
    try expectBothPaths("-9876", @as(i32, -9876));
}

test "jzon: integer, both paths write the extremes of their width" {
    try expectBothPaths("255", @as(u8, 255));
    try expectBothPaths("127", @as(i8, 127));
    try expectBothPaths("-128", @as(i8, -128));
    try expectBothPaths("18446744073709551615", @as(u64, std.math.maxInt(u64)));
    try expectBothPaths("9223372036854775807", @as(i64, std.math.maxInt(i64)));
    try expectBothPaths("-9223372036854775808", @as(i64, std.math.minInt(i64)));
}

test "jzon: integer, maxDigits bounds every width it is asked about" {
    try std.testing.expect(maxDigits(u8) >= "255".len);
    try std.testing.expect(maxDigits(i8) >= "-128".len);
    try std.testing.expect(maxDigits(u64) >= "18446744073709551615".len);
    try std.testing.expect(maxDigits(i64) >= "-9223372036854775808".len);
    try std.testing.expect(maxDigits(u1) >= "1".len);
}

test "jzon: integer, parse reads back what either path wrote" {
    const values = [_]i64{
        0,
        1,
        -1,
        9,
        10,
        99,
        100,
        12345,
        -12345,
        std.math.maxInt(i64),
        std.math.minInt(i64),
    };

    for (values) |value| {
        var buf: [32]u8 = undefined;
        var sink: Sink = .init(&buf);
        try appendTable(&sink, value);

        try std.testing.expectEqual(value, try parse(i64, sink.filled()));

        sink.reset();
        try appendFmt(&sink, value);

        try std.testing.expectEqual(value, try parse(i64, sink.filled()));
    }
}

test "jzon: integer, parse enforces the target type range" {
    try std.testing.expectEqual(@as(u8, 255), try parse(u8, "255"));
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(u8, "256"));
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(u8, "-1"));
    try std.testing.expectEqual(@as(i8, -128), try parse(i8, "-128"));
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(i8, "-129"));
    try std.testing.expectError(
        Error.Jzon_Integer_BadNumber,
        parse(u64, "18446744073709551616"),
    );
}

test "jzon: integer, parse refuses text no integer can be read from" {
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(u32, ""));
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(u32, "-"));
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(u32, "007"));
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(u32, "1.0"));
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(u32, "1e2"));
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(u32, "12a"));
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(i32, "--1"));
}

test "jzon: integer, sinkError renames no space left to its own name" {
    const err = sinkError(error.Jzon_Sink_NoSpaceLeft);

    try std.testing.expectEqual(Error.Jzon_Integer_NoSpaceLeft, err);
}

test "jzon: integer, both paths carry the extremes of every width" {
    inline for (WIDTHS) |Value| {
        const extremes = [_]Value{
            std.math.minInt(Value),
            std.math.maxInt(Value),
            0,
        };

        for (extremes) |value| {
            var expected: [64]u8 = undefined;
            const reference = try std.fmt.bufPrint(&expected, "{d}", .{value});

            try expectBothPaths(reference, value);
        }
    }
}

test "jzon: integer, digits fit a buffer of exactly their count" {
    var exact: [3]u8 = undefined;
    var fits: Sink = .init(&exact);
    try appendTable(&fits, @as(u8, 255));

    try std.testing.expectEqualStrings("255", fits.filled());
    try std.testing.expectEqual(@as(usize, 0), fits.remaining());

    var exact_fmt: [4]u8 = undefined;
    var fits_fmt: Sink = .init(&exact_fmt);
    try appendFmt(&fits_fmt, @as(i8, -128));

    try std.testing.expectEqualStrings("-128", fits_fmt.filled());
    try std.testing.expectEqual(@as(usize, 0), fits_fmt.remaining());
}

test "jzon: integer, appendTable one byte short is no space left" {
    var buf: [2]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(
        Error.Jzon_Integer_NoSpaceLeft,
        appendTable(&sink, @as(u16, 255)),
    );
    try std.testing.expectEqual(@as(usize, 0), sink.written());
}

test "jzon: integer, appendFmt one byte short is no space left" {
    var buf: [2]u8 = undefined;
    var sink: Sink = .init(&buf);

    try std.testing.expectError(
        Error.Jzon_Integer_NoSpaceLeft,
        appendFmt(&sink, @as(u16, 255)),
    );
    try std.testing.expectEqual(@as(usize, 0), sink.written());
}

test "jzon: integer, appendTable into a full buffer is no space left" {
    var buf: [2]u8 = undefined;
    var sink: Sink = .init(&buf);
    try sink.bytes("ab");

    try std.testing.expectError(Error.Jzon_Integer_NoSpaceLeft, appendTable(&sink, @as(u8, 0)));
}

test "jzon: integer, appendFmt into a full buffer is no space left" {
    var buf: [2]u8 = undefined;
    var sink: Sink = .init(&buf);
    try sink.bytes("ab");

    try std.testing.expectError(Error.Jzon_Integer_NoSpaceLeft, appendFmt(&sink, @as(u8, 0)));
}

test "jzon: integer, parse carries the extremes of its target type" {
    try std.testing.expectEqual(@as(u8, 0), try parse(u8, "0"));
    try std.testing.expectEqual(@as(u8, 255), try parse(u8, "255"));
    try std.testing.expectEqual(@as(i8, 127), try parse(i8, "127"));
    try std.testing.expectEqual(@as(i8, -128), try parse(i8, "-128"));
    try std.testing.expectEqual(
        @as(u64, std.math.maxInt(u64)),
        try parse(u64, "18446744073709551615"),
    );
    try std.testing.expectEqual(
        @as(i64, std.math.minInt(i64)),
        try parse(i64, "-9223372036854775808"),
    );
}

test "jzon: integer, parse one past the target type is bad number" {
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(u8, "256"));
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(i8, "128"));
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(i8, "-129"));
    try std.testing.expectError(
        Error.Jzon_Integer_BadNumber,
        parse(u64, "18446744073709551616"),
    );
    try std.testing.expectError(
        Error.Jzon_Integer_BadNumber,
        parse(i64, "9223372036854775808"),
    );
    try std.testing.expectError(
        Error.Jzon_Integer_BadNumber,
        parse(i64, "-9223372036854775809"),
    );
}

test "jzon: integer, parse of a negative value for an unsigned type is bad number" {
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(u8, "-1"));
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(u64, "-0"));
}

test "jzon: integer, parse with a leading zero RFC8259 does not allow is bad number" {
    try std.testing.expectEqual(@as(u32, 0), try parse(u32, "0"));
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(u32, "00"));
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(u32, "007"));
    try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(i32, "-01"));
}

test "jzon: integer, parse of text that is not a whole number is bad number" {
    const samples = [_][]const u8{
        "",
        "-",
        "+1",
        " 1",
        "1 ",
        "1.0",
        "1e2",
        "0x10",
        "1_000",
        "--1",
    };

    for (samples) |sample| {
        try std.testing.expectError(Error.Jzon_Integer_BadNumber, parse(i32, sample));
    }
}

test "jzon: integer, maxDigits bounds the widest value of every width" {
    inline for (WIDTHS) |Value| {
        var buf: [maxDigits(Value)]u8 = undefined;

        var lowest: Sink = .init(&buf);
        try appendTable(&lowest, @as(Value, std.math.minInt(Value)));

        try std.testing.expect(lowest.written() <= maxDigits(Value));

        var highest: Sink = .init(&buf);
        try appendTable(&highest, @as(Value, std.math.maxInt(Value)));

        try std.testing.expect(highest.written() <= maxDigits(Value));
    }
}

