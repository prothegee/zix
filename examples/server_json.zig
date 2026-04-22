const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "0.0.0.0";
const PORT: u16 = 9001;
const MAX_KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_CLIENT_REQUEST: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;

// --------------------------------------------------------- //

pub fn statusHandler(req: *zix.Request, res: *zix.Response, ctx: *zix.Context) !void {
    _ = ctx;
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }
    try res.sendJson("{\"status\":\"ok\",\"server\":\"zix\"}");
}

pub fn echoHandler(req: *zix.Request, res: *zix.Response, ctx: *zix.Context) !void {
    _ = ctx;
    const name = req.queryParam("name") orelse "world";
    var buf: [256]u8 = undefined;
    const body = try std.fmt.bufPrint(&buf, "{{\"hello\":\"{s}\"}}", .{name});
    try res.sendJson(body);
}

pub fn postHandler(req: *zix.Request, res: *zix.Response, ctx: *zix.Context) !void {
    _ = ctx;
    if (req.method() != .POST) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try res.sendJson("{\"error\":\"method not allowed\"}");
        return;
    }
    const body = try req.body();
    var buf: [512]u8 = undefined;
    const reply = try std.fmt.bufPrint(&buf, "{{\"received\":{d}}}", .{body.len});
    try res.sendJson(reply);
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var server = try zix.HttpServer.init(.{
        .io = process.io,
        .allocator = arena.allocator(),
        .ip = IP,
        .port = PORT,
        .max_kernel_backlog = MAX_KERNEL_BACKLOG,
        .max_client_request = MAX_CLIENT_REQUEST,
        .max_allocator_size = MAX_ALLOCATOR_SIZE,
        .max_client_response = MAX_CLIENT_RESPONSE,
    });
    defer server.deinit();

    server.registerHandler("/status", statusHandler);
    server.registerHandler("/echo", echoHandler);
    server.registerHandler("/post", postHandler);

    try server.run();
}
