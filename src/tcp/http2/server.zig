//! HTTP/2 h2c server: all 3 dispatch models.

const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const Config = @import("config.zig");
const Http2ServerConfig = Config.Http2ServerConfig;
const DispatchModel = @import("../config.zig").DispatchModel;

pub const Route = core.Route;

// --------------------------------------------------------- //

/// Emit a server lifecycle line. Http2ServerConfig has no logger, so this prints
/// to stderr only in Debug builds (silent in release).
fn logSystem(comptime fmt: []const u8, args: anytype) void {
    if (comptime builtin.mode == .Debug) std.debug.print("zix http2: " ++ fmt ++ "\n", args);
}

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
        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
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

fn Http2ServerImpl(comptime routes: []const Route) type {
    return struct {
        const Self = @This();

        config: Http2ServerConfig,

        // --------------------------------------------------------- //

        const ConnTask = struct {
            fd: std.posix.fd_t,
            opts: core.ServeOpts,
        };

        fn dispatchConn(task: ConnTask) void {
            defer _ = std.os.linux.close(task.fd);
            core.serveConn(routes, task.fd, task.opts);
        }

        // --------------------------------------------------------- //

        const PoolCtx = struct {
            queue: *ConnQueue,
            io: std.Io,
            opts: core.ServeOpts,
        };

        fn poolEntry(ctx: PoolCtx) void {
            while (ctx.queue.pop(ctx.io)) |fd| {
                defer _ = std.os.linux.close(fd);
                core.serveConn(routes, fd, ctx.opts);
            }
        }

        // --------------------------------------------------------- //

        const AsyncWorkerCtx = struct {
            io: std.Io,
            ip: []const u8,
            port: u16,
            kernel_backlog: u31,
            opts: core.ServeOpts,
        };

        fn asyncWorkerEntry(ctx: AsyncWorkerCtx) void {
            const addr = std.Io.net.IpAddress.resolve(ctx.io, ctx.ip, ctx.port) catch return;
            var listener = addr.listen(ctx.io, .{
                .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
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

        /// Initialize the HTTP/2 server with the given config.
        ///
        /// Return:
        /// - !Self (error.PortNotConfigured if config.port is 0)
        pub fn init(config: Http2ServerConfig) !Self {
            if (config.port == 0) return error.PortNotConfigured;
            return .{ .config = config };
        }

        /// No-op: resources released inside run via defer.
        pub fn deinit(self: *Self) void {
            _ = self;
        }

        /// Listen and serve. Routes are baked in at compile time via Server.init.
        ///
        /// Return:
        /// - !void
        pub fn run(self: *Self) !void {
            const cfg = self.config;
            const io = cfg.io;
            const cpu = try std.Thread.getCpuCount();
            const opts = core.ServeOpts{
                .max_streams = cfg.max_streams,
                .max_frame_size = cfg.max_frame_size,
                .max_header_scratch = cfg.max_header_scratch,
                .max_body = cfg.max_body,
            };

            switch (cfg.dispatch_model) {
                .ASYNC => {
                    logSystem("listening on {s}:{d} (async)", .{ cfg.ip, cfg.port });

                    const addr = try std.Io.net.IpAddress.resolve(io, cfg.ip, cfg.port);
                    var listener = try addr.listen(io, .{
                        .reuse_address = true, // SO_REUSEADDR + SO_REUSEPORT on POSIX, required for POOL, applied to all models
                        .kernel_backlog = cfg.kernel_backlog,
                    });
                    defer listener.deinit(io);

                    while (true) {
                        const stream = listener.accept(io) catch |err| {
                            if (err != error.ConnectionAborted) {
                                logSystem("accept error: {}", .{err});
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

                    logSystem("listening on {s}:{d} (pool/{d}x{d})", .{ cfg.ip, cfg.port, worker_count, pool_count });

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

                    logSystem("listening on {s}:{d} (mixed/{d})", .{ cfg.ip, cfg.port, worker_count });

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

                // .URING has no native ring path in zix.Http2, so it follows .EPOLL
                // and falls back to POOL (ADR-037 implements .URING in zix.Http1 first).
                .EPOLL, .URING => {
                    logSystem("EPOLL is HTTP-only. Falling back to POOL.", .{});
                    var fallback = self.*;
                    fallback.config.dispatch_model = .POOL;
                    try fallback.run();
                },
            }
        }
    };
}

// --------------------------------------------------------- //

/// HTTP/2 h2c server. Routes are baked in at compile time.
///
/// Usage:
/// ```zig
/// var server = try zix.Http2.Server.init(
///     &[_]zix.Http2.Route{
///         .{ .path = "/",     .handler = homeHandler },
///         .{ .path = "/echo", .handler = echoHandler },
///     },
///     .{ .io = io, .ip = "127.0.0.1", .port = 8082 },
/// );
/// defer server.deinit();
/// try server.run();
/// ```
pub const Http2Server = struct {
    pub fn init(
        comptime routes: []const Route,
        config: Http2ServerConfig,
    ) !Http2ServerImpl(routes) {
        return Http2ServerImpl(routes).init(config);
    }
};

// --------------------------------------------------------- //
// --------------------------------------------------------- //

test "zix test: Http2Server.init, port zero returns PortNotConfigured" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(
        error.PortNotConfigured,
        Http2Server.init(&[_]Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 0 }),
    );
}

test "zix test: Http2Server.init, valid config succeeds and deinit is safe" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var server = try Http2Server.init(&[_]Route{}, .{ .io = io, .ip = "127.0.0.1", .port = 8082 });
    server.deinit();
}
