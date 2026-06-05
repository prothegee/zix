// Bug reproduction tests for zix 0.2.0 gRPC server-streaming.
//
// Run with (from the zix/ directory):
//   zig test bug_grpc_stream_test.zig
//
// Both tests are expected to FAIL on the unpatched zix 0.2.0 source.

const std = @import("std");
const frm = @import("src/tcp/http2/grpc/frame.zig");
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
// Expected to FAIL on zix 0.2.0.
test "Bug1: sendGrpcError response contains content-type header" {
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(fds[0]);

    frm.sendGrpcError(fds[1], 1, 3, "empty request") catch {};
    _ = std.posix.system.close(fds[1]);

    var buf: [512]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
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
// Expected to FAIL on zix 0.2.0 (sendGrpcError lacks content-type).
test "Bug2: GrpcContext finish without sendMessage still emits content-type" {
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(fds[0]);

    var ctx = core.GrpcContext{
        .fd = fds[1],
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
    _ = std.posix.system.close(fds[1]);

    var buf: [512]u8 = undefined;
    const n = try std.posix.read(fds[0], &buf);
    const raw = buf[0..n];

    // The response must carry content-type per gRPC spec.
    // FAILS because _hdr_sent=false -> finish() calls sendGrpcError which
    // omits content-type (Bug 1).
    const has_content_type = std.mem.indexOf(u8, raw, "content-type") != null;
    try std.testing.expect(has_content_type);
}
