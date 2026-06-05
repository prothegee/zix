//! Bug 2 reproduction: blocking dispatch freezes the h2 read loop under
//! concurrent server-streaming requests on the same connection.
//!
//! Issue: https://codeberg.org/prothegee/zix/issues/68
//! Appear: version 0.2.0
//! Status: resolved (0.2.1)
//!
//! dispatchGrpcStream is called synchronously inside serveGrpcLoop. While a
//! streaming handler writes thousands of DATA frames, the entire read loop is
//! frozen. Concurrent streams sent by other workers on the same connection pile
//! up in the TCP receive buffer. Once the TCP send buffer fills (flow control),
//! writes stall and no reads happen either — full deadlock. Subsequent streams
//! arrive with body_len = 0, recvMessage() returns null, the handler calls
//! finish(.INVALID_ARGUMENT), which triggers Bug 1 (missing content-type).
//!
//! Build:
//! zig build bug-grpc_stream_concurrent_server
//!
//! Run:
//! ./zig-out/bin/bug-grpc_stream_concurrent_server
//! (listens on 127.0.0.1:9092)
//!
//! Reproduce with ghz (requires a proto matching the path below):
//! ghz --insecure \
//! --proto rnd/bug-0.2.x/bug.proto \
//! --call bug.BugService.Stream \
//! -d '{}' \
//! --connections 2 -c 8 -z 5s \
//! 127.0.0.1:9092
//!
//! bug.proto (rnd/bug-0.2.x/bug.proto):
//! syntax = "proto3";
//! package bug;
//! message Request  {}
//! message Response {}
//! service BugService {
//!   rpc Trigger (Request) returns (Response);
//!   rpc Stream  (Request) returns (stream Response);
//! }
//!
//! Observe: near-100% Unknown errors despite valid requests.
//! Single-stream baseline (passes cleanly):
//! ghz --insecure --proto rnd/bug-0.2.x/bug.proto \
//! --call bug.BugService.Stream \
//! -d '{}' --connections 1 -c 1 -n 5 127.0.0.1:9092

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

const response_count = 5000;

fn streamHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;

    const msg = ctx.recvMessage() orelse {
        ctx.finish(zix.Grpc.Status.INVALID_ARGUMENT, "empty request");
        return;
    };
    _ = msg;

    var index: usize = 0;
    while (index < response_count) : (index += 1) {
        ctx.sendMessage("application/grpc+proto", &[_]u8{0});
    }

    ctx.finish(zix.Grpc.Status.OK, "");
}

// --------------------------------------------------------- //

pub fn main() !void {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();

    const io_backend = threaded.io();

    var server = try zix.Grpc.Server.init(
        &[_]zix.Grpc.Route{
            .{ .path = "/bug.BugService/Stream", .handler = streamHandler },
        }, .{
            .io = io_backend,
            .ip = "127.0.0.1",
            .port = 9092,
            .dispatch_model = .ASYNC,
        },
    );
    defer server.deinit();

    try server.run();
}
