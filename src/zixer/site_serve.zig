//! zixer site serve loop: accept thread for one started proxy site

const std = @import("std");
const zix = @import("zix");

const acme_challenge = @import("acme_challenge.zig");
const http1_proxy = @import("http1_proxy.zig");
const http2_edge = @import("http2_edge.zig");
const site_cfg = @import("site_cfg.zig");
const static_files = @import("static_files.zig");
const tls_edge = @import("tls_edge.zig");
const upstream_conn = @import("upstream_conn.zig");
const upstream_pool = @import("upstream_pool.zig");

/// Consecutive accept failures before the loop gives up.
const MAX_ACCEPT_FAILURES: usize = 100;

/// Everything one serving site owns. Heap-allocated so the accept thread and
/// its connection tasks keep stable pointers while the daemon registry moves.
///
/// Note:
/// - pool and idle exist only when the site has upstreams. A static-only
///   site serves public_dir alone and leaves both null.
/// - tls_ctx exists only when the site terminates TLS: built from the cfg
///   cert / key paths at create, so a restart re-reads renewed cert files
///   (the certbot deploy-hook path).
pub const ServeState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    engine: site_cfg.Engine,
    server: std.Io.net.Server,
    pool: ?upstream_pool.Pool,
    idle: ?upstream_conn.IdleCache,
    public_dir: ?[]const u8,
    public_prefix: ?[]const u8,
    spa_fallback: ?[]const u8,
    tls_ctx: ?zix.Tls.Context,
    acme_webroot: ?[]const u8,
    acme_relay: ?site_cfg.Upstream,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    /// Live connection tasks. A concurrent group member releases its
    /// resources when the task returns, shutdown cancels the stragglers
    /// before the pool and strings are freed.
    conns: std.Io.Group = .init,
    wake_ip: []const u8,
    port: u16,

    /// Build the serve state and start its accept thread.
    ///
    /// Note:
    /// - server is moved in here: the caller hands the bound listener over
    ///   and must not touch it again, shutdown() closes it.
    /// - Every string taken from cfg is duped, the caller's arena may go.
    ///
    /// Param:
    /// allocator - std.mem.Allocator (state, pool, and idle cache, long-lived)
    /// io - std.Io (must outlive the state)
    /// server - std.Io.net.Server (bound tcp listener for this site)
    /// cfg - *const site_cfg.SiteCfg (validated site config)
    /// port - u16
    ///
    /// Return:
    /// - *ServeState with the accept thread running
    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        server: std.Io.net.Server,
        cfg: *const site_cfg.SiteCfg,
        port: u16,
    ) !*ServeState {
        const state = try allocator.create(ServeState);
        errdefer allocator.destroy(state);

        var pool: ?upstream_pool.Pool = null;
        errdefer if (pool) |*inner| inner.deinit(allocator);
        var idle: ?upstream_conn.IdleCache = null;
        errdefer if (idle) |*inner| inner.deinit(allocator, io);
        if (cfg.upstreams.len > 0) {
            pool = try upstream_pool.Pool.init(allocator, cfg.upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
            idle = try upstream_conn.IdleCache.init(allocator, cfg.upstreams.len);
        }

        const wake_ip = try allocator.dupe(u8, cfg.ip);
        errdefer allocator.free(wake_ip);
        const public_dir = try dupeOptional(allocator, cfg.public_dir);
        errdefer freeOptional(allocator, public_dir);
        const public_prefix = try dupeOptional(allocator, cfg.public_prefix);
        errdefer freeOptional(allocator, public_prefix);
        const spa_fallback = try dupeOptional(allocator, cfg.spa_fallback);
        errdefer freeOptional(allocator, spa_fallback);
        const acme_webroot = try dupeOptional(allocator, cfg.acme_webroot);
        errdefer freeOptional(allocator, acme_webroot);
        var acme_relay = cfg.acme_proxy;
        if (cfg.acme_proxy) |relay| acme_relay.?.host = try allocator.dupe(u8, relay.host);
        errdefer if (acme_relay) |relay| allocator.free(relay.host);

        // Validation guarantees cert and key paths exist when tls is on.
        // Loading here (not at validate) keeps restart the cert reload path.
        var tls_ctx: ?zix.Tls.Context = null;
        errdefer if (tls_ctx) |*ctx| ctx.deinit();
        const engine = cfg.engine orelse .HTTP1;
        if (cfg.tls) {
            tls_ctx = try tls_edge.buildContext(allocator, io, cfg.tls_cert.?, cfg.tls_key.?, tls_edge.alpnPrefs(engine));
        }

        state.* = .{
            .allocator = allocator,
            .io = io,
            .engine = engine,
            .server = server,
            .pool = pool,
            .idle = idle,
            .public_dir = public_dir,
            .public_prefix = public_prefix,
            .spa_fallback = spa_fallback,
            .tls_ctx = tls_ctx,
            .acme_webroot = acme_webroot,
            .acme_relay = acme_relay,
            .wake_ip = wake_ip,
            .port = port,
        };

        state.thread = try std.Thread.spawn(.{}, acceptLoop, .{state});

        return state;
    }

    /// Stop the accept thread, close the listener, release everything.
    ///
    /// Note:
    /// - The wake connection is what unblocks the accept call portably:
    ///   closing a socket another thread is blocked on is not reliable
    ///   cross-platform, a loopback connect always is.
    /// - Connections already being served finish on their own tasks.
    pub fn shutdown(state: *ServeState) void {
        const io = state.io;

        state.stop.store(true, .release);
        wake(io, state.wake_ip, state.port);
        if (state.thread) |thread| thread.join();
        state.conns.cancel(io);

        state.server.deinit(io);
        if (state.idle) |*idle| idle.deinit(state.allocator, io);
        if (state.pool) |*pool| pool.deinit(state.allocator);
        if (state.tls_ctx) |*ctx| ctx.deinit();
        state.allocator.free(state.wake_ip);
        freeOptional(state.allocator, state.public_dir);
        freeOptional(state.allocator, state.public_prefix);
        freeOptional(state.allocator, state.spa_fallback);
        freeOptional(state.allocator, state.acme_webroot);
        if (state.acme_relay) |relay| state.allocator.free(relay.host);

        const allocator = state.allocator;
        allocator.destroy(state);
    }
};

/// Dupe a string that may be absent.
fn dupeOptional(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    const inner = value orelse return null;

    return try allocator.dupe(u8, inner);
}

fn freeOptional(allocator: std.mem.Allocator, value: ?[]const u8) void {
    if (value) |inner| allocator.free(inner);
}

fn acceptLoop(state: *ServeState) void {
    const io = state.io;

    const pool: ?*upstream_pool.Pool = if (state.pool) |*inner| inner else null;
    const idle: ?*upstream_conn.IdleCache = if (state.idle) |*inner| inner else null;
    const static_site: ?static_files.StaticSite = if (state.public_dir) |dir| .{
        .public_dir = dir,
        .public_prefix = state.public_prefix,
        .spa_fallback = state.spa_fallback,
    } else null;
    const acme: ?acme_challenge.AcmeSite = if (state.acme_webroot != null or state.acme_relay != null)
        .{ .webroot = state.acme_webroot, .relay = state.acme_relay }
    else
        null;
    const tls_ctx: ?*const zix.Tls.Context = if (state.tls_ctx) |*ctx| ctx else null;
    const proxy = http1_proxy.Proxy{
        .io = io,
        .pool = pool,
        .idle = idle,
        .static = static_site,
        .acme = acme,
        .tls_cert_der = if (tls_ctx) |ctx| ctx.cert_der else null,
    };

    var accept_failures: usize = 0;
    while (!state.stop.load(.acquire)) {
        const stream = state.server.accept(io) catch {
            if (state.stop.load(.acquire)) return;

            accept_failures += 1;
            if (accept_failures >= MAX_ACCEPT_FAILURES) return;
            continue;
        };
        accept_failures = 0;

        if (state.stop.load(.acquire)) {
            stream.close(io);
            return;
        }

        const task = ConnTask{ .proxy = proxy, .stream = stream, .tls_ctx = tls_ctx, .engine = state.engine };
        state.conns.concurrent(io, serveTask, .{task}) catch serveTask(task);
    }
}

const ConnTask = struct {
    proxy: http1_proxy.Proxy,
    stream: std.Io.net.Stream,
    tls_ctx: ?*const zix.Tls.Context,
    engine: site_cfg.Engine,
};

fn serveTask(task: ConnTask) void {
    if (task.tls_ctx) |ctx| {
        tls_edge.serveConn(&task.proxy, ctx, task.stream, task.engine);
        return;
    }

    // A cleartext http2 site sniffs the preface and falls back to the h1
    // loop for anything else (rfc 9113 3.3 prior knowledge).
    if (task.engine == .HTTP2) {
        http2_edge.serveConn(&task.proxy, task.stream);
        return;
    }

    http1_proxy.serveConn(&task.proxy, task.stream);
}

/// Connect-and-close against the site's own port so a blocked accept returns.
/// A wildcard listen ip is reached through loopback.
fn wake(io: std.Io, ip: []const u8, port: u16) void {
    const target = if (std.mem.eql(u8, ip, "0.0.0.0"))
        "127.0.0.1"
    else if (std.mem.eql(u8, ip, "::"))
        "::1"
    else
        ip;

    // No connect timeout: the std.Io.Threaded backend panics on one (TODO in
    // std), and a loopback connect to an owned port returns immediately.
    const addr = std.Io.net.IpAddress.parse(target, port) catch return;
    const stream = addr.connect(io, .{ .mode = .stream, .protocol = .tcp }) catch return;
    stream.close(io);
}

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix zixer: site serve, create binds a thread and shutdown frees the port" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const upstreams = [_]site_cfg.Upstream{.{ .host = "127.0.0.1", .port = 39869 }};
    const cfg = site_cfg.SiteCfg{ .engine = .HTTP1, .ip = "127.0.0.1", .port = 39870, .upstreams = &upstreams };

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 39870);
    const server = try addr.listen(io, .{ .kernel_backlog = 64 });

    const state = try ServeState.create(std.testing.allocator, io, server, &cfg, 39870);
    state.shutdown();

    // The port is free again: a fresh bind succeeds.
    var rebound = try addr.listen(io, .{ .kernel_backlog = 64 });
    rebound.deinit(io);
}

test "zix zixer: site serve, static-only site runs without a pool" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg = site_cfg.SiteCfg{
        .engine = .HTTP1,
        .ip = "127.0.0.1",
        .port = 39881,
        .public_dir = "/var/www/static-test",
        .spa_fallback = "index.html",
    };

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 39881);
    const server = try addr.listen(io, .{ .kernel_backlog = 64 });

    const state = try ServeState.create(std.testing.allocator, io, server, &cfg, 39881);
    try std.testing.expect(state.pool == null);
    try std.testing.expect(state.idle == null);
    try std.testing.expectEqualStrings("/var/www/static-test", state.public_dir.?);
    state.shutdown();

    var rebound = try addr.listen(io, .{ .kernel_backlog = 64 });
    rebound.deinit(io);
}

test "zix zixer: site serve, wake tolerates a dead port" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    wake(io, "0.0.0.0", 39871);
    wake(io, "not an ip", 39871);
}

test "zix zixer: site serve, tls site create refuses a missing cert file" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const cfg = site_cfg.SiteCfg{
        .engine = .HTTP1,
        .ip = "127.0.0.1",
        .port = 39895,
        .tls = true,
        .tls_cert = "examples/certs/absent.pem",
        .tls_key = "examples/certs/ecdsa_p256_key.pem",
        .public_dir = "/var/www/static-test",
    };

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 39895);
    var server = try addr.listen(io, .{ .kernel_backlog = 8 });

    try std.testing.expectError(error.TlsCertFileNotFound, ServeState.create(std.testing.allocator, io, server, &cfg, 39895));
    server.deinit(io);
}

test "zix zixer: site serve, tls site terminates and serves the static plane" {
    if (comptime @import("builtin").os.tag != .linux) return error.SkipZigTest;

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    tmp.dir.writeFile(std.testing.io, .{ .sub_path = "index.html", .data = "tls-static" }) catch @panic("fixture write failed");

    var root_buf: [128]u8 = undefined;
    const root = std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    const cfg = site_cfg.SiteCfg{
        .engine = .HTTP1,
        .ip = "127.0.0.1",
        .port = 39894,
        .tls = true,
        .tls_cert = "examples/certs/ecdsa_p256_cert.pem",
        .tls_key = "examples/certs/ecdsa_p256_key.pem",
        .public_dir = root,
    };

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 39894);
    const server = try addr.listen(io, .{ .kernel_backlog = 8, .reuse_address = true });

    const state = try ServeState.create(std.testing.allocator, io, server, &cfg, 39894);
    try std.testing.expect(state.tls_ctx != null);

    // manual TLS 1.3 client over the real socket: hello record, read the
    // three-record server flight, finish, then one https request.
    const stream = try addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    var read_buf: [8 * 1024]u8 = undefined;
    var write_buf: [8 * 1024]u8 = undefined;
    var client_reader = stream.reader(io, &read_buf);
    var client_writer = stream.writer(io, &write_buf);

    var hello_buf: [512]u8 = undefined;
    const started = try zix.Tls.Client.start(.{
        .client_random = @splat(0x11),
        .ephemeral_secret = @splat(0x42),
        .alpn = &.{.HTTP_1_1},
    }, &hello_buf);
    var client_state = started.state;

    var hello_rec: [600]u8 = undefined;
    hello_rec[0] = 22;
    std.mem.writeInt(u16, hello_rec[1..3], 0x0303, .big);
    std.mem.writeInt(u16, hello_rec[3..5], @intCast(started.client_hello.len), .big);
    @memcpy(hello_rec[5 .. 5 + started.client_hello.len], started.client_hello);
    try client_writer.interface.writeAll(hello_rec[0 .. 5 + started.client_hello.len]);
    try client_writer.interface.flush();

    var flight_buf: [8 * 1024]u8 = undefined;
    var flight_len: usize = 0;
    for (0..3) |_| {
        try client_reader.interface.readSliceAll(flight_buf[flight_len..][0..5]);
        const body_len = std.mem.readInt(u16, flight_buf[flight_len + 3 ..][0..2], .big);
        try client_reader.interface.readSliceAll(flight_buf[flight_len + 5 ..][0..body_len]);
        flight_len += 5 + body_len;
    }

    var finish_buf: [256]u8 = undefined;
    const finished = try zix.Tls.Client.finish(&client_state, flight_buf[0..flight_len], &finish_buf);
    var client_conn = finished.connection;
    try client_writer.interface.writeAll(finished.client_finished);
    try client_writer.interface.flush();

    var request_out: [256]u8 = undefined;
    const request_rec = client_conn.writeAppData("GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", &request_out);
    try client_writer.interface.writeAll(request_rec);
    try client_writer.interface.flush();

    // collect the sealed response records until the server closes, then
    // decrypt them in order.
    var reply: [2048]u8 = undefined;
    var reply_len: usize = 0;
    var wire: [4096]u8 = undefined;
    collect: while (true) {
        client_reader.interface.readSliceAll(wire[0..5]) catch break :collect;
        const body_len = std.mem.readInt(u16, wire[3..5], .big);
        client_reader.interface.readSliceAll(wire[5..][0..body_len]) catch break :collect;

        var plain: [2048]u8 = undefined;
        const piece = client_conn.readAppData(wire[0 .. 5 + body_len], &plain) catch break :collect;
        @memcpy(reply[reply_len..][0..piece.len], piece);
        reply_len += piece.len;
    }
    stream.close(io);

    const response = reply[0..reply_len];
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.indexOf(u8, response, "Connection: close\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, response, "tls-static"));

    state.shutdown();

    var rebound = try addr.listen(io, .{ .kernel_backlog = 8, .reuse_address = true });
    rebound.deinit(io);
}
