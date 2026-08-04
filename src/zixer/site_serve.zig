//! zixer site serve loop: accept thread for one started proxy site

const std = @import("std");

const http1_proxy = @import("http1_proxy.zig");
const site_cfg = @import("site_cfg.zig");
const upstream_conn = @import("upstream_conn.zig");
const upstream_pool = @import("upstream_pool.zig");

/// Consecutive accept failures before the loop gives up.
const MAX_ACCEPT_FAILURES: usize = 100;

/// Everything one serving site owns. Heap-allocated so the accept thread and
/// its connection tasks keep stable pointers while the daemon registry moves.
pub const ServeState = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: std.Io.net.Server,
    pool: upstream_pool.Pool,
    idle: upstream_conn.IdleCache,
    stop: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    wake_ip: []const u8,
    port: u16,

    /// Build the serve state and start its accept thread.
    ///
    /// Note:
    /// - server is moved in here: the caller hands the bound listener over
    ///   and must not touch it again, shutdown() closes it.
    ///
    /// Param:
    /// allocator - std.mem.Allocator (state, pool, and idle cache, long-lived)
    /// io - std.Io (must outlive the state)
    /// server - std.Io.net.Server (bound tcp listener for this site)
    /// upstreams - []const site_cfg.Upstream (validated, host strings are duped)
    /// ip - []const u8 (the cfg listen ip, duped for the stop wake)
    /// port - u16
    ///
    /// Return:
    /// - *ServeState with the accept thread running
    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        server: std.Io.net.Server,
        upstreams: []const site_cfg.Upstream,
        ip: []const u8,
        port: u16,
    ) !*ServeState {
        const state = try allocator.create(ServeState);
        errdefer allocator.destroy(state);

        var pool = try upstream_pool.Pool.init(allocator, upstreams, upstream_pool.DEFAULT_COOLDOWN_MS);
        errdefer pool.deinit(allocator);
        var idle = try upstream_conn.IdleCache.init(allocator, upstreams.len);
        errdefer idle.deinit(allocator, io);
        const wake_ip = try allocator.dupe(u8, ip);
        errdefer allocator.free(wake_ip);

        state.* = .{
            .allocator = allocator,
            .io = io,
            .server = server,
            .pool = pool,
            .idle = idle,
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
        state.idle.deinit(state.allocator, io);
        state.pool.deinit(state.allocator);
        state.allocator.free(state.wake_ip);

        const allocator = state.allocator;
        allocator.destroy(state);
    }
};

fn acceptLoop(state: *ServeState) void {
    const io = state.io;
    const proxy = http1_proxy.Proxy{ .io = io, .pool = &state.pool, .idle = &state.idle };

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

    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 39870);
    const server = try addr.listen(io, .{ .kernel_backlog = 64 });

    const state = try ServeState.create(std.testing.allocator, io, server, &upstreams, "127.0.0.1", 39870);
    state.shutdown();

    // The port is free again: a fresh bind succeeds.
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
