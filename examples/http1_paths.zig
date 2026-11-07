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
//! Http1 server example that routes by hand from path segments.
//!
//! ### note:
//!
//! This example routes manually in `dispatch` with startsWith and splitScalar,
//! to show custom matching beyond the built-in route kinds.
//! The Http1 Router also supports .PREFIX and .PARAM directly.
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

// GET /path
// GET /path/<seg1>
// GET /path/<seg1>/<seg2>/<seg3>
// ... up to MAX_PATH_SEGMENTS segments after /path
// Exactly 2 segments after /path go to userHandler or tenantHandler instead.
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

// GET /path/user/:id
//
// curl usage: curl -X GET "http://localhost:9023/path/user/alice"
// curl usage: curl -X GET "http://localhost:9023/path/user/123"
fn userHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const prefix = "/path/user/";
    const id = if (std.mem.startsWith(u8, req.path(), prefix))
        req.path()[prefix.len..]
    else
        "";

    if (id.len == 0) {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"missing path param: id\"}");
        return;
    }

    var buf: [256]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &buf,
        "{{\"path\":\"{s}\",\"id\":\"{s}\"}}",
        .{ req.path(), id },
    );

    try res.sendJson(json);
}

// GET /path/:tenant-id/:tenant-branch
// Matches /path/<seg1>/<seg2> where seg1 != "user".
//
// curl usage: curl -X GET "http://localhost:9023/path/acme/main"
// curl usage: curl -X GET "http://localhost:9023/path/acme/dev"
// curl usage: curl -X GET "http://localhost:9023/path/user/alice"  (-> userHandler)
fn tenantHandler(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    _: *zix.Http1.Context,
    segments: []const []const u8,
) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const tenant_id = segments[1];
    const tenant_branch = segments[2];

    var buf: [512]u8 = undefined;
    const json = try std.fmt.bufPrint(
        &buf,
        "{{\"path\":\"{s}\",\"tenant-id\":\"{s}\",\"tenant-branch\":\"{s}\"}}",
        .{ req.path(), tenant_id, tenant_branch },
    );

    try res.sendJson(json);
}

// --------------------------------------------------------- //

fn dispatch(
    req: *zix.Http1.Request,
    res: *zix.Http1.Response,
    ctx: *zix.Http1.Context,
) anyerror!void {
    var segments: [MAX_PATH_SEGMENTS + 2][]const u8 = undefined;
    const count = splitSegments(req.path(), &segments);
    const under_path = count >= 1 and std.mem.eql(u8, segments[0], "path");

    // /path/user/<id>: 3 segments, segments[1] is "user".
    if (under_path and count == 3 and std.mem.eql(u8, segments[1], "user")) {
        return userHandler(req, res, ctx);
    }

    // /path/<tenant-id>/<tenant-branch>: 3 segments, segments[1] is not "user".
    if (under_path and count == 3) {
        return tenantHandler(req, res, ctx, segments[0..count]);
    }

    // /path prefix, any other segment count.
    if (under_path) {
        return pathsHandler(req, res, ctx);
    }

    res.setStatus(.NOT_FOUND);
    res.setContentType(.TEXT_PLAIN);

    try res.send("Not Found");
}

pub fn main(init: std.process.Init) !void {
    var server = zix.Http1.Server.init(dispatch, .{
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

