//! zwte base64url (RFC 4648 section 5, unpadded)

const std = @import("std");

// --------------------------------------------------------- //

/// URL-safe alphabet, RFC 4648 section 5.
pub const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// Reverse lookup, 0xFF marks a byte outside the alphabet.
const decode_table: [256]u8 = table: {
    var values: [256]u8 = undefined;
    @memset(&values, 0xFF);

    for (alphabet, 0..) |char, index| {
        values[char] = @intCast(index);
    }

    break :table values;
};

// --------------------------------------------------------- //

/// Exact encoded size of `input_len` bytes, unpadded.
pub fn encodedLength(input_len: usize) usize {
    return (4 * input_len + 2) / 3;
}

/// Exact decoded size of `input_len` chars.
///
/// Note:
/// - Rejects `input_len % 4 == 1`, which no base64url string can have.
pub fn decodedLength(input_len: usize) !usize {
    if (input_len % 4 == 1) return error.InvalidLength;

    return (input_len * 3) / 4;
}

/// Encode `input` into `out`, unpadded.
///
/// Note:
/// - `out` must hold at least `encodedLength(input.len)` bytes.
/// - Returns the written slice.
pub fn encode(input: []const u8, out: []u8) ![]u8 {
    if (out.len < encodedLength(input.len)) return error.NoSpaceLeft;

    var input_index: usize = 0;
    var output_index: usize = 0;

    while (input_index + 3 <= input.len) : (input_index += 3) {
        const byte_0 = input[input_index];
        const byte_1 = input[input_index + 1];
        const byte_2 = input[input_index + 2];

        out[output_index] = alphabet[byte_0 >> 2];
        out[output_index + 1] = alphabet[((byte_0 & 0x03) << 4) | (byte_1 >> 4)];
        out[output_index + 2] = alphabet[((byte_1 & 0x0F) << 2) | (byte_2 >> 6)];
        out[output_index + 3] = alphabet[byte_2 & 0x3F];

        output_index += 4;
    }

    const remaining = input.len - input_index;

    if (remaining == 1) {
        const byte_0 = input[input_index];

        out[output_index] = alphabet[byte_0 >> 2];
        out[output_index + 1] = alphabet[(byte_0 & 0x03) << 4];

        output_index += 2;
    } else if (remaining == 2) {
        const byte_0 = input[input_index];
        const byte_1 = input[input_index + 1];

        out[output_index] = alphabet[byte_0 >> 2];
        out[output_index + 1] = alphabet[((byte_0 & 0x03) << 4) | (byte_1 >> 4)];
        out[output_index + 2] = alphabet[(byte_1 & 0x0F) << 2];

        output_index += 3;
    }

    return out[0..output_index];
}

/// Decode `input` into `out`, unpadded.
///
/// Note:
/// - Rejects `=` padding and any byte outside the URL-safe alphabet.
/// - `out` must hold at least `decodedLength(input.len)` bytes.
/// - Returns the written slice.
pub fn decode(input: []const u8, out: []u8) ![]u8 {
    const output_len = try decodedLength(input.len);
    if (out.len < output_len) return error.NoSpaceLeft;

    var input_index: usize = 0;
    var output_index: usize = 0;

    while (input_index + 4 <= input.len) : (input_index += 4) {
        const value_0 = decode_table[input[input_index]];
        const value_1 = decode_table[input[input_index + 1]];
        const value_2 = decode_table[input[input_index + 2]];
        const value_3 = decode_table[input[input_index + 3]];

        if (value_0 == 0xFF or value_1 == 0xFF or value_2 == 0xFF or value_3 == 0xFF) {
            return error.InvalidCharacter;
        }

        out[output_index] = (value_0 << 2) | (value_1 >> 4);
        out[output_index + 1] = ((value_1 & 0x0F) << 4) | (value_2 >> 2);
        out[output_index + 2] = ((value_2 & 0x03) << 6) | value_3;

        output_index += 3;
    }

    const remaining = input.len - input_index;

    if (remaining == 2) {
        const value_0 = decode_table[input[input_index]];
        const value_1 = decode_table[input[input_index + 1]];

        if (value_0 == 0xFF or value_1 == 0xFF) return error.InvalidCharacter;

        out[output_index] = (value_0 << 2) | (value_1 >> 4);

        output_index += 1;
    } else if (remaining == 3) {
        const value_0 = decode_table[input[input_index]];
        const value_1 = decode_table[input[input_index + 1]];
        const value_2 = decode_table[input[input_index + 2]];

        if (value_0 == 0xFF or value_1 == 0xFF or value_2 == 0xFF) return error.InvalidCharacter;

        out[output_index] = (value_0 << 2) | (value_1 >> 4);
        out[output_index + 1] = ((value_1 & 0x0F) << 4) | (value_2 >> 2);

        output_index += 2;
    }

    return out[0..output_index];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zwte base64url: RFC 4648 vectors (unpadded, URL-safe)" {
    const cases = [_]struct {
        plain: []const u8,
        encoded: []const u8,
    }{
        .{ .plain = "", .encoded = "" },
        .{ .plain = "f", .encoded = "Zg" },
        .{ .plain = "fo", .encoded = "Zm8" },
        .{ .plain = "foo", .encoded = "Zm9v" },
        .{ .plain = "foob", .encoded = "Zm9vYg" },
        .{ .plain = "fooba", .encoded = "Zm9vYmE" },
        .{ .plain = "foobar", .encoded = "Zm9vYmFy" },
        .{ .plain = "Hello, Zig!", .encoded = "SGVsbG8sIFppZyE" },
    };

    for (cases) |case| {
        var encoded_buf: [64]u8 = undefined;
        const encoded = try encode(case.plain, &encoded_buf);

        try std.testing.expectEqualSlices(u8, case.encoded, encoded);
        try std.testing.expectEqual(encodedLength(case.plain.len), encoded.len);

        var decoded_buf: [64]u8 = undefined;
        const decoded = try decode(encoded, &decoded_buf);

        try std.testing.expectEqualSlices(u8, case.plain, decoded);
    }
}

test "zwte base64url: URL-safe alphabet uses - and _" {
    const input = [_]u8{ 0xFB, 0xFF, 0xBF };

    var encoded_buf: [8]u8 = undefined;
    const encoded = try encode(&input, &encoded_buf);

    try std.testing.expectEqualSlices(u8, "-_-_", encoded);

    var decoded_buf: [8]u8 = undefined;
    const decoded = try decode(encoded, &decoded_buf);

    try std.testing.expectEqualSlices(u8, &input, decoded);
}

test "zwte base64url: round-trip every remainder" {
    var plain: [96]u8 = undefined;
    for (&plain, 0..) |*byte, index| {
        byte.* = @intCast((index * 37 + 11) & 0xFF);
    }

    var encoded_buf: [128]u8 = undefined;
    var decoded_buf: [96]u8 = undefined;

    for (0..97) |length| {
        const input = plain[0..length];
        const encoded = try encode(input, &encoded_buf);

        try std.testing.expectEqual(encodedLength(length), encoded.len);

        const decoded = try decode(encoded, &decoded_buf);

        try std.testing.expectEqualSlices(u8, input, decoded);
    }
}

test "zwte base64url: reject invalid length and characters" {
    var buf: [16]u8 = undefined;

    try std.testing.expectError(error.InvalidLength, decode("A", &buf));
    try std.testing.expectError(error.InvalidLength, decode("AAAAA", &buf));
    try std.testing.expectError(error.InvalidCharacter, decode("A=", &buf));
    try std.testing.expectError(error.InvalidCharacter, decode("Zg==", &buf));
    try std.testing.expectError(error.InvalidCharacter, decode("!!!!", &buf));
    try std.testing.expectError(error.InvalidCharacter, decode("A+A/", &buf));
}

test "zwte base64url: reject short output buffers" {
    var encoded_buf: [2]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, encode("foo", &encoded_buf));

    var decoded_buf: [2]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, decode("Zm9v", &decoded_buf));
}
