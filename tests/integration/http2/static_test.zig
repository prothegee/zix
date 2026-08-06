//! Integration tests: zix.Http2 serving public_dir over a real h2c connection.
//!
//! Covers the router's static fallback end to end: an unmatched path resolves through the static
//! cache and comes back as HEADERS plus DATA on the wire, routed paths keep precedence over it, and
//! a repeated request returns the same bytes. The cache is installed for these, so what is exercised
//! is the path a served deployment takes rather than the uncached fallback.

const std = @import("std");
const zix = @import("zix");

const static_cache = zix.utils.static_cache;

/// Base of this file's own port block. The eight tests below take TEST_PORT through TEST_PORT + 8
/// (one of them runs two servers), so the block has to stay clear of every other suite: these run
/// as parallel build steps, and a second binary listening on a shared port sends a client to the
/// wrong server, which reads as a stall rather than as a bind failure.
const TEST_PORT: u16 = 18110;

// --------------------------------------------------------- //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

/// public_dir for the running server. The fixture root is a temp directory known only at run time,
/// so the runner reads it from here rather than from a comptime route table.
var g_public_dir_buf: [64]u8 = undefined;
var g_public_dir: []const u8 = "";

fn homeHandler(_: *zix.Http2.Request, res: *zix.Http2.Response, _: *zix.Http2.Context) anyerror!void {
    try res.sendText("routed");
}

const Routes = zix.Http2.Router(&[_]zix.Http2.Route{
    .{ .path = "/", .handler = homeHandler },
});

fn runServer(ctx: *ServerCtx, io: std.Io) void {
    const stream = ctx.listener.accept(io) catch |err| {
        ctx.err = err;

        return;
    };
    const fd = stream.socket.handle;

    zix.Http2.serveConn(Routes.dispatch, fd, .{ .public_dir = g_public_dir }, io);

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

// --------------------------------------------------------- //

fn clientConnect(io: std.Io, port: u16) !std.posix.fd_t {
    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream });

    return stream.socket.handle;
}

fn sendPreface(fd: std.posix.fd_t) !void {
    try zix.Http2.writeAllFD(fd, zix.Http2.PREFACE);
    try zix.Http2.sendSettingsFD(fd, &.{});
}

fn sendGet(fd: std.posix.fd_t, sid: u31, path: []const u8, accept_encoding: ?[]const u8) !void {
    return sendGetRange(fd, sid, path, accept_encoding, null);
}

fn sendGetRange(fd: std.posix.fd_t, sid: u31, path: []const u8, accept_encoding: ?[]const u8, range: ?[]const u8) !void {
    var header_buf: [256]u8 = undefined;
    var hpack_encoder = zix.Http2.HpackEncoder.init(&header_buf);
    try hpack_encoder.writeHeader(":method", "GET");
    try hpack_encoder.writeHeader(":path", path);
    try hpack_encoder.writeHeader(":scheme", "http");
    try hpack_encoder.writeHeader(":authority", "localhost");
    if (accept_encoding) |value| try hpack_encoder.writeHeader("accept-encoding", value);
    if (range) |value| try hpack_encoder.writeHeader("range", value);
    const hblock = hpack_encoder.encoded();

    try zix.Http2.writeFrameHeaderFD(fd, .{
        .length = @intCast(hblock.len),
        .frame_type = zix.Http2.FRAME_TYPE_HEADERS,
        .flags = zix.Http2.FLAG_END_STREAM | zix.Http2.FLAG_END_HEADERS,
        .stream_id = sid,
    });
    try zix.Http2.writeAllFD(fd, hblock);
}

/// Read one stream to END_STREAM, returning its body and the decoded status.
const Reply = struct {
    status: u16,
    body: []const u8,
    content_encoding: []const u8,
    content_range: []const u8 = "",
};

fn recvReply(fd: std.posix.fd_t, sid: u31, buf: []u8, encoding_buf: []u8) !Reply {
    var body_len: usize = 0;
    var status: u16 = 0;
    var encoding_len: usize = 0;
    var range_buf: [64]u8 = undefined;
    var range_len: usize = 0;
    var payload_buf: [zix.Http2.MAX_PAYLOAD + 256]u8 = undefined;
    var hpack_decoder = zix.Http2.HpackDecoder.init();
    var hdrs: [32]zix.Http2.Header = undefined;
    var scratch: [2048]u8 = undefined;

    while (true) {
        const frame = try zix.Http2.readFrameHeader(fd);
        const payload = payload_buf[0..frame.length];
        if (frame.length > 0) try zix.Http2.recvExact(fd, payload);

        switch (frame.frame_type) {
            zix.Http2.FRAME_TYPE_SETTINGS => {
                if ((frame.flags & zix.Http2.FLAG_ACK) == 0) try zix.Http2.sendSettingsAckFD(fd);
            },
            zix.Http2.FRAME_TYPE_WINDOW_UPDATE => {},
            zix.Http2.FRAME_TYPE_HEADERS => {
                if (frame.stream_id != sid) continue;

                const count = try hpack_decoder.decode(payload, &hdrs, &scratch);
                for (hdrs[0..count]) |header| {
                    if (std.mem.eql(u8, header.name, ":status")) status = std.fmt.parseInt(u16, header.value, 10) catch 0;
                    if (std.mem.eql(u8, header.name, "content-encoding") and header.value.len <= encoding_buf.len) {
                        @memcpy(encoding_buf[0..header.value.len], header.value);
                        encoding_len = header.value.len;
                    }
                    if (std.mem.eql(u8, header.name, "content-range") and header.value.len <= range_buf.len) {
                        @memcpy(range_buf[0..header.value.len], header.value);
                        range_len = header.value.len;
                    }
                }

                if ((frame.flags & zix.Http2.FLAG_END_STREAM) != 0) {
                    return .{ .status = status, .body = buf[0..body_len], .content_encoding = encoding_buf[0..encoding_len], .content_range = replyRange(range_buf[0..range_len]) };
                }
            },
            zix.Http2.FRAME_TYPE_DATA => {
                if (frame.stream_id != sid) continue;

                const take = @min(payload.len, buf.len - body_len);
                @memcpy(buf[body_len..][0..take], payload[0..take]);
                body_len += take;

                if ((frame.flags & zix.Http2.FLAG_END_STREAM) != 0) {
                    return .{ .status = status, .body = buf[0..body_len], .content_encoding = encoding_buf[0..encoding_len], .content_range = replyRange(range_buf[0..range_len]) };
                }
            },
            zix.Http2.FRAME_TYPE_GOAWAY => return error.ServerGoaway,
            zix.Http2.FRAME_TYPE_RST_STREAM => return error.StreamReset,
            else => {},
        }
    }
}

/// Copy a Content-Range value out of the frame-local buffer into module storage, so the returned
/// Reply does not point at a stack slot that is about to go away.
var reply_range_buf: [64]u8 = undefined;

fn replyRange(value: []const u8) []const u8 {
    if (value.len == 0 or value.len > reply_range_buf.len) return "";

    @memcpy(reply_range_buf[0..value.len], value);

    return reply_range_buf[0..value.len];
}

fn writeFixture(dir: std.Io.Dir, name: []const u8, data: []const u8) void {
    dir.writeFile(std.testing.io, .{ .sub_path = name, .data = data }) catch @panic("fixture write failed");
}

fn setPublicDir(tmp: *std.testing.TmpDir) void {
    g_public_dir = std.fmt.bufPrint(&g_public_dir_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
}

// --------------------------------------------------------- //

test "zix integration: Http2 serves an unmatched path from public_dir over h2c" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "styles.css", "body{margin:0;padding:0}");
    setPublicDir(&tmp);

    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const thread = try spawnServer(&ctx, io, TEST_PORT);

    const fd = try clientConnect(io, TEST_PORT);
    defer zix.utils.fd_io.close(fd);

    try sendPreface(fd);
    try sendGet(fd, 1, "/styles.css", null);

    var body_buf: [1024]u8 = undefined;
    var encoding_buf: [32]u8 = undefined;
    const reply = try recvReply(fd, 1, &body_buf, &encoding_buf);

    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings("body{margin:0;padding:0}", reply.body);

    try zix.Http2.sendGoawayFD(fd, 1, zix.Http2.ERR_NO_ERROR);
    thread.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: Http2 negotiates the brotli sibling from public_dir over h2c" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "bundle.js", "the whole plain bundle");
    writeFixture(tmp.dir, "bundle.js.br", "compact");
    setPublicDir(&tmp);

    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const thread = try spawnServer(&ctx, io, TEST_PORT + 1);

    const fd = try clientConnect(io, TEST_PORT + 1);
    defer zix.utils.fd_io.close(fd);

    try sendPreface(fd);
    try sendGet(fd, 1, "/bundle.js", "br, gzip");

    var body_buf: [1024]u8 = undefined;
    var encoding_buf: [32]u8 = undefined;
    const reply = try recvReply(fd, 1, &body_buf, &encoding_buf);

    try std.testing.expectEqual(@as(u16, 200), reply.status);
    try std.testing.expectEqualStrings("compact", reply.body);
    try std.testing.expectEqualStrings("br", reply.content_encoding);

    try zix.Http2.sendGoawayFD(fd, 1, zix.Http2.ERR_NO_ERROR);
    thread.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: Http2 repeats a public_dir file byte for byte across streams" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Longer than one DATA frame at the cap used below, so a repeat has to walk the body again.
    var payload: [5000]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast('A' + index % 26);

    writeFixture(tmp.dir, "vendor.js", &payload);
    setPublicDir(&tmp);

    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const thread = try spawnServer(&ctx, io, TEST_PORT + 2);

    const fd = try clientConnect(io, TEST_PORT + 2);
    defer zix.utils.fd_io.close(fd);

    try sendPreface(fd);

    // Three streams on one connection: the second and third are served from what the first resolved.
    var sid: u31 = 1;
    while (sid <= 5) : (sid += 2) {
        try sendGet(fd, sid, "/vendor.js", null);

        var body_buf: [8192]u8 = undefined;
        var encoding_buf: [32]u8 = undefined;
        const reply = try recvReply(fd, sid, &body_buf, &encoding_buf);

        try std.testing.expectEqual(@as(u16, 200), reply.status);
        try std.testing.expectEqualStrings(&payload, reply.body);
    }

    try zix.Http2.sendGoawayFD(fd, 5, zix.Http2.ERR_NO_ERROR);
    thread.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: Http2 keeps a routed path ahead of public_dir" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A file that would shadow the routed path if the fallback ran first.
    writeFixture(tmp.dir, "index.html", "<h1>from disk</h1>");
    setPublicDir(&tmp);

    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const thread = try spawnServer(&ctx, io, TEST_PORT + 3);

    const fd = try clientConnect(io, TEST_PORT + 3);
    defer zix.utils.fd_io.close(fd);

    try sendPreface(fd);
    try sendGet(fd, 1, "/", null);

    var body_buf: [1024]u8 = undefined;
    var encoding_buf: [32]u8 = undefined;
    const reply = try recvReply(fd, 1, &body_buf, &encoding_buf);

    try std.testing.expectEqualStrings("routed", reply.body);

    try zix.Http2.sendGoawayFD(fd, 1, zix.Http2.ERR_NO_ERROR);
    thread.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: Http2 serves the same bytes with the cache off as with it on" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var payload: [3000]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);

    writeFixture(tmp.dir, "shared.js", &payload);
    writeFixture(tmp.dir, "shared.js.br", "tiny");
    setPublicDir(&tmp);

    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    // No cache installed: the request takes the uncached open-and-read path, which does no
    // negotiation, so the client gets identity even though it asked for brotli.
    try std.testing.expect(static_cache.instance() == null);

    var uncached_ctx: ServerCtx = undefined;
    const uncached_thread = try spawnServer(&uncached_ctx, io, TEST_PORT + 5);
    const uncached_fd = try clientConnect(io, TEST_PORT + 5);

    try sendPreface(uncached_fd);
    try sendGet(uncached_fd, 1, "/shared.js", "br");

    var uncached_body: [8192]u8 = undefined;
    var uncached_encoding: [32]u8 = undefined;
    const uncached = try recvReply(uncached_fd, 1, &uncached_body, &uncached_encoding);

    try std.testing.expectEqual(@as(u16, 200), uncached.status);
    try std.testing.expectEqualStrings(&payload, uncached.body);

    try zix.Http2.sendGoawayFD(uncached_fd, 1, zix.Http2.ERR_NO_ERROR);
    uncached_thread.join();
    uncached_ctx.listener.deinit(io);
    zix.utils.fd_io.close(uncached_fd);
    try std.testing.expect(uncached_ctx.err == null);

    // Same file, cache installed: the identity body has to be byte for byte what the uncached path
    // produced, so enabling the cache cannot change what a client without brotli receives.
    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    var cached_ctx: ServerCtx = undefined;
    const cached_thread = try spawnServer(&cached_ctx, io, TEST_PORT + 6);
    const cached_fd = try clientConnect(io, TEST_PORT + 6);
    defer zix.utils.fd_io.close(cached_fd);

    try sendPreface(cached_fd);
    try sendGet(cached_fd, 1, "/shared.js", null);

    var cached_body: [8192]u8 = undefined;
    var cached_encoding: [32]u8 = undefined;
    const cached = try recvReply(cached_fd, 1, &cached_body, &cached_encoding);

    try std.testing.expectEqual(uncached.status, cached.status);
    try std.testing.expectEqualStrings(uncached.body, cached.body);

    try zix.Http2.sendGoawayFD(cached_fd, 1, zix.Http2.ERR_NO_ERROR);
    cached_thread.join();
    cached_ctx.listener.deinit(io);
    try std.testing.expect(cached_ctx.err == null);
}

test "zix integration: Http2 404s an unmatched path with no file behind it" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    setPublicDir(&tmp);

    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const thread = try spawnServer(&ctx, io, TEST_PORT + 4);

    const fd = try clientConnect(io, TEST_PORT + 4);
    defer zix.utils.fd_io.close(fd);

    try sendPreface(fd);
    try sendGet(fd, 1, "/absent.css", null);

    var body_buf: [1024]u8 = undefined;
    var encoding_buf: [32]u8 = undefined;
    const reply = try recvReply(fd, 1, &body_buf, &encoding_buf);

    try std.testing.expectEqual(@as(u16, 404), reply.status);

    try zix.Http2.sendGoawayFD(fd, 1, zix.Http2.ERR_NO_ERROR);
    thread.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: Http2 answers a Range with 206 over h2c" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Long enough that the range spans several DATA frames at the default 16 KiB cap.
    var payload: [40000]u8 = undefined;
    for (&payload, 0..) |*byte, index| byte.* = @intCast('a' + index % 26);

    writeFixture(tmp.dir, "media.bin", &payload);
    setPublicDir(&tmp);

    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const thread = try spawnServer(&ctx, io, TEST_PORT + 7);

    const fd = try clientConnect(io, TEST_PORT + 7);
    defer zix.utils.fd_io.close(fd);

    try sendPreface(fd);
    try sendGetRange(fd, 1, "/media.bin", null, "bytes=1000-20999");

    var body_buf: [65536]u8 = undefined;
    var encoding_buf: [32]u8 = undefined;
    const reply = try recvReply(fd, 1, &body_buf, &encoding_buf);

    try std.testing.expectEqual(@as(u16, 206), reply.status);
    try std.testing.expectEqualStrings("bytes 1000-20999/40000", reply.content_range);
    try std.testing.expectEqualSlices(u8, payload[1000..21000], reply.body);

    try zix.Http2.sendGoawayFD(fd, 1, zix.Http2.ERR_NO_ERROR);
    thread.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "zix integration: Http2 answers 416 for an unsatisfiable Range over h2c" {
    if (comptime @import("builtin").target.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    writeFixture(tmp.dir, "small.txt", "0123456789");
    setPublicDir(&tmp);

    _ = try static_cache.install(32, 60_000);
    defer static_cache.shutdown(std.testing.io);

    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const thread = try spawnServer(&ctx, io, TEST_PORT + 8);

    const fd = try clientConnect(io, TEST_PORT + 8);
    defer zix.utils.fd_io.close(fd);

    try sendPreface(fd);
    try sendGetRange(fd, 1, "/small.txt", null, "bytes=500-600");

    var body_buf: [1024]u8 = undefined;
    var encoding_buf: [32]u8 = undefined;
    const reply = try recvReply(fd, 1, &body_buf, &encoding_buf);

    try std.testing.expectEqual(@as(u16, 416), reply.status);
    try std.testing.expectEqualStrings("bytes */10", reply.content_range);
    try std.testing.expectEqual(@as(usize, 0), reply.body.len);

    try zix.Http2.sendGoawayFD(fd, 1, zix.Http2.ERR_NO_ERROR);
    thread.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
