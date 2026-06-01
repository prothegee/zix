//! zix fix server — POOL, ASYNC, MIXED, and EPOLL (Linux-only) dispatch for FIX 4.x.

const std = @import("std");
const core = @import("core.zig");
const FixServerConfig = @import("config.zig").FixServerConfig;
const DispatchModel = @import("../config.zig").DispatchModel;
const FixServeOpts = core.FixServeOpts;
const Logger = @import("../../logger/logger.zig").Logger;

// --------------------------------------------------------- //

const ConnTask = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    comp_id: []const u8,
    opts: FixServeOpts,
};

fn dispatchConn(task: ConnTask) void {
    core.serveConn(task.stream, task.io, task.comp_id, task.opts) catch {};
}

// --------------------------------------------------------- //

const ConnQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    items: std.ArrayListUnmanaged(std.Io.net.Stream) = .empty,
    closed: bool = false,

    fn push(self: *ConnQueue, stream: std.Io.net.Stream, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.items.append(std.heap.smp_allocator, stream) catch {
            self.mutex.unlock(io);
            stream.close(io);
            return;
        };
        self.mutex.unlock(io);
        self.ready.signal(io);
    }

    fn pop(self: *ConnQueue, io: std.Io) ?std.Io.net.Stream {
        self.mutex.lockUncancelable(io);
        while (self.items.items.len == 0) {
            if (self.closed) {
                self.mutex.unlock(io);
                return null;
            }
            self.ready.waitUncancelable(io, &self.mutex);
        }
        const stream = self.items.orderedRemove(0);
        self.mutex.unlock(io);
        return stream;
    }

    fn close(self: *ConnQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.mutex.unlock(io);
        self.ready.broadcast(io);
    }

    fn deinit(self: *ConnQueue) void {
        self.items.deinit(std.heap.smp_allocator);
    }
};

// --------------------------------------------------------- //

const FdQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    buf: []std.posix.fd_t = &.{},
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,

    fn push(self: *FdQueue, fd: std.posix.fd_t, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        if (self.len == self.buf.len) {
            const new_cap = if (self.buf.len == 0) 16 else self.buf.len * 2;
            const new_buf = std.heap.smp_allocator.alloc(std.posix.fd_t, new_cap) catch {
                self.mutex.unlock(io);
                _ = std.os.linux.close(fd);
                return;
            };
            if (self.buf.len > 0) {
                for (0..self.len) |i| new_buf[i] = self.buf[(self.head + i) % self.buf.len];
                std.heap.smp_allocator.free(self.buf);
            }
            self.buf = new_buf;
            self.head = 0;
        }
        self.buf[(self.head + self.len) % self.buf.len] = fd;
        self.len += 1;
        self.mutex.unlock(io);
        self.ready.signal(io);
    }

    fn pop(self: *FdQueue, io: std.Io) ?std.posix.fd_t {
        self.mutex.lockUncancelable(io);
        while (self.len == 0) {
            if (self.closed) {
                self.mutex.unlock(io);
                return null;
            }
            self.ready.waitUncancelable(io, &self.mutex);
        }
        const fd = self.buf[self.head];
        self.head = (self.head + 1) % self.buf.len;
        self.len -= 1;
        self.mutex.unlock(io);
        return fd;
    }

    fn close(self: *FdQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.mutex.unlock(io);
        self.ready.broadcast(io);
    }

    fn deinit(self: *FdQueue) void {
        if (self.buf.len > 0) std.heap.smp_allocator.free(self.buf);
    }
};

// --------------------------------------------------------- //

const WorkerCtx = struct {
    queue: *ConnQueue,
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    opts: FixServeOpts,
};

fn workerEntry(ctx: WorkerCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch |err| {
        if (ctx.opts.logger) |lg| lg.system(.ERROR, "fix", "resolve error: {}", .{err});
        return;
    };
    var listener = addr.listen(ctx.io, .{
        .reuse_address = true,
        .kernel_backlog = ctx.kernel_backlog,
    }) catch |err| {
        if (ctx.opts.logger) |lg| lg.system(.ERROR, "fix", "listen error: {}", .{err});
        return;
    };
    defer listener.deinit(ctx.io);

    while (true) {
        const stream = listener.accept(ctx.io) catch |err| {
            if (err != error.ConnectionAborted) {
                if (ctx.opts.logger) |lg| lg.system(.WARN, "fix", "accept error: {}", .{err});
                break;
            }
            continue;
        };
        ctx.queue.push(stream, ctx.io);
    }
}

const PoolCtx = struct {
    queue: *ConnQueue,
    io: std.Io,
    comp_id: []const u8,
    opts: FixServeOpts,
};

fn poolEntry(ctx: PoolCtx) void {
    while (ctx.queue.pop(ctx.io)) |stream| {
        dispatchConn(.{ .stream = stream, .io = ctx.io, .comp_id = ctx.comp_id, .opts = ctx.opts });
    }
}

const AsyncWorkerCtx = struct {
    io: std.Io,
    ip: []const u8,
    port: u16,
    kernel_backlog: u31,
    comp_id: []const u8,
    opts: FixServeOpts,
};

fn asyncWorkerEntry(ctx: AsyncWorkerCtx) void {
    const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
    var listener = addr.listen(ctx.io, .{
        .reuse_address = true,
        .kernel_backlog = ctx.kernel_backlog,
    }) catch return;
    defer listener.deinit(ctx.io);

    while (true) {
        const stream = listener.accept(ctx.io) catch |err| {
            if (err != error.ConnectionAborted) break;
            continue;
        };
        _ = ctx.io.async(dispatchConn, .{ConnTask{
            .stream = stream,
            .io = ctx.io,
            .comp_id = ctx.comp_id,
            .opts = ctx.opts,
        }});
    }
}

const EpollWorkerCtx = struct {
    queue: *FdQueue,
    io: std.Io,
    comp_id: []const u8,
    opts: FixServeOpts,
};

fn epollWorkerEntry(ctx: EpollWorkerCtx) void {
    while (ctx.queue.pop(ctx.io)) |conn_fd| {
        const stream: std.Io.net.Stream = .{ .socket = .{
            .handle = conn_fd,
            .address = .{ .ip4 = .unspecified(0) },
        } };
        core.serveConn(stream, ctx.io, ctx.comp_id, ctx.opts) catch {};
    }
}

// --------------------------------------------------------- //

/// FIX 4.x session server. Dispatches connections via POOL, ASYNC, MIXED,
/// or EPOLL (Linux-only: non-Linux falls back to POOL).
/// Session messages (Logon, Logout, Heartbeat, TestRequest) are handled internally.
/// Application messages are dispatched to registered routes.
///
/// Usage:
/// ```zig
/// var server = try FixServer.init(
///     &[_]FixRoute{
///         .{ .msg_type = "D", .handler = handleOrder },
///         .{ .msg_type = "F", .handler = handleCancel },
///     },
///     .{ .io = io, .ip = "0.0.0.0", .port = 9500, .comp_id = "SRV" },
/// );
/// defer server.deinit();
/// try server.run();
/// ```
pub const FixServer = struct {
    const Self = @This();

    routes: []const core.FixRoute,
    config: FixServerConfig,

    // --------------------------------------------------------- //

    /// Initialize.
    ///
    /// Param:
    /// routes - []const FixRoute (application message route table. pass &.{} for echo-only mode)
    /// config - FixServerConfig
    ///
    /// Return:
    /// - !Self
    /// - error.PortNotConfigured if config.port is 0
    pub fn init(routes: []const core.FixRoute, config: FixServerConfig) !Self {
        if (config.port == 0) return error.PortNotConfigured;
        return .{ .routes = routes, .config = config };
    }

    /// No-op — resources released inside run via defer.
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Listen and serve FIX sessions using the server's comp_id.
    pub fn run(self: *Self) !void {
        const cfg = self.config;
        const io = cfg.io;
        const cpu = try std.Thread.getCpuCount();
        const conn_opts = FixServeOpts{
            .logger = cfg.logger,
            .heartbeat_timeout_ms = cfg.heartbeat_timeout_ms,
            .connection_timeout_ms = cfg.connection_timeout_ms,
            .handler_timeout_ms = cfg.handler_timeout_ms,
            .routes = self.routes,
        };

        switch (cfg.dispatch_model) {
            .ASYNC => {
                if (cfg.logger) |lg| lg.system(.INFO, "fix", "listening on {s}:{d} (async)", .{ cfg.ip, cfg.port });

                const addr = try std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port);
                var listener = try addr.listen(io, .{
                    .reuse_address = true,
                    .kernel_backlog = cfg.kernel_backlog,
                });
                defer listener.deinit(io);

                while (true) {
                    const stream = listener.accept(io) catch |err| {
                        if (err != error.ConnectionAborted) break;
                        continue;
                    };
                    _ = io.async(dispatchConn, .{ConnTask{
                        .stream = stream,
                        .io = io,
                        .comp_id = cfg.comp_id,
                        .opts = conn_opts,
                    }});
                }
            },

            .POOL => {
                const worker_count = if (cfg.workers == 0) cpu else cfg.workers;
                const pool_count = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

                if (cfg.logger) |lg| lg.system(.INFO, "fix", "listening on {s}:{d} (pool/{d}x{d})", .{ cfg.ip, cfg.port, worker_count, pool_count });

                var queue = ConnQueue{};
                defer queue.deinit();

                const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_count);
                defer std.heap.smp_allocator.free(pool_threads);
                for (pool_threads) |*t|
                    t.* = try std.Thread.spawn(
                        .{ .stack_size = 256 * 1024 },
                        poolEntry,
                        .{PoolCtx{ .queue = &queue, .io = io, .comp_id = cfg.comp_id, .opts = conn_opts }},
                    );

                const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
                defer std.heap.smp_allocator.free(acc_threads);
                for (acc_threads) |*t|
                    t.* = try std.Thread.spawn(
                        .{ .stack_size = 256 * 1024 },
                        workerEntry,
                        .{WorkerCtx{
                            .queue = &queue,
                            .io = io,
                            .ip = cfg.ip,
                            .port = cfg.port,
                            .kernel_backlog = cfg.kernel_backlog,
                            .opts = conn_opts,
                        }},
                    );

                for (acc_threads) |t| t.join();
                queue.close(io);
                for (pool_threads) |t| t.join();
            },

            .MIXED => {
                const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

                if (cfg.logger) |lg| lg.system(.INFO, "fix", "listening on {s}:{d} (mixed/{d})", .{ cfg.ip, cfg.port, worker_count });

                const acc_threads = try std.heap.smp_allocator.alloc(std.Thread, worker_count);
                defer std.heap.smp_allocator.free(acc_threads);
                for (acc_threads) |*t|
                    t.* = try std.Thread.spawn(
                        .{},
                        asyncWorkerEntry,
                        .{AsyncWorkerCtx{
                            .io = io,
                            .ip = cfg.ip,
                            .port = cfg.port,
                            .kernel_backlog = cfg.kernel_backlog,
                            .comp_id = cfg.comp_id,
                            .opts = conn_opts,
                        }},
                    );

                for (acc_threads) |t| t.join();
            },

            .EPOLL => {
                if (comptime @import("builtin").target.os.tag == .linux) {
                    try self.runEpoll(io, conn_opts, cpu);
                } else {
                    std.debug.print("zix fix server: EPOLL is Linux-only. Falling back to POOL.\n", .{});
                    var fallback = self.*;
                    fallback.config.dispatch_model = .POOL;
                    try fallback.run();
                }
            },
        }
    }

    /// EPOLL dispatch: a single epoll event loop accepts connections and hands
    /// each fd to a worker pool. Each worker runs the full FIX session loop.
    /// Linux-only.
    ///
    /// Note:
    /// - Workers hold each connection for its full lifetime (FIX sessions are
    ///   stateful: seq_num, Logon state, heartbeat timer all live on the stack
    ///   inside serveConn). EPOLLONESHOT is not used.
    /// - The benefit over POOL is single-threaded accept vs N accept threads.
    /// - pool_size sets the worker count (0 = max(10, cpu * 2)).
    fn runEpoll(self: *Self, io: std.Io, conn_opts: FixServeOpts, cpu: usize) !void {
        const linux = std.os.linux;
        const cfg = self.config;
        const pool_count = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

        const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
            if (cfg.logger) |lg| lg.system(.ERROR, "fix", "epoll resolve error: {}", .{err});
            return err;
        };
        var net_server = addr.listen(io, .{
            .reuse_address = true,
            .kernel_backlog = cfg.kernel_backlog,
        }) catch |err| {
            if (cfg.logger) |lg| lg.system(.ERROR, "fix", "epoll listen error: {}", .{err});
            return err;
        };
        defer net_server.deinit(io);
        const listener_fd = net_server.socket.handle;

        const cur_flags = linux.fcntl(listener_fd, std.posix.F.GETFL, 0);
        const nonblock_bit: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
        _ = linux.fcntl(listener_fd, std.posix.F.SETFL, cur_flags | @as(usize, nonblock_bit));

        const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (std.posix.errno(epfd_rc) != .SUCCESS) return error.EpollCreateFailed;
        const epfd: std.posix.fd_t = @intCast(epfd_rc);
        defer _ = linux.close(epfd);

        var listener_event = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ET,
            .data = .{ .fd = listener_fd },
        };
        if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listener_fd, &listener_event)) != .SUCCESS)
            return error.EpollCtlFailed;

        if (cfg.logger) |lg| lg.system(.INFO, "fix", "listening on {s}:{d} (epoll/{d})", .{ cfg.ip, cfg.port, pool_count });

        var queue = FdQueue{};
        defer queue.deinit();

        const workers = try std.heap.smp_allocator.alloc(std.Thread, pool_count);
        defer std.heap.smp_allocator.free(workers);
        for (workers) |*t|
            t.* = try std.Thread.spawn(
                .{ .stack_size = 512 * 1024 },
                epollWorkerEntry,
                .{EpollWorkerCtx{ .queue = &queue, .io = io, .comp_id = cfg.comp_id, .opts = conn_opts }},
            );

        const max_events = 256;
        var events: [max_events]linux.epoll_event = undefined;
        while (true) {
            const wait_result = linux.epoll_wait(epfd, &events, max_events, -1);
            switch (std.posix.errno(wait_result)) {
                .SUCCESS => {},
                .INTR => continue,
                else => break,
            }
            const n: usize = @intCast(wait_result);
            for (events[0..n]) |ev| {
                if (ev.data.fd != listener_fd) continue;
                while (true) {
                    const accept_result = linux.accept4(listener_fd, null, null, std.posix.SOCK.CLOEXEC);
                    switch (std.posix.errno(accept_result)) {
                        .SUCCESS => {},
                        .AGAIN => break,
                        .INTR, .CONNABORTED => continue,
                        else => break,
                    }
                    const conn_fd: std.posix.fd_t = @intCast(accept_result);
                    queue.push(conn_fd, io);
                }
            }
        }

        queue.close(io);
        for (workers) |t| t.join();
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix fix: FixServer.init, port zero returns PortNotConfigured" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(
        error.PortNotConfigured,
        FixServer.init(&.{}, .{ .io = io, .ip = "127.0.0.1", .port = 0, .comp_id = "SERVER" }),
    );
}

test "zix fix: FixServer.init, valid config succeeds and deinit is safe" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try FixServer.init(&.{}, .{ .io = io, .ip = "127.0.0.1", .port = 9500, .comp_id = "SERVER" });
    server.deinit();
}

test "zix fix: FixServer.init with EPOLL dispatch model succeeds" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try FixServer.init(&.{}, .{ .io = io, .ip = "127.0.0.1", .port = 9500, .comp_id = "SERVER", .dispatch_model = .EPOLL });
    server.deinit();
}
