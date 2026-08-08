//! Integration tests: zix.Http dual listener (config.tls_port), cleartext + TLS from ONE worker fleet.

const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

// --------------------------------------------------------- //

const IP: []const u8 = "127.0.0.1";
const EPOLL_PORT: u16 = 9230;
const EPOLL_TLS_PORT: u16 = 9231;
const URING_PORT: u16 = 9232;
const URING_TLS_PORT: u16 = 9233;
const CERT: []const u8 = "examples/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/certs/ecdsa_p256_key.pem";

fn rootHandler(_: *zix.Http.Request, res: *zix.Http.Response, _: *zix.Http.Context) !void {
    res.setContentType(.TEXT_PLAIN);
    try res.send("dual");
}

fn eventsHandler(_: *zix.Http.Request, res: *zix.Http.Response, _: *zix.Http.Context) !void {
    const sse = try res.sendStream();

    try sse.writeEvent("tick one");
}

const Routes = [_]zix.Http.Route{
    .{ .path = "/", .handler = rootHandler },
    .{ .path = "/events", .handler = eventsHandler },
};
const router = zix.Http.Router(&Routes);

const ServeArgs = struct {
    port: u16,
    tls_port: u16,
    dispatch_model: zix.Http.DispatchModel,
};

/// The server thread runs forever (run() never returns), so everything it touches is intentionally
/// leaked for the lifetime of the test binary.
fn serveDual(io: std.Io, tls: *zix.Tls.Context, logger: *zix.Logger, args: ServeArgs) void {
    var server = zix.Http.Server.init(router.dispatch, .{
        .io = io,
        .ip = IP,
        .port = args.port,
        .tls = tls,
        .tls_port = args.tls_port,
        .dispatch_model = args.dispatch_model,
        .workers = 1,
        .logger = logger,
    });
    defer server.deinit();

    server.run() catch {};
}

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

var servers_started = false;

fn startServersOnce() !void {
    if (servers_started) return;
    servers_started = true;

    // Leaked by design: the detached server threads outlive every test in this binary.
    const gpa = std.heap.smp_allocator;

    const threaded = try gpa.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(gpa, .{});
    const io = threaded.io();

    const logger = try gpa.create(zix.Logger);
    logger.* = try zix.Logger.init(gpa, .{}); // console OFF, no file: fully silent

    const tls = try gpa.create(zix.Tls.Context);
    tls.* = try zix.Tls.Context.init(gpa, io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.HTTP_1_1},
    });

    const epoll_thread = try std.Thread.spawn(.{}, serveDual, .{ io, tls, logger, ServeArgs{
        .port = EPOLL_PORT,
        .tls_port = EPOLL_TLS_PORT,
        .dispatch_model = .EPOLL,
    } });
    epoll_thread.detach();

    const uring_thread = try std.Thread.spawn(.{}, serveDual, .{ io, tls, logger, ServeArgs{
        .port = URING_PORT,
        .tls_port = URING_TLS_PORT,
        .dispatch_model = .URING,
    } });
    uring_thread.detach();
}

/// One cleartext exchange: the handler body arrives after the response head.
fn expectCleartextOk(io: std.Io, port: u16) !void {
    var stream = try connectRetry(io, port);
    defer stream.close(io);

    var read_buf: [2048]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();

    // Connection: close, so the server ends the stream after the response: read to EOF.
    var recv: [2048]u8 = undefined;
    var total: usize = 0;
    while (total < recv.len) {
        const n = reader.interface.readSliceShort(recv[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    try std.testing.expect(std.mem.indexOf(u8, recv[0..total], "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, recv[0..total], "dual") != null);
}

/// One full TLS exchange against tls_port: handshake, one GET, assert the shared route answered.
fn expectTlsOk(io: std.Io, tls_port: u16) !void {
    var stream = try connectRetry(io, tls_port);
    defer stream.close(io);

    var read_buf: [8 * 1024]u8 = undefined;
    var write_buf: [4 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    var ch_buf: [512]u8 = undefined;
    const started = try zix.Tls.Client.start(.{ .client_random = @splat(0x51), .ephemeral_secret = @splat(0x82) }, &ch_buf);
    var state = started.state;

    var hello_record: [600]u8 = undefined;
    hello_record[0] = 22; // handshake record
    std.mem.writeInt(u16, hello_record[1..3], 0x0303, .big);
    std.mem.writeInt(u16, hello_record[3..5], @intCast(started.client_hello.len), .big);
    @memcpy(hello_record[5 .. 5 + started.client_hello.len], started.client_hello);
    try writer.interface.writeAll(hello_record[0 .. 5 + started.client_hello.len]);
    try writer.interface.flush();

    var flight_buf: [4096]u8 = undefined;
    var flight_len: usize = 0;
    for (0..3) |_| {
        const record = try readRecord(&reader.interface, flight_buf[flight_len..]);
        flight_len += record.len;
    }

    var fin_buf: [256]u8 = undefined;
    var finished = try zix.Tls.Client.finish(&state, flight_buf[0..flight_len], &fin_buf);
    try writer.interface.writeAll(finished.client_finished);
    try writer.interface.flush();

    var cipher_buf: [512]u8 = undefined;
    try writer.interface.writeAll(finished.connection.writeAppData("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n", &cipher_buf));
    try writer.interface.flush();

    var record_buf: [4096]u8 = undefined;
    const record = try readRecord(&reader.interface, &record_buf);
    var plain: [4096]u8 = undefined;
    const resp = try finished.connection.readAppData(record, &plain);
    try std.testing.expect(std.mem.indexOf(u8, resp, "200") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "dual") != null);
}

test "zix integration: Http dual listener EPOLL serves cleartext on port" {
    if (builtin.os.tag != .linux) {
        std.log.info("EPOLL/URING is Linux-only, test skipped", .{});
        return;
    }

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try startServersOnce();
    try expectCleartextOk(threaded.io(), EPOLL_PORT);
}

test "zix integration: Http dual listener EPOLL serves TLS on tls_port with the same routes" {
    if (builtin.os.tag != .linux) {
        std.log.info("EPOLL/URING is Linux-only, test skipped", .{});
        return;
    }

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try startServersOnce();
    try expectTlsOk(threaded.io(), EPOLL_TLS_PORT);
}

test "zix integration: Http dual listener EPOLL streams SSE over TLS on the mux loop" {
    if (builtin.os.tag != .linux) {
        std.log.info("EPOLL/URING is Linux-only, test skipped", .{});
        return;
    }

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    try startServersOnce();

    var stream = try connectRetry(io, EPOLL_TLS_PORT);
    defer stream.close(io);

    var read_buf: [8 * 1024]u8 = undefined;
    var write_buf: [4 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    var ch_buf: [512]u8 = undefined;
    const started = try zix.Tls.Client.start(.{ .client_random = @splat(0x61), .ephemeral_secret = @splat(0x92) }, &ch_buf);
    var state = started.state;

    var hello_record: [600]u8 = undefined;
    hello_record[0] = 22; // handshake record
    std.mem.writeInt(u16, hello_record[1..3], 0x0303, .big);
    std.mem.writeInt(u16, hello_record[3..5], @intCast(started.client_hello.len), .big);
    @memcpy(hello_record[5 .. 5 + started.client_hello.len], started.client_hello);
    try writer.interface.writeAll(hello_record[0 .. 5 + started.client_hello.len]);
    try writer.interface.flush();

    var flight_buf: [4096]u8 = undefined;
    var flight_len: usize = 0;
    for (0..3) |_| {
        const record = try readRecord(&reader.interface, flight_buf[flight_len..]);
        flight_len += record.len;
    }

    var fin_buf: [256]u8 = undefined;
    var finished = try zix.Tls.Client.finish(&state, flight_buf[0..flight_len], &fin_buf);
    try writer.interface.writeAll(finished.client_finished);
    try writer.interface.flush();

    var cipher_buf: [512]u8 = undefined;
    try writer.interface.writeAll(finished.connection.writeAppData("GET /events HTTP/1.1\r\nHost: localhost\r\n\r\n", &cipher_buf));
    try writer.interface.flush();

    // The streamed response arrives as records sealed per write: collect until the SSE headers and
    // the one event both came through.
    var collected: [4096]u8 = undefined;
    var total: usize = 0;
    while (total < collected.len) {
        var record_buf: [4096]u8 = undefined;
        const record = readRecord(&reader.interface, &record_buf) catch break;
        var plain: [4096]u8 = undefined;
        const part = finished.connection.readAppData(record, &plain) catch break;
        @memcpy(collected[total..][0..part.len], part);
        total += part.len;

        if (std.mem.indexOf(u8, collected[0..total], "tick one") != null) break;
    }

    try std.testing.expect(std.mem.indexOf(u8, collected[0..total], "text/event-stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, collected[0..total], "tick one") != null);
}

test "zix integration: Http dual listener URING serves cleartext on port" {
    if (builtin.os.tag != .linux) {
        std.log.info("EPOLL/URING is Linux-only, test skipped", .{});
        return;
    }

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try startServersOnce();
    try expectCleartextOk(threaded.io(), URING_PORT);
}

test "zix integration: Http dual listener URING serves TLS on-ring on tls_port" {
    if (builtin.os.tag != .linux) {
        std.log.info("EPOLL/URING is Linux-only, test skipped", .{});
        return;
    }

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try startServersOnce();
    try expectTlsOk(threaded.io(), URING_TLS_PORT);
}

test "zix integration: Http tls_port equal to port is rejected at run" {
    if (builtin.os.tag != .linux) {
        std.log.info("EPOLL/URING is Linux-only, test skipped", .{});
        return;
    }

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tls = try zix.Tls.Context.init(std.testing.allocator, io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.HTTP_1_1},
    });
    defer tls.deinit();

    var server = zix.Http.Server.init(router.dispatch, .{
        .io = io,
        .ip = IP,
        .port = 9234,
        .tls = &tls,
        .tls_port = 9234,
        .dispatch_model = .EPOLL,
    });
    defer server.deinit();

    try std.testing.expectError(error.TlsPortConflict, server.run());
}
