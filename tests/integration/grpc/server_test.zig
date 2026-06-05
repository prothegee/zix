//! Integration tests: gRPC h2c round-trips over real TCP using zix.Grpc.serveConn.
//! Covers: server init, unary, server streaming, client streaming, bidirectional, unknown path,
//! trailers-only error response, and two sequential streams on one connection.

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

fn errorOnlyHandler(headers: []const zix.Http2.Header, ctx: *zix.Grpc.Context) void {
    _ = headers;
    ctx.finish(zix.Grpc.Status.INVALID_ARGUMENT, "bad req");
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

    const Runner = makeRunner(&[_]zix.Grpc.Route{
        .{ .path = "/svc.Svc/Greet", .handler = greetHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT, Runner.run);

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

    const Runner = makeRunner(&[_]zix.Grpc.Route{
        .{ .path = "/svc.Svc/Echo", .handler = echoHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 1, Runner.run);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = TEST_PORT + 1 }, io);
    defer client.deinit();

    const stream_id = try client.openStream("/svc.Svc/Echo", "application/grpc+proto");
    try client.sendMessage(stream_id, "aaa");
    try client.sendMessage(stream_id, "bbb");
    try client.endStream(stream_id);

    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    const resp1 = try client.recvResponse(stream_id, &buf1);
    try std.testing.expectEqualStrings("aaa", resp1.data);

    const resp2 = try client.recvResponse(stream_id, &buf2);
    try std.testing.expectEqualStrings("bbb", resp2.data);

    const fin = try client.recvResponse(stream_id, &buf1);
    try std.testing.expect(fin == .status);
    try std.testing.expectEqual(zix.Grpc.Status.OK, fin.status);

    zix.Http2.sendGoaway(client.fd, stream_id, zix.Http2.ERR_NO_ERROR) catch {};
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: gRPC client streaming collects all messages" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const Runner = makeRunner(&[_]zix.Grpc.Route{
        .{ .path = "/svc.Svc/Collect", .handler = collectHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 2, Runner.run);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = TEST_PORT + 2 }, io);
    defer client.deinit();

    const stream_id = try client.openStream("/svc.Svc/Collect", "application/grpc+proto");
    try client.sendMessage(stream_id, "a");
    try client.sendMessage(stream_id, "b");
    try client.sendMessage(stream_id, "c");
    try client.endStream(stream_id);

    var buf: [64]u8 = undefined;
    const resp = try client.recvResponse(stream_id, &buf);
    try std.testing.expectEqualStrings("got 3", resp.data);

    const fin = try client.recvResponse(stream_id, &buf);
    try std.testing.expect(fin == .status);
    try std.testing.expectEqual(zix.Grpc.Status.OK, fin.status);

    zix.Http2.sendGoaway(client.fd, stream_id, zix.Http2.ERR_NO_ERROR) catch {};
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: gRPC bidirectional echoes each message" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const Runner = makeRunner(&[_]zix.Grpc.Route{
        .{ .path = "/svc.Svc/BidiEcho", .handler = echoHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 3, Runner.run);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = TEST_PORT + 3 }, io);
    defer client.deinit();

    const stream_id = try client.openStream("/svc.Svc/BidiEcho", "application/grpc+proto");
    try client.sendMessage(stream_id, "ping");
    try client.sendMessage(stream_id, "pong");
    try client.endStream(stream_id);

    var buf1: [32]u8 = undefined;
    var buf2: [32]u8 = undefined;
    const resp1 = try client.recvResponse(stream_id, &buf1);
    try std.testing.expectEqualStrings("ping", resp1.data);

    const resp2 = try client.recvResponse(stream_id, &buf2);
    try std.testing.expectEqualStrings("pong", resp2.data);

    zix.Http2.sendGoaway(client.fd, stream_id, zix.Http2.ERR_NO_ERROR) catch {};
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: gRPC unknown method returns UNIMPLEMENTED" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const Runner = makeRunner(&[_]zix.Grpc.Route{
        .{ .path = "/svc.Svc/Greet", .handler = greetHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 4, Runner.run);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = TEST_PORT + 4 }, io);
    defer client.deinit();

    const stream_id = try client.openStream("/svc.Svc/Unknown", "application/grpc+proto");
    try client.sendMessage(stream_id, "test");
    try client.endStream(stream_id);

    var buf: [64]u8 = undefined;
    const resp = try client.recvResponse(stream_id, &buf);
    try std.testing.expect(resp == .status);
    try std.testing.expectEqual(zix.Grpc.Status.UNIMPLEMENTED, resp.status);

    zix.Http2.sendGoaway(client.fd, stream_id, zix.Http2.ERR_NO_ERROR) catch {};
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: gRPC trailers-only error is received as INVALID_ARGUMENT" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const Runner = makeRunner(&[_]zix.Grpc.Route{
        .{ .path = "/svc.Svc/Fail", .handler = errorOnlyHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 5, Runner.run);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = TEST_PORT + 5 }, io);
    defer client.deinit();

    const stream_id = try client.openStream("/svc.Svc/Fail", "application/grpc+proto");
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

test "zix integration: gRPC two streams on same connection both return OK" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const Runner = makeRunner(&[_]zix.Grpc.Route{
        .{ .path = "/svc.Svc/Greet", .handler = greetHandler },
    });
    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 6, Runner.run);

    var client = try zix.Grpc.Client.connect(.{ .ip = "127.0.0.1", .port = TEST_PORT + 6 }, io);
    defer client.deinit();

    const stream_id1 = try client.openStream("/svc.Svc/Greet", "application/grpc+proto");
    try client.sendMessage(stream_id1, "alice");
    try client.endStream(stream_id1);

    var buf_alice: [64]u8 = undefined;
    const resp_alice = try client.recvResponse(stream_id1, &buf_alice);
    try std.testing.expectEqualStrings("Hello, alice!", resp_alice.data);
    const status_alice = try client.recvResponse(stream_id1, &buf_alice);
    try std.testing.expect(status_alice == .status);
    try std.testing.expectEqual(zix.Grpc.Status.OK, status_alice.status);

    const stream_id2 = try client.openStream("/svc.Svc/Greet", "application/grpc+proto");
    try client.sendMessage(stream_id2, "bob");
    try client.endStream(stream_id2);

    var buf_bob: [64]u8 = undefined;
    const resp_bob = try client.recvResponse(stream_id2, &buf_bob);
    try std.testing.expectEqualStrings("Hello, bob!", resp_bob.data);
    const status_bob = try client.recvResponse(stream_id2, &buf_bob);
    try std.testing.expect(status_bob == .status);
    try std.testing.expectEqual(zix.Grpc.Status.OK, status_bob.status);

    zix.Http2.sendGoaway(client.fd, stream_id2, zix.Http2.ERR_NO_ERROR) catch {};
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
