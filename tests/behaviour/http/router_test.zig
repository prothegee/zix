//! Behaviour tests: router dispatch priority and query-string transparency.
//! Verifies the contracts callers rely on: exact > param > prefix priority,
//! longest prefix wins, and query strings are ignored during path matching.

const std = @import("std");
const zix = @import("zix");

fn makeInner(method_: std.http.Method, target_: []const u8) std.http.Server.Request {
    return .{
        .server = undefined,
        .head = .{
            .method = method_,
            .target = target_,
            .version = .@"HTTP/1.1",
            .expect = null,
            .content_type = null,
            .content_length = null,
            .transfer_encoding = .none,
            .transfer_compression = .identity,
            .keep_alive = true,
        },
        .head_buffer = undefined,
        .respond_err = null,
    };
}

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
    var server = try zix.Http.Server.init(4096, .{ .io = undefined, .allocator = al, .ip = "127.0.0.1", .port = 9000 });
    defer server.deinit();
    server.registerParamHandler("/users/:id", handlerB);
    server.registerHandler("/users/alice", handlerA);

    var inner = makeInner(.GET, "/users/alice");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    last_handler = "";
    _ = try server.router.dispatch(&req, &res, &ctx);
    try std.testing.expectEqualStrings("A", last_handler);
}

test "zix behaviour: dispatch, param beats prefix regardless of registration order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var server = try zix.Http.Server.init(4096, .{ .io = undefined, .allocator = al, .ip = "127.0.0.1", .port = 9000 });
    defer server.deinit();
    server.registerPrefixHandler("/api", handlerB);
    server.registerParamHandler("/api/:resource", handlerA);

    var inner = makeInner(.GET, "/api/users");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    last_handler = "";
    _ = try server.router.dispatch(&req, &res, &ctx);
    try std.testing.expectEqualStrings("A", last_handler);
}

test "zix behaviour: dispatch, prefix: longest match wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var server = try zix.Http.Server.init(4096, .{ .io = undefined, .allocator = al, .ip = "127.0.0.1", .port = 9000 });
    defer server.deinit();
    server.registerPrefixHandler("/api", handlerB);
    server.registerPrefixHandler("/api/users", handlerA);

    var inner = makeInner(.GET, "/api/users/alice");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    last_handler = "";
    _ = try server.router.dispatch(&req, &res, &ctx);
    try std.testing.expectEqualStrings("A", last_handler);
}

test "zix behaviour: dispatch, prefix matches its own path exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var server = try zix.Http.Server.init(4096, .{ .io = undefined, .allocator = al, .ip = "127.0.0.1", .port = 9000 });
    defer server.deinit();
    server.registerPrefixHandler("/api", handlerA);

    var inner = makeInner(.GET, "/api");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    last_handler = "";
    try std.testing.expect(try server.router.dispatch(&req, &res, &ctx));
    try std.testing.expectEqualStrings("A", last_handler);
}

test "zix behaviour: dispatch, query string transparent to path matching (param)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var server = try zix.Http.Server.init(4096, .{ .io = undefined, .allocator = al, .ip = "127.0.0.1", .port = 9000 });
    defer server.deinit();
    server.registerParamHandler("/users/:id", handlerA);

    var inner = makeInner(.GET, "/users/bob?role=admin");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    try std.testing.expect(try server.router.dispatch(&req, &res, &ctx));
    try std.testing.expectEqualStrings("bob", req.path_params[0].value);
}

test "zix behaviour: dispatch, query string transparent to path matching (exact)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();
    var server = try zix.Http.Server.init(4096, .{ .io = undefined, .allocator = al, .ip = "127.0.0.1", .port = 9000 });
    defer server.deinit();
    server.registerHandler("/about", handlerA);

    var inner = makeInner(.GET, "/about?ref=menu");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    try std.testing.expect(try server.router.dispatch(&req, &res, &ctx));
}
