//! ZIX http2 tls serve
//!
//! ### file: src/zix/tcp/http2/tls_serve.zig
//!
//! ### author: Prana Ron
//!
//! ---------------------------------------------------------
//!
//! ### brief:
//!
//! h2 over TLS serve path for .ASYNC: an accept loop hands each connection to
//! its own task, which terminates TLS and drives the h2 mux inline.
//!
//! ### note:
//!
//! The handshake is the shared h2 terminator (TLS 1.3, or TLS 1.2 as a
//! fallback, ALPN h2 required). One task per connection, no socketpair.
//!
//! ---------------------------------------------------------
//!
//! ### licenses:
//!
//! - BSD-3-Clause
//!
//! ### copyright:
//!
//! - (c) Prana Ron // @prothegee // prothegee@pm.me
//!
//! ### contributors:
//!
//! - Prana Ron // @prothegee // prothegee@pm.me
//!

const std = @import("std");
const tlz = @import("tlz");
const Config = @import("Config.zig");
const handler = @import("handler.zig");
const log = @import("log.zig");
const h2_terminator = @import("../../tls/h2_terminator.zig");
const ConnCtx = @import("tls_serve/ConnCtx.zig");
const MuxDriver = @import("tls_serve/MuxDriver.zig");
const ServeOpts = @import("ServeOpts.zig");
const HandlerFn = handler.HandlerFn;

// --------------------------------------------------------- //
// Private:

/// Terminate TLS on fd and drive the h2 mux over it.
fn serveFd(
    fd: std.posix.fd_t,
    handler_fn: HandlerFn,
    ctx: *const tlz.Context,
    opts: ServeOpts,
    io: std.Io,
) h2_terminator.Error!void {
    const driver: MuxDriver = .{
        .handler = handler_fn,
        .opts = opts,
        .io = io,
    };

    return h2_terminator.serveConnTls(fd, ctx, io, driver);
}

/// One connection task: serve, then close. A failed handshake is logged at
/// DEBUG, not WARN, because a scanner on a public port would flood the log.
fn connWorker(conn_ctx: ConnCtx) void {
    handler.setAccessLogger(conn_ctx.opts.logger);

    defer conn_ctx.stream.close(conn_ctx.io);

    serveFd(
        conn_ctx.stream.socket.handle,
        conn_ctx.handler,
        conn_ctx.ctx,
        conn_ctx.opts,
        conn_ctx.io,
    ) catch |err| {
        const logger = conn_ctx.opts.logger orelse return;

        logger.system(.DEBUG, "http2", "tls connection ended: {s}", .{@errorName(err)});
    };
}

// --------------------------------------------------------- //
// Public:

/// ZIX Http2 TLS serve error
pub const Error = error {
    ZixHttp2_TlsServe_ResolveFailed,
    ZixHttp2_TlsServe_ListenFailed,
    ZixHttp2_TlsServe_AcceptFailed,
};

/// Listen and serve h2 over TLS, one task per connection.
///
/// Note:
/// - The cert, key, and policy are already loaded and checked in ctx, so the
///   accept loop does no per-connection PEM work.
/// - A peer that drops before accept (ConnectionAborted) is skipped.
///
/// Param:
/// config - Config (listen address, knobs)
/// handler_fn - HandlerFn
/// ctx - *const tlz.Context (borrowed, must outlive the server)
///
/// Return:
/// - void (never returns on success)
/// - Error.ZixHttp2_TlsServe_ResolveFailed or ListenFailed when the bind fails
/// - Error.ZixHttp2_TlsServe_AcceptFailed when accept fails for good
pub fn runTls(config: Config, handler_fn: HandlerFn, ctx: *const tlz.Context) Error!void {
    const io = config.io;
    const opts = config.serveOpts();
    const address = std.Io.net.IpAddress.resolve(io, config.ip, config.port) catch |err| {
        switch (err) {
            else => return Error.ZixHttp2_TlsServe_ResolveFailed,
        }
    };
    var server = address.listen(io, .{
        .mode = .stream,
        .reuse_address = true,
        .kernel_backlog = config.kernel_backlog,
    }) catch |err| switch (err) {
        else => return Error.ZixHttp2_TlsServe_ListenFailed,
    };
    defer server.deinit(io);

    log.logSystem(config, .INFO, "listening on {s}:{d} (h2 TLS)", .{
        config.ip,
        config.port,
    });

    while (true) {
        const stream = server.accept(io) catch |err| switch (err) {
            error.ConnectionAborted => continue,
            else => return Error.ZixHttp2_TlsServe_AcceptFailed,
        };
        const conn_ctx: ConnCtx = .{
            .stream = stream,
            .handler = handler_fn,
            .ctx = ctx,
            .io = io,
            .opts = opts,
        };

        _ = io.async(connWorker, .{conn_ctx});
    }
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //
// Test:

const frame = @import("frame.zig");
const pair = @import("../../utils/socket/pair.zig");
const router = @import("router.zig");
const HpackEncoder = @import("hpack/HpackEncoder.zig");
const Request = @import("Request.zig");
const Response = @import("Response.zig");
const Context = @import("Context.zig");

const CERT_PATH = "examples/certs/ecdsa_p256_cert.pem";
const KEY_PATH = "examples/certs/ecdsa_p256_key.pem";
const CONTENT_HANDSHAKE: u8 = @intFromEnum(tlz.ContentType.HANDSHAKE);
const CONTENT_APPLICATION_DATA: u8 = @intFromEnum(tlz.ContentType.APPLICATION_DATA);

fn okHandler(_: *Request, res: *Response, _: *Context) anyerror!void {
    try res.sendText("ok over tls");
}

const ok_router = router.Router(&[_]router.Route{
    .{
        .path = "/",
        .handler = okHandler,
    },
});

const TestServer = struct {
    fn run(fd: std.posix.fd_t, ctx: *const tlz.Context, result: *?h2_terminator.Error) void {
        serveFd(fd, ok_router.dispatch, ctx, .{
            .max_streams = 4,
        }, std.testing.io) catch |err| {
            result.* = err;
        };

        _ = std.posix.system.close(fd);
    }
};

fn testContext() !tlz.Context {
    return tlz.Context.init(std.testing.allocator, std.testing.io, .{
        .cert_path = CERT_PATH,
        .key_path = KEY_PATH,
        .alpn = &.{.H2},
    });
}

/// The preface, an empty SETTINGS, and one GET / on stream 1.
fn encodeRequest(plain: []u8) ![]const u8 {
    var len: usize = 0;
    @memcpy(plain[0..frame.PREFACE.len], frame.PREFACE);
    len += frame.PREFACE.len;

    frame.encodeFrameHeader(plain[len..][0..frame.FRAME_HEADER_LEN], .{
        .length = 0,
        .frame_type = frame.FRAME_TYPE_SETTINGS,
        .flags = 0,
        .stream_id = 0,
    });
    len += frame.FRAME_HEADER_LEN;

    var block: [64]u8 = undefined;
    var encoder = HpackEncoder.init(&block);
    try encoder.writeHeader(":method", "GET");
    try encoder.writeHeader(":path", "/");
    const head = encoder.encoded();

    frame.encodeFrameHeader(plain[len..][0..frame.FRAME_HEADER_LEN], .{
        .length = @intCast(head.len),
        .frame_type = frame.FRAME_TYPE_HEADERS,
        .flags = frame.FLAG_END_HEADERS | frame.FLAG_END_STREAM,
        .stream_id = 1,
    });
    len += frame.FRAME_HEADER_LEN;
    @memcpy(plain[len..][0..head.len], head);
    len += head.len;

    return plain[0..len];
}

test "zix http2: tls_serve, serves a GET over TLS 1.3 with ALPN h2" {
    var ctx = try testContext();
    defer ctx.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    var server_error: ?h2_terminator.Error = null;
    const thread = try std.Thread.spawn(.{}, TestServer.run, .{
        fds[1],
        &ctx,
        &server_error,
    });

    var hello_buf: [512]u8 = undefined;
    const started = try tlz.Client.start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
        .alpn = &.{.H2},
    }, &hello_buf);
    var state = started.state;

    var hello_rec: [600]u8 = undefined;
    hello_rec[0] = CONTENT_HANDSHAKE;
    std.mem.writeInt(u16, hello_rec[1..3], 0x0303, .big);
    std.mem.writeInt(u16, hello_rec[3..5], @intCast(started.client_hello.len), .big);
    @memcpy(hello_rec[5..][0..started.client_hello.len], started.client_hello);
    try h2_terminator.writeAll(fds[0], hello_rec[0 .. 5 + started.client_hello.len]);

    var flight_buf: [4096]u8 = undefined;
    var flight_len: usize = 0;
    for (0..3) |_| {
        const rec = try h2_terminator.readRecord(fds[0], flight_buf[flight_len..]);
        flight_len += rec.full.len;
    }

    var fin_buf: [256]u8 = undefined;
    var finished = try tlz.Client.finish(&state, flight_buf[0..flight_len], &fin_buf);
    try h2_terminator.writeAll(fds[0], finished.client_finished);

    var plain: [256]u8 = undefined;
    const request = try encodeRequest(&plain);
    var enc: [512]u8 = undefined;
    try h2_terminator.writeAll(fds[0], finished.connection.writeAppData(request, &enc));

    // Read records until the reply HEADERS for stream 1 shows up.
    var headers: usize = 0;
    var record_buf: [tlz.MAX_RECORD_WIRE]u8 = undefined;
    var dec: [tlz.MAX_PLAINTEXT + 256]u8 = undefined;
    while (headers == 0) {
        const rec = try h2_terminator.readRecord(fds[0], &record_buf);
        try std.testing.expectEqual(CONTENT_APPLICATION_DATA, rec.content_type);

        const got = try finished.connection.readAppData(rec.full, &dec);
        var off: usize = 0;
        while (off + frame.FRAME_HEADER_LEN <= got.len) {
            const header = frame.parseFrameHeader(got[off..][0..frame.FRAME_HEADER_LEN]);
            if (header.frame_type == frame.FRAME_TYPE_HEADERS) headers += 1;

            off += frame.FRAME_HEADER_LEN + header.length;
        }
    }

    _ = std.posix.system.close(fds[0]);
    fds[0] = -1;
    thread.join();

    try std.testing.expectEqual(tlz.Alpn.H2, finished.alpn.?);
    try std.testing.expectEqual(@as(usize, 1), headers);
    try std.testing.expect(server_error == null);
}

test "zix http2: tls_serve, a client without ALPN h2 is refused" {
    var ctx = try testContext();
    defer ctx.deinit();

    var fds: [2]std.posix.fd_t = undefined;
    try pair.open(std.testing.io, &fds);
    defer _ = std.posix.system.close(fds[0]);

    var server_error: ?h2_terminator.Error = null;
    const thread = try std.Thread.spawn(.{}, TestServer.run, .{
        fds[1],
        &ctx,
        &server_error,
    });

    var hello_buf: [512]u8 = undefined;
    const started = try tlz.Client.start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
    }, &hello_buf);

    var hello_rec: [600]u8 = undefined;
    hello_rec[0] = CONTENT_HANDSHAKE;
    std.mem.writeInt(u16, hello_rec[1..3], 0x0303, .big);
    std.mem.writeInt(u16, hello_rec[3..5], @intCast(started.client_hello.len), .big);
    @memcpy(hello_rec[5..][0..started.client_hello.len], started.client_hello);
    try h2_terminator.writeAll(fds[0], hello_rec[0 .. 5 + started.client_hello.len]);

    thread.join();

    try std.testing.expectEqual(error.ZixTls_H2Terminator_AlpnNotH2, server_error.?);
}

test "zix http2: tls_serve, runTls with an unresolvable ip is ResolveFailed" {
    var ctx: tlz.Context = undefined;
    const config: Config = .{
        .io = std.testing.io,
        .ip = "not-an-ip",
        .port = 9443,
        .dispatch_model = .ASYNC,
    };

    try std.testing.expectError(
        Error.ZixHttp2_TlsServe_ResolveFailed,
        runTls(config, ok_router.dispatch, &ctx),
    );
}

