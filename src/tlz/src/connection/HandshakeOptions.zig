//! TLZ connection HandshakeOptions
//!
//! ### file: src/tlz/src/connection/HandshakeOptions.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What the caller supplies to drive one TLS 1.3 server handshake: the identity,
//! the per-connection randoms, and the ALPN and curve policy.
//!
//! ### note:
//!
//! The randoms are injected, so a handshake is deterministic given its inputs. In
//! production they are fresh per connection.
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
const rsa = @import("../crypto/rsa.zig");
const handshake = @import("../handshake.zig");
const SigningKey = @import("../crypto/certificate/signing_key.zig").SigningKey;
const Alpn = @import("../alpn.zig").Alpn;
const NamedGroup = @import("../named_group.zig").NamedGroup;

// --------------------------------------------------------- //
// Fields:

/// The end-entity certificate DER, borrowed.
certificate_der: []const u8,
/// The CertificateVerify signing key. Its scheme must be one the client offered.
signing_key: SigningKey,
/// The ephemeral ECDHE private key.
ephemeral_secret: [32]u8,
/// The ServerHello random.
server_random: [32]u8,
/// The salt for an RSA PSS CertificateVerify (RFC 8017 9.1). Ignored by ECDSA and
/// Ed25519.
pss_salt: [rsa.PSS_SALT_LEN]u8 = std.mem.zeroes([rsa.PSS_SALT_LEN]u8),
/// Server ALPN preference order (RFC 7301). Empty disables ALPN.
alpn_prefs: []const Alpn = &.{},
/// Server curve preference order. negotiate picks the first the client also offered.
group_prefs: []const NamedGroup = &handshake.SERVER_GROUP_PREFS,
/// mTLS: send a CertificateRequest (RFC 8446 4.3.2) in the server flight.
request_client_cert: bool = false,

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz connection: HandshakeOptions, defaults keep ALPN and mTLS off" {
    const opts: Self = .{
        .certificate_der = &.{},
        .signing_key = .{ .rsa = .{} },
        .ephemeral_secret = @splat(0),
        .server_random = @splat(0),
    };

    try std.testing.expectEqual(@as(usize, 0), opts.alpn_prefs.len);
    try std.testing.expect(!opts.request_client_cert);
}

test "tlz connection: HandshakeOptions, default groups follow the server order" {
    const opts: Self = .{
        .certificate_der = &.{},
        .signing_key = .{ .rsa = .{} },
        .ephemeral_secret = @splat(0),
        .server_random = @splat(0),
    };
    const expected = &handshake.SERVER_GROUP_PREFS;

    try std.testing.expectEqualSlices(NamedGroup, expected, opts.group_prefs);
}

test "tlz connection: HandshakeOptions, default PSS salt is zero" {
    const opts: Self = .{
        .certificate_der = &.{},
        .signing_key = .{ .rsa = .{} },
        .ephemeral_secret = @splat(0),
        .server_random = @splat(0),
    };

    try std.testing.expectEqualSlices(u8, &std.mem.zeroes([rsa.PSS_SALT_LEN]u8), &opts.pss_salt);
}

