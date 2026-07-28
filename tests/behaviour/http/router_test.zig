//! Behaviour tests: router dispatch priority and query-string transparency.
//! Verifies the contracts callers rely on: exact > param > prefix priority,
//! longest prefix wins, and query strings are ignored during path matching.

const std = @import("std");
const zix = @import("zix");

var last_handler: []const u8 = "";

fn handlerA(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = res;
    _ = ctx;
    last_handler = "A";
}

fn handlerB(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = req;
    _ = res;
    _ = ctx;
    last_handler = "B";
}

// --------------------------------------------------------- //

test "zix behaviour: dispatch, exact beats param regardless of registration order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const router = zix.Http.Router(&[_]zix.Http.Route{
        .{ .path = "/users/:id", .handler = handlerB, .kind = .PARAM },
        .{ .path = "/users/alice", .handler = handlerA },
    });

    var req = try zix.Http.Request.fromRaw("GET /users/alice HTTP/1.1\r\nHost: localhost\r\n\r\n", al);
    var res = zix.Http.Response.init(undefined, false, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    last_handler = "";
    try router.dispatch(&req, &res, &ctx);
    try std.testing.expectEqualStrings("A", last_handler);
}

test "zix behaviour: dispatch, param beats prefix regardless of registration order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const router = zix.Http.Router(&[_]zix.Http.Route{
        .{ .path = "/api", .handler = handlerB, .kind = .PREFIX },
        .{ .path = "/api/:resource", .handler = handlerA, .kind = .PARAM },
    });

    var req = try zix.Http.Request.fromRaw("GET /api/users HTTP/1.1\r\nHost: localhost\r\n\r\n", al);
    var res = zix.Http.Response.init(undefined, false, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    last_handler = "";
    try router.dispatch(&req, &res, &ctx);
    try std.testing.expectEqualStrings("A", last_handler);
}

test "zix behaviour: dispatch, prefix: longest match wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const router = zix.Http.Router(&[_]zix.Http.Route{
        .{ .path = "/api", .handler = handlerB, .kind = .PREFIX },
        .{ .path = "/api/users", .handler = handlerA, .kind = .PREFIX },
    });

    var req = try zix.Http.Request.fromRaw("GET /api/users/alice HTTP/1.1\r\nHost: localhost\r\n\r\n", al);
    var res = zix.Http.Response.init(undefined, false, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    last_handler = "";
    try router.dispatch(&req, &res, &ctx);
    try std.testing.expectEqualStrings("A", last_handler);
}

test "zix behaviour: dispatch, prefix matches its own path exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const router = zix.Http.Router(&[_]zix.Http.Route{
        .{ .path = "/api", .handler = handlerA, .kind = .PREFIX },
    });

    var req = try zix.Http.Request.fromRaw("GET /api HTTP/1.1\r\nHost: localhost\r\n\r\n", al);
    var res = zix.Http.Response.init(undefined, false, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    last_handler = "";
    try router.dispatch(&req, &res, &ctx);
    try std.testing.expectEqualStrings("A", last_handler);
}

test "zix behaviour: dispatch, query string transparent to path matching (param)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const router = zix.Http.Router(&[_]zix.Http.Route{
        .{ .path = "/users/:id", .handler = handlerA, .kind = .PARAM },
    });

    var req = try zix.Http.Request.fromRaw("GET /users/bob?role=admin HTTP/1.1\r\nHost: localhost\r\n\r\n", al);
    var res = zix.Http.Response.init(undefined, false, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    try router.dispatch(&req, &res, &ctx);
    try std.testing.expectEqualStrings("bob", req.path_params[0].value);
}

test "zix behaviour: dispatch, query string transparent to path matching (exact)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    const router = zix.Http.Router(&[_]zix.Http.Route{
        .{ .path = "/about", .handler = handlerA },
    });

    var req = try zix.Http.Request.fromRaw("GET /about?ref=menu HTTP/1.1\r\nHost: localhost\r\n\r\n", al);
    var res = zix.Http.Response.init(undefined, false, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    try router.dispatch(&req, &res, &ctx);
}
