//! zwte jwt (HS256 compact, RFC 7519)

const std = @import("std");

const base64url = @import("base64url.zig");
const claims = @import("claims.zig");
const hmac = @import("hmac.zig");

// --------------------------------------------------------- //

/// HS256 JWT protected header, kept as a comptime constant.
pub const HEADER_JSON = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";

/// base64url of `HEADER_JSON`, 36 chars.
pub const HEADER_B64: []const u8 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

/// HS256 requires a key at least as large as the hash output (RFC 7518 section 3.2).
pub const MIN_KEY_LENGTH: usize = hmac.SIGNATURE_LENGTH;

/// base64url length of the 32-byte HS256 signature.
pub const SIGNATURE_B64_LENGTH: usize = base64url.encodedLength(hmac.SIGNATURE_LENGTH);

/// Largest decoded header accepted by verify.
const MAX_HEADER_LENGTH: usize = 512;

// --------------------------------------------------------- //

/// Exact token size for a base64url payload of `payload_b64_len` chars.
pub fn tokenLength(payload_b64_len: usize) usize {
    return HEADER_B64.len + 1 + payload_b64_len + 1 + SIGNATURE_B64_LENGTH;
}

/// Sign an HS256 JWT.
///
/// Note:
/// - `payload_b64` is the base64url payload part, already encoded.
/// - `out` must hold at least `tokenLength(payload_b64.len)` bytes.
/// - Returns the written token slice.
pub fn sign(key: []const u8, payload_b64: []const u8, out: []u8) ![]const u8 {
    if (key.len < MIN_KEY_LENGTH) return error.KeyTooShort;

    const token_len = tokenLength(payload_b64.len);
    if (out.len < token_len) return error.NoSpaceLeft;

    var index: usize = 0;

    @memcpy(out[index..][0..HEADER_B64.len], HEADER_B64);
    index += HEADER_B64.len;

    out[index] = '.';
    index += 1;

    @memcpy(out[index..][0..payload_b64.len], payload_b64);
    index += payload_b64.len;

    const signature = hmac.sign(key, out[0..index]);

    out[index] = '.';
    index += 1;

    const signature_b64 = try base64url.encode(&signature, out[index..]);
    index += signature_b64.len;

    return out[0..index];
}

/// Verify an HS256 JWT and decode its payload.
///
/// Note:
/// - Checks the signature first, then the header `alg` field.
/// - `payload_out` receives the decoded payload bytes.
/// - Returns the written payload slice.
pub fn verify(key: []const u8, token: []const u8, payload_out: []u8) ![]const u8 {
    var header_buf: [MAX_HEADER_LENGTH]u8 = undefined;

    const verified = try verifyInternal(key, token, payload_out, &header_buf);

    return verified.payload;
}

/// Verify an HS256 JWT, validate its claims, and decode its payload.
///
/// Note:
/// - Composes `verify` with `claims.validate`.
/// - `payload_out` receives the decoded payload bytes.
/// - Returns the written payload slice.
pub fn verifyClaims(key: []const u8, token: []const u8, payload_out: []u8, options: claims.Options) ![]const u8 {
    var header_buf: [MAX_HEADER_LENGTH]u8 = undefined;

    const verified = try verifyInternal(key, token, payload_out, &header_buf);

    try claims.validate(verified.payload, verified.header, options);

    return verified.payload;
}

const Verified = struct {
    payload: []const u8,
    header: []const u8,
};

fn verifyInternal(key: []const u8, token: []const u8, payload_out: []u8, header_out: []u8) !Verified {
    if (key.len < MIN_KEY_LENGTH) return error.KeyTooShort;

    const first_dot = std.mem.indexOfScalar(u8, token, '.') orelse return error.MalformedToken;
    const rest = token[first_dot + 1 ..];
    const second_relative = std.mem.indexOfScalar(u8, rest, '.') orelse return error.MalformedToken;
    const second_dot = first_dot + 1 + second_relative;

    if (std.mem.indexOfScalar(u8, token[second_dot + 1 ..], '.') != null) {
        return error.MalformedToken;
    }

    const header_b64 = token[0..first_dot];
    const payload_b64 = token[first_dot + 1 .. second_dot];
    const signature_b64 = token[second_dot + 1 ..];

    if (header_b64.len == 0 or signature_b64.len == 0) return error.MalformedToken;

    const signature_len = base64url.decodedLength(signature_b64.len) catch return error.MalformedToken;
    if (signature_len != hmac.SIGNATURE_LENGTH) return error.InvalidSignatureLength;

    var signature_buf: [hmac.SIGNATURE_LENGTH]u8 = undefined;
    const expected = base64url.decode(signature_b64, &signature_buf) catch return error.MalformedToken;

    hmac.verify(key, token[0..second_dot], expected) catch return error.InvalidSignature;

    const header_len = base64url.decodedLength(header_b64.len) catch return error.MalformedToken;
    if (header_len > MAX_HEADER_LENGTH) return error.HeaderTooLarge;
    if (header_out.len < header_len) return error.NoSpaceLeft;

    const header = base64url.decode(header_b64, header_out[0..header_len]) catch return error.MalformedToken;

    try checkHeader(header);

    const payload_len = base64url.decodedLength(payload_b64.len) catch return error.MalformedToken;
    if (payload_out.len < payload_len) return error.NoSpaceLeft;

    const payload = base64url.decode(payload_b64, payload_out) catch return error.MalformedToken;

    return .{ .payload = payload, .header = header };
}

/// Check that the decoded header declares HS256.
fn checkHeader(header: []const u8) !void {
    const algorithm = headerAlgorithm(header) orelse return error.MalformedToken;
    if (!std.mem.eql(u8, algorithm, "HS256")) return error.UnsupportedAlgorithm;
}

/// Extract the string value of the `alg` field from a JOSE header.
///
/// Note:
/// - Targeted scan of a flat header object, not a general JSON parser.
fn headerAlgorithm(header: []const u8) ?[]const u8 {
    const key_position = std.mem.indexOf(u8, header, "\"alg\"") orelse return null;

    var index = key_position + "\"alg\"".len;

    while (index < header.len and std.ascii.isWhitespace(header[index])) index += 1;
    if (index >= header.len or header[index] != ':') return null;
    index += 1;
    while (index < header.len and std.ascii.isWhitespace(header[index])) index += 1;
    if (index >= header.len or header[index] != '"') return null;
    index += 1;

    const value_start = index;

    while (index < header.len and header[index] != '"') index += 1;
    if (index >= header.len) return null;

    return header[value_start..index];
}

// --------------------------------------------------------- //

/// Test helper, build a token with an arbitrary header.
fn buildTestToken(header_json: []const u8, payload_b64: []const u8, key: []const u8, out: []u8) ![]const u8 {
    var header_b64_buf: [128]u8 = undefined;
    const header_b64 = try base64url.encode(header_json, &header_b64_buf);

    const signing_len = header_b64.len + 1 + payload_b64.len;
    if (out.len < signing_len + 1 + SIGNATURE_B64_LENGTH) return error.NoSpaceLeft;

    @memcpy(out[0..][0..header_b64.len], header_b64);
    out[header_b64.len] = '.';
    @memcpy(out[header_b64.len + 1 ..][0..payload_b64.len], payload_b64);

    const signature = hmac.sign(key, out[0..signing_len]);
    out[signing_len] = '.';

    const signature_b64 = try base64url.encode(&signature, out[signing_len + 1 ..]);

    return out[0 .. signing_len + 1 + signature_b64.len];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zwte jwt: sign full token byte-exact" {
    const key = "0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";
    const expected_token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.FO08B83KharVEIjci1WakjzVdRNtQsmpsC7B7L8IkIU";

    var token_buf: [256]u8 = undefined;
    const token = try sign(key, payload_b64, &token_buf);

    try std.testing.expectEqualSlices(u8, expected_token, token);
    try std.testing.expectEqual(tokenLength(payload_b64.len), token.len);

    var payload_buf: [128]u8 = undefined;
    const payload = try verify(key, token, &payload_buf);

    try std.testing.expectEqualSlices(u8, "{\"sub\":\"1234567890\",\"name\":\"John Doe\",\"iat\":1516239022}", payload);
}

test "zwte jwt: verify accepts RFC 7515 A.1 token" {
    const key_hex = "0323354b2b0fa5bc837e0665777ba68f5ab328e6f054c928a90f84b2d2502ebf" ++
        "d3fb5a92d20647ef968ab4c377623d223d2e2172052e4f08c0cd9af567d080a3";
    const token = "eyJ0eXAiOiJKV1QiLA0KICJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlfQ.dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
    const expected_payload = "{\"iss\":\"joe\",\r\n \"exp\":1300819380,\r\n \"http://example.com/is_root\":true}";

    var key: [64]u8 = undefined;
    _ = try std.fmt.hexToBytes(&key, key_hex);

    var payload_buf: [128]u8 = undefined;
    const payload = try verify(&key, token, &payload_buf);

    try std.testing.expectEqualSlices(u8, expected_payload, payload);
}

test "zwte jwt: reject wrong key and tampered token" {
    const key = "0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_buf: [256]u8 = undefined;
    const token = try sign(key, payload_b64, &token_buf);

    var payload_buf: [128]u8 = undefined;
    _ = try verify(key, token, &payload_buf);

    try std.testing.expectError(error.InvalidSignature, verify("ffffffffffffffffffffffffffffffff", token, &payload_buf));

    var tampered_payload: [256]u8 = undefined;
    @memcpy(tampered_payload[0..token.len], token);
    tampered_payload[40] = if (tampered_payload[40] == 'A') 'B' else 'A';

    try std.testing.expectError(error.InvalidSignature, verify(key, tampered_payload[0..token.len], &payload_buf));

    var tampered_signature: [256]u8 = undefined;
    @memcpy(tampered_signature[0..token.len], token);
    tampered_signature[token.len - 20] = if (tampered_signature[token.len - 20] == 'A') 'B' else 'A';

    try std.testing.expectError(error.InvalidSignature, verify(key, tampered_signature[0..token.len], &payload_buf));
}

test "zwte jwt: reject malformed tokens" {
    const key = "0123456789abcdef0123456789abcdef";
    var payload_buf: [128]u8 = undefined;

    try std.testing.expectError(error.MalformedToken, verify(key, "", &payload_buf));
    try std.testing.expectError(error.MalformedToken, verify(key, "a.b", &payload_buf));
    try std.testing.expectError(error.MalformedToken, verify(key, "a.b.c.d", &payload_buf));
    try std.testing.expectError(error.MalformedToken, verify(key, ".b.c", &payload_buf));
    try std.testing.expectError(error.MalformedToken, verify(key, "a..c", &payload_buf));
    try std.testing.expectError(error.MalformedToken, verify(key, "a.b.", &payload_buf));
}

test "zwte jwt: reject non-HS256 headers" {
    const key = "0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_buf: [512]u8 = undefined;
    var payload_buf: [128]u8 = undefined;

    const none_token = try buildTestToken("{\"alg\":\"none\",\"typ\":\"JWT\"}", payload_b64, key, &token_buf);
    try std.testing.expectError(error.UnsupportedAlgorithm, verify(key, none_token, &payload_buf));

    const rsa_token = try buildTestToken("{\"alg\":\"RS256\",\"typ\":\"JWT\"}", payload_b64, key, &token_buf);
    try std.testing.expectError(error.UnsupportedAlgorithm, verify(key, rsa_token, &payload_buf));

    const missing_token = try buildTestToken("{\"typ\":\"JWT\"}", payload_b64, key, &token_buf);
    try std.testing.expectError(error.MalformedToken, verify(key, missing_token, &payload_buf));

    const spaced_token = try buildTestToken("{\"typ\":\"JWT\", \"alg\" : \"HS256\"}", payload_b64, key, &token_buf);
    _ = try verify(key, spaced_token, &payload_buf);
}

test "zwte jwt: reject short keys and small buffers" {
    const key = "0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_buf: [256]u8 = undefined;
    var payload_buf: [128]u8 = undefined;

    try std.testing.expectError(error.KeyTooShort, sign("short", payload_b64, &token_buf));

    const token = try sign(key, payload_b64, &token_buf);
    try std.testing.expectError(error.KeyTooShort, verify("short", token, &payload_buf));

    var small_token_buf: [10]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, sign(key, payload_b64, &small_token_buf));

    var small_payload_buf: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, verify(key, token, &small_payload_buf));
}

test "zwte jwt: verifyClaims validates registered claims" {
    const key = "0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_buf: [256]u8 = undefined;
    const token = try sign(key, payload_b64, &token_buf);

    var payload_buf: [128]u8 = undefined;

    _ = try verifyClaims(key, token, &payload_buf, .{ .now_s = 1_700_000_000 });
    _ = try verifyClaims(key, token, &payload_buf, .{ .sub = "1234567890", .typ = "JWT", .now_s = 1_700_000_000 });

    try std.testing.expectError(error.IssuedInFuture, verifyClaims(key, token, &payload_buf, .{ .now_s = 1_500_000_000 }));
    try std.testing.expectError(error.InvalidSubject, verifyClaims(key, token, &payload_buf, .{ .sub = "other", .now_s = 1_700_000_000 }));
    try std.testing.expectError(error.InvalidType, verifyClaims(key, token, &payload_buf, .{ .typ = "JWS", .now_s = 1_700_000_000 }));
}
