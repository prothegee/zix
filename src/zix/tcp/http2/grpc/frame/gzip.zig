//! ZIX Http2 Grpc frame gzip
//!
//! ### file: src/zix/tcp/http2/grpc/frame/gzip.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! gzip for gRPC messages: compress one message, and decompress every
//! compressed message of a gRPC body.
//!
//! ### note:
//!
//! compressGrpcMessage takes its window and state from the heap
//! (std.heap.smp_allocator), about 64 KiB per call.
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

const prefix = @import("prefix.zig");

// --------------------------------------------------------- //
// Private:

const flate = std.compress.flate;

/// Compress.init needs more than this many bytes of output room.
const COMPRESS_OUT_MIN: usize = 8;

/// Decompress one message into out. Return the decompressed length.
fn inflateMessage(compressed: []const u8, out: []u8) Error!usize {
    var in_reader = std.Io.Reader.fixed(compressed);
    var decompress = flate.Decompress.init(&in_reader, .gzip, &.{});
    var out_writer = std.Io.Writer.fixed(out);

    return decompress.reader.streamRemaining(&out_writer) catch |err| switch (err) {
        error.ReadFailed => Error.ZixHttp2_GrpcGzip_DecompressFailed,
        error.WriteFailed => Error.ZixHttp2_GrpcGzip_BufferTooSmall,
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc frame gzip error
pub const Error = error {
    ZixHttp2_GrpcGzip_TruncatedBody,
    ZixHttp2_GrpcGzip_DecompressFailed,
    ZixHttp2_GrpcGzip_BufferTooSmall,
    ZixHttp2_GrpcGzip_CompressFailed,
    ZixHttp2_GrpcGzip_OutOfMemory,
};

/// Output room over the message length that compressGrpcMessage always fits
/// in: gzip header, trailer, and the gRPC prefix.
pub const GZIP_FRAMING_HEADROOM: usize = 128;

/// Decompress a gRPC body (5-byte prefix plus message, repeated) into out_buf.
///
/// Note:
/// - A message with compress flag 1 is gunzipped, flag 0 is copied as is.
/// - Every message in out_buf has compress flag 0.
/// - Fewer than 5 bytes left after the last message are ignored.
///
/// Param:
/// body - []const u8 (gRPC body, starting at a prefix)
/// out_buf - []u8 (destination)
///
/// Return:
/// - usize (bytes written into out_buf)
/// - error.ZixHttp2_GrpcGzip_TruncatedBody when a message is past the body
/// - error.ZixHttp2_GrpcGzip_DecompressFailed when a message is not valid gzip
/// - error.ZixHttp2_GrpcGzip_BufferTooSmall when out_buf cannot hold the result
pub fn decompressGrpcBody(body: []const u8, out_buf: []u8) Error!usize {
    var in_pos: usize = 0;
    var out_pos: usize = 0;

    while (body.len - in_pos >= prefix.PREFIX_LEN) {
        const grpc_prefix = prefix.readGrpcPrefix(body[in_pos..]) catch |err| switch (err) {
            error.ZixHttp2_GrpcPrefix_TooShort => return Error.ZixHttp2_GrpcGzip_TruncatedBody,
        };
        const msg_len: usize = grpc_prefix.msg_len;
        const total = prefix.PREFIX_LEN + msg_len;
        if (total > body.len - in_pos) return Error.ZixHttp2_GrpcGzip_TruncatedBody;

        if (grpc_prefix.compress) {
            if (prefix.PREFIX_LEN > out_buf.len - out_pos) {
                return Error.ZixHttp2_GrpcGzip_BufferTooSmall;
            }

            const compressed = body[in_pos + prefix.PREFIX_LEN ..][0..msg_len];
            const out_msg = out_buf[out_pos + prefix.PREFIX_LEN ..];
            const inflated_len = try inflateMessage(compressed, out_msg);
            if (inflated_len > std.math.maxInt(u32)) {
                return Error.ZixHttp2_GrpcGzip_BufferTooSmall;
            }

            prefix.writeGrpcPrefix(
                out_buf[out_pos..][0..prefix.PREFIX_LEN],
                false,
                @intCast(inflated_len),
            );
            out_pos += prefix.PREFIX_LEN + inflated_len;
        } else {
            if (total > out_buf.len - out_pos) return Error.ZixHttp2_GrpcGzip_BufferTooSmall;

            @memcpy(out_buf[out_pos..][0..total], body[in_pos..][0..total]);
            out_pos += total;
        }

        in_pos += total;
    }

    return out_pos;
}

/// gzip data into out_buf, at the fastest level (level_1) for low latency.
///
/// Note:
/// - out_buf of data.len + GZIP_FRAMING_HEADROOM always fits.
///
/// Param:
/// data - []const u8 (message payload to compress)
/// out_buf - []u8 (destination)
///
/// Return:
/// - usize (compressed byte count)
/// - error.ZixHttp2_GrpcGzip_CompressFailed when out_buf is too small
/// - error.ZixHttp2_GrpcGzip_OutOfMemory when the window cannot be allocated
pub fn compressGrpcMessage(data: []const u8, out_buf: []u8) Error!usize {
    if (out_buf.len <= COMPRESS_OUT_MIN) return Error.ZixHttp2_GrpcGzip_CompressFailed;

    const allocator = std.heap.smp_allocator;

    const window = allocator.alloc(u8, flate.max_window_len) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_GrpcGzip_OutOfMemory,
    };
    defer allocator.free(window);

    const compress = allocator.create(flate.Compress) catch |err| switch (err) {
        error.OutOfMemory => return Error.ZixHttp2_GrpcGzip_OutOfMemory,
    };
    defer allocator.destroy(compress);

    var out_writer = std.Io.Writer.fixed(out_buf);
    compress.* = flate.Compress.init(
        &out_writer,
        window,
        .gzip,
        flate.Compress.Options.level_1,
    ) catch |err| switch (err) {
        error.WriteFailed => return Error.ZixHttp2_GrpcGzip_CompressFailed,
    };

    compress.writer.writeAll(data) catch |err| switch (err) {
        error.WriteFailed => return Error.ZixHttp2_GrpcGzip_CompressFailed,
    };
    compress.finish() catch |err| switch (err) {
        error.WriteFailed => return Error.ZixHttp2_GrpcGzip_CompressFailed,
    };

    return out_writer.end;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

/// Build a one-message body with compress flag 1 from data. Return its length.
fn testCompressedBody(data: []const u8, body: []u8) !usize {
    const comp_len = try compressGrpcMessage(data, body[prefix.PREFIX_LEN..]);
    prefix.writeGrpcPrefix(body[0..prefix.PREFIX_LEN], true, @intCast(comp_len));

    return prefix.PREFIX_LEN + comp_len;
}

test "zix http2 grpc frame: gzip, round trip restores the message" {
    const original = "hello grpc compression";
    var body: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;

    const body_len = try testCompressedBody(original, &body);
    const out_len = try decompressGrpcBody(body[0..body_len], &out_buf);

    try std.testing.expectEqual(prefix.PREFIX_LEN + original.len, out_len);
    try std.testing.expectEqualStrings(original, out_buf[prefix.PREFIX_LEN..out_len]);
}

test "zix http2 grpc frame: gzip, decompressed prefix has compress flag 0" {
    const original = "hello grpc compression";
    var body: [256]u8 = undefined;
    var out_buf: [256]u8 = undefined;

    const body_len = try testCompressedBody(original, &body);
    _ = try decompressGrpcBody(body[0..body_len], &out_buf);
    const grpc_prefix = try prefix.readGrpcPrefix(&out_buf);

    try std.testing.expect(!grpc_prefix.compress);
    try std.testing.expectEqual(@as(u32, original.len), grpc_prefix.msg_len);
}

test "zix http2 grpc frame: gzip, large message round trips whole" {
    const allocator = std.testing.allocator;
    const len: usize = 200 * 1024;

    const original = try allocator.alloc(u8, len);
    defer allocator.free(original);
    for (original, 0..) |*byte, i| byte.* = @truncate(i *% 131 +% i / 7);

    const body = try allocator.alloc(u8, len + GZIP_FRAMING_HEADROOM + prefix.PREFIX_LEN);
    defer allocator.free(body);
    const out_buf = try allocator.alloc(u8, len + prefix.PREFIX_LEN);
    defer allocator.free(out_buf);

    const body_len = try testCompressedBody(original, body);
    const out_len = try decompressGrpcBody(body[0..body_len], out_buf);

    try std.testing.expectEqual(prefix.PREFIX_LEN + len, out_len);
    try std.testing.expectEqualSlices(u8, original, out_buf[prefix.PREFIX_LEN..out_len]);
}

test "zix http2 grpc frame: gzip, empty message round trips" {
    var body: [256]u8 = undefined;
    var out_buf: [16]u8 = undefined;

    const body_len = try testCompressedBody("", &body);
    const out_len = try decompressGrpcBody(body[0..body_len], &out_buf);

    try std.testing.expectEqual(prefix.PREFIX_LEN, out_len);
}

test "zix http2 grpc frame: gzip, uncompressed message passes through" {
    var body: [12]u8 = undefined;
    prefix.writeGrpcPrefix(body[0..prefix.PREFIX_LEN], false, 7);
    @memcpy(body[prefix.PREFIX_LEN..], "abcdefg");
    var out_buf: [32]u8 = undefined;

    const out_len = try decompressGrpcBody(&body, &out_buf);

    try std.testing.expectEqualSlices(u8, &body, out_buf[0..out_len]);
}

test "zix http2 grpc frame: gzip, mixed messages keep their order" {
    var body: [256]u8 = undefined;
    const first_len = try testCompressedBody("one", &body);
    prefix.writeGrpcPrefix(body[first_len..][0..prefix.PREFIX_LEN], false, 3);
    @memcpy(body[first_len + prefix.PREFIX_LEN ..][0..3], "two");
    const body_len = first_len + prefix.PREFIX_LEN + 3;
    var out_buf: [64]u8 = undefined;

    const out_len = try decompressGrpcBody(body[0..body_len], &out_buf);

    try std.testing.expectEqual(@as(usize, 16), out_len);
    try std.testing.expectEqualStrings("one", out_buf[prefix.PREFIX_LEN..][0..3]);
    try std.testing.expectEqualStrings("two", out_buf[2 * prefix.PREFIX_LEN + 3 ..][0..3]);
}

test "zix http2 grpc frame: gzip, empty body writes nothing" {
    var out_buf: [16]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), try decompressGrpcBody("", &out_buf));
}

test "zix http2 grpc frame: gzip, tail shorter than a prefix is ignored" {
    const body = [_]u8{ 0, 0, 0 };
    var out_buf: [16]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), try decompressGrpcBody(&body, &out_buf));
}

test "zix http2 grpc frame: gzip, message past the body is TruncatedBody" {
    var body: [prefix.PREFIX_LEN]u8 = undefined;
    prefix.writeGrpcPrefix(&body, false, 100);
    var out_buf: [256]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_GrpcGzip_TruncatedBody,
        decompressGrpcBody(&body, &out_buf),
    );
}

test "zix http2 grpc frame: gzip, max u32 length is TruncatedBody" {
    var body: [prefix.PREFIX_LEN]u8 = undefined;
    prefix.writeGrpcPrefix(&body, true, std.math.maxInt(u32));
    var out_buf: [256]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_GrpcGzip_TruncatedBody,
        decompressGrpcBody(&body, &out_buf),
    );
}

test "zix http2 grpc frame: gzip, malformed gzip is DecompressFailed" {
    var body: [prefix.PREFIX_LEN + 12]u8 = undefined;
    prefix.writeGrpcPrefix(body[0..prefix.PREFIX_LEN], true, 12);
    @memset(body[prefix.PREFIX_LEN..], 0xAB);
    var out_buf: [256]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_GrpcGzip_DecompressFailed,
        decompressGrpcBody(&body, &out_buf),
    );
}

test "zix http2 grpc frame: gzip, out too small for a plain message is BufferTooSmall" {
    var body: [12]u8 = undefined;
    prefix.writeGrpcPrefix(body[0..prefix.PREFIX_LEN], false, 7);
    @memcpy(body[prefix.PREFIX_LEN..], "abcdefg");
    var out_buf: [8]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_GrpcGzip_BufferTooSmall,
        decompressGrpcBody(&body, &out_buf),
    );
}

test "zix http2 grpc frame: gzip, out too small for the prefix is BufferTooSmall" {
    var body: [256]u8 = undefined;
    const body_len = try testCompressedBody("hello", &body);
    var out_buf: [4]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_GrpcGzip_BufferTooSmall,
        decompressGrpcBody(body[0..body_len], &out_buf),
    );
}

test "zix http2 grpc frame: gzip, out too small for the inflated message is BufferTooSmall" {
    const original: [64]u8 = @splat('z');
    var body: [256]u8 = undefined;
    const body_len = try testCompressedBody(&original, &body);
    var out_buf: [prefix.PREFIX_LEN + 16]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_GrpcGzip_BufferTooSmall,
        decompressGrpcBody(body[0..body_len], &out_buf),
    );
}

test "zix http2 grpc frame: gzip, compressed output starts with the gzip magic" {
    var out_buf: [256]u8 = undefined;

    const comp_len = try compressGrpcMessage("hello", &out_buf);

    try std.testing.expect(comp_len > 2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x1f, 0x8b }, out_buf[0..2]);
}

test "zix http2 grpc frame: gzip, headroom always fits incompressible data" {
    var data: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(&data);
    var out_buf: [data.len + GZIP_FRAMING_HEADROOM]u8 = undefined;

    const comp_len = try compressGrpcMessage(&data, &out_buf);

    try std.testing.expect(comp_len <= out_buf.len);
}

test "zix http2 grpc frame: gzip, out at the minimum is CompressFailed" {
    var out_buf: [COMPRESS_OUT_MIN]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_GrpcGzip_CompressFailed,
        compressGrpcMessage("hello", &out_buf),
    );
}

test "zix http2 grpc frame: gzip, out too small for the stream is CompressFailed" {
    var data: [1024]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(11);
    prng.random().bytes(&data);
    var out_buf: [64]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_GrpcGzip_CompressFailed,
        compressGrpcMessage(&data, &out_buf),
    );
}

