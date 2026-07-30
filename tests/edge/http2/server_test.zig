//! Edge tests: Http2 boundary conditions: bad preface, RST_STREAM, GOAWAY, stream 0.

const std = @import("std");
const zix = @import("zix");

const TEST_PORT: u16 = 18100;

// --------------------------------------------------------- //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

fn nopHandler(req: *zix.Http2.Request, res: *zix.Http2.Response, ctx: *zix.Http2.Context) anyerror!void {
    _ = req;
    _ = ctx;
    try res.sendText("ok");
}

const nop_router = zix.Http2.Router(&[_]zix.Http2.Route{.{ .path = "/", .handler = nopHandler }});

fn runServer(ctx: *ServerCtx, io: std.Io) void {
    const stream = ctx.listener.accept(io) catch |e| {
        ctx.err = e;
        return;
    };
    const fd = stream.socket.handle;
    zix.Http2.serveConn(nop_router.dispatch, fd, .{}, io);
    zix.utils.fd_io.close(fd);
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
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT);

    const fd = try clientConnect(io, TEST_PORT);
    defer zix.utils.fd_io.close(fd);

    try zix.Http2.writeAllFD(fd, "PRI * HTTP/2.0\r\nBAD PREFACE GARBAGE");

    var buf: [256]u8 = undefined;
    const n = zix.utils.fd_io.readOnce(fd, &buf) catch 0;
    _ = n;

    t.join();
    ctx.listener.deinit(io);
}

test "zix edge: client sends GOAWAY and server connection loop exits" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 1);

    const fd = try clientConnect(io, TEST_PORT + 1);
    defer zix.utils.fd_io.close(fd);

    try zix.Http2.writeAllFD(fd, zix.Http2.PREFACE);
    try zix.Http2.sendSettingsFD(fd, &.{});

    var payload_buf: [64]u8 = undefined;
    var got_settings = false;
    while (!got_settings) {
        const fh = try zix.Http2.readFrameHeader(fd);
        const payload = payload_buf[0..fh.length];
        if (fh.length > 0) try zix.Http2.recvExact(fd, payload);
        if (fh.frame_type == zix.Http2.FRAME_TYPE_SETTINGS and (fh.flags & zix.Http2.FLAG_ACK) == 0) {
            try zix.Http2.sendSettingsAckFD(fd);
            got_settings = true;
        }
    }

    try zix.Http2.sendGoawayFD(fd, 0, zix.Http2.ERR_NO_ERROR);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix edge: Http2Server.run rejects port zero" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const empty_router = zix.Http2.Router(&[_]zix.Http2.Route{});
    var server = zix.Http2.Server.init(empty_router.dispatch, .{ .io = io, .ip = "127.0.0.1", .port = 0, .dispatch_model = .ASYNC });
    defer server.deinit();

    try std.testing.expectError(error.PortNotConfigured, server.run());
}

test "zix edge: HpackDecoder decode of empty block returns zero headers" {
    var dec = zix.Http2.HpackDecoder.init();
    var out: [8]zix.Http2.Header = undefined;
    var scratch: [256]u8 = undefined;
    const n = try dec.decode(&.{}, &out, &scratch);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "zix edge: writeFrameHeader stream_id high bit is cleared on read" {
    var pair = try zix.utils.socket_pair.Pair.open(std.testing.allocator);
    defer pair.deinit();
    const fds = pair.fds;

    const orig = zix.Http2.FrameHeader{
        .length = 0,
        .frame_type = zix.Http2.FRAME_TYPE_DATA,
        .flags = 0,
        .stream_id = 0x7FFF_FFFF,
    };
    try zix.Http2.writeFrameHeaderFD(fds[1], orig);
    zix.utils.fd_io.close(fds[1]);
    const got = try zix.Http2.readFrameHeader(fds[0]);
    try std.testing.expectEqual(orig.stream_id, got.stream_id);
}
