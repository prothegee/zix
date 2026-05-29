//! Integration tests: HTTP/2 h2c round-trips over real TCP using zix.Http2.serveConn.
//! Covers: h2c direct GET, POST echo, sequential streams, h2c upgrade.

const std = @import("std");
const zix = @import("zix");

const TEST_PORT: u16 = 18082;

// --------------------------------------------------------- //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

fn echoHandler(
    method: []const u8,
    headers: []const zix.Http2.Header,
    body: []const u8,
    fd: std.posix.fd_t,
    sid: u31,
) void {
    _ = method;
    _ = headers;
    zix.Http2.sendResponse(fd, sid, 200, "text/plain", body) catch {};
}

fn helloHandler(
    method: []const u8,
    headers: []const zix.Http2.Header,
    body: []const u8,
    fd: std.posix.fd_t,
    sid: u31,
) void {
    _ = method;
    _ = headers;
    _ = body;
    zix.Http2.sendResponse(fd, sid, 200, "text/plain", "Hello, World!") catch {};
}

// --------------------------------------------------------- //

fn makeRunner(comptime routes: []const zix.Http2.Route) type {
    return struct {
        fn run(ctx: *ServerCtx, io: std.Io) void {
            const stream = ctx.listener.accept(io) catch |e| {
                ctx.err = e;
                return;
            };
            const fd = stream.socket.handle;
            zix.Http2.serveConn(routes, fd, .{});
            _ = std.os.linux.close(fd);
        }
    };
}

fn spawnServer(
    ctx: *ServerCtx,
    io: std.Io,
    port: u16,
    comptime run_fn: fn (*ServerCtx, std.Io) void,
) !std.Thread {
    ctx.err = null;
    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
    ctx.listener = try addr.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 4,
    });
    return std.Thread.spawn(.{ .stack_size = 512 * 1024 }, run_fn, .{ ctx, io });
}

// --------------------------------------------------------- //

fn clientConnect(io: std.Io, port: u16) !std.posix.fd_t {
    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
    const s = try addr.connect(io, .{ .mode = .stream });
    return s.socket.handle;
}

fn sendPreface(fd: std.posix.fd_t) !void {
    try zix.Http2.fdWriteAll(fd, zix.Http2.PREFACE);
    try zix.Http2.sendSettings(fd, &.{});
}

fn sendRequest(
    fd: std.posix.fd_t,
    sid: u31,
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
) !void {
    var hbuf: [256]u8 = undefined;
    var enc = zix.Http2.HpackEncoder.init(&hbuf);
    try enc.writeHeader(":method", method);
    try enc.writeHeader(":path", path);
    try enc.writeHeader(":scheme", "http");
    try enc.writeHeader(":authority", "localhost");
    const hblock = enc.encoded();

    const end_stream: u8 = if (body == null)
        zix.Http2.FLAG_END_STREAM | zix.Http2.FLAG_END_HEADERS
    else
        zix.Http2.FLAG_END_HEADERS;

    try zix.Http2.writeFrameHeader(fd, .{
        .length = @intCast(hblock.len),
        .frame_type = zix.Http2.FT_HEADERS,
        .flags = end_stream,
        .stream_id = sid,
    });
    try zix.Http2.fdWriteAll(fd, hblock);

    if (body) |b| {
        try zix.Http2.writeFrameHeader(fd, .{
            .length = @intCast(b.len),
            .frame_type = zix.Http2.FT_DATA,
            .flags = zix.Http2.FLAG_END_STREAM,
            .stream_id = sid,
        });
        try zix.Http2.fdWriteAll(fd, b);
    }
}

fn recvResponse(fd: std.posix.fd_t, sid: u31, buf: []u8) ![]const u8 {
    var body_len: usize = 0;
    var payload_buf: [zix.Http2.MAX_PAYLOAD + 256]u8 = undefined;
    var hdec = zix.Http2.HpackDecoder.init();
    var hdrs: [32]zix.Http2.Header = undefined;
    var scratch: [2048]u8 = undefined;

    while (true) {
        const fh = try zix.Http2.readFrameHeader(fd);
        const payload = payload_buf[0..fh.length];
        if (fh.length > 0) try zix.Http2.recvExact(fd, payload);

        switch (fh.frame_type) {
            zix.Http2.FT_SETTINGS => {
                if ((fh.flags & zix.Http2.FLAG_ACK) == 0) try zix.Http2.sendSettingsAck(fd);
            },
            zix.Http2.FT_WINDOW_UPDATE => {},
            zix.Http2.FT_PING => {
                if ((fh.flags & zix.Http2.FLAG_ACK) == 0) {
                    var p8: [8]u8 = undefined;
                    @memcpy(&p8, payload[0..8]);
                    try zix.Http2.sendPingAck(fd, p8);
                }
            },
            zix.Http2.FT_HEADERS => {
                if (fh.stream_id != sid) continue;
                _ = try hdec.decode(payload, &hdrs, &scratch);
                if ((fh.flags & zix.Http2.FLAG_END_STREAM) != 0) return buf[0..body_len];
            },
            zix.Http2.FT_DATA => {
                if (fh.stream_id != sid) continue;
                const to_copy = @min(payload.len, buf.len - body_len);
                @memcpy(buf[body_len..][0..to_copy], payload[0..to_copy]);
                body_len += to_copy;
                if ((fh.flags & zix.Http2.FLAG_END_STREAM) != 0) return buf[0..body_len];
            },
            zix.Http2.FT_GOAWAY => return error.ServerGoaway,
            zix.Http2.FT_RST_STREAM => return error.StreamReset,
            else => {},
        }
    }
}

// --------------------------------------------------------- //

test "zix integration: Http2Server.init and deinit do not error" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try zix.Http2.Server.init(&[_]zix.Http2.Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 8082 });
    server.deinit();
}

test "zix integration: Http2Server.init port zero returns PortNotConfigured" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(
        error.PortNotConfigured,
        zix.Http2.Server.init(&[_]zix.Http2.Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 0 }),
    );
}

test "zix integration: Http2 HandlerFn type is a function pointer" {
    const h: zix.Http2.HandlerFn = helloHandler;
    _ = h;
}

test "zix integration: Http2 GET / returns Hello World over h2c direct" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const R = makeRunner(&[_]zix.Http2.Route{
        .{ .path = "/", .handler = helloHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT, R.run);

    const fd = try clientConnect(io, TEST_PORT);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);
    try sendRequest(fd, 1, "GET", "/", null);

    var body_buf: [1024]u8 = undefined;
    const body = try recvResponse(fd, 1, &body_buf);

    try std.testing.expectEqualStrings("Hello, World!", body);

    try zix.Http2.sendGoaway(fd, 1, zix.Http2.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: Http2 POST /echo returns request body" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const R = makeRunner(&[_]zix.Http2.Route{
        .{ .path = "/echo", .handler = echoHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 1, R.run);

    const fd = try clientConnect(io, TEST_PORT + 1);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);
    try sendRequest(fd, 1, "POST", "/echo", "ping from client");

    var body_buf: [1024]u8 = undefined;
    const body = try recvResponse(fd, 1, &body_buf);

    try std.testing.expectEqualStrings("ping from client", body);

    try zix.Http2.sendGoaway(fd, 1, zix.Http2.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: Http2 two sequential streams on same connection" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const R = makeRunner(&[_]zix.Http2.Route{
        .{ .path = "/", .handler = helloHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 2, R.run);

    const fd = try clientConnect(io, TEST_PORT + 2);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);

    try sendRequest(fd, 1, "GET", "/", null);
    var buf1: [1024]u8 = undefined;
    const b1 = try recvResponse(fd, 1, &buf1);
    try std.testing.expectEqualStrings("Hello, World!", b1);

    try sendRequest(fd, 3, "GET", "/", null);
    var buf2: [1024]u8 = undefined;
    const b2 = try recvResponse(fd, 3, &buf2);
    try std.testing.expectEqualStrings("Hello, World!", b2);

    try zix.Http2.sendGoaway(fd, 3, zix.Http2.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: Http2 h2c upgrade GET / returns Hello World" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const R = makeRunner(&[_]zix.Http2.Route{
        .{ .path = "/", .handler = helloHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 3, R.run);

    const fd = try clientConnect(io, TEST_PORT + 3);
    defer _ = std.posix.system.close(fd);

    const upgrade_req =
        "GET / HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Upgrade: h2c\r\n" ++
        "\r\n";
    try zix.Http2.fdWriteAll(fd, upgrade_req);

    var resp101: [256]u8 = undefined;
    const n101 = try std.posix.read(fd, &resp101);
    try std.testing.expect(std.mem.startsWith(u8, resp101[0..n101], "HTTP/1.1 101"));

    try sendPreface(fd);

    var body_buf: [1024]u8 = undefined;
    const body = try recvResponse(fd, 1, &body_buf);

    try std.testing.expectEqualStrings("Hello, World!", body);

    try zix.Http2.sendGoaway(fd, 1, zix.Http2.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
