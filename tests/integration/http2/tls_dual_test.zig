//! Integration tests: Http2 dual listener (config.tls_port), h2c + h2-over-TLS from ONE worker fleet.

const std = @import("std");
const builtin = @import("builtin");
const zix = @import("zix");

// --------------------------------------------------------- //

const IP: []const u8 = "127.0.0.1";
const EPOLL_PORT: u16 = 9220;
const EPOLL_TLS_PORT: u16 = 9221;
const URING_PORT: u16 = 9222;
const URING_TLS_PORT: u16 = 9223;
const CERT: []const u8 = "examples/tls/certs/ecdsa_p256_cert.pem";
const KEY: []const u8 = "examples/tls/certs/ecdsa_p256_key.pem";

const h2_preface: []const u8 = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
const settings_frame_type: u8 = 0x04;

fn okHandler(_: []const u8, _: []const zix.Http2.Header, _: []const u8, fd: std.posix.fd_t, sid: u31) void {
    zix.Http2.sendResponseFD(fd, sid, 200, "text/plain", "dual") catch {};
}

const Routes = [_]zix.Http2.Route{
    .{ .path = "/", .handler = okHandler },
};

const ServeArgs = struct {
    port: u16,
    tls_port: u16,
    dispatch_model: zix.Http2.DispatchModel,
};

/// The server thread runs forever (run() never returns), so everything it touches is intentionally
/// leaked for the lifetime of the test binary.
fn serveDual(io: std.Io, tls: *zix.Tls.Context, logger: *zix.Logger, args: ServeArgs) void {
    var server = zix.Http2.Server.init(&Routes, .{
        .io = io,
        .ip = IP,
        .port = args.port,
        .tls = tls,
        .tls_port = args.tls_port,
        .dispatch_model = args.dispatch_model,
        .pool_size = 1,
        .logger = logger,
    });
    defer server.deinit();

    server.run() catch {};
}

fn connectRetry(io: std.Io, port: u16) !std.Io.net.Stream {
    const sa = try std.Io.net.IpAddress.resolve(io, IP, port);

    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        if (sa.connect(io, .{ .mode = .stream })) |stream| {
            return stream;
        } else |_| {
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(20), .awake) catch {};
        }
    }

    return error.ServerNotUp;
}

/// Read exactly one TLS record (5-byte header + body) into buf.
fn readRecord(rd: *std.Io.Reader, buf: []u8) ![]const u8 {
    try rd.readSliceAll(buf[0..5]);

    const length = std.mem.readInt(u16, buf[3..5], .big);
    try rd.readSliceAll(buf[5 .. 5 + length]);

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
        .alpn = &.{.H2},
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

/// h2c smoke exchange on the cleartext port: preface + empty SETTINGS out, a SETTINGS frame back.
fn expectH2cSettings(io: std.Io, port: u16) !void {
    var stream = try connectRetry(io, port);
    defer stream.close(io);

    var rd_buf: [4 * 1024]u8 = undefined;
    var wr_buf: [1024]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    const empty_settings = [_]u8{ 0, 0, 0, settings_frame_type, 0, 0, 0, 0, 0 };
    try wr.interface.writeAll(h2_preface);
    try wr.interface.writeAll(&empty_settings);
    try wr.interface.flush();

    // The server answers with its own SETTINGS frame first (RFC 7540 3.5).
    var frame_head: [9]u8 = undefined;
    try rd.interface.readSliceAll(&frame_head);
    try std.testing.expectEqual(settings_frame_type, frame_head[3]);
}

/// h2-over-TLS smoke exchange on tls_port: ALPN h2 handshake, preface + SETTINGS as application
/// data, a SETTINGS frame back inside the first record.
fn expectH2TlsSettings(io: std.Io, tls_port: u16) !void {
    var stream = try connectRetry(io, tls_port);
    defer stream.close(io);

    var rd_buf: [8 * 1024]u8 = undefined;
    var wr_buf: [4 * 1024]u8 = undefined;
    var rd = stream.reader(io, &rd_buf);
    var wr = stream.writer(io, &wr_buf);

    var ch_buf: [512]u8 = undefined;
    const started = try zix.Tls.Client.start(.{
        .client_random = @splat(0x31),
        .ephemeral_secret = @splat(0x62),
        .alpn = &.{.H2},
    }, &ch_buf);
    var state = started.state;

    var ch_rec: [600]u8 = undefined;
    ch_rec[0] = 22; // handshake record
    std.mem.writeInt(u16, ch_rec[1..3], 0x0303, .big);
    std.mem.writeInt(u16, ch_rec[3..5], @intCast(started.client_hello.len), .big);
    @memcpy(ch_rec[5 .. 5 + started.client_hello.len], started.client_hello);
    try wr.interface.writeAll(ch_rec[0 .. 5 + started.client_hello.len]);
    try wr.interface.flush();

    var flight_buf: [4096]u8 = undefined;
    var flen: usize = 0;
    for (0..3) |_| {
        const rec = try readRecord(&rd.interface, flight_buf[flen..]);
        flen += rec.len;
    }

    var fin_buf: [256]u8 = undefined;
    var finished = try zix.Tls.Client.finish(&state, flight_buf[0..flen], &fin_buf);
    try std.testing.expectEqual(zix.Tls.Alpn.H2, finished.alpn.?);
    try wr.interface.writeAll(finished.client_finished);
    try wr.interface.flush();

    var plain_out: [128]u8 = undefined;
    @memcpy(plain_out[0..h2_preface.len], h2_preface);
    const empty_settings = [_]u8{ 0, 0, 0, settings_frame_type, 0, 0, 0, 0, 0 };
    @memcpy(plain_out[h2_preface.len..][0..empty_settings.len], &empty_settings);

    var enc: [512]u8 = undefined;
    try wr.interface.writeAll(finished.connection.writeAppData(plain_out[0 .. h2_preface.len + empty_settings.len], &enc));
    try wr.interface.flush();

    var rec_buf: [2048]u8 = undefined;
    const rec = try readRecord(&rd.interface, &rec_buf);
    var plain: [2048]u8 = undefined;
    const reply = try finished.connection.readAppData(rec, &plain);
    try std.testing.expect(reply.len >= 9);
    try std.testing.expectEqual(settings_frame_type, reply[3]);
}

test "zix integration: Http2 dual listener EPOLL serves h2c on port" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try startServersOnce();
    try expectH2cSettings(threaded.io(), EPOLL_PORT);
}

test "zix integration: Http2 dual listener EPOLL serves h2 TLS on tls_port" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try startServersOnce();
    try expectH2TlsSettings(threaded.io(), EPOLL_TLS_PORT);
}

test "zix integration: Http2 dual listener URING serves h2c on port" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try startServersOnce();
    try expectH2cSettings(threaded.io(), URING_PORT);
}

test "zix integration: Http2 dual listener URING serves h2 TLS on-ring on tls_port" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();

    try startServersOnce();
    try expectH2TlsSettings(threaded.io(), URING_TLS_PORT);
}

test "zix integration: Http2 tls_port equal to port is rejected at run" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tls = try zix.Tls.Context.init(std.testing.allocator, io, .{
        .cert_path = CERT,
        .key_path = KEY,
        .alpn = &.{.H2},
    });
    defer tls.deinit();

    var server = zix.Http2.Server.init(&Routes, .{
        .io = io,
        .ip = IP,
        .port = 9224,
        .tls = &tls,
        .tls_port = 9224,
        .dispatch_model = .EPOLL,
    });
    defer server.deinit();

    try std.testing.expectError(error.TlsPortConflict, server.run());
}
