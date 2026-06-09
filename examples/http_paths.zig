const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9005;
const DISPATCH_MODEL: zix.Http.DispatchModel = .POOL;
const KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_RECV_BUF: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;
const WORKERS: usize = 0; // 0 = auto (cpu_count accept threads)
const POOL_SIZE: usize = 0; // 0 = auto (max(10, cpu_count * 2) pool threads)

const MAX_PATH_SEGMENTS: usize = 9;

// --------------------------------------------------------- //

// GET /path
// GET /path/<seg1>
// GET /path/<seg1>/<seg2>
// ... up to MAX_PATH_SEGMENTS segments after /path
// More than MAX_PATH_SEGMENTS -> 404
// Note: /path/user/:id is handled by userHandler below (param beats prefix)
//
// curl usage: curl -X GET "http://localhost:9005/path"
// curl usage: curl -X GET "http://localhost:9005/path/hello"
// curl usage: curl -X GET "http://localhost:9005/path/hello/world"
// curl usage: curl -X GET "http://localhost:9005/path/a/b/c/d/e/f/g/h/i"
// curl usage: curl -X GET "http://localhost:9005/path/a/b/c/d/e/f/g/h/i/j"  (-> 404)
pub fn pathsHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const all_segments = try req.pathSegments(ctx.allocator);

    // Skip the leading "path" segment — it is always present because we are
    // registered under the /path prefix.
    const subpath = if (all_segments.len > 0) all_segments[1..] else all_segments;

    if (subpath.len > MAX_PATH_SEGMENTS) {
        res.setStatus(.NOT_FOUND);
        try res.sendJson("{\"message\":\"Error: too many path segments\",\"max\":9}");
        return;
    }

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(ctx.allocator, "{\"path\":\"");
    try buf.appendSlice(ctx.allocator, req.path());
    try buf.appendSlice(ctx.allocator, "\",\"segments\":[");
    for (subpath, 0..) |seg, i| {
        if (i > 0) try buf.appendSlice(ctx.allocator, ",");
        try buf.append(ctx.allocator, '"');
        try buf.appendSlice(ctx.allocator, seg);
        try buf.append(ctx.allocator, '"');
    }
    try buf.appendSlice(ctx.allocator, "],\"count\":");
    var count_buf: [4]u8 = undefined;
    const count_str = try std.fmt.bufPrint(&count_buf, "{d}", .{subpath.len});
    try buf.appendSlice(ctx.allocator, count_str);
    try buf.append(ctx.allocator, '}');

    try res.sendJson(buf.items);
}

// GET /path/user/:id
// Demonstrates registerParamHandler — :id is captured and returned in the response.
// Priority: param beats prefix, so this wins over pathsHandler for /path/user/<anything>.
//
// curl usage: curl -X GET "http://localhost:9005/path/user/alice"
// curl usage: curl -X GET "http://localhost:9005/path/user/123"
pub fn userHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = ctx;
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const id = req.pathParam("id") orelse {
        res.setStatus(.BAD_REQUEST);
        try res.sendJson("{\"error\":\"missing path param: id\"}");
        return;
    };

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(
        &buf,
        "{{\"path\":\"{s}\",\"id\":\"{s}\"}}",
        .{ req.path(), id },
    );
    try res.sendJson(msg);
}

// GET /path/:tenant-id/:tenant-branch
// Demonstrates hyphenated param names.
// Hyphens are valid in param names — the name is everything after ':' until the next '/'.
//
// IMPORTANT registration order: within param routes, first-registered wins when two
// patterns have the same segment count. Register more-literal patterns first so they
// take priority over all-param patterns of the same depth.
//   /path/user/:id         registered 1st -> wins for /path/user/<anything>
//   /path/:tenant-id/:tenant-branch  registered 2nd -> wins for /path/<non-user>/<anything>
//
// curl usage: curl -X GET "http://localhost:9005/path/acme/main"
// curl usage: curl -X GET "http://localhost:9005/path/acme/dev"
// curl usage: curl -X GET "http://localhost:9005/path/user/alice"   (-> userHandler, not here)
pub fn tenantHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    _ = ctx;
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const tenant_id = req.pathParam("tenant-id") orelse {
        res.setStatus(.BAD_REQUEST);
        try res.sendJson("{\"error\":\"missing path param: tenant-id\"}");
        return;
    };
    const tenant_branch = req.pathParam("tenant-branch") orelse {
        res.setStatus(.BAD_REQUEST);
        try res.sendJson("{\"error\":\"missing path param: tenant-branch\"}");
        return;
    };

    var buf: [512]u8 = undefined;
    const msg = try std.fmt.bufPrint(
        &buf,
        "{{\"path\":\"{s}\",\"tenant-id\":\"{s}\",\"tenant-branch\":\"{s}\"}}",
        .{ req.path(), tenant_id, tenant_branch },
    );
    try res.sendJson(msg);
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    // Param routes: more-literal patterns first, all-param patterns after.
    var server = try zix.Http.Server.init(4096, &[_]zix.Http.Route{
        .{ .path = "/path/user/:id", .handler = userHandler, .kind = .PARAM },
        .{ .path = "/path/:tenant-id/:tenant-branch", .handler = tenantHandler, .kind = .PARAM },
        .{ .path = "/path", .handler = pathsHandler, .kind = .PREFIX },
    }, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
