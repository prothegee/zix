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

fn nopHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;
    ctx.finish(zix.Grpc.Status.OK, "");
}

fn errorOnlyHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;
    ctx.finish(zix.Grpc.Status.INVALID_ARGUMENT, "bad");
}

fn runServer(ctx: *ServerCtx, io: std.Io) void {
    const stream = ctx.listener.accept(io) catch |e| {
        ctx.err = e;
        return;
    };
    const fd = stream.socket.handle;
    zix.Grpc.serveConn(&[_]zix.Grpc.Route{.{ .path = "/nop/Nop", .handler = nopHandler }}, fd, .{});
    _ = std.posix.system.close(fd);
}

fn runErrorServer(ctx: *ServerCtx, io: std.Io) void {
    const stream = ctx.listener.accept(io) catch |e| {
        ctx.err = e;
        return;
    };
    const fd = stream.socket.handle;
    zix.Grpc.serveConn(&[_]zix.Grpc.Route{.{ .path = "/nop/Nop", .handler = errorOnlyHandler }}, fd, .{});
    _ = std.posix.system.close(fd);
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

test "zix edge: readGrpcPrefix with 4 bytes returns TooShort" {
    const body = [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.TooShort, zix.Grpc.readPrefix(&body));
}

test "zix edge: readGrpcPrefix with empty slice returns TooShort" {
    try std.testing.expectError(error.TooShort, zix.Grpc.readPrefix(&.{}));
}

test "zix edge: GrpcContext.recvMessage body shorter than prefix returns null" {
    const body = [_]u8{ 0, 0, 0 };
    var ctx = zix.Grpc.Context{ .fd = 0, .stream_id = 1, ._body = &body, ._pos = 0, ._hdr_sent = false, ._sent_bytes = 0, ._grpc_status = 0 };
    try std.testing.expect(ctx.recvMessage() == null);
}

test "zix edge: GrpcContext.recvMessage msg_len exceeds body returns null" {
    var body: [5]u8 = undefined;
    zix.Grpc.writePrefix(body[0..5], false, 100);
    var ctx = zix.Grpc.Context{ .fd = 0, .stream_id = 1, ._body = &body, ._pos = 0, ._hdr_sent = false, ._sent_bytes = 0, ._grpc_status = 0 };
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
        error.PortNotConfigured,
        zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = 0 }, io),
    );
}

test "zix edge: gRPC serveConn closes cleanly on immediate client disconnect" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT);

    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT);
    const stream = try addr.connect(io, .{ .mode = .stream });
    _ = std.posix.system.close(stream.socket.handle);

    t.join();
    ctx.listener.deinit(io);
}

test "zix edge: gRPC finish-only handler delivers error status to client" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnErrorServer(&ctx, io, TEST_PORT + 1);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = TEST_PORT + 1 }, io);
    defer client.deinit();

    const stream_id = try client.openStream("/nop/Nop", "application/grpc+proto");
    try client.sendMessage(stream_id, "trigger");
    try client.endStream(stream_id);

    var buf: [64]u8 = undefined;
    const resp = try client.recvResponse(stream_id, &buf);
    try std.testing.expect(resp == .status);
    try std.testing.expectEqual(zix.Grpc.Status.INVALID_ARGUMENT, resp.status);

    zix.Http2.sendGoaway(client.fd, stream_id, zix.Http2.ERR_NO_ERROR) catch {};
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
