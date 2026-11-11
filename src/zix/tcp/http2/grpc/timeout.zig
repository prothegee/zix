//! ZIX Http2 Grpc timeout
//!
//! ### file: src/zix/tcp/http2/grpc/timeout.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Parse the grpc-timeout header value (`<digits><unit>`) to nanoseconds.
//!
//! ### note:
//!
//! Units are case-sensitive: `M` is minutes, `m` is milliseconds.
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

// --------------------------------------------------------- //
// Private:

const NS_PER_HOUR: u64 = 3_600_000_000_000;
const NS_PER_MINUTE: u64 = 60_000_000_000;
const NS_PER_SECOND: u64 = 1_000_000_000;
const NS_PER_MILLI: u64 = 1_000_000;
const NS_PER_MICRO: u64 = 1_000;
const NS_PER_NANO: u64 = 1;

/// Nanoseconds in one unit, or null for an unknown unit character.
fn unitScale(unit_char: u8) ?u64 {
    return switch (unit_char) {
        'H' => NS_PER_HOUR,
        'M' => NS_PER_MINUTE,
        'S' => NS_PER_SECOND,
        'm' => NS_PER_MILLI,
        'u' => NS_PER_MICRO,
        'n' => NS_PER_NANO,
        else => null,
    };
}

/// ASCII digits (0-9 only) to a number, or null on any other byte.
/// The caller caps the length at `MAX_DIGITS`, so the sum fits u64.
fn parseDigits(num_str: []const u8) ?u64 {
    var num: u64 = 0;

    for (num_str) |byte| {
        if (!std.ascii.isDigit(byte)) return null;

        num = num * 10 + (byte - '0');
    }

    return num;
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixHttp2_GrpcTimeout_InvalidFormat,
    ZixHttp2_GrpcTimeout_TooManyDigits,
    ZixHttp2_GrpcTimeout_InvalidNumber,
    ZixHttp2_GrpcTimeout_NotPositive,
    ZixHttp2_GrpcTimeout_InvalidUnit,
    ZixHttp2_GrpcTimeout_Overflow,
};

/// Most digits a grpc-timeout value may carry (gRPC over HTTP/2 spec).
pub const MAX_DIGITS: usize = 8;

/// Parse a grpc-timeout header value to nanoseconds.
///
/// Note:
/// - Unit characters: H - hours, M - minutes, S - seconds, m - milliseconds,
///   u - microseconds, n - nanoseconds.
///
/// Param:
/// value - []const u8 (header value, e.g. `100m`)
///
/// Return:
/// - u64 (timeout in nanoseconds)
/// - InvalidFormat when value is shorter than one digit plus the unit
/// - TooManyDigits when the number is past `MAX_DIGITS`
/// - InvalidNumber when the number has a byte other than 0-9
/// - NotPositive when the number is zero
/// - InvalidUnit when the last character is not a known unit
/// - Overflow when the nanoseconds do not fit u64
pub fn parseTimeout(value: []const u8) Error!u64 {
    if (value.len < 2) return Error.ZixHttp2_GrpcTimeout_InvalidFormat;

    const num_str = value[0 .. value.len - 1];
    if (num_str.len > MAX_DIGITS) return Error.ZixHttp2_GrpcTimeout_TooManyDigits;

    const scale = unitScale(value[value.len - 1]) orelse {
        return Error.ZixHttp2_GrpcTimeout_InvalidUnit;
    };

    const num = parseDigits(num_str) orelse return Error.ZixHttp2_GrpcTimeout_InvalidNumber;
    if (num == 0) return Error.ZixHttp2_GrpcTimeout_NotPositive;

    return std.math.mul(u64, num, scale) catch |err| switch (err) {
        error.Overflow => Error.ZixHttp2_GrpcTimeout_Overflow,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const UnitCase = struct {
    value: []const u8,
    nanos: u64,
};

const UNIT_CASES = [_]UnitCase{
    .{
        .value = "2H",
        .nanos = 7_200_000_000_000,
    },
    .{
        .value = "3M",
        .nanos = 180_000_000_000,
    },
    .{
        .value = "1S",
        .nanos = 1_000_000_000,
    },
    .{
        .value = "100m",
        .nanos = 100_000_000,
    },
    .{
        .value = "500u",
        .nanos = 500_000,
    },
    .{
        .value = "1n",
        .nanos = 1,
    },
};

test "zix http2 grpc: parseTimeout, each unit scales to nanoseconds" {
    for (UNIT_CASES) |case| {
        try std.testing.expectEqual(case.nanos, try parseTimeout(case.value));
    }
}

test "zix http2 grpc: parseTimeout, leading zero keeps the value" {
    try std.testing.expectEqual(@as(u64, 5_000_000_000), try parseTimeout("05S"));
}

test "zix http2 grpc: parseTimeout, zero is NotPositive" {
    try std.testing.expectError(Error.ZixHttp2_GrpcTimeout_NotPositive, parseTimeout("0S"));
}

test "zix http2 grpc: parseTimeout, all zero digits are NotPositive" {
    try std.testing.expectError(
        Error.ZixHttp2_GrpcTimeout_NotPositive,
        parseTimeout("00000000S"),
    );
}

test "zix http2 grpc: parseTimeout, plus sign is InvalidNumber" {
    try std.testing.expectError(Error.ZixHttp2_GrpcTimeout_InvalidNumber, parseTimeout("+5S"));
}

test "zix http2 grpc: parseTimeout, underscore is InvalidNumber" {
    try std.testing.expectError(Error.ZixHttp2_GrpcTimeout_InvalidNumber, parseTimeout("1_0S"));
}

test "zix http2 grpc: parseTimeout, minus sign is InvalidNumber" {
    try std.testing.expectError(Error.ZixHttp2_GrpcTimeout_InvalidNumber, parseTimeout("-5S"));
}

test "zix http2 grpc: parseTimeout, MAX_DIGITS digits are accepted" {
    try std.testing.expectEqual(@as(u64, 99_999_999), try parseTimeout("99999999n"));
}

test "zix http2 grpc: parseTimeout, largest minutes value fits u64" {
    const nanos = try parseTimeout("99999999M");

    try std.testing.expectEqual(@as(u64, 5_999_999_940_000_000_000), nanos);
}

test "zix http2 grpc: parseTimeout, empty value is InvalidFormat" {
    try std.testing.expectError(Error.ZixHttp2_GrpcTimeout_InvalidFormat, parseTimeout(""));
}

test "zix http2 grpc: parseTimeout, unit without digits is InvalidFormat" {
    try std.testing.expectError(Error.ZixHttp2_GrpcTimeout_InvalidFormat, parseTimeout("S"));
}

test "zix http2 grpc: parseTimeout, past MAX_DIGITS is TooManyDigits" {
    try std.testing.expectError(
        Error.ZixHttp2_GrpcTimeout_TooManyDigits,
        parseTimeout("123456789S"),
    );
}

test "zix http2 grpc: parseTimeout, non-numeric digits are InvalidNumber" {
    try std.testing.expectError(Error.ZixHttp2_GrpcTimeout_InvalidNumber, parseTimeout("abcS"));
}

test "zix http2 grpc: parseTimeout, unknown unit is InvalidUnit" {
    try std.testing.expectError(Error.ZixHttp2_GrpcTimeout_InvalidUnit, parseTimeout("5X"));
}

test "zix http2 grpc: parseTimeout, lowercase s is InvalidUnit" {
    try std.testing.expectError(Error.ZixHttp2_GrpcTimeout_InvalidUnit, parseTimeout("5s"));
}

test "zix http2 grpc: parseTimeout, hours past u64 is Overflow" {
    try std.testing.expectError(Error.ZixHttp2_GrpcTimeout_Overflow, parseTimeout("99999999H"));
}

