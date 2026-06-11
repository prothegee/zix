//! gRPC PoC integration tests: full round-trip over real TCP using serveConn.
//! Run: zig test rnd/grpc_integ_test.zig

const std = @import("std");
const h2 = @import("http2_poc_core.zig");
const grpc = @import("grpc_poc_core.zig");

const TEST_PORT: u16 = 18300;

// ------------------------------------------------------------------ //
// Test server helpers                                                 //
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

// ------------------------------------------------------------------ //
// Minimal h2c + gRPC client helpers                                  //
// ------------------------------------------------------------------ //

fn sendPreface(fd: std.posix.fd_t) !void {
    try h2.fdWriteAll(fd, h2.PREFACE);
    try h2.sendSettings(fd, &.{});
}

// Send a unary gRPC POST: HEADERS (no END_STREAM) + DATA (5-byte prefix + msg, END_STREAM).
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

// Read frames until END_STREAM on a HEADERS frame (gRPC trailer).
// Accumulates raw DATA bytes (including 5-byte prefix) into data_buf.
// Returns grpc-status code from the trailer.
const GrpcResponse = struct {
    grpc_status: u8,
    data: []const u8,
};

fn recvGrpcResponse(fd: std.posix.fd_t, sid: u31, data_buf: []u8) !GrpcResponse {
    var data_len: usize = 0;
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
                if ((fh.flags & h2.FLAG_END_STREAM) != 0)
                    return .{ .grpc_status = grpc_status, .data = data_buf[0..data_len] };
            },
            h2.FT_DATA => {
                if (fh.stream_id != sid) continue;
                const to_copy = @min(payload.len, data_buf.len - data_len);
                @memcpy(data_buf[data_len..][0..to_copy], payload[0..to_copy]);
                data_len += to_copy;
            },
            h2.FT_GOAWAY => return error.ServerGoaway,
            h2.FT_RST_STREAM => return error.StreamReset,
            else => {},
        }
    }
}

// ------------------------------------------------------------------ //
// Test handler (mirrors grpc_poc_server.zig routes)                  //
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
        if (ct == .PROTO) {
            sayHelloProto(body, fd, sid);
        } else if (ct == .JSON) {
            sayHelloJson(body, fd, sid);
        } else {
            grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "bad content-type") catch {};
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
        grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "truncated") catch {};
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

fn sayHelloJson(body: []const u8, fd: std.posix.fd_t, sid: u31) void {
    const prefix = grpc.readGrpcPrefix(body) catch {
        grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "bad prefix") catch {};
        return;
    };
    if (body.len < 5 + @as(usize, prefix.msg_len)) {
        grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "truncated") catch {};
        return;
    }
    const json_bytes = body[5..][0..prefix.msg_len];

    const Request = struct { name: []const u8 };
    const req = std.json.parseFromSlice(
        Request,
        std.heap.smp_allocator,
        json_bytes,
        .{ .ignore_unknown_fields = true },
    ) catch {
        grpc.sendGrpcError(fd, sid, grpc.GRPC_INVALID_ARGUMENT, "bad json") catch {};
        return;
    };
    defer req.deinit();

    var msg_buf: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&msg_buf, "Hello, {s}!", .{req.value.name}) catch "Hello!";
    var resp_json_buf: [512]u8 = undefined;
    const resp_json = std.fmt.bufPrint(&resp_json_buf, "{{\"message\":\"{s}\"}}", .{message}) catch "{}";

    grpc.sendGrpcHeaders(fd, sid, "application/grpc+json") catch return;
    grpc.sendGrpcData(fd, sid, resp_json) catch return;
    grpc.sendGrpcTrailer(fd, sid, grpc.GRPC_OK, "") catch {};
}

// ------------------------------------------------------------------ //
// Tests                                                               //
// ------------------------------------------------------------------ //

test "integ: SayHello proto roundtrip returns Hello world!" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT);

    const fd = try clientConnect(io, TEST_PORT);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);

    // Build proto message: field 1 = "world"
    var req_buf: [32]u8 = undefined;
    const req_len = grpc.encodeString(1, "world", &req_buf);

    try sendGrpcRequest(fd, 1, "/helloworld.Greeter/SayHello", "application/grpc+proto", req_buf[0..req_len]);

    var data_buf: [1024]u8 = undefined;
    const resp = try recvGrpcResponse(fd, 1, &data_buf);

    try std.testing.expectEqual(@as(u8, grpc.GRPC_OK), resp.grpc_status);

    // Response DATA: 5-byte prefix + proto field 1 = "Hello, world!"
    try std.testing.expect(resp.data.len >= 5);
    const p = try grpc.readGrpcPrefix(resp.data);
    try std.testing.expect(!p.compress);
    const msg_bytes = resp.data[5..][0..p.msg_len];
    var reader = grpc.MessageReader.init(msg_bytes);
    const field = (try reader.next()) orelse return error.NoField;
    try std.testing.expectEqual(@as(u32, 1), field.field_number);
    try std.testing.expectEqualStrings("Hello, world!", field.payload);

    try h2.sendGoaway(fd, 1, h2.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "integ: SayHello JSON roundtrip returns hello message json" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 1);

    const fd = try clientConnect(io, TEST_PORT + 1);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);

    const json_msg = "{\"name\":\"zix\"}";
    try sendGrpcRequest(fd, 1, "/helloworld.Greeter/SayHello", "application/grpc+json", json_msg);

    var data_buf: [1024]u8 = undefined;
    const resp = try recvGrpcResponse(fd, 1, &data_buf);

    try std.testing.expectEqual(@as(u8, grpc.GRPC_OK), resp.grpc_status);

    // DATA: 5-byte prefix + JSON response body
    try std.testing.expect(resp.data.len >= 5);
    const p = try grpc.readGrpcPrefix(resp.data);
    const json_bytes = resp.data[5..][0..p.msg_len];
    const Response = struct { message: []const u8 };
    const parsed = try std.json.parseFromSlice(Response, gpa, json_bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Hello, zix!", parsed.value.message);

    try h2.sendGoaway(fd, 1, h2.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "integ: unknown path returns UNIMPLEMENTED" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try spawnServer(&ctx, io, TEST_PORT + 2);

    const fd = try clientConnect(io, TEST_PORT + 2);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);
    try sendGrpcRequest(fd, 1, "/no.Such.Service/Method", "application/grpc+proto", "");

    var data_buf: [256]u8 = undefined;
    const resp = try recvGrpcResponse(fd, 1, &data_buf);

    try std.testing.expectEqual(@as(u8, grpc.GRPC_UNIMPLEMENTED), resp.grpc_status);

    try h2.sendGoaway(fd, 1, h2.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
