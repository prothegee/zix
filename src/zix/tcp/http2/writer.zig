//! ZIX Http2 writer
//!
//! ### file: src/zix/tcp/http2/writer.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Bytes to an HTTP/2 connection: direct writes and frame header writes.
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
const frame = @import("frame.zig");
const FrameHeader = @import("FrameHeader.zig");
const response_block = @import("hpack/response_block.zig");

// --------------------------------------------------------- //
// Private:

/// Send stage: HEADERS frame header + HPACK block + DATA frame header + a body
/// up to SEND_STAGE_BODY_MAX.
const SEND_STAGE_SIZE: usize =
    frame.FRAME_HEADER_LEN +
    frame.HPACK_ENCODE_SCRATCH +
    frame.FRAME_HEADER_LEN +
    frame.SEND_STAGE_BODY_MAX;

const Inner = Error || response_block.Error;

fn innerError(err: Inner) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixHttp2_ResponseBlock_UnexpectedEOF => Error.ZixHttp2_Writer_UnexpectedEOF,
        error.ZixHttp2_ResponseBlock_Overflow => Error.ZixHttp2_Writer_Overflow,
        error.ZixHttp2_ResponseBlock_BufferFull => Error.ZixHttp2_Writer_BufferFull,
        error.ZixHttp2_Writer_BrokenPipe => Error.ZixHttp2_Writer_BrokenPipe,
        error.ZixHttp2_Writer_UnexpectedEOF => Error.ZixHttp2_Writer_UnexpectedEOF,
        error.ZixHttp2_Writer_Overflow => Error.ZixHttp2_Writer_Overflow,
        error.ZixHttp2_Writer_BufferFull => Error.ZixHttp2_Writer_BufferFull,
    };
}

/// Wait until a non-blocking fd can take more bytes.
fn waitWritable(fd: std.posix.fd_t) Error!void {
    var pfd = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.OUT,
        .revents = 0,
    }};

    _ = std.posix.poll(&pfd, -1) catch |err| switch (err) {
        else => return Error.ZixHttp2_Writer_BrokenPipe,
    };
}

/// Write a head + payload pair in one vectored syscall, retrying partial writes.
fn writevAllDirectFD(fd: std.posix.fd_t, head: []const u8, payload: []const u8) Error!void {
    var iovs = [2]std.posix.iovec_const{
        .{
            .base = head.ptr,
            .len = head.len,
        },
        .{
            .base = payload.ptr,
            .len = payload.len,
        },
    };
    var iov_index: usize = 0;

    while (iov_index < iovs.len) {
        const remaining = iovs[iov_index..];
        const rc = std.posix.system.writev(fd, remaining.ptr, @intCast(remaining.len));
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                var accepted: usize = @intCast(rc);
                if (accepted == 0) return Error.ZixHttp2_Writer_BrokenPipe;

                while (iov_index < iovs.len and accepted >= iovs[iov_index].len) {
                    accepted -= iovs[iov_index].len;
                    iov_index += 1;
                }

                if (iov_index < iovs.len and accepted > 0) {
                    iovs[iov_index].base += accepted;
                    iovs[iov_index].len -= accepted;
                }
            },
            .INTR => continue,
            .AGAIN => try waitWritable(fd),
            else => return Error.ZixHttp2_Writer_BrokenPipe,
        }
    }
}

/// Write a frame head + payload pair and mark the stream answered.
fn writePairFD(fd: std.posix.fd_t, head: []const u8, payload: []const u8) Error!void {
    markResponded();

    return writevAllDirectFD(fd, head, payload);
}

fn sendResponseInner(
    fd: std.posix.fd_t,
    stream_id: u31,
    status: u16,
    content_type: []const u8,
    content_encoding: []const u8,
    body: []const u8,
) Inner!void {
    var stage: [SEND_STAGE_SIZE]u8 = undefined;

    const content_length: ?u64 = if (body.len > 0) body.len else null;
    const block_len = try response_block.respHeaderBlock(
        stage[frame.FRAME_HEADER_LEN..][0..frame.HPACK_ENCODE_SCRATCH],
        status,
        content_type,
        content_encoding,
        content_length,
    );
    const headers_flags: u8 = if (body.len == 0)
        frame.FLAG_END_STREAM | frame.FLAG_END_HEADERS
    else
        frame.FLAG_END_HEADERS;

    frame.encodeFrameHeader(stage[0..frame.FRAME_HEADER_LEN], .{
        .length = @intCast(block_len),
        .frame_type = frame.FRAME_TYPE_HEADERS,
        .flags = headers_flags,
        .stream_id = stream_id,
    });
    var staged: usize = frame.FRAME_HEADER_LEN + block_len;

    if (body.len == 0) return writeAllFD(fd, stage[0..staged]);

    if (body.len <= frame.SEND_STAGE_BODY_MAX) {
        frame.encodeFrameHeader(stage[staged..][0..frame.FRAME_HEADER_LEN], .{
            .length = @intCast(body.len),
            .frame_type = frame.FRAME_TYPE_DATA,
            .flags = frame.FLAG_END_STREAM,
            .stream_id = stream_id,
        });
        staged += frame.FRAME_HEADER_LEN;
        @memcpy(stage[staged..][0..body.len], body);
        staged += body.len;

        return writeAllFD(fd, stage[0..staged]);
    }

    // a DATA frame past the peer max frame size is a FRAME_SIZE_ERROR, so
    // split the body. The last chunk carries END_STREAM.
    var offset: usize = 0;
    while (offset < body.len) {
        const chunk_len = @min(body.len - offset, frame.DEFAULT_MAX_FRAME_SIZE);
        const is_last = offset + chunk_len == body.len;
        const data_header: FrameHeader = .{
            .length = @intCast(chunk_len),
            .frame_type = frame.FRAME_TYPE_DATA,
            .flags = if (is_last) frame.FLAG_END_STREAM else 0,
            .stream_id = stream_id,
        };
        const chunk = body[offset..][0..chunk_len];

        if (offset == 0) {
            // the HEADERS frame and the first DATA header share one head
            frame.encodeFrameHeader(stage[staged..][0..frame.FRAME_HEADER_LEN], data_header);
            try writePairFD(fd, stage[0 .. staged + frame.FRAME_HEADER_LEN], chunk);
        } else {
            var chunk_head: [frame.FRAME_HEADER_LEN]u8 = undefined;
            frame.encodeFrameHeader(&chunk_head, data_header);
            try writePairFD(fd, &chunk_head, chunk);
        }

        offset += chunk_len;
    }
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 writer error
pub const Error = error {
    ZixHttp2_Writer_BrokenPipe,
    ZixHttp2_Writer_UnexpectedEOF,
    ZixHttp2_Writer_Overflow,
    ZixHttp2_Writer_BufferFull,
};

/// Whether frames for the stream in flight have already left for the peer.
///
/// Note:
/// - The `Response` builder tracks the same thing, but a handler may answer
///   through the fd writers instead, which hold no `Response`. Without this the
///   engine reads such a handler as never having answered and completes it a
///   second time.
/// - A threadlocal because the fd writers take an fd and nothing else. Cleared
///   by the core before each handler call.
pub threadlocal var tl_responded: bool = false;

/// Record that frames for the stream in flight left for the peer.
pub fn markResponded() void {
    tl_responded = true;
}

/// Whether the stream in flight has been answered through the fd writers.
///
/// Return:
/// - bool
pub fn respondedFD() bool {
    return tl_responded;
}

/// Write all of data to fd, retrying partial writes.
///
/// Note:
/// - A non-blocking socket with a full send buffer waits until writable, then
///   retries. A blocking socket never takes that branch.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// data - []const u8 (bytes to send, written in full on success)
///
/// Return:
/// - void when every byte was accepted
/// - error.ZixHttp2_Writer_BrokenPipe on a write error or a peer that went away
pub fn writeAllDirectFD(fd: std.posix.fd_t, data: []const u8) Error!void {
    var rem = data;

    while (rem.len > 0) {
        const rc = std.posix.system.write(fd, rem.ptr, rem.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {
                const written: usize = @intCast(rc);
                if (written == 0) return Error.ZixHttp2_Writer_BrokenPipe;

                rem = rem[written..];
            },
            .INTR => continue,
            .AGAIN => try waitWritable(fd),
            else => return Error.ZixHttp2_Writer_BrokenPipe,
        }
    }
}

/// Write frame bytes to fd, the canonical write behind every frame sender.
///
/// Note:
/// - Marks the stream in flight as answered, so a handler that writes here
///   directly is not completed a second time.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// data - []const u8 (bytes to send)
///
/// Return:
/// - void when every byte was accepted
/// - error.ZixHttp2_Writer_BrokenPipe on a write error
pub fn writeAllFD(fd: std.posix.fd_t, data: []const u8) Error!void {
    markResponded();

    return writeAllDirectFD(fd, data);
}

/// Encode one frame header and write it to fd.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// header - FrameHeader (the header to send)
///
/// Return:
/// - void when the 9 bytes were accepted
/// - error.ZixHttp2_Writer_BrokenPipe on a write error
pub fn writeFrameHeaderFD(fd: std.posix.fd_t, header: FrameHeader) Error!void {
    var buf: [frame.FRAME_HEADER_LEN]u8 = undefined;
    frame.encodeFrameHeader(&buf, header);

    return writeAllFD(fd, &buf);
}

/// Send a complete response: HEADERS, then DATA when there is a body.
///
/// Note:
/// - END_STREAM rides the last DATA frame, or HEADERS when the body is empty.
/// - Not for multi-step responses such as gRPC trailers. Use
///   writeFrameHeaderFD and writeAllFD for those.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// stream_id - u31 (the stream to answer)
/// status - u16 (response status)
/// content_type - []const u8 (empty omits the header)
/// body - []const u8 (response body, may be empty)
///
/// Return:
/// - void when the response was sent
/// - error.ZixHttp2_Writer_BufferFull when the header block does not fit
/// - error.ZixHttp2_Writer_BrokenPipe on a write error
pub fn sendResponseFD(
    fd: std.posix.fd_t,
    stream_id: u31,
    status: u16,
    content_type: []const u8,
    body: []const u8,
) Error!void {
    return sendResponseEncodedFD(fd, stream_id, status, content_type, "", body);
}

/// sendResponseFD plus a content-encoding header, for a precompressed body.
///
/// Note:
/// - An empty content_encoding omits the header.
/// - The send is not flow controlled. For a body that may pass the peer
///   window, use the mux stream sender, which waits for WINDOW_UPDATE.
/// - A body at or under SEND_STAGE_BODY_MAX leaves as one staged write. A
///   larger body leaves as one vectored write per DATA frame, without a copy.
///
/// Param:
/// fd - std.posix.fd_t (the connection)
/// stream_id - u31 (the stream to answer)
/// status - u16 (response status)
/// content_type - []const u8 (empty omits the header)
/// content_encoding - []const u8 (empty omits the header)
/// body - []const u8 (response body, may be empty)
///
/// Return:
/// - void when the response was sent
/// - error.ZixHttp2_Writer_BufferFull when the header block does not fit
/// - error.ZixHttp2_Writer_BrokenPipe on a write error
pub fn sendResponseEncodedFD(
    fd: std.posix.fd_t,
    stream_id: u31,
    status: u16,
    content_type: []const u8,
    content_encoding: []const u8,
    body: []const u8,
) Error!void {
    return sendResponseInner(
        fd,
        stream_id,
        status,
        content_type,
        content_encoding,
        body,
    ) catch |err| innerError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

const TestFrames = struct {
    data_frames: usize = 0,
    data_bytes: usize = 0,
    last_data_flags: u8 = 0,
    headers_flags: u8 = 0,
};

/// Read one end until the peer closes it and return how many bytes arrived.
///
/// Note:
/// - Runs on its own thread while the other end sends. A send past the socket
///   buffer only finishes while someone drains it.
fn testDrain(fd: std.posix.fd_t, buf: []u8, total: *usize) void {
    var filled: usize = 0;

    while (filled < buf.len) {
        const got = std.posix.read(fd, buf[filled..]) catch |err| switch (err) {
            else => break,
        };
        if (got == 0) break;

        filled += got;
    }

    total.* = filled;
}

/// Send a response on a socket pair and collect the frames that arrived.
fn testSendAndCollect(body: []const u8, buf: []u8) !TestFrames {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    var total: usize = 0;
    const drain = try std.Thread.spawn(.{}, testDrain, .{
        fds[0],
        buf,
        &total,
    });

    sendResponseFD(fds[1], 1, 200, "text/plain", body) catch |err| {
        _ = std.posix.system.close(fds[1]);
        drain.join();

        return err;
    };
    _ = std.posix.system.close(fds[1]);
    drain.join();

    var frames: TestFrames = .{};
    var offset: usize = 0;
    while (offset + frame.FRAME_HEADER_LEN <= total) {
        const header = frame.parseFrameHeader(buf[offset..][0..frame.FRAME_HEADER_LEN]);
        offset += frame.FRAME_HEADER_LEN;

        if (header.frame_type == frame.FRAME_TYPE_HEADERS) frames.headers_flags = header.flags;
        if (header.frame_type == frame.FRAME_TYPE_DATA) {
            frames.data_frames += 1;
            frames.data_bytes += header.length;
            frames.last_data_flags = header.flags;
        }

        offset += header.length;
    }

    return frames;
}

test "zix http2: writer, writeAllFD delivers data" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try writeAllFD(fds[1], "frame");

    var buf: [8]u8 = undefined;
    const got = try std.posix.read(fds[0], &buf);

    try std.testing.expectEqualStrings("frame", buf[0..got]);
}

test "zix http2: writer, writeAllFD marks the stream answered" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    tl_responded = false;
    defer tl_responded = false;

    try writeAllFD(fds[1], "x");

    try std.testing.expect(respondedFD());
}

test "zix http2: writer, writeAllDirectFD leaves the answered mark alone" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    tl_responded = false;

    try writeAllDirectFD(fds[1], "x");

    try std.testing.expect(!respondedFD());
}

test "zix http2: writer, writeAllFD with empty data writes nothing" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    try writeAllFD(fds[1], "");
    try writeAllFD(fds[1], "z");

    var buf: [4]u8 = undefined;
    const got = try std.posix.read(fds[0], &buf);

    try std.testing.expectEqualStrings("z", buf[0..got]);
}

test "zix http2: writer, writeAllDirectFD to a closed peer is BrokenPipe" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const result = writeAllDirectFD(fds[1], "gone");

    try std.testing.expectError(Error.ZixHttp2_Writer_BrokenPipe, result);
}

test "zix http2: writer, writeFrameHeaderFD sends 9 encoded bytes" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const header: FrameHeader = .{
        .length = 8,
        .frame_type = frame.FRAME_TYPE_PING,
        .flags = frame.FLAG_ACK,
        .stream_id = 0,
    };
    try writeFrameHeaderFD(fds[1], header);

    var buf: [frame.FRAME_HEADER_LEN]u8 = undefined;
    const got = try std.posix.read(fds[0], &buf);

    try std.testing.expectEqual(frame.FRAME_HEADER_LEN, got);
    try std.testing.expectEqual(header, frame.parseFrameHeader(&buf));
}

test "zix http2: writer, sendResponseFD bodyless sets END_STREAM on HEADERS" {
    var buf: [1024]u8 = undefined;

    const frames = try testSendAndCollect("", &buf);

    try std.testing.expectEqual(@as(usize, 0), frames.data_frames);
    try std.testing.expect((frames.headers_flags & frame.FLAG_END_STREAM) != 0);
    try std.testing.expect((frames.headers_flags & frame.FLAG_END_HEADERS) != 0);
}

test "zix http2: writer, sendResponseFD small body is one DATA frame" {
    var buf: [1024]u8 = undefined;

    const frames = try testSendAndCollect("pong", &buf);

    try std.testing.expectEqual(@as(usize, 1), frames.data_frames);
    try std.testing.expectEqual(@as(usize, 4), frames.data_bytes);
    try std.testing.expect((frames.last_data_flags & frame.FLAG_END_STREAM) != 0);
    try std.testing.expect((frames.headers_flags & frame.FLAG_END_STREAM) == 0);
}

test "zix http2: writer, sendResponseFD body at SEND_STAGE_BODY_MAX is one DATA frame" {
    var buf: [8 * 1024]u8 = undefined;
    const body: [frame.SEND_STAGE_BODY_MAX]u8 = @splat('x');

    const frames = try testSendAndCollect(&body, &buf);

    try std.testing.expectEqual(@as(usize, 1), frames.data_frames);
    try std.testing.expectEqual(body.len, frames.data_bytes);
}

test "zix http2: writer, sendResponseFD body past the stage takes the vectored path" {
    var buf: [16 * 1024]u8 = undefined;
    const body: [8000]u8 = @splat('b');

    const frames = try testSendAndCollect(&body, &buf);

    try std.testing.expectEqual(@as(usize, 1), frames.data_frames);
    try std.testing.expectEqual(@as(usize, 8000), frames.data_bytes);
    try std.testing.expect((frames.last_data_flags & frame.FLAG_END_STREAM) != 0);
}

test "zix http2: writer, sendResponseFD body past the max frame size is split" {
    var buf: [64 * 1024]u8 = undefined;
    const body: [40000]u8 = @splat('a');

    const frames = try testSendAndCollect(&body, &buf);

    try std.testing.expectEqual(@as(usize, 3), frames.data_frames);
    try std.testing.expectEqual(@as(usize, 40000), frames.data_bytes);
    try std.testing.expect((frames.last_data_flags & frame.FLAG_END_STREAM) != 0);
}

test "zix http2: writer, sendResponseFD marks the stream answered" {
    var buf: [1024]u8 = undefined;
    tl_responded = false;
    defer tl_responded = false;

    _ = try testSendAndCollect("ok", &buf);

    try std.testing.expect(respondedFD());
}

test "zix http2: writer, sendResponseFD content-type past the block scratch is BufferFull" {
    const long_type: [frame.HPACK_ENCODE_SCRATCH]u8 = @splat('t');

    const result = sendResponseFD(-1, 1, 200, &long_type, "x");

    try std.testing.expectError(Error.ZixHttp2_Writer_BufferFull, result);
}

test "zix http2: writer, sendResponseEncodedFD to a closed peer is BrokenPipe" {
    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const result = sendResponseEncodedFD(fds[1], 1, 200, "text/plain", "br", "zz");

    try std.testing.expectError(Error.ZixHttp2_Writer_BrokenPipe, result);
}

