//! HTTP-family protocol checks for all_runner.zig.
//!
//! Covers the arena and http1 engines (GET, feature routes, static files,
//! compression, SSE, WebSocket), prior-knowledge h2c, and HTTP/3 over QUIC.
//! Each spawns its server, waits for the port, then drives a native client.

const std = @import("std");
const zix = @import("zix");
const common = @import("common.zig");
const wire = @import("wire.zig");
const http3_client = @import("http3_client.zig");

const Http2 = zix.Http2;

// --------------------------------------------------------- //

pub fn runHttp(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 4096,
    });
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    var resp = try client.get(url, .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;
    if (resp.body().len == 0) return error.EmptyBody;
}

pub fn runHttp1(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 4096,
    });
    defer client.deinit();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    var resp = try client.get(url, .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;
    if (!std.mem.eql(u8, resp.body(), "Hello, World!")) return error.UnexpectedBody;
}

pub fn runHttpGet(
    io: std.Io,
    server_path: []const u8,
    port: u16,
    route: []const u8,
    origin: []const u8,
    expected_substr: []const u8,
) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 16384,
    });
    defer client.deinit();

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, route });

    const origin_header = std.http.Header{ .name = "Origin", .value = origin };
    const headers: []const std.http.Header = if (origin.len > 0) &[_]std.http.Header{origin_header} else &.{};

    var resp = try client.get(url, .{ .headers = headers });
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;

    if (expected_substr.len > 0) {
        if (!std.mem.containsAtLeast(u8, resp.body(), 1, expected_substr)) return error.MissingExpectedSubstring;
    }
}

// GET route and assert the named response header carries the expected value. Validates the custom
// headers the xtra-headers examples attach, not just the 200 status.
pub fn runHttpHeader(io: std.Io, server_path: []const u8, port: u16, route: []const u8, header_name: []const u8, header_value: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 16384,
    });
    defer client.deinit();

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}{s}", .{ port, route });

    var resp = try client.get(url, .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;

    const got = resp.header(header_name) orelse return error.MissingExpectedHeader;
    if (!std.mem.eql(u8, got, header_value)) return error.UnexpectedHeaderValue;
}

pub fn runHttpStatic(
    io: std.Io,
    server_path: []const u8,
    port: u16,
    filename: []const u8,
    file_content: []const u8,
    multipart_path: ?[]const u8,
) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    var file_path_buf: [256]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&file_path_buf, "public/secret/{s}", .{filename});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = file_content });

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    var client = zix.Http.Client.init(.{
        .allocator = arena.allocator(),
        .io = io,
        .connect_timeout_ms = 3000,
        .max_response_body = 4096,
    });
    defer client.deinit();

    var url_buf: [512]u8 = undefined;
    const url = try std.fmt.bufPrint(
        &url_buf,
        "http://127.0.0.1:{d}/secret/{s}?sec=abc123",
        .{ port, filename },
    );

    var resp = try client.get(url, .{});
    defer resp.deinit();

    if (resp.status() != 200) return error.UnexpectedStatus;
    if (!std.mem.eql(u8, resp.body(), file_content)) return error.StaticBodyMismatch;

    // Multipart upload round trip (http1_static only): POST a multipart/form-data body to the
    // upload route, then GET the saved file back through the engine static fallback at /u/<name>.
    if (multipart_path) |mp_path| try common.multipartUploadRoundTrip(io, port, mp_path);
}

// Validate every available coding the compression examples serve. The /gzip, /deflate, /br routes
// force one specific coding; /data negotiates and, since only one coding is accepted, returns it.
// For each, assert Content-Encoding then decode the body and check it round-trips to the source.
pub fn runHttpCompression(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    try checkCoding(io, port, "/gzip", .GZIP);
    try checkCoding(io, port, "/deflate", .DEFLATE);
    try checkCoding(io, port, "/br", .BR);
    try checkCoding(io, port, "/data", .BR);
}

// One coding check over a raw socket: GET route with Accept-Encoding set to that coding, then assert
// 200 and a matching Content-Encoding and decode the body and confirm the source text. A raw read is
// used on purpose: zix.Http.Client wraps std.http.Client, which decompresses gzip/deflate but not
// brotli and stalls forever on a Content-Encoding: br response. Reading the raw bytes here keeps the
// compressed payload intact for zix.utils.compression.decode, and the read terminates on the
// Content-Length body (not EOF) so a keep-alive server cannot hang it. encoding is a compressed
// coding, so contentEncoding() is never null.
fn checkCoding(io: std.Io, port: u16, route: []const u8, encoding: zix.utils.compression.Encoding) !void {
    const token = encoding.contentEncoding().?;

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    const fd = stream.socket.handle;

    var req_buf: [256]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: localhost\r\nAccept-Encoding: {s}\r\nConnection: close\r\n\r\n", .{ route, token });

    try wire.tlsWriteAll(fd, req);

    var buf: [16384]u8 = undefined;
    var len: usize = 0;
    var header_end: usize = 0;
    var content_length: usize = 0;
    while (len < buf.len) {
        const n = std.posix.read(fd, buf[len..]) catch break;
        if (n == 0) break;

        len += n;
        if (header_end == 0) {
            if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n")) |idx| {
                header_end = idx + 4;
                content_length = wire.parseContentLength(buf[0..idx]) orelse return error.NoContentLength;
            }
        }

        if (header_end != 0 and len >= header_end + content_length) break;
    }
    if (header_end == 0) return error.NoHeaderTerminator;

    const head = buf[0..header_end];
    if (std.mem.indexOf(u8, head, " 200 ") == null) return error.UnexpectedStatus;

    const content_encoding = wire.headerValue(head, "content-encoding") orelse return error.MissingContentEncoding;
    if (!std.ascii.eqlIgnoreCase(content_encoding, token)) return error.UnexpectedContentEncoding;

    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();

    const body = buf[header_end .. header_end + content_length];
    const decoded = try zix.utils.compression.decode(arena.allocator(), encoding, body, 16384);
    if (!std.mem.containsAtLeast(u8, decoded, 1, "zix response compression demo")) return error.MissingExpectedBody;
}

pub fn runSse(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/events", .{port});

    var sse_client = zix.Http.SseClient.init(.{ .io = io, .connect_timeout_ms = 3000 });
    var stream = try sse_client.open(url);
    defer stream.deinit();

    var buf: [4096]u8 = undefined;
    const event = try stream.next(&buf) orelse return error.NoSseEvent;

    if (event.data.len == 0) return error.EmptySseEvent;
}

pub fn runWs(io: std.Io, server_path: []const u8, port: u16, ws_route: []const u8) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    var url_buf: [256]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "ws://127.0.0.1:{d}{s}", .{ port, ws_route });

    var wsc = zix.Http.WsClient.init(.{ .io = io, .connect_timeout_ms = 3000 });
    var conn = try wsc.connect(url);
    defer conn.deinit();

    try conn.send(.text, "hello");

    var payload_buf: [256]u8 = undefined;
    const frame = try conn.recv(&payload_buf) orelse return error.NoWsFrame;

    if (!std.mem.containsAtLeast(u8, frame.payload, 1, "hello")) return error.UnexpectedEcho;
}

pub fn runHttp2(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try common.waitForTcpPort(io, &server_child, port, common.START_TIMEOUT_MS);

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);
    const fd = stream.socket.handle;

    // Prior-knowledge h2c: preface, empty SETTINGS, then HEADERS GET / on stream 1.
    var req: [512]u8 = undefined;
    var n: usize = 0;
    @memcpy(req[0..Http2.PREFACE.len], Http2.PREFACE);
    n += Http2.PREFACE.len;

    var fh: [Http2.FRAME_HEADER_LEN]u8 = undefined;
    Http2.encodeFrameHeader(&fh, .{ .length = 0, .frame_type = Http2.FRAME_TYPE_SETTINGS, .flags = 0, .stream_id = 0 });
    @memcpy(req[n..][0..fh.len], &fh);
    n += fh.len;

    var hbuf: [256]u8 = undefined;
    var enc = Http2.HpackEncoder.init(&hbuf);
    try enc.writeHeader(":method", "GET");
    try enc.writeHeader(":path", "/");
    try enc.writeHeader(":scheme", "http");
    try enc.writeHeader(":authority", "localhost");
    const hblock = enc.encoded();
    Http2.encodeFrameHeader(&fh, .{ .length = @intCast(hblock.len), .frame_type = Http2.FRAME_TYPE_HEADERS, .flags = Http2.FLAG_END_HEADERS | Http2.FLAG_END_STREAM, .stream_id = 1 });
    @memcpy(req[n..][0..fh.len], &fh);
    n += fh.len;
    @memcpy(req[n..][0..hblock.len], hblock);
    n += hblock.len;

    try wire.tlsWriteAll(fd, req[0..n]);

    var scanner: wire.H2Scanner = .{};
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        var tmp: [16384]u8 = undefined;
        const rc = std.os.linux.read(fd, tmp[0..].ptr, tmp.len);
        switch (std.posix.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (rc == 0) return error.ConnectionClosed;

        if (try scanner.push(tmp[0..rc])) return;
    }

    return error.NoStatus200;
}

/// HTTP/3 over QUIC: spawn the server, then drive one native round trip with the hand-rolled QUIC
/// client (zix.Http3 primitives, no external tool). QUIC binds a UDP socket with no TCP accept to
/// poll, so the server gets a short fixed moment to bind. Asserts the /baseline2 handler summed the
/// query (a=20 + b=22 = 42).
pub fn runHttp3(io: std.Io, server_path: []const u8, port: u16) !void {
    var server_child = try common.spawnServer(io, server_path);
    defer server_child.kill(io);

    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(600), .awake);

    var body_buf: [256]u8 = undefined;
    const body = try http3_client.fetch(io, "127.0.0.1", port, "/baseline2?a=20&b=22", &body_buf);

    if (!std.mem.eql(u8, body, "42")) return error.UnexpectedBody;
}
