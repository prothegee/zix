//! ZIX Http2 Grpc encoding
//!
//! ### file: src/zix/tcp/http2/grpc/encoding.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Message compression a call asks for: grpc-encoding inbound,
//! grpc-accept-encoding outbound.
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
const gzip = @import("frame/gzip.zig");
const Header = @import("../hpack/Header.zig");

// --------------------------------------------------------- //
// Public:

/// Whether the client sent `grpc-encoding: gzip` (inbound messages are compressed).
///
/// Param:
/// headers - []const Header (decoded request headers)
///
/// Return:
/// - bool
pub fn headersHaveGzipEncoding(headers: []const Header) bool {
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "grpc-encoding")) continue;

        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, header.value, " "), "gzip")) return true;
    }

    return false;
}

/// Whether the client listed gzip in `grpc-accept-encoding`.
///
/// Param:
/// headers - []const Header (decoded request headers)
///
/// Return:
/// - bool
pub fn headersAcceptGzip(headers: []const Header) bool {
    for (headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, "grpc-accept-encoding")) continue;

        var parts = std.mem.splitScalar(u8, header.value, ',');
        while (parts.next()) |part| {
            if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, part, " "), "gzip")) return true;
        }
    }

    return false;
}

/// The body a handler reads: gunzipped when the client sent
/// `grpc-encoding: gzip`, the body as is otherwise.
///
/// Note:
/// - The gunzipped body lives in a heap buffer of max_body bytes, handed back
///   through decomp_out. The caller frees it with std.heap.smp_allocator.
/// - A body that does not gunzip, or a failed allocation, falls back to the
///   body as is. The handler then reads the compressed messages.
///
/// Param:
/// body - []const u8 (the gRPC body, starting at a prefix)
/// headers - []const Header (decoded request headers)
/// max_body - usize (size of the gunzip buffer)
/// decomp_out - *?[]u8 (set to the heap buffer, null when none was kept)
///
/// Return:
/// - []const u8 (the effective body)
pub fn maybeDecompressBody(
    body: []const u8,
    headers: []const Header,
    max_body: usize,
    decomp_out: *?[]u8,
) []const u8 {
    decomp_out.* = null;

    if (!headersHaveGzipEncoding(headers)) return body;

    const allocator = std.heap.smp_allocator;
    const buf = allocator.alloc(u8, max_body) catch |err| switch (err) {
        error.OutOfMemory => return body,
    };

    const len = gzip.decompressGrpcBody(body, buf) catch |err| switch (err) {
        error.ZixHttp2_GrpcGzip_TruncatedBody,
        error.ZixHttp2_GrpcGzip_DecompressFailed,
        error.ZixHttp2_GrpcGzip_BufferTooSmall,
        error.ZixHttp2_GrpcGzip_CompressFailed,
        error.ZixHttp2_GrpcGzip_OutOfMemory,
        => {
            allocator.free(buf);

            return body;
        },
    };

    decomp_out.* = buf;

    return buf[0..len];
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const prefix = @import("frame/prefix.zig");

fn oneHeader(name: []const u8, value: []const u8) [1]Header {
    return .{
        .{
            .name = name,
            .value = value,
        },
    };
}

test "zix http2 grpc: encoding, headersHaveGzipEncoding sees gzip" {
    const headers = oneHeader("grpc-encoding", " gzip ");

    try std.testing.expect(headersHaveGzipEncoding(&headers));
}

test "zix http2 grpc: encoding, headersHaveGzipEncoding ignores identity" {
    const headers = oneHeader("grpc-encoding", "identity");

    try std.testing.expect(!headersHaveGzipEncoding(&headers));
}

test "zix http2 grpc: encoding, headersHaveGzipEncoding without the header is false" {
    try std.testing.expect(!headersHaveGzipEncoding(&.{}));
}

test "zix http2 grpc: encoding, headersAcceptGzip finds gzip in a list" {
    const headers = oneHeader("grpc-accept-encoding", "identity, deflate, GZIP");

    try std.testing.expect(headersAcceptGzip(&headers));
}

test "zix http2 grpc: encoding, headersAcceptGzip without gzip is false" {
    const headers = oneHeader("grpc-accept-encoding", "identity,deflate");

    try std.testing.expect(!headersAcceptGzip(&headers));
}

test "zix http2 grpc: encoding, maybeDecompressBody without gzip keeps the body" {
    var decomp: ?[]u8 = null;
    const body = "plain";

    const effective = maybeDecompressBody(body, &.{}, 64, &decomp);

    try std.testing.expectEqualStrings(body, effective);
    try std.testing.expect(decomp == null);
}

test "zix http2 grpc: encoding, maybeDecompressBody gunzips a compressed message" {
    var body: [256]u8 = undefined;
    const gz_len = try gzip.compressGrpcMessage("hello", body[prefix.PREFIX_LEN..]);
    prefix.writeGrpcPrefix(body[0..prefix.PREFIX_LEN], true, @intCast(gz_len));

    const headers = oneHeader("grpc-encoding", "gzip");
    var decomp: ?[]u8 = null;
    const body_len = prefix.PREFIX_LEN + gz_len;

    const effective = maybeDecompressBody(body[0..body_len], &headers, 256, &decomp);
    defer if (decomp) |buf| std.heap.smp_allocator.free(buf);

    try std.testing.expect(decomp != null);
    try std.testing.expectEqual(@as(usize, prefix.PREFIX_LEN + 5), effective.len);
    try std.testing.expectEqualStrings("hello", effective[prefix.PREFIX_LEN..]);
}

test "zix http2 grpc: encoding, maybeDecompressBody malformed falls back to the body" {
    var body: [7]u8 = undefined;
    prefix.writeGrpcPrefix(body[0..prefix.PREFIX_LEN], true, 2);
    @memcpy(body[prefix.PREFIX_LEN..], "xx");

    const headers = oneHeader("grpc-encoding", "gzip");
    var decomp: ?[]u8 = null;

    const effective = maybeDecompressBody(&body, &headers, 64, &decomp);

    try std.testing.expectEqualSlices(u8, &body, effective);
    try std.testing.expect(decomp == null);
}

