//! gRPC context timeout example.
//! Demonstrates handler_timeout_ms (global cap), Route.timeout_ms (per-route),
//! ctx.isExpired() (deadline check), and ctx.deadline_ns override at runtime.
//! Port: 9037
//!
//! Run:
//! zig build example-grpc_timeout
//! ./zig-out/bin/zix-example-grpc_timeout
//!
//! Test with grpcurl (requires grpcurl installed):
//! grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//! -d '{"name":"world"}' 127.0.0.1:9037 helloworld.Greeter/SayHello
//!
//! grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//! -rpc-header 'grpc-timeout: 1S' \
//! -d '{"name":"world"}' 127.0.0.1:9037 helloworld.Greeter/SayHello

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

// Unary handler. Checks ctx.isExpired() before building the response.
// In production, check between each expensive step (DB call, codec, etc.).
fn sayHelloHandler(req: *zix.Grpc.Request, res: *zix.Grpc.Response, ctx: *zix.Grpc.Context) !void {
    const msg = req.recvMessage() orelse {
        res.finish(zix.Grpc.Status.INVALID_ARGUMENT, "empty request");
        return;
    };

    if (ctx.isExpired()) {
        res.finish(zix.Grpc.Status.DEADLINE_EXCEEDED, "");
        return;
    }

    var out: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&out, "Hello, {s}!", .{msg}) catch "Hello!";

    res.sendMessage("application/grpc+proto", resp);
    res.finish(zix.Grpc.Status.OK, "");
}

// Streaming echo handler. Checks ctx.isExpired() before each response message.
// Abort early with DEADLINE_EXCEEDED so the client gets a status rather than a closed stream.
fn echoHandler(req: *zix.Grpc.Request, res: *zix.Grpc.Response, ctx: *zix.Grpc.Context) !void {
    while (req.recvMessage()) |msg| {
        if (ctx.isExpired()) {
            res.finish(zix.Grpc.Status.DEADLINE_EXCEEDED, "");
            return;
        }

        res.sendMessage("application/grpc+proto", msg);
    }

    res.finish(zix.Grpc.Status.OK, "");
}

// Handler that overrides its own deadline at runtime.
// Use when one route needs a longer or shorter window than the global cap.
// ctx.deadline_ns = null disables enforcement entirely for this call.
fn extendedHandler(req: *zix.Grpc.Request, res: *zix.Grpc.Response, ctx: *zix.Grpc.Context) !void {
    // Override: extend to 30s from now regardless of the global 5s cap.
    // Always check isExpired() first: the deadline may already have passed.
    if (!ctx.isExpired()) {
        ctx.deadline_ns = zix.Grpc.wallClockNs() + 30 * std.time.ns_per_s;
    }

    const msg = req.recvMessage() orelse {
        res.finish(zix.Grpc.Status.INVALID_ARGUMENT, "empty request");
        return;
    };

    res.sendMessage("application/grpc+proto", msg);
    res.finish(zix.Grpc.Status.OK, "");
}

// --------------------------------------------------------- //

const Routes = [_]zix.Grpc.Route{
    // SayHello: per-route cap of 3s (tightens the 5s global cap).
    .{ .path = "/helloworld.Greeter/SayHello", .handler = sayHelloHandler, .timeout_ms = 3_000 },
    // Echo: per-route cap of 10s (loosens nothing, global 5s cap still wins).
    .{ .path = "/helloworld.Greeter/Echo", .handler = echoHandler, .timeout_ms = 10_000, .is_server_streaming = true },
    // Extended: ignores per-route cap. Overrides deadline_ns at runtime.
    .{ .path = "/helloworld.Greeter/Extended", .handler = extendedHandler },
};

pub fn main(process: std.process.Init) !void {
    var server = zix.Grpc.Server.init(
        zix.Grpc.Router(&Routes),
        .{
            .io = process.io,
            .ip = "127.0.0.1",
            .port = 9037,
            .dispatch_model = .ASYNC,
            // Global fallback cap: 5s. Applies to any route with timeout_ms = 0.
            // Combined with Route.timeout_ms and the client grpc-timeout header,
            // the tightest of the three wins.
            .handler_timeout_ms = 5_000,
        },
    );
    defer server.deinit();

    try server.run();
}
