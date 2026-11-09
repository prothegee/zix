//! ZIX utils compression policy
//!
//! ### file: src/zix/utils/compression/policy.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Whether a response body is worth compressing, and the codings the server can
//! produce.
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
const Encoding = @import("../http/encoding.zig").Encoding;

// --------------------------------------------------------- //
// Private:

/// Media types that are already compressed. Compressing them again wastes CPU
/// and can grow the body.
const COMPRESSED_PREFIXES = [_][]const u8{
    "image/jpeg",
    "image/png",
    "image/gif",
    "image/webp",
    "image/avif",
    "video/",
    "audio/",
    "application/zip",
    "application/gzip",
    "application/x-gzip",
    "application/zstd",
    "application/x-brotli",
    "font/woff",
    "font/woff2",
};

fn startsWithIgnoreCase(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;

    return std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

fn isAlreadyCompressed(content_type: []const u8) bool {
    const semicolon = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    const media_type = std.mem.trim(u8, content_type[0..semicolon], " \t");

    for (COMPRESSED_PREFIXES) |prefix| {
        if (startsWithIgnoreCase(media_type, prefix)) return true;
    }

    return false;
}

// --------------------------------------------------------- //
// Public:

/// Default size floor: smaller bodies are sent as they are.
pub const MIN_SIZE_DEFAULT: usize = 256;

/// The codings the server can produce, in server preference order. identity is
/// always the implicit fallback. gzip leads, so brotli is served only when the
/// client prefers it (a higher q, or br as the only offered coding).
pub const supported_default = [_]Encoding{ .GZIP, .DEFLATE, .BR };

/// Whether a response body is worth compressing.
///
/// Param:
/// body_len - usize (uncompressed body length)
/// content_type - []const u8 (response Content-Type, parameters allowed)
/// min_size - usize (size floor)
///
/// Return:
/// - bool (true when compression should be applied)
pub fn shouldCompress(body_len: usize, content_type: []const u8, min_size: usize) bool {
    if (body_len < min_size) return false;
    if (isAlreadyCompressed(content_type)) return false;

    return true;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression: policy, below the floor is skipped" {
    try std.testing.expect(!shouldCompress(64, "text/html", MIN_SIZE_DEFAULT));
}

test "zix utils compression: policy, at the floor compresses" {
    try std.testing.expect(shouldCompress(MIN_SIZE_DEFAULT, "text/html", MIN_SIZE_DEFAULT));
}

test "zix utils compression: policy, compressed media types are skipped" {
    try std.testing.expect(!shouldCompress(4096, "image/jpeg", MIN_SIZE_DEFAULT));
    try std.testing.expect(!shouldCompress(4096, "video/mp4", MIN_SIZE_DEFAULT));
    try std.testing.expect(!shouldCompress(4096, "application/zip", MIN_SIZE_DEFAULT));
    try std.testing.expect(!shouldCompress(4096, "font/woff2", MIN_SIZE_DEFAULT));
}

test "zix utils compression: policy, content-type parameters are ignored" {
    try std.testing.expect(shouldCompress(4096, "text/html; charset=utf-8", MIN_SIZE_DEFAULT));
    try std.testing.expect(!shouldCompress(4096, "IMAGE/JPEG; quality=90", MIN_SIZE_DEFAULT));
}

test "zix utils compression: policy, empty content-type compresses" {
    try std.testing.expect(shouldCompress(4096, "", MIN_SIZE_DEFAULT));
}

test "zix utils compression: policy, supported_default leads with gzip" {
    try std.testing.expectEqualSlices(Encoding, &.{ .GZIP, .DEFLATE, .BR }, &supported_default);
}

