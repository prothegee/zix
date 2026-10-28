//! zwte jwt (HS256 compact, RFC 7519)
//! zwte jwt (HS384 compact, RFC 7519)
//! zwte jwt (HS512 compact, RFC 7519)

const std = @import("std");

const base64url = @import("base64url.zig");
const claims = @import("claims.zig");
const hmac = @import("hmac.zig");

// --------------------------------------------------------- //

/// HS256 JWT protected header, kept as a comptime constant.
pub const HEADER_JSON = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";

/// base64url of `HEADER_JSON`, 36 chars.
pub const HEADER_B64: []const u8 = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9";

/// Recommended HS256 key minimum (RFC 7518 section 3.2).
pub const MIN_KEY_LENGTH: usize = hmac.SIGNATURE_LENGTH;

/// HS384 JWT protected header, kept as a comptime constant.
pub const HEADER_JSON_384 = "{\"alg\":\"HS384\",\"typ\":\"JWT\"}";

/// base64url of `HEADER_JSON_384`, 36 chars.
pub const HEADER_B64_384: []const u8 = "eyJhbGciOiJIUzM4NCIsInR5cCI6IkpXVCJ9";

/// Recommended HS384 key minimum (RFC 7518 section 3.2).
pub const MIN_KEY_LENGTH_384: usize = hmac.SIGNATURE_LENGTH_384;

/// HS512 JWT protected header, kept as a comptime constant.
pub const HEADER_JSON_512 = "{\"alg\":\"HS512\",\"typ\":\"JWT\"}";

/// base64url of `HEADER_JSON_512`, 36 chars.
pub const HEADER_B64_512: []const u8 = "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9";

/// Recommended HS512 key minimum (RFC 7518 section 3.2).
pub const MIN_KEY_LENGTH_512: usize = hmac.SIGNATURE_LENGTH_512;

/// Per-call key policy.
///
/// Note:
/// - `min_key_length` is the HMAC shared-secret minimum in bytes.
/// - The default follows RFC 7518 section 3.2 (256 bits for HS256).
/// - null selects the algorithm default.
pub const KeyPolicy = struct {
    min_key_length: ?usize = null,
};

/// base64url length of the 32-byte HS256 signature.
pub const SIGNATURE_B64_LENGTH: usize = base64url.encodedLength(hmac.SIGNATURE_LENGTH);

/// base64url length of the 48-byte HS384 signature.
pub const SIGNATURE_B64_LENGTH_384: usize = base64url.encodedLength(hmac.SIGNATURE_LENGTH_384);

/// base64url length of the 64-byte HS512 signature.
pub const SIGNATURE_B64_LENGTH_512: usize = base64url.encodedLength(hmac.SIGNATURE_LENGTH_512);

/// Largest decoded header accepted by verify.
const MAX_HEADER_LENGTH: usize = 512;

/// Supported JWT algorithm variants.
const Algorithm = enum {
    hs256,
    hs384,
    hs512,

    fn headerB64(self: Algorithm) []const u8 {
        return switch (self) {
            .hs256 => HEADER_B64,
            .hs384 => HEADER_B64_384,
            .hs512 => HEADER_B64_512,
        };
    }

    fn signatureLength(self: Algorithm) usize {
        return switch (self) {
            .hs256 => hmac.SIGNATURE_LENGTH,
            .hs384 => hmac.SIGNATURE_LENGTH_384,
            .hs512 => hmac.SIGNATURE_LENGTH_512,
        };
    }

    fn signatureB64Length(self: Algorithm) usize {
        return switch (self) {
            .hs256 => SIGNATURE_B64_LENGTH,
            .hs384 => SIGNATURE_B64_LENGTH_384,
            .hs512 => SIGNATURE_B64_LENGTH_512,
        };
    }

    fn minKeyLength(self: Algorithm) usize {
        return switch (self) {
            .hs256 => MIN_KEY_LENGTH,
            .hs384 => MIN_KEY_LENGTH_384,
            .hs512 => MIN_KEY_LENGTH_512,
        };
    }

    fn name(self: Algorithm) []const u8 {
        return switch (self) {
            .hs256 => "HS256",
            .hs384 => "HS384",
            .hs512 => "HS512",
        };
    }
};

// --------------------------------------------------------- //

/// Exact token size for a base64url payload of `payload_b64_len` chars.
pub fn tokenLength(payload_b64_len: usize) usize {
    return tokenLengthWith(.hs256, payload_b64_len);
}

/// Exact token size for an HS384 base64url payload of `payload_b64_len` chars.
pub fn tokenLength384(payload_b64_len: usize) usize {
    return tokenLengthWith(.hs384, payload_b64_len);
}

/// Exact token size for an HS512 base64url payload of `payload_b64_len` chars.
pub fn tokenLength512(payload_b64_len: usize) usize {
    return tokenLengthWith(.hs512, payload_b64_len);
}

fn tokenLengthWith(alg: Algorithm, payload_b64_len: usize) usize {
    return alg.headerB64().len + 1 + payload_b64_len + 1 + alg.signatureB64Length();
}

/// Sign an HS256 JWT.
///
/// Note:
/// - `payload_b64` is the base64url payload part, already encoded.
/// - `out` must hold at least `tokenLength(payload_b64.len)` bytes.
/// - `policy` sets the key minimum, pass `.{}` for the RFC default.
/// - Returns the written token slice.
pub fn sign(key: []const u8, payload_b64: []const u8, out: []u8, policy: KeyPolicy) ![]const u8 {
    return signWith(.hs256, key, payload_b64, out, policy);
}

/// Sign an HS384 JWT.
///
/// Note:
/// - `payload_b64` is the base64url payload part, already encoded.
/// - `out` must hold at least `tokenLength384(payload_b64.len)` bytes.
/// - `policy` sets the key minimum, pass `.{}` for the RFC default (48 bytes).
/// - Returns the written token slice.
pub fn sign384(key: []const u8, payload_b64: []const u8, out: []u8, policy: KeyPolicy) ![]const u8 {
    return signWith(.hs384, key, payload_b64, out, policy);
}

/// Sign an HS512 JWT.
///
/// Note:
/// - `payload_b64` is the base64url payload part, already encoded.
/// - `out` must hold at least `tokenLength512(payload_b64.len)` bytes.
/// - `policy` sets the key minimum, pass `.{}` for the RFC default (64 bytes).
/// - Returns the written token slice.
pub fn sign512(key: []const u8, payload_b64: []const u8, out: []u8, policy: KeyPolicy) ![]const u8 {
    return signWith(.hs512, key, payload_b64, out, policy);
}

fn signWith(alg: Algorithm, key: []const u8, payload_b64: []const u8, out: []u8, policy: KeyPolicy) ![]const u8 {
    const min_key = policy.min_key_length orelse alg.minKeyLength();
    if (key.len < min_key) return error.KeyTooShort;

    const token_len = tokenLengthWith(alg, payload_b64.len);
    if (out.len < token_len) return error.NoSpaceLeft;

    var index: usize = 0;

    @memcpy(out[index..][0..alg.headerB64().len], alg.headerB64());
    index += alg.headerB64().len;

    out[index] = '.';
    index += 1;

    @memcpy(out[index..][0..payload_b64.len], payload_b64);
    index += payload_b64.len;

    var sig_buf: [hmac.SIGNATURE_LENGTH_512]u8 = undefined;
    const sig = signForAlgorithm(alg, key, out[0..index], &sig_buf);

    out[index] = '.';
    index += 1;

    const signature_b64 = try base64url.encode(sig, out[index..]);
    index += signature_b64.len;

    return out[0..index];
}

fn signForAlgorithm(alg: Algorithm, key: []const u8, message: []const u8, buf: *[hmac.SIGNATURE_LENGTH_512]u8) []const u8 {
    return switch (alg) {
        .hs256 => blk: {
            const sig = hmac.sign(key, message);
            @memcpy(buf[0..sig.len], &sig);
            break :blk buf[0..sig.len];
        },
        .hs384 => blk: {
            const sig = hmac.sign384(key, message);
            @memcpy(buf[0..sig.len], &sig);
            break :blk buf[0..sig.len];
        },
        .hs512 => blk: {
            const sig = hmac.sign512(key, message);
            @memcpy(buf[0..sig.len], &sig);
            break :blk buf[0..sig.len];
        },
    };
}

/// Verify an HS256 JWT and decode its payload.
///
/// Note:
/// - Checks the signature first, then the header `alg` field.
/// - `payload_out` receives the decoded payload bytes.
/// - `policy` sets the key minimum, pass `.{}` for the RFC default.
/// - Returns the written payload slice.
pub fn verify(key: []const u8, token: []const u8, payload_out: []u8, policy: KeyPolicy) ![]const u8 {
    return verifyWith(.hs256, key, token, payload_out, policy);
}

/// Verify an HS384 JWT and decode its payload.
///
/// Note:
/// - Checks the signature first, then the header `alg` field.
/// - `payload_out` receives the decoded payload bytes.
/// - `policy` sets the key minimum, pass `.{}` for the RFC default (48 bytes).
/// - Returns the written payload slice.
pub fn verify384(key: []const u8, token: []const u8, payload_out: []u8, policy: KeyPolicy) ![]const u8 {
    return verifyWith(.hs384, key, token, payload_out, policy);
}

/// Verify an HS512 JWT and decode its payload.
///
/// Note:
/// - Checks the signature first, then the header `alg` field.
/// - `payload_out` receives the decoded payload bytes.
/// - `policy` sets the key minimum, pass `.{}` for the RFC default (64 bytes).
/// - Returns the written payload slice.
pub fn verify512(key: []const u8, token: []const u8, payload_out: []u8, policy: KeyPolicy) ![]const u8 {
    return verifyWith(.hs512, key, token, payload_out, policy);
}

fn verifyWith(alg: Algorithm, key: []const u8, token: []const u8, payload_out: []u8, policy: KeyPolicy) ![]const u8 {
    var header_buf: [MAX_HEADER_LENGTH]u8 = undefined;

    const verified = try verifyInternal(alg, key, token, payload_out, &header_buf, policy);

    return verified.payload;
}

/// Verify an HS256 JWT, validate its claims, and decode its payload.
///
/// Note:
/// - Composes `verify` with `claims.validate`.
/// - `payload_out` receives the decoded payload bytes.
/// - `policy` sets the key minimum, pass `.{}` for the RFC default.
/// - Returns the written payload slice.
pub fn verifyClaims(key: []const u8, token: []const u8, payload_out: []u8, policy: KeyPolicy, options: claims.Options) ![]const u8 {
    return verifyClaimsWith(.hs256, key, token, payload_out, policy, options);
}

/// Verify an HS384 JWT, validate its claims, and decode its payload.
///
/// Note:
/// - Composes `verify384` with `claims.validate`.
/// - `payload_out` receives the decoded payload bytes.
/// - `policy` sets the key minimum, pass `.{}` for the RFC default (48 bytes).
/// - Returns the written payload slice.
pub fn verifyClaims384(key: []const u8, token: []const u8, payload_out: []u8, policy: KeyPolicy, options: claims.Options) ![]const u8 {
    return verifyClaimsWith(.hs384, key, token, payload_out, policy, options);
}

/// Verify an HS512 JWT, validate its claims, and decode its payload.
///
/// Note:
/// - Composes `verify512` with `claims.validate`.
/// - `payload_out` receives the decoded payload bytes.
/// - `policy` sets the key minimum, pass `.{}` for the RFC default (64 bytes).
/// - Returns the written payload slice.
pub fn verifyClaims512(key: []const u8, token: []const u8, payload_out: []u8, policy: KeyPolicy, options: claims.Options) ![]const u8 {
    return verifyClaimsWith(.hs512, key, token, payload_out, policy, options);
}

fn verifyClaimsWith(alg: Algorithm, key: []const u8, token: []const u8, payload_out: []u8, policy: KeyPolicy, options: claims.Options) ![]const u8 {
    var header_buf: [MAX_HEADER_LENGTH]u8 = undefined;

    const verified = try verifyInternal(alg, key, token, payload_out, &header_buf, policy);

    try claims.validate(verified.payload, verified.header, options);

    return verified.payload;
}

const Verified = struct {
    payload: []const u8,
    header: []const u8,
};

fn verifyInternal(alg: Algorithm, key: []const u8, token: []const u8, payload_out: []u8, header_out: []u8, policy: KeyPolicy) !Verified {
    const min_key = policy.min_key_length orelse alg.minKeyLength();
    if (key.len < min_key) return error.KeyTooShort;

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
    if (signature_len != alg.signatureLength()) return error.InvalidSignatureLength;

    var signature_buf: [hmac.SIGNATURE_LENGTH_512]u8 = undefined;
    const expected = base64url.decode(signature_b64, signature_buf[0..signature_len]) catch return error.MalformedToken;

    try verifySignature(alg, key, token[0..second_dot], expected);

    const header_len = base64url.decodedLength(header_b64.len) catch return error.MalformedToken;
    if (header_len > MAX_HEADER_LENGTH) return error.HeaderTooLarge;
    if (header_out.len < header_len) return error.NoSpaceLeft;

    const header = base64url.decode(header_b64, header_out[0..header_len]) catch return error.MalformedToken;

    try checkHeader(alg, header);

    const payload_len = base64url.decodedLength(payload_b64.len) catch return error.MalformedToken;
    if (payload_out.len < payload_len) return error.NoSpaceLeft;

    const payload = base64url.decode(payload_b64, payload_out) catch return error.MalformedToken;

    return .{ .payload = payload, .header = header };
}

fn verifySignature(alg: Algorithm, key: []const u8, message: []const u8, expected: []const u8) !void {
    switch (alg) {
        .hs256 => hmac.verify(key, message, expected) catch return error.InvalidSignature,
        .hs384 => hmac.verify384(key, message, expected) catch return error.InvalidSignature,
        .hs512 => hmac.verify512(key, message, expected) catch return error.InvalidSignature,
    }
}

/// Check that the decoded header declares the expected algorithm.
fn checkHeader(alg: Algorithm, header: []const u8) !void {
    const algorithm = headerAlgorithm(header) orelse return error.MalformedToken;
    if (!std.mem.eql(u8, algorithm, alg.name())) return error.UnsupportedAlgorithm;
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
fn buildTestToken(alg: Algorithm, header_json: []const u8, payload_b64: []const u8, key: []const u8, out: []u8) ![]const u8 {
    var header_b64_buf: [128]u8 = undefined;
    const header_b64 = try base64url.encode(header_json, &header_b64_buf);

    const signing_len = header_b64.len + 1 + payload_b64.len;
    if (out.len < signing_len + 1 + alg.signatureB64Length()) return error.NoSpaceLeft;

    @memcpy(out[0..][0..header_b64.len], header_b64);
    out[header_b64.len] = '.';
    @memcpy(out[header_b64.len + 1 ..][0..payload_b64.len], payload_b64);

    var sig_buf: [hmac.SIGNATURE_LENGTH_512]u8 = undefined;
    const sig = signForAlgorithm(alg, key, out[0..signing_len], &sig_buf);
    out[signing_len] = '.';

    const signature_b64 = try base64url.encode(sig, out[signing_len + 1 ..]);

    return out[0 .. signing_len + 1 + signature_b64.len];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zwte jwt: sign full token byte-exact" {
    const key = "0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";
    const expected_token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.FO08B83KharVEIjci1WakjzVdRNtQsmpsC7B7L8IkIU";

    var token_buf: [256]u8 = undefined;
    const token = try sign(key, payload_b64, &token_buf, .{});

    try std.testing.expectEqualSlices(u8, expected_token, token);
    try std.testing.expectEqual(tokenLength(payload_b64.len), token.len);

    var payload_buf: [128]u8 = undefined;
    const payload = try verify(key, token, &payload_buf, .{});

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
    const payload = try verify(&key, token, &payload_buf, .{});

    try std.testing.expectEqualSlices(u8, expected_payload, payload);
}

test "zwte jwt: reject wrong key and tampered token" {
    const key = "0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_buf: [256]u8 = undefined;
    const token = try sign(key, payload_b64, &token_buf, .{});

    var payload_buf: [128]u8 = undefined;
    _ = try verify(key, token, &payload_buf, .{});

    try std.testing.expectError(error.InvalidSignature, verify("ffffffffffffffffffffffffffffffff", token, &payload_buf, .{}));

    var tampered_payload: [256]u8 = undefined;
    @memcpy(tampered_payload[0..token.len], token);
    tampered_payload[40] = if (tampered_payload[40] == 'A') 'B' else 'A';

    try std.testing.expectError(error.InvalidSignature, verify(key, tampered_payload[0..token.len], &payload_buf, .{}));

    var tampered_signature: [256]u8 = undefined;
    @memcpy(tampered_signature[0..token.len], token);
    tampered_signature[token.len - 20] = if (tampered_signature[token.len - 20] == 'A') 'B' else 'A';

    try std.testing.expectError(error.InvalidSignature, verify(key, tampered_signature[0..token.len], &payload_buf, .{}));
}

test "zwte jwt: reject malformed tokens" {
    const key = "0123456789abcdef0123456789abcdef";
    var payload_buf: [128]u8 = undefined;

    try std.testing.expectError(error.MalformedToken, verify(key, "", &payload_buf, .{}));
    try std.testing.expectError(error.MalformedToken, verify(key, "a.b", &payload_buf, .{}));
    try std.testing.expectError(error.MalformedToken, verify(key, "a.b.c.d", &payload_buf, .{}));
    try std.testing.expectError(error.MalformedToken, verify(key, ".b.c", &payload_buf, .{}));
    try std.testing.expectError(error.MalformedToken, verify(key, "a..c", &payload_buf, .{}));
    try std.testing.expectError(error.MalformedToken, verify(key, "a.b.", &payload_buf, .{}));
}

test "zwte jwt: reject non-HS256 headers" {
    const key = "0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_buf: [512]u8 = undefined;
    var payload_buf: [128]u8 = undefined;

    const none_token = try buildTestToken(.hs256, "{\"alg\":\"none\",\"typ\":\"JWT\"}", payload_b64, key, &token_buf);
    try std.testing.expectError(error.UnsupportedAlgorithm, verify(key, none_token, &payload_buf, .{}));

    const rsa_token = try buildTestToken(.hs256, "{\"alg\":\"RS256\",\"typ\":\"JWT\"}", payload_b64, key, &token_buf);
    try std.testing.expectError(error.UnsupportedAlgorithm, verify(key, rsa_token, &payload_buf, .{}));

    const missing_token = try buildTestToken(.hs256, "{\"typ\":\"JWT\"}", payload_b64, key, &token_buf);
    try std.testing.expectError(error.MalformedToken, verify(key, missing_token, &payload_buf, .{}));

    const spaced_token = try buildTestToken(.hs256, "{\"typ\":\"JWT\", \"alg\" : \"HS256\"}", payload_b64, key, &token_buf);
    _ = try verify(key, spaced_token, &payload_buf, .{});
}

test "zwte jwt: reject short keys and small buffers" {
    const key = "0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_buf: [256]u8 = undefined;
    var payload_buf: [128]u8 = undefined;

    try std.testing.expectError(error.KeyTooShort, sign("short", payload_b64, &token_buf, .{}));

    const token = try sign(key, payload_b64, &token_buf, .{});
    try std.testing.expectError(error.KeyTooShort, verify("short", token, &payload_buf, .{}));

    var small_token_buf: [10]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, sign(key, payload_b64, &small_token_buf, .{}));

    var small_payload_buf: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, verify(key, token, &small_payload_buf, .{}));
}

test "zwte jwt: caller adjusts the key minimum" {
    const key = "0123456789abcdef0123456789"; // 26 bytes
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    try std.testing.expectEqual(@as(usize, 26), key.len);

    var token_buf: [256]u8 = undefined;

    try std.testing.expectError(error.KeyTooShort, sign(key, payload_b64, &token_buf, .{}));

    const token = try sign(key, payload_b64, &token_buf, .{ .min_key_length = 26 });

    var payload_buf: [128]u8 = undefined;
    const payload = try verify(key, token, &payload_buf, .{ .min_key_length = 26 });

    try std.testing.expectEqualSlices(u8, "{\"sub\":\"1234567890\",\"name\":\"John Doe\",\"iat\":1516239022}", payload);

    try std.testing.expectError(error.KeyTooShort, verify(key, token, &payload_buf, .{ .min_key_length = 27 }));
}

test "zwte jwt: verifyClaims validates registered claims" {
    const key = "0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_buf: [256]u8 = undefined;
    const token = try sign(key, payload_b64, &token_buf, .{});

    var payload_buf: [128]u8 = undefined;

    _ = try verifyClaims(key, token, &payload_buf, .{}, .{ .now_s = 1_700_000_000 });
    _ = try verifyClaims(key, token, &payload_buf, .{}, .{ .sub = "1234567890", .typ = "JWT", .now_s = 1_700_000_000 });

    try std.testing.expectError(error.IssuedInFuture, verifyClaims(key, token, &payload_buf, .{}, .{ .now_s = 1_500_000_000 }));
    try std.testing.expectError(error.InvalidSubject, verifyClaims(key, token, &payload_buf, .{}, .{ .sub = "other", .now_s = 1_700_000_000 }));
    try std.testing.expectError(error.InvalidType, verifyClaims(key, token, &payload_buf, .{}, .{ .typ = "JWS", .now_s = 1_700_000_000 }));
}

test "zwte jwt: sign and verify HS384 round-trip" {
    const key = "0123456789abcdef0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    try std.testing.expectEqual(@as(usize, 48), key.len);

    var token_buf: [256]u8 = undefined;
    const token = try sign384(key, payload_b64, &token_buf, .{});

    try std.testing.expectEqual(tokenLength384(payload_b64.len), token.len);
    try std.testing.expectEqualSlices(u8, HEADER_B64_384, token[0..HEADER_B64_384.len]);

    var payload_buf: [128]u8 = undefined;
    const payload = try verify384(key, token, &payload_buf, .{});

    try std.testing.expectEqualSlices(u8, "{\"sub\":\"1234567890\",\"name\":\"John Doe\",\"iat\":1516239022}", payload);
}

test "zwte jwt: HS256 and HS384 reject each other" {
    const key_256 = "0123456789abcdef0123456789abcdef";
    const key_384 = "0123456789abcdef0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_256_buf: [256]u8 = undefined;
    const token_256 = try sign(key_256, payload_b64, &token_256_buf, .{});

    var token_384_buf: [256]u8 = undefined;
    const token_384 = try sign384(key_384, payload_b64, &token_384_buf, .{});

    var payload_buf: [128]u8 = undefined;

    try std.testing.expectError(error.InvalidSignatureLength, verify384(key_384, token_256, &payload_buf, .{}));
    try std.testing.expectError(error.InvalidSignatureLength, verify(key_256, token_384, &payload_buf, .{}));
}

test "zwte jwt: HS384 rejects short keys and small buffers" {
    const key = "0123456789abcdef0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_buf: [256]u8 = undefined;
    var payload_buf: [128]u8 = undefined;

    try std.testing.expectError(error.KeyTooShort, sign384("short", payload_b64, &token_buf, .{}));

    const token = try sign384(key, payload_b64, &token_buf, .{});
    try std.testing.expectError(error.KeyTooShort, verify384("short", token, &payload_buf, .{}));

    var small_token_buf: [10]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, sign384(key, payload_b64, &small_token_buf, .{}));

    var small_payload_buf: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, verify384(key, token, &small_payload_buf, .{}));
}

test "zwte jwt: verifyClaims384 validates registered claims" {
    const key = "0123456789abcdef0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_buf: [256]u8 = undefined;
    const token = try sign384(key, payload_b64, &token_buf, .{});

    var payload_buf: [128]u8 = undefined;

    _ = try verifyClaims384(key, token, &payload_buf, .{}, .{ .now_s = 1_700_000_000 });
    _ = try verifyClaims384(key, token, &payload_buf, .{}, .{ .sub = "1234567890", .typ = "JWT", .now_s = 1_700_000_000 });

    try std.testing.expectError(error.IssuedInFuture, verifyClaims384(key, token, &payload_buf, .{}, .{ .now_s = 1_500_000_000 }));
    try std.testing.expectError(error.InvalidSubject, verifyClaims384(key, token, &payload_buf, .{}, .{ .sub = "other", .now_s = 1_700_000_000 }));
    try std.testing.expectError(error.InvalidType, verifyClaims384(key, token, &payload_buf, .{}, .{ .typ = "JWS", .now_s = 1_700_000_000 }));
}

test "zwte jwt: HS384 rejects non-HS384 headers" {
    const key = "0123456789abcdef0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_buf: [512]u8 = undefined;
    var payload_buf: [128]u8 = undefined;

    const none_token = try buildTestToken(.hs384, "{\"alg\":\"none\",\"typ\":\"JWT\"}", payload_b64, key, &token_buf);
    try std.testing.expectError(error.UnsupportedAlgorithm, verify384(key, none_token, &payload_buf, .{}));

    const hs256_token = try buildTestToken(.hs384, "{\"alg\":\"HS256\",\"typ\":\"JWT\"}", payload_b64, key, &token_buf);
    try std.testing.expectError(error.UnsupportedAlgorithm, verify384(key, hs256_token, &payload_buf, .{}));

    const missing_token = try buildTestToken(.hs384, "{\"typ\":\"JWT\"}", payload_b64, key, &token_buf);
    try std.testing.expectError(error.MalformedToken, verify384(key, missing_token, &payload_buf, .{}));
}

test "zwte jwt: sign and verify HS512 round-trip" {
    const key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    try std.testing.expectEqual(@as(usize, 64), key.len);

    var token_buf: [256]u8 = undefined;
    const token = try sign512(key, payload_b64, &token_buf, .{});

    try std.testing.expectEqual(tokenLength512(payload_b64.len), token.len);
    try std.testing.expectEqualSlices(u8, HEADER_B64_512, token[0..HEADER_B64_512.len]);

    var payload_buf: [128]u8 = undefined;
    const payload = try verify512(key, token, &payload_buf, .{});

    try std.testing.expectEqualSlices(u8, "{\"sub\":\"1234567890\",\"name\":\"John Doe\",\"iat\":1516239022}", payload);
}

test "zwte jwt: HS512 rejects other algorithm tokens" {
    const key_256 = "0123456789abcdef0123456789abcdef";
    const key_384 = "0123456789abcdef0123456789abcdef0123456789abcdef";
    const key_512 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_256_buf: [256]u8 = undefined;
    const token_256 = try sign(key_256, payload_b64, &token_256_buf, .{});

    var token_384_buf: [256]u8 = undefined;
    const token_384 = try sign384(key_384, payload_b64, &token_384_buf, .{});

    var token_512_buf: [256]u8 = undefined;
    const token_512 = try sign512(key_512, payload_b64, &token_512_buf, .{});

    var payload_buf: [128]u8 = undefined;

    try std.testing.expectError(error.InvalidSignatureLength, verify512(key_512, token_256, &payload_buf, .{}));
    try std.testing.expectError(error.InvalidSignatureLength, verify512(key_512, token_384, &payload_buf, .{}));
    try std.testing.expectError(error.InvalidSignatureLength, verify384(key_384, token_512, &payload_buf, .{}));
    try std.testing.expectError(error.InvalidSignatureLength, verify(key_256, token_512, &payload_buf, .{}));
}

test "zwte jwt: HS512 rejects short keys and small buffers" {
    const key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_buf: [256]u8 = undefined;
    var payload_buf: [128]u8 = undefined;

    try std.testing.expectError(error.KeyTooShort, sign512("short", payload_b64, &token_buf, .{}));

    const token = try sign512(key, payload_b64, &token_buf, .{});
    try std.testing.expectError(error.KeyTooShort, verify512("short", token, &payload_buf, .{}));

    var small_token_buf: [10]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, sign512(key, payload_b64, &small_token_buf, .{}));

    var small_payload_buf: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, verify512(key, token, &small_payload_buf, .{}));
}

test "zwte jwt: verifyClaims512 validates registered claims" {
    const key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_buf: [256]u8 = undefined;
    const token = try sign512(key, payload_b64, &token_buf, .{});

    var payload_buf: [128]u8 = undefined;

    _ = try verifyClaims512(key, token, &payload_buf, .{}, .{ .now_s = 1_700_000_000 });
    _ = try verifyClaims512(key, token, &payload_buf, .{}, .{ .sub = "1234567890", .typ = "JWT", .now_s = 1_700_000_000 });

    try std.testing.expectError(error.IssuedInFuture, verifyClaims512(key, token, &payload_buf, .{}, .{ .now_s = 1_500_000_000 }));
    try std.testing.expectError(error.InvalidSubject, verifyClaims512(key, token, &payload_buf, .{}, .{ .sub = "other", .now_s = 1_700_000_000 }));
    try std.testing.expectError(error.InvalidType, verifyClaims512(key, token, &payload_buf, .{}, .{ .typ = "JWS", .now_s = 1_700_000_000 }));
}

test "zwte jwt: HS512 rejects non-HS512 headers" {
    const key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const payload_b64 = "eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ";

    var token_buf: [512]u8 = undefined;
    var payload_buf: [128]u8 = undefined;

    const none_token = try buildTestToken(.hs512, "{\"alg\":\"none\",\"typ\":\"JWT\"}", payload_b64, key, &token_buf);
    try std.testing.expectError(error.UnsupportedAlgorithm, verify512(key, none_token, &payload_buf, .{}));

    const hs256_token = try buildTestToken(.hs512, "{\"alg\":\"HS256\",\"typ\":\"JWT\"}", payload_b64, key, &token_buf);
    try std.testing.expectError(error.UnsupportedAlgorithm, verify512(key, hs256_token, &payload_buf, .{}));

    const hs384_token = try buildTestToken(.hs512, "{\"alg\":\"HS384\",\"typ\":\"JWT\"}", payload_b64, key, &token_buf);
    try std.testing.expectError(error.UnsupportedAlgorithm, verify512(key, hs384_token, &payload_buf, .{}));

    const missing_token = try buildTestToken(.hs512, "{\"typ\":\"JWT\"}", payload_b64, key, &token_buf);
    try std.testing.expectError(error.MalformedToken, verify512(key, missing_token, &payload_buf, .{}));
}
