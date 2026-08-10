//! Edge tests: gRPC boundary conditions: malformed prefix, empty body, truncated message,
//! path parse failures, content-type detection edge cases, and finish-only handler behavior.

const std = @import("std");
const zix = @import("zix");

const TEST_PORT: u16 = 18220;

// --------------------------------------------------------- //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

fn nopHandler(req: *zix.Grpc.Request, res: *zix.Grpc.Response, ctx: *zix.Grpc.Context) !void {
    _ = req;
    _ = ctx;
    res.finish(zix.Grpc.Status.OK, "");
}

fn errorOnlyHandler(req: *zix.Grpc.Request, res: *zix.Grpc.Response, ctx: *zix.Grpc.Context) !void {
    _ = req;
    _ = ctx;
    res.finish(zix.Grpc.Status.INVALID_ARGUMENT, "bad");
}

fn runServer(ctx: *ServerCtx, io: std.Io) void {
    const stream = ctx.listener.accept(io) catch |e| {
        ctx.err = e;
        return;
    };
    const fd = stream.socket.handle;
    zix.Grpc.serveConn(zix.Grpc.Router(&[_]zix.Grpc.Route{.{ .path = "/nop/Nop", .handler = nopHandler }}), fd, .{}, io);
    zix.utils.fd_io.close(fd);
}

fn runErrorServer(ctx: *ServerCtx, io: std.Io) void {
    const stream = ctx.listener.accept(io) catch |e| {
        ctx.err = e;
        return;
    };
    const fd = stream.socket.handle;
    zix.Grpc.serveConn(zix.Grpc.Router(&[_]zix.Grpc.Route{.{ .path = "/nop/Nop", .handler = errorOnlyHandler }}), fd, .{}, io);
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

fn spawnErrorServer(ctx: *ServerCtx, io: std.Io, port: u16) !std.Thread {
    ctx.err = null;
    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
    ctx.listener = try addr.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 4,
    });
    return std.Thread.spawn(.{ .stack_size = 512 * 1024 }, runErrorServer, .{ ctx, io });
}

// --------------------------------------------------------- //

/// Test fd sentinel: Windows descriptors are opaque pointers, POSIX are ints.
const TEST_FD: std.posix.fd_t = if (@import("builtin").target.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else 0;

test "zix edge: readGrpcPrefix with 4 bytes returns TooShort" {
    const body = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.ZixTooShort, zix.Grpc.readPrefix(&body));
}

test "zix edge: readGrpcPrefix with empty slice returns TooShort" {
    try std.testing.expectError(error.ZixTooShort, zix.Grpc.readPrefix(&.{}));
}

test "zix edge: GrpcContext.recvMessage body shorter than prefix returns null" {
    const body = [_]u8{ 0, 0, 0 };
    var ctx = zix.Grpc.Context{ .fd = TEST_FD, .stream_id = 1, ._body = &body, ._pos = 0, ._hdr_sent = false, ._sent_bytes = 0, ._grpc_status = 0, .io = undefined, .allocator = std.testing.allocator };
    try std.testing.expect(ctx.recvMessage() == null);
}

test "zix edge: GrpcContext.recvMessage msg_len exceeds body returns null" {
    var body: [5]u8 = undefined;
    zix.Grpc.writePrefix(body[0..5], false, 100);
    var ctx = zix.Grpc.Context{ .fd = TEST_FD, .stream_id = 1, ._body = &body, ._pos = 0, ._hdr_sent = false, ._sent_bytes = 0, ._grpc_status = 0, .io = undefined, .allocator = std.testing.allocator };
    try std.testing.expect(ctx.recvMessage() == null);
}

test "zix edge: parsePath empty string returns null" {
    try std.testing.expect(zix.Grpc.parsePath("") == null);
}

test "zix edge: parsePath no leading slash returns null" {
    try std.testing.expect(zix.Grpc.parsePath("pkg.Svc/Method") == null);
}

test "zix edge: parsePath only slash returns null" {
    try std.testing.expect(zix.Grpc.parsePath("/") == null);
}

test "zix edge: detectContentType no header returns UNKNOWN" {
    const hdrs: []const zix.Http2.Header = &.{};
    try std.testing.expectEqual(zix.Grpc.ContentType.UNKNOWN, zix.Grpc.detectContentType(hdrs));
}

test "zix edge: detectContentType text/plain returns UNKNOWN" {
    const hdrs = [_]zix.Http2.Header{.{ .name = "content-type", .value = "text/plain" }};
    try std.testing.expectEqual(zix.Grpc.ContentType.UNKNOWN, zix.Grpc.detectContentType(&hdrs));
}

test "zix edge: parseTimeout single character is null" {
    try std.testing.expect(zix.Grpc.parseTimeout("S") == null);
}

test "zix edge: GrpcClient.connect port zero returns PortNotConfigured" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(
        error.ZixPortNotConfigured,
        zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = 0 }, io),
    );
}

test "zix edge: gRPC serveConn closes cleanly on immediate client disconnect" {
    if (comptime @import("builtin").target.os.tag == .windows) {
        std.log.info("this test drives a POSIX descriptor, Windows handles are opaque, test skipped", .{});
        return;
    }

    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const server_thread = try spawnServer(&ctx, io, TEST_PORT);

    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT);
    const stream = try addr.connect(io, .{ .mode = .stream });
    zix.utils.fd_io.close(stream.socket.handle);

    server_thread.join();
    ctx.listener.deinit(io);
}

test "zix edge: gRPC finish-only handler delivers error status to client" {
    if (comptime @import("builtin").target.os.tag == .windows) {
        std.log.info("this test drives a POSIX descriptor, Windows handles are opaque, test skipped", .{});
        return;
    }

    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const server_thread = try spawnErrorServer(&ctx, io, TEST_PORT + 1);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = TEST_PORT + 1 }, io);
    defer client.deinit();

    const stream_id = try client.openStream("/nop/Nop", "application/grpc+proto");
    try client.sendMessage(stream_id, "trigger");
    try client.endStream(stream_id);

    var buf: [64]u8 = undefined;
    const resp = try client.recvResponse(stream_id, &buf);
    try std.testing.expect(resp == .status);
    try std.testing.expectEqual(zix.Grpc.Status.INVALID_ARGUMENT, resp.status);

    zix.Http2.sendGoawayFD(client.fd, stream_id, zix.Http2.ERR_NO_ERROR) catch {};
    server_thread.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix edge: GrpcClientConfig, recv_timeout_ms = 0 disables timeout (default)" {
    const cfg = zix.Grpc.ClientConfig{ .ip = "127.0.0.1", .port = 8083 };
    try std.testing.expectEqual(@as(u32, 0), cfg.recv_timeout_ms);
}

test "zix edge: GrpcClientConfig, send_timeout_ms = 0 disables timeout (default)" {
    const cfg = zix.Grpc.ClientConfig{ .ip = "127.0.0.1", .port = 8083 };
    try std.testing.expectEqual(@as(u32, 0), cfg.send_timeout_ms);
}

test "zix edge: GrpcClientConfig, large recv_timeout_ms value is stored without overflow" {
    const cfg = zix.Grpc.ClientConfig{
        .ip = "127.0.0.1",
        .port = 8083,
        .recv_timeout_ms = std.math.maxInt(u32),
    };
    try std.testing.expectEqual(std.math.maxInt(u32), cfg.recv_timeout_ms);
}
