//! ZIX Http2 Grpc mux mux_dispatch
//!
//! ### file: src/zix/tcp/http2/grpc/mux/mux_dispatch.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Run a finished gRPC stream on the mux worker, staging the reply into the
//! connection's reply stage.
//!
//! ### note:
//!
//! The worker owns the connection, so every call runs inline: no task, no
//! write lock. A server-streaming handler runs on the event loop and must
//! stay bounded.
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
const deadline = @import("../deadline.zig");
const encoding = @import("../encoding.zig");
const frame = @import("../../frame.zig");
const handler = @import("../handler.zig");
const path = @import("../path.zig");
const router = @import("../router.zig");
const stage_frame = @import("stage_frame.zig");
const stream_body = @import("../../stream_body.zig");
const tcp_cork = @import("tcp_cork.zig");
const Context = @import("../Context.zig");
const MuxConn = @import("MuxConn.zig");
const Request = @import("../Request.zig");
const Stream = @import("../Stream.zig");

// --------------------------------------------------------- //
// Public:

/// Run one finished stream inline. A server-streaming route packs its
/// messages into shared DATA frames and runs under TCP_CORK.
///
/// Param:
/// RouterType - type (a Router, carrying route_slice and dispatch)
/// conn - *MuxConn (the connection owning the stream)
/// stream - *const Stream (the finished stream)
///
/// Return:
/// - void
pub fn dispatch(comptime RouterType: type, conn: *MuxConn, stream: *const Stream) void {
    const headers = stream.headerList();
    const call_path = path.headerPath(headers);
    const is_streaming = router.routeIsStreaming(RouterType.route_slice, call_path);
    const started = handler.rpcStart(conn.io, conn.opts.logger);

    var decomp: ?[]u8 = null;
    defer if (decomp) |buf| std.heap.smp_allocator.free(buf);

    const body = encoding.maybeDecompressBody(
        stream.bodyBytes(),
        headers,
        conn.opts.max_body,
        &decomp,
    );

    // Unary keeps one DATA frame per message, so it gets no coalesce buffer.
    var coal_buf: [Context.STREAM_COALESCE_CAP]u8 = undefined;

    var arena_buf: [Context.CTX_ARENA_BYTES]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);

    var ctx = Context.init(conn.io, fba.allocator(), conn.fd, stream.id, body);
    ctx.path = call_path;
    ctx.deadline = deadline.computeDeadline(conn.io, conn.opts.handler_timeout_ms, headers);
    ctx._out = &conn.stage;
    ctx._resp_gzip = conn.opts.compress and encoding.headersAcceptGzip(headers);
    ctx._coal = if (is_streaming) &coal_buf else null;

    var req: Request = .{
        .path = call_path,
        .headers = headers,
        ._ctx = &ctx,
    };

    if (is_streaming) _ = tcp_cork.set(conn.fd, true);
    handler.invoke(RouterType.dispatch, &req, &ctx);
    if (is_streaming) _ = tcp_cork.set(conn.fd, false);

    handler.writeRpcRecord(conn.opts.logger, started, &ctx, call_path, stream.body_len);
}

/// Dispatch a stream whose END_STREAM arrived, unless its body is short of
/// (or past) the content-length it declared. Such a stream is reset with
/// PROTOCOL_ERROR (RFC 9113 section 8.1.1). The caller frees the slot either way.
///
/// Param:
/// RouterType - type (a Router, carrying route_slice and dispatch)
/// conn - *MuxConn (the connection owning the stream)
/// stream - *const Stream (the finished stream)
///
/// Return:
/// - void
pub fn dispatchWhole(comptime RouterType: type, conn: *MuxConn, stream: *const Stream) void {
    if (!stream_body.isWhole(stream.headerList(), stream.body_len)) {
        stage_frame.rstStream(&conn.stage, stream.id, frame.ERR_PROTOCOL_ERROR);

        return;
    }

    dispatch(RouterType, conn, stream);
}

/// Stage a GOAWAY for a peer that hangs up part way through a request. A
/// connection with no request in flight closes without a byte.
///
/// Param:
/// conn - *MuxConn (the connection whose peer just hung up)
///
/// Return:
/// - bool (true when a GOAWAY was staged)
pub fn hangupGoaway(conn: *MuxConn) bool {
    if (!conn.requestInFlight()) return false;

    stage_frame.goaway(&conn.stage, conn.last_stream_id, frame.ERR_PROTOCOL_ERROR);

    return true;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const prefix = @import("../frame/prefix.zig");
const Response = @import("../Response.zig");
const ServeOpts = @import("../ServeOpts.zig");

const TEST_OPTS: ServeOpts = .{
    .max_streams = 4,
    .max_body = 1024,
    .max_header_scratch = 256,
};

/// A descriptor nothing is written to: every reply fits the stage.
const UNUSED_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

threadlocal var tl_unary_calls: usize = 0;
threadlocal var tl_unary_body_len: usize = 0;
threadlocal var tl_streaming_calls: usize = 0;

fn unaryHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    tl_unary_calls += 1;

    const msg = req.recvMessage() orelse "";
    tl_unary_body_len = msg.len;

    try res.sendMessage("application/grpc", msg);
    try res.finish(.OK, "");
}

fn streamingHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    tl_streaming_calls += 1;

    try res.sendMessage("application/grpc", "one");
    try res.sendMessage("application/grpc", "two");
    try res.finish(.OK, "");
}

const TestRouter = router.Router(&[_]router.Route{
    .{
        .path = "/svc.Svc/Unary",
        .handler = unaryHandler,
    },
    .{
        .path = "/svc.Svc/Stream",
        .handler = streamingHandler,
        .is_server_streaming = true,
    },
});

/// Claim a slot and fill it as a finished stream.
fn finishedStream(
    conn: *MuxConn,
    call_path: []const u8,
    content_length: []const u8,
    body: []const u8,
) *Stream {
    const slot = conn.claimSlot(1).?;
    const stream = conn.streams[slot];

    stream.headers[0] = .{
        .name = ":path",
        .value = call_path,
    };
    stream.headers[1] = .{
        .name = "content-length",
        .value = content_length,
    };
    stream.header_count = 2;
    _ = stream.appendBody(body);
    stream.end_stream = true;

    return stream;
}

/// Count the staged frames of one type.
fn stagedFrames(conn: *const MuxConn, frame_type: u8) usize {
    const staged = conn.stage.buf[0..conn.stage.len];

    var seen: usize = 0;
    var pos: usize = 0;
    while (pos + frame.FRAME_HEADER_LEN <= staged.len) {
        const header = frame.parseFrameHeader(staged[pos..][0..frame.FRAME_HEADER_LEN]);
        pos += frame.FRAME_HEADER_LEN + header.length;

        if (header.frame_type == frame_type) seen += 1;
    }

    return seen;
}

test "zix http2 grpc mux: mux_dispatch, dispatch stages a unary reply" {
    const conn = try MuxConn.init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    var body: [9]u8 = undefined;
    prefix.writeGrpcPrefix(body[0..prefix.PREFIX_LEN], false, 4);
    @memcpy(body[prefix.PREFIX_LEN..], "ping");
    const stream = finishedStream(conn, "/svc.Svc/Unary", "9", &body);

    tl_unary_calls = 0;
    dispatch(TestRouter, conn, stream);

    const staged = conn.stage.buf[0..conn.stage.len];

    try std.testing.expectEqual(@as(usize, 1), tl_unary_calls);
    try std.testing.expect(std.mem.indexOf(u8, staged, "ping") != null);
}

test "zix http2 grpc mux: mux_dispatch, a streaming reply packs messages in one DATA" {
    const conn = try MuxConn.init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const stream = finishedStream(conn, "/svc.Svc/Stream", "0", "");

    tl_streaming_calls = 0;
    dispatch(TestRouter, conn, stream);

    try std.testing.expectEqual(@as(usize, 1), tl_streaming_calls);
    try std.testing.expectEqual(@as(usize, 1), stagedFrames(conn, frame.FRAME_TYPE_DATA));
}

test "zix http2 grpc mux: mux_dispatch, dispatchWhole resets a short body" {
    const conn = try MuxConn.init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const short: [40]u8 = @splat('x');
    const stream = finishedStream(conn, "/svc.Svc/Unary", "100", &short);

    tl_unary_calls = 0;
    dispatchWhole(TestRouter, conn, stream);

    try std.testing.expectEqual(@as(usize, 0), tl_unary_calls);
    try std.testing.expectEqual(@as(usize, 1), stagedFrames(conn, frame.FRAME_TYPE_RST_STREAM));
}

test "zix http2 grpc mux: mux_dispatch, dispatchWhole resets a body past its content-length" {
    const conn = try MuxConn.init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const overlong: [40]u8 = @splat('x');
    const stream = finishedStream(conn, "/svc.Svc/Unary", "10", &overlong);

    tl_unary_calls = 0;
    dispatchWhole(TestRouter, conn, stream);

    try std.testing.expectEqual(@as(usize, 0), tl_unary_calls);
    try std.testing.expectEqual(@as(usize, 1), stagedFrames(conn, frame.FRAME_TYPE_RST_STREAM));
}

test "zix http2 grpc mux: mux_dispatch, dispatchWhole serves a body that matches" {
    const conn = try MuxConn.init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    const whole = [_]u8{ 0, 0, 0, 0, 4, 'p', 'i', 'n', 'g' };
    const stream = finishedStream(conn, "/svc.Svc/Unary", "9", &whole);

    tl_unary_calls = 0;
    tl_unary_body_len = 0;
    dispatchWhole(TestRouter, conn, stream);

    try std.testing.expectEqual(@as(usize, 1), tl_unary_calls);
    try std.testing.expectEqual(@as(usize, 4), tl_unary_body_len);
    try std.testing.expectEqual(@as(usize, 0), stagedFrames(conn, frame.FRAME_TYPE_RST_STREAM));
}

test "zix http2 grpc mux: mux_dispatch, hangupGoaway stages a GOAWAY mid-request" {
    const conn = try MuxConn.init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    _ = conn.claimSlot(1).?;
    conn.last_stream_id = 1;

    try std.testing.expect(hangupGoaway(conn));
    try std.testing.expectEqual(@as(usize, 1), stagedFrames(conn, frame.FRAME_TYPE_GOAWAY));
}

test "zix http2 grpc mux: mux_dispatch, hangupGoaway on an idle connection stages nothing" {
    const conn = try MuxConn.init(UNUSED_FD, TEST_OPTS, std.testing.io);
    defer conn.deinit();

    try std.testing.expect(!hangupGoaway(conn));
    try std.testing.expectEqual(@as(usize, 0), conn.stage.len);
}

