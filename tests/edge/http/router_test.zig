//! Edge tests: zix.Http.Router dispatch boundary conditions.
//! Verifies: no-match returns false, and a prefix does NOT match a path that
//! merely starts with the same characters but is a different segment.

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
    var server = try zix.Http.Server.init(4096, .{ .io = undefined, .allocator = al, .ip = "127.0.0.1", .port = 9000 });
    defer server.deinit();

    var inner = makeInner(.GET, "/missing");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
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
    var server = try zix.Http.Server.init(4096, .{ .io = undefined, .allocator = al, .ip = "127.0.0.1", .port = 9000 });
    defer server.deinit();
    server.registerPrefixHandler("/api", handlerA);

    var inner = makeInner(.GET, "/apiv2/resource");
    var req = zix.Http.Request{ .inner = &inner, .reader = undefined, .allocator = al };
    var res = zix.Http.Response.init(&inner, undefined, al, 32);
    var ctx = zix.Http.Context{ .io = undefined, .allocator = al };

    const matched = try server.router.dispatch(&req, &res, &ctx);
    try std.testing.expect(!matched);
}
