//! Integration tests: zix.Http1.Router comptime dispatch and handler selection.

const std = @import("std");
const zix = @import("zix");

var last_route: []const u8 = "";

fn homeHandler(_: *zix.Http1.Request, _: *zix.Http1.Response, _: *zix.Http1.Context) anyerror!void {
    last_route = "home";
}

fn apiHandler(_: *zix.Http1.Request, _: *zix.Http1.Response, _: *zix.Http1.Context) anyerror!void {
    last_route = "api";
}

// --------------------------------------------------------- //

const TestRouter = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/", .handler = homeHandler },
    .{ .path = "/api", .handler = apiHandler },
});

fn parsedHead(raw: []const u8) zix.Http1.ParsedHead {
    return (zix.Http1.parseHead(raw) catch unreachable).head;
}

// Build the request, response, and context trio over head and fd, then dispatch.
fn dispatchReq(head: *const zix.Http1.ParsedHead, fd: std.posix.fd_t) !void {
    var req = zix.Http1.Request.init(head, "", fd);
    var res = zix.Http1.Response.init(fd, undefined, std.testing.allocator);
    var ctx = zix.Http1.Context.init(undefined, std.testing.allocator, fd);

    try TestRouter.dispatch(&req, &res, &ctx);
}

test "zix integration: Http1 Router dispatch routes to matching handler" {
    const pipe_fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(pipe_fds[0]);
    defer _ = std.posix.system.close(pipe_fds[1]);

    const head = parsedHead("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    last_route = "";
    try dispatchReq(&head, pipe_fds[1]);

    try std.testing.expectEqualStrings("home", last_route);
}

test "zix integration: Http1 Router dispatch selects correct route among multiple" {
    const pipe_fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(pipe_fds[0]);
    defer _ = std.posix.system.close(pipe_fds[1]);

    const head = parsedHead("GET /api HTTP/1.1\r\nHost: localhost\r\n\r\n");
    last_route = "";
    try dispatchReq(&head, pipe_fds[1]);

    try std.testing.expectEqualStrings("api", last_route);
}

test "zix integration: Http1 Router dispatch unknown path writes 404" {
    const pipe_fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(pipe_fds[0]);
    defer _ = std.posix.system.close(pipe_fds[1]);

    const head = parsedHead("GET /not-found HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try dispatchReq(&head, pipe_fds[1]);

    var resp_buf: [256]u8 = undefined;
    const n = try std.posix.read(pipe_fds[0], &resp_buf);
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp_buf[0..n], "404") != null);
}
