//! TLZ crypto certificate
//!
//! ### file: src/tlz/src/crypto/certificate.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! TLS 1.3 authentication messages (RFC 8446 section 4.4): Certificate,
//! CertificateRequest, CertificateVerify, and Finished.
//!
//! ### note:
//!
//! The DER certificate comes from the caller. PEM loading and X.509 path checks
//! live in `pem.zig` and `cert_verify.zig`. The Finished bytes are checked against
//! the RFC 8448 trace in the tests below.
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
const Reader = @import("../wire/Reader.zig");
const Writer = @import("../wire/Writer.zig");
const key_schedule = @import("../key_schedule.zig");
const rsa = @import("rsa.zig");
const RsaPrivateKey = @import("rsa/PrivateKey.zig");
const SigningKey = @import("certificate/signing_key.zig").SigningKey;
const HandshakeType = @import("../handshake/handshake_type.zig").HandshakeType;
const ExtensionType = @import("../extension_type.zig").ExtensionType;
const SignatureScheme = @import("../signature_scheme.zig").SignatureScheme;

const Secret = key_schedule.Secret;
const HASH_LENGTH = key_schedule.HASH_LENGTH;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Ed25519 = std.crypto.sign.Ed25519;

// --------------------------------------------------------- //
// Private:

/// The signed content: 64 bytes of 0x20, the context, a 0x00, the transcript hash.
const CERTIFICATE_VERIFY_CONTENT_LEN = 64 + CERTIFICATE_VERIFY_CONTEXT.len + 1 + HASH_LENGTH;

/// The client CertificateVerify path: its own errors plus the wire reader.
const VerifyInner = VerifyError || Reader.Error;

fn verifyInnerError(err: VerifyInner) VerifyError {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_WireReader_Truncated => error.Tlz_Certificate_Truncated,
        error.Tlz_Certificate_Truncated,
        error.Tlz_Certificate_UnsupportedSignatureScheme,
        error.Tlz_Certificate_SignatureFailed,
        => |own| own,
    };
}

fn rsaError(err: RsaPrivateKey.SignError) SignError {
    @branchHint(.cold);

    return switch (err) {
        error.Tlz_RsaPrivateKey_InvalidKey => error.Tlz_Certificate_InvalidKey,
        error.Tlz_RsaPrivateKey_MessageTooLong => error.Tlz_Certificate_MessageTooLong,
    };
}

/// Write the signed content framing for one context string.
fn writeVerifyContent(buf: []u8, context: []const u8, transcript_hash: Secret) []const u8 {
    @memset(buf[0..64], 0x20);
    @memcpy(buf[64 .. 64 + context.len], context);
    buf[64 + context.len] = 0x00;
    @memcpy(buf[64 + context.len + 1 ..][0..HASH_LENGTH], &transcript_hash);

    return buf[0 .. 64 + context.len + 1 + HASH_LENGTH];
}

/// Sign `content` with the key and write the signature bytes.
fn writeSignature(
    writer: *Writer,
    signing_key: SigningKey,
    content: []const u8,
    pss_salt: [rsa.PSS_SALT_LEN]u8,
) SignError!void {
    switch (signing_key) {
        .ecdsa_p256 => |key_pair| {
            const signature = key_pair.sign(content, null) catch |err| switch (err) {
                else => return error.Tlz_Certificate_SignFailed,
            };

            var der_buf: [EcdsaP256.Signature.der_encoded_length_max]u8 = undefined;
            writer.writeBytes(signature.toDer(&der_buf));
        },
        .ed25519 => |key_pair| {
            const signature = key_pair.sign(content, null) catch |err| switch (err) {
                else => return error.Tlz_Certificate_SignFailed,
            };

            writer.writeBytes(&signature.toBytes());
        },
        .rsa => |key| {
            var sig_buf: [rsa.MAX_MODULUS_LEN]u8 = undefined;
            const signature = key.signPss(content, pss_salt, &sig_buf) catch |err| {
                return rsaError(err);
            };

            writer.writeBytes(signature);
        },
    }
}

fn parseEndEntityInner(certificate_body: []const u8) Reader.Error!?[]const u8 {
    var reader: Reader = .{ .buf = certificate_body };

    const context_len = try reader.readU8();
    _ = try reader.readBytes(context_len);

    const list_len = try reader.readU24();
    if (list_len == 0) return null;

    const entry_len = try reader.readU24();

    return try reader.readBytes(entry_len);
}

fn verifyClientInner(
    certificate_verify_body: []const u8,
    public_key: EcdsaP256.PublicKey,
    transcript_hash: Secret,
) VerifyInner!void {
    var reader: Reader = .{ .buf = certificate_verify_body };

    const scheme = try reader.readU16();
    if (scheme != @intFromEnum(SignatureScheme.ECDSA_SECP256R1_SHA256)) {
        return error.Tlz_Certificate_UnsupportedSignatureScheme;
    }

    const sig_len = try reader.readU16();
    const sig_bytes = try reader.readBytes(sig_len);

    var content_buf: [CERTIFICATE_VERIFY_CONTENT_LEN]u8 = undefined;
    const content = clientCertificateVerifyContent(&content_buf, transcript_hash);

    const signature = EcdsaP256.Signature.fromDer(sig_bytes) catch |err| switch (err) {
        else => return error.Tlz_Certificate_SignatureFailed,
    };

    signature.verify(content, public_key) catch |err| switch (err) {
        else => return error.Tlz_Certificate_SignatureFailed,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error{
    Tlz_Certificate_Truncated,
    Tlz_Certificate_UnsupportedSignatureScheme,
    Tlz_Certificate_SignatureFailed,
    Tlz_Certificate_SignFailed,
    Tlz_Certificate_InvalidKey,
    Tlz_Certificate_MessageTooLong,
};

/// CertificateVerify context string for a server signature (RFC 8446 4.4.3).
/// The part of Error `parseEndEntityCertificate` can return.
pub const ParseError = error{
    Tlz_Certificate_Truncated,
};

/// The part of Error `buildCertificateVerify` can return.
pub const SignError = error{
    Tlz_Certificate_SignFailed,
    Tlz_Certificate_InvalidKey,
    Tlz_Certificate_MessageTooLong,
};

/// The part of Error `verifyClientCertificateVerify` can return.
pub const VerifyError = error{
    Tlz_Certificate_Truncated,
    Tlz_Certificate_UnsupportedSignatureScheme,
    Tlz_Certificate_SignatureFailed,
};

pub const CERTIFICATE_VERIFY_CONTEXT = "TLS 1.3, server CertificateVerify";

/// CertificateVerify context string for a client signature (RFC 8446 4.4.3). Same
/// length as the server one, only the role word differs.
pub const CLIENT_CERTIFICATE_VERIFY_CONTEXT = "TLS 1.3, client CertificateVerify";

/// Build the Certificate message (RFC 8446 4.4.2): an empty request context and one
/// end-entity entry holding the DER, with empty entry extensions.
///
/// Param:
/// buf - []u8 (the destination, sized for the whole message)
/// der - []const u8 (the end-entity certificate DER)
///
/// Return:
/// - []const u8 (the wire message, a view into `buf`)
pub fn buildCertificate(buf: []u8, der: []const u8) []const u8 {
    var writer: Writer = .{ .buf = buf };

    writer.writeU8(@intFromEnum(HandshakeType.CERTIFICATE));
    const header = writer.placeU24();

    writer.writeU8(0);

    const list = writer.placeU24();
    const entry = writer.placeU24();
    writer.writeBytes(der);
    writer.patchU24(entry);
    writer.writeU16(0);
    writer.patchU24(list);

    writer.patchU24(header);

    return writer.slice();
}

/// Build the CertificateRequest message (RFC 8446 4.3.2): an empty request context
/// and signature_algorithms offering ecdsa_secp256r1_sha256 and ed25519. Sent to ask
/// for client authentication (mTLS).
///
/// Param:
/// buf - []u8 (the destination, sized for the whole message)
///
/// Return:
/// - []const u8 (the wire message, a view into `buf`)
pub fn buildCertificateRequest(buf: []u8) []const u8 {
    var writer: Writer = .{ .buf = buf };

    writer.writeU8(@intFromEnum(HandshakeType.CERTIFICATE_REQUEST));
    const header = writer.placeU24();

    writer.writeU8(0);

    const extensions = writer.placeU16();
    writer.writeU16(@intFromEnum(ExtensionType.SIGNATURE_ALGORITHMS));
    const ext_body = writer.placeU16();
    const scheme_list = writer.placeU16();
    writer.writeU16(@intFromEnum(SignatureScheme.ECDSA_SECP256R1_SHA256));
    writer.writeU16(@intFromEnum(SignatureScheme.ED25519));
    writer.patchU16(scheme_list);
    writer.patchU16(ext_body);
    writer.patchU16(extensions);

    writer.patchU24(header);

    return writer.slice();
}

/// Extract the end-entity certificate DER from a Certificate message body
/// (RFC 8446 4.4.2), the bytes after the 4-byte handshake header.
///
/// Param:
/// certificate_body - []const u8 (the message body)
///
/// Return:
/// - []const u8 (the first entry DER, a view into `certificate_body`)
/// - null when the certificate_list is empty (the client declined auth)
/// - Error.Tlz_Certificate_Truncated on truncated input
pub fn parseEndEntityCertificate(certificate_body: []const u8) ParseError!?[]const u8 {
    return parseEndEntityInner(certificate_body) catch |err| switch (err) {
        error.Tlz_WireReader_Truncated => error.Tlz_Certificate_Truncated,
    };
}

/// The server CertificateVerify signed content (RFC 8446 4.4.3).
///
/// Param:
/// buf - []u8 (at least the content length)
/// transcript_hash - Secret (the transcript hash through Certificate)
///
/// Return:
/// - []const u8 (the content, a view into `buf`)
pub fn certificateVerifyContent(buf: []u8, transcript_hash: Secret) []const u8 {
    return writeVerifyContent(buf, CERTIFICATE_VERIFY_CONTEXT, transcript_hash);
}

/// The client CertificateVerify signed content (RFC 8446 4.4.3).
///
/// Param:
/// buf - []u8 (at least the content length)
/// transcript_hash - Secret (the transcript hash through the client Certificate)
///
/// Return:
/// - []const u8 (the content, a view into `buf`)
pub fn clientCertificateVerifyContent(buf: []u8, transcript_hash: Secret) []const u8 {
    return writeVerifyContent(buf, CLIENT_CERTIFICATE_VERIFY_CONTEXT, transcript_hash);
}

/// Sign the CertificateVerify content and emit the message (RFC 8446 4.4.3). The
/// wire scheme is the key's own scheme.
///
/// Note:
/// - `pss_salt` is read only by the RSA path. The ECDSA and Ed25519 paths ignore it.
///
/// Param:
/// buf - []u8 (the destination, sized for the whole message)
/// signing_key - SigningKey (the server key)
/// transcript_hash - Secret (the transcript hash through Certificate)
/// pss_salt - [rsa.PSS_SALT_LEN]u8 (the random salt for an RSA PSS signature)
///
/// Return:
/// - []const u8 (the wire message, a view into `buf`)
/// - Error.Tlz_Certificate_SignFailed when std refuses to sign
/// - Error.Tlz_Certificate_InvalidKey or MessageTooLong from the RSA path
pub fn buildCertificateVerify(
    buf: []u8,
    signing_key: SigningKey,
    transcript_hash: Secret,
    pss_salt: [rsa.PSS_SALT_LEN]u8,
) SignError![]const u8 {
    var content_buf: [CERTIFICATE_VERIFY_CONTENT_LEN]u8 = undefined;
    const content = certificateVerifyContent(&content_buf, transcript_hash);

    var writer: Writer = .{ .buf = buf };
    writer.writeU8(@intFromEnum(HandshakeType.CERTIFICATE_VERIFY));
    const header = writer.placeU24();
    writer.writeU16(@intFromEnum(signing_key.scheme()));
    const sig = writer.placeU16();

    try writeSignature(&writer, signing_key, content, pss_salt);

    writer.patchU16(sig);
    writer.patchU24(header);

    return writer.slice();
}

/// Verify a client CertificateVerify body (RFC 8446 4.4.3) against the client
/// certificate key.
///
/// Param:
/// certificate_verify_body - []const u8 (the message after the 4-byte header)
/// public_key - EcdsaP256.PublicKey (from the client end-entity certificate)
/// transcript_hash - Secret (the transcript through the client Certificate)
///
/// Return:
/// - void on a valid signature
/// - Error.Tlz_Certificate_UnsupportedSignatureScheme when not ecdsa_secp256r1_sha256
/// - Error.Tlz_Certificate_SignatureFailed when the signature does not verify
/// - Error.Tlz_Certificate_Truncated on truncated input
pub fn verifyClientCertificateVerify(
    certificate_verify_body: []const u8,
    public_key: EcdsaP256.PublicKey,
    transcript_hash: Secret,
) VerifyError!void {
    verifyClientInner(
        certificate_verify_body,
        public_key,
        transcript_hash,
    ) catch |err| return verifyInnerError(err);
}

/// finished_key = HKDF-Expand-Label(BaseKey, "finished", "", Hash.length)
/// (RFC 8446 4.4.4).
///
/// Param:
/// traffic_secret - Secret (the handshake traffic secret of the sender)
///
/// Return:
/// - Secret
pub fn finishedKey(traffic_secret: Secret) Secret {
    var out: Secret = undefined;
    key_schedule.expandLabel(&out, traffic_secret, "finished", "");

    return out;
}

/// Finished verify_data = HMAC(finished_key, transcript hash) (RFC 8446 4.4.4).
///
/// Param:
/// finished_key - Secret (from `finishedKey`)
/// transcript_hash - Secret (the transcript hash at this point)
///
/// Return:
/// - Secret
pub fn finishedVerifyData(finished_key: Secret, transcript_hash: Secret) Secret {
    var out: Secret = undefined;
    HmacSha256.create(&out, &transcript_hash, &finished_key);

    return out;
}

/// Build the Finished message (RFC 8446 4.4.4).
///
/// Param:
/// buf - []u8 (the destination, at least 4 + HASH_LENGTH bytes)
/// finished_key - Secret (from `finishedKey`)
/// transcript_hash - Secret (the transcript hash at this point)
///
/// Return:
/// - []const u8 (the wire message, a view into `buf`)
pub fn buildFinished(buf: []u8, finished_key: Secret, transcript_hash: Secret) []const u8 {
    const verify_data = finishedVerifyData(finished_key, transcript_hash);

    var writer: Writer = .{ .buf = buf };
    writer.writeU8(@intFromEnum(HandshakeType.FINISHED));
    const header = writer.placeU24();
    writer.writeBytes(&verify_data);
    writer.patchU24(header);

    return writer.slice();
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pem = @import("pem.zig");
const std_rsa_verify = @import("std_rsa_verify.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// An all-zero salt, for the paths that ignore it.
const ZERO_SALT = std.mem.zeroes([rsa.PSS_SALT_LEN]u8);

const RFC8448_TRANSCRIPT_HEX =
    "edb7725fa7a3473b031ec8ef65a2485493900138a2b91291407d7951a06110ed";
const RFC8448_SERVER_HS_HEX =
    "b67b7d690cc16c4e75e54213cb2d37b4e9c912bcded9105d42befd59d391ad38";
const RFC8448_FINISHED_KEY_HEX =
    "008d3b66f816ea559f96b537e885c31fc068bf492c652f01f288a1d8cdc19fc8";
const RFC8448_VERIFY_DATA_HEX =
    "9b9b141d906337fbd2cbdce71df4deda4ab42c309572cb7fffee5454b78f0718";
const EC_SCALAR_HEX =
    "0b76f7f1c7bf6e20029ddb566795e58da5ba63ffbdb914bf699bfbed3147d32c";

/// A deterministic RSA-2048 PKCS#8 key (openssl genpkey).
const RSA_FIXTURE_PKCS8_PEM =
    \\-----BEGIN PRIVATE KEY-----
    \\MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDiK/ullhGBT/Mj
    \\s1cQ3b7xqIAtHwMjuTxnUne42qU3cUrEeH2/jWjXjEeBMBqt8TYp1FVpDg+u2DGU
    \\Jada+rtFsPVZkD/07HUGXYfya6hwdwOqwjm+fdI+jIIpM+N1t6Ln+eV75GIu8KEr
    \\uRQVTsR3Rz8uMcIN/apvXP1Tus2Y2ZIhAKX9vk2DvL6+7gCLzK0wJmdQ34aGEw89
    \\MRfQLVmTpFvZSJ2B81dxY+IdgbshiZbbn76pzdH4TvxIOwDpUxW16qY7VXZErMtR
    \\S9jnavMpIB1sTkZLKZyIkowWqeeVWIQG85RreOwiEYywRUYnhI44YBxf0Xmgr1x6
    \\CnJ3atxDAgMBAAECggEACaafz9KF/7MWKG1UJ0OXDL/IbGR44VLbqXsC4c/uod2D
    \\N7v+fah+k0gImxIe6VI0IffOBzQS5j6SawRqTj8Js7EX3xEBMaXPXoyqKuV+JAJo
    \\FSbBiQfca0/alACDUbgayvRGXxGBQQiCkBePLFOWnZJcN0/nPGqZFbRtmN+NO1rk
    \\zTD46uKfBAFMKZLbWrK8plECMfea5h+/ysnfhpZXv5nAXuPY6cvwgDTZvphQdB4l
    \\4mjAtuI6oEYUL4CVga1NE57vC02RxJBwylmxznJyJcRdLl52kSgOMU3xV9isrrZT
    \\88s9Ds5ZxtGqaWUmbF+pHW1wxzTmJhrCXxEGtsrmAQKBgQD5u1KiuTlPnnVgIRfT
    \\thzF5pBp6Ynwbw/Q0SMkF/E7yxkPDdLWMY43WIikRj9IyfDnIRxdGEBkprF7/Sm/
    \\ehGVGRDNNT3eRaZ04jLP/EbksO9hF49ro/FlHSaaVrDSAsW3F8HBp8NQC9Sgpdlf
    \\XwnxZsP35wpISF1hWV5be0yWAQKBgQDn2UYCjGCRFdBNdsqxbgGemPBu60/U0leE
    \\T8xg42jN6tO2j0vesKp83NFcAl71NYh7rl8G+WnFJ3DgrjrFAPbTa6VJdnNnpjV+
    \\3o2CSqSTAReFM2khRIZodCbQ3Ad/6P00RnahpciBemQsQKeyGRMrhrkBZbiPIWch
    \\LgBIniOaQwKBgGcmxsVL+K44Z4cjZDIgoNXlnHUC7+UOGtxH5ln8QbpO87TSIuoy
    \\YeneeeJQ2cb5EraFaK/TWpW4fMsYEOx0QVrylYwNl9Z9snnJDO/35liD9PyHvMfb
    \\WdRILC/H6xVz67Lq7y9MWlJv8I3Cs3y/Rt4dcoitOAQPT/Lr9RuYXFQBAoGBAM0U
    \\QXsrlJeBRhnfQ/eiKMiS28ohVyIXVNZyh4QEY8YRO2g2ZJP8jTGZWY8bgcdArRNJ
    \\8ECJCegctRnow49TBQGKLFBI+Ffsi1FHpsBjKiPmSVnHWezVYlaut07z8aZQ/vfo
    \\hDMEI9Fz43vJTQyaZXyQ1MDJq3DfyQtuV03ko/VlAoGBAJiRuT9T8EQO0gJoaS6g
    \\W/+g7A+JUZnqIrCiL9JAaWzOy4TdKtEgbDQsLH1NfVclcnti5C/6wlCqvPcSQtF/
    \\ZGgEuI4ajyq60Un5tOiB1rbJ5sahSLgpM21Ph6kkC6nxTuKfRPpu1+L92SFZBFrX
    \\sIWllpzoV5pFqYoMGir8MZfp
    \\-----END PRIVATE KEY-----
;

fn secretFromHex(comptime hex: []const u8) !Secret {
    var out: Secret = undefined;
    _ = try std.fmt.hexToBytes(&out, hex);

    return out;
}

fn fixtureEcdsaKeyPair() !EcdsaP256.KeyPair {
    const scalar = try secretFromHex(EC_SCALAR_HEX);

    return EcdsaP256.KeyPair.fromSecretKey(try EcdsaP256.SecretKey.fromBytes(scalar));
}

/// Skip the 4-byte handshake header and the 2-byte scheme of a CertificateVerify,
/// then return the signature bytes.
fn certificateVerifySignature(message: []const u8, scheme: *u16) ![]const u8 {
    var reader: Reader = .{ .buf = message };
    _ = try reader.readU8();
    _ = try reader.readU24();
    scheme.* = try reader.readU16();

    const sig_len = try reader.readU16();

    return reader.readBytes(sig_len);
}

test "tlz crypto: certificate, Certificate message wraps the DER" {
    const der = [_]u8{ 0x30, 0x03, 0x01, 0x02, 0x03 };
    var buf: [64]u8 = undefined;

    const message = buildCertificate(&buf, &der);

    var reader: Reader = .{ .buf = message };
    try std.testing.expectEqual(@as(u8, 11), try reader.readU8());
    _ = try reader.readU24();
    try std.testing.expectEqual(@as(u8, 0), try reader.readU8());
    try std.testing.expect(try reader.readU24() > 0);

    const entry_len = try reader.readU24();
    try std.testing.expectEqualSlices(u8, &der, try reader.readBytes(entry_len));
    try std.testing.expectEqual(@as(u16, 0), try reader.readU16());
}

test "tlz crypto: certificate, CertificateVerify content has the RFC framing" {
    const transcript = try secretFromHex(RFC8448_TRANSCRIPT_HEX);
    var content_buf: [CERTIFICATE_VERIFY_CONTENT_LEN]u8 = undefined;

    const content = certificateVerifyContent(&content_buf, transcript);

    for (content[0..64]) |byte| try std.testing.expectEqual(@as(u8, 0x20), byte);
    try std.testing.expectEqualStrings(
        CERTIFICATE_VERIFY_CONTEXT,
        content[64 .. 64 + CERTIFICATE_VERIFY_CONTEXT.len],
    );
    try std.testing.expectEqual(@as(u8, 0), content[64 + CERTIFICATE_VERIFY_CONTEXT.len]);
    try std.testing.expectEqualSlices(u8, &transcript, content[content.len - HASH_LENGTH ..]);
}

test "tlz crypto: certificate, client and server contexts are the same length" {
    try std.testing.expectEqual(
        CERTIFICATE_VERIFY_CONTEXT.len,
        CLIENT_CERTIFICATE_VERIFY_CONTEXT.len,
    );
}

test "tlz crypto: certificate, ECDSA P-256 CertificateVerify verifies" {
    const transcript = try secretFromHex(RFC8448_TRANSCRIPT_HEX);
    const key_pair = try fixtureEcdsaKeyPair();
    var message_buf: [256]u8 = undefined;
    var content_buf: [CERTIFICATE_VERIFY_CONTENT_LEN]u8 = undefined;
    var scheme: u16 = 0;

    const message = try buildCertificateVerify(
        &message_buf,
        .{ .ecdsa_p256 = key_pair },
        transcript,
        ZERO_SALT,
    );
    const sig_bytes = try certificateVerifySignature(message, &scheme);
    const signature = try EcdsaP256.Signature.fromDer(sig_bytes);

    try std.testing.expectEqual(@as(u8, 15), message[0]);
    try std.testing.expectEqual(@as(u16, 0x0403), scheme);
    const content = certificateVerifyContent(&content_buf, transcript);
    try signature.verify(content, key_pair.public_key);
}

test "tlz crypto: certificate, ECDSA P-256 CertificateVerify rejects a tampered transcript" {
    const transcript = try secretFromHex(RFC8448_TRANSCRIPT_HEX);
    const key_pair = try fixtureEcdsaKeyPair();
    var message_buf: [256]u8 = undefined;
    var content_buf: [CERTIFICATE_VERIFY_CONTENT_LEN]u8 = undefined;
    var scheme: u16 = 0;
    var tampered = transcript;
    tampered[0] ^= 0x01;

    const message = try buildCertificateVerify(
        &message_buf,
        .{ .ecdsa_p256 = key_pair },
        transcript,
        ZERO_SALT,
    );
    const signature = try EcdsaP256.Signature.fromDer(
        try certificateVerifySignature(message, &scheme),
    );

    try std.testing.expectError(
        error.SignatureVerificationFailed,
        signature.verify(certificateVerifyContent(&content_buf, tampered), key_pair.public_key),
    );
}

test "tlz crypto: certificate, Ed25519 CertificateVerify emits scheme 0x0807" {
    const transcript = try secretFromHex(RFC8448_TRANSCRIPT_HEX);
    const key_pair = try Ed25519.KeyPair.generateDeterministic(@splat(0x42));
    var message_buf: [256]u8 = undefined;
    var content_buf: [CERTIFICATE_VERIFY_CONTENT_LEN]u8 = undefined;
    var scheme: u16 = 0;

    const message = try buildCertificateVerify(
        &message_buf,
        .{ .ed25519 = key_pair },
        transcript,
        ZERO_SALT,
    );
    const sig_bytes = try certificateVerifySignature(message, &scheme);
    const signature = Ed25519.Signature.fromBytes(sig_bytes[0..64].*);

    try std.testing.expectEqual(@as(u16, 0x0807), scheme);
    const content = certificateVerifyContent(&content_buf, transcript);
    try signature.verify(content, key_pair.public_key);
}

test "tlz crypto: certificate, RSA CertificateVerify emits a 256-byte PSS signature" {
    const transcript: Secret = @splat(0x33);
    var der_buf: [4096]u8 = undefined;
    const der = try pem.pemToDer(&der_buf, RSA_FIXTURE_PKCS8_PEM);
    const key = try RsaPrivateKey.fromDer(der, true);
    const salt: [rsa.PSS_SALT_LEN]u8 = @splat(0x5a);
    var message_buf: [512]u8 = undefined;
    var scheme: u16 = 0;

    const message = try buildCertificateVerify(&message_buf, .{ .rsa = key }, transcript, salt);
    const sig_bytes = try certificateVerifySignature(message, &scheme);

    try std.testing.expectEqual(@as(u16, 0x0804), scheme);
    try std.testing.expectEqual(@as(usize, 256), sig_bytes.len);
}

test "tlz crypto: certificate, RSA CertificateVerify PSS signature verifies with std" {
    const transcript: Secret = @splat(0x33);
    var der_buf: [4096]u8 = undefined;
    const der = try pem.pemToDer(&der_buf, RSA_FIXTURE_PKCS8_PEM);
    const key = try RsaPrivateKey.fromDer(der, true);
    const public_key = try std.crypto.Certificate.rsa.PublicKey.fromBytes(
        &[_]u8{ 0x01, 0x00, 0x01 },
        key.modulus(),
    );
    var message_buf: [512]u8 = undefined;
    var content_buf: [CERTIFICATE_VERIFY_CONTENT_LEN]u8 = undefined;
    var scheme: u16 = 0;

    const salt: [rsa.PSS_SALT_LEN]u8 = @splat(0x5a);
    const message = try buildCertificateVerify(&message_buf, .{ .rsa = key }, transcript, salt);
    const sig_bytes = try certificateVerifySignature(message, &scheme);
    const content = certificateVerifyContent(&content_buf, transcript);

    try std_rsa_verify.verifyPss(256, sig_bytes[0..256], content, public_key, Sha256);
}

test "tlz crypto: certificate, RSA CertificateVerify with a bad key is an invalid key" {
    const transcript: Secret = @splat(0x33);
    var message_buf: [512]u8 = undefined;
    const bad_key: RsaPrivateKey = .{
        .n_len = 1,
        .n_buf = @splat(0),
    };

    try std.testing.expectError(
        Error.Tlz_Certificate_InvalidKey,
        buildCertificateVerify(&message_buf, .{ .rsa = bad_key }, transcript, ZERO_SALT),
    );
}

test "tlz crypto: certificate, Finished key matches RFC 8448" {
    const server_hs = try secretFromHex(RFC8448_SERVER_HS_HEX);
    const expected = try secretFromHex(RFC8448_FINISHED_KEY_HEX);

    try std.testing.expectEqualSlices(u8, &expected, &finishedKey(server_hs));
}

test "tlz crypto: certificate, Finished verify_data matches RFC 8448" {
    const server_hs = try secretFromHex(RFC8448_SERVER_HS_HEX);
    const transcript = try secretFromHex(RFC8448_TRANSCRIPT_HEX);
    const expected = try secretFromHex(RFC8448_VERIFY_DATA_HEX);

    const verify_data = finishedVerifyData(finishedKey(server_hs), transcript);

    try std.testing.expectEqualSlices(u8, &expected, &verify_data);
}

test "tlz crypto: certificate, Finished verify_data changes with the transcript" {
    const server_hs = try secretFromHex(RFC8448_SERVER_HS_HEX);
    const expected = try secretFromHex(RFC8448_VERIFY_DATA_HEX);
    var tampered = try secretFromHex(RFC8448_TRANSCRIPT_HEX);
    tampered[0] ^= 0x01;

    const verify_data = finishedVerifyData(finishedKey(server_hs), tampered);

    try std.testing.expect(!std.mem.eql(u8, &expected, &verify_data));
}

test "tlz crypto: certificate, Finished message carries verify_data" {
    const server_hs = try secretFromHex(RFC8448_SERVER_HS_HEX);
    const transcript = try secretFromHex(RFC8448_TRANSCRIPT_HEX);
    const expected = try secretFromHex(RFC8448_VERIFY_DATA_HEX);
    var finished_buf: [64]u8 = undefined;

    const finished = buildFinished(&finished_buf, finishedKey(server_hs), transcript);

    try std.testing.expectEqual(@as(u8, 20), finished[0]);
    try std.testing.expectEqualSlices(u8, &expected, finished[4..]);
}

test "tlz crypto: certificate, CertificateRequest offers ECDSA then Ed25519" {
    var buf: [64]u8 = undefined;

    const message = buildCertificateRequest(&buf);

    var reader: Reader = .{ .buf = message };
    try std.testing.expectEqual(@as(u8, 13), try reader.readU8());
    _ = try reader.readU24();
    try std.testing.expectEqual(@as(u8, 0), try reader.readU8());
    _ = try reader.readU16();
    try std.testing.expectEqual(@as(u16, 0x000d), try reader.readU16());
    _ = try reader.readU16();
    try std.testing.expectEqual(@as(u16, 4), try reader.readU16());
    try std.testing.expectEqual(@as(u16, 0x0403), try reader.readU16());
    try std.testing.expectEqual(@as(u16, 0x0807), try reader.readU16());
}

test "tlz crypto: certificate, parseEndEntityCertificate recovers the DER" {
    const der = [_]u8{ 0x30, 0x05, 0x01, 0x02, 0x03, 0x04 };
    var buf: [64]u8 = undefined;
    const message = buildCertificate(&buf, &der);

    const recovered = try parseEndEntityCertificate(message[4..]);

    try std.testing.expectEqualSlices(u8, &der, recovered.?);
}

test "tlz crypto: certificate, parseEndEntityCertificate on an empty list is null" {
    const empty_body = [_]u8{ 0x00, 0x00, 0x00, 0x00 };

    const recovered = try parseEndEntityCertificate(&empty_body);

    try std.testing.expectEqual(@as(?[]const u8, null), recovered);
}

test "tlz crypto: certificate, parseEndEntityCertificate on truncated input is truncated" {
    const truncated = [_]u8{ 0x00, 0x00, 0x00, 0x08, 0x00, 0x00 };

    try std.testing.expectError(
        Error.Tlz_Certificate_Truncated,
        parseEndEntityCertificate(&truncated),
    );
}

test "tlz crypto: certificate, client CertificateVerify verifies" {
    const transcript = try secretFromHex(RFC8448_TRANSCRIPT_HEX);
    const key_pair = try fixtureEcdsaKeyPair();
    var content_buf: [CERTIFICATE_VERIFY_CONTENT_LEN]u8 = undefined;
    const content = clientCertificateVerifyContent(&content_buf, transcript);
    const signature = try key_pair.sign(content, null);
    var der_buf: [EcdsaP256.Signature.der_encoded_length_max]u8 = undefined;
    var body_buf: [256]u8 = undefined;
    var writer: Writer = .{ .buf = &body_buf };
    writer.writeU16(@intFromEnum(SignatureScheme.ECDSA_SECP256R1_SHA256));
    const sig = writer.placeU16();
    writer.writeBytes(signature.toDer(&der_buf));
    writer.patchU16(sig);

    try verifyClientCertificateVerify(writer.slice(), key_pair.public_key, transcript);
}

test "tlz crypto: certificate, client CertificateVerify rejects a tampered transcript" {
    const transcript = try secretFromHex(RFC8448_TRANSCRIPT_HEX);
    const key_pair = try fixtureEcdsaKeyPair();
    var content_buf: [CERTIFICATE_VERIFY_CONTENT_LEN]u8 = undefined;
    const content = clientCertificateVerifyContent(&content_buf, transcript);
    const signature = try key_pair.sign(content, null);
    var der_buf: [EcdsaP256.Signature.der_encoded_length_max]u8 = undefined;
    var body_buf: [256]u8 = undefined;
    var writer: Writer = .{ .buf = &body_buf };
    writer.writeU16(@intFromEnum(SignatureScheme.ECDSA_SECP256R1_SHA256));
    const sig = writer.placeU16();
    writer.writeBytes(signature.toDer(&der_buf));
    writer.patchU16(sig);
    var tampered = transcript;
    tampered[0] ^= 0x01;

    try std.testing.expectError(
        Error.Tlz_Certificate_SignatureFailed,
        verifyClientCertificateVerify(writer.slice(), key_pair.public_key, tampered),
    );
}

test "tlz crypto: certificate, client CertificateVerify with Ed25519 is unsupported" {
    const key_pair = try fixtureEcdsaKeyPair();
    const body = [_]u8{ 0x08, 0x07, 0x00, 0x00 };

    try std.testing.expectError(
        Error.Tlz_Certificate_UnsupportedSignatureScheme,
        verifyClientCertificateVerify(&body, key_pair.public_key, @splat(0)),
    );
}

test "tlz crypto: certificate, client CertificateVerify on empty input is truncated" {
    const key_pair = try fixtureEcdsaKeyPair();

    try std.testing.expectError(
        Error.Tlz_Certificate_Truncated,
        verifyClientCertificateVerify(&.{}, key_pair.public_key, @splat(0)),
    );
}

