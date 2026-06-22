//! TLS cross-version negotiation + downgrade sentinel PoC (RFC 8446 4.1.3, 4.2.1). A 1.3-capable
//! server offering both 1.3 and 1.2 must: pick 1.3 when the ClientHello offers it (supported_versions
//! lists 0x0304), else fall back to 1.2, else reject; AND when it negotiates DOWN to 1.2 it must
//! plant the "DOWNGRD\x01" sentinel in the last 8 bytes of ServerHello.random, so a 1.3-capable
//! client can detect a downgrade attack. Layer N of tls12-plan.md. Deterministic logic only.
//!
//! Run: `zig test rnd/0.5.x/tls12_negotiate_poc.zig`

const std = @import("std");

const version_tls_1_3: u16 = 0x0304;
const version_tls_1_2: u16 = 0x0303;

/// RFC 8446 4.1.3: the last 8 bytes of ServerHello.random when a 1.3-capable server negotiates a
/// lower version. "DOWNGRD" + 0x01 for TLS 1.2, + 0x00 for 1.1 or below.
const sentinel_tls_1_2 = [8]u8{ 'D', 'O', 'W', 'N', 'G', 'R', 'D', 0x01 };
const sentinel_below_1_2 = [8]u8{ 'D', 'O', 'W', 'N', 'G', 'R', 'D', 0x00 };

const Selected = enum { TLS_1_3, TLS_1_2, UNSUPPORTED };

/// Pick the version (RFC 8446 4.2.1): prefer 1.3 when the client offered it via supported_versions,
/// else 1.2 if the legacy_version is at least 0x0303, else unsupported (1.1 / 1.0 are never used).
fn selectVersion(offers_tls13: bool, legacy_version: u16) Selected {
    if (offers_tls13) return .TLS_1_3;
    if (legacy_version >= version_tls_1_2) return .TLS_1_2;

    return .UNSUPPORTED;
}

/// Plant the downgrade sentinel in the last 8 bytes of ServerHello.random when negotiating below
/// 1.3 (RFC 8446 4.1.3). No-op for 1.3. zix only ever negotiates 1.3 or 1.2, so in practice only
/// the 1.2 sentinel is emitted.
fn applyDowngradeSentinel(server_random: *[32]u8, negotiated: Selected) void {
    switch (negotiated) {
        .TLS_1_3 => {},
        .TLS_1_2 => @memcpy(server_random[24..32], &sentinel_tls_1_2),
        .UNSUPPORTED => @memcpy(server_random[24..32], &sentinel_below_1_2),
    }
}

/// Client-side check: a client that offered 1.3 but got a lower version MUST treat the matching
/// sentinel as a downgrade attack and abort (RFC 8446 4.1.3).
fn downgradeDetected(server_random: [32]u8, negotiated: Selected, client_offered_1_3: bool) bool {
    if (!client_offered_1_3) return false;

    return switch (negotiated) {
        .TLS_1_3 => false,
        .TLS_1_2 => std.mem.eql(u8, server_random[24..32], &sentinel_tls_1_2),
        .UNSUPPORTED => std.mem.eql(u8, server_random[24..32], &sentinel_below_1_2),
    };
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "tls negotiate: version selection" {
    try std.testing.expectEqual(Selected.TLS_1_3, selectVersion(true, version_tls_1_2)); // 1.3 offered
    try std.testing.expectEqual(Selected.TLS_1_2, selectVersion(false, version_tls_1_2)); // 1.2-only client
    try std.testing.expectEqual(Selected.UNSUPPORTED, selectVersion(false, 0x0302)); // TLS 1.1 -> reject
}

test "tls negotiate: downgrade sentinel byte-exact (RFC 8446 4.1.3)" {
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x44, 0x4F, 0x57, 0x4E, 0x47, 0x52, 0x44, 0x01 }, &sentinel_tls_1_2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x44, 0x4F, 0x57, 0x4E, 0x47, 0x52, 0x44, 0x00 }, &sentinel_below_1_2);

    // negotiating 1.2 overwrites the last 8 bytes, the first 24 are untouched.
    var rnd: [32]u8 = undefined;
    @memset(&rnd, 0xAB);
    applyDowngradeSentinel(&rnd, .TLS_1_2);
    const head_ab: [24]u8 = @splat(0xAB);
    try std.testing.expectEqualSlices(u8, &head_ab, rnd[0..24]);
    try std.testing.expectEqualSlices(u8, &sentinel_tls_1_2, rnd[24..32]);

    // negotiating 1.3 leaves random untouched.
    var rnd13: [32]u8 = undefined;
    @memset(&rnd13, 0xCD);
    applyDowngradeSentinel(&rnd13, .TLS_1_3);
    const all_cd: [32]u8 = @splat(0xCD);
    try std.testing.expectEqualSlices(u8, &all_cd, &rnd13);
}

test "tls negotiate: client detects (and ignores) downgrade correctly" {
    var rnd: [32]u8 = undefined;
    @memset(&rnd, 0x00);
    applyDowngradeSentinel(&rnd, .TLS_1_2);

    // 1.3-capable client sees 1.2 + sentinel -> downgrade attack.
    try std.testing.expect(downgradeDetected(rnd, .TLS_1_2, true));
    // same client, server picked 1.3 -> fine.
    try std.testing.expect(!downgradeDetected(rnd, .TLS_1_3, true));
    // a genuine 1.2-only client (never offered 1.3) -> not a downgrade.
    try std.testing.expect(!downgradeDetected(rnd, .TLS_1_2, false));
}
