//! Integration tests: full HTTP/1 round-trip over real TCP using serveConn.
//! Covers: GET, POST (Content-Length), POST (chunked), keep-alive.
//! Run: zig test rnd/http1_integ_test.zig

const std = @import("std");
const core = @import("http1_poc_core.zig");

const TEST_PORT: u16 = 18080;

// ------------------------------------------------------------------ //
// Test server helpers                                                 //
// ------------------------------------------------------------------ //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

fn echoHandler(head: *const core.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    core.writeSimple(fd, 200, "text/plain", body) catch {};
}

fn helloHandler(head: *const core.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    core.writeSimple(fd, 200, "text/plain", "Hello, World!") catch {};
}

fn runServer(ctx: *ServerCtx, io: std.Io, h: core.HandlerFn) void {
    const stream = ctx.listener.accept(io) catch |e| {
        ctx.err = e;
        return;
    };
    core.serveConn(stream, io, h);
}

fn spawnServer(ctx: *ServerCtx, io: std.Io, port: u16, h: core.HandlerFn) !std.Thread {
    ctx.err = null;
    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
    ctx.listener = try addr.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 4,
    });
    return std.Thread.spawn(.{ .stack_size = 512 * 1024 }, runServer, .{ ctx, io, h });
}

// Read until headers + full body are received (Content-Length based).
fn recvFull(rd: *std.Io.Reader, buf: []u8) !usize {
    var filled: usize = 0;
    while (filled < buf.len) {
        buf[filled] = try rd.takeByte();
        filled += 1;
        if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n")) |sep| {
            const cl = extractContentLength(buf[0..sep]) orelse 0;
            const body_start = sep + 4;
            while (filled < body_start + cl) {
                buf[filled] = try rd.takeByte();
                filled += 1;
            }
            return filled;
        }
    }
    return filled;
}

fn extractContentLength(headers: []const u8) ?usize {
    const prefix = "Content-Length: ";
    const pos = std.mem.indexOf(u8, headers, prefix) orelse return null;
    const after = headers[pos + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, after, '\r') orelse after.len;
    return std.fmt.parseInt(usize, after[0..end], 10) catch null;
}

// ------------------------------------------------------------------ //
// Tests                                                               //
// ------------------------------------------------------------------ //

test "integ: GET / returns 200 with Hello World body" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT, helloHandler);

    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rd_buf: [4096]u8 = undefined;
    var wr_buf: [4096]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    try wr.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try wr.interface.flush();

    var resp: [2048]u8 = undefined;
    const n = try recvFull(&rd.interface, &resp);

    try std.testing.expect(std.mem.startsWith(u8, resp[0..n], "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, resp[0..n], "Hello, World!") != null);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "integ: POST body is echoed back" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 1, echoHandler);

    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT + 1);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rd_buf: [4096]u8 = undefined;
    var wr_buf: [4096]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    const body = "hello from client";
    var req_buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(
        &req_buf,
        "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ body.len, body },
    );
    try wr.interface.writeAll(req);
    try wr.interface.flush();

    var resp: [2048]u8 = undefined;
    const n = try recvFull(&rd.interface, &resp);

    try std.testing.expect(std.mem.startsWith(u8, resp[0..n], "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, resp[0..n], body) != null);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "integ: two sequential requests on keep-alive connection both succeed" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    // Server accepts 2 requests on same connection before close.
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 2, helloHandler);

    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT + 2);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rd_buf: [4096]u8 = undefined;
    var wr_buf: [4096]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    // Request 1: keep-alive.
    try wr.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try wr.interface.flush();
    var resp1: [2048]u8 = undefined;
    const n1 = try recvFull(&rd.interface, &resp1);
    try std.testing.expect(std.mem.startsWith(u8, resp1[0..n1], "HTTP/1.1 200 OK"));

    // Request 2: close.
    try wr.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try wr.interface.flush();
    var resp2: [2048]u8 = undefined;
    const n2 = try recvFull(&rd.interface, &resp2);
    try std.testing.expect(std.mem.startsWith(u8, resp2[0..n2], "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, resp2[0..n2], "Hello, World!") != null);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "integ: POST with chunked body is decoded and echoed" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 3, echoHandler);

    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT + 3);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rd_buf: [4096]u8 = undefined;
    var wr_buf: [4096]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    const req =
        "POST /echo HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "Connection: close\r\n" ++
        "\r\n" ++
        "5\r\nhello\r\n" ++
        "6\r\n world\r\n" ++
        "0\r\n" ++
        "\r\n";
    try wr.interface.writeAll(req);
    try wr.interface.flush();

    var resp: [2048]u8 = undefined;
    const n = try recvFull(&rd.interface, &resp);

    try std.testing.expect(std.mem.startsWith(u8, resp[0..n], "HTTP/1.1 200 OK"));
    try std.testing.expect(std.mem.indexOf(u8, resp[0..n], "hello world") != null);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
