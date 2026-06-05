//! gRPC context timeout example.
//! Demonstrates handler_timeout_ms (global cap), Route.timeout_ms (per-route),
//! ctx.isExpired() (deadline check), and ctx.deadline_ns override at runtime.
//! Port: 8084
//!
//! Run:
//! zig build example-grpc_timeout
//! ./zig-out/bin/example-grpc_timeout
//!
//! Test with grpcurl (requires grpcurl installed):
//! grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//! -d '{"name":"world"}' 127.0.0.1:8084 helloworld.Greeter/SayHello
//!
//! grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//! -rpc-header 'grpc-timeout: 1S' \
//! -d '{"name":"world"}' 127.0.0.1:8084 helloworld.Greeter/SayHello

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

// Unary handler. Checks ctx.isExpired() before building the response.
// In production, check between each expensive step (DB call, codec, etc.).
fn sayHelloHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;
    const msg = ctx.recvMessage() orelse {
        ctx.finish(zix.Grpc.Status.INVALID_ARGUMENT, "empty request");
        return;
    };

    if (ctx.isExpired()) {
        ctx.finish(zix.Grpc.Status.DEADLINE_EXCEEDED, "");
        return;
    }

    var out: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&out, "Hello, {s}!", .{msg}) catch "Hello!";

    ctx.sendMessage("application/grpc+proto", resp);
    ctx.finish(zix.Grpc.Status.OK, "");
}

// Streaming echo handler. Checks ctx.isExpired() before each response message.
// Abort early with DEADLINE_EXCEEDED so the client gets a status rather than a closed stream.
fn echoHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;
    while (ctx.recvMessage()) |msg| {
        if (ctx.isExpired()) {
            ctx.finish(zix.Grpc.Status.DEADLINE_EXCEEDED, "");
            return;
        }

        ctx.sendMessage("application/grpc+proto", msg);
    }

    ctx.finish(zix.Grpc.Status.OK, "");
}

// Handler that overrides its own deadline at runtime.
// Use when one route needs a longer or shorter window than the global cap.
// ctx.deadline_ns = null disables enforcement entirely for this call.
fn extendedHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;

    // Override: extend to 30s from now regardless of the global 5s cap.
    // Always check isExpired() first — the deadline may already have passed.
    if (!ctx.isExpired()) {
        ctx.deadline_ns = zix.Grpc.wallClockNs() + 30 * std.time.ns_per_s;
    }

    const msg = ctx.recvMessage() orelse {
        ctx.finish(zix.Grpc.Status.INVALID_ARGUMENT, "empty request");
        return;
    };

    ctx.sendMessage("application/grpc+proto", msg);
    ctx.finish(zix.Grpc.Status.OK, "");
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    var server = try zix.Grpc.Server.init(
        &[_]zix.Grpc.Route{
            // SayHello: per-route cap of 3s (tightens the 5s global cap).
            .{ .path = "/helloworld.Greeter/SayHello", .handler = sayHelloHandler, .timeout_ms = 3_000 },
            // Echo: per-route cap of 10s (loosens nothing — global 5s cap still wins).
            .{ .path = "/helloworld.Greeter/Echo", .handler = echoHandler, .timeout_ms = 10_000, .is_server_streaming = true },
            // Extended: ignores per-route cap. Overrides deadline_ns at runtime.
            .{ .path = "/helloworld.Greeter/Extended", .handler = extendedHandler },
        },
        .{
            .io = process.io,
            .ip = "127.0.0.1",
            .port = 8084,
            .dispatch_model = .ASYNC,
            // Global fallback cap: 5s. Applies to any route with timeout_ms = 0.
            // Combined with Route.timeout_ms and the client grpc-timeout header —
            // the tightest of the three wins.
            .handler_timeout_ms = 5_000,
        },
    );
    defer server.deinit();

    try server.run();
}
