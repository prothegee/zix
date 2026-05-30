//! Edge tests: HTTP/2 boundary conditions and error paths.
//! Run: zig test rnd/http2_edge_test.zig

const std = @import("std");
const core = @import("http2_poc_core.zig");

const TEST_PORT: u16 = 18220;

// ------------------------------------------------------------------ //
// Shared                                                              //
// ------------------------------------------------------------------ //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

fn nopHandler(
    method: []const u8,
    path: []const u8,
    headers: []const core.Header,
    body: []const u8,
    fd: std.posix.fd_t,
    sid: u31,
) void {
    _ = method;
    _ = path;
    _ = headers;
    _ = body;
    core.sendResponse(fd, sid, 200, "text/plain", "ok") catch {};
}

fn runServer(ctx: *ServerCtx, io: std.Io) void {
    const stream = ctx.listener.accept(io) catch |e| {
        ctx.err = e;
        return;
    };
    core.serveConn(stream, io, nopHandler);
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

// ------------------------------------------------------------------ //
// Pure-computation edge cases (no I/O)                               //
// ------------------------------------------------------------------ //

test "edge: huffman decode empty input produces empty output" {
    var out: [16]u8 = undefined;
    const n = try core.huffDecode("", &out);
    try std.testing.expectEqual(0, n);
}

test "edge: huffman encode empty string produces no bytes" {
    var out: [16]u8 = undefined;
    const n = try core.huffEncode("", &out);
    try std.testing.expectEqual(0, n);
}

test "edge: hpack decode empty block produces zero headers" {
    var dec = core.HpackDecoder.init();
    var hdrs: [8]core.Header = undefined;
    var scratch: [256]u8 = undefined;
    const n = try dec.decode("", &hdrs, &scratch);
    try std.testing.expectEqual(0, n);
}

test "edge: frame header with maximum 24-bit length field parses correctly" {
    // length = 0xFFFFFF (16_777_215), type = DATA, flags = 0, stream_id = 0x7FFFFFFF
    const raw = [9]u8{ 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x7F, 0xFF, 0xFF, 0xFF };
    const fds = try std.Io.Threaded.pipe2(.{});
    defer _ = std.posix.system.close(fds[0]);
    defer _ = std.posix.system.close(fds[1]);
    _ = std.posix.system.write(fds[1], &raw, raw.len);
    const fh = try core.readFrameHeader(fds[0]);
    try std.testing.expectEqual(0xFFFFFF, fh.length);
    try std.testing.expectEqual(0x7FFFFFFF, fh.stream_id);
}

// ------------------------------------------------------------------ //
// Connection edge cases (with I/O)                                   //
// ------------------------------------------------------------------ //

test "edge: wrong connection preface causes server to close" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT);

    const fd = try clientConnect(io, TEST_PORT);
    defer _ = std.posix.system.close(fd);

    // Send an HTTP/1.1 request without Upgrade: h2c — not a valid h2c connection.
    try core.fdWriteAll(fd, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");

    // Server must reject: GOAWAY (h2c direct path), HTTP/1.1 4xx (upgrade path), or EOF.
    var buf: [64]u8 = undefined;
    const n = std.posix.read(fd, &buf) catch 0;
    try std.testing.expect(
        n == 0 or
            buf[3] == core.FT_GOAWAY or
            std.mem.startsWith(u8, buf[0..n], "HTTP/1.1 4"),
    );

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "edge: client sending GOAWAY causes server to exit cleanly" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT + 1);

    const fd = try clientConnect(io, TEST_PORT + 1);
    defer _ = std.posix.system.close(fd);

    try core.fdWriteAll(fd, core.PREFACE);
    try core.sendSettings(fd, &.{});
    try core.sendGoaway(fd, 0, core.ERR_NO_ERROR);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "edge: peer closes without handshake causes silent server exit" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT + 2);

    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT + 2);
    const stream = try addr.connect(io, .{ .mode = .stream });
    stream.close(io); // immediate close — server recvExact returns error.Closed

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
