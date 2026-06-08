const std = @import("std");
const zix = @import("zix");

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9104;
const WORKERS: usize = 0;
const POOL_SIZE: usize = 0;

// --------------------------------------------------------- //

// GET /echo
// Echoes all query params as a JSON object.
// /echo?foo=bar&baz=qux  ->  {"foo":"bar","baz":"qux"}
// /echo                  ->  null
// curl usage: curl -X GET "http://localhost:9104/echo?foo=bar&baz=qux"
fn echoHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    if (!std.mem.eql(u8, head.method, "GET")) {
        zix.Http1.writeJson(fd, 405, "{\"error\":\"method not allowed\"}") catch {};
        return;
    }

    if (head.query.len == 0) {
        zix.Http1.writeJson(fd, 200, "null") catch {};
        return;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.smp_allocator);

    out.append(std.heap.smp_allocator, '{') catch return;
    var first = true;
    var it = std.mem.splitScalar(u8, head.query, '&');
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

    zix.Http1.writeJson(fd, 200, out.items) catch {};
}

// GET /greet?name=<value>
// /greet?name=alice  ->  {"ok":true,"message":"hello, alice"}
// /greet             ->  {"ok":false,"message":"Error: missing required param: name"}
// curl usage: curl -X GET "http://localhost:9104/greet?name=alice"
fn greetHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    if (!std.mem.eql(u8, head.method, "GET")) {
        zix.Http1.writeJson(fd, 405, "{\"ok\":false,\"message\":\"Error: method not allowed\"}") catch {};
        return;
    }

    const name = zix.Http1.queryParam(head, "name") orelse {
        zix.Http1.writeJson(fd, 400, "{\"ok\":false,\"message\":\"Error: missing required param: name\"}") catch {};
        return;
    };

    var buf: [256]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"message\":\"hello, {s}\"}}", .{name}) catch return;
    zix.Http1.writeJson(fd, 200, json) catch {};
}

// GET /calc?a=<num>&b=<num>
// /calc?a=3&b=4   ->  {"ok":true,"message":"3 + 4 = 7"}
// /calc?b=4       ->  {"ok":false,"message":"Error: missing required param: a"}
// /calc?a=foo&b=4 ->  {"ok":false,"message":"Error: a must be a number"}
// curl usage: curl -X GET "http://localhost:9104/calc?a=3&b=4"
fn calcHandler(head: *const zix.Http1.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    if (!std.mem.eql(u8, head.method, "GET")) {
        zix.Http1.writeJson(fd, 405, "{\"ok\":false,\"message\":\"Error: method not allowed\"}") catch {};
        return;
    }

    const a_str = zix.Http1.queryParam(head, "a") orelse {
        zix.Http1.writeJson(fd, 400, "{\"ok\":false,\"message\":\"Error: missing required param: a\"}") catch {};
        return;
    };
    const b_str = zix.Http1.queryParam(head, "b") orelse {
        zix.Http1.writeJson(fd, 400, "{\"ok\":false,\"message\":\"Error: missing required param: b\"}") catch {};
        return;
    };

    const a = std.fmt.parseInt(i64, a_str, 10) catch {
        zix.Http1.writeJson(fd, 400, "{\"ok\":false,\"message\":\"Error: a must be a number\"}") catch {};
        return;
    };
    const b = std.fmt.parseInt(i64, b_str, 10) catch {
        zix.Http1.writeJson(fd, 400, "{\"ok\":false,\"message\":\"Error: b must be a number\"}") catch {};
        return;
    };

    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"ok\":true,\"message\":\"{d} + {d} = {d}\"}}", .{ a, b, a + b }) catch return;
    zix.Http1.writeJson(fd, 200, json) catch {};
}

// --------------------------------------------------------- //

const Routes = zix.Http1.Router(&[_]zix.Http1.Route{
    .{ .path = "/echo", .handler = echoHandler },
    .{ .path = "/greet", .handler = greetHandler },
    .{ .path = "/calc", .handler = calcHandler },
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
