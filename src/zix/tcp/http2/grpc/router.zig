//! ZIX Http2 Grpc router
//!
//! ### file: src/zix/tcp/http2/grpc/router.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! gRPC routes and the comptime router: exact path to handler.
//!
//! ### note:
//!
//! The engine reads Route.is_server_streaming before a handler runs, to pick
//! inline dispatch or a spawned task. That is why a server takes the router
//! type, not a bare handler.
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
const Context = @import("Context.zig");
const HandlerFn = @import("handler.zig").HandlerFn;
const Request = @import("Request.zig");
const Response = @import("Response.zig");

// --------------------------------------------------------- //
// Public:

/// One gRPC route: exact full path to handler.
pub const Route = struct {
    /// Full gRPC path, e.g. "/package.Service/Method".
    path: []const u8,
    handler: HandlerFn,
    /// Route budget in milliseconds. 0 leaves the deadline as dispatch set it.
    /// Otherwise it tightens ctx.deadline when shorter.
    timeout_ms: u32 = 0,
    /// true for a handler that sends many messages or runs long. It runs on
    /// its own task. false runs inline on the connection thread, which only
    /// suits a short unary handler.
    is_server_streaming: bool = false,
};

/// Build a router type whose route table is fixed at compile time.
///
/// Note:
/// - An unknown path is closed with UNIMPLEMENTED.
/// - route_slice exposes the table, so the engine can read
///   is_server_streaming before a handler runs.
///
/// Usage:
/// ```zig
/// const Routes = zix.Grpc.Router(&[_]zix.Grpc.Route{
///     .{
///         .path = "/helloworld.Greeter/SayHello",
///         .handler = sayHello,
///     },
///     .{
///         .path = "/helloworld.Greeter/Echo",
///         .handler = echo,
///         .is_server_streaming = true,
///     },
/// });
/// ```
///
/// Param:
/// routes - []const Route (comptime-known route table)
///
/// Return:
/// - type
pub fn Router(comptime routes: []const Route) type {
    return struct {
        /// The comptime route table.
        pub const route_slice: []const Route = routes;

        /// Dispatch the call to the route with its exact path. Usable as a
        /// HandlerFn.
        pub fn dispatch(req: *Request, res: *Response, ctx: *Context) anyerror!void {
            inline for (routes) |route| {
                if (std.mem.eql(u8, route.path, req.path)) {
                    ctx.deadline = deadline.tightenMs(ctx.io, ctx.deadline, route.timeout_ms);

                    return route.handler(req, res, ctx);
                }
            }

            return res.finish(.UNIMPLEMENTED, "unknown method");
        }
    };
}

/// Whether the route for path is server-streaming.
///
/// Param:
/// routes - []const Route (comptime route table)
/// path - []const u8 (the gRPC path)
///
/// Return:
/// - bool (false for an unknown path)
pub fn routeIsStreaming(comptime routes: []const Route, path: []const u8) bool {
    inline for (routes) |route| {
        if (std.mem.eql(u8, route.path, path)) return route.is_server_streaming;
    }

    return false;
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

fn countHandler(_: *Request, _: *Response, _: *Context) anyerror!void {
    tl_calls += 1;
}

const TEST_ROUTES = [_]Route{
    .{
        .path = "/svc.Svc/Unary",
        .handler = countHandler,
    },
    .{
        .path = "/svc.Svc/Stream",
        .handler = countHandler,
        .timeout_ms = 60_000,
        .is_server_streaming = true,
    },
};

const TestRouter = Router(&TEST_ROUTES);

fn stagedContext(stage: *ReplyStage) Context {
    var ctx = Context.init(std.testing.io, std.testing.allocator, TEST_FD, 1, &.{});
    ctx._out = stage;

    return ctx;
}

test "zix http2 grpc: router, Route timeout_ms defaults to zero" {
    try std.testing.expectEqual(@as(u32, 0), TEST_ROUTES[0].timeout_ms);
}

test "zix http2 grpc: router, Route is_server_streaming defaults to false" {
    try std.testing.expect(!TEST_ROUTES[0].is_server_streaming);
}

test "zix http2 grpc: router, dispatch calls the matching handler" {
    var backing: [512]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);
    var req: Request = .{
        .path = "/svc.Svc/Unary",
        .headers = &.{},
        ._ctx = &ctx,
    };
    var res: Response = .{
        ._ctx = &ctx,
    };

    tl_calls = 0;
    try TestRouter.dispatch(&req, &res, &ctx);

    try std.testing.expectEqual(@as(usize, 1), tl_calls);
    try std.testing.expect(ctx.deadline == null);
}

test "zix http2 grpc: router, dispatch sets the route deadline" {
    var backing: [512]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);
    var req: Request = .{
        .path = "/svc.Svc/Stream",
        .headers = &.{},
        ._ctx = &ctx,
    };
    var res: Response = .{
        ._ctx = &ctx,
    };

    try TestRouter.dispatch(&req, &res, &ctx);

    try std.testing.expect(ctx.deadline != null);
    try std.testing.expect(!ctx.isExpired());
}

test "zix http2 grpc: router, dispatch keeps a tighter deadline" {
    var backing: [512]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage).withTimeout(0);
    var req: Request = .{
        .path = "/svc.Svc/Stream",
        .headers = &.{},
        ._ctx = &ctx,
    };
    var res: Response = .{
        ._ctx = &ctx,
    };

    try TestRouter.dispatch(&req, &res, &ctx);

    try std.testing.expect(ctx.isExpired());
}

test "zix http2 grpc: router, unknown path is UNIMPLEMENTED" {
    var backing: [512]u8 = undefined;
    var stage: ReplyStage = .{
        .fd = TEST_FD,
        .buf = &backing,
    };
    var ctx = stagedContext(&stage);
    var req: Request = .{
        .path = "/svc.Svc/Missing",
        .headers = &.{},
        ._ctx = &ctx,
    };
    var res: Response = .{
        ._ctx = &ctx,
    };

    tl_calls = 0;
    try TestRouter.dispatch(&req, &res, &ctx);

    try std.testing.expectEqual(@as(usize, 0), tl_calls);
    try std.testing.expectEqual(@intFromEnum(GrpcStatus.UNIMPLEMENTED), ctx._grpc_status);
}

test "zix http2 grpc: router, route_slice exposes the table" {
    try std.testing.expectEqual(@as(usize, 2), TestRouter.route_slice.len);
}

test "zix http2 grpc: router, routeIsStreaming reads the route flag" {
    try std.testing.expect(routeIsStreaming(&TEST_ROUTES, "/svc.Svc/Stream"));
    try std.testing.expect(!routeIsStreaming(&TEST_ROUTES, "/svc.Svc/Unary"));
}

test "zix http2 grpc: router, routeIsStreaming on an unknown path is false" {
    try std.testing.expect(!routeIsStreaming(&TEST_ROUTES, "/svc.Svc/Missing"));
}

