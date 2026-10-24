//! zix utils pwhash pbkdf2

const std = @import("std");

// --------------------------------------------------------- //

const SALT_LENGTH = 16;
const DERIVED_LENGTH = 32;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;

// --------------------------------------------------------- //

/// PBKDF2 pwhash create hmac sha256
///
/// Note:
/// - For `rounds` use 600_000 as OWASP recommendation.
pub fn hash(
    io: std.Io,
    allocator: std.mem.Allocator,
    password: []const u8,
    rounds: u32,
    buf: []u8,
) ![]const u8 {
    _ = allocator; // ignore for now

    var salt: [SALT_LENGTH]u8 = undefined;
    io.random(&salt);

    var dk: [DERIVED_LENGTH]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&dk, password, &salt, rounds, HmacSha256);

    const Encoder = std.base64.url_safe_no_pad.Encoder;
    var salt_b64: [Encoder.calcSize(SALT_LENGTH)]u8 = undefined;
    _ = Encoder.encode(&salt_b64, &salt);
    var hash_b64: [Encoder.calcSize(DERIVED_LENGTH)]u8 = undefined;
    _ = Encoder.encode(&hash_b64, &dk);

    return try std.fmt.bufPrint(
        buf,
        "$pbkdf2-sha256$i={d}${s}${s}",
        .{ rounds, salt_b64, hash_b64 },
    );
}

/// PBKDF2 pwhash verify hmac sha256
pub fn verify(
    allocator: std.mem.Allocator,
    password_raw: []const u8,
    password_encoded: []const u8,
) !void {
    _ = allocator;

    var it = std.mem.splitScalar(u8, password_encoded, '$');
    if ((it.next() orelse return error.InvalidEncoding).len != 0) return error.InvalidEncoding;
    if (!std.mem.eql(u8, it.next() orelse return error.InvalidEncoding, "pbkdf2-sha256"))
        return error.InvalidEncoding;

    const rounds_str = it.next() orelse return error.InvalidEncoding;
    if (!std.mem.startsWith(u8, rounds_str, "i=")) return error.InvalidEncoding;
    const rounds = std.fmt.parseInt(u32, rounds_str[2..], 10) catch return error.InvalidEncoding;

    const salt_b64 = it.next() orelse return error.InvalidEncoding;
    const hash_b64 = it.next() orelse return error.InvalidEncoding;
    if (it.next() != null) return error.InvalidEncoding;

    const Decoder = std.base64.url_safe_no_pad.Decoder;
    var salt: [SALT_LENGTH]u8 = undefined;
    Decoder.decode(&salt, salt_b64) catch return error.InvalidEncoding;
    var expected: [DERIVED_LENGTH]u8 = undefined;
    Decoder.decode(&expected, hash_b64) catch return error.InvalidEncoding;

    var dk: [DERIVED_LENGTH]u8 = undefined;
    try std.crypto.pwhash.pbkdf2(&dk, password_raw, &salt, rounds, HmacSha256);

    if (!std.crypto.timing_safe.eql([DERIVED_LENGTH]u8, dk, expected))
        return error.PasswordVerificationFailed;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix utils: pwhash pbkdf2 hash & verify" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const password = "my sUp3r p4s5w0rd!";
    const rounds = 1_000;

    var buf: [128]u8 = undefined;
    const encoded = try hash(io, allocator, password, rounds, &buf);
    try verify(allocator, password, encoded);

    try std.testing.expectError(
        error.PasswordVerificationFailed,
        verify(allocator, "wrong password", encoded),
    );
}
