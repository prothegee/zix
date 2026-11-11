//! ZIX Http2 router
//!
//! ### file: src/zix/tcp/http2/router.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Compile-time route table (EXACT and PREFIX) and request dispatch, with the
//! public_dir static fallback before 404.
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
const static = @import("static.zig");

// --------------------------------------------------------- //
// Public:

pub const RouteKind = enum(u8) {
    EXACT,
    PREFIX,
};

pub const Route = struct {
    path: []const u8,
    handler: HandlerFn,
    kind: RouteKind = .EXACT,
};

/// Build a router type whose dispatch table is fixed at compile time.
///
/// Note:
/// - EXACT routes go into a StaticStringMap for O(1) lookup, PREFIX routes
///   into a comptime array iterated with inline for at each dispatch call.
/// - Dispatch priority: EXACT > PREFIX (longest wins) > static file > 404.
/// - A PREFIX matches only at a segment boundary: "/api" takes "/api/x",
///   not "/apiv2".
/// - The returned type exposes a single `dispatch` usable as a HandlerFn.
///
/// Param:
/// routes - []const Route (comptime-known route table)
///
/// Usage:
/// ```zig
/// const Routes = zix.Http2.Router(&[_]zix.Http2.Route{
///     .{
///         .path = "/",
///         .handler = homeHandler,
///     },
///     .{
///         .path = "/static",
///         .handler = staticHandler,
///         .kind = .PREFIX,
///     },
/// });
///
/// var server = zix.Http2.Server.init(Routes.dispatch, .{
///     .io = init.io,
///     .ip = "0.0.0.0",
///     .port = 8082,
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

    const exact_map = std.StaticStringMap(HandlerFn).initComptime(exact_pairs);

    return struct {
        /// Dispatch the request to the best matching route. Usable as a HandlerFn.
        ///
        /// Note:
        /// - Pass 1 exact: O(1) comptime-built hash lookup
        /// - Pass 2 prefix: longest matching prefix wins
        /// - Pass 3 static: a file under public_dir, when one is configured
        /// - Unknown paths get 404 text/plain.
        pub fn dispatch(
            req: *Request,
            res: *Response,
            ctx: *Context,
        ) anyerror!void {
            const path = req.path;

            // Pass 1: exact, O(1) hash lookup
            if (exact_map.get(path)) |handler| {
                return handler(req, res, ctx);
            }

            // Pass 2: prefix (longest match wins)
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

            // Pass 3: a file under public_dir, when one is configured.
            if (static.fallback(req, ctx)) {
                res.sent = true;

                return;
            }

            res.setStatus(404);

            try res.sendText("Not Found");
        }
    };
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const builtin = @import("builtin");
const frame = @import("frame.zig");
const pair = @import("../../utils/socket/pair.zig");

/// A descriptor no test path writes to.
const NO_FD: std.posix.fd_t = if (builtin.os.tag == .windows)
    std.os.windows.INVALID_HANDLE_VALUE
else
    -1;

/// Which route handled the last dispatch. Zero means none.
threadlocal var tl_hit_id: u8 = 0;

fn mockHandler(req: *Request, res: *Response, ctx: *Context) anyerror!void {
    _ = req;
    _ = res;
    _ = ctx;
}

fn markHandler(comptime route_id: u8) HandlerFn {
    return struct {
        fn handle(_: *Request, _: *Response, _: *Context) anyerror!void {
            tl_hit_id = route_id;
        }
    }.handle;
}

fn testRequest(path: []const u8) Request {
    return .{
        .method = "GET",
        .path = path,
        .query = "",
        .headers = &.{},
        .body = "",
    };
}

/// Dispatch one path with no matching side effect on a socket.
fn dispatchHit(comptime RouterType: type, path: []const u8) !u8 {
    var req = testRequest(path);
    var res = Response{
        .fd = NO_FD,
        .sid = 1,
    };
    var ctx = Context.init(std.testing.io, std.testing.allocator, NO_FD, 1);

    tl_hit_id = 0;
    try RouterType.dispatch(&req, &res, &ctx);

    return tl_hit_id;
}

/// Dispatch one path over a socket pair and return the response and the wire.
fn dispatchWire(
    comptime RouterType: type,
    path: []const u8,
    public_dir: []const u8,
    wire_buf: []u8,
) !struct { Response, []const u8 } {
    // The wire is read back with a POSIX read.
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[1]);

    var req = testRequest(path);
    var res = Response{
        .fd = fds[0],
        .sid = 1,
    };
    var ctx = Context.init(std.testing.io, std.testing.allocator, fds[0], 1);
    ctx.public_dir = public_dir;

    const dispatched = RouterType.dispatch(&req, &res, &ctx);
    _ = std.posix.system.close(fds[0]);
    try dispatched;

    var total: usize = 0;
    while (total < wire_buf.len) {
        const rc = std.posix.system.read(fds[1], wire_buf[total..].ptr, wire_buf.len - total);
        if (std.posix.errno(rc) != .SUCCESS or rc == 0) break;

        total += @intCast(rc);
    }

    return .{ res, wire_buf[0..total] };
}

fn writeFixture(tmp: *std.testing.TmpDir, name: []const u8, data: []const u8) void {
    tmp.dir.writeFile(std.testing.io, .{
        .sub_path = name,
        .data = data,
    }) catch |err| switch (err) {
        else => @panic("fixture write failed"),
    };
}

fn fixtureRoot(tmp: *std.testing.TmpDir, buf: []u8) []const u8 {
    const root = std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path});

    return root catch |err| switch (err) {
        error.NoSpaceLeft => @panic("fixture path too long"),
    };
}

/// Payload of the last DATA frame on the wire.
fn lastData(wire: []const u8) []const u8 {
    var offset: usize = 0;
    var payload: []const u8 = &.{};

    while (offset + frame.FRAME_HEADER_LEN <= wire.len) {
        const header = frame.parseFrameHeader(wire[offset..][0..frame.FRAME_HEADER_LEN]);
        offset += frame.FRAME_HEADER_LEN;
        if (offset + header.length > wire.len) break;

        if (header.frame_type == frame.FRAME_TYPE_DATA) {
            payload = wire[offset..][0..header.length];
        }

        offset += header.length;
    }

    return payload;
}

test "zix http2: router, Router builds at comptime" {
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
    });

    try std.testing.expect(@hasDecl(TestRouter, "dispatch"));
}

test "zix http2: router, exact match routes to handler" {
    const TestRouter = Router(&[_]Route{.{
        .path = "/about",
        .handler = markHandler(1),
    }});

    try std.testing.expectEqual(@as(u8, 1), try dispatchHit(TestRouter, "/about"));
}

test "zix http2: router, EXACT wins over PREFIX" {
    const TestRouter = Router(&[_]Route{
        .{
            .path = "/json",
            .handler = markHandler(1),
        },
        .{
            .path = "/json",
            .handler = markHandler(2),
            .kind = .PREFIX,
        },
    });

    try std.testing.expectEqual(@as(u8, 1), try dispatchHit(TestRouter, "/json"));
}

test "zix http2: router, longest PREFIX wins" {
    const TestRouter = Router(&[_]Route{
        .{
            .path = "/json",
            .handler = markHandler(2),
            .kind = .PREFIX,
        },
        .{
            .path = "/json/special",
            .handler = markHandler(3),
            .kind = .PREFIX,
        },
    });

    try std.testing.expectEqual(@as(u8, 3), try dispatchHit(TestRouter, "/json/special/x"));
}

test "zix http2: router, PREFIX matches the bare prefix path" {
    const TestRouter = Router(&[_]Route{.{
        .path = "/api",
        .handler = markHandler(4),
        .kind = .PREFIX,
    }});

    try std.testing.expectEqual(@as(u8, 4), try dispatchHit(TestRouter, "/api"));
}

test "zix http2: router, PREFIX past a segment boundary falls through to 404" {
    const TestRouter = Router(&[_]Route{.{
        .path = "/api",
        .handler = markHandler(4),
        .kind = .PREFIX,
    }});

    var wire_buf: [256]u8 = undefined;
    tl_hit_id = 0;
    const res, _ = try dispatchWire(TestRouter, "/apiv2", "", &wire_buf);

    try std.testing.expectEqual(@as(u8, 0), tl_hit_id);
    try std.testing.expectEqual(@as(u16, 404), res.status);
}

test "zix http2: router, unknown path sends Not Found" {
    const TestRouter = Router(&[_]Route{.{
        .path = "/about",
        .handler = mockHandler,
    }});

    var wire_buf: [256]u8 = undefined;
    _, const wire = try dispatchWire(TestRouter, "/missing", "", &wire_buf);

    try std.testing.expectEqualStrings("Not Found", lastData(wire));
}

test "zix http2: router, static disabled when public_dir is empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "a.txt", "hi");

    const TestRouter = Router(&[_]Route{.{
        .path = "/about",
        .handler = mockHandler,
    }});

    var wire_buf: [256]u8 = undefined;
    const res, _ = try dispatchWire(TestRouter, "/a.txt", "", &wire_buf);

    try std.testing.expectEqual(@as(u16, 404), res.status);
}

test "zix http2: router, static fallback serves a file under public_dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "a.txt", "hi");

    const TestRouter = Router(&[_]Route{.{
        .path = "/about",
        .handler = mockHandler,
    }});

    var root_buf: [64]u8 = undefined;
    var wire_buf: [256]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);
    _, const wire = try dispatchWire(TestRouter, "/a.txt", root, &wire_buf);

    try std.testing.expectEqualStrings("hi", lastData(wire));
}

test "zix http2: router, static fallback marks the response sent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(&tmp, "a.txt", "hi");

    const TestRouter = Router(&[_]Route{.{
        .path = "/about",
        .handler = mockHandler,
    }});

    var root_buf: [64]u8 = undefined;
    var wire_buf: [256]u8 = undefined;
    const root = fixtureRoot(&tmp, &root_buf);
    const res, _ = try dispatchWire(TestRouter, "/a.txt", root, &wire_buf);

    try std.testing.expect(res.sent);
}

