//! Integration tests: full HTTP/2 round-trip over real TCP using serveConn.
//! Covers: h2c direct GET, POST echo, sequential streams, h2c upgrade.
//! Run: zig test rnd/http2_integ_test.zig

const std = @import("std");
const core = @import("http2_poc_core.zig");

const TEST_PORT: u16 = 18200;

// ------------------------------------------------------------------ //
// Test server helpers                                                 //
// ------------------------------------------------------------------ //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

fn echoHandler(
    method: []const u8,
    path: []const u8,
    headers: []const core.Header,
    body: []const u8,
    fd: std.posix.fd_t,
    sid: u31,
) void {
    _ = method;
    _ = path;
    _ = headers;
    core.sendResponse(fd, sid, 200, "text/plain", body) catch {};
}

fn helloHandler(
    method: []const u8,
    path: []const u8,
    headers: []const core.Header,
    body: []const u8,
    fd: std.posix.fd_t,
    sid: u31,
) void {
    _ = method;
    _ = path;
    _ = headers;
    _ = body;
    core.sendResponse(fd, sid, 200, "text/plain", "Hello, World!") catch {};
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

// ------------------------------------------------------------------ //
// Minimal h2c client helpers                                         //
// ------------------------------------------------------------------ //

fn clientConnect(io: std.Io, port: u16) !std.posix.fd_t {
    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
    const s = try addr.connect(io, .{ .mode = .stream });
    return s.socket.handle;
}

fn sendPreface(fd: std.posix.fd_t) !void {
    try core.fdWriteAll(fd, core.PREFACE);
    // Client sends initial SETTINGS (empty = accept defaults).
    try core.sendSettings(fd, &.{});
}

// Encode a minimal HEADERS frame: :method, :path, :scheme, :authority.
fn sendRequest(
    fd: std.posix.fd_t,
    sid: u31,
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
) !void {
    var hbuf: [256]u8 = undefined;
    var enc = core.HpackEncoder.init(&hbuf);
    try enc.writeHeader(":method", method);
    try enc.writeHeader(":path", path);
    try enc.writeHeader(":scheme", "http");
    try enc.writeHeader(":authority", "localhost");
    const hblock = enc.encoded();

    const end_stream: u8 = if (body == null) core.FLAG_END_STREAM | core.FLAG_END_HEADERS else core.FLAG_END_HEADERS;
    try core.writeFrameHeader(fd, .{
        .length = @intCast(hblock.len),
        .frame_type = core.FT_HEADERS,
        .flags = end_stream,
        .stream_id = sid,
    });
    try core.fdWriteAll(fd, hblock);

    if (body) |b| {
        try core.writeFrameHeader(fd, .{
            .length = @intCast(b.len),
            .frame_type = core.FT_DATA,
            .flags = core.FLAG_END_STREAM,
            .stream_id = sid,
        });
        try core.fdWriteAll(fd, b);
    }
}

// Read frames until we see HEADERS + DATA (or HEADERS with END_STREAM) for the given stream.
// Returns decoded response body.
fn recvResponse(
    fd: std.posix.fd_t,
    sid: u31,
    buf: []u8,
) ![]const u8 {
    var body_len: usize = 0;
    var payload_buf: [core.MAX_PAYLOAD + 256]u8 = undefined;
    var hpack = core.HpackDecoder.init();
    var hdrs: [32]core.Header = undefined;
    var scratch: [2048]u8 = undefined;

    while (true) {
        const fh = try core.readFrameHeader(fd);
        const payload = payload_buf[0..fh.length];
        if (fh.length > 0) try core.recvExact(fd, payload);

        switch (fh.frame_type) {
            core.FT_SETTINGS => {
                if ((fh.flags & core.FLAG_ACK) == 0) try core.sendSettingsAck(fd);
            },
            core.FT_WINDOW_UPDATE => {},
            core.FT_PING => {
                if ((fh.flags & core.FLAG_ACK) == 0) {
                    var p8: [8]u8 = undefined;
                    @memcpy(&p8, payload[0..8]);
                    try core.sendPingAck(fd, p8);
                }
            },
            core.FT_HEADERS => {
                if (fh.stream_id != sid) continue;
                _ = try hpack.decode(payload, &hdrs, &scratch);
                if ((fh.flags & core.FLAG_END_STREAM) != 0) return buf[0..body_len];
            },
            core.FT_DATA => {
                if (fh.stream_id != sid) continue;
                const to_copy = @min(payload.len, buf.len - body_len);
                @memcpy(buf[body_len..][0..to_copy], payload[0..to_copy]);
                body_len += to_copy;
                if ((fh.flags & core.FLAG_END_STREAM) != 0) return buf[0..body_len];
            },
            core.FT_GOAWAY => return error.ServerGoaway,
            core.FT_RST_STREAM => return error.StreamReset,
            else => {},
        }
    }
}

// ------------------------------------------------------------------ //
// Tests                                                               //
// ------------------------------------------------------------------ //

test "integ: GET / returns Hello World over h2c" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT, helloHandler);

    const fd = try clientConnect(io, TEST_PORT);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);
    try sendRequest(fd, 1, "GET", "/", null);

    var body_buf: [1024]u8 = undefined;
    const body = try recvResponse(fd, 1, &body_buf);

    try std.testing.expectEqualStrings("Hello, World!", body);

    try core.sendGoaway(fd, 1, core.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "integ: POST /echo returns request body" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 1, echoHandler);

    const fd = try clientConnect(io, TEST_PORT + 1);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);
    try sendRequest(fd, 1, "POST", "/echo", "ping from client");

    var body_buf: [1024]u8 = undefined;
    const body = try recvResponse(fd, 1, &body_buf);

    try std.testing.expectEqualStrings("ping from client", body);

    try core.sendGoaway(fd, 1, core.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "integ: two sequential streams on same connection both succeed" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 2, helloHandler);

    const fd = try clientConnect(io, TEST_PORT + 2);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);

    // Stream 1.
    try sendRequest(fd, 1, "GET", "/", null);
    var buf1: [1024]u8 = undefined;
    const b1 = try recvResponse(fd, 1, &buf1);
    try std.testing.expectEqualStrings("Hello, World!", b1);

    // Stream 3 (client-initiated streams must be odd and incrementing).
    try sendRequest(fd, 3, "GET", "/", null);
    var buf2: [1024]u8 = undefined;
    const b2 = try recvResponse(fd, 3, &buf2);
    try std.testing.expectEqualStrings("Hello, World!", b2);

    try core.sendGoaway(fd, 3, core.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "integ: h2c upgrade GET / returns Hello World via HTTP/1.1 Upgrade" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 3, helloHandler);

    const fd = try clientConnect(io, TEST_PORT + 3);
    defer _ = std.posix.system.close(fd);

    // Send HTTP/1.1 upgrade request.
    const upgrade_req =
        "GET / HTTP/1.1\r\n" ++
        "Host: localhost\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Upgrade: h2c\r\n" ++
        "\r\n";
    try core.fdWriteAll(fd, upgrade_req);

    // Read 101 Switching Protocols (fits in one read; response is ~70 bytes).
    var resp101: [256]u8 = undefined;
    const n101 = try std.posix.read(fd, &resp101);
    try std.testing.expect(std.mem.startsWith(u8, resp101[0..n101], "HTTP/1.1 101"));

    // Send h2c connection preface + empty SETTINGS.
    try sendPreface(fd);

    // recvResponse handles the server's SETTINGS (ACKs it) then returns stream 1 body.
    var body_buf: [1024]u8 = undefined;
    const body = try recvResponse(fd, 1, &body_buf);

    try std.testing.expectEqualStrings("Hello, World!", body);

    try core.sendGoaway(fd, 1, core.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
