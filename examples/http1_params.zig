const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9022;
const DISPATCH_MODEL: zix.Http1.DispatchModel = .POOL;
const KERNEL_BACKLOG: u31 = 1024;
const MAX_RECV_BUF: usize = 16 * 1024;
const COMPRESSION_MAX_OUT: usize = 256 * 1024;
const WORKERS: usize = 0; // 0 = cpu_count accept threads
const POOL_SIZE: usize = 0; // 0 = max(10, cpu_count * 2) pool threads

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

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.smp_allocator);

    out.append(std.heap.smp_allocator, '{') catch return;
    var first = true;
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        if (!first) out.append(std.heap.smp_allocator, ',') catch return;
        first = false;

        var entry_buf: [512]u8 = undefined;
        const entry = if (std.mem.indexOfScalar(u8, pair, '=')) |eq|
            std.fmt.bufPrint(&entry_buf, "\"{s}\":\"{s}\"", .{ pair[0..eq], pair[eq + 1 ..] }) catch return
        else
            std.fmt.bufPrint(&entry_buf, "\"{s}\":null", .{pair}) catch return;
        out.appendSlice(std.heap.smp_allocator, entry) catch return;
    }
    out.append(std.heap.smp_allocator, '}') catch return;

    try res.sendJson(out.items);
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
    const json = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"message\":\"hello, {s}\"}}", .{name}) catch return;

    try res.sendJson(json);
}

// GET /calc?a=<num>&b=<num>
// /calc?a=3&b=4   ->  {"ok":true,"message":"3 + 4 = 7"}
// /calc?b=4       ->  {"ok":false,"message":"Error: missing required param: a"}
// /calc?a=foo&b=4 ->  {"ok":false,"message":"Error: a must be a number"}
// curl usage: curl -X GET "http://localhost:9022/calc?a=3&b=4"
fn calcHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);

        try res.sendJson("{\"ok\":false,\"message\":\"Error: method not allowed\"}");
        return;
    }

    const a_str = req.queryParam("a") orelse {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"Error: missing required param: a\"}");
        return;
    };
    const b_str = req.queryParam("b") orelse {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"Error: missing required param: b\"}");
        return;
    };

    const a = std.fmt.parseInt(i64, a_str, 10) catch {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"Error: a must be a number\"}");
        return;
    };
    const b = std.fmt.parseInt(i64, b_str, 10) catch {
        res.setStatus(.BAD_REQUEST);

        try res.sendJson("{\"ok\":false,\"message\":\"Error: b must be a number\"}");
        return;
    };

    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"message\":\"{d} + {d} = {d}\"}}", .{ a, b, a + b }) catch return;

    try res.sendJson(json);
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/echo", .handler = echoHandler },
    .{ .path = "/greet", .handler = greetHandler },
    .{ .path = "/calc", .handler = calcHandler },
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
