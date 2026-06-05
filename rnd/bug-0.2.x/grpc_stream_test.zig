// Bug reproduction tests for zix 0.2.0 gRPC server-streaming.
//
// Run with (from the zix/ directory):
//   zig test bug_grpc_stream_test.zig
//
// Both tests pass on zix 0.2.1 and later.

const std = @import("std");
const frame = @import("src/tcp/http2/grpc/frame.zig");
const core = @import("src/tcp/http2/grpc/core.zig");

// --------------------------------------------------------- //
// --------------------------------------------------------- //

// Bug 1: sendGrpcError omits content-type header.
//
// gRPC spec (§ "Responses") requires content-type: application/grpc[+format]
// in ALL response HEADERS frames, including trailers-only error responses.
// sendGrpcError sends :status:200 + grpc-status + grpc-message but no
// content-type, so any gRPC client that enforces the spec (ghz, grpc-go)
// reports "malformed header: missing HTTP content-type".
//
// Fixed in 0.2.1.
test "Bug1: sendGrpcError response contains content-type header" {
    const pipe_fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(pipe_fds[0]);

    frame.sendGrpcError(pipe_fds[1], 1, 3, "empty request") catch {};
    _ = std.posix.system.close(pipe_fds[1]);

    var buf: [512]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    const raw = buf[0..n];

    // HPACK encodes content-type as a literal; the ASCII string "content-type"
    // will appear verbatim in the encoded header block.
    const has_content_type = std.mem.indexOf(u8, raw, "content-type") != null;
    try std.testing.expect(has_content_type);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

// Bug 2: empty body reaches the handler under concurrent stream load.
//
// GrpcContext.recvMessage() returns null when _body is empty (body_len=0).
// Under concurrent h2 streaming, zix's blocking per-connection dispatch causes
// stream slot state to degrade: DATA frames arrive but findSlot() misses the
// matching slot, so the handler is dispatched with _body=&.{} instead of the
// actual request bytes. The handler then hits the null path and calls
// ctx.finish(.INVALID_ARGUMENT) without a prior ctx.sendMessage(), which
// triggers Bug 1.
//
// This test pins the null-body -> sendGrpcError path.
// Fixed in 0.2.1.
test "Bug2: GrpcContext finish without sendMessage still emits content-type" {
    const pipe_fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(pipe_fds[0]);

    var ctx = core.GrpcContext{
        .fd = pipe_fds[1],
        .stream_id = 1,
        ._body = &.{},
        ._pos = 0,
        ._hdr_sent = false,
        ._sent_bytes = 0,
        ._grpc_status = 0,
    };

    // Simulate: recvMessage() returns null because body is empty (Bug 2 trigger).
    const msg = ctx.recvMessage();
    try std.testing.expect(msg == null);

    // Handler takes the early-exit path used in streamSumHandler / getSumHandler.
    ctx.finish(.INVALID_ARGUMENT, "empty request");
    _ = std.posix.system.close(pipe_fds[1]);

    var buf: [512]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &buf);
    const raw = buf[0..n];

    // The response must carry content-type per gRPC spec.
    const has_content_type = std.mem.indexOf(u8, raw, "content-type") != null;
    try std.testing.expect(has_content_type);
}
