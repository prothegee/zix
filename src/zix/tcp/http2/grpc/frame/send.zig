//! ZIX Http2 Grpc frame send
//!
//! ### file: src/zix/tcp/http2/grpc/frame/send.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Send gRPC reply frames to a connection fd: initial HEADERS, one DATA
//! message, the trailer, and the trailers-only error.
//!
//! ### note:
//!
//! Every write goes through writer.writeAllFD, so the stream counts as
//! answered and a worker write hook still batches the frames.
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

const build = @import("build.zig");
const writer = @import("../../writer.zig");

// --------------------------------------------------------- //
// Private:

const Inner = Error || build.Error || writer.Error;

fn headersInner(fd: std.posix.fd_t, stream_id: u31, content_type: []const u8) Inner!void {
    var buf: [build.HEADERS_FRAME_SCRATCH]u8 = undefined;
    const len = try build.buildGrpcHeaders(&buf, stream_id, content_type);

    try writer.writeAllFD(fd, buf[0..len]);
}

fn dataInner(fd: std.posix.fd_t, stream_id: u31, message: []const u8) Inner!void {
    var head: [build.DATA_HEAD_LEN]u8 = undefined;
    _ = try build.buildGrpcDataHeader(&head, stream_id, message.len, false);

    try writer.writeAllFD(fd, &head);
    try writer.writeAllFD(fd, message);
}

fn trailerInner(
    fd: std.posix.fd_t,
    stream_id: u31,
    grpc_status: u8,
    grpc_message: []const u8,
) Inner!void {
    var buf: [build.HEADERS_FRAME_SCRATCH]u8 = undefined;
    const len = try build.buildGrpcTrailer(&buf, stream_id, grpc_status, grpc_message);

    try writer.writeAllFD(fd, buf[0..len]);
}

fn errorInner(
    fd: std.posix.fd_t,
    stream_id: u31,
    grpc_status: u8,
    grpc_message: []const u8,
) Inner!void {
    var buf: [build.HEADERS_FRAME_SCRATCH]u8 = undefined;
    const len = try build.buildGrpcError(&buf, stream_id, grpc_status, grpc_message);

    try writer.writeAllFD(fd, buf[0..len]);
}

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixHttp2_GrpcBuild_UnexpectedEOF => Error.ZixHttp2_GrpcSend_UnexpectedEOF,
        error.ZixHttp2_GrpcBuild_Overflow => Error.ZixHttp2_GrpcSend_Overflow,
        error.ZixHttp2_GrpcBuild_BufferFull => Error.ZixHttp2_GrpcSend_BufferFull,
        error.ZixHttp2_Writer_BrokenPipe => Error.ZixHttp2_GrpcSend_BrokenPipe,
        error.ZixHttp2_Writer_UnexpectedEOF => Error.ZixHttp2_GrpcSend_UnexpectedEOF,
        error.ZixHttp2_Writer_Overflow => Error.ZixHttp2_GrpcSend_Overflow,
        error.ZixHttp2_Writer_BufferFull => Error.ZixHttp2_GrpcSend_BufferFull,
        error.ZixHttp2_GrpcSend_BrokenPipe => Error.ZixHttp2_GrpcSend_BrokenPipe,
        error.ZixHttp2_GrpcSend_UnexpectedEOF => Error.ZixHttp2_GrpcSend_UnexpectedEOF,
        error.ZixHttp2_GrpcSend_Overflow => Error.ZixHttp2_GrpcSend_Overflow,
        error.ZixHttp2_GrpcSend_BufferFull => Error.ZixHttp2_GrpcSend_BufferFull,
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc frame send error
pub const Error = error {
    ZixHttp2_GrpcSend_BrokenPipe,
    ZixHttp2_GrpcSend_UnexpectedEOF,
    ZixHttp2_GrpcSend_Overflow,
    ZixHttp2_GrpcSend_BufferFull,
};

/// Send the initial response HEADERS (`:status 200`, content-type). No END_STREAM.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// stream_id - u31 (the stream to answer)
/// content_type - []const u8 (response content-type)
///
/// Return:
/// - void when the frame was sent
/// - error.ZixHttp2_GrpcSend_BufferFull when the header block does not fit
/// - error.ZixHttp2_GrpcSend_BrokenPipe on a write error
pub fn sendGrpcHeadersFD(
    fd: std.posix.fd_t,
    stream_id: u31,
    content_type: []const u8,
) Error!void {
    return headersInner(fd, stream_id, content_type) catch |err| innerError(err);
}

/// Send one DATA frame: the gRPC prefix, then the message. No END_STREAM.
///
/// Note:
/// - Not flow controlled and not split. The caller keeps the message within
///   the peer window and max frame size.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// stream_id - u31 (the stream to answer)
/// message - []const u8 (message payload, sent uncompressed)
///
/// Return:
/// - void when the frame was sent
/// - error.ZixHttp2_GrpcSend_Overflow when the message is past one frame
/// - error.ZixHttp2_GrpcSend_BrokenPipe on a write error
pub fn sendGrpcDataFD(fd: std.posix.fd_t, stream_id: u31, message: []const u8) Error!void {
    return dataInner(fd, stream_id, message) catch |err| innerError(err);
}

/// Send the trailer HEADERS (grpc-status, grpc-message). END_STREAM.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// stream_id - u31 (the stream to close)
/// grpc_status - u8 (gRPC status code)
/// grpc_message - []const u8 (status message, empty omits the header)
///
/// Return:
/// - void when the frame was sent
/// - error.ZixHttp2_GrpcSend_BufferFull when the header block does not fit
/// - error.ZixHttp2_GrpcSend_BrokenPipe on a write error
pub fn sendGrpcTrailerFD(
    fd: std.posix.fd_t,
    stream_id: u31,
    grpc_status: u8,
    grpc_message: []const u8,
) Error!void {
    return trailerInner(fd, stream_id, grpc_status, grpc_message) catch |err| {
        return innerError(err);
    };
}

/// Send a trailers-only error reply (no DATA frame). END_STREAM.
///
/// Note:
/// - Carries `:status 200` and the default content-type, as the gRPC spec asks.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// stream_id - u31 (the stream to close)
/// grpc_status - u8 (gRPC status code)
/// grpc_message - []const u8 (status message, empty omits the header)
///
/// Return:
/// - void when the frame was sent
/// - error.ZixHttp2_GrpcSend_BufferFull when the header block does not fit
/// - error.ZixHttp2_GrpcSend_BrokenPipe on a write error
pub fn sendGrpcErrorFD(
    fd: std.posix.fd_t,
    stream_id: u31,
    grpc_status: u8,
    grpc_message: []const u8,
) Error!void {
    return errorInner(fd, stream_id, grpc_status, grpc_message) catch |err| {
        return innerError(err);
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const frame = @import("../../frame.zig");
const prefix = @import("prefix.zig");
const reply_block = @import("reply_block.zig");
const pair = @import("../../../../utils/socket/pair.zig");
const HpackDecoder = @import("../../hpack/HpackDecoder.zig");
const Header = @import("../../hpack/Header.zig");

/// Read until want bytes arrived or the peer closed. Return the byte count.
fn testReadAtLeast(fd: std.posix.fd_t, buf: []u8, want: usize) !usize {
    var filled: usize = 0;

    while (filled < want) {
        const got = try std.posix.read(fd, buf[filled..]);
        if (got == 0) break;

        filled += got;
    }

    return filled;
}

/// Read one whole frame (header plus payload) into buf. Return the byte count.
fn testReadFrame(fd: std.posix.fd_t, buf: []u8) !usize {
    const filled = try testReadAtLeast(fd, buf, frame.FRAME_HEADER_LEN);
    const header = frame.parseFrameHeader(buf[0..frame.FRAME_HEADER_LEN]);
    const want = frame.FRAME_HEADER_LEN + header.length;
    if (filled >= want) return filled;

    return filled + try testReadAtLeast(fd, buf[filled..], want - filled);
}

/// Whether the HPACK block of the frame in buf holds name with value.
fn testHasHeader(buf: []const u8, name: []const u8, value: []const u8) !bool {
    const header = frame.parseFrameHeader(buf[0..frame.FRAME_HEADER_LEN]);
    const block = buf[frame.FRAME_HEADER_LEN..][0..header.length];

    var decoder = HpackDecoder.init();
    var headers: [8]Header = undefined;
    var scratch: [256]u8 = undefined;
    const count = try decoder.decode(block, &headers, &scratch);

    for (headers[0..count]) |entry| {
        const matched =
            std.mem.eql(u8, entry.name, name) and
            std.mem.eql(u8, entry.value, value);
        if (matched) return true;
    }

    return false;
}

test "zix http2 grpc frame: send, sendGrpcHeadersFD writes a HEADERS frame" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try sendGrpcHeadersFD(fds[1], 1, reply_block.GRPC_CONTENT_TYPE);

    var buf: [256]u8 = undefined;
    _ = try testReadFrame(fds[0], &buf);
    const header = frame.parseFrameHeader(buf[0..frame.FRAME_HEADER_LEN]);

    try std.testing.expectEqual(frame.FRAME_TYPE_HEADERS, header.frame_type);
    try std.testing.expectEqual(frame.FLAG_END_HEADERS, header.flags);
}

test "zix http2 grpc frame: send, sendGrpcDataFD writes prefix then message" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try sendGrpcDataFD(fds[1], 1, "hello");

    var buf: [64]u8 = undefined;
    const got = try testReadAtLeast(fds[0], &buf, build.DATA_HEAD_LEN + 5);
    const header = frame.parseFrameHeader(buf[0..frame.FRAME_HEADER_LEN]);
    const grpc_prefix = try prefix.readGrpcPrefix(buf[frame.FRAME_HEADER_LEN..got]);

    try std.testing.expectEqual(frame.FRAME_TYPE_DATA, header.frame_type);
    try std.testing.expectEqual(@as(u32, 5), grpc_prefix.msg_len);
    try std.testing.expectEqualStrings("hello", buf[build.DATA_HEAD_LEN..got]);
}

test "zix http2 grpc frame: send, sendGrpcDataFD empty message sends the head only" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try sendGrpcDataFD(fds[1], 1, "");

    var buf: [64]u8 = undefined;
    const got = try testReadFrame(fds[0], &buf);
    const header = frame.parseFrameHeader(buf[0..frame.FRAME_HEADER_LEN]);

    try std.testing.expectEqual(build.DATA_HEAD_LEN, got);
    try std.testing.expectEqual(@as(u24, prefix.PREFIX_LEN), header.length);
}

test "zix http2 grpc frame: send, sendGrpcTrailerFD ends the stream" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try sendGrpcTrailerFD(fds[1], 1, 0, "");

    var buf: [64]u8 = undefined;
    _ = try testReadFrame(fds[0], &buf);
    const header = frame.parseFrameHeader(buf[0..frame.FRAME_HEADER_LEN]);

    try std.testing.expectEqual(frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM, header.flags);
    try std.testing.expect(try testHasHeader(&buf, "grpc-status", "0"));
}

test "zix http2 grpc frame: send, sendGrpcErrorFD includes content-type header" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try sendGrpcErrorFD(fds[1], 1, 3, "");

    var buf: [256]u8 = undefined;
    _ = try testReadFrame(fds[0], &buf);
    const has_type = try testHasHeader(&buf, "content-type", reply_block.GRPC_CONTENT_TYPE);

    try std.testing.expect(has_type);
}

test "zix http2 grpc frame: send, sendGrpcErrorFD message past the scratch is BufferFull" {
    const long_message: [frame.HPACK_ENCODE_SCRATCH]u8 = @splat('~');

    try std.testing.expectError(
        Error.ZixHttp2_GrpcSend_BufferFull,
        sendGrpcErrorFD(-1, 1, 13, &long_message),
    );
}

test "zix http2 grpc frame: send, sendGrpcTrailerFD closed peer is BrokenPipe" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[1]);
    _ = std.posix.system.close(fds[0]);

    try std.testing.expectError(
        Error.ZixHttp2_GrpcSend_BrokenPipe,
        sendGrpcTrailerFD(fds[1], 1, 13, "boom"),
    );
}

