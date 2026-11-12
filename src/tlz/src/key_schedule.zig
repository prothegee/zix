//! TLZ key schedule
//!
//! ### file: src/tlz/src/key_schedule.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLS 1.3 key schedule (RFC 8446 section 7.1): HKDF-Expand-Label and
//! Derive-Secret over HKDF-SHA256. Pure functions, no I/O.
//!
//! ### note:
//!
//! std.crypto ships HKDF and SHA-256 but no TLS key schedule, so the "tls13 "
//! label encoding lives here. The tests check it against the RFC 8448 trace.
//! QUIC-TLS (RFC 9001) reuses this layer as is.
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

/// Every HkdfLabel.label starts with this prefix (RFC 8446 7.1).
const LABEL_PREFIX = "tls13 ";

// --------------------------------------------------------- //
// Public:

pub const HkdfSha256 = std.crypto.kdf.hkdf.HkdfSha256;
pub const Sha256 = std.crypto.hash.sha2.Sha256;

/// Hash output width (SHA-256): the secret and transcript hash size in bytes.
pub const HASH_LENGTH = Sha256.digest_length;

/// A schedule secret or a transcript hash, one hash block wide.
pub const Secret = [HASH_LENGTH]u8;

/// HKDF-Expand-Label (RFC 8446 7.1): expand `secret` under the HkdfLabel info
/// (output length, "tls13 " + label, context).
///
/// Note:
/// - `label` is at most 249 bytes and `context` at most `HASH_LENGTH` bytes,
///   the TLS 1.3 limits for every label and context in use.
///
/// Param:
/// out - []u8 (filled in place, its length is HkdfLabel.length)
/// secret - Secret (the pseudorandom key)
/// label - []const u8 (the bare label, without the "tls13 " prefix)
/// context - []const u8 (a transcript hash, or empty)
///
/// Return:
/// - void
pub fn expandLabel(out: []u8, secret: Secret, label: []const u8, context: []const u8) void {
    var info: [2 + 1 + LABEL_PREFIX.len + 255 + 1 + HASH_LENGTH]u8 = undefined;
    std.mem.writeInt(u16, info[0..2], @intCast(out.len), .big);
    info[2] = @intCast(LABEL_PREFIX.len + label.len);
    @memcpy(info[3 .. 3 + LABEL_PREFIX.len], LABEL_PREFIX);
    @memcpy(info[3 + LABEL_PREFIX.len .. 3 + LABEL_PREFIX.len + label.len], label);

    const context_pos = 3 + LABEL_PREFIX.len + label.len;
    info[context_pos] = @intCast(context.len);
    @memcpy(info[context_pos + 1 .. context_pos + 1 + context.len], context);

    HkdfSha256.expand(out, info[0 .. context_pos + 1 + context.len], secret);
}

/// Derive-Secret (RFC 8446 7.1): HKDF-Expand-Label keyed by a transcript hash,
/// one block wide.
///
/// Param:
/// secret - Secret (the pseudorandom key)
/// label - []const u8 (the bare label, without the "tls13 " prefix)
/// transcript_hash - Secret (the transcript hash at this point)
///
/// Return:
/// - Secret
pub fn deriveSecret(secret: Secret, label: []const u8, transcript_hash: Secret) Secret {
    var out: Secret = undefined;
    expandLabel(&out, secret, label, &transcript_hash);

    return out;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn expectHex(got: []const u8, comptime hex_str: []const u8) !void {
    var want: [64]u8 = undefined;
    const want_bytes = try std.fmt.hexToBytes(&want, hex_str);

    try std.testing.expectEqualSlices(u8, want_bytes, got);
}

fn secretFromHex(comptime hex_str: []const u8) !Secret {
    var out: Secret = undefined;
    _ = try std.fmt.hexToBytes(&out, hex_str);

    return out;
}

fn emptyHash() Secret {
    var out: Secret = undefined;
    Sha256.hash("", &out, .{});

    return out;
}

/// The RFC 8448 server handshake traffic secret, built from the trace inputs.
fn rfc8448ServerHandshakeSecret() !Secret {
    const ecdhe = try secretFromHex(
        "8bd4054fb55b9d63fdfbacf9f04b9f0d35e6d63f537563efd46272900f89492d",
    );
    const transcript_ch_sh = try secretFromHex(
        "860c06edc07858ee8e78f0e7428c58edd6b43f2ca3e6e95f02ed063cf0e1cad8",
    );

    const zero = std.mem.zeroes(Secret);
    const early = HkdfSha256.extract(&zero, &zero);
    const derived = deriveSecret(early, "derived", emptyHash());
    const handshake = HkdfSha256.extract(&derived, &ecdhe);

    return deriveSecret(handshake, "s hs traffic", transcript_ch_sh);
}

test "tlz: key_schedule, early secret matches RFC 8448" {
    const zero = std.mem.zeroes(Secret);

    const early = HkdfSha256.extract(&zero, &zero);

    try expectHex(&early, "33ad0a1c607ec03b09e6cd9893680ce210adf300aa1f2660e1b22e10f170f92a");
}

test "tlz: deriveSecret, derived secret matches RFC 8448" {
    const zero = std.mem.zeroes(Secret);
    const early = HkdfSha256.extract(&zero, &zero);

    const derived = deriveSecret(early, "derived", emptyHash());

    try expectHex(&derived, "6f2615a108c702c5678f54fc9dbab69716c076189c48250cebeac3576c3611ba");
}

test "tlz: deriveSecret, server handshake secret matches RFC 8448" {
    const server_hs = try rfc8448ServerHandshakeSecret();

    try expectHex(
        &server_hs,
        "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38",
    );
}

test "tlz: expandLabel, traffic key matches RFC 8448" {
    const server_hs = try rfc8448ServerHandshakeSecret();
    var key: [16]u8 = undefined;

    expandLabel(&key, server_hs, "key", "");

    try expectHex(&key, "3fce516009c21727d0f2e4e86ee403bc");
}

test "tlz: expandLabel, traffic iv matches RFC 8448" {
    const server_hs = try rfc8448ServerHandshakeSecret();
    var iv: [12]u8 = undefined;

    expandLabel(&iv, server_hs, "iv", "");

    try expectHex(&iv, "5d313eb2671276ee13000b30");
}

test "tlz: expandLabel, finished key matches RFC 8448" {
    const server_hs = try rfc8448ServerHandshakeSecret();
    var finished: Secret = undefined;

    expandLabel(&finished, server_hs, "finished", "");

    try expectHex(
        &finished,
        "008d3b66f816ea559f96b537e885c31fc068bf492c652f01f288a1d8cdc19fc8",
    );
}

test "tlz: expandLabel, different labels give different output" {
    const secret = std.mem.zeroes(Secret);
    var key_out: [16]u8 = undefined;
    var iv_out: [16]u8 = undefined;

    expandLabel(&key_out, secret, "key", "");
    expandLabel(&iv_out, secret, "iv", "");

    try std.testing.expect(!std.mem.eql(u8, &key_out, &iv_out));
}

test "tlz: expandLabel, output length is part of the info" {
    const secret = std.mem.zeroes(Secret);
    var short_out: [16]u8 = undefined;
    var long_out: [32]u8 = undefined;

    expandLabel(&short_out, secret, "key", "");
    expandLabel(&long_out, secret, "key", "");

    try std.testing.expect(!std.mem.eql(u8, &short_out, long_out[0..16]));
}

test "tlz: expandLabel, full width context fits" {
    const secret = std.mem.zeroes(Secret);
    const context: Secret = @splat(0xab);
    var out: Secret = undefined;

    expandLabel(&out, secret, "c ap traffic", &context);

    try std.testing.expect(!std.mem.eql(u8, &out, &std.mem.zeroes(Secret)));
}

