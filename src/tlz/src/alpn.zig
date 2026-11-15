//! TLZ alpn
//!
//! ### file: src/tlz/src/alpn.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! ALPN protocols tlz can negotiate over TLS (RFC 7301).
//!
//! ### note:
//!
//! The set is closed. h3 is QUIC ALPN, a different layer, so it is not listed.
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
// Public:

/// One protocol the server can select.
pub const Alpn = enum(u8) {
    HTTP_1_1,
    H2,

    /// The ProtocolName bytes carried in the ALPN extension.
    ///
    /// Return:
    /// - []const u8
    pub fn token(self: Alpn) []const u8 {
        return switch (self) {
            .HTTP_1_1 => "http/1.1",
            .H2 => "h2",
        };
    }
};

/// The byte length of a ProtocolNameList body that lists every protocol once.
pub const MAX_PROTOCOL_LIST_LEN: usize = blk: {
    var total: usize = 0;
    for (std.enums.values(Alpn)) |protocol| total += 1 + protocol.token().len;

    break :blk total;
};

/// Write protocols as one ProtocolNameList body (RFC 7301 3.1): each name is one
/// length byte followed by its token, with no outer two byte length.
///
/// Param:
/// prefs - []const Alpn (the protocols in preference order)
/// buf - []u8 (the output buffer)
///
/// Return:
/// - []const u8 (the encoded list inside `buf`, empty when `prefs` is empty)
/// - null when `buf` is too small
pub fn encodeProtocolList(prefs: []const Alpn, buf: []u8) ?[]const u8 {
    var len: usize = 0;

    for (prefs) |protocol| {
        const token = protocol.token();
        if (len + 1 + token.len > buf.len) return null;

        buf[len] = @intCast(token.len);
        @memcpy(buf[len + 1 ..][0..token.len], token);
        len += 1 + token.len;
    }

    return buf[0..len];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz: alpn, HTTP_1_1 token is http/1.1" {
    try std.testing.expectEqualStrings("http/1.1", Alpn.HTTP_1_1.token());
}

test "tlz: alpn, H2 token is h2" {
    try std.testing.expectEqualStrings("h2", Alpn.H2.token());
}

test "tlz: alpn, encodeProtocolList writes length prefixed names in order" {
    var buf: [MAX_PROTOCOL_LIST_LEN]u8 = undefined;

    const list = encodeProtocolList(&.{ .H2, .HTTP_1_1 }, &buf).?;

    try std.testing.expectEqualSlices(u8, "\x02h2\x08http/1.1", list);
}

test "tlz: alpn, encodeProtocolList with no protocols is empty" {
    var buf: [MAX_PROTOCOL_LIST_LEN]u8 = undefined;

    const list = encodeProtocolList(&.{}, &buf).?;

    try std.testing.expectEqual(@as(usize, 0), list.len);
}

test "tlz: alpn, encodeProtocolList past the buffer is null" {
    var buf: [3]u8 = undefined;

    try std.testing.expect(encodeProtocolList(&.{ .H2, .HTTP_1_1 }, &buf) == null);
}

test "tlz: alpn, MAX_PROTOCOL_LIST_LEN fits every protocol once" {
    var buf: [MAX_PROTOCOL_LIST_LEN]u8 = undefined;

    const list = encodeProtocolList(std.enums.values(Alpn), &buf).?;

    try std.testing.expectEqual(MAX_PROTOCOL_LIST_LEN, list.len);
}

test "tlz: alpn, every token fits one ProtocolName length byte" {
    for (std.enums.values(Alpn)) |protocol| {
        const len = protocol.token().len;

        try std.testing.expect(len > 0 and len <= 255);
    }
}

