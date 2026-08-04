//! zixer site serve loop: accept thread for one started proxy site

const std = @import("std");

const http1_proxy = @import("http1_proxy.zig");
const site_cfg = @import("site_cfg.zig");
const static_files = @import("static_files.zig");
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
pub const ServeState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    pool: ?upstream_pool.Pool,
    idle: ?upstream_conn.IdleCache,
    public_dir: ?[]const u8,
    public_prefix: ?[]const u8,
    spa_fallback: ?[]const u8,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
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

        state.* = .{
            .allocator = allocator,
            .io = io,
            .server = server,
            .pool = pool,
            .idle = idle,
            .public_dir = public_dir,
            .public_prefix = public_prefix,
            .spa_fallback = spa_fallback,
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

        state.server.deinit(io);
        if (state.idle) |*idle| idle.deinit(state.allocator, io);
        if (state.pool) |*pool| pool.deinit(state.allocator);
        state.allocator.free(state.wake_ip);
        freeOptional(state.allocator, state.public_dir);
        freeOptional(state.allocator, state.public_prefix);
        freeOptional(state.allocator, state.spa_fallback);

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
    const proxy = http1_proxy.Proxy{ .io = io, .pool = pool, .idle = idle, .static = static_site };

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

        const task = ConnTask{ .proxy = proxy, .stream = stream };
        if (io.concurrent(serveTask, .{task})) |_| {} else |_| {
            serveTask(task);
        }
    }
}

const ConnTask = struct {
    proxy: http1_proxy.Proxy,
    stream: std.Io.net.Stream,
};

fn serveTask(task: ConnTask) void {
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
