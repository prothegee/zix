//! TLZ tls12 version
//!
//! ### file: src/tlz/src/tls12/version.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Cross-version selection and the downgrade sentinel (RFC 8446 4.1.3, 4.2.1).
//!
//! ### note:
//!
//! A 1.3-capable server that negotiates down to 1.2 plants "DOWNGRD\x01" in the last
//! 8 bytes of ServerHello.random, so a 1.3-capable client detects the downgrade.
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
// Private:

const VERSION_TLS_1_2: u16 = 0x0303;

/// Pick the version (RFC 8446 4.2.1): 1.3 when supported_versions offers it, else 1.2
/// when legacy_version is at least 0x0303, else unsupported.
fn selectVersion(offers_tls13: bool, legacy_version: u16) Selected {
    if (offers_tls13) return .TLS_1_3;
    if (legacy_version >= VERSION_TLS_1_2) return .TLS_1_2;

    return .UNSUPPORTED;
}

/// Client side check: a client that offered 1.3 but got a lower version with the
/// matching sentinel treats it as a downgrade attack (RFC 8446 4.1.3).
fn downgradeDetected(server_random: [32]u8, negotiated: Selected, offered_1_3: bool) bool {
    if (!offered_1_3) return false;

    return switch (negotiated) {
        .TLS_1_3 => false,
        .TLS_1_2 => std.mem.eql(u8, server_random[24..32], &SENTINEL_TLS_1_2),
        .UNSUPPORTED => std.mem.eql(u8, server_random[24..32], &SENTINEL_BELOW_1_2),
    };
}

// --------------------------------------------------------- //
// Public:

pub const Selected = @import("version/selected.zig").Selected;

/// Last 8 bytes of ServerHello.random when a 1.3-capable server picks 1.2.
pub const SENTINEL_TLS_1_2 = [8]u8{ 'D', 'O', 'W', 'N', 'G', 'R', 'D', 0x01 };

/// Last 8 bytes of ServerHello.random when a 1.3-capable server picks below 1.2.
pub const SENTINEL_BELOW_1_2 = [8]u8{ 'D', 'O', 'W', 'N', 'G', 'R', 'D', 0x00 };

/// Plant the downgrade sentinel in the last 8 bytes of ServerHello.random when
/// negotiating below 1.3. No change for 1.3.
///
/// Param:
/// server_random - *[32]u8 (the ServerHello.random to patch)
/// negotiated - Selected (the picked version)
///
/// Return:
/// - void
pub fn applyDowngradeSentinel(server_random: *[32]u8, negotiated: Selected) void {
    switch (negotiated) {
        .TLS_1_3 => {},
        .TLS_1_2 => @memcpy(server_random[24..32], &SENTINEL_TLS_1_2),
        .UNSUPPORTED => @memcpy(server_random[24..32], &SENTINEL_BELOW_1_2),
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "tlz tls12: version, selectVersion picks 1.3 when offered" {
    try std.testing.expectEqual(Selected.TLS_1_3, selectVersion(true, VERSION_TLS_1_2));
}

test "tlz tls12: version, selectVersion falls back to 1.2" {
    try std.testing.expectEqual(Selected.TLS_1_2, selectVersion(false, VERSION_TLS_1_2));
}

test "tlz tls12: version, selectVersion below 1.2 is unsupported" {
    try std.testing.expectEqual(Selected.UNSUPPORTED, selectVersion(false, 0x0302));
}

test "tlz tls12: version, sentinel is DOWNGRD 01 byte for byte" {
    const expected = [_]u8{ 0x44, 0x4F, 0x57, 0x4E, 0x47, 0x52, 0x44, 0x01 };

    try std.testing.expectEqualSlices(u8, &expected, &SENTINEL_TLS_1_2);
}

test "tlz tls12: version, applyDowngradeSentinel keeps the first 24 bytes" {
    var server_random: [32]u8 = @splat(0xAB);
    const head: [24]u8 = @splat(0xAB);

    applyDowngradeSentinel(&server_random, .TLS_1_2);

    try std.testing.expectEqualSlices(u8, &head, server_random[0..24]);
    try std.testing.expectEqualSlices(u8, &SENTINEL_TLS_1_2, server_random[24..32]);
}

test "tlz tls12: version, applyDowngradeSentinel for 1.3 changes nothing" {
    var server_random: [32]u8 = @splat(0xAB);
    const untouched: [32]u8 = @splat(0xAB);

    applyDowngradeSentinel(&server_random, .TLS_1_3);

    try std.testing.expectEqualSlices(u8, &untouched, &server_random);
}

test "tlz tls12: version, applyDowngradeSentinel below 1.2 uses the 00 sentinel" {
    var server_random: [32]u8 = @splat(0xAB);

    applyDowngradeSentinel(&server_random, .UNSUPPORTED);

    try std.testing.expectEqualSlices(u8, &SENTINEL_BELOW_1_2, server_random[24..32]);
}

test "tlz tls12: version, downgradeDetected on a 1.3 client with the sentinel" {
    var server_random: [32]u8 = @splat(0xAB);
    applyDowngradeSentinel(&server_random, .TLS_1_2);

    try std.testing.expect(downgradeDetected(server_random, .TLS_1_2, true));
}

test "tlz tls12: version, downgradeDetected is false when the server picked 1.3" {
    var server_random: [32]u8 = @splat(0xAB);
    applyDowngradeSentinel(&server_random, .TLS_1_2);

    try std.testing.expect(!downgradeDetected(server_random, .TLS_1_3, true));
}

test "tlz tls12: version, downgradeDetected is false for a 1.2-only client" {
    var server_random: [32]u8 = @splat(0xAB);
    applyDowngradeSentinel(&server_random, .TLS_1_2);

    try std.testing.expect(!downgradeDetected(server_random, .TLS_1_2, false));
}

test "tlz tls12: version, downgradeDetected without the sentinel is false" {
    const server_random: [32]u8 = @splat(0xAB);

    try std.testing.expect(!downgradeDetected(server_random, .TLS_1_2, true));
}

