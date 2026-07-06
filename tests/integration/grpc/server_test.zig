//! Integration tests: gRPC h2c round-trips over real TCP using zix.Grpc.serveConn.
//! Covers: server init, unary, server streaming, client streaming, bidirectional, unknown path,
//! trailers-only error response, two sequential streams on one connection,
//! and HPACK dynamic table stability across requests (regression for Bug 2 root cause).

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
    var server = zix.Grpc.Server.init(&[_]zix.Grpc.Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 8083, .dispatch_model = .ASYNC });
    server.deinit();
}

test "zix integration: GrpcServer.run port zero returns PortNotConfigured" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = zix.Grpc.Server.init(&[_]zix.Grpc.Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 0, .dispatch_model = .ASYNC });
    defer server.deinit();

    try std.testing.expectError(error.PortNotConfigured, server.run());
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

    zix.Http2.sendGoawayFD(client.fd, 1, zix.Http2.ERR_NO_ERROR) catch {};
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

    zix.Http2.sendGoawayFD(client.fd, stream_id, zix.Http2.ERR_NO_ERROR) catch {};
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

    zix.Http2.sendGoawayFD(client.fd, stream_id, zix.Http2.ERR_NO_ERROR) catch {};
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

    zix.Http2.sendGoawayFD(client.fd, stream_id, zix.Http2.ERR_NO_ERROR) catch {};
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

    zix.Http2.sendGoawayFD(client.fd, stream_id, zix.Http2.ERR_NO_ERROR) catch {};
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

    zix.Http2.sendGoawayFD(client.fd, stream_id, zix.Http2.ERR_NO_ERROR) catch {};
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

    zix.Http2.sendGoawayFD(client.fd, stream_id2, zix.Http2.ERR_NO_ERROR) catch {};
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

// --------------------------------------------------------- //

// sendRawFrame writes a complete H2 frame to the fd.
fn sendRawFrame(fd: std.posix.fd_t, frame_type: u8, flags: u8, stream_id: u31, payload: []const u8) !void {
    var header: [9]u8 = undefined;
    header[0] = @intCast((payload.len >> 16) & 0xFF);
    header[1] = @intCast((payload.len >> 8) & 0xFF);
    header[2] = @intCast(payload.len & 0xFF);
    header[3] = frame_type;
    header[4] = flags;
    header[5] = @intCast((stream_id >> 24) & 0x7F);
    header[6] = @intCast((stream_id >> 16) & 0xFF);
    header[7] = @intCast((stream_id >> 8) & 0xFF);
    header[8] = @intCast(stream_id & 0xFF);

    try zix.Http2.writeAllFD(fd, &header);
    if (payload.len > 0) try zix.Http2.writeAllFD(fd, payload);
}

// sendGrpcDataFrame wraps a message in a 5-byte gRPC length-prefix and sends it as a DATA frame.
fn sendGrpcDataFrame(fd: std.posix.fd_t, stream_id: u31, data: []const u8, end_stream: bool) !void {
    var frame_buf: [65 + 5]u8 = undefined;
    zix.Grpc.writePrefix(frame_buf[0..5], false, @intCast(data.len));
    @memcpy(frame_buf[5..][0..data.len], data);
    const flags: u8 = if (end_stream) 0x01 else 0x00;

    try sendRawFrame(fd, 0x0, flags, stream_id, frame_buf[0 .. 5 + data.len]);
}

// sendHeadersIncrementalHpack sends a HEADERS frame using HPACK incremental indexing (0x40).
// After this call, server's HPACK dynamic table will have:
//   dyn[0] = content-type (idx 62), dyn[1] = :path (idx 63)
// This matches what real gRPC clients (grpc-go, ghz) send on the first request.
fn sendHeadersIncrementalHpack(fd: std.posix.fd_t, stream_id: u31, path: []const u8, content_type: []const u8) !void {
    var payload: [256]u8 = undefined;
    var pos: usize = 0;

    // :method POST: indexed (static idx 3 = 0x83)
    payload[pos] = 0x83;
    pos += 1;

    // :path with incremental indexing: 0x40 | 4 (static idx 4 = :path name)
    payload[pos] = 0x44;
    pos += 1;
    payload[pos] = @intCast(path.len);
    pos += 1;
    @memcpy(payload[pos..][0..path.len], path);
    pos += path.len;

    // :scheme http: indexed (static idx 6 = 0x86)
    payload[pos] = 0x86;
    pos += 1;

    // content-type with incremental indexing: 0x40 | 31 (static idx 31 = content-type name)
    payload[pos] = 0x5F;
    pos += 1;
    payload[pos] = @intCast(content_type.len);
    pos += 1;
    @memcpy(payload[pos..][0..content_type.len], content_type);
    pos += content_type.len;

    // te: trailers: literal without indexing (name and value literal)
    payload[pos] = 0x00;
    pos += 1;
    const te_name = "te";
    payload[pos] = @intCast(te_name.len);
    pos += 1;
    @memcpy(payload[pos..][0..te_name.len], te_name);
    pos += te_name.len;
    const te_value = "trailers";
    payload[pos] = @intCast(te_value.len);
    pos += 1;
    @memcpy(payload[pos..][0..te_value.len], te_value);
    pos += te_value.len;

    // FLAG_END_HEADERS = 0x04
    try sendRawFrame(fd, 0x1, 0x04, stream_id, payload[0..pos]);
}

// sendHeadersIndexedHpack sends a HEADERS frame using fully-indexed HPACK references.
// Requires that request 1 used sendHeadersIncrementalHpack first so the server's
// dynamic table is populated:
//   dyn[0] = content-type (added last -> overall HPACK idx 62 -> 0x80|62 = 0xBE)
//   dyn[1] = :path        (added first -> overall HPACK idx 63 -> 0x80|63 = 0xBF)
// Bug 2 root cause: without the dyn_buf fix, dyn[1].value pointed into a zeroed scratch
// and the server read an empty :path, returning UNIMPLEMENTED.
fn sendHeadersIndexedHpack(fd: std.posix.fd_t, stream_id: u31) !void {
    var payload: [8]u8 = undefined;
    var pos: usize = 0;

    // :method POST: static idx 3
    payload[pos] = 0x83;
    pos += 1;
    // content-type: dynamic slot 1 (most recent) -> overall idx 62 -> 0x80|62 = 0xBE
    payload[pos] = 0xBE;
    pos += 1;
    // :scheme http: static idx 6
    payload[pos] = 0x86;
    pos += 1;
    // :path: dynamic slot 2 (older) -> overall idx 63 -> 0x80|63 = 0xBF
    payload[pos] = 0xBF;
    pos += 1;

    try sendRawFrame(fd, 0x1, 0x04, stream_id, payload[0..pos]);
}

// recvFramesUntilData reads frames until a DATA frame on the given stream arrives.
// Transparently handles SETTINGS ACK, WINDOW_UPDATE, and HEADERS frames.
// Returns the gRPC status from a trailers HEADERS frame, or .OK on DATA.
fn recvFramesUntilStatus(fd: std.posix.fd_t, stream_id: u31) !zix.Grpc.Status {
    var header_buf: [9]u8 = undefined;
    while (true) {
        try zix.Http2.recvExact(fd, &header_buf);
        const length: usize = (@as(usize, header_buf[0]) << 16) | (@as(usize, header_buf[1]) << 8) | header_buf[2];
        const frame_type = header_buf[3];
        const flags = header_buf[4];
        const recv_sid: u31 = @intCast(
            ((@as(u32, header_buf[5]) & 0x7F) << 24) | (@as(u32, header_buf[6]) << 16) |
                (@as(u32, header_buf[7]) << 8) | header_buf[8],
        );

        var payload_buf: [16384]u8 = undefined;
        if (length > 0) try zix.Http2.recvExact(fd, payload_buf[0..length]);
        const payload = payload_buf[0..length];

        // Trailers HEADERS have both END_HEADERS (0x04) and END_STREAM (0x01).
        // Response HEADERS (status 200) have END_HEADERS but NOT END_STREAM, skip those.
        if (frame_type == 0x1 and recv_sid == stream_id and
            (flags & 0x04) != 0 and (flags & 0x01) != 0)
        {
            var dec = zix.Http2.HpackDecoder.init();
            var out: [16]zix.Http2.Header = undefined;
            var scratch: [512]u8 = undefined;
            const count = dec.decode(payload, &out, &scratch) catch return .INTERNAL;
            for (out[0..count]) |hdr| {
                if (std.mem.eql(u8, hdr.name, "grpc-status")) {
                    const code = std.fmt.parseInt(u8, hdr.value, 10) catch 13;
                    return @enumFromInt(code);
                }
            }
            return .OK;
        }
    }
}

test "zix integration: gRPC second request HPACK indexed path returns correct response" {
    // Regression test for Bug 2 HPACK root cause.
    // Real gRPC clients (grpc-go, ghz) use incremental indexing (0x40) on request 1,
    // then fully-indexed (0x80) on request 2. Without the dyn_buf fix, the server's
    // dyn[] entries aliased per-stream scratch that was zeroed on slot reuse, causing
    // an empty :path -> Router returns UNIMPLEMENTED on every request after the first.
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    const Runner = makeRunner(&[_]zix.Grpc.Route{
        .{ .path = "/svc.Svc/Greet", .handler = greetHandler },
    });
    var server_ctx: ServerCtx = undefined;

    // This server must handle 2 requests, so use a loop runner.
    const MultiRunner = struct {
        fn run(ctx: *ServerCtx, run_io: std.Io) void {
            const stream = ctx.listener.accept(run_io) catch |e| {
                ctx.err = e;
                return;
            };
            const fd = stream.socket.handle;
            zix.Grpc.serveConn(&[_]zix.Grpc.Route{
                .{ .path = "/svc.Svc/Greet", .handler = greetHandler },
            }, fd, .{});
            _ = std.posix.system.close(fd);
        }
    };
    _ = Runner;

    const t = try spawnServer(&server_ctx, io, TEST_PORT + 7, MultiRunner.run);

    // Open a raw TCP connection and perform the H2 handshake manually.
    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT + 7);
    const raw_stream = try addr.connect(io, .{ .mode = .stream });
    const fd = raw_stream.socket.handle;
    defer _ = std.posix.system.close(fd);

    try zix.Http2.writeAllFD(fd, zix.Http2.PREFACE);

    // Send client SETTINGS (empty).
    try sendRawFrame(fd, 0x4, 0x00, 0, &.{});

    // Read and ACK server SETTINGS.
    var settings_header: [9]u8 = undefined;
    try zix.Http2.recvExact(fd, &settings_header);
    const settings_len: usize = (@as(usize, settings_header[0]) << 16) | (@as(usize, settings_header[1]) << 8) | settings_header[2];
    var settings_payload: [64]u8 = undefined;
    if (settings_len > 0) try zix.Http2.recvExact(fd, settings_payload[0..settings_len]);
    try sendRawFrame(fd, 0x4, 0x01, 0, &.{});

    // Request 1: HEADERS with incremental indexing (0x40), populates server dyn table.
    // Sends :path "/svc.Svc/Greet" as literal-with-incremental-indexing.
    try sendHeadersIncrementalHpack(fd, 1, "/svc.Svc/Greet", "application/grpc+proto");

    // DATA frame with gRPC message "carol", END_STREAM.
    try sendGrpcDataFrame(fd, 1, "carol", true);

    // Drain response for stream 1.
    const status1 = try recvFramesUntilStatus(fd, 1);
    try std.testing.expectEqual(zix.Grpc.Status.OK, status1);

    // Request 2: HEADERS with fully-indexed (0x80) references to dynamic table.
    // Without dyn_buf fix: server dyn[] aliased zeroed scratch -> :path = "" -> UNIMPLEMENTED.
    // With fix: server dyn[] points into dyn_buf -> :path = "/svc.Svc/Greet" -> OK.
    try sendHeadersIndexedHpack(fd, 3);
    try sendGrpcDataFrame(fd, 3, "dave", true);

    const status2 = try recvFramesUntilStatus(fd, 3);
    try std.testing.expectEqual(zix.Grpc.Status.OK, status2);

    try sendRawFrame(fd, 0x7, 0x00, 0, &[_]u8{ 0, 0, 0, 3, 0, 0, 0, 0 }); // GOAWAY last=3
    t.join();
    server_ctx.listener.deinit(io);
    try std.testing.expect(server_ctx.err == null);
}

test "zix integration: GrpcClient, recv_timeout_ms fires when server sends no data" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", 18100);
    var stall_listener = try addr.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = 4,
    });
    defer stall_listener.deinit(io);

    var client = try zix.Grpc.Client.connect(.{
        .ip = "127.0.0.1",
        .port = 18100,
        .recv_timeout_ms = 200,
    }, io);
    defer client.deinit();

    const sid = try client.openStream("/svc.Svc/Test", "application/grpc+proto");
    try client.sendMessage(sid, "test");
    try client.endStream(sid);

    var buf: [256]u8 = undefined;
    const result = client.recvResponse(sid, &buf);
    if (result) |_| return error.ExpectedRecvTimeout else |_| {}
}
