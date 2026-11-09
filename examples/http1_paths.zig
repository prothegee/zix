//! ZIX example http1 paths
//!
//! ### file: examples/http1_paths.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! Http1 server example that routes paths with the .PARAM and .PREFIX route kinds.
//!
//! ### note:
//!
//! Router priority is EXACT, then PARAM (first registered wins), then PREFIX
//! (longest wins). /path/user/:id is registered before the tenant route, so
//! /path/user/alice reaches userHandler.
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
const PORT:u16 = 9023;
const WORKERS:usize = 0;
const KERNEL_BACKLOG:u31 = 1024;
const DISPATCH_MODEL:zix.Http1.DispatchModel = .ASYNC;

const MAX_PATH_SEGMENTS:usize = 9;

// --------------------------------------------------------- //

// Collect path segments from path, without the leading '/'.
// Return the count written into out.
fn splitSegments(path: []const u8, out: [][]const u8) usize {
    const stripped = if (std.mem.startsWith(u8, path, "/")) path[1..] else path;
    if (stripped.len == 0) return 0;

    var segments = std.mem.splitScalar(u8, stripped, '/');
    var count: usize = 0;
    while (segments.next()) |segment| {
        if (count >= out.len) break;

        out[count] = segment;
        count += 1;
    }

    return count;
}

// --------------------------------------------------------- //

// GET /path (PREFIX route)
// GET /path/<seg1>
// GET /path/<seg1>/<seg2>/<seg3>
// ... up to MAX_PATH_SEGMENTS segments after /path
// Exactly 2 segments after /path match a PARAM route first.
// More than MAX_PATH_SEGMENTS -> 404
//
// curl usage: curl -X GET "http://localhost:9023/path"
// curl usage: curl -X GET "http://localhost:9023/path/hello"
// curl usage: curl -X GET "http://localhost:9023/path/hello/big/world"
fn pathsHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    var segments: [MAX_PATH_SEGMENTS + 2][]const u8 = undefined;
    const count = splitSegments(req.path(), &segments);

    // segments[0] is "path", the sub path starts at segments[1].
    const sub_count = if (count > 0) count - 1 else 0;

    if (sub_count > MAX_PATH_SEGMENTS) {
        res.setStatus(.NOT_FOUND);

        try res.sendJson("{\"message\":\"Error: too many path segments\",\"max\":9}");
        return;
    }

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(std.heap.smp_allocator);

    var head_buf: [256]u8 = undefined;
    const head = try std.fmt.bufPrint(
        &head_buf,
        "{{\"path\":\"{s}\",\"segments\":[",
        .{req.path()},
    );
    try json.appendSlice(std.heap.smp_allocator, head);

    for (segments[1..count], 0..) |segment, i| {
        if (i > 0) try json.append(std.heap.smp_allocator, ',');

        var segment_buf: [128]u8 = undefined;
        const segment_json = try std.fmt.bufPrint(&segment_buf, "\"{s}\"", .{segment});
        try json.appendSlice(std.heap.smp_allocator, segment_json);
    }

    var tail_buf: [32]u8 = undefined;
    const tail = try std.fmt.bufPrint(&tail_buf, "],\"count\":{d}}}", .{sub_count});
    try json.appendSlice(std.heap.smp_allocator, tail);

    try res.sendJson(json.items);
}

// GET /path/user/:id (PARAM route)
//
// curl usage: curl -X GET "http://localhost:9023/path/user/alice"
// curl usage: curl -X GET "http://localhost:9023/path/user/123"
fn userHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
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
    const json = try std.fmt.bufPrint(
        &buf,
        "{{\"path\":\"{s}\",\"id\":\"{s}\"}}",
        .{ req.path(), id },
    );

    try res.sendJson(json);
}

// GET /path/:tenant-id/:tenant-branch (PARAM route)
// Matches /path/<seg1>/<seg2> when /path/user/:id did not match first.
//
// curl usage: curl -X GET "http://localhost:9023/path/acme/main"
// curl usage: curl -X GET "http://localhost:9023/path/acme/dev"
// curl usage: curl -X GET "http://localhost:9023/path/user/alice"  (-> userHandler)
fn tenantHandler(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    _: *zix.Http1.Context,
) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const tenant_id = req.pathParam("tenant-id") orelse "";
    const tenant_branch = req.pathParam("tenant-branch") orelse "";

    var buf: [512]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &buf,
        "{{\"path\":\"{s}\",\"tenant-id\":\"{s}\",\"tenant-branch\":\"{s}\"}}",
        .{ req.path(), tenant_id, tenant_branch },
    );

    try res.sendJson(json);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{
        .path = "/path/user/:id",
        .handler = userHandler,
        .kind = .PARAM,
    },
    .{
        .path = "/path/:tenant-id/:tenant-branch",
        .handler = tenantHandler,
        .kind = .PARAM,
    },
    .{
        .path = "/path",
        .handler = pathsHandler,
        .kind = .PREFIX,
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

