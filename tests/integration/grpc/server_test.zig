//! Integration tests: gRPC h2c round-trips over real TCP using zix.Grpc.serveConn.
//! Covers: server init, unary, server streaming, client streaming, bidirectional, unknown path.

const std = @import("std");
const zix = @import("zix");

const TEST_PORT: u16 = 18200;

// --------------------------------------------------------- //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

// --------------------------------------------------------- //
// Handlers

fn echoHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;
    while (ctx.recvMessage()) |msg| {
        ctx.sendMessage("application/grpc+proto", msg);
    }
    ctx.finish(zix.Grpc.Status.OK, "");
}

fn greetHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;
    const name = ctx.recvMessage() orelse {
        ctx.finish(zix.Grpc.Status.INVALID_ARGUMENT, "no message");
        return;
    };
    var out: [256]u8 = undefined;
    const resp = std.fmt.bufPrint(&out, "Hello, {s}!", .{name}) catch "Hello!";
    ctx.sendMessage("application/grpc+proto", resp);
    ctx.finish(zix.Grpc.Status.OK, "");
}

fn collectHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;
    var count: usize = 0;
    while (ctx.recvMessage()) |_| count += 1;
    var out: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&out, "got {d}", .{count}) catch "got ?";
    ctx.sendMessage("application/grpc+proto", s);
    ctx.finish(zix.Grpc.Status.OK, "");
}

// --------------------------------------------------------- //

fn makeRunner(comptime routes: []const zix.Grpc.Route) type {
    return struct {
        fn run(ctx: *ServerCtx, io: std.Io) void {
            const stream = ctx.listener.accept(io) catch |e| {
                ctx.err = e;
                return;
            };
            const fd = stream.socket.handle;
            zix.Grpc.serveConn(routes, fd, .{});
            _ = std.posix.system.close(fd);
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

test "zix integration: GrpcServer.init and deinit do not error" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try zix.Grpc.Server.init(&[_]zix.Grpc.Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 8083 });
    server.deinit();
}

test "zix integration: GrpcServer.init port zero returns PortNotConfigured" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(
        error.PortNotConfigured,
        zix.Grpc.Server.init(&[_]zix.Grpc.Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 0 }),
    );
}

test "zix integration: gRPC unary returns greeting" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const R = makeRunner(&[_]zix.Grpc.Route{
        .{ .path = "/svc.Svc/Greet", .handler = greetHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT, R.run);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = TEST_PORT }, io);
    defer client.deinit();

    var buf: [256]u8 = undefined;
    const resp = try client.unary("/svc.Svc/Greet", "application/grpc+proto", "world", &buf);
    try std.testing.expectEqualStrings("Hello, world!", resp);

    zix.Http2.sendGoaway(client.fd, 1, zix.Http2.ERR_NO_ERROR) catch {};
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: gRPC server streaming sends multiple responses" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const R = makeRunner(&[_]zix.Grpc.Route{
        .{ .path = "/svc.Svc/Echo", .handler = echoHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 1, R.run);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = TEST_PORT + 1 }, io);
    defer client.deinit();

    const sid = try client.openStream("/svc.Svc/Echo", "application/grpc+proto");
    try client.sendMessage(sid, "aaa");
    try client.sendMessage(sid, "bbb");
    try client.endStream(sid);

    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    const r1 = try client.recvResponse(sid, &b1);
    try std.testing.expectEqualStrings("aaa", r1.data);

    const r2 = try client.recvResponse(sid, &b2);
    try std.testing.expectEqualStrings("bbb", r2.data);

    const fin = try client.recvResponse(sid, &b1);
    try std.testing.expect(fin == .status);
    try std.testing.expectEqual(zix.Grpc.Status.OK, fin.status);

    zix.Http2.sendGoaway(client.fd, sid, zix.Http2.ERR_NO_ERROR) catch {};
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: gRPC client streaming collects all messages" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const R = makeRunner(&[_]zix.Grpc.Route{
        .{ .path = "/svc.Svc/Collect", .handler = collectHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 2, R.run);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = TEST_PORT + 2 }, io);
    defer client.deinit();

    const sid = try client.openStream("/svc.Svc/Collect", "application/grpc+proto");
    try client.sendMessage(sid, "a");
    try client.sendMessage(sid, "b");
    try client.sendMessage(sid, "c");
    try client.endStream(sid);

    var buf: [64]u8 = undefined;
    const r = try client.recvResponse(sid, &buf);
    try std.testing.expectEqualStrings("got 3", r.data);

    const fin = try client.recvResponse(sid, &buf);
    try std.testing.expect(fin == .status);
    try std.testing.expectEqual(zix.Grpc.Status.OK, fin.status);

    zix.Http2.sendGoaway(client.fd, sid, zix.Http2.ERR_NO_ERROR) catch {};
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: gRPC bidirectional echoes each message" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const R = makeRunner(&[_]zix.Grpc.Route{
        .{ .path = "/svc.Svc/BidiEcho", .handler = echoHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 3, R.run);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = TEST_PORT + 3 }, io);
    defer client.deinit();

    const sid = try client.openStream("/svc.Svc/BidiEcho", "application/grpc+proto");
    try client.sendMessage(sid, "ping");
    try client.sendMessage(sid, "pong");
    try client.endStream(sid);

    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    const rx1 = try client.recvResponse(sid, &b1);
    try std.testing.expectEqualStrings("ping", rx1.data);

    const rx2 = try client.recvResponse(sid, &b2);
    try std.testing.expectEqualStrings("pong", rx2.data);

    zix.Http2.sendGoaway(client.fd, sid, zix.Http2.ERR_NO_ERROR) catch {};
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: gRPC unknown method returns UNIMPLEMENTED" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const R = makeRunner(&[_]zix.Grpc.Route{
        .{ .path = "/svc.Svc/Greet", .handler = greetHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 4, R.run);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = TEST_PORT + 4 }, io);
    defer client.deinit();

    const sid = try client.openStream("/svc.Svc/Unknown", "application/grpc+proto");
    try client.sendMessage(sid, "test");
    try client.endStream(sid);

    var buf: [64]u8 = undefined;
    const resp = try client.recvResponse(sid, &buf);
    try std.testing.expect(resp == .status);
    try std.testing.expectEqual(zix.Grpc.Status.UNIMPLEMENTED, resp.status);

    zix.Http2.sendGoaway(client.fd, sid, zix.Http2.ERR_NO_ERROR) catch {};
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
