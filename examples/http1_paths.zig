const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9105;
const WORKERS: usize = 0;
const POOL_SIZE: usize = 0;

const MAX_PATH_SEGMENTS: usize = 9;

// Http1 Router is exact-match only. Path param and prefix routing is done manually
// in the dispatcher below using startsWith and splitScalar.

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
// curl usage: curl -X GET "http://localhost:9105/path"
// curl usage: curl -X GET "http://localhost:9105/path/hello"
// curl usage: curl -X GET "http://localhost:9105/path/hello/world"
fn pathsHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    if (!std.mem.eql(u8, head.method, "GET")) {
        zix.Http1.writeJson(fd, 405, "{\"error\":\"method not allowed\"}") catch {};
        return;
    }

    var segs: [MAX_PATH_SEGMENTS + 2][]const u8 = undefined;
    const count = splitSegments(head.path, &segs);
    // segs[0] == "path", subpath starts at segs[1]
    const sub_count = if (count > 0) count - 1 else 0;

    if (sub_count > MAX_PATH_SEGMENTS) {
        zix.Http1.writeJson(fd, 404, "{\"message\":\"Error: too many path segments\",\"max\":9}") catch {};
        return;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.smp_allocator);

    var hdr_buf: [256]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "{{\"path\":\"{s}\",\"segments\":[", .{head.path}) catch return;
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

    zix.Http1.writeJson(fd, 200, out.items) catch {};
}

// GET /path/user/:id
//
// curl usage: curl -X GET "http://localhost:9105/path/user/alice"
// curl usage: curl -X GET "http://localhost:9105/path/user/123"
fn userHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    if (!std.mem.eql(u8, head.method, "GET")) {
        zix.Http1.writeJson(fd, 405, "{\"error\":\"method not allowed\"}") catch {};
        return;
    }

    const prefix = "/path/user/";
    const id = if (std.mem.startsWith(u8, head.path, prefix)) head.path[prefix.len..] else "";
    if (id.len == 0) {
        zix.Http1.writeJson(fd, 400, "{\"error\":\"missing path param: id\"}") catch {};
        return;
    }

    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"path\":\"{s}\",\"id\":\"{s}\"}}", .{ head.path, id }) catch return;
    zix.Http1.writeJson(fd, 200, json) catch {};
}

// GET /path/:tenant-id/:tenant-branch
// Matches /path/<seg1>/<seg2> where seg1 != "user".
//
// curl usage: curl -X GET "http://localhost:9105/path/acme/main"
// curl usage: curl -X GET "http://localhost:9105/path/acme/dev"
// curl usage: curl -X GET "http://localhost:9105/path/user/alice"  (-> userHandler)
fn tenantHandler(head: *const zix.Http1.ParsedHead, body: []const u8, segs: []const []const u8, fd: std.posix.fd_t) void {
    _ = body;
    if (!std.mem.eql(u8, head.method, "GET")) {
        zix.Http1.writeJson(fd, 405, "{\"error\":\"method not allowed\"}") catch {};
        return;
    }

    const tenant_id = segs[1];
    const tenant_branch = segs[2];

    var buf: [512]u8 = undefined;
    const json = std.fmt.bufPrint(
        &buf,
        "{{\"path\":\"{s}\",\"tenant-id\":\"{s}\",\"tenant-branch\":\"{s}\"}}",
        .{ head.path, tenant_id, tenant_branch },
    ) catch return;
    zix.Http1.writeJson(fd, 200, json) catch {};
}

// --------------------------------------------------------- //

fn dispatch(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    var segs: [MAX_PATH_SEGMENTS + 2][]const u8 = undefined;
    const count = splitSegments(head.path, &segs);

    // /path/user/<id> — 3 segments, segs[1] == "user"
    if (count == 3 and std.mem.eql(u8, segs[1], "user")) {
        userHandler(head, body, fd);
        return;
    }

    // /path/<tenant-id>/<tenant-branch> — 3 segments, segs[1] != "user"
    if (count == 3) {
        tenantHandler(head, body, segs[0..count], fd);
        return;
    }

    // /path prefix (any other segment count)
    if (count >= 1 and std.mem.eql(u8, segs[0], "path")) {
        pathsHandler(head, body, fd);
        return;
    }

    zix.Http1.writeSimple(fd, 404, "text/plain", "Not Found") catch {};
}

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(.{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = .POOL,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    try server.run(dispatch);
}
