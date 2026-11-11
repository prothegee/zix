//! ZIX Http2 Grpc Response
//!
//! ### file: src/zix/tcp/http2/grpc/Response.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Reply verbs of one gRPC call: headers, messages, status, and the cache.
//!
//! ### note:
//!
//! A thin forward to the Context, which owns the gzip, packing, and cork
//! buffer state.
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
const Context = @import("Context.zig");
const GrpcStatus = @import("status.zig").GrpcStatus;

// --------------------------------------------------------- //
// Fields:

/// The call context that owns the reply state.
_ctx: *Context,

const Self = @This();

// --------------------------------------------------------- //
// Private:

fn contextError(err: Context.Error) Error {
    @branchHint(.cold);

    return switch (err) {
        error.ZixHttp2_GrpcContext_BrokenPipe => Error.ZixHttp2_GrpcResponse_BrokenPipe,
        error.ZixHttp2_GrpcContext_UnexpectedEOF => Error.ZixHttp2_GrpcResponse_UnexpectedEOF,
        error.ZixHttp2_GrpcContext_Overflow => Error.ZixHttp2_GrpcResponse_Overflow,
        error.ZixHttp2_GrpcContext_BufferFull => Error.ZixHttp2_GrpcResponse_BufferFull,
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 Grpc response error
pub const Error = error {
    ZixHttp2_GrpcResponse_BrokenPipe,
    ZixHttp2_GrpcResponse_UnexpectedEOF,
    ZixHttp2_GrpcResponse_Overflow,
    ZixHttp2_GrpcResponse_BufferFull,
};

/// Send the initial HEADERS. See Context.sendHeaders.
///
/// Return:
/// - void
/// - error.ZixHttp2_GrpcResponse_BrokenPipe when the peer is gone
pub fn sendHeaders(self: Self, content_type: []const u8) Error!void {
    return self._ctx.sendHeaders(content_type) catch |err| contextError(err);
}

/// Send one reply message. See Context.sendMessage.
///
/// Return:
/// - void
/// - error.ZixHttp2_GrpcResponse_BrokenPipe when the peer is gone
pub fn sendMessage(self: Self, content_type: []const u8, data: []const u8) Error!void {
    return self._ctx.sendMessage(content_type, data) catch |err| contextError(err);
}

/// Close the call with a gRPC status. See Context.finish.
///
/// Return:
/// - void
/// - error.ZixHttp2_GrpcResponse_BrokenPipe when the peer is gone
pub fn finish(self: Self, stat: GrpcStatus, grpc_message: []const u8) Error!void {
    return self._ctx.finish(stat, grpc_message) catch |err| contextError(err);
}

/// Serve a cached unary reply. See Context.serveCached.
///
/// Return:
/// - bool (true when served from cache, the handler should return)
/// - error.ZixHttp2_GrpcResponse_BrokenPipe when the peer went away mid-replay
pub fn serveCached(self: Self, content_type: []const u8) Error!bool {
    return self._ctx.serveCached(content_type) catch |err| contextError(err);
}

/// Send a unary reply message and store it. See Context.sendCached.
///
/// Return:
/// - void
/// - error.ZixHttp2_GrpcResponse_BrokenPipe when the peer is gone
pub fn sendCached(
    self: Self,
    content_type: []const u8,
    data: []const u8,
    ttl_ms: u32,
) Error!void {
    return self._ctx.sendCached(content_type, data, ttl_ms) catch |err| contextError(err);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const ReplyStage = @import("ReplyStage.zig");

const TEST_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

fn stagedContext(stage: *ReplyStage) Context {
    var ctx = Context.init(std.testing.io, std.testing.allocator, TEST_FD, 1, &.{});
    ctx._out = stage;

    return ctx;
}

test "zix http2 grpc: Response, sendMessage forwards to the context" {
    var backing: [1024]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);
    const res: Self = .{
        ._ctx = &ctx,
    };

    try res.sendMessage("application/grpc", "pong");

    try std.testing.expect(ctx._hdr_sent);
    try std.testing.expectEqual(@as(usize, 4), ctx._sent_bytes);
}

test "zix http2 grpc: Response, finish forwards the status" {
    var backing: [1024]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);
    const res: Self = .{
        ._ctx = &ctx,
    };

    try res.finish(.UNIMPLEMENTED, "unknown method");

    try std.testing.expect(ctx._finished);
    try std.testing.expectEqual(@intFromEnum(GrpcStatus.UNIMPLEMENTED), ctx._grpc_status);
}

test "zix http2 grpc: Response, a dead stage is BrokenPipe" {
    var backing: [1024]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
        .failed = true,
    };
    var ctx = stagedContext(&stage);
    const res: Self = .{
        ._ctx = &ctx,
    };

    try std.testing.expectError(
        Error.ZixHttp2_GrpcResponse_BrokenPipe,
        res.sendHeaders("application/grpc"),
    );
}

test "zix http2 grpc: Response, serveCached without a cache is a miss" {
    var backing: [64]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);
    ctx.path = "/svc.Svc/Method";
    const res: Self = .{
        ._ctx = &ctx,
    };

    try std.testing.expect(!try res.serveCached("application/grpc"));
}

