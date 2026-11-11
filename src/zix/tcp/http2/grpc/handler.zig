//! ZIX Http2 Grpc handler
//!
//! ### file: src/zix/tcp/http2/grpc/handler.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! gRPC handler contract, the one place a handler is invoked, and the rpc
//! log line per call.
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
const peer_addr = @import("../../../utils/peer_address.zig");
const Context = @import("Context.zig");
const Logger = @import("../../../logger/Logger.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");

const Timestamp = std.Io.Clock.Timestamp;

// --------------------------------------------------------- //
// Private:

/// grpc-message for a call the handler failed without closing. Says nothing
/// about the fault: the caller is not the audience for a server-side error.
const HANDLER_ERROR_MESSAGE: []const u8 = "handler error";

// --------------------------------------------------------- //
// Public:

/// Handler signature: the request, response, context trio. Called once per
/// call (one h2 stream).
///
/// Note:
/// - The handler closes the call with res.finish before returning.
/// - A returned error closes a call still open with INTERNAL.
pub const HandlerFn = *const fn (
    req: *Request,
    res: *Response,
    ctx: *Context,
) anyerror!void;

/// Close a call whose handler returned an error, so the caller is never left
/// waiting on a stream with no status. A call the handler already closed is
/// left as it is.
pub fn completeHandlerError(ctx: *Context) void {
    @branchHint(.cold);

    _ = ctx.finishIfOpen(.INTERNAL, HANDLER_ERROR_MESSAGE);
}

/// Build the response and hand the trio to the handler. One place builds the
/// trio, so every dispatch path invokes a handler the same way.
///
/// Param:
/// handler_fn - HandlerFn (the router dispatch or a single handler)
/// req - *Request (already built by the caller)
/// ctx - *Context (already built by the caller)
///
/// Return:
/// - void
pub fn invoke(handler_fn: HandlerFn, req: *Request, ctx: *Context) void {
    var res: Response = .{
        ._ctx = ctx,
    };

    handler_fn(req, &res, ctx) catch |err| switch (err) {
        else => completeHandlerError(ctx),
    };
}

/// Start time of a call for the rpc line.
///
/// Return:
/// - ?Timestamp (null when no logger is attached, so nothing is timed)
pub fn rpcStart(io: std.Io, logger: ?*Logger) ?Timestamp {
    if (logger == null) return null;

    return Timestamp.now(io, .awake);
}

/// Write one rpc line for a finished call, when a logger is attached.
///
/// Param:
/// logger - ?*Logger (null writes nothing)
/// started - ?Timestamp (from rpcStart)
/// ctx - *const Context (the finished call)
/// path - []const u8 (the gRPC path)
/// recv_bytes - usize (request body bytes)
///
/// Return:
/// - void
pub fn writeRpcRecord(
    logger: ?*Logger,
    started: ?Timestamp,
    ctx: *const Context,
    path: []const u8,
    recv_bytes: usize,
) void {
    const target = logger orelse return;
    const start = started orelse return;

    const elapsed = start.untilNow(ctx.io).raw.toMilliseconds();
    const dur_ms: u64 = @intCast(@max(0, elapsed));

    var peer_buf: [peer_addr.MAX_LEN]u8 = undefined;
    const peer = peer_addr.endpoint(ctx.fd, &peer_buf);

    target.rpc(peer, path, ctx._grpc_status, recv_bytes, ctx._sent_bytes, dur_ms);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const GrpcStatus = @import("status.zig").GrpcStatus;
const ReplyStage = @import("ReplyStage.zig");

const TEST_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

threadlocal var tl_calls: usize = 0;

fn okHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    tl_calls += 1;

    try res.finish(.OK, "");
}

fn failingHandler(_: *Request, _: *Response, _: *Context) anyerror!void {
    tl_calls += 1;

    return error.TestHandlerFailed;
}

fn finishThenFailHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    try res.finish(.NOT_FOUND, "");

    return error.TestHandlerFailed;
}

fn stagedContext(stage: *ReplyStage) Context {
    var ctx = Context.init(std.testing.io, std.testing.allocator, TEST_FD, 1, &.{});
    ctx._out = stage;

    return ctx;
}

test "zix http2 grpc: handler, invoke calls the handler once" {
    var backing: [512]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);
    var req: Request = .{
        .path = "/svc.Svc/Method",
        .headers = &.{},
        ._ctx = &ctx,
    };

    tl_calls = 0;
    invoke(okHandler, &req, &ctx);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    try std.testing.expectEqual(@intFromEnum(GrpcStatus.OK), ctx._grpc_status);
}

test "zix http2 grpc: handler, an error with the call open closes it with INTERNAL" {
    var backing: [512]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);
    var req: Request = .{
        .path = "/svc.Svc/Method",
        .headers = &.{},
        ._ctx = &ctx,
    };

    invoke(failingHandler, &req, &ctx);

    try std.testing.expect(ctx._finished);
    try std.testing.expectEqual(@intFromEnum(GrpcStatus.INTERNAL), ctx._grpc_status);
}

test "zix http2 grpc: handler, an error after finish keeps the handler status" {
    var backing: [512]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);
    var req: Request = .{
        .path = "/svc.Svc/Method",
        .headers = &.{},
        ._ctx = &ctx,
    };

    invoke(finishThenFailHandler, &req, &ctx);

    try std.testing.expectEqual(@intFromEnum(GrpcStatus.NOT_FOUND), ctx._grpc_status);
}

test "zix http2 grpc: handler, rpcStart without a logger is null" {
    try std.testing.expect(rpcStart(std.testing.io, null) == null);
}

test "zix http2 grpc: handler, writeRpcRecord without a logger writes nothing" {
    const ctx = Context.init(std.testing.io, std.testing.allocator, TEST_FD, 1, &.{});
    const now = Timestamp.now(std.testing.io, .awake);

    writeRpcRecord(null, now, &ctx, "/svc.Svc/Method", 0);
}

