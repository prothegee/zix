//! Edge tests: boundary conditions and error paths for HTTP/1 parsing and connection.
//! Run: zig test rnd/http1_edge_test.zig

const std = @import("std");
const core = @import("http1_poc_core.zig");

const TEST_PORT: u16 = 18100;

// ------------------------------------------------------------------ //
// Shared                                                              //
// ------------------------------------------------------------------ //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

fn nopHandler(head: *const core.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = head;
    _ = body;
    core.writeSimple(fd, 200, "text/plain", "ok") catch {};
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

fn recvStatus(rd: *std.Io.Reader, buf: []u8) ![]const u8 {
    var filled: usize = 0;
    while (filled < buf.len) {
        buf[filled] = try rd.takeByte();
        filled += 1;
        if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n") != null) break;
    }
    const crlf = std.mem.indexOf(u8, buf[0..filled], "\r\n") orelse filled;
    return buf[0..crlf];
}

// ------------------------------------------------------------------ //
// Pure-computation edge cases (no I/O)                               //
// ------------------------------------------------------------------ //

test "edge: parseRange with total=0 returns null" {
    try std.testing.expect(core.parseRange("bytes=0-0", 0) == null);
}

test "edge: parseRange start equals end is valid single-byte range" {
    const r = core.parseRange("bytes=5-5", 10).?;
    try std.testing.expectEqual(5, r.start);
    try std.testing.expectEqual(5, r.end);
}

test "edge: parseHead handles request with no headers beyond request line" {
    // HTTP/1.0 with no headers at all.
    const raw = "GET / HTTP/1.0\r\n\r\n";
    const r = try core.parseHead(raw);
    try std.testing.expectEqualStrings("GET", r.head.method);
    try std.testing.expectEqual(0, r.head.header_count);
}

test "edge: parseHead body_offset points past header block" {
    const raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\nbody";
    const r = try core.parseHead(raw);
    // body_offset must land on 'b' of "body".
    try std.testing.expectEqualStrings("body", raw[r.body_offset..]);
}

// ------------------------------------------------------------------ //
// Connection edge cases (with I/O)                                   //
// ------------------------------------------------------------------ //

test "edge: header block exceeding BUF_SIZE causes 431 response" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT);

    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rd_buf: [4096]u8 = undefined;
    var wr_buf: [core.BUF_SIZE + 256]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    // Build a request with a header value longer than BUF_SIZE (no \r\n\r\n until the end).
    try wr.interface.writeAll("GET / HTTP/1.1\r\nX-Pad: ");
    var i: usize = 0;
    while (i < core.BUF_SIZE) : (i += 1) {
        try wr.interface.writeByte('A');
    }
    try wr.interface.writeAll("\r\n\r\n");
    try wr.interface.flush();

    var resp: [256]u8 = undefined;
    const status = recvStatus(&rd.interface, &resp) catch resp[0..0];
    try std.testing.expect(std.mem.startsWith(u8, status, "HTTP/1.1 431"));

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "edge: malformed request line causes 400 response" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT + 1);

    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT + 1);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rd_buf: [4096]u8 = undefined;
    var wr_buf: [512]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    try wr.interface.writeAll("NOTHTTP\r\n\r\n");
    try wr.interface.flush();

    var resp: [256]u8 = undefined;
    const status = recvStatus(&rd.interface, &resp) catch resp[0..0];
    try std.testing.expect(std.mem.startsWith(u8, status, "HTTP/1.1 400"));

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "edge: request header split across two TCP segments is reassembled" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT + 2);

    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT + 2);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer stream.close(io);

    var rd_buf: [4096]u8 = undefined;
    var wr_buf: [512]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    const full = "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    const half = full.len / 2;

    try wr.interface.writeAll(full[0..half]);
    try wr.interface.flush();
    var ts = std.os.linux.timespec{ .sec = 0, .nsec = 5 * std.time.ns_per_ms };
    _ = std.os.linux.nanosleep(&ts, null);
    try wr.interface.writeAll(full[half..]);
    try wr.interface.flush();

    var resp: [256]u8 = undefined;
    const status = recvStatus(&rd.interface, &resp) catch resp[0..0];
    try std.testing.expect(std.mem.startsWith(u8, status, "HTTP/1.1 200 OK"));

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "edge: peer closes without sending a request causes silent server exit" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .stack_size = 512 * 1024 });
    defer threaded.deinit();
    const io = threaded.io();

    var ctx: ServerCtx = undefined;
    const t = try setup(io, &ctx, TEST_PORT + 3);

    const addr = try std.Io.net.IpAddress.resolve(io, "127.0.0.1", TEST_PORT + 3);
    const stream = try addr.connect(io, .{ .mode = .stream });
    // Close immediately — server recvHead returns error.Closed, serveConn returns silently.
    stream.close(io);

    t.join();
    ctx.listener.deinit(io);
    // Server must not record a crash or unexpected error.
    try std.testing.expect(ctx.err == null);
}
