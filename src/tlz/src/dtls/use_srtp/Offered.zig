//! TLZ dtls use_srtp Offered
//!
//! ### file: src/tlz/src/dtls/use_srtp/Offered.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! What a client offered in its use_srtp extension (RFC 5764 4.1.1), borrowed from
//! the hello it came in.
//!
//! ### note:
//!
//! The MKI is read and reported, never honoured.
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
const use_srtp = @import("../use_srtp.zig");
const SrtpProfile = @import("../exporter/srtp_profile.zig").SrtpProfile;

// --------------------------------------------------------- //
// Fields:

/// The profile list as it stands, two bytes per entry.
profiles: []const u8,
/// The master key identifier, empty when the client asked for none.
mki: []const u8,

const Self = @This();

// --------------------------------------------------------- //
// Public:

/// How many profiles the client named.
///
/// Return:
/// - usize
pub fn count(self: Self) usize {
    return self.profiles.len / use_srtp.PROFILE_LEN;
}

/// One profile by position, in the client's own preference order.
///
/// Param:
/// index - usize (position in the list)
///
/// Return:
/// - SrtpProfile
/// - null past the end of the list
pub fn at(self: Self, index: usize) ?SrtpProfile {
    if (index >= self.count()) return null;

    const at_byte = index * use_srtp.PROFILE_LEN;

    return @enumFromInt(std.mem.readInt(u16, self.profiles[at_byte..][0..2], .big));
}

/// Whether a profile is somewhere in the list.
///
/// Param:
/// wanted - SrtpProfile (the profile to look for)
///
/// Return:
/// - bool
pub fn has(self: Self, wanted: SrtpProfile) bool {
    var index: usize = 0;
    while (self.at(index)) |offered| : (index += 1) {
        if (offered == wanted) return true;
    }

    return false;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const TEST_OFFER: Self = .{
    .profiles = &[_]u8{ 0x00, 0x02, 0x00, 0x01 },
    .mki = "",
};

test "tlz dtls use_srtp: Offered, count is two bytes per profile" {
    try std.testing.expectEqual(@as(usize, 2), TEST_OFFER.count());
}

test "tlz dtls use_srtp: Offered, at keeps the client order" {
    try std.testing.expectEqual(SrtpProfile.SRTP_AES128_CM_HMAC_SHA1_32, TEST_OFFER.at(0).?);
    try std.testing.expectEqual(SrtpProfile.SRTP_AES128_CM_HMAC_SHA1_80, TEST_OFFER.at(1).?);
}

test "tlz dtls use_srtp: Offered, at past the end gives null" {
    try std.testing.expectEqual(@as(?SrtpProfile, null), TEST_OFFER.at(2));
}

test "tlz dtls use_srtp: Offered, has finds a listed profile" {
    try std.testing.expect(TEST_OFFER.has(.SRTP_AES128_CM_HMAC_SHA1_80));
}

test "tlz dtls use_srtp: Offered, has misses an unlisted profile" {
    try std.testing.expect(!TEST_OFFER.has(.SRTP_NULL_HMAC_SHA1_80));
}

