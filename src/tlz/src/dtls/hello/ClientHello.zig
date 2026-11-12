//! TLZ dtls hello ClientHello
//!
//! ### file: src/tlz/src/dtls/hello/ClientHello.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! A parsed DTLS ClientHello body (RFC 6347 4.2.1), borrowing the caller's bytes.
//!
//! ### note:
//!
//! Only `random` is copied, every slice points into the receive buffer. The cookie
//! sits between session_id and cipher_suites, which is why the TLS parser cannot be
//! reused.
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

client_version: u16,
random: [32]u8,
session_id: []const u8,
/// Empty on the first ClientHello, filled on the one that answers a
/// HelloVerifyRequest.
cookie: []const u8,
/// A flat run of 2-byte suite values.
cipher_suites: []const u8,
compression_methods: []const u8,
/// Raw extensions block, empty when the hello carried none.
extensions: []const u8,
/// The whole body, the span `paramsForCookie` cuts from.
body: []const u8,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// The bytes a cookie binds: every field the client must repeat verbatim.
///
/// Note:
/// - The cookie itself is cut out, since the second hello carries a cookie the
///   first did not, and binding it would make the check circular.
///
/// Return:
/// - []const u8 (version, random, and session_id, in wire order)
pub fn paramsForCookie(self: *const Self) []const u8 {
    return self.body[0 .. 2 + 32 + 1 + self.session_id.len];
}

/// Whether this hello answers a HelloVerifyRequest.
///
/// Return:
/// - bool
pub fn hasCookie(self: *const Self) bool {
    return self.cookie.len > 0;
}

/// Whether a cipher suite was offered.
///
/// Param:
/// suite - u16 (the suite value to look for)
///
/// Return:
/// - bool
pub fn offersCipherSuite(self: *const Self, suite: u16) bool {
    var pos: usize = 0;
    while (pos + 2 <= self.cipher_suites.len) : (pos += 2) {
        if (std.mem.readInt(u16, self.cipher_suites[pos..][0..2], .big) == suite) return true;
    }

    return false;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// version, random, a 2-byte session_id, then an empty cookie length.
const TEST_BODY = [_]u8{ 0xFE, 0xFD } ++ @as([32]u8, @splat(0x11)) ++ [_]u8{ 2, 0xAA, 0xBB, 0 };

fn testHello(cipher_suites: []const u8, cookie: []const u8) Self {
    return .{
        .client_version = 0xFEFD,
        .random = @splat(0x11),
        .session_id = TEST_BODY[35..37],
        .cookie = cookie,
        .cipher_suites = cipher_suites,
        .compression_methods = &[_]u8{0},
        .extensions = "",
        .body = &TEST_BODY,
    };
}

test "tlz dtls hello: ClientHello, paramsForCookie spans version random and session_id" {
    const hello = testHello(&[_]u8{ 0xC0, 0x2B }, "");

    try std.testing.expectEqual(@as(usize, 2 + 32 + 1 + 2), hello.paramsForCookie().len);
    try std.testing.expectEqualSlices(u8, TEST_BODY[0..37], hello.paramsForCookie());
}

test "tlz dtls hello: ClientHello, hasCookie is false for an empty cookie" {
    try std.testing.expect(!testHello(&[_]u8{ 0xC0, 0x2B }, "").hasCookie());
}

test "tlz dtls hello: ClientHello, hasCookie is true for a cookie" {
    try std.testing.expect(testHello(&[_]u8{ 0xC0, 0x2B }, "c").hasCookie());
}

test "tlz dtls hello: ClientHello, offersCipherSuite finds every listed suite" {
    const hello = testHello(&[_]u8{ 0xC0, 0x2B, 0x00, 0x9C }, "");

    try std.testing.expect(hello.offersCipherSuite(0xC02B));
    try std.testing.expect(hello.offersCipherSuite(0x009C));
}

test "tlz dtls hello: ClientHello, offersCipherSuite misses an unlisted suite" {
    const hello = testHello(&[_]u8{ 0xC0, 0x2B }, "");

    try std.testing.expect(!hello.offersCipherSuite(0x1301));
}

test "tlz dtls hello: ClientHello, offersCipherSuite on an empty list is false" {
    try std.testing.expect(!testHello("", "").offersCipherSuite(0xC02B));
}

