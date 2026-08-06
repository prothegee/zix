//! Integration tests: Http1 dual listener (config.tls_port), cleartext + TLS from ONE worker fleet.

const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

// --------------------------------------------------------- //

const IP: []const u8 = "127.0.0.1";
const PORT: u16 = 9210;
const TLS_PORT: u16 = 9211;
const URING_PORT: u16 = 9213;
const URING_TLS_PORT: u16 = 9214;
const ASYNC_PORT: u16 = 9215;
const ASYNC_TLS_PORT: u16 = 9216;
const CERT: []const u8 = "examples/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/certs/ecdsa_p256_key.pem";

/// The exact bytes okHandler writes, so reads can be exact (a short read on a live TCP socket
/// blocks, so the tests never read more than the server will send).
const OK_RESPONSE: []const u8 = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ndual";

fn okHandler(_: *zix.Http1.Request, res: *zix.Http1.Response, _: *zix.Http1.Context) anyerror!void {
    return res.sendRaw(OK_RESPONSE);
}

const ServeArgs = struct {
    port: u16,
    tls_port: u16,
    dispatch_model: zix.Http1.DispatchModel,
};

/// The server thread runs forever (run() never returns), so everything it touches is intentionally
/// leaked for the lifetime of the test binary: no deinit on the context, logger, or io backend.
fn serveDual(io: std.Io, tls: *zix.Tls.Context, logger: *zix.Logger, args: ServeArgs) void {
    var server = zix.Http1.Server.init(okHandler, .{
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
        .port = PORT,
        .tls_port = TLS_PORT,
        .dispatch_model = .EPOLL,
    } });
    epoll_thread.detach();

    const uring_thread = try std.Thread.spawn(.{}, serveDual, .{ io, tls, logger, ServeArgs{
        .port = URING_PORT,
        .tls_port = URING_TLS_PORT,
        .dispatch_model = .URING,
    } });
    uring_thread.detach();

    const async_thread = try std.Thread.spawn(.{}, serveDual, .{ io, tls, logger, ServeArgs{
        .port = ASYNC_PORT,
        .tls_port = ASYNC_TLS_PORT,
        .dispatch_model = .ASYNC,
    } });
    async_thread.detach();
}

/// One full TLS exchange against tls_port: handshake, one GET, assert the shared route answered.
fn expectTlsOk(io: std.Io, tls_port: u16) !void {
    var stream = try connectRetry(io, tls_port);
    defer stream.close(io);

    var read_buf: [8 * 1024]u8 = undefined;
    var write_buf: [4 * 1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    // TLS 1.3 handshake via the zix client: ClientHello out, server flight in, Finished out.
    var ch_buf: [512]u8 = undefined;
    const started = try zix.Tls.Client.start(.{ .client_random = @splat(0x21), .ephemeral_secret = @splat(0x52) }, &ch_buf);
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

    // Same route as cleartext, over TLS this time.
    var cipher_buf: [512]u8 = undefined;
    try writer.interface.writeAll(finished.connection.writeAppData("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n", &cipher_buf));
    try writer.interface.flush();

    var record_buf: [2048]u8 = undefined;
    const record = try readRecord(&reader.interface, &record_buf);
    var plain: [2048]u8 = undefined;
    const resp = try finished.connection.readAppData(record, &plain);
    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "dual") != null);
}

/// One cleartext exchange against port: exact-size read of the fixed handler response.
fn expectCleartextOk(io: std.Io, port: u16) !void {
    var stream = try connectRetry(io, port);
    defer stream.close(io);

    var read_buf: [1024]u8 = undefined;
    var write_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);

    try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();

    var recv: [OK_RESPONSE.len]u8 = undefined;
    try reader.interface.readSliceAll(&recv);
    try std.testing.expectEqualStrings(OK_RESPONSE, &recv);
}

test "zix integration: Http1 dual listener EPOLL serves cleartext on port" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try startServersOnce();
    try expectCleartextOk(threaded.io(), PORT);
}

test "zix integration: Http1 dual listener EPOLL serves TLS on tls_port with the same routes" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try startServersOnce();
    try expectTlsOk(threaded.io(), TLS_PORT);
}

test "zix integration: Http1 dual listener URING serves cleartext on port" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try startServersOnce();
    try expectCleartextOk(threaded.io(), URING_PORT);
}

test "zix integration: Http1 dual listener URING serves TLS on-ring on tls_port" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try startServersOnce();
    try expectTlsOk(threaded.io(), URING_TLS_PORT);
}

test "zix integration: Http1 dual listener ASYNC serves cleartext on port" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try startServersOnce();
    try expectCleartextOk(threaded.io(), ASYNC_PORT);
}

test "zix integration: Http1 dual listener ASYNC serves TLS via the extra accept thread" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try startServersOnce();
    try expectTlsOk(threaded.io(), ASYNC_TLS_PORT);
}

test "zix integration: Http1 tls_port equal to port is rejected at run" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tls = try zix.Tls.Context.init(std.testing.allocator, io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.HTTP_1_1},
    });
    defer tls.deinit();

    var server = zix.Http1.Server.init(okHandler, .{
        .io = io,
        .ip = IP,
        .port = 9212,
        .tls = &tls,
        .tls_port = 9212,
        .dispatch_model = .EPOLL,
    });
    defer server.deinit();

    try std.testing.expectError(error.TlsPortConflict, server.run());
}
