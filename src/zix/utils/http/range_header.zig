//! ZIX utils http range parser
//!
//! ### file: src/zix/utils/http/range_header.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Read the Range request header (RFC 7233) and clamp it to a file length.
//!
//! ### note:
//!
//! Split in two on purpose. A malformed header must be ignored (serve 200),
//! while a valid header past the end of the file is a 416. parseSpec tells
//! them apart, resolve handles the length.
//! Only the first range of a multi-range request is read.
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
const Range = @import("Range.zig");
const RangeSpec = @import("RangeSpec.zig");

// --------------------------------------------------------- //
// Private:

/// Unit prefix every supported Range value starts with.
const BYTES_PREFIX = "bytes=";

/// Parse one decimal number of a range.
///
/// Return:
/// - u64
/// - null when the text is not a decimal number
fn parseNumber(text: []const u8) ?u64 {
    return std.fmt.parseInt(u64, text, 10) catch |err| switch (err) {
        error.Overflow,
        error.InvalidCharacter,
        => null,
    };
}

// --------------------------------------------------------- //
// Public:

/// Read a `Range: bytes=start-end` header value.
///
/// Note:
/// - A suffix range (`bytes=-500`) is not supported and parses as null, so
///   the caller serves the whole file.
///
/// Param:
/// value - []const u8 (raw header value, `bytes=` prefix included)
///
/// Return:
/// - RangeSpec (valid syntax, not yet checked against any length)
/// - null when the header is malformed, which the caller treats as no range
pub fn parseSpec(value: []const u8) ?RangeSpec {
    const trimmed = std.mem.trim(u8, value, " \t");
    if (!std.mem.startsWith(u8, trimmed, BYTES_PREFIX)) return null;

    const spec = trimmed[BYTES_PREFIX.len..];
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return null;
    const first_end = std.mem.indexOfScalar(u8, spec, ',') orelse spec.len;
    if (dash > first_end) return null;

    const start_text = spec[0..dash];
    const end_text = spec[dash + 1 .. first_end];
    if (start_text.len == 0) return null;

    const start = parseNumber(start_text) orelse return null;
    if (end_text.len == 0) return .{
        .start = start,
        .end = null,
    };

    const end = parseNumber(end_text) orelse return null;
    if (end < start) return null;

    return .{
        .start = start,
        .end = end,
    };
}

/// Clamp a spec to a known length.
///
/// Note:
/// - An end past the last byte is clamped, not refused (RFC 7233 section 2.1).
///
/// Param:
/// spec - RangeSpec (from parseSpec)
/// total - u64 (file length in bytes)
///
/// Return:
/// - Range (satisfiable, inclusive)
/// - null when the range cannot be satisfied, which is a 416
pub fn resolve(spec: RangeSpec, total: u64) ?Range {
    if (total == 0) return null;
    if (spec.start >= total) return null;

    const end = if (spec.end) |asked| @min(asked, total - 1) else total - 1;

    return .{
        .start = spec.start,
        .end = end,
    };
}

/// Read and clamp in one step.
///
/// Param:
/// value - []const u8 (raw header value)
/// total - u64 (file length in bytes)
///
/// Return:
/// - Range (satisfiable, inclusive)
/// - null when the header is malformed or the range is unsatisfiable
pub fn parse(value: []const u8, total: u64) ?Range {
    const spec = parseSpec(value) orelse return null;

    return resolve(spec, total);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils http: range_header, parseSpec reads a closed range" {
    const spec = parseSpec("bytes=0-499").?;

    try std.testing.expectEqual(@as(u64, 0), spec.start);
    try std.testing.expectEqual(@as(u64, 499), spec.end.?);
}

test "zix utils http: range_header, parseSpec reads an open ended range" {
    const spec = parseSpec("bytes=500-").?;

    try std.testing.expectEqual(@as(u64, 500), spec.start);
    try std.testing.expect(spec.end == null);
}

test "zix utils http: range_header, parseSpec tolerates surrounding whitespace" {
    const spec = parseSpec("  bytes=2-5 ").?;

    try std.testing.expectEqual(@as(u64, 2), spec.start);
    try std.testing.expectEqual(@as(u64, 5), spec.end.?);
}

test "zix utils http: range_header, parseSpec takes the first of a multi range" {
    const spec = parseSpec("bytes=0-49,100-149").?;

    try std.testing.expectEqual(@as(u64, 0), spec.start);
    try std.testing.expectEqual(@as(u64, 49), spec.end.?);
}

test "zix utils http: range_header, parseSpec wrong unit is null" {
    try std.testing.expect(parseSpec("items=0-10") == null);
}

test "zix utils http: range_header, parseSpec without a dash is null" {
    try std.testing.expect(parseSpec("bytes=0") == null);
}

test "zix utils http: range_header, parseSpec suffix range is null" {
    try std.testing.expect(parseSpec("bytes=-500") == null);
}

test "zix utils http: range_header, parseSpec reversed range is null" {
    try std.testing.expect(parseSpec("bytes=10-5") == null);
}

test "zix utils http: range_header, parseSpec non numeric is null" {
    try std.testing.expect(parseSpec("bytes=a-b") == null);
}

test "zix utils http: range_header, parseSpec empty value is null" {
    try std.testing.expect(parseSpec("") == null);
}

test "zix utils http: range_header, parseSpec number past u64 is null" {
    try std.testing.expect(parseSpec("bytes=99999999999999999999-") == null);
}

test "zix utils http: range_header, resolve clamps an end past the last byte" {
    const range = resolve(.{
        .start = 0,
        .end = 999,
    }, 200).?;

    try std.testing.expectEqual(@as(u64, 199), range.end);
    try std.testing.expectEqual(@as(u64, 200), range.length());
}

test "zix utils http: range_header, resolve fills an open end from the length" {
    const range = resolve(.{
        .start = 100,
        .end = null,
    }, 200).?;

    try std.testing.expectEqual(@as(u64, 199), range.end);
    try std.testing.expectEqual(@as(u64, 100), range.length());
}

test "zix utils http: range_header, resolve start at the length is null" {
    try std.testing.expect(resolve(.{
        .start = 200,
        .end = null,
    }, 200) == null);
}

test "zix utils http: range_header, resolve start past the length is null" {
    try std.testing.expect(resolve(.{
        .start = 201,
        .end = 300,
    }, 200) == null);
}

test "zix utils http: range_header, resolve empty file is null" {
    try std.testing.expect(resolve(.{
        .start = 0,
        .end = null,
    }, 0) == null);
}

test "zix utils http: range_header, resolve keeps a single byte" {
    const range = resolve(.{
        .start = 5,
        .end = 5,
    }, 10).?;

    try std.testing.expectEqual(@as(u64, 1), range.length());
}

test "zix utils http: range_header, parse combines both steps" {
    const range = parse("bytes=2-5", 10).?;

    try std.testing.expectEqual(@as(u64, 2), range.start);
    try std.testing.expectEqual(@as(u64, 5), range.end);
}

test "zix utils http: range_header, parse unsatisfiable is null" {
    try std.testing.expect(parse("bytes=99-", 10) == null);
}

test "zix utils http: range_header, parse malformed is null" {
    try std.testing.expect(parse("garbage", 10) == null);
}

