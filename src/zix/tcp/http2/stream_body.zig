//! ZIX Http2 stream_body
//!
//! ### file: src/zix/tcp/http2/stream_body.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Whether a request body is whole: the declared content-length against the
//! DATA payload bytes that arrived (RFC 9113 section 8.1.1).
//!
//! ### note:
//!
//! - The count compared is the DATA payload before any content-encoding is
//!   undone. content-length describes the bytes on the wire.
//! - A request with no content-length is whole at END_STREAM by definition.
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
const Declared = @import("declared.zig").Declared;
const Header = @import("hpack/Header.zig");

// --------------------------------------------------------- //
// Private:

/// Longest decimal a u64 byte count can occupy, so an absurd run of digits is
/// rejected on length before any arithmetic runs.
const MAX_DIGITS: usize = 20;

/// Length of the header name looked for, checked before the compare so every
/// other header costs one integer test.
const CONTENT_LENGTH_NAME_LEN: usize = "content-length".len;

/// Parse a header value as a plain decimal byte count.
///
/// Note:
/// - Strict on purpose: a general integer parser also accepts a sign and digit
///   separators, which would let `+40` or `1_0` pass as a length.
///
/// Param:
/// value - []const u8 (the raw header value)
///
/// Return:
/// - ?u64 (null when the value is not a bare decimal number or overflows u64)
fn parseDecimal(value: []const u8) ?u64 {
    if (value.len == 0 or value.len > MAX_DIGITS) return null;

    var total: u64 = 0;
    for (value) |digit| {
        if (digit < '0' or digit > '9') return null;

        total = std.math.mul(u64, total, 10) catch |err| switch (err) {
            error.Overflow => return null,
        };
        total = std.math.add(u64, total, digit - '0') catch |err| switch (err) {
            error.Overflow => return null,
        };
    }

    return total;
}

// --------------------------------------------------------- //
// Public:

/// Read the content-length a request declared.
///
/// Note:
/// - Repeats of the same value count as one declaration, which is what a proxy
///   that re-emits the header produces. Two different values report BROKEN.
///
/// Param:
/// headers - []const Header (the stream's decoded request headers)
///
/// Return:
/// - Declared.ABSENT when no content-length header is present
/// - Declared.LENGTH when one usable value was declared
/// - Declared.BROKEN when a value is not a bare decimal or two values disagree
pub fn declared(headers: []const Header) Declared {
    var found: ?u64 = null;

    for (headers) |header| {
        if (header.name.len != CONTENT_LENGTH_NAME_LEN) continue;
        if (!std.ascii.eqlIgnoreCase(header.name, "content-length")) continue;

        const value = parseDecimal(header.value) orelse return .BROKEN;
        if (found) |first| {
            if (first != value) return .BROKEN;
        } else {
            found = value;
        }
    }

    if (found) |value| return .{ .LENGTH = value };

    return .ABSENT;
}

/// Whether the DATA bytes that arrived complete the declared body. Asked once,
/// when END_STREAM closes the request side of a stream.
///
/// Param:
/// headers - []const Header (the stream's decoded request headers)
/// received - usize (DATA payload bytes accumulated for the stream)
///
/// Return:
/// - true when the request may be served
/// - false when it is malformed and its stream must be reset
pub fn isWhole(headers: []const Header, received: usize) bool {
    return switch (declared(headers)) {
        .ABSENT => true,
        .LENGTH => |promised| promised == received,
        .BROKEN => false,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2: stream_body, no content-length is whole at any count" {
    const headers = [_]Header{
        .{
            .name = ":method",
            .value = "POST",
        },
        .{
            .name = ":path",
            .value = "/upload",
        },
    };

    try std.testing.expectEqual(Declared.ABSENT, declared(&headers));
    try std.testing.expect(isWhole(&headers, 0));
    try std.testing.expect(isWhole(&headers, 4096));
}

test "zix http2: stream_body, content-length is whole only at the exact count" {
    const headers = [_]Header{
        .{
            .name = "content-length",
            .value = "100",
        },
    };

    try std.testing.expectEqual(@as(u64, 100), declared(&headers).LENGTH);
    try std.testing.expect(isWhole(&headers, 100));
    try std.testing.expect(!isWhole(&headers, 99));
    try std.testing.expect(!isWhole(&headers, 0));
    try std.testing.expect(!isWhole(&headers, 101));
}

test "zix http2: stream_body, content-length zero is malformed with a body" {
    const headers = [_]Header{
        .{
            .name = "content-length",
            .value = "0",
        },
    };

    try std.testing.expectEqual(@as(u64, 0), declared(&headers).LENGTH);
    try std.testing.expect(isWhole(&headers, 0));
    try std.testing.expect(!isWhole(&headers, 1));
}

test "zix http2: stream_body, content-length not a bare decimal is broken" {
    const rejected = [_][]const u8{
        "+40", "-40", "1_0", " 40", "40 ", "40b", "0x28", "", "abc",
    };

    for (rejected) |value| {
        const headers = [_]Header{
            .{
                .name = "content-length",
                .value = value,
            },
        };

        try std.testing.expectEqual(Declared.BROKEN, declared(&headers));
        try std.testing.expect(!isWhole(&headers, 40));
    }
}

test "zix http2: stream_body, content-length past u64 is broken" {
    const headers = [_]Header{
        .{
            .name = "content-length",
            .value = "99999999999999999999",
        },
    };

    try std.testing.expectEqual(Declared.BROKEN, declared(&headers));
    try std.testing.expect(!isWhole(&headers, 0));
}

test "zix http2: stream_body, content-length with too many digits is broken" {
    const headers = [_]Header{
        .{
            .name = "content-length",
            .value = "000000000000000000001",
        },
    };

    try std.testing.expectEqual(Declared.BROKEN, declared(&headers));
}

test "zix http2: stream_body, repeated equal content-length counts once" {
    const headers = [_]Header{
        .{
            .name = "content-length",
            .value = "12",
        },
        .{
            .name = "content-length",
            .value = "12",
        },
    };

    try std.testing.expectEqual(@as(u64, 12), declared(&headers).LENGTH);
    try std.testing.expect(isWhole(&headers, 12));
}

test "zix http2: stream_body, disagreeing content-length is broken" {
    const headers = [_]Header{
        .{
            .name = "content-length",
            .value = "12",
        },
        .{
            .name = "content-length",
            .value = "13",
        },
    };

    try std.testing.expectEqual(Declared.BROKEN, declared(&headers));
    try std.testing.expect(!isWhole(&headers, 12));
    try std.testing.expect(!isWhole(&headers, 13));
}

test "zix http2: stream_body, content-length name ignores case" {
    const headers = [_]Header{
        .{
            .name = "Content-Length",
            .value = "7",
        },
    };

    try std.testing.expectEqual(@as(u64, 7), declared(&headers).LENGTH);
    try std.testing.expect(isWhole(&headers, 7));
}

test "zix http2: stream_body, same-length name is not content-length" {
    const headers = [_]Header{
        .{
            .name = "content-lengthx",
            .value = "9",
        },
        .{
            .name = "if-none-match!",
            .value = "9",
        },
    };

    try std.testing.expectEqual(Declared.ABSENT, declared(&headers));
    try std.testing.expect(isWhole(&headers, 0));
}

test "zix http2: stream_body, empty header list declares nothing" {
    const headers = [_]Header{};

    try std.testing.expectEqual(Declared.ABSENT, declared(&headers));
    try std.testing.expect(isWhole(&headers, 0));
}

