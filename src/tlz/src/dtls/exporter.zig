//! TLZ dtls exporter
//!
//! ### file: src/tlz/src/dtls/exporter.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLS 1.2 exported keying material (RFC 5705) and the DTLS-SRTP key split
//! (RFC 5764 4.2), on the TLS 1.2 PRF.
//!
//! ### note:
//!
//! RFC 5705 has TWO seed forms. Without a context the seed is client_random ++
//! server_random. With a context, even an empty one, a 2-byte length is appended,
//! so the output differs. DTLS-SRTP uses the NO-CONTEXT form, which is why
//! `srtpKeys` passes null and not an empty slice.
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
const prf = @import("../tls12/prf.zig");

// --------------------------------------------------------- //
// Private:

/// client_random ++ server_random, plus room for a length-prefixed context.
const MAX_SEED_LEN: usize = 64 + 2 + MAX_CONTEXT_LEN;

// --------------------------------------------------------- //
// Public:

pub const SrtpProfile = @import("exporter/srtp_profile.zig").SrtpProfile;
pub const SrtpKeys = @import("exporter/SrtpKeys.zig");

pub const Error = error{
    Tlz_DtlsExporter_ContextTooLong,
    Tlz_DtlsExporter_UnsupportedProfile,
};

/// Exporter label for DTLS-SRTP (RFC 5764 4.2). The "EXTRACTOR" prefix is historical.
pub const LABEL_DTLS_SRTP: []const u8 = "EXTRACTOR-dtls_srtp";

/// Longest context accepted. The PRF builds label ++ seed in a fixed buffer, so the
/// context is bounded here.
pub const MAX_CONTEXT_LEN: usize = 128;

/// SRTP master key length for the AES-128 profiles (RFC 5764 4.1.2).
pub const SRTP_MASTER_KEY_LEN: usize = SrtpKeys.MASTER_KEY_LEN;

/// SRTP master salt length for the AES-128 profiles (RFC 5764 4.1.2).
pub const SRTP_MASTER_SALT_LEN: usize = SrtpKeys.MASTER_SALT_LEN;

/// Export keying material for another protocol (RFC 5705 4).
///
/// Note:
/// - context null and context "" are NOT the same. null omits the context, an empty
///   slice appends a 2-byte length of zero.
///
/// Param:
/// out - []u8 (filled completely, its length is the amount exported)
/// master_secret - [48]u8 (from the finished handshake)
/// client_random - [32]u8 (from ClientHello)
/// server_random - [32]u8 (from ServerHello)
/// label - []const u8 (registered exporter label)
/// context - ?[]const u8 (null for no context, otherwise length-prefixed into the seed)
///
/// Return:
/// - void
/// - Error.Tlz_DtlsExporter_ContextTooLong when the context is over MAX_CONTEXT_LEN
pub fn exportKeyingMaterial(
    out: []u8,
    master_secret: [48]u8,
    client_random: [32]u8,
    server_random: [32]u8,
    label: []const u8,
    context: ?[]const u8,
) Error!void {
    var seed: [MAX_SEED_LEN]u8 = undefined;
    @memcpy(seed[0..32], &client_random);
    @memcpy(seed[32..64], &server_random);

    var seed_len: usize = 64;

    if (context) |bytes| {
        if (bytes.len > MAX_CONTEXT_LEN) return Error.Tlz_DtlsExporter_ContextTooLong;

        std.mem.writeInt(u16, seed[seed_len..][0..2], @intCast(bytes.len), .big);
        seed_len += 2;
        @memcpy(seed[seed_len..][0..bytes.len], bytes);
        seed_len += bytes.len;
    }

    prf.prf(out, &master_secret, label, seed[0..seed_len]);
}

/// Derive the SRTP master keys and salts for both directions (RFC 5764 4.2).
///
/// Note:
/// - The NULL profiles carry no cipher key, so there is nothing to export for them.
///
/// Param:
/// profile - SrtpProfile (the profile the handshake agreed on)
/// master_secret - [48]u8 (from the finished handshake)
/// client_random - [32]u8 (from ClientHello)
/// server_random - [32]u8 (from ServerHello)
///
/// Return:
/// - SrtpKeys
/// - Error.Tlz_DtlsExporter_UnsupportedProfile for a profile without a cipher key
pub fn srtpKeys(
    profile: SrtpProfile,
    master_secret: [48]u8,
    client_random: [32]u8,
    server_random: [32]u8,
) Error!SrtpKeys {
    switch (profile) {
        .SRTP_AES128_CM_HMAC_SHA1_80, .SRTP_AES128_CM_HMAC_SHA1_32 => {},
        else => return Error.Tlz_DtlsExporter_UnsupportedProfile,
    }

    var material: [SrtpKeys.MATERIAL_LEN]u8 = undefined;
    try exportKeyingMaterial(
        &material,
        master_secret,
        client_random,
        server_random,
        LABEL_DTLS_SRTP,
        null,
    );

    return SrtpKeys.fromMaterial(material);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const TEST_MASTER: [48]u8 = @splat(0x5A);
const TEST_CLIENT_RANDOM: [32]u8 = @splat(0xAA);
const TEST_SERVER_RANDOM: [32]u8 = @splat(0xBB);

fn testExport(out: []u8, label: []const u8, context: ?[]const u8) Error!void {
    return exportKeyingMaterial(
        out,
        TEST_MASTER,
        TEST_CLIENT_RANDOM,
        TEST_SERVER_RANDOM,
        label,
        context,
    );
}

fn testSrtpKeys(profile: SrtpProfile) Error!SrtpKeys {
    return srtpKeys(profile, TEST_MASTER, TEST_CLIENT_RANDOM, TEST_SERVER_RANDOM);
}

test "tlz dtls: exporter, no context seeds with the two randoms only" {
    var exported: [32]u8 = undefined;
    var expected: [32]u8 = undefined;
    const seed = TEST_CLIENT_RANDOM ++ TEST_SERVER_RANDOM;

    try testExport(&exported, "label", null);
    prf.prf(&expected, &TEST_MASTER, "label", &seed);

    try std.testing.expectEqualSlices(u8, &expected, &exported);
}

test "tlz dtls: exporter, an empty context appends a zero length" {
    var with_empty: [32]u8 = undefined;
    var expected: [32]u8 = undefined;
    const seed = TEST_CLIENT_RANDOM ++ TEST_SERVER_RANDOM ++ [_]u8{ 0, 0 };

    try testExport(&with_empty, "label", "");
    prf.prf(&expected, &TEST_MASTER, "label", &seed);

    try std.testing.expectEqualSlices(u8, &expected, &with_empty);
}

test "tlz dtls: exporter, an empty context differs from no context" {
    var without: [32]u8 = undefined;
    var with_empty: [32]u8 = undefined;

    try testExport(&without, "label", null);
    try testExport(&with_empty, "label", "");

    try std.testing.expect(!std.mem.eql(u8, &without, &with_empty));
}

test "tlz dtls: exporter, the label separates the output" {
    var base: [32]u8 = undefined;
    var other: [32]u8 = undefined;

    try testExport(&base, LABEL_DTLS_SRTP, null);
    try testExport(&other, "EXTRACTOR-other", null);

    try std.testing.expect(!std.mem.eql(u8, &base, &other));
}

test "tlz dtls: exporter, swapped randoms give another output" {
    var forward: [32]u8 = undefined;
    var reversed: [32]u8 = undefined;

    try testExport(&forward, "label", null);
    try exportKeyingMaterial(
        &reversed,
        TEST_MASTER,
        TEST_SERVER_RANDOM,
        TEST_CLIENT_RANDOM,
        "label",
        null,
    );

    try std.testing.expect(!std.mem.eql(u8, &forward, &reversed));
}

test "tlz dtls: exporter, a shorter export is a prefix of a longer one" {
    var short: [16]u8 = undefined;
    var long: [64]u8 = undefined;

    try testExport(&short, "label", null);
    try testExport(&long, "label", null);

    try std.testing.expectEqualSlices(u8, &short, long[0..16]);
}

test "tlz dtls: exporter, a context past MAX_CONTEXT_LEN is too long" {
    var exported: [16]u8 = undefined;
    const too_long: [MAX_CONTEXT_LEN + 1]u8 = @splat(0);

    try std.testing.expectError(
        Error.Tlz_DtlsExporter_ContextTooLong,
        testExport(&exported, "label", &too_long),
    );
}

test "tlz dtls: exporter, a context at MAX_CONTEXT_LEN is accepted" {
    var exported: [16]u8 = undefined;
    const at_ceiling: [MAX_CONTEXT_LEN]u8 = @splat(0);

    try testExport(&exported, "label", &at_ceiling);
}

test "tlz dtls: exporter, srtpKeys splits the exported 60 bytes" {
    var material: [60]u8 = undefined;

    const keys = try testSrtpKeys(.SRTP_AES128_CM_HMAC_SHA1_80);
    try testExport(&material, LABEL_DTLS_SRTP, null);

    try std.testing.expectEqualSlices(u8, material[0..16], &keys.client_write_key);
    try std.testing.expectEqualSlices(u8, material[46..60], &keys.server_write_salt);
    try std.testing.expect(!std.mem.eql(u8, &keys.client_write_key, &keys.server_write_key));
}

test "tlz dtls: exporter, both AES128 profiles derive alike" {
    const tag_80 = try testSrtpKeys(.SRTP_AES128_CM_HMAC_SHA1_80);
    const tag_32 = try testSrtpKeys(.SRTP_AES128_CM_HMAC_SHA1_32);

    try std.testing.expectEqualSlices(u8, &tag_80.client_write_key, &tag_32.client_write_key);
}

test "tlz dtls: exporter, a NULL profile is unsupported" {
    try std.testing.expectError(
        Error.Tlz_DtlsExporter_UnsupportedProfile,
        testSrtpKeys(.SRTP_NULL_HMAC_SHA1_80),
    );
}

test "tlz dtls: exporter, an unregistered profile is unsupported" {
    try std.testing.expectError(
        Error.Tlz_DtlsExporter_UnsupportedProfile,
        testSrtpKeys(@enumFromInt(0xFFFF)),
    );
}

