const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9023;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .POOL;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
const WORKERS: usize = 0; // 0 = cpu_count accept threads
const POOL_SIZE: usize = 0; // 0 = max(10, cpu_count * 2) pool threads

const MAX_PATH_SEGMENTS: usize = 9;

// This example routes manually in the dispatcher below using startsWith and
// splitScalar, to show custom matching beyond the built-in kinds. The Http1
// Router also supports .PREFIX and .PARAM directly (with zix.Http1.pathParam),
// see examples/http1_static.zig and the Routing section of the README.

// --------------------------------------------------------- //

// Collect path segments from path (strips leading '/').
// Returns the count written into out[].
fn splitSegments(path: []const u8, out: [][]const u8) usize {
    const stripped = if (std.mem.startsWith(u8, path, "/")) path[1..] else path;
    if (stripped.len == 0) return 0;

    var it = std.mem.splitScalar(u8, stripped, '/');
    var count: usize = 0;
    while (it.next()) |seg| {
        if (count >= out.len) break;
        out[count] = seg;
        count += 1;
    }

    return count;
}

// --------------------------------------------------------- //

// GET /path
// GET /path/<seg1>
// GET /path/<seg1>/<seg2>
// ... up to MAX_PATH_SEGMENTS segments after /path
// More than MAX_PATH_SEGMENTS -> 404
//
// curl usage: curl -X GET "http://localhost:9023/path"
// curl usage: curl -X GET "http://localhost:9023/path/hello"
// curl usage: curl -X GET "http://localhost:9023/path/hello/world"
fn pathsHandler(req: *zix.Http1.Request, res: *zix.Http1.Response) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    var segs: [MAX_PATH_SEGMENTS + 2][]const u8 = undefined;
    const count = splitSegments(req.path(), &segs);
    // segs[0] == "path", subpath starts at segs[1]
    const sub_count = if (count > 0) count - 1 else 0;

    if (sub_count > MAX_PATH_SEGMENTS) {
        res.setStatus(.NOT_FOUND);

        try res.sendJson("{\"message\":\"Error: too many path segments\",\"max\":9}");
        return;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.smp_allocator);

    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "{{\"path\":\"{s}\",\"segments\":[", .{req.path()}) catch return;
    out.appendSlice(std.heap.smp_allocator, hdr) catch return;

    for (segs[1..count], 0..) |seg, i| {
        if (i > 0) out.append(std.heap.smp_allocator, ',') catch return;
        var seg_buf: [128]u8 = undefined;
        const seg_json = std.fmt.bufPrint(&seg_buf, "\"{s}\"", .{seg}) catch return;
        out.appendSlice(std.heap.smp_allocator, seg_json) catch return;
    }

    var tail_buf: [32]u8 = undefined;
    const tail = std.fmt.bufPrint(&tail_buf, "],\"count\":{d}}}", .{sub_count}) catch return;
    out.appendSlice(std.heap.smp_allocator, tail) catch return;

    try res.sendJson(out.items);
}

// GET /path/user/:id
//
// curl usage: curl -X GET "http://localhost:9023/path/user/alice"
// curl usage: curl -X GET "http://localhost:9023/path/user/123"
fn userHandler(req: *zix.Http1.Request, res: *zix.Http1.Response) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const prefix = "/path/user/";
    const id = if (std.mem.startsWith(u8, req.path(), prefix)) req.path()[prefix.len..] else "";
    if (id.len == 0) {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"error\":\"missing path param: id\"}");
        return;
    }

    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"path\":\"{s}\",\"id\":\"{s}\"}}", .{ req.path(), id }) catch return;

    try res.sendJson(json);
}

// GET /path/:tenant-id/:tenant-branch
// Matches /path/<seg1>/<seg2> where seg1 != "user".
//
// curl usage: curl -X GET "http://localhost:9023/path/acme/main"
// curl usage: curl -X GET "http://localhost:9023/path/acme/dev"
// curl usage: curl -X GET "http://localhost:9023/path/user/alice"  (-> userHandler)
fn tenantHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, segs: []const []const u8) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const tenant_id = segs[1];
    const tenant_branch = segs[2];

    var buf: [512]u8 = undefined;
    const json = std.fmt.bufPrint(
        &buf,
        "{{\"path\":\"{s}\",\"tenant-id\":\"{s}\",\"tenant-branch\":\"{s}\"}}",
        .{ req.path(), tenant_id, tenant_branch },
    ) catch return;

    try res.sendJson(json);
}

// --------------------------------------------------------- //

fn dispatch(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) anyerror!void {
    var segs: [MAX_PATH_SEGMENTS + 2][]const u8 = undefined;
    const count = splitSegments(req.path(), &segs);

    // /path/user/<id>: 3 segments, segs[1] == "user"
    if (count == 3 and std.mem.eql(u8, segs[1], "user")) {
        return userHandler(req, res);
    }

    // /path/<tenant-id>/<tenant-branch>: 3 segments, segs[1] != "user"
    if (count == 3) {
        return tenantHandler(req, res, segs[0..count]);
    }

    // /path prefix (any other segment count)
    if (count >= 1 and std.mem.eql(u8, segs[0], "path")) {
        return pathsHandler(req, res);
    }

    res.setStatus(.NOT_FOUND);
    res.setContentType(.TEXT_PLAIN);

    try res.send("Not Found");
}

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(dispatch, .{
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
