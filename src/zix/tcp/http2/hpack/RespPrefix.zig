//! ZIX Http2 hpack RespPrefix
//!
//! ### file: src/zix/tcp/http2/hpack/RespPrefix.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! One cached response prefix: the HPACK bytes for a
//! [:status, content-type, content-encoding] triple.
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

// --------------------------------------------------------- //
// Fields:

/// Response status of the triple.
status: u16,
/// Used bytes of content_type.
content_type_len: u8,
/// Used bytes of content_encoding.
content_encoding_len: u8,
/// Used bytes of block.
block_len: u8,
/// content-type of the triple. Empty means the header is omitted.
content_type: [CONTENT_TYPE_MAX]u8,
/// content-encoding of the triple. Empty means the header is omitted.
content_encoding: [CONTENT_ENCODING_MAX]u8,
/// The encoded HPACK prefix.
block: [BLOCK_MAX]u8,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// Longest content-type that can be cached.
pub const CONTENT_TYPE_MAX: usize = 64;
/// Longest content-encoding that can be cached.
pub const CONTENT_ENCODING_MAX: usize = 32;
/// Longest encoded prefix that can be cached.
pub const BLOCK_MAX: usize = 96;

/// Whether this entry holds the given triple.
///
/// Param:
/// status - u16 (response status)
/// content_type - []const u8 (content-type, empty when omitted)
/// content_encoding - []const u8 (content-encoding, empty when omitted)
///
/// Return:
/// - bool
pub fn matches(
    self: *const Self,
    status: u16,
    content_type: []const u8,
    content_encoding: []const u8,
) bool {
    return self.status == status and
        std.mem.eql(u8, self.content_type[0..self.content_type_len], content_type) and
        std.mem.eql(u8, self.content_encoding[0..self.content_encoding_len], content_encoding);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn testPrefix(status: u16, content_type: []const u8, content_encoding: []const u8) Self {
    var prefix: Self = undefined;
    prefix.status = status;
    prefix.content_type_len = @intCast(content_type.len);
    prefix.content_encoding_len = @intCast(content_encoding.len);
    prefix.block_len = 0;
    @memcpy(prefix.content_type[0..content_type.len], content_type);
    @memcpy(prefix.content_encoding[0..content_encoding.len], content_encoding);

    return prefix;
}

test "zix http2 hpack: RespPrefix, matches the same triple" {
    const prefix = testPrefix(200, "text/plain", "br");

    try std.testing.expect(prefix.matches(200, "text/plain", "br"));
}

test "zix http2 hpack: RespPrefix, other status does not match" {
    const prefix = testPrefix(200, "text/plain", "");

    try std.testing.expect(!prefix.matches(404, "text/plain", ""));
}

test "zix http2 hpack: RespPrefix, other content-encoding does not match" {
    const prefix = testPrefix(200, "text/plain", "");

    try std.testing.expect(!prefix.matches(200, "text/plain", "br"));
}

test "zix http2 hpack: RespPrefix, empty triple matches empty input" {
    const prefix = testPrefix(204, "", "");

    try std.testing.expect(prefix.matches(204, "", ""));
}

