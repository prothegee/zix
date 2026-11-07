//! ZIX example http1 params
//!
//! ### file: examples/http1_params.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example that reads query parameters.
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

// --------------------------------------------------------- //

const IP:[]const u8 = "127.0.0.1";
const PORT:u16 = 9022;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const DISPATCH_MODEL:zix.Http1.DispatchModel = .ASYNC;

// --------------------------------------------------------- //

// GET /echo
// Echoes all query params as a JSON object.
// /echo?foo=bar&baz=qux  ->  {"foo":"bar","baz":"qux"}
// /echo                  ->  null
// curl usage: curl -X GET "http://localhost:9022/echo?foo=bar&baz=qux"
fn echoHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const query = req.query();
    if (query.len == 0) {
        try res.sendJson("null");
        return;
    }

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(std.heap.smp_allocator);

    try json.append(std.heap.smp_allocator, '{');

    var first = true;
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) continue;

        if (!first) try json.append(std.heap.smp_allocator, ',');
        first = false;

        var entry_buf: [512]u8 = undefined;
        const entry = if (std.mem.indexOfScalar(u8, pair, '=')) |eq_pos|
            try std.fmt.bufPrint(
                &entry_buf,
                "\"{s}\":\"{s}\"",
                .{ pair[0..eq_pos], pair[eq_pos + 1 ..] },
            )
        else
            try std.fmt.bufPrint(&entry_buf, "\"{s}\":null", .{pair});

        try json.appendSlice(std.heap.smp_allocator, entry);
    }

    try json.append(std.heap.smp_allocator, '}');

    try res.sendJson(json.items);
}

// GET /greet?name=<value>
// /greet?name=alice  ->  {"ok":true,"message":"hello, alice"}
// /greet             ->  {"ok":false,"message":"Error: missing required param: name"}
// curl usage: curl -X GET "http://localhost:9022/greet?name=alice"
fn greetHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"ok\":false,\"message\":\"Error: method not allowed\"}");
        return;
    }

    const name = req.queryParam("name") orelse {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"Error: missing required param: name\"}");
        return;
    };

    var buf: [256]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &buf,
        "{{\"ok\":true,\"message\":\"hello, {s}\"}}",
        .{name},
    );

    try res.sendJson(json);
}

// GET /calc?a=<num>&b=<num>
// /calc?a=3&b=4   ->  {"ok":true,"message":"3 + 4 = 7"}
// /calc?b=4       ->  {"ok":false,"message":"Error: missing required param: a"}
// /calc?a=foo&b=4 ->  {"ok":false,"message":"Error: a must be a number"}
// /calc?a=9223372036854775807&b=1 ->  {"ok":false,"message":"Error: a + b is out of range"}
// curl usage: curl -X GET "http://localhost:9022/calc?a=3&b=4"
fn calcHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"ok\":false,\"message\":\"Error: method not allowed\"}");
        return;
    }

    const left_text = req.queryParam("a") orelse {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"Error: missing required param: a\"}");
        return;
    };
    const right_text = req.queryParam("b") orelse {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"Error: missing required param: b\"}");
        return;
    };

    const left = std.fmt.parseInt(i64, left_text, 10) catch {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"Error: a must be a number\"}");
        return;
    };
    const right = std.fmt.parseInt(i64, right_text, 10) catch {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"Error: b must be a number\"}");
        return;
    };

    const sum = std.math.add(i64, left, right) catch {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"Error: a + b is out of range\"}");
        return;
    };

    var buf: [128]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &buf,
        "{{\"ok\":true,\"message\":\"{d} + {d} = {d}\"}}",
        .{ left, right, sum },
    );

    try res.sendJson(json);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{
        .path = "/echo",
        .handler = echoHandler,
    },
    .{
        .path = "/greet",
        .handler = greetHandler,
    },
    .{
        .path = "/calc",
        .handler = calcHandler,
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

