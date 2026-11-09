//! ZIX utils compression flate
//!
//! ### file: src/zix/utils/compression/flate/flate.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! gzip (RFC 1952) and deflate (RFC 1950 zlib) codec over std.compress.flate.
//! 
//! ### note:
//! 
//! The HTTP deflate coding is zlib-wrapped DEFLATE, not raw DEFLATE.
//! So the deflate functions use the zlib container.
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
const Level = @import("../level.zig").Level;

const flate = std.compress.flate;
const Container = flate.Container;

// --------------------------------------------------------- //
// Private:

/// Map the shared effort to a std preset.
///
/// Param:
/// level - Level (effort)
///
/// Return:
/// - flate.Compress.Options
fn options(level: Level) flate.Compress.Options {
    return switch (level) {
        .FASTEST => flate.Compress.Options.level_1,
        .DEFAULT => flate.Compress.Options.default,
    };
}

/// Compress data into a caller buffer with the given container.
///
/// Note:
/// - out_buf must be at least compressBound(data.len).
/// - flate.Compress is about 230 KB. It is built in a heap slot, never on the
///   caller stack, because a handler runs on a small worker stack.
///
/// Param:
/// allocator - std.mem.Allocator (transient window and state, freed before return)
/// data - []const u8 (bytes to compress)
/// out_buf - []u8 (destination)
/// level - Level (effort)
/// container - Container (.gzip or .zlib)
///
/// Return:
/// - usize (compressed byte count written into out_buf)
/// - Error.ZixUtils_Flate_BufferTooSmall when out_buf is under the bound
/// - Error.ZixUtils_Flate_CompressFailed when the codec fails
/// - Error.ZixUtils_Flate_OutOfMemory when the scratch cannot be allocated
fn compressContainer(
    allocator: std.mem.Allocator,
    data: []const u8,
    out_buf: []u8,
    level: Level,
    container: Container,
) Error!usize {
    if (out_buf.len < compressBound(data.len)) return Error.ZixUtils_Flate_BufferTooSmall;

    const work_buf = allocator.alloc(u8, flate.max_window_len) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixUtils_Flate_OutOfMemory,
    };
    defer allocator.free(work_buf);

    const slot = allocator.create(std.Io.Writer.Error!flate.Compress) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixUtils_Flate_OutOfMemory,
    };
    defer allocator.destroy(slot);

    var out_writer = std.Io.Writer.fixed(out_buf);
    slot.* = flate.Compress.init(&out_writer, work_buf, container, options(level));

    const comp: *flate.Compress = if (slot.*) |*payload| payload else |err| switch (err) {
        error.WriteFailed => return Error.ZixUtils_Flate_CompressFailed,
    };

    comp.writer.writeAll(data) catch |err| switch (err) {
        error.WriteFailed => return Error.ZixUtils_Flate_CompressFailed,
    };
    comp.finish() catch |err| switch (err) {
        error.WriteFailed => return Error.ZixUtils_Flate_CompressFailed,
    };

    return out_writer.end;
}

/// Compress into a fresh buffer shrunk to the exact result size.
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// data - []const u8 (bytes to compress)
/// level - Level (effort)
/// container - Container (.gzip or .zlib)
///
/// Return:
/// - []u8 (owned, free with the same allocator)
/// - Error from compressContainer
fn compressContainerAlloc(
    allocator: std.mem.Allocator,
    data: []const u8,
    level: Level,
    container: Container,
) Error![]u8 {
    const buf = allocator.alloc(u8, compressBound(data.len)) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixUtils_Flate_OutOfMemory,
    };
    errdefer allocator.free(buf);

    const written = try compressContainer(allocator, data, buf, level, container);

    return allocator.realloc(buf, written) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixUtils_Flate_OutOfMemory,
    };
}

/// Inflate a stream of the given container into a caller buffer.
///
/// Param:
/// compressed - []const u8 (compressed bytes)
/// out_buf - []u8 (destination)
/// container - Container (.gzip or .zlib)
/// overflow - Error (returned when the output does not fit out_buf)
///
/// Return:
/// - usize (inflated byte count written into out_buf)
/// - overflow when out_buf is too small
/// - Error.ZixUtils_Flate_DecompressFailed when the stream is malformed
fn inflateInto(
    compressed: []const u8,
    out_buf: []u8,
    container: Container,
    overflow: Error,
) Error!usize {
    var in_reader = std.Io.Reader.fixed(compressed);
    var decomp = flate.Decompress.init(&in_reader, container, &.{});

    var out_writer = std.Io.Writer.fixed(out_buf);

    return decomp.reader.stream(&out_writer, .unlimited) catch |err| switch (err) {
        error.WriteFailed => return overflow,
        error.ReadFailed, error.EndOfStream => return Error.ZixUtils_Flate_DecompressFailed,
    };
}

/// Inflate into a fresh buffer, capped at max_out (bomb guard).
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// compressed - []const u8 (compressed bytes)
/// max_out - usize (largest output accepted)
/// container - Container (.gzip or .zlib)
///
/// Return:
/// - []u8 (owned, free with the same allocator)
/// - Error.ZixUtils_Flate_OutputTooLarge when the output passes max_out
/// - Error.ZixUtils_Flate_DecompressFailed when the stream is malformed
fn decompressContainerAlloc(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    max_out: usize,
    container: Container,
) Error![]u8 {
    const buf = allocator.alloc(u8, max_out) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixUtils_Flate_OutOfMemory,
    };
    errdefer allocator.free(buf);

    const inflated = try inflateInto(
        compressed,
        buf,
        container,
        Error.ZixUtils_Flate_OutputTooLarge,
    );

    return allocator.realloc(buf, inflated) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixUtils_Flate_OutOfMemory,
    };
}

// --------------------------------------------------------- //
// Public:

pub const Error = error {
    ZixUtils_Flate_CompressFailed,
    ZixUtils_Flate_DecompressFailed,
    ZixUtils_Flate_OutputTooLarge,
    ZixUtils_Flate_BufferTooSmall,
    ZixUtils_Flate_OutOfMemory,
};

/// Upper bound on the compressed size for an input length. Safe for gzip and zlib.
///
/// Note:
/// - std has no store fallback, so incompressible data can grow up to 9 bits per
///   byte. The bound adds input / 8, 5 bytes per 65535-byte block, and 18 bytes of
///   gzip header and trailer.
///
/// Param:
/// input_len - usize (uncompressed byte count)
///
/// Return:
/// - usize (a length out_buf can safely be sized to)
pub fn compressBound(input_len: usize) usize {
    const blocks = input_len / 65535 + 1;

    return input_len + input_len / 8 + 5 * blocks + 18;
}

/// gzip compress into a caller buffer sized with compressBound.
///
/// Param:
/// allocator - std.mem.Allocator (transient codec scratch)
/// data - []const u8 (bytes to compress)
/// out_buf - []u8 (destination)
/// level - Level (effort)
///
/// Return:
/// - usize (compressed byte count)
/// - Error when the buffer is short or the codec fails
pub fn compressGzip(
    allocator: std.mem.Allocator,
    data: []const u8,
    out_buf: []u8,
    level: Level,
) Error!usize {
    return compressContainer(allocator, data, out_buf, level, .gzip);
}

/// gzip compress into a fresh buffer shrunk to the exact size.
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// data - []const u8 (bytes to compress)
/// level - Level (effort)
///
/// Return:
/// - []u8 (owned)
/// - Error when the codec fails
pub fn compressGzipAlloc(allocator: std.mem.Allocator, data: []const u8, level: Level) Error![]u8 {
    return compressContainerAlloc(allocator, data, level, .gzip);
}

/// gzip decompress into a caller buffer.
///
/// Param:
/// compressed - []const u8 (gzip bytes)
/// out_buf - []u8 (destination)
///
/// Return:
/// - usize (inflated byte count)
/// - Error.ZixUtils_Flate_BufferTooSmall when out_buf is too small
/// - Error.ZixUtils_Flate_DecompressFailed when the stream is malformed
pub fn decompressGzip(compressed: []const u8, out_buf: []u8) Error!usize {
    return inflateInto(compressed, out_buf, .gzip, Error.ZixUtils_Flate_BufferTooSmall);
}

/// gzip decompress into a fresh buffer, capped at max_out (bomb guard).
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// compressed - []const u8 (gzip bytes)
/// max_out - usize (largest output accepted)
///
/// Return:
/// - []u8 (owned)
/// - Error.ZixUtils_Flate_OutputTooLarge when the output passes max_out
pub fn decompressGzipAlloc(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    max_out: usize,
) Error![]u8 {
    return decompressContainerAlloc(allocator, compressed, max_out, .gzip);
}

/// deflate (zlib) compress into a caller buffer sized with compressBound.
///
/// Param:
/// allocator - std.mem.Allocator (transient codec scratch)
/// data - []const u8 (bytes to compress)
/// out_buf - []u8 (destination)
/// level - Level (effort)
///
/// Return:
/// - usize (compressed byte count)
/// - Error when the buffer is short or the codec fails
pub fn compressDeflate(
    allocator: std.mem.Allocator,
    data: []const u8,
    out_buf: []u8,
    level: Level,
) Error!usize {
    return compressContainer(allocator, data, out_buf, level, .zlib);
}

/// deflate (zlib) compress into a fresh buffer shrunk to the exact size.
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// data - []const u8 (bytes to compress)
/// level - Level (effort)
///
/// Return:
/// - []u8 (owned)
/// - Error when the codec fails
pub fn compressDeflateAlloc(
    allocator: std.mem.Allocator,
    data: []const u8,
    level: Level,
) Error![]u8 {
    return compressContainerAlloc(allocator, data, level, .zlib);
}

/// deflate (zlib) decompress into a caller buffer.
///
/// Param:
/// compressed - []const u8 (zlib bytes)
/// out_buf - []u8 (destination)
///
/// Return:
/// - usize (inflated byte count)
/// - Error.ZixUtils_Flate_BufferTooSmall when out_buf is too small
/// - Error.ZixUtils_Flate_DecompressFailed when the stream is malformed
pub fn decompressDeflate(compressed: []const u8, out_buf: []u8) Error!usize {
    return inflateInto(compressed, out_buf, .zlib, Error.ZixUtils_Flate_BufferTooSmall);
}

/// deflate (zlib) decompress into a fresh buffer, capped at max_out.
///
/// Param:
/// allocator - std.mem.Allocator (owns the returned slice)
/// compressed - []const u8 (zlib bytes)
/// max_out - usize (largest output accepted)
///
/// Return:
/// - []u8 (owned)
/// - Error.ZixUtils_Flate_OutputTooLarge when the output passes max_out
pub fn decompressDeflateAlloc(
    allocator: std.mem.Allocator,
    compressed: []const u8,
    max_out: usize,
) Error![]u8 {
    return decompressContainerAlloc(allocator, compressed, max_out, .zlib);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

test "zix utils compression flate: gzip, round-trips ascii" {
    const original = "the quick brown fox jumps over the lazy dog";

    const packed_bytes = try compressGzipAlloc(std.testing.allocator, original, .DEFAULT);
    defer std.testing.allocator.free(packed_bytes);

    const restored = try decompressGzipAlloc(std.testing.allocator, packed_bytes, 1024);
    defer std.testing.allocator.free(restored);

    try std.testing.expectEqualStrings(original, restored);
}

test "zix utils compression flate: gzip, round-trips empty input" {
    const packed_bytes = try compressGzipAlloc(std.testing.allocator, "", .DEFAULT);
    defer std.testing.allocator.free(packed_bytes);

    const restored = try decompressGzipAlloc(std.testing.allocator, packed_bytes, 64);
    defer std.testing.allocator.free(restored);

    try std.testing.expectEqual(@as(usize, 0), restored.len);
}

test "zix utils compression flate: gzip, round-trips every byte value" {
    var original: [256]u8 = undefined;
    for (&original, 0..) |*byte, index| byte.* = @intCast(index);

    const packed_bytes = try compressGzipAlloc(std.testing.allocator, &original, .DEFAULT);
    defer std.testing.allocator.free(packed_bytes);

    const restored = try decompressGzipAlloc(std.testing.allocator, packed_bytes, 512);
    defer std.testing.allocator.free(restored);

    try std.testing.expectEqualSlices(u8, &original, restored);
}

test "zix utils compression flate: gzip, shrinks compressible input" {
    var original: [4096]u8 = undefined;
    @memset(&original, 'A');

    const packed_bytes = try compressGzipAlloc(std.testing.allocator, &original, .DEFAULT);
    defer std.testing.allocator.free(packed_bytes);

    try std.testing.expect(packed_bytes.len < original.len);
}

test "zix utils compression flate: gzip, output stays within compressBound" {
    var original: [8192]u8 = undefined;
    var seed: u32 = 2654435761;
    for (&original) |*byte| {
        seed = seed *% 1664525 +% 1013904223;
        byte.* = @truncate(seed >> 16);
    }

    const packed_bytes = try compressGzipAlloc(std.testing.allocator, &original, .DEFAULT);
    defer std.testing.allocator.free(packed_bytes);

    try std.testing.expect(packed_bytes.len <= compressBound(original.len));
}

test "zix utils compression flate: gzip, writes the gzip magic" {
    var out_buf: [128]u8 = undefined;
    const written = try compressGzip(std.testing.allocator, "magic check", &out_buf, .DEFAULT);

    try std.testing.expect(written >= 3);
    try std.testing.expectEqual(@as(u8, 0x1f), out_buf[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), out_buf[1]);
    try std.testing.expectEqual(@as(u8, 0x08), out_buf[2]);
}

test "zix utils compression flate: gzip, round-trips both levels" {
    var original: [512]u8 = undefined;
    for (&original, 0..) |*byte, index| byte.* = @intCast('a' + (index % 26));

    inline for (.{ Level.FASTEST, Level.DEFAULT }) |level| {
        const packed_bytes = try compressGzipAlloc(std.testing.allocator, &original, level);
        defer std.testing.allocator.free(packed_bytes);

        const restored = try decompressGzipAlloc(std.testing.allocator, packed_bytes, 4096);
        defer std.testing.allocator.free(restored);

        try std.testing.expectEqualSlices(u8, &original, restored);
    }
}

test "zix utils compression flate: gzip, decodes a gzip CLI vector" {
    const vector = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\x03\xcb\x48\xcd\xc9\xc9\xd7" ++
        "\x51\x48\xaf\xca\x2c\x00\x00\x4a\x9b\xb1\x5c\x0b\x00\x00\x00";

    var out_buf: [32]u8 = undefined;
    const inflated = try decompressGzip(vector, &out_buf);

    try std.testing.expectEqualStrings("hello, gzip", out_buf[0..inflated]);
}

test "zix utils compression flate: gzip, decompress into a small buffer is too small" {
    var original: [256]u8 = undefined;
    @memset(&original, 'A');

    const packed_bytes = try compressGzipAlloc(std.testing.allocator, &original, .DEFAULT);
    defer std.testing.allocator.free(packed_bytes);

    var tiny: [8]u8 = undefined;

    try std.testing.expectError(
        Error.ZixUtils_Flate_BufferTooSmall,
        decompressGzip(packed_bytes, &tiny),
    );
}

test "zix utils compression flate: gzip, decompress past the cap is too large" {
    var original: [1024]u8 = undefined;
    @memset(&original, 'A');

    const packed_bytes = try compressGzipAlloc(std.testing.allocator, &original, .DEFAULT);
    defer std.testing.allocator.free(packed_bytes);

    try std.testing.expectError(
        Error.ZixUtils_Flate_OutputTooLarge,
        decompressGzipAlloc(std.testing.allocator, packed_bytes, 16),
    );
}

test "zix utils compression flate: gzip, malformed stream fails" {
    const garbage = "\x1f\x8b\x08\x00 not really gzip past the header";

    var out_buf: [64]u8 = undefined;

    try std.testing.expectError(
        Error.ZixUtils_Flate_DecompressFailed,
        decompressGzip(garbage, &out_buf),
    );
}

test "zix utils compression flate: gzip, compress into a short buffer is too small" {
    var original: [64]u8 = undefined;
    @memset(&original, 'A');

    var out_buf: [4]u8 = undefined;

    try std.testing.expectError(
        Error.ZixUtils_Flate_BufferTooSmall,
        compressGzip(std.testing.allocator, &original, &out_buf, .DEFAULT),
    );
}

test "zix utils compression flate: gzip, failing allocator is out of memory" {
    try std.testing.expectError(
        Error.ZixUtils_Flate_OutOfMemory,
        compressGzipAlloc(std.testing.failing_allocator, "abc", .DEFAULT),
    );
}

test "zix utils compression flate: deflate, round-trips ascii" {
    const original = "the quick brown fox jumps over the lazy dog";

    const packed_bytes = try compressDeflateAlloc(std.testing.allocator, original, .DEFAULT);
    defer std.testing.allocator.free(packed_bytes);

    const restored = try decompressDeflateAlloc(std.testing.allocator, packed_bytes, 1024);
    defer std.testing.allocator.free(restored);

    try std.testing.expectEqualStrings(original, restored);
}

test "zix utils compression flate: deflate, round-trips every byte value" {
    var original: [256]u8 = undefined;
    for (&original, 0..) |*byte, index| byte.* = @intCast(index);

    const packed_bytes = try compressDeflateAlloc(std.testing.allocator, &original, .DEFAULT);
    defer std.testing.allocator.free(packed_bytes);

    const restored = try decompressDeflateAlloc(std.testing.allocator, packed_bytes, 512);
    defer std.testing.allocator.free(restored);

    try std.testing.expectEqualSlices(u8, &original, restored);
}

test "zix utils compression flate: deflate, writes the zlib header" {
    var out_buf: [128]u8 = undefined;
    const written = try compressDeflate(
        std.testing.allocator,
        "zlib header check",
        &out_buf,
        .DEFAULT,
    );

    try std.testing.expect(written >= 2);
    try std.testing.expectEqual(@as(u8, 0x78), out_buf[0]);
    try std.testing.expect((@as(u16, out_buf[0]) * 256 + out_buf[1]) % 31 == 0);
}

test "zix utils compression flate: deflate, decodes a zlib vector" {
    const vector = "\x78\x9c\xcb\x48\xcd\xc9\xc9\xd7\x51\x48\x49\x4d\xcb\x49\x2c\x49" ++
        "\x05\x00\x26\xad\x05\x36";

    var out_buf: [32]u8 = undefined;
    const inflated = try decompressDeflate(vector, &out_buf);

    try std.testing.expectEqualStrings("hello, deflate", out_buf[0..inflated]);
}

test "zix utils compression flate: deflate, gzip stream does not decode" {
    const packed_gzip = try compressGzipAlloc(
        std.testing.allocator,
        "container mismatch",
        .DEFAULT,
    );
    defer std.testing.allocator.free(packed_gzip);

    var out_buf: [64]u8 = undefined;

    try std.testing.expectError(
        Error.ZixUtils_Flate_DecompressFailed,
        decompressDeflate(packed_gzip, &out_buf),
    );
}

test "zix utils compression flate: deflate, decompress past the cap is too large" {
    var original: [1024]u8 = undefined;
    @memset(&original, 'B');

    const packed_bytes = try compressDeflateAlloc(std.testing.allocator, &original, .DEFAULT);
    defer std.testing.allocator.free(packed_bytes);

    try std.testing.expectError(
        Error.ZixUtils_Flate_OutputTooLarge,
        decompressDeflateAlloc(std.testing.allocator, packed_bytes, 16),
    );
}

test "zix utils compression flate: compressBound, covers empty input" {
    try std.testing.expectEqual(@as(usize, 23), compressBound(0));
}

