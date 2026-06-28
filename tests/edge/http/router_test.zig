//! Edge tests: zix.Http.Router dispatch boundary conditions.
//! Verifies: no-match yields false, and a prefix does NOT match a path that
//! merely starts with the same characters but is a different segment.

const std = @import("std");
const zix = @import("zix");

fn handlerA(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = res;
    _ = ctx;
}

// --------------------------------------------------------- //

test "zix edge: dispatch, no registered route returns false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{}, .{ .io = undefined, .ip = "127.0.0.1", .port = 9000, .dispatch_model = .ASYNC });
    defer server.deinit();

    var req = try zix.Http.Request.fromRaw("GET /missing HTTP/1.1\r\nHost: localhost\r\n\r\n", al);
    var res = zix.Http.Response.init(undefined, false, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    const matched = try server.router.dispatch(&req, &res, &ctx);
    try std.testing.expect(!matched);
}

test "zix edge: dispatch, prefix /api does NOT match /apiv2" {
    // A prefix handler for "/api" must only match paths where the next character
    // after the prefix is '/' or end-of-path, not paths that merely start with
    // the same bytes but continue without a separator.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/api", .handler = handlerA, .kind = .PREFIX },
    }, .{ .io = undefined, .ip = "127.0.0.1", .port = 9000, .dispatch_model = .ASYNC });
    defer server.deinit();

    var req = try zix.Http.Request.fromRaw("GET /apiv2/resource HTTP/1.1\r\nHost: localhost\r\n\r\n", al);
    var res = zix.Http.Response.init(undefined, false, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    const matched = try server.router.dispatch(&req, &res, &ctx);
    try std.testing.expect(!matched);
}
