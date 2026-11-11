//! ZIX Http2 hpack huffman_table
//!
//! ### file: src/zix/tcp/http2/hpack/huffman_table.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! The HPACK Huffman code table (RFC 7541 appendix B), one code per byte value.
//! 
//! ### note:
//! 
//! The table is kept as two parallel arrays (codes and bit lengths) and joined
//! into HuffSym entries at comptime. The values are fixed by the RFC.
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
const HuffSym = @import("HuffSym.zig");

// --------------------------------------------------------- //
// Private:

/// Code bits for each byte value, right aligned.
const CODES = [256]u32{
    0x1ff8, 0x7fffd8, 0xfffffe2, 0xfffffe3, // 0
    0xfffffe4, 0xfffffe5, 0xfffffe6, 0xfffffe7, // 4
    0xfffffe8, 0xffffea, 0x3ffffffc, 0xfffffe9, // 8
    0xfffffea, 0x3ffffffd, 0xfffffeb, 0xfffffec, // 12
    0xfffffed, 0xfffffee, 0xfffffef, 0xffffff0, // 16
    0xffffff1, 0xffffff2, 0x3ffffffe, 0xffffff3, // 20
    0xffffff4, 0xffffff5, 0xffffff6, 0xffffff7, // 24
    0xffffff8, 0xffffff9, 0xffffffa, 0xffffffb, // 28
    0x14, 0x3f8, 0x3f9, 0xffa, // 32
    0x1ff9, 0x15, 0xf8, 0x7fa, // 36
    0x3fa, 0x3fb, 0xf9, 0x7fb, // 40
    0xfa, 0x16, 0x17, 0x18, // 44
    0x0, 0x1, 0x2, 0x19, // 48
    0x1a, 0x1b, 0x1c, 0x1d, // 52
    0x1e, 0x1f, 0x5c, 0xfb, // 56
    0x7ffc, 0x20, 0xffb, 0x3fc, // 60
    0x1ffa, 0x21, 0x5d, 0x5e, // 64
    0x5f, 0x60, 0x61, 0x62, // 68
    0x63, 0x64, 0x65, 0x66, // 72
    0x67, 0x68, 0x69, 0x6a, // 76
    0x6b, 0x6c, 0x6d, 0x6e, // 80
    0x6f, 0x70, 0x71, 0x72, // 84
    0xfc, 0x73, 0xfd, 0x1ffb, // 88
    0x7fff0, 0x1ffc, 0x3ffc, 0x22, // 92
    0x7ffd, 0x3, 0x23, 0x4, // 96
    0x24, 0x5, 0x25, 0x26, // 100
    0x27, 0x6, 0x74, 0x75, // 104
    0x28, 0x29, 0x2a, 0x7, // 108
    0x2b, 0x76, 0x2c, 0x8, // 112
    0x9, 0x2d, 0x77, 0x78, // 116
    0x79, 0x7a, 0x7b, 0x7ffe, // 120
    0x7fc, 0x3ffd, 0x1ffd, 0xffffffc, // 124
    0xfffe6, 0x3fffd2, 0xfffe7, 0xfffe8, // 128
    0x3fffd3, 0x3fffd4, 0x3fffd5, 0x7fffd9, // 132
    0x3fffd6, 0x7fffda, 0x7fffdb, 0x7fffdc, // 136
    0x7fffdd, 0x7fffde, 0xffffeb, 0x7fffdf, // 140
    0xffffec, 0xffffed, 0x3fffd7, 0x7fffe0, // 144
    0xffffee, 0x7fffe1, 0x7fffe2, 0x7fffe3, // 148
    0x7fffe4, 0x1fffdc, 0x3fffd8, 0x7fffe5, // 152
    0x3fffd9, 0x7fffe6, 0x7fffe7, 0xffffef, // 156
    0x3fffda, 0x1fffdd, 0xfffe9, 0x3fffdb, // 160
    0x3fffdc, 0x7fffe8, 0x7fffe9, 0x1fffde, // 164
    0x7fffea, 0x3fffdd, 0x3fffde, 0xfffff0, // 168
    0x1fffdf, 0x3fffdf, 0x7fffeb, 0x7fffec, // 172
    0x1fffe0, 0x1fffe1, 0x3fffe0, 0x1fffe2, // 176
    0x7fffed, 0x3fffe1, 0x7fffee, 0x7fffef, // 180
    0xfffea, 0x3fffe2, 0x3fffe3, 0x3fffe4, // 184
    0x7ffff0, 0x3fffe5, 0x3fffe6, 0x7ffff1, // 188
    0x3ffffe0, 0x3ffffe1, 0xfffeb, 0x7fff1, // 192
    0x3fffe7, 0x7ffff2, 0x3fffe8, 0x1ffffec, // 196
    0x3ffffe2, 0x3ffffe3, 0x3ffffe4, 0x7ffffde, // 200
    0x7ffffdf, 0x3ffffe5, 0xfffff1, 0x1ffffed, // 204
    0x7fff2, 0x1fffe3, 0x3ffffe6, 0x7ffffe0, // 208
    0x7ffffe1, 0x3ffffe7, 0x7ffffe2, 0xfffff2, // 212
    0x1fffe4, 0x1fffe5, 0x3ffffe8, 0x3ffffe9, // 216
    0xffffffd, 0x7ffffe3, 0x7ffffe4, 0x7ffffe5, // 220
    0xfffec, 0xfffff3, 0xfffed, 0x1fffe6, // 224
    0x3fffe9, 0x1fffe7, 0x1fffe8, 0x7ffff3, // 228
    0x3fffea, 0x3fffeb, 0x1ffffee, 0x1ffffef, // 232
    0xfffff4, 0xfffff5, 0x3ffffea, 0x7ffff4, // 236
    0x3ffffeb, 0x7ffffe6, 0x3ffffec, 0x3ffffed, // 240
    0x7ffffe7, 0x7ffffe8, 0x7ffffe9, 0x7ffffea, // 244
    0x7ffffeb, 0xffffffe, 0x7ffffec, 0x7ffffed, // 248
    0x7ffffee, 0x7ffffef, 0x7fffff0, 0x3ffffee, // 252
};

/// Bit length of each code in CODES.
const BITS = [256]u5{
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28, // 0
    28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28, // 16
    6, 10, 10, 12, 13, 6, 8, 11, 10, 10, 8, 11, 8, 6, 6, 6, // 32
    5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 7, 8, 15, 6, 12, 10, // 48
    13, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, // 64
    7, 7, 7, 7, 7, 7, 7, 7, 8, 7, 8, 13, 19, 13, 14, 6, // 80
    15, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7, 6, 6, 6, 5, // 96
    6, 7, 6, 5, 5, 6, 7, 7, 7, 7, 7, 15, 11, 14, 13, 28, // 112
    20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23, // 128
    24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24, // 144
    22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23, // 160
    21, 21, 22, 21, 23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23, // 176
    26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25, // 192
    19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27, // 208
    20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23, // 224
    26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26, // 240
};

// --------------------------------------------------------- //
// Public:

/// Huffman code for each byte value, indexed by the byte.
pub const HUFF: [256]HuffSym = blk: {
    var table: [256]HuffSym = undefined;
    for (&table, CODES, BITS) |*sym, code, bits| {
        sym.* = .{
            .code = code,
            .bits = bits,
        };
    }

    break :blk table;
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix http2 hpack: huffman_table, space is the 6-bit code 0x14" {
    try std.testing.expectEqual(@as(u32, 0x14), HUFF[' '].code);
    try std.testing.expectEqual(@as(u5, 6), HUFF[' '].bits);
}

test "zix http2 hpack: huffman_table, 'a' is the 5-bit code 0x3" {
    try std.testing.expectEqual(@as(u32, 0x3), HUFF['a'].code);
    try std.testing.expectEqual(@as(u5, 5), HUFF['a'].bits);
}

test "zix http2 hpack: huffman_table, byte 255 is the 26-bit code 0x3ffffee" {
    try std.testing.expectEqual(@as(u32, 0x3ffffee), HUFF[255].code);
    try std.testing.expectEqual(@as(u5, 26), HUFF[255].bits);
}

test "zix http2 hpack: huffman_table, every code fits its bit length" {
    for (HUFF) |sym| {
        try std.testing.expect(sym.bits >= 5);
        try std.testing.expect(sym.bits <= 30);
        try std.testing.expect(sym.code < (@as(u64, 1) << sym.bits));
    }
}

