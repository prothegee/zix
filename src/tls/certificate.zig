//! TLS 1.3 Certificate, CertificateVerify, and Finished (RFC 8446 section 4.4).
//!
//! Note:
//! - Server-side message builders plus the CertificateVerify signing content and the Finished
//!   verify_data. zix authenticates with ECDSA P-256 (and Ed25519), no RSA.
//! - The DER end-entity certificate is supplied by the caller (connection.zig loads it). PEM
//!   parsing + X.509 path validation are separate concerns (Layer V).
//! - Verified against the RFC 8448 trace in-file (Finished verify_data byte-exact).

const std = @import("std");
const wire = @import("wire.zig");
const handshake = @import("handshake.zig");
const key_schedule = @import("key_schedule.zig");

const Reader = wire.Reader;
const Writer = wire.Writer;
const Secret = key_schedule.Secret;
const hash_length = key_schedule.hash_length;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

/// CertificateVerify context string for a server signature (RFC 8446 4.4.3).
pub const certificate_verify_context = "TLS 1.3, server CertificateVerify";

const certificate_verify_content_len = 64 + certificate_verify_context.len + 1 + hash_length;

// --------------------------------------------------------------- //

/// Build the Certificate message (RFC 8446 4.4.2): empty request_context, one end-entity entry
/// holding the DER, empty entry extensions. Returns the wire slice.
pub fn buildCertificate(buf: []u8, der: []const u8) []const u8 {
    var w = Writer{ .buf = buf };

    w.writeU8(@intFromEnum(handshake.HandshakeType.CERTIFICATE));
    const header = w.placeU24();

    w.writeU8(0); // empty certificate_request_context

    const list = w.placeU24();
    const entry = w.placeU24();
    w.writeBytes(der);
    w.patchU24(entry);
    w.writeU16(0); // empty entry extensions
    w.patchU24(list);

    w.patchU24(header);

    return w.slice();
}

// --------------------------------------------------------------- //

/// The CertificateVerify signed content (RFC 8446 4.4.3): a 64-octet 0x20 pad, the context
/// string, a 0x00 separator, then the transcript hash. Returns the slice written into `buf`.
pub fn certificateVerifyContent(buf: []u8, transcript_hash: Secret) []const u8 {
    @memset(buf[0..64], 0x20);
    @memcpy(buf[64 .. 64 + certificate_verify_context.len], certificate_verify_context);
    buf[64 + certificate_verify_context.len] = 0x00;
    @memcpy(buf[64 + certificate_verify_context.len + 1 ..][0..hash_length], &transcript_hash);

    return buf[0..certificate_verify_content_len];
}

/// Sign the CertificateVerify content with ECDSA P-256 and emit the message (RFC 8446 4.4.3).
pub fn buildCertificateVerify(buf: []u8, key_pair: EcdsaP256.KeyPair, transcript_hash: Secret) ![]const u8 {
    var content_buf: [certificate_verify_content_len]u8 = undefined;
    const content = certificateVerifyContent(&content_buf, transcript_hash);

    const signature = try key_pair.sign(content, null);
    var der_buf: [EcdsaP256.Signature.der_encoded_length_max]u8 = undefined;
    const der = signature.toDer(&der_buf);

    var w = Writer{ .buf = buf };
    w.writeU8(@intFromEnum(handshake.HandshakeType.CERTIFICATE_VERIFY));
    const header = w.placeU24();
    w.writeU16(@intFromEnum(handshake.SignatureScheme.ECDSA_SECP256R1_SHA256));
    const sig = w.placeU16();
    w.writeBytes(der);
    w.patchU16(sig);
    w.patchU24(header);

    return w.slice();
}

// --------------------------------------------------------------- //

/// finished_key = HKDF-Expand-Label(BaseKey, "finished", "", Hash.length) (RFC 8446 4.4.4).
pub fn finishedKey(traffic_secret: Secret) Secret {
    var out: Secret = undefined;
    key_schedule.expandLabel(&out, traffic_secret, "finished", "");

    return out;
}

/// Finished verify_data = HMAC(finished_key, Transcript-Hash(...)) (RFC 8446 4.4.4).
pub fn finishedVerifyData(finished_key: Secret, transcript_hash: Secret) Secret {
    var out: Secret = undefined;
    HmacSha256.create(&out, &transcript_hash, &finished_key);

    return out;
}

/// Build the Finished message (RFC 8446 4.4.4) into `buf`, returning the wire slice.
pub fn buildFinished(buf: []u8, finished_key: Secret, transcript_hash: Secret) []const u8 {
    const verify_data = finishedVerifyData(finished_key, transcript_hash);

    var w = Writer{ .buf = buf };
    w.writeU8(@intFromEnum(handshake.HandshakeType.FINISHED));
    const header = w.placeU24();
    w.writeBytes(&verify_data);
    w.patchU24(header);

    return w.slice();
}

// --------------------------------------------------------------- //
// --------------------------------------------------------------- //

test "zix test: certificate, Certificate message wraps the DER (4.4.2)" {
    const der = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };

    var buf: [64]u8 = undefined;
    const msg = buildCertificate(&buf, &der);

    var r = Reader{ .buf = msg };
    try std.testing.expectEqual(@as(u8, 11), try r.readU8());
    _ = try r.readU24();
    try std.testing.expectEqual(@as(u8, 0), try r.readU8());
    const list_len = try r.readU24();
    try std.testing.expect(list_len > 0);
    const entry_len = try r.readU24();
    try std.testing.expectEqualSlices(u8, &der, try r.readBytes(entry_len));
    try std.testing.expectEqual(@as(u16, 0), try r.readU16());
}

test "zix test: certificate, CertificateVerify content + ECDSA P-256 sign/verify (4.4.3)" {
    var transcript: Secret = undefined;
    _ = try std.fmt.hexToBytes(&transcript, "edb7725fa7a3473b031ec8ef65a2485493900138a2b91291407d7951a06110ed");

    var content_buf: [certificate_verify_content_len]u8 = undefined;
    const content = certificateVerifyContent(&content_buf, transcript);
    for (content[0..64]) |b| try std.testing.expectEqual(@as(u8, 0x20), b);
    try std.testing.expectEqualStrings(certificate_verify_context, content[64 .. 64 + certificate_verify_context.len]);
    try std.testing.expectEqual(@as(u8, 0), content[64 + certificate_verify_context.len]);

    var scalar: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&scalar, "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c");
    const key_pair = try EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(scalar));

    var msg_buf: [256]u8 = undefined;
    const msg = try buildCertificateVerify(&msg_buf, key_pair, transcript);

    var r = Reader{ .buf = msg };
    try std.testing.expectEqual(@as(u8, 15), try r.readU8());
    _ = try r.readU24();
    try std.testing.expectEqual(@as(u16, 0x0403), try r.readU16());
    const sig_len = try r.readU16();
    const signature = try EcdsaP256.Signature.fromDer(try r.readBytes(sig_len));
    try signature.verify(content, key_pair.public_key);

    var bad = transcript;
    bad[0] ^= 0x01;
    var bad_buf: [certificate_verify_content_len]u8 = undefined;
    const bad_content = certificateVerifyContent(&bad_buf, bad);
    const tamper_rejected = if (signature.verify(bad_content, key_pair.public_key)) false else |_| true;
    try std.testing.expect(tamper_rejected);
}

test "zix test: certificate, Finished verify_data byte-exact vs RFC 8448 (4.4.4)" {
    var server_hs_traffic: Secret = undefined;
    _ = try std.fmt.hexToBytes(&server_hs_traffic, "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38");
    var transcript: Secret = undefined;
    _ = try std.fmt.hexToBytes(&transcript, "edb7725fa7a3473b031ec8ef65a2485493900138a2b91291407d7951a06110ed");

    const fk = finishedKey(server_hs_traffic);
    var expected_fk: Secret = undefined;
    _ = try std.fmt.hexToBytes(&expected_fk, "008d3b66f816ea559f96b537e885c31fc068bf492c652f01f288a1d8cdc19fc8");
    try std.testing.expectEqualSlices(u8, &expected_fk, &fk);

    const verify_data = finishedVerifyData(fk, transcript);
    var expected_vd: Secret = undefined;
    _ = try std.fmt.hexToBytes(&expected_vd, "9b9b141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718");
    try std.testing.expectEqualSlices(u8, &expected_vd, &verify_data);

    var bad = transcript;
    bad[0] ^= 0x01;
    try std.testing.expect(!std.mem.eql(u8, &finishedVerifyData(fk, bad), &expected_vd));

    var fin_buf: [64]u8 = undefined;
    const fin = buildFinished(&fin_buf, fk, transcript);
    try std.testing.expectEqual(@as(u8, 20), fin[0]);
    try std.testing.expectEqualSlices(u8, &expected_vd, fin[4..]);
}
