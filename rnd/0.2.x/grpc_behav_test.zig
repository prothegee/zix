//! gRPC PoC behaviour tests — observable API contracts over real TCP.
//! Run: zig test rnd/grpc_behav_test.zig

const std = @import("std");
const h2 = @import("http2_poc_core.zig");
const grpc = @import("grpc_poc_core.zig");

const TEST_PORT: u16 = 18310;

// ------------------------------------------------------------------ //
// Server and client helpers (same pattern as grpc_integ_test.zig)    //
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

fn sendGrpcRequest(
    fd: std.posix.fd_t,
    sid: u31,
    path: []const u8,
    content_type: []const u8,
    msg: []const u8,
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

    var prefix: [5]u8 = undefined;
    grpc.writeGrpcPrefix(&prefix, false, @intCast(msg.len));
    try h2.writeFrameHeader(fd, .{
        .length = @intCast(5 + msg.len),
        .frame_type = h2.FT_DATA,
        .flags = h2.FLAG_END_STREAM,
        .stream_id = sid,
    });
    try h2.fdWriteAll(fd, &prefix);
    try h2.fdWriteAll(fd, msg);
}

// Read all frames for a stream. Returns status, initial headers, trailer headers, and DATA bytes.
const FullResponse = struct {
    http_status: []const u8,
    content_type: []const u8,
    grpc_status: u8,
    data: []const u8,

    scratch: [4096]u8 = undefined,
    data_buf: [1024]u8 = undefined,
};

fn recvFullResponse(fd: std.posix.fd_t, sid: u31, out: *FullResponse) !void {
    out.http_status = "";
    out.content_type = "";
    out.grpc_status = 255;
    var data_len: usize = 0;

    var payload_buf: [h2.MAX_PAYLOAD + 256]u8 = undefined;
    var hpack = h2.HpackDecoder.init();
    var hdrs: [32]h2.Header = undefined;
    var scratch_pos: usize = 0;

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
                var scratch: [2048]u8 = undefined;
                const n = try hpack.decode(payload, &hdrs, &scratch);
                for (hdrs[0..n]) |hdr| {
                    if (std.mem.eql(u8, hdr.name, ":status")) {
                        const dst = out.scratch[scratch_pos..][0..hdr.value.len];
                        @memcpy(dst, hdr.value);
                        out.http_status = dst;
                        scratch_pos += hdr.value.len;
                    } else if (std.mem.eql(u8, hdr.name, "content-type")) {
                        const dst = out.scratch[scratch_pos..][0..hdr.value.len];
                        @memcpy(dst, hdr.value);
                        out.content_type = dst;
                        scratch_pos += hdr.value.len;
                    } else if (std.mem.eql(u8, hdr.name, "grpc-status")) {
                        out.grpc_status = std.fmt.parseInt(u8, hdr.value, 10) catch 255;
                    }
                }
                if ((fh.flags & h2.FLAG_END_STREAM) != 0) {
                    out.data = out.data_buf[0..data_len];
                    return;
                }
            },
            h2.FT_DATA => {
                if (fh.stream_id != sid) continue;
                const to_copy = @min(payload.len, out.data_buf.len - data_len);
                @memcpy(out.data_buf[data_len..][0..to_copy], payload[0..to_copy]);
                data_len += to_copy;
            },
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
        std.mem.eql(u8, grpc_path.method, "SayHello") and ct == .PROTO)
    {
        const prefix = grpc.readGrpcPrefix(body) catch {
            grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "bad prefix") catch {};
            return;
        };
        const msg_bytes = if (body.len >= 5 + @as(usize, prefix.msg_len))
            body[5..][0..prefix.msg_len]
        else
            &.{};

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
        return;
    }

    grpc.sendGrpcError(fd, sid, grpc.GRPC_UNIMPLEMENTED, "unknown") catch {};
}

// ------------------------------------------------------------------ //
// Behaviour tests                                                     //
// ------------------------------------------------------------------ //

test "behav: response :status is always 200" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT);

    const fd = try clientConnect(io, TEST_PORT);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);

    var req_buf: [32]u8 = undefined;
    const req_len = grpc.encodeString(1, "test", &req_buf);
    try sendGrpcRequest(fd, 1, "/helloworld.Greeter/SayHello", "application/grpc+proto", req_buf[0..req_len]);

    var resp: FullResponse = undefined;
    try recvFullResponse(fd, 1, &resp);
    try std.testing.expectEqualStrings("200", resp.http_status);

    try h2.sendGoaway(fd, 1, h2.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "behav: grpc-status 0 in trailer for successful call" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 1);

    const fd = try clientConnect(io, TEST_PORT + 1);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);

    var req_buf: [32]u8 = undefined;
    const req_len = grpc.encodeString(1, "x", &req_buf);
    try sendGrpcRequest(fd, 1, "/helloworld.Greeter/SayHello", "application/grpc+proto", req_buf[0..req_len]);

    var resp: FullResponse = undefined;
    try recvFullResponse(fd, 1, &resp);
    try std.testing.expectEqual(@as(u8, grpc.GRPC_OK), resp.grpc_status);

    try h2.sendGoaway(fd, 1, h2.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "behav: content-type is application/grpc+proto for proto request" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 2);

    const fd = try clientConnect(io, TEST_PORT + 2);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);

    var req_buf: [32]u8 = undefined;
    const req_len = grpc.encodeString(1, "y", &req_buf);
    try sendGrpcRequest(fd, 1, "/helloworld.Greeter/SayHello", "application/grpc+proto", req_buf[0..req_len]);

    var resp: FullResponse = undefined;
    try recvFullResponse(fd, 1, &resp);
    try std.testing.expectEqualStrings("application/grpc+proto", resp.content_type);

    try h2.sendGoaway(fd, 1, h2.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
