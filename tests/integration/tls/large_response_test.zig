//! Integration tests: a TLS response larger than one TLS record.
//!
//! A TLS 1.3 record carries at most 2^14 bytes of plaintext (RFC 8446 5.1), so anything longer has
//! to leave as several records. These drive a real TLS server with a real handshake and assert that
//! a body spanning one, two, three, and four records arrives whole and unchanged, and that the
//! server is still answering afterwards.
//!
//! The sizes are chosen around the record boundary rather than at round numbers, because that is
//! where a split goes wrong: one byte over the ceiling is the first case that needs two records.

const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

// --------------------------------------------------------- //

const IP: []const u8 = "127.0.0.1";
const TLS_PORT: u16 = 9250;
const URING_TLS_PORT: u16 = 9251;

const is_linux = builtin.target.os.tag == .linux;

/// Dispatch model behind TLS_PORT, the port the record-splitting tests use.
///
/// Note:
/// - EPOLL on Linux, the production path there. ASYNC elsewhere, because ADR-065 makes EPOLL and
///   URING Linux-only: run() rejects them off Linux, which left the server thread exiting at once
///   and every test here failing with ServerNotUp. ADR-066 puts TLS on ASYNC for all platforms,
///   so the record splitting under test is genuinely exercised rather than skipped.
const SPLIT_MODEL: zix.Http1.DispatchModel = if (is_linux) .EPOLL else .ASYNC;
const CERT: []const u8 = "examples/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/certs/ecdsa_p256_key.pem";

/// Largest body a test asks for. Kept under the engine's TLS response staging, which bounds the
/// whole response (headers included), not just the body.
const BODY_MAX: usize = 60 * 1024;

/// Body bytes the handler serves, filled once with a non-repeating pattern so a truncated or
/// misordered record cannot pass as correct.
var body_source: [BODY_MAX]u8 = undefined;

fn fillBodySource() void {
    for (&body_source, 0..) |*byte, index| byte.* = @intCast('!' + index % 90);
}

// --------------------------------------------------------- //

/// GET /big?n=<bytes> : a body of exactly n bytes from the pattern above.
fn bigHandler(req: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) anyerror!void {
    const raw = req.queryParam("n") orelse return res.send(body_source[0..16]);
    const want = std.fmt.parseInt(usize, raw, 10) catch 16;

    try res.send(body_source[0..@min(want, body_source.len)]);
}

const ServeArgs = struct {
    port: u16,
    dispatch_model: zix.Http1.DispatchModel,
};

/// The server thread runs forever (run() never returns), so everything it touches is intentionally
/// leaked for the lifetime of the test binary.
fn serveTls(io: std.Io, tls: *zix.Tls.Context, logger: *zix.Logger, args: ServeArgs) void {
    var server = zix.Http1.Server.init(bigHandler, .{
        .io = io,
        .ip = IP,
        .port = args.port,
        .tls = tls,
        .dispatch_model = args.dispatch_model,
        .workers = 1,
        .logger = logger,
    });
    defer server.deinit();

    server.run() catch {};
}

var servers_started = false;

fn startServersOnce() !void {
    if (servers_started) return;
    servers_started = true;

    fillBodySource();

    // Leaked by design: the detached server threads outlive every test in this binary.
    const gpa = std.heap.smp_allocator;

    const threaded = try gpa.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(gpa, .{});
    const io = threaded.io();

    const logger = try gpa.create(zix.Logger);
    logger.* = try zix.Logger.init(gpa, .{});

    const tls = try gpa.create(zix.Tls.Context);
    tls.* = try zix.Tls.Context.init(gpa, io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.HTTP_1_1},
    });

    const split_thread = try std.Thread.spawn(.{}, serveTls, .{ io, tls, logger, ServeArgs{
        .port = TLS_PORT,
        .dispatch_model = SPLIT_MODEL,
    } });
    split_thread.detach();

    // No URING server off Linux: run() would reject the model and the thread would exit, leaving
    // a port nothing listens on. The one test that drives it skips there instead.
    if (comptime !is_linux) return;

    const uring_thread = try std.Thread.spawn(.{}, serveTls, .{ io, tls, logger, ServeArgs{
        .port = URING_TLS_PORT,
        .dispatch_model = .URING,
    } });
    uring_thread.detach();
}

// --------------------------------------------------------- //

fn connectRetry(io: std.Io, port: u16) !std.Io.net.Stream {
    const server_addr = try std.Io.net.IpAddress.resolve(io, IP, port);

    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        if (server_addr.connect(io, .{ .mode = .stream })) |stream| {
            return stream;
        } else |_| {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
        }
    }

    return error.ServerNotUp;
}

/// Read exactly one TLS record (5-byte header + body) into buf.
fn readRecord(reader: *std.Io.Reader, buf: []u8) ![]const u8 {
    try reader.readSliceAll(buf[0..5]);

    const length = std.mem.readInt(u16, buf[3..5], .big);
    try reader.readSliceAll(buf[5 .. 5 + length]);

    return buf[0 .. 5 + length];
}

/// A live TLS connection with the handshake already done.
const Session = struct {
    stream: std.Io.net.Stream,
    read_buf: []u8,
    write_buf: []u8,
    reader: std.Io.net.Stream.Reader,
    writer: std.Io.net.Stream.Writer,
    conn: zix.Tls.Client.ClientConnection,
};

/// Handshake against a TLS port and hand back the established connection.
fn handshake(io: std.Io, allocator: std.mem.Allocator, port: u16, session: *Session) !void {
    session.stream = try connectRetry(io, port);
    session.read_buf = try allocator.alloc(u8, 64 * 1024);
    session.write_buf = try allocator.alloc(u8, 8 * 1024);
    session.reader = session.stream.reader(io, session.read_buf);
    session.writer = session.stream.writer(io, session.write_buf);

    var ch_buf: [512]u8 = undefined;
    const started = try zix.Tls.Client.start(.{ .client_random = @splat(0x31), .ephemeral_secret = @splat(0x62) }, &ch_buf);
    var state = started.state;

    var hello_record: [600]u8 = undefined;
    hello_record[0] = 22;
    std.mem.writeInt(u16, hello_record[1..3], 0x0303, .big);
    std.mem.writeInt(u16, hello_record[3..5], @intCast(started.client_hello.len), .big);
    @memcpy(hello_record[5 .. 5 + started.client_hello.len], started.client_hello);

    try session.writer.interface.writeAll(hello_record[0 .. 5 + started.client_hello.len]);
    try session.writer.interface.flush();

    var flight_buf: [4096]u8 = undefined;
    var flight_len: usize = 0;
    for (0..3) |_| {
        const record = try readRecord(&session.reader.interface, flight_buf[flight_len..]);
        flight_len += record.len;
    }

    var fin_buf: [256]u8 = undefined;
    const finished = try zix.Tls.Client.finish(&state, flight_buf[0..flight_len], &fin_buf);

    try session.writer.interface.writeAll(finished.client_finished);
    try session.writer.interface.flush();

    session.conn = finished.connection;
}

/// A reassembled response and how many TLS records carried it.
const Fetched = struct {
    response: []const u8,
    records: usize,
};

/// Send one GET and reassemble the whole HTTP response across however many TLS records it takes.
fn fetch(session: *Session, path: []const u8, out: []u8) !Fetched {
    var request_buf: [256]u8 = undefined;
    const request = try std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\nHost: localhost\r\n\r\n", .{path});

    var cipher_buf: [512]u8 = undefined;
    try session.writer.interface.writeAll(session.conn.writeAppData(request, &cipher_buf));
    try session.writer.interface.flush();

    var record_buf: [17 * 1024]u8 = undefined;
    var plain: [(1 << 14) + 1]u8 = undefined;
    var filled: usize = 0;
    var body_start: ?usize = null;
    var expected: usize = 0;
    var records: usize = 0;

    // Keep pulling records until the headers name a length and that many body bytes have arrived.
    // A response past one record's worth of plaintext only completes after several.
    while (true) {
        const record = try readRecord(&session.reader.interface, &record_buf);
        const opened = try session.conn.readAppData(record, &plain);
        records += 1;

        if (filled + opened.len > out.len) return error.ResponseTooLarge;
        @memcpy(out[filled..][0..opened.len], opened);
        filled += opened.len;

        if (body_start == null) {
            if (std.mem.indexOf(u8, out[0..filled], "\r\n\r\n")) |mark| {
                body_start = mark + 4;

                const head = out[0..mark];
                const label = std.mem.indexOf(u8, head, "Content-Length: ") orelse return error.NoContentLength;
                const after = head[label + "Content-Length: ".len ..];
                const end = std.mem.indexOfScalar(u8, after, '\r') orelse after.len;
                expected = try std.fmt.parseInt(usize, after[0..end], 10);
            }
        }

        if (body_start) |start| {
            if (filled - start >= expected) return .{ .response = out[0..filled], .records = records };
        }
    }
}

/// Fetch a body of n bytes and check it against the pattern the handler serves.
///
/// Return:
/// - usize (how many TLS records carried the response)
fn expectBody(session: *Session, allocator: std.mem.Allocator, want: usize) !usize {
    const out = try allocator.alloc(u8, want + 4096);
    defer allocator.free(out);

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/big?n={d}", .{want});

    const fetched = try fetch(session, path, out);
    const mark = std.mem.indexOf(u8, fetched.response, "\r\n\r\n").?;
    const body = fetched.response[mark + 4 ..];

    try std.testing.expect(std.mem.indexOf(u8, fetched.response, "200 OK") != null);
    try std.testing.expectEqual(want, body.len);
    try std.testing.expectEqualSlices(u8, body_source[0..want], body);

    return fetched.records;
}

// --------------------------------------------------------- //

test "zix integration: TLS serves a body spanning one two three and four records" {
    try startServersOnce();

    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var session: Session = undefined;
    try handshake(io, gpa, TLS_PORT, &session);
    defer {
        session.stream.close(io);
        gpa.free(session.read_buf);
        gpa.free(session.write_buf);
    }

    // Under, exactly at, and one past the single-record ceiling, then two and four records' worth.
    // The 16385 case is the one that used to run off the end of a record-sized buffer.
    const sizes = [_]usize{ 4096, (1 << 14) - 1, (1 << 14), (1 << 14) + 1, 20000, 40000, 58000 };
    for (sizes) |want| _ = try expectBody(&session, gpa, want);

    // The point of the split is that a large body genuinely leaves as several records, so assert
    // the record count grows with the body rather than trusting the reassembly alone.
    try std.testing.expect(try expectBody(&session, gpa, 4096) == 1);
    try std.testing.expect(try expectBody(&session, gpa, 40000) >= 3);
    try std.testing.expect(try expectBody(&session, gpa, 58000) >= 4);
}

test "zix integration: TLS keeps answering after a multi-record response" {
    try startServersOnce();

    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var session: Session = undefined;
    try handshake(io, gpa, TLS_PORT, &session);
    defer {
        session.stream.close(io);
        gpa.free(session.read_buf);
        gpa.free(session.write_buf);
    }

    // A body over the ceiling used to take the process down, so the small request after it is the
    // real assertion: the connection and the server both survived.
    _ = try expectBody(&session, gpa, 40000);
    _ = try expectBody(&session, gpa, 32);
    _ = try expectBody(&session, gpa, 50000);
    _ = try expectBody(&session, gpa, 8);
}

test "zix integration: TLS on the URING model splits a large response the same way" {
    // URING dispatch is Linux-only.
    if (comptime !is_linux) {
        std.log.info("EPOLL/URING is Linux-only, test skipped", .{});
        return;
    }

    try startServersOnce();

    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var session: Session = undefined;
    try handshake(io, gpa, URING_TLS_PORT, &session);
    defer {
        session.stream.close(io);
        gpa.free(session.read_buf);
        gpa.free(session.write_buf);
    }

    try std.testing.expect(try expectBody(&session, gpa, (1 << 14) + 1) >= 2);
    try std.testing.expect(try expectBody(&session, gpa, 45000) >= 3);
}
