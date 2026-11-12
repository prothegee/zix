//! TLZ dtls use_srtp
//!
//! ### file: src/tlz/src/dtls/use_srtp.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! DTLS-SRTP use_srtp extension (RFC 5764 4.1): find and read the client offer,
//! select one profile, and write the server answer.
//!
//! ### note:
//!
//! The server side only: it reads a list and writes a single choice. An answer names
//! exactly one profile (RFC 5764 4.1.1). A hello without the extension is not an
//! error, it means plain DTLS, and the ServerHello leaves the extension out too.
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
const exporter = @import("exporter.zig");

// --------------------------------------------------------- //
// Public:

pub const Offered = @import("use_srtp/Offered.zig");

/// What `find` and `read` can raise.
pub const ReadError = error{
    Tlz_DtlsUseSrtp_Malformed,
};

/// What `writeAnswer` can raise.
pub const WriteError = error{
    Tlz_DtlsUseSrtp_NoSpace,
};

pub const Error = ReadError || WriteError;

/// Extension number for use_srtp (RFC 5764 9).
pub const EXTENSION_TYPE: u16 = 14;

/// Bytes one profile takes on the wire.
pub const PROFILE_LEN: usize = 2;

/// Longest master key identifier the length byte can describe.
pub const MAX_MKI_LEN: usize = 255;

/// Bytes a server answer takes, extension header included.
pub const ANSWER_LEN: usize = 2 + 2 + 2 + PROFILE_LEN + 1;

/// Find the use_srtp extension inside a hello's extensions block.
///
/// Note:
/// - The whole block is walked even after a match, so a truncated entry behind the
///   extension is still refused.
/// - Two use_srtp extensions in one block is an error, picking either would be
///   guessing.
///
/// Param:
/// extensions - []const u8 (the whole block, as `hello.ClientHello` holds it)
///
/// Return:
/// - []const u8 (the extension_data alone, borrowing `extensions`)
/// - null when the block is well formed and has no use_srtp
/// - Error.Tlz_DtlsUseSrtp_Malformed when an entry runs past the block, or use_srtp
///   appears twice
pub fn find(extensions: []const u8) ReadError!?[]const u8 {
    var found: ?[]const u8 = null;
    var pos: usize = 0;

    while (pos + 4 <= extensions.len) {
        const kind = std.mem.readInt(u16, extensions[pos..][0..2], .big);
        const len = std.mem.readInt(u16, extensions[pos + 2 ..][0..2], .big);
        const body_at = pos + 4;
        if (body_at + len > extensions.len) return ReadError.Tlz_DtlsUseSrtp_Malformed;

        if (kind == EXTENSION_TYPE) {
            if (found != null) return ReadError.Tlz_DtlsUseSrtp_Malformed;

            found = extensions[body_at..][0..len];
        }

        pos = body_at + len;
    }

    if (pos != extensions.len) return ReadError.Tlz_DtlsUseSrtp_Malformed;

    return found;
}

/// Read a UseSRTPData value (RFC 5764 4.1.1).
///
/// Param:
/// extension_data - []const u8 (borrowed, must outlive the result)
///
/// Return:
/// - Offered (borrowing `extension_data`)
/// - Error.Tlz_DtlsUseSrtp_Malformed for a truncated value, an odd or empty profile
///   list, or trailing bytes
pub fn read(extension_data: []const u8) ReadError!Offered {
    if (extension_data.len < 3) return ReadError.Tlz_DtlsUseSrtp_Malformed;

    const profiles_len = std.mem.readInt(u16, extension_data[0..2], .big);
    const mki_at = 2 + @as(usize, profiles_len);
    if (profiles_len == 0) return ReadError.Tlz_DtlsUseSrtp_Malformed;
    if (profiles_len % PROFILE_LEN != 0) return ReadError.Tlz_DtlsUseSrtp_Malformed;
    if (mki_at >= extension_data.len) return ReadError.Tlz_DtlsUseSrtp_Malformed;

    const mki_len = extension_data[mki_at];
    if (mki_at + 1 + @as(usize, mki_len) != extension_data.len) {
        return ReadError.Tlz_DtlsUseSrtp_Malformed;
    }

    return .{
        .profiles = extension_data[2..mki_at],
        .mki = extension_data[mki_at + 1 ..],
    };
}

/// Pick the profile to answer with. The server's own order decides.
///
/// Param:
/// offered - Offered (what the client listed)
/// preferences - []const exporter.SrtpProfile (server order, most wanted first)
///
/// Return:
/// - exporter.SrtpProfile
/// - null when nothing overlaps
pub fn select(
    offered: Offered,
    preferences: []const exporter.SrtpProfile,
) ?exporter.SrtpProfile {
    for (preferences) |wanted| {
        if (offered.has(wanted)) return wanted;
    }

    return null;
}

/// Write the server's use_srtp extension, header included.
///
/// Param:
/// out - []u8 (buffer to write into, from its start)
/// chosen - exporter.SrtpProfile (the one profile the server agreed to)
///
/// Return:
/// - []const u8 (exactly ANSWER_LEN bytes, borrowing `out`)
/// - Error.Tlz_DtlsUseSrtp_NoSpace when `out` is shorter than ANSWER_LEN
pub fn writeAnswer(out: []u8, chosen: exporter.SrtpProfile) WriteError![]const u8 {
    if (out.len < ANSWER_LEN) return WriteError.Tlz_DtlsUseSrtp_NoSpace;

    std.mem.writeInt(u16, out[0..2], EXTENSION_TYPE, .big);
    std.mem.writeInt(u16, out[2..4], PROFILE_LEN + 2 + 1, .big);
    std.mem.writeInt(u16, out[4..6], PROFILE_LEN, .big);
    std.mem.writeInt(u16, out[6..8], @intFromEnum(chosen), .big);
    out[8] = 0;

    return out[0..ANSWER_LEN];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const SrtpProfile = exporter.SrtpProfile;

/// One client extension_data naming `profiles`, with no MKI.
fn offerData(out: []u8, profiles: []const exporter.SrtpProfile) []const u8 {
    const list_len = profiles.len * PROFILE_LEN;
    std.mem.writeInt(u16, out[0..2], @intCast(list_len), .big);

    for (profiles, 0..) |profile, index| {
        const at_byte = 2 + index * PROFILE_LEN;
        std.mem.writeInt(u16, out[at_byte..][0..2], @intFromEnum(profile), .big);
    }

    out[2 + list_len] = 0;

    return out[0 .. 2 + list_len + 1];
}

test "tlz dtls: use_srtp, read takes a two profile offer field for field" {
    const data = [_]u8{ 0x00, 0x04, 0x00, 0x01, 0x00, 0x02, 0x00 };

    const offered = try read(&data);

    try std.testing.expectEqual(@as(usize, 2), offered.count());
    try std.testing.expectEqual(SrtpProfile.SRTP_AES128_CM_HMAC_SHA1_80, offered.at(0).?);
    try std.testing.expectEqual(SrtpProfile.SRTP_AES128_CM_HMAC_SHA1_32, offered.at(1).?);
    try std.testing.expectEqual(@as(usize, 0), offered.mki.len);
}

test "tlz dtls: use_srtp, read reports a master key identifier" {
    const data = [_]u8{ 0x00, 0x02, 0x00, 0x01, 0x03, 0xAA, 0xBB, 0xCC };

    const offered = try read(&data);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, offered.mki);
}

test "tlz dtls: use_srtp, read on a too short value is malformed" {
    try std.testing.expectError(ReadError.Tlz_DtlsUseSrtp_Malformed, read(&[_]u8{ 0x00, 0x02 }));
}

test "tlz dtls: use_srtp, read on an odd profile list is malformed" {
    const data = [_]u8{ 0x00, 0x03, 0x00, 0x01, 0x00, 0x00 };

    try std.testing.expectError(ReadError.Tlz_DtlsUseSrtp_Malformed, read(&data));
}

test "tlz dtls: use_srtp, read on an empty profile list is malformed" {
    try std.testing.expectError(ReadError.Tlz_DtlsUseSrtp_Malformed, read(&[_]u8{ 0, 0, 0 }));
}

test "tlz dtls: use_srtp, read on a list past the value is malformed" {
    const data = [_]u8{ 0x00, 0x08, 0x00, 0x01, 0x00 };

    try std.testing.expectError(ReadError.Tlz_DtlsUseSrtp_Malformed, read(&data));
}

test "tlz dtls: use_srtp, read on a wrong MKI length is malformed" {
    const data = [_]u8{ 0x00, 0x02, 0x00, 0x01, 0x04, 0xAA };

    try std.testing.expectError(ReadError.Tlz_DtlsUseSrtp_Malformed, read(&data));
}

test "tlz dtls: use_srtp, read with trailing bytes is malformed" {
    const data = [_]u8{ 0x00, 0x02, 0x00, 0x01, 0x00, 0xFF };

    try std.testing.expectError(ReadError.Tlz_DtlsUseSrtp_Malformed, read(&data));
}

test "tlz dtls: use_srtp, read keeps an unregistered profile number" {
    const data = [_]u8{ 0x00, 0x04, 0xFF, 0xFF, 0x00, 0x01, 0x00 };

    const offered = try read(&data);

    try std.testing.expectEqual(@as(u16, 0xFFFF), @intFromEnum(offered.at(0).?));
    try std.testing.expect(offered.has(.SRTP_AES128_CM_HMAC_SHA1_80));
}

test "tlz dtls: use_srtp, find picks the extension out of a block" {
    const extensions = [_]u8{
        0x00, 0x0D, 0x00, 0x02, 0x04, 0x03,
        0x00, 0x0E, 0x00, 0x05, 0x00, 0x02,
        0x00, 0x01, 0x00, 0x00, 0x17, 0x00,
        0x00,
    };

    const offered = try read((try find(&extensions)).?);

    try std.testing.expectEqual(@as(usize, 1), offered.count());
    try std.testing.expectEqual(SrtpProfile.SRTP_AES128_CM_HMAC_SHA1_80, offered.at(0).?);
}

test "tlz dtls: use_srtp, find on a block without it gives null" {
    const extensions = [_]u8{ 0x00, 0x0D, 0x00, 0x02, 0x04, 0x03 };

    try std.testing.expect((try find(&extensions)) == null);
    try std.testing.expect((try find("")) == null);
}

test "tlz dtls: use_srtp, find on an entry past the block is malformed" {
    const extensions = [_]u8{ 0x00, 0x0E, 0x00, 0x08, 0x00 };

    try std.testing.expectError(ReadError.Tlz_DtlsUseSrtp_Malformed, find(&extensions));
}

test "tlz dtls: use_srtp, find on a trailing stub is malformed" {
    const extensions = [_]u8{ 0x00, 0x0E, 0x00, 0x00, 0x00 };

    try std.testing.expectError(ReadError.Tlz_DtlsUseSrtp_Malformed, find(&extensions));
}

test "tlz dtls: use_srtp, find on the extension twice is malformed" {
    const twice = [_]u8{
        0x00, 0x0E, 0x00, 0x05, 0x00, 0x02, 0x00, 0x01, 0x00,
        0x00, 0x0E, 0x00, 0x05, 0x00, 0x02, 0x00, 0x02, 0x00,
    };

    try std.testing.expectError(ReadError.Tlz_DtlsUseSrtp_Malformed, find(&twice));
}

test "tlz dtls: use_srtp, select follows the server order" {
    var buf: [16]u8 = undefined;
    const offered = try read(offerData(&buf, &.{
        .SRTP_AES128_CM_HMAC_SHA1_32,
        .SRTP_AES128_CM_HMAC_SHA1_80,
    }));

    const chosen = select(offered, &.{
        .SRTP_AES128_CM_HMAC_SHA1_80,
        .SRTP_AES128_CM_HMAC_SHA1_32,
    });

    try std.testing.expectEqual(SrtpProfile.SRTP_AES128_CM_HMAC_SHA1_80, chosen.?);
}

test "tlz dtls: use_srtp, select with nothing in common gives null" {
    var buf: [16]u8 = undefined;
    const offered = try read(offerData(&buf, &.{.SRTP_NULL_HMAC_SHA1_80}));

    try std.testing.expect(select(offered, &.{.SRTP_AES128_CM_HMAC_SHA1_80}) == null);
    try std.testing.expect(select(offered, &.{}) == null);
}

test "tlz dtls: use_srtp, writeAnswer names exactly one profile" {
    var buf: [ANSWER_LEN]u8 = undefined;
    const expected = [_]u8{ 0x00, 0x0E, 0x00, 0x05, 0x00, 0x02, 0x00, 0x01, 0x00 };

    const written = try writeAnswer(&buf, .SRTP_AES128_CM_HMAC_SHA1_80);
    const offered = try read((try find(written)).?);

    try std.testing.expectEqualSlices(u8, &expected, written);
    try std.testing.expectEqual(@as(usize, 1), offered.count());
}

test "tlz dtls: use_srtp, writeAnswer into a short buffer has no space" {
    var buf: [ANSWER_LEN - 1]u8 = undefined;

    try std.testing.expectError(
        WriteError.Tlz_DtlsUseSrtp_NoSpace,
        writeAnswer(&buf, .SRTP_AES128_CM_HMAC_SHA1_80),
    );
}

test "tlz dtls: use_srtp, the chosen profile is one keys derive from" {
    var buf: [16]u8 = undefined;
    const offered = try read(offerData(&buf, &.{
        .SRTP_AES128_CM_HMAC_SHA1_80,
        .SRTP_NULL_HMAC_SHA1_80,
    }));
    const chosen = select(offered, &.{.SRTP_AES128_CM_HMAC_SHA1_80}).?;

    const keys = try exporter.srtpKeys(chosen, @splat(0x5A), @splat(0xAA), @splat(0xBB));

    try std.testing.expect(!std.mem.eql(u8, &keys.client_write_key, &keys.server_write_key));
}

