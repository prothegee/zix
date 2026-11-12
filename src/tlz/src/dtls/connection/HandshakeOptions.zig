//! TLZ dtls connection HandshakeOptions
//!
//! ### file: src/tlz/src/dtls/connection/HandshakeOptions.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What a DTLS 1.2 server brings to one handshake: certificate, signing key,
//! ephemeral seed, server random, and the fragment and SRTP policy.
//!
//! ### note:
//!
//! `first_record_seq` must be one past the record sequence the HelloVerifyRequest
//! used. Starting over at zero repeats an (epoch, sequence) pair the peer has seen,
//! and its anti-replay window (RFC 6347 4.1.2.6) drops the ServerHello.
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
const connection = @import("../connection.zig");
const SrtpProfile = @import("../exporter/srtp_profile.zig").SrtpProfile;

const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

// --------------------------------------------------------- //
// Fields:

certificate_der: []const u8,
signing_key: EcdsaP256.KeyPair,
/// Seed for the ephemeral ECDHE scalar. Fresh per handshake, never reused.
server_eph_secret: [32]u8,
server_random: [32]u8,
/// Largest handshake fragment body this server emits.
max_fragment_len: usize = connection.DEFAULT_MAX_FRAGMENT,
/// Where this server's epoch 0 record numbering has already reached.
first_record_seq: u48 = 0,
/// SRTP profiles this server carries, best first (RFC 5764 4.1). Empty declines
/// media: the ServerHello echoes no use_srtp, the association stays plain DTLS.
srtp_profiles: []const SrtpProfile = &.{},

const Self = @This();

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz dtls connection: HandshakeOptions, defaults decline media from sequence 0" {
    const opts: Self = .{
        .certificate_der = "",
        .signing_key = try EcdsaP256.KeyPair.generateDeterministic(@splat(0x01)),
        .server_eph_secret = @splat(0x22),
        .server_random = @splat(0x33),
    };

    try std.testing.expectEqual(connection.DEFAULT_MAX_FRAGMENT, opts.max_fragment_len);
    try std.testing.expectEqual(@as(u48, 0), opts.first_record_seq);
    try std.testing.expectEqual(@as(usize, 0), opts.srtp_profiles.len);
}

