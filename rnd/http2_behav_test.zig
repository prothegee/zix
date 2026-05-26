//! Behaviour tests: HTTP/2 observable response contracts.
//! Verifies: :status header, content-type, 404, PING ACK, GOAWAY.
//! Run: zig test rnd/http2_behav_test.zig

const std = @import("std");
const core = @import("http2_poc_core.zig");

const TEST_PORT: u16 = 18210;

// ------------------------------------------------------------------ //
// Shared                                                              //
// ------------------------------------------------------------------ //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

fn routingHandler(
    method: []const u8,
    path: []const u8,
    headers: []const core.Header,
    body: []const u8,
    fd: std.posix.fd_t,
    sid: u31,
) void {
    _ = method;
    _ = headers;
    _ = body;
    if (std.mem.eql(u8, path, "/")) {
        core.sendResponse(fd, sid, 200, "text/plain", "Hello, World!") catch {};
    } else {
        core.sendResponse(fd, sid, 404, "text/plain", "Not Found\n") catch {};
    }
}

fn runServer(ctx: *ServerCtx, io: std.Io) void {
    const stream = ctx.listener.accept(io) catch |e| {
        ctx.err = e;
        return;
    };
    core.serveConn(stream, io, routingHandler);
}

fn setup(io: std.Io, ctx: *ServerCtx, port: u16) !std.Thread {
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
    try core.fdWriteAll(fd, core.PREFACE);
    try core.sendSettings(fd, &.{});
}

fn sendGetRequest(fd: std.posix.fd_t, sid: u31, path: []const u8) !void {
    var hbuf: [256]u8 = undefined;
    var enc = core.HpackEncoder.init(&hbuf);
    try enc.writeHeader(":method", "GET");
    try enc.writeHeader(":path", path);
    try enc.writeHeader(":scheme", "http");
    try enc.writeHeader(":authority", "localhost");
    const hblock = enc.encoded();
    try core.writeFrameHeader(fd, .{
        .length = @intCast(hblock.len),
        .frame_type = core.FT_HEADERS,
        .flags = core.FLAG_END_STREAM | core.FLAG_END_HEADERS,
        .stream_id = sid,
    });
    try core.fdWriteAll(fd, hblock);
}

// Collect all frames for a stream into status + headers + body.
const ResponseInfo = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
    body_buf: [1024]u8,
    hdr_scratch: [2048]u8,
    status_buf: [8]u8,
    ct_buf: [64]u8,
};

fn recvResponseInfo(fd: std.posix.fd_t, sid: u31, info: *ResponseInfo) !void {
    var payload_buf: [core.MAX_PAYLOAD + 256]u8 = undefined;
    var hpack = core.HpackDecoder.init();
    var hdrs: [32]core.Header = undefined;
    info.body_buf = undefined;
    var body_len: usize = 0;
    info.status = "";
    info.content_type = "";

    while (true) {
        const fh = try core.readFrameHeader(fd);
        const payload = payload_buf[0..fh.length];
        if (fh.length > 0) try core.recvExact(fd, payload);

        switch (fh.frame_type) {
            core.FT_SETTINGS => {
                if ((fh.flags & core.FLAG_ACK) == 0) try core.sendSettingsAck(fd);
            },
            core.FT_WINDOW_UPDATE => {},
            core.FT_PING => {
                if ((fh.flags & core.FLAG_ACK) == 0) {
                    var p8: [8]u8 = undefined;
                    @memcpy(&p8, payload[0..8]);
                    try core.sendPingAck(fd, p8);
                }
            },
            core.FT_HEADERS => {
                if (fh.stream_id != sid) continue;
                const n = try hpack.decode(payload, &hdrs, &info.hdr_scratch);
                for (hdrs[0..n]) |h| {
                    if (std.mem.eql(u8, h.name, ":status")) {
                        const l = @min(h.value.len, info.status_buf.len);
                        @memcpy(info.status_buf[0..l], h.value[0..l]);
                        info.status = info.status_buf[0..l];
                    } else if (std.mem.eql(u8, h.name, "content-type")) {
                        const l = @min(h.value.len, info.ct_buf.len);
                        @memcpy(info.ct_buf[0..l], h.value[0..l]);
                        info.content_type = info.ct_buf[0..l];
                    }
                }
                if ((fh.flags & core.FLAG_END_STREAM) != 0) {
                    info.body = info.body_buf[0..body_len];
                    return;
                }
            },
            core.FT_DATA => {
                if (fh.stream_id != sid) continue;
                const to_copy = @min(payload.len, info.body_buf.len - body_len);
                @memcpy(info.body_buf[body_len..][0..to_copy], payload[0..to_copy]);
                body_len += to_copy;
                if ((fh.flags & core.FLAG_END_STREAM) != 0) {
                    info.body = info.body_buf[0..body_len];
                    return;
                }
            },
            core.FT_GOAWAY => return error.ServerGoaway,
            core.FT_RST_STREAM => return error.StreamReset,
            else => {},
        }
    }
}

// ------------------------------------------------------------------ //
// Tests                                                               //
// ------------------------------------------------------------------ //

test "behav: response includes :status header with value 200" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT);

    const fd = try clientConnect(io, TEST_PORT);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);
    try sendGetRequest(fd, 1, "/");

    var info: ResponseInfo = undefined;
    try recvResponseInfo(fd, 1, &info);

    try std.testing.expectEqualStrings("200", info.status);
    try std.testing.expectEqualStrings("text/plain", info.content_type);

    try core.sendGoaway(fd, 1, core.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "behav: unknown path returns :status 404" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT + 1);

    const fd = try clientConnect(io, TEST_PORT + 1);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);
    try sendGetRequest(fd, 1, "/no-such-path");

    var info: ResponseInfo = undefined;
    try recvResponseInfo(fd, 1, &info);

    try std.testing.expectEqualStrings("404", info.status);

    try core.sendGoaway(fd, 1, core.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "behav: PING frame elicits ACK with same payload" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT + 2);

    const fd = try clientConnect(io, TEST_PORT + 2);
    defer _ = std.posix.system.close(fd);

    try sendPreface(fd);

    // Wait for server SETTINGS before sending PING.
    var payload_buf: [256]u8 = undefined;
    got_settings: while (true) {
        const fh = try core.readFrameHeader(fd);
        const pl = payload_buf[0..fh.length];
        if (fh.length > 0) try core.recvExact(fd, pl);
        if (fh.frame_type == core.FT_SETTINGS and (fh.flags & core.FLAG_ACK) == 0) {
            try core.sendSettingsAck(fd);
            break :got_settings;
        }
    }

    // Send PING with a known payload.
    const ping_payload = [8]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    try core.writeFrameHeader(fd, .{
        .length = 8,
        .frame_type = core.FT_PING,
        .flags = 0,
        .stream_id = 0,
    });
    try core.fdWriteAll(fd, &ping_payload);

    // Read until we get a PING ACK.
    got_ack: while (true) {
        const fh = try core.readFrameHeader(fd);
        const pl = payload_buf[0..fh.length];
        if (fh.length > 0) try core.recvExact(fd, pl);
        if (fh.frame_type == core.FT_PING and (fh.flags & core.FLAG_ACK) != 0) {
            try std.testing.expectEqualSlices(u8, &ping_payload, pl);
            break :got_ack;
        }
    }

    try core.sendGoaway(fd, 0, core.ERR_NO_ERROR);
    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
