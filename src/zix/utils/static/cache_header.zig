//! ZIX utils static cache header
//!
//! ### file: src/zix/utils/static/cache_header.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Render the 200 header a cached static variant replays, and map a coding to
//! its variant index.
//!
//! ### note:
//!
//! Vary: Accept-Encoding is sent on every variant, identity included, so a
//! proxy never serves a compressed body to a client that did not ask for it.
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
const Encoding = @import("../http/encoding.zig").Encoding;

// --------------------------------------------------------- //
// Public:

/// Prerendered 200 header cap. The longest shape lands near 231 bytes.
pub const HEADER_MAX: usize = 256;

/// Variants a slot holds: identity plus the two precompressed siblings.
pub const VARIANT_COUNT: usize = 3;

/// Index of the variant that holds this coding.
///
/// Note:
/// - DEFLATE has no sibling file convention, so it maps to identity.
///
/// Param:
/// encoding - Encoding (the coding)
///
/// Return:
/// - usize (0 identity, 1 gzip, 2 br)
pub fn variantIndex(encoding: Encoding) usize {
    return switch (encoding) {
        .IDENTITY, .DEFLATE => 0,
        .GZIP => 1,
        .BR => 2,
    };
}

/// Render the 200 header for one variant.
///
/// Param:
/// buf - []u8 (output, HEADER_MAX bytes is enough)
/// content_type - []const u8 (MIME type)
/// size - u64 (body length)
/// encoding - Encoding (variant coding, identity sends no Content-Encoding)
///
/// Return:
/// - []u8 (the rendered slice inside buf)
/// - null when the header does not fit, which makes the variant uncacheable
pub fn render(buf: []u8, content_type: []const u8, size: u64, encoding: Encoding) ?[]u8 {
    if (encoding.contentEncoding()) |token| {
        return std.fmt.bufPrint(
            buf,
            "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n" ++
                "Content-Encoding: {s}\r\nAccept-Ranges: bytes\r\n" ++
                "Vary: Accept-Encoding\r\nConnection: keep-alive\r\n\r\n",
            .{ content_type, size, token },
        ) catch |err| switch (err) {
            error.NoSpaceLeft => null,
        };
    }

    return std.fmt.bufPrint(
        buf,
        "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n" ++
            "Accept-Ranges: bytes\r\nVary: Accept-Encoding\r\nConnection: keep-alive\r\n\r\n",
        .{ content_type, size },
    ) catch |err| switch (err) {
        error.NoSpaceLeft => null,
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils static: cache_header, render starts with the 200 line" {
    var buf: [HEADER_MAX]u8 = undefined;
    const plain = render(&buf, "text/html", 12, .IDENTITY).?;

    try std.testing.expect(std.mem.startsWith(u8, plain, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, plain, "\r\n\r\n"));
}

test "zix utils static: cache_header, render states the length" {
    var buf: [HEADER_MAX]u8 = undefined;
    const plain = render(&buf, "text/html", 12, .IDENTITY).?;

    try std.testing.expect(std.mem.indexOf(u8, plain, "Content-Length: 12\r\n") != null);
}

test "zix utils static: cache_header, render identity carries Vary" {
    var buf: [HEADER_MAX]u8 = undefined;
    const plain = render(&buf, "text/html", 12, .IDENTITY).?;

    try std.testing.expect(std.mem.indexOf(u8, plain, "Vary: Accept-Encoding\r\n") != null);
}

test "zix utils static: cache_header, render identity has no Content-Encoding" {
    var buf: [HEADER_MAX]u8 = undefined;
    const plain = render(&buf, "text/html", 12, .IDENTITY).?;

    try std.testing.expect(std.mem.indexOf(u8, plain, "Content-Encoding") == null);
}

test "zix utils static: cache_header, render br names its coding" {
    var buf: [HEADER_MAX]u8 = undefined;
    const compressed = render(&buf, "text/css", 7, .BR).?;

    try std.testing.expect(std.mem.indexOf(u8, compressed, "Content-Encoding: br\r\n") != null);
}

test "zix utils static: cache_header, render too small buffer is null" {
    var tiny: [8]u8 = undefined;

    try std.testing.expect(render(&tiny, "text/html", 12, .IDENTITY) == null);
}

test "zix utils static: cache_header, render longest shape fits HEADER_MAX" {
    var buf: [HEADER_MAX]u8 = undefined;
    const long_type: [40]u8 = @splat('x');

    try std.testing.expect(render(&buf, &long_type, std.math.maxInt(u64), .GZIP) != null);
}

test "zix utils static: cache_header, variantIndex separates the three codings" {
    try std.testing.expectEqual(@as(usize, 0), variantIndex(.IDENTITY));
    try std.testing.expectEqual(@as(usize, 1), variantIndex(.GZIP));
    try std.testing.expectEqual(@as(usize, 2), variantIndex(.BR));
}

test "zix utils static: cache_header, variantIndex deflate falls back to identity" {
    try std.testing.expectEqual(variantIndex(.IDENTITY), variantIndex(.DEFLATE));
}

