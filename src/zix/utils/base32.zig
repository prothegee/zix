//! ZIX utils base32
//!
//! ### file: src/zix/utils/base32.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Base32 encode and decode for RFC 4648.
//! 
//! ### note:
//! 
//! n/a
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

const charset_base32 = @import("charsets.zig").base32;

/// Marker for a byte that is not in the base32 alphabet.
const INVALID: u8 = 0xFF;

/// Return the encoded symbol, or `=` when the input byte is absent.
fn symbolOrPad(index: usize, valid: bool) u8 {
    return if (valid) charset_base32[index] else '=';
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_Base32_InvalidLength,
    ZixUtils_Base32_InvalidCharacter,
    ZixUtils_Base32_OutOfMemory,
};

/// Encode input using base32.
///
/// Note:
/// - Free the result when finished.
///
/// Usage:
/// ```zig
/// const allocator = std.heap.smp_allocator;
/// const encoded = try encode(allocator, "Hello, Zig!");
/// defer allocator.free(encoded);
/// ```
///
/// Return:
/// - []u8 (caller-owned encoded bytes)
/// - Error.ZixUtils_Base32_OutOfMemory when allocation fails
pub fn encode(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    const out_len = ((input.len + 4) / 5) * 8;
    const out = allocator.alloc(u8, out_len) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixUtils_Base32_OutOfMemory,
    };

    var input_idx: usize = 0;
    var output_idx: usize = 0;

    while (input_idx < input.len) {
        const byte0 = input[input_idx];
        const byte1 = if (input_idx + 1 < input.len) input[input_idx + 1] else 0;
        const byte2 = if (input_idx + 2 < input.len) input[input_idx + 2] else 0;
        const byte3 = if (input_idx + 3 < input.len) input[input_idx + 3] else 0;
        const byte4 = if (input_idx + 4 < input.len) input[input_idx + 4] else 0;

        const has_byte1 = input_idx + 1 < input.len;
        const has_byte2 = input_idx + 2 < input.len;
        const has_byte3 = input_idx + 3 < input.len;
        const has_byte4 = input_idx + 4 < input.len;

        out[output_idx] = charset_base32[byte0 >> 3];
        out[output_idx + 1] = charset_base32[((byte0 & 0x07) << 2) | (byte1 >> 6)];
        out[output_idx + 2] = symbolOrPad((byte1 >> 1) & 0x1F, has_byte1);
        out[output_idx + 3] = symbolOrPad(((byte1 & 0x01) << 4) | (byte2 >> 4), has_byte1);
        out[output_idx + 4] = symbolOrPad(((byte2 & 0x0F) << 1) | (byte3 >> 7), has_byte2);
        out[output_idx + 5] = symbolOrPad((byte3 >> 2) & 0x1F, has_byte3);
        out[output_idx + 6] = symbolOrPad(((byte3 & 0x03) << 3) | (byte4 >> 5), has_byte3);
        out[output_idx + 7] = symbolOrPad(byte4 & 0x1F, has_byte4);

        input_idx += 5;
        output_idx += 8;
    }

    return out;
}

/// Decode input using base32.
///
/// Note:
/// - Free the result when finished.
/// - Lowercase letters are accepted.
///
/// Usage:
/// ```zig
/// const allocator = std.heap.smp_allocator;
/// const decoded = try decode(allocator, "JBSWY3DPFQQFU2LHEE======");
/// defer allocator.free(decoded);
/// ```
///
/// Return:
/// - []u8 (caller-owned decoded bytes)
/// - Error.ZixUtils_Base32_InvalidLength when input is not a multiple of 8
/// - Error.ZixUtils_Base32_InvalidCharacter when input holds a non-alphabet byte
/// - Error.ZixUtils_Base32_OutOfMemory when allocation fails
pub fn decode(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    if (input.len % 8 != 0) return Error.ZixUtils_Base32_InvalidLength;

    var table: [256]u8 = undefined;
    for (&table) |*value| {
        value.* = INVALID;
    }

    for (charset_base32, 0..) |char, index| {
        table[char] = @intCast(index);
        // Only A-Z map to lowercase
        if (char >= 'A' and char <= 'Z') {
            table[char + 32] = @intCast(index);
        }
    }

    var valid_len = input.len;
    while (valid_len > 0 and input[valid_len - 1] == '=') {
        valid_len -= 1;
    }
    const out_len = (valid_len * 5) / 8;

    const out = allocator.alloc(u8, out_len) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixUtils_Base32_OutOfMemory,
    };
    errdefer allocator.free(out);

    var output_idx: usize = 0;
    var input_idx: usize = 0;

    while (input_idx < input.len) {
        var chunk: [8]u8 = undefined;
        for (&chunk) |*value| {
            value.* = 0;
        }

        for (0..8) |chunk_idx| {
            if (input_idx + chunk_idx < input.len and input[input_idx + chunk_idx] != '=') {
                const char = input[input_idx + chunk_idx];
                const decoded_value = table[char];

                if (decoded_value == INVALID) {
                    return Error.ZixUtils_Base32_InvalidCharacter;
                }
                chunk[chunk_idx] = decoded_value;
            }
        }

        if (output_idx < out_len) {
            out[output_idx] = (chunk[0] << 3) | (chunk[1] >> 2);
        }
        if (output_idx + 1 < out_len) {
            const value = ((chunk[1] & 3) << 6) | (chunk[2] << 1) | (chunk[3] >> 4);
            out[output_idx + 1] = value;
        }
        if (output_idx + 2 < out_len) {
            out[output_idx + 2] = ((chunk[3] & 0xF) << 4) | (chunk[4] >> 1);
        }
        if (output_idx + 3 < out_len) {
            const value = ((chunk[4] & 1) << 7) | (chunk[5] << 2) | (chunk[6] >> 3);
            out[output_idx + 3] = value;
        }
        if (output_idx + 4 < out_len) {
            out[output_idx + 4] = ((chunk[6] & 7) << 5) | chunk[7];
        }

        output_idx += 5;
        input_idx += 8;
    }

    return out;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils: base32, encodes and decodes RFC 4648 vectors" {
    const allocator = std.testing.allocator;

    const test_cases = [_]struct {
        input: []const u8,
        expected_encoded: []const u8,
    }{
        .{
            .input = "",
            .expected_encoded = "",
        },
        .{
            .input = "f",
            .expected_encoded = "MY======",
        },
        .{
            .input = "fo",
            .expected_encoded = "MZXQ====",
        },
        .{
            .input = "foo",
            .expected_encoded = "MZXW6===",
        },
        .{
            .input = "foob",
            .expected_encoded = "MZXW6YQ=",
        },
        .{
            .input = "fooba",
            .expected_encoded = "MZXW6YTB",
        },
        .{
            .input = "foobar",
            .expected_encoded = "MZXW6YTBOI======",
        },
        .{
            .input = "Hello, Zig!",
            .expected_encoded = "JBSWY3DPFQQFU2LHEE======",
        },
    };

    for (test_cases) |test_case| {
        const encoded = try encode(allocator, test_case.input);
        defer allocator.free(encoded);

        try std.testing.expectEqualSlices(u8, test_case.expected_encoded, encoded);

        const decoded = try decode(allocator, encoded);
        defer allocator.free(decoded);

        try std.testing.expectEqualSlices(u8, test_case.input, decoded);
    }
}

test "zix utils: base32, decodes lowercase input" {
    const allocator = std.testing.allocator;
    const encoded_lower = "jBSWY3DPFQQFU2LHEAYC4MJWEE======";

    const decoded = try decode(allocator, encoded_lower);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, "Hello, Zig 0.16!", decoded);
}

test "zix utils: base32, rejects an invalid character" {
    const allocator = std.testing.allocator;
    const invalid = "JBSWY3DPFQQFU2LHEAYC4MJWEE!!!!!!";

    try std.testing.expectError(
        Error.ZixUtils_Base32_InvalidCharacter,
        decode(allocator, invalid),
    );
}

test "zix utils: base32, rejects a length that is not a multiple of 8" {
    const allocator = std.testing.allocator;
    const invalid_len = "JBSWY3DPFQQFU2LHEAYC4MJWEE";

    try std.testing.expectError(
        Error.ZixUtils_Base32_InvalidLength,
        decode(allocator, invalid_len),
    );
}

test "zix utils: base32, decodes empty input to empty output" {
    const allocator = std.testing.allocator;

    const decoded = try decode(allocator, "");
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

test "zix utils: base32, decodes a full padding block to empty output" {
    const allocator = std.testing.allocator;

    const decoded = try decode(allocator, "========");
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

