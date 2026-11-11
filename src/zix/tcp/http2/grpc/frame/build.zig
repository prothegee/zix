//! ZIX Http2 Grpc frame build
//!
//! ### file: src/zix/tcp/http2/grpc/frame/build.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Encode gRPC reply frames into a caller buffer: initial HEADERS, the DATA
//! head (frame header plus gRPC prefix), the trailer, and the trailers-only error.
//!
//! ### note:
//!
//! - The default content-type and the OK trailer copy a comptime block
//!   (reply_block.zig). Anything else runs the HPACK encoder.
//! - An HPACK block always fits HEADERS_FRAME_SCRATCH, so an out of that size
//!   never returns BufferFull for a block, only for a header past the scratch.
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

const frame = @import("../../frame.zig");
const HpackEncoder = @import("../../hpack/HpackEncoder.zig");
const prefix = @import("prefix.zig");
const reply_block = @import("reply_block.zig");

// --------------------------------------------------------- //
// Private:

const Inner = Error || HpackEncoder.Error;

/// Room for the decimal text of a u8 status.
const STATUS_TEXT_LEN: usize = 3;

const FLAGS_TRAILER: u8 = frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM;

/// Stamp a HEADERS frame header plus an HPACK block into out.
fn emitHeaders(out: []u8, stream_id: u31, flags: u8, block: []const u8) Error!usize {
    const total = frame.FRAME_HEADER_LEN + block.len;
    if (out.len < total) return Error.ZixHttp2_GrpcBuild_BufferFull;

    frame.encodeFrameHeader(out[0..frame.FRAME_HEADER_LEN], .{
        .length = @intCast(block.len),
        .frame_type = frame.FRAME_TYPE_HEADERS,
        .flags = flags,
        .stream_id = stream_id,
    });
    @memcpy(out[frame.FRAME_HEADER_LEN..][0..block.len], block);

    return total;
}

/// Write grpc-status, then grpc-message when it is not empty.
fn writeStatus(encoder: *HpackEncoder, grpc_status: u8, grpc_message: []const u8) Inner!void {
    var status_text: [STATUS_TEXT_LEN]u8 = undefined;
    const status_len = std.fmt.printInt(&status_text, grpc_status, 10, .lower, .{});

    try encoder.writeHeader("grpc-status", status_text[0..status_len]);
    if (grpc_message.len > 0) try encoder.writeHeader("grpc-message", grpc_message);
}

fn headersInner(
    out: []u8,
    stream_id: u31,
    content_type: []const u8,
    gzip: bool,
) Inner!usize {
    var block_buf: [frame.HPACK_ENCODE_SCRATCH]u8 = undefined;
    var encoder = HpackEncoder.init(&block_buf);

    try encoder.writeHeader(":status", "200");
    try encoder.writeHeader("content-type", content_type);
    if (gzip) try encoder.writeHeader("grpc-encoding", "gzip");

    return emitHeaders(out, stream_id, frame.FLAG_END_HEADERS, encoder.encoded());
}

fn trailerInner(
    out: []u8,
    stream_id: u31,
    grpc_status: u8,
    grpc_message: []const u8,
) Inner!usize {
    var block_buf: [frame.HPACK_ENCODE_SCRATCH]u8 = undefined;
    var encoder = HpackEncoder.init(&block_buf);

    try writeStatus(&encoder, grpc_status, grpc_message);

    return emitHeaders(out, stream_id, FLAGS_TRAILER, encoder.encoded());
}

fn errorInner(
    out: []u8,
    stream_id: u31,
    grpc_status: u8,
    grpc_message: []const u8,
) Inner!usize {
    var block_buf: [frame.HPACK_ENCODE_SCRATCH]u8 = undefined;
    var encoder = HpackEncoder.init(&block_buf);

    try encoder.writeHeader(":status", "200");
    try encoder.writeHeader("content-type", reply_block.GRPC_CONTENT_TYPE);
    try writeStatus(&encoder, grpc_status, grpc_message);

    return emitHeaders(out, stream_id, FLAGS_TRAILER, encoder.encoded());
}

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixHttp2_HpackEncoder_UnexpectedEOF => Error.ZixHttp2_GrpcBuild_UnexpectedEOF,
        error.ZixHttp2_HpackEncoder_Overflow => Error.ZixHttp2_GrpcBuild_Overflow,
        error.ZixHttp2_HpackEncoder_BufferFull => Error.ZixHttp2_GrpcBuild_BufferFull,
        error.ZixHttp2_GrpcBuild_UnexpectedEOF => Error.ZixHttp2_GrpcBuild_UnexpectedEOF,
        error.ZixHttp2_GrpcBuild_Overflow => Error.ZixHttp2_GrpcBuild_Overflow,
        error.ZixHttp2_GrpcBuild_BufferFull => Error.ZixHttp2_GrpcBuild_BufferFull,
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc frame build error
pub const Error = error {
    ZixHttp2_GrpcBuild_UnexpectedEOF,
    ZixHttp2_GrpcBuild_Overflow,
    ZixHttp2_GrpcBuild_BufferFull,
};

/// Room for any HEADERS or trailer frame built here: frame header plus HPACK block.
pub const HEADERS_FRAME_SCRATCH: usize = frame.FRAME_HEADER_LEN + frame.HPACK_ENCODE_SCRATCH;

/// Size of a DATA head: frame header plus gRPC prefix.
pub const DATA_HEAD_LEN: usize = frame.FRAME_HEADER_LEN + prefix.PREFIX_LEN;

/// Largest message one DATA frame can carry after the gRPC prefix.
pub const MAX_DATA_MSG_LEN: usize = std.math.maxInt(u24) - prefix.PREFIX_LEN;

/// Encode the initial response HEADERS (`:status 200`, content-type). No END_STREAM.
///
/// Note:
/// - GRPC_CONTENT_TYPE copies a comptime block, no HPACK encode.
///
/// Param:
/// out - []u8 (destination, HEADERS_FRAME_SCRATCH always fits)
/// stream_id - u31 (the stream to answer)
/// content_type - []const u8 (response content-type)
///
/// Return:
/// - usize (bytes written)
/// - error.ZixHttp2_GrpcBuild_BufferFull when the frame does not fit out or the scratch
pub fn buildGrpcHeaders(out: []u8, stream_id: u31, content_type: []const u8) Error!usize {
    if (std.mem.eql(u8, content_type, reply_block.GRPC_CONTENT_TYPE)) {
        return emitHeaders(
            out,
            stream_id,
            frame.FLAG_END_HEADERS,
            reply_block.HEADERS_PROTO_BLOCK,
        );
    }

    return headersInner(out, stream_id, content_type, false) catch |err| innerError(err);
}

/// buildGrpcHeaders plus `grpc-encoding: gzip`, for gzip-compressed DATA frames.
///
/// Param:
/// out - []u8 (destination, HEADERS_FRAME_SCRATCH always fits)
/// stream_id - u31 (the stream to answer)
/// content_type - []const u8 (response content-type)
///
/// Return:
/// - usize (bytes written)
/// - error.ZixHttp2_GrpcBuild_BufferFull when the frame does not fit out or the scratch
pub fn buildGrpcHeadersGzip(out: []u8, stream_id: u31, content_type: []const u8) Error!usize {
    return headersInner(out, stream_id, content_type, true) catch |err| innerError(err);
}

/// Encode a DATA frame header plus the gRPC prefix. No END_STREAM.
///
/// Note:
/// - The caller sends the message payload right after these DATA_HEAD_LEN bytes.
///
/// Param:
/// out - []u8 (destination, at least DATA_HEAD_LEN)
/// stream_id - u31 (the stream to answer)
/// msg_len - usize (message payload length)
/// compress - bool (true sets compress flag 1 in the gRPC prefix)
///
/// Return:
/// - usize (always DATA_HEAD_LEN)
/// - error.ZixHttp2_GrpcBuild_BufferFull when out is shorter than DATA_HEAD_LEN
/// - error.ZixHttp2_GrpcBuild_Overflow when msg_len is past MAX_DATA_MSG_LEN
pub fn buildGrpcDataHeader(
    out: []u8,
    stream_id: u31,
    msg_len: usize,
    compress: bool,
) Error!usize {
    if (out.len < DATA_HEAD_LEN) return Error.ZixHttp2_GrpcBuild_BufferFull;
    if (msg_len > MAX_DATA_MSG_LEN) return Error.ZixHttp2_GrpcBuild_Overflow;

    frame.encodeFrameHeader(out[0..frame.FRAME_HEADER_LEN], .{
        .length = @intCast(prefix.PREFIX_LEN + msg_len),
        .frame_type = frame.FRAME_TYPE_DATA,
        .flags = 0,
        .stream_id = stream_id,
    });
    prefix.writeGrpcPrefix(
        out[frame.FRAME_HEADER_LEN..][0..prefix.PREFIX_LEN],
        compress,
        @intCast(msg_len),
    );

    return DATA_HEAD_LEN;
}

/// Encode the trailer HEADERS (grpc-status, grpc-message). END_STREAM.
///
/// Note:
/// - Status 0 with an empty message copies a comptime block, no HPACK encode.
/// - An empty grpc_message omits the header.
///
/// Param:
/// out - []u8 (destination, HEADERS_FRAME_SCRATCH always fits)
/// stream_id - u31 (the stream to close)
/// grpc_status - u8 (gRPC status code)
/// grpc_message - []const u8 (status message, may be empty)
///
/// Return:
/// - usize (bytes written)
/// - error.ZixHttp2_GrpcBuild_BufferFull when the frame does not fit out or the scratch
pub fn buildGrpcTrailer(
    out: []u8,
    stream_id: u31,
    grpc_status: u8,
    grpc_message: []const u8,
) Error!usize {
    if (grpc_status == 0 and grpc_message.len == 0) {
        return emitHeaders(out, stream_id, FLAGS_TRAILER, reply_block.TRAILER_OK_BLOCK);
    }

    return trailerInner(out, stream_id, grpc_status, grpc_message) catch |err| {
        return innerError(err);
    };
}

/// Encode a trailers-only error reply (no DATA frame). END_STREAM.
///
/// Note:
/// - Carries `:status 200` and content-type GRPC_CONTENT_TYPE, as the gRPC spec asks.
///
/// Param:
/// out - []u8 (destination, HEADERS_FRAME_SCRATCH always fits)
/// stream_id - u31 (the stream to close)
/// grpc_status - u8 (gRPC status code)
/// grpc_message - []const u8 (status message, may be empty)
///
/// Return:
/// - usize (bytes written)
/// - error.ZixHttp2_GrpcBuild_BufferFull when the frame does not fit out or the scratch
pub fn buildGrpcError(
    out: []u8,
    stream_id: u31,
    grpc_status: u8,
    grpc_message: []const u8,
) Error!usize {
    return errorInner(out, stream_id, grpc_status, grpc_message) catch |err| {
        return innerError(err);
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const HpackDecoder = @import("../../hpack/HpackDecoder.zig");
const Header = @import("../../hpack/Header.zig");
const FrameHeader = @import("../../FrameHeader.zig");

const TestDecoded = struct {
    header: FrameHeader,
    headers: [8]Header,
    count: usize,
};

/// Parse the frame header in buf and decode its HPACK block.
fn testDecode(buf: []const u8, len: usize, scratch: []u8) !TestDecoded {
    var decoded: TestDecoded = undefined;
    decoded.header = frame.parseFrameHeader(buf[0..frame.FRAME_HEADER_LEN]);

    var decoder = HpackDecoder.init();
    decoded.count = try decoder.decode(
        buf[frame.FRAME_HEADER_LEN..len],
        &decoded.headers,
        scratch,
    );

    return decoded;
}

/// Value of the named header, or null.
fn testValue(decoded: *const TestDecoded, name: []const u8) ?[]const u8 {
    for (decoded.headers[0..decoded.count]) |header| {
        if (std.mem.eql(u8, header.name, name)) return header.value;
    }

    return null;
}

test "zix http2 grpc frame: build, buildGrpcHeaders default type is HEADERS with END_HEADERS" {
    var buf: [HEADERS_FRAME_SCRATCH]u8 = undefined;
    var scratch: [256]u8 = undefined;

    const len = try buildGrpcHeaders(&buf, 1, reply_block.GRPC_CONTENT_TYPE);
    const decoded = try testDecode(&buf, len, &scratch);

    try std.testing.expectEqual(frame.FRAME_TYPE_HEADERS, decoded.header.frame_type);
    try std.testing.expectEqual(frame.FLAG_END_HEADERS, decoded.header.flags);
    try std.testing.expectEqual(@as(u31, 1), decoded.header.stream_id);
}

test "zix http2 grpc frame: build, buildGrpcHeaders default type copies the cached block" {
    var buf: [HEADERS_FRAME_SCRATCH]u8 = undefined;

    const len = try buildGrpcHeaders(&buf, 1, reply_block.GRPC_CONTENT_TYPE);

    try std.testing.expectEqualSlices(
        u8,
        reply_block.HEADERS_PROTO_BLOCK,
        buf[frame.FRAME_HEADER_LEN..len],
    );
}

test "zix http2 grpc frame: build, buildGrpcHeaders other type decodes to status and type" {
    var buf: [HEADERS_FRAME_SCRATCH]u8 = undefined;
    var scratch: [256]u8 = undefined;

    const len = try buildGrpcHeaders(&buf, 3, "application/grpc+json");
    const decoded = try testDecode(&buf, len, &scratch);

    try std.testing.expectEqualStrings("200", testValue(&decoded, ":status").?);
    try std.testing.expectEqualStrings(
        "application/grpc+json",
        testValue(&decoded, "content-type").?,
    );
}

test "zix http2 grpc frame: build, buildGrpcHeaders out too small is BufferFull" {
    var buf: [frame.FRAME_HEADER_LEN]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_GrpcBuild_BufferFull,
        buildGrpcHeaders(&buf, 1, reply_block.GRPC_CONTENT_TYPE),
    );
}

test "zix http2 grpc frame: build, buildGrpcHeaders type past the scratch is BufferFull" {
    var buf: [HEADERS_FRAME_SCRATCH]u8 = undefined;
    const long_type: [frame.HPACK_ENCODE_SCRATCH]u8 = @splat('~');

    try std.testing.expectError(
        Error.ZixHttp2_GrpcBuild_BufferFull,
        buildGrpcHeaders(&buf, 1, &long_type),
    );
}

test "zix http2 grpc frame: build, buildGrpcHeadersGzip carries grpc-encoding gzip" {
    var buf: [HEADERS_FRAME_SCRATCH]u8 = undefined;
    var scratch: [256]u8 = undefined;

    const len = try buildGrpcHeadersGzip(&buf, 1, reply_block.GRPC_CONTENT_TYPE);
    const decoded = try testDecode(&buf, len, &scratch);

    try std.testing.expectEqual(frame.FLAG_END_HEADERS, decoded.header.flags);
    try std.testing.expectEqualStrings("gzip", testValue(&decoded, "grpc-encoding").?);
}

test "zix http2 grpc frame: build, buildGrpcHeadersGzip out too small is BufferFull" {
    var buf: [frame.FRAME_HEADER_LEN]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_GrpcBuild_BufferFull,
        buildGrpcHeadersGzip(&buf, 1, reply_block.GRPC_CONTENT_TYPE),
    );
}

test "zix http2 grpc frame: build, buildGrpcDataHeader frame length counts the prefix" {
    var buf: [DATA_HEAD_LEN]u8 = undefined;

    const len = try buildGrpcDataHeader(&buf, 5, 10, false);
    const header = frame.parseFrameHeader(buf[0..frame.FRAME_HEADER_LEN]);

    try std.testing.expectEqual(DATA_HEAD_LEN, len);
    try std.testing.expectEqual(frame.FRAME_TYPE_DATA, header.frame_type);
    try std.testing.expectEqual(@as(u24, 15), header.length);
    try std.testing.expectEqual(@as(u8, 0), header.flags);
}

test "zix http2 grpc frame: build, buildGrpcDataHeader prefix holds the message length" {
    var buf: [DATA_HEAD_LEN]u8 = undefined;

    _ = try buildGrpcDataHeader(&buf, 1, 10, false);
    const grpc_prefix = try prefix.readGrpcPrefix(buf[frame.FRAME_HEADER_LEN..]);

    try std.testing.expect(!grpc_prefix.compress);
    try std.testing.expectEqual(@as(u32, 10), grpc_prefix.msg_len);
}

test "zix http2 grpc frame: build, buildGrpcDataHeader compress sets flag 1" {
    var buf: [DATA_HEAD_LEN]u8 = undefined;

    _ = try buildGrpcDataHeader(&buf, 1, 10, true);

    try std.testing.expectEqual(@as(u8, 1), buf[frame.FRAME_HEADER_LEN]);
}

test "zix http2 grpc frame: build, buildGrpcDataHeader MAX_DATA_MSG_LEN fills u24" {
    var buf: [DATA_HEAD_LEN]u8 = undefined;

    _ = try buildGrpcDataHeader(&buf, 1, MAX_DATA_MSG_LEN, false);
    const header = frame.parseFrameHeader(buf[0..frame.FRAME_HEADER_LEN]);

    try std.testing.expectEqual(@as(u24, std.math.maxInt(u24)), header.length);
}

test "zix http2 grpc frame: build, buildGrpcDataHeader past MAX_DATA_MSG_LEN is Overflow" {
    var buf: [DATA_HEAD_LEN]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_GrpcBuild_Overflow,
        buildGrpcDataHeader(&buf, 1, MAX_DATA_MSG_LEN + 1, false),
    );
}

test "zix http2 grpc frame: build, buildGrpcDataHeader out too small is BufferFull" {
    var buf: [DATA_HEAD_LEN - 1]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_GrpcBuild_BufferFull,
        buildGrpcDataHeader(&buf, 1, 10, false),
    );
}

test "zix http2 grpc frame: build, buildGrpcTrailer OK copies the cached block" {
    var buf: [HEADERS_FRAME_SCRATCH]u8 = undefined;

    const len = try buildGrpcTrailer(&buf, 3, 0, "");
    const header = frame.parseFrameHeader(buf[0..frame.FRAME_HEADER_LEN]);

    try std.testing.expectEqual(FLAGS_TRAILER, header.flags);
    try std.testing.expectEqualSlices(
        u8,
        reply_block.TRAILER_OK_BLOCK,
        buf[frame.FRAME_HEADER_LEN..len],
    );
}

test "zix http2 grpc frame: build, buildGrpcTrailer carries status and message" {
    var buf: [HEADERS_FRAME_SCRATCH]u8 = undefined;
    var scratch: [256]u8 = undefined;

    const len = try buildGrpcTrailer(&buf, 3, 13, "boom");
    const decoded = try testDecode(&buf, len, &scratch);

    try std.testing.expectEqual(FLAGS_TRAILER, decoded.header.flags);
    try std.testing.expectEqualStrings("13", testValue(&decoded, "grpc-status").?);
    try std.testing.expectEqualStrings("boom", testValue(&decoded, "grpc-message").?);
}

test "zix http2 grpc frame: build, buildGrpcTrailer empty message omits grpc-message" {
    var buf: [HEADERS_FRAME_SCRATCH]u8 = undefined;
    var scratch: [256]u8 = undefined;

    const len = try buildGrpcTrailer(&buf, 3, 5, "");
    const decoded = try testDecode(&buf, len, &scratch);

    try std.testing.expectEqualStrings("5", testValue(&decoded, "grpc-status").?);
    try std.testing.expect(testValue(&decoded, "grpc-message") == null);
}

test "zix http2 grpc frame: build, buildGrpcTrailer max u8 status encodes 255" {
    var buf: [HEADERS_FRAME_SCRATCH]u8 = undefined;
    var scratch: [256]u8 = undefined;

    const len = try buildGrpcTrailer(&buf, 3, 255, "");
    const decoded = try testDecode(&buf, len, &scratch);

    try std.testing.expectEqualStrings("255", testValue(&decoded, "grpc-status").?);
}

test "zix http2 grpc frame: build, buildGrpcTrailer message past the scratch is BufferFull" {
    var buf: [HEADERS_FRAME_SCRATCH]u8 = undefined;
    const long_message: [frame.HPACK_ENCODE_SCRATCH]u8 = @splat('~');

    try std.testing.expectError(
        Error.ZixHttp2_GrpcBuild_BufferFull,
        buildGrpcTrailer(&buf, 1, 13, &long_message),
    );
}

test "zix http2 grpc frame: build, buildGrpcError carries status 200 and content-type" {
    var buf: [HEADERS_FRAME_SCRATCH]u8 = undefined;
    var scratch: [256]u8 = undefined;

    const len = try buildGrpcError(&buf, 1, 3, "");
    const decoded = try testDecode(&buf, len, &scratch);

    try std.testing.expectEqualStrings("200", testValue(&decoded, ":status").?);
    try std.testing.expectEqualStrings(
        reply_block.GRPC_CONTENT_TYPE,
        testValue(&decoded, "content-type").?,
    );
}

test "zix http2 grpc frame: build, buildGrpcError ends the stream with the status" {
    var buf: [HEADERS_FRAME_SCRATCH]u8 = undefined;
    var scratch: [256]u8 = undefined;

    const len = try buildGrpcError(&buf, 1, 12, "no route");
    const decoded = try testDecode(&buf, len, &scratch);

    try std.testing.expectEqual(FLAGS_TRAILER, decoded.header.flags);
    try std.testing.expectEqualStrings("12", testValue(&decoded, "grpc-status").?);
    try std.testing.expectEqualStrings("no route", testValue(&decoded, "grpc-message").?);
}

test "zix http2 grpc frame: build, buildGrpcError out too small is BufferFull" {
    var buf: [frame.FRAME_HEADER_LEN]u8 = undefined;

    try std.testing.expectError(
        Error.ZixHttp2_GrpcBuild_BufferFull,
        buildGrpcError(&buf, 1, 3, ""),
    );
}

