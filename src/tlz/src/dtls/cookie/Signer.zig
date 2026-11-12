//! TLZ dtls cookie Signer
//!
//! ### file: src/tlz/src/dtls/cookie/Signer.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Signs and verifies HelloVerifyRequest cookies for one DTLS server
//! (RFC 6347 4.2.1).
//!
//! ### note:
//!
//! Holds two secrets so a rotation does not break handshakes already in flight.
//! The cookie binds the peer IP address, not the port, so a NAT rebinding between
//! the two ClientHellos does not cost an extra round trip.
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
const cookie = @import("../cookie.zig");

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const IpAddress = std.Io.net.IpAddress;
const Cookie = cookie.Cookie;

// --------------------------------------------------------- //
// Fields:

/// The secret new cookies are signed with.
current: [cookie.SECRET_LEN]u8,
/// The secret before the last rotation, still accepted for one more period.
previous: ?[cookie.SECRET_LEN]u8 = null,

const Self = @This();

// --------------------------------------------------------- //
// Private:

/// HMAC(secret, family ++ address ++ client_params), the construction RFC 6347 4.2.1
/// recommends. The family byte keeps an ipv4 and an ipv6 peer apart.
fn sign(secret: [cookie.SECRET_LEN]u8, peer: IpAddress, client_params: []const u8) Cookie {
    var mac = HmacSha256.init(&secret);

    switch (peer) {
        .ip4 => |addr| {
            mac.update(&.{1});
            mac.update(&addr.bytes);
        },
        .ip6 => |addr| {
            mac.update(&.{2});
            mac.update(&addr.bytes);
        },
    }

    mac.update(client_params);

    var out: Cookie = undefined;
    mac.final(&out);

    return out;
}

// --------------------------------------------------------- //
// Public:

/// Build a signer from a caller-supplied secret.
///
/// Note:
/// - The secret has to be unpredictable, and sourcing it is the caller's job. This file
///   stays free of platform entropy calls so it compiles and tests the same everywhere.
///
/// Param:
/// secret - [cookie.SECRET_LEN]u8 (the first signing secret)
///
/// Return:
/// - Self
pub fn init(secret: [cookie.SECRET_LEN]u8) Self {
    return .{ .current = secret };
}

/// Take a new secret, keeping the old one valid for one more period.
///
/// Note:
/// - Call this on a timer, not per handshake. Rotating too fast makes legitimate clients
///   fail twice in a row, once for each stale secret.
///
/// Param:
/// secret - [cookie.SECRET_LEN]u8 (the next signing secret)
///
/// Return:
/// - void
pub fn rotate(self: *Self, secret: [cookie.SECRET_LEN]u8) void {
    self.previous = self.current;
    self.current = secret;
}

/// Cookie for a peer, under the current secret.
///
/// Param:
/// peer - std.Io.net.IpAddress (where the ClientHello came from)
/// client_params - []const u8 (the ClientHello fields the client must repeat verbatim)
///
/// Return:
/// - Cookie
pub fn generate(self: *const Self, peer: IpAddress, client_params: []const u8) Cookie {
    return sign(self.current, peer, client_params);
}

/// Whether a cookie is one this server issued for this peer and these parameters.
///
/// Note:
/// - Compares in constant time. A check that leaks how many bytes matched hands an
///   attacker a way to forge one byte at a time.
/// - false is the answer for a wrong length, a wrong peer, changed parameters, and a
///   secret that has aged out. The caller treats all of them as "no cookie".
///
/// Param:
/// peer - std.Io.net.IpAddress (where the ClientHello came from)
/// client_params - []const u8 (the ClientHello fields the cookie binds)
/// offered - []const u8 (the cookie the client echoed)
///
/// Return:
/// - bool
pub fn verify(
    self: *const Self,
    peer: IpAddress,
    client_params: []const u8,
    offered: []const u8,
) bool {
    if (offered.len != cookie.COOKIE_LEN) return false;

    const value: Cookie = offered[0..cookie.COOKIE_LEN].*;
    const current = sign(self.current, peer, client_params);

    if (std.crypto.timing_safe.eql(Cookie, current, value)) return true;

    if (self.previous) |secret| {
        return std.crypto.timing_safe.eql(Cookie, sign(secret, peer, client_params), value);
    }

    return false;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const TEST_SECRET: [cookie.SECRET_LEN]u8 = @splat(0x5A);
const TEST_PARAMS: []const u8 = "client hello parameters";

const TEST_PEER: IpAddress = .{
    .ip4 = .{
        .bytes = .{ 192, 0, 2, 1 },
        .port = 41000,
    },
};

test "tlz dtls cookie: Signer, a fresh cookie verifies against its peer" {
    const signer = init(TEST_SECRET);
    const issued = signer.generate(TEST_PEER, TEST_PARAMS);

    try std.testing.expect(signer.verify(TEST_PEER, TEST_PARAMS, &issued));
}

test "tlz dtls cookie: Signer, generation is repeatable" {
    const signer = init(TEST_SECRET);

    const first = signer.generate(TEST_PEER, TEST_PARAMS);
    const second = signer.generate(TEST_PEER, TEST_PARAMS);

    try std.testing.expectEqualSlices(u8, &first, &second);
}

test "tlz dtls cookie: Signer, another signer with the same secret verifies" {
    const issued = init(TEST_SECRET).generate(TEST_PEER, TEST_PARAMS);
    const other = init(TEST_SECRET);

    try std.testing.expect(other.verify(TEST_PEER, TEST_PARAMS, &issued));
}

test "tlz dtls cookie: Signer, a different ipv4 address does not verify" {
    const signer = init(TEST_SECRET);
    const issued = signer.generate(TEST_PEER, TEST_PARAMS);
    const other: IpAddress = .{
        .ip4 = .{
            .bytes = .{ 192, 0, 2, 2 },
            .port = 41000,
        },
    };

    try std.testing.expect(!signer.verify(other, TEST_PARAMS, &issued));
}

test "tlz dtls cookie: Signer, an ipv6 peer gets a cookie of its own" {
    const signer = init(TEST_SECRET);
    const issued = signer.generate(TEST_PEER, TEST_PARAMS);
    const ip6: IpAddress = .{
        .ip6 = .{
            .bytes = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
            .port = 41000,
        },
    };
    const ip6_cookie = signer.generate(ip6, TEST_PARAMS);

    try std.testing.expect(!signer.verify(ip6, TEST_PARAMS, &issued));
    try std.testing.expect(signer.verify(ip6, TEST_PARAMS, &ip6_cookie));
    try std.testing.expect(!std.mem.eql(u8, &issued, &ip6_cookie));
}

test "tlz dtls cookie: Signer, the port is not bound" {
    const signer = init(TEST_SECRET);
    const issued = signer.generate(TEST_PEER, TEST_PARAMS);
    const rebound: IpAddress = .{
        .ip4 = .{
            .bytes = TEST_PEER.ip4.bytes,
            .port = 41001,
        },
    };

    try std.testing.expect(signer.verify(rebound, TEST_PARAMS, &issued));
}

test "tlz dtls cookie: Signer, changed client parameters do not verify" {
    const signer = init(TEST_SECRET);
    const issued = signer.generate(TEST_PEER, TEST_PARAMS);

    try std.testing.expect(!signer.verify(TEST_PEER, "different parameters", &issued));
    try std.testing.expect(!signer.verify(TEST_PEER, "", &issued));
}

test "tlz dtls cookie: Signer, a flipped byte does not verify" {
    const signer = init(TEST_SECRET);
    var issued = signer.generate(TEST_PEER, TEST_PARAMS);

    issued[cookie.COOKIE_LEN - 1] ^= 0x01;
    try std.testing.expect(!signer.verify(TEST_PEER, TEST_PARAMS, &issued));

    issued[cookie.COOKIE_LEN - 1] ^= 0x01;
    issued[0] ^= 0x80;
    try std.testing.expect(!signer.verify(TEST_PEER, TEST_PARAMS, &issued));
}

test "tlz dtls cookie: Signer, a short or empty cookie does not verify" {
    const signer = init(TEST_SECRET);
    const issued = signer.generate(TEST_PEER, TEST_PARAMS);

    try std.testing.expect(!signer.verify(TEST_PEER, TEST_PARAMS, issued[0 .. issued.len - 1]));
    try std.testing.expect(!signer.verify(TEST_PEER, TEST_PARAMS, ""));
}

test "tlz dtls cookie: Signer, an all zero cookie does not verify" {
    const signer = init(TEST_SECRET);
    const all_zero: Cookie = @splat(0);

    try std.testing.expect(!signer.verify(TEST_PEER, TEST_PARAMS, &all_zero));
}

test "tlz dtls cookie: Signer, another secret issues cookies this server rejects" {
    const signer = init(TEST_SECRET);
    const forged = init(@splat(0xA5)).generate(TEST_PEER, TEST_PARAMS);

    try std.testing.expect(!signer.verify(TEST_PEER, TEST_PARAMS, &forged));
}

test "tlz dtls cookie: Signer, rotate keeps the previous secret usable" {
    var signer = init(TEST_SECRET);
    const issued_before = signer.generate(TEST_PEER, TEST_PARAMS);

    signer.rotate(@splat(0xB6));
    const issued_after = signer.generate(TEST_PEER, TEST_PARAMS);

    try std.testing.expect(signer.verify(TEST_PEER, TEST_PARAMS, &issued_before));
    try std.testing.expect(signer.verify(TEST_PEER, TEST_PARAMS, &issued_after));
    try std.testing.expect(!std.mem.eql(u8, &issued_before, &issued_after));
}

test "tlz dtls cookie: Signer, a second rotate ages the first secret out" {
    var signer = init(TEST_SECRET);
    const issued_first = signer.generate(TEST_PEER, TEST_PARAMS);

    signer.rotate(@splat(0xB6));
    const issued_second = signer.generate(TEST_PEER, TEST_PARAMS);
    signer.rotate(@splat(0xC7));

    try std.testing.expect(!signer.verify(TEST_PEER, TEST_PARAMS, &issued_first));
    try std.testing.expect(signer.verify(TEST_PEER, TEST_PARAMS, &issued_second));
}

test "tlz dtls cookie: Signer, one flipped secret bit changes the whole cookie" {
    var near_secret: [cookie.SECRET_LEN]u8 = TEST_SECRET;
    near_secret[0] ^= 0x01;

    const issued = init(TEST_SECRET).generate(TEST_PEER, TEST_PARAMS);
    const near = init(near_secret);
    const near_cookie = near.generate(TEST_PEER, TEST_PARAMS);

    try std.testing.expect(!std.mem.eql(u8, &issued, &near_cookie));
    try std.testing.expect(!near.verify(TEST_PEER, TEST_PARAMS, &issued));
}

