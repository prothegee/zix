//! gRPC h2c server — all 3 dispatch models plus EPOLL (Linux-only).

const std = @import("std");
const core = @import("core.zig");
const config_mod = @import("config.zig");
const GrpcServerConfig = config_mod.GrpcServerConfig;
const DispatchModel = @import("../../config.zig").DispatchModel;

pub const Route = core.Route;

// --------------------------------------------------------- //

const ConnQueue = struct {
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    buf: []std.posix.fd_t = &.{},
    head: usize = 0,
    len: usize = 0,
    closed: bool = false,

    fn push(self: *ConnQueue, fd: std.posix.fd_t, io: std.Io) void {
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

    fn pop(self: *ConnQueue, io: std.Io) ?std.posix.fd_t {
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

    fn close(self: *ConnQueue, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        self.closed = true;
        self.mutex.unlock(io);
        self.ready.broadcast(io);
    }

    fn deinit(self: *ConnQueue) void {
        if (self.buf.len > 0) std.heap.smp_allocator.free(self.buf);
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
};

fn workerEntry(ctx: WorkerCtx) void {
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
        ctx.queue.push(stream.socket.handle, ctx.io);
    }
}

// --------------------------------------------------------- //

fn GrpcServerImpl(comptime routes: []const Route) type {
    return struct {
        const Self = @This();

        config: GrpcServerConfig,

        // --------------------------------------------------------- //

        const ConnTask = struct {
            fd: std.posix.fd_t,
            opts: core.GrpcServeOpts,
        };

        fn dispatchConn(task: ConnTask) void {
            defer _ = std.os.linux.close(task.fd);
            core.serveGrpcConn(routes, task.fd, task.opts);
        }

        // --------------------------------------------------------- //

        const PoolCtx = struct {
            queue: *ConnQueue,
            io: std.Io,
            opts: core.GrpcServeOpts,
        };

        fn poolEntry(ctx: PoolCtx) void {
            while (ctx.queue.pop(ctx.io)) |fd| {
                defer _ = std.os.linux.close(fd);
                core.serveGrpcConn(routes, fd, ctx.opts);
            }
        }

        // --------------------------------------------------------- //

        const AsyncWorkerCtx = struct {
            io: std.Io,
            ip: []const u8,
            port: u16,
            kernel_backlog: u31,
            opts: core.GrpcServeOpts,
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
                    .fd = stream.socket.handle,
                    .opts = ctx.opts,
                }});
            }
        }

        // --------------------------------------------------------- //

        const EpollWorkerCtx = struct {
            queue: *FdQueue,
            io: std.Io,
            opts: core.GrpcServeOpts,
        };

        fn epollWorkerEntry(ctx: EpollWorkerCtx) void {
            while (ctx.queue.pop(ctx.io)) |fd| {
                defer _ = std.os.linux.close(fd);
                core.serveGrpcConn(routes, fd, ctx.opts);
            }
        }

        /// EPOLL dispatch: a single epoll event loop accepts connections and hands
        /// them to a worker pool. Each worker runs the full gRPC connection loop.
        /// Linux-only.
        ///
        /// Note:
        /// - Unlike HTTP EPOLL, gRPC workers hold a connection for its full lifetime
        ///   because HTTP/2 is stateful (HPACK table, stream state, flow control).
        ///   The EPOLL benefit here is single-threaded accept vs N accept threads in POOL.
        /// - pool_size sets the worker count (0 = max(10, cpu * 2)).
        fn runEpoll(self: *Self, io: std.Io) !void {
            const linux = std.os.linux;
            const cfg = self.config;
            const cpu = try std.Thread.getCpuCount();
            const pool_count = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;
            const opts = core.GrpcServeOpts{
                .max_streams = cfg.max_streams,
                .max_frame_size = cfg.max_frame_size,
                .max_header_scratch = cfg.max_header_scratch,
                .max_body = cfg.max_body,
                .logger = cfg.logger,
                .handler_timeout_ms = cfg.handler_timeout_ms,
            };

            const addr = std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port) catch |err| {
                std.debug.print("zix grpc server: epoll resolve error: {}\n", .{err});
                return err;
            };
            var net_server = addr.listen(io, .{
                .reuse_address = true,
                .kernel_backlog = cfg.kernel_backlog,
            }) catch |err| {
                std.debug.print("zix grpc server: epoll listen error: {}\n", .{err});
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

            var lev = linux.epoll_event{
                .events = linux.EPOLL.IN | linux.EPOLL.ET,
                .data = .{ .fd = listener_fd },
            };
            if (std.posix.errno(linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, listener_fd, &lev)) != .SUCCESS)
                return error.EpollCtlFailed;

            std.debug.print("zix grpc server (epoll): {s}:{d} ({d} pool)\n", .{ cfg.ip, cfg.port, pool_count });
            if (cfg.logger) |lg| lg.system(.INFO, "grpc", "listening on {s}:{d} (epoll/{d})", .{ cfg.ip, cfg.port, pool_count });

            var queue = FdQueue{};
            defer queue.deinit();

            const workers = try std.heap.smp_allocator.alloc(std.Thread, pool_count);
            defer std.heap.smp_allocator.free(workers);
            for (workers) |*t|
                t.* = try std.Thread.spawn(
                    .{ .stack_size = 512 * 1024 },
                    epollWorkerEntry,
                    .{EpollWorkerCtx{ .queue = &queue, .io = io, .opts = opts }},
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

        // --------------------------------------------------------- //

        /// Initialize the gRPC server with the given config.
        ///
        /// Return:
        /// !Self — error.PortNotConfigured if config.port is 0.
        pub fn init(config: GrpcServerConfig) !Self {
            if (config.port == 0) return error.PortNotConfigured;
            return .{ .config = config };
        }

        /// No-op: resources are released inside run via defer.
        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Listen and serve. Routes are baked in at compile time via Server.init.
        ///
        /// Return:
        /// !void
        pub fn run(self: *Self) !void {
            const cfg = self.config;
            const io = cfg.io;
            const cpu = try std.Thread.getCpuCount();
            const opts = core.GrpcServeOpts{
                .max_streams = cfg.max_streams,
                .max_frame_size = cfg.max_frame_size,
                .max_header_scratch = cfg.max_header_scratch,
                .max_body = cfg.max_body,
                .logger = cfg.logger,
                .handler_timeout_ms = cfg.handler_timeout_ms,
            };

            switch (cfg.dispatch_model) {
                .ASYNC => {
                    std.debug.print("zix grpc server (async): {s}:{d}\n", .{ cfg.ip, cfg.port });
                    if (cfg.logger) |lg| lg.system(.INFO, "grpc", "listening on {s}:{d} (async)", .{ cfg.ip, cfg.port });

                    const addr = try std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port);
                    var listener = try addr.listen(io, .{
                        .reuse_address = true,
                        .kernel_backlog = cfg.kernel_backlog,
                    });
                    defer listener.deinit(io);

                    while (true) {
                        const stream = listener.accept(io) catch |err| {
                            if (err != error.ConnectionAborted) {
                                std.debug.print("zix grpc server: accept error: {}\n", .{err});
                                break;
                            }
                            continue;
                        };
                        _ = io.async(dispatchConn, .{ConnTask{
                            .fd = stream.socket.handle,
                            .opts = opts,
                        }});
                    }
                },

                .POOL => {
                    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;
                    const pool_count = if (cfg.pool_size == 0) @max(10, cpu * 2) else cfg.pool_size;

                    std.debug.print("zix grpc server (pool): {s}:{d} ({d} accept, {d} pool)\n", .{
                        cfg.ip, cfg.port, worker_count, pool_count,
                    });
                    if (cfg.logger) |lg| lg.system(.INFO, "grpc", "listening on {s}:{d} (pool/{d}x{d})", .{ cfg.ip, cfg.port, worker_count, pool_count });

                    var queue = ConnQueue{};
                    defer queue.deinit();

                    const pool_threads = try std.heap.smp_allocator.alloc(std.Thread, pool_count);
                    defer std.heap.smp_allocator.free(pool_threads);
                    for (pool_threads) |*t|
                        t.* = try std.Thread.spawn(
                            .{ .stack_size = 512 * 1024 },
                            poolEntry,
                            .{PoolCtx{ .queue = &queue, .io = io, .opts = opts }},
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
                            }},
                        );

                    for (acc_threads) |t| t.join();
                    queue.close(io);
                    for (pool_threads) |t| t.join();
                },

                .MIXED => {
                    const worker_count = if (cfg.workers == 0) cpu else cfg.workers;

                    std.debug.print("zix grpc server (mixed): {s}:{d} ({d} accept)\n", .{
                        cfg.ip, cfg.port, worker_count,
                    });
                    if (cfg.logger) |lg| lg.system(.INFO, "grpc", "listening on {s}:{d} (mixed/{d})", .{ cfg.ip, cfg.port, worker_count });

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
                                .opts = opts,
                            }},
                        );

                    for (acc_threads) |t| t.join();
                },

                .EPOLL => {
                    if (comptime @import("builtin").target.os.tag == .linux) {
                        try self.runEpoll(io);
                    } else {
                        std.debug.print("zix grpc server: EPOLL is Linux-only. Falling back to POOL.\n", .{});
                        var fallback = self.*;
                        fallback.config.dispatch_model = .POOL;
                        try fallback.run();
                    }
                },
            }
        }
    };
}

// --------------------------------------------------------- //

/// gRPC h2c server. Routes are baked in at compile time.
///
/// Usage:
/// ```zig
/// var server = try zix.Grpc.Server.init(
///     &[_]zix.Grpc.Route{
///         .{ .path = "/pkg.Svc/Method", .handler = myHandler },
///     },
///     .{ .io = io, .ip = "127.0.0.1", .port = 8083 },
/// );
/// defer server.deinit();
/// try server.run();
/// ```
pub const GrpcServer = struct {
    pub fn init(
        comptime routes: []const Route,
        config: GrpcServerConfig,
    ) !GrpcServerImpl(routes) {
        return GrpcServerImpl(routes).init(config);
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix grpc: GrpcServer.init port zero returns PortNotConfigured" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(
        error.PortNotConfigured,
        GrpcServer.init(&[_]Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 0 }),
    );
}

test "zix grpc: GrpcServer.init valid config succeeds and deinit is safe" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try GrpcServer.init(&[_]Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 8083 });
    server.deinit();
}
