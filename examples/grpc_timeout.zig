//! ZIX example grpc timeout
//!
//! ### file: examples/grpc_timeout.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! gRPC deadline example: handler_timeout_ms (global cap), Route.timeout_ms
//! (per route), the grpc-timeout header, ctx.isExpired, and ctx.setTimeout.
//!
//! ### note:
//!
//! The tightest of the three budgets wins (global cap, route, grpc-timeout).
//! A deadline never interrupts a handler: the handler checks ctx.isExpired.
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
const zix = @import("zix");

// --------------------------------------------------------- //

const IP:[]const u8 = "127.0.0.1";
const PORT:u16 = 9037;
const WORKERS:usize = 0;
const DISPATCH_MODEL:zix.Grpc.DispatchModel = .ASYNC;

/// Global fallback cap, used by a route with timeout_ms = 0.
const HANDLER_TIMEOUT_MS:u32 = 5_000;
/// Deadline the Extended handler sets for itself.
const EXTENDED_TIMEOUT_MS:u64 = 30_000;

const CONTENT_TYPE:[]const u8 = "application/grpc+proto";

// --------------------------------------------------------- //

/// Read the name field of a HelloReq.
///
/// Return:
/// - []const u8 (the name, "stranger" when absent)
/// - null when the message is malformed
fn helloName(msg: []const u8) ?[]const u8 {
    var name: []const u8 = "stranger";
    var reader = zix.Grpc.MessageReader.init(msg);
    while (true) {
        const maybe_field = reader.next() catch return null;
        const field = maybe_field orelse break;

        if (field.field_number == 1) name = field.payload;
    }

    return name;
}

// Checks ctx.isExpired before building the reply. A real handler checks it
// between each costly step (database call, codec, and so on).
//
// grpcurl usage:
// grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//   -d '{"name":"world"}' 127.0.0.1:9037 helloworld.Greeter/SayHello
//
// grpcurl usage (client deadline):
// grpcurl -proto examples/protobuf/helloworld.proto -plaintext \
//   -rpc-header 'grpc-timeout: 1S' \
//   -d '{"name":"world"}' 127.0.0.1:9037 helloworld.Greeter/SayHello
fn sayHelloHandler(
    req: *zix.Grpc.Request,
    res: *zix.Grpc.Response,
    ctx: *zix.Grpc.Context,
) !void {
    const msg = req.recvMessage() orelse {
        try res.finish(.INVALID_ARGUMENT, "empty request");
        return;
    };

    const name = helloName(msg) orelse {
        try res.finish(.INVALID_ARGUMENT, "malformed request");
        return;
    };

    if (ctx.isExpired()) {
        try res.finish(.DEADLINE_EXCEEDED, "");
        return;
    }

    var text_buf: [256]u8 = undefined;
    const greeting = std.fmt.bufPrint(&text_buf, "Hello, {s}!", .{name}) catch "Hello!";

    var resp_buf: [300]u8 = undefined;
    const resp_len = try zix.Grpc.encodeString(1, greeting, &resp_buf);

    try res.sendMessage(CONTENT_TYPE, resp_buf[0..resp_len]);
    try res.finish(.OK, "");
}

// Checks ctx.isExpired before each reply message, so the client gets
// DEADLINE_EXCEEDED instead of a closed stream.
fn echoHandler(req: *zix.Grpc.Request, res: *zix.Grpc.Response, ctx: *zix.Grpc.Context) !void {
    while (req.recvMessage()) |msg| {
        if (ctx.isExpired()) {
            try res.finish(.DEADLINE_EXCEEDED, "");
            return;
        }

        try res.sendMessage(CONTENT_TYPE, msg);
    }

    try res.finish(.OK, "");
}

// Moves its own deadline at runtime, for a call that needs a longer window
// than the global cap. Checks ctx.isExpired first: the deadline may already
// have passed.
fn extendedHandler(
    req: *zix.Grpc.Request,
    res: *zix.Grpc.Response,
    ctx: *zix.Grpc.Context,
) !void {
    if (!ctx.isExpired()) ctx.setTimeout(EXTENDED_TIMEOUT_MS);

    const msg = req.recvMessage() orelse {
        try res.finish(.INVALID_ARGUMENT, "empty request");
        return;
    };

    try res.sendMessage(CONTENT_TYPE, msg);
    try res.finish(.OK, "");
}

// --------------------------------------------------------- //

const Routes = zix.Grpc.Router(&[_]zix.Grpc.Route{
    // Route cap of 3s, tighter than the 5s global cap.
    .{
        .path = "/helloworld.Greeter/SayHello",
        .handler = sayHelloHandler,
        .timeout_ms = 3_000,
    },
    // Route cap of 10s. The 5s global cap is tighter, so 5s applies.
    .{
        .path = "/helloworld.Greeter/Echo",
        .handler = echoHandler,
        .timeout_ms = 10_000,
        .is_server_streaming = true,
    },
    // No route cap. The handler sets its own deadline.
    .{
        .path = "/helloworld.Greeter/Extended",
        .handler = extendedHandler,
    },
});

pub fn main(init: std.process.Init) !void {
    var server = zix.Grpc.Server.init(Routes, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .dispatch_model = DISPATCH_MODEL,
        .handler_timeout_ms = HANDLER_TIMEOUT_MS,
    });
    defer server.deinit();

    try server.run();
}

