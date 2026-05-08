//! Integration tests: router dispatch via zix.Http.Server public API.
//! Covers dispatch behavior not tested in src/tcp/http/router.zig unit tests:
//!   - dispatch returns true/false
//!   - exact > param > prefix priority (independent of registration order)
//!   - prefix: longest match wins
//!   - prefix: boundary check ("/api" does not match "/apiv2")
//!   - param dispatch: path_params populated on the request

const std = @import("std");
const zix = @import("zix");

// --------------------------------------------------------- //

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

// --------------------------------------------------------- //
// Mock handlers — do not call send(), only record which one ran.

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

test "zix integration: dispatch — exact match returns true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var server = try zix.Http.Server.init(4096, .{
        .io = undefined,
        .allocator = al,
        .ip = "127.0.0.1",
        .port = 9000,
    });
    defer server.deinit();
    server.registerHandler("/about", handlerA);

    var inner = makeInner(.GET, "/about");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    last_handler = "";
    const matched = try server.router.dispatch(&req, &res, &ctx);
    try std.testing.expect(matched);
    try std.testing.expectEqualStrings("A", last_handler);
}

test "zix integration: dispatch — no match returns false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var server = try zix.Http.Server.init(4096, .{
        .io = undefined,
        .allocator = al,
        .ip = "127.0.0.1",
        .port = 9000,
    });
    defer server.deinit();
    server.registerHandler("/about", handlerA);

    var inner = makeInner(.GET, "/contact");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    const matched = try server.router.dispatch(&req, &res, &ctx);
    try std.testing.expect(!matched);
}

test "zix integration: dispatch — exact beats param regardless of registration order" {
    // Register param first, then exact. Exact must still win for /path/user/alice.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var server = try zix.Http.Server.init(4096, .{
        .io = undefined,
        .allocator = al,
        .ip = "127.0.0.1",
        .port = 9000,
    });
    defer server.deinit();
    server.registerParamHandler("/path/user/:id", handlerB); // registered first
    server.registerHandler("/path/user/alice", handlerA); // registered second

    var inner = makeInner(.GET, "/path/user/alice");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    last_handler = "";
    const matched = try server.router.dispatch(&req, &res, &ctx);
    try std.testing.expect(matched);
    try std.testing.expectEqualStrings("A", last_handler); // exact wins
}

test "zix integration: dispatch — param beats prefix regardless of registration order" {
    // Register prefix first, then param. Param must win for /api/users.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var server = try zix.Http.Server.init(4096, .{
        .io = undefined,
        .allocator = al,
        .ip = "127.0.0.1",
        .port = 9000,
    });
    defer server.deinit();
    server.registerPrefixHandler("/api", handlerB); // registered first
    server.registerParamHandler("/api/:resource", handlerA); // registered second

    var inner = makeInner(.GET, "/api/users");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    last_handler = "";
    const matched = try server.router.dispatch(&req, &res, &ctx);
    try std.testing.expect(matched);
    try std.testing.expectEqualStrings("A", last_handler); // param wins
}

test "zix integration: dispatch — param populates path_params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var server = try zix.Http.Server.init(4096, .{
        .io = undefined,
        .allocator = al,
        .ip = "127.0.0.1",
        .port = 9000,
    });
    defer server.deinit();
    server.registerParamHandler("/users/:id", handlerA);

    var inner = makeInner(.GET, "/users/bob");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    const matched = try server.router.dispatch(&req, &res, &ctx);
    try std.testing.expect(matched);
    try std.testing.expectEqual(@as(usize, 1), req.path_params.len);
    try std.testing.expectEqualStrings("id", req.path_params[0].name);
    try std.testing.expectEqualStrings("bob", req.path_params[0].value);
    try std.testing.expectEqualStrings("bob", req.pathParam("id").?);
}

test "zix integration: dispatch — prefix: longest match wins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var server = try zix.Http.Server.init(4096, .{
        .io = undefined,
        .allocator = al,
        .ip = "127.0.0.1",
        .port = 9000,
    });
    defer server.deinit();
    server.registerPrefixHandler("/api", handlerB); // shorter
    server.registerPrefixHandler("/api/users", handlerA); // longer

    var inner = makeInner(.GET, "/api/users/alice");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    last_handler = "";
    const matched = try server.router.dispatch(&req, &res, &ctx);
    try std.testing.expect(matched);
    try std.testing.expectEqualStrings("A", last_handler); // longer prefix wins
}

test "zix integration: dispatch — prefix boundary: /api does not match /apiv2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var server = try zix.Http.Server.init(4096, .{
        .io = undefined,
        .allocator = al,
        .ip = "127.0.0.1",
        .port = 9000,
    });
    defer server.deinit();
    server.registerPrefixHandler("/api", handlerA);

    var inner = makeInner(.GET, "/apiv2");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    const matched = try server.router.dispatch(&req, &res, &ctx);
    try std.testing.expect(!matched); // must not match: 'v' is not '/'
}

test "zix integration: dispatch — prefix matches its own path exactly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const al = arena.allocator();

    var server = try zix.Http.Server.init(4096, .{
        .io = undefined,
        .allocator = al,
        .ip = "127.0.0.1",
        .port = 9000,
    });
    defer server.deinit();
    server.registerPrefixHandler("/api", handlerA);

    var inner = makeInner(.GET, "/api");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    last_handler = "";
    const matched = try server.router.dispatch(&req, &res, &ctx);
    try std.testing.expect(matched);
    try std.testing.expectEqualStrings("A", last_handler);
}
