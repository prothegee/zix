const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "0.0.0.0";
const PORT: u16 = 9001;
const MAX_KERNEL_BACKLOG: usize = 1024 * 4;
const MAX_CLIENT_REQUEST: usize = 1024 * 4;
const MAX_ALLOCATOR_SIZE: usize = 1024 * 4;
const MAX_CLIENT_RESPONSE: usize = 1024 * 4;

// --------------------------------------------------------- //

const User = struct {
    name: []const u8,
    age: u16,
};

const ResponseData = struct {
    ok: bool,
    message: []const u8,
    data: ?std.json.Value,
};

fn sendResponse(res: *zix.Http.Response, allocator: std.mem.Allocator, response: ResponseData) !void {
    const json_bytes = try std.json.Stringify.valueAlloc(allocator, response, .{});
    try res.sendJson(json_bytes);
}

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9001/status"
pub fn statusHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try sendResponse(res, ctx.allocator, .{ .ok = false, .message = "method not allowed", .data = null });
        return;
    }

    var obj = std.json.ObjectMap{};
    try obj.put(ctx.allocator, "server", .{ .string = "zix" });
    try sendResponse(res, ctx.allocator, .{ .ok = true, .message = "", .data = .{ .object = obj } });
}

// curl usage: curl -X GET "http://localhost:9001/echo?name=Alice"
pub fn echoHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    const name = req.queryParam("name") orelse "world";

    var obj = std.json.ObjectMap{};
    try obj.put(ctx.allocator, "hello", .{ .string = name });
    try sendResponse(res, ctx.allocator, .{ .ok = true, .message = "", .data = .{ .object = obj } });
}

// curl usage: curl -X POST "http://localhost:9001/post" -d "hello"
pub fn postHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    if (req.method() != .POST) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try sendResponse(res, ctx.allocator, .{ .ok = false, .message = "method not allowed", .data = null });
        return;
    }

    const body = try req.body();

    var obj = std.json.ObjectMap{};
    try obj.put(ctx.allocator, "received", .{ .integer = @intCast(body.len) });
    try sendResponse(res, ctx.allocator, .{ .ok = true, .message = "", .data = .{ .object = obj } });
}

// curl usage: curl -X POST "http://localhost:9001/user" -H "Content-Type: application/json" -d '{"name":"Alice","age":30}'
pub fn userHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    if (req.method() != .POST) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try sendResponse(res, ctx.allocator, .{ .ok = false, .message = "method not allowed", .data = null });
        return;
    }

    const body = try req.body();
    if (body.len == 0) {
        res.setStatus(.BAD_REQUEST);
        try sendResponse(res, ctx.allocator, .{ .ok = false, .message = "empty body", .data = null });
        return;
    }

    const parsed = std.json.parseFromSliceLeaky(
        User,
        ctx.allocator,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch {
        res.setStatus(.BAD_REQUEST);
        try sendResponse(res, ctx.allocator, .{ .ok = false, .message = "invalid json", .data = null });
        return;
    };

    var obj = std.json.ObjectMap{};
    try obj.put(ctx.allocator, "name", .{ .string = parsed.name });
    try obj.put(ctx.allocator, "age", .{ .integer = @intCast(parsed.age) });
    try sendResponse(res, ctx.allocator, .{ .ok = true, .message = "", .data = .{ .object = obj } });
}

// curl usage: curl -X GET "http://localhost:9001/users"
pub fn usersHandler(req: *zix.Http.Request, res: *zix.Http.Response, ctx: *zix.Http.Context) !void {
    if (req.method() != .GET) {
        res.setStatus(.METHOD_NOT_ALLOWED);
        try sendResponse(res, ctx.allocator, .{ .ok = false, .message = "method not allowed", .data = null });
        return;
    }

    const static_users = [_]User{
        .{ .name = "Alice", .age = 30 },
        .{ .name = "Bob", .age = 25 },
        .{ .name = "Carol", .age = 28 },
    };

    var arr = std.json.Array.init(ctx.allocator);
    for (static_users) |user| {
        var obj = std.json.ObjectMap{};
        try obj.put(ctx.allocator, "name", .{ .string = user.name });
        try obj.put(ctx.allocator, "age", .{ .integer = @intCast(user.age) });
        try arr.append(.{ .object = obj });
    }
    try sendResponse(res, ctx.allocator, .{ .ok = true, .message = "", .data = .{ .array = arr } });
}

// --------------------------------------------------------- //

pub fn main(process: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var server = try zix.Http.Server.init(.{
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
    server.registerHandler("/user", userHandler);
    server.registerHandler("/users", usersHandler);

    try server.run();
}
