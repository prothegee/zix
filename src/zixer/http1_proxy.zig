//! zixer http1 proxy edge: one client connection, re-originate to the pool

const std = @import("std");

const http1_head = @import("http1_head.zig");
const proxy_headers = @import("proxy_headers.zig");
const upstream_conn = @import("upstream_conn.zig");
const upstream_pool = @import("upstream_pool.zig");

/// Stream buffer size for each leg of the relay.
const STREAM_BUF_SIZE: usize = 8 * 1024;

/// Copy chunk size for the body pumps.
const PUMP_CHUNK: usize = 16 * 1024;

/// Interim (1xx) responses relayed per exchange before giving up.
const MAX_INTERIM = 4;

/// What one site's edge connections share.
pub const Proxy = struct {
    io: std.Io,
    pool: *upstream_pool.Pool,
    idle: *upstream_conn.IdleCache,
};

/// After one exchange: keep the edge connection or close it.
const EdgeResult = enum {
    KEEP,
    CLOSE,
};

/// Serve one accepted client connection until it closes.
///
/// Note:
/// - Every request is re-originated: zixer parses the client framing and
///   builds its own upstream message, raw client bytes never splice through
///   (rfc 9112 smuggling defense).
pub fn serveConn(proxy: *const Proxy, client_stream: std.Io.net.Stream) void {
    const io = proxy.io;
    defer client_stream.close(io);

    var read_buf: [STREAM_BUF_SIZE]u8 = undefined;
    var write_buf: [STREAM_BUF_SIZE]u8 = undefined;
    var client_reader = client_stream.reader(io, &read_buf);
    var client_writer = client_stream.writer(io, &write_buf);
    const client_addr = client_stream.socket.address;

    while (true) {
        var head_buf: [http1_head.MAX_HEAD_BYTES]u8 = undefined;
        const head_bytes = http1_head.readHead(&client_reader.interface, &head_buf) catch |err| {
            if (err == error.HeadTooLarge) writeEdgeError(&client_writer.interface, 431, "head too large", "http_request_error");
            return;
        };

        const request = http1_head.parseRequest(head_bytes) catch {
            writeEdgeError(&client_writer.interface, 400, "bad request", "http_request_error");
            return;
        };

        var build_buf: [http1_head.MAX_HEAD_BYTES + 512]u8 = undefined;
        const upstream_head = buildUpstreamHead(&build_buf, &request, client_addr) catch {
            writeEdgeError(&client_writer.interface, 400, "bad request", "http_request_error");
            return;
        };

        // The client may be waiting on Expect: 100-continue before it sends
        // the body. zixer answers the interim itself, the Expect header was
        // dropped from the rebuilt head.
        if (expectsContinue(&request)) {
            client_writer.interface.writeAll("HTTP/1.1 100 Continue\r\n\r\n") catch return;
            client_writer.interface.flush() catch return;
        }

        const outcome = exchange(proxy, &client_reader.interface, &client_writer.interface, &request, upstream_head);

        client_writer.interface.flush() catch return;
        if (outcome == .CLOSE) return;
    }
}

/// One request against the pool: pick, forward, relay, bounded retry.
fn exchange(
    proxy: *const Proxy,
    client_r: *std.Io.Reader,
    client_w: *std.Io.Writer,
    request: *const http1_head.RequestHead,
    upstream_head: []const u8,
) EdgeResult {
    const io = proxy.io;
    const no_body = request.framing == .none;

    // Bounded retry: one try per configured upstream, plus one spare so a
    // single stale idle conn never eats a slot's only chance.
    var attempts: usize = proxy.pool.slots.len + 1;
    var failed_here: bool = false;
    while (attempts > 0) : (attempts -= 1) {
        const picked = proxy.pool.pick(nowMs(io)) orelse {
            // Nothing left to pick. When this exchange itself emptied the
            // pool the honest answer is the failure it saw, not 503.
            if (failed_here) break;

            writeEdgeError(client_w, 503, "no upstream available", "destination_unavailable");
            return .CLOSE;
        };

        const conn = proxy.idle.acquire(picked.index) orelse
            upstream_conn.connect(io, picked.host, picked.port, picked.index) catch {
            proxy.pool.markDown(picked.index, nowMs(io));
            failed_here = true;
            continue;
        };

        var up_read_buf: [STREAM_BUF_SIZE]u8 = undefined;
        var up_write_buf: [STREAM_BUF_SIZE]u8 = undefined;
        var up_reader = conn.stream.reader(io, &up_read_buf);
        var up_writer = conn.stream.writer(io, &up_write_buf);

        up_writer.interface.writeAll(upstream_head) catch {
            conn.stream.close(io);
            if (!conn.reused) proxy.pool.markDown(picked.index, nowMs(io));
            failed_here = true;
            continue;
        };

        // The body is not replayable: any failure past this point cannot
        // retry another upstream for a request that carries one.
        switch (request.framing) {
            .none => {},
            .content_length => |len| pumpExact(client_r, &up_writer.interface, len) catch {
                conn.stream.close(io);
                writeEdgeError(client_w, 502, "upstream send failed", "connection_terminated");
                return .CLOSE;
            },
            .chunked => pumpChunked(client_r, &up_writer.interface) catch {
                conn.stream.close(io);
                writeEdgeError(client_w, 502, "upstream send failed", "connection_terminated");
                return .CLOSE;
            },
            .until_close => unreachable,
        }
        up_writer.interface.flush() catch {
            conn.stream.close(io);
            if (no_body) {
                if (!conn.reused) proxy.pool.markDown(picked.index, nowMs(io));
                failed_here = true;
                continue;
            }
            writeEdgeError(client_w, 502, "upstream send failed", "connection_terminated");
            return .CLOSE;
        };

        var resp_head_buf: [http1_head.MAX_HEAD_BYTES]u8 = undefined;
        const response = readResponseHead(&up_reader.interface, &resp_head_buf, request.method, client_w) orelse {
            conn.stream.close(io);
            if (no_body) {
                // A stale idle conn answers EOF here. Bodyless requests are
                // safe to replay, with a body the client already spent it.
                if (!conn.reused) proxy.pool.markDown(picked.index, nowMs(io));
                failed_here = true;
                continue;
            }
            writeEdgeError(client_w, 502, "upstream closed early", "connection_terminated");
            return .CLOSE;
        };

        const edge_close = request.connection_close or response.framing == .until_close;
        writeResponseHead(client_w, &response, edge_close) catch {
            conn.stream.close(io);
            return .CLOSE;
        };

        var relay_failed = false;
        switch (response.framing) {
            .none => {},
            .content_length => |len| pumpExact(&up_reader.interface, client_w, len) catch {
                relay_failed = true;
            },
            .chunked => pumpChunked(&up_reader.interface, client_w) catch {
                relay_failed = true;
            },
            .until_close => pumpUntilClose(&up_reader.interface, client_w),
        }

        const reusable = !relay_failed and !response.connection_close and response.framing != .until_close;
        if (reusable) proxy.idle.release(io, conn) else conn.stream.close(io);

        if (relay_failed or edge_close) return .CLOSE;

        return .KEEP;
    }

    writeEdgeError(client_w, 502, "all upstreams failed", "connection_refused");

    return .CLOSE;
}

/// Read the upstream response head, relaying interim 1xx responses to the
/// client on the way. Null when the upstream connection failed first.
fn readResponseHead(up_r: *std.Io.Reader, head_buf: []u8, method: []const u8, client_w: *std.Io.Writer) ?http1_head.ResponseHead {
    var interim: usize = 0;
    while (interim <= MAX_INTERIM) : (interim += 1) {
        const bytes = http1_head.readHead(up_r, head_buf) catch return null;
        const response = http1_head.parseResponse(bytes, method) catch return null;

        if (response.status / 100 != 1) return response;

        client_w.writeAll(bytes) catch return null;
        client_w.flush() catch return null;
    }

    return null;
}

/// Rebuild the client head for the upstream leg: filtered headers plus Via,
/// Forwarded, and zixer's own framing header.
fn buildUpstreamHead(buf: []u8, request: *const http1_head.RequestHead, client_addr: std.Io.net.IpAddress) ![]const u8 {
    var fixed = std.Io.Writer.fixed(buf);

    try fixed.print("{s} {s} HTTP/1.1\r\n", .{ request.method, request.target });
    for (request.headerSlice()) |header| {
        if (proxy_headers.isStripped(header.name)) continue;
        if (proxy_headers.namedInConnection(header.name, request.connection_value)) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "expect")) continue;

        try fixed.print("{s}: {s}\r\n", .{ header.name, header.value });
    }

    try fixed.print("Via: {s}\r\n", .{proxy_headers.VIA});
    try proxy_headers.writeForwarded(&fixed, client_addr, request.host);

    switch (request.framing) {
        .none => {},
        .content_length => |len| try fixed.print("Content-Length: {d}\r\n", .{len}),
        .chunked => try fixed.writeAll("Transfer-Encoding: chunked\r\n"),
        .until_close => unreachable,
    }

    try fixed.writeAll("\r\n");

    return fixed.buffered();
}

/// Relay the upstream head to the client: filtered headers plus Via and
/// zixer's framing, Connection: close when this exchange ends the edge conn.
fn writeResponseHead(client_w: *std.Io.Writer, response: *const http1_head.ResponseHead, edge_close: bool) !void {
    try client_w.print("HTTP/1.1 {d} {s}\r\n", .{ response.status, response.reason });
    for (response.headerSlice()) |header| {
        if (proxy_headers.isStripped(header.name)) continue;
        if (proxy_headers.namedInConnection(header.name, response.connection_value)) continue;

        try client_w.print("{s}: {s}\r\n", .{ header.name, header.value });
    }

    try client_w.print("Via: {s}\r\n", .{proxy_headers.VIA});

    switch (response.framing) {
        .none => {
            if (response.status / 100 != 1 and response.status != 204 and response.status != 304)
                try client_w.writeAll("Content-Length: 0\r\n");
        },
        .content_length => |len| try client_w.print("Content-Length: {d}\r\n", .{len}),
        .chunked => try client_w.writeAll("Transfer-Encoding: chunked\r\n"),
        .until_close => {},
    }
    if (edge_close) try client_w.writeAll("Connection: close\r\n");

    try client_w.writeAll("\r\n");
}

fn expectsContinue(request: *const http1_head.RequestHead) bool {
    for (request.headerSlice()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "expect") and
            std.ascii.eqlIgnoreCase(header.value, "100-continue")) return true;
    }

    return false;
}

/// Local error reply with the rfc 9209 Proxy-Status parameter, then close.
fn writeEdgeError(client_w: *std.Io.Writer, status: u16, reason: []const u8, proxy_error: []const u8) void {
    client_w.print(
        "HTTP/1.1 {d} {s}\r\nContent-Length: {d}\r\nProxy-Status: zixer; error=\"{s}\"\r\nConnection: close\r\n\r\n{s}\n",
        .{ status, reason, reason.len + 1, proxy_error, reason },
    ) catch return;
    client_w.flush() catch return;
}

fn nowMs(io: std.Io) i64 {
    return std.Io.Clock.Timestamp.now(io, .real).raw.toMilliseconds();
}

// --------------------------------------------------------- //

/// Copy exactly len bytes from src to dst.
fn pumpExact(src: *std.Io.Reader, dst: *std.Io.Writer, len: u64) !void {
    var chunk: [PUMP_CHUNK]u8 = undefined;
    var remaining = len;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, chunk.len));
        const got = src.readSliceShort(chunk[0..want]) catch return error.ConnectionClosed;
        if (got == 0) return error.ConnectionClosed;

        try dst.writeAll(chunk[0..got]);
        remaining -= got;
    }
}

/// Relay a chunked body, re-emitting the chunk framing zixer parsed. The
/// trailer section is relayed line by line.
fn pumpChunked(src: *std.Io.Reader, dst: *std.Io.Writer) !void {
    while (true) {
        var line_buf: [256]u8 = undefined;
        const size_line = try readLine(src, &line_buf);

        const semicolon = std.mem.indexOfScalar(u8, size_line, ';');
        const size_text = std.mem.trim(u8, if (semicolon) |pos| size_line[0..pos] else size_line, " \t");
        const size = std.fmt.parseInt(u64, size_text, 16) catch return error.BadChunk;

        try dst.print("{x}\r\n", .{size});

        if (size == 0) {
            while (true) {
                const trailer = try readLine(src, &line_buf);
                try dst.writeAll(trailer);
                try dst.writeAll("\r\n");
                if (trailer.len == 0) return;
            }
        }

        try pumpExact(src, dst, size);

        const after = try readLine(src, &line_buf);
        if (after.len != 0) return error.BadChunk;
        try dst.writeAll("\r\n");
    }
}

/// Relay until the source closes. The destination is closed by the caller.
fn pumpUntilClose(src: *std.Io.Reader, dst: *std.Io.Writer) void {
    var chunk: [PUMP_CHUNK]u8 = undefined;
    while (true) {
        const got = src.readSliceShort(&chunk) catch return;
        if (got == 0) return;

        dst.writeAll(chunk[0..got]) catch return;
    }
}

/// One CRLF-terminated line, returned without its terminator.
fn readLine(src: *std.Io.Reader, buf: []u8) ![]const u8 {
    var len: usize = 0;
    while (len < buf.len) {
        const got = src.readSliceShort(buf[len .. len + 1]) catch return error.ConnectionClosed;
        if (got == 0) return error.ConnectionClosed;

        len += 1;
        if (len >= 2 and buf[len - 2] == '\r' and buf[len - 1] == '\n') return buf[0 .. len - 2];
    }

    return error.BadChunk;
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix zixer: http1 proxy, upstream head is rebuilt with forwarded and via" {
    const request = try http1_head.parseRequest("POST /api HTTP/1.1\r\nHost: app.example\r\nConnection: close, X-Hop\r\nX-Hop: secret\r\nAccept: */*\r\nContent-Length: 4\r\nExpect: 100-continue\r\n\r\n");

    var build_buf: [http1_head.MAX_HEAD_BYTES + 512]u8 = undefined;
    const addr = std.Io.net.IpAddress{ .ip4 = .{ .bytes = .{ 192, 0, 2, 7 }, .port = 55000 } };
    const head = try buildUpstreamHead(&build_buf, &request, addr);

    try std.testing.expect(std.mem.startsWith(u8, head, "POST /api HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, head, "Host: app.example\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Accept: */*\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Via: 1.1 zixer\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Forwarded: for=\"192.0.2.7:55000\";proto=http;host=\"app.example\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Content-Length: 4\r\n") != null);

    try std.testing.expect(std.mem.indexOf(u8, head, "Connection") == null);
    try std.testing.expect(std.mem.indexOf(u8, head, "X-Hop") == null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Expect") == null);
    try std.testing.expect(std.mem.endsWith(u8, head, "\r\n\r\n"));
}

test "zix zixer: http1 proxy, response head relays filtered with edge framing" {
    const response = try http1_head.parseResponse("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: keep-alive\r\nKeep-Alive: timeout=5\r\nContent-Length: 2\r\n\r\n", "GET");

    var out_buf: [1024]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);
    try writeResponseHead(&out, &response, false);
    const head = out.buffered();

    try std.testing.expect(std.mem.startsWith(u8, head, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, head, "Content-Type: text/plain\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Content-Length: 2\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Via: 1.1 zixer\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Keep-Alive") == null);
    try std.testing.expect(std.mem.indexOf(u8, head, "Connection") == null);

    var close_buf: [1024]u8 = undefined;
    var close_out = std.Io.Writer.fixed(&close_buf);
    try writeResponseHead(&close_out, &response, true);
    try std.testing.expect(std.mem.indexOf(u8, close_out.buffered(), "Connection: close\r\n") != null);
}

test "zix zixer: http1 proxy, pumpExact moves exactly the length" {
    var src = std.Io.Reader.fixed("hello worldEXTRA");
    var out_buf: [64]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);

    try pumpExact(&src, &out, 11);
    try std.testing.expectEqualStrings("hello world", out.buffered());

    var short = std.Io.Reader.fixed("abc");
    var short_out = std.Io.Writer.fixed(&out_buf);
    try std.testing.expectError(error.ConnectionClosed, pumpExact(&short, &short_out, 5));
}

test "zix zixer: http1 proxy, pumpChunked re-emits chunks and the trailer" {
    var src = std.Io.Reader.fixed("5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nX-Sum: ok\r\n\r\n");
    var out_buf: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);

    try pumpChunked(&src, &out);
    try std.testing.expectEqualStrings("5\r\nhello\r\n6\r\n world\r\n0\r\nX-Sum: ok\r\n\r\n", out.buffered());

    var bad = std.Io.Reader.fixed("nope\r\n");
    var bad_out = std.Io.Writer.fixed(&out_buf);
    try std.testing.expectError(error.BadChunk, pumpChunked(&bad, &bad_out));
}

test "zix zixer: http1 proxy, edge error carries proxy-status" {
    var out_buf: [512]u8 = undefined;
    var out = std.Io.Writer.fixed(&out_buf);

    writeEdgeError(&out, 502, "all upstreams failed", "connection_refused");
    const reply = out.buffered();

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 502 all upstreams failed\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, reply, "Proxy-Status: zixer; error=\"connection_refused\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\nall upstreams failed\n"));
}

// --------------------------------------------------------- //

const site_cfg = @import("site_cfg.zig");

/// Test upstream: accepts conns on a loopback port, records the first request
/// head, answers each request with a canned response.
const FakeUpstream = struct {
    io: std.Io,
    port: u16,
    /// Requests answered before the thread exits, across any number of conns.
    request_quota: usize,
    /// Canned payload the response body echoes when the request had one.
    seen_head: [4096]u8 = undefined,
    seen_len: usize = 0,
    conns_accepted: usize = 0,
    ready: std.atomic.Value(bool) = .init(false),

    fn serve(fake: *FakeUpstream) void {
        const io = fake.io;

        const addr = std.Io.net.IpAddress.parse("127.0.0.1", fake.port) catch return;
        var server = addr.listen(io, .{ .reuse_address = true, .kernel_backlog = 8 }) catch return;
        defer server.deinit(io);
        fake.ready.store(true, .release);

        var answered: usize = 0;
        while (answered < fake.request_quota) {
            const stream = server.accept(io) catch return;
            fake.conns_accepted += 1;

            var read_buf: [4096]u8 = undefined;
            var write_buf: [4096]u8 = undefined;
            var reader = stream.reader(io, &read_buf);
            var writer = stream.writer(io, &write_buf);

            conn: while (answered < fake.request_quota) {
                var head_buf: [4096]u8 = undefined;
                const head = http1_head.readHead(&reader.interface, &head_buf) catch break :conn;
                const request = http1_head.parseRequest(head) catch break :conn;

                if (fake.seen_len == 0) {
                    @memcpy(fake.seen_head[0..head.len], head);
                    fake.seen_len = head.len;
                }

                var body_buf: [256]u8 = undefined;
                var body_len: usize = 0;
                if (request.framing == .content_length) {
                    body_len = @intCast(request.framing.content_length);
                    var got: usize = 0;
                    while (got < body_len) {
                        const n = reader.interface.readSliceShort(body_buf[got..body_len]) catch break :conn;
                        if (n == 0) break :conn;
                        got += n;
                    }
                }

                writer.interface.print(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nKeep-Alive: timeout=5\r\nContent-Length: {d}\r\n\r\necho:{s}",
                    .{ body_len + 5, body_buf[0..body_len] },
                ) catch break :conn;
                writer.interface.flush() catch break :conn;
                answered += 1;
            }

            stream.close(io);
        }
    }
};

fn spawnServeConn(proxy: *const Proxy, stream: std.Io.net.Stream) !std.Thread {
    return std.Thread.spawn(.{}, serveConnThread, .{ proxy, stream });
}

fn serveConnThread(proxy: *const Proxy, stream: std.Io.net.Stream) void {
    serveConn(proxy, stream);
}

fn edgeStream(handle: std.posix.fd_t) std.Io.net.Stream {
    return .{ .socket = .{ .handle = handle, .address = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = 40000 } } } };
}

fn readAllAvailable(io: std.Io, stream: std.Io.net.Stream, buf: []u8) usize {
    var read_buf: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var len: usize = 0;
    while (len < buf.len) {
        const got = reader.interface.readSliceShort(buf[len .. len + 1]) catch break;
        if (got == 0) break;
        len += got;
    }

    return len;
}

fn waitReady(io: std.Io, fake: *FakeUpstream) !void {
    var tries: usize = 0;
    while (tries < 100 and !fake.ready.load(.acquire)) : (tries += 1) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .awake) catch {};
    }

    try std.testing.expect(tries < 100);
}

test "zix zixer: http1 proxy, round trip relays body and rewrites both heads" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeUpstream{ .io = io, .port = 39873, .request_quota = 1 };
    const fake_thread = try std.Thread.spawn(.{}, FakeUpstream.serve, .{&fake});
    try waitReady(io, &fake);

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39873 }};
    var pool = try upstream_pool.Pool.init(std.testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(std.testing.allocator);
    var idle = try upstream_conn.IdleCache.init(std.testing.allocator, 1);
    defer idle.deinit(std.testing.allocator, io);
    const proxy = Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    const client = edgeStream(fds[1]);
    {
        var write_buf: [512]u8 = undefined;
        var writer = client.writer(io, &write_buf);
        try writer.interface.writeAll("POST /api HTTP/1.1\r\nHost: t.example\r\nContent-Length: 4\r\nConnection: close\r\n\r\nping");
        try writer.interface.flush();
    }

    var reply_buf: [2048]u8 = undefined;
    const reply_len = readAllAvailable(io, client, &reply_buf);
    const reply = reply_buf[0..reply_len];
    client.close(io);

    edge_thread.join();
    fake_thread.join();

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, reply, "Via: 1.1 zixer\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "Keep-Alive") == null);
    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\necho:ping"));

    const seen = fake.seen_head[0..fake.seen_len];
    try std.testing.expect(std.mem.startsWith(u8, seen, "POST /api HTTP/1.1\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, seen, "Host: t.example\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "Via: 1.1 zixer\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "Forwarded: for=\"127.0.0.1:40000\";proto=http;host=\"t.example\"\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen, "Connection") == null);
}

test "zix zixer: http1 proxy, edge keep-alive reuses one upstream conn" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeUpstream{ .io = io, .port = 39874, .request_quota = 2 };
    const fake_thread = try std.Thread.spawn(.{}, FakeUpstream.serve, .{&fake});
    try waitReady(io, &fake);

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39874 }};
    var pool = try upstream_pool.Pool.init(std.testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(std.testing.allocator);
    var idle = try upstream_conn.IdleCache.init(std.testing.allocator, 1);
    defer idle.deinit(std.testing.allocator, io);
    const proxy = Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    const client = edgeStream(fds[1]);
    var read_buf: [4096]u8 = undefined;
    var write_buf: [512]u8 = undefined;
    var reader = client.reader(io, &read_buf);
    var writer = client.writer(io, &write_buf);

    try writer.interface.writeAll("GET /a HTTP/1.1\r\nHost: t\r\n\r\n");
    try writer.interface.flush();
    var head_buf: [2048]u8 = undefined;
    const first_head = try http1_head.readHead(&reader.interface, &head_buf);
    const first = try http1_head.parseResponse(first_head, "GET");
    try std.testing.expectEqual(@as(u16, 200), first.status);
    var body: [64]u8 = undefined;
    const first_len: usize = @intCast(first.framing.content_length);
    _ = try reader.interface.readSliceShort(body[0..first_len]);

    try writer.interface.writeAll("GET /b HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();
    var head_buf2: [2048]u8 = undefined;
    const second_head = try http1_head.readHead(&reader.interface, &head_buf2);
    const second = try http1_head.parseResponse(second_head, "GET");
    try std.testing.expectEqual(@as(u16, 200), second.status);

    client.close(io);
    edge_thread.join();
    fake_thread.join();

    // Both requests crossed one upstream tcp conn: the second came from the
    // idle cache instead of a fresh handshake.
    try std.testing.expectEqual(@as(usize, 1), fake.conns_accepted);
}

test "zix zixer: http1 proxy, dead upstream fails over inside one request" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var fake = FakeUpstream{ .io = io, .port = 39875, .request_quota = 1 };
    const fake_thread = try std.Thread.spawn(.{}, FakeUpstream.serve, .{&fake});
    try waitReady(io, &fake);

    // The dead upstream sits first in round-robin order, so the request must
    // fail over to the live one.
    const upstreams = [_]site_cfg.Upstream{
        .{ .host = "127.0.0.1", .port = 39877 },
        .{ .host = "127.0.0.1", .port = 39875 },
    };
    var pool = try upstream_pool.Pool.init(std.testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(std.testing.allocator);
    var idle = try upstream_conn.IdleCache.init(std.testing.allocator, 2);
    defer idle.deinit(std.testing.allocator, io);
    const proxy = Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    const client = edgeStream(fds[1]);
    {
        var write_buf: [512]u8 = undefined;
        var writer = client.writer(io, &write_buf);
        try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n");
        try writer.interface.flush();
    }

    var reply_buf: [2048]u8 = undefined;
    const reply_len = readAllAvailable(io, client, &reply_buf);
    const reply = reply_buf[0..reply_len];
    client.close(io);

    edge_thread.join();
    fake_thread.join();

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expectEqual(@as(usize, 1), pool.upCount());
}

test "zix zixer: http1 proxy, every upstream down answers 502 with proxy-status" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39878 }};
    var pool = try upstream_pool.Pool.init(std.testing.allocator, &upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
    defer pool.deinit(std.testing.allocator);
    var idle = try upstream_conn.IdleCache.init(std.testing.allocator, 1);
    defer idle.deinit(std.testing.allocator, io);
    const proxy = Proxy{ .io = io, .pool = &pool, .idle = &idle };

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds));
    const edge_thread = try spawnServeConn(&proxy, edgeStream(fds[0]));

    const client = edgeStream(fds[1]);
    {
        var write_buf: [512]u8 = undefined;
        var writer = client.writer(io, &write_buf);
        try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: t\r\n\r\n");
        try writer.interface.flush();
    }

    var reply_buf: [2048]u8 = undefined;
    const reply_len = readAllAvailable(io, client, &reply_buf);
    const reply = reply_buf[0..reply_len];
    client.close(io);

    edge_thread.join();

    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 502 "));
    try std.testing.expect(std.mem.indexOf(u8, reply, "Proxy-Status: zixer; error=\"connection_refused\"") != null);

    // A fresh edge conn while the pool is still empty gets the 503: nothing
    // failed inside that exchange, there was just nothing to pick.
    var fds2: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds2));
    const second_edge = try spawnServeConn(&proxy, edgeStream(fds2[0]));

    const client2 = edgeStream(fds2[1]);
    {
        var write_buf: [512]u8 = undefined;
        var writer = client2.writer(io, &write_buf);
        try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: t\r\n\r\n");
        try writer.interface.flush();
    }

    var reply2_buf: [2048]u8 = undefined;
    const reply2_len = readAllAvailable(io, client2, &reply2_buf);
    const reply2 = reply2_buf[0..reply2_len];
    client2.close(io);
    second_edge.join();

    try std.testing.expect(std.mem.startsWith(u8, reply2, "HTTP/1.1 503 "));
    try std.testing.expect(std.mem.indexOf(u8, reply2, "Proxy-Status: zixer; error=\"destination_unavailable\"") != null);
}
