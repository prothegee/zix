//! gRPC PoC edge tests: boundary conditions and error paths over real TCP.
//! Run: zig test rnd/grpc_edge_test.zig

const std = @import("std");
const h2 = @import("http2_poc_core.zig");
const grpc = @import("grpc_poc_core.zig");

const TEST_PORT: u16 = 18320;

// ------------------------------------------------------------------ //
// Server and client helpers                                           //
// ------------------------------------------------------------------ //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

fn runServer(ctx: *ServerCtx, io: std.Io) void {
    const stream = ctx.listener.accept(io) catch |e| {
        ctx.err = e;
        return;
    };
    grpc.serveConn(stream, io, testHandler);
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

fn sendPreface(fd: std.posix.fd_t) !void {
    try h2.fdWriteAll(fd, h2.PREFACE);
    try h2.sendSettings(fd, &.{});
}

// Send HEADERS + DATA with an arbitrary raw body (no gRPC prefix wrapping done here).
fn sendRawRequest(
    fd: std.posix.fd_t,
    sid: u31,
    path: []const u8,
    content_type: []const u8,
    raw_body: []const u8,
) !void {
    var hbuf: [512]u8 = undefined;
    var enc = h2.HpackEncoder.init(&hbuf);
    try enc.writeHeader(":method", "POST");
    try enc.writeHeader(":path", path);
    try enc.writeHeader(":scheme", "http");
    try enc.writeHeader(":authority", "localhost");
    try enc.writeHeader("content-type", content_type);
    try enc.writeHeader("te", "trailers");
    const hblock = enc.encoded();
    try h2.writeFrameHeader(fd, .{
        .length = @intCast(hblock.len),
        .frame_type = h2.FT_HEADERS,
        .flags = h2.FLAG_END_HEADERS,
        .stream_id = sid,
    });
    try h2.fdWriteAll(fd, hblock);

    if (raw_body.len > 0) {
        try h2.writeFrameHeader(fd, .{
            .length = @intCast(raw_body.len),
            .frame_type = h2.FT_DATA,
            .flags = h2.FLAG_END_STREAM,
            .stream_id = sid,
        });
        try h2.fdWriteAll(fd, raw_body);
    } else {
        try h2.writeFrameHeader(fd, .{
            .length = 0,
            .frame_type = h2.FT_DATA,
            .flags = h2.FLAG_END_STREAM,
            .stream_id = sid,
        });
    }
}

fn recvGrpcStatus(fd: std.posix.fd_t, sid: u31) !u8 {
    var grpc_status: u8 = 255;
    var payload_buf: [h2.MAX_PAYLOAD + 256]u8 = undefined;
    var hpack = h2.HpackDecoder.init();
    var hdrs: [32]h2.Header = undefined;
    var scratch: [2048]u8 = undefined;

    while (true) {
        const fh = try h2.readFrameHeader(fd);
        const payload = payload_buf[0..fh.length];
        if (fh.length > 0) try h2.recvExact(fd, payload);

        switch (fh.frame_type) {
            h2.FT_SETTINGS => {
                if ((fh.flags & h2.FLAG_ACK) == 0) try h2.sendSettingsAck(fd);
            },
            h2.FT_WINDOW_UPDATE => {},
            h2.FT_PING => {
                if ((fh.flags & h2.FLAG_ACK) == 0) {
                    var p8: [8]u8 = undefined;
                    @memcpy(&p8, payload[0..8]);
                    try h2.sendPingAck(fd, p8);
                }
            },
            h2.FT_HEADERS => {
                if (fh.stream_id != sid) continue;
                const n = try hpack.decode(payload, &hdrs, &scratch);
                for (hdrs[0..n]) |hdr| {
                    if (std.mem.eql(u8, hdr.name, "grpc-status"))
                        grpc_status = std.fmt.parseInt(u8, hdr.value, 10) catch 255;
                }
                if ((fh.flags & h2.FLAG_END_STREAM) != 0) return grpc_status;
            },
            h2.FT_DATA => {},
            h2.FT_GOAWAY => return error.ServerGoaway,
            h2.FT_RST_STREAM => return error.StreamReset,
            else => {},
        }
    }
}

// ------------------------------------------------------------------ //
// Test handler                                                        //
// ------------------------------------------------------------------ //

fn testHandler(
    method: []const u8,
    path: []const u8,
    headers: []const h2.Header,
    body: []const u8,
    fd: std.posix.fd_t,
    sid: u31,
) void {
    _ = method;

    const ct = grpc.detectContentType(headers);
    const grpc_path = grpc.parsePath(path) orelse {
        grpc.sendGrpcError(fd, sid, grpc.GRPC_UNIMPLEMENTED, "invalid path") catch {};
        return;
    };

    if (std.mem.eql(u8, grpc_path.package_service, "helloworld.Greeter") and
        std.mem.eql(u8, grpc_path.method, "SayHello"))
    {
        switch (ct) {
            .PROTO => sayHelloProto(body, fd, sid),
            .JSON => {
                grpc.sendGrpcError(fd, sid, grpc.GRPC_UNIMPLEMENTED, "json not in edge handler") catch {};
            },
            .UNKNOWN => grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "bad content-type") catch {},
        }
        return;
    }

    grpc.sendGrpcError(fd, sid, grpc.GRPC_UNIMPLEMENTED, "unknown method") catch {};
}

fn sayHelloProto(body: []const u8, fd: std.posix.fd_t, sid: u31) void {
    const prefix = grpc.readGrpcPrefix(body) catch {
        grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "bad prefix") catch {};
        return;
    };
    if (body.len < 5 + @as(usize, prefix.msg_len)) {
        grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "truncated body") catch {};
        return;
    }
    const msg_bytes = body[5..][0..prefix.msg_len];

    var name: []const u8 = "";
    var reader = grpc.MessageReader.init(msg_bytes);
    while (reader.next() catch null) |field| {
        if (field.field_number == 1 and field.wire_type == grpc.WT_LEN)
            name = field.payload;
    }

    var msg_buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&msg_buf, "Hello, {s}!", .{name}) catch "Hello!";
    var resp_buf: [512]u8 = undefined;
    const resp_len = grpc.encodeString(1, message, &resp_buf);

    grpc.sendGrpcHeaders(fd, sid, "application/grpc+proto") catch return;
    grpc.sendGrpcData(fd, sid, resp_buf[0..resp_len]) catch return;
    grpc.sendGrpcTrailer(fd, sid, grpc.GRPC_OK, "") catch {};
}

// ------------------------------------------------------------------ //
// Edge tests                                                          //
// ------------------------------------------------------------------ //

test "edge: unknown content-type returns INVALID_ARGUMENT" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT);

    const fd = try clientConnect(io, TEST_PORT);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);
    // content-type is not grpc at all
    try sendRawRequest(fd, 1, "/helloworld.Greeter/SayHello", "application/json", &.{});

    const status = try recvGrpcStatus(fd, 1);
    try std.testing.expectEqual(@as(u8, grpc.GRPC_INVALID_ARGUMENT), status);

    try h2.sendGoaway(fd, 1, h2.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "edge: body shorter than 5-byte prefix returns INVALID_ARGUMENT" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 1);

    const fd = try clientConnect(io, TEST_PORT + 1);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);
    // Only 3 bytes of body, not enough for the 5-byte gRPC prefix
    try sendRawRequest(fd, 1, "/helloworld.Greeter/SayHello", "application/grpc+proto", &.{ 0, 0, 0 });

    const status = try recvGrpcStatus(fd, 1);
    try std.testing.expectEqual(@as(u8, grpc.GRPC_INVALID_ARGUMENT), status);

    try h2.sendGoaway(fd, 1, h2.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "edge: zero-length gRPC message returns OK with empty name" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 2);

    const fd = try clientConnect(io, TEST_PORT + 2);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);
    // Valid 5-byte prefix with msg_len = 0, no proto fields
    const zero_msg = [_]u8{ 0, 0, 0, 0, 0 };
    try sendRawRequest(fd, 1, "/helloworld.Greeter/SayHello", "application/grpc+proto", &zero_msg);

    const status = try recvGrpcStatus(fd, 1);
    try std.testing.expectEqual(@as(u8, grpc.GRPC_OK), status);

    try h2.sendGoaway(fd, 1, h2.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "edge: unknown service/method returns UNIMPLEMENTED" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 3);

    const fd = try clientConnect(io, TEST_PORT + 3);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);
    try sendRawRequest(fd, 1, "/no.Such.Service/DoThing", "application/grpc+proto", &.{});

    const status = try recvGrpcStatus(fd, 1);
    try std.testing.expectEqual(@as(u8, grpc.GRPC_UNIMPLEMENTED), status);

    try h2.sendGoaway(fd, 1, h2.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "edge: truncated proto body (prefix says N bytes but body is shorter) returns INVALID_ARGUMENT" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 4);

    const fd = try clientConnect(io, TEST_PORT + 4);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);
    // Prefix claims msg_len = 100 but only 2 bytes follow
    const bad_body = [_]u8{ 0, 0, 0, 0, 100, 0xAA, 0xBB };
    try sendRawRequest(fd, 1, "/helloworld.Greeter/SayHello", "application/grpc+proto", &bad_body);

    const status = try recvGrpcStatus(fd, 1);
    try std.testing.expectEqual(@as(u8, grpc.GRPC_INVALID_ARGUMENT), status);

    try h2.sendGoaway(fd, 1, h2.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
