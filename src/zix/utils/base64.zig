//! ZIX utils base64
//!
//! ### file: src/zix/utils/base64.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Base64 encode and decode for RFC 4648.
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

const charset_base64 = @import("charsets.zig").base64;

/// Marker for a byte that is not in the base64 alphabet.
const INVALID: u8 = 0xFF;

/// Return the encoded symbol, or `=` when the input byte is absent.
fn symbolOrPad(index: usize, valid: bool) u8 {
    return if (valid) charset_base64[index] else '=';
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_Base64_InvalidLength,
    ZixUtils_Base64_InvalidCharacter,
    ZixUtils_Base64_OutOfMemory,
};

/// Encode input using base64.
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
/// - Error.ZixUtils_Base64_OutOfMemory when allocation fails
pub fn encode(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    const out_len = ((input.len + 2) / 3) * 4;
    const out = allocator.alloc(u8, out_len) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixUtils_Base64_OutOfMemory,
    };

    var input_idx: usize = 0;
    var output_idx: usize = 0;

    while (input_idx < input.len) {
        const byte0 = input[input_idx];
        const byte1 = if (input_idx + 1 < input.len) input[input_idx + 1] else 0;
        const byte2 = if (input_idx + 2 < input.len) input[input_idx + 2] else 0;

        const has_byte1 = input_idx + 1 < input.len;
        const has_byte2 = input_idx + 2 < input.len;

        out[output_idx] = charset_base64[byte0 >> 2];
        out[output_idx + 1] = charset_base64[((byte0 & 0x03) << 4) | (byte1 >> 4)];
        out[output_idx + 2] = symbolOrPad(((byte1 & 0x0F) << 2) | (byte2 >> 6), has_byte1);
        out[output_idx + 3] = symbolOrPad(byte2 & 0x3F, has_byte2);

        input_idx += 3;
        output_idx += 4;
    }

    return out;
}

/// Decode input using base64.
///
/// Note:
/// - Free the result when finished.
/// - Padding is optional at the end of the input.
///
/// Usage:
/// ```zig
/// const allocator = std.heap.smp_allocator;
/// const decoded = try decode(allocator, "SGVsbG8sIFppZyE=");
/// defer allocator.free(decoded);
/// ```
///
/// Return:
/// - []u8 (caller-owned decoded bytes)
/// - Error.ZixUtils_Base64_InvalidLength when input is not a multiple of 4
/// - Error.ZixUtils_Base64_InvalidCharacter when input holds a non-alphabet byte
/// - Error.ZixUtils_Base64_OutOfMemory when allocation fails
pub fn decode(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    if (input.len % 4 != 0) return Error.ZixUtils_Base64_InvalidLength;

    var table: [256]u8 = undefined;
    for (&table) |*value| {
        value.* = INVALID;
    }

    for (charset_base64, 0..) |char, index| {
        table[char] = @intCast(index);
    }

    var valid_len = input.len;
    while (valid_len > 0 and input[valid_len - 1] == '=') {
        valid_len -= 1;
    }

    const out_len = (valid_len * 3) / 4;
    const out = allocator.alloc(u8, out_len) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixUtils_Base64_OutOfMemory,
    };
    errdefer allocator.free(out);

    var output_idx: usize = 0;
    var input_idx: usize = 0;

    while (input_idx < input.len) {
        var chunk: [4]u8 = undefined;
        for (&chunk) |*value| {
            value.* = 0;
        }

        var valid_chars: usize = 0;
        for (0..4) |chunk_idx| {
            if (input_idx + chunk_idx < input.len and input[input_idx + chunk_idx] != '=') {
                const char = input[input_idx + chunk_idx];
                const decoded_value = table[char];

                if (decoded_value == INVALID) {
                    return Error.ZixUtils_Base64_InvalidCharacter;
                }
                chunk[chunk_idx] = decoded_value;
                valid_chars += 1;
            }
        }

        if (valid_chars >= 2 and output_idx < out_len) {
            out[output_idx] = (chunk[0] << 2) | (chunk[1] >> 4);
        }
        if (valid_chars >= 3 and output_idx + 1 < out_len) {
            out[output_idx + 1] = ((chunk[1] & 0x0F) << 4) | (chunk[2] >> 2);
        }
        if (valid_chars >= 4 and output_idx + 2 < out_len) {
            out[output_idx + 2] = ((chunk[2] & 0x03) << 6) | chunk[3];
        }

        output_idx += 3;
        input_idx += 4;
    }

    return out;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils: base64, encodes and decodes RFC 4648 vectors" {
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
            .expected_encoded = "Zg==",
        },
        .{
            .input = "fo",
            .expected_encoded = "Zm8=",
        },
        .{
            .input = "foo",
            .expected_encoded = "Zm9v",
        },
        .{
            .input = "foob",
            .expected_encoded = "Zm9vYg==",
        },
        .{
            .input = "fooba",
            .expected_encoded = "Zm9vYmE=",
        },
        .{
            .input = "foobar",
            .expected_encoded = "Zm9vYmFy",
        },
        .{
            .input = "Hello, Zig!",
            .expected_encoded = "SGVsbG8sIFppZyE=",
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

test "zix utils: base64, rejects an invalid character" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        Error.ZixUtils_Base64_InvalidCharacter,
        decode(allocator, "!!!!"),
    );
}

test "zix utils: base64, rejects a length that is not a multiple of 4" {
    const allocator = std.testing.allocator;
    const invalid_len = "SGVsbG8sIFppZyAwLjE2IQ=";

    try std.testing.expectError(
        Error.ZixUtils_Base64_InvalidLength,
        decode(allocator, invalid_len),
    );
}

test "zix utils: base64, decodes padded input" {
    const allocator = std.testing.allocator;

    const decoded = try decode(allocator, "Zg==");
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, "f", decoded);
}

test "zix utils: base64, decodes input without padding" {
    const allocator = std.testing.allocator;

    const decoded = try decode(allocator, "Zm9v");
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, "foo", decoded);
}

test "zix utils: base64, decodes empty input to empty output" {
    const allocator = std.testing.allocator;

    const decoded = try decode(allocator, "");
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

test "zix utils: base64, decodes a full padding block to empty output" {
    const allocator = std.testing.allocator;

    const decoded = try decode(allocator, "====");
    defer allocator.free(decoded);

    try std.testing.expectEqual(@as(usize, 0), decoded.len);
}

