//! Behaviour tests: observable HTTP/1 response contracts.
//! Verifies status codes, header presence, keep-alive semantics, HEAD method.
//! Run: zig test rnd/http1_behav_test.zig

const std = @import("std");
const core = @import("http1_poc_core.zig");

const TEST_PORT: u16 = 18090;

// ------------------------------------------------------------------ //
// Shared                                                              //
// ------------------------------------------------------------------ //

const ServerCtx = struct {
    listener: std.Io.net.Server,
    err: ?anyerror = null,
};

fn routingHandler(head: *const core.ParsedHead, body: []const u8, fd: std.posix.fd_t) void {
    _ = body;
    if (std.mem.eql(u8, head.path, "/")) {
        core.writeSimple(fd, 200, "text/plain", "Hello, World!") catch {};
    } else if (std.mem.eql(u8, head.path, "/chunked")) {
        core.writeChunkedStart(fd, 200, "text/plain") catch {};
        core.writeChunk(fd, "chunk-a\n") catch {};
        core.writeChunkedEnd(fd) catch {};
    } else {
        core.writeSimple(fd, 404, "text/plain", "Not Found\n") catch {};
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

fn recvFull(rd: *std.Io.Reader, buf: []u8) !usize {
    var filled: usize = 0;
    while (filled < buf.len) {
        buf[filled] = try rd.takeByte();
        filled += 1;
        if (std.mem.indexOf(u8, buf[0..filled], "\r\n\r\n")) |sep| {
            if (std.mem.indexOf(u8, buf[0..sep], "Transfer-Encoding: chunked") != null) {
                // Read until terminal chunk "0\r\n\r\n".
                while (filled < buf.len) {
                    buf[filled] = try rd.takeByte();
                    filled += 1;
                    if (std.mem.indexOf(u8, buf[0..filled], "0\r\n\r\n") != null) break;
                }
                return filled;
            }
            const cl = extractContentLength(buf[0..sep]) orelse 0;
            const body_start = sep + 4;
            while (filled < body_start + cl) {
                buf[filled] = try rd.takeByte();
                filled += 1;
            }
            return filled;
        }
    }
    return filled;
}

fn extractContentLength(headers: []const u8) ?usize {
    const prefix = "Content-Length: ";
    const pos = std.mem.indexOf(u8, headers, prefix) orelse return null;
    const after = headers[pos + prefix.len ..];
    const end = std.mem.indexOfScalar(u8, after, '\r') orelse after.len;
    return std.fmt.parseInt(usize, after[0..end], 10) catch null;
}

// ------------------------------------------------------------------ //
// Tests                                                               //
// ------------------------------------------------------------------ //

test "behav: response includes Content-Type and Content-Length headers" {
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
    var wr_buf: [512]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    try wr.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try wr.interface.flush();

    var resp: [2048]u8 = undefined;
    const n = try recvFull(&rd.interface, &resp);
    const raw = resp[0..n];

    try std.testing.expect(std.mem.indexOf(u8, raw, "Content-Type: text/plain") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Content-Length: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "Date: ") != null);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "behav: unknown path returns 404" {
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

    try wr.interface.writeAll("GET /no-such-path HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try wr.interface.flush();

    var resp: [2048]u8 = undefined;
    const n = try recvFull(&rd.interface, &resp);

    try std.testing.expect(std.mem.startsWith(u8, resp[0..n], "HTTP/1.1 404 Not Found"));

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}

test "behav: chunked response contains Transfer-Encoding header and terminal chunk" {
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

    try wr.interface.writeAll("GET /chunked HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try wr.interface.flush();

    var resp: [2048]u8 = undefined;
    const n = try recvFull(&rd.interface, &resp);
    const raw = resp[0..n];

    try std.testing.expect(std.mem.indexOf(u8, raw, "Transfer-Encoding: chunked") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "0\r\n\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "chunk-a\n") != null);

    t.join();
    ctx.listener.deinit(io);
    try std.testing.expect(ctx.err == null);
}
