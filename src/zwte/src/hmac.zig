//! zwte hmac-sha256 (HS256 primitive)

const std = @import("std");

// --------------------------------------------------------- //

/// HMAC-SHA256 output size in bytes.
pub const SIGNATURE_LENGTH: usize = 32;

// --------------------------------------------------------- //

/// HS256 signature (HMAC-SHA256) over `message` with `key`.
///
/// Note:
/// - Raw HMAC, key-length policy belongs to the caller.
///   HS256 JWT requires a key of at least 32 bytes.
pub fn sign(key: []const u8, message: []const u8) [SIGNATURE_LENGTH]u8 {
    var signature: [SIGNATURE_LENGTH]u8 = undefined;
    std.crypto.auth.hmac.sha2.HmacSha256.create(&signature, message, key);

    return signature;
}

/// HS256 verify (constant-time compare).
///
/// Note:
/// - `expected` is the decoded 32-byte tag, not the base64url text.
pub fn verify(key: []const u8, message: []const u8, expected: []const u8) !void {
    if (expected.len != SIGNATURE_LENGTH) return error.InvalidSignatureLength;

    const computed = sign(key, message);
    const expected_array: *const [SIGNATURE_LENGTH]u8 = expected[0..SIGNATURE_LENGTH];

    if (!std.crypto.timing_safe.eql([SIGNATURE_LENGTH]u8, computed, expected_array.*)) {
        return error.InvalidSignature;
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zwte hmac: RFC 4231 test case 1" {
    var key: [20]u8 = undefined;
    @memset(&key, 0x0b);

    var expected: [SIGNATURE_LENGTH]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7");

    const computed = sign(&key, "Hi There");

    try std.testing.expectEqualSlices(u8, &expected, &computed);
    try verify(&key, "Hi There", &expected);
}

test "zwte hmac: RFC 4231 test case 2" {
    var expected: [SIGNATURE_LENGTH]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843");

    const computed = sign("Jefe", "what do ya want for nothing?");

    try std.testing.expectEqualSlices(u8, &expected, &computed);
}

test "zwte hmac: RFC 7515 A.1 HS256 signature" {
    const key_hex = "0323354b2b0fa5bc837e0665777ba68f5ab328e6f054c928a90f84b2d2502ebf" ++
        "d3fb5a92d20647ef968ab4c377623d223d2e2172052e4f08c0cd9af567d080a3";
    const signature_hex = "7418dfb49799e0254ffa607dd8adbbba16d4254d69d6bff05b58055853848d79";
    const signing_input = "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ";

    var key: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, key_hex);

    var expected: [SIGNATURE_LENGTH]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, signature_hex);

    const computed = sign(&key, signing_input);

    try std.testing.expectEqualSlices(u8, &expected, &computed);
    try verify(&key, signing_input, &expected);
}

test "zwte hmac: verify rejects tamper, wrong key, and bad length" {
    const key = "0123456789abcdef0123456789abcdef";
    const message = "zwte hs256";

    const signature = sign(key, message);

    try verify(key, message, &signature);

    var tampered = signature;
    tampered[0] ^= 0x01;

    try std.testing.expectError(error.InvalidSignature, verify(key, message, &tampered));
    try std.testing.expectError(error.InvalidSignature, verify("wrong-key", message, &signature));
    try std.testing.expectError(error.InvalidSignatureLength, verify(key, message, signature[0..31]));
    try std.testing.expectError(error.InvalidSignatureLength, verify(key, message, ""));
}
