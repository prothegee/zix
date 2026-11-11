//! ZIX Http2 Grpc stream dispatch
//!
//! ### file: src/zix/tcp/http2/grpc/stream_dispatch.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Hand a finished gRPC stream to its handler: inline for a unary route, on
//! its own task for a server-streaming route.
//!
//! ### note:
//!
//! A stream whose body disagrees with its content-length is reset with
//! PROTOCOL_ERROR (RFC9113 8.1.1) and never reaches a handler.
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
const deadline = @import("deadline.zig");
const encoding = @import("encoding.zig");
const frame = @import("../frame.zig");
const handler = @import("handler.zig");
const path = @import("path.zig");
const router = @import("router.zig");
const send_best_effort = @import("../send_best_effort.zig");
const stream_body = @import("../stream_body.zig");
const ConnMutex = @import("ConnMutex.zig");
const Context = @import("Context.zig");
const DispatchTask = @import("DispatchTask.zig");
const ReplyStage = @import("ReplyStage.zig");
const Request = @import("Request.zig");
const ServeOpts = @import("ServeOpts.zig");
const Stream = @import("Stream.zig");

// --------------------------------------------------------- //
// Private:

/// Cork buffer for one inline reply, in bytes.
const REPLY_STAGE_SCRATCH: usize = 4096;

// --------------------------------------------------------- //
// Public:

/// Run a unary call on the connection thread. HEADERS, DATA, and the trailer
/// leave in one write after the handler returns.
///
/// Note:
/// - The write lock is held across the reply only while a streaming task may
///   be writing on the same connection.
///
/// Param:
/// handler_fn - handler.HandlerFn (the router dispatch)
/// stream - *const Stream (the finished stream)
/// fd - std.posix.fd_t (the connection)
/// opts - ServeOpts (serve knobs carried to the call)
/// conn_mutex - *ConnMutex (the connection write lock)
/// io - std.Io (the worker io, carried on Context)
///
/// Return:
/// - void
pub fn dispatchInline(
    handler_fn: handler.HandlerFn,
    stream: *const Stream,
    fd: std.posix.fd_t,
    opts: ServeOpts,
    conn_mutex: *ConnMutex,
    io: std.Io,
) void {
    const headers = stream.headerList();
    const call_path = path.headerPath(headers);
    const started = handler.rpcStart(io, opts.logger);

    var decomp: ?[]u8 = null;
    defer if (decomp) |buf| std.heap.smp_allocator.free(buf);

    const body = encoding.maybeDecompressBody(
        stream.bodyBytes(),
        headers,
        opts.max_body,
        &decomp,
    );

    var stage_buf: [REPLY_STAGE_SCRATCH]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = fd,
        .buf = &stage_buf,
    };

    var arena_buf: [Context.CTX_ARENA_BYTES]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_buf);

    var ctx = Context.init(io, fba.allocator(), fd, stream.id, body);
    ctx.path = call_path;
    ctx.deadline = deadline.computeDeadline(io, opts.handler_timeout_ms, headers);
    ctx._out = &stage;
    ctx._resp_gzip = opts.compress and encoding.headersAcceptGzip(headers);

    var req: Request = .{
        .path = call_path,
        .headers = headers,
        ._ctx = &ctx,
    };

    const need_mutex = conn_mutex.streamingActive();

    if (need_mutex) conn_mutex.lock();
    handler.invoke(handler_fn, &req, &ctx);
    stage.flush();
    if (need_mutex) conn_mutex.unlock();

    handler.writeRpcRecord(opts.logger, started, &ctx, call_path, stream.body_len);
}

/// Run a finished stream inline or on a task, by its route.
///
/// Param:
/// RouterType - type (a Router, carrying route_slice and dispatch)
/// stream - *const Stream (the finished stream)
/// fd - std.posix.fd_t (the connection)
/// opts - ServeOpts (serve knobs carried to the call)
/// conn_mutex - *ConnMutex (the connection write lock)
/// io - std.Io (the worker io, carried on Context)
///
/// Return:
/// - void
pub fn dispatchStream(
    comptime RouterType: type,
    stream: *const Stream,
    fd: std.posix.fd_t,
    opts: ServeOpts,
    conn_mutex: *ConnMutex,
    io: std.Io,
) void {
    const call_path = path.headerPath(stream.headerList());

    if (router.routeIsStreaming(RouterType.route_slice, call_path)) {
        DispatchTask.spawn(RouterType.dispatch, stream, fd, opts, conn_mutex, io);
    } else {
        dispatchInline(RouterType.dispatch, stream, fd, opts, conn_mutex, io);
    }
}

/// Dispatch a stream whose END_STREAM arrived, unless its body is short of
/// (or past) the content-length it declared. Such a stream is reset with
/// PROTOCOL_ERROR. The caller frees the slot either way.
///
/// Param:
/// RouterType - type (a Router, carrying route_slice and dispatch)
/// stream - *const Stream (the finished stream)
/// fd - std.posix.fd_t (the connection)
/// opts - ServeOpts (serve knobs carried to the call)
/// conn_mutex - *ConnMutex (the connection write lock)
/// io - std.Io (the worker io, carried on Context)
///
/// Return:
/// - void
pub fn dispatchWhole(
    comptime RouterType: type,
    stream: *const Stream,
    fd: std.posix.fd_t,
    opts: ServeOpts,
    conn_mutex: *ConnMutex,
    io: std.Io,
) void {
    if (!stream_body.isWhole(stream.headerList(), stream.body_len)) {
        conn_mutex.lock();
        defer conn_mutex.unlock();

        send_best_effort.rstStream(fd, stream.id, frame.ERR_PROTOCOL_ERROR);

        return;
    }

    dispatchStream(RouterType, stream, fd, opts, conn_mutex, io);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const pair = @import("../../../utils/socket/pair.zig");
const prefix = @import("frame/prefix.zig");
const Response = @import("Response.zig");

var unary_calls: std.atomic.Value(usize) = .init(0);
var streaming_calls: std.atomic.Value(usize) = .init(0);

fn unaryHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    _ = unary_calls.fetchAdd(1, .monotonic);

    const msg = req.recvMessage() orelse "";
    try res.sendMessage("application/grpc", msg);
    try res.finish(.OK, "");
}

fn streamingHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    _ = streaming_calls.fetchAdd(1, .monotonic);

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

fn isLinux() bool {
    if (comptime builtin.target.os.tag == .linux) return true;

    std.log.info("this test drives a Linux socket pair, test skipped", .{});

    return false;
}

/// A finished stream with a path, a content-length, and body bytes.
fn testStream(
    stream: *Stream,
    body: []u8,
    call_path: []const u8,
    content_length: []const u8,
    body_len: usize,
) void {
    stream.* = .{
        .body = body,
    };
    stream.open(1);
    stream.headers[0] = .{
        .name = ":path",
        .value = call_path,
    };
    stream.headers[1] = .{
        .name = "content-length",
        .value = content_length,
    };
    stream.header_count = 2;
    stream.body_len = body_len;
    stream.end_stream = true;
}

test "zix http2 grpc: stream_dispatch, dispatchInline answers in one reply" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var body: [9]u8 = undefined;
    prefix.writeGrpcPrefix(body[0..prefix.PREFIX_LEN], false, 4);
    @memcpy(body[prefix.PREFIX_LEN..], "ping");

    var stream: Stream = undefined;
    testStream(&stream, &body, "/svc.Svc/Unary", "9", body.len);

    const conn_mutex = try ConnMutex.create();
    defer conn_mutex.release();

    unary_calls.store(0, .monotonic);
    dispatchInline(TestRouter.dispatch, &stream, fds[1], .{}, conn_mutex, std.testing.io);

    var reply: [512]u8 = undefined;
    const got = try std.posix.read(fds[0], &reply);

    try std.testing.expectEqual(@as(usize, 1), unary_calls.load(.monotonic));
    try std.testing.expect(std.mem.indexOf(u8, reply[0..got], "ping") != null);
}

test "zix http2 grpc: stream_dispatch, dispatchWhole resets a short body" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var body: [40]u8 = @splat('x');
    var stream: Stream = undefined;
    testStream(&stream, &body, "/svc.Svc/Unary", "100", body.len);

    const conn_mutex = try ConnMutex.create();
    defer conn_mutex.release();

    unary_calls.store(0, .monotonic);
    dispatchWhole(TestRouter, &stream, fds[1], .{}, conn_mutex, std.testing.io);

    var reply: [64]u8 = undefined;
    const got = try std.posix.read(fds[0], &reply);
    const header = frame.parseFrameHeader(reply[0..frame.FRAME_HEADER_LEN]);
    const code = std.mem.readInt(u32, reply[frame.FRAME_HEADER_LEN..][0..4], .big);

    try std.testing.expectEqual(@as(usize, 0), unary_calls.load(.monotonic));
    try std.testing.expect(got >= frame.FRAME_HEADER_LEN + 4);
    try std.testing.expectEqual(frame.FRAME_TYPE_RST_STREAM, header.frame_type);
    try std.testing.expectEqual(frame.ERR_PROTOCOL_ERROR, code);
}

test "zix http2 grpc: stream_dispatch, dispatchWhole serves a whole body" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var body: [5]u8 = @splat(0);
    var stream: Stream = undefined;
    testStream(&stream, &body, "/svc.Svc/Unary", "5", body.len);

    const conn_mutex = try ConnMutex.create();
    defer conn_mutex.release();

    unary_calls.store(0, .monotonic);
    dispatchWhole(TestRouter, &stream, fds[1], .{}, conn_mutex, std.testing.io);

    try std.testing.expectEqual(@as(usize, 1), unary_calls.load(.monotonic));
}

test "zix http2 grpc: stream_dispatch, streaming route runs on a task" {
    if (!isLinux()) return;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    var body: [5]u8 = @splat(0);
    var stream: Stream = undefined;
    testStream(&stream, &body, "/svc.Svc/Stream", "5", body.len);

    const conn_mutex = try ConnMutex.create();
    defer conn_mutex.release();

    streaming_calls.store(0, .monotonic);
    dispatchStream(TestRouter, &stream, fds[1], .{}, conn_mutex, std.testing.io);

    var reply: [256]u8 = undefined;
    _ = try std.posix.read(fds[0], &reply);
    while (conn_mutex.streamingActive()) std.atomic.spinLoopHint();

    try std.testing.expectEqual(@as(usize, 1), streaming_calls.load(.monotonic));
}

