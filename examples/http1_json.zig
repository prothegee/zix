const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9020;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .POOL;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
const WORKERS: usize = 0; // 0 = cpu_count accept threads
const POOL_SIZE: usize = 0; // 0 = max(10, cpu_count * 2) pool threads

// --------------------------------------------------------- //

const User = struct {
    name: []const u8,
    age: u16,
};

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9020/status"
fn statusHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"ok\":false,\"message\":\"method not allowed\"}");
        return;
    }

    try res.sendJson("{\"ok\":true,\"message\":\"\",\"data\":{\"server\":\"zix\"}}");
}

// curl usage: curl -X GET "http://localhost:9020/echo?name=Alice"
fn echoHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    const name = req.queryParam("name") orelse "world";

    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"message\":\"\",\"data\":{{\"hello\":\"{s}\"}}}}", .{name}) catch return;

    try res.sendJson(json);
}

// curl usage: curl -X POST "http://localhost:9020/post" -d "hello"
fn postHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    if (req.method() != .POST) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"ok\":false,\"message\":\"method not allowed\"}");
        return;
    }

    var buf: [128]u8 = undefined;
    const body = try req.body();
    const json = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"message\":\"\",\"data\":{{\"received\":{d}}}}}", .{body.len}) catch return;

    try res.sendJson(json);
}

// curl usage: curl -X POST "http://localhost:9020/user" -H "Content-Type: application/json" -d '{"name":"Alice","age":30}'
fn userHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, ctx: *zix.Http1.Context) !void {
    if (req.method() != .POST) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"ok\":false,\"message\":\"method not allowed\"}");
        return;
    }

    const body = try req.body();
    if (body.len == 0) {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"empty body\"}");
        return;
    }

    // ctx.allocator is the per-request arena: freed automatically at the next
    // request, so a handler-scoped parse needs no manual teardown on the hot path.
    const parsed = std.json.parseFromSlice(
        User,
        ctx.allocator,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"invalid json\"}");
        return;
    };

    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(
        &buf,
        "{{\"ok\":true,\"message\":\"\",\"data\":{{\"name\":\"{s}\",\"age\":{d}}}}}",
        .{ parsed.value.name, parsed.value.age },
    ) catch return;

    try res.sendJson(json);
}

// curl usage: curl -X GET "http://localhost:9020/users"
fn usersHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"ok\":false,\"message\":\"method not allowed\"}");
        return;
    }

    const payload =
        "{\"ok\":true,\"message\":\"\",\"data\":[" ++
        "{\"name\":\"Alice\",\"age\":30}," ++
        "{\"name\":\"Bob\",\"age\":25}," ++
        "{\"name\":\"Carol\",\"age\":28}" ++
        "]}";

    try res.sendJson(payload);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/status", .handler = statusHandler },
    .{ .path = "/echo", .handler = echoHandler },
    .{ .path = "/post", .handler = postHandler },
    .{ .path = "/user", .handler = userHandler },
    .{ .path = "/users", .handler = usersHandler },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = DISPATCH_MODEL,
        .kernel_backlog = KERNEL_BACKLOG,
        .max_recv_buf = MAX_RECV_BUF,
        .compression_max_out = COMPRESSION_MAX_OUT,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run();
}
