//! ZIX Http1 router
//!
//! ### file: src/zix/tcp/http1/router.zig
//! 
//! ### author: Prana Ron
//! 
//! ---------------------------------------------------------
//! 
//! ### brief:
//! 
//! Compile-time route table and request dispatch.
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
const HandlerFn = @import("handler.zig").HandlerFn;
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const Context = @import("Context.zig");
const PathParam = @import("PathParam.zig");

// --------------------------------------------------------- //
// Private:

/// The params captured by the PARAM route that matched this request.
/// It points into the matched router's own store, so a router never needs a
/// fixed limit. Thread-local because each worker serves one request at a time.
/// Values are slices into the request path and stay valid only for the
/// dispatch call.
threadlocal var tl_params: []const PathParam = &.{};

/// Count the `:params` in one route pattern.
///
/// Param:
/// pattern - []const u8 (route path, e.g. "/org/:org/user/:id")
///
/// Return:
/// - usize (number of segments that start with ":")
fn countParams(pattern: []const u8) usize {
    var count: usize = 0;
    var segments = std.mem.splitScalar(u8, pattern, '/');
    while (segments.next()) |segment| {
        if (std.mem.startsWith(u8, segment, ":")) count += 1;
    }

    return count;
}

/// Match a parameterized pattern against a concrete path.
///
/// Note:
/// - A failed match may leave partial writes in store. They are never read,
///   because the caller only publishes store on success.
///
/// Param:
/// pattern - []const u8 (route path with ":" params)
/// path - []const u8 (request path)
/// store - []PathParam (slots the captured params are written into)
///
/// Return:
/// - usize (number of params written into store)
/// - null when the path does not match, or the pattern has more params than store
fn matchParam(pattern: []const u8, path: []const u8, store: []PathParam) ?usize {
    var pat_it = std.mem.splitScalar(u8, pattern, '/');
    var path_it = std.mem.splitScalar(u8, path, '/');
    var count: usize = 0;

    while (true) {
        const pat_seg = pat_it.next();
        const path_seg = path_it.next();
        if (pat_seg == null and path_seg == null) break;
        if (pat_seg == null or path_seg == null) return null;

        const pat_token = pat_seg.?;
        const path_token = path_seg.?;
        if (std.mem.startsWith(u8, pat_token, ":")) {
            if (path_token.len == 0) return null;
            if (count >= store.len) return null;

            store[count] = .{
                .name = pat_token[1..],
                .value = path_token,
            };
            count += 1;
        } else {
            if (!std.mem.eql(u8, pat_token, path_token)) return null;
        }
    }

    return count;
}

// --------------------------------------------------------- //
// Public:

pub const RouteKind = enum(u8) {
    EXACT,
    PREFIX,
    PARAM,
};

pub const Route = struct {
    path: []const u8,
    handler: HandlerFn,
    kind: RouteKind = .EXACT,
};

/// Build a router type whose dispatch table is fixed at compile time.
///
/// Note:
/// - Routes are partitioned by kind at comptime: EXACT routes go into a
///   StaticStringMap for O(1) lookup, PARAM and PREFIX routes into comptime
///   arrays iterated with inline for at each dispatch call.
/// - Dispatch priority: EXACT > PARAM (first-registered wins) > PREFIX (longest wins).
/// - Registration order matters only within the PARAM tier.
/// - The param store is sized at comptime to the PARAM route with the most
///   ":" params, so there is no fixed limit to raise.
/// - The returned type exposes a single `dispatch` usable as a HandlerFn.
///
/// Param:
/// routes - []const Route (comptime-known route table)
///
/// Usage:
/// ```zig
/// const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
///     .{
///         .path = "/",
///         .handler = homeHandler,
///     },
///     .{
///         .path = "/secret",
///         .handler = secretHandler,
///         .kind = .PREFIX,
///     },
///     .{
///         .path = "/users/:id",
///         .handler = userHandler,
///         .kind = .PARAM,
///     },
/// });
///
/// var server = zix.Http1.Server.init(Routes.dispatch, .{
///     .io = init.io,
///     .ip = "0.0.0.0",
///     .port = 8080,
///     .dispatch_model = .ASYNC,
/// });
/// try server.run();
/// ```
///
/// Return:
/// - type
pub fn Router(comptime routes: []const Route) type {
    const exact_count = blk: {
        var n: usize = 0;
        for (routes) |route| if (route.kind == .EXACT) {
            n += 1;
        };
        break :blk n;
    };
    const prefix_count = blk: {
        var n: usize = 0;
        for (routes) |route| if (route.kind == .PREFIX) {
            n += 1;
        };
        break :blk n;
    };
    const param_count = blk: {
        var n: usize = 0;
        for (routes) |route| if (route.kind == .PARAM) {
            n += 1;
        };
        break :blk n;
    };
    const max_params = blk: {
        var n: usize = 0;
        for (routes) |route| if (route.kind == .PARAM) {
            n = @max(n, countParams(route.path));
        };
        break :blk n;
    };

    const exact_pairs: [exact_count]struct { []const u8, HandlerFn } = blk: {
        var arr: [exact_count]struct { []const u8, HandlerFn } = undefined;
        var i: usize = 0;
        for (routes) |route| {
            if (route.kind == .EXACT) {
                arr[i] = .{ route.path, route.handler };
                i += 1;
            }
        }
        break :blk arr;
    };

    const prefix_routes: [prefix_count]Route = blk: {
        var arr: [prefix_count]Route = undefined;
        var i: usize = 0;
        for (routes) |route| {
            if (route.kind == .PREFIX) {
                arr[i] = route;
                i += 1;
            }
        }
        break :blk arr;
    };

    const param_routes: [param_count]Route = blk: {
        var arr: [param_count]Route = undefined;
        var i: usize = 0;
        for (routes) |route| {
            if (route.kind == .PARAM) {
                arr[i] = route;
                i += 1;
            }
        }
        break :blk arr;
    };

    const exact_map = std.StaticStringMap(HandlerFn).initComptime(exact_pairs);

    return struct {
        /// This router's param slots, one per ":" param of its largest PARAM route.
        threadlocal var params: [max_params]PathParam = undefined;

        /// Dispatch the request to the best matching route. Usable as a HandlerFn.
        ///
        /// Note:
        /// - Pass 1 exact: O(1) comptime-built hash lookup
        /// - Pass 2 param: first parameterized pattern that matches wins
        /// - Pass 3 prefix: longest matching prefix wins
        /// - Unknown paths get 404 text/plain.
        pub fn dispatch(
            req: *Request,
            res: *Response,
            ctx: *Context,
        ) anyerror!void {
            tl_params = &.{};

            const path = req.head.path;

            // Pass 1: exact, O(1) hash lookup
            if (exact_map.get(path)) |handler| {
                return handler(req, res, ctx);
            }

            // Pass 2: parameterized (first match wins)
            inline for (param_routes) |route| {
                if (matchParam(route.path, path, &params)) |count| {
                    tl_params = params[0..count];

                    return route.handler(req, res, ctx);
                }
            }

            // Pass 3: prefix (longest match wins)
            var best_len: usize = 0;
            var best_handler: ?HandlerFn = null;
            inline for (prefix_routes) |route| {
                if (std.mem.startsWith(u8, path, route.path)) {
                    const at_boundary =
                        path.len == route.path.len or
                        path[route.path.len] == '/';
                    if (at_boundary and route.path.len > best_len) {
                        best_len = route.path.len;
                        best_handler = route.handler;
                    }
                }
            }

            if (best_handler) |handler| {
                return handler(req, res, ctx);
            }

            // TODO: static file fallback from public_dir before the 404.
            std.log.info("TODO: static.serve", .{});

            res.setStatus(.NOT_FOUND);

            try res.sendText("Not Found");
        }
    };
}

/// Look up a path parameter captured by the matched PARAM route.
///
/// Note:
/// - Only valid inside a handler reached via a PARAM route.
/// - The returned slice borrows the request path and dies with the call.
///
/// Param:
/// name - []const u8 (param name without the leading ":")
///
/// Return:
/// - ?[]const u8 (value slice, or null if no such param)
pub fn pathParam(name: []const u8) ?[]const u8 {
    for (tl_params) |param| {
        if (std.mem.eql(u8, param.name, name)) return param.value;
    }

    return null;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const pair = @import("../../utils/socket/pair.zig");

const TEN_PARAM_PATTERN = "/a/:p1/:p2/:p3/:p4/:p5/:p6/:p7/:p8/:p9/:p10";

fn mockHandler(req: *Request, res: *Response, ctx: *Context) anyerror!void {
    _ = req;
    _ = res;
    _ = ctx;
}

fn lastParamHandler(req: *Request, res: *Response, _: *Context) anyerror!void {
    try res.sendText(req.pathParam("p10") orelse "none");
}

fn storeLen(comptime RouterType: type) usize {
    return @typeInfo(@TypeOf(RouterType.params)).array.len;
}

/// Dispatch one raw request through RouterType and return what it wrote.
fn dispatchRaw(
    comptime RouterType: type,
    raw: []const u8,
    out: []u8,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const head_module = @import("head.zig");
    head_module.setDateHeader(false);
    defer head_module.setDateHeader(true);

    var req = try Request.fromRaw(raw, arena.allocator());
    var res = Response.init(fds[0], std.testing.io, arena.allocator());
    var ctx = Context.init(std.testing.io, arena.allocator(), fds[0]);

    try RouterType.dispatch(&req, &res, &ctx);

    const n = try std.posix.read(fds[1], out);

    return out[0..n];
}

test "zix http1: router, matches a parameter" {
    var store: [2]PathParam = undefined;

    const count = matchParam("/users/:id", "/users/alice", &store).?;
    tl_params = store[0..count];

    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqualStrings("id", store[0].name);
    try std.testing.expectEqualStrings("alice", pathParam("id").?);
}

test "zix http1: router, matches two parameters" {
    var store: [2]PathParam = undefined;

    const count = matchParam("/:tenant/:branch", "/acme/main", &store).?;
    tl_params = store[0..count];

    try std.testing.expectEqualStrings("acme", pathParam("tenant").?);
    try std.testing.expectEqualStrings("main", pathParam("branch").?);
}

test "zix http1: router, rejects a path with too few segments" {
    var store: [1]PathParam = undefined;

    try std.testing.expectEqual(@as(?usize, null), matchParam("/users/:id", "/users", &store));
}

test "zix http1: router, rejects a path with too many segments" {
    var store: [1]PathParam = undefined;

    try std.testing.expectEqual(
        @as(?usize, null),
        matchParam("/users/:id", "/users/alice/posts", &store),
    );
}

test "zix http1: router, rejects an empty param value" {
    var store: [1]PathParam = undefined;

    try std.testing.expectEqual(@as(?usize, null), matchParam("/users/:id", "/users/", &store));
}

test "zix http1: router, matchParam stops past the store" {
    var store: [1]PathParam = undefined;

    try std.testing.expectEqual(@as(?usize, null), matchParam("/:a/:b", "/x/y", &store));
}

test "zix http1: router, countParams counts each param segment" {
    try std.testing.expectEqual(@as(usize, 0), countParams("/about"));
    try std.testing.expectEqual(@as(usize, 1), countParams("/users/:id"));
    try std.testing.expectEqual(@as(usize, 10), countParams(TEN_PARAM_PATTERN));
}

test "zix http1: router, countParams ignores a colon inside a segment" {
    try std.testing.expectEqual(@as(usize, 0), countParams("/time/12:30"));
}

test "zix http1: router, pathParam is null for an unknown name" {
    tl_params = &.{};

    try std.testing.expectEqual(@as(?[]const u8, null), pathParam("id"));
}

test "zix http1: router, builds at comptime" {
    const TestRouter = Router(&[_]Route{
        .{
            .path = "/about",
            .handler = mockHandler,
        },
        .{
            .path = "/api",
            .handler = mockHandler,
            .kind = .PREFIX,
        },
        .{
            .path = "/users/:id",
            .handler = mockHandler,
            .kind = .PARAM,
        },
    });
    _ = TestRouter;
}

test "zix http1: router, sizes the param store to the largest route" {
    const TestRouter = Router(&[_]Route{
        .{
            .path = "/user/:id",
            .handler = mockHandler,
            .kind = .PARAM,
        },
        .{
            .path = "/org/:org/team/:team",
            .handler = mockHandler,
            .kind = .PARAM,
        },
        .{
            .path = TEN_PARAM_PATTERN,
            .handler = mockHandler,
            .kind = .PARAM,
        },
    });

    try std.testing.expectEqual(@as(usize, 10), storeLen(TestRouter));
}

test "zix http1: router, sizes the param store to zero without a param route" {
    const TestRouter = Router(&[_]Route{
        .{
            .path = "/about",
            .handler = mockHandler,
        },
        .{
            .path = "/:not_a_param_route",
            .handler = mockHandler,
            .kind = .PREFIX,
        },
    });

    try std.testing.expectEqual(@as(usize, 0), storeLen(TestRouter));
}

test "zix http1: router, two routers keep their own store size" {
    const SmallRouter = Router(&[_]Route{
        .{
            .path = "/:a/:b/:c",
            .handler = mockHandler,
            .kind = .PARAM,
        },
    });
    const LargeRouter = Router(&[_]Route{
        .{
            .path = "/:a/:b/:c/:d/:e/:f/:g/:h/:i/:j/:k/:l",
            .handler = mockHandler,
            .kind = .PARAM,
        },
    });

    try std.testing.expectEqual(@as(usize, 3), storeLen(SmallRouter));
    try std.testing.expectEqual(@as(usize, 12), storeLen(LargeRouter));
}

test "zix http1: router, dispatch captures more than 8 params" {
    const TestRouter = Router(&[_]Route{
        .{
            .path = TEN_PARAM_PATTERN,
            .handler = lastParamHandler,
            .kind = .PARAM,
        },
    });

    var buf: [256]u8 = undefined;
    const written = try dispatchRaw(
        TestRouter,
        "GET /a/1/2/3/4/5/6/7/8/9/10 HTTP/1.1\r\n\r\n",
        &buf,
    );

    try std.testing.expect(std.mem.endsWith(u8, written, "\r\n\r\n10"));
}

test "zix http1: router, dispatch answers 404" {
    const TestRouter = Router(&[_]Route{
        .{
            .path = "/about",
            .handler = mockHandler,
        },
    });

    var buf: [256]u8 = undefined;
    const written = try dispatchRaw(TestRouter, "GET /missing HTTP/1.1\r\n\r\n", &buf);

    try std.testing.expectEqualStrings(
        "HTTP/1.1 404 Not Found\r\n" ++
        "Content-Type: text/plain\r\n" ++
        "Content-Length: 9\r\n\r\nNot Found",
        written,
    );
}

