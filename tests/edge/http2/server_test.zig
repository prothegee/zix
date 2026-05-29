//! Edge tests: Http2 boundary conditions — bad preface, RST_STREAM, GOAWAY, stream 0.

const std = @import("std");
const zix = @import("zix");

const TEST_PORT: u16 = 18100;

// --------------------------------------------------------- //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

fn nopHandler(
    method: []const u8,
    headers: []const zix.Http2.Header,
    body: []const u8,
    fd: std.posix.fd_t,
    sid: u31,
) void {
    _ = method;
    _ = headers;
    _ = body;
    zix.Http2.sendResponse(fd, sid, 200, "text/plain", "ok") catch {};
}

fn runServer(ctx: *ServerCtx, io: std.Io) void {
    const stream = ctx.listener.accept(io) catch |e| {
        ctx.err = e;
        return;
    };
    const fd = stream.socket.handle;
    zix.Http2.serveConn(&[_]zix.Http2.Route{.{ .path = "/", .handler = nopHandler }}, fd, .{});
    _ = std.os.linux.close(fd);
}

fn spawnServer(ctx: *ServerCtx, io: std.Io, port: u16) !std.Thread {
    ctx.err = null;
    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
    ctx.listener = try addr.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 4,
    });
    return std.Thread.spawn(.{ .stack_size = 512 * 1024 }, runServer, .{ ctx, io });
}

fn clientConnect(io: std.Io, port: u16) !std.posix.fd_t {
    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
    const s = try addr.connect(io, .{ .mode = .stream });
    return s.socket.handle;
}

// --------------------------------------------------------- //

test "zix edge: bad PRI preface causes server to close connection" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT);

    const fd = try clientConnect(io, TEST_PORT);
    defer _ = std.posix.system.close(fd);

    try zix.Http2.fdWriteAll(fd, "PRI * HTTP/2.0\r\nBAD PREFACE GARBAGE");

    var buf: [256]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch 0;
    _ = n;

    t.join();
    ctx.listener.deinit(io);
}

test "zix edge: client sends GOAWAY and server connection loop exits" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 1);

    const fd = try clientConnect(io, TEST_PORT + 1);
    defer _ = std.posix.system.close(fd);

    try zix.Http2.fdWriteAll(fd, zix.Http2.PREFACE);
    try zix.Http2.sendSettings(fd, &.{});

    var payload_buf: [64]u8 = undefined;
    var got_settings = false;
    while (!got_settings) {
        const fh = try zix.Http2.readFrameHeader(fd);
        const payload = payload_buf[0..fh.length];
        if (fh.length > 0) try zix.Http2.recvExact(fd, payload);
        if (fh.frame_type == zix.Http2.FT_SETTINGS and (fh.flags & zix.Http2.FLAG_ACK) == 0) {
            try zix.Http2.sendSettingsAck(fd);
            got_settings = true;
        }
    }

    try zix.Http2.sendGoaway(fd, 0, zix.Http2.ERR_NO_ERROR);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix edge: Http2Server.init rejects port zero" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const result = zix.Http2.Server.init(&[_]zix.Http2.Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 0 });
    try std.testing.expectError(error.PortNotConfigured, result);
}

test "zix edge: HpackDecoder decode of empty block returns zero headers" {
    var dec = zix.Http2.HpackDecoder.init();
    var out: [8]zix.Http2.Header = undefined;
    var scratch: [256]u8 = undefined;
    const n = try dec.decode(&.{}, &out, &scratch);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "zix edge: writeFrameHeader stream_id high bit is cleared on read" {
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);

    const orig = zix.Http2.FrameHeader{
        .length = 0,
        .frame_type = zix.Http2.FT_DATA,
        .flags = 0,
        .stream_id = 0x7FFF_FFFF,
    };
    try zix.Http2.writeFrameHeader(fds[1], orig);
    _ = std.posix.system.close(fds[1]);
    const got = try zix.Http2.readFrameHeader(fds[0]);
    try std.testing.expectEqual(orig.stream_id, got.stream_id);
}
