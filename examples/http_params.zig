const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9004;
const MAX_KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_CLIENT_REQUEST: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;
const WORKERS: usize = 0; // 0 = auto (2 accept threads)
const POOL_SIZE: usize = 0; // 0 = auto (max(10, cpu_count * 2) pool threads)

// --------------------------------------------------------- //

const SimpleResponse = struct {
    ok: bool,
    message: []const u8,
};

fn sendResponse(res: *zix.Http.Response, allocator: std.mem.Allocator, response: SimpleResponse) !void {
    const json_bytes = try std.json.Stringify.valueAlloc(allocator, response, .{});
    try res.sendJson(json_bytes);
}

// --------------------------------------------------------- //

// GET /echo
// Echoes all query params as a JSON object.
// /echo?foo=bar&baz=qux  ->  {"foo":"bar","baz":"qux"}
// /echo                  ->  null
// /echo?flag             ->  {"flag":null}
// curl usage: curl -X GET "http://localhost:9004/echo?foo=bar&baz=qux"
pub fn echoHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }

    const params = try req.queryParams(ctx.allocator);
    if (params.len == 0) {
        try res.sendJson("null");
        return;
    }

    var buf: std.ArrayList(u8) = .empty;
    try buf.append(ctx.allocator, '{');
    for (params, 0..) |p, i| {
        if (i > 0) try buf.appendSlice(ctx.allocator, ",");
        try buf.append(ctx.allocator, '"');
        try buf.appendSlice(ctx.allocator, p.key);
        try buf.appendSlice(ctx.allocator, "\":");
        if (p.value) |v| {
            try buf.append(ctx.allocator, '"');
            try buf.appendSlice(ctx.allocator, v);
            try buf.append(ctx.allocator, '"');
        } else {
            try buf.appendSlice(ctx.allocator, "null");
        }
    }
    try buf.append(ctx.allocator, '}');
    try res.sendJson(buf.items);
}

// GET /greet?name=<value>
// /greet?name=alice  ->  {"ok":true,"message":"hello, alice"}
// /greet             ->  {"ok":false,"message":"Error: missing required param: name"}
// curl usage: curl -X GET "http://localhost:9004/greet?name=alice"
pub fn greetHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try sendResponse(res, ctx.allocator, .{ .ok = false, .message = "Error: method not allowed" });
        return;
    }

    const name = req.queryParam("name") orelse {
        res.setStatus(.BAD_REQUEST);
        try sendResponse(res, ctx.allocator, .{ .ok = false, .message = "Error: missing required param: name" });
        return;
    };

    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "hello, {s}", .{name});
    try sendResponse(res, ctx.allocator, .{ .ok = true, .message = msg });
}

// GET /calc?a=<num>&b=<num>
// /calc?a=3&b=4   ->  {"ok":true,"message":"3 + 4 = 7"}
// /calc?b=4       ->  {"ok":false,"message":"Error: missing required param: a"}
// /calc?a=foo&b=4 ->  {"ok":false,"message":"Error: a must be a number"}
// curl usage: curl -X GET "http://localhost:9004/calc?a=3&b=4"
pub fn calcHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try sendResponse(res, ctx.allocator, .{ .ok = false, .message = "Error: method not allowed" });
        return;
    }

    const a_str = req.queryParam("a") orelse {
        res.setStatus(.BAD_REQUEST);
        try sendResponse(res, ctx.allocator, .{ .ok = false, .message = "Error: missing required param: a" });
        return;
    };
    const b_str = req.queryParam("b") orelse {
        res.setStatus(.BAD_REQUEST);
        try sendResponse(res, ctx.allocator, .{ .ok = false, .message = "Error: missing required param: b" });
        return;
    };

    const a = std.fmt.parseInt(i64, a_str, 10) catch {
        res.setStatus(.BAD_REQUEST);
        try sendResponse(res, ctx.allocator, .{ .ok = false, .message = "Error: a must be a number" });
        return;
    };
    const b = std.fmt.parseInt(i64, b_str, 10) catch {
        res.setStatus(.BAD_REQUEST);
        try sendResponse(res, ctx.allocator, .{ .ok = false, .message = "Error: b must be a number" });
        return;
    };

    var buf: [64]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "{d} + {d} = {d}", .{ a, b, a + b });
    try sendResponse(res, ctx.allocator, .{ .ok = true, .message = msg });
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var server = try zix.Http.Server.init(4096, .{
        .io = process.io,
        .allocator = arena.allocator(),
        .ip = IP,
        .port = PORT,
        .max_kernel_backlog = MAX_KERNEL_BACKLOG,
        .max_client_request = MAX_CLIENT_REQUEST,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
        .workers = WORKERS,
        .pool_size = POOL_SIZE,
    });
    defer server.deinit();

    server.registerHandler("/echo", echoHandler);
    server.registerHandler("/greet", greetHandler);
    server.registerHandler("/calc", calcHandler);

    try server.run();
}
