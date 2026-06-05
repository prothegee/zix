//! Bug 1 reproduction: sendGrpcError omits content-type header.
//!
//! Issue: https://codeberg.org/prothegee/zix/issues/67
//! Status: not resolved
//!
//! Every gRPC response HEADERS frame must carry content-type per spec,
//! including trailers-only error responses. sendGrpcError sends :status 200
//! and grpc-status but no content-type, so spec-compliant clients report:
//! rpc error: code = Unknown desc = malformed header: missing HTTP content-type
//!
//! Build:
//! zig build bug-grpc_error_response_server
//!
//! Run:
//! ./zig-out/bin/bug-grpc_error_response_server
//! (listens on 127.0.0.1:9091)
//!
//! Reproduce with curl (no proto file needed):
//! curl -v --http2-prior-knowledge \
//! -H 'content-type: application/grpc+proto' \
//! -H 'te: trailers' \
//! -X POST \
//! http://127.0.0.1:9091/bug.BugService/Trigger
//!
//! Observe in the response headers:
//! < :status: 200
//! < grpc-status: 3
//! < grpc-message: trigger
//! (no content-type header present — this is the bug)
//!
//! After fix, the response must also include:
//! < content-type: application/grpc+proto

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

fn triggerHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;

    // Never calls sendMessage — forces the sendGrpcError path (_hdr_sent = false).
    ctx.finish(zix.Grpc.Status.INVALID_ARGUMENT, "trigger");
}

// --------------------------------------------------------- //

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();

    const io_backend = threaded.io();

    var server = try zix.Grpc.Server.init(
        &[_]zix.Grpc.Route{
            .{ .path = "/bug.BugService/Trigger", .handler = triggerHandler },
        }, .{
            .io = io_backend,
            .ip = "127.0.0.1",
            .port = 9091,
            .dispatch_model = .ASYNC,
        },
    );
    defer server.deinit();

    try server.run();
}
