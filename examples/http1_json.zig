const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9101;
const WORKERS: usize = 0;
const POOL_SIZE: usize = 0;

// --------------------------------------------------------- //

const User = struct {
    name: []const u8,
    age: u16,
};

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9101/status"
fn statusHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    if (!std.mem.eql(u8, head.method, "GET")) {
        zix.Http1.writeJson(fd, 405, "{\"ok\":false,\"message\":\"method not allowed\"}") catch {};
        return;
    }

    zix.Http1.writeJson(fd, 200, "{\"ok\":true,\"message\":\"\",\"data\":{\"server\":\"zix\"}}") catch {};
}

// curl usage: curl -X GET "http://localhost:9101/echo?name=Alice"
fn echoHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    const name = zix.Http1.queryParam(head, "name") orelse "world";

    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"message\":\"\",\"data\":{{\"hello\":\"{s}\"}}}}", .{name}) catch return;
    zix.Http1.writeJson(fd, 200, json) catch {};
}

// curl usage: curl -X POST "http://localhost:9101/post" -d "hello"
fn postHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    if (!std.mem.eql(u8, head.method, "POST")) {
        zix.Http1.writeJson(fd, 405, "{\"ok\":false,\"message\":\"method not allowed\"}") catch {};
        return;
    }

    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"message\":\"\",\"data\":{{\"received\":{d}}}}}", .{body.len}) catch return;
    zix.Http1.writeJson(fd, 200, json) catch {};
}

// curl usage: curl -X POST "http://localhost:9101/user" -H "Content-Type: application/json" -d '{"name":"Alice","age":30}'
fn userHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    if (!std.mem.eql(u8, head.method, "POST")) {
        zix.Http1.writeJson(fd, 405, "{\"ok\":false,\"message\":\"method not allowed\"}") catch {};
        return;
    }

    if (body.len == 0) {
        zix.Http1.writeJson(fd, 400, "{\"ok\":false,\"message\":\"empty body\"}") catch {};
        return;
    }

    const parsed = std.json.parseFromSlice(
        User,
        std.heap.smp_allocator,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch {
        zix.Http1.writeJson(fd, 400, "{\"ok\":false,\"message\":\"invalid json\"}") catch {};
        return;
    };
    defer parsed.deinit();

    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(
        &buf,
        "{{\"ok\":true,\"message\":\"\",\"data\":{{\"name\":\"{s}\",\"age\":{d}}}}}",
        .{ parsed.value.name, parsed.value.age },
    ) catch return;
    zix.Http1.writeJson(fd, 200, json) catch {};
}

// curl usage: curl -X GET "http://localhost:9101/users"
fn usersHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    if (!std.mem.eql(u8, head.method, "GET")) {
        zix.Http1.writeJson(fd, 405, "{\"ok\":false,\"message\":\"method not allowed\"}") catch {};
        return;
    }

    const payload =
        "{\"ok\":true,\"message\":\"\",\"data\":[" ++
        "{\"name\":\"Alice\",\"age\":30}," ++
        "{\"name\":\"Bob\",\"age\":25}," ++
        "{\"name\":\"Carol\",\"age\":28}" ++
        "]}";
    zix.Http1.writeJson(fd, 200, payload) catch {};
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/status", .handler = statusHandler },
    .{ .path = "/echo", .handler = echoHandler },
    .{ .path = "/post", .handler = postHandler },
    .{ .path = "/user", .handler = userHandler },
    .{ .path = "/users", .handler = usersHandler },
});

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

    try server.run(Routes.dispatch);
}
