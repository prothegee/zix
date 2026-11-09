//! ZIX utils compression
//!
//! ### file: src/zix/utils/compression/compression.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Compression facade: encode, encode into a buffer, and decode with a chosen
//! content coding, plus the public compression namespace.
//! 
//! ### note:
//! 
//! gzip bodies under 64 KiB use the fast encoder (flate_fast). Larger bodies use
//! std flate.
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
const brotli_codec = @import("brotli/brotli.zig");
const flate_codec = @import("flate/flate.zig");
const flate_fast_codec = @import("flate/flate_fast.zig");
const negotiate_mod = @import("negotiate.zig");
const policy = @import("policy.zig");

// --------------------------------------------------------- //
// Private:

const Inner = Error || std.mem.Allocator.Error || flate_codec.Error || brotli_codec.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixUtils_Compression_CompressFailed => Error.ZixUtils_Compression_CompressFailed,
        error.ZixUtils_Compression_DecompressFailed => Error.ZixUtils_Compression_DecompressFailed,
        error.ZixUtils_Compression_OutputTooLarge => Error.ZixUtils_Compression_OutputTooLarge,
        error.ZixUtils_Compression_BufferTooSmall => Error.ZixUtils_Compression_BufferTooSmall,
        error.ZixUtils_Compression_OutOfMemory => Error.ZixUtils_Compression_OutOfMemory,
        error.ZixUtils_Compression_InvalidWindowBits => {
            return Error.ZixUtils_Compression_InvalidWindowBits;
        },
        error.ZixUtils_Compression_InputTooLarge => Error.ZixUtils_Compression_InputTooLarge,
        error.ZixUtils_Compression_Truncated => Error.ZixUtils_Compression_Truncated,
        error.ZixUtils_Compression_Malformed => Error.ZixUtils_Compression_Malformed,
        error.OutOfMemory => Error.ZixUtils_Compression_OutOfMemory,
        error.ZixUtils_Flate_CompressFailed => Error.ZixUtils_Compression_CompressFailed,
        error.ZixUtils_Flate_DecompressFailed => Error.ZixUtils_Compression_DecompressFailed,
        error.ZixUtils_Flate_OutputTooLarge => Error.ZixUtils_Compression_OutputTooLarge,
        error.ZixUtils_Flate_BufferTooSmall => Error.ZixUtils_Compression_BufferTooSmall,
        error.ZixUtils_Flate_OutOfMemory => Error.ZixUtils_Compression_OutOfMemory,
        error.ZixUtils_Brotli_InvalidWindowBits => Error.ZixUtils_Compression_InvalidWindowBits,
        error.ZixUtils_Brotli_InputTooLarge => Error.ZixUtils_Compression_InputTooLarge,
        error.ZixUtils_Brotli_BufferTooSmall => Error.ZixUtils_Compression_BufferTooSmall,
        error.ZixUtils_Brotli_Truncated => Error.ZixUtils_Compression_Truncated,
        error.ZixUtils_Brotli_Malformed => Error.ZixUtils_Compression_Malformed,
        error.ZixUtils_Brotli_OutputTooLarge => Error.ZixUtils_Compression_OutputTooLarge,
        error.ZixUtils_Brotli_OutOfMemory => Error.ZixUtils_Compression_OutOfMemory,
    };
}

/// gzip into a fresh buffer: the fast encoder under its cap, std flate above it.
fn gzipAlloc(allocator: std.mem.Allocator, data: []const u8, level: Level) Inner![]u8 {
    const bound = flate_fast_codec.gzipFastBound(data.len);
    if (!flate_fast_codec.fitsFast(data.len, bound)) {
        return flate_codec.compressGzipAlloc(allocator, data, level);
    }

    const buf = try allocator.alloc(u8, bound);
    errdefer allocator.free(buf);

    const written = flate_fast_codec.gzipFastInto(data, buf);

    return allocator.realloc(buf, written);
}

fn encodeInner(
    allocator: std.mem.Allocator,
    encoding: Encoding,
    data: []const u8,
    level: Level,
) Inner![]u8 {
    return switch (encoding) {
        .IDENTITY => allocator.dupe(u8, data),
        .GZIP => gzipAlloc(allocator, data, level),
        .DEFLATE => flate_codec.compressDeflateAlloc(allocator, data, level),
        .BR => brotli_codec.compressBrotliAlloc(allocator, data, level),
    };
}

fn encodeIntoInner(
    allocator: std.mem.Allocator,
    encoding: Encoding,
    data: []const u8,
    out_buf: []u8,
    level: Level,
) Inner!usize {
    switch (encoding) {
        .IDENTITY => {
            if (out_buf.len < data.len) return Error.ZixUtils_Compression_BufferTooSmall;

            @memcpy(out_buf[0..data.len], data);

            return data.len;
        },
        .GZIP => {
            if (flate_fast_codec.fitsFast(data.len, out_buf.len)) {
                return flate_fast_codec.gzipFastInto(data, out_buf);
            }

            return flate_codec.compressGzip(allocator, data, out_buf, level);
        },
        .DEFLATE => return flate_codec.compressDeflate(allocator, data, out_buf, level),
        .BR => return brotli_codec.compressBrotli(allocator, data, out_buf, level),
    }
}

fn decodeInner(
    allocator: std.mem.Allocator,
    encoding: Encoding,
    data: []const u8,
    max_out: usize,
) Inner![]u8 {
    return switch (encoding) {
        .IDENTITY => allocator.dupe(u8, data),
        .GZIP => flate_codec.decompressGzipAlloc(allocator, data, max_out),
        .DEFLATE => flate_codec.decompressDeflateAlloc(allocator, data, max_out),
        .BR => brotli_codec.decompressBrotliAlloc(allocator, data, max_out),
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_Compression_CompressFailed,
    ZixUtils_Compression_DecompressFailed,
    ZixUtils_Compression_OutputTooLarge,
    ZixUtils_Compression_BufferTooSmall,
    ZixUtils_Compression_OutOfMemory,
    ZixUtils_Compression_InvalidWindowBits,
    ZixUtils_Compression_InputTooLarge,
    ZixUtils_Compression_Truncated,
    ZixUtils_Compression_Malformed,
};

/// gzip and deflate codec.
pub const flate = flate_codec;

/// Fast gzip encoder for bodies under 64 KiB.
pub const flate_fast = flate_fast_codec;

/// Brotli codec.
pub const brotli = brotli_codec;

/// HTTP content coding.
pub const Encoding = @import("../http/encoding.zig").Encoding;

/// Compression effort.
pub const Level = @import("level.zig").Level;

/// Default size floor, see policy.zig.
pub const MIN_SIZE_DEFAULT = policy.MIN_SIZE_DEFAULT;

/// Producible codings in server preference order, see policy.zig.
pub const supported_default = policy.supported_default;

/// Accept-Encoding negotiation, see negotiate.zig.
pub const negotiate = negotiate_mod.negotiate;

/// Whether a body is worth compressing, see policy.zig.
pub const shouldCompress = policy.shouldCompress;

/// Encode a body with the chosen coding into a fresh buffer.
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// encoding - Encoding (chosen coding)
/// data - []const u8 (uncompressed body)
/// level - Level (effort, ignored for identity)
///
/// Return:
/// - []u8 (owned. For identity it is a copy of data)
/// - Error when the codec fails or memory runs out
pub fn encode(
    allocator: std.mem.Allocator,
    encoding: Encoding,
    data: []const u8,
    level: Level,
) Error![]u8 {
    return encodeInner(allocator, encoding, data, level) catch |err| innerError(err);
}

/// Encode a body with the chosen coding into a caller buffer.
///
/// Param:
/// allocator - std.mem.Allocator (transient codec scratch)
/// encoding - Encoding (chosen coding)
/// data - []const u8 (uncompressed body)
/// out_buf - []u8 (destination)
/// level - Level (effort, ignored for identity)
///
/// Return:
/// - usize (encoded byte count written into out_buf)
/// - Error.ZixUtils_Compression_BufferTooSmall when out_buf cannot hold the result
pub fn encodeInto(
    allocator: std.mem.Allocator,
    encoding: Encoding,
    data: []const u8,
    out_buf: []u8,
    level: Level,
) Error!usize {
    return encodeIntoInner(allocator, encoding, data, out_buf, level) catch |err| {
        return innerError(err);
    };
}

/// Decode a body in the given coding into a fresh buffer.
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// encoding - Encoding (coding the data is in)
/// data - []const u8 (encoded body)
/// max_out - usize (bomb guard, ignored for identity)
///
/// Return:
/// - []u8 (owned)
/// - Error.ZixUtils_Compression_OutputTooLarge past max_out
/// - Error when the stream is bad
pub fn decode(
    allocator: std.mem.Allocator,
    encoding: Encoding,
    data: []const u8,
    max_out: usize,
) Error![]u8 {
    return decodeInner(allocator, encoding, data, max_out) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

fn roundTrip(encoding: Encoding, original: []const u8) !void {
    const packed_bytes = try encode(std.testing.allocator, encoding, original, .DEFAULT);
    defer std.testing.allocator.free(packed_bytes);

    const restored = try decode(std.testing.allocator, encoding, packed_bytes, 1 << 20);
    defer std.testing.allocator.free(restored);

    try std.testing.expectEqualSlices(u8, original, restored);
}

test "zix utils compression: compression, identity is a copy" {
    const original = "passthrough body";

    const out = try encode(std.testing.allocator, .IDENTITY, original, .DEFAULT);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqualStrings(original, out);
    try std.testing.expect(out.ptr != original.ptr);
}

test "zix utils compression: compression, gzip round-trips" {
    try roundTrip(.GZIP, "facade roundtrip over the gzip codec");
}

test "zix utils compression: compression, gzip above the fast cap round-trips" {
    const original = try std.testing.allocator.alloc(u8, 70 * 1024);
    defer std.testing.allocator.free(original);

    for (original, 0..) |*byte, i| byte.* = @truncate(i % 251);

    try roundTrip(.GZIP, original);
}

test "zix utils compression: compression, deflate round-trips" {
    try roundTrip(.DEFLATE, "facade roundtrip over the deflate codec");
}

test "zix utils compression: compression, brotli round-trips" {
    try roundTrip(.BR, "facade roundtrip over the brotli codec, repeated. " ++
        "facade roundtrip over the brotli codec, repeated.");
}

test "zix utils compression: compression, encodeInto gzip round-trips" {
    const original = "facade into-buffer roundtrip over the gzip codec, repeated. " ++
        "facade into-buffer roundtrip over the gzip codec, repeated.";

    var out: [512]u8 = undefined;
    const written = try encodeInto(std.testing.allocator, .GZIP, original, &out, .DEFAULT);

    const restored = try decode(std.testing.allocator, .GZIP, out[0..written], 1024);
    defer std.testing.allocator.free(restored);

    try std.testing.expectEqualStrings(original, restored);
}

test "zix utils compression: compression, encodeInto gzip with a small buffer uses std" {
    const original = "short";

    var out: [flate_codec.compressBound(original.len)]u8 = undefined;
    const written = try encodeInto(std.testing.allocator, .GZIP, original, &out, .DEFAULT);

    const restored = try decode(std.testing.allocator, .GZIP, out[0..written], 64);
    defer std.testing.allocator.free(restored);

    try std.testing.expectEqualStrings(original, restored);
}

test "zix utils compression: compression, encodeInto identity copies" {
    var out: [8]u8 = undefined;
    const written = try encodeInto(std.testing.allocator, .IDENTITY, "abc", &out, .DEFAULT);

    try std.testing.expectEqualStrings("abc", out[0..written]);
}

test "zix utils compression: compression, encodeInto identity short buffer is too small" {
    var tiny: [2]u8 = undefined;

    try std.testing.expectError(
        Error.ZixUtils_Compression_BufferTooSmall,
        encodeInto(std.testing.allocator, .IDENTITY, "abc", &tiny, .DEFAULT),
    );
}

test "zix utils compression: compression, decode gzip past the cap is too large" {
    var original: [1024]u8 = undefined;
    @memset(&original, 'A');

    const packed_bytes = try encode(std.testing.allocator, .GZIP, &original, .DEFAULT);
    defer std.testing.allocator.free(packed_bytes);

    try std.testing.expectError(
        Error.ZixUtils_Compression_OutputTooLarge,
        decode(std.testing.allocator, .GZIP, packed_bytes, 16),
    );
}

test "zix utils compression: compression, decode bad gzip fails" {
    try std.testing.expectError(
        Error.ZixUtils_Compression_DecompressFailed,
        decode(std.testing.allocator, .GZIP, "\x1f\x8b\x08\x00 not gzip", 64),
    );
}

test "zix utils compression: compression, decode empty brotli is truncated" {
    try std.testing.expectError(
        Error.ZixUtils_Compression_Truncated,
        decode(std.testing.allocator, .BR, "", 64),
    );
}

test "zix utils compression: compression, failing allocator is out of memory" {
    try std.testing.expectError(
        Error.ZixUtils_Compression_OutOfMemory,
        encode(std.testing.failing_allocator, .GZIP, "abc", .DEFAULT),
    );
}

test "zix utils compression: compression, re-exports the policy" {
    try std.testing.expectEqual(@as(usize, 256), MIN_SIZE_DEFAULT);
    try std.testing.expect(!shouldCompress(10, "text/plain", MIN_SIZE_DEFAULT));
    try std.testing.expectEqual(Encoding.GZIP, negotiate("gzip", &supported_default).?);
}

