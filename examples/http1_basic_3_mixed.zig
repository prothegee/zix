const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9100;
const WORKERS: usize = 0; // 0 = cpu_count accept threads (each dispatches via io.async)

// --------------------------------------------------------- //

// curl usage: curl -X GET "http://localhost:9100/"
fn homeHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.writeSimple(fd, 200, "text/plain", "Hello, World!") catch {};
}

// curl usage: curl -X GET "http://localhost:9100/echo"
fn echoHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.writeJson(fd, 200, "{\"status\":\"ok\"}") catch {};
}

// curl usage: curl -X GET "http://localhost:9100/about"
fn aboutHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    zix.Http1.writeSimple(fd, 200, "text/plain", "zix http1 basic server example") catch {};
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/echo", .handler = echoHandler },
    .{ .path = "/about", .handler = aboutHandler },
});

pub fn main(process: std.process.Init) !void {
    var server = zix.Http1.Server.init(.{
        .io = process.io,
        .ip = IP,
        .port = PORT,
        .dispatch_model = .MIXED,
        .workers = WORKERS,
    });
    defer server.deinit();

    try server.run(Routes.dispatch);
}
