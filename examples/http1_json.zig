//! ZIX example http1 json
//!
//! ### file: examples/http1_json.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example that answers and parses JSON with std.json.
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
const zix = @import("zix");

const builtin = @import("builtin");

// --------------------------------------------------------- //

const IP:[]const u8 = "127.0.0.1";
const PORT:u16 = 9020;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const DISPATCH_MODEL:zix.Http1.DispatchModel =
    if (builtin.os.tag == .linux) .URING else .ASYNC;

// --------------------------------------------------------- //

const User = struct {
    name: []const u8,
    age: u16,
};

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9020/status"
fn statusHandler(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    _: *zix.Http1.Context,
) !void {
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
    const json = try std.fmt.bufPrint(
        &buf,
        "{{\"ok\":true,\"message\":\"\",\"data\":{{\"hello\":\"{s}\"}}}}",
        .{name},
    );

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
    const body = req.body();
    const json = try std.fmt.bufPrint(
        &buf,
        "{{\"ok\":true,\"message\":\"\",\"data\":{{\"received\":{d}}}}}",
        .{body.len},
    );

    try res.sendJson(json);
}

// curl usage:
// curl -X POST "http://localhost:9020/user" -H "Content-Type: application/json" \
//     -d '{"name":"Alice","age":30}'
fn userHandler(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) !void {
    if (req.method() != .POST) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"ok\":false,\"message\":\"method not allowed\"}");
        return;
    }

    const body = req.body();
    if (body.len == 0) {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"empty body\"}");
        return;
    }

    // ctx.allocator is the per-request scratch, reset by the engine after the
    // request, so a handler-scoped parse needs no manual teardown.
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
    const json = try std.fmt.bufPrint(
        &buf,
        "{{\"ok\":true,\"message\":\"\",\"data\":{{\"name\":\"{s}\",\"age\":{d}}}}}",
        .{ parsed.value.name, parsed.value.age },
    );

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
    .{
        .path = "/status",
        .handler = statusHandler,
    },
    .{
        .path = "/echo",
        .handler = echoHandler,
    },
    .{
        .path = "/post",
        .handler = postHandler,
    },
    .{
        .path = "/user",
        .handler = userHandler,
    },
    .{
        .path = "/users",
        .handler = usersHandler,
    },
});

pub fn main(init: std.process.Init) !void {
    var server = zix.Http1.Server.init(Routes.dispatch, .{
        .io = init.io,
        .ip = IP,
        .port = PORT,
        .workers = WORKERS,
        .kernel_backlog = KERNEL_BACKLOG,
        .dispatch_model = DISPATCH_MODEL,
    });
    defer server.deinit();

    try server.run();
}

