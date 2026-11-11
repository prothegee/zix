//! ZIX Http2 hpack huffman
//!
//! ### file: src/zix/tcp/http2/hpack/huffman.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! HPACK Huffman string encode and decode (RFC 7541 section 5.2).
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
const HUFF = @import("huffman_table.zig").HUFF;

// --------------------------------------------------------- //
// Private:

/// Shortest code in the table. Fewer pending bits can never match a symbol.
const MIN_CODE_BITS: u8 = 5;
/// Longest code in the table. This many pending bits with no match is a bad code.
const MAX_CODE_BITS: u8 = 30;
/// Padding after the last symbol is at most 7 bits (RFC 7541 section 5.2).
const MAX_PADDING_BITS: u8 = 7;

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 hpack huffman error
pub const Error = error {
    ZixHttp2_Huffman_OutputTooSmall,
    ZixHttp2_Huffman_InvalidCode,
};

/// Decode a Huffman-encoded string into out.
///
/// Param:
/// src - []const u8 (the encoded bytes)
/// out - []u8 (destination for the decoded bytes)
///
/// Return:
/// - usize (number of decoded bytes)
/// - error.ZixHttp2_Huffman_OutputTooSmall when out cannot hold the result
/// - error.ZixHttp2_Huffman_InvalidCode when src is not valid Huffman data
pub fn huffDecode(src: []const u8, out: []u8) Error!usize {
    var pending: u64 = 0;
    var bits: u8 = 0;
    var out_pos: usize = 0;

    for (src) |byte| {
        pending = (pending << 8) | byte;
        bits += 8;

        while (bits >= MIN_CODE_BITS) {
            var matched = false;
            for (HUFF, 0..) |sym, sym_idx| {
                if (bits < sym.bits) continue;

                const shift: u6 = @intCast(bits - sym.bits);
                const code_mask = (@as(u64, 1) << sym.bits) - 1;
                if (((pending >> shift) & code_mask) != sym.code) continue;

                if (out_pos >= out.len) return Error.ZixHttp2_Huffman_OutputTooSmall;

                out[out_pos] = @intCast(sym_idx);
                out_pos += 1;
                pending &= (@as(u64, 1) << shift) - 1;
                bits -= sym.bits;
                matched = true;
                break;
            }

            if (matched) continue;
            if (bits >= MAX_CODE_BITS) return Error.ZixHttp2_Huffman_InvalidCode;

            break;
        }
    }

    if (bits > MAX_PADDING_BITS) return Error.ZixHttp2_Huffman_InvalidCode;

    return out_pos;
}

/// Encode src into out using the HPACK Huffman code.
///
/// Param:
/// src - []const u8 (the plain bytes)
/// out - []u8 (destination for the encoded bytes)
///
/// Return:
/// - usize (bytes written)
/// - error.ZixHttp2_Huffman_OutputTooSmall when out cannot hold the result
pub fn huffEncode(src: []const u8, out: []u8) Error!usize {
    var pending: u64 = 0;
    var bits: u8 = 0;
    var pos: usize = 0;

    for (src) |byte| {
        const sym = HUFF[byte];
        pending = (pending << sym.bits) | sym.code;
        bits += sym.bits;

        while (bits >= 8) {
            bits -= 8;
            if (pos >= out.len) return Error.ZixHttp2_Huffman_OutputTooSmall;

            out[pos] = @intCast((pending >> @as(u6, @intCast(bits))) & 0xFF);
            pos += 1;
        }
    }

    if (bits > 0) {
        if (pos >= out.len) return Error.ZixHttp2_Huffman_OutputTooSmall;

        // pad the last byte with 1 bits, the prefix of the EOS code
        const pad_bits: u6 = @intCast(8 - bits);
        const padding = (@as(u64, 1) << pad_bits) - 1;
        out[pos] = @intCast(((pending << pad_bits) | padding) & 0xFF);
        pos += 1;
    }

    return pos;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 hpack: huffman, round trips ascii" {
    const src = "hello";
    var encoded: [32]u8 = undefined;
    const encoded_len = try huffEncode(src, &encoded);

    var decoded: [32]u8 = undefined;
    const decoded_len = try huffDecode(encoded[0..encoded_len], &decoded);

    try std.testing.expectEqualStrings(src, decoded[0..decoded_len]);
}

test "zix http2 hpack: huffman, encodes www.example.com per RFC 7541 C.4.1" {
    const want = [_]u8{ 0xf1, 0xe3, 0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff };
    var encoded: [32]u8 = undefined;

    const encoded_len = try huffEncode("www.example.com", &encoded);

    try std.testing.expectEqualSlices(u8, &want, encoded[0..encoded_len]);
}

test "zix http2 hpack: huffman, decodes no-cache per RFC 7541 C.4.2" {
    const src = [_]u8{ 0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf };
    var decoded: [16]u8 = undefined;

    const decoded_len = try huffDecode(&src, &decoded);

    try std.testing.expectEqualStrings("no-cache", decoded[0..decoded_len]);
}

test "zix http2 hpack: huffman, round trips every byte value" {
    var src: [256]u8 = undefined;
    for (&src, 0..) |*byte, i| byte.* = @intCast(i);

    var encoded: [1024]u8 = undefined;
    const encoded_len = try huffEncode(&src, &encoded);

    var decoded: [256]u8 = undefined;
    const decoded_len = try huffDecode(encoded[0..encoded_len], &decoded);

    try std.testing.expectEqualSlices(u8, &src, decoded[0..decoded_len]);
}

test "zix http2 hpack: huffman, empty input encodes and decodes to nothing" {
    var buf: [4]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), try huffEncode("", &buf));
    try std.testing.expectEqual(@as(usize, 0), try huffDecode("", &buf));
}

test "zix http2 hpack: huffman, encode past the output is OutputTooSmall" {
    var buf: [2]u8 = undefined;

    const result = huffEncode("www.example.com", &buf);

    try std.testing.expectError(Error.ZixHttp2_Huffman_OutputTooSmall, result);
}

test "zix http2 hpack: huffman, decode past the output is OutputTooSmall" {
    const src = [_]u8{ 0xa8, 0xeb, 0x10, 0x64, 0x9c, 0xbf };
    var decoded: [2]u8 = undefined;

    const result = huffDecode(&src, &decoded);

    try std.testing.expectError(Error.ZixHttp2_Huffman_OutputTooSmall, result);
}

test "zix http2 hpack: huffman, padding longer than 7 bits is InvalidCode" {
    const src = [_]u8{ 0xff, 0xff };
    var decoded: [8]u8 = undefined;

    const result = huffDecode(&src, &decoded);

    try std.testing.expectError(Error.ZixHttp2_Huffman_InvalidCode, result);
}

test "zix http2 hpack: huffman, long run of ones is InvalidCode" {
    const src: [16]u8 = @splat(0xff);
    var decoded: [16]u8 = undefined;

    const result = huffDecode(&src, &decoded);

    try std.testing.expectError(Error.ZixHttp2_Huffman_InvalidCode, result);
}

